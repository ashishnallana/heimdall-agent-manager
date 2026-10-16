package agent

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// REQ-ERR-PROTO-A: the hub acts on a failed instance's error class.

@(private = "file")
failed_at :: "2026-10-15T12:00:00Z"

@(private = "file")
failed_instance :: proc(last_error_json: string) -> domain.Agent_Instance {
	return domain.Agent_Instance{runtime_status = "failed", stopped_at = failed_at, last_error_json = last_error_json}
}

@(test)
test_err_proto_disposition_per_class :: proc(t: ^testing.T) {
	failed_ms, _ := platform.rfc3339_to_unix_ms(failed_at)

	testing.expect_value(t, failed_instance_disposition(domain.Agent_Instance{runtime_status = "running"}, failed_ms), Failed_Instance_Disposition.Not_Failed)
	testing.expect_value(t, failed_instance_disposition(domain.Agent_Instance{runtime_status = "terminated"}, failed_ms), Failed_Instance_Disposition.Dead)
	// No typed error: the old behaviour (dead, replaceable).
	testing.expect_value(t, failed_instance_disposition(failed_instance(""), failed_ms), Failed_Instance_Disposition.Dead)

	fatal := failed_instance(`{"code":"internal_error","class":"fatal","cause":"agent_launch_failed","message":"","attempt":1}`)
	// Fatal: the same launch would fail again, so it is neither re-woken nor replaced.
	testing.expect_value(t, failed_instance_disposition(fatal, failed_ms + 10_000_000), Failed_Instance_Disposition.Hold)

	// Recoverable never re-wakes on its own, however long it waits.
	recoverable := failed_instance(`{"code":"provider_unavailable","class":"recoverable","cause":"provider_not_logged_in","message":"","attempt":1}`)
	testing.expect_value(t, failed_instance_disposition(recoverable, failed_ms + 10_000_000), Failed_Instance_Disposition.Hold)

	// Retriable backs off exponentially: attempt 3 waits 60s * 4 = 240s.
	retriable := failed_instance(`{"code":"bridge_busy","class":"retriable","cause":"pty_host_unreachable","message":"","attempt":3}`)
	testing.expect_value(t, failed_instance_disposition(retriable, failed_ms + 239_000), Failed_Instance_Disposition.Hold)
	testing.expect_value(t, failed_instance_disposition(retriable, failed_ms + 240_000), Failed_Instance_Disposition.Retry_Now)
}

@(test)
test_err_proto_retry_delay_is_capped_and_floored :: proc(t: ^testing.T) {
	testing.expect_value(t, instance_retry_delay_ms(1), i64(60_000))
	testing.expect_value(t, instance_retry_delay_ms(2), i64(120_000))
	testing.expect_value(t, instance_retry_delay_ms(50), i64(INSTANCE_RETRY_MAX_MS))
	testing.expect_value(t, instance_retry_delay_ms(1, 90_000), i64(90_000))
}

@(test)
test_err_proto_last_error_record_counts_attempts :: proc(t: ^testing.T) {
	err := `{"code":"bridge_busy","class":"retriable","cause":"pty_host_unreachable","message":"daemon unavailable"}`
	first := instance_last_error_record("", err)
	defer delete(first)
	testing.expect(t, strings.contains(first, `"attempt":1`), first)
	second := instance_last_error_record(first, err)
	defer delete(second)
	testing.expect(t, strings.contains(second, `"attempt":2`), second)
	werr, found := instance_last_error(domain.Agent_Instance{last_error_json = second})
	testing.expect(t, found)
	testing.expect_value(t, werr.class, contracts.Bridge_Error_Class.retriable)
	testing.expect_value(t, werr.cause, "pty_host_unreachable")

	garbage := instance_last_error_record("", `{"no":"code"}`)
	defer delete(garbage)
	testing.expect_value(t, garbage, "")
}

@(private = "file")
Lf_Repo :: struct {
	inst: domain.Agent_Instance,
}

@(private = "file")
lf_clone :: proc(i: domain.Agent_Instance) -> domain.Agent_Instance {
	c := i
	c.agent_instance_id = strings.clone(i.agent_instance_id)
	c.owner_user_id     = domain.User_ID(strings.clone(string(i.owner_user_id)))
	c.bridge_id         = strings.clone(i.bridge_id)
	c.runtime_status    = strings.clone(i.runtime_status)
	c.startup_status    = strings.clone(i.startup_status)
	c.activity_status   = strings.clone(i.activity_status)
	c.last_error_json   = strings.clone(i.last_error_json)
	c.last_seen_at      = strings.clone(i.last_seen_at)
	c.updated_at        = strings.clone(i.updated_at)
	c.stopped_at        = strings.clone(i.stopped_at)
	c.launch_epoch      = ""
	c.agent_id          = ""
	c.created_at        = ""
	return c
}

@(test)
test_err_proto_status_report_records_and_clears_last_error :: proc(t: ^testing.T) {
	r: Lf_Repo
	r.inst = lf_clone(domain.Agent_Instance{agent_instance_id = "inst_lf", owner_user_id = "owner_a", bridge_id = "brg_1", runtime_status = "starting", startup_status = "starting", activity_status = "idle"})
	defer domain.agent_instance_destroy(&r.inst)
	repo := iface.Agent_Repository{
		ctx = rawptr(&r),
		get_instance = proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
			return lf_clone((^Lf_Repo)(ctx).inst), true, {}
		},
		save_instance = proc(ctx: rawptr, inst: domain.Agent_Instance) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
			r := (^Lf_Repo)(ctx)
			domain.agent_instance_destroy(&r.inst)
			r.inst = lf_clone(inst)
			return inst, true, {}
		},
	}
	clk := platform.Clock{now = proc(ctx: rawptr) -> string { return "2026-10-15T12:00:00Z" }}
	svc: Agent_Service
	svc.agents = &repo
	svc.clock = &clk
	err_json := `{"code":"provider_unavailable","class":"recoverable","cause":"provider_not_logged_in","message":"login"}`

	saved, applied, _ := apply_bridge_status_report(&svc, "brg_1", "inst_lf", 1, "failed", "idle", error_json = err_json)
	testing.expect(t, applied)
	testing.expect(t, strings.contains(saved.last_error_json, `"cause":"provider_not_logged_in"`), saved.last_error_json)
	testing.expect(t, strings.contains(saved.last_error_json, `"attempt":1`), saved.last_error_json)
	domain.agent_instance_destroy(&saved)

	// A retry in flight keeps the failure; a second failure counts as attempt 2.
	saved, _, _ = apply_bridge_status_report(&svc, "brg_1", "inst_lf", 2, "starting", "active")
	testing.expect(t, saved.last_error_json != "", "starting keeps last_error")
	domain.agent_instance_destroy(&saved)
	saved, _, _ = apply_bridge_status_report(&svc, "brg_1", "inst_lf", 3, "failed", "idle", error_json = err_json)
	testing.expect(t, strings.contains(saved.last_error_json, `"attempt":2`), saved.last_error_json)
	domain.agent_instance_destroy(&saved)

	// A successful start clears it.
	saved, _, _ = apply_bridge_status_report(&svc, "brg_1", "inst_lf", 4, "running", "idle")
	testing.expect_value(t, saved.last_error_json, "")
	domain.agent_instance_destroy(&saved)
}

// A failed stop puts the instance back to the status the bridge restored instead of
// leaving it "stopping"; a successful or foreign result changes nothing.
@(test)
test_err_proto_failed_stop_result_restores_status :: proc(t: ^testing.T) {
	r: Lf_Repo
	r.inst = lf_clone(domain.Agent_Instance{agent_instance_id = "inst_lf", owner_user_id = "owner_a", bridge_id = "brg_1", runtime_status = "stopping", startup_status = "running", activity_status = "idle"})
	defer domain.agent_instance_destroy(&r.inst)
	repo := iface.Agent_Repository{
		ctx = rawptr(&r),
		get_instance = proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
			return lf_clone((^Lf_Repo)(ctx).inst), true, {}
		},
		save_instance = proc(ctx: rawptr, inst: domain.Agent_Instance) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
			r := (^Lf_Repo)(ctx)
			domain.agent_instance_destroy(&r.inst)
			r.inst = lf_clone(inst)
			return inst, true, {}
		},
	}
	clk := platform.Clock{now = proc(ctx: rawptr) -> string { return "2026-10-15T12:00:00Z" }}
	svc: Agent_Service
	svc.agents = &repo
	svc.clock = &clk

	failed := `{"type":"command_result","command_id":"cmd_stop_1_inst_lf","ok":false,"error":{"code":"unprocessable_entity","class":"fatal","cause":"stop_failed","message":""},"payload":{"status":"failed","result":{"runtime_status":"running"}}}`
	testing.expect(t, !apply_stop_command_result(&svc, "brg_2", "cmd_stop_1_inst_lf", failed), "another bridge's result is ignored")
	testing.expect_value(t, r.inst.runtime_status, "stopping")
	ok_result := `{"type":"command_result","command_id":"cmd_stop_1_inst_lf","ok":true,"payload":{"status":"succeeded","result":{"runtime_status":"stopped"}}}`
	testing.expect(t, !apply_stop_command_result(&svc, "brg_1", "cmd_stop_1_inst_lf", ok_result), "a successful stop is left to the status report")
	testing.expect_value(t, r.inst.runtime_status, "stopping")

	testing.expect(t, apply_stop_command_result(&svc, "brg_1", "cmd_stop_1_inst_lf", failed))
	testing.expect_value(t, r.inst.runtime_status, "running")

	// No pre-stop snapshot on the bridge (restarted): it reports "unreachable".
	delete(r.inst.runtime_status)
	r.inst.runtime_status = strings.clone("stopping")
	cold := `{"type":"command_result","command_id":"cmd_stop_2_inst_lf","ok":false,"error":{"code":"unprocessable_entity","class":"fatal","cause":"stop_failed","message":""},"payload":{"status":"failed","result":{"runtime_status":"unreachable"}}}`
	testing.expect(t, apply_stop_command_result(&svc, "brg_1", "cmd_stop_2_inst_lf", cold))
	testing.expect_value(t, r.inst.runtime_status, "unreachable")
}
