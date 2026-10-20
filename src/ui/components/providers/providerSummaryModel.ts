// Pure logic for provider setup after a bridge enrollment (REQ-ENR-2..5) and the
// shared provider row helpers ProviderSetupSurface renders. No React and no fetch,
// so every decision here is unit-testable (tests/ui_enrollment_provider_summary_test.ts).

/** How long the approval page waits for an approved bridge to restart and reconnect. */
export const RECONNECT_TIMEOUT_MS = 90_000;
/** Polling fallback for the reconnect wait, next to the bridge status_changed WS event. */
export const RECONNECT_POLL_MS = 2000;
/** A reconnect poll that has not settled by then is aborted and counted as "not yet". */
export const RECONNECT_REQUEST_TIMEOUT_MS = 5000;
/** The countdown clock ticks on its own, never waiting for a poll to settle. */
export const RECONNECT_CLOCK_MS = 1000;
/** How long enrollment-mode discovery keeps retrying while the bridge is still offline. */
export const DISCOVERY_RETRY_TIMEOUT_MS = 90_000;
export const DISCOVERY_RETRY_MS = 2000;

/** The provider fields these helpers read (a subset of BridgeProviderStatus). */
export interface ProviderSummaryInput {
  provider: string;
  display_name: string;
  state: 'present' | 'absent';
  enabled: boolean;
  models: Array<{ state: 'active' | 'deprecated' }>;
}

/** A bridge row as GET /bridges or GET /bridges/{id} returns it (only the fields read here). */
export interface BridgeReconnectRow {
  status?: string;
  enrollment_state?: string;
}

export type ReconnectStage = 'waiting' | 'ready' | 'timed-out';

/**
 * REQ-ENR-2: an approved bridge is back once its runtime is online AND the hub
 * committed its enrollment. A row with no enrollment_state is not treated as enrolled.
 */
export function bridgeReconnectReady(row: BridgeReconnectRow | null | undefined): boolean {
  if (!row) return false;
  return String(row.status || '').toLowerCase() === 'online'
    && String(row.enrollment_state || '').toLowerCase() === 'enrolled';
}

/** Where the reconnect wait stands; readiness wins over a deadline reached on the same tick. */
export function reconnectStage(ready: boolean, startedAtMs: number, nowMs: number, timeoutMs = RECONNECT_TIMEOUT_MS): ReconnectStage {
  if (ready) return 'ready';
  return nowMs - startedAtMs >= timeoutMs ? 'timed-out' : 'waiting';
}

/** Whole seconds left in the reconnect wait (never negative). */
export function reconnectSecondsLeft(startedAtMs: number, nowMs: number, timeoutMs = RECONNECT_TIMEOUT_MS): number {
  return Math.max(0, Math.ceil((startedAtMs + timeoutMs - nowMs) / 1000));
}

/** The timers startReconnectWait uses; injectable so tests can drive time by hand. */
export interface ReconnectTimers {
  now(): number;
  setTimeout(fn: () => void, ms: number): unknown;
  clearTimeout(handle: unknown): void;
  setInterval(fn: () => void, ms: number): unknown;
  clearInterval(handle: unknown): void;
}

const realTimers: ReconnectTimers = {
  now: () => Date.now(),
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
  setInterval: (fn, ms) => setInterval(fn, ms),
  clearInterval: (handle) => clearInterval(handle as ReturnType<typeof setInterval>),
};

export interface ReconnectWaitOptions {
  /** One readiness check (GET /bridges/{id}); must honour the signal. Rejections count as "not yet". */
  poll: (signal: AbortSignal) => Promise<boolean>;
  onReady: () => void;
  /** Called on every clock tick, independent of the network, so the deadline always advances. */
  onTick: (nowMs: number) => void;
  timers?: ReconnectTimers;
  pollMs?: number;
  requestTimeoutMs?: number;
  clockMs?: number;
}

/**
 * REQ-ENR-2: drives the reconnect wait. The clock and the polls are independent: a
 * stalled GET can never freeze the countdown. Polls are serialized (the next starts
 * pollMs after the previous settles) and each is aborted after requestTimeoutMs, so
 * at most one request is ever in flight. Returns stop(), which cancels everything.
 */
export function startReconnectWait(options: ReconnectWaitOptions): () => void {
  const timers = options.timers ?? realTimers;
  const pollMs = options.pollMs ?? RECONNECT_POLL_MS;
  const requestTimeoutMs = options.requestTimeoutMs ?? RECONNECT_REQUEST_TIMEOUT_MS;
  let stopped = false;
  let inFlight: AbortController | null = null;
  let expiry: unknown = null;
  let nextPoll: unknown = null;

  const clock = timers.setInterval(() => { if (!stopped) options.onTick(timers.now()); }, options.clockMs ?? RECONNECT_CLOCK_MS);

  const runPoll = async () => {
    nextPoll = null;
    if (stopped) return;
    const controller = new AbortController();
    inFlight = controller;
    let ready = false;
    try {
      // The race settles even if the poll ignores its abort signal.
      ready = await Promise.race([
        options.poll(controller.signal),
        new Promise<boolean>((resolve) => {
          expiry = timers.setTimeout(() => { controller.abort(); resolve(false); }, requestTimeoutMs);
        }),
      ]);
    } catch {
      // transient; the WS event or the next poll still applies
    } finally {
      timers.clearTimeout(expiry);
      expiry = null;
      inFlight = null;
    }
    if (stopped) return;
    if (ready) {
      options.onReady();
      return;
    }
    nextPoll = timers.setTimeout(() => void runPoll(), pollMs);
  };

  void runPoll();
  return () => {
    stopped = true;
    timers.clearInterval(clock);
    if (nextPoll !== null) timers.clearTimeout(nextPoll);
    if (expiry !== null) timers.clearTimeout(expiry);
    inFlight?.abort();
  };
}

/**
 * Discovery answers 409 bridge_offline until the bridge's runtime socket is live,
 * which is expected right after an enrollment: that is worth retrying, nothing else is.
 */
export function isRetriableDiscoveryError(err: unknown): boolean {
  const e = err as { code?: unknown; status?: unknown } | null;
  if (!e || typeof e !== 'object') return false;
  if (e.code !== undefined && e.code !== null && e.code !== '') return e.code === 'bridge_offline';
  return e.status === 409;
}

export function activeModelCount(provider: ProviderSummaryInput): number {
  return provider.models.filter((model) => model.state === 'active').length;
}

export function modelCountLabel(count: number): string {
  return `${count} ${count === 1 ? 'model' : 'models'}`;
}

/** REQ-ENR-3: checked by default iff the provider is present and has at least one active model. */
export function defaultProviderSelection(providers: ProviderSummaryInput[]): Record<string, boolean> {
  const out: Record<string, boolean> = {};
  for (const provider of providers) {
    if (provider.state === 'present') out[provider.provider] = activeModelCount(provider) >= 1;
  }
  return out;
}

export function presentProviders<T extends ProviderSummaryInput>(providers: T[]): T[] {
  return providers.filter((provider) => provider.state === 'present');
}

/** One muted line for every absent provider, or '' when all were found. */
export function notFoundSummary(providers: ProviderSummaryInput[]): string {
  const absent = providers.filter((provider) => provider.state !== 'present').map((provider) => provider.display_name || provider.provider);
  return absent.length ? `Not found: ${absent.join(', ')}` : '';
}

export function checkedProviderCount(providers: ProviderSummaryInput[], selection: Record<string, boolean>): number {
  return presentProviders(providers).filter((provider) => Boolean(selection[provider.provider])).length;
}

/** REQ-ENR-4: 'Enable N providers', or 'Continue' when nothing is checked. */
export function enableButtonLabel(checked: number): string {
  if (checked <= 0) return 'Continue';
  return `Enable ${checked} ${checked === 1 ? 'provider' : 'providers'}`;
}

/**
 * REQ-ENR-4: the PUTs to send — one per present provider whose desired state
 * differs from its current one. Absent providers are never touched (the hub
 * refuses enabled=true for them).
 */
export function providerEnableChanges(
  providers: ProviderSummaryInput[],
  selection: Record<string, boolean>,
): Array<{ provider: string; enabled: boolean }> {
  return presentProviders(providers)
    .filter((provider) => Boolean(selection[provider.provider]) !== provider.enabled)
    .map((provider) => ({ provider: provider.provider, enabled: Boolean(selection[provider.provider]) }));
}

export type PillTone = 'success' | 'warning' | 'neutral' | 'danger';

/** The per-provider status pill on the full Settings/enrollment card. */
export function providerStatus(provider: ProviderSummaryInput): { label: string; tone: PillTone } {
  if (provider.state === 'absent') return { label: 'Not detected', tone: 'neutral' };
  if (provider.enabled) return { label: 'Enabled', tone: 'success' };
  return { label: 'Detected', tone: 'neutral' };
}

/** The bridge pill, from the bridge's real status rather than a hardcoded "Online". */
export function bridgeStatusPill(status: string): { label: string; tone: PillTone } {
  return String(status || '').toLowerCase() === 'online'
    ? { label: 'Online', tone: 'success' }
    : { label: 'Offline', tone: 'warning' };
}
