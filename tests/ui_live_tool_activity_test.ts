import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { harness, snapshot, FakeToolSocket } from './helpers/toolStreamHarness.ts';
import { ToolActivityStream } from '../src/ui/api/toolActivityStream.ts';
import { parseLiveSnapshot, compareToolOrder } from '../src/ui/store/toolActivitySlice.ts';

test('shared views deduplicate membership, replace sets, and last unmount cleans all resources', async () => {
  const h = harness();
  const own = h.stream.subscribe('user1', ['inst_a']);
  const chain = h.stream.subscribe('user1', ['inst_a', 'inst_b', 'inst_b']);
  await h.flush();
  assert.equal(h.sockets.length, 1);
  const s = h.sockets[0]; s.open();
  assert.deepEqual(s.sent, [{ type: 'subscribe', instance_ids: ['inst_a', 'inst_b'] }]);
  assert.equal(h.timers.size, 1); assert.equal(h.resumeListeners, 1);
  s.state(snapshot()); s.state(snapshot('inst_b'));
  own.release();
  assert.equal(s.sent.length, 1, 'shared instance stays subscribed');
  chain.update(['inst_b', 'inst_c']);
  assert.deepEqual(s.sent.at(-1).instance_ids, ['inst_b', 'inst_c']);
  assert.equal(h.member('inst_a'), undefined);
  assert.equal(h.member('inst_b').snapshot?.active.length, 1);
  assert.equal(h.sockets.length, 1, 'membership changes reuse socket');
  chain.release();
  assert.equal(s.closeCount, 1); assert.equal(h.timers.size, 0); assert.equal(h.resumeListeners, 0);
  assert.deepEqual(h.store.getState().toolActivity.members, {});
  h.advance(300_000); await h.flush();
  assert.equal(h.sockets.length, 1);
});

test('baseline, replacement batches, empty state and ordering accept refreshes but reject old revisions/generations', async () => {
  const h = harness(), view = h.stream.subscribe('u', ['inst_a']); await h.flush();
  const s = h.sockets[0]; s.open();
  s.state(snapshot(), false);
  assert.equal(h.member().snapshot, null, 'new connection requires baseline');
  s.state(snapshot());
  const complete = { call_id: 'finished', source: 'provider', tool_name: 'Read', summary: '/file',
    summary_truncated: false, duration_ms: 1250, completed_at_ms: 1500, status: 'completed' };
  s.state(snapshot('inst_a', 2, { active: [], completed_since_last: [complete] }), false);
  assert.equal(h.member().snapshot?.completed_since_last.length, 1);
  s.state(snapshot('inst_a', 1), false);
  assert.equal(h.member().snapshot?.active.length, 0);
  s.state(snapshot('inst_a', 2, { active: [], completed_since_last: [] }), false, true);
  assert.equal(h.member().snapshot?.completed_since_last.length, 0, 'batch replaced, never accumulated');
  s.state(snapshot('inst_a', 0, { generation: 2 }), false);
  assert.equal(h.member().snapshot?.generation, 2, 'generation precedes revision');
  s.state(snapshot('inst_a', 999, { generation: 1 }), true);
  assert.equal(h.member().snapshot?.generation, 2);
  view.release();
});

test('same revision at 60s refreshes only that instance; active call older than 2m stays visible', async () => {
  const h = harness(), view = h.stream.subscribe('u', ['inst_a', 'inst_b']); await h.flush();
  const s = h.sockets[0]; s.open(); s.state(snapshot()); s.state(snapshot('inst_b'));
  h.advance(60_000); s.state(snapshot(), false, true);
  h.advance(59_000);
  assert.equal(h.member('inst_b').availability, 'ready');
  h.advance(1000);
  assert.equal(h.member('inst_b').availability, 'unavailable', 'other states and pong cannot refresh B');
  assert.equal(h.member('inst_b').snapshot, null);
  s.state(snapshot(), false, true);
  h.advance(60_000); s.state(snapshot(), false, true);
  assert.equal(h.member().snapshot?.active.length, 1, 'started_at_ms never controls receipt freshness');
  h.advance(119_000);
  assert.equal(h.member().availability, 'ready');
  h.advance(1000);
  assert.equal(h.member().availability, 'unavailable', 'expires exactly 120s after own valid state');
  view.release();
});

test('invalid/stale/duplicate ordinary states and pong do not extend freshness', async () => {
  const h = harness(), view = h.stream.subscribe('u', ['inst_a']); await h.flush();
  const s = h.sockets[0]; s.open(); s.state(snapshot('inst_a', 2));
  h.advance(60_000);
  s.state(snapshot('inst_a', 2), false);
  s.state(snapshot('inst_a', 1), false, true);
  s.state(snapshot('inst_a', 3, { active: [{ ...snapshot().active[0], summary: 'x'.repeat(513) }] }), false);
  h.advance(60_000);
  assert.equal(h.member().availability, 'unavailable');
  view.release();
});

for (const loss of ['close', 'error', 'unavailable', 'pong timeout']) {
  test(loss + ' clears active and completed without inventing terminal results', async () => {
    const h = harness(), view = h.stream.subscribe('u', ['inst_a', 'inst_b']); await h.flush();
    const s = h.sockets[0]; s.open(); s.state(snapshot());
    s.state(snapshot('inst_b', 1, { active: [], completed_since_last: [{
      call_id: 'c', source: 'provider', tool_name: 'Read', summary: 'file', summary_truncated: false,
      status: 'completed', duration_ms: 1, completed_at_ms: 10,
    }] }));
    if (loss === 'close') s.onclose?.();
    if (loss === 'error') s.onerror?.();
    if (loss === 'unavailable') {
      s.frame({ type: 'unavailable', instance_id: 'inst_a', reason: 'bridge_offline' });
      assert.equal(h.member('inst_b').availability, 'ready', 'unavailable is per instance');
      s.frame({ type: 'unavailable', instance_id: 'inst_b', reason: 'bridge_offline' });
    }
    if (loss === 'pong timeout') {
      h.advance(44_000, false);
      assert.equal(h.member().availability, 'ready');
      h.advance(1000, false);
    }
    for (const id of ['inst_a', 'inst_b']) {
      assert.equal(h.member(id).availability, 'unavailable');
      assert.equal(h.member(id).snapshot, null);
    }
    view.release();
  });
}

test('reconnect/resume earn fresh baseline, mint new URL and reject late old socket callbacks', async () => {
  const h = harness(), view = h.stream.subscribe('u', ['inst_a']); await h.flush();
  const old = h.sockets[0]; old.open(); old.state(snapshot());
  const late = old.onmessage!;
  h.resume();
  assert.equal(h.member().snapshot, null);
  await h.flush();
  const current = h.sockets[1]; current.open();
  assert.notEqual(current.url, old.url);
  assert.deepEqual(current.sent.at(-1).instance_ids, ['inst_a']);
  late({ data: JSON.stringify({ type: 'state', instance_id: 'inst_a', baseline: true, refresh: false,
    snapshot: snapshot('inst_a', 999) }) });
  assert.equal(h.member().snapshot, null);
  current.state(snapshot('inst_a', 2));
  assert.equal(h.member().availability, 'ready');
  current.onclose?.();
  h.advance(1000); await h.flush();
  assert.equal(h.sockets.length, 3);
  h.sockets[2].open(); h.sockets[2].state(snapshot('inst_a', 3));
  assert.equal(h.member().snapshot?.revision, 3);
  view.release();
});

test('user switch fences pending auth URL and old subscriptions cannot mutate new user', async () => {
  let finish!: (value: string) => void;
  let aborted = false;
  const sockets: FakeToolSocket[] = [];
  const stream = new ToolActivityStream(() => {}, {
    now: () => 0,
    url: (signal) => new Promise((resolve) => { finish = resolve; signal.addEventListener('abort', () => { aborted = true; }); }),
    socket: (url) => { const s = new FakeToolSocket(url); sockets.push(s); return s; },
    every: () => () => {}, onResume: () => () => {},
  });
  const old = stream.subscribe('old', ['inst_a']);
  const finishOld = finish;
  const current = stream.subscribe('new', ['inst_b']);
  assert.equal(aborted, true);
  finishOld('wss://old');
  await Promise.resolve();
  assert.equal(sockets.length, 0);
  finish('wss://new'); await Promise.resolve();
  old.update(['inst_c']); old.release();
  sockets[0].open();
  assert.deepEqual(sockets[0].sent[0].instance_ids, ['inst_b']);
  current.release();
});

test('parser enforces UTF-8/array/id bounds and retains no arbitrary args/results', () => {
  const raw = snapshot();
  raw.active[0].summary = 'é'.repeat(256);
  (raw.active[0] as any).arguments = 'secret';
  const parsed = parseLiveSnapshot(raw)!;
  assert.ok(parsed); assert.equal((parsed.active[0] as any).arguments, undefined);
  raw.active[0].summary += 'é'; assert.equal(parseLiveSnapshot(raw), null);
  assert.equal(parseLiveSnapshot(snapshot('wrong')), null);
  assert.equal(parseLiveSnapshot(snapshot('inst_a', 1, { active: Array(33).fill(snapshot().active[0]) })), null);
  assert.ok(compareToolOrder({ epoch: '10000000000000000001', generation: 1, revision: 1 },
    { epoch: '9999999999999999999', generation: 999, revision: 999 }) > 0);
});

test('obsolete REST and general-event tool plumbing are absent', () => {
  assert.equal(fs.existsSync('src/ui/api/toolActivityLive.ts'), false);
  for (const path of ['src/ui/api/useUserWebSocket.ts', 'src/ui/api/wsInvalidation.ts']) {
    assert.doesNotMatch(fs.readFileSync(path, 'utf8'), /liveStream|liveResync|tool_activity_live/);
  }
  assert.doesNotMatch(fs.readFileSync('src/ui/api/toolActivityStream.ts', 'utf8'), /cookieJsonFetch|fetch\(/);
});

test('empty views hold no socket/timer; over-capacity rosters fail visibly and recover when reduced', async () => {
  const h = harness();
  const view = h.stream.subscribe('u', []);
  await h.flush();
  assert.equal(h.timers.size, 0); assert.equal(h.sockets.length, 0);
  view.update(Array.from({ length: 257 }, (_, i) => 'inst_' + i));
  assert.equal(h.store.getState().toolActivity.capacityExceeded, true);
  assert.equal(h.timers.size, 0);
  view.update(['inst_a']); await h.flush();
  assert.equal(h.store.getState().toolActivity.capacityExceeded, false);
  assert.equal(h.sockets.length, 1);
  h.sockets[0].open(); h.sockets[0].state(snapshot());
  assert.equal(h.member().availability, 'ready');
  view.update([]);
  assert.equal(h.timers.size, 0);
  assert.equal(h.sockets[0].readyState, 3);
  view.release();
});

test('unavailable relocation baseline can reset producer epoch/order without reviving retired frames', async () => {
  const h = harness(), view = h.stream.subscribe('u', ['inst_a']); await h.flush();
  const s = h.sockets[0]; s.open(); s.state(snapshot('inst_a', 50));
  s.frame({ type: 'unavailable', instance_id: 'inst_a', reason: 'instance_changed' });
  s.state(snapshot('inst_a', 100), false);
  assert.equal(h.member().snapshot, null, 'old changed frame cannot replace awaited baseline');
  s.state(snapshot('inst_a', 1, { epoch: '123', generation: 1, bridge_id: 'brg_destination', active: [] }));
  assert.equal(h.member().availability, 'ready');
  assert.equal(h.member().snapshot?.bridge_id, 'brg_destination');
  view.release();
});

test('pending socket open times out; server protocol error clears state and schedules bounded reconnect', async () => {
  const h = harness(), view = h.stream.subscribe('u', ['inst_a']); await h.flush();
  h.advance(15_000);
  assert.equal(h.sockets[0].readyState, 3);
  assert.equal(h.member().availability, 'unavailable');
  h.advance(1000); await h.flush();
  h.sockets[1].open(); h.sockets[1].state(snapshot());
  h.sockets[1].frame({ type: 'error', code: 'capacity', message: 'busy' });
  assert.equal(h.member().snapshot, null);
  view.release();
});
