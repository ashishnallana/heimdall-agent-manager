// Task System v2 (M2): pure helpers for the task brief — the create-modal payload
// builder, client-side validation that mirrors the hub's single publish
// validator (taskv2.brief_publish_missing: a goal and at least one acceptance
// item, nothing else; REQ-TV2-2),
// and the wording of a 422 `brief_incomplete` publish error.
//
// Deliberately free of ANY import so it loads under plain `node --test`
// (see tests/ui_task_brief_test.ts).

import type { BriefIncompleteDetails, TaskBriefWire } from '../api/taskWire';

export const BRIEF_GOAL_MAX = 2000;
export const BRIEF_ACCEPTANCE_MAX = 20;
export const BRIEF_ACCEPTANCE_ITEM_MAX = 200;

export interface TaskBriefFormInput {
  goal: string;
  /** One acceptance item per line (blank lines ignored). */
  acceptanceText: string;
  /** Comma / newline separated review roles. */
  reviewRolesText?: string;
  /** Durable agent template id (agt_…) or ''. */
  assignee?: string;
  /** Optional output contract. Never required to publish. */
  output?: Record<string, unknown>;
}

export interface TaskBriefBuildResult {
  brief: TaskBriefWire;
  /** Human-readable problems, empty when the brief is publishable. */
  errors: string[];
  /** Hub-style missing keys: goal | acceptance. */
  missing: string[];
}

export function parseLineList(text: string | undefined | null): string[] {
  return String(text ?? '')
    .split(/\r?\n/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

export function parseCommaList(text: string | undefined | null): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const raw of String(text ?? '').split(/[,\n]/)) {
    const s = raw.trim();
    if (!s || seen.has(s)) continue;
    seen.add(s);
    out.push(s);
  }
  return out;
}

/**
 * Build the `brief` object for a task create/patch body and validate it the way
 * the hub will at publish time. Review-role fleet coverage is hub-only (it
 * needs the chain's fleet rows) and is NOT checked here.
 */
export function buildTaskBrief(input: TaskBriefFormInput): TaskBriefBuildResult {
  const goal = String(input.goal ?? '').trim();
  const acceptance = parseLineList(input.acceptanceText);
  const reviewRoles = parseCommaList(input.reviewRolesText);
  const assignee = String(input.assignee ?? '').trim();
  const hasOutput = Boolean(input.output && typeof input.output === 'object' && !Array.isArray(input.output));

  const errors: string[] = [];
  const missing: string[] = [];

  if (!goal) {
    errors.push('Goal is required.');
    missing.push('goal');
  } else if (goal.length > BRIEF_GOAL_MAX) {
    errors.push(`Goal must be at most ${BRIEF_GOAL_MAX} characters.`);
    missing.push('goal');
  }

  if (acceptance.length === 0) {
    errors.push('At least one acceptance criterion is required (one per line).');
    missing.push('acceptance');
  } else if (acceptance.length > BRIEF_ACCEPTANCE_MAX) {
    errors.push(`At most ${BRIEF_ACCEPTANCE_MAX} acceptance criteria are allowed.`);
    missing.push('acceptance');
  } else {
    const tooLong = acceptance.findIndex((a) => a.length > BRIEF_ACCEPTANCE_ITEM_MAX);
    if (tooLong >= 0) {
      errors.push(`Acceptance criterion ${tooLong + 1} exceeds ${BRIEF_ACCEPTANCE_ITEM_MAX} characters.`);
      missing.push('acceptance');
    }
  }

  const brief: TaskBriefWire = { goal, acceptance, review_roles: reviewRoles };
  if (assignee) brief.assignee = assignee;
  if (hasOutput) brief.output = input.output;

  return { brief, errors, missing };
}

export function isBriefIncompleteDetails(details: unknown): details is BriefIncompleteDetails {
  return Boolean(
    details &&
      typeof details === 'object' &&
      (details as any).code === 'brief_incomplete' &&
      Array.isArray((details as any).tasks),
  );
}

function wordMissing(key: string): string {
  if (key.startsWith('review_role:')) return `no fleet row for review role "${key.slice('review_role:'.length)}"`;
  return key;
}

/**
 * "Task <title>: missing goal, acceptance" — one line per task, titles resolved
 * from `titles` (task_id → title) with the raw task_id as the fallback.
 */
export function briefIncompleteMessage(details: BriefIncompleteDetails, titles: Record<string, string> = {}): string {
  const lines = (details.tasks || []).map((t) => {
    const label = titles[t.task_id] || t.task_id;
    const missing = (t.missing || []).map(wordMissing).join(', ') || 'brief';
    return `Task ${label}: missing ${missing}`;
  });
  return lines.length > 0 ? lines.join('\n') : 'Brief incomplete';
}

/**
 * Message for a failed publish: the brief_incomplete wording when the hub sent
 * it, otherwise the hub's own sentence. `error` is whatever cookieMutation threw
 * (an ApiError with `.details`, or a plain Error).
 */
export function publishErrorMessage(error: any, titles: Record<string, string> = {}): string {
  const details = error?.details;
  if (isBriefIncompleteDetails(details)) return briefIncompleteMessage(details, titles);
  return String(error?.message || error || 'Publish failed');
}
