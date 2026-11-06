// Ticket board and ticket tab (ticket board design spec, REQ-B*, REQ-T*, REQ-L1).
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_ticket_board_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { configureStore } from '@reduxjs/toolkit';
import type { TaskWire } from '../src/ui/api/taskWire.ts';
import {
  attemptInfo,
  blockReasonText,
  boardFilterCounts,
  boardGroupFor,
  boardOrder,
  buildFleetMachines,
  diffAcceptance,
  fleetSummary,
  formatAgo,
  groupTickets,
  inlineChange,
  leaseClock,
  needsYouContext,
  needsYouHeadline,
  parseRequirementsHistory,
  progressCaption,
  progressCounts,
  replacedByComment,
  replacementLinks,
  requirementChangeLine,
  sortFinished,
  ticketKeys,
  ticketPosition,
  ticketShortTitle,
  ticketStateMenu,
  ticketTabTitle,
  upNextContext,
} from '../src/ui/components/tasks/ticketModel.ts';
import { buildTaskNames } from '../src/ui/components/tasks/taskNames.ts';
import {
  TASKS_TAB_ID,
  auxTabId,
  createAuxTab,
  decodeAuxTabId,
  isAuxContent,
  resolveLegacyPanelToAuxContent,
} from '../src/ui/store/auxTabId.ts';
import auxPanesReducer, { closeAuxTab, openAuxTab, rekeyAuxTab, selectAuxPane } from '../src/ui/store/auxPanesSlice.ts';
import workspaceLayoutReducer from '../src/ui/store/workspaceLayoutSlice.ts';

const REPO_ROOT = path.resolve(import.meta.dirname, '..');
const NOW = Date.parse('2026-11-02T18:30:00Z');
const iso = (msAgo: number) => new Date(NOW - msAgo).toISOString();
const MIN = 60_000;

function makeTask(over: Partial<TaskWire> & { task_id: string }): TaskWire {
  return {
    chain_id: 'chain_1',
    title: `Ticket ${over.task_id}`,
    publish_state: 'published',
    state: 'ready',
    kind: 'task',
    priority: 'p2',
    attempt_no: 1,
    bridge_id: '',
    brief: { goal: 'g', acceptance: ['a'] },
    blocked_on: null,
    requires_user_approval: false,
    ready_since: '',
    created_at: iso(60 * MIN),
    updated_at: iso(30 * MIN),
    ...over,
  } as TaskWire;
}

/* Keys and titles ---------------------------------------------------- */

test('REQ-T2: T-n is the 1-based created_at position; ties by task_id; untimed tasks last', () => {
  const keys = ticketKeys([
    { task_id: 'tsk_c', created_at: iso(10 * MIN) },
    { task_id: 'tsk_b', created_at: iso(30 * MIN) },
    { task_id: 'tsk_a', created_at: iso(30 * MIN) },
    { task_id: 'tsk_z', created_at: '' },
  ]);
  assert.equal(keys.get('tsk_a'), 'T-1');
  assert.equal(keys.get('tsk_b'), 'T-2');
  assert.equal(keys.get('tsk_c'), 'T-3');
  assert.equal(keys.get('tsk_z'), 'T-4');
});

test('REQ-T2: workflow stages get no key, so ticket keys have no gaps', () => {
  const keys = ticketKeys([
    { task_id: 'tsk_a', created_at: iso(30 * MIN) },
    { task_id: 'stage_1', created_at: iso(20 * MIN), workflow_run_id: 'run_1' },
    { task_id: 'tsk_b', created_at: iso(10 * MIN) },
  ]);
  assert.deepEqual([...keys], [['tsk_a', 'T-1'], ['tsk_b', 'T-2']]);
});

test('a sealed title stays one whole vault token in the tab title, so it can still be decrypted', () => {
  const sealed = 'vault:v2:0123456789abcdef:e1:c2VhbGVkIHRpdGxl';
  assert.equal(ticketShortTitle(sealed), sealed);
  assert.equal(ticketTabTitle('T-3', sealed), `T-3 ${sealed}`);
});

test('REQ-T1: the tab title is the key plus a short title', () => {
  assert.equal(ticketShortTitle('A: bridges auto-update themselves to the promoted release'), 'Bridges auto-update');
  assert.equal(ticketTabTitle('T-21', 'A: bridges auto-update themselves'), 'T-21 Bridges auto-update');
  assert.equal(ticketShortTitle(''), 'Untitled');
});

/* Groups, filter and order ------------------------------------------- */

const review = makeTask({ task_id: 'tsk_review', state: 'in_review', requires_user_approval: true, created_at: iso(50 * MIN) });
const working = makeTask({
  task_id: 'tsk_work',
  state: 'in_progress',
  created_at: iso(40 * MIN),
  leases: [{ lease_id: 'l1', kind: 'work', review_role: '', holder_instance_id: 'inst_w5', attempt_no: 1, bridge_id: 'brg_mac', granted_at: iso(1 * MIN), confirmed_at: iso(1 * MIN), expires_at: new Date(NOW + 14 * MIN).toISOString(), hard_deadline_at: new Date(NOW + 59 * MIN).toISOString(), delivery: '' }],
});
const held = makeTask({ task_id: 'tsk_held', state: 'ready', blocked_on: { kind: 'hold', reason: 're-route' } as any, created_at: iso(35 * MIN) });
const next = makeTask({ task_id: 'tsk_next', state: 'ready', depends_on: ['tsk_work'], created_at: iso(20 * MIN) });
const doneOld = makeTask({ task_id: 'tsk_done_old', state: 'done', completed_at: iso(120 * MIN), created_at: iso(200 * MIN) });
const doneNew = makeTask({ task_id: 'tsk_done_new', state: 'done', completed_at: iso(12 * MIN), created_at: iso(150 * MIN) });
const cancelled = makeTask({ task_id: 'tsk_cancel', state: 'cancelled', completed_at: '', updated_at: iso(40 * MIN), created_at: iso(100 * MIN) });
const ALL = [review, working, held, next, doneOld, doneNew, cancelled];

test('REQ-B4: groups come in board order, empty groups are hidden, a held ticket is Held', () => {
  assert.equal(boardGroupFor(review), 'needs_you');
  assert.equal(boardGroupFor(working), 'in_progress');
  assert.equal(boardGroupFor(held), 'held');
  assert.equal(boardGroupFor(next), 'up_next');
  const open = groupTickets(ALL, 'open').map((g) => g.key);
  assert.deepEqual(open, ['needs_you', 'in_progress', 'up_next', 'held']);
  assert.deepEqual(groupTickets(ALL, 'finished').map((g) => g.key), ['finished']);
  assert.deepEqual(groupTickets(ALL, 'all').map((g) => g.key), ['needs_you', 'in_progress', 'up_next', 'held', 'finished']);
  assert.deepEqual(boardFilterCounts(ALL), { open: 4, finished: 3, all: 7 });
});

test('REQ-B6: finished rows by completed_at newest first, falling back to updated_at, with an Oldest toggle', () => {
  assert.deepEqual(sortFinished([doneOld, cancelled, doneNew]).map((t) => t.task_id), ['tsk_done_new', 'tsk_cancel', 'tsk_done_old']);
  assert.deepEqual(sortFinished([doneOld, cancelled, doneNew], 'oldest').map((t) => t.task_id), ['tsk_done_old', 'tsk_cancel', 'tsk_done_new']);
});

test('previous / next follow board order and stop at the ends', () => {
  const order = boardOrder(ALL);
  assert.equal(order[0], 'tsk_review');
  const pos = ticketPosition(order, 'tsk_work');
  assert.equal(pos.prev, 'tsk_review');
  assert.equal(pos.next, 'tsk_next');
  assert.equal(pos.total, 7);
  assert.equal(ticketPosition(order, 'tsk_review').prev, null);
  assert.equal(ticketPosition(order, 'missing').index, -1);
});

/* Header ------------------------------------------------------------- */

test('REQ-B2: the headline leads with what needs you and names the first ask', () => {
  const keys = ticketKeys(ALL);
  const unblocked = makeTask({ task_id: 'tsk_after_review', state: 'ready', depends_on: ['tsk_review'], created_at: iso(5 * MIN) });
  const h = needsYouHeadline([...ALL, unblocked], ticketKeys([...ALL, unblocked]));
  assert.equal(h.title, '1 ticket needs you');
  assert.match(h.subtitle, /^Review T-\d+, then T-\d+ can ship$/);
  assert.equal(h.firstTaskId, 'tsk_review');
  const quiet = needsYouHeadline([working, next], ticketKeys([working, next]));
  assert.equal(quiet.title, 'Nothing needs you');
  const two = needsYouHeadline([review, makeTask({ task_id: 'tsk_draft', publish_state: 'draft' })], keys);
  assert.equal(two.title, '2 tickets need you');
});

test('REQ-B2: progress counts and caption agree with the groups', () => {
  const c = progressCounts(ALL);
  assert.deepEqual(c, { done: 2, inProgress: 1, inReview: 1, ready: 2, backlog: 0, cancelled: 1, total: 7 });
  const cap = progressCaption(c);
  assert.equal(cap.lead, '2 of 7 done');
  assert.equal(cap.rest, '1 in review · 1 in progress · 2 ready · 1 cancelled');
  const withBacklog = progressCounts([...ALL, makeTask({ task_id: 'b', state: 'backlog' })]);
  assert.equal(withBacklog.ready, 2, 'backlog is not waiting for a worker');
  assert.equal(withBacklog.backlog, 1);
  assert.match(progressCaption(withBacklog).rest, /1 in backlog/);
});

/* Cards -------------------------------------------------------------- */

test('REQ-B4: the attempt shows once, without "of N"; it warns only when the hub says the budget is spent', () => {
  // attempt_no counts every lease, including ones that spend no budget.
  assert.deepEqual(attemptInfo(makeTask({ task_id: 'x', attempt_no: 6 })), { no: 6, max: 5, exhausted: false, label: 'Attempt 6' });
  const spent = makeTask({ task_id: 'y', attempt_no: 5, blocked_on: { kind: 'human', reason: 'budget_exhausted', since_ms: NOW } as any });
  assert.equal(attemptInfo(spent).exhausted, true);
  assert.equal(attemptInfo(makeTask({ task_id: 'z', attempt_no: 2, brief: { budget: { max_attempts: 3 } } })).max, 3);
});

test('hub block reason codes read as sentences; other reasons pass through', () => {
  assert.match(blockReasonText('budget_exhausted'), /^Every attempt in the budget is spent/);
  assert.equal(blockReasonText('Which bucket should I use?'), 'Which bucket should I use?');
  assert.equal(blockReasonText(undefined), '');
});

test('state button: Approve is never offered during a rework or while an action runs; finished offers Reopen only', () => {
  const inReview = { task_id: 'r', state: 'in_review', requires_user_approval: true, attempt_no: 1 };
  assert.ok(ticketStateMenu(makeTask(inReview), false).includes('approve'));
  assert.ok(!ticketStateMenu(makeTask(inReview), true).includes('approve'), 'not while busy');
  const rework = makeTask({ ...inReview, requirements: { revision: 3, submitted_revision: 2, submitted_head: '', checkpoint_required: true, acknowledgements: [], history: '', history_truncated: false } });
  const menu = ticketStateMenu(rework, false);
  assert.ok(!menu.includes('approve'), 'requirements changed after submission');
  assert.ok(menu.includes('request_changes'));
  assert.deepEqual(ticketStateMenu(makeTask({ task_id: 'd', state: 'done' }), false), ['reopen']);
});

test('live values come from timestamps: lease time left and "ago" labels need no refetch', () => {
  const clock = leaseClock(working, NOW)!;
  assert.equal(clock.holderInstanceId, 'inst_w5');
  assert.equal(Math.round(clock.leftMs / MIN), 14);
  assert.equal(clock.fraction.toFixed(3), (14 / 15).toFixed(3), 'granted 1 min ago, 14 of 15 min left');
  assert.equal(Math.round((clock.hardLeftMs || 0) / MIN), 59);
  assert.equal(leaseClock(working, NOW + 7 * MIN)!.fraction < 1, true, 'the bar drains as the clock ticks');
  assert.equal(leaseClock(next, NOW), null);
  const unstamped = makeTask({ task_id: 'u', state: 'in_progress', leases: [{ ...working.leases![0], expires_at: '', granted_at: iso(5 * MIN), confirmed_at: '' }] });
  assert.equal(Math.round(leaseClock(unstamped, NOW)!.leftMs / MIN), 10, 'no expiry yet: the default 15 min lease from its grant');
  assert.equal(formatAgo(iso(12 * MIN), NOW), '12m ago');
  assert.equal(formatAgo(iso(10_000), NOW), 'just now');
});

test('REQ-B7: requirement-change line while fresh, unread or forcing rework; Rework after submission', () => {
  const fresh = makeTask({
    task_id: 'r',
    updated_at: iso(12 * MIN),
    requirements: { revision: 3, submitted_revision: 0, submitted_head: '', checkpoint_required: false, acknowledgements: [{ lease_id: 'l1', holder_instance_id: 'inst_w5', revision: 2, pending: true }], history: '', history_truncated: false },
  });
  const line = requirementChangeLine(fresh, NOW)!;
  assert.equal(line.revision, 3);
  assert.deepEqual(line.pendingReaders, ['inst_w5']);
  assert.equal(line.rework, false);
  const stale = makeTask({ task_id: 's', updated_at: iso(3 * 24 * 60 * MIN), requirements: { ...fresh.requirements!, acknowledgements: [] } });
  assert.equal(requirementChangeLine(stale, NOW), null, 'older than 24 h and read: no line');
  const rework = makeTask({ task_id: 'w', state: 'in_review', updated_at: iso(3 * 24 * 60 * MIN), requirements: { ...fresh.requirements!, acknowledgements: [], checkpoint_required: true } });
  assert.equal(requirementChangeLine(rework, NOW)?.rework, true);
  assert.equal(requirementChangeLine(makeTask({ task_id: 'n' }), NOW), null, 'revision 1 never shows a change');
});

test('card sentences: needs-you context and up-next dependencies', () => {
  const names = buildTaskNames({ identities: [{ agent_id: 'agt_worker', name: 'worker #5' }, { agent_id: 'agt_rev', name: 'reviewer #2' }] });
  const t = makeTask({
    task_id: 'q',
    state: 'in_review',
    attempt_no: 2,
    requires_user_approval: true,
    brief: { assignee: 'agt_worker' },
    reviews: [{ reviewer: 'agt_rev', reviewer_kind: 'agent', reviewer_instance_id: '', role: 'reviewer', verdict: 'approve', created_at: '' }],
  });
  assert.equal(needsYouContext(t, names), 'worker #5 handed off attempt 2 · reviewer #2 approved · waiting on you');
  const keys = ticketKeys(ALL);
  assert.equal(upNextContext(next, keys, ALL, names), `Starts after ${keys.get('tsk_work')} · any worker`);
});

/* Requirement history (gap G1) --------------------------------------- */

const HISTORY = [
  'Revision 3 — user usr_1 — 1730000000000',
  'Reason: Reinstalling a bridge wiped the opt-out on my test machine.',
  'Before goal: Each bridge follows the promoted release.',
  '- A bridge updates to the promoted release',
  '- Opting out is per profile and survives restarts',
  'After goal: Each bridge follows the promoted release.',
  '- A bridge updates to the promoted release',
  '- Opting out is per profile and survives restarts and bridge reinstalls',
  '- Waits at most 30 minutes for sessions to drain, then defers',
  'History event: #42',
  '',
  'Revision 2 — agent inst_coord — 1729990000000',
  'Reason: Follow the promoted release.',
  'Before goal: Each bridge updates itself to the newest build.',
  '- Updates run at 3am local time',
  'After goal: Each bridge follows the promoted release.',
  '- A bridge updates to the promoted release',
  'History event: #31',
  '',
].join('\n');

test('G1: the preformatted history parses into revisions, newest first; bad text returns null', () => {
  const entries = parseRequirementsHistory(HISTORY)!;
  assert.equal(entries.length, 2);
  assert.equal(entries[0].revision, 3);
  assert.equal(entries[0].actorKind, 'user');
  assert.equal(entries[0].actorId, 'usr_1');
  assert.equal(entries[0].tsMs, 1730000000000);
  assert.equal(entries[0].reason, 'Reinstalling a bridge wiped the opt-out on my test machine.');
  assert.equal(entries[0].after.acceptance.length, 3);
  assert.equal(entries[0].eventId, 42);
  assert.equal(entries[1].before.goal, 'Each bridge updates itself to the newest build.');
  assert.deepEqual(parseRequirementsHistory(''), []);
  assert.equal(parseRequirementsHistory('not the hub format'), null);
});

test('G1: markdown bullets inside a goal stay in the goal; only the trailing "- " lines are acceptance', () => {
  const text = [
    'Revision 2 — user usr_1 — 1730000000000',
    'Reason: Spell out the cases.',
    'Before goal: Handle errors.',
    '- Errors are logged',
    'After goal: Handle errors in:',
    '- the bridge',
    '- the hub',
    'and report them once.',
    '- Errors are logged',
    '- Each error is reported once',
    'History event: #7',
  ].join('\n');
  const [entry] = parseRequirementsHistory(text)!;
  assert.equal(entry.after.goal, 'Handle errors in:\n- the bridge\n- the hub\nand report them once.');
  assert.deepEqual(entry.after.acceptance, ['Errors are logged', 'Each error is reported once']);
  assert.deepEqual(entry.before.acceptance, ['Errors are logged']);
});

test('REQ-T4: acceptance items are tagged Edited / New against the previous revision', () => {
  const [latest] = parseRequirementsHistory(HISTORY)!;
  const diff = diffAcceptance(latest.before.acceptance, latest.after.acceptance);
  assert.deepEqual(diff.items.map((i) => i.tag), [null, 'edited', 'new']);
  assert.equal(diff.items[1].previous, 'Opting out is per profile and survives restarts');
  assert.deepEqual(diff.removed, []);
  const removedOnly = diffAcceptance(['a', 'b', 'c'], ['a', 'c']);
  assert.deepEqual(removedOnly.items.map((i) => i.tag), [null, null]);
  assert.deepEqual(removedOnly.removed, ['b']);
  assert.deepEqual(inlineChange('survives restarts', 'survives restarts and bridge reinstalls'), { prefix: 'survives restarts', changed: ' and bridge reinstalls', suffix: '' });
});

test('G2: a replacement link round-trips through its comment text', () => {
  assert.deepEqual(replacementLinks(replacedByComment('tsk_new', 'T-27')), { replacedBy: 'tsk_new', replaces: null });
  assert.deepEqual(replacementLinks('Replaces ticket tsk_old (T-17).'), { replacedBy: null, replaces: 'tsk_old' });
  assert.deepEqual(replacementLinks('nothing here'), { replacedBy: null, replaces: null });
});

/* Fleet table -------------------------------------------------------- */

test('REQ-B3: fleet rows grouped by machine with Working / Idle / Coordinating / Not running; offline machines read Not running', () => {
  const keys = ticketKeys(ALL);
  const machines = buildFleetMachines({
    tasks: ALL,
    members: [
      { agent_instance_id: 'inst_coord', agent_id: 'agt_coord', role: 'coordinator', display_name: 'coordinator #1', runtime_status: 'live' },
      { agent_instance_id: 'inst_w5', agent_id: 'agt_worker', role: 'member', display_name: 'worker #5', runtime_status: 'live' },
      { agent_instance_id: 'inst_r2', agent_id: 'agt_rev', role: 'member', display_name: 'reviewer #2', runtime_status: 'live' },
      { agent_instance_id: 'inst_lx', agent_id: 'agt_linux', role: 'member', display_name: 'builder #1', runtime_status: 'live' },
    ],
    fleets: [
      { agent_id: 'agt_worker', capacity: 2, roles: ['worker'], effective: { bridge_id: 'brg_mac' } },
      { agent_id: 'agt_rev', capacity: 1, roles: ['reviewer'], bridge_id: 'brg_mac' },
      { agent_id: 'agt_linux', capacity: 2, roles: ['worker'], bridge_id: 'brg_linux' },
    ],
    bridges: [
      { bridge_id: 'brg_mac', label: 'Tanmays-MacBook-Pro.local', status: 'online' },
      { bridge_id: 'brg_linux', label: 'linux-builder', status: 'offline' },
    ],
    coordinatorInstanceId: 'inst_coord',
    keys,
    agentName: (id) => ({ agt_worker: 'worker', agt_rev: 'reviewer', agt_linux: 'builder' } as Record<string, string>)[id] || 'Agent',
  });
  const mac = machines.find((m) => m.bridgeId === 'brg_mac')!;
  const linux = machines.find((m) => m.bridgeId === 'brg_linux')!;
  assert.equal(mac.online, true);
  assert.equal(linux.online, false);
  const byId = Object.fromEntries(mac.slots.map((s) => [s.id, s]));
  assert.equal(byId.inst_w5.state, 'working');
  assert.equal(byId.inst_w5.taskId, 'tsk_work');
  assert.match(byId.inst_w5.detail, new RegExp(`^${keys.get('tsk_work')} `));
  assert.equal(byId.inst_r2.state, 'idle');
  assert.equal(byId.inst_r2.detail, 'Waiting for a handoff');
  assert.equal(byId['agt_worker-slot-1'].state, 'not_running', 'unused capacity is a slot the hub starts when needed');
  assert.ok(linux.slots.every((s) => s.state === 'not_running' && s.detail === 'Machine offline'));
  assert.equal(linux.slots.length, 2);
  // The coordinator has no lease or fleet row: it lands on "Any machine".
  const any = machines.find((m) => m.bridgeId === '')!;
  assert.equal(any.slots[0].state, 'coordinating');
  assert.equal(machines[machines.length - 1].bridgeId, 'brg_linux', 'offline machines sort last');
  assert.equal(fleetSummary(machines), '1 working · 1 idle · 3 off');
});

test('a starting agent reads Starting, not Not running', () => {
  const [machine] = buildFleetMachines({
    tasks: [],
    members: [{ agent_instance_id: 'inst_new', agent_id: 'agt_worker', display_name: 'worker #6', runtime_status: 'starting' }],
    fleets: [{ agent_id: 'agt_worker', capacity: 1, roles: ['worker'], bridge_id: 'brg_mac' }],
    bridges: [{ bridge_id: 'brg_mac', label: 'mac', status: 'online' }],
    keys: new Map(),
    agentName: () => 'worker',
  });
  assert.equal(machine.slots.length, 1, 'the starting instance fills the slot');
  assert.equal(machine.slots[0].state, 'idle');
  assert.equal(machine.slots[0].detail, 'Starting');
});

test('edge state "Agent stopped mid-work": the slot reads Blocked on that ticket since the hub noticed', () => {
  const stalled = makeTask({
    task_id: 'tsk_stalled',
    title: 'Bridges auto-update',
    blocked_on: { kind: 'agent_not_running', agent_id: 'agt_worker', reason: 'Agent agt_worker is not running', since_ms: NOW - 2 * MIN },
  });
  const keys = ticketKeys([stalled]);
  const [mac] = buildFleetMachines({
    tasks: [stalled],
    members: [{ agent_instance_id: 'inst_w5', agent_id: 'agt_worker', display_name: 'worker #5', runtime_status: 'stopped' }],
    fleets: [{ agent_id: 'agt_worker', capacity: 1, roles: ['worker'], bridge_id: 'brg_mac' }],
    bridges: [{ bridge_id: 'brg_mac', label: 'mac', status: 'online' }],
    keys,
    agentName: () => 'worker',
  });
  const slot = mac.slots[0];
  assert.equal(slot.state, 'blocked');
  assert.equal(slot.taskId, 'tsk_stalled');
  assert.equal(slot.detail, 'T-1 Bridges auto-update');
  assert.equal(formatAgo(slot.sinceMs, NOW), '2m ago');
});

/* Aux tab kind (REQ-T1) ---------------------------------------------- */

test('REQ-T1: ticket tabs have a content-derived id that decodes back', () => {
  const content = { type: 'ticket' as const, chainId: 'chn_1', taskId: 'tsk_21' };
  assert.equal(auxTabId(content), 'ticket__chn_1:tsk_21');
  assert.deepEqual(decodeAuxTabId('ticket__chn_1:tsk_21'), content);
  assert.equal(decodeAuxTabId('ticket__chn_1:'), null);
  assert.equal(isAuxContent(content), true);
  assert.equal(isAuxContent({ type: 'ticket', chainId: '', taskId: 't' }), false);
  assert.equal(createAuxTab({ ...content, focus: 'decision' }).id, 'ticket__chn_1:tsk_21', 'transient focus never enters the id');
});

test('REQ-T1: opening a ticket twice focuses the one tab; prev/next rekeys it; closing returns to Tickets', () => {
  const store = configureStore({ reducer: { workspaceLayout: workspaceLayoutReducer, auxPanes: auxPanesReducer } });
  const treeId = { kind: 'chain' as const, chainId: 'chn_1' };
  store.dispatch(openAuxTab({ treeId, content: { type: 'tasks' }, hasChain: true }));
  store.dispatch(openAuxTab({ treeId, content: { type: 'ticket', chainId: 'chn_1', taskId: 'tsk_21' }, title: 'T-21 Bridges auto-update' }));
  store.dispatch(openAuxTab({ treeId, content: { type: 'tasks' } }));
  store.dispatch(openAuxTab({ treeId, content: { type: 'ticket', chainId: 'chn_1', taskId: 'tsk_21' }, title: 'T-21 Bridges auto-update' }));
  let pane = selectAuxPane(store.getState(), treeId)!;
  assert.equal(pane.tabs.filter((t) => t.content.type === 'ticket').length, 1, 'no duplicate ticket tab');
  assert.equal(pane.activeTabId, 'ticket__chn_1:tsk_21');
  assert.equal(pane.tabs.find((t) => t.id === 'ticket__chn_1:tsk_21')?.title, 'T-21 Bridges auto-update');

  store.dispatch(rekeyAuxTab({ treeId, tabId: 'ticket__chn_1:tsk_21', content: { type: 'ticket', chainId: 'chn_1', taskId: 'tsk_22' }, title: 'T-22 Next one' }));
  pane = selectAuxPane(store.getState(), treeId)!;
  assert.equal(pane.activeTabId, 'ticket__chn_1:tsk_22');
  assert.equal(pane.tabs.filter((t) => t.content.type === 'ticket').length, 1, 'same tab, new ticket');

  store.dispatch(openAuxTab({ treeId, content: { type: 'files' } }));
  store.dispatch(openAuxTab({ treeId, content: { type: 'ticket', chainId: 'chn_1', taskId: 'tsk_22' } }));
  store.dispatch(closeAuxTab({ treeId, tabId: 'ticket__chn_1:tsk_22' }));
  pane = selectAuxPane(store.getState(), treeId)!;
  assert.equal(pane.activeTabId, TASKS_TAB_ID, 'focus returns to the Tickets tab');
});

test('legacy ?panel=tasks&task=<id> resolves to the ticket tab once the chain is known', () => {
  assert.deepEqual(resolveLegacyPanelToAuxContent('tasks', { taskId: 'tsk_1', chainId: 'chn_1' }), { type: 'ticket', chainId: 'chn_1', taskId: 'tsk_1' });
  assert.deepEqual(resolveLegacyPanelToAuxContent('tasks', { taskId: 'tsk_1' }), { type: 'tasks', taskId: 'tsk_1' });
  assert.deepEqual(resolveLegacyPanelToAuxContent('tasks', {}), { type: 'tasks' });
});

/* Rendered views ----------------------------------------------------- */

async function renderWith(element: (React: any) => any, seed?: (store: any) => Promise<void>) {
  const React = (await import('react')).default;
  const { Provider } = await import('react-redux');
  const { renderToStaticMarkup } = await import('react-dom/server');
  const { makeVaultStore } = await import('./helpers/vaultEndpointHarness.ts');
  const store = await makeVaultStore();
  if (seed) await seed(store);
  return renderToStaticMarkup(React.createElement(Provider, { store, children: element(React) }));
}

test('board render: header, filter, fleet, groups and finished rows; no rails or glows (REQ-B5)', async () => {
  const { TicketBoard } = await import('../src/ui/components/tasks/TicketBoard.tsx');
  const keys = ticketKeys(ALL);
  const names = buildTaskNames({ tasks: ALL });
  const html = await renderWith((React) =>
    React.createElement(TicketBoard, {
      chainId: 'chain_1',
      tasks: ALL,
      keys,
      names,
      machines: [],
      onOpenTicket: () => {},
      onOpenAgent: () => {},
      onEditTicket: () => {},
      onNewTask: () => {},
      onOpenFleetDrawer: () => {},
    }),
  );
  assert.match(html, /data-debug-id="ticket-board-headline"[^>]*>1 ticket needs you</);
  assert.match(html, /data-debug-id="task-board-new-task-btn"/);
  assert.match(html, /data-debug-id="ticket-board-filter-open"/);
  assert.match(html, /data-debug-id="ticket-board-fleet"/);
  assert.match(html, /data-debug-id="task-board-section-needs_you"/);
  assert.match(html, /data-debug-id="task-board-section-held"/);
  assert.doesNotMatch(html, /task-board-section-finished/, 'the Open filter hides Finished');
  assert.match(html, /data-debug-id="task-card-ask-tsk_review"[^>]*>Your review</);
  assert.match(html, new RegExp(`>${keys.get('tsk_review')}<`));
  assert.doesNotMatch(html, /shadow-glow|bg-accent-soft|w-\[3px\]/, 'state is a pill with a word, never a rail, outline or glow');
});

test('board render: empty chain offers New ticket', async () => {
  const { TicketBoard } = await import('../src/ui/components/tasks/TicketBoard.tsx');
  const html = await renderWith((React) =>
    React.createElement(TicketBoard, { chainId: 'chain_1', tasks: [], keys: new Map(), machines: [], onOpenTicket: () => {}, onOpenAgent: () => {}, onEditTicket: () => {}, onNewTask: () => {} }),
  );
  assert.match(html, /No tickets yet/);
  assert.match(html, /data-debug-id="task-board-empty-new-task-btn"/);
});

test('ticket tab render: toolbar, title, decision block, requirements and activity tabs, no Details card', async () => {
  const { TicketView } = await import('../src/ui/components/tasks/TicketView.tsx');
  const { tasksApi } = await import('../src/ui/api/endpoints/tasks.ts');
  const task = makeTask({
    task_id: 'tsk_review',
    state: 'in_review',
    requires_user_approval: true,
    title: 'C: Hub bridge-update catalog follows the promoted release',
    requirements: { revision: 3, submitted_revision: 2, submitted_head: 'a91f3c2', checkpoint_required: true, acknowledgements: [], history: HISTORY, history_truncated: false },
    brief: { goal: 'Each bridge follows the promoted release.', acceptance: ['A bridge updates to the promoted release', 'Opting out is per profile and survives restarts and bridge reinstalls', 'Waits at most 30 minutes for sessions to drain, then defers'] },
    reviews: [{ reviewer: 'agt_rev', reviewer_kind: 'agent', reviewer_instance_id: '', role: 'reviewer', verdict: 'approve', created_at: '' }],
  });
  const html = await renderWith(
    (React) => React.createElement(TicketView, { chainId: 'chain_1', taskId: 'tsk_review', onShowBoard: () => {}, onOpenTicket: () => {}, onSwitchTicket: () => {}, onOpenAgent: () => {} }),
    async (store) => {
      await store.dispatch(tasksApi.util.upsertQueryData('fetchTaskChainDetail', { chainId: 'chain_1' }, { chain: { chain_id: 'chain_1', tasks: [task, working], members: [] } } as any));
      await store.dispatch(tasksApi.util.upsertQueryData('fetchChainTaskDetail', { chainId: 'chain_1', taskId: 'tsk_review' }, { task } as any));
    },
  );
  assert.match(html, /data-debug-id="ticket-view-breadcrumb-tickets"/);
  assert.match(html, /data-debug-id="ticket-view-prev-btn"/);
  assert.match(html, /data-debug-id="ticket-view-copy-link-btn"/);
  assert.match(html, /data-debug-id="ticket-view-title"/);
  assert.match(html, /data-debug-id="your-review-block"/);
  assert.match(html, /data-debug-id="ticket-view-rework-notice"/, 'REQ-T6 explains the requirements changed after submission');
  assert.match(html, /for rev 2 · no longer counts/, 'REQ-T6 marks earlier votes');
  assert.match(html, /data-debug-id="ticket-view-approve-btn"[^>]*disabled=""|disabled=""[^>]*data-debug-id="ticket-view-approve-btn"/, 'REQ-T6 disables Approve until resubmission');
  assert.match(html, /data-debug-id="ticket-view-requirements"/);
  assert.match(html, />Edited</);
  assert.match(html, />New</);
  assert.doesNotMatch(html, /data-debug-id="ticket-view-details"/, "the Details card is gone");
  assert.doesNotMatch(html, /data-debug-id="ticket-view-edit-bridge"/);
  assert.match(html, /data-debug-id="ticket-activity-tab-requirements"/);
  assert.match(html, /data-debug-id="comment-composer"/);
});

test('ticket tab render: a ticket that left the chain says so, with Back to Tickets', async () => {
  const { TicketView } = await import('../src/ui/components/tasks/TicketView.tsx');
  const { tasksApi } = await import('../src/ui/api/endpoints/tasks.ts');
  const html = await renderWith(
    (React) => React.createElement(TicketView, { chainId: 'chain_1', taskId: 'tsk_gone', onShowBoard: () => {}, onOpenTicket: () => {}, onSwitchTicket: () => {}, onOpenAgent: () => {} }),
    async (store) => {
      await store.dispatch(tasksApi.util.upsertQueryData('fetchTaskChainDetail', { chainId: 'chain_1' }, { chain: { chain_id: 'chain_1', tasks: [working], members: [] } } as any));
      await store.dispatch(tasksApi.util.upsertQueryData('fetchChainTaskDetail', { chainId: 'chain_1', taskId: 'tsk_gone' }, { task: null } as any));
    },
  );
  assert.match(html, /This ticket isn(&#x27;|')t in this chain any more/);
  assert.match(html, /data-debug-id="ticket-view-back-to-board-btn"/);
});

/* Quality gates ------------------------------------------------------ */

const NEW_FILES = [
  'src/ui/components/tasks/TicketBoard.tsx',
  'src/ui/components/tasks/BoardTicketCard.tsx',
  'src/ui/components/tasks/TicketFleetTable.tsx',
  'src/ui/components/tasks/TicketView.tsx',
  'src/ui/components/tasks/TicketCard.tsx',
  'src/ui/components/tasks/TicketDecisionBlock.tsx',
  'src/ui/components/tasks/TicketAgentsCard.tsx',
  'src/ui/components/tasks/TicketRequirementsCard.tsx',
  'src/ui/components/tasks/TicketLinkedCard.tsx',
  'src/ui/components/tasks/TicketAttemptsCard.tsx',
  'src/ui/components/tasks/TicketChangesCard.tsx',
  'src/ui/components/tasks/HoldReasonDialog.tsx',
  'src/ui/components/tasks/TicketActivity.tsx',
  'src/ui/components/tasks/RequirementsEditorModal.tsx',
  'src/ui/components/tasks/TicketAgentAvatar.tsx',
  'src/ui/components/tasks/ticketModel.ts',
  'src/ui/components/tasks/useChainTickets.ts',
];

test('REQ-L1: neither view polls', () => {
  for (const rel of NEW_FILES) {
    const src = fs.readFileSync(path.join(REPO_ROOT, rel), 'utf8');
    assert.doesNotMatch(src, /pollingInterval|refetchInterval/, `${rel} must not poll`);
  }
});

test('REQ-Q1: tokens only, no raw hex colours in the new views', () => {
  for (const rel of NEW_FILES) {
    const src = fs.readFileSync(path.join(REPO_ROOT, rel), 'utf8');
    assert.doesNotMatch(src, /#[0-9a-fA-F]{3,8}\b(?!\})/, `${rel} uses a raw hex colour`);
  }
});

test('REQ-Q1: every button, input, select and textarea in the new views has a data-debug-id or is an @ui control given one', () => {
  for (const rel of NEW_FILES.filter((f) => f.endsWith('.tsx'))) {
    const src = fs.readFileSync(path.join(REPO_ROOT, rel), 'utf8');
    // `=>` inside an onClick is not the end of the tag.
    const tags = src.match(/<(button|input|select|textarea)\b(?:=>|[^>])*>/gs) || [];
    for (const tag of tags) assert.match(tag, /data-debug-id=/, `${rel}: ${tag.slice(0, 80)}`);
  }
});

test('avatar initials are one letter or digit, never a bracket from a "(model)" suffix', async () => {
  const { initialsOf } = await import('../src/ui/components/ui/primitives/Avatar.tsx');
  assert.equal(initialsOf('Safety Reviewer (gpt-6.1-sol)'), 'S');
  assert.equal(initialsOf('coordinator'), 'C');
  assert.equal(initialsOf('(gpt) helper'), 'G');
  assert.equal(initialsOf('   '), '?');
});

test('activity rows top-align the avatar so a wrapped line does not stretch its ring', () => {
  const src = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/tasks/TicketActivity.tsx'), 'utf8');
  assert.match(src, /data-debug-id="task-timeline-event" className="flex items-start gap-3"/);
});
