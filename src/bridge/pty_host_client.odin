package main

// BR-2: Odin client for the ham-pty-host multi-agent daemon (HOST-1).
//
// This speaks the daemon's instance-scoped wire protocol (tools/pty_host/src/
// dproto.rs) so the bridge can drive N agents over one unix socket instead of
// tmux. The framing is a u32 big-endian length prefix followed by a tagged
// payload; every data-plane frame carries an instance id. This module is a
// byte-for-byte port of the dproto codec plus a blocking request/response helper
// and a lazy daemon starter.
//
// Kept deliberately dependency-light (pure encode/decode + a unix-socket
// round-trip) so the codec is unit-testable without a live daemon; the launch
// path (bridge_runtime_launch_agent) calls the high-level host_* ops behind the
// PTY-host runtime flag.

import local_socket "odin_test:lib/local_socket"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// ---- protocol tags (must match dproto.rs) -------------------------------

PTY_HOST_T_SPAWN :: 0x20
PTY_HOST_T_CLOSE :: 0x21
PTY_HOST_T_RESTART :: 0x22
PTY_HOST_T_LIST :: 0x23
PTY_HOST_T_ATTACH :: 0x30
PTY_HOST_T_INPUT :: 0x31
PTY_HOST_T_KEY :: 0x32
PTY_HOST_T_RESIZE :: 0x33
PTY_HOST_T_CAPTURE :: 0x34
PTY_HOST_T_DETACH :: 0x35
PTY_HOST_T_PING :: 0x36

PTY_HOST_T_SPAWNED :: 0xA0
PTY_HOST_T_CLOSED :: 0xA1
PTY_HOST_T_RESTARTED :: 0xA2
PTY_HOST_T_AGENTLIST :: 0xA3
PTY_HOST_T_OUTPUT :: 0xA4
PTY_HOST_T_SCREEN :: 0xA5
PTY_HOST_T_EXITED :: 0xA6
PTY_HOST_T_PONG :: 0xA7
PTY_HOST_T_ERROR :: 0xA8
// HOST-2 events (bridge decodes; never sent by the bridge).
PTY_HOST_T_STARTUP_READY :: 0xA9
PTY_HOST_T_STARTUP_BLOCKED :: 0xAA
PTY_HOST_T_SCREEN_CHANGED :: 0xAB
PTY_HOST_T_SHUTTING_DOWN :: 0xAC
PTY_HOST_T_HOST_HEARTBEAT :: 0xAD
PTY_HOST_T_STREAM_READY :: 0xAE
PTY_HOST_T_STREAM_CLOSED :: 0xAF
// REQ-PTY-1 (pty-host 52cebd54): Signal's reply when the target already exited.
PTY_HOST_T_ALREADY_EXITED :: 0xB0
PTY_HOST_T_WATCH_EVENTS :: 0x38
PTY_HOST_T_SIGNAL :: 0x39 // Send POSIX signal to a shell's process group (T2/REQ-SH-CONTRACT §4)
PTY_HOST_T_STARTUP_INPUT :: 0x3A
PTY_HOST_T_STARTUP_INPUT_DONE :: 0xB1
PTY_HOST_T_STARTUP_LAUNCH :: 0x3B
PTY_HOST_T_STARTUP_LAUNCH_REPLY :: 0xB2

PTY_HOST_MAX_FRAME_BYTES :: 64 * 1024 * 1024

// ---- named keys (must match proto.rs NamedKey discriminants) ------------

Pty_Host_Key :: enum u8 {
	Enter          = 1,
	Esc            = 2,
	Ctrl_C         = 3,
	Tab            = 4,
	Up             = 5,
	Down           = 6,
	Left           = 7,
	Right          = 8,
	Backspace      = 9,
	Ctrl_D         = 10,
	Ctrl_Backslash = 11,
	Home           = 12,
	End            = 13,
	Page_Up        = 14,
	Page_Down      = 15,
	Delete         = 16,
}

// ---- request/reply value types ------------------------------------------

// Pty_Host_Spawn_Request is everything the daemon needs to (re-)spawn an agent.
// The daemon remembers this so Restart re-spawns the exact same command without
// the bridge re-plumbing it. env entries are (key,value) pairs; detect is the
// opaque startup-detection JSON (stored verbatim by HOST-1, parsed in HOST-2).
Pty_Host_Spawn_Request :: struct {
	instance:         string,
	argv:             []string,
	cwd:              string, // "" => None on the wire
	env:              [][2]string,
	detect:           string, // "" => None on the wire
	display_name:     string, // "" => None on the wire
	// T4 fields: kind/tee_path appended after display_name per dproto.rs §T2.
	// Rust decoder uses backward-compat guard (off < rest.len()), so old senders
	// that omit these fields still work — just set has_* = false.
	kind:             string, // "run"|"shell"|"server"
	tee_path:         string, // absolute path; "" => None (no tee)
	has_cwd:             bool,
	has_detect:          bool,
	has_display_name:    bool,
	has_kind:            bool,
	has_tee_path:        bool,
	has_timeout_seconds: bool,
	timeout_seconds:     u64,
	rows:                u16,
	cols:                u16,
}

// Pty_Host_Agent_Info is one row of a List reply: an agent's live state.
Pty_Host_Agent_Info :: struct {
	instance_id:      string,
	program:          string,
	pid:              i32,
	alive:            bool,
	has_exit_code:    bool,
	exit_code:        i32,
	rows:             u16,
	cols:             u16,
	started_at:       u64,
	last_activity:    u64,
	display_name:     string,
	has_display_name: bool,
}

// Pty_Host_Reply is a decoded daemon->client message. kind selects the active
// fields; screen/agents/data are owned by the caller (see pty_host_reply_delete).
Pty_Host_Reply_Kind :: enum {
	Spawned,
	Closed,
	Restarted,
	Agent_List,
	Output,
	Screen,
	Child_Exited,
	Pong,
	Error,
	// HOST-2 events
	Startup_Ready,
	Startup_Blocked,
	Screen_Changed,
	// Periodic host-level liveness digest (roster + alive flags).
	Host_Heartbeat,
	// REQ-STREAM-EVENT-2: stream lifecycle events
	Stream_Ready,
	Stream_Closed,
	// Reply to Signal: the target had already exited (code = its exit code).
	Already_Exited,
	Startup_Input_Done,
	Startup_Launch,
}

// One agent's liveness entry inside a Host_Heartbeat reply.
Pty_Host_Heartbeat_Agent :: struct {
	instance_id: string,
	alive:       bool,
}

Pty_Host_Reply :: struct {
	kind:             Pty_Host_Reply_Kind,
	instance:         string,
	pid:              i32,
	code:             i32, // ChildExited code
	message:          string, // Error message / StartupBlocked safe_diagnostic
	startup_key:      string, // StartupInputDone launch fence
	reason_code:      string, // StartupBlocked reason_code
	hash:             u64, // ScreenChanged content hash
	ts_unix_ms:       u64, // HostHeartbeat timestamp
	data:             []byte, // Output bytes
	screen:           Pty_Host_Screen,
	agents:           []Pty_Host_Agent_Info,
	heartbeat_agents: []Pty_Host_Heartbeat_Agent, // HostHeartbeat roster
	has_code:         bool, // StreamClosed optional exit code
}

Pty_Host_Screen :: struct {
	rows:       u16,
	cols:       u16,
	cursor_row: u16,
	cursor_col: u16,
	lines:      []string,
}

// Pty_Host_Client wraps the daemon unix socket path for typed call sites that
// need more than a bare string (e.g. bridge_pty_host_signal).
Pty_Host_Client :: struct {
	socket: string,
}

// ---- primitive encoders (match dproto.rs put_*) -------------------------

pty_host_put_u16 :: proc(p: ^[dynamic]byte, v: u16) {
	append(p, byte(v >> 8), byte(v))
}

pty_host_put_i32 :: proc(p: ^[dynamic]byte, v: i32) {
	u := u32(v)
	append(p, byte(u >> 24), byte(u >> 16), byte(u >> 8), byte(u))
}

pty_host_put_u64 :: proc(p: ^[dynamic]byte, v: u64) {
	append(p, byte(v >> 56), byte(v >> 48), byte(v >> 40), byte(v >> 32), byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v))
}

pty_host_put_str :: proc(p: ^[dynamic]byte, s: string) {
	pty_host_put_u32(p, u32(len(s)))
	for i in 0..<len(s) do append(p, s[i])
}

pty_host_put_u32 :: proc(p: ^[dynamic]byte, v: u32) {
	append(p, byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v))
}

pty_host_put_opt_str :: proc(p: ^[dynamic]byte, present: bool, s: string) {
	if present {
		append(p, 1)
		pty_host_put_str(p, s)
	} else {
		append(p, 0)
	}
}

// ---- primitive decoders (match dproto.rs get_*) -------------------------

pty_host_get_u16 :: proc(b: []byte, off: ^int) -> (u16, bool) {
	if off^ + 2 > len(b) do return 0, false
	v := u16(b[off^]) << 8 | u16(b[off^ + 1])
	off^ += 2
	return v, true
}

pty_host_get_u32 :: proc(b: []byte, off: ^int) -> (u32, bool) {
	if off^ + 4 > len(b) do return 0, false
	v := u32(b[off^]) << 24 | u32(b[off^ + 1]) << 16 | u32(b[off^ + 2]) << 8 | u32(b[off^ + 3])
	off^ += 4
	return v, true
}

pty_host_get_i32 :: proc(b: []byte, off: ^int) -> (i32, bool) {
	v, ok := pty_host_get_u32(b, off)
	return i32(v), ok
}

pty_host_get_u64 :: proc(b: []byte, off: ^int) -> (u64, bool) {
	if off^ + 8 > len(b) do return 0, false
	v: u64 = 0
	for i in 0..<8 do v = v << 8 | u64(b[off^ + i])
	off^ += 8
	return v, true
}

// pty_host_get_str returns a CLONED string (caller owns it).
pty_host_get_str :: proc(b: []byte, off: ^int) -> (string, bool) {
	length, ok := pty_host_get_u32(b, off)
	if !ok do return "", false
	n := int(length)
	if off^ + n > len(b) do return "", false
	s := strings.clone(string(b[off^ : off^ + n]))
	off^ += n
	return s, true
}

// ---- frame IO -----------------------------------------------------------

// pty_host_frame prepends the u32 BE length prefix to a payload, returning a new
// owned buffer.
pty_host_frame :: proc(payload: []byte) -> []byte {
	out := make([dynamic]byte, 0, 4 + len(payload))
	pty_host_put_u32(&out, u32(len(payload)))
	append(&out, ..payload)
	return out[:]
}

// ---- CtlMsg encoders ----------------------------------------------------

// pty_host_encode_spawn builds a framed Spawn control message. Caller owns result.
pty_host_encode_spawn :: proc(req: Pty_Host_Spawn_Request) -> []byte {
	p := make([dynamic]byte)
	defer delete(p)
	append(&p, PTY_HOST_T_SPAWN)
	pty_host_put_str(&p, req.instance)
	pty_host_put_u16(&p, u16(len(req.argv)))
	for a in req.argv do pty_host_put_str(&p, a)
	pty_host_put_opt_str(&p, req.has_cwd, req.cwd)
	pty_host_put_u16(&p, u16(len(req.env)))
	for kv in req.env {
		pty_host_put_str(&p, kv[0])
		pty_host_put_str(&p, kv[1])
	}
	pty_host_put_opt_str(&p, req.has_detect, req.detect)
	pty_host_put_u16(&p, req.rows)
	pty_host_put_u16(&p, req.cols)
	pty_host_put_opt_str(&p, req.has_display_name, req.display_name)
	// T4/T2 backward-compat fields (dproto.rs order: kind, label, meta, tee_path).
	// Rust decoder guards each with `if off < rest.len()` so old bridges are fine.
	pty_host_put_opt_str(&p, req.has_kind, req.kind)
	pty_host_put_opt_str(&p, false, "") // label (None — display_name carries the label)
	pty_host_put_opt_str(&p, false, "") // meta  (None — not used by shell sessions)
	pty_host_put_opt_str(&p, req.has_tee_path, req.tee_path)
	if req.has_timeout_seconds {
		append(&p, 1)
		pty_host_put_u64(&p, req.timeout_seconds)
	} else {
		append(&p, 0)
	}
	return pty_host_frame(p[:])
}

pty_host_encode_instance_only :: proc(tag: byte, instance: string) -> []byte {
	p := make([dynamic]byte)
	defer delete(p)
	append(&p, tag)
	pty_host_put_str(&p, instance)
	return pty_host_frame(p[:])
}

pty_host_encode_close :: proc(instance: string) -> []byte { return pty_host_encode_instance_only(PTY_HOST_T_CLOSE, instance) }
pty_host_encode_restart :: proc(instance: string) -> []byte { return pty_host_encode_instance_only(PTY_HOST_T_RESTART, instance) }
pty_host_encode_attach :: proc(instance: string) -> []byte { return pty_host_encode_instance_only(PTY_HOST_T_ATTACH, instance) }
pty_host_encode_capture :: proc(instance: string) -> []byte { return pty_host_encode_instance_only(PTY_HOST_T_CAPTURE, instance) }
pty_host_encode_detach :: proc(instance: string) -> []byte { return pty_host_encode_instance_only(PTY_HOST_T_DETACH, instance) }
pty_host_encode_watch_events :: proc() -> []byte { p := [?]byte{PTY_HOST_T_WATCH_EVENTS}; return pty_host_frame(p[:]) }

pty_host_encode_list :: proc() -> []byte {
	p := [?]byte{PTY_HOST_T_LIST}
	return pty_host_frame(p[:])
}

pty_host_encode_ping :: proc() -> []byte {
	p := [?]byte{PTY_HOST_T_PING}
	return pty_host_frame(p[:])
}

pty_host_encode_input :: proc(instance: string, data: []byte) -> []byte {
	p := make([dynamic]byte)
	defer delete(p)
	append(&p, PTY_HOST_T_INPUT)
	pty_host_put_str(&p, instance)
	append(&p, ..data)
	return pty_host_frame(p[:])
}

pty_host_encode_startup_input :: proc(instance: string, pid: i32, launch_key: string, data: []byte) -> []byte {
	p := make([dynamic]byte)
	defer delete(p)
	append(&p, PTY_HOST_T_STARTUP_INPUT)
	pty_host_put_str(&p, instance)
	pty_host_put_i32(&p, pid)
	pty_host_put_str(&p, launch_key)
	append(&p, ..data)
	return pty_host_frame(p[:])
}

pty_host_encode_key :: proc(instance: string, key: Pty_Host_Key) -> []byte {
	p := make([dynamic]byte)
	defer delete(p)
	append(&p, PTY_HOST_T_KEY)
	pty_host_put_str(&p, instance)
	append(&p, byte(key))
	return pty_host_frame(p[:])
}

pty_host_encode_resize :: proc(instance: string, rows, cols: u16) -> []byte {
	p := make([dynamic]byte)
	defer delete(p)
	append(&p, PTY_HOST_T_RESIZE)
	pty_host_put_str(&p, instance)
	pty_host_put_u16(&p, rows)
	pty_host_put_u16(&p, cols)
	return pty_host_frame(p[:])
}

// ---- CtlReply decoder ---------------------------------------------------

// pty_host_decode_reply decodes one reply payload (tag byte + rest). On success
// the returned Pty_Host_Reply owns its heap fields (free with pty_host_reply_delete).
pty_host_decode_reply :: proc(payload: []byte) -> (Pty_Host_Reply, bool) {
	if len(payload) == 0 do return {}, false
	tag := payload[0]
	rest := payload[1:]
	off := 0
	r: Pty_Host_Reply
	switch tag {
	case PTY_HOST_T_STARTUP_LAUNCH_REPLY, PTY_HOST_T_STARTUP_INPUT_DONE:
		r.kind = .Startup_Launch if tag == PTY_HOST_T_STARTUP_LAUNCH_REPLY else .Startup_Input_Done
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		pid, pok := pty_host_get_i32(rest, &off); if !pok { delete(inst); return {}, false }
		key, kok := pty_host_get_str(rest, &off); if !kok { delete(inst); return {}, false }
		r.instance = inst; r.pid = pid; r.startup_key = key
	case PTY_HOST_T_SPAWNED:
		r.kind = .Spawned
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		pid, ok2 := pty_host_get_i32(rest, &off); if !ok2 { delete(inst); return {}, false }
		r.instance = inst; r.pid = pid
	case PTY_HOST_T_CLOSED:
		r.kind = .Closed
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		r.instance = inst
	case PTY_HOST_T_RESTARTED:
		r.kind = .Restarted
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		pid, ok2 := pty_host_get_i32(rest, &off); if !ok2 { delete(inst); return {}, false }
		r.instance = inst; r.pid = pid
	case PTY_HOST_T_AGENTLIST:
		r.kind = .Agent_List
		n, ok := pty_host_get_u16(rest, &off); if !ok do return {}, false
		agents := make([]Pty_Host_Agent_Info, int(n))
		for i in 0..<int(n) {
			a: Pty_Host_Agent_Info
			ai, aok := pty_host_get_str(rest, &off); if !aok { pty_host_free_agents(agents[:i]); delete(agents); return {}, false }
			prog, pok := pty_host_get_str(rest, &off); if !pok { delete(ai); pty_host_free_agents(agents[:i]); delete(agents); return {}, false }
			a.instance_id = ai; a.program = prog
			pid, _ := pty_host_get_i32(rest, &off); a.pid = pid
			if off >= len(rest) { pty_host_free_agents(agents[:i]); delete(agents); return {}, false }
			a.alive = rest[off] != 0; off += 1
			if off >= len(rest) { pty_host_free_agents(agents[:i]); delete(agents); return {}, false }
			has_code := rest[off]; off += 1
			if has_code == 1 { ec, _ := pty_host_get_i32(rest, &off); a.exit_code = ec; a.has_exit_code = true }
			a.rows, _ = pty_host_get_u16(rest, &off)
			a.cols, _ = pty_host_get_u16(rest, &off)
			a.started_at, _ = pty_host_get_u64(rest, &off)
			a.last_activity, _ = pty_host_get_u64(rest, &off)
			if off < len(rest) {
				has_disp := rest[off]; off += 1
				if has_disp == 1 {
					disp, dok := pty_host_get_str(rest, &off)
					if dok { a.display_name = disp; a.has_display_name = true }
				}
			}
			agents[i] = a
		}
		r.agents = agents
	case PTY_HOST_T_OUTPUT:
		r.kind = .Output
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		r.instance = inst
		r.data = make([]byte, len(rest) - off)
		copy(r.data, rest[off:])
	case PTY_HOST_T_SCREEN:
		r.kind = .Screen
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		r.instance = inst
		scr, sok := pty_host_get_screen(rest, &off); if !sok { delete(inst); return {}, false }
		r.screen = scr
	case PTY_HOST_T_EXITED:
		r.kind = .Child_Exited
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		code, ok2 := pty_host_get_i32(rest, &off); if !ok2 { delete(inst); return {}, false }
		r.instance = inst; r.code = code
	case PTY_HOST_T_PONG:
		r.kind = .Pong
	case PTY_HOST_T_ERROR:
		r.kind = .Error
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		msg, ok2 := pty_host_get_str(rest, &off); if !ok2 { delete(inst); return {}, false }
		r.instance = inst; r.message = msg
	case PTY_HOST_T_STARTUP_READY:
		r.kind = .Startup_Ready
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		r.instance = inst
	case PTY_HOST_T_STARTUP_BLOCKED:
		r.kind = .Startup_Blocked
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		rc, ok2 := pty_host_get_str(rest, &off); if !ok2 { delete(inst); return {}, false }
		diag, ok3 := pty_host_get_str(rest, &off); if !ok3 { delete(inst); delete(rc); return {}, false }
		r.instance = inst; r.reason_code = rc; r.message = diag
	case PTY_HOST_T_SCREEN_CHANGED:
		r.kind = .Screen_Changed
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		h, ok2 := pty_host_get_u64(rest, &off); if !ok2 { delete(inst); return {}, false }
		r.instance = inst; r.hash = h
	case PTY_HOST_T_HOST_HEARTBEAT:
		r.kind = .Host_Heartbeat
		ts, tok := pty_host_get_u64(rest, &off); if !tok do return {}, false
		n, nok := pty_host_get_u16(rest, &off); if !nok do return {}, false
		agents := make([]Pty_Host_Heartbeat_Agent, int(n))
		for i in 0..<int(n) {
			id, idok := pty_host_get_str(rest, &off)
			if !idok { for j in 0..<i do delete(agents[j].instance_id); delete(agents); return {}, false }
			if off >= len(rest) { delete(id); for j in 0..<i do delete(agents[j].instance_id); delete(agents); return {}, false }
			alive := rest[off] != 0; off += 1
			agents[i] = Pty_Host_Heartbeat_Agent{instance_id = id, alive = alive}
		}
		r.ts_unix_ms = ts; r.heartbeat_agents = agents
	case PTY_HOST_T_STREAM_READY:
		r.kind = .Stream_Ready
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		r.instance = inst
	case PTY_HOST_T_ALREADY_EXITED:
		r.kind = .Already_Exited
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		code, ok2 := pty_host_get_i32(rest, &off); if !ok2 { delete(inst); return {}, false }
		r.instance = inst; r.code = code
	case PTY_HOST_T_STREAM_CLOSED:
		r.kind = .Stream_Closed
		inst, ok := pty_host_get_str(rest, &off); if !ok do return {}, false
		r.instance = inst
		if off >= len(rest) { delete(inst); return {}, false }
		has_code := rest[off]; off += 1
		if has_code == 1 {
			c, ok2 := pty_host_get_i32(rest, &off)
			if !ok2 { delete(inst); return {}, false }
			r.code = c
			r.has_code = true
		} else {
			r.has_code = false
		}
	case:
		return {}, false
	}
	return r, true
}

pty_host_get_screen :: proc(b: []byte, off: ^int) -> (Pty_Host_Screen, bool) {
	s: Pty_Host_Screen
	ok: bool
	s.rows, ok = pty_host_get_u16(b, off); if !ok do return {}, false
	s.cols, ok = pty_host_get_u16(b, off); if !ok do return {}, false
	s.cursor_row, ok = pty_host_get_u16(b, off); if !ok do return {}, false
	s.cursor_col, ok = pty_host_get_u16(b, off); if !ok do return {}, false
	n: u16
	n, ok = pty_host_get_u16(b, off); if !ok do return {}, false
	lines := make([]string, int(n))
	for i in 0..<int(n) {
		line, lok := pty_host_get_str(b, off)
		if !lok {
			for j in 0..<i do delete(lines[j])
			delete(lines)
			return {}, false
		}
		lines[i] = line
	}
	s.lines = lines
	return s, true
}

pty_host_free_agents :: proc(agents: []Pty_Host_Agent_Info) {
	for a in agents {
		if a.instance_id != "" do delete(a.instance_id)
		if a.program != "" do delete(a.program)
		if a.display_name != "" do delete(a.display_name)
	}
}

// pty_host_reply_delete frees an owned reply's heap fields.
pty_host_reply_delete :: proc(r: Pty_Host_Reply) {
	delete(r.startup_key)
	if r.instance != "" do delete(r.instance)
	if r.message != "" do delete(r.message)
	if r.reason_code != "" do delete(r.reason_code)
	if r.data != nil do delete(r.data)
	for l in r.screen.lines do delete(l)
	if r.screen.lines != nil do delete(r.screen.lines)
	pty_host_free_agents(r.agents)
	if r.agents != nil do delete(r.agents)
	for a in r.heartbeat_agents do delete(a.instance_id)
	if r.heartbeat_agents != nil do delete(r.heartbeat_agents)
}

// ---- socket round-trip --------------------------------------------------

// pty_host_socket_path resolves the daemon's unix socket path for this bridge.
// A bridge-specific directory already scopes the daemon; shared directories
// retain an identity suffix so multiple bridges never share a daemon.
pty_host_socket_path :: proc() -> string {
	base := strings.trim_right(bridge_config.local_endpoint_run_dir, "/")
	if base == "" do base = bridge_scratch_local_default(context.temp_allocator)
	// A daemon serves exactly one bridge. Use the directory identity when
	// available; otherwise put the identity in the name for shared run dirs.
	id := pty_host_bridge_identity()
	defer delete(id)
	scoped := strings.concatenate({"/", id, "/"})
	defer delete(scoped)
	if strings.contains(base, scoped) || strings.has_suffix(base, scoped[:len(scoped)-1]) {
		path := strings.concatenate({base, "/pty-host.sock"})
		defer delete(path)
		return bridge_unix_socket_bounded_path(path)
	}
	path := strings.concatenate({base, "/pty-host-", id, ".sock"})
	defer delete(path)
	return bridge_unix_socket_bounded_path(path)
}

// pty_host_bridge_identity returns a stable, filesystem-safe token identifying
// THIS bridge, for scoping the daemon socket. Preference order:
//   1. daemon_id (the enrolled bridge_id persisted in config) — the true identity;
//   2. local_endpoint_port — a reliable per-host discriminator (two bridges cannot
//      bind the same port), matching how the tmux session is scoped;
//   3. "default" — last resort for an unconfigured single bridge.
// Caller owns the returned string.
pty_host_bridge_identity :: proc() -> string {
	if id := strings.trim_space(bridge_config.daemon_id); id != "" && id != "local-daemon" {
		return bridge_runtime_safe_part(id)
	}
	if bridge_config.local_endpoint_port != 0 {
		return fmt.aprintf("port-%d", bridge_config.local_endpoint_port)
	}
	return strings.clone("default")
}

// pty_host_dial connects to the daemon unix socket, returning the fd or (-1,false).
pty_host_dial :: proc(socket_path: string) -> (local_socket.Socket, bool) {
	return local_socket.dial(strings.trim_prefix(socket_path, "unix:"))
}

// pty_host_send_all writes every byte of buf to fd.
pty_host_send_all :: proc(fd: local_socket.Socket, buf: []byte) -> bool {
	sent := 0
	for sent < len(buf) {
		remaining := len(buf) - sent
		n := local_socket.send(fd, buf[sent:][:remaining])
		if n <= 0 do return false
		sent += n
	}
	return true
}

// pty_host_read_frame reads one length-prefixed frame payload from fd. Returns
// (payload, true) or ({}, false) on EOF/error. Caller owns the payload.
pty_host_read_frame :: proc(fd: local_socket.Socket) -> ([]byte, bool) {
	len_buf: [4]byte
	if !pty_host_read_exact(fd, len_buf[:]) do return {}, false
	length := u32(len_buf[0]) << 24 | u32(len_buf[1]) << 16 | u32(len_buf[2]) << 8 | u32(len_buf[3])
	if int(length) > PTY_HOST_MAX_FRAME_BYTES do return {}, false
	payload := make([]byte, int(length))
	if int(length) > 0 && !pty_host_read_exact(fd, payload) {
		delete(payload)
		return {}, false
	}
	return payload, true
}

pty_host_read_exact :: proc(fd: local_socket.Socket, buf: []byte) -> bool {
	got := 0
	for got < len(buf) {
		remaining := len(buf) - got
		n := local_socket.recv(fd, buf[got:][:remaining])
		if n <= 0 do return false
		got += n
	}
	return true
}

// Bound on how many unsolicited async frames pty_host_request will skip while
// waiting for a control reply, so a misbehaving/very-busy daemon can never spin
// this helper forever. A live agent emits at most a handful of frames per control
// round-trip; 256 is comfortably above that while still bounded.
PTY_HOST_REQUEST_MAX_SKIP :: 256

// pty_host_reply_is_async reports whether a reply kind is an UNSOLICITED async
// event (as opposed to a control-op reply). The daemon may interleave these on any
// connection; a control client must skip them and keep reading for its reply.
pty_host_reply_is_async :: proc(kind: Pty_Host_Reply_Kind) -> bool {
	#partial switch kind {
	case .Output, .Child_Exited, .Screen_Changed, .Startup_Ready, .Startup_Blocked, .Host_Heartbeat:
		return true
	}
	return false
}

// pty_host_request sends one framed control message and returns the matching
// control reply. It reads in a LOOP, skipping any unsolicited async event frames
// (Output/ChildExited/ScreenChanged/StartupReady/StartupBlocked) the daemon may
// interleave on this connection, and returns the first genuine control reply
// (Spawned/Closed/Restarted/AgentList/Screen/Pong/Error). This makes the bridge
// correct-by-construction against event interleaving regardless of the daemon's
// subscription behaviour: a control-only connection is never fooled into reading
// an activity event as its command's reply. Bounded by PTY_HOST_REQUEST_MAX_SKIP.
// Caller owns the returned reply.
pty_host_request :: proc(socket_path: string, request: []byte) -> (Pty_Host_Reply, bool) {
	fd, ok := pty_host_dial(socket_path)
	if !ok do return {}, false
	defer local_socket.close(fd)
	if !pty_host_send_all(fd, request) do return {}, false
	return pty_host_read_control_reply(fd)
}

// pty_host_read_control_reply reads frames from fd, skipping unsolicited async
// events, and returns the first control reply. Split out from pty_host_request so
// the skip loop is unit-testable over a socketpair without a live daemon.
pty_host_read_control_reply :: proc(fd: local_socket.Socket) -> (Pty_Host_Reply, bool) {
	for _ in 0..<PTY_HOST_REQUEST_MAX_SKIP {
		payload, pok := pty_host_read_frame(fd)
		if !pok do return {}, false
		reply, dok := pty_host_decode_reply(payload)
		delete(payload)
		if !dok do return {}, false
		if pty_host_reply_is_async(reply.kind) {
			pty_host_reply_delete(reply) // drop the async event; the event loop is its real consumer
			continue
		}
		return reply, true
	}
	return {}, false
}

// ---- Signal (tag 0x39) --------------------------------------------------

// pty_host_encode_signal builds a framed Signal control message. The daemon
// delivers POSIX signal `signal` to the process group of `shell_id` via
// killpg. Caller owns the result.
pty_host_encode_signal :: proc(shell_id: string, signal: u8) -> []byte {
	p := make([dynamic]byte)
	defer delete(p)
	append(&p, PTY_HOST_T_SIGNAL)
	pty_host_put_str(&p, shell_id)
	append(&p, signal)
	return pty_host_frame(p[:])
}

// Pty_Host_Signal_Result is the daemon's answer to a Signal request.
Pty_Host_Signal_Result :: enum {
	Delivered,      // Closed: the signal was sent to the process group
	Already_Exited, // the target had already exited; the exit code comes with it
	Refused,        // Error, an unexpected reply, or no answer at all
}

// bridge_pty_host_signal_detailed sends a POSIX signal to the process group of
// shell_id and says what the daemon did with it. exit_code is meaningful only for
// .Already_Exited, which a daemon older than pty-host 52cebd54 never sends (it
// answers an exited target with a generic Error, i.e. .Refused).
bridge_pty_host_signal_detailed :: proc(client: ^Pty_Host_Client, shell_id: string, signal: u8) -> (result: Pty_Host_Signal_Result, exit_code: i32) {
	frame := pty_host_encode_signal(shell_id, signal)
	defer delete(frame)
	reply, ok := pty_host_request(client.socket, frame)
	if !ok do return .Refused, 0
	defer pty_host_reply_delete(reply)
	#partial switch reply.kind {
	case .Closed:         return .Delivered, 0
	case .Already_Exited: return .Already_Exited, reply.code
	}
	return .Refused, 0
}

// bridge_pty_host_signal is bridge_pty_host_signal_detailed for callers that only
// care whether the signal was delivered. Returns true on success.
bridge_pty_host_signal :: proc(client: ^Pty_Host_Client, shell_id: string, signal: u8) -> bool {
	result, _ := bridge_pty_host_signal_detailed(client, shell_id, signal)
	return result == .Delivered
}
