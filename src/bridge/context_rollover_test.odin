package main

import "core:strings"
import "core:sync"
import "core:testing"
import agent_runtime "odin_test:lib/agent_runtime"

// Context rollover (context_rollover.odin): every transition, the self-send
// interception (persisted and acked, never relayed), timeout retry + alert,
// cooldown, withheld idle, queued notices, the restart prompt line, and the
// extension-ingest wiring.

@(private = "file")
roll_test_mutex: sync.Mutex

@(private = "file")
Roll_Recorder :: struct {
	requests:   [dynamic]string, // "<instance>|<text>"
	notices:    [dynamic]string, // "<instance>|<sender>"
	persists:   [dynamic]string, // "<instance>|<request_id>|<body>|<metadata>"
	restarts:   [dynamic]string,
	alerts:     [dynamic]string, // "<instance>|<coordinator>|<text>"
	idles:      [dynamic]string, // "<instance>|<source>"
	persist_ok: bool,
	restart_ok: bool,
}

@(private = "file")
roll_rec: Roll_Recorder

@(private = "file")
roll_begin :: proc() {
	sync.mutex_lock(&roll_test_mutex)
	roll_rec = Roll_Recorder{persist_ok = true, restart_ok = true}
	bridge_rollover_sync_effects = true
	bridge_rollover_effects = Bridge_Rollover_Effects{
		deliver_line = proc(id, text: string) -> bool {
			append(&roll_rec.requests, strings.concatenate({id, "|", text}, context.temp_allocator)); return true
		},
		deliver_notice = proc(id, sender: string) -> bool {
			append(&roll_rec.notices, strings.concatenate({id, "|", sender}, context.temp_allocator)); return true
		},
		persist = proc(rec: Bridge_Local_Agent_Token_Record, request_id, body, metadata: string) -> Bridge_Local_Relay_Result {
			append(&roll_rec.persists, strings.concatenate({rec.agent_instance_id, "|", request_id, "|", body, "|", metadata}, context.temp_allocator))
			if !roll_rec.persist_ok do return Bridge_Local_Relay_Result{ok = true, status = 503, body = `{"error":"down"}`}
			return Bridge_Local_Relay_Result{ok = true, status = 201, body = `{"accepted":true,"created":true,"message_id":"msg_pctx_1","message_type":"previous_context"}`}
		},
		restart = proc(id: string) -> bool {
			append(&roll_rec.restarts, strings.clone(id, context.temp_allocator)); return roll_rec.restart_ok
		},
		report_idle = proc(id, source: string) {
			append(&roll_rec.idles, strings.concatenate({id, "|", source}, context.temp_allocator))
		},
		alert = proc(id, coordinator, text: string) {
			append(&roll_rec.alerts, strings.concatenate({id, "|", coordinator, "|", text}, context.temp_allocator))
		},
	}
}

@(private = "file")
roll_end :: proc(ids: ..string) {
	for id in ids do bridge_rollover_forget(id)
	bridge_rollover_effects = {}
	bridge_rollover_sync_effects = false
	delete(roll_rec.requests); delete(roll_rec.notices); delete(roll_rec.persists)
	delete(roll_rec.restarts); delete(roll_rec.alerts); delete(roll_rec.idles)
	roll_rec = {}
	sync.mutex_unlock(&roll_test_mutex)
}

@(private = "file")
roll_event :: proc(id: string, pct: i64, idle: bool, now: i64) {
	bridge_rollover_run(bridge_rollover_decide_event(id, pct, idle, 80, 200_000, now))
}

@(private = "file")
roll_tick :: proc(now: i64) {
	bridge_rollover_run(bridge_rollover_decide_tick(now))
}

@(private = "file")
roll_self_send :: proc(id, body: string) -> (string, bool) {
	params := strings.concatenate({`{"to":"`, id, `","body":"`, body, `"}`}, context.temp_allocator)
	return bridge_rollover_intercept_chat_send("req_1", params, Bridge_Local_Agent_Token_Record{agent_instance_id = id, instance_token = "itok", role = .Agent})
}

@(test)
test_rollover_full_cycle_transitions :: proc(t: ^testing.T) {
	roll_begin()
	id := "inst_test_roll_cycle"
	defer roll_end(id)
	now := i64(1_000_000)

	// Below threshold: nothing, and no state is even created.
	roll_event(id, 79, true, now)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Normal)
	// At threshold mid-turn: pending only, nothing typed.
	roll_event(id, 80, false, now + 1)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Pending)
	testing.expect_value(t, len(roll_rec.requests), 0)
	// Next idle (Stop): the templated request is typed.
	roll_event(id, 83, true, now + 2)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Requested)
	testing.expect_value(t, len(roll_rec.requests), 1)
	req := roll_rec.requests[0]
	testing.expect(t, strings.has_prefix(req, strings.concatenate({id, "|Context rollover: your context is at 83% of its 200000-token window"}, context.temp_allocator)), req)
	testing.expect(t, strings.contains(req, strings.concatenate({"`" + agent_runtime.CTL_SHIM_INVOCATION + " chat send --to ", id, " --body"}, context.temp_allocator)), "request names the self-addressed send")
	for want in ([]string{"goal", "current state", "lease and task ids", "decisions", "dead ends", "key files", "next steps"}) {
		testing.expect(t, strings.contains(req, want), want)
	}
	testing.expect(t, !strings.contains(req, "\n"), "request is one line")
	// No restart prompt line before the restart is requested.
	testing.expect_value(t, bridge_rollover_launch_prompt_line(id), "")

	// The self-send is persisted (acked) and answered locally.
	resp, handled := roll_self_send(id, "## Handoff\\ngoal: X")
	testing.expect(t, handled, "self-send intercepted")
	testing.expect(t, strings.contains(resp, `"message_type":"previous_context"`), resp)
	testing.expect_value(t, len(roll_rec.persists), 1)
	testing.expect(t, strings.has_prefix(roll_rec.persists[0], strings.concatenate({id, "|rollover_", id, "_1|## Handoff\ngoal: X|"}, context.temp_allocator)), roll_rec.persists[0])
	testing.expect(t, strings.contains(roll_rec.persists[0], `"kind":"context_rollover","context_pct":83,"attempt":1`), roll_rec.persists[0])
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Restarting)
	testing.expect_value(t, len(roll_rec.restarts), 0) // never mid-turn

	// The agent's next idle requests the hub restart; the prompt line is armed.
	roll_event(id, 84, true, now + 3)
	testing.expect_value(t, len(roll_rec.restarts), 1)
	testing.expect_value(t, roll_rec.restarts[0], id)
	testing.expect_value(t, bridge_rollover_launch_prompt_line(id), BRIDGE_ROLLOVER_RESTART_PROMPT_LINE)
	roll_event(id, 84, true, now + 4)
	testing.expect_value(t, len(roll_rec.restarts), 1) // only once

	// Restarted agent's readiness: back to normal, prompt line disarmed.
	actions, completed := bridge_rollover_decide_start_success(id, now + 5)
	bridge_rollover_run(actions)
	testing.expect(t, completed)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Normal)
	testing.expect_value(t, bridge_rollover_launch_prompt_line(id), "")
	testing.expect_value(t, len(roll_rec.alerts), 0)

	// A second rollover gets a new request id.
	roll_event(id, 90, true, now + 5 + BRIDGE_ROLLOVER_COOLDOWN_MS)
	_, _ = roll_self_send(id, "second")
	testing.expect_value(t, len(roll_rec.persists), 2)
	testing.expect(t, strings.contains(roll_rec.persists[1], strings.concatenate({"|rollover_", id, "_2|"}, context.temp_allocator)), roll_rec.persists[1])
}

@(test)
test_rollover_self_send_outside_rollover_is_not_intercepted :: proc(t: ^testing.T) {
	roll_begin()
	id := "inst_test_roll_passthru"
	defer roll_end(id)
	_, handled := roll_self_send(id, "note to self")
	testing.expect(t, !handled, "normal: relayed as usual")
	roll_event(id, 95, false, 10)
	_, handled = roll_self_send(id, "note to self")
	testing.expect(t, !handled, "pending (not yet requested): relayed as usual")
	roll_event(id, 95, true, 11)
	// A send to someone else during the request is ordinary chat.
	params := `{"to":"inst_other","body":"hi"}`
	_, handled = bridge_rollover_intercept_chat_send("r", params, Bridge_Local_Agent_Token_Record{agent_instance_id = id, instance_token = "itok"})
	testing.expect(t, !handled, "send to another agent relayed")
	_, handled = bridge_rollover_intercept_chat_send("r", `{"to":"user","body":"hi"}`, Bridge_Local_Agent_Token_Record{agent_instance_id = id, instance_token = "itok"})
	testing.expect(t, !handled, "send to user relayed")
	testing.expect_value(t, len(roll_rec.persists), 0)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Requested)
}

@(test)
test_rollover_persist_failure_and_empty_body_allow_retry :: proc(t: ^testing.T) {
	roll_begin()
	id := "inst_test_roll_persist_fail"
	defer roll_end(id)
	roll_event(id, 85, true, 100)
	resp, handled := roll_self_send(id, "  ")
	testing.expect(t, handled)
	testing.expect(t, strings.contains(resp, "bad_request"), resp)
	testing.expect_value(t, len(roll_rec.persists), 0)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Requested)

	roll_rec.persist_ok = false
	resp, handled = roll_self_send(id, "handoff")
	testing.expect(t, handled, "a failed persist is still never relayed as chat")
	testing.expect(t, strings.contains(resp, "hub_error"), resp)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Requested)

	roll_rec.persist_ok = true
	_, handled = roll_self_send(id, "handoff")
	testing.expect(t, handled)
	testing.expect_value(t, len(roll_rec.persists), 2)
	// Same rollover -> same request id (the hub dedupes on it).
	testing.expect_value(t, strings.split(roll_rec.persists[0], "|", context.temp_allocator)[1], strings.split(roll_rec.persists[1], "|", context.temp_allocator)[1])
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Restarting)
}

@(test)
test_rollover_timeout_retries_once_then_alerts_and_cools_down :: proc(t: ^testing.T) {
	roll_begin()
	id := "inst_test_roll_timeout"
	defer roll_end(id)
	bridge_rollover_note_launch(id, "inst_coord_1")
	now := i64(5_000_000)
	roll_event(id, 88, true, now)
	testing.expect_value(t, len(roll_rec.requests), 1)
	testing.expect_value(t, bridge_rollover_filter_activity(id, "idle", "claude_extension"), "active")

	roll_tick(now + BRIDGE_ROLLOVER_REQUEST_TIMEOUT_MS - 1)
	testing.expect_value(t, len(roll_rec.requests), 1)
	// First timeout: the request is typed once more.
	roll_tick(now + BRIDGE_ROLLOVER_REQUEST_TIMEOUT_MS)
	testing.expect_value(t, len(roll_rec.requests), 2)
	testing.expect(t, strings.contains(roll_rec.requests[1], "Reminder (context rollover)"), roll_rec.requests[1])
	testing.expect_value(t, len(roll_rec.alerts), 0)
	// Second timeout: alert user + coordinator, no restart, back to normal.
	t2 := now + 2 * BRIDGE_ROLLOVER_REQUEST_TIMEOUT_MS
	roll_tick(t2)
	testing.expect_value(t, len(roll_rec.requests), 2)
	testing.expect_value(t, len(roll_rec.alerts), 1)
	testing.expect(t, strings.has_prefix(roll_rec.alerts[0], strings.concatenate({id, "|inst_coord_1|Context rollover for agent `", id, "` stalled"}, context.temp_allocator)), roll_rec.alerts[0])
	testing.expect_value(t, len(roll_rec.restarts), 0)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Normal)
	// The idle withheld during the rollover is reported now that it is over.
	testing.expect_value(t, len(roll_rec.idles), 1)
	testing.expect_value(t, roll_rec.idles[0], strings.concatenate({id, "|claude_extension"}, context.temp_allocator))
	roll_tick(t2 + BRIDGE_ROLLOVER_REQUEST_TIMEOUT_MS)
	testing.expect_value(t, len(roll_rec.alerts), 1)

	// A late handoff after giving up is ordinary chat.
	_, handled := roll_self_send(id, "late")
	testing.expect(t, !handled)

	// Cooldown: still above threshold, but no new rollover for 10 min.
	roll_event(id, 95, true, t2 + BRIDGE_ROLLOVER_COOLDOWN_MS - 1)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Normal)
	testing.expect_value(t, len(roll_rec.requests), 2)
	roll_event(id, 95, true, t2 + BRIDGE_ROLLOVER_COOLDOWN_MS)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Requested)
	testing.expect_value(t, len(roll_rec.requests), 3)
	testing.expect(t, strings.contains(roll_rec.requests[2], "|Context rollover:"), "a fresh rollover starts with attempt 1")
}

@(test)
test_rollover_cooldown_after_completed_restart :: proc(t: ^testing.T) {
	roll_begin()
	id := "inst_test_roll_cooldown"
	defer roll_end(id)
	now := i64(9_000_000)
	roll_event(id, 81, true, now)
	_, _ = roll_self_send(id, "h")
	roll_event(id, 81, true, now + 1)
	actions, _ := bridge_rollover_decide_start_success(id, now + 2)
	bridge_rollover_run(actions)
	roll_event(id, 99, true, now + 2 + BRIDGE_ROLLOVER_COOLDOWN_MS - 1)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Normal)
	roll_event(id, 99, false, now + 2 + BRIDGE_ROLLOVER_COOLDOWN_MS)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Pending)
}

@(test)
test_rollover_restart_stall_alert_and_refused_restart :: proc(t: ^testing.T) {
	roll_begin()
	id := "inst_test_roll_restart"
	defer roll_end(id)
	now := bridge_runtime_now_ms() // the intercept stamps the persisted phase with the real clock
	roll_event(id, 85, true, now)
	_, _ = roll_self_send(id, "h")
	// Persisted but never idle: one alert, still waiting, never forced.
	roll_tick(now + BRIDGE_ROLLOVER_REQUEST_TIMEOUT_MS + 10)
	roll_tick(now + 2 * BRIDGE_ROLLOVER_REQUEST_TIMEOUT_MS + 10)
	testing.expect_value(t, len(roll_rec.alerts), 1)
	testing.expect(t, strings.contains(roll_rec.alerts[0], "has not gone idle"), roll_rec.alerts[0])
	testing.expect_value(t, len(roll_rec.restarts), 0)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Restarting)
	// The hub refuses the restart: alert, back to normal.
	roll_rec.restart_ok = false
	roll_event(id, 85, true, now + 3 * BRIDGE_ROLLOVER_REQUEST_TIMEOUT_MS)
	testing.expect_value(t, len(roll_rec.restarts), 1)
	testing.expect_value(t, len(roll_rec.alerts), 2)
	testing.expect(t, strings.contains(roll_rec.alerts[1], "refused the restart"), roll_rec.alerts[1])
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Normal)
	testing.expect_value(t, bridge_rollover_launch_prompt_line(id), "")
}

@(test)
test_rollover_withholds_idle_and_queues_notices :: proc(t: ^testing.T) {
	roll_begin()
	id := "inst_test_roll_guards"
	defer roll_end(id)
	testing.expect_value(t, bridge_rollover_filter_activity(id, "idle"), "idle")
	testing.expect(t, !bridge_rollover_queue_notice(id, "User"), "normal: delivered at once")
	roll_event(id, 85, false, 1)
	testing.expect_value(t, bridge_rollover_filter_activity(id, "idle"), "idle") // pending is normal operation
	roll_event(id, 85, true, 2)
	testing.expect_value(t, bridge_rollover_filter_activity(id, "idle"), "active")
	testing.expect_value(t, bridge_rollover_filter_activity(id, "waiting_user"), "waiting_user")
	testing.expect_value(t, bridge_rollover_filter_activity(id, "idle", "pane_diff"), "active")
	testing.expect(t, bridge_rollover_queue_notice(id, "User"))
	testing.expect(t, bridge_rollover_queue_notice(id, "User")) // de-duplicated
	_, _ = roll_self_send(id, "h")
	testing.expect_value(t, bridge_rollover_filter_activity(id, "idle"), "active")
	testing.expect(t, bridge_rollover_queue_notice(id, "inst_peer"))
	roll_event(id, 85, true, 3)
	testing.expect_value(t, bridge_rollover_filter_activity(id, "idle"), "active")
	testing.expect_value(t, len(roll_rec.notices), 0)
	actions, _ := bridge_rollover_decide_start_success(id, 4)
	bridge_rollover_run(actions)
	testing.expect_value(t, len(roll_rec.notices), 2)
	testing.expect_value(t, roll_rec.notices[0], strings.concatenate({id, "|User"}, context.temp_allocator))
	testing.expect_value(t, roll_rec.notices[1], strings.concatenate({id, "|inst_peer"}, context.temp_allocator))
	testing.expect_value(t, len(roll_rec.idles), 0) // the relaunch reports its own readiness
	testing.expect_value(t, bridge_rollover_filter_activity(id, "idle"), "idle")
}

@(test)
test_rollover_start_success_without_restart_is_ignored :: proc(t: ^testing.T) {
	roll_begin()
	id := "inst_test_roll_ss"
	defer roll_end(id)
	roll_event(id, 85, true, 1)
	_, _ = roll_self_send(id, "h")
	// Restart not yet requested (agent never went idle): a start-success is not ours.
	actions, completed := bridge_rollover_decide_start_success(id, 2)
	bridge_rollover_run(actions)
	testing.expect(t, !completed)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Restarting)
}

@(test)
test_rollover_starter_prompt_line_rendered_for_that_launch_only :: proc(t: ^testing.T) {
	// render_starter_prompt_for_agent's intermediate replace_all copies are not
	// freed by design (launch-scoped); keep them off the tracking allocator.
	context.allocator = context.temp_allocator
	profile := agent_runtime.Agent_Profile{starter_prompt = "Read CLAUDE.md."}
	plain := agent_runtime.render_starter_prompt_for_agent(profile, "", "tok", "inst_x")
	testing.expect(t, !strings.contains(plain, "rolled over"), plain)
	profile.starter_prompt_suffix = BRIDGE_ROLLOVER_RESTART_PROMPT_LINE
	rolled := agent_runtime.render_starter_prompt_for_agent(profile, "", "tok", "inst_x")
	testing.expect(t, strings.has_prefix(rolled, plain), "line is appended after the normal prompt")
	testing.expect(t, strings.has_suffix(rolled, "\n\n" + BRIDGE_ROLLOVER_RESTART_PROMPT_LINE), rolled)
	testing.expect_value(t, BRIDGE_ROLLOVER_RESTART_PROMPT_LINE, "Your context was rolled over. Run ./bin/ham-ctl chat read first and read your previous_context message, then ./bin/ham-ctl lease next if you held a task.")

	// Through the bridge argv builder: only while the rollover restart is in flight.
	roll_begin()
	id := "inst_test_roll_prompt"
	defer roll_end(id)
	bp := Bridge_Provider_Profile{command = []string{"claude"}, model_flag = "--model", prompt_flags = []string{"-p"}, starter_prompt = "Hello."}
	argv_has_line :: proc(bp: Bridge_Provider_Profile, id: string) -> bool {
		argv := bridge_runtime_agent_argv_for_profile(bp, "opus", "tok", id)
		for a in argv do if strings.contains(a, "Your context was rolled over") do return true
		return false
	}
	testing.expect(t, !argv_has_line(bp, id))
	roll_event(id, 85, true, 1)
	_, _ = roll_self_send(id, "h")
	testing.expect(t, !argv_has_line(bp, id), "not before the restart is requested")
	roll_event(id, 85, true, 2)
	testing.expect(t, argv_has_line(bp, id), "the rollover relaunch carries the line")
	actions, _ := bridge_rollover_decide_start_success(id, 3)
	bridge_rollover_run(actions)
	testing.expect(t, !argv_has_line(bp, id), "later launches do not")
}

@(test)
test_rollover_ingest_stop_triggers_request_and_withholds_idle :: proc(t: ^testing.T) {
	roll_begin()
	id := "inst_test_roll_ingest"
	defer roll_end(id)
	bridge_runtime_mark_start_success(id)
	rec := Bridge_Local_Agent_Token_Record{agent_instance_id = id, instance_token = "itok", role = .Agent}
	now := bridge_runtime_now_ms()
	ingest :: proc(t: ^testing.T, rec: Bridge_Local_Agent_Token_Record, raw: string, now: i64) {
		res := bridge_ext_ingest(rec, raw, now)
		defer bridge_ext_ingest_result_destroy(&res)
		testing.expect_value(t, res.accepted, 1)
	}
	head := `{"schema":"ham.ext.v1","provider":"claude","ext_version":"0.1.0","ts":"2026-11-02T06:00:00Z","session_id":"sess-roll",`
	// 170000 / 200000 (default window) = 85% on a tool.end mid-turn: pending.
	ingest(t, rec, strings.concatenate({head, `"event":"tool.end","tool":{"name":"Read","use_id":"tu_1"},"usage":{"context_tokens":170000,"source":"claude_transcript"}}`}, context.temp_allocator), now)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Pending)
	testing.expect_value(t, len(roll_rec.requests), 0)
	// A subagent's idle is not the main agent's Stop.
	ingest(t, rec, strings.concatenate({head, `"event":"activity","agent":{"id":"sub-1"},"payload":{"state":"idle"}}`}, context.temp_allocator), now + 1)
	testing.expect_value(t, len(roll_rec.requests), 0)
	// Main Stop (activity idle): request typed, and the idle is reported active.
	ingest(t, rec, strings.concatenate({head, `"event":"activity","payload":{"state":"idle"}}`}, context.temp_allocator), now + 2)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Requested)
	testing.expect_value(t, len(roll_rec.requests), 1)
	inst, ok := bridge_runtime_instance_snapshot(id)
	testing.expect(t, ok)
	testing.expect_value(t, inst.activity_status, "active")

	// The self-send through the real agent method handler is persisted, not relayed.
	resp := bridge_local_handle_agent_method("req_9", "agent.chat.send", strings.concatenate({`{"to":"`, id, `","body":"handoff"}`}, context.temp_allocator), rec)
	testing.expect(t, strings.contains(resp, "msg_pctx_1"), resp)
	testing.expect_value(t, len(roll_rec.persists), 1)

	// Restart on the next main idle; start-success resets the token counters.
	ingest(t, rec, strings.concatenate({head, `"event":"activity","payload":{"state":"idle"}}`}, context.temp_allocator), now + 3)
	testing.expect_value(t, len(roll_rec.restarts), 1)
	bridge_rollover_on_start_success(id)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Normal)
	_, _, pct := bridge_ext_context_window_for(id)
	testing.expect_value(t, pct, -1)
}

// Antigravity-style stream: tool.end with metrics only, no usage block. The
// estimate (x1.5) drives the state machine to Pending at >= 70% of 200K.
@(test)
test_rollover_pending_from_estimate_only_stream :: proc(t: ^testing.T) {
	roll_begin()
	id := "inst_test_roll_estimate"
	defer roll_end(id)
	bridge_runtime_mark_start_success(id)
	now := bridge_runtime_now_ms()
	ev :: proc(est: string) -> string {
		return strings.concatenate({`{"schema":"ham.ext.v1","provider":"antigravity","ext_version":"0.1.0","event":"tool.end","ts":"2026-11-02T06:00:00Z","session_id":"s","tool":{"name":"Read","use_id":"tu"},"metrics":{"input_bytes":1,"response_bytes":1,"est_tokens":`, est, `}}`}, context.temp_allocator)
	}
	for raw in ([]string{ev("50000"), ev("30000")}) { // 80K * 1.5 = 120K = 60%
		res := bridge_ext_ingest(Bridge_Local_Agent_Token_Record{agent_instance_id = id, instance_token = "tok_test", role = .Agent}, raw, now)
		bridge_ext_ingest_result_destroy(&res)
	}
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Normal)
	res := bridge_ext_ingest(Bridge_Local_Agent_Token_Record{agent_instance_id = id, instance_token = "tok_test", role = .Agent}, ev("15000"), now + 1) // 95K*1.5 = 142.5K = 71%
	bridge_ext_ingest_result_destroy(&res)
	_, _, pct := bridge_ext_context_window_for(id)
	testing.expect(t, pct >= 70, "estimate pct >= 70")
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Pending)
}

// pane_diff idle (no extension, e.g. Pi) drives Pending -> Requested -> restart.
@(test)
test_rollover_pane_diff_idle_advances_rollover :: proc(t: ^testing.T) {
	roll_begin()
	id := "inst_test_roll_pane"
	defer roll_end(id)
	now := bridge_runtime_now_ms()
	roll_event(id, 85, false, now)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Pending)
	bridge_rollover_on_activity(id, "working", "pane_diff", now + 1)
	testing.expect_value(t, len(roll_rec.requests), 0)
	// Only pane_diff is handled here; other sources go through their own path.
	bridge_rollover_on_activity(id, "idle", "wrapper", now + 2)
	testing.expect_value(t, len(roll_rec.requests), 0)
	bridge_rollover_on_activity(id, "idle", "pane_diff", now + 3)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Requested)
	testing.expect_value(t, len(roll_rec.requests), 1)

	rec := Bridge_Local_Agent_Token_Record{agent_instance_id = id, instance_token = "itok", role = .Agent}
	resp := bridge_local_handle_agent_method("req_p", "agent.chat.send", strings.concatenate({`{"to":"`, id, `","body":"handoff"}`}, context.temp_allocator), rec)
	testing.expect(t, strings.contains(resp, "msg_pctx_1"), resp)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Restarting)
	bridge_rollover_on_activity(id, "idle", "pane_diff", now + 4)
	testing.expect_value(t, len(roll_rec.restarts), 1)
}

// waiting_user / waiting_approval are blocked prompts (the presentation layer
// maps them to idle), so they must never deliver the handoff or restart.
@(test)
test_rollover_pane_diff_waiting_is_not_idle :: proc(t: ^testing.T) {
	roll_begin()
	id := "inst_test_roll_pane_wait"
	defer roll_end(id)
	now := bridge_runtime_now_ms()
	roll_event(id, 85, false, now)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Pending)
	bridge_rollover_on_activity(id, "waiting_user", "pane_diff", now + 1)
	bridge_rollover_on_activity(id, "waiting_approval", "pane_diff", now + 2)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Pending)
	testing.expect_value(t, len(roll_rec.requests), 0)
	bridge_rollover_on_activity(id, "idle", "pane_diff", now + 3)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Requested)
	testing.expect_value(t, len(roll_rec.requests), 1)

	rec := Bridge_Local_Agent_Token_Record{agent_instance_id = id, instance_token = "itok", role = .Agent}
	_ = bridge_local_handle_agent_method("req_w", "agent.chat.send", strings.concatenate({`{"to":"`, id, `","body":"handoff"}`}, context.temp_allocator), rec)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Restarting)
	bridge_rollover_on_activity(id, "waiting_user", "pane_diff", now + 4)
	testing.expect_value(t, len(roll_rec.restarts), 0)
	bridge_rollover_on_activity(id, "idle", "pane_diff", now + 5)
	testing.expect_value(t, len(roll_rec.restarts), 1)
}

// ext + pane_diff both reporting idle in one tick yield a single request/restart.
@(test)
test_rollover_duplicate_idle_from_two_sources_acts_once :: proc(t: ^testing.T) {
	roll_begin()
	id := "inst_test_roll_dup"
	defer roll_end(id)
	now := bridge_runtime_now_ms()
	roll_event(id, 85, false, now)
	bridge_rollover_on_ext_event(id, true, now + 1)
	bridge_rollover_on_activity(id, "idle", "pane_diff", now + 1)
	testing.expect_value(t, len(roll_rec.requests), 1)

	rec := Bridge_Local_Agent_Token_Record{agent_instance_id = id, instance_token = "itok", role = .Agent}
	_ = bridge_local_handle_agent_method("req_d", "agent.chat.send", strings.concatenate({`{"to":"`, id, `","body":"handoff"}`}, context.temp_allocator), rec)
	bridge_rollover_on_activity(id, "idle", "pane_diff", now + 2)
	bridge_rollover_on_ext_event(id, true, now + 2)
	bridge_rollover_on_activity(id, "idle", "pane_diff", now + 2)
	testing.expect_value(t, len(roll_rec.restarts), 1)
	testing.expect_value(t, len(roll_rec.requests), 1)
}

// An idle withheld from pane_diff during a rollover is re-reported with its
// source once the rollover ends without a restart.
@(test)
test_rollover_pane_diff_idle_withheld_then_rereported :: proc(t: ^testing.T) {
	roll_begin()
	id := "inst_test_roll_pane_withheld"
	defer roll_end(id)
	now := bridge_runtime_now_ms()
	roll_event(id, 85, true, now) // Pending -> Requested
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Requested)
	testing.expect_value(t, bridge_rollover_filter_activity(id, "idle", "pane_diff"), "active")
	// Request times out twice -> alert, finish; the withheld idle is re-reported.
	roll_tick(now + 10 * 60 * 1000)
	roll_tick(now + 20 * 60 * 1000)
	testing.expect_value(t, bridge_rollover_phase_of(id), Bridge_Rollover_Phase.Normal)
	testing.expect_value(t, len(roll_rec.idles), 1)
	testing.expect(t, strings.has_suffix(roll_rec.idles[0], "|pane_diff"), roll_rec.idles[0])
}
