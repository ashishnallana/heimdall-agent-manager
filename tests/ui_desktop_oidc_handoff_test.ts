import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { transformSync } from 'esbuild';

const mainSource = fs.readFileSync(new URL('../src/ui/electron/main.cts', import.meta.url), 'utf8');
const configSource = fs.readFileSync(new URL('../src/ui/electron/desktopConfig.cts', import.meta.url), 'utf8');
const module = { exports: {} as any };
vm.runInNewContext(transformSync(configSource, { loader: 'ts', format: 'cjs' }).code, { module, exports: module.exports, URL });
const { resolveDesktopConfig, desktopAuthReturnUrl } = module.exports;
const plain = (value: unknown) => JSON.parse(JSON.stringify(value));
const legacy = 'https://heimdall.brolabs.ai';
const canonical = 'https://web.ninjy.ai';
const api = 'https://hub.brolabs.ai';

test('production defaults and the exact local legacy deployment use one canonical main UI', () => {
  assert.deepEqual(plain(resolveDesktopConfig({}, true)), {
    hubApiBaseUrl: api, uiUrl: canonical, isDev: false, migratedLegacyUi: false,
  });
  for (const packaged of [true, false]) {
    const config = resolveDesktopConfig({ HEIMDALL_HUB_API_URL: api, HEIMDALL_UI_URL: legacy }, packaged);
    assert.equal(config.uiUrl, canonical);
    assert.equal(config.migratedLegacyUi, true);
    assert.equal(config.isDev, false);
  }
  assert.equal(resolveDesktopConfig({ HEIMDALL_HUB_URL: api + '/', HEIMDALL_UI_URL: legacy + '/' }, false).uiUrl, canonical);
  assert.equal(resolveDesktopConfig({ HEIMDALL_HUB_API_URL: api }, false).uiUrl, canonical);
  assert.equal(resolveDesktopConfig({ HEIMDALL_UI_URL: canonical }, true).migratedLegacyUi, false);
});

test('local Vite resolves its actual port consistently and reports contradictory UI configuration', () => {
  assert.equal(resolveDesktopConfig({}, false).uiUrl, 'http://127.0.0.1:5173');
  assert.equal(resolveDesktopConfig({}, false).hubApiBaseUrl, 'http://127.0.0.1:8081');
  const vite = 'http://127.0.0.1:5181';
  assert.equal(resolveDesktopConfig({ VITE_DEV_SERVER_URL: vite }, false).uiUrl, vite);
  assert.equal(resolveDesktopConfig({ VITE_DEV_SERVER_URL: vite }, false).isDev, true);
  assert.equal(resolveDesktopConfig({ VITE_DEV_SERVER_URL: vite, HEIMDALL_UI_URL: vite + '/' }, false).uiUrl, vite);
  assert.throws(() => resolveDesktopConfig({ VITE_DEV_SERVER_URL: vite, HEIMDALL_UI_URL: legacy }, false), /conflicts/);
});

test('custom deployments and lookalike/path-bearing URLs never gain the production migration alias', () => {
  for (const ui of [
    'https://custom.example', legacy + '.evil.example', legacy + ':444',
    legacy + '/custom', legacy + '?custom=1', legacy + '/#custom',
  ]) {
    const config = resolveDesktopConfig({ HEIMDALL_HUB_API_URL: api, HEIMDALL_UI_URL: ui }, false);
    assert.equal(config.uiUrl, ui);
    assert.equal(config.migratedLegacyUi, false);
  }
  for (const hub of ['https://custom.example', api + '/proxy', api + ':444', 'http://hub.brolabs.ai']) {
    assert.equal(resolveDesktopConfig({ HEIMDALL_HUB_API_URL: hub, HEIMDALL_UI_URL: legacy }, false).uiUrl, legacy);
  }
  for (const bad of ['javascript:alert(1)', 'file:///tmp/ui', 'https://user:password@heimdall.brolabs.ai']) {
    assert.throws(() => resolveDesktopConfig({ HEIMDALL_UI_URL: bad }, true), /without credentials/);
  }
});

test('popup completion permits only trusted app returns and retains route or auth failure', () => {
  for (const url of [canonical + '/', canonical + '/#/conversations/test', canonical + '/?auth_error=forbidden']) {
    assert.equal(desktopAuthReturnUrl(url, canonical), url);
  }
  for (const url of [
    legacy + '/', 'https://auth.brolabs.ai/', canonical + '.evil.example/',
    'https://user:password@web.ninjy.ai/', canonical + ':444/', 'javascript:alert(1)',
    canonical + '/api/v1/auth/callback?code=redacted', canonical + '/api/v1/auth/login',
    canonical + '/api/v1/auth/logout', canonical + '/api/v1/me',
  ]) assert.equal(desktopAuthReturnUrl(url, canonical), '', url);
  assert.equal(desktopAuthReturnUrl('http://127.0.0.1:5181/#/home', 'http://127.0.0.1:5181'), 'http://127.0.0.1:5181/#/home');
});

function popupHarness() {
  const deferred: (() => void)[] = [];
  const windows: FakeWindow[] = [];
  const loads: string[] = [];
  let ownerDestroyed = false;
  let shown = 0, focused = 0;
  const owner = {
    isDestroyed: () => ownerDestroyed, loadURL: (url: string) => { loads.push(url); },
    show: () => { shown += 1; }, focus: () => { focused += 1; },
  };
  class FakeWindow {
    destroyed = false; closes = 0; focuses = 0; initialUrl = '';
    handlers = new Map<string, (...args: any[]) => void>();
    webContents = {
      setWindowOpenHandler: () => undefined,
      on: (name: string, callback: (...args: any[]) => void) => { this.handlers.set(name, callback); },
    };
    options: any;
    constructor(options: any) { this.options = options; windows.push(this); }
    isDestroyed() { return this.destroyed; }
    focus() { this.focuses += 1; }
    close() { this.closes += 1; this.destroyed = true; this.handlers.get('closed')?.(); }
    on(name: string, callback: (...args: any[]) => void) { this.handlers.set(name, callback); }
    loadURL(url: string) { this.initialUrl = url; }
    emit(name: string, url: string) { this.handlers.get(name)?.({}, url); }
  }
  const context: any = {
    BrowserWindow: FakeWindow, desktopAuthReturnUrl, configuredUiOrigin: () => canonical,
    authWindow: null, APP_DISPLAY_NAME: 'Heimdall', setImmediate: (callback: () => void) => deferred.push(callback),
    allowedExternalUrl: () => '', oidcWindowNavigationAllowed: () => true, shell: {},
  };
  const source = mainSource.slice(mainSource.indexOf('function openOidcWindow('), mainSource.indexOf('function createWindow('));
  vm.createContext(context);
  vm.runInContext(transformSync(source, { loader: 'ts' }).code, context);
  return {
    open: () => context.openOidcWindow(canonical + '/api/v1/auth/login', owner),
    windows, loads, deferred, owner, focused: () => focused, shown: () => shown,
    flush: () => { while (deferred.length) deferred.shift()!(); },
    destroyOwner: () => { ownerDestroyed = true; },
  };
}

test('actual popup function completes only after committed return, defers close, preserves route and runs once', () => {
  const h = popupHarness(); h.open();
  const popup = h.windows[0];
  assert.deepEqual(plain(popup.options.webPreferences), { contextIsolation: true, nodeIntegration: false, sandbox: true });
  assert.equal(popup.options.parent, h.owner);
  h.open(); assert.equal(h.windows.length, 1); assert.equal(popup.focuses, 1);
  for (const url of ['https://auth.brolabs.ai/', canonical + '/api/v1/auth/callback?code=redacted', legacy + '/']) {
    popup.emit('did-navigate', url);
  }
  assert.equal(h.deferred.length, 0);
  popup.emit('did-redirect-navigation', canonical + '/');
  assert.equal(h.deferred.length, 0);
  const returned = canonical + '/#/conversations/test';
  popup.emit('did-navigate', returned);
  popup.emit('did-navigate', returned);
  assert.equal(h.deferred.length, 1);
  assert.equal(popup.closes, 0); assert.equal(h.loads.length, 0);
  h.flush();
  assert.equal(popup.closes, 1); assert.deepEqual(h.loads, [returned]);
  assert.equal(h.shown(), 1); assert.equal(h.focused(), 1);
});

test('cancellation can reopen and a popup cancelled after completion queues no stale main reload', () => {
  const h = popupHarness(); h.open();
  h.windows[0].emit('did-navigate', canonical + '/');
  h.windows[0].close(); h.flush();
  assert.deepEqual(h.loads, []);
  h.open(); assert.equal(h.windows.length, 2);
  h.windows[1].emit('did-navigate', canonical + '/?auth_error=forbidden');
  h.flush();
  assert.deepEqual(h.loads, [canonical + '/?auth_error=forbidden']);
});

test('destroyed owner never reloads a different window', () => {
  const h = popupHarness(); h.open();
  h.windows[0].emit('did-navigate', canonical + '/');
  h.destroyOwner(); h.flush();
  assert.deepEqual(h.loads, []);
  assert.equal(h.windows[0].closes, 1);
});

test('main startup and notification identity share effective UI without touching stored auth material', () => {
  assert.match(mainSource, /const desktopConfig = resolveDesktopConfig\(process.env, app.isPackaged\)/);
  assert.match(mainSource, /return desktopConfig.uiUrl/);
  assert.match(mainSource, /const isDev = desktopConfig.isDev/);
  assert.match(mainSource, /uiUrl: configuredUiOrigin\(\)/);
  assert.match(mainSource, /win.loadURL\(configuredUiOrigin\(\)\)/);
  assert.doesNotMatch(mainSource, /cookies.set|clearStorageData|BrowserWindow.getAllWindows/);
  assert.match(mainSource, /Existing profile\/storage is retained/);
});
