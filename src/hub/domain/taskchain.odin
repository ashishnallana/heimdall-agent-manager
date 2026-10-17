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

// Task_State is the human-facing ticket state (Task System v2). Exactly five
// stored states plus Cancelled; everything else (blocked, lease expiring,
// awaiting approval, …) is a BADGE derived from events/leases, never a state.
//
// `ready ⇔ published ∧ deps done ∧ blocked_on = null ∧ no work lease ∧ kind = task`.
// The column `tasks.state` is a cached projection of the fold over task_events
// (see service/taskv2/fold.odin); it is property-tested against the fold.
Task_State :: enum {
	Backlog,
	Ready,
	In_Progress,
	In_Review,
	Done,
	Cancelled,
}

task_state_string :: proc(state: Task_State) -> string {
	switch state {
	case .Backlog: return "backlog"
	case .Ready: return "ready"
	case .In_Progress: return "in_progress"
	case .In_Review: return "in_review"
	case .Done: return "done"
	case .Cancelled: return "cancelled"
	}
	return "backlog"
}

task_state_from_string :: proc(value: string) -> (Task_State, bool) {
	switch value {
	case "backlog": return .Backlog, true
	case "ready": return .Ready, true
	case "in_progress": return .In_Progress, true
	case "in_review": return .In_Review, true
	case "done": return .Done, true
	case "cancelled": return .Cancelled, true
	}
	return .Backlog, false
}

// task_state_is_terminal: Done and Cancelled are the two terminal ticket states.
task_state_is_terminal :: proc(state: Task_State) -> bool {
	return state == .Done || state == .Cancelled
}

// task_state_unblocks_dependents: a dependency is satisfied once the task it
// points at is Done or Cancelled (a cancelled prerequisite does not hold its
// dependents hostage; the human decided it is out of scope).
task_state_unblocks_dependents :: proc(state: Task_State) -> bool {
	return task_state_is_terminal(state)
}

// Task_Kind: `task` is granted to workers; `gate` is a human approval point in a
// workflow chain — it is never granted, is materialised directly into in_review
// and is resolved only by the human verbs.
Task_Kind :: enum {
	Task,
	Gate,
}

task_kind_string :: proc(kind: Task_Kind) -> string {
	switch kind {
	case .Task: return "task"
	case .Gate: return "gate"
	}
	return "task"
}

task_kind_from_string :: proc(value: string) -> Task_Kind {
	if value == "gate" do return .Gate
	return .Task
}

// Chain kinds (Task System v2 §0). `team_work` is the pre-v2 default and is
// accepted as an alias for `ticket` at the create boundary only.
CHAIN_KIND_TICKET :: "ticket"
CHAIN_KIND_WORKFLOW :: "workflow"
// CHAIN_KIND_PRIVATE_CONVERSATION labels the per-instance chat chain the agent
// service creates; the engine treats it exactly like a ticket chain.
CHAIN_KIND_PRIVATE_CONVERSATION :: "private_conversation"

// normalize_chain_kind maps the accepted spellings onto the stored vocabulary.
// Returns ok=false for an unknown kind so the caller can reject it.
normalize_chain_kind :: proc(kind: string) -> (string, bool) {
	switch kind {
	case "", "ticket", "team_work": return CHAIN_KIND_TICKET, true
	case "workflow": return CHAIN_KIND_WORKFLOW, true
	case "private_conversation": return CHAIN_KIND_PRIVATE_CONVERSATION, true
	}
	return "", false
}

// Task_Priority orders tasks within the matcher's ready queue. Lower ordinal =
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
	// kind ∈ {ticket, workflow}. See CHAIN_KIND_*.
	kind:                          string,
	coordinator_agent_instance_id: string,
	// Workflow chains (M3b): the definition reference and the immutable snapshot
	// `(def_id, version, inputs)` written once at `workflow.run`.
	workflow_def_ref:              string,
	workflow_snapshot_json:        string,
	// defaults_json: chain-level brief defaults (e.g. auto_submit), JSON object.
	defaults_json:                 string,
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

// TASK_MAX_ATTEMPTS is the default budget (`brief.budget.max_attempts`): counting
// attempts beyond it send the task to backlog · blocked_on human.
TASK_MAX_ATTEMPTS :: 5

Task :: struct {
	task_id:                Task_ID,
	chain_id:               Task_Chain_ID,
	owner_user_id:          User_ID,
	title:                  string,
	description:            string,
	publish_state:          Publish_State,
	// state is the cached fold projection (see Task_State).
	state:                  Task_State,
	kind:                   Task_Kind,
	priority:               Task_Priority,
	// attempt_no is the current attempt (0 until the first work lease is granted).
	attempt_no:             int,
	// brief_json: the task brief (goal, acceptance[], verify, inputs[],
	// review_roles[], assignee?, budget{…}, auto_submit, …) as a JSON object.
	brief_json:             string,
	// blocked_on_json: `{"kind": "human"|"task"|"bridge"|…, "ref": …, "reason": …,
	// "since": ts}` while the task sits in backlog with the blocked badge; "" when
	// not blocked.
	blocked_on_json:        string,
	requires_user_approval: bool,
	// ready_since: timestamp of the last transition into `ready` (drives the
	// ready_unclaimed alert); "" otherwise.
	ready_since:            string,
	// bridge_id pins which bridge instantiates this task's workers (REQ-TB-1).
	// Empty = inherit: resolved at grant time task pin → fleet row → chain
	// directory → coordinator bridge. A pin edit is a brief edit (409 while leased).
	bridge_id:              string,
	// stage_key/stage_index: workflow materialisation identity, UNIQUE per chain.
	stage_key:              string,
	stage_index:            int,
	// generated_by_json: provenance only (never a dependency kind).
	generated_by_json:      string,
	created_at:             string,
	updated_at:             string,
	published_at:           string,
	started_at:             string,
	completed_at:           string,
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

Task_Dependency :: struct {
	task_id:            Task_ID,
	depends_on_task_id: Task_ID,
	chain_id:           Task_Chain_ID,
	owner_user_id:      User_ID,
	created_at:         string,
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

// Fleet roles (Task System v2 §4a). A fleet row is the per-(chain, template)
// placement policy; `roles_json` lists which roles the template may be granted
// for. The coordinator is NOT a fleet role (it is chain.coordinator / member role).
FLEET_ROLE_WORKER :: "worker"
FLEET_ROLE_REVIEWER :: "reviewer"
FLEET_ROLES_DEFAULT_JSON :: `["worker"]`

// fleet_role_name_valid: `worker` is the work role; every other role is a REVIEW
// role a brief can require via review_roles (`reviewer`, `security`, `ux`, …).
// Names are 1–32 chars of [a-z0-9_-] starting with a letter so they stay
// readable in badges, attention lines and `review_role:<r>` publish errors.
fleet_role_name_valid :: proc(role: string) -> bool {
	if len(role) == 0 || len(role) > 32 do return false
	for c, i in transmute([]u8)role {
		switch c {
		case 'a' ..= 'z':
		case '0' ..= '9', '_', '-':
			if i == 0 do return false
		case:
			return false
		}
	}
	return true
}

Task_Chain_Fleet :: struct {
	task_chain_id:    Task_Chain_ID,
	agent_id:         string,
	capacity:         int,
	min_warm:         int,
	// idle_ttl_seconds: armed on lease release for the released instance; fire →
	// stop[] if it still holds no lease (coordinator exempt).
	idle_ttl_seconds: int,
	bridge_models_json: string,
	// provider/model are the per-role provider selection for JIT-provisioned
	// instances. "" means inherit the standard resolution order.
	provider:   string,
	model:       string,
	// roles_json: JSON array of role strings, default ["worker"].
	roles_json: string,
	// bridge_id: where instances of this template are placed. "" = resolve via
	// chain directory → coordinator bridge.
	bridge_id:  string,
	created_at: string,
	updated_at: string,
}

task_is_workable :: proc(task: Task) -> bool {
	return task.publish_state == .Published && !task_state_is_terminal(task.state)
}
