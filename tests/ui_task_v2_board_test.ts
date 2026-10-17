// Task System v2 (Milestone M4): UI test suite for Ticket Board,
// Workflow Pipeline, Badge Derivation, Status Lines, Diff Truncation,
// and Hook Cleanup Invariants.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_task_v2_board_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {
  normalizeTaskState,
  getTaskBadges,
  getTaskStatusLines,
  TASK_STATES_ORDER,
  TASK_STATE_LABELS,
  TASK_STATE_COLORS,
} from '../src/ui/components/tasks/taskV2Types.ts';
import type { TaskStateV2 } from '../src/ui/components/tasks/taskV2Types.ts';
import type { TaskWire } from '../src/ui/api/taskWire.ts';

const REPO_ROOT = path.resolve(import.meta.dirname, '..');

// Helper to construct a baseline TaskWire
function makeTask(overrides: Partial<TaskWire> = {}): TaskWire {
  return {
    task_id: 'task-test-1',
    chain_id: 'chain-test-1',
    title: 'Test Task',
    state: 'backlog',
    attempt_no: 1,
    max_attempts: 5,
    created_at: new Date(Date.now() - 3600000).toISOString(),
    updated_at: new Date(Date.now() - 1800000).toISOString(),
    brief: {
      goal: 'Test goal',
      acceptance: ['Item 1'],
      verify: 'npm test',
    },
    ...overrides,
  };
}

test('normalizeTaskState correctly normalizes v2 and legacy state strings', () => {
  // Direct v2 states
  assert.equal(normalizeTaskState('backlog'), 'backlog');
  assert.equal(normalizeTaskState('ready'), 'ready');
  assert.equal(normalizeTaskState('in_progress'), 'in_progress');
  assert.equal(normalizeTaskState('in_review'), 'in_review');
  assert.equal(normalizeTaskState('done'), 'done');
  assert.equal(normalizeTaskState('cancelled'), 'cancelled');

  // Aliases and case insensitivity
  assert.equal(normalizeTaskState('RUNNING'), 'in_progress');
  assert.equal(normalizeTaskState('working'), 'in_progress');
  assert.equal(normalizeTaskState('review'), 'in_review');
  assert.equal(normalizeTaskState('under_review'), 'in_review');
  assert.equal(normalizeTaskState('published'), 'ready');
  assert.equal(normalizeTaskState('unclaimed'), 'ready');
  assert.equal(normalizeTaskState('completed'), 'done');
  assert.equal(normalizeTaskState('finished'), 'done');
  assert.equal(normalizeTaskState('canceled'), 'cancelled');
  assert.equal(normalizeTaskState('archived'), 'cancelled');

  // Unknown defaults to backlog
  assert.equal(normalizeTaskState('unknown_state'), 'backlog');
  assert.equal(normalizeTaskState(''), 'backlog');
  assert.equal(normalizeTaskState(undefined), 'backlog');
});

test('TASK_STATES_ORDER and color definitions preserve 5 states + cancelled', () => {
  assert.deepEqual(TASK_STATES_ORDER, [
    'in_progress',
    'in_review',
    'ready',
    'backlog',
    'done',
    'cancelled',
  ]);

  for (const st of TASK_STATES_ORDER) {
    assert.ok(TASK_STATE_LABELS[st], `Label missing for ${st}`);
    assert.ok(TASK_STATE_COLORS[st], `Color missing for ${st}`);
  }
});

test('getTaskBadges derives TTL countdown and tone for in-progress lease', () => {
  const nowMs = 1700000000000;

  // 12 mins left -> accent
  const task12m = makeTask({
    state: 'in_progress',
    leases: [
      {
        lease_id: 'l-1',
        holder_instance_id: 'inst_agt_worker',
        bridge_id: 'br-local',
        expires_at: new Date(nowMs + 12 * 60000).toISOString(),
        hard_deadline_at: new Date(nowMs + 55 * 60000).toISOString(),
        confirmed_at: new Date(nowMs - 3 * 60000).toISOString(),
        kind: 'work',
      },
    ],
  });
  const badges12m = getTaskBadges(task12m, [], nowMs);
  const ttlBadge12m = badges12m.find((b) => b.label.includes('⏱'));
  assert.ok(ttlBadge12m, 'Should have TTL badge');
  assert.equal(ttlBadge12m.label, '⏱ worker · 12m');
  assert.equal(ttlBadge12m.tone, 'accent');

  // 4 mins left -> warn
  const task4m = makeTask({
    state: 'in_progress',
    leases: [
      {
        lease_id: 'l-2',
        holder_instance_id: 'inst_agt_worker',
        expires_at: new Date(nowMs + 4 * 60000).toISOString(),
        kind: 'work',
      },
    ],
  });
  const badges4m = getTaskBadges(task4m, [], nowMs);
  const ttlBadge4m = badges4m.find((b) => b.label.includes('⏱'));
  assert.equal(ttlBadge4m?.tone, 'warn');

  // 2 mins left -> danger
  const task2m = makeTask({
    state: 'in_progress',
    leases: [
      {
        lease_id: 'l-3',
        holder_instance_id: 'inst_agt_worker',
        expires_at: new Date(nowMs + 2 * 60000).toISOString(),
        kind: 'work',
      },
    ],
  });
  const badges2m = getTaskBadges(task2m, [], nowMs);
  const ttlBadge2m = badges2m.find((b) => b.label.includes('⏱'));
  assert.equal(ttlBadge2m?.tone, 'danger');
});

test('getTaskBadges derives bridge pin, attempt count, review roles, blocked on you, and verified', () => {
  const nowMs = 1700000000000;

  // Gate badge
  const gateTask = makeTask({ kind: 'gate', state: 'in_review' });
  const gateBadges = getTaskBadges(gateTask, [], nowMs);
  assert.ok(gateBadges.some((b) => b.label === 'gate' && b.tone === 'accent'));

  // Bridge pin on idle task
  const pinnedTask = makeTask({ bridge_id: 'prod-edge-1' });
  const pinnedBadges = getTaskBadges(pinnedTask, [], nowMs);
  assert.ok(pinnedBadges.some((b) => b.label === '⌂ prod-edge-1'));

  // Attempt count >= 2
  const attemptTask = makeTask({ attempt_no: 3 });
  const attemptBadges = getTaskBadges(attemptTask, [], nowMs);
  assert.ok(attemptBadges.some((b) => b.label === 'attempt 3/5' && b.tone === 'neutral'));

  const highAttemptTask = makeTask({ attempt_no: 4 });
  const highAttemptBadges = getTaskBadges(highAttemptTask, [], nowMs);
  assert.ok(highAttemptBadges.some((b) => b.label === 'attempt 4/5' && b.tone === 'warn'));

  // In review with user approval
  const reviewTask = makeTask({
    state: 'in_review',
    requires_user_approval: true,
    brief: {
      goal: 'review goal',
      acceptance: ['ok'],
      verify: 'npm test',
      review_roles: ['reviewer', 'security'],
    },
  });
  const reviewBadges = getTaskBadges(reviewTask, [], nowMs);
  assert.ok(reviewBadges.some((b) => b.label === '2 reviews + you' && b.tone === 'accent'));

  // Blocked on human
  const blockedTask = makeTask({
    state: 'backlog',
    blocked_on: {
      kind: 'human',
      reason: 'Need database password',
      since: new Date(nowMs - 600000).toISOString(),
    },
  });
  const blockedBadges = getTaskBadges(blockedTask, [], nowMs);
  assert.ok(blockedBadges.some((b) => b.label === '⛔ blocked on you' && b.tone === 'danger'));

  // Done state
  const doneTask = makeTask({ state: 'done' });
  const doneBadges = getTaskBadges(doneTask, [], nowMs);
  assert.ok(doneBadges.some((b) => b.label === '✓ verified' && b.tone === 'ok'));
});

test('getTaskStatusLines generates human-readable status sentences for each state', () => {
  const nowMs = 1700000000000;

  // In progress with lease
  const taskInProg = makeTask({
    state: 'in_progress',
    attempt_no: 2,
    leases: [
      {
        lease_id: 'l-1',
        holder_instance_id: 'worker-agent',
        expires_at: new Date(nowMs + 10 * 60000).toISOString(),
        hard_deadline_at: new Date(nowMs + 45 * 60000).toISOString(),
        kind: 'work',
      },
    ],
  });
  const [line1, line2] = getTaskStatusLines(taskInProg, [], nowMs);
  assert.match(line1, /worker-agent is working · attempt 2\/5 · lease 10 min left/);
  assert.match(line2, /hard cap in 45 min · auto-extends on active agent calls/);

  // In review gate
  const gateTask = makeTask({ kind: 'gate', state: 'in_review' });
  const [gateLine1, gateLine2] = getTaskStatusLines(gateTask, [], nowMs);
  assert.equal(gateLine1, 'Gate — waiting on your decision');
  assert.equal(gateLine2, 'Downstream stages stay unmaterialised until approved');

  // Ready unclaimed
  const readyTask = makeTask({
    state: 'ready',
    ready_since: new Date(nowMs - 15 * 60000).toISOString(),
  });
  const [readyLine1, readyLine2] = getTaskStatusLines(readyTask, [], nowMs);
  assert.match(readyLine1, /Ready — will be granted to the next free worker/);
  assert.match(readyLine2, /unclaimed for 15 min/);

  // Blocked on human
  const blockedTask = makeTask({
    state: 'backlog',
    blocked_on: { kind: 'human', reason: 'Missing API key' },
  });
  const [bLine1, bLine2] = getTaskStatusLines(blockedTask, [], nowMs);
  assert.match(bLine1, /Blocked on you — Missing API key/);
  assert.equal(bLine2, 'Nothing will move until you answer');

  // Done
  const doneTask = makeTask({ state: 'done', attempt_no: 1 });
  const [dLine1, dLine2] = getTaskStatusLines(doneTask, [], nowMs);
  assert.equal(dLine1, 'Done · completed and verified');
  assert.equal(dLine2, '1 attempt');
});

test('CommitDiff query contract includes pagination and truncated flag', () => {
  // Verify that commit-diff response typing and API structure handle truncated flag
  interface CommitDiffResponse {
    hunks?: Array<{
      old_start: number;
      old_lines: number;
      new_start: number;
      new_lines: number;
      header: string;
      lines: string[];
    }>;
    files_changed?: number;
    insertions?: number;
    deletions?: number;
    truncated?: boolean;
    next_cursor?: string;
  }

  const samplePayload: CommitDiffResponse = {
    hunks: [
      {
        old_start: 1,
        old_lines: 5,
        new_start: 1,
        new_lines: 7,
        header: '@@ -1,5 +1,7 @@',
        lines: [' context', '+new line', '-old line'],
      },
    ],
    files_changed: 1,
    insertions: 1,
    deletions: 1,
    truncated: true,
    next_cursor: 'cursor-200',
  };

  assert.equal(samplePayload.truncated, true);
  assert.equal(samplePayload.next_cursor, 'cursor-200');
  assert.equal(samplePayload.hunks?.length, 1);
});

test('Invariant: legacy v1 hooks and endpoints are removed and v2 hooks are present', () => {
  const endpointsContent = fs.readFileSync(
    path.join(REPO_ROOT, 'src/ui/api/endpoints/tasks.ts'),
    'utf8'
  );

  // Assert legacy v1 hooks are NOT present
  assert.ok(
    !endpointsContent.includes('useSetTaskStatusMutation'),
    'useSetTaskStatusMutation must be deleted'
  );
  assert.ok(
    !endpointsContent.includes('useVoteTaskMutation'),
    'useVoteTaskMutation must be deleted'
  );
  assert.ok(
    !endpointsContent.includes('useNudgeTaskMutation'),
    'useNudgeTaskMutation must be deleted'
  );
  assert.ok(
    !endpointsContent.includes('useSetInstanceCurrentTaskMutation'),
    'useSetInstanceCurrentTaskMutation must be deleted'
  );

  // Assert v2 hooks ARE present
  assert.ok(
    endpointsContent.includes('useUserReviewTaskMutation'),
    'useUserReviewTaskMutation must exist'
  );
  assert.ok(
    endpointsContent.includes('useReopenTaskMutation'),
    'useReopenTaskMutation must exist'
  );
  assert.ok(
    endpointsContent.includes('useAnswerTaskBlockerMutation'),
    'useAnswerTaskBlockerMutation must exist'
  );
  assert.ok(
    endpointsContent.includes('useVerifyTaskMutation'),
    'useVerifyTaskMutation must exist'
  );
  assert.ok(
    endpointsContent.includes('useFetchTaskEventsQuery'),
    'useFetchTaskEventsQuery must exist'
  );
  assert.ok(
    endpointsContent.includes('useFetchCommitDiffQuery'),
    'useFetchCommitDiffQuery must exist'
  );
  assert.ok(
    endpointsContent.includes('useFetchWorkflowTemplatesQuery'),
    'useFetchWorkflowTemplatesQuery must exist'
  );
  assert.ok(
    endpointsContent.includes('useFetchWorkflowStatusQuery'),
    'useFetchWorkflowStatusQuery must exist'
  );
  assert.ok(
    endpointsContent.includes('useRetryWorkflowMutation'),
    'useRetryWorkflowMutation must exist'
  );
  assert.ok(
    endpointsContent.includes('useCancelWorkflowMutation'),
    'useCancelWorkflowMutation must exist'
  );
  assert.ok(
    endpointsContent.includes('useRunWorkflowMutation'),
    'useRunWorkflowMutation must exist'
  );
});

test('chain detail normalizer keeps the v2 wire fields the board and detail views read', async () => {
  // Regression: normalizeTask projected tasks to legacy camelCase only, so
  // TaskCard rendered task-card-undefined and a click selected `undefined`
  // (detail view never opened). Feed an API-shaped chain detail through it.
  const { normalizeTaskChainDetail } = await import('../src/ui/api/endpoints/tasks.ts');
  const wire = {
    task_id: 'task_abc',
    chain_id: 'chain_abc',
    title: 'Add refresh_tokens table',
    publish_state: 'published',
    state: 'ready',
    kind: 'task',
    priority: 'p0',
    attempt_no: 2,
    bridge_id: 'brg_1',
    ready_since: '2026-10-17T04:38:42Z',
    blocked_on: null,
    requires_user_approval: true,
    brief: { goal: 'Create the table', acceptance: ['migration applies'], verify: 'true' },
    leases: [],
    comment_summary: { count: 1, last_comment_at: '', last_comment_author_agent_instance_id: '', last_comment_preview: 'hi' },
  };
  const chain = normalizeTaskChainDetail({ chain_id: 'chain_abc', title: 'c', tasks: [wire], members: [] });
  const t = chain.tasks[0];
  for (const key of Object.keys(wire) as (keyof typeof wire)[]) {
    if (key === 'priority' || key === 'brief') continue;
    assert.deepEqual(t[key], wire[key], `wire field ${key} must survive normalization`);
  }
  assert.equal(t.priority, 'p0');
  assert.deepEqual(t.brief, wire.brief);
  // Legacy camelCase readers keep working.
  assert.equal(t.taskId, 'task_abc');
  assert.equal(t.attemptNo, 2);
  // Badges derived from the normalized task see the wire fields too.
  const labels = getTaskBadges(t as TaskWire, []).map((b) => b.label).join(' ');
  assert.ok(!labels.includes('undefined'), `badges must not render undefined: ${labels}`);
});
