package main

// AUDIT F4: the loopback surface must FAIL CLOSED when the bridge has no credential.
//
// WHAT THE DEFECT WAS. `bridge_loopback_authorized` opened with:
//
//     if strings.trim_space(bridge_config.bridge_token) == "" do return true
//
// A blank configured token authorised EVERY loopback request. That is not a narrow
// edge case — a bridge is token-less for its whole life before it enrols, and a
// bridge whose token file is missing, empty or unreadable is token-less too. In all
// of those states the loopback routes, which spawn agents and read project files,
// were open to any local process with no credential at all.
//
// WHY IT COULD ONLY BE FLIPPED WITH THE STATIC-TOKEN DELETION. The permissive branch
// had exactly one legitimate consumer: a locally started bridge deliberately given
// no token, which is how the deleted static-token path let a developer run a stack
// without enrolling. Flipping it sooner would have broken every such bridge,
// including other agents' running `dev-stack.sh` harnesses. REQ-IMPL-6 deletes that
// path and rewrites `dev-stack.sh` onto the device flow, so nothing legitimate
// depends on fail-open any more.
//
// WHY THESE TESTS EXIST RATHER THAN A COMMENT. F4 is a privilege-escalation defect,
// and settled practice in this chain is that a security property without a test
// proving it is an `ngtm`. Reintroducing the `return true` makes
// `test_blank_configured_token_authorizes_nothing` fail, which is the whole point.

import "core:strings"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"

// loopback_request builds a minimal request with the given Authorization value.
// An empty `auth` omits the header entirely, which is the shape a caller that
// presents no credential at all actually sends.
@(private = "file")
loopback_request :: proc(auth: string) -> string {
	if auth == "" do return "GET /bridge/health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
	return strings.concatenate({
		"GET /bridge/health HTTP/1.1\r\nHost: 127.0.0.1\r\n",
		contracts.BRIDGE_LOOPBACK_AUTH_HEADER, ": ", auth, "\r\n\r\n",
	}, context.temp_allocator)
}

// THE F4 ASSERTION. A blank configured token must authorise NOTHING — not an
// absent header, not an empty bearer, and not an arbitrary guess.
@(test)
test_blank_configured_token_authorizes_nothing :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved := bridge_config.bridge_token
	defer bridge_config.bridge_token = saved

	bridge_config.bridge_token = ""
	testing.expect(t, !bridge_loopback_authorized(loopback_request("")), "a blank configured token must not authorize a request with no Authorization header")
	testing.expect(t, !bridge_loopback_authorized(loopback_request("Bearer ")), "a blank configured token must not authorize an empty bearer")
	testing.expect(t, !bridge_loopback_authorized(loopback_request("Bearer anything")), "a blank configured token must not authorize an arbitrary token")
	// The empty-string bearer is called out separately because it is the one an
	// attacker reaches by simply echoing the blank config value back.
	testing.expect(t, !bridge_loopback_authorized(loopback_request("Bearer \"\"")), "a blank configured token must not authorize a quoted-empty bearer")

	// WHITESPACE-ONLY IS STILL BLANK. A token file containing just a newline, or a
	// config value of " ", must not be treated as a real credential — otherwise the
	// fix is one stray space away from being undone.
	bridge_config.bridge_token = "   "
	testing.expect(t, !bridge_loopback_authorized(loopback_request("")), "a whitespace-only configured token must not authorize an unauthenticated request")
	testing.expect(t, !bridge_loopback_authorized(loopback_request("Bearer    ")), "a whitespace-only configured token must not authorize a whitespace bearer")
}

// The positive case, so the test above cannot pass by rejecting everything.
@(test)
test_configured_token_authorizes_only_the_matching_bearer :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved := bridge_config.bridge_token
	defer bridge_config.bridge_token = saved

	bridge_config.bridge_token = "hba_brg_test.secret"
	testing.expect(t, bridge_loopback_authorized(loopback_request("Bearer hba_brg_test.secret")), "the matching bearer must be authorized")
	testing.expect(t, !bridge_loopback_authorized(loopback_request("Bearer hba_brg_test.wrong")), "a wrong secret must be refused")
	testing.expect(t, !bridge_loopback_authorized(loopback_request("Bearer hba_brg_test.secretx")), "a token with the right prefix must still be compared in full")
	testing.expect(t, !bridge_loopback_authorized(loopback_request("hba_brg_test.secret")), "the Bearer prefix is required")
	testing.expect(t, !bridge_loopback_authorized(loopback_request("")), "a configured token must not authorize a request with no header")
}

// A SECOND, NARROWER BUG FOUND WHILE FLIPPING F4, and the reason the proc now
// trims once and compares against the trimmed value.
//
// The blank check was trimmed but the equality check was not, so a token supplied
// through `config.toml`'s `daemon.bridge_token` or `--bridge-token` with surrounding
// whitespace passed the blank test and then rejected every correctly-formed request
// — a bridge silently refusing its own traffic. (`bridge_read_token_file` already
// trims, so the token-file path never hit this.) The two checks must agree on what
// the token is.
@(test)
test_surrounding_whitespace_in_the_configured_token_does_not_break_authorization :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved := bridge_config.bridge_token
	defer bridge_config.bridge_token = saved

	bridge_config.bridge_token = "  hba_brg_test.secret\n"
	testing.expect(t, bridge_loopback_authorized(loopback_request("Bearer hba_brg_test.secret")), "a configured token with surrounding whitespace must still authorize its own correctly-formed request")
	testing.expect(t, !bridge_loopback_authorized(loopback_request("Bearer wrong")), "trimming must not weaken the comparison")
}
