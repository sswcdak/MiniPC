import { hilog } from '@kit.PerformanceAnalysisKit';
import { nativeBridge as testNapi } from '../llama/LlamaCompat';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common, UIAbility, Want } from '@kit.AbilityKit';
import { BusinessError, emitter, runningLock } from '@kit.BasicServicesKit';
import { taskpool } from '@kit.ArkTS';
import featureAbility from '@ohos.ability.featureAbility';
import { promptAction, router } from '@kit.ArkUI';
import worker from '@ohos.worker';
import socket from '@ohos.net.socket';
import http from '@ohos.net.http';
import buffer from '@ohos.buffer';
import hidebug from '@ohos.hidebug';
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import {
  PEER_START_EVENT,
  PeerPresenceService,
  PeerPresenceSnapshot,
  PeerStartRequest
} from '../llama/PeerPresenceService';
import llamaProbe from 'libllama_probe.so';
import {
  LlamaInferenceConfig,
  llamaRuntimeOptions,
  loadLlamaInferenceConfig,
  migrateLegacyLlamaModels,
  saveLlamaInferenceConfig
} from '../llm/LlamaSettings';
import { llamaModelFile, readyModelDirs } from '../llm/ModelRegistry';


const LOCK_REFRESH_MS = 25 * 60 * 1000;

const TAG: string = '[Sample_FAModelAbilityDevelop]';
const domain: number = 0xFF00;
// 对端数据通道：每台 App 监听这个小端口，回一行 JSON；对端每 2s 取一次。
// 与推理完全无关（不碰 llama.cpp 线程），量级 ~200B/2s。
const PEER_STATS_PORT: number = 30002;
const PEER_STATS_STALE_MS: number = 8000;
const TOPOLOGY_REFRESH_MS: number = 2000;
const DIST_PORT: number = 30001;
const PEER_SCAN_INTERVAL_MS: number = 12000;

interface PeerDiscoveryPayload {
  rank?: number;
  serving?: number;
  ready?: number;
  name?: string;
  ip?: string;
}

interface PeerDevice {
  ip: string;
  name: string;
  rank: number;
  serving: boolean;
  ready: boolean;
  available: boolean;
}

interface NetworkNeighbor {
  ip: string;
  mac: string;
  iface: string;
}

interface PeerStartCommand {
  type: string;
  from: string;
  split: string;
  model: string;
  contextSize: number;
  otherArgs: string;
  hotCold: boolean;
  expertSkip: boolean;
  skipRange: string;
  port: number;
}

interface PeerStartEventData {
  payload: string;
}

interface CoopEndpoints {
  endpoints: string;
  rank: number;
  nRanks: number;
}

// 对话/内置测试用的请求与流式响应类型（ArkTS 要求显式接口，禁止无类型对象字面量）
interface ChatMessage { role: string; content: string; think?: string; }
interface ChatRequest {
  messages: ChatMessage[];
  max_tokens: number;
  cache_prompt: boolean;
  seed: number;
  temperature: number;
  stream?: boolean;
}
interface ChatTimings { prompt_per_second?: number; predicted_per_second?: number; }
// 流式（SSE）分块：delta.content = 正式回答；delta.reasoning_content = 思考过程
interface ChatDelta { role?: string; content?: string; reasoning_content?: string; }
interface StreamChoice { delta?: ChatDelta; }
interface StreamChunk { choices?: StreamChoice[]; timings?: ChatTimings; }
interface ChatChoiceMessage { content?: string; }
interface ChatChoice { message?: ChatChoiceMessage; }
interface ChatResponse { timings?: ChatTimings; choices?: ChatChoice[]; }
interface DirectNativeEvent { event: string; id?: string; payload: string; }
interface DirectNativeResponse { message?: ChatChoiceMessage; finish_reason?: string; }

interface RpcArg {
  host: string;
  port: number;
}

// 从「其他命令行参数」里取 -n / --n-predict（llama.cpp 原生参数，透传给 server 也无害），
// 作为对话请求的 max_tokens；缺省 256。这样输出长度可随启动参数修改，不再写死。
function parseMaxTokens(args: string): number {
  const m = args.match(/(?:^|\s)(?:-n|--n-predict|--predict)\s+(\d+)(?:\s|$)/);
  if (m) {
    const v = parseInt(m[1]);
    if (v > 0) {
      return v;
    }
  }
  return 256;
}

// 从「分布式 rank」串里取出 endpoints 列表（形如 0/2@ip1:30001,ip2:30001#layer）
function parseEndpoints(cfg: string): string[] {
  const out: string[] = [];
  const at = cfg.indexOf('@');
  if (at < 0) {
    return out;
  }
  let body = cfg.substring(at + 1);
  const hash = body.indexOf('#');
  if (hash >= 0) {
    body = body.substring(0, hash);
  }
  const parts = body.split(',');
  for (let i = 0; i < parts.length; i++) {
    const s = parts[i].trim();
    if (s.length > 0) {
      out.push(s);
    }
  }
  return out;
}

// 解析命令行参数里的 --rpc host:port，返回 RpcArg 或 null
function parseRpcArg(args: string): RpcArg | null {
  const m = args.match(/--rpc\s+([^\s:]+):(\d+)/);
  if (!m) return null;
  const arg: RpcArg = { host: m[1], port: parseInt(m[2]) };
  return arg;
}

// TCP 探测：尝试连接 host:port，超时 3 秒，返回 true=成功 false=失败
async function checkTcpReachable(host: string, port: number): Promise<boolean> {
  return new Promise<boolean>((resolve) => {
    const tcp = socket.constructTCPSocketInstance();
    const timer = setTimeout(() => {
      try { tcp.close(); } catch (_) {}
      resolve(false);
    }, 3000);
    tcp.connect({ address: { address: host, port: port }, timeout: 3000 })
      .then(() => {
        clearTimeout(timer);
        try { tcp.close(); } catch (_) {}
        resolve(true);
      })
      .catch(() => {
        clearTimeout(timer);
        try { tcp.close(); } catch (_) {}
        resolve(false);
      });
  });
}

let want: Want = {
  deviceId: "",
  bundleName: "com.aloereed.myapplication",
  abilityName: "ServerAbility",
};

function uriToPath(uri: string): string {
  if (!uri.startsWith('file://')) {
    throw new Error('The provided URI is not a file URI.');
  }

  let path = uri.slice(7);

  if (path[0] === '/' && /^[a-zA-Z]:/.test(path.slice(1, 3))) {
    path = path.slice(1);
  }

  if (path.startsWith('docs/')) {
    path = path.slice(5);
    if (path.startsWith('storage/Users/currentUser/')) {
      path = '/storage/media/100/local/files/Docs/' + path.slice('storage/Users/currentUser/'.length);
    } else {
      path = '/storage/media/100/local/files/Docs/' + path;
    }
  } else if (path.startsWith('media/')) {
    path = '/storage/media/100/local/files/Media/' + path.slice(6);
  }

  path = decodeURIComponent(path);

  return path;
}

// 启动前轮转日志：把上一次的 llama_debug.log 留成 llama_debug.prev.log。
// 否则每次启动都 TRUNC，上一轮运行（尤其是偶发启动失败）会被直接冲掉、事后无法回看。
function rotateDebugLog(logDir: string): string {
  const cur = logDir + '/llama_debug.log';
  const prev = logDir + '/llama_debug.prev.log';
  try {
    if (fs.accessSync(cur)) {
      try {
        fs.unlinkSync(prev);
      } catch (e) {}
      fs.renameSync(cur, prev);
    }
  } catch (e) {}
  return cur;
}

// 日志头带启动时间，便于事后区分是哪一次运行
function debugLogHeader(command: string): string {
  const d = new Date();
  const p = (n: number): string => (n < 10 ? '0' + n : `${n}`);
  const ts = `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ` +
    `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
  return `start: ${ts}\ncommand: ${command}\n`;
}

@Concurrent
async function StartServer(command: string, logDir: string): Promise<void> {
  emitter.on({ eventId: 1 }, () => {
    emitter.off(1)
  });
  try {
    // 注：实际启动走 doStartServer()（ThreadWorker → ServerWorker.ets），此 taskpool 路径已不再调用
    let logFile = logDir + '/llama_debug.log';
    let file = fs.openSync(logFile, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, 'command: ' + command + '\n');
    fs.closeSync(file);
    hilog.info(0x0000, 'StartServer', 'command: %{public}s', command);
    let result: string = testNapi.openllama(command);
    hilog.info(0x0000, 'StartServer', 'openllama returned: %{public}s', result);
    file = fs.openSync(logFile, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.APPEND);
    fs.writeSync(file.fd, 'result: ' + result + '\n');
    fs.closeSync(file);
  } catch (e) {
    hilog.error(0x0000, 'StartServer', 'openllama error: %{public}s', `${e}`);
    try {
      let logFile = logDir + '/llama_debug.log';
      let file = fs.openSync(logFile, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.APPEND);
      fs.writeSync(file.fd, 'error: ' + `${e}` + '\n');
      fs.closeSync(file);
    } catch (e2) {}
  }
}


@Entry
@Component
struct Index {
  @State message: string = 'Hello World';
  @State selectedModel: string = '没有模型被选择。';
  @State modelList: string[] = [];
  @State modelOptions: SelectOption[] = [];
  @State selectedBuiltin: string = '';
  @State draftModel: string = '未选择 DFlash 侧车（可选）。';
  @State contextSize: number = 4096;
  @State port: number = 8080;
  @State otherargs: string = '--memory-budget 14336';
  @State bisectConfig: string = '5:20';
  @State distConfig: string = '';
  @State rpcRunning: boolean = false;
  @State rpcStatus: string = 'RPC Server 未运行';
  @State rpcMode: string = 'wifi';  // 'wifi' | 'usb' | 'eth'
  @State rpcWifiIp: string = '获取中...';
  @State rpcUsbIp: string = '获取中...';
  @State rpcEthIp: string = '获取中...';
  @State rpcCache: boolean = false;
  @State rpcPort: number = 50053;
  @State importing: boolean = false;
  @State importText: string = '';
  @State importPercent: number = 0;
  @State chatMsgs: ChatMessage[] = [];
  @State chatInput: string = '';
  @State chatStat: string = '';
  @State chatPending: boolean = false;
  @State streamThink: string = '';
  @State streamContent: string = '';
  @State loadStatus: string = '';
  @State loadDone: boolean = false;
  @State starting: boolean = false;
  // 本次会话已忽略的日志字节数（上次运行留下的内容），见 refreshPoolStats()
  private logBaseline: number = -1;
  // 对端数据（来自对端的 stats 端口）
  @State peerRssBytes: number = 0;
  @State peerExpertRamBytes: number = 0;
  @State peerHitPct: number = -1;
  @State peerDiskWeightBytes: number = 0;
  @State peerServing: boolean = false;
  @State peerReady: boolean = false;
  private peerTs: number = 0;
  // 本机 llama-server 是否在跑：由 refreshPoolStats() 按日志新鲜度判定，供对端数据通道使用。
  // 本机和对端统一使用 native status 的 RSS，避免 PSS/RSS 混用造成数值不一致。
  private serving: boolean = false;
  private peerPolling: boolean = false;
  private peerFailCount: number = 0;   // 临时诊断
  private peerOkCount: number = 0;     // 临时诊断
  private loadTimer: number = -1;
  private listScroller: Scroller = new Scroller();
  @State chatAtBottom: boolean = true;
  @State roleIsMaster: boolean = true;
  @State masterIp: string = '192.168.0.200';
  @State masterPort: string = '30001';
  @State slaveIp: string = '192.168.0.210';
  @State slavePort: string = '30001';
  @State peerDevices: PeerDevice[] = [];
  @State selectedPeerIp: string = '';
  private preferredPeerIp: string = '';
  @State peerScanning: boolean = false;
  @State peerScanText: string = '正在搜索对端设备...';
  private peerScanAtMs: number = 0;
  private peerScanGeneration: number = 0;
  @State hotColdOn: boolean = true;
  @State bisectOn: boolean = true;
  @State distMode: string = 'layer';
  @State memTotalBytes: number = 0;
  @State memFreeBytes: number = 0;
  @State ramExperts: number = 0;
  @State diskExperts: number = 0;
  @State appRssBytes: number = 0;
  @State expertRamBytes: number = 0;
  @State diskWeightBytes: number = 0;
  @State poolHitPct: number = -1;
  private memTimer: number = -1;


  private workerInstance: worker.ThreadWorker | null = null;
  private selectedUri: string = '';
  private selectedUris: string[] = [];
  private modelFd: number = -1;
  private draftFd: number = -1;
  private draftUri: string = '';
  private bgLock: runningLock.RunningLock | null = null;
  private lockTimer: number = -1;
  private context = getContext(this) as common.UIAbilityContext;
  private filesDir: string = '';

  // 对话界面（仿 llama.cpp webui）：多轮流式对话。用 requestInStream + SSE 逐块接收，
  // ---- 协同配置面板的小工具 ----
  coopIsOn(): boolean {
    return this.selectedPeerIp.length > 0;
  }
  showPeerTopology(): boolean {
    return this.selectedPeerIp.length > 0;
  }
  coopRole(): string {
    return this.roleIsMaster ? '主设备 (rank0)' : '子设备 (rank1)';
  }
  coopMaster(): string {
    const eps = parseEndpoints(this.distConfig);
    return eps.length > 0 ? eps[0] : '未配置';
  }
  chatRequestHost(): string {
    if (this.roleIsMaster) {
      return '127.0.0.1';
    }
    const eps = parseEndpoints(this.distConfig);
    if (eps.length > 0) {
      const endpoint = eps[0];
      const colon = endpoint.lastIndexOf(':');
      if (colon > 0) {
        return endpoint.substring(0, colon);
      }
    }
    return this.selectedPeerIp.length > 0 ? this.selectedPeerIp : '127.0.0.1';
  }
  chatReady(): boolean {
    // Inference is lazy: a saved built-in model is enough to submit the next
    // request; local loading starts inside llamaProbe.start().
    return this.selectedBuiltin.length > 0;
  }
  distModeLabel(): string {
    return this.distMode === 'layer' ? 'PP（流水线并行）'
      : (this.distMode === 'expert' ? '专家并行' : '神经元并行');
  }
  localEthIp(): string {
    try {
      const ips = JSON.parse(testNapi.getnetworkips()) as Record<string, string>;
      const actual = typeof ips['eth'] === 'string' ? ips['eth'].trim() : '';
      if (/^\d{1,3}(\.\d{1,3}){3}$/.test(actual)) {
        return actual;
      }
    } catch (_) {}
    const ip = this.masterIp.trim();
    if (/^\d{1,3}(\.\d{1,3}){3}$/.test(ip)) {
      return ip;
    }
    return '';
  }

  peerHostForStats(): string {
    if (this.selectedPeerIp.length > 0) {
      return this.selectedPeerIp;
    }
    const first = this.firstAvailablePeer();
    return first !== null ? first.ip : '';
  }

  firstAvailablePeer(): PeerDevice | null {
    for (let i = 0; i < this.peerDevices.length; i++) {
      if (this.peerDevices[i].available) {
        return this.peerDevices[i];
      }
    }
    return null;
  }

  peerIsAvailable(ip: string): boolean {
    for (let i = 0; i < this.peerDevices.length; i++) {
      if (this.peerDevices[i].ip === ip) {
        return this.peerDevices[i].available;
      }
    }
    return false;
  }

  peerAvailableCount(): number {
    let count = 0;
    for (let i = 0; i < this.peerDevices.length; i++) {
      if (this.peerDevices[i].available) {
        count++;
      }
    }
    return count;
  }

  private setPeerReachability(ip: string, available: boolean): void {
    for (let i = 0; i < this.peerDevices.length; i++) {
      if (this.peerDevices[i].ip !== ip) {
        continue;
      }
      const peer: PeerDevice = {
        ip: this.peerDevices[i].ip,
        name: this.peerDevices[i].name,
        rank: this.peerDevices[i].rank,
        serving: available ? this.peerServing : false,
        ready: available ? this.peerReady : false,
        available: available
      };
      this.peerDevices = this.peerDevices.slice(0, i).concat([peer], this.peerDevices.slice(i + 1));
      return;
    }
  }

  buildCoopEndpoints(): CoopEndpoints | null {
    const localIp = this.localEthIp();
    const peerIp = this.selectedPeerIp.trim();
    if (localIp.length === 0 || peerIp.length === 0 || !this.peerIsAvailable(peerIp)) {
      return null;
    }
    // rank 固定按 IP 升序：地址较小的一台永远是 rank0。
    const localFirst = this.compareIpv4(localIp, peerIp) < 0;
    const firstIp = localFirst ? localIp : peerIp;
    const secondIp = localFirst ? peerIp : localIp;
    const result: CoopEndpoints = {
      endpoints: `${firstIp}:${DIST_PORT},${secondIp}:${DIST_PORT}`,
      rank: localFirst ? 0 : 1,
      nRanks: 2
    };
    return result;
  }

  applyDistConfig(): void {
    const config = this.buildCoopEndpoints();
    if (config === null) {
      this.distConfig = '';
      this.message = this.selectedPeerIp.length > 0 ? '所选协同设备当前不可用' : '请选择协同设备';
      try { testNapi.setdistconfig(0, 1, '', ''); } catch (e) {}
      return;
    }
    try {
      const split = this.distMode;
      const rank = config.rank;
      const nRanks = config.nRanks;
      this.roleIsMaster = rank === 0;
      // 同时把组装串写回 distConfig，供左上「设备拓扑」解析 IP
      this.distConfig = `${rank}/${nRanks}@${config.endpoints}#${split}`;
      this.masterPort = `${DIST_PORT}`;
      this.slavePort = `${DIST_PORT}`;
      this.slaveIp = this.selectedPeerIp;
      testNapi.setdistconfig(rank, nRanks, config.endpoints, split);
      const eps = parseEndpoints(config.endpoints);
      this.message = rank === 0
        ? `协同配置已应用：本机为 rank0，对端 ${this.selectedPeerIp} 为 rank1`
        : `协同配置已应用：本机为子设备，主设备 ${eps.length > 0 ? eps[0].split(':')[0] : ''}`;
    } catch (e) {
      this.message = '协同配置应用失败: ' + `${e}`;
      hilog.error(0x0000, 'StartServer', 'apply distconfig error: %{public}s', `${e}`);
    }
  }

  // 流式输出后把对话列表滚到底部；但仅当用户本来就在底部时才跟随（网页聊天行为），
  // 用户上滚看历史时不会被拽回底部
  scrollChatToBottom(): void {
    if (!this.chatAtBottom) {
      return;
    }
    setTimeout(() => {
      try {
        this.listScroller.scrollEdge(Edge.Bottom);
      } catch (e) {
      }
    }, 30);
  }

  private saveInferenceConfig(): string {
    const config: LlamaInferenceConfig = {
      model: this.selectedBuiltin,
      contextSize: this.contextSize,
      otherArgs: this.otherargs,
      hotCold: this.hotColdOn,
      expertSkip: this.bisectOn,
      skipRange: this.bisectConfig,
      distMode: this.distMode,
      peerIp: this.selectedPeerIp,
      roleMaster: this.roleIsMaster,
      port: this.port
    };
    const error = saveLlamaInferenceConfig(this.filesDir, config);
    if (error.length === 0) {
      this.preferredPeerIp = config.peerIp;
      // Re-evaluate the running lock after a co-op peer is configured.
      PeerPresenceService.start(this.filesDir);
    }
    return error;
  }

  private saveCascadeConfig(): void {
    const error = this.saveInferenceConfig();
    if (error.length > 0) {
      this.message = '协同配置保存失败: ' + error;
    }
  }

  private restoreSavedInferenceConfig(): void {
    const saved = loadLlamaInferenceConfig(this.filesDir);
    if (saved === null) {
      return;
    }
    if (this.modelList.indexOf(saved.model) >= 0) {
      this.selectedBuiltin = saved.model;
      this.selectedModel = this.filesDir + '/models/' + saved.model;
    }
    this.contextSize = saved.contextSize;
    this.otherargs = saved.otherArgs;
    this.hotColdOn = saved.hotCold;
    this.bisectOn = saved.expertSkip;
    this.bisectConfig = saved.skipRange;
    this.distMode = saved.distMode;
    this.selectedPeerIp = saved.peerIp.trim();
    this.preferredPeerIp = this.selectedPeerIp;
    this.roleIsMaster = saved.roleMaster;
    this.port = saved.port;
    this.loadStatus = '配置已保存 · 请求时加载';
  }

  private async runDirectChat(text: string): Promise<void> {
    const startedAt = Date.now();
    const modelPath = this.selectedBuiltin.length > 0 ?
      llamaModelFile(this.filesDir + '/models/' + this.selectedBuiltin) :
      this.modelFd >= 0 ? '/proc/self/fd/' + String(this.modelFd) : '';
    await new Promise<void>((resolve: () => void): void => {
      const request: ChatRequest = {
        messages: this.chatMsgs,
        max_tokens: parseMaxTokens(this.otherargs),
        cache_prompt: false,
        seed: 1234,
        temperature: 0,
        stream: true
      };
      const runtimeConfig: LlamaInferenceConfig = {
        model: this.selectedBuiltin,
        contextSize: this.contextSize,
        otherArgs: this.otherargs,
        hotCold: this.hotColdOn,
        expertSkip: this.bisectOn,
        skipRange: this.bisectConfig,
        distMode: this.distMode,
        peerIp: this.selectedPeerIp,
        roleMaster: this.roleIsMaster,
        port: this.port
      };
      const runtimeOptions = llamaRuntimeOptions(this.filesDir, runtimeConfig, this.contextSize, this.localEthIp());
      if (runtimeOptions.distRanks > 1 && runtimeOptions.distRank === 0) {
        PeerPresenceService.requestStart(runtimeConfig.peerIp, runtimeConfig.distMode);
      }
      const jobId = llamaProbe.start(modelPath, JSON.stringify(request), 1800, this.contextSize,
        JSON.stringify(runtimeOptions));
      if (jobId <= 0) {
        this.chatStat = '失败: 模型正在加载或原生引擎繁忙';
        resolve();
        return;
      }
      const started = Date.now();
      let lastEventAt = started;
      const timer = setInterval((): void => {
        const events = llamaProbe.takeEvents();
        let finished = false;
        for (const line of events) {
          try {
            const event = JSON.parse(line) as DirectNativeEvent;
            if (String(event.id || '') !== String(jobId)) continue;
            lastEventAt = Date.now();
            if (event.event === 'response') {
              const response = JSON.parse(event.payload) as DirectNativeResponse;
              const add = response.message?.content || '';
              if (add.length > 0) {
                this.streamContent += add;
                this.scrollChatToBottom();
              }
            } else if (event.event === 'end') {
              finished = true;
            } else if (event.event === 'error') {
              this.chatStat = '失败: ' + event.payload;
            }
          } catch (_) {}
        }
        const stalled = !finished && runtimeOptions.distRanks > 1 &&
          Date.now() - lastEventAt > 120000;
        if (stalled) {
          llamaProbe.cancel(jobId);
          this.chatStat = '失败: 分布式推理超过 120 秒无进度，已停止';
          hilog.error(domain, TAG, 'distributed inference watchdog fired');
          finished = true;
        }
        if (finished || Date.now() - started > 1800000) {
          clearInterval(timer);
          this.chatMsgs = this.chatMsgs.concat([{ role: 'assistant', content: this.streamContent }]);
          if (!stalled) {
            this.chatStat = `${((Date.now() - startedAt) / 1000).toFixed(1)}s`;
          }
          resolve();
        }
      }, 80);
    });
    this.streamContent = '';
    this.streamThink = '';
    this.chatPending = false;
    this.scrollChatToBottom();
  }

  // 思考过程（delta.reasoning_content）与正式回答（delta.content）分开显示，边生成边吐。
  async sendChat(): Promise<void> {
    const text: string = this.chatInput.trim();
    // 模型没加载完（未显示"✓ 服务就绪"）不允许发送
    if (text.length === 0 || this.chatPending || !this.chatReady()) {
      return;
    }
    this.chatMsgs = this.chatMsgs.concat([{ role: 'user', content: text }]);
    this.scrollChatToBottom();
    this.chatInput = '';
    this.chatPending = true;
    this.chatStat = '生成中...';
    this.streamThink = '';
    this.streamContent = '';
    await this.runDirectChat(text);
    return;
    let sseBuf = '';
    let think = '';
    let content = '';
    let timStat = '';
    const t0 = Date.now();
    const httpReq = http.createHttp();
    httpReq.on('dataReceive', (data: ArrayBuffer) => {
      sseBuf += buffer.from(data).toString('utf-8');
      let nl = sseBuf.indexOf('\n');
      while (nl >= 0) {
        const line = sseBuf.substring(0, nl).trim();
        sseBuf = sseBuf.substring(nl + 1);
        nl = sseBuf.indexOf('\n');
        if (line.length === 0 || !line.startsWith('data:')) {
          continue;
        }
        const payload = line.substring(5).trim();
        if (payload === '[DONE]') {
          continue;
        }
        try {
          const obj = JSON.parse(payload) as StreamChunk;
          if (obj.choices && obj.choices.length > 0 && obj.choices[0].delta) {
            const d = obj.choices[0].delta;
            if (d.reasoning_content) {
              think += d.reasoning_content;
              this.streamThink = think;
            }
            if (d.content) {
              content += d.content;
              this.streamContent = content;
            }
            this.scrollChatToBottom();
          }
          if (obj.timings && obj.timings.prompt_per_second) {
            const pv: number = obj.timings.prompt_per_second ? obj.timings.prompt_per_second : 0;
            const dv: number = obj.timings.predicted_per_second ? obj.timings.predicted_per_second : 0;
            timStat = `prefill ${pv.toFixed(2)} t/s | decode ${dv.toFixed(2)} t/s`;
          }
        } catch (e2) {
        }
      }
    });
    try {
      const reqBody: ChatRequest = {
        messages: this.chatMsgs,
        max_tokens: parseMaxTokens(this.otherargs),
        cache_prompt: false,
        seed: 1234,
        temperature: 0,
        stream: true
      };
      const chatHost = this.chatRequestHost();
      hilog.info(domain, TAG, 'chat request host=%{public}s port=%{public}d rank=%{public}d',
        chatHost, this.port, this.roleIsMaster ? 0 : 1);
      await httpReq.requestInStream(`http://${chatHost}:${this.port}/v1/chat/completions`, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' },
        extraData: JSON.stringify(reqBody),
        connectTimeout: 10000,
        readTimeout: 1800000
      });
      const elapsed = (Date.now() - t0) / 1000;
      this.chatMsgs = this.chatMsgs.concat([{ role: 'assistant', content: content, think: think }]);
      this.scrollChatToBottom();
      this.chatStat = (timStat.length > 0 ? timStat : '') + ` | ${elapsed.toFixed(1)}s`;
      hilog.info(domain, TAG, 'chat done: %{public}s', this.chatStat);
    } catch (e) {
      this.chatStat = this.roleIsMaster
        ? '失败: ' + `${e}`
        : `失败：rank1 无法连接 rank0 ${this.chatRequestHost()}:${this.port}`;
      hilog.error(domain, TAG, 'chat failed: %{public}s', `${e}`);
    }
    this.chatPending = false;
    this.streamThink = '';
    this.streamContent = '';
    httpReq.destroy();
  }

  // 启动后轮询沙箱日志尾部，判断"模型是否加载完成"，让用户不用猜。
  // rank0（入口）就绪标志 = "listening on http://"；rank1（--follower）就绪标志 =
  // "common_follower_run" / "decoding what rank 0 decodes"；失败/退出关键字也一并识别。
  startLoadWatch(): void {
    this.loadStatus = '模型加载中...（同进程 llama.cpp）';
    this.loadDone = false;
    if (this.loadTimer >= 0) {
      clearInterval(this.loadTimer);
      this.loadTimer = -1;
    }
    this.loadTimer = setInterval(() => {
      try {
        const status = JSON.parse(llamaProbe.status()) as Record<string, string>;
        if (status.state === 'error') {
          this.loadStatus = '启动失败 ✗（' + (status.error || 'native load failed') + '）';
          this.loadDone = false;
          this.starting = false;
          clearInterval(this.loadTimer);
          this.loadTimer = -1;
        } else if (status.state === 'ready' || status.state === 'busy') {
          this.loadStatus = '模型已加载完成 ✓ 同进程服务就绪';
          this.loadDone = true;
          this.starting = false;
          clearInterval(this.loadTimer);
          this.loadTimer = -1;
        }
      } catch (e) {
      }
    }, 2000);
  }

  stopLoadWatch(): void {
    if (this.loadTimer >= 0) {
      clearInterval(this.loadTimer);
      this.loadTimer = -1;
    }
  }

  // ---- 设备拓扑：本机内存 ----
  refreshMem(): void {
    try {
      const mi: hidebug.SystemMemInfo = hidebug.getSystemMemInfo();
      // totalMem / availableMem 单位为 KB，统一换算成字节。
      this.memTotalBytes = Number(mi.totalMem) * 1024;
      this.memFreeBytes = Number(mi.availableMem) * 1024;
      hilog.info(domain, TAG, `refreshMem: rss=${this.appRssBytes} memTotal=${this.memTotalBytes}`);
    } catch (e) {
      hilog.error(domain, TAG, `refreshMem err: ${e}`);
    }
  }
  appMemPct(): number {
    if (this.memTotalBytes <= 0) {
      return 0;
    }
    const p = 100.0 * this.appRssBytes / this.memTotalBytes;
    return p > 100 ? 100 : (p < 0 ? 0 : p);
  }
  fmtGB(bytes: number): string {
    if (bytes <= 0) {
      return '—';
    }
    const gb = bytes / 1024 / 1024 / 1024;
    if (gb >= 1) {
      return gb.toFixed(1) + ' GB';
    }
    return (bytes / 1024 / 1024).toFixed(0) + ' MB';
  }
  hitLabel(hit: number): string {
    if (hit >= 0) return hit.toFixed(0) + '%';
    return '—';
  }
  distIp(idx: number): string {
    const eps = parseEndpoints(this.distConfig);
    return idx < eps.length ? eps[idx] : '未配置';
  }
  // 扫描沙箱里的内置模型（.gguf），生成下拉选项；分片模型只列首个分片
  refreshModelList(): void {
    try {
      const list: string[] = readyModelDirs(this.filesDir);
      hilog.info(domain, TAG, 'sandbox model refresh count=%{public}d dir=%{public}s',
        list.length, this.filesDir);
      this.modelList = list;
      this.modelOptions = list.map((name: string): SelectOption => ({ value: name }));
      // 已选文件被删除/重命名后不要继续指向旧文件名
      if (this.selectedBuiltin.length > 0 && list.indexOf(this.selectedBuiltin) < 0) {
        this.selectedBuiltin = '';
      }
      // 尚未选择时，默认选中第一个内置模型；外部 picker 的显式选择优先
      if (this.selectedBuiltin.length === 0 && this.selectedUri.length === 0 && list.length > 0) {
        this.selectedBuiltin = list[0];
        this.selectedModel = this.filesDir + '/models/' + list[0];
      }
    } catch (e) {
      hilog.error(domain, TAG, `refreshModelList err: ${e}`);
    }
  }
  // 从 llama_debug.log 解析：POOL 池几何（RAM 档/总专家数、arena 字节）+ 最新 [monitor] VmRSS
  refreshPoolStats(): void {
    try {
      const native = JSON.parse(llamaProbe.status()) as Record<string, Object>;
      const nativeState = typeof native['state'] === 'string' ? native['state'] as string : '';
      const rss = Number(native['rss']);
      if (rss > 0) this.appRssBytes = rss;
      if (nativeState === 'ready' || nativeState === 'busy' || nativeState === 'loading') {
        const expertRam = Number(native['expertRam']);
        const hit = Number(native['hit']);
        const disk = Number(native['disk']);
        this.expertRamBytes = expertRam > 0 ? expertRam : 0;
        this.diskWeightBytes = disk > 0 ? disk : 0;
        this.poolHitPct = Number.isFinite(hit) && hit >= 0 ? hit : -1;
        this.serving = nativeState === 'busy';
        this.loadDone = nativeState === 'ready' || nativeState === 'busy';
        hilog.info(domain, TAG, `native topology state=${nativeState} rss=${rss} expertRam=${expertRam} hit=${hit} disk=${disk}`);
        return;
      }
      const logPath = this.filesDir + '/llama_debug.log';
      const st = fs.statSync(logPath);
      const len = st.size;
      // 只解析本次 app 会话新写入的内容：重开 app 时日志里还留着上一轮的
      // POOL/命中行，若不建基线就会把旧值当成当前数据（等 30s 后才会被 clear）。
      if (this.logBaseline < 0 || len < this.logBaseline) {
        // 首次采样：把已有内容整体当历史；日志变小说明被新一轮启动截断/轮转 → 从头读
        this.logBaseline = this.logBaseline < 0 ? len : 0;
      }
      // 服务器运行时 native 监控线程每 2s 写一次 [monitor] 行；超过 30s 未更新即视为已停止
      const ageMs = Date.now() - st.mtime * 1000;
      const fresh = len > 0 && ageMs <= 30000;
      // 对端数据通道要用它：它决定对端柱显示的是"推理内存"还是 "—"。这里用更紧的阈值 ——
      // server 在跑时 native 每 2s 写一次 [monitor]，10s 内没有任何新写入就说明本机没在跑 server。
      // （若沿用 30s，App 刚重启时上一轮留下的旧日志会被误判成"正在推理"，对端就会看到本机 App 的 PSS。）
      this.serving = len > 0 && ageMs <= 10000;
      hilog.info(domain, TAG, `mem refresh: len=${len} base=${this.logBaseline} mtimeMs=${st.mtime * 1000} nowMs=${Date.now()} fresh=${fresh}`);
      if (!fresh || len - this.logBaseline <= 0) {
        // 未在推理：清空专家/权重（App 内存由 refreshMem() 单独提供，不受影响、始终有值）
        this.clearPoolStats();
        return;
      }
      const cap = 1048576;
      const span = len - this.logBaseline;
      const readFrom = span <= cap ? this.logBaseline : len - cap;
      const readLen = len - readFrom;
      const fd = fs.openSync(logPath, fs.OpenMode.READ_ONLY);
      let text = '';
      const buf = new ArrayBuffer(readLen);
      fs.readSync(fd.fd, buf, { offset: readFrom, length: readLen });
      text = buffer.from(buf).toString('utf-8');
      fs.closeSync(fd);
      let ram = 0;
      let total = 0;
      let arena = 0;
      let rssKb = 0;
      let poolBytes = 0;          // 面板"专家"显示的字节数（取日志里最后出现的那个池占用）
      let sawPoolBytes = false;   // 只有"真请求之后"（或填充进度行）才算，避免启动预热就出值
      let sawLarge = false;
      let demandBytes = 0;
      let prevHits = 0;           // 上一条统计行的累计 hit/miss（用于算增量命中率）
      let prevMisses = 0;
      let baseHits = -1;          // 闸门打开时的累计值（= 上一行，即启动预热行）
      let baseMisses = -1;
      let lastHits = -1;          // 最新一条统计行的累计值
      let lastMisses = -1;
      const lines = text.split('\n');
      for (let i = 0; i < lines.length; i++) {
        const ln = lines[i];
        if (ln.indexOf('POOL: init group') >= 0) {
          const me = ln.match(/experts=(\d+)/);
          const mc = ln.match(/cap=(\d+)\//);
          const ma = ln.match(/arena=(\d+)/);
          if (me && mc) {
            total += parseInt(me[1]);
            ram += parseInt(mc[1]);
          }
          if (ma) {
            arena = parseInt(ma[1]);
          }
        } else if (ln.indexOf('[monitor] VmRSS=') >= 0) {
          const mr = ln.match(/VmRSS=(\d+)/);
          if (mr) {
            rssKb = parseInt(mr[1]);
          }
        } else if (ln.indexOf('POOL: fill ') >= 0) {
          // 启动填充进度（native 补打）。native 侧已保证这类行只在真 prefill 时出现
          // （启动探测那次 2-token decode 不再预取），所以见到它就可以开始显示
          const mf = ln.match(/loaded=([\d.]+) capacity=([\d.]+) MiB/);
          if (mf) {
            poolBytes = parseFloat(mf[1]) * 1024 * 1024;
            sawPoolBytes = true;
          }
        } else if (ln.indexOf('POOL: cache eval=') >= 0) {
          // POOL: cache eval=<n_eval> tokens=<n> ... hit=<..> miss=<..> (X%) ... resident=<slots> <MiB>
          // 真实请求判据：eval>0（decode）或 tokens>=4（prefill，此时 eval 停在 0）；
          // 服务器启动预热是 tokens<=2 的 eval=0，排除
          // 闸门：先见到真正的请求行（eval>0 或 tokens>=4，即 prefill/decode）才统计命中率，
          // 这样跳过服务器启动的池预热行（eval=0 tokens=2），又能统计 follower 的 eval=0 tokens=1 decode 行
          const mn = ln.match(/cache eval=(\d+)/);
          const mt = ln.match(/tokens=(\d+)/);
          const nEval = mn ? parseInt(mn[1]) : 0;
          const nTok = mt ? parseInt(mt[1]) : 0;
          if (nEval > 0 || nTok >= 4) {
            sawLarge = true;
          }
          // 专家占用：用 resident（当前池内驻留字节）。只在"真请求之后"才取值 ——
          // 启动预热那次留下的少量驻留不给用户看，否则还没发 prompt 就有值了
          const mres = ln.match(/resident=(\d+) slots ([\d.]+) MiB/);
          if (mres && sawLarge) {
            poolBytes = parseFloat(mres[2]) * 1024 * 1024;
            sawPoolBytes = true;
          }
          // 命中率：算"自闸门打开以来的增量"，而不是自启动以来的累计值（那会带上启动预热，
          // 一上来就是 80%+）。首条真请求池还是冷的 → 偏低，随后爬升并稳定在 ~97%。
          const mhm = ln.match(/hit=(\d+) miss=(\d+)/);
          if (mhm) {
            const h = parseInt(mhm[1]);
            const m = parseInt(mhm[2]);
            if (sawLarge) {
              if (baseHits < 0) {
                baseHits = prevHits;
                baseMisses = prevMisses;
              }
              lastHits = h;
              lastMisses = m;
            }
            prevHits = h;
            prevMisses = m;
          }
          if (sawLarge) {
            const md = ln.match(/demand=([\d.]+) prefetch=([\d.]+) MiB/);
            if (md) {
              demandBytes = (parseFloat(md[1]) + parseFloat(md[2])) * 1024 * 1024;
            }
          }
        }
      }
      // 命中率：闸门之后的累计增量
      let dh = 0;
      let dm = 0;
      if (baseHits >= 0 && lastHits >= baseHits && lastMisses >= baseMisses) {
        dh = lastHits - baseHits;
        dm = lastMisses - baseMisses;
      }
      const haveHit = dh + dm > 0;
      // native 监控线程写出的 RSS 同样用于空闲状态的基线内存。
      if (rssKb > 0) {
        this.appRssBytes = rssKb * 1024;
      }

      if (total > 0) {
        this.ramExperts = ram;
        this.diskExperts = total - ram;
        // 磁盘档专家：本机分到的全部专家权重总量 = 总专家数 × 每专家字节（与是否推理无关）
        if (ram > 0 && arena > 0) {
          this.diskWeightBytes = total * (arena / ram);
        }
        // 专家占用 = 当前池内驻留字节（resident / 填充进度），从 0 长到容量；未推理显示 —
        if (sawPoolBytes) {
          this.expertRamBytes = poolBytes;
        } else if (haveHit) {
          // 兜底（旧日志没有 resident 字段）：累计加载量按 arena 封顶
          const capBytes = arena > 0 ? arena : demandBytes;
          this.expertRamBytes = demandBytes < capBytes ? demandBytes : capBytes;
        } else {
          this.expertRamBytes = 0;
        }
        if (haveHit) {
          this.poolHitPct = 100.0 * dh / (dh + dm);
        } else {
          this.poolHitPct = -1;
        }
      } else {
        // 本次运行下尚未出现 POOL 几何（未开 hot-cold 或池未建立）
        this.clearPoolStats();
      }
      hilog.info(domain, TAG, `pool done: total=${total} poolBytes=${this.expertRamBytes} dHit=${dh} dMiss=${dm} expertRam=${this.expertRamBytes} hit=${this.poolHitPct}`);
    } catch (e) {
      hilog.error(domain, TAG, 'refreshPoolStats error: %{public}s', `${e}`);
    }
  }
  clearPoolStats(): void {
    this.ramExperts = 0;
    this.diskExperts = 0;
    this.expertRamBytes = 0;
    this.diskWeightBytes = 0;
    this.poolHitPct = -1;
  }

  // 30002 由 EntryAbility 持有的 PeerPresenceService 常驻监听；
  // 这里只同步页面当前状态，不参与监听生命周期。
  syncPresenceStats(): void {
    const snapshot: PeerPresenceSnapshot = {
      rank: this.roleIsMaster ? 0 : 1,
      serving: this.serving ? 1 : 0,
      ready: this.loadDone ? 1 : 0,
      rss: this.appRssBytes,
      expertRam: this.expertRamBytes,
      hit: this.poolHitPct,
      disk: this.diskWeightBytes,
      memTotal: this.memTotalBytes,
      memAvail: this.memFreeBytes
    };
    PeerPresenceService.update(snapshot);
  }

  private parsePeerDevice(host: string, text: string): PeerDevice | null {
    try {
      const payload = JSON.parse(text) as PeerDiscoveryPayload;
      // 只接受本应用的统计应答，避免把同网段其它服务误判为鸿蒙对端。
      if (payload.rank === undefined && payload.name === undefined) {
        return null;
      }
      const resolvedIp = payload.ip && payload.ip.length > 0 ? payload.ip : host;
      if (!this.isUsablePeerIp(resolvedIp, this.localEthIp())) {
        return null;
      }
      const device: PeerDevice = {
        ip: resolvedIp,
        name: payload.name && payload.name.length > 0 ? payload.name : 'HarmonyOS PC',
        rank: typeof payload.rank === 'number' ? payload.rank : 0,
        serving: payload.serving === 1,
        ready: payload.ready === 1,
        available: true
      };
      return device;
    } catch (e) {
      return null;
    }
  }

  private probePeerDevice(host: string, timeoutMs: number = 1500): Promise<PeerDevice | null> {
    return new Promise<PeerDevice | null>((resolve) => {
      const tcp = socket.constructTCPSocketInstance();
      let text = '';
      let done = false;
      let connected = false;
      const genericDevice: PeerDevice = {
        ip: host,
        name: 'HarmonyOS PC',
        rank: 0,
        serving: false,
        ready: false,
        available: true
      };
      const finish = (device: PeerDevice | null) => {
        if (done) {
          return;
        }
        done = true;
        clearTimeout(timer);
        try { tcp.close(); } catch (e) {}
        resolve(device);
      };
      const timer = setTimeout(() => { finish(connected ? genericDevice : null); }, timeoutMs);
      tcp.on('message', (v: socket.SocketMessageInfo) => {
        try {
          text += buffer.from(v.message).toString('utf-8');
          if (text.indexOf('}') >= 0) {
            const parsed = this.parsePeerDevice(host, text);
            finish(parsed !== null ? parsed : genericDevice);
          }
        } catch (e) {}
      });
      tcp.on('close', () => {
        const parsed = text.length > 0 ? this.parsePeerDevice(host, text) : null;
        finish(parsed !== null ? parsed : (connected ? genericDevice : null));
      });
      tcp.on('error', () => { finish(null); });
      tcp.connect({
        address: { address: host, port: PEER_STATS_PORT },
        timeout: Math.min(1200, Math.max(300, timeoutMs - 100))
      })
        .then(() => {
          connected = true;
          // 服务端会主动回一行 JSON；即使读事件丢失，TCP 连接成功本身已证明端口可用。
          setTimeout(() => { finish(genericDevice); }, Math.min(350, Math.max(150, timeoutMs / 3)));
          tcp.send({ data: 'stats\n' }).catch(() => {});
        })
        .catch(() => { finish(null); });
    });
  }

  private compareIpv4(a: string, b: string): number {
    const pa = a.split('.');
    const pb = b.split('.');
    for (let i = 0; i < 4; i++) {
      const va = parseInt(pa[i]) || 0;
      const vb = parseInt(pb[i]) || 0;
      if (va !== vb) {
        return va - vb;
      }
    }
    return 0;
  }

  private isUsablePeerIp(ip: string, localIp: string): boolean {
    const parts = ip.split('.');
    if (parts.length !== 4 || ip === localIp) {
      return false;
    }
    for (let i = 0; i < 4; i++) {
      const part = parseInt(parts[i]);
      if (!/^\d+$/.test(parts[i]) || part < 0 || part > 255) {
        return false;
      }
    }
    const last = parseInt(parts[3]);
    // /24 网络地址和广播地址不是可连接主机
    return last > 0 && last < 255;
  }

  private resetPeerDiscovery(): void {
    this.peerScanGeneration++;
    this.peerScanning = false;
    this.peerScanAtMs = 0;
    this.peerDevices = [];
    this.selectedPeerIp = '';
    this.peerScanText = '正在搜索对端设备...';
    this.distConfig = '';
    this.clearPeerStats();
    try { testNapi.setdistconfig(0, 1, '', ''); } catch (e) {}
  }

  async refreshPeerDevices(force: boolean = false, manual: boolean = false): Promise<void> {
    if (this.peerScanning) {
      return;
    }
    // 已经探测到可用设备后停止周期扫描；后续只允许用户手动刷新。
    if (!manual && !force && this.firstAvailablePeer() !== null) {
      return;
    }
    const now = Date.now();
    if (!force && this.peerScanAtMs > 0 && now - this.peerScanAtMs < PEER_SCAN_INTERVAL_MS) {
      return;
    }
    const localIp = this.localEthIp();
    if (localIp.length === 0) {
      this.peerScanText = '未获取到以太网 IP';
      return;
    }
    const parts = localIp.split('.');
    if (parts.length !== 4) {
      this.peerScanText = '以太网 IP 格式异常';
      return;
    }
    const base = `${parts[0]}.${parts[1]}.${parts[2]}`;
    const generation = this.peerScanGeneration;
    this.peerScanning = true;
    this.peerScanText = '正在探测对端设备...';
    try {
      let found: PeerDevice[] = [];
      const neighborList: NetworkNeighbor[] = [];
      try {
        const neighborJson = testNapi.getnetworkneighbors();
        const neighbors = JSON.parse(neighborJson) as NetworkNeighbor[];
        for (let i = 0; i < neighbors.length; i++) {
          const n = neighbors[i];
          if (n.iface !== 'eth0' || !this.isUsablePeerIp(n.ip, localIp) || n.ip.indexOf(base + '.') !== 0) {
            continue;
          }
          let duplicate = false;
          for (let j = 0; j < neighborList.length; j++) {
            if (neighborList[j].ip === n.ip) {
              duplicate = true;
              break;
            }
          }
          if (!duplicate) {
            neighborList.push(n);
          }
        }
      } catch (e) {
        hilog.warn(domain, TAG, 'neighbor discovery unavailable: %{public}s', `${e}`);
      }

      if (neighborList.length > 0) {
        // 邻居数量通常很少；每批 8 个并发，既快又不会饿死事件循环。
        for (let start = 0; start < neighborList.length; start += 8) {
          const end = Math.min(neighborList.length, start + 8);
          const probes: Promise<PeerDevice | null>[] = [];
          for (let i = start; i < end; i++) {
            probes.push(this.probePeerDevice(neighborList[i].ip));
          }
          const results = await Promise.all(probes);
          for (let i = 0; i < results.length; i++) {
            const n = neighborList[start + i];
            const peer = results[i];
            if (peer !== null) {
              found.push(peer);
            } else {
              const offline: PeerDevice = {
                ip: n.ip,
                name: 'HarmonyOS PC',
                rank: 0,
                serving: false,
                ready: false,
                available: false
              };
              found.push(offline);
            }
          }
        }
      } else {
        // 邻居表为空时保留一次网段扫描，用于首次发现尚未进入 ARP 的对端。
        for (let start = 1; start <= 254; start += 32) {
          const probes: Promise<PeerDevice | null>[] = [];
          const end = Math.min(254, start + 31);
          for (let hostId = start; hostId <= end; hostId++) {
            const host = `${base}.${hostId}`;
            if (host !== localIp) {
              probes.push(this.probePeerDevice(host, 700));
            }
          }
          const results = await Promise.all(probes);
          for (let i = 0; i < results.length; i++) {
            const peer = results[i];
            if (peer !== null) {
              found.push(peer);
            }
          }
        }
      }
      if (generation !== this.peerScanGeneration) {
        return;
      }
      const merged: PeerDevice[] = [];
      for (let i = 0; i < found.length; i++) {
        let index = -1;
        for (let j = 0; j < merged.length; j++) {
          if (merged[j].ip === found[i].ip) {
            index = j;
            break;
          }
        }
        if (index < 0) {
          merged.push(found[i]);
        } else if (found[i].available || !merged[index].available) {
          // 同一 IP 只保留一条；可用结果覆盖离线结果。
          merged[index] = found[i];
        }
      }
      found = merged;
      const preferredPeer = this.preferredPeerIp.trim();
      if (preferredPeer.length > 0 && !found.some((peer: PeerDevice): boolean => peer.ip === preferredPeer)) {
        found.push({
          ip: preferredPeer,
          name: '已保存的协同设备',
          rank: this.roleIsMaster ? 1 : 0,
          serving: false,
          ready: false,
          available: false
        });
      }
      found.sort((a: PeerDevice, b: PeerDevice) => this.compareIpv4(a.ip, b.ip));
      this.peerDevices = found;
      let selectionStillValid = false;
      for (let i = 0; i < found.length; i++) {
        if (found[i].ip === this.selectedPeerIp && found[i].available) {
          selectionStillValid = true;
          break;
        }
      }
      if (!selectionStillValid && preferredPeer.length > 0) {
        this.selectedPeerIp = preferredPeer;
      } else if (!selectionStillValid) {
        const first = this.firstAvailablePeer();
        // 发现可用设备后默认勾选；实际 rank 仍按两端 IP 升序计算。
        this.selectedPeerIp = first !== null ? first.ip : '';
      }
      this.peerScanAtMs = Date.now();
      let availableCount = 0;
      for (let i = 0; i < found.length; i++) {
        if (found[i].available) {
          availableCount++;
        }
      }
      this.peerScanText = found.length > 0
        ? `已发现 ${found.length} 台设备，${availableCount} 台协同端口可用`
        : '未发现以太网对端设备';
      hilog.info(domain, TAG,
        'peer discovery local=%{public}s found=%{public}d available=%{public}d selected=%{public}s',
        localIp, found.length, availableCount, this.selectedPeerIp);
      if (this.selectedPeerIp.length > 0) {
        this.applyDistConfig();
      }
    } catch (e) {
      this.peerScanText = '对端设备探测失败';
      hilog.error(domain, TAG, 'peer discovery error: %{public}s', `${e}`);
    } finally {
      if (generation === this.peerScanGeneration) {
        this.peerScanning = false;
      }
    }
  }

  // 每 2s 取一次对端数据；连不上/超时就按"过期"处理
  // retry=true 表示这是"拿到 0 字节后的立刻重试"，再失败就不再重试，等下一轮
  pollPeerStats(retry: boolean = false): void {
    if (this.selectedPeerIp.length === 0) {
      // 只有拓扑实际展示对端时才拉取对端数据。
      this.clearPeerStats();
      return;
    }
    if (this.peerPolling) {
      return;
    }
    const host = this.peerHostForStats();
    if (host.length === 0) {
      return;
    }
    this.peerPolling = true;
    const tcp = socket.constructTCPSocketInstance();
    let text = '';
    let done = false;
    const finish = (ok: boolean) => {
      if (done) {
        return;
      }
      done = true;
      this.peerPolling = false;
      try { tcp.close(); } catch (e) {}
      // 只要拿到字节就算成功：实测有个别情况下 close 事件不按时到，
      // 但数据已经收齐（bytes>0），不能因为 ok=false 就把它丢掉
      if (text.length === 0) {
        this.peerFailCount++;
        if (this.peerFailCount === 1 || this.peerFailCount % 10 === 0) {
          hilog.error(domain, TAG, 'peer poll FAILED host=%{public}s ok=%{public}d bytes=%{public}d n=%{public}d',
            host, ok ? 1 : 0, text.length, this.peerFailCount);
        }
        if (!retry) {
          // 这一轮白跑（多半是上面那条竞态），立刻重试一次，别等下一个 2s
          setTimeout(() => { this.pollPeerStats(true); }, 100);
          return;
        }
      } else {
        this.peerFailCount = 0;
        if (this.peerOkCount < 2) {
          this.peerOkCount++;
          hilog.info(domain, TAG, 'peer poll OK host=%{public}s bytes=%{public}d sample=%{public}s',
            host, text.length, text.substring(0, 48));
        }
      }
      if (text.length === 0 && this.peerFailCount >= 2) {
        this.setPeerReachability(host, false);
        this.clearPeerStats();
      }
      this.applyPeerStats(text);
    };
    const timer = setTimeout(() => { finish(false); }, 1000);
    tcp.on('message', (v: socket.SocketMessageInfo) => {
      try {
        text += buffer.from(v.message).toString('utf-8');
        // 一行 JSON 收齐就立刻收尾，不等 close 事件
        if (text.indexOf('}') >= 0) {
          clearTimeout(timer);
          finish(true);
        }
      } catch (e) {}
    });
    tcp.on('close', () => { clearTimeout(timer); finish(true); });
    tcp.on('error', () => { clearTimeout(timer); finish(false); });
    tcp.connect({ address: { address: host, port: PEER_STATS_PORT }, timeout: 800 })
      .then(() => {
        // 连上后主动发一个请求字节，服务端收到才回数据
        tcp.send({ data: 'stats\n' }).catch(() => {
          clearTimeout(timer);
          finish(false);
        });
      })
      .catch(() => { clearTimeout(timer); finish(false); });
  }

  applyPeerStats(json: string): void {
    if (json.length > 0) {
      try {
        const o = JSON.parse(json) as Record<string, number>;
        this.peerServing = Number(o['serving']) === 1;
        this.peerReady = Number(o['ready']) === 1;
        this.peerRssBytes = Number(o['rss']) || 0;
        this.peerExpertRamBytes = Number(o['expertRam']) || 0;
        this.peerHitPct = o['hit'] === undefined ? -1 : Number(o['hit']);
        this.peerDiskWeightBytes = Number(o['disk']) || 0;
        this.peerTs = Date.now();
        this.setPeerReachability(this.selectedPeerIp, true);
        return;
      } catch (e) {
        hilog.error(domain, TAG, 'peer stats parse error: %{public}s', `${e}`);
      }
    }
    // 取不到：超过一个刷新周期就清空，避免显示陈旧数据
    if (Date.now() - this.peerTs > PEER_STATS_STALE_MS) {
      this.clearPeerStats();
    }
  }

  clearPeerStats(): void {
    // 已经是"无数据"就不重复赋值，免得每 2s 触发一次无意义的重绘
    if (this.peerRssBytes === 0 && this.peerExpertRamBytes === 0 &&
        this.peerHitPct < 0 && this.peerDiskWeightBytes === 0 && !this.peerServing && !this.peerReady) {
      return;
    }
    this.peerRssBytes = 0;
    this.peerExpertRamBytes = 0;
    this.peerHitPct = -1;
    this.peerDiskWeightBytes = 0;
    this.peerServing = false;
    this.peerReady = false;
    this.peerTs = 0;
  }

  aboutToAppear(): void {
    this.filesDir = this.context.getApplicationContext().filesDir;
    // 页面初始化视为新的探测会话，不能复用上一轮设备/选中状态。
    PeerPresenceService.start(this.filesDir);
    this.resetPeerDiscovery();
    emitter.off(PEER_START_EVENT);
    emitter.on(PEER_START_EVENT, (data: emitter.EventData) => {
      this.onPeerStartEvent(data);
    });
    try {
      if (testNapi) {
        try {
          const ipsJson: string = testNapi.getnetworkips();
          hilog.info(domain, TAG, 'getnetworkips: %{public}s', ipsJson);
          const ips = JSON.parse(ipsJson) as Record<string, string>;
          this.rpcWifiIp = ips['wifi'] || '未获取到 WiFi IP';
          this.rpcUsbIp  = ips['usb']  || '未获取到 USB IP';
          this.rpcEthIp  = ips['eth']  || '未获取到以太网 IP';
          if (/^\d{1,3}(\.\d{1,3}){3}$/.test(this.rpcEthIp)) {
            this.masterIp = this.rpcEthIp;
          }
        } catch (e) {
          const err = e as BusinessError;
          hilog.error(domain, TAG, 'getnetworkips failed: %{public}s', err?.message);
          this.rpcWifiIp = '获取失败';
          this.rpcUsbIp  = '获取失败';
          this.rpcEthIp  = '获取失败';
        }
      }
    } catch (e) {
      hilog.error(domain, TAG, 'aboutToAppear error: %{public}s', `${e}`);
    }
    const migrationError = migrateLegacyLlamaModels(this.filesDir);
    if (migrationError.length > 0) this.loadStatus = migrationError;
    this.refreshModelList();
    const saved = loadLlamaInferenceConfig(this.filesDir);
    if (saved !== null) {
      if (this.modelList.indexOf(saved.model) >= 0) {
        this.selectedBuiltin = saved.model;
        this.selectedModel = this.filesDir + '/' + saved.model;
      }
      this.contextSize = saved.contextSize;
      this.otherargs = saved.otherArgs;
      this.hotColdOn = saved.hotCold;
      this.bisectOn = saved.expertSkip;
      this.bisectConfig = saved.skipRange;
      this.distMode = saved.distMode;
      this.selectedPeerIp = saved.peerIp;
      this.roleIsMaster = saved.roleMaster;
      this.port = saved.port;
      this.loadStatus = '配置已保存 · 请求时加载';
    }
    const pendingStart = PeerPresenceService.takePendingStart();
    if (pendingStart !== null) {
      this.handlePeerStartRequest(pendingStart);
    }
    this.preferredPeerIp = this.selectedPeerIp;
    this.loadDone = false;
    this.starting = false;
    this.startMemTimer();
    this.refreshPeerDevices(true);
  }

  // 页面每次显示（含从后台切回）都确保刷新定时器在跑
  onPageShow(): void {
    this.refreshModelList();
    this.restoreSavedInferenceConfig();
    this.startMemTimer();
    this.refreshPeerDevices();
  }

  onPageHide(): void {
    this.stopMemTimer();
  }

  startMemTimer(): void {
    if (this.memTimer < 0) {
      this.refreshMem();
      this.refreshPoolStats();
      this.syncPresenceStats();
      this.pollPeerStats();
      this.memTimer = setInterval(() => {
        this.refreshMem();
        this.refreshPoolStats();
        this.syncPresenceStats();
        this.pollPeerStats();
        this.refreshPeerDevices();
      }, TOPOLOGY_REFRESH_MS);
    }
  }

  stopMemTimer(): void {
    if (this.memTimer >= 0) {
      clearInterval(this.memTimer);
      this.memTimer = -1;
    }
  }

  aboutToDisappear(): void {
    emitter.off(PEER_START_EVENT);
    this.stopMemTimer();
    this.releaseRunningLock();
  }

  acquireRunningLock(): void {
    if (this.bgLock) {
      return;
    }
    try {
      let lockType = runningLock.RunningLockType.BACKGROUND;
      try {
        if (runningLock.isSupported(runningLock.RunningLockType.BACKGROUND_USER_IDLE)) {
          lockType = runningLock.RunningLockType.BACKGROUND_USER_IDLE;
        }
      } catch (_) {}
      runningLock.create('llama_server', lockType).then((lock: runningLock.RunningLock) => {
          this.bgLock = lock;
          lock.hold(-1);
          hilog.info(domain, TAG, 'running lock acquired type=%{public}d', lockType);
        }).catch((err: BusinessError) => {
          hilog.error(domain, TAG, 'create running lock failed: %{public}s', `${err}`);
        });
    } catch (e) {
      hilog.error(domain, TAG, 'running lock error: %{public}s', `${e}`);
    }
  }

  releaseRunningLock(): void {
    if (this.lockTimer >= 0) {
      clearInterval(this.lockTimer);
      this.lockTimer = -1;
    }
    if (this.bgLock) {
      try {
        this.bgLock.unhold();
        this.bgLock = null;
        hilog.info(domain, TAG, 'running lock released');
      } catch (e) {
        hilog.error(domain, TAG, 'unlock error: %{public}s', `${e}`);
      }
    }
  }
  async toWebBrowser(url: string): Promise<void> {
    let want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url,
      parameters: {
        bundleName: this.context.abilityInfo.bundleName,
        pushParams: this.context.abilityInfo.bundleName,
      }
    };
    return await this.context.startAbility(want);
  }
  // 手绘笔记本图标：屏幕分「内存 / 磁盘」两柱，信息写在柱子内部
  // 手绘笔记本图标：屏幕分「内存 / 磁盘」两柱，柱内显示各自指标
  // 注意：内部直接引用 @State（@Builder 按值传参不是响应式的，变化不会刷新）
  @Builder
  lapTop(isSelf: boolean) {
    Column() {
      Text(isSelf ? (this.showPeerTopology() ? ('本机 ' + (this.roleIsMaster ? '(rank0)' : '(rank1)')) : '本机')
                  : ('对端 ' + (this.roleIsMaster ? '(rank1)' : '(rank0)')))
        .fontSize(27).fontWeight(FontWeight.Bold).margin({ bottom: 9 })
      // 屏幕：两柱（信息写在柱内）
      Row() {
        // 内存柱
        Column() {
          Column() {
            Text('内存').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#334155')
            Text(!isSelf && !this.peerServing ? 'App 内存占用' : '推理内存占用')
              .fontSize(18).fontColor('#334155').margin({ top: 8 })
            Text(this.fmtGB(isSelf ? this.appRssBytes : this.peerRssBytes)).fontSize(20).fontColor('#0A59F7')
            Text('专家缓存').fontSize(18).fontColor('#334155').margin({ top: 8 })
            Text(this.fmtGB(isSelf ? this.expertRamBytes : this.peerExpertRamBytes)).fontSize(20).fontColor('#059669')
            Text('命中').fontSize(18).fontColor('#334155').margin({ top: 8 })
            Text(this.hitLabel(isSelf ? this.poolHitPct : this.peerHitPct))
              .fontSize(20).fontColor('#8B5CF6')
          }
          .width(116)
          .height(280)
          .borderRadius(9)
          .border({ width: 1, color: '#333333' })
          .backgroundColor('#EAF2FE')
          .alignItems(HorizontalAlign.Center)
          .justifyContent(FlexAlign.Start)
          .padding(8)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
        // 磁盘柱
        Column() {
          Column() {
            Text('磁盘').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#334155')
            Text('模型文件').fontSize(18).fontColor('#334155').margin({ top: 8 })
            Text(this.fmtGB(isSelf ? this.diskWeightBytes : this.peerDiskWeightBytes))
              .fontSize(20).fontColor('#666666').margin({ top: 4 })
          }
          .width(116)
          .height(280)
          .borderRadius(9)
          .border({ width: 1, color: '#333333' })
          .backgroundColor('#EFEFEF')
          .alignItems(HorizontalAlign.Center)
          .justifyContent(FlexAlign.Start)
          .padding(8)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
      }
      .padding(12)
      .border({ width: 3, color: '#333333' })
      .borderRadius(12)
      .backgroundColor('#FAFAFA')
      // 底座
      Row().width('62%').height(12).backgroundColor('#333333').borderRadius(5).margin({ top: 5 })
      Text(isSelf ? (this.showPeerTopology() ? this.distIp(0) : this.masterIp) : this.distIp(1))
        .fontSize(22).fontColor('#888888').margin({ top: 9 })

    }
    .width(300)
    .alignItems(HorizontalAlign.Center)
  }

  private markPeerAvailable(ip: string): void {
    if (!this.isUsablePeerIp(ip, this.localEthIp())) {
      return;
    }
    for (let i = 0; i < this.peerDevices.length; i++) {
      if (this.peerDevices[i].ip === ip) {
        return;
      }
    }
    const peer: PeerDevice = {
      ip: ip,
      name: '协同对端',
      rank: 0,
      serving: false,
      ready: false,
      available: true
    };
    this.peerDevices = this.peerDevices.concat([peer]);
  }

  private requestPeerStart(peerIp: string): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      const tcp = socket.constructTCPSocketInstance();
      let done = false;
      let sent = false;
      const finish = (ok: boolean) => {
        if (done) {
          return;
        }
        done = true;
        clearTimeout(timer);
        try { tcp.close(); } catch (e) {}
        resolve(ok);
      };
      const timer = setTimeout(() => { finish(false); }, 1500);
      tcp.on('close', () => { finish(sent); });
      tcp.on('error', () => { finish(false); });
      tcp.connect({ address: { address: peerIp, port: PEER_STATS_PORT }, timeout: 1200 })
        .then(() => {
          const command: PeerStartCommand = {
            type: 'start',
            from: this.localEthIp(),
            split: this.distMode,
            model: this.selectedBuiltin,
            contextSize: this.contextSize,
            otherArgs: this.otherargs,
            hotCold: this.hotColdOn,
            expertSkip: this.bisectOn,
            skipRange: this.bisectConfig,
            port: this.port
          };
          tcp.send({ data: JSON.stringify(command) + '\n' }).then(() => {
            sent = true;
            // 对端 presence 服务收到命令后会立即发事件；稍等片刻再断开。
            setTimeout(() => { finish(true); }, 350);
          }).catch(() => { finish(false); });
        })
        .catch(() => { finish(false); });
    });
  }

  private async onPeerStartEvent(data: emitter.EventData): Promise<void> {
    try {
      PeerPresenceService.takePendingStart();
      const eventData = data.data as PeerStartEventData;
      const request = JSON.parse(eventData.payload) as PeerStartRequest;
      await this.handlePeerStartRequest(request);
    } catch (e) {
      hilog.error(domain, TAG, 'peer start event error: %{public}s', `${e}`);
    }
  }

  private async handlePeerStartRequest(request: PeerStartRequest): Promise<void> {
    if (request.fromIp.length === 0) {
      return;
    }
    if (this.loadDone || this.starting || this.workerInstance !== null) {
      hilog.info(domain, TAG, 'peer start skipped: llama-server already running or starting');
      return;
    }
    this.selectedPeerIp = request.fromIp;
    this.slaveIp = request.fromIp;
    this.distMode = request.split === 'expert' || request.split === 'neuron' ? request.split : 'layer';
    this.markPeerAvailable(request.fromIp);
    this.applyDistConfig();
    this.saveCascadeConfig();
    this.message = `收到 ${request.fromIp} 的启动请求，正在启动本机服务...`;
    await this.doStartServer(true);
  }

  // 防重复启动：点第二次会再起一个 llama-server 实例，占住 8080/30001 让后一个秒退。
  // starting 要一直保持到「就绪/失败」被 load watch 判出来为止 —— 只在 doStartServerInner
  // 的执行瞬间置位是不够的，隔一秒再点仍会放行。
  async doStartServer(fromPeer: boolean = false): Promise<void> {
            if (this.starting || this.loadDone || this.workerInstance !== null) {
              hilog.warn(domain, TAG, 'start already in progress, second click ignored');
              return;
            }
            this.starting = true;
            try {
              // 首次进入页面时设备探测和用户点击可能同时发生。先完成一轮探测，
              // 再决定是否启动协同；否则点击瞬间 selectedPeerIp 仍为空，本机
              // 会直接进入 rank0 等待，对端却从未收到启动请求。
              if (!fromPeer) {
                await this.refreshPeerDevices(true);
                for (let wait = 0; wait < 4 && this.peerScanning; wait++) {
                  await new Promise<void>((resolve) => setTimeout(resolve, 250));
                }
              }
              if (this.selectedPeerIp.length > 0) {
                if (!fromPeer) {
                  if (!this.peerIsAvailable(this.selectedPeerIp)) {
                    this.message = `协同设备 ${this.selectedPeerIp} 当前不可用`;
                    this.starting = false;
                    return;
                  }
                  const peerStarted = await this.requestPeerStart(this.selectedPeerIp);
                  if (!peerStarted) {
                    this.message = `无法通知对端 ${this.selectedPeerIp} 启动服务`;
                    this.starting = false;
                    return;
                  }
                }
                if (!this.roleIsMaster && this.peerReady) {
                  // rank0 已真正 ready 时，若 30001 不可用说明它是普通单机服务。
                  // rank0 仍在加载时不要等待，必须并行启动 follower 才能完成握手。
                  const distReady = await checkTcpReachable(this.selectedPeerIp, DIST_PORT);
                  if (!distReady) {
                    const httpReady = await checkTcpReachable(this.selectedPeerIp, this.port);
                    if (httpReady) {
                      this.message = 'rank0 当前为单机模式，rank1 已切换为客户端；可直接对话，重启 rank0 为协同模式后可重新加入';
                      this.starting = false;
                      return;
                    }
                    this.message = `rank0 ${this.selectedPeerIp}:30001 未就绪，启动已取消`;
                    this.starting = false;
                    return;
                  }
                }
              }
              await this.doStartServerInner();
            } catch (e) {
              hilog.error(domain, TAG, 'doStartServer error: %{public}s', `${e}`);
            }
            if (this.workerInstance == null) {
              // 提前 return 的错误路径（未真正启动 server）→ 允许重试
              this.starting = false;
            }
  }
  async doStartServerInner(): Promise<void> {
            this.acquireRunningLock();
            // bisection method: set activated experts k1/k2 (0,0 = stock)
            try {
              if (this.bisectOn && this.bisectConfig && this.bisectConfig.indexOf(':') >= 0) {
                const parts = this.bisectConfig.split(':');
                testNapi.setbisect(parseInt(parts[0]) || 0, parseInt(parts[1]) || 0);
              } else {
                testNapi.setbisect(0, 0);
              }
            } catch (e) {
              hilog.error(0x0000, 'StartServer', 'setbisect error: %{public}s', `${e}`);
            }
            // 多进程（每 rank 一个进程）：rank 配置 -> LLAMA_DIST_* 环境变量，
            // 必须在 openllama 之前设置（模型装载前读取）
            try {
              let distCfg = '';
              if (this.selectedPeerIp.length > 0) {
                if (this.buildCoopEndpoints() === null) {
                  this.message = '启动失败：协同设备状态或本机以太网地址无效';
                  return;
                }
                this.applyDistConfig();
                distCfg = this.distConfig.trim();
              }
              if (distCfg.length === 0) {
                testNapi.setdistconfig(0, 1, '', '');
              } else {
                let body = distCfg;
                let split = '';
                const hash = distCfg.indexOf('#');
                if (hash >= 0) {
                  body = distCfg.substring(0, hash).trim();
                  split = distCfg.substring(hash + 1).trim();
                }
                const at = body.indexOf('@');
                const head = at >= 0 ? body.substring(0, at).trim() : body;
                const endpoints = at >= 0 ? body.substring(at + 1).trim() : '';
                const parts = head.split('/');
                const rank = parseInt(parts[0]) || 0;
                const nRanks = parseInt(parts[1]) || 1;
                testNapi.setdistconfig(rank, nRanks, endpoints, split);
              }
            } catch (e) {
              hilog.error(0x0000, 'StartServer', 'setdistconfig error: %{public}s', `${e}`);
            }
            // 检查 --rpc 参数，若存在则先探测连通性
            const rpcArg = parseRpcArg(this.otherargs);
            if (rpcArg) {
              this.message = `正在检测 RPC Server ${rpcArg.host}:${rpcArg.port}...`;
              const reachable = await checkTcpReachable(rpcArg.host, rpcArg.port);
              if (!reachable) {
                this.message = `RPC Server ${rpcArg.host}:${rpcArg.port} 不可达，请先在从节点启动 RPC Server`;
                return;
              }
            }
            let logDir = this.filesDir;
            let modelArg = '';
            let aliasSource = '';
            if (this.selectedBuiltin.length > 0) {
              // 用户在沙箱下拉框中明确选择的模型必须优先，不能再被目录扫描结果覆盖
              modelArg = llamaModelFile(this.filesDir + '/models/' + this.selectedBuiltin);
              aliasSource = this.selectedBuiltin;
              hilog.info(0x0000, 'StartServer', 'using selected sandbox model: %{public}s', modelArg);
            } else if (this.selectedUri) {
              try {
                // 通过 picker 授权打开模型文件获取 fd，绕过物理路径权限限制
                let file = fs.openSync(this.selectedUri, fs.OpenMode.READ_ONLY);
                if (this.modelFd >= 0) {
                  try { fs.closeSync(this.modelFd); } catch (e2) {}
                }
                this.modelFd = file.fd;
                modelArg = '/proc/self/fd/' + file.fd;
                aliasSource = uriToPath(this.selectedUri);
              } catch (e) {
                this.message = '模型文件打开失败: ' + `${e}`;
                hilog.error(0x0000, 'StartServer', 'model open error: %{public}s', `${e}`);
                return;
              }
            } else {
              // 没有显式选择时才自动扫描沙箱：
              // 分片模型优先首个分片，其次单文件/旧版 sandbox_model.gguf。
              let shardModel = '';
              let singleModel = '';
              let legacySandbox = '';
              try {
                const entries = fs.listFileSync(logDir);
                for (let i = 0; i < entries.length; i++) {
                  const name = entries[i];
                  if (!/\.gguf$/i.test(name)) {
                    continue;
                  }
                  if (/^.*-00001-of-\d{5}\.gguf$/i.test(name)) {
                    if (shardModel === '') { shardModel = logDir + '/' + name; }
                  } else if (name === 'sandbox_model.gguf') {
                    legacySandbox = logDir + '/' + name;
                  } else if (singleModel === '') {
                    singleModel = logDir + '/' + name;
                  }
                }
              } catch (e) {
              }
              const sandboxSingle = singleModel !== '' ? singleModel : legacySandbox;
              if (shardModel !== '') {
                modelArg = shardModel;
                aliasSource = shardModel;
                hilog.info(0x0000, 'StartServer', 'using auto sandbox shard model: %{public}s', shardModel);
              } else if (sandboxSingle !== '') {
                modelArg = sandboxSingle;
                aliasSource = sandboxSingle;
                hilog.info(0x0000, 'StartServer', 'using auto sandbox model: %{public}s', sandboxSingle);
              } else {
                this.message = '请先选择 GGUF 模型文件';
                return;
              }
            }
            const hcArgs = this.hotColdOn ? '-rea off -np 1 --ffn-hot-cold' : '';
            // 子设备（rank1）需要 --follower（不监听、连接 rank0）；otherargs 里已有时不重复加
            const roleArgs = (this.selectedPeerIp.length > 0 && !this.roleIsMaster &&
              this.otherargs.indexOf('--follower') < 0) ? '--follower' : '';
            let command = `./llama-server -m ${modelArg} --host 0.0.0.0 -c ${this.contextSize} --port ${this.port} ${hcArgs} ${roleArgs} ${this.otherargs}`;
            // 沙箱副本名 / /proc/self/fd/N 都不是原模型名（server 用 -m 路径取名，见 common/common.h 的 get_name），
            // 用 --alias 还原为原模型文件名（去掉 .gguf 与分片后缀）；用户在 otherargs 里已指定 --alias 则尊重
            if (aliasSource.length > 0 && !/--alias(\s|=)/.test(this.otherargs)) {
              try {
                let base = aliasSource;
                base = base.substring(base.lastIndexOf('/') + 1);
                base = base.replace(/\.gguf$/i, '').replace(/-\d{5}-of-\d{5}$/i, '');
                if (base.length > 0) {
                  command += ` --alias "${base}"`;
                }
              } catch (e) {
              }
            }

            // draft（DFlash 侧车）：优先用 picker 选中的文件 —— 桌面/文件管理等外部路径 app 无路径权限，
            // 必须经 fs.openSync 取 fd，再以 /proc/self/fd/N 传给 llama-server（同进程 fd 共享绕过 ACL）
            let draftInjected = false;
            if (this.draftUri) {
              try {
                if (this.draftFd >= 0) {
                  try { fs.closeSync(this.draftFd); } catch (e3) {}
                  this.draftFd = -1;
                }
                const draftFile = fs.openSync(this.draftUri, fs.OpenMode.READ_ONLY);
                this.draftFd = draftFile.fd;
                const draftFdArg = '/proc/self/fd/' + draftFile.fd;
                const mdPick = this.otherargs.match(/-md\s+(\S+)/);
                if (mdPick) {
                  command = command.replace(mdPick[1], draftFdArg);
                } else {
                  command = command + ' -md ' + draftFdArg;
                }
                draftInjected = true;
                hilog.info(0x0000, 'StartServer', 'draft (picker) -> %{public}s', draftFdArg);
              } catch (e) {
                this.message = 'DFlash 侧车打开失败: ' + `${e}`;
                hilog.error(0x0000, 'StartServer', 'draft picker open error: %{public}s', `${e}`);
                return;
              }
            }

            // 未选 picker 时的兜底：otherargs 含 -md <路径>，把 draft 文件也用 fs.openSync 转 fd（绕过沙箱 open 限制）
            if (!draftInjected) {
              const mdMatch = this.otherargs.match(/-md\s+(\S+)/);
              if (mdMatch) {
                try {
                  if (this.draftFd >= 0) {
                    try { fs.closeSync(this.draftFd); } catch (e3) {}
                    this.draftFd = -1;
                  }
                  let mdPath = mdMatch[1];
                  // 物理路径在 app 沙箱内不可访问，尝试转逻辑路径兜底
                  const logicalPath = mdPath.replace(/^\/data\/app\/el2\/100\/base\/[^/]+\/haps\/entry\/files\//,
                    '/data/storage/el2/base/haps/entry/files/');
                  let df: fs.File;
                  try {
                    df = fs.openSync(mdPath, fs.OpenMode.READ_ONLY);
                  } catch (eOpen) {
                    df = fs.openSync(logicalPath, fs.OpenMode.READ_ONLY);
                    mdPath = logicalPath;
                  }
                  this.draftFd = df.fd;
                  command = command.replace(mdMatch[1], '/proc/self/fd/' + df.fd);
                } catch (e) {
                  this.message = 'draft 文件打开失败: ' + `${e}`;
                  hilog.error(0x0000, 'StartServer', 'draft open error: %{public}s', `${e}`);
                  return;
                }
              }
            }

            try {
              let file = fs.openSync(rotateDebugLog(logDir), fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
              fs.writeSync(file.fd, debugLogHeader(command));
              fs.writeSync(file.fd, 'creating worker...\n');
              fs.closeSync(file);
            } catch (e) {
              hilog.error(0x0000, 'StartServer', 'log error: %{public}s', `${e}`);
            }
            try {
              this.workerInstance = new worker.ThreadWorker('entry/ets/workers/LlamaServerWorker.ets');
              this.workerInstance.onmessage = (e: Object) => {
                let data = e as Record<string, string>;
                try {
                  let file = fs.openSync(logDir + '/llama_debug.log', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.APPEND);
                  fs.writeSync(file.fd, 'worker response: ' + JSON.stringify(data) + '\n');
                  fs.closeSync(file);
                } catch (e2) {}
                if (data.status === 'error') {
                  this.message = 'Server error: ' + data.error;
                }
                // openllama 返回即 llama-server 已退出；必须复位 UI，避免继续显示假就绪。
                this.stopLoadWatch();
                this.loadDone = false;
                this.starting = false;
                this.loadStatus = data.status === 'error' ? '启动失败 ✗' : '服务已停止';
                if (data.status === 'ok') {
                  this.message = 'llama-server 已退出，可重新启动';
                }
                this.workerInstance = null;
              };
              this.workerInstance.postMessage({ command: command });
              try {
                let file = fs.openSync(logDir + '/llama_debug.log', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.APPEND);
                fs.writeSync(file.fd, 'worker created and message sent\n');
                fs.closeSync(file);
              } catch (e2) {}
            } catch (e) {
              try {
                let file = fs.openSync(logDir + '/llama_debug.log', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.APPEND);
                fs.writeSync(file.fd, 'worker create error: ' + `${e}` + '\n');
                fs.closeSync(file);
              } catch (e2) {}
            }

            this.message = `服务器在端口 ${this.port} 上启动，窗口大小为 ${this.contextSize}`;
            this.startLoadWatch();
  }
  doStopServer(): void {
            this.releaseRunningLock();
            this.stopLoadWatch();
            this.loadDone = false;
            this.loadStatus = '';
            this.message = '正在释放同进程模型...';
            try {
              llamaProbe.release();
              this.workerInstance?.terminate();
              this.workerInstance = null;
              this.message = '同进程模型已释放';
            } catch (e) {
              hilog.error(domain, TAG, 'release native model failed: %{public}s', `${e}`);
              this.message = '释放模型失败: ' + `${e}`;
            }
  }

  build() {
    Column() {
      Row() {
        Button('← 返回算力面板')
          .fontSize(14)
          .backgroundColor('#FFFFFF')
          .fontColor('#0A59F7')
          .onClick((): void => {
            router.back();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .padding({ left: 12, right: 12, top: 8 })
      // 左上：设备拓扑  |  右上：协同配置
      Row() {
        // 左列：1/3 宽（拓扑 / 会话）
        Column() {
        Column() {
          Text('设备拓扑').fontSize(22).fontWeight(FontWeight.Bold).margin({ bottom: 12 })
          Scroll() {
            Row() {
              this.lapTop(true)
              if (this.showPeerTopology()) {
                // 仅勾选协同子设备后展示链路与对端
                Column() {
                  Line()
                    .width(30).height(3)
                    .startPoint([0, 0]).endPoint([30, 0])
                    .stroke('#94A3B8').strokeWidth(3).strokeDashArray([9, 6])
                }
                .width(30)
                .alignItems(HorizontalAlign.Center)
                this.lapTop(false)
              }
            }
            .justifyContent(FlexAlign.Center)
            .margin({ top: 8 })
          }
          .scrollable(ScrollDirection.Horizontal)
          .width('100%')
          .layoutWeight(1)
        }
        .width('100%').layoutWeight(3).padding(12).margin(4).alignItems(HorizontalAlign.Center).backgroundColor(Color.White).borderRadius(8).border({ width: 1, color: '#E2E8F0' })
        Column() {
        // 对话界面（仿 llama.cpp webui）：上方消息列表、底部输入框；
        // 顶部同步显示模型加载状态，切到这个 tab 也能知道 load 完没
        if (this.loadStatus.length > 0) {
          Text(!this.loadDone && this.chatReady()
            ? 'rank0 已就绪，rank1 可直接转发对话（本机分布式仍在等待）'
            : this.loadStatus)
            .fontSize(14)
            .fontColor(this.loadDone ? Color.Green : '#E6A23C')
            .width('100%')
            .margin({ bottom: 8 })
        }
        // prefill / decode 速度：会话窗口顶部居中
        Text(this.chatStat)
          .fontSize(14)
          .fontColor('#0A59F7')
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ bottom: 6 })
        // 请求由 app 前台发出，避免切后台掉速
        List({ space: 8, scroller: this.listScroller }) {
          ForEach(this.chatMsgs, (m: ChatMessage, idx: number) => {
            ListItem() {
              Column() {
                Text(m.role === 'user' ? '我' : 'AI')
                  .fontSize(13)
                  .fontColor('#888888')
                  .alignSelf(m.role === 'user' ? ItemAlign.End : ItemAlign.Start)
                if (m.think && m.think.length > 0) {
                  Text('思考过程')
                    .fontSize(12)
                    .fontColor('#999999')
                    .alignSelf(ItemAlign.Start)
                    .margin({ top: 2 })
                  Text(m.think)
                    .fontSize(14)
                    .fontColor('#777777')
                    .padding(8)
                    .borderRadius(8)
                    .backgroundColor('#F5F5F5')
                    .alignSelf(ItemAlign.Start)
                }
                Text(m.content)
                  .fontSize(16)
                  .padding(10)
                  .borderRadius(8)
                  .backgroundColor(m.role === 'user' ? '#DCE9FF' : '#FFFFFF')
                  .border({ width: 1, color: '#E0E0E0' })
                  .alignSelf(m.role === 'user' ? ItemAlign.End : ItemAlign.Start)
              }
              .width('100%')
            }
          }, (m: ChatMessage, idx: number) => `${idx}`)
          // 正在生成的助手消息：思考与回答都随流实时追加（边生成边吐）
          if (this.chatPending) {
            ListItem() {
              Column() {
                Text('AI')
                  .fontSize(13)
                  .fontColor('#888888')
                  .alignSelf(ItemAlign.Start)
                if (this.streamThink.length > 0) {
                  Text('思考中...')
                    .fontSize(12)
                    .fontColor('#999999')
                    .alignSelf(ItemAlign.Start)
                    .margin({ top: 2 })
                  Text(this.streamThink)
                    .fontSize(14)
                    .fontColor('#777777')
                    .padding(8)
                    .borderRadius(8)
                    .backgroundColor('#F5F5F5')
                    .alignSelf(ItemAlign.Start)
                }
                Text(this.streamContent.length > 0 ? this.streamContent : '...')
                  .fontSize(16)
                  .padding(10)
                  .borderRadius(8)
                  .backgroundColor('#FFFFFF')
                  .border({ width: 1, color: '#E0E0E0' })
                  .alignSelf(ItemAlign.Start)
              }
              .width('100%')
            }
          }
        }
        .layoutWeight(1)
        .width('100%')
        .onScrollIndex((first: number, last: number) => {
          // 记录用户是否停在底部：只有在底部时才自动跟随（像网页聊天）
          const total = this.chatMsgs.length + (this.chatPending ? 1 : 0);
          this.chatAtBottom = last >= total - 1;
        });


        Row() {
          TextInput({ placeholder: '输入消息...', text: this.chatInput })
            .layoutWeight(1)
            .height(40)
            .enterKeyType(EnterKeyType.Send)
            .onChange((v: string) => {
              this.chatInput = v;
            })
            .onKeyEvent((event: KeyEvent) => {
              if (event.type === KeyType.Down &&
                  (event.keyCode === KeyCode.KEYCODE_ENTER || event.keyCode === KeyCode.KEYCODE_NUMPAD_ENTER)) {
                if (!this.chatPending && this.chatReady()) {
                  this.sendChat();
                }
                return true;
              }
              return false;
            })
            .onSubmit((enterKey: EnterKeyType) => {
              if (!this.chatPending && this.chatReady()) {
                this.sendChat();
              }
            });
          Button('发送')
            .height(40)
            .margin({ left: 8 })
            .enabled(this.chatReady() && !this.chatPending)
            .onClick(() => {
              this.sendChat();
            });
          Button('清空')
            .height(40)
            .margin({ left: 8 })
            .backgroundColor(Color.Gray)
            .onClick(() => {
              this.chatMsgs = [];
              this.chatInput = '';
              this.chatStat = '';
            });
        }
        .width('100%')
        }
        .width('100%').layoutWeight(2).padding(10).margin(4).backgroundColor(Color.White).borderRadius(8).border({ width: 1, color: '#E2E8F0' })
        }.layoutWeight(2).height('100%')
        // 右列：2/3 宽；右上占 3/5 高
        Column() {
        Column() {
        Column() {
          Text('协同配置').fontSize(24).fontWeight(FontWeight.Bold).width('100%').textAlign(TextAlign.Center).margin({ bottom: 12 })
          // 2) 自动发现的对端设备；勾选后本机作为主设备，未勾选时自动作为 follower
          Row() {
            Column() {
              Text('对端设备').fontSize(16).fontWeight(FontWeight.Medium).width('100%')
              Text(this.peerScanning
                ? this.peerScanText
                : (this.peerDevices.length > 0
                  ? `已发现 ${this.peerDevices.length} 台设备，${this.peerAvailableCount()} 台协同端口可用`
                  : this.peerScanText))
                .fontSize(14).fontColor('#666666').width('100%').margin({ top: 3 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Button(this.peerScanning ? '探测中...' : '刷新')
              .height(34)
              .fontSize(14)
              .enabled(!this.peerScanning)
              .onClick(() => {
                this.refreshPeerDevices(true, true);
              })
          }
          .width('100%')
          .margin({ bottom: 8 })
          if (this.peerDevices.length === 0) {
            Text(this.peerScanning ? '正在扫描同一网段...' : '未发现设备，请确认对端已打开本应用并接入同一网线')
              .fontSize(15)
              .fontColor('#999999')
              .width('100%')
              .padding({ top: 8, bottom: 8 })
          } else {
            Scroll() {
              Column() {
                ForEach(this.peerDevices, (peer: PeerDevice) => {
                  Row() {
                    Checkbox({ name: peer.ip, group: 'coopPeers' })
                      .select(peer.ip === this.selectedPeerIp)
                      .enabled(peer.available)
                      .onChange((checked: boolean) => {
                        if (checked) {
                          this.selectedPeerIp = peer.ip;
                        } else if (this.selectedPeerIp === peer.ip) {
                          this.selectedPeerIp = '';
                        }
                        this.preferredPeerIp = this.selectedPeerIp;
                        this.slaveIp = this.selectedPeerIp;
                        this.applyDistConfig();
                        this.saveCascadeConfig();
                      });
                    Column() {
                      Text(peer.name).fontSize(16).fontWeight(FontWeight.Medium).width('100%')
                      Text(`${peer.ip} · ${peer.available
                        ? (peer.serving ? '协同服务运行中' : '协同端口可用')
                        : '协同端口不可用'}`)
                        .fontSize(14)
                        .fontColor(peer.available ? '#666666' : '#C0392B')
                        .width('100%')
                        .margin({ top: 2 })
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                    Text(peer.ip === this.selectedPeerIp ? (this.roleIsMaster ? '对端 rank1' : '对端 rank0') : '')
                      .fontSize(14)
                      .fontColor('#0A59F7')
                  }
                  .width('100%')
                  .height(56)
                  .padding({ top: 7, bottom: 7 })
                  .border({ width: { bottom: 1 }, color: '#E2E8F0' })
                }, (peer: PeerDevice) => `${peer.ip}:${peer.available}:${peer.serving}:${peer.ready}`)
              }
              .width('100%')
            }
            .width('100%')
            .height(Math.min(150, this.peerDevices.length * 56))
            .scrollBar(BarState.Auto)
          }
          // 模式上方占 3/4、下方占 1/4 的剩余空间
          Blank()
            .layoutWeight(3)
            .constraintSize({ minHeight: 12 })
          Text(this.selectedPeerIp.length > 0
            ? `已选择 ${this.selectedPeerIp}；本机 rank${this.roleIsMaster ? 0 : 1}，启动时同步拉起对端`
            : '未选择协同设备；启动时仅运行本机')
            .fontSize(15)
            .fontColor(this.selectedPeerIp.length > 0 ? '#0A59F7' : '#666666')
            .width('100%')
            .padding({ top: 7, bottom: 9 })
          // 4) 分布式模式（下拉选择）
          Text('分布式模式').fontSize(15).fontColor('#666666').width('100%').margin({ bottom: 6 })
          Select([{ value: 'PP（流水线并行）' }, { value: '专家并行' }, { value: '神经元并行' }])
            .selected(this.distMode === 'layer' ? 0 : (this.distMode === 'expert' ? 1 : 2))
            .value(this.distModeLabel())
            .width('100%')
            .height(40)
            .font({ size: 15 })
            .selectedOptionFont({ size: 15 })
            .optionFont({ size: 15 })
            .backgroundColor('#F5F7FA')
            .borderRadius(8)
            .onSelect((index: number) => {
              this.distMode = index === 0 ? 'layer' : (index === 1 ? 'expert' : 'neuron');
              if (this.selectedPeerIp.length > 0) {
                this.applyDistConfig();
              }
              this.saveCascadeConfig();
            })
            .margin({ bottom: 14 })
          // 模式下方保留约 1/4 的弹性空间
          Blank()
            .layoutWeight(1)
            .constraintSize({ minHeight: 8 })
        }
        .width('80%').height('100%').alignSelf(ItemAlign.Center)
        }
        .width('100%').layoutWeight(3)
        .padding(12)
        .margin(4).backgroundColor(Color.White).borderRadius(8).border({ width: 1, color: '#E2E8F0' })
        Scroll() {
          Column() {
        Text('Llama.cpp 推理配置')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .margin({ bottom: 12 });

        // 导入沙箱进度：置于页面顶部，避免被底部内容淹没
        if (this.importing || this.importText.length > 0) {
          Column() {
            Text(this.importText)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.importing ? Color.Blue
                : (this.importText.includes('失败') ? Color.Red : Color.Green));
            if (this.importing) {
              Progress({ value: this.importPercent, total: 100, type: ProgressType.Linear })
                .width('100%')
                .margin({ top: 6 })
                .color(Color.Blue);
            }
          }
          .width('80%')
          .padding(10)
          .borderRadius(8)
          .backgroundColor('#F0F4FF')
          .margin({ bottom: 20 });
        }

        // 内置模型（沙箱）下拉选择，免去路径查找
        Row() {
          Select(this.modelOptions)
            .layoutWeight(1)
            .height(40)
            .value(this.selectedBuiltin.length > 0 ? this.selectedBuiltin : '选择内置模型（沙箱）')
            .onSelect((index: number) => {
              if (index >= 0 && index < this.modelList.length) {
                this.selectedBuiltin = this.modelList[index];
                this.selectedModel = this.filesDir + '/models/' + this.modelList[index];
                // 沙箱选择与外部 picker 互斥，避免两套状态互相覆盖
                this.selectedUri = '';
              }
            });
          Button('保存推理配置')
            .layoutWeight(1)
            .height(40)
            .margin({ left: 8 })
            .enabled(this.selectedBuiltin.length > 0)
            .onClick(() => {
              const error = this.saveInferenceConfig();
              this.message = error || '推理配置已保存，将在收到请求时加载模型';
              this.loadStatus = error ? '配置保存失败' : '配置已保存 · 请求时加载';
            });
        }
        .width('80%')
        .margin({ bottom: 20 })

        // 冷热分层开关：开启时自动加默认参数 -rea off -np 1 --ffn-hot-cold
        Row() {
          Toggle({ type: ToggleType.Switch, isOn: this.hotColdOn })
            .onChange((on: boolean) => {
              this.hotColdOn = on;
            })
          Text('冷热分层（-rea off -np 1 --ffn-hot-cold）').fontSize(15).margin({ left: 8 })
        }
        .width('80%')
        .margin({ bottom: 12 })

        // 专家跳过开关：开启后显示比例输入框
        Row() {
          Toggle({ type: ToggleType.Switch, isOn: this.bisectOn })
            .onChange((on: boolean) => {
              this.bisectOn = on;
            })
          Text('专家跳过 k1:k2').fontSize(15).margin({ left: 8 })
        }
        .width('80%')
        .margin({ bottom: 8 })

        if (this.bisectOn) {
          TextInput({ placeholder: '跳过比例 (如 5:20)', text: this.bisectConfig })
            .width('80%')
            .height(40)
            .margin({ bottom: 20 })
            .onChange((value: string) => {
              this.bisectConfig = value || '';
            });
        }

        TextInput({ placeholder: '提示词上下文大小 (默认: 4096)' })
          .width('80%')
          .height(40)
          .margin({ bottom: 20 })
          .onChange((value: string) => {
            this.contextSize = parseInt(value) || 4096;
          });

        TextInput({ placeholder: '端口 (默认: 8080)' })
          .width('80%')
          .height(40)
          .margin({ bottom: 20 })
          .onChange((value: string) => {
            this.port = parseInt(value) || 8080;
          });

        TextInput({ placeholder: '其他命令行参数 (默认为空)', text: this.otherargs })
          .width('80%')
          .height(40)
          .margin({ bottom: 20 })
          .onChange((value: string) => {
            this.otherargs = value || '';
          });


        Button("选择 GGUF 模型")
          .width('80%')
          .height(40)
          .margin({ bottom: 20 })
          .onClick(() => {
            const documentSelectOptions = new picker.DocumentSelectOptions();
            // 允许一次选中多个文件：分片模型（如 122B 的 -00001/-00002/-00003）必须一次全选，
            // 导入时全部按「授权 URI」复制到沙箱（app 无权限直接 open 桌面真实路径，会 ENOENT）
            documentSelectOptions.maxSelectNumber = 3;
            documentSelectOptions.fileSuffixFilters = ['.gguf'];
            documentSelectOptions.authMode = false;

            let context = getContext(this) as common.Context;
            const documentViewPicker = new picker.DocumentViewPicker(context);

            documentViewPicker.select(documentSelectOptions).then((documentSelectResult: Array<string>) => {
              this.selectedUris = documentSelectResult;
              this.selectedUri = documentSelectResult[0];
              this.selectedBuiltin = '';
              this.selectedModel = uriToPath(documentSelectResult[0]);
              if (documentSelectResult.length > 1) {
                this.selectedModel = `已选 ${documentSelectResult.length} 个分片（首个: ${uriToPath(documentSelectResult[0])}）`;
              }
              console.info('Selected model: ' + this.selectedModel);
            }).catch((err: BusinessError) => {
              console.error(`Invoke documentViewPicker.select failed, code is ${err.code}, message is ${err.message}`);
            });
          });

        if (this.loadStatus.length > 0) {
          Text(this.loadStatus)
            .fontSize(15)
            .fontColor(this.loadDone ? Color.Green : '#E6A23C')
            .margin({ bottom: 8 })
        }

        Button("导入到沙箱 (启用 O_DIRECT 加速)")
          .width('80%')
          .height(40)
          .margin({ bottom: 8 })
          .onClick(async () => {
            if (!this.selectedUri) {
              this.importText = '请先选择 GGUF 模型文件';
              return;
            }
            // 全部保留原文件名：分片模型 llama.cpp 才能按"同目录同名"推导其余分片；
            // 单文件保留原名后 -m 的 basename 即原模型名，浏览器/客户端显示的模型名才正确
            const uris: string[] = this.selectedUris.length > 0 ? this.selectedUris : [this.selectedUri];
            const isShardSet = uris.length > 1;
            this.importing = true;
            this.importPercent = 0;
            this.importText = isShardSet ? `导入分片模型（${uris.length} 个文件）...` : '导入中...';
            const firstPath = uriToPath(uris[0]);
            const firstName = firstPath.substring(firstPath.lastIndexOf('/') + 1);
            const importedModelName = firstName.replace(/-00001-of-\d{5}\.gguf$/i, '')
              .replace(/\.gguf$/i, '');
            const importedModelDir = this.filesDir + '/models/' + importedModelName;
            try { fs.mkdirSync(this.filesDir + '/models'); } catch (e) {}
            try { fs.mkdirSync(importedModelDir); } catch (e) {}
            // 旧版固定名 sandbox_model.gguf 与新的原名副本可能并存，避免双倍占用，导入前清理
            try { fs.unlinkSync(this.filesDir + '/sandbox_model.gguf'); } catch (e) {}
            try {
              const CHUNK = 8 * 1024 * 1024;
              const buf = new ArrayBuffer(CHUNK);
              // 先统计源文件总字节数，用于计算进度百分比
              let totalSize = 0;
              for (let si = 0; si < uris.length; si++) {
                try {
                  const st = await fs.stat(uris[si]);
                  totalSize += st.size;
                } catch (e) {
                }
              }
              let total = 0;
              for (let fi = 0; fi < uris.length; fi++) {
                const onePath = uriToPath(uris[fi]);
                const oneName = onePath.substring(onePath.lastIndexOf('/') + 1);
                const dstName = oneName;
                const target = importedModelDir + '/' + dstName;
                const src = await fs.open(uris[fi], fs.OpenMode.READ_ONLY);
                const dst = await fs.open(target, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
                while (true) {
                  // 顺序读/写：不传 offset，使用 fd 的当前位置
                  // （fs.write 的 offset 是文件内写入位置，传 0 会每次覆盖开头）
                  const n = await fs.read(src.fd, buf, { length: CHUNK });
                  if (n <= 0) {
                    break;
                  }
                  await fs.write(dst.fd, buf, { length: n });
                  total += n;
                  this.importPercent = totalSize > 0 ? Math.min(100, total * 100 / totalSize) : 0;
                  if (total % 1073741824 < CHUNK) {
                    this.importText = `导入中... ${(total / 1073741824).toFixed(1)} GiB (${fi + 1}/${uris.length})`;
                  }
                }
                fs.closeSync(src);
                fs.closeSync(dst);
              }
              const manifest = fs.openSync(importedModelDir + '/llama.json',
                fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
              fs.writeSync(manifest.fd, JSON.stringify({
                model: firstName, context: this.contextSize, tier: 2, capabilities: ['text']
              }));
              fs.closeSync(manifest);
              this.selectedBuiltin = importedModelName;
              this.selectedModel = importedModelDir;
              this.importPercent = 100;
              this.importing = false;
              this.importText = `导入完成: ${(total / 1073741824).toFixed(2)} GiB（模型在 /data 上，池可用 O_DIRECT）`;
              this.refreshModelList();
            } catch (e) {
              this.importing = false;
              this.importText = '导入失败: ' + `${e}`;
              hilog.error(0x0000, 'Import', 'error: %{public}s', `${e}`);
            }
          });

        Button("清除沙箱模型")
          .width('80%')
          .height(40)
          .margin({ bottom: 20 })
          .onClick(() => {
            try {
              let removed = 0;
              // 沙箱副本保留原文件名（含旧版 sandbox_model.gguf 与分片），统一按 .gguf 清理
              try {
                const entries = fs.listFileSync(this.filesDir);
                for (let i = 0; i < entries.length; i++) {
                  if (/\.gguf$/i.test(entries[i])) {
                    try {
                      fs.unlinkSync(this.filesDir + '/' + entries[i]);
                      removed++;
                    } catch (e) {
                    }
                  }
                }
              } catch (e) {
              }
              this.importText = `已清除沙箱模型（${removed} 个文件）`;
            } catch (e) {
              this.importText = '清除失败: ' + `${e}`;
            }
          });


        // （内置测试已迁移到「对话界面」标签页）

        Text(this.message)
          .fontSize(16)
          .margin({ top: 20 });

        Text('请使用Chatbox、OpenWebUI等工具连接下面的地址:')
          .fontSize(16)
          .margin({ top: 20 });

        Text(this.roleIsMaster
          ? `http://你的设备IP（本机为127.0.0.1）:${this.port}`
          : `rank1 对话转发到 rank0：http://${this.chatRequestHost()}:${this.port}`)
          .fontSize(16)
          .fontColor(Color.Blue)
          .margin({ top: 10 });
        Text(`去ModelScope下载通义千问模型`)
          .fontSize(16)
          .fontColor(Color.Blue)
          .margin({ top: 10 }).onClick(() => {
            this.toWebBrowser('https://www.modelscope.cn/models/Qwen/Qwen2.5-1.5B-Instruct-GGUF/files');
          });
        Text(`Llama.cpp 命令行参数一览`)
          .fontSize(16)
          .fontColor(Color.Blue)
          .margin({ top: 10 }).onClick(() => {
          this.toWebBrowser('https://github.com/ggerganov/llama.cpp/blob/master/examples/server/README.md');
        });
          }
          .width('100%').padding(12)
        }
        .scrollBar(BarState.On)
        .width('100%').layoutWeight(2).margin(4).backgroundColor(Color.White).borderRadius(8).border({ width: 1, color: '#E2E8F0' })
        }.layoutWeight(1).height('100%')
      }.width('100%').height('100%')
    }
    .width('100%').height('100%').backgroundColor('#EEF2F7')
  }
}
