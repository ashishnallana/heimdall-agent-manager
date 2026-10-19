// Behavioral tests for agent instance input endpoint, ECIES encryption golden vectors, and vault lock enforcement.
package http

import agent_service "odin_test:hub/service/agent"
import "core:strings"
import "core:testing"

// --- Consolidated from agent_instance_input_test.odin ---

@(test)
test_json_string_unicode_escapes :: proc(t: ^testing.T) {
	body := `{"data":"hello\u0020world\u000a\u001b[31mred\u001b[0m"}`
	parsed := json_string(body, "data")
	defer delete(parsed)

	testing.expect_value(t, parsed, "hello world\n\x1b[31mred\x1b[0m")
}

@(test)
test_json_string_ctrl_c :: proc(t: ^testing.T) {
	body := `{"data":"\u0003"}`
	parsed := json_string(body, "data")
	defer delete(parsed)

	testing.expect_value(t, parsed, "\x03")
}

@(test)
test_input_frame_single_encrypted_payload :: proc(t: ^testing.T) {
	body := `{"type":"input","data_b64":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==","is_encrypted":true}`
	frame := shell_stream_decode_input_frame(body)
	defer shell_stream_input_destroy(&frame)
	testing.expect_value(t, frame.kind, Shell_Stream_Input_Kind.Armored)
	testing.expect_value(t, frame.armored, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==")
	testing.expect_value(t, frame.plain, "")
}

@(test)
test_input_frame_plain_data_b64_unchanged :: proc(t: ^testing.T) {
	frame := shell_stream_decode_input_frame(`{"type":"input","data_b64":"bHMgLWxhCg==","is_encrypted":false}`)
	defer shell_stream_input_destroy(&frame)
	testing.expect_value(t, frame.kind, Shell_Stream_Input_Kind.Plain)
	testing.expect_value(t, frame.plain, "ls -la\n")
}

@(test)
test_input_frame_plain_data_b64_ctrl_c :: proc(t: ^testing.T) {
	frame := shell_stream_decode_input_frame(`{"type":"input","data_b64":"Aw==","is_encrypted":false}`)
	defer shell_stream_input_destroy(&frame)
	testing.expect_value(t, frame.kind, Shell_Stream_Input_Kind.Plain)
	testing.expect_value(t, frame.plain, "\x03")
}

@(test)
test_input_frame_requires_unambiguous_flag_and_payload :: proc(t: ^testing.T) {
	bodies := []string{
		`{"type":"input","enc_b64":"QUJD"}`,
		`{"type":"input","data_b64":"QUJD"}`,
		`{"type":"input","data_b64":"QUJD","is_encrypted":"false"}`,
		`{"type":"input","data_b64":"vault:v2:QUJD","is_encrypted":true}`,
		`{"type":"input","data_b64":"not!base64","is_encrypted":false}`,
		`{"type":"input","data_b64":"QUJD","is_encrypted":true}`,
	}
	for body in bodies {
		frame := shell_stream_decode_input_frame(body)
		testing.expect_value(t, frame.kind, Shell_Stream_Input_Kind.Undecodable)
		testing.expect_value(t, frame.plain, "")
		testing.expect_value(t, frame.armored, "")
		testing.expect(t, frame.reason != "")
		shell_stream_input_destroy(&frame)
	}
}

// --- Consolidated from agent_instance_input_golden_vector_test.odin ---

C1_GOLDEN_KEY_HEX :: "4f1c2a9d8e7b6a5c4d3e2f10112233445566778899aabbccddeeff0011223344"
C1_GOLDEN_PLAINTEXT :: "ls -la\n"
C1_GOLDEN_ENC_B64 :: "vFQrdD8pfrvPMg80AH82Q+0Ryd+5fD++WZUYiGUzlU+BsSo="
C1_GOLDEN_FRAME :: `{"type":"input","data_b64":"vFQrdD8pfrvPMg80AH82Q+0Ryd+5fD++WZUYiGUzlU+BsSo=","is_encrypted":true}`

@(test)
test_agent_pane_relays_real_browser_armored_frame :: proc(t: ^testing.T) {
	frame := shell_stream_decode_input_frame(C1_GOLDEN_FRAME)
	defer shell_stream_input_destroy(&frame)

	testing.expect_value(t, frame.kind, Shell_Stream_Input_Kind.Armored)
	testing.expect_value(t, frame.armored, C1_GOLDEN_ENC_B64)
	// REQ-PANE-INPUT-6: the Hub holds no vault key, so it must never claim a plaintext.
	testing.expect_value(t, frame.plain, "")

	cmd := agent_service.agent_pty_input_command_json("cmd_golden", "inst_golden", frame.plain, frame.armored)
	defer delete(cmd)

	testing.expect(t, strings.contains(cmd, "\"type\":\"shell_pty_input\""), "bridge command type")
	// The bridge resolves the pty from shell_id (REQ-PTY-NET-3 dropped the duplicated
	// agent_instance_id from the envelope; the bridge keys both panes on shell_id).
	testing.expect(t, strings.contains(cmd, "\"shell_id\":\"inst_golden\""), "pty addressed by shell_id")
	testing.expect(t, !strings.contains(cmd, "agent_instance_id"), "no duplicated agent_instance_id on the wire")
	testing.expect(
		t,
		strings.contains(cmd, strings.concatenate({"\"data_b64\":\"", C1_GOLDEN_ENC_B64, "\""}, context.temp_allocator)),
		"ciphertext relayed byte-for-byte",
	)
	testing.expect(t, strings.contains(cmd, "\"is_encrypted\":true"))
	testing.expect(t, !strings.contains(cmd, "enc_b64"))
	testing.expect(t, !strings.contains(cmd, "vault:v2:"))
	testing.expect(t, !strings.contains(cmd, "\"data\":"))
}
