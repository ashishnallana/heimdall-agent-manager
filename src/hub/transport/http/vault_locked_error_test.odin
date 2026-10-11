package http

// T10 (REQ-T10-2): a bridge refusal that names `vault_locked` reaches the client as a
// typed error (HTTP 423, code vault_locked, details.bridge_id) on every path — shell
// start/restart replies, REST keystrokes and the pane stream — while an unknown
// refusal keeps the generic 500.

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import project_service "odin_test:hub/service/project"
import shell_session_svc "odin_test:hub/service/shell_session"

@(test)
test_t10_vault_locked_maps_to_423_with_bridge_id :: proc(t: ^testing.T) {
	err := domain.vault_locked_error("brg_t10")
	testing.expect_value(t, err.code, domain.Error_Code.Vault_Locked)
	testing.expect_value(t, status_for_error(err.code), 423)

	resp := respond_error(err, "req_t10")
	defer delete(resp.body)
	testing.expect_value(t, resp.status, 423)
	testing.expect(t, strings.contains(resp.body, `"code":"vault_locked"`), resp.body)
	testing.expect(t, strings.contains(resp.body, `"details":{"bridge_id":"brg_t10"}`), resp.body)
	testing.expect(t, strings.contains(resp.body, domain.VAULT_LOCKED_MESSAGE), resp.body)
}

@(test)
test_t10_bridge_refusal_error_only_maps_known_codes :: proc(t: ^testing.T) {
	typed, ok := domain.bridge_refusal_error("vault_locked", "brg_x")
	testing.expect(t, ok, "vault_locked has a typed mapping")
	testing.expect_value(t, typed.code, domain.Error_Code.Vault_Locked)

	_, unknown_ok := domain.bridge_refusal_error("invalid_vault_key", "brg_x")
	testing.expect(t, !unknown_ok, "codes without a typed mapping fall back to the caller's error")
	_, empty_ok := domain.bridge_refusal_error("", "brg_x")
	testing.expect(t, !empty_ok, "no code, no mapping")

	// A hostile id cannot break the details JSON.
	quoted := domain.vault_locked_error(`brg"\x`)
	testing.expect_value(t, quoted.details_json, `{"bridge_id":"brg\"\\x"}`)
}

// The shell_start / shell_restart reply path (shell_session_service._bridge_failure).
@(test)
test_t10_bridge_failure_types_vault_locked_and_keeps_500_otherwise :: proc(t: ^testing.T) {
	locked := shell_session_svc._bridge_failure(
		`{"type":"shell_start_result","ok":false,"error_code":"vault_locked","error":"unauthorized: vault locked"}`,
		"bridge failed to start shell session",
		"brg_t10",
	)
	testing.expect_value(t, locked.code, domain.Error_Code.Vault_Locked)
	testing.expect_value(t, status_for_error(locked.code), 423)
	testing.expect(t, strings.contains(locked.details_json, "brg_t10"), locked.details_json)

	restart := shell_session_svc._bridge_failure(
		`{"type":"shell_restart_result","session_id":"sh_1","command_id":"c","ok":false,"error_code":"vault_locked"}`,
		"bridge failed to restart shell session",
		"brg_t10",
	)
	testing.expect_value(t, restart.code, domain.Error_Code.Vault_Locked)

	other := shell_session_svc._bridge_failure(
		`{"type":"shell_start_result","ok":false,"error_code":"invalid_vault_key","error":"unauthorized: missing or invalid vault enc_spec"}`,
		"bridge failed to start shell session",
		"brg_t10",
	)
	testing.expect_value(t, other.code, domain.Error_Code.Internal_Error)
	testing.expect(t, strings.contains(other.message, "missing or invalid vault enc_spec"), other.message)

	bare := shell_session_svc._bridge_failure(`{"ok":false}`, "bridge failed to start shell session", "brg_t10")
	testing.expect_value(t, bare.code, domain.Error_Code.Internal_Error)
}

@(private = "file")
T10_Sink_State :: struct {
	reply:       string,
	sent_calls:  int,
	wait_calls:  int,
}

@(private = "file")
t10_sink :: proc(state: ^T10_Sink_State) -> project_service.Bridge_Command_Sink {
	return project_service.Bridge_Command_Sink{
		ctx = rawptr(state),
		send_runtime_command = proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
			(^T10_Sink_State)(ctx).sent_calls += 1
			return true, {}
		},
		send_runtime_command_wait = proc(ctx: rawptr, command: project_service.Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error) {
			s := (^T10_Sink_State)(ctx)
			s.wait_calls += 1
			return strings.clone(s.reply), true, {}
		},
	}
}

// The REST keystroke path (agent_service_send_pty_input / bridge_service.send_shell_input
// with wait_for_result) shares this helper.
@(test)
test_t10_checked_send_surfaces_vault_locked_from_command_result :: proc(t: ^testing.T) {
	cmd := project_service.Runtime_Command{bridge_id = "brg_t10", command_id = "cmd_1", body_json = `{"type":"shell_pty_input"}`}

	locked := T10_Sink_State{reply = `{"type":"command_result","protocol_version":1,"command_id":"cmd_1","payload":{"status":"failed","error_code":"vault_locked"}}`}
	ok, err := project_service.bridge_command_send_runtime_checked(t10_sink(&locked), cmd, true)
	testing.expect(t, !ok, "a locked refusal is not a delivery")
	testing.expect_value(t, err.code, domain.Error_Code.Vault_Locked)
	testing.expect(t, strings.contains(err.details_json, "brg_t10"), err.details_json)
	testing.expect_value(t, locked.wait_calls, 1)

	// Any other outcome keeps the old fire-and-forget answer: delivered.
	plain_fail := T10_Sink_State{reply = `{"type":"command_result","protocol_version":1,"command_id":"cmd_1","payload":{"status":"failed"}}`}
	ok2, err2 := project_service.bridge_command_send_runtime_checked(t10_sink(&plain_fail), cmd, true)
	testing.expect(t, ok2, "an untyped failure keeps the pre-T10 contract")
	testing.expect_value(t, err2.code, domain.Error_Code.None)

	// The WebSocket pane path does not wait.
	no_wait := T10_Sink_State{reply = locked.reply}
	ok3, _ := project_service.bridge_command_send_runtime_checked(t10_sink(&no_wait), cmd, false)
	testing.expect(t, ok3, "fire-and-forget when not waiting")
	testing.expect_value(t, no_wait.wait_calls, 0)
	testing.expect_value(t, no_wait.sent_calls, 1)

	// A sink without a wait proc falls back to the plain send.
	fallback := T10_Sink_State{}
	sink := t10_sink(&fallback)
	sink.send_runtime_command_wait = nil
	ok4, _ := project_service.bridge_command_send_runtime_checked(sink, cmd, true)
	testing.expect(t, ok4, "no wait proc -> plain send")
	testing.expect_value(t, fallback.sent_calls, 1)
}

// The pane-stream path: the viewer frame and the start-refused user event.
@(test)
test_t10_vault_locked_viewer_frame_and_exit_event_shape :: proc(t: ^testing.T) {
	frame := shell_session_svc._vault_locked_frame_json("inst_t10", "brg_t10")
	defer delete(frame)
	testing.expect(t, strings.contains(frame, `"type":"error"`), frame)
	testing.expect(t, strings.contains(frame, `"code":"vault_locked"`), frame)
	testing.expect(t, strings.contains(frame, `"bridge_id":"brg_t10"`), frame)
	testing.expect(t, strings.contains(frame, `"session_id":"inst_t10"`), frame)
	testing.expect(t, strings.contains(frame, `"message":"`), "older clients still get a message")

	evt := shell_session_svc._shell_exited_event_json("sh_t10", "failed", 0, false, "vault_locked", "brg_t10")
	defer delete(evt)
	testing.expect(t, strings.contains(evt, `"type":"shell_session_exited"`), evt)
	testing.expect(t, strings.contains(evt, `"error_code":"vault_locked"`), evt)
	testing.expect(t, strings.contains(evt, `"bridge_id":"brg_t10"`), evt)
	testing.expect(t, !strings.contains(evt, "exit_code"), "a synthesized terminal never claims an exit code")

	plain := shell_session_svc._shell_exited_event_json("sh_t10", "exited", 3, true)
	defer delete(plain)
	testing.expect(t, !strings.contains(plain, "error_code"), "ordinary exits are unchanged")
}
