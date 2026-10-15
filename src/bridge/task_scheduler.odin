package main

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import http "odin_test:lib/http_client"

// Bridge-side task scheduler: the "heavy lifting" half of task auto-promotion +
// auto-nudge. The Hub stays lean and exposes a compact actionable-task read
// (GET /api/v1/bridge/actionable-tasks) plus its existing mutation-path
// promotion. The Bridge polls that read once per tick and, for tasks whose
// target is a local instance, decides nudges and wakes agents directly (tmux +
// wrapper push) with zero extra Hub round-trips.
//
// Timing model: staleness is measured from when THIS bridge first observed a
// task in its current status (not the Hub's updated_at), which avoids hub/bridge
// clock skew and keeps all timing decisions local. Cooldown and wake coalescing
// are likewise in-memory per bridge.

BRIDGE_NUDGE_DEFAULT_INTERVAL_S :: 60
BRIDGE_NUDGE_DEFAULT_READY_S :: 300
BRIDGE_NUDGE_DEFAULT_REVIEW_S :: 300
BRIDGE_NUDGE_DEFAULT_WORKING_S :: 900
BRIDGE_NUDGE_DEFAULT_COOLDOWN_S :: 300
BRIDGE_NUDGE_DEFAULT_GRACE_S :: 30
BRIDGE_WAKE_COALESCE_MS :: i64(30_000)
// Retriable wake failures back off 1m, 2m, 4m ... capped at 30m (+-20% jitter).
BRIDGE_WAKE_BACKOFF :: Bridge_Backoff_Policy{base_ms = 60_000, max_ms = 1_800_000, jitter_pct = 20}
// A parked wake re-checks its LOCAL unpark probe (provider resolvable on PATH) at
// most this often; the probe may scan PATH, so it is not run on every tick.
BRIDGE_WAKE_PARK_PROBE_MS :: i64(300_000)

Bridge_Nudge_Config :: struct {
	// enabled gates only the auto-NUDGE path (re-pinging stale actionable tasks).
	// The promotion-wake path (ensuring a queued task's assignee is running) is a
	// safety net that always runs while the sweep thread is active, independent of
	// this flag, so default-off config still picks up queued work.
	enabled:              bool,
	interval_seconds:     int,
	ready_after_seconds:  int,
	review_after_seconds: int,
	working_stale_after_seconds: int,
	cooldown_seconds:     int,
	grace_seconds:        int,
}

// Bridge_Task_Observation tracks per-task local timing state across ticks.
Bridge_Task_Observation :: struct {
	task_id:            string,
	status:             string,
	target_instance_id: string,
	first_seen_unix_ms: i64, // when this bridge first saw task in this status
	last_nudge_unix_ms: i64, // last nudge sent for this (task,target)
}

bridge_task_sched_mutex: sync.Mutex
bridge_task_observations: [dynamic]Bridge_Task_Observation
bridge_agent_wake: map[string]Bridge_Wake_State // agent_instance_id -> wake state
bridge_nudge_config: Bridge_Nudge_Config

bridge_task_sched_once: sync.Once

// bridge_task_scheduler_init allocates the scheduler state exactly once. It is
// idempotent and never replaces the mutex or the maps, because launch paths
// (bridge_task_wake_note_launched) can run as soon as the hub worker starts,
// before the scheduler thread does. main calls it before bridge_hub_runtime_start;
// every entry point also calls it, so no call order can touch nil state.
bridge_task_scheduler_init :: proc() {
	sync.once_do(&bridge_task_sched_once, proc() {
		bridge_task_observations = make([dynamic]Bridge_Task_Observation)
		bridge_agent_wake = make(map[string]Bridge_Wake_State)
	})
}

// bridge_task_scheduler_reset empties the scheduler state in place (tests).
bridge_task_scheduler_reset :: proc() {
	bridge_task_scheduler_init()
	sync.mutex_lock(&bridge_task_sched_mutex)
	defer sync.mutex_unlock(&bridge_task_sched_mutex)
	clear(&bridge_task_observations)
	for _, &st in bridge_agent_wake do bridge_wake_state_free(&st)
	clear(&bridge_agent_wake)
}

// bridge_task_scheduler_default_config returns the built-in defaults
// (disabled). Real config wiring can override these from the loaded config.
bridge_task_scheduler_default_config :: proc() -> Bridge_Nudge_Config {
	return Bridge_Nudge_Config{
		enabled                     = false,
		interval_seconds            = BRIDGE_NUDGE_DEFAULT_INTERVAL_S,
		ready_after_seconds         = BRIDGE_NUDGE_DEFAULT_READY_S,
		review_after_seconds        = BRIDGE_NUDGE_DEFAULT_REVIEW_S,
		working_stale_after_seconds = BRIDGE_NUDGE_DEFAULT_WORKING_S,
		cooldown_seconds            = BRIDGE_NUDGE_DEFAULT_COOLDOWN_S,
		grace_seconds               = BRIDGE_NUDGE_DEFAULT_GRACE_S,
	}
}

// bridge_task_scheduler_configure copies nudge knobs from the loaded bridge
// config into the scheduler's runtime config, applying defaults for any unset
// (zero) values so an enabled-but-sparse config still behaves sanely.
bridge_task_scheduler_configure :: proc() {
	cfg := bridge_task_scheduler_default_config()
	cfg.enabled = bridge_config.nudge_enabled
	if bridge_config.nudge_interval_seconds > 0 do cfg.interval_seconds = bridge_config.nudge_interval_seconds
	if bridge_config.nudge_ready_after_seconds > 0 do cfg.ready_after_seconds = bridge_config.nudge_ready_after_seconds
	if bridge_config.nudge_review_after_seconds > 0 do cfg.review_after_seconds = bridge_config.nudge_review_after_seconds
	if bridge_config.nudge_working_stale_after_seconds > 0 do cfg.working_stale_after_seconds = bridge_config.nudge_working_stale_after_seconds
	if bridge_config.nudge_cooldown_seconds > 0 do cfg.cooldown_seconds = bridge_config.nudge_cooldown_seconds
	if bridge_config.nudge_restart_grace_seconds >= 0 do cfg.grace_seconds = bridge_config.nudge_restart_grace_seconds
	bridge_nudge_config = cfg
}

bridge_task_scheduler_start :: proc() {
	bridge_task_scheduler_init()
	// The sweep runs whenever the bridge has hub connectivity, so the
	// promotion-wake safety net is active even when auto-nudge is disabled. The
	// nudge path inside the tick is separately gated by bridge_nudge_config.enabled.
	if strings.trim_space(bridge_config.bridge_token) == "" || strings.trim_space(bridge_config.daemon_url) == "" do return
	thread.run(bridge_task_scheduler_worker)
}

bridge_task_scheduler_worker :: proc() {
	grace := bridge_nudge_config.grace_seconds
	if grace < 0 do grace = 0
	if grace > 0 do time.sleep(time.Duration(grace) * time.Second)
	for {
		bridge_task_scheduler_tick()
		interval := bridge_nudge_config.interval_seconds
		if interval <= 0 do interval = BRIDGE_NUDGE_DEFAULT_INTERVAL_S
		time.sleep(time.Duration(interval) * time.Second)
	}
}

// bridge_task_scheduler_tick performs one sweep: fetch actionable tasks, then
// for each locally-targeted task decide promotion-wake / nudge. Returns the
// number of actions taken (nudges delivered/queued + wakes requested).
bridge_task_scheduler_tick :: proc() -> int {
	body, ok := bridge_task_fetch_actionable()
	if !ok do return 0
	actions := 0
	now := bridge_runtime_now_ms()

	tasks_arr, has_tasks := bridge_provider_json_extract_array(body, "tasks")
	if !has_tasks do return 0
	objects := bridge_provider_json_top_level_objects(tasks_arr)
	defer delete(objects)

	// Track which task_ids we saw this tick to prune stale observations.
	seen := make(map[string]bool)
	defer delete(seen)

	for obj in objects {
		task_id := bridge_provider_json_extract_string(obj, "task_id", "")
		status := bridge_provider_json_extract_string(obj, "status", "")
		target := bridge_provider_json_extract_string(obj, "target_instance_id", "")
		title := bridge_provider_json_extract_string(obj, "title", "")
		deps_ok := strings.contains(obj, "\"deps_satisfied\":true")
		if task_id == "" || target == "" do continue
		seen[task_id] = true

		first_seen := bridge_task_observe(task_id, status, target, now)

		// Promotion-wake: an Assigned task whose deps are satisfied should be
		// worked. If the local assignee is not live, wake it (coalesced). The Hub
		// performs the durable status promotion on its own mutation path; here we
		// only ensure the agent is running so it can pick up the work.
		if status == "assigned" && deps_ok {
			if bridge_task_wake_if_needed(target, now) do actions += 1
			continue
		}

		// Do NOT nudge a task whose dependencies are not satisfied: it cannot be
		// worked yet, so pinging its assignee is pure noise. (An assigned+deps_ok
		// task is handled by the promotion-wake branch above; anything reaching here
		// with unsatisfied deps is genuinely blocked.)
		if !deps_ok do continue

		// Nudge: stale actionable task past threshold + cooldown.
		last_nudge := bridge_task_last_nudge(task_id, target)
		if !bridge_task_should_nudge(bridge_nudge_config, status, first_seen, last_nudge, now) do continue

		// Record the cooldown on ATTEMPT, before delivery. Previously last_nudge was
		// only set when bridge_task_deliver_nudge returned true; when delivery was a
		// no-op (wrapper push channel missing but the instance already live, common
		// right after a relaunch) last_nudge stayed 0 and the task was re-nudged
		// every tick, bypassing the cooldown entirely. Marking on attempt guarantees
		// the per-(task,target) cooldown always applies.
		bridge_task_mark_nudged(task_id, target, now)
		delivered := bridge_task_deliver_nudge(task_id, status, target, now, title)
		actions += 1
		fmt.printfln("SCHED_NUDGE ts=%d task=%s status=%s target=%s stale_ms=%d delivered=%t", now, task_id, status, target, now - first_seen, delivered)
	}

	bridge_task_prune_unseen(seen)
	return actions
}

bridge_task_threshold_seconds :: proc(status: string) -> int {
	return bridge_task_threshold_seconds_cfg(bridge_nudge_config, status)
}

// bridge_task_threshold_seconds_cfg is the pure form (config passed explicitly)
// so it can be unit-tested without touching global scheduler state.
bridge_task_threshold_seconds_cfg :: proc(cfg: Bridge_Nudge_Config, status: string) -> int {
	switch status {
	case "assigned":            return cfg.ready_after_seconds
	case "in_progress":         return cfg.working_stale_after_seconds
	case "in_validation":       return cfg.review_after_seconds
	case "validated_not_good":  return cfg.ready_after_seconds
	case:                       return 0
	}
}

// bridge_task_should_nudge is the pure nudge gate: given the config, the task
// status, the timestamp this bridge first saw the task in this status, the last
// nudge time for the target, and now, decide whether to nudge. Mirrors the Hub
// evaluate_nudge decision but keyed on bridge-local observation time.
bridge_task_should_nudge :: proc(cfg: Bridge_Nudge_Config, status: string, first_seen_ms, last_nudge_ms, now_ms: i64) -> bool {
	if !cfg.enabled do return false
	threshold_ms := i64(bridge_task_threshold_seconds_cfg(cfg, status)) * 1000
	if threshold_ms <= 0 do return false
	if first_seen_ms <= 0 do return false
	if now_ms - first_seen_ms < threshold_ms do return false
	cooldown_ms := i64(cfg.cooldown_seconds) * 1000
	if cooldown_ms <= 0 do cooldown_ms = i64(BRIDGE_NUDGE_DEFAULT_COOLDOWN_S) * 1000
	if last_nudge_ms > 0 && now_ms - last_nudge_ms < cooldown_ms do return false
	return true
}

bridge_task_fetch_actionable :: proc() -> (string, bool) {
	headers := [?]http.Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge_config.bridge_token})}}
	resp, ok := bridge_http_request_retry("GET", bridge_config.daemon_url, "/api/v1/bridge/actionable-tasks", "", headers[:], http.DEFAULT_TIMEOUT_MS)
	if !ok || resp.status != 200 do return "", false
	return resp.body, true
}

// bridge_task_observe records/updates the observation for a task and returns the
// first_seen timestamp for its CURRENT status (reset when status changes).
bridge_task_observe :: proc(task_id, status, target: string, now: i64) -> i64 {
	sync.mutex_lock(&bridge_task_sched_mutex)
	defer sync.mutex_unlock(&bridge_task_sched_mutex)
	for i in 0..<len(bridge_task_observations) {
		o := &bridge_task_observations[i]
		if o.task_id != task_id do continue
		if o.status != status {
			o.status = strings.clone(status)
			o.target_instance_id = strings.clone(target)
			o.first_seen_unix_ms = now
			o.last_nudge_unix_ms = 0
		}
		return o.first_seen_unix_ms
	}
	append(&bridge_task_observations, Bridge_Task_Observation{
		task_id = strings.clone(task_id), status = strings.clone(status),
		target_instance_id = strings.clone(target), first_seen_unix_ms = now,
	})
	return now
}

bridge_task_last_nudge :: proc(task_id, target: string) -> i64 {
	sync.mutex_lock(&bridge_task_sched_mutex)
	defer sync.mutex_unlock(&bridge_task_sched_mutex)
	for o in bridge_task_observations { if o.task_id == task_id && o.target_instance_id == target do return o.last_nudge_unix_ms }
	return 0
}

bridge_task_mark_nudged :: proc(task_id, target: string, now: i64) {
	sync.mutex_lock(&bridge_task_sched_mutex)
	defer sync.mutex_unlock(&bridge_task_sched_mutex)
	for i in 0..<len(bridge_task_observations) {
		o := &bridge_task_observations[i]
		if o.task_id == task_id && o.target_instance_id == target { o.last_nudge_unix_ms = now; return }
	}
}

bridge_task_prune_unseen :: proc(seen: map[string]bool) {
	sync.mutex_lock(&bridge_task_sched_mutex)
	defer sync.mutex_unlock(&bridge_task_sched_mutex)
	for i := len(bridge_task_observations) - 1; i >= 0; i -= 1 {
		if !seen[bridge_task_observations[i].task_id] {
			ordered_remove(&bridge_task_observations, i)
		}
	}
}

// bridge_task_status_notify_wake_local wakes a non-live target in response to a
// task_status_changed_notify. The
// Hub routes each notify ONLY to the bridge that hosts the target instance, so a
// target that arrives here is authoritative — we must not gate on the bridge's
// in-memory runtime registry, which is empty right after a bridge restart (the
// exact orphan-recovery case). We therefore trust the Hub's routing and attempt
// the wake directly; the launch path itself validates whether the instance can
// run locally (provider/tmux). Wakes remain coalesced within
// BRIDGE_WAKE_COALESCE_MS. Returns true when a wake was requested.
bridge_task_status_notify_wake_local :: proc(instance_id: string) -> bool {
	return bridge_task_wake_if_needed(instance_id, bridge_runtime_now_ms())
}

// Per-instance wake state. The error class of the last failed wake decides what
// happens next (see contracts.bridge_error_classify):
//   retriable   -> exponential backoff (BRIDGE_WAKE_BACKOFF); never parks.
//   recoverable -> PARKED: no timer retries. Unparks when the provider catalog
//                  changes, or (for provider_missing / missing_binary) when the
//                  provider becomes resolvable locally.
//   fatal       -> PARKED until a launch of this instance succeeds by another path
//                  (e.g. a hub launch_agent) or the bridge restarts.
// Any successful launch resets the state (bridge_task_wake_note_launched).
Bridge_Wake_State :: struct {
	last_wake_ms:  i64, // last attempt; wakes within BRIDGE_WAKE_COALESCE_MS coalesce
	failures:      int, // consecutive retriable failures
	next_at_ms:    i64, // earliest next attempt after a retriable failure
	parked:        bool,
	err:           Bridge_Error, // last failure
	probe_at_ms:   i64,    // parked: last local unpark probe
	catalog_etag:  string, // parked: provider catalog etag at park time (owned)
	provider:      string, // parked: for the local unpark probe (owned)
	model:         string, // (owned)
	generation:    u64,    // bumped by every successful launch; a wake result is
	                       // applied only if the generation it started under is current
}

Bridge_Wake_Decision :: enum {
	Wake,
	Coalesced,
	Backing_Off,
	Parked,
}

Bridge_Wake_Transition :: enum {
	None,
	Recovered,
	Backoff,
	Parked,
}

bridge_wake_state_free :: proc(st: ^Bridge_Wake_State) {
	delete(st.catalog_etag)
	delete(st.provider)
	delete(st.model)
	st.catalog_etag, st.provider, st.model = "", "", ""
}

// bridge_wake_gate is the pure wake decision. `unpark` is the parked instance's
// trigger check, evaluated by the caller only while parked.
bridge_wake_gate :: proc(st: Bridge_Wake_State, has: bool, now_ms: i64, unpark := false) -> Bridge_Wake_Decision {
	if !has do return .Wake
	if st.parked do return .Wake if unpark else .Parked
	if now_ms - st.last_wake_ms < BRIDGE_WAKE_COALESCE_MS do return .Coalesced
	if st.next_at_ms > now_ms do return .Backing_Off
	return .Wake
}

// bridge_wake_record applies one wake outcome to `st` and reports the transition
// to log. It never touches the owned park strings; the caller sets them on .Parked.
bridge_wake_record :: proc(st: ^Bridge_Wake_State, ok: bool, err: Bridge_Error, now_ms: i64, jitter_seed: u64 = 0) -> Bridge_Wake_Transition {
	st.last_wake_ms = now_ms
	if ok {
		was_failing := st.parked || st.failures > 0
		st.parked, st.failures, st.next_at_ms, st.err = false, 0, 0, {}
		return .Recovered if was_failing else .None
	}
	st.err = err
	switch err.class {
	case .retriable:
		st.parked = false
		st.failures += 1
		st.next_at_ms = bridge_backoff_next_at_ms(BRIDGE_WAKE_BACKOFF, st.failures, now_ms, err, jitter_seed)
		return .Backoff
	case .recoverable, .fatal:
		was_parked := st.parked
		st.parked, st.failures, st.next_at_ms, st.probe_at_ms = true, 0, 0, now_ms
		return .None if was_parked else .Parked
	}
	return .None
}

// bridge_provider_runnable reports whether (provider, model) could be spawned on
// this bridge right now: known to the catalog and the binary resolvable. Local
// only; no hub call.
bridge_provider_runnable :: proc(provider, model: string) -> bool {
	if strings.trim_space(provider) == "" || strings.trim_space(model) == "" do return false
	if !bridge_provider_catalog_has_model(provider, model) do return false
	if _, ok := bridge_provider_catalog_profile(provider); !ok do return false
	path, path_ok := bridge_provider_resolve_path(provider)
	if !path_ok do return false
	delete(path)
	return true
}

// bridge_wake_unpark_trigger evaluates a parked instance's resume triggers and
// returns a non-empty trigger name when it should be retried. Called under the
// scheduler mutex; updates probe_at_ms.
bridge_wake_unpark_trigger :: proc(st: ^Bridge_Wake_State, now_ms: i64) -> string {
	if st.err.class == .fatal do return ""
	etag := bridge_provider_catalog_current_etag()
	defer delete(etag)
	if etag != st.catalog_etag do return "provider_catalog_changed"
	provider_problem := st.err.code == .provider_missing || st.err.reason == .missing_binary || st.err.reason == .not_executable
	if !provider_problem || now_ms - st.probe_at_ms < BRIDGE_WAKE_PARK_PROBE_MS do return ""
	st.probe_at_ms = now_ms
	if bridge_provider_runnable(st.provider, st.model) do return "provider_runnable"
	return ""
}

// bridge_task_wake_note_launched resets an instance's wake state after ANY
// successful launch (scheduler, hub launch_agent, wake_agent), which is the
// universal unpark trigger.
//
// The entry is created when absent, so a wake that registers AFTER this success
// (it read a stale "not active" snapshot) still sees the bumped generation and a
// fresh last_wake_ms, which coalesces it away.
bridge_task_wake_note_launched :: proc(instance_id: string, now_ms: i64 = 0) {
	bridge_task_scheduler_init()
	sync.mutex_lock(&bridge_task_sched_mutex)
	defer sync.mutex_unlock(&bridge_task_sched_mutex)
	if instance_id not_in bridge_agent_wake do bridge_agent_wake[strings.clone(instance_id)] = Bridge_Wake_State{}
	st := &bridge_agent_wake[instance_id]
	st.last_wake_ms = now_ms if now_ms > 0 else bridge_runtime_now_ms()
	if st.parked || st.failures > 0 do fmt.println("bridge scheduler wake RECOVERED (launched)", instance_id)
	bridge_wake_state_free(st)
	st.parked, st.failures, st.next_at_ms, st.err = false, 0, 0, {}
	// Invalidate any wake attempt still in flight: its (older) result must not
	// re-park or back off an instance that has since launched.
	st.generation += 1
}

// bridge_task_wake_if_needed wakes a local instance if it is not currently live,
// subject to coalescing (BRIDGE_WAKE_COALESCE_MS), retriable-failure backoff and
// parking (see Bridge_Wake_State). Returns true if a wake was requested and the
// launch succeeded.
bridge_task_wake_if_needed :: proc(instance_id: string, now: i64) -> bool {
	bridge_task_scheduler_init()
	sync.mutex_lock(&bridge_task_sched_mutex)
	// Activity is checked UNDER the scheduler mutex (lock order: scheduler ->
	// runtime). A launch marks the instance active before it calls
	// bridge_task_wake_note_launched, so either this check sees it active, or the
	// launch's generation bump happens after we register and invalidates us.
	if inst, found := bridge_runtime_instance_snapshot(instance_id); found && bridge_runtime_status_active(inst.runtime_status) {
		sync.mutex_unlock(&bridge_task_sched_mutex)
		return false
	}
	st, has := bridge_agent_wake[instance_id]
	trigger := ""
	if has && st.parked {
		trigger = bridge_wake_unpark_trigger(&bridge_agent_wake[instance_id], now)
		st = bridge_agent_wake[instance_id]
	}
	if bridge_wake_gate(st, has, now, trigger != "") != .Wake {
		sync.mutex_unlock(&bridge_task_sched_mutex)
		return false
	}
	if !has do bridge_agent_wake[strings.clone(instance_id)] = Bridge_Wake_State{}
	slot := &bridge_agent_wake[instance_id]
	slot.last_wake_ms = now
	generation := slot.generation
	sync.mutex_unlock(&bridge_task_sched_mutex)
	if trigger != "" do fmt.println("bridge scheduler wake UNPARKED", instance_id, "trigger=", trigger)

	// Reuse the same launch path as a hub launch_agent command; a synthetic
	// command_id keeps the launch idempotency/caching machinery happy.
	//
	// REQ-37 (B1): the bridge knows only the instance_id locally, but a bare
	// {agent_instance_id} payload used to leave descriptor.agent_id empty, which took
	// the header-only instance-endpoint fallback and materialized a 6-line CLAUDE.md
	// (all static skills/persona/instructions missing). We now first fetch the
	// per-instance descriptor from the hub and build a FULLY-ENRICHED launch command
	// (same payload keys as agent_service.launch_command_json_full) so the launch
	// takes the full agent-keyed template bootstrap. If the descriptor cannot be
	// fetched (or lacks agent_id), the wake fails with a classified error rather
	// than materialize a degraded bootstrap -- a visible failure, never a silent one.
	command_id := fmt.tprintf("sched_wake_%s_%d", instance_id, now)
	command_json, enrich_err, enrich_ok := bridge_scheduler_fetch_enriched_launch_json(instance_id, command_id)
	defer delete(command_json)
	ok, detail, err := false, "", enrich_err
	if enrich_ok {
		ok, detail, err = bridge_runtime_launch_agent(command_id, command_json)
	} else {
		detail = "could not fetch enriched descriptor (agent_id)"
	}
	bridge_task_wake_record_result(instance_id, generation, ok, detail, err, command_json, now)
	return ok
}

// bridge_task_wake_record_result applies a wake outcome and logs only state
// TRANSITIONS (first failure / each backoff step, parked, recovered), never one
// line per tick.
// A result whose `generation` is stale (a launch succeeded while this attempt was
// in flight) is dropped.
bridge_task_wake_record_result :: proc(instance_id: string, generation: u64, ok: bool, detail: string, err: Bridge_Error, command_json: string, now: i64) {
	sync.mutex_lock(&bridge_task_sched_mutex)
	defer sync.mutex_unlock(&bridge_task_sched_mutex)
	st, has := &bridge_agent_wake[instance_id]
	if !has || st.generation != generation do return
	transition := bridge_wake_record(st, ok, err, now, rand.uint64())
	if st.parked {
		// Snapshot the trigger baselines on EVERY parked failure, including a failed
		// unpark attempt: otherwise a changed catalog etag would re-trigger each tick.
		bridge_wake_state_free(st)
		st.catalog_etag = bridge_provider_catalog_current_etag()
		st.provider, st.model = bridge_runtime_provider_model(command_json) // caller-owned
	}
	switch transition {
	case .None:
	case .Recovered:
		fmt.println("bridge scheduler wake RECOVERED", instance_id)
	case .Backoff:
		fmt.printfln("bridge scheduler wake failed %s %s: %s; retry %d in %ds", instance_id, detail, bridge_error_string(err), st.failures, (st.next_at_ms - now) / 1000)
	case .Parked:
		fmt.printfln("bridge scheduler wake PARKED %s %s: %s; no timer retries until a resume trigger", instance_id, detail, bridge_error_string(err))
	}
}

// bridge_scheduler_fetch_enriched_launch_json builds a fully-enriched launch_agent
// command for the scheduler wake path (REQ-37 B1). The scheduler only knows the
// instance_id locally (the bridge launch record + runtime snapshot carry no
// agent_id/chain data), so it GETs the hub instance bootstrap endpoint, which
// returns the per-instance descriptor (agent_id, agent_name, role, chain_id,
// chain_title, coordinator, project). Those are forwarded into the synthetic launch
// payload so the launch takes the full agent-keyed template bootstrap instead of the
// header-only fallback. Returns ("", err, false) when the hub is unreachable
// (retriable), rejects the fetch (classified by HTTP status) or the descriptor lacks
// agent_id (recoverable), so the caller fails the wake with that class rather than
// materialize a degraded, header-only CLAUDE.md. Transient extracted strings
// follow the same no-free convention as bridge_hub_handle_wake_agent.
bridge_scheduler_fetch_enriched_launch_json :: proc(instance_id, command_id: string) -> (string, Bridge_Error, bool) {
	if strings.trim_space(bridge_config.daemon_url) == "" || strings.trim_space(bridge_config.bridge_token) == "" do return "", bridge_error(.hub_connect_failed, .config), false
	path := strings.concatenate({"/api/v1/bridge/agent-instances/", instance_id, "/bootstrap?format=manifest"})
	defer delete(path)
	auth := strings.concatenate({"Bearer ", bridge_config.bridge_token})
	defer delete(auth)
	headers := [?]http.Header{{name = "Authorization", value = auth}}
	resp, ok := bridge_http_request_retry("GET", bridge_config.daemon_url, path, "", headers[:], http.DEFAULT_TIMEOUT_MS)
	if !ok || resp.status != 200 {
		delete(resp.body)
		if !ok || resp.status == 0 do return "", bridge_error(.hub_connect_failed, .transport), false
		return "", bridge_error(.hub_rejected, .other, resp.status), false
	}
	defer delete(resp.body)
	// data_obj/inst_obj are ALIASES into resp.body (not owned clones) -- do not free.
	data_obj, data_ok := bridge_provider_json_extract_object(resp.body, "data")
	if !data_ok do return "", bridge_error(.agent_bootstrap_invalid), false
	inst_obj, inst_ok := bridge_provider_json_extract_object(data_obj, "instance")
	if !inst_ok do return "", bridge_error(.agent_bootstrap_invalid), false
	agent_id := extract_json_string(inst_obj, "agent_id", "")
	if strings.trim_space(agent_id) == "" do return "", bridge_error(.agent_bootstrap_invalid), false
	agent_name     := extract_json_string(inst_obj, "agent_name", "")
	role           := extract_json_string(inst_obj, "role", "")
	chain_id       := extract_json_string(inst_obj, "chain_id", "")
	chain_title    := extract_json_string(inst_obj, "chain_title", "")
	coordinator_id           := extract_json_string(inst_obj, "coordinator_agent_instance_id", "")
	coordinator_display_name := extract_json_string(inst_obj, "coordinator_display_name", "")
	project_id               := extract_json_string(inst_obj, "project_id", "")
	project_path             := extract_json_string(inst_obj, "project_path", "")
	// REQ-ERR-6: provider/model come from the descriptor. The launch path has no
	// fallback for them, so an older hub that omits them still yields
	// provider_missing, which now parks the wake instead of looping. task_id stays
	// unknown: the agent resolves its current task after boot via reconcile.
	provider := extract_json_string(inst_obj, "provider", "")
	defer delete(provider)
	model    := extract_json_string(inst_obj, "model", "")
	defer delete(model)
	return bridge_wake_launch_command_json(command_id, instance_id, "", role, provider, model, agent_id, agent_name, chain_id, chain_title, coordinator_id, project_id, project_path, coordinator_display_name), {}, true
}

// bridge_task_deliver_nudge pushes a nudge to the local wrapper if live. If the
// wrapper is not connected, it wakes the agent (coalesced) so it can pick up the
// task on boot; the durable state already lives in the Hub.
bridge_task_deliver_nudge :: proc(task_id, status, target: string, now: i64, task_title: string = "") -> bool {
	trimmed_title := strings.trim_space(task_title)
	msg: string
	if trimmed_title != "" {
		msg = fmt.tprintf("Task \"%s\" (%s) needs attention (%s)", trimmed_title, task_id, status)
	} else {
		msg = fmt.tprintf("Task %s needs attention (%s)", task_id, status)
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "{\"type\":\"notify_task_nudge\",\"origin\":\"scheduled\",\"task_id\":\"")
	bridge_runtime_write_json_string(&b, task_id)
	strings.write_string(&b, "\",\"target_instance_id\":\"")
	bridge_runtime_write_json_string(&b, target)
	strings.write_string(&b, "\",\"task_status\":\"")
	bridge_runtime_write_json_string(&b, status)
	strings.write_string(&b, "\"")
	if trimmed_title != "" {
		strings.write_string(&b, ",\"title\":\"")
		bridge_runtime_write_json_string(&b, trimmed_title)
		strings.write_string(&b, "\"")
	}
	strings.write_string(&b, ",\"message\":\"")
	bridge_runtime_write_json_string(&b, msg)
	strings.write_string(&b, "\"}")
	payload := strings.to_string(b)
	if bridge_wrapper_push_task_nudge(target, payload) do return true
	// Wrapper not live: ensure the agent is running so it sees the work on boot.
	return bridge_task_wake_if_needed(target, now)
}
