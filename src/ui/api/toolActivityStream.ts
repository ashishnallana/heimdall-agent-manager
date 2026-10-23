import {
  LIVE_MEMBER_CAP, validInstanceId, parseLiveSnapshot, compareToolOrder,
  toolMembersSelected, toolStateReceived, toolMembersUnavailable, toolCapacityExceeded, type ToolOrder,
} from '../store/toolActivitySlice';

export const TOOL_FRESH_MS = 120_000;
export const TOOL_PING_MS = 30_000;
export const TOOL_PONG_MS = 15_000;
export interface ToolSocket {
  readyState: number;
  onopen: ((event: any) => void) | null;
  onmessage: ((event: any) => void) | null;
  onclose: ((event: any) => void) | null;
  onerror: ((event: any) => void) | null;
  send(data: string): void;
  close(): void;
}
export interface ToolStreamEnvironment {
  now(): number;
  url(signal: AbortSignal): Promise<string>;
  socket(url: string): ToolSocket;
  every(callback: () => void, ms: number): () => void;
  onResume(callback: () => void): () => void;
}
type Receipt = { deadline: number; order?: ToolOrder; baseline: boolean };
export type ToolSubscription = { update(ids: string[]): void; release(): void };

// One owner per authenticated UI store, shared by every mounted own/chain view.
// Transport liveness and per-instance state freshness are deliberately independent.
export class ToolActivityStream {
  private views = new Map<symbol, string[]>();
  private receipts = new Map<string, Receipt>();
  private socket: ToolSocket | null = null;
  private abort: AbortController | null = null;
  private generation = 0;
  private cancelTick?: () => void;
  private cancelResume?: () => void;
  private reconnectAt = 0;
  private failures = 0;
  private pingAt = 0;
  private pongBy = 0;
  private connectBy = 0;
  private authKey = '';

  constructor(private dispatch: (action: any) => void, private env: ToolStreamEnvironment) {}

  subscribe(authKey: string, ids: string[]): ToolSubscription {
    if (this.authKey !== authKey) {
      this.stop();
      this.views.clear();
      this.receipts.clear();
      this.dispatch(toolMembersSelected([]));
      this.authKey = authKey;
    }
    const token = Symbol();
    this.views.set(token, ids);
    this.reconcile();
    this.ensureRunning();
    return {
      update: (next) => {
        if (!this.views.has(token)) return;
        this.views.set(token, next);
        this.reconcile();
        this.ensureRunning();
      },
      release: () => {
        if (!this.views.delete(token)) return;
        this.reconcile();
        this.ensureRunning();
      },
    };
  }

  private ensureRunning() {
    if (!this.receipts.size) { this.stop(); return; }
    if (!this.cancelTick) {
      this.cancelTick = this.env.every(() => this.tick(), 1000);
      this.cancelResume = this.env.onResume(() => this.resume());
      void this.connect();
    }
  }

  private reconcile() {
    const ids = [...new Set([...this.views.values()].flat().filter(validInstanceId))].sort();
    // Never silently truncate an authorized roster into a misleading partial view.
    if (ids.length > LIVE_MEMBER_CAP) {
      this.invalidate();
      this.disconnect();
      this.receipts.clear();
      this.dispatch(toolCapacityExceeded());
      return;
    }
    const prior = [...this.receipts.keys()].sort();
    if (ids.join(',') === prior.join(',')) {
      if (!ids.length) this.dispatch(toolMembersSelected([]));
      return;
    }
    const next = new Map<string, Receipt>();
    for (const id of ids) next.set(id, this.receipts.get(id) ||
      { deadline: this.env.now() + TOOL_FRESH_MS, baseline: true });
    this.receipts = next;
    this.dispatch(toolMembersSelected(ids));
    this.sendSubscription();
  }

  private invalidate(ids = [...this.receipts.keys()]) {
    this.dispatch(toolMembersUnavailable(ids));
  }

  private sendSubscription() {
    if (this.socket?.readyState !== 1) return;
    try {
      this.socket.send(JSON.stringify({ type: 'subscribe', instance_ids: [...this.receipts.keys()].sort() }));
    } catch { this.failed(); }
  }

  private disconnect() {
    this.generation++;
    this.abort?.abort();
    this.abort = null;
    const socket = this.socket;
    this.socket = null;
    this.pongBy = this.pingAt = this.connectBy = 0;
    if (socket) {
      socket.onopen = socket.onmessage = socket.onclose = socket.onerror = null;
      try { socket.close(); } catch { /* already closed */ }
    }
  }

  private failed() {
    this.invalidate();
    this.disconnect();
    this.reconnectAt = this.env.now() + Math.min(1000 * 2 ** Math.min(this.failures++, 5), 30_000);
  }

  private async connect() {
    if (!this.receipts.size) return;
    this.disconnect();
    const generation = this.generation;
    const controller = this.abort = new AbortController();
    this.connectBy = this.env.now() + TOOL_PONG_MS;
    for (const receipt of this.receipts.values()) { receipt.baseline = true; receipt.order = undefined; }
    try {
      const url = await this.env.url(controller.signal);
      if (generation !== this.generation || !this.views.size) return;
      const socket = this.socket = this.env.socket(url);
      socket.onopen = () => {
        if (generation !== this.generation) return;
        this.connectBy = 0;
        this.pingAt = this.env.now() + TOOL_PING_MS;
        this.sendSubscription();
      };
      socket.onmessage = (event) => {
        if (generation !== this.generation || socket !== this.socket) return;
        this.receive(event.data);
      };
      socket.onclose = socket.onerror = () => {
        if (generation === this.generation) this.failed();
      };
    } catch {
      if (generation === this.generation) this.failed();
    }
  }

  private receive(data: unknown) {
    if (typeof data !== 'string' || data.length > 256 * 1024 ||
        new TextEncoder().encode(data).length > 256 * 1024) return;
    let frame: any;
    try { frame = JSON.parse(data); } catch { return; }
    if (frame?.type === 'pong') { this.pongBy = 0; return; }
    if (frame?.type === 'error') { this.failed(); return; }
    if (frame?.type === 'unavailable' && this.receipts.has(frame.instance_id)) {
      this.invalidate([frame.instance_id]);
      const receipt = this.receipts.get(frame.instance_id)!;
      receipt.baseline = true; receipt.order = undefined;
      return;
    }
    if (frame?.type !== 'state' || typeof frame.baseline !== 'boolean' ||
        typeof frame.refresh !== 'boolean') return;
    const snapshot = parseLiveSnapshot(frame.snapshot);
    if (!snapshot || frame.instance_id !== snapshot.instance_id) return;
    const receipt = this.receipts.get(snapshot.instance_id);
    if (!receipt || (receipt.baseline && !frame.baseline)) return;
    const order = receipt.order && compareToolOrder(snapshot, receipt.order);
    if (order !== undefined && (order < 0 || (order === 0 && !frame.refresh && !frame.baseline))) return;
    receipt.baseline = false;
    // Retain only ordering metadata outside Redux, never old tool content.
    receipt.order = { epoch: snapshot.epoch, generation: snapshot.generation, revision: snapshot.revision };
    receipt.deadline = this.env.now() + TOOL_FRESH_MS;
    this.failures = 0;
    this.dispatch(toolStateReceived(snapshot));
  }

  private tick() {
    const now = this.env.now();
    const expired: string[] = [];
    for (const [id, receipt] of this.receipts) {
      if (receipt.deadline && now >= receipt.deadline) {
        receipt.deadline = 0;
        expired.push(id);
      }
    }
    if (expired.length) this.invalidate(expired);
    if ((this.connectBy && now >= this.connectBy) || (this.pongBy && now >= this.pongBy)) {
      this.failed();
      return;
    }
    if (this.socket?.readyState === 1 && !this.pongBy && now >= this.pingAt) {
      try {
        this.socket.send(JSON.stringify({ type: 'ping' }));
        this.pongBy = now + TOOL_PONG_MS;
        this.pingAt = now + TOOL_PING_MS;
      } catch { this.failed(); }
    } else if (!this.socket && !this.abort && now >= this.reconnectAt) void this.connect();
  }

  resume() {
    if (!this.receipts.size) return;
    this.invalidate();
    // Reconnect earns an immediate fresh baseline even when background timers froze.
    this.failures = 0;
    void this.connect();
  }

  private stop() {
    this.disconnect();
    this.cancelTick?.();
    this.cancelResume?.();
    this.cancelTick = this.cancelResume = undefined;
    this.failures = 0;
  }
}
