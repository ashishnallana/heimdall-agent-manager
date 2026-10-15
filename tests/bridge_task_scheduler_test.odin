package bridge_task_scheduler_test

import "core:fmt"
import "core:testing"
import "core:os"
import bridge "odin_test:bridge"

@(test)
test_bridge_task_scheduler_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	test_threshold_mapping()
	test_should_nudge()
	test_observe_and_prune()
	test_cooldown_on_attempt()
	fmt.println("PASS: bridge task scheduler")
}

// Regression: the scheduler used to record last_nudge only on SUCCESSFUL
// delivery. When delivery was a no-op (wrapper push channel missing but the
// instance already live, e.g. right after a relaunch) last_nudge stayed 0 and
// the task was re-nudged every 60s tick, bypassing the 300s cooldown. The fix
// records last_nudge on ATTEMPT. This test simulates the tick's decide->mark
// sequence and asserts the cooldown holds regardless of delivery outcome.
test_cooldown_on_attempt :: proc() {
	bridge.bridge_task_scheduler_reset()
	c := cfg()
	now: i64 = 10_000_000
	// Task became stale (first_seen 400s ago), never nudged.
	fs := bridge.bridge_task_observe("task_x", "in_validation", "inst_rev", now - 400_000)
	check(fs == now - 400_000, "observed stale task")
	last := bridge.bridge_task_last_nudge("task_x", "inst_rev")
	check(bridge.bridge_task_should_nudge(c, "in_validation", fs, last, now), "stale+no-cooldown must nudge")
	// Simulate the fixed tick: mark on ATTEMPT (even though delivery would fail).
	bridge.bridge_task_mark_nudged("task_x", "inst_rev", now)
	// One tick later (60s), the cooldown must suppress a re-nudge.
	last2 := bridge.bridge_task_last_nudge("task_x", "inst_rev")
	check(last2 == now, "cooldown timestamp recorded on attempt")
	check(!bridge.bridge_task_should_nudge(c, "in_validation", fs, last2, now + 60_000), "within cooldown must NOT re-nudge (was the bug)")
	// After the full 300s cooldown, nudging is allowed again.
	check(bridge.bridge_task_should_nudge(c, "in_validation", fs, last2, now + 300_000), "allowed again after cooldown")
}

cfg :: proc() -> bridge.Bridge_Nudge_Config {
	c := bridge.bridge_task_scheduler_default_config()
	c.enabled = true
	c.ready_after_seconds = 300
	c.working_stale_after_seconds = 900
	c.review_after_seconds = 300
	c.cooldown_seconds = 300
	return c
}

test_threshold_mapping :: proc() {
	c := cfg()
	check(bridge.bridge_task_threshold_seconds_cfg(c, "assigned") == 300, "assigned -> ready_after")
	check(bridge.bridge_task_threshold_seconds_cfg(c, "in_progress") == 900, "in_progress -> working_stale")
	check(bridge.bridge_task_threshold_seconds_cfg(c, "in_validation") == 300, "in_validation -> review_after")
	check(bridge.bridge_task_threshold_seconds_cfg(c, "validated_good") == 0, "validated_good has no threshold")
	check(bridge.bridge_task_threshold_seconds_cfg(c, "completed") == 0, "completed has no threshold")
}

test_should_nudge :: proc() {
	c := cfg()
	now: i64 = 10_000_000

	// Disabled short-circuits.
	off := c; off.enabled = false
	check(!bridge.bridge_task_should_nudge(off, "assigned", now - 999_000, 0, now), "disabled must not nudge")

	// Not stale (only 100s since first seen vs 300s threshold).
	check(!bridge.bridge_task_should_nudge(c, "assigned", now - 100_000, 0, now), "fresh must not nudge")

	// Stale, never nudged -> nudge.
	check(bridge.bridge_task_should_nudge(c, "assigned", now - 400_000, 0, now), "stale assigned must nudge")

	// Cooldown active (last nudge 100s ago < 300s).
	check(!bridge.bridge_task_should_nudge(c, "assigned", now - 400_000, now - 100_000, now), "cooldown must suppress")

	// Cooldown expired (last nudge 400s ago).
	check(bridge.bridge_task_should_nudge(c, "assigned", now - 400_000, now - 400_000, now), "allowed after cooldown")

	// No-threshold status never nudges even if very old.
	check(!bridge.bridge_task_should_nudge(c, "validated_good", now - 999_000, 0, now), "no-threshold status must not nudge")

	// first_seen unset -> no nudge.
	check(!bridge.bridge_task_should_nudge(c, "assigned", 0, 0, now), "missing first_seen must not nudge")
}

test_observe_and_prune :: proc() {
	bridge.bridge_task_scheduler_reset()
	now: i64 = 5_000_000

	// First observation sets first_seen = now.
	fs1 := bridge.bridge_task_observe("task_1", "assigned", "inst_a", now)
	check(fs1 == now, "first observation stamps now")

	// Same status later keeps first_seen stable (staleness accrues).
	fs2 := bridge.bridge_task_observe("task_1", "assigned", "inst_a", now + 60_000)
	check(fs2 == now, "same status keeps first_seen stable")

	// Status change resets first_seen and clears nudge state.
	bridge.bridge_task_mark_nudged("task_1", "inst_a", now + 10_000)
	check(bridge.bridge_task_last_nudge("task_1", "inst_a") == now + 10_000, "nudge time recorded")
	fs3 := bridge.bridge_task_observe("task_1", "in_progress", "inst_a", now + 120_000)
	check(fs3 == now + 120_000, "status change resets first_seen")
	check(bridge.bridge_task_last_nudge("task_1", "inst_a") == 0, "status change clears nudge cooldown")

	// Prune removes observations not seen this tick.
	seen := make(map[string]bool); defer delete(seen)
	seen["task_1"] = true
	_ = bridge.bridge_task_observe("task_gone", "assigned", "inst_b", now)
	bridge.bridge_task_prune_unseen(seen)
	// task_gone should be pruned; task_1 retained (observe still works / returns stable).
	fs_keep := bridge.bridge_task_observe("task_1", "in_progress", "inst_a", now + 200_000)
	check(fs_keep == now + 120_000, "retained task keeps its first_seen after prune")
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln("FAIL:", message); os.exit(1) }
