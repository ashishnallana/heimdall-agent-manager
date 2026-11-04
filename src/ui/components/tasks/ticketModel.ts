import type { TaskWire } from '../../api/taskWire';
import { normalizeTaskState, reviewLeases, taskHold, workLease } from './taskV2Types';
import { awaitingYourReview, blockedOnYou, getTaskActions, isDraft, taskNeedsYou, type TaskActionId } from './taskActions';
import { isAgentRunning } from '../../utils/agentStatus';
import { containsVaultArmored } from '../../utils/vaultCrypto';

/**
 * Pure model behind the Tickets board and the ticket tab (ticket board design
 * spec, REQ-B* / REQ-T*). No React and no fetching: every view value is derived
 * here from the cached chain, fleet, live-agent and bridge data, so the views
 * update from WebSocket cache patches alone (REQ-L1).
 */

/** A work lease's length when the hub has not stamped its expiry yet. */
const DEFAULT_LEASE_MS = 15 * 60000;

/** Attempts a ticket gets when its brief sets no budget (the hub's default). */
export const DEFAULT_MAX_ATTEMPTS = 5;

/**
 * Gap G2: the hub has no native "replaces / replaced by" link (the brief schema
 * rejects unknown keys), so Replace stays behind this flag. The link is recorded
 * as a comment on both tickets and shown only where it is found.
 */
export const TICKET_REPLACE_ENABLED = false;

const DAY_MS = 24 * 60 * 60 * 1000;

function str(v: unknown): string {
  return typeof v === 'string' ? v.trim() : '';
}

/** Milliseconds since epoch for an RFC3339 / numeric timestamp, or NaN. */
export function timestampMs(value: unknown): number {
  if (typeof value === 'number') return value;
  const s = str(value);
  if (!s) return NaN;
  if (/^\d+$/.test(s)) return Number(s);
  return Date.parse(s);
}

/* ------------------------------------------------------------------ *
 * Keys and titles (REQ-T1, REQ-T2, gap G4)
 * ------------------------------------------------------------------ */

/**
 * `T-n` per ticket: its 1-based position by created_at within the chain, ties
 * broken by task_id (REQ-T2). Tasks without a timestamp sort last. Workflow
 * stages are not tickets and get no key, so the keys have no gaps.
 */
export function ticketKeys(tasks: readonly Pick<TaskWire, 'task_id' | 'created_at' | 'workflow_run_id'>[]): Map<string, string> {
  const sorted = [...tasks].filter((t) => t?.task_id && !t.workflow_run_id).sort((a, b) => {
    const ta = timestampMs(a.created_at);
    const tb = timestampMs(b.created_at);
    const na = Number.isNaN(ta);
    const nb = Number.isNaN(tb);
    if (na !== nb) return na ? 1 : -1;
    if (!na && ta !== tb) return ta - tb;
    return a.task_id < b.task_id ? -1 : a.task_id > b.task_id ? 1 : 0;
  });
  const keys = new Map<string, string>();
  sorted.forEach((t, i) => keys.set(t.task_id, `T-${i + 1}`));
  return keys;
}

export function keyFor(keys: Map<string, string>, taskId: string): string {
  return keys.get(taskId) || 'T-?';
}

/**
 * A few words for a tab label: "A: bridges auto-update themselves to…" becomes
 * "Bridges auto-update". A leading "A:" / "P2:" style tag is dropped.
 */
export function ticketShortTitle(title: string, maxWords = 2): string {
  // A sealed title is one vault token: cutting it would make it undecryptable.
  if (containsVaultArmored(title)) return str(title);
  const clean = str(title).replace(/^[A-Za-z0-9]{1,3}:\s+/, '');
  if (!clean) return 'Untitled';
  const words = clean.split(/\s+/).slice(0, maxWords).join(' ').replace(/[,.;:]+$/, '');
  return words.charAt(0).toUpperCase() + words.slice(1);
}

/** The ticket tab's title: "T-21 Bridges auto-update" (REQ-T1). */
export function ticketTabTitle(key: string, title: string): string {
  return `${key} ${ticketShortTitle(title)}`;
}

/* ------------------------------------------------------------------ *
 * Groups, filter and order (REQ-B4, REQ-B6)
 * ------------------------------------------------------------------ */

export type BoardGroupKey = 'needs_you' | 'in_progress' | 'in_review' | 'up_next' | 'held' | 'finished';
export type BoardFilter = 'open' | 'finished' | 'all';
export type FinishedOrder = 'newest' | 'oldest';

export const BOARD_GROUP_ORDER: BoardGroupKey[] = ['needs_you', 'in_progress', 'in_review', 'up_next', 'held', 'finished'];

export const BOARD_GROUP_LABELS: Record<BoardGroupKey, string> = {
  needs_you: 'Needs you',
  in_progress: 'In progress',
  in_review: 'In review',
  up_next: 'Up next',
  held: 'Held',
  finished: 'Finished',
};

export function isFinishedTask(task: Pick<TaskWire, 'state'>): boolean {
  const s = normalizeTaskState(task.state);
  return s === 'done' || s === 'cancelled';
}

/** The board group a ticket belongs to. A held ticket is Held unless it needs you. */
export function boardGroupFor(task: TaskWire): BoardGroupKey {
  if (isFinishedTask(task)) return 'finished';
  if (taskNeedsYou(task)) return 'needs_you';
  if (taskHold(task)) return 'held';
  const s = normalizeTaskState(task.state);
  if (s === 'in_progress') return 'in_progress';
  if (s === 'in_review') return 'in_review';
  return 'up_next';
}

const PRIORITY_RANK: Record<string, number> = { p0: 0, p1: 1, p2: 2 };

function compareOpen(a: TaskWire, b: TaskWire): number {
  const pa = PRIORITY_RANK[String(a.priority || '').toLowerCase()] ?? 3;
  const pb = PRIORITY_RANK[String(b.priority || '').toLowerCase()] ?? 3;
  if (pa !== pb) return pa - pb;
  const ta = timestampMs(a.created_at);
  const tb = timestampMs(b.created_at);
  if (!Number.isNaN(ta) && !Number.isNaN(tb) && ta !== tb) return ta - tb;
  return a.task_id < b.task_id ? -1 : a.task_id > b.task_id ? 1 : 0;
}

/** When a finished ticket finished: completed_at, then updated_at, then created_at (REQ-B6). */
export function finishedAtMs(task: Pick<TaskWire, 'completed_at' | 'updated_at' | 'created_at'>): number {
  for (const v of [task.completed_at, task.updated_at, task.created_at]) {
    const ms = timestampMs(v);
    if (!Number.isNaN(ms)) return ms;
  }
  return NaN;
}

/** Finished tickets newest (or oldest) first; ties and missing times fall back to task_id. */
export function sortFinished(tasks: readonly TaskWire[], order: FinishedOrder = 'newest'): TaskWire[] {
  const dir = order === 'newest' ? -1 : 1;
  return [...tasks].sort((a, b) => {
    const ta = finishedAtMs(a);
    const tb = finishedAtMs(b);
    const na = Number.isNaN(ta);
    const nb = Number.isNaN(tb);
    if (na !== nb) return na ? 1 : -1;
    if (!na && ta !== tb) return (ta - tb) * dir;
    return a.task_id < b.task_id ? -1 : a.task_id > b.task_id ? 1 : 0;
  });
}

export interface BoardGroup {
  key: BoardGroupKey;
  label: string;
  tasks: TaskWire[];
}

/** Non-empty groups in board order for a filter (REQ-B4: empty groups are hidden). */
export function groupTickets(tasks: readonly TaskWire[], filter: BoardFilter = 'open', order: FinishedOrder = 'newest'): BoardGroup[] {
  const buckets: Record<BoardGroupKey, TaskWire[]> = { needs_you: [], in_progress: [], in_review: [], up_next: [], held: [], finished: [] };
  for (const t of tasks) {
    if (!t?.task_id) continue;
    buckets[boardGroupFor(t)].push(t);
  }
  return BOARD_GROUP_ORDER.filter((key) => {
    if (filter === 'open' && key === 'finished') return false;
    if (filter === 'finished' && key !== 'finished') return false;
    return buckets[key].length > 0;
  }).map((key) => ({
    key,
    label: BOARD_GROUP_LABELS[key],
    tasks: key === 'finished' ? sortFinished(buckets[key], order) : buckets[key].sort(compareOpen),
  }));
}

export function boardFilterCounts(tasks: readonly TaskWire[]): Record<BoardFilter, number> {
  const finished = tasks.filter(isFinishedTask).length;
  return { open: tasks.length - finished, finished, all: tasks.length };
}

/** Every ticket in the order the All filter shows them: previous / next follow it (REQ-T8 click map). */
export function boardOrder(tasks: readonly TaskWire[], order: FinishedOrder = 'newest'): string[] {
  return groupTickets(tasks, 'all', order).flatMap((g) => g.tasks.map((t) => t.task_id));
}

export interface TicketPosition {
  index: number;
  total: number;
  prev: string | null;
  next: string | null;
}

export function ticketPosition(order: readonly string[], taskId: string): TicketPosition {
  const index = order.indexOf(taskId);
  if (index < 0) return { index: -1, total: order.length, prev: null, next: null };
  return {
    index,
    total: order.length,
    prev: index > 0 ? order[index - 1] : null,
    next: index < order.length - 1 ? order[index + 1] : null,
  };
}

/* ------------------------------------------------------------------ *
 * Header: progress and what needs you (REQ-B2)
 * ------------------------------------------------------------------ */

export interface ProgressCounts {
  done: number;
  inProgress: number;
  inReview: number;
  ready: number;
  /** Not ready yet: backlog, drafts and tickets waiting on dependencies. */
  backlog: number;
  cancelled: number;
  total: number;
}

export function progressCounts(tasks: readonly TaskWire[]): ProgressCounts {
  const c: ProgressCounts = { done: 0, inProgress: 0, inReview: 0, ready: 0, backlog: 0, cancelled: 0, total: 0 };
  for (const t of tasks) {
    c.total += 1;
    const s = normalizeTaskState(t.state);
    if (s === 'done') c.done += 1;
    else if (s === 'cancelled') c.cancelled += 1;
    else if (s === 'in_progress') c.inProgress += 1;
    else if (s === 'in_review') c.inReview += 1;
    else if (s === 'ready') c.ready += 1;
    else c.backlog += 1;
  }
  return c;
}

/** Bar segments in order: done, in progress (incl. review), ready, cancelled. Widths in percent. */
export function progressSegments(c: ProgressCounts): { key: 'done' | 'in_progress' | 'ready' | 'cancelled'; count: number; percent: number }[] {
  const total = c.total || 1;
  return [
    { key: 'done' as const, count: c.done },
    { key: 'in_progress' as const, count: c.inProgress + c.inReview },
    { key: 'ready' as const, count: c.ready },
    { key: 'cancelled' as const, count: c.cancelled },
  ].map((s) => ({ ...s, percent: (s.count / total) * 100 }));
}

/** "18 of 23 done · 1 in review · 2 in progress · 2 cancelled" (zero parts dropped). */
export function progressCaption(c: ProgressCounts): { lead: string; rest: string } {
  const rest = [
    c.inReview ? `${c.inReview} in review` : '',
    c.inProgress ? `${c.inProgress} in progress` : '',
    c.ready ? `${c.ready} ready` : '',
    c.backlog ? `${c.backlog} in backlog` : '',
    c.cancelled ? `${c.cancelled} cancelled` : '',
  ].filter(Boolean);
  return { lead: `${c.done} of ${c.total} done`, rest: rest.join(' · ') };
}

export type TicketAsk = 'review' | 'answer' | 'agent_down' | 'publish';

/** What a ticket needs from you, or null. */
export function ticketAsk(task: TaskWire): TicketAsk | null {
  if (!taskNeedsYou(task)) return null;
  if (isDraft(task)) return 'publish';
  const b: any = task.blocked_on;
  if (b && (b.kind === 'agent_not_running' || b.kind === 'dispatch')) return 'agent_down';
  if (blockedOnYou(task)) return 'answer';
  if (awaitingYourReview(task)) return 'review';
  return 'answer';
}

/** The hub's human-block reasons as a person would say them. */
const HUB_BLOCK_REASONS: Record<string, string> = {
  budget_exhausted: 'Every attempt in the budget is spent. Reopen it or raise its budget to try again.',
  oscillation: 'The work kept going back and forth between attempts, so the hub stopped it.',
  merge_conflict: 'The work could not be merged back because of a conflict. Resolve it, then recheck.',
  blocked: 'The work is blocked and needs you.',
};

/** A block's reason for people: known hub reason codes become a sentence. */
export function blockReasonText(reason: unknown): string {
  const r = String(reason || '').trim();
  return HUB_BLOCK_REASONS[r] || r;
}

export const ASK_LABELS: Record<TicketAsk, string> = {
  review: 'Your review',
  answer: 'Your answer',
  agent_down: 'Agent not running',
  publish: 'Not published',
};

const ASK_VERBS: Record<TicketAsk, string> = {
  review: 'Review',
  answer: 'Answer',
  agent_down: 'Start the agent for',
  publish: 'Publish',
};

/** Open tickets that wait for `taskId`. */
export function dependentsOf(tasks: readonly TaskWire[], taskId: string): TaskWire[] {
  return tasks.filter((t) => !isFinishedTask(t) && (t.depends_on || []).includes(taskId));
}

/**
 * The header's lead: "2 tickets need you" / "Nothing needs you", and one line
 * naming the first ask ("Review T-19, then T-21 can ship").
 */
export function needsYouHeadline(tasks: readonly TaskWire[], keys: Map<string, string>): { count: number; title: string; subtitle: string; firstTaskId: string | null } {
  const needing = tasks.filter((t) => !isFinishedTask(t) && taskNeedsYou(t)).sort(compareOpen);
  const count = needing.length;
  if (!count) {
    const c = progressCounts(tasks);
    const working = c.inProgress + c.inReview;
    const subtitle = !tasks.length
      ? ''
      : working
        ? `${working} ticket${working === 1 ? ' is' : 's are'} moving`
        : c.ready
          ? `${c.ready} ticket${c.ready === 1 ? '' : 's'} waiting for a worker`
          : 'Every ticket is finished';
    return { count, title: 'Nothing needs you', subtitle, firstTaskId: null };
  }
  const first = needing[0];
  const ask = ticketAsk(first) || 'answer';
  const dependent = dependentsOf(tasks, first.task_id)[0];
  const subtitle = `${ASK_VERBS[ask]} ${keyFor(keys, first.task_id)}${dependent ? `, then ${keyFor(keys, dependent.task_id)} can ship` : ''}`;
  return { count, title: `${count} ticket${count === 1 ? ' needs' : 's need'} you`, subtitle, firstTaskId: first.task_id };
}

/* ------------------------------------------------------------------ *
 * Card details: attempts, lease, requirement changes (REQ-B4, REQ-B7)
 * ------------------------------------------------------------------ */

export interface AttemptInfo {
  no: number;
  /** The brief's attempt budget. */
  max: number;
  /** The hub stopped granting leases: the attempt budget is spent. */
  exhausted: boolean;
  label: string;
}

/**
 * `attempt_no` counts every lease, but the hub spends budget only on attempts
 * that count (not replaced, reopened, user-stopped or failed dispatches) and does
 * not send that count. So the label carries no "of N"; the warning comes from the
 * hub's own budget block.
 */
export function attemptInfo(task: Pick<TaskWire, 'attempt_no' | 'brief' | 'blocked_on'>): AttemptInfo {
  const max = Math.max(1, Number(task.brief?.budget?.max_attempts) || DEFAULT_MAX_ATTEMPTS);
  const no = Math.max(1, Number(task.attempt_no) || 1);
  const b: any = task.blocked_on;
  return { no, max, exhausted: b?.kind === 'human' && b?.reason === 'budget_exhausted', label: `Attempt ${no}` };
}

export interface LeaseClock {
  holderInstanceId: string;
  bridgeId: string;
  leftMs: number;
  /** 0..1 of the lease still left (the bar's fill). */
  fraction: number;
  hardLeftMs: number | null;
}

/** The work lease's countdown from its timestamps; never refetched to tick (REQ-L1 rules). */
export function leaseClock(task: TaskWire, nowMs: number): LeaseClock | null {
  if (normalizeTaskState(task.state) !== 'in_progress') return null;
  const lease = workLease(task);
  if (!lease?.holder_instance_id) return null;
  const granted = timestampMs(lease.confirmed_at) || timestampMs(lease.granted_at);
  // No expiry yet: the default 15 minute lease from its grant, as workLeaseHolder assumes.
  const stated = timestampMs(lease.expires_at);
  const expires = Number.isNaN(stated) ? (Number.isNaN(granted) ? nowMs : granted) + DEFAULT_LEASE_MS : stated;
  const leftMs = Math.max(0, expires - nowMs);
  const span = !Number.isNaN(granted) && expires > granted ? expires - granted : DEFAULT_LEASE_MS;
  const hard = timestampMs(lease.hard_deadline_at);
  return {
    holderInstanceId: String(lease.holder_instance_id),
    bridgeId: String(lease.bridge_id || ''),
    leftMs,
    fraction: Math.max(0, Math.min(1, leftMs / span)),
    hardLeftMs: Number.isNaN(hard) ? null : Math.max(0, hard - nowMs),
  };
}

/** "14m", "1h 5m", "45s". */
export function formatDuration(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000));
  if (s < 60) return `${s}s`;
  const m = Math.round(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  const rm = m % 60;
  if (h < 24) return rm ? `${h}h ${rm}m` : `${h}h`;
  return `${Math.floor(h / 24)}d`;
}

/** "just now", "12m ago", "1h ago", "3d ago". */
export function formatAgo(value: unknown, nowMs: number): string {
  const ms = timestampMs(value);
  if (Number.isNaN(ms)) return '';
  const diff = nowMs - ms;
  if (diff < 45_000) return 'just now';
  return `${formatDuration(diff)} ago`;
}

/**
 * The ticket's state button menu: what getTaskActions allows, and Reopen only
 * once finished. Approve never goes out against an out-of-date submission
 * (rework) or while another action is running.
 */
export function ticketStateMenu(task: TaskWire, busy: boolean): TaskActionId[] {
  if (isFinishedTask(task)) return ['reopen'];
  const { primary, more } = getTaskActions(task);
  return [...primary, ...more].filter((a) => a !== 'copy_id' && !(a === 'approve' && (isRework(task) || busy)));
}

/** True once requirements changed after the current attempt was submitted (Rework, REQ-T6). */
export function isRework(task: TaskWire): boolean {
  return Boolean(task.requirements?.checkpoint_required);
}

export interface RequirementChangeLine {
  revision: number;
  /** When the current revision was written, when known (history time, else updated_at). */
  changedAtMs: number | null;
  /** Instances that still have to read the current revision. */
  pendingReaders: string[];
  rework: boolean;
}

/**
 * The card's requirement-change line (REQ-B7): shown while a revision > 1 is
 * fresh (last 24 h), unread by a lease holder, or forces rework. The board's
 * chain payload has no history (gap G1), so the time falls back to updated_at.
 */
export function requirementChangeLine(task: TaskWire, nowMs: number, history?: RequirementRevisionEntry[] | null): RequirementChangeLine | null {
  const req = task.requirements;
  const revision = Number(req?.revision) || 0;
  if (revision <= 1) return null;
  const fromHistory = history?.find((h) => h.revision === revision)?.tsMs;
  const changedAtMs = fromHistory ?? (Number.isNaN(timestampMs(task.updated_at)) ? null : timestampMs(task.updated_at));
  const pendingReaders = (req?.acknowledgements || []).filter((a) => a?.pending && a.holder_instance_id).map((a) => String(a.holder_instance_id));
  const rework = isRework(task);
  const fresh = changedAtMs !== null && nowMs - changedAtMs <= DAY_MS;
  if (!fresh && !pendingReaders.length && !rework) return null;
  return { revision, changedAtMs, pendingReaders, rework };
}

/* ------------------------------------------------------------------ *
 * Requirement history (gap G1: preformatted text, parsed here)
 * ------------------------------------------------------------------ */

export interface RequirementSnapshot {
  goal: string;
  acceptance: string[];
}

export interface RequirementRevisionEntry {
  revision: number;
  actorKind: string;
  actorId: string;
  tsMs: number;
  reason: string;
  before: RequirementSnapshot;
  after: RequirementSnapshot;
  eventId: number | null;
}

const ENTRY_HEAD = /^Revision (\d+) — (\S*) ?(.*?) — (\d+)$/;

/**
 * Parses the hub's `requirements.history` text (newest first):
 *
 *   Revision 3 — user usr_1 — 1730000000000
 *   Reason: …
 *   Before goal: …
 *   - item
 *   After goal: …
 *   - item
 *   History event: #42
 *
 * Returns [] for empty text and null when the text does not parse, so the view
 * can show the raw text instead (G1 fallback).
 */
export function parseRequirementsHistory(text: string | null | undefined): RequirementRevisionEntry[] | null {
  const raw = typeof text === 'string' ? text.replace(/\r\n/g, '\n') : '';
  if (!raw.trim()) return [];
  const lines = raw.split('\n');
  const entries: RequirementRevisionEntry[] = [];
  let cur: RequirementRevisionEntry | null = null;
  let section: 'reason' | 'before' | 'after' | null = null;
  const push = () => {
    if (cur) entries.push(cur);
    cur = null;
    section = null;
  };
  for (const line of lines) {
    const head = ENTRY_HEAD.exec(line);
    if (head) {
      push();
      cur = {
        revision: Number(head[1]),
        actorKind: head[2] || '',
        actorId: (head[3] || '').trim(),
        tsMs: Number(head[4]),
        reason: '',
        before: { goal: '', acceptance: [] },
        after: { goal: '', acceptance: [] },
        eventId: null,
      };
      continue;
    }
    if (!cur) {
      if (line.trim()) return null;
      continue;
    }
    const entry: RequirementRevisionEntry = cur;
    if (line.startsWith('Reason: ')) {
      entry.reason = line.slice('Reason: '.length);
      section = 'reason';
    } else if (line.startsWith('Before goal: ') || line === 'Before goal:') {
      entry.before.goal = line.slice('Before goal:'.length).trim();
      section = 'before';
    } else if (line.startsWith('After goal: ') || line === 'After goal:') {
      entry.after.goal = line.slice('After goal:'.length).trim();
      section = 'after';
    } else if (line.startsWith('History event: #')) {
      const id = Number(line.slice('History event: #'.length));
      entry.eventId = Number.isFinite(id) ? id : null;
      section = null;
    } else if (line.startsWith('- ') && (section === 'before' || section === 'after')) {
      entry[section].acceptance.push(line.slice(2));
    } else if (line.trim() && section) {
      // A multi-line goal or reason continues on the next line.
      if (section === 'reason') entry.reason += `\n${line}`;
      else {
        // Prose after "- " lines means those were markdown bullets in the goal:
        // acceptance is only the trailing run of "- " lines.
        const snap = entry[section];
        if (snap.acceptance.length) snap.goal += snap.acceptance.map((a) => `\n- ${a}`).join('');
        snap.acceptance = [];
        snap.goal += `\n${line}`;
      }
    }
  }
  push();
  if (!entries.length) return null;
  return entries.sort((a, b) => b.revision - a.revision);
}

export type AcceptanceTag = 'edited' | 'new' | null;

export interface AcceptanceDiffItem {
  text: string;
  tag: AcceptanceTag;
  /** The earlier wording of an edited item. */
  previous?: string;
}

/**
 * Tags each current acceptance item against the previous revision (REQ-T4):
 * unchanged items match exactly; an unmatched item at a position the previous
 * revision also had (and did not keep) is Edited; the rest are New.
 */
export function diffAcceptance(before: readonly string[], after: readonly string[]): { items: AcceptanceDiffItem[]; removed: string[] } {
  const remaining = new Map<string, number>();
  for (const b of before) remaining.set(b, (remaining.get(b) || 0) + 1);
  const exact = after.map((a) => {
    const n = remaining.get(a) || 0;
    if (n > 0) {
      remaining.set(a, n - 1);
      return true;
    }
    return false;
  });
  const unusedBefore = before.map((b, i) => ({ b, i })).filter(({ b }) => {
    const n = remaining.get(b) || 0;
    if (n > 0) {
      remaining.set(b, n - 1);
      return true;
    }
    return false;
  });
  const usedPrev = new Set<number>();
  const items = after.map((text, i): AcceptanceDiffItem => {
    if (exact[i]) return { text, tag: null };
    const prev = unusedBefore.find((u) => u.i === i && !usedPrev.has(u.i));
    if (prev) {
      usedPrev.add(prev.i);
      return { text, tag: 'edited', previous: prev.b };
    }
    return { text, tag: 'new' };
  });
  const removed = unusedBefore.filter((u) => !usedPrev.has(u.i)).map((u) => u.b);
  return { items, removed };
}

/** Common prefix / changed middle / common suffix, for highlighting an edit ("…restarts [and bridge reinstalls]"). */
export function inlineChange(previous: string, next: string): { prefix: string; changed: string; suffix: string } {
  let p = 0;
  while (p < previous.length && p < next.length && previous[p] === next[p]) p += 1;
  let s = 0;
  while (s < previous.length - p && s < next.length - p && previous[previous.length - 1 - s] === next[next.length - 1 - s]) s += 1;
  return { prefix: next.slice(0, p), changed: next.slice(p, next.length - s), suffix: next.slice(next.length - s) };
}

/* ------------------------------------------------------------------ *
 * Replace link (gap G2)
 * ------------------------------------------------------------------ */

export const REPLACED_BY_PREFIX = 'Replaced by ticket ';
export const REPLACES_PREFIX = 'Replaces ticket ';

export function replacedByComment(newTaskId: string, newKey: string): string {
  return `${REPLACED_BY_PREFIX}${newTaskId} (${newKey}).`;
}

export function replacesComment(oldTaskId: string, oldKey: string): string {
  return `${REPLACES_PREFIX}${oldTaskId} (${oldKey}).`;
}

/** The task ids a comment text links as replacement / replaced. */
export function replacementLinks(text: string): { replacedBy: string | null; replaces: string | null } {
  const t = String(text || '');
  const by = new RegExp(`${REPLACED_BY_PREFIX}(\\S+?)(?:\\s|\\.|$)`).exec(t);
  const of = new RegExp(`${REPLACES_PREFIX}(\\S+?)(?:\\s|\\.|$)`).exec(t);
  return { replacedBy: by ? by[1] : null, replaces: of ? of[1] : null };
}

/* ------------------------------------------------------------------ *
 * Fleet table (REQ-B3)
 * ------------------------------------------------------------------ */

export type FleetSlotState = 'working' | 'reviewing' | 'idle' | 'blocked' | 'not_running' | 'coordinating';

export const FLEET_STATE_LABELS: Record<FleetSlotState, string> = {
  working: 'Working',
  reviewing: 'Working',
  idle: 'Idle',
  blocked: 'Blocked',
  not_running: 'Not running',
  coordinating: 'Coordinating',
};

export const FLEET_STATE_TONE: Record<FleetSlotState, 'info' | 'success' | 'danger' | 'neutral'> = {
  working: 'info',
  reviewing: 'info',
  idle: 'success',
  blocked: 'danger',
  not_running: 'neutral',
  coordinating: 'info',
};

export interface FleetSlot {
  /** Stable row id: the instance id, or `<agentId>-slot-<n>` for a slot nothing runs in. */
  id: string;
  instanceId: string;
  agentId: string;
  name: string;
  role: string;
  state: FleetSlotState;
  /** The ticket it works on or reviews. */
  taskId: string | null;
  /** "T-21 Bridges auto-update…" or a reason. */
  detail: string;
  /** When the current state began (lease grant), when known. */
  sinceMs: number | null;
  provider: string;
}

export interface FleetMachine {
  bridgeId: string;
  label: string;
  online: boolean;
  slots: FleetSlot[];
}

export interface FleetInputs {
  tasks: readonly TaskWire[];
  /** Chain members (chain detail): instance, agent, role, display name, runtime. */
  members: readonly any[];
  /** Fleet rows (capacity, roles, placement). */
  fleets: readonly any[];
  bridges: readonly any[];
  /** The chain's entry from /agents/live (live agents and runtime status), if loaded. */
  live?: { liveAgents?: readonly any[]; members?: readonly any[] } | null;
  coordinatorInstanceId?: string;
  keys: Map<string, string>;
  agentName: (agentId: string) => string;
  /** Instances blocked by a hub blocker (failed start), keyed by instance id. */
  blockedReasons?: Record<string, string>;
}

function memberInstance(m: any): string {
  return str(m?.agent_instance_id) || str(m?.agentInstanceId);
}

function memberAgent(m: any): string {
  return str(m?.agent_id) || str(m?.agentId);
}

function fleetAgent(f: any): string {
  return str(f?.agent_id) || str(f?.agentId);
}

function bridgeIdOf(b: any): string {
  return str(b?.bridge_id) || str(b?.bridgeId) || str(b?.id);
}

function bridgeLabelOf(b: any): string {
  return str(b?.label) || str(b?.name) || str(b?.machine_hostname) || 'Unnamed machine';
}

/** Runtime statuses of an instance that is coming up; it counts as running. */
const STARTING_RUNTIMES = new Set(['starting', 'launching', 'pending', 'booting']);

function isStartingRuntime(runtime: string): boolean {
  return STARTING_RUNTIMES.has(runtime.toLowerCase());
}

function isLiveRuntime(runtime: string): boolean {
  const r = runtime.toLowerCase();
  return isAgentRunning({ state: r }) || r === 'running' || r === 'idle' || r === 'busy' || isStartingRuntime(r);
}

function isFailedRuntime(runtime: string): boolean {
  const r = runtime.toLowerCase();
  return r === 'failed' || r === 'blocked' || r === 'startup_failed' || r === 'startup_blocked' || r === 'unreachable';
}

/** Placement of a fleet row: the hub-resolved effective bridge, else its pin. */
function fleetBridge(f: any): string {
  return str(f?.effective?.bridge_id) || str(f?.bridge_id) || str(f?.bridgeId);
}

/**
 * One row per agent slot, grouped by machine (REQ-B3). Running instances come
 * from the chain members; each fleet row's unused capacity adds "Not running"
 * slots the hub starts when needed. A slot's machine is the bridge of its lease,
 * else its fleet row's placement. Offline machines keep their slots (the view
 * collapses them) and every slot on them reads Not running.
 */
export function buildFleetMachines(input: FleetInputs): FleetMachine[] {
  const { tasks, members, fleets, bridges, live, coordinatorInstanceId = '', keys, agentName, blockedReasons = {} } = input;
  const runtimeByInstance = new Map<string, string>();
  for (const m of live?.members || []) {
    const id = memberInstance(m);
    if (id) runtimeByInstance.set(id, str(m?.runtimeStatus) || str(m?.runtime_status) || (m?.isLive || m?.is_live ? 'live' : ''));
  }
  for (const a of live?.liveAgents || []) {
    const id = memberInstance(a);
    if (id) runtimeByInstance.set(id, str(a?.runtimeStatus) || str(a?.runtime_status) || 'live');
  }

  // What each instance is doing, from the leases on open tickets.
  const workOf = new Map<string, { taskId: string; bridgeId: string; sinceMs: number | null; reviewing: boolean }>();
  for (const t of tasks) {
    if (isFinishedTask(t)) continue;
    const w = workLease(t);
    if (w?.holder_instance_id) {
      const since = timestampMs(w.confirmed_at) || timestampMs(w.granted_at);
      workOf.set(String(w.holder_instance_id), { taskId: t.task_id, bridgeId: str(w.bridge_id), sinceMs: Number.isNaN(since) ? null : since, reviewing: false });
    }
    for (const r of reviewLeases(t)) {
      const id = String(r.holder_instance_id);
      if (workOf.has(id)) continue;
      const since = timestampMs(r.confirmed_at) || timestampMs(r.granted_at);
      workOf.set(id, { taskId: t.task_id, bridgeId: str(r.bridge_id), sinceMs: Number.isNaN(since) ? null : since, reviewing: true });
    }
  }
  const titleOf = new Map(tasks.map((t) => [t.task_id, t.title] as const));
  const fleetByAgent = new Map<string, any>();
  for (const f of fleets) if (fleetAgent(f)) fleetByAgent.set(fleetAgent(f), f);
  const bridgeById = new Map<string, any>();
  for (const b of bridges) if (bridgeIdOf(b)) bridgeById.set(bridgeIdOf(b), b);

  const slots: (FleetSlot & { bridgeId: string })[] = [];
  const runningPerAgent = new Map<string, number>();
  const seen = new Set<string>();
  for (const m of members) {
    const instanceId = memberInstance(m);
    if (!instanceId || seen.has(instanceId)) continue;
    seen.add(instanceId);
    const agentId = memberAgent(m);
    const fleet = fleetByAgent.get(agentId);
    const runtime = runtimeByInstance.get(instanceId) || str(m?.runtime_status) || str(m?.runtimeStatus);
    const work = workOf.get(instanceId);
    const isCoordinator = instanceId === coordinatorInstanceId || Boolean(m?.is_coordinator || m?.isCoordinator) || str(m?.role) === 'coordinator';
    let state: FleetSlotState;
    let detail: string;
    if (blockedReasons[instanceId] || isFailedRuntime(runtime)) {
      state = 'blocked';
      detail = blockedReasons[instanceId] || 'Stopped with an error';
    } else if (work) {
      state = work.reviewing ? 'reviewing' : 'working';
      const key = keyFor(keys, work.taskId);
      detail = `${work.reviewing ? 'Reviewing ' : ''}${key} ${titleOf.get(work.taskId) || ''}`.trim();
    } else if (!isLiveRuntime(runtime) && runtime) {
      state = 'not_running';
      detail = 'Hub starts it when needed';
    } else if (isStartingRuntime(runtime)) {
      state = isCoordinator ? 'coordinating' : 'idle';
      detail = 'Starting';
    } else if (isCoordinator) {
      state = 'coordinating';
      detail = 'Watching the chain';
    } else if (!runtime) {
      state = 'not_running';
      detail = 'Hub starts it when needed';
    } else {
      state = 'idle';
      const roles: string[] = Array.isArray(fleet?.roles) ? fleet.roles.map(String) : [];
      detail = roles.includes('worker') ? 'Waiting for work' : 'Waiting for a handoff';
    }
    if (state !== 'not_running') runningPerAgent.set(agentId, (runningPerAgent.get(agentId) || 0) + 1);
    const role = isCoordinator ? 'Coordinator' : roleLabel(str(m?.role), fleet);
    slots.push({
      id: instanceId,
      instanceId,
      agentId,
      name: str(m?.display_name) || str(m?.displayName) || agentName(agentId),
      role,
      state,
      taskId: work?.taskId || null,
      detail,
      sinceMs: work?.sinceMs ?? null,
      provider: str(fleet?.effective?.provider) || str(fleet?.provider),
      bridgeId: work?.bridgeId || (fleet ? fleetBridge(fleet) : ''),
    });
  }
  // Capacity no instance fills yet: the hub starts these on demand.
  for (const f of fleets) {
    const agentId = fleetAgent(f);
    if (!agentId) continue;
    const capacity = Math.max(0, Number(f?.capacity) || 0);
    const running = runningPerAgent.get(agentId) || 0;
    const stopped = slots.filter((s) => s.agentId === agentId && s.state === 'not_running').length;
    for (let n = running + stopped; n < capacity; n += 1) {
      slots.push({
        id: `${agentId}-slot-${n}`,
        instanceId: '',
        agentId,
        name: agentName(agentId),
        role: roleLabel('', f),
        state: 'not_running',
        taskId: null,
        detail: 'Hub starts it when needed',
        sinceMs: null,
        provider: str(f?.effective?.provider) || str(f?.provider),
        bridgeId: fleetBridge(f),
      });
    }
  }

  // Agents the hub found not running mid-work (blocked_on agent_not_running):
  // their slot reads Blocked, on that ticket, since the hub's since_ms.
  for (const t of tasks) {
    const b: any = t.blocked_on;
    if (isFinishedTask(t) || !b || (b.kind !== 'agent_not_running' && b.kind !== 'dispatch')) continue;
    const agentId = str(b.agent_id) || str(t.brief?.assignee);
    const slot =
      slots.find((s) => s.agentId === agentId && s.instanceId && (s.state === 'not_running' || s.state === 'blocked')) ||
      slots.find((s) => s.agentId === agentId && (s.state === 'not_running' || s.state === 'blocked'));
    if (!slot) continue;
    const since = timestampMs(b.since_ms);
    slot.state = 'blocked';
    slot.taskId = t.task_id;
    slot.detail = `${keyFor(keys, t.task_id)} ${titleOf.get(t.task_id) || ''}`.trim();
    slot.sinceMs = Number.isNaN(since) ? null : since;
  }

  const byBridge = new Map<string, FleetMachine>();
  for (const slot of slots) {
    const { bridgeId, ...rest } = slot;
    let machine = byBridge.get(bridgeId);
    if (!machine) {
      const b = bridgeById.get(bridgeId);
      machine = {
        bridgeId,
        label: bridgeId ? (b ? bridgeLabelOf(b) : 'Unknown machine') : 'Any machine',
        online: bridgeId ? String(b?.status || '').toLowerCase() === 'online' || Boolean(b?.runtime_connected) : true,
        slots: [],
      };
      byBridge.set(bridgeId, machine);
    }
    machine.slots.push(machine.online ? rest : { ...rest, state: 'not_running', detail: 'Machine offline' });
  }
  const STATE_RANK: Record<FleetSlotState, number> = { coordinating: 0, working: 1, reviewing: 2, blocked: 3, idle: 4, not_running: 5 };
  for (const m of byBridge.values()) m.slots.sort((a, b) => STATE_RANK[a.state] - STATE_RANK[b.state] || a.name.localeCompare(b.name));
  // Online machines first (most slots first), then offline ones.
  return Array.from(byBridge.values()).sort((a, b) => Number(b.online) - Number(a.online) || b.slots.length - a.slots.length || a.label.localeCompare(b.label));
}

function roleLabel(memberRole: string, fleet: any): string {
  const roles: string[] = Array.isArray(fleet?.roles) ? fleet.roles.map(String) : [];
  const role = memberRole && memberRole !== 'member' ? memberRole : roles[0] || 'worker';
  return role.charAt(0).toUpperCase() + role.slice(1);
}

/** "2 working · 1 idle · 1 off" for the fleet heading. */
export function fleetSummary(machines: readonly FleetMachine[]): string {
  let working = 0;
  let idle = 0;
  let off = 0;
  let blocked = 0;
  for (const m of machines) {
    for (const s of m.slots) {
      if (s.state === 'working' || s.state === 'reviewing') working += 1;
      else if (s.state === 'idle') idle += 1;
      else if (s.state === 'blocked') blocked += 1;
      else if (s.state === 'not_running') off += 1;
    }
  }
  return [working ? `${working} working` : '', idle ? `${idle} idle` : '', blocked ? `${blocked} blocked` : '', off ? `${off} off` : ''].filter(Boolean).join(' · ');
}

/* ------------------------------------------------------------------ *
 * Card sentences
 * ------------------------------------------------------------------ */

export interface ContextNames {
  /** Instance display name, or null when unknown. */
  instance(instanceId: string): string | null;
  agent(agentId: string): string;
  /** Any participant id (agt_, inst_, user). */
  participant(id: string): string | null;
}

function who(names: ContextNames, id: string, fallback = 'An agent'): string {
  return (id && (names.participant(id) || names.instance(id))) || fallback;
}

/**
 * One sentence of context for a card that needs you (REQ-B4): "worker #5 handed
 * off attempt 2 · reviewer #2 approved · waiting on you".
 */
export function needsYouContext(task: TaskWire, names: ContextNames): string {
  const ask = ticketAsk(task);
  const b: any = task.blocked_on || {};
  if (ask === 'publish') return "Draft: agents can't see it until you publish it";
  if (ask === 'agent_down') return String(b.reason || 'The agent could not start');
  if (ask === 'answer') return String(b.question || blockReasonText(b.reason) || b.message || 'An agent is waiting on your answer');
  const attempt = attemptInfo(task).no;
  const parts: string[] = [];
  const author = task.brief?.assignee ? names.agent(String(task.brief.assignee)) : '';
  parts.push(`${author || 'The worker'} handed off attempt ${attempt}`);
  for (const r of task.reviews || []) {
    const id = String(r?.reviewer || r?.reviewer_instance_id || '');
    if (!id || id === 'user' || String(r?.role || '').startsWith('legacy-verify:')) continue;
    parts.push(`${who(names, id, 'A reviewer')} ${r.verdict === 'approve' ? 'approved' : 'requested changes'}`);
  }
  parts.push(isRework(task) ? 'requirements changed since' : 'waiting on you');
  return parts.join(' · ');
}

/** "Starts after T-21 · any worker" for a ticket that is up next. */
export function upNextContext(task: TaskWire, keys: Map<string, string>, tasks: readonly TaskWire[], names: ContextNames): string {
  const open = new Set(tasks.filter((t) => !isFinishedTask(t)).map((t) => t.task_id));
  const waits = (task.depends_on || []).filter((d) => open.has(d)).map((d) => keyFor(keys, d));
  const worker = task.brief?.assignee ? names.agent(String(task.brief.assignee)) : 'any worker';
  if (isDraft(task)) return `Draft · ${worker}`;
  if (waits.length) return `Starts after ${waits.join(', ')} · ${worker}`;
  return `Ready for ${worker}`;
}
