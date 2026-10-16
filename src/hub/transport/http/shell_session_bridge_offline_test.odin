// Behavioral tests for shell session HTTP endpoints, list JSON serialization, preview URL derivation, and bridge offline handling.
package http

import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import domain "odin_test:hub/domain"
import project_service "odin_test:hub/service/project"
import "core:strings"
import "core:testing"

// --- Consolidated from shell_session_bridge_offline_test.odin ---

@(private = "file")
_offline_session :: proc(status: string) -> domain.Shell_Session {
	return domain.Shell_Session{
		session_id    = "sh_1",
		owner_user_id = "owner_a",
		bridge_id     = "brg_1",
		kind          = domain.Shell_Session_Kind_Shell,
		cmd           = "zsh",
		status        = status,
		started_at    = "2026-09-28T09:00:00Z",
	}
}

@(private = "file")
_offline_json :: proc(registry: ^project_service.Bridge_Runtime_Registry, s: domain.Shell_Session) -> string {
	b := strings.builder_make()
	write_shell_session_json(&b, s, registry)
	return strings.to_string(b)
}

// AC3, BOTH DIRECTIONS in one test, because the reverse is the half a stored status
// would get wrong: a design that wrote a state on disconnect has to remember to unwind
// it, and a fast reconnect racing that teardown is exactly how a live session gets
// stuck looking dead. Deriving the state means the reverse direction is the same line
// of code read again, which is what this asserts.
@(test)
test_shell_session_bridge_offline_state_both_directions :: proc(t: ^testing.T) {
	registry: project_service.Bridge_Runtime_Registry
	session := _offline_session(domain.Shell_Session_Status_Running)

	// 1. CONNECTED: the row's status stands on its own.
	_, _, _ = bridge_runtime_service.runtime_accept_hello(&registry, "brg_1", bridge_runtime_service.PROTOCOL_VERSION, "")
	online := _offline_json(&registry, session)
	defer delete(online)
	testing.expect(t, strings.contains(online, "\"bridge_online\":true"), "a connected bridge must report online")
	testing.expect(t, strings.contains(online, "\"status_unknown\":false"), "a connected bridge's session status is trustworthy")

	// 2. DISCONNECTED: the status is reported verbatim but flagged untrustworthy —
	// never rewritten to failed/killed, which would assert a death nobody observed.
	project_service.bridge_runtime_registry_mark_offline(&registry, "brg_1", 0)
	offline := _offline_json(&registry, session)
	defer delete(offline)
	testing.expect(t, strings.contains(offline, "\"bridge_online\":false"), "a disconnected bridge must report offline")
	testing.expect(t, strings.contains(offline, "\"status_unknown\":true"), "its live session's status is no longer trustworthy")
	testing.expect(t, strings.contains(offline, "\"status\":\"running\""),
		"the stored status is still reported verbatim — this state qualifies it, it does not replace it")

	// 3. RECONNECTED: back to trustworthy, with nothing to unwind.
	_, _, _ = bridge_runtime_service.runtime_accept_hello(&registry, "brg_1", bridge_runtime_service.PROTOCOL_VERSION, "")
	back := _offline_json(&registry, session)
	defer delete(back)
	testing.expect(t, strings.contains(back, "\"bridge_online\":true"), "reconnect must clear the flag")
	testing.expect(t, strings.contains(back, "\"status_unknown\":false"), "reconnect must restore the true status")
}

// A TERMINAL session is exempt, and this is the reason the rule is a named predicate
// rather than `!bridge_online` at the call site. A session that has already ended has a
// FINAL status — a fact about the past that no bridge needs to vouch for. Flagging it
// unknown would tell a user the outcome of a finished job is in doubt, every time its
// bridge happened to be offline.
@(test)
test_shell_session_terminal_status_is_never_unknown :: proc(t: ^testing.T) {
	registry: project_service.Bridge_Runtime_Registry // nothing live

	for status in ([]string{
		domain.Shell_Session_Status_Exited,
		domain.Shell_Session_Status_Killed,
		domain.Shell_Session_Status_Failed,
	}) {
		session := _offline_session(status)
		body := _offline_json(&registry, session)
		defer delete(body)
		testing.expectf(t, strings.contains(body, "\"status_unknown\":false"),
			"a %s session has a final status and must not be flagged unknown", status)
		testing.expect(t, strings.contains(body, "\"bridge_online\":false"),
			"the bridge fact is still reported truthfully")
	}
}

// AC6 — THE GENERATION GUARD, asserted on this path specifically.
//
// A bridge reconnects fast enough that the PREVIOUS connection's teardown runs after
// the new one is established. If that teardown could evict the fresh entry, every
// session on a perfectly healthy bridge would be presented as status-unknown until
// something else re-marked it live.
//
// The guard already exists in bridge_runtime_registry_mark_offline (it ignores a
// teardown whose generation is not the current one) and bridge_ws_disconnect gates its
// whole cascade on the same comparison. What this test pins is that the derived state
// INHERITS it rather than needing a second copy — which is the payoff of deriving from
// the registry instead of writing a status on disconnect.
@(test)
test_superseded_teardown_does_not_flip_a_fresh_reconnect :: proc(t: ^testing.T) {
	registry: project_service.Bridge_Runtime_Registry
	session := _offline_session(domain.Shell_Session_Status_Running)

	first, _, _ := bridge_runtime_service.runtime_accept_hello(&registry, "brg_1", bridge_runtime_service.PROTOCOL_VERSION, "")
	second, _, _ := bridge_runtime_service.runtime_accept_hello(&registry, "brg_1", bridge_runtime_service.PROTOCOL_VERSION, "")
	testing.expect(t, second.generation != first.generation, "a reconnect must take a new generation")

	// The OLD connection's teardown arrives late, naming its own (now superseded)
	// generation.
	project_service.bridge_runtime_registry_mark_offline(&registry, "brg_1", first.generation)

	body := _offline_json(&registry, session)
	defer delete(body)
	testing.expect(t, strings.contains(body, "\"bridge_online\":true"),
		"a superseded connection's teardown must not evict the live reconnect")
	testing.expect(t, strings.contains(body, "\"status_unknown\":false"),
		"and so must not present a healthy bridge's sessions as status-unknown")
}

// --- Consolidated from shell_session_list_json_test.odin ---

@(test)
test_shell_session_list_json_has_more :: proc(t: ^testing.T) {
	sessions := []domain.Shell_Session{
		{session_id = "sh_a", bridge_id = "brg_1", status = "running"},
		{session_id = "sh_b", bridge_id = "brg_2", status = "exited"},
	}

	// A full page: cursor present, has_more true.
	more := _shell_session_list_json(sessions, "sh_b")
	defer delete(more)
	testing.expect(t, strings.contains(more, "\"next_cursor\":\"sh_b\""), "cursor echoed")
	testing.expect(t, strings.contains(more, "\"has_more\":true"), "has_more true when a cursor was returned")
	testing.expect(t, !strings.contains(more, "\"has_more\":false"), "not both spellings")

	// The last page: no cursor, has_more false.
	last := _shell_session_list_json(sessions, "")
	defer delete(last)
	testing.expect(t, strings.contains(last, "\"next_cursor\":\"\""), "empty cursor still emitted")
	testing.expect(t, strings.contains(last, "\"has_more\":false"), "has_more false with no cursor")

	// The keys existing consumers already read are untouched and still in order.
	testing.expect(t, strings.contains(last, "\"ok\":true,\"sessions\":["), "envelope prefix unchanged")
	testing.expect(t, strings.contains(last, "\"session_id\":\"sh_a\""), "first session present")
	testing.expect(t, strings.contains(last, "\"session_id\":\"sh_b\""), "second session present")
	testing.expect(t, strings.contains(last, "\"bridge_id\":\"brg_2\""), "sessions from more than one bridge serialize")

	// An empty page is still a well-formed envelope, not a bare array.
	none := _shell_session_list_json([]domain.Shell_Session{}, "")
	defer delete(none)
	testing.expect_value(t, none, "{\"ok\":true,\"sessions\":[],\"next_cursor\":\"\",\"has_more\":false}")
}

// --- Consolidated from shell_session_preview_url_test.odin ---

@(private = "file")
preview_url_test_session :: proc(port: int = 5173) -> domain.Shell_Session {
	return domain.Shell_Session{session_id = "ss_1", server_port = port}
}

@(test)
test_shell_session_preview_url_variants :: proc(t: ^testing.T) {
	cases := []struct {
		preview_origin: string,
		ui_origin:      string,
		port:           int,
		expected:       string,
	}{
		{"https://preview.example", "https://hub.example", 5173, "https://preview.example/p/ss_1/"},
		{"https://preview.example/", "https://hub.example", 5173, "https://preview.example/p/ss_1/"},
		{"", "https://hub.example", 5173, "https://hub.example/api/v1/preview/ss_1/"},
		{"", "", 5173, "/api/v1/preview/ss_1/"},
		{"https://preview.example", "https://hub.example", 0, ""},
	}
	for tc in cases {
		actual := shell_session_preview_url(preview_url_test_session(tc.port), tc.preview_origin, tc.ui_origin)
		testing.expect_value(t, actual, tc.expected)
		delete(actual)
	}
}

@(test)
test_shell_session_json_contains_preview_url :: proc(t: ^testing.T) {
	b := strings.builder_make()
	write_shell_session_json(&b, preview_url_test_session(), nil, "https://preview.example", "https://hub.example")
	actual := strings.to_string(b)
	defer delete(actual)
	testing.expect(t, strings.contains(actual, `"preview_url":"https://preview.example/p/ss_1/"`))
}
