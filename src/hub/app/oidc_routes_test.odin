package app

import "core:strings"
import "core:testing"
import http "odin_test:hub/transport/http"

@(test)
test_oidc_removes_user_token_routes_and_preserves_bridge_routes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	legacy, oidc: App_Graph
	legacy.router = http.new_router()
	oidc.router = http.new_router()
	defer http.router_free(&legacy.router)
	defer http.router_free(&oidc.router)
	oidc.auth.oidc_mode = true
	register_routes(&legacy)
	register_routes(&oidc)
	testing.expect_value(t, len(legacy.router.routes) - len(oidc.router.routes), 3)
	for route in legacy.router.routes {
		removed := strings.has_prefix(route.path, "/api/v1/me/tokens")
		found := false
		for candidate in oidc.router.routes {
			if candidate.method == route.method && candidate.path == route.path {
				found = true
				testing.expect(t, candidate.handler == route.handler)
			}
		}
		testing.expect(t, found != removed, route.path)
	}
	testing.expect_value(t, len(legacy.router.upgrade_routes), len(oidc.router.upgrade_routes))
}
