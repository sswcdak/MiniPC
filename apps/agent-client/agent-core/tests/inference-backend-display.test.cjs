const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {transpile, transpileSource} = require('../../../../tests/ets-harness.cjs');
const root = path.resolve(__dirname, '../../../..');
function load(relative, requires = {}) {
  const box = {exports: {}, Date, JSON, Math, Number, Map, Set, Uint8Array,
    require: name => requires[name] || {}};
  vm.runInNewContext(transpile(path.join(root, relative)), box);
  return box.exports;
}
const util = {
  TextEncoder: class {encodeInto(text) {return new TextEncoder().encode(text);}},
  TextDecoder: {create: (encoding, options) => ({decodeToString: bytes => new TextDecoder(encoding, options).decode(bytes)})},
  Base64Helper: class {
    encodeToStringSync(bytes) {return Buffer.from(bytes).toString('base64');}
    decodeSync(text) {return new Uint8Array(Buffer.from(text, 'base64'));}
  }
};
const compute = load('apps/compute-node/entry/src/main/ets/protocol/ChatProtocol.ets', {'@kit.ArkTS': {util}});
const tablet = load('apps/agent-client/entry/src/main/ets/protocol/ChatProtocol.ets', {'@kit.ArkTS': {util}});
const {TaskRoutingStore} = load('apps/agent-client/entry/src/main/ets/ui/TaskRoutingStore.ets');
for (const protocol of [compute, tablet]) {
  const base = {protocol: 'nearby-chat-v1', type: 'deviceInfo', requestId: 'backend', capabilities: []};
  assert(protocol.validMessage(base), 'legacy messages remain valid');
  for (const backend of ['', 'gewu', 'llama.cpp', 'qwenvl']) {
    assert(protocol.validMessage({...base, inferenceBackend: backend}));
    assert(protocol.validMessage({...base, type: 'deviceInfoSync', devices: [{id: 'a', inferenceBackend: backend}]}));
  }
  for (const backend of [false, null, 7, 'unknown', 'cloud']) {
    assert(!protocol.validMessage({...base, inferenceBackend: backend}));
    assert(!protocol.validMessage({...base, type: 'deviceInfoSync', devices: [{id: 'a', inferenceBackend: backend}]}));
  }
}

const source = fs.readFileSync(path.join(root, 'apps/compute-node/entry/src/main/ets/pages/Index.ets'), 'utf8');
const start = source.indexOf('  private pollDeviceInfo('), end = source.indexOf('\n  }', start) + 4;
const hostBox = {exports: {}, IS_SERVER: true, Date, JSON, Map};
vm.runInNewContext(transpileSource('class Host {' + source.slice(start, end) + '} exports.Host=Host;'), hostBox);
const host = new hostBox.exports.Host(), sent = [];
const hub = {id: 'hub', role: 'self', slot: 1, ready: true, model: 'Qwen2.5-7B', inferenceBackend: 'gewu'};
const worker = {epoch: 2, peerId: 'worker', deviceUid: 'worker', role: 'compute', slot: 2, ready: true};
const chat = {epoch: 7, peerId: 'chat', deviceUid: 'chat', role: 'chat', slot: 1, ready: true};
Object.assign(host, {serviceReady: true, jobs: [{workerEpoch: 0}], rosterDeliveries: new Map(),
  peerStats: new Map([[2, {model: 'Qwen3-Next-80B-A3B', inferenceBackend: 'llama.cpp'}]]),
  clusterSelfEntry: () => ({...hub}), inferenceLoadStatus: () => ({type: 'deviceInfo', capabilities: []}),
  emitDashboard() {}, channel: {setSelfMem() {}, peerInfos: () => [worker, chat], selfComputeNumber: () => 1,
    operation: () => 1, hasEpoch: () => false,
    send(message, epoch) {
      if (epoch === 7 && message.type === 'deviceInfoSync') {
        const assembler = new tablet.MessageAssembler(); let decoded;
        for (const frame of compute.encodeMessage(message, 'backend_' + (sent.length + 1))) decoded = assembler.receive(frame);
        sent.push(decoded);
      }
      return Promise.resolve(true);
    }
  }});
host.pollDeviceInfo();
assert.equal(sent.length, 1);
assert.equal(sent[0].devices.find(device => device.id === 'worker').inferenceBackend, 'llama.cpp', 'busy compact rosters retain the engine');
const store = new TaskRoutingStore();
store.receive(sent[0], 7, hub);
const calls = [{id: 'task', device: '算力设备2', question: 'test', image: '', phase: 'running', startedAt: 1}];
const snapshot = () => JSON.parse(store.snapshot(calls, '聊天设备1', 'chat', true, 7, hub, 2));
let event = snapshot();
assert.equal(event.devices.find(device => device.id === 'worker').name, '算力设备2', 'logical routing labels stay stable');
assert.equal(event.jobs[0].source, '算力设备2');

const elements = {};
for (const id of ['viewport', 'stage', 'space', 'collaboration', 'detail', 'detailText', 'closeDetail']) {
  elements[id] = {style: {setProperty() {}}, clientWidth: 720, clientHeight: 700, scrollHeight: 700,
    scrollTop: 0, innerHTML: '', addEventListener() {}, querySelectorAll() {return [];}};
}
const renderer = {document: {getElementById: id => elements[id] || null, createElement: () => ({})},
  window: {addEventListener() {}}, Date, Map, Set, JSON, Math, Array, String, Number, setInterval() {}};
const html = fs.readFileSync(path.join(root, 'apps/agent-client/entry/src/main/resources/rawfile/task-routing.html'), 'utf8');
vm.runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], renderer);
function render() {renderer.window.onNativeEvent(snapshot()); return elements.collaboration.innerHTML;}
let markup = render();
assert(markup.includes('算力集群2-Qwen3-80B'));
assert(markup.includes('href="#flow-cluster"'));
assert(markup.includes('算力设备1-Qwen2.5-7B'));
assert(markup.includes('href="#flow-pc"'));
assert(markup.includes('is-computing'), 'tasks still resolve onto a cluster card');
const partial = sent[0].devices.map(device => ({...device}));
delete partial.find(device => device.id === 'worker').inferenceBackend;
store.receive({type: 'deviceInfoSync', devices: partial}, 7, hub);
assert(render().includes('算力集群2-Qwen3-80B'), 'compact legacy updates preserve a known engine');
host.peerStats.get(2).inferenceBackend = 'gewu';
host.pollDeviceInfo();
assert.equal(sent.length, 2, 'backend-only changes trigger a fresh roster even during inference');
store.receive(sent[1], 7, hub);
markup = render();
assert(markup.includes('算力设备2-Qwen3-80B') && !markup.includes('href="#flow-cluster"'), 'GEWU restores the device label and laptop');
store.receive({type: 'deviceInfo', inferenceBackend: 'llama.cpp'}, 7, hub);
assert(render().includes('算力集群1-Qwen2.5-7B'), 'single-device engine telemetry updates the hub card');
store.receive({type: 'deviceInfo', inferenceBackend: ''}, 7, hub);
assert(!render().includes('算力集群1'), 'explicit clearing restores the legacy display');
console.log('PASS backend display across both wire validators, busy roster serialization, backend-only changes, tablet state, cluster artwork and stable task routing');
