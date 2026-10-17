package main

// REQ-CLI-1: `agent.task_chain.publish` route mapping.
//
// A coordinator agent could build a well-formed chain and never start it: chains
// and tasks are created publish_state=draft, draft tasks cannot be nudged and are
// never promoted, and there was no agent-surface method to publish. The hub route
// (POST /api/v1/task-chains/<id>/publish) and its coordinator permission check
// already existed — these tests pin the bridge surface that reaches them.

import "core:encoding/json"
import "core:strings"
import "core:testing"

@(test)
bridge_task_chain_publish_routes_raw_post :: proc(t: ^testing.T) {
	r := bridge_agent_route("agent.task_chain.publish", `{"chain_id":"chain_abc"}`)
	testing.expect(t, r.kind == .Raw, "publish routes .Raw (plain hub route, not an agent-actions envelope)")
	testing.expect(t, r.http_method == "POST", "publish is a POST")
	testing.expect_value(t, r.path, "/api/v1/task-chains/chain_abc/publish")
	testing.expect(t, !r.send_body, "publish takes no request body")
}

@(test)
bridge_task_chain_publish_requires_chain_id :: proc(t: ^testing.T) {
	// No hub-side "your own chain" default exists for publish, so a missing id must
	// fail fast with a usage message rather than POSTing to a malformed path.
	r := bridge_agent_route("agent.task_chain.publish", "{}")
	testing.expect(t, r.kind == .Bad_Request, "missing chain_id is a bad request")
	testing.expect(t, r.message != "", "bad request carries a usage message")

	blank := bridge_agent_route("agent.task_chain.publish", `{"chain_id":"   "}`)
	testing.expect(t, blank.kind == .Bad_Request, "whitespace-only chain_id is a bad request")
}

@(test)
bridge_task_chain_publish_method_allowed :: proc(t: ^testing.T) {
	testing.expect(t, bridge_agent_method_allowed("agent.task_chain.publish"), "publish is in the agent method allowlist")
	// Guard the neighbours: adding publish must not disturb the existing verbs.
	testing.expect(t, bridge_agent_method_allowed("agent.task_chain.set_status"), "set_status still allowed")
	testing.expect(t, bridge_agent_method_allowed("agent.task_chain.create"), "create is in the agent method allowlist")
}

@(test)
bridge_task_chain_create_routes_raw_post :: proc(t: ^testing.T) {
	r := bridge_agent_route("agent.task_chain.create", `{"title":"test chain"}`)
	testing.expect(t, r.kind == .Raw, "create routes .Raw (plain hub route, not an agent-actions envelope)")
	testing.expect(t, r.http_method == "POST", "create is a POST")
	testing.expect_value(t, r.path, "/api/v1/task-chains")
	testing.expect(t, r.send_body, "create takes a request body")
}

// Task System v2: the subscribe/unsubscribe, status, set_current, vote and nudge
// agent verbs were removed. They must be neither routed nor allow-listed, so an
// agent that still issues them gets a clean "unknown method" rather than a hub 410.
@(test)
bridge_removed_task_verbs_not_routed :: proc(t: ^testing.T) {
	removed := [?]string{
		"agent.task.status", "agent.task.set_current", "agent.task.vote", "agent.task.nudge",
		"agent.task.subscribe", "agent.task.unsubscribe",
		"agent.task_chain.subscribe", "agent.task_chain.unsubscribe",
	}
	for m in removed {
		r := bridge_agent_route(m, `{"task_id":"task_123","chain_id":"chain_abc"}`)
		testing.expectf(t, r.kind == .Unknown, "%s must be unrouted", m)
		testing.expectf(t, !bridge_agent_method_allowed(m), "%s must not be allow-listed", m)
	}
	// The surviving task verbs are untouched.
	for m in ([?]string{"agent.task.list", "agent.task.show", "agent.task.comments", "agent.task.create", "agent.task.update", "agent.task.depend", "agent.task.comment", "agent.context.get"}) {
		testing.expectf(t, bridge_agent_method_allowed(m), "%s still allowed", m)
		testing.expectf(t, bridge_agent_route(m, "{}").kind == .Envelope, "%s still routed", m)
	}
}

// Task System v2 (M1+M2): the lease / review / fetch verbs. next, submit and
// handoff are .Local so the bridge can add git state before relaying; the route
// still names the hub path it relays to. heartbeat, block, review.post and
// task.fetch are plain envelopes.
@(test)
bridge_lease_verbs_routed :: proc(t: ^testing.T) {
	next := bridge_agent_route("agent.lease.next", "{}")
	testing.expect(t, next.kind == .Local && next.local_op == "lease.next", "lease.next is bridge-local (vcs_base enrichment)")
	testing.expect_value(t, next.path, "/api/v1/agent-actions/lease/next")
	hb := bridge_agent_route("agent.lease.heartbeat", `{"note":"x"}`)
	testing.expect(t, hb.kind == .Envelope && hb.path == "/api/v1/agent-actions/lease/heartbeat", "lease.heartbeat relays")
	submit := bridge_agent_route("agent.lease.submit", `{"summary":"done"}`)
	testing.expect(t, submit.kind == .Local && submit.local_op == "lease.submit", "lease.submit is bridge-local (vcs enrichment)")
	testing.expect_value(t, submit.path, "/api/v1/agent-actions/lease/submit")
	handoff := bridge_agent_route("agent.lease.handoff", `{"summary":"wip"}`)
	testing.expect(t, handoff.kind == .Local && handoff.local_op == "lease.handoff", "lease.handoff is bridge-local (vcs enrichment)")
	testing.expect_value(t, handoff.path, "/api/v1/agent-actions/lease/handoff")
	block := bridge_agent_route("agent.lease.block", `{"waiting_on":{"kind":"user","reason":"q"}}`)
	testing.expect(t, block.kind == .Envelope && block.path == "/api/v1/agent-actions/lease/block", "lease.block relays")
	review := bridge_agent_route("agent.review.post", `{"verdict":"approve"}`)
	testing.expect(t, review.kind == .Envelope && review.path == "/api/v1/agent-actions/review/post", "review.post relays")
	fetch := bridge_agent_route("agent.task.fetch", `{"task_id":"task_1","ref":"#evt_1"}`)
	testing.expect(t, fetch.kind == .Envelope && fetch.path == "/api/v1/agent-actions/task/fetch", "task.fetch relays")
	for m in ([?]string{"agent.lease.next", "agent.lease.heartbeat", "agent.lease.submit", "agent.lease.handoff", "agent.lease.block", "agent.review.post", "agent.task.fetch"}) {
		testing.expectf(t, bridge_agent_method_allowed(m), "%s allow-listed", m)
	}
}

@(test)
bridge_workflow_verbs_routed :: proc(t: ^testing.T) {
	cases := [?][2]string{
		{"agent.workflow.templates", "/api/v1/agent-actions/workflow/templates"},
		{"agent.workflow.list", "/api/v1/agent-actions/workflow/templates"},
		{"agent.workflow.define", "/api/v1/agent-actions/workflow/define"},
		{"agent.workflow.run", "/api/v1/agent-actions/workflow/run"},
		{"agent.workflow.status", "/api/v1/agent-actions/workflow/status"},
		{"agent.workflow.output", "/api/v1/agent-actions/workflow/output"},
		{"agent.workflow.retry", "/api/v1/agent-actions/workflow/retry"},
		{"agent.workflow.cancel", "/api/v1/agent-actions/workflow/cancel"},
	}
	for c in cases {
		r := bridge_agent_route(c[0], "{}")
		testing.expectf(t, r.kind == .Envelope && r.path == c[1], "%s routes to %s (got %v %s)", c[0], c[1], r.kind, r.path)
		testing.expectf(t, bridge_agent_method_allowed(c[0]), "%s allow-listed", c[0])
	}
}

// bridge_taskv2_params_inject is the pure splice behind the lease enrichment.
@(test)
bridge_lease_params_inject :: proc(t: ^testing.T) {
	a := bridge_taskv2_params_inject("{}", "vcs_base", `"abc"`)
	defer delete(a)
	testing.expect_value(t, a, `{"vcs_base":"abc"}`)
	b := bridge_taskv2_params_inject(`{"summary":"s"}`, "vcs", `{"head":"h","dirty":false,"files":[]}`)
	defer delete(b)
	testing.expect_value(t, b, `{"vcs":{"head":"h","dirty":false,"files":[]},"summary":"s"}`)
	// an explicit caller value wins
	c := bridge_taskv2_params_inject(`{"vcs_base":"mine"}`, "vcs_base", `"bridge"`)
	defer delete(c)
	testing.expect_value(t, c, `{"vcs_base":"mine"}`)
	obj := bridge_taskv2_vcs_object_json("h1", true, `[{"path":"a","status":"modified","add":1,"del":2}]`)
	defer delete(obj)
	testing.expect_value(t, obj, `{"kind":"git","head":"h1","dirty":true,"files":[{"path":"a","status":"modified","add":1,"del":2}]}`)
}

// shell_exited frames for `ham-ctl verify` runs carry vcs + tail (contract §verify 6).
@(test)
bridge_verify_exit_frame_enriched :: proc(t: ^testing.T) {
	frame := bridge_shell_exited_event_json("sh_v1", 3, true, "exited", 0)
	defer delete(frame)
	enriched := bridge_taskv2_verify_exit_enrich_json(frame, "deadbeef", true, false, "line39\nline40\n")
	defer delete(enriched)
	testing.expect(t, strings.has_suffix(enriched, `,"vcs":{"head":"deadbeef","dirty":false},"tail":"line39\nline40\n"}`), "vcs + tail appended")
	testing.expect(t, strings.contains(enriched, `"session_id":"sh_v1"`) && strings.contains(enriched, `"exit_code":3`), "original fields kept")
	parsed: Bridge_Shell_Exited_Event
	testing.expect(t, json.unmarshal_string(enriched, &parsed, json.DEFAULT_SPECIFICATION, context.temp_allocator) == nil, "still valid JSON")
	testing.expect_value(t, parsed.run_seq, 0)

	// unknown dirty -> null; not-a-repo head is written empty, tail empty
	unknown := bridge_taskv2_verify_exit_enrich_json(`{"type":"shell_exited"}`, "", false, false, "")
	defer delete(unknown)
	testing.expect_value(t, unknown, `{"type":"shell_exited","vcs":{"head":"","dirty":null},"tail":""}`)

	// tail keeps the last 40 lines only
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 1 ..= 45 { strings.write_string(&b, "l"); strings.write_int(&b, i); strings.write_byte(&b, '\n') }
	tail := bridge_taskv2_tail_lines(strings.to_string(b), 40)
	testing.expect(t, strings.has_prefix(tail, "l6\n") && strings.has_suffix(tail, "l45\n"), "last 40 lines")
	short := bridge_taskv2_tail_lines("a\nb\n", 40)
	testing.expect_value(t, short, "a\nb\n")
}
