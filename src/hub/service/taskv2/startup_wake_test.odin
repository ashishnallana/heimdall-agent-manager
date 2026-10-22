package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
startup_wake_grant_generation_is_transactional_and_retries_reuse_it :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "startup_wake")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_startup_wake")
	seed_fleet(fx, chain, "agt_w", capacity = 1)
	previous := seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "running")
	previous.run_count = 7
	previous.startup_status = "ready"
	_, _, _ = iface.agent_save_instance(&fx.agents, previous)
	_ = publish_task(t, fx, chain, "task_startup_wake")
	lease, held := lease_of(fx, "inst_w1")
	if !testing.expect(t, held, "actual matcher grants wake lease") do return
	current, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	testing.expect_value(t, current.run_count, 8)
	testing.expect_value(t, current.startup_status, "starting")
	testing.expect(t, lease.confirmed_at == "", "replacement awaits its own ready hook")
	if !testing.expect(t, len(log.cmds) > 0) do return
	testing.expect(t, strings.contains(log.cmds[len(log.cmds)-1].body_json, `"run_count":8`), "wake carries committed generation")
	// The old callback may arrive after the new grant, even if its save preceded it.
	on_start_success(&fx.svc, previous)
	lease, _ = lease_of(fx, "inst_w1")
	testing.expect(t, lease.confirmed_at == "", "delayed old hook cannot confirm replacement")
	_, stored, err := iface.agent_save_instance(&fx.agents, previous)
	testing.expect(t, !stored && err.code == .Conflict, "stale save cannot roll generation backward")
	// Reconnect, hub boot and unconfirmed timer delivery all reuse effect_wake_lease.
	wake_log_reset(log)
	on_bridge_hello(&fx.svc, "br_1", nil)
	boot(&fx.svc)
	current, _, _ = iface.agent_get_instance(&fx.agents, "inst_w1")
	testing.expect_value(t, current.run_count, 8)
	for cmd in log.cmds do testing.expect(t, strings.contains(cmd.body_json, `"run_count":8`), "delivery retry preserves generation")
	testing.expect(t, len(log.cmds) >= 2, "reconnect and boot re-delivered pending wake")
	on_start_success(&fx.svc, current)
	lease, _ = lease_of(fx, "inst_w1")
	testing.expect(t, lease.confirmed_at != "", "current child confirms pending lease")
	// Confirmed reconnect is only a nudge, never a replacement.
	wake_log_reset(log)
	on_bridge_hello(&fx.svc, "br_1", []string{"inst_w1"})
	current, _, _ = iface.agent_get_instance(&fx.agents, "inst_w1")
	testing.expect_value(t, current.run_count, 8)
	testing.expect(t, !wake_log_has_run(log, "inst_w1"), "live notification has no run effect")
	// A subsequent actual task grant allocates exactly one more generation.
	submit_via_release(t, fx, lease)
	_ = publish_task(t, fx, chain, "task_startup_wake_next")
	current, _, _ = iface.agent_get_instance(&fx.agents, "inst_w1")
	testing.expect_value(t, current.run_count, 9)
}

@(test)
startup_inline_grant_and_rolled_back_wake_preserve_generation :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "startup_inline")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_startup_inline")
	inst := seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "running")
	inst.run_count = 5
	_, _, _ = iface.agent_save_instance(&fx.agents, inst)
	task := publish_task(t, fx, chain, "task_startup_inline")
	deliveries := [2]bool{false, true}
	for is_inline in deliveries {
		u, begun, err := begin_uow(&fx.svc)
		if !testing.expect(t, begun, fmt.tprintf("begin: %s", err.message)) do return
		lease, granted, grant_err := grant_in_uow(&fx.svc, &u, Grant_Request{
			chain = chain, task = task, instance = inst, kind = domain.LEASE_KIND_WORK,
			delivery = domain.LEASE_DELIVERY_INLINE if is_inline else domain.LEASE_DELIVERY_WAKE,
			placement = Placement{bridge_id = "br_1"}, actor = hub_actor(),
		})
		testing.expect(t, granted, fmt.tprintf("grant: %s", grant_err.message))
		_, _ = end_uow(&fx.svc, &u, is_inline && granted)
		current, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
		testing.expect_value(t, current.run_count, 5)
		if is_inline do testing.expect(t, lease.confirmed_at != "", "inline grant is already confirmed")
	}
	testing.expect(t, !wake_log_has_run(log, "inst_w1"), "rollback and inline grant emit no launch")
}

@(test)
startup_pending_wake_is_stopped_when_task_is_cancelled :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "startup_cancel")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_startup_cancel")
	seed_fleet(fx, chain, "agt_w", capacity = 1)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	task := publish_task(t, fx, chain, "task_startup_cancel")
	inst, _, _ := iface.agent_get_instance(&fx.agents, "inst_w1")
	testing.expect(t, instance_is_pending(inst), "wake grant is pending readiness")
	wake_log_reset(log)
	err := cancel_task(&fx.svc, task, Actor{kind = ACTOR_USER, id = "u1"}, "cancel before ready")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect(t, wake_log_has_stop(log, "inst_w1"), "pending replacement is included in stop effect")
	_, held := lease_of(fx, "inst_w1")
	testing.expect(t, !held, "cancelled wake lease is reclaimed")
}
