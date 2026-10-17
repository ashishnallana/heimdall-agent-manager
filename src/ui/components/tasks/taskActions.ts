import type { TaskWire } from '../../api/taskWire';
import { normalizeTaskState } from './taskV2Types';

/**
 * Which human actions a task offers, and which one is primary (plan REQ-UI-7).
 *
 * Agents drive the work (lease, verify, submit, review) and the Hub schedules it,
 * so there is no Start / Pause / Reconcile here. A card shows only the action
 * that matters now as a button; everything else sits in its More menu.
 */
export type TaskActionId =
  | 'publish'
  | 'answer'
  | 'approve'
  | 'request_changes'
  | 'reopen'
  | 'cancel'
  | 'rerun_verify'
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
  cancel: 'Cancel task',
  rerun_verify: 'Re-run verify',
  copy_id: 'Copy task id',
};

export function isDraft(task: TaskWire): boolean {
  return String(task.publish_state || '').toLowerCase() === 'draft';
}

function isGate(task: TaskWire): boolean {
  return task.kind === 'gate';
}

/** Waiting on a human decision: the reviewer gate is you, or a blocker asks you. */
export function awaitingYourReview(task: TaskWire): boolean {
  return normalizeTaskState(task.state) === 'in_review' && (Boolean(task.requires_user_approval) || isGate(task));
}

export function blockedOnYou(task: TaskWire): boolean {
  const b: any = task.blocked_on;
  if (!b) return false;
  return !b.kind || b.kind === 'human' || b.kind === 'user';
}

/** True when nothing moves on this task until the user acts. */
export function taskNeedsYou(task: TaskWire): boolean {
  const state = normalizeTaskState(task.state);
  if (state === 'done' || state === 'cancelled') return false;
  return isDraft(task) || blockedOnYou(task) || awaitingYourReview(task);
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
  } else if (blockedOnYou(task)) {
    primary.push('answer');
  } else if (awaitingYourReview(task)) {
    primary.push('approve', 'request_changes');
  }

  const hasVerify = Boolean(task.brief?.verify) && String(task.brief?.verify).trim() !== 'none';
  if (!closed && hasVerify && (task.attempt_no || 0) > 0 && (state === 'in_progress' || state === 'in_review')) {
    more.push('rerun_verify');
  }
  if (!closed && !isGate(task)) more.push('cancel');
  more.push('copy_id');
  return { primary, more };
}
