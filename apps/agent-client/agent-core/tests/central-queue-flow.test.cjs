// Real clients, relay/router, hosts and stream hashes; only radio delivery and native engines are controlled.
const assert=require('node:assert/strict'),path=require('node:path'),vm=require('node:vm');
const {transpile}=require('../../../../tests/ets-harness.cjs'),root=path.resolve(__dirname,'../../../..');
let timer=0;const timers=new Map(),globals={Date,Map,Set,Array,Math,Number,String,JSON,Promise,Error,Uint8Array,ArrayBuffer,
 setTimeout:(fn,ms)=>{timers.set(++timer,{fn,ms});return timer},clearTimeout:id=>timers.delete(id)};
function load(file,imports={}){const box={...globals,exports:{},require:name=>imports[name]||{}};vm.runInNewContext(transpile(path.join(root,file)),box);return box.exports;}
const compute='apps/compute-node/entry/src/main/ets/',agent='apps/agent-client/entry/src/main/ets/';
const logger={'@kit.PerformanceAnalysisKit':{hilog:{info(){},warn(){}}}};
const wire=load(compute+'llm/InferenceWire.ets',{'@kit.ArkTS':{util:{TextEncoder:class{encodeInto(text){return Buffer.from(text)}}}}});
const repair=load(compute+'llm/Utf8Repair.ets'),pool=load(compute+'cluster/DevicePool.ets'),routerCode=load(compute+'cluster/ComputeRouter.ets');
const reuse=load(compute+'llm/SessionReuse.ets'),rules=load(compute+'cluster/TaskRules.ets');
const {InferenceRelay,RelayEvents}=load(compute+'llm/InferenceRelay.ets',{...logger,'../cluster/ComputeRouter':routerCode,'../cluster/DevicePool':pool,'../cluster/TaskRules':rules,'./SessionReuse':reuse});
const {InferenceHost,InferCardHooks}=load(compute+'llm/InferenceHost.ets',{...logger,'./InferenceWire':wire,'./Utf8Repair':repair,'./QwenVlManager':{QwenVlManager:{getInstance:()=>({isBusy:()=>false,unloadIfIdle(){}})}}});
function engine(){const calls=[],active=new Map();return {calls,active,readinessError:()=>'',hasPendingNativeJobs:()=>active.size>0,
 start(messages,listener,id){const call={messages,listener,id};calls.push(call);active.set(id,call);return ''},
 cancel(id){const call=active.get(id);if(call){active.delete(id);call.listener({kind:'done',text:'',finishReason:'cancelled'})}},
 finish(call,text){assert(active.delete(call.id));call.listener({kind:'delta',text});call.listener({kind:'done',text:'',finishReason:'stop'})}}}
const turn=async()=>{for(let i=0;i<80;i++)await Promise.resolve()};
(async()=>{
 const text1=engine(),text2=engine(),vision=engine(),hosts=new Map(),clients=new Map(),received=new Map(),sent=[];let relay;
 const sender=async(message,epoch)=>{sent.push({message:JSON.parse(JSON.stringify(message)),epoch});await Promise.resolve();
  if(clients.has(epoch)){received.get(epoch)(message,epoch);return true;}
  const host=hosts.get(epoch);if(!host)return false;host.handle(message,0);return true;
 };
 const hub=new InferenceHost(text1,(m,e)=>relay.sendLocal(m,e),new InferCardHooks());hub.setDeviceProvider(()=> '算力设备1');
 const worker=new InferenceHost(text2,async(m)=>{await Promise.resolve();relay.handleFromWorker(m,7);return true},new InferCardHooks());worker.setDeviceProvider(()=> '算力设备2');
 const imageHost=new InferenceHost({readinessError:()=> 'no text model',hasPendingNativeJobs:()=>false,cancel(){}},async(m)=>{await Promise.resolve();relay.handleFromWorker(m,8);return true},new InferCardHooks());imageHost.setDeviceProvider(()=> '算力设备3');imageHost.setVisionTransport(vision);
 hosts.set(7,worker);hosts.set(8,imageHost);const router=new routerCode.ComputeRouter();
 const node=(epoch,label,caps,inflight,isSelf=false)=>Object.assign(new pool.PoolNode(),{epoch,label,capabilities:caps,inflight,ready:true,isSelf,memAvail:100});
 relay=new InferenceRelay(router,()=>[node(0,'算力设备1',['text'],hub.activeCount(),true),node(7,'算力设备2',['text'],router.workerLoad(7,worker.activeCount())),node(8,'算力设备3',['vision'],router.workerLoad(8,imageHost.activeCount()))],()=>[...clients.keys()],hub,sender,new RelayEvents());
 hub.setClusterProvider(()=>relay.load());
 function client(epoch){const channel={readyEpoch:()=>epoch,inferenceReady:()=>true,setInferenceHandler:fn=>received.set(epoch,fn),setInferenceLinkHandler(){},async send(m){await Promise.resolve();relay.handleFromChat(m,epoch);return true}};
  const {inferenceClient:c}=load(agent+'model/InferenceClient.ets',{...logger,'../nearby/LinkEnhanceChannel':{nearbyChannel:channel},'./InferenceWire':wire,'./Utf8Repair':repair});c.bind();clients.set(epoch,c);return c;
 }
 const a=client(5),b=client(6);assert.equal(await a.ensureReady(),'');assert.equal(await b.ensureReady(),'');assert.equal(a.profile.centralQueue,true);
 // With two text devices, all five wire requests reach actual Host admission before any result completes.
 const five=Array.from({length:5},(_,i)=>a.complete('user task '+i,{owner:'five-'+i}));await turn();
 assert.equal(text1.calls.length+text2.calls.length,5);assert.equal(relay.pendingCount(),0);assert.equal(a.routingCalls().length,5);
 for(const e of [text2,text1])for(const call of e.calls.slice().reverse())e.finish(call,'answer: '+call.messages.at(-1).content);
 await turn();assert.deepEqual(await Promise.all(five),Array.from({length:5},(_,i)=>'answer: user task '+i));assert.equal(a.routingCalls().length,0);
 // A busy visual engine queues at the hub, yet later text goes straight to a text engine.
 const first=a.complete('image one',{owner:'image-one'},null,'AA==');await turn();const queued=a.complete('image two',{owner:'image-two'},null,'AA==').catch(e=>e.message);await turn();
 assert.equal(vision.calls.length,1);assert.equal(relay.pendingCount(),1);const queueCall=a.routingCalls().find(x=>x.question==='推理请求'&&x.stage==='hub-queued');assert(queueCall);assert.equal(queueCall.device,'');
 const text=a.complete('text while image is busy',{owner:'later-text'});await turn();assert.equal(text1.calls.length+text2.calls.length,6);
 const textEngine=text1.active.size?text1:text2;const textCall=[...textEngine.active.values()][0];textEngine.finish(textCall,'text passed busy image');
 a.cancelOwner('image-two');await turn();assert.equal(await queued,'已停止生成');assert.equal(relay.pendingCount(),0);
 vision.finish([...vision.active.values()][0],'cat one');await turn();assert.equal(await first,'cat one');assert.equal(await text,'text passed busy image');assert.equal(vision.calls.length,1,'cancelled queued image never starts');
 // Same wire IDs from two chat connections remain isolated; queued work from a dropped origin is removed.
 a.instance='same-client-id';b.instance='same-client-id';a.serial=100;b.serial=100;
 const imageA=a.complete('chat A',{owner:'a'},null,'AA=='),imageB=b.complete('chat B',{owner:'b'},null,'AA==').catch(e=>e.message);await turn();
 assert.equal(a.routingCalls()[0].id,b.routingCalls()[0].id);assert.equal(relay.pendingCount(),1);
 relay.chatDropped(6);b.reset();await turn();assert.match(await imageB,/连接/);assert.equal(relay.pendingCount(),0);
 vision.finish([...vision.active.values()][0],'only A');await turn();assert.equal(await imageA,'only A');assert.equal(vision.calls.length,2);
 assert.equal(relay.admissions.size,0);relay.close();
 console.log('PASS actual client→hub→host flow: five tasks/two text devices, hash-checked results, image waiting with text bypass, queued cancellation, colliding IDs, origin disconnect and terminal cleanup');
})().catch(e=>{console.error(e);process.exitCode=1});
