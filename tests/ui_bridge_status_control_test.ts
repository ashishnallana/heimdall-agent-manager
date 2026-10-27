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
import externalUrl from '../src/ui/electron/externalUrl.cts';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const statusSource = fs.readFileSync(path.join(ROOT, 'src/ui/components/shell/SidebarUpdateBadge.tsx'), 'utf8');
const preloadSource = fs.readFileSync(path.join(ROOT, 'src/ui/electron/preload.cts'), 'utf8');
const mainSource = fs.readFileSync(path.join(ROOT, 'src/ui/electron/main.cts'), 'utf8');
const managerSource = fs.readFileSync(path.join(ROOT, 'src/ui/electron/bridgeManager.cts'), 'utf8');
const updaterSource = fs.readFileSync(path.join(ROOT, 'src/ui/electron/desktopUpdater.cts'), 'utf8');
const authGateSource = fs.readFileSync(path.join(ROOT, 'src/ui/components/ElectronDeviceAuthGate.tsx'), 'utf8');
const appShellSource = fs.readFileSync(path.join(ROOT, 'src/ui/components/shell/AppShell.tsx'), 'utf8');
const builderSource = fs.readFileSync(path.join(ROOT, 'electron-builder.yml'), 'utf8');
const windowsInstallerSource = fs.readFileSync(path.join(ROOT, 'scripts/install.ps1'), 'utf8');
const windowsSocketSource = fs.readFileSync(path.join(ROOT, 'src/bridge/os_platform_windows.odin'), 'utf8');
const releaseWorkflowSource = fs.readFileSync(path.join(ROOT, '.github/workflows/release-local-binaries.yml'), 'utf8');

const base = {
  supported: true, packaged: true, installed: true, enrolled: true,
  bridgeId: 'brg_example', canReEnroll: true,
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

type SpawnCall = { command: string; args: string[]; env: NodeJS.ProcessEnv; proc: any };

// Records every child process bridgeManager starts. Each completes with the exit
// code `exitCode` returns for it; `null` leaves it running until the test acts.
function stubSpawn(t: any, exitCode: (call: SpawnCall) => number | null = () => 0): SpawnCall[] {
  const calls: SpawnCall[] = [];
  t.mock.method(childProcess, 'spawn', (command: string, args: string[], options: any) => {
    const proc: any = new EventEmitter();
    proc.stdout = new EventEmitter();
    proc.stderr = new EventEmitter();
    proc.pid = 4242 + calls.length;
    proc.kill = () => true;
    const call = { command, args, env: options?.env || {}, proc };
    calls.push(call);
    const code = exitCode(call);
    if (code !== null) setImmediate(() => proc.emit('close', code));
    return proc;
  });
  return calls;
}

// A Bridge home with one enrolled, installed-on-macOS service for hub.example.
function enrolledBridgeHome(t: any): { home: string; stateDir: string } {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'heimdall-bridge-home-'));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const serviceName = 'heimdall-bridge-hub-example';
  const stateDir = path.join(home, '.config', 'heimdall', 'bridges', serviceName);
  fs.mkdirSync(stateDir, { recursive: true });
  fs.writeFileSync(path.join(stateDir, 'hub-url'), 'https://hub.example\n');
  fs.writeFileSync(path.join(stateDir, 'enroll.sh'), '');
  fs.writeFileSync(path.join(stateDir, 'bridge-token'), 'token');
  fs.writeFileSync(path.join(stateDir, 'bridge-id'), 'brg_example\n');
  const binDir = path.join(home, '.local', 'share', 'heimdall', 'bridges', serviceName, 'bin');
  fs.mkdirSync(binDir, { recursive: true });
  fs.writeFileSync(path.join(binDir, 'ham-bridge'), '');
  fs.mkdirSync(path.join(home, 'Library', 'LaunchAgents'), { recursive: true });
  fs.writeFileSync(path.join(home, 'Library', 'LaunchAgents', `${serviceName}.plist`), '');
  t.mock.method(os, 'homedir', () => home);
  const platform = Object.getOwnPropertyDescriptor(process, 'platform')!;
  Object.defineProperty(process, 'platform', { ...platform, value: 'darwin' });
  t.after(() => Object.defineProperty(process, 'platform', platform));
  // launchd reports the agent as not loaded; bootstrap and kickstart succeed.
  t.mock.method(childProcess, 'spawnSync', (_command: string, args: string[]) => ({ status: args?.[0] === 'print' ? 1 : 0, stdout: '', stderr: '' }));
  // Async status probes: not loaded, and no version output.
  t.mock.method(childProcess, 'execFile', (_command: string, _args: string[], _options: any, callback: any) => {
    setImmediate(() => callback(Object.assign(new Error('not loaded'), { code: 113 }), '', ''));
    return new EventEmitter();
  });
  return { home, stateDir };
}

function assertStockMacBridgeEnv(env: NodeJS.ProcessEnv) {
  const home = os.homedir();
  assert.equal(env.PATH, [
    '/usr/bin', '/bin', '/usr/sbin', '/sbin', '/usr/local/bin', '/opt/homebrew/bin',
    path.join(home, '.local', 'bin'), path.join(home, '.npm-global', 'bin'),
    path.join(home, '.bun', 'bin'), path.join(home, '.volta', 'bin'),
    path.join(home, '.cargo', 'bin'), path.join(home, '.nix-profile', 'bin'),
    '/run/current-system/sw/bin', '/nix/var/nix/profiles/default/bin',
  ].join(':'));
  assert.equal(env.HAM_TLS_BACKEND, undefined);
  assert.equal(env.HEIMDALL_INSTALL_PLAIN, '1');
}

test('REQ-DMG-ENV-1: packaged install needs only the stock macOS tool environment', async (t) => {
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

test('REQ-DMG-ENV-1: enrollment uses the same stock tool environment as install', async (t) => {
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

test('REQ-MAC-TRAY-2: tokenless state retains a safe re-enrollment identity and rejects conflicting hints', (t) => {
  const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'heimdall-bridge-state-'));
  t.after(() => fs.rmSync(stateDir, { recursive: true, force: true }));
  fs.writeFileSync(path.join(stateDir, 'config.toml'), '[daemon]\ndaemon_id = "brg_previous123"\n');

  assert.equal(bridgeManager.discoverBridgeId(stateDir), 'brg_previous123');

  fs.writeFileSync(path.join(stateDir, 'bridge-id'), 'brg_different456\n');
  assert.equal(bridgeManager.discoverBridgeId(stateDir), '', 'conflicting identity hints fail closed');
});

test('REQ-MAC-TRAY-2: tokenless re-enrollment explicitly reuses the recorded Bridge id', { skip: process.platform !== 'darwin' }, async (t) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'heimdall-bridge-home-'));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const serviceName = 'heimdall-bridge-hub-example';
  const stateDir = path.join(home, '.config', 'heimdall', 'bridges', serviceName);
  const binDir = path.join(home, '.local', 'share', 'heimdall', 'bridges', serviceName, 'bin');
  fs.mkdirSync(stateDir, { recursive: true });
  fs.mkdirSync(binDir, { recursive: true });
  fs.writeFileSync(path.join(stateDir, 'hub-url'), 'https://hub.example\n');
  fs.writeFileSync(path.join(stateDir, 'config.toml'), '[daemon]\ndaemon_id = "brg_previous123"\n');
  fs.writeFileSync(path.join(stateDir, 'enroll.sh'), '');
  fs.writeFileSync(path.join(binDir, 'ham-bridge'), '');
  t.mock.method(os, 'homedir', () => home);
  t.mock.method(childProcess, 'spawnSync', () => ({ status: 1, stdout: 'ham-bridge 0.5.16\n', stderr: '' }));
  const calls = stubSpawn(t);
  const events: any[] = [];
  const done = new Promise<void>((resolve) => {
    assert.deepEqual(bridgeManager.startReEnrollment('https://hub.example', (event: any) => {
      events.push(event);
      if (event.type === 'complete') resolve();
    }), { ok: true });
  });
  await done;

  assert.deepEqual(calls[0].args, [path.join(stateDir, 'enroll.sh'), '--headless', '--reuse-bridge', 'brg_previous123']);
  assert.equal(events.filter((event) => event.type === 'complete').length, 1);
  assert.equal(fs.readFileSync(path.join(stateDir, 'bridge-id'), 'utf8').trim(), 'brg_previous123');
});

test('REQ-MAC-TRAY-2: enrollment reports the actionable subprocess failure once', async (t) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'heimdall-bridge-home-'));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const stateDir = path.join(home, '.config', 'heimdall', 'bridges', 'heimdall-bridge-hub-example');
  fs.mkdirSync(stateDir, { recursive: true });
  fs.writeFileSync(path.join(stateDir, 'hub-url'), 'https://hub.example\n');
  fs.writeFileSync(path.join(stateDir, 'enroll.sh'), '');
  t.mock.method(os, 'homedir', () => home);
  t.mock.method(childProcess, 'spawn', () => {
    const proc: any = new EventEmitter();
    proc.stdout = new EventEmitter();
    proc.stderr = new EventEmitter();
    setImmediate(() => {
      proc.stderr.emit('data', 'bridge enroll FAILED: retained identity requires explicit reuse\n');
      proc.emit('close', 1);
    });
    return proc;
  });
  const events: any[] = [];
  await new Promise<void>((resolve) => {
    bridgeManager.startEnrollment('https://hub.example', (event: any) => {
      events.push(event);
      if (event.type === 'error') resolve();
    });
  });

  const logPath = path.join(home, '.local', 'share', 'heimdall', 'bridges', 'heimdall-bridge-hub-example', 'logs', 'enroll.log');
  assert.deepEqual(events.filter((event) => event.type === 'error'), [{
    type: 'error',
    message: `bridge enroll FAILED: retained identity requires explicit reuse\nFull log: ${logPath}`,
    summary: 'bridge enroll FAILED: retained identity requires explicit reuse',
    logPath,
  }]);
});

test('REQ-WIN-DESKTOP-1: Windows resources and per-user Bridge paths are architecture-safe', () => {
  const root = path.join('C:', 'Program Files', 'Heimdall', 'resources', 'bridge');
  assert.deepEqual(bridgeManager.resources('win32', 'arm64', root), {
    installScript: path.join(root, 'install.ps1'),
    bundle: path.join(root, 'heimdall-local-windows-amd64.zip'),
    checksums: path.join(root, 'SHA256SUMS'),
    metadata: path.join(root, 'METADATA.json'),
  });
  assert.deepEqual(bridgeManager.desktopPaths('win32', {
    APPDATA: path.join('C:', 'Users', 'alice', 'AppData', 'Roaming'),
    LOCALAPPDATA: path.join('C:', 'Users', 'alice', 'AppData', 'Local'),
  }, path.join('C:', 'Users', 'alice')), {
    stateRoot: path.join('C:', 'Users', 'alice', 'AppData', 'Roaming', 'heimdall', 'bridges'),
    dataRoot: path.join('C:', 'Users', 'alice', 'AppData', 'Local', 'heimdall', 'bridges'),
    binaryName: 'ham-bridge.exe',
    enrollScriptName: 'enroll.ps1',
  });
});

test('REQ-WIN-DESKTOP-2: Windows desktop invokes the verified bundle and headless enrollment contracts', () => {
  const files = bridgeManager.resources('win32', 'x64', path.join('C:', 'resources', 'bridge'));
  const install = bridgeManager.installInvocation('win32', files, 'https://hub.example', '0.5.17');
  assert.match(install.command, /powershell\.exe$/i);
  assert.deepEqual(install.args.slice(-11), [
    '-File', files.installScript, '-Hub', 'https://hub.example', '-Version', 'v0.5.17',
    '-Bundle', files.bundle, '-ChecksumFile', files.checksums, '-NonInteractive',
  ]);
  const enroll = bridgeManager.enrollmentInvocation('win32', path.join('C:', 'state', 'enroll.ps1'));
  assert.match(enroll.command, /powershell\.exe$/i);
  assert.deepEqual(enroll.args.slice(-3), ['-File', path.join('C:', 'state', 'enroll.ps1'), '-Headless']);
  const reenroll = bridgeManager.enrollmentInvocation('win32', path.join('C:', 'state', 'enroll.ps1'), 'brg_previous123');
  assert.deepEqual(reenroll.args.slice(-5), [
    '-File', path.join('C:', 'state', 'enroll.ps1'), '-Headless', '-ReuseBridge', 'brg_previous123',
  ]);
  assert.match(windowsInstallerSource, /\[string\]\$Bundle/);
  assert.match(windowsInstallerSource, /\[string\]\$ChecksumFile/);
  assert.match(windowsInstallerSource, /Test-Sha256 \$sums \$O\.Bundle \$archive/);
  assert.match(windowsInstallerSource, /param\(\[switch\]\$Headless, \[string\]\$ReuseBridge/);
  assert.match(windowsInstallerSource, /--reuse-bridge', \$ReuseBridge/);
  assert.match(windowsInstallerSource, /Get-BridgeId \$C/);
});

test('REQ-WIN-DESKTOP-2: Windows desktop supplies common per-user provider locations', (t) => {
  const home = path.join('C:', 'Users', 'alice');
  t.mock.method(os, 'homedir', () => home);
  const previous = {
    APPDATA: process.env.APPDATA,
    LOCALAPPDATA: process.env.LOCALAPPDATA,
    PATH: process.env.PATH,
  };
  process.env.APPDATA = path.join(home, 'AppData', 'Roaming');
  process.env.LOCALAPPDATA = path.join(home, 'AppData', 'Local');
  process.env.PATH = path.join('C:', 'Windows', 'System32');
  const roaming = process.env.APPDATA;
  const local = process.env.LOCALAPPDATA;
  const systemPath = process.env.PATH;
  t.after(() => {
    for (const [name, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[name]; else process.env[name] = value;
    }
  });

  const env = bridgeManager.bridgeHostEnv('win32');
  assert.deepEqual(env.PATH?.split(';'), [
    path.join(roaming, 'npm'),
    path.join(local, 'pnpm'),
    path.join(home, '.local', 'bin'),
    path.join(home, '.bun', 'bin'),
    path.join(home, '.volta', 'bin'),
    path.join(home, '.cargo', 'bin'),
    systemPath,
  ]);
  assert.equal(env.HEIMDALL_INSTALL_PLAIN, '1');
  assert.equal(env.HAM_TLS_BACKEND, undefined);
});

test('REQ-WIN-DESKTOP-2: Windows bridge listeners explicitly reject child-process inheritance', () => {
  assert.match(windowsSocketSource, /SetHandleInformation/);
  assert.match(windowsSocketSource, /win\.HANDLE_FLAG_INHERIT, 0/);
});

test('REQ-REENROLL-RECOVER-1: failed Windows re-enrollment restarts its Scheduled Task', async (t) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'heimdall-windows-home-'));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const roaming = path.join(home, 'AppData', 'Roaming');
  const local = path.join(home, 'AppData', 'Local');
  const serviceName = 'heimdall-bridge-hub-example';
  const stateDir = path.join(roaming, 'heimdall', 'bridges', serviceName);
  const binDir = path.join(local, 'heimdall', 'bridges', serviceName, 'bin');
  fs.mkdirSync(stateDir, { recursive: true });
  fs.mkdirSync(binDir, { recursive: true });
  fs.writeFileSync(path.join(stateDir, 'hub-url'), 'https://hub.example\n');
  fs.writeFileSync(path.join(stateDir, 'bridge-token'), 'token\n');
  fs.writeFileSync(path.join(stateDir, 'bridge-id'), 'brg_previous123\n');
  fs.writeFileSync(path.join(stateDir, 'enroll.ps1'), '');
  fs.writeFileSync(path.join(binDir, 'ham-bridge.exe'), '');

  const previous = {
    APPDATA: process.env.APPDATA,
    LOCALAPPDATA: process.env.LOCALAPPDATA,
    USERPROFILE: process.env.USERPROFILE,
    SystemRoot: process.env.SystemRoot,
  };
  Object.assign(process.env, { APPDATA: roaming, LOCALAPPDATA: local, USERPROFILE: home, SystemRoot: path.join('C:', 'Windows') });
  t.after(() => {
    for (const [name, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[name]; else process.env[name] = value;
    }
  });
  t.mock.method(os, 'homedir', () => home);
  const platform = Object.getOwnPropertyDescriptor(process, 'platform')!;
  Object.defineProperty(process, 'platform', { ...platform, value: 'win32' });
  t.after(() => Object.defineProperty(process, 'platform', platform));
  t.mock.method(childProcess, 'spawnSync', (command: string) => ({
    status: 0,
    stdout: command.endsWith('ham-bridge.exe') ? 'ham-bridge 0.5.17\n' : '',
    stderr: '',
  }));
  const statusProbes: Array<{ command: string; args: string[]; env: NodeJS.ProcessEnv }> = [];
  t.mock.method(childProcess, 'execFile', (command: string, args: string[], options: any, callback: any) => {
    statusProbes.push({ command, args, env: options?.env || {} });
    setImmediate(() => callback(null, command.endsWith('ham-bridge.exe') ? 'ham-bridge 0.5.17\n' : '', ''));
    return new EventEmitter();
  });
  const status = await bridgeManager.refreshStatus('https://hub.example');
  assert.equal(status.serviceState, 'running');
  assert.equal(status.installedVersion, '0.5.17');
  assert.equal(statusProbes.length, 2);
  assert.ok(statusProbes[0].args.includes('-Command'));
  assert.equal(statusProbes[0].env.HEIMDALL_BRIDGE_TASK_NAME, serviceName);
  assert.equal((childProcess.spawnSync as any).mock.calls.length, 0, 'status probing stays asynchronous on Windows');
  const calls = stubSpawn(t, (call) => call.args.includes('-File') ? 1 : 0);
  const events: any[] = [];
  await new Promise<void>((resolve) => {
    assert.deepEqual(bridgeManager.startReEnrollment('https://hub.example', (event: any) => {
      events.push(event);
      if (event.type === 'error') resolve();
    }), { ok: true });
  });

  assert.deepEqual(calls[0].args.slice(-5), [
    '-File', path.join(stateDir, 'enroll.ps1'), '-Headless', '-ReuseBridge', 'brg_previous123',
  ]);
  assert.equal(calls.length, 2);
  assert.ok(calls[1].args.includes('-Command'));
  assert.equal(calls[1].env.HEIMDALL_BRIDGE_TASK_NAME, serviceName);
  assert.match(events.at(-1).message, /restarted with its existing enrollment/);
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
  assert.match(statusSource, /desktop\.installed \? desktop\.installedVersion : ''/);
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
  assert.match(mainSource, /setInterval\(\(\) => \{ void refreshBridgeStatus\(\); \}, 15_000\)/);
  assert.match(mainSource, /Bridge enrollment required/);
  assert.match(mainSource, /Bridge online/);
  assert.match(mainSource, /Bridge offline/);
  assert.match(mainSource, /Bridge v\$\{version\}/);
  // An installed Bridge whose --version probe has not succeeded never falls
  // back to the version bundled with the app.
  assert.match(mainSource, /status\.installed \? status\.installedVersion : status\.bundledVersion/);
  assert.match(mainSource, /status\.installed \? 'Bridge version unknown' : ''/);
  assert.doesNotMatch(mainSource, /status\.installedVersion \|\| status\.bundledVersion/);
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
  assert.match(preloadSource, /startReEnrollment: \(\) => ipcRenderer\.invoke\('heimdall-bridge:start-re-enrollment'\)/);
  assert.match(statusSource, /desktop\?\.canReEnroll/);
  assert.match(managerSource, /'--reuse-bridge', reuseBridgeId/);
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
  assert.match(mainSource, /win\.on\('close',[\s\S]*!supportsStatusTray\(\) \|\| isQuitting[\s\S]*event\.preventDefault\(\)[\s\S]*win\.hide\(\)/);
  assert.match(mainSource, /app\.dock\?\.hide\(\)/);
  assert.match(mainSource, /const loginSettings =[\s\S]*openAtLogin: enabled,[\s\S]*openAsHidden: true/);
  assert.match(mainSource, /app\.setLoginItemSettings\(loginSettings\)/);
  assert.match(mainSource, /function ensureDefaultLaunchAtLogin\(\)/);
  assert.match(mainSource, /LOGIN_ITEM_PREFERENCE_MARKER/);
  assert.match(mainSource, /recordedSettings\.status === 'requires-approval'/);
  assert.match(mainSource, /label: 'Launch at Login'/);
  assert.match(mainSource, /function wasOpenedAtLogin\(\)/);
  assert.match(mainSource, /settings\.wasOpenedAtLogin/);
  assert.match(mainSource, /if \(!backgroundLaunch\) createWindow\(\)/);
  assert.match(mainSource, /showMainWindow/);
  assert.match(mainSource, /isQuitting = true; app\.quit\(\)/);
});

test('REQ-WIN-TRAY-1: Windows keeps a tray controller with Bridge, user, and update actions', () => {
  assert.match(mainSource, /process\.platform === 'darwin' \|\| process\.platform === 'win32'/);
  assert.match(mainSource, /process\.platform === 'win32' \? 16 : 18/);
  assert.match(mainSource, /statusTray\.on\('double-click', showMainWindow\)/);
  assert.match(mainSource, /process\.argv\.includes\('--background'\)/);
  assert.match(mainSource, /args: \['--background'\]/);
  assert.match(mainSource, /Check for Heimdall Updates/);
  assert.match(mainSource, /Restart to Install Heimdall/);
  assert.match(mainSource, /Check for Bridge Updates/);
  assert.match(mainSource, /Restart Bridge/);
  assert.match(mainSource, /Re-enroll Bridge/);
  assert.match(mainSource, /Signed in as/);
  assert.match(builderSource, /win:\s+[\s\S]*target: nsis/);
  assert.match(builderSource, /nsis:\s+[\s\S]*oneClick: false[\s\S]*perMachine: false/);
});

test('REQ-WIN-UPDATE-1: unsigned Windows releases publish digest-protected updater metadata', () => {
  assert.match(updaterSource, /require\('electron-updater'\)/);
  assert.match(updaterSource, /autoUpdater\.allowPrerelease = false/);
  assert.match(updaterSource, /autoUpdater\.checkForUpdates\(\)/);
  assert.match(updaterSource, /autoUpdater\.quitAndInstall\(false, true\)/);
  assert.match(mainSource, /desktopUpdater\.start\(app\.isPackaged && process\.platform === 'win32'/);
  assert.match(builderSource, /publish:\s+[\s\S]*provider: github[\s\S]*repo: heimdall-agent-manager/);
  assert.match(builderSource, /verifyUpdateCodeSignature: false/);
  assert.doesNotMatch(releaseWorkflowSource, /WINDOWS_CODE_SIGNING_PFX|signtool sign|forceCodeSigning=true/);
  assert.match(releaseWorkflowSource, /desktop-dist\/latest\.yml/);
  assert.match(
    releaseWorkflowSource,
    /npx electron-builder --win nsis --x64 --publish never `[\s\S]*?--config\.extraMetadata\.version=[\s\S]*?if \(\$LASTEXITCODE\) \{ throw "electron-builder failed with exit code \$LASTEXITCODE" \}/,
  );
  assert.doesNotMatch(releaseWorkflowSource, /npx electron-builder --win[\s\S]*?-c\.extraMetadata\.version=/);
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

test('REQ-REENROLL-RECOVER-1: a failed re-enrollment restarts the Bridge it booted out', async (t) => {
  enrolledBridgeHome(t);
  const calls = stubSpawn(t, (call) => (call.command === '/bin/bash' ? 1 : 0));
  const done = new Promise<any>((resolve) => {
    const started = bridgeManager.startReEnrollment('https://hub.example', (event: any) => { if (event.type === 'error') resolve(event); });
    assert.deepEqual(started, { ok: true });
  });
  const event = await done;

  assert.match(event.message, /^Enrollment exited with status 1\.\nThe Bridge was restarted with its existing enrollment\.\nFull log: /);
  assert.deepEqual(calls.slice(1).map((call) => [call.command, call.args[0], call.args[1]]), [
    ['/bin/launchctl', 'print', `gui/${process.getuid()}/heimdall-bridge-hub-example`],
    ['/bin/launchctl', 'kickstart', '-k'],
  ]);
});

test('REQ-REENROLL-RECOVER-1: a failed first enrollment does not restart a token-less Bridge', async (t) => {
  enrolledBridgeHome(t);
  const calls = stubSpawn(t, (call) => (call.command === '/bin/bash' ? 1 : 0));
  const done = new Promise<any>((resolve) => {
    bridgeManager.startEnrollment('https://hub.example', (event: any) => { if (event.type === 'error') resolve(event); });
  });
  const event = await done;

  assert.match(event.message, /^Enrollment exited with status 1\.\nFull log: .*\/logs\/enroll\.log$/);
  assert.equal(calls.length, 1);
});

test('REQ-REENROLL-RECOVER-1: quitting stops a running re-enrollment and restarts the Bridge', async (t) => {
  enrolledBridgeHome(t);
  const calls = stubSpawn(t, () => null);
  const kills: Array<[number, string]> = [];
  t.mock.method(process, 'kill', (pid: number, signal: string) => { kills.push([pid, signal]); return true; });
  assert.deepEqual(bridgeManager.startReEnrollment('https://hub.example', () => {}), { ok: true });
  const syncCalls = (childProcess.spawnSync as any).mock.calls.length;

  bridgeManager.stopEnrollment();

  assert.deepEqual(kills, [[-calls[0].proc.pid, 'SIGTERM']]);
  const launchctl = (childProcess.spawnSync as any).mock.calls.slice(syncCalls).map((call: any) => call.arguments[1][0]);
  assert.deepEqual(launchctl, ['print', 'bootstrap', 'kickstart']);
  calls[0].proc.emit('close', null);
});

test('REQ-EXT-URL-1: only https: and mailto: links reach the system browser', () => {
  for (const ok of ['https://customer-portal.paddle.com/cpl_1', 'mailto:support@example.com', ' https://github.com/a/b ']) {
    assert.notEqual(externalUrl.allowedExternalUrl(ok), '', ok);
  }
  for (const refused of [
    'file:///Applications/Calculator.app', 'smb://evil.example/share', 'javascript:alert(1)', 'http://example.com/',
    'x-apple.systempreferences:com.apple.preference.security', 'vscode://file/etc/passwd', 'https://user:pass@example.com/', '', null, 'not a url',
  ]) {
    assert.equal(externalUrl.allowedExternalUrl(refused), '', String(refused));
  }
});

test('REQ-EXT-URL-1: Bridge pairing pages open only on the configured Hub/UI origins', () => {
  const origins = ['https://hub.brolabs.ai', 'https://heimdall.brolabs.ai/'];
  assert.equal(externalUrl.allowedPairingUrl('https://heimdall.brolabs.ai/api/v1/device/add?c=1', origins), 'https://heimdall.brolabs.ai/api/v1/device/add?c=1');
  assert.equal(externalUrl.allowedPairingUrl('http://127.0.0.1:8081/api/v1/device/add', ['http://127.0.0.1:8081']), 'http://127.0.0.1:8081/api/v1/device/add');
  for (const refused of ['https://evil.example/api/v1/device/add', 'http://heimdall.brolabs.ai/api/v1/device/add', 'https://heimdall.brolabs.ai.evil.example/api/v1/device/add', 'file:///tmp/x']) {
    assert.equal(externalUrl.allowedPairingUrl(refused, origins), '', refused);
  }
});

test('REQ-EXT-URL-1: every shell.openExternal call in the main process uses a vetted URL', () => {
  const calls = [...mainSource.matchAll(/shell\.openExternal\(([^)]*)\)/g)].map((match) => match[1]);
  // OIDC-window popups, main-window navigation, main-window popups, pairing (x2), IPC.
  assert.deepEqual(calls, ['href', 'allowedExternalUrl(url', 'href', 'trayPairing.url', 'trayPairing.url', 'href']);
  assert.match(mainSource, /const href = allowedExternalUrl\(url\);\s*if \(href\) void shell\.openExternal\(href\);/);
  assert.match(mainSource, /const href = allowedExternalUrl\(url\);\s*if \(!href\) return \{ ok: false/);
  assert.match(mainSource, /allowedPairingUrl\(payload\.url, \[configuredHubApiBaseUrl\(\), configuredUiOrigin\(\)\]\)/);
});

const NAV = { uiOrigin: 'https://heimdall.brolabs.ai', idpOrigin: 'https://auth.brolabs.ai', inAuthRedirect: false };

test('REQ-NAV-ROUTE-1: only sign-in and sign-out navigations open the OIDC window', () => {
  const route = (url: string, extra: Partial<typeof NAV> = {}) => externalUrl.classifyNavigation(url, { ...NAV, ...extra });
  assert.equal(route('https://heimdall.brolabs.ai/chains/c1'), 'allow');
  assert.equal(route('https://heimdall.brolabs.ai/api/v1/auth/login?return_to=%2F'), 'allow');
  // The /api/v1/auth/login 302 to the provider, and sign-out at the provider's end-session URL.
  assert.equal(route('https://accounts.google.com/o/oauth2/auth?x=1', { inAuthRedirect: true }), 'auth');
  assert.equal(route('https://auth.brolabs.ai/application/o/heimdall/end-session/'), 'auth');
  // Paddle checkout and ordinary links go to the system browser instead.
  assert.equal(route('https://pay.paddle.io/hsc_01?_ptxn=txn_1'), 'external');
  assert.equal(route('https://github.com/tanmayv/heimdall-agent-manager'), 'external');
  assert.equal(route('mailto:support@example.com'), 'external');
  // Never opened anywhere.
  for (const refused of ['file:///etc/passwd', 'http://example.com/', 'smb://evil.example/s', 'javascript:alert(1)', 'not a url']) {
    assert.equal(route(refused), 'block', refused);
    assert.equal(route(refused, { inAuthRedirect: true }), 'block', refused);
  }
  // Without a known provider origin, sign-in still works through the redirect chain.
  assert.equal(route('https://auth.brolabs.ai/flow', { idpOrigin: '' }), 'external');
  assert.equal(route('https://auth.brolabs.ai/flow', { idpOrigin: '', inAuthRedirect: true }), 'auth');
});

test('REQ-NAV-ROUTE-1: auth redirect chains start only at the Hub sign-in/sign-out routes', () => {
  assert.equal(externalUrl.isAuthStartUrl('https://heimdall.brolabs.ai/api/v1/auth/login?return_to=%2F', NAV.uiOrigin), true);
  assert.equal(externalUrl.isAuthStartUrl('https://heimdall.brolabs.ai/api/v1/auth/logout', NAV.uiOrigin), true);
  assert.equal(externalUrl.isAuthStartUrl('https://heimdall.brolabs.ai/settings', NAV.uiOrigin), false);
  assert.equal(externalUrl.isAuthStartUrl('https://evil.example/api/v1/auth/login', NAV.uiOrigin), false);
  assert.equal(externalUrl.idpOriginFromAuthConfig({ data: { logout_url: 'https://auth.brolabs.ai/application/o/heimdall/end-session/' } }), 'https://auth.brolabs.ai');
  assert.equal(externalUrl.idpOriginFromAuthConfig({ data: { logout_url: '' } }), '');
  assert.equal(externalUrl.idpOriginFromAuthConfig({ data: { logout_url: 'http://auth.example/end' } }), '');
});

test('REQ-NAV-ROUTE-2: the OIDC window stays on https: or the Hub UI and opens no popups', () => {
  assert.equal(externalUrl.oidcWindowNavigationAllowed('https://accounts.google.com/signin', NAV.uiOrigin), true);
  assert.equal(externalUrl.oidcWindowNavigationAllowed('http://127.0.0.1:5173/', 'http://127.0.0.1:5173'), true);
  for (const refused of ['http://evil.example/', 'file:///etc/passwd', 'javascript:alert(1)']) {
    assert.equal(externalUrl.oidcWindowNavigationAllowed(refused, NAV.uiOrigin), false, refused);
  }
  assert.match(mainSource, /loginWindow\.webContents\.setWindowOpenHandler\([\s\S]*?return \{ action: 'deny' \};/);
  assert.match(mainSource, /loginWindow\.webContents\.on\('will-navigate', guardOidcNavigation\)/);
  assert.match(mainSource, /loginWindow\.webContents\.on\('will-redirect', guardOidcNavigation\)/);
  assert.match(mainSource, /if \(route === 'auth'\) openOidcWindow\(url, win\);\s*else if \(route === 'external'\) void shell\.openExternal\(allowedExternalUrl\(url\)\);/);
});

test('REQ-BRIDGE-STATUS-ASYNC-1: getStatus reads only files and the probe cache', (t) => {
  enrolledBridgeHome(t);
  const sync = childProcess.spawnSync as any;
  const before = sync.mock.calls.length;
  t.mock.method(childProcess, 'execFile', () => { throw new Error('getStatus must not start a probe'); });

  const status = bridgeManager.getStatus('https://hub.example');

  assert.equal(sync.mock.calls.length, before, 'no synchronous child process');
  assert.equal(status.installed, true);
  assert.equal(status.enrolled, true);
});

test('REQ-BRIDGE-STATUS-ASYNC-1: refreshStatus probes asynchronously, caches, and shares concurrent probes', async (t) => {
  enrolledBridgeHome(t);
  let release: () => void = () => {};
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const probes: string[][] = [];
  t.mock.method(childProcess, 'execFile', (command: string, args: string[], _options: any, callback: any) => {
    probes.push([command, ...args]);
    void gate.then(() => callback(null, command.endsWith('ham-bridge') ? 'ham-bridge v0.5.16 (abc)\n' : '', ''));
    return new EventEmitter();
  });

  const first = bridgeManager.refreshStatus('https://hub.example');
  const second = bridgeManager.refreshStatus('https://hub.example/');
  // A slow probe never blocks readers: the cached status is served meanwhile.
  assert.equal(bridgeManager.getStatus('https://hub.example').serviceState, 'stopped');
  release();
  const [a, b] = await Promise.all([first, second]);

  assert.equal(probes.length, 2, 'one launchctl print and one --version for both callers');
  assert.equal(probes[0][0], '/bin/launchctl');
  assert.equal(a.serviceState, 'running');
  assert.equal(a.installedVersion, '0.5.16');
  assert.deepEqual(a, b);
  assert.equal(bridgeManager.getStatus('https://hub.example').serviceState, 'running');
});

test('REQ-BRIDGE-STATUS-ASYNC-1: the tray and renderer are fed by one async poller', () => {
  const getStatusStart = managerSource.indexOf('function getStatus(');
  const getStatusBody = managerSource.slice(getStatusStart, managerSource.indexOf('\n}\n', getStatusStart));
  assert.doesNotMatch(getStatusBody, /spawnSync|execFile/);
  assert.match(mainSource, /trayRefreshTimer = setInterval\(\(\) => \{ void refreshBridgeStatus\(\); \}, 15_000\)/);
  assert.match(mainSource, /ipcMain\.handle\('heimdall-bridge:get-status', \(\) => bridgeManager\.getStatus\(/);
});

test('REQ-BTOP-1 (#7): an installed Bridge is not reported as an error when packaged resources are missing', async (t) => {
  enrolledBridgeHome(t);
  const previous = process.env.HEIMDALL_BRIDGE_RESOURCES;
  process.env.HEIMDALL_BRIDGE_RESOURCES = path.join(os.tmpdir(), 'heimdall-no-bridge-resources');
  t.after(() => { if (previous === undefined) delete process.env.HEIMDALL_BRIDGE_RESOURCES; else process.env.HEIMDALL_BRIDGE_RESOURCES = previous; });
  t.mock.method(childProcess, 'execFile', (_command: string, _args: string[], _options: any, callback: any) => {
    setImmediate(() => callback(null, 'ham-bridge v0.5.16\n', ''));
    return new EventEmitter();
  });

  const status = await bridgeManager.refreshStatus('https://hub.example');

  assert.equal(status.packaged, false);
  assert.equal(status.error, '');
  assert.deepEqual(desktopBridgeStatusLabel(status), { label: 'Bridge online', tone: 'success' });
});

test('REQ-BTOP-1 (#7): missing packaged resources are still an error when nothing is installed', (t) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'heimdall-bridge-empty-home-'));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  t.mock.method(os, 'homedir', () => home);
  const platform = Object.getOwnPropertyDescriptor(process, 'platform')!;
  Object.defineProperty(process, 'platform', { ...platform, value: 'darwin' });
  t.after(() => Object.defineProperty(process, 'platform', platform));
  const previous = process.env.HEIMDALL_BRIDGE_RESOURCES;
  process.env.HEIMDALL_BRIDGE_RESOURCES = path.join(home, 'missing');
  t.after(() => { if (previous === undefined) delete process.env.HEIMDALL_BRIDGE_RESOURCES; else process.env.HEIMDALL_BRIDGE_RESOURCES = previous; });

  const status = bridgeManager.getStatus('https://hub.example');

  assert.equal(status.installed, false);
  assert.match(status.error, /packaged Bridge resources are incomplete/);
});

test('REQ-BTOP-1 (#8): the popover never labels the bundled version as installed', () => {
  assert.match(statusSource, /\? \(desktop\.installed \? desktop\.installedVersion : ''\)/);
  assert.doesNotMatch(statusSource, /desktop\.installedVersion \|\| desktop\.bundledVersion/);
  assert.match(statusSource, /Packaged version v\{desktop\.bundledVersion\}/);
});

test('REQ-ENROLL-LOG-1: enrollment output is kept in a log and a failure names it', async (t) => {
  const { home } = enrolledBridgeHome(t);
  t.mock.method(childProcess, 'spawn', (_command: string, _args: string[]) => {
    const proc: any = new EventEmitter();
    proc.stdout = new EventEmitter();
    proc.stderr = new EventEmitter();
    proc.pid = 5151;
    proc.kill = () => true;
    setImmediate(() => {
      proc.stdout.emit('data', Buffer.from('Open https://hub.example/api/v1/device/add\nand type QESF-BO6G-XSJX-4E\n'));
      proc.stderr.emit('data', Buffer.from('\x1b[31m  waiting up to 45s for encrypted vault delivery…\x1b[0m\nbridge enroll FAILED: the Hub WebSocket did not connect\n'));
      proc.emit('close', 4);
    });
    return proc;
  });
  const done = new Promise<any>((resolve) => {
    bridgeManager.startEnrollment('https://hub.example', (event: any) => { if (event.type === 'error') resolve(event); });
  });
  const event = await done;

  const logPath = path.join(home, '.local', 'share', 'heimdall', 'bridges', 'heimdall-bridge-hub-example', 'logs', 'enroll.log');
  assert.equal(event.logPath, logPath);
  assert.equal(event.summary, 'bridge enroll FAILED: the Hub WebSocket did not connect');
  assert.match(event.message, /bridge enroll FAILED: the Hub WebSocket did not connect/);
  assert.doesNotMatch(event.message, /\x1b\[/, 'terminal colour codes are stripped');
  assert.ok(event.message.endsWith(`Full log: ${logPath}`));
  // The stream flushes asynchronously after close.
  for (let i = 0; i < 50 && !(fs.existsSync(logPath) && fs.readFileSync(logPath, 'utf8').includes('# exit status 4')); i++) await new Promise((r) => setTimeout(r, 10));
  const log = fs.readFileSync(logPath, 'utf8');
  assert.match(log, /^# Heimdall Bridge enrollment .* \(https:\/\/hub\.example\)\n/);
  assert.match(log, /QESF-BO6G-XSJX-4E/);
  assert.match(log, /bridge enroll FAILED/);
  assert.match(log, /# exit status 4\n$/);
  assert.equal(fs.statSync(logPath).mode & 0o777, 0o600);
});

test('REQ-ENROLL-LOG-1: the tray summarizes a failure on one line and offers the log', () => {
  assert.match(mainSource, /trayOperationMessage = String\(payload\?\.summary \|\| payload\?\.message \|\| 'Bridge enrollment failed\.'\)\.split\('\\n'\)\[0\];/);
  assert.match(mainSource, /label: 'Show Enrollment Log', click: \(\) => \{ shell\.showItemInFolder\(trayEnrollmentLog\); \}/);
});
