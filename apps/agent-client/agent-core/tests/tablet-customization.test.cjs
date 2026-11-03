const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {transpile}=require('../../../../tests/ets-harness.cjs');
function load(file,requires={}){const box={exports:{},require:name=>requires[name]||{},JSON,Array,Math,Number,Date};vm.runInNewContext(transpile(path.resolve(__dirname,'../../entry/src/main/ets/'+file)),box);return box.exports;}
let saved,fail=false;
const preferences={getPreferencesSync(){return {getSync:()=>saved??'{}',putSync:(key,value)=>{saved=value;},async flush(){if(fail)throw new Error('disk');}};}};
const presets=load('model/TabletQuickInputs.ets');
const settings=load('model/TabletPreferences.ets',{'@kit.ArkData':{preferences},'./TabletQuickInputs':presets});
(async()=>{
 const displaySize=load('model/TabletDisplay.ets');
 assert.equal(displaySize.TABLET_WIDTH_MM,127);assert.equal(displaySize.TABLET_HEIGHT_MM,198);
 assert.ok(Math.abs(displaySize.physicalPixelsPerInch()-264.068544)<0.00001);
 let pixels=displaySize.tabletSizePx(3120,2080);assert.equal(pixels.width,1320);assert.equal(pixels.height,2058);
 pixels=displaySize.tabletSizePx(2080,3120);assert.equal(pixels.width,1320);assert.equal(pixels.height,2058);
 pixels=displaySize.tabletSizePx(1560,1040);assert.equal(pixels.width,660);assert.equal(pixels.height,1029);
 pixels=displaySize.fitDefaultWindow({width:1320,height:2058},3120,1980);assert.equal(pixels.width,1320);assert.equal(pixels.height,1980);
 assert.equal(displaySize.physicalPixelsPerInch(0,0,0),displaySize.physicalPixelsPerInch());
 const windowCalls=[],screen={width:3120,height:2080,availableWidth:3120,availableHeight:1980,densityPixels:2};
 const win={async setWindowLimits(limits){windowCalls.push(['limits',limits]);return limits;},async resize(w,h){windowCalls.push(['resize',w,h]);}};
 const {default:EntryAbility}=load('entryability/EntryAbility.ets',{
  '@kit.AbilityKit':{UIAbility:class{}},'@kit.BasicServicesKit':{deviceInfo:{deviceType:'2in1'}},
  '@kit.ArkUI':{display:{getDefaultDisplaySync:()=>screen},window:{}},'../model/TabletDisplay':displaySize
 });
 const ability=new EntryAbility();await ability.configureDefaultWindow({getMainWindowSync:()=>win});
 const limits=windowCalls[0][1];assert.ok(limits.minWidth<limits.maxWidth);assert.ok(limits.minHeight<limits.maxHeight);
 assert.deepEqual(windowCalls[1],['resize',1320,1980]);
 const pageSource=fs.readFileSync(path.resolve(__dirname,'../../entry/src/main/ets/pages/Index.ets'),'utf8');
 assert.doesNotMatch(pageSource,/TABLET_WIDTH_VP|TABLET_HEIGHT_VP|TABLET_DISPLAY_RATIO/);
 assert.match(pageSource,/this.sessionSidebar\(\)/);assert.doesNotMatch(pageSource,/this.sessionStrip\(\)/);
 let value=settings.loadTabletPreferences({});assert.equal(value.quickInputs.length,4);assert.equal(value.sidebarCollapsed,false);
 await settings.saveTabletPreferences({},{quickInputs:['第一行\n第二行','自定义任务',''],sidebarCollapsed:true,sidebarWidth:240});
 value=settings.loadTabletPreferences({});assert.deepEqual(Array.from(value.quickInputs),['第一行\n第二行','自定义任务','',presets.DEFAULT_QUICK_INPUTS[3]]);assert.equal(value.sidebarCollapsed,true);assert.equal(value.sidebarWidth,240);
 value=settings.normalizeTabletPreferences({quickInputs:['x'.repeat(5000)],sidebarWidth:999});assert.equal(value.quickInputs[0].length,4000);assert.equal(value.sidebarWidth,300);
 saved='broken';assert.equal(settings.loadTabletPreferences({}).quickInputs.length,4);
 saved=JSON.stringify({quickInputs:['总结一下当前结果','列出下一步计划','帮我分析这个问题']});
 assert.deepEqual(Array.from(settings.loadTabletPreferences({}).quickInputs),Array.from(presets.DEFAULT_QUICK_INPUTS),'old stock prompts upgrade to four examples');
 saved=JSON.stringify({quickInputs:['自己的任务','','帮我分析这个问题']});
 assert.deepEqual(Array.from(settings.loadTabletPreferences({}).quickInputs),['自己的任务','',presets.DEFAULT_QUICK_INPUTS[2],presets.DEFAULT_QUICK_INPUTS[3]],'custom edits and disabled buttons survive migration');
 const oldSimpleQa='请用100～200字介绍一下华为公司，涵盖成立时间、总部所在地、主要业务和技术领域。语言简洁、客观，适合不了解这家公司的读者。直接给出一段介绍，不使用标题、列表或宣传口号。';
 saved=JSON.stringify({quickInputsVersion:2,quickInputs:['总结一下当前结果','','自己的任务',oldSimpleQa]});
 assert.deepEqual(Array.from(settings.loadTabletPreferences({}).quickInputs),['总结一下当前结果','','自己的任务',presets.DEFAULT_QUICK_INPUTS[3]],'version 2 stock introduction upgrades without replacing prior custom edits');
 for(const custom of ['请介绍其他公司','']){
  saved=JSON.stringify({quickInputsVersion:2,quickInputs:['','','',custom]});
  assert.equal(settings.loadTabletPreferences({}).quickInputs[3],custom,'custom or disabled introduction survives the shorter-prompt upgrade');
 }
 const oldCatAnalysis='请分析这张图片，用中文描述：\n1. 图中动物的种类、毛色和外观特征。\n2. 它的姿态、视线方向及身体各部分的位置。\n3. 周围环境、光线和画面构图。\n4. 两到三个容易被忽略的可见细节。\n\n请以图中实际可见的信息为依据；无法确定的内容请明确说明，不要仅凭外观推断具体品种、年龄、性别或健康状况。总字数控制在200～400字。';
 saved=JSON.stringify({quickInputsVersion:3,quickInputs:['自己的任务',oldCatAnalysis,'',presets.DEFAULT_QUICK_INPUTS[3]]});
 assert.deepEqual(Array.from(settings.loadTabletPreferences({}).quickInputs),['自己的任务',presets.DEFAULT_QUICK_INPUTS[1],'',presets.DEFAULT_QUICK_INPUTS[3]],'version 3 stock image prompt upgrades without replacing other edits');
 for(const custom of ['只描述猫的毛色','']){
  saved=JSON.stringify({quickInputsVersion:3,quickInputs:['',custom,'','']});
  assert.equal(settings.loadTabletPreferences({}).quickInputs[1],custom,'custom or disabled image prompt survives the shorter-prompt upgrade');
 }
 const oldLongSummary=presets.DEFAULT_QUICK_INPUTS[0].replace('生成一份100～200字的中文总结','生成一份300～500字的中文总结');
 for(const version of [2,3,4]){
  saved=JSON.stringify({quickInputsVersion:version,quickInputs:[oldLongSummary,oldCatAnalysis,presets.DEFAULT_QUICK_INPUTS[2],oldSimpleQa]});
  const upgraded=settings.loadTabletPreferences({});
  assert.equal(upgraded.quickInputs[0],presets.DEFAULT_QUICK_INPUTS[0],'old stock long summary upgrades to 100–200 characters');
  assert.equal(upgraded.quickInputsVersion,5);
 }
 for(const custom of ['请把这段文章总结成300～500字','']){
  saved=JSON.stringify({quickInputsVersion:4,quickInputs:[custom,'','','']});
  assert.equal(settings.loadTabletPreferences({}).quickInputs[0],custom,'custom or disabled summary survives migration');
 }
 saved=JSON.stringify({quickInputsVersion:5,quickInputs:[oldLongSummary,oldCatAnalysis,'',oldSimpleQa]});
 assert.deepEqual(Array.from(settings.loadTabletPreferences({}).quickInputs),[oldLongSummary,oldCatAnalysis,'',oldSimpleQa],'edits made after upgrading are not migrated again');
 await settings.saveTabletPreferences({},{quickInputs:['总结一下当前结果','','',''],sidebarWidth:200});
 assert.equal(settings.loadTabletPreferences({}).quickInputs[0],'总结一下当前结果','explicitly edited old wording is not migrated again');
 assert.equal(presets.QUICK_INPUT_LABELS.length,4);
 fail=true;await assert.rejects(settings.saveTabletPreferences({},value),/disk/);
 const promptNames=['01-long-summary.txt','02-cat-analysis.txt','03-coding.txt','04-simple-qa.txt'];
 promptNames.forEach((name,i)=>assert.equal(presets.DEFAULT_QUICK_INPUTS[i],fs.readFileSync(path.resolve(__dirname,'../../../../examples/quick-inputs',name),'utf8').trim()));
 const rules={exports:{}};
 vm.runInNewContext(transpile(path.resolve(__dirname,'../../../compute-node/entry/src/main/ets/cluster/TaskRules.ets')),rules);
 assert.deepEqual(Array.from(presets.DEFAULT_QUICK_INPUTS,(content,i)=>rules.exports.classifyFromMessages([{role:'user',content}],i===1).tier),[2,1,2,1],'the four presets cover both tiers while image analysis retains its image requirement');
 let written,closed=0;const attach=load('media/ChatAttach.ets',{
  '@ohos.file.fs':{default:{OpenMode:{CREATE:1,WRITE_ONLY:2,TRUNC:4},accessSync:()=>false,mkdirSync(){},openSync:()=>({fd:10}),writeSync(_fd,data){written=Buffer.from(data);return data.byteLength},closeSync(){closed++;}}},
  '@loop/agent-core':{ensureSandboxWorkspace(){},sandboxWorkspacePath:relative=>'/workspace/'+relative}
 });
 const bytes=new Uint8Array([9,1,2,3,9]).subarray(1,4);
 const cat=await attach.prepareQuickInputCat({resourceManager:{getRawFileContent:async name=>{assert.equal(name,'quick-inputs/cat.jpg');return bytes;}}});
 assert.deepEqual([...written],[1,2,3],'image export writes precisely the resource slice');assert.equal(closed,1);assert.equal(cat.localPath,'/workspace/uploads/quick-input-cat-v1.jpg');assert.equal(cat.kind,'image');
 await assert.rejects(attach.prepareQuickInputCat({resourceManager:{getRawFileContent:async()=>new Uint8Array()}}),/猫图素材为空/);
 const {TaskRoutingStore}=load('ui/TaskRoutingStore.ets'),store=new TaskRoutingStore();
 const connectedHub={id:'hub',deviceUid:'hub',name:'算力设备1',role:'compute',ready:true};
 const noRoster=new TaskRoutingStore();
 let connectedEvent=JSON.parse(noRoster.snapshot([],'聊天设备1','chat',true,7,connectedHub));
 assert.equal(connectedEvent.devices.filter(d=>d.role==='compute').length,1,'handshake-complete hub must show before any task or roster');
 noRoster.receive({type:'deviceInfoSync',devices:[connectedHub]},7);
 connectedEvent=JSON.parse(noRoster.snapshot([],'聊天设备1','chat',true,7,connectedHub));
 assert.equal(connectedEvent.devices.filter(d=>d.role==='compute').length,1,'roster replaces the handshake fallback without duplicates');
 connectedEvent=JSON.parse(noRoster.snapshot([],'聊天设备1','chat',false,-1,null));
 assert.equal(connectedEvent.devices.filter(d=>d.role==='compute').length,0,'disconnect removes the connected node');
 const linkSource=fs.readFileSync(path.resolve(__dirname,'../../entry/src/main/ets/nearby/LinkEnhanceChannel.ets'),'utf8').replace(/\r\n/g,'\n');
 const linkStart=linkSource.indexOf('  connectedComputeInfo('),linkEnd=linkSource.indexOf('\n  }',linkStart)+4;
 const routeTs=require(process.env.TYPESCRIPT_PATH||'typescript'),linkBox={exports:{},IS_SERVER:false};
 vm.runInNewContext(routeTs.transpileModule('class Links {'+linkSource.slice(linkStart,linkEnd)+'} exports.Links=Links;', {compilerOptions:{target:routeTs.ScriptTarget.ES2020}}).outputText,linkBox);
 const links=new linkBox.exports.Links();Object.assign(links,{peers:[],lastHits:[],idsMatch:(a,b)=>a===b});
 assert.equal(links.connectedComputeInfo(),null);
 links.peers=[{ready:true,deviceUid:'hub',peerId:'mac'}];links.lastHits=[{mac:'mac',slot:1}];
 assert.equal(links.connectedComputeInfo().deviceUid,'hub');assert.equal(links.connectedComputeInfo().name,'算力设备1');
 links.peers[0].ready=false;assert.equal(links.connectedComputeInfo(),null);

 store.receive({type:'deviceInfoSync',devices:[{deviceUid:'hub',name:'算力设备1',role:'compute',ready:true,memUsage:52,modelRequests:1,capabilities:['text','vision']},{deviceUid:'chat',name:'聊天设备1',role:'chat',ready:true}]},7);
 const calls=[{id:'one',question:'测试<任务>',image:'',device:'算力设备1',phase:'running',startedAt:1000},{id:'two',question:'排队',image:'',device:'',phase:'queued',startedAt:1001}];
 let event=JSON.parse(store.snapshot(calls,'聊天设备1','chat',true,7));assert.equal(event.devices.length,2);assert.equal(event.jobs.length,1);assert.equal(event.queuedCalls.length,1);assert.equal(event.jobs[0].originId,'chat');assert.equal(event.devices[0].memUsage,52);
 event=JSON.parse(store.snapshot([], '聊天设备1','chat',false,-1));assert.equal(event.devices.length,1);assert.equal(event.jobs.length,0);
 store.receive({type:'deviceInfoSync',devices:[{id:'stale',role:'compute'}]},7);event=JSON.parse(store.snapshot([], '聊天设备1','chat',true,8));assert.equal(event.devices.length,1,'old epoch roster must not survive reconnect');
 event=JSON.parse(store.snapshot(calls,'聊天设备1','chat',true,8));assert.equal(event.devices[1].name,'算力设备1','acceptance is actual device evidence');
 const notice={key:'other',revision:2,kind:'text',phase:'running',source:'算力设备2',origin:'聊天设备2',originId:'chat2',elapsed:3000};
 store.receiveFlow({text:JSON.stringify(notice)});event=JSON.parse(store.snapshot([],'聊天设备1','chat',true,8));assert.equal(event.flowCalls.length,1);
 store.receiveFlow({text:JSON.stringify({...notice,revision:3,phase:'cleared'})});
 store.receiveFlow({text:JSON.stringify({...notice,revision:2})});event=JSON.parse(store.snapshot([],'聊天设备1','chat',true,8));assert.equal(event.flowCalls.length,0,'late route must not revive cleared request');
 store.receiveFlow({text:JSON.stringify({...notice,key:'own',revision:1,originId:'chat'})});event=JSON.parse(store.snapshot(calls,'聊天设备1','chat',true,8));assert.equal(event.flowCalls.length,0,'owned requests must not duplicate mirrors');
 store.receiveFlow({text:JSON.stringify({...notice,key:'bad',revision:1,elapsed:-1})});event=JSON.parse(store.snapshot([],'聊天设备1','chat',true,8));assert.equal(event.flowCalls.length,0);

 // The chat asset uses the same node, wire and task renderer as the compute dashboard.
 const compute=fs.readFileSync(path.resolve(__dirname,'../../../compute-node/entry/src/main/resources/rawfile/peer-chat.html'),'utf8').replace(/\r\n/g,'\n');
 const html=fs.readFileSync(path.resolve(__dirname,'../../entry/src/main/resources/rawfile/task-routing.html'),'utf8');
 assert.match(html,/executionBackend/,'the chat route renderer retains local/cloud executor evidence');
 assert.match(html,/flow-cloud/,'cloud executors retain their existing visual layout');
 const start=compute.indexOf('    function flowClock('),end=compute.indexOf('    function flowTitle(',start);
 assert.ok(html.includes(compute.slice(start,end)),'compute clock, icons and safe image helpers must stay intact');
 const elements={};function el(){return {style:{setProperty(k,v){this[k]=v;}},clientWidth:640,clientHeight:500,scrollHeight:500,scrollTop:0,innerHTML:'',handlers:{},addEventListener(k,v){this.handlers[k]=v;},querySelectorAll(){return[];}};}
 for(const id of ['viewport','stage','space','collaboration','detail','detailText','closeDetail'])elements[id]=el();
 const document={getElementById:id=>elements[id]||null,createElement:()=>({})};
 const window={addEventListener(){}};vm.runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1],{document,window,Date,Map,Set,JSON,Math,Array,String,Number,setInterval(){}});
 window.onNativeEvent({devices:[{id:'hub',name:'算力设备1',role:'compute',ready:true,model:'Qwen2.5-7B-Instruct-Q4_N_0',memUsage:52},{id:'chat',name:'聊天设备1',role:'chat',ready:true}],jobs:[{id:'r',key:'client:r',source:'算力设备1',originId:'chat',origin:'聊天设备1',phase:'running',running:true,question:'测试<任务>',startedAt:Date.now()-5000}]});
 assert.match(elements.collaboration.innerHTML,/flow-compute/);assert.match(elements.collaboration.innerHTML,/测试&lt;任务&gt;/);assert.match(elements.collaboration.innerHTML,/路由中心/);assert.equal(elements.stage.style.transform,'scale(0.64)');
 assert.match(elements.collaboration.innerHTML,/算力设备1-Qwen2\.5-7B/,'device title keeps the reported model family and size');
 assert.doesNotMatch(elements.collaboration.innerHTML,/Qwen2\.5-7B-Instruct/,'device title omits model variant suffixes');
 window.onNativeEvent({devices:[{id:'hub',name:'算力设备1',role:'compute',ready:true,model:'Qwen2.5-VL-3B-NPU',capabilities:['text']}],jobs:[]});
 assert.match(elements.collaboration.innerHTML,/算力设备1-Qwen2\.5-VL-3B/,'a model switch keeps its family and size');
 assert.doesNotMatch(elements.collaboration.innerHTML,/Qwen2\.5-VL-3B-NPU/);
 assert.doesNotMatch(elements.collaboration.innerHTML,/算力设备1-(纯文本|多模态)/);
 window.onNativeEvent({devices:[{id:'hub',name:'算力设备1',role:'compute',ready:true,model:'<img src=x onerror="bad()">'}],jobs:[]});
 assert.match(elements.collaboration.innerHTML,/&lt;img src=x onerror=&quot;bad\(\)&quot;&gt;/,'model names are escaped in text and title attributes');
 assert.doesNotMatch(elements.collaboration.innerHTML,/<img src=x/);
 window.onNativeEvent({devices:[{id:'hub',name:'算力设备1',role:'compute',ready:true}],jobs:[]});
 assert.match(elements.collaboration.innerHTML,/算力设备1-模型待同步/);
 window.onNativeEvent({devices:[{id:'hub',name:'算力设备1',role:'compute',ready:true,model:''}],jobs:[]});
 assert.match(elements.collaboration.innerHTML,/算力设备1-无可用模型/);
 elements.stage.scrollHeight=2400;elements.viewport.clientHeight=300;
 window.onNativeEvent({devices:event.devices,jobs:[]});
 assert.equal(elements.stage.style.transform,'scale(0.125)','a tall diagram fits the available height');
 assert.equal(elements.stage.style.left,'0px','height-constrained diagram starts at the left edge');
 assert.equal(elements.stage.style.width,'5120px','layout widens so the scaled diagram still fills the viewport');
 assert.equal(elements.space.style.height,'300px','the diagram never creates a taller scroll surface');
 elements.stage.scrollHeight=500;elements.viewport.clientHeight=500;
 window.onNativeEvent({devices:[{id:'hub',name:'算力设备1',role:'compute',ready:true},{id:'worker',name:'算力设备2',role:'compute',ready:true,jobs:0},{id:'chat',name:'聊天设备1',role:'chat',ready:true}],jobs:[]});
 assert.equal((elements.collaboration.innerHTML.match(/class="flow-compute"/g)||[]).length,2,'idle compute members must remain visible');
 const beforeRoster=JSON.parse(new TaskRoutingStore().snapshot([],'聊天设备1','chat',true,7,connectedHub));
 window.onNativeEvent(beforeRoster);assert.match(elements.collaboration.innerHTML,/flow-compute/);assert.doesNotMatch(elements.collaboration.innerHTML,/等待算力设备上线/);
 const sending=JSON.parse(new TaskRoutingStore().snapshot([{id:'upload',question:'任务',image:'',device:'',phase:'sending',startedAt:Date.now()}],'聊天设备1','chat',true,7,connectedHub));
 window.onNativeEvent(sending);assert.match(elements.collaboration.innerHTML,/flow-packet/,'upload animates toward the connected hub before acceptance');
 window.onNativeEvent({devices:[],jobs:[]});assert.doesNotMatch(elements.collaboration.innerHTML,/flow-task working/);
 // Execute the actual compute publisher: ready chat clients receive route notices too.
 const computePage=fs.readFileSync(path.resolve(__dirname,'../../../compute-node/entry/src/main/ets/pages/Index.ets'),'utf8').replace(/\r\n/g,'\n');
 const methodStart=computePage.indexOf('  private publishFlow('),methodEnd=computePage.indexOf('\n  }',methodStart)+4;
 const ts=require(process.env.TYPESCRIPT_PATH||'typescript'),publisher={exports:{},computeLabel:()=> '算力设备1',Date,Math,Map,Array};
 vm.runInNewContext(ts.transpileModule('class Publisher {'+computePage.slice(methodStart,methodEnd)+'} exports.Publisher=Publisher;', {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,publisher);
 const p=new publisher.exports.Publisher(),sent=[];
 Object.assign(p,{isComputeHub:()=>true,flowNotices:new Map(),flowDeliveries:new Map(),flowRevision:0,channel:{peerInfos:()=>[{epoch:1,role:'chat',ready:true},{epoch:2,role:'compute',ready:true},{epoch:3,role:'chat',ready:false}],send:(message,epoch)=>{sent.push(epoch);return Promise.resolve(true);}}});
 p.publishFlow([{key:'r',startedAt:Date.now(),running:true,source:'算力设备1',origin:'聊天设备1'}]);
 assert.deepEqual(sent,[1],'executor skip must only apply to compute peers, not chat peers');
 console.log('PASS tablet preferences persistence, multiline custom text, bounds, failures, roster epochs, actual device evidence, shared route renderer and cleanup');
})().catch(e=>{console.error(e);process.exitCode=1;});
