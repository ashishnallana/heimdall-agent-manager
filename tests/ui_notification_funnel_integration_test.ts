import { test } from 'node:test';
import assert from 'node:assert/strict';
import './helpers/vaultEndpointHarness.ts';

test('handleUserWsEvent funnel dispatches native notifications for curated events when backgrounded or viewing another thread', async () => {
  const created: Array<{ title: string; options: any }> = [];
  const storage = new Map<string, string>();

  class FakeNotification {
    onclick: (() => void) | null = null;
    static permission: 'default' | 'granted' | 'denied' = 'granted';
    constructor(title: string, options: any) { created.push({ title, options }); }
    static async requestPermission() { return FakeNotification.permission; }
    close() {}
  }

  const view = { visibility: 'hidden' as 'hidden' | 'visible', focus: false, hash: '' };

  (globalThis as any).document = {
    get visibilityState() { return view.visibility; },
    hasFocus() { return view.focus; },
    querySelector() { return null; },
    addEventListener() {},
    removeEventListener() {},
  };
  (globalThis as any).window = {
    Notification: FakeNotification,
    localStorage: {
      getItem(k: string) { return storage.has(k) ? storage.get(k)! : null; },
      setItem(k: string, v: string) { storage.set(k, v); },
      removeItem(k: string) { storage.delete(k); },
    },
    location: { origin: 'https://hub.test', pathname: '/index.html', search: '', get hash() { return view.hash; }, set hash(v: string) { view.hash = v; } },
    focus() { view.focus = true; },
    open() { return { focus() {} }; },
    addEventListener() {},
    removeEventListener() {},
    matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} }),
    odinApi: undefined,
  };
  (globalThis as any).Notification = FakeNotification;
  (window as any).isSecureContext = true;

  const flush = async () => { await Promise.resolve(); await Promise.resolve(); };

  const { configureStore } = await import('@reduxjs/toolkit');
  const { handleUserWsEvent } = await import('../src/ui/api/wsInvalidation.ts');
  const notificationsMod: any = await import('../src/ui/store/notificationsSlice.ts');
  const { notificationsEnabledSet, notificationPermissionSet } = notificationsMod;
  const { heimdallApi }: any = await import('../src/ui/api/heimdallApi.ts');
  const store = configureStore({
    reducer: { notifications: notificationsMod.default, [heimdallApi.reducerPath]: heimdallApi.reducer },
    middleware: (getDefault: any) => getDefault().concat(heimdallApi.middleware),
  });

  store.dispatch(notificationPermissionSet('granted'));
  store.dispatch(notificationsEnabledSet(true));
  assert.equal((store.getState() as any).notifications.enabled, true, 'notifications enabled in store');

  const chatEvent = {
    type: 'chat_event',
    direction: 'agent_to_user',
    agent_instance_id: 'inst_a',
    conversation_id: 'conv_1',
    message: { message_id: 'm1', direction: 'agent_to_user', body: 'Build finished', created_unix_ms: Date.now() },
  };

  created.length = 0;
  view.visibility = 'hidden';
  view.focus = false;
  handleUserWsEvent(store.dispatch, chatEvent, {});
  await flush();
  assert.equal(created.length, 1, 'backgrounded curated event fires exactly one notification');
  assert.equal(created[0].options.tag, 'heimdall:chat:conv_1');

  created.length = 0;
  view.visibility = 'visible';
  view.focus = true;
  view.hash = '';
  handleUserWsEvent(store.dispatch, chatEvent, {});
  await flush();
  assert.equal(created.length, 1, 'focused but not viewing this conversation still notifies');

  created.length = 0;
  view.hash = '#/conversations/conv_1';
  handleUserWsEvent(store.dispatch, chatEvent, {});
  await flush();
  assert.equal(created.length, 0, 'focused + viewing this conversation fires no native notification');
  view.hash = '';

  created.length = 0;
  view.visibility = 'hidden';
  view.focus = false;
  handleUserWsEvent(store.dispatch, { type: 'agent_runtime_changed', agent_instance_id: 'inst_a' }, {});
  await flush();
  assert.equal(created.length, 0, 'excluded event never notifies');

  created.length = 0;
  handleUserWsEvent(store.dispatch, {
    type: 'chat_approval',
    event: 'chat_approval_created',
    approval: { approval_id: 'ap1', chain_id: 'chain_9', agent_instance_id: 'inst_a', kind: 'question', body: 'Deploy now?', state: 'open' },
  }, {});
  await flush();
  assert.equal(created.length, 1, 'chat_approval_created fires one notification');
  assert.equal(created[0].options.tag, 'heimdall:attention:approval:chain_9');
  store.dispatch(heimdallApi.util.resetApiState());
});
