const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {transpile} = require('../../../../tests/ets-harness.cjs');
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
