import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import { createRequire } from 'node:module';
import { EventEmitter } from 'node:events';
import { transformSync } from 'esbuild';
import { desktopCapabilities } from '../src/ui/bridge/desktopBridge.ts';

const require = createRequire(import.meta.url);
function load(name: string, mocks: Record<string, any> = {}, platform = 'darwin') {
  const module = { exports: {} as any };
  const source = fs.readFileSync(new URL(`../src/ui/electron/${name}.cts`, import.meta.url), 'utf8');
  vm.runInNewContext(transformSync(source, { loader: 'ts', format: 'cjs' }).code, { module, exports: module.exports,
    require: (id: string) => id in mocks ? mocks[id] : id.startsWith('./') ? load(path.basename(id, '.cjs'), mocks, platform) : require(id),
    process: { platform }, setTimeout, clearTimeout, setInterval, clearInterval, Date, URL });
  return module.exports;
}
const tick = () => new Promise(resolve => setImmediate(resolve));
function fixture(platform = 'darwin') {
  const native: any = new EventEmitter(); let stages = 0; let quits = 0; let wrapperQuits = 0;
  native.checkForUpdates = () => { stages++; }; native.quitAndInstall = () => { quits++; };
  const updater: any = new EventEmitter();
  updater.checkForUpdates = async () => { updater.emit('update-available', { version: '1.2.4' }); updater.emit('update-downloaded', { version: '1.2.4' }); return { downloadPromise: Promise.resolve() }; };
  updater.quitAndInstall = (silent: boolean, run: boolean) => { wrapperQuits++; assert.equal(silent, false); assert.equal(run, true); if (platform === 'darwin') throw new Error('MacUpdater.quitAndInstall must never run'); quits++; };
  const handlers = new Map<string, any>(); const contents: any = new EventEmitter(); const win: any = new EventEmitter();
  const sent: [string, any][] = []; let destroyed = false;
  contents.mainFrame = { url: 'https://hub.example/' }; contents.isDestroyed = () => destroyed;
  contents.send = (channel: string, data: any) => sent.push([channel, data]);
  win.webContents = contents; win.isDestroyed = () => destroyed;
  const ipcMain = { handle: (channel: string, handler: any) => handlers.set(channel, handler), removeHandler: (channel: string) => handlers.delete(channel) };
  const { installDesktopUpdates } = load('desktopUpdatesMain', {
    './desktopUpdatePolicy.cjs': { readEligibility: () => ({ supported: true, reason: 'signed-install', currentVersion: '1.2.3' }) },
    'electron-updater': { autoUpdater: updater }, 'electron': { autoUpdater: native, Notification: { isSupported: () => false } },
  }, platform);
  const integration = installDesktopUpdates({ app: {}, ipcMain, dialog: { showMessageBox: async () => ({ response: 1 }) },
    getWindow: () => win, trustedOrigins: () => ['https://hub.example'], bridgeBusy: () => false });
  integration.bindWindow(win); contents.emit('did-finish-load');
  const event = () => ({ sender: contents, senderFrame: contents.mainFrame });
  const invoke = (name: string, payload?: any, override?: any) => handlers.get('heimdall-updates:' + name)(override || event(), payload);
  const epoch = () => sent.findLast(([channel]) => channel === 'heimdall-updates:prepare')?.[1].epoch;
  return { integration, contents, win, native, updater, handlers, invoke, epoch, sent,
    stages: () => stages, quits: () => quits, wrapperQuits: () => wrapperQuits, destroy: () => { destroyed = true; contents.emit('destroyed'); } };
}

test('updater IPC rejects wrong origin, popup and child frame without invoking native updater', async () => {
  const f = fixture();
  try {
    for (const override of [ { sender: f.contents, senderFrame: { url: 'https://evil.example/' } },
      { sender: {}, senderFrame: f.contents.mainFrame }, { sender: f.contents, senderFrame: { url: 'https://hub.example/' } } ]) {
      for (const command of ['get-state', 'check', 'retry', 'restart', 'preparation-result']) assert.equal((await f.invoke(command, { epoch: 1, ready: true }, override)).ok, false);
    }
    assert.equal(f.stages(), 0); assert.equal(f.quits(), 0);
  } finally { f.integration.stop(); }
  assert.equal(f.handlers.size, 0);
});

test('stale acknowledgement cannot stage; valid document acknowledgement plus consent stages once', async () => {
  const f = fixture();
  try {
    await f.invoke('check'); const pending = f.invoke('restart'); await tick();
    assert.equal(f.integration.operationHeld(), true);
    await f.invoke('preparation-result', { epoch: f.epoch() - 1, ready: true }); await tick(); assert.equal(f.stages(), 0);
    await f.invoke('preparation-result', { epoch: f.epoch(), ready: true }); await tick(); assert.equal(f.stages(), 1); assert.equal(f.quits(), 0);
    f.native.emit('update-downloaded'); assert.equal((await pending).ok, true);
    f.native.emit('update-downloaded'); assert.equal(f.quits(), 1); assert.equal(f.wrapperQuits(), 0);
  } finally { f.integration.stop(); }
});

test('navigation, renderer loss and loss of freeze disarm delayed staging and release exclusion', async () => {
  for (const invalidation of ['navigation', 'crash', 'freeze', 'beforeunload']) {
    const f = fixture();
    try {
      await f.invoke('check'); const pending = f.invoke('restart'); await tick();
      await f.invoke('preparation-result', { epoch: f.epoch(), ready: true }); await tick();
      assert.equal(f.stages(), 1);
      if (invalidation === 'navigation') f.contents.emit('did-start-navigation', {}, 'https://hub.example/next', false, true);
      if (invalidation === 'crash') f.contents.emit('render-process-gone');
      if (invalidation === 'freeze') await f.invoke('preparation-result', { epoch: f.epoch(), ready: false });
      if (invalidation === 'beforeunload') f.contents.emit('will-prevent-unload');
      assert.equal((await pending).ok, false); f.native.emit('update-downloaded');
      assert.equal(f.quits(), 0); assert.equal(f.integration.operationHeld(), false);
      assert.ok(f.sent.some(([channel]) => channel === 'heimdall-updates:release'));
    } finally { f.integration.stop(); }
  }
});

test('Windows uses NSIS restart only after held preparation and explicit confirmation', async () => {
  const f = fixture('win32');
  try {
    await f.invoke('check'); assert.equal(f.quits(), 0);
    const pending = f.invoke('restart'); await tick(); assert.equal(f.quits(), 0);
    await f.invoke('preparation-result', { epoch: f.epoch(), ready: true });
    assert.equal((await pending).ok, true); assert.equal(f.wrapperQuits(), 1); assert.equal(f.stages(), 0);
    assert.equal(f.integration.operationHeld(), true, 'held until final exit');
    f.updater.emit('error', new Error('late native error'));
    assert.equal(f.integration.operationHeld(), true, 'a late error does not prove quit was cancelled');
    f.contents.emit('will-prevent-unload');
    assert.equal(f.integration.operationHeld(), false, 'known unload veto releases editing');
  } finally { f.integration.stop(); }
});

test('old or incomplete preload exposes no updater capability', () => {
  const saved = (globalThis as any).window;
  try {
    for (const api of [null, {}, { desktopUpdates: { schemaVersion: 1, getState() {} } }, { desktopUpdates: { schemaVersion: 2 } }]) {
      (globalThis as any).window = { odinApi: api };
      assert.equal(desktopCapabilities().desktopUpdates, null);
    }
  } finally { (globalThis as any).window = saved; }
});

test('actual pinned MacUpdater constructor listeners do not acquire the persistent quit callback through our adapter', async () => {
  const file = require.resolve('electron-updater/out/MacUpdater.js');
  const localRequire = createRequire(file); const module = { exports: {} as any };
  const native: any = new EventEmitter(); let quits = 0;
  native.checkForUpdates = () => {}; native.quitAndInstall = () => { quits++; };
  vm.runInNewContext(fs.readFileSync(file, 'utf8'), { module, exports: module.exports,
    require: (id: string) => id === 'electron' ? { autoUpdater: native } : localRequire(id),
    process, console, setTimeout, clearTimeout, Buffer });
  const wrapper = new module.exports.MacUpdater(null, { version: '1.2.3' });
  wrapper.logger = { info() {}, warn() {}, error() {}, debug() {} }; wrapper.autoInstallOnAppQuit = false;
  assert.equal(native.listenerCount('update-downloaded'), 1, 'constructor records completion only');
  const { createMacUpdateInstall } = load('macUpdateInstall');
  const adapter = createMacUpdateInstall(native);
  const pending = adapter.stage(() => true); const rejected = assert.rejects(pending);
  native.emit('error', new Error('staging failed')); await rejected;
  native.emit('update-downloaded');
  assert.equal(wrapper.squirrelDownloadedUpdate, true); assert.equal(quits, 0);
  assert.equal(native.listenerCount('update-downloaded'), 1, 'persistent quit listener was never registered');
});
