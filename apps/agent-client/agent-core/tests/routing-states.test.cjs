// Exercise the actual client, projection and HTML renderer with deterministic time and no device.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {transpile,transpileSource}=require('../../../../tests/ets-harness.cjs');
const root=path.resolve(__dirname,'../../../..');
let now=10000,timer=0;const timers=new Map();
class Clock extends Date{static now(){return now;}}
const globals={Date:Clock,Map,Set,Math,Number,Array,String,JSON,Promise,Error,
 setTimeout:(fn)=>{timers.set(++timer,fn);return timer},clearTimeout:id=>timers.delete(id)};
function load(file,requires={}){const box={exports:{},require:name=>requires[name]||{},...globals};vm.runInNewContext(transpile(path.join(root,file)),box);return box.exports;}
// The application channel accepts the display extension in both directions, without changing inference-v2.
for(const app of ['agent-client','compute-node']){
 const protocol=load('apps/'+app+'/entry/src/main/ets/protocol/ChatProtocol.ets',{'@kit.ArkTS':{util:{TextEncoder:class{encodeInto(text){return Buffer.from(text)}}}}});
 assert(protocol.validMessage({protocol:'nearby-chat-v1',type:'infer.status',version:2,requestId:'r',state:'rerouting',source:'算力设备2',device:'算力设备3',text:'执行设备连接中断'}));
}
const channel={readyEpoch:()=>7,send:async()=>true};
const {inferenceClient:client}=load('apps/agent-client/entry/src/main/ets/model/InferenceClient.ets',{
 '../nearby/LinkEnhanceChannel':{nearbyChannel:channel},'@kit.PerformanceAnalysisKit':{hilog:{info(){},warn(){}}},
 './InferenceWire':{utf8Bytes:text=>Buffer.from(text),sha256Hex:()=>''},'./Utf8Repair':{repairUtf8FromSource:text=>text}
});
const seenPhases=[];
const sent=[];client.deliver=(m,e)=>{sent.push(m);return true};
const ready=()=>{client.profile={ready:true,maxOutputTokens:128,maxPromptBytes:32768};client.profileEpoch=7};ready();
const {TaskRoutingStore}=load('apps/agent-client/entry/src/main/ets/ui/TaskRoutingStore.ets'),store=new TaskRoutingStore();
const hub={id:'hub',name:'算力设备1',role:'compute',ready:true,model:'Qwen2.5-7B',jobs:0},
 worker={id:'worker',name:'算力设备2',role:'compute',ready:true,model:'Qwen3-80B',jobs:0},
 vision={id:'vision',name:'算力设备3',role:'compute',ready:true,model:'Qwen2.5-VL-3B',jobs:0};
store.receive({type:'deviceInfoSync',devices:[hub,worker,vision]},7);
const project=()=>JSON.parse(store.snapshot(client.routingCalls(),'聊天设备1','chat',true,7,hub));
const elements={};for(const id of ['viewport','stage','space','collaboration','detail','detailText','closeDetail'])elements[id]={style:{setProperty(){}},clientWidth:1000,clientHeight:1120,scrollHeight:500,innerHTML:'',scrollTop:0,addEventListener(){},querySelectorAll(){return[]}};
const window={addEventListener(){}},document={getElementById:id=>elements[id]||null,createElement:()=>({})};
const html=fs.readFileSync(path.join(root,'apps/agent-client/entry/src/main/resources/rawfile/task-routing.html'),'utf8');
const ui={...globals,window,document,setInterval(){}};
vm.runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1]+'\nthis.inspect=()=>({items:flowItems,flights:Array.from(flowFlights.values())});',ui);
const render=()=>{window.onNativeEvent(project());return elements.collaboration.innerHTML};
const message=(id,type,extra={},epoch=7)=>client.onMessage({type,requestId:id,...extra},epoch);
(async()=>{
 // Requests blocked by a previous cancellation are local; they have stable separate identities and no packets.
 client.stopping.set('stop',{epoch:7,timer:-1});
 const local1=client.complete('本地排队一').catch(()=>{}),local2=client.complete('本地排队二').catch(()=>{});
 let calls=client.routingCalls();assert.equal(calls[0].phase,'waiting-send');assert.notEqual(calls[0].displayId,calls[1].displayId);
 const waitingAt=calls[0].startedAt;now+=1000;assert.equal(client.routingCalls()[0].startedAt,waitingAt);
 assert.match(render(),/等待发送/);assert.doesNotMatch(render(),/class="flow-packet"/);
 client.reset();await Promise.all([local1,local2]);ready();
 const image=client.complete('识别这张图',{label:'识别图片',onPhase:phase=>seenPhases.push(phase)},null,'aGVsbG8=').catch(()=>{}),id=sent.at(-1).requestId;
 let projected=project();assert.equal(projected.jobs[0].source,'');assert.equal(projected.jobs[0].ingressId,'hub');
 let markup=render();assert.match(markup,/data-flow-leg="ingress" data-flow-target="router"/);assert.doesNotMatch(markup,/data-flow-leg="executor"/);
 message(id,'infer.accepted',{device:'算力设备3',state:'queued'},999);assert.equal(client.routingCalls()[0].device,'');
 message(id,'infer.accepted',{device:'算力设备3',state:'queued'});
 assert.equal(client.routingCalls()[0].phase,'queued');assert.equal(seenPhases.at(-1),'queued');markup=render();
 assert.match(markup,/等待执行/);assert.match(markup,/data-flow-leg="executor" data-flow-target="vision"/);assert.doesNotMatch(markup,/data-flow-leg="ingress"|class="flow-task working"/);
 assert.equal(ui.inspect().items[0].executor,'vision');assert.equal(ui.inspect().flights.length,1);
 now+=10;message(id,'infer.accepted',{state:'queued'});assert.equal(client.routingCalls()[0].device,'算力设备3','a worker acknowledgement may omit the hub assignment');
 for(const [stage,label] of [['preparing','准备模型'],['loading','加载模型'],['prefill','处理输入'],['generating','生成中']]){
  now+=100;message(id,'infer.status',{state:stage});assert.equal(client.routingCalls()[0].stage,stage);assert.match(render(),new RegExp(label));
 }
 const phaseAt=client.routingCalls()[0].phaseStartedAt;now+=100;message(id,'infer.status',{state:'generating'});assert.equal(client.routingCalls()[0].phaseStartedAt,phaseAt,'repeated status does not reset the phase clock');
 message(id,'infer.status',{state:'queued'},999);assert.equal(client.routingCalls()[0].phase,'running');
 // A genuine retry stops the old path before acceptance arrives for the next device.
 message(id,'infer.status',{state:'rerouting',source:'算力设备3',device:'算力设备2',text:'执行设备连接中断'});
 markup=render();assert.equal(ui.inspect().flights.length,0);assert.match(markup,/算力设备3不可用，改派算力设备2/);
 message(id,'infer.accepted',{device:'算力设备2',state:'queued'});render();assert.equal(ui.inspect().flights[0].executor,'worker');
 // Delayed mirrored evidence must not pull this request back onto the failed executor.
 store.receiveFlow({text:JSON.stringify({key:'request:'+id+':attempt',revision:1,kind:'image',phase:'running',source:'算力设备3',origin:'聊天设备1',originId:'chat',executorId:'vision',executionBackend:'cloud',executionModel:'stale-cloud',elapsed:10})});
 assert.equal(project().queuedCalls[0].executorId,undefined);assert.equal(project().queuedCalls[0].executionBackend,undefined);render();assert.equal(ui.inspect().items[0].executor,'worker');
 const text=client.complete('另一条任务').catch(()=>{}),textId=sent.at(-1).requestId;
 message(textId,'infer.accepted',{device:'算力设备1',state:'preparing'});render();assert.equal(ui.inspect().items.length,2);
 assert.deepEqual(ui.inspect().flights.map(x=>x.executor).sort(),['hub','worker']);
 message(id,'infer.error',{message:'结束测试'});await image;render();assert.equal(ui.inspect().flights.length,1);assert.equal(ui.inspect().flights[0].executor,'hub','ending one request leaves the other flight intact');
 now+=9000;assert.doesNotMatch(render(),/任务改派/);
 // All devices busy: wait at the router with no made-up target, stable identity across a new wire ID.
 const busy=client.complete('等待多模态空闲',{},null,'aGVsbG8=').catch(()=>{}),busyId=sent.at(-1).requestId;
 const displayId=client.routingCalls().find(x=>x.id===busyId).displayId;
 message(busyId,'infer.error',{code:'BUSY',retryable:true});render();
 assert.equal(ui.inspect().items.find(x=>x.key==='client:'+displayId).executor,null);
 const state=client.waitingCalls[0];now+=1000;client.resend(state);assert.notEqual(state.requestId,busyId);
 assert.equal(client.routingCalls().find(x=>x.id===state.requestId).displayId,displayId);
 render();assert.equal(ui.inspect().items.filter(x=>x.key==='client:'+displayId).length,1);
 client.reset();await Promise.all([text,busy]);render();assert.equal(ui.inspect().flights.length,0);
 // Native tablet queue is projected as local waiting, without changing its admission policy.
 const page=fs.readFileSync(path.join(root,'apps/agent-client/entry/src/main/ets/pages/Index.ets'),'utf8');
 const start=page.indexOf('  private refreshRoutingView('),end=page.indexOf('\n  }',start)+4;
 const box={exports:{},inferenceClient:{clusterLoad:()=>({idle:2,total:2}),routingCalls:()=>[]},nearbyChannel:{isConnected:()=>true,readyEpoch:()=>7,selfLabel:()=> '聊天设备1',localUid:()=> 'chat',connectedComputeInfo:()=>hub}};
 vm.runInNewContext(transpileSource('class Page {'+page.slice(start,end)+'} exports.Page=Page;'),box);
 const native=new box.exports.Page();Object.assign(native,{deviceInfoPoller:{poll(){}},pageActive:true,routingStore:store,taskQueue:[{id:4,display:'还没发出',imagePayload:'',submittedAt:now}]});
 native.refreshRoutingView();assert.equal(JSON.parse(native.routingJson).queuedCalls[0].phase,'waiting-send');
 console.log('PASS routing stages, explicit executor, queued acceptance, two-hop animation, retry identity, stale events, concurrent isolation, reroute cleanup and native local queue');
})().catch(error=>{console.error(error);process.exitCode=1});
