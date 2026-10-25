package main

import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import auth_service "odin_test:hub/service/auth"

// hub_test_user_headers authenticates test requests as `user_id`: it enables
// cookie sessions on the graph's auth service (backed by the graph's real SQLite
// session store), mints a browser session for the user (provisioning it) and
// returns the request Cookie header. It replaces the removed trusted-proxy
// identity header. Strings live in the temp allocator.
hub_test_user_headers :: proc(graph: ^app.App_Graph, user_id: string) -> [1]contracts.HTTP_Header {
	context.allocator = context.temp_allocator
	graph.auth.web.enabled = true
	raw, ok := auth_service.mint_session(&graph.auth, user_id)
	if !ok do return [1]contracts.HTTP_Header{{name = "X-Test-Session-Mint-Failed", value = user_id}}
	return [1]contracts.HTTP_Header{auth_service.session_cookie_request_header(raw)}
}
