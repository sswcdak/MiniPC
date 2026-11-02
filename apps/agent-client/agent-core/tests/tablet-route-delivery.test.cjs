const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {transpileSource}=require('../../../../tests/ets-harness.cjs');
const file=path.resolve(__dirname,'../../entry/src/main/ets/ui/TaskRoutingView.ets');
const source=fs.readFileSync(file,'utf8');
const plain=source.slice(0,source.indexOf('  build() {')).replace(/^import .*;\r?\n/gm,'').replace('@Component\n','')
 .replace('export struct TaskRoutingView','class TaskRoutingView').replace(/@Prop @Watch\('refresh'\) /g,'')+'}\nexports.View=TaskRoutingView;';
const flush=async()=>{for(let i=0;i<16;i++)await Promise.resolve();};
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return{promise,resolve,reject};};
function create(){
 const timers=new Map(),calls=[],logs=[];let timerId=0;
 const box={exports:{},Promise,Math,webview:{WebviewController:class{runJavaScript(script){calls.push(script);return Promise.resolve('{"inputComputes":2,"cards":2}');}}},
  hilog:{info(...args){logs.push(args);},warn(...args){logs.push(args);}},setTimeout(fn){timers.set(++timerId,fn);return timerId;},clearTimeout(id){timers.delete(id);}};
 vm.runInNewContext(transpileSource(plain),box);return{view:new box.exports.View(),timers,calls,logs};
}
const one=JSON.stringify({devices:[{id:'hub',role:'compute'}]}),two=JSON.stringify({devices:[{id:'hub',role:'compute'},{id:'worker',role:'compute'}]});
(async()=>{
 const first=create();first.view.eventJson=two;first.view.refresh();await flush();assert.equal(first.calls.length,0);
 first.view.pageReady();await flush();assert.equal(first.calls.length,1,'page load delivers the latest roster');

 const queued=create(),pending=deferred();let count=0;
 queued.view.controller={runJavaScript(script){queued.calls.push(script);return ++count===1?pending.promise:Promise.resolve('two');}};
 queued.view.eventJson=one;queued.view.pageReady();await flush();
 queued.view.eventJson=two;queued.view.refreshRevision=1;queued.view.refresh();queued.view.refresh();await flush();
 assert.equal(queued.calls.length,1,'one native evaluation at a time');pending.resolve('one');await flush();
 assert.equal(queued.calls.length,2);assert(queued.calls[1].includes(two),'the second device is delivered after the first evaluation finishes');

 const failed=create();let failures=1;
 failed.view.controller={runJavaScript(script){failed.calls.push(script);return failures-->0?Promise.reject(new Error('web temporarily unavailable')):Promise.resolve('two');}};
 failed.view.eventJson=two;failed.view.pageReady();await flush();assert.equal(failed.timers.size,1);
 const [id,retry]=failed.timers.entries().next().value;failed.timers.delete(id);retry();await flush();
 assert.equal(failed.calls.length,2,'a failed update retries even when the JSON has not changed');assert.equal(failed.timers.size,0);

 const exhausted=create();exhausted.view.controller={runJavaScript(script){exhausted.calls.push(script);return Promise.reject(new Error('unavailable'));}};
 exhausted.view.eventJson=two;exhausted.view.pageReady();await flush();
 while(exhausted.timers.size){const [id,fn]=exhausted.timers.entries().next().value;exhausted.timers.delete(id);fn();await flush();}
 assert.equal(exhausted.calls.length,5,'failure retries are bounded');
 exhausted.view.refreshRevision++;exhausted.view.refresh();await flush();assert.equal(exhausted.calls.length,6,'a fresh authoritative roster can retry identical content');
 exhausted.view.aboutToDisappear();assert.equal(exhausted.timers.size,0);

 const destroyed=create(),late=deferred();destroyed.view.controller={runJavaScript(script){destroyed.calls.push(script);return late.promise;}};
 destroyed.view.pageReady();await flush();destroyed.view.eventJson=two;destroyed.view.refresh();destroyed.view.aboutToDisappear();late.resolve('old page');await flush();
 assert.equal(destroyed.calls.length,1);assert.equal(destroyed.timers.size,0,'stale completion cannot revive a destroyed view');
 console.log('PASS tablet route delivery: preload, latest roster during in-flight update, retry unchanged JSON, bounded retries, fresh-roster recovery and teardown');
})().catch(e=>{console.error(e);process.exitCode=1;});
