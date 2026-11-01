const { createDesktopUpdateController } = require('./desktopUpdater.cjs');
const { readEligibility } = require('./desktopUpdatePolicy.cjs');
const { createDesktopUpdateRestart } = require('./desktopUpdateRestart.cjs');
const { createMacUpdateInstall } = require('./macUpdateInstall.cjs');
const { trustedIpcSender } = require('./externalUrl.cjs');

function installDesktopUpdates(deps: any) {
  const { app, ipcMain, dialog } = deps;
  let currentDocument: any = null;
  let preparation: { epoch: number; document: any; resolve: (ready: boolean) => void; timer: any } | null = null;
  const initialEligibility = readEligibility(app);
  // Unsupported installs neither construct the platform updater nor access a feed.
  const updater = initialEligibility.supported ? require('electron-updater').autoUpdater : null;
  const mac = initialEligibility.supported && process.platform === 'darwin'
    ? createMacUpdateInstall(require('electron').autoUpdater) : null;
  function trusted(event: any) {
    const win = deps.getWindow();
    return Boolean(win && !win.isDestroyed() && event.sender === win.webContents
      && trustedIpcSender(event.senderFrame?.url, event.senderFrame === win.webContents.mainFrame, deps.trustedOrigins()));
  }
  function documentIdentity() {
    const win = deps.getWindow();
    return win && !win.isDestroyed() && !win.webContents.isDestroyed() && currentDocument?.contents === win.webContents
      && trustedIpcSender(win.webContents.mainFrame?.url, true, deps.trustedOrigins()) ? currentDocument : null;
  }
  function send(channel: string, payload: any) {
    const document = documentIdentity();
    if (document) document.contents.send(channel, payload);
  }
  let announced = '';
  const controller = createDesktopUpdateController({ updater, eligibility: initialEligibility,
    onState: (state: any) => {
      send('heimdall-updates:state', state);
      if (state.phase === 'downloaded' && state.targetVersion !== announced) {
        announced = state.targetVersion;
        // Non-blocking notice; installation still requires the separate native confirmation.
        const { Notification } = require('electron');
        if (Notification.isSupported()) {
          const notice = new Notification({ title: 'Ninjy update ready', body: 'Restart when ready from App updates or the application menu.' });
          notice.show();
        }
      }
    } });
  function finishPreparation(ready: boolean) {
    if (!preparation) return;
    const pending = preparation;
    preparation = null;
    clearTimeout(pending.timer);
    pending.resolve(ready);
  }
  const restart = createDesktopUpdateRestart({ controller,
    bridgeBusy: deps.bridgeBusy, eligibility: () => readEligibility(app).supported,
    document: documentIdentity,
    prepare: (epoch: number, document: any) => new Promise<boolean>(resolve => {
      const timer = setTimeout(() => finishPreparation(false), 10_000);
      preparation = { epoch, document, resolve, timer };
      try { document.contents.send('heimdall-updates:prepare', { epoch }); }
      catch (_error) { finishPreparation(false); }
    }),
    release: (epoch: number, document: any) => {
      finishPreparation(false);
      if (!document.contents.isDestroyed()) document.contents.send('heimdall-updates:release', { epoch });
    },
    confirm: async () => {
      const answer = await dialog.showMessageBox(deps.getWindow(), { type: 'question',
        title: 'Restart Ninjy to update?', message: 'Your work is saved and editing is paused.',
        detail: 'Ninjy will restart. Bridge services and agents continue independently.',
        buttons: ['Later', 'Restart to update'], defaultId: 0, cancelId: 0, noLink: true });
      return answer.response === 1;
    },
    install: async (gate: () => boolean) => {
      if (mac) { await mac.stage(gate); return; }
      if (process.platform !== 'win32' || !gate()) throw new Error('Restart authorization expired');
      updater.quitAndInstall(false, true);
    },
    cancelInstall: () => mac?.cancel(),
  });
  const channels: string[] = [];
  function handle(channel: string, fn: (payload: any, event: any) => any) {
    channels.push(channel);
    ipcMain.handle(channel, async (event: any, payload: any) => {
      if (!trusted(event)) return { ok: false, error: 'App updates are only available to the trusted Ninjy window.' };
      try { return await fn(payload, event); }
      catch (_error) { return { ok: false, error: 'App update operation failed. Retry or update manually.' }; }
    });
  }
  handle('heimdall-updates:get-state', () => controller.getState());
  handle('heimdall-updates:check', () => controller.check());
  handle('heimdall-updates:retry', () => controller.retry());
  const requestRestart = () => mac?.quarantined()
    ? Promise.resolve({ ok: false, error: 'Native staging already ran. Relaunch Ninjy or use the official manual installer before retrying.' })
    : restart.restart();
  handle('heimdall-updates:restart', requestRestart);
  handle('heimdall-updates:preparation-result', (payload, event) => {
    if (payload?.ready === false && payload.epoch === restart.epoch()) {
      restart.abort('Work changed during restart preparation. Save or discard pending edits and try again.');
      return { ok: true };
    }
    if (preparation && preparation.document === documentIdentity() && event.senderFrame === preparation.document.contents.mainFrame
      && payload?.epoch === preparation.epoch && typeof payload.ready === 'boolean') finishPreparation(payload.ready);
    return { ok: true };
  });
  const nativeError = () => {
    // Once quit was invoked, an error does not prove the pending quit stopped.
    // Keep editing frozen until exit, a known unload veto, or the exit watchdog.
    if (restart.held() && !restart.exiting()) restart.abort('Native update failed. Relaunch Ninjy or update manually.');
  };
  updater?.on('error', nativeError);
  function bindWindow(win: any) {
    const contents = win.webContents;
    const invalidate = () => { currentDocument = null; restart.abort('The app page changed. Open the app and try again.'); finishPreparation(false); };
    contents.on('did-start-navigation', (_event: any, _url: string, _inPlace: boolean, mainFrame: boolean) => { if (mainFrame) invalidate(); });
    contents.on('will-navigate', invalidate);
    contents.on('render-process-gone', invalidate);
    contents.on('destroyed', invalidate);
    contents.on('did-finish-load', () => {
      currentDocument = { contents }; send('heimdall-updates:state', controller.getState());
    });
    contents.on('did-navigate-in-page', (_event: any, _url: string, mainFrame: boolean) => {
      if (mainFrame) { invalidate(); currentDocument = { contents }; send('heimdall-updates:state', controller.getState()); }
    });
    contents.on('will-prevent-unload', () => restart.abort('The page refused to close. Save pending work and try again.'));
    win.on('close', (event: any) => {
      if (restart.held() && !restart.exiting()) { event.preventDefault(); restart.abort('Restart cancelled by closing the window.'); }
    });
  }
  controller.start();
  return {
    bindWindow, operationHeld: restart.held,
    beforeQuit: (event: any) => {
      if (restart.held() && !restart.exiting()) { event.preventDefault(); restart.abort('Restart cancelled.'); return false; }
      return true;
    },
    async showMenu() {
      const state = controller.getState();
      if (state.phase === 'downloaded') {
        const result = await requestRestart();
        if (!result.ok) await dialog.showMessageBox({ type: 'info', title: 'Ninjy app updates', message: result.error, buttons: ['OK'] });
        return;
      }
      void controller.check();
      const snapshot = controller.getState();
      await dialog.showMessageBox({ type: 'info', title: 'Ninjy app updates', message: snapshot.message || snapshot.reason,
        detail: `Installed version: ${snapshot.currentVersion}\nChannel: Stable\nOfficial releases: https://github.com/tanmayv/heimdall-agent-manager/releases`, buttons: ['OK'] });
    },
    stop() { restart.abort('App updates stopped.'); finishPreparation(false); controller.stop(); updater?.removeListener('error', nativeError); for (const channel of channels) ipcMain.removeHandler(channel); },
  };
}

module.exports = { installDesktopUpdates };
