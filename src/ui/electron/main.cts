const { app, BrowserWindow, ipcMain, dialog, nativeImage, Menu, safeStorage, shell } = require('electron');
const fs = require('fs');
const os = require('os');
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

function normalizeBaseUrl(value: string): string {
  return String(value || '').trim().replace(/\/$/, '');
}

function configuredHubApiBaseUrl(): string {
  return normalizeBaseUrl(
    process.env.HEIMDALL_HUB_API_URL ||
    process.env.HEIMDALL_HUB_URL ||
    // Default to the public Hub API, not the outpost/dev-proxy browser URL.
    'http://127.0.0.1:8081'
  );
}

function deviceTokenPath(): string {
  return path.join(app.getPath('userData'), 'device-authorization-token.bin');
}

function readDeviceToken(): { ok: boolean; token: string; error?: string } {
  try {
    const filePath = deviceTokenPath();
    if (!fs.existsSync(filePath)) return { ok: true, token: '' };
    if (!safeStorage.isEncryptionAvailable()) return { ok: false, token: '', error: 'Electron safeStorage encryption is unavailable on this OS/session.' };
    const encrypted = fs.readFileSync(filePath);
    return { ok: true, token: safeStorage.decryptString(encrypted) };
  } catch (err: any) {
    return { ok: false, token: '', error: String(err?.message || err || 'Unable to read stored token') };
  }
}

function writeDeviceToken(token: string): { ok: boolean; error?: string } {
  try {
    if (!safeStorage.isEncryptionAvailable()) return { ok: false, error: 'Electron safeStorage encryption is unavailable on this OS/session.' };
    fs.mkdirSync(app.getPath('userData'), { recursive: true });
    fs.writeFileSync(deviceTokenPath(), safeStorage.encryptString(String(token || '')));
    return { ok: true };
  } catch (err: any) {
    return { ok: false, error: String(err?.message || err || 'Unable to store token') };
  }
}

function clearDeviceToken(): { ok: boolean; error?: string } {
  try {
    const filePath = deviceTokenPath();
    if (fs.existsSync(filePath)) fs.rmSync(filePath, { force: true });
    return { ok: true };
  } catch (err: any) {
    return { ok: false, error: String(err?.message || err || 'Unable to clear token') };
  }
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

  if (isDev) {
    win.loadURL(process.env.VITE_DEV_SERVER_URL || 'http://127.0.0.1:5173');
  } else {
    win.loadFile(path.join(__dirname, '..', 'dist', 'index.html'));
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

ipcMain.handle('heimdall-device-auth:get-config', () => {
  return { apiBaseUrl: configuredHubApiBaseUrl(), safeStorageAvailable: safeStorage.isEncryptionAvailable() };
});

ipcMain.handle('heimdall-device-auth:get-token', () => readDeviceToken());

ipcMain.handle('heimdall-device-auth:store-token', (_event, token: string) => writeDeviceToken(token));

ipcMain.handle('heimdall-device-auth:clear-token', () => clearDeviceToken());

ipcMain.handle('heimdall-device-auth:device-info', () => {
  return {
    client: 'heimdall-electron',
    deviceLabel: os.hostname() || 'Heimdall Desktop',
    os: `${process.platform} ${process.arch}`,
    appVersion: app.getVersion?.() || '0.1.0',
  };
});

ipcMain.handle('heimdall-device-auth:open-external', async (_event, url: string) => {
  await shell.openExternal(String(url || ''));
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

  // In dev the renderer runs at the Vite dev-server origin, and Vite's
  // `server.proxy` (see vite.config.js) forwards `/api/v1` to the local Hub,
  // which authenticates users only with its OIDC session cookie (local dev uses
  // tools/mock-oidc). TODO(oidc): desktop sign-in is not implemented yet.
  const daemonUrl = process.env.HEIMDALL_DAEMON_URL || 'http://127.0.0.1:49322';
  pruneAndRegister(daemonUrl);
  updatePort(0); // Explicitly 0 since disabled by default

  console.log('[heimdall] startup config:');
  console.log(`  daemon_url=${daemonUrl}`);
  console.log(`  daemon_url_source=${process.env.HEIMDALL_DAEMON_URL ? 'env' : 'default'}`);
  console.log(`  hub_api_base_url=${configuredHubApiBaseUrl()}`);
  console.log(`  safe_storage_available=${safeStorage.isEncryptionAvailable()}`);
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
