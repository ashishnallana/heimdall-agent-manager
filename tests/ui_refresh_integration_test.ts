// refresh_integrate: request-count regressions for event-driven refresh. Every test
// drives the REAL store, endpoints and user-WS consumer (handleUserWsEvent) against a
// stubbed fetch, feeds the hub's owner-scoped event frames (contract: refresh_producers
// resource_events.odin / messages_read_event_json) and asserts which requests reach the
// wire. The poll-retirement guard at the end checks the retired caller options in source.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_refresh_integration_test.ts

import { after, beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { makeVaultStore as makeHarnessStore, REPO_ROOT } from './helpers/vaultEndpointHarness.ts';

// node has no window; the pane signal (conversationMessageEvents) dispatches on it.
if (typeof (globalThis as any).window === 'undefined') (globalThis as any).window = new EventTarget();

const stores: any[] = [];
async function makeStore() {
  const store = await makeHarnessStore();
  stores.push(store);
  return store;
}
after(async () => {
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const { resetQueuedInvalidations } = await import('../src/ui/api/wsInvalidation.ts');
  resetQueuedInvalidations();
  for (const store of stores) store.dispatch(heimdallApi.util.resetApiState());
});
beforeEach(async () => {
  const { resetQueuedInvalidations } = await import('../src/ui/api/wsInvalidation.ts');
  const { resetLocalMessageEchoes } = await import('../src/ui/api/conversationMessageEvents.ts');
  resetQueuedInvalidations();
  resetLocalMessageEchoes();
});

type Reply = { status?: number; body: any } | ((url: URL, init: any) => { status?: number; body: any } | Promise<{ status?: number; body: any }>);
type Routes = Record<string, Reply>;

function reply(status: number, body: any) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: (h: string) => (h.toLowerCase() === 'content-type' ? 'application/json' : null) },
    text: async () => JSON.stringify(body),
    json: async () => body,
  } as any;
}

// Same routing rules as ui_refresh_request_reduction_test.ts: "METHOD /path" first,
// then "/path"; longest suffix wins; unrouted requests answer {data:{}}.
function installRoutes(routes: Routes): { hits: string[]; restore: () => void } {
  const hits: string[] = [];
  const prev = (globalThis as any).fetch;
  (globalThis as any).fetch = async (input: any, init: any = {}) => {
    const url = new URL(String(input?.url ?? input), 'http://localhost');
    const method = String(init?.method || 'GET').toUpperCase();
    hits.push(`${method} ${url.pathname}${url.search}`);
    const p = url.pathname.replace(/^\/api\/v1/, '');
    const keys = Object.keys(routes)
      .filter((k) => (k.includes(' ') ? k === `${method} ${p}` || (k.startsWith(`${method} `) && p.endsWith(k.slice(method.length + 1))) : p.endsWith(k)))
      .sort((a, b) => b.length - a.length);
    const r = keys.length ? routes[keys[0]] : { body: { data: {} } };
    const out = typeof r === 'function' ? await r(url, init) : r;
    return reply(out.status ?? 200, out.body);
  };
  return { hits, restore: () => { (globalThis as any).fetch = prev; } };
}

const tick = (ms = 20) => new Promise((r) => setTimeout(r, ms));
const count = (hits: string[], pred: (h: string) => boolean) => hits.filter(pred).length;

async function settle() {
  const { INVALIDATION_COALESCE_MS } = await import('../src/ui/api/wsInvalidation.ts');
  await tick(INVALIDATION_COALESCE_MS + 60);
}

const CONV = 'chat_1';
const INST = 'inst_1';
const messagesRoute = (rows: any[]) => ({ body: { data: rows, page: { has_more: true, next_cursor: 'older1' } } });
const userRow = (id: string, extra: any = {}) => ({ message_id: id, conversation_id: CONV, direction: 'user_to_agent', body: id, created_at: '2026-10-21T10:00:00Z', ...extra });

function messageCreated(messageId: string) {
  return {
    type: 'chat_event', event: 'message_created', conversation_id: CONV, agent_instance_id: INST,
    message_id: messageId, direction: 'user_to_agent', message_type: 'text', created_at: '2026-10-21T10:05:00Z',
    last_message_at: '2026-10-21T10:05:00Z', unread_count: 0, fetch_required: true, fetch_kind: 'chat_message', fetch_id: messageId,
  };
}

function instanceSummary(extra: any = {}) {
  return {
    runtime_status: 'running', startup_status: 'ready', activity_status: 'idle', display_name: 'Worker',
    bridge_id: 'brg_1', provider: 'claude', model: 'm1', configuration_revision: 1, run_count: 1,
    started_at: '2026-10-21T09:00:00Z', current_task_id: '', current_task_role: '', chain_id: '',
    updated_at: '2026-10-21T10:00:00Z', ...extra,
  };
}

// ------------------------------------------------------------------ instances

test('20 instance status events patch the full summary and send zero /agents or /agents/live requests', async () => {
  const net = installRoutes({
    '/agents': { body: { data: [{ agent_id: 'agt_1', name: 'A' }], page: { has_more: false } } },
    '/agents/live': { body: { projects: [{ project_id: 'p1', name: 'P', chains: [{ chain_id: 'c1', live_agents: [{ agent_instance_id: INST, runtime_status: 'running', activity_status: 'idle' }], members: [] }] }] } },
    [`/agent-instances/${INST}`]: { body: { data: { agent_instance_id: INST, agent_id: 'agt_1', ...instanceSummary() } } },
  });
  try {
    const store = await makeStore();
    const { agentsApi } = await import('../src/ui/api/endpoints/agents.ts');
    const { agentsLiveApi } = await import('../src/ui/api/endpoints/agentsLive.ts');
    const { handleUserWsEvent } = await import('../src/ui/api/wsInvalidation.ts');
    await Promise.all([
      store.dispatch(agentsApi.endpoints.listAgentIdentities.initiate(undefined)),
      store.dispatch(agentsApi.endpoints.fetchAgentInstance.initiate({ instanceId: INST })),
      store.dispatch(agentsLiveApi.endpoints.getAgentsLive.initiate(undefined)),
    ]);
    net.hits.length = 0;
    for (let i = 0; i < 20; i++) {
      handleUserWsEvent(store.dispatch, {
        type: 'resource_changed', resource: 'agent_instance', resource_id: INST, change: 'status_changed',
        summary: instanceSummary({ activity_status: i % 2 ? 'busy' : 'idle', updated_at: `2026-10-21T10:00:${String(i + 1).padStart(2, '0')}Z` }),
      });
    }
    // A restart: run_count/started_at move; a late frame (older updated_at) is ignored.
    handleUserWsEvent(store.dispatch, { type: 'resource_changed', resource: 'agent_instance', resource_id: INST, change: 'status_changed', summary: instanceSummary({ run_count: 2, started_at: '2026-10-21T10:01:00Z', updated_at: '2026-10-21T10:01:00Z' }) });
    handleUserWsEvent(store.dispatch, { type: 'resource_changed', resource: 'agent_instance', resource_id: INST, change: 'status_changed', summary: instanceSummary({ runtime_status: 'stopped', updated_at: '2026-10-21T09:59:00Z' }) });
    await settle();
    assert.equal(count(net.hits, (h) => h.startsWith('GET /api/v1/agents')), 0, `no /agents or /agents/live; saw ${net.hits.join(', ')}`);
    assert.equal(net.hits.length, 0, `no request at all; saw ${net.hits.join(', ')}`);
    const instance = agentsApi.endpoints.fetchAgentInstance.select({ instanceId: INST })(store.getState()).data.instance;
    assert.equal(instance.run_count, 2, 'restart detected from run_count');
    assert.equal(instance.started_at, '2026-10-21T10:01:00Z');
    assert.equal(instance.runtime_status, 'running', 'stale frame did not overwrite a newer state');
  } finally { net.restore(); }
});

test('instance going live/stopped or changing current task refetches the live tree once per burst', async () => {
  const net = installRoutes({
    '/agents/live': { body: { projects: [{ project_id: 'p1', name: 'P', chains: [{ chain_id: 'c1', live_agents: [{ agent_instance_id: INST, runtime_status: 'running' }], members: [] }] }] } },
  });
  try {
    const store = await makeStore();
    const { agentsLiveApi } = await import('../src/ui/api/endpoints/agentsLive.ts');
    const { handleUserWsEvent } = await import('../src/ui/api/wsInvalidation.ts');
    const sub = store.dispatch(agentsLiveApi.endpoints.getAgentsLive.initiate(undefined));
    await sub;
    net.hits.length = 0;
    handleUserWsEvent(store.dispatch, { type: 'resource_changed', resource: 'agent_instance', resource_id: INST, change: 'status_changed', summary: instanceSummary({ runtime_status: 'stopped', updated_at: '2026-10-21T11:00:00Z' }) });
    handleUserWsEvent(store.dispatch, { type: 'resource_changed', resource: 'agent_instance', resource_id: INST, change: 'current_task_changed', summary: instanceSummary({ current_task_id: 't1', updated_at: '2026-10-21T11:00:01Z' }) });
    await settle();
    assert.equal(count(net.hits, (h) => h === 'GET /api/v1/agents/live'), 1, `one coalesced live-tree refetch; saw ${net.hits.join(', ')}`);
    sub.unsubscribe();
  } finally { net.restore(); }
});

test('instance failing refetches that one instance so the failure notice has last_error; plain status never clears it', async () => {
  let failed = false;
  const net = installRoutes({
    [`/agent-instances/${INST}`]: () => ({ body: { data: { agent_instance_id: INST, agent_id: 'agt_1', ...instanceSummary(failed
      ? { runtime_status: 'failed', updated_at: '2026-10-21T10:02:00Z', last_error: { code: 'spawn_failed', message: 'provider exited 1' } }
      : {}) } } }),
  });
  try {
    const store = await makeStore();
    const { agentsApi } = await import('../src/ui/api/endpoints/agents.ts');
    const { handleUserWsEvent } = await import('../src/ui/api/wsInvalidation.ts');
    const sub = store.dispatch(agentsApi.endpoints.fetchAgentInstance.initiate({ instanceId: INST }));
    await sub;
    net.hits.length = 0;
    failed = true;
    // The producer summary carries no last_error (resource_events.odin instance_changed_summary_json).
    handleUserWsEvent(store.dispatch, { type: 'resource_changed', resource: 'agent_instance', resource_id: INST, change: 'status_changed', summary: instanceSummary({ runtime_status: 'failed', updated_at: '2026-10-21T10:02:00Z' }) });
    handleUserWsEvent(store.dispatch, { type: 'resource_changed', resource: 'agent_instance', resource_id: INST, change: 'status_changed', summary: instanceSummary({ runtime_status: 'failed', activity_status: 'idle', updated_at: '2026-10-21T10:02:00Z' }) });
    await settle();
    assert.deepEqual(net.hits, [`GET /api/v1/agent-instances/${INST}`], `one targeted instance fetch; saw ${net.hits.join(', ')}`);
    const select = () => agentsApi.endpoints.fetchAgentInstance.select({ instanceId: INST })(store.getState()).data.instance;
    assert.equal(select().runtime_status, 'failed');
    assert.ok(select().last_error, 'failure reason present for AgentFailureNotice');
    // Same-status frames (activity only) neither clear the error nor refetch.
    net.hits.length = 0;
    handleUserWsEvent(store.dispatch, { type: 'resource_changed', resource: 'agent_instance', resource_id: INST, change: 'status_changed', summary: instanceSummary({ runtime_status: 'failed', activity_status: 'busy', updated_at: '2026-10-21T10:03:00Z' }) });
    await settle();
    assert.equal(net.hits.length, 0, `no request; saw ${net.hits.join(', ')}`);
    assert.ok(select().last_error, 'summary does not own last_error, so it is not cleared');
    // Leaving failure (restart) refetches once so the stale error goes away.
    failed = false;
    handleUserWsEvent(store.dispatch, { type: 'resource_changed', resource: 'agent_instance', resource_id: INST, change: 'status_changed', summary: instanceSummary({ runtime_status: 'running', run_count: 2, updated_at: '2026-10-21T10:04:00Z' }) });
    await settle();
    assert.deepEqual(net.hits, [`GET /api/v1/agent-instances/${INST}`]);
    sub.unsubscribe();
  } finally { net.restore(); }
});

// ------------------------------------------------------------------ messages

test('one message from another tab/CLI: one newest-page fetch + one sidebar fetch, no /agents/live, older pages untouched', async () => {
  const net = installRoutes({
    [`/chats/${CONV}/messages`]: (url) => (url.searchParams.get('cursor') ? { body: { data: [userRow('m_old')], page: { has_more: false } } } : messagesRoute([userRow('m1')])),
    '/chats': { body: { data: [{ conversation_id: CONV, agent_instance_id: INST, unread_count: 0 }] } },
    '/agents/live': { body: { projects: [] } },
  });
  try {
    const store = await makeStore();
    const { chatEndpoints } = await import('../src/ui/api/endpoints/chats.ts');
    const { sidebarApi } = await import('../src/ui/api/endpoints/sidebar.ts');
    const { agentsLiveApi } = await import('../src/ui/api/endpoints/agentsLive.ts');
    const { handleUserWsEvent } = await import('../src/ui/api/wsInvalidation.ts');
    const subs = [
      store.dispatch(chatEndpoints.endpoints.fetchConversationMessages.initiate({ conversationId: CONV })),
      store.dispatch(chatEndpoints.endpoints.fetchConversationMessages.initiate({ conversationId: CONV, limit: 30, cursor: 'older1' })),
      store.dispatch(sidebarApi.endpoints.listSidebarConversations.initiate({ limit: 30 })),
      store.dispatch(agentsLiveApi.endpoints.getAgentsLive.initiate(undefined)),
    ];
    await Promise.all(subs);
    net.hits.length = 0;
    // The same logical change delivered twice (dedupe across a burst).
    handleUserWsEvent(store.dispatch, messageCreated('m2'));
    handleUserWsEvent(store.dispatch, messageCreated('m2'));
    await settle();
    assert.equal(count(net.hits, (h) => h.startsWith(`GET /api/v1/chats/${CONV}/messages?limit=30`) && !h.includes('cursor')), 1, `one newest-page fetch; saw ${net.hits.join(', ')}`);
    assert.equal(count(net.hits, (h) => h.includes('cursor=')), 0, 'older pages do not refetch on a new message');
    assert.equal(count(net.hits, (h) => h.startsWith('GET /api/v1/chats?')), 1, 'one sidebar fetch');
    assert.equal(count(net.hits, (h) => h.startsWith('GET /api/v1/agents')), 0, 'message events never reload the live-agent tree');
    for (const s of subs) s.unsubscribe();
  } finally { net.restore(); }
});

test('a message in a conversation outside the loaded sidebar page (31st) refetches the sidebar list', async () => {
  const OUTSIDE = 'chat_31';
  const net = installRoutes({
    [`/chats/${OUTSIDE}/messages`]: messagesRoute([userRow('x1', { conversation_id: OUTSIDE })]),
    '/chats': { body: { data: Array.from({ length: 30 }, (_, i) => ({ conversation_id: `chat_top${i}`, agent_instance_id: `inst_${i}`, unread_count: 0 })) } },
  });
  try {
    const store = await makeStore();
    const { sidebarApi } = await import('../src/ui/api/endpoints/sidebar.ts');
    const { handleUserWsEvent } = await import('../src/ui/api/wsInvalidation.ts');
    const sub = store.dispatch(sidebarApi.endpoints.listSidebarConversations.initiate({ limit: 30 }));
    await sub;
    net.hits.length = 0;
    handleUserWsEvent(store.dispatch, { ...messageCreated('x2'), conversation_id: OUTSIDE });
    await settle();
    assert.equal(count(net.hits, (h) => h.startsWith('GET /api/v1/chats?')), 1, `the sidebar page refetches so the row moves to the top; saw ${net.hits.join(', ')}`);
    // A row already on the page still costs exactly one sidebar fetch.
    net.hits.length = 0;
    handleUserWsEvent(store.dispatch, { ...messageCreated('x3'), conversation_id: 'chat_top5' });
    await settle();
    assert.equal(count(net.hits, (h) => h.startsWith('GET /api/v1/chats?')), 1, `saw ${net.hits.join(', ')}`);
    sub.unsubscribe();
  } finally { net.restore(); }
});

test('reconcileOlderPages carries rows that slide out of the newest page and re-anchors when pages no longer join', async () => {
  const { reconcileOlderPages } = await import('../src/ui/api/conversationMessageEvents.ts');
  const PAGE = 30;
  const row = (n: number) => ({ message_id: `m${String(n).padStart(3, '0')}` });
  const range = (from: number, to: number) => Array.from({ length: to - from }, (_, i) => row(from + i));
  const idOf = (r: any) => String(r.message_id || '');
  // Loaded: older page m000..m029, newest page m030..m059.
  const older = range(0, PAGE);
  const previous = range(PAGE, 2 * PAGE);
  const ids = (rows: any[]) => rows.map(idOf).sort();
  // k = 1: newest page m031..m060; m030 slid out and must be kept.
  const one = reconcileOlderPages(previous, range(PAGE + 1, 2 * PAGE + 1), older, idOf);
  assert.equal(one.reanchor, false);
  assert.deepEqual(ids([...one.older, ...range(PAGE + 1, 2 * PAGE + 1)]), ids(range(0, 2 * PAGE + 1)), 'k=1: contiguous, no hole, no duplicate');
  // k = page - 1: one overlapping row; every slid row carried.
  const most = reconcileOlderPages(previous, range(2 * PAGE - 1, 3 * PAGE - 1), older, idOf);
  assert.equal(most.reanchor, false);
  assert.deepEqual(ids([...most.older, ...range(2 * PAGE - 1, 3 * PAGE - 1)]), ids(range(0, 3 * PAGE - 1)));
  // k = page: no overlap; older pages no longer join -> re-anchor from the new cursor.
  const full = reconcileOlderPages(previous, range(2 * PAGE, 3 * PAGE), older, idOf);
  assert.deepEqual(full, { older: [], reanchor: true });
  // Same page refetched (read receipt, reconnect with nothing new): identity kept.
  const same = reconcileOlderPages(previous, range(PAGE, 2 * PAGE), older, idOf);
  assert.equal(same.older, older);
  // No older pages loaded: nothing to carry; the pane pages from the new cursor.
  assert.deepEqual(reconcileOlderPages(previous, range(PAGE + 1, 2 * PAGE + 1), [], idOf), { older: [], reanchor: false });
  // Repeated refetch does not duplicate rows already carried.
  const again = reconcileOlderPages(range(PAGE + 1, 2 * PAGE + 1), range(PAGE + 2, 2 * PAGE + 2), one.older, idOf);
  assert.equal(new Set(again.older.map(idOf)).size, again.older.length);
});

test('originating tab: send + its WS echo cost one messages fetch, even when the echo beats the POST response', async () => {
  let echo: (() => void) | null = null;
  const net = installRoutes({
    [`GET /chats/${CONV}/messages`]: messagesRoute([userRow('m1')]),
    [`POST /chats/${CONV}/messages`]: async () => {
      // The hub publishes before it answers the POST.
      echo?.();
      await tick(5);
      return { status: 201, body: { data: userRow('m_sent') } };
    },
  });
  try {
    const store = await makeStore();
    const { chatEndpoints } = await import('../src/ui/api/endpoints/chats.ts');
    const { handleUserWsEvent } = await import('../src/ui/api/wsInvalidation.ts');
    const sub = store.dispatch(chatEndpoints.endpoints.fetchConversationMessages.initiate({ conversationId: CONV }));
    await sub;
    net.hits.length = 0;
    echo = () => handleUserWsEvent(store.dispatch, messageCreated('m_sent'));
    await store.dispatch(chatEndpoints.endpoints.sendConversationMessage.initiate({ conversationId: CONV, body: 'hello' }));
    await settle();
    assert.equal(count(net.hits, (h) => h.startsWith(`GET /api/v1/chats/${CONV}/messages`)), 1, `one fetch for send+echo; saw ${net.hits.join(', ')}`);
    sub.unsubscribe();
  } finally { net.restore(); }
});

test('messages_read patches newest and older pages, the sidebar unread count and the pane signal with zero requests', async () => {
  const net = installRoutes({
    [`/chats/${CONV}/messages`]: (url) => (url.searchParams.get('cursor')
      ? { body: { data: [userRow('m_old')], page: { has_more: false } } }
      : messagesRoute([userRow('m1')])),
    '/chats': { body: { data: [{ conversation_id: CONV, agent_instance_id: INST, unread_count: 3 }] } },
  });
  try {
    const store = await makeStore();
    const { chatEndpoints } = await import('../src/ui/api/endpoints/chats.ts');
    const { sidebarApi } = await import('../src/ui/api/endpoints/sidebar.ts');
    const { handleUserWsEvent } = await import('../src/ui/api/wsInvalidation.ts');
    const { CONVERSATION_MESSAGES_READ_EVENT } = await import('../src/ui/api/conversationMessageEvents.ts');
    const subs = [
      store.dispatch(chatEndpoints.endpoints.fetchConversationMessages.initiate({ conversationId: CONV })),
      store.dispatch(chatEndpoints.endpoints.fetchConversationMessages.initiate({ conversationId: CONV, limit: 30, cursor: 'older1' })),
      store.dispatch(sidebarApi.endpoints.listSidebarConversations.initiate({ limit: 30 })),
    ];
    await Promise.all(subs);
    net.hits.length = 0;
    const signals: any[] = [];
    const onRead = (e: any) => signals.push(e.detail);
    window.addEventListener(CONVERSATION_MESSAGES_READ_EVENT, onRead);
    handleUserWsEvent(store.dispatch, {
      type: 'chat_event', event: 'messages_read', conversation_id: CONV, agent_instance_id: INST,
      reader: INST, read_at: '2026-10-21T10:10:00Z', unread_count: 0, message_ids: ['m1', 'm_old'],
    });
    await settle();
    window.removeEventListener(CONVERSATION_MESSAGES_READ_EVENT, onRead);
    assert.equal(net.hits.length, 0, `no request; saw ${net.hits.join(', ')}`);
    const newest = chatEndpoints.endpoints.fetchConversationMessages.select({ conversationId: CONV })(store.getState()).data.messages;
    const older = chatEndpoints.endpoints.fetchConversationMessages.select({ conversationId: CONV, limit: 30, cursor: 'older1' })(store.getState()).data.messages;
    assert.equal(newest[0].read_at, '2026-10-21T10:10:00Z');
    assert.equal(older[0].read_at, '2026-10-21T10:10:00Z', 'loaded older page patched too');
    const rows = sidebarApi.endpoints.listSidebarConversations.select({ limit: 30 })(store.getState()).data;
    assert.equal(rows[0].unreadCount, 0);
    assert.deepEqual(signals.map((s) => s.messageIds), [['m1', 'm_old']], 'pane-held older pages receive the receipt');
    for (const s of subs) s.unsubscribe();
  } finally { net.restore(); }
});

test('applyReadReceipt keeps identity when nothing changes and never moves read_at backwards', async () => {
  const { applyReadReceipt } = await import('../src/ui/api/conversationMessageEvents.ts');
  const rows = [userRow('a', { read_at: '2026-10-21T10:20:00Z' }), userRow('b')];
  const same = applyReadReceipt(rows, { conversationId: CONV, messageIds: ['a'], readAt: '2026-10-21T10:10:00Z' });
  assert.equal(same, rows);
  const next = applyReadReceipt(rows, { conversationId: CONV, messageIds: ['a', 'b'], readAt: '2026-10-21T10:30:00Z' });
  assert.notEqual(next, rows);
  assert.deepEqual(next.map((r: any) => r.read_at), ['2026-10-21T10:30:00Z', '2026-10-21T10:30:00Z']);
});

test('conversation created elsewhere refetches the sidebar once; rename refetches header + sidebar, never messages', async () => {
  const net = installRoutes({
    [`/chats/${CONV}/messages`]: messagesRoute([userRow('m1')]),
    [`/chats/by-instance/${INST}`]: { body: { data: { conversation_id: CONV, agent_instance_id: INST, title: 'T' } } },
    '/chats': { body: { data: [{ conversation_id: CONV, agent_instance_id: INST }] } },
  });
  try {
    const store = await makeStore();
    const { chatEndpoints } = await import('../src/ui/api/endpoints/chats.ts');
    const { sidebarApi } = await import('../src/ui/api/endpoints/sidebar.ts');
    const { handleUserWsEvent } = await import('../src/ui/api/wsInvalidation.ts');
    const subs = [
      store.dispatch(chatEndpoints.endpoints.fetchConversationMessages.initiate({ conversationId: CONV })),
      store.dispatch(chatEndpoints.endpoints.fetchConversation.initiate({ conversationId: '', agentInstanceId: INST })),
      store.dispatch(sidebarApi.endpoints.listSidebarConversations.initiate({ limit: 30 })),
    ];
    await Promise.all(subs);
    net.hits.length = 0;
    handleUserWsEvent(store.dispatch, { type: 'resource_changed', resource: 'conversation', resource_id: 'chat_new', change: 'created', summary: { agent_instance_id: 'inst_new' } });
    await settle();
    assert.deepEqual(net.hits, ['GET /api/v1/chats?limit=30'], 'created: sidebar only');
    net.hits.length = 0;
    handleUserWsEvent(store.dispatch, { type: 'resource_changed', resource: 'conversation', resource_id: CONV, change: 'updated', summary: { title: 'New' } });
    await settle();
    assert.equal(count(net.hits, (h) => h.includes('/messages')), 0, 'rename does not refetch messages');
    assert.equal(count(net.hits, (h) => h.includes(`/chats/by-instance/${INST}`)), 1, 'header refetched once');
    assert.equal(count(net.hits, (h) => h.startsWith('GET /api/v1/chats?')), 1, 'sidebar refetched once');
    for (const s of subs) s.unsubscribe();
  } finally { net.restore(); }
});

// ------------------------------------------------------------------ operations, tasks, workflows, shells

test('reconfiguration progress is event-driven: one GET per phase event, none on instance status', async () => {
  const net = installRoutes({
    [`/agent-instances/${INST}/reconfigurations`]: { body: { data: { operations: [{ operation_id: 'op1', phase: 'stopping', revision: 1 }] } } },
    [`/agent-instances/${INST}`]: { body: { data: { agent_instance_id: INST, ...instanceSummary() } } },
  });
  try {
    const store = await makeStore();
    const { agentsApi } = await import('../src/ui/api/endpoints/agents.ts');
    const { handleUserWsEvent } = await import('../src/ui/api/wsInvalidation.ts');
    const subs = [
      store.dispatch(agentsApi.endpoints.listInstanceReconfigurations.initiate({ instanceId: INST })),
      store.dispatch(agentsApi.endpoints.fetchAgentInstance.initiate({ instanceId: INST })),
    ];
    await Promise.all(subs);
    net.hits.length = 0;
    handleUserWsEvent(store.dispatch, { type: 'resource_changed', resource: 'agent_instance', resource_id: INST, change: 'status_changed', summary: instanceSummary({ updated_at: '2026-10-21T10:30:00Z' }) });
    await settle();
    assert.equal(net.hits.length, 0, `status does not refetch reconfigurations; saw ${net.hits.join(', ')}`);
    handleUserWsEvent(store.dispatch, { type: 'resource_changed', resource: 'agent_instance_reconfiguration', resource_id: INST, change: 'progress', summary: { reconfiguration_id: 'op1', phase: 'launching', revision: 2 } });
    await settle();
    assert.deepEqual(net.hits, [`GET /api/v1/agent-instances/${INST}/reconfigurations`]);
    for (const s of subs) s.unsubscribe();
  } finally { net.restore(); }
});

test('task facet_changed refetches only that (task, attempt, kind) facet; other facets stay cached', async () => {
  const net = installRoutes({
    '/facets/output': { body: { data: { kind: 'output', body: { summary: 'x' } } } },
    '/facets/verify': { body: { data: { kind: 'verify', body: { exit_code: 0 } } } },
  });
  try {
    const store = await makeStore();
    const { tasksApi } = await import('../src/ui/api/endpoints/tasks.ts');
    const { handleUserWsEvent } = await import('../src/ui/api/wsInvalidation.ts');
    const subs = [
      store.dispatch(tasksApi.endpoints.fetchTaskFacet.initiate({ chainId: 'c1', taskId: 't1', attemptNo: 1, kind: 'output' })),
      store.dispatch(tasksApi.endpoints.fetchTaskFacet.initiate({ chainId: 'c1', taskId: 't1', attemptNo: 1, kind: 'verify' })),
    ];
    await Promise.all(subs);
    net.hits.length = 0;
    handleUserWsEvent(store.dispatch, { type: 'resource_changed', resource: 'task', resource_id: 't1', change: 'facet_changed', summary: { task_id: 't1', chain_id: 'c1', attempt_no: 1, kind: 'output' } });
    await settle();
    assert.deepEqual(net.hits, ['GET /api/v1/task-chains/c1/tasks/t1/attempts/1/facets/output']);
    for (const s of subs) s.unsubscribe();
  } finally { net.restore(); }
});

test('workflow stage change refetches the chain workflow runs once', async () => {
  const net = installRoutes({
    '/task-chains/c1/workflow-runs': { body: { data: { runs: [{ run_id: 'wr1', stages: [] }], work_revision: 1 } } },
  });
  try {
    const store = await makeStore();
    const { workflowRunsApi } = await import('../src/ui/api/endpoints/workflowRuns.ts');
    const { handleUserWsEvent } = await import('../src/ui/api/wsInvalidation.ts');
    const sub = store.dispatch(workflowRunsApi.endpoints.fetchChainWorkflowRuns.initiate({ chainId: 'c1' }));
    await sub;
    net.hits.length = 0;
    handleUserWsEvent(store.dispatch, { type: 'resource_changed', resource: 'workflow_run', resource_id: 'wr1', change: 'stage_changed', summary: { workflow_run_id: 'wr1', chain_id: 'c1', stage_key: 's2' } });
    handleUserWsEvent(store.dispatch, { type: 'resource_changed', resource: 'task_chain', resource_id: 'c1', change: 'workflow_started', summary: { task_chain_id: 'c1', chain_id: 'c1', workflow_run_id: 'wr1' } });
    await settle();
    assert.equal(count(net.hits, (h) => h.includes('/workflow-runs')), 1, `one coalesced fetch; saw ${net.hits.join(', ')}`);
    sub.unsubscribe();
  } finally { net.restore(); }
});

test('shell retention prune (empty resource_id, owner-scoped) refreshes the shell lists', async () => {
  const net = installRoutes({ '/shells': { body: { data: { sessions: [] } } } });
  try {
    const store = await makeStore();
    const { handleUserWsEvent, INVALIDATION_COALESCE_MS } = await import('../src/ui/api/wsInvalidation.ts');
    const { shellsApi } = await import('../src/ui/api/endpoints/shells.ts');
    const sub = store.dispatch((shellsApi.endpoints as any).listShells.initiate({}));
    await sub;
    net.hits.length = 0;
    handleUserWsEvent(store.dispatch, { type: 'resource_changed', resource: 'shell_session', resource_id: '', change: 'pruned', summary: { deleted: 3 } });
    // Shell frames ride the burst window (api-fetch-dedup), so wait it out.
    await tick(INVALIDATION_COALESCE_MS + 60);
    assert.equal(count(net.hits, (h) => h.startsWith('GET /api/v1/shells')), 1, `saw ${net.hits.join(', ')}`);
    sub.unsubscribe();
  } finally { net.restore(); }
});

test('bridge provider_status_changed refetches only that bridge provider status, not the bridge list', async () => {
  const net = installRoutes({
    '/bridges': { body: { data: { bridges: [{ bridge_id: 'brg_1', status: 'online' }] } } },
    '/bridges/brg_1/provider-status': { body: { data: { providers: [] } } },
  });
  try {
    const store = await makeStore();
    const { bridgeSupportApi } = await import('../src/ui/api/endpoints/bridgeSupport.ts');
    const { handleUserWsEvent } = await import('../src/ui/api/wsInvalidation.ts');
    const subs = [store.dispatch(bridgeSupportApi.endpoints.listBridges.initiate(undefined))];
    subs.push(store.dispatch(bridgeSupportApi.endpoints.listBridgeProviders.initiate({ bridgeId: 'brg_1' })));
    await Promise.all(subs);
    net.hits.length = 0;
    handleUserWsEvent(store.dispatch, { type: 'resource_changed', resource: 'bridge', resource_id: 'brg_1', change: 'provider_status_changed', summary: { provider: 'claude' } });
    await settle();
    assert.equal(count(net.hits, (h) => h === 'GET /api/v1/bridges'), 0, `bridge list untouched; saw ${net.hits.join(', ')}`);
    assert.deepEqual(net.hits, ['GET /api/v1/bridges/brg_1/provider-status'], 'one selected-bridge provider call');
    for (const s of subs) s.unsubscribe();
  } finally { net.restore(); }
});

// ------------------------------------------------------------------ recovery

test('reconnect resync refetches mounted conversation state and mounted catalogues', async () => {
  const net = installRoutes({
    [`/chats/${CONV}/messages`]: messagesRoute(Array.from({ length: 30 }, (_, i) => userRow(`n${i}`))),
    '/templates': { body: { data: [] } },
  });
  try {
    const store = await makeStore();
    const { chatEndpoints } = await import('../src/ui/api/endpoints/chats.ts');
    const { agentsApi } = await import('../src/ui/api/endpoints/agents.ts');
    const { resyncAfterReconnect } = await import('../src/ui/api/wsInvalidation.ts');
    const subs = [
      store.dispatch(chatEndpoints.endpoints.fetchConversationMessages.initiate({ conversationId: CONV })),
      store.dispatch(agentsApi.endpoints.listAgentTemplates.initiate(undefined)),
    ];
    await Promise.all(subs);
    net.hits.length = 0;
    resyncAfterReconnect(store.dispatch);
    await tick(60);
    assert.equal(count(net.hits, (h) => h.includes(`/chats/${CONV}/messages`)), 1, 'newest page refetched after >page missed messages');
    // A catalogue can change from another tab/device/CLI while disconnected.
    assert.equal(count(net.hits, (h) => h.includes('template')), 1, `mounted catalogue refetched once; saw ${net.hits.join(', ')}`);
    for (const s of subs) s.unsubscribe();
  } finally { net.restore(); }
});

// ------------------------------------------------------------------ retired polls (source guard)
// This checks caller options in source only. The idle before/after figure in the handoff
// (~43 req/min -> 0) is an ESTIMATE from these intervals, not a fake-timer measurement;
// the performance follow-up runs the same scenarios under timers.

test('covered steady polls stay retired in their callers', () => {
  const read = (rel: string) => fs.readFileSync(path.join(REPO_ROOT, rel), 'utf8');
  const appShell = read('src/ui/components/shell/AppShell.tsx');
  assert.match(appShell, /useListSidebarConversationsQuery\(\{ limit: 30 \}\);/);
  assert.match(appShell, /useGetAgentsLiveQuery\(undefined, \{ refetchOnFocus: true \}\)/);
  const pane = read('src/ui/components/workbench/AgentChatPane.tsx');
  const paneQueries = pane.match(/use(FetchConversation|FetchConversationMessages|FetchAgentInstance|GetAgentsLive|ListBridges|FetchTaskChainDetail)Query\([^;]*?\);/gs) || [];
  assert.ok(paneQueries.length >= 6, `found ${paneQueries.length} pane queries`);
  for (const q of paneQueries) assert.doesNotMatch(q, /pollingInterval/, `pane query still polls: ${q.slice(0, 80)}`);
  // The only pane poll left is the active-operation fallback, and it is 0 while idle.
  assert.match(pane, /RECONFIGURATION_ACTIVE_FALLBACK_MS\)\s*\n\s*: 0,/);
  assert.doesNotMatch(read('src/ui/components/taskchain/TaskChainOverview.tsx'), /pollingInterval: 5000/);
  assert.doesNotMatch(read('src/ui/components/auxiliary/AuxDock.tsx'), /pollingInterval/);
  assert.doesNotMatch(read('src/ui/components/auxiliary/useAgentAuxContext.ts'), /pollingInterval/);
});
