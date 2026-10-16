package shell_session

// REQ-PTY-NET-4 — the per-session repaint cache.

import "core:net"
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import ws "odin_test:lib/ws"

@(private = "file")
snap_frame :: proc(text: string, snapshot := true) -> []byte {
	return contracts.pty_wire_encode_viewer_frame(contracts.PTY_WIRE_KIND_OUTPUT, contracts.pty_wire_flags(snapshot, false), transmute([]byte)text)
}

@(test)
test_snapshot_cache_catchup_paints_broadcast_viewers_and_serves_late_joiner :: proc(t: ^testing.T) {
	svc := new_shell_session_service()
	defer shell_session_service_free(&svc)
	v1 := net.TCP_Socket(1001)
	v2 := net.TCP_Socket(1002)

	// Two-frame catch-up sequence fanned out to v1 only (v2 joins later).
	f1 := snap_frame("\x1b[2J\x1b[Hrow one of a screen that is long enough\r\n")
	defer delete(f1)
	f2 := snap_frame("row two\r\n")
	defer delete(f2)
	shell_session_snapshot_cache_note_output(&svc, "sh_a", f1, true, {v1})
	shell_session_snapshot_cache_note_output(&svc, "sh_a", f2, true, {v1})
	testing.expect(t, shell_session_snapshot_cache_has(&svc, "sh_a"))

	testing.expect_value(t, shell_session_snapshot_cache_decide(&svc, "sh_a", v1, 80, 24), Shell_Snapshot_Decision.Already_Painted)
	testing.expect_value(t, shell_session_snapshot_cache_decide(&svc, "sh_a", v2, 80, 24), Shell_Snapshot_Decision.Serve)

	// An incremental frame closes the sequence; a later snapshot starts a NEW entry.
	inc := snap_frame("$ ", false)
	defer delete(inc)
	shell_session_snapshot_cache_note_output(&svc, "sh_a", inc, false, {v1})
	testing.expect_value(t, shell_session_snapshot_cache_decide(&svc, "sh_a", v2, 80, 24), Shell_Snapshot_Decision.Serve) // still cached
	f3 := snap_frame("\x1b[2J\x1b[Ha brand new repaint after a resize or reattach\r\n")
	defer delete(f3)
	shell_session_snapshot_cache_note_output(&svc, "sh_a", f3, true, {v2})
	testing.expect_value(t, shell_session_snapshot_cache_decide(&svc, "sh_a", v2, 80, 24), Shell_Snapshot_Decision.Already_Painted)
	testing.expect_value(t, shell_session_snapshot_cache_decide(&svc, "sh_a", v1, 80, 24), Shell_Snapshot_Decision.Serve) // v1 saw the OLD one only

	// A tiny catch-up (just a CUP) is not a screen: nobody counts as painted by it.
	tiny := snap_frame("\x1b[1;1H")
	defer delete(tiny)
	shell_session_snapshot_cache_note_output(&svc, "sh_b", tiny, true, {v1})
	testing.expect_value(t, shell_session_snapshot_cache_decide(&svc, "sh_b", v1, 80, 24), Shell_Snapshot_Decision.Miss)
}

@(test)
test_snapshot_cache_capture_store_matches_geometry_and_evicts :: proc(t: ^testing.T) {
	svc := new_shell_session_service()
	defer shell_session_service_free(&svc)
	v1 := net.TCP_Socket(2001)
	v2 := net.TCP_Socket(2002)
	cap_frame := contracts.pty_wire_encode_viewer_frame(contracts.PTY_WIRE_KIND_SCREEN, contracts.pty_wire_flags(true, false), transmute([]byte)string("\x1b[2J\x1b[Hcaptured at 120x40 ok"), 0, 5)
	defer delete(cap_frame)
	shell_session_snapshot_cache_store_capture(&svc, "sh_c", {cap_frame}, 120, 40, v1)
	testing.expect_value(t, shell_session_snapshot_cache_decide(&svc, "sh_c", v1, 120, 40), Shell_Snapshot_Decision.Already_Painted)
	testing.expect_value(t, shell_session_snapshot_cache_decide(&svc, "sh_c", v2, 120, 40), Shell_Snapshot_Decision.Serve)
	testing.expect_value(t, shell_session_snapshot_cache_decide(&svc, "sh_c", v2, 80, 24), Shell_Snapshot_Decision.Serve) // fresh wins regardless of geometry

	// Age it past freshness: same geometry still serves, a different one misses.
	svc.snapshot_cache["sh_c"].at = time.Tick{_nsec = time.tick_now()._nsec - i64(SHELL_SNAPSHOT_CACHE_FRESH) - 1}
	testing.expect_value(t, shell_session_snapshot_cache_decide(&svc, "sh_c", v2, 120, 40), Shell_Snapshot_Decision.Serve)
	testing.expect_value(t, shell_session_snapshot_cache_decide(&svc, "sh_c", v2, 80, 24), Shell_Snapshot_Decision.Miss)

	// Over the cap: not cached at all.
	big := strings.repeat("x", SHELL_SNAPSHOT_CACHE_MAX_BYTES + 1)
	defer delete(big)
	big_frame := snap_frame(big)
	defer delete(big_frame)
	shell_session_snapshot_cache_note_output(&svc, "sh_big", big_frame, true, {v1})
	testing.expect(t, !shell_session_snapshot_cache_has(&svc, "sh_big"), "an over-cap repaint is not cached")

	// Explicit eviction (stream closed) and eviction on detach-to-zero.
	shell_session_snapshot_cache_evict(&svc, "sh_c")
	testing.expect(t, !shell_session_snapshot_cache_has(&svc, "sh_c"))
}

@(test)
test_snapshot_cache_serve_writes_frames_once_and_detach_to_zero_evicts :: proc(t: ^testing.T) {
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if lerr != nil do testing.fail_now(t, "listen")
	defer net.close(listener)
	bound, _ := net.bound_endpoint(listener)
	peer, derr := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if derr != nil do testing.fail_now(t, "dial")
	hub, _, aerr := net.accept_tcp(listener)
	if aerr != nil do testing.fail_now(t, "accept")
	defer net.close(hub)
	reader := ws.Connection{socket = peer, connected = true}
	defer ws.close(&reader)
	_ = net.set_blocking(peer, false)

	svc := new_shell_session_service()
	defer shell_session_service_free(&svc)
	shell_session_attach(&svc, "sh_serve", hub, "bridge")

	// Catch-up noted as fanned out to an EARLIER viewer (not `hub`).
	earlier := net.TCP_Socket(4242)
	f := snap_frame("\x1b[2J\x1b[Hcached screen for the late joiner\r\n")
	defer delete(f)
	shell_session_snapshot_cache_note_output(&svc, "sh_serve", f, true, {earlier})

	testing.expect_value(t, shell_session_snapshot_cache_decide(&svc, "sh_serve", hub, 80, 24), Shell_Snapshot_Decision.Serve)
	testing.expect(t, shell_session_snapshot_cache_serve(&svc, "sh_serve", hub))
	// It arrives as the SAME binary frame, once.
	text := pane_test_read(t, &reader)
	defer delete(text)
	testing.expect_value(t, text, string(f))
	testing.expect_value(t, shell_session_snapshot_cache_decide(&svc, "sh_serve", hub, 80, 24), Shell_Snapshot_Decision.Already_Painted)

	// Last viewer leaves -> cache gone.
	shell_session_detach(&svc, "sh_serve", hub)
	testing.expect(t, !shell_session_snapshot_cache_has(&svc, "sh_serve"), "detach-to-zero evicts the repaint")
}
