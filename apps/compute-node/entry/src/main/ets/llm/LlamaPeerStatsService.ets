import { hilog } from '@kit.PerformanceAnalysisKit';
import socket from '@ohos.net.socket';
import buffer from '@ohos.buffer';
import { loadLlamaInferenceConfig } from './LlamaSettings';

const PEER_STATS_PORT: number = 30002;
const POLL_MS: number = 2000;
const POLL_TIMEOUT_MS: number = 1000;
const STALE_MS: number = 6000;

export interface LlamaPeerTelemetry {
  online: boolean;
  ready: boolean;
  serving: boolean;
  ip: string;
  rank: number;
  rss: number;
  expertRam: number;
  hit: number;
  disk: number;
  memTotal: number;
  memAvail: number;
  updatedAt: number;
}

interface PeerStatsPayload {
  rank?: number;
  serving?: number;
  ready?: number;
  rss?: number;
  expertRam?: number;
  hit?: number;
  disk?: number;
  memTotal?: number;
  memAvail?: number;
}

class LlamaPeerStatsService {
  private filesDir: string = '';
  private peerIp: string = '';
  private timer: number = -1;
  private inFlight: boolean = false;
  private loggedOnline: boolean = false;
  private snapshot: LlamaPeerTelemetry = {
    online: false,
    ready: false,
    serving: false,
    ip: '',
    rank: 1,
    rss: 0,
    expertRam: 0,
    hit: -1,
    disk: 0,
    memTotal: 0,
    memAvail: 0,
    updatedAt: 0
  };

  start(filesDir: string): void {
    this.filesDir = filesDir;
    this.refreshConfig();
  }

  refreshConfig(): void {
    if (this.filesDir.length === 0) return;
    const config = loadLlamaInferenceConfig(this.filesDir);
    const nextIp = config === null ? '' : config.peerIp.trim();
    if (nextIp !== this.peerIp) {
      this.peerIp = nextIp;
      this.loggedOnline = false;
      hilog.info(0, 'PeerPresence', 'relay target=%{public}s', nextIp.length > 0 ? nextIp : 'none');
      this.snapshot = {
        online: false,
        ready: false,
        serving: false,
        ip: nextIp,
        rank: config !== null && config.roleMaster ? 1 : 0,
        rss: 0,
        expertRam: 0,
        hit: -1,
        disk: 0,
        memTotal: 0,
        memAvail: 0,
        updatedAt: 0
      };
    }
    if (this.peerIp.length === 0) {
      this.stopTimer();
      return;
    }
    if (this.timer < 0) {
      this.poll();
      this.timer = setInterval((): void => { this.poll(); }, POLL_MS);
    }
  }

  stop(): void {
    this.stopTimer();
  }

  getSnapshot(): LlamaPeerTelemetry {
    if (this.snapshot.online && Date.now() - this.snapshot.updatedAt > STALE_MS) {
      this.snapshot = {
        online: false,
        ready: false,
        serving: false,
        ip: this.peerIp,
        rank: this.snapshot.rank,
        rss: 0,
        expertRam: 0,
        hit: -1,
        disk: 0,
        memTotal: 0,
        memAvail: 0,
        updatedAt: this.snapshot.updatedAt
      };
    }
    return this.snapshot;
  }

  private stopTimer(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private poll(): void {
    if (this.inFlight || this.peerIp.length === 0) return;
    this.inFlight = true;
    const host = this.peerIp;
    const tcp = socket.constructTCPSocketInstance();
    let text = '';
    let done = false;
    let timer = -1;
    const finish = (): void => {
      if (done) return;
      done = true;
      this.inFlight = false;
      if (timer >= 0) clearTimeout(timer);
      try { tcp.close(); } catch (_) {}
      if (text.length > 0) {
        this.apply(host, text);
      } else if (this.snapshot.online && Date.now() - this.snapshot.updatedAt > STALE_MS) {
        this.getSnapshot();
      }
    };
    timer = setTimeout(finish, POLL_TIMEOUT_MS);
    tcp.on('message', (message: socket.SocketMessageInfo): void => {
      try {
        text += buffer.from(message.message).toString('utf-8');
        if (text.indexOf('}') >= 0) finish();
      } catch (_) {
        finish();
      }
    });
    tcp.on('close', finish);
    tcp.on('error', finish);
    tcp.connect({ address: { address: host, port: PEER_STATS_PORT }, timeout: 800 })
      .then((): void => {
        tcp.send({ data: 'stats\n' }).catch(finish);
      })
      .catch(finish);
  }

  private apply(host: string, text: string): void {
    try {
      const payload = JSON.parse(text) as PeerStatsPayload;
      const hit = payload.hit === undefined ? -1 : Number(payload.hit);
      this.snapshot = {
        online: true,
        ready: Number(payload.ready) === 1,
        serving: Number(payload.serving) === 1,
        ip: host,
        rank: Number.isInteger(payload.rank) ? Number(payload.rank) : this.snapshot.rank,
        rss: Number(payload.rss) || 0,
        expertRam: Number(payload.expertRam) || 0,
        hit: Number.isFinite(hit) && hit >= 0 ? hit : -1,
        disk: Number(payload.disk) || 0,
        memTotal: Number(payload.memTotal) || 0,
        memAvail: Number(payload.memAvail) || 0,
        updatedAt: Date.now()
      };
      if (!this.loggedOnline) {
        this.loggedOnline = true;
        hilog.info(0, 'PeerPresence',
          'relay peer online host=%{public}s rss=%{public}d expert=%{public}d hit=%{public}f',
          host, this.snapshot.rss, this.snapshot.expertRam, this.snapshot.hit);
      }
    } catch (error) {
      hilog.warn(0, 'PeerPresence', 'peer stats parse failed: %{public}s', String(error));
    }
  }
}

export const llamaPeerStats: LlamaPeerStatsService = new LlamaPeerStatsService();
