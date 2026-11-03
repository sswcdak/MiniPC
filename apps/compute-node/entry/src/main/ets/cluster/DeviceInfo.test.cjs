// node DeviceInfo.test.cjs [path/to/typescript/lib/typescript.js]
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { transpile } = require('../../../../../../../tests/ets-harness.cjs');
const kits = {
  mem: { totalMem: 2000, availableMem: 800 },
  cpu: 0.18,
  thermal: 2,
  battery: 421
};
// 模型发现由 llm/ModelRegistry 提供并有专项测试；这里用可变状态验证委托语义。
let registryDirs = [];
let selectedModel = '';
let unionCaps = [];
let registryTier = 0;
let llamaConfig = null;
let llamaModel = '';
let llamaLayout = false;
let textDir = '';
let visionDir = '';
const context = {
  exports: {}, Error, Map, Math, Number, Date,
  require(name) {
    if (name === '@kit.PerformanceAnalysisKit') {
      return {
        hidebug: {
          getSystemMemInfo() { return kits.mem; },
          getSystemCpuUsage() { return kits.cpu; }
        }
      };
    }
    if (name === '@kit.BasicServicesKit') {
      return {
        batteryInfo: { get batteryTemperature() { return kits.battery; } },
        thermal: { getLevel() { return kits.thermal; } }
      };
    }
    if (name === '../llm/ModelRegistry') {
      return {
        activeModelDirs: () => registryDirs.slice(),
        modelSelection: () => ({model: selectedModel}),
        selectModelDir: (_filesDir, needs) => needs.length > 0 ? visionDir : textDir,
        isLlamaLayout: () => llamaLayout,
        deviceCapabilities: () => unionCaps.slice(),
        deviceTier: () => registryTier
      };
    }
    if (name === '../llm/LlamaSettings') return {
      loadLlamaInferenceConfig: () => llamaConfig,
      configuredLlamaModel: () => llamaModel
    };
    return {};
  }
};
vm.runInNewContext(transpile(__dirname + '/DeviceInfo.ets'), context);
const { DEVICE_INFO_POLL_MS, sampleMemory, formatHeat, thermalLabel, toDeviceInfoReply, formatComputeStatus,
  buildSelfEntry, deployedCapabilities, deployedModelName, deployedInferenceBackend, applyDeviceInfo } = context.exports;
assert.equal(DEVICE_INFO_POLL_MS, 2000);
assert.equal(thermalLabel(0), '清凉');
assert.equal(thermalLabel(2), '温热');
assert.equal(thermalLabel(7), '逃生');
assert.equal(thermalLabel(-1), '');
assert.equal(formatHeat(42, 2), '42℃ · 温热');
assert.equal(formatHeat(-1, 1), '正常');
assert.equal(formatHeat(38, -1), '38℃');
const sampled = sampleMemory();
assert.equal(sampled.memUsage, 60);
assert.equal(sampled.thermalLevel, 2);
assert.equal(sampled.batteryTemp, 42.1);
assert.equal(sampled.cpuUsage, 18);
const reply = toDeviceInfoReply('info-1', {
  name: '算力', memTotal: 2000, memAvail: 800, memUsage: 60,
  thermalLevel: 2, batteryTemp: 42.1, cpuUsage: 18, model: 'Qwen', modelRequests: 1,
  capabilities: ['text', 'vision']
});
assert.equal(reply.thermalLevel, 2);
assert.equal(reply.batteryTemp, 42.1);
assert.equal(reply.cpuUsage, 18);
assert.equal(reply.capabilities.join(','), 'text,vision', 'deviceInfo reply carries capabilities');
assert.equal(formatComputeStatus(reply), 'Qwen · 内存 60% · 42.1℃ · 温热 · CPU 18% · 推理 1');
// Device-card names follow automatic/manual selection; capabilities remain unchanged.
assert.equal(deployedModelName('/app'), '', 'no ready dir means no model');
assert.equal(deployedCapabilities('/app').join(','), '', 'no model ready means no capabilities');
assert.equal(buildSelfEntry('/app', 0, '本机', 'self').capabilities.join(','), '');
registryDirs = ['Qwen2.5-7B-Instruct-Q4_N_0'];
unionCaps = ['text'];
assert.equal(buildSelfEntry('/app', 0, '本机', 'self').model, 'Auto', 'automatic mode is explicit even with one ready model');
selectedModel = registryDirs[0];
assert.equal(buildSelfEntry('/app', 0, '本机', 'self').model, 'Qwen2.5-7B-Instruct-Q4_N_0');
assert.equal(deployedCapabilities('/app').join(','), 'text');
registryDirs = ['Qwen2.5-7B-Instruct-Q4_N_0', 'Qwen2.5-VL-7B-Q4_N_0'];
unionCaps = ['text', 'vision'];
selectedModel = '';
assert.equal(deployedModelName('/app'), 'Auto', 'automatic text/image selection does not masquerade as one specific model');
assert.equal(toDeviceInfoReply('auto', buildSelfEntry('/app', 0, '本机', 'self')).model, 'Auto', 'Auto reaches peers through deviceInfo');
selectedModel = registryDirs[0];
assert.equal(deployedModelName('/app'), registryDirs.join(' / '), 'display includes all active models');
assert.equal(buildSelfEntry('/app', 0, '本机', 'self').capabilities.join(','), 'text,vision',
  'device capability is the union across deployed models');
registryDirs = ['A'.repeat(100), 'B'.repeat(100)];
assert.equal(deployedModelName('/app').length, 128, 'multiple model names stay within the deviceInfo wire limit');
// 档位上报：无模型省略字段；有声明带上；reply 透传；applyDeviceInfo 只拷合法值（旧构建的 3 归一为 2）
assert.equal(buildSelfEntry('/app', 0, '本机', 'self').modelTier, undefined,
  'no ready model omits modelTier (old-peer semantics)');
registryTier = 2;
assert.equal(buildSelfEntry('/app', 0, '本机', 'self').modelTier, 2);
assert.equal(toDeviceInfoReply('info-2', buildSelfEntry('/app', 0, '本机', 'self')).modelTier, 2,
  'deviceInfo reply carries the declared tier');
registryTier = 0;
assert.equal(toDeviceInfoReply('info-3', buildSelfEntry('/app', 0, '本机', 'self')).modelTier, undefined,
  'reply omits the field when undeclared');
const peer = { role: 'compute', capabilities: [] };
applyDeviceInfo(peer, { modelTier: 2 });
assert.equal(peer.modelTier, 2);
applyDeviceInfo(peer, { modelTier: 3 });
assert.equal(peer.modelTier, 2, 'legacy 3 from an old build normalizes to strong 2');
applyDeviceInfo(peer, { modelTier: 1 });
assert.equal(peer.modelTier, 1);
for (const bad of [5, 0, '3', 2.5]) {
  applyDeviceInfo(peer, { modelTier: bad });
  assert.equal(peer.modelTier, 1, 'out-of-range modelTier is ignored: ' + JSON.stringify(bad));
}
console.log('PASS: thermal/battery/CPU sampling, heat label, deviceInfo reply fields, registry delegation, tier reporting');
assert.equal(deployedInferenceBackend('/app'), '');
textDir = 'GEWU';
assert.equal(deployedInferenceBackend('/app'), 'gewu');
llamaLayout = true;
assert.equal(deployedInferenceBackend('/app'), 'llama.cpp');
textDir = ''; visionDir = 'VL';
assert.equal(deployedInferenceBackend('/app'), 'qwenvl');
llamaModel = '/app/models/managed.gguf';
assert.equal(deployedInferenceBackend('/app'), 'llama.cpp', 'manager configuration has execution priority');
const managed = buildSelfEntry('/app', 0, 'device', 'id');
assert.equal(managed.inferenceBackend, 'llama.cpp');
assert.equal(toDeviceInfoReply('backend', managed).inferenceBackend, 'llama.cpp');
applyDeviceInfo(peer, {inferenceBackend: 'llama.cpp'});
assert.equal(peer.inferenceBackend, 'llama.cpp');
applyDeviceInfo(peer, {modelRequests: 0});
assert.equal(peer.inferenceBackend, 'llama.cpp', 'legacy telemetry preserves a known engine');
applyDeviceInfo(peer, {inferenceBackend: ''});
assert.equal(peer.inferenceBackend, '', 'explicit empty backend clears a previous selection');
llamaConfig = {model: 'managed.gguf', peerIp: '192.0.2.2', roleMaster: false};
assert.equal(deployedCapabilities('/app').length, 0, 'llama followers do not advertise independent text work');
console.log('PASS: configured engine declaration, GGUF fallback, VL-only backend, wire propagation and follower capabilities');
