package domain

Action_State :: enum {
	Active,
	In_Flight,
	Completed,
}

Action_Target_Mode :: enum {
	Instance,
	Agent,
}

Action :: struct {
	id:                 Action_ID,
	owner_user_id:      User_ID,
	target_instance_id: Agent_Instance_ID,
	prompt_text:        string,
	// Schedule fields (nullable/optional):
	cron_expr:          string, // 5-field standard cron, empty if run-only
	timezone:           string, // IANA timezone, defaults to "UTC"
	blackout_dates:     string, // JSON array of "YYYY-MM-DD" strings to skip
	active_from:        string, // ISO timestamp window start
	active_until:       string, // ISO timestamp window end
	target_run_at:      string, // Next computed fire time (ISO timestamp UTC)
	interval:           string, // Legacy interval or empty
	state:              Action_State,
	in_flight:          bool,
	leased_at:          string,
	deleted_at:         string,
	created_at:         string,
	updated_at:         string,
	// Agent targeting fields (REQ-SCHED-1):
	target_agent_id:    Agent_ID,
	target_bridge_id:   Bridge_ID,
	target_provider:    string,
	target_model:        string,
	target_project_id:  Project_ID,
	// Instance strategy for durable agent-id targets (REQ-SCHED-2):
	// "reuse" (default, legacy) reuses/wakes an existing instance of the agent-id;
	// "fresh_per_run" mints a NEW instance on every fire and reaps the previous one.
	instance_strategy:        string,
	// The instance created by the previous fresh_per_run fire, tracked so the next
	// fire can reap it once the new instance is ready. Empty for reuse actions.
	last_spawned_instance_id: Agent_Instance_ID,
}

// Valid values for Action.instance_strategy.
ACTION_INSTANCE_STRATEGY_REUSE :: "reuse"
ACTION_INSTANCE_STRATEGY_FRESH_PER_RUN :: "fresh_per_run"

// action_instance_strategy_valid reports whether s is an accepted instance_strategy.
// Empty is accepted (normalized to "reuse" at the boundary for backward compatibility).
action_instance_strategy_valid :: proc(s: string) -> bool {
	return s == "" || s == ACTION_INSTANCE_STRATEGY_REUSE || s == ACTION_INSTANCE_STRATEGY_FRESH_PER_RUN
}

action_target_mode :: proc(action: Action) -> Action_Target_Mode {
	if action.target_instance_id != "" {
		return .Instance
	}
	return .Agent
}

