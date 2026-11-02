package events

// REQ-SHELL-35 — one oversized event must not unsubscribe a browser from every event.
//
// No browser and no HTTP stack: a loopback pair stands in for a /user WebSocket, because
// what has to be true is a property of the BUS STATE after a write and of the BYTES that
// reach the peer, neither of which needs a real client.
//
// The assertions are deliberately PAIRED: for every case that must not remove the slot,
// the test also proves the slot is still USABLE afterwards (a following event arrives).
// Checking connected[i] alone would pass just as well if the fix had left a dead socket in
// the table, and checking delivery alone would pass if removal had simply been disabled —
// which is what req35_a_dead_peer_is_still_removed exists to rule out.

import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import ws "odin_test:lib/ws"

@(test)
test_mcp_worker_hint_skips_busy_socket_without_sequence_gap :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	p:=make_pair(t);defer close_pair(&p)
	bus:User_Event_Bus
	i:=user_ws_add(&bus,"alice",p.hub)
	defer user_ws_remove(&bus,i)
	sync.mutex_lock(&bus.write_mutexes[i])
	started:=time.tick_now()
	publish_mcp_worker_hint(&bus,"alice")
	sync.mutex_unlock(&bus.write_mutexes[i])
	testing.expect(t,time.tick_since(started)<200*time.Millisecond && bus.stream_seqs[i]==0)
	publish_mcp_worker_hint(&bus,"alice")
	bytes:=drain(p.peer);defer delete(bytes)
	frames,ok:=split_text_frames(bytes);defer delete(frames)
	testing.expect(t,ok && len(frames)==1 && strings.contains(frames[0],"mcp_worker_available") && stream_seq_of(frames[0])==1)
}

@(private = "file")
Pair :: struct {
	listener: net.TCP_Socket,
	peer:     net.TCP_Socket,
	hub:      net.TCP_Socket,
}

@(private = "file")
PAIR_BUFFER_BYTES :: 8 * 1024 * 1024

@(private = "file")
make_pair :: proc(t: ^testing.T) -> Pair {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil do testing.fail_now(t, "could not listen on loopback")
	bound, bound_err := net.bound_endpoint(listener)
	if bound_err != nil {
		net.close(listener)
		testing.fail_now(t, "could not read the bound endpoint")
	}
	peer, dial_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if dial_err != nil {
		net.close(listener)
		testing.fail_now(t, "could not dial loopback")
	}
	hub, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil {
		net.close(listener)
		net.close(peer)
		testing.fail_now(t, "could not accept on loopback")
	}
	// A frame larger than the socket buffer would block the writer rather than
	// complete, so the buffers are enlarged to keep these tests about FRAMING.
	_ = net.set_option(hub, .Send_Buffer_Size, PAIR_BUFFER_BYTES)
	_ = net.set_option(peer, .Receive_Buffer_Size, PAIR_BUFFER_BYTES)
	_ = net.set_option(peer, .Receive_Timeout, 500 * time.Millisecond)
	return Pair{listener = listener, peer = peer, hub = hub}
}

@(private = "file")
close_pair :: proc(p: ^Pair) {
	net.close(p.hub)
	net.close(p.peer)
	net.close(p.listener)
}

// drain reads until the peer goes quiet. Caller owns the result.
@(private = "file")
drain :: proc(sock: net.TCP_Socket) -> []byte {
	out := make([dynamic]byte)
	buf: [65536]byte
	for {
		n, err := net.recv_tcp(sock, buf[:])
		if err != nil || n <= 0 do break
		append(&out, ..buf[:n])
	}
	return out[:]
}

// split_text_frames parses unmasked server->client text frames out of a byte stream,
// returning each frame's PAYLOAD. ok=false means the stream was malformed — which is a
// failure worth reporting in its own right, since a half-written frame is exactly the
// .Desynchronised condition. Payloads alias `raw`; the caller owns nothing.
@(private = "file")
split_text_frames :: proc(raw: []byte) -> (payloads: [dynamic]string, ok: bool) {
	payloads = make([dynamic]string)
	pos := 0
	for pos < len(raw) {
		if len(raw) - pos < 2 do return payloads, false
		if raw[pos] != 0x81 do return payloads, false
		n := int(raw[pos + 1] & 0x7f)
		header := 2
		if n == 126 {
			if len(raw) - pos < 4 do return payloads, false
			n = int(raw[pos + 2]) << 8 | int(raw[pos + 3])
			header = 4
		} else if n == 127 {
			if len(raw) - pos < 10 do return payloads, false
			n = 0
			for i in 0 ..< 8 do n = n << 8 | int(raw[pos + 2 + i])
			header = 10
		}
		if len(raw) - pos - header < n do return payloads, false
		append(&payloads, string(raw[pos + header:pos + header + n]))
		pos += header + n
	}
	return payloads, true
}

@(private = "file")
OWNER :: "usr_req35"

// stream_seq_of reads the stream_seq the bus stamped on a frame, or -1.
@(private = "file")
stream_seq_of :: proc(frame: string) -> int {
	key :: `"stream_seq":`
	at := strings.index(frame, key)
	if at < 0 do return -1
	n := 0
	digits := 0
	for c in transmute([]byte)frame[at + len(key):] {
		if c < '0' || c > '9' do break
		n = n * 10 + int(c - '0')
		digits += 1
	}
	if digits == 0 do return -1
	return n
}

// stream_epoch_of reads the stamped stream_epoch, or "".
@(private = "file")
stream_epoch_of :: proc(frame: string) -> string {
	key :: `"stream_epoch":"`
	at := strings.index(frame, key)
	if at < 0 do return ""
	rest := frame[at + len(key):]
	end := strings.index_byte(rest, '"')
	if end < 0 do return ""
	return rest[:end]
}

// unstamped returns the frame without the leading stream stamp, i.e. what the producer
// published. Allocated on the temp allocator.
@(private = "file")
unstamped :: proc(frame: string) -> string {
	if !strings.has_prefix(frame, `{"stream_epoch":"`) do return frame
	at := strings.index(frame, `"stream_seq":`)
	if at < 0 do return frame
	rest := frame[at + len(`"stream_seq":`):]
	i := 0
	for i < len(rest) && rest[i] >= '0' && rest[i] <= '9' do i += 1
	rest = rest[i:]
	if strings.has_prefix(rest, ",") do rest = rest[1:]
	return strings.concatenate({"{", rest}, context.temp_allocator)
}

// AC1 — THE DEFECT. An event the hub cannot encode at all must cost that one event and
// nothing else. Sized past WS_MAX_SERVER_PAYLOAD so it is refused by the writer even with
// the 64-bit arm available, which is now the only way to reach a refusal.
@(test)
req35_oversized_event_keeps_the_client_subscribed :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	bus: User_Event_Bus
	idx := user_ws_add(&bus, OWNER, pair.hub)
	testing.expect_value(t, idx, 0)

	huge := strings.repeat("h", ws.WS_MAX_SERVER_PAYLOAD + 1)
	defer delete(huge)
	publish_raw_to_user(&bus, OWNER, huge)

	// The slot survives, the table is untouched, and nothing was counted as a removal.
	testing.expect(t, bus.connected[idx], "an event the hub could not encode must NOT unsubscribe the client")
	testing.expect_value(t, bus.owner_user_ids[idx], OWNER)
	testing.expect_value(t, bus.client_count, 1)
	testing.expect_value(t, bus.sockets_removed, 0)
	// AC4 — the drop is counted, not silent.
	testing.expect_value(t, bus.oversized_events_dropped, 1)

	// REQ-3 — the client is TOLD: the dropped event's stream_seq goes to a resync_required.
	testing.expect_value(t, bus.resyncs_sent, 1)

	// Still SUBSCRIBED, not merely still marked connected: the next event arrives, after
	// only the resync hint — no fragment of the refused frame preceded either.
	publish_raw_to_user(&bus, OWNER, `{"type":"after"}`)
	raw := drain(pair.peer)
	defer delete(raw)
	frames, parse_ok := split_text_frames(raw)
	defer delete(frames)
	testing.expect(t, parse_ok, "the stream must be well-formed — a refusal must not put bytes on the wire")
	testing.expect_value(t, len(frames), 2)
	if len(frames) == 2 {
		testing.expect_value(t, stream_seq_of(frames[0]), 1)
		testing.expect_value(t, unstamped(frames[0]), `{"type":"resync_required","reason":"event_too_large"}`)
		testing.expect_value(t, stream_seq_of(frames[1]), 2)
		testing.expect_value(t, unstamped(frames[1]), `{"type":"after"}`)
	}
}

// AC2 — DELIVERY, not survival. 80 KB is the size the old writer returned false for (and
// therefore unsubscribed on); with the 64-bit arm it is simply sent. Read back off the wire
// as ONE well-formed 127-length frame, because "the call returned Ok" is not the claim.
@(test)
req35_event_over_65535_is_actually_delivered :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	bus: User_Event_Bus
	idx := user_ws_add(&bus, OWNER, pair.hub)
	testing.expect_value(t, idx, 0)

	// A realistic shape rather than 80 KB of filler: the field that is actually unbounded
	// on this bus is a summary string riding a resource_changed event.
	long_name := strings.repeat("n", 80_000)
	defer delete(long_name)
	summary := strings.concatenate({`{"display_name":"`, long_name, `"}`})
	defer delete(summary)
	publish_resource_changed(&bus, OWNER, "agent_instance", "ain_req35", "status_changed", summary)

	testing.expect(t, bus.connected[idx], "a large but encodable event must not unsubscribe the client")
	testing.expect_value(t, bus.oversized_events_dropped, 0)
	testing.expect_value(t, bus.sockets_removed, 0)

	raw := drain(pair.peer)
	defer delete(raw)
	testing.expect(t, len(raw) > ws.WS_16BIT_MAX_PAYLOAD, "the whole payload must have reached the peer")
	// The 127 arm, spelled out: the old writer had no 8-byte length case at all.
	testing.expect_value(t, raw[0], 0x81)
	testing.expect_value(t, raw[1] & 0x7f, 127)
	frames, parse_ok := split_text_frames(raw)
	defer delete(frames)
	testing.expect(t, parse_ok, "the frame must be well-formed")
	testing.expect_value(t, len(frames), 1)
	testing.expect(t, strings.contains(frames[0], long_name), "the payload must arrive intact, not truncated")
}

// The other half of AC1, and the reason it is a TYPE and not a relaxed bool: a peer that is
// genuinely gone must STILL be removed. Without this, "stop unsubscribing on write failure"
// would pass as a fix while leaking every dead slot in a fixed 128-entry table.
@(test)
req35_a_dead_peer_is_still_removed :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	bus: User_Event_Bus
	idx := user_ws_add(&bus, OWNER, pair.hub)
	testing.expect_value(t, idx, 0)

	// SHUT_WR on the hub end, NOT net.close. Two reasons, both learned the hard way:
	//
	//  1. DETERMINISM. Closing only the remote end is not enough on loopback — the first
	//     send after a peer close usually succeeds and only the second sees EPIPE, which
	//     would make this test depend on TCP timing rather than on the removal rule.
	//     A shutdown for sending fails the very next send_tcp, every time.
	//  2. IT DOES NOT RELEASE THE DESCRIPTOR. Closing the hub socket and then writing to
	//     it writes to a FREED fd number, and the test runner runs packages on 4 threads:
	//     another test's freshly-accepted socket takes that number and receives this
	//     event. That is not hypothetical — it is what this test did before, and it made
	//     two unrelated tests in this file fail with each other's payloads.
	net.shutdown(net.Any_Socket(pair.hub), .Send)

	publish_raw_to_user(&bus, OWNER, `{"type":"to_a_dead_peer"}`)

	testing.expect(t, !bus.connected[idx], "a peer that is gone MUST be removed")
	testing.expect_value(t, bus.owner_user_ids[idx], "")
	testing.expect_value(t, bus.sockets_removed, 1)
	// A dead peer is not an encoding refusal and must not be counted as one.
	testing.expect_value(t, bus.oversized_events_dropped, 0)
	// Nor is it a desynchronised stream. A closed tab is the ORDINARY removal and must not
	// land in the counter that exists to make a half-written frame findable — if it did,
	// the alarming case would be permanently hidden inside everyday traffic.
	testing.expect_value(t, bus.desynchronised_removals, 0)
}

// Fan-out is per-connection: one client's refused event must not disturb another's. The
// old code removed on the same bool for every socket in the loop, so a single oversized
// event unsubscribed EVERY connection the user had.
@(test)
req35_one_refused_event_does_not_disturb_the_users_other_connections :: proc(t: ^testing.T) {
	a := make_pair(t)
	defer close_pair(&a)
	b := make_pair(t)
	defer close_pair(&b)
	bus: User_Event_Bus
	testing.expect_value(t, user_ws_add(&bus, OWNER, a.hub), 0)
	testing.expect_value(t, user_ws_add(&bus, OWNER, b.hub), 1)

	huge := strings.repeat("h", ws.WS_MAX_SERVER_PAYLOAD + 1)
	defer delete(huge)
	publish_raw_to_user(&bus, OWNER, huge)

	testing.expect(t, bus.connected[0], "connection 0 must stay subscribed")
	testing.expect(t, bus.connected[1], "connection 1 must stay subscribed")
	testing.expect_value(t, bus.client_count, 2)
	testing.expect_value(t, bus.sockets_removed, 0)
	// Counted once per CONNECTION the event could not reach, which is what an operator
	// reading the warn line sees.
	testing.expect_value(t, bus.oversized_events_dropped, 2)
	testing.expect_value(t, bus.resyncs_sent, 2)

	publish_raw_to_user(&bus, OWNER, `{"type":"both"}`)
	for sock in ([]net.TCP_Socket{a.peer, b.peer}) {
		raw := drain(sock)
		defer delete(raw)
		frames, parse_ok := split_text_frames(raw)
		defer delete(frames)
		testing.expect(t, parse_ok, "each stream must be well-formed")
		testing.expect_value(t, len(frames), 2)
		if len(frames) == 2 do testing.expect_value(t, unstamped(frames[1]), `{"type":"both"}`)
	}
}

// AC3 — nothing bespoke is left. The control-frame wrapper and the fan-out path must agree
// on the arm, or the handshake and the events would disagree about what a browser can be
// sent. Asserted through the wrapper the /user upgrade actually calls.
@(test)
req35_the_control_frame_wrapper_uses_the_browser_arm :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	big := strings.repeat("r", ws.WS_16BIT_MAX_PAYLOAD + 1)
	defer delete(big)
	testing.expect(t, write_ws_text_frame(pair.hub, big), "the user socket is a browser: the 64-bit arm applies here too")

	raw := drain(pair.peer)
	defer delete(raw)
	frames, parse_ok := split_text_frames(raw)
	defer delete(frames)
	testing.expect(t, parse_ok, "the frame must be well-formed")
	testing.expect_value(t, len(frames), 1)
	testing.expect_value(t, len(frames[0]), ws.WS_16BIT_MAX_PAYLOAD + 1)
}

// The decision table itself, all four arms, exhaustively. REQ-SHELL-35.
//
// This exists because the counter tests above can only prove the arms they can REACH. An
// oversized frame and a shut-down socket are easy to stage; a genuine .Desynchronised — the
// hub getting a partial write onto the wire — needs a socket buffer filled to the byte and
// would be a flaky test if written that way. So the reachable arms are asserted end-to-end
// through publish_raw_to_user above, and the decision is ALSO pinned here directly, where
// .Desynchronised costs nothing to express.
//
// Asserting it as a table rather than case-by-case is deliberate: the defect this task
// fixed was a two-valued answer to a four-valued question, and a table is the shape that
// makes a future fifth arm a visible omission instead of a silent fallthrough.
@(test)
req35_the_removal_decision_covers_every_result_arm :: proc(t: ^testing.T) {
	// "Can the hub not encode this?" -> keep the client. "Is the peer finished?" -> drop it.
	testing.expect(t, !_publish_write_removes_socket(.Ok), "a successful write must never remove the socket")
	testing.expect(t, !_publish_write_removes_socket(.Too_Large), "an unencodable frame says NOTHING about the peer — this is the defect")
	testing.expect(t, _publish_write_removes_socket(.Peer_Gone), "a peer that is gone must be removed")
	testing.expect(t, _publish_write_removes_socket(.Desynchronised), "half a frame on the wire must end the connection, not be retried on it")
}

// ---------------------------------------------------------------------------------------
// REQ-3 — per-connection delivery stream, slot exhaustion, concurrent publishers.
// ---------------------------------------------------------------------------------------

@(private = "file")
OTHER_OWNER :: "usr_req3_other"

// Ready carries the epoch and the watermark, and every connection gets its own epoch, so a
// reconnect can never be mistaken for continuity.
@(test)
req3_attach_sends_ready_with_epoch_and_watermark :: proc(t: ^testing.T) {
	a := make_pair(t)
	defer close_pair(&a)
	b := make_pair(t)
	defer close_pair(&b)
	bus: User_Event_Bus
	ha, ra := user_ws_attach(&bus, OWNER, a.hub)
	hb, rb := user_ws_attach(&bus, OWNER, b.hub)
	testing.expect_value(t, ra, User_WS_Attach_Result.Attached)
	testing.expect_value(t, rb, User_WS_Attach_Result.Attached)
	publish_raw_to_user(&bus, OWNER, `{"type":"x"}`)
	user_ws_detach(&bus, ha)
	user_ws_detach(&bus, hb)

	epochs: [2]string
	for sock, k in ([]net.TCP_Socket{a.peer, b.peer}) {
		raw := drain(sock)
		defer delete(raw)
		frames, ok := split_text_frames(raw)
		defer delete(frames)
		testing.expect(t, ok, "well-formed stream")
		testing.expect_value(t, len(frames), 2)
		if len(frames) != 2 do continue
		testing.expect(t, strings.contains(frames[0], `"type":"user_ws_ready"`), "ready comes first")
		testing.expect(t, strings.contains(frames[0], `"protocol_version":2`), "ready announces protocol 2")
		testing.expect_value(t, stream_seq_of(frames[0]), 0)
		testing.expect_value(t, stream_seq_of(frames[1]), 1)
		testing.expect_value(t, stream_epoch_of(frames[1]), stream_epoch_of(frames[0]))
		epochs[k] = strings.clone(stream_epoch_of(frames[0]), context.temp_allocator)
	}
	testing.expect(t, epochs[0] != "" && epochs[0] != epochs[1], "each connection has its own epoch")
	testing.expect(t, !bus.connected[ha.idx] && !bus.connected[hb.idx], "detach releases both slots")
}

// The global event_seq advances for EVERY owner; the per-connection stream must not, or
// another user's traffic would look like a gap.
@(test)
req3_other_owners_events_do_not_advance_the_stream :: proc(t: ^testing.T) {
	mine := make_pair(t)
	defer close_pair(&mine)
	theirs := make_pair(t)
	defer close_pair(&theirs)
	bus: User_Event_Bus
	user_ws_add(&bus, OWNER, mine.hub)
	user_ws_add(&bus, OTHER_OWNER, theirs.hub)

	publish_resource_changed(&bus, OTHER_OWNER, "task", "t1", "updated", "")
	publish_resource_changed(&bus, OWNER, "task", "t2", "updated", "")
	publish_resource_changed(&bus, OTHER_OWNER, "task", "t3", "updated", "")
	publish_resource_changed(&bus, OTHER_OWNER, "task", "t4", "updated", "")
	publish_raw_to_user(&bus, OWNER, `{"type":"attention_changed"}`)
	testing.expect_value(t, bus.event_seq, 4)

	raw := drain(mine.peer)
	defer delete(raw)
	frames, ok := split_text_frames(raw)
	defer delete(frames)
	testing.expect(t, ok, "well-formed stream")
	testing.expect_value(t, len(frames), 2)
	if len(frames) == 2 {
		testing.expect_value(t, stream_seq_of(frames[0]), 1)
		testing.expect_value(t, stream_seq_of(frames[1]), 2)
		testing.expect(t, strings.contains(frames[0], `"resource_id":"t2"`), "only my event")
		testing.expect(t, strings.contains(frames[1], `"type":"attention_changed"`), "every event type is stamped")
	}
	other_raw := drain(theirs.peer)
	defer delete(other_raw)
	other_frames, _ := split_text_frames(other_raw)
	defer delete(other_frames)
	testing.expect_value(t, len(other_frames), 3)
	if len(other_frames) == 3 do testing.expect_value(t, stream_seq_of(other_frames[2]), 3)
}

@(private = "file")
Publisher_Job :: struct {
	bus:   ^User_Event_Bus,
	owner: string,
	count: int,
}

@(private = "file")
REQ3_PUBLISHERS :: 8
@(private = "file")
REQ3_PER_PUBLISHER :: 60

// Concurrent publishers on several threads: each connection must receive every event
// exactly once, as well-formed frames, with stream_seq 1..N in wire order — the
// write_mutex makes seq assignment and the write one step.
@(test)
req3_concurrent_publishers_keep_each_stream_contiguous :: proc(t: ^testing.T) {
	a := make_pair(t)
	defer close_pair(&a)
	b := make_pair(t)
	defer close_pair(&b)
	other := make_pair(t)
	defer close_pair(&other)
	bus: User_Event_Bus
	user_ws_add(&bus, OWNER, a.hub)
	user_ws_add(&bus, OWNER, b.hub)
	user_ws_add(&bus, OTHER_OWNER, other.hub)

	jobs: [REQ3_PUBLISHERS]Publisher_Job
	threads: [REQ3_PUBLISHERS]^thread.Thread
	for k in 0..<REQ3_PUBLISHERS {
		owner := OWNER
		if k % 4 == 3 do owner = OTHER_OWNER
		jobs[k] = Publisher_Job{bus = &bus, owner = owner, count = REQ3_PER_PUBLISHER}
		threads[k] = thread.create_and_start_with_data(&jobs[k], proc(data: rawptr) {
			job := (^Publisher_Job)(data)
			for _ in 0..<job.count do publish_resource_changed(job.bus, job.owner, "task", "t", "updated", `{"pad":"0123456789"}`)
		})
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	mine_expected := REQ3_PER_PUBLISHER * (REQ3_PUBLISHERS - REQ3_PUBLISHERS / 4)
	testing.expect_value(t, bus.event_seq, REQ3_PUBLISHERS * REQ3_PER_PUBLISHER)

	for sock in ([]net.TCP_Socket{a.peer, b.peer}) {
		raw := drain(sock)
		defer delete(raw)
		frames, ok := split_text_frames(raw)
		defer delete(frames)
		testing.expect(t, ok, "concurrent writers must never interleave bytes inside a frame")
		testing.expect_value(t, len(frames), mine_expected)
		in_order := true
		for f, k in frames do if stream_seq_of(f) != k + 1 do in_order = false
		testing.expect(t, in_order, "stream_seq must be contiguous in wire order")
	}
	other_raw := drain(other.peer)
	defer delete(other_raw)
	other_frames, _ := split_text_frames(other_raw)
	defer delete(other_frames)
	testing.expect_value(t, len(other_frames), REQ3_PER_PUBLISHER * (REQ3_PUBLISHERS / 4))
	testing.expect_value(t, bus.sockets_removed, 0)
}

// Slot exhaustion: the 129th socket is refused (no ready), the refusal is counted, and the
// 1013 close frame is what reaches the peer — never a ready-deaf subscription.
@(test)
req3_slot_exhaustion_refuses_with_1013_not_ready :: proc(t: ^testing.T) {
	bus: User_Event_Bus
	for k in 0..<USER_WS_MAX_SLOTS {
		testing.expect_value(t, user_ws_add(&bus, OWNER, net.TCP_Socket(0)), k)
	}
	pair := make_pair(t)
	defer close_pair(&pair)
	handle, result := user_ws_attach(&bus, OWNER, pair.hub)
	testing.expect_value(t, result, User_WS_Attach_Result.Slots_Full)
	testing.expect_value(t, handle.idx, -1)
	testing.expect_value(t, bus.slot_exhaustions, 1)
	testing.expect(t, user_ws_refuse_full(pair.hub), "the close frame is written")

	raw := drain(pair.peer)
	defer delete(raw)
	testing.expect(t, len(raw) >= 4, "a close frame reached the peer")
	if len(raw) >= 4 {
		testing.expect_value(t, raw[0], 0x88)
		code := int(raw[2]) << 8 | int(raw[3])
		testing.expect_value(t, code, USER_WS_CLOSE_TRY_AGAIN_LATER)
	}
	testing.expect(t, !strings.contains(string(raw), "user_ws_ready"), "no ready for a refused socket")

	// A freed slot is usable again.
	user_ws_remove(&bus, 5)
	h2, r2 := user_ws_attach(&bus, OWNER, pair.hub)
	testing.expect_value(t, r2, User_WS_Attach_Result.Attached)
	testing.expect_value(t, h2.idx, 5)
	user_ws_detach(&bus, h2)
}

// A reader that exits late holds a STALE handle; detaching it must not release the new
// connection that reused the slot.
@(test)
req3_stale_handle_detach_leaves_a_reused_slot_alone :: proc(t: ^testing.T) {
	a := make_pair(t)
	defer close_pair(&a)
	b := make_pair(t)
	defer close_pair(&b)
	bus: User_Event_Bus
	old, _ := user_ws_attach(&bus, OWNER, a.hub)
	user_ws_detach(&bus, old)
	fresh, r := user_ws_attach(&bus, OWNER, b.hub)
	testing.expect_value(t, r, User_WS_Attach_Result.Attached)
	testing.expect_value(t, fresh.idx, old.idx)
	user_ws_detach(&bus, old)
	testing.expect(t, bus.connected[fresh.idx], "a stale detach must not release the reused slot")
	user_ws_detach(&bus, fresh)
	testing.expect(t, !bus.connected[fresh.idx], "the live handle releases it")
}

// Stamping covers every JSON object shape, and anything that cannot carry the stamp is
// replaced by resync_required rather than sent unsequenced.
@(test)
req3_stamping_and_unstampable_payloads :: proc(t: ^testing.T) {
	f1, ok1 := stamp_stream_event("e-1", 7, `{}`)
	testing.expect(t, ok1, "empty object is stampable")
	testing.expect_value(t, f1, `{"stream_epoch":"e-1","stream_seq":7}`)
	delete(f1)
	f2, ok2 := stamp_stream_event("e-1", 8, ` { "type":"x"}`)
	testing.expect(t, ok2, "leading whitespace is fine")
	testing.expect_value(t, f2, `{"stream_epoch":"e-1","stream_seq":8,"type":"x"}`)
	delete(f2)
	_, ok3 := stamp_stream_event("e-1", 9, `[1,2]`)
	testing.expect(t, !ok3, "a non-object cannot carry the stamp")

	pair := make_pair(t)
	defer close_pair(&pair)
	bus: User_Event_Bus
	user_ws_add(&bus, OWNER, pair.hub)
	publish_raw_to_user(&bus, OWNER, `not json`)
	raw := drain(pair.peer)
	defer delete(raw)
	frames, _ := split_text_frames(raw)
	defer delete(frames)
	testing.expect_value(t, len(frames), 1)
	if len(frames) == 1 {
		testing.expect_value(t, stream_seq_of(frames[0]), 1)
		testing.expect(t, strings.contains(frames[0], `"type":"resync_required"`), "the client is told to resync")
	}
	testing.expect(t, bus.connected[0], "the client stays subscribed")
}

// A stale handle must never release the slot's NEXT registration: detach after the slot
// was released and re-granted is a no-op, and the new connection keeps receiving.
@(test)
req3_stale_handle_detach_does_not_release_reused_slot :: proc(t: ^testing.T) {
	first := make_pair(t)
	defer close_pair(&first)
	second := make_pair(t)
	defer close_pair(&second)
	bus: User_Event_Bus
	old, r1 := user_ws_attach(&bus, OWNER, first.hub)
	testing.expect_value(t, r1, User_WS_Attach_Result.Attached)
	user_ws_detach(&bus, old)
	fresh, r2 := user_ws_attach(&bus, OWNER, second.hub)
	testing.expect_value(t, r2, User_WS_Attach_Result.Attached)
	testing.expect_value(t, fresh.idx, old.idx)
	testing.expect(t, fresh.generation != old.generation, "a re-granted slot gets a new generation")

	user_ws_detach(&bus, old)
	testing.expect(t, bus.connected[fresh.idx], "stale detach left the new registration alone")
	publish_resource_changed(&bus, OWNER, "task", "t1", "updated", "{}")

	raw := drain(second.peer)
	defer delete(raw)
	frames, ok := split_text_frames(raw)
	defer delete(frames)
	testing.expect(t, ok, "well-formed frames")
	testing.expect_value(t, len(frames), 2)
	if len(frames) == 2 {
		testing.expect(t, strings.contains(frames[0], `"type":"user_ws_ready"`), "ready first")
		testing.expect_value(t, stream_seq_of(frames[1]), 1)
	}
	old_raw := drain(first.peer)
	defer delete(old_raw)
	old_frames, _ := split_text_frames(old_raw)
	defer delete(old_frames)
	testing.expect_value(t, len(old_frames), 1) // only its own ready
}

@(private = "file")
Churn_Publisher :: struct {
	bus:  ^User_Event_Bus,
	stop: bool,
	sent: int,
}

@(private = "file")
REQ3_CHURN_CYCLES :: 12

// attach/detach racing a publisher: every connection sees ready first, then a stream_seq
// that is contiguous from 1 with no frame split or interleaved, and nothing arrives on a
// socket after user_ws_detach has returned (detach waits out an in-flight write).
@(test)
req3_attach_detach_racing_publish_keeps_streams_clean :: proc(t: ^testing.T) {
	bus: User_Event_Bus
	job := Churn_Publisher{bus = &bus}
	th := thread.create_and_start_with_data(&job, proc(data: rawptr) {
		job := (^Churn_Publisher)(data)
		for !sync.atomic_load(&job.stop) {
			publish_resource_changed(job.bus, OWNER, "task", "t", "updated", `{"pad":"0123456789"}`)
			job.sent += 1
		}
	})

	pairs: [REQ3_CHURN_CYCLES]Pair
	before_detach: [REQ3_CHURN_CYCLES][]byte
	for k in 0..<REQ3_CHURN_CYCLES {
		pairs[k] = make_pair(t)
		handle, result := user_ws_attach(&bus, OWNER, pairs[k].hub)
		testing.expect_value(t, result, User_WS_Attach_Result.Attached)
		time.sleep(2 * time.Millisecond)
		user_ws_detach(&bus, handle)
		before_detach[k] = drain(pairs[k].peer)
	}
	sync.atomic_store(&job.stop, true)
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, job.sent > 0, "the publisher ran")

	for k in 0..<REQ3_CHURN_CYCLES {
		frames, ok := split_text_frames(before_detach[k])
		testing.expect(t, ok, "no torn or interleaved frame across attach/detach")
		testing.expect(t, len(frames) >= 1 && strings.contains(frames[0], `"type":"user_ws_ready"`), "ready is the first frame")
		in_order := true
		for f, n in frames[1:] do if stream_seq_of(f) != n + 1 do in_order = false
		testing.expect(t, in_order, "stream_seq contiguous from 1 on every connection")
		delete(frames)
		after := drain(pairs[k].peer)
		testing.expect_value(t, len(after), 0) // nothing written after detach returned
		delete(after)
		delete(before_detach[k])
		close_pair(&pairs[k])
	}
	testing.expect_value(t, bus.sockets_removed, 0)
}
