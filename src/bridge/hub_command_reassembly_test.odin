package main

// Tests for bridge-side reassembly of chunked hub->bridge commands (REQ-SHELL-36).
//
// Three things are being proven, and the third is the one the chain's core invariant
// depends on:
//   1. ROUND TRIP — an ordered chunk sequence rebuilds the original command exactly.
//   2. HOSTILE/MALFORMED INPUT is dropped without dispatching and without allocating an
//      unbounded buffer.
//   3. ALL-OR-NOTHING — an INTERRUPTED sequence (the reconnect case) never dispatches a
//      partial command, and the partial dies with the connection rather than lingering.

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:testing"
import base64 "core:encoding/base64"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"
import ws "odin_test:lib/ws"

// _chunk_frame builds one hub->bridge chunk frame. Hand-rolled rather than reusing the
// hub's builder because src/bridge cannot import a hub package; the cross-direction
// shape agreement is proven separately by
// hub_command_reassemble_accepts_the_bridges_own_chunk_shape below.
@(private = "file")
_chunk_frame :: proc(chunk_id: string, index, count, total: int, raw: string) -> string {
	frag := base64.encode(transmute([]byte)raw)
	defer delete(frag)
	b := strings.builder_make()
	strings.write_string(&b, `{"version":1,"kind":"`)
	strings.write_string(&b, contracts.BRIDGE_WS_FRAME_KIND_CHUNK)
	strings.write_string(&b, `","chunk_id":"`)
	strings.write_string(&b, chunk_id)
	strings.write_string(&b, `","chunk_index":`)
	strings.write_int(&b, index)
	strings.write_string(&b, `,"chunk_count":`)
	strings.write_int(&b, count)
	strings.write_string(&b, `,"total_bytes":`)
	strings.write_int(&b, total)
	strings.write_string(&b, `,"payload_fragment":"`)
	strings.write_string(&b, string(frag))
	strings.write_string(&b, `","end_stream":`)
	strings.write_string(&b, "true" if index + 1 == count else "false")
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

// _split cuts `text` into `payload`-sized raw slices, mirroring what the hub chunker does.
@(private = "file")
_split :: proc(text: string, payload: int) -> []string {
	count := (len(text) + payload - 1) / payload
	out := make([]string, count)
	for i in 0 ..< count {
		start := i * payload
		end := start + payload
		if end > len(text) do end = len(text)
		out[i] = text[start:end]
	}
	return out
}

@(test)
hub_command_reassemble_round_trips_in_order :: proc(t: ^testing.T) {
	buf := make([dynamic]Hub_Command_Reassembly)
	defer hub_command_reassemblies_free(&buf)

	original := strings.repeat("lsp-didOpen-payload-", 600) // 12000 bytes
	defer delete(original)
	parts := _split(original, 1000)
	defer delete(parts)

	assembled := ""
	for p, i in parts {
		f := _chunk_frame("cid-order", i, len(parts), len(original), p)
		defer delete(f)
		out, complete, ok := hub_command_reassemble(&buf, f)
		testing.expect(t, ok, "a well-formed chunk must be accepted")
		if i + 1 < len(parts) {
			testing.expect(t, !complete, "an incomplete stream must NOT dispatch")
		} else {
			testing.expect(t, complete, "the final chunk must complete the stream")
			assembled = out
		}
	}
	defer delete(assembled)
	testing.expect_value(t, len(assembled), len(original))
	testing.expect(t, assembled == original, "reassembly must reproduce the command byte-for-byte")
	testing.expect_value(t, len(buf), 0) // completed streams are removed, not retained
}

@(test)
hub_command_reassemble_tolerates_out_of_order_and_duplicates :: proc(t: ^testing.T) {
	// The wire is ordered today (one connection, hub holds the command lock across a
	// sequence), so this is defence in depth rather than an expected case. The duplicate
	// half matters most: a retransmit must not double-count received_chunks and complete
	// the stream early WITH A HOLE IN IT.
	buf := make([dynamic]Hub_Command_Reassembly)
	defer hub_command_reassemblies_free(&buf)
	original := "ABCDEFGHIJ"
	parts := _split(original, 2) // 5 chunks of 2
	defer delete(parts)

	order := [5]int{4, 0, 3, 1, 2}
	assembled := ""
	for slot, n in order {
		f := _chunk_frame("cid-ooo", slot, 5, len(original), parts[slot])
		defer delete(f)
		// Send each chunk TWICE; the duplicate must change nothing.
		out1, c1, ok1 := hub_command_reassemble(&buf, f)
		testing.expect(t, ok1, "first copy accepted")
		out2, c2, ok2 := hub_command_reassemble(&buf, f)
		testing.expect(t, ok2, "duplicate accepted without corrupting the stream")
		if n + 1 < len(order) {
			testing.expect(t, !c1 && !c2, "stream must not complete before every slot is filled")
		} else {
			testing.expect(t, c1, "the last distinct chunk completes the stream")
			assembled = out1
			_ = c2
			_ = out2
		}
		_ = out2
	}
	defer delete(assembled)
	testing.expect(t, assembled == original, "out-of-order arrival must still rebuild in index order")
}

@(test)
hub_command_reassemble_rejects_malformed_and_over_cap :: proc(t: ^testing.T) {
	buf := make([dynamic]Hub_Command_Reassembly)
	defer hub_command_reassemblies_free(&buf)

	expect_dropped :: proc(t: ^testing.T, buf: ^[dynamic]Hub_Command_Reassembly, frame, why: string) {
		_, complete, ok := hub_command_reassemble(buf, frame)
		testing.expect(t, !ok, why)
		testing.expect(t, !complete, "a rejected frame must never dispatch")
	}

	// Missing chunk_id.
	f1 := _chunk_frame("", 0, 2, 10, "aa"); defer delete(f1)
	expect_dropped(t, &buf, f1, "a frame with no chunk_id must be dropped")
	// index >= count.
	f2 := _chunk_frame("c", 5, 2, 10, "aa"); defer delete(f2)
	expect_dropped(t, &buf, f2, "chunk_index beyond chunk_count must be dropped")
	// chunk_count over the shared cap.
	f3 := _chunk_frame("c", 0, contracts.BRIDGE_WS_MAX_CHUNK_COUNT + 1, 1 << 20, "aa"); defer delete(f3)
	expect_dropped(t, &buf, f3, "chunk_count over the contract cap must be dropped")
	// total_bytes over the shared cap.
	f4 := _chunk_frame("c", 0, 2, contracts.BRIDGE_WS_MAX_REASSEMBLY_BYTES + 1, "aa"); defer delete(f4)
	expect_dropped(t, &buf, f4, "total_bytes over the contract cap must be dropped")
	// A stream whose fragments would exceed its own declared total.
	f5 := _chunk_frame("over", 0, 2, 3, "aaaa"); defer delete(f5)
	expect_dropped(t, &buf, f5, "a fragment exceeding the declared total must be dropped")

	// Nothing above may have left a buffered stream behind.
	testing.expect_value(t, len(buf), 0)
}

@(test)
hub_command_reassemble_conflicting_metadata_keeps_the_stream :: proc(t: ^testing.T) {
	// A second frame claiming a different shape for an id already in flight is dropped,
	// but must NOT destroy the legitimate stream — otherwise one bad frame could cancel
	// a good command.
	buf := make([dynamic]Hub_Command_Reassembly)
	defer hub_command_reassemblies_free(&buf)
	good0 := _chunk_frame("cid-meta", 0, 2, 4, "ab"); defer delete(good0)
	_, _, ok := hub_command_reassemble(&buf, good0)
	testing.expect(t, ok, "first chunk accepted")
	testing.expect_value(t, len(buf), 1)

	bad := _chunk_frame("cid-meta", 1, 7, 99, "cd"); defer delete(bad)
	_, complete, ok2 := hub_command_reassemble(&buf, bad)
	testing.expect(t, !ok2, "conflicting metadata must be dropped")
	testing.expect(t, !complete, "and must not complete anything")
	testing.expect_value(t, len(buf), 1) // the good stream survives

	good1 := _chunk_frame("cid-meta", 1, 2, 4, "cd"); defer delete(good1)
	out, complete2, ok3 := hub_command_reassemble(&buf, good1)
	defer delete(out)
	testing.expect(t, ok3 && complete2, "the real second chunk must still complete the stream")
	testing.expect_value(t, out, "abcd")
}

@(test)
hub_command_reassemble_interrupted_sequence_never_dispatches :: proc(t: ^testing.T) {
	// >>> AC2/AC5: THE RECONNECT CASE. <<<
	// A sequence cut in half must leave a command that NEVER ARRIVED, not half a command
	// that did. The bridge must not act on a partial, and the partial must not survive
	// the connection — because the hub does not retransmit, so its tail is never coming,
	// and a partial carried across a reconnect would be exactly the two-ends-disagree
	// state the core invariant forbids.
	original := strings.repeat("interrupted-", 500) // 6000 bytes
	defer delete(original)
	parts := _split(original, 1000)
	defer delete(parts)
	testing.expect_value(t, len(parts), 6)

	buf := make([dynamic]Hub_Command_Reassembly)
	// Deliver only the first three of six chunks, as a connection dying mid-sequence
	// would.
	for i in 0 ..< 3 {
		f := _chunk_frame("cid-cut", i, len(parts), len(original), parts[i])
		defer delete(f)
		_, complete, ok := hub_command_reassemble(&buf, f)
		testing.expect(t, ok, "each delivered chunk is well-formed")
		testing.expect(t, !complete, "NOTHING may dispatch from a partial sequence")
	}
	testing.expect_value(t, len(buf), 1)                 // one stream still in flight
	testing.expect_value(t, buf[0].received_chunks, 3)   // genuinely partial
	testing.expect(t, buf[0].received_chunks < buf[0].chunk_count, "stream is incomplete by construction")

	// THE RECONNECT: the loop exits and frees its per-connection buffer. This is the
	// mechanism, not a simulation of one — bridge_hub_runtime_loop defers exactly this
	// call, so what runs here is what runs on a real disconnect.
	hub_command_reassemblies_free(&buf)

	// A FRESH connection starts with a fresh buffer and must assemble cleanly, with no
	// trace of the abandoned stream — not even if the new stream reuses the old chunk_id.
	buf2 := make([dynamic]Hub_Command_Reassembly)
	defer hub_command_reassemblies_free(&buf2)
	testing.expect_value(t, len(buf2), 0)
	assembled := ""
	for p, i in parts {
		f := _chunk_frame("cid-cut", i, len(parts), len(original), p)
		defer delete(f)
		out, complete, ok := hub_command_reassemble(&buf2, f)
		testing.expect(t, ok, "post-reconnect chunk accepted")
		if i + 1 == len(parts) {
			testing.expect(t, complete, "the retried sequence must complete on the new connection")
			assembled = out
		} else {
			testing.expect(t, !complete, "still incomplete mid-sequence")
		}
	}
	defer delete(assembled)
	testing.expect(t, assembled == original, "the retried command must arrive intact and whole")
	testing.expect_value(t, len(buf2), 0)
}

@(test)
hub_command_reassembly_expires_abandoned_streams :: proc(t: ^testing.T) {
	// The concurrency cap is only a bound if something removes incomplete entries.
    // REQ-SHELL-32 records what happens otherwise on the hub's identical code: the cap
	// became a COUNTDOWN and every chunked frame was dropped forever while the
	// connection looked healthy.
	buf := make([dynamic]Hub_Command_Reassembly)
	defer hub_command_reassemblies_free(&buf)
	f := _chunk_frame("cid-old", 0, 4, 8, "ab"); defer delete(f)
	_, _, ok := hub_command_reassemble(&buf, f)
	testing.expect(t, ok, "chunk accepted")
	testing.expect_value(t, len(buf), 1)

	// Age it past the TTL and sweep. now_ns is a parameter precisely so this is
	// deterministic instead of a sleep.
	aged := buf[0].started_at_ns + i64(HUB_COMMAND_REASSEMBLY_TTL)
	testing.expect_value(t, hub_command_reassembly_sweep(&buf, aged), 1)
	testing.expect_value(t, len(buf), 0)

	// A stream inside its TTL is NOT swept.
	f2 := _chunk_frame("cid-young", 0, 4, 8, "ab"); defer delete(f2)
	_, _, _ = hub_command_reassemble(&buf, f2)
	testing.expect_value(t, hub_command_reassembly_sweep(&buf, buf[0].started_at_ns + 1), 0)
	testing.expect_value(t, len(buf), 1)
}

@(test)
hub_command_frame_is_chunk_discriminates :: proc(t: ^testing.T) {
	// A command frame must never be mistaken for a chunk envelope, or every ordinary
	// command would be swallowed by the reassembler and nothing would work at all.
	f := _chunk_frame("cid", 0, 2, 4, "ab"); defer delete(f)
	testing.expect(t, hub_command_frame_is_chunk(f), "a chunk frame must be recognised")
	testing.expect(t, !hub_command_frame_is_chunk(`{"type":"launch_agent","command_id":"c1"}`), "a command must not be taken for a chunk")
	testing.expect(t, !hub_command_frame_is_chunk(`{"type":"bridge_heartbeat_ack","schedules_version":3}`), "a heartbeat ack must pass straight through")
	testing.expect(t, !hub_command_frame_is_chunk(""), "an empty frame is not a chunk")

	// >>> COMMANDS THAT LEGITIMATELY CARRY A "kind" FIELD MUST STILL BE DISPATCHED. <<<
	// The shell_start shape is a REAL command on this channel, not an invented one:
	// _shell_start_command_json (shell_session_service.odin) emits
	// {"type":"shell_start",...,"kind":"run"|"shell"|"server",...}. The bootstrap-manifest
	// shape below is included as a hostile INPUT only — that payload is served over HTTP
	// REST and never crosses this WS path, so it is not evidence of the hazard, just a
	// convenient nested-"kind" document to test against.
	testing.expect(t, !hub_command_frame_is_chunk(`{"type":"launch_agent","template":{"kind":"AGENTS_TEMPLATE","hash":"abc"}}`), "the agent bootstrap payload must not be taken for a chunk")
	testing.expect(t, !hub_command_frame_is_chunk(`{"type":"shell_start","kind":"run","cmd":"ls"}`), "a shell command whose kind is run must not be taken for a chunk")
	testing.expect(t, !hub_command_frame_is_chunk(`{"type":"shell_start","kind":"server","cmd":"npm run dev"}`), "kind=server must not be taken for a chunk")
	// The adversarial case the second half of the guard exists for: a COMMAND that
	// happens to nest a kind of "chunk" must still reach the dispatcher.
	testing.expect(t, !hub_command_frame_is_chunk(`{"type":"launch_agent","file":{"kind":"chunk"}}`), "a real command nesting kind=chunk must NOT be swallowed by the reassembler")
}

@(test)
hub_command_reassemble_accepts_the_bridges_own_chunk_shape :: proc(t: ^testing.T) {
	// >>> ONE PROTOCOL, NOT TWO THAT RESEMBLE EACH OTHER. <<<
	// Feed the frames the BRIDGE's own outbound chunker emits (bridge_ws_chunk_json, the
	// bridge->hub direction that has existed since REQ-SHELL-32) into the NEW inbound
	// reassembler. If the two directions ever drift apart in field names or encoding,
	// this fails — which is the check that the hub's "mirrors the bridge's own inbound
	// reassembly" comment was asserting without anything enforcing it.
	original := strings.repeat("same-wire-format-", 400)
	defer delete(original)
	frames := bridge_hub_chunk_frames_with_payload(original, 1000)
	testing.expect(t, frames != nil, "the bridge chunker must split this")
	defer {
		for f in frames do delete(f)
		delete(frames)
	}
	buf := make([dynamic]Hub_Command_Reassembly)
	defer hub_command_reassemblies_free(&buf)
	assembled := ""
	for f, i in frames {
		testing.expect(t, hub_command_frame_is_chunk(f), "the bridge's chunk frames must be recognised as chunks")
		out, complete, ok := hub_command_reassemble(&buf, f)
		testing.expect(t, ok, "the bridge's own chunk shape must be accepted")
		if i + 1 == len(frames) {
			testing.expect(t, complete, "final frame completes")
			assembled = out
		}
	}
	defer delete(assembled)
	testing.expect(t, assembled == original, "both directions must share one wire format exactly")
}

@(test)
hub_command_reassembly_wire_shell_start_reversed_keys_and_whitespace :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	// Reversed key order with arbitrary whitespace, indentation, newlines.
	raw := `
	{
		"run_seq": 5,
		"background": true,
		"server_port": 8080,
		"started_at": "2026-10-03T11:00:00Z",
		"owner_user_id": "usr_tanmay",
		"agent_instance_id": "inst_worker_1",
		"chain_id": "chain_test_99",
		"project_id": "proj_heima",
		"label": "Build Job",
		"cwd": "/tmp/test_dir",
		"cmd": "make build -j4",
		"kind": "run",
		"session_id": "sh_reversed_01",
		"command_id": "cmd_rev_01",
		"type": "shell_start"
	}
	`

	cmd: Bridge_Shell_Start_Command
	err := json.unmarshal(transmute([]byte)raw, &cmd, allocator = context.temp_allocator)
	testing.expect(t, err == nil, "unmarshaling with reversed keys and whitespace must succeed")

	testing.expect_value(t, cmd.type, "shell_start")
	testing.expect_value(t, cmd.command_id, "cmd_rev_01")
	testing.expect_value(t, cmd.session_id, "sh_reversed_01")
	testing.expect_value(t, cmd.kind, "run")
	testing.expect_value(t, cmd.cmd, "make build -j4")
	testing.expect_value(t, cmd.cwd, "/tmp/test_dir")
	testing.expect_value(t, cmd.label, "Build Job")
	testing.expect_value(t, cmd.project_id, "proj_heima")
	testing.expect_value(t, cmd.chain_id, "chain_test_99")
	testing.expect_value(t, cmd.agent_instance_id, "inst_worker_1")
	testing.expect_value(t, cmd.owner_user_id, "usr_tanmay")
	testing.expect_value(t, cmd.started_at, "2026-10-03T11:00:00Z")
	testing.expect_value(t, cmd.server_port, 8080)
	testing.expect_value(t, cmd.background, true)
	testing.expect_value(t, cmd.run_seq, 5)

	// Since unmarshaling was on context.temp_allocator, heap tracking allocator must have zero leaks
	testing.expectf(t, len(track.allocation_map) == 0, "leak: %d live allocations", len(track.allocation_map))
	testing.expect(t, len(track.bad_free_array) == 0, "no bad frees")
}

@(test)
hub_command_reassembly_wire_shell_start_special_characters :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	// JSON containing escaped double quotes, backslashes, unicode characters, tabs, newlines
	raw := `{"type":"shell_start","command_id":"cmd_spec_1","session_id":"sh_spec_1","kind":"server","cmd":"echo \"hello \\ world\" \u2764\n\t","cwd":"/path/with spaces/and \"quotes\""}`

	cmd: Bridge_Shell_Start_Command
	err := json.unmarshal(transmute([]byte)raw, &cmd, allocator = context.temp_allocator)
	testing.expect(t, err == nil, "unmarshaling with special characters must succeed")

	testing.expect_value(t, cmd.type, "shell_start")
	testing.expect_value(t, cmd.session_id, "sh_spec_1")
	testing.expect_value(t, cmd.kind, "server")
	testing.expect_value(t, cmd.cmd, "echo \"hello \\ world\" \u2764\n\t")
	testing.expect_value(t, cmd.cwd, "/path/with spaces/and \"quotes\"")

	testing.expectf(t, len(track.allocation_map) == 0, "leak: %d live allocations", len(track.allocation_map))
	testing.expect(t, len(track.bad_free_array) == 0, "no bad frees")
}

@(test)
hub_command_reassembly_wire_shell_exited_event_serialization_and_no_leak :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	event_str := bridge_shell_exited_event_json("sh_exit_test", 137, true, "killed", 3)
	testing.expect(t, len(event_str) > 0, "serialized event must not be empty")

	// Verify unmarshaling the emitted json back into Bridge_Shell_Exited_Event
	parsed: Bridge_Shell_Exited_Event
	err := json.unmarshal(transmute([]byte)event_str, &parsed, allocator = context.temp_allocator)
	testing.expect(t, err == nil, "serialized event must be valid JSON")

	testing.expect_value(t, parsed.type, "shell_exited")
	testing.expect_value(t, parsed.session_id, "sh_exit_test")
	testing.expect_value(t, parsed.exit_code, 137)
	testing.expect_value(t, parsed.exit_code_set, true)
	testing.expect_value(t, parsed.status, "killed")
	testing.expect_value(t, parsed.run_seq, 3)
	testing.expect(t, len(parsed.finished_at) > 0, "finished_at must be populated")

	// Free event_str and assert tracking allocator has 0 leaks and 0 bad frees
	delete(event_str)

	testing.expectf(t, len(track.allocation_map) == 0, "leak: %d live allocations", len(track.allocation_map))
	testing.expect(t, len(track.bad_free_array) == 0, "no bad frees")
}

@(test)
hub_command_reassembly_wire_related_commands_deserialization :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	// Test Bridge_Shell_Set_Port_Command
	set_port_raw := `{"server_port": 9001, "command_id": "cmd_p1", "session_id": "sh_p1", "type": "shell_set_port"}`
	cmd_port: Bridge_Shell_Set_Port_Command
	err := json.unmarshal(transmute([]byte)set_port_raw, &cmd_port, allocator = context.temp_allocator)
	testing.expect(t, err == nil, "set_port unmarshal ok")
	testing.expect_value(t, cmd_port.type, "shell_set_port")
	testing.expect_value(t, cmd_port.session_id, "sh_p1")
	testing.expect_value(t, cmd_port.command_id, "cmd_p1")
	testing.expect_value(t, cmd_port.server_port, 9001)

	// Test Bridge_Shell_Restart_Command
	restart_raw := `{"run_seq": 2, "command_id": "cmd_r1", "session_id": "sh_r1", "type": "shell_restart"}`
	cmd_restart: Bridge_Shell_Restart_Command
	err = json.unmarshal(transmute([]byte)restart_raw, &cmd_restart, allocator = context.temp_allocator)
	testing.expect(t, err == nil, "restart unmarshal ok")
	testing.expect_value(t, cmd_restart.type, "shell_restart")
	testing.expect_value(t, cmd_restart.session_id, "sh_r1")
	testing.expect_value(t, cmd_restart.command_id, "cmd_r1")
	testing.expect_value(t, cmd_restart.run_seq, 2)

	// Test Bridge_Shell_Logs_Command
	logs_raw := `{"grep": "error: *", "limit": 50, "offset": 10, "command_id": "cmd_l1", "session_id": "sh_l1", "type": "shell_logs"}`
	cmd_logs: Bridge_Shell_Logs_Command
	err = json.unmarshal(transmute([]byte)logs_raw, &cmd_logs, allocator = context.temp_allocator)
	testing.expect(t, err == nil, "logs unmarshal ok")
	testing.expect_value(t, cmd_logs.type, "shell_logs")
	testing.expect_value(t, cmd_logs.session_id, "sh_l1")
	testing.expect_value(t, cmd_logs.command_id, "cmd_l1")
	testing.expect_value(t, cmd_logs.offset, 10)
	testing.expect_value(t, cmd_logs.limit, 50)
	testing.expect_value(t, cmd_logs.grep, "error: *")

	testing.expectf(t, len(track.allocation_map) == 0, "leak: %d live allocations", len(track.allocation_map))
	testing.expect(t, len(track.bad_free_array) == 0, "no bad frees")
}


// A full 15 MiB html-bundle MCP job crosses both WS directions: hub->bridge at the
// 6000-byte chunk size (~4200 chunks) and the bridge's signed reply back at the
// runtime chunk size, each reassembled byte-exact and admitted to the large lane.
@(test)
test_hub_command_reassemble_full_size_mcp_bundle_job_both_directions :: proc(t: ^testing.T) {
	envelope := vault.CONTROL_JOB_ARTIFACT_PAYLOAD_MAX + 1024 * 1024
	for prefix in ([]string{`{"type":"mcp_transform","command_id":"req_big","job":{"payload":"`, `{"type":"mcp_transform_result","command_id":"req_big","reply":{"result":"`}) {
		b := strings.builder_make(0, envelope + 64, context.temp_allocator)
		strings.write_string(&b, prefix)
		for strings.builder_len(b) < envelope do strings.write_string(&b, "QUJDRA==")
		strings.write_string(&b, `"}}`)
		text := strings.to_string(b)
		payload := contracts.BRIDGE_WS_HUB_TO_BRIDGE_CHUNK_PAYLOAD_BYTES
		if strings.has_prefix(prefix, `{"type":"mcp_transform_result"`) do payload = bridge_hub_runtime_chunk_payload_bytes()
		frames := ws.chunk_frames(text, payload)
		if !testing.expectf(t, frames != nil, "%d bytes chunk at %d", len(text), payload) do continue
		buf: [dynamic]Hub_Command_Reassembly
		assembled: string
		complete := false
		for f, i in frames {
			out, done, ok := hub_command_reassemble(&buf, f)
			testing.expectf(t, ok, "frame %d accepted", i)
			if done {assembled = out; complete = true}
			delete(f)
		}
		delete(frames)
		testing.expect(t, complete && assembled == text, "reassembled byte-exact")
		if strings.has_prefix(prefix, `{"type":"mcp_transform_result"`) {
			testing.expect(t, bridge_command_dispatch_is_mcp_large_result(assembled))
		} else {
			testing.expect(t, bridge_command_dispatch_is_mcp_large("mcp_transform", len(assembled)) && len(assembled) <= BRIDGE_DISPATCH_MCP_LARGE_BYTES_LIMIT)
		}
		if complete do delete(assembled)
		hub_command_reassemblies_free(&buf)
	}
}
