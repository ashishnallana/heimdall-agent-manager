const { app, BrowserWindow, ipcMain, dialog, nativeImage, Menu, shell, Tray, clipboard, session } = require('electron');
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
const { allowedExternalUrl, allowedPairingUrl, classifyNavigation, idpOriginFromAuthConfig, isAuthStartUrl, oidcWindowNavigationAllowed } = require('./externalUrl.cjs');

function normalizeBaseUrl(value: string): string {
  return String(value || '').trim().replace(/\/$/, '');
}

function configuredHubApiBaseUrl(): string {
  return normalizeBaseUrl(
    process.env.HEIMDALL_HUB_API_URL ||
    process.env.HEIMDALL_HUB_URL ||
    // Default to the public Hub API, not the outpost/dev-proxy browser URL.
    (app.isPackaged ? 'https://hub.brolabs.ai' : 'http://127.0.0.1:8081')
  );
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
let statusTray: any = null;
let trayRefreshTimer: NodeJS.Timeout | null = null;
let userRefreshTimer: NodeJS.Timeout | null = null;
let isQuitting = false;
let authenticatedUserLabel = '';
let trayOperationMessage = '';
let trayPairing: { code: string; url: string } | null = null;
// Identity provider origin from GET /api/v1/auth/config, used to route sign-out.
let idpOrigin = '';
const LOGIN_ITEM_PREFERENCE_MARKER = 'login-item-preference-configured';

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
    },
  });
  mainWindow = win;

  // REQ-MAC-TRAY-1: closing the visible UI leaves the lightweight tray
  // controller running. The independently managed Bridge LaunchAgent is not
  // coupled to either window or tray lifetime.
  win.on('close', (event: any) => {
    if (process.platform !== 'darwin' || isQuitting) return;
    event.preventDefault();
    win.hide();
    app.dock?.hide();
  });
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
}

function trayStatus(status: any): { label: string; symbol: string } {
  if (status?.busy) return { label: 'Bridge configuring…', symbol: '…' };
  if (!status?.installed) return { label: 'Bridge not installed', symbol: '–' };
  if (!status?.enrolled) return { label: 'Bridge enrollment required', symbol: '!' };
  if (status.serviceState === 'running') return { label: 'Bridge online', symbol: '●' };
  return { label: 'Bridge offline', symbol: '○' };
}

function loginItemEnabled(): boolean {
  try { return Boolean(app.getLoginItemSettings().openAtLogin); }
  catch (_err) { return false; }
}

function wasOpenedAtLogin(): boolean {
  if (process.platform !== 'darwin') return false;
  try {
    const settings = app.getLoginItemSettings();
    return Boolean(settings.wasOpenedAtLogin || settings.wasOpenedAsHidden);
  } catch (_err) { return false; }
}

function setLaunchAtLogin(enabled: boolean) {
  if (process.platform !== 'darwin' || !app.isPackaged) return;
  try {
    app.setLoginItemSettings({
      openAtLogin: enabled,
      // Supports the intended behavior on macOS 12 and earlier. On macOS 13+
      // Electron reports `wasOpenedAtLogin`, which we use below to suppress the
      // initial window regardless of this deprecated OS hint.
      openAsHidden: true,
    });
    const settings = app.getLoginItemSettings();
    const requestWasRecorded = !enabled || settings.openAtLogin || settings.status === 'enabled' || settings.status === 'requires-approval';
    if (requestWasRecorded) {
      const marker = path.join(app.getPath('userData'), LOGIN_ITEM_PREFERENCE_MARKER);
      fs.mkdirSync(path.dirname(marker), { recursive: true });
      fs.writeFileSync(marker, '1\n');
    }
  }
  catch (error) { console.warn('[heimdall] unable to change login-item setting:', error); }
}

function ensureDefaultLaunchAtLogin() {
  if (process.platform !== 'darwin' || !app.isPackaged) return;
  const marker = path.join(app.getPath('userData'), LOGIN_ITEM_PREFERENCE_MARKER);
  if (!fs.existsSync(marker)) setLaunchAtLogin(true);
}

function updateAuthenticatedUser(identity: any) {
  const clean = (value: any) => String(value || '').replace(/[\r\n\t]+/g, ' ').trim().slice(0, 160);
  authenticatedUserLabel = identity && typeof identity === 'object'
    ? clean(identity.display_name || identity.name || identity.email || identity.user_id)
    : '';
  refreshTrayStatus();
}

async function refreshIdpOrigin() {
  try {
    const response = await session.defaultSession.fetch(`${configuredUiOrigin()}/api/v1/auth/config`);
    if (!response.ok) return;
    const next = idpOriginFromAuthConfig(await response.json());
    if (next) idpOrigin = next;
  } catch (_err) { /* Sign-in still routes through the /api/v1/auth/login redirect chain. */ }
}

async function refreshAuthenticatedUserFromSession() {
  try {
    const response = await session.defaultSession.fetch(`${configuredUiOrigin()}/api/v1/me`, { credentials: 'include' });
    if (response.status === 401 || response.status === 403) { updateAuthenticatedUser(null); return; }
    if (!response.ok) return;
    const body = await response.json();
    updateAuthenticatedUser(body?.data || null);
  } catch (_err) { /* The renderer will synchronize identity after a successful OIDC check. */ }
}

function handleEnrollmentEvent(rawPayload: any) {
  // REQ-EXT-URL-1: only open (or show) an approval page on this Hub's origins.
  let payload = rawPayload;
  if (payload?.type === 'pairing') {
    const url = allowedPairingUrl(payload.url, [configuredHubApiBaseUrl(), configuredUiOrigin()]);
    payload = url && payload.code
      ? { ...payload, url }
      : { type: 'error', message: 'Bridge enrollment printed an approval page outside this Hub; it was not opened.' };
  }
  if (mainWindow && !mainWindow.isDestroyed() && !mainWindow.webContents.isDestroyed()) {
    mainWindow.webContents.send('heimdall-bridge:enrollment-event', payload);
  }
  if (payload?.type === 'pairing') {
    trayPairing = { url: String(payload.url), code: String(payload.code) };
    trayOperationMessage = 'Waiting for browser approval…';
    void shell.openExternal(trayPairing.url);
  } else if (payload?.type === 'complete') {
    trayPairing = null;
    trayOperationMessage = payload?.message || 'Bridge enrollment complete.';
  } else if (payload?.type === 'error') {
    trayPairing = null;
    trayOperationMessage = payload?.message || 'Bridge enrollment failed.';
  }
  if (payload?.type === 'complete' || payload?.type === 'error') void refreshBridgeStatus();
  else refreshTrayStatus();
}

async function restartBridgeFromTray() {
  trayOperationMessage = 'Restarting Bridge…';
  refreshTrayStatus();
  const result = await bridgeManager.restart(configuredHubApiBaseUrl());
  trayOperationMessage = result?.ok ? 'Bridge restarted.' : String(result?.error || 'Bridge restart failed.');
  refreshTrayStatus();
  if (!result?.ok) dialog.showErrorBox('Unable to restart Bridge', trayOperationMessage);
}

async function installBridgeFromTray() {
  trayOperationMessage = 'Installing packaged Bridge…';
  refreshTrayStatus();
  const result = await bridgeManager.installBundled(configuredHubApiBaseUrl());
  if (result?.ok) {
    trayOperationMessage = result?.status?.enrolled ? 'Bridge installed and running.' : 'Bridge installed. Enrollment required.';
  } else {
    trayOperationMessage = String(result?.error || 'Bridge installation failed.');
    dialog.showErrorBox('Unable to install Bridge', trayOperationMessage);
  }
  refreshTrayStatus();
}

async function enrollBridgeFromTray(reEnrollment: boolean) {
  if (reEnrollment) {
    const options = {
      type: 'warning',
      title: 'Re-enroll Bridge',
      message: 'Re-enroll this Bridge?',
      detail: 'The Bridge will disconnect until you approve the new browser pairing request. Its existing Bridge identity and history will be reused.',
      buttons: ['Cancel', 'Re-enroll Bridge'],
      defaultId: 0,
      cancelId: 0,
      noLink: true,
    };
    const answer = mainWindow && !mainWindow.isDestroyed()
      ? await dialog.showMessageBox(mainWindow, options)
      : await dialog.showMessageBox(options);
    if (answer.response !== 1) return;
  }
  trayPairing = null;
  trayOperationMessage = reEnrollment ? 'Starting Bridge re-enrollment…' : 'Starting Bridge enrollment…';
  refreshTrayStatus();
  const result = reEnrollment
    ? bridgeManager.startReEnrollment(configuredHubApiBaseUrl(), handleEnrollmentEvent)
    : bridgeManager.startEnrollment(configuredHubApiBaseUrl(), handleEnrollmentEvent);
  if (!result?.ok) {
    trayOperationMessage = String(result?.error || 'Unable to start Bridge enrollment.');
    refreshTrayStatus();
    dialog.showErrorBox('Unable to enroll Bridge', trayOperationMessage);
  }
}

// REQ-BRIDGE-STATUS-ASYNC-1: the single poller. It probes launchd and the
// Bridge binary asynchronously; the tray menu and the renderer read the cache.
async function refreshBridgeStatus() {
  try { await bridgeManager.refreshStatus(configuredHubApiBaseUrl()); }
  catch (error) { console.warn('[heimdall] unable to refresh Bridge status:', error); }
  refreshTrayStatus();
}

function refreshTrayStatus() {
  if (!statusTray || statusTray.isDestroyed()) return;
  let status: any;
  try { status = bridgeManager.getStatus(configuredHubApiBaseUrl()); }
  catch (_err) {
    status = { installed: false, enrolled: false, serviceState: 'not-installed', hubUrl: configuredHubApiBaseUrl() };
  }
  const presentation = trayStatus(status);
  const version = String(status.installedVersion || status.bundledVersion || '').replace(/^v/, '');
  statusTray.setTitle(` ${presentation.symbol}`);
  statusTray.setToolTip(`${APP_DISPLAY_NAME} — ${presentation.label}${version ? ` (Bridge v${version})` : ''}`);
  statusTray.setContextMenu(Menu.buildFromTemplate([
    { label: presentation.label, enabled: false },
    ...(version ? [{ label: `Bridge v${version}`, enabled: false }] : []),
    { label: String(status.hubUrl || configuredHubApiBaseUrl()), enabled: false },
    ...(authenticatedUserLabel ? [{ label: `Signed in as ${authenticatedUserLabel}`, enabled: false }] : []),
    ...(trayOperationMessage ? [{ label: trayOperationMessage, enabled: false }] : []),
    ...(trayPairing ? [
      { label: `Pairing code: ${trayPairing.code}`, enabled: false },
      { label: 'Copy Pairing Code', click: () => clipboard.writeText(trayPairing?.code || '') },
      { label: 'Open Approval Page', click: () => { if (trayPairing?.url) void shell.openExternal(trayPairing.url); } },
    ] : []),
    { type: 'separator' },
    { label: `Open ${APP_DISPLAY_NAME}`, click: showMainWindow },
    { label: 'Check for Bridge Updates…', click: openBridgeUpdates },
    { label: 'Refresh Bridge Status', click: () => { void refreshBridgeStatus(); } },
    ...(!status.installed ? [{
      label: 'Install Packaged Bridge',
      enabled: Boolean(status.packaged && !status.busy),
      click: () => { void installBridgeFromTray(); },
    }] : [
      { label: 'Restart Bridge', enabled: !status.busy, click: () => { void restartBridgeFromTray(); } },
      {
        label: status.canReEnroll ? 'Re-enroll Bridge…' : 'Enroll Bridge…',
        enabled: !status.busy,
        click: () => { void enrollBridgeFromTray(Boolean(status.canReEnroll)); },
      },
    ]),
    { type: 'separator' },
    {
      label: 'Launch at Login',
      type: 'checkbox',
      checked: loginItemEnabled(),
      click: (item: any) => setLaunchAtLogin(Boolean(item.checked)),
    },
    { type: 'separator' },
    { label: `Quit ${APP_DISPLAY_NAME}`, click: () => { isQuitting = true; app.quit(); } },
  ]));
}

function openBridgeUpdates() {
  const win = mainWindow && !mainWindow.isDestroyed() ? mainWindow : createWindow();
  showMainWindow();
  const send = () => { if (!win.webContents.isDestroyed()) win.webContents.send('heimdall-bridge:check-updates'); };
  if (win.webContents.isLoadingMainFrame()) win.webContents.once('did-finish-load', send);
  else send();
}

function installStatusTray() {
  if (process.platform !== 'darwin' || statusTray) return;
  const trayIcon = appIcon?.resize({ width: 18, height: 18 });
  trayIcon?.setTemplateImage(true);
  statusTray = new Tray(trayIcon || nativeImage.createEmpty());
  void refreshBridgeStatus();
  trayRefreshTimer = setInterval(() => { void refreshBridgeStatus(); }, 15_000);
  void refreshAuthenticatedUserFromSession();
  userRefreshTimer = setInterval(() => { void refreshAuthenticatedUserFromSession(); }, 300_000);
}

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

ipcMain.on('heimdall-auth:set-user', (event, identity) => {
  if (!mainWindow || mainWindow.isDestroyed() || event.sender !== mainWindow.webContents) return;
  updateAuthenticatedUser(identity);
});

ipcMain.handle('heimdall-bridge:get-status', () => bridgeManager.getStatus(configuredHubApiBaseUrl()));
ipcMain.handle('heimdall-bridge:install-bundled', async () => {
  const result = await bridgeManager.installBundled(configuredHubApiBaseUrl());
  refreshTrayStatus();
  return result;
});
ipcMain.handle('heimdall-bridge:start-enrollment', () => bridgeManager.startEnrollment(configuredHubApiBaseUrl(), handleEnrollmentEvent));
ipcMain.handle('heimdall-bridge:start-re-enrollment', () => bridgeManager.startReEnrollment(configuredHubApiBaseUrl(), handleEnrollmentEvent));


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
  ensureDefaultLaunchAtLogin();
  installStatusTray();

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

  const backgroundLaunch = wasOpenedAtLogin();
  if (!backgroundLaunch) createWindow();
  else app.dock?.hide();

  app.on('activate', () => {
    showMainWindow();
  });
});

app.on('before-quit', () => {
  isQuitting = true;
  bridgeManager.stopEnrollment();
  if (trayRefreshTimer) clearInterval(trayRefreshTimer);
  trayRefreshTimer = null;
  if (userRefreshTimer) clearInterval(userRefreshTimer);
  userRefreshTimer = null;
  statusTray?.destroy();
  statusTray = null;
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
