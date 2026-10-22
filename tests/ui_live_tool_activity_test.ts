import './helpers/vaultEndpointHarness.ts';
import { test, mock } from 'node:test';
import assert from 'node:assert/strict';
import { configureStore } from '@reduxjs/toolkit';
import { installWindowShim } from './helpers/vaultEndpointHarness.ts';
import reducer, {
  liveScopeMounted, liveScopeUnmounted, liveScopeKey, liveStreamReady, liveStreamDisconnected,
  liveResyncRequested, liveSnapshotStarted, liveSnapshotLoaded, liveFrameReceived,
  liveInstanceUnavailable, parseLiveSnapshot, newerSnapshot, LIVE_MEMBER_CAP,
  type LiveSnapshot, type LiveMember,
} from '../src/ui/store/toolActivitySlice.ts';
import { readLiveScope, fetchLiveScope, RosterChangedError } from '../src/ui/api/toolActivityLive.ts';

const key = liveScopeKey('inst_a');
function snapshot(overrides: Partial<LiveSnapshot> = {}): LiveSnapshot {
  return { type: 'tool_activity_live', instance_id: 'inst_a', agent_id: 'agt_a',
    display_name: 'Worker A', chain_id: 'chain_a', bridge_id: 'brg_a',
    epoch: '1792670400000000001', generation: 1, revision: 1, availability: 'ready',
    active: [{ call_id: 'provider-a', source: 'provider', tool_name: 'Read',
      shell_session_id: '', started_at_ms: 1000 }], last_completion: null, ...overrides };
}
function member(s: LiveSnapshot | null = snapshot(), id = s?.instance_id || 'inst_a'): LiveMember {
  return { instance_id: id, agent_id: 'agt_a', display_name: 'Worker A',
    snapshot: s, availability: s ? 'ready' : 'offline' };
}
function harness(chainId = '') {
  const store = configureStore({ reducer: { toolActivity: reducer } });
  const scopeKey = liveScopeKey('inst_a', chainId);
  store.dispatch(liveScopeMounted({ instanceId: 'inst_a', chainId }));
  store.dispatch(liveStreamReady());
  const scope = () => store.getState().toolActivity.scopes[scopeKey];
  const load = (members = [member()], requestId = 'r1') => {
    store.dispatch(liveSnapshotStarted({ key: scopeKey, requestId }));
    store.dispatch(liveSnapshotLoaded({ key: scopeKey, requestId, members }));
  };
  return { store, scope, load, key: scopeKey };
}

test('active provider and shell calls stay distinct, completion replaces active rows with scalar duration only', () => {
  const h = harness(); h.load();
  h.store.dispatch(liveFrameReceived(snapshot({ revision: 2, active: [
    ...snapshot().active,
    { call_id: 'shell-a', source: 'shell', tool_name: 'Shell', shell_session_id: 'sh_a', started_at_ms: 1200 },
  ] })));
  assert.equal(h.scope().members.inst_a.snapshot!.active.length, 2);
  const raw = { ...snapshot({ revision: 3, active: [], last_completion: { duration_ms: 900 } }),
    last_completion: { duration_ms: 900, tool_name: 'secret command', status: 'completed' }, arguments: 'secret args' };
  h.store.dispatch(liveFrameReceived(parseLiveSnapshot(raw)!));
  const final = h.scope().members.inst_a.snapshot!;
  assert.deepEqual(final.active, []);
  assert.deepEqual(final.last_completion, { duration_ms: 900 });
  assert.doesNotMatch(JSON.stringify(final), /secret|arguments/);
});

test('duplicate and reordered snapshots cannot resurrect completed calls', () => {
  const h = harness(); h.load([member(snapshot({ revision: 4, active: [], last_completion: { duration_ms: 50 } }))]);
  h.store.dispatch(liveFrameReceived(snapshot({ revision: 3 })));
  h.store.dispatch(liveFrameReceived(snapshot({ revision: 4 })));
  assert.deepEqual(h.scope().members.inst_a.snapshot!.active, []);
  h.store.dispatch(liveFrameReceived(snapshot({ revision: 5 })));
  assert.equal(h.scope().members.inst_a.snapshot!.active.length, 1);
});

test('Bridge epoch is compared without Number rounding; older epochs and generations are fenced', () => {
  const prior = snapshot({ epoch: '1792670400000000002', revision: 500, generation: 5 });
  assert.equal(newerSnapshot(snapshot({ epoch: '1792670400000000001', revision: 999 }), prior), false);
  assert.equal(newerSnapshot(snapshot({ epoch: '1792670400000000003', revision: 0 }), prior), true);
  assert.equal(newerSnapshot(snapshot({ epoch: prior.epoch, generation: 4, revision: 501 }), prior), false);
  const h = harness(); h.load([member(prior)]);
  h.store.dispatch(liveFrameReceived(snapshot({ epoch: '1792670400000000003', revision: 0, active: [] })));
  h.store.dispatch(liveFrameReceived(prior));
  assert.deepEqual(h.scope().members.inst_a.snapshot!.active, []);
});

test('newest live completion wins a stale initial snapshot, never exposing completed history', () => {
  const h = harness();
  h.store.dispatch(liveSnapshotStarted({ key, requestId: 'r1' }));
  h.store.dispatch(liveFrameReceived(snapshot({ revision: 5, active: [], last_completion: { duration_ms: 10 } })));
  h.store.dispatch(liveFrameReceived(snapshot({ revision: 3 })));
  h.store.dispatch(liveSnapshotLoaded({ key, requestId: 'r1', members: [member()] }));
  assert.equal(h.scope().members.inst_a.snapshot!.revision, 5);
  assert.deepEqual(h.scope().members.inst_a.snapshot!.active, []);
  assert.deepEqual(h.scope().pending, {});
});

test('disconnect clears immediately; old HTTP responses and offline frames cannot rehydrate a new connection', () => {
  const h = harness(); h.load();
  h.store.dispatch(liveStreamDisconnected());
  h.store.dispatch(liveFrameReceived(snapshot({ revision: 10 })));
  h.store.dispatch(liveSnapshotLoaded({ key, requestId: 'r1', members: [member()] }));
  assert.deepEqual(h.scope().members, {});
  h.store.dispatch(liveStreamReady());
  h.store.dispatch(liveSnapshotStarted({ key, requestId: 'r2' }));
  h.store.dispatch(liveSnapshotLoaded({ key, requestId: 'r1', members: [member()] }));
  assert.deepEqual(h.scope().members, {});
  h.store.dispatch(liveSnapshotLoaded({ key, requestId: 'r2', members: [member(snapshot({ revision: 20, active: [] }))] }));
  assert.equal(h.scope().members.inst_a.snapshot!.revision, 20);
});

test('unavailable during snapshot fences both response and late frames until resync', () => {
  const h = harness('chain_a');
  h.store.dispatch(liveSnapshotStarted({ key: h.key, requestId: 'r1' }));
  h.store.dispatch(liveInstanceUnavailable('inst_a'));
  h.store.dispatch(liveFrameReceived(snapshot({ revision: 5 })));
  h.store.dispatch(liveSnapshotLoaded({ key: h.key, requestId: 'r1', members: [member()] }));
  assert.equal(h.scope().members.inst_a.snapshot, null);
  h.store.dispatch(liveResyncRequested()); h.load();
  assert.equal(h.scope().members.inst_a.snapshot!.active.length, 1);
});

test('offline authoritative member cannot be resurrected by a frame buffered before its snapshot', () => {
  const h = harness('chain_a');
  h.store.dispatch(liveFrameReceived(snapshot({ revision: 9 })));
  h.load([member(null)]);
  assert.equal(h.scope().members.inst_a.snapshot, null);
  h.store.dispatch(liveFrameReceived(snapshot({ revision: 10 })));
  assert.equal(h.scope().members.inst_a.snapshot, null);
});

test('chain frames require roster inclusion, preserve separate runs, and remove former members', () => {
  const h = harness('chain_a');
  const other = snapshot({ instance_id: 'inst_b', agent_id: 'agt_a' });
  h.store.dispatch(liveFrameReceived(snapshot({ instance_id: 'inst_foreign', chain_id: 'chain_other' })));
  h.load([member(), member(other)]);
  assert.deepEqual(Object.keys(h.scope().members), ['inst_a', 'inst_b']);
  h.store.dispatch(liveFrameReceived(snapshot({ instance_id: 'inst_foreign' })));
  assert.equal(h.scope().members.inst_foreign, undefined);
  h.store.dispatch(liveResyncRequested());
  h.load([member(other)], 'r2');
  assert.equal(h.scope().members.inst_a, undefined);
  assert.equal(h.scope().members.inst_b.snapshot!.agent_id, 'agt_a');
});

test('bounded pending buffer fails closed rather than silently applying a raced stale snapshot', () => {
  const h = harness('chain_a');
  for (let i = 0; i <= LIVE_MEMBER_CAP; i++) h.store.dispatch(liveFrameReceived(snapshot({ instance_id: 'inst_' + i })));
  assert.equal(Object.keys(h.scope().pending).length, LIVE_MEMBER_CAP);
  h.load();
  assert.deepEqual(h.scope().members, {});
  assert.match(h.scope().error, /buffer full/);
});

test('scope reference counts share projection and final unmount forgets all state', () => {
  const h = harness(); h.load();
  h.store.dispatch(liveScopeMounted({ instanceId: 'inst_a', chainId: '' }));
  h.store.dispatch(liveScopeUnmounted(key));
  assert.equal(h.scope().refs, 1);
  h.store.dispatch(liveScopeUnmounted(key));
  assert.equal(h.scope(), undefined);
});

test('parser enforces active count/field limits, rejects duplicates and negative/nonfinite durations', () => {
  assert.equal(parseLiveSnapshot(snapshot({ active: Array(33).fill(snapshot().active[0]) })), null);
  assert.equal(parseLiveSnapshot(snapshot({ active: [snapshot().active[0], snapshot().active[0]] })), null);
  assert.equal(parseLiveSnapshot(snapshot({ instance_id: 'x'.repeat(65) })), null);
  assert.equal(parseLiveSnapshot(snapshot({ epoch: 'not-numeric' })), null);
  assert.equal(parseLiveSnapshot(snapshot({ last_completion: { duration_ms: -1 } })), null);
  assert.equal(parseLiveSnapshot(snapshot({ last_completion: { duration_ms: Infinity } })), null);
  assert.equal(parseLiveSnapshot(snapshot({ active: [{ ...snapshot().active[0], tool_name: 'x'.repeat(97) }] })), null);
});

test('instance handshake uses only the owner REST proxy with no-store and a deadline', async () => {
  const calls: any[] = [];
  const result = await readLiveScope({ instanceId: 'inst_a', chainId: '' }, async (path, init) => {
    calls.push({ path, init }); return snapshot();
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].path, '/agent-instances/inst_a/tool-activity-live');
  assert.equal(calls[0].init.cache, 'no-store');
  assert.ok(calls[0].init.signal instanceof AbortSignal);
  assert.equal(result[0].snapshot!.instance_id, 'inst_a');
});

test('paged chain handshake follows raw cursor and returns full roster, including offline and cross-current-chain coordinators', async () => {
  const paths: string[] = [];
  const result = await readLiveScope({ instanceId: 'inst_a', chainId: 'chain_a' }, async (path) => {
    paths.push(path);
    return paths.length === 1
      ? { chain_id: 'chain_a', roster_token: 'roster1', members: [member()], next_cursor: 'inst_a' }
      : { chain_id: 'chain_a', roster_token: 'roster1', members: [
        member(null, 'inst_b'), member(snapshot({ instance_id: 'inst_c', chain_id: 'other_chain' })),
      ], next_cursor: '' };
  });
  assert.deepEqual(result.map((m) => m.instance_id), ['inst_a', 'inst_b', 'inst_c']);
  assert.match(paths[1], /\?cursor=inst_a$/);
  assert.equal(result[1].snapshot, null);
});

test('membership changes mid-page abort atomic roster replacement', async () => {
  let calls = 0;
  await assert.rejects(readLiveScope({ instanceId: 'inst_a', chainId: 'chain_a' }, async () => {
    calls++;
    return { chain_id: 'chain_a', roster_token: String(calls), members: [member(null, 'inst_' + calls)],
      next_cursor: calls === 1 ? 'inst_1' : '' };
  }), RosterChangedError);
  assert.equal(calls, 2);
});

test('bad cursor and foreign/invalid member snapshots fail closed', async () => {
  const read = (overrides: any) => async () => ({
    chain_id: 'chain_a', roster_token: 'v1', members: [member()], next_cursor: '', ...overrides,
  });
  await assert.rejects(readLiveScope({ instanceId: 'inst_a', chainId: 'chain_a' }, read({ next_cursor: 'stuck' })), /cursor/);
  await assert.rejects(readLiveScope({ instanceId: 'inst_a', chainId: 'chain_a' }, read({ chain_id: 'foreign' })), /roster/);
  await assert.rejects(readLiveScope({ instanceId: 'inst_a', chainId: 'chain_a' },
    read({ members: [{ ...member(), snapshot: snapshot({ instance_id: 'wrong' }) }] })), /snapshot/);
});

test('one successful fetch is shared by duplicate panes and idle time causes zero requests', async () => {
  installWindowShim();
  const previous = globalThis.fetch;
  let requests = 0;
  globalThis.fetch = async () => { requests++; return new Response(JSON.stringify({ data: snapshot() })); };
  mock.timers.enable({ apis: ['setTimeout', 'setInterval'] });
  try {
    const h = harness();
    await Promise.all([h.store.dispatch(fetchLiveScope(key)), h.store.dispatch(fetchLiveScope(key))]);
    assert.equal(requests, 1);
    mock.timers.tick(300_000);
    assert.equal(requests, 1);
    h.store.dispatch(liveFrameReceived(snapshot({ revision: 2, active: [] })));
    mock.timers.tick(300_000);
    assert.equal(requests, 1);
    assert.deepEqual(h.scope().members.inst_a.snapshot!.active, []);
  } finally { mock.timers.reset(); globalThis.fetch = previous; }
});

test('actual offline/busy errors expose manual retry without a busy loop', async () => {
  installWindowShim();
  const previous = globalThis.fetch;
  let requests = 0;
  globalThis.fetch = async () => { requests++; return new Response(JSON.stringify({
    error: { code: 'bridge_offline', message: 'Bridge offline' },
  }), { status: 409 }); };
  mock.timers.enable({ apis: ['setTimeout', 'setInterval'] });
  try {
    const h = harness();
    await h.store.dispatch(fetchLiveScope(key));
    assert.match(h.scope().error, /Bridge offline/);
    mock.timers.tick(600_000);
    assert.equal(requests, 1);
    assert.deepEqual(h.scope().members, {});
  } finally { mock.timers.reset(); globalThis.fetch = previous; }
});

test('real REST chat endpoint preserves raw cursor through hidden-only pages and read receipt metadata', async () => {
  installWindowShim();
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const { chatEndpoints } = await import('../src/ui/api/endpoints/chats.ts');
  const { groupTranscriptMessages } = await import('../src/ui/components/chat/transcriptGrouping.ts');
  const previous = globalThis.fetch;
  const cursors: string[] = [];
  globalThis.fetch = async (url: any) => {
    const cursor = new URL(String(url), 'https://hub.test').searchParams.get('cursor') || '';
    cursors.push(cursor);
    const hidden = (id: string, type: string) => ({ message_id: id, message_type: type, body: 'marker', read_unix_ms: 123 });
    return new Response(JSON.stringify(cursor === ''
      ? { data: [hidden('m3', 'tool_activity'), hidden('m2', 'shell_run')], page: { next_cursor: 'raw2', has_more: true } }
      : { data: [{ message_id: 'm1', message_type: 'text', body: 'real message', read_unix_ms: 456 }], page: { next_cursor: '', has_more: false } }));
  };
  const store = configureStore({ reducer: { [heimdallApi.reducerPath]: heimdallApi.reducer },
    middleware: (gdm) => gdm().concat(heimdallApi.middleware) });
  try {
    const first: any = await store.dispatch(chatEndpoints.endpoints.fetchConversationMessages.initiate(
      { conversationId: 'chat_a' }, { subscribe: false })).unwrap();
    assert.equal(first.nextCursor, 'raw2'); assert.equal(first.hasMore, true);
    assert.deepEqual(groupTranscriptMessages(first.messages.map((m: any) => ({ ...m, messageType: m.message_type }))), []);
    assert.equal(first.messages.length, 2); assert.equal(first.messages[0].read_unix_ms, 123);
    const second: any = await store.dispatch(chatEndpoints.endpoints.fetchConversationMessages.initiate(
      { conversationId: 'chat_a', cursor: first.nextCursor }, { subscribe: false })).unwrap();
    assert.equal(second.messages[0].body, 'real message');
    assert.equal(second.messages[0].read_unix_ms, 456);
    assert.equal(second.hasMore, false); assert.deepEqual(cursors, ['', 'raw2']);
  } finally { store.dispatch(heimdallApi.util.resetApiState()); globalThis.fetch = previous; }
});

test('real WS funnel applies tools silently and ordinary extension/status events do not request tool snapshots', async () => {
  installWindowShim();
  const { handleUserWsEvent } = await import('../src/ui/api/wsInvalidation.ts');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const store = configureStore({ reducer: { toolActivity: reducer, [heimdallApi.reducerPath]: heimdallApi.reducer },
    middleware: (gdm) => gdm().concat(heimdallApi.middleware) });
  store.dispatch(liveScopeMounted({ instanceId: 'inst_a', chainId: '' }));
  store.dispatch(liveStreamReady());
  store.dispatch(liveSnapshotStarted({ key, requestId: 'r1' }));
  store.dispatch(liveSnapshotLoaded({ key, requestId: 'r1', members: [member()] }));
  const h = { store, scope: () => store.getState().toolActivity.scopes[key] };
  const before = h.store.getState().toolActivity.refresh;
  handleUserWsEvent(h.store.dispatch, snapshot({ revision: 2, active: [], last_completion: { duration_ms: 99 } }));
  assert.deepEqual(h.scope().members.inst_a.snapshot!.active, []);
  assert.equal(h.store.getState().toolActivity.refresh, before);
  handleUserWsEvent(h.store.dispatch, { type: 'resource_changed', resource: 'agent_instance', resource_id: 'inst_a',
    change: 'extension_events', summary: { events: [{ event: 'tool.end' }] } });
  handleUserWsEvent(h.store.dispatch, { type: 'resource_changed', resource: 'agent_instance', resource_id: 'inst_a',
    change: 'status_changed', summary: { runtime_status: 'running' } });
  assert.equal(h.store.getState().toolActivity.refresh, before);
  handleUserWsEvent(h.store.dispatch, { type: 'tool_activity_live_unavailable', instance_id: 'inst_a', availability: 'offline' });
  assert.equal(h.scope().members.inst_a.snapshot, null);
  handleUserWsEvent(h.store.dispatch, { type: 'tool_activity_live_resync', bridge_id: 'brg_a' });
  assert.equal(h.store.getState().toolActivity.refresh, before + 1);
});
