package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import platform "odin_test:hub/platform"

// Instance-level permission mode (composer "Bypass permissions" toggle):
// agent_instances.permission_mode overrides the agent's mode, a reconfiguration
// may change only it, and every launch payload carries the effective mode.

@(private = "file")
Perm_Harness :: struct {
	path:       string,
	conn:       sqlite.Conn,
	agent_impl: sqlite.Agent_Repo_SQLite,
	agents:     iface.Agent_Repository,
	clock:      platform.Clock,
	ids:        platform.ID_Generator,
	service:    Agent_Service,
}

@(private = "file")
PERM_OWNER :: "user_perm"

@(private = "file")
perm_open :: proc(t: ^testing.T, h: ^Perm_Harness, name: string, agent_mode: string) -> bool {
	h.path = fmt.aprintf("%s/.cache/heimdall-tests/%s.db", os.get_env("HOME", context.temp_allocator), name)
	os.remove(h.path)
	conn, ok, err := sqlite.open(h.path)
	if !testing.expectf(t, ok, "open db: %s", err.message) do return false
	h.conn = conn
	mig_ok, mig_err := sqlite.run_migrations(&h.conn)
	if !testing.expectf(t, mig_ok, "migrations: %s", mig_err.message) do return false
	h.agents = sqlite.new_agent_repository(&h.agent_impl, &h.conn)
	h.clock = platform.real_clock()
	h.ids = platform.real_id_generator()
	h.service = new_agent_service(&h.agents, nil, &h.clock, &h.ids)
	_, saved, save_err := iface.agent_save(&h.agents, domain.Agent{agent_id = "agt_perm", owner_user_id = PERM_OWNER, name = "worker", slug = "worker", template_id = domain.TEMPLATE_EMPTY_ID, state = .Active, created_at = "2026-10-22T08:00:00Z", updated_at = "2026-10-22T08:00:00Z", permission_mode = agent_mode})
	if !testing.expect(t, saved, save_err.message) do return false
	_, saved, save_err = iface.agent_save_instance(&h.agents, domain.Agent_Instance{agent_instance_id = "inst_perm", owner_user_id = PERM_OWNER, agent_id = "agt_perm", bridge_id = "brg_perm", provider = "claude", model = "claude-opus-5-5", conversation_id = "chat_perm", runtime_status = "running", created_at = "2026-10-22T08:00:00Z", updated_at = "2026-10-22T08:00:00Z"})
	return testing.expect(t, saved, save_err.message)
}

@(private = "file")
perm_close :: proc(h: ^Perm_Harness) {
	sqlite.close(&h.conn)
	os.remove(h.path)
}

@(private = "file")
perm_user :: proc() -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .Session, user_id = PERM_OWNER}
}

// A permission-only operation: same bridge/project/provider/model, only the
// permission override differs between source and destination.
@(private = "file")
perm_only_op :: proc(key, mode: string) -> domain.Instance_Reconfiguration {
	source := domain.Instance_Configuration{bridge_id = "brg_perm", provider = "claude", model = "claude-opus-5-5"}
	destination := source
	destination.permission_mode = mode
	return domain.Instance_Reconfiguration{operation_id = strings.concatenate({"op_", key}), owner_user_id = PERM_OWNER, agent_instance_id = "inst_perm", conversation_id = "chat_perm", actor_user_id = PERM_OWNER, idempotency_key = key, revision = 1, phase = .Prepared, source = source, destination = destination, stop_command_id = "stop_perm", launch_command_id = "launch_perm", launch_epoch = "epoch_perm", created_at = "2026-10-22T08:01:00Z", updated_at = "2026-10-22T08:01:00Z"}
}

@(test)
test_instance_permission_mode_effective_resolution :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	testing.expect_value(t, domain.effective_permission_mode("", "ask"), domain.AGENT_PERMISSION_MODE_ASK)
	testing.expect_value(t, domain.effective_permission_mode("", "yolo"), domain.AGENT_PERMISSION_MODE_YOLO)
	testing.expect_value(t, domain.effective_permission_mode("", ""), domain.AGENT_PERMISSION_MODE_YOLO)
	testing.expect_value(t, domain.effective_permission_mode("yolo", "ask"), domain.AGENT_PERMISSION_MODE_YOLO)
	testing.expect_value(t, domain.effective_permission_mode("ask", "yolo"), domain.AGENT_PERMISSION_MODE_ASK)
	// An unknown stored override inherits rather than silently forcing yolo.
	testing.expect_value(t, domain.effective_permission_mode("never", "ask"), domain.AGENT_PERMISSION_MODE_ASK)
}

@(test)
test_reconfiguration_permission_mode_validation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	inst := domain.Agent_Instance{permission_mode = "ask"}
	kept, ok, _ := reconfiguration_destination_permission_mode(perm_user(), inst, "")
	testing.expect(t, ok, "omitted permission_mode is valid")
	testing.expect_value(t, kept, domain.AGENT_PERMISSION_MODE_ASK)
	set, set_ok, _ := reconfiguration_destination_permission_mode(perm_user(), inst, " yolo ")
	testing.expect(t, set_ok, "yolo is valid")
	testing.expect_value(t, set, domain.AGENT_PERMISSION_MODE_YOLO)
	for bad in ([]string{"YOLO", "never", "inherit", "bypass"}) {
		_, bad_ok, bad_err := reconfiguration_destination_permission_mode(perm_user(), inst, bad)
		testing.expectf(t, !bad_ok && bad_err.code == .Validation_Failed, "%q must be rejected", bad)
	}
	agent_auth := contracts.Auth_Context{kind = .Instance_Token, user_id = PERM_OWNER, agent_instance_id = "inst_perm"}
	_, agent_ok, agent_err := reconfiguration_destination_permission_mode(agent_auth, inst, "yolo")
	testing.expect(t, !agent_ok && agent_err.code == .Forbidden, "an agent cannot lift its own permission gate")
	// Agents may still reconfigure other fields without touching the mode.
	_, untouched_ok, _ := reconfiguration_destination_permission_mode(agent_auth, inst, "")
	testing.expect(t, untouched_ok, "agent request that omits permission_mode is unaffected")
}

@(test)
test_reconfiguration_permission_only_change_is_accepted_and_invalid_rejected :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	h: Perm_Harness
	if !perm_open(t, &h, "inst_perm_begin", domain.AGENT_PERMISSION_MODE_YOLO) { perm_close(&h); return }
	defer perm_close(&h)

	// Invalid values are rejected by the real entry point before any runtime work.
	base := Reconfigure_Operation_Input{bridge_id = "brg_perm", provider = "claude", model = "claude-opus-5-5", idempotency_key = "key_bad", expected_revision = 0}
	bad := base; bad.permission_mode = "sometimes"
	_, accepted, err := begin_instance_reconfiguration(&h.service, perm_user(), "inst_perm", bad)
	testing.expect(t, !accepted && err.code == .Validation_Failed, "invalid permission_mode rejected")

	// A permission-only destination is a valid operation (the repository accepts
	// it as a full destination equal to the source except for the mode).
	op := perm_only_op("key_ask", domain.AGENT_PERMISSION_MODE_ASK)
	stored, began, begin_err := iface.instance_reconfiguration_begin(&h.agents, op)
	if !testing.expect(t, began, begin_err.message) do return
	domain.instance_reconfiguration_destroy(&stored)

	// Idempotent replay with the same mode returns the original operation; the
	// same key cannot be reused for a different mode.
	same := base; same.idempotency_key = "key_ask"; same.permission_mode = "ask"
	replay, replayed, replay_err := begin_instance_reconfiguration(&h.service, perm_user(), "inst_perm", same)
	testing.expect(t, replayed, replay_err.message)
	testing.expect_value(t, replay.operation_id, "op_key_ask")
	testing.expect_value(t, replay.destination.permission_mode, domain.AGENT_PERMISSION_MODE_ASK)
	domain.instance_reconfiguration_destroy(&replay)
	other := same; other.permission_mode = "yolo"
	_, accepted, err = begin_instance_reconfiguration(&h.service, perm_user(), "inst_perm", other)
	testing.expect(t, !accepted && err.code == .Conflict, "same key with another permission mode conflicts")

	// Stop confirmed -> commit: the trigger applies the override with the move.
	op.phase = .Stopping; op.revision = 2
	step, stepped, step_err := iface.instance_reconfiguration_advance(&h.agents, op, 1)
	if !testing.expect(t, stepped, step_err.message) do return
	domain.instance_reconfiguration_destroy(&step)
	op.phase = .Source_Stopped; op.source_stopped = true; op.revision = 3
	step, stepped, step_err = iface.instance_reconfiguration_advance(&h.agents, op, 2)
	if !testing.expect(t, stepped, step_err.message) do return
	domain.instance_reconfiguration_destroy(&step)
	op.phase = .Launching; op.destination_committed = true; op.revision = 4
	step, stepped, step_err = iface.instance_reconfiguration_advance(&h.agents, op, 3)
	if !testing.expect(t, stepped, step_err.message) do return
	domain.instance_reconfiguration_destroy(&step)

	inst, found, _ := iface.agent_get_instance(&h.agents, "inst_perm")
	if !testing.expect(t, found, "instance reloads") do return
	defer domain.agent_instance_destroy(&inst)
	testing.expect_value(t, inst.permission_mode, domain.AGENT_PERMISSION_MODE_ASK)
	testing.expect_value(t, inst.agent_permission_mode, domain.AGENT_PERMISSION_MODE_YOLO)
	testing.expect_value(t, domain.agent_instance_effective_permission_mode(inst), domain.AGENT_PERMISSION_MODE_ASK)
	testing.expect_value(t, inst.configuration_revision, 1)
	testing.expect_value(t, inst.launch_epoch, "epoch_perm")
	testing.expect_value(t, inst.provider, "claude")

	// The relaunch the operation sends carries the new effective mode.
	launch := launch_command_json_full(&h.service, "cmd_relaunch", inst)
	testing.expect(t, strings.contains(launch, `"permission_mode":"ask"`), "relaunch drops yolo flags")

	// A heartbeat-style save keeps the committed override.
	heartbeat := inst; heartbeat.permission_mode = ""; heartbeat.activity_status = "busy"
	_, _, _ = iface.agent_save_instance(&h.agents, heartbeat)
	reloaded, _, _ := iface.agent_get_instance(&h.agents, "inst_perm")
	testing.expect_value(t, reloaded.permission_mode, domain.AGENT_PERMISSION_MODE_ASK)
	domain.agent_instance_destroy(&reloaded)
}

@(test)
test_launch_payloads_use_instance_override_over_agent_mode :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	h: Perm_Harness
	if !perm_open(t, &h, "inst_perm_launch", domain.AGENT_PERMISSION_MODE_ASK) { perm_close(&h); return }
	defer perm_close(&h)

	inst, found, _ := iface.agent_get_instance(&h.agents, "inst_perm")
	if !testing.expect(t, found, "instance loads") do return
	defer domain.agent_instance_destroy(&inst)
	// No override: the agent's 'ask' is inherited.
	testing.expect_value(t, inst.permission_mode, "")
	testing.expect_value(t, domain.agent_instance_effective_permission_mode(inst), domain.AGENT_PERMISSION_MODE_ASK)
	inherited := launch_command_json_full(&h.service, "cmd_a", inst)
	testing.expect(t, strings.contains(inherited, `"permission_mode":"ask"`), "inherits the agent's ask mode")

	// Instance override 'yolo' (Bypass permissions on) wins over the agent's 'ask'.
	bypass := inst; bypass.permission_mode = domain.AGENT_PERMISSION_MODE_YOLO
	launch := launch_command_json_full(&h.service, "cmd_b", bypass)
	testing.expect(t, strings.contains(launch, `"permission_mode":"yolo"`), "instance override wins")
	// Without a service lookup the row's own agent mode is still honoured.
	bare := launch_command_json("cmd_c", inst)
	testing.expect(t, strings.contains(bare, `"permission_mode":"ask"`), "repository-provided agent mode is used without a lookup")
}
