// REQ-3: user WebSocket recovery — delivery-gap detection, first-open/reconnect resync,
// bounded coalescing, auth (HTTP 401) versus outage, and capped retries.
//
// RUN: node --test tests/ui_user_ws_recovery_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  INITIAL_BACKOFF_MS,
  MAX_BACKOFF_MS,
  MAX_CONSECUTIVE_FAILURES,
  UserWsStreamTracker,
  authProbeResultForStatus,
  classifyClose,
  createResyncScheduler,
  probeUserAuth,
  reconnectDelayMs,
  staleQueriesBefore,
} from '../src/ui/api/userWsRecovery.ts';

const ready = (epoch: string) => ({ type: 'user_ws_ready', protocol_version: 2, stream_epoch: epoch, stream_seq: 0 });
const ev = (epoch: string, seq: number, type = 'resource_changed') => ({ type, stream_epoch: epoch, stream_seq: seq });

test('first ready is an initial resync, every later ready a reconnect resync', () => {
  const t = new UserWsStreamTracker();
  assert.equal(t.onReady(ready('a-1')), 'initial');
  assert.equal(t.onReady(ready('a-2')), 'reconnect');
  assert.equal(t.onReady(ready('b-1')), 'reconnect');
});

test('contiguous events deliver without resync', () => {
  const t = new UserWsStreamTracker();
  t.onReady(ready('a-1'));
  for (let seq = 1; seq <= 50; seq++) assert.deepEqual(t.onEvent(ev('a-1', seq)), { deliver: true, resync: null });
});

test('a missing seq is a gap: the event still delivers and one resync is requested', () => {
  const t = new UserWsStreamTracker();
  t.onReady(ready('a-1'));
  t.onEvent(ev('a-1', 1));
  assert.deepEqual(t.onEvent(ev('a-1', 3)), { deliver: true, resync: 'gap' });
  assert.deepEqual(t.onEvent(ev('a-1', 4)), { deliver: true, resync: null });
});

test('owner-filtered stream: seq counts only this connection, so no false gap', () => {
  // The hub-global version jumps because of other users; stream_seq does not.
  const t = new UserWsStreamTracker();
  t.onReady(ready('a-1'));
  assert.deepEqual(t.onEvent({ ...ev('a-1', 1), version: 10 }), { deliver: true, resync: null });
  assert.deepEqual(t.onEvent({ ...ev('a-1', 2), version: 97 }), { deliver: true, resync: null });
});

test('every event type carries the stream (not only resource_changed)', () => {
  const t = new UserWsStreamTracker();
  t.onReady(ready('a-1'));
  for (const [i, type] of ['task_event', 'chat_message', 'messages_read', 'attention_changed', 'shell_session_event'].entries()) {
    assert.deepEqual(t.onEvent(ev('a-1', i + 1, type)), { deliver: true, resync: null });
  }
  assert.deepEqual(t.onEvent(ev('a-1', 7, 'task_event')), { deliver: true, resync: 'gap' });
});

test('resync_required (oversized event) is consumed and requests a resync', () => {
  const t = new UserWsStreamTracker();
  t.onReady(ready('a-1'));
  assert.deepEqual(t.onEvent({ ...ev('a-1', 1, 'resync_required'), reason: 'event_too_large' }), { deliver: false, resync: 'resync_required' });
  assert.deepEqual(t.onEvent(ev('a-1', 2)), { deliver: true, resync: null });
});

test('duplicate or stale seq is dropped; epoch change resyncs', () => {
  const t = new UserWsStreamTracker();
  t.onReady(ready('a-1'));
  t.onEvent(ev('a-1', 1));
  assert.deepEqual(t.onEvent(ev('a-1', 1)), { deliver: false, resync: null });
  assert.deepEqual(t.onEvent(ev('z-9', 5)), { deliver: true, resync: 'epoch_changed' });
});

test('protocol-1 hub (no stream fields) passes events through', () => {
  const t = new UserWsStreamTracker();
  t.onReady({ type: 'user_ws_ready', protocol_version: 1 });
  assert.deepEqual(t.onEvent({ type: 'task_event' }), { deliver: true, resync: null });
});

function fakeClock() {
  let now = 0;
  const timers: Array<{ at: number; fn: () => void; id: number }> = [];
  let nextId = 1;
  return {
    now: () => now,
    setTimer: (fn: () => void, ms: number) => { const id = nextId++; timers.push({ at: now + ms, fn, id }); return id; },
    clearTimer: (id: number) => { const i = timers.findIndex((t) => t.id === id); if (i >= 0) timers.splice(i, 1); },
    advance(ms: number) {
      now += ms;
      for (;;) {
        timers.sort((a, b) => a.at - b.at);
        if (!timers.length || timers[0].at > now) break;
        timers.shift()!.fn();
      }
    },
  };
}

test('resync bursts are coalesced: at most one immediate and one trailing run per window', () => {
  const clock = fakeClock();
  const runs: string[] = [];
  const s = createResyncScheduler((r) => runs.push(r), { minIntervalMs: 1000, ...clock });
  s.trigger('reconnect');
  for (let i = 0; i < 100; i++) s.trigger('gap');
  assert.deepEqual(runs, ['reconnect']);
  clock.advance(1000);
  assert.deepEqual(runs, ['reconnect', 'gap']);
  clock.advance(5000);
  assert.deepEqual(runs, ['reconnect', 'gap']);
});

test('a reconnect inside a pending gap window is not dropped by coalescing', () => {
  const clock = fakeClock();
  const runs: string[] = [];
  const s = createResyncScheduler((r) => runs.push(r), { minIntervalMs: 1000, ...clock });
  s.trigger('gap');
  s.trigger('resync_required');
  s.trigger('reconnect');
  s.trigger('gap');
  clock.advance(1000);
  assert.deepEqual(runs, ['gap', 'reconnect'], 'the trailing run keeps the reconnect reason');
});

test('a gap during the initial window widens the trailing resync', () => {
  const clock = fakeClock();
  const runs: string[] = [];
  const s = createResyncScheduler((r) => runs.push(r), { minIntervalMs: 1000, ...clock });
  s.trigger('initial');
  s.trigger('initial');
  s.trigger('gap');
  clock.advance(1000);
  assert.deepEqual(runs, ['initial', 'gap']);
});

test('initial resync targets only queries started before ready', () => {
  const queries = {
    a: { endpointName: 'listAgents', originalArgs: undefined, startedTimeStamp: 100, status: 'fulfilled' },
    b: { endpointName: 'getChat', originalArgs: { id: 'c1' }, startedTimeStamp: 250, status: 'fulfilled' },
    c: { endpointName: 'listChats', originalArgs: undefined, startedTimeStamp: 199, status: 'pending' },
  };
  assert.deepEqual(staleQueriesBefore(queries, 200).map((q) => q.endpointName), ['listAgents', 'listChats']);
  assert.deepEqual(staleQueriesBefore(undefined, 200), []);
});

test('HTTP 401/403 are auth stops; 5xx and network errors are outages', async () => {
  assert.equal(authProbeResultForStatus(401), 'unauthenticated');
  assert.equal(authProbeResultForStatus(403), 'forbidden');
  assert.equal(authProbeResultForStatus(200), 'ok');
  assert.equal(authProbeResultForStatus(502), 'unavailable');
  assert.equal(authProbeResultForStatus(503), 'unavailable');
  const respond = (status: number) => (async () => new Response('{}', { status })) as unknown as typeof fetch;
  assert.equal(await probeUserAuth('http://hub/api/v1/me', respond(401)), 'unauthenticated');
  assert.equal(await probeUserAuth('http://hub/api/v1/me', respond(504)), 'unavailable');
  const offline = (async () => { throw new TypeError('fetch failed'); }) as unknown as typeof fetch;
  assert.equal(await probeUserAuth('http://hub/api/v1/me', offline), 'unavailable');
});

test('close codes: 4401/4403 stop, 1013 is transient, 1006 is unknown (probe HTTP)', () => {
  assert.equal(classifyClose(4401), 'auth');
  assert.equal(classifyClose(4403), 'forbidden');
  assert.equal(classifyClose(1013), 'transient');
  assert.equal(classifyClose(1006), 'unknown');
  assert.equal(classifyClose(undefined), 'unknown');
});

test('retry delay is capped, jittered and bounded in count', () => {
  for (let f = 0; f < 40; f++) {
    const lo = reconnectDelayMs(f, () => 0);
    const hi = reconnectDelayMs(f, () => 0.999999);
    assert.ok(lo >= INITIAL_BACKOFF_MS / 2, `delay floor at ${f}`);
    assert.ok(hi <= MAX_BACKOFF_MS, `delay cap at ${f}`);
    assert.ok(hi > lo, 'jitter spreads the delay');
  }
  assert.equal(reconnectDelayMs(30, () => 0), MAX_BACKOFF_MS / 2);
  // Total wait before the hook parks is finite and bounded.
  let total = 0;
  for (let f = 0; f < MAX_CONSECUTIVE_FAILURES; f++) total += reconnectDelayMs(f, () => 1);
  assert.ok(total <= MAX_CONSECUTIVE_FAILURES * MAX_BACKOFF_MS);
});
