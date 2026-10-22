// Agent blockers (REQ-EXT-BLK-1..5, UI): snapshot normalisation, the realtime
// summary, the revision-guarded reducer (stale snapshots ignored, locally
// answered blockers hidden until the bridge drops them, cleared on stop), the
// card view (Allow / Deny only for permission blockers while running) and the
// API / realtime wiring.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_extension_blockers_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

import {
  AGENT_BLOCKERS_CHANGE,
  blockerCardView,
  blockersNeedRefetch,
  blockersRealtimeFromSummary,
  blockersReducer,
  initialBlockersState,
  instanceCanBeBlocked,
  instanceCanDecide,
  normalizeBlocker,
  normalizeBlockersSnapshot,
  visibleBlockers,
  type AgentBlockersSnapshot,
} from '../src/ui/components/extension/blockersModel.ts';

const NOW = Date.parse('2026-10-22T07:00:00Z');

function perm(id: string, extra: Record<string, unknown> = {}) {
  return {
    blocker_id: id, kind: 'permission', provider: 'claude', tool_name: 'Bash', summary: 'Bash: rm -rf build',
    input: { command: 'rm -rf build' }, agent_id: '', created_at: '2026-10-22T06:59:00Z', expires_at: '2026-10-22T07:05:00Z', ...extra,
  };
}

function snap(revision: number, blockers: any[], instance = 'inst_1'): AgentBlockersSnapshot {
  return normalizeBlockersSnapshot({ agent_instance_id: instance, revision, blockers }, instance);
}

test('snapshot normalisation keeps known kinds, sorts by creation and drops terminal deadlines', () => {
  const s = normalizeBlockersSnapshot({
    agent_instance_id: 'inst_1', revision: '42',
    blockers: [
      perm('b2', { created_at: '2026-10-22T06:59:30Z' }),
      { kind: 'permission' },
      { blocker_id: 'x', kind: 'weird' },
      { blocker_id: 'term_inst_1', kind: 'terminal_prompt', summary: 'Waiting for input in terminal', expires_at: 'ignored' },
      perm('b1', { input: [1, 2] }),
    ],
  });
  assert.equal(s.revision, 42);
  // terminal_prompt has no created_at here, so it sorts first.
  assert.deepEqual(s.blockers.map((b) => b.blocker_id), ['term_inst_1', 'b1', 'b2']);
  const term = s.blockers.find((b) => b.kind === 'terminal_prompt')!;
  assert.equal(term.expires_at, '');
  assert.deepEqual(s.blockers.find((b) => b.blocker_id === 'b1')!.input, {});
  assert.equal(normalizeBlocker(null), null);
  assert.equal(normalizeBlockersSnapshot(null, 'inst_9').agent_instance_id, 'inst_9');
  assert.deepEqual(normalizeBlockersSnapshot(undefined).blockers, []);
});

test('realtime summary parsing and the refetch rule', () => {
  assert.equal(AGENT_BLOCKERS_CHANGE, 'agent_blockers_changed');
  const f = blockersRealtimeFromSummary({ agent_instance_id: 'inst_1', revision: 7, count: 2 });
  assert.deepEqual(f, { agent_instance_id: 'inst_1', revision: 7, count: 2 });
  assert.equal(blockersRealtimeFromSummary({ revision: 1 }, 'inst_2')?.agent_instance_id, 'inst_2');
  assert.equal(blockersRealtimeFromSummary({ revision: 1 }), null);
  const state = blockersReducer(initialBlockersState('inst_1'), { type: 'loaded', snapshot: snap(7, [perm('b1'), perm('b2')]) });
  assert.equal(blockersNeedRefetch(state, { revision: 7, count: 2 }), false);
  assert.equal(blockersNeedRefetch(state, { revision: 8, count: 2 }), true);
  assert.equal(blockersNeedRefetch(state, { revision: 7, count: 0 }), true);
});

test('reducer: a newer snapshot replaces the list, an older one is ignored', () => {
  let s = blockersReducer(initialBlockersState('inst_1'), { type: 'loaded', snapshot: snap(10, [perm('b1')]) });
  assert.equal(s.revision, 10);
  s = blockersReducer(s, { type: 'loaded', snapshot: snap(12, [perm('b1'), perm('b2', { created_at: '2026-10-22T06:59:30Z' })]) });
  assert.deepEqual(visibleBlockers(s).map((b) => b.blocker_id), ['b1', 'b2']);
  // A slow fetch of revision 11 lands after 12: ignored.
  const stale = blockersReducer(s, { type: 'loaded', snapshot: snap(11, []) });
  assert.equal(stale, s);
  // Another instance's snapshot never lands here.
  assert.equal(blockersReducer(s, { type: 'loaded', snapshot: snap(99, [], 'inst_other') }), s);
  // After a bridge restart the rebuilt list arrives with a larger revision.
  s = blockersReducer(s, { type: 'loaded', snapshot: snap(1_800_000_000_000, [perm('b2')]) });
  assert.deepEqual(visibleBlockers(s).map((b) => b.blocker_id), ['b2']);
});

test('reducer: Allow hides the blocker until the bridge snapshot drops it', () => {
  let s = blockersReducer(initialBlockersState('inst_1'), { type: 'loaded', snapshot: snap(5, [perm('b1'), perm('b2')]) });
  s = blockersReducer(s, { type: 'decision_started', id: 'b1', decision: 'allow' });
  assert.equal(s.submitting.b1, 'allow');
  s = blockersReducer(s, { type: 'decision_succeeded', id: 'b1' });
  assert.equal(s.submitting.b1, undefined);
  assert.deepEqual(visibleBlockers(s).map((b) => b.blocker_id), ['b2']);
  // The hub still lists it (snapshot lag): stays hidden.
  s = blockersReducer(s, { type: 'loaded', snapshot: snap(5, [perm('b1'), perm('b2')]) });
  assert.deepEqual(visibleBlockers(s).map((b) => b.blocker_id), ['b2']);
  // The bridge dropped it: forgotten, so a later re-registration would show again.
  s = blockersReducer(s, { type: 'loaded', snapshot: snap(6, [perm('b2')]) });
  assert.deepEqual(s.resolved, {});
});

test('reducer: a failed decision keeps the card with an error', () => {
  let s = blockersReducer(initialBlockersState('inst_1'), { type: 'loaded', snapshot: snap(5, [perm('b1')]) });
  s = blockersReducer(s, { type: 'decision_started', id: 'b1', decision: 'deny' });
  s = blockersReducer(s, { type: 'decision_failed', id: 'b1', error: 'bridge offline' });
  assert.equal(s.errors.b1, 'bridge offline');
  assert.deepEqual(visibleBlockers(s).map((b) => b.blocker_id), ['b1']);
  s = blockersReducer(s, { type: 'decision_started', id: 'b1', decision: 'deny' });
  assert.equal(s.errors.b1, undefined);
});

test('reducer: the list is cleared when the instance stops', () => {
  let s = blockersReducer(initialBlockersState('inst_1'), { type: 'loaded', snapshot: snap(5, [perm('b1')]) });
  s = blockersReducer(s, { type: 'decision_started', id: 'b1', decision: 'allow' });
  s = blockersReducer(s, { type: 'instance_stopped' });
  assert.deepEqual(visibleBlockers(s), []);
  assert.deepEqual(s.submitting, {});
  // A stale pre-stop fetch cannot bring them back.
  assert.equal(blockersReducer(s, { type: 'loaded', snapshot: snap(4, [perm('b1')]) }), s);
  assert.equal(instanceCanBeBlocked('running'), true);
  assert.equal(instanceCanBeBlocked('stopped'), false);
  assert.equal(instanceCanBeBlocked('failed'), false);
  assert.equal(instanceCanDecide('starting'), false);
});

test('card view: countdown, expiry, running gate and terminal prompts', () => {
  const b = normalizeBlocker(perm('b1'))!;
  const live = blockerCardView(b, NOW, 'running');
  assert.equal(live.phase, 'pending');
  assert.equal(live.countdown, '5:00');
  assert.equal(live.canDecide, true);
  assert.equal(blockerCardView(b, NOW, 'blocked').canDecide, false);
  const late = blockerCardView(b, Date.parse('2026-10-22T07:05:00Z'), 'running');
  assert.equal(late.phase, 'expired');
  assert.equal(late.canDecide, false);
  const noDeadline = blockerCardView(normalizeBlocker(perm('b2', { expires_at: '' }))!, NOW, 'running');
  assert.equal(noDeadline.canDecide, true);
  const term = blockerCardView(normalizeBlocker({ blocker_id: 't', kind: 'terminal_prompt' })!, NOW, 'running');
  assert.equal(term.phase, 'terminal');
  assert.equal(term.canDecide, false);
});

const root = fileURLToPath(new URL('..', import.meta.url));
const read = (p: string) => fs.readFileSync(`${root}/${p}`, 'utf8');

test('API uses the blockers endpoints and realtime refetches them', () => {
  const api = read('src/ui/api/endpoints/extension.ts');
  assert.match(api, /instancePath\(instanceId, 'blockers'\)/);
  assert.match(api, /\/resolve`/);
  assert.match(api, /'AgentBlockers'/);
  assert.doesNotMatch(api, /permission-requests/);
  const ws = read('src/ui/api/wsInvalidation.ts');
  assert.match(ws, /AGENT_BLOCKERS_CHANGE/);
  assert.match(ws, /'AgentBlockers'/);
  assert.doesNotMatch(ws, /permission_requests/);
  const pane = read('src/ui/components/workbench/AgentChatPane.tsx');
  assert.match(pane, /<InstancePermissionCards[\s\S]*runtimeStatus=\{runtimeStatus\}[\s\S]*onOpenTerminal=\{handleOpenPtyTab\}/);
});
