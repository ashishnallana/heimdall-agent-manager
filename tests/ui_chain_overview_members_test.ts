// Chain overview: each member's current ticket comes from the v2 task wire
// (state + leases), work and review alike; legacy status/assignee_ref are gone.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_chain_overview_members_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {
  attentionReason,
  buildMemberCurrentTaskMap,
  isAttentionNeeded,
  isOngoingTask,
  memberTicketText,
  reviewHolders,
} from '../src/ui/components/chat/chainMemberTickets.ts';
import type { TaskLeaseWire, TaskWire } from '../src/ui/api/taskWire.ts';

const REPO_ROOT = path.resolve(import.meta.dirname, '..');

function lease(holder: string, kind: 'work' | 'review', reviewRole = ''): TaskLeaseWire {
  return {
    lease_id: `lease_${holder}_${kind}`,
    kind,
    review_role: reviewRole,
    holder_instance_id: holder,
    attempt_no: 1,
    bridge_id: '',
    granted_at: '',
    confirmed_at: '',
    expires_at: '',
    hard_deadline_at: '',
    delivery: '',
  };
}

function makeTask(id: string, overrides: Partial<TaskWire> = {}): TaskWire {
  return {
    task_id: id,
    chain_id: 'chain-1',
    title: `Title ${id}`,
    publish_state: 'published',
    state: 'backlog',
    kind: 'task',
    priority: 'P2',
    attempt_no: 1,
    bridge_id: '',
    brief: null,
    blocked_on: null,
    requires_user_approval: false,
    ready_since: '',
    leases: [],
    ...overrides,
  } as TaskWire;
}

const workTask = makeTask('task-work', { state: 'in_progress', leases: [lease('inst-worker', 'work')] });
const reviewTask = makeTask('task-review', {
  state: 'in_review',
  brief: { review_roles: ['security', 'code'] } as any,
  leases: [lease('inst-sec', 'review', 'security'), lease('inst-code', 'review', 'code')],
});

test('buildMemberCurrentTaskMap maps work and review lease holders across members', () => {
  const map = buildMemberCurrentTaskMap([workTask, reviewTask, makeTask('task-idle', { state: 'ready' })]);
  assert.deepEqual([...map.keys()].sort(), ['inst-code', 'inst-sec', 'inst-worker']);
  assert.equal(map.get('inst-worker')?.task.task_id, 'task-work');
  assert.equal(map.get('inst-worker')?.kind, 'work');
  assert.equal(map.get('inst-worker')?.reviewRole, '');
  assert.equal(map.get('inst-sec')?.task.task_id, 'task-review');
  assert.equal(map.get('inst-sec')?.kind, 'review');
  assert.equal(map.get('inst-sec')?.reviewRole, 'security');
  assert.equal(map.get('inst-code')?.reviewRole, 'code');
  assert.equal(map.get('inst-nobody'), undefined);
});

test('buildMemberCurrentTaskMap ignores legacy fields and terminal tasks; work beats review', () => {
  const legacy = makeTask('task-legacy', { status: 'in_progress', assignee_ref: { agent_instance_id: 'inst-legacy' } });
  const done = makeTask('task-done', { state: 'done', leases: [lease('inst-done', 'work')] });
  const alsoReviewing = makeTask('task-other', { state: 'in_review', leases: [lease('inst-worker', 'review', 'code')] });
  const map = buildMemberCurrentTaskMap([alsoReviewing, legacy, done, workTask]);
  assert.equal(map.has('inst-legacy'), false);
  assert.equal(map.has('inst-done'), false);
  assert.equal(map.get('inst-worker')?.task.task_id, 'task-work');
  assert.equal(map.get('inst-worker')?.kind, 'work');
});

test('memberTicketText names work, review (with role) and no ticket', () => {
  const map = buildMemberCurrentTaskMap([workTask, reviewTask]);
  assert.equal(memberTicketText(map.get('inst-worker')), 'Title task-work');
  assert.equal(memberTicketText(map.get('inst-sec')), 'Reviewing: Title task-review (security)');
  assert.equal(memberTicketText(undefined), 'No ticket');
});

test('ongoing and attention helpers read v2 state, including in_review', () => {
  assert.equal(isOngoingTask(workTask), true);
  assert.equal(isOngoingTask(reviewTask), true);
  assert.equal(isOngoingTask(makeTask('t', { state: 'ready' })), false);
  assert.equal(isOngoingTask(makeTask('t', { status: 'in_progress' })), false, 'legacy status is not read');

  assert.equal(isAttentionNeeded(reviewTask), false, 'agent reviewers only: nothing on you');
  const onYou = makeTask('t-you', { state: 'in_review', requires_user_approval: true });
  assert.equal(isAttentionNeeded(onYou), true);
  assert.equal(attentionReason(onYou), 'Review required by you');
  const approved = makeTask('t-ok', {
    state: 'in_review',
    requires_user_approval: true,
    reviews: [{ reviewer: 'user', reviewer_kind: 'user', reviewer_instance_id: '', role: '', verdict: 'approve', created_at: '' }],
  });
  assert.equal(isAttentionNeeded(approved), false, 'you already approved');
  const noReviewer = makeTask('t-none', { state: 'in_review' });
  assert.equal(isAttentionNeeded(noReviewer), true);
  assert.equal(attentionReason(noReviewer), 'No reviewer assigned');
  assert.equal(isAttentionNeeded(makeTask('t-legacy', { status: 'validated_not_good' })), false);
  // Named reviewer only (brief.reviewers, no review_roles, no user gate).
  const named = makeTask('t-named', { state: 'in_review' });
  named.brief = { review_roles: [], reviewers: ['agt_reviewer'] } as TaskWire['brief'];
  assert.equal(isAttentionNeeded(named), false, 'named reviewer: not on you');
  assert.equal(attentionReason(named), 'Review required by you', 'named reviewer: not unassigned');
  const namedLive = { ...named, task_id: 't-named-live', leases: [lease('inst-named', 'review')] };
  assert.equal(isAttentionNeeded(namedLive), false, 'named reviewer holding its lease: not on you');
  assert.equal(attentionReason(namedLive), 'Review required by you');
  const leaseOnly = makeTask('t-lease', { state: 'in_review', leases: [lease('inst-r', 'review')] });
  assert.equal(isAttentionNeeded(leaseOnly), false, 'a live review lease means someone is reviewing');

  assert.deepEqual(reviewHolders(reviewTask), ['inst-sec', 'inst-code']);
  assert.deepEqual(reviewHolders(workTask), []);
});

test('ChainOverviewPanel shows each member\'s ticket from leases: work title, Reviewing (role), No ticket', async () => {
  const React = (await import('react')).default;
  const { Provider } = await import('react-redux');
  const { renderToStaticMarkup } = await import('react-dom/server');
  const { makeVaultStore } = await import('./helpers/vaultEndpointHarness.ts');
  const { tasksApi } = await import('../src/ui/api/endpoints/tasks.ts');
  const ChainOverviewPanel = (await import('../src/ui/components/chat/ChainOverviewPanel.tsx')).default;

  const store = await makeVaultStore();
  const members = ['inst-worker', 'inst-sec', 'inst-idle'].map((id) => ({
    agent_instance_id: id,
    display_name: `Agent ${id}`,
    runtime_status: 'running',
  }));
  await store.dispatch(
    tasksApi.util.upsertQueryData('fetchTaskChainDetail', { chainId: 'chain-1' }, {
      chain: { chain_id: 'chain-1', members, tasks: [workTask, reviewTask] },
    }),
  );
  const html = renderToStaticMarkup(
    React.createElement(Provider, {
      store,
      children: React.createElement(ChainOverviewPanel, { chainId: 'chain-1', projectId: '', projectVcsEnabled: false }),
    }),
  );
  store.dispatch(tasksApi.util.resetApiState());

  const ticketCell = (inst: string) => {
    const at = html.indexOf(`data-debug-id="chain-overview-agent-ticket-${inst}"`);
    assert.ok(at >= 0, `ticket cell for ${inst}`);
    return html.slice(at, html.indexOf('</span></span>', at) + 14);
  };
  assert.match(ticketCell('inst-worker'), /Title task-work/);
  assert.doesNotMatch(ticketCell('inst-worker'), /Reviewing/);
  assert.match(ticketCell('inst-sec'), /title="Reviewing: Title task-review \(security\)"/);
  assert.match(ticketCell('inst-sec'), />Reviewing: <\/span>/);
  assert.match(ticketCell('inst-sec'), /\(security\)/);
  assert.match(ticketCell('inst-idle'), /No ticket/);
  // Both leased tasks count as ongoing, the in_review one under its v2 label.
  assert.match(html, /Ongoing Tasks \(<!-- -->2<!-- -->\)|Ongoing Tasks \(2\)/);
  assert.match(html, /data-debug-id="chain-overview-ongoing-task-task-review"/);
  assert.match(html, />In review</);
});

test('ChainOverviewPanel no longer reads legacy status or assignee_ref for members/ongoing', () => {
  const src = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/chat/ChainOverviewPanel.tsx'), 'utf8');
  for (const legacy of [/\bt\.status\b/, /\bt\.assignee_ref\b/, /\btask\.status\b/]) {
    assert.ok(!legacy.test(src), `ChainOverviewPanel.tsx still reads ${legacy}`);
  }
});
