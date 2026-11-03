const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const { transpileSource } = require('../../../../tests/ets-harness.cjs');
const root = path.resolve(__dirname, '../../../..');
const source = fs.readFileSync(path.join(root, 'apps/agent-client/entry/src/main/ets/pages/Index.ets'), 'utf8');
function method(name) {
  const lines = source.split('\n');
  const start = lines.findIndex(line => line.startsWith('  private ' + name + '('));
  assert(start >= 0, name);
  let end = start + 1;
  while (end < lines.length && lines[end] !== '  }') end++;
  return lines.slice(start, end + 1).join('\n');
}
const methods = ['openTabletLlamaManager', 'startLlamaManagerRefresh', 'requestLlamaManagerState', 'saveLlamaManagerConfig', 'closeTabletLlamaManager', 'stopLlamaManagerRefresh'];
const flush = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
function harness() {
  let now = 1000;
  const sends = [];
  const channel = { readyEpoch: () => 1, isConnected: () => true, connectedComputeInfo: () => ({ deviceUid: 'hub' }), send(message) {
    const pending = deferred(); sends.push({ message, pending }); return pending.promise;
  } };
  const box = { exports: {}, nearbyChannel: channel, Date: { now: () => now }, setInterval: () => 1, clearInterval() {} };
  vm.runInNewContext(transpileSource('class Page {\n' + methods.map(method).join('\n') + '\n}\nexports.Page=Page;'), box);
  const page = new box.exports.Page();
  Object.assign(page, { llamaManagerRequestId: '', llamaManagerRequestDeadline: 0, llamaManagerRefreshTimer: -1 });
  return { page, sends, channel, advance(ms) { now += ms; } };
}
(async () => {
  const target = harness();
  target.page.openTabletLlamaManager('worker');
  assert.equal(target.sends.length, 0, 'a remote icon must not read or overwrite the hub configuration');
  target.page.openTabletLlamaManager('hub');
  assert.equal(target.page.llamaManagerDeviceId, 'hub');
  assert.equal(target.sends.length, 1);
  const h = harness();
  h.page.requestLlamaManagerState();
  h.page.saveLlamaManagerConfig('{}');
  const saveId = h.page.llamaManagerRequestId;
  h.advance(3000); h.page.requestLlamaManagerState();
  assert.equal(h.sends.length, 2, 'refresh must wait for the save acknowledgement');
  h.sends[0].pending.reject(new Error('late read failure')); await flush();
  assert.equal(h.page.llamaManagerRequestId, saveId, 'old request failure must not clear the newer save');
  h.advance(7001); h.page.requestLlamaManagerState();
  assert.equal(h.sends.length, 3, 'a missing acknowledgement must eventually allow refresh');
  h.page.closeTabletLlamaManager();
  assert.equal(h.page.llamaManagerRequestId, '');
  assert.equal(h.page.llamaManagerRequestDeadline, 0);

  const failed = harness(); failed.page.saveLlamaManagerConfig('{}');
  failed.sends[0].pending.resolve(false); await flush();
  assert.equal(failed.page.llamaManagerRequestId, '');
  assert.match(JSON.parse(failed.page.llamaManagerStateJson).message, /发送失败/);
  failed.channel.isConnected = () => false; failed.page.saveLlamaManagerConfig('{}');
  assert.match(JSON.parse(failed.page.llamaManagerStateJson).message, /未连接/);

  const component = fs.readFileSync(path.join(root, 'apps/agent-client/entry/src/main/ets/ui/TabletLlamaManagerView.ets'), 'utf8');
  const plain = component.slice(0, component.indexOf('  @Builder'))
    .replace('@Component\n', '').replace('export struct TabletLlamaManagerView', 'class View')
    .replace(/@Prop(?: @Watch\('[^']+'\))? |@State /g, '') + '}\nexports.View=View;';
  const box = { exports: {} }; vm.runInNewContext(transpileSource(plain), box);
  const view = new box.exports.View();
  view.focusDeviceId = 'hub';
  view.eventJson = JSON.stringify({ devices: [{ id: 'other', slot: 1, role: 'compute', ready: true },
    { id: 'hub', slot: 3, role: 'compute', ready: true, memTotal: 24 * 2 ** 30, memUsage: 50 }] });
  view.stateJson = JSON.stringify({ config: { model: 'test', peerIp: '10.0.0.2', roleMaster: true },
    models: ['test'], runtime: { state: 'ready', distRank: 0, rss: 2 ** 31 }, peer: { online: false, rank: 1, rss: 0 } });
  view.aboutToAppear();
  assert.equal(view.selectedModel, 'test', 'opening a cached state must initialize the form');
  assert.equal(view.topologyNodes().length, 2, 'only the managed hub and its configured cascade belong to this topology');
  assert.equal(view.topologyNodes()[0].id, 'hub');
  assert.equal(view.topologyNodes()[0].rankLabel, 'rank0', 'nearby slot numbers are not distributed ranks');
  assert.equal(view.actualMemoryBytes(), 2 ** 31, 'an offline peer must not double the measured memory');
  view.stateJson = '{"ok":false,"message":"配置发送失败，请重新保存"}'; view.applyManagerState();
  assert.equal(view.selectedModel, 'test', 'a transport error must keep the last model selection');
  assert.equal(view.runtimeRss, 2 ** 31, 'a transport error is not a new idle telemetry sample');
  view.runtimeRss = 0;
  assert.equal(view.actualMemoryBytes(), 0, 'system-wide memory usage must not masquerade as inference RSS');

  const storeBox = { exports: {} };
  vm.runInNewContext(transpileSource(fs.readFileSync(path.join(root,
    'apps/agent-client/entry/src/main/ets/ui/TaskRoutingStore.ets'), 'utf8')), storeBox);
  const store = new storeBox.exports.TaskRoutingStore();
  assert.equal(JSON.parse(store.snapshot([], 'chat', 'pad', true, 1, { deviceUid: 'hub' })).llamaManagerDeviceId, 'hub');
  assert.equal(JSON.parse(store.snapshot([], 'chat', 'pad', false, 1, { deviceUid: 'hub' })).llamaManagerDeviceId, '');

  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'minipc-routing-'));
  try {
    const files = ['scripts/sync-tablet-routing.cjs', 'apps/agent-client/entry/src/main/resources/rawfile/task-routing.html',
      'apps/compute-node/entry/src/main/resources/rawfile/peer-chat.html'];
    for (const file of files) { const dest = path.join(dir, file); fs.mkdirSync(path.dirname(dest), { recursive: true }); fs.copyFileSync(path.join(root, file), dest); }
    const result = spawnSync(process.execPath, [path.join(dir, files[0])], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    const html = fs.readFileSync(path.join(dir, files[1]), 'utf8');
    assert.match(html, /decorateClusterLinks\(\)/);
    assert.match(html, /window\.routingBridge\.openLlamaManager/);
    assert.match(html, /data-open-llama.*focus-visible/);
    assert.match(html, /flowState\(flowItems\.find/);
    new vm.Script(html.match(/<script>([\s\S]*?)<\/script>/)[1]);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  console.log('PASS Llama management target isolation, measured topology, cached state, save/refresh ordering, stale callbacks, send failure, close cleanup and regenerated routing entry');
})().catch(error => { console.error(error); process.exitCode = 1; });
