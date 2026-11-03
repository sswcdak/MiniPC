const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {transpile}=require('../../../../tests/ets-harness.cjs');
const box={exports:{}};
vm.runInNewContext(transpile(path.resolve(__dirname,'../../entry/src/main/ets/ui/ResultOverview.ets')),box);
const {resultTurns,resultSnippet,resultPhaseLabel,resultElapsed,resultIsActive,resultInputLabel,sessionResult}=box.exports;
const message=(id,kind,text='',extra={})=>({id,revision:0,kind,text,imagePath:'',pending:false,phase:'',...extra});
const input='长输入\n\n'+'请保留这份计划的全部内容。\n'.repeat(30);
const answer='完整回答\n'+'工作项与验收标准\n'.repeat(50);
const bubbles=[message(1,'input',input,{imagePath:'/test/photo.jpg'}),message(2,'status','',{phase:'done'}),
 message(3,'process','调用工具\n原始记录'),message(4,'answer',answer),message(5,'input','仍在运行'),
 message(6,'status','',{phase:'running'}),message(7,'answer','正在生成…',{pending:true})];
let turns=resultTurns(bubbles);
assert.equal(turns.length,2);assert.equal(turns[0].input,input);assert.equal(turns[0].answer,answer);
assert.equal(turns[0].imagePath,'/test/photo.jpg');assert.equal(turns[0].process,'调用工具\n原始记录');
assert.equal(turns[1].answer,'','pending placeholders are not saved as an answer');assert.equal(turns[1].phase,'running');
assert.ok(resultSnippet(turns[0].input,32).length<=32);assert.ok(resultSnippet(turns[0].answer,48).length<=48);
assert.equal(resultSnippet('  第一行\n\n第二行\t第三行 ',32),'第一行 第二行 第三行');
assert.equal(turns[0].answer,answer,'making thumbnails must not truncate the full reader text');
const emoji=resultSnippet('a'.repeat(30)+'😀尾部',32);assert.equal(emoji,'a'.repeat(30)+'…');
const stableKey=turns[1].key,oldRevision=turns[1].revision;
bubbles[6]={...bubbles[6],pending:false,text:'新输出',revision:2};turns=resultTurns(bubbles);
assert.equal(turns[1].key,stableKey);assert.ok(turns[1].revision>oldRevision);assert.equal(turns[1].answer,'新输出');
turns=resultTurns([message(-1,'input','排队的输入',{phase:'queued'}),message(9,'input','失败的输入'),message(10,'error','网络异常')]);
assert.equal(turns[0].phase,'queued');assert.equal(turns[1].phase,'failed');assert.equal(turns[1].answer,'网络异常');
turns=resultTurns([message(1,'input','停止'),message(2,'status','',{phase:'cancelled'}),message(3,'answer','部分回答\n已停止生成')]);
assert.equal(turns[0].phase,'cancelled');assert.equal(turns[0].answer,'部分回答\n已停止生成');
assert.equal(resultTurns([]).length,0);assert.equal(resultPhaseLabel('cancelled'),'已停止');
const waitingAtHub=resultTurns([message(20,'input','中心等待'),message(21,'status','',{phase:'running',inferencePhase:'hub-queued',startedAt:1000,endedAt:0})])[0];
assert.equal(waitingAtHub.phase,'hub-queued');assert.equal(resultPhaseLabel(waitingAtHub.phase),'中心等待分派');assert.equal(resultIsActive(waitingAtHub.phase),true);assert.equal(resultElapsed(waitingAtHub,12000),'00:11');
let timed=resultTurns([message(1,'input','（附图）',{imagePath:'/photo.jpg'}),message(2,'status','',{
 phase:'running',inferencePhase:'prefill',device:'算力设备2',startedAt:1000,endedAt:0})])[0];
assert.equal(timed.phase,'prefill');assert.equal(timed.device,'算力设备2');assert.equal(resultInputLabel(timed),'图片输入');
assert.equal(resultElapsed(timed,12000),'00:11');assert.equal(resultElapsed(timed,13000),'00:12');assert.equal(resultIsActive(timed.phase),true);
timed.phase='done';timed.endedAt=15000;assert.equal(resultElapsed(timed,99000),'00:14','finished clocks do not continue ticking');
timed.phase='cancelled';assert.equal(resultElapsed(timed,100000),'00:14');
timed.endedAt=0;assert.equal(resultElapsed(timed,100000),'—','old histories must not invent durations');
timed.startedAt=1000;timed.endedAt=3662000;assert.equal(resultElapsed(timed,9999999),'01:01:01');
const cardSource=fs.readFileSync(path.resolve(__dirname,'../../entry/src/main/ets/ui/ResultCard.ets'),'utf8').split('\n');
function cardMethod(name){const start=cardSource.findIndex(line=>line.startsWith('  private '+name+'('));let end=start+1;while(cardSource[end]!=='  }')end++;return cardSource.slice(start,end+1).join('\n');}
let clockNow=12000,clockSerial=0;const clockTimers=new Map();
const clockBox={exports:{},resultElapsed,resultIsActive,Date:{now:()=>clockNow},setInterval(fn){clockTimers.set(++clockSerial,fn);return clockSerial;},clearInterval(id){clockTimers.delete(id);}};
const clockTs=require(process.env.TYPESCRIPT_PATH||'typescript');
vm.runInNewContext(clockTs.transpileModule('class Card {'+['stopTimer','syncTimer'].map(cardMethod).join('\n')+'} exports.Card=Card;', {compilerOptions:{target:clockTs.ScriptTarget.ES2020}}).outputText,clockBox);
const card=new clockBox.exports.Card();timed.phase='running';timed.endedAt=0;Object.assign(card,{visible:true,timer:-1,turn:timed});card.syncTimer();assert.equal(clockTimers.size,1);
clockNow=14000;[...clockTimers.values()][0]();assert.equal(card.elapsed,'00:13');timed.phase='done';timed.endedAt=15000;card.syncTimer();assert.equal(clockTimers.size,0);assert.equal(card.elapsed,'00:14');
timed.phase='running';card.syncTimer();assert.equal(clockTimers.size,1);card.stopTimer();assert.equal(clockTimers.size,0,'removed cards release their clock interval');
const breathBox={exports:{},resultIsActive,Curve:{EaseInOut:0},PlayMode:{Alternate:1}};
vm.runInNewContext(clockTs.transpileModule('class Card {'+['syncBreathing','surface'].map(cardMethod).join('\n')+'} exports.Card=Card;', {compilerOptions:{target:clockTs.ScriptTarget.ES2020}}).outputText,breathBox);
const breathCard=new breathBox.exports.Card(),animations=[];
Object.assign(breathCard,{visible:true,breathing:false,turn:{phase:'running'},getUIContext:()=>({animateTo(options,update){animations.push(options);update();}})});
breathCard.syncBreathing();assert.equal(breathCard.breathing,true);assert.equal(animations[0].iterations,-1);
breathCard.syncBreathing();assert.equal(animations.length,1,'streaming updates do not restart the breathing loop');
breathCard.turn.phase='done';breathCard.syncBreathing();assert.equal(breathCard.breathing,false);assert.equal(animations[1].duration,0);
assert.equal(breathCard.surface(),'#E1F1E6');breathCard.turn.phase='running';breathCard.syncBreathing();
breathCard.visible=false;breathCard.syncBreathing();assert.equal(breathCard.breathing,false,'hidden cards stop their animation');
breathCard.visible=true;breathCard.turn.phase='queued';breathCard.syncBreathing();assert.equal(breathCard.breathing,false,'queued work stays steady');
const source=fs.readFileSync(path.resolve(__dirname,'../../entry/src/main/ets/pages/Index.ets'),'utf8').replace(/\r\n/g,'\n');
const lines=source.split('\n');
const names=['onBackPress','openSessionDrawer','closeSessionDrawer','toggleRoutingPanel','toggleCurrentConversation'];
function method(name){const start=lines.findIndex(line=>['  '+name+'(','  private '+name+'('].some(prefix=>line.startsWith(prefix)));assert.ok(start>=0,name);let end=start+1;while(lines[end]!=='  }')end++;return lines.slice(start,end+1).join('\n');}
const ts=require(process.env.TYPESCRIPT_PATH||'typescript'),state={exports:{},Curve:{EaseOut:0}};
vm.runInNewContext(ts.transpileModule('class Page {'+names.map(method).join('\n')+'} exports.Page=Page;', {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,state);
const page=new state.exports.Page();let animationCount=0,persistCount=0;
Object.assign(page,{sessionDrawerVisible:false,settingsVisible:false,routingCollapsed:false,
 persistTabletPreferences(){persistCount++;},getUIContext:()=>({animateTo(_options,update){animationCount++;update();}})});
page.openSessionDrawer();assert.equal(page.sessionDrawerVisible,true);assert.equal(page.onBackPress(),true);assert.equal(page.sessionDrawerVisible,false);
page.settingsVisible=true;assert.equal(page.onBackPress(),true);assert.equal(page.settingsVisible,false);assert.equal(page.onBackPress(),false);
page.toggleCurrentConversation();assert.equal(page.routingCollapsed,true,'expanding current conversation folds routing');
page.toggleCurrentConversation();assert.equal(page.routingCollapsed,false,'restoring conversation reopens routing');
page.toggleRoutingPanel();assert.equal(page.routingCollapsed,true,'routing header also gives space to conversation');
assert.equal(persistCount,3);assert.ok(animationCount>=5,'layout changes animate');
// Run the application's inline conversation clock, including streaming updates and teardown.
const viewLines=fs.readFileSync(path.resolve(__dirname,'../../entry/src/main/ets/ui/ConversationTurnView.ets'),'utf8').split('\n');
function viewMethod(name){const start=viewLines.findIndex(l=>l.startsWith('  private '+name+'('));assert.ok(start>=0,name);let end=start+1;while(viewLines[end]!=='  }')end++;return viewLines.slice(start,end+1).join('\n');}
let viewNow=5000,viewSerial=0;const viewTimers=new Map();
const viewBox={exports:{},resultElapsed,resultIsActive,Date:{now:()=>viewNow},setInterval(fn){viewTimers.set(++viewSerial,fn);return viewSerial;},clearInterval(id){viewTimers.delete(id);}};
vm.runInNewContext(ts.transpileModule('class View {'+['stopTimer','syncTimer'].map(viewMethod).join('\n')+'} exports.View=View;', {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,viewBox);
const view=new viewBox.exports.View();Object.assign(view,{turn:{phase:'running',startedAt:1000,endedAt:0},visible:true,timer:-1});
view.syncTimer();assert.equal(view.elapsed,'00:04');assert.equal(viewTimers.size,1);
viewNow=6000;view.syncTimer();assert.equal(view.elapsed,'00:05');assert.equal(viewSerial,1,'streaming updates keep one clock');
viewNow=7000;[...viewTimers.values()][0]();assert.equal(view.elapsed,'00:06');
view.turn={phase:'done',startedAt:1000,endedAt:8000};viewNow=99000;view.syncTimer();assert.equal(view.elapsed,'00:07');assert.equal(viewTimers.size,0);
view.turn.phase='running';view.syncTimer();view.visible=false;view.syncTimer();assert.equal(viewTimers.size,0,'switching away releases the conversation clock');
const empty=sessionResult('s1',[]);assert.equal(empty.phase,'empty');assert.equal(resultInputLabel(empty),'—');assert.equal(empty.answer,'');
const overview=sessionResult('s1',resultTurns(bubbles));assert.equal(overview.key,'s1');assert.equal(overview.input,'仍在运行');assert.equal(overview.answer,'新输出');assert.equal(resultTurns(bubbles).length,2,'overview does not alter complete history');
console.log('PASS result overview: short snippets, complete long text/image/process, live revisions, queue/error/cancellation; drawer navigation, animated conversation expansion and routing coordination');
