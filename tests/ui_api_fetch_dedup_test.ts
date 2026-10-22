import { test } from 'node:test';
import assert from 'node:assert/strict';
import { makeVaultStore, installFetchCapture, installWindowShim } from './helpers/vaultEndpointHarness.ts';

const baseline = process.env.DEDUP_BASELINE === '1';

test('equivalent request replay uses actual endpoint middleware and fetch', async () => {
  installWindowShim();
  const store = await makeVaultStore();
  const net = installFetchCapture();
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const { shellsApi } = await import('../src/ui/api/endpoints/shells.ts');
  const { cardsApi } = await import('../src/ui/api/endpoints/cards.ts');
  const { tasksApi } = await import('../src/ui/api/endpoints/tasks.ts');
  const { agentsApi } = await import('../src/ui/api/endpoints/agents.ts');
  const expected = baseline ? 2 : 1;
  async function replay(endpoint: any, args: any[], response: any, count: number, label: string) {
    store.dispatch(heimdallApi.util.resetApiState());
    net.reset();
    net.setNextResponse(response);
    const subs = args.map(arg => store.dispatch(endpoint.initiate(arg)));
    const results = await Promise.all(subs);
    for (const result of results) assert.equal(result.isError, false, JSON.stringify(result.error));
    assert.equal(net.requests.length, count, label + ': ' + JSON.stringify(net.requests));
    console.log(label + ' HTTP=' + net.requests.length);
    subs.forEach(sub => sub.unsubscribe());
  }
  try {
    await replay(shellsApi.endpoints.listShells,
      [{ chainId: 'chain1' }, { chainId: 'chain1', cursor: '', limit: 0, status: undefined }],
      { data: { sessions: [], next_cursor: '' } }, expected, 'shell equivalent URL');
    await replay(cardsApi.endpoints.getCard,
      [{ id: 'card1' }, { cardId: 'card1' }],
      { data: { card_id: 'card1', operations: [] } }, expected, 'card aliases');
    await replay(tasksApi.endpoints.fetchChainTaskDetail,
      [{ chainId: 'chain1', taskId: 'task1' }, { taskId: 'task1', chainId: 'chain1' }],
      { data: { task_id: 'task1' } }, 1, 'task detail existing dedup');
    await replay(agentsApi.endpoints.fetchAgentIdentity,
      [{ agentId: 'agent1' }, { agentId: 'agent1' }],
      { data: { agent_id: 'agent1' } }, 1, 'agent detail existing dedup');

    // Distinct owner scopes, filters, cursor and page sizes must never collide.
    await replay(shellsApi.endpoints.listShells, [
      {}, { chainId: 'chain1' }, { bridgeId: 'bridge1' }, { projectId: 'project1' },
      { agentInstanceId: 'instance1' }, { status: 'live' }, { cursor: 'next' }, { limit: 1 },
    ], { data: { sessions: [], next_cursor: '' } }, 8, 'distinct shell queries');
    await replay(cardsApi.endpoints.getCard,
      [{ id: 'other' }, { id: 'ignored', cardId: 'winner' }],
      { data: { card_id: 'card1', operations: [] } }, 2, 'distinct cards and alias precedence');

    if (!baseline) {
      store.dispatch(heimdallApi.util.resetApiState());
      net.reset();
      net.setNextResponse({ data: { card_id: 'card1', operations: [] } });
      const subs = [
        store.dispatch(cardsApi.endpoints.getCard.initiate({ id: 'card1' })),
        store.dispatch(cardsApi.endpoints.getCard.initiate({ cardId: 'card1' })),
      ];
      await Promise.all(subs);
      store.dispatch(heimdallApi.util.invalidateTags([{ type: 'Card', id: 'card1' }]));
      await new Promise(resolve => setTimeout(resolve, 30));
      assert.equal(net.requests.length, 2, 'one initial fetch and one mutation/event invalidation fetch');
      store.dispatch(heimdallApi.util.resetApiState());
      await store.dispatch(cardsApi.endpoints.getCard.initiate({ cardId: 'card1' }));
      assert.equal(net.requests.length, 3, 'auth/logout cache reset fetches fresh');
      subs.forEach(sub => sub.unsubscribe());
    }
  } finally {
    store.dispatch(heimdallApi.util.resetApiState());
  }
});
