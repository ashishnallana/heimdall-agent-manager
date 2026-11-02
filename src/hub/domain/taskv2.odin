package domain

// Task System v2 — event-sourced engine records. Every table carries
// owner_user_id (+ an owner-immutable trigger) and none of them is in FTS.

// Task_Event is one append-only entry of a task's audit trail. Ticket state and
// badges are a FOLD over these (service/taskv2/fold.odin); the UI timeline is the
// list. payload_json is stored verbatim and never re-marshalled by the hub.
Task_Event :: struct {
	event_id:      i64,
	task_id:       Task_ID,
	chain_id:      Task_Chain_ID,
	owner_user_id: User_ID,
	ts_ms:         i64,
	// actor_kind ∈ {agent, user, hub, bridge}; actor_id is the instance id / user
	// id / "" for hub timers.
	actor_kind:    string,
	actor_id:      string,
	kind:          string,
	payload_json:  string,
}

// Task_Attempt: one row per attempt (a lease ever granted for `work`, or a
// reopen). counts_toward_budget is false for attempts whose reason was
// structural (replaced | dep_added | reopen).
Task_Attempt :: struct {
	task_id:              Task_ID,
	attempt_no:           int,
	chain_id:             Task_Chain_ID,
	owner_user_id:        User_ID,
	started_at:           string,
	ended_at:             string,
	holder_instance_id:   string,
	// outcome: "" while open; then submitted | blocked | handoff | expired |
	// cancelled | reopened | replaced …
	outcome:              string,
	counts_toward_budget: bool,
}

// Task_Attempt_Facet: a typed, versioned blob attached to an attempt by exactly
// one writer per (attempt, kind). body_json is stored VERBATIM.
Task_Attempt_Facet :: struct {
	task_id:       Task_ID,
	attempt_no:    int,
	chain_id:      Task_Chain_ID,
	owner_user_id: User_ID,
	kind:          string,
	v:             int,
	body_json:     string,
	// writer ∈ {bridge, hub, agent, user}
	writer:        string,
	written_at:    string,
}

LEASE_KIND_WORK :: "work"
LEASE_KIND_REVIEW :: "review"
LEASE_DELIVERY_WAKE :: "wake"
LEASE_DELIVERY_INLINE :: "inline"

// Task_Lease is the machine-layer work token. Invariants (DB uniques):
// holder_instance_id UNIQUE (an instance holds ≤ 1 lease), partial
// UNIQUE(task_id) WHERE kind='work'. Rows are DELETED on release; history lives
// in task_events / task_attempts.
Task_Lease :: struct {
	provider_profile:string,
	lease_id:           string,
	task_id:            Task_ID,
	chain_id:           Task_Chain_ID,
	owner_user_id:      User_ID,
	attempt_no:         int,
	holder_instance_id: string,
	kind:               string,
	review_role:        string,
	// Placement recorded at grant (task pin → fleet row → directory → coordinator).
	bridge_id:          string,
	provider:           string,
	model:              string,
	granted_at:         string,
	// confirmed_at is "" until the holder's `start-success` (wake delivery) or the
	// inline grant (lease.next); the grant_unconfirmed timer keys off it.
	confirmed_at:       string,
	// expires_at is re-armed by heartbeat, bounded by hard_deadline_at.
	expires_at:         string,
	hard_deadline_at:   string,
	last_beat_at:       string,
	delivery:           string,
	// extended_at: set once when the clock-jump rule granted the one-shot
	// hub_resume extension (plan §2.4); "" otherwise.
	extended_at:        string,
}

// Task_Review: one verdict per (attempt, role, reviewer). verdict ∈ {approve,
// request_changes}; findings_json stored verbatim.
Task_Review :: struct {
	task_id:              Task_ID,
	chain_id:             Task_Chain_ID,
	owner_user_id:        User_ID,
	attempt_no:           int,
	role:                 string,
	// reviewer_kind ∈ {agent, user}
	reviewer_kind:        string,
	reviewer_agent_id:    string,
	reviewer_instance_id: string,
	verdict:              string,
	findings_json:        string,
	created_at:           string,
}

Chain_Summary :: struct {
	chain_id:      Task_Chain_ID,
	owner_user_id: User_ID,
	body:          string,
	line_count:    int,
	version:       int,
	updated_at:    string,
}

Workflow_Definition :: struct {
	def_id:        string,
	owner_user_id: User_ID,
	name:          string,
	version:       int,
	body_json:     string,
	created_at:    string,
}
