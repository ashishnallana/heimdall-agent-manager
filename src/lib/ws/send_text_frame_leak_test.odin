package ws

// REQ-SHELL-52 AC4 — the COMMITTED GUARD for the `defer delete(frame)` in send_text.
//
// WHY THIS FILE EXISTS AT ALL, since the fix it guards is one line that is already in
// origin/main (4e4ff21e). The proof behind that push was a scratch probe that was
// deliberately NOT committed, so nothing stood between the `defer` and a future
// "tidy up the defers" pass. The census on REQ-SHELL-52 is the argument: there are FIVE
// copies of this frame writer in the tree, and the two that freed correctly were the two
// with a committed test near them. This writer family has had its duplicate count
// mis-stated three times (REQ-SHELL-33 stopped at three copies, 35 found the fourth, 47
// found the fifth and miscounted the leaks as one), so "someone will read the commit
// message" is not a guard.
//
// WHAT IT ASSERTS, AND WHY A GREEN SUITE IS NOT THE BAR. The suites were ALREADY green
// with the leak present — that is exactly how it survived. So these tests do not check
// that send_text works; they check that the heap is back where it started. Each runs on
// a mem.Tracking_Allocator and asserts BOTH halves, following the idiom in
// src/bridge/shell_cwd_test.odin:75 and shell_session_ownership_test.odin:506+527:
//
//   * allocation_map back at its baseline  -> the frame was freed (the LEAK half)
//   * bad_free_array empty                 -> it was freed ONCE, by its owner, with the
//                                             allocator it came from (the DOUBLE-FREE half)
//
// Asserting only the leak half would be the wrong single check here: `send_all_tcp` and
// `send_all_file` BORROW the slice, and if a future change made either of them free it,
// the leak count would read clean while a double free went latent. REQ-SHELL-50 already
// records 14 pre-existing bad frees in this codebase; this pair of assertions is what
// stops this writer from contributing the fifteenth.
//
// THE FAILURE-PATH TEST IS NOT REDUNDANT. `defer` covers every exit by construction
// today, but the original defect's severity came from send_all_tcp's THREE early returns
// (deadline, error, n<=0) each dropping the frame. A test that only ever exercises the
// success path would still pass if a future refactor replaced the `defer` with a single
// `delete(frame)` before `return true`.

import "core:mem"
import "core:net"
import "core:strings"
import "core:testing"
import "core:time"

// Deliberately a private copy of the loopback fixture rather than a reach into
// server_frame_test.odin's `Pair`: that one is @(private = "file") and unreachable from
// here by design. Same shape, same enlarged buffers, same reason.
@(private = "file")
Leak_Pair :: struct {
	listener: net.TCP_Socket,
	peer:     net.TCP_Socket,
	hub:      net.TCP_Socket,
}

// 4 MiB each way: every frame these tests write must leave the sender without a draining
// peer, or send_all_tcp would sit on its 5s WRITE_DEADLINE and the test would measure the
// timeout rather than the free.
@(private = "file")
LEAK_PAIR_BUFFER_BYTES :: 4 * 1024 * 1024

@(private = "file")
leak_make_pair :: proc(t: ^testing.T) -> Leak_Pair {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil do testing.fail_now(t, "fixture: could not listen on loopback")
	bound, bound_err := net.bound_endpoint(listener)
	if bound_err != nil {
		net.close(listener)
		testing.fail_now(t, "fixture: could not read the bound endpoint")
	}
	peer, dial_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if dial_err != nil {
		net.close(listener)
		testing.fail_now(t, "fixture: could not dial loopback")
	}
	hub, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil {
		net.close(listener)
		net.close(peer)
		testing.fail_now(t, "fixture: could not accept on loopback")
	}
	_ = net.set_option(hub, .Send_Buffer_Size, LEAK_PAIR_BUFFER_BYTES)
	_ = net.set_option(peer, .Receive_Buffer_Size, LEAK_PAIR_BUFFER_BYTES)
	_ = net.set_option(peer, .Receive_Timeout, 2 * time.Second)
	return Leak_Pair{listener = listener, peer = peer, hub = hub}
}

@(private = "file")
leak_close_pair :: proc(p: ^Leak_Pair) {
	net.close(p.hub)
	net.close(p.peer)
	net.close(p.listener)
}

// Both halves, in one place, so no test can quietly make only one of them.
@(private = "file")
leak_expect_heap_restored :: proc(t: ^testing.T, track: ^mem.Tracking_Allocator, baseline_allocs: int, what: string) {
	testing.expectf(t, len(track.allocation_map) == baseline_allocs,
		"%s: LEAK — %d live allocations, expected the baseline %d. send_text's `defer delete(frame)` is the only thing that frees this; send_all_tcp and send_all_file borrow.",
		what, len(track.allocation_map), baseline_allocs)
	testing.expectf(t, len(track.bad_free_array) == 0,
		"%s: %d BAD FREES — the frame was freed twice, or with the wrong allocator. A sender must not free a slice send_text owns.",
		what, len(track.bad_free_array))
}

// FRAME_REPEATS: enough that a per-frame leak is unmistakable rather than a rounding
// error, and small enough to stay instant. With the defer removed this shows 64 (or 128,
// both header widths) live allocations against a baseline of the fixture's own.
@(private = "file")
FRAME_REPEATS :: 64

// The two header widths are both exercised because they are separate `make` sizes on
// separate branches: n <= 125 takes the 2-byte header, anything larger takes the 4-byte
// 126 arm. A leak guard that only ever saw one branch would guard half the writer.
@(test)
test_send_text_frees_its_frame_on_the_success_path :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	pair := leak_make_pair(t)
	defer leak_close_pair(&pair)

	// 1000 bytes: over 125, so the 4-byte header arm, and far under the 65535 refusal.
	big := strings.repeat("x", 1000)
	defer delete(big)

	conn := Connection{socket = pair.hub, secure = false, connected = true}

	baseline_allocs := len(track.allocation_map)
	{
		for _ in 0 ..< FRAME_REPEATS {
			testing.expect(t, send_text(&conn, "short"), "fixture: the 2-byte-header write must succeed on a drained loopback")
			testing.expect(t, send_text(&conn, big), "fixture: the 4-byte-header write must succeed on a drained loopback")
		}
	}
	leak_expect_heap_restored(t, &track, baseline_allocs, "send_text success path")
}

// The exits BELOW the allocation are the ones that mattered: send_all_tcp has three
// (deadline, send error, n <= 0) and send_all_file two, and before 4e4ff21e every one of
// them dropped the frame. A closed socket reaches the error arm deterministically and
// without the SIGPIPE risk of writing to a socket whose peer went away.
@(test)
test_send_text_frees_its_frame_when_the_write_fails :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	pair := leak_make_pair(t)
	defer leak_close_pair(&pair)
	// Shut down both directions while keeping the descriptor open until defer: closing the
	// descriptor up front allows the kernel to recycle the numeric FD into another parallel
	// test thread's socket pair mid-run.
	_ = net.shutdown(pair.hub, .Both)

	big := strings.repeat("y", 1000)
	defer delete(big)

	conn := Connection{socket = pair.hub, secure = false, connected = true}

	baseline_allocs := len(track.allocation_map)
	{
		for _ in 0 ..< FRAME_REPEATS {
			conn.connected = true
			testing.expect(t, !send_text(&conn, big),
				"a write on a shut-down socket must report failure — if this passes, the test is no longer exercising the failure exit")
		}
	}
	leak_expect_heap_restored(t, &track, baseline_allocs, "send_text failure path")
}

// The two exits ABOVE the allocation, pinned so the baseline in the tests above stays
// meaningful: if either of these ever started allocating, a leak there would be invisible
// to a test that assumed nothing is allocated before the `make`.
@(test)
test_send_text_allocates_nothing_on_the_pre_allocation_refusals :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	pair := leak_make_pair(t)
	defer leak_close_pair(&pair)

	oversized := strings.repeat("z", WS_MAX_SERVER_PAYLOAD + 1)
	defer delete(oversized)

	baseline_allocs := len(track.allocation_map)
	{
		disconnected := Connection{socket = pair.hub, secure = false, connected = false}
		testing.expect(t, !send_text(&disconnected, "short"), "a disconnected connection must refuse the write")

		connected := Connection{socket = pair.hub, secure = false, connected = true}
		testing.expect(t, !send_text(&connected, oversized),
			"payloads exceeding WS_MAX_SERVER_PAYLOAD must be refused before allocation")
	}
	leak_expect_heap_restored(t, &track, baseline_allocs, "send_text pre-allocation refusals")
}
