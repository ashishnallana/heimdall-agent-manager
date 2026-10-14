package domain

Publish_State :: enum {
	Draft,
	Published,
}

Task_Chain_Status :: enum {
	Active,
	Completed,
	Cancelled,
	Archived,
}

Task_Status :: enum {
	Assigned,
	// Queued marks a published, unblocked task that is eligible to run but is
	// being held back because its assignee instance is currently focused on a
	// higher-priority current task. It is distinct from Assigned (which is the
	// default not-yet-started state) and is set by the auto-promotion engine.
	Queued,
	In_Progress,
	In_Validation,
	Finishing,
	Pausing,
	Validated_Good,
	Validated_Not_Good,
	Paused,
	Completed,
	Cancelled,
}

// Task_Priority orders tasks within an instance's work queue. Lower ordinal =
// higher urgency (P0 is most urgent). New tasks default to P2.
Task_Priority :: enum {
	P0,
	P1,
	P2,
}

task_priority_string :: proc(priority: Task_Priority) -> string {
	switch priority {
	case .P0: return "p0"
	case .P1: return "p1"
	case .P2: return "p2"
	}
	return "p2"
}

task_priority_from_string :: proc(value: string) -> Task_Priority {
	switch value {
	case "p0", "P0": return .P0
	case "p1", "P1": return .P1
	case "p2", "P2": return .P2
	}
	return .P2
}

Task_Chain :: struct {
	chain_id:                      Task_Chain_ID,
	owner_user_id:                 User_ID,
	title:                         string,
	description:                   string,
	publish_state:                 Publish_State,
	status:                        Task_Chain_Status,
	kind:                          string,
	coordinator_agent_instance_id: string,
	default_reviewer_refs_json:    string,
	// Title-nudge tracking fields (persisted). See Chat_Conversation for semantics.
	last_activity_at:              string,
	last_title_nudge_at:           string,
	title_source:                  string,
	created_at:                    string,
	updated_at:                    string,
	published_at:                  string,
	completed_at:                  string,
	is_pinned:                     bool,
	pinned_at:                     string,
}

// A revisioned invalidation entry for the encrypted Bridge search document feed.
// Content is intentionally absent: the current task_chains row remains canonical.
Task_Chain_Search_Change :: struct {
	revision: i64,
	chain_id: Task_Chain_ID,
	operation: string,
}

TASK_CHAINS_MAX_PINNED :: 10


Task :: struct {
	task_id:            Task_ID,
	chain_id:           Task_Chain_ID,
	owner_user_id:      User_ID,
	title:              string,
	description:        string,
	publish_state:      Publish_State,
	status:             Task_Status,
	priority:           Task_Priority,
	assignee_ref_json:  string,
	reviewer_refs_json: string,
	// bridge_id pins which bridge instantiates this task's agent-id actors
	// (REQ-TB-1). Empty = inherit: resolved later at promotion time from the
	// chain instances / directories / owner's bridges, in that order.
	bridge_id:          string,
	created_at:         string,
	updated_at:         string,
	published_at:       string,
	started_at:         string,
	completed_at:       string,
}

Task_Comment :: struct {
	comment_id:               string,
	task_id:                  Task_ID,
	chain_id:                 Task_Chain_ID,
	owner_user_id:            User_ID,
	author_agent_instance_id: string,
	body:                     string,
	created_at:               string,
	updated_at:               string,
}

// Task_Comment_Summary is the compact comment rollup embedded on task objects so
// list/show/context can convey "there is discussion, and how recent" without
// shipping every comment body. Derived by a cheap COUNT + last-row query.
Task_Comment_Summary :: struct {
	count:                    int,    // total comments on the task
	last_comment_at:          string, // "" when count == 0
	last_comment_author:      string, // last comment's author_agent_instance_id
	last_comment_preview:     string, // first ~80 chars of the last comment body
}

// TASK_COMMENT_PREVIEW_MAX bounds the preview length (runes) in the summary.
TASK_COMMENT_PREVIEW_MAX :: 80

// Byte caps for agent-settable chain text (REQ-VCAP-1). These bound the
// PLAINTEXT; an encrypted value is checked against the inflated armored budget
// instead — see domain.validate_capped_text in vault_text_caps.odin.
CHAIN_TITLE_MAX_BYTES       :: 120
CHAIN_DESCRIPTION_MAX_BYTES :: 4000

Task_Chain_Member :: struct {
	chain_id:          Task_Chain_ID,
	agent_instance_id: string,
	agent_id:          string,
	owner_user_id:     User_ID,
	role:              string,
	created_at:        string,
}

Actor_Ref :: struct {
	type:              string `json:"type"`,
	agent_id:          string `json:"agent_id,omitempty"`,
	agent_instance_id: string `json:"agent_instance_id,omitempty"`,
	user_id:           string `json:"user_id,omitempty"`,
	username:          string `json:"username,omitempty"`,
	display_name:      string `json:"display_name,omitempty"`,
}

Task_Dependency :: struct {
	task_id:            Task_ID,
	depends_on_task_id: Task_ID,
	chain_id:           Task_Chain_ID,
	owner_user_id:      User_ID,
	created_at:         string,
}

Task_Vote :: struct {
	task_id:                    Task_ID,
	reviewer_agent_instance_id: string,
	chain_id:                   Task_Chain_ID,
	owner_user_id:              User_ID,
	vote:                       string,
	comment:                    string,
	created_at:                 string,
	updated_at:                 string,
}

Task_Chain_Directory :: struct {
	directory_id:  string,
	chain_id:      Task_Chain_ID,
	owner_user_id: User_ID,
	path:          string,
	bridge_id:     string,
	vcs_kind:      string,
	vcs_info_json: string,
	created_at:    string,
	updated_at:    string,
}

Fleet_Bridge_Model :: struct {
	provider: string,
	model: string,
}

Task_Chain_Fleet :: struct {
	task_chain_id:    Task_Chain_ID,
	agent_id:         string,
	capacity:         int,
	min_warm:         int,
	idle_ttl_seconds: int,
	bridge_models_json: string,
	// provider/model are the per-role provider selection for JIT-provisioned
	// instances. "" means inherit the standard resolution order.
	provider:   string,
	model:       string,
	created_at: string,
	updated_at: string,
}

task_status_unblocks_dependents :: proc(status: Task_Status) -> bool {
	return status == .Completed || status == .Cancelled
}

task_is_workable :: proc(task: Task) -> bool {
	return task.publish_state == .Published && task.status != .Completed && task.status != .Cancelled
}

@(private = "file", rodata)
TASK_TRANSITIONS_ASSIGNED := [4]Task_Status{.Queued, .In_Progress, .Paused, .Cancelled}
@(private = "file", rodata)
TASK_TRANSITIONS_QUEUED := [4]Task_Status{.Assigned, .In_Progress, .Paused, .Cancelled}
@(private = "file", rodata)
TASK_TRANSITIONS_IN_PROGRESS := [5]Task_Status{.Queued, .In_Validation, .Pausing, .Paused, .Cancelled}
@(private = "file", rodata)
TASK_TRANSITIONS_IN_VALIDATION := [6]Task_Status{.Validated_Good, .Validated_Not_Good, .Finishing, .Completed, .Paused, .Cancelled}
@(private = "file", rodata)
TASK_TRANSITIONS_FINISHING := [6]Task_Status{.Completed, .In_Validation, .In_Progress, .Pausing, .Paused, .Cancelled}
@(private = "file", rodata)
TASK_TRANSITIONS_PAUSING := [4]Task_Status{.Paused, .In_Progress, .Cancelled, .Assigned}
@(private = "file", rodata)
TASK_TRANSITIONS_VALIDATED_NOT_GOOD := [3]Task_Status{.In_Progress, .Paused, .Cancelled}
@(private = "file", rodata)
TASK_TRANSITIONS_VALIDATED_GOOD := [3]Task_Status{.Completed, .Paused, .Cancelled}
@(private = "file", rodata)
TASK_TRANSITIONS_PAUSED := [3]Task_Status{.In_Progress, .Assigned, .Cancelled}
@(private = "file", rodata)
TASK_TRANSITIONS_CANCELLED := [1]Task_Status{.Assigned}
@(private = "file", rodata)
TASK_TRANSITIONS_COMPLETED := [3]Task_Status{.Assigned, .In_Progress, .In_Validation}
@(private = "file", rodata)
TASK_TRANSITIONS_DEGRADED := [3]Task_Status{.Assigned, .Queued, .Cancelled}

task_allowed_transitions :: proc(status: Task_Status) -> []Task_Status {
	switch status {
	case .Assigned:
		return TASK_TRANSITIONS_ASSIGNED[:]
	case .Queued:
		return TASK_TRANSITIONS_QUEUED[:]
	case .In_Progress:
		return TASK_TRANSITIONS_IN_PROGRESS[:]
	case .In_Validation:
		return TASK_TRANSITIONS_IN_VALIDATION[:]
	case .Finishing:
		return TASK_TRANSITIONS_FINISHING[:]
	case .Pausing:
		return TASK_TRANSITIONS_PAUSING[:]
	case .Validated_Not_Good:
		return TASK_TRANSITIONS_VALIDATED_NOT_GOOD[:]
	case .Validated_Good:
		return TASK_TRANSITIONS_VALIDATED_GOOD[:]
	case .Paused:
		return TASK_TRANSITIONS_PAUSED[:]
	case .Cancelled:
		return TASK_TRANSITIONS_CANCELLED[:]
	case .Completed:
		return TASK_TRANSITIONS_COMPLETED[:]
	}
	return TASK_TRANSITIONS_DEGRADED[:]
}

@(private = "file", rodata)
TASK_ACTIONS_ASSIGNED_OR_QUEUED := [4]string{"start", "pause", "cancel", "nudge"}
@(private = "file", rodata)
TASK_ACTIONS_IN_PROGRESS := [4]string{"validate", "pause", "cancel", "nudge"}
@(private = "file", rodata)
TASK_ACTIONS_IN_VALIDATION := [5]string{"lgtm", "ngtm", "pause", "cancel", "nudge"}
@(private = "file", rodata)
TASK_ACTIONS_FINISHING := [5]string{"complete", "revalidate", "pause", "cancel", "nudge"}
@(private = "file", rodata)
TASK_ACTIONS_PAUSING := [4]string{"pause", "start", "cancel", "nudge"}
@(private = "file", rodata)
TASK_ACTIONS_VALIDATED_NOT_GOOD := [4]string{"start", "pause", "cancel", "nudge"}
@(private = "file", rodata)
TASK_ACTIONS_VALIDATED_GOOD := [3]string{"complete", "pause", "cancel"}
@(private = "file", rodata)
TASK_ACTIONS_PAUSED := [2]string{"unpause", "cancel"}
@(private = "file", rodata)
TASK_ACTIONS_CANCELLED := [1]string{"uncancel"}
@(private = "file", rodata)
TASK_ACTIONS_COMPLETED := [2]string{"not_complete", "revalidate"}
@(private = "file", rodata)
TASK_ACTIONS_DEGRADED := [5]string{"restart", "restart_worker", "reset_to_assigned", "retry", "cancel"}

task_allowed_actions :: proc(status: Task_Status) -> []string {
	switch status {
	case .Assigned, .Queued:
		return TASK_ACTIONS_ASSIGNED_OR_QUEUED[:]
	case .In_Progress:
		return TASK_ACTIONS_IN_PROGRESS[:]
	case .In_Validation:
		return TASK_ACTIONS_IN_VALIDATION[:]
	case .Finishing:
		return TASK_ACTIONS_FINISHING[:]
	case .Pausing:
		return TASK_ACTIONS_PAUSING[:]
	case .Validated_Not_Good:
		return TASK_ACTIONS_VALIDATED_NOT_GOOD[:]
	case .Validated_Good:
		return TASK_ACTIONS_VALIDATED_GOOD[:]
	case .Paused:
		return TASK_ACTIONS_PAUSED[:]
	case .Cancelled:
		return TASK_ACTIONS_CANCELLED[:]
	case .Completed:
		return TASK_ACTIONS_COMPLETED[:]
	}
	return TASK_ACTIONS_DEGRADED[:]
}

@(private = "file", rodata)
TASK_RECOVERY_ACTIONS_IN_PROGRESS := [5]string{"restart_worker", "reset_to_assigned", "retry", "pause", "cancel"}
@(private = "file", rodata)
TASK_RECOVERY_ACTIONS_IN_VALIDATION := [5]string{"restart_worker", "reset_to_assigned", "retry", "pause", "cancel"}
@(private = "file", rodata)
TASK_RECOVERY_ACTIONS_FINISHING := [5]string{"restart_worker", "reset_to_assigned", "retry", "pause", "cancel"}
@(private = "file", rodata)
TASK_RECOVERY_ACTIONS_PAUSING := [5]string{"restart_worker", "reset_to_assigned", "retry", "pause", "cancel"}
@(private = "file", rodata)
TASK_RECOVERY_ACTIONS_STANDARD := [4]string{"restart", "reset_to_assigned", "retry", "cancel"}
@(private = "file", rodata)
TASK_RECOVERY_ACTIONS_PAUSED := [4]string{"unpause", "reset_to_assigned", "retry", "cancel"}
@(private = "file", rodata)
TASK_RECOVERY_ACTIONS_CANCELLED := [3]string{"uncancel", "reset_to_assigned", "retry"}
@(private = "file", rodata)
TASK_RECOVERY_ACTIONS_COMPLETED := [3]string{"revalidate", "not_complete", "reset_to_assigned"}

task_recovery_actions :: proc(status: Task_Status) -> []string {
	switch status {
	case .In_Progress:
		return TASK_RECOVERY_ACTIONS_IN_PROGRESS[:]
	case .In_Validation:
		return TASK_RECOVERY_ACTIONS_IN_VALIDATION[:]
	case .Finishing:
		return TASK_RECOVERY_ACTIONS_FINISHING[:]
	case .Pausing:
		return TASK_RECOVERY_ACTIONS_PAUSING[:]
	case .Assigned, .Queued, .Validated_Not_Good, .Validated_Good:
		return TASK_RECOVERY_ACTIONS_STANDARD[:]
	case .Paused:
		return TASK_RECOVERY_ACTIONS_PAUSED[:]
	case .Cancelled:
		return TASK_RECOVERY_ACTIONS_CANCELLED[:]
	case .Completed:
		return TASK_RECOVERY_ACTIONS_COMPLETED[:]
	}
	return TASK_ACTIONS_DEGRADED[:]
}

task_degraded_recovery_actions :: proc() -> []string {
	return TASK_ACTIONS_DEGRADED[:]
}

task_degraded_recovery_transitions :: proc() -> []Task_Status {
	return TASK_TRANSITIONS_DEGRADED[:]
}

