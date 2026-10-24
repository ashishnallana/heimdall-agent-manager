package http

import "core:strconv"
import "core:encoding/json"
import contracts "odin_test:contracts"
import "core:strings"
import "core:sync"
import "core:time"
import project_service "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"
import metrics "odin_test:lib/metrics"

// stats_raw_container returns the raw `{...}`/`[...]` text that follows
// `"key":` at the top nesting level of `body`. Strings are skipped so braces
// inside values cannot confuse the scan. balanced=false means the container was
// opened but never closed (truncated/malformed frame).
stats_raw_container :: proc(body, key: string, open, close: byte) -> (raw: string, found, balanced: bool) {
	needle_buf: [64]byte
	if len(key) + 3 > len(needle_buf) do return "", false, false
	n := copy(needle_buf[:], "\"")
	n += copy(needle_buf[n:], key)
	n += copy(needle_buf[n:], "\":")
	idx := strings.index(body, string(needle_buf[:n]))
	if idx < 0 do return "", false, false
	i := idx + n
	for i < len(body) && (body[i] == ' ' || body[i] == '\t' || body[i] == '\n' || body[i] == '\r') do i += 1
	if i >= len(body) || body[i] != open do return "", true, false
	start := i
	depth := 0
	in_string := false
	for ; i < len(body); i += 1 {
		c := body[i]
		if in_string {
			if c == '\\' { i += 1; continue }
			if c == '"' do in_string = false
			continue
		}
		switch c {
		case '"': in_string = true
		case '{', '[': depth += 1
		case '}', ']':
			depth -= 1
			if depth == 0 do return body[start:i+1], true, c == close
		}
	}
	return "", true, false
}

// stats_next_object advances through the inside of an array, returning the
// next balanced `{...}` item.
stats_next_object :: proc(rest: ^string) -> (item: string, ok: bool) {
	s := rest^
	start := strings.index_byte(s, '{')
	if start < 0 do return "", false
	depth := 0
	in_string := false
	for i := start; i < len(s); i += 1 {
		c := s[i]
		if in_string {
			if c == '\\' { i += 1; continue }
			if c == '"' do in_string = false
			continue
		}
		switch c {
		case '"': in_string = true
		case '{': depth += 1
		case '}':
			depth -= 1
			if depth == 0 {
				rest^ = s[i+1:]
				return s[start:i+1], true
			}
		}
	}
	return "", false
}

// Heartbeat `stats` ingestion (plan 4.3, hub side). The bridge is a remote,
// customer-controlled process, so everything it says about itself is validated
// before it becomes a time series:
//   - the raw object is size-capped;
//   - every number is clamped to [0, STATS_MAX_VALUE] (negative/NaN/huge -> reject);
//   - at most one object per bridge per 5 s is applied (the heartbeat cadence is
//     45 s; anything faster is a misbehaving peer or a replay);
//   - provider names are enum-mapped (unknown -> "other"), so a peer cannot
//     mint series; at most STATS_MAX_INSTANCES provider entries are read.
// Rejections are counted in heimdall_bridge_frames_rejected_total{reason}.

STATS_MAX_BYTES :: 8 * 1024
STATS_MIN_INTERVAL :: 5 * time.Second
STATS_MAX_INSTANCES :: 16
// 2^53: the largest integer a JSON producer can represent exactly; bytes and
// seconds never legitimately get near it.
STATS_MAX_VALUE :: 9_007_199_254_740_992

Heartbeat_Stats_Result :: enum {
	Absent,
	Applied,
	Rejected_Oversize,
	Rejected_Rate_Limited,
	Rejected_Out_Of_Range,
	Rejected_Bad_Json,
}

// bridge_apply_heartbeat_stats reads `stats` from a bridge_heartbeat frame and
// sets the per-bridge resource gauges. `connection` may be nil in unit tests
// that drive frames without a registered socket (no rate cap then).
bridge_apply_heartbeat_stats :: proc(bridge_id, text: string, connection: ^project_service.Bridge_Runtime_Connection, now_tick_ns: i64 = 0) -> Heartbeat_Stats_Result {
	stats, has_stats, balanced := stats_raw_container(text, "stats", '{', '}')
	if !has_stats do return .Absent
	if !balanced do return stats_reject(.Rejected_Bad_Json)
	if len(stats) > STATS_MAX_BYTES do return stats_reject(.Rejected_Oversize)

	// Rate cap, per connection: the slot lives on the registry connection so a
	// replaced connection starts fresh.
	if connection != nil {
		now := now_tick_ns if now_tick_ns != 0 else time.tick_now()._nsec
		last := sync.atomic_load(&connection.last_stats_tick_ns)
		if last != 0 && now - last < i64(STATS_MIN_INTERVAL) do return stats_reject(.Rejected_Rate_Limited)
		sync.atomic_store(&connection.last_stats_tick_ns, now)
	}

	// Parse everything first; apply nothing unless the whole object is sane.
	rss, rss_ok := stats_number(stats, "rss")
	pty_rss, pty_ok := stats_number(stats, "pty_host_rss")
	cpu_cs, cpu_ok := stats_number(stats, "cpu_s", 2)
	mem_total, mt_ok := stats_number(stats, "host_mem_total")
	mem_avail, ma_ok := stats_number(stats, "host_mem_avail")
	load1_cs, load_ok := stats_number(stats, "load1", 2)
	disk_free, disk_ok := stats_number(stats, "disk_free")
	if !rss_ok || !pty_ok || !cpu_ok || !mt_ok || !ma_ok || !load_ok || !disk_ok do return stats_reject(.Rejected_Out_Of_Range)

	Instance_Stat :: struct { provider: string, rss: u64, cpu_cs: u64 }
	instances: [STATS_MAX_INSTANCES]Instance_Stat
	n_instances := 0
	if arr, arr_found, arr_balanced := stats_raw_container(stats, "instances", '[', ']'); arr_found {
		if !arr_balanced do return stats_reject(.Rejected_Bad_Json)
		rest := arr[1:len(arr)-1]
		n_items := 0
		for {
			item, item_ok := stats_next_object(&rest)
			if !item_ok do break
			n_items += 1
			if n_items > STATS_MAX_INSTANCES do return stats_reject(.Rejected_Out_Of_Range)
			provider := jsonx.extract_string(item, "provider", allocator = context.temp_allocator)
			irss, irss_ok := stats_number(item, "rss")
			icpu, icpu_ok := stats_number(item, "cpu_s", 2)
			if !irss_ok || !icpu_ok do return stats_reject(.Rejected_Out_Of_Range)
			mapped := project_service.provider_enum(provider)
			// Merge duplicates (e.g. two unknown programs both mapping to "other").
			merged := false
			for i in 0 ..< n_instances {
				if instances[i].provider == mapped { instances[i].rss += irss; instances[i].cpu_cs += icpu; merged = true; break }
			}
			if !merged {
				instances[n_instances] = Instance_Stat{provider = mapped, rss = irss, cpu_cs = icpu}
				n_instances += 1
			}
		}
	}

	m := &project_service.fleet_metrics
	// A provider that disappeared since the last heartbeat must not linger at
	// its last value: tombstone the per-bridge instance series, then set the
	// current ones (revive = same pointer, zeroed, so this is cheap).
	metrics.remove_where(m.instance_resident, 0, bridge_id)
	metrics.remove_where(m.instance_cpu, 0, bridge_id)
	metrics.gauge_set(metrics.with(m.bridge_process_resident, bridge_id, "bridge"), i64(rss))
	metrics.gauge_set(metrics.with(m.bridge_process_resident, bridge_id, "pty_host"), i64(pty_rss))
	metrics.counter_set(metrics.with(m.bridge_process_cpu, bridge_id, "bridge"), cpu_cs)
	if mem_total > 0 {
		metrics.gauge_set(metrics.with(m.bridge_host_memory, bridge_id, "total"), i64(mem_total))
		metrics.gauge_set(metrics.with(m.bridge_host_memory, bridge_id, "available"), i64(mem_avail))
	}
	if load_ok && strings.contains(stats, "\"load1\"") do metrics.gauge_set(metrics.with(m.bridge_host_load1, bridge_id), i64(load1_cs))
	if strings.contains(stats, "\"disk_free\"") do metrics.gauge_set(metrics.with(m.bridge_disk_free, bridge_id), i64(disk_free))
	for i in 0 ..< n_instances {
		metrics.gauge_set(metrics.with(m.instance_resident, bridge_id, instances[i].provider), i64(instances[i].rss))
		metrics.counter_set(metrics.with(m.instance_cpu, bridge_id, instances[i].provider), instances[i].cpu_cs)
	}
	return .Applied
}

// bridge_apply_heartbeat_reliability exports the bridge's cumulative dispatcher,
// HTTP-retry and circuit-breaker counters from a bridge_heartbeat frame
// (REQ-ERR-PROTO-B). Each object is optional (older bridges omit http_retries) and
// applied only when all of its fields parse.
bridge_apply_heartbeat_reliability :: proc(bridge_id, text: string) {
	m := &project_service.fleet_metrics
    if obj, found, balanced := stats_raw_container(text, "operation_recovery", '{', '}'); found && balanced && len(obj) <= STATS_MAX_BYTES {
        wire: struct { rows: []struct {operation, state, code, class: string, receipts: int} }
        if json.unmarshal_string(obj, &wire) == nil && len(wire.rows) <= 256 {
            valid := true
            for row in wire.rows {
                op_ok := row.operation == "sync" || row.operation == "readiness" || row.operation == "refresh" || row.operation == "slot"
                state_ok := row.state == "Pending" || row.state == "In_Flight" || row.state == "Backoff" || row.state == "Succeeded" || row.state == "Waiting_Repair" || row.state == "Exhausted" || row.state == "Cancelled"
                _, code_ok := contracts.error_code_parse(row.code)
                _, class_ok := contracts.error_class_parse(row.class)
                if !op_ok || !state_ok || (!code_ok && row.code != "") || !class_ok || row.receipts < 0 || row.receipts > 4096 { valid = false; break }
            }
            if valid {
                metrics.remove_where(m.bridge_recovery, 0, bridge_id)
                for row in wire.rows do metrics.gauge_set(metrics.with(m.bridge_recovery, bridge_id, row.operation, row.state, row.code, row.class), i64(row.receipts))
            }
        }
    }
    if obj, found, balanced := stats_raw_container(text, "command_dispatch", '{', '}'); found && balanced && len(obj) <= STATS_MAX_BYTES {
		accepted, a_ok := stats_number(obj, "accepted")
		shed, s_ok := stats_number(obj, "rejected")
		completed, c_ok := stats_number(obj, "completed")
		expired, e_ok := stats_number(obj, "deadline_expired")
		if a_ok && s_ok && c_ok && e_ok {
			metrics.counter_set(metrics.with(m.bridge_dispatch, bridge_id, "accepted"), accepted)
			metrics.counter_set(metrics.with(m.bridge_dispatch, bridge_id, "shed"), shed)
			metrics.counter_set(metrics.with(m.bridge_dispatch, bridge_id, "completed"), completed)
			metrics.counter_set(metrics.with(m.bridge_dispatch, bridge_id, "deadline_expired"), expired)
		}
	}
	if obj, found, balanced := stats_raw_container(text, "http_retries", '{', '}'); found && balanced && len(obj) <= STATS_MAX_BYTES {
		retry, r_ok := stats_number(obj, "retry")
		recovered, rc_ok := stats_number(obj, "recovered")
		gave_up, g_ok := stats_number(obj, "gave_up")
		deferred, d_ok := stats_number(obj, "deferred")
		if r_ok && rc_ok && g_ok && d_ok {
			metrics.counter_set(metrics.with(m.bridge_http_retries, bridge_id, "retry"), retry)
			metrics.counter_set(metrics.with(m.bridge_http_retries, bridge_id, "recovered"), recovered)
			metrics.counter_set(metrics.with(m.bridge_http_retries, bridge_id, "gave_up"), gave_up)
			metrics.counter_set(metrics.with(m.bridge_http_retries, bridge_id, "deferred"), deferred)
		}
	}
	if obj, found, balanced := stats_raw_container(text, "dependency_breakers", '{', '}'); found && balanced && len(obj) <= STATS_MAX_BYTES {
		open, o_ok := stats_number(obj, "open")
		opened, op_ok := stats_number(obj, "opened")
		if o_ok && op_ok {
			metrics.gauge_set(metrics.with(m.bridge_breakers_open, bridge_id), i64(open))
			metrics.counter_set(metrics.with(m.bridge_breaker_trips, bridge_id), opened)
		}
	}
}

@(private = "file")
stats_reject :: proc(result: Heartbeat_Stats_Result) -> Heartbeat_Stats_Result {
	reason := "other"
	#partial switch result {
	case .Rejected_Oversize:     reason = "stats_oversize"
	case .Rejected_Rate_Limited: reason = "stats_rate_limited"
	case .Rejected_Out_Of_Range: reason = "stats_out_of_range"
	case .Rejected_Bad_Json:     reason = "stats_bad_json"
	}
	metrics.counter_inc(metrics.with(project_service.fleet_metrics.bridge_frames_rejected, reason))
	return result
}

// stats_number reads a non-negative JSON number as an integer scaled by
// 10^decimals (so "cpu_s":12.34 with decimals=2 -> 1234). A missing key is 0/ok;
// a present key that is negative, non-numeric, NaN or beyond STATS_MAX_VALUE is
// not ok. Exponent notation is deliberately refused.
stats_number :: proc(obj, key: string, decimals := 0) -> (value: u64, ok: bool) {
	raw, found := stats_raw_value(obj, key)
	if !found do return 0, true
	if raw == "" || raw[0] == '-' do return 0, false
	for c in raw do if !((c >= '0' && c <= '9') || c == '.') do return 0, false
	if strings.count(raw, ".") > 1 do return 0, false
	int_part := raw
	frac_part := ""
	if dot := strings.index_byte(raw, '.'); dot >= 0 {
		int_part = raw[:dot]
		frac_part = raw[dot+1:]
	}
	if int_part == "" do int_part = "0"
	if len(int_part) > 16 do return 0, false
	whole, whole_ok := strconv.parse_u64(int_part)
	if !whole_ok || whole > STATS_MAX_VALUE do return 0, false
	value = whole
	for _ in 0 ..< decimals do value *= 10
	frac: u64
	scale: u64 = 1
	for _ in 0 ..< decimals do scale *= 10
	// Take at most `decimals` fractional digits, truncating the rest.
	for i in 0 ..< decimals {
		frac *= 10
		if i < len(frac_part) do frac += u64(frac_part[i] - '0')
	}
	_ = scale
	value += frac
	if value > STATS_MAX_VALUE do return 0, false
	return value, true
}

// stats_raw_value finds `"key":` at the top level of a small flat object and
// returns the unparsed scalar token that follows (up to , or }).
@(private = "file")
stats_raw_value :: proc(obj, key: string) -> (string, bool) {
	needle_buf: [64]byte
	if len(key) + 3 > len(needle_buf) do return "", false
	n := copy(needle_buf[:], "\"")
	n += copy(needle_buf[n:], key)
	n += copy(needle_buf[n:], "\":")
	needle := string(needle_buf[:n])
	idx := strings.index(obj, needle)
	if idx < 0 do return "", false
	rest := strings.trim_left_space(obj[idx+len(needle):])
	end := 0
	for end < len(rest) && rest[end] != ',' && rest[end] != '}' && rest[end] != ']' && rest[end] != ' ' && rest[end] != '\n' do end += 1
	return rest[:end], true
}
