import { test } from 'node:test';
import assert from 'node:assert/strict';

test('notificationService gates, open-thread suppression, click routing, and permission requests', async () => {
type Created = { title: string; options: any };
const created: Created[] = [];

const storage = new Map<string, string>();

class FakeNotification {
  title: string;
  options: any;
  onclick: (() => void) | null = null;
  static permission: 'default' | 'granted' | 'denied' = 'granted';
  static requestImpl: () => Promise<'default' | 'granted' | 'denied'> = async () => 'granted';
  constructor(title: string, options: any) {
    this.title = title;
    this.options = options;
    created.push({ title, options });
  }
  static async requestPermission() {
    return FakeNotification.requestImpl();
  }
  close() {}
}

const state = {
  visibility: 'hidden' as 'hidden' | 'visible',
  focus: false,
  hash: '',
  origin: 'https://hub.test',
  pathname: '/index.html',
  search: '',
};

(globalThis as any).document = {
  get visibilityState() { return state.visibility; },
  hasFocus() { return state.focus; },
  querySelector() { return { href: 'https://hub.test/favicon.png' }; },
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
  get location() {
    return {
      origin: state.origin,
      pathname: state.pathname,
      search: state.search,
      get hash() { return state.hash; },
      set hash(v: string) { state.hash = v; },
    };
  },
  focus() { state.focus = true; },
  open(url: string) { (globalThis as any).__lastOpen = url; return { focus() {} }; },
  odinApi: undefined,
};
// Also expose Notification globally (some code checks `'Notification' in window`).
(globalThis as any).Notification = FakeNotification;
// No service worker in this test env (Node's navigator has no `serviceWorker`),
// so the service falls back to the in-page Notification constructor.
(window as any).isSecureContext = true;

// showNativeNotification is async (SW path is awaited then falls back). Flush
// microtasks so the constructor fallback runs before we assert on `created`.
const flush = async () => { await Promise.resolve(); await Promise.resolve(); };

const {
  isTabBackgrounded,
  isNotificationSupported,
  isElectronRuntime,
  fireNotificationForWsEvent,
  showNativeNotification,
  requestNotificationPermission,
} = await import('../src/ui/services/notificationService.ts');

// --- basic gates ----------------------------------------------------------
assert.equal(isNotificationSupported(), true, 'FakeNotification => supported');
assert.equal(isElectronRuntime(), false, 'no odinApi => not electron');

state.visibility = 'hidden';
state.focus = false;
assert.equal(isTabBackgrounded(), true, 'hidden tab is backgrounded');

state.visibility = 'visible';
state.focus = true;
assert.equal(isTabBackgrounded(), false, 'visible+focused tab is foregrounded');

state.visibility = 'visible';
state.focus = false;
assert.equal(isTabBackgrounded(), true, 'visible-but-unfocused is backgrounded');

// --- settings that enable notifications ----------------------------------
function enabledState() {
  return {
    notifications: { enabled: true, permission: 'granted', categories: { chat: true, attention: true } },
  };
}

const chatPayload = {
  type: 'chat_event',
  direction: 'agent_to_user',
  conversation_id: 'conv_1',
  message: { direction: 'agent_to_user', body: 'hello there' },
};

// Focused tab, NOT viewing any conversation => still notify (new behavior:
// notify while focused unless the event targets the conversation on screen).
created.length = 0;
state.visibility = 'visible';
state.focus = true;
state.hash = '';
let plan = fireNotificationForWsEvent(() => enabledState(), chatPayload);
assert.ok(plan, 'focused but not viewing this conversation should notify');
await flush();
assert.equal(created.length, 1, 'one Notification when focused on a non-conversation view');

// Focused tab, viewing a DIFFERENT conversation => notify.
created.length = 0;
state.hash = '#/conversations/conv_other';
plan = fireNotificationForWsEvent(() => enabledState(), chatPayload);
assert.ok(plan, 'focused on another conversation should notify');
await flush();
assert.equal(created.length, 1, 'one Notification when viewing a different conversation');

// Focused tab, viewing THIS conversation => suppress (user already sees it).
created.length = 0;
state.hash = '#/conversations/conv_1';
plan = fireNotificationForWsEvent(() => enabledState(), chatPayload);
assert.equal(plan, null, 'focused + viewing this conversation must not notify');
assert.equal(created.length, 0, 'no Notification when already viewing the conversation');

// Focused tab, open conversation matched by the instance-id route segment =>
// suppress (routing is instance-id-only: #/conversations/{agentInstanceId}).
created.length = 0;
state.hash = '#/conversations/agent_1';
const chatByAgent = {
  type: 'chat_event', direction: 'agent_to_user',
  conversation_id: 'conv_1', agent_instance_id: 'agent_1',
  message: { direction: 'agent_to_user', body: 'hi' },
};
plan = fireNotificationForWsEvent(() => enabledState(), chatByAgent);
assert.equal(plan, null, 'suppressed when the open conversation matches by agent_instance_id');
assert.equal(created.length, 0, 'no Notification for the open thread matched via agent id');
state.hash = '';

// REQ-N1: unfocused tab + enabled => exactly one native notification.
created.length = 0;
state.visibility = 'hidden';
state.focus = false;
plan = fireNotificationForWsEvent(() => enabledState(), chatPayload);
assert.ok(plan, 'backgrounded + enabled should notify');
await flush();
assert.equal(created.length, 1, 'exactly one Notification');
assert.equal(created[0].options.tag, 'heimdall:chat:conv_1', 'tag set for coalescing');

// Disabled settings => skip.
created.length = 0;
plan = fireNotificationForWsEvent(() => ({ notifications: { enabled: false, permission: 'granted', categories: { chat: true, attention: true } } }), chatPayload);
assert.equal(plan, null, 'disabled => no notify');
assert.equal(created.length, 0);

// Permission not granted => skip even if enabled flag set.
created.length = 0;
plan = fireNotificationForWsEvent(() => ({ notifications: { enabled: true, permission: 'default', categories: { chat: true, attention: true } } }), chatPayload);
assert.equal(plan, null, 'permission!=granted => no notify');

// Per-category opt-out => skip.
created.length = 0;
plan = fireNotificationForWsEvent(() => ({ notifications: { enabled: true, permission: 'granted', categories: { chat: false, attention: true } } }), chatPayload);
assert.equal(plan, null, 'chat category off => no chat notify');

// Excluded event => skip.
created.length = 0;
plan = fireNotificationForWsEvent(() => enabledState(), { type: 'agent_runtime_changed' });
assert.equal(plan, null, 'excluded event => no notify');
assert.equal(created.length, 0);

// --- click => focus existing window + route ------------------------------
// Wrap Notification so we can capture the instance whose onclick the service
// wires up, then simulate the user clicking the OS notification.
let lastInstance: any = null;
const OrigNote = (window as any).Notification;
(window as any).Notification = class extends OrigNote {
  constructor(t: string, o: any) { super(t, o); lastInstance = this; }
} as any;
(globalThis as any).Notification = (window as any).Notification;

// Case 1: focus succeeds => hash navigation on existing window.
state.focus = false;
state.hash = '';
await showNativeNotification({ title: 'a', body: 'b', tag: 't2', route: '/conversations/conv_2', category: 'chat' });
lastInstance.onclick();
assert.match(state.hash, /#\/conversations\/conv_2/, 'click routes in existing window');

// Case 2: focus is BLOCKED (backgrounded tab) => still navigate the SAME tab
// in place; must NOT open a new window/tab (the originating tab still exists).
(window as any).focus = () => { /* browser blocks refocus from background */ };
state.focus = false;
state.hash = '';
(globalThis as any).__lastOpen = undefined;
await showNativeNotification({ title: 'a', body: 'b', tag: 't3', route: '/conversations/conv_3', category: 'chat' });
lastInstance.onclick();
assert.match(state.hash, /#\/conversations\/conv_3/, 'blocked focus still routes in the same tab');
assert.equal((globalThis as any).__lastOpen, undefined, 'must not open a duplicate tab when focus is merely blocked');

// Case 3: in-place hash navigation THROWS => fall back to a named new window.
const origLocation = Object.getOwnPropertyDescriptor(window, 'location');
Object.defineProperty(window, 'location', {
  configurable: true,
  get() {
    return {
      origin: state.origin, pathname: state.pathname, search: state.search,
      get hash() { return state.hash; },
      set hash(_v: string) { throw new Error('nav blocked'); },
    };
  },
});
(globalThis as any).__lastOpen = undefined;
await showNativeNotification({ title: 'a', body: 'b', tag: 't4', route: '/conversations/conv_4', category: 'chat' });
lastInstance.onclick();
assert.ok(String((globalThis as any).__lastOpen || '').includes('#/conversations/conv_4'), 'opens deep-link in new window only when in-place nav throws');
if (origLocation) Object.defineProperty(window, 'location', origLocation);

// --- requestNotificationPermission uses the browser API ------------------
FakeNotification.requestImpl = async () => 'granted';
assert.equal(await requestNotificationPermission(), 'granted');
FakeNotification.requestImpl = async () => 'denied';
assert.equal(await requestNotificationPermission(), 'denied');
FakeNotification.requestImpl = async () => { throw new Error('boom'); };
assert.equal(await requestNotificationPermission(), 'denied', 'thrown requestPermission => denied, no crash');
});
