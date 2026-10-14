package main

// blog — bridge error-event log (bridge_log relay, L1).
//
// Every call site that used to say WHY something failed only on stderr now also
// enqueues a structured event: a code from contracts.Bridge_Log_Code plus up to
// BRIDGE_LOG_MAX_FIELDS typed fields (int or symbol). The stderr line is still
// printed (rendered here from the same code+fields), the event rides the
// existing bridge-ws to the hub after the next bridge_ready, and the hub turns it
// into counters, a per-bridge ring the owner can read, and (optionally) a log
// backend. The wire carries NOTHING free-form — see src/contracts/bridge_log.odin.
//
// Buffering: a fixed 256-slot ring under one mutex. Identical (level, code,
// fields) within a flush window are merged into one entry with `count`; when the
// ring is full the OLDEST entry is dropped and `dropped` rides on the next frame.
// Flush: bridge_log_drain_outgoing(conn) runs in bridge_hub_runtime_loop (so only
// after bridge_ready); it sends when the ring is non-empty and either 10 s passed
// since the last flush, or an `error` entry arrived and 1 s passed (debounce).
// A frame carries at most 10 entries; the loop sends one frame per iteration.
//
// Opt-out: shipping follows the same switch as the heartbeat stats
// (bridge_heartbeat_stats_enabled: bridge_ready.heartbeat_stats / set_telemetry).
// Buffering and stderr are unaffected by the switch.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import ws "odin_test:lib/ws"

Blog_Level :: contracts.Bridge_Log_Level
Blog_Code :: contracts.Bridge_Log_Code
Blog_Key :: contracts.Bridge_Log_Key
Blog_Sym :: contracts.Bridge_Log_Sym

BLOG_RING_SLOTS :: 256
BLOG_FLUSH_INTERVAL :: 10 * time.Second
BLOG_ERROR_DEBOUNCE :: 1 * time.Second

// Blog_Field is one typed field. Symbolic keys use `sym`, int keys use `int_value`.
Blog_Field :: struct {
	key:       Blog_Key,
	int_value: i64,
	sym:       Blog_Sym,
}

blog_int :: proc(key: Blog_Key, value: i64) -> Blog_Field {
	return Blog_Field{key = key, int_value = value}
}

blog_sym :: proc(key: Blog_Key, value: Blog_Sym) -> Blog_Field {
	return Blog_Field{key = key, sym = value}
}

blog_provider :: proc(provider: string) -> Blog_Field {
	return Blog_Field{key = .provider, sym = contracts.bridge_log_provider_sym(provider)}
}

Blog_Entry :: struct {
	seq:      u64,
	ts_ms:    i64,
	level:    Blog_Level,
	code:     Blog_Code,
	n_fields: u8,
	fields:   [contracts.BRIDGE_LOG_MAX_FIELDS]Blog_Field,
	count:    u32,
}

Blog_Ring :: struct {
	mu:            sync.Mutex,
	slots:         [BLOG_RING_SLOTS]Blog_Entry,
	head:          int, // index of the oldest entry
	len:           int,
	next_seq:      u64,
	dropped:       u32,
	error_pending: bool,
	last_flush_ns: i64, // tick ns of the last successful send (0 = never)
}

blog_ring: Blog_Ring

// blog_error / blog_warn enqueue an event and print its rendered line to stderr.
blog_error :: proc(code: Blog_Code, fields: ..Blog_Field) {
	blog_emit(.Error, code, fields)
}

blog_warn :: proc(code: Blog_Code, fields: ..Blog_Field) {
	blog_emit(.Warn, code, fields)
}

blog_emit :: proc(level: Blog_Level, code: Blog_Code, fields: []Blog_Field, now_ms: i64 = 0) {
	ts := now_ms if now_ms != 0 else time.to_unix_nanoseconds(time.now()) / 1_000_000
	e := Blog_Entry{ts_ms = ts, level = level, code = code, count = 1}
	for f in fields {
		if int(e.n_fields) >= len(e.fields) do break
		e.fields[e.n_fields] = f
		e.n_fields += 1
	}
	line := blog_render_line(e, context.temp_allocator)
	fmt.eprintln(line)
	blog_enqueue(&blog_ring, e)
}

// blog_enqueue merges into a matching pending entry or appends; overflow drops
// the oldest and counts it.
blog_enqueue :: proc(r: ^Blog_Ring, entry: Blog_Entry) {
	sync.mutex_lock(&r.mu)
	defer sync.mutex_unlock(&r.mu)
	for i in 0 ..< r.len {
		s := &r.slots[(r.head + i) % BLOG_RING_SLOTS]
		if blog_entry_same_shape(s^, entry) {
			if s.count < contracts.BRIDGE_LOG_MAX_COUNT do s.count += 1
			if entry.level == .Error do r.error_pending = true
			return
		}
	}
	e := entry
	r.next_seq += 1
	e.seq = r.next_seq
	if r.len == BLOG_RING_SLOTS {
		r.head = (r.head + 1) % BLOG_RING_SLOTS
		r.len -= 1
		if r.dropped < contracts.BRIDGE_LOG_MAX_DROPPED do r.dropped += 1
	}
	r.slots[(r.head + r.len) % BLOG_RING_SLOTS] = e
	r.len += 1
	if e.level == .Error do r.error_pending = true
}

blog_entry_same_shape :: proc(a, b: Blog_Entry) -> bool {
	if a.level != b.level || a.code != b.code || a.n_fields != b.n_fields do return false
	for i in 0 ..< int(a.n_fields) {
		if a.fields[i] != b.fields[i] do return false
	}
	return true
}

// blog_flush_due reports whether a frame should go out now.
blog_flush_due :: proc(r: ^Blog_Ring, now_tick_ns: i64) -> bool {
	sync.mutex_lock(&r.mu)
	defer sync.mutex_unlock(&r.mu)
	if r.len == 0 do return false
	since := now_tick_ns - r.last_flush_ns
	if r.last_flush_ns == 0 do since = i64(BLOG_FLUSH_INTERVAL)
	if since >= i64(BLOG_FLUSH_INTERVAL) do return true
	return r.error_pending && since >= i64(BLOG_ERROR_DEBOUNCE)
}

// blog_take_batch pops up to BRIDGE_LOG_MAX_ENTRIES oldest entries plus the
// dropped counter (which it resets). The caller owns the returned slice.
blog_take_batch :: proc(r: ^Blog_Ring, allocator := context.allocator) -> (batch: []Blog_Entry, dropped: u32) {
	sync.mutex_lock(&r.mu)
	defer sync.mutex_unlock(&r.mu)
	n := min(r.len, contracts.BRIDGE_LOG_MAX_ENTRIES)
	if n == 0 do return nil, 0
	batch = make([]Blog_Entry, n, allocator)
	for i in 0 ..< n do batch[i] = r.slots[(r.head + i) % BLOG_RING_SLOTS]
	r.head = (r.head + n) % BLOG_RING_SLOTS
	r.len -= n
	dropped = r.dropped
	r.dropped = 0
	if r.len == 0 do r.error_pending = false
	return batch, dropped
}

// blog_restore_batch puts a batch back at the FRONT after a failed send (the
// connection is dead; the next ready connection flushes it). Entries that no
// longer fit are dropped and counted, newest-first, so the oldest evidence —
// the reason for the previous disconnect — survives.
blog_restore_batch :: proc(r: ^Blog_Ring, batch: []Blog_Entry, dropped: u32) {
	sync.mutex_lock(&r.mu)
	defer sync.mutex_unlock(&r.mu)
	room := BLOG_RING_SLOTS - r.len
	keep := min(len(batch), room)
	lost := u32(len(batch) - keep)
	for i := keep - 1; i >= 0; i -= 1 {
		r.head = (r.head + BLOG_RING_SLOTS - 1) % BLOG_RING_SLOTS
		r.slots[r.head] = batch[i]
		r.len += 1
		if batch[i].level == .Error do r.error_pending = true
	}
	total := u64(r.dropped) + u64(dropped) + u64(lost)
	r.dropped = u32(min(total, u64(contracts.BRIDGE_LOG_MAX_DROPPED)))
}

blog_mark_flushed :: proc(r: ^Blog_Ring, now_tick_ns: i64) {
	sync.mutex_lock(&r.mu)
	defer sync.mutex_unlock(&r.mu)
	r.last_flush_ns = now_tick_ns
	if r.len == 0 do r.error_pending = false
}

// blog_reset clears everything; tests only.
blog_reset :: proc(r: ^Blog_Ring) {
	sync.mutex_lock(&r.mu)
	defer sync.mutex_unlock(&r.mu)
	r.head = 0
	r.len = 0
	r.next_seq = 0
	r.dropped = 0
	r.error_pending = false
	r.last_flush_ns = 0
}

blog_pending_count :: proc(r: ^Blog_Ring) -> int {
	sync.mutex_lock(&r.mu)
	defer sync.mutex_unlock(&r.mu)
	return r.len
}

// ---- wire -----------------------------------------------------------------

blog_write_fields_json :: proc(b: ^strings.Builder, e: Blog_Entry) {
	strings.write_byte(b, '{')
	for i in 0 ..< int(e.n_fields) {
		f := e.fields[i]
		if i > 0 do strings.write_byte(b, ',')
		strings.write_byte(b, '"')
		strings.write_string(b, contracts.bridge_log_key_name(f.key))
		strings.write_string(b, "\":")
		if contracts.bridge_log_key_is_symbolic(f.key) {
			strings.write_byte(b, '"')
			strings.write_string(b, contracts.bridge_log_sym_name(f.sym))
			strings.write_byte(b, '"')
		} else {
			strings.write_i64(b, f.int_value)
		}
	}
	strings.write_byte(b, '}')
}

blog_write_entry_json :: proc(b: ^strings.Builder, e: Blog_Entry) {
	strings.write_string(b, "{\"seq\":")
	strings.write_u64(b, e.seq)
	strings.write_string(b, ",\"ts_ms\":")
	strings.write_i64(b, e.ts_ms)
	strings.write_string(b, ",\"level\":\"")
	strings.write_string(b, contracts.bridge_log_level_name(e.level))
	strings.write_string(b, "\",\"code\":\"")
	strings.write_string(b, contracts.bridge_log_code_name(e.code))
	strings.write_string(b, "\",\"fields\":")
	blog_write_fields_json(b, e)
	strings.write_string(b, ",\"count\":")
	strings.write_u64(b, u64(min(e.count, contracts.BRIDGE_LOG_MAX_COUNT)))
	strings.write_byte(b, '}')
}

// blog_frame_json renders one bridge_log frame. The caller owns the string.
blog_frame_json :: proc(batch: []Blog_Entry, dropped: u32, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"type\":\"")
	strings.write_string(&b, contracts.BRIDGE_LOG_FRAME_TYPE)
	strings.write_string(&b, "\",\"seq_from\":")
	strings.write_u64(&b, batch[0].seq if len(batch) > 0 else 0)
	strings.write_string(&b, ",\"seq_to\":")
	strings.write_u64(&b, batch[len(batch) - 1].seq if len(batch) > 0 else 0)
	strings.write_string(&b, ",\"dropped\":")
	strings.write_u64(&b, u64(min(dropped, contracts.BRIDGE_LOG_MAX_DROPPED)))
	strings.write_string(&b, ",\"entries\":[")
	for e, i in batch {
		if i > 0 do strings.write_byte(&b, ',')
		blog_write_entry_json(&b, e)
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// blog_render_line is the local stderr rendering: "ham-bridge ERROR code k=v …".
// Human prose lives on the hub (one table); this is deliberately mechanical.
blog_render_line :: proc(e: Blog_Entry, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "ham-bridge ")
	strings.write_string(&b, "ERROR" if e.level == .Error else "WARN")
	strings.write_byte(&b, ' ')
	strings.write_string(&b, contracts.bridge_log_code_name(e.code))
	for i in 0 ..< int(e.n_fields) {
		f := e.fields[i]
		strings.write_byte(&b, ' ')
		strings.write_string(&b, contracts.bridge_log_key_name(f.key))
		strings.write_byte(&b, '=')
		if contracts.bridge_log_key_is_symbolic(f.key) {
			strings.write_string(&b, contracts.bridge_log_sym_name(f.sym))
		} else {
			strings.write_i64(&b, f.int_value)
		}
	}
	return strings.to_string(b)
}

// ---- flush point ----------------------------------------------------------

// bridge_log_drain_outgoing sends at most one frame per call. Lives beside the
// other *_drain_outgoing calls in bridge_hub_runtime_loop, which only runs after
// bridge_ready — so a ring filled during an outage flushes right after the next
// successful connect, carrying the previous disconnect's reason.
bridge_log_drain_outgoing :: proc(conn: ^ws.Connection) {
	bridge_log_drain_outgoing_at(conn, time.tick_now()._nsec)
}

bridge_log_drain_outgoing_at :: proc(conn: ^ws.Connection, now_tick_ns: i64) -> (sent: bool) {
	if !bridge_heartbeat_stats_enabled() do return false
	if !blog_flush_due(&blog_ring, now_tick_ns) do return false
	batch, dropped := blog_take_batch(&blog_ring)
	if len(batch) == 0 do return false
	defer delete(batch)
	frame := blog_frame_json(batch, dropped)
	defer delete(frame)
	if !bridge_hub_send(conn, frame) {
		blog_restore_batch(&blog_ring, batch, dropped)
		conn.connected = false
		return false
	}
	blog_mark_flushed(&blog_ring, now_tick_ns)
	return true
}

// ---- classification helpers shared by call sites --------------------------

// blog_connect_failure_code classifies ws.last_connect_error() text into a code
// and stage WITHOUT shipping the text. Keep in step with
// src/lib/ws/ws.odin set_last_connect_error call sites.
blog_connect_failure :: proc(reason: string) -> (code: Blog_Code, stage: Blog_Sym, why: Blog_Sym) {
	switch {
	case strings.contains(reason, "could not start the TLS relay"):
		return .tls_backend_missing, .tls, .missing_binary
	case strings.contains(reason, "timed out"):
		return .hub_connect_failed, .tcp, .timeout
	case strings.contains(reason, "TLS relay closed"):
		return .hub_connect_failed, .tls, .transport
	case strings.contains(reason, "handshake rejected"):
		return .hub_connect_failed, .ws_upgrade, .unsupported
	case strings.contains(reason, "pipe creation failed"), strings.contains(reason, "could not write the handshake"):
		return .hub_connect_failed, .tcp, .transport
	}
	return .hub_connect_failed, .tcp, .unknown
}

// blog_http_status_from_reason pulls the 3-digit status out of a
// "handshake rejected by host:port: HTTP/1.1 401 Unauthorized" line; 0 if none.
blog_http_status_from_reason :: proc(reason: string) -> i64 {
	idx := strings.index(reason, "HTTP/1.")
	if idx < 0 do return 0
	rest := reason[idx:]
	sp := strings.index_byte(rest, ' ')
	if sp < 0 || sp + 4 > len(rest) do return 0
	code, ok := strconv.parse_i64(rest[sp + 1:sp + 4])
	if !ok || code < 100 || code > 599 do return 0
	return code
}

// blog_hub_error_reason classifies a bridge_error message from the hub.
blog_hub_error_reason :: proc(message: string) -> Blog_Sym {
	m := strings.to_lower(message, context.temp_allocator)
	switch {
	case strings.contains(m, "revoked"):                                   return .revoked
	case strings.contains(m, "limit"):                                     return .limit
	case strings.contains(m, "unsupported") || strings.contains(m, "target"): return .unsupported
	case strings.contains(m, "denied") || strings.contains(m, "forbidden"): return .denied
	}
	return .unknown
}

// blog_replaced_reason maps the hub's connection_replaced reason string.
blog_replaced_reason :: proc(reason: string) -> Blog_Sym {
	switch reason {
	case "replaced", "connection_replaced": return .replaced
	case "revoked":                         return .revoked
	case "limit":                           return .limit
	case "shutdown", "eof":                 return .eof
	case "timeout", "read_deadline":        return .timeout
	}
	return .unknown
}

// blog_bootstrap_stage maps bridge_bootstrap_launch_materialize_run_dir's stage
// string onto the symbol set.
blog_bootstrap_stage :: proc(stage: string) -> Blog_Sym {
	switch stage {
	case "manifest_get":               return .manifest
	case "blob_fetch":                 return .blob
	case "assemble":                   return .assemble
	case "write_run_dir":              return .materialize
	case "validate":                   return .config
	}
	return .other
}

// BLOG_EARLY_EXIT_WINDOW: a ChildExited this soon after launch is reported as
// agent_exited_early (a provider CLI that never got going), not a normal stop.
BLOG_EARLY_EXIT_WINDOW :: 10 * time.Second

// blog_startup_reason_is_login recognises the startup-probe reason codes that
// mean "the provider CLI wants an interactive login" (provider catalog
// startup_reason_mapping values are operator-defined; match the vocabulary).
blog_startup_reason_is_login :: proc(reason_code: string) -> bool {
	r := strings.to_lower(reason_code, context.temp_allocator)
	return strings.contains(r, "login") || strings.contains(r, "auth") || strings.contains(r, "sign_in") || strings.contains(r, "signin")
}
