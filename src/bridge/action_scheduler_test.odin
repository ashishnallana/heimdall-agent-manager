package main

import "core:strings"
import "core:testing"
import "core:time/timezone"

NY_TZIF :: #load("testdata/America_New_York.tzif")

@(test)
test_action_scheduler_parse_interval :: proc(t: ^testing.T) {
	testing.expect(t, action_scheduler_parse_interval_seconds("60s") == 60, "60s should be 60")
	testing.expect(t, action_scheduler_parse_interval_seconds("30s") == 30, "30s should be 30")
	testing.expect(t, action_scheduler_parse_interval_seconds("5m") == 300, "5m should be 300")
	testing.expect(t, action_scheduler_parse_interval_seconds("2h") == 7200, "2h should be 7200")
	testing.expect(t, action_scheduler_parse_interval_seconds("1d") == 86400, "1d should be 86400")
	testing.expect(t, action_scheduler_parse_interval_seconds("90") == 90, "bare 90 should be 90")
	testing.expect(t, action_scheduler_parse_interval_seconds("") == 0, "empty should be 0")
	testing.expect(t, action_scheduler_parse_interval_seconds("abc") == 0, "abc should be 0")
	testing.expect(t, action_scheduler_parse_interval_seconds("-10s") == 0, "negative should be 0")
}

@(test)
test_action_scheduler_parse_rfc3339 :: proc(t: ^testing.T) {
	ms, ok := action_scheduler_parse_rfc3339_ms("1970-01-01T00:00:00Z")
	testing.expect(t, ok, "parse unix epoch ok")
	testing.expect(t, ms == 0, "unix epoch should be 0 ms")

	ms2, ok2 := action_scheduler_parse_rfc3339_ms("2026-01-01T00:00:00Z")
	testing.expect(t, ok2, "parse 2026 ok")
	testing.expect(t, ms2 == 1_767_225_600_000, "2026-01-01 should be 1_767_225_600_000 ms")

	_, ok3 := action_scheduler_parse_rfc3339_ms("invalid")
	testing.expect(t, !ok3, "invalid format should fail")

	_, ok4 := action_scheduler_parse_rfc3339_ms("2026-13-01T00:00:00Z")
	testing.expect(t, !ok4, "month 13 should fail")

	formatted := action_scheduler_format_rfc3339_utc(ms2)
	testing.expect(t, formatted == "2026-01-01T00:00:00Z", "format matches original timestamp")

	ms5, ok5 := action_scheduler_parse_rfc3339_ms("2026-12-24T15:30:45Z")
	testing.expect(t, ok5 && ms5 == 1_798_126_245_000, "non-midnight timestamp parses to exact ms")
	testing.expect(t, action_scheduler_format_rfc3339_utc(ms5) == "2026-12-24T15:30:45Z", "non-midnight timestamp round-trips")

	ms6, ok6 := action_scheduler_parse_rfc3339_ms("  1970-01-01T00:00:00Z ")
	testing.expect(t, ok6 && ms6 == 0, "surrounding whitespace is trimmed")
}

@(test)
test_action_scheduler_cron_evaluator :: proc(t: ^testing.T) {
	// 2026-12-24 is Thursday.
	days_dec24 := action_scheduler_days_from_civil(2026, 12, 24)
	after_ms := (i64(days_dec24) * 86400 + 15 * 3600) * 1000 // 15:00 UTC (10:00 EST)

	ny, ny_ok := timezone.region_load_from_buffer(NY_TZIF, "America/New_York")
	testing.expect_value(t, ny_ok, true)
	if !ny_ok do return
	defer timezone.region_destroy(ny)

	// Case 1: Normal next run on Friday Dec 25 at 09:00 EST (14:00 UTC)
	next1, ok1 := action_scheduler_eval_next_cron_slot_region("0 9 * * 1-5", ny, "[]", 0, 0, after_ms)
	testing.expect(t, ok1, "cron eval ok")
	testing.expect(t, action_scheduler_format_rfc3339_utc(next1) == "2026-12-25T14:00:00Z", "next run is Friday 09:00 EST")

	// Case 2: Holiday blackout on Friday Dec 25 -> skips weekend, lands on Monday Dec 28 09:00 EST (14:00 UTC)
	next2, ok2 := action_scheduler_eval_next_cron_slot_region("0 9 * * 1-5", ny, "[\"2026-12-25\"]", 0, 0, after_ms)
	testing.expect(t, ok2, "cron eval with blackout ok")
	testing.expect(t, action_scheduler_format_rfc3339_utc(next2) == "2026-12-28T14:00:00Z", "next run skips Friday + weekend to Monday 09:00 EST")

	// Case 3: Blackout on both Friday Dec 25 AND Monday Dec 28 -> skips to Tuesday Dec 29 09:00 EST (14:00 UTC)
	next3, ok3 := action_scheduler_eval_next_cron_slot_region("0 9 * * 1-5", ny, "[\"2026-12-25\",\"2026-12-28\"]", 0, 0, after_ms)
	testing.expect(t, ok3, "cron eval with multi-blackout ok")
	testing.expect(t, action_scheduler_format_rfc3339_utc(next3) == "2026-12-29T14:00:00Z", "next run skips to Tuesday 09:00 EST")

	// Case 4: Active until window expired before next slot -> returns ok=false
	until_ms := (i64(days_dec24) * 86400 + 18 * 3600) * 1000 // expires Dec 24 18:00 UTC
	_, ok4 := action_scheduler_eval_next_cron_slot_region("0 9 * * 1-5", ny, "[]", 0, until_ms, after_ms)
	testing.expect(t, !ok4, "expired active_until should return ok=false")

	// Case 5: Active from window in future -> first slot after active_from
	from_days := action_scheduler_days_from_civil(2027, 1, 1)
	active_from_ms := (i64(from_days) * 86400) * 1000 // 2027-01-01 is Friday
	next5, ok5 := action_scheduler_eval_next_cron_slot("0 9 * * 1-5", "UTC", "[]", active_from_ms, 0, after_ms)
	testing.expect(t, ok5, "active_from in future ok")
	testing.expect(t, action_scheduler_format_rfc3339_utc(next5) == "2027-01-01T09:00:00Z", "first slot is 2027-01-01 09:00 UTC")
}

@(test)
test_action_scheduler_can_claim :: proc(t: ^testing.T) {
	now := i64(100_000)
	item := Action_Queue_Item{
		id = "act_1",
		target_instance_id = "inst_1",
		target_run_at_ms = 90_000,
		state = "active",
		in_flight = false,
		leased_at_ms = 0,
	}

	// 1. Due and active -> can claim
	testing.expect(t, action_scheduler_can_claim(item, now), "active due action can be claimed")

	// 2. Not due yet -> cannot claim
	item.target_run_at_ms = 110_000
	testing.expect(t, !action_scheduler_can_claim(item, now), "future action cannot be claimed")
	item.target_run_at_ms = 90_000

	// 3. Completed -> cannot claim
	item.state = "completed"
	testing.expect(t, !action_scheduler_can_claim(item, now), "completed action cannot be claimed")
	item.state = "active"

	// 4. In flight within lease window -> cannot claim
	item.in_flight = true
	item.leased_at_ms = now - 10_000
	testing.expect(t, !action_scheduler_can_claim(item, now, 60_000), "action in-flight within lease window cannot be claimed")

	// 5. In flight with expired lease -> lease recovery allows claim
	item.leased_at_ms = now - 70_000
	testing.expect(t, action_scheduler_can_claim(item, now, 60_000), "action with expired lease can be claimed")

	// 6. Lease age exactly equal to the window -> claimable
	item.leased_at_ms = now - 60_000
	testing.expect(t, action_scheduler_can_claim(item, now, 60_000), "lease aged exactly the window can be claimed")

	// 7. In flight with no recorded lease time -> not claimable
	item.leased_at_ms = 0
	testing.expect(t, !action_scheduler_can_claim(item, now, 60_000), "in-flight action without leased_at cannot be claimed")
	item.in_flight = false

	// 8. Target exactly now -> claimable
	item.target_run_at_ms = now
	testing.expect(t, action_scheduler_can_claim(item, now), "action targeted exactly now can be claimed")

	// 9. Unset target -> not claimable
	item.target_run_at_ms = 0
	testing.expect(t, !action_scheduler_can_claim(item, now), "action with no target time cannot be claimed")
}

@(test)
test_action_scheduler_claim_and_recovery :: proc(t: ^testing.T) {
	now := i64(200_000)
	// state is a heap-owned field (claim/recover free+clone it), so clone the
	// initial value here just as bridge_action_scheduler_sync does for real items.
	item := Action_Queue_Item{
		id = "act_2",
		target_instance_id = "inst_1",
		target_run_at_ms = 150_000,
		state = strings.clone("active"),
		in_flight = false,
		leased_at_ms = 0,
	}
	defer delete(item.state)

	// Claim
	action_scheduler_claim(&item, now)
	testing.expect(t, item.in_flight == true, "item must be in_flight after claim")
	testing.expect(t, item.state == "in_flight", "item state must be in_flight after claim")
	testing.expect(t, item.leased_at_ms == now, "item leased_at_ms must be now")

	// Attempt recover before window -> false
	recovered_early := action_scheduler_recover_lease(&item, now + 30_000, 60_000)
	testing.expect(t, !recovered_early, "should not recover early")
	testing.expect(t, item.in_flight == true, "still in_flight")

	// Attempt recover after window -> true and state reset to active
	recovered := action_scheduler_recover_lease(&item, now + 70_000, 60_000)
	testing.expect(t, recovered, "should recover expired lease")
	testing.expect(t, item.in_flight == false, "in_flight must be false after recovery")
	testing.expect(t, item.state == "active", "state must be active after recovery")
}

@(test)
test_action_scheduler_interval_advance :: proc(t: ^testing.T) {
	target := i64(1_000_000)

	// 1. One-time action (interval_seconds = 0) -> completed
	next1, completed1 := action_scheduler_advance_interval_ms(target, 0, 1_005_000)
	testing.expect(t, completed1, "one-time action must be completed")
	testing.expect(t, next1 == target, "target_run_at unchanged on completion")

	// 2. Normal recurring advance (interval = 60s)
	next2, completed2 := action_scheduler_advance_interval_ms(target, 60, 1_000_500)
	testing.expect(t, !completed2, "recurring action must not be completed")
	testing.expect(t, next2 == 1_060_000, "next run must advance by 60s")

	// 3. Missed intervals resync
	next3, completed3 := action_scheduler_advance_interval_ms(target, 60, 1_150_000)
	testing.expect(t, !completed3, "recurring action must not be completed")
	testing.expect(t, next3 == 1_180_000, "missed intervals must resync to next future slot (1_180_000)")
}

// REQ-SCHED-2 + reuse bridge/project filter (SCOPE ADDENDUM): pure decision helpers.

@(test)
test_action_scheduler_candidate_matches :: proc(t: ^testing.T) {
	// Empty targets impose no filter (backward-compat).
	testing.expect(t, action_scheduler_candidate_matches("brgA", "projA", "", ""), "no target -> match anything")
	// Bridge filter only when set.
	testing.expect(t, action_scheduler_candidate_matches("brgA", "projA", "brgA", ""), "same bridge, no project filter -> match")
	testing.expect(t, !action_scheduler_candidate_matches("brgB", "projA", "brgA", ""), "different bridge -> no match")
	// Project filter only when set.
	testing.expect(t, action_scheduler_candidate_matches("brgA", "projA", "", "projA"), "same project, no bridge filter -> match")
	testing.expect(t, !action_scheduler_candidate_matches("brgA", "projB", "", "projA"), "different project -> no match")
	// Both must match when both set.
	testing.expect(t, action_scheduler_candidate_matches("brgA", "projA", "brgA", "projA"), "bridge+project both match")
	testing.expect(t, !action_scheduler_candidate_matches("brgA", "projB", "brgA", "projA"), "bridge matches but project differs -> no match")
}

@(test)
test_action_scheduler_should_reuse :: proc(t: ^testing.T) {
	// A live instance of the agent-id on the action's target bridge/project.
	live_match := []Instance_Candidate{
		{id = "inst_live", bridge_id = "brgA", project_id = "projA", live = true},
	}

	// reuse strategy + live matching instance -> REUSED (no new instance).
	id, ok := action_scheduler_should_reuse("reuse", "brgA", "projA", live_match)
	testing.expect(t, ok && id == "inst_live", "reuse strategy reuses the live matching instance")

	// fresh_per_run + the SAME live matching instance -> NOT reused (forces a fresh create).
	_, ok_fresh := action_scheduler_should_reuse("fresh_per_run", "brgA", "projA", live_match)
	testing.expect(t, !ok_fresh, "fresh_per_run never reuses -> a new instance is created")

	// reuse + live instance on a DIFFERENT bridge -> NOT reused (bug fix).
	diff_bridge := []Instance_Candidate{
		{id = "inst_other_bridge", bridge_id = "brgB", project_id = "projA", live = true},
	}
	_, ok_db := action_scheduler_should_reuse("reuse", "brgA", "projA", diff_bridge)
	testing.expect(t, !ok_db, "reuse must not reuse an instance on a different bridge")

	// reuse + live instance in a DIFFERENT project -> NOT reused (bug fix).
	diff_project := []Instance_Candidate{
		{id = "inst_other_project", bridge_id = "brgA", project_id = "projB", live = true},
	}
	_, ok_dp := action_scheduler_should_reuse("reuse", "brgA", "projA", diff_project)
	testing.expect(t, !ok_dp, "reuse must not reuse an instance in a different project")

	// reuse + only a STOPPED (not live) matching instance -> not reused here (wake handles it).
	stopped := []Instance_Candidate{
		{id = "inst_stopped", bridge_id = "brgA", project_id = "projA", live = false},
	}
	_, ok_stopped := action_scheduler_should_reuse("reuse", "brgA", "projA", stopped)
	testing.expect(t, !ok_stopped, "reuse only reuses LIVE instances")

	// reuse + mixed candidates: first live matching instance wins; stopped/other-bridge skipped.
	mixed := []Instance_Candidate{
		{id = "inst_stop", bridge_id = "brgA", project_id = "projA", live = false},
		{id = "inst_b", bridge_id = "brgB", project_id = "projA", live = true},
		{id = "inst_match", bridge_id = "brgA", project_id = "projA", live = true},
		{id = "inst_match2", bridge_id = "brgA", project_id = "projA", live = true},
	}
	id_mixed, ok_mixed := action_scheduler_should_reuse("reuse", "brgA", "projA", mixed)
	testing.expect(t, ok_mixed && id_mixed == "inst_match", "first live matching candidate is reused")

	// reuse + empty targets (legacy action) + a live instance anywhere -> reused (backward-compat).
	id_legacy, ok_legacy := action_scheduler_should_reuse("reuse", "", "", live_match)
	testing.expect(t, ok_legacy && id_legacy == "inst_live", "legacy (no bridge/project target) still reuses a live instance")
}

@(test)
test_action_scheduler_reap_target :: proc(t: ^testing.T) {
	// fresh_per_run with a prior instance different from the new one -> reap the prior.
	reap, do_reap := action_scheduler_reap_target("fresh_per_run", "inst_prev", "inst_new")
	testing.expect(t, do_reap && reap == "inst_prev", "fresh_per_run reaps the previous instance after the new one is ready")

	// fresh_per_run but no prior instance -> nothing to reap (first fire).
	_, do_reap_first := action_scheduler_reap_target("fresh_per_run", "", "inst_new")
	testing.expect(t, !do_reap_first, "first fresh_per_run fire has no prior instance to reap")

	// fresh_per_run but prior == new (shouldn't happen) -> never reap the live one.
	_, do_reap_same := action_scheduler_reap_target("fresh_per_run", "inst_new", "inst_new")
	testing.expect(t, !do_reap_same, "never reap the newly minted instance")

	// reuse strategy never reaps, even with a prior value present.
	_, do_reap_reuse := action_scheduler_reap_target("reuse", "inst_prev", "inst_new")
	testing.expect(t, !do_reap_reuse, "reuse strategy never reaps")
}
