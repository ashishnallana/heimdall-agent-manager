// REQ-MAC-CHROME-1: macOS-only hidden native title bar with native traffic
// lights, Windows native caption, legacy overlay compatibility and gated drag regions.
// Linux, browser/PWA and older desktops keep today's chrome.
import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { JSDOM } from 'jsdom';
import { transformSync } from 'esbuild';
import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { MAC_TRAFFIC_LIGHT_INSET, windowControlsInsetLeft, windowControlsInsetRight } from '../src/ui/components/shell/shellChrome.ts';
import { applyWindowChromeAttributes, readWindowChromeStyle, subscribeWindowChromeGeometry, useWindowChrome } from '../src/ui/hooks/useWindowChrome.ts';

function read(relative: string): string {
  return fs.readFileSync(new URL(`../${relative}`, import.meta.url), 'utf8');
}

// Values built inside the vm context carry its prototypes; compare plain data.
const plain = (value: unknown) => JSON.parse(JSON.stringify(value));

function loadCts(name: string, globals: any = {}) {
  const module = { exports: {} as any };
  vm.runInNewContext(transformSync(read(`src/ui/electron/${name}.cts`), { loader: 'ts', format: 'cjs' }).code,
    { module, exports: module.exports, ...globals });
  return module.exports;
}

const mainSource = read('src/ui/electron/main.cts');
const appShellSource = read('src/ui/components/shell/AppShell.tsx');
const stylesSource = read('src/ui/styles.css');

test('Windows pins relaunch Ninjy in packaged and unpackaged runs', () => {
  const identity = loadCts('windowsIdentity');
  const executable = 'C:\\Program Files\\Ninjy\\Ninjy.exe';
  const entry = 'C:\\source code\\Heimdall\\main.cjs';
  const icon = 'C:\\source code\\Heimdall\\icon.ico';
  const packaged = identity.taskbarDetails('win32', true, executable, entry, icon);
  assert.equal(packaged.relaunchCommand, `"${executable}"`);
  assert.equal(packaged.appIconPath, executable);
  assert.equal(packaged.relaunchDisplayName, 'Ninjy');
  assert.equal(packaged.appId, identity.APP_ID);
  const development = identity.taskbarDetails('win32', false, 'C:\\Electron\\electron.exe', entry, icon);
  assert.equal(development.relaunchCommand, `"C:\\Electron\\electron.exe" "${entry}"`);
  assert.equal(development.appIconPath, icon);
  assert.equal(development.appId, packaged.appId);
  // A directory entry with a trailing separator must not escape the closing quote.
  assert.equal(identity.taskbarDetails('win32', false, executable, 'C:\\app path\\', icon).relaunchCommand,
    `"${executable}" "C:\\app path\\\\"`);
  for (const platform of ['darwin', 'linux']) {
    assert.equal(identity.taskbarDetails(platform, false, executable, entry, icon), null);
  }
  assert.match(mainSource, /win\.setAppDetails\(taskbarDetails\)/);
  assert.match(mainSource, /app\.setAppUserModelId\?\.\(windowsIdentity\.APP_ID\)/);
});

test('windowChrome keeps native controls on each desktop and the kill switch restores the native title bar', () => {
  const chrome = loadCts('windowChrome');
  assert.deepEqual(plain(chrome.windowChromeOptions('darwin', {})), { titleBarStyle: 'hidden', trafficLightPosition: { x: 16, y: 17 } });
  assert.deepEqual(plain(chrome.windowChromeArgs('darwin', {})), ['--heimdall-window-chrome=mac-hidden']);
  for (const platform of ['linux']) {
    assert.deepEqual(plain(chrome.windowChromeOptions(platform, {})), {});
    assert.deepEqual(plain(chrome.windowChromeArgs(platform, {})), []);
  }
  assert.deepEqual(plain(chrome.windowChromeOptions('darwin', { HEIMDALL_NATIVE_TITLE_BAR: '1' })), {});
  assert.deepEqual(plain(chrome.windowChromeArgs('darwin', { HEIMDALL_NATIVE_TITLE_BAR: '1' })), []);
  assert.equal(chrome.windowChromeStyle('darwin', { HEIMDALL_NATIVE_TITLE_BAR: '0' }), 'mac-hidden');
  assert.equal(chrome.windowChromeStyle('win32', {}), 'native');
  assert.deepEqual(plain(chrome.windowChromeOptions('win32', {})), {});
  assert.deepEqual(plain(chrome.windowChromeArgs('win32', {})), []);
  assert.deepEqual(plain(chrome.windowChromeOptions('win32', { HEIMDALL_NATIVE_TITLE_BAR: '1' })), {});
  assert.deepEqual(plain(chrome.windowChromeArgs('win32', { HEIMDALL_NATIVE_TITLE_BAR: '1' })), []);
});

test('main window applies chrome through windowChrome only, keeps security flags, and leaves the OIDC window native', () => {
  assert.match(mainSource, /\.\.\.windowChrome\.windowChromeOptions\(process\.platform, process\.env\)/);
  assert.match(mainSource, /\.\.\.windowChrome\.windowChromeArgs\(process\.platform, process\.env\)/);
  assert.match(mainSource, /contextIsolation: true,\s+nodeIntegration: false,\s+sandbox: true,\s+preload:/);
  assert.doesNotMatch(mainSource, /trafficLightPosition|titleBarStyle|frame:\s*false|titleBarOverlay/);
  const loginWindow = mainSource.slice(mainSource.indexOf('const loginWindow = new BrowserWindow'), mainSource.indexOf('authWindow = loginWindow'));
  assert.ok(loginWindow.length > 0);
  assert.doesNotMatch(loginWindow, /windowChrome/);
  assert.match(mainSource, /win\.on\('enter-full-screen', sendChromeState\)/);
  assert.match(mainSource, /win\.on\('leave-full-screen', sendChromeState\)/);
  assert.match(mainSource, /win\.webContents\.on\('did-finish-load', sendChromeState\)/);
  // The renderer gets no new invoke/send channel for window chrome.
  assert.doesNotMatch(mainSource, /ipcMain\.(handle|on)\('heimdall-window:/);
});

function loadPreload(argv: string[]) {
  let api: any;
  const handlers = new Map<string, (...args: any[]) => void>();
  const sends: any[] = [];
  loadCts('preload', {
    process: { argv, env: {} },
    queueMicrotask,
    require: (name: string) => {
      assert.equal(name, 'electron');
      return {
        contextBridge: { exposeInMainWorld: (_key: string, value: any) => { api = value; } },
        ipcRenderer: {
          on: (channel: string, handler: (...args: any[]) => void) => { handlers.set(channel, handler); },
          invoke: async () => true,
          send: (...args: any[]) => { sends.push(args); },
        },
      };
    },
  });
  return { api, emit: (payload: any) => handlers.get('heimdall-window:chrome-state')?.({}, payload), sends };
}

test('preload exposes read-only window chrome state with replayable fullscreen and unsubscribe', () => {
  assert.equal(loadPreload([]).api.windowChrome.style, 'native');
  assert.equal(loadPreload(['--heimdall-window-chrome=win-overlay']).api.windowChrome.style, 'win-overlay');
  const { api, emit, sends } = loadPreload(['--heimdall-window-chrome=mac-hidden']);
  assert.equal(api.windowChrome.style, 'mac-hidden');
  assert.deepEqual(plain(api.windowChrome.getState()), { fullscreen: false });
  // A state sent before any renderer listener (reload in fullscreen) is cached.
  emit({ fullscreen: true });
  assert.deepEqual(plain(api.windowChrome.getState()), { fullscreen: true });
  const seen: boolean[] = [];
  const unsubscribe = api.windowChrome.onStateChange((state: any) => seen.push(state.fullscreen));
  emit({ fullscreen: false });
  unsubscribe();
  emit({ fullscreen: true });
  assert.deepEqual(seen, [false]);
  assert.deepEqual(Object.keys(api.windowChrome).sort(), ['getState', 'onStateChange', 'style']);
  assert.deepEqual(sends, []);
});

test('renderer inset is only reserved for the windowed macOS hidden title bar', () => {
  assert.equal(windowControlsInsetLeft('native', false), 0);
  assert.equal(windowControlsInsetLeft('native', true), 0);
  assert.equal(windowControlsInsetLeft('mac-hidden', false), MAC_TRAFFIC_LIGHT_INSET);
  assert.equal(windowControlsInsetLeft('mac-hidden', true), 0);
  assert.equal(readWindowChromeStyle(null), 'native');
  assert.equal(readWindowChromeStyle({ style: 'something-else' }), 'native');
  assert.equal(readWindowChromeStyle({ style: 'mac-hidden' }), 'mac-hidden');
});

test('html attributes gate the chrome CSS and are absent in the browser/native case', () => {
  const root = new JSDOM('<!doctype html><html></html>').window.document.documentElement;
  applyWindowChromeAttributes(root, 'native', false);
  assert.equal(root.hasAttribute('data-window-chrome'), false);
  applyWindowChromeAttributes(root, 'mac-hidden', false);
  assert.equal(root.getAttribute('data-window-chrome'), 'mac-hidden');
  assert.equal(root.hasAttribute('data-window-fullscreen'), false);
  assert.equal(root.style.getPropertyValue('--window-controls-inset-left'), `${MAC_TRAFFIC_LIGHT_INSET}px`);
  applyWindowChromeAttributes(root, 'mac-hidden', true);
  assert.equal(root.hasAttribute('data-window-fullscreen'), true);
  assert.equal(root.style.getPropertyValue('--window-controls-inset-left'), '0px');
  applyWindowChromeAttributes(root, 'native', false);
  assert.equal(root.hasAttribute('data-window-chrome'), false);
  assert.equal(root.style.getPropertyValue('--window-controls-inset-left'), '');
});

test('drag/no-drag CSS requires an integrated desktop style', () => {
  const chromeCss = stylesSource.slice(stylesSource.indexOf('/* REQ-MAC-CHROME-1')).replace(/\/\*[\s\S]*?\*\//g, '');
  const appRegionRules = [...chromeCss.matchAll(/([^{}]+)\{[^}]*-webkit-app-region/g)].map((m) => m[1].trim());
  assert.ok(appRegionRules.length >= 3);
  for (const selectorList of appRegionRules) {
    for (const selector of selectorList.split(/,\s*\n/)) {
      assert.match(selector.trim(), /^html:is\(\[data-window-chrome="mac-hidden"\], \[data-window-chrome="win-overlay"\]\)/, selector);
    }
  }
  assert.doesNotMatch(stylesSource.slice(0, stylesSource.indexOf('/* REQ-MAC-CHROME-1')), /-webkit-app-region/);
  assert.match(chromeCss, /\[draggable="true"\]/);
  assert.match(chromeCss, /\[role="dialog"\]/);
  assert.match(chromeCss, /main-pane-drag-grip-/);
  assert.match(chromeCss, /\.window-gate-drag-strip \{\s*display: none;/);
});

test('top-left cluster clears the traffic lights and gate screens get a drag surface', () => {
  assert.match(appShellSource, /const controlsInset = isMobile \? 0 : rawControlsInset/);
  assert.match(appShellSource, /paddingLeft: controlsInset \? controlsInset \+ 8 : undefined/);
  assert.match(appShellSource, /data-debug-id="shell-top-left-cluster"\s+className="window-drag /);
  assert.match(appShellSource, /data-debug-id="shell-top-bar"\s+className="window-drag /);
  // Auth/device-vault gates render the strip; standalone device pages pad below it.
  const authGate = appShellSource.slice(appShellSource.indexOf('function AuthGate()'), appShellSource.indexOf('function AuthStatusScreen'));
  assert.match(authGate, /useWindowChrome\(\)/);
  assert.match(authGate, /return <>\{gateDragStrip\}\{screen\}<\/>/);
  // Standalone pages: /setup (first-run wizard), /device/add and /device/providers.
  assert.equal(appShellSource.match(/className="window-gate-pad fixed inset-x-0 top-0/g)?.length, 3);
  assert.match(appShellSource, /data-debug-id="setup-standalone-page"\s+className="window-gate-pad fixed inset-x-0 top-0 /);
});

test('Windows right inset follows valid overlay geometry, protects missing data and vanishes in fullscreen', () => {
  const area = { x: 0, y: 0, width: 1062, height: 48 };
  assert.equal(windowControlsInsetRight('win-overlay', false, 1200, area), 138);
  assert.equal(windowControlsInsetRight('win-overlay', false, 1200, { ...area, x: 10, width: 1050 }), 140);
  assert.equal(windowControlsInsetRight('win-overlay', true, 1200, area), 0);
  for (const style of ['native', 'mac-hidden'] as const) {
    assert.equal(windowControlsInsetRight(style, false, 1200, area), 0);
  }
  for (const invalid of [null, { ...area, width: 1300 }, { ...area, width: 1200 },
    { ...area, width: NaN }, { ...area, width: -1 }, { ...area, height: 0 }, { ...area, x: -1 }]) {
    assert.equal(windowControlsInsetRight('win-overlay', false, 1200, invalid), 160);
  }
  assert.equal(windowControlsInsetRight('win-overlay', false, 100, null), 100);
  assert.equal(windowControlsInsetRight('win-overlay', false, NaN, area), 160);
  assert.equal(readWindowChromeStyle({ style: 'win-overlay' }), 'win-overlay');
});

test('Windows attributes carry only right safe area and native opt-out clears both properties', () => {
  const root = new JSDOM('<!doctype html><html></html>').window.document.documentElement;
  applyWindowChromeAttributes(root, 'win-overlay', false, 138);
  assert.equal(root.getAttribute('data-window-chrome'), 'win-overlay');
  assert.equal(root.style.getPropertyValue('--window-controls-inset-left'), '0px');
  assert.equal(root.style.getPropertyValue('--window-controls-inset-right'), '138px');
  applyWindowChromeAttributes(root, 'win-overlay', true, 138);
  assert.equal(root.style.getPropertyValue('--window-controls-inset-right'), '0px');
  applyWindowChromeAttributes(root, 'native', false);
  assert.equal(root.hasAttribute('data-window-chrome'), false);
  assert.equal(root.style.getPropertyValue('--window-controls-inset-right'), '');
});

test('geometry subscription reads after registering, handles resize and cleans up both listeners', () => {
  const calls: string[] = [];
  const overlay = {
    visible: true, getTitlebarAreaRect: () => ({ x: 0, y: 0, width: 1000, height: 48 }),
    addEventListener: (name: string) => { calls.push('overlay+' + name); },
    removeEventListener: (name: string) => { calls.push('overlay-' + name); },
  };
  const viewport = {
    addEventListener: (name: string) => { calls.push('viewport+' + name); },
    removeEventListener: (name: string) => { calls.push('viewport-' + name); },
  };
  const cleanup = subscribeWindowChromeGeometry(overlay, viewport, () => { calls.push('read'); });
  cleanup();
  assert.deepEqual(calls, ['overlay+geometrychange', 'viewport+resize', 'read', 'overlay-geometrychange', 'viewport-resize']);
});

test('Windows hook tracks geometry, viewport resize, fullscreen replay and unsubscribe', async () => {
  const dom = new JSDOM('<!doctype html><html><body><div id="root"></div></body></html>');
  const saved = new Map<string, PropertyDescriptor | undefined>();
  const install = (key: string, value: unknown) => {
    saved.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    Object.defineProperty(globalThis, key, { configurable: true, writable: true, value });
  };
  const listeners = new Set<(state: { fullscreen: boolean }) => void>();
  const geometryListeners = new Set<() => void>();
  let area = { x: 0, y: 0, width: 1062, height: 48 };
  let fullscreen = false;
  const overlay = {
    visible: false, getTitlebarAreaRect: () => area,
    addEventListener: (_name: string, callback: () => void) => { geometryListeners.add(callback); },
    removeEventListener: (_name: string, callback: () => void) => { geometryListeners.delete(callback); },
  };
  (dom.window as any).odinApi = { windowChrome: {
    style: 'win-overlay', getState: () => ({ fullscreen }),
    onStateChange: (callback: (state: { fullscreen: boolean }) => void) => {
      listeners.add(callback);
      // Simulate a main-process state received between first read and subscribe.
      fullscreen = true;
      return () => { listeners.delete(callback); };
    },
  } };
  Object.defineProperty(dom.window, 'innerWidth', { configurable: true, writable: true, value: 1200 });
  Object.defineProperty(dom.window.navigator, 'windowControlsOverlay', { value: overlay });
  install('window', dom.window); install('document', dom.window.document);
  install('navigator', dom.window.navigator); install('IS_REACT_ACT_ENVIRONMENT', true);
  const root = createRoot(dom.window.document.getElementById('root')!);
  let latest: ReturnType<typeof useWindowChrome>;
  function Probe() { latest = useWindowChrome(); return null; }
  try {
    await act(async () => { root.render(React.createElement(Probe)); });
    assert.equal(latest!.fullscreen, true);
    assert.equal(latest!.insetRight, 0);
    await act(async () => {
      fullscreen = false;
      for (const callback of listeners) callback({ fullscreen });
    });
    assert.equal(latest!.insetRight, 160); // no geometry yet; protect native controls
    await act(async () => {
      overlay.visible = true;
      for (const callback of geometryListeners) callback();
    });
    assert.equal(latest!.insetRight, 138);
    assert.equal(latest!.insetLeft, 0);
    assert.equal(document.documentElement.style.getPropertyValue('--window-controls-inset-right'), '138px');
    await act(async () => {
      (dom.window as any).innerWidth = 1440;
      area = { ...area, width: 1260 };
      dom.window.dispatchEvent(new dom.window.Event('resize'));
    });
    assert.equal(latest!.insetRight, 180);
    await act(async () => { root.unmount(); });
    assert.equal(listeners.size, 0);
    assert.equal(geometryListeners.size, 0);
  } finally {
    for (const [key, descriptor] of saved) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else delete (globalThis as any)[key];
    }
    dom.window.close();
  }
});

test('right safe area reaches the top bar, workspace cluster and pane/dock reservations', () => {
  const workspace = read('src/ui/components/mainWorkspace/Workspace.tsx');
  assert.match(appShellSource, /paddingRight: controlsInsetRight \? controlsInsetRight \+ 12 : undefined/);
  assert.match(workspace, /const reservedTopRightWidth = topRightWidth \+ windowControlsInset/);
  assert.match(workspace, /reserveRight=\{reservedTopRightWidth\}/);
  assert.match(workspace, /right: windowControlsInset \|\| undefined/);
  assert.match(workspace, /Math.max\(0, reservedTopRightWidth - 12\)/);
});
