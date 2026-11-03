const assert = require('node:assert/strict');
const path = require('node:path');
const vm = require('node:vm');
const { transpile } = require('../../../../../../../tests/ets-harness.cjs');
let stored = null, saveError = '', saves = 0;
const modules = {
  './LlamaSettings': { loadLlamaInferenceConfig: () => stored, saveLlamaInferenceConfig(_dir, config) {
    saves++; if (!saveError) stored = config; return saveError;
  } },
  './ModelRegistry': { readyModelDirs: () => ['gewu', 'llama'], isLlamaLayout: dir => dir.endsWith('/llama') },
  './LlamaPeerStatsService': { llamaPeerStats: { getSnapshot: () => ({ online: false }), refreshConfig() {} } }
};
const box = { exports: {}, require(name) { assert(name in modules, name); return modules[name]; } };
vm.runInNewContext(transpile(path.join(__dirname, 'LlamaRemoteState.ets')), box);
const state = payload => JSON.parse(box.exports.applyLlamaRemoteRequest('/sandbox', '{"state":"ready"}', payload));
const initial = state('{"action":"get"}');
assert.deepEqual(initial.models, ['llama'], 'GEWU and VL layouts cannot be selected for a llama runtime');
assert.equal(initial.config.model, 'llama');
for (const payload of ['{', 'null', '{}', '{"action":"stop"}', '{"action":"save","config":{}}']) {
  assert.equal(state(payload).ok, false, payload);
}
const valid = { action: 'save', config: initial.config };
assert.equal(state(JSON.stringify(valid)).ok, true);
assert.equal(saves, 1);
valid.config.model = 'gewu';
assert.equal(state(JSON.stringify(valid)).ok, false);
assert.equal(saves, 1, 'invalid backend selection must not be persisted');
valid.config.model = 'llama'; saveError = 'disk full';
assert.equal(state(JSON.stringify(valid)).ok, false);
console.log('PASS Llama remote model filtering, default selection, validation, save result and explicit failure status');
