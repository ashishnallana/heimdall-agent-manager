const { app, BrowserWindow, ipcMain, dialog, nativeImage, Menu, shell, session, Notification } = require('electron');
const fs = require('fs');
const path = require('path');

// Visible product identity (window title + dock/taskbar + macOS app menu).
const APP_DISPLAY_NAME = 'Heimdall';
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
const { trustedIpcSender, allowedExternalUrl, allowedPairingUrl, classifyNavigation, idpOriginFromAuthConfig, isAuthStartUrl, oidcWindowNavigationAllowed } = require('./externalUrl.cjs');
const desktopUpdater = require('./desktopUpdater.cjs');
const { installNotifications } = require('./notifications.cjs');

function normalizeBaseUrl(value: string): string {
  return String(value || '').trim().replace(/\/$/, '');
}

function defaultHubApiBaseUrl(): string {
  return normalizeBaseUrl(
    process.env.HEIMDALL_HUB_API_URL ||
    process.env.HEIMDALL_HUB_URL ||
    // Default to the public Hub API, not the outpost/dev-proxy browser URL.
    (app.isPackaged ? 'https://hub.brolabs.ai' : 'http://127.0.0.1:8081')
  );
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
  return normalizeBaseUrl(process.env.HEIMDALL_UI_URL || (app.isPackaged ? 'https://heimdall.brolabs.ai' : 'http://127.0.0.1:5173'));
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
app.setAppUserModelId?.('works.earendil.heimdall');

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

// app.isPackaged is false when Electron loads a loose .cjs (Nix install, CI).
// Treat as dev only when the Vite dev server URL is explicitly provided.
const isDev = Boolean(process.env.VITE_DEV_SERVER_URL);

let authWindow: any = null;
let mainWindow: any = null;
let isQuitting = false;
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
  authWindow = loginWindow;
  const uiOrigin = new URL(configuredUiOrigin()).origin;
  let finishing = false;
  const finishIfReturned = (_event: any, nextUrl: string) => {
    try {
      const parsed = new URL(nextUrl);
      if (parsed.origin !== uiOrigin || parsed.pathname.startsWith('/api/v1/auth/login') || parsed.pathname.startsWith('/api/v1/auth/callback')) return;
      if (finishing) return;
      finishing = true;
      // Chromium emits redirect/navigation events from inside its navigation
      // stack. Destroying the emitting WebContents synchronously trips a fatal
      // CHECK in Electron on macOS. Complete OIDC on the next event-loop turn,
      // after the callback response has committed its HttpOnly session cookie.
      setImmediate(() => {
        const main = owner && !owner.isDestroyed() ? owner : BrowserWindow.getAllWindows().find((candidate: any) => candidate !== loginWindow);
        if (!loginWindow.isDestroyed()) loginWindow.close();
        if (authWindow === loginWindow) authWindow = null;
        void main?.loadURL(configuredUiOrigin());
      });
    } catch (_err) { /* Keep the OIDC window open for non-URL navigations. */ }
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
  loginWindow.webContents.on('did-redirect-navigation', finishIfReturned);
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
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      preload: path.join(__dirname, 'preload.cjs'),
      additionalArguments: Notification.isSupported() ? ['--heimdall-native-notifications'] : [],
    },
  });
  mainWindow = win;

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

  if (isDev) {
    win.loadURL(process.env.VITE_DEV_SERVER_URL || 'http://127.0.0.1:5173');
  } else {
    // The packaged app is a trusted desktop shell for the Hub web UI. Loading
    // the Hub origin is what lets Chromium retain/send the exact same HttpOnly
    // OIDC session cookie as the browser UI; there is no deprecated HUT token.
    win.loadURL(configuredUiOrigin());
  }

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
  uiUrl: isDev ? process.env.VITE_DEV_SERVER_URL : configuredUiOrigin(),
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
      return { ok: false, error: 'Bridge actions are only available to the Heimdall app window.' };
    }
    try { return await handler(...args); }
    catch (error: any) { return { ok: false, error: String(error?.message || error) }; }
  });
}

function sendBridgeEvent(rawPayload: any) {
  let payload = rawPayload;
  if (payload?.type === 'pairing') {
    // REQ-EXT-URL-1: only open (or show) an approval page on this Hub's origins.
    const url = allowedPairingUrl(payload.url, [configuredHubApiBaseUrl(), configuredUiOrigin()]);
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
function bridgeTarget(raw: any) {
  const service = typeof raw?.service === 'string' ? raw.service : '';
  return {
    hub: typeof raw?.hub === 'string' && raw.hub ? raw.hub : configuredHubApiBaseUrl(),
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
bridgeHandler('heimdall-bridge:set-hub-url', (value: unknown) => ({ ok: true, hubUrl: saveHubApiBaseUrl(String(value || '')) }));
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
  const file = String(logPath || '');
  // Only logs under the per-user Heimdall bridge directories are revealed.
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

app.whenReady().then(() => {
  // macOS dock icon (window `icon` is ignored on macOS; the dock uses this).
  if (process.platform === 'darwin' && appIcon && app.dock) {
    app.dock.setIcon(appIcon);
  }

  // About-panel identity (macOS shows this from the app menu > About).
  app.setName(APP_DISPLAY_NAME);
  app.setAboutPanelOptions?.({ applicationName: APP_DISPLAY_NAME });
  installAppMenu();
  desktopUpdater.start(app.isPackaged && process.platform === 'win32', () => undefined);

  // In dev the renderer runs at the Vite dev-server origin, and Vite's
  // `server.proxy` (see vite.config.js) forwards `/api/v1` to the local Hub.
  // Packaged builds load the HTTPS Hub UI directly; both use its OIDC cookie.
  const daemonUrl = process.env.HEIMDALL_DAEMON_URL || 'http://127.0.0.1:49322';

  console.log('[heimdall] startup config:');
  console.log(`  daemon_url=${daemonUrl}`);
  console.log(`  daemon_url_source=${process.env.HEIMDALL_DAEMON_URL ? 'env' : 'default'}`);
  console.log(`  hub_api_base_url=${configuredHubApiBaseUrl()}`);
  console.log(`  ui_origin=${configuredUiOrigin()}`);
  console.log('  auth=oidc-session-cookie');
  console.log(`  pid=${process.pid}`);
  console.log(`  platform=${process.platform}`);
  console.log(`  electron=${process.versions.electron}`);
  console.log(`  packaged=${app.isPackaged}`);
  console.log(`  dev=${isDev}`);

  createWindow();

  app.on('activate', () => {
    showMainWindow();
  });
});

app.on('before-quit', () => {
  isQuitting = true;
  desktopNotifications.dispose();
  // A running setup/update is cancelled (and rolled back); an installed Bridge
  // service is never stopped by quitting the app.
  bridgeManager.stopOnQuit();
  desktopUpdater.stop();
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
