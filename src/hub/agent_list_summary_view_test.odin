package main

import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import api_http "odin_test:hub/transport/http"

// GET /agents?view=summary (refresh performance pass): the opt-in list view drops the
// instructions text and per-row counts; the default view is unchanged, and paging and
// owner scoping behave identically in both.
@(test)
test_agents_list_summary_view_is_opt_in :: proc(t: ^testing.T) {
	f: Refresh_Fixture
	defer refresh_fixture_teardown(&f)
	if !refresh_fixture_setup(t, &f, "agentsummary") do return

	big := strings.repeat("persona line ", 2000) // ~26 KB of instructions
	defer delete(big)
	patch := api_http.router_dispatch(&f.graph.router, api_http.Request{method = "PATCH", path = fmt.aprintf("/api/v1/agents/%s", f.agent_id), body = fmt.aprintf(`{{"instructions":"%s"}}`, big), request_id = "req_as_patch", remote_addr = "127.0.0.1", headers = f.alice[:]})
	if !testing.expectf(t, patch.status == 200, "patch status %d body %s", patch.status, patch.body) do return

	full := api_http.router_dispatch(&f.graph.router, api_http.Request{method = "GET", path = "/api/v1/agents", query = "limit=200", request_id = "req_as_full", remote_addr = "127.0.0.1", headers = f.alice[:]})
	summary := api_http.router_dispatch(&f.graph.router, api_http.Request{method = "GET", path = "/api/v1/agents", query = "limit=200&view=summary", request_id = "req_as_sum", remote_addr = "127.0.0.1", headers = f.alice[:]})
	testing.expect_value(t, full.status, 200)
	testing.expect_value(t, summary.status, 200)
	testing.expect(t, strings.contains(full.body, "persona line"), "default view keeps instructions")
	testing.expect(t, strings.contains(full.body, `"supported_bridge_count":`), "default view keeps counts")
	testing.expect(t, !strings.contains(summary.body, "instructions"), "summary view omits instructions")
	testing.expect(t, !strings.contains(summary.body, "_count"), "summary view omits per-row counts")
	for field in ([]string{`"agent_id":"`, `"name":"`, `"slug":"`, `"template_id":"`, `"state":"`, `"updated_at":"`}) {
		testing.expectf(t, strings.contains(summary.body, field), "summary view keeps %s", field)
	}
	testing.expect(t, strings.contains(summary.body, f.agent_id), "summary lists the agent")
	testing.expect(t, strings.contains(summary.body, `"has_more":false`), "summary keeps the page envelope")
	testing.expectf(t, len(summary.body) * 10 < len(full.body), "summary %d bytes vs full %d bytes", len(summary.body), len(full.body))
	fmt.printf("agents list bytes: full=%d summary=%d\n", len(full.body), len(summary.body))

	// Another owner sees none of alice's agents in either view.
	bob := hub_test_user_headers(&f.graph, "bob")
	other := api_http.router_dispatch(&f.graph.router, api_http.Request{method = "GET", path = "/api/v1/agents", query = "view=summary", request_id = "req_as_bob", remote_addr = "127.0.0.1", headers = bob[:]})
	testing.expect(t, !strings.contains(other.body, f.agent_id), "owner scoping preserved in summary view")

	// Unauthenticated: same 401 as the default view.
	anon := api_http.router_dispatch(&f.graph.router, api_http.Request{method = "GET", path = "/api/v1/agents", query = "view=summary", request_id = "req_as_anon", remote_addr = "127.0.0.1"})
	testing.expect_value(t, anon.status, 401)
}
