import { BusinessError, deviceInfo, runningLock } from '@kit.BasicServicesKit';
import hidebug from '@ohos.hidebug';
import { hilog } from '@kit.PerformanceAnalysisKit';
import socket from '@ohos.net.socket';
import buffer from '@ohos.buffer';
import { nativeBridge as testNapi } from './LlamaCompat';
import llamaProbe from 'libllama_probe.so';
import {
  LlamaInferenceConfig,
  llamaRuntimeOptions,
  loadLlamaInferenceConfig,
  saveLlamaInferenceConfig
} from '../llm/LlamaSettings';
import { llamaModelFile } from '../llm/ModelRegistry';

const TAG: string = 'PeerPresence';
const domain: number = 0xFF00;
const PRESENCE_PORT: number = 30002;
const RETRY_MS: number = 5000;
export const PEER_START_EVENT: string = 'llama_server.peer_start';

export interface PeerPresenceSnapshot {
  rank: number;
  serving: number;
  ready: number;
  rss: number;
  expertRam: number;
  hit: number;
  disk: number;
  memTotal: number;
  memAvail: number;
}

export interface PeerStartRequest {
  fromIp: string;
  split: string;
  model?: string;
  contextSize?: number;
  otherArgs?: string;
  hotCold?: boolean;
  expertSkip?: boolean;
  skipRange?: string;
  port?: number;
}

interface StartCommand {
  type: string;
  from: string;
  split: string;
  model?: string;
  contextSize?: number;
  otherArgs?: string;
  hotCold?: boolean;
  expertSkip?: boolean;
  skipRange?: string;
  port?: number;
}

interface PresencePayload {
  rank: number;
  serving: number;
  ready: number;
  rss: number;
  expertRam: number;
  hit: number;
  disk: number;
  memTotal: number;
  memAvail: number;
  ts: number;
  name: string;
  ip: string;
}

export class PeerPresenceService {
  private static instance: PeerPresenceService = new PeerPresenceService();
  private server: socket.TCPSocketServer | null = null;
  private filesDir: string = '';
  private wakeLock: runningLock.RunningLock | null = null;
  private wakeTimer: number = -1;
  private statsTimer: number = -1;
  private opening: boolean = false;
  private active: boolean = false;
  private retryTimer: number = -1;
  private pendingStart: PeerStartRequest | null = null;
  private snapshot: PeerPresenceSnapshot = {
    rank: 0,
    serving: 0,
    ready: 0,
    rss: 0,
    expertRam: 0,
    hit: -1,
    disk: 0,
    memTotal: 0,
    memAvail: 0
  };

  static start(filesDir: string = ''): void {
    if (filesDir.length > 0) {
      PeerPresenceService.instance.filesDir = filesDir;
    }
    PeerPresenceService.instance.ensureWakeLock();
    PeerPresenceService.instance.startNativeStats();
    PeerPresenceService.instance.startInternal();
  }

  static stop(): void {
    PeerPresenceService.instance.releaseWakeLock();
    PeerPresenceService.instance.stopNativeStats();
    PeerPresenceService.instance.stopInternal();
  }

  static update(snapshot: PeerPresenceSnapshot): void {
    PeerPresenceService.instance.snapshot = snapshot;
  }

  static takePendingStart(): PeerStartRequest | null {
    const request = PeerPresenceService.instance.pendingStart;
    PeerPresenceService.instance.pendingStart = null;
    return request;
  }

  /** Ask the rank-1 app to load the same model as a distributed follower. */
  static requestStart(peerIp: string, split: string, config: LlamaInferenceConfig | null = null): Promise<boolean> {
    return PeerPresenceService.instance.requestStartInternal(peerIp, split, config);
  }

  private localIp(): string {
    try {
      const payload: string = testNapi.getnetworkips();
      const ips = JSON.parse(payload) as Record<string, string>;
      return ips['eth'] || '';
    } catch (e) {
      return '';
    }
  }

  private ensureWakeLock(): void {
    if (this.filesDir.length === 0 || this.wakeLock !== null) return;
    const config = loadLlamaInferenceConfig(this.filesDir);
    if (config === null || config.peerIp.length === 0) return;
    let lockType = runningLock.RunningLockType.BACKGROUND;
    try {
      if (runningLock.isSupported(runningLock.RunningLockType.BACKGROUND_USER_IDLE)) {
        lockType = runningLock.RunningLockType.BACKGROUND_USER_IDLE;
      }
    } catch (_) {}
    runningLock.create('llama_distributed', lockType)
      .then((lock: runningLock.RunningLock): void => {
        const latest = loadLlamaInferenceConfig(this.filesDir);
        if (latest === null || latest.peerIp.length === 0) {
          lock.unhold();
          return;
        }
        this.wakeLock = lock;
        lock.hold(-1);
        if (this.wakeTimer >= 0) clearInterval(this.wakeTimer);
        this.wakeTimer = setInterval((): void => {
          try {
            if (this.wakeLock !== null && !this.wakeLock.isHolding()) this.wakeLock.hold(-1);
          } catch (e) {}
        }, 30 * 1000);
        hilog.info(domain, TAG, 'distributed wake lock acquired type=%{public}d', lockType);
      }).catch((e: BusinessError): void => {
        hilog.warn(domain, TAG, 'distributed wake lock unavailable: %{public}s', e.message);
      });
  }

  private releaseWakeLock(): void {
    if (this.wakeTimer >= 0) {
      clearInterval(this.wakeTimer);
      this.wakeTimer = -1;
    }
    if (this.wakeLock !== null) {
      try { this.wakeLock.unhold(); } catch (e) {}
      this.wakeLock = null;
    }
  }

  private startNativeStats(): void {
    if (this.statsTimer >= 0) return;
    this.refreshNativeStats();
    this.statsTimer = setInterval((): void => this.refreshNativeStats(), 2000);
  }

  private stopNativeStats(): void {
    if (this.statsTimer >= 0) {
      clearInterval(this.statsTimer);
      this.statsTimer = -1;
    }
  }

  private refreshNativeStats(): void {
    try {
      const status = JSON.parse(llamaProbe.status()) as Record<string, Object>;
      const state = typeof status['state'] === 'string' ? status['state'] as string : '';
      const config = this.filesDir.length > 0 ? loadLlamaInferenceConfig(this.filesDir) : null;
      const nativeRank = Number(status['distRank']);
      const rank = nativeRank >= 0 ? nativeRank :
        (config !== null && config.peerIp.length > 0 ? (config.roleMaster ? 0 : 1) : 0);
      const hit = Number(status['hit']);
      let memTotal = this.snapshot.memTotal;
      let memAvail = this.snapshot.memAvail;
      try {
        const memory = hidebug.getSystemMemInfo();
        memTotal = Number(memory.totalMem) * 1024;
        memAvail = Number(memory.availableMem) * 1024;
      } catch (_) {
      }
      this.snapshot = {
        rank: rank,
        serving: state === 'ready' || state === 'busy' ? 1 : 0,
        ready: state === 'ready' || state === 'busy' ? 1 : 0,
        rss: Number(status['rss']) || 0,
        expertRam: Number(status['expertRam']) || 0,
        hit: Number.isFinite(hit) && hit >= 0 ? hit : -1,
        disk: Number(status['disk']) || 0,
        memTotal: memTotal,
        memAvail: memAvail
      };
    } catch (_) {
      // Keep the last valid topology sample.
    }
  }

  private async requestStartInternal(peerIp: string, split: string,
    config: LlamaInferenceConfig | null): Promise<boolean> {
    if (peerIp.length === 0) return false;
    // A distributed request can be the first action after app launch. Retry
    // here as well, because the saved config may not have been readable during
    // onCreate().
    this.ensureWakeLock();
    return new Promise<boolean>((resolve) => {
      const client = socket.constructTCPSocketInstance();
      let done = false;
      let sent = false;
      const finish = (ok: boolean): void => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        try { client.close(); } catch (e) {}
        resolve(ok);
      };
      const timer = setTimeout((): void => finish(false), 1800);
      client.on('close', (): void => finish(sent));
      client.on('error', (): void => finish(false));
      client.connect({ address: { address: peerIp, port: PRESENCE_PORT }, timeout: 1500 })
        .then((): void => {
          client.send({ data: JSON.stringify({
            type: 'start', from: this.localIp(), split: split,
            model: config?.model || '', contextSize: config?.contextSize || 0,
            otherArgs: config?.otherArgs || '', hotCold: config?.hotCold === true,
            expertSkip: config?.expertSkip === true, skipRange: config?.skipRange || '',
            port: config?.port || 0
          }) + '\n' }).then((): void => {
            sent = true;
            setTimeout((): void => finish(true), 350);
          }).catch((): void => finish(false));
        })
        .catch((): void => finish(false));
    });
  }

  private async prepareFollower(request: PeerStartRequest): Promise<void> {
    if (this.filesDir.length === 0) {
      hilog.error(domain, TAG, 'remote start skipped: filesDir unavailable');
      return;
    }
    const stored = loadLlamaInferenceConfig(this.filesDir);
    const model = (request.model || '').trim().length > 0 ? (request.model || '').trim() :
      (stored === null ? '' : stored.model);
    if (model.length === 0) {
      hilog.error(domain, TAG, 'remote start ignored: rank0 did not provide a model');
      return;
    }
    // rank0 is the single source of truth for the cascade runtime configuration.
    const config: LlamaInferenceConfig = {
      model: model,
      contextSize: (request.contextSize || 0) > 0 ? (request.contextSize || 8192) :
        (stored === null ? 8192 : stored.contextSize),
      otherArgs: request.otherArgs === undefined ? (stored === null ? '' : stored.otherArgs) : request.otherArgs,
      hotCold: request.hotCold === undefined ? (stored === null ? false : stored.hotCold) : request.hotCold,
      expertSkip: request.expertSkip === undefined ?
        (stored === null ? false : stored.expertSkip) : request.expertSkip,
      skipRange: request.skipRange === undefined ?
        (stored === null ? '' : stored.skipRange) : request.skipRange,
      distMode: request.split,
      peerIp: request.fromIp,
      roleMaster: false,
      port: (request.port || 0) > 0 ? (request.port || 8080) : (stored === null ? 8080 : stored.port)
    };
    const saveError = saveLlamaInferenceConfig(this.filesDir, config);
    if (saveError.length > 0) {
      hilog.warn(domain, TAG, 'received cascade config could not be persisted: %{public}s', saveError);
    }
    // This path is how rank 1 starts a follower. Hold the background lock here
    // even if the service was created before llama-inference.json existed.
    this.ensureWakeLock();
    const status = JSON.parse(llamaProbe.status()) as Record<string, Object>;
    const state = typeof status.state === 'string' ? status.state as string : '';
    if (state === 'loading' || state === 'ready' || state === 'busy') {
      hilog.info(domain, TAG, 'remote start skipped: native state=%{public}s', state);
      return;
    }
    const modelPath = llamaModelFile(this.filesDir + '/models/' + config.model);
    if (modelPath.length === 0) {
      hilog.error(domain, TAG, 'remote start skipped: configured model missing');
      return;
    }
    const options = llamaRuntimeOptions(this.filesDir, config, config.contextSize, this.localIp());
    if (options.distRanks !== 2 || options.distRank !== 1) {
      hilog.error(domain, TAG, 'remote start ignored: derived rank=%{public}d/%{public}d',
        options.distRank, options.distRanks);
      return;
    }
    const jobId = llamaProbe.preload(modelPath, config.contextSize, JSON.stringify(options));
    hilog.info(domain, TAG, 'distributed follower preload job=%{public}d peer=%{public}s',
      jobId, request.fromIp);
  }

  private startInternal(): void {
    if (this.active) {
      return;
    }
    this.active = true;
    this.open();
  }

  private stopInternal(): void {
    this.active = false;
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    const old = this.server;
    this.server = null;
    if (old !== null) {
      old.close().catch(() => {});
    }
  }

  private scheduleRetry(): void {
    if (!this.active || this.retryTimer >= 0) {
      return;
    }
    this.retryTimer = setTimeout(() => {
      this.retryTimer = -1;
      this.open();
    }, RETRY_MS);
  }

  private reply(client: socket.TCPSocketConnection): void {
    const modelName = deviceInfo.marketName.length > 0 ? deviceInfo.marketName : deviceInfo.productModel;
    const payloadData: PresencePayload = {
      rank: this.snapshot.rank,
      serving: this.snapshot.serving,
      ready: this.snapshot.ready,
      rss: this.snapshot.rss,
      expertRam: this.snapshot.expertRam,
      hit: this.snapshot.hit,
      disk: this.snapshot.disk,
      memTotal: this.snapshot.memTotal,
      memAvail: this.snapshot.memAvail,
      ts: Date.now(),
      name: modelName.length > 0 ? modelName : 'HarmonyOS PC',
      ip: this.localIp()
    };
    const payload = JSON.stringify(payloadData);
    client.send({ data: payload }).then(() => {
      setTimeout(() => {
        try { client.close(); } catch (e) {}
      }, 300);
    }).catch((e: BusinessError) => {
      hilog.error(domain, TAG, 'send failed: %{public}s', `${e}`);
      try { client.close(); } catch (e2) {}
    });
  }

  private async open(): Promise<void> {
    if (!this.active || this.server !== null || this.opening) {
      return;
    }
    this.opening = true;
    try {
      const srv = socket.constructTCPSocketServerInstance();
      srv.on('connect', (client: socket.TCPSocketConnection) => {
        client.on('message', (value: socket.SocketMessageInfo) => {
          try {
            const text = buffer.from(value.message).toString('utf-8');
            const command = JSON.parse(text) as StartCommand;
            if (command.type === 'start' && typeof command.from === 'string' && command.from.length > 0) {
              const request: PeerStartRequest = {
                fromIp: command.from,
                split: typeof command.split === 'string' && command.split.length > 0 ? command.split : 'layer',
                model: typeof command.model === 'string' ? command.model : '',
                contextSize: typeof command.contextSize === 'number' ? command.contextSize : 0,
                otherArgs: typeof command.otherArgs === 'string' ? command.otherArgs : '',
                hotCold: command.hotCold === true,
                expertSkip: command.expertSkip === true,
                skipRange: typeof command.skipRange === 'string' ? command.skipRange : '',
                port: typeof command.port === 'number' ? command.port : 0
              };
              this.pendingStart = request;
              hilog.info(domain, TAG, 'remote start requested by %{public}s', request.fromIp);
              this.prepareFollower(request).catch((e: Error): void => {
                hilog.error(domain, TAG, 'remote follower preload failed: %{public}s', e.message);
              });
            }
          } catch (e) {
            // Discovery and stats requests are not JSON commands.
          }
        });
        client.on('error', (e) => {
          hilog.error(domain, TAG, 'client error: %{public}s', `${e}`);
        });
        setTimeout(() => {
          this.reply(client);
        }, 100);
      });
      await srv.listen({ address: '0.0.0.0', port: PRESENCE_PORT });
      const address = await srv.getLocalAddress();
      if (Number(address.port) !== PRESENCE_PORT) {
        await srv.close();
        throw new Error(`port fell back to ${address.port}`);
      }
      this.server = srv;
      hilog.info(domain, TAG, 'presence listening on %{public}d', PRESENCE_PORT);
    } catch (e) {
      hilog.error(domain, TAG, 'presence listen failed: %{public}s', `${e}`);
      this.scheduleRetry();
    } finally {
      this.opening = false;
    }
  }
}
