import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { EventEmitter } from 'node:events';
import { transformSync } from 'esbuild';
import './helpers/vaultEndpointHarness.ts';
import { keyringFromHex } from './helpers/vaultTestKeyring.ts';

function loadCts(name: string, globals: any = {}) {
  const source = fs.readFileSync(new URL(`../src/ui/electron/${name}.cts`, import.meta.url), 'utf8');
  const module = { exports: {} as any };
  vm.runInNewContext(transformSync(source, { loader: 'ts', format: 'cjs' }).code,
    { module, exports: module.exports, URL, setTimeout, clearTimeout, ...globals });
  return module.exports;
}

const plan = { title: 'Build finished', body: 'Ready for review', tag: 'thread-1', route: '/conversations/inst_1' };

function fixture(globals: any = {}) {
  const handlers = new Map<string, Function>();
  const created: any[] = [];
  let supported = true;
  let behavior = 'show';
  const wc: any = new EventEmitter();
  wc.mainFrame = { url: 'https://heimdall.test/' };
  wc.getURL = () => wc.mainFrame.url;
  let loading = false;
  wc.isLoadingMainFrame = () => loading;
  const scripts: string[] = [];
  wc.executeJavaScript = async (script: string) => { scripts.push(script); };
  let focused = 0;
  const win = { isDestroyed: () => false, webContents: wc };
  class FakeNotification extends EventEmitter {
    options: any;
    closed = false;
    constructor(options: any) { super(); this.options = options; created.push(this); }
    static isSupported() { return supported; }
    show() {
      if (behavior === 'throw') throw new Error('OS unavailable');
      if (behavior !== 'pending') this.emit(behavior);
    }
    close() { this.closed = true; this.emit('close'); }
  }
  const controller = loadCts('notifications', globals).installNotifications({
    ipcMain: { handle: (name: string, fn: Function) => handlers.set(name, fn) },
    Notification: FakeNotification, getWindow: () => win,
    showWindow: () => { focused++; return win; }, uiUrl: 'https://heimdall.test/', icon: 'app-icon',
  });
  const event = { sender: wc, senderFrame: wc.mainFrame };
  return {
    created, scripts, controller, wc, event,
    show: (value: any = plan, sender = event) => handlers.get('heimdall-notifications:show')!(sender, value),
    set supported(value: boolean) { supported = value; },
    set behavior(value: string) { behavior = value; },
    set loading(value: boolean) { loading = value; },
    get focused() { return focused; },
  };
}

test('native delivery coalesces threads, retains click routing, and waits for loading UI', async () => {
  const f = fixture();
  try {
    assert.equal(await f.show(), true);
    assert.equal(f.created[0].options.icon, 'app-icon');
    assert.equal(f.created[0].options.body, plan.body);
    assert.equal(await f.show({ ...plan, body: 'Newer event' }), true);
    assert.equal(f.created[0].closed, true, 'same tag replaces old native notification');
    assert.equal(await f.show({ ...plan, tag: 'other', route: '#/settings' }), true);
    assert.equal(f.created[1].closed, false, 'other threads stay active');
    f.loading = true;
    f.created[1].emit('click');
    assert.equal(f.focused, 1, 'click restores and focuses the owning window');
    assert.equal(f.scripts.length, 0, 'wait for UI load before routing');
    f.wc.emit('did-finish-load');
    assert.equal(f.scripts[0], 'window.location.hash = "#/conversations/inst_1"');
    f.created[2].emit('click');
    f.wc.emit('did-finish-load');
    assert.equal(f.scripts[1], 'window.location.hash = "#/settings"');
  } finally { f.controller.dispose(); }
});

test('IPC rejects other windows, subframes, off-origin/auth pages and invalid payloads', async () => {
  const f = fixture();
  assert.equal(await f.show(plan, { ...f.event, sender: {} }), false);
  assert.equal(await f.show(plan, { ...f.event, senderFrame: { url: 'https://heimdall.test/' } }), false);
  for (const url of ['https://evil.test/', 'https://heimdall.test/api/v1/auth/login']) {
    f.wc.mainFrame.url = url;
    assert.equal(await f.show(), false);
  }
  f.wc.mainFrame.url = 'https://heimdall.test/';
  for (const value of [null, {}, { ...plan, title: 'x'.repeat(257) }, { ...plan, body: 42 },
    { ...plan, body: 'x'.repeat(4097) }, { ...plan, tag: 'x'.repeat(513) },
    ...['https://evil.test/', '//evil.test', '/api/v1/auth/login', '/settings\\evil', '/settings\nfoo',
      '/settings#bad', '/settings' + '\0'].map(route => ({ ...plan, route }))]) {
    assert.equal(await f.show(value), false, `reject ${JSON.stringify(value).slice(0, 80)}`);
  }
  assert.equal(f.created.length, 0);
});

test('unsupported sessions, thrown delivery and asynchronous OS failure report false', async () => {
  const f = fixture();
  f.supported = false;
  assert.equal(await f.show(), false);
  assert.equal(f.created.length, 0);
  f.supported = true;
  f.behavior = 'throw';
  assert.equal(await f.show(), false);
  f.behavior = 'pending';
  const result = f.show();
  f.created.at(-1).emit('failed', new Error('blocked by OS'));
  assert.equal(await result, false);
  f.controller.dispose();
});

test('native lifecycle bounds retained objects and disposal closes pending notifications', async () => {
  const f = fixture();
  for (let i = 0; i < 101; i++) assert.equal(await f.show({ ...plan, tag: `thread-${i}` }), true);
  assert.equal(f.created[0].closed, true, 'oldest closes at retention limit');
  f.behavior = 'pending';
  const pending = f.show({ ...plan, tag: 'pending' });
  f.controller.dispose();
  assert.equal(await pending, false);
  assert.ok(f.created.every(n => n.closed));
});

test('a native backend that never acknowledges delivery times out and releases the notification', async () => {
  let expire: () => void;
  const f = fixture({ setTimeout: (fn: () => void) => { expire = fn; return 1; }, clearTimeout() {} });
  f.behavior = 'pending';
  const result = f.show();
  expire!();
  assert.equal(await result, false);
  assert.equal(f.created[0].closed, true);
  f.controller.dispose();
});

test('preload exposes native capability and only the narrow notification IPC call', async () => {
  for (const supported of [false, true]) {
    let api: any;
    const calls: any[] = [];
    loadCts('preload', {
      process: { argv: supported ? ['--heimdall-native-notifications'] : [], env: {} },
      require: (name: string) => {
        assert.equal(name, 'electron');
        return {
          contextBridge: { exposeInMainWorld: (key: string, value: any) => { assert.equal(key, 'odinApi'); api = value; } },
          ipcRenderer: { on() {}, invoke: async (...args: any[]) => { calls.push(args); return true; } },
        };
      },
    });
    assert.equal(api.notifications.supported, supported);
    assert.equal(await api.notifications.show(plan), true);
    assert.equal(calls[0][0], 'heimdall-notifications:show');
    assert.deepEqual(calls[0][1], plan);
    assert.equal(api.notifications.invoke, undefined);
  }
});

test('Electron shares policy/privacy settings, sends once through IPC, and never uses browser API', { timeout: 10000 }, async () => {
  const sent: any[] = [];
  let onDelivery: (() => void) | undefined;
  let browserCalls = 0;
  let focus = false;
  (globalThis as any).window = {
    odinApi: { notifications: { supported: true, show: async (p: any) => { sent.push(p); onDelivery?.(); return true; } } },
    Notification: class { constructor() { browserCalls++; } },
    location: { hash: '#/conversations/inst_1', pathname: '/', search: '' },
    localStorage: { getItem: () => null, setItem() {} },
  };
  (globalThis as any).document = { visibilityState: 'visible', hasFocus: () => focus };
  const service = await import('../src/ui/services/notificationService.ts');
  const slice = await import('../src/ui/store/notificationsSlice.ts');
  const state = { notifications: { enabled: true, permission: 'granted', categories: { chat: true, attention: true } }, vault: { isUnlocked: false } };
  const getState = () => state;
  const event = { type: 'chat_event', direction: 'agent_to_user', agent_instance_id: 'inst_1', conversation_id: 'conv_1', message: { direction: 'agent_to_user', body: 'Hello' } };
  assert.equal(service.isNotificationSupported(), true);
  assert.equal(await service.requestNotificationPermission(), 'granted');
  let settings = slice.default(undefined, { type: 'init' });
  settings = slice.default(settings, slice.notificationPermissionRefreshed());
  settings = slice.default(settings, slice.notificationsEnabledSet(true));
  assert.equal(settings.enabled, true, 'desktop support permits enabling without browser permission');
  service.fireNotificationForWsEvent(getState, event);
  assert.equal(sent.length, 1);
  focus = true;
  service.fireNotificationForWsEvent(getState, event);
  assert.equal(sent.length, 1, 'focused current conversation suppressed');
  focus = false;
  state.notifications.categories.chat = false;
  service.fireNotificationForWsEvent(getState, event);
  assert.equal(sent.length, 1, 'category opt-out honored');
  state.notifications.categories.chat = true;
  state.notifications.enabled = false;
  service.fireNotificationForWsEvent(getState, event);
  assert.equal(sent.length, 1, 'master opt-out honored');
  state.notifications.enabled = true;
  const vault = await import('../src/ui/utils/vaultContent.ts');
  const key = await keyringFromHex('a'.repeat(64));
  const encrypted = await vault.encryptVaultText('Secret build result', key);
  service.fireNotificationForWsEvent(getState, { ...event, message: { ...event.message, body: encrypted } });
  assert.equal(sent.at(-1).body, '[🔒 Encrypted message]', 'locked vault never passes ciphertext to OS');
  const { setActiveVaultKey } = vault;
  setActiveVaultKey(key);
  try {
    const delivered = new Promise<void>(resolve => { onDelivery = resolve; });
    service.fireNotificationForWsEvent(getState, { ...event, message: { ...event.message, body: encrypted } });
    await delivered;
    assert.equal(sent.at(-1).body, 'Secret build result', 'installed vault key decrypts before IPC');
  } finally { setActiveVaultKey(null); }
  assert.equal(browserCalls, 0);
  (window as any).odinApi.notifications.show = async () => { throw new Error('IPC unavailable'); };
  assert.equal(await service.showNativeNotification({ ...plan, category: 'chat' }), false);
  (window as any).odinApi.notifications.supported = false;
  assert.equal(service.isNotificationSupported(), false);
  assert.equal(await service.requestNotificationPermission(), 'unsupported');
  settings = slice.default(settings, slice.notificationPermissionRefreshed());
  assert.equal(settings.enabled, false);
  assert.equal(settings.permission, 'unsupported');
  assert.equal(browserCalls, 0, 'never fall back to duplicate browser delivery on IPC errors');
});

test('desktop Settings enables master toggle and test button actually invokes native delivery', async () => {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://heimdall.test/#/settings/notifications' });
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  const delivered: any[] = [];
  (window as any).odinApi = { notifications: { supported: true, show: async (p: any) => { delivered.push(p); return true; } } };
  const React = await import('react');
  const { createRoot } = await import('react-dom/client');
  const { Provider } = await import('react-redux');
  const { configureStore } = await import('@reduxjs/toolkit');
  const slice = await import('../src/ui/store/notificationsSlice.ts');
  const { default: NotificationsPanel, TEST_NOTIFICATION_PLAN } = await import('../src/ui/components/settings/NotificationsPanel.tsx');
  const store = configureStore({ reducer: { notifications: slice.default } });
  const root = createRoot(document.getElementById('root')!);
  try {
    await React.act(async () => { root.render(React.createElement(Provider, { store, children: React.createElement(NotificationsPanel) })); });
    const toggle = document.querySelector('[data-debug-id="settings-notifications-master-toggle"]') as HTMLButtonElement;
    assert.equal(toggle.disabled, false);
    await React.act(async () => { toggle.click(); });
    assert.equal(store.getState().notifications.enabled, true);
    const button = document.querySelector('[data-debug-id="settings-notifications-test-btn"]') as HTMLButtonElement;
    await React.act(async () => { button.click(); });
    assert.equal(delivered.length, 1);
    assert.equal(delivered[0].title, TEST_NOTIFICATION_PLAN.title);
    assert.equal(delivered[0].route, '#/settings');
    await React.act(async () => { toggle.click(); });
    assert.equal(store.getState().notifications.enabled, false);
  } finally {
    await React.act(async () => root.unmount());
    dom.window.close();
    delete (globalThis as any).IS_REACT_ACT_ENVIRONMENT;
  }
});
