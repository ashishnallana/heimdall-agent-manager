// REQ-FLEET-UI-ACTIONS-1: executable unit tests for role-assigned fleet task action buttons.
// REQ-FLEET-PT-3: provider/model selection logic for the Fleet Management drawer.
// REQ-AUTO-1: no synthetic standard-role Fleet cards or capacity-1 fallback —
// a role is only a fleet entry when persisted or staged via Add Role.
//
// RUN: node --test tests/ui_fleet_actions_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  isRoleAssignedWithoutLiveInstance,
  canStartTask,
  canCompleteTask,
  canPauseTask,
  hasLiveNudgeTarget,
  getUnpauseStatus,
} from '../src/ui/components/tasks/TaskCard.ts';
import {
  activeTasksByRole,
  changedFleetEntries,
  fleetApplyRequests,
  fleetProviderCapabilities,
  flattenProviderModelDrafts,
  getOriginalFleetCapacity,
  getOriginalProviderModel,
  hasCustomRuntimeOverrides,
  isLiveFleetMember,
  liveInstancesByRole,
  nextModelOnProviderChange,
  providerModelModified,
  restartAffectedEntries,
  seedPerBridgeProviderModelDrafts,
  seedProviderModelDrafts,
  summarizeFleetRestartResults,
  modelOptionsForProvider,
} from '../src/ui/components/tasks/fleetSelection.ts';

// -----------------------------------------------------------------------------
// isRoleAssignedWithoutLiveInstance
// -----------------------------------------------------------------------------

test('isRoleAssignedWithoutLiveInstance returns true for role-assigned task without bound instance', () => {
  const task = {
    taskId: 'task_001',
    status: 'assigned',
    assigneeRef: { type: 'agent_id', agent_id: 'agt_worker' },
  };
  assert.equal(isRoleAssignedWithoutLiveInstance(task), true);
});

test('isRoleAssignedWithoutLiveInstance returns false for role-assigned task with live bound instance', () => {
  const task = {
    taskId: 'task_002',
    status: 'in_progress',
    assigneeRef: { type: 'agent_instance', agent_id: 'agt_worker', agent_instance_id: 'inst_live_1' },
    assigneeAgentInstanceId: 'inst_live_1',
  };
  const instances = [
    { agent_instance_id: 'inst_live_1', runtime_status: 'running' },
  ];
  assert.equal(isRoleAssignedWithoutLiveInstance(task, instances), false);
});

test('isRoleAssignedWithoutLiveInstance returns true for role-assigned task with stopped/failed bound instance', () => {
  const task = {
    taskId: 'task_003',
    status: 'assigned',
    assigneeRef: { type: 'agent_instance', agent_id: 'agt_worker', agent_instance_id: 'inst_dead_1' },
  };
  const instances = [
    { agent_instance_id: 'inst_dead_1', runtime_status: 'stopped' },
  ];
  assert.equal(isRoleAssignedWithoutLiveInstance(task, instances), true);
});

test('isRoleAssignedWithoutLiveInstance returns false for direct instance-assigned task without agent_id', () => {
  const task = {
    taskId: 'task_004',
    status: 'assigned',
    assigneeRef: { type: 'agent_instance', agent_instance_id: 'inst_manual_1' },
  };
  assert.equal(isRoleAssignedWithoutLiveInstance(task), false);
});

test('isRoleAssignedWithoutLiveInstance returns false for unassigned task', () => {
  const task = {
    taskId: 'task_005',
    status: 'assigned',
    assigneeRef: null,
  };
  assert.equal(isRoleAssignedWithoutLiveInstance(task), false);
});

// -----------------------------------------------------------------------------
// canStartTask (Start button visibility)
// -----------------------------------------------------------------------------

test('canStartTask returns false (hides Start button) for role-assigned task without live instance', () => {
  const task = {
    taskId: 'task_101',
    status: 'queued',
    assigneeRef: { type: 'agent_id', agent_id: 'agt_worker' },
  };
  assert.equal(canStartTask(task), false);
});

test('canStartTask returns true (shows Start button) for task with live bound instance', () => {
  const task = {
    taskId: 'task_102',
    status: 'assigned',
    assigneeRef: { type: 'agent_instance', agent_id: 'agt_worker', agent_instance_id: 'inst_live_2' },
  };
  const instances = [
    { agent_instance_id: 'inst_live_2', runtime_status: 'running' },
  ];
  assert.equal(canStartTask(task, instances), true);
});

test('canStartTask returns true for role-assigned task without live instance when allowedActions includes start', () => {
  const task = {
    taskId: 'task_103',
    status: 'assigned',
    assigneeRef: { type: 'agent_id', agent_id: 'agt_worker' },
    allowedActions: ['start', 'cancel'],
  };
  assert.equal(canStartTask(task), true);
});

test('canStartTask returns true for role-assigned task without live instance when allowed_actions includes start', () => {
  const task = {
    taskId: 'task_104',
    status: 'queued',
    assigneeRef: { type: 'agent_id', agent_id: 'agt_worker' },
    allowed_actions: ['start'],
  };
  assert.equal(canStartTask(task), true);
});

// -----------------------------------------------------------------------------
// hasLiveNudgeTarget (Nudge button visibility)
// -----------------------------------------------------------------------------

test('hasLiveNudgeTarget returns false for queued task', () => {
  const task = {
    taskId: 'task_201',
    status: 'queued',
    assigneeRef: { type: 'agent_id', agent_id: 'agt_worker' },
  };
  assert.equal(hasLiveNudgeTarget(task), false);
});

test('hasLiveNudgeTarget returns false for completed or cancelled task', () => {
  const completedTask = { taskId: 'task_202', status: 'completed', assigneeRef: { agent_instance_id: 'inst_1' } };
  const cancelledTask = { taskId: 'task_203', status: 'cancelled', assigneeRef: { agent_instance_id: 'inst_1' } };
  assert.equal(hasLiveNudgeTarget(completedTask), false);
  assert.equal(hasLiveNudgeTarget(cancelledTask), false);
});

test('hasLiveNudgeTarget returns false for in_progress task without bound instance', () => {
  const task = {
    taskId: 'task_204',
    status: 'in_progress',
    assigneeRef: { type: 'agent_id', agent_id: 'agt_worker' },
  };
  assert.equal(hasLiveNudgeTarget(task), false);
});

test('hasLiveNudgeTarget returns true for in_progress task with live bound instance', () => {
  const task = {
    taskId: 'task_205',
    status: 'in_progress',
    assigneeRef: { type: 'agent_instance', agent_instance_id: 'inst_live_3' },
  };
  const instances = [
    { agent_instance_id: 'inst_live_3', runtime_status: 'ready' },
  ];
  assert.equal(hasLiveNudgeTarget(task, instances), true);
});

test('hasLiveNudgeTarget returns false for in_progress task with stopped instance', () => {
  const task = {
    taskId: 'task_206',
    status: 'in_progress',
    assigneeRef: { type: 'agent_instance', agent_instance_id: 'inst_dead_2' },
  };
  const instances = [
    { agent_instance_id: 'inst_dead_2', runtime_status: 'failed' },
  ];
  assert.equal(hasLiveNudgeTarget(task, instances), false);
});

test('hasLiveNudgeTarget in validation checks reviewer instances', () => {
  const taskWithoutReviewerInst = {
    taskId: 'task_207',
    status: 'in_validation',
    reviewerRefs: [{ type: 'agent_id', agent_id: 'agt_reviewer' }],
  };
  assert.equal(hasLiveNudgeTarget(taskWithoutReviewerInst), false);

  const taskWithLiveReviewerInst = {
    taskId: 'task_208',
    status: 'in_validation',
    reviewerRefs: [{ type: 'agent_instance', agent_instance_id: 'inst_rev_1' }],
  };
  const instances = [
    { agent_instance_id: 'inst_rev_1', runtime_status: 'idle' },
  ];
  assert.equal(hasLiveNudgeTarget(taskWithLiveReviewerInst, instances), true);
});

// -----------------------------------------------------------------------------
// getUnpauseStatus (Unpause action target)
// -----------------------------------------------------------------------------

test('getUnpauseStatus returns queued for role-assigned task without live instance', () => {
  const task = {
    taskId: 'task_301',
    status: 'paused',
    assigneeRef: { type: 'agent_id', agent_id: 'agt_worker' },
  };
  assert.equal(getUnpauseStatus(task), 'queued');
});

test('getUnpauseStatus returns in_progress for task with live bound instance', () => {
  const task = {
    taskId: 'task_302',
    status: 'paused',
    assigneeRef: { type: 'agent_instance', agent_id: 'agt_worker', agent_instance_id: 'inst_live_4' },
  };
  const instances = [
    { agent_instance_id: 'inst_live_4', runtime_status: 'running' },
  ];
  assert.equal(getUnpauseStatus(task, instances), 'in_progress');
});

// -----------------------------------------------------------------------------
// REQ-FLEET-PT-3: provider/model drafts (Fleet Management drawer)
// -----------------------------------------------------------------------------

const CAPABILITIES = [
  { provider: 'qoder', models: ['smart', 'max'] },
  { provider: 'claude', models: ['opus', 'sonnet'] },
];

test('seedProviderModelDrafts maps provider/model from fleet JSON, defaulting missing values to ""', () => {
  const rawFleets = [
    { agent_id: 'agt_worker', capacity: 2, provider: 'qoder', model: 'max' },
    { agent_id: 'agt_reviewer', capacity: 1 },
    { agentId: 'agt_custom', capacity: 1, provider: '', model: '' },
  ];
  assert.deepEqual(seedProviderModelDrafts(rawFleets), {
    agt_worker: { provider: 'qoder', model: 'max' },
    agt_reviewer: { provider: '', model: '' },
    agt_custom: { provider: '', model: '' },
  });
  assert.deepEqual(seedProviderModelDrafts([]), {});
});

test('getOriginalProviderModel returns server values for persisted roles and "" for unpersisted roles', () => {
  const rawFleets = [{ agent_id: 'agt_worker', capacity: 2, provider: 'qoder', model: 'smart' }];
  assert.deepEqual(getOriginalProviderModel(rawFleets, 'agt_worker'), { provider: 'qoder', model: 'smart' });
  assert.deepEqual(getOriginalProviderModel(rawFleets, 'agt_reviewer'), { provider: '', model: '' });
});

test('getOriginalFleetCapacity keeps the capacity rule: persisted row or null — no standard-role default', () => {
  const rawFleets = [{ agent_id: 'agt_worker', capacity: 3 }];
  assert.equal(getOriginalFleetCapacity(rawFleets, 'agt_worker'), 3);
  // REQ-AUTO-1: agt_worker/agt_reviewer are no longer special-cased; an
  // unpersisted role of any ID reports null so it only reaches Apply when the
  // user stages it via Add Role.
  assert.equal(getOriginalFleetCapacity([], 'agt_worker'), null);
  assert.equal(getOriginalFleetCapacity(rawFleets, 'agt_reviewer'), null);
  assert.equal(getOriginalFleetCapacity([], 'agt_reviewer'), null);
  assert.equal(getOriginalFleetCapacity(rawFleets, 'agt_other'), null);
});

test('modelOptionsForProvider returns the selected provider models and none for "" (Auto)', () => {
  assert.deepEqual(modelOptionsForProvider(CAPABILITIES, 'qoder'), ['smart', 'max']);
  assert.deepEqual(modelOptionsForProvider(CAPABILITIES, 'claude'), ['opus', 'sonnet']);
  assert.deepEqual(modelOptionsForProvider(CAPABILITIES, ''), []);
  assert.deepEqual(modelOptionsForProvider(CAPABILITIES, 'unknown'), []);
});

test('fleetProviderCapabilities maps the live bridge providers payload (name + models) to models', () => {
  const payload = {
    bridge_id: 'brg_x',
    default_provider: 'claude',
    default_model: 'normal',
    providers: [
      { name: 'claude', enabled: true, models: { cheap: '', normal: 'claude-sonnet', smart: 'claude-opus' } },
      { name: 'codex', enabled: true, models: { cheap: '', normal: '', smart: '' } },
      { name: 'disabled-one', enabled: false, models: { normal: 'x' } },
    ],
  };
  assert.deepEqual(fleetProviderCapabilities(payload), [
    { provider: 'claude', models: ['normal', 'smart'] },
    { provider: 'codex', models: [] },
  ]);
});

test('fleetProviderCapabilities maps the explicit models payload shape unchanged', () => {
  const payload = {
    bridge_id: 'brg_x',
    default_provider: 'qoder',
    default_model: 'smart',
    providers: [{ provider: 'qoder', models: ['smart', 'max'], default_model: 'smart' }],
  };
  assert.deepEqual(fleetProviderCapabilities(payload), [
    { provider: 'qoder', models: ['smart', 'max'] },
  ]);
  assert.deepEqual(fleetProviderCapabilities({ providers: [] }), []);
  assert.deepEqual(fleetProviderCapabilities(undefined), []);
});

test('nextModelOnProviderChange keeps a model the new provider offers, otherwise resets to ""', () => {
  assert.equal(nextModelOnProviderChange('smart', 'qoder', CAPABILITIES), 'smart');
  assert.equal(nextModelOnProviderChange('smart', 'claude', CAPABILITIES), '');
  assert.equal(nextModelOnProviderChange('opus', 'claude', CAPABILITIES), 'opus');
  assert.equal(nextModelOnProviderChange('opus', '', CAPABILITIES), '');
});

test('changedFleetEntries includes Apply payload provider/model for a provider-only change', () => {
  const rawFleets = [
    { agent_id: 'agt_worker', capacity: 2, provider: '', model: '' },
    { agent_id: 'agt_reviewer', capacity: 1, provider: '', model: '' },
  ];
  const fleets = [...rawFleets];
  const entries = changedFleetEntries(
    fleets,
    { agt_worker: 2, agt_reviewer: 1 },
    { agt_worker: { provider: 'qoder', model: '' }, agt_reviewer: { provider: '', model: '' } },
    rawFleets,
  );
  assert.deepEqual(entries, [
    { agentId: 'agt_worker', capacity: 2, provider: 'qoder', model: '' },
  ]);
});

test('changedFleetEntries includes a model-only change and a capacity+provider change', () => {
  const rawFleets = [
    { agent_id: 'agt_worker', capacity: 2, provider: 'qoder', model: 'smart' },
    { agent_id: 'agt_reviewer', capacity: 1, provider: '', model: '' },
  ];
  const entries = changedFleetEntries(
    rawFleets,
    { agt_worker: 2, agt_reviewer: 4 },
    { agt_worker: { provider: 'qoder', model: 'max' }, agt_reviewer: { provider: 'claude', model: '' } },
    rawFleets,
  );
  assert.deepEqual(entries, [
    { agentId: 'agt_worker', capacity: 2, provider: 'qoder', model: 'max' },
    { agentId: 'agt_reviewer', capacity: 4, provider: 'claude', model: '' },
  ]);
});

test('changedFleetEntries detects provider/model staged on a not-yet-persisted role (Add Role staging)', () => {
  // A role staged through the drawer Add Role flow carries drafts but no
  // persisted row: origCapacity is null, so any staged value reaches Apply.
  const fleets = [{ agent_id: 'agt_custom_dev', capacity: 1, active_count: 0 }];
  const entries = changedFleetEntries(
    fleets,
    { agt_custom_dev: 1 },
    { agt_custom_dev: { provider: 'qoder', model: 'max' } },
    [],
  );
  assert.deepEqual(entries, [
    { agentId: 'agt_custom_dev', capacity: 1, provider: 'qoder', model: 'max' },
  ]);
  // The same holds for the former standard-role IDs — no special-casing.
  const standardEntries = changedFleetEntries(
    [{ agent_id: 'agt_worker', capacity: 1, active_count: 0 }],
    { agt_worker: 1 },
    { agt_worker: { provider: 'qoder', model: 'max' } },
    [],
  );
  assert.deepEqual(standardEntries, [
    { agentId: 'agt_worker', capacity: 1, provider: 'qoder', model: 'max' },
  ]);
});

test('changedFleetEntries detects a provider/model-only change on a role with NO capacity draft (staged role)', () => {
  // Live-found case: the drawer no longer seeds synthetic standard-role cards,
  // so a role only appears when persisted or Add-Role-staged. Staging always
  // writes both drafts — but a provider/model-only draft with no capacity draft
  // must still reach Apply (the upsert creates the fleet row).
  const fleets = [{ agent_id: 'agt_custom_dev', capacity: 1, active_count: 0 }];
  const entries = changedFleetEntries(
    fleets,
    {},
    { agt_custom_dev: { provider: 'claude', model: 'smart' } },
    [],
  );
  assert.deepEqual(entries, [
    { agentId: 'agt_custom_dev', capacity: 1, provider: 'claude', model: 'smart' },
  ]);
  // Untouched roles with neither draft stay out.
  const untouched = changedFleetEntries(fleets, {}, {}, []);
  assert.deepEqual(untouched, []);
});

test('changedFleetEntries skips roles whose drafts match the server state', () => {
  const rawFleets = [
    { agent_id: 'agt_worker', capacity: 2, provider: 'qoder', model: 'smart' },
    { agent_id: 'agt_reviewer', capacity: 1, provider: '', model: '' },
  ];
  const entries = changedFleetEntries(
    rawFleets,
    { agt_worker: 2, agt_reviewer: 1 },
    { agt_worker: { provider: 'qoder', model: 'smart' }, agt_reviewer: { provider: '', model: '' } },
    rawFleets,
  );
  assert.deepEqual(entries, []);
});

test('changedFleetEntries ignores provider/model diffs when no draft entry exists (capacity-only flow preserved)', () => {
  const rawFleets = [{ agent_id: 'agt_worker', capacity: 2, provider: 'qoder', model: 'smart' }];
  const entries = changedFleetEntries(
    rawFleets,
    { agt_worker: 5 },
    {},
    rawFleets,
  );
  assert.deepEqual(entries, [
    { agentId: 'agt_worker', capacity: 5, provider: 'qoder', model: 'smart' },
  ]);
});

// -----------------------------------------------------------------------------
// REQ-RS-3 / REQ-RS-4: confirm-before-restart — affected roles, PUT bodies, summary
//
// The drawer asks before any PUT when a provider/model edit would leave live
// instances on the old values; "Apply to New Instances Only" is exactly the
// pre-restart request shape. All of that decision logic is pure and covered here.
// -----------------------------------------------------------------------------

const ROLE_MEMBERS = [
  { agent_id: 'agt_worker', agent_instance_id: 'inst_live_1', runtime_status: 'running' },
  { agent_id: 'agt_worker', agent_instance_id: 'inst_live_2', runtimeStatus: 'launching' },
  { agent_id: 'agt_worker', agent_instance_id: 'inst_dead_1', runtime_status: 'stopped' },
  { agent_id: 'agt_reviewer', agent_instance_id: 'inst_live_3', runtime_status: 'idle' },
  { agent_id: 'agt_reviewer', agent_instance_id: 'inst_dead_2', runtime_status: 'failed' },
  { agent_id: 'agt_reviewer', agent_instance_id: 'inst_dead_3', runtime_status: 'terminated' },
];

test('isLiveFleetMember treats every non-terminal runtime status as live', () => {
  for (const status of ['running', 'ready', 'idle', 'launching', '']) {
    assert.equal(isLiveFleetMember({ runtime_status: status }), true);
  }
  for (const status of ['stopped', 'failed', 'terminated', 'Stopped']) {
    assert.equal(isLiveFleetMember({ runtime_status: status }), false);
  }
  // camelCase field and a missing status behave like the drawer's inline predicate always did.
  assert.equal(isLiveFleetMember({ runtimeStatus: 'failed' }), false);
  assert.equal(isLiveFleetMember({}), true);
});

test('liveInstancesByRole groups live members per role and drops terminal/role-less rows', () => {
  const grouped = liveInstancesByRole([
    ...ROLE_MEMBERS,
    { agent_instance_id: 'inst_orphan', runtime_status: 'running' },
  ]);
  assert.deepEqual(Object.keys(grouped).sort(), ['agt_reviewer', 'agt_worker']);
  assert.deepEqual(grouped.agt_worker.map((m) => m.agent_instance_id), ['inst_live_1', 'inst_live_2']);
  assert.deepEqual(grouped.agt_reviewer.map((m) => m.agent_instance_id), ['inst_live_3']);
  assert.deepEqual(liveInstancesByRole([]), {});
});

test('activeTasksByRole counts active tasks per role via assignee ref and bound instance', () => {
  const tasks = [
    { status: 'in_progress', assigneeRef: { agent_id: 'agt_worker' } },
    { status: 'queued', assigneeRef: { agent_id: 'agt_worker' } },
    { status: 'in_validation', assigneeRef: { agent_id: 'agt_reviewer' } },
    { status: 'completed', assigneeRef: { agent_id: 'agt_worker' } },
    { status: 'cancelled', assigneeRef: { agent_id: 'agt_reviewer' } },
    { status: 'in_progress', assigneeRef: null, assigneeAgentInstanceId: 'inst_live_3' },
  ];
  const grouped = activeTasksByRole(tasks, ROLE_MEMBERS);
  assert.equal((grouped.agt_worker || []).length, 2);
  assert.equal((grouped.agt_reviewer || []).length, 2);
});

test('activeTasksByRole counts a task for both its assignee role and its bound instance role', () => {
  const task = {
    status: 'in_progress',
    assigneeRef: { agent_id: 'agt_worker' },
    assigneeAgentInstanceId: 'inst_live_3',
  };
  const grouped = activeTasksByRole([task], ROLE_MEMBERS);
  assert.deepEqual(grouped.agt_worker, [task]);
  assert.deepEqual(grouped.agt_reviewer, [task]);
  assert.deepEqual(activeTasksByRole([], ROLE_MEMBERS), {});
});

test('providerModelModified compares drafts against the persisted row ("" included)', () => {
  const rawFleets = [{ agent_id: 'agt_worker', capacity: 1, provider: 'qoder', model: 'smart' }];
  assert.equal(providerModelModified(rawFleets, 'agt_worker', { agt_worker: { provider: 'qoder', model: 'max' } }), true);
  assert.equal(providerModelModified(rawFleets, 'agt_worker', { agt_worker: { provider: 'claude', model: 'smart' } }), true);
  assert.equal(providerModelModified(rawFleets, 'agt_worker', { agt_worker: { provider: 'qoder', model: 'smart' } }), false);
  // Clearing back to Auto is still a change: live instances carry the old values.
  assert.equal(providerModelModified(rawFleets, 'agt_worker', { agt_worker: { provider: '', model: '' } }), true);
  // Untouched roles have no draft at all.
  assert.equal(providerModelModified(rawFleets, 'agt_reviewer', {}), false);
  // A not-yet-persisted role inherits ''/'' as its original.
  assert.equal(providerModelModified([], 'agt_worker', { agt_worker: { provider: 'qoder', model: '' } }), true);
  assert.equal(providerModelModified([], 'agt_worker', { agt_worker: { provider: '', model: '' } }), false);
});

test('restartAffectedEntries: provider/model change + live instance prompts; capacity-only or zero live does not', () => {
  const rawFleets = [
    { agent_id: 'agt_worker', capacity: 2, provider: '', model: '' },
    { agent_id: 'agt_reviewer', capacity: 1, provider: '', model: '' },
  ];
  const liveCounts = { agt_worker: 2, agt_reviewer: 0 };

  // Provider change on a role with live instances -> the one role to confirm.
  const providerDrafts = { agt_worker: { provider: 'qoder', model: '' } };
  const providerEntries = changedFleetEntries(rawFleets, { agt_worker: 2, agt_reviewer: 1 }, providerDrafts, rawFleets);
  assert.deepEqual(restartAffectedEntries(providerEntries, rawFleets, providerDrafts, liveCounts), [
    { agentId: 'agt_worker', capacity: 2, provider: 'qoder', model: '' },
  ]);

  // Same change, zero live instances -> nothing to confirm, direct apply.
  assert.deepEqual(restartAffectedEntries(providerEntries, rawFleets, providerDrafts, { agt_worker: 0 }), []);

  // Capacity-only change on a role WITH live instances -> never a restart prompt.
  const capacityEntries = changedFleetEntries(rawFleets, { agt_worker: 5, agt_reviewer: 1 }, {}, rawFleets);
  assert.deepEqual(capacityEntries, [
    { agentId: 'agt_worker', capacity: 5, provider: '', model: '' },
  ]);
  assert.deepEqual(restartAffectedEntries(capacityEntries, rawFleets, {}, liveCounts), []);

  // Model-only change on a live role -> prompt.
  const modelDrafts = { agt_worker: { provider: '', model: 'smart' } };
  const tierEntries = changedFleetEntries(rawFleets, { agt_worker: 2, agt_reviewer: 1 }, modelDrafts, rawFleets);
  assert.deepEqual(restartAffectedEntries(tierEntries, rawFleets, modelDrafts, liveCounts), [
    { agentId: 'agt_worker', capacity: 2, provider: '', model: 'smart' },
  ]);
});

test('fleetApplyRequests flags affected roles only; unaffected bodies keep the pre-restart shape', () => {
  const entries = [
    { agentId: 'agt_worker', capacity: 2, provider: 'qoder', model: '' },
    { agentId: 'agt_reviewer', capacity: 3, provider: 'claude', model: 'smart' },
  ];
  const restartNow = fleetApplyRequests(entries, [entries[0]]);
  assert.deepEqual(restartNow, [
    { agentId: 'agt_worker', capacity: 2, provider: 'qoder', model: '', restartLiveInstances: true },
    { agentId: 'agt_reviewer', capacity: 3, provider: 'claude', model: 'smart' },
  ]);
  assert.equal('restartLiveInstances' in restartNow[1], false);

  // "Apply to New Instances Only" (no affected roles) -> no flag key anywhere,
  // i.e. the request objects equal today's payloads.
  const newInstancesOnly = fleetApplyRequests(entries, []);
  assert.deepEqual(newInstancesOnly, [
    { agentId: 'agt_worker', capacity: 2, provider: 'qoder', model: '' },
    { agentId: 'agt_reviewer', capacity: 3, provider: 'claude', model: 'smart' },
  ]);
  assert.equal(JSON.stringify(newInstancesOnly).includes('restart'), false);
  assert.deepEqual(fleetApplyRequests([], []), []);
});

test('summarizeFleetRestartResults maps per-role restart counts and flattens failures', () => {
  const summary = summarizeFleetRestartResults([
    { agentId: 'agt_worker', restarted_instance_ids: ['inst_a', 'inst_b'], restart_failures: [] },
    {
      agentId: 'agt_reviewer',
      restarted_instance_ids: [],
      restart_failures: [{ instance_id: 'inst_c', message: 'launch failed: model missing' }],
    },
  ]);
  assert.deepEqual(summary.restartedByRole, [
    { agentId: 'agt_worker', count: 2 },
    { agentId: 'agt_reviewer', count: 0 },
  ]);
  assert.deepEqual(summary.failures, [
    { instance_id: 'inst_c', message: 'launch failed: model missing' },
  ]);
});

test('summarizeFleetRestartResults tolerates flag-less responses and missing fields', () => {
  const summary = summarizeFleetRestartResults([
    { agentId: 'agt_worker' },
    { agentId: 'agt_reviewer', restarted_instance_ids: ['inst_z'] },
  ]);
  assert.deepEqual(summary.restartedByRole, [{ agentId: 'agt_reviewer', count: 1 }]);
  assert.deepEqual(summary.failures, []);
  assert.deepEqual(summarizeFleetRestartResults([]), {
    restartedByRole: [],
    failures: [],
  });
});

test('drawer decision end-to-end: only the role with a live instance gets the restart flag', () => {
  const rawFleets = [
    { agent_id: 'agt_worker', capacity: 1, provider: '', model: '' },
    { agent_id: 'agt_reviewer', capacity: 1, provider: '', model: '' },
  ];
  const drafts = {
    agt_worker: { provider: 'claude', model: 'smart' },
    agt_reviewer: { provider: 'claude', model: 'smart' },
  };
  const members = [
    { agent_id: 'agt_worker', agent_instance_id: 'inst_live_1', runtime_status: 'running' },
    { agent_id: 'agt_reviewer', agent_instance_id: 'inst_dead_1', runtime_status: 'stopped' },
  ];
  const liveByRole = liveInstancesByRole(members);
  const liveCounts: Record<string, number> = {};
  for (const [agentId, list] of Object.entries(liveByRole)) liveCounts[agentId] = list.length;

  const entries = changedFleetEntries(
    rawFleets,
    { agt_worker: 1, agt_reviewer: 1 },
    drafts,
    rawFleets,
  );
  const affected = restartAffectedEntries(entries, rawFleets, drafts, liveCounts);
  assert.deepEqual(affected.map((e) => e.agentId), ['agt_worker']);

  const requests = fleetApplyRequests(entries, affected);
  assert.deepEqual(
    requests.map((r) => [r.agentId, r.restartLiveInstances === true]),
    [
      ['agt_worker', true],
      ['agt_reviewer', false],
    ],
  );
});

test('model options derived from a live bridge payload drive model selection end-to-end', () => {
  const livePayload = {
    bridge_id: 'brg_x',
    default_provider: 'claude',
    default_model: 'normal',
    providers: [
      { name: 'claude', enabled: true, models: { cheap: '', normal: 'claude-sonnet', smart: 'claude-opus' } },
      { name: 'codex', enabled: true, models: { cheap: '', normal: 'gpt-5-codex', smart: '' } },
    ],
  };
  const caps = fleetProviderCapabilities(livePayload);
  // Provider selected from the live names; models follow the selected provider.
  assert.deepEqual(modelOptionsForProvider(caps, 'claude'), ['normal', 'smart']);
  assert.deepEqual(modelOptionsForProvider(caps, 'codex'), ['normal']);
  // A model from one provider is reset when switching to a provider without it.
  assert.equal(nextModelOnProviderChange('smart', 'codex', caps), '');
  assert.equal(nextModelOnProviderChange('normal', 'codex', caps), 'normal');
});

// -----------------------------------------------------------------------------
// REQ-FLEET-UI-EXPANDABLE-1 & REQ-FLEET-PER-BRIDGE-1: per-bridge runtime config
// -----------------------------------------------------------------------------

test('seedPerBridgeProviderModelDrafts maps per-bridge provider/model for active bridges', () => {
  const rawFleets = [
    { agent_id: 'agt_worker', capacity: 2, provider: 'claude', model: 'smart' },
    { agent_id: 'agt_reviewer', capacity: 1, provider: '', model: '' },
  ];
  const bridges = [
    { bridge_id: 'brg_alpha', label: 'alpha' },
    { bridge_id: 'brg_beta', label: 'beta' },
  ];
  const drafts = seedPerBridgeProviderModelDrafts(rawFleets, bridges, 'brg_alpha');
  assert.deepEqual(drafts, {
    agt_worker: {
      brg_alpha: { provider: 'claude', model: 'smart' },
      brg_beta: { provider: 'claude', model: 'smart' },
    },
    agt_reviewer: {
      brg_alpha: { provider: '', model: '' },
      brg_beta: { provider: '', model: '' },
    },
  });
});

test('hasCustomRuntimeOverrides detects custom provider or model overrides', () => {
  assert.equal(hasCustomRuntimeOverrides({ brg_1: { provider: 'claude', model: '' } }), true);
  assert.equal(hasCustomRuntimeOverrides({ brg_1: { provider: '', model: 'smart' } }), true);
  assert.equal(hasCustomRuntimeOverrides({ brg_1: { provider: '', model: '' } }), false);
  assert.equal(hasCustomRuntimeOverrides(undefined), false);
});

test('flattenProviderModelDrafts prioritizes preferred bridge and detects overrides', () => {
  const drafts = {
    agt_worker: {
      brg_1: { provider: 'qoder', model: 'normal' },
      brg_2: { provider: 'claude', model: 'smart' },
    },
    agt_reviewer: {
      brg_1: { provider: '', model: '' },
      brg_2: { provider: 'gemini', model: 'pro' },
    },
  };
  const flat = flattenProviderModelDrafts(drafts, 'brg_1');
  assert.deepEqual(flat, {
    agt_worker: { provider: 'qoder', model: 'normal' },
    agt_reviewer: { provider: 'gemini', model: 'pro' },
  });
});

test('changedFleetEntries detects changes from per-bridge drafts', () => {
  const rawFleets = [
    { agent_id: 'agt_worker', capacity: 2, provider: '', model: '' },
  ];
  const perBridgeDrafts = {
    agt_worker: {
      brg_main: { provider: 'claude', model: 'opus' },
    },
  };
  const entries = changedFleetEntries(
    rawFleets,
    { agt_worker: 2 },
    perBridgeDrafts,
    rawFleets,
    'brg_main',
  );
  assert.deepEqual(entries, [
    { agentId: 'agt_worker', capacity: 2, provider: '', model: '', bridgeModels: {
      brg_main: { provider: 'claude', model: 'opus' },
    } },
  ]);
});

// -----------------------------------------------------------------------------
// REQ-TB-5: per-task bridge pin — select default, create submit, change/clear
// -----------------------------------------------------------------------------

import {
  TASK_BRIDGE_INHERIT_LABEL,
  taskBridgeOptions,
  taskCreateBridgeFields,
  taskPatchBridgeFields,
  taskBridgeDisplay,
} from '../src/ui/utils/taskBridgePin.ts';

const PIN_BRIDGES = [
  { bridge_id: 'brg_alpha', label: 'alpha host', status: 'online' },
  { bridge_id: 'brg_beta', machine_hostname: 'beta.example', status: 'online' },
  { bridge_id: 'brg_gone', label: 'retired host', status: 'revoked' },
];

test('taskBridgeOptions defaults to Inherit and lists the owner bridges (revoked excluded)', () => {
  const options = taskBridgeOptions(PIN_BRIDGES);
  assert.deepEqual(options, [
    { value: '', label: TASK_BRIDGE_INHERIT_LABEL },
    { value: 'brg_alpha', label: 'alpha host' },
    { value: 'brg_beta', label: 'beta.example' },
  ]);
  // An empty bridge list still offers the inherit default — the modal never pins.
  assert.deepEqual(taskBridgeOptions([]), [{ value: '', label: TASK_BRIDGE_INHERIT_LABEL }]);
});

test('create submit: default create sends no bridge_id, an override pins the chosen bridge', () => {
  // Default (inherit) create — the hub treats absent and '' alike, so the key is
  // simply omitted.
  assert.deepEqual(taskCreateBridgeFields(''), {});
  assert.deepEqual(taskCreateBridgeFields(undefined), {});
  // A concrete bridge is forwarded verbatim.
  assert.deepEqual(taskCreateBridgeFields('brg_alpha'), { bridge_id: 'brg_alpha' });
});

test('change/clear submit: the presence-checked PATCH always carries bridge_id', () => {
  // Change: repin to a concrete bridge.
  assert.deepEqual(taskPatchBridgeFields('brg_beta'), { bridge_id: 'brg_beta' });
  // Clear: '' is the explicit clear-to-inherit signal (must NOT be dropped).
  assert.deepEqual(taskPatchBridgeFields(''), { bridge_id: '' });
});

test('taskBridgeDisplay resolves the pin name and marks inherit', () => {
  // Pinned: name resolved from the /bridges list.
  assert.deepEqual(taskBridgeDisplay('brg_alpha', PIN_BRIDGES), { label: 'alpha host', inherited: false });
  // Unknown id (e.g. revoked/foreign pin): falls back to the raw id, never blank.
  assert.deepEqual(taskBridgeDisplay('brg_other', PIN_BRIDGES), { label: 'brg_other', inherited: false });
  // No pin: inherited.
  assert.deepEqual(taskBridgeDisplay('', PIN_BRIDGES), { label: '', inherited: true });
  assert.deepEqual(taskBridgeDisplay(undefined, PIN_BRIDGES), { label: '', inherited: true });
});

// -----------------------------------------------------------------------------
// REQ-UI-CLI-FINISHING-1 & REQ-UI-CLI-PAUSING-1: Finishing & Pausing UI and helpers
// -----------------------------------------------------------------------------

test('hasLiveNudgeTarget returns true for finishing and pausing tasks with live bound instance', () => {
  const finishingTask = {
    taskId: 'task_fin_1',
    status: 'finishing',
    assigneeRef: { type: 'agent_instance', agent_instance_id: 'inst_fin_live' },
  };
  const pausingTask = {
    taskId: 'task_pau_1',
    status: 'pausing',
    assigneeRef: { type: 'agent_instance', agent_instance_id: 'inst_pau_live' },
  };
  const instances = [
    { agent_instance_id: 'inst_fin_live', runtime_status: 'running' },
    { agent_instance_id: 'inst_pau_live', runtime_status: 'ready' },
  ];

  assert.equal(hasLiveNudgeTarget(finishingTask, instances), true);
  assert.equal(hasLiveNudgeTarget(pausingTask, instances), true);
});

test('hasLiveNudgeTarget returns false for finishing and pausing tasks without bound instance or dead instance', () => {
  const finishingNoInst = {
    taskId: 'task_fin_2',
    status: 'finishing',
    assigneeRef: { type: 'agent_id', agent_id: 'agt_worker' },
  };
  const pausingDeadInst = {
    taskId: 'task_pau_2',
    status: 'pausing',
    assigneeRef: { type: 'agent_instance', agent_instance_id: 'inst_dead' },
  };
  const instances = [
    { agent_instance_id: 'inst_dead', runtime_status: 'stopped' },
  ];

  assert.equal(hasLiveNudgeTarget(finishingNoInst, instances), false);
  assert.equal(hasLiveNudgeTarget(pausingDeadInst, instances), false);
});

test('canStartTask, canCompleteTask, canPauseTask handle finishing and pausing states', () => {
  const finishingTask = {
    taskId: 'task_fin_3',
    status: 'finishing',
    allowedActions: ['complete', 'force_finish', 'revalidate', 'pause', 'cancel', 'nudge'],
  };
  const pausingTask = {
    taskId: 'task_pau_3',
    status: 'pausing',
    allowedActions: ['pause', 'force_pause', 'start', 'cancel', 'nudge'],
  };

  assert.equal(canCompleteTask(finishingTask), true);
  assert.equal(canPauseTask(finishingTask), true);

  assert.equal(canStartTask(pausingTask), true);
  assert.equal(canPauseTask(pausingTask), true);
  assert.equal(canCompleteTask(pausingTask), false);
});

// -----------------------------------------------------------------------------
// Task System v2 M3: Fleet Placement Editor (roles, bridge_id, provider, model, delete)
// -----------------------------------------------------------------------------

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  FLEET_ROLES,
  normalizeFleetRoles,
  toggleFleetRole,
  formatFleetRolesBadge,
  seedFleetRolesDrafts,
  seedFleetBridgeIdDrafts,
  seedFleetMinWarmDrafts,
  seedFleetIdleTtlDrafts,
} from '../src/ui/components/tasks/fleetSelection.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

test('M3 Fleet Placement: roles toggle and dirty detection for staged and persisted rows', () => {
  assert.deepEqual(FLEET_ROLES, ['worker', 'reviewer']);

  const rawFleets = [
    {
      agent_id: 'agt_worker',
      capacity: 2,
      roles: ['worker'],
      bridge_id: 'brg_alpha',
      provider: 'claude',
      model: 'sonnet',
      min_warm: 1,
      idle_ttl_seconds: 600,
    },
  ];

  // Seeding preserves server values
  const rolesDraft = seedFleetRolesDrafts(rawFleets);
  const bridgeIdsDraft = seedFleetBridgeIdDrafts(rawFleets);
  const topPTDraft = seedProviderModelDrafts(rawFleets);
  const minWarmsDraft = seedFleetMinWarmDrafts(rawFleets);
  const idleTtlsDraft = seedFleetIdleTtlDrafts(rawFleets);

  assert.deepEqual(rolesDraft.agt_worker, ['worker']);
  assert.equal(bridgeIdsDraft.agt_worker, 'brg_alpha');
  assert.deepEqual(topPTDraft.agt_worker, { provider: 'claude', model: 'sonnet' });
  assert.equal(minWarmsDraft.agt_worker, 1);
  assert.equal(idleTtlsDraft.agt_worker, 600);

  // Toggling reviewer adds it alongside worker
  rolesDraft.agt_worker = toggleFleetRole(rolesDraft.agt_worker, 'reviewer');
  assert.deepEqual(rolesDraft.agt_worker, ['worker', 'reviewer']);

  // Changing bridge_id to '' (clear pin to inherit) and top-level model to 'opus'
  bridgeIdsDraft.agt_worker = '';
  topPTDraft.agt_worker = { provider: 'claude', model: 'opus' };

  const changed = changedFleetEntries(
    rawFleets,
    { agt_worker: 2 },
    {},
    rawFleets,
    'brg_alpha',
    {
      roles: rolesDraft,
      bridgeIds: bridgeIdsDraft,
      topLevelProviderModels: topPTDraft,
      minWarms: minWarmsDraft,
      idleTtls: idleTtlsDraft,
    }
  );

  assert.equal(changed.length, 1);
  assert.deepEqual(changed[0], {
    agentId: 'agt_worker',
    capacity: 2,
    provider: 'claude',
    model: 'opus',
    roles: ['worker', 'reviewer'],
    bridgeId: '',
    minWarm: 1,
    idleTtlSeconds: 600,
  });

  // Apply payload preserves empty string bridgeId (so hub clears bridge pin) and roles array
  const requests = fleetApplyRequests(changed, []);
  assert.deepEqual(requests, [
    {
      agentId: 'agt_worker',
      capacity: 2,
      provider: 'claude',
      model: 'opus',
      roles: ['worker', 'reviewer'],
      bridgeId: '',
      minWarm: 1,
      idleTtlSeconds: 600,
    },
  ]);
});

test('M3 Fleet Placement: top-level provider/model edit triggers restart confirmation when live instances exist', () => {
  const rawFleets = [
    {
      agent_id: 'agt_worker',
      capacity: 2,
      roles: ['worker'],
      bridge_id: 'brg_alpha',
      provider: 'claude',
      model: 'sonnet',
    },
  ];
  const topLevelDraftPT = {
    agt_worker: { provider: 'claude', model: 'opus' },
  };
  const changed = changedFleetEntries(
    rawFleets,
    { agt_worker: 2 },
    {},
    rawFleets,
    'brg_alpha',
    { topLevelProviderModels: topLevelDraftPT }
  );
  assert.equal(changed.length, 1);
  assert.equal(
    providerModelModified(rawFleets, 'agt_worker', {}, 'brg_alpha', topLevelDraftPT),
    true
  );

  const affected = restartAffectedEntries(
    changed,
    rawFleets,
    {},
    { agt_worker: 1 },
    'brg_alpha',
    topLevelDraftPT
  );
  assert.equal(affected.length, 1);
  assert.equal(affected[0].agentId, 'agt_worker');
});

test('M3 Fleet Placement UI & API contract: FleetManagementDrawer.tsx and taskChains.ts wire roles, bridge_id, provider, model, and delete', () => {
  const drawerSrc = fs.readFileSync(
    path.join(REPO_ROOT, 'src/ui/components/tasks/FleetManagementDrawer.tsx'),
    'utf8'
  );
  const taskChainsSrc = fs.readFileSync(
    path.join(REPO_ROOT, 'src/ui/api/endpoints/taskChains.ts'),
    'utf8'
  );
  const tasksSrc = fs.readFileSync(
    path.join(REPO_ROOT, 'src/ui/api/endpoints/tasks.ts'),
    'utf8'
  );

  // Verify FleetSlotChips renders role badge
  assert.ok(
    drawerSrc.includes('fleet-slot-chip-roles-'),
    'FleetSlotChips must render role badge per fleet chip'
  );

  // Verify FleetManagementDrawer renders controls for roles, placement bridge, default provider/model, min_warm, idle_ttl, and remove
  assert.ok(
    drawerSrc.includes('fleet-role-toggle-'),
    'FleetManagementDrawer must render role toggle buttons (worker / reviewer)'
  );
  assert.ok(
    drawerSrc.includes('fleet-bridge-select-'),
    'FleetManagementDrawer must render placement bridge selector'
  );
  assert.ok(
    drawerSrc.includes('fleet-default-provider-select-') &&
      drawerSrc.includes('fleet-default-model-select-'),
    'FleetManagementDrawer must render top-level provider and model selectors'
  );
  assert.ok(
    drawerSrc.includes('fleet-min-warm-input-') &&
      drawerSrc.includes('fleet-idle-ttl-input-'),
    'FleetManagementDrawer must render min_warm and idle_ttl_seconds inputs'
  );
  assert.ok(
    drawerSrc.includes('fleet-delete-role-btn-'),
    'FleetManagementDrawer must render a Remove button per fleet role card'
  );

  // Verify taskChains.ts normalizes and sends roles and bridge_id, and exposes deleteTaskChainFleet
  assert.ok(
    taskChainsSrc.includes('body.roles = roles') &&
      taskChainsSrc.includes('body.bridge_id = resolvedBridgeId'),
    'updateTaskChainFleet must send roles and bridge_id in the PUT body'
  );
  assert.ok(
    taskChainsSrc.includes('deleteTaskChainFleet') &&
      tasksSrc.includes('useDeleteTaskChainFleetMutation'),
    'deleteTaskChainFleet must be defined in taskChains.ts and re-exported in tasks.ts'
  );
});

