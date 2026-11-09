package http

import "core:testing"
import domain "odin_test:hub/domain"

// H2 (bridge auth recovery): an unknown access token is answered with
// bridge_token_invalid ONLY to a bridge whose hello advertised
// credential_refresh_on_invalid; older bridges keep bridge_credential_revoked, so
// none of them starts looping. Expiry, sunset and Forbidden revocation are unchanged.
@(test)
test_bridge_ws_auth_error_code_is_capability_gated :: proc(t: ^testing.T) {
	invalid := domain.domain_error(.Unauthenticated, "bridge token is invalid")
	testing.expect_value(t, bridge_ws_auth_error_code(invalid, false), BRIDGE_WS_CREDENTIAL_REVOKED_CODE)
	testing.expect_value(t, bridge_ws_auth_error_code(invalid, true), BRIDGE_WS_TOKEN_INVALID_CODE)
	expired := domain.domain_error(.Unauthenticated, "bridge access token has expired")
	testing.expect_value(t, bridge_ws_auth_error_code(expired, false), BRIDGE_WS_TOKEN_EXPIRED_CODE)
	testing.expect_value(t, bridge_ws_auth_error_code(expired, true), BRIDGE_WS_TOKEN_EXPIRED_CODE)
	revoked := domain.domain_error(.Forbidden, "bridge credential is revoked")
	testing.expect_value(t, bridge_ws_auth_error_code(revoked, true), BRIDGE_WS_CREDENTIAL_REVOKED_CODE)
	family := domain.domain_error(.Forbidden, "bridge credential has reached its maximum lifetime; re-enrollment is required")
	testing.expect_value(t, bridge_ws_auth_error_code(family, true), BRIDGE_WS_CREDENTIAL_REVOKED_CODE)
	sunset := domain.domain_error(.Internal_Error, "pending")
	sunset.cause = BRIDGE_WS_SUNSET_PENDING_CODE
	testing.expect_value(t, bridge_ws_auth_error_code(sunset, true), BRIDGE_WS_SUNSET_PENDING_CODE)
}
