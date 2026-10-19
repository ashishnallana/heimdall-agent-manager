package main

import "core:strings"
import "core:testing"

// Mixed-work CLI surface (plan item 2): typed refs for `task depend`, the
// --depends-on normalizer, and agent-mode routing of the chain-level graph verbs
// through the authenticated agent.work.* Bridge methods.

@(test)
test_task_depend_target_typed_refs :: proc(t: ^testing.T) {
	kind, id, msg := ctl_task_depend_target("task_b")
	testing.expect(t, kind == .Task && id == "task_b" && msg == "", "bare id is a ticket prerequisite")
	kind, id, _ = ctl_task_depend_target(" task:task_b ")
	testing.expect(t, kind == .Task && id == "task_b", "task:<id> strips the kind")
	kind, id, _ = ctl_task_depend_target("workflow_run:wrun_1")
	testing.expect(t, kind == .Workflow_Run && id == "wrun_1", "workflow_run:<id> is a graph edge")

	for bad in ([?]string{"stage:audit", "workflow:research", "issue:iss_1"}) {
		kind, _, msg = ctl_task_depend_target(bad)
		testing.expectf(t, kind == .Invalid, "%s must be rejected", bad)
		testing.expectf(t, strings.contains(msg, "unsupported prerequisite kind") && strings.contains(msg, "workflow_run:<run-id>") && strings.contains(msg, "task-chain depend"), "actionable error for %s: %s", bad, msg)
	}
	kind, _, msg = ctl_task_depend_target("workflow_run:")
	testing.expect(t, kind == .Invalid && strings.contains(msg, "has no id"), "empty typed id rejected")
	kind, _, msg = ctl_task_depend_target("")
	testing.expect(t, kind == .Invalid && strings.contains(msg, "requires --on"), "missing prerequisite rejected")
}

@(test)
test_task_depends_on_csv_normalizes_and_rejects_runs :: proc(t: ^testing.T) {
	out, ok, _ := ctl_task_depends_on_csv("task_a, task:task_b,,")
	testing.expect(t, ok, "ticket ids accepted")
	testing.expect_value(t, out, "task_a,task_b")
	out, ok, _ = ctl_task_depends_on_csv("")
	testing.expect(t, ok && out == "", "empty list clears")
	msg: string
	_, ok, msg = ctl_task_depends_on_csv("task_a,workflow_run:wrun_1")
	testing.expect(t, !ok, "workflow runs are not ticket-list entries")
	testing.expectf(t, strings.contains(msg, "ham-ctl task depend <task-id> --on workflow_run:wrun_1"), "points at the supported command: %s", msg)
	_, ok, msg = ctl_task_depends_on_csv("stage:x")
	testing.expect(t, !ok && strings.contains(msg, "--depends-on: unsupported prerequisite kind"), "other kinds rejected")
}

@(test)
test_mixed_work_verbs_and_methods :: proc(t: ^testing.T) {
	for v in ([?]string{"graph", "depend", "remove-dependency", "scope", "complete"}) {
		testing.expectf(t, ctl_is_mixed_work_verb(v), "%s is a mixed-work verb", v)
	}
	testing.expect(t, !ctl_is_mixed_work_verb("publish"), "publish is not")
	testing.expect_value(t, ctl_mixed_work_agent_method("remove-dependency"), "agent.work.remove_dependency")
	testing.expect_value(t, ctl_mixed_work_agent_method("graph"), "agent.work.graph")
	// Every new flag consumes its value, so typed refs never become positionals.
	toks := command_tokens([]string{"ham-ctl", "task-chain", "depend", "--item", "task:t1", "--on", "workflow_run:r1"})
	defer delete(toks)
	testing.expect_value(t, len(toks), 2)
	params := ctl_task_depend_workflow_params("", "task_1", "wrun_1")
	testing.expect_value(t, params, `{"dependent":{"kind":"task","id":"task_1"},"prerequisite":{"kind":"workflow_run","id":"wrun_1"}}`)
}

@(test)
test_agent_mode_task_chain_graph_verbs_route_to_agent_work :: proc(t: ^testing.T) {
	ok_line := "{\"ok\":true,\"result\":{}}\n"
	responses := []string{ok_line, ok_line, ok_line, ok_line, ok_line, ok_line, ok_line}
	fb := fake_bridge_start(t, responses)
	if fb == nil do return
	defer fake_bridge_stop(fb)
	kr := tkr_b64(CTL_TEST_WRITE_KEY)

	ctl_v2_task_chain(fb.endpoint, "tok", []string{"graph", "chain_g"}, []string{"ham-ctl", "task-chain", "graph", "chain_g", "--vault-keyring", kr})
	ctl_v2_task_chain(fb.endpoint, "tok", []string{"depend"}, []string{"ham-ctl", "task-chain", "depend", "--chain", "chain_g", "--item", "task:task_r", "--on", "workflow_run:wrun_x", "--vault-keyring", kr})
	ctl_v2_task_chain(fb.endpoint, "tok", []string{"remove-dependency"}, []string{"ham-ctl", "task-chain", "remove-dependency", "--chain", "chain_g", "--dependency", "wdep_1", "--reason", "replanned", "--vault-keyring", kr})
	ctl_v2_task_chain(fb.endpoint, "tok", []string{"complete", "chain_g"}, []string{"ham-ctl", "task-chain", "complete", "chain_g", "--expected-work-revision", "4", "--summary", "done", "--vault-keyring", kr})
	// Agent `task depend --on workflow_run:` becomes the same chain-level edge.
	ctl_v2_task(fb.endpoint, "tok", []string{"depend", "task_r"}, []string{"ham-ctl", "task", "depend", "task_r", "--on", "workflow_run:wrun_x", "--vault-keyring", kr})
	ctl_v2_task_chain(fb.endpoint, "tok", []string{"scope"}, []string{"ham-ctl", "task-chain", "scope", "--chain", "chain_g", "--item", "workflow_run:wrun_x", "--action", "exclude", "--reason", "dropped", "--vault-keyring", kr})
	// A task:<id> prerequisite stays a ticket dependency (agent.task.depend).
	ctl_v2_task(fb.endpoint, "tok", []string{"depend", "task_r"}, []string{"ham-ctl", "task", "depend", "task_r", "--on", "task:task_p", "--vault-keyring", kr})
	testing.expect_value(t, fb.served, 7)

	graph := fake_bridge_request(fb, 0)
	testing.expectf(t, strings.contains(graph, `"method":"agent.work.graph"`) && strings.contains(graph, `"params":{"chain_id":"chain_g"}`), "graph routes with the positional chain: %s", graph)
	depend := fake_bridge_request(fb, 1)
	testing.expectf(t, strings.contains(depend, `"method":"agent.work.depend"`) && strings.contains(depend, `"dependent":{"kind":"task","id":"task_r"}`) && strings.contains(depend, `"prerequisite":{"kind":"workflow_run","id":"wrun_x"}`), "depend sends typed refs: %s", depend)
	remove := fake_bridge_request(fb, 2)
	testing.expectf(t, strings.contains(remove, `"method":"agent.work.remove_dependency"`) && strings.contains(remove, `"dependency_id":"wdep_1"`) && strings.contains(remove, `"reason":"replanned"`), "remove-dependency: %s", remove)
	complete := fake_bridge_request(fb, 3)
	testing.expectf(t, strings.contains(complete, `"method":"agent.work.complete"`) && strings.contains(complete, `"chain_id":"chain_g"`) && strings.contains(complete, `"expected_work_revision":4`) && strings.contains(complete, `"summary":"done"`), "complete: %s", complete)
	task_depend := fake_bridge_request(fb, 4)
	testing.expectf(t, strings.contains(task_depend, `"method":"agent.work.depend"`) && strings.contains(task_depend, `"dependent":{"kind":"task","id":"task_r"}`) && strings.contains(task_depend, `"prerequisite":{"kind":"workflow_run","id":"wrun_x"}`) && !strings.contains(task_depend, `depends_on_task_id`), "task depend on a run uses the graph edge: %s", task_depend)
	scope := fake_bridge_request(fb, 5)
	testing.expectf(t, strings.contains(scope, `"method":"agent.work.scope"`) && strings.contains(scope, `"chain_id":"chain_g"`) && strings.contains(scope, `"item":{"kind":"workflow_run","id":"wrun_x"}`) && strings.contains(scope, `"action":"exclude"`) && strings.contains(scope, `"reason":"dropped"`), "scope: %s", scope)
	ticket_depend := fake_bridge_request(fb, 6)
	testing.expectf(t, strings.contains(ticket_depend, `"method":"agent.task.depend"`) && strings.contains(ticket_depend, `"task_id":"task_r"`) && strings.contains(ticket_depend, `"depends_on_task_id":"task_p"`), "task: ref stays a ticket dependency: %s", ticket_depend)
	for i in 0..<7 do testing.expect(t, strings.contains(fake_bridge_request(fb, i), `"token":"tok"`), "authenticated with the agent token")
}
