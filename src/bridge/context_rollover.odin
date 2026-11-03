package main

// Context rollover (chain "Estimate agent tokens via extensions", T6).
//
// When an agent's context crosses the rollover threshold (T2b: rollover_pct of
// the resolved window) the bridge asks it, at its next idle point, to write a
// previous_context handoff; it intercepts the agent's self-addressed
// `ham-ctl chat send --to <own id>`, persists it through the hub (T5) and then
// restarts the agent through the hub's restart_instance, so the lease and the
// instance id survive. The restarted agent's starter prompt gets one extra line
// telling it to read that message first.
//
// Per instance:
//
//   normal --(context_pct >= rollover_pct, cooldown over)--> pending
//   pending --(main agent idle / Stop)--> requested      [request typed into the PTY]
//   requested --(self chat send intercepted)--> persisting [T5 call, waits for ack]
//   persisting --(ack)--> restarting (awaiting idle)  | --(error)--> requested
//   restarting --(next idle)--> restart requested       [hub restart_instance]
//   restart requested --(agent.start_success)--> normal [cooldown, counters reset,
//                                                         queued notices delivered]
//
// Guards: in `requested` the request is retried once after
// BRIDGE_ROLLOVER_REQUEST_TIMEOUT_MS, then the user and the chain coordinator are
// alerted and the instance returns to normal (never a forced restart). A
// persisted handoff that sees no idle within the same timeout is alerted once and
// keeps waiting for idle. Between a request and the restarted agent's
// start-success, idle activity is reported as active (so the hub's idle grace
// cannot expire the lease) and user message notices are queued.
//
// Decisions run under bridge_rollover_mutex and return a list of actions; the
// actions (PTY typing, hub calls) run after the lock is released, on a worker
// thread unless bridge_rollover_sync_effects is set (tests).

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import agent_runtime "odin_test:lib/agent_runtime"

BRIDGE_ROLLOVER_REQUEST_TIMEOUT_MS :: 5 * 60_000
BRIDGE_ROLLOVER_COOLDOWN_MS :: 10 * 60_000
BRIDGE_ROLLOVER_TICK_MS :: 5_000
BRIDGE_ROLLOVER_MAX_QUEUED_NOTICES :: 32
BRIDGE_ROLLOVER_MAX_INSTANCES :: 256

BRIDGE_ROLLOVER_RESTART_PROMPT_LINE :: "Your context was rolled over. Run " + agent_runtime.CTL_SHIM_INVOCATION + " chat read first and read your previous_context message, then " + agent_runtime.CTL_SHIM_INVOCATION + " lease next if you held a task."

Bridge_Rollover_Phase :: enum {
	Normal,
	Pending,
	Requested,
	Persisting,
	Restarting,
}

Bridge_Rollover_State :: struct {
	agent_instance_id: string,
	coordinator_id:    string,
	phase:             Bridge_Rollover_Phase,
	seq:               int, // rollover number for this instance; part of the request id
	attempts:          int, // requests typed in the current rollover (max 2)
	context_pct:       i64, // context_pct that triggered pending
	phase_at_ms:       i64, // when the current phase (or the latest retry) began
	restart_requested: bool,
	stall_alerted:     bool, // restarting: idle timeout already alerted
	cooldown_until_ms: i64,
	queued_notices:    [dynamic]string, // senders of user notices held during the rollover
	// Source of the latest idle withheld during the rollover ("" = none, or the
	// agent went active since). Re-reported when the rollover ends without a
	// restart so the hub does not keep showing an idle agent as active.
	withheld_idle_source: string,
}

Bridge_Rollover_Action_Kind :: enum {
	Deliver_Request,
	Restart,
	Alert,
	Deliver_Notice,
	Report_Idle,
}

Bridge_Rollover_Action :: struct {
	kind:        Bridge_Rollover_Action_Kind,
	instance_id: string,
	text:        string, // request text, alert text or notice sender
	coordinator: string, // Alert only
}

// Side effects, replaceable by tests. Nil members use the real implementation.
Bridge_Rollover_Effects :: struct {
	deliver_line:   proc(instance_id, text: string) -> bool,
	deliver_notice: proc(instance_id, sender: string) -> bool,
	persist:        proc(rec: Bridge_Local_Agent_Token_Record, request_id, body, metadata: string) -> Bridge_Local_Relay_Result,
	restart:        proc(instance_id: string) -> bool,
	alert:          proc(instance_id, coordinator_id, text: string),
	report_idle:    proc(instance_id, source: string),
}

bridge_rollover_mutex: sync.Mutex
bridge_rollover_states: [dynamic]Bridge_Rollover_State
bridge_rollover_effects: Bridge_Rollover_Effects
bridge_rollover_sync_effects: bool
bridge_rollover_worker_started: bool

// ---- pure renderers --------------------------------------------------------

// bridge_rollover_request_text renders the single-line request typed into the
// agent's PTY (newlines would be stripped by the paste wrapper anyway).
bridge_rollover_request_text :: proc(instance_id: string, context_pct, window: i64, attempt: int, allocator := context.allocator) -> string {
	lead := "Context rollover" if attempt <= 1 else "Reminder (context rollover)"
	return fmt.aprintf(
		"%s: your context is at %d%% of its %d-token window, so Heimdall will restart you with a fresh context. " +
		"First write a handoff for your next self and send it as ONE message to your own instance with " +
		"`%s chat send --to %s --body \"<handoff>\"`. Include: the goal; the current state; the lease and task ids you hold; " +
		"decisions made and why; dead ends; key files; the exact next steps. Do not start other work; " +
		"after sending it, stop and wait to be restarted.",
		lead, max(context_pct, 0), window, agent_runtime.CTL_SHIM_INVOCATION, instance_id, allocator = allocator,
	)
}

bridge_rollover_request_id :: proc(instance_id: string, seq: int, allocator := context.allocator) -> string {
	return fmt.aprintf("rollover_%s_%d", instance_id, seq, allocator = allocator)
}

bridge_rollover_request_timeout_alert_text :: proc(instance_id: string, context_pct: i64, allocator := context.allocator) -> string {
	return fmt.aprintf(
		"Context rollover for agent `%s` stalled: it did not send its previous_context handoff after 2 requests (%d min each). " +
		"It was NOT restarted and keeps running at %d%% context; it will be asked again after a %d min cooldown.",
		instance_id, BRIDGE_ROLLOVER_REQUEST_TIMEOUT_MS / 60_000, max(context_pct, 0), BRIDGE_ROLLOVER_COOLDOWN_MS / 60_000, allocator = allocator,
	)
}

bridge_rollover_restart_stall_alert_text :: proc(instance_id: string, allocator := context.allocator) -> string {
	return fmt.aprintf(
		"Context rollover for agent `%s`: its previous_context handoff is saved, but it has not gone idle for %d min, so it has not been restarted yet. " +
		"It will be restarted at its next idle point.",
		instance_id, BRIDGE_ROLLOVER_REQUEST_TIMEOUT_MS / 60_000, allocator = allocator,
	)
}

bridge_rollover_restart_failed_alert_text :: proc(instance_id: string, allocator := context.allocator) -> string {
	return fmt.aprintf(
		"Context rollover for agent `%s`: its previous_context handoff is saved, but the hub refused the restart. " +
		"The agent keeps running; restart it from Heimdall when convenient.",
		instance_id, allocator = allocator,
	)
}

// ---- state -----------------------------------------------------------------

@(private = "file")
bridge_rollover_state_locked :: proc(instance_id: string, create := true) -> ^Bridge_Rollover_State {
	for &s in bridge_rollover_states {
		if s.agent_instance_id == instance_id do return &s
	}
	if !create || len(bridge_rollover_states) >= BRIDGE_ROLLOVER_MAX_INSTANCES do return nil
	append(&bridge_rollover_states, Bridge_Rollover_State{agent_instance_id = strings.clone(instance_id, bridge_rollover_heap())})
	return &bridge_rollover_states[len(bridge_rollover_states) - 1]
}

// Rollover state outlives any request (and any test's tracking allocator).
bridge_rollover_heap :: proc() -> runtime.Allocator {
	return runtime.heap_allocator()
}

@(private = "file")
bridge_rollover_set_phase_locked :: proc(s: ^Bridge_Rollover_State, phase: Bridge_Rollover_Phase, now: i64) {
	s.phase = phase
	s.phase_at_ms = now
}

// bridge_rollover_finish_locked returns s to normal with a fresh cooldown and
// moves the queued notices into actions.
@(private = "file")
bridge_rollover_finish_locked :: proc(s: ^Bridge_Rollover_State, now: i64, actions: ^[dynamic]Bridge_Rollover_Action) {
	bridge_rollover_set_phase_locked(s, .Normal, now)
	s.attempts = 0
	s.restart_requested = false
	s.stall_alerted = false
	s.cooldown_until_ms = now + BRIDGE_ROLLOVER_COOLDOWN_MS
	if s.withheld_idle_source != "" {
		append(actions, Bridge_Rollover_Action{kind = .Report_Idle, instance_id = strings.clone(s.agent_instance_id), text = strings.clone(s.withheld_idle_source)})
		delete(s.withheld_idle_source, bridge_rollover_heap())
		s.withheld_idle_source = ""
	}
	for sender in s.queued_notices {
		append(actions, Bridge_Rollover_Action{kind = .Deliver_Notice, instance_id = strings.clone(s.agent_instance_id), text = strings.clone(sender)})
		delete(sender, bridge_rollover_heap())
	}
	clear(&s.queued_notices)
}

@(private = "file")
bridge_rollover_request_action_locked :: proc(s: ^Bridge_Rollover_State, window: i64) -> Bridge_Rollover_Action {
	return Bridge_Rollover_Action{
		kind = .Deliver_Request, instance_id = strings.clone(s.agent_instance_id),
		text = bridge_rollover_request_text(s.agent_instance_id, s.context_pct, window, s.attempts),
	}
}

@(private = "file")
bridge_rollover_alert_action_locked :: proc(s: ^Bridge_Rollover_State, text: string) -> Bridge_Rollover_Action {
	return Bridge_Rollover_Action{kind = .Alert, instance_id = strings.clone(s.agent_instance_id), text = text, coordinator = strings.clone(s.coordinator_id)}
}

// bridge_rollover_in_progress: between the typed request and the restarted
// agent's start-success (idle withheld, notices queued).
bridge_rollover_phase_in_progress :: proc(phase: Bridge_Rollover_Phase) -> bool {
	return phase == .Requested || phase == .Persisting || phase == .Restarting
}

// ---- transitions -----------------------------------------------------------

// bridge_rollover_decide_event folds one main-agent signal into the state:
// context_pct (-1 = unknown) and whether the main agent just went idle.
bridge_rollover_decide_event :: proc(instance_id: string, context_pct: i64, idle: bool, rollover_pct: int, window: i64, now: i64) -> [dynamic]Bridge_Rollover_Action {
	context.allocator = bridge_rollover_heap()
	actions := make([dynamic]Bridge_Rollover_Action)
	if strings.trim_space(instance_id) == "" do return actions
	sync.mutex_lock(&bridge_rollover_mutex)
	defer sync.mutex_unlock(&bridge_rollover_mutex)
	s := bridge_rollover_state_locked(instance_id, create = context_pct >= i64(rollover_pct))
	if s == nil do return actions
	if s.phase == .Normal && context_pct >= i64(rollover_pct) && now >= s.cooldown_until_ms {
		s.context_pct = context_pct
		bridge_rollover_set_phase_locked(s, .Pending, now)
	}
	if s.phase == .Pending && context_pct > s.context_pct do s.context_pct = context_pct
	if !idle do return actions
	#partial switch s.phase {
	case .Pending:
		s.seq += 1
		s.attempts = 1
		bridge_rollover_set_phase_locked(s, .Requested, now)
		append(&actions, bridge_rollover_request_action_locked(s, window))
	case .Restarting:
		if !s.restart_requested {
			s.restart_requested = true
			s.phase_at_ms = now
			append(&actions, Bridge_Rollover_Action{kind = .Restart, instance_id = strings.clone(s.agent_instance_id)})
		}
	}
	return actions
}

// bridge_rollover_decide_tick applies the timeouts.
bridge_rollover_decide_tick :: proc(now: i64, window_for: proc(instance_id: string) -> i64 = nil) -> [dynamic]Bridge_Rollover_Action {
	context.allocator = bridge_rollover_heap()
	actions := make([dynamic]Bridge_Rollover_Action)
	sync.mutex_lock(&bridge_rollover_mutex)
	defer sync.mutex_unlock(&bridge_rollover_mutex)
	for &s in bridge_rollover_states {
		if now - s.phase_at_ms < BRIDGE_ROLLOVER_REQUEST_TIMEOUT_MS do continue
		#partial switch s.phase {
		case .Requested:
			if s.attempts < 2 {
				s.attempts += 1
				s.phase_at_ms = now
				window := window_for(s.agent_instance_id) if window_for != nil else BRIDGE_EXT_TOKEN_DEFAULT_WINDOW
				append(&actions, bridge_rollover_request_action_locked(&s, window))
			} else {
				append(&actions, bridge_rollover_alert_action_locked(&s, bridge_rollover_request_timeout_alert_text(s.agent_instance_id, s.context_pct)))
				bridge_rollover_finish_locked(&s, now, &actions)
			}
		case .Restarting:
			if !s.restart_requested && !s.stall_alerted {
				s.stall_alerted = true
				append(&actions, bridge_rollover_alert_action_locked(&s, bridge_rollover_restart_stall_alert_text(s.agent_instance_id)))
			}
		}
	}
	return actions
}

// bridge_rollover_begin_persist claims a self-addressed chat send. ok=false when
// the instance is not waiting for its handoff (the send is relayed as usual).
bridge_rollover_begin_persist :: proc(instance_id: string, now: i64) -> (request_id: string, attempt: int, context_pct: i64, ok: bool) {
	context.allocator = bridge_rollover_heap()
	sync.mutex_lock(&bridge_rollover_mutex)
	defer sync.mutex_unlock(&bridge_rollover_mutex)
	s := bridge_rollover_state_locked(instance_id, create = false)
	if s == nil || s.phase != .Requested do return
	bridge_rollover_set_phase_locked(s, .Persisting, now)
	return bridge_rollover_request_id(instance_id, s.seq), s.attempts, s.context_pct, true
}

// bridge_rollover_end_persist records the hub's answer: acked -> restarting
// (restart at the next idle); otherwise back to requested so the agent may retry
// (the request timer keeps running from the original request).
bridge_rollover_end_persist :: proc(instance_id: string, acked: bool, now: i64) {
	sync.mutex_lock(&bridge_rollover_mutex)
	defer sync.mutex_unlock(&bridge_rollover_mutex)
	s := bridge_rollover_state_locked(instance_id, create = false)
	if s == nil || s.phase != .Persisting do return
	if acked {
		bridge_rollover_set_phase_locked(s, .Restarting, now)
		s.restart_requested = false
		s.stall_alerted = false
	} else {
		s.phase = .Requested // keep phase_at_ms: the timeout still counts from the request
	}
}

// bridge_rollover_decide_restart_result: a refused restart returns the instance
// to normal (the handoff stays stored) and alerts.
bridge_rollover_decide_restart_result :: proc(instance_id: string, ok: bool, now: i64) -> [dynamic]Bridge_Rollover_Action {
	context.allocator = bridge_rollover_heap()
	actions := make([dynamic]Bridge_Rollover_Action)
	if ok do return actions
	sync.mutex_lock(&bridge_rollover_mutex)
	defer sync.mutex_unlock(&bridge_rollover_mutex)
	s := bridge_rollover_state_locked(instance_id, create = false)
	if s == nil || s.phase != .Restarting do return actions
	append(&actions, bridge_rollover_alert_action_locked(s, bridge_rollover_restart_failed_alert_text(instance_id)))
	bridge_rollover_finish_locked(s, now, &actions)
	return actions
}

// bridge_rollover_decide_start_success completes a rollover once the restarted
// agent reports start-success. Returns whether a rollover completed.
bridge_rollover_decide_start_success :: proc(instance_id: string, now: i64) -> (actions: [dynamic]Bridge_Rollover_Action, completed: bool) {
	context.allocator = bridge_rollover_heap()
	actions = make([dynamic]Bridge_Rollover_Action)
	sync.mutex_lock(&bridge_rollover_mutex)
	defer sync.mutex_unlock(&bridge_rollover_mutex)
	s := bridge_rollover_state_locked(instance_id, create = false)
	if s == nil || s.phase != .Restarting || !s.restart_requested do return
	// The relaunch reports its own status at readiness; the old process's
	// withheld idle is stale.
	delete(s.withheld_idle_source, bridge_rollover_heap())
	s.withheld_idle_source = ""
	bridge_rollover_finish_locked(s, now, &actions)
	completed = true
	return
}

// bridge_rollover_launch_prompt_line is the extra starter-prompt line for a
// launch of instance_id: set only while its rollover restart is in flight.
bridge_rollover_launch_prompt_line :: proc(instance_id: string) -> string {
	sync.mutex_lock(&bridge_rollover_mutex)
	defer sync.mutex_unlock(&bridge_rollover_mutex)
	s := bridge_rollover_state_locked(instance_id, create = false)
	if s == nil || s.phase != .Restarting || !s.restart_requested do return ""
	return BRIDGE_ROLLOVER_RESTART_PROMPT_LINE
}

// bridge_rollover_filter_activity withholds idle while a rollover is in
// progress (reported as active) and remembers it for bridge_rollover_finish_locked.
bridge_rollover_filter_activity :: proc(instance_id, activity: string, source := "") -> string {
	sync.mutex_lock(&bridge_rollover_mutex)
	defer sync.mutex_unlock(&bridge_rollover_mutex)
	s := bridge_rollover_state_locked(instance_id, create = false)
	if s == nil || !bridge_rollover_phase_in_progress(s.phase) do return activity
	heap := bridge_rollover_heap()
	delete(s.withheld_idle_source, heap)
	s.withheld_idle_source = ""
	if activity != "idle" do return activity
	s.withheld_idle_source = strings.clone(source if source != "" else "agent_extension", heap)
	return "active"
}

// bridge_rollover_queue_notice holds a user message notice during a rollover.
// Returns false when no rollover is in progress (deliver it now).
bridge_rollover_queue_notice :: proc(instance_id, sender: string) -> bool {
	sync.mutex_lock(&bridge_rollover_mutex)
	defer sync.mutex_unlock(&bridge_rollover_mutex)
	s := bridge_rollover_state_locked(instance_id, create = false)
	if s == nil || !bridge_rollover_phase_in_progress(s.phase) do return false
	// Repeated notices carry no extra information; keep at most one per sender.
	for q in s.queued_notices do if q == sender do return true
	if len(s.queued_notices) < BRIDGE_ROLLOVER_MAX_QUEUED_NOTICES {
		append(&s.queued_notices, strings.clone(sender, bridge_rollover_heap()))
	}
	return true
}

bridge_rollover_note_launch :: proc(instance_id, coordinator_id: string) {
	if strings.trim_space(instance_id) == "" do return
	sync.mutex_lock(&bridge_rollover_mutex)
	defer sync.mutex_unlock(&bridge_rollover_mutex)
	s := bridge_rollover_state_locked(instance_id, create = strings.trim_space(coordinator_id) != "")
	if s == nil || s.coordinator_id == coordinator_id do return
	delete(s.coordinator_id, bridge_rollover_heap())
	s.coordinator_id = strings.clone(coordinator_id, bridge_rollover_heap())
}

bridge_rollover_phase_of :: proc(instance_id: string) -> Bridge_Rollover_Phase {
	sync.mutex_lock(&bridge_rollover_mutex)
	defer sync.mutex_unlock(&bridge_rollover_mutex)
	s := bridge_rollover_state_locked(instance_id, create = false)
	return s.phase if s != nil else .Normal
}

bridge_rollover_forget :: proc(instance_id: string) {
	sync.mutex_lock(&bridge_rollover_mutex)
	defer sync.mutex_unlock(&bridge_rollover_mutex)
	for s, i in bridge_rollover_states {
		if s.agent_instance_id != instance_id do continue
		heap := bridge_rollover_heap()
		delete(s.agent_instance_id, heap); delete(s.coordinator_id, heap); delete(s.withheld_idle_source, heap)
		for q in s.queued_notices do delete(q, heap)
		delete(s.queued_notices)
		unordered_remove(&bridge_rollover_states, i)
		return
	}
}

// ---- wiring ----------------------------------------------------------------

// bridge_rollover_on_ext_event is called by extension ingest for every
// main-agent event after the token accumulator has folded it in.
bridge_rollover_on_ext_event :: proc(instance_id: string, idle: bool, now: i64) {
	window, _, pct := bridge_ext_context_window_for(instance_id)
	_, rollover_pct, _ := bridge_context_window_thresholds()
	actions := bridge_rollover_decide_event(instance_id, pct, idle, rollover_pct, window, now)
	if len(actions) > 0 || bridge_rollover_phase_of(instance_id) != .Normal do bridge_rollover_worker_ensure_started()
	bridge_rollover_run(actions)
}

// bridge_rollover_on_activity feeds an activity report that did not come from
// extension ingest (the pane_diff screen detector, for providers without an
// extension such as Pi) into the state machine. Only pane_diff is accepted: it
// observes the instance's main pane, so it is always the main agent. Only an
// explicit "idle" counts as a finished turn: waiting_user / waiting_approval
// are blocked prompts, not rollover-safe. Repeated idle from several sources
// is harmless: Requested / restart_requested make the transitions idempotent.
bridge_rollover_on_activity :: proc(instance_id, activity, source: string, now: i64) {
	if source != "pane_diff" || strings.trim_space(instance_id) == "" do return
	bridge_rollover_on_ext_event(instance_id, activity == "idle", now)
}

// bridge_rollover_intercept_chat_send handles agent.chat.send. handled=false
// means it is not this instance's pending handoff: relay it as usual.
bridge_rollover_intercept_chat_send :: proc(request_id, params: string, rec: Bridge_Local_Agent_Token_Record) -> (response: string, handled: bool) {
	context.allocator = bridge_rollover_heap()
	to := strings.trim_space(bridge_local_extract_json_string(params, "to", "", context.temp_allocator))
	if to == "" || to != rec.agent_instance_id do return "", false
	now := bridge_runtime_now_ms()
	pctx_request_id, attempt, context_pct, claimed := bridge_rollover_begin_persist(rec.agent_instance_id, now)
	if !claimed do return "", false
	defer delete(pctx_request_id)
	body := bridge_local_extract_json_string(params, "body", "", context.temp_allocator)
	if strings.trim_space(body) == "" {
		bridge_rollover_end_persist(rec.agent_instance_id, false, now)
		return bridge_local_response_error(request_id, "bad_request", "previous_context handoff body is empty; resend it with --body"), true
	}
	metadata := fmt.tprintf(`{{"kind":"context_rollover","context_pct":%d,"attempt":%d}}`, max(context_pct, 0), attempt)
	persist := bridge_rollover_effects.persist if bridge_rollover_effects.persist != nil else bridge_rollover_persist_default
	relay := persist(rec, pctx_request_id, body, metadata)
	acked := relay.ok && relay.status >= 200 && relay.status < 300 && strings.contains(relay.body, `"accepted":true`)
	bridge_rollover_end_persist(rec.agent_instance_id, acked, bridge_runtime_now_ms())
	if !acked {
		if !relay.ok do return bridge_local_response_error(request_id, "retryable_unavailable", "previous_context was not saved (hub unreachable); send it again"), true
		return bridge_local_response_error(request_id, "hub_error", relay.body), true
	}
	bridge_rollover_worker_ensure_started()
	return bridge_local_response_data(request_id, relay.body), true
}

// bridge_rollover_on_start_success completes a rollover restart.
bridge_rollover_on_start_success :: proc(instance_id: string) {
	actions, completed := bridge_rollover_decide_start_success(instance_id, bridge_runtime_now_ms())
	if completed do bridge_ext_token_usage_reset_instance(instance_id)
	bridge_rollover_run(actions)
}

bridge_rollover_tick :: proc(now: i64) {
	actions := bridge_rollover_decide_tick(now, proc(id: string) -> i64 {
		window, _, _ := bridge_ext_context_window_for(id)
		return window
	})
	bridge_rollover_run(actions)
}

bridge_rollover_worker_ensure_started :: proc() {
	if bridge_rollover_sync_effects do return
	if _, swapped := sync.atomic_compare_exchange_strong(&bridge_rollover_worker_started, false, true); swapped {
		thread.run(proc() {
			for {
				time.sleep(BRIDGE_ROLLOVER_TICK_MS * time.Millisecond)
				bridge_rollover_tick(bridge_runtime_now_ms())
				free_all(context.temp_allocator)
			}
		})
	}
}

bridge_rollover_actions_destroy :: proc(actions: [dynamic]Bridge_Rollover_Action) {
	context.allocator = bridge_rollover_heap()
	for a in actions {
		delete(a.instance_id); delete(a.text); delete(a.coordinator)
	}
	delete(actions)
}

// bridge_rollover_run executes actions (owning and freeing them), on a worker
// thread unless bridge_rollover_sync_effects is set.
bridge_rollover_run :: proc(actions: [dynamic]Bridge_Rollover_Action) {
	context.allocator = bridge_rollover_heap()
	if len(actions) == 0 {
		delete(actions)
		return
	}
	if bridge_rollover_sync_effects {
		bridge_rollover_execute(actions)
		return
	}
	thread.run_with_poly_data(actions, proc(actions: [dynamic]Bridge_Rollover_Action) {
		bridge_rollover_execute(actions)
		free_all(context.temp_allocator)
	})
}

bridge_rollover_execute :: proc(actions: [dynamic]Bridge_Rollover_Action) {
	context.allocator = bridge_rollover_heap()
	defer bridge_rollover_actions_destroy(actions)
	for a in actions {
		switch a.kind {
		case .Deliver_Request:
			deliver := bridge_rollover_effects.deliver_line if bridge_rollover_effects.deliver_line != nil else bridge_rollover_deliver_line_default
			if !deliver(a.instance_id, a.text) do fmt.println("bridge context rollover: request delivery failed", a.instance_id)
		case .Restart:
			restart := bridge_rollover_effects.restart if bridge_rollover_effects.restart != nil else bridge_rollover_restart_default
			ok := restart(a.instance_id)
			if !ok do fmt.println("bridge context rollover: hub restart refused", a.instance_id)
			follow := bridge_rollover_decide_restart_result(a.instance_id, ok, bridge_runtime_now_ms())
			bridge_rollover_execute(follow)
		case .Alert:
			alert := bridge_rollover_effects.alert if bridge_rollover_effects.alert != nil else bridge_rollover_alert_default
			alert(a.instance_id, a.coordinator, a.text)
		case .Deliver_Notice:
			deliver := bridge_rollover_effects.deliver_notice if bridge_rollover_effects.deliver_notice != nil else bridge_rollover_deliver_notice_default
			_ = deliver(a.instance_id, a.text)
		case .Report_Idle:
			report := bridge_rollover_effects.report_idle if bridge_rollover_effects.report_idle != nil else bridge_rollover_report_idle_default
			report(a.instance_id, a.text)
		}
	}
}

// ---- default effects -------------------------------------------------------

bridge_rollover_deliver_line_default :: proc(instance_id, text: string) -> bool {
	socket, ok := bridge_pty_host_ensure_daemon()
	if !ok do return false
	return bridge_pty_host_deliver_line(socket, instance_id, text)
}

bridge_rollover_report_idle_default :: proc(instance_id, source: string) {
	bridge_runtime_note_activity_signal(instance_id, "idle", source)
}

bridge_rollover_deliver_notice_default :: proc(instance_id, sender: string) -> bool {
	return bridge_pty_host_deliver_to_agent(instance_id, "message", sender, "", "")
}

bridge_rollover_rec_for :: proc(instance_id: string) -> (rec: Bridge_Local_Agent_Token_Record, ok: bool) {
	token := bridge_agent_instance_assertion(instance_id)
	if strings.trim_space(token) == "" {
		delete(token)
		return {}, false
	}
	return Bridge_Local_Agent_Token_Record{agent_instance_id = instance_id, instance_token = token}, true
}

bridge_rollover_persist_default :: proc(rec: Bridge_Local_Agent_Token_Record, request_id, body, metadata: string) -> Bridge_Local_Relay_Result {
	if strings.trim_space(rec.instance_token) == "" || !sync.atomic_load(&bridge_hub_runtime_up) do return {}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"request_id":"`); bridge_local_write_json_string(&b, request_id)
	strings.write_string(&b, `","body":"`); bridge_local_write_json_string(&b, body)
	strings.write_string(&b, `","metadata":`); strings.write_string(&b, metadata)
	strings.write_string(&b, "}")
	route := bridge_agent_route("agent.chat.previous_context", strings.to_string(b))
	return bridge_local_relay_agent_envelope(route.path, "agent.chat.previous_context", strings.to_string(b), rec)
}

bridge_rollover_restart_default :: proc(instance_id: string) -> bool {
	rec, ok := bridge_rollover_rec_for(instance_id)
	if !ok do return false
	defer delete(rec.instance_token)
	if !sync.atomic_load(&bridge_hub_runtime_up) do return false
	route := bridge_agent_route("agent.agents.instance_restart", fmt.tprintf(`{{"agent_instance_id":"%s"}}`, instance_id))
	if route.kind != .Raw do return false
	relay := bridge_local_relay_raw(route.http_method, route.path, route.query, "{}", rec)
	return relay.ok && relay.status >= 200 && relay.status < 300
}

// bridge_rollover_alert_default sends text to the user and (when known and not
// the agent itself) the chain coordinator, as the agent.
bridge_rollover_alert_default :: proc(instance_id, coordinator_id, text: string) {
	fmt.println("bridge context rollover alert", instance_id, text)
	rec, ok := bridge_rollover_rec_for(instance_id)
	if !ok do return
	defer delete(rec.instance_token)
	if !sync.atomic_load(&bridge_hub_runtime_up) do return
	targets := [2]string{"user", strings.trim_space(coordinator_id)}
	for to in targets {
		if to == "" || to == instance_id do continue
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"to":"`); bridge_local_write_json_string(&b, to)
		strings.write_string(&b, `","body":"`); bridge_local_write_json_string(&b, text)
		strings.write_string(&b, `"}`)
		params := strings.to_string(b)
		route := bridge_agent_route("agent.chat.send", params)
		if route.kind != .Envelope do continue
		eff := bridge_agent_rewrite_params("agent.chat.send", params)
		relay := bridge_local_relay_agent_envelope(route.path, "agent.chat.send", eff, rec)
		if !relay.ok || relay.status < 200 || relay.status >= 300 do fmt.println("bridge context rollover alert not delivered", instance_id, to, relay.status)
	}
}
