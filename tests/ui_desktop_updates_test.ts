import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { EventEmitter } from 'node:events';
import { transformSync } from 'esbuild';

const require = createRequire(import.meta.url);
function load(name: string) {
  const module = { exports: {} as any };
  const source = fs.readFileSync(new URL(`../src/ui/electron/${name}.cts`, import.meta.url), 'utf8');
  vm.runInNewContext(transformSync(source, { loader: 'ts', format: 'cjs' }).code,
    { module, exports: module.exports, require, setTimeout, clearTimeout, setInterval, clearInterval, Date });
  return module.exports;
}
const { evaluatePolicy, readEligibility, windowsInstalled } = load('desktopUpdatePolicy');
const { createDesktopUpdateController } = load('desktopUpdateController');
const { createMacUpdateInstall } = load('macUpdateInstall');

function clock() {
  let now = 1000;
  const timeouts = new Map<any, () => void>();
  const intervals = new Map<any, () => void>();
  return { now: () => now, advance: () => { now += 251; },
    setTimeout: (fn: () => void, ms: number) => { const id = {}; timeouts.set(id, fn); return id; },
    setInterval: (fn: () => void, ms: number) => { const id = {}; intervals.set(id, fn); return id; },
    clearTimeout: (id: any) => timeouts.delete(id), clearInterval: (id: any) => intervals.delete(id),
    timeouts, intervals };
}
const base = () => ({ platform: 'darwin', arch: 'arm64', isPackaged: true, currentVersion: '1.2.3',
  executable: '/Applications/Ninjy.app/Contents/MacOS/Ninjy', resources: '/Applications/Ninjy.app/Contents/Resources',
  writable: true, policy: { schemaVersion: 1, distribution: 'mac-app', updatesEnabled: true },
  feed: { provider: 'github', owner: 'tanmayv', repo: 'heimdall-agent-manager' } });

test('signed build policy fails closed for immutable, unknown, unsigned and malformed installs', () => {
  assert.equal(evaluatePolicy(base()).supported, true);
  for (const patch of [ { platform: 'linux' }, { isPackaged: false }, { arch: 'ia32' },
    { executable: '/nix/store/a/Ninjy' }, { resources: '/nix/store/a/resources' },
    { executable: '/Volumes/Ninjy/Ninjy.app/Contents/MacOS/Ninjy' }, { writable: false }, { policy: null },
    { policy: { ...base().policy, schemaVersion: 2 } }, { policy: { ...base().policy, updatesEnabled: false } },
    { policy: { ...base().policy, url: 'https://evil.invalid' } },
    { feed: { ...base().feed, owner: 'other' } }, { feed: { ...base().feed, token: 'secret' } },
    { feed: { ...base().feed, private: true } }, { feed: { ...base().feed, requestHeaders: { Authorization: 'secret' } } } ]) {
    assert.equal(evaluatePolicy({ ...base(), ...patch }).supported, false, JSON.stringify(patch));
  }
});

test('Windows requires NSIS policy and exact nonempty publisher configuration', () => {
  const input = { ...base(), platform: 'win32', arch: 'x64',
    installed: true,
    policy: { ...base().policy, distribution: 'windows-nsis', publisherName: ['Verified Publisher'] },
    feed: { ...base().feed, publisherName: 'Verified Publisher' } };
  assert.equal(evaluatePolicy(input).supported, true);
  assert.equal(evaluatePolicy({ ...input, installed: false }).supported, false);
  for (const feed of [base().feed, { ...input.feed, publisherName: 'Different Publisher' },
    { ...input.feed, verifyUpdateCodeSignature: false }]) assert.equal(evaluatePolicy({ ...input, feed }).supported, false);
  assert.equal(evaluatePolicy({ ...input, policy: { ...input.policy, publisherName: [] } }).supported, false);
});

test('Windows rejects copied/unregistered apps and resolves only its own installed NSIS location', () => {
  const env = { SystemRoot: 'C:\\Windows' };
  const executable = 'C:\\Users\\fixture\\AppData\\Local\\Programs\\Ninjy\\Ninjy.exe';
  const registered = '    InstallLocation    REG_SZ    C:\\Users\\fixture\\AppData\\Local\\Programs\\Ninjy\r\n';
  assert.equal(windowsInstalled(executable, env, () => registered, () => true), true);
  assert.equal(windowsInstalled('C:\\Portable\\Ninjy.exe', env, () => registered, () => true), false);
  assert.equal(windowsInstalled(executable, env, () => { throw new Error('no key'); }, () => true), false);
  assert.equal(windowsInstalled(executable, env, () => registered, () => false), false);
});

test('packaged resource policy and feed are read independently of writable-install eligibility', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ninjy-resource-policy-'));
  const resources = path.join(directory, 'Ninjy.app/Contents/Resources');
  const executable = path.join(directory, 'Ninjy.app/Contents/MacOS/Ninjy');
  fs.mkdirSync(resources, { recursive: true }); fs.mkdirSync(path.dirname(executable)); fs.writeFileSync(executable, 'fixture');
  const app = { isPackaged: true, getVersion: () => '1.2.3', getPath: () => executable };
  const runtime = { platform: 'darwin', arch: 'arm64', resourcesPath: resources };
  try {
    assert.equal(readEligibility(app, runtime).reason, 'missing-policy');
    fs.writeFileSync(path.join(resources, 'desktop-update-policy.json'), JSON.stringify(base().policy));
    assert.equal(readEligibility(app, runtime).reason, 'invalid-feed');
    fs.writeFileSync(path.join(resources, 'app-update.yml'), 'provider: github\nowner: tanmayv\nrepo: heimdall-agent-manager\n');
    assert.equal(readEligibility(app, runtime).supported, true);
    fs.writeFileSync(path.join(resources, 'app-update.yml'), 'provider: [malformed');
    assert.equal(readEligibility(app, runtime).reason, 'invalid-feed');
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});

function fixture(supported = true) {
  const updater: any = new EventEmitter();
  const time = clock();
  let calls = 0;
  let resolve: (result?: any) => void = () => {};
  let reject: (error: any) => void = () => {};
  updater.checkForUpdates = () => { calls++; return new Promise((yes, no) => { resolve = yes; reject = no; }); };
  const states: any[] = [];
  const controller = createDesktopUpdateController({ updater, clock: time, eligibility: { supported, currentVersion: '1.2.3', reason: 'test' }, onState: (s: any) => states.push(s) });
  return { updater, time, states, controller, calls: () => calls, resolve: (v?: any) => resolve(v), reject: (e: any) => reject(e) };
}

test('ineligible installs never subscribe, schedule or check', async () => {
  const f = fixture(false); f.controller.start(); await f.controller.check();
  assert.equal(f.calls(), 0); assert.equal(f.time.timeouts.size, 0); assert.equal(f.updater.eventNames().length, 0);
  assert.equal(f.controller.getState().phase, 'disabled');
});

test('timers, listener ownership and single flight span automatic download completion', async () => {
  const f = fixture(); f.controller.start(); f.controller.start();
  assert.equal(f.time.timeouts.size, 1); assert.equal(f.time.intervals.size, 1);
  assert.equal(f.updater.autoInstallOnAppQuit, false); assert.equal(f.updater.allowDowngrade, false);
  assert.equal(f.updater.allowPrerelease, false); assert.equal(f.updater.disableWebInstaller, true);
  const pending = f.controller.check(); await f.controller.check(); assert.equal(f.calls(), 1);
  f.updater.emit('update-available', { version: '1.2.4' });
  let finishDownload!: () => void;
  f.resolve({ downloadPromise: new Promise<void>(resolve => { finishDownload = resolve; }) });
  await Promise.resolve(); await f.controller.check(); assert.equal(f.calls(), 1);
  f.updater.emit('download-progress', { percent: NaN, total: Infinity, transferred: -1 });
  assert.equal(f.controller.getState().percent, null); assert.equal(f.controller.getState().total, null);
  f.time.advance(); f.updater.emit('download-progress', { percent: 150, total: 100, transferred: 100 });
  assert.equal(f.controller.getState().percent, 100);
  f.updater.emit('update-downloaded', { version: '1.2.4' }); finishDownload(); await pending;
  await f.controller.check(); assert.equal(f.calls(), 1, 'ready download is never replaced');
  assert.equal(f.controller.beginRestart(), true); assert.equal(f.controller.beginRestart(), false);
  f.controller.abortRestart(); assert.equal(f.controller.getState().phase, 'downloaded');
  f.controller.stop(); f.controller.stop();
  assert.equal(f.time.timeouts.size, 0); assert.equal(f.time.intervals.size, 0); assert.equal(f.updater.eventNames().length, 0);
});

test('offline, checksum and signature diagnostics never expose feed response contents', async () => {
  for (const [error, code] of [['ENOTFOUND https://host/?token=secret', 'offline'], ['sha512 secret', 'checksum'], ['publisher secret', 'signature']]) {
    const f = fixture(); f.controller.start(); const pending = f.controller.check(); f.reject(new Error(error)); await pending;
    assert.equal(f.controller.getState().errorCode, code); assert.doesNotMatch(f.controller.getState().message, /secret|https:/);
    assert.equal(f.controller.beginRestart(), false); f.controller.stop();
  }
});

test('disposed in-flight check cannot publish late events or rejection', async () => {
  const f = fixture(); f.controller.start(); const pending = f.controller.check(); f.controller.stop();
  const count = f.states.length;
  f.updater.emit('update-downloaded', { version: '1.2.4' }); f.reject(new Error('offline')); await pending;
  assert.equal(f.states.length, count);
});

test('restart of disposed controller waits for the old flight before reattaching listeners', async () => {
  const f = fixture(); f.controller.start(); const pending = f.controller.check(); f.controller.stop(); f.controller.start();
  assert.equal(f.updater.listenerCount('update-available'), 0);
  f.resolve(); await pending;
  assert.equal(f.updater.listenerCount('update-available'), 1); assert.equal(f.time.timeouts.size, 1);
  f.controller.stop();
});

test('pinned GitHubProvider ignores numeric candidates until promotion; pinned AppUpdater refuses downgrades', async () => {
  const { GitHubProvider } = require('electron-updater/out/providers/GitHubProvider.js');
  const { AppUpdater } = require('electron-updater/out/AppUpdater.js');
  const { parse } = createRequire(require.resolve('electron-updater/out/AppUpdater.js'))('semver');
  let promoted = false;
  const requested: string[] = [];
  const executor = { request: async (options: any) => {
    requested.push(options.path);
    if (options.path.endsWith('.atom')) return '<feed><entry><title>Candidate</title><link href="https://github.com/tanmayv/heimdall-agent-manager/releases/tag/v1.2.4"/><content>candidate</content></entry><entry><title>Stable</title><link href="https://github.com/tanmayv/heimdall-agent-manager/releases/tag/v1.2.3"/><content>stable</content></entry></feed>';
    if (options.path.endsWith('/latest')) return JSON.stringify({ tag_name: promoted ? 'v1.2.4' : 'v1.2.3' });
    const version = promoted ? '1.2.4' : '1.2.3';
    assert.ok(options.path.endsWith(`/v${version}/latest-mac.yml`));
    return `version: ${version}\nfiles:\n  - url: Ninjy-${version}-arm64.zip\n    sha512: fixture\n    size: 1\npath: Ninjy-${version}-arm64.zip\nsha512: fixture\n`;
  } };
  const updater = { allowPrerelease: false, currentVersion: parse('1.2.4'), fullChangelog: false, channel: null };
  const provider = new GitHubProvider({ provider: 'github', owner: 'tanmayv', repo: 'heimdall-agent-manager' }, updater, { platform: 'darwin', executor });
  const stable = await provider.getLatestVersion(); assert.equal(stable.version, '1.2.3');
  const comparison = { currentVersion: parse('1.2.4'), allowDowngrade: false, isUpdateSupported: () => true, isUserWithinRollout: () => true };
  assert.equal(await AppUpdater.prototype.isUpdateAvailable.call(comparison, stable), false);
  promoted = true; const next = await provider.getLatestVersion(); assert.equal(next.version, '1.2.4');
  comparison.currentVersion = parse('1.2.3'); assert.equal(await AppUpdater.prototype.isUpdateAvailable.call(comparison, next), true);
  assert.equal(requested.some(url => /beta|alpha/.test(url)), false);
});

function nativeFixture() {
  const native: any = new EventEmitter(); let checks = 0; let quits = 0;
  native.checkForUpdates = () => { checks++; }; native.quitAndInstall = () => { quits++; };
  const time = clock(); const adapter = createMacUpdateInstall(native, time);
  return { native, time, adapter, checks: () => checks, quits: () => quits };
}
test('macOS waits for native completion and consumes active final authorization once', async () => {
  const f = nativeFixture(); const pending = f.adapter.stage(() => true);
  assert.equal(f.checks(), 1); assert.equal(f.quits(), 0);
  f.native.emit('update-downloaded'); f.native.emit('update-downloaded'); await pending;
  assert.equal(f.quits(), 1); assert.equal(f.time.timeouts.size, 0);
  assert.equal(f.native.listenerCount('update-downloaded'), 0);
});
test('macOS error, cancellation, invalid epoch and timeout disarm late completion and quarantine retry', async () => {
  for (const abort of ['error', 'cancel', 'invalid', 'timeout']) {
    const f = nativeFixture();
    // Electron/updater owns other listeners; our cleanup must leave them intact.
    const foreign = () => {}; f.native.on('error', foreign);
    const pending = f.adapter.stage(() => abort !== 'invalid');
    const rejected = assert.rejects(pending);
    if (abort === 'error') f.native.emit('error', new Error('signature'));
    if (abort === 'cancel') f.adapter.cancel();
    if (abort === 'invalid') f.native.emit('update-downloaded');
    if (abort === 'timeout') for (const fn of f.time.timeouts.values()) fn();
    await rejected; f.native.emit('update-downloaded');
    assert.equal(f.quits(), 0, abort); assert.equal(f.adapter.quarantined(), true);
    assert.equal(f.native.listenerCount('error'), 1);
    await assert.rejects(f.adapter.stage(() => true), /Relaunch/);
    assert.equal(f.checks(), 1); assert.equal(f.time.timeouts.size, 0);
  }
});
