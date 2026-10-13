package shell_session

import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import ws "odin_test:lib/ws"

@(private = "file")
first_frame_test_mu: sync.Mutex

@(private = "file")
reset_first_frame :: proc() {
	sync.guard(& shell_first_frame_tracker.mu)
	shell_first_frame_tracker.slots = {}
	shell_first_frame_tracker.next = 0
}

@(test)
test_shell_viewer_detach_reasons_are_distinct :: proc(t: ^testing.T) {
	reasons := []Shell_Viewer_Detach_Reason{.Unspecified, .Stream_Closed, .Peer_Gone, .Desynchronised}
	seen := make([dynamic]string)
	defer delete(seen)
	for r in reasons {
		str := shell_viewer_detach_reason_string(r)
		testing.expect(t, len(str) > 0)
		for prior in seen do testing.expect(t, prior != str, "two detach reasons render identically")
		append(&seen, str)
	}
}

@(test)
test_shell_detach_reason_tracks_write_result :: proc(t: ^testing.T) {
	testing.expect_value(t, _detach_reason_for_write(.Peer_Gone), Shell_Viewer_Detach_Reason.Peer_Gone)
	testing.expect_value(t, _detach_reason_for_write(.Desynchronised), Shell_Viewer_Detach_Reason.Desynchronised)
	testing.expect_value(t, _detach_reason_for_write(.Ok), Shell_Viewer_Detach_Reason.Unspecified)
	testing.expect_value(t, _detach_reason_for_write(.Too_Large), Shell_Viewer_Detach_Reason.Unspecified)
}

@(test)
test_shell_first_frame_fires_exactly_once_per_attach :: proc(t: ^testing.T) {
	sync.guard(&first_frame_test_mu)
	reset_first_frame()
	defer reset_first_frame()
	shell_first_frame_arm("sh_once")
	testing.expect(t, shell_first_frame_take("sh_once"), "the first frame must be reported")
	for i in 0 ..< 500 {
		testing.expect(t, !shell_first_frame_take("sh_once"), "only the FIRST frame may be reported")
	}
}

@(test)
test_shell_first_frame_is_silent_without_attach :: proc(t: ^testing.T) {
	sync.guard(&first_frame_test_mu)
	reset_first_frame()
	defer reset_first_frame()
	testing.expect(t, !shell_first_frame_take("sh_never_attached"))
}

@(test)
test_shell_first_frame_rearms_on_reattach :: proc(t: ^testing.T) {
	sync.guard(&first_frame_test_mu)
	reset_first_frame()
	defer reset_first_frame()
	shell_first_frame_arm("sh_re")
	testing.expect(t, shell_first_frame_take("sh_re"))
	testing.expect(t, !shell_first_frame_take("sh_re"))
	shell_first_frame_arm("sh_re")
	testing.expect(t, shell_first_frame_take("sh_re"), "a re-attach must re-arm the first-frame log")
}

@(test)
test_shell_first_frame_is_per_session :: proc(t: ^testing.T) {
	sync.guard(&first_frame_test_mu)
	reset_first_frame()
	defer reset_first_frame()
	shell_first_frame_arm("sh_a")
	shell_first_frame_arm("sh_b")
	testing.expect(t, shell_first_frame_take("sh_a"))
	testing.expect(t, shell_first_frame_take("sh_b"), "sh_b's one-shot was consumed by sh_a")
}

@(test)
test_shell_first_frame_survives_more_sessions_than_slots :: proc(t: ^testing.T) {
	sync.guard(&first_frame_test_mu)
	reset_first_frame()
	defer reset_first_frame()
	ids := make([dynamic]string)
	defer { for s in ids do delete(s); delete(ids) }
	for i in 0 ..< SHELL_FIRST_FRAME_SLOTS * 2 {
		id := session_id_for_test(i)
		append(&ids, id)
		shell_first_frame_arm(id)
	}
	last := ids[len(ids) - 1]
	testing.expect(t, shell_first_frame_take(last), "the newest armed session must still fire")
	testing.expect(t, !shell_first_frame_take(last))
}

@(private = "file")
session_id_for_test :: proc(n: int) -> string {
	digits := "0123456789"
	buf: [24]byte
	copy(buf[:], "sh_")
	i := len(buf)
	v := n
	if v == 0 {
		i -= 1
		buf[i] = '0'
	}
	for v > 0 {
		i -= 1
		buf[i] = digits[v % 10]
		v /= 10
	}
	out := make([]byte, 3 + (len(buf) - i))
	copy(out[:3], "sh_")
	copy(out[3:], buf[i:])
	return string(out)
}

@(test)
test_shell_write_result_enum_is_reachable :: proc(t: ^testing.T) {
	r := ws.Text_Write_Result.Ok
	testing.expect_value(t, r, ws.Text_Write_Result.Ok)
}

// --- REQ-SHELL-33 viewer broadcast fan-out and write-lock tests ---

@(private = "file")
Pair :: struct {
	listener: net.TCP_Socket,
	peer:     net.TCP_Socket,
	hub:      net.TCP_Socket,
}

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
	return Pair{listener = listener, peer = peer, hub = hub}
}

@(private = "file")
close_pair :: proc(p: ^Pair) {
	net.close(p.hub)
	net.close(p.peer)
	net.close(p.listener)
}

@(private = "file")
over_cap_payload :: proc() -> string {
	n := ws.WS_MAX_SERVER_PAYLOAD + 1
	b := make([]byte, n)
	for i in 0 ..< n do b[i] = 'A'
	return string(b)
}

@(test)
test_broadcast_output_too_large_frame_does_not_detach_live_viewer :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	svc := Shell_Session_Service{}
	defer shell_session_service_free(&svc)

	shell_session_attach(&svc, "sh_big", pair.hub)
	testing.expect_value(t, shell_session_viewer_count(&svc, "sh_big"), 1)

	payload := over_cap_payload()
	defer delete(payload)
	shell_session_broadcast_output(&svc, "sh_big", payload)

	testing.expect_value(t, shell_session_viewer_count(&svc, "sh_big"), 1)
}

@(test)
test_broadcast_status_too_large_frame_does_not_detach_live_viewer :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	svc := Shell_Session_Service{}
	defer shell_session_service_free(&svc)

	shell_session_attach(&svc, "sh_status", pair.hub)
	payload := over_cap_payload()
	defer delete(payload)
	shell_session_broadcast_status(&svc, "sh_status", payload, 0, false)

	testing.expect_value(t, shell_session_viewer_count(&svc, "sh_status"), 1)
}

@(test)
test_broadcast_output_dead_viewer_is_detached :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	svc := Shell_Session_Service{}
	defer shell_session_service_free(&svc)

	shell_session_attach(&svc, "sh_dead", pair.hub)
	testing.expect_value(t, shell_session_viewer_count(&svc, "sh_dead"), 1)

	_ = net.shutdown(pair.hub, .Send)

	shell_session_broadcast_output(&svc, "sh_dead", "aGk=")
	pane_test_wait_writer(t, &svc, pair.hub)
	testing.expect_value(t, shell_session_viewer_count(&svc, "sh_dead"), 0)
}

@(test)
test_broadcast_output_healthy_viewer_stays_attached :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	svc := Shell_Session_Service{}
	defer shell_session_service_free(&svc)

	shell_session_attach(&svc, "sh_ok", pair.hub)
	shell_session_broadcast_output(&svc, "sh_ok", "aGVsbG8=")
	testing.expect_value(t, shell_session_viewer_count(&svc, "sh_ok"), 1)
}

@(private = "file")
Blocked_Broadcast :: struct {
	svc:  ^Shell_Session_Service,
	done: bool,
}

@(private = "file")
broadcast_worker :: proc(raw: rawptr) {
	b := (^Blocked_Broadcast)(raw)
	shell_session_broadcast_output(b.svc, "sh_lock", "QUJD")
	sync.atomic_store(&b.done, true)
}

@(test)
test_broadcast_output_writes_under_session_write_lock :: proc(t: ^testing.T) {
	pair := make_pair(t)
	defer close_pair(&pair)
	svc := Shell_Session_Service{}
	defer shell_session_service_free(&svc)
	shell_session_attach(&svc, "sh_lock", pair.hub)

	write_mu := shell_session_viewer_write_lock(&svc, "sh_lock")
	testing.expect(t, write_mu != nil, "an attached session must have a write lock")
	sync.mutex_lock(write_mu)

	blocked := Blocked_Broadcast{svc = &svc}
	th := thread.create_and_start_with_data(rawptr(&blocked), broadcast_worker)
	defer thread.destroy(th)

	time.sleep(20 * time.Millisecond)
	testing.expect(
		t,
		!sync.atomic_load(&blocked.done),
		"the fan-out completed while the session write lock was held — it is not taking it, so a chunked snapshot can be split by an output frame",
	)

	sync.mutex_unlock(write_mu)
	shell_session_viewer_write_release(&svc, "sh_lock")
	thread.join(th)
	testing.expect(t, sync.atomic_load(&blocked.done), "the fan-out must proceed once the lock is released")
}
