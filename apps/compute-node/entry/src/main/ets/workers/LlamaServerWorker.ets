import worker from '@ohos.worker';
import { hilog } from '@kit.PerformanceAnalysisKit';
import llamaProbe from 'libllama_probe.so';

const workerPort = worker.workerPort;

workerPort.onmessage = (event: Object): void => {
  try {
    const data = event as Record<string, Object>;
    const payload = data.data as Record<string, string>;
    const command = payload.command || '';
    const modelMatch = command.match(/(?:^|\s)-m\s+(?:"([^"]+)"|(\S+))/);
    const contextMatch = command.match(/(?:^|\s)-c\s+(\d+)/);
    if (modelMatch === null) {
      hilog.error(0, 'LlamaManager', 'direct preload command has no model');
      return;
    }
    const modelPath = modelMatch[1] || modelMatch[2] || '';
    const contextSize = contextMatch === null ? 8192 : Number(contextMatch[1]);
    const id = llamaProbe.preload(modelPath, contextSize);
    hilog.info(0, 'LlamaManager', 'direct preload queued job=%{public}d model=%{public}s',
      id, modelPath);
  } catch (error) {
    hilog.error(0, 'LlamaManager', 'direct preload worker failed=%{public}s', `${error}`);
  }
};
