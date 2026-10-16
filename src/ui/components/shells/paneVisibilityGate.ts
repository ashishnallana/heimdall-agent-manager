/**
 * REQ-PTY-NET-5: visibility gating for pane sockets.
 *
 * A pane in a hidden tab (document.hidden) kept its viewer socket — and therefore the bridge
 * -> hub stream for that session — alive through the 30 s heartbeat for as long as the tab
 * stayed hidden. Nothing could be seen, so every byte was waste, and on the bridge side the
 * pty-host stream stayed attached.
 *
 * The gate waits PANE_HIDDEN_PAUSE_MS after the document becomes hidden (a quick tab flick
 * must not cost a reconnect + repaint) and then asks the hook to close its socket. When the
 * document becomes visible again it asks for an immediate reconnect; the fresh attach earns
 * a full-screen repaint (pty-host catch-up or the hub's cached snapshot), which is exactly
 * the "needs repaint" state a resumed pane is in.
 *
 * Pure: the document is reached through `isHidden`, timers through the injected clock, so
 * the policy is unit-testable without a DOM.
 */
export const PANE_HIDDEN_PAUSE_MS = 10_000;

export interface VisibilityGateOptions {
  isHidden: () => boolean;
  /** Close the socket; the pane is now paused and needs a repaint on resume. */
  onPause: () => void;
  /** Reconnect immediately. Called only after onPause. */
  onResume: () => void;
  pauseAfterMs?: number;
  setTimeout?: (fn: () => void, ms: number) => unknown;
  clearTimeout?: (handle: unknown) => void;
}

export interface VisibilityGate {
  /** Wire to document 'visibilitychange'. Safe to call redundantly. */
  notify(): void;
  /** Cancel any pending pause; the gate no longer calls back. */
  dispose(): void;
  readonly paused: boolean;
}

export function createVisibilityGate(options: VisibilityGateOptions): VisibilityGate {
  const pauseAfterMs = options.pauseAfterMs ?? PANE_HIDDEN_PAUSE_MS;
  const schedule = options.setTimeout ?? ((fn: () => void, ms: number) => setTimeout(fn, ms));
  const cancel = options.clearTimeout ?? ((handle: unknown) => clearTimeout(handle as ReturnType<typeof setTimeout>));
  let timer: unknown = null;
  let paused = false;
  let disposed = false;

  const clearTimer = () => {
    if (timer !== null) {
      cancel(timer);
      timer = null;
    }
  };

  return {
    notify() {
      if (disposed) return;
      if (options.isHidden()) {
        if (paused || timer !== null) return;
        timer = schedule(() => {
          timer = null;
          if (disposed || paused || !options.isHidden()) return;
          paused = true;
          options.onPause();
        }, pauseAfterMs);
        return;
      }
      clearTimer();
      if (paused) {
        paused = false;
        options.onResume();
      }
    },
    dispose() {
      disposed = true;
      clearTimer();
    },
    get paused() { return paused; },
  };
}
