
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
