import { fileIo } from '@kit.CoreFileKit';

export interface LlamaInferenceConfig {
  model: string;
  contextSize: number;
  otherArgs: string;
  hotCold: boolean;
  expertSkip: boolean;
  skipRange: string;
  distMode: string;
  peerIp: string;
  roleMaster: boolean;
  port: number;
}

/** Parameters that must reach llama_model_params/llama_context_params. */
export interface LlamaRuntimeOptions {
  memoryBudgetMb: number;
  kvReservePct: number;
  hotAlpha: number;
  ffnHotCold: boolean;
  prefetch: boolean;
  useExtraBufts: boolean;
  moeSkipK1: number;
  moeSkipK2: number;
  nBatch: number;
  nUbatch: number;
  nSeqMax: number;
  kvDir: string;
  distRank: number;
  distRanks: number;
  distEndpoints: string;
  distSplit: string;
  distFollower: boolean;
}

const CONFIG_FILE: string = '/llama-inference.json';
const MODELS_DIR: string = '/models';

function argumentTokens(text: string): string[] {
  const normalized = text.trim();
  return normalized.length === 0 ? [] : normalized.split(/\s+/);
}

function flagValue(args: string[], flag: string): string {
  const inline = flag + '=';
  for (let index = 0; index < args.length; index++) {
    const token = args[index];
    if (token.indexOf(inline) === 0) return token.substring(inline.length);
    if (token === flag && index + 1 < args.length) return args[index + 1];
  }
  return '';
}

function numberArgument(args: string[], flags: string[], fallback: number,
  minimum: number, maximum: number): number {
  for (const flag of flags) {
    const raw = flagValue(args, flag);
    if (raw.length === 0) continue;
    const value = Number(raw);
    if (Number.isFinite(value)) return Math.min(maximum, Math.max(minimum, value));
  }
  return fallback;
}

function hasFlag(args: string[], flag: string): boolean {
  return args.indexOf(flag) >= 0;
}

function compareIpv4(a: string, b: string): number {
  const left = a.split('.');
  const right = b.split('.');
  for (let index = 0; index < 4; index++) {
    const delta = Number(left[index]) - Number(right[index]);
    if (delta !== 0) return delta;
  }
  return 0;
}

/**
 * Translate the original llama-server settings into the exact native fields.
 * `--memory-budget` is MiB in the bundled llama.cpp tree; the native layer
 * converts it to bytes.
 */
export function llamaRuntimeOptions(filesDir: string, config: LlamaInferenceConfig | null,
  contextSize: number, localIp: string = ''): LlamaRuntimeOptions {
  const args = argumentTokens(config === null ? '' : config.otherArgs);
  let ffnHotCold = config !== null && config.hotCold;
  if (hasFlag(args, '--no-ffn-hot-cold')) ffnHotCold = false;
  if (hasFlag(args, '--ffn-hot-cold')) ffnHotCold = true;

  let prefetch = false;
  if (hasFlag(args, '--no-prefetch')) prefetch = false;
  if (hasFlag(args, '--prefetch')) prefetch = true;

  // llama-server-ohos runs hot/cold models with `-rea off`: runtime weight
  // repacking creates anonymous buffers on top of the mmap-backed weights and
  // can exhaust the device before the context is created.
  let useExtraBufts = !ffnHotCold;
  if (hasFlag(args, '--no-extra-bufts')) useExtraBufts = false;
  if (hasFlag(args, '--extra-bufts')) useExtraBufts = true;
  const repack = flagValue(args, '-rea').toLowerCase();
  if (repack === 'off' || repack === 'false' || repack === '0') useExtraBufts = false;
  if (repack === 'on' || repack === 'true' || repack === '1') useExtraBufts = true;

  let moeSkipK1 = 0;
  let moeSkipK2 = 0;
  if (config !== null && config.expertSkip) {
    const match = /^(\d+)\s*:\s*(\d+)$/.exec(config.skipRange.trim());
    if (match !== null) {
      moeSkipK1 = Number(match[1]);
      moeSkipK2 = Number(match[2]);
    }
  }
  moeSkipK1 = numberArgument(args, ['--moe-skip-k1'], moeSkipK1, 0, 64);
  moeSkipK2 = numberArgument(args, ['--moe-skip-k2'], moeSkipK2, 0, 64);

  const context = Math.min(32768, Math.max(512, Math.trunc(contextSize)));
  const nBatchDefault = Math.min(context, 2048);
  let nBatch = numberArgument(args, ['-b', '--batch-size'], nBatchDefault, 1, context);
  nBatch = Math.trunc(nBatch);
  let nUbatch = numberArgument(args, ['-ub', '--ubatch-size'], Math.min(nBatch, 512), 1, nBatch);
  nUbatch = Math.trunc(nUbatch);
  const nSeqMax = Math.trunc(numberArgument(args, ['-np', '--parallel'], 1, 1, 8));
  const peerIp = config === null ? '' : config.peerIp.trim();
  let distRank = 0;
  let distRanks = 1;
  let distEndpoints = '';
  let distSplit = '';
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(localIp) && /^\d{1,3}(\.\d{1,3}){3}$/.test(peerIp) &&
    localIp !== peerIp) {
    const localFirst = compareIpv4(localIp, peerIp) < 0;
    distRank = localFirst ? 0 : 1;
    distRanks = 2;
    distEndpoints = localFirst ? localIp + ':30001,' + peerIp + ':30001'
      : peerIp + ':30001,' + localIp + ':30001';
    distSplit = config !== null && (config.distMode === 'expert' || config.distMode === 'neuron') ?
      config.distMode : 'layer';
  }

  return {
    memoryBudgetMb: Math.trunc(numberArgument(args, ['--memory-budget'], 0, 0, 1048576)),
    kvReservePct: numberArgument(args, ['--kv-reserve-pct'], 0, 0, 100),
    hotAlpha: numberArgument(args, ['--hot-alpha'], 0.1, 0.001, 1),
    ffnHotCold: ffnHotCold,
    prefetch: prefetch,
    useExtraBufts: useExtraBufts,
    moeSkipK1: Math.trunc(moeSkipK1),
    moeSkipK2: Math.trunc(moeSkipK2),
    nBatch: nBatch,
    nUbatch: nUbatch,
    nSeqMax: nSeqMax,
    kvDir: filesDir,
    distRank: distRank,
    distRanks: distRanks,
    distEndpoints: distEndpoints,
    distSplit: distSplit,
    distFollower: distRanks > 1 && distRank > 0
  };
}

function modelBaseName(fileName: string): string {
  return fileName.replace(/-\d{5}-of-\d{5}\.gguf$/i, '').replace(/\.gguf$/i, '');
}

function resolvedModelFile(filesDir: string, modelDirName: string): string {
  const modelDir = filesDir + MODELS_DIR + '/' + modelDirName;
  try {
    const names = (fileIo.listFileSync(modelDir) as string[]).filter((name: string): boolean =>
      /\.gguf$/i.test(name) && !name.startsWith('._'));
    const firstShard = names.find((name: string): boolean => /-\d{5}-of-\d{5}\.gguf$/i.test(name));
    names.sort();
    const selected = firstShard || (names.length > 0 ? names[0] : '');
    return selected.length > 0 ? modelDir + '/' + selected : '';
  } catch (_) {
    return '';
  }
}

/** One-time migration from old filesDir/*.gguf layout into filesDir/models/<name>/. */
export function migrateLegacyLlamaModels(filesDir: string): string {
  const oldConfig = loadLlamaInferenceConfig(filesDir);
  try {
    const rootNames = (fileIo.listFileSync(filesDir) as string[]).filter((name: string): boolean =>
      /\.gguf$/i.test(name) && !name.startsWith('._'));
    for (const fileName of rootNames) {
      const modelName = modelBaseName(fileName);
      const modelDir = filesDir + MODELS_DIR + '/' + modelName;
      if (!fileIo.accessSync(filesDir + MODELS_DIR)) fileIo.mkdirSync(filesDir + MODELS_DIR);
      if (!fileIo.accessSync(modelDir)) fileIo.mkdirSync(modelDir);
      const source = filesDir + '/' + fileName;
      const target = modelDir + '/' + fileName;
      if (!fileIo.accessSync(target)) {
        fileIo.renameSync(source, target);
      } else {
        const sourceFile = fileIo.openSync(source, fileIo.OpenMode.READ_ONLY);
        const targetFile = fileIo.openSync(target, fileIo.OpenMode.READ_ONLY);
        try {
          if (fileIo.statSync(sourceFile.fd).size !== fileIo.statSync(targetFile.fd).size) {
            return '沙箱中已存在同名但大小不同的模型，未覆盖：' + modelName;
          }
        } finally {
          fileIo.closeSync(sourceFile);
          fileIo.closeSync(targetFile);
        }
        fileIo.unlinkSync(source);
      }
      const manifest = modelDir + '/llama.json';
      if (!fileIo.accessSync(manifest)) {
        const file = fileIo.openSync(manifest,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(file.fd, JSON.stringify({
          model: fileName, context: oldConfig?.contextSize || 4096, tier: 2, capabilities: ['text']
        }));
        fileIo.closeSync(file);
      }
    }
    if (oldConfig !== null && /\.gguf$/i.test(oldConfig.model)) {
      oldConfig.model = modelBaseName(oldConfig.model);
      return saveLlamaInferenceConfig(filesDir, oldConfig);
    }
    return '';
  } catch (_) {
    return '旧位置模型迁移失败。';
  }
}

export function loadLlamaInferenceConfig(filesDir: string): LlamaInferenceConfig | null {
  try {
    const value = JSON.parse(fileIo.readTextSync(filesDir + CONFIG_FILE)) as LlamaInferenceConfig;
    if (value === null || typeof value !== 'object' || typeof value.model !== 'string' ||
      value.model.length === 0) return null;
    return value;
  } catch (_) {
    return null;
  }
}

export function saveLlamaInferenceConfig(filesDir: string, config: LlamaInferenceConfig): string {
  const model = config.model.trim();
  if (model.length === 0 || resolvedModelFile(filesDir, model).length === 0) {
    return '所选内置模型不存在或无法读取。';
  }
  if (!Number.isInteger(config.contextSize) || config.contextSize < 512 || config.contextSize > 32768) {
    return '上下文大小必须在 512 到 32768 之间。';
  }
  try {
    const temp = filesDir + CONFIG_FILE + '.tmp';
    const file = fileIo.openSync(temp,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, JSON.stringify(config));
    } finally {
      fileIo.closeSync(file);
    }
    fileIo.renameSync(temp, filesDir + CONFIG_FILE);
    return '';
  } catch (_) {
    return '推理配置保存失败。';
  }
}

export function configuredLlamaModel(filesDir: string): string {
  const config = loadLlamaInferenceConfig(filesDir);
  if (config === null) return '';
  return resolvedModelFile(filesDir, config.model);
}
