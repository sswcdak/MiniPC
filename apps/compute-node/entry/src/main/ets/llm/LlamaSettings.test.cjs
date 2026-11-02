const assert = require('node:assert/strict');
const vm = require('node:vm');
const { transpile } = require('../../../../../../../tests/ets-harness.cjs');

const context = { exports: {}, require(name) {
  if (name === '@kit.CoreFileKit') return { fileIo: {} };
  return {};
} };
vm.runInNewContext(transpile(__dirname + '/LlamaSettings.ets'), context);
const { llamaRuntimeOptions } = context.exports;

const base = {
  model: 'Qwen3-Next-80B-A3B-Instruct-Q4_K_M',
  contextSize: 4096,
  otherArgs: '--memory-budget 14336',
  hotCold: true,
  expertSkip: true,
  skipRange: '5:20',
  distMode: 'layer',
  peerIp: '',
  roleMaster: true,
  port: 8080
};

const hotCold = llamaRuntimeOptions('/files', base, 4096);
assert.equal(hotCold.ffnHotCold, true);
assert.equal(hotCold.useExtraBufts, false,
  'hot/cold mode must disable runtime repack like llama-server-ohos -rea off');
assert.equal(hotCold.memoryBudgetMb, 14336);
assert.equal(hotCold.moeSkipK1, 5);
assert.equal(hotCold.moeSkipK2, 20);
assert.equal(hotCold.nBatch, 2048);
assert.equal(hotCold.nUbatch, 512);
assert.equal(hotCold.nSeqMax, 1);
assert.equal(hotCold.distRanks, 1);

const rank0 = llamaRuntimeOptions('/files', { ...base, peerIp: '192.168.0.210' }, 4096, '192.168.0.200');
assert.equal(rank0.distRanks, 2);
assert.equal(rank0.distRank, 0);
assert.equal(rank0.distFollower, false);
assert.equal(rank0.distEndpoints, '192.168.0.200:30001,192.168.0.210:30001');
assert.equal(rank0.distSplit, 'layer');

const rank1 = llamaRuntimeOptions('/files', {
  ...base, peerIp: '192.168.0.200', distMode: 'expert'
}, 4096, '192.168.0.210');
assert.equal(rank1.distRank, 1);
assert.equal(rank1.distFollower, true);
assert.equal(rank1.distEndpoints, rank0.distEndpoints);
assert.equal(rank1.distSplit, 'expert');

assert.equal(llamaRuntimeOptions('/files', {
  ...base, otherArgs: '--memory-budget 1024 --extra-bufts'
}, 4096).useExtraBufts, true, 'explicit extra-bufts can override the hot/cold default');
assert.equal(llamaRuntimeOptions('/files', {
  ...base, hotCold: false, otherArgs: '-rea off'
}, 4096).useExtraBufts, false, 'the original llama-server repack flag is honored');
assert.equal(llamaRuntimeOptions('/files', {
  ...base, hotCold: true, otherArgs: '-rea on'
}, 4096).useExtraBufts, true);

console.log('PASS: llama hot/cold runtime options match llama-server-ohos repack behavior');
