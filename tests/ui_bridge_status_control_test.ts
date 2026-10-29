// REQ-ENR-5/6/9/10/12, F24-F28, REQ-OIDC-DESKTOP-1, REQ-EXT-URL-1, REQ-NAV-ROUTE-1/2
// RUN: node --test tests/ui_bridge_status_control_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import childProcess from 'node:child_process';
import crypto from 'node:crypto';
import { EventEmitter } from 'node:events';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { initialWizard, reduceWizard, startWizard, wizardStepFor } from '../src/ui/bridge/desktopBridge.ts';
import bridgeManager from '../src/ui/electron/bridgeManager.cts';
import externalUrl from '../src/ui/electron/externalUrl.cts';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const preloadSource = fs.readFileSync(path.join(ROOT, 'src/ui/electron/preload.cts'), 'utf8');
const mainSource = fs.readFileSync(path.join(ROOT, 'src/ui/electron/main.cts'), 'utf8');
const managerSource = fs.readFileSync(path.join(ROOT, 'src/ui/electron/bridgeManager.cts'), 'utf8');
const updaterSource = fs.readFileSync(path.join(ROOT, 'src/ui/electron/desktopUpdater.cts'), 'utf8');
const authGateSource = fs.readFileSync(path.join(ROOT, 'src/ui/components/ElectronDeviceAuthGate.tsx'), 'utf8');
const badgeSource = fs.readFileSync(path.join(ROOT, 'src/ui/components/shell/SidebarUpdateBadge.tsx'), 'utf8');
const builderSource = fs.readFileSync(path.join(ROOT, 'electron-builder.yml'), 'utf8');
const windowsSocketSource = fs.readFileSync(path.join(ROOT, 'src/bridge/os_platform_windows.odin'), 'utf8');
const releaseWorkflowSource = fs.readFileSync(path.join(ROOT, '.github/workflows/release-local-binaries.yml'), 'utf8');

const HUB = { hub: 'https://hub.example', profile: '' };

type SpawnCall = { command: string; args: string[]; proc: any };

// Fakes ham-bridge. `status` answers with `statusFor()`; any other command runs
// `script(call)`, which may emit output and close the process (or leave it
// running). process.kill is stubbed so a cancel never signals a real process.
function fakeHamBridge(t: any, script: (call: SpawnCall) => void, statusFor: () => any = () => ({ installed: false, state: 'not_installed' })): SpawnCall[] {
  const calls: SpawnCall[] = [];
  const previous = process.env.HEIMDALL_HAM_BRIDGE;
  process.env.HEIMDALL_HAM_BRIDGE = '/opt/fake/ham-bridge';
  t.after(() => { if (previous === undefined) delete process.env.HEIMDALL_HAM_BRIDGE; else process.env.HEIMDALL_HAM_BRIDGE = previous; });
  const procs = new Map<number, any>();
  t.mock.method(childProcess, 'spawn', (command: string, args: string[]) => {
    const proc: any = new EventEmitter();
    proc.stdout = new EventEmitter();
    proc.stderr = new EventEmitter();
    proc.pid = 90000 + calls.length;
    proc.exitCode = null;
    proc.kill = () => { setImmediate(() => proc.emit('close', null)); return true; };
    procs.set(proc.pid, proc);
    const call = { command, args, proc };
    calls.push(call);
    setImmediate(() => {
      if (args[0] === 'status' || args[0] === 'list') {
        const status = statusFor();
        // A string is printed as-is (e.g. garbage, so status --json is unreadable).
        proc.stdout.emit('data', typeof status === 'string' ? status : `${JSON.stringify(args[0] === 'list' ? { profiles: [status] } : status)}\n`);
        proc.emit('close', 0);
      } else script(call);
    });
    return proc;
  });
  t.mock.method(process, 'kill', (pid: number) => {
    const proc = procs.get(Math.abs(pid));
    if (!proc) throw Object.assign(new Error('ESRCH'), { code: 'ESRCH' });
    setImmediate(() => proc.emit('close', null));
    return true;
  });
  return calls;
}

const line = (value: any) => `${JSON.stringify(value)}\n`;

test('REQ-WIN-DESKTOP-2: Windows bridge listeners explicitly reject child-process inheritance', () => {
  assert.match(windowsSocketSource, /SetHandleInformation/);
  assert.match(windowsSocketSource, /win\.HANDLE_FLAG_INHERIT, 0/);
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

test('REQ-WIN-UPDATE-1: unsigned Windows releases publish digest-protected updater metadata', () => {
  assert.match(updaterSource, /require\('electron-updater'\)/);
  assert.match(updaterSource, /autoUpdater\.allowPrerelease = false/);
  assert.match(updaterSource, /autoUpdater\.checkForUpdates\(\)/);
  assert.match(updaterSource, /autoUpdater\.quitAndInstall\(false, true\)/);
  assert.match(mainSource, /desktopUpdater\.start\(desktopUpdater\.supported\(process\.platform, app\.isPackaged\)/);
  assert.match(updaterSource, /platform === 'win32' \|\| platform === 'darwin'/);
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
  // OIDC-window popups, main-window navigation, main-window popups, IPC, vetted Bridge pairing page.
  assert.deepEqual(calls, ['href', 'allowedExternalUrl(url', 'href', 'href', 'payload.url']);
  assert.match(mainSource, /if \(payload\.type === 'pairing'\) void shell\.openExternal\(payload\.url\)/);
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

test('REQ-ENR-5: Electron manages the Bridge only through ham-bridge, on macOS, Windows and Linux', () => {
  for (const platform of ['darwin', 'win32', 'linux'] as const) assert.equal(bridgeManager.supportedPlatform(platform), true, platform);
  assert.equal(bridgeManager.supportedPlatform('freebsd'), false);
  // No install scripts, service managers, PATH rewriting or state discovery of its own.
  assert.doesNotMatch(managerSource, /install\.sh|install\.ps1|enroll\.sh|enroll\.ps1|launchctl|schtasks|ScheduledTask|systemctl|PATH:|hub-url/);
  // Profile files are only named to ham-bridge enroll, never read or parsed here.
  assert.doesNotMatch(managerSource, /readFileSync\([^)]*(?:bridge-token|config\.toml|stateDir)/);
  assert.deepEqual(bridgeManager.operationArgs('setup', HUB, {}), ['setup', '--hub', 'https://hub.example', '--headless', '--json-progress']);
  // enroll has no --profile: it names the profile's own files from status --json state_dir.
  const stateDir = path.join(path.sep, 'home', 'u', '.config', 'heimdall', 'bridges', 'heimdall-bridge-hub-example_work');
  assert.deepEqual(
    bridgeManager.operationArgs('reenroll', { hub: 'https://hub.example/', profile: 'work' }, { bridgeId: 'brg_abc', stateDir, replaceOtherAccount: true }),
    ['enroll', '--hub', 'https://hub.example', '--config', path.join(stateDir, 'config.toml'), '--bridge-token-file', path.join(stateDir, 'bridge-token'),
      '--headless', '--json-progress', '--reuse-bridge', 'brg_abc', '--replace-other-account'],
  );
  assert.throws(() => bridgeManager.operationArgs('reenroll', HUB, { bridgeId: 'brg_abc' }), /state directory/);
  assert.deepEqual(bridgeManager.operationArgs('setup', HUB, { replaceOtherAccount: true }).slice(-1), ['--replace-other-account']);
  assert.deepEqual(
    bridgeManager.operationArgs('update', { hub: '', service: 'heimdall-bridge-hub-example_work' }, { bundleDir: '/cache/v1/bundle' }),
    ['update', '--bundle', '/cache/v1/bundle', '--service', 'heimdall-bridge-hub-example_work', '--json-progress'],
  );
  assert.deepEqual(
    bridgeManager.operationArgs('uninstall', HUB, { purge: true }),
    ['uninstall', '--hub', 'https://hub.example', '--purge', '--yes', '--json-progress'],
  );
  // Explicit, validated profile selection.
  assert.throws(() => bridgeManager.profileArgs({ hub: 'file:///etc' }), /valid Hub URL/);
  assert.throws(() => bridgeManager.profileArgs({ hub: 'https://hub.example', profile: 'Bad Name' }), /Profile names/);
  assert.throws(() => bridgeManager.profileArgs({ hub: '', service: 'evil; rm -rf /' }), /Invalid bridge service/);
  assert.throws(() => bridgeManager.operationArgs('reenroll', HUB, { bridgeId: 'not-a-bridge' }), /invalid/);
  assert.equal(bridgeManager.releaseTarget('linux', 'arm64'), 'linux-arm64');
  assert.equal(bridgeManager.releaseTarget('win32', 'arm64'), 'windows-amd64');
  assert.equal(bridgeManager.releaseTarget('darwin', 'x64'), 'darwin-amd64');
});

test('F25: Bridge IPC handlers reject calls from non-app origins', () => {
  const origins = ['https://heimdall.brolabs.ai'];
  assert.equal(externalUrl.trustedIpcSender('https://heimdall.brolabs.ai/settings/bridges', true, origins), true);
  assert.equal(externalUrl.trustedIpcSender('https://heimdall.brolabs.ai/x', false, origins), false, 'iframes are refused');
  for (const refused of ['https://evil.example/', 'http://heimdall.brolabs.ai/', 'https://heimdall.brolabs.ai.evil.example/', 'file:///tmp/x', 'about:blank', '', null]) {
    assert.equal(externalUrl.trustedIpcSender(refused, true, origins), false, String(refused));
  }
  // Every bridge channel goes through the guarded registration.
  assert.doesNotMatch(mainSource, /ipcMain\.handle\('heimdall-bridge:/);
  const channels = [...mainSource.matchAll(/bridgeHandler\('(heimdall-bridge:[a-z-]+)'/g)].map((match) => match[1]);
  assert.deepEqual(channels.sort(), ['heimdall-bridge:cancel', 'heimdall-bridge:get-config', 'heimdall-bridge:get-status', 'heimdall-bridge:list', 'heimdall-bridge:open-log', 'heimdall-bridge:run', 'heimdall-bridge:set-hub-url']);
  assert.match(mainSource, /event\.sender === mainWindow\.webContents/);
  assert.match(mainSource, /trustedIpcSender\(frame\?\.url, frame \? frame === event\.sender\.mainFrame : false, trustedUiOrigins\(\)\)/);
  for (const channel of channels) assert.match(preloadSource, new RegExp(`'${channel}'`), channel);
});

test('REQ-ENR-6: the Electron tray is gone and quitting the app never touches the Bridge service', () => {
  assert.doesNotMatch(mainSource, /\bTray\b|statusTray|setContextMenu|setLoginItemSettings|wasOpenedAtLogin|restartSync|stopEnrollment/);
  assert.match(mainSource, /app\.on\('window-all-closed', \(\) => \{\s*if \(process\.platform !== 'darwin'\) app\.quit\(\);/);
  assert.match(mainSource, /app\.on\('before-quit'[\s\S]*event\.preventDefault\(\)[\s\S]*bridgeManager\.stopOnQuit\(\)\.finally\(\(\) => \{ bridgeQuitHold = 'released'; app\.quit\(\); \}\)/);
  assert.doesNotMatch(managerSource, /function stopOnQuit\([^)]*\)[^}]*(?:uninstall|service|stop')/);
  assert.doesNotMatch(preloadSource, /setAuthenticatedUser|check-updates|enrollment-event/);
  // F29: the sidebar control only links to Settings > Bridges.
  assert.doesNotMatch(badgeSource, /desktopBridgeManager|installBundled|startEnrollment|pairing/);
  assert.match(badgeSource, /data-debug-id="shell-bridge-manage-btn"/);
});

test('REQ-ENR-9: setup streams --json-progress, enrollment codes and completion', async (t) => {
  let installed = false;
  const calls = fakeHamBridge(t, ({ proc, args }) => {
    assert.equal(args[0], 'setup');
    proc.stdout.emit('data', line({ step: 'lock', state: 'start', pct: 2, message: '', log: '', attempt: 1 }));
    proc.stdout.emit('data', 'Open https://hub.example/api/v1/device/add\n');
    proc.stdout.emit('data', line({ event: 'enroll_code', approval_url: 'https://hub.example/api/v1/device/add', pairing_code: 'QESF-BO6G-XSJX-4E', issue: 1 }));
    proc.stdout.emit('data', line({ step: 'enroll', state: 'ok', pct: 60, message: 'enrolled', log: '', attempt: 1 }));
    installed = true;
    proc.stdout.emit('data', line({ step: 'setup', state: 'done', pct: 100, message: 'bridge installed, enrolled and running', log: '', attempt: 0 }));
    proc.emit('close', 0);
  }, () => (installed ? { installed: true, state: 'connected', bridge_id: 'brg_x' } : { installed: false, state: 'not_installed' }));
  const events: any[] = [];
  const result = await bridgeManager.runOperation('setup', HUB, (event: any) => events.push(event));
  assert.deepEqual(result, { ok: true });
  const setup = calls.find((call) => call.args[0] === 'setup')!;
  assert.equal(setup.command, '/opt/fake/ham-bridge');
  assert.deepEqual(events.filter((e) => e.type === 'pairing'), [{ type: 'pairing', url: 'https://hub.example/api/v1/device/add', code: 'QESF-BO6G-XSJX-4E', issue: 1 }]);
  assert.deepEqual(events.filter((e) => e.type === 'progress').map((e) => `${e.step}:${e.state}`), ['lock:start', 'enroll:ok', 'setup:done']);
  assert.deepEqual(events.filter((e) => e.type === 'output').map((e) => e.message), ['Open https://hub.example/api/v1/device/add']);
  assert.equal(events.at(-1).type, 'complete');
  assert.equal(events.at(-1).status.state, 'connected');
});

test('F26: a running setup can be cancelled; a cancelled first install is rolled back', async (t) => {
  let installed = false;
  const calls = fakeHamBridge(t, ({ proc, args }) => {
    if (args[0] === 'setup') {
      installed = true; // left half-installed and still running
      proc.stdout.emit('data', line({ step: 'enroll', state: 'start', pct: 50 }));
    } else if (args[0] === 'uninstall') {
      installed = false;
      proc.emit('close', 0);
    }
  }, () => (installed ? { installed: true, state: 'not_enrolled' } : { installed: false, state: 'not_installed' }));
  const events: any[] = [];
  const running = bridgeManager.runOperation('setup', HUB, (event: any) => {
    events.push(event);
    if (event.type === 'progress' && event.step === 'enroll') assert.equal(bridgeManager.cancelOperation(), true);
  });
  const result = await running;
  assert.equal(result.ok, false);
  const error = events.find((e) => e.type === 'error');
  assert.equal(error.cancelled, true);
  assert.equal(error.rolledBack, true);
  assert.deepEqual(calls.filter((c) => c.args[0] !== 'status').map((c) => c.args.slice(0, 4).join(' ')), ['setup --hub https://hub.example --headless', 'uninstall --hub https://hub.example --purge']);
  assert.equal(bridgeManager.cancelOperation(), false, 'nothing left running');
});

test('F26: every ham-bridge process has a timeout', async (t) => {
  const saved = bridgeManager.TIMEOUTS.uninstall;
  bridgeManager.TIMEOUTS.uninstall = 30;
  t.after(() => { bridgeManager.TIMEOUTS.uninstall = saved; });
  fakeHamBridge(t, () => { /* never exits */ }, () => ({ installed: true, state: 'connected' }));
  const events: any[] = [];
  const result = await bridgeManager.runOperation('uninstall', HUB, (event: any) => events.push(event), { purge: false });
  assert.equal(result.ok, false);
  assert.equal(events.at(-1).timedOut, true);
  assert.match(events.at(-1).message, /did not finish/);
  for (const kind of ['query', 'download', 'setup', 'update', 'uninstall']) assert.ok(bridgeManager.TIMEOUTS[kind] > 0, kind);
});

test('REQ-ENR-10: only one Bridge operation runs at a time', async (t) => {
  let installed = true;
  fakeHamBridge(t, ({ proc }) => { setTimeout(() => { installed = false; proc.emit('close', 0); }, 20); }, () => ({ installed, state: installed ? 'connected' : 'not_installed' }));
  const first = bridgeManager.runOperation('uninstall', HUB, () => undefined);
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.deepEqual(await bridgeManager.runOperation('reenroll', HUB, () => undefined), { ok: false, error: 'A Bridge operation is already running.' });
  assert.equal((await first).ok, true);
});

test('REQ-ENR-10: an uninstall that exits 0 but leaves the Bridge installed is an error', async (t) => {
  const saved = bridgeManager.TIMEOUTS.uninstallSettle;
  bridgeManager.TIMEOUTS.uninstallSettle = 30;
  t.after(() => { bridgeManager.TIMEOUTS.uninstallSettle = saved; });
  // A Windows uninstall run from bin\ham-bridge.exe hands off to a %TEMP% copy
  // and exits 0 at once; here the copy never removes the profile.
  fakeHamBridge(t, ({ proc }) => proc.emit('close', 0), () => ({ installed: true, state: 'stopped' }));
  const events: any[] = [];
  const result = await bridgeManager.runOperation('uninstall', HUB, (event: any) => events.push(event), { purge: true });
  assert.equal(result.ok, false);
  assert.equal(events.some((e) => e.type === 'complete'), false);
  assert.match(events.at(-1).message, /still installed/);
  assert.equal(bridgeManager.operationRunning(), false);
});

test('REQ-ENR-6: quitting mid first-install waits for the rollback before the app exits', async (t) => {
  let installed = false;
  let uninstalled = false;
  fakeHamBridge(t, ({ proc, args }) => {
    if (args[0] === 'setup') {
      installed = true;
      proc.stdout.emit('data', line({ step: 'enroll', state: 'start', pct: 50 }));
    } else if (args[0] === 'uninstall') {
      setTimeout(() => { installed = false; uninstalled = true; proc.emit('close', 0); }, 20);
    }
  }, () => (installed ? { installed: true, state: 'not_enrolled' } : { installed: false, state: 'not_installed' }));
  let enrolling!: () => void;
  const started = new Promise<void>((resolve) => { enrolling = resolve; });
  const running = bridgeManager.runOperation('setup', HUB, (event: any) => { if (event.type === 'progress' && event.step === 'enroll') enrolling(); });
  await started;
  assert.equal(bridgeManager.operationRunning(), true);
  await bridgeManager.stopOnQuit(5_000);
  assert.equal(uninstalled, true, 'the partial install was removed before stopOnQuit settled');
  assert.equal(bridgeManager.operationRunning(), false);
  assert.equal((await running).ok, false);
});

test('REQ-ENR-6: a cancelled setup never rolls back an install whose status was unreadable', async (t) => {
  let statusCalls = 0;
  const calls = fakeHamBridge(t, ({ proc, args }) => {
    if (args[0] === 'setup') proc.stdout.emit('data', line({ step: 'enroll', state: 'start', pct: 50 }));
    else proc.emit('close', 0);
  }, () => (++statusCalls === 1 ? 'not json\n' : { installed: true, state: 'running' }));
  let enrolling!: () => void;
  const started = new Promise<void>((resolve) => { enrolling = resolve; });
  const running = bridgeManager.runOperation('setup', HUB, (event: any) => { if (event.type === 'progress' && event.step === 'enroll') enrolling(); });
  await started;
  assert.equal(bridgeManager.cancelOperation(), true);
  assert.equal((await running).ok, false);
  assert.equal(calls.some((c) => c.args[0] === 'uninstall'), false, 'an existing install must not be purged');
});

test('F25: the Hub a Bridge is set up against is never taken from the renderer', () => {
  assert.match(mainSource, /function bridgeTarget\(raw: any\) \{[\s\S]*?hub: configuredHubApiBaseUrl\(\),/);
  assert.match(mainSource, /'heimdall-bridge:set-hub-url'[\s\S]*?dialog\.showMessageBox\(mainWindow/);
});

test('REQ-ENR-6: the quit hold is bounded when the rollback hangs', async (t) => {
  const saved = bridgeManager.TIMEOUTS.uninstall;
  bridgeManager.TIMEOUTS.uninstall = 200;
  t.after(() => { bridgeManager.TIMEOUTS.uninstall = saved; });
  let installed = false;
  fakeHamBridge(t, ({ proc, args }) => {
    if (args[0] === 'setup') {
      installed = true;
      proc.stdout.emit('data', line({ step: 'enroll', state: 'start', pct: 50 }));
    } // the rollback uninstall never exits; only its own timeout ends it
  }, () => (installed ? { installed: true, state: 'not_enrolled' } : { installed: false, state: 'not_installed' }));
  let enrolling!: () => void;
  const started = new Promise<void>((resolve) => { enrolling = resolve; });
  const running = bridgeManager.runOperation('setup', HUB, (event: any) => { if (event.type === 'progress' && event.step === 'enroll') enrolling(); });
  await started;
  const begin = Date.now();
  await bridgeManager.stopOnQuit(20);
  assert.ok(Date.now() - begin < 150, 'stopOnQuit gave up after waitMs');
  assert.equal(bridgeManager.operationRunning(), true, 'the rollback was still running');
  assert.equal((await running).ok, false);
  assert.equal(await bridgeManager.stopOnQuit(10), undefined, 'nothing running resolves at once');
});

// A real tar.gz release bundle containing bin/ham-bridge, plus its SHA256SUMS.
function releaseFixture(t: any, version: string) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'heimdall-release-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const target = bridgeManager.releaseTarget('linux', process.arch);
  fs.mkdirSync(path.join(dir, 'src', 'heimdall-local', 'bin'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'src', 'heimdall-local', 'bin', 'ham-bridge'), '#!/bin/sh\n', { mode: 0o755 });
  const archive = `heimdall-local-${target}-${version}.tar.gz`;
  childProcess.execFileSync('tar', ['-czf', path.join(dir, archive), '-C', path.join(dir, 'src'), 'heimdall-local']);
  const bytes = fs.readFileSync(path.join(dir, archive));
  const sums = `${crypto.createHash('sha256').update(bytes).digest('hex')}  ${archive}\n`;
  return { dir, target, archive, bytes, sums };
}

test('F27: setup downloads and SHA-256-verifies the latest promoted release', { skip: process.platform !== 'linux' }, async (t) => {
  const fixture = releaseFixture(t, 'v9.1.0');
  process.env.HEIMDALL_BRIDGE_CACHE = path.join(fixture.dir, 'cache');
  t.after(() => { delete process.env.HEIMDALL_BRIDGE_CACHE; });
  const releases = [
    { tag_name: 'v9.2.0', prerelease: true, assets: [{ name: fixture.archive.replace('v9.1.0', 'v9.2.0') }, { name: 'SHA256SUMS' }] },
    { tag_name: 'v9.1.0', assets: [{ name: fixture.archive }, { name: 'SHA256SUMS' }] },
  ];
  assert.equal(bridgeManager.latestRelease(releases, fixture.target, 'linux'), 'v9.1.0');
  const fetched: string[] = [];
  const fetchImpl = async (url: string) => {
    fetched.push(url);
    if (url.includes('/releases?')) return Response.json(releases);
    if (url.endsWith('/SHA256SUMS')) return new Response(fixture.sums);
    if (url.endsWith(fixture.archive)) return new Response(fixture.bytes);
    return new Response('', { status: 404 });
  };
  const events: any[] = [];
  const prepared = await bridgeManager.prepareBinary((e: any) => events.push(e), () => undefined, { fetchImpl });
  assert.equal(prepared.source, 'release');
  assert.equal(prepared.version, '9.1.0');
  assert.ok(prepared.binary.endsWith(path.join('bin', 'ham-bridge')) && fs.existsSync(prepared.binary));
  assert.equal(fetched.length, 3);
  // A tampered download is refused, and the bundled fallback is used only when it exists.
  const tampered = async (url: string) => (url.endsWith(fixture.archive) ? new Response(Buffer.from('evil')) : fetchImpl(url));
  fs.rmSync(path.join(fixture.dir, 'cache'), { recursive: true, force: true });
  process.env.HEIMDALL_BRIDGE_RESOURCES = path.join(fixture.dir, 'no-bundle');
  t.after(() => { delete process.env.HEIMDALL_BRIDGE_RESOURCES; });
  await assert.rejects(bridgeManager.prepareBinary(() => undefined, () => undefined, { fetchImpl: tampered }), /SHA-256 mismatch/);
});

test('F27: offline, the bundled Bridge is the verified fallback', { skip: process.platform !== 'linux' }, async (t) => {
  const fixture = releaseFixture(t, 'v9.0.0');
  const resources = path.join(fixture.dir, 'resources');
  fs.mkdirSync(resources);
  const bundled = `heimdall-local-${fixture.target}.tar.gz`;
  fs.copyFileSync(path.join(fixture.dir, fixture.archive), path.join(resources, bundled));
  fs.writeFileSync(path.join(resources, 'SHA256SUMS'), fixture.sums.replace(fixture.archive, bundled));
  fs.writeFileSync(path.join(resources, 'METADATA.json'), '{"version":"v9.0.0"}');
  process.env.HEIMDALL_BRIDGE_RESOURCES = resources;
  process.env.HEIMDALL_BRIDGE_CACHE = path.join(fixture.dir, 'cache');
  t.after(() => { delete process.env.HEIMDALL_BRIDGE_RESOURCES; delete process.env.HEIMDALL_BRIDGE_CACHE; });
  const events: any[] = [];
  const prepared = await bridgeManager.prepareBinary((e: any) => events.push(e), () => undefined, { fetchImpl: async () => { throw new Error('offline'); } });
  assert.equal(prepared.source, 'bundled');
  assert.equal(prepared.version, '9.0.0');
  assert.ok(fs.existsSync(prepared.binary));
  assert.ok(events.some((e) => e.step === 'download' && e.state === 'retry' && /offline/.test(e.message)));
});

test('REQ-ENR-12: the wizard shows automatic recovery inline and offers Retry only once it is exhausted', () => {
  assert.equal(wizardStepFor('ports'), 'install');
  assert.equal(wizardStepFor('extensions'), 'providers');
  let model = startWizard();
  model = reduceWizard(model, { type: 'progress', step: 'download', state: 'ok', pct: 100, message: 'downloaded' });
  model = reduceWizard(model, { type: 'progress', step: 'ports', state: 'start', pct: 40 });
  model = reduceWizard(model, { type: 'progress', step: 'ports', state: 'retry', pct: 41, failure: 'port_in_use', message: 'moved to ports 49327/49328' });
  const install = model.steps.find((s) => s.id === 'install')!;
  assert.equal(install.state, 'recovering');
  assert.deepEqual(install.recoveries, ['moved to ports 49327/49328']);
  model = reduceWizard(model, { type: 'progress', step: 'verify', state: 'retry', pct: 88, failure: 'port_in_use', message: 'still waiting for the port' });
  assert.equal(model.steps.find((s) => s.id === 'install')!.state, 'ok', 'verify belongs to the last row');
  assert.equal(model.steps.find((s) => s.id === 'done')!.state, 'recovering');
  assert.equal(model.canRetry, false, 'no manual retry while ham-bridge is still recovering');
  assert.equal(model.steps.find((s) => s.id === 'download')!.state, 'ok');
  model = reduceWizard(model, { type: 'progress', step: 'verify', state: 'failed', pct: 88, failure: 'port_in_use', message: 'still busy', log: '/x/heimdall/bridges/s/logs/bridge.err.log' });
  model = reduceWizard(model, { type: 'progress', step: 'verify', state: 'rollback', pct: 88 });
  model = reduceWizard(model, { type: 'error', message: 'still busy', step: 'verify' });
  assert.equal(model.failedStep, 'done');
  assert.equal(model.canRetry, true);
  assert.equal(model.rolledBack, true);
  assert.equal(model.steps.find((s) => s.id === 'done')!.log, '/x/heimdall/bridges/s/logs/bridge.err.log');
  const cancelled = reduceWizard(startWizard(), { type: 'error', message: 'Cancelled.', cancelled: true, rolledBack: true });
  assert.equal(cancelled.canRetry, false);
  const done = reduceWizard(reduceWizard(initialWizard(), { type: 'pairing', url: 'https://hub/api/v1/device/add', code: 'AAAA-BBBB-CCCC-DD' }), { type: 'complete' });
  assert.equal(done.completed, true);
  assert.equal(done.pairing, null);
  assert.ok(done.steps.every((s) => s.state === 'ok'));
});

test('REQ-ENR-9: wizard rows finish in order (start/verify after Enroll and Providers)', () => {
  const states = (model: any) => model.steps.map((s: any) => `${s.id}:${s.state}`).join(' ');
  let model = startWizard();
  const order = ['download', 'lock', 'stage', 'binaries', 'config', 'ports', 'service', 'enroll', 'extensions', 'start', 'verify'];
  const seen: string[] = [];
  for (const step of order) {
    model = reduceWizard(model, { type: 'progress', step, state: 'start' });
    model = reduceWizard(model, { type: 'progress', step, state: 'ok' });
    seen.push(states(model));
  }
  assert.equal(seen[order.indexOf('service')], 'download:ok install:ok enroll:pending providers:pending done:pending');
  assert.equal(seen[order.indexOf('extensions')], 'download:ok install:ok enroll:ok providers:ok done:pending');
  assert.equal(seen[order.indexOf('start')], 'download:ok install:ok enroll:ok providers:ok done:running');
  assert.equal(seen.at(-1), 'download:ok install:ok enroll:ok providers:ok done:ok');
  // No row ever goes back from ok.
  const rank: Record<string, number> = { pending: 0, running: 1, recovering: 1, ok: 2, skipped: 2, failed: 2 };
  for (let i = 1; i < seen.length; i += 1) {
    const prev = seen[i - 1].split(' ').map((x) => rank[x.split(':')[1]]);
    seen[i].split(' ').forEach((x, j) => assert.ok(rank[x.split(':')[1]] >= prev[j], `${order[i]}: ${seen[i]}`));
  }
});

test('REQ-ENR-9: enrollment output still yields the canonical 14-symbol pairing code', () => {
  assert.deepEqual(
    bridgeManager.extractEnrollmentPairing(`Open https://heimdall.example/api/v1/device/add\nand type QESF-BO6G-XSJX-4E\n`),
    { url: 'https://heimdall.example/api/v1/device/add', code: 'QESF-BO6G-XSJX-4E' },
  );
  assert.equal(bridgeManager.extractEnrollmentPairing('https://heimdall.example/api/v1/device/add ABCD-EFGH-IJKL-MNOP'), null);
  assert.equal(bridgeManager.parseProgressLine('not json'), null);
  assert.equal(bridgeManager.parseProgressLine('[1,2]'), null);
  assert.deepEqual(bridgeManager.parseProgressLine(' {"step":"lock","state":"ok"} '), { step: 'lock', state: 'ok' });
});

test('F24: desktopCapabilities is the one desktop check; no odinApi.deviceAuth remains', () => {
  const probes: string[] = [];
  const walk = (dir: string) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) { if (entry.name !== 'electron') walk(full); continue; }
      if (!/\.tsx?$/.test(entry.name)) continue;
      const source = fs.readFileSync(full, 'utf8');
      assert.doesNotMatch(source, /odinApi\??\.deviceAuth/, full);
      if (/\bodinApi\b/.test(source)) probes.push(path.relative(ROOT, full));
    }
  };
  walk(path.join(ROOT, 'src/ui'));
  assert.deepEqual(probes, ['src/ui/bridge/desktopBridge.ts']);
  assert.equal(fs.existsSync(path.join(ROOT, 'src/ui/components/extension/ProviderExtensionInstallAction.tsx')), false);
});

test('F1/REQ-ENR-1: another account\'s enrollment is flagged for an explicit replace confirmation', () => {
  let model = startWizard();
  model = reduceWizard(model, { type: 'output', message: 'bridge enroll REFUSED: this machine is enrolled as brg_old by another Heimdall account; nothing was written.' });
  model = reduceWizard(model, { type: 'error', message: 'enrollment did not complete', step: 'enroll' });
  assert.equal(model.otherAccount, true);
  assert.equal(reduceWizard(startWizard(), { type: 'output', message: 'Open https://hub/api/v1/device/add' }).otherAccount, false);
  const card = fs.readFileSync(path.join(ROOT, 'src/ui/components/settings/ThisMachineCard.tsx'), 'utf8');
  assert.match(card, /settings-bridge-wizard-replace-account[\s\S]*replaceOtherAccount: true/);
  assert.match(fs.readFileSync(path.join(ROOT, 'src/bridge/setup_cmd.odin'), 'utf8'), /has_flag\(s\.args, "--replace-other-account"\) do append\(&argv, "--replace-other-account"\)/);
});
