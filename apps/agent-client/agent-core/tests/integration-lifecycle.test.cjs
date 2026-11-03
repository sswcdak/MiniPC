const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const ts = require(process.env.TYPESCRIPT_PATH || 'D:/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '../..');
function load(relative, imports = {}, globals = {}) {
  const file = path.join(root, relative);
  const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), {fileName: file.replace(/\.ets$/, '.ts'), compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS}, reportDiagnostics: true});
  assert.deepEqual((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error), []);
  const mod = {exports: {}};
  const sandbox = {module: mod, exports: mod.exports, require: name => imports[name] || {}, Error, console, setTimeout, clearTimeout, ...globals};
  vm.runInNewContext(compiled.outputText, sandbox, {filename: file});
  return mod.exports;
}
const agent = file => 'agent-core/src/main/ets/' + file;
const entry = file => 'entry/src/main/ets/model/' + file;
function clientHarness() {
  const sent = [], timers = new Map();
  let timerId = 0, handler, linkHandler, throwSend = false, sendResult;
  const channel = {inferenceReady: () => true, readyEpoch: () => 0, setInferenceHandler: value => {handler = value;},
    setInferenceLinkHandler: value => {linkHandler = value;},
    send: message => {if (throwSend) throw new Error('channel closed'); sent.push(message); return sendResult;}};
  const {inferenceClient: client, INFERENCE_STOPPED: stopped} = load(entry('InferenceClient.ets'), {
    '@kit.PerformanceAnalysisKit': {hilog: {info() {}, warn() {}}},
    '../nearby/LinkEnhanceChannel': {nearbyChannel: channel},
    './InferenceWire': {utf8Bytes: value => Buffer.from(value, 'utf8'), sha256Hex: () => 'hash'},
    './Utf8Repair': {repairUtf8FromSource: value => value}
  }, {setTimeout: callback => {timers.set(++timerId, callback); return timerId;}, clearTimeout: id => timers.delete(id)});
  client.bind();
  return {client, stopped, sent, timers, receive: (message, epoch = 0) => handler(message, epoch),
    dropLink: epoch => linkHandler(epoch), sendResolves: value => {sendResult = value;},
    failSend: () => {throwSend = true;}, resumeSend: () => {throwSend = false;}};
}
const profile = extra => ({ready: true, readinessReason: '', promptFormat: 'loop-react-split-v1', maxPromptBytes: 4096, maxOutputTokens: 2048, maxContextTokens: 32768, modelId: 'test', modelRevision: '1', ...extra});
async function ready(h,extra={}) {
  const pending = h.client.ensureReady();
  h.receive({type: 'infer.capabilities', requestId: h.sent.at(-1).requestId, profiles: [profile(extra)]});
  assert.equal(await pending, '');
}
async function settled(promise) {
  const marker = {};
  const value = await Promise.race([promise, new Promise(resolve => setImmediate(() => resolve(marker)))]);
  assert.notEqual(value, marker, 'promise must already be settled, not left waiting for a cleared timer');
  return value;
}
test('reset settles shared negotiation and rejects stale capability replies', async () => {
  const h = clientHarness(), p = h.client.ensureReady();
  assert.equal(h.client.ensureReady(), p);
  const oldId = h.sent.at(-1).requestId;
  h.client.reset();
  assert.match(await settled(p), /连接已中断/);
  assert.equal(h.timers.size, 0);
  const retry = h.client.ensureReady();
  h.receive({type: 'infer.capabilities', requestId: oldId, profiles: [profile()]});
  assert.equal(h.client.isReady(), false);
  h.receive({type: 'infer.capabilities', requestId: h.sent.at(-1).requestId, profiles: [profile()]});
  assert.equal(await retry, '');
});
test('cancel settles negotiation immediately and permits a fresh attempt', async () => {
  const h = clientHarness(), wait = h.client.ensureReady();
  h.client.cancel();
  assert.equal(await settled(wait), h.stopped);
  assert.equal(h.timers.size, 0);
  await ready(h);
});
test('cancel settles completion even if cancel transport throws and ignores late output', async () => {
  const h = clientHarness(); await ready(h);
  let previews = 0;
  const wait = h.client.complete('hello', {onDelta: () => previews++});
  const id = h.sent.at(-1).requestId;
  const rejection = wait.catch(error => error.message);
  h.failSend(); h.client.cancelActive();
  assert.equal(await settled(rejection), h.stopped);
  h.receive({type: 'infer.delta', requestId: id, seq: 1, text: 'late'});
  assert.equal(previews, 0); assert.equal(h.timers.size, 0);
});
test('reset settles pending completion as connection interruption', async () => {
  const h = clientHarness(); await ready(h);
  const wait = h.client.complete('hello').catch(error => error.message);
  h.client.reset();
  assert.match(await settled(wait), /连接已中断/);
  assert.equal(h.timers.size, 0); assert.equal(h.client.isReady(), false);
});
test('request send exception rejects promptly and permits the next completion', async () => {
  const h=clientHarness(); await ready(h); h.failSend();
  let started=0; const hooks={onStart:()=>started++};
  const failed=h.client.complete('task',hooks).catch(error=>error.message);
  assert.match(await settled(failed),/连接已中断/); assert.equal(h.client.calls.size,0); assert.equal(h.timers.size,0); assert.equal(started,0);
  h.resumeSend(); const next=h.client.complete('retry',hooks).catch(error=>error.message);
  assert.equal(started,1); h.client.cancel(); assert.equal(await settled(next),h.stopped);
});
test('deadline always settles locally when cancellation transport throws', async () => {
  const h=clientHarness(); await ready(h);
  const wait=h.client.complete('task').catch(error=>error.message); const callback=[...h.timers.values()][0];
  h.failSend(); assert.doesNotThrow(()=>callback());
  assert.match(await settled(wait),/推理中断/); assert.equal(h.client.calls.size,0); assert.equal(h.timers.size,0);
});
test('link drop settles the pending request at once and forces renegotiation', async () => {
  const h = clientHarness(); await ready(h);
  const wait = h.client.complete('task').catch(error => error.message);
  h.dropLink(0);
  assert.match(await settled(wait), /连接已中断/); assert.equal(h.timers.size, 0); assert.equal(h.client.isReady(), false);
});
test('output from another link epoch is ignored', async () => {
  const h = clientHarness(); await ready(h);
  const wait = h.client.complete('task'); const id = h.sent.at(-1).requestId;
  h.receive({type: 'infer.error', requestId: id, message: 'stale'}, 7);
  assert.equal(h.client.calls.size, 1);
  h.receive({type: 'infer.error', requestId: id, message: 'current'}, 0);
  await assert.rejects(wait, /current/);
});
test('asynchronous send failure rejects instead of waiting for the deadline', async () => {
  const h = clientHarness(); await ready(h); h.sendResolves(Promise.resolve(false));
  const wait = h.client.complete('task').catch(error => error.message);
  assert.match(await wait, /连接已中断/); assert.equal(h.client.calls.size, 0);
});
test('next request waits for the host to acknowledge a stop', async () => {
  const h = clientHarness(); await ready(h);
  const first = h.client.complete('one').catch(error => error.message); const id = h.sent.at(-1).requestId;
  h.receive({type: 'infer.accepted', requestId: id});
  h.client.cancelActive(); assert.equal(await first, h.stopped); assert.equal(h.client.isStopping(), true);
  const before = h.sent.length; const second = h.client.complete('two');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.sent.filter(m => m.type === 'infer.request').length, 1);
  h.receive({type: 'infer.error', requestId: id, code: 'CANCELLED', message: 'stopped'});
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.client.isStopping(), false); assert.ok(h.sent.length > before);
  const nextId = h.sent.at(-1).requestId; assert.notEqual(nextId, id);
  h.receive({type: 'infer.error', requestId: nextId, message: 'end'}); await assert.rejects(second, /end/);
});
test('split-capable host receives developer and user turns instead of one prompt', async () => {
  const h = clientHarness();
  const pending = h.client.ensureReady();
  h.receive({type: 'infer.capabilities', requestId: h.sent.at(-1).requestId, profiles: [profile({splitMessages: true})]});
  assert.equal(await pending, '');
  h.client.complete('flat', {}, {system: 'rules', user: 'User task:\nq'}).catch(() => {});
  const request = h.sent.at(-1);
  assert.equal(request.prompt, undefined);
  assert.deepEqual(JSON.parse(JSON.stringify(request.messages)), [{role: 'developer', content: 'rules'}, {role: 'user', content: 'User task:\nq'}]);
  h.client.cancel();
});
const reqs = h => h.sent.filter(m => m.type === 'infer.request');
const fireAll = h => { for (const [id, fn] of Array.from(h.timers)) { h.timers.delete(id); fn(); } };
test('several requests can be in flight and complete independently', async () => {
  const h = clientHarness(); await ready(h);
  const a = h.client.complete('a'), b = h.client.complete('b');
  const [ra, rb] = reqs(h); assert.notEqual(ra.requestId, rb.requestId); assert.equal(h.client.calls.size, 2);
  for (const [r, text] of [[rb, 'B'], [ra, 'A']]) {
    h.receive({type: 'infer.accepted', requestId: r.requestId});
    h.receive({type: 'infer.delta', requestId: r.requestId, seq: 1, text});
    h.receive({type: 'infer.done', requestId: r.requestId, lastSeq: 1, outputUtf8Bytes: 1, outputSha256: 'hash', finishReason: 'stop'});
  }
  assert.deepEqual([await a, await b], ['A', 'B']); assert.equal(h.client.calls.size, 0);
});
test('a request refused for lack of an idle device waits and is re-sent under a new id', async () => {
  const h = clientHarness(); await ready(h);
  const wait = h.client.complete('task'); const first = reqs(h)[0].requestId;
  h.receive({type: 'infer.error', requestId: first, code: 'BUSY', message: 'busy', retryable: true});
  assert.equal(h.client.calls.size, 0); assert.equal(h.timers.size, 1);
  fireAll(h);
  const again = reqs(h); assert.equal(again.length, 2); assert.notEqual(again[1].requestId, first);
  h.receive({type: 'infer.accepted', requestId: again[1].requestId, device: '算力设备2'});
  h.receive({type: 'infer.delta', requestId: again[1].requestId, seq: 1, text: 'ok'});
  h.receive({type: 'infer.done', requestId: again[1].requestId, lastSeq: 1, outputUtf8Bytes: 2, outputSha256: 'hash', finishReason: 'stop'});
  assert.equal(await wait, 'ok');
});
test('an idle report releases waiting requests without waiting for the retry timer', async () => {
  const h = clientHarness(); await ready(h);
  const wait = h.client.complete('task').catch(error => error.message); const first = reqs(h)[0].requestId;
  h.receive({type: 'infer.error', requestId: first, code: 'BUSY', message: 'busy', retryable: true});
  h.receive({type: 'infer.status', requestId: 'cluster', cluster: {idle: 1, total: 2}});
  assert.equal(reqs(h).length, 2); assert.deepEqual(JSON.parse(JSON.stringify(h.client.clusterLoad())), {idle: 1, total: 2});
  h.client.cancel(); assert.equal(await wait, h.stopped);
});
test('a failure after acceptance is never re-sent', async () => {
  const h = clientHarness(); await ready(h);
  const wait = h.client.complete('task').catch(error => error.message); const id = reqs(h)[0].requestId;
  h.receive({type: 'infer.accepted', requestId: id});
  h.receive({type: 'infer.error', requestId: id, code: 'WORKER_LOST', message: 'lost', retryable: false});
  assert.equal(await wait, 'lost'); fireAll(h); assert.equal(reqs(h).length, 1);
});
test('cancelling a waiting request needs no host stop and does not block the next request', async () => {
  const h = clientHarness(); await ready(h);
  const wait = h.client.complete('task').catch(error => error.message); const id = reqs(h)[0].requestId;
  h.receive({type: 'infer.error', requestId: id, code: 'BUSY', message: 'busy', retryable: true});
  h.client.cancel(); assert.equal(await wait, h.stopped);
  assert.equal(h.client.isStopping(), false); assert.equal(h.sent.filter(m => m.type === 'infer.cancel').length, 0);
});
test('cancelOwner stops only that owner and reports the executing device', async () => {
  const h = clientHarness(); await ready(h);
  const devices = [];
  const a = h.client.complete('a', {owner: 'A', onAccepted: d => devices.push(d)}).catch(error => error.message);
  const b = h.client.complete('b', {owner: 'B'});
  const [ra, rb] = reqs(h);
  h.receive({type: 'infer.accepted', requestId: ra.requestId, device: '算力设备2'});
  h.client.cancelOwner('A'); assert.equal(await a, h.stopped);
  assert.deepEqual(devices, ['算力设备2']);
  assert.deepEqual(h.sent.filter(m => m.type === 'infer.cancel').map(m => m.requestId), [ra.requestId]);
  assert.equal(h.client.calls.size, 1);
  h.receive({type: 'infer.delta', requestId: rb.requestId, seq: 1, text: 'B'});
  h.receive({type: 'infer.done', requestId: rb.requestId, lastSeq: 1, outputUtf8Bytes: 1, outputSha256: 'hash', finishReason: 'stop'});
  assert.equal(await b, 'B');
});
test('capabilities carry the cluster load that infer.status later updates', async () => {
  const h = clientHarness(); await ready(h);
  assert.deepEqual(JSON.parse(JSON.stringify(h.client.clusterLoad())), {idle: 1, total: 1});
  let notified = 0; h.client.setLoadListener(() => notified++);
  h.receive({type: 'infer.status', requestId: 'cluster', cluster: {idle: 0, total: 3}});
  assert.deepEqual(JSON.parse(JSON.stringify(h.client.clusterLoad())), {idle: 0, total: 3}); assert.equal(notified, 1);
});
test('capability failure preserves readinessReason and prefers ready alternative', async () => {
  const h = clientHarness();
  let wait = h.client.ensureReady();
  h.receive({type: 'infer.capabilities', requestId: h.sent.at(-1).requestId, profiles: [profile({ready: false, readinessReason: '模型仍在加载'})]});
  assert.equal(await wait, '模型仍在加载'); assert.equal(h.client.statusText(), '模型仍在加载');
  assert.equal(h.client.isReady(), false);
  wait = h.client.ensureReady();
  h.receive({type: 'infer.capabilities', requestId: h.sent.at(-1).requestId, profiles: [profile({ready: false, readinessReason: '模型仍在加载'}), profile()]});
  assert.equal(await wait, ''); assert.equal(h.client.isReady(), true);
});
test('capability send failure settles waiter without timer leak', async () => {
  const h = clientHarness(); h.failSend();
  assert.match(await settled(h.client.ensureReady()), /连接已中断/); assert.equal(h.timers.size, 0);
});
test('RemoteComputeModel forwards complete and optional cancellation', async () => {
  const calls = [];
  const {RemoteComputeModel} = load(entry('RemoteComputeModel.ets'), {'@loop/agent-core': {splitReActPrompt: () => null}, './InferenceClient': {inferenceClient: {complete: prompt => {calls.push(prompt); return Promise.resolve('ok');}, cancel: () => calls.push('cancel')}}});
  const model = new RemoteComputeModel();
  assert.equal(await model.complete('task'), 'ok'); model.cancel(); assert.deepEqual(calls, ['task', 'cancel']);
});
const events = load(agent('agent/AgentEvent.ets'));
test('AgentEvent preserves old constructor and exposes optional call metadata', () => {
  const old = new events.AgentEvent(events.AgentEventKind.FINAL, 'answer');
  assert.equal(old.callId, undefined); assert.equal(old.text, 'answer');
  const value = new events.AgentEvent(events.AgentEventKind.OBSERVATION, 'shown', 'c1', 'read', '{}', 'success');
  assert.equal(value.callId, 'c1'); assert.equal(value.toolName, 'read'); assert.equal(value.input, '{}'); assert.equal(value.status, 'success');
});
function registryHarness() {
  const tool = load(agent('agent/AgentTool.ets'));
  const {ToolRegistry} = load(agent('agent/ToolRegistry.ets'), {
    './ToolContract': load(agent('agent/ToolContract.ets')),
    './AgentTool': tool, './A2uiObservationDigest': {summarizeA2uiObservation: value => ({isA2ui: value === 'jsonl', text: 'bounded digest', finalText: 'safe final', shouldStop: false})}
  });
  return new ToolRegistry();
}
const fixture = (name, run = async () => 'ok') => ({name: () => name, description: () => 'description', run});
test('registry defaults deny parallel/cache and registration policy cannot be forged by returned metadata', async () => {
  const registry = registryHarness();
  registry.register(fixture('x', async () => ({callId: 'forged', status: 'success', raw: 'ok', displayText: 'ok', metadata: {name: 'x', readOnly: true, supportsParallel: true, cacheable: true, risk: 'low'}})));
  const result = await registry.run('x', '', 'real');
  assert.equal(result.callId, 'real'); assert.equal(result.metadata.risk, 'high');
  assert.equal(result.metadata.cacheable, false); assert.equal(result.metadata.supportsParallel, false);
  registry.register(fixture('x'), {readOnly: true, supportsParallel: true, cacheable: true, risk: 'low'});
  assert.equal(registry.metadata('x').cacheable, true);
  registry.register(fixture('x')); assert.equal(registry.metadata('x').cacheable, false);
  registry.register(fixture('x'), {readOnly: false, supportsParallel: true, cacheable: true, risk: 'low'});
  assert.equal(registry.metadata('x').supportsParallel, false); assert.equal(registry.metadata('x').cacheable, false);
});
test('registry preserves A2UI digest and final hint while retaining raw for diagnostics', async () => {
  const registry = registryHarness(); registry.register(fixture('a2ui', async () => 'jsonl'));
  const result = await registry.run('a2ui', '', 'c1');
  assert.equal(result.displayText, 'bounded digest'); assert.equal(result.finalText, 'safe final'); assert.equal(result.raw, 'jsonl');
});
test('registry turns thrown failures into returned=false control results', async () => {
  const registry = registryHarness(); registry.register(fixture('fail', async () => {throw new Error('broken');}));
  const result = await registry.run('fail', '', 'c1');
  assert.equal(result.callId, 'c1'); assert.equal(result.status, 'failed'); assert.equal(result.returned, false);
});
async function backendRun(sequence) {
  class Runner {async run(_prompt, listener) {for (const value of sequence) listener(value);}}
  const {LoopBackend} = load(agent('aiphone/LoopBackend.ets'), {
    '../agent/AgentEvent': events, '../agent/ReActAgentRunner': {ReActAgentRunner: Runner},
    './AiphoneA2ui': {aiphoneInfoJsonl: () => '', splitJsonl: () => []}
  });
  const backend = new LoopBackend();
  backend.buildConversation = () => ({}); backend.buildModel = () => ({}); backend.buildToolRegistry = () => ({});
  return backend.run({prompt: 'test', maxSteps: 2}, {});
}
const event = (kind, text, callId, toolName, input, status) => new events.AgentEvent(kind, text, callId, toolName, input, status);
test('backend associates reverse-order same-tool observations by callId', async () => {
  const out = await backendRun([event('ACTION', 'read(one)', 'a', 'read', 'one'), event('ACTION', 'read(two)', 'b', 'read', 'two'), event('OBSERVATION', 'B', 'b'), event('OBSERVATION', 'A', 'a')]);
  assert.equal(out.toolCalls[0].input, 'two'); assert.equal(out.toolCalls[1].input, 'one');
});
test('backend legacy multi-call FIFO never reuses the most recent action', async () => {
  const out = await backendRun([event('ACTION', 'read(one)'), event('ACTION', 'read(two)'), event('OBSERVATION', 'A'), event('OBSERVATION', 'B')]);
  assert.equal(out.toolCalls[0].input, 'one'); assert.equal(out.toolCalls[1].input, 'two');
});
test('backend unknown IDs cannot consume another pending call and tool errors remain traced', async () => {
  const out = await backendRun([event('ACTION', 'read(one)', 'a'), event('ACTION', 'read(two)', 'b'), event('OBSERVATION', 'unknown', 'z'), event('ERROR', 'failed', 'b', 'read', undefined, 'failed'), event('OBSERVATION', 'A', 'a')]);
  assert.equal(out.toolCalls[0].input, ''); assert.equal(out.toolCalls[1].input, 'two'); assert.equal(out.toolCalls[2].input, 'one'); assert.equal(out.ok, false);
});

test('central queue admission keeps one wire request, no BUSY polling and no invented executor',async()=>{
 const h=clientHarness();await ready(h,{centralQueue:true});const phases=[];
 const result=h.client.complete('image request',{onPhase:phase=>phases.push(phase)},null,'aGVsbG8=').catch(e=>e.message);
 const id=reqs(h)[0].requestId;
 h.receive({type:'infer.accepted',requestId:id,state:'queued',source:'hub-queue',device:''});
 assert.equal(h.client.routingCalls()[0].phase,'routing');assert.equal(h.client.routingCalls()[0].device,'');assert.equal(phases.at(-1),'hub-queued');
 h.receive({type:'infer.status',requestId:'cluster',cluster:{idle:1,total:2}});
 h.receive({type:'infer.status',requestId:id,state:'queued',source:'hub-queue',device:''});
 assert.equal(reqs(h).length,1);assert.equal(h.client.waitingCalls.length,0);
 h.receive({type:'infer.accepted',requestId:id,state:'queued',device:'算力设备3'});
 assert.equal(h.client.routingCalls()[0].phase,'queued');assert.equal(h.client.routingCalls()[0].device,'算力设备3');
 h.receive({type:'infer.accepted',requestId:id,state:'queued',source:'hub-queue',device:''});
 assert.equal(h.client.routingCalls()[0].device,'','a BUSY reassignment clears the old executor');
 h.client.cancel();h.receive({type:'infer.error',requestId:id,code:'CANCELLED'});assert.equal(await result,h.stopped);
 assert.equal(reqs(h).length,1);
});
test('new hub accepts five concurrent requests and does not hold another owner behind a stop acknowledgement',async()=>{
 const h=clientHarness();await ready(h,{centralQueue:true});const pending=[];
 for(let i=0;i<5;i++)pending.push(h.client.complete('task '+i,{owner:'owner'+i}).catch(e=>e.message));
 assert.equal(reqs(h).length,5);assert.equal(h.client.routingCalls().length,5);
 const first=reqs(h)[0].requestId;h.client.cancelOwner('owner0');
 const extra=h.client.complete('new task',{owner:'new'}).catch(e=>e.message);
 assert.equal(reqs(h).length,6,'other owners can submit while one request is stopping');
 h.receive({type:'infer.error',requestId:first,code:'CANCELLED'});h.client.cancel();
 await Promise.all(pending);await extra;
});
test('BUSY from a new center is a terminal error rather than a hidden retry loop',async()=>{
 const h=clientHarness();await ready(h,{centralQueue:true});const result=h.client.complete('task').catch(e=>e.message),id=reqs(h)[0].requestId;
 h.receive({type:'infer.error',requestId:id,code:'BUSY',message:'unexpected BUSY',retryable:true});
 assert.equal(await result,'unexpected BUSY');fireAll(h);assert.equal(reqs(h).length,1);assert.equal(h.client.waitingCalls.length,0);
});
