package main

// REQ-LSP-BR-1: Bridge-side LSP session manager.
//
// Spawns a language-server process on the bridge host and relays JSON-RPC
// between its stdio and the Hub WebSocket as lsp_* frames.
//
// MODEL: bridge_shell_session.odin — long-lived process over the bridge WS.
//
// MEMORY NOTE: every allocation here lives on the persistent heap (context
// allocator on background threads = heap). No arena is in scope. Every
// strings.clone / dynamic array / JSON builder output is explicitly freed.
//
// FRAMING: the LSP Base Protocol uses Content-Length-delimited frames:
//   Content-Length: N\r\n\r\n<N bytes of JSON>
// N is byte-count, not rune-count. Headers can be split across OS reads, and
// one read may contain multiple complete messages or half of one. lsp_try_parse_one
// is the pure framing kernel (testable without I/O).

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import ws "odin_test:lib/ws"

// ALLOCATOR RULE (learned the hard way — see the comment on lsp_heap).
// LSP state crosses threads: a session's strings are cloned on the WS command
// thread, drained by the hub runtime loop, and freed by the per-session read
// thread. Every long-lived allocation here is therefore made AND freed through
// the process-wide heap, passed explicitly. Never let context.allocator decide:
// in the bridge it can be a per-request virtual arena, and under `odin test` it
// is a per-test tracking allocator — either way, memory allocated on one thread
// and freed on another goes through a different allocator than it came from.

// lsp_heap is the single allocator every cross-thread LSP allocation uses.
lsp_heap :: proc() -> runtime.Allocator {
	return runtime.default_allocator()
}

// ---- status / session structs -----------------------------------------------

Bridge_Lsp_Status :: enum {
	Starting,
	Running,
	Exited,
	Failed,
}

// Bridge_Lsp_Session holds the durable record for one LSP process. All string
// fields are heap-allocated clones (owned). stdin_w is nil once closed.
Bridge_Lsp_Session :: struct {
	session_id:    string, // "lsp_<nanos>_<seq>"
	language:      string,
	cmd:           string, // original cmd string (for logging)
	cwd:           string,
	owner_user_id: string,
	pid:           int,
	status:        Bridge_Lsp_Status,
	stdin_w:       ^os.File,  // write end — bridge sends JSON-RPC to server; nil after close
	process:       os.Process, // handle for SIGTERM / process_wait
	process_slot:  bool, // owns one Bridge-wide child-process slot
}

Bridge_Lsp_Session_Map :: struct {
	mu:       sync.Mutex,
	sessions: map[string]Bridge_Lsp_Session,
}

// ---- session map global -------------------------------------------------------

@(private = "file")
bridge_lsp_session_map: Bridge_Lsp_Session_Map

// ---- ID generator ------------------------------------------------------------

@(private = "file")
_bridge_lsp_seq:    i64
@(private = "file")
_bridge_lsp_seq_mu: sync.Mutex

bridge_lsp_next_id :: proc() -> string {
	sync.mutex_lock(&_bridge_lsp_seq_mu)
	_bridge_lsp_seq += 1
	seq := _bridge_lsp_seq
	sync.mutex_unlock(&_bridge_lsp_seq_mu)
	return strings.clone(fmt.tprintf("lsp_%x_%d", bridge_now_unix_ms(), seq), lsp_heap())
}

// ---- map CRUD ----------------------------------------------------------------

bridge_lsp_session_register :: proc(s: Bridge_Lsp_Session) {
	sync.mutex_lock(&bridge_lsp_session_map.mu)
	defer sync.mutex_unlock(&bridge_lsp_session_map.mu)
	if bridge_lsp_session_map.sessions == nil {
		bridge_lsp_session_map.sessions = make(map[string]Bridge_Lsp_Session, allocator = lsp_heap())
	}
	bridge_lsp_session_map.sessions[s.session_id] = s
}

bridge_lsp_session_set_status :: proc(session_id: string, status: Bridge_Lsp_Status) {
	sync.mutex_lock(&bridge_lsp_session_map.mu)
	defer sync.mutex_unlock(&bridge_lsp_session_map.mu)
	if s, ok := &bridge_lsp_session_map.sessions[session_id]; ok {
		s.status = status
	}
}

// bridge_lsp_session_take_stdin_w atomically replaces stdin_w with nil and
// returns the old value so the caller can close it without a race.
bridge_lsp_session_take_stdin_w :: proc(session_id: string) -> ^os.File {
	sync.mutex_lock(&bridge_lsp_session_map.mu)
	defer sync.mutex_unlock(&bridge_lsp_session_map.mu)
	if s, ok := &bridge_lsp_session_map.sessions[session_id]; ok {
		f := s.stdin_w
		s.stdin_w = nil
		return f
	}
	return nil
}

// bridge_lsp_session_remove removes the session from the map (called on cleanup).
//
// The five owned clones are freed here. That is only safe because no caller
// holds a borrowed pointer into a map entry outside the lock: every accessor
// below either works by session_id or returns cloned strings. Do not
// reintroduce a proc that hands a Bridge_Lsp_Session snapshot to a caller who
// then reads its strings after unlocking.
bridge_lsp_session_remove :: proc(session_id: string) {
	sync.mutex_lock(&bridge_lsp_session_map.mu)
	defer sync.mutex_unlock(&bridge_lsp_session_map.mu)
	if s, ok := bridge_lsp_session_map.sessions[session_id]; ok {
		delete_key(&bridge_lsp_session_map.sessions, session_id)
		delete(s.session_id, lsp_heap())
		delete(s.language, lsp_heap())
		delete(s.cmd, lsp_heap())
		delete(s.cwd, lsp_heap())
		delete(s.owner_user_id, lsp_heap())
		if s.process_slot do bridge_process_slot_release()
	}
}

// bridge_lsp_session_exists reports whether a session id is registered, without
// exposing any borrowed string.
bridge_lsp_session_exists :: proc(session_id: string) -> bool {
	sync.mutex_lock(&bridge_lsp_session_map.mu)
	defer sync.mutex_unlock(&bridge_lsp_session_map.mu)
	_, ok := bridge_lsp_session_map.sessions[session_id]
	return ok
}

// bridge_lsp_session_status returns a session's status by id (no borrowed
// pointers escape the lock).
bridge_lsp_session_status :: proc(session_id: string) -> (Bridge_Lsp_Status, bool) {
	sync.mutex_lock(&bridge_lsp_session_map.mu)
	defer sync.mutex_unlock(&bridge_lsp_session_map.mu)
	if s, ok := bridge_lsp_session_map.sessions[session_id]; ok do return s.status, true
	return .Failed, false
}

// bridge_lsp_session_write_stdin writes to the server's stdin while HOLDING the
// map lock, so a concurrent lsp_stop cannot close the fd between the liveness
// check and the write (N1). Returns false if the session is gone or not running.
// ---- opt-in JSON-RPC tracing ------------------------------------------------
//
// Set HAM_LSP_TRACE_DIR to capture, per session, EVERY frame in both directions:
//   <dir>/<session_id>.jsonl   {"t":<unix_ms>,"dir":"tx"|"rx","body":<raw frame>}
// "tx" is bridge -> language server (what the editor asked); "rx" is the answer.
// Unset (the default) this is a single getenv and a branch, so production pays
// nothing. It exists because "no completions" is indistinguishable, from the
// outside, between a request never sent, a request sent against a stale
// document, and a server answering nothing -- and those have different fixes.
lsp_trace_dir :: proc() -> string {
	dir, found := os.lookup_env_alloc("HAM_LSP_TRACE_DIR", context.temp_allocator)
	if !found do return ""
	return dir
}

lsp_trace :: proc(session_id: string, direction: string, body: string) {
	dir := lsp_trace_dir()
	if dir == "" do return
	path := fmt.tprintf("%s/%s.jsonl", dir, session_id)
	f, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_APPEND, os.Permissions{.Read_User, .Write_User})
	if err != nil do return
	defer os.close(f)
	// body is raw JSON already; embed it as a string so one bad frame cannot
	// corrupt the whole trace file for a reader.
	// NOTE: Odin's fmt treats a literal '{' as the start of a brace directive, so
	// the JSON braces are passed as ARGUMENTS rather than written into the format
	// string. Writing them inline yields "%!(MISSING CLOSE BRACE)" and a corrupt
	// trace -- found the first time this ran.
	line := fmt.tprintf("%s\"t\":%d,\"dir\":\"%s\",\"len\":%d,\"body\":%q%s\n",
		"{", bridge_now_unix_ms(), direction, len(body), body, "}")
	os.write(f, transmute([]byte)line)
}

bridge_lsp_session_write_stdin :: proc(session_id: string, chunks: ..[]byte) -> bool {
	sync.mutex_lock(&bridge_lsp_session_map.mu)
	defer sync.mutex_unlock(&bridge_lsp_session_map.mu)
	s, ok := bridge_lsp_session_map.sessions[session_id]
	if !ok || s.status != .Running || s.stdin_w == nil do return false
	for c in chunks {
		if _, err := os.write(s.stdin_w, c); err != nil do return false
		lsp_trace(session_id, "tx", string(c))
	}
	return true
}

// bridge_lsp_active_session_ids returns CLONED ids of every live session; the
// caller owns and must delete them.
bridge_lsp_active_session_ids :: proc() -> [dynamic]string {
	out := make([dynamic]string, lsp_heap())
	sync.mutex_lock(&bridge_lsp_session_map.mu)
	defer sync.mutex_unlock(&bridge_lsp_session_map.mu)
	for id, s in bridge_lsp_session_map.sessions {
		if s.status == .Running || s.status == .Starting do append(&out, strings.clone(id, lsp_heap()))
	}
	return out
}

// bridge_lsp_session_pid returns a session's pid by id.
bridge_lsp_session_pid :: proc(session_id: string) -> int {
	sync.mutex_lock(&bridge_lsp_session_map.mu)
	defer sync.mutex_unlock(&bridge_lsp_session_map.mu)
	if s, ok := bridge_lsp_session_map.sessions[session_id]; ok do return s.pid
	return 0
}

// ---- outgoing frame queue ---------------------------------------------------
//
// lsp_data / lsp_error frames are built on background threads and queued here.
// bridge_hub_runtime_loop drains the queue on the WS writer goroutine.

@(private = "file")
Bridge_Lsp_Outgoing :: struct {
	json: string, // pre-built frame; caller transfers ownership
}

@(private = "file")
bridge_lsp_outgoing_queue: [dynamic]Bridge_Lsp_Outgoing

@(private = "file")
bridge_lsp_outgoing_mu: sync.Mutex

bridge_lsp_init :: proc() {
	bridge_lsp_outgoing_queue = make([dynamic]Bridge_Lsp_Outgoing, lsp_heap())
}

@(private = "file")
_bridge_lsp_init_once: sync.Once

// bridge_lsp_init_once initialises the queue exactly once no matter how many
// callers race. The tests need it because they run in parallel threads and a
// second bridge_lsp_init would drop the queue out from under a live reader.
bridge_lsp_init_once :: proc() {
	sync.once_do(&_bridge_lsp_init_once, bridge_lsp_init)
}

bridge_lsp_enqueue :: proc(json: string) {
	if json == "" do return
	sync.mutex_lock(&bridge_lsp_outgoing_mu)
	defer sync.mutex_unlock(&bridge_lsp_outgoing_mu)
	append(&bridge_lsp_outgoing_queue, Bridge_Lsp_Outgoing{json = strings.clone(json, lsp_heap())})
}

bridge_lsp_drain_outgoing :: proc(conn: ^ws.Connection) {
	for {
		item: Bridge_Lsp_Outgoing
		have := false
		sync.mutex_lock(&bridge_lsp_outgoing_mu)
		if len(bridge_lsp_outgoing_queue) > 0 {
			item = bridge_lsp_outgoing_queue[0]
			ordered_remove(&bridge_lsp_outgoing_queue, 0)
			have = true
		}
		sync.mutex_unlock(&bridge_lsp_outgoing_mu)
		if !have do return
		if !bridge_hub_send(conn, item.json) {
			sync.mutex_lock(&bridge_lsp_outgoing_mu)
			inject_at(&bridge_lsp_outgoing_queue, 0, item)
			sync.mutex_unlock(&bridge_lsp_outgoing_mu)
			conn.connected = false
			return
		}
		delete(item.json, lsp_heap())
	}
}

// bridge_lsp_take_outgoing removes and returns every queued frame without a WS
// connection, transferring ownership of each string to the caller (who must
// delete them). Used when frames must be discarded rather than sent, and by the
// session tests to observe what a read thread produced.
bridge_lsp_take_outgoing :: proc() -> [dynamic]string {
	out := make([dynamic]string, lsp_heap())
	sync.mutex_lock(&bridge_lsp_outgoing_mu)
	defer sync.mutex_unlock(&bridge_lsp_outgoing_mu)
	for item in bridge_lsp_outgoing_queue {
		append(&out, item.json) // ownership moves to caller
	}
	clear(&bridge_lsp_outgoing_queue)
	return out
}

// ---- LSP Base Protocol framing (pure, no I/O) --------------------------------
//
// lsp_try_parse_one scans buf for a complete Content-Length-framed message.
//
//   buf = "Content-Length: N\r\n\r\n<body>"
//
// Returns:
//   message   — slice INTO buf for the body bytes (NOT a copy); valid only
//               while buf is unmodified.
//   remaining — slice into buf for bytes after the message.
//   ok        — true iff a complete message was found.
//
// Returns (nil, nil, false) when:
//   - the header separator \r\n\r\n has not arrived yet, OR
//   - Content-Length is missing/unparseable from the header, OR
//   - the body is shorter than the declared Content-Length.
//
// N is a BYTE count. This function operates entirely on bytes so multibyte
// UTF-8 sequences are handled transparently.
//
// LSP_MAX_CONTENT_LENGTH caps absurdly large declared lengths so a server
// emitting garbage cannot make the accumulator grow without bound.
LSP_MAX_CONTENT_LENGTH :: 16 * 1024 * 1024 // 16 MiB

// LSP_MAX_HEADER bounds the HEADER, which is a separate concern from the total
// accumulator bound and the reason garbage is caught promptly. A conforming
// header is tens of bytes; anything past a few KB with no \r\n\r\n in sight is
// a log line, a banner or a stack trace, not a header.
//
// Without this, garbage is only caught once the accumulator passes
// LSP_MAX_ACCUM (16 MiB) — and because every read rescans the whole buffer for
// the separator, getting there costs O(n^2): measured at well over 20 seconds
// of CPU for a server that simply logged to stdout. The header bound turns
// that into a fixed ~8 KiB.
LSP_MAX_HEADER :: 8 * 1024

// lsp_header_overrun reports that buf cannot be the start of a valid frame:
// more than LSP_MAX_HEADER bytes have arrived with no header terminator among
// them. Pure, no I/O — the caller fails the session on true.
lsp_header_overrun :: proc(buf: []byte) -> bool {
	if len(buf) <= LSP_MAX_HEADER do return false
	// Only the header window needs scanning; +3 so a separator straddling the
	// boundary still counts.
	window := buf[:min(len(buf), LSP_MAX_HEADER + 3)]
	for i := 0; i + 3 < len(window); i += 1 {
		if window[i] == '\r' && window[i+1] == '\n' && window[i+2] == '\r' && window[i+3] == '\n' {
			return false
		}
	}
	return true
}

lsp_try_parse_one :: proc(buf: []byte) -> (message: []byte, remaining: []byte, ok: bool) {
	// Search for the header terminator \r\n\r\n.
	sep := -1
	for i := 0; i + 3 < len(buf); i += 1 {
		if buf[i] == '\r' && buf[i+1] == '\n' && buf[i+2] == '\r' && buf[i+3] == '\n' {
			sep = i
			break
		}
	}
	if sep < 0 do return nil, nil, false // header not complete yet

	header := string(buf[:sep])

	// Extract Content-Length value.
	CL_PREFIX :: "Content-Length:"
	cl_idx := strings.index(header, CL_PREFIX)
	if cl_idx < 0 do return nil, nil, false // no Content-Length header — garbage

	val := strings.trim_space(header[cl_idx + len(CL_PREFIX):])
	// Trim to just the first header line (there may be other headers).
	if nl := strings.index_byte(val, '\n'); nl >= 0 do val = val[:nl]
	val = strings.trim_space(val)

	content_length, cl_ok := strconv.parse_int(val)
	if !cl_ok || content_length < 0 || content_length > LSP_MAX_CONTENT_LENGTH {
		return nil, nil, false // bad Content-Length — treat as incomplete (caller guards buffer size)
	}

	body_start := sep + 4 // skip past \r\n\r\n
	body_end   := body_start + content_length
	if len(buf) < body_end do return nil, nil, false // body not fully arrived yet

	return buf[body_start:body_end], buf[body_end:], true
}

// ---- outgoing frame JSON builders -------------------------------------------

@(private = "file")
bridge_lsp_data_frame_json :: proc(session_id, message: string) -> string {
	b := strings.builder_make(lsp_heap())
	strings.write_string(&b, "{\"type\":\"lsp_data\",\"session_id\":\"")
	bridge_runtime_write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"message\":\"")
	bridge_runtime_write_json_string(&b, message)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

@(private = "file")
bridge_lsp_error_frame_json :: proc(session_id, reason: string, exit_code: int) -> string {
	b := strings.builder_make(lsp_heap())
	strings.write_string(&b, "{\"type\":\"lsp_error\",\"session_id\":\"")
	bridge_runtime_write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"reason\":\"")
	bridge_runtime_write_json_string(&b, reason)
	strings.write_string(&b, "\",\"exit_code\":")
	bridge_agent_write_int(&b, exit_code)
	strings.write_string(&b, ",\"error\":")
	contracts.write_wire_error(&b, bridge_error_wire(bridge_error(.lsp_crashed), reason))
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// ---- background read thread -------------------------------------------------

// LSP_MAX_ACCUM caps the accumulator so a server writing garbage (no valid
// Content-Length headers) cannot exhaust bridge memory.
//
// It MUST exceed LSP_MAX_CONTENT_LENGTH plus header slack: a message declaring
// a legal length just under the content cap is still legal while its body is
// arriving, and a smaller accum bound would kill that session as a framing
// error mid-message.
LSP_MAX_ACCUM :: LSP_MAX_CONTENT_LENGTH + 64 * 1024

#assert(LSP_MAX_ACCUM > LSP_MAX_CONTENT_LENGTH)

Bridge_Lsp_Read_Ctx :: struct {
	session_id: string,       // owned clone
	stdout_r:   ^os.File,     // read end of stdout pipe; read thread closes it
	process:    os.Process,
}

// LSP_REAP_GRACE bounds every wait on a child process. Nothing on this path
// may block indefinitely.
LSP_REAP_GRACE :: 2 * time.Second

// bridge_lsp_reap returns the child's exit code, forcing it down if it has not
// already exited. Mirrors the core:os idiom (core/os/process.odin): poll with
// timeout=0, kill if still running, then wait for the corpse. Returns -1 when
// the exit code could not be determined.
bridge_lsp_reap :: proc(process: os.Process) -> int {
	// Already dead? Reap immediately, no signal needed.
	if state, err := os.process_wait(process, 0); err == nil && state.exited {
		return state.exit_code
	}
	// Still running (or the poll errored) — force it down.
	_ = os.process_kill(process)
	if state, err := os.process_wait(process, LSP_REAP_GRACE); err == nil && state.exited {
		return state.exit_code
	}
	return -1
}

bridge_lsp_read_worker :: proc(data: rawptr) {
	ctx := (^Bridge_Lsp_Read_Ctx)(data)
	defer {
		delete(ctx.session_id, lsp_heap())
		free(ctx, lsp_heap())
		free_all(context.temp_allocator)
	}

	buf: [4096]byte
	accum := make([dynamic]byte, lsp_heap())
	defer {
		delete(accum)
		os.close(ctx.stdout_r)
	}

	exit_code := -1
	reason    := "exited"

	read_loop: for {
		n, read_err := os.read(ctx.stdout_r, buf[:])
		if n > 0 {
			append(&accum, ..buf[:n])

			// Drain all complete messages from the accumulator.
			msg_loop: for {
				msg, remaining, parsed := lsp_try_parse_one(accum[:])
				if !parsed do break msg_loop

				lsp_trace(ctx.session_id, "rx", string(msg))
				frame := bridge_lsp_data_frame_json(ctx.session_id, string(msg))
				bridge_lsp_enqueue(frame)
				delete(frame, lsp_heap())

				// Replace accumulator with the bytes after the consumed message.
				new_accum := make([dynamic]byte, len(remaining), lsp_heap())
				copy(new_accum[:], remaining)
				delete(accum)
				accum = new_accum
			}

			// Garbage guards, cheapest first.
			//
			// 1. Header bound: no terminator within the header window means the
			//    server is writing something that is not a frame at all (a log
			//    line, a banner, a stack trace). Catches it after ~8 KiB.
			// 2. Accumulator bound: backstop for a well-formed header whose body
			//    never arrives.
			if lsp_header_overrun(accum[:]) || len(accum) > LSP_MAX_ACCUM {
				reason = "framing_error"
				break read_loop
			}
		}
		if read_err != nil || n <= 0 {
			// EOF or I/O error — normal exit or server crash.
			break read_loop
		}
	}

	// Reap the child so it does not become a zombie.
	//
	// B1: an unbounded process_wait here parks this thread FOREVER on the
	// framing_error path — that break happens while the server is still alive
	// and still writing the garbage that tripped the bound, so nothing will
	// ever make the wait return. Everything below (status, the lsp_error
	// frame, the map removal) would be unreachable, leaving a wedged thread
	// reporting a healthy session. Always bound the wait and kill first.
	exit_code = bridge_lsp_reap(ctx.process)

	// Mark session finished and notify hub. A server that framed its output
	// correctly and exited 0 is .Exited; a framing error or a non-zero exit is
	// an unexpected death and must surface as .Failed.
	final_status: Bridge_Lsp_Status = .Exited
	if reason == "framing_error" || exit_code != 0 do final_status = .Failed
	bridge_lsp_session_set_status(ctx.session_id, final_status)
	frame := bridge_lsp_error_frame_json(ctx.session_id, reason, exit_code)
	bridge_lsp_enqueue(frame)
	delete(frame, lsp_heap())

	// Remove from the map now that every WS frame is queued. The session was
	// purely in-memory (no spec file to delete); bridge_lsp_session_remove frees
	// the five owned clones, which is safe because no accessor lets a borrowed
	// string escape the map lock.
	bridge_lsp_session_remove(ctx.session_id)
}

// ---- WS command dispatcher --------------------------------------------------

// bridge_lsp_handle_command returns true when it handled the frame type so
// bridge_hub_handle_command can return early.
bridge_lsp_handle_command :: proc(conn: ^ws.Connection, type, text: string) -> bool {
	switch type {
	case "lsp_start":
		bridge_lsp_handle_start(conn, text)
		return true
	case "lsp_stop":
		bridge_lsp_handle_stop(conn, text)
		return true
	case "lsp_send":
		bridge_lsp_handle_send(text)
		return true
	}
	return false
}

// bridge_lsp_find_root_dir searches upwards from file_path (or cwd) towards the
// filesystem root for the nearest ancestor directory containing any of the
// comma-separated root_markers (e.g. "tsconfig.json,package.json", "go.mod,.git").
// Returns a heap-allocated copy of the directory path if found, or "" otherwise.
bridge_lsp_find_root_dir :: proc(file_path, cwd, root_markers: string, allocator := context.allocator) -> string {
	if strings.trim_space(root_markers) == "" do return ""

	// Determine starting search directory.
	start_dir := ""
	if strings.trim_space(file_path) != "" {
		fp := file_path
		if !filepath.is_abs(fp) && strings.trim_space(cwd) != "" {
			if joined, err := filepath.join([]string{cwd, fp}, context.temp_allocator); err == nil {
				fp = joined
			}
		}
		clean_fp, _ := filepath.clean(fp, context.temp_allocator)
		if os.is_dir(clean_fp) {
			start_dir = clean_fp
		} else {
			start_dir = filepath.dir(clean_fp)
		}
	} else if strings.trim_space(cwd) != "" {
		start_dir, _ = filepath.clean(cwd, context.temp_allocator)
	}

	if start_dir == "" do return ""

	// Split comma-separated markers.
	markers_raw := strings.split(root_markers, ",", context.temp_allocator)
	markers := make([dynamic]string, context.temp_allocator)
	for m in markers_raw {
		trimmed := strings.trim_space(m)
		if trimmed != "" {
			append(&markers, trimmed)
		}
	}
	if len(markers) == 0 do return ""

	curr := start_dir
	for {
		for m in markers {
			candidate, jerr := filepath.join([]string{curr, m}, context.temp_allocator)
			if jerr == nil && os.exists(candidate) {
				return strings.clone(curr, allocator)
			}
		}

		parent := filepath.dir(curr)
		if parent == curr || curr == "." || curr == "" {
			break
		}
		curr = parent
	}

	return ""
}

// ---- lsp_start: spawn server process ----------------------------------------

bridge_lsp_handle_start :: proc(conn: ^ws.Connection, text: string) {
	command_id   := extract_json_string(text, "command_id",    "")
	session_id   := extract_json_string(text, "session_id",    "")
	language     := extract_json_string(text, "language",      "")
	cmd_str      := extract_json_string(text, "cmd",           "")
	args_str     := extract_json_string(text, "args",          "")
	cwd          := extract_json_string(text, "cwd",           "")
	owner_uid    := extract_json_string(text, "owner_user_id", "")
	root_markers := extract_json_string(text, "root_markers",  "")
	file_path    := extract_json_string(text, "file_path",     "")
	// extract_json_string returns a heap string per call (json_unescape,
	// main.odin:732). This loop is NOT arena-covered, so every one is freed
	// here; the session keeps its own lsp_heap clones.
	defer {
		delete(command_id);   delete(session_id); delete(language)
		delete(cmd_str);      delete(args_str);   delete(cwd)
		delete(owner_uid);    delete(root_markers); delete(file_path)
	}

	send_result :: proc(conn: ^ws.Connection, session_id, command_id: string, ok: bool, err_msg: string, root_path: string = "") {
		b := strings.builder_make()
		strings.write_string(&b, "{\"type\":\"lsp_started\",\"session_id\":\"")
		bridge_runtime_write_json_string(&b, session_id)
		strings.write_string(&b, "\",\"command_id\":\"")
		bridge_runtime_write_json_string(&b, command_id)
		strings.write_string(&b, "\",")
		if !ok {
			bridge_write_failure(&b, bridge_error_wire(bridge_error(.lsp_start_failed), err_msg))
		} else {
			strings.write_string(&b, "\"ok\":true")
		}
		if ok && strings.trim_space(root_path) != "" {
			strings.write_string(&b, ",\"root_path\":\"")
			bridge_runtime_write_json_string(&b, root_path)
			strings.write_byte(&b, '"')
		}
		strings.write_byte(&b, '}')
		result := strings.to_string(b)
		defer delete(result)
		if conn != nil do _ = bridge_hub_send(conn, result)
	}

	if strings.trim_space(session_id) == "" {
		send_result(conn, session_id, command_id, false, "missing session_id")
		return
	}
	if strings.trim_space(cmd_str) == "" {
		send_result(conn, session_id, command_id, false, "missing cmd")
		return
	}
	// Registering over a live id would orphan that process and leak its clones.
	if bridge_lsp_session_exists(session_id) {
		send_result(conn, session_id, command_id, false, "session_id already in use")
		return
	}

	// Build command argv: cmd + space-separated args.
	argv := make([dynamic]string)
	defer delete(argv)
	append(&argv, cmd_str)
	if strings.trim_space(args_str) != "" {
		parts := strings.split(args_str, " ")
		defer delete(parts)
		for p in parts {
			if strings.trim_space(p) != "" do append(&argv, p)
		}
	}

	// Long-lived language servers retain a Bridge-wide child-process slot until
	// the read-loop cleanup removes the session.
	if !bridge_process_slot_try_acquire() {
		send_result(conn, session_id, command_id, false, "bridge child-process limit reached")
		return
	}
	process_slot_owned := true
	defer if process_slot_owned do bridge_process_slot_release()

	// Create stdin/stdout pipes.
	stdin_r, stdin_w, pipe_err1 := os.pipe()
	if pipe_err1 != nil {
		send_result(conn, session_id, command_id, false, "pipe() failed for stdin")
		return
	}
	stdout_r, stdout_w, pipe_err2 := os.pipe()
	if pipe_err2 != nil {
		os.close(stdin_r); os.close(stdin_w)
		send_result(conn, session_id, command_id, false, "pipe() failed for stdout")
		return
	}

	// Detect project root directory if root markers are configured.
	detected_root := bridge_lsp_find_root_dir(file_path, cwd, root_markers)
	defer delete(detected_root)

	// Spawn the language server. The child gets stdin_r as stdin and stdout_w as stdout.
	working_dir := cwd
	if detected_root != "" {
		working_dir = detected_root
	}
	process, spawn_err := os.process_start(os.Process_Desc{
		command     = argv[:],
		stdin       = stdin_r,
		stdout      = stdout_w,
		working_dir = working_dir,
	})

	// Close the child's ends — bridge does not use them.
	os.close(stdin_r)
	os.close(stdout_w)

	if spawn_err != nil {
		os.close(stdin_w)
		os.close(stdout_r)
		send_result(conn, session_id, command_id, false, "process_start failed")
		fmt.println("bridge lsp_start: spawn failed for session", session_id, spawn_err)
		return
	}

	// Register the session.
	sess := Bridge_Lsp_Session{
		session_id    = strings.clone(session_id,  lsp_heap()),
		language      = strings.clone(language,    lsp_heap()),
		cmd           = strings.clone(cmd_str,     lsp_heap()),
		cwd           = strings.clone(working_dir, lsp_heap()),
		owner_user_id = strings.clone(owner_uid,   lsp_heap()),
		pid           = process.pid,
		status        = .Running,
		stdin_w       = stdin_w,
		process       = process,
		process_slot  = true,
	}
	bridge_lsp_session_register(sess)
	process_slot_owned = false

	// Launch background read loop.
	ctx       := new(Bridge_Lsp_Read_Ctx, lsp_heap())
	ctx.session_id = strings.clone(session_id, lsp_heap())
	ctx.stdout_r   = stdout_r
	ctx.process    = process
	thread.run_with_data(rawptr(ctx), bridge_lsp_read_worker)

	fmt.println("bridge lsp_start: session", session_id, "pid", process.pid, "cmd", cmd_str)
	send_result(conn, session_id, command_id, true, "", detected_root)
}

// ---- lsp_stop: terminate server process -------------------------------------

bridge_lsp_handle_stop :: proc(conn: ^ws.Connection, text: string) {
	command_id := extract_json_string(text, "command_id", "")
	session_id := extract_json_string(text, "session_id", "")
	defer { delete(command_id); delete(session_id) }

	send_result :: proc(conn: ^ws.Connection, session_id, command_id: string) {
		b := strings.builder_make()
		strings.write_string(&b, "{\"type\":\"lsp_stopped\",\"session_id\":\"")
		bridge_runtime_write_json_string(&b, session_id)
		strings.write_string(&b, "\",\"command_id\":\"")
		bridge_runtime_write_json_string(&b, command_id)
		strings.write_string(&b, "\"}")
		result := strings.to_string(b)
		defer delete(result)
		if conn != nil do _ = bridge_hub_send(conn, result)
	}

	// Close stdin to signal EOF to the language server; it typically exits cleanly.
	if stdin_w := bridge_lsp_session_take_stdin_w(session_id); stdin_w != nil {
		os.close(stdin_w)
	}

	// SIGTERM the process so it shuts down even if it ignores EOF.
	if bridge_lsp_session_exists(session_id) {
		if pid := bridge_lsp_session_pid(session_id); pid > 0 {
			_ = posix.kill(posix.pid_t(pid), .SIGTERM)
		}
		// A requested stop is a clean shutdown, not a failure. .Failed is
		// reserved for spawn errors and unexpected exits so the status field
		// stays meaningful to the UI.
		bridge_lsp_session_set_status(session_id, .Exited)
	}

	send_result(conn, session_id, command_id)
}

// ---- lsp_send: forward JSON-RPC message to server ---------------------------

bridge_lsp_handle_send :: proc(text: string) {
	session_id := extract_json_string(text, "session_id", "")
	message    := extract_json_string(text, "message",    "")
	defer { delete(session_id); delete(message) }
	if message == "" do return

	// Build the Content-Length frame: "Content-Length: N\r\n\r\n<body>"
	// N is the byte count of the JSON body.
	//
	// NOTE: tprintf returns TEMP-allocator memory — it must NOT be delete()d
	// (that is a bad free against the context allocator). This runs on the WS
	// command thread for every outbound message, so reclaim the temp arena
	// explicitly rather than letting it grow for the life of the bridge.
	defer free_all(context.temp_allocator)
	header := fmt.tprintf("Content-Length: %d\r\n\r\n", len(message))

	// The liveness check and both writes happen under the map lock, so a
	// concurrent lsp_stop cannot close stdin_w between them (N1). Header and
	// body are separate chunks so no concatenated buffer is allocated.
	_ = bridge_lsp_session_write_stdin(
		session_id,
		transmute([]byte)header,
		transmute([]byte)message,
	)
}

// ---- cleanup on WS disconnect -----------------------------------------------

// bridge_lsp_stop_all kills every active LSP session. Called when the hub WS
// drops so orphaned server processes do not accumulate between reconnects.
bridge_lsp_stop_all :: proc() {
	// Cloned ids, not struct snapshots: a snapshot's strings can be freed by
	// bridge_lsp_session_remove the moment the lock is released.
	ids := bridge_lsp_active_session_ids()
	defer {
		// C1: these ids were cloned with lsp_heap() (bridge_lsp_active_session_ids),
		// so they must be freed with it — a bare delete() would go to
		// context.allocator, the same mismatch as B2. No test reaches this proc
		// (its only caller is the hub-WS-disconnect path), so the suite cannot
		// catch a slip here; the file's allocator rule at the top is the guard.
		for id in ids do delete(id, lsp_heap())
		delete(ids) // dynamic array carries its own allocator
	}

	for id in ids {
		// Take the fd under lock, then close outside.
		if w := bridge_lsp_session_take_stdin_w(id); w != nil {
			os.close(w)
		}
		if pid := bridge_lsp_session_pid(id); pid > 0 {
			_ = posix.kill(posix.pid_t(pid), .SIGTERM)
		}
		// A forced kill on WS disconnect, not a clean shutdown — .Failed.
		bridge_lsp_session_set_status(id, .Failed)
	}
}
