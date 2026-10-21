// REQ-3: the user WebSocket connection loop (startUserWsConnection) end to end with a
// fake socket — first-open and reconnect resync, gap resync, HTTP 401 vs outage, close
// 4401, Electron ticket 401, and the bound on retries.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_user_ws_connection_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test, mock } from 'node:test';
import assert from 'node:assert/strict';

class FakeTarget extends EventTarget {}
const fakeWindow: any = new FakeTarget();
fakeWindow.setTimeout = (fn: any, ms: number) => globalThis.setTimeout(fn, ms);
fakeWindow.clearTimeout = (t: any) => globalThis.clearTimeout(t);
fakeWindow.setInterval = (fn: any, ms: number) => globalThis.setInterval(fn, ms);
fakeWindow.clearInterval = (t: any) => globalThis.clearInterval(t);
fakeWindow.location = { origin: 'http://hub.test', href: 'http://hub.test/' };
const fakeDocument: any = new FakeTarget();
fakeDocument.visibilityState = 'visible';
(globalThis as any).window ??= fakeWindow;
(globalThis as any).document ??= fakeDocument;

const { startUserWsConnection } = await import('../src/ui/api/useUserWebSocket.ts');
const { UserWsAuthError, UserWsStreamTracker, MAX_CONSECUTIVE_FAILURES, USER_WS_RESYNC_EVENT } = await import('../src/ui/api/userWsRecovery.ts');

class FakeSocket {
  readyState = 0;
  onopen: any = null;
  onmessage: any = null;
  onclose: any = null;
  onerror: any = null;
  sent: string[] = [];
  send(data: string) { this.sent.push(data); }
  close() { this.readyState = 3; }
  open() { this.readyState = 1; this.onopen?.({}); }
  frame(payload: any) { this.onmessage?.({ data: JSON.stringify(payload) }); }
  drop(code = 1006) { this.readyState = 3; this.onclose?.({ code }); }
}

type Harness = ReturnType<typeof harness>;
function harness(opts: { probe?: () => Promise<any>; resolveUrl?: () => Promise<string>; isElectron?: boolean } = {}) {
  const sockets: FakeSocket[] = [];
  const actions: any[] = [];
  const events: any[] = [];
  const delivered: any[] = [];
  const resyncReasons: string[] = [];
  let fullResyncs = 0;
  let probes = 0;
  const onResync = (e: any) => resyncReasons.push(e.detail.reason);
  window.addEventListener(USER_WS_RESYNC_EVENT, onResync);
  const dispatch = (a: any) => {
    if (typeof a === 'function') return a(dispatch, () => ({}));
    actions.push(a);
    return a;
  };
  const stop = startUserWsConnection({
    dispatch,
    tracker: new UserWsStreamTracker(),
    createSocket: () => { const s = new FakeSocket(); sockets.push(s); return s as any; },
    resolveUrl: opts.resolveUrl ?? (async () => 'ws://hub.test/api/v1/user-ws'),
    probeAuth: async () => { probes += 1; return opts.probe ? opts.probe() : 'unavailable'; },
    isElectron: () => Boolean(opts.isElectron),
    handleEvent: (_d, payload) => { delivered.push(payload); },
    fullResync: () => { fullResyncs += 1; },
  });
  return {
    sockets, actions, events, delivered, resyncReasons,
    get fullResyncs() { return fullResyncs; },
    get probes() { return probes; },
    last: () => sockets[sockets.length - 1],
    stop: () => { stop(); window.removeEventListener(USER_WS_RESYNC_EVENT, onResync); },
  };
}

const flush = async () => { for (let i = 0; i < 5; i++) await Promise.resolve(); };
const ready = (epoch: string) => ({ type: 'user_ws_ready', protocol_version: 2, stream_epoch: epoch, stream_seq: 0 });
const ev = (epoch: string, seq: number) => ({ type: 'task_event', stream_epoch: epoch, stream_seq: seq });

async function advance(ms: number) {
  mock.timers.tick(ms);
  await flush();
}

test('first open resyncs once (scoped), events deliver, a gap triggers one full resync', async () => {
  mock.timers.enable({ apis: ['setTimeout', 'setInterval', 'Date'] });
  try {
    const h = harness();
    await flush();
    assert.equal(h.sockets.length, 1);
    h.last().open();
    h.last().frame(ready('e-1'));
    assert.deepEqual(h.resyncReasons, ['initial']);
    assert.equal(h.fullResyncs, 0, 'first open must not invalidate every tag');
    h.last().frame(ev('e-1', 1));
    h.last().frame(ev('e-1', 2));
    assert.equal(h.delivered.length, 2);
    await advance(1500);
    h.last().frame(ev('e-1', 5));
    h.last().frame(ev('e-1', 9));
    assert.equal(h.delivered.length, 4, 'events after a gap still deliver');
    assert.equal(h.fullResyncs, 1, 'gap burst -> one immediate resync');
    await advance(1000);
    assert.equal(h.fullResyncs, 2, '... plus at most one trailing resync');
    await advance(10000);
    assert.equal(h.fullResyncs, 2);
    h.stop();
  } finally { mock.timers.reset(); }
});

test('reconnect after a drop resyncs once and fires heimdall:user-ws-reconnected', async () => {
  mock.timers.enable({ apis: ['setTimeout', 'setInterval', 'Date'] });
  try {
    let reconnected = 0;
    const onRe = () => { reconnected += 1; };
    window.addEventListener('heimdall:user-ws-reconnected', onRe);
    const h = harness();
    await flush();
    h.last().open();
    h.last().frame(ready('e-1'));
    h.last().drop(1006);
    await flush();
    assert.equal(h.probes, 0, 'a socket that was ready does not need an auth probe');
    await advance(31000);
    assert.equal(h.sockets.length, 2);
    h.last().open();
    h.last().frame(ready('e-2'));
    assert.equal(h.fullResyncs, 1);
    assert.equal(reconnected, 1);
    assert.deepEqual(h.resyncReasons, ['initial', 'reconnect']);
    h.stop();
    window.removeEventListener('heimdall:user-ws-reconnected', onRe);
  } finally { mock.timers.reset(); }
});

test('pre-upgrade HTTP 401 (seen via /api/v1/me) stops retrying until focus', async () => {
  mock.timers.enable({ apis: ['setTimeout', 'setInterval', 'Date'] });
  try {
    const h = harness({ probe: async () => 'unauthenticated' });
    await flush();
    h.last().drop(1006);
    await flush();
    assert.equal(h.probes, 1);
    await advance(10 * 60 * 1000);
    assert.equal(h.sockets.length, 1, 'no retry storm after a sign-out');
    window.dispatchEvent(new Event('focus'));
    await flush();
    assert.equal(h.sockets.length, 2, 'focus resumes');
    h.stop();
  } finally { mock.timers.reset(); }
});

test('outage (probe unavailable) retries with backoff and parks after a bounded count', async () => {
  mock.timers.enable({ apis: ['setTimeout', 'setInterval', 'Date'] });
  try {
    const h = harness({ probe: async () => 'unavailable' });
    await flush();
    for (let i = 0; i < MAX_CONSECUTIVE_FAILURES + 5; i++) {
      h.last().drop(1006);
      await flush();
      await advance(31000);
    }
    assert.equal(h.sockets.length, MAX_CONSECUTIVE_FAILURES + 1, 'bounded attempts');
    await advance(60 * 60 * 1000);
    assert.equal(h.sockets.length, MAX_CONSECUTIVE_FAILURES + 1, 'parked, not retrying forever');
    window.dispatchEvent(new Event('online'));
    await flush();
    assert.equal(h.sockets.length, MAX_CONSECUTIVE_FAILURES + 2, 'online resumes');
    h.stop();
  } finally { mock.timers.reset(); }
});

test('slot exhaustion close 1013 is retried without an auth probe', async () => {
  mock.timers.enable({ apis: ['setTimeout', 'setInterval', 'Date'] });
  try {
    const h = harness();
    await flush();
    h.last().drop(1013);
    await flush();
    assert.equal(h.probes, 0);
    await advance(31000);
    assert.equal(h.sockets.length, 2);
    h.stop();
  } finally { mock.timers.reset(); }
});

test('post-upgrade close 4401 stops and announces sign-out', async () => {
  mock.timers.enable({ apis: ['setTimeout', 'setInterval', 'Date'] });
  try {
    let signedOut = 0;
    const onOut = () => { signedOut += 1; };
    window.addEventListener('heimdall:api-unauthenticated', onOut);
    const h = harness();
    await flush();
    h.last().open();
    h.last().frame(ready('e-1'));
    h.last().drop(4401);
    await advance(10 * 60 * 1000);
    assert.equal(h.sockets.length, 1);
    assert.equal(signedOut, 1);
    h.stop();
    window.removeEventListener('heimdall:api-unauthenticated', onOut);
  } finally { mock.timers.reset(); }
});

test('Electron ticket 401 stops retrying', async () => {
  mock.timers.enable({ apis: ['setTimeout', 'setInterval', 'Date'] });
  try {
    let mints = 0;
    const h = harness({ isElectron: true, resolveUrl: async () => { mints += 1; throw new UserWsAuthError('unauthenticated', 'WebSocket ticket failed (401)'); } });
    await flush();
    await advance(10 * 60 * 1000);
    assert.equal(mints, 1);
    assert.equal(h.sockets.length, 0);
    h.stop();
  } finally { mock.timers.reset(); }
});
