package main

// Per-instance token accumulator fed by ham.ext.v1 events (chain "Estimate
// agent tokens via extensions", T2). It reduces tool.end metrics and provider
// usage blocks into one small snapshot per agent instance. Raw events are never
// kept: only the counters below exist, and only that snapshot goes upstream as
// the optional `token_usage` object of agent_instance_status, throttled.

import "core:fmt"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"

// An event-driven push is sent at most once per interval per instance...
BRIDGE_EXT_TOKEN_PUSH_MIN_INTERVAL_MS :: 10_000
// ...unless context_tokens moved by at least this many percentage points of the
// instance's resolved context window (context_window.odin) since the last push.
BRIDGE_EXT_TOKEN_PUSH_DELTA_PP :: 5
// Window of an instance the bridge has no launch record for (equals the shipped
// config's default_window; a test keeps them in step).
BRIDGE_EXT_TOKEN_DEFAULT_WINDOW :: 200_000
// A reported window this far (percent) from the config/default one is a mismatch.
BRIDGE_EXT_WINDOW_MISMATCH_PCT :: 10
// A context drop to (100 - this)% or less of the previous value is a compaction.
BRIDGE_EXT_COMPACTION_DROP_PCT :: 50
// Conservative context estimate for an instance with no provider usage block
// (Antigravity: metrics only; Pi: no extension): the tool-traffic sum
// (est_tokens_total) understates the real context (prompts, replies, thinking),
// so it is scaled by this factor. Only used while the provider reported no
// context size (context_source = "estimate"); reported usage always wins. The
// estimate restarts from zero on a session start and on a compaction event.
BRIDGE_EXT_ESTIMATE_MULTIPLIER :: 1.5
BRIDGE_EXT_ESTIMATE_SOURCE :: "estimate"

Bridge_Ext_Token_Usage :: struct {
	session_id:          string, // owned; provider session the counters belong to
	tool_calls:          i64,
	est_tokens_total:    i64, // sum of tool.end metrics.est_tokens
	est_base:           i64, // est_tokens_total at the last compaction; the estimate counts from here
	has_context:         bool,
	context_tokens:      i64, // latest provider-reported context size
	context_source:      string, // owned; usage.source of context_tokens
	// Effective window: the override, else a provider-reported window, else the
	// config/default resolution; 0 = no launch record, i.e. the default. All of
	// the window fields below survive resets.
	context_window:      i64,
	window_source:       Bridge_Context_Window_Source,
	// Last override/config/default resolution (0 = none yet, i.e. the default).
	resolved_window:     i64,
	resolved_source:     Bridge_Context_Window_Source,
	// usage.context_window from the provider (0 = never reported).
	reported_window:     i64,
	// reported_window differs from the config/default resolution by > 10%.
	// Never set while an override is in force.
	window_mismatch:     bool,
	has_output_total:    bool,
	output_tokens_total: i64,
	compactions:         i64,
	updated_at_ms:       i64, // 0 = no token signal seen yet
	// From the provider hello: has_usage_cap = a hello was seen; usage_supported =
	// it listed the "usage" capability (provider emits usage.context_tokens).
	// Neither is set for a provider without an extension (Pi): flag omitted.
	has_usage_cap:       bool,
	usage_supported:     bool,

	// Upstream throttle state (not part of the snapshot).
	dirty:               bool, // changed since the last push
	has_pushed:          bool,
	last_push_at_ms:     i64,
	last_push_context:   i64,
}

// bridge_ext_token_usage_reset clears the counters for a new provider session,
// keeping the throttle state so a reset still reaches the hub promptly.
// Allocations use context.allocator (the ext state's heap allocator).
bridge_ext_token_usage_reset :: proc(u: ^Bridge_Ext_Token_Usage, session_id: string) {
	new_id := strings.clone(session_id) // session_id may alias u.session_id
	delete(u.session_id); delete(u.context_source)
	dirty, has_pushed, last_at, last_ctx := u.dirty, u.has_pushed, u.last_push_at_ms, u.last_push_context
	window, source, resolved, resolved_src, reported, mismatch := u.context_window, u.window_source, u.resolved_window, u.resolved_source, u.reported_window, u.window_mismatch
	has_cap, supported := u.has_usage_cap, u.usage_supported
	u^ = {}
	u.session_id = new_id
	u.dirty, u.has_pushed, u.last_push_at_ms, u.last_push_context = dirty, has_pushed, last_at, last_ctx
	u.context_window, u.window_source, u.resolved_window, u.resolved_source, u.reported_window, u.window_mismatch = window, source, resolved, resolved_src, reported, mismatch
	u.has_usage_cap, u.usage_supported = has_cap, supported
}

bridge_ext_token_usage_destroy :: proc(u: ^Bridge_Ext_Token_Usage) {
	delete(u.session_id); delete(u.context_source)
	u^ = {}
}

// bridge_ext_token_usage_apply folds one event into u and reports whether the
// snapshot changed. Resets on a session start (except a compaction restart,
// whose context drop is counted below instead) and on a new session_id.
bridge_ext_token_usage_apply :: proc(u: ^Bridge_Ext_Token_Usage, ev: contracts.Ext_Event, now: i64) -> (changed: bool) {
	session_start := ev.kind == .Session && ev.session_phase == "start" && ev.session_source != "compact"
	new_session := ev.session_id != "" && u.session_id != "" && ev.session_id != u.session_id
	if session_start || new_session {
		bridge_ext_token_usage_reset(u, ev.session_id if ev.session_id != "" else u.session_id)
		changed = true // a zeroed snapshot tells the hub the counters restarted
	} else if u.session_id == "" && ev.session_id != "" {
		u.session_id = strings.clone(ev.session_id)
	}

	if ev.kind == .Hello {
		supported := false
		for c in ev.capabilities do if c == "usage" do supported = true
		if !u.has_usage_cap || u.usage_supported != supported do changed = true
		u.has_usage_cap, u.usage_supported = true, supported
	}
	if ev.kind == .Compaction {
		// Both phases: the context shrank (or is about to), so the tool-traffic
		// estimate restarts. est_tokens_total itself is a lifetime sum and stays.
		if u.est_base != u.est_tokens_total do changed = true
		u.est_base = u.est_tokens_total
	}
	if ev.kind == .Tool_End {
		u.tool_calls += 1
		if ev.has_metrics do u.est_tokens_total += max(ev.metrics.est_tokens, 0)
		changed = true
	}
	if ev.has_usage {
		ctx := max(ev.usage.context_tokens, 0)
		// est_tokens_total is a running sum of tool traffic and is kept across
		// compactions; only the provider's context figure drops.
		if u.has_context && u.context_tokens > 0 && ctx * 100 <= u.context_tokens * (100 - BRIDGE_EXT_COMPACTION_DROP_PCT) {
			u.compactions += 1
		}
		u.has_context = true
		u.context_tokens = ctx
		if ev.usage.source != u.context_source {
			delete(u.context_source)
			u.context_source = strings.clone(ev.usage.source)
		}
		if ev.usage.has_context_window && ev.usage.context_window > 0 && ev.usage.context_window <= BRIDGE_CONTEXT_WINDOW_MAX {
			u.reported_window = ev.usage.context_window
			bridge_ext_token_usage_window_recompute(u)
		}
		if ev.usage.has_output_tokens_total {
			u.has_output_total = true
			u.output_tokens_total = max(ev.usage.output_tokens_total, 0)
		}
		changed = true
	}
	if changed {
		u.updated_at_ms = now
		u.dirty = true
	}
	return
}

bridge_ext_token_usage_window :: proc(u: Bridge_Ext_Token_Usage) -> i64 {
	return u.context_window if u.context_window > 0 else BRIDGE_EXT_TOKEN_DEFAULT_WINDOW
}

// bridge_ext_token_usage_window_recompute derives the effective window, its
// source and window_mismatch from the last resolution and the reported window:
// override > reported > config > default. The mismatch compares the reported
// window to the config/default resolution (an unresolved instance counts as
// the default) and is logged when it appears or its figures change.
bridge_ext_token_usage_window_recompute :: proc(u: ^Bridge_Ext_Token_Usage) {
	resolved := u.resolved_window if u.resolved_window > 0 else BRIDGE_EXT_TOKEN_DEFAULT_WINDOW
	was_mismatch := u.window_mismatch
	u.window_mismatch = false
	if u.resolved_source != .Override && u.reported_window > 0 {
		u.context_window, u.window_source = u.reported_window, .Reported
		diff := abs(u.reported_window - resolved)
		u.window_mismatch = diff * 100 > resolved * BRIDGE_EXT_WINDOW_MISMATCH_PCT
		if u.window_mismatch && !was_mismatch {
			fmt.eprintfln("bridge context window mismatch: provider reported %d, config/default says %d", u.reported_window, resolved)
		}
	} else {
		u.context_window, u.window_source = u.resolved_window, u.resolved_source
	}
}

// bridge_ext_token_usage_set_window records a resolution and reports whether
// the effective window, its source or the mismatch flag changed; a change marks
// the snapshot dirty once it has content.
bridge_ext_token_usage_set_window :: proc(u: ^Bridge_Ext_Token_Usage, r: Bridge_Context_Window_Resolution) -> bool {
	window, source, mismatch := u.context_window, u.window_source, u.window_mismatch
	u.resolved_window, u.resolved_source = r.context_window, r.source
	bridge_ext_token_usage_window_recompute(u)
	if u.context_window == window && u.window_source == source && u.window_mismatch == mismatch do return false
	if u.updated_at_ms != 0 do u.dirty = true
	return true
}

// bridge_ext_token_usage_estimated_context is the tool-traffic estimate of the
// context size: (est_tokens_total since the last reset/compaction) *
// BRIDGE_EXT_ESTIMATE_MULTIPLIER. ok=false until a tool.end carried metrics.
bridge_ext_token_usage_estimated_context :: proc(u: Bridge_Ext_Token_Usage) -> (tokens: i64, ok: bool) {
	if u.est_tokens_total <= 0 do return 0, false
	return i64(f64(max(u.est_tokens_total - u.est_base, 0)) * BRIDGE_EXT_ESTIMATE_MULTIPLIER), true
}

// bridge_ext_token_usage_effective_context is the context size rollover and the
// hub act on: the provider-reported size when one was seen (source = its
// usage.source), else the tool-traffic estimate (source = "estimate"), else
// ok=false.
bridge_ext_token_usage_effective_context :: proc(u: Bridge_Ext_Token_Usage) -> (tokens: i64, source: string, ok: bool) {
	if u.has_context do return u.context_tokens, u.context_source, true
	est, has_est := bridge_ext_token_usage_estimated_context(u)
	if !has_est do return 0, "", false
	return est, BRIDGE_EXT_ESTIMATE_SOURCE, true
}

// bridge_ext_token_usage_context_pct is the effective context as a whole
// percentage of the resolved window (floor); -1 when there is no signal at all.
bridge_ext_token_usage_context_pct :: proc(u: Bridge_Ext_Token_Usage) -> i64 {
	tokens, _, ok := bridge_ext_token_usage_effective_context(u)
	if !ok do return -1
	return tokens * 100 / bridge_ext_token_usage_window(u)
}

// bridge_ext_token_push_due: a changed snapshot goes upstream when the per-instance
// interval has passed, or at once when the context moved by >= 5pp of the window.
bridge_ext_token_push_due :: proc(u: Bridge_Ext_Token_Usage, now: i64) -> bool {
	if !u.dirty do return false
	if !u.has_pushed do return true
	if now - u.last_push_at_ms >= BRIDGE_EXT_TOKEN_PUSH_MIN_INTERVAL_MS do return true
	cur, _, _ := bridge_ext_token_usage_effective_context(u)
	delta := abs(cur - u.last_push_context)
	return delta * 100 >= BRIDGE_EXT_TOKEN_PUSH_DELTA_PP * bridge_ext_token_usage_window(u)
}

// bridge_ext_token_collect_due_locked marks every due snapshot as pushed and
// returns the instance ids (temp allocator). Caller holds bridge_ext_mutex.
@(private = "file")
bridge_ext_token_collect_due_locked :: proc(now: i64, only_id: string = "") -> [dynamic]string {
	ids := make([dynamic]string, context.temp_allocator)
	for &s in bridge_ext_states {
		if only_id != "" && s.agent_instance_id != only_id do continue
		if !bridge_ext_token_push_due(s.token_usage, now) do continue
		bridge_ext_token_mark_pushed(&s.token_usage, now)
		append(&ids, strings.clone(s.agent_instance_id, context.temp_allocator))
	}
	return ids
}

// bridge_ext_token_enqueue_due queues an agent_instance_status push for each
// instance whose snapshot is due (only_id narrows it to one instance). The hub
// loop calls it every tick so a change held back by the interval still goes out
// once the interval passes, without another event.
bridge_ext_token_enqueue_due :: proc(now: i64, only_id: string = "") -> int {
	sync.mutex_lock(&bridge_ext_mutex)
	ids := bridge_ext_token_collect_due_locked(now, only_id)
	sync.mutex_unlock(&bridge_ext_mutex)
	if len(ids) == 0 do return 0
	sync.mutex_lock(&bridge_runtime_mutex)
	for id in ids do bridge_runtime_enqueue_status_push_locked(id)
	sync.mutex_unlock(&bridge_runtime_mutex)
	return len(ids)
}

// bridge_ext_token_usage_field writes `,"token_usage":{…}` for instance_id when
// it has a token snapshot; nothing otherwise, so the frame is unchanged for
// instances without extension token signals. run_count (the bridge's launch
// generation for the instance; 0 = unknown, omitted) tags the snapshot with its
// run. A frozen final snapshot of a finished run (T3r) follows as
// `,"token_usage_final":{…,"run_count":N}` until a newer run's final replaces
// it, so the hub adds each run to its lifetime totals exactly once even when a
// frame is lost or replayed (the hub de-duplicates by run_count).
// sent_at_ms > 0 means the frame is being sent now (T14): a pending change rides
// along on it and counts as pushed, so the throttle does not follow it with a
// usage-only status frame carrying the same snapshot.
bridge_ext_token_usage_field :: proc(b: ^strings.Builder, instance_id: string, run_count := 0, sent_at_ms: i64 = 0) {
	sync.mutex_lock(&bridge_ext_mutex)
	defer sync.mutex_unlock(&bridge_ext_mutex)
	for &s in bridge_ext_states {
		if s.agent_instance_id != instance_id do continue
		if s.token_usage.updated_at_ms != 0 {
			strings.write_string(b, ",\"token_usage\":")
			bridge_ext_token_usage_write_json(b, s.token_usage, run_count)
			if sent_at_ms > 0 && s.token_usage.dirty do bridge_ext_token_mark_pushed(&s.token_usage, sent_at_ms)
		}
		if s.token_final_run > 0 {
			strings.write_string(b, ",\"token_usage_final\":")
			bridge_ext_token_usage_write_json(b, s.token_final, s.token_final_run)
		}
		return
	}
}

// bridge_ext_token_usage_clone copies the snapshot counters (owned strings,
// context.allocator) without the upstream throttle state.
bridge_ext_token_usage_clone :: proc(u: Bridge_Ext_Token_Usage) -> Bridge_Ext_Token_Usage {
	out := u
	out.session_id = strings.clone(u.session_id)
	out.context_source = strings.clone(u.context_source)
	out.dirty, out.has_pushed, out.last_push_at_ms, out.last_push_context = false, false, 0, 0
	return out
}

bridge_ext_token_mark_pushed :: proc(u: ^Bridge_Ext_Token_Usage, now: i64) {
	u.dirty = false
	u.has_pushed = true
	u.last_push_at_ms = now
	u.last_push_context, _, _ = bridge_ext_token_usage_effective_context(u^)
}

// bridge_ext_token_usage_write_json writes the snapshot object. context_tokens,
// context_source, context_pct and output_tokens_total are omitted until
// reported; context_window, window_source (override|reported|config|default),
// warn_pct and rollover_pct (shipped config thresholds) are always present;
// reported_window and window_mismatch appear once the provider reported a
// window. usage_supported is written once a hello was seen. run_count > 0 is written as the run the counters belong to.
bridge_ext_token_usage_write_json :: proc(b: ^strings.Builder, u: Bridge_Ext_Token_Usage, run_count := 0) {
	strings.write_string(b, fmt.tprintf("{{\"tool_calls\":%d,\"est_tokens_total\":%d", u.tool_calls, u.est_tokens_total))
	if u.has_context {
		strings.write_string(b, fmt.tprintf(",\"context_tokens\":%d,\"context_source\":\"", u.context_tokens))
		bridge_local_write_json_string(b, u.context_source)
		strings.write_byte(b, '"')
	}
	if !u.has_context {
		if est, ok := bridge_ext_token_usage_estimated_context(u); ok {
			strings.write_string(b, fmt.tprintf(",\"context_source\":\"%s\",\"estimated_context_tokens\":%d", BRIDGE_EXT_ESTIMATE_SOURCE, est))
		}
	}
	strings.write_string(b, fmt.tprintf(",\"context_window\":%d,\"window_source\":\"%s\"", bridge_ext_token_usage_window(u), bridge_context_window_source_name(u.window_source)))
	warn_pct, rollover_pct, _ := bridge_context_window_thresholds()
	strings.write_string(b, fmt.tprintf(",\"warn_pct\":%d,\"rollover_pct\":%d", warn_pct, rollover_pct))
	if u.reported_window > 0 do strings.write_string(b, fmt.tprintf(",\"reported_window\":%d,\"window_mismatch\":%v", u.reported_window, u.window_mismatch))
	if pct := bridge_ext_token_usage_context_pct(u); pct >= 0 do strings.write_string(b, fmt.tprintf(",\"context_pct\":%d", pct))
	if u.has_output_total do strings.write_string(b, fmt.tprintf(",\"output_tokens_total\":%d", u.output_tokens_total))
	if u.has_usage_cap do strings.write_string(b, fmt.tprintf(",\"usage_supported\":%v", u.usage_supported))
	if run_count > 0 do strings.write_string(b, fmt.tprintf(",\"run_count\":%d", run_count))
	strings.write_string(b, fmt.tprintf(",\"compactions\":%d,\"updated_at_ms\":%d}}", u.compactions, u.updated_at_ms))
}
