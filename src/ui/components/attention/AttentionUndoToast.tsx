import { useEffect, useState, useSyncExternalStore } from 'react';
import { attentionScheduler, type ActionScheduler } from '../../services/attention/actionScheduler';

/**
 * App-level Undo toast for deferred attention actions. Rendered by the shell (not
 * the deck) so the undo window survives closing the deck or navigating. Shows the
 * most recent pending action with a countdown, and any send failure.
 */
export function AttentionUndoToast({ scheduler = attentionScheduler }: { scheduler?: ActionScheduler }) {
  const snap = useSyncExternalStore(scheduler.subscribe, scheduler.getSnapshot, scheduler.getSnapshot);
  const latest = snap.pending[snap.pending.length - 1];
  const [, tick] = useState(0);

  useEffect(() => {
    if (!latest) return;
    const id = globalThis.setInterval(() => tick((n) => n + 1), 250);
    return () => globalThis.clearInterval(id);
  }, [latest]);

  useEffect(() => {
    if (!snap.error) return;
    const id = globalThis.setTimeout(() => scheduler.acknowledgeError(), 6000);
    return () => globalThis.clearTimeout(id);
  }, [snap.error, scheduler]);

  if (!latest && !snap.error) return null;
  const seconds = latest ? Math.max(0, Math.ceil((latest.dueAt - Date.now()) / 1000)) : 0;
  return (
    <div
      role="status"
      aria-live="polite"
      data-debug-id="attention-undo-toast"
      className="fixed bottom-[calc(var(--ui-bottom-chrome,32px)+12px)] left-1/2 z-toast flex max-w-[calc(100%-32px)] -translate-x-1/2 items-center gap-3 rounded-[var(--radius-md)] border border-subtle bg-surface-raised px-3 py-2 text-[13px] text-primary shadow-panel"
    >
      {latest ? (
        <>
          <span>
            {latest.label}
            {snap.pending.length > 1 ? ` (+${snap.pending.length - 1} more)` : ''}
            <span className="ml-2 text-faint tabular-nums">{seconds}s</span>
          </span>
          <button type="button" data-debug-id="attention-undo" className="font-semibold text-warning hover:underline" onClick={() => scheduler.undo(latest.id)}>
            Undo
          </button>
        </>
      ) : (
        <>
          <span role="alert" className="text-danger">{snap.error}</span>
          <button type="button" data-debug-id="attention-error-dismiss" className="text-muted hover:text-primary" onClick={() => scheduler.acknowledgeError()}>Dismiss</button>
        </>
      )}
    </div>
  );
}
