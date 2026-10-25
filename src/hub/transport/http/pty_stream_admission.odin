package http

import "core:net"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import ws "odin_test:lib/ws"

// Agent automation does not consume the user's plan allowance.
pty_stream_user_id :: proc(auth: contracts.Auth_Context) -> string {
	if contracts.is_user_auth(auth) do return auth.user_id
	return ""
}

// Admission failed before a writer was registered, so this request owns writes.
// Send the actionable error before close; shutting down during attach would lose it.
write_pty_attach_error :: proc(client: net.TCP_Socket, err: domain.Domain_Error) {
	_ = net.set_option(client, .Send_Timeout, 5 * time.Second)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\"type\":\"error\",\"code\":\"")
	write_handler_json_string(&b, domain.error_code_string(err.code))
	strings.write_string(&b, "\",\"message\":\"")
	write_handler_json_string(&b, err.message)
	strings.write_string(&b, "\",\"details\":")
	strings.write_string(&b, err.details_json if err.details_json != "" else "{}")
	strings.write_string(&b, "}")
	_ = ws.write_server_opcode(client, 0x1, strings.to_string(b), true)
	// Private code 4402 signals a plan refusal; 1011 covers other admission failures.
	close_payload := "\x11\x32" if err.code == .Plan_Limit_Reached else "\x03\xf3"
	_ = ws.write_server_opcode(client, 0x8, close_payload, true)
}
