import type { TaskReviewWire, TaskWire } from '../../api/taskWire';
import { normalizeTaskState, taskHold } from './taskV2Types';
import type { TaskNames } from './taskNames';

/**
 * Which human actions a task offers, and which one is primary (plan REQ-UI-7).
 *
 * Agents drive the work (lease, submit, review) and the Hub schedules it,
 * so there is no Start / Pause / Reconcile here. A card shows only the action
 * that matters now as a button; everything else sits in its More menu.
 */
export type TaskActionId =
  | 'publish'
  | 'answer'
  | 'approve'
  | 'request_changes'
  | 'reopen'
  | 'recheck'
  | 'hold'
  | 'release'
  | 'cancel'
  | 'copy_id';

export interface TaskActionSet {
  primary: TaskActionId[];
  more: TaskActionId[];
}

export const TASK_ACTION_LABELS: Record<TaskActionId, string> = {
  publish: 'Publish',
  answer: 'Answer',
  approve: 'Approve',
  request_changes: 'Request changes',
  reopen: 'Reopen',
  recheck: 'Re-check',
  hold: 'Hold…',
  release: 'Release hold',
  cancel: 'Cancel ticket',
  copy_id: 'Copy ticket id',
};

export function isDraft(task: TaskWire): boolean {
  return String(task.publish_state || '').toLowerCase() === 'draft';
}

function isGate(task: TaskWire): boolean {
  return task.kind === 'gate';
}

export type ReviewVerdict = 'approve' | 'request_changes';

/**
 * Each reviewer's verdict on the current attempt (`task.reviews`), keyed by
 * durable agent id, or 'user' for you (REQ-TV2-6). A legacy row whose reviewer
 * is an instance id is re-keyed through `names.durableId`. Instance ids a row
 * names (its reviewer_instance_id) are kept as aliases, not keys, so an
 * assignment that carries an instance id still finds the vote through
 * voteFor() while each reviewer is listed once. An agent holding several
 * review roles approves only when every one of its roles approved.
 * Superseded (D1) approvals are skipped: they are history, not votes.
 */
export class ReviewVoteMap extends Map<string, ReviewVerdict> {
  /** instance id → the durable key its vote is stored under. */
  readonly aliases = new Map<string, string>();
}

/**
 * Role prefix of an approval superseded when verification commands were
 * removed (D1). The migration re-keys the old vote under this role so the same
 * reviewer owes a fresh review; the row is audit history, never a current vote.
 */
export const SUPERSEDED_REVIEW_ROLE_PREFIX = 'legacy-verify:';

export function isSupersededReview(r: Pick<TaskReviewWire, 'role'> | null | undefined): boolean {
  return String(r?.role || '').startsWith(SUPERSEDED_REVIEW_ROLE_PREFIX);
}

export function reviewVotes(task: TaskWire, names?: Pick<TaskNames, 'durableId'>): ReviewVoteMap {
  const out = new ReviewVoteMap();
  for (const r of task.reviews || []) {
    if (isSupersededReview(r)) continue;
    const raw = String(r?.reviewer || '').trim();
    const inst = String(r?.reviewer_instance_id || '').trim();
    if (!raw && !inst) continue;
    const verdict: ReviewVerdict = r.verdict === 'approve' ? 'approve' : 'request_changes';
    const key = names ? names.durableId(raw || inst) : raw || inst;
    if (out.get(key) !== 'request_changes') out.set(key, verdict);
    for (const alias of [raw, inst]) if (alias && alias !== key) out.aliases.set(alias, key);
  }
  return out;
}

/**
 * Every participant id a task's review rows and assigned reviewers mention
 * (superseded rows excluded), for useLookupNames() to resolve the instance
 * ids among them before votes are matched.
 */
export function reviewParticipantIds(task: TaskWire, reviewers: readonly string[] = []): string[] {
  const out = new Set<string>(reviewers);
  for (const r of task.reviews || []) {
    if (isSupersededReview(r)) continue;
    for (const id of [r?.reviewer, r?.reviewer_instance_id]) if (id) out.add(String(id));
  }
  return Array.from(out);
}

/** The verdict for a participant id (`agt_`, `inst_` or `user`), matched by durable id. */
export function voteFor(votes: Map<string, ReviewVerdict>, id: string, names?: Pick<TaskNames, 'durableId'>): ReviewVerdict | undefined {
  const v = String(id || '').trim();
  if (!v) return undefined;
  if (votes.has(v)) return votes.get(v);
  const alias = votes instanceof ReviewVoteMap ? votes.aliases.get(v) : undefined;
  if (alias) return votes.get(alias);
  return names ? votes.get(names.durableId(v)) : undefined;
}

/** True when `id` names the same reviewer as the vote key `key` (directly, by alias or by durable id). */
export function sameReviewer(votes: ReviewVoteMap, key: string, id: string, names?: Pick<TaskNames, 'durableId'>): boolean {
  const v = String(id || '').trim();
  if (!v) return false;
  if (v === key) return true;
  if (votes.aliases.get(v) === key) return true;
  return Boolean(names && names.durableId(v) === key);
}

/** You already approved this attempt; the task may still wait on other reviewers. */
export function youApproved(task: TaskWire): boolean {
  return normalizeTaskState(task.state) === 'in_review' && reviewVotes(task).get('user') === 'approve';
}

/**
 * Waiting on a human decision: the reviewer gate is you, or a blocker asks you.
 * Once you approved, the rest is up to the other reviewers (as the hub's
 * awaits_user_review).
 */
export function awaitingYourReview(task: TaskWire): boolean {
  return normalizeTaskState(task.state) === 'in_review' && (Boolean(task.requires_user_approval) || isGate(task)) && !youApproved(task);
}

/**
 * A block only you can clear. A hold is an operator pause, not a question:
 * the hub refuses an answer while held (as its user_attention), so a held task
 * is on you only through a nested agent-not-running block (Start agent).
 */
export function blockedOnYou(task: TaskWire): boolean {
  const b: any = task.blocked_on;
  if (!b) return false;
  const agentDown = b.kind === 'agent_not_running' || b.kind === 'dispatch';
  if (taskHold(task)) return agentDown;
  return !b.kind || b.kind === 'human' || b.kind === 'user' || agentDown;
}

/** Hold (hub `task hold`): any open, published, non-gate task that is not held yet. */
export function canHold(task: TaskWire): boolean {
  const state = normalizeTaskState(task.state);
  if (state === 'done' || state === 'cancelled' || isDraft(task) || isGate(task)) return false;
  return !taskHold(task);
}

/** True when nothing moves on this task until the user acts. */
export function taskNeedsYou(task: TaskWire): boolean {
  const state = normalizeTaskState(task.state);
  if (state === 'done' || state === 'cancelled') return false;
  return isDraft(task) || blockedOnYou(task) || awaitingYourReview(task);
}

/**
 * Re-check (hub `task recheck`) recomputes the gate, readiness, dispatch and
 * merge-back. Offered where a task can look stuck without an agent working on
 * it: backlog, ready and in review, and a done task whose merge is pending or
 * failed. A task with a live work lease is left to its holder.
 */
export function canRecheck(task: TaskWire): boolean {
  if (isDraft(task)) return false;
  const state = normalizeTaskState(task.state);
  if (state === 'done') return task.merge?.state === 'pending' || task.merge?.state === 'failed';
  if (state !== 'backlog' && state !== 'ready' && state !== 'in_review') return false;
  return !(task.leases || []).some((l: any) => (l?.kind || 'work') === 'work');
}

export interface RecheckToast {
  kind: 'success' | 'info';
  title: string;
  message: string;
}

/**
 * The toast for a Re-check result: what changed, else why the task still
 * waits (every reason, so "fleet full 2/2" and "bridge offline" both show).
 */
export function recheckToast(result: { changed?: boolean; actions?: string[]; reasons?: string[]; message?: string } | null | undefined): RecheckToast {
  const actions = (result?.actions || []).filter(Boolean);
  const reasons = (result?.reasons || []).filter(Boolean);
  if (result?.changed) {
    const lines = [...actions, ...reasons.map((r) => `Still waiting: ${r}`)];
    return { kind: 'success', title: 'Re-checked: updated', message: lines.join('; ') || result.message || 'The ticket was updated.' };
  }
  return {
    kind: 'info',
    title: 'Re-checked: nothing to change',
    message: reasons.join('; ') || 'Nothing is holding this ticket that a re-check can fix.',
  };
}

export function getTaskActions(task: TaskWire): TaskActionSet {
  const state = normalizeTaskState(task.state);
  const closed = state === 'done' || state === 'cancelled';
  const primary: TaskActionId[] = [];
  const more: TaskActionId[] = [];

  if (closed) {
    more.push('reopen');
  } else if (isDraft(task)) {
    primary.push('publish');
  } else if (blockedOnYou(task) && !taskHold(task)) {
    // Held: the hub refuses an answer; a failed agent under a hold is
    // started from its attention card, and Release (below) is the way on.
    primary.push('answer');
  } else if (awaitingYourReview(task)) {
    primary.push('approve', 'request_changes');
  }
  // Nothing moves on a held task until someone releases it: always offer it up front.
  if (!closed && taskHold(task)) primary.push('release');

  if (canRecheck(task)) more.push('recheck');
  if (canHold(task)) more.push('hold');
  if (!closed && !isGate(task)) more.push('cancel');
  more.push('copy_id');
  return { primary, more };
}

export interface EditLock {
  locked: boolean;
  /** Why the assignee / reviewers / dependencies can't be changed right now. */
  reason: string;
}

/**
 * When a person may change who works on a task, who reviews it and what it
 * waits for (plan REQ-UI-11). The hub refuses these edits while an agent holds
 * the work lease, and always for workflow tasks (the run owns them).
 */
export function editLock(task: TaskWire, chainKind = ''): EditLock {
  const state = normalizeTaskState(task.state);
  if (chainKind === 'workflow' || String(task.stage_key || '').trim()) {
    return { locked: true, reason: 'Workflow tasks are set by the run and cannot be edited.' };
  }
  if (state === 'done' || state === 'cancelled') return { locked: true, reason: 'Reopen the ticket to change it.' };
  const working = (task.leases || []).some((l: any) => (l?.kind || 'work') === 'work');
  if (working || state === 'in_progress') {
    return { locked: true, reason: 'An agent is working on it. Wait, or cancel the current attempt first.' };
  }
  return { locked: false, reason: '' };
}
