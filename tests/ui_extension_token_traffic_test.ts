// T14: token-usage reporting adds no needless hub calls from the UI.
//   - chainTokenUsageRefresh: chain usage refreshes only while the chain's card is
//     viewed, at most once per window (leading + one trailing), and a chain whose
//     events were dropped while hidden refreshes once when shown again.
//   - wsInvalidation: an agent_instance token event patches the cached instance
//     and instance list from its summary (no GET /agent-instances*), and a burst
//     of token events on a viewed chain costs one token-usage GET, not one each.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_extension_token_traffic_test.ts

import { test, mock } from 'node:test';
import assert from 'node:assert/strict';
import { makeVaultStore } from './helpers/vaultEndpointHarness.ts';

const refresh = await import('../src/ui/api/chainTokenUsageRefresh.ts');

test('chain token refresh: viewed only, leading + one trailing per window, stale on show', () => {
  mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 1_000_000 });
  try {
    refresh.resetChainTokenUsageRefresh();
    const calls: string[] = [];
    const invalidate = (id: string) => calls.push(id);
    const W = refresh.CHAIN_TOKEN_USAGE_REFRESH_MS;

    // Not viewed: nothing is fetched, the chain is only marked stale.
    for (let i = 0; i < 5; i++) refresh.requestChainTokenUsageRefresh('chain_hidden', invalidate);
    mock.timers.tick(W * 3);
    assert.deepEqual(calls, []);
    const shown = refresh.retainChainTokenUsageView('chain_hidden');
    assert.equal(shown.stale, true, 'dropped events make the chain stale for its next view');
    shown.release();
    assert.equal(refresh.retainChainTokenUsageView('chain_hidden').stale, false, 'stale is consumed once');

    // Viewed: a burst of 20 events -> one at once, one trailing at the window end.
    const view = refresh.retainChainTokenUsageView('chain_a');
    assert.equal(view.stale, false);
    for (let i = 0; i < 20; i++) {
      refresh.requestChainTokenUsageRefresh('chain_a', invalidate);
      mock.timers.tick(200);
    }
    assert.deepEqual(calls, ['chain_a'], 'leading refresh only inside the window');
    mock.timers.tick(W);
    assert.deepEqual(calls, ['chain_a', 'chain_a'], 'one trailing refresh folds the rest');
    mock.timers.tick(W * 4);
    assert.equal(calls.length, 2, 'no refresh without events');

    // An event after a quiet window refreshes at once again.
    refresh.requestChainTokenUsageRefresh('chain_a', invalidate);
    assert.equal(calls.length, 3);

    // Unmount with a trailing refresh pending: it is dropped and the chain is stale.
    refresh.requestChainTokenUsageRefresh('chain_a', invalidate);
    view.release();
    mock.timers.tick(W * 2);
    assert.equal(calls.length, 3, 'no refresh for a chain nobody views');
    assert.equal(refresh.retainChainTokenUsageView('chain_a').stale, true);
  } finally {
    refresh.resetChainTokenUsageRefresh();
    mock.timers.reset();
  }
});

const SNAP_1 = { tool_calls: 2, est_tokens_total: 40, context_tokens: 90000, context_window: 200000, window_source: 'config', context_pct: 45, compactions: 0, updated_at_ms: 9 };
const SNAP_2 = { ...SNAP_1, tool_calls: 3, context_tokens: 100000, context_pct: 50, updated_at_ms: 19 };

function tokenEvent(change: string, usage: any, at: string, extra: Record<string, unknown> = {}) {
  return {
    type: 'resource_changed', resource: 'agent_instance', resource_id: 'inst_1', change,
    summary: {
      runtime_status: 'running', activity_status: 'busy', chain_id: 'chain_1', updated_at: '2026-11-02T10:00:00Z',
      token_usage: usage, token_usage_updated_at: at,
      token_totals: { total_context_tokens: 1000, total_est_tool_tokens: 10, total_output_tokens: 5, runs_counted: 1, last_run_counted: 1 },
      ...extra,
    },
  };
}

test('token events patch instance caches and coalesce the chain usage refetch', async () => {
  refresh.resetChainTokenUsageRefresh();
  const hits: string[] = [];
  const prevFetch = (globalThis as any).fetch;
  (globalThis as any).fetch = async (input: any) => {
    const url = new URL(String(input?.url ?? input), 'http://localhost');
    hits.push(url.pathname);
    let body: any = { data: {} };
    if (url.pathname.endsWith('/agent-instances/inst_1')) body = { data: { agent_instance_id: 'inst_1', runtime_status: 'running', chain_id: 'chain_1', updated_at: '2026-11-02T10:00:00Z' } };
    else if (url.pathname.endsWith('/agent-instances')) body = { data: [{ agent_instance_id: 'inst_1', runtime_status: 'running', updated_at: '2026-11-02T10:00:00Z' }] };
    else if (url.pathname.endsWith('/token-usage')) body = { data: { chain_id: 'chain_1', has_data: true, agents: [] } };
    return { ok: true, status: 200, headers: { get: () => 'application/json' }, text: async () => JSON.stringify(body), json: async () => body } as any;
  };
  try {
    const store = await makeVaultStore();
    const { agentsApi } = await import('../src/ui/api/endpoints/agents.ts');
    const { taskChainsApi } = await import('../src/ui/api/endpoints/taskChains.ts');
    const { handleUserWsEvent, flushQueuedInvalidations, resetQueuedInvalidations } = await import('../src/ui/api/wsInvalidation.ts');
    resetQueuedInvalidations();
    const subs = [
      store.dispatch(agentsApi.endpoints.fetchAgentInstance.initiate({ instanceId: 'inst_1' })),
      store.dispatch(agentsApi.endpoints.listAgentInstances.initiate({ limit: 200 })),
      store.dispatch(taskChainsApi.endpoints.getTaskChainTokenUsage.initiate({ chainId: 'chain_1' })),
    ];
    await Promise.all(subs);
    const view = refresh.retainChainTokenUsageView('chain_1');
    hits.length = 0;

    const settle = async () => { flushQueuedInvalidations(); await new Promise((r) => setTimeout(r, 30)); };
    handleUserWsEvent(store.dispatch, tokenEvent('token_usage_changed', SNAP_1, '2026-11-02T10:00:01Z'));
    await settle();
    const instance = () => agentsApi.endpoints.fetchAgentInstance.select({ instanceId: 'inst_1' })(store.getState()).data?.instance;
    const listRow = () => agentsApi.endpoints.listAgentInstances.select({ limit: 200 })(store.getState()).data?.instances?.[0];
    assert.equal(instance().token_usage.context_tokens, 90000, 'instance patched from the event');
    assert.equal(instance().token_totals.runs_counted, 1);
    assert.equal(listRow().token_usage.context_pct, 45, 'list row patched from the event');
    assert.deepEqual(hits.filter((p) => p.includes('/agent-instances')), [], 'no instance or list refetch');
    assert.equal(hits.filter((p) => p.endsWith('/token-usage')).length, 1, 'first change refreshes the viewed chain');

    // A burst inside the window (incl. a coalesced status_changed carrying tokens):
    // patched each time, but no further chain usage GET yet.
    for (let i = 0; i < 5; i++) {
      handleUserWsEvent(store.dispatch, tokenEvent(i % 2 ? 'status_changed' : 'token_usage_changed', SNAP_2, `2026-11-02T10:00:0${2 + i}Z`, i % 2 ? { token_changed: true } : {}));
    }
    await settle();
    assert.equal(instance().token_usage.context_tokens, 100000);
    assert.equal(hits.filter((p) => p.endsWith('/token-usage')).length, 1, 'burst folded into the trailing refresh');
    assert.deepEqual(hits.filter((p) => p.includes('/agent-instances')), []);

    // An older snapshot does not overwrite a newer one.
    handleUserWsEvent(store.dispatch, tokenEvent('token_usage_changed', SNAP_1, '2026-11-02T09:00:00Z'));
    await settle();
    assert.equal(instance().token_usage.context_tokens, 100000, 'stale snapshot ignored');

    view.release();
    // Subscriptions are left in place: unsubscribing arms RTK keepUnusedDataFor
    // timers that would keep the test process alive.
  } finally {
    refresh.resetChainTokenUsageRefresh();
    (globalThis as any).fetch = prevFetch;
  }
});
