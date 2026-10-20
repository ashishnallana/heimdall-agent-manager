package main

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"
import http "odin_test:lib/http_client"

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

// Backward-compatibility alias
Prompt_Queue_Item :: Action_Queue_Item

Bridge_Action_Scheduler_State :: struct {
	mutex:                  sync.Mutex,
	queue:                  [dynamic]Action_Queue_Item,
	known_actions_version:  int,
	synced_actions_version: int,
	last_etag:              string,
	last_full_reconcile_ms: i64,
	running:                bool,
}

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

// Backward-compatibility procedure aliases
prompt_scheduler_days_from_civil :: action_scheduler_days_from_civil
prompt_scheduler_parse_rfc3339_ms :: action_scheduler_parse_rfc3339_ms
prompt_scheduler_parse_interval_seconds :: action_scheduler_parse_interval_seconds
prompt_scheduler_is_due :: action_scheduler_is_due
prompt_scheduler_can_claim :: action_scheduler_can_claim
prompt_scheduler_claim :: action_scheduler_claim
prompt_scheduler_recover_lease :: action_scheduler_recover_lease
prompt_scheduler_advance_ms :: action_scheduler_advance_interval_ms
prompt_queue_item_free :: action_queue_item_free

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
	if strings.trim_space(bridge_config.bridge_token) == "" || strings.trim_space(bridge_config.daemon_url) == "" do return
	bridge_action_sched_state.running = true
	thread.run(bridge_action_scheduler_worker)
}

// Backward-compatibility alias
bridge_prompt_scheduler_start :: bridge_action_scheduler_start

bridge_action_scheduler_worker :: proc() {
	for bridge_action_sched_state.running {
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

// Backward-compatibility alias
bridge_prompt_scheduler_notify_version :: bridge_action_scheduler_notify_version

bridge_action_scheduler_sync :: proc() -> bool {
	if strings.trim_space(bridge_config.bridge_token) == "" || strings.trim_space(bridge_config.daemon_url) == "" do return false
	now_ms := bridge_runtime_now_ms()

	sync.mutex_lock(&bridge_action_sched_state.mutex)
	last_etag := bridge_action_sched_state.last_etag
	version_to_sync := bridge_action_sched_state.known_actions_version
	sync.mutex_unlock(&bridge_action_sched_state.mutex)

	headers := make([dynamic]http.Header)
	defer delete(headers)
	auth_header := strings.concatenate({"Bearer ", bridge_config.bridge_token})
	defer delete(auth_header)
	append(&headers, http.Header{name = "Authorization", value = auth_header})
	if last_etag != "" {
		append(&headers, http.Header{name = "If-None-Match", value = last_etag})
	}

	resp, ok := bridge_http_request_retry("GET", bridge_config.daemon_url, "/api/v1/bridge/actions", "", headers[:], http.DEFAULT_TIMEOUT_MS)
	if !ok do return false
	defer delete(resp.body)

	if resp.status == 304 {
		sync.mutex_lock(&bridge_action_sched_state.mutex)
		bridge_action_sched_state.synced_actions_version = version_to_sync
		bridge_action_sched_state.last_full_reconcile_ms = now_ms
		sync.mutex_unlock(&bridge_action_sched_state.mutex)
		return true
	}

	if resp.status != 200 do return false

	data_arr, has_data := bridge_provider_json_extract_array(resp.body, "data")
	if !has_data do return false

	objects := bridge_provider_json_top_level_objects(data_arr)
	defer {
		for obj in objects do delete(obj)
		delete(objects)
	}

	sync.mutex_lock(&bridge_action_sched_state.mutex)
	defer sync.mutex_unlock(&bridge_action_sched_state.mutex)

	seen := make(map[string]bool)
	defer delete(seen)

	for obj in objects {
		id := extract_json_string(obj, "id", "")
		if id == "" do continue
		seen[id] = true

		target := extract_json_string(obj, "target_instance_id", "")
		prompt := extract_json_string(obj, "prompt_text", "")
		cron_expr := extract_json_string(obj, "cron_expr", "")
		timezone_str := extract_json_string(obj, "timezone", "UTC")
		blackout_dates := extract_json_string(obj, "blackout_dates", "[]")
		active_from := extract_json_string(obj, "active_from", "")
		active_until := extract_json_string(obj, "active_until", "")
		run_at := extract_json_string(obj, "target_run_at", "")
		interval := extract_json_string(obj, "interval", "")
		state := extract_json_string(obj, "state", "active")
		in_flight := strings.contains(obj, "\"in_flight\":true")
		leased_at := extract_json_string(obj, "leased_at", "")
		target_agent := extract_json_string(obj, "target_agent_id", "")
		target_bridge := extract_json_string(obj, "target_bridge_id", "")
		target_provider := extract_json_string(obj, "target_provider", "")
		target_model := extract_json_string(obj, "target_model", "")
		target_project := extract_json_string(obj, "target_project_id", "")
		instance_strategy := extract_json_string(obj, "instance_strategy", "reuse")
		last_spawned := extract_json_string(obj, "last_spawned_instance_id", "")

		run_at_ms, _ := action_scheduler_parse_rfc3339_ms(run_at)
		active_from_ms, _ := action_scheduler_parse_rfc3339_ms(active_from)
		active_until_ms, _ := action_scheduler_parse_rfc3339_ms(active_until)
		leased_at_ms, _ := action_scheduler_parse_rfc3339_ms(leased_at)
		interval_secs := action_scheduler_parse_interval_seconds(interval)

		// If target_run_at was unset and action has a cron or interval, compute the next slot
		if run_at_ms <= 0 {
			dummy_item := Action_Queue_Item{
				cron_expr        = cron_expr,
				timezone         = timezone_str,
				blackout_dates   = blackout_dates,
				active_from_ms   = active_from_ms,
				active_until_ms  = active_until_ms,
				interval_seconds = interval_secs,
				target_run_at_ms = 0,
			}
			computed_slot, computed_ok := action_scheduler_compute_next_run(dummy_item, now_ms)
			if computed_ok {
				run_at_ms = computed_slot
				run_at = action_scheduler_format_rfc3339_utc(computed_slot)
			}
		}

		found_idx := -1
		for i in 0..<len(bridge_action_sched_state.queue) {
			if bridge_action_sched_state.queue[i].id == id {
				found_idx = i
				break
			}
		}

		if found_idx >= 0 {
			q := &bridge_action_sched_state.queue[found_idx]
			is_locally_in_flight := q.in_flight && (now_ms - q.leased_at_ms < ACTION_SCHEDULER_DEFAULT_LEASE_WINDOW_MS)
			action_queue_item_free(q)
			q.id = strings.clone(id)
			q.target_instance_id = strings.clone(target)
			q.prompt_text = strings.clone(prompt)
			q.cron_expr = strings.clone(cron_expr)
			q.timezone = strings.clone(timezone_str)
			q.blackout_dates = strings.clone(blackout_dates)
			q.active_from = strings.clone(active_from)
			q.active_until = strings.clone(active_until)
			q.active_from_ms = active_from_ms
			q.active_until_ms = active_until_ms
			q.target_run_at = strings.clone(run_at)
			q.target_run_at_ms = run_at_ms
			q.interval = strings.clone(interval)
			q.interval_seconds = interval_secs
			q.state = strings.clone(state)
			q.target_agent_id = strings.clone(target_agent)
			q.target_bridge_id = strings.clone(target_bridge)
			q.target_provider = strings.clone(target_provider)
			q.target_model = strings.clone(target_model)
			q.target_project_id = strings.clone(target_project)
			q.instance_strategy = strings.clone(instance_strategy)
			q.last_spawned_instance_id = strings.clone(last_spawned)
			if is_locally_in_flight {
				q.in_flight = true
			} else {
				q.in_flight = in_flight
				q.leased_at_ms = leased_at_ms
			}
		} else {
			append(&bridge_action_sched_state.queue, Action_Queue_Item{
				id                 = strings.clone(id),
				target_instance_id = strings.clone(target),
				prompt_text        = strings.clone(prompt),
				cron_expr          = strings.clone(cron_expr),
				timezone           = strings.clone(timezone_str),
				blackout_dates     = strings.clone(blackout_dates),
				active_from        = strings.clone(active_from),
				active_until       = strings.clone(active_until),
				active_from_ms     = active_from_ms,
				active_until_ms    = active_until_ms,
				target_run_at      = strings.clone(run_at),
				target_run_at_ms   = run_at_ms,
				interval           = strings.clone(interval),
				interval_seconds   = interval_secs,
				state              = strings.clone(state),
				in_flight          = in_flight,
				leased_at_ms       = leased_at_ms,
				target_agent_id    = strings.clone(target_agent),
				target_bridge_id   = strings.clone(target_bridge),
				target_provider    = strings.clone(target_provider),
				target_model        = strings.clone(target_model),
				target_project_id  = strings.clone(target_project),
				instance_strategy        = strings.clone(instance_strategy),
				last_spawned_instance_id = strings.clone(last_spawned),
			})
		}
	}

	// Prune items deleted on Hub
	for i := len(bridge_action_sched_state.queue) - 1; i >= 0; i -= 1 {
		item_id := bridge_action_sched_state.queue[i].id
		if !seen[item_id] {
			action_queue_item_free(&bridge_action_sched_state.queue[i])
			ordered_remove(&bridge_action_sched_state.queue, i)
		}
	}

	bridge_action_sched_state.last_etag = fmt.tprintf("W/\"%d\"", version_to_sync)
	bridge_action_sched_state.synced_actions_version = version_to_sync
	bridge_action_sched_state.last_full_reconcile_ms = now_ms

	return true
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
	if strings.trim_space(bridge_config.bridge_token) == "" || strings.trim_space(bridge_config.daemon_url) == "" {
		return false, 0, ""
	}
	path := fmt.tprintf("/api/v1/bridge/actions/%s/execute", action_id)
	auth_header := strings.concatenate({"Bearer ", bridge_config.bridge_token})
	defer delete(auth_header)
	headers := [?]http.Header{
		{name = "Authorization", value = auth_header},
		{name = "Content-Type", value = "application/json"},
	}
	// Build the JSON body WITHOUT fmt.tprintf: Odin's fmt treats literal '{'/'}'
	// as format-verb delimiters, so a JSON object literal comes out corrupted
	// (e.g. "%!(MISSING CLOSE BRACE)target_run_at..."). That corruption made the hub
	// parse an empty target_run_at and mark cron actions completed while the bridge
	// kept re-firing them -> the every-minute reschedule loop. All three values are
	// bridge-generated ids/RFC3339 timestamps (no characters needing JSON escaping),
	// so plain concatenation into the builder is safe. last_spawned_instance_id is
	// sent only for fresh_per_run fires so the hub records it (REQ-SCHED-2).
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	strings.write_byte(&sb, '{')
	need_comma := false
	if next_target_run_at != "" {
		strings.write_string(&sb, "\"target_run_at\":\"")
		strings.write_string(&sb, next_target_run_at)
		strings.write_byte(&sb, '"')
		need_comma = true
	}
	if instance_id != "" {
		if need_comma do strings.write_byte(&sb, ',')
		strings.write_string(&sb, "\"instance_id\":\"")
		strings.write_string(&sb, instance_id)
		strings.write_byte(&sb, '"')
		need_comma = true
	}
	if last_spawned_instance_id != "" {
		if need_comma do strings.write_byte(&sb, ',')
		strings.write_string(&sb, "\"last_spawned_instance_id\":\"")
		strings.write_string(&sb, last_spawned_instance_id)
		strings.write_byte(&sb, '"')
		need_comma = true
	}
	strings.write_byte(&sb, '}')
	body := strings.to_string(sb)
	resp, ok := bridge_http_request_retry("POST", bridge_config.daemon_url, path, body, headers[:], http.DEFAULT_TIMEOUT_MS)
	if !ok do return false, 0, ""
	return resp.status == 200, resp.status, resp.body
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
	if due.target_agent_id == "" do return "", false
	if strings.trim_space(bridge_config.bridge_token) == "" || strings.trim_space(bridge_config.daemon_url) == "" {
		return "", false
	}

	auth_header := strings.concatenate({"Bearer ", bridge_config.bridge_token})
	defer delete(auth_header)
	headers := [?]http.Header{
		{name = "Authorization", value = auth_header},
		{name = "Content-Type", value = "application/json"},
	}

	// For the default (reuse) strategy, enumerate existing instances of the agent-id and
	// reuse/wake one that MATCHES the action's bridge+project targeting. fresh_per_run
	// skips this entirely and always mints a new instance below (REQ-SCHED-2).
	force_create := due.instance_strategy == "fresh_per_run"
	if !force_create {
		// 1. Check existing instances via GET /api/v1/agent-instances?agent_id=...
		list_path := fmt.tprintf("/api/v1/agent-instances?agent_id=%s", due.target_agent_id)
		resp, ok := bridge_http_request_retry("GET", bridge_config.daemon_url, list_path, "", headers[:], http.DEFAULT_TIMEOUT_MS)
		if ok && resp.status == 200 {
			defer delete(resp.body)
			data_arr, has_data := bridge_provider_json_extract_array(resp.body, "data")
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
					bridge_task_wake_if_needed(c.id, now_ms)
					if bridge_action_scheduler_await_ready(c.id, 3000) {
						return c.id, true
					}
				}
			}
		} else if ok {
			delete(resp.body)
		}
	}

	// 2. No reusable instance (or fresh_per_run); launch a new one via POST /api/v1/agent-instances
	b := strings.builder_make()
	strings.write_string(&b, "{\"agent_id\":\"")
	bridge_runtime_write_json_string(&b, due.target_agent_id)
	strings.write_string(&b, "\"")
	if due.target_bridge_id != "" {
		strings.write_string(&b, ",\"bridge_id\":\"")
		bridge_runtime_write_json_string(&b, due.target_bridge_id)
		strings.write_string(&b, "\"")
	}
	if due.target_provider != "" {
		strings.write_string(&b, ",\"provider\":\"")
		bridge_runtime_write_json_string(&b, due.target_provider)
		strings.write_string(&b, "\"")
	}
	if due.target_model != "" {
		strings.write_string(&b, ",\"model\":\"")
		bridge_runtime_write_json_string(&b, due.target_model)
		strings.write_string(&b, "\"")
	}
	if due.target_project_id != "" {
		strings.write_string(&b, ",\"project_id\":\"")
		bridge_runtime_write_json_string(&b, due.target_project_id)
		strings.write_string(&b, "\"")
	}
	strings.write_string(&b, "}")
	payload := strings.to_string(b)
	defer delete(payload)

	launch_resp, launch_ok := bridge_http_request_retry("POST", bridge_config.daemon_url, "/api/v1/agent-instances", payload, headers[:], http.DEFAULT_TIMEOUT_MS)
	if !launch_ok do return "", false
	defer delete(launch_resp.body)

	if launch_resp.status != 200 && launch_resp.status != 201 {
		return "", false
	}

	new_instance_id := extract_json_string(launch_resp.body, "agent_instance_id", "")
	if new_instance_id == "" do return "", false

	if bridge_action_scheduler_await_ready(new_instance_id, 5000) {
		return new_instance_id, true
	}
	return new_instance_id, true
}

bridge_action_scheduler_tick :: proc() -> int {
	now_ms := bridge_runtime_now_ms()
	actions := 0

	// 1. Sync if version changed, uninitialized, or daily reconcile backstop reached
	sync_needed := false
	sync.mutex_lock(&bridge_action_sched_state.mutex)
	if bridge_action_sched_state.known_actions_version != bridge_action_sched_state.synced_actions_version ||
	   bridge_action_sched_state.synced_actions_version < 0 ||
	   (bridge_action_sched_state.last_full_reconcile_ms > 0 && now_ms - bridge_action_sched_state.last_full_reconcile_ms >= ACTION_SCHEDULER_RECONCILE_INTERVAL_MS) {
		sync_needed = true
	}
	sync.mutex_unlock(&bridge_action_sched_state.mutex)

	if sync_needed {
		bridge_action_scheduler_sync()
	}

	// 2. Lease recovery on in-flight items
	sync.mutex_lock(&bridge_action_sched_state.mutex)
	for i in 0..<len(bridge_action_sched_state.queue) {
		item := &bridge_action_sched_state.queue[i]
		if action_scheduler_recover_lease(item, now_ms, ACTION_SCHEDULER_DEFAULT_LEASE_WINDOW_MS) {
			fmt.printfln("ACTION_SCHED_LEASE_RECOVERY id=%s target=%s", item.id, item.target_instance_id)
		}
	}

	// Collect due items to evaluate
	due_items := make([dynamic]Action_Queue_Item)
	defer delete(due_items)
	for item in bridge_action_sched_state.queue {
		if action_scheduler_can_claim(item, now_ms, ACTION_SCHEDULER_DEFAULT_LEASE_WINDOW_MS) {
			append(&due_items, item)
		}
	}
	sync.mutex_unlock(&bridge_action_sched_state.mutex)

	// 3. Process due items
	for due in due_items {
		target_instance_id := due.target_instance_id
		is_ready := false
		is_fresh := false // fresh_per_run mint on this fire -> persist + reap after execute

		if target_instance_id != "" {
			inst, found := bridge_runtime_instance_snapshot(target_instance_id)
			is_ready = found && (inst.runtime_status == "running" || inst.runtime_status == "idle")

			if !is_ready {
				if !found || !bridge_runtime_status_active(inst.runtime_status) {
					bridge_task_wake_if_needed(target_instance_id, now_ms)
				}
				if bridge_action_scheduler_await_ready(target_instance_id, 3000) {
					is_ready = true
				}
			}
		} else if due.target_agent_id != "" {
			resolved_id, resolved_ok := bridge_action_scheduler_resolve_or_launch_instance(due, now_ms)
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
			if bridge_action_sched_state.queue[i].id == due.id {
				if action_scheduler_can_claim(bridge_action_sched_state.queue[i], now_ms, ACTION_SCHEDULER_DEFAULT_LEASE_WINDOW_MS) {
					action_scheduler_claim(&bridge_action_sched_state.queue[i], now_ms)
					claimed = true
				}
				break
			}
		}
		sync.mutex_unlock(&bridge_action_sched_state.mutex)

		if !claimed do continue

		// Compute next fire time (skipping blackouts and cron-excluded days)
		next_run_ms, has_next := action_scheduler_compute_next_run(due, now_ms)
		next_target_run_at := action_scheduler_format_rfc3339_utc(next_run_ms) if has_next else ""

		// For fresh_per_run, carry the newly minted instance id so the hub records it as
		// last_spawned_instance_id; reuse fires never send it (keeps the row untouched).
		spawned_to_persist := target_instance_id if is_fresh else ""

		ok, status, body := bridge_action_scheduler_execute(due.id, next_target_run_at, target_instance_id, spawned_to_persist)
		if ok {
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
			if body != "" do delete(body)
			sync.mutex_lock(&bridge_action_sched_state.mutex)
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
