// Deferred, undoable attention actions (attention deck v1).
//
// Every one-tap action on a card (approve, discard, snooze, mark read, hand to a
// reviewer) is HELD for a short window before it is sent, so Undo really undoes
// it: nothing has happened on the server yet. The scheduler is app-level (a module
// singleton the deck and the toast share), not deck state, so closing the deck or
// navigating does NOT cut the window short.
//
// - The card is hidden optimistically from the moment it is scheduled.
// - Undo drops the action before it is sent; the card comes back.
// - On pagehide every pending action is flushed at once, best-effort, with fetch
//   keepalive (the only way a request outlives the page). One that does not land
//   simply reappears on the next load, because its source still needs the user.
// - A failed send restores the card and reports the error.
//
// Replies and comments do NOT go through here: they are additive and deliberate,
// and they need the encrypting mutations, so they are sent immediately.

export const ATTENTION_UNDO_MS = 4000;

export type ScheduledAction = {
  /** Card the action resolves; hidden while pending and after success. */
  cardId: string;
  /** Toast text, e.g. "Approved". No ids. */
  label: string;
  /** Sends the action. keepalive=true when flushing on page exit. */
  run: (keepalive: boolean) => Promise<void>;
};

export type PendingAction = ScheduledAction & { id: number; dueAt: number };

export type SchedulerSnapshot = {
  pending: readonly PendingAction[];
  /** Cards to keep out of the deck: pending + recently succeeded. */
  hidden: ReadonlySet<string>;
  /** Most recent failure message, cleared by acknowledgeError. */
  error: string;
};

type Timers = {
  setTimeout: (fn: () => void, ms: number) => unknown;
  clearTimeout: (handle: unknown) => void;
  now: () => number;
};

const realTimers: Timers = {
  setTimeout: (fn, ms) => globalThis.setTimeout(fn, ms),
  clearTimeout: (h) => globalThis.clearTimeout(h as any),
  now: () => Date.now(),
};

export function createActionScheduler(opts: { delayMs?: number; timers?: Timers } = {}) {
  const delayMs = opts.delayMs ?? ATTENTION_UNDO_MS;
  const timers = opts.timers ?? realTimers;
  let nextId = 1;
  let pending: PendingAction[] = [];
  const handles = new Map<number, unknown>();
  // Succeeded cards stay hidden until the server stops returning them (prune).
  let settled = new Set<string>();
  let error = '';
  let snapshot: SchedulerSnapshot = { pending, hidden: new Set(), error };
  const listeners = new Set<() => void>();

  const emit = () => {
    const hidden = new Set<string>(settled);
    for (const p of pending) hidden.add(p.cardId);
    snapshot = { pending, hidden, error };
    for (const l of listeners) l();
  };

  const execute = async (action: PendingAction, keepalive: boolean) => {
    pending = pending.filter((p) => p.id !== action.id);
    handles.delete(action.id);
    settled = new Set(settled).add(action.cardId);
    emit();
    try {
      await action.run(keepalive);
    } catch (e: any) {
      const next = new Set(settled);
      next.delete(action.cardId);
      settled = next;
      error = `${action.label} failed: ${e?.message || 'request failed'}`;
      emit();
    }
  };

  return {
    schedule(action: ScheduledAction): number {
      const id = nextId++;
      const item: PendingAction = { ...action, id, dueAt: timers.now() + delayMs };
      pending = [...pending, item];
      handles.set(id, timers.setTimeout(() => { void execute(item, false); }, delayMs));
      emit();
      return id;
    },
    /** Cancels a pending action before it is sent. false if it already went. */
    undo(id: number): boolean {
      const item = pending.find((p) => p.id === id);
      if (!item) return false;
      timers.clearTimeout(handles.get(id));
      handles.delete(id);
      pending = pending.filter((p) => p.id !== id);
      emit();
      return true;
    },
    /** Sends everything now (page exit). */
    flushAll(keepalive: boolean): Promise<void[]> {
      const batch = pending;
      for (const p of batch) timers.clearTimeout(handles.get(p.id));
      return Promise.all(batch.map((p) => execute(p, keepalive)));
    },
    /**
     * Hide a card resolved by an IMMEDIATE action (a reply or comment that was
     * already sent), exactly as if a deferred action had succeeded.
     */
    settle(cardId: string): void {
      settled = new Set(settled).add(cardId);
      emit();
    },
    /** Bring a settled card back (its immediate action failed). */
    unsettle(cardId: string): void {
      if (!settled.has(cardId)) return;
      const next = new Set(settled);
      next.delete(cardId);
      settled = next;
      emit();
    },
    /**
     * Lift a settle after ms, so a card the server STILL returns by then shows
     * again (an accepted decision that never reached the agent). Harmless when
     * the card is gone: prune already dropped the key and unsettle is a no-op.
     */
    recheckAfter(cardId: string, ms: number): void {
      timers.setTimeout(() => {
        if (!settled.has(cardId)) return;
        const next = new Set(settled);
        next.delete(cardId);
        settled = next;
        emit();
      }, ms);
    },
    /** Forget settled cards the server no longer returns. */
    prune(liveCardIds: Iterable<string>): void {
      const live = new Set(liveCardIds);
      let changed = false;
      const next = new Set<string>();
      for (const id of settled) {
        if (live.has(id)) next.add(id);
        else changed = true;
      }
      if (changed) {
        settled = next;
        emit();
      }
    },
    acknowledgeError(): void {
      if (!error) return;
      error = '';
      emit();
    },
    getSnapshot: (): SchedulerSnapshot => snapshot,
    subscribe(listener: () => void): () => void {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
}

export type ActionScheduler = ReturnType<typeof createActionScheduler>;

/** The app's scheduler. Installs the page-exit flush once, in a browser. */
export const attentionScheduler: ActionScheduler = createActionScheduler();
if (typeof window !== 'undefined' && typeof window.addEventListener === 'function') {
  window.addEventListener('pagehide', () => { void attentionScheduler.flushAll(true); });
}
