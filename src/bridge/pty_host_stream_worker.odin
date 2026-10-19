package main

import local_socket "odin_test:lib/local_socket"
import "base:runtime"
import "core:crypto"
import "core:crypto/aes"
import base64 "core:encoding/base64"
import "core:encoding/hex"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import ws "odin_test:lib/ws"
import os_random "odin_test:lib/os_random"
import vault "odin_test:lib/vault"

// Bridge_PTY_Stream_Worker holds state for one dedicated streaming socket worker (REQ-STREAM-IMPL-1).
// To isolate high-throughput PTY Output from the single-threaded WatchEvents control loop
// (permanently resolving BUG-10 / false agent reaper timeouts), each streaming session
// opens its own dedicated UNIX domain socket connection to ham-pty-host.
Bridge_PTY_Stream_Worker :: struct {
	session_id:            string,
	shell_id:              string,
	fd:                    local_socket.Socket,
	active:                bool,
	conn:                  ^ws.Connection,
	// PTY v2 (passwordless-vault.md §1): frames are sealed under the per-stream subkey
	// HKDF(epoch key, salt16, "heimdall-pty-v2|<session_id>|out") with nonce
	// u32be(0) || u64be(seq). The salt is fresh CSPRNG output for every worker start,
	// every epoch change and every keyring install (salt_generation), and seq never
	// resets under one salt, so a (subkey, nonce) pair is never reused.
	salt:                  Bridge_PTY_Salt,
	seq:                   u64,
	salt_epoch:            u32,
	salt_generation:       u64,
	salt_set:              bool,
	locked_banner_emitted: bool,
	emitting_snapshot: bool,
}

bridge_pty_stream_fallback_mu: sync.Mutex
bridge_pty_stream_fallback_salt: Bridge_PTY_Salt
bridge_pty_stream_fallback_seq: u64
bridge_pty_stream_fallback_epoch: u32
bridge_pty_stream_fallback_generation: u64
bridge_pty_stream_fallback_inited: bool

Bridge_PTY_Salt :: [vault.PTY_V2_SALT_BYTES]byte

// bridge_pty_salt_generation is bumped on every keyring install, so every stream
// draws a fresh salt before it seals again.
bridge_pty_salt_generation: u64

bridge_pty_stream_resalt_all :: proc() {
	sync.atomic_add(&bridge_pty_salt_generation, 1)
}

// bridge_pty_random_source is the CSPRNG the salt is drawn from; tests point it at
// an unreadable path to prove a randomness failure seals nothing.
bridge_pty_random_source := os_random.DEFAULT_SOURCE

// Bridge_PTY_Stream_Outgoing is ONE queued record for the hub connection. Exactly one of
// `json` or `data` is set:
//   - `json`  : a pre-formatted control/lifecycle frame (stream_ready, stream_closed,
//               pane_resync_required, shell_pty_vault_locked). Sent verbatim, never merged.
//   - `data`  : PLAINTEXT PTY output for `session_id`. The queue holds plaintext on purpose
//               (REQ-PTY-NET-1): the drain merges adjacent records of one session into a
//               single wire frame and only THEN encrypts, so one AES-GCM header and one
//               envelope are paid per merged frame rather than per 8 KiB pty read.
//
// `salt`/`seq` are reserved at ENQUEUE time from the owning worker's counter, because the
// worker may have been freed by the time the drain runs. A merged frame uses the FIRST
// record's (salt, seq); the skipped values are simply never used, which keeps every nonce
// unique under one key (NIST SP 800-38D needs uniqueness, not density).
Bridge_PTY_Stream_Outgoing :: struct {
	json:       string,
	data:       []byte,
	session_id: string,
	snapshot:   bool,
	encrypted:  bool,
	epoch:      u32,
	salt:       Bridge_PTY_Salt,
	seq:        u64,
}

// _bridge_pty_stream_outgoing_len is the queue-accounting size of one record.
_bridge_pty_stream_outgoing_len :: proc(item: Bridge_PTY_Stream_Outgoing) -> int {
	return len(item.json) + len(item.data)
}

// _bridge_pty_stream_outgoing_free releases everything a record owns.
_bridge_pty_stream_outgoing_free :: proc(item: Bridge_PTY_Stream_Outgoing, heap: runtime.Allocator) {
	if len(item.json) > 0 do delete(item.json, heap)
	if item.data != nil do delete(item.data, heap)
	delete(item.session_id, heap)
}

// Per-emitted-frame plaintext caps (REQ-PTY-NET-1). A record larger than its cap is split
// at enqueue so the drain never has to cut a record; the drain merges UP TO the cap.
// (Incremental and snapshot caps are separate knobs; today both sit at the edge-safe
// value below, so a snapshot simply costs more frames.)
//
// REQ-PTY-NET-2: these are the SOCAT values. Binary frames never pass through the
// kind:"chunk" re-splitter (it is text/base64-only), so a frame must fit the bridge->hub
// per-message cap on its own: under the legacy s_client transport (cap 6000 B) both caps
// drop to BRIDGE_PTY_STREAM_EMIT_SCLIENT_BYTES. See bridge_pty_stream_emit_caps.
//
// WHY 12 KiB AND NOT MORE. The prod edge (nginx -> Caddy) still enforces a ~16 KiB
// PER-MESSAGE WebSocket ceiling — contracts/bridge.odin, the note on
// BRIDGE_WS_HUB_RUNTIME_CHUNK_PAYLOAD_BYTES says lifting it is a separate rollout — and the
// pty path must not depend on that rollout. 12 KiB payload + 4 B pty_wire header + session
// id + WS header stays under it with margin. When the edge ceiling is lifted, raise
// BRIDGE_PTY_STREAM_EMIT_EDGE_SAFE_BYTES (the one constant) and both caps follow.
BRIDGE_PTY_STREAM_EMIT_EDGE_SAFE_BYTES   :: 12 * 1024
BRIDGE_PTY_STREAM_EMIT_INCREMENTAL_BYTES :: BRIDGE_PTY_STREAM_EMIT_EDGE_SAFE_BYTES
BRIDGE_PTY_STREAM_EMIT_SNAPSHOT_BYTES    :: BRIDGE_PTY_STREAM_EMIT_EDGE_SAFE_BYTES
BRIDGE_PTY_STREAM_EMIT_SCLIENT_BYTES     :: 4 * 1024
#assert(BRIDGE_PTY_STREAM_EMIT_SNAPSHOT_BYTES + 256 + 28 + contracts.PTY_WIRE_SESSION_HEADER_BYTES + 8 < 16 * 1024)
#assert(BRIDGE_PTY_STREAM_EMIT_SNAPSHOT_BYTES + 64 + 28 + contracts.PTY_WIRE_SESSION_HEADER_BYTES < contracts.BRIDGE_WS_HUB_RUNTIME_CHUNK_PAYLOAD_BYTES_SOCAT)
#assert(BRIDGE_PTY_STREAM_EMIT_SCLIENT_BYTES + 64 + 28 + contracts.PTY_WIRE_SESSION_HEADER_BYTES < contracts.BRIDGE_WS_HUB_RUNTIME_CHUNK_PAYLOAD_BYTES)

// bridge_pty_stream_emit_caps picks the per-frame plaintext caps for the current
// bridge->hub transport (the chunk cap is the proxy for it, see
// bridge_hub_runtime_chunk_payload_bytes). The 64 B above is the session-id allowance.
bridge_pty_stream_emit_caps :: proc() -> (incremental, snapshot: int) {
	return bridge_pty_stream_emit_caps_for(bridge_hub_runtime_chunk_payload_bytes())
}

// bridge_pty_stream_emit_caps_for is the pure core: caps for a given per-message chunk cap.
// Split out so the s_client (6000 B) case is testable without mutating HAM_TLS_BACKEND.
bridge_pty_stream_emit_caps_for :: proc(chunk_payload_cap: int) -> (incremental, snapshot: int) {
	if chunk_payload_cap >= contracts.BRIDGE_WS_HUB_RUNTIME_CHUNK_PAYLOAD_BYTES_SOCAT {
		return BRIDGE_PTY_STREAM_EMIT_INCREMENTAL_BYTES, BRIDGE_PTY_STREAM_EMIT_SNAPSHOT_BYTES
	}
	return BRIDGE_PTY_STREAM_EMIT_SCLIENT_BYTES, BRIDGE_PTY_STREAM_EMIT_SCLIENT_BYTES
}

// BRIDGE_PTY_STREAM_DRAIN_BUDGET_BYTES bounds ONE drain turn of the hub loop in bytes
// (it replaced a "4 frames per turn" cap, which throttled a busy pane to ~160 frames/s
// at the loop's 25 ms idle cadence while never merging anything). Heartbeat, lifecycle and
// inbound input are serviced between turns; the loop drops to its 1 ms busy cadence while
// this returns `more`.
BRIDGE_PTY_STREAM_DRAIN_BUDGET_BYTES :: 256 * 1024

Bridge_PTY_Stream_Map :: struct {
	mu:      sync.Mutex,
	workers: map[string]^Bridge_PTY_Stream_Worker, // keyed by session_id
}

bridge_pty_stream_map: Bridge_PTY_Stream_Map
bridge_pty_stream_outgoing_mu: sync.Mutex
bridge_pty_stream_outgoing: [dynamic]Bridge_PTY_Stream_Outgoing

// _bridge_pty_stream_outgoing_bind_heap pins the outgoing queue's BACKING ARRAY to the heap
// allocator, and must be called with bridge_pty_stream_outgoing_mu held before any append.
//
// WHY THIS EXISTS — IT IS THE FIX FOR A HARD SEGFAULT, NOT A TIDINESS MEASURE (REQ-SHELL-40).
// `bridge_pty_stream_outgoing` is a package-level `[dynamic]` declared with NO allocator, so its
// allocator field is nil until something appends. Odin's __dynamic_array_* then binds it to
// `context.allocator` AT THE MOMENT OF THE FIRST APPEND and keeps that binding forever.
//
// In production that is harmless by luck: the first append happens on a bridge worker whose
// context carries the default heap allocator, and the queue lives for the process's lifetime.
//
// UNDER THE TEST RUNNER IT IS FATAL. Each test runs with its OWN tracking allocator installed in
// the context, and the runner tears that allocator down when the test ends. So the first test to
// append bound this global's backing to an allocator that then died, and every later test appended
// through a DANGLING backing pointer. The reads come back as whatever now occupies that memory —
// which is how `delete(item.json)` in bridge_pty_stream_stop_all_for_reconnect came to be handed
// 0x5f68730a00000035, a pointer-shaped view of the ASCII bytes "_hs\n5". Confirmed under gdb:
//   #3 runtime::delete_string
//   #4 main::bridge_pty_stream_stop_all_for_reconnect (pty_host_stream_worker.odin)
//   #5 main::t40_stop_all_for_reconnect_detaches_every_worker
//
// It was invisible at the default thread count and DETERMINISTIC at -define:ODIN_TEST_THREADS=1,
// because what matters is which test appends FIRST and whether its allocator is already dead when
// the next one appends — test ORDER, not concurrency. More threads reordered it into hiding.
// REQ-SHELL-48 owns the invocation standard that let that stay hidden.
//
// Binding the ALLOCATOR FIELD rather than calling make() is deliberate: it allocates nothing, so it
// is safe to call on every locked path, and it cannot itself be the first binding done from a
// transient context.
_bridge_pty_stream_outgoing_bind_heap :: proc() {
	if bridge_pty_stream_outgoing.allocator.procedure == nil {
		bridge_pty_stream_outgoing.allocator = runtime.heap_allocator()
	}
}

// bridge_pty_stream_worker_start initiates an Attach-gated dedicated streaming worker.
// Dials a NEW, DEDICATED socket connection to ham-pty-host, sends CtlMsg::Attach,
// and spawns a lightweight reader thread that loops on CtlReply frames.
bridge_pty_stream_worker_start :: proc(session_id, shell_id: string, conn: ^ws.Connection) -> bool {
	sid := strings.trim_space(session_id)
	sh_id := strings.trim_space(shell_id)
	if sid == "" do return false
	if sh_id == "" do sh_id = sid

	sync.mutex_lock(&bridge_pty_stream_map.mu)
	if bridge_pty_stream_map.workers == nil {
		bridge_pty_stream_map.workers = make(map[string]^Bridge_PTY_Stream_Worker, allocator = runtime.heap_allocator())
	}
	if existing, ok := bridge_pty_stream_map.workers[sid]; ok {
		if sync.atomic_load(&existing.active) {
			existing.conn = conn
			sync.mutex_unlock(&bridge_pty_stream_map.mu)
			return true
		}
	}
	sync.mutex_unlock(&bridge_pty_stream_map.mu)

	socket, daemon_ok := bridge_pty_host_ensure_daemon()
	if !daemon_ok do return false

	fd, dial_ok := pty_host_dial(socket)
	if !dial_ok do return false

	// Send CtlMsg::Attach on this dedicated socket
	attach_frame := pty_host_encode_attach(sh_id)
	defer delete(attach_frame)
	if !pty_host_send_all(fd, attach_frame) {
		local_socket.close(fd)
		return false
	}

	worker := new(Bridge_PTY_Stream_Worker, runtime.heap_allocator())
	worker.session_id = strings.clone(sid, runtime.heap_allocator())
	worker.shell_id = strings.clone(sh_id, runtime.heap_allocator())
	worker.fd = fd
	worker.active = true
	worker.conn = conn
	// The salt is drawn lazily, per epoch, by _bridge_pty_stream_next_nonce.
	worker.salt_set = false
	worker.seq = 0

	sync.mutex_lock(&bridge_pty_stream_map.mu)
	if _, exists := bridge_pty_stream_map.workers[sid]; exists {
		bridge_pty_stream_map.workers[sid] = worker
	} else {
		bridge_pty_stream_map.workers[strings.clone(sid, runtime.heap_allocator())] = worker
	}
	sync.mutex_unlock(&bridge_pty_stream_map.mu)

	thread.run_with_data(rawptr(worker), bridge_pty_stream_reader_worker)
	return true
}

// bridge_pty_stream_worker_detach detaches the streaming worker for session_id.
// Sends CtlMsg::Detach and shuts down / closes the dedicated socket descriptor.
bridge_pty_stream_worker_detach :: proc(session_id: string) -> bool {
	sid := strings.trim_space(session_id)
	if sid == "" do return false

	sync.mutex_lock(&bridge_pty_stream_map.mu)
	worker: ^Bridge_PTY_Stream_Worker = nil
	key_to_delete := ""
	for k, w in bridge_pty_stream_map.workers {
		if k == sid {
			worker = w
			key_to_delete = k
			delete_key(&bridge_pty_stream_map.workers, k)
			break
		}
	}
	if worker == nil {
		sync.mutex_unlock(&bridge_pty_stream_map.mu)
		return true // already detached
	}
	sync.atomic_store(&worker.active, false)
	// The reader closes under this same map lock. Shutdown here cannot race fd reuse.
	_ = local_socket.shutdown(worker.fd, .Both)
	delete(key_to_delete, runtime.heap_allocator())
	sync.mutex_unlock(&bridge_pty_stream_map.mu)

	return true
}

// bridge_pty_stream_stop_all_for_reconnect detaches EVERY live streaming worker, and is
// the bridge half of REQ-SHELL-40's convergence: no stream worker may outlive the hub
// connection it was created for.
//
// WHY A BLANKET TEARDOWN RATHER THAN A REAPER. A worker holds `conn`, a POINTER to the
// `ws.Connection` that `bridge_hub_runtime_worker` declares as a STACK LOCAL INSIDE its
// reconnect loop (hub_runtime_client.odin). The moment that loop iterates, the pointer is
// dangling — and worse than merely dangling, because the next iteration refills the same
// stack slot with the NEW connection, so an orphaned worker silently begins aliasing a
// socket it was never attached to. Output appearing to survive a WS blip today is that
// accident, not a design. Nothing here can be made safe by reaping later; the pointer has
// to stop existing before the slot is reused, which is what this does.
//
// IT ALSO CLOSES A REAL UNBOUNDED LEAK. Hub->bridge runtime commands are fire-and-forget
// over the live socket (bridge_runtime.send_runtime_command returns .Bridge_Offline and
// DROPS the frame), and the hub replays kill intents on reconnect but not detaches. So a
// viewer that closed its pane while the bridge was away left its `shell_stream_detach`
// discarded and its worker running forever, appending every byte the shell produced to the
// unbounded `bridge_pty_stream_outgoing` queue for a session nobody was watching.
//
// WHAT RE-ESTABLISHES THE STREAM. Nothing here — deliberately. The hub re-issues
// `shell_stream_attach` for every still-viewed live session out of its inventory
// convergence (shell_session_inventory.odin), and the fresh Attach earns a fresh Screen
// catch-up frame from the pty-host, so the pane repaints rather than resuming mid-scroll.
// Losing the bytes produced during the outage is correct: they are off-screen history the
// viewer never saw, and the repaint shows the screen as it actually is now.
//
// CALL IT BEFORE ws.close, NOT AFTER. That ordering is the whole answer to "what happens to
// a worker that is mid-write when the socket closes". ws.close does not take the send mutex
// REQ-SHELL-32 added, so a writer CAN be inside bridge_hub_send when the fd goes away; after
// this returns, no worker is eligible to write at all, so the window shrinks instead of
// growing. A worker already inside a send finishes against a closing fd, gets false back,
// and — because `active` is now false — has its frame DELETED by
// bridge_pty_stream_emit_frame rather than queued, so a wedged writer costs neither a hang
// nor a queue entry.
//
// Detaching is idempotent (bridge_pty_stream_worker_detach returns true for an already
// detached session), so a reconnect storm running this repeatedly is harmless.
bridge_pty_stream_stop_all_for_reconnect :: proc() -> int {
	heap := runtime.heap_allocator()

	// Snapshot the ids under the lock and detach OUTSIDE it: worker_detach takes the
	// same mutex, and it also writes to the pty-host socket, which must never happen
	// with the worker map held.
	sync.mutex_lock(&bridge_pty_stream_map.mu)
	ids := make([dynamic]string, 0, len(bridge_pty_stream_map.workers), heap)
	for k in bridge_pty_stream_map.workers {
		append(&ids, strings.clone(k, heap))
	}
	sync.mutex_unlock(&bridge_pty_stream_map.mu)
	defer {
		for id in ids do delete(id, heap)
		delete(ids)
	}

	for id in ids {
		_ = bridge_pty_stream_worker_detach(id)
	}

	// Frames queued by workers that are now gone can never be delivered to anyone: the
	// sessions they belong to have no attachment until the hub re-attaches, and a
	// re-attach is answered by a fresh Screen frame that supersedes them. Dropping them
	// here is what keeps the queue from carrying a burst of pre-outage bytes that would
	// paint over the catch-up snapshot.
	//
	// THIS IS A DELIBERATE DROP AND IT IS NOT DATA LOSS, which is the only reason it is
	// acceptable — the reason is not self-evident, so it is written down rather than
	// left to a reviewer to reconstruct:
	//   - The bytes are still on disk. The pty-host tees every chunk to the session's
	//     tee file INDEPENDENTLY of subscribers — tools/pty_host/src/daemon.rs
	//     pump_output writes the tee AFTER the subscriber loop and outside it, so a
	//     session with no attached stream still records everything — and the bridge sets
	//     has_tee_path unconditionally for shell spawns (hub_runtime_client.odin:2540).
	//     `shell log` serves that file under REQ-SHELL-8 retention. So this is a
	//     live-view recovery choice, not a loss of output.
	//   - For a `server` kind streaming build output, the catch-up repaint shows the
	//     CURRENT tail, which is what a human watching actually wants — a delayed burst
	//     of pre-outage scrollback arriving after the reconnect is strictly less useful.
	//
	// AND IT IS LOGGED, because this chain has catalogued several defects that survived
	// only because something was dropped without a word. A deliberate drop must be at
	// least as visible as an accidental one.
	sync.mutex_lock(&bridge_pty_stream_outgoing_mu)
	_bridge_pty_stream_outgoing_bind_heap()
	dropped_frames := len(bridge_pty_stream_outgoing)
	dropped_bytes := 0
	for item in bridge_pty_stream_outgoing {
		dropped_bytes += _bridge_pty_stream_outgoing_len(item)
		_bridge_pty_stream_outgoing_free(item, heap)
	}
	clear(&bridge_pty_stream_outgoing)
	bridge_pty_stream_outgoing_bytes = 0
	sync.mutex_unlock(&bridge_pty_stream_outgoing_mu)

	if len(ids) > 0 || dropped_frames > 0 {
		// Session ids in full: a count alone cannot tell an operator WHICH pane went
		// quiet, which is the first question asked when one does.
		joined := strings.join(ids[:], ",", context.temp_allocator)
		fmt.println(
			"bridge pty stream: detached workers for hub reconnect",
			"reason=", "hub_ws_reconnect",
			"workers=", len(ids),
			"sessions=", joined,
			"dropped_frames=", dropped_frames,
			"dropped_bytes=", dropped_bytes,
			"(bytes remain in the session tee file; the hub re-attach earns a fresh screen repaint)",
		)
	}

	return len(ids)
}

// _bridge_pty_stream_lf_to_crlf rewrites bare row separators into CRLF.
// Caller owns the result.
//
// WHY THIS IS NEEDED (REQ-SHELL-31). This is the SECOND staircase producer; REQ-SHELL-30 fixed
// the hub's snapshot builder and the terminal still staircased, because the bridge emits a
// catch-up paint of its own. The pty-host delivers a captured screen as one string PER GRID ROW
// (tools/pty_host/src/vt.rs capture()), and bridge_pty_host_screen_to_output joins those rows
// with a bare LF. A VT drops one row on LF and KEEPS the column, so every row began where the
// previous one ended.
//
// WHY THE RAW-BYTE DISTINCTION IS THE WHOLE POINT. The joiner has four non-test callers and only
// this one is wrong, which is why the join itself must not change. The decisive difference is
// xterm's `convertEol` option (ShellTerminalPane.tsx:229/349, AgentPaneComposerPanel.tsx:263/390):
// it is TRUE on the polled paths, where xterm converts LF->CRLF itself and bare LF is therefore
// correct, and FALSE while streaming. The .Screen frame below travels as `shell_pty_output`
// data_b64 — raw bytes on the streaming path — so it is the one place the conversion must happen
// in Odin. Fixing the shared joiner would instead rewrite the poller's text AND invalidate every
// stored since_hash (bridge_pty_host_pane_hash consumes it on the very next statement of
// bridge_pty_host_evaluate_pane), costing every client a full repaint.
//
// An LF that ALREADY has a CR before it is passed through untouched, so this can never produce
// "\r\r\n" should the pty-host ever start sending CRLF itself.
//
// NOTHING here measures width. vt.rs capture() writes SGR runs INLINE into each row, so a row's
// byte length is not its display width and must never be used as one. The separator is decided
// per LF byte, never per length.
_bridge_pty_stream_lf_to_crlf :: proc(s: string) -> string {
	b := strings.builder_make()
	for i in 0 ..< len(s) {
		c := s[i]
		if c == '\n' && (i == 0 || s[i - 1] != '\r') {
			strings.write_byte(&b, '\r')
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

// _bridge_pty_stream_trim_trailing_blank_rows strips non-informative trailing blank/whitespace
// rows from pane text while preserving trailing spaces on non-blank prompt lines.
// Intermediate blank lines are preserved. Returns an empty string if all lines are blank.
// Caller owns the result.
_bridge_pty_stream_trim_trailing_blank_rows :: proc(s: string, allocator := context.allocator) -> string {
	if len(s) == 0 do return strings.clone("", allocator)

	last_non_blank_end := -1
	line_start := 0
	line_has_content := false

	for i in 0 ..< len(s) {
		c := s[i]
		if c == '\n' {
			if line_has_content {
				end := i
				if end > line_start && s[end - 1] == '\r' do end -= 1
				last_non_blank_end = end
			}
			line_start = i + 1
			line_has_content = false
		} else if c != ' ' && c != '\t' && c != '\r' {
			line_has_content = true
		}
	}

	if line_has_content {
		end := len(s)
		if end > line_start && s[end - 1] == '\r' do end -= 1
		last_non_blank_end = end
	}

	if last_non_blank_end <= 0 do return strings.clone("", allocator)
	return strings.clone(s[:last_non_blank_end], allocator)
}

// bridge_pty_stream_screen_payload builds the byte payload of the bridge's catch-up screen
// frame: the pty-host's colour preamble (if any) first, then the captured rows joined, with
// trailing blank rows trimmed, CRLF row separators, and
// an explicit ANSI cursor positioning sequence (\x1b[<row+1>;<col+1>H) when valid cursor
// coordinates (>= 0) are supplied. Caller owns the result.
//
// This exists as a named seam rather than two statements inlined in the .Screen case so that
// the conversion is covered in the SAME composition the emit site uses. A test that called
// _bridge_pty_stream_lf_to_crlf directly would stay green if someone dropped the call from the
// emit site — it would guard the helper without detecting the regression this task fixes.
//
// REQ-FIX-3: the CUP is the SECOND half of "initial cursor positioning". There are two catch-up
// producers that paint an existing screen, and this is the one that attach uses; the hub's polled
// repaint (_shell_screen_repaint_text in shell_stream_screen_snapshot.odin) already emitted a CUP
// while this one left the cursor wherever the last written byte landed. Trimming trailing blank
// rows moves end-of-text further from the true cursor, so the two had to agree.
//
// The contract is deliberately IDENTICAL to the hub's: coordinates are 0-based, so the sequence
// takes row+1/col+1, and a coordinate below zero means "no cursor data" and suppresses the CUP
// entirely rather than guessing a position. The sentinel exists for callers that have no cursor to
// report, which must not fabricate one; the pty-host stream reply always carries real coordinates
// (see the .Screen case below).
//
// REQ-FIX-9: the cursor parameters are MANDATORY, and that is the whole point. They used to default
// to -1, which made the sentinel reachable by ACCIDENT: dropping the two arguments at the emit site
// below silently reverts REQ-FIX-3 — it compiles, all 17 Odin tests stay green because every one of
// them calls this helper directly, and the bridge quietly goes back to emitting no cursor escape.
// That is the same trap the paragraph above describes for the joiner, one level up. With the
// defaults gone the regression is a compile error instead, so absent-cursor callers must now say
// -1, -1 out loud and a dropped argument cannot be mistaken for one.
bridge_pty_stream_screen_payload :: proc(lines: []string, cursor_row: int, cursor_col: int) -> string {
	joined, _, _ := bridge_pty_host_screen_to_output(lines, 0)
	defer delete(joined)
	// REQ-PTY-COLOR-1: the pty-host leads the capture with the terminal-colour preamble
	// (OSC 10/11/12/4). Split it off FIRST so the alt-screen detection below still sees
	// its prefix, and so a screen whose rows are all blank cannot trim it away.
	preamble, rows := contracts.pty_screen_split_preamble(joined)
	trimmed := _bridge_pty_stream_trim_trailing_blank_rows(rows)
	defer delete(trimmed)
	body := _bridge_pty_stream_lf_to_crlf(trimmed)
	defer delete(body)

	alt_prefix := ""
	rest_body := body
	if strings.has_prefix(body, "\x1b[?1049h\x1b[?25l") {
		alt_prefix = "\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H"
		rest_body = body[len("\x1b[?1049h\x1b[?25l"):]
	} else if strings.has_prefix(body, "\x1b[?1049h") {
		alt_prefix = "\x1b[?1049h\x1b[2J\x1b[H"
		rest_body = body[len("\x1b[?1049h"):]
	}

	cup := ""
	if cursor_row >= 0 && cursor_col >= 0 {
		// tprintf lands in the temp allocator; concatenate copies it out, so the CUP is never freed here.
		cup = fmt.tprintf("\x1b[%d;%dH", cursor_row + 1, cursor_col + 1)
	}
	if alt_prefix != "" {
		return strings.concatenate({preamble, alt_prefix, rest_body, cup})
	}
	return strings.concatenate({preamble, body, cup})
}

// bridge_pty_stream_reader_worker runs on a dedicated background thread per active stream.
// It loops reading CtlReply frames from the dedicated UNIX socket and emits shell_pty_output.
bridge_pty_stream_reader_worker :: proc(data: rawptr) {
	worker := (^Bridge_PTY_Stream_Worker)(data)
	heap := runtime.heap_allocator()

	// Capture stack copies so we never dereference worker if deregistered concurrently
	local_fd := worker.fd
	local_session_id := strings.clone(worker.session_id, heap)
	defer delete(local_session_id, heap)
	local_shell_id := strings.clone(worker.shell_id, heap)
	defer delete(local_shell_id, heap)

	saw_stream_closed := false

	for {
		payload, pok := pty_host_read_frame(local_fd)
		if !pok do break

		reply, dok := pty_host_decode_reply(payload)
		delete(payload)
		if !dok do continue

		#partial switch reply.kind {
		case .Output:
			bridge_pty_stream_emit_frame(worker, local_session_id, reply.data)
		case .Screen:
			// Initial catchup snapshot delivered immediately upon Attach.
			// REQ-SHELL-31: the joiner separates rows with a bare LF, which is correct for the
			// polled panes (xterm's convertEol is on there) but not here — this frame reaches the
			// terminal as raw bytes, where a bare LF keeps the column and staircases the paint.
			// Converted at the emit site, never in the shared joiner: see the note above.
			// REQ-FIX-3: cursor_row/cursor_col are u16 off the wire and 0-based, and
			// pty_host_get_screen fails the whole decode unless all four screen coordinates
			// parsed (a failed decode `continue`s above), so the data here is always real —
			// this call never reaches the payload builder's absent-cursor sentinel.
			content := bridge_pty_stream_screen_payload(
				reply.screen.lines,
				int(reply.screen.cursor_row),
				int(reply.screen.cursor_col),
			)
			if len(content) > 0 {
				worker.emitting_snapshot = true
				if len(content) <= 1024 * 1024 { bridge_pty_stream_emit_frame(worker, local_session_id, transmute([]byte)content) } else { bridge_pty_stream_emit_lifecycle_event(worker, "pane_resync_required", local_session_id, local_shell_id) }
				worker.emitting_snapshot = false
			}
			delete(content)
		case .Stream_Ready:
			bridge_pty_stream_emit_lifecycle_event(worker, "shell_pty_stream_ready", local_session_id, local_shell_id)
		case .Stream_Closed:
			saw_stream_closed = true
			bridge_pty_stream_emit_lifecycle_event(worker, "shell_pty_stream_closed", local_session_id, local_shell_id, reply.has_code, reply.code)
		case .Error:
			fmt.println("bridge pty stream error:", reply.message)
		}
		pty_host_reply_delete(reply)
	}

	if !saw_stream_closed && sync.atomic_load(&worker.active) {
		bridge_pty_stream_emit_lifecycle_event(worker, "pane_resync_required", local_session_id, local_shell_id, false, 0)
	}

	// Teardown: send CtlMsg::Detach and close dedicated socket descriptor
	detach_frame := pty_host_encode_detach(local_shell_id)
	_ = pty_host_send_all(local_fd, detach_frame)
	delete(detach_frame)

	// Deregister worker from map if still present
	sync.mutex_lock(&bridge_pty_stream_map.mu)
	for k, w in bridge_pty_stream_map.workers {
		if w == worker {
			delete_key(&bridge_pty_stream_map.workers, k)
			delete(k, heap)
			break
		}
	}
	local_socket.close(local_fd)
	sync.mutex_unlock(&bridge_pty_stream_map.mu)

	delete(worker.session_id, heap)
	delete(worker.shell_id, heap)
	free(worker, heap)
}

// bridge_pty_stream_seal_v2 seals PTY output as a PTY v2 payload
// (u32be epoch | salt16 | nonce | tag | ct, AAD heimdall-pty-v2|e<epoch>|<session_id>|out)
// under the (salt, session, out) subkey with nonce = u32be(0) || u64be(seq). Caller owns
// the result.
bridge_pty_stream_seal_v2 :: proc(data: []byte, kr: ^vault.Vault_Keyring, epoch: u32, salt: Bridge_PTY_Salt, seq: u64, session_id: string, allocator := context.allocator) -> (sealed: []byte, ok: bool) {
	key, key_ok := vault.keyring_key_for_epoch(kr, epoch)
	if !key_ok do return nil, false
	salt_copy := salt
	return vault.pty_seal(data, key, epoch, salt_copy[:], seq, session_id, .Out, "", allocator)
}

BRIDGE_PANE_QUEUE_BYTES :: 8 * 1024 * 1024
BRIDGE_PANE_QUEUE_FRAMES :: 1024
bridge_pty_stream_outgoing_bytes: int
bridge_pty_stream_reconnect_required: bool

// _bridge_pty_stream_queue_control enqueues a pre-formatted control/lifecycle frame.
_bridge_pty_stream_queue_control :: proc(worker: ^Bridge_PTY_Stream_Worker, json: string, heap: runtime.Allocator, session_id: string) {
	_bridge_pty_stream_deliver_or_queue(worker, Bridge_PTY_Stream_Outgoing{json = json}, heap, session_id)
}

// _bridge_pty_stream_queue_output enqueues one PLAINTEXT output record. `data` is owned by
// the queue from here on (heap-allocated by the caller).
_bridge_pty_stream_queue_output :: proc(worker: ^Bridge_PTY_Stream_Worker, data: []byte, heap: runtime.Allocator, session_id: string, encrypted: bool, salt: Bridge_PTY_Salt, seq: u64, epoch: u32 = 0) {
	_bridge_pty_stream_deliver_or_queue(worker, Bridge_PTY_Stream_Outgoing{data = data, encrypted = encrypted, epoch = epoch, salt = salt, seq = seq}, heap, session_id)
}

// Overflow handling (REQ-PTY-NET-5). When a session's INCREMENTAL output outruns the hub
// link, the queue used to drop everything for that session, kill the worker and ask every
// viewer to reconnect — which cost a double repaint and, on a slow link under `cat bigfile`,
// repeated itself as a resync storm. Now the per-session queue is COMPACTED instead: the
// oldest incremental records are dropped until the newest
// BRIDGE_PTY_STREAM_COMPACT_KEEP_BYTES remain, a clear-screen+home record is placed in
// front of the kept tail so the viewer sees "skipped ahead" rather than a torn join, and
// the worker keeps streaming. The bytes are still in the pty-host tee file (see
// bridge_pty_stream_stop_all_for_reconnect for why that makes a drop acceptable).
//
// Compaction is NOT applied to a snapshot overflow (a partial screen repaint is worse than
// a fresh one) or to a GLOBAL queue overflow (this session's share is not the problem), and
// it escalates to the old resync when it happens BRIDGE_PTY_STREAM_COMPACT_STORM_LIMIT
// times within BRIDGE_PTY_STREAM_COMPACT_STORM_WINDOW — a link that slow needs the viewer
// gone, not a smaller queue.
BRIDGE_PTY_STREAM_COMPACT_KEEP_BYTES   :: 64 * 1024
BRIDGE_PTY_STREAM_COMPACT_STORM_LIMIT  :: 3
BRIDGE_PTY_STREAM_COMPACT_STORM_WINDOW :: 10 * time.Second
BRIDGE_PTY_STREAM_COMPACT_MARKER       :: "\x1b[2J\x1b[H"

@(private = "file")
Bridge_PTY_Compaction_Record :: struct {
	session_id: string, // heap
	ticks:      [BRIDGE_PTY_STREAM_COMPACT_STORM_LIMIT]time.Tick,
	count:      int,
}

@(private = "file")
bridge_pty_stream_compactions: [dynamic]Bridge_PTY_Compaction_Record

// _bridge_pty_stream_note_compaction_locked records one compaction for the session and
// returns how many happened inside the storm window (including this one). Caller holds
// bridge_pty_stream_outgoing_mu.
_bridge_pty_stream_note_compaction_locked :: proc(session_id: string, now: time.Tick) -> int {
	if bridge_pty_stream_compactions.allocator.procedure == nil do bridge_pty_stream_compactions.allocator = runtime.heap_allocator()
	idx := -1
	for r, i in bridge_pty_stream_compactions do if r.session_id == session_id { idx = i; break }
	if idx < 0 {
		append(&bridge_pty_stream_compactions, Bridge_PTY_Compaction_Record{session_id = strings.clone(session_id, runtime.heap_allocator())})
		idx = len(bridge_pty_stream_compactions) - 1
	}
	r := &bridge_pty_stream_compactions[idx]
	// Keep only ticks inside the window, then add this one.
	kept := 0
	for i in 0 ..< r.count {
		if time.tick_diff(r.ticks[i], now) < BRIDGE_PTY_STREAM_COMPACT_STORM_WINDOW {
			r.ticks[kept] = r.ticks[i]
			kept += 1
		}
	}
	if kept < len(r.ticks) {
		r.ticks[kept] = now
		kept += 1
	}
	r.count = kept
	return kept
}

@(private = "file")
_bridge_pty_stream_forget_compactions_locked :: proc(session_id: string) {
	for r, i in bridge_pty_stream_compactions {
		if r.session_id == session_id {
			delete(r.session_id, runtime.heap_allocator())
			unordered_remove(&bridge_pty_stream_compactions, i)
			return
		}
	}
}

// _bridge_pty_stream_compact_session_locked drops the oldest incremental records of
// `session_id` until at most keep_bytes of plaintext remain, and inserts the clear-screen
// marker in front of what is kept. Returns the bytes released. Caller holds the lock.
_bridge_pty_stream_compact_session_locked :: proc(session_id: string, keep_bytes: int, encrypted: bool, epoch: u32, salt: Bridge_PTY_Salt, seq: u64, heap: runtime.Allocator) -> (released: int) {
	// Walk from the tail: everything past the budget (towards the head) goes.
	kept := 0
	cut := -1 // index of the oldest record that is kept
	for i := len(bridge_pty_stream_outgoing) - 1; i >= 0; i -= 1 {
		q := bridge_pty_stream_outgoing[i]
		if q.session_id != session_id || q.data == nil || q.snapshot do continue
		if kept + len(q.data) > keep_bytes do break
		kept += len(q.data)
		cut = i
	}
	i := 0
	first_kept := -1
	for i < len(bridge_pty_stream_outgoing) {
		q := bridge_pty_stream_outgoing[i]
		if q.session_id != session_id || q.data == nil || q.snapshot { i += 1; continue }
		if cut >= 0 && i >= cut {
			if first_kept < 0 do first_kept = i
			i += 1
			continue
		}
		released += len(q.data)
		bridge_pty_stream_outgoing_bytes -= len(q.data)
		_bridge_pty_stream_outgoing_free(q, heap)
		ordered_remove(&bridge_pty_stream_outgoing, i)
		if cut > i do cut -= 1
	}
	marker := Bridge_PTY_Stream_Outgoing{
		data       = slice.clone(transmute([]byte)string(BRIDGE_PTY_STREAM_COMPACT_MARKER), heap),
		session_id = strings.clone(session_id, heap),
		encrypted  = encrypted,
		epoch      = epoch,
		salt       = salt,
		seq        = seq,
	}
	if first_kept >= 0 {
		inject_at(&bridge_pty_stream_outgoing, first_kept, marker)
	} else {
		append(&bridge_pty_stream_outgoing, marker)
	}
	bridge_pty_stream_outgoing_bytes += len(marker.data)
	return released
}

// _bridge_pty_stream_deliver_or_queue appends `item` (whose json/data the queue takes over)
// for `session_id`, enforcing the per-session and global bounds. `item.session_id` and
// `item.snapshot` are filled in here.
_bridge_pty_stream_deliver_or_queue :: proc(worker: ^Bridge_PTY_Stream_Worker, item_in: Bridge_PTY_Stream_Outgoing, heap: runtime.Allocator, session_id: string) {
	item := item_in
	frame_len := _bridge_pty_stream_outgoing_len(item)
	if worker != nil && !sync.atomic_load(&worker.active) { _bridge_pty_stream_outgoing_free(item, heap); return }
	sync.mutex_lock(&bridge_pty_stream_outgoing_mu)
	_bridge_pty_stream_outgoing_bind_heap()
	if worker != nil && !sync.atomic_load(&worker.active) { sync.mutex_unlock(&bridge_pty_stream_outgoing_mu); _bridge_pty_stream_outgoing_free(item, heap); return }
	snapshot := worker != nil && worker.emitting_snapshot
	stream_bytes := 0
	for q in bridge_pty_stream_outgoing { if q.session_id == session_id && q.snapshot == snapshot do stream_bytes += _bridge_pty_stream_outgoing_len(q) }
	stream_limit := 2 * 1024 * 1024 if snapshot else 256 * 1024
	session_over := frame_len > stream_limit - stream_bytes
	global_over := frame_len > BRIDGE_PANE_QUEUE_BYTES - bridge_pty_stream_outgoing_bytes || len(bridge_pty_stream_outgoing) >= BRIDGE_PANE_QUEUE_FRAMES
	overflow := session_over || global_over
	if session_over && !global_over && !snapshot && item.data != nil {
		// REQ-PTY-NET-5: compact instead of dropping the session, unless it is storming.
		now := time.tick_now()
		if _bridge_pty_stream_note_compaction_locked(session_id, now) < BRIDGE_PTY_STREAM_COMPACT_STORM_LIMIT {
			marker_salt: Bridge_PTY_Salt
			marker_seq: u64
			marker_epoch: u32
			if item.encrypted {
				// A marker whose nonce cannot be reserved keeps epoch 0, which the drain
				// refuses to seal (it becomes a pane_resync_required, never plaintext).
				if salt, seq, nonce_ok := _bridge_pty_stream_next_nonce(worker, item.epoch); nonce_ok {
					marker_salt, marker_seq, marker_epoch = salt, seq, item.epoch
				}
			}
			released := _bridge_pty_stream_compact_session_locked(session_id, BRIDGE_PTY_STREAM_COMPACT_KEEP_BYTES, item.encrypted, marker_epoch, marker_salt, marker_seq, heap)
			fmt.eprintln("bridge WARN pane queue compacted; skipped ahead", "session=", session_id, "released_bytes=", released, "kept_bytes<=", BRIDGE_PTY_STREAM_COMPACT_KEEP_BYTES)
			overflow = false
		} else {
			_bridge_pty_stream_forget_compactions_locked(session_id)
		}
	}
	if !overflow {
		item.session_id = strings.clone(session_id, heap)
		item.snapshot = snapshot
		append(&bridge_pty_stream_outgoing, item)
		bridge_pty_stream_outgoing_bytes += frame_len
	}
	if overflow {
		// Obsolete bytes for this stream cannot be replayed after a gap. Release them
		// and reserve one small control record so only this pane reconnects.
		i := 0
		for i < len(bridge_pty_stream_outgoing) {
			q := bridge_pty_stream_outgoing[i]
			if q.session_id != session_id { i += 1; continue }
			bridge_pty_stream_outgoing_bytes -= _bridge_pty_stream_outgoing_len(q)
			_bridge_pty_stream_outgoing_free(q, heap)
			ordered_remove(&bridge_pty_stream_outgoing, i)
		}
		marker := bridge_pty_stream_format_lifecycle_event("pane_resync_required", session_id, "", false, 0, heap)
		if len(bridge_pty_stream_outgoing) < BRIDGE_PANE_QUEUE_FRAMES {
			// Control reserve: at most 1024 small markers in addition to 8 MiB of data.
			append(&bridge_pty_stream_outgoing, Bridge_PTY_Stream_Outgoing{json = marker, session_id = strings.clone(session_id, heap)})
			bridge_pty_stream_outgoing_bytes += len(marker)
		} else { delete(marker, heap); sync.atomic_store(&bridge_pty_stream_reconnect_required, true) }
	}
	sync.mutex_unlock(&bridge_pty_stream_outgoing_mu)
	if overflow {
		_bridge_pty_stream_outgoing_free(Bridge_PTY_Stream_Outgoing{json = item.json, data = item.data}, heap)
		fmt.eprintln("bridge WARN pane queue overflow; detaching stream for a fresh screen")
		if worker != nil {
			sync.atomic_store(&worker.active, false)
			if local_socket.valid(worker.fd) && worker.fd != 0 do _ = local_socket.shutdown(worker.fd, .Both)
		}
	}
}

// _bridge_pty_stream_next_nonce reserves the next (salt, seq) pair for a record sealed
// under epoch: the worker's counter when there is one, else a process-wide fallback
// counter. A fresh CSPRNG salt is drawn whenever the stream has none yet, the epoch
// changed, or a keyring was installed since; seq restarts only under a new salt.
// ok=false (randomness failure) means the record must not be sealed at all.
_bridge_pty_stream_next_nonce :: proc(worker: ^Bridge_PTY_Stream_Worker, epoch: u32) -> (salt: Bridge_PTY_Salt, seq: u64, ok: bool) {
	generation := sync.atomic_load(&bridge_pty_salt_generation)
	if worker != nil {
		if !worker.salt_set || worker.salt_epoch != epoch || worker.salt_generation != generation {
			if !os_random.fill(worker.salt[:], bridge_pty_random_source) {
				worker.salt_set = false
				return {}, 0, false
			}
			worker.salt_set = true
			worker.salt_epoch = epoch
			worker.salt_generation = generation
			worker.seq = 0
		}
		worker.seq += 1
		return worker.salt, worker.seq, true
	}
	sync.mutex_lock(&bridge_pty_stream_fallback_mu)
	defer sync.mutex_unlock(&bridge_pty_stream_fallback_mu)
	if !bridge_pty_stream_fallback_inited || bridge_pty_stream_fallback_epoch != epoch || bridge_pty_stream_fallback_generation != generation {
		if !os_random.fill(bridge_pty_stream_fallback_salt[:], bridge_pty_random_source) {
			bridge_pty_stream_fallback_inited = false
			return {}, 0, false
		}
		bridge_pty_stream_fallback_inited = true
		bridge_pty_stream_fallback_epoch = epoch
		bridge_pty_stream_fallback_generation = generation
		bridge_pty_stream_fallback_seq = 0
	}
	bridge_pty_stream_fallback_seq += 1
	return bridge_pty_stream_fallback_salt, bridge_pty_stream_fallback_seq, true
}

// bridge_pty_stream_emit_frame queues a PTY output chunk for `session_id`.
// When vault status is Locked, it queues a locked warning banner plus a typed shell_pty_vault_locked
// frame (once per lock) and suppresses raw stream bytes.
// When Unlocked, it reserves a monotonic (salt, seq) nonce and marks the record for AES-256-GCM
// encryption AT DRAIN TIME — after coalescing — see Bridge_PTY_Stream_Outgoing.
// Without a key it queues the locked banner and a typed vault_locked frame; output
// never leaves in plaintext.
bridge_pty_stream_emit_frame :: proc(worker: ^Bridge_PTY_Stream_Worker, session_id: string, data: []byte) {
	if len(data) == 0 do return
	snapshot := worker != nil && worker.emitting_snapshot
	cap_incr, cap_snap := bridge_pty_stream_emit_caps()
	limit := cap_snap if snapshot else cap_incr
	if len(data) > limit {
		for offset := 0; offset < len(data); offset += limit { bridge_pty_stream_emit_frame(worker, session_id, data[offset:min(offset+limit, len(data))]) }
		return
	}
	heap := runtime.heap_allocator()

	status, kr := bridge_vault_status_and_key()
	epoch := kr.current_epoch
	vault.keyring_wipe(&kr)
	switch status {
	case .Not_Enrolled, .Locked:
		if worker != nil {
			if worker.locked_banner_emitted do return
			worker.locked_banner_emitted = true
		}
		banner := "\r\n\x1b[33m[Vault locked: terminal stream is suspended. Unlock bridge vault to continue.]\x1b[0m\r\n"
		_bridge_pty_stream_queue_output(worker, slice.clone(transmute([]byte)banner, heap), heap, session_id, false, {}, 0)
		// T10 (REQ-T10-3): the banner is for scrollback; this typed frame is what the
		// hub relays as a `vault_locked` error so the pane can switch to its overlay.
		_bridge_pty_stream_queue_control(worker, bridge_pty_vault_locked_frame_json(session_id, heap), heap, session_id)
		return

	case .Unlocked:
		if worker != nil {
			worker.locked_banner_emitted = false
		}
		salt, seq, nonce_ok := _bridge_pty_stream_next_nonce(worker, epoch)
		if !nonce_ok {
			// No randomness, no nonce: never seal, never fall back to plaintext.
			fmt.eprintln("bridge WARN OS random source failed; terminal output withheld")
			_bridge_pty_stream_queue_control(worker, bridge_pty_stream_format_lifecycle_event("pane_resync_required", session_id, "", false, 0, heap), heap, session_id)
			return
		}
		_bridge_pty_stream_queue_output(worker, slice.clone(data, heap), heap, session_id, true, salt, seq, epoch)
		return
	}
}

// bridge_pty_stream_format_lifecycle_event formats shell_pty_stream_ready or shell_pty_stream_closed JSON.
bridge_pty_stream_format_lifecycle_event :: proc(
	event_type: string,
	session_id: string,
	shell_id: string,
	has_exit_code := false,
	exit_code: i32 = 0,
	allocator := context.allocator,
	boot_id := "",
) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"type\":\"")
	bridge_runtime_write_json_string(&b, event_type)
	strings.write_string(&b, "\",\"session_id\":\"")
	bridge_runtime_write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"shell_id\":\"")
	bridge_runtime_write_json_string(&b, shell_id)
	strings.write_string(&b, "\"")
	if boot_id != "" {
		// PTY v2 input frames bind this bridge process's unseal boot_id in their AAD;
		// the viewer learns it here, on every (re)attach.
		strings.write_string(&b, ",\"bridge_boot_id\":\"")
		bridge_runtime_write_json_string(&b, boot_id)
		strings.write_string(&b, "\"")
	}
	if has_exit_code {
		fmt.sbprintf(&b, ",\"exit_code\":%d", exit_code)
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// bridge_pty_stream_emit_lifecycle_event formats and emits shell_pty_stream_ready or shell_pty_stream_closed JSON to Hub (REQ-STREAM-EVENT-2).
bridge_pty_stream_emit_lifecycle_event :: proc(
	worker: ^Bridge_PTY_Stream_Worker,
	event_type: string,
	session_id: string,
	shell_id: string,
	has_exit_code := false,
	exit_code: i32 = 0,
) {
	heap := runtime.heap_allocator()
	boot_id := bridge_unseal_boot_id() if event_type == "shell_pty_stream_ready" else ""
	frame := bridge_pty_stream_format_lifecycle_event(event_type, session_id, shell_id, has_exit_code, exit_code, heap, boot_id)
	_bridge_pty_stream_queue_control(worker, frame, heap, session_id)
}

// _bridge_pty_stream_can_merge says whether `next` may be folded into the frame being
// built from `head`: same session, same snapshot/encryption class, same nonce salt, both
// output records (a control frame between them is a boundary), and within the cap.
_bridge_pty_stream_can_merge :: proc(head, next: Bridge_PTY_Stream_Outgoing, merged_len, limit: int) -> bool {
	if next.data == nil || len(next.json) > 0 do return false
	if next.session_id != head.session_id do return false
	if next.snapshot != head.snapshot || next.encrypted != head.encrypted do return false
	if next.salt != head.salt || next.epoch != head.epoch do return false
	return merged_len + len(next.data) <= limit
}

// _bridge_pty_stream_pop_wire_frame removes the head of the queue and returns ONE wire
// frame for it (`binary` says whether it is a pty_wire session frame or a JSON control
// frame). For an output record it first folds in every immediately following
// record that _bridge_pty_stream_can_merge allows (when `coalesce`), then encodes:
// encryption happens HERE, once per merged frame. Returns ok=false when the queue is
// empty. `session_id`/`payload_len` describe the frame for logging/accounting.
//
// A record marked encrypted whose key is no longer readable (vault locked between
// enqueue and drain) is replaced by a pane_resync_required for its session — plaintext
// is never sent in its place.
_bridge_pty_stream_pop_wire_frame :: proc(heap: runtime.Allocator, coalesce := true) -> (frame: string, binary: bool, payload_len: int, ok: bool) {
	sync.mutex_lock(&bridge_pty_stream_outgoing_mu)
	_bridge_pty_stream_outgoing_bind_heap()
	if len(bridge_pty_stream_outgoing) == 0 { sync.mutex_unlock(&bridge_pty_stream_outgoing_mu); return "", false, 0, false }
	head := bridge_pty_stream_outgoing[0]
	ordered_remove(&bridge_pty_stream_outgoing, 0)
	bridge_pty_stream_outgoing_bytes -= _bridge_pty_stream_outgoing_len(head)
	if head.data == nil {
		sync.mutex_unlock(&bridge_pty_stream_outgoing_mu)
		delete(head.session_id, heap)
		return head.json, false, len(head.json), true
	}
	cap_incr, cap_snap := bridge_pty_stream_emit_caps()
	limit := cap_snap if head.snapshot else cap_incr
	merged := head.data
	buf: []byte // only allocated when a second record is folded in
	if coalesce {
		for len(bridge_pty_stream_outgoing) > 0 && _bridge_pty_stream_can_merge(head, bridge_pty_stream_outgoing[0], len(merged), limit) {
			next := bridge_pty_stream_outgoing[0]
			ordered_remove(&bridge_pty_stream_outgoing, 0)
			bridge_pty_stream_outgoing_bytes -= len(next.data)
			if buf == nil {
				buf = make([]byte, limit, heap)
				copy(buf, merged)
			}
			copy(buf[len(merged):], next.data)
			merged = buf[:len(merged) + len(next.data)]
			delete(next.data, heap)
			delete(next.session_id, heap)
		}
	}
	sync.mutex_unlock(&bridge_pty_stream_outgoing_mu)
	defer if buf != nil do delete(buf, heap)
	defer delete(head.data, heap)
	defer delete(head.session_id, heap)

	payload_len = len(merged)
	wire, enc_ok := bridge_pty_stream_encode_output_frame(head.session_id, merged, head.snapshot, head.encrypted, head.epoch, head.salt, head.seq, heap)
	if !enc_ok {
		fmt.eprintln("bridge WARN terminal encryption failed; refusing plaintext output")
		return bridge_pty_stream_format_lifecycle_event("pane_resync_required", head.session_id, "", false, 0, heap), false, payload_len, true
	}
	return string(wire), true, payload_len, true
}

// bridge_pty_stream_encode_output_frame turns one (merged) plaintext payload into the
// binary pty_wire session frame (REQ-PTY-NET-2), encrypting it when `encrypted`
// (payload = PTY v2: u32be epoch | salt16 | nonce | tag | ct). Caller owns the result.
bridge_pty_stream_encode_output_frame :: proc(session_id: string, data: []byte, snapshot, encrypted: bool, epoch: u32, salt: Bridge_PTY_Salt, seq: u64, heap: runtime.Allocator) -> (frame: []byte, ok: bool) {
	temp := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp)
	payload := data
	if encrypted {
		if epoch == 0 do return nil, false
		status, kr := bridge_vault_status_and_key()
		defer vault.keyring_wipe(&kr)
		if status != .Unlocked do return nil, false
		sealed, enc_ok := bridge_pty_stream_seal_v2(data, &kr, epoch, salt, seq, session_id, context.temp_allocator)
		if !enc_ok do return nil, false
		payload = sealed
	}
	frame = contracts.pty_wire_encode_session_frame(contracts.PTY_WIRE_KIND_OUTPUT, contracts.pty_wire_flags(snapshot, encrypted), session_id, payload, heap)
	return frame, frame != nil
}

// bridge_pty_stream_drain_outgoing flushes queued records to the hub connection, merging
// adjacent same-session output as it goes, up to BRIDGE_PTY_STREAM_DRAIN_BUDGET_BYTES of
// plaintext per call. Returns whether records remain so the caller can shorten its sleep.
bridge_pty_stream_drain_outgoing :: proc(conn: ^ws.Connection) -> (more: bool) {
	if sync.atomic_exchange(&bridge_pty_stream_reconnect_required, false) { ws.abort(conn); return false }
	heap := runtime.heap_allocator()
	sent := 0
	for sent < BRIDGE_PTY_STREAM_DRAIN_BUDGET_BYTES {
		frame, binary, payload_len, ok := _bridge_pty_stream_pop_wire_frame(heap)
		if !ok do break
		sent += max(payload_len, 1)
		delivered := bridge_hub_send_binary(conn, transmute([]byte)frame) if binary else bridge_hub_send(conn, frame)
		delete(frame, heap)
		if !delivered do break
	}
	sync.mutex_lock(&bridge_pty_stream_outgoing_mu)
	more = len(bridge_pty_stream_outgoing) > 0
	sync.mutex_unlock(&bridge_pty_stream_outgoing_mu)
	return more
}

// bridge_pty_stream_take_outgoing drains all queued records into wire frames without
// sending (for tests). `coalesce=false` yields one frame per record.
bridge_pty_stream_take_outgoing :: proc(coalesce := true) -> [dynamic]string {
	heap := runtime.heap_allocator()
	out := make([dynamic]string, heap)
	for {
		frame, _, _, ok := _bridge_pty_stream_pop_wire_frame(heap, coalesce)
		if !ok do break
		append(&out, frame)
	}
	return out
}

// bridge_pty_stream_queued_frames reports how many records are queued (for tests).
bridge_pty_stream_queued_frames :: proc() -> int {
	sync.mutex_lock(&bridge_pty_stream_outgoing_mu)
	defer sync.mutex_unlock(&bridge_pty_stream_outgoing_mu)
	return len(bridge_pty_stream_outgoing)
}

// bridge_pty_stream_worker_is_active checks if a worker is running for session_id.
bridge_pty_stream_worker_is_active :: proc(session_id: string) -> bool {
	sync.mutex_lock(&bridge_pty_stream_map.mu)
	defer sync.mutex_unlock(&bridge_pty_stream_map.mu)
	if worker, ok := bridge_pty_stream_map.workers[session_id]; ok {
		return sync.atomic_load(&worker.active)
	}
	return false
}

// bridge_pty_stream_worker_get_active_conn checks if an active streaming worker exists for session_id and retrieves its connection.
bridge_pty_stream_worker_get_active_conn :: proc(session_id: string) -> (conn: ^ws.Connection, active: bool) {
	sid := strings.trim_space(session_id)
	if sid == "" do return nil, false

	sync.mutex_lock(&bridge_pty_stream_map.mu)
	defer sync.mutex_unlock(&bridge_pty_stream_map.mu)

	if bridge_pty_stream_map.workers == nil do return nil, false
	if worker, ok := bridge_pty_stream_map.workers[sid]; ok {
		if worker != nil && sync.atomic_load(&worker.active) {
			return worker.conn, true
		}
	}
	return nil, false
}

// bridge_pty_stream_reset clears all streaming workers and outgoing queue (for tests).
bridge_pty_stream_reset :: proc() {
	bridge_pty_input_replay_reset()
	sync.mutex_lock(&bridge_pty_stream_map.mu)
	heap := runtime.heap_allocator()
	for k, w in bridge_pty_stream_map.workers {
		w.active = false
		_ = local_socket.shutdown(w.fd, .Both)
		local_socket.close(w.fd)
		delete(w.session_id, heap)
		delete(w.shell_id, heap)
		free(w, heap)
		delete(k, heap)
	}
	clear(&bridge_pty_stream_map.workers)
	sync.mutex_unlock(&bridge_pty_stream_map.mu)

	sync.mutex_lock(&bridge_pty_stream_outgoing_mu)
	_bridge_pty_stream_outgoing_bind_heap()
	for item in bridge_pty_stream_outgoing {
		_bridge_pty_stream_outgoing_free(item, heap)
	}
	clear(&bridge_pty_stream_outgoing)
	bridge_pty_stream_outgoing_bytes = 0
	sync.mutex_unlock(&bridge_pty_stream_outgoing_mu)

	sync.mutex_lock(&bridge_pty_stream_fallback_mu)
	bridge_pty_stream_fallback_seq = 0
	bridge_pty_stream_fallback_inited = false
	sync.mutex_unlock(&bridge_pty_stream_fallback_mu)

	sync.mutex_lock(&bridge_pty_stream_outgoing_mu)
	for r in bridge_pty_stream_compactions do delete(r.session_id, heap)
	clear(&bridge_pty_stream_compactions)
	sync.mutex_unlock(&bridge_pty_stream_outgoing_mu)
}

// ── PTY input replay defence (passwordless-vault.md §1, finding M1) ─────────
// Every PTY v2 `in` frame binds its counter in the AAD. After a frame authenticates,
// the bridge accepts it only if its counter strictly increases for its (session, salt)
// stream (see vault.pty_replay_accept); a new salt is a new browser stream and a new
// subkey, the only way the per-stream state starts over. The table is bounded: when a
// session's state is evicted its highest counter becomes a global floor every fresh
// session state starts from, so evicting can never re-open a replay window.

BRIDGE_PTY_INPUT_REPLAY_MAX_SESSIONS :: 1024

bridge_pty_input_replay_mu: sync.Mutex
bridge_pty_input_replay: map[string]vault.Pty_Input_Replay
bridge_pty_input_replay_global_floor: u64

@(private = "file")
_bridge_pty_input_replay_high_water :: proc(r: vault.Pty_Input_Replay) -> u64 {
	high := r.floor
	for e in r.entries do if e.used do high = max(high, e.last)
	return high
}

bridge_pty_input_replay_accept :: proc(session_id: string, salt: [vault.PTY_V2_SALT_BYTES]byte, counter: u64) -> bool {
	if session_id == "" || counter == 0 do return false
	heap := runtime.heap_allocator()
	sync.mutex_lock(&bridge_pty_input_replay_mu)
	defer sync.mutex_unlock(&bridge_pty_input_replay_mu)
	if bridge_pty_input_replay == nil do bridge_pty_input_replay = make(map[string]vault.Pty_Input_Replay, allocator = heap)
	state, found := bridge_pty_input_replay[session_id]
	if !found {
		if len(bridge_pty_input_replay) >= BRIDGE_PTY_INPUT_REPLAY_MAX_SESSIONS {
			victim := ""
			for k, v in bridge_pty_input_replay {
				victim = k
				bridge_pty_input_replay_global_floor = max(bridge_pty_input_replay_global_floor, _bridge_pty_input_replay_high_water(v))
				break
			}
			if victim != "" {
				delete_key(&bridge_pty_input_replay, victim)
				delete(victim, heap)
			}
		}
		state = vault.Pty_Input_Replay{floor = bridge_pty_input_replay_global_floor}
	}
	if !vault.pty_replay_accept(&state, salt, counter) do return false
	if found {
		bridge_pty_input_replay[session_id] = state
	} else {
		bridge_pty_input_replay[strings.clone(session_id, heap)] = state
	}
	return true
}

// bridge_pty_input_replay_reset forgets every session's replay state and the global
// floor. Test isolation only (bridge_pty_stream_reset); production never forgets.
bridge_pty_input_replay_reset :: proc() {
	heap := runtime.heap_allocator()
	sync.mutex_lock(&bridge_pty_input_replay_mu)
	defer sync.mutex_unlock(&bridge_pty_input_replay_mu)
	for k in bridge_pty_input_replay do delete(k, heap)
	clear(&bridge_pty_input_replay)
	bridge_pty_input_replay_global_floor = 0
}

// bridge_pty_open_input authenticates one browser input frame for session_id under the
// keyring's CURRENT epoch (the command epoch floor) and this bridge process's unseal
// boot_id (bound in the AAD: a frame captured before a restart, when the replay state
// was lost, no longer authenticates), then enforces the replay rule. Nothing is
// returned for a frame that fails any check. Temp-allocated plaintext.
bridge_pty_open_input :: proc(frame: []byte, kr: ^vault.Vault_Keyring, session_id: string, boot_id: string) -> (plaintext: string, ok: bool) {
	if kr == nil || boot_id == "" do return "", false
	plain, salt, counter, opened := vault.pty_open(frame, kr, session_id, .In, kr.current_epoch, boot_id, context.temp_allocator)
	if !opened do return "", false
	if !bridge_pty_input_replay_accept(session_id, salt, counter) {
		crypto.zero_explicit(raw_data(plain), len(plain))
		return "", false
	}
	return string(plain), true
}

// ── Pane capture sealing (get_agent_pane / shell_get_pane replies) ──────────

Bridge_Pane_Seal :: enum {
	Sealed, // armored PTY v2 frame
	Locked, // configured but locked: send an error, never plaintext
	Failed, // sealing failed (randomness, bad session id): send an error
}

// bridge_pane_output_seal seals a pane capture for the hub. The armor is vault:v2:e<N>:b64(salt16 | nonce | tag | ct): a PTY v2
// `out` frame for session_id under a fresh CSPRNG salt (its own subkey, counter 1),
// minus the epoch prefix the token header already carries. The hub re-frames it to the
// binary PTY v2 layout (domain.vault_pty_v2_payload_from_armor) without decrypting.
// Caller owns `armored` when res == .Sealed.
bridge_pane_output_seal :: proc(output: string, session_id: string, allocator := context.allocator) -> (armored: string, res: Bridge_Pane_Seal) {
	status, kr := bridge_vault_status_and_key()
	defer vault.keyring_wipe(&kr)
	return bridge_pane_output_seal_with(status, &kr, output, session_id, bridge_pty_random_source, allocator)
}

// bridge_pane_output_seal_with is the pure core of bridge_pane_output_seal: vault
// state, keyring and randomness are passed in (tests drive it without the keystore).
bridge_pane_output_seal_with :: proc(status: Vault_Status, kr: ^vault.Vault_Keyring, output: string, session_id: string, random_source: string, allocator := context.allocator) -> (armored: string, res: Bridge_Pane_Seal) {
	if status != .Unlocked do return "", .Locked
	if output == "" do return "", .Sealed
	if kr == nil do return "", .Failed
	key, key_ok := vault.keyring_key_for_epoch(kr, kr.current_epoch)
	if !key_ok do return "", .Failed
	salt: Bridge_PTY_Salt
	if !os_random.fill(salt[:], random_source) do return "", .Failed
	frame, sealed := vault.pty_seal(transmute([]byte)output, key, kr.current_epoch, salt[:], 1, session_id, .Out, "", context.temp_allocator)
	if !sealed do return "", .Failed
	b64, err := base64.encode(frame[4:], allocator = context.temp_allocator)
	if err != nil do return "", .Failed
	e_buf: [16]byte
	return strings.concatenate({vault.VAULT_V2_PREFIX, "e", strconv.write_uint(e_buf[:], u64(kr.current_epoch), 10), ":", b64}, allocator), .Sealed
}

// BRIDGE_PANE_CAPTURE_SEAL_MAX_PLAIN keeps a sealed chat pane capture under the hub's
// 48000-byte message cap (content_service.pane_capture_limit_output): a token cut by
// that cap could never be decrypted. 48000 * 3/4 minus the envelope header and prefix.
BRIDGE_PANE_CAPTURE_SEAL_MAX_PLAIN :: 35_000

// bridge_pane_capture_seal_with seals a chat pane capture (capture_agent_pane) as a
// standard v2 content envelope: the hub stores it as the chat message body, which the
// UI already decrypts like any other vault message. A capture over the cap keeps its
// TAIL (the live end of the screen) from a line start and reports truncated.
bridge_pane_capture_seal_with :: proc(status: Vault_Status, kr: ^vault.Vault_Keyring, output: string, random_source: string, allocator := context.allocator) -> (armored: string, res: Bridge_Pane_Seal, truncated: bool) {
	if status != .Unlocked do return "", .Locked, false
	if kr == nil do return "", .Failed, false
	text := output
	if len(text) > BRIDGE_PANE_CAPTURE_SEAL_MAX_PLAIN {
		truncated = true
		start := len(text) - BRIDGE_PANE_CAPTURE_SEAL_MAX_PLAIN
		if nl := strings.index_byte(text[start:], '\n'); nl >= 0 {
			start += nl + 1
		} else {
			for start < len(text) && (text[start] & 0xC0) == 0x80 do start += 1
		}
		text = text[start:]
	}
	token, ok := vault.seal(transmute([]byte)text, kr, allocator, random_source)
	if !ok do return "", .Failed, false
	return token, .Sealed, truncated
}
