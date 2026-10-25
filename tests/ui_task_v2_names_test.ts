// Task System v2 UI: human-readable names instead of raw ids (plan REQ-UI-4).
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_task_v2_names_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {
  buildTaskNames,
  instanceAgentsFromEvents,
  readableAgentFallback,
  withInstanceAgents,
  participantLabel,
  unknownReviewerLabel,
  GENERIC_AGENT_LABEL,
} from '../src/ui/components/tasks/taskNames.ts';
import { describeTaskEvent, EXPIRE_REASON_TEXT, reviewsPostedForAttempt, whoById } from '../src/ui/components/tasks/taskEvents.ts';
import { reviewParticipantIds, reviewVotes, voteFor } from '../src/ui/components/tasks/taskActions.ts';
import { getTaskBadges, getTaskStatusLines } from '../src/ui/components/tasks/taskV2Types.ts';
import type { TaskWire } from '../src/ui/api/taskWire.ts';

const REPO_ROOT = path.resolve(import.meta.dirname, '..');
const EVENTS_ODIN = fs.readFileSync(path.join(REPO_ROOT, 'src/hub/service/taskv2/events.odin'), 'utf8');

function odinConstants(prefix: string): string[] {
  const re = new RegExp(`^\\s*${prefix}[A-Z_]+\\s*::\\s*"([a-z_]+)"`, 'gm');
  return Array.from(EVENTS_ODIN.matchAll(re), (m) => m[1]);
}

const RAW_ID = /\b(task|inst|agt|brg|chain)_[0-9a-z]{6,}/;

const names = buildTaskNames({
  tasks: [
    { task_id: 'task_aaa111', title: 'Add refresh_tokens table' },
    { task_id: 'task_bbb222', title: 'Rotate refresh token' },
  ],
  members: [
    { agentInstanceId: 'inst_coord01', agentId: 'agt_18df0000aaaa1111', displayName: 'soloist #20' },
    { agentInstanceId: 'inst_member02', agentId: 'agt_18df385deeb91f7c', displayName: '' },
  ],
  bridges: [{ id: 'brg_dawn01', name: 'dawnstar' }],
  identities: [
    { agent_id: 'agt_18df385deeb91f7c', name: 'Backend Dev' },
    { agent_id: 'agt_18df385df494b971', name: 'Security Reviewer' },
  ],
});

test('buildTaskNames resolves titles, agents, bridges and member instances', () => {
  assert.equal(names.task('task_bbb222'), 'Rotate refresh token');
  assert.equal(names.task('task_missing'), 'Untitled ticket');
  assert.equal(names.agent('agt_18df385deeb91f7c'), 'Backend Dev');
  assert.equal(names.bridge('brg_dawn01'), 'dawnstar');
  assert.equal(names.bridge('brg_gone'), 'unknown bridge');
  // holder chain: member display name, then member agent → identity name
  assert.equal(names.instance('inst_coord01'), 'soloist #20');
  assert.equal(names.instance('inst_member02'), 'Backend Dev');
  // unknown instance → null so <HolderName> fetches it
  assert.equal(names.instance('inst_fleet99'), null);
});

test('agent fallback never shows a generated id', () => {
  assert.equal(readableAgentFallback('agt_18df385deeb91f7c'), GENERIC_AGENT_LABEL);
  assert.equal(readableAgentFallback('agt_backend-dev'), 'Backend dev');
  assert.equal(readableAgentFallback('reviewer'), 'Reviewer');
  assert.equal(names.agent('agt_18df9999ffff0000'), GENERIC_AGENT_LABEL);
});

test('lease_granted events add instance → agent facts (holder chain step 4)', () => {
  const facts = instanceAgentsFromEvents([
    { kind: 'lease_granted', payload: { instance_id: 'inst_fleet99', agent_id: 'agt_18df385df494b971' } },
    { kind: 'published', payload: {} },
  ]);
  assert.deepEqual(facts, { inst_fleet99: 'agt_18df385df494b971' });
  const enriched = withInstanceAgents(names, facts);
  assert.equal(enriched.instance('inst_fleet99'), 'Security Reviewer');
  // an agent without a readable name stays unresolved so the component can fetch it
  assert.equal(withInstanceAgents(names, { inst_x: 'agt_18df0000ffff9999' }).instance('inst_x'), null);
});

test('describeTaskEvent has a sentence for every event kind in events.odin', () => {
  const kinds = odinConstants('EV_');
  assert.ok(kinds.length >= 29, `parsed ${kinds.length} EV_* kinds`);
  for (const kind of kinds) {
    const d = describeTaskEvent({ kind, actor_kind: 'user', payload: {} }, names);
    assert.ok(d.known, `no sentence for event kind "${kind}"`);
    assert.ok(!d.text.includes('_'), `"${kind}" sentence leaks a raw key: ${d.text}`);
  }
  assert.equal(describeTaskEvent({ kind: 'brand_new_kind' }, names).known, false);
});

test('describeTaskEvent explains every lease-expiry reason in events.odin', () => {
  const reasons = odinConstants('EXPIRE_');
  assert.ok(reasons.length >= 11, `parsed ${reasons.length} EXPIRE_* reasons`);
  for (const reason of reasons) {
    assert.ok(EXPIRE_REASON_TEXT[reason], `no text for expiry reason "${reason}"`);
    const d = describeTaskEvent({ kind: 'lease_expired', payload: { kind: 'work', attempt_no: 2, reason } }, names);
    assert.ok(d.text.includes(EXPIRE_REASON_TEXT[reason]), d.text);
  }
});

test('a legacy verify submission is read-only history tied to its attempt (D2)', () => {
  const skipped = describeTaskEvent({ kind: 'submitted', payload: { attempt_no: 2, skip_verify_reason: 'Runner unavailable' } }, names);
  assert.match(skipped.text, /attempt 2/);
  assert.doesNotMatch(skipped.text, /verif/i);
  assert.deepEqual(skipped.legacyVerify, { auto: false, skipReason: 'Runner unavailable' });
  const auto = describeTaskEvent({ kind: 'submitted', payload: { attempt_no: 1, auto: true } }, names);
  assert.doesNotMatch(auto.text, /verif/i, 'no "Verify passed" sentence for an old auto-submit');
  assert.deepEqual(auto.legacyVerify, { auto: true, skipReason: '' });
  assert.equal(describeTaskEvent({ kind: 'submitted', payload: {} }, names).legacyVerify, undefined);
});

// ---- REQ-TV2-6: one reviewer/participant resolver ---------------------------

test('participant resolver: agt_, inst_ and user ids name the durable agent', () => {
  const facts = withInstanceAgents(names, { inst_rev01: 'agt_18df385df494b971' });
  assert.equal(facts.participant('agt_18df385df494b971'), 'Security Reviewer');
  // An instance resolves to its durable agent's name (member → lease fact → identity).
  assert.equal(facts.participant('inst_rev01'), 'Security Reviewer');
  assert.equal(facts.participant('inst_member02'), 'Backend Dev');
  assert.equal(facts.durableId('inst_rev01'), 'agt_18df385df494b971');
  assert.equal(facts.durableId('agt_18df385df494b971'), 'agt_18df385df494b971');
  assert.equal(facts.participant('user'), 'you');
  // A member whose agent has no readable name keeps its member display name.
  assert.equal(facts.participant('inst_coord01'), 'soloist #20');
  // An agents/instances lookup names a stopped instance that is not a member.
  const withLookup = buildTaskNames({
    identities: [{ agent_id: 'agt_18df385df494b971', name: 'Security Reviewer' }],
    instances: [{ agent_instance_id: 'inst_stopped9', agent_id: 'agt_18df385df494b971' }],
  });
  assert.equal(withLookup.participant('inst_stopped9'), 'Security Reviewer');
});

test('participant resolver: an unknown id gets the explicit fallback, never "Inst <hex>" or "An agent"', () => {
  assert.equal(names.participant('inst_ffff00001111'), null);
  assert.equal(participantLabel(names, 'inst_ffff00001111'), 'Unknown reviewer (inst_ffff00001111)');
  assert.equal(participantLabel(names, 'agt_18df9999ffff0000'), 'Unknown reviewer (agt_18df9999ffff0000)');
  assert.equal(unknownReviewerLabel('inst_x'), 'Unknown reviewer (inst_x)');
  for (const id of ['inst_ffff00001111', 'agt_18df9999ffff0000']) {
    const who = whoById(id, names);
    assert.equal(who, `Unknown reviewer (${id})`);
    assert.doesNotMatch(who, /^(Inst [0-9a-f]+|An agent|)$/);
  }
  assert.equal(whoById('user', names), 'You');
});

test('review events name the reviewer by durable id, then instance id', () => {
  const facts = withInstanceAgents(names, { inst_rev01: 'agt_18df385df494b971' });
  // Both ids on the payload (backend contract): the durable agent id wins.
  const both = describeTaskEvent({ kind: 'review_posted', payload: { reviewer_agent_id: 'agt_18df385df494b971', reviewer_instance_id: 'inst_rev01', verdict: 'approve' } }, names);
  assert.equal(both.text, 'Security Reviewer approved');
  // A legacy row carrying only an instance id still names the agent.
  const legacy = describeTaskEvent({ kind: 'changes_requested', payload: { reviewer: 'inst_rev01', attempt_no: 1 } }, facts);
  assert.equal(legacy.text, 'Security Reviewer requested changes (attempt 1)');
  const unknown = describeTaskEvent({ kind: 'review_posted', payload: { reviewer_instance_id: 'inst_ghost42', verdict: 'approve' } }, names);
  assert.equal(unknown.text, 'Unknown reviewer (inst_ghost42) approved');
  const posted = reviewsPostedForAttempt([{ kind: 'review_posted', payload: { attempt_no: 1, reviewer_agent_id: 'agt_18df385df494b971', reviewer: 'inst_rev01', summary: 'ok' } }], 1);
  assert.equal(posted[0].reviewer, 'agt_18df385df494b971');
});

test('votes match assignments by durable agent id, even when either side carries an instance id', () => {
  const facts = withInstanceAgents(names, { inst_rev01: 'agt_18df385df494b971' });
  // Vote row with both ids; assignment carries the instance id (legacy).
  const t1 = { reviews: [{ reviewer: 'agt_18df385df494b971', reviewer_instance_id: 'inst_rev01', verdict: 'approve' }] } as unknown as TaskWire;
  const v1 = reviewVotes(t1, facts);
  assert.equal(voteFor(v1, 'inst_rev01', facts), 'approve');
  assert.equal(voteFor(v1, 'agt_18df385df494b971', facts), 'approve');
  assert.deepEqual(Array.from(v1.keys()), ['agt_18df385df494b971'], 'one entry per durable reviewer');
  // Even without an instance fact, the row's own reviewer_instance_id matches.
  assert.equal(voteFor(reviewVotes(t1, names), 'inst_rev01', names), 'approve');
  // Legacy vote row keyed by instance id; assignment is the agent id.
  const t2 = { reviews: [{ reviewer: 'inst_rev01', verdict: 'request_changes' }] } as unknown as TaskWire;
  const v2 = reviewVotes(t2, facts);
  assert.equal(voteFor(v2, 'agt_18df385df494b971', facts), 'request_changes');
  assert.deepEqual(Array.from(v2.keys()), ['agt_18df385df494b971']);
  // request_changes on any role wins over an approve on another.
  const t3 = { reviews: [
    { reviewer: 'agt_18df385df494b971', role: 'a', verdict: 'approve' },
    { reviewer: 'inst_rev01', role: 'b', verdict: 'request_changes' },
  ] } as unknown as TaskWire;
  assert.equal(voteFor(reviewVotes(t3, facts), 'agt_18df385df494b971', facts), 'request_changes');
});

test('task details: an instance-id reviewer shows the agent name with its vote; an unknown id shows the fallback', async () => {
  const React = (await import('react')).default;
  const { Provider } = await import('react-redux');
  const { renderToStaticMarkup } = await import('react-dom/server');
  const { makeVaultStore } = await import('./helpers/vaultEndpointHarness.ts');
  const { tasksApi } = await import('../src/ui/api/endpoints/tasks.ts');
  const { TaskDetails } = await import('../src/ui/components/tasks/TaskDetails.tsx');

  const store = await makeVaultStore();
  const chainId = 'chain_rev';
  const taskId = 'task_rev';
  // The reviewer instance is not a chain member; its lease_granted fact names its agent.
  await store.dispatch(tasksApi.util.upsertQueryData('fetchTaskEvents', { chainId, taskId }, {
    events: [{ event_id: 1, kind: 'lease_granted', actor_kind: 'hub', ts_ms: 1, payload: { kind: 'review', instance_id: 'inst_rev01', agent_id: 'agt_18df385df494b971', attempt_no: 1 } }],
  }));
  const task = {
    task_id: taskId,
    chain_id: chainId,
    title: 'Review me',
    state: 'in_review',
    attempt_no: 1,
    // Legacy assignment rows carry instance ids.
    brief: { goal: 'g', acceptance: ['a'], reviewers: ['inst_rev01', 'inst_ghost42'] },
    reviews: [{ reviewer: 'agt_18df385df494b971', reviewer_kind: 'agent', reviewer_instance_id: 'inst_rev01', role: 'named', verdict: 'approve', created_at: '' }],
  } as unknown as TaskWire;
  const html = renderToStaticMarkup(
    React.createElement(Provider, { store, children: React.createElement(TaskDetails, { chainId, task, actions: { busy: false } as any, names }) }),
  );
  store.dispatch(tasksApi.util.resetApiState());

  const row = (id: string) => {
    const m = html.match(new RegExp(`<span data-debug-id="task-detail-reviewer-vote-${id}"[^>]*title="([^"]*)"[^>]*>([\\s\\S]*?)</span>(?=<|$)`));
    return m ? { title: m[1], body: m[2] } : null;
  };
  const named = row('inst_rev01');
  assert.ok(named, 'instance-id reviewer row renders');
  assert.equal(named.title, 'Security Reviewer: approved', 'agent name and its vote on its own row');
  const ghost = row('inst_ghost42');
  assert.ok(ghost, 'unknown reviewer row renders');
  assert.equal(ghost.title, 'Unknown reviewer (inst_ghost42): waiting for review');
  // The approving agent is not listed a second time as an "extra" voter.
  assert.equal((html.match(/task-detail-reviewer-vote-/g) || []).length, 2);
  assert.doesNotMatch(html, /An agent|Inst [0-9a-f]{4,}/);
});

test('superseded (D1) approvals are history, not current votes', () => {
  const legacy = { reviewer: 'agt_18df385df494b971', reviewer_kind: 'agent', reviewer_instance_id: 'inst_rev01', role: 'legacy-verify:named', verdict: 'approve' };
  // Only the superseded row: the reviewer still owes a fresh review.
  const only = reviewVotes({ reviews: [legacy] } as unknown as TaskWire, names);
  assert.equal(only.size, 0);
  assert.equal(voteFor(only, 'agt_18df385df494b971', names), undefined);
  assert.equal(voteFor(only, 'inst_rev01', names), undefined, 'its instance id is no alias either');
  // A fresh review next to its historical row decides on its own.
  const fresh = (verdict: string) =>
    reviewVotes({ reviews: [legacy, { ...legacy, reviewer_instance_id: 'inst_rev02', role: 'named', verdict }] } as unknown as TaskWire, names);
  assert.equal(voteFor(fresh('request_changes'), 'agt_18df385df494b971', names), 'request_changes');
  const approved = fresh('approve');
  assert.equal(voteFor(approved, 'agt_18df385df494b971', names), 'approve');
  assert.deepEqual(Array.from(approved.keys()), ['agt_18df385df494b971']);
  assert.equal(voteFor(approved, 'inst_rev01', names), undefined, 'the superseded row adds no alias');
  assert.deepEqual(reviewParticipantIds({ reviews: [legacy] } as unknown as TaskWire, ['agt_x']), ['agt_x']);
});

async function renderReviewDetails(task: TaskWire, seed: (store: any) => Promise<void> | void) {
  const React = (await import('react')).default;
  const { Provider } = await import('react-redux');
  const { renderToStaticMarkup } = await import('react-dom/server');
  const { makeVaultStore } = await import('./helpers/vaultEndpointHarness.ts');
  const { tasksApi } = await import('../src/ui/api/endpoints/tasks.ts');
  const { TaskDetails } = await import('../src/ui/components/tasks/TaskDetails.tsx');
  const store = await makeVaultStore();
  await store.dispatch(tasksApi.util.upsertQueryData('fetchTaskEvents', { chainId: task.chain_id, taskId: task.task_id }, { events: [] }));
  await seed(store);
  const html = renderToStaticMarkup(
    React.createElement(Provider, { store, children: React.createElement(TaskDetails, { chainId: task.chain_id, task, actions: { busy: false } as any, names }) }),
  );
  store.dispatch(tasksApi.util.resetApiState());
  return html;
}

function reviewerRowTitles(html: string): string[] {
  return Array.from(html.matchAll(/data-debug-id="task-detail-reviewer-vote-[^"]*"[^>]*title="([^"]*)"/g), (m) => m[1]);
}

test('task details: a superseded-only approval leaves the reviewer waiting', async () => {
  const task = {
    task_id: 'task_d1',
    chain_id: 'chain_d1',
    title: 'Superseded',
    state: 'in_review',
    attempt_no: 1,
    requires_user_approval: true,
    brief: { goal: 'g', acceptance: ['a'], reviewers: ['agt_18df385df494b971'] },
    reviews: [
      { reviewer: 'agt_18df385df494b971', reviewer_kind: 'agent', reviewer_instance_id: 'inst_rev01', role: 'legacy-verify:named', verdict: 'approve', created_at: '' },
      { reviewer: 'user', reviewer_kind: 'user', reviewer_instance_id: '', role: 'user', verdict: 'approve', created_at: '' },
    ],
  } as unknown as TaskWire;
  const html = await renderReviewDetails(task, () => {});
  assert.deepEqual(reviewerRowTitles(html), ['Security Reviewer: waiting for review', 'you: approved']);
  assert.match(html, /waiting on Security Reviewer/);
});

test('task details: a stopped-instance assignment matches the fresh vote of its looked-up agent', async () => {
  const { agentsApi } = await import('../src/ui/api/endpoints/agents.ts');
  const task = {
    task_id: 'task_old',
    chain_id: 'chain_old',
    title: 'Stopped reviewer',
    state: 'in_review',
    attempt_no: 1,
    requires_user_approval: true,
    // Legacy assignment: a stopped instance no member or lease fact maps.
    brief: { goal: 'g', acceptance: ['a'], reviewers: ['inst_old77'] },
    reviews: [
      { reviewer: 'agt_18df385df494b971', reviewer_kind: 'agent', reviewer_instance_id: 'inst_new88', role: 'named', verdict: 'approve', created_at: '' },
      { reviewer: 'user', reviewer_kind: 'user', reviewer_instance_id: '', role: 'user', verdict: 'approve', created_at: '' },
    ],
  } as unknown as TaskWire;
  const html = await renderReviewDetails(task, async (store) => {
    await store.dispatch(agentsApi.util.upsertQueryData('fetchAgentInstance', { instanceId: 'inst_old77' }, { instance: { agent_instance_id: 'inst_old77', agent_id: 'agt_18df385df494b971', status: 'stopped' } }));
  });
  // One approved row for the reviewer (no duplicate extra voter), nobody pending.
  assert.deepEqual(reviewerRowTitles(html), ['Security Reviewer: approved', 'you: approved']);
  assert.doesNotMatch(html, /waiting on/);
});

test('timeline sentences use names, never raw ids', () => {
  const granted = describeTaskEvent(
    { kind: 'lease_granted', actor_kind: 'hub', payload: { kind: 'work', instance_id: 'inst_member02', agent_id: 'agt_18df385deeb91f7c', bridge_id: 'brg_dawn01', attempt_no: 1 } },
    names,
  ).text;
  assert.equal(granted, 'Assigned to Backend Dev on dawnstar (attempt 1)');
  const dep = describeTaskEvent({ kind: 'dep_added', actor_kind: 'user', payload: { depends_on: 'task_aaa111' } }, names).text;
  assert.equal(dep, 'Now waits for "Add refresh_tokens table"');
  const review = describeTaskEvent(
    { kind: 'review_posted', actor_kind: 'agent', actor_id: 'inst_member02', payload: { reviewer: 'agt_18df385df494b971', verdict: 'approve', role: 'security' } },
    names,
  ).text;
  assert.equal(review, 'Security Reviewer approved (security review)');
  for (const t of [granted, review]) assert.ok(!RAW_ID.test(t), t);
});

test('badges and status lines name the holder, bridge and dependencies', () => {
  const now = Date.parse('2026-10-17T05:00:00Z');
  const running = {
    task_id: 'task_ccc333',
    chain_id: 'chain_x',
    title: 'Running',
    state: 'in_progress',
    attempt_no: 1,
    bridge_id: 'brg_dawn01',
    leases: [{ kind: 'work', holder_instance_id: 'inst_member02', bridge_id: 'brg_dawn01', expires_at: '2026-10-17T05:12:00Z' }],
  } as unknown as TaskWire;
  const labels = getTaskBadges(running, [], now, names).map((b) => b.label);
  assert.ok(labels.includes('Backend Dev · 12m left'), labels.join(' | '));
  assert.ok(labels.includes('dawnstar'), labels.join(' | '));
  for (const l of labels) assert.ok(!RAW_ID.test(l), l);

  const waiting = { task_id: 'task_ddd444', chain_id: 'chain_x', title: 'Waits', state: 'backlog', depends_on: ['task_aaa111'] } as unknown as TaskWire;
  const [, line2] = getTaskStatusLines(waiting, [], now, names);
  assert.equal(line2, 'needs "Add refresh_tokens table"');
});

test('the in-progress sentence names the holder and never prints an instance id', () => {
  const now = Date.parse('2026-10-17T05:00:00Z');
  const running = (holder: string) =>
    ({
      task_id: 'task_run',
      chain_id: 'chain_x',
      title: 'Running',
      state: 'in_progress',
      attempt_no: 2,
      leases: [{ kind: 'work', holder_instance_id: holder, expires_at: '2026-10-17T05:12:00Z', hard_deadline_at: '2026-10-17T05:40:00Z' }],
    }) as unknown as TaskWire;
  const [named, detail] = getTaskStatusLines(running('inst_member02'), [], now, names);
  assert.equal(named, 'Backend Dev is working, 12m left');
  assert.equal(detail, 'attempt 2 of 5 · hard limit in 40m');
  const [unknown] = getTaskStatusLines(running('inst_fleet99'), [], now, names);
  assert.equal(unknown, 'An agent is working, 12m left');
  for (const line of [named, detail, unknown]) assert.ok(!RAW_ID.test(line), line);
});

test('badges carry a kind, and "Blocked on you" only for a human blocker', () => {
  const now = Date.parse('2026-10-17T05:00:00Z');
  const base = { task_id: 't', chain_id: 'c', title: 'T', state: 'backlog', attempt_no: 3, bridge_id: 'brg_dawn01' } as any;
  const onYou = getTaskBadges({ ...base, blocked_on: { kind: 'human', reason: 'Which DB?' } } as TaskWire, [], now, names);
  assert.ok(onYou.some((b) => b.kind === 'blocked' && b.label === 'Blocked on you' && b.tone === 'danger'));
  const onTask = getTaskBadges({ ...base, blocked_on: { kind: 'task_output' } } as TaskWire, [], now, names);
  assert.ok(onTask.some((b) => b.kind === 'blocked' && b.label === 'Blocked: waiting on task output' && b.tone === 'warn'));
  assert.ok(onTask.some((b) => b.kind === 'bridge' && b.label === 'dawnstar'));
  assert.ok(onTask.some((b) => b.kind === 'attempt'));
  for (const b of [...onYou, ...onTask]) assert.ok(b.kind, `badge without kind: ${b.label}`);
});

test('holder and time left come from the work lease even when a review lease is listed first', () => {
  const now = Date.parse('2026-10-17T05:00:00Z');
  const t = {
    task_id: 'task_mix',
    chain_id: 'chain_x',
    title: 'Mixed leases',
    state: 'in_progress',
    attempt_no: 1,
    leases: [
      { kind: 'review', holder_instance_id: 'inst_coord01', expires_at: '2026-10-17T05:03:00Z' },
      { kind: 'work', holder_instance_id: 'inst_member02', expires_at: '2026-10-17T05:20:00Z', hard_deadline_at: '2026-10-17T05:50:00Z' },
    ],
  } as unknown as TaskWire;
  assert.equal(getTaskStatusLines(t, [], now, names)[0], 'Backend Dev is working, 20m left');
  assert.ok(getTaskBadges(t, [], now, names).some((b) => b.kind === 'lease' && b.label === 'Backend Dev · 20m left'));
});
