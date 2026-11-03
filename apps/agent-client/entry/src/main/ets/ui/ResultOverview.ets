/** A read-only projection of display bubbles. Full text stays intact for the reader. */
export interface ResultMessage {
  id: number;
  revision: number;
  kind: string;
  text: string;
  imagePath: string;
  pending: boolean;
  phase: string;
  device?: string;
  startedAt?: number;
  endedAt?: number;
  inferencePhase?: string;
}

export class ResultTurn {
  key: string = '';
  revision: number = 0;
  input: string = '';
  answer: string = '';
  process: string = '';
  imagePath: string = '';
  phase: string = 'done';
  device: string = '';
  startedAt: number = 0;
  endedAt: number = 0;
}

/** One card per conversation; the reader keeps every turn. */
export function sessionResult(key: string, turns: ResultTurn[]): ResultTurn {
  const latest = turns.length > 0 ? turns[turns.length - 1] : new ResultTurn();
  const result = new ResultTurn();
  result.key = key;
  result.revision = latest.revision;
  result.input = latest.input;
  result.answer = latest.answer;
  result.process = latest.process;
  result.imagePath = latest.imagePath;
  result.phase = turns.length > 0 ? latest.phase : 'empty';
  result.device = latest.device;
  result.startedAt = latest.startedAt;
  result.endedAt = latest.endedAt;
  return result;
}

export function resultTurns(messages: ResultMessage[]): ResultTurn[] {
  const turns: ResultTurn[] = [];
  let current: ResultTurn | null = null;
  for (const message of messages) {
    if (message.kind === 'input' || current === null) {
      current = new ResultTurn();
      current.key = 'result-' + message.id;
      turns.push(current);
    }
    current.revision += message.revision + 1;
    if (message.phase.length > 0) current.phase = message.phase;
    if (message.phase === 'running' && ['hub-queued', 'queued', 'sending', 'preparing', 'loading', 'prefill'].indexOf(message.inferencePhase ?? '') >= 0) {
      current.phase = message.inferencePhase ?? 'running';
    }
    if (message.device !== undefined && message.device.length > 0) current.device = message.device;
    if (message.startedAt !== undefined && message.startedAt > 0) current.startedAt = message.startedAt;
    if (message.endedAt !== undefined && message.endedAt > 0) current.endedAt = message.endedAt;
    if (message.imagePath.length > 0) current.imagePath = message.imagePath;
    if (message.kind === 'input') current.input = message.text;
    else if (message.kind === 'process') current.process += (current.process ? '\n' : '') + message.text;
    else if (message.kind !== 'status' && !message.pending) {
      current.answer += (current.answer ? '\n' : '') + message.text;
      if (message.kind === 'error') current.phase = 'failed';
    }
  }
  return turns;
}

/** One short line for each side of a thumbnail; never modify the stored turn. */
export function resultSnippet(text: string, limit: number): string {
  const compact = text.replace(/\s+/g, ' ').trim();
  if (compact.length <= limit) return compact;
  let end = Math.max(0, limit - 1);
  const last = compact.charCodeAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return compact.substring(0, end) + '…';
}

export function resultPhaseLabel(phase: string): string {
  if (phase === 'empty') return '未开始';
  if (phase === 'preparing') return '准备中';
  if (phase === 'hub-queued') return '中心等待分派';
  if (phase === 'queued') return '等待执行';
  if (phase === 'sending') return '发送中';
  if (phase === 'loading') return '加载模型';
  if (phase === 'prefill') return '理解中';
  if (phase === 'running') return '推理中';
  if (phase === 'partial') return '部分完成';
  if (phase === 'failed') return '失败';
  if (phase === 'cancelled') return '已停止';
  return '已完成';
}

export function resultIsActive(phase: string): boolean {
  return ['preparing', 'hub-queued', 'queued', 'sending', 'loading', 'prefill', 'running'].indexOf(phase) >= 0;
}

export function resultInputLabel(turn: ResultTurn): string {
  if (turn.phase === 'empty') return '—';
  if (turn.imagePath.length > 0 && (turn.input.trim().length === 0 || turn.input === '（附图）')) return '图片输入';
  return resultSnippet(turn.input, 24) || '推理请求';
}

export function resultElapsed(turn: ResultTurn, now: number): string {
  const end = resultIsActive(turn.phase) ? now : turn.endedAt;
  if (turn.startedAt <= 0 || end <= 0) return '—';
  const seconds = Math.floor(Math.max(0, end - turn.startedAt) / 1000);
  const minutes = Math.floor(seconds / 60);
  const tail = String(seconds % 60).padStart(2, '0');
  return minutes < 60 ? String(minutes).padStart(2, '0') + ':' + tail :
    String(Math.floor(minutes / 60)).padStart(2, '0') + ':' + String(minutes % 60).padStart(2, '0') + ':' + tail;
}
