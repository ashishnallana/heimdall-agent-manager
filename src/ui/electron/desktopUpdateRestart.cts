/** Main-owned restart transaction. Identity is captured before any await and
 * revalidated synchronously at the only installation boundary. */
function createDesktopUpdateRestart(deps: {
  controller: any; bridgeBusy: () => boolean; eligibility: () => boolean;
  document: () => any; prepare: (epoch: number, document: any) => Promise<boolean>;
  release: (epoch: number, document: any) => void;
  confirm: () => Promise<boolean>; install: (gate: () => boolean) => Promise<void>;
  cancelInstall: () => void; clock?: any;
}) {
  const clock = deps.clock || { setTimeout, clearTimeout };
  let sequence = 0;
  let active: { epoch: number; document: any; target: string; frozen: boolean; timer: any; exiting: boolean; cancel: () => void } | null = null;
  let lastError = '';
  function gate(transaction: typeof active) {
    return Boolean(transaction && active === transaction && !transaction.exiting && transaction.frozen && deps.eligibility()
      && deps.document() === transaction.document && transaction.document && !deps.bridgeBusy()
      && deps.controller.getState().phase === 'preparing-restart'
      && deps.controller.getState().targetVersion === transaction.target);
  }
  function abort(message = 'Restart cancelled. Save your work and try again.') {
    const transaction = active;
    if (!transaction) return;
    active = null; // Invalidate before disarming native callbacks and releasing freeze.
    lastError = message;
    clock.clearTimeout(transaction.timer);
    transaction.cancel();
    deps.cancelInstall();
    try { deps.release(transaction.epoch, transaction.document); } catch (_error) { /* Destroyed document. */ }
    deps.controller.abortRestart(message);
  }
  async function restart() {
    if (active || deps.bridgeBusy() || !deps.eligibility() || !deps.document()) return { ok: false, error: 'Finish Bridge operations and open the app before restarting.' };
    if (!deps.controller.beginRestart()) return { ok: false, error: 'No verified update is ready.' };
    let cancel!: () => void;
    const cancelled = new Promise<false>(resolve => { cancel = () => resolve(false); });
    const transaction = { epoch: ++sequence, document: deps.document(), target: deps.controller.getState().targetVersion,
      frozen: false, timer: null as any, exiting: false, cancel };
    active = transaction;
    lastError = '';
    transaction.timer = clock.setTimeout(() => abort(transaction.exiting
      ? 'Native restart did not complete. Relaunch Ninjy or update manually.'
      : 'Restart preparation timed out. Save your work and try again.'), 180_000);
    try {
      const ready = await Promise.race([deps.prepare(transaction.epoch, transaction.document), cancelled]);
      if (active !== transaction) return { ok: false, error: lastError };
      if (!ready) { abort('Unable to save all work. Finish sends/uploads, save or discard pending edits, and close other forms, editor or preview panes, then try again.'); return { ok: false, error: lastError }; }
      transaction.frozen = true;
      if (!gate(transaction)) { abort(); return { ok: false, error: lastError }; }
      const consent = await Promise.race([deps.confirm(), cancelled]);
      if (active !== transaction) return { ok: false, error: lastError };
      if (!consent || !gate(transaction)) { abort('Restart postponed. You can keep using Ninjy.'); return { ok: false, error: lastError }; }
      await Promise.race([deps.install(() => {
        if (!gate(transaction)) return false;
        transaction.exiting = true;
        // Retain the watchdog until actual process exit. A native quit method
        // returning without exiting must not leave editing frozen forever.
        return true;
      }), cancelled]);
      if (active !== transaction) return { ok: false, error: lastError };
      if (!transaction.exiting) { abort(); return { ok: false, error: lastError }; }
      // Keep freeze and Bridge exclusion held until exit (or beforeunload veto).
      return { ok: true };
    } catch (_error) {
      if (active === transaction) abort('Unable to install the update. Relaunch Ninjy or update manually.');
      return { ok: false, error: lastError };
    }
  }
  return { restart, abort, held: () => Boolean(active), exiting: () => Boolean(active?.exiting),
    epoch: () => active?.epoch ?? null };
}

module.exports = { createDesktopUpdateRestart };
