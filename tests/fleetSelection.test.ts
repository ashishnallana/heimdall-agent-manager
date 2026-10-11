import test from 'node:test';
import assert from 'node:assert/strict';
import {
  detectLiveInstanceRuntimeMismatch,
  groupMismatchesByRole,
  isLiveFleetMember,
  restartAffectedEntries,
  fleetApplyRequests,
  summarizeFleetRestartResults,
  providerModelModified,
  changedFleetEntries,
  resolvedFleetProviderModel,
  seedPerBridgeProviderModelDrafts,
  type FleetProviderModel,
  type ChangedFleetEntry,
} from '../src/ui/components/tasks/fleetSelection.ts';
import { effectiveChainBridgeId } from '../src/ui/utils/taskBridgePin.ts';

test('fleet launch display resolves concrete settings and preserves explicit choices', () => {
  const capabilities = [{ provider: 'codex', models: ['model-a', 'model-b'] }];
  assert.deepEqual(resolvedFleetProviderModel({ provider: '', model: '' }, capabilities), { provider: 'codex', model: 'model-a' });
  assert.deepEqual(resolvedFleetProviderModel({ provider: '', model: 'model-b' }, capabilities), { provider: 'codex', model: 'model-b' });
  assert.deepEqual(resolvedFleetProviderModel({ provider: 'missing', model: 'pinned' }, capabilities), { provider: 'missing', model: 'pinned' });
  assert.deepEqual(resolvedFleetProviderModel({ provider: '', model: '' }, []), { provider: '', model: '' });
});

test('per-bridge fleet changes survive seeding and Apply without flattening', () => {
  const fleets = [{ agent_id: 'worker', capacity: 1, provider: 'codex', model: 'model-a', bridge_models: {
    second: { provider: 'claude', model: 'model-c' },
  } }];
  const drafts = seedPerBridgeProviderModelDrafts(fleets, [{ bridge_id: 'first' }, { bridge_id: 'second' }], 'first');
  assert.deepEqual(drafts.worker.second, { provider: 'claude', model: 'model-c' });
  assert.deepEqual(changedFleetEntries(fleets, { worker: 1 }, drafts, fleets, 'first'), []);
  drafts.worker.second.model = 'model-d';
  const changed = changedFleetEntries(fleets, { worker: 1 }, drafts, fleets, 'first');
  assert.equal(changed.length, 1);
  assert.equal(changed[0].model, 'model-a');
  assert.equal(changed[0].bridgeModels?.first, undefined, 'unchanged role defaults must remain role-wide');
  assert.equal(fleetApplyRequests(changed, changed)[0].bridgeModels?.second.model, 'model-d');
  assert.equal(providerModelModified(fleets, 'worker', drafts, 'first'), true);
});

test('capacity edits preserve unrendered bridge selections without pinning resolved defaults', () => {
  const fleets = [{ agent_id: 'worker', capacity: 1, provider: 'codex', model: 'model-a', bridge_models: {
    unrendered: { provider: 'claude', model: 'model-c' },
  } }];
  const drafts = seedPerBridgeProviderModelDrafts(fleets, [{ bridge_id: 'first' }], 'first');
  const changed = changedFleetEntries(fleets, { worker: 2 }, drafts, fleets, 'first');
  assert.deepEqual(changed[0].bridgeModels, fleets[0].bridge_models);
});

test('bridge display follows coordinator, member, directory and owner bridge resolution', () => {
  const instances = [{ agent_instance_id: 'coord', bridge_id: 'actual' }, { agent_instance_id: 'worker', bridge_id: 'member' }];
  const chain = { coordinatorAgentInstanceId: 'coord', members: [{ agentInstanceId: 'worker' }], directories: [{ bridgeId: 'directory' }] };
  assert.equal(effectiveChainBridgeId(chain, instances, [{ bridge_id: 'fallback' }]), 'actual');
  assert.equal(effectiveChainBridgeId({ ...chain, coordinatorAgentInstanceId: '' }, instances, []), 'member');
  assert.equal(effectiveChainBridgeId({ directories: chain.directories }, [], []), 'directory');
  assert.equal(effectiveChainBridgeId({}, [], [{ bridge_id: 'fallback' }]), 'fallback');
});

// ---------------------------------------------------------------------------
// detectLiveInstanceRuntimeMismatch tests (REQ-FLEET-MISMATCH-MODAL-1)
// ---------------------------------------------------------------------------

test('detectLiveInstanceRuntimeMismatch returns empty array on empty or undefined instances', () => {
  const result1 = detectLiveInstanceRuntimeMismatch([], {});
  assert.equal(result1.length, 0);
  assert.deepEqual(result1.affectedRoleIds, []);

  const result2 = detectLiveInstanceRuntimeMismatch(undefined as any, {});
  assert.equal(result2.length, 0);
});

test('detectLiveInstanceRuntimeMismatch filters out non-live members (stopped, failed, terminated)', () => {
  const instances = [
    { agent_instance_id: 'inst_stopped', agent_id: 'agt_worker', provider: 'codex', model: 'normal', runtime_status: 'stopped' },
    { agent_instance_id: 'inst_failed', agent_id: 'agt_worker', provider: 'codex', model: 'normal', runtime_status: 'failed' },
    { agent_instance_id: 'inst_terminated', agent_id: 'agt_worker', provider: 'codex', model: 'normal', runtime_status: 'terminated' },
  ];
  const targetConfig = {
    agt_worker: { provider: 'claude', model: 'smart' },
  };

  const mismatches = detectLiveInstanceRuntimeMismatch(instances, targetConfig);
  assert.equal(mismatches.length, 0, 'Non-live instances must be ignored by mismatch detection');
});

test('detectLiveInstanceRuntimeMismatch identifies provider mismatch for active instance', () => {
  const instances = [
    {
      agent_instance_id: 'inst_live_1',
      agent_id: 'agt_worker',
      bridge_id: 'brg_alpha',
      provider: 'codex',
      model: 'normal',
      runtime_status: 'running',
    },
  ];
  const targetConfig = {
    agt_worker: { provider: 'claude', model: 'normal' },
  };

  const mismatches = detectLiveInstanceRuntimeMismatch(instances, targetConfig);
  assert.equal(mismatches.length, 1);
  assert.equal(mismatches[0].instanceId, 'inst_live_1');
  assert.equal(mismatches[0].agentId, 'agt_worker');
  assert.equal(mismatches[0].actualProvider, 'codex');
  assert.equal(mismatches[0].targetProvider, 'claude');
  assert.equal(mismatches[0].actualModel, 'normal');
  assert.equal(mismatches[0].targetModel, 'normal');
  assert.equal(mismatches[0].mismatchType, 'provider');
  assert.deepEqual(mismatches.affectedRoleIds, ['agt_worker']);
});

test('detectLiveInstanceRuntimeMismatch identifies model mismatch for active instance', () => {
  const instances = [
    {
      agent_instance_id: 'inst_live_2',
      agent_id: 'agt_reviewer',
      bridge_id: 'brg_alpha',
      provider: 'claude',
      model: 'cheap',
      runtime_status: 'running',
    },
  ];
  const targetConfig = {
    agt_reviewer: { provider: 'claude', model: 'smart' },
  };

  const mismatches = detectLiveInstanceRuntimeMismatch(instances, targetConfig);
  assert.equal(mismatches.length, 1);
  assert.equal(mismatches[0].instanceId, 'inst_live_2');
  assert.equal(mismatches[0].agentId, 'agt_reviewer');
  assert.equal(mismatches[0].actualModel, 'cheap');
  assert.equal(mismatches[0].targetModel, 'smart');
  assert.equal(mismatches[0].mismatchType, 'model');
});

test('detectLiveInstanceRuntimeMismatch identifies multiple mismatches (provider and model)', () => {
  const instances = [
    {
      agent_instance_id: 'inst_live_3',
      agent_id: 'agt_worker',
      bridge_id: 'brg_alpha',
      provider: 'codex',
      model: 'cheap',
      runtime_status: 'running',
    },
  ];
  const targetConfig = {
    agt_worker: { provider: 'claude', model: 'smart' },
  };

  const mismatches = detectLiveInstanceRuntimeMismatch(instances, targetConfig);
  assert.equal(mismatches.length, 1);
  assert.equal(mismatches[0].mismatchType, 'multiple');
  assert.equal(mismatches[0].reasons.length, 2);
});

test('detectLiveInstanceRuntimeMismatch returns 0 mismatches when instance runtime matches target', () => {
  const instances = [
    {
      agent_instance_id: 'inst_ok',
      agent_id: 'agt_worker',
      bridge_id: 'brg_alpha',
      provider: 'claude',
      model: 'smart',
      runtime_status: 'running',
    },
  ];
  const targetConfig = {
    agt_worker: { provider: 'claude', model: 'smart' },
  };

  const mismatches = detectLiveInstanceRuntimeMismatch(instances, targetConfig);
  assert.equal(mismatches.length, 0);
  assert.deepEqual(mismatches.affectedRoleIds, []);
});

test('detectLiveInstanceRuntimeMismatch respects per-bridge overrides', () => {
  const instances = [
    // Running on brg_alpha where override is claude/smart -> matches
    {
      agent_instance_id: 'inst_alpha',
      agent_id: 'agt_worker',
      bridge_id: 'brg_alpha',
      provider: 'claude',
      model: 'smart',
      runtime_status: 'running',
    },
    // Running on brg_beta where override is gemini/pro -> currently running codex/normal -> mismatch
    {
      agent_instance_id: 'inst_beta',
      agent_id: 'agt_worker',
      bridge_id: 'brg_beta',
      provider: 'codex',
      model: 'normal',
      runtime_status: 'running',
    },
  ];

  const targetConfig = {
    agt_worker: {
      brg_alpha: { provider: 'claude', model: 'smart' },
      brg_beta: { provider: 'gemini', model: 'pro' },
    },
  };

  const mismatches = detectLiveInstanceRuntimeMismatch(instances, targetConfig);
  assert.equal(mismatches.length, 1);
  assert.equal(mismatches[0].instanceId, 'inst_beta');
  assert.equal(mismatches[0].bridgeId, 'brg_beta');
  assert.equal(mismatches[0].actualProvider, 'codex');
  assert.equal(mismatches[0].targetProvider, 'gemini');
  assert.equal(mismatches[0].actualModel, 'normal');
  assert.equal(mismatches[0].targetModel, 'pro');
});

test('detectLiveInstanceRuntimeMismatch falls back to role default when per-bridge override inherits', () => {
  const instances = [
    {
      agent_instance_id: 'inst_inherit',
      agent_id: 'agt_worker',
      bridge_id: 'brg_alpha',
      provider: 'codex',
      model: 'normal',
      runtime_status: 'running',
    },
  ];

  // brg_alpha has empty (inherit) provider/model, role default is claude/smart
  const targetConfig = {
    roleDefaults: { agt_worker: { provider: 'claude', model: 'smart' } },
    perBridgeOverrides: {
      agt_worker: { brg_alpha: { provider: '', model: '' } },
    },
  };

  const mismatches = detectLiveInstanceRuntimeMismatch(instances, targetConfig);
  assert.equal(mismatches.length, 1);
  assert.equal(mismatches[0].actualProvider, 'codex');
  assert.equal(mismatches[0].targetProvider, 'claude');
  assert.equal(mismatches[0].targetModel, 'smart');
});

test('detectLiveInstanceRuntimeMismatch detects bridge mismatch when targetBridgeId specified', () => {
  const instances = [
    {
      agent_instance_id: 'inst_wrong_bridge',
      agent_id: 'agt_worker',
      bridge_id: 'brg_alpha',
      provider: 'claude',
      model: 'smart',
      runtime_status: 'running',
    },
  ];
  const targetConfig = {
    roleDefaults: { agt_worker: { provider: 'claude', model: 'smart' } },
    targetBridgeId: 'brg_beta',
  };

  const mismatches = detectLiveInstanceRuntimeMismatch(instances, targetConfig);
  assert.equal(mismatches.length, 1);
  assert.equal(mismatches[0].bridgeId, 'brg_alpha');
  assert.equal(mismatches[0].targetBridgeId, 'brg_beta');
  assert.equal(mismatches[0].mismatchType, 'bridge');
});

test('detectLiveInstanceRuntimeMismatch supports grouped map input and camelCase/snake_case aliases', () => {
  const groupedInstances = {
    agt_worker: [
      {
        agentInstanceId: 'inst_camel_1',
        agentId: 'agt_worker',
        bridgeId: 'brg_alpha',
        provider: 'old_provider',
        model: 'old_model',
        runtimeStatus: 'running',
      },
    ],
  };
  const targetConfig = {
    agt_worker: { provider: 'new_provider', model: 'new_model' },
  };

  const mismatches = detectLiveInstanceRuntimeMismatch(groupedInstances, targetConfig);
  assert.equal(mismatches.length, 1);
  assert.equal(mismatches[0].agent_instance_id, 'inst_camel_1');
  assert.equal(mismatches[0].agent_id, 'agt_worker');
  assert.equal(mismatches[0].provider, 'old_provider');
  assert.equal(mismatches[0].model, 'old_model');
});

test('groupMismatchesByRole summarizes mismatches correctly', () => {
  const mismatches = [
    {
      instanceId: 'inst_1',
      agentId: 'agt_worker',
      bridgeId: 'brg_1',
      actualProvider: 'a',
      actualModel: 'b',
      targetProvider: 'c',
      targetModel: 'd',
      mismatchType: 'provider' as const,
      reasons: [],
      agent_instance_id: 'inst_1',
      agent_id: 'agt_worker',
      bridge_id: 'brg_1',
      provider: 'a',
      model: 'b',
    },
    {
      instanceId: 'inst_2',
      agentId: 'agt_worker',
      bridgeId: 'brg_1',
      actualProvider: 'a',
      actualModel: 'b',
      targetProvider: 'c',
      targetModel: 'd',
      mismatchType: 'provider' as const,
      reasons: [],
      agent_instance_id: 'inst_2',
      agent_id: 'agt_worker',
      bridge_id: 'brg_1',
      provider: 'a',
      model: 'b',
    },
  ];

  const summary = groupMismatchesByRole(mismatches);
  assert.equal(summary['agt_worker'].mismatchedCount, 2);
  assert.equal(summary['agt_worker'].instances.length, 2);
  assert.equal(summary['agt_worker'].targetProvider, 'c');
});

// ---------------------------------------------------------------------------
// Restart actions and fleet persistence helpers (REQ-FLEET-PERSIST-1, REQ-RS-3/4)
// ---------------------------------------------------------------------------

test('restartAffectedEntries identifies affected roles with live instances and modified provider/model', () => {
  const rawFleets = [
    { agent_id: 'agt_worker', capacity: 2, provider: 'codex', model: 'normal' },
    { agent_id: 'agt_reviewer', capacity: 1, provider: 'claude', model: 'smart' },
  ];
  const changedEntries: ChangedFleetEntry[] = [
    { agentId: 'agt_worker', capacity: 2, provider: 'claude', model: 'smart' },
    { agentId: 'agt_reviewer', capacity: 3, provider: 'claude', model: 'smart' }, // Capacity only!
  ];
  const draftPT = {
    agt_worker: { provider: 'claude', model: 'smart' },
    agt_reviewer: { provider: 'claude', model: 'smart' },
  };
  const liveCounts = {
    agt_worker: 2,
    agt_reviewer: 1,
  };

  const affected = restartAffectedEntries(changedEntries, rawFleets, draftPT, liveCounts);
  assert.equal(affected.length, 1);
  assert.equal(affected[0].agentId, 'agt_worker');
});

test('fleetApplyRequests sets restartLiveInstances flag for "Apply & Restart Now"', () => {
  const changedEntries: ChangedFleetEntry[] = [
    { agentId: 'agt_worker', capacity: 2, provider: 'claude', model: 'smart' },
    { agentId: 'agt_other', capacity: 1, provider: '', model: '' },
  ];
  const restartAffected: ChangedFleetEntry[] = [
    { agentId: 'agt_worker', capacity: 2, provider: 'claude', model: 'smart' },
  ];

  const requests = fleetApplyRequests(changedEntries, restartAffected);
  assert.equal(requests.length, 2);
  assert.equal(requests[0].agentId, 'agt_worker');
  assert.equal(requests[0].restartLiveInstances, true);
  assert.equal(requests[1].agentId, 'agt_other');
  assert.equal(requests[1].restartLiveInstances, undefined);
});

test('fleetApplyRequests omits restartLiveInstances for "Apply to New Instances Only"', () => {
  const changedEntries: ChangedFleetEntry[] = [
    { agentId: 'agt_worker', capacity: 2, provider: 'claude', model: 'smart' },
  ];
  // Empty restartAffected = Apply to New Instances Only
  const requests = fleetApplyRequests(changedEntries, []);
  assert.equal(requests.length, 1);
  assert.equal(requests[0].agentId, 'agt_worker');
  assert.equal(requests[0].restartLiveInstances, undefined);
});

test('summarizeFleetRestartResults aggregates restarted instances and failure messages', () => {
  const results = [
    {
      agentId: 'agt_worker',
      restarted_instance_ids: ['inst_1', 'inst_2'],
      restart_failures: [{ instance_id: 'inst_fail_1', message: 'Instance busy' }],
    },
    {
      agentId: 'agt_reviewer',
      restarted_instance_ids: ['inst_3'],
    },
  ];

  const summary = summarizeFleetRestartResults(results);
  assert.deepEqual(summary.restartedByRole, [
    { agentId: 'agt_worker', count: 2 },
    { agentId: 'agt_reviewer', count: 1 },
  ]);
  assert.equal(summary.failures.length, 1);
  assert.equal(summary.failures[0].instance_id, 'inst_fail_1');
  assert.equal(summary.failures[0].message, 'Instance busy');
});
