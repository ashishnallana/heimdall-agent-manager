package main

import "core:testing"

@(test)
test_agent_reconcile_extract_hub_instances :: proc(t: ^testing.T) {
	json_payload := `{"ok":true,"data":[` +
		`{"agent_instance_id":"inst_1","runtime_status":"running"},` +
		`{"agent_instance_id":"inst_2","runtime_status":"stopped"},` +
		`{"agent_instance_id":"inst_3","runtime_status":"unreachable"},` +
		`{"agent_instance_id":"inst_4","runtime_status":"starting"}` +
		`]}`

	hub_instances, ok := bridge_agent_instance_extract_hub_instances(json_payload)
	testing.expect(t, ok, "extraction should succeed")
	defer bridge_agent_instance_delete_hub_instances(&hub_instances)

	testing.expect_value(t, len(hub_instances), 4)
	testing.expect_value(t, hub_instances["inst_1"], "running")
	testing.expect_value(t, hub_instances["inst_2"], "stopped")
	testing.expect_value(t, hub_instances["inst_3"], "unreachable")
	testing.expect_value(t, hub_instances["inst_4"], "starting")
}

@(test)
test_agent_reconcile_surviving_pty_preserved_not_stopped :: proc(t: ^testing.T) {
	hub_instances := make(map[string]string)
	defer delete(hub_instances)
	hub_instances["inst_alive_running"] = "running"
	hub_instances["inst_alive_unreach"] = "unreachable"

	pty_agents := []Pty_Host_Agent_Info{
		{instance_id = "inst_alive_running", alive = true},
		{instance_id = "inst_alive_unreach", alive = true},
	}

	plan := bridge_agent_instance_compute_reconcile_plan(pty_agents, hub_instances)
	defer bridge_agent_instance_plan_delete(&plan)

	testing.expect_value(t, len(plan.to_preserve), 2)
	testing.expect_value(t, len(plan.to_reap), 0)

	has_running := false
	has_unreach := false
	for p in plan.to_preserve {
		if p == "inst_alive_running" do has_running = true
		if p == "inst_alive_unreach" do has_unreach = true
	}
	testing.expect(t, has_running, "inst_alive_running must be preserved")
	testing.expect(t, has_unreach, "inst_alive_unreach must be preserved")
}

@(test)
test_agent_reconcile_stopped_instance_reaped :: proc(t: ^testing.T) {
	hub_instances := make(map[string]string)
	defer delete(hub_instances)
	hub_instances["inst_user_stopped"] = "stopped"

	pty_agents := []Pty_Host_Agent_Info{
		{instance_id = "inst_user_stopped", alive = true},
	}

	plan := bridge_agent_instance_compute_reconcile_plan(pty_agents, hub_instances)
	defer bridge_agent_instance_plan_delete(&plan)

	testing.expect_value(t, len(plan.to_preserve), 0)
	testing.expect_value(t, len(plan.to_reap), 1)
	testing.expect_value(t, plan.to_reap[0], "inst_user_stopped")
	testing.expect_value(t, len(plan.to_push_terminal), 1)
	testing.expect_value(t, plan.to_push_terminal[0], "inst_user_stopped")
}

@(test)
test_agent_reconcile_dead_hub_instance_pushed_terminal :: proc(t: ^testing.T) {
	hub_instances := make(map[string]string)
	defer delete(hub_instances)
	hub_instances["inst_dead_on_pty"] = "running"
	hub_instances["inst_absent_on_pty"] = "running"
	hub_instances["inst_already_stopped"] = "stopped"

	pty_agents := []Pty_Host_Agent_Info{
		{instance_id = "inst_dead_on_pty", alive = false},
	}

	plan := bridge_agent_instance_compute_reconcile_plan(pty_agents, hub_instances)
	defer bridge_agent_instance_plan_delete(&plan)

	testing.expect_value(t, len(plan.to_preserve), 0)
	testing.expect_value(t, len(plan.to_reap), 0)
	testing.expect_value(t, len(plan.to_push_terminal), 2)

	has_dead := false
	has_absent := false
	for term in plan.to_push_terminal {
		if term == "inst_dead_on_pty" do has_dead = true
		if term == "inst_absent_on_pty" do has_absent = true
	}
	testing.expect(t, has_dead, "inst_dead_on_pty must be pushed terminal")
	testing.expect(t, has_absent, "inst_absent_on_pty must be pushed terminal")
}

@(test)
test_agent_reconcile_bidirectional_convergence :: proc(t: ^testing.T) {
	hub_instances := make(map[string]string)
	defer delete(hub_instances)
	hub_instances["inst_keep"] = "running"
	hub_instances["inst_reap"] = "stopped"
	hub_instances["inst_vanished"] = "running"
	hub_instances["inst_idle_stopped"] = "stopped"

	pty_agents := []Pty_Host_Agent_Info{
		{instance_id = "sh_bash_1", alive = true},              // shell session -> ignored
		{instance_id = "other_prefix", alive = true},           // invalid prefix -> ignored
		{instance_id = "inst_keep", alive = true},              // alive, not stopped -> preserve
		{instance_id = "inst_reap", alive = true},              // alive, user stopped -> reap + push terminal
		{instance_id = "inst_dead", alive = false},             // dead -> ignored for reap/preserve
	}

	plan := bridge_agent_instance_compute_reconcile_plan(pty_agents, hub_instances)
	defer bridge_agent_instance_plan_delete(&plan)

	// Preserved: inst_keep
	testing.expect_value(t, len(plan.to_preserve), 1)
	testing.expect_value(t, plan.to_preserve[0], "inst_keep")

	// Reaped: inst_reap
	testing.expect_value(t, len(plan.to_reap), 1)
	testing.expect_value(t, plan.to_reap[0], "inst_reap")

	// Pushed terminal: inst_reap (reaped) and inst_vanished (in hub as running, absent physically)
	testing.expect_value(t, len(plan.to_push_terminal), 2)
	has_reap_term := false
	has_vanished_term := false
	for term in plan.to_push_terminal {
		if term == "inst_reap" do has_reap_term = true
		if term == "inst_vanished" do has_vanished_term = true
	}
	testing.expect(t, has_reap_term, "inst_reap must be in to_push_terminal")
	testing.expect(t, has_vanished_term, "inst_vanished must be in to_push_terminal")
}

