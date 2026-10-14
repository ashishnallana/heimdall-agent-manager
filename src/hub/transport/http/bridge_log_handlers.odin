package http

import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import bridge_log_service "odin_test:hub/service/bridge_log"
import bridge_service "odin_test:hub/service/bridge"
import project_service "odin_test:hub/service/project"
import metrics "odin_test:lib/metrics"

// bridge_log ingest (bridge_logs plan v2 §4.1) + owner API (§4.4).
//
// Hot path (the connection's ws reader thread) does exactly four things:
// validate against the allow-list, bump counters, heap-clone the accepted
// entries, hand them to the single writer thread. It never touches SQLite or
// the network. The reader `defer delete(text)`s the frame right after dispatch,
// so nothing queued may point into `text`.
//
// Trust model: the bridge is a customer-controlled process. bridge_id ALWAYS
// comes from the authenticated socket; `code` is enum-mapped (unknown ->
// "other"); field keys are allow-listed and values must be an int (int keys)
// or a known symbol name (symbol keys; unknown name -> "other"); counts and
// timestamps are clamped; a per-connection token bucket bounds volume.

BRIDGE_LOG_BUCKET_BURST :: 300
BRIDGE_LOG_BUCKET_REFILL :: 20
BRIDGE_LOG_BUCKET_PERIOD :: 10 * time.Second
BRIDGE_LOG_TS_PAST :: 7 * 24 * time.Hour
BRIDGE_LOG_TS_FUTURE :: 5 * time.Minute
BRIDGE_LOG_API_DEFAULT_LIMIT :: 100
BRIDGE_LOG_API_MAX_LIMIT :: 200

Bridge_Log_Frame_Result :: enum {
	Applied,
	Dropped_Opted_Out,
	Rejected_Oversize,
	Rejected_Bad_Json,
	Rejected_Too_Many,
}

Bridge_Log_Frame_Stats :: struct {
	result:        Bridge_Log_Frame_Result,
	accepted:      int, // entries queued for the writer
	bad_field:     int, // entries rejected (log_bad_field)
	rate_limited:  int, // entries dropped by the token bucket
	queue_dropped: int, // accepted but the writer queue was full
	dropped_hint:  int, // bridge-reported ring drops (clamped)
}

// bridge_apply_log_frame validates one bridge_log frame. `connection` may be
// nil in unit tests (no opt-out, no bucket); `svc` may be nil (entries are
// validated and counted but not stored). now_* let tests pin time.
bridge_apply_log_frame :: proc(
	svc: ^bridge_log_service.Service,
	bridge_id, text: string,
	connection: ^project_service.Bridge_Runtime_Connection,
	now_unix_ms: i64 = 0,
	now_tick_ns: i64 = 0,
) -> (st: Bridge_Log_Frame_Stats) {
	m := &project_service.fleet_metrics
	if len(text) > contracts.BRIDGE_LOG_MAX_FRAME_BYTES {
		st.result = .Rejected_Oversize
		metrics.counter_inc(metrics.with(m.bridge_frames_rejected, "log_oversize"))
		return
	}
	if connection != nil && !sync.atomic_load(&connection.telemetry_enabled) {
		st.result = .Dropped_Opted_Out
		return
	}
	entries_raw, has_entries, balanced := stats_raw_container(text, "entries", '[', ']')
	if !has_entries || !balanced {
		st.result = .Rejected_Bad_Json
		metrics.counter_inc(metrics.with(m.bridge_frames_rejected, "log_bad_json"))
		return
	}
	now_ms := now_unix_ms if now_unix_ms != 0 else time.now()._nsec / 1_000_000
	dropped := json_int(text, "dropped", 0)
	if dropped < 0 do dropped = 0
	if dropped > contracts.BRIDGE_LOG_MAX_DROPPED do dropped = contracts.BRIDGE_LOG_MAX_DROPPED
	st.dropped_hint = dropped
	if dropped > 0 do metrics.counter_add(m.bridge_log_dropped, u64(dropped))

	// Count first so an over-long frame is refused whole, before any side effect.
	count_rest := entries_raw
	n_entries := 0
	for {
		_, ok := stats_next_object(&count_rest)
		if !ok do break
		n_entries += 1
		if n_entries > contracts.BRIDGE_LOG_MAX_ENTRIES {
			st.result = .Rejected_Too_Many
			metrics.counter_inc(metrics.with(m.bridge_frames_rejected, "log_too_many"))
			return
		}
	}

	// Token bucket on the connection (reader-thread-only fields).
	tokens := BRIDGE_LOG_BUCKET_BURST
	if connection != nil {
		tick := now_tick_ns if now_tick_ns != 0 else time.tick_now()._nsec
		bridge_log_bucket_refill(connection, tick)
		tokens = connection.log_tokens
	}

	rest := entries_raw
	rate_limited_hit := false
	for {
		entry, ok := stats_next_object(&rest)
		if !ok do break
		if tokens <= 0 {
			st.rate_limited += 1
			if !rate_limited_hit {
				rate_limited_hit = true
				metrics.counter_inc(metrics.with(m.bridge_frames_rejected, "log_rate_limited"))
			}
			continue
		}
		tokens -= 1
		ev, valid := bridge_log_validate_entry(bridge_id, entry, now_ms)
		if !valid {
			st.bad_field += 1
			metrics.counter_inc(metrics.with(m.bridge_frames_rejected, "log_bad_field"))
			continue
		}
		metrics.counter_add(metrics.with(m.bridge_errors, ev.code, ev.level), u64(ev.count))
		metrics.counter_add(metrics.with(m.bridge_errors_by_bridge, bridge_id), u64(ev.count))
		metrics.counter_add(m.bridge_log_entries, u64(ev.count))
		if svc != nil {
			if bridge_log_service.enqueue(svc, ev) {
				st.accepted += 1
			} else {
				st.queue_dropped += 1
				metrics.counter_inc(m.bridge_log_queue_dropped)
				domain.bridge_log_event_destroy(&ev)
			}
		} else {
			st.accepted += 1
			domain.bridge_log_event_destroy(&ev)
		}
	}
	if connection != nil do connection.log_tokens = tokens
	st.result = .Applied
	return
}

// bridge_log_bucket_refill tops the bucket up by elapsed time. A connection
// that has never been refilled starts FULL (a reconnecting bridge legitimately
// flushes its whole ring in the first seconds).
bridge_log_bucket_refill :: proc(c: ^project_service.Bridge_Runtime_Connection, tick_ns: i64) {
	if c.log_tokens_tick_ns == 0 {
		c.log_tokens = BRIDGE_LOG_BUCKET_BURST
		c.log_tokens_tick_ns = tick_ns
		return
	}
	per_token_ns := i64(BRIDGE_LOG_BUCKET_PERIOD) / BRIDGE_LOG_BUCKET_REFILL
	elapsed := tick_ns - c.log_tokens_tick_ns
	if elapsed < per_token_ns do return
	add := int(elapsed / per_token_ns)
	c.log_tokens_tick_ns += i64(add) * per_token_ns
	c.log_tokens = min(c.log_tokens + add, BRIDGE_LOG_BUCKET_BURST)
}

// bridge_log_validate_entry turns one `{seq,ts_ms,level,code,fields,count}`
// object into a heap-owned event, or rejects it. Every string in the result is
// a fresh clone (nothing aliases `entry`).
bridge_log_validate_entry :: proc(bridge_id, entry: string, now_ms: i64) -> (ev: domain.Bridge_Log_Event, ok: bool) {
	level := json_string(entry, "level", context.temp_allocator)
	if _, level_ok := contracts.bridge_log_level_from_name(level); !level_ok do return {}, false
	code_raw := json_string(entry, "code", context.temp_allocator)
	code := "other"
	if c, known := contracts.bridge_log_code_from_name(code_raw); known do code = contracts.bridge_log_code_name(c)
	count := json_int(entry, "count", 1)
	if count < 1 do count = 1
	if count > contracts.BRIDGE_LOG_MAX_COUNT do count = contracts.BRIDGE_LOG_MAX_COUNT
	ts := i64(json_int(entry, "ts_ms", 0))
	lo := now_ms - i64(BRIDGE_LOG_TS_PAST / time.Millisecond)
	hi := now_ms + i64(BRIDGE_LOG_TS_FUTURE / time.Millisecond)
	if ts < lo do ts = lo
	if ts > hi do ts = hi

	fields_json, fields_ok := bridge_log_normalize_fields(entry)
	if !fields_ok do return {}, false
	ev = domain.Bridge_Log_Event{
		bridge_id   = strings.clone(bridge_id),
		ts_ms       = ts,
		received_at = now_ms,
		level       = strings.clone(level),
		code        = strings.clone(code),
		fields_json = fields_json,
		count       = count,
	}
	return ev, true
}

// bridge_log_normalize_fields re-emits the entry's `fields` object with only
// allow-listed keys and typed values. Rejects: unknown key, a non-integer for
// an int key, a non-string for a symbol key, more than BRIDGE_LOG_MAX_FIELDS
// keys, or malformed JSON. A missing/empty object is "{}". The result is
// heap-allocated and owned by the caller.
bridge_log_normalize_fields :: proc(entry: string) -> (string, bool) {
	raw, found, balanced := stats_raw_container(entry, "fields", '{', '}')
	if !found do return strings.clone("{}"), true
	if !balanced do return "", false
	body := strings.trim_space(raw[1:len(raw) - 1])
	b := strings.builder_make()
	strings.write_byte(&b, '{')
	n := 0
	seen: [len(contracts.Bridge_Log_Key)]bool
	for len(body) > 0 {
		body = strings.trim_left_space(body)
		if len(body) == 0 do break
		if body[0] != '"' { strings.builder_destroy(&b); return "", false }
		key_end := strings.index_byte(body[1:], '"')
		if key_end < 0 { strings.builder_destroy(&b); return "", false }
		key_name := body[1:1 + key_end]
		body = strings.trim_left_space(body[2 + key_end:])
		if len(body) == 0 || body[0] != ':' { strings.builder_destroy(&b); return "", false }
		body = strings.trim_left_space(body[1:])
		key, key_ok := contracts.bridge_log_key_from_name(key_name)
		if !key_ok || seen[key] { strings.builder_destroy(&b); return "", false }
		seen[key] = true
		n += 1
		if n > contracts.BRIDGE_LOG_MAX_FIELDS { strings.builder_destroy(&b); return "", false }
		if n > 1 do strings.write_byte(&b, ',')
		strings.write_byte(&b, '"')
		strings.write_string(&b, contracts.bridge_log_key_name(key))
		strings.write_string(&b, "\":")
		if contracts.bridge_log_key_is_symbolic(key) {
			if len(body) == 0 || body[0] != '"' { strings.builder_destroy(&b); return "", false }
			val_end := strings.index_byte(body[1:], '"')
			if val_end < 0 { strings.builder_destroy(&b); return "", false }
			sym_name := body[1:1 + val_end]
			sym, _ := contracts.bridge_log_sym_from_name(sym_name) // unknown -> .other
			strings.write_byte(&b, '"')
			strings.write_string(&b, contracts.bridge_log_sym_name(sym))
			strings.write_byte(&b, '"')
			body = body[2 + val_end:]
		} else {
			end := 0
			for end < len(body) && body[end] != ',' && body[end] != '}' && body[end] != ' ' && body[end] != '\t' && body[end] != '\n' && body[end] != '\r' do end += 1
			tok := body[:end]
			v, v_ok := strconv.parse_i64(tok)
			if !v_ok || tok == "" { strings.builder_destroy(&b); return "", false }
			for ch, i in tok do if !(ch >= '0' && ch <= '9') && !(i == 0 && ch == '-') { strings.builder_destroy(&b); return "", false }
			strings.write_i64(&b, v)
			body = body[end:]
		}
		body = strings.trim_left_space(body)
		if len(body) == 0 do break
		if body[0] == ',' { body = body[1:]; continue }
		strings.builder_destroy(&b)
		return "", false
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b), true
}

// ---- owner API --------------------------------------------------------------

@(private = "file")
bridge_events_bridge_id :: proc(path: string) -> string {
	return strings.trim_suffix(suffix_after(path, "/api/v1/bridges/"), "/events")
}

// GET /api/v1/bridges/{bridge_id}/events?limit=100&before_id=<id>
// Owner-scoped exactly like every other /api/v1/bridges/* route: get_bridge
// yields 404 for an unknown bridge and 403 for someone else's. Pagination is
// by id (hub-monotonic), never by the bridge's clock. `message` is rendered
// here from code+fields (bridge_log_render.odin).
bridge_events_list_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	bridge_id := bridge_events_bridge_id(req.path)
	bridge, found, err := bridge_service.get_bridge(h.bridges, auth_ctx, bridge_id)
	if !found do return respond_error(err, req.request_id)
	defer domain.bridge_destroy(&bridge)
	limit := query_int(req.query, "limit", BRIDGE_LOG_API_DEFAULT_LIMIT)
	if limit < 1 do limit = 1
	if limit > BRIDGE_LOG_API_MAX_LIMIT do limit = BRIDGE_LOG_API_MAX_LIMIT
	before_id := i64(query_int(req.query, "before_id", 0))
	events, list_err := bridge_log_service.list(h.bridge_logs, bridge.bridge_id, limit + 1, before_id)
	if list_err.code != .None do return respond_error(list_err, req.request_id)
	defer domain.bridge_log_events_destroy(events)
	has_more := len(events) > limit
	shown := events[:min(len(events), limit)]
	b := strings.builder_make()
	strings.write_string(&b, "{\"bridge_id\":\"")
	write_handler_json_string(&b, bridge.bridge_id)
	strings.write_string(&b, "\",\"events\":[")
	for e, i in shown {
		if i > 0 do strings.write_byte(&b, ',')
		write_bridge_log_event_json(&b, e)
	}
	strings.write_string(&b, "],\"has_more\":")
	strings.write_string(&b, "true" if has_more else "false")
	strings.write_string(&b, ",\"next_before_id\":")
	strings.write_i64(&b, shown[len(shown) - 1].id if len(shown) > 0 else 0)
	strings.write_byte(&b, '}')
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

// DELETE /api/v1/bridges/{bridge_id}/events — the owner purges the ring.
bridge_events_purge_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Bridge_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	bridge_id := bridge_events_bridge_id(req.path)
	bridge, found, err := bridge_service.get_bridge(h.bridges, auth_ctx, bridge_id)
	if !found do return respond_error(err, req.request_id)
	defer domain.bridge_destroy(&bridge)
	deleted, purge_err := bridge_log_service.purge_bridge(h.bridge_logs, bridge.bridge_id)
	if purge_err.code != .None do return respond_error(purge_err, req.request_id)
	b := strings.builder_make()
	strings.write_string(&b, "{\"bridge_id\":\"")
	write_handler_json_string(&b, bridge.bridge_id)
	strings.write_string(&b, "\",\"deleted\":")
	strings.write_int(&b, deleted)
	strings.write_byte(&b, '}')
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

write_bridge_log_event_json :: proc(b: ^strings.Builder, e: domain.Bridge_Log_Event) {
	message := bridge_log_render_message(e.code, e.fields_json, context.temp_allocator)
	strings.write_string(b, "{\"id\":")
	strings.write_i64(b, e.id)
	strings.write_string(b, ",\"ts_ms\":")
	strings.write_i64(b, e.ts_ms)
	strings.write_string(b, ",\"received_at\":")
	strings.write_i64(b, e.received_at)
	strings.write_string(b, ",\"level\":\"")
	write_handler_json_string(b, e.level)
	strings.write_string(b, "\",\"code\":\"")
	write_handler_json_string(b, e.code)
	strings.write_string(b, "\",\"fields\":")
	strings.write_string(b, e.fields_json if e.fields_json != "" else "{}")
	strings.write_string(b, ",\"count\":")
	strings.write_int(b, e.count)
	strings.write_string(b, ",\"message\":\"")
	write_handler_json_string(b, message)
	strings.write_string(b, "\"}")
}
