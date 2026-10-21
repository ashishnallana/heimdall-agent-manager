// refresh_trim: request-count regressions for the UI refresh cleanup. Every test
// drives the REAL store, endpoints and components against a stubbed fetch and
// asserts which requests reach the wire: closed UI makes none, provider status is
// fetched only for the bridge that needs it, runtime status for a known agent
// never refetches /agents, hidden panes never mark read, and 401/404 are terminal.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_refresh_request_reduction_test.ts

import { after, test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { makeVaultStore as makeHarnessStore } from './helpers/vaultEndpointHarness.ts';

// RTK keeps unused cache entries alive on timers (keepUnusedDataFor up to 600 s);
// reset every store at the end so the test process exits on its own.
const stores: any[] = [];
async function makeVaultStore() {
  const store = await makeHarnessStore();
  stores.push(store);
  return store;
}
after(async () => {
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  for (const store of stores) store.dispatch(heimdallApi.util.resetApiState());
});

type Reply = { status?: number; body: any } | ((url: URL, init: any) => { status?: number; body: any });
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

/**
 * Route stubbed fetch by path. A key is matched against "METHOD /path" first and then
 * "/path"; the longest matching suffix wins. Unrouted requests answer `{data:{}}`.
 * Returns the ordered request log as "METHOD /path?query".
 */
function installRoutes(routes: Routes): { hits: string[]; restore: () => void } {
  const hits: string[] = [];
  const prev = (globalThis as any).fetch;
  (globalThis as any).fetch = async (input: any, init: any = {}) => {
    const url = new URL(String(input?.url ?? input), 'http://localhost');
    const method = String(init?.method || 'GET').toUpperCase();
    hits.push(`${method} ${url.pathname}${url.search}`);
    const path = url.pathname.replace(/^\/api\/v1/, '');
    const keys = Object.keys(routes)
      .filter((k) => (k.includes(' ') ? k === `${method} ${path}` || (k.startsWith(`${method} `) && path.endsWith(k.slice(method.length + 1))) : path.endsWith(k)))
      .sort((a, b) => b.length - a.length);
    const r = keys.length ? routes[keys[0]] : { body: { data: {} } };
    const out = typeof r === 'function' ? r(url, init) : r;
    return reply(out.status ?? 200, out.body);
  };
  return { hits, restore: () => { (globalThis as any).fetch = prev; } };
}

const tick = (ms = 20) => new Promise((r) => setTimeout(r, ms));
const count = (hits: string[], pred: (h: string) => boolean) => hits.filter(pred).length;

// ------------------------------------------------------------------ store level

test('listAgentIdentities follows has_more so >1 page of agents is never dropped', async () => {
  const pageOf = (n: number, from: number) => Array.from({ length: n }, (_, i) => ({ agent_id: `agt_${from + i}`, name: `A${from + i}` }));
  const net = installRoutes({
    '/agents': (url) => {
      const cursor = url.searchParams.get('cursor');
      if (!cursor) return { body: { data: pageOf(200, 0), page: { has_more: true, next_cursor: 'c1' } } };
      if (cursor === 'c1') return { body: { data: pageOf(60, 200), page: { has_more: true, next_cursor: 'c1' } } };
      return { body: { data: [] } };
    },
  });
  try {
    const store = await makeVaultStore();
    const { agentsApi } = await import('../src/ui/api/endpoints/agents.ts');
    const res = await store.dispatch(agentsApi.endpoints.listAgentIdentities.initiate({ limit: 200 }));
    assert.equal(res.data.agents.length, 260, 'both pages are returned');
    // The repeated cursor 'c1' stops the loop instead of spinning.
    assert.deepEqual(net.hits, ['GET /api/v1/agents?limit=200&view=summary', 'GET /api/v1/agents?limit=200&view=summary&cursor=c1']);
    // void and {limit} share ONE cache entry, so a second caller sends nothing.
    await store.dispatch(agentsApi.endpoints.listAgentIdentities.initiate(undefined));
    assert.equal(net.hits.length, 2);
  } finally { net.restore(); }
});

test('runtime status for a known agent patches caches and never refetches /agents', async () => {
  const net = installRoutes({
    '/agents': { body: { data: [{ agent_id: 'agt_known', name: 'Known' }], page: { has_more: false } } },
    '/agent-instances/inst_known': { body: { data: { agent_instance_id: 'inst_known', agent_id: 'agt_known', runtime_status: 'running' } } },
    '/agent-instances/inst_new': { body: { data: { agent_instance_id: 'inst_new', agent_id: 'agt_elsewhere', runtime_status: 'running' } } },
  });
  try {
    const store = await makeVaultStore();
    const { agentsApi, patchAgentCachesFromWs } = await import('../src/ui/api/endpoints/agents.ts');
    const subs = [
      store.dispatch(agentsApi.endpoints.listAgentIdentities.initiate(undefined)),
      store.dispatch(agentsApi.endpoints.fetchAgentInstance.initiate({ instanceId: 'inst_known' })),
    ];
    await Promise.all(subs);
    net.hits.length = 0;

    for (const status of ['running', 'idle', 'running', 'stopped']) {
      patchAgentCachesFromWs(store.dispatch, { agent_instance_id: 'inst_known', summary: { runtime_status: status } });
    }
    // An instance this tab never fetched: the status summary has no agent_id, so
    // there is nothing to look up and nothing to refetch.
    patchAgentCachesFromWs(store.dispatch, { agent_instance_id: 'inst_unseen', summary: { runtime_status: 'running' } });
    await tick();
    assert.equal(count(net.hits, (h) => h.startsWith('GET /api/v1/agents?')), 0, `no /agents refetch; saw ${net.hits.join(', ')}`);
    const instance = agentsApi.endpoints.fetchAgentInstance.select({ instanceId: 'inst_known' })(store.getState()).data.instance;
    assert.equal(instance.runtime_status, 'stopped', 'patched in place');

    // A cached instance whose agent the catalogue lacks (created in another tab) refetches once.
    subs.push(store.dispatch(agentsApi.endpoints.fetchAgentInstance.initiate({ instanceId: 'inst_new' })));
    await tick();
    net.hits.length = 0;
    patchAgentCachesFromWs(store.dispatch, { agent_instance_id: 'inst_new', summary: { runtime_status: 'running' } });
    await tick();
    assert.equal(count(net.hits, (h) => h.startsWith('GET /api/v1/agents?')), 1);
    subs.forEach((s: any) => s.unsubscribe?.());
  } finally { net.restore(); }
});

test('instance lifecycle mutations do not invalidate the identity catalogue', async () => {
  const net = installRoutes({
    '/agents': { body: { data: [{ agent_id: 'agt_1' }], page: { has_more: false } } },
    'POST /stop': { body: { data: { ok: true } } },
    'POST /restart': { body: { data: { ok: true } } },
  });
  try {
    const store = await makeVaultStore();
    const { agentsApi } = await import('../src/ui/api/endpoints/agents.ts');
    const sub = store.dispatch(agentsApi.endpoints.listAgentIdentities.initiate(undefined));
    await sub;
    net.hits.length = 0;
    await store.dispatch(agentsApi.endpoints.stopAgentInstance.initiate({ agentId: 'agt_1', instanceId: 'inst_1' }));
    await store.dispatch(agentsApi.endpoints.restartAgentInstance.initiate({ agentId: 'agt_1', instanceId: 'inst_1' }));
    await tick();
    assert.equal(count(net.hits, (h) => h.startsWith('GET /api/v1/agents?')), 0, net.hits.join(', '));
    sub.unsubscribe();
  } finally { net.restore(); }
});

test('listBridges is one plain request; provider status is per bridge and only when asked', async () => {
  const net = installRoutes({
    '/bridges': { body: { data: { bridges: [
      { bridge_id: 'b1', status: 'online', capabilities: [{ provider: 'stale', models: ['x'] }] },
      { bridge_id: 'b2', status: 'online' },
      { bridge_id: 'b3', status: 'offline' },
    ] } } },
    '/provider-status': (url) => ({ body: { data: { bridge_id: url.pathname.split('/')[4], providers: [
      { provider: 'claude', enabled: true, state: 'present', catalog_state: 'active', models: [{ model_id: 'm1', state: 'active' }, { model_id: 'old', state: 'archived' }] },
      { provider: 'off', enabled: false, state: 'present', catalog_state: 'active', models: [] },
    ] } } }),
  });
  try {
    const store = await makeVaultStore();
    const { bridgeSupportApi, normalizeBridgeCapabilities } = await import('../src/ui/api/endpoints/bridgeSupport.ts');
    const list = await store.dispatch(bridgeSupportApi.endpoints.listBridges.initiate(undefined));
    assert.deepEqual(net.hits, ['GET /api/v1/bridges'], 'no provider-status fan-out');
    // The hub's unfiltered row capabilities are not offered to capability consumers.
    assert.deepEqual(normalizeBridgeCapabilities(list.data.bridges[0]), []);

    const providers = store.dispatch(bridgeSupportApi.endpoints.listBridgeProviders.initiate({ bridgeId: 'b2' }));
    const res = await providers;
    assert.deepEqual(normalizeBridgeCapabilities(res.data), [{ provider: 'claude', models: ['m1'] }]);
    assert.deepEqual(net.hits.filter((h) => h.includes('provider-status')), ['GET /api/v1/bridges/b2/provider-status']);
    providers.unsubscribe();
  } finally { net.restore(); }
});

test('bridge WS events: update bursts refetch nothing; coming online refetches only that bridge', async () => {
  const net = installRoutes({
    '/bridges': { body: { data: { bridges: [{ bridge_id: 'b1', status: 'offline' }, { bridge_id: 'b2', status: 'online' }] } } },
    '/provider-status': { body: { data: { providers: [] } } },
  });
  try {
    const store = await makeVaultStore();
    const { bridgeSupportApi } = await import('../src/ui/api/endpoints/bridgeSupport.ts');
    const { handleUserWsEvent: handleWsEvent } = await import('../src/ui/api/wsInvalidation.ts');
    const subs = [
      store.dispatch(bridgeSupportApi.endpoints.listBridges.initiate(undefined)),
      store.dispatch(bridgeSupportApi.endpoints.listBridgeProviders.initiate({ bridgeId: 'b1' })),
      store.dispatch(bridgeSupportApi.endpoints.listBridgeProviders.initiate({ bridgeId: 'b2' })),
    ];
    await Promise.all(subs);
    net.hits.length = 0;

    for (let p = 10; p <= 100; p += 10) {
      handleWsEvent(store.dispatch, { type: 'resource_changed', resource: 'bridge', resource_id: 'b2', change: 'update_progress', summary: { update_status: 'running', update_progress: p } }, {} as any);
    }
    await tick();
    assert.deepEqual(net.hits, [], '50% of nothing: progress is patched in place');
    const rows = bridgeSupportApi.endpoints.listBridges.select(undefined)(store.getState()).data.bridges;
    assert.equal(rows.find((b: any) => b.bridge_id === 'b2').update_progress, 100);

    handleWsEvent(store.dispatch, { type: 'resource_changed', resource: 'bridge', resource_id: 'b1', change: 'status_changed', summary: { status: 'online' } }, {} as any);
    await tick();
    assert.equal(count(net.hits, (h) => h === 'GET /api/v1/bridges'), 1);
    assert.deepEqual(net.hits.filter((h) => h.includes('provider-status')), ['GET /api/v1/bridges/b1/provider-status']);
    subs.forEach((s: any) => s.unsubscribe());
  } finally { net.restore(); }
});

test('pane queryFns keep the HTTP status, and 401/403/404 are terminal', async () => {
  const net = installRoutes({
    '/agent-instances/inst_gone': { status: 404, body: { error: { code: 'not_found', message: 'instance not found' } } },
    '/agent-instances/inst_gone/reconfigurations': { status: 404, body: { error: { code: 'not_found', message: 'gone' } } },
    '/chats/conv_x/messages': { status: 401, body: { error: { code: 'unauthenticated', message: 'sign in' } } },
    '/agent-instances/inst_flaky': { status: 503, body: { error: { message: 'busy' } } },
  });
  try {
    const store = await makeVaultStore();
    const { agentsApi } = await import('../src/ui/api/endpoints/agents.ts');
    const { chatEndpoints } = await import('../src/ui/api/endpoints/chats.ts');
    const { isTerminalQueryError, queryErrorStatus } = await import('../src/ui/api/cookieFetch.ts');
    const inst = await store.dispatch(agentsApi.endpoints.fetchAgentInstance.initiate({ instanceId: 'inst_gone' }));
    assert.equal(queryErrorStatus(inst.error), 404);
    assert.equal(inst.error.code, 'not_found');
    assert.ok(isTerminalQueryError(inst.error));
    const ops = await store.dispatch(agentsApi.endpoints.listInstanceReconfigurations.initiate({ instanceId: 'inst_gone' }));
    assert.ok(isTerminalQueryError(ops.error));
    const msgs = await store.dispatch(chatEndpoints.endpoints.fetchConversationMessages.initiate({ conversationId: 'conv_x' }));
    assert.equal(queryErrorStatus(msgs.error), 401);
    assert.ok(isTerminalQueryError(msgs.error));
    const flaky = await store.dispatch(agentsApi.endpoints.fetchAgentInstance.initiate({ instanceId: 'inst_flaky' }));
    assert.equal(isTerminalQueryError(flaky.error), false, 'a 503 keeps polling');
  } finally { net.restore(); }
});

test('review findings come from review_posted events of the current attempt', async () => {
  const { reviewsPostedForAttempt } = await import('../src/ui/components/tasks/taskEvents.ts');
  const events = [
    { kind: 'review_posted', payload: { attempt_no: 1, verdict: 'request_changes', reviewer: 'agt_r', findings: ['old'] } },
    { kind: 'review_posted', payload: { attempt_no: 2, verdict: 'approve', reviewer: 'agt_r', findings: [] } },
    { kind: 'review_posted', payload: { attempt_no: 2, verdict: 'request_changes', reviewer: 'user', findings: [{ message: 'fix X' }], summary: 'one issue' } },
    { kind: 'comment', payload: { attempt_no: 2 } },
  ];
  assert.deepEqual(reviewsPostedForAttempt(events, 2), [
    { reviewer: 'user', verdict: 'request_changes', findings: [{ message: 'fix X' }], summary: 'one issue' },
  ]);
});

test('mark-read requires the selected tab to be on screen', async () => {
  const { paneShouldMarkRead, visiblePollInterval } = await import('../src/ui/components/workbench/paneVisibility.tsx');
  const base = { isActiveTab: true, paneVisible: true, conversationId: 'c', agentInstanceId: 'i', unreadCount: 2 };
  assert.equal(paneShouldMarkRead(base), true);
  assert.equal(paneShouldMarkRead({ ...base, paneVisible: false }), false, 'CSS-hidden / off-screen / background tab');
  assert.equal(paneShouldMarkRead({ ...base, isActiveTab: false }), false, 'inactive tab');
  assert.equal(paneShouldMarkRead({ ...base, unreadCount: 0 }), false);
  assert.equal(visiblePollInterval(false, 8000), 0);
  assert.equal(visiblePollInterval(true, 8000), 8000);
});

// ------------------------------------------------------------------ components under jsdom

async function withDom(routes: Routes, run: (h: { hits: string[]; store: any; render: (el: any) => Promise<void>; dom: any; act: any }) => Promise<void>) {
  const { JSDOM } = await import('jsdom');
  const { Provider } = await import('react-redux');
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', { url: 'http://localhost/', pretendToBeVisual: true });
  const saved: any = {};
  const keys = ['window', 'document', 'HTMLElement', 'Node', 'KeyboardEvent', 'navigator', 'MutationObserver', 'getComputedStyle'];
  for (const k of keys) saved[k] = (globalThis as any)[k];
  Object.assign(globalThis as any, {
    window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement, Node: dom.window.Node,
    KeyboardEvent: dom.window.KeyboardEvent, MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  });
  (dom.window as any).matchMedia = (q: string) => ({ matches: false, media: q, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
  (globalThis as any).requestAnimationFrame = (cb: (t: number) => void) => setTimeout(() => cb(Date.now()), 0);
  (globalThis as any).cancelAnimationFrame = (h: any) => clearTimeout(h);
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  const net = installRoutes(routes);
  const store = await makeVaultStore();
  const root = createRoot(dom.window.document.getElementById('root')!);
  const render = async (el: any) => {
    await act(async () => { root.render(React.createElement(Provider, { store }, el)); });
    await act(async () => { await tick(40); });
  };
  try {
    await run({ hits: net.hits, store, render, dom, act });
  } finally {
    await act(async () => root.unmount());
    net.restore();
    for (const k of keys) {
      try { (globalThis as any)[k] = saved[k]; } catch { /* read-only global (navigator) */ }
    }
    dom.window.close();
  }
}

test('closed task modals and the fleet drawer send no requests; opening fetches', async () => {
  await withDom({
    '/agents': { body: { data: [{ agent_id: 'agt_1', name: 'One' }], page: { has_more: false } } },
    '/workflows/templates': { body: { data: { templates: [] } } },
    '/workflows/definitions': { body: { data: { definitions: [] } } },
  }, async ({ hits, render }) => {
    const { CreateChainModal } = await import('../src/ui/components/taskchain/CreateChainModal.tsx');
    const { ReviewRolesModal } = await import('../src/ui/components/tasks/ReviewRolesModal.tsx');
    const { TaskEditModal } = await import('../src/ui/components/tasks/TaskEditModal.tsx');
    const { FleetManagementDrawer } = await import('../src/ui/components/tasks/FleetManagementDrawer.tsx');
    const task: any = { task_id: 't1', chain_id: 'ch1', state: 'ready', brief: {}, depends_on: [] };
    const tree = (open: boolean) => React.createElement(React.Fragment, null,
      React.createElement(CreateChainModal, { isOpen: open, onClose: () => {} }),
      React.createElement(ReviewRolesModal, { chainId: 'ch1', open: false, onClose: () => {} }),
      React.createElement(TaskEditModal, { chainId: 'ch1', task, field: null, onClose: () => {} }),
      React.createElement(FleetManagementDrawer, { chainId: 'ch1', isOpen: false, onClose: () => {} }),
    );
    await render(tree(false));
    assert.deepEqual(hits, [], `closed UI made requests: ${hits.join(', ')}`);

    await render(tree(true));
    assert.equal(count(hits, (h) => h.startsWith('GET /api/v1/agents?')), 1, hits.join(', '));
    assert.equal(count(hits, (h) => h === 'GET /api/v1/workflows/templates'), 1);
    assert.equal(count(hits, (h) => h === 'GET /api/v1/workflows/definitions'), 1);
    assert.equal(count(hits, (h) => h.includes('/fleets') || h.includes('/review-roles') || h.includes('/bridges')), 0, hits.join(', '));
  });
});

test('runtime picker fetches provider status for the selected bridge only', async () => {
  await withDom({
    '/provider-status': { body: { data: { providers: [{ provider: 'claude', enabled: true, state: 'present', catalog_state: 'active', models: [{ model_id: 'm1', state: 'active' }] }] } } },
  }, async ({ hits, render, dom }) => {
    const { default: RuntimeConfigurationOptions } = await import('../src/ui/components/chat/RuntimeConfigurationOptions.tsx');
    const bridges = ['b1', 'b2', 'b3'].map((id) => ({ bridge_id: id, label: id, status: 'online', runtime_connected: true, reconfiguration_supported: true }));
    await render(React.createElement(RuntimeConfigurationOptions, {
      bridges, selection: { bridgeId: 'b2', provider: '', model: '' }, onChange: () => {}, debugPrefix: 't',
    }));
    // (Provider icons are static assets, not data requests.)
    assert.deepEqual(hits.filter((h) => !h.includes('/icon')), ['GET /api/v1/bridges/b2/provider-status']);
    assert.match(dom.window.document.body.textContent || '', /claude/);
  });
});

// The whole AgentChatPane does not render headless (its command palette loops under
// jsdom; see ui_reconfiguration_refresh_test.ts), so these mount the pane's own hooks
// with the REAL endpoints, store and RTK polling.

test('a pane hidden by layout does not mark read; showing it marks read once', async () => {
  await withDom({
    '/chats/by-instance/inst_1': { body: { data: { conversation_id: 'conv_1', agent_instance_id: 'inst_1', unread_count: 3 } } },
    'POST /chats/conv_1/read': { body: { data: { ok: true } } },
  }, async ({ hits, render }) => {
    const { chatEndpoints } = await import('../src/ui/api/endpoints/chats.ts');
    const { PaneVisibilityProvider, usePaneVisible, usePaneMarkRead } = await import('../src/ui/components/workbench/paneVisibility.tsx');
    function PaneProbe() {
      const paneVisible = usePaneVisible();
      const conv = chatEndpoints.useFetchConversationQuery({ conversationId: '', agentInstanceId: 'inst_1' });
      const [markRead] = chatEndpoints.useMarkConversationReadMutation();
      const c = conv.data?.conversation;
      usePaneMarkRead({
        isActiveTab: true, paneVisible, conversationId: String(c?.conversation_id || ''), agentInstanceId: 'inst_1',
        unreadCount: Number(c?.unread_count || 0), markRead: (id) => void markRead({ conversationId: id }),
      });
      return null;
    }
    // Nested providers AND together: a maximised sibling hides it inside a visible workspace.
    const tree = (tileVisible: boolean) => React.createElement(PaneVisibilityProvider, { visible: true },
      React.createElement(PaneVisibilityProvider, { visible: tileVisible }, React.createElement(PaneProbe)));
    await render(tree(false));
    assert.ok(hits.some((h) => h.startsWith('GET /api/v1/chats/by-instance/inst_1')), 'hidden pane still loads its data');
    assert.equal(count(hits, (h) => h.startsWith('POST')), 0, `hidden pane marked read: ${hits.join(', ')}`);
    await render(tree(true));
    assert.equal(count(hits, (h) => h === 'POST /api/v1/chats/conv_1/read'), 1);
  });
});

test('a background browser tab does not mark read', async () => {
  await withDom({
    '/chats/by-instance/inst_1': { body: { data: { conversation_id: 'conv_1', agent_instance_id: 'inst_1', unread_count: 1 } } },
  }, async ({ hits, render, dom }) => {
    Object.defineProperty(dom.window.document, 'visibilityState', { configurable: true, get: () => 'hidden' });
    const { chatEndpoints } = await import('../src/ui/api/endpoints/chats.ts');
    const { usePaneVisible, usePaneMarkRead } = await import('../src/ui/components/workbench/paneVisibility.tsx');
    function PaneProbe() {
      const conv = chatEndpoints.useFetchConversationQuery({ conversationId: '', agentInstanceId: 'inst_1' });
      const [markRead] = chatEndpoints.useMarkConversationReadMutation();
      usePaneMarkRead({
        isActiveTab: true, paneVisible: usePaneVisible(), conversationId: String(conv.data?.conversation?.conversation_id || ''),
        agentInstanceId: 'inst_1', unreadCount: Number(conv.data?.conversation?.unread_count || 0),
        markRead: (id) => void markRead({ conversationId: id }),
      });
      return null;
    }
    await render(React.createElement(PaneProbe));
    assert.equal(count(hits, (h) => h.startsWith('POST')), 0);
  });
});

async function pollsUnder(status: number): Promise<{ instance: number; reconfig: number }> {
  let result = { instance: 0, reconfig: 0 };
  await withDom({
    '/agent-instances/inst_1': { status, body: { error: { code: 'x', message: `status ${status}` } } },
    '/agent-instances/inst_1/reconfigurations': { body: { data: { operations: [] } } },
  }, async ({ hits, render, act }) => {
    const { agentsApi } = await import('../src/ui/api/endpoints/agents.ts');
    const { usePanePollPolicy } = await import('../src/ui/components/workbench/paneVisibility.tsx');
    function PaneProbe() {
      const policy = usePanePollPolicy(true);
      // AgentChatPane's instance poll and the reconfiguration poll that depends on it,
      // at a test cadence.
      const instance = agentsApi.useFetchAgentInstanceQuery({ instanceId: 'inst_1' }, { pollingInterval: policy.interval('instance', 40) });
      agentsApi.useListInstanceReconfigurationsQuery({ instanceId: 'inst_1' }, {
        pollingInterval: policy.isTerminal('instance') ? 0 : 40,
      });
      policy.useReportErrors({ instance: instance.error });
      return null;
    }
    await render(React.createElement(PaneProbe));
    await act(async () => { await tick(400); });
    result = {
      instance: count(hits, (h) => h === 'GET /api/v1/agent-instances/inst_1'),
      reconfig: count(hits, (h) => h === 'GET /api/v1/agent-instances/inst_1/reconfigurations'),
    };
  });
  return result;
}

test('404 and 401 stop the instance poll and its dependent reconfiguration poll; 503 keeps polling', async () => {
  for (const status of [404, 401]) {
    const n = await pollsUnder(status);
    assert.ok(n.instance <= 2, `${status}: instance polled ${n.instance} times in 400ms`);
    assert.ok(n.reconfig <= 2, `${status}: reconfigurations polled ${n.reconfig} times in 400ms`);
  }
  const transient = await pollsUnder(503);
  assert.ok(transient.instance >= 5, `503 is retried by the poll (saw ${transient.instance})`);
});
