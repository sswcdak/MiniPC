import {
  LlamaInferenceConfig,
  loadLlamaInferenceConfig,
  saveLlamaInferenceConfig
} from './LlamaSettings';
import { readyModelDirs } from './ModelRegistry';
import { llamaPeerStats, LlamaPeerTelemetry } from './LlamaPeerStatsService';

interface LlamaRemoteRequest {
  action: string;
  config?: LlamaInferenceConfig;
}

interface LlamaRemoteState {
  ok: boolean;
  message: string;
  models: string[];
  config: LlamaInferenceConfig;
  runtime: LlamaRemoteRuntime;
  peer: LlamaPeerTelemetry;
}

interface LlamaRemoteRuntime {
  state: string;
  rss?: number;
  expertRam?: number;
  disk?: number;
  hit?: number;
  error?: string;
}

function defaultConfig(models: string[]): LlamaInferenceConfig {
  return {
    model: models.length > 0 ? models[0] : '',
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
}

function validConfig(config: LlamaInferenceConfig | undefined, models: string[]): boolean {
  if (config === undefined || config === null) return false;
  return typeof config.model === 'string' && models.includes(config.model) &&
    Number.isInteger(config.contextSize) && config.contextSize >= 512 && config.contextSize <= 32768 &&
    typeof config.otherArgs === 'string' && config.otherArgs.length <= 2048 &&
    typeof config.hotCold === 'boolean' && typeof config.expertSkip === 'boolean' &&
    typeof config.skipRange === 'string' && config.skipRange.length <= 32 &&
    (config.distMode === 'layer' || config.distMode === 'expert' || config.distMode === 'neuron') &&
    typeof config.peerIp === 'string' && config.peerIp.length <= 64 &&
    typeof config.roleMaster === 'boolean' &&
    Number.isInteger(config.port) && config.port >= 1 && config.port <= 65535;
}

export function buildLlamaRemoteState(filesDir: string, runtimeJson: string, message: string = ''): string {
  const models = readyModelDirs(filesDir);
  const saved = loadLlamaInferenceConfig(filesDir);
  const config = saved !== null ? saved : defaultConfig(models);
  if (saved !== null && !models.includes(saved.model)) {
    config.model = models.length > 0 ? models[0] : '';
  }
  let runtime: LlamaRemoteRuntime = { state: 'idle' };
  try {
    const parsed = JSON.parse(runtimeJson) as LlamaRemoteRuntime;
    if (parsed !== null && typeof parsed === 'object' && typeof parsed.state === 'string') {
      runtime = parsed;
    }
  } catch (_error) {
    // Keep the explicit idle state when the native probe has no JSON payload.
  }
  const state: LlamaRemoteState = {
    ok: message.length === 0 || !message.includes('失败'),
    message: message,
    models: models,
    config: config,
    runtime: runtime,
    peer: llamaPeerStats.getSnapshot()
  };
  return JSON.stringify(state);
}

export function applyLlamaRemoteRequest(filesDir: string, runtimeJson: string, payload: string): string {
  try {
    const request = JSON.parse(payload) as LlamaRemoteRequest;
    if (request === null || typeof request !== 'object' || typeof request.action !== 'string') {
      return buildLlamaRemoteState(filesDir, runtimeJson, '管理请求格式无效');
    }
    if (request.action === 'get') {
      return buildLlamaRemoteState(filesDir, runtimeJson);
    }
    if (request.action !== 'save') {
      return buildLlamaRemoteState(filesDir, runtimeJson, '不支持的管理操作');
    }
    const models = readyModelDirs(filesDir);
    if (!validConfig(request.config, models)) {
      return buildLlamaRemoteState(filesDir, runtimeJson, '推理配置校验失败');
    }
    const error = saveLlamaInferenceConfig(filesDir, request.config as LlamaInferenceConfig);
    llamaPeerStats.refreshConfig();
    return buildLlamaRemoteState(filesDir, runtimeJson,
      error.length > 0 ? '配置保存失败: ' + error : '推理配置已保存，将在收到请求时加载模型');
  } catch (_error) {
    return buildLlamaRemoteState(filesDir, runtimeJson, '管理请求解析失败');
  }
}
