// T6: code outside React reads the bridge list through the shared RTK listBridges
// cache (readBridgeRows) instead of calling GET /bridges itself, and the paths that
// act on the answer (auto-unseal re-check, key delivery, enrollment) force a fetch
// through that cache.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_bridge_list_cache_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { configureStore } from '@reduxjs/toolkit';

const { heimdallApi, setupHeimdallApiListeners } = await import('../src/ui/api/heimdallApi.ts');
const { bridgeSupportApi, readBridgeRows } = await import('../src/ui/api/endpoints/bridgeSupport.ts');
const bridgesEndpoints = await import('../src/ui/api/endpoints/bridges.ts');
const { providerSetupApi } = await import('../src/ui/components/providers/providerSetupApi.ts');
const { agentsApi } = await import('../src/ui/api/endpoints/agents.ts');

const store = configureStore({
  reducer: { [heimdallApi.reducerPath]: heimdallApi.reducer },
  middleware: (defaults) => defaults().concat(heimdallApi.middleware),
});
// The app binds its store this way (store/store.ts); readBridgeRows then uses it.
setupHeimdallApiListeners(store.dispatch);

const ROWS = [
  { bridge_id: 'brg_locked', label: 'Desktop', machine_hostname: 'desk', status: 'online', vault_status: 'locked', capabilities: ['x'] },
  { bridge_id: 'brg_open', label: 'Laptop', status: 'online', vault_status: 'unlocked' },
  { bridge_id: 'brg_unpaired', status: 'offline', vault_status: 'unpaired' },
];

function mockHub(): { reads: string[]; restore: () => void } {
  const reads: string[] = [];
  const original = globalThis.fetch;
  globalThis.fetch = (async (input: any, init: any = {}) => {
    const url = new URL(String(input), 'https://hub.example.test');
    const method = init.method || 'GET';
    reads.push(`${method} ${url.pathname}${url.search}`);
    if (url.pathname === '/api/v1/bridges') {
      const rows = url.searchParams.get('include_pending')
        ? [...ROWS, { bridge_id: 'brg_new', enrollment_state: 'pending', label: 'New' }]
        : ROWS;
      return Response.json({ data: rows });
    }
    if (url.pathname.endsWith('/provider-status')) return Response.json({ data: { providers: [] } });
    if (url.pathname.endsWith('/bridge-support')) return Response.json({ data: { ok: true } });
    throw new Error(`Unexpected request: ${method} ${url.pathname}`);
  }) as typeof fetch;
  return {
    reads,
    restore: () => {
      globalThis.fetch = original;
      store.dispatch(heimdallApi.util.resetApiState());
    },
  };
}

const bridgeListReads = (reads: string[]) => reads.filter((r) => r.startsWith('GET /api/v1/bridges') && !r.includes('/api/v1/bridges/'));

test('readBridgeRows serves repeat reads from the shared cache and shares it with listBridges', async () => {
  const hub = mockHub();
  try {
    const first = await readBridgeRows();
    const second = await readBridgeRows();
    assert.deepEqual(bridgeListReads(hub.reads), ['GET /api/v1/bridges'], 'one GET /bridges for two reads');
    assert.deepEqual(second, first);
    assert.equal('capabilities' in first[0], false, 'unfiltered hub capabilities are dropped, as in listBridges');
    const cached = bridgeSupportApi.endpoints.listBridges.select(undefined)(store.getState() as any);
    assert.deepEqual(cached.data?.bridges.map((b: any) => b.bridge_id), ['brg_locked', 'brg_open', 'brg_unpaired'],
      'the read populated the same cache entry components subscribe to');

    await readBridgeRows({ fresh: true });
    assert.equal(bridgeListReads(hub.reads).length, 2, 'fresh forces a fetch through the cache');
  } finally {
    hub.restore();
  }
});

test('auto-unseal re-check and key delivery read fresh; Devices panel and callers reuse the cache', async () => {
  const hub = mockHub();
  try {
    assert.deepEqual(await bridgesEndpoints.listUnpairedBridgeIds(), ['brg_unpaired']);
    assert.deepEqual(await bridgesEndpoints.listUnpairedBridgeIds(), ['brg_unpaired']);
    assert.equal(bridgeListReads(hub.reads).length, 1, 'the unpaired list is cached');

    assert.deepEqual(await bridgesEndpoints.listOnlineLockedBridgeIds(), ['brg_locked']);
    assert.equal(bridgeListReads(hub.reads).length, 2, 'the auto-unseal re-check never trusts a cached row');
    assert.deepEqual(await bridgesEndpoints.listOnlineBridgeIds(), ['brg_locked', 'brg_open']);
    assert.equal(bridgeListReads(hub.reads).length, 3, 'key delivery after a rotation reads fresh');

    const setup = await providerSetupApi.get('brg_locked');
    assert.deepEqual(setup.bridge, { bridge_id: 'brg_locked', label: 'Desktop', machine_hostname: 'desk', status: 'online' });
    await store.dispatch(agentsApi.endpoints.enableBridgeSupport.initiate({ agentId: 'agt_1' }) as any);
    assert.equal(bridgeListReads(hub.reads).length, 3, 'provider setup and enableBridgeSupport add no GET /bridges');
    const put = hub.reads.find((r) => r.startsWith('PUT '));
    assert.equal(put, 'PUT /api/v1/agents/agt_1/bridge-support');
  } finally {
    hub.restore();
  }
});

test('pending enrollments use their own include_pending cache entry, read fresh for the enrollment flows', async () => {
  const hub = mockHub();
  try {
    await readBridgeRows();
    const pending = await bridgesEndpoints.fetchPendingBridgeEnrollments();
    assert.deepEqual(pending.map((p) => p.bridge_id), ['brg_new']);
    await bridgesEndpoints.fetchPendingBridgeEnrollments();
    assert.deepEqual(bridgeListReads(hub.reads),
      ['GET /api/v1/bridges', 'GET /api/v1/bridges?include_pending=1', 'GET /api/v1/bridges?include_pending=1']);
    const plain = bridgeSupportApi.endpoints.listBridges.select(undefined)(store.getState() as any);
    assert.equal(plain.data?.bridges.some((b: any) => b.bridge_id === 'brg_new'), false, 'pending rows never leak into ordinary pickers');
  } finally {
    hub.restore();
  }
});
