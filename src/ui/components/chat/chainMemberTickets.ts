import type { TaskWire } from '../../api/taskWire';
import { awaitingYourReview } from '../tasks/taskActions';
import { normalizeTaskState } from '../tasks/taskV2Types';

/** The ticket a chain member is on right now, read from the lease it holds. */
export interface MemberCurrentTask {
  task: TaskWire;
  kind: 'work' | 'review';
  /** The review role of a review lease ('' for work). */
  reviewRole: string;
}

/**
 * holder_instance_id -> the ticket that instance holds a lease on. The hub
 * sends every live lease on the task wire (work and review), so this is what
 * each member is doing; a member with no lease has no ticket. When one
 * instance holds several leases the work lease wins, then the first review.
 */
export function buildMemberCurrentTaskMap(tasks: readonly TaskWire[]): Map<string, MemberCurrentTask> {
  const map = new Map<string, MemberCurrentTask>();
  for (const task of tasks) {
    const state = normalizeTaskState(task.state);
    if (state === 'done' || state === 'cancelled') continue;
    for (const lease of Array.isArray(task.leases) ? task.leases : []) {
      const holder = String(lease?.holder_instance_id || '');
      if (!holder) continue;
      const kind = (lease.kind || 'work') === 'review' ? 'review' : 'work';
      const existing = map.get(holder);
      if (existing && (existing.kind === 'work' || kind === 'review')) continue;
      map.set(holder, { task, kind, reviewRole: kind === 'review' ? String(lease.review_role || '') : '' });
    }
  }
  return map;
}

/** Plain-text form of a member's ticket, e.g. for a tooltip. */
export function memberTicketText(current: MemberCurrentTask | undefined): string {
  if (!current) return 'No ticket';
  const title = String(current.task.title || current.task.task_id || '');
  if (current.kind === 'work') return title;
  return `Reviewing: ${title}${current.reviewRole ? ` (${current.reviewRole})` : ''}`;
}

/** Tasks someone is on: being worked (in_progress) or reviewed (in_review). */
export function isOngoingTask(task: TaskWire): boolean {
  const state = normalizeTaskState(task.state);
  return state === 'in_progress' || state === 'in_review';
}

/**
 * In review and nothing moves until you act: you are the review gate (and
 * have not approved yet), or the task has no reviewer at all.
 */
export function isAttentionNeeded(task: TaskWire): boolean {
  if (normalizeTaskState(task.state) !== 'in_review') return false;
  return awaitingYourReview(task) || !hasReviewer(task);
}

export function attentionReason(task: TaskWire): string {
  return hasReviewer(task) ? 'Review required by you' : 'No reviewer assigned';
}

function hasReviewer(task: TaskWire): boolean {
  return Boolean(task.requires_user_approval) || (task.brief?.review_roles || []).length > 0 || task.kind === 'gate';
}

/** Instance ids holding a review lease on the task, in wire order. */
export function reviewHolders(task: TaskWire): string[] {
  return (Array.isArray(task.leases) ? task.leases : [])
    .filter((l) => l?.kind === 'review' && l.holder_instance_id)
    .map((l) => String(l.holder_instance_id));
}
