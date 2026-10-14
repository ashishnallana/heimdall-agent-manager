// Conversation freshness after instance reconfiguration is driven by RTK Query tag
// invalidation, not by views calling refetch().
//
// WHY THIS FILE EXISTS (task_18de650b59bc111e): opening a conversation sometimes
// crashed the Conversation boundary with "Minified Redux Toolkit error #38" (Cannot
// refetch a query that has not been started yet). AgentChatPane refetched the
// conversation/messages/instance queries from an effect whenever the instance's latest
// reconfiguration was `ready`. When the operations list loaded before the conversation,
// that effect called refetch() on the still-skipped messages query. The manual refetches
// also papered over tags that never matched (instance-keyed conversation lookups,
// stop/restart invalidating by agent id).
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_reconfiguration_refresh_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { makeVaultStore } from './helpers/vaultEndpointHarness.ts';

const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
const agents = await import('../src/ui/api/endpoints/agents.ts');
const chats = await import('../src/ui/api/endpoints/chats.ts');
const { reconfigurationSettled } = agents;

const config = { bridge_id: 'brg_a', bridge_label: '', project_id: '', project_label: '', project_path: '', provider: 'claude', model: 'opus' };
function op(id: string, phase: string, extra: Record<string, unknown> = {}): any {
  return {
    operation_id: id, agent_instance_id: 'inst_a', conversation_id: 'chat_a', idempotency_key: id,
    phase, source: config, destination: config, source_stopped: true, destination_committed: phase === 'ready',
    failure_code: '', failure_message: '', revision: 1, ...extra,
  };
}

function jsonResponse(body: any) {
  return {
    ok: true,
    status: 200,
    headers: { get: (h: string) => (h.toLowerCase() === 'content-type' ? 'application/json' : null) },
    text: async () => JSON.stringify(body),
    json: async () => body,
  } as any;
}

/** Routes requests by path; `delays` holds a response back per path fragment. */
function installRoutedFetch(routes: Record<string, () => any>, delays: Record<string, number> = {}) {
  const hits: string[] = [];
  const previous = (globalThis as any).fetch;
  (globalThis as any).fetch = async (input: any, init: any = {}) => {
    const url = new URL(String(input?.url ?? input), 'http://localhost');
    const method = String(init?.method || 'GET').toUpperCase();
    const key = `${method} ${url.pathname}`;
    hits.push(key);
    const route = Object.keys(routes).find((fragment) => key.includes(fragment));
    const delay = Object.entries(delays).find(([fragment]) => key.includes(fragment))?.[1] || 0;
    if (delay) await new Promise((resolve) => setTimeout(resolve, delay));
    return jsonResponse({ data: route ? routes[route]() : {} });
  };
  return {
    count: (match: string | RegExp) =>
      hits.filter((hit) => (typeof match === 'string' ? hit.includes(match) : match.test(hit))).length,
    restore: () => { (globalThis as any).fetch = previous; },
  };
}

const INSTANCE_GET = /^GET \S*\/agent-instances\/inst_a$/;
const settle = (ms = 30) => new Promise((resolve) => setTimeout(resolve, ms));

test('reconfigurationSettled fires only on a transition observed by the caller', () => {
  assert.equal(reconfigurationSettled(undefined, op('op1', 'ready')), false, 'first observation is history');
  assert.equal(reconfigurationSettled(op('op1', 'launching'), op('op1', 'ready')), true);
  assert.equal(reconfigurationSettled(op('op1', 'ready'), op('op1', 'ready')), false, 'already settled');
  assert.equal(reconfigurationSettled(op('op0', 'ready'), op('op1', 'ready')), true, 'a newer operation settled');
  assert.equal(reconfigurationSettled(op('op1', 'launching'), op('op1', 'failed', { failure_code: 'recovery_stopped' })), true);
  assert.equal(reconfigurationSettled(op('op1', 'launching'), op('op1', 'failed', { failure_code: 'launch_failed' })), false);
  assert.equal(reconfigurationSettled(op('op1', 'prepared'), op('op1', 'launching')), false);
});

test('an instance-keyed conversation lookup is reached by its resolved conversation id', async () => {
  const fetch = installRoutedFetch({ '/chats/by-instance/inst_a': () => ({ conversation_id: 'chat_a', agent_instance_id: 'inst_a' }) });
  const store = await makeVaultStore();
  const sub = store.dispatch(chats.chatEndpoints.endpoints.fetchConversation.initiate({ conversationId: '', agentInstanceId: 'inst_a' }));
  try {
    await settle();
    assert.equal(fetch.count('/chats/by-instance/inst_a'), 1);
    store.dispatch(heimdallApi.util.invalidateTags([{ type: 'ConversationSummaries', id: 'chat_a' }]));
    await settle();
    assert.equal(fetch.count('/chats/by-instance/inst_a'), 2, 'rename/settle invalidation must refetch the header');
  } finally {
    sub.unsubscribe();
    store.dispatch(heimdallApi.util.resetApiState());
    fetch.restore();
  }
});

test('stop and restart refresh the instance they act on', async () => {
  const fetch = installRoutedFetch({ '/agent-instances/inst_a': () => ({ agent_instance_id: 'inst_a' }) });
  const store = await makeVaultStore();
  const sub = store.dispatch(agents.agentsApi.endpoints.fetchAgentInstance.initiate({ instanceId: 'inst_a' }));
  try {
    await settle();
    const before = fetch.count(INSTANCE_GET);
    await store.dispatch(agents.agentsApi.endpoints.stopAgentInstance.initiate({ agentId: 'agt_a', instanceId: 'inst_a' }));
    await settle();
    assert.equal(fetch.count(INSTANCE_GET), before + 1, 'stop must invalidate the instance');
    await store.dispatch(agents.agentsApi.endpoints.restartAgentInstance.initiate({ agentId: 'agt_a', instanceId: 'inst_a' }));
    await settle();
    assert.equal(fetch.count(INSTANCE_GET), before + 2, 'restart must invalidate the instance');
  } finally {
    sub.unsubscribe();
    store.dispatch(heimdallApi.util.resetApiState());
    fetch.restore();
  }
});

test('a reconfiguration settling invalidates instance, header and messages; history does not', async () => {
  let operations = [op('op1', 'ready')];
  const fetch = installRoutedFetch({
    '/reconfigurations': () => ({ operations }),
    '/chats/chat_a/messages': () => ({ messages: [] }),
    '/chats/by-instance/inst_a': () => ({ conversation_id: 'chat_a', agent_instance_id: 'inst_a' }),
    '/agent-instances/inst_a': () => ({ agent_instance_id: 'inst_a' }),
  });
  const store = await makeVaultStore();
  const subs = [
    store.dispatch(chats.chatEndpoints.endpoints.fetchConversation.initiate({ conversationId: '', agentInstanceId: 'inst_a' })),
    store.dispatch(chats.chatEndpoints.endpoints.fetchConversationMessages.initiate({ conversationId: 'chat_a' })),
    store.dispatch(agents.agentsApi.endpoints.fetchAgentInstance.initiate({ instanceId: 'inst_a' })),
    store.dispatch(agents.agentsApi.endpoints.listInstanceReconfigurations.initiate({ instanceId: 'inst_a' })),
  ];
  const counts = () => [
    fetch.count('/chats/by-instance/inst_a'),
    fetch.count('/chats/chat_a/messages'),
    fetch.count(INSTANCE_GET),
  ];
  const refetchOps = async () => {
    await store.dispatch(agents.agentsApi.endpoints.listInstanceReconfigurations.initiate({ instanceId: 'inst_a' }, { forceRefetch: true }));
    await settle();
  };
  try {
    await settle();
    const initial = counts();
    assert.deepEqual(initial, [1, 1, 1], 'first load of an already-ready operation must not refresh anything');

    operations = [op('op2', 'launching')];
    await refetchOps();
    assert.deepEqual(counts(), initial, 'an in-flight operation must not refresh dependents');

    operations = [op('op2', 'ready')];
    await refetchOps();
    assert.deepEqual(counts(), initial.map((n) => n + 1), 'settling must refresh instance, header and messages once');
  } finally {
    for (const sub of subs) sub.unsubscribe();
    store.dispatch(heimdallApi.util.resetApiState());
    fetch.restore();
  }
});

// Mounting the whole AgentChatPane under jsdom drags in unrelated chrome (command
// palette, chain selector) that does not render headless, so the crash is pinned at
// its two halves instead: the RTK behaviour that produced #38, and the pane no longer
// calling refetch() outside a user gesture.
test('refetchIfStarted is a no-op on a skipped query that raw refetch() crashes on (RTK #38)', async () => {
  const { JSDOM } = await import('jsdom');
  const { Provider } = await import('react-redux');
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const { refetchIfStarted } = await import('../src/ui/components/workbench/AgentChatPane.tsx');

  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', { url: 'http://localhost/' });
  const saved = { window: (globalThis as any).window, document: (globalThis as any).document };
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  const fetch = installRoutedFetch({});
  const store = await makeVaultStore();
  const root = createRoot(dom.window.document.getElementById('root')!);
  let query: any = null;
  function Probe() {
    // Same shape as AgentChatPane's messages query before the conversation resolves.
    query = chats.chatEndpoints.useFetchConversationMessagesQuery({ conversationId: '' }, { skip: true });
    return null;
  }
  try {
    await act(async () => {
      root.render(React.createElement(Provider, { store }, React.createElement(Probe)));
    });
    assert.equal(query.isUninitialized, true);
    assert.throws(() => query.refetch(), /#38|not been started/, 'raw refetch on a skipped query is the crash');
    assert.doesNotThrow(() => refetchIfStarted(query));
    assert.equal(fetch.count('/messages'), 0);
  } finally {
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    dom.window.close();
    (globalThis as any).window = saved.window;
    (globalThis as any).document = saved.document;
    fetch.restore();
  }
});

test('AgentChatPane only refetches through the started-query guard', async () => {
  const fs = await import('node:fs');
  const source = fs.readFileSync(new URL('../src/ui/components/workbench/AgentChatPane.tsx', import.meta.url), 'utf8');
  const rawRefetches = source.split('\n').filter((line) => /\.refetch\(\)/.test(line) && !/function refetchIfStarted|query\.refetch\(\)/.test(line));
  assert.deepEqual(rawRefetches, [], 'freshness comes from tag invalidation; user refreshes use refetchIfStarted');
});
