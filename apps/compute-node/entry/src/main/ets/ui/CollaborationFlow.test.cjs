const assert=require('node:assert/strict'),dashboard=require('./DashboardHarness.cjs');
const h=dashboard(),now=Date.now();
const devices=[{id:'c1',name:'算力设备1',role:'self',ready:true,jobs:2,memUsage:50,model:'Qwen2.5-7B',capabilities:['text']},
 {id:'c2',name:'算力设备2',role:'compute',ready:true,jobs:1,memUsage:51,model:'Qwen2.5-VL-3B',capabilities:['text','vision']},
 {id:'p',name:'聊天设备1',role:'chat',ready:true}];
const photo='data:image/jpeg;base64,/9j/4AAQ';
const job=(key,extra={})=>({id:key,key,source:'算力设备1',origin:'聊天设备1',kind:'text',phase:'running',running:true,startedAt:now-5000,phaseStartedAt:now-5000,endedAt:0,question:'介绍一下深圳',...extra});
const event={kind:'dashboard',selfLabel:'算力设备1',devices,jobs:[job('one'),job('two',{kind:'image',question:'这是什么',image:photo})],remoteCalls:[job('three',{source:'算力设备2',phase:'sending',kind:'image'})],queuedCalls:[job('wait',{phase:'queued',source:''})],groups:[]};
h.window.onNativeEvent(event);
let html=h.elements.collaboration.innerHTML;
assert.equal((html.match(/class="flow-compute"/g)||[]).length,2);
assert.doesNotMatch(h.source,/class="app-tabs"|id="tabDashboard"|id="tabLlama"/);
assert.equal((html.match(/class="flow-task working"/g)||[]).length,2);
assert.doesNotMatch(html,/class="flow-task waiting"|等待分配|暂无排队|flow-lane queue|<h3>排队/);
assert.match(html,/<h3>推理中-(文本|图片)<\/h3>/);assert.match(html,/offset-path:path/);assert.match(html,/class="flow-photo"/);
assert.match(html,/介绍一下深圳/);assert.match(html,/这是什么/);
assert.doesNotMatch(html,/flight-label|>发送中</);
assert.match(html,/flow-device-name">算力设备1<\/span><span class="flow-device-model">Qwen2\.5-7B/);assert.match(html,/flow-device-name">算力设备2<\/span><span class="flow-device-model">Qwen2\.5-VL-3B/);
assert.match(html,/class="flow-pc-local">本机<\/span>/);
assert.match(html,/>路由中心<br>\(算力设备1\)<\/span>/);
assert.doesNotMatch(html,/>路由层</);
assert.equal((html.match(/class="flow-pc-local"/g)||[]).length,1);
let llamaManagerOpens=0;
h.window.chatBridge.openLlamaManager=()=>{llamaManagerOpens++;};
const clusterEvent={...event,jobs:[],remoteCalls:[],queuedCalls:[],flowCalls:[],devices:[
  {id:'cluster',name:'compute',role:'self',ready:true,jobs:0,memUsage:20,capabilities:['text'],inferenceBackend:'llama.cpp'}]};
h.window.onNativeEvent(clusterEvent);html=h.elements.collaboration.innerHTML;
assert.match(html,/class="flow-pc-mark flow-cluster-link"/);
assert.match(html,/data-open-llama="1"/);
h.elements.collaboration.handlers.click({target:h.target({'data-open-llama':'1'}),preventDefault(){},stopPropagation(){}});
assert.equal(llamaManagerOpens,1,'cluster icon opens Llama management');
h.window.onNativeEvent({...clusterEvent,devices:[{...clusterEvent.devices[0],role:'compute'}]});
assert.doesNotMatch(h.elements.collaboration.innerHTML,/data-open-llama/,'a remote cluster must not open the local manager');
h.window.onNativeEvent({...clusterEvent,devices:[
  {id:'single',name:'compute',role:'self',ready:true,jobs:0,memUsage:20,capabilities:['text'],inferenceBackend:'native'}]});
html=h.elements.collaboration.innerHTML;
assert.doesNotMatch(html,/flow-cluster-link|data-open-llama/,'single-device icon stays non-clickable');
h.window.onNativeEvent(event);html=h.elements.collaboration.innerHTML;
assert.match(h.elements.usageStats.innerHTML,/累计完成<\/span><b>0/);
assert.match(h.elements.usageStats.innerHTML,/节省 token<\/span><b>0/);
assert.match(h.elements.usageStats.innerHTML,/节省金额<\/span><b>¥0\.00/);
assert.doesNotMatch(h.elements.stats.innerHTML,/累计完成|节省 token|DeepSeek/);
event.usage={tasks:12,tokens:1500,microYuan:4000};
h.window.onNativeEvent(event);
assert.match(h.elements.usageStats.innerHTML,/累计完成<\/span><b>12/);
assert.match(h.elements.usageStats.innerHTML,/节省 token<\/span><b>1,500/);
assert.match(h.elements.usageStats.innerHTML,/节省金额<\/span><b>¥0\.0040/);
assert.match(html,/width:50%;background:#279a73/);assert.match(html,/width:51%;background:#e1b43b/);
assert.match(html,/00:05/);
event.remoteCalls=[];event.jobs=[];event.queuedCalls=[];event.devices=devices.map(device=>({...device,jobs:0}));
h.window.onNativeEvent(event);html=h.elements.collaboration.innerHTML;
assert.match(html,/<h3>在线-文本<\/h3>/);assert.doesNotMatch(html,/<h3>推理中-(文本|图片)<\/h3>/);
assert.doesNotMatch(html,/class="flow-packet"|data-flow-clock/);
event.flowCalls=[job('mirror:remote',{source:'算力设备2',kind:'image'})];h.window.onNativeEvent(event);html=h.elements.collaboration.innerHTML;
assert.match(html,/介绍一下深圳|图片/);assert.doesNotMatch(html,/data-flow-detail="mirror:/,'mirrored minimal records must not open nonexistent local details');
console.log('PASS: live device layout, concurrent tasks, question and image on the collaboration card, sending path, idle/online labels, clock baseline, >50 memory threshold, terminal cleanup and mirror handling');

// Local inference can remain available while the nearby listener failed. That
// must not turn a failed enable attempt into a green "ready" status.
const nearbyFailure = '无法启动增强连接（32390203）。';
h.window.onNativeEvent({kind:'connection',text:nearbyFailure,available:true,connecting:false,connectLabel:'启用近场'});
assert.equal(h.elements.connection.textContent,nearbyFailure);
assert.equal(h.elements.connection.className,'status err');
assert.equal(h.elements.connect.disabled,false,'a failed attempt leaves enable available for retry');
h.window.onNativeEvent({...event,text:nearbyFailure,available:true,connecting:false,connectLabel:'启用近场'});
assert.equal(h.elements.connection.textContent,nearbyFailure,'dashboard refresh preserves the startup error');
h.window.onNativeEvent({kind:'connection',text:'近场已连接',available:true,connecting:false,connectLabel:'停用近场'});
assert.equal(h.elements.connection.textContent,'已就绪');
assert.equal(h.elements.connection.className,'status ok');
console.log('PASS: nearby startup failure remains visible while local inference is available, and successful retry clears it');
