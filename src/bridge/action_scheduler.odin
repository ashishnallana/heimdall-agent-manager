package main

import "core:fmt"
import "base:runtime"
import "core:encoding/json"
import contracts "odin_test:contracts"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"
import httpc "odin_test:lib/httpc"

// Bridge action scheduler engine (AC-3).
//
// 1. Watches schedules_version on bridge_heartbeat_ack.
// 2. On version change (or initial start or 24h daily reconcile), issues a conditional
//    GET /api/v1/bridge/actions (If-None-Match ETag) scoped to this bridge's instances.
// 3. Maintains an in-memory queue of action schedules and ticks locally.
// 4. At target_run_at: evaluates target instance readiness, wakes/launches via existing
//    runtime plumbing if stopped and awaits ready.
// 5. Computes the next valid fire slot using cron + timezone + blackout-dates evaluator
//    (or interval fallback), skipping blackout dates and cron-excluded days.
// 6. Issues POST /api/v1/bridge/actions/:id/execute passing the next target_run_at.
// 7. Implements lease recovery: reclaims in_flight actions older than lease window back to active.

ACTION_SCHEDULER_TICK_INTERVAL_S :: 1
ACTION_SCHEDULER_DEFAULT_LEASE_WINDOW_MS :: i64(60_000)
ACTION_SCHEDULER_RECONCILE_INTERVAL_MS :: i64(86_400_000) // 24 hours

Action_Queue_Item :: struct {
	id:                 string,
	target_instance_id: string,
	prompt_text:        string,
	cron_expr:          string,
	timezone:           string,
	blackout_dates:     string,
	active_from:        string,
	active_until:       string,
	active_from_ms:     i64,
	active_until_ms:    i64,
	target_run_at:      string,
	target_run_at_ms:   i64,
	interval:           string,
	interval_seconds:   int,
	state:              string,
	in_flight:          bool,
	leased_at_ms:       i64,
	target_agent_id:    string,
	target_bridge_id:   string,
	target_provider:    string,
	target_model:        string,
	target_project_id:  string,
	// REQ-SCHED-2: "reuse" (default) or "fresh_per_run"; last_spawned_instance_id is
	// the instance created by the previous fresh_per_run fire, reaped on the next fire.
	instance_strategy:        string,
	last_spawned_instance_id: string,
}

Bridge_Action_Scheduler_State :: struct {
	mutex:                  sync.Mutex,
	queue:                  [dynamic]Action_Queue_Item,
	known_actions_version:  int,
	synced_actions_version: int,
	last_etag:              string,
	last_full_reconcile_ms: i64,
    running: bool,
    wanted_epoch, installed_epoch: string,
    wanted_revision, installed_revision: i64,
    connection_generation: u64,
    validated_ms, last_request_ms: i64,
    sync_inflight: bool,
    sync_state: Bridge_Operation_State,
    // suspended: the Hub answered experimental_feature_disabled (REQ-EXP-GATE-4).
    // The cached queue is dropped and nothing fires until a later snapshot installs.
    suspended: bool,
}

Action_Scheduler_Fetch :: Bridge_Hub_Fetch

bridge_action_sched_state: Bridge_Action_Scheduler_State

// --- Pure timing / civil / cron / advance procedures ---

action_scheduler_days_from_civil :: proc(y_in, m, d: int) -> int {
	y := y_in
	if m <= 2 do y -= 1
	era := (y if y >= 0 else y - 399) / 400
	yoe := y - era * 400
	mp := (m + 9) %% 12
	doy := (153 * mp + 2) / 5 + d - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468
}

action_scheduler_civil_from_days :: proc(z: int) -> (year: int, month: int, day: int) {
	z_shifted := z + 719468
	era := (z_shifted if z_shifted >= 0 else z_shifted - 146096) / 146097
	doe := z_shifted - era * 146097
	yoe := (doe - doe/1460 + doe/36524 - doe/146096) / 365
	y := yoe + era * 400
	doy := doe - (365*yoe + yoe/4 - yoe/100)
	mp := (5*doy + 2)/153
	d := doy - (153*mp + 2)/5 + 1
	m := mp + 3 if mp < 10 else mp - 9
	return y + (1 if m <= 2 else 0), m, d
}

action_scheduler_weekday_from_days :: proc(days: int) -> int {
	w := (days + 4) %% 7
	if w < 0 do w += 7
	return w
}

action_scheduler_format_rfc3339_utc :: proc(ms: i64) -> string {
	secs := ms / 1000
	days := int(secs / 86400)
	rem_secs := int(secs % 86400)
	if rem_secs < 0 {
		rem_secs += 86400
		days -= 1
	}
	y, m, d := action_scheduler_civil_from_days(days)
	hour := rem_secs / 3600
	minute := (rem_secs % 3600) / 60
	second := rem_secs % 60
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, m, d, hour, minute, second)
}

// Parses hub UTC RFC3339 timestamp (YYYY-MM-DDTHH:MM:SSZ) to unix milliseconds.
action_scheduler_parse_rfc3339_ms :: proc(s: string) -> (i64, bool) {
	t := strings.trim_space(s)
	if len(t) < 20 do return 0, false
	if t[4] != '-' || t[7] != '-' || t[10] != 'T' || t[13] != ':' || t[16] != ':' do return 0, false
	parse2 :: proc(str: string) -> (int, bool) {
		if len(str) < 2 do return 0, false
		a := int(str[0]) - '0'; b := int(str[1]) - '0'
		if a < 0 || a > 9 || b < 0 || b > 9 do return 0, false
		return a*10 + b, true
	}
	parse4 :: proc(str: string) -> (int, bool) {
		hi, ok1 := parse2(str[0:2]); lo, ok2 := parse2(str[2:4])
		if !ok1 || !ok2 do return 0, false
		return hi*100 + lo, true
	}
	year, y_ok := parse4(t[0:4])
	month, mo_ok := parse2(t[5:7])
	day, d_ok := parse2(t[8:10])
	hour, h_ok := parse2(t[11:13])
	minute, mi_ok := parse2(t[14:16])
	second, s_ok := parse2(t[17:19])
	if !(y_ok && mo_ok && d_ok && h_ok && mi_ok && s_ok) do return 0, false
	if month < 1 || month > 12 do return 0, false
	days := action_scheduler_days_from_civil(year, month, day)
	total_secs := i64(days) * 86400 + i64(hour) * 3600 + i64(minute) * 60 + i64(second)
	return total_secs * 1000, true
}

action_scheduler_parse_interval_seconds :: proc(interval: string) -> int {
	s := strings.trim_space(interval)
	if len(s) == 0 do return 0
	unit := s[len(s)-1]
	val_str := s[:len(s)-1]
	val, ok := strconv.parse_int(val_str)
	if !ok || val <= 0 do return 0
	switch unit {
	case 's': return val
	case 'm': return val * 60
	case 'h': return val * 3600
	case 'd': return val * 86400
	case:
		num, num_ok := strconv.parse_int(s)
		if num_ok && num > 0 do return num
		return 0
	}
}

// --- Cron Parser & Evaluator ---

Parsed_Cron :: struct {
	minutes:         [60]bool,
	hours:           [24]bool,
	dom:             [32]bool,
	months:          [13]bool,
	dow:             [8]bool,
	dom_is_wildcard: bool,
	dow_is_wildcard: bool,
}

action_scheduler_parse_cron_field :: proc(field: string, min_val, max_val: int, bits: ^[]bool) -> bool {
	f := strings.trim_space(field)
	if f == "" do return false
	if f == "*" {
		for i in min_val..=max_val do bits[i] = true
		return true
	}
	subparts := strings.split(f, ",")
	defer delete(subparts)
	for sp in subparts {
		s := strings.trim_space(sp)
		if s == "" do return false
		if strings.contains(s, "/") {
			slash_parts := strings.split(s, "/")
			defer delete(slash_parts)
			if len(slash_parts) != 2 do return false
			step, ok := strconv.parse_int(slash_parts[1])
			if !ok || step <= 0 do return false
			base := slash_parts[0]
			start_val := min_val
			end_val := max_val
			if base != "*" {
				if strings.contains(base, "-") {
					dash_parts := strings.split(base, "-")
					defer delete(dash_parts)
					if len(dash_parts) != 2 do return false
					v1, ok1 := strconv.parse_int(dash_parts[0])
					v2, ok2 := strconv.parse_int(dash_parts[1])
					if !ok1 || !ok2 || v1 < min_val || v2 > max_val || v1 > v2 do return false
					start_val = v1
					end_val = v2
				} else {
					v, ok_v := strconv.parse_int(base)
					if !ok_v || v < min_val || v > max_val do return false
					start_val = v
					end_val = max_val
				}
			}
			for v := start_val; v <= end_val; v += step do bits[v] = true
		} else if strings.contains(s, "-") {
			dash_parts := strings.split(s, "-")
			defer delete(dash_parts)
			if len(dash_parts) != 2 do return false
			v1, ok1 := strconv.parse_int(dash_parts[0])
			v2, ok2 := strconv.parse_int(dash_parts[1])
			if !ok1 || !ok2 || v1 < min_val || v2 > max_val || v1 > v2 do return false
			for v in v1..=v2 do bits[v] = true
		} else {
			v, ok_v := strconv.parse_int(s)
			if !ok_v || v < min_val || v > max_val do return false
			bits[v] = true
		}
	}
	return true
}

action_scheduler_parse_cron :: proc(expr: string) -> (cron: Parsed_Cron, ok: bool) {
	parts := strings.fields(strings.trim_space(expr))
	defer delete(parts)
	if len(parts) != 5 do return {}, false
	min_slice := cron.minutes[:]
	hour_slice := cron.hours[:]
	dom_slice := cron.dom[:]
	mo_slice := cron.months[:]
	dow_slice := cron.dow[:]
	if !action_scheduler_parse_cron_field(parts[0], 0, 59, &min_slice) do return {}, false
	if !action_scheduler_parse_cron_field(parts[1], 0, 23, &hour_slice) do return {}, false
	if !action_scheduler_parse_cron_field(parts[2], 1, 31, &dom_slice) do return {}, false
	if !action_scheduler_parse_cron_field(parts[3], 1, 12, &mo_slice) do return {}, false
	if !action_scheduler_parse_cron_field(parts[4], 0, 7, &dow_slice) do return {}, false
	if cron.dow[0] do cron.dow[7] = true
	if cron.dow[7] do cron.dow[0] = true
	cron.dom_is_wildcard = (parts[2] == "*")
	cron.dow_is_wildcard = (parts[4] == "*")
	return cron, true
}

action_scheduler_is_blackout_date :: proc(blackout_json: string, year, month, day: int) -> bool {
	if blackout_json == "" || blackout_json == "[]" do return false
	needle := fmt.tprintf("\"%04d-%02d-%02d\"", year, month, day)
	return strings.contains(blackout_json, needle)
}

// Given cron expression, IANA timezone, blackout dates, active window, and after_ms reference time,
// computes the next valid fire slot in UTC milliseconds, skipping blackout dates and cron-excluded days.
action_scheduler_eval_next_cron_slot :: proc(
	cron_expr: string,
	tz_name: string,
	blackout_json: string,
	active_from_ms: i64,
	active_until_ms: i64,
	after_ms: i64,
) -> (next_ms: i64, ok: bool) {
	_, cron_ok := action_scheduler_parse_cron(cron_expr)
	if !cron_ok do return 0, false

	tz_clean := strings.trim_space(tz_name)
	reg: ^datetime.TZ_Region = nil
	has_tz := false
	if tz_clean != "" && tz_clean != "UTC" {
		reg, has_tz = timezone.region_load(tz_clean)
	}
	defer {
		if has_tz && reg != nil {
			timezone.region_destroy(reg)
		}
	}

	return action_scheduler_eval_next_cron_slot_region(cron_expr, reg, blackout_json, active_from_ms, active_until_ms, after_ms)
}

// Same as action_scheduler_eval_next_cron_slot but with an already-loaded timezone region
// (nil = UTC); the caller owns reg. Lets tests inject an embedded TZif instead of host tzdata.
action_scheduler_eval_next_cron_slot_region :: proc(
	cron_expr: string,
	reg: ^datetime.TZ_Region,
	blackout_json: string,
	active_from_ms: i64,
	active_until_ms: i64,
	after_ms: i64,
) -> (next_ms: i64, ok: bool) {
	cron, cron_ok := action_scheduler_parse_cron(cron_expr)
	if !cron_ok do return 0, false

	ref_ms := after_ms
	if active_from_ms > 0 && active_from_ms > ref_ms {
		ref_ms = active_from_ms - 1000
	}

	secs := ref_ms / 1000
	tm_ref := time.unix(secs, 0)
	dt_utc, dt_ok := time.time_to_datetime(tm_ref)
	if !dt_ok do return 0, false
	dt_local, local_ok := timezone.datetime_to_tz(dt_utc, reg)
	if !local_ok do return 0, false

	curr_days := action_scheduler_days_from_civil(int(dt_local.year), int(dt_local.month), int(dt_local.day))

	// Search up to 2 years (730 days) forward
	for day_offset in 0..=730 {
		y, m, d := action_scheduler_civil_from_days(curr_days + day_offset)
		if action_scheduler_is_blackout_date(blackout_json, y, m, d) do continue
		if !cron.months[m] do continue

		dow := action_scheduler_weekday_from_days(curr_days + day_offset)
		dom_match := cron.dom[d]
		dow_match := cron.dow[dow]
		day_matches := false
		if cron.dom_is_wildcard && cron.dow_is_wildcard {
			day_matches = true
		} else if !cron.dom_is_wildcard && cron.dow_is_wildcard {
			day_matches = dom_match
		} else if cron.dom_is_wildcard && !cron.dow_is_wildcard {
			day_matches = dow_match
		} else {
			day_matches = (dom_match || dow_match)
		}
		if !day_matches do continue

		for h in 0..=23 {
			if !cron.hours[h] do continue
			for mi in 0..=59 {
				if !cron.minutes[mi] do continue

				cand_dt := datetime.DateTime{
					date = datetime.Date{year = i64(y), month = i8(m), day = i8(d)},
					time = datetime.Time{hour = i8(h), minute = i8(mi), second = 0},
					tz = reg,
				}
				cand_utc, utc_ok := timezone.datetime_to_utc(cand_dt)
				if !utc_ok do continue
				cand_tm, tm_ok := time.datetime_to_time(cand_utc)
				if !tm_ok do continue
				cand_ms := time.time_to_unix(cand_tm) * 1000

				if cand_ms <= after_ms do continue
				if active_from_ms > 0 && cand_ms < active_from_ms do continue
				if active_until_ms > 0 && cand_ms > active_until_ms do return 0, false

				return cand_ms, true
			}
		}
	}

	return 0, false
}

action_scheduler_advance_interval_ms :: proc(target_run_at_ms: i64, interval_seconds: int, now_ms: i64) -> (next_run_ms: i64, completed: bool) {
	if interval_seconds <= 0 {
		return target_run_at_ms, true
	}
	interval_ms := i64(interval_seconds) * 1000
	next := target_run_at_ms + interval_ms
	for next <= now_ms {
		next += interval_ms
	}
	return next, false
}

action_scheduler_compute_next_run :: proc(item: Action_Queue_Item, now_ms: i64) -> (next_ms: i64, ok: bool) {
	if item.cron_expr != "" {
		from_ms := now_ms
		if item.target_run_at_ms > from_ms {
			from_ms = item.target_run_at_ms
		}
		return action_scheduler_eval_next_cron_slot(
			item.cron_expr,
			item.timezone,
			item.blackout_dates,
			item.active_from_ms,
			item.active_until_ms,
			from_ms,
		)
	} else if item.interval_seconds > 0 {
		next_run_ms, completed := action_scheduler_advance_interval_ms(item.target_run_at_ms, item.interval_seconds, now_ms)
		if completed do return 0, false
		if item.active_until_ms > 0 && next_run_ms > item.active_until_ms do return 0, false
		return next_run_ms, true
	}
	return 0, false
}

action_scheduler_is_due :: proc(target_run_at_ms, now_ms: i64) -> bool {
	return target_run_at_ms > 0 && now_ms >= target_run_at_ms
}

action_scheduler_can_claim :: proc(item: Action_Queue_Item, now_ms: i64, lease_window_ms: i64 = ACTION_SCHEDULER_DEFAULT_LEASE_WINDOW_MS) -> bool {
	if item.state == "completed" do return false
	if !action_scheduler_is_due(item.target_run_at_ms, now_ms) do return false
	if !item.in_flight do return true
	// In-flight: claimable only if lease has expired
	if lease_window_ms > 0 && item.leased_at_ms > 0 && (now_ms - item.leased_at_ms >= lease_window_ms) do return true
	return false
}

action_scheduler_claim :: proc(item: ^Action_Queue_Item, now_ms: i64) {
	if item == nil do return
	item.in_flight = true
	item.leased_at_ms = now_ms
	// item.state is a heap-owned string (cloned in sync, freed in
	// action_queue_item_free). Free the old value and clone the new status so the
	// field stays heap-owned; assigning a string literal here previously caused an
	// invalid free (SIGABRT) on the next sync tick and leaked the prior clone.
	delete(item.state)
	item.state = strings.clone("in_flight")
}

action_scheduler_recover_lease :: proc(item: ^Action_Queue_Item, now_ms: i64, lease_window_ms: i64 = ACTION_SCHEDULER_DEFAULT_LEASE_WINDOW_MS) -> bool {
	if item == nil do return false
	if item.in_flight && lease_window_ms > 0 && item.leased_at_ms > 0 && (now_ms - item.leased_at_ms >= lease_window_ms) {
		item.in_flight = false
		// Keep item.state heap-owned (see action_scheduler_claim): free the old
		// value and clone the new status rather than assigning a string literal,
		// which would be an invalid free when action_queue_item_free runs.
		delete(item.state)
		item.state = strings.clone("active")
		return true
	}
	return false
}

action_queue_item_free :: proc(item: ^Action_Queue_Item) {
	if item == nil do return
	delete(item.id)
	delete(item.target_instance_id)
	delete(item.prompt_text)
	delete(item.cron_expr)
	delete(item.timezone)
	delete(item.blackout_dates)
	delete(item.active_from)
	delete(item.active_until)
	delete(item.target_run_at)
	delete(item.interval)
	delete(item.state)
	delete(item.target_agent_id)
	delete(item.target_bridge_id)
	delete(item.target_provider)
	delete(item.target_model)
	delete(item.target_project_id)
	delete(item.instance_strategy)
	delete(item.last_spawned_instance_id)
}


action_queue_item_clone :: proc(item: Action_Queue_Item) -> Action_Queue_Item {
    copy := item
    copy.id = strings.clone(item.id, runtime.heap_allocator())
    copy.target_instance_id = strings.clone(item.target_instance_id, runtime.heap_allocator())
    copy.prompt_text = strings.clone(item.prompt_text, runtime.heap_allocator())
    copy.cron_expr = strings.clone(item.cron_expr, runtime.heap_allocator())
    copy.timezone = strings.clone(item.timezone, runtime.heap_allocator())
    copy.blackout_dates = strings.clone(item.blackout_dates, runtime.heap_allocator())
    copy.active_from = strings.clone(item.active_from, runtime.heap_allocator())
    copy.active_until = strings.clone(item.active_until, runtime.heap_allocator())
    copy.target_run_at = strings.clone(item.target_run_at, runtime.heap_allocator())
    copy.interval = strings.clone(item.interval, runtime.heap_allocator())
    copy.state = strings.clone(item.state, runtime.heap_allocator())
    copy.target_agent_id = strings.clone(item.target_agent_id, runtime.heap_allocator())
    copy.target_bridge_id = strings.clone(item.target_bridge_id, runtime.heap_allocator())
    copy.target_provider = strings.clone(item.target_provider, runtime.heap_allocator())
    copy.target_model = strings.clone(item.target_model, runtime.heap_allocator())
    copy.target_project_id = strings.clone(item.target_project_id, runtime.heap_allocator())
    copy.instance_strategy = strings.clone(item.instance_strategy, runtime.heap_allocator())
    copy.last_spawned_instance_id = strings.clone(item.last_spawned_instance_id, runtime.heap_allocator())
    return copy
}

// --- Bridge runtime scheduling engine ---

bridge_action_scheduler_init :: proc() {
	bridge_action_sched_state = Bridge_Action_Scheduler_State{
		mutex                  = sync.Mutex{},
		queue                  = make([dynamic]Action_Queue_Item),
		known_actions_version  = 0,
		synced_actions_version = -1,
		last_etag              = "",
		last_full_reconcile_ms = 0,
		running                = false,
	}
}

bridge_action_scheduler_start :: proc() {
	bridge_action_scheduler_init()
	credential_snapshot_509 := bridge_credential_snapshot()
	defer delete(credential_snapshot_509)
	if strings.trim_space(credential_snapshot_509) == "" || strings.trim_space(bridge_config.daemon_url) == "" do return
	bridge_action_sched_state.running = true
	thread.run(bridge_action_scheduler_worker)
}

bridge_action_scheduler_worker :: proc() {
	for bridge_action_sched_state.running {
		if sync.atomic_load(&bridge_hub_traffic_stopped) do return
		bridge_action_scheduler_tick()
		time.sleep(time.Duration(ACTION_SCHEDULER_TICK_INTERVAL_S) * time.Second)
	}
}

bridge_action_scheduler_notify_version :: proc(version: int) {
	if version <= 0 do return
	sync.mutex_lock(&bridge_action_sched_state.mutex)
	defer sync.mutex_unlock(&bridge_action_sched_state.mutex)
	if version > bridge_action_sched_state.known_actions_version {
		bridge_action_sched_state.known_actions_version = version
	}
}

// eligible_since: when the owner last enabled Actions (REQ-EXP-GATE-4); fires due
// before it were missed while suspended and are rolled forward, not replayed.
Action_Snapshot_Metadata :: struct { epoch: string, revision: i64, etag: string, eligible_since: string }
Action_Snapshot_Wire_Item :: struct {
    id, target_instance_id, prompt_text, cron_expr, timezone: string,
    blackout_dates: []string,
    active_from, active_until, target_run_at, interval, state, leased_at: string,
    in_flight: bool,
    target_agent_id, target_bridge_id, target_provider, target_model, target_project_id: string,
    instance_strategy, last_spawned_instance_id: string,
}

// Parse into an owned candidate before taking the install lock. JSON validation
// includes the complete array; no partial response is allowed to prune good data.
action_snapshot_candidate :: proc(body: string, now: i64) -> (Action_Snapshot_Metadata, [dynamic]Action_Queue_Item, bool) {
    wire: struct { snapshot: Action_Snapshot_Metadata, data: [dynamic]Action_Snapshot_Wire_Item }
    parse_ctx := context
    context.allocator = context.temp_allocator
    if json.unmarshal_string(body, &wire) != nil do return {}, nil, false
    if _, found := bridge_provider_json_extract_array(body, "data"); !found do return {}, nil, false
    if wire.snapshot.epoch == "" || wire.snapshot.revision < 0 ||
       wire.snapshot.etag != fmt.tprintf("W/\"%s:%d\"", wire.snapshot.epoch, wire.snapshot.revision) { return {}, nil, false }
    context = parse_ctx
    candidate := make([dynamic]Action_Queue_Item, runtime.heap_allocator())
    valid := false
    defer if !valid {
        for &q in candidate do action_queue_item_free(&q)
        delete(candidate)
    }
    for row in wire.data {
        if row.id == "" || (row.state != "active" && row.state != "in_flight" && row.state != "completed") ||
           (row.target_instance_id == "" && row.target_agent_id == "") { return {}, nil, false }
        for q in candidate do if q.id == row.id do return {}, nil, false
        q := Action_Queue_Item{
            id = row.id,
            target_instance_id = row.target_instance_id,
            prompt_text = row.prompt_text,
            cron_expr = row.cron_expr,
            timezone = row.timezone,
            active_from = row.active_from,
            active_until = row.active_until,
            target_run_at = row.target_run_at,
            interval = row.interval,
            state = row.state,
            target_agent_id = row.target_agent_id,
            target_bridge_id = row.target_bridge_id,
            target_provider = row.target_provider,
            target_model = row.target_model,
            target_project_id = row.target_project_id,
            instance_strategy = row.instance_strategy,
            last_spawned_instance_id = row.last_spawned_instance_id,
            in_flight = row.in_flight,
        }
        if q.timezone == "" do q.timezone = "UTC"
        if q.instance_strategy == "" do q.instance_strategy = "reuse"
        if q.instance_strategy != "reuse" && q.instance_strategy != "fresh_per_run" do return {}, nil, false
        bd, bd_err := json.marshal(row.blackout_dates, allocator = context.temp_allocator)
        if bd_err != nil do return {}, nil, false
        q.blackout_dates = string(bd)
        if q.target_run_at != "" {
            ms, ok := action_scheduler_parse_rfc3339_ms(q.target_run_at)
            if !ok do return {}, nil, false
            q.target_run_at_ms = ms
        }
        if q.active_from != "" {
            ms, ok := action_scheduler_parse_rfc3339_ms(q.active_from)
            if !ok do return {}, nil, false
            q.active_from_ms = ms
        }
        if q.active_until != "" {
            ms, ok := action_scheduler_parse_rfc3339_ms(q.active_until)
            if !ok do return {}, nil, false
            q.active_until_ms = ms
        }
        if row.leased_at != "" {
            ms, ok := action_scheduler_parse_rfc3339_ms(row.leased_at)
            if !ok do return {}, nil, false
            q.leased_at_ms = ms
        }
        if q.cron_expr != "" {
            if _, ok := action_scheduler_parse_cron(q.cron_expr); !ok do return {}, nil, false
        }
        q.interval_seconds = action_scheduler_parse_interval_seconds(q.interval)
        if q.interval != "" && q.interval_seconds <= 0 do return {}, nil, false
        if q.target_run_at_ms <= 0 && q.state != "completed" {
            ms, ok := action_scheduler_compute_next_run(q, now)
            if !ok do return {}, nil, false
            q.target_run_at_ms = ms
            q.target_run_at = action_scheduler_format_rfc3339_utc(ms)
        }
        append(&candidate, action_queue_item_clone(q))
    }
    valid = true
    return wire.snapshot, candidate, true
}

bridge_action_scheduler_notify_snapshot :: proc(epoch: string, revision: i64, now: i64) {
    context.allocator = runtime.heap_allocator()
    sync.mutex_lock(&bridge_action_sched_state.mutex)
    defer sync.mutex_unlock(&bridge_action_sched_state.mutex)
    s := &bridge_action_sched_state
    if epoch == "" || revision < 0 { s.validated_ms = 0; return }
    if s.wanted_epoch != epoch {
        delete(s.wanted_epoch)
        s.wanted_epoch = strings.clone(epoch)
        s.wanted_revision = revision
    } else if revision >= s.wanted_revision {
        s.wanted_revision = revision
    }
    if s.installed_epoch == epoch && s.installed_revision == revision do s.validated_ms = now
}
bridge_action_scheduler_connection_changed :: proc() {
    sync.mutex_lock(&bridge_action_sched_state.mutex)
    defer sync.mutex_unlock(&bridge_action_sched_state.mutex)
    bridge_action_sched_state.connection_generation += 1
    bridge_action_sched_state.validated_ms = 0
}

bridge_action_scheduler_sync_key :: proc() -> string {
    return fmt.aprintf("sync:%s:%s", bridge_config.daemon_url, bridge_config.daemon_id)
}

bridge_action_scheduler_sync :: proc(fetch: Action_Scheduler_Fetch = bridge_hub_http_send, now_override: i64 = 0) -> bool {
    now := now_override if now_override > 0 else bridge_runtime_now_ms()
    s := &bridge_action_sched_state
    sync.mutex_lock(&s.mutex)
    if s.sync_inflight || (s.last_request_ms != 0 && now - s.last_request_ms < 1000) {
        sync.mutex_unlock(&s.mutex); return false
    }
    s.sync_inflight = true
    generation := s.connection_generation
    epoch := strings.clone(s.wanted_epoch)
    etag := strings.clone(s.last_etag) if s.installed_epoch == epoch else ""
    version := s.known_actions_version
    sync.mutex_unlock(&s.mutex)
    defer {
        delete(epoch); delete(etag)
        sync.mutex_lock(&s.mutex); s.sync_inflight = false; sync.mutex_unlock(&s.mutex)
    }
    key := bridge_action_scheduler_sync_key()
    defer delete(key)
    bridge_retry_reopen_success(key)
    budget, reserved := bridge_retry_reserve(key, now)
    if !reserved {
        sync.mutex_lock(&s.mutex); s.sync_state = budget.state; sync.mutex_unlock(&s.mutex)
        return false
    }
    sync.mutex_lock(&s.mutex); s.last_request_ms = now; sync.mutex_unlock(&s.mutex)
    credential := bridge_credential_snapshot()
    defer delete(credential)
    headers := make([dynamic]httpc.Header, context.temp_allocator)
    append(&headers, httpc.bearer(credential))
    if etag != "" do append(&headers, httpc.Header{name = "If-None-Match", value = etag})
    resp, http_err := fetch({
        method = .GET, url = bridge_hub_url(), path = {"api", "v1", "bridge", "actions"},
        headers = headers[:], timeout_ms = bridge_deadline_ms(bridge_operation_timeout_ms(budget, now)),
    })
    defer httpc.response_destroy(&resp)
    ok := http_err == .None
    body := httpc.text(resp)
    success := false
    err := bridge_operation_http_error(resp, ok)
    defer {
        finished := bridge_retry_finish(key, bridge_runtime_now_ms(), success, err)
        sync.mutex_lock(&s.mutex); s.sync_state = finished.state; sync.mutex_unlock(&s.mutex)
    }
    current_credential := bridge_credential_snapshot()
    defer delete(current_credential)
    sync.mutex_lock(&s.mutex)
    current := generation == s.connection_generation && epoch == s.wanted_epoch && credential == current_credential
    sync.mutex_unlock(&s.mutex)
    if !current { err = contracts.wire_error(.Bridge_Offline); return false }
    if !ok do return false
    if resp.status == 304 && etag != "" {
        sync.mutex_lock(&s.mutex)
        if s.last_etag == etag && s.wanted_epoch == s.installed_epoch && s.wanted_revision == s.installed_revision {
            s.validated_ms = now; s.last_full_reconcile_ms = now
            s.synced_actions_version = version
            success = true
        }
        sync.mutex_unlock(&s.mutex)
        return success
    }
    if action_scheduler_feature_disabled(resp.status, body) {
        // Authoritative disable: an answer, not a transport failure, so it does not
        // spend retry budget; the next heartbeat token change (re-enable) resyncs.
        sync.mutex_lock(&s.mutex)
        if generation == s.connection_generation do bridge_action_scheduler_suspend_locked(now)
        sync.mutex_unlock(&s.mutex)
        success = true
        return false
    }
    if resp.status != 200 do return false
    metadata, candidate, parsed := action_snapshot_candidate(body, now)
    if !parsed {
        if extract_json_string(body, "epoch", "") == "" do err = contracts.wire_error(.Not_Implemented)
        return false
    }
    installed := false
    defer if !installed {
        for &q in candidate do action_queue_item_free(&q)
        delete(candidate)
    }
    sync.mutex_lock(&s.mutex)
    defer sync.mutex_unlock(&s.mutex)
    if generation != s.connection_generation || (epoch != "" && metadata.epoch != epoch) ||
       (s.installed_epoch == metadata.epoch && metadata.revision < s.installed_revision) { return false }
    action_scheduler_skip_missed_fires(&candidate, metadata.eligible_since, now)
    for &q in candidate {
        for old in s.queue {
            if old.id == q.id && old.target_run_at_ms == q.target_run_at_ms && old.in_flight {
                q.in_flight = true; q.leased_at_ms = old.leased_at_ms
            }
        }
    }
    for &q in s.queue do action_queue_item_free(&q)
    delete(s.queue)
    s.queue = candidate; installed = true
    s.suspended = false
    delete(s.last_etag); s.last_etag = strings.clone(metadata.etag, runtime.heap_allocator())
    delete(s.installed_epoch); s.installed_epoch = strings.clone(metadata.epoch, runtime.heap_allocator())
    s.installed_revision = metadata.revision
    if s.wanted_epoch == "" {
        s.wanted_epoch = strings.clone(metadata.epoch, runtime.heap_allocator())
        s.wanted_revision = metadata.revision
    }
    s.validated_ms = now if s.wanted_epoch == s.installed_epoch && s.wanted_revision == s.installed_revision else 0
    s.last_full_reconcile_ms = now; s.synced_actions_version = version
    success = true
    return true
}

// bridge_action_scheduler_sync_needed_locked decides whether the tick asks the Hub.
// Suspended (REQ-EXP-GATE-4), only a new heartbeat epoch or the daily backstop counts:
// the Hub refuses a disabled owner whatever the revision, and the `.off` token's
// revision is the Hub-wide schedule counter (any user's action edit or agent-instance
// insert/delete bumps it), so following it re-polled the 403 for unrelated activity.
// Re-enable always moves the epoch (`<base>.on<eligible_since>`), as does a Hub restart.
// Version/revision drift accumulated while suspended is moot: the resync that a new
// epoch triggers is a full, unconditional GET. Caller holds the mutex.
bridge_action_scheduler_sync_needed_locked :: proc(now: i64) -> bool {
    s := &bridge_action_sched_state
    backstop := s.last_full_reconcile_ms > 0 && now - s.last_full_reconcile_ms >= ACTION_SCHEDULER_RECONCILE_INTERVAL_MS
    if s.suspended do return backstop || s.wanted_epoch != s.installed_epoch
    return backstop || s.known_actions_version != s.synced_actions_version ||
        s.wanted_epoch != s.installed_epoch || s.wanted_revision != s.installed_revision ||
        s.synced_actions_version < 0
}

bridge_action_scheduler_fresh_locked :: proc(now: i64) -> bool {
    s := &bridge_action_sched_state
    return !s.suspended && s.validated_ms > 0 && now >= s.validated_ms && now - s.validated_ms < BRIDGE_OPERATION_DEADLINE_MS &&
        s.wanted_epoch != "" && s.wanted_epoch == s.installed_epoch && s.wanted_revision == s.installed_revision &&
        (s.sync_state == .Succeeded || s.sync_state == .Pending)
}

bridge_action_scheduler_update_from_execute_response :: proc(action_id, next_run_at: string, next_run_ms: i64, has_next: bool) {
	sync.mutex_lock(&bridge_action_sched_state.mutex)
	defer sync.mutex_unlock(&bridge_action_sched_state.mutex)

	for i in 0..<len(bridge_action_sched_state.queue) {
		q := &bridge_action_sched_state.queue[i]
		if q.id == action_id {
			if !has_next {
				action_queue_item_free(q)
				ordered_remove(&bridge_action_sched_state.queue, i)
			} else {
				delete(q.target_run_at)
				q.target_run_at = strings.clone(next_run_at)
				q.target_run_at_ms = next_run_ms
				q.in_flight = false
				q.leased_at_ms = 0
			}
			break
		}
	}
}

bridge_action_scheduler_execute :: proc(action_id: string, next_target_run_at: string, instance_id: string = "", last_spawned_instance_id: string = "") -> (bool, int, string) {
    credential := bridge_credential_snapshot()
    defer delete(credential)
	if strings.trim_space(credential) == "" || strings.trim_space(bridge_config.daemon_url) == "" {
		return false, 0, ""
	}
	// last_spawned_instance_id is sent only for fresh_per_run fires so the hub
	// records it (REQ-SCHED-2); empty fields are omitted.
	Execute_Body :: struct {
		target_run_at:            string `json:"target_run_at,omitempty"`,
		instance_id:              string `json:"instance_id,omitempty"`,
		last_spawned_instance_id: string `json:"last_spawned_instance_id,omitempty"`,
	}
	payload := Execute_Body{target_run_at = next_target_run_at, instance_id = instance_id, last_spawned_instance_id = last_spawned_instance_id}
	headers := [?]httpc.Header{httpc.bearer(credential)}
	resp, err := bridge_hub_http_send_alloc({
		method = .POST, url = bridge_hub_url(), path = {"api", "v1", "bridge", "actions", action_id, "execute"},
		headers = headers[:], body = httpc.json_body(payload), timeout_ms = 10_000,
	})
	defer httpc.response_destroy(&resp)
	if err != .None do return false, 0, ""
	return resp.status == 200, resp.status, strings.clone(httpc.text(resp))
}

bridge_action_scheduler_await_ready :: proc(instance_id: string, max_wait_ms: int = 5000) -> bool {
	deadline := bridge_runtime_now_ms() + i64(max_wait_ms)
	for bridge_runtime_now_ms() < deadline {
		inst, found := bridge_runtime_instance_snapshot(instance_id)
		if found && (inst.runtime_status == "running" || inst.runtime_status == "idle") {
			return true
		}
		time.sleep(200 * time.Millisecond)
	}
	inst, found := bridge_runtime_instance_snapshot(instance_id)
	return found && (inst.runtime_status == "running" || inst.runtime_status == "idle")
}

// Instance_Candidate is a hub-listed instance of a durable agent-id together with the
// bridge-local liveness the scheduler computed for it.
Instance_Candidate :: struct {
	id:         string,
	bridge_id:  string,
	project_id: string,
	live:       bool, // running/idle in this bridge's runtime view
}

// action_scheduler_candidate_matches reports whether a candidate instance satisfies the
// action's bridge/project targeting. An empty target field imposes no filter, keeping
// backward-compat with actions that never specified a bridge or project (REQ-SCHED-2).
action_scheduler_candidate_matches :: proc(cand_bridge, cand_project, target_bridge, target_project: string) -> bool {
	if target_bridge != "" && cand_bridge != target_bridge do return false
	if target_project != "" && cand_project != target_project do return false
	return true
}

// action_scheduler_should_reuse decides whether a fired action reuses an existing
// instance (REQ-SCHED-1 reuse + REQ-SCHED-2 bridge/project filter + fresh_per_run opt-in):
//   - fresh_per_run -> never reuse (a new instance is minted every fire).
//   - otherwise     -> reuse the first LIVE candidate matching the bridge/project target.
action_scheduler_should_reuse :: proc(strategy, target_bridge, target_project: string, candidates: []Instance_Candidate) -> (string, bool) {
	if strategy == "fresh_per_run" do return "", false
	for c in candidates {
		if !c.live do continue
		if !action_scheduler_candidate_matches(c.bridge_id, c.project_id, target_bridge, target_project) do continue
		return c.id, true
	}
	return "", false
}

// action_scheduler_reap_target returns the previous fresh_per_run instance to stop once a
// new one is ready. Only fresh_per_run reaps, and never the newly minted instance.
action_scheduler_reap_target :: proc(strategy, prev_last_spawned, new_instance_id: string) -> (string, bool) {
	if strategy != "fresh_per_run" do return "", false
	if prev_last_spawned == "" || prev_last_spawned == new_instance_id do return "", false
	return prev_last_spawned, true
}

// bridge_action_scheduler_resolve_or_launch_instance resolves a target instance for an
// action that does not specify target_instance_id (REQ-SCHED-1).
// Policy:
// 1. Reuse: check if an existing instance of target_agent_id on this bridge is live (running/idle).
// 2. Wake: check if an existing instance of target_agent_id on this bridge is stopped, and wake it.
// 3. Launch: if no instance exists, call POST /api/v1/agent-instances with target_agent_id,
//    target_bridge_id, provider, model, project_id, and await readiness.
bridge_action_scheduler_resolve_or_launch_instance :: proc(due: Action_Queue_Item, now_ms: i64) -> (string, bool) {
    credential := bridge_credential_snapshot()
    defer delete(credential)
	if due.target_agent_id == "" do return "", false
	if strings.trim_space(credential) == "" || strings.trim_space(bridge_config.daemon_url) == "" {
		return "", false
	}

	headers := [?]httpc.Header{httpc.bearer(credential)}

	// For the default (reuse) strategy, enumerate existing instances of the agent-id and
	// reuse/wake one that MATCHES the action's bridge+project targeting. fresh_per_run
	// skips this entirely and always mints a new instance below (REQ-SCHED-2).
	force_create := due.instance_strategy == "fresh_per_run"
	if !force_create {
		// 1. Check existing instances via GET /api/v1/agent-instances?agent_id=...
		resp, list_err := bridge_hub_http_send_alloc({
			method = .GET, url = bridge_hub_url(), path = {"api", "v1", "agent-instances"},
			query = {{"agent_id", due.target_agent_id}}, headers = headers[:], timeout_ms = 10_000,
		})
		defer httpc.response_destroy(&resp)
		if list_err == .None && resp.status == 200 {
			data_arr, has_data := bridge_provider_json_extract_array(httpc.text(resp), "data")
			if !has_data do return "", false
			if has_data {
				objects := bridge_provider_json_top_level_objects(data_arr)
				defer {
					for obj in objects do delete(obj)
					delete(objects)
				}
				// Build the candidate set once, capturing each instance's bridge/project
				// (from the hub list) and its bridge-local liveness (from the snapshot).
				candidates := make([dynamic]Instance_Candidate)
				defer delete(candidates)
				for obj in objects {
					cid := extract_json_string(obj, "agent_instance_id", "")
					if cid == "" do continue
					cbridge := extract_json_string(obj, "bridge_id", "")
					cproject := extract_json_string(obj, "project_id", "")
					inst, found := bridge_runtime_instance_snapshot(cid)
					live := found && (inst.runtime_status == "running" || inst.runtime_status == "idle")
					append(&candidates, Instance_Candidate{id = cid, bridge_id = cbridge, project_id = cproject, live = live})
				}
				// Reuse a live instance that matches the bridge/project target.
				if reuse_id, reuse_ok := action_scheduler_should_reuse(due.instance_strategy, due.target_bridge_id, due.target_project_id, candidates[:]); reuse_ok {
					return reuse_id, true
				}
				// Otherwise wake a matching (bridge+project) stopped instance.
				for c in candidates {
					if !action_scheduler_candidate_matches(c.bridge_id, c.project_id, due.target_bridge_id, due.target_project_id) do continue
					bridge_task_wake_if_needed(c.id, now_ms, (now_ms + BRIDGE_OPERATION_DEADLINE_MS)*i64(time.Millisecond))
                    // Do not wake every candidate and then mint a fresh instance
                    // when the first launch outcome is unknown.
                    if bridge_action_scheduler_await_ready(c.id, 3000) do return c.id, true
                    return "", false
				}
			}
        } else {
            return "", false
        }
    }

    // 2. No reusable instance (or fresh_per_run); launch a new one via POST /api/v1/agent-instances
	Launch_Body :: struct {
		agent_id:   string `json:"agent_id"`,
		bridge_id:  string `json:"bridge_id,omitempty"`,
		provider:   string `json:"provider,omitempty"`,
		model:      string `json:"model,omitempty"`,
		project_id: string `json:"project_id,omitempty"`,
	}
	launch := Launch_Body{
		agent_id = due.target_agent_id, bridge_id = due.target_bridge_id, provider = due.target_provider,
		model = due.target_model, project_id = due.target_project_id,
	}
	launch_resp, launch_err := bridge_hub_http_send_alloc({
		method = .POST, url = bridge_hub_url(), path = {"api", "v1", "agent-instances"},
		headers = headers[:], body = httpc.json_body(launch), timeout_ms = 10_000,
	})
	defer httpc.response_destroy(&launch_resp)
	if launch_err != .None do return "", false

	if launch_resp.status != 200 && launch_resp.status != 201 {
		return "", false
	}

	new_instance_id := extract_json_string(httpc.text(launch_resp), "agent_instance_id", "")
	if new_instance_id == "" do return "", false

	if bridge_action_scheduler_await_ready(new_instance_id, 5000) {
		return new_instance_id, true
	}
	return new_instance_id, true
}

bridge_action_scheduler_tick :: proc(now_override: i64 = 0, fetch: Action_Scheduler_Fetch = bridge_hub_http_send, execute := bridge_action_scheduler_execute, resolve := bridge_action_scheduler_resolve_or_launch_instance, revalidate: proc(fetch: Action_Scheduler_Fetch) -> bool = bridge_action_scheduler_revalidate) -> int {
	if sync.atomic_load(&bridge_hub_traffic_stopped) do return 0
	now_ms := now_override if now_override > 0 else bridge_runtime_now_ms()
	actions := 0

	// 1. Sync if version changed, uninitialized, or daily reconcile backstop reached
	sync.mutex_lock(&bridge_action_sched_state.mutex)
	sync_needed := bridge_action_scheduler_sync_needed_locked(now_ms)
	sync.mutex_unlock(&bridge_action_sched_state.mutex)

	if sync_needed {
		bridge_action_scheduler_sync(fetch, now_ms)
	}

	// 2. Cached schedules are display-only until current authenticated validation.
    sync.mutex_lock(&bridge_action_sched_state.mutex)
    if !bridge_action_scheduler_fresh_locked(now_ms) {
        sync.mutex_unlock(&bridge_action_sched_state.mutex)
        return 0
    }
	for i in 0..<len(bridge_action_sched_state.queue) {
		item := &bridge_action_sched_state.queue[i]
		if action_scheduler_recover_lease(item, now_ms, ACTION_SCHEDULER_DEFAULT_LEASE_WINDOW_MS) {
			fmt.printfln("ACTION_SCHED_LEASE_RECOVERY id=%s target=%s", item.id, item.target_instance_id)
		}
	}

	// Collect due items to evaluate
	due_items := make([dynamic]Action_Queue_Item)
	defer {
        for &item in due_items do action_queue_item_free(&item)
        delete(due_items)
    }
	for item in bridge_action_sched_state.queue {
		if action_scheduler_can_claim(item, now_ms, ACTION_SCHEDULER_DEFAULT_LEASE_WINDOW_MS) {
			append(&due_items, action_queue_item_clone(item))
		}
	}
	sync.mutex_unlock(&bridge_action_sched_state.mutex)

	// 3. Process due items
	for due in due_items {
        sync.mutex_lock(&bridge_action_sched_state.mutex)
        fresh := bridge_action_scheduler_fresh_locked(bridge_runtime_now_ms())
        sync.mutex_unlock(&bridge_action_sched_state.mutex)
        if !fresh do break
        // REQ-EXP-GATE-4: authoritative pre-launch check. Resolve/launch/wake below run
        // BEFORE execute, so an execute-only rejection would still start agents after
        // a disable. Skipped (not parked) on failure: the slot stays due for a later tick.
        if !revalidate(fetch) do break
        slot_key := fmt.aprintf("slot:%s:%d", due.id, due.target_run_at_ms)
        _, reserved := bridge_retry_reserve(slot_key, bridge_runtime_now_ms())
        if !reserved { delete(slot_key); continue }
        // This pipeline may launch and POST. Any failure/uncertain completion is
        // parked, never reminted by a lease timeout or the next one-second tick.
        slot_success := false
        defer {
            bridge_retry_finish(slot_key, bridge_runtime_now_ms(), slot_success, contracts.wire_error(.Conflict))
            delete(slot_key)
        }
        target_instance_id := due.target_instance_id
		is_ready := false
		is_fresh := false // fresh_per_run mint on this fire -> persist + reap after execute

		if target_instance_id != "" {
			inst, found := bridge_runtime_instance_snapshot(target_instance_id)
			is_ready = found && (inst.runtime_status == "running" || inst.runtime_status == "idle")

			if !is_ready {
				if !found || !bridge_runtime_status_active(inst.runtime_status) {
					bridge_task_wake_if_needed(target_instance_id, now_ms, (now_ms + BRIDGE_OPERATION_DEADLINE_MS)*i64(time.Millisecond))
				}
				if bridge_action_scheduler_await_ready(target_instance_id, 3000) {
					is_ready = true
				}
			}
		} else if due.target_agent_id != "" {
			resolved_id, resolved_ok := resolve(due, now_ms)
			if resolved_ok && resolved_id != "" {
				target_instance_id = resolved_id
				is_ready = true
				// fresh_per_run always mints a new instance (resolve skipped reuse/wake),
				// so this fire owns a freshly created instance to record + reap against.
				is_fresh = due.instance_strategy == "fresh_per_run"
			}
		}

		if !is_ready {
			continue
		}

		sync.mutex_lock(&bridge_action_sched_state.mutex)
		claimed := false
		for i in 0..<len(bridge_action_sched_state.queue) {
			if bridge_action_sched_state.queue[i].id == due.id &&
               bridge_action_sched_state.queue[i].target_run_at_ms == due.target_run_at_ms &&
               bridge_action_scheduler_fresh_locked(bridge_runtime_now_ms()) {
                if action_scheduler_can_claim(bridge_action_sched_state.queue[i], now_ms, ACTION_SCHEDULER_DEFAULT_LEASE_WINDOW_MS) {
					action_scheduler_claim(&bridge_action_sched_state.queue[i], now_ms)
					claimed = true
				}
				break
			}
		}
		sync.mutex_unlock(&bridge_action_sched_state.mutex)

        if !claimed do continue
        if !bridge_retry_record_target(slot_key, target_instance_id) do continue
        sync.mutex_lock(&bridge_action_sched_state.mutex)
        still_fresh := bridge_action_scheduler_fresh_locked(bridge_runtime_now_ms())
        sync.mutex_unlock(&bridge_action_sched_state.mutex)
        if !still_fresh do continue

		// Compute next fire time (skipping blackouts and cron-excluded days)
		next_run_ms, has_next := action_scheduler_compute_next_run(due, now_ms)
		next_target_run_at := action_scheduler_format_rfc3339_utc(next_run_ms) if has_next else ""

		// For fresh_per_run, carry the newly minted instance id so the hub records it as
		// last_spawned_instance_id; reuse fires never send it (keeps the row untouched).
		spawned_to_persist := target_instance_id if is_fresh else ""

		ok, status, body := execute(due.id, next_target_run_at, target_instance_id, spawned_to_persist)
		if ok {
            slot_success = true
			actions += 1
			bridge_action_scheduler_update_from_execute_response(due.id, next_target_run_at, next_run_ms, has_next)
			delete(body)

			// REQ-SCHED-2: only AFTER the new instance is created + delivered do we reap
			// the previous fresh_per_run instance, so a failed create never leaves the
			// schedule with no instance. The reap uses the bridge's local lifecycle stop.
			if is_fresh {
				if reap_id, do_reap := action_scheduler_reap_target(due.instance_strategy, due.last_spawned_instance_id, target_instance_id); do_reap {
					bridge_runtime_stop_agent(reap_id)
				}
				// Record the new instance as last_spawned locally so the next fire reaps
				// THIS one even before the hub-side value round-trips back via sync.
				sync.mutex_lock(&bridge_action_sched_state.mutex)
				for i in 0..<len(bridge_action_sched_state.queue) {
					if bridge_action_sched_state.queue[i].id == due.id {
						delete(bridge_action_sched_state.queue[i].last_spawned_instance_id)
						bridge_action_sched_state.queue[i].last_spawned_instance_id = strings.clone(target_instance_id)
						break
					}
				}
				sync.mutex_unlock(&bridge_action_sched_state.mutex)
			}
		} else {
			disabled := action_scheduler_feature_disabled(status, body)
			if body != "" do delete(body)
			sync.mutex_lock(&bridge_action_sched_state.mutex)
			if disabled {
				// Disabled between revalidation and execute: the Hub refused before any
				// lease or prompt. Suspend so no further cached slot launches.
				bridge_action_scheduler_suspend_locked(now_ms)
				sync.mutex_unlock(&bridge_action_sched_state.mutex)
				break
			}
			for i in 0..<len(bridge_action_sched_state.queue) {
				if bridge_action_sched_state.queue[i].id == due.id {
					bridge_action_sched_state.queue[i].in_flight = false
					if status == 409 {
						bridge_action_sched_state.synced_actions_version = -1
					}
					break
				}
			}
			sync.mutex_unlock(&bridge_action_sched_state.mutex)
		}
	}

	return actions
}

// action_scheduler_feature_disabled reports the Hub's experimental gate refusal
// (403 forbidden, details.code experimental_feature_disabled).
action_scheduler_feature_disabled :: proc(status: int, body: string) -> bool {
    return status == 403 && strings.contains(body, "experimental_feature_disabled")
}

// bridge_action_scheduler_suspend_locked drops every cached schedule after an
// authoritative Actions disable (REQ-EXP-GATE-4). Definitions live on the Hub and are
// untouched; running work is not stopped. The installed token is pinned to the wanted
// (disabled) token so the tick does not poll the 403 every second; a re-enable changes
// the heartbeat token, which triggers a full (non-conditional) resync.
// Caller holds bridge_action_sched_state.mutex.
bridge_action_scheduler_suspend_locked :: proc(now: i64) {
    s := &bridge_action_sched_state
    for &q in s.queue do action_queue_item_free(&q)
    clear(&s.queue)
    delete(s.last_etag); s.last_etag = ""
    delete(s.installed_epoch); s.installed_epoch = strings.clone(s.wanted_epoch, runtime.heap_allocator())
    s.installed_revision = s.wanted_revision
    s.synced_actions_version = s.known_actions_version
    s.validated_ms = 0
    s.suspended = true
    // The 403 is an authoritative answer: it restarts the daily backstop. Without
    // this, a snapshot installed >24h before the disable kept the backstop due, and
    // every tick re-polled the 403 (1 Hz, forever).
    s.last_full_reconcile_ms = now
}

// action_scheduler_skip_missed_fires rolls forward slots that fell due before the owner
// (re-)enabled Actions, so re-enable never replays fires missed while suspended. A
// one-shot whose time passed while disabled is dropped from the local queue (its Hub
// definition is kept). Hub-side target_run_at advances on the next real fire.
// eligible_since has one-second resolution (the Hub clock), so the real re-enable
// instant lies anywhere in [since, since+1s): the cutoff covers that whole second, so
// a slot missed in a sub-second disable is never replayed. Fail closed: a slot due
// within that second after the re-enable is rolled forward too.
action_scheduler_skip_missed_fires :: proc(queue: ^[dynamic]Action_Queue_Item, eligible_since: string, now_ms: i64) {
    if eligible_since == "" do return
    since_ms, ok := action_scheduler_parse_rfc3339_ms(eligible_since)
    if !ok do return
    cutoff := min(since_ms + 1000, now_ms)
    for i := len(queue) - 1; i >= 0; i -= 1 {
        q := &queue[i]
        if q.state == "completed" || q.in_flight || q.target_run_at_ms <= 0 || q.target_run_at_ms >= cutoff do continue
        next_ms, has_next := action_scheduler_compute_next_run(q^, now_ms)
        if !has_next || next_ms <= now_ms {
            action_queue_item_free(q)
            ordered_remove(queue, i)
            continue
        }
        delete(q.target_run_at)
        q.target_run_at = strings.clone(action_scheduler_format_rfc3339_utc(next_ms), runtime.heap_allocator())
        q.target_run_at_ms = next_ms
    }
}

// bridge_action_scheduler_revalidate asks the Hub, immediately before a due fire may
// wake or launch an instance, whether the installed snapshot is still current and the
// owner still eligible (conditional GET; eligibility is folded into the ETag epoch).
// Only 304 for the installed ETag passes. experimental_feature_disabled suspends;
// anything else (changed snapshot, auth/transport error) fails closed and forces a
// resync. Remaining window: a disable landing after this 304 but before execute can
// still wake/launch an instance, but execute is refused, so no prompt is delivered.
bridge_action_scheduler_revalidate :: proc(fetch: Action_Scheduler_Fetch) -> bool {
    s := &bridge_action_sched_state
    sync.mutex_lock(&s.mutex)
    etag := strings.clone(s.last_etag, runtime.heap_allocator())
    generation := s.connection_generation
    sync.mutex_unlock(&s.mutex)
    defer delete(etag)
    if etag == "" do return false
    credential := bridge_credential_snapshot()
    defer delete(credential)
    headers := [?]httpc.Header{httpc.bearer(credential), {name = "If-None-Match", value = etag}}
    resp, err := fetch({method = .GET, url = bridge_hub_url(), path = {"api", "v1", "bridge", "actions"}, headers = headers[:], timeout_ms = 5_000})
    defer httpc.response_destroy(&resp)
    sync.mutex_lock(&s.mutex)
    defer sync.mutex_unlock(&s.mutex)
    if err != .None || generation != s.connection_generation do return false
    if action_scheduler_feature_disabled(resp.status, httpc.text(resp)) {
        bridge_action_scheduler_suspend_locked(bridge_runtime_now_ms())
        return false
    }
    if resp.status == 304 && s.last_etag == etag && !s.suspended do return true
    s.synced_actions_version = -1
    return false
}
