package main

// Local ham.ext.v1 reduction. Only explicitly leased subscriptions publish
// sanitized current tool and permission state. Raw telemetry stays local.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"

// Local bounded signal metadata. Raw events are never queued or relayed.
BRIDGE_EXT_MAX_INSTANCES :: 256

Bridge_Ext_Instance_State :: struct {
	agent_instance_id: string,
	provider:          string,
	ext_version:       string,
	capabilities:      [dynamic]string,
	last_event_at_ms:  i64,
	events_accepted:   int,
	events_dropped:    int,
	token_usage:       Bridge_Ext_Token_Usage, // extension_token_usage.odin
	// Frozen usage of the last run the hub stopped or restarted (T3r), sent as
	// agent_instance_status.token_usage_final; token_final_run = 0 means none.
	token_final:       Bridge_Ext_Token_Usage,
	token_final_run:   int,
	// From the launch command (context_window.odin resolves the window from
	// these). Empty when the bridge has no launch record for the instance.
	launch_provider:   string,
	model:             string,
	provider_profile:  string,
	resolved_model:    string,
	// session_id whose usage_unavailable was already logged (once per session;
	// only logged when the provider hello advertised the usage capability).
	usage_dark_logged_session: string,
}

Bridge_Ext_Ingest_Result :: struct {
	accepted: int,
	rejected: int,
	errors:   [dynamic]string, // pre-rendered {"index":N,"error":"…"} objects
	fatal:    contracts.Ext_Error, // whole-request failure (unparseable / single invalid event)
}

bridge_ext_mutex: sync.Mutex
bridge_ext_states: [dynamic]Bridge_Ext_Instance_State

// Local metadata outlives any request (and any test's tracking allocator),
// so every proc that allocates into it pins the heap allocator.
@(private = "file")
bridge_ext_allocator :: proc() -> runtime.Allocator {
	return runtime.heap_allocator()
}

// bridge_ext_activity_source names the activity source for a provider. It must
// contain "extension" so bridge_runtime_activity_source_rank ranks it 80.
bridge_ext_activity_source :: proc(provider: string) -> string {
	p := strings.to_lower(strings.trim_space(provider), context.temp_allocator)
	if p == "" do return "agent_extension"
	return fmt.tprintf("%s_extension", p)
}

@(private = "file")
bridge_ext_state_locked :: proc(instance_id: string) -> ^Bridge_Ext_Instance_State {
	for &s in bridge_ext_states {
		if s.agent_instance_id == instance_id do return &s
	}
	if len(bridge_ext_states) >= BRIDGE_EXT_MAX_INSTANCES do return nil
	append(&bridge_ext_states, Bridge_Ext_Instance_State{agent_instance_id = strings.clone(instance_id)})
	return &bridge_ext_states[len(bridge_ext_states) - 1]
}

// bridge_ext_raw_tool_input returns the event's tool.input object as JSON (temp
// allocator), or "" when absent. Auto-resolve uses it to tell parallel calls of
// the same tool apart.
bridge_ext_raw_tool_input :: proc(raw: string) -> string {
	value, err := json.parse_string(raw, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err != .None do return ""
	root, _ := value.(json.Object)
	tool, _ := root["tool"].(json.Object)
	input, is_obj := tool["input"].(json.Object)
	if !is_obj do return ""
	bytes, merr := json.marshal(input, allocator = context.temp_allocator)
	if merr != nil do return ""
	return string(bytes)
}

bridge_ext_ingest :: proc(rec: Bridge_Local_Agent_Token_Record, params: string, now: i64) -> (res: Bridge_Ext_Ingest_Result) {
	context.allocator = bridge_ext_allocator()
	instance_id := rec.agent_instance_id
	raws, split_err := contracts.ext_split_events(params)
	if split_err != .None {
		res.fatal = split_err
		return
	}
	defer contracts.ext_split_events_destroy(raws)

	for raw, i in raws {
		ev, perr := contracts.ext_parse_event(raw)
		if perr != .None {
			res.rejected += 1
			b := strings.builder_make()
			strings.write_string(&b, fmt.tprintf("{{\"index\":%d,\"error\":\"", i))
			bridge_local_write_json_string(&b, contracts.ext_error_message(perr))
			strings.write_string(&b, "\"}")
			append(&res.errors, strings.to_string(b))
			if len(raws) == 1 do res.fatal = perr
			continue
		}
		defer contracts.ext_event_destroy(&ev)
		bridge_tool_live_event(rec, ev, raw)
		if bridge_startup_event(ev) {
			// A launch's first readiness completes a context rollover restart (T6).
			if _, newly_ready := bridge_startup_accept(rec, now); newly_ready do bridge_rollover_on_start_success(instance_id)
		}

		// A later event proves a permission prompt was answered in the terminal.
		tool_input := ""
		if ev.kind == .Tool_Start || ev.kind == .Tool_End do tool_input = bridge_ext_raw_tool_input(raw)
		_ = bridge_blockers_on_extension_event(instance_id, ev, now, tool_input)
		activity, has_activity := contracts.ext_activity_for_event(ev)
		// Activity is reported after the accumulator and the context rollover
		// (context_rollover.odin) saw the event: a Stop that starts a rollover
		// must already be withheld as active, never reported idle.
		main_agent := ev.agent_id == "" && (ev.agent_type == "" || ev.agent_type == "main")
		defer if has_activity do bridge_runtime_note_agent_activity(instance_id, activity, bridge_ext_activity_source(ev.provider))
		defer if main_agent do bridge_rollover_on_ext_event(instance_id, has_activity && activity == "idle", now)

		sync.mutex_lock(&bridge_ext_mutex)
		s := bridge_ext_state_locked(instance_id)
		if s == nil {
			sync.mutex_unlock(&bridge_ext_mutex)
			res.accepted += 1
			continue
		}
		if ev.kind == .Hello {
			delete(s.provider); delete(s.ext_version)
			s.provider = strings.clone(ev.provider)
			s.ext_version = strings.clone(ev.ext_version)
			for c in s.capabilities do delete(c)
			clear(&s.capabilities)
			for c in ev.capabilities do append(&s.capabilities, strings.clone(c))
		} else if s.provider == "" {
			s.provider = strings.clone(ev.provider)
			s.ext_version = strings.clone(ev.ext_version)
		}
		s.last_event_at_ms = now
		s.events_accepted += 1
		token_changed := bridge_ext_token_usage_apply(&s.token_usage, ev, now)
		if ev.usage_unavailable && s.token_usage.usage_supported && ev.session_id != "" && s.usage_dark_logged_session != ev.session_id {
			delete(s.usage_dark_logged_session)
			s.usage_dark_logged_session = strings.clone(ev.session_id)
			fmt.eprintfln("extension: %s transcript usage unavailable for instance %s session %s; context usage will not be reported (logged once per session)", ev.provider, instance_id, ev.session_id)
		}
		sync.mutex_unlock(&bridge_ext_mutex)
		// Only the throttled snapshot goes upstream (agent_instance_status.token_usage).
		if token_changed do bridge_ext_token_enqueue_due(now, instance_id)
		res.accepted += 1
	}
	return
}

bridge_ext_ingest_result_destroy :: proc(res: ^Bridge_Ext_Ingest_Result) {
	context.allocator = bridge_ext_allocator()
	for e in res.errors do delete(e)
	delete(res.errors)
}

bridge_ext_ingest_result_json :: proc(res: Bridge_Ext_Ingest_Result) -> string {
	b := strings.builder_make()
	strings.write_string(&b, fmt.tprintf("{{\"accepted\":%d,\"rejected\":%d,\"errors\":[", res.accepted, res.rejected))
	for e, i in res.errors {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, e)
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// bridge_ext_status_json renders agent.extension.status for one instance.
bridge_ext_status_json :: proc(instance_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"agent_instance_id\":\"")
	bridge_local_write_json_string(&b, instance_id)
	sync.mutex_lock(&bridge_ext_mutex)
	provider, version: string
	last: i64
	accepted, dropped, queued: int
	caps := make([dynamic]string, context.temp_allocator)
	tokens_json, session_id: string
	for s in bridge_ext_states {
		if s.agent_instance_id != instance_id do continue
		provider = strings.clone(s.provider, context.temp_allocator)
		version = strings.clone(s.ext_version, context.temp_allocator)
		last = s.last_event_at_ms
		accepted = s.events_accepted
		dropped = s.events_dropped
		for c in s.capabilities do append(&caps, strings.clone(c, context.temp_allocator))
		tb := strings.builder_make(context.temp_allocator)
		bridge_ext_token_usage_write_json(&tb, s.token_usage)
		tokens_json = strings.to_string(tb)
		session_id = strings.clone(s.token_usage.session_id, context.temp_allocator)
		break
	}
	sync.mutex_unlock(&bridge_ext_mutex)
	strings.write_string(&b, "\",\"provider\":\""); bridge_local_write_json_string(&b, provider)
	strings.write_string(&b, "\",\"ext_version\":\""); bridge_local_write_json_string(&b, version)
	strings.write_string(&b, "\",\"capabilities\":[")
	for c, i in caps {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_byte(&b, '"'); bridge_local_write_json_string(&b, c); strings.write_byte(&b, '"')
	}
	strings.write_string(&b, fmt.tprintf("],\"last_event_at_ms\":%d,\"events_accepted\":%d,\"events_dropped\":%d,\"queued\":%d", last, accepted, dropped, queued))
	activity, source: string
	if inst, ok := bridge_runtime_instance_snapshot(instance_id); ok {
		activity = inst.activity_status
		source = inst.activity_source
	}
	strings.write_string(&b, ",\"activity_status\":\""); bridge_local_write_json_string(&b, activity)
	strings.write_string(&b, "\",\"activity_source\":\""); bridge_local_write_json_string(&b, source)
	// token_usage is null until the instance sent any event; session_id is the
	// provider session its counters belong to (local only, never sent upstream).
	strings.write_string(&b, "\",\"session_id\":\""); bridge_local_write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"token_usage\":")
	strings.write_string(&b, tokens_json if tokens_json != "" else "null")
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// bridge_ext_handle_rpc fulfils agent.extension.event / agent.extension.status.
bridge_ext_handle_rpc :: proc(request_id, method, params: string, rec: Bridge_Local_Agent_Token_Record) -> string {
	if method == "agent.extension.status" {
		return bridge_local_response_data(request_id, bridge_ext_status_json(rec.agent_instance_id))
	}
	res := bridge_ext_ingest(rec, params, bridge_runtime_now_ms())
	defer bridge_ext_ingest_result_destroy(&res)
	if res.accepted > 0 {
		bridge_startup_worker_ensure_started()
	}
	if res.fatal != .None {
		return bridge_local_response_error(request_id, "bad_request", contracts.ext_error_message(res.fatal))
	}
	return bridge_local_response_data(request_id, bridge_ext_ingest_result_json(res))
}

Bridge_Ext_Context_Window_Instance :: struct {
	agent_instance_id, provider, model, provider_profile, resolved_model: string,
	// Provider-reported window and mismatch flag (0 / false when never reported
	// or when an override is in force).
	reported_window: i64,
	window_mismatch: bool,
}

// bridge_ext_token_capture_final freezes instance_id's current token snapshot
// as the final usage of run run_count, at a hub-requested stop (stop_agent,
// wake_agent stop list) or restart (a genuine relaunch). reset_live also zeroes
// the live counters (keeping the resolved window) so the finished run's figures
// never leak into the next run; the zeroed snapshot still goes upstream so the
// hub's latest snapshot restarts too. A status push is queued when a final was
// captured. Returns whether one was. run_count <= 0 (no hub generation known)
// captures nothing: the hub could not de-duplicate it.
bridge_ext_token_capture_final :: proc(instance_id: string, run_count: int, reset_live := false, now: i64 = 0) -> bool {
	context.allocator = bridge_ext_allocator()
	if strings.trim_space(instance_id) == "" || run_count <= 0 do return false
	captured := false
	sync.mutex_lock(&bridge_ext_mutex)
	for &s in bridge_ext_states {
		if s.agent_instance_id != instance_id do continue
		if s.token_usage.updated_at_ms == 0 do break
		// A later run's final is never overwritten by an older generation.
		if run_count >= s.token_final_run {
			bridge_ext_token_usage_destroy(&s.token_final)
			s.token_final = bridge_ext_token_usage_clone(s.token_usage)
			s.token_final_run = run_count
			captured = true
		}
		if reset_live {
			bridge_ext_token_usage_reset(&s.token_usage, "")
			s.token_usage.updated_at_ms = now if now > 0 else max(s.token_final.updated_at_ms, 1)
			s.token_usage.dirty = true
		}
		break
	}
	sync.mutex_unlock(&bridge_ext_mutex)
	if captured {
		sync.mutex_lock(&bridge_runtime_mutex)
		bridge_runtime_enqueue_status_push_locked(instance_id)
		sync.mutex_unlock(&bridge_runtime_mutex)
	}
	return captured
}

// bridge_ext_note_launch records an instance's provider/model/profile at launch
// and resolves its context window. Resolution runs before bridge_ext_mutex is
// taken: it reads the discovery cache and the window config under their own locks.
bridge_ext_note_launch :: proc(instance_id, provider, model, provider_profile: string) {
	context.allocator = bridge_ext_allocator()
	if strings.trim_space(instance_id) == "" do return
	resolved := bridge_context_window_resolved_model(provider, model, provider_profile)
	r := bridge_context_window_resolve(provider, model, resolved)
	sync.mutex_lock(&bridge_ext_mutex)
	s := bridge_ext_state_locked(instance_id)
	if s != nil {
		delete(s.usage_dark_logged_session); s.usage_dark_logged_session = ""
		delete(s.launch_provider); delete(s.model); delete(s.provider_profile); delete(s.resolved_model)
		s.launch_provider = strings.clone(provider)
		s.model = strings.clone(model)
		s.provider_profile = strings.clone(provider_profile)
		s.resolved_model = strings.clone(resolved)
		_ = bridge_ext_token_usage_set_window(&s.token_usage, r)
	}
	sync.mutex_unlock(&bridge_ext_mutex)
}

// bridge_ext_context_window_instances lists instances with a launch record
// (temp allocator).
bridge_ext_context_window_instances :: proc() -> [dynamic]Bridge_Ext_Context_Window_Instance {
	out := make([dynamic]Bridge_Ext_Context_Window_Instance, context.temp_allocator)
	sync.mutex_lock(&bridge_ext_mutex)
	defer sync.mutex_unlock(&bridge_ext_mutex)
	for s in bridge_ext_states {
		if s.launch_provider == "" do continue
		append(&out, Bridge_Ext_Context_Window_Instance{
			strings.clone(s.agent_instance_id, context.temp_allocator),
			strings.clone(s.launch_provider, context.temp_allocator),
			strings.clone(s.model, context.temp_allocator),
			strings.clone(s.provider_profile, context.temp_allocator),
			strings.clone(s.resolved_model, context.temp_allocator),
			s.token_usage.reported_window,
			s.token_usage.window_mismatch,
		})
	}
	return out
}

// bridge_ext_context_windows_refresh re-resolves every launched instance after
// an override changed; a changed window is pushed upstream with the next due
// token snapshot.
bridge_ext_context_windows_refresh :: proc() {
	insts := bridge_ext_context_window_instances()
	if len(insts) == 0 do return
	resolutions := make([]Bridge_Context_Window_Resolution, len(insts), context.temp_allocator)
	for inst, i in insts do resolutions[i] = bridge_context_window_resolve(inst.provider, inst.model, inst.resolved_model)
	sync.mutex_lock(&bridge_ext_mutex)
	for inst, i in insts {
		for &s in bridge_ext_states {
			if s.agent_instance_id != inst.agent_instance_id do continue
			_ = bridge_ext_token_usage_set_window(&s.token_usage, resolutions[i])
			break
		}
	}
	sync.mutex_unlock(&bridge_ext_mutex)
	_ = bridge_ext_token_enqueue_due(bridge_runtime_now_ms())
}

// bridge_ext_context_window_for reports an instance's resolved window, its
// source and the current context percentage (-1 when unknown). An instance
// without a launch record gets the default.
bridge_ext_context_window_for :: proc(instance_id: string) -> (window: i64, source: Bridge_Context_Window_Source, context_pct: i64) {
	sync.mutex_lock(&bridge_ext_mutex)
	defer sync.mutex_unlock(&bridge_ext_mutex)
	for s in bridge_ext_states {
		if s.agent_instance_id != instance_id do continue
		return bridge_ext_token_usage_window(s.token_usage), s.token_usage.window_source, bridge_ext_token_usage_context_pct(s.token_usage)
	}
	return BRIDGE_EXT_TOKEN_DEFAULT_WINDOW, .Default, -1
}

// bridge_ext_token_usage_reset_instance zeroes an instance's token counters (a
// context rollover restart starts a fresh context) and queues the snapshot.
bridge_ext_token_usage_reset_instance :: proc(instance_id: string) {
	context.allocator = bridge_ext_allocator()
	sync.mutex_lock(&bridge_ext_mutex)
	found := false
	for &s in bridge_ext_states {
		if s.agent_instance_id != instance_id do continue
		bridge_ext_token_usage_reset(&s.token_usage, "")
		s.token_usage.updated_at_ms = bridge_runtime_now_ms()
		s.token_usage.dirty = true
		found = true
		break
	}
	sync.mutex_unlock(&bridge_ext_mutex)
	if found do bridge_ext_token_enqueue_due(bridge_runtime_now_ms(), instance_id)
}
