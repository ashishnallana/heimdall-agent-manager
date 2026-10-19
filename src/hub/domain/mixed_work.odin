package domain

WORK_ITEM_TASK :: "task"
WORK_ITEM_WORKFLOW_RUN :: "workflow_run"

// External dependencies address ordinary tickets or whole runs, never a
// generated stage task. Internal workflow dependencies remain engine-owned.
Work_Item_Ref :: struct {
	kind: string,
	id:   string,
}

Work_Dependency :: struct {
	dependency_id:  string,
	chain_id:       Task_Chain_ID,
	owner_user_id:  User_ID,
	dependent:      Work_Item_Ref,
	prerequisite:   Work_Item_Ref,
	created_by_kind: string,
	created_by_id:   string,
	created_at:      string,
	// Removal retains the original edge as provenance. Re-adding creates a
	// new edge. Only one active edge may join the same two endpoints.
	removed_at:      string,
	removed_by_kind: string,
	removed_by_id:   string,
	removal_reason:  string,
}

// A receipt freezes what a consumer actually used at start. Generation means
// task attempt_no for a ticket, execution_no for a run. It outlives changes to
// the dependency graph, cancelled consumers and later attempts/executions.
Work_Input_Receipt :: struct {
	receipt_id:              string,
	chain_id:                Task_Chain_ID,
	owner_user_id:           User_ID,
	dependent:               Work_Item_Ref,
	dependent_generation:    int,
	prerequisite:            Work_Item_Ref,
	prerequisite_generation: int,
	output_manifest_json:    string,
	created_at:              string,
}

Work_Scope_Decision :: struct {
	decision_id:   i64,
	chain_id:      Task_Chain_ID,
	owner_user_id: User_ID,
	item:          Work_Item_Ref,
	action:        string, // include | exclude; never changes dependency success
	reason:        string,
	actor_kind:    string,
	actor_id:      string,
	created_at:    string,
}
