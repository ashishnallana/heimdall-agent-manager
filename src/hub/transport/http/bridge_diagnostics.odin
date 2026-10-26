package http

import "base:runtime"
import "core:encoding/json"
import "core:math"
import "core:mem/virtual"
import "core:sync"
import "core:unicode/utf8"
import contracts "odin_test:contracts"
import project_service "odin_test:hub/service/project"
import metrics "odin_test:lib/metrics"

// bridge_diagnostics frame ingestion (minimal heartbeat plan §4.3, T5). Only sent by
// a Bridge after bridge_ready advertised diagnostics_frame_v1; legacy heartbeat
// diagnostics (bridge_heartbeat_stats.odin) are still ingested for every other Bridge.
//
// Strict by construction, unlike the legacy scanner:
//   - the whole frame is capped (DIAGNOSTICS_MAX_FRAME_BYTES), must be valid UTF-8 and
//     exactly one JSON object (no trailing bytes, no duplicate keys);
//   - a malformed envelope (type/schema/process_epoch/sample_seq/collected_at_ms) or a
//     present family that is not an object rejects the whole frame;
//   - inside a present family every consumed scalar is required: a missing, mistyped,
//     negative or out-of-range value rejects that family (never read as zero);
//   - vocabularies are exact; one bad operation_recovery row rejects the whole object;
//   - unknown members are ignored, so a newer Bridge may add fields.
// Everything is validated before the hub mutates anything; ordering and application
// happen in project_service.bridge_diagnostics_commit.

DIAGNOSTICS_MAX_FRAME_BYTES :: 16 * 1024
DIAGNOSTICS_MAX_RECOVERY_ROWS :: 256
DIAGNOSTICS_MAX_RECOVERY_BYTES :: 8 * 1024
DIAGNOSTICS_MAX_RECEIPTS :: 4096
DIAGNOSTICS_MAX_PROVIDER_BYTES :: 64
DIAGNOSTICS_SCHEMA :: 1

Diagnostics_Frame_Result :: enum u8 {
	Applied,
	Rejected_Oversize,
	Rejected_Bad_Json,
	Rejected_Envelope,
	Stale,
	Superseded,
}

// BRIDGE_HUB_DIAGNOSTICS_FRAME_V1: this hub has a complete bridge_diagnostics handler,
// so bridge_ready may advertise diagnostics_frame_v1 to runtime sockets.
BRIDGE_HUB_DIAGNOSTICS_FRAME_V1 :: true

// bridge_apply_diagnostics_frame validates and applies one bridge_diagnostics frame.
// Rejections are counted, never fatal to the connection: diagnostics must not cost a
// Bridge its liveness socket. `connection` (nil in unit tests) supplies the owner's
// telemetry switch; `registry` (nil in unit tests) the generation barrier.
bridge_apply_diagnostics_frame :: proc(registry: ^project_service.Bridge_Runtime_Registry, bridge_id: string, generation: int, text: string, connection: ^project_service.Bridge_Runtime_Connection = nil, now_unix_s: i64 = 0) -> Diagnostics_Frame_Result {
	if len(text) > DIAGNOSTICS_MAX_FRAME_BYTES {
		diagnostics_reject(project_service.DIAGNOSTICS_REJECT_OVERSIZE)
		return .Rejected_Oversize
	}
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		diagnostics_reject(project_service.DIAGNOSTICS_REJECT_BAD_JSON)
		return .Rejected_Bad_Json
	}
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)

	snap: project_service.Bridge_Diagnostics_Snapshot
	switch bridge_decode_diagnostics(&snap, text, allocator) {
	case .Applied:
	case .Rejected_Bad_Json:
		diagnostics_reject(project_service.DIAGNOSTICS_REJECT_BAD_JSON)
		return .Rejected_Bad_Json
	case .Rejected_Envelope, .Rejected_Oversize, .Stale, .Superseded:
		diagnostics_reject(project_service.DIAGNOSTICS_REJECT_ENVELOPE)
		return .Rejected_Envelope
	}
	stats_enabled := connection == nil || sync.atomic_load(&connection.telemetry_enabled)
	switch project_service.bridge_diagnostics_commit(registry, bridge_id, generation, &snap, stats_enabled, now_unix_s) {
	case .Applied:    return .Applied
	case .Stale:      return .Stale
	case .Superseded: return .Superseded
	}
	return .Applied
}

// bridge_decode_diagnostics fills snap from text; string fields point into
// allocator's parse tree. Returns .Applied for a structurally valid frame (families
// may still be individually .Invalid), or the frame-level rejection.
bridge_decode_diagnostics :: proc(snap: ^project_service.Bridge_Diagnostics_Snapshot, text: string, allocator: runtime.Allocator) -> Diagnostics_Frame_Result {
	if len(text) > DIAGNOSTICS_MAX_FRAME_BYTES do return .Rejected_Oversize
	// Core's string decoder assumes valid UTF-8, and its convenience parsers accept
	// trailing bytes, so parse exactly one value and require EOF after it.
	if !utf8.valid_string(text) do return .Rejected_Bad_Json
	// parse_value's error paths free through context.allocator, not the parser's.
	context.allocator = allocator
	parser := json.make_parser_from_string(text, .JSON, true, allocator)
	value, parse_err := json.parse_value(&parser)
	object, is_object := value.(json.Object)
	if parse_err != nil || !is_object || parser.curr_token.kind != .EOF do return .Rejected_Bad_Json

	if type, ok := object["type"].(json.String); !ok || type != "bridge_diagnostics" do return .Rejected_Envelope
	if schema, ok := object["schema"].(json.Integer); !ok || schema != DIAGNOSTICS_SCHEMA do return .Rejected_Envelope
	epoch, epoch_ok := object["process_epoch"].(json.String)
	if !epoch_ok || !diagnostics_epoch_valid(epoch) do return .Rejected_Envelope
	seq, seq_ok := diagnostics_uint(object, "sample_seq")
	if !seq_ok || seq == 0 do return .Rejected_Envelope
	collected, collected_ok := diagnostics_uint(object, "collected_at_ms")
	if !collected_ok do return .Rejected_Envelope
	snap.process_epoch = epoch
	snap.sample_seq = seq
	snap.collected_at_ms = collected

	families := [project_service.Bridge_Diagnostics_Family]string{
		.Command_Dispatch    = "command_dispatch",
		.Dependency_Breakers = "dependency_breakers",
		.Http_Retries        = "http_retries",
		.Operation_Recovery  = "operation_recovery",
		.Stats               = "stats",
	}
	for key, family in families {
		raw, present := object[key]
		if !present do continue
		obj, obj_ok := raw.(json.Object)
		if !obj_ok do return .Rejected_Envelope
		ok := false
		switch family {
		case .Command_Dispatch:    ok = diagnostics_decode_dispatch(snap, obj)
		case .Dependency_Breakers: ok = diagnostics_decode_breakers(snap, obj)
		case .Http_Retries:        ok = diagnostics_decode_http_retries(snap, obj)
		case .Operation_Recovery:  ok = diagnostics_decode_recovery(snap, obj, allocator)
		case .Stats:               ok = diagnostics_decode_stats(snap, obj, object)
		}
		snap.parts[family] = .Valid if ok else .Invalid
	}
	return .Applied
}

@(private = "file")
diagnostics_reject :: proc(reason: string) {
	metrics.counter_inc(metrics.with(project_service.fleet_metrics.bridge_frames_rejected, reason))
}

// process_epoch is opaque, but it is compared and stored in a fixed buffer: 1..64
// printable ASCII bytes.
@(private = "file")
diagnostics_epoch_valid :: proc(epoch: string) -> bool {
	if len(epoch) == 0 || len(epoch) > project_service.BRIDGE_DIAGNOSTICS_EPOCH_MAX do return false
	for i in 0 ..< len(epoch) do if epoch[i] < 0x21 || epoch[i] > 0x7e do return false
	return true
}

// diagnostics_uint reads a required non-negative JSON integer no larger than
// STATS_MAX_VALUE. Floats, strings, null and absent keys are not ok.
@(private = "file")
diagnostics_uint :: proc(obj: json.Object, key: string) -> (u64, bool) {
	v, ok := obj[key].(json.Integer)
	if !ok || v < 0 || v > STATS_MAX_VALUE do return 0, false
	return u64(v), true
}

// diagnostics_centi reads a required non-negative JSON number (integer or decimal)
// scaled by 100 and rounded, matching the 2-decimal metric families.
@(private = "file")
diagnostics_centi :: proc(obj: json.Object, key: string) -> (u64, bool) {
	#partial switch v in obj[key] {
	case json.Integer:
		if v < 0 || v > STATS_MAX_VALUE / 100 do return 0, false
		return u64(v) * 100, true
	case json.Float:
		if math.is_nan(v) || math.is_inf(v) || v < 0 do return 0, false
		scaled := math.round(v * 100)
		if scaled > f64(STATS_MAX_VALUE) do return 0, false
		return u64(scaled), true
	}
	return 0, false
}

@(private = "file")
diagnostics_decode_dispatch :: proc(snap: ^project_service.Bridge_Diagnostics_Snapshot, obj: json.Object) -> bool {
	for key, i in ([4]string{"accepted", "rejected", "completed", "deadline_expired"}) {
		v, ok := diagnostics_uint(obj, key)
		if !ok do return false
		snap.dispatch[i] = v
	}
	return true
}

@(private = "file")
diagnostics_decode_http_retries :: proc(snap: ^project_service.Bridge_Diagnostics_Snapshot, obj: json.Object) -> bool {
	for key, i in ([4]string{"retry", "recovered", "gave_up", "deferred"}) {
		v, ok := diagnostics_uint(obj, key)
		if !ok do return false
		snap.http_retries[i] = v
	}
	return true
}

@(private = "file")
diagnostics_decode_breakers :: proc(snap: ^project_service.Bridge_Diagnostics_Snapshot, obj: json.Object) -> bool {
	open, open_ok := diagnostics_uint(obj, "open")
	opened, opened_ok := diagnostics_uint(obj, "opened")
	if !open_ok || !opened_ok do return false
	snap.breakers_open, snap.breakers_opened = open, opened
	return true
}

// Vocabularies match the legacy heartbeat validator (bridge_heartbeat_stats.odin) and
// the producer (retry_journal.odin): exact, case-sensitive.
diagnostics_recovery_operation_valid :: proc(operation: string) -> bool {
	switch operation {
	case "sync", "readiness", "refresh", "slot": return true
	}
	return false
}

diagnostics_recovery_state_valid :: proc(state: string) -> bool {
	switch state {
	case "Pending", "In_Flight", "Backoff", "Succeeded", "Waiting_Repair", "Exhausted", "Cancelled": return true
	}
	return false
}

// The 8 KiB recovery bound is measured on the canonical compact encoding
// {"rows":[{"operation":"…","state":"…","code":"…","class":"…","receipts":N},…]}, so
// whitespace in the frame cannot move a snapshot across it.
@(private = "file")
diagnostics_decode_recovery :: proc(snap: ^project_service.Bridge_Diagnostics_Snapshot, obj: json.Object, allocator: runtime.Allocator) -> bool {
	rows, rows_ok := obj["rows"].(json.Array)
	if !rows_ok || len(rows) > DIAGNOSTICS_MAX_RECOVERY_ROWS do return false
	out := make([]project_service.Bridge_Diagnostics_Recovery_Row, len(rows), allocator)
	ROW_FIXED :: len(`{"operation":"","state":"","code":"","class":"","receipts":}`)
	size := len(`{"rows":[]}`)
	for raw, i in rows {
		row, row_ok := raw.(json.Object)
		if !row_ok do return false
		operation, op_ok := row["operation"].(json.String)
		state, state_ok := row["state"].(json.String)
		code, code_ok := row["code"].(json.String)
		class, class_ok := row["class"].(json.String)
		receipts, receipts_ok := diagnostics_uint(row, "receipts")
		if !op_ok || !state_ok || !code_ok || !class_ok || !receipts_ok do return false
		if !diagnostics_recovery_operation_valid(operation) || !diagnostics_recovery_state_valid(state) do return false
		if _, ok := contracts.error_class_parse(class); !ok do return false
		if code != "" {
			if _, ok := contracts.error_code_parse(code); !ok do return false
		}
		if receipts > DIAGNOSTICS_MAX_RECEIPTS do return false
		digits := 1
		for n := receipts; n >= 10; n /= 10 do digits += 1
		size += ROW_FIXED + len(operation) + len(state) + len(code) + len(class) + digits
		if i > 0 do size += 1
		if size > DIAGNOSTICS_MAX_RECOVERY_BYTES do return false
		out[i] = {operation = operation, state = state, code = code, class = class, receipts = i64(receipts)}
	}
	snap.recovery_rows = out
	return true
}

// stats: rss and cpu_s are always required. pty_host_rss, host_mem_total/avail,
// load1 and disk_free are required unless the frame's top-level `unavailable` names
// them, in which case they must be ABSENT (a gauge is never both unavailable and
// sampled). `unavailable` is validated with stats: unknown or repeated names, or
// naming only half of the host memory pair, reject stats. Without stats it is ignored.
@(private = "file")
diagnostics_decode_stats :: proc(snap: ^project_service.Bridge_Diagnostics_Snapshot, obj: json.Object, frame: json.Object) -> bool {
	unavailable: bit_set[project_service.Bridge_Diagnostics_Gauge]
	mem_total_listed, mem_avail_listed := false, false
	if raw, present := frame["unavailable"]; present {
		names, names_ok := raw.(json.Array)
		if !names_ok do return false
		for raw_name in names {
			name, name_ok := raw_name.(json.String)
			if !name_ok do return false
			switch name {
			case "pty_host_rss":
				if .Pty_Host_Rss in unavailable do return false
				unavailable += {.Pty_Host_Rss}
			case "host_mem_total":
				if mem_total_listed do return false
				mem_total_listed = true
			case "host_mem_avail":
				if mem_avail_listed do return false
				mem_avail_listed = true
			case "load1":
				if .Load1 in unavailable do return false
				unavailable += {.Load1}
			case "disk_free":
				if .Disk_Free in unavailable do return false
				unavailable += {.Disk_Free}
			case:
				return false
			}
		}
		if mem_total_listed != mem_avail_listed do return false
		if mem_total_listed do unavailable += {.Host_Memory}
	}

	ok: bool
	if snap.rss, ok = diagnostics_uint(obj, "rss"); !ok do return false
	if snap.cpu_cs, ok = diagnostics_centi(obj, "cpu_s"); !ok do return false
	if !diagnostics_optional_gauge(obj, "pty_host_rss", .Pty_Host_Rss in unavailable, &snap.pty_host_rss, false) do return false
	if !diagnostics_optional_gauge(obj, "host_mem_total", .Host_Memory in unavailable, &snap.host_mem_total, false) do return false
	if !diagnostics_optional_gauge(obj, "host_mem_avail", .Host_Memory in unavailable, &snap.host_mem_avail, false) do return false
	if !diagnostics_optional_gauge(obj, "load1", .Load1 in unavailable, &snap.load1_cs, true) do return false
	if !diagnostics_optional_gauge(obj, "disk_free", .Disk_Free in unavailable, &snap.disk_free, false) do return false
	snap.unavailable = unavailable

	instances, instances_ok := obj["instances"].(json.Array)
	if !instances_ok || len(instances) > project_service.BRIDGE_DIAGNOSTICS_MAX_PROVIDERS do return false
	snap.n_providers = 0
	for raw in instances {
		item, item_ok := raw.(json.Object)
		if !item_ok do return false
		provider, provider_ok := item["provider"].(json.String)
		if !provider_ok || len(provider) == 0 || len(provider) > DIAGNOSTICS_MAX_PROVIDER_BYTES do return false
		rss, rss_ok := diagnostics_uint(item, "rss")
		cpu, cpu_ok := diagnostics_centi(item, "cpu_s")
		if !rss_ok || !cpu_ok do return false
		// Providers are enum-mapped so a peer cannot mint series; collisions merge.
		mapped := project_service.provider_enum(provider)
		merged := false
		for &p in snap.providers[:snap.n_providers] {
			if p.provider == mapped { p.rss += rss; p.cpu_cs += cpu; merged = true; break }
		}
		if !merged {
			snap.providers[snap.n_providers] = {provider = mapped, rss = rss, cpu_cs = cpu}
			snap.n_providers += 1
		}
	}
	return true
}

@(private = "file")
diagnostics_optional_gauge :: proc(obj: json.Object, key: string, unavailable: bool, out: ^u64, centi: bool) -> bool {
	_, present := obj[key]
	if unavailable do return !present
	v: u64
	ok: bool
	if centi {
		v, ok = diagnostics_centi(obj, key)
	} else {
		v, ok = diagnostics_uint(obj, key)
	}
	out^ = v
	return ok
}
