type UpdatePhase = 'disabled' | 'idle' | 'checking' | 'available' | 'downloading' | 'downloaded' | 'up-to-date' | 'error' | 'preparing-restart';
type UpdateSnapshot = {
  schemaVersion: 1; phase: UpdatePhase; currentVersion: string; targetVersion: string;
  supported: boolean; reason: string; channel: 'stable'; message: string;
  errorCode: string; retryable: boolean; percent: number | null;
  transferred: number | null; total: number | null; lastCheckedAt: string | null;
};

/** No Electron globals: lifecycle fixtures use the same controller as production. */
function createDesktopUpdateController(deps: {
  updater: any; eligibility: any; onState: (state: UpdateSnapshot) => void;
  clock?: any;
}) {
  const clock = deps.clock || { setTimeout, clearTimeout, setInterval, clearInterval, now: () => Date.now() };
  const updater = deps.updater;
  let running = false;
  let generation = 0;
  let busy = false;
  let flightActive = false;
  let restartRequested = false;
  let startup: any = null;
  let interval: any = null;
  let progressAt = -Infinity;
  const listeners: [string, (...args: any[]) => void][] = [];
  let state: UpdateSnapshot = {
    schemaVersion: 1, phase: 'disabled', currentVersion: deps.eligibility.currentVersion,
    targetVersion: '', supported: Boolean(deps.eligibility.supported), reason: deps.eligibility.reason,
    channel: 'stable', message: '', errorCode: '', retryable: false, percent: null,
    transferred: null, total: null, lastCheckedAt: null,
  };
  function snapshot(): UpdateSnapshot { return { ...state }; }
  function publish(next: Partial<UpdateSnapshot>) {
    state = { ...state, ...next };
    try { deps.onState(snapshot()); } catch (_error) { /* A destroyed window cannot stop updating. */ }
  }
  function fail(error: any) {
    // Classify locally. Never forward server HTML, URLs, tokens or arbitrary errors to UI.
    const text = String(error?.code || '') + ' ' + String(error?.message || error || '');
    const [errorCode, message] = /signature|publisher|ERR_UPDATER_INVALID_SIGNATURE/i.test(text)
      ? ['signature', 'Update signature verification failed. Update manually from the official release.']
      : /sha512|checksum|digest/i.test(text) ? ['checksum', 'Update integrity verification failed. Retry the download.']
      : /ENOSPC|EACCES|EPERM|disk/i.test(text) ? ['disk', 'Unable to save the update. Check disk space and installation permissions.']
      : /429|403|rate.?limit/i.test(text) ? ['rate-limit', 'The release host is limiting requests. Try again later.']
      : /ENOTFOUND|ECONN|network|offline|timed?.?out/i.test(text) ? ['offline', 'Unable to reach the release host. Check your connection and retry.']
      : ['feed', 'No valid update could be retrieved for this installation. Retry or update manually.'];
    publish({ phase: 'error', errorCode, message, retryable: true, percent: null, targetVersion: '' });
  }
  function on(name: string, callback: (...args: any[]) => void) {
    const owned = (...args: any[]) => { if (running && busy && !['preparing-restart', 'error'].includes(state.phase)) callback(...args); };
    listeners.push([name, owned]);
    updater.on(name, owned);
  }
  function version(info: any): string {
    return typeof info?.version === 'string' && info.version.length <= 64 && /^\d+\.\d+\.\d+$/.test(info.version) ? info.version : '';
  }
  function start() {
    if (running) return;
    if (flightActive) { restartRequested = true; return; }
    restartRequested = false;
    running = true;
    generation++;
    if (!state.supported) { publish({ phase: 'disabled', message: 'Use the official installer or package manager to update this installation.' }); return; }
    updater.autoDownload = true;
    updater.autoInstallOnAppQuit = false;
    updater.allowPrerelease = false;
    updater.allowDowngrade = false;
    updater.disableWebInstaller = true;
    on('checking-for-update', () => publish({ phase: 'checking' }));
    on('update-available', (info: any) => {
      const targetVersion = version(info);
      if (!targetVersion) { fail(new Error('Invalid feed version')); return; }
      publish({ phase: 'available', targetVersion, message: `Ninjy ${targetVersion} is available.` });
    });
    on('update-not-available', () => { publish({ phase: 'up-to-date', message: 'Ninjy is up to date.', targetVersion: '' }); });
    on('download-progress', (progress: any) => {
      if (clock.now() - progressAt < 250) return;
      progressAt = clock.now();
      const finite = (value: any) => typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : null;
      const bytes = (value: any) => Number.isSafeInteger(value) && value >= 0 ? value : null;
      const p = finite(progress?.percent);
      publish({ phase: 'downloading', percent: p === null ? null : Math.min(100, p),
        transferred: bytes(progress?.transferred), total: bytes(progress?.total), message: 'Downloading Ninjy update…' });
    });
    on('update-downloaded', (info: any) => {
      const targetVersion = version(info);
      if (!targetVersion || targetVersion !== state.targetVersion) { fail(new Error('Invalid feed version')); return; }
      publish({ phase: 'downloaded', targetVersion, percent: 100, retryable: false, message: `Ninjy ${targetVersion} is ready. Restart when you are ready.` });
    });
    on('error', fail);
    publish({ phase: state.phase === 'downloaded' ? 'downloaded' : 'idle' });
    startup = clock.setTimeout(() => { void check(); }, 30_000);
    interval = clock.setInterval(() => { void check(); }, 6 * 60 * 60 * 1000);
    startup?.unref?.(); interval?.unref?.();
  }
  async function check() {
    if (!running || !state.supported || busy || ['downloaded', 'preparing-restart'].includes(state.phase)) return snapshot();
    busy = true;
    flightActive = true;
    const epoch = generation;
    publish({ phase: 'checking', lastCheckedAt: new Date(clock.now()).toISOString(),
      message: 'Checking for Ninjy updates…', errorCode: '', retryable: false, percent: null,
      transferred: null, total: null, targetVersion: '' });
    try {
      const result = await updater.checkForUpdates();
      // checkForUpdates resolves before an automatic download. Keep ownership
      // until downloadPromise settles, rather than opening a second check race.
      await result?.downloadPromise;
    } catch (error) { if (running && generation === epoch) fail(error); }
    finally {
      flightActive = false;
      if (running && generation === epoch) {
        busy = false;
        if (['checking', 'available', 'downloading'].includes(state.phase)) fail(new Error('Incomplete update response'));
      }
      if (restartRequested) start();
    }
    return snapshot();
  }
  function stop() {
    running = false;
    restartRequested = false;
    generation++;
    busy = false;
    clock.clearTimeout(startup); clock.clearInterval(interval);
    startup = interval = null;
    for (const [name, listener] of listeners) updater.removeListener(name, listener);
    listeners.length = 0;
  }
  return {
    start, stop, check, retry: check, getState: snapshot,
    beginRestart: () => {
      if (!running || !state.supported || busy || state.phase !== 'downloaded') return false;
      publish({ phase: 'preparing-restart', message: 'Saving work before restart…' });
      return true;
    },
    abortRestart: (message = 'Restart cancelled. Your current app remains available.') => {
      if (state.phase === 'preparing-restart') publish({ phase: 'downloaded', message });
    },
  };
}

module.exports = { createDesktopUpdateController };
