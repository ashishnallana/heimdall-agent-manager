package hub_startup_blocked_projection_test

// AE-5 hub-side unit test: the runtime->startup projection and the
// active-but-not-ready classification for the "blocked" runtime state, plus
// explicit guards that the normal starting->ready path is unchanged.
//
// Build/run:
//   odin build tests/hub_startup_blocked_projection_test.odin -file \
//     -collection:odin_test=src -out:/tmp/hub_ae5 && /tmp/hub_ae5

import "core:fmt"
import "core:os"
import "core:testing"
import agent "odin_test:hub/service/agent"
import domain "odin_test:hub/domain"

@(test)
test_hub_startup_blocked_projection :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	// (1) blocked -> startup_blocked, active-but-not-ready, no terminal side effects.
	blocked := domain.Agent_Instance{
		agent_instance_id = "inst_blk",
		runtime_status = "blocked",
		startup_status = "starting",
		current_task_id = "task_x",
		current_task_role = .Work,
	}
	agent.apply_runtime_startup_projection(&blocked, "2026-09-04T00:00:00Z")
	check(blocked.startup_status == "startup_blocked", "blocked runtime must project to startup_status startup_blocked")
	check(blocked.stopped_at == "", "blocked must NOT set stopped_at (it is not terminal)")
	check(blocked.current_task_id == "task_x" && blocked.current_task_role == .Work, "blocked must NOT clear the current task focus")
	check(agent.runtime_expected_active("blocked"), "blocked must be treated as active (live, not reaped)")

	// (2) Normal happy path stays intact: running -> ready, and it is active.
	running := domain.Agent_Instance{agent_instance_id = "inst_run", runtime_status = "running", startup_status = "starting"}
	agent.apply_runtime_startup_projection(&running, "2026-09-04T00:00:00Z")
	check(running.startup_status == "ready", "running must still project to ready (no AE-5 regression)")
	check(running.stopped_at == "", "running must not set stopped_at")
	check(agent.runtime_expected_active("running"), "running must remain active")

	// (3) starting -> starting, active (the pre-ready normal state).
	starting := domain.Agent_Instance{agent_instance_id = "inst_st", runtime_status = "starting", startup_status = "ready"}
	agent.apply_runtime_startup_projection(&starting, "2026-09-04T00:00:00Z")
	check(starting.startup_status == "starting", "starting must project to starting")
	check(agent.runtime_expected_active("starting"), "starting must remain active")

	// (4) Terminal states are unchanged and are NOT active.
	failed := domain.Agent_Instance{agent_instance_id = "inst_f", runtime_status = "failed", startup_status = "starting", current_task_id = "t"}
	agent.apply_runtime_startup_projection(&failed, "2026-09-04T00:00:00Z")
	check(failed.startup_status == "startup_failed", "failed must project to startup_failed")
	check(failed.stopped_at == "2026-09-04T00:00:00Z", "failed must set stopped_at")
	check(failed.current_task_id == "", "failed must clear current task focus")
	check(!agent.runtime_expected_active("failed"), "failed must NOT be active")
	check(!agent.runtime_expected_active("stopped"), "stopped must NOT be active")
	check(!agent.runtime_expected_active("unreachable"), "unreachable must NOT be active")

	fmt.println("PASS: hub AE-5 startup_blocked projection + expected_active")
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln("FAIL:", message); os.exit(1) }
