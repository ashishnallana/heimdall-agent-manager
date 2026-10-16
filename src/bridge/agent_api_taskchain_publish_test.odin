package main

// REQ-CLI-1: `agent.task_chain.publish` route mapping.
//
// A coordinator agent could build a well-formed chain and never start it: chains
// and tasks are created publish_state=draft, draft tasks cannot be nudged and are
// never promoted, and there was no agent-surface method to publish. The hub route
// (POST /api/v1/task-chains/<id>/publish) and its coordinator permission check
// already existed — these tests pin the bridge surface that reaches them.

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

@(test)
bridge_task_chain_subscribe_routes_envelope :: proc(t: ^testing.T) {
	r := bridge_agent_route("agent.task_chain.subscribe", `{"chain_id":"chain_abc","events":"all"}`)
	testing.expect(t, r.kind == .Envelope, "subscribe routes .Envelope")
	testing.expect_value(t, r.path, "/api/v1/agent-actions/chain/subscribe")
}

@(test)
bridge_task_chain_unsubscribe_routes_envelope :: proc(t: ^testing.T) {
	r := bridge_agent_route("agent.task_chain.unsubscribe", `{"chain_id":"chain_abc"}`)
	testing.expect(t, r.kind == .Envelope, "unsubscribe routes .Envelope")
	testing.expect_value(t, r.path, "/api/v1/agent-actions/chain/unsubscribe")
}

@(test)
bridge_task_subscribe_routes_envelope :: proc(t: ^testing.T) {
	r := bridge_agent_route("agent.task.subscribe", `{"task_id":"task_123","events":"all"}`)
	testing.expect(t, r.kind == .Envelope, "task subscribe routes .Envelope")
	testing.expect_value(t, r.path, "/api/v1/agent-actions/task/subscribe")
}

@(test)
bridge_task_unsubscribe_routes_envelope :: proc(t: ^testing.T) {
	r := bridge_agent_route("agent.task.unsubscribe", `{"task_id":"task_123"}`)
	testing.expect(t, r.kind == .Envelope, "task unsubscribe routes .Envelope")
	testing.expect_value(t, r.path, "/api/v1/agent-actions/task/unsubscribe")
}

@(test)
bridge_subscription_methods_allowed :: proc(t: ^testing.T) {
	testing.expect(t, bridge_agent_method_allowed("agent.task_chain.subscribe"), "chain subscribe allowed")
	testing.expect(t, bridge_agent_method_allowed("agent.task_chain.unsubscribe"), "chain unsubscribe allowed")
	testing.expect(t, bridge_agent_method_allowed("agent.task.subscribe"), "task subscribe allowed")
	testing.expect(t, bridge_agent_method_allowed("agent.task.unsubscribe"), "task unsubscribe allowed")
}
