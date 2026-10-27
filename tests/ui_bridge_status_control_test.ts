// REQ-BTOP-1 / REQ-BTOP-2 / REQ-OIDC-DESKTOP-1 / REQ-MAC-TRAY-1 / REQ-MAC-TRAY-2
// RUN: node --test tests/ui_bridge_status_control_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import childProcess from 'node:child_process';
import { EventEmitter } from 'node:events';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { desktopBridgeStatusLabel } from '../src/ui/bridge/desktopBridge.ts';
import bridgeManager from '../src/ui/electron/bridgeManager.cts';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const statusSource = fs.readFileSync(path.join(ROOT, 'src/ui/components/shell/SidebarUpdateBadge.tsx'), 'utf8');
const preloadSource = fs.readFileSync(path.join(ROOT, 'src/ui/electron/preload.cts'), 'utf8');
const mainSource = fs.readFileSync(path.join(ROOT, 'src/ui/electron/main.cts'), 'utf8');
const managerSource = fs.readFileSync(path.join(ROOT, 'src/ui/electron/bridgeManager.cts'), 'utf8');
const authGateSource = fs.readFileSync(path.join(ROOT, 'src/ui/components/ElectronDeviceAuthGate.tsx'), 'utf8');
const appShellSource = fs.readFileSync(path.join(ROOT, 'src/ui/components/shell/AppShell.tsx'), 'utf8');

const base = {
  supported: true, packaged: true, installed: true, enrolled: true,
  serviceState: 'running' as const, serviceName: 'heimdall-bridge-example',
  hubUrl: 'https://hub.example', installedVersion: '0.5.8', bundledVersion: '0.5.9', busy: false, error: '',
};

test('REQ-BTOP-1: enrollment output recognizes the canonical 14-symbol pairing code', () => {
  assert.deepEqual(
    bridgeManager.extractEnrollmentPairing(`Open https://heimdall.example/api/v1/device/add\nand type QESF-BO6G-XSJX-4E\n`),
    { url: 'https://heimdall.example/api/v1/device/add', code: 'QESF-BO6G-XSJX-4E' },
  );
  assert.equal(
    bridgeManager.extractEnrollmentPairing('https://heimdall.example/api/v1/device/add ABCD-EFGH-IJKL-MNOP'),
    null,
  );
});

// Records every child process bridgeManager starts and completes it with exit 0.
function stubSpawn(t: any): Array<{ command: string; args: string[]; env: NodeJS.ProcessEnv }> {
  const calls: Array<{ command: string; args: string[]; env: NodeJS.ProcessEnv }> = [];
  t.mock.method(childProcess, 'spawn', (command: string, args: string[], options: any) => {
    calls.push({ command, args, env: options?.env || {} });
    const proc: any = new EventEmitter();
    proc.stdout = new EventEmitter();
    proc.stderr = new EventEmitter();
    setImmediate(() => proc.emit('close', 0));
    return proc;
  });
  return calls;
}

function assertStockMacBridgeEnv(env: NodeJS.ProcessEnv) {
  assert.equal(env.PATH, '/usr/bin:/bin:/usr/sbin:/sbin');
  assert.equal(env.HAM_TLS_BACKEND, 's_client');
  assert.equal(env.HEIMDALL_INSTALL_PLAIN, '1');
}

test('REQ-DMG-ENV-1: packaged install runs with the stock-macOS TLS relay environment', async (t) => {
  const resources = fs.mkdtempSync(path.join(os.tmpdir(), 'heimdall-bridge-resources-'));
  t.after(() => fs.rmSync(resources, { recursive: true, force: true }));
  const target = process.arch === 'arm64' ? 'darwin-arm64' : 'darwin-amd64';
  for (const name of ['install.sh', `heimdall-local-${target}.tar.gz`, 'SHA256SUMS']) fs.writeFileSync(path.join(resources, name), '');
  fs.writeFileSync(path.join(resources, 'METADATA.json'), JSON.stringify({ version: 'v0.5.15' }));
  const previous = process.env.HEIMDALL_BRIDGE_RESOURCES;
  process.env.HEIMDALL_BRIDGE_RESOURCES = resources;
  t.after(() => { if (previous === undefined) delete process.env.HEIMDALL_BRIDGE_RESOURCES; else process.env.HEIMDALL_BRIDGE_RESOURCES = previous; });
  const calls = stubSpawn(t);

  const result = await bridgeManager.installBundled('https://hub.example');

  assert.equal(result.ok, true);
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].args.slice(0, 3), [path.join(resources, 'install.sh'), '--hub', 'https://hub.example']);
  assertStockMacBridgeEnv(calls[0].env);
});

test('REQ-DMG-ENV-1: enrollment runs with the same TLS relay environment as install', async (t) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'heimdall-bridge-home-'));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const stateDir = path.join(home, '.config', 'heimdall', 'bridges', 'heimdall-bridge-hub-example');
  fs.mkdirSync(stateDir, { recursive: true });
  fs.writeFileSync(path.join(stateDir, 'hub-url'), 'https://hub.example\n');
  fs.writeFileSync(path.join(stateDir, 'enroll.sh'), '');
  t.mock.method(os, 'homedir', () => home);
  const calls = stubSpawn(t);
  const events: any[] = [];
  const done = new Promise<void>((resolve) => {
    assert.deepEqual(bridgeManager.startEnrollment('https://hub.example/', (event: any) => { events.push(event); if (event.type === 'complete') resolve(); }), { ok: true });
  });
  await done;

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].args, [path.join(stateDir, 'enroll.sh'), '--headless']);
  assertStockMacBridgeEnv(calls[0].env);
});

test('REQ-BTOP-1: desktop service states have explicit user-facing labels', () => {
  assert.deepEqual(desktopBridgeStatusLabel(base), { label: 'Bridge online', tone: 'success' });
  assert.deepEqual(desktopBridgeStatusLabel({ ...base, enrolled: false }), { label: 'Enrollment required', tone: 'warning' });
  assert.deepEqual(desktopBridgeStatusLabel({ ...base, installed: false, enrolled: false, serviceState: 'not-installed' }), { label: 'Bridge not installed', tone: 'muted' });
  assert.deepEqual(desktopBridgeStatusLabel({ ...base, serviceState: 'stopped' }), { label: 'Bridge offline', tone: 'danger' });
  assert.deepEqual(desktopBridgeStatusLabel({ ...base, error: 'bad bundle' }), { label: 'Bridge error', tone: 'danger' });
});

test('REQ-BTOP-1/2: top-bar control exposes status, version, update, install, enrollment, and code-copy actions', () => {
  for (const id of [
    'shell-bridge-status-btn', 'shell-bridge-status-popover', 'shell-bridge-check-update-btn',
    'shell-bridge-update-available-btn', 'shell-bridge-install-btn', 'shell-bridge-enroll-btn',
    'shell-bridge-pairing-code', 'shell-bridge-copy-pairing-code-btn',
  ]) assert.match(statusSource, new RegExp(`data-debug-id="${id}"`));
  assert.match(statusSource, /desktop\.installedVersion \|\| desktop\.bundledVersion/);
  assert.match(statusSource, /bridgesQuery\.refetch\(\)/);
});

test('REQ-OIDC-DESKTOP-1: Electron has no HUT bearer-token bridge and loads the OIDC Hub origin', () => {
  assert.doesNotMatch(preloadSource, /getStoredToken|storeToken|clearToken|deviceAuth/);
  assert.doesNotMatch(mainSource, /safeStorage|device-authorization-token|heimdall-device-auth/);
  assert.match(mainSource, /auth=oidc-session-cookie/);
  assert.match(mainSource, /win\.loadURL\(configuredUiOrigin\(\)\)/);
  assert.match(mainSource, /webPreferences: \{ contextIsolation: true, nodeIntegration: false, sandbox: true \}/);
  assert.match(mainSource, /nodeIntegration: false,\s+sandbox: true,\s+preload:/);
  assert.doesNotMatch(authGateSource, /headers\.set\(['"]Authorization|getStoredToken|device\/authorize/);
});

test('REQ-OIDC-DESKTOP-1: OIDC completion does not destroy its window inside a navigation callback', () => {
  assert.match(mainSource, /let finishing = false/);
  assert.match(mainSource, /if \(finishing\) return;\s+finishing = true/);
  assert.match(mainSource, /setImmediate\(\(\) => \{[\s\S]*loginWindow\.close\(\)/);
  assert.doesNotMatch(mainSource, /finishIfReturned[\s\S]*?authWindow\?\.close\(\)/);
});

test('REQ-MAC-TRAY-1: macOS keeps a status tray alive independently of the Bridge service', () => {
  assert.match(mainSource, /\bTray\b/);
  assert.match(mainSource, /function installStatusTray\(\)/);
  assert.match(mainSource, /setInterval\(refreshTrayStatus, 15_000\)/);
  assert.match(mainSource, /Bridge enrollment required/);
  assert.match(mainSource, /Bridge online/);
  assert.match(mainSource, /Bridge offline/);
  assert.match(mainSource, /Bridge v\$\{version\}/);
  assert.match(mainSource, /Check for Bridge Updates/);
  assert.match(mainSource, /webContents\.send\('heimdall-bridge:check-updates'\)/);
  assert.match(preloadSource, /onCheckUpdatesRequested/);
  assert.match(preloadSource, /pendingBridgeUpdateCheck/);
  assert.match(preloadSource, /queueMicrotask\(callback\)/);
  assert.match(statusSource, /manager\.onCheckUpdatesRequested/);
  assert.match(mainSource, /Refresh Bridge Status/);
  assert.match(mainSource, /String\(status\.hubUrl \|\| configuredHubApiBaseUrl\(\)\)/);
});

test('REQ-MAC-TRAY-2: native menu manages packaged Bridge installation, restart, and browser re-enrollment', () => {
  assert.match(mainSource, /label: 'Install Packaged Bridge'/);
  assert.match(mainSource, /bridgeManager\.installBundled\(configuredHubApiBaseUrl\(\)\)/);
  assert.match(mainSource, /label: 'Restart Bridge'/);
  assert.match(mainSource, /bridgeManager\.restart\(configuredHubApiBaseUrl\(\)\)/);
  assert.match(mainSource, /'Re-enroll Bridge…'/);
  assert.match(mainSource, /bridgeManager\.startReEnrollment\(configuredHubApiBaseUrl\(\), handleEnrollmentEvent\)/);
  assert.match(mainSource, /message: 'Re-enroll this Bridge\?'/);
  assert.match(mainSource, /label: 'Copy Pairing Code'/);
  assert.match(mainSource, /clipboard\.writeText/);
  assert.match(managerSource, /\['kickstart', '-k', target\]/);
  assert.match(managerSource, /function startReEnrollment/);
  assert.match(managerSource, /module\.exports = \{[^}]*restart[^}]*startReEnrollment/);
});

test('REQ-MAC-TRAY-2: tray receives display-only OIDC identity and never an auth credential', () => {
  assert.match(preloadSource, /setAuthenticatedUser: \(identity: any\) => ipcRenderer\.send\('heimdall-auth:set-user', identity\)/);
  assert.match(appShellSource, /desktopApi\.setAuthenticatedUser\(auth\.status === 'authenticated'/);
  assert.match(mainSource, /ipcMain\.on\('heimdall-auth:set-user'/);
  assert.match(mainSource, /Signed in as \$\{authenticatedUserLabel\}/);
  assert.match(mainSource, /identity\.display_name \|\| identity\.name \|\| identity\.email \|\| identity\.user_id/);
  assert.doesNotMatch(appShellSource, /setAuthenticatedUser\([^)]*(token|cookie|authorization)/i);
});

test('REQ-MAC-TRAY-1: closing the macOS window hides it and packaged installs launch hidden at login', () => {
  assert.match(mainSource, /win\.on\('close',[\s\S]*process\.platform !== 'darwin' \|\| isQuitting[\s\S]*event\.preventDefault\(\)[\s\S]*win\.hide\(\)/);
  assert.match(mainSource, /app\.dock\?\.hide\(\)/);
  assert.match(mainSource, /app\.setLoginItemSettings\(\{[\s\S]*openAtLogin: enabled,[\s\S]*openAsHidden: true/);
  assert.match(mainSource, /function ensureDefaultLaunchAtLogin\(\)/);
  assert.match(mainSource, /LOGIN_ITEM_PREFERENCE_MARKER/);
  assert.match(mainSource, /settings\.status === 'requires-approval'/);
  assert.match(mainSource, /label: 'Launch at Login'/);
  assert.match(mainSource, /function wasOpenedAtLogin\(\)/);
  assert.match(mainSource, /settings\.wasOpenedAtLogin/);
  assert.match(mainSource, /if \(!backgroundLaunch\) createWindow\(\)/);
  assert.match(mainSource, /showMainWindow/);
  assert.match(mainSource, /isQuitting = true; app\.quit\(\)/);
});

test('REQ-ELECTRON-NO-REMOTE-DEBUG-1: the Electron app has no debug-control server at all', () => {
  for (const removed of ['src/ui/electron/debugServer.cts', 'src/ui/electron/instanceRegistry.cts', 'src/ui/debugCapture.ts']) {
    assert.equal(fs.existsSync(path.join(ROOT, removed)), false, `${removed} must stay deleted`);
  }
  assert.doesNotMatch(preloadSource, /toggleDebugServer|getDebugInfo|debug-server|debug-info/);
  assert.doesNotMatch(mainSource, /debugServer|startDebugServer|HEIMDALL_UI_DEBUG|instanceRegistry/);
  const rendererEntry = fs.readFileSync(path.join(ROOT, 'src/ui/main.tsx'), 'utf8');
  assert.doesNotMatch(rendererEntry, /debugCapture|__debugStore/);
});
