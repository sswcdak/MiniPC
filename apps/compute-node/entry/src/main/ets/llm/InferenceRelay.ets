import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatMessage, ClusterInfo, WireMessage, InferenceMetrics } from '../protocol/ChatProtocol';
import { ComputeRouter, DispatchEntry, originKeyOf } from '../cluster/ComputeRouter';
import { PoolNode, clusterLoad, meetsCapabilities, pickAvailableFor } from '../cluster/DevicePool';
import { stableSystem, taskHead } from './SessionReuse';
import { classifyFromMessages } from '../cluster/TaskRules';

/** Time the hub keeps for relaying; the worker gets the requester's budget minus this. */
const RELAY_MARGIN_MS = 5000;
const MIN_FORWARD_BUDGET_MS = 10000;
const QUEUE_WAIT_MS = 120000;
const QUEUE_HEARTBEAT_MS = 5000;
const QUEUE_MAX = 128;
const ADMISSION_MAX = 256;
const FINISHED_MAX = 1024;
const FINISHED_TTL_MS = 600000;

class HubAdmission {
  request: WireMessage;
  epoch: number;
  receivedAt: number;
  deadlineAt: number;
  phase: string = 'new';
  workerEpoch: number = 0;
  device: string = '';
  accepted: boolean = false;
  cancelled: boolean = false;
  cancelDeadlineAt: number = 0;
  queuedAt: number = 0;
  waitedMs: number = 0;
  queueExpiresAt: number = 0;
  tried: number[] = [];
  attempts: number = 0;
  constructor(request: WireMessage, epoch: number, now: number) {
    this.request = request; this.epoch = epoch; this.receivedAt = now;
    this.deadlineAt = now + Math.min(300000, typeof request.deadlineBudgetMs === 'number' ? request.deadlineBudgetMs : 300000);
  }
}

/** The hub's own inference host, as seen by the relay. */
export interface RelayLocal {
  handle(message: WireMessage, epoch: number): void;
  hasRequest?(requestId: string, epoch: number): boolean;
}

/** Task-card observers for requests that run on another device. */
export class RelayEvents {
  waiting: (request: WireMessage, chatEpoch: number, waiting: boolean, dispatching?: boolean) => void =
    (_request: WireMessage, _chatEpoch: number, _waiting: boolean, _dispatching?: boolean): void => {};
  phase: (requestId: string, chatEpoch: number, phase: string) => void =
    (_requestId: string, _chatEpoch: number, _phase: string): void => {};
  metrics: (requestId: string, chatEpoch: number, metrics: InferenceMetrics) => void =
    (_requestId: string, _chatEpoch: number, _metrics: InferenceMetrics): void => {};
  begin: (requestId: string, chatEpoch: number, workerEpoch: number, messages: ChatMessage[], label: string,
    image: string) => void =
    (_requestId: string, _chatEpoch: number, _workerEpoch: number, _messages: ChatMessage[], _label: string,
      _image: string): void => {};
  delta: (requestId: string, chatEpoch: number, answer: string) => void =
    (_requestId: string, _chatEpoch: number, _answer: string): void => {};
  end: (requestId: string, chatEpoch: number, answer: string, failed: boolean) => void =
    (_requestId: string, _chatEpoch: number, _answer: string, _failed: boolean): void => {};
  forward: (requestId: string, chatEpoch: number, workerEpoch: number, request: WireMessage) => void =
    (_requestId: string, _chatEpoch: number, _workerEpoch: number, _request: WireMessage): void => {};
}

/**
 * Compute-hub router for agent `infer.*` traffic.
 *
 * One chat request goes to exactly one ready device: the hub itself (handled by
 * its own host) or another compute device (forwarded under a hub-generated
 * forwardId). Replies are matched on forwardId, the worker is identified by its
 * link epoch, and the payload is passed through unchanged except for requestId,
 * so the requester's seq/length/sha256 checks keep covering the real output.
 *
 * Resource waiting belongs to this hub. BUSY before native acceptance is retained here;
 * failures after execution began follow the existing bounded, no-output reissue policy.
 */
interface AffinityEntry { epoch: number; at: number; }
const AFFINITY_TTL_MS = 180000;
const AFFINITY_MAX = 16;
/** A request whose device was lost or failed before any output reached the requester is re-issued this many times. */
const MAX_REISSUE = 2;
/** Worker errors that mean "this device did not complete it", not "the request is bad". */
const REISSUE_CODES: string[] = ['CANCELLED', 'WORKER_LOST', 'MODEL_EXECUTION_FAILED'];

/** Same system part and task section (see SessionReuse) means the same run. */
function runFingerprint(message: WireMessage): string {
  const messages = message.messages;
  if (messages === undefined || messages.length !== 2) return '';
  const system = stableSystem(messages[0].content);
  const head = taskHead(messages[1].content);
  if (system.length === 0 || head.length === 0) return '';
  let hash = 0;
  const text = system + '\u0001' + head;
  for (let i = 0; i < text.length; i++) {
    hash = (hash * 31 + text.charCodeAt(i)) % 2147483647;
  }
  return hash.toString() + ':' + text.length.toString();
}

export class InferenceRelay {
  private router: ComputeRouter;
  private nodes: () => PoolNode[];
  private chats: () => number[];
  private local: RelayLocal;
  private sender: (message: WireMessage, epoch: number) => Promise<boolean>;
  private events: RelayEvents;
  private admissions: Map<string, HubAdmission> = new Map();
  private finished: Map<string, number> = new Map();
  private blockedUntil: Map<number, number> = new Map();
  private queueTimer: number = -1;
  private draining: boolean = false;
  private closed: boolean = false;
  private now: () => number;
  private lastPublished: string = '';
  private speedCost: (epoch: number) => number = (_epoch: number): number => -1;
  private affinityOn: () => boolean = (): boolean => false;
  /** Run fingerprint -> the worker that served its last round. */
  private affinity: Map<string, AffinityEntry> = new Map();

  constructor(router: ComputeRouter, nodes: () => PoolNode[], chats: () => number[], local: RelayLocal,
    sender: (message: WireMessage, epoch: number) => Promise<boolean>, events: RelayEvents,
    now: () => number = (): number => Date.now()) {
    this.router = router;
    this.nodes = nodes;
    this.chats = chats;
    this.local = local;
    this.sender = sender;
    this.events = events;
    this.now = now;
  }

  private safeSend(message: WireMessage, epoch: number): Promise<boolean> {
    try { return Promise.resolve(this.sender(message, epoch)).catch((): boolean => false); }
    catch (_) { return Promise.resolve(false); }
  }

  /** Soft affinity: send the next round of a run to the device that holds its session, if idle. */
  setAffinity(enabled: () => boolean): void {
    this.affinityOn = enabled;
  }

  /** Measured cost per device (lower = faster, -1 = unknown); faster idle devices are preferred. */
  setSpeed(cost: (epoch: number) => number): void {
    this.speedCost = cost;
  }

  load(): ClusterInfo {
    // This profile feeds the chat client's text-Agent splitter, not a device inventory.
    const load = clusterLoad(this.nodes().filter((node: PoolNode): boolean => meetsCapabilities(node, ['text'])));
    return { idle: load.idle, total: load.total };
  }

  /** Message from a chat phone: infer.request, infer.cancel, infer.capabilities.get. */
  handleFromChat(message: WireMessage, chatEpoch: number): void {
    if (message.type === 'infer.request') {
      this.route(message, chatEpoch);
      return;
    }
    if (message.type === 'infer.cancel') {
      this.cancel(message, chatEpoch);
      return;
    }
    this.local.handle(message, chatEpoch);
  }

  /** Reply from a compute device that was handed a forwarded request. */
  handleFromWorker(message: WireMessage, workerEpoch: number): void {
    const forwardId = message.requestId || '';
    const entry = this.router.getByForwardId(forwardId);
    if (entry === undefined || !entry.infer || entry.workerEpoch !== workerEpoch) {
      return;
    }
    const origin = entry.originRequestId;
    const admission = this.admissions.get(originKeyOf(entry.originEpoch, origin));
    if (message.metrics !== undefined) {
      try { this.events.metrics(origin, entry.originEpoch, message.metrics); } catch (_) { /* display only */ }
    }
    if (message.type === 'infer.accepted') {
      entry.accepted = true;
      if (admission !== undefined) admission.accepted = true;
      this.events.phase(origin, entry.originEpoch, message.state === 'queued' ? 'queued' : 'running');
      this.toChat({ type: 'infer.accepted', version: 2, requestId: origin, state: message.state,
        device: entry.workerName }, entry);
      return;
    }
    if (message.type === 'infer.status') {
      if (['queued', 'preparing', 'loading', 'prefill', 'generating'].includes(message.state || '')) {
        this.events.phase(origin, entry.originEpoch, message.state === 'queued' ? 'queued' : 'running');
      }
      this.toChat({ type: 'infer.status', version: 2, requestId: origin, state: message.state }, entry);
      return;
    }
    if (message.type === 'infer.delta') {
      const text = message.text || '';
      entry.answer += text;
      this.toChat({ type: 'infer.delta', version: 2, requestId: origin, seq: message.seq, text: text,
        metrics: message.metrics }, entry);
      this.events.delta(origin, entry.originEpoch, entry.answer);
      return;
    }
    if (message.type === 'infer.done') {
      this.router.finishForward(forwardId);
      if (admission !== undefined) this.finishAdmission(admission);
      this.sendToChat({ type: 'infer.done', version: 2, requestId: origin, lastSeq: message.lastSeq,
        outputUtf8Bytes: message.outputUtf8Bytes, outputSha256: message.outputSha256,
        finishReason: message.finishReason, source: message.source, metrics: message.metrics }, entry.originEpoch, null);
      this.events.end(origin, entry.originEpoch, entry.answer, false);
      this.publishLoad();
      return;
    }
    if (message.type === 'infer.error') {
      this.router.finishForward(forwardId);
      if (admission !== undefined && !entry.accepted && !admission.cancelled && message.retryable === true &&
        ['BUSY', 'MODEL_UNAVAILABLE'].includes(message.code || '')) {
        this.enqueue(admission, workerEpoch); this.publishLoad(); return;
      }
      if (REISSUE_CODES.includes(message.code || '') && this.reissue(entry, 'error ' + (message.code || ''))) return;
      if (admission !== undefined) this.finishAdmission(admission);
      this.sendToChat({ type: 'infer.error', version: 2, requestId: origin, code: message.code,
        message: message.message, retryable: message.retryable }, entry.originEpoch, null);
      this.events.end(origin, entry.originEpoch, entry.answer, true);
      this.publishLoad();
    }
  }

  /** The chat phone is gone: nothing can be delivered, so stop the remote work. */
  chatDropped(chatEpoch: number): void {
    for (const entry of Array.from(this.admissions.values())) if (entry.epoch === chatEpoch) {
      entry.cancelled = true;
      if (entry.phase === 'running' && entry.workerEpoch === 0) this.local.handle({ type: 'infer.cancel', version: 2, requestId: entry.request.requestId }, chatEpoch);
      this.finishAdmission(entry);
    }
    for (const entry of this.router.dispatchesFromOrigin(chatEpoch)) {
      if (!entry.infer) continue;
      entry.cancelRequested = true;
      this.router.finishForward(entry.forwardId);
      this.safeSend({ type: 'infer.cancel', version: 2, requestId: entry.forwardId }, entry.workerEpoch)
        .catch((_error: Error): void => {});
      this.events.end(entry.originRequestId, entry.originEpoch, entry.answer, true);
    }
    this.publishLoad();
  }

  /** A compute device disappeared: fail what ran on it, retryable only if never accepted. */
  workerDropped(workerEpoch: number): void {
    for (const entry of this.router.dispatchesFor(workerEpoch)) {
      if (!entry.infer) continue;
      this.router.finishForward(entry.forwardId);
      if (this.reissue(entry, 'worker lost')) continue;
      const admission = this.admissions.get(originKeyOf(entry.originEpoch, entry.originRequestId));
      if (admission !== undefined) this.finishAdmission(admission);
      this.sendToChat({ type: 'infer.error', version: 2, requestId: entry.originRequestId, code: 'WORKER_LOST',
        message: '执行设备 ' + entry.workerName + ' 已断开', retryable: !entry.accepted }, entry.originEpoch, null);
      this.events.end(entry.originRequestId, entry.originEpoch, entry.answer, true);
    }
    this.publishLoad();
  }

  /** Pushes infer.status to every chat phone, only when the numbers changed. */
  publishLoad(): void {
    if (this.closed) return;
    this.drainQueue();
    const load = this.load();
    const key = String(load.idle) + '/' + String(load.total);
    if (key === this.lastPublished) return;
    this.lastPublished = key;
    for (const epoch of this.chats()) {
      this.safeSend({ type: 'infer.status', version: 2, requestId: 'cluster', cluster: load }, epoch)
        .catch((_error: Error): void => {});
    }
  }

  private route(message: WireMessage, chatEpoch: number): void {
    this.pruneFinished();
    const id = message.requestId || '', key = originKeyOf(chatEpoch, id);
    if (this.closed) { this.refuse(id, chatEpoch, 'MODEL_UNAVAILABLE', '路由中心已停止', false); return; }
    const existing = this.admissions.get(key);
    if (existing !== undefined) {
      // Retransmission is idempotent, including while the request waits at the hub.
      if (existing.phase === 'queued') this.queueStatus(existing, true);
      else this.safeSend({ type: 'infer.accepted', version: 2, requestId: id,
        state: existing.accepted ? 'running' : 'queued', device: existing.device }, chatEpoch).catch((): void => {});
      return;
    }
    if (this.finished.has(key) || this.router.getDispatch(id, chatEpoch) !== undefined || this.local.hasRequest?.(id, chatEpoch) === true) {
      this.refuse(id, chatEpoch, 'DUPLICATE_REQUEST', '请求编号已处理，请使用新的编号', false);
      return;
    }
    if (message.deadlineBudgetMs !== undefined && (!Number.isInteger(message.deadlineBudgetMs) ||
      message.deadlineBudgetMs <= MIN_FORWARD_BUDGET_MS + RELAY_MARGIN_MS)) {
      this.refuse(id, chatEpoch, 'DEADLINE_EXCEEDED', '请求剩余时限不足以执行', false); return;
    }
    if (this.admissions.size >= ADMISSION_MAX) {
      this.refuse(id, chatEpoch, 'QUEUE_FULL', '路由中心请求已满，请稍后重新提交', false);
      return;
    }
    // Give older eligible requests first access; an unavailable image never blocks later text.
    this.drainQueue();
    const entry = new HubAdmission(message, chatEpoch, this.now());
    this.admissions.set(key, entry);
    const target = this.pickTarget(message, []);
    if (target !== null) this.dispatch(message, chatEpoch, target, [], 0);
    else this.enqueue(entry);
  }

  private pickTarget(message: WireMessage, tried: number[]): PoolNode | null {
    const needs: string[] = message.image ? ['vision'] : ['text'];
    const messages: ChatMessage[] = message.messages || [{ role: 'user', content: message.prompt || '' }];
    const profile = classifyFromMessages(messages, !!message.image);
    const fingerprint = this.affinityOn() ? runFingerprint(message) : '';
    const preferred = fingerprint ? this.affinity.get(fingerprint) : undefined;
    const target = pickAvailableFor(this.nodes().filter((node: PoolNode): boolean =>
      !tried.includes(node.epoch) && (this.blockedUntil.get(node.epoch) || 0) <= this.now()), needs, profile.tier,
      preferred !== undefined && this.now() - preferred.at < AFFINITY_TTL_MS ? preferred.epoch : -1, this.speedCost);
    if (target !== null && fingerprint) this.remember(fingerprint, target.epoch);
    return target;
  }

  private enqueue(entry: HubAdmission, blockedWorker?: number): void {
    if (this.admissions.get(originKeyOf(entry.epoch, entry.request.requestId || '')) !== entry) return;
    if (blockedWorker !== undefined) this.blockedUntil.set(blockedWorker, this.now() + 2000);
    if (entry.phase !== 'queued') {
      if (Array.from(this.admissions.values()).filter((item: HubAdmission): boolean => item.phase === 'queued').length >= QUEUE_MAX) {
        this.finishAdmission(entry);
        this.refuse(entry.request.requestId || '', entry.epoch, 'QUEUE_FULL', '路由中心等待队列已满，请稍后重新提交', false);
        return;
      }
      entry.phase = 'queued'; entry.device = ''; entry.accepted = false; entry.queuedAt = this.now();
      entry.queueExpiresAt = Math.min(this.now() + Math.max(0, QUEUE_WAIT_MS - entry.waitedMs),
        entry.deadlineAt - MIN_FORWARD_BUDGET_MS - RELAY_MARGIN_MS);
      this.events.waiting(entry.request, entry.epoch, true);
    }
    if (entry.queueExpiresAt <= this.now()) { this.expireQueued(entry); return; }
    this.queueStatus(entry, true);
    this.scheduleQueue();
  }

  private queueStatus(entry: HubAdmission, accepted: boolean = false): void {
    const key = originKeyOf(entry.epoch, entry.request.requestId || '');
    const failed = (): void => {
      if (this.admissions.get(key) !== entry) return;
      this.finishAdmission(entry);
      const dispatch = this.router.getDispatch(entry.request.requestId || '', entry.epoch);
      if (dispatch !== undefined) {
        this.router.finishForward(dispatch.forwardId);
        this.safeSend({ type: 'infer.cancel', version: 2, requestId: dispatch.forwardId }, dispatch.workerEpoch).catch((): void => {});
        this.events.end(dispatch.originRequestId, dispatch.originEpoch, dispatch.answer, true);
      } else if (entry.phase === 'running') this.local.handle({ type: 'infer.cancel', version: 2, requestId: entry.request.requestId }, entry.epoch);
    };
    try {
      this.safeSend({ type: accepted ? 'infer.accepted' : 'infer.status', version: 2,
        requestId: entry.request.requestId, state: 'queued', source: 'hub-queue', device: '' }, entry.epoch)
        .then((sent: boolean): void => { if (!sent) failed(); }).catch(failed);
    } catch (_) { failed(); }
  }

  /** Resource events drive admission; the timer only maintains deadlines, heartbeats and stale BUSY backoff. */
  resourcesChanged(epoch?: number): void {
    if (epoch !== undefined) this.blockedUntil.delete(epoch);
    this.publishLoad();
  }

  private drainQueue(): void {
    if (this.draining || this.closed) return;
    this.draining = true;
    try {
      for (const entry of Array.from(this.admissions.values())) {
        if (entry.phase !== 'queued') continue;
        if (entry.queueExpiresAt <= this.now()) { this.expireQueued(entry); continue; }
        const target = this.pickTarget(entry.request, entry.tried);
        if (target !== null) this.dispatch(entry.request, entry.epoch, target, entry.tried, entry.attempts);
      }
    } finally { this.draining = false; this.scheduleQueue(); }
  }

  private scheduleQueue(): void {
    clearTimeout(this.queueTimer); this.queueTimer = -1;
    if (this.closed || !this.admissions.size) return;
    let delay = QUEUE_HEARTBEAT_MS;
    for (const entry of this.admissions.values()) {
      const expiry = entry.phase === 'queued' ? entry.queueExpiresAt :
        entry.cancelDeadlineAt > 0 ? Math.min(entry.deadlineAt, entry.cancelDeadlineAt) : entry.deadlineAt;
      delay = Math.min(delay, Math.max(1, expiry - this.now()));
    }
    this.queueTimer = setTimeout((): void => {
      this.queueTimer = -1;
      for (const entry of Array.from(this.admissions.values())) {
        if (entry.phase !== 'running' || (entry.deadlineAt > this.now() &&
          (entry.cancelDeadlineAt === 0 || entry.cancelDeadlineAt > this.now()))) continue;
        this.finishAdmission(entry);
        const dispatch = this.router.getDispatch(entry.request.requestId || '', entry.epoch);
        if (dispatch !== undefined) {
          dispatch.cancelRequested = true; this.router.finishForward(dispatch.forwardId);
          this.safeSend({ type: 'infer.cancel', version: 2, requestId: dispatch.forwardId }, dispatch.workerEpoch).catch((): void => {});
          this.events.end(entry.request.requestId || '', entry.epoch, '', true);
        } else this.local.handle({ type: 'infer.cancel', version: 2, requestId: entry.request.requestId }, entry.epoch);
        this.refuse(entry.request.requestId || '', entry.epoch, entry.cancelled ? 'CANCELLED' : 'DEADLINE_EXCEEDED',
          entry.cancelled ? '已取消' : '推理请求已超过总时限', false);
      }
      this.drainQueue();
      for (const entry of this.admissions.values()) if (entry.phase === 'queued') this.queueStatus(entry);
    }, delay);
  }

  private expireQueued(entry: HubAdmission): void {
    this.finishAdmission(entry);
    this.refuse(entry.request.requestId || '', entry.epoch, 'QUEUE_TIMEOUT', '路由中心等待资源超时，请重新提交', false);
  }

  private finishAdmission(entry: HubAdmission): void {
    this.admissions.delete(originKeyOf(entry.epoch, entry.request.requestId || ''));
    if (entry.phase === 'queued') this.events.waiting(entry.request, entry.epoch, false);
    this.finished.set(originKeyOf(entry.epoch, entry.request.requestId || ''), this.now());
    this.pruneFinished(); this.scheduleQueue();
  }

  private pruneFinished(): void {
    for (const item of this.finished) if (this.now() - item[1] >= FINISHED_TTL_MS) this.finished.delete(item[0]);
    for (const item of this.blockedUntil) if (item[1] <= this.now()) this.blockedUntil.delete(item[0]);
    while (this.finished.size > FINISHED_MAX) this.finished.delete(Array.from(this.finished.keys())[0]);
  }

  /** Local host replies use the same admission ledger as forwarded worker replies. */
  sendLocal(message: WireMessage, epoch: number): Promise<boolean> {
    const entry = this.admissions.get(originKeyOf(epoch, message.requestId || ''));
    if (entry !== undefined && entry.phase === 'running' && entry.workerEpoch === 0) {
      if (message.type === 'infer.error' && !entry.accepted && message.retryable === true &&
        ['BUSY', 'MODEL_UNAVAILABLE'].includes(message.code || '')) {
        this.enqueue(entry, 0); return Promise.resolve(true);
      }
      if (message.type === 'infer.accepted') entry.accepted = true;
      if (message.type === 'infer.done' || message.type === 'infer.error') {
        this.finishAdmission(entry);
        // Host card teardown releases self load after invoking its sender.
        Promise.resolve().then((): void => this.publishLoad());
      }
    }
    return this.safeSend(message, epoch);
  }

  pendingCount(): number { return Array.from(this.admissions.values()).filter((item: HubAdmission): boolean => item.phase === 'queued').length; }

  close(): void {
    this.closed = true;
    for (const epoch of Array.from(new Set(Array.from(this.admissions.values()).map((entry: HubAdmission): number => entry.epoch)))) this.chatDropped(epoch);
    clearTimeout(this.queueTimer); this.queueTimer = -1; this.finished.clear(); this.blockedUntil.clear();
  }

  /** Hands the request to the chosen device: this hub itself, or a worker under a new forwardId. */
  private dispatch(message: WireMessage, chatEpoch: number, target: PoolNode, tried: number[], attempts: number): void {
    const id = message.requestId || '';
    const admission = this.admissions.get(originKeyOf(chatEpoch, id));
    if (admission !== undefined) {
      if (admission.deadlineAt - this.now() <= MIN_FORWARD_BUDGET_MS + (target.isSelf ? 0 : RELAY_MARGIN_MS)) {
        this.finishAdmission(admission);
        this.refuse(id, chatEpoch, 'DEADLINE_EXCEEDED', '请求剩余时限不足以执行', false); return;
      }
      if (admission.phase === 'queued') {
        admission.waitedMs += Math.max(0, this.now() - admission.queuedAt);
        admission.phase = 'running';
        this.events.waiting(message, chatEpoch, false, true);
      }
      admission.phase = 'running'; admission.workerEpoch = target.epoch; admission.device = target.label; admission.accepted = false;
      admission.tried = tried; admission.attempts = attempts;
    }
    const messages: ChatMessage[] = message.messages !== undefined ? message.messages :
      [{ role: 'user', content: message.prompt || '' }];
    const profile = classifyFromMessages(messages, !!message.image);
    hilog.info(0, 'NearbyChat', 'infer route request=%{public}s chat=%{public}d device=%{public}s worker=%{public}d load=%{public}d',
      id, chatEpoch, target.label, target.epoch, target.inflight);
    if (target.isSelf) {
      hilog.info(0, 'NearbyChat', 'infer local request=%{public}s tier=%{public}d nodeTier=%{public}d',
        id, profile.tier, target.modelTier);
      this.local.handle(this.forwardCopy(message, id, admission, 0), chatEpoch);
      this.publishLoad();
      return;
    }
    const entry = new DispatchEntry();
    entry.originEpoch = chatEpoch;
    entry.originRequestId = id;
    entry.workerEpoch = target.epoch;
    entry.workerName = target.label;
    entry.infer = true;
    entry.request = message;
    entry.tried = tried.concat([target.epoch]);
    entry.attempts = attempts;
    // Count before sending so the next request sees the updated load.
    const dispatch = this.router.beginDispatch(id, entry);
    const forwarded = this.forwardCopy(message, dispatch.forwardId, admission);
    this.events.begin(id, chatEpoch, target.epoch, messages, message.label !== undefined ? message.label : '',
      message.image !== undefined ? message.image : '');
    this.events.forward(id, chatEpoch, target.epoch, forwarded);
    hilog.info(0, 'NearbyChat', 'infer relay request=%{public}s forward=%{public}s worker=%{public}d',
      id, dispatch.forwardId, target.epoch);
    this.safeSend(forwarded, target.epoch).then((sent: boolean): void => {
      if (!sent) this.forwardFailed(dispatch);
    }).catch((_error: Error): void => this.forwardFailed(dispatch));
    // This is hub admission, not worker execution. It stops the chat's upload-only
    // timeout while the second hop is still in flight. Never mark entry.accepted here:
    // worker-loss/reissue safety continues to depend on the worker's own reply.
    this.toChat({ type: 'infer.accepted', version: 2, requestId: id, state: 'queued',
      device: target.label }, dispatch);
    this.publishLoad();
  }

  /**
   * The device lost or failed this request before any output reached the requester. Inference has no
   * side effects, so it is safe to run again on another ready device that has not been tried.
   * Returns false (and does nothing) when that is not possible; the caller then reports the failure.
   */
  private reissue(entry: DispatchEntry, why: string): boolean {
    const request = entry.request as WireMessage | undefined;
    if (request === undefined || entry.cancelRequested || entry.answer.length > 0 || entry.attempts >= MAX_REISSUE) {
      return false;
    }
    const target = this.pickTarget(request, entry.tried);
    const admission = this.admissions.get(originKeyOf(entry.originEpoch, entry.originRequestId));
    if (target === null && admission === undefined) return false;
    hilog.warn(0, 'NearbyChat', 'infer relay reissue request=%{public}s after %{public}s from=%{public}s to=%{public}s attempt=%{public}d',
      entry.originRequestId, why, entry.workerName, target?.label || 'hub-queue', entry.attempts + 1);
    // The lost attempt's card closes as failed; the new attempt opens its own.
    this.events.end(entry.originRequestId, entry.originEpoch, '', true);
    // Explain an actual scheduler retry to the requester; an ordinary hub→worker handoff never emits this.
    const reason = why === 'worker lost' ? '执行设备连接中断' :
      why.includes('MODEL_EXECUTION_FAILED') ? '模型执行失败' : '执行被取消';
    this.toChat({ type: 'infer.status', version: 2, requestId: entry.originRequestId,
      state: 'rerouting', source: entry.workerName, device: target?.label || '', text: reason }, entry);
    if (target === null && admission !== undefined) {
      admission.tried = entry.tried; admission.attempts = entry.attempts + 1;
      this.enqueue(admission); this.publishLoad(); return true;
    }
    if (target === null) return false;
    this.dispatch(request, entry.originEpoch, target, entry.tried, entry.attempts + 1);
    return true;
  }

  private remember(fingerprint: string, epoch: number): void {
    this.affinity.delete(fingerprint);
    this.affinity.set(fingerprint, { epoch: epoch, at: Date.now() });
    while (this.affinity.size > AFFINITY_MAX) {
      const oldest = this.affinity.keys().next();
      if (oldest.done === true) break;
      this.affinity.delete(oldest.value as string);
    }
  }

  /** The send to the worker failed: the request never started there, so it is retryable. */
  private forwardFailed(dispatch: DispatchEntry): void {
    if (this.router.finishForward(dispatch.forwardId) === undefined) return;
    const admission = this.admissions.get(originKeyOf(dispatch.originEpoch, dispatch.originRequestId));
    if (admission !== undefined && !dispatch.accepted && !admission.cancelled) {
      this.toChat({ type: 'infer.status', version: 2, requestId: dispatch.originRequestId, state: 'rerouting',
        source: dispatch.workerName, text: '无法联系执行设备' }, dispatch);
      this.enqueue(admission, dispatch.workerEpoch); this.publishLoad(); return;
    }
    if (admission !== undefined) this.finishAdmission(admission);
    this.sendToChat({ type: 'infer.error', version: 2, requestId: dispatch.originRequestId, code: 'WORKER_LOST',
      message: '无法联系执行设备 ' + dispatch.workerName, retryable: !dispatch.accepted }, dispatch.originEpoch, null);
    this.events.end(dispatch.originRequestId, dispatch.originEpoch, dispatch.answer, true);
    this.publishLoad();
  }

  private cancel(message: WireMessage, chatEpoch: number): void {
    const id = message.requestId || '', key = originKeyOf(chatEpoch, id), admission = this.admissions.get(key);
    if (admission === undefined || admission.phase === 'queued') {
      if (admission !== undefined) this.finishAdmission(admission);
      else { this.finished.set(key, this.now()); this.pruneFinished(); }
      this.refuse(id, chatEpoch, 'CANCELLED', '已取消', false); return;
    }
    admission.cancelled = true; admission.cancelDeadlineAt = this.now() + 8000; this.scheduleQueue();
    const entry = this.router.getDispatch(message.requestId || '', chatEpoch);
    if (entry === undefined || !entry.infer) {
      this.local.handle(message, chatEpoch);
      return;
    }
    entry.cancelRequested = true;
    // The worker answers with infer.error CANCELLED, which flows back through handleFromWorker.
    this.safeSend({ type: 'infer.cancel', version: 2, requestId: entry.forwardId }, entry.workerEpoch)
      .then((sent: boolean): void => {
        if (!sent) this.forwardFailed(entry);
      }).catch((_error: Error): void => this.forwardFailed(entry));
  }

  private refuse(requestId: string, chatEpoch: number, code: string, text: string, retryable: boolean): void {
    this.safeSend({ type: 'infer.error', version: 2, requestId: requestId, code: code, message: text,
      retryable: retryable }, chatEpoch).catch((_error: Error): void => {});
  }

  private toChat(message: WireMessage, entry: DispatchEntry): void {
    this.sendToChat(message, entry.originEpoch, entry);
  }

  /** A lost reply makes the stream undeliverable, so stop the worker instead of letting it run on. */
  private sendToChat(message: WireMessage, chatEpoch: number, live: DispatchEntry | null): void {
    const failed = (): void => {
      if (live === null) return;
      if (this.router.finishForward(live.forwardId) === undefined) return;
      this.safeSend({ type: 'infer.cancel', version: 2, requestId: live.forwardId }, live.workerEpoch)
        .catch((_error: Error): void => {});
      const admission = this.admissions.get(originKeyOf(live.originEpoch, live.originRequestId));
      if (admission !== undefined) this.finishAdmission(admission);
      this.events.end(live.originRequestId, live.originEpoch, live.answer, true);
      this.publishLoad();
    };
    let pending: Promise<boolean>;
    try {
      pending = this.safeSend(message, chatEpoch);
    } catch (_error) {
      failed();
      return;
    }
    pending.then((sent: boolean): void => {
      if (!sent) failed();
    }).catch((_error: Error): void => failed());
  }

  private forwardCopy(message: WireMessage, forwardId: string, admission?: HubAdmission, margin: number = RELAY_MARGIN_MS): WireMessage {
    const copy: WireMessage = { type: 'infer.request', version: 2, requestId: forwardId };
    if (message.clientInstanceId !== undefined) copy.clientInstanceId = message.clientInstanceId;
    if (message.agentRunId !== undefined) copy.agentRunId = message.agentRunId;
    if (message.modelId !== undefined) copy.modelId = message.modelId;
    if (message.modelRevision !== undefined) copy.modelRevision = message.modelRevision;
    if (message.promptFormat !== undefined) copy.promptFormat = message.promptFormat;
    if (message.prompt !== undefined) copy.prompt = message.prompt;
    if (message.messages !== undefined) copy.messages = message.messages;
    if (message.image !== undefined) copy.image = message.image;
    if (message.label !== undefined) copy.label = message.label;
    if (message.taskId !== undefined) copy.taskId = message.taskId;
    if (message.subtaskId !== undefined) copy.subtaskId = message.subtaskId;
    if (message.origin !== undefined) copy.origin = message.origin;
    if (message.maxOutputTokens !== undefined) copy.maxOutputTokens = message.maxOutputTokens;
    if (admission !== undefined || typeof message.deadlineBudgetMs === 'number') {
      copy.deadlineBudgetMs = Math.max(1, (admission !== undefined ? admission.deadlineAt - this.now() : (message.deadlineBudgetMs || 300000)) - margin);
    }
    return copy;
  }
}
