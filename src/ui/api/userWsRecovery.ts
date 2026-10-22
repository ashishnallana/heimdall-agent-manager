// REQ-3: the user WebSocket's recovery rules, kept free of React and the store so they
// can be tested directly (tests/ui_user_ws_recovery_test.ts). useUserWebSocket wires
// them to the socket.
//
// Wire contract (hub src/hub/service/events/event_bus.odin):
// - `user_ws_ready` carries `stream_epoch` (unique per connection) and `stream_seq: 0`.
// - Every event on that connection carries the same `stream_epoch` and a `stream_seq`
//   contiguous from 1. It counts only this connection's events, so another user's
//   traffic never shows up as a gap. (The hub-global `version`/`event_id` on
//   resource_changed is NOT a gap signal.)
// - `{type:"resync_required", reason}` replaces an event the hub could not deliver.
// - Close 1013: the hub has no free slot; retry later.
// - Close 4401/4403: post-upgrade auth revoked (reserved: the hub does not send these
//   yet, because cookie/proxy auth cannot be re-checked from the socket).
//
// Resync signal: each trigger becomes one call of the resync callback with a reason and
// one `heimdall:user-ws-resync` window event ({detail: {reason}}), so stores outside RTK
// Query can refresh too. `heimdall:user-ws-reconnected` still fires on reconnect.

export type UserWsResyncReason = 'initial' | 'reconnect' | 'gap' | 'epoch_changed' | 'resync_required';

export const USER_WS_RESYNC_EVENT = 'heimdall:user-ws-resync';
export const USER_WS_CLOSE_TRY_AGAIN_LATER = 1013;
export const USER_WS_CLOSE_UNAUTHENTICATED = 4401;
export const USER_WS_CLOSE_FORBIDDEN = 4403;

export type StreamVerdict = { deliver: boolean; resync: UserWsResyncReason | null };

// UserWsStreamTracker follows one connection's delivery stream. onReady starts a new
// connection; onEvent decides whether to deliver a frame and whether it shows that
// something was missed. A hub without stream fields (protocol 1) is passed through.
export class UserWsStreamTracker {
  private epoch: string | null = null;
  private lastSeq = 0;
  private readyCount = 0;

  // onReady returns 'initial' for the first ready this tracker ever sees and 'reconnect'
  // for every later one. Both are resyncs: the first closes the window between the
  // page's first GETs and the subscription going live.
  onReady(payload: any): UserWsResyncReason {
    this.epoch = typeof payload?.stream_epoch === 'string' ? payload.stream_epoch : null;
    this.lastSeq = Number.isFinite(payload?.stream_seq) ? Number(payload.stream_seq) : 0;
    this.readyCount += 1;
    return this.readyCount === 1 ? 'initial' : 'reconnect';
  }

  onEvent(payload: any): StreamVerdict {
    const seq = payload?.stream_seq;
    if (typeof seq !== 'number' || !Number.isFinite(seq)) {
      return { deliver: payload?.type !== 'resync_required', resync: payload?.type === 'resync_required' ? 'resync_required' : null };
    }
    const epoch = typeof payload?.stream_epoch === 'string' ? payload.stream_epoch : null;
    let resync: UserWsResyncReason | null = null;
    if (epoch !== this.epoch) {
      // Should not happen within one socket; treat as a fresh stream.
      this.epoch = epoch;
      this.lastSeq = seq;
      resync = 'epoch_changed';
    } else if (seq <= this.lastSeq) {
      return { deliver: false, resync: null };
    } else {
      if (seq > this.lastSeq + 1) resync = 'gap';
      this.lastSeq = seq;
    }
    if (payload?.type === 'resync_required') return { deliver: false, resync: resync || 'resync_required' };
    return { deliver: true, resync };
  }
}

export const RESYNC_MIN_INTERVAL_MS = 1000;

// createResyncScheduler runs at most one resync per window: the first trigger runs at
// once, later triggers inside the window collapse into one trailing run. A burst of gaps
// therefore costs at most two resyncs, not one per frame.
export function createResyncScheduler(
  run: (reason: UserWsResyncReason) => void,
  opts: { minIntervalMs?: number; now?: () => number; setTimer?: (fn: () => void, ms: number) => any; clearTimer?: (t: any) => void } = {},
) {
  const minIntervalMs = opts.minIntervalMs ?? RESYNC_MIN_INTERVAL_MS;
  const now = opts.now ?? (() => Date.now());
  const setTimer = opts.setTimer ?? ((fn, ms) => setTimeout(fn, ms));
  const clearTimer = opts.clearTimer ?? ((t) => clearTimeout(t));
  let lastRunAt = -Infinity;
  let timer: any = null;
  let pending: UserWsResyncReason | null = null;

  const fire = (reason: UserWsResyncReason) => {
    lastRunAt = now();
    run(reason);
  };

  return {
    trigger(reason: UserWsResyncReason) {
      const elapsed = now() - lastRunAt;
      if (timer === null && elapsed >= minIntervalMs) {
        fire(reason);
        return;
      }
      // 'initial' is the only scoped resync; any other reason widens it to a full one.
      // 'reconnect' wins over gap/resync_required too: the full resync is the same, but
      // only a 'reconnect' run fires heimdall:user-ws-reconnected, which listeners such
      // as the shell's identity refresh rely on.
      if (pending === null || pending === 'initial' || reason === 'reconnect') pending = reason;
      if (timer !== null) return;
      timer = setTimer(() => {
        timer = null;
        const r = pending;
        pending = null;
        if (r) fire(r);
      }, Math.max(0, minIntervalMs - elapsed));
    },
    cancel() {
      if (timer !== null) clearTimer(timer);
      timer = null;
      pending = null;
    },
  };
}

export const INITIAL_BACKOFF_MS = 1000;
export const MAX_BACKOFF_MS = 30000;
// After this many consecutive failed connects the hook stops on its own and waits for
// the browser to come back online, the tab to become visible or the window to regain
// focus. Transient outages are thus retried with capped delays, never forever.
export const MAX_CONSECUTIVE_FAILURES = 12;
// A connection must stay ready this long before it counts as healthy and clears the
// failure count. Resetting on ready alone let a ready-then-close flap (idle proxy drop,
// hub restart loop, a slot dropped right after ready) reconnect forever at the minimum
// delay, with a full resync each cycle.
export const STABLE_CONNECTION_MS = 30000;

// reconnectDelayMs: exponential, capped, with jitter (half fixed, half random) so many
// tabs do not reconnect in lockstep after a hub restart.
export function reconnectDelayMs(failures: number, random: () => number = Math.random): number {
  const exp = Math.min(MAX_BACKOFF_MS, INITIAL_BACKOFF_MS * 2 ** Math.max(0, failures));
  const half = exp / 2;
  return Math.round(half + random() * half);
}

export type CloseClass = 'auth' | 'forbidden' | 'transient' | 'unknown';

// classifyClose names what a close code says on its own. A browser cannot see the HTTP
// status of a refused upgrade (it surfaces as 1006), so 'unknown' before ready means
// "ask the HTTP API whether we are still signed in".
export function classifyClose(code: number | undefined): CloseClass {
  if (code === USER_WS_CLOSE_UNAUTHENTICATED) return 'auth';
  if (code === USER_WS_CLOSE_FORBIDDEN) return 'forbidden';
  if (code === USER_WS_CLOSE_TRY_AGAIN_LATER || code === 1001 || code === 1012) return 'transient';
  return 'unknown';
}

export type AuthProbeResult = 'ok' | 'unauthenticated' | 'forbidden' | 'unavailable';

export function authProbeResultForStatus(status: number): AuthProbeResult {
  if (status === 401) return 'unauthenticated';
  if (status === 403) return 'forbidden';
  if (status >= 200 && status < 300) return 'ok';
  return 'unavailable';
}

// probeUserAuth asks the identity endpoint whether the session is still valid. A network
// error or 5xx is an outage (retry), never a sign-out.
export async function probeUserAuth(url: string, fetchImpl: typeof fetch = fetch): Promise<AuthProbeResult> {
  try {
    const response = await fetchImpl(url, { method: 'GET', credentials: 'include' });
    return authProbeResultForStatus(response.status);
  } catch (_err) {
    return 'unavailable';
  }
}

// UserWsAuthError marks a failure that retrying cannot fix (the Electron ticket mint
// answered 401/403).
export class UserWsAuthError extends Error {
  readonly result: 'unauthenticated' | 'forbidden';
  constructor(result: 'unauthenticated' | 'forbidden', message: string) {
    super(message);
    this.result = result;
  }
}

// staleQueriesBefore lists the RTK Query cache entries whose request started before
// `readyAt` — the only ones that can have missed an event published before the socket
// was subscribed. The 'initial' resync refetches just these. On a cold load nearly every
// query starts before ready, so this costs about one extra fetch of the first page's
// queries, once (bounded, never repeated). It is cheaper than a full invalidation only
// for queries mounted after ready; refresh_integrate may narrow it to event-covered endpoints.
export function staleQueriesBefore(queries: Record<string, any> | undefined, readyAt: number): Array<{ endpointName: string; originalArgs: unknown }> {
  const out: Array<{ endpointName: string; originalArgs: unknown }> = [];
  for (const entry of Object.values(queries || {})) {
    if (!entry || typeof entry.endpointName !== 'string') continue;
    const started = Number(entry.startedTimeStamp);
    if (!Number.isFinite(started) || started >= readyAt) continue;
    out.push({ endpointName: entry.endpointName, originalArgs: entry.originalArgs });
  }
  return out;
}
