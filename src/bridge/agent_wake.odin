package main

import "core:fmt"
import "core:time"
import "core:math/rand"
import "core:strings"
import "core:sync"
import httpc "odin_test:lib/httpc"

// Bridge-side agent wake machinery. The hub pushes work (leases, notices) to the
// bridge via wake_agent / notify frames; when the target instance is not live
// the bridge launches it through the same path as a hub launch_agent, subject to
// coalescing, retriable-failure backoff and parking (see Bridge_Wake_State).
//
// Task System v2 note: the former bridge-side task scheduler (periodic poll of
// GET /api/v1/bridge/actionable-tasks + auto-nudge) was removed; the bridge no
// longer polls the hub for work. Only the wake state machine remains.

BRIDGE_WAKE_COALESCE_MS :: i64(30_000)
// Retriable wake failures back off 1m, 2m, 4m ... capped at 30m (+-20% jitter).
BRIDGE_WAKE_BACKOFF :: Bridge_Backoff_Policy{base_ms = 60_000, max_ms = 1_800_000, jitter_pct = 20}
// A parked wake re-checks its LOCAL unpark probe (provider resolvable on PATH) at
// most this often; the probe may scan PATH, so it is not run on every tick.
BRIDGE_WAKE_PARK_PROBE_MS :: i64(300_000)

bridge_wake_mutex: sync.Mutex
bridge_agent_wake: map[string]Bridge_Wake_State // agent_instance_id -> wake state

bridge_wake_once: sync.Once

// bridge_agent_wake_init allocates the wake state exactly once. It is idempotent
// and never replaces the mutex or the map, because launch paths
// (bridge_task_wake_note_launched) can run as soon as the hub worker starts. main
// calls it before bridge_hub_runtime_start; every entry point also calls it, so
// no call order can touch nil state.
bridge_agent_wake_init :: proc() {
	sync.once_do(&bridge_wake_once, proc() {
		bridge_agent_wake = make(map[string]Bridge_Wake_State)
	})
}

// bridge_agent_wake_reset empties the wake state in place (tests).
bridge_agent_wake_reset :: proc() {
	bridge_agent_wake_init()
	sync.mutex_lock(&bridge_wake_mutex)
	defer sync.mutex_unlock(&bridge_wake_mutex)
	for _, &st in bridge_agent_wake do bridge_wake_state_free(&st)
	clear(&bridge_agent_wake)
}

// bridge_task_status_notify_wake_local wakes a non-live target in response to a
// hub notify frame (task_status_changed_notify, notify_*_nudge, ...). The
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
//   recoverable -> PARKED: no backoff retries. Unparks when the provider catalog
//                  changes; for provider_missing / missing_binary when the provider
//                  becomes resolvable locally; for vault_locked when the vault is
//                  unsealed; for any other cause on a slow re-check at the backoff cap.
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
// wake mutex; updates probe_at_ms.
bridge_wake_unpark_trigger :: proc(st: ^Bridge_Wake_State, now_ms: i64) -> string {
	if st.err.class == .fatal do return ""
	etag := bridge_provider_catalog_current_etag()
	defer delete(etag)
	if etag != st.catalog_etag do return "provider_catalog_changed"
	provider_problem := st.err.code == .provider_missing || st.err.reason == .missing_binary || st.err.reason == .not_executable
	if provider_problem || st.err.code == .vault_locked {
		if now_ms - st.probe_at_ms < BRIDGE_WAKE_PARK_PROBE_MS do return ""
		st.probe_at_ms = now_ms
		if provider_problem && bridge_provider_runnable(st.provider, st.model) do return "provider_runnable"
		if st.err.code == .vault_locked && bridge_vault_status() == .Unlocked do return "vault_unsealed"
		return ""
	}
	// Any other recoverable cause (a refused bootstrap token, hub-side config) has no
	// local signal to watch: re-check it at the retriable backoff cap, so a fix made
	// elsewhere is picked up without user action and without a retry storm.
	if now_ms - st.last_wake_ms >= BRIDGE_WAKE_BACKOFF.max_ms do return "periodic_recheck"
	return ""
}

// bridge_task_wake_note_launched resets an instance's wake state after ANY
// successful launch (hub launch_agent, wake_agent, action scheduler), which is the
// universal unpark trigger.
//
// The entry is created when absent, so a wake that registers AFTER this success
// (it read a stale "not active" snapshot) still sees the bumped generation and a
// fresh last_wake_ms, which coalesces it away.
bridge_task_wake_note_launched :: proc(instance_id: string, now_ms: i64 = 0) {
	bridge_agent_wake_init()
	sync.mutex_lock(&bridge_wake_mutex)
	defer sync.mutex_unlock(&bridge_wake_mutex)
	if instance_id not_in bridge_agent_wake do bridge_agent_wake[strings.clone(instance_id)] = Bridge_Wake_State{}
	st := &bridge_agent_wake[instance_id]
	st.last_wake_ms = now_ms if now_ms > 0 else bridge_runtime_now_ms()
	if st.parked || st.failures > 0 do fmt.println("bridge wake RECOVERED (launched)", instance_id)
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
bridge_task_wake_if_needed :: proc(instance_id: string, now: i64, deadline_ns: i64 = 0) -> bool {
	bridge_agent_wake_init()
	sync.mutex_lock(&bridge_wake_mutex)
	// Activity is checked UNDER the wake mutex (lock order: wake ->
	// runtime). A launch marks the instance active before it calls
	// bridge_task_wake_note_launched, so either this check sees it active, or the
	// launch's generation bump happens after we register and invalidates us.
	if inst, found := bridge_runtime_instance_snapshot(instance_id); found && bridge_runtime_status_active(inst.runtime_status) {
		sync.mutex_unlock(&bridge_wake_mutex)
		return false
	}
	st, has := bridge_agent_wake[instance_id]
	trigger := ""
	if has && st.parked {
		trigger = bridge_wake_unpark_trigger(&bridge_agent_wake[instance_id], now)
		st = bridge_agent_wake[instance_id]
	}
	if bridge_wake_gate(st, has, now, trigger != "") != .Wake {
		sync.mutex_unlock(&bridge_wake_mutex)
		return false
	}
	if !has do bridge_agent_wake[strings.clone(instance_id)] = Bridge_Wake_State{}
	slot := &bridge_agent_wake[instance_id]
	slot.last_wake_ms = now
	generation := slot.generation
	sync.mutex_unlock(&bridge_wake_mutex)
	if trigger != "" do fmt.println("bridge wake UNPARKED", instance_id, "trigger=", trigger)

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
	command_json, enrich_err, enrich_ok := bridge_wake_fetch_enriched_launch_json(instance_id, command_id, deadline_ns)
	defer delete(command_json)
	ok, detail, err := false, "", enrich_err
	if enrich_ok {
		ok, detail, err = bridge_runtime_launch_agent(command_id, command_json, deadline_ns)
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
	sync.mutex_lock(&bridge_wake_mutex)
	defer sync.mutex_unlock(&bridge_wake_mutex)
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
		fmt.println("bridge wake RECOVERED", instance_id)
	case .Backoff:
		fmt.printfln("bridge wake failed %s %s: %s; retry %d in %ds", instance_id, detail, bridge_error_string(err), st.failures, (st.next_at_ms - now) / 1000)
	case .Parked:
		fmt.printfln("bridge wake PARKED %s %s: %s; no timer retries until a resume trigger", instance_id, detail, bridge_error_string(err))
	}
}

// bridge_wake_fetch_enriched_launch_json builds a fully-enriched launch_agent
// command for the wake path (REQ-37 B1). The wake path only knows the
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
bridge_wake_fetch_enriched_launch_json :: proc(instance_id, command_id: string, deadline_ns: i64 = 0) -> (string, Bridge_Error, bool) {
	credential_snapshot_298 := bridge_credential_snapshot()
	defer delete(credential_snapshot_298)
	if strings.trim_space(bridge_config.daemon_url) == "" || strings.trim_space(credential_snapshot_298) == "" do return "", bridge_error(.hub_connect_failed, .config), false
	credential_snapshot_301 := bridge_credential_snapshot()
	defer delete(credential_snapshot_301)
	headers := [?]httpc.Header{httpc.bearer(credential_snapshot_301)}
	req := httpc.Request{
		method = .GET, url = bridge_hub_url(), path = {"api", "v1", "bridge", "agent-instances", instance_id, "bootstrap"},
		query = {{"format", "manifest"}}, headers = headers[:],
	}
	resp: httpc.Response
    http_err: httpc.Error
    if deadline_ns != 0 {
        left := (deadline_ns - time.to_unix_nanoseconds(time.now())) / i64(time.Millisecond)
        if left <= 0 do return "", bridge_error(.hub_connect_failed, .transport), false
        req.timeout_ms = int(min(10_000, left))
        resp, http_err = bridge_hub_http_send_alloc(req)
    } else {
        resp, http_err = bridge_http_request_retry(req)
    }
	defer httpc.response_destroy(&resp)
	ok := http_err == .None
	if !ok || resp.status != 200 {
		if !ok || resp.status == 0 do return "", bridge_error(.hub_connect_failed, .transport), false
		return "", bridge_error(.hub_rejected, .other, resp.status), false
	}
	// data_obj/inst_obj are ALIASES into resp.body (not owned clones) -- do not free.
	data_obj, data_ok := bridge_provider_json_extract_object(httpc.text(resp), "data")
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
	provider_profile:=extract_json_string(inst_obj,"provider_profile","");defer delete(provider_profile)
	permission_mode := extract_json_string(inst_obj, "permission_mode", "")
	defer delete(permission_mode)
	return bridge_wake_launch_command_json(command_id, instance_id, "", role, provider, model, agent_id, agent_name, chain_id, chain_title, coordinator_id, project_id, project_path, coordinator_display_name, "", "", permission_mode,provider_profile=provider_profile), {}, true
}
