// Task System v2 wire types (M2). Mirrors Simple_Task_Wire / Task_Detail_Wire in
// src/hub/transport/http/taskchain_handlers.odin. Legacy fields (status, votes,
// allowed_transitions, …) stay optional so the M4 board rework can drop them
// without a flag day. `brief` and `blocked_on` are stored verbatim by the hub —
// keep them loose on purpose.

export type TaskState = 'draft' | 'ready' | 'in_progress' | 'in_review' | 'blocked' | 'done' | 'cancelled' | string;

export interface TaskBriefBudgetWire {
  max_attempts?: number;
  hard_deadline?: string;
}

export interface TaskBriefWire {
  goal?: string;
  acceptance?: string[];
  verify?: string;
  inputs?: unknown[];
  review_roles?: string[];
  /** Agents named as reviewers of THIS task (hybrid review model). */
  reviewers?: string[];
  assignee?: string;
  budget?: TaskBriefBudgetWire;
  output?: Record<string, unknown>;
  auto_submit?: boolean;
  [extra: string]: unknown;
}

export interface TaskBlockedOnWire {
  kind?: string;
  ref?: string;
  reason?: string;
  [extra: string]: unknown;
}

export interface TaskLeaseWire {
  lease_id: string;
  kind: string;
  review_role: string;
  holder_instance_id: string;
  attempt_no: number;
  bridge_id: string;
  granted_at: string;
  confirmed_at: string;
  expires_at: string;
  hard_deadline_at: string;
  delivery: string;
}

/** One reviewer's verdict on the task's current attempt (per review role). */
export interface TaskReviewWire {
  /** Agent id of an agent/coordinator reviewer, or 'user' for you. */
  reviewer: string;
  reviewer_kind: string;
  reviewer_instance_id: string;
  role: string;
  verdict: 'approve' | 'request_changes' | string;
  created_at: string;
}

export interface TaskWire {
  /** Where a done task's worktree branch is (Task System v2 F5). */
  merge?: { state: 'none' | 'pending' | 'merged' | 'conflict' | 'failed'; detail?: string; head?: string };
  task_id: string;
  chain_id: string;
  title: string;
  description?: string;
  publish_state: string;
  state: TaskState;
  kind: string;
  priority: string;
  attempt_no: number;
  bridge_id: string;
  brief: TaskBriefWire | null;
  blocked_on: TaskBlockedOnWire | null;
  requires_user_approval: boolean;
  ready_since: string;
  workflow_run_id?: string;
  workflow_execution_no?: number;
  stage_key?: string;
  stage_index?: number;
  blocked?: boolean;
  unblocks_dependents?: boolean;
  depends_on?: string[];
  comment_summary?: {
    count: number;
    last_comment_at: string;
    last_comment_author_agent_instance_id: string;
    last_comment_preview: string;
  };
  leases?: TaskLeaseWire[];
  reviews?: TaskReviewWire[];
  created_at?: string;
  updated_at?: string;
  started_at?: string;
  completed_at?: string;
  // ---- legacy (pre-v2) fields, optional until M4 removes their readers ----
  status?: string;
  assignee_ref?: any;
  reviewer_refs?: any[];
  votes?: any[];
  participants?: any[];
  allowed_transitions?: string[];
  allowed_actions?: string[];
  next_states?: string[];
  not_actionable_reason?: string;
  acceptance_criteria?: string;
  [extra: string]: unknown;
}

// 422 `brief_incomplete` details from POST …/publish (task or chain).
export interface BriefIncompleteDetails {
  code: 'brief_incomplete';
  tasks: Array<{ task_id: string; missing: string[] }>;
}
