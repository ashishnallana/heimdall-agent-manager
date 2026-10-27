const { app, BrowserWindow, ipcMain, dialog, nativeImage, Menu, shell } = require('electron');
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
const { pruneAndRegister, updatePort, deregister } = require('./instanceRegistry.cjs');
const { startDebugServer, stopDebugServer } = require('./debugServer.cjs');
const bridgeManager = require('./bridgeManager.cjs');

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

function openOidcWindow(url: string, owner: any) {
  // REQ-OIDC-DESKTOP-1: OIDC runs in a preload-free window which shares the
  // default Electron cookie jar. Once the Hub callback has set its HttpOnly
  // session cookie, the trusted main window reloads the same-origin Hub UI.
  if (authWindow && !authWindow.isDestroyed()) { authWindow.focus(); return; }
  authWindow = new BrowserWindow({
    width: 620,
    height: 760,
    parent: owner || undefined,
    modal: Boolean(owner),
    title: `Sign in to ${APP_DISPLAY_NAME}`,
    webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true },
  });
  const uiOrigin = new URL(configuredUiOrigin()).origin;
  const finishIfReturned = (_event: any, nextUrl: string) => {
    try {
      const parsed = new URL(nextUrl);
      if (parsed.origin !== uiOrigin || parsed.pathname.startsWith('/api/v1/auth/login') || parsed.pathname.startsWith('/api/v1/auth/callback')) return;
      const main = owner && !owner.isDestroyed() ? owner : BrowserWindow.getAllWindows().find((candidate: any) => candidate !== authWindow);
      authWindow?.close();
      authWindow = null;
      main?.loadURL(configuredUiOrigin());
    } catch (_err) { /* Keep the OIDC window open for non-URL navigations. */ }
  };
  authWindow.webContents.on('did-navigate', finishIfReturned);
  authWindow.webContents.on('did-redirect-navigation', finishIfReturned);
  authWindow.on('closed', () => { authWindow = null; });
  void authWindow.loadURL(url);
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
    const trustedOrigin = new URL(configuredUiOrigin()).origin;
    const guardNavigation = (event: any, url: string) => {
      try {
        if (new URL(url).origin === trustedOrigin) return;
      } catch (_err) { /* Treat malformed navigation as untrusted. */ }
      event.preventDefault();
      openOidcWindow(url, win);
    };
    // `will-redirect` is load-bearing: /auth/login reaches the identity
    // provider through an HTTP 302, which is not a user-initiated navigation.
    win.webContents.on('will-navigate', guardNavigation);
    win.webContents.on('will-redirect', guardNavigation);
    win.webContents.setWindowOpenHandler(({ url }: { url: string }) => {
      void shell.openExternal(url);
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

let currentDebugPort = 0;

ipcMain.handle('odin-api:get-debug-info', () => {
  return { enabled: currentDebugPort !== 0, port: currentDebugPort, pid: process.pid };
});

ipcMain.handle('odin-api:toggle-debug-server', async (_event, enable: boolean) => {
  if (enable) {
    if (currentDebugPort === 0) {
      currentDebugPort = await startDebugServer();
      updatePort(currentDebugPort);
    }
  } else {
    if (currentDebugPort !== 0) {
      await stopDebugServer();
      currentDebugPort = 0;
      updatePort(0);
    }
  }
  return { enabled: currentDebugPort !== 0, port: currentDebugPort, pid: process.pid };
});

ipcMain.handle('heimdall-api:open-external', async (_event, url: string) => {
  await shell.openExternal(String(url || ''));
  return { ok: true };
});

ipcMain.handle('heimdall-bridge:get-status', () => bridgeManager.getStatus(configuredHubApiBaseUrl()));
ipcMain.handle('heimdall-bridge:install-bundled', () => bridgeManager.installBundled(configuredHubApiBaseUrl()));
ipcMain.handle('heimdall-bridge:start-enrollment', (event) => bridgeManager.startEnrollment(configuredHubApiBaseUrl(), (payload: any) => {
  if (!event.sender.isDestroyed()) event.sender.send('heimdall-bridge:enrollment-event', payload);
  if (payload?.type === 'pairing' && payload?.url) void shell.openExternal(String(payload.url));
}));


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

  // In dev the renderer runs at the Vite dev-server origin, and Vite's
  // `server.proxy` (see vite.config.js) forwards `/api/v1` to the local Hub.
  // Packaged builds load the HTTPS Hub UI directly; both use its OIDC cookie.
  const daemonUrl = process.env.HEIMDALL_DAEMON_URL || 'http://127.0.0.1:49322';
  pruneAndRegister(daemonUrl);
  updatePort(0); // Explicitly 0 since disabled by default

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

  if (process.env.HEIMDALL_UI_DEBUG === '1') {
    currentDebugPort = await startDebugServer();
    updatePort(currentDebugPort);
    console.log(`[heimdall] debug_server_port=${currentDebugPort}`);
  }

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('before-quit', () => {
  deregister();
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
