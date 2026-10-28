// REQ-MAC-CHROME-1: macOS-only hidden native title bar with native traffic
// lights, an integrated renderer inset and attribute-gated drag regions. Every
// other platform, the browser/PWA and older desktops keep today's chrome.
import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { JSDOM } from 'jsdom';
import { transformSync } from 'esbuild';
import { MAC_TRAFFIC_LIGHT_INSET, windowControlsInsetLeft } from '../src/ui/components/shell/shellChrome.ts';
import { applyWindowChromeAttributes, readWindowChromeStyle } from '../src/ui/hooks/useWindowChrome.ts';

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

test('windowChrome options are macOS-only and the kill switch restores the native title bar', () => {
  const chrome = loadCts('windowChrome');
  assert.deepEqual(plain(chrome.windowChromeOptions('darwin', {})), { titleBarStyle: 'hidden', trafficLightPosition: { x: 16, y: 17 } });
  assert.deepEqual(plain(chrome.windowChromeArgs('darwin', {})), ['--heimdall-window-chrome=mac-hidden']);
  for (const platform of ['win32', 'linux']) {
    assert.deepEqual(plain(chrome.windowChromeOptions(platform, {})), {});
    assert.deepEqual(plain(chrome.windowChromeArgs(platform, {})), []);
  }
  assert.deepEqual(plain(chrome.windowChromeOptions('darwin', { HEIMDALL_NATIVE_TITLE_BAR: '1' })), {});
  assert.deepEqual(plain(chrome.windowChromeArgs('darwin', { HEIMDALL_NATIVE_TITLE_BAR: '1' })), []);
  assert.equal(chrome.windowChromeStyle('darwin', { HEIMDALL_NATIVE_TITLE_BAR: '0' }), 'mac-hidden');
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

test('drag/no-drag CSS only applies under html[data-window-chrome="mac-hidden"]', () => {
  const chromeCss = stylesSource.slice(stylesSource.indexOf('/* REQ-MAC-CHROME-1')).replace(/\/\*[\s\S]*?\*\//g, '');
  const appRegionRules = [...chromeCss.matchAll(/([^{}]+)\{[^}]*-webkit-app-region/g)].map((m) => m[1].trim());
  assert.ok(appRegionRules.length >= 3);
  for (const selectorList of appRegionRules) {
    for (const selector of selectorList.split(/,\s*\n/)) {
      assert.match(selector.trim(), /^html\[data-window-chrome="mac-hidden"\]/, selector);
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
  assert.equal(appShellSource.match(/className="window-gate-pad fixed inset-x-0 top-0/g)?.length, 2);
});
