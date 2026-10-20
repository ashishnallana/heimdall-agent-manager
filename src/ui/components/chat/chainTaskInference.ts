// UI-6: pure client-side inference for the task chain bound to an open agent chat.
// The current-task strip, review-needed chip, and Work tab are all derived from the
// SAME cached task list loaded via `GET /api/v1/task-chains/{chain_id}?expand=tasks`.
// No separate per-conversation "current task" endpoint is required (design doc §4A).

// Statuses that should not count toward chain progress / active task lists.
export const CHAIN_PROGRESS_EXCLUDED_STATUSES = new Set(['cancelled', 'archived', 'abandoned']);

export type TaskLike = {
  taskId?: string;
  task_id?: string;
  title?: string;
  status?: string;
  priority?: string;
  chainId?: string;
  chain_id?: string;
  assigneeAgentInstanceId?: string;
  assignee_agent_instance_id?: string;
  reviewerAgentInstanceId?: string;
  reviewer_agent_instance_id?: string;
  requiresUserApproval?: boolean;
  requires_user_approval?: boolean;
  coordinatorAgentInstanceId?: string;
  coordinator_agent_instance_id?: string;
  description?: string;
  participants?: Array<{ agentInstanceId?: string; role?: string }>;
  createdAtUnixMs?: number;
  created_at_unix_ms?: number;
  updatedAtUnixMs?: number;
  updated_at_unix_ms?: number;
  dependsOn?: string | string[];
  depends_on?: string | string[];
};

export type ChainLike = {
  chainId?: string;
  chain_id?: string;
  title?: string;
  status?: string;
  kind?: string;
  coordinatorAgentInstanceId?: string;
  coordinator_agent_instance_id?: string;
  defaultReviewerAgentInstanceId?: string;
  default_reviewer_agent_instance_id?: string;
};

export function chainIdOfTask(task: TaskLike | null | undefined): string {
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  return String(task?.chainId || task?.chain_id || '');
}

export function taskStatusOf(task: TaskLike | null | undefined): string {
  return String(task?.status || '');
}

export function taskAssigneeOf(task: TaskLike | null | undefined): string {
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  return String(
    task?.assigneeAgentInstanceId ||
    task?.assignee_agent_instance_id ||
    (task as any)?.assigneeRef?.agentInstanceId ||
    (task as any)?.assignee_ref?.agent_instance_id ||
    (task as any)?.assigneeRef?.agent_instance_id ||
    (task as any)?.assignee_ref?.agentInstanceId ||
    ''
  );
}

export function taskReviewerOf(task: TaskLike | null | undefined): string {
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  return String(
    task?.reviewerAgentInstanceId ||
    task?.reviewer_agent_instance_id ||
    (task as any)?.reviewerRefs?.[0]?.agentInstanceId ||
    (task as any)?.reviewer_refs?.[0]?.agent_instance_id ||
    (task as any)?.reviewerRefs?.[0]?.agent_instance_id ||
    (task as any)?.reviewer_refs?.[0]?.agentInstanceId ||
    (task as any)?.reviewerRefs?.[0]?.agentId ||
    (task as any)?.reviewer_refs?.[0]?.agent_id ||
    (task as any)?.reviewerRefs?.[0]?.agent_id ||
    (task as any)?.reviewer_refs?.[0]?.agentId ||
    ''
  );
}

export function taskCreatedMs(task: TaskLike | null | undefined): number {
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  return Number(task?.createdAtUnixMs || task?.created_at_unix_ms || task?.updatedAtUnixMs || task?.updated_at_unix_ms || 0);
}

// Is the current user/operator an effective reviewer for this task?
export function isUserEffectiveReviewer(task: TaskLike | null | undefined): boolean {
  if (!task) return false;
  return Boolean(task.requiresUserApproval ?? task.requires_user_approval);
}

// Is this agent instance an effective reviewer for this task?
export function isInstanceEffectiveReviewer(task: TaskLike | null | undefined, agentInstanceId: string): boolean {
  if (!task || !agentInstanceId) return false;
  if (taskReviewerOf(task) === agentInstanceId) return true;
  return (task.participants || []).some((p) => String(p?.agentInstanceId || '') === agentInstanceId && (p?.role === 'lgtm_required' || p?.role === 'lgtm_optional'));
}

export function isInstanceCoordinatorOf(chain: ChainLike | null | undefined, agentInstanceId: string): boolean {
  if (!chain || !agentInstanceId) return false;
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  return String(chain?.coordinatorAgentInstanceId || chain?.coordinator_agent_instance_id || '') === agentInstanceId;
}

export type CurrentTaskPick = {
  task: TaskLike;
  role: 'assignee' | 'reviewer' | 'coordinator' | 'assigned' | 'observer';
};

export type ChainProgressInfo = {
  total: number;
  completed: number;
  inProgress: number;
  reviewReady: number;
};
