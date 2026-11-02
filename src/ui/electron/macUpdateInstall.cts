/** Own only our public native listeners. Never call MacUpdater.quitAndInstall:
 * 6.8.12 leaves a persistent quit callback armed after native staging errors. */
function createMacUpdateInstall(native: any, clock: any = { setTimeout, clearTimeout }) {
  let attempted = false;
  let active: { cancel: (reason: string) => void } | null = null;

  function stage(finalGate: () => boolean): Promise<void> {
    if (attempted) return Promise.reject(new Error('Relaunch Ninjy before trying installation again.'));
    attempted = true;
    return new Promise((resolve, reject) => {
      let armed = true;
      let timer: any;
      function cleanup() {
        native.removeListener('update-downloaded', completed);
        native.removeListener('error', failed);
        clock.clearTimeout(timer);
        active = null;
      }
      function cancel(reason: string) {
        if (!armed) return;
        armed = false; // Disarm before listener removal or releasing renderer guards.
        cleanup();
        reject(new Error(reason));
      }
      function failed() { cancel('Native update verification failed. Relaunch Ninjy or update manually.'); }
      function completed() {
        if (!armed) return;
        if (!finalGate()) { cancel('Restart preparation expired. Relaunch Ninjy before retrying.'); return; }
        armed = false; // One-shot authorization, consumed synchronously before quit.
        cleanup();
        try { native.quitAndInstall(); resolve(); }
        catch (_error) { reject(new Error('Unable to restart. Relaunch Ninjy or update manually.')); }
      }
      active = { cancel };
      native.on('update-downloaded', completed);
      native.on('error', failed);
      timer = clock.setTimeout(() => cancel('Native staging timed out. Relaunch Ninjy before retrying.'), 120_000);
      try { native.checkForUpdates(); }
      catch (_error) { failed(); }
    });
  }

  return {
    stage,
    cancel: (reason = 'Restart cancelled. Relaunch Ninjy before retrying.') => active?.cancel(reason),
    quarantined: () => attempted && !active,
  };
}

module.exports = { createMacUpdateInstall };
