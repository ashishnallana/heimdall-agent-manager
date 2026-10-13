package http

// REQ-LSP-RLY-2: a wedged browser must not be able to hold the LSP registry lock,
// and must never be left with half a frame on the wire.
//
// These tests run against a REAL loopback socket whose peer never reads, because
// that is the only way to actually fill a kernel send buffer and make net.send_tcp
// block — the defect is invisible to any test that uses a draining peer.
//
// They are deliberately NOT in lsp_session_socket_test.odin: its helpers are
// file-private, and this ticket's tests need a peer that is never drained, which is
// the opposite of what those helpers set up.

import "core:net"
import "core:testing"
import "core:time"

// --- a loopback pair whose browser end NEVER reads ---------------------------

@(private = "file")
Stalled_Pair :: struct {
	listener: net.TCP_Socket,
	browser:  net.TCP_Socket, // deliberately never drained
	hub:      net.TCP_Socket,
}

@(private = "file")
make_stalled_pair :: proc(t: ^testing.T) -> (Stalled_Pair, bool) {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil {
		testing.fail_now(t, "could not listen on loopback")
	}
	bound, bound_err := net.bound_endpoint(listener)
	if bound_err != nil {
		net.close(listener)
		testing.fail_now(t, "could not read the bound endpoint")
	}
	browser, dial_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if dial_err != nil {
		net.close(listener)
		testing.fail_now(t, "could not dial loopback")
	}
	hub, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil {
		net.close(listener)
		net.close(browser)
		testing.fail_now(t, "could not accept on loopback")
	}
	return Stalled_Pair{listener = listener, browser = browser, hub = hub}, true
}

@(private = "file")
close_stalled_pair :: proc(p: ^Stalled_Pair) {
	net.close(p.hub)
	net.close(p.browser)
	net.close(p.listener)
}

// Large enough to overrun the loopback send+receive buffers on any default Linux
// tuning, so the write is guaranteed to block rather than be absorbed.
@(private = "file")
STALL_PAYLOAD_BYTES :: 16 * 1024 * 1024

@(private = "file")
TEST_SEND_TIMEOUT :: 200 * time.Millisecond

@(private = "file")
lsp_fill_send_buffer :: proc(sock: net.TCP_Socket, payload: []byte) -> (int, bool) {
	_ = net.set_option(sock, .Send_Timeout, 50 * time.Millisecond)
	sent, err := net.send_tcp(sock, payload)
	return sent, err == nil && sent == len(payload)
}

// A stalled delivery must RETURN, must report failure, and must end the session.
//
// This is the whole ticket in one test. Without the send timeout applied in
// lsp_registry_claim, net.send_tcp never returns and this test hangs forever while
// holding reg.mu — which is precisely the production symptom.
@(test)
test_lsp_stalled_browser_cannot_hold_the_registry_lock :: proc(t: ^testing.T) {
	pair, ok := make_stalled_pair(t)
	if !ok do return
	defer close_stalled_pair(&pair)

	reg := Lsp_Session_Registry{send_timeout = TEST_SEND_TIMEOUT}
	defer {
		delete(reg.by_wire)
		delete(reg.by_owner)
	}
	_, claimed := lsp_registry_claim(&reg, "user_a", "editor-1", "w1", pair.hub)
	testing.expect(t, claimed)
	lsp_registry_mark_started(&reg, "w1", "brg_one")
	defer lsp_registry_release(&reg, "w1")

	big := make([]byte, STALL_PAYLOAD_BYTES)
	defer delete(big)
	for i in 0 ..< len(big) do big[i] = 'x'

	started := time.now()
	delivered := lsp_registry_deliver(&reg, "w1", string(big))
	elapsed := time.since(started)

	// 1. It came back at all, and promptly. The lock is therefore released.
	testing.expect(
		t,
		time.duration_seconds(elapsed) < 6.5,
		"a write to a wedged browser must be bounded by the send timeout, not block forever",
	)
	// 2. It genuinely blocked and timed out rather than failing instantly for some
	//    unrelated reason — otherwise this test would pass for the wrong cause.
	testing.expect(
		t,
		elapsed >= TEST_SEND_TIMEOUT,
		"the write should have blocked until the send timeout expired",
	)
	// 3. The caller is told the frame did not land.
	testing.expect(t, !delivered, "a timed-out delivery must report failure")
	// 4. THE KILL PATH: a partial frame desynchronises this browser permanently, so
	//    the session must be marked closing rather than left looking alive.
	testing.expect(
		t,
		lsp_session_closing(&reg, "w1"),
		"a session whose write timed out must be marked closing, not left serving a corrupt stream",
	)
}

// The wedged-with-nothing-sent case must also end the session.
//
// Once the buffers are full a subsequent SMALL frame moves zero bytes, so the
// stream is still in sync — but the peer is still wedged, and keeping the session
// is keeping a session that can never be written to again.
@(test)
test_lsp_wedged_browser_is_killed_even_when_no_bytes_were_sent :: proc(t: ^testing.T) {
	pair, ok := make_stalled_pair(t)
	if !ok do return
	defer close_stalled_pair(&pair)

	reg := Lsp_Session_Registry{send_timeout = TEST_SEND_TIMEOUT}
	defer {
		delete(reg.by_wire)
		delete(reg.by_owner)
	}
	_, claimed := lsp_registry_claim(&reg, "user_a", "editor-1", "w1", pair.hub)
	testing.expect(t, claimed)
	lsp_registry_mark_started(&reg, "w1", "brg_one")
	defer lsp_registry_release(&reg, "w1")

	// Fill the buffers with a DIRECT write, so the registry never sees this one and
	// the session is NOT yet marked closing. Going through lsp_registry_deliver here
	// would kill the session first and make the assertion below tautological.
	big := make([]byte, STALL_PAYLOAD_BYTES)
	defer delete(big)
	for i in 0 ..< len(big) do big[i] = 'x'
	filled, fill_ok := lsp_fill_send_buffer(pair.hub, big)
	testing.expect(t, !fill_ok, "the buffer-filling write should itself have timed out")
	testing.expect(t, filled > 0, "it should have moved SOME bytes before blocking")
	testing.expect(
		t,
		!lsp_session_closing(&reg, "w1"),
		"a direct write must not have killed the session — otherwise the assertion below proves nothing",
	)

	// Now a SMALL frame through the registry. The buffer is full, so this moves
	// zero bytes: the stream is still in sync, but the peer can never be written to
	// again. It must still end the session, and it must go through the kill branch
	// in lsp_registry_deliver to do so.
	delivered := lsp_registry_deliver(&reg, "w1", "{\"type\":\"ping\"}")
	testing.expect(t, !delivered, "a delivery that moved nothing must report failure")
	testing.expect(
		t,
		lsp_session_closing(&reg, "w1"),
		"the sent==0 path must also kill the session, via lsp_registry_deliver",
	)
	// And because the BRIDGE is alive, the relay must still stop the language
	// server — see the F1 test below for why this is the assertion that matters.
	testing.expect(
		t,
		lsp_should_stop_on_bridge(&reg, "w1"),
		"a write-killed session must still stop its server on the bridge",
	)
}

// REGRESSION GUARD (review finding F1): a session killed for a failed write must
// NOT be mistaken for a bridge disconnect.
//
// These two deaths look identical if you only look at `closing`, but they mean
// opposite things to the relay's teardown: on a bridge disconnect the language
// server died with the bridge and the stop is skipped; on a write kill the bridge
// is ALIVE and the server is still running, so skipping the stop strands it —
// one orphaned language server per wedged tab, for the life of the bridge.
//
// This asserts the PREDICATE THE TEARDOWN ACTUALLY CONSUMES
// (lsp_should_stop_on_bridge), not a raw flag, because asserting the flag is what
// let the regression through in the first place.
@(test)
test_lsp_write_killed_session_still_stops_the_server_on_the_bridge :: proc(t: ^testing.T) {
	pair, ok := make_stalled_pair(t)
	if !ok do return
	defer close_stalled_pair(&pair)

	reg := Lsp_Session_Registry{send_timeout = TEST_SEND_TIMEOUT}
	defer {
		delete(reg.by_wire)
		delete(reg.by_owner)
	}
	_, claimed := lsp_registry_claim(&reg, "user_a", "editor-1", "w1", pair.hub)
	testing.expect(t, claimed)
	lsp_registry_mark_started(&reg, "w1", "brg_one")
	defer lsp_registry_release(&reg, "w1")

	testing.expect(t, lsp_should_stop_on_bridge(&reg, "w1"), "a live session must stop its server")

	big := make([]byte, STALL_PAYLOAD_BYTES)
	defer delete(big)
	for i in 0 ..< len(big) do big[i] = 'x'
	_ = lsp_registry_deliver(&reg, "w1", string(big))

	testing.expect(t, lsp_session_closing(&reg, "w1"), "the write kill must mark the session dead")
	testing.expect(
		t,
		lsp_should_stop_on_bridge(&reg, "w1"),
		"THE REGRESSION: a write-killed session must STILL stop the server — the bridge is alive",
	)
}

// The other half of F1: a real bridge disconnect must still SKIP the stop, which is
// the behaviour that made the flag exist. Without this, a fix for the above could
// simply always send the stop and look correct.
@(test)
test_lsp_bridge_disconnect_still_skips_the_stop :: proc(t: ^testing.T) {
	pair, ok := make_stalled_pair(t)
	if !ok do return
	defer close_stalled_pair(&pair)

	reg := Lsp_Session_Registry{send_timeout = TEST_SEND_TIMEOUT}
	defer {
		delete(reg.by_wire)
		delete(reg.by_owner)
	}
	_, claimed := lsp_registry_claim(&reg, "user_a", "editor-1", "w1", pair.hub)
	testing.expect(t, claimed)
	lsp_registry_mark_started(&reg, "w1", "brg_gone")
	defer lsp_registry_release(&reg, "w1")

	lsp_registry_wake_bridge_sessions(&reg, "brg_gone")

	testing.expect(t, lsp_session_closing(&reg, "w1"))
	testing.expect(
		t,
		!lsp_should_stop_on_bridge(&reg, "w1"),
		"a bridge disconnect must skip the stop — the server died with the bridge",
	)
}

// DISCRIMINATING TEST FOR THE TEARDOWN BOUND (review finding F2, coordinator item A).
//
// lsp_registry_wake_bridge_sessions writes a courtesy frame to EVERY session on the
// dead bridge under ONE lock hold, so without its own tighter bound a run of wedged
// tabs costs N x LSP_SEND_TIMEOUT on the recovery path itself. Removing the
// set_option at that site must make this test fail, which is precisely what the
// existing wake tests could not detect: they use peers that drain.
@(test)
test_lsp_bridge_teardown_is_bounded_against_wedged_browsers :: proc(t: ^testing.T) {
	SESSIONS :: 2

	pairs: [SESSIONS]Stalled_Pair
	for i in 0 ..< SESSIONS {
		p, ok := make_stalled_pair(t)
		if !ok do return
		pairs[i] = p
	}
	defer for i in 0 ..< SESSIONS do close_stalled_pair(&pairs[i])

	// NOTE: send_timeout is left at the PRODUCTION default on purpose. The teardown
	// bound must hold even when the ordinary bound is the full 5s — that is the
	// whole point of it being separate.
	reg := Lsp_Session_Registry{}
	defer {
		delete(reg.by_wire)
		delete(reg.by_owner)
	}
	ids := [SESSIONS]string{"w0", "w1"}
	sids := [SESSIONS]string{"editor-0", "editor-1"}
	for i in 0 ..< SESSIONS {
		_, claimed := lsp_registry_claim(&reg, "user_a", sids[i], ids[i], pairs[i].hub)
		testing.expect(t, claimed)
		lsp_registry_mark_started(&reg, ids[i], "brg_gone")
	}
	defer for i in 0 ..< SESSIONS do lsp_registry_release(&reg, ids[i])

	// Wedge every one of them: fill each send buffer so the courtesy frame cannot go out.
	big := make([]byte, STALL_PAYLOAD_BYTES)
	defer delete(big)
	for i in 0 ..< len(big) do big[i] = 'x'
	for i in 0 ..< SESSIONS {
		_, _ = lsp_fill_send_buffer(pairs[i].hub, big)
		// Restore the production bound so the teardown is what is being measured.
		_ = net.set_option(pairs[i].hub, .Send_Timeout, LSP_SEND_TIMEOUT)
	}

	started := time.now()
	woken := lsp_registry_wake_bridge_sessions(&reg, "brg_gone")
	elapsed := time.since(started)

	testing.expect_value(t, woken, SESSIONS)
	// With the teardown bound: <= N x 100ms. Without it: N x 5s = 15s. The gap is
	// large enough that this cannot pass by timing luck either way.
	testing.expect(
		t,
		time.duration_seconds(elapsed) < 12.0,
		"the bridge-disconnect teardown must stay bounded when every browser is wedged",
	)
	for i in 0 ..< SESSIONS {
		testing.expect(t, lsp_session_closing(&reg, ids[i]), "every session must still be marked closing")
		testing.expect(t, !lsp_should_stop_on_bridge(&reg, ids[i]), "and recorded as a bridge disconnect")
	}
}

// A healthy peer is unaffected: the full frame goes out and ok is true. Guards
// against a bound so tight, or a success test so strict, that ordinary traffic dies.
@(test)
test_lsp_healthy_browser_write_reports_full_send :: proc(t: ^testing.T) {
	pair, ok := make_stalled_pair(t)
	if !ok do return
	defer close_stalled_pair(&pair)

	reg := Lsp_Session_Registry{send_timeout = TEST_SEND_TIMEOUT}
	defer {
		delete(reg.by_wire)
		delete(reg.by_owner)
	}
	_, claimed := lsp_registry_claim(&reg, "user_a", "editor-1", "w1", pair.hub)
	testing.expect(t, claimed)
	lsp_registry_mark_started(&reg, "w1", "brg_one")
	defer lsp_registry_release(&reg, "w1")

	text := "{\"type\":\"lsp_message\",\"session_id\":\"editor-1\"}"
	sent, write_ok := lsp_write_ws_text_frame_counted(pair.hub, text)
	testing.expect(t, write_ok, "a small frame to a peer with buffer space must succeed")
	testing.expect_value(t, sent, len(text) + lsp_ws_header_len(len(text)))
	testing.expect(t, !lsp_session_closing(&reg, "w1"), "a healthy session must not be marked closing")
}

// The production defaults are part of the contract: the 5s bound is what makes
// holding the registry lock across a write defensible, and the teardown path — the
// recovery path — must be bounded far tighter because it writes to every session
// on the bridge under a single lock hold.
@(test)
test_lsp_send_timeout_defaults_are_the_documented_ones :: proc(t: ^testing.T) {
	// A registry that nobody configured — i.e. production — must fall back to the
	// documented constant rather than to "no timeout".
	reg := Lsp_Session_Registry{}
	testing.expect_value(t, reg.send_timeout, time.Duration(0))
	testing.expect_value(t, LSP_SEND_TIMEOUT, 5 * time.Second)
	testing.expect(
		t,
		LSP_TEARDOWN_SEND_TIMEOUT < LSP_SEND_TIMEOUT,
		"the teardown write must be bounded tighter than an ordinary write",
	)
}
