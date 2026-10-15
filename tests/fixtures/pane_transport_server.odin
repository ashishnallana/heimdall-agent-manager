package main

import base64 "core:encoding/base64"
import "core:fmt"
import "base:runtime"
import "core:net"
import "core:strings"
import "core:time"
import jsonx "odin_test:lib/jsonx"
import shell "odin_test:hub/service/shell_session"
import http "odin_test:hub/transport/http"

// Isolated fixture using production Hub fan-out and capture formatting. The
// client sends newline-delimited commands and receives actual WS wire frames.
main :: proc() {
	listener, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if err != nil do panic("listen failed")
	defer net.close(listener)
	ep, _ := net.bound_endpoint(listener)
	fmt.printfln("PANE_TEST_PORT=%d", ep.port)
	client, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil do panic("accept failed")
	defer net.close(client)
	_ = net.set_option(client, .Receive_Timeout, 10 * time.Second)
	svc := shell.new_shell_session_service()
	defer shell.shell_session_service_free(&svc)
	shell.shell_session_attach(&svc, "pane", client, "bridge")
	defer shell.shell_session_detach(&svc, "pane", client)
	pending := make([dynamic]byte)
	defer delete(pending)
	buf: [16384]byte
	for {
		n, read_err := net.recv_tcp(client, buf[:])
		if read_err != nil || n <= 0 do return
		append(&pending, ..buf[:n])
		for {
			end := strings.index_byte(string(pending[:]), '\n')
			if end < 0 do break
			temp := runtime.default_temp_allocator_temp_begin()
			defer runtime.default_temp_allocator_temp_end(temp)
			command := strings.clone(string(pending[:end]))
			copy(pending[:], pending[end+1:])
			resize(&pending, len(pending)-end-1)
			if command == "quit" { delete(command); return }
			kind := jsonx.extract_string(command, "type")
			switch kind {
			case "output":
				// The test still hands the fixture base64 (it is a JSON command line); the
				// production fan-out takes the decoded bytes (REQ-PTY-NET-2).
				data := jsonx.extract_string(command, "data_b64")
				raw, derr := base64.decode(data)
				if derr != nil do panic("output data_b64 must be valid base64")
				shell.shell_session_broadcast_output(&svc, "pane", raw, jsonx.extract_bool(command, "is_encrypted"))
				delete(raw)
				delete(data)
			case "capture":
				if !http._shell_stream_write_screen_frame(&svc, "pane", client, command) do panic("capture failed")
			case "done":
				_ = shell.shell_session_write_viewer_frame(&svc, "pane", client, "{\"type\":\"ready\"}")
			}
			delete(kind)
			delete(command)
		}
	}
}
