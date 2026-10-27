const { autoUpdater } = require('electron-updater');

type UpdatePhase = 'disabled' | 'idle' | 'checking' | 'available' | 'downloading' | 'downloaded' | 'up-to-date' | 'error';
type UpdateState = { phase: UpdatePhase; version: string; percent: number; message: string };

let state: UpdateState = { phase: 'disabled', version: '', percent: 0, message: '' };
let changed: ((state: UpdateState) => void) | null = null;
let automaticTimer: NodeJS.Timeout | null = null;
let configured = false;

function publish(next: Partial<UpdateState>) {
  state = { ...state, ...next };
  changed?.({ ...state });
}

function start(enabled: boolean, onChanged: (next: UpdateState) => void) {
  changed = onChanged;
  if (!enabled) { publish({ phase: 'disabled', message: '' }); return; }
  if (configured) return;
  configured = true;
  autoUpdater.autoDownload = true;
  autoUpdater.autoInstallOnAppQuit = true;
  autoUpdater.allowPrerelease = false;
  autoUpdater.on('checking-for-update', () => publish({ phase: 'checking', message: 'Checking for Heimdall updates…', percent: 0 }));
  autoUpdater.on('update-available', (info: any) => publish({
    phase: 'available', version: String(info?.version || ''), message: `Heimdall ${String(info?.version || '')} is available.`, percent: 0,
  }));
  autoUpdater.on('update-not-available', () => publish({ phase: 'up-to-date', message: 'Heimdall is up to date.', percent: 0 }));
  autoUpdater.on('download-progress', (progress: any) => {
    const percent = Math.max(0, Math.min(100, Math.round(Number(progress?.percent || 0))));
    publish({ phase: 'downloading', percent, message: `Downloading Heimdall update… ${percent}%` });
  });
  autoUpdater.on('update-downloaded', (info: any) => publish({
    phase: 'downloaded', version: String(info?.version || state.version || ''), percent: 100,
    message: `Heimdall ${String(info?.version || state.version || '')} is ready to install.`,
  }));
  autoUpdater.on('error', (error: any) => publish({
    phase: 'error', message: `Heimdall update failed: ${String(error?.message || error || 'unknown error')}`.slice(0, 300),
  }));
  publish({ phase: 'idle', message: '' });
  const automaticCheck = () => { void check(false); };
  setTimeout(automaticCheck, 30_000).unref?.();
  automaticTimer = setInterval(automaticCheck, 6 * 60 * 60 * 1000);
  automaticTimer.unref?.();
}

async function check(manual: boolean = true) {
  if (!configured) return { ok: false, error: 'Desktop updates are available only in the installed app.' };
  try {
    await autoUpdater.checkForUpdates();
    return { ok: true };
  } catch (error: any) {
    const message = String(error?.message || error || 'Unable to check for updates.');
    if (manual) publish({ phase: 'error', message: `Heimdall update failed: ${message}`.slice(0, 300) });
    return { ok: false, error: message };
  }
}

function install() {
  if (state.phase !== 'downloaded') return false;
  autoUpdater.quitAndInstall(false, true);
  return true;
}

function getState(): UpdateState {
  return { ...state };
}

function stop() {
  if (automaticTimer) clearInterval(automaticTimer);
  automaticTimer = null;
}

module.exports = { check, getState, install, start, stop };
