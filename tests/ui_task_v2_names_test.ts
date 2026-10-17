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
  GENERIC_AGENT_LABEL,
} from '../src/ui/components/tasks/taskNames.ts';
import { describeTaskEvent, EXPIRE_REASON_TEXT } from '../src/ui/components/tasks/taskEvents.ts';
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
  assert.equal(names.task('task_missing'), 'Untitled task');
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
