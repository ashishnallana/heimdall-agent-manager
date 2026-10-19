package domain

// A run executes one immutable workflow definition inside a permanent chain.
// The chain owns the coordinator, fleet and directories. Retries add execution
// generations; they never rewrite an earlier execution's tasks or outputs.
Workflow_Run_ID :: distinct string

Workflow_Run :: struct {
	run_id:               Workflow_Run_ID,
	chain_id:             Task_Chain_ID,
	owner_user_id:        User_ID,
	title:                string,
	definition_ref:       string,
	spec_json:            string,
	inputs_json:          string,
	current_execution_no: int,
	request_id:           string,
	request_hash:         string,
	created_by_kind:      string,
	created_by_id:        string,
	created_at:           string,
	updated_at:           string,
	revision:             i64,
}

// State vocabulary is shared by persistence and future engine/wire adapters.
WORKFLOW_EXECUTION_DRAFT :: "draft"
WORKFLOW_EXECUTION_PENDING :: "pending"
WORKFLOW_EXECUTION_RUNNING :: "running"
WORKFLOW_EXECUTION_SUCCEEDED :: "succeeded"
WORKFLOW_EXECUTION_FAILED :: "failed"
WORKFLOW_EXECUTION_CANCELLED :: "cancelled"

Workflow_Run_Execution :: struct {
	run_id:               Workflow_Run_ID,
	execution_no:         int,
	chain_id:             Task_Chain_ID,
	owner_user_id:        User_ID,
	state:                string,
	resolved_inputs_json: string,
	started_at:           string,
	ended_at:             string,
	failure_code:         string,
	failure_detail:       string,
	output_manifest_json: string,
	revision:             i64,
}

// Written once after expansion, including a successful zero-item fan-out.
// Stage status otherwise folds from this generation's generated task events.
Workflow_Stage_Execution :: struct {
	run_id:        Workflow_Run_ID,
	execution_no:  int,
	stage_key:     string,
	chain_id:      Task_Chain_ID,
	owner_user_id: User_ID,
	item_count:    int,
	expanded_at:   string,
}

Workflow_Run_Event :: struct {
	event_id:      i64,
	run_id:        Workflow_Run_ID,
	execution_no:  int,
	chain_id:      Task_Chain_ID,
	owner_user_id: User_ID,
	ts_ms:         i64,
	actor_kind:    string,
	actor_id:      string,
	kind:          string,
	payload_json:  string,
}
