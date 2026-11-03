const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {transpile, transpileSource} = require('../../../../tests/ets-harness.cjs');
const root = path.resolve(__dirname, '../../entry/src/main');
const box = {exports: {}, require: () => ({}), Date, JSON, Map, Set, Math, Number};
vm.runInNewContext(transpile(path.join(root, 'ets/ui/TaskRoutingStore.ets')), box);
const {TaskRoutingStore} = box.exports;
const hub = {id: 'hub', name: '算力设备1', role: 'compute', slot: 1, ready: true};
const worker = {id: 'worker', name: '算力设备2', role: 'compute', slot: 2, ready: true, model: 'Qwen-VL'};
const view = (store, total, epoch = 7, connected = true, calls = []) =>
  JSON.parse(store.snapshot(calls, '聊天设备1', 'chat', connected, epoch, hub, total));
const computes = event => event.devices.filter(d => d.role === 'compute');
const pending = event => computes(event).filter(d => d.pendingInfo);

const store = new TaskRoutingStore();
store.receive({type: 'deviceInfo', model: 'Qwen-7B', memUsage: 42}, 7, hub);
let event = view(store, 2);
assert.equal(computes(event).length, 2, 'a reported second compute stays visible before its identity arrives');
assert.equal(pending(event).length, 1);
assert.equal(computes(event)[0].model, 'Qwen-7B');
assert.equal(computes(event)[0].memUsage, 42);
assert.equal(pending(event)[0].ready, false);
assert.equal(pending(event)[0].model, undefined);
assert.equal(pending(event)[0].slot, undefined, 'the count cannot supply a real device slot');
assert.equal(pending(event)[0].jobs, 0);
const firstId = pending(event)[0].id;
assert.equal(pending(view(store, 3)).length, 2, 'increasing load count adds only the missing cards');
assert.equal(pending(view(store, 2))[0].id, firstId, 'unchanged fallback cards retain their UI keys');
assert.equal(pending(view(store, 1)).length, 0, 'decreasing counts remove fallback cards');
for (const total of [0, -2, NaN, Infinity, 2.5]) assert.equal(pending(view(store, total)).length, 0);
assert.equal(computes(view(store, 100)).length, 16, 'untrusted aggregate counts stay bounded');

const call = {id: 'job', device: '算力设备2', phase: 'running', question: 'test', image: '', startedAt: 1};
event = view(store, 2, 7, true, [call]);
assert.equal(computes(event).length, 2);
assert.equal(pending(event).length, 0, 'an accepted executor label already accounts for that device');
assert.equal(event.jobs[0].source, '算力设备2');

store.receive({type: 'deviceInfoSync', devices: [hub, worker]}, 7, hub);
event = view(store, 3);
assert.equal(computes(event).length, 2, 'an authoritative roster wins over a stale larger aggregate count');
assert.equal(pending(event).length, 0, 'real membership replaces fallback cards');
assert.equal(computes(event).find(d => d.id === 'worker').model, 'Qwen-VL');
store.receive({type: 'deviceInfoSync', devices: [hub]}, 7, hub);
assert.equal(computes(view(store, 2)).length, 1, 'removed workers must not return as fallback cards');
event = view(store, 2, 8);
assert.equal(pending(event).length, 1, 'a new connection starts its own roster synchronization');
assert.notEqual(pending(event)[0].id, firstId);
assert.equal(computes(view(store, 2, -1, false)).length, 0, 'disconnect clears all compute cards');

// Execute the actual renderer with the store output, including replacement of pending cards.
const elements = {};
for (const id of ['viewport', 'stage', 'space', 'collaboration', 'detail', 'detailText', 'closeDetail']) {
  elements[id] = {style: {setProperty() {}}, clientWidth: 720, clientHeight: 700,
    scrollHeight: 700, scrollTop: 0, innerHTML: '', addEventListener() {}, querySelectorAll() {return [];}};
}
const renderer = {document: {getElementById: id => elements[id] || null, createElement: () => ({})},
  window: {addEventListener() {}}, Date, Map, Set, JSON, Math, Array, String, Number, setInterval() {}};
const html = fs.readFileSync(path.join(root, 'resources/rawfile/task-routing.html'), 'utf8');
vm.runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], renderer);
const legacy = new TaskRoutingStore();
legacy.receive({type: 'deviceInfo', model: 'Qwen-7B'}, 7, hub);
renderer.window.onNativeEvent(view(legacy, 2));
let markup = elements.collaboration.innerHTML;
assert.equal((markup.match(/data-row-key="compute:/g) || []).length, 2);
assert.equal((markup.match(/class="flow-compute is-pending"/g) || []).length, 1);
assert(markup.includes('信息待同步') && markup.includes('已计入在线总数'));
const pendingCard = markup.slice(markup.indexOf('<section class="flow-compute is-pending"'));
assert(!pendingCard.includes('连接中') && !pendingCard.includes('flow-memory'), 'unknown details must not imply a new connection or measured memory');
legacy.receive({type: 'deviceInfoSync', devices: [hub, worker]}, 7, hub);
renderer.window.onNativeEvent(view(legacy, 2));
markup = elements.collaboration.innerHTML;
assert(!markup.includes('is-pending'));
assert(markup.includes('算力设备2-Qwen-VL'));
console.log('PASS tablet roster fallback: missing membership, count changes, bounds, accepted executors, authoritative replacement, reconnect, disconnect and actual HTML rendering');

// The cluster load drives text admission. A third vision-only device belongs in
// the inventory without increasing text concurrency or being counted as busy.
const summaryStore = new TaskRoutingStore();
const textLoad = {idle: 2, total: 2};
assert.equal(summaryStore.summary(textLoad, false), '等待算力连接');
assert.equal(summaryStore.summary(textLoad, true), '文本2/2台，多模态待同步',
  'a text capacity report alone cannot establish the complete device inventory');
const visionHub = {...hub, capabilities: ['vision']};
const llamaWorker = {...worker, capabilities: ['text'], inferenceBackend: 'llama.cpp'};
const textWorker = {id: 'text', role: 'compute', slot: 3, ready: true, capabilities: ['text']};
summaryStore.receive({type: 'deviceInfoSync', devices: [visionHub, llamaWorker, textWorker,
  {id: 'chat', role: 'chat', ready: true}]}, 7, hub);
assert.equal(summaryStore.summary(textLoad, true), '在线3台，文本2/2台，多模态1/1台');
const visionCall = {...call, device: '算力设备1', image: 'image'};
assert.equal(summaryStore.summary(textLoad, true, [visionCall]), '在线3台，文本2/2台，多模态0/1台');
assert.equal(summaryStore.summary(textLoad, true, [{...visionCall, phase: 'queued'}]),
  '在线3台，文本2/2台，多模态1/1台', 'an unassigned queued task does not consume a vision node');
const flow = {key: 'vision-task', revision: 1, kind: 'image', phase: 'running',
  source: '算力设备1', origin: '聊天设备2', executorId: 'hub', elapsed: 1};
summaryStore.receiveFlow({type: 'infer.flow', text: JSON.stringify(flow)});
assert.equal(summaryStore.summary(textLoad, true), '在线3台，文本2/2台，多模态0/1台',
  'another chat client\'s task updates multimodal idle count immediately');
summaryStore.receiveFlow({type: 'infer.flow', text: JSON.stringify({...flow, revision: 2, phase: 'cleared'})});
assert.equal(summaryStore.summary(textLoad, true), '在线3台，文本2/2台，多模态1/1台');
summaryStore.receiveFlow({type: 'infer.flow', text: JSON.stringify({...flow, revision: 3, executionBackend: 'cloud'})});
assert.equal(summaryStore.summary(textLoad, true), '在线3台，文本2/2台，多模态1/1台',
  'cloud execution does not occupy the local multimodal device');
summaryStore.receiveFlow({type: 'infer.flow', text: JSON.stringify({...flow, revision: 4, phase: 'cleared'})});
summaryStore.receive({type: 'deviceInfoSync', devices: [{...visionHub, modelRequests: 1}, llamaWorker, textWorker]}, 7, hub);
assert.equal(summaryStore.summary(textLoad, true), '在线3台，文本2/2台，多模态0/1台');
summaryStore.receive({type: 'deviceInfoSync', devices: [{...visionHub, modelRequests: 0}, llamaWorker, textWorker]}, 7, hub);
assert.equal(summaryStore.summary({idle: 1, total: 2}, true), '在线3台，文本1/2台，多模态1/1台');
assert.equal(summaryStore.summary({idle: 0, total: 0}, true), '在线3台，文本0/0台，多模态1/1台');
summaryStore.receive({type: 'deviceInfoSync', devices: [visionHub, textWorker]}, 7, hub);
assert.equal(summaryStore.summary({idle: 1, total: 1}, true), '在线2台，文本1/1台，多模态1/1台');
summaryStore.receive({type: 'deviceInfoSync', devices: [visionHub, {...textWorker, ready: false}]}, 7, hub);
assert.equal(summaryStore.summary({idle: 0, total: 0}, true), '在线1台，文本0/0台，多模态1/1台');
summaryStore.clear();
assert.equal(summaryStore.summary(textLoad, true), '文本2/2台，多模态待同步', 'reconnect drops the previous inventory');
console.log('PASS tablet summary: inventory versus text capacity, busy work, no text model, membership changes and reconnect');

// Run the page's real refresh path: receiving a roster must refresh the native
// header even if infer.status still reports exactly the same text capacity.
const pageSource = fs.readFileSync(path.join(root, 'ets/pages/Index.ets'), 'utf8');
const refreshStart = pageSource.indexOf('  private refreshRoutingView(');
const refreshEnd = pageSource.indexOf('\n  }', refreshStart) + 4;
let connected = true;
const pageBox = {exports: {}, nearbyChannel: {readyEpoch: () => connected ? 7 : -1,
  isConnected: () => connected, connectedComputeInfo: () => hub, selfLabel: () => '聊天设备1', localUid: () => 'chat'},
  inferenceClient: {clusterLoad: () => textLoad, routingCalls: () => []}};
vm.runInNewContext(transpileSource('class Page {' + pageSource.slice(refreshStart, refreshEnd) + '} exports.Page=Page;'), pageBox);
const page = new pageBox.exports.Page();
page.pageActive = true; page.routingStore = summaryStore; page.deviceInfoPoller = {poll() {}};
summaryStore.receive({type: 'deviceInfoSync', devices: [visionHub, llamaWorker, textWorker]}, 7, hub);
page.refreshRoutingView();
assert.equal(page.clusterSummary, '在线3台，文本2/2台，多模态1/1台');
assert.equal(computes(JSON.parse(page.routingJson)).length, 3);
connected = false; page.refreshRoutingView();
assert.equal(page.clusterSummary, '等待算力连接');
assert.equal(computes(JSON.parse(page.routingJson)).length, 0);
console.log('PASS tablet native header and routing cards refresh from the same roster, including disconnect');
