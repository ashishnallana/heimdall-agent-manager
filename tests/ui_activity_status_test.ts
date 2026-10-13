import { test } from 'node:test';
import assert from 'node:assert/strict';
import './helpers/vaultEndpointHarness.ts';

test('mapAgent, agentRuntimeDot, agentHasLiveSession, and isAgentRunning activity status rules', async () => {
  const storage = new Map<string, string>();
  (globalThis as any).window = {
    localStorage: {
      getItem(key: string) { return storage.has(key) ? storage.get(key) ?? null : null; },
      setItem(key: string, value: string) { storage.set(key, value); },
      removeItem(key: string) { storage.delete(key); },
    },
    odinApi: undefined,
  };

  const { mapAgent } = await import('../src/ui/api/agentCatalog.ts');
  const { agentRuntimeDot, isAgentRunning } = await import('../src/ui/utils/agentStatus.ts');

  const active = mapAgent({ agent_instance_id: 'active@local', connected: true, activity_status: 'active' });
  assert.equal(active.status, 'connected', 'active activity should map to connected/active UI status');

  const idle = mapAgent({ agent_instance_id: 'idle@local', connected: true, activity_status: 'idle' });
  assert.equal(idle.status, 'idle', 'idle activity should map to idle UI status');

  const offlineWithStaleActivity = mapAgent({ agent_instance_id: 'offline@local', connected: false, activity_status: 'active' });
  assert.equal(offlineWithStaleActivity.status, 'offline', 'stale activity must not override offline status');

  const startingWithActivity = mapAgent({ agent_instance_id: 'starting@local', connected: true, startup_status: 'starting', activity_status: 'active' });
  assert.equal(startingWithActivity.status, 'starting', 'startup state must outrank activity status');

  assert.equal(agentRuntimeDot({ status: 'offline', activityStatus: 'active' }).label, 'offline', 'runtime dot should preserve offline over stale activity');
  assert.equal(agentRuntimeDot({ startupStatus: 'starting', connected: true, activityStatus: 'idle' }).label, 'starting', 'runtime dot should preserve starting over activity');
  assert.equal(agentRuntimeDot({ connected: true, activityStatus: 'idle' }).label, 'idle', 'runtime dot should show idle for live idle activity');
  assert.equal(agentRuntimeDot({ connected: true, activityStatus: 'active' }).label, 'working', 'runtime dot should display active activity as working');

  assert.equal(isAgentRunning({ connected: false, status: 'offline' }), false, 'offline agent should not count as running');
  assert.equal(isAgentRunning({ connected: true, activityStatus: 'idle' }), true, 'connected idle agent should count as running');
});
