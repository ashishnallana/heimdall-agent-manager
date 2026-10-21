package taskv2

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// The instance/bridge hooks are called from threads that live on the persistent
// heap (the bridge WS reader, the reaper). Drive each one with a tracking
// allocator standing in for that heap and require that nothing it allocated
// there outlives the call. Temp is the caller's to reset (per frame / pass /
// tick), so it gets its own arena here. Before the hooks had a scratch scope every agent stop/start
// on a workflow chain leaked the chain's tasks, spec and inputs (hundreds of MB
// on a 586-stage workflow).
@(test)
test_instance_hooks_leave_nothing_on_the_caller_heap :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "scratch_leak")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_scratch_leak")
	seed_fleet(fx, chain, "agt_w", capacity = 2)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "running")
	seed_instance(fx, chain, "inst_w2", "agt_w", "br_1", "running")
	_ = publish_task(t, fx, chain, "task_scratch_a")
	_ = publish_task(t, fx, chain, "task_scratch_b")
	_, held1 := lease_of(fx, "inst_w1")
	_, held2 := lease_of(fx, "inst_w2")
	testing.expect(t, held1 && held2, "both workers hold a lease")
	inst1, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")

	expect_no_residue :: proc(t: ^testing.T, what: string, call: proc(fx: ^Fixture, inst: rawptr), fx: ^Fixture, inst: rawptr) {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, runtime.heap_allocator())
		defer mem.tracking_allocator_destroy(&track)
		temp: virtual.Arena
		testing.expect(t, virtual.arena_init_growing(&temp) == nil, "temp arena")
		defer virtual.arena_destroy(&temp)
		{
			context.allocator = mem.tracking_allocator(&track)
			context.temp_allocator = virtual.arena_allocator(&temp)
			call(fx, inst)
		}
		residue := 0
		for _, entry in track.allocation_map do residue += entry.size
		testing.expectf(t, len(track.allocation_map) == 0, "%s left %d allocations (%d bytes) on the caller's heap", what, len(track.allocation_map), residue)
		testing.expectf(t, len(track.bad_free_array) == 0, "%s freed %d pointers it did not own", what, len(track.bad_free_array))
	}

	expect_no_residue(t, "on_start_success", proc(fx: ^Fixture, inst: rawptr) {
		on_start_success(&fx.svc, (^domain.Agent_Instance)(inst)^)
	}, fx, &inst1)
	expect_no_residue(t, "on_instance_activity busy", proc(fx: ^Fixture, _: rawptr) {
		on_instance_activity(&fx.svc, "inst_w1", "busy")
	}, fx, nil)
	expect_no_residue(t, "on_instance_activity idle", proc(fx: ^Fixture, _: rawptr) {
		on_instance_activity(&fx.svc, "inst_w1", "idle")
	}, fx, nil)
	expect_no_residue(t, "on_bridge_hello", proc(fx: ^Fixture, _: rawptr) {
		on_bridge_hello(&fx.svc, "br_1", []string{"inst_w1", "inst_w2"})
	}, fx, nil)
	verify_exit := Verify_Exit{session_id = "sh_x", label = fmt.tprintf("%s%s", VERIFY_LABEL_PREFIX, "task_scratch_a"), owner_user_id = "u1", exit_code = 0, exit_code_set = true}
	expect_no_residue(t, "on_verify_session_exited", proc(fx: ^Fixture, exit: rawptr) {
		on_verify_session_exited(&fx.svc, (^Verify_Exit)(exit)^)
	}, fx, &verify_exit)
	expect_no_residue(t, "on_instance_user_stopped", proc(fx: ^Fixture, _: rawptr) {
		on_instance_user_stopped(&fx.svc, "inst_w2")
	}, fx, nil)
	inst1.runtime_status = "stopped"
	_, _, _ = iface.agent_save_instance(&fx.agents, inst1)
	expect_no_residue(t, "on_instance_terminal", proc(fx: ^Fixture, _: rawptr) {
		on_instance_terminal(&fx.svc, "inst_w1")
	}, fx, nil)
	_, held1 = lease_of(fx, "inst_w1")
	testing.expect(t, !held1, "the hooks still did their work: the dead holder's lease ended")
}
