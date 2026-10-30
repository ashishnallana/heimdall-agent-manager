// Task System v2 UI: which human action a task offers, and the board order
// (plan REQ-UI-7 / REQ-UI-9).
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_task_v2_actions_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { canHold, canRecheck, getTaskActions, recheckToast, taskNeedsYou } from '../src/ui/components/tasks/taskActions.ts';
import type { TaskWire } from '../src/ui/api/taskWire.ts';

function task(overrides: Partial<TaskWire> & Record<string, unknown> = {}): TaskWire {
  return {
    task_id: 'task_x',
    chain_id: 'chain_x',
    title: 'T',
    state: 'ready',
    publish_state: 'published',
    kind: 'task',
    attempt_no: 0,
    priority: 'p2',
    brief: { goal: 'g', acceptance: ['a'] },
    ...overrides,
  } as unknown as TaskWire;
}

test('a draft offers Publish and needs you', () => {
  const t = task({ publish_state: 'draft', state: 'backlog' });
  assert.deepEqual(getTaskActions(t).primary, ['publish']);
  assert.ok(taskNeedsYou(t));
});

test('a task blocked on a human offers Answer', () => {
  const t = task({ state: 'backlog', blocked_on: { kind: 'human', reason: 'Which DB?' } as any });
  assert.deepEqual(getTaskActions(t).primary, ['answer']);
  assert.ok(taskNeedsYou(t));
  // blocked on something that is not a person: nothing for the user to do
  const onDep = task({ state: 'backlog', blocked_on: { kind: 'dependency' } as any });
  assert.deepEqual(getTaskActions(onDep).primary, []);
  assert.ok(!taskNeedsYou(onDep));
});

test('review awaiting the user (or a gate) offers Approve and Request changes', () => {
  for (const t of [task({ state: 'in_review', requires_user_approval: true, attempt_no: 1 }), task({ state: 'in_review', kind: 'gate' })]) {
    assert.deepEqual(getTaskActions(t).primary, ['approve', 'request_changes']);
    assert.ok(taskNeedsYou(t));
  }
  // reviewed only by agents: the user just watches
  const agentReview = task({ state: 'in_review', attempt_no: 1 });
  assert.deepEqual(getTaskActions(agentReview).primary, []);
  assert.ok(!taskNeedsYou(agentReview));
});

test('running work has no primary action; hold and cancel live in More and there is no verify re-run', () => {
  const t = task({ state: 'in_progress', attempt_no: 2 });
  const { primary, more } = getTaskActions(t);
  assert.deepEqual(primary, []);
  assert.deepEqual(more, ['hold', 'cancel', 'copy_id']);
  // A legacy brief that still carries a verify command offers no re-run either.
  const legacy = getTaskActions(task({ state: 'in_review', attempt_no: 1, brief: { goal: 'g', acceptance: ['a'], verify: 'npm test' } as any }));
  assert.ok(!(legacy.more as string[]).includes('rerun_verify'));
  assert.ok(!(legacy.primary as string[]).includes('rerun_verify'));
});

test('finished tasks can only be reopened; gates are never cancelled from a card', () => {
  for (const state of ['done', 'cancelled']) {
    const { primary, more } = getTaskActions(task({ state }));
    assert.deepEqual(primary, []);
    assert.deepEqual(more, ['reopen', 'copy_id']);
    assert.ok(!taskNeedsYou(task({ state, publish_state: 'draft' })));
  }
  assert.ok(!getTaskActions(task({ kind: 'gate', state: 'in_review' })).more.includes('cancel'));
});

test('Re-check is offered where a task can look stuck, never on running work', () => {
  for (const state of ['backlog', 'ready', 'in_review']) {
    assert.ok(getTaskActions(task({ state })).more.includes('recheck'), state);
  }
  assert.ok(!canRecheck(task({ state: 'in_progress' })));
  assert.ok(!canRecheck(task({ state: 'ready', leases: [{ kind: 'work' }] as any })), 'a live work lease is left to its holder');
  assert.ok(canRecheck(task({ state: 'in_review', leases: [{ kind: 'review' }] as any })), 'a review lease does not hide the item');
  assert.ok(!canRecheck(task({ state: 'backlog', publish_state: 'draft' })), 'drafts are published, not re-checked');
  assert.ok(!canRecheck(task({ state: 'cancelled' })));
  assert.ok(!canRecheck(task({ state: 'done' })));
  assert.ok(!canRecheck(task({ state: 'done', merge: { state: 'merged' } } as any)));
  for (const merge of ['pending', 'failed']) {
    const { more } = getTaskActions(task({ state: 'done', merge: { state: merge } } as any));
    assert.deepEqual(more, ['reopen', 'recheck', 'copy_id'], `done with merge ${merge}`);
  }
});

test('the Re-check toast says what changed, else why the task still waits', () => {
  const changed = recheckToast({ changed: true, actions: ['state: in_review → done'], reasons: [], message: 'state: in_review → done' });
  assert.equal(changed.kind, 'success');
  assert.match(changed.title, /updated/);
  assert.equal(changed.message, 'state: in_review → done');
  const waiting = recheckToast({ changed: false, actions: [], reasons: ['agt_w: fleet full 2/2 on bridge br_1', 'agt_x: bridge br_2 is offline'], message: 'nothing to change: …' });
  assert.equal(waiting.kind, 'info');
  assert.match(waiting.title, /nothing to change/);
  assert.match(waiting.message, /fleet full 2\/2/);
  assert.match(waiting.message, /offline/);
  assert.ok(recheckToast({ changed: false, actions: [], reasons: [] }).message.length > 0);
});

test('the board puts tasks that need you first, then by state and priority', async () => {
  const { sortTasksForBoard } = await import('../src/ui/components/tasks/TicketBoardView.tsx');
  const order = sortTasksForBoard([
    task({ task_id: 'done', state: 'done' }),
    task({ task_id: 'ready_p2', state: 'ready', priority: 'p2' }),
    task({ task_id: 'ready_p0', state: 'ready', priority: 'p0' }),
    task({ task_id: 'running', state: 'in_progress' }),
    task({ task_id: 'needs_review', state: 'in_review', requires_user_approval: true }),
  ]).map((t) => t.task_id);
  assert.deepEqual(order, ['needs_review', 'running', 'ready_p0', 'ready_p2', 'done']);
});

test('the board groups open tasks into needs-you, in-progress, in-review and up-next sections', async () => {
  const { groupForBoard, sortTasksForBoard } = await import('../src/ui/components/tasks/TicketBoardView.tsx');
  const sorted = sortTasksForBoard([
    task({ task_id: 'done', state: 'done' }),
    task({ task_id: 'ready', state: 'ready' }),
    task({ task_id: 'backlog', state: 'backlog' }),
    task({ task_id: 'running', state: 'in_progress' }),
    task({ task_id: 'agent_review', state: 'in_review' }),
    task({ task_id: 'needs_review', state: 'in_review', requires_user_approval: true }),
    task({ task_id: 'draft', state: 'backlog', publish_state: 'draft' }),
  ]);
  const sections = groupForBoard(sorted).map((s: any) => [s.key, s.tasks.map((t: any) => t.task_id)]);
  assert.deepEqual(sections, [
    ['needs_you', ['needs_review', 'draft']],
    ['in_progress', ['running']],
    ['in_review', ['agent_review']],
    ['up_next', ['ready', 'backlog']],
  ]);
  // Finished tasks fold away unless they are the expanded one; empty sections are dropped.
  assert.deepEqual(groupForBoard(sorted, 'done').at(-1)?.tasks.map((t: any) => t.task_id), ['ready', 'backlog', 'done']);
  assert.deepEqual(groupForBoard([task({ task_id: 'r', state: 'ready' })]).map((s: any) => s.key), ['up_next']);
});

test('a draft says it is a draft; template stage titles never show raw placeholders', async () => {
  const { getTaskStatusLines } = await import('../src/ui/components/tasks/taskV2Types.ts');
  const [line1, line2] = getTaskStatusLines(task({ publish_state: 'draft', state: 'backlog' }));
  assert.equal(line1, 'Draft, not visible to agents until you publish it');
  assert.equal(line2, '');
  const { renderStageTitle } = await import('../src/ui/components/tasks/WorkflowPipelineView.tsx');
  assert.equal(renderStageTitle('Explore: {{inputs.goal}}', { goal: 'Add CSV export' }), 'Explore: Add CSV export');
  assert.equal(renderStageTitle('Build: {{item.title}}', {}), 'Build: each planned item');
  assert.ok(!renderStageTitle('X {{ something.else }}', {}).includes('{{'));
});

test('a chain row opens the chain-addressed coordinator chat, or the board when there is no coordinator', async () => {
  const { chainRowPrimaryAction } = await import('../src/ui/components/taskchain/TaskChainsPage.tsx');
  assert.deepEqual(chainRowPrimaryAction('chain_a', 'inst_coord1', false), {
    kind: 'conversation',
    href: '#/conversations/chain:chain_a?panel=tasks',
    closeSidebar: false,
  });
  // mobile keeps the plain conversation route and closes the sidebar
  assert.deepEqual(chainRowPrimaryAction('chain_a', 'inst_coord1', true), {
    kind: 'conversation',
    href: '#/conversations/chain:chain_a',
    closeSidebar: true,
  });
  assert.deepEqual(chainRowPrimaryAction('chain_a', '', false), { kind: 'select' });
  assert.deepEqual(chainRowPrimaryAction('chain_a', '  ', true), { kind: 'select' });
});

test('a held task offers Release up front and never Answer; open tasks offer Hold', () => {
  const held = task({ state: 'backlog', blocked_on: { kind: 'hold', reason: 're-route' } as any });
  assert.deepEqual(getTaskActions(held).primary, ['release']);
  assert.ok(!getTaskActions(held).more.includes('hold'));
  assert.ok(!taskNeedsYou(held), 'a hold is an operator pause, not a question for you');
  // A question paused by a hold cannot be answered (the hub refuses it).
  const pausedQ = task({ state: 'backlog', blocked_on: { kind: 'human', reason: 'Which DB?', hold: { kind: 'hold', reason: 're-route' } } as any });
  assert.deepEqual(getTaskActions(pausedQ).primary, ['release']);
  assert.ok(!taskNeedsYou(pausedQ));
  // A failed agent under a hold still needs you (Start agent, from its
  // attention card), but it is not a question: no Answer, Release instead.
  const agentDown = task({ state: 'backlog', blocked_on: { kind: 'agent_not_running', reason: 'exited', hold: { kind: 'hold', reason: 'x' } } as any });
  assert.ok(taskNeedsYou(agentDown));
  assert.deepEqual(getTaskActions(agentDown).primary, ['release']);
  // A held review awaiting you keeps Approve, and Release shows beside it.
  const heldReview = task({ state: 'in_review', requires_user_approval: true, blocked_on: { kind: 'hold', reason: 'x' } as any });
  assert.deepEqual(getTaskActions(heldReview).primary, ['approve', 'request_changes', 'release']);
  for (const t of [held, pausedQ, agentDown, heldReview]) assert.ok(!getTaskActions(t).more.includes('release'), 'Release is never tucked into More');

  assert.ok(canHold(task({ state: 'ready' })));
  assert.ok(canHold(task({ state: 'in_progress', leases: [{ kind: 'work' }] as any })), 'a leased task can be held (its holder checkpoints)');
  assert.ok(getTaskActions(task({ state: 'ready' })).more.includes('hold'));
  assert.ok(!canHold(held), 'already held');
  assert.ok(!canHold(task({ state: 'done' })));
  assert.ok(!canHold(task({ state: 'backlog', publish_state: 'draft' })));
  assert.ok(!canHold(task({ state: 'ready', kind: 'gate' })), 'gates cannot be held');
});

test('the board parks held tasks in a Held section last, unless they need you', async () => {
  const { groupForBoard, sortTasksForBoard } = await import('../src/ui/components/tasks/TicketBoardView.tsx');
  const sorted = sortTasksForBoard([
    task({ task_id: 'ready', state: 'ready' }),
    task({ task_id: 'held', state: 'backlog', blocked_on: { kind: 'hold', reason: 'x' } as any }),
    task({ task_id: 'held_running', state: 'in_progress', blocked_on: { kind: 'hold', reason: 'x', checkpoint_requested: true } as any }),
    task({ task_id: 'held_review', state: 'in_review', requires_user_approval: true, blocked_on: { kind: 'hold', reason: 'x' } as any }),
  ]);
  const sections = groupForBoard(sorted).map((s: any) => [s.key, s.tasks.map((t: any) => t.task_id).sort()]);
  assert.deepEqual(sections, [
    ['needs_you', ['held_review']],
    ['up_next', ['ready']],
    ['held', ['held', 'held_running']],
  ]);
});
