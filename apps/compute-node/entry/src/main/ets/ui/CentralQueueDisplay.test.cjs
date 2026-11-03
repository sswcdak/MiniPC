// Actual hub projection keeps queued work unassigned and restores task metadata at dispatch.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {transpileSource}=require('../../../../../../../tests/ets-harness.cjs');
const source=fs.readFileSync(path.join(__dirname,'../pages/Index.ets'),'utf8'),start=source.indexOf('  private showQueuedInference('),end=source.indexOf('\n  }',start)+4;
const box={exports:{},Date,chatLabel:()=> '聊天设备1'};
vm.runInNewContext(transpileSource('class Index {static jobKey(e,id){return e+":"+id}\n'+source.slice(start,end)+'} exports.Page=Index;'),box);
const page=new box.exports.Page();Object.assign(page,{jobs:[{key:'5:r',endedAt:0},{key:'6:other',endedAt:0}],queuedJobs:new Map(),taskLinks:new Map(),channel:{peerInfos:()=>[{epoch:5,deviceUid:'chat-uid'}]},inferQuestion:(_input,label)=>label,jobImage:image=>image,emitDashboard(){}});
const req={requestId:'r',taskId:'task',subtaskId:'child',prompt:'full input',label:'图片分析',origin:'聊天设备1',image:'AA=='};
page.showQueuedInference(req,5,true);const view=page.queuedJobs.get('5:r');
assert.equal(view.source,'');assert.equal(view.executorId,undefined);assert.equal(view.phase,'queued');assert.equal(view.originId,'chat-uid');assert.equal(view.groupKey,'5:task');assert.equal(view.kind,'image');
assert.equal(page.jobs.length,1);assert.equal(page.jobs[0].key,'6:other','another origin is untouched');
page.taskLinks.clear();page.showQueuedInference(req,5,false,true);
assert.equal(page.queuedJobs.size,0);assert.equal(page.taskLinks.get('5:r').taskId,'task');assert.equal(page.taskLinks.get('5:r').subtaskId,'child');assert.equal(page.taskLinks.get('5:r').input,'full input','dispatch restores original metadata even if display cache was evicted');
page.showQueuedInference(req,5,true);page.showQueuedInference(req,5,false);
assert.equal(page.queuedJobs.size,0);assert.equal(page.taskLinks.size,0,'terminal queued cleanup retains no task link');
console.log('PASS hub waiting projection: unknown executor, origin identity, original task/child metadata after cache eviction, independent jobs and terminal cleanup');
