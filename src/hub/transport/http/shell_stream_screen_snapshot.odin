package http

// REQ-SHELL-29: screen snapshot on stream attach for LATE-JOINING viewers.
//
// WHY THIS EXISTS. Both terminal consumers already understand a `screen` frame
// (useShellStream.ts:221, useAgentStream.ts:225) and feed its payload into the same
// sink as incremental output. What was missing is a producer for a viewer that joins a
// session ALREADY being watched.
//
// The pty-host does emit a catchup screen on Attach, and the bridge forwards it
// (pty_host_stream_worker.odin:149-156) — but only on the hub's 0->1 viewer transition
// (shell_session_service.odin:140), and it travels as `shell_pty_output`, which the hub
// BROADCASTS to every viewer. So it cannot serve viewer #2 without repainting viewer #1.
// That 0->1 path is deliberately left byte-exact here; this serves late joiners only.
//
// ORDERING (REQ-SHELL-29 AC3, as revised). The snapshot travels the command/reply
// channel while incremental output is a bridge->hub push, so the two have NO
// protocol-level ordering. Rather than pretend otherwise, the payload is prefixed with
// erase-screen + cursor-home, making it an ABSOLUTE REPAINT: it discards whatever the
// client already drew, so DUPLICATION IS STRUCTURALLY IMPOSSIBLE.
//
// The residual, stated precisely: output produced between the pty-host's capture and the
// reply landing (one bridge->hub hop) is painted over and does not reappear until the
// program next writes. This is NOT a no-loss guarantee and must not be described as one.
// For the case that motivates the task — switching back to an idle shell sitting at a
// prompt — no output is in flight, so the repaint is exact.

import base64 "core:encoding/base64"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import agent_service "odin_test:hub/service/agent"
import shell_session_svc "odin_test:hub/service/shell_session"

// SHELL_SCREEN_REPAINT_PREFIX erases the screen and homes the cursor. It is what makes
// the snapshot idempotent against anything already rendered — see the ordering note above.
SHELL_SCREEN_REPAINT_PREFIX :: "\x1b[2J\x1b[H"

// _shell_screen_lf_to_crlf rewrites the pane's bare row separators into CRLF.
// Caller owns the result.
//
// WHY THIS IS NEEDED (REQ-SHELL-30). The pane text arrives as one string PER GRID ROW joined
// with a bare LF — bridge_pty_host_screen_to_output in src/bridge/pty_host_runtime.odin. A VT
// drops one row on LF and KEEPS the column, so the repaint drew every row starting where the
// previous one ended — a diagonal staircase on a viewer's FIRST render.
//
// WHY THE POLLED PANE IS SAFE ON THE SAME TEXT — CORRECTED BY REQ-SHELL-31. This comment used
// to say the polling pane "paints into the DOM, where bare LF is correct". THAT IS FALSE: the
// poller writes into xterm too (ShellTerminalPane.tsx:300 and :333,
// `term.write('\x1b[?25l' + output)`, fed by REST GET /shells/{id}/pane, which returns the
// bridge reply verbatim). Both paths feed a terminal. The poller is safe because xterm's OWN
// `convertEol` option performs the LF->CRLF conversion, and the code deliberately turns it OFF
// while streaming: `convertEol: !isStreamingActive` (ShellTerminalPane.tsx:229, kept in sync at
// :349; AgentPaneComposerPanel.tsx:263/:390 is the identical pair).
//
// The invariant is therefore about convertEol, NOT about "terminal vs DOM": the bare-LF text is
// safe in any consumer with convertEol ON and unsafe exactly where it is OFF. Anyone auditing
// for further instances should grep for the streaming paths / convertEol:false. The original
// framing sent two agents hunting for a non-terminal consumer that does not exist, and it missed
// the bridge's own catch-up emit (pty_host_stream_worker.odin), which REQ-SHELL-31 then had to
// fix as the SECOND staircase producer.
//
// WHY THE FIX LIVES HERE AND NOT AT THE JOIN. bridge_pty_host_screen_to_output is also the input
// to bridge_pty_host_pane_hash (the very next statement in bridge_pty_host_evaluate_pane), so
// changing the join would not merely alter the poller's text — it would invalidate every stored
// since_hash at once and cost every client a full repaint. This builder is the WS/terminal-only
// seam, and it is already the thing that speaks VT: it prepends erase-screen + cursor-home.
//
// An LF that ALREADY has a CR in front of it is passed through untouched, so this can never
// produce "\r\r\n" should a pane source ever start sending CRLF itself.
//
// NOTHING here measures width. vt.rs capture() writes SGR runs INLINE into each row, so a row's
// byte length is not its display width and must never be used as one. The separator is decided
// per LF byte, never per length.
_shell_screen_lf_to_crlf :: proc(s: string) -> string {
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

// _shell_screen_trim_trailing_blank_rows strips non-informative trailing blank/whitespace
// rows from pane text while preserving trailing spaces on non-blank prompt lines.
// Intermediate blank lines are preserved. Returns an empty string if all lines are blank.
// Caller owns the result.
_shell_screen_trim_trailing_blank_rows :: proc(s: string, allocator := context.allocator) -> string {
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

// _shell_screen_repaint_text builds the DECODED repaint: the erase+home prefix followed by
// the captured pane text with trailing blank rows trimmed and CRLF row separators, and an
// explicit ANSI cursor positioning sequence (\x1b[<row+1>;<col+1>H) when valid cursor
// coordinates (>= 0) are provided. Caller owns the result.
//
// The chunked writer cuts this text at row boundaries into SCREEN frames.
_shell_screen_repaint_text :: proc(pane_output: string, cursor_row: int = -1, cursor_col: int = -1) -> string {
	// REQ-PTY-COLOR-1: the capture may lead with the pty-host's terminal-colour preamble
	// (OSC 10/11/12/4). It goes FIRST in the repaint — before the alt-screen prefix and
	// before the erase+home — and is split off here so neither the trim nor the alt-prefix
	// detection below ever sees it.
	preamble, rows := contracts.pty_screen_split_preamble(pane_output)
	trimmed := _shell_screen_trim_trailing_blank_rows(rows)
	defer delete(trimmed)
	body := _shell_screen_lf_to_crlf(trimmed)
	defer delete(body)

	alt_prefix := ""
	rest_body := body
	if strings.has_prefix(body, "\x1b[?1049h\x1b[?25l") {
		alt_prefix = "\x1b[?1049h\x1b[?25l"
		rest_body = body[len("\x1b[?1049h\x1b[?25l"):]
	} else if strings.has_prefix(body, "\x1b[?1049h") {
		alt_prefix = "\x1b[?1049h"
		rest_body = body[len("\x1b[?1049h"):]
	}

	if cursor_row >= 0 && cursor_col >= 0 {
		cup := fmt.tprintf("\x1b[%d;%dH", cursor_row + 1, cursor_col + 1)
		return strings.concatenate({preamble, alt_prefix, SHELL_SCREEN_REPAINT_PREFIX, rest_body, cup})
	}
	return strings.concatenate({preamble, alt_prefix, SHELL_SCREEN_REPAINT_PREFIX, rest_body})
}

// SHELL_SCREEN_CHUNK_DECODED_BYTES is how much repaint text one `screen` frame carries.
// 32 KiB + the 6-byte pty_wire header lands well inside even the 16-bit WebSocket length
// (65535). That is deliberate: a snapshot of any size travels in frames that would survive
// a 16-bit-only writer, so this path can never again depend on a length arm being present
// to paint. (It was chosen when the payload was base64; binary left it unchanged so the
// per-frame budget on the viewer writer did not move.)
SHELL_SCREEN_CHUNK_DECODED_BYTES :: 32 * 1024

// _shell_screen_chunk_end picks where the chunk starting at `start` ends, preferring a ROW
// boundary (just past a '\n') so a chunk never splits an SGR escape run or a multi-byte
// rune. A single row longer than the budget — pathological, but a wide pane full of colour
// runs is what this ticket is about — falls back to the hard byte boundary, which is safe
// because xterm's parser is a STREAM parser: it carries escape and UTF-8 state across
// writes, and consecutive `screen` frames feed the same sink as incremental output
// (useShellStream.ts:221).
_shell_screen_chunk_end :: proc(s: string, start: int) -> int {
	if len(s) - start <= SHELL_SCREEN_CHUNK_DECODED_BYTES do return len(s)
	hard := start + SHELL_SCREEN_CHUNK_DECODED_BYTES
	for i := hard - 1; i > start; i -= 1 {
		if s[i] == '\n' do return i + 1
	}
	return hard
}

// shell_stream_screen_frame builds one binary SCREEN viewer frame (REQ-PTY-NET-2):
// kind=SCREEN, flags=SNAPSHOT [|ENCRYPTED], an optional cursor block, then the payload.
// For a plaintext repaint the payload already ends with the CUP escape, so the cursor
// block is informational; for an ENCRYPTED capture (payload = nonce|tag|ciphertext the
// hub cannot read) it is the ONLY way the browser learns where to put the cursor.
// Caller owns the result.
shell_stream_screen_frame :: proc(payload: []byte, cursor_row: int = -1, cursor_col: int = -1, is_encrypted: bool = false) -> []byte {
	return contracts.pty_wire_encode_viewer_frame(contracts.PTY_WIRE_KIND_SCREEN, contracts.pty_wire_flags(true, is_encrypted), payload, cursor_row, cursor_col)
}

// _shell_stream_write_screen_frame turns a pane reply into one or more `screen` frames on
// ONE socket. An empty `output` writes nothing: a terminal session answers locally with
// output:"" and has no screen worth repainting.
//
// WHY THIS CHUNKS (REQ-SHELL-33). This is the one caller on this socket whose payload can
// exceed a WebSocket length arm: vt.rs's capture() writes SGR colour runs INLINE into every
// row, so a wide, fully-coloured pane produces a repaint far larger than its display area.
// Before this change that frame was silently dropped and the viewer saw a BLANK PANE —
// exactly the late-join repaint REQ-SHELL-29 exists to provide, failing where it matters
// most. A 64-bit length arm alone would not settle it: any cap, however generous, would
// turn the same case back into a blank pane, only with a log line. Cutting the repaint into
// ordered frames means a snapshot of ANY size paints.
//
// This is sound because the repaint is ABSOLUTE and SEQUENTIAL. The erase+home prefix leads
// the first chunk only; the rest continue where it left off, on the same socket, written in
// order by this proc, into a client that feeds every `screen` frame to the same terminal
// sink. Re-prefixing later chunks would erase the part already painted.
//
// ATOMICITY, not merely ordering. Chunking is only sound if NOTHING ELSE writes this
// socket mid-sequence. It is not enough that the chunks leave in order: the bridge-push
// path (shell_session_broadcast_output) writes the same viewer socket from another thread,
// and an `output` frame between two chunks moves the cursor, after which every remaining
// chunk — none of which carries erase+home or absolute positioning — paints from the wrong
// place. The whole sequence is therefore written under that session's viewer-write lock;
// see shell_session_viewer_write_lock for why the lock is per session and why concurrent
// writes were in fact never safe on this socket even at one frame each.
//
// A partial paint on a mid-sequence failure is deliberate and is not a regression: the
// alternative is the blank pane this replaces, and the next output or snapshot repaints
// absolutely.
// `sessions`/`stream_id` name the viewer-write lock this sequence must hold — see the
// ATOMICITY note above. They may be nil/"" only where there is no fan-out to race with,
// which in practice means tests; production callers always have both.
_shell_stream_write_screen_frame :: proc(
	sessions: ^shell_session_svc.Shell_Session_Service,
	stream_id: string,
	client: net.TCP_Socket,
	pane_reply: string,
	cols: int = -1,
	rows: int = -1,
) -> bool {
	frames, ok := _shell_stream_screen_frames(pane_reply)
	if !ok do return false
	defer { for f in frames do delete(f); delete(frames) }

	// Held across EVERY chunk, not per chunk: an `output` frame landing between two
	// chunks would move the cursor and misposition all of them.
	// NOTE the shape. `defer` in Odin runs at the end of its ENCLOSING SCOPE, so putting
	// the unlock inside the `if` block releases the lock immediately — which is exactly
	// the bug req33_output_cannot_interleave_with_a_chunked_snapshot caught here. The
	// guarded `defer if` keeps the release at proc exit.
	write_mu := shell_session_svc.shell_session_viewer_write_lock(sessions, stream_id)
	if write_mu != nil do sync.mutex_lock(write_mu)
	defer if write_mu != nil { sync.mutex_unlock(write_mu); shell_session_svc.shell_session_viewer_write_release(sessions, stream_id) }

	total := 0
	for f in frames do total += len(f)
	offset := 0
	for frame in frames {
		result := shell_session_svc.shell_session_enqueue_viewer_frame(sessions, client, string(frame), 0x2)
		if result != .Ok {
			fmt.eprintfln(
				"ham-hub WARN shell screen snapshot frame not delivered result=%v offset=%d chunk_bytes=%d total_bytes=%d",
				result,
				offset,
				len(frame),
				total,
			)
			return false
		}
		offset += len(frame)
	}
	// REQ-PTY-NET-4: the next joiner at this geometry (or within the freshness window)
	// is served from these exact frames instead of another bridge round-trip.
	shell_session_svc.shell_session_snapshot_cache_store_capture(sessions, stream_id, frames[:], cols, rows, client)
	return true
}

// _shell_stream_screen_frames turns a pane reply into the ordered binary SCREEN frames
// it is written as. ok=false when there is nothing to paint (empty output, over cap,
// malformed armor). Caller owns the frames.
_shell_stream_screen_frames :: proc(pane_reply: string) -> (frames: [dynamic][]byte, ok: bool) {
	output := json_string(pane_reply, "output")
	defer delete(output)
	if output == "" do return nil, false
	encrypted_capture := strings.has_prefix(output, "vault:v1:")
	max_bytes := ((1024 * 1024 + 28 + 2) / 3) * 4 + len("vault:v1:") if encrypted_capture else 1024 * 1024
	if len(output) > max_bytes do return nil, false

	cursor_row := json_int(pane_reply, "cursor_row", -1)
	cursor_col := json_int(pane_reply, "cursor_col", -1)
	frames = make([dynamic][]byte)

	if encrypted_capture {
		// The bridge armors an encrypted capture as vault:v1:base64(nonce|tag|ct) on the
		// command/reply channel; the viewer gets the raw bytes.
		sealed, derr := base64.decode(output[len("vault:v1:"):], allocator = context.temp_allocator)
		if derr != nil { delete(frames); return nil, false }
		append(&frames, shell_stream_screen_frame(sealed, cursor_row, cursor_col, true))
		return frames, true
	}

	repaint := _shell_screen_repaint_text(output, cursor_row, cursor_col)
	defer delete(repaint)
	offset := 0
	for offset < len(repaint) {
		end := _shell_screen_chunk_end(repaint, offset)
		append(&frames, shell_stream_screen_frame(transmute([]byte)repaint[offset:end], cursor_row, cursor_col))
		offset = end
	}
	return frames, true
}

// SHELL_SNAPSHOT_CATCHUP_GRACE bounds how long the viewer that triggered the bridge attach
// waits for the pty-host catch-up to land before falling back to a capture round-trip.
// The catch-up normally beats the first resize by a few ms to a few hundred ms (bridge
// attach -> pty-host Attach -> Screen -> bridge -> hub); the grace is the ceiling for a
// slow bridge, after which REQ-SHELL-61's "every viewer sees a full screen" wins and one
// capture is paid. Polled, because the handler thread is the only thing waiting and a
// condvar per session would be more machinery than the two seconds justify.
SHELL_SNAPSHOT_CATCHUP_GRACE :: 2 * time.Second
SHELL_SNAPSHOT_CATCHUP_POLL  :: 20 * time.Millisecond

// Shell_Screen_Capture is the pane-source callback shell_stream_serve_screen_snapshot
// falls back to on a cache miss (shell_session_get_pane or agent get_instance_pane).
Shell_Screen_Capture :: struct {
	ctx:  rawptr,
	call: proc(ctx: rawptr, cols, rows: int) -> (reply: string, ok: bool),
}

// shell_stream_serve_screen_snapshot is the one attach-repaint policy for both panes
// (REQ-PTY-NET-4): serve from the cache when it can, wait briefly for the in-flight
// catch-up when this viewer caused the bridge attach, capture only as a last resort.
// Returns whether the viewer ended up with a full screen by any of the three routes.
shell_stream_serve_screen_snapshot :: proc(
	sessions: ^shell_session_svc.Shell_Session_Service,
	session_id: string,
	client: net.TCP_Socket,
	rows, cols: int,
	late_join: bool,
	capture: Shell_Screen_Capture,
	grace: time.Duration = SHELL_SNAPSHOT_CATCHUP_GRACE,
) -> bool {
	if session_id == "" || rows < 1 || cols < 1 do return false
	switch shell_session_svc.shell_session_snapshot_cache_decide(sessions, session_id, client, cols, rows) {
	case .Already_Painted: return true
	case .Serve:           return shell_session_svc.shell_session_snapshot_cache_serve(sessions, session_id, client)
	case .Miss:
	}
	if !late_join && grace > 0 {
		// We triggered the 0->1 attach: the pty-host catch-up is on its way as a
		// broadcast this socket will receive. Give it the grace window.
		started := time.tick_now()
		for time.tick_since(started) < grace {
			time.sleep(SHELL_SNAPSHOT_CATCHUP_POLL)
			switch shell_session_svc.shell_session_snapshot_cache_decide(sessions, session_id, client, cols, rows) {
			case .Already_Painted: return true
			case .Serve:           return shell_session_svc.shell_session_snapshot_cache_serve(sessions, session_id, client)
			case .Miss:
			}
		}
	}
	if capture.call == nil do return false
	reply, ok := capture.call(capture.ctx, cols, rows)
	if !ok do return false
	defer delete(reply)
	return _shell_stream_write_screen_frame(sessions, session_id, client, reply, cols, rows)
}

// shell_stream_should_send_screen_snapshot decides whether an attaching viewer's resize
// frame must be answered with a screen snapshot. It is THE gate: both stream handlers
// (shell_session_handlers.odin, agent_instance_handlers.odin) consult it rather than
// spelling the condition out twice, so the two panes cannot drift apart again.
//
// REQ-SHELL-61 — `late_join` IS ACCEPTED AND DELIBERATELY NOT CONSULTED, and that is the
// whole fix. This gate used to read `late_join && !screen_sent`, which meant THE FIRST
// VIEWER OF A SESSION NEVER RECEIVED A SNAPSHOT. Viewer #1 was expected to be painted by
// the pty-host's catch-up that the bridge forwards on the hub's 0->1 transition; when that
// catch-up carries little or nothing, viewer #1 gets a BLANK PANE, which is the reported
// neovim defect. A re-render or a tab switch appeared to "fix" it only because it made the
// viewer a late joiner, where the snapshot did fire.
//
// WHY SERVING VIEWER #1 TOO IS SAFE, since the design note at the top of this file is easy
// to misread as an argument against it. That note explains why the 0->1 catch-up cannot
// serve viewer #2 — it travels as `shell_pty_output`, which the hub BROADCASTS, so it would
// repaint viewer #1. That is an argument for ADDING a targeted snapshot for late joiners.
// It is not an argument for WITHHOLDING one from viewer #1, and the code never had one:
//   - the snapshot is a TARGETED write. shell_stream_send_shell_screen_snapshot is handed
//     one `client` socket and _shell_stream_write_screen_frame writes only that socket —
//     no fan-out, no viewer-list iteration — so it cannot repaint anybody else;
//   - it is an ABSOLUTE REPAINT (SHELL_SCREEN_REPAINT_PREFIX, erase-screen + cursor-home),
//     so viewer #1 receiving BOTH the catch-up and the snapshot paints over, it does not
//     duplicate. The cost is one extra pane capture per attach.
//
// `screen_sent` keeps it once-per-stream: a viewer resizes repeatedly and only the first
// resize earns a capture.
//
// THE GEOMETRY GUARD IS PART OF THE GATE, not an incidental caller-side check, because it
// is a live trap worth seeing in one place: a snapshot is only ever produced from a resize
// frame carrying real geometry (capturing at a guessed 80 columns would re-wrap the
// screen), so a client that sends NO resize, or sends 0/0, gets no snapshot at all. Since
// REQ-SHELL-61 that also means it gets no screen on a first attach beyond whatever the
// catch-up drew. The shells UI does always send one from inside `onopen`
// (useShellStream.ts sendGeometry -> shellStreamFrames.ts shellResizeFrame), with 24x80
// floors applied in ShellTerminalPane.tsx getGeometry — but that helper returns null when
// the xterm instance does not exist yet, and a null frame is silently not sent.
shell_stream_should_send_screen_snapshot :: proc(late_join: bool, screen_sent: bool, rows, cols: int) -> bool {
	if screen_sent do return false
	if rows < 1 || cols < 1 do return false
	return true
}

@(private = "file")
Shell_Capture_Ctx :: struct {
	svc:        ^shell_session_svc.Shell_Session_Service,
	auth:       contracts.Auth_Context,
	session_id: string,
}

@(private = "file")
_shell_capture_call :: proc(raw: rawptr, cols, rows: int) -> (string, bool) {
	c := (^Shell_Capture_Ctx)(raw)
	reply, ok, err := shell_session_svc.shell_session_get_pane(c.svc, c.auth, c.session_id, "", cols, rows)
	if !ok || err.code != .None do return "", false
	return reply, true
}

// shell_stream_send_shell_screen_snapshot serves the shells terminal pane.
// `cols`/`rows` come from the client's own resize frame so the capture is rendered at the
// width the viewer actually has; capturing at a guessed 80 would deliver a correct picture
// of the wrong layout. `late_join` says whether this viewer triggered the bridge attach
// (false) — see shell_stream_serve_screen_snapshot.
shell_stream_send_shell_screen_snapshot :: proc(
	svc: ^shell_session_svc.Shell_Session_Service,
	auth: contracts.Auth_Context,
	session_id: string,
	client: net.TCP_Socket,
	rows, cols: int,
	late_join: bool = true,
) -> bool {
	if svc == nil || session_id == "" || rows < 1 || cols < 1 do return false
	ctx := Shell_Capture_Ctx{svc = svc, auth = auth, session_id = session_id}
	return shell_stream_serve_screen_snapshot(svc, session_id, client, rows, cols, late_join, Shell_Screen_Capture{ctx = rawptr(&ctx), call = _shell_capture_call})
}

@(private = "file")
Agent_Capture_Ctx :: struct {
	svc:         ^agent_service.Agent_Service,
	auth:        contracts.Auth_Context,
	instance_id: string,
}

@(private = "file")
_agent_capture_call :: proc(raw: rawptr, cols, rows: int) -> (string, bool) {
	c := (^Agent_Capture_Ctx)(raw)
	reply, ok, err := agent_service.get_instance_pane(c.svc, c.auth, c.instance_id, "", cols, rows)
	if !ok || err.code != .None do return "", false
	return reply, true
}

// shell_stream_send_agent_screen_snapshot serves the agent pane. Same frame, same
// contract; only the pane source differs, because an agent instance has no shell_sessions
// row — agent_service.get_instance_pane is the twin of shell_session_get_pane and returns
// the identical payload shape.
// `sessions` is the shell-session service, NOT the pane source: an agent stream attaches
// its viewer socket through shell_session_attach exactly like a shell does
// (agent_instance_handlers.odin), so its writes share the same lock and the same fan-out.
shell_stream_send_agent_screen_snapshot :: proc(
	svc: ^agent_service.Agent_Service,
	sessions: ^shell_session_svc.Shell_Session_Service,
	auth: contracts.Auth_Context,
	instance_id: string,
	client: net.TCP_Socket,
	rows, cols: int,
	late_join: bool = true,
) -> bool {
	if svc == nil || instance_id == "" || rows < 1 || cols < 1 do return false
	ctx := Agent_Capture_Ctx{svc = svc, auth = auth, instance_id = instance_id}
	return shell_stream_serve_screen_snapshot(sessions, instance_id, client, rows, cols, late_join, Shell_Screen_Capture{ctx = rawptr(&ctx), call = _agent_capture_call})
}
