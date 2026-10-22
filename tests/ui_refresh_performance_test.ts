// refresh performance pass: hermetic same-scenario request and byte counts. Every
// scenario drives the REAL store, endpoints and user-WS consumer (handleUserWsEvent)
// against a stubbed fetch that logs each request and the bytes of its response body,
// under node:test fake timers (setTimeout/setInterval/Date), so poll cadences are
// measured, not estimated.
//
// Labelling: the idle, identity-picker and aux PTY/chain-overview scenarios are BYTE AND
// REQUEST BENCHMARKS of the caller poll options / hub row shapes fed in below; they do not
// guard the component sources (the hub view has its own Odin test; components are typechecked).
// The hidden-pane, burst and reconnect scenarios exercise real consumer code paths.
//
// BASELINE vs FINAL are the same scenario with two configurations:
//   - idle: query subscriptions with the caller poll options of main 244bedbf
//     (AppShell, AgentChatPane, AuxDock; provider-status fan-out modelled as one
//     listBridgeProviders per bridge on the listBridges cadence, which main ran inside
//     listBridges) vs the caller options in this tree (no steady polls).
//   - hidden pane: the pane not registered with paneDeferral (integration head
//     behaviour) vs registered hidden (this branch).
// Payload sizes are synthetic fixtures (documented below), not production samples.
//
// Set PERF_RESULTS_OUT=<file> to write the measured numbers as JSON.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_refresh_performance_test.ts

import { after, afterEach, beforeEach, mock, test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { makeVaultStore } from './helpers/vaultEndpointHarness.ts';

if (typeof (globalThis as any).window === 'undefined') (globalThis as any).window = new EventTarget();

const results: Record<string, any> = {};
const stores: any[] = [];

after(async () => {
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const { resetQueuedInvalidations } = await import('../src/ui/api/wsInvalidation.ts');
  const { resetPaneDeferral } = await import('../src/ui/api/paneDeferral.ts');
  resetQueuedInvalidations();
  resetPaneDeferral();
  for (const store of stores) store.dispatch(heimdallApi.util.resetApiState());
  const out = process.env.PERF_RESULTS_OUT;
  if (out) fs.writeFileSync(out, JSON.stringify(results, null, 2) + '\n');
  else console.log(`PERF_RESULTS ${JSON.stringify(results)}`);
});

beforeEach(async () => {
  const { resetQueuedInvalidations } = await import('../src/ui/api/wsInvalidation.ts');
  const { resetLocalMessageEchoes } = await import('../src/ui/api/conversationMessageEvents.ts');
  const { resetPaneDeferral } = await import('../src/ui/api/paneDeferral.ts');
  resetQueuedInvalidations();
  resetLocalMessageEchoes();
  resetPaneDeferral();
});

afterEach(() => mock.timers.reset());

// ------------------------------------------------------------------ fixtures
// Sizes: 30-message newest page with ~600-char bodies; 30-row sidebar; a live tree
// with 6 agents; 3 bridges with provider rows; an instance row.
const CONV = 'chat_1';
const INST = 'inst_1';
const BRIDGES = ['brg_1', 'brg_2', 'brg_3'];
const filler = (n: number) => 'x'.repeat(n);
const messagePage = (prefix = 'm') => ({
  data: Array.from({ length: 30 }, (_, i) => ({ message_id: `${prefix}${i}`, conversation_id: CONV, direction: i % 2 ? 'agent_to_user' : 'user_to_agent', body: filler(600), created_at: `2026-10-21T10:${String(i).padStart(2, '0')}:00Z` })),
  page: { has_more: true, next_cursor: 'older1' },
});
const sidebarRows = { data: Array.from({ length: 30 }, (_, i) => ({ conversation_id: i === 0 ? CONV : `chat_s${i}`, agent_instance_id: `inst_s${i}`, agent_name: 'Agent', title: filler(40), last_message_at: '2026-10-21T10:00:00Z', unread_count: 0 })) };
const liveTree = { projects: [{ project_id: 'p1', name: 'P', chains: [{ chain_id: 'c1', live_agents: Array.from({ length: 6 }, (_, i) => ({ agent_instance_id: `inst_${i}`, runtime_status: 'running', activity_status: 'idle', display_name: `Agent ${i}` })), members: [] }] }] };
const instanceRow = { data: { agent_instance_id: INST, agent_id: 'agt_1', runtime_status: 'running', startup_status: 'ready', activity_status: 'idle', bridge_id: 'brg_1', provider: 'claude', model: 'm1', updated_at: '2026-10-21T10:00:00Z' } };
const conversationRow = { data: { conversation_id: CONV, agent_instance_id: INST, title: 'T', unread_count: 0 } };
const bridgesRows = { data: BRIDGES.map((id) => ({ bridge_id: id, name: id, status: 'online', last_seen_at: '2026-10-21T10:00:00Z' })) };
const providerRows = { data: [{ provider: 'claude', available: true, models: ['m1', 'm2', 'm3'] }, { provider: 'codex', available: true, models: ['c1'] }] };

type Log = { reqs: Array<{ key: string; bytes: number }>; restore: () => void };

function installNet(): Log {
  const reqs: Array<{ key: string; bytes: number }> = [];
  const prev = (globalThis as any).fetch;
  (globalThis as any).fetch = async (input: any, init: any = {}) => {
    const url = new URL(String(input?.url ?? input), 'http://localhost');
    const method = String(init?.method || 'GET').toUpperCase();
    const p = url.pathname.replace(/^\/api\/v1/, '');
    let body: any = { data: {} };
    if (/^\/chats\/[^/]+\/messages$/.test(p)) body = messagePage();
    else if (p === '/chats') body = sidebarRows;
    else if (p === '/agents/live') body = liveTree;
    else if (/^\/agent-instances\/[^/]+\/reconfigurations$/.test(p)) body = { data: [] };
    else if (/^\/agent-instances\/[^/]+$/.test(p)) body = instanceRow;
    else if (/^\/chats\/[^/]+$/.test(p) || /^\/chats\/by-instance\//.test(p) || url.searchParams.get('agent_instance_id')) body = conversationRow;
    else if (p === '/bridges') body = bridgesRows;
    else if (/^\/bridges\/[^/]+\/providers/.test(p)) body = providerRows;
    const text = JSON.stringify(body);
    reqs.push({ key: `${method} ${route(p)}`, bytes: Buffer.byteLength(text) });
    return {
      ok: true, status: 200,
      headers: { get: (h: string) => (h.toLowerCase() === 'content-type' ? 'application/json' : null) },
      text: async () => text, json: async () => JSON.parse(text),
    } as any;
  };
  return { reqs, restore: () => { (globalThis as any).fetch = prev; } };
}

// Collapse ids so counts group by route.
function route(p: string): string {
  return p.replace(/\/(chat|inst|brg|agt)_[A-Za-z0-9_]+/g, '/:id');
}

function summarize(reqs: Array<{ key: string; bytes: number }>) {
  const byRoute: Record<string, { requests: number; bytes: number }> = {};
  for (const r of reqs) {
    const e = (byRoute[r.key] ||= { requests: 0, bytes: 0 });
    e.requests += 1;
    e.bytes += r.bytes;
  }
  return { requests: reqs.length, bytes: reqs.reduce((n, r) => n + r.bytes, 0), byRoute };
}

const flush = async () => { for (let i = 0; i < 5; i++) await new Promise((r) => setImmediate(r)); };

async function advance(ms: number, step = 500) {
  for (let t = 0; t < ms; t += step) {
    mock.timers.tick(step);
    await flush();
  }
}

async function makeStore() {
  const store = await makeVaultStore();
  stores.push(store);
  return store;
}

async function api() {
  const { chatEndpoints } = await import('../src/ui/api/endpoints/chats.ts');
  const { agentsApi } = await import('../src/ui/api/endpoints/agents.ts');
  const { agentsLiveApi } = await import('../src/ui/api/endpoints/agentsLive.ts');
  const { sidebarApi } = await import('../src/ui/api/endpoints/sidebar.ts');
  const { bridgeSupportApi } = await import('../src/ui/api/endpoints/bridgeSupport.ts');
  const ws = await import('../src/ui/api/wsInvalidation.ts');
  const deferral = await import('../src/ui/api/paneDeferral.ts');
  return { chatEndpoints, agentsApi, agentsLiveApi, sidebarApi, bridgeSupportApi, ws, deferral };
}

// One visible conversation pane plus the app shell sidebar, with each query's caller
// poll interval (0 = no steady poll). Returns the subscriptions so tests unsubscribe.
type Cadence = { sidebar: number; live: number; auxLive: number; paneConversation: number; paneMessages: number; paneInstance: number; paneLive: number; paneBridges: number; reconfigurations: number };

const MAIN_CADENCE: Cadence = {
  sidebar: 10000, live: 10000, auxLive: 30000, // AppShell.tsx:1514/1518, AuxDock.tsx:47
  paneConversation: 10000, paneMessages: 10000, paneInstance: 8000, // AgentChatPane.tsx:673/681/741
  paneLive: 30000, paneBridges: 30000, reconfigurations: 8000, // AgentChatPane.tsx:747/814/1105 (idle values)
};
// This tree: steady polls retired (refresh_integrate); reconfigurations poll only while an
// accepted operation is unsettled and provider-status only while the picker is open.
const FINAL_CADENCE: Cadence = { sidebar: 0, live: 0, auxLive: 0, paneConversation: 0, paneMessages: 0, paneInstance: 0, paneLive: 0, paneBridges: 0, reconfigurations: 0 };

async function mountShellAndPane(store: any, c: Cadence, opts: { providerFanout: boolean }) {
  const a = await api();
  const sub = (thunk: any) => store.dispatch(thunk);
  const poll = (ms: number) => ({ subscriptionOptions: { pollingInterval: ms, skipPollingIfUnfocused: true } });
  const subs = [
    sub(a.sidebarApi.endpoints.listSidebarConversations.initiate({ limit: 30 }, poll(c.sidebar))),
    sub(a.agentsLiveApi.endpoints.getAgentsLive.initiate(undefined, poll(Math.min(...[c.live, c.auxLive, c.paneLive].filter(Boolean), Infinity) === Infinity ? 0 : Math.min(...[c.live, c.auxLive, c.paneLive].filter(Boolean))))),
    sub(a.chatEndpoints.endpoints.fetchConversation.initiate({ conversationId: '', agentInstanceId: INST }, poll(c.paneConversation))),
    sub(a.chatEndpoints.endpoints.fetchConversationMessages.initiate({ conversationId: CONV }, poll(c.paneMessages))),
    sub(a.agentsApi.endpoints.fetchAgentInstance.initiate({ instanceId: INST }, poll(c.paneInstance))),
    sub(a.agentsApi.endpoints.listInstanceReconfigurations.initiate({ instanceId: INST }, poll(c.reconfigurations))),
    sub(a.bridgeSupportApi.endpoints.listBridges.initiate(undefined, poll(c.paneBridges))),
  ];
  if (opts.providerFanout) {
    for (const bridgeId of BRIDGES) subs.push(sub(a.bridgeSupportApi.endpoints.listBridgeProviders.initiate({ bridgeId }, poll(c.paneBridges))));
  }
  await flush();
  return subs;
}

// ------------------------------------------------------------------ scenarios

test('idle 60s: one open pane + sidebar, main caller cadences vs this tree', async () => {
  mock.timers.enable({ apis: ['setTimeout', 'setInterval', 'Date'], now: Date.parse('2026-10-21T10:00:00Z') });
  const measure = async (c: Cadence, fanout: boolean) => {
    const net = installNet();
    try {
      const store = await makeStore();
      const subs = await mountShellAndPane(store, c, { providerFanout: fanout });
      net.reqs.length = 0; // count steady state, not the initial mount
      await advance(60_000);
      const out = summarize(net.reqs);
      for (const s of subs) s.unsubscribe();
      return out;
    } finally { net.restore(); }
  };
  const baseline = await measure(MAIN_CADENCE, true);
  const final = await measure(FINAL_CADENCE, false);
  results.idle_60s = { baseline, final };
  assert.ok(baseline.requests >= 40, `main cadences poll steadily; saw ${baseline.requests}`);
  assert.equal(final.requests, 0, `no steady requests in this tree; saw ${JSON.stringify(final.byRoute)}`);
});

async function hiddenPaneRun(register: boolean) {
  mock.timers.reset();
  mock.timers.enable({ apis: ['setTimeout', 'setInterval', 'Date'], now: Date.parse('2026-10-21T10:00:00Z') });
  const net = installNet();
  try {
    const store = await makeStore();
    const a = await api();
    const subs = await mountShellAndPane(store, FINAL_CADENCE, { providerFanout: false });
    const pane = register ? a.deferral.registerPane(CONV, false) : 0;
    net.reqs.length = 0;
    // 10 agent replies, 2s apart (each outside the 150ms coalesce window).
    for (let i = 0; i < 10; i++) {
      a.ws.handleUserWsEvent(store.dispatch, {
        type: 'chat_event', event: 'message_created', conversation_id: CONV, agent_instance_id: INST,
        message_id: `msg_${i}`, direction: 'agent_to_user', message_type: 'text', created_at: '2026-10-21T10:05:00Z',
        last_message_at: '2026-10-21T10:05:00Z', unread_count: i + 1, fetch_required: true, fetch_kind: 'chat_message', fetch_id: `msg_${i}`,
      });
      await advance(2000);
    }
    const whileHidden = summarize(net.reqs);
    // Pane shown again: the hook (usePaneDeferredRefresh) does exactly this.
    if (register) {
      // The pane's view of its newest-page request, as useQuery reports it.
      const request = () => {
        const q = a.chatEndpoints.endpoints.fetchConversationMessages.select({ conversationId: CONV })(store.getState());
        return { requestId: q.requestId, isFetching: q.status === 'pending' };
      };
      a.deferral.updatePane(pane, CONV, true);
      if (a.deferral.needsCatchUp(CONV, request(), true)) subs[3].refetch();
      await advance(10);
      // The catch-up response spends the mark; a second hide/show does not refetch again.
      a.deferral.updatePane(pane, CONV, false);
      a.deferral.updatePane(pane, CONV, true);
      assert.equal(a.deferral.needsCatchUp(CONV, request(), true), false);
      assert.equal(a.deferral.isDirty(CONV), false);
    }
    await advance(1000);
    const total = summarize(net.reqs);
    for (const s of subs) s.unsubscribe();
    return { whileHidden, total };
  } finally { net.restore(); }
}

test('hidden pane: 10 message events refetch messages 10x before, 0x hidden + 1x on show after', async () => {
  const baseline = await hiddenPaneRun(false);
  const final = await hiddenPaneRun(true);
  results.hidden_pane_10_messages = { baseline: baseline.total, final: final.total, final_while_hidden: final.whileHidden };
  const msgs = (s: any) => s.byRoute['GET /chats/:id/messages']?.requests || 0;
  const side = (s: any) => s.byRoute['GET /chats']?.requests || 0;
  assert.equal(msgs(baseline.total), 10, JSON.stringify(baseline.total.byRoute));
  assert.equal(msgs(final.whileHidden), 0, 'no messages fetch while every pane is hidden');
  assert.equal(msgs(final.total), 1, 'exactly one deferred refetch on show');
  // Unread correctness: the sidebar rows still refresh on every event while hidden.
  assert.equal(side(final.whileHidden), side(baseline.whileHidden));
  assert.ok(side(final.whileHidden) > 0);
  assert.ok(final.total.bytes < baseline.total.bytes);
});

test('a visible pane is never deferred, and a second visible pane keeps refreshing', async () => {
  mock.timers.enable({ apis: ['setTimeout', 'setInterval', 'Date'], now: Date.parse('2026-10-21T10:00:00Z') });
  const net = installNet();
  try {
    const store = await makeStore();
    const a = await api();
    const subs = await mountShellAndPane(store, FINAL_CADENCE, { providerFanout: false });
    a.deferral.registerPane(CONV, false);
    a.deferral.registerPane(CONV, true); // same conversation open in a visible tile
    net.reqs.length = 0;
    a.ws.handleUserWsEvent(store.dispatch, {
      type: 'chat_event', event: 'message_created', conversation_id: CONV, agent_instance_id: INST, message_id: 'msg_v',
      direction: 'agent_to_user', message_type: 'text', created_at: '2026-10-21T10:05:00Z', last_message_at: '2026-10-21T10:05:00Z',
      unread_count: 1, fetch_required: true, fetch_kind: 'chat_message', fetch_id: 'msg_v',
    });
    await advance(1000);
    assert.equal(summarize(net.reqs).byRoute['GET /chats/:id/messages']?.requests, 1);
    assert.equal(a.deferral.isDirty(CONV), false);
    for (const s of subs) s.unsubscribe();
  } finally { net.restore(); }
});

test('a dirty mark survives unmount and conversation switches until a pane shows it', async () => {
  const { registerPane, updatePane, deferIfHidden, unregisterPane, isDirty, needsCatchUp } = await import('../src/ui/api/paneDeferral.ts');
  const id = registerPane(CONV, false);
  assert.equal(deferIfHidden({ type: 'Chat', id: CONV }), true);
  assert.equal(deferIfHidden({ type: 'SidebarConversations', id: CONV }), false, 'only Chat:<conversation> defers');
  assert.equal(deferIfHidden({ type: 'Chat', id: 'chat_other' }), false, 'no pane registered: not deferred');
  assert.equal(deferIfHidden({ type: 'Chat', id: `${CONV}@older1` }), false, 'older pages are never deferred');
  // The pane switches to another conversation, then unmounts: the cached page of CONV
  // is still stale, so the mark stays.
  updatePane(id, 'chat_other', false);
  unregisterPane(id);
  assert.equal(isDirty(CONV), true);
  // A later pane showing CONV refetches until a newer request settles; a hidden pane
  // or one with a request in flight does not.
  const again = registerPane(CONV, true);
  assert.equal(needsCatchUp(CONV, { requestId: 'r_old', isFetching: false }, false), false, 'hidden: wait');
  assert.equal(needsCatchUp(CONV, { requestId: 'r_old', isFetching: true }, true), false, 'in flight: wait');
  assert.equal(needsCatchUp(CONV, { requestId: 'r_old', isFetching: false }, true), true, 'stale page: refetch');
  assert.equal(needsCatchUp(CONV, { requestId: 'r_old', isFetching: false }, true), true, 'still stale until a newer request');
  assert.equal(needsCatchUp(CONV, { requestId: 'r_new', isFetching: true }, true), false);
  assert.equal(needsCatchUp(CONV, { requestId: 'r_new', isFetching: false }, true), false, 'newer request settled: spent');
  assert.equal(isDirty(CONV), false);
  unregisterPane(again);
});

test('event burst: 20 frames for one conversation inside the window cost one fetch per mounted key', async () => {
  mock.timers.enable({ apis: ['setTimeout', 'setInterval', 'Date'], now: Date.parse('2026-10-21T10:00:00Z') });
  const net = installNet();
  try {
    const store = await makeStore();
    const a = await api();
    const subs = await mountShellAndPane(store, FINAL_CADENCE, { providerFanout: false });
    net.reqs.length = 0;
    for (let i = 0; i < 20; i++) {
      a.ws.handleUserWsEvent(store.dispatch, {
        type: 'chat_event', event: 'message_created', conversation_id: CONV, agent_instance_id: INST, message_id: `b${i}`,
        direction: 'agent_to_user', message_type: 'progress', created_at: '2026-10-21T10:05:00Z', last_message_at: '2026-10-21T10:05:00Z',
        unread_count: i + 1, fetch_required: true, fetch_kind: 'chat_message', fetch_id: `b${i}`,
      });
    }
    await advance(1000, 50);
    const s = summarize(net.reqs);
    results.burst_20_frames_one_conversation = s;
    assert.equal(s.byRoute['GET /chats/:id/messages']?.requests, 1, JSON.stringify(s.byRoute));
    assert.equal(s.byRoute['GET /chats']?.requests, 1);
    assert.equal(s.requests, 2);
    for (const sub of subs) sub.unsubscribe();
  } finally { net.restore(); }
});

test('reconnect: one resync refetches each mounted query once', async () => {
  mock.timers.enable({ apis: ['setTimeout', 'setInterval', 'Date'], now: Date.parse('2026-10-21T10:00:00Z') });
  const net = installNet();
  try {
    const store = await makeStore();
    const a = await api();
    const subs = await mountShellAndPane(store, FINAL_CADENCE, { providerFanout: false });
    net.reqs.length = 0;
    a.ws.resyncAfterReconnect(store.dispatch);
    await advance(1000);
    const s = summarize(net.reqs);
    results.reconnect_resync = s;
    for (const [k, v] of Object.entries(s.byRoute)) assert.equal(v.requests, 1, `${k} once`);
    assert.equal(s.requests, subs.length);
    for (const sub of subs) sub.unsubscribe();
  } finally { net.restore(); }
});

test('identity picker: 260 agents with 8 KB instructions, full rows vs view=summary', async () => {
  // Rows shaped like agent_handlers.odin write_agent_json / write_agent_summary_json.
  const full = (i: number) => ({ agent_id: `agt_${i}`, name: `Agent ${i}`, slug: `agent-${i}`, template_id: 'tpl_1', instructions: filler(8192), state: 'active', supported_bridge_count: 2, active_instance_count: 1, updated_at: '2026-10-21T10:00:00Z' });
  const summaryRow = (i: number) => ({ agent_id: `agt_${i}`, name: `Agent ${i}`, slug: `agent-${i}`, template_id: 'tpl_1', state: 'active', updated_at: '2026-10-21T10:00:00Z' });
  const run = async (hubHonoursView: boolean) => {
    const reqs: Array<{ key: string; bytes: number }> = [];
    const prev = (globalThis as any).fetch;
    (globalThis as any).fetch = async (input: any) => {
      const url = new URL(String(input?.url ?? input), 'http://localhost');
      const cursor = url.searchParams.get('cursor');
      const from = cursor ? 200 : 0;
      const n = cursor ? 60 : 200;
      const summary = hubHonoursView && url.searchParams.get('view') === 'summary';
      const body = { data: Array.from({ length: n }, (_, i) => (summary ? summaryRow : full)(from + i)), page: { has_more: !cursor, next_cursor: cursor ? '' : 'c1' } };
      const text = JSON.stringify(body);
      reqs.push({ key: `GET ${url.pathname}`, bytes: Buffer.byteLength(text) });
      return { ok: true, status: 200, headers: { get: () => 'application/json' }, text: async () => text, json: async () => JSON.parse(text) } as any;
    };
    try {
      const store = await makeStore();
      const { agentsApi } = await import('../src/ui/api/endpoints/agents.ts');
      const res = await store.dispatch(agentsApi.endpoints.listAgentIdentities.initiate({ limit: 200 }));
      assert.equal(res.data.agents.length, 260, 'every identity across both pages');
      assert.ok(res.data.agents.every((a: any) => a.agent_id && a.name && a.state), 'picker fields present');
      return summarize(reqs);
    } finally { (globalThis as any).fetch = prev; }
  };
  const baseline = await run(false); // hub before this change ignores view=summary
  const final = await run(true);
  results.identity_picker_260_agents = { baseline, final };
  assert.equal(baseline.requests, 2);
  assert.equal(final.requests, 2, 'same page count: paging unchanged');
  assert.ok(final.bytes * 20 < baseline.bytes, `summary ${final.bytes} vs full ${baseline.bytes}`);
});

test('aux PTY tab + chain overview open 60s: integration-head cadences vs this branch', async () => {
  mock.timers.enable({ apis: ['setTimeout', 'setInterval', 'Date'], now: Date.parse('2026-10-21T10:00:00Z') });
  const { agentsApi } = await import('../src/ui/api/endpoints/agents.ts');
  const { projectVcsApi } = await import('../src/ui/api/endpoints/projectVcs.ts');
  const { visiblePollInterval } = await import('../src/ui/components/workbench/paneVisibility.tsx');
  // Integration head: AgentPtyWorkbenchPane instance poll 10s; ChainOverviewPanel VCS
  // status (like artifacts/VCS files) 30s regardless of visibility. This branch: no PTY
  // instance poll (events patch it); chain overview polls 30s only while on screen.
  const measure = async (ptyPoll: number, overviewPoll: number) => {
    const net = installNet();
    try {
      const store = await makeStore();
      const poll = (ms: number) => ({ subscriptionOptions: { pollingInterval: ms } });
      const subs = [
        store.dispatch(agentsApi.endpoints.fetchAgentInstance.initiate({ instanceId: 'inst_pty' }, poll(ptyPoll))),
        store.dispatch(projectVcsApi.endpoints.getProjectVcsStatus.initiate('proj_1', poll(overviewPoll))),
      ];
      await flush();
      net.reqs.length = 0;
      await advance(60_000);
      for (const s of subs) s.unsubscribe();
      return summarize(net.reqs);
    } finally { net.restore(); }
  };
  const baseline = await measure(10_000, 30_000);
  const final = await measure(0, visiblePollInterval(false, 30_000));
  const shown = await measure(0, visiblePollInterval(true, 30_000));
  results.aux_pty_and_hidden_chain_overview_60s_shown = shown;
  assert.ok(shown.requests >= 1, `visible chain overview keeps its 30s VCS fallback; ${JSON.stringify(shown.byRoute)}`);
  results.aux_pty_and_hidden_chain_overview_60s = { baseline, final };
  assert.ok(baseline.requests >= 7, JSON.stringify(baseline.byRoute));
  assert.equal(final.requests, 0);
});
