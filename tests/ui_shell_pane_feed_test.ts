import { test } from 'node:test';
import assert from 'node:assert/strict';
import { configureStore } from '@reduxjs/toolkit';
import { installWindowShim } from './helpers/vaultEndpointHarness.ts';

test('computeShellPanePollingInterval and shellsApi getShellPane endpoint caching', async () => {
  installWindowShim();
  const { computeShellPanePollingInterval, isShellTerminalStatus } = await import('../src/ui/hooks/useShellPaneSubscription.ts');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const { shellsApi, useGetShellPaneQuery, useLazyGetShellPaneQuery } = await import('../src/ui/api/endpoints/shells.ts');

  assert.equal(
    computeShellPanePollingInterval({ sessionId: null, isExpanded: true, isActiveTab: true }),
    0,
    'null sessionId must return 0'
  );

  assert.equal(
    computeShellPanePollingInterval({ sessionId: '', isExpanded: true, isActiveTab: true }),
    0,
    'empty sessionId must return 0'
  );

  assert.equal(
    computeShellPanePollingInterval({ sessionId: 'sh_1', isExpanded: true, isActiveTab: false }),
    0,
    'isActiveTab=false must return 0'
  );

  assert.equal(
    computeShellPanePollingInterval({
      sessionId: 'sh_1',
      isExpanded: true,
      isActiveTab: true,
      isDocumentHidden: true,
    }),
    0,
    'isDocumentHidden=true must return 0'
  );

  for (const status of ['exited', 'killed', 'failed']) {
    assert.equal(
      computeShellPanePollingInterval({
        sessionId: 'sh_1',
        isExpanded: true,
        isActiveTab: true,
        status,
      }),
      0,
      `status=${status} must return 0`
    );
    assert.equal(isShellTerminalStatus(status), true, `${status} must be a terminal status`);
  }

  for (const status of ['starting', 'running']) {
    assert.equal(isShellTerminalStatus(status), false, `${status} must NOT be a terminal status`);
  }

  assert.equal(
    computeShellPanePollingInterval({
      sessionId: 'sh_1',
      isExpanded: true,
      isActiveTab: true,
      status: 'running',
      isDocumentHidden: false,
    }),
    500,
    'expanded active subscription must return 500 (500ms)'
  );

  assert.equal(
    computeShellPanePollingInterval({
      sessionId: 'sh_1',
      isExpanded: false,
      isActiveTab: true,
      status: 'running',
      isDocumentHidden: false,
    }),
    300000,
    'collapsed active subscription must return 300000 (5m)'
  );

  const endpoint = shellsApi.endpoints.getShellPane;
  assert.ok(endpoint, 'shellsApi must define getShellPane endpoint');
  assert.equal(typeof endpoint.initiate, 'function', 'endpoint must have initiate function');

  assert.equal(typeof useGetShellPaneQuery, 'function', 'useGetShellPaneQuery must be exported');
  assert.equal(typeof useLazyGetShellPaneQuery, 'function', 'useLazyGetShellPaneQuery must be exported');

  let fetchUrlCalled = '';
  let fetchCallCount = 0;
  let mockResponsePayload: any = {
    data: {
      ok: true,
      unchanged: false,
      hash: 'hash_v1',
      output: 'line 1\nline 2',
      line_count: 2,
    },
  };

  globalThis.fetch = (async (url: string) => {
    fetchUrlCalled = url;
    fetchCallCount++;
    return {
      ok: true,
      status: 200,
      json: async () => mockResponsePayload,
      text: async () => JSON.stringify(mockResponsePayload),
    } as any;
  }) as any;

  const store = configureStore({
    reducer: {
      [heimdallApi.reducerPath]: heimdallApi.reducer,
    },
    middleware: (getDefaultMiddleware) => getDefaultMiddleware().concat(heimdallApi.middleware),
  });

  const res1 = await store.dispatch(
    endpoint.initiate({ sessionId: 'sh_test_1', width: 80, lineLimit: 120 }, { forceRefetch: true })
  );
  assert.equal(fetchCallCount, 1);
  assert.ok(fetchUrlCalled.includes('/api/v1/shells/sh_test_1/pane'));
  assert.ok(fetchUrlCalled.includes('since_hash='));
  assert.ok(fetchUrlCalled.includes('width=80'));
  assert.ok(fetchUrlCalled.includes('line_limit=120'));
  assert.equal(res1.data?.output, 'line 1\nline 2');
  assert.equal(res1.data?.hash, 'hash_v1');

  mockResponsePayload = {
    data: {
      ok: true,
      unchanged: true,
      hash: 'hash_v1',
    },
  };

  await store.dispatch(
    endpoint.initiate(
      { sessionId: 'sh_test_1', sinceHash: 'hash_v1', width: 80, lineLimit: 120 },
      { forceRefetch: true }
    )
  );
  assert.equal(fetchCallCount, 2);
  assert.ok(fetchUrlCalled.includes('since_hash=hash_v1'));

  const querySubstate = endpoint.select({
    sessionId: 'sh_test_1',
    width: 80,
    lineLimit: 120,
  })(store.getState());

  assert.equal(
    querySubstate.data?.output,
    'line 1\nline 2',
    'cached output buffer must be retained when response is unchanged'
  );
  assert.equal(querySubstate.data?.hash, 'hash_v1');
  assert.equal(querySubstate.data?.unchanged, true);
  store.dispatch(heimdallApi.util.resetApiState());
});
