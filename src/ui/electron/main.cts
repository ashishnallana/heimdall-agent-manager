const { app, BrowserWindow, ipcMain, dialog, nativeImage, Menu, shell, session, Notification } = require('electron');
const fs = require('fs');
const path = require('path');

// Visible product identity (window title + dock/taskbar + macOS app menu).
const APP_DISPLAY_NAME = 'Ninjy';
const APP_ICON_PATH = path.join(__dirname, 'icon.png');
const appIcon = (() => {
  try {
    const img = nativeImage.createFromPath(APP_ICON_PATH);
    return img.isEmpty() ? undefined : img;
  } catch (_err) {
    return undefined;
  }
})();
const bridgeManager = require('./bridgeManager.cjs');
const { trustedIpcSender, allowedExternalUrl, desktopPairingOrigins, allowedPairingUrl, classifyNavigation, idpOriginFromAuthConfig, isAuthStartUrl, oidcWindowNavigationAllowed } = require('./externalUrl.cjs');
const desktopUpdater = require('./desktopUpdater.cjs');
const installChoice = require('./installChoice.cjs');
const { installNotifications } = require('./notifications.cjs');
const windowChrome = require('./windowChrome.cjs');
const windowsIdentity = require('./windowsIdentity.cjs');

const { resolveDesktopConfig, desktopAuthReturnUrl } = require('./desktopConfig.cjs');
const desktopConfig = resolveDesktopConfig(process.env, app.isPackaged);

// The environment/packaged default (desktopConfig: HEIMDALL_HUB_API_URL, else
// the public Hub API); a Hub URL saved in Settings > Bridges overrides it.
function defaultHubApiBaseUrl(): string {
  return desktopConfig.hubApiBaseUrl;
}

// F28: self-hosters point the Bridge at their own Hub. The choice is stored
// with the app's settings; the environment/default applies until one is saved.
function bridgeSettingsPath(): string {
  return path.join(app.getPath('userData'), 'bridge-settings.json');
}

function configuredHubApiBaseUrl(): string {
  try {
    const saved = bridgeManager.normalizeHubUrl(JSON.parse(fs.readFileSync(bridgeSettingsPath(), 'utf8'))?.hubUrl || '');
    if (saved) return saved;
  } catch (_err) { /* No saved Hub URL. */ }
  return defaultHubApiBaseUrl();
}

function saveHubApiBaseUrl(value: string): string {
  const hubUrl = value ? bridgeManager.normalizeHubUrl(value) : '';
  if (value && !hubUrl) throw new Error('Enter an http(s) Hub URL, e.g. https://hub.example.com.');
  fs.mkdirSync(path.dirname(bridgeSettingsPath()), { recursive: true });
  fs.writeFileSync(bridgeSettingsPath(), `${JSON.stringify({ hubUrl }, null, 2)}\n`, { mode: 0o600 });
  return configuredHubApiBaseUrl();
}

function configuredUiOrigin(): string {
  return desktopConfig.uiUrl;
}

// Bypass Nix sandbox GPU library mismatches on Linux to enable full hardware-accelerated rendering.
if (process.platform === 'linux') {
  app.commandLine.appendSwitch('disable-gpu-sandbox');
}
// Display name drives the macOS app menu label, dock/taskbar, and About panel.
// In UNPACKAGED mode (Nix/dev) macOS otherwise shows "Electron"; setting the name
// AND installing a custom app menu whose first submenu is the app name (below) is
// what actually renames the menu-bar entry.
process.title = APP_DISPLAY_NAME;
app.setName(APP_DISPLAY_NAME);
app.setAppUserModelId?.(windowsIdentity.APP_ID);

// Keep Electron state namespaced under "heimdall-ui" (so it doesn't collide with
// the ham daemon/wrapper config dir at <appData>/heimdall/, and so existing
// stored daemon profiles/tokens are preserved) even though the app is now named
// "Heimdall". We pin userData explicitly instead of relying on the app name.
// Must run before app.whenReady() and any path lookup.
try {
  const appDataDir = app.getPath('appData');
  app.setPath('userData', path.join(appDataDir, 'heimdall-ui'));
} catch (_err) {
  // Non-fatal: fall back to the default (name-derived) userData path.
}

// One app process per profile (the lock is taken on userData, so after the pin
// above). Without it a second copy (the installer's finish-page "Run" plus a
// manual launch, or a relaunch while the old process is still exiting) shares
// the Chromium profile, and IndexedDB then fails with "Internal error opening
// backing store for indexedDB.open" (the vault check). The second copy exits
// before anything starts and the running one comes to the front.
if (!app.requestSingleInstanceLock()) {
  app.exit(0);
}
app.on('second-instance', () => {
  if (mainWindow && !mainWindow.isDestroyed()) showMainWindow();
});

// app.isPackaged is false when Electron loads a loose .cjs (Nix install, CI).
// Treat as dev only when the Vite dev server URL is explicitly provided.
const isDev = desktopConfig.isDev;

let authWindow: any = null;
let mainWindow: any = null;
// Identity provider origin from GET /api/v1/auth/config, used to route sign-out.
let idpOrigin = '';

function openOidcWindow(url: string, owner: any) {
  // REQ-OIDC-DESKTOP-1: OIDC runs in a preload-free window which shares the
  // default Electron cookie jar. Once the Hub callback has set its HttpOnly
  // session cookie, the trusted main window reloads the same-origin Hub UI.
  if (authWindow && !authWindow.isDestroyed()) { authWindow.focus(); return; }
  const loginWindow = new BrowserWindow({
    width: 620,
    height: 760,
    parent: owner || undefined,
    modal: Boolean(owner),
    title: `Sign in to ${APP_DISPLAY_NAME}`,
    webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true },
  });
  // REQ-WIN-COMPACT-2: retain native caption, without a second application-menu row.
  if (process.platform === 'win32') loginWindow.removeMenu();
  authWindow = loginWindow;
  let finishing = false;
  const finishIfReturned = (_event: any, nextUrl: string) => {
    const returnUrl = desktopAuthReturnUrl(nextUrl, configuredUiOrigin());
    if (!returnUrl) return;
    if (finishing) return;
    finishing = true;
    // did-navigate reports a committed UI response, after the callback's cookie
    // was accepted. Defer closing outside Chromium's navigation stack (macOS).
    setImmediate(() => {
      // A cancelled/replaced popup must not reload an unrelated window.
      if (authWindow !== loginWindow || loginWindow.isDestroyed()) return;
      const main = owner && !owner.isDestroyed() ? owner : null;
      loginWindow.close();
      if (authWindow === loginWindow) authWindow = null;
      if (main && !main.isDestroyed()) {
        void main.loadURL(returnUrl);
        main.show();
        main.focus();
      }
    });
  };
  // REQ-NAV-ROUTE-2: the OIDC window has no preload, but still must not open
  // popups or leave https: (other than returning to the Hub UI).
  loginWindow.webContents.setWindowOpenHandler(({ url: popupUrl }: { url: string }) => {
    const href = allowedExternalUrl(popupUrl);
    if (href) void shell.openExternal(href);
    return { action: 'deny' };
  });
  const guardOidcNavigation = (event: any, nextUrl: string) => {
    if (!oidcWindowNavigationAllowed(nextUrl, configuredUiOrigin())) event.preventDefault();
  };
  loginWindow.webContents.on('will-navigate', guardOidcNavigation);
  loginWindow.webContents.on('will-redirect', guardOidcNavigation);
  loginWindow.webContents.on('did-navigate', finishIfReturned);
  // Redirect events occur before the final response commits; never finish there.
  loginWindow.on('closed', () => { if (authWindow === loginWindow) authWindow = null; });
  void loginWindow.loadURL(url);
}

function createWindow() {
  const win = new BrowserWindow({
    width: 1200,
    height: 760,
    minWidth: 920,
    minHeight: 620,
    title: APP_DISPLAY_NAME,
    icon: appIcon,
    backgroundColor: '#0f172a',
    // REQ-MAC-CHROME-1: macOS-only hidden title bar; {} elsewhere.
    ...windowChrome.windowChromeOptions(process.platform, process.env),
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      preload: path.join(__dirname, 'preload.cjs'),
      additionalArguments: [
        ...(Notification.isSupported() ? ['--heimdall-native-notifications'] : []),
        ...windowChrome.windowChromeArgs(process.platform, process.env),
      ],
    },
  });
  mainWindow = win;
  if (process.platform === 'win32') win.removeMenu();
  const taskbarDetails = windowsIdentity.taskbarDetails(
    process.platform, app.isPackaged, process.execPath,
    path.resolve(process.argv[1] || app.getAppPath()), path.join(__dirname, 'icon.ico'),
  );
  if (taskbarDetails) win.setAppDetails(taskbarDetails);

  // The renderer drops its traffic-light inset in fullscreen, where macOS
  // hides the buttons. Display-only state; the renderer cannot send anything.
  const sendChromeState = () => {
    if (win.isDestroyed()) return;
    win.webContents.send(windowChrome.CHROME_STATE_CHANNEL, { fullscreen: win.isFullScreen() });
  };
  win.on('enter-full-screen', sendChromeState);
  win.on('leave-full-screen', sendChromeState);
  win.webContents.on('did-finish-load', sendChromeState);

  // REQ-ENR-6: the system tray belongs to the Bridge (`ham-bridge tray`), not
  // to this app. Closing the window closes it; the Bridge service is
  // independent of the app's lifetime and keeps running.
  win.on('closed', () => { if (mainWindow === win) mainWindow = null; });

  const forceWindowTitle = () => {
    win.setTitle(APP_DISPLAY_NAME);
    win.webContents.executeJavaScript(`document.title = ${JSON.stringify(APP_DISPLAY_NAME)}`, true).catch(() => undefined);
  };

  // The renderer's <title> would otherwise override our window title once the
  // page loads; force it back to the product name.
  win.setTitle(APP_DISPLAY_NAME);
  win.on('page-title-updated', (event: any) => {
    event.preventDefault();
    forceWindowTitle();
  });
  win.once('ready-to-show', forceWindowTitle);
  win.webContents.on('did-finish-load', forceWindowTitle);

  if (!isDev) {
    // REQ-NAV-ROUTE-1: only sign-in/sign-out reaches the OIDC window. Any other
    // off-origin page (Paddle checkout, a clicked link) opens in the system
    // browser, and the main window stays on the Hub UI.
    let inAuthRedirect = false;
    win.webContents.on('did-start-navigation', (details: any, legacyUrl?: string, _inPlace?: boolean, legacyIsMainFrame?: boolean) => {
      const url = typeof details === 'object' && details ? details.url : legacyUrl;
      const isMainFrame = typeof details === 'object' && details ? details.isMainFrame : legacyIsMainFrame;
      if (isMainFrame) inAuthRedirect = isAuthStartUrl(url, configuredUiOrigin());
    });
    const guardNavigation = (event: any, url: string) => {
      // A Hub page may itself redirect to /api/v1/auth/login before the provider.
      if (isAuthStartUrl(url, configuredUiOrigin())) inAuthRedirect = true;
      const route = classifyNavigation(url, { uiOrigin: configuredUiOrigin(), idpOrigin, inAuthRedirect });
      if (route === 'allow') return;
      event.preventDefault();
      if (route === 'auth') openOidcWindow(url, win);
      else if (route === 'external') void shell.openExternal(allowedExternalUrl(url));
    };
    // `will-redirect` is load-bearing: /auth/login reaches the identity
    // provider through an HTTP 302, which is not a user-initiated navigation.
    win.webContents.on('will-navigate', (event: any, url: string) => {
      // A fresh navigation is never part of an earlier sign-in redirect chain.
      inAuthRedirect = false;
      guardNavigation(event, url);
    });
    win.webContents.on('will-redirect', guardNavigation);
    win.webContents.on('did-finish-load', () => { void refreshIdpOrigin(); });
    win.webContents.setWindowOpenHandler(({ url }: { url: string }) => {
      const href = allowedExternalUrl(url);
      if (href) void shell.openExternal(href);
      return { action: 'deny' };
    });
  }

  // Hosted or Vite UI: all navigation, cookies and completion use the same URL.
  win.loadURL(configuredUiOrigin());

  return win;
}

function showMainWindow() {
  const win = mainWindow && !mainWindow.isDestroyed() ? mainWindow : createWindow();
  app.dock?.show();
  if (win.isMinimized()) win.restore();
  win.show();
  win.focus();
  return win;
}

const desktopNotifications = installNotifications({
  ipcMain, Notification, icon: appIcon,
  getWindow: () => mainWindow,
  showWindow: showMainWindow,
  uiUrl: configuredUiOrigin(),
});

ipcMain.handle('odin-api:pick-directory', async (event) => {
  const owner = BrowserWindow.fromWebContents(event.sender);
  const result = await dialog.showOpenDialog(owner || undefined, {
    title: 'Select project anchor directory',
    properties: ['openDirectory'],
  });
  if (result.canceled || !result.filePaths.length) return { ok: true, canceled: true, path: '' };
  return { ok: true, canceled: false, path: result.filePaths[0] };
});

ipcMain.handle('heimdall-api:open-external', async (_event, url: string) => {
  const href = allowedExternalUrl(url);
  if (!href) return { ok: false, error: 'Only https: and mailto: links can be opened.' };
  await shell.openExternal(href);
  return { ok: true };
});

async function refreshIdpOrigin() {
  try {
    const response = await session.defaultSession.fetch(`${configuredUiOrigin()}/api/v1/auth/config`);
    if (!response.ok) return;
    const next = idpOriginFromAuthConfig(await response.json());
    if (next) idpOrigin = next;
  } catch (_err) { /* Sign-in still routes through the /api/v1/auth/login redirect chain. */ }
}

// ---------------------------------------------------------------------------
// Settings > Bridges (REQ-ENR-9/10). Every handler first checks that the call
// comes from the main window's own document on the trusted UI origin (F25).
// ---------------------------------------------------------------------------

function trustedUiOrigins(): string[] {
  return isDev ? [process.env.VITE_DEV_SERVER_URL || 'http://127.0.0.1:5173'] : [configuredUiOrigin()];
}

function bridgeHandler(channel: string, handler: (...args: any[]) => any) {
  ipcMain.handle(channel, async (event: any, ...args: any[]) => {
    const frame = event.senderFrame;
    const fromMainWindow = Boolean(mainWindow && !mainWindow.isDestroyed() && event.sender === mainWindow.webContents);
    if (!fromMainWindow || !trustedIpcSender(frame?.url, frame ? frame === event.sender.mainFrame : false, trustedUiOrigins())) {
      console.warn(`[heimdall] refused ${channel} from ${String(frame?.url || 'an unknown frame')}`);
      return { ok: false, error: 'Bridge actions are only available to the Ninjy app window.' };
    }
    try { return await handler(...args); }
    catch (error: any) { return { ok: false, error: String(error?.message || error) }; }
  });
}

function sendBridgeEvent(rawPayload: any) {
  let payload = rawPayload;
  if (payload?.type === 'pairing') {
    // REQ-EXT-URL-1: only open (or show) an approval page on this Hub's origins.
    const url = allowedPairingUrl(payload.url, desktopPairingOrigins(configuredHubApiBaseUrl(), configuredUiOrigin()));
    payload = url && payload.code
      ? { ...payload, url }
      : { type: 'output', message: 'Bridge enrollment printed an approval page outside this Hub; it was not opened.' };
    if (payload.type === 'pairing') void shell.openExternal(payload.url);
  }
  if (mainWindow && !mainWindow.isDestroyed() && !mainWindow.webContents.isDestroyed()) {
    mainWindow.webContents.send('heimdall-bridge:event', payload);
  }
}

// The renderer's target: the local profile for the configured Hub, with an
// optional profile name, or another installed profile by its service name.
// The Hub is always the configured one: the window shows a remote origin, so a
// script injected there must not be able to enroll this machine elsewhere.
function bridgeTarget(raw: any) {
  const service = typeof raw?.service === 'string' ? raw.service : '';
  return {
    hub: configuredHubApiBaseUrl(),
    profile: typeof raw?.profile === 'string' ? raw.profile : '',
    ...(service ? { service } : {}),
  };
}

bridgeHandler('heimdall-bridge:get-config', () => ({
  ok: true,
  supported: bridgeManager.supportedPlatform(),
  platform: process.platform,
  hubUrl: configuredHubApiBaseUrl(),
  defaultHubUrl: defaultHubApiBaseUrl(),
  bundledVersion: bridgeManager.bundledVersion(),
}));
// Changing the Hub is confirmed natively (outside the renderer) for the same reason.
bridgeHandler('heimdall-bridge:set-hub-url', async (value: unknown) => {
  const requested = String(value || '');
  const next = requested ? bridgeManager.normalizeHubUrl(requested) : defaultHubApiBaseUrl();
  if (next && next !== configuredHubApiBaseUrl() && mainWindow && !mainWindow.isDestroyed()) {
    const answer = await dialog.showMessageBox(mainWindow, {
      type: 'question',
      message: `Point the Bridge on this machine at ${next}?`,
      detail: 'Set up and re-enroll will register this machine with that Hub.',
      buttons: ['Change Hub', 'Cancel'],
      defaultId: 1,
      cancelId: 1,
    });
    if (answer.response !== 0) return { ok: false, error: 'Hub change cancelled.' };
  }
  return { ok: true, hubUrl: saveHubApiBaseUrl(requested) };
});
bridgeHandler('heimdall-bridge:get-status', (target: unknown) => bridgeManager.getStatus(bridgeTarget(target)));
bridgeHandler('heimdall-bridge:list', async () => ({ ok: true, profiles: await bridgeManager.listProfiles() }));
bridgeHandler('heimdall-bridge:run', (kind: unknown, target: unknown, options: any) => {
  const operation = String(kind || '');
  if (!['setup', 'update', 'reenroll', 'uninstall'].includes(operation)) return { ok: false, error: `Unknown Bridge operation ${operation}.` };
  const clean = {
    bridgeId: typeof options?.bridgeId === 'string' ? options.bridgeId : '',
    purge: options?.purge === true,
    replaceOtherAccount: options?.replaceOtherAccount === true,
  };
  return bridgeManager.runOperation(operation, bridgeTarget(target), sendBridgeEvent, clean);
});
bridgeHandler('heimdall-bridge:cancel', () => ({ ok: bridgeManager.cancelOperation() }));
bridgeHandler('heimdall-bridge:open-log', (logPath: unknown) => {
  const file = path.resolve(String(logPath || ''));
  // Only logs under the per-user Heimdall bridge directories are revealed
  // (resolved first, so '..' cannot climb out of them).
  if (!/[\\/]heimdall[\\/]bridges[\\/]/.test(file) || !fs.existsSync(file)) return { ok: false, error: 'Log not found.' };
  shell.showItemInFolder(file);
  return { ok: true };
});


// Build an application menu whose FIRST submenu is titled with the app name.
// On macOS this is the entry next to the Apple logo; without a custom menu an
// unpackaged Electron app shows "Electron" there regardless of app.setName().
function installAppMenu() {
  const isMac = process.platform === 'darwin';
  const template: any[] = [];
  if (isMac) {
    template.push({
      label: APP_DISPLAY_NAME,
      submenu: [
        { role: 'about', label: `About ${APP_DISPLAY_NAME}` },
        { type: 'separator' },
        { role: 'hide', label: `Hide ${APP_DISPLAY_NAME}` },
        { role: 'hideOthers' },
        { role: 'unhide' },
        { type: 'separator' },
        { role: 'quit', label: `Quit ${APP_DISPLAY_NAME}` },
      ],
    });
  }
  template.push(
    { role: 'editMenu' },
    { role: 'viewMenu' },
    { role: 'windowMenu' },
  );
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

app.whenReady().then(async () => {
  // macOS dock icon (window `icon` is ignored on macOS; the dock uses this).
  if (process.platform === 'darwin' && appIcon && app.dock) {
    app.dock.setIcon(appIcon);
  }

  // About-panel identity (macOS shows this from the app menu > About).
  app.setName(APP_DISPLAY_NAME);
  app.setAboutPanelOptions?.({ applicationName: APP_DISPLAY_NAME });
  installAppMenu();
  desktopUpdater.start(desktopUpdater.supported(process.platform, app.isPackaged), () => undefined);

  // In dev the renderer runs at the Vite dev-server origin, and Vite's
  // `server.proxy` (see vite.config.js) forwards `/api/v1` to the local Hub.
  // Packaged builds load the HTTPS Hub UI directly; both use its OIDC cookie.
  const daemonUrl = process.env.HEIMDALL_DAEMON_URL || 'http://127.0.0.1:49322';

  console.log('[heimdall] startup config:');
  console.log(`  daemon_url=${daemonUrl}`);
  console.log(`  daemon_url_source=${process.env.HEIMDALL_DAEMON_URL ? 'env' : 'default'}`);
  console.log(`  hub_api_base_url=${configuredHubApiBaseUrl()}`);
  console.log(`  ui_origin=${configuredUiOrigin()}`);
  if (desktopConfig.migratedLegacyUi) {
    console.warn('[heimdall] Brolabs desktop UI moved to https://web.ninjy.ai. Existing profile/storage is retained; canonical-origin device approval may be required.');
  }
  console.log('  auth=oidc-session-cookie');
  console.log(`  pid=${process.pid}`);
  console.log(`  platform=${process.platform}`);
  console.log(`  electron=${process.versions.electron}`);
  console.log(`  packaged=${app.isPackaged}`);
  console.log(`  dev=${isDev}`);

  // REQ-ENR-4 (Linux): App / Bridge / both on the first packaged launch.
  const installChoiceMarker = path.join(app.getPath('userData'), 'install-choice.json');
  if (installChoice.shouldAsk(process.platform, app.isPackaged, installChoiceMarker)) {
    const { openWindow } = await installChoice.runFirstLaunch({
      markerPath: installChoiceMarker,
      showMessageBox: (options: any) => dialog.showMessageBox(options),
      setupBridge: () => bridgeManager.runOperation('setup', bridgeTarget({}), sendBridgeEvent, {}),
      packageKind: installChoice.packageKind(),
    });
    if (!openWindow) { app.quit(); return; }
  }

  createWindow();

  app.on('activate', () => {
    showMainWindow();
  });
});

// '' → no hold yet; 'waiting' → the quit is held for a Bridge operation;
// 'released' → the wait is over (settled or timed out), so quit proceeds.
let bridgeQuitHold: '' | 'waiting' | 'released' = '';

app.on('before-quit', (event: any) => {
  // A running Bridge operation is cancelled, and the quit is held (bounded by
  // TIMEOUTS.quit) until it settles, so a cancelled first install is rolled
  // back before the app exits. An installed Bridge service is never stopped by
  // quitting the app.
  if (bridgeQuitHold !== 'released' && bridgeManager.operationRunning()) {
    event.preventDefault();
    if (bridgeQuitHold === 'waiting') return;
    bridgeQuitHold = 'waiting';
    void bridgeManager.stopOnQuit().finally(() => { bridgeQuitHold = 'released'; app.quit(); });
    return;
  }
  desktopNotifications.dispose();
  desktopUpdater.stop();
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
