package http

// REQ-LSP-RLY-1: Hub WS relay for LSP sessions.
//
// Carries JSON-RPC between the browser and the bridge's LSP session
// (src/bridge/lsp_session.odin, REQ-LSP-BR-1). Modelled on
// shell_session_stream_handler in shell_session_handlers.odin — same ticket auth,
// same upgrade, same relay shape — with three deliberate differences, each decided
// by the coordinator on the task and recorded here so the next reader does not
// "fix" them back:
//
//  1. NO PERSISTED SESSION. A shell session is a row in shell_sessions and the
//     shell handler checks ownership by reading it. An LSP session has no table and
//     no migration: it is bound to a live socket AND a live process in the bridge's
//     own in-memory map, so a row would outlive both and need reaper logic. You
//     reattach to a terminal; you do not reattach to a language server. The socket
//     dying is the session ending.
//  2. OWNERSHIP IS STRUCTURAL, NOT A CHECK. The registry is keyed by
//     (owner_user_id, session_id), so two users who pick the same session id string
//     occupy different entries and cannot reach each other's. There is no
//     owner_user_id comparison to forget. The URL segment is therefore a plain
//     client-supplied id and needs no unguessability — it is namespaced by the
//     authenticated user.
//  3. START PARAMETERS ARRIVE AS A FRAME, NOT QUERY PARAMS. The browser sends
//     {"type":"start","bridge_id":..,"language":..,"file_path":..} after the
//     upgrade. THE BROWSER NEVER SUPPLIES cmd OR args: the Hub resolves those from
//     the operator's stored config (REQ-LSP-CFG-1). A browser-supplied cmd would be
//     arbitrary code execution on the bridge host, which is the security boundary
//     of this whole feature. file_path also changes as the user opens files, and a
//     query param would fix it at connect time and force a reconnect per file.

import "core:net"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import bridge_service "odin_test:hub/service/bridge"
import project_service "odin_test:hub/service/project"
import metrics "odin_test:lib/metrics"
import ws "odin_test:lib/ws"


// LSP_EXPERIMENT_KEY gates the whole feature (REQ-EXP-1).
LSP_EXPERIMENT_KEY :: "lsp"

// LSP_IDLE_TIMEOUT bounds a silent socket. It is far longer than the shell
// stream's 120s because an editor can legitimately sit idle with a language
// server attached and no traffic in either direction, whereas a terminal that
// silent is usually gone. Clients that want to hold a session open past this
// send {"type":"ping"} and get {"type":"pong"} back.
LSP_IDLE_TIMEOUT :: 15 * time.Minute

// --- session registry --------------------------------------------------------

Lsp_Session_Entry :: struct {
	owner_user_id: string, // owned
	session_id:    string, // owned; the client-supplied id
	wire_id:       string, // owned; the id used on the bridge wire
	bridge_id:     string, // owned; empty until "start" succeeds
	// The two map keys, owned by the entry. Odin's delete_key removes the slot
	// but hands back no allocation, so the entry keeps the exact strings that
	// were inserted and frees them itself on release.
	owner_key:     string,
	wire_key:      string,
	socket:        net.TCP_Socket,
	started:       bool,
	// closing marks the session dead: the relay must unwind and release it. It is
	// set by the bridge-disconnect teardown AND by a failed write (REQ-LSP-RLY-2).
	closing:       bool,
	// bridge_gone narrows that to "the BRIDGE is what went away", which is the
	// only case where the language server process died on its own. It must stay
	// distinct from closing: the relay's teardown skips send_lsp_stop on it, so
	// setting it for a merely-dead session would strand a live language server on
	// the bridge host. See lsp_should_stop_on_bridge.
	bridge_gone:   bool,
}

// Lsp_Session_Registry holds the live relays. Two indexes over the same entries:
// by wire id (what bridge frames carry) and by owner+session id (what the browser
// names and what makes cross-user access structurally impossible).
Lsp_Session_Registry :: struct {
	mu:       sync.Mutex,
	by_wire:  map[string]^Lsp_Session_Entry,
	by_owner: map[string]^Lsp_Session_Entry,
	// send_timeout overrides LSP_SEND_TIMEOUT for sockets claimed on this
	// registry; zero (the production value — nothing ever sets it) means use the
	// constant. It lives HERE rather than in a package-level variable on purpose:
	// `odin test` runs tests in parallel, so a mutable global would let one test's
	// override leak into another's socket and make both flaky. A per-registry
	// field is private to whoever owns the registry, which in tests is one test.
	send_timeout: time.Duration,
}

// lsp_owner_key namespaces a client session id by its owner. The NUL separator
// cannot occur in either half of a JSON string value that reached us as a path
// segment, so distinct pairs cannot collide into one key.
lsp_owner_key :: proc(owner_user_id, session_id: string, allocator := context.allocator) -> string {
	return strings.concatenate({owner_user_id, "\x00", session_id}, allocator)
}

// lsp_registry_claim reserves (owner, session_id) and returns the new entry.
// ok=false means that pair is already live: a second socket for it is a conflict,
// never a silent replacement, or a duplicate browser tab would kill a working
// session out from under the first one.
lsp_registry_claim :: proc(reg: ^Lsp_Session_Registry, owner_user_id, session_id, wire_id: string, socket: net.TCP_Socket) -> (^Lsp_Session_Entry, bool) {
	if reg == nil do return nil, false
	sync.mutex_lock(&reg.mu)
	defer sync.mutex_unlock(&reg.mu)

	key := lsp_owner_key(owner_user_id, session_id)
	if _, exists := reg.by_owner[key]; exists {
		delete(key)
		return nil, false
	}

	entry := new(Lsp_Session_Entry)
	entry.owner_user_id = strings.clone(owner_user_id)
	entry.session_id    = strings.clone(session_id)
	entry.wire_id       = strings.clone(wire_id)
	entry.bridge_id     = ""
	entry.owner_key     = key
	entry.wire_key      = strings.clone(wire_id)
	entry.socket        = socket
	entry.started       = false
	entry.closing       = false
	entry.bridge_gone   = false

	// Bound writes on this socket against a NON-PROGRESSING peer (REQ-LSP-RLY-2).
	// Claim is the one choke point: every frame the Hub ever writes to this browser
	// goes to entry.socket, and claim happens before the upgrade response, so
	// nothing is written before the bound is in place. SO_SNDTIMEO touches ONLY the
	// send side, so the relay thread's parked recv and its own .Receive_Timeout are
	// unaffected — the reader remains the socket's sole closer.
	//
	// KNOW WHAT THIS DOES AND DOES NOT GUARANTEE. SO_SNDTIMEO bounds each send()
	// SYSCALL, not the frame. Linux socket(7): a blocked send returns a partial
	// count, or EWOULDBLOCK if nothing was sent. core/net _send_tcp only exits its
	// loop on an errno, so a partial count with NO error loops into a FRESH timeout
	// window. Therefore:
	//   - a peer making NO progress (the wedged tab this ticket is about) is bounded
	//     at one timeout, which is the defect being fixed;
	//   - a peer that TRICKLES is bounded by its own throughput, not by this value.
	//     A browser absorbing 500KB at 10KB/s holds the lock ~50s without the
	//     timeout ever firing.
	// The trickling case is NOT addressed here and is not this ticket's subject.
	send_timeout := reg.send_timeout
	if send_timeout <= 0 do send_timeout = LSP_SEND_TIMEOUT
	_ = net.set_option(socket, .Send_Timeout, send_timeout)

	if reg.by_wire == nil do reg.by_wire = make(map[string]^Lsp_Session_Entry)
	if reg.by_owner == nil do reg.by_owner = make(map[string]^Lsp_Session_Entry)
	reg.by_wire[entry.wire_key]   = entry
	reg.by_owner[entry.owner_key] = entry
	return entry, true
}

// lsp_registry_release removes an entry and frees everything it owns. Safe to call
// for a wire id that is already gone.
lsp_registry_release :: proc(reg: ^Lsp_Session_Registry, wire_id: string) {
	if reg == nil do return
	sync.mutex_lock(&reg.mu)
	defer sync.mutex_unlock(&reg.mu)

	entry, found := reg.by_wire[wire_id]
	if !found || entry == nil do return

	delete_key(&reg.by_owner, entry.owner_key)
	delete_key(&reg.by_wire, entry.wire_key)

	delete(entry.owner_user_id)
	delete(entry.session_id)
	delete(entry.wire_id)
	// bridge_id is "" until a "start" succeeds, and that empty value was never
	// allocated — only free what was actually cloned.
	if entry.bridge_id != "" do delete(entry.bridge_id)
	delete(entry.owner_key)
	delete(entry.wire_key)
	free(entry)
}

// lsp_registry_mark_started records the bridge the session was started on. The
// relay needs it again at teardown to send lsp_stop.
lsp_registry_mark_started :: proc(reg: ^Lsp_Session_Registry, wire_id, bridge_id: string) {
	if reg == nil do return
	sync.mutex_lock(&reg.mu)
	defer sync.mutex_unlock(&reg.mu)
	entry, found := reg.by_wire[wire_id]
	if !found || entry == nil do return
	if entry.bridge_id != "" do delete(entry.bridge_id)
	entry.bridge_id = strings.clone(bridge_id)
	entry.started = true
}

// lsp_registry_mark_stopped records that the client stopped the server itself.
// Without this the entry stays "started" and a later bridge disconnect would tear
// down a session the user had already stopped and might be about to restart.
lsp_registry_mark_stopped :: proc(reg: ^Lsp_Session_Registry, wire_id: string) {
	if reg == nil do return
	sync.mutex_lock(&reg.mu)
	defer sync.mutex_unlock(&reg.mu)
	entry, found := reg.by_wire[wire_id]
	if !found || entry == nil do return
	if entry.bridge_id != "" do delete(entry.bridge_id)
	entry.bridge_id = ""
	entry.started = false
}

// lsp_should_stop_on_bridge reports whether the relay's teardown must still tell
// the bridge to stop the language server.
//
// This is the predicate the teardown defer consumes, named and separated so it can
// be tested directly. It keys on bridge_gone, NOT on closing: a session killed for
// a failed write (REQ-LSP-RLY-2) is dead, but its bridge is alive and its language
// server is still running, so the stop MUST go out or the process outlives the
// socket that owned it — one orphaned server per wedged tab.
//
// An unknown wire_id answers true, preserving the pre-existing behaviour that a
// released entry still gets its stop sent.
lsp_should_stop_on_bridge :: proc(reg: ^Lsp_Session_Registry, wire_id: string) -> bool {
	if reg == nil do return true
	sync.mutex_lock(&reg.mu)
	defer sync.mutex_unlock(&reg.mu)
	entry, found := reg.by_wire[wire_id]
	if !found || entry == nil do return true
	return !entry.bridge_gone
}

// lsp_session_closing reports whether this session has been marked dead, by either
// the bridge-disconnect teardown or a failed write. Read under the lock: the flag
// is set from the bridge WS thread.
lsp_session_closing :: proc(reg: ^Lsp_Session_Registry, wire_id: string) -> bool {
	if reg == nil do return false
	sync.mutex_lock(&reg.mu)
	defer sync.mutex_unlock(&reg.mu)
	entry, found := reg.by_wire[wire_id]
	if !found || entry == nil do return false
	return entry.closing
}

// lsp_registry_wake_bridge_sessions is the bridge-disconnect teardown. For every
// live session started on bridge_id it tells the browser why the session ended and
// then WAKES that session's relay thread so it unwinds and releases the entry.
//
// It deliberately does NOT close the socket and does NOT release the entry. Per
// AGENTS.md "Socket lifetime across threads" — a rule this codebase has paid for
// five times — the thread parked in recv is the socket's SOLE closer on every exit
// path; any other thread may only shutdown(.Receive) to wake it. A close from here
// would either leave the parked recv sleeping forever (it holds the struct file, so
// the socket is merely orphaned) or, if the reader were between recv calls, let its
// next recv re-resolve an fd NUMBER a new connection already owns and read a
// stranger's bytes under this session's id.
//
// Returns how many sessions were woken, so the caller can log it and tests can
// assert on it.
lsp_registry_wake_bridge_sessions :: proc(reg: ^Lsp_Session_Registry, bridge_id: string) -> int {
	if reg == nil || bridge_id == "" do return 0
	sync.mutex_lock(&reg.mu)
	defer sync.mutex_unlock(&reg.mu)

	woken := 0
	for _, entry in reg.by_wire {
		if entry == nil || !entry.started do continue
		if entry.bridge_id != bridge_id do continue
		entry.closing = true
		// The bridge is what went away, so the server process died with it. This
		// is the ONLY place this may be set — see lsp_should_stop_on_bridge.
		entry.bridge_gone = true
		// Last word to the browser while the socket is still writable: the send
		// side is untouched by shutdown(.Receive), so this frame goes out.
		//
		// This loop holds reg.mu across EVERY matching session, so with WEDGED tabs
		// the ordinary LSP_SEND_TIMEOUT would cost N x 5s of lock hold on the one
		// path whose whole purpose is recovering from a wedged peer — bounded, but a
		// weaker version of the bug this ticket is about. So the teardown write gets
		// its own much shorter bound (REQ-LSP-RLY-2 item A). N x 100ms is the bound
		// for NON-PROGRESSING peers; a trickling peer is still bounded only by its
		// own throughput (see lsp_registry_claim).
		// That is sound precisely here and nowhere else: this frame is a COURTESY,
		// the actual recovery is the shutdown below, and a browser that cannot take
		// ~60 bytes in 100ms has a full send buffer, i.e. is exactly the wedged peer
		// we are recovering from. It still learns the session ended — by the socket
		// closing when the relay unwinds.
		_ = net.set_option(entry.socket, .Send_Timeout, LSP_TEARDOWN_SEND_TIMEOUT)
		frame := lsp_error_frame(entry.session_id, "bridge disconnected")
		ws_note_write_ok(project_service.WS_KIND_LSP, ws_bytes_series(project_service.WS_KIND_LSP, "tx", ""), lsp_write_ws_text_frame(entry.socket, frame), len(frame))
		delete(frame)
		// Wake the parked reader; it owns the close.
		_ = net.shutdown(entry.socket, .Receive)
		woken += 1
	}
	return woken
}

// lsp_registry_deliver writes one already-built frame to the browser socket for
// wire_id. The write happens under the registry lock so a bridge thread's frame
// can never interleave with another thread's into a corrupt frame, and so the
// socket cannot be released underneath the write.
lsp_registry_deliver :: proc(reg: ^Lsp_Session_Registry, wire_id, text: string) -> bool {
	if reg == nil do return false
	sync.mutex_lock(&reg.mu)
	defer sync.mutex_unlock(&reg.mu)
	entry, found := reg.by_wire[wire_id]
	if !found || entry == nil do return false
	res := ws.write_server_text(entry.socket, text, true)
	ws_note_write(project_service.WS_KIND_LSP, ws_bytes_series(project_service.WS_KIND_LSP, "tx", ""), res, len(text))
	if res == .Ok do return true

	// The write did not complete: either the peer is wedged (sent == 0, the send
	// timeout expired having moved nothing) or, worse, half a frame is already on
	// the wire (sent > 0) and this browser's stream can never resynchronise. Both
	// end the session. A dead session is visible to the user and to the relay; a
	// desynchronised one looks alive and serves corruption.
	//
	// We do NOT close the socket here. Per AGENTS.md "Socket lifetime across
	// threads", the thread parked in recv is the sole closer on every exit path;
	// this thread may only mark the session and wake that reader, exactly as
	// lsp_registry_wake_bridge_sessions does.
	entry.closing = true
	_ = net.shutdown(entry.socket, .Receive)
	return false
}

// --- WebSocket framing for the browser socket --------------------------------
//
// WebSocket server writes route canonically through ws.write_server_text
// (src/lib/ws/server_frame.odin) and client reads route canonically through
// ws.Frame_Reader (src/lib/ws/reader.odin).

// LSP_SEND_TIMEOUT bounds how long one send() syscall to a browser socket may
// block on a peer that is not draining, and therefore how long the registry lock
// can be held against a wedged peer (REQ-LSP-RLY-2). Five seconds.
LSP_SEND_TIMEOUT :: 5 * time.Second

// LSP_TEARDOWN_SEND_TIMEOUT bounds the courtesy frame on the bridge-disconnect
// path, which writes to every affected session under one lock hold.
LSP_TEARDOWN_SEND_TIMEOUT :: 100 * time.Millisecond

lsp_ws_frame_header :: proc(out: []byte, n: int) -> int {
	return ws.server_frame_header(out, n)
}


lsp_ws_header_len :: proc(n: int) -> int {
	return ws.server_frame_header_len(n)
}

lsp_write_ws_text_frame_counted :: proc(client: net.TCP_Socket, text: string) -> (sent: int, ok: bool) {
	written, res := ws.write_server_text_counted(client, text, true)
	return written, res == .Ok
}

lsp_write_ws_text_frame :: proc(client: net.TCP_Socket, text: string) -> bool {
	return ws.write_server_text(client, text, true) == .Ok
}

Lsp_WS_Reader :: ws.Frame_Reader
LSP_MAX_MESSAGE_BYTES :: ws.WS_CONTINUATION_DEFAULT_MAX_BYTES

lsp_ws_reader_make :: proc(socket: net.TCP_Socket) -> Lsp_WS_Reader {
	return ws.reader_make(socket = socket, allow_64bit = true)
}

lsp_ws_reader_destroy :: proc(reader: ^Lsp_WS_Reader) {
	ws.reader_destroy(reader)
}

lsp_ws_take_frame :: proc(reader: ^Lsp_WS_Reader) -> (text: string, ok: bool, fatal: bool) {
	op, payload, has_frame, res_ok := ws.take_frame(reader)
	if !res_ok {
		return "", false, true
	}
	if !has_frame {
		return "", false, false
	}
	if op == 0x8 {
		delete(payload)
		return "", false, true
	}
	return payload, true, false
}

lsp_read_ws_text_blocking :: proc(reader: ^Lsp_WS_Reader, timeout: time.Duration) -> (string, bool) {
	return ws.read_text_blocking(reader.socket, reader, timeout)
}


// --- bridge -> browser fan-out ----------------------------------------------

// lsp_forward_bridge_frame rewrites one bridge frame for the browser and delivers
// it. The session_id on the wire is the Hub's opaque wire id; the browser only
// ever knows the id IT chose, so the field is translated rather than passed
// through. Returns false when no live session owns the frame (a late frame from a
// session whose socket already went away) — the caller drops it.
//
// Called from the bridge WS thread (bridge_handlers.odin), not a request thread,
// so nothing here may rely on the per-request arena.
lsp_forward_bridge_frame :: proc(reg: ^Lsp_Session_Registry, frame_type, text: string) -> bool {
	if reg == nil do return false
	wire_id := json_string(text, "session_id")
	defer delete(wire_id)
	if wire_id == "" do return false

	client_session_id, found := lsp_client_session_id(reg, wire_id)
	if !found do return false
	defer delete(client_session_id)

	out := lsp_bridge_frame_for_client(frame_type, text, client_session_id)
	defer delete(out)
	return lsp_registry_deliver(reg, wire_id, out)
}

// lsp_bridge_frame_for_client rebuilds one bridge frame with the browser's own
// session id in place of the wire id, carrying across only the fields that
// direction defines. Pure, so the translation is testable on its own.
lsp_bridge_frame_for_client :: proc(frame_type, text, client_session_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"")
	write_handler_json_string(&b, frame_type)
	strings.write_string(&b, "\",\"session_id\":\"")
	write_handler_json_string(&b, client_session_id)
	strings.write_byte(&b, '"')

	switch frame_type {
	case "lsp_data":
		message := json_string(text, "message")
		defer delete(message)
		strings.write_string(&b, ",\"message\":\"")
		write_handler_json_string(&b, message)
		strings.write_byte(&b, '"')
	case "lsp_error":
		reason := json_string(text, "reason")
		defer delete(reason)
		strings.write_string(&b, ",\"reason\":\"")
		write_handler_json_string(&b, reason)
		strings.write_string(&b, "\",\"exit_code\":")
		strings.write_int(&b, json_int(text, "exit_code", 0))
	case "lsp_started":
		ok_val := json_bool_value(text, "ok")
		strings.write_string(&b, ",\"ok\":")
		strings.write_string(&b, "true" if ok_val else "false")
		if !ok_val {
			// REQ-ERR-PROTO-A: relay the bridge's typed error object unchanged.
			werr, _ := contracts.wire_error_parse(text, context.temp_allocator)
			strings.write_string(&b, ",\"error\":")
			contracts.write_wire_error(&b, werr)
		} else {
			root_path := json_string(text, "root_path")
			defer delete(root_path)
			if root_path != "" {
				strings.write_string(&b, ",\"root_path\":\"")
				write_handler_json_string(&b, root_path)
				strings.write_byte(&b, '"')
			}
		}
	case "lsp_stopped":
	// no payload beyond the type and session id
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// lsp_client_session_id maps a wire id back to the id the browser chose. The
// returned string is a clone the caller frees, so it cannot dangle if the entry
// is released the moment the lock drops.
lsp_client_session_id :: proc(reg: ^Lsp_Session_Registry, wire_id: string) -> (string, bool) {
	if reg == nil do return "", false
	sync.mutex_lock(&reg.mu)
	defer sync.mutex_unlock(&reg.mu)
	entry, found := reg.by_wire[wire_id]
	if !found || entry == nil do return "", false
	return strings.clone(entry.session_id), true
}

// --- handler -----------------------------------------------------------------

Lsp_Session_Stream_Handlers :: struct {
	ws_tickets:          ^User_WS_Ticket_Store,
	bridges:             ^bridge_service.Bridge_Service,
	experiments:         ^iface.Experiment_Repository,
	lsp_configs:         ^iface.Lsp_Server_Config_Repository,
	sessions:            ^Lsp_Session_Registry,
	ids:                 ^platform.ID_Generator,
	bridge_command_sink: project_service.Bridge_Command_Sink,
}

// lsp_experiment_enabled reports the "lsp" flag for this user. The experiment
// repository exposes only set and list_by_owner — there is no get-by-key — so the
// owner's flags are listed and scanned. Absent means off.
lsp_experiment_enabled :: proc(repo: ^iface.Experiment_Repository, owner_user_id: string) -> bool {
	exps, err := iface.experiment_list_by_owner(repo, owner_user_id)
	if err.code != .None do return false
	defer {
		for exp in exps {
			delete(exp.owner_user_id)
			delete(exp.key)
			delete(exp.updated_at)
		}
		delete(exps)
	}
	for exp in exps {
		if exp.key == LSP_EXPERIMENT_KEY do return exp.enabled
	}
	return false
}

// lsp_resolve_server picks the configured server for (bridge, language, file_path)
// using the REQ-LSP-CFG-1 resolver. Returns a config whose strings the caller must
// free with domain.lsp_server_config_destroy.
//
// This runs on the relay thread, which is NOT covered by the per-request arena, so
// the intermediate list is an explicit allocation rather than temp_allocator.
lsp_resolve_server :: proc(repo: ^iface.Lsp_Server_Config_Repository, owner_user_id, bridge_id, language, file_path: string) -> (domain.Lsp_Server_Config, bool) {
	all_configs, err := iface.lsp_server_config_list_by_bridge(repo, owner_user_id, bridge_id)
	if err.code != .None do return domain.Lsp_Server_Config{}, false
	defer domain.lsp_server_configs_destroy(all_configs)

	lang_configs := make([dynamic]domain.Lsp_Server_Config)
	defer delete(lang_configs)
	for c in all_configs {
		if domain.lsp_server_config_matches_language_or_ext(c, language, file_path) {
			append(&lang_configs, c)
		}
	}

	cfg, found := domain.lsp_server_config_resolve(lang_configs[:], file_path)
	if !found do return domain.Lsp_Server_Config{}, false
	// The resolved config aliases strings owned by all_configs, which is freed on
	// return — hand back a deep copy instead.
	return lsp_server_config_clone(cfg), true
}

lsp_server_config_clone :: proc(c: domain.Lsp_Server_Config) -> domain.Lsp_Server_Config {
	return domain.Lsp_Server_Config{
		config_id       = strings.clone(c.config_id),
		owner_user_id   = strings.clone(c.owner_user_id),
		bridge_id       = strings.clone(c.bridge_id),
		language        = strings.clone(c.language),
		cmd             = strings.clone(c.cmd),
		args            = strings.clone(c.args),
		file_extensions = strings.clone(c.file_extensions),
		root_markers    = strings.clone(c.root_markers),
		dir_prefix      = strings.clone(c.dir_prefix),
		dir_pattern     = strings.clone(c.dir_pattern),
		created_at      = strings.clone(c.created_at),
		updated_at      = strings.clone(c.updated_at),
	}
}

// lsp_working_dir chooses the language server's cwd: the config's dir_prefix when
// the operator set one (that is exactly "this server serves this tree"), otherwise
// the directory holding the file.
//
// root_markers is deliberately NOT consulted here, and it cannot be: this proc runs in
// the Hub and resolves the cwd by pure string manipulation, but the files live on the
// BRIDGE host. Walking upward for a marker from here would search the Hub's own
// filesystem — the wrong machine — and could pick a stray .git as a nonsense root.
// Root detection therefore belongs in src/bridge/lsp_session.odin, where the process is
// spawned and the filesystem is the right one, which also means root_markers must first
// be added to the lsp_start wire payload (it is not on the wire today).
// Resolved by REQ-LSP-CFG-4: the column and its round-trip stay, the Settings > LSP field
// is hidden until something reads it, and the bridge-side implementation is deferred
// until the relay has run end to end (REQ-LSP-E2E-1). No open question here.
lsp_working_dir :: proc(cfg: domain.Lsp_Server_Config, file_path: string, root_path: string = "") -> string {
	if strings.trim_space(cfg.dir_prefix) != "" do return strings.clone(cfg.dir_prefix)
	if strings.trim_space(root_path) != "" do return strings.clone(root_path)
	slash := strings.last_index_byte(file_path, '/')
	if slash <= 0 do return strings.clone("")
	return strings.clone(file_path[:slash])
}

lsp_simple_frame :: proc(frame_type, session_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"")
	write_handler_json_string(&b, frame_type)
	strings.write_string(&b, "\",\"session_id\":\"")
	write_handler_json_string(&b, session_id)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

lsp_error_frame :: proc(session_id, reason: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"lsp_error\",\"session_id\":\"")
	write_handler_json_string(&b, session_id)
	strings.write_string(&b, "\",\"reason\":\"")
	write_handler_json_string(&b, reason)
	strings.write_string(&b, "\",\"exit_code\":0}")
	return strings.to_string(b)
}

// GET /api/v1/lsp/{session_id}/stream — WS upgrade carrying JSON-RPC both ways.
//
// Refusals happen BEFORE the upgrade and as plain HTTP errors: a socket that
// upgrades and then closes tells the client nothing about why.
lsp_session_stream_handler :: proc(ctx: rawptr, req: Request, client: net.TCP_Socket) {
	h := (^Lsp_Session_Stream_Handlers)(ctx)

	ticket := query_value(req.query, "ticket")
	if ticket == "" {
		project_service.ws_track_rejected(project_service.WS_KIND_LSP, "auth_failed")
		write_http_response(client, respond_error(domain.domain_error(.Unauthenticated, "websocket ticket required for lsp stream"), req.request_id))
		return
	}
	auth_ctx, auth_ok := user_ws_ticket_store_consume(h.ws_tickets, ticket)
	if !auth_ok {
		project_service.ws_track_rejected(project_service.WS_KIND_LSP, "auth_failed")
		write_http_response(client, respond_error(domain.domain_error(.Unauthenticated, "websocket ticket is invalid or expired"), req.request_id))
		return
	}

	// Experiment gate (REQ-EXP-1): with the flag off the route refuses outright.
	if !lsp_experiment_enabled(h.experiments, auth_ctx.user_id) {
		project_service.ws_track_rejected(project_service.WS_KIND_LSP, "auth_failed")
		write_http_response(client, respond_error(domain.domain_error(.Forbidden, "the lsp experiment is not enabled for this user"), req.request_id))
		return
	}

	session_id := path_part(req.path, 4)
	if session_id == "" || strings.contains(session_id, "/") {
		project_service.ws_track_rejected(project_service.WS_KIND_LSP, "bad_request")
		write_http_response(client, respond_error(domain.domain_error(.Validation_Failed, "session id is required"), req.request_id))
		return
	}

	key := header_value(req.headers, "Sec-WebSocket-Key")
	if key == "" {
		project_service.ws_track_rejected(project_service.WS_KIND_LSP, "bad_request")
		write_http_response(client, respond_error(domain.domain_error(.Validation_Failed, "missing websocket key"), req.request_id))
		return
	}

	// The wire id is what the bridge keys its session map by. It is generated
	// here, never taken from the client, so two users who both pick session id
	// "main" get two different language servers instead of one shared one.
	// platform.generate_id returns fmt.tprintf memory — a TEMP-ALLOCATOR string.
	// It must be cloned onto the heap for two independent reasons:
	//   1. delete() on a temp string frees it against context.allocator, which is
	//      a bad free (the same defect the tracking allocator reports elsewhere in
	//      this tree).
	//   2. wire_id lives for the whole session and is read on every frame. The
	//      per-thread temp ring wraps as a long-lived relay keeps allocating, and
	//      once it wraps it reuses those bytes IN PLACE — silently corrupting the
	//      session id in every frame sent after that point. shell_session_handlers
	//      hit exactly this and documents it around its stream_id.
	generated := ""
	if h.ids != nil do generated = platform.generate_id(h.ids, "lsp_")
	if generated == "" {
		project_service.ws_track_rejected(project_service.WS_KIND_LSP, "other")
		write_http_response(client, respond_error(domain.domain_error(.Internal_Error, "could not allocate an lsp session id"), req.request_id))
		return
	}
	wire_id := strings.clone(generated)
	defer delete(wire_id)

	entry, claimed := lsp_registry_claim(h.sessions, auth_ctx.user_id, session_id, wire_id, client)
	if !claimed {
		project_service.ws_track_rejected(project_service.WS_KIND_LSP, "conflict")
		write_http_response(client, respond_error(domain.domain_error(.Conflict, "an lsp session with this id is already open"), req.request_id))
		return
	}
	// From here the entry owns its strings; release frees them and unregisters.
	defer lsp_registry_release(h.sessions, wire_id)

	if !write_user_ws_upgrade_response(client, user_ws_accept_key(key)) {
		project_service.ws_track_rejected(project_service.WS_KIND_LSP, "other")
		return
	}

	// Telemetry (plan 3.4/3.6). LSP streams carry no bridge_id on ws_bytes (the
	// bridge is chosen per "start" frame, after the connection exists). Bridge->browser
	// frames are counted in lsp_registry_deliver; handler-originated frames here.
	ws_opened := project_service.ws_track_open(project_service.WS_KIND_LSP)
	ws_close_reason := "error"
	defer project_service.ws_track_close(project_service.WS_KIND_LSP, ws_opened, ws_close_reason)
	ws_rx := ws_bytes_series(project_service.WS_KIND_LSP, "rx", "")
	ws_tx := ws_bytes_series(project_service.WS_KIND_LSP, "tx", "")
	lsp_gauge: ^metrics.Series // heimdall_lsp_sessions{language} while started
	defer if lsp_gauge != nil do lsp_session_stopped(lsp_gauge)

	ready := lsp_simple_frame("ready", session_id)
	ws_note_write_ok(project_service.WS_KIND_LSP, ws_tx, lsp_write_ws_text_frame(client, ready), len(ready))
	delete(ready)

	reader := lsp_ws_reader_make(client)
	defer lsp_ws_reader_destroy(&reader)

	// Teardown: a session that was started must be stopped on the bridge, or the
	// language server outlives the socket that owned it. bridge_id is read from
	// the entry because "start" may have set it after the claim.
	started_bridge_id := ""
	defer {
		if started_bridge_id != "" {
			// Skip the stop ONLY when the bridge itself is what went away: the
			// server process died with it, and send_lsp_stop would only fail an
			// offline bridge lookup. Any other death — including a session killed
			// for a failed write — leaves a live server that must be stopped.
			if lsp_should_stop_on_bridge(h.sessions, wire_id) {
				bridge_service.send_lsp_stop(h.bridges, auth_ctx, started_bridge_id, wire_id, h.bridge_command_sink)
			}
			delete(started_bridge_id)
		}
	}

	guard := stream_auth_guard_make(h.ws_tickets.auth if h.ws_tickets != nil else nil, auth_ctx)
	for {
		text, ok := lsp_read_ws_text_blocking(&reader, LSP_IDLE_TIMEOUT)
		if !ok {
			ws_close_reason = lsp_ws_close_reason(h.sessions, wire_id, reader.disconnect_reason)
			return
		}
		// Logout / session expiry ends the language-server stream at the next frame.
		if !stream_auth_still_valid(&guard) {
			ws_close_reason = "auth_revoked"
			return
		}
		defer delete(text)
		ws_note_rx(ws_rx, len(text))

		frame_type := json_string(text, "type")
		defer delete(frame_type)

		switch frame_type {
		case "start":
			if started_bridge_id != "" {
				frame := lsp_error_frame(session_id, "session is already started")
				ws_note_write_ok(project_service.WS_KIND_LSP, ws_tx, lsp_write_ws_text_frame(client, frame), len(frame))
				delete(frame)
				continue
			}
			bridge_id := json_string(text, "bridge_id")
			language  := json_string(text, "language")
			file_path := json_string(text, "file_path")
			root_path := json_string(text, "root_path")
			defer {
				delete(bridge_id)
				delete(language)
				delete(file_path)
				delete(root_path)
			}
			if strings.trim_space(bridge_id) == "" || strings.trim_space(language) == "" {
				frame := lsp_error_frame(session_id, "start requires bridge_id and language")
				ws_note_write_ok(project_service.WS_KIND_LSP, ws_tx, lsp_write_ws_text_frame(client, frame), len(frame))
				delete(frame)
				continue
			}

			cfg, resolved := lsp_resolve_server(h.lsp_configs, auth_ctx.user_id, bridge_id, language, file_path)
			if !resolved {
				frame := lsp_error_frame(session_id, "no lsp server is configured for this language and path")
				ws_note_write_ok(project_service.WS_KIND_LSP, ws_tx, lsp_write_ws_text_frame(client, frame), len(frame))
				delete(frame)
				continue
			}
			defer domain.lsp_server_config_destroy(cfg)

			cwd := lsp_working_dir(cfg, file_path, root_path)
			defer delete(cwd)

			sent, send_err := bridge_service.send_lsp_start(
				h.bridges, auth_ctx, bridge_id, wire_id,
				language, cfg.cmd, cfg.args, cwd, auth_ctx.user_id,
				cfg.root_markers, file_path,
				h.bridge_command_sink,
			)
			if !sent {
				frame := lsp_error_frame(session_id, send_err.message)
				ws_note_write_ok(project_service.WS_KIND_LSP, ws_tx, lsp_write_ws_text_frame(client, frame), len(frame))
				delete(frame)
				continue
			}
			started_bridge_id = strings.clone(bridge_id)
			lsp_registry_mark_started(h.sessions, wire_id, bridge_id)
			lsp_gauge = lsp_session_started(language)
			_ = entry

		case "send":
			if started_bridge_id == "" {
				frame := lsp_error_frame(session_id, "session is not started")
				ws_note_write_ok(project_service.WS_KIND_LSP, ws_tx, lsp_write_ws_text_frame(client, frame), len(frame))
				delete(frame)
				continue
			}
			message := json_string(text, "message")
			defer delete(message)
			if message == "" do continue
			bridge_service.send_lsp_message(h.bridges, auth_ctx, started_bridge_id, wire_id, message, h.bridge_command_sink)

		case "stop":
			if started_bridge_id == "" do continue
			bridge_service.send_lsp_stop(h.bridges, auth_ctx, started_bridge_id, wire_id, h.bridge_command_sink)
			delete(started_bridge_id)
			started_bridge_id = ""
			lsp_registry_mark_stopped(h.sessions, wire_id)
			if lsp_gauge != nil { lsp_session_stopped(lsp_gauge); lsp_gauge = nil }

		case "ping":
			frame := lsp_simple_frame("pong", session_id)
			ws_note_write_ok(project_service.WS_KIND_LSP, ws_tx, lsp_write_ws_text_frame(client, frame), len(frame))
			delete(frame)
		}
	}
}

// lsp_ws_close_reason picks the heimdall_ws_disconnects_total reason for an LSP
// relay that is unwinding: a session the hub itself marked dead (bridge gone, or a
// failed write — both wake the reader with shutdown(.Receive), which the reader sees
// as a clean close) reports WHY it was marked, otherwise the reader's own reason.
lsp_ws_close_reason :: proc(reg: ^Lsp_Session_Registry, wire_id: string, read_reason: ws.Frame_Disconnect_Reason) -> string {
	if reg != nil {
		sync.mutex_lock(&reg.mu)
		defer sync.mutex_unlock(&reg.mu)
		if entry, found := reg.by_wire[wire_id]; found && entry != nil && entry.closing {
			return "bridge_offline" if entry.bridge_gone else "write_failed"
		}
	}
	return ws_disconnect_reason_string(read_reason)
}

// auth_ctx is carried by value into the teardown defer above; this reference keeps
// the contracts import honest when the file is read in isolation.
_ :: contracts
