// Actual page dispatcher and session methods, controlled workers; no UI, device or external writes.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.TYPESCRIPT_PATH||'typescript'),{transpile}=require('../../../../tests/ets-harness.cjs');
const coreBox={exports:{}};vm.runInNewContext(transpile(path.resolve(__dirname,'../src/main/ets/agent/ConversationContext.ets')),coreBox);
const {ConversationContext}=coreBox.exports;
const ledgerBox={exports:{},require:()=>({ConversationContext})};vm.runInNewContext(transpile(path.resolve(__dirname,'../../entry/src/main/ets/model/TaskConversationLedger.ets')),ledgerBox);
const source=fs.readFileSync(path.resolve(__dirname,'../../entry/src/main/ets/pages/Index.ets'),'utf8').replace(/\r\n/g,'\n'),lines=source.split('\n');
const names=['initializeTabletSessions','captureEngineSession','saveSelectedDraft','selectSession','newSession','createTabletSession','sessionBusy','canClearSession','clearSessionHistory','sessionMessages','switchConversation','isEmptyTabletSession','restoreTabletSessions','restoreResultBubbles',
 'selectedSessionTitle','sessionStatus','visibleMessages','canClearAllSessions','clearAllSessions','persistTabletSessions','drainTaskQueue','runAgent','canSend','clearAttachment','composeAttachmentTask',
 'ledgerFor','setSessionMessages','refreshTaskActivity','startConcurrentTask','updateConcurrentTask','finishConcurrentTask','cancelSessionTasks','cancelAllConcurrentTasks',
 'clearWaitingTasks','deleteSession','resultTranscript','buildRemoteConversation','ensureTaskConnection','openNewSession','closeSessionDrawer','chooseAttachment'];
function method(name){const start=lines.findIndex(l=>['  private '+name+'(','  private async '+name+'('].some(p=>l.startsWith(p)));assert.ok(start>=0,name);let end=start+1;while(lines[end]!=='  }')end++;return lines.slice(start,end+1).join('\n');}
function deferred(){let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};}
const workers=[];class Worker{
 constructor(input,ready,observe){this.input=input;this.observe=observe;this.gate=deferred();this.cancelled=false;workers.push(this);}
 run(){this.observe({phase:'running',status:'生成',answer:'',process:'',device:'',startedAt:100,endedAt:0});return this.gate.promise;}
 finish(answer,phase='done'){this.observe({phase,status:'完成',answer,process:'',device:'算力设备2',startedAt:100,endedAt:200});this.gate.resolve();}
 cancel(){this.cancelled=true;this.finish('已停止生成','cancelled');}
 late(answer){this.observe({phase:'done',status:'完成',answer,process:'',device:'',startedAt:100,endedAt:200});}
}
let savedSessions='[]',total=3,legacyClears=0;let pickResult=null;let encodeResult=null;
const BubbleKind={USER:0,LOOP:1,PROCESS:2,TASK:3,ERROR:4};
const box={exports:{},fs:{OpenMode:{CREATE:1,WRITE_ONLY:2,TRUNC:4},openSync:()=>({fd:1}),writeSync(_fd,text){savedSessions=text;},closeSync(){},readTextSync:()=>savedSessions},clearStoredConversation(){legacyClears++;},ConversationRole:coreBox.exports.ConversationRole,ConversationContext,TaskConversationLedger:ledgerBox.exports.TaskConversationLedger,
 ConcurrentChatTask:Worker,BubbleKind,PARTIAL_HISTORY_NOTE:'（上一轮未得到完整回答）',LIVE_PLACEHOLDER:'正在生成…',REMOTE_HISTORY_TURNS:6,REMOTE_HISTORY_MAX_CHARS:4000,
 inferenceClient:{clusterLoad:()=>({total,idle:total})},taskProgressActive:p=>p==='running'||p==='preparing',Edge:{Bottom:1},Curve:{EaseOut:0},Date,
 pickAttachment:async()=>await pickResult,encodeLocalImageBase64:async()=>{if(encodeResult)return await encodeResult;throw new Error('bad image');}};
vm.runInNewContext(ts.transpileModule('class Page {'+names.map(method).join('\n')+'} exports.Page=Page;', {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
function page(){const p=new box.exports.Page();Object.assign(p,{sessions:[],messages:[],conversation:new ConversationContext(),message:'',taskQueue:[],nextSessionId:1,
 selectedSessionId:'',engineSessionId:'',nextQueuedTaskId:1,nextChatBubbleId:1,pageActive:true,sending:false,queueDraining:false,taskClosing:false,activeTaskSessions:[],activeChatTasks:new Map(),taskLedgers:new Map(),
 preparingSubmission:false,sessionDrawerVisible:false,pendingPath:'',pendingKind:'',pendingName:'',pendingLocal:'',chatMode:'chat',remoteRunGeneration:0,
 getAbilityContext:()=>({filesDir:'/test'}),getUIContext:()=>({animateTo(_options,update){update();}}),buildMessagesFromConversation:c=>c.toChatMessages().map(t=>({text:t.content,kind:t.role==='user'?0:1})),
 createChatBubble(speaker,text,kind,imagePath=''){return {id:this.nextChatBubbleId++,speaker,text,kind,imagePath,collapsible:false,expanded:false,revision:0};},
 scroller:{scrollEdge(){}},setCollaborationKeepScreenOn(){},ensureRemoteReady:async()=>true});p.initializeTabletSessions();return p;}
async function tick(){for(let i=0;i<30;i++)await Promise.resolve();}
async function submit(p,text){p.message=text;await p.runAgent();}
async function submitNew(p,text){p.openNewSession();await submit(p,text);}
(async()=>{
 const p=page(),start=workers.length;
 await submitNew(p,'会话A');const a=p.sessions[0].id;
 await submitNew(p,'会话B');const b=p.sessions[1].id;
 await submitNew(p,'会话C');await submitNew(p,'会话D');
 assert.equal(p.sessions.length,4,'explicit new sessions keep concurrent work separate');
 assert.equal(workers.length-start,3);assert.equal(p.taskQueue.length,1,'device capacity still queues excess conversations');
 assert.equal(new Set(p.activeTaskSessions).size,3);
 assert.deepEqual(Array.from(workers[start+1].input.conversation.toChatMessages()),[],'new conversations do not inherit selected history');
 p.switchConversation(a);assert.equal(p.selectedSessionId,a);assert.equal(p.sessionDrawerVisible,false);
 const beforeBusy=p.sessions[0].messages.length;
 await submit(p,'不能抢先追问');p.clearSessionHistory();
 assert.equal(p.sessions[0].messages.length,beforeBusy);assert.equal(workers.length-start,3,'a busy conversation cannot send another round');
 assert.equal(p.canClearSession(),false);assert.equal(p.canClearAllSessions(),false);
 workers[start].finish('A的回答');await tick();assert.equal(workers.length-start,4,'next conversation gets released capacity');
 const cardCount=p.sessions.length;await submit(p,'继续会话A');assert.equal(p.sessions.length,cardCount,'main composer follows up in the selected conversation');
 assert.equal(p.taskQueue.length,1);workers[start+1].finish('B的回答');await tick();
 assert.equal(workers.length-start,5);
 assert.deepEqual(Array.from(workers[start+4].input.conversation.toChatMessages(),t=>t.content),['会话A','A的回答'],'follow-up uses this conversation history');
 workers[start+2].finish('C的回答');workers[start+3].finish('D的回答');workers[start+4].finish('A的追问回答');await tick();
 assert.deepEqual(Array.from(p.sessions.find(s=>s.id===a).conversation.toChatMessages(),t=>t.content),['会话A','A的回答','继续会话A','A的追问回答']);
 assert.equal(p.sessionMessages(b).some(bubble=>bubble.text==='B的回答'),true);
 p.message='会话A草稿';p.clearSessionHistory();
 assert.equal(p.sessions.length,4);assert.equal(p.selectedSessionId,a);assert.equal(p.visibleMessages().length,0);
 assert.equal(p.sessions[0].conversation.toChatMessages().length,0);assert.equal(p.sessions[0].draft,'');assert.equal(p.message,'');
 assert.equal(p.taskLedgers.has(a),false);assert.equal(p.sessions.find(s=>s.id===b).conversation.toChatMessages().length,2);
 const clearedSaved=JSON.parse(savedSessions);assert.equal(clearedSaved[0].resultBubbles.length,0);assert.equal(clearedSaved[0].transcript,'[]');
 workers[start].late('过期内容');assert.equal(p.visibleMessages().length,0);
 const reloaded=page();reloaded.restoreTabletSessions();assert.equal(reloaded.sessions[0].messages.length,0,'clear persists the complete conversation');
 p.switchConversation(b);assert.equal(p.visibleMessages().some(bubble=>bubble.text==='B的回答'),true,'drawer selection switches the inline conversation');
 p.message='B的草稿';p.openNewSession();const fresh=p.selectedSessionId;
 assert.notEqual(fresh,b);assert.equal(p.sessionDrawerVisible,false);assert.equal(p.message,'');
 assert.equal(p.sessions.find(s=>s.id===b).draft,'B的草稿');
 p.openNewSession();assert.equal(p.selectedSessionId,fresh,'repeated new conversation reuses an empty session');
 const global=page(),globalStart=workers.length;await submitNew(global,'后台工作');global.openNewSession();
 const beforeClear=legacyClears;global.clearAllSessions();assert.equal(legacyClears,beforeClear);assert.equal(global.sessions.length,2);
 workers[globalStart].finish('完成');await tick();global.message='主页草稿';global.pendingPath='photo';
 global.clearAllSessions();assert.equal(global.sessions.length,0);assert.equal(global.visibleMessages().length,0);assert.equal(global.message,'');assert.equal(global.pendingPath,'');
 assert.equal(global.taskLedgers.size,0);assert.equal(legacyClears,beforeClear+1);assert.equal(global.sessionDrawerVisible,false);
 const photoFail=page();photoFail.message='保留图片问题';photoFail.pendingKind='image';photoFail.pendingPath='photo';photoFail.pendingLocal='photo.jpg';
 await photoFail.runAgent();assert.equal(photoFail.message,'保留图片问题');assert.equal(photoFail.pendingPath,'photo');assert.equal(photoFail.taskQueue.length,0);assert.equal(photoFail.sessions.length,0,'encoding failure does not add an orphan card');
 const detailFail=page();detailFail.newSession();detailFail.message='会话图片';detailFail.pendingKind='image';detailFail.pendingPath='photo';detailFail.pendingLocal='photo.jpg';
 await detailFail.runAgent();assert.equal(detailFail.message,'会话图片');assert.equal(detailFail.pendingPath,'photo');
 const cancel=page(),cancelStart=workers.length;await submitNew(cancel,'A工作');await submitNew(cancel,'B工作');const other=cancel.sessions[1].id;
 cancel.deleteSession(cancel.sessions[0].id);await tick();assert.equal(workers[cancelStart].cancelled,true);assert.equal(workers[cancelStart+1].cancelled,false);
 workers[cancelStart+1].finish('B工作完成');await tick();assert.ok(cancel.sessionMessages(other).some(bubble=>bubble.text==='B工作完成'));
 savedSessions=JSON.stringify([{title:'新会话',transcript:'[]',draft:''},{title:'新对话',transcript:'[]',draft:''},
 {title:'历史',transcript:JSON.stringify([{role:'user',content:'历史内容'}]),resultTranscript:'[]',draft:''},{title:'新会话',transcript:'[]',draft:'草稿'}]);
 const restored=page();restored.restoreTabletSessions();assert.equal(restored.sessions.length,3);assert.equal(restored.sessions[1].messages.length,0);assert.equal(restored.sessions[1].conversation.toChatMessages()[0].content,'历史内容');
 const photo=page();photo.newSession();photo.messages=[{id:1,kind:BubbleKind.USER,text:'（附图）',imagePath:'/test/photo.jpg',revision:0},
  {id:2,kind:BubbleKind.TASK,text:'',imagePath:'',revision:0,taskProgress:{kind:'图像',phase:'done',device:'算力设备2',startedAt:1000,endedAt:4000}},
  {id:3,kind:BubbleKind.LOOP,text:'图片中的物体',imagePath:'',revision:0}];
 photo.persistTabletSessions();const photoReload=page();photoReload.restoreTabletSessions();
 assert.equal(photoReload.messages[0].imagePath,'/test/photo.jpg','stored conversation images retain their local image path');
 assert.equal(photoReload.messages[1].taskProgress.device,'算力设备2');assert.equal(photoReload.messages[1].taskProgress.endedAt,4000);
 savedSessions=JSON.stringify([{id:'old',title:'中断的任务',draft:'',transcript:'[]',savedAt:7000,resultBubbles:[
  {kind:BubbleKind.USER,text:'图片问题',imagePath:'/test/photo.jpg'},
  {kind:BubbleKind.TASK,text:'',taskProgress:{kind:'图像',phase:'running',startedAt:5000,endedAt:0,device:'算力设备2'}},
  {kind:BubbleKind.LOOP,text:'正在生成…',pending:true}]}]);
 const interrupted=page();interrupted.restoreTabletSessions();assert.equal(interrupted.messages[1].taskProgress.phase,'cancelled');assert.equal(interrupted.messages[1].taskProgress.endedAt,7000);
 assert.equal(interrupted.messages[2].kind,BubbleKind.ERROR,'restoring an interrupted task must not restart a phantom spinner');

 const switching=page();
 await submit(switching,'首次发送');const first=switching.selectedSessionId;
 assert.equal(switching.sessions.length,1,'first send creates and selects a conversation');
 switching.message='A草稿';switching.pendingKind='file';switching.pendingPath='A.txt';switching.pendingName='A.txt';
 switching.openNewSession();const second=switching.selectedSessionId;switching.message='B草稿';
 switching.switchConversation(first);assert.equal(switching.message,'A草稿');assert.equal(switching.pendingPath,'A.txt');
 switching.switchConversation(second);assert.equal(switching.message,'B草稿');assert.equal(switching.pendingPath,'');
 workers.at(-1).finish('首次回答');await tick();
 switching.switchConversation(first);switching.clearAttachment();await submit(switching,'同一会话追问');
 assert.equal(switching.sessions.length,2);assert.equal(workers.at(-1).input.conversation.toChatMessages()[0].content,'首次发送');
 workers.at(-1).finish('追问回答');await tick();
 // The picker may return after another conversation becomes active.
 const attachment=page();attachment.message='先输入再选附件';pickResult={kind:'image',name:'房间.jpg',relativePath:'room.jpg',localPath:'/room.jpg'};
 await attachment.chooseAttachment();const photoSession=attachment.selectedSessionId;
 assert.equal(attachment.message,'先输入再选附件');assert.equal(attachment.pendingPath,'room.jpg');
 attachment.openNewSession();const nextSession=attachment.selectedSessionId;
 attachment.switchConversation(photoSession);const pick=deferred();pickResult=pick.promise;
 const picking=attachment.chooseAttachment();attachment.switchConversation(nextSession);
 pick.resolve({kind:'file',name:'计划.txt',relativePath:'plan.txt',localPath:'/plan.txt'});await picking;
 assert.equal(attachment.pendingPath,'','a late attachment cannot leak into another conversation');
 attachment.switchConversation(photoSession);assert.equal(attachment.pendingPath,'plan.txt');assert.equal(attachment.message,'先输入再选附件');
 // Image encoding also captures the intended conversation before yielding.
 attachment.pendingKind='image';attachment.pendingLocal='/room.jpg';attachment.saveSelectedDraft();
 const encoded=deferred();encodeResult=encoded.promise;const preparing=attachment.runAgent();
 attachment.switchConversation(nextSession);attachment.message='另一个会话的草稿';
 encoded.resolve('base64-image');await preparing;
 assert.equal(workers.at(-1).input.display,'先输入再选附件');assert.equal(attachment.selectedSessionId,nextSession);
 assert.equal(attachment.message,'另一个会话的草稿');assert.equal(attachment.pendingPath,'');
 workers.at(-1).finish('图片回答');await tick();assert.ok(attachment.sessionMessages(photoSession).some(b=>b.text==='图片回答'));
 encodeResult=null;pickResult=null;
 console.log('PASS current conversation: inline switching, follow-up context, drafts and attachments, asynchronous picker/encoding isolation, live background work, cancellation, clear and persistence');
})().catch(e=>{console.error(e);process.exitCode=1;});
