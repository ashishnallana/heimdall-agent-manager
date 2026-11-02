// POST /api/v1/device/bridge-refresh — the bridge credential refresh endpoint
// (REQ-IMPL-3, design §7.4).
//
// WHY THIS PATH AND NOT §9.3's `/api/v1/bridge-device/refresh`. The design names a
// whole `/api/v1/bridge-device/*` family, written before settled 1 decided to REUSE
// the existing device grant rather than stand up a parallel flow. No such family
// exists in the tree: every route of this flow is `/api/v1/device/*`
// (wiring.odin), and REQ-IMPL-2 extended those in place. Inventing a second
// prefix for a single endpoint would leave the bridge talking to two families for
// one flow. The endpoint's §9.3 contract — dedicated path, `hbf_`-authenticated,
// nothing else accepted — is unchanged.
//
// AUTH IS THE REFRESH TOKEN ITSELF, in the Authorization header. Three things are
// deliberately absent:
//   - NO user session. A bridge has none; requiring one would make unattended
//     renewal impossible, which is the whole point of a refresh token.
//   - NO access token accepted. refresh_bridge_token checks the STORED kind, so an
//     `hba_` presented here is refused — otherwise an hour-long credential would be
//     exchangeable for a 30-day one.
//   - NO token in the query string or body. reject_query_or_body_token enforces the
//     repo-wide rule: a credential in a URL lands in every access log and proxy
//     cache on the path.
package http

import "core:strings"
import contracts "odin_test:contracts"
import bridge_service "odin_test:hub/service/bridge"
import domain "odin_test:hub/domain"

// bridge_refresh_handler rotates a bridge's credential pair.
//
// ONE ERROR FOR EVERY FAILURE, ON PURPOSE (§7.4): expired, unknown, already-used and
// revoked all return 401 `invalid_grant`. The bridge's correct response to all four
// is identical — stop, wipe both tokens, require re-enrollment, do not loop — so
// distinguishing them would add an enumeration oracle and no capability. The server
// log distinguishes them. A pending sunset is a recoverable suspension: it returns
// a retriable 500 until enrollment commits or rolls back, so installed bridges keep
// their on-disk credentials.
//
// A SUCCESSFUL RESPONSE CARRIES BOTH NEW PLAINTEXTS AND NO TIMESTAMPS. expires_in
// and refresh_expires_in are DURATIONS: a bridge with a wrong clock must still
// refresh correctly, so it schedules off a monotonic timer and never compares its
// wall clock against a Hub timestamp. See BRIDGE_TOKEN_CLOCK_SKEW_SECONDS.
bridge_refresh_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	if rejected, resp := reject_query_or_body_token(req); rejected do return resp
	token, token_ok := bearer_token(req)
	// The prefix check is a cheap rejection, not the authorisation: the service
	// re-splits the token and verifies the secret against the stored row. It exists
	// so a user token or an access token fails here without a database lookup.
	if !token_ok || !strings.has_prefix(token, bridge_service.REFRESH_TOKEN_PREFIX) {
		return respond_error(domain.domain_error(.Unauthenticated, "invalid_grant"), req.request_id)
	}
	// The bridge's per-rotation request id, when it sends one, lets a retry of a
	// rotation whose reply was lost be answered (BRIDGE_REFRESH_RETRY_GRACE_SECONDS).
	request_id := header_value(req.headers, bridge_service.BRIDGE_REFRESH_REQUEST_ID_HEADER)
	pair, ok, err := bridge_service.refresh_bridge_token(h.bridges, token, request_id)
	if !ok do return respond_error(err, req.request_id)
	// Typed marshal, never concatenation: field names, order and types are the
	// historical wire format (contracts.Bridge_Refresh_Reply).
	return respond_success_typed(contracts.Bridge_Refresh_Reply{
		access_token = pair.access_token,
		refresh_token = pair.refresh_token,
		bridge_id = pair.bridge_id,
		token_type = "Bearer",
		expires_in = pair.expires_in,
		refresh_expires_in = pair.refresh_expires_in,
	}, req.request_id, "")
}
