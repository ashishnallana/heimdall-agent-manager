package main

// T5: `agent.chat.previous_context` route mapping. The bridge forwards a
// rollover handoff to the hub endpoint that stores it inbound + unread in the
// caller's own conversation without notifying the agent (interception is T6).

import "core:testing"

@(test)
bridge_chat_previous_context_routes_envelope :: proc(t: ^testing.T) {
	r := bridge_agent_route("agent.chat.previous_context", `{"request_id":"rq_1","body":"vault:v1:x"}`)
	testing.expect(t, r.kind == .Envelope, "previous_context is an agent-actions envelope (identity from the verified token)")
	testing.expect_value(t, bridge_agent_route_target(r), "/api/v1/agent-actions/chat/previous-context")
}

@(test)
bridge_chat_previous_context_is_allowlisted :: proc(t: ^testing.T) {
	testing.expect(t, bridge_agent_method_allowed("agent.chat.previous_context"), "method is dispatchable")
	// The plain self-send path is unchanged: it still routes to send-to-agent.
	r := bridge_agent_route("agent.chat.send", `{"to":"inst_self","body":"x"}`)
	testing.expect_value(t, bridge_agent_route_target(r), "/api/v1/agent-actions/chat/send-to-agent")
}
