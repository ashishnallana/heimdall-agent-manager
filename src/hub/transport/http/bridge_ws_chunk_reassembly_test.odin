// Behavioral tests for bridge WebSocket chunk reassembly, admission caps, and TTL expiry.
package http

import base64 "core:encoding/base64"
import contracts "odin_test:contracts"
import "core:fmt"
import "core:testing"
import "core:time"

// --- Consolidated from bridge_ws_chunk_reassembly_test.odin ---

@(private = "file")
make_chunk_frame :: proc(chunk_id: string, index, count, total: int, raw: []byte) -> string {
	fragment := base64.encode(raw)
	defer delete(fragment)
	end := "true" if index + 1 == count else "false"
	return fmt.aprintf(
		`{{"version":1,"kind":"chunk","frame_id":"f","stream_id":"%s","src_daemon_id":"d","dest_daemon_id":"","original_kind":"frame","idempotency_key":"","chunk_id":"%s","chunk_index":%d,"chunk_count":%d,"total_bytes":%d,"payload_fragment":"%s","end_stream":%s}}`,
		chunk_id, chunk_id, index, count, total, fragment, end,
	)
}

@(test)
test_reassemble_in_order :: proc(t: ^testing.T) {
	reassemblies := make([dynamic]Bridge_Chunk_Reassembly)
	defer bridge_chunk_reassemblies_free(&reassemblies)
	original := `{"type":"fs_read_file_result","command_id":"cmd_1","content":"hello world"}`
	parts := [][]byte{transmute([]byte)original[0:20], transmute([]byte)original[20:50], transmute([]byte)original[50:]}
	total := len(original)

	for p, i in parts {
		frame := make_chunk_frame("chunk_A", i, len(parts), total, p)
		defer delete(frame)
		assembled, complete, ok := bridge_ws_reassemble_chunk(&reassemblies, frame)
		testing.expect(t, ok)
		if i < len(parts) - 1 {
			testing.expect(t, !complete) // still buffering
		} else {
			testing.expect(t, complete)
			testing.expect_value(t, assembled, original)
			delete(assembled)
		}
	}
	// Completed stream is freed — nothing left buffered.
	testing.expect_value(t, len(reassemblies), 0)
}

@(test)
test_reassemble_out_of_order :: proc(t: ^testing.T) {
	reassemblies := make([dynamic]Bridge_Chunk_Reassembly)
	defer bridge_chunk_reassemblies_free(&reassemblies)
	original := "0123456789abcdefghij"
	total := len(original)
	// Deliver chunks 2, 0, 1 — reassembly must order by chunk_index, not arrival.
	order := []int{2, 0, 1}
	slices := [][]byte{transmute([]byte)original[0:7], transmute([]byte)original[7:14], transmute([]byte)original[14:]}
	got_complete := false
	for idx in order {
		frame := make_chunk_frame("chunk_B", idx, 3, total, slices[idx])
		defer delete(frame)
		assembled, complete, ok := bridge_ws_reassemble_chunk(&reassemblies, frame)
		testing.expect(t, ok)
		if complete {
			got_complete = true
			testing.expect_value(t, assembled, original)
			delete(assembled)
		}
	}
	testing.expect(t, got_complete)
	testing.expect_value(t, len(reassemblies), 0)
}

@(test)
test_reassemble_ignores_duplicate :: proc(t: ^testing.T) {
	reassemblies := make([dynamic]Bridge_Chunk_Reassembly)
	defer bridge_chunk_reassemblies_free(&reassemblies)
	original := "duplicate-guard-check"
	total := len(original)
	a := transmute([]byte)original[0:10]
	b := transmute([]byte)original[10:]

	f0 := make_chunk_frame("chunk_C", 0, 2, total, a); defer delete(f0)
	// Send chunk 0 TWICE (a retransmit): the second fill must be ignored, not
	// double-counted, or received_bytes would overshoot and the stream would never
	// complete.
	_, _, ok0 := bridge_ws_reassemble_chunk(&reassemblies, f0)
	testing.expect(t, ok0)
	_, dup_complete, dup_ok := bridge_ws_reassemble_chunk(&reassemblies, f0)
	testing.expect(t, dup_ok)
	testing.expect(t, !dup_complete)

	f1 := make_chunk_frame("chunk_C", 1, 2, total, b); defer delete(f1)
	assembled, complete, ok1 := bridge_ws_reassemble_chunk(&reassemblies, f1)
	testing.expect(t, ok1)
	testing.expect(t, complete)
	testing.expect_value(t, assembled, original)
	delete(assembled)
	testing.expect_value(t, len(reassemblies), 0)
}

@(test)
test_reassemble_heartbeat_interleaved :: proc(t: ^testing.T) {
	// MUTATION: a heartbeat arriving BETWEEN chunks must not disturb an in-flight
	// reassembly. In bridge_ws_runtime_loop a heartbeat has a non-empty "type", so
	// it is dispatched straight through and never reaches the reassembler; the
	// buffered chunk state persists across it. We reproduce that here: buffer
	// chunk 0, assert the heartbeat is classified as a pass-through (not a chunk),
	// then finish with chunk 1 and confirm the stream still reassembles intact.
	reassemblies := make([dynamic]Bridge_Chunk_Reassembly)
	defer bridge_chunk_reassemblies_free(&reassemblies)
	original := "interleaved-heartbeat-stream"
	total := len(original)

	f0 := make_chunk_frame("chunk_D", 0, 2, total, transmute([]byte)original[0:12]); defer delete(f0)
	_, complete0, ok0 := bridge_ws_reassemble_chunk(&reassemblies, f0)
	testing.expect(t, ok0)
	testing.expect(t, !complete0)
	testing.expect_value(t, len(reassemblies), 1) // one stream buffered

	// The loop's chunk-detection guard: a heartbeat is NOT a chunk (it has a type).
	heartbeat := `{"type":"bridge_heartbeat","active_instance_ids":[]}`
	hb_type := json_string(heartbeat, "type"); defer delete(hb_type)
	hb_kind := json_string(heartbeat, "kind"); defer delete(hb_kind)
	is_chunk := hb_type == "" && hb_kind == contracts.BRIDGE_WS_FRAME_KIND_CHUNK
	testing.expect(t, !is_chunk)
	testing.expect_value(t, len(reassemblies), 1) // untouched by the heartbeat

	f1 := make_chunk_frame("chunk_D", 1, 2, total, transmute([]byte)original[12:]); defer delete(f1)
	assembled, complete1, ok1 := bridge_ws_reassemble_chunk(&reassemblies, f1)
	testing.expect(t, ok1)
	testing.expect(t, complete1)
	testing.expect_value(t, assembled, original)
	delete(assembled)
	testing.expect_value(t, len(reassemblies), 0)
}

@(test)
test_reassemble_rejects_over_cap :: proc(t: ^testing.T) {
	reassemblies := make([dynamic]Bridge_Chunk_Reassembly)
	defer bridge_chunk_reassemblies_free(&reassemblies)
	frag := transmute([]byte)string("x")

	// total_bytes over the reassembly byte cap: rejected before any allocation.
	over_bytes := make_chunk_frame("cap_bytes", 0, 1, contracts.BRIDGE_WS_MAX_REASSEMBLY_BYTES + 1, frag)
	defer delete(over_bytes)
	_, _, ok_bytes := bridge_ws_reassemble_chunk(&reassemblies, over_bytes)
	testing.expect(t, !ok_bytes)

	// chunk_count over the chunk-count cap: rejected.
	over_count := make_chunk_frame("cap_count", 0, contracts.BRIDGE_WS_MAX_CHUNK_COUNT + 1, contracts.BRIDGE_WS_MAX_CHUNK_COUNT + 2, frag)
	defer delete(over_count)
	_, _, ok_count := bridge_ws_reassemble_chunk(&reassemblies, over_count)
	testing.expect(t, !ok_count)

	// No leak / no partial state from rejected frames.
	testing.expect_value(t, len(reassemblies), 0)
}

@(test)
test_reassemble_rejects_too_many_streams :: proc(t: ^testing.T) {
	reassemblies := make([dynamic]Bridge_Chunk_Reassembly)
	defer bridge_chunk_reassemblies_free(&reassemblies)
	// Open MAX_REASSEMBLIES distinct 2-chunk streams (each 1 chunk in flight).
	for i in 0 ..< contracts.BRIDGE_WS_MAX_REASSEMBLIES {
		id := fmt.aprintf("stream_%d", i)
		defer delete(id)
		frame := make_chunk_frame(id, 0, 2, 8, transmute([]byte)string("abcd"))
		defer delete(frame)
		_, _, ok := bridge_ws_reassemble_chunk(&reassemblies, frame)
		testing.expect(t, ok)
	}
	testing.expect_value(t, len(reassemblies), contracts.BRIDGE_WS_MAX_REASSEMBLIES)

	// Refusal now terminates the transport and triggers recovery; it cannot
	// leave a live connection silently losing chunks or evict another stream.
	extra := make_chunk_frame("stream_overflow", 0, 2, 8, transmute([]byte)string("abcd"))
	defer delete(extra)
	_, _, ok_extra := bridge_ws_reassemble_chunk(&reassemblies, extra)
	testing.expect(t, !ok_extra, "full reassembly queues refuse the new record explicitly")
	testing.expect_value(t, len(reassemblies), contracts.BRIDGE_WS_MAX_REASSEMBLIES)

	// The newcomer is present and the oldest is the one that went.
	found_new := false
	found_oldest := false
	for r in reassemblies {
		if r.chunk_id == "stream_overflow" do found_new = true
		if r.chunk_id == "stream_0" do found_oldest = true
	}
	testing.expect(t, !found_new, "refused stream must not allocate buffers")
	testing.expect(t, found_oldest, "existing streams must not be silently evicted")
}

@(test)
test_reassemble_rejects_malformed :: proc(t: ^testing.T) {
	reassemblies := make([dynamic]Bridge_Chunk_Reassembly)
	defer bridge_chunk_reassemblies_free(&reassemblies)

	// Empty payload_fragment.
	empty := `{"version":1,"kind":"chunk","stream_id":"m","chunk_id":"m","chunk_index":0,"chunk_count":1,"total_bytes":4,"payload_fragment":"","end_stream":true}`
	_, _, ok_empty := bridge_ws_reassemble_chunk(&reassemblies, empty)
	testing.expect(t, !ok_empty)

	// chunk_index >= chunk_count.
	bad_index := make_chunk_frame("m2", 3, 2, 8, transmute([]byte)string("abcd"))
	defer delete(bad_index)
	_, _, ok_index := bridge_ws_reassemble_chunk(&reassemblies, bad_index)
	testing.expect(t, !ok_index)

	testing.expect_value(t, len(reassemblies), 0)
}

@(test)
test_chunk_detection_ignores_content_embedding_kind :: proc(t: ^testing.T) {
	// ROBUSTNESS: a normal result frame whose file CONTENT embeds "kind":"chunk"
	// must NOT be misrouted to the reassembler. The loop's guard requires an EMPTY
	// top-level "type" — a real frame always has one, so it is never a false chunk.
	frame := `{"type":"fs_read_file_result","command_id":"c","content":"a line with \"kind\":\"chunk\" inside it"}`
	ftype := json_string(frame, "type"); defer delete(ftype)
	fkind := json_string(frame, "kind"); defer delete(fkind)
	is_chunk := ftype == "" && fkind == contracts.BRIDGE_WS_FRAME_KIND_CHUNK
	testing.expect(t, !is_chunk)
	// The real type is still recovered for normal dispatch.
	testing.expect_value(t, ftype, "fs_read_file_result")
}

// --- Consolidated from bridge_ws_reassembly_ttl_req32_test.odin ---

@(private = "file")
ttl_chunk_frame :: proc(chunk_id: string, index, count, total: int, raw: []byte) -> string {
	fragment := base64.encode(raw)
	defer delete(fragment)
	end := "true" if index + 1 == count else "false"
	return fmt.aprintf(
		`{{"version":1,"kind":"chunk","frame_id":"f","stream_id":"%s","src_daemon_id":"d","dest_daemon_id":"","original_kind":"frame","idempotency_key":"","chunk_id":"%s","chunk_index":%d,"chunk_count":%d,"total_bytes":%d,"payload_fragment":"%s","end_stream":%s}}`,
		chunk_id, chunk_id, index, count, total, fragment, end,
	)
}

// Fill the array with `n` streams that declare 2 chunks and send only chunk 0, so each
// one is admitted and then never completes — exactly what a lost chunk leaves behind.
@(private = "file")
ttl_abandon_streams :: proc(reassemblies: ^[dynamic]Bridge_Chunk_Reassembly, n: int) {
	for i in 0 ..< n {
		id := fmt.aprintf("abandoned_%d", i)
		defer delete(id)
		frame := ttl_chunk_frame(id, 0, 2, 8, transmute([]byte)string("AAAA"))
		defer delete(frame)
		_, complete, ok := bridge_ws_reassemble_chunk(reassemblies, frame)
		if !ok || complete do break
	}
}

// A saturated connection is refused explicitly and reset by its owner. The
// fresh transport must accept a complete pane record without replaying old bytes.
@(test)
test_req32_gate_full_recovers_after_explicit_transport_reset :: proc(t: ^testing.T) {
 reassemblies := make([dynamic]Bridge_Chunk_Reassembly)
 defer bridge_chunk_reassemblies_free(&reassemblies)
 ttl_abandon_streams(&reassemblies, contracts.BRIDGE_WS_MAX_REASSEMBLIES)
 testing.expect_value(t, len(reassemblies), contracts.BRIDGE_WS_MAX_REASSEMBLIES)
 original := `{"type":"shell_pty_output","session_id":"s1","data_b64":"QUJD","is_encrypted":false}`
 frame := ttl_chunk_frame("fresh", 0, 1, len(original), transmute([]byte)original)
 defer delete(frame)
 _, _, refused := bridge_ws_reassemble_chunk(&reassemblies, frame)
 testing.expect(t, !refused, "saturation must trigger transport recovery")
 bridge_chunk_reassemblies_free(&reassemblies)
 reassemblies = make([dynamic]Bridge_Chunk_Reassembly)
 assembled, complete, ok := bridge_ws_reassemble_chunk(&reassemblies, frame)
 defer if complete do delete(assembled)
 testing.expect(t, ok && complete, "fresh connection must not inherit a saturated gate")
 testing.expect_value(t, assembled, original)
}

// AC4 SECONDARY: assert the ENTRY IS GONE once past its deadline, not merely that
// admission still works. Without this a future change could satisfy the test above by
// raising the cap from 64 to 65 and leave the leak and the countdown intact.
@(test)
test_req32_expired_reassembly_entry_is_actually_removed :: proc(t: ^testing.T) {
	reassemblies := make([dynamic]Bridge_Chunk_Reassembly)
	defer bridge_chunk_reassemblies_free(&reassemblies)

	ttl_abandon_streams(&reassemblies, 3)
	testing.expect_value(t, len(reassemblies), 3)

	// Sweeping at "now" must keep them: they are well inside the TTL.
	now_ns := time.to_unix_nanoseconds(time.now())
	testing.expect_value(t, bridge_chunk_reassembly_sweep(&reassemblies, now_ns), 0)
	testing.expect_value(t, len(reassemblies), 3)

	// Sweeping one nanosecond past the TTL must drop every one of them, and the array
	// must actually shrink — the entry is freed, not just skipped.
	expired_ns := now_ns + i64(BRIDGE_WS_REASSEMBLY_TTL) + 1
	testing.expect_value(t, bridge_chunk_reassembly_sweep(&reassemblies, expired_ns), 3)
	testing.expect_value(t, len(reassemblies), 0)
}

// A YOUNG stream that is still being filled must not be expired out from under itself.
// NAMED FOR WHAT IT ACTUALLY ASSERTS: it sweeps at time.now(), well inside the TTL, so
// it proves only that a sweep does not drop a stream that has not aged out. It does NOT
// establish "the TTL bounds abandonment, not throughput" — an earlier version of this
// comment claimed that, and the clock cannot deliver it, because started_at_ns is
// first-chunk and never refreshed (see BRIDGE_WS_REASSEMBLY_TTL). A stream arriving
// steadily for longer than the TTL is expired mid-flight; no test here covers that, and
// that is the known gap, not an oversight.
@(test)
test_req32_young_in_flight_stream_survives_a_sweep_and_still_completes :: proc(t: ^testing.T) {
	reassemblies := make([dynamic]Bridge_Chunk_Reassembly)
	defer bridge_chunk_reassemblies_free(&reassemblies)

	original := `{"type":"shell_pty_output","session_id":"s2","data_b64":"WVla"}`
	half := len(original) / 2
	first := ttl_chunk_frame("live", 0, 2, len(original), transmute([]byte)original[:half])
	defer delete(first)
	_, complete, ok := bridge_ws_reassemble_chunk(&reassemblies, first)
	testing.expect(t, ok && !complete, "first of two chunks buffers")

	testing.expect_value(t, bridge_chunk_reassembly_sweep(&reassemblies, time.to_unix_nanoseconds(time.now())), 0)

	second := ttl_chunk_frame("live", 1, 2, len(original), transmute([]byte)original[half:])
	defer delete(second)
	assembled, complete2, ok2 := bridge_ws_reassemble_chunk(&reassemblies, second)
	defer if complete2 do delete(assembled)
	testing.expect(t, ok2 && complete2, "second chunk completes the stream")
	testing.expect_value(t, assembled, original)
	testing.expect_value(t, len(reassemblies), 0)
}
