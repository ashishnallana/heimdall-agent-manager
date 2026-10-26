package http

import base64 "core:encoding/base64"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:testing"
import domain "odin_test:hub/domain"
import contracts "odin_test:contracts"
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import project_service "odin_test:hub/service/project"

@(private = "file")
Audit_Sock_Pair :: struct {
	listener: net.TCP_Socket,
	client:   net.TCP_Socket,
	hub:      net.TCP_Socket,
}

@(private = "file")
make_audit_sock_pair :: proc(t: ^testing.T) -> (Audit_Sock_Pair, bool) {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil {
		testing.fail_now(t, "could not listen on loopback")
	}
	bound, bound_err := net.bound_endpoint(listener)
	if bound_err != nil {
		net.close(listener)
		testing.fail_now(t, "could not read bound endpoint")
	}
	client, dial_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if dial_err != nil {
		net.close(listener)
		testing.fail_now(t, "could not dial loopback")
	}
	hub, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil {
		net.close(listener)
		net.close(client)
		testing.fail_now(t, "could not accept on loopback")
	}
	return Audit_Sock_Pair{listener = listener, client = client, hub = hub}, true
}

@(private = "file")
close_audit_sock_pair :: proc(p: ^Audit_Sock_Pair) {
	net.close(p.hub)
	net.close(p.client)
	net.close(p.listener)
}

@(private = "file")
make_sized_json_payload :: proc(total_len: int) -> []byte {
	prefix := `{"type":"fs_write_file","command_id":"cmd_audit","content":"`
	suffix := `"}`
	out := make([]byte, total_len)
	copy(out[:len(prefix)], transmute([]byte)prefix)
	fill_end := total_len - len(suffix)
	for i in len(prefix) ..< fill_end {
		out[i] = 'x'
	}
	copy(out[fill_end:], transmute([]byte)suffix)
	return out
}

@(private = "file")
make_masked_ws_frame_with_first_byte :: proc(first_byte: byte, payload: string, mask: [4]byte) -> [dynamic]byte {
	n := len(payload)
	out := make([dynamic]byte)
	append(&out, first_byte)
	if n <= 125 {
		append(&out, byte(0x80 | n))
	} else if n <= 65535 {
		append(&out, byte(0x80 | 126), byte((n >> 8) & 0xff), byte(n & 0xff))
	} else {
		append(&out, byte(0x80 | 127))
		length_u64 := u64(n)
		for shift := 56; shift >= 0; shift -= 8 {
			append(&out, byte((length_u64 >> uint(shift)) & 0xff))
		}
	}
	append(&out, mask[0], mask[1], mask[2], mask[3])
	for i in 0 ..< n {
		append(&out, payload[i] ~ mask[i % 4])
	}
	return out
}

@(private = "file")
make_audit_chunk_frame :: proc(chunk_id: string, index, count, total: int, raw: []byte) -> string {
	fragment := base64.encode(raw)
	defer delete(fragment)
	end := "true" if index + 1 == count else "false"
	return fmt.aprintf(
		`{{"version":1,"kind":"chunk","frame_id":"f","stream_id":"%s","src_daemon_id":"d","dest_daemon_id":"","original_kind":"frame","idempotency_key":"","chunk_id":"%s","chunk_index":%d,"chunk_count":%d,"total_bytes":%d,"payload_fragment":"%s","end_stream":%s}}`,
		chunk_id, chunk_id, index, count, total, fragment, end,
	)
}

// REQ-WS-AUDIT-7 (1a): Over a socketpair, prove write_ws_text_frame (which delegates
// to ws.write_server_text(client, text, false)) returns false for a 70,000-byte JSON
// payload while a 65,535-byte payload succeeds.
@(test)
test_audit_claim_write_ws_text_frame_rejects_over_65535 :: proc(t: ^testing.T) {
	pair, ok := make_audit_sock_pair(t)
	if !ok do return
	defer close_audit_sock_pair(&pair)

	payload_65535 := make_sized_json_payload(65_535)
	defer delete(payload_65535)
	testing.expect_value(t, len(payload_65535), 65_535)

	wrote_max_16bit := write_ws_text_frame(pair.hub, string(payload_65535))
	testing.expect(t, wrote_max_16bit, "write_ws_text_frame must succeed for a 65,535-byte payload")

	payload_70000 := make_sized_json_payload(70_000)
	defer delete(payload_70000)
	testing.expect_value(t, len(payload_70000), 70_000)

	wrote_over_65535 := write_ws_text_frame(pair.hub, string(payload_70000))
	testing.expect(t, !wrote_over_65535, "write_ws_text_frame must return false for a 70,000-byte JSON payload (> 65535)")
}

// REQ-WS-AUDIT-7 (1b): Feed a valid RFC 6455 masked text frame with 64-bit extended
// payload length (70,000 bytes, header[1] = 0x80 | 127) into Bridge_WS_Reader;
// prove bridge_ws_take_frame decodes it intact (ok=true, fatal=false).
// Also verify that an invalid/oversized 64-bit length (> 32 MiB or MSB set) returns ok=false, fatal=true.
@(test)
test_audit_claim_bridge_ws_take_frame_rejects_64bit_length_as_fatal :: proc(t: ^testing.T) {
	reader := Bridge_WS_Reader{}
	defer bridge_ws_reader_destroy(&reader)

	payload_70k := make_sized_json_payload(70_000)
	defer delete(payload_70k)

	frame_64bit := make_masked_ws_frame_with_first_byte(0x81, string(payload_70k), {0x12, 0x34, 0x56, 0x78})
	defer delete(frame_64bit)
	testing.expect_value(t, frame_64bit[0], byte(0x81))
	testing.expect_value(t, frame_64bit[1], byte(0x80 | 127))

	append(&reader.pending, ..frame_64bit[:])

	text, ok, fatal := bridge_ws_take_frame(&reader)
	defer delete(text)
	testing.expect(t, ok, "bridge_ws_take_frame must return ok=true on valid 64-bit length indicator 127")
	testing.expect(t, !fatal, "bridge_ws_take_frame must return fatal=false on valid 64-bit length indicator 127")
	testing.expect_value(t, len(text), 70_000)
	testing.expect_value(t, text, string(payload_70k))

	// Verify that an invalid/oversized 64-bit length (> 32 MiB or MSB set) returns ok=false, fatal=true
	bad_reader := Bridge_WS_Reader{}
	defer bridge_ws_reader_destroy(&bad_reader)
	append(&bad_reader.pending, 0x81, 0xff, 0x80, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x00, 0x00, 0x00)
	bad_text, bad_ok, bad_fatal := bridge_ws_take_frame(&bad_reader)
	defer delete(bad_text)
	testing.expect(t, !bad_ok, "oversized/MSB-set 64-bit frame must return ok=false")
	testing.expect(t, bad_fatal, "oversized/MSB-set 64-bit frame must return fatal=true")
}

// REQ-WS-AUDIT-7 (1c): Feed a 2-fragment RFC 6455 message (frame 1: 0x01 FIN=0 masked
// first half of JSON; interleaved masked Ping frame; frame 2: 0x80 FIN=1 masked second half of JSON) into
// Bridge_WS_Reader; prove bridge_ws_take_frame reassembles the complete JSON message
// with ok=true, fatal=false, and that interleaved Ping does not cause fatal=true.
@(test)
test_audit_claim_bridge_ws_take_frame_corrupts_fragmented_message :: proc(t: ^testing.T) {
	reader := Bridge_WS_Reader{}
	defer bridge_ws_reader_destroy(&reader)

	first_half := `{"type":"bridge_heartbeat","part":1`
	second_half := `,"part2":2}`

	// Frame 1: 0x01 (FIN=0, opcode=0x1 text)
	frag1 := make_masked_ws_frame_with_first_byte(0x01, first_half, {0xaa, 0xbb, 0xcc, 0xdd})
	defer delete(frag1)
	// Interleaved masked Ping frame (0x89 FIN=1 opcode=0x9, masked 0-length)
	ping := [6]byte{0x89, 0x80, 0x12, 0x34, 0x56, 0x78}
	// Frame 2: 0x80 (FIN=1, opcode=0x0 continuation)
	frag2 := make_masked_ws_frame_with_first_byte(0x80, second_half, {0x11, 0x22, 0x33, 0x44})
	defer delete(frag2)

	append(&reader.pending, ..frag1[:])
	append(&reader.pending, ..ping[:])
	append(&reader.pending, ..frag2[:])

	// Reassembles frag1 + frag2 into complete message, ignoring interleaved Ping
	text, ok, fatal := bridge_ws_take_frame(&reader)
	defer delete(text)
	testing.expect(t, ok, "bridge_ws_take_frame must return ok=true when reassembling fragmented frames")
	testing.expect(t, !fatal, "bridge_ws_take_frame must return fatal=false on fragmented frame sequence with ping")
	testing.expect_value(t, text, `{"type":"bridge_heartbeat","part":1,"part2":2}`)
	testing.expect_value(t, len(reader.pending), 0)
}

// REQ-WS-AUDIT-7 (1d): On origin/main (05ffa6cf / REQ-SHELL-36):
// 1. Prove bridge_runtime_service.write_ws_text_frame (bridge_runtime.odin:241-243) still
//    hard-rejects payloads > 65,535 bytes (70,000 bytes -> false).
// 2. Prove bridge_runtime_service.hub_command_chunk_frames / write_ws_command (bridge_runtime.odin:204-234)
//    splits a 70,000-byte payload into 12 kind:"chunk" frames with >33% base64 + JSON envelope
//    amplification (> 94,000 wire bytes) and rejects payloads > BRIDGE_WS_MAX_REASSEMBLY_BYTES
//    (16 MiB + 1) with .Too_Large -> .Validation_Failed, while a closed socket returns
//    .Send_Failed -> .Bridge_Offline ("bridge websocket command send failed").
@(test)
test_audit_claim_hub_to_bridge_large_json_command_dropped :: proc(t: ^testing.T) {
	pair, ok := make_audit_sock_pair(t)
	if !ok do return
	defer net.close(pair.listener)

	large_body := make_sized_json_payload(70_000)
	defer delete(large_body)

	// 1. Direct frame writer still hard-rejects > 65,535 bytes.
	direct_wrote := bridge_runtime_service.write_ws_text_frame(pair.hub, string(large_body))
	testing.expect(t, !direct_wrote, "bridge_runtime.write_ws_text_frame must return false when len(text) > 65,535")

	// 2. Application-level chunker splits 70,000 bytes into 12 frames at 6,000 bytes/chunk
	//    with >33% base64 + JSON envelope amplification.
	chunks := bridge_runtime_service.hub_command_chunk_frames(
		string(large_body),
		contracts.BRIDGE_WS_HUB_TO_BRIDGE_CHUNK_PAYLOAD_BYTES,
	)
	defer {
		for c in chunks do delete(c)
		delete(chunks)
	}
	testing.expect_value(t, len(chunks), 12)
	total_wire_bytes := 0
	for c in chunks do total_wire_bytes += len(c)
	testing.expect(t, total_wire_bytes > 94_000, "base64 + JSON chunk framing amplifies 70,000 bytes to > 94,000 bytes on the wire")

	// 3. Payloads exceeding BRIDGE_WS_MAX_REASSEMBLY_BYTES (16 MiB) are rejected with
	//    .Too_Large -> .Validation_Failed before touching the socket.
	registry := project_service.Bridge_Runtime_Registry{}
	bridge_id := "brg_audit_large_cmd"
	project_service.bridge_runtime_registry_mark_live(&registry, bridge_id, false, "")
	project_service.bridge_runtime_registry_set_command_socket(&registry, bridge_id, pair.hub)

	over_cap := make([]byte, contracts.BRIDGE_WS_MAX_REASSEMBLY_BYTES + 1)
	defer delete(over_cap)
	write_res := bridge_runtime_service.write_ws_command(pair.hub, string(over_cap))
	testing.expect_value(t, write_res, bridge_runtime_service.Command_Write_Result.Too_Large)

	over_cap_cmd := project_service.Runtime_Command{
		bridge_id  = bridge_id,
		command_id = "cmd_audit_over_16mib",
		body_json  = string(over_cap),
	}
	sent_over, derr_over := bridge_runtime_service.send_runtime_command(&registry, over_cap_cmd)
	testing.expect(t, !sent_over, "send_runtime_command must reject payloads > BRIDGE_WS_MAX_REASSEMBLY_BYTES")
	testing.expect_value(t, derr_over.code, domain.Error_Code.Validation_Failed)

	// 4. On a dead socket, send_runtime_command returns .Bridge_Offline ("bridge websocket command send failed").
	// The peer is closed and the hub end SHUT DOWN, not closed: closing an fd the
	// registry still holds would let a parallel test's new socket reuse the number
	// (AGENTS.md, socket lifetime), making this assertion depend on scheduling.
	net.close(pair.client)
	_ = net.shutdown(pair.hub, .Both)
	defer net.close(pair.hub)
	small_cmd := project_service.Runtime_Command{
		bridge_id  = bridge_id,
		command_id = "cmd_audit_closed_sock",
		body_json  = `{"type":"lsp_stop","session_id":"s1"}`,
	}
	sent_closed, derr_closed := bridge_runtime_service.send_runtime_command(&registry, small_cmd)
	testing.expect(t, !sent_closed)
	testing.expect_value(t, derr_closed.code, domain.Error_Code.Bridge_Offline)
	testing.expect_value(t, derr_closed.message, "bridge websocket command send failed")
}

// REQ-WS-AUDIT-7 (1e): Feed chunk_index=0 of chunk_count=3 into bridge_ws_reassemble_chunk;
// prove complete=false, ok=true, and len(reassemblies)==1 persists across subsequent calls
// because the REQ-SHELL-32 TTL sweep at bridge_handlers.odin:1420 only triggers when
// len(reassemblies) >= BRIDGE_WS_MAX_REASSEMBLIES (64) (clean up reassemblies at end of test
// so 0 leaks occur).
@(test)
test_audit_claim_abandoned_chunk_streams_persist_below_admission_cap :: proc(t: ^testing.T) {
	reassemblies := make([dynamic]Bridge_Chunk_Reassembly)
	defer bridge_chunk_reassemblies_free(&reassemblies)

	// Feed chunk 0 of 3 for an abandoned stream that never sends chunks 1 or 2.
	abandoned_f0 := make_audit_chunk_frame("chunk_abandoned", 0, 3, 15, transmute([]byte)string("01234"))
	defer delete(abandoned_f0)

	assembled0, complete0, ok0 := bridge_ws_reassemble_chunk(&reassemblies, abandoned_f0)
	testing.expect(t, ok0, "first chunk of abandoned stream is accepted (ok=true)")
	testing.expect(t, !complete0, "stream with 1 of 3 chunks is incomplete (complete=false)")
	testing.expect_value(t, assembled0, "")
	testing.expect_value(t, len(reassemblies), 1)

	// Age the abandoned stream well past BRIDGE_WS_REASSEMBLY_TTL (30s).
	reassemblies[0].started_at_ns -= i64(2 * BRIDGE_WS_REASSEMBLY_TTL)

	// Feed subsequent unrelated complete streams through bridge_ws_reassemble_chunk;
	// verify the expired abandoned stream is swept on admission of chunk_complete_1.
	other_payload := "complete-payload"
	other_f0 := make_audit_chunk_frame("chunk_complete_1", 0, 2, len(other_payload), transmute([]byte)other_payload[:8])
	other_f1 := make_audit_chunk_frame("chunk_complete_1", 1, 2, len(other_payload), transmute([]byte)other_payload[8:])
	defer delete(other_f0)
	defer delete(other_f1)

	_, c_complete0, c_ok0 := bridge_ws_reassemble_chunk(&reassemblies, other_f0)
	testing.expect(t, c_ok0)
	testing.expect(t, !c_complete0)
	testing.expect_value(t, len(reassemblies), 1)
	testing.expect_value(t, reassemblies[0].chunk_id, "chunk_complete_1")

	c_assembled1, c_complete1, c_ok1 := bridge_ws_reassemble_chunk(&reassemblies, other_f1)
	defer delete(c_assembled1)
	testing.expect(t, c_ok1)
	testing.expect(t, c_complete1)
	testing.expect_value(t, c_assembled1, other_payload)

	// chunk_complete_1 completed and was freed, leaving 0 active streams.
	testing.expect_value(t, len(reassemblies), 0)
}

// REQ-WS-AUDIT-7 (1f): On origin/main (05ffa6cf):
// 1. Verify under mem.Tracking_Allocator that bridge_runtime_service.write_ws_text_frame
//    frees its frame buffer on 05ffa6cf (REQ-SHELL-36 f6bf8ce0 at bridge_runtime.odin:252).
// 2. Prove bridge_runtime_service.json_string (bridge_runtime.odin:285-294) truncates
//    string values at the first escaped quote (\") because it scans with `if rest[i] == '"'`
//    without backslash handling, AND returns an uncloned subslice aliasing the input buffer,
//    which bridge_runtime_service.parse_validation_result (bridge_runtime.odin:149-168) stores
//    directly into Project_Path_Validation_Result.validation_error (forcing
//    send_validate_project_path_command at bridge_runtime.odin:135-139 to leak the
//    ws.poll_text string on the heap to avoid a use-after-free).
@(test)
test_audit_claim_bridge_runtime_write_ws_text_frame_leaks_frame_buffer :: proc(t: ^testing.T) {
	pair, ok := make_audit_sock_pair(t)
	if !ok do return
	defer close_audit_sock_pair(&pair)

	payload := `{"type":"lsp_send","command_id":"cmd_leak_audit","payload":"hello"}`

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	wrote := false
	{
		context.allocator = mem.tracking_allocator(&track)
		wrote = bridge_runtime_service.write_ws_text_frame(pair.hub, payload)
	}
	testing.expect(t, wrote, "bridge_runtime.write_ws_text_frame should succeed on live socketpair")
	testing.expect_value(t, len(track.allocation_map), 0)

	// Verify bridge_runtime.json_string unescapes \" without truncation and returns an owned string.
	raw_json := `{"type":"project_path_validation_result","command_id":"cmd_1","ok":false,"validation_error":"invalid path \"/tmp/ws\" here","code":"bad_path"}`
	extracted := bridge_runtime_service.json_string(raw_json, "validation_error")
	defer delete(extracted)
	testing.expect_value(t, extracted, `invalid path "/tmp/ws" here`)

	cmd := project_service.Validate_Project_Path_Command{
		type       = "validate_project_path",
		command_id = "cmd_1",
		project_id = "proj_1",
		bridge_id  = "brg_1",
		path       = "/tmp/ws",
	}
	// REQ-ERR-PROTO-A: the reply's failure is the typed wire error object.
	wire_json := `{"type":"project_path_validation_result","command_id":"cmd_1","ok":false,"error":{"code":"validation_failed","class":"fatal","cause":"bad_path","message":"invalid path \"/tmp/ws\" here"}}`
	parsed := bridge_runtime_service.parse_validation_result(cmd, wire_json)
	defer delete(parsed.details_json)
	defer delete(parsed.validation_error)

	testing.expect(t, !parsed.ok)
	testing.expect_value(t, parsed.validation_error, `invalid path "/tmp/ws" here`)

	// Prove parsed.validation_error is an owned string allocated separately, not pointing inside the reply.
	raw_start := uintptr(raw_data(wire_json))
	raw_end := raw_start + uintptr(len(wire_json))
	err_ptr := uintptr(raw_data(parsed.validation_error))
	testing.expect(t, err_ptr < raw_start || err_ptr >= raw_end, "parsed.validation_error is an owned string, not aliasing raw_json")
}
