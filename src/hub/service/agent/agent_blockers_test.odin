package agent

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"

// REQ-EXT-BLK-2/3: the hub's in-memory agent blockers — snapshot replace, rebuild
// after a hub restart, drop on bridge offline / instance stop, owner-checked
// list + resolve, and the agent_blockers_changed realtime event.

@(private = "file")
Blk_Store :: struct {
	insts:    [dynamic]domain.Agent_Instance,
	commands: [dynamic]project_service.Runtime_Command,
	offline:  bool,
}

@(private = "file")
blk_get_instance :: proc(ctx: rawptr, instance_id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	s := (^Blk_Store)(ctx)
	for inst in s.insts do if inst.agent_instance_id == instance_id do return inst, true, {}
	return {}, false, domain.domain_error(.Not_Found, "agent instance not found")
}

@(private = "file")
blk_send :: proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	s := (^Blk_Store)(ctx)
	if s.offline do return false, domain.domain_error(.Bridge_Offline, "offline")
	append(&s.commands, cmd)
	return true, {}
}

@(private = "file")
blk_now :: proc(ctx: rawptr) -> string { return "2026-10-22T10:00:00Z" }

@(private = "file")
blk_service :: proc(store: ^Blk_Store, repo: ^iface.Agent_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Agent_Service {
	append(&store.insts, domain.Agent_Instance{agent_instance_id = "inst_me", owner_user_id = "owner", bridge_id = "brg_1", runtime_status = "running"})
	append(&store.insts, domain.Agent_Instance{agent_instance_id = "inst_two", owner_user_id = "owner", bridge_id = "brg_1", runtime_status = "running"})
	append(&store.insts, domain.Agent_Instance{agent_instance_id = "inst_other_bridge", owner_user_id = "owner", bridge_id = "brg_2", runtime_status = "running"})
	repo^ = iface.Agent_Repository{ctx = store, get_instance = blk_get_instance}
	clock^ = platform.Clock{ctx = store, now = blk_now}
	ids^ = platform.real_id_generator()
	svc := new_agent_service(repo, nil, clock, ids)
	svc.bridge_command_sink = project_service.Bridge_Command_Sink{ctx = store, send_runtime_command = blk_send}
	svc.blockers.record_events = true
	return svc
}

@(private = "file")
blk_user :: proc(user := "owner") -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .Session, user_id = user}
}

@(private = "file")
BLK_SNAPSHOT_ONE :: `{"type":"agent_blockers","protocol_version":1,"agent_instance_id":"inst_me","revision":100,"blockers":[{"blocker_id":"blk_aaa","kind":"permission","provider":"claude","agent_id":"sub-1","tool_name":"Bash","summary":"Bash: ls","input":{"command":"ls"},"created_at":"2026-10-22T09:59:00Z","expires_at":"2026-10-22T10:04:00Z","extra":"dropped"}]}`
@(private = "file")
BLK_SNAPSHOT_TWO :: `{"type":"agent_blockers","agent_instance_id":"inst_me","revision":101,"blockers":[{"blocker_id":"blk_aaa","kind":"permission","tool_name":"Bash","input":{"command":"ls"}},{"blocker_id":"term_inst_me","kind":"terminal_prompt","summary":"Waiting for input in terminal"},{"blocker_id":"bad id","kind":"permission"},{"blocker_id":"blk_x","kind":"mystery"}]}`
@(private = "file")
BLK_SNAPSHOT_EMPTY :: `{"type":"agent_blockers","agent_instance_id":"inst_me","revision":102,"blockers":[]}`

@(test)
test_agent_blockers_snapshot_replaces_wholesale_and_publishes :: proc(t: ^testing.T) {
	store: Blk_Store; repo: iface.Agent_Repository; clock: platform.Clock; ids: platform.ID_Generator
	svc := blk_service(&store, &repo, &clock, &ids)

	testing.expect(t, apply_bridge_blockers_snapshot(&svc, "brg_1", BLK_SNAPSHOT_ONE))
	body, ok, err := list_instance_blockers(&svc, blk_user(), "inst_me")
	testing.expect(t, ok, err.message)
	for want in ([]string{`"agent_instance_id":"inst_me"`, `"revision":100`, `"blocker_id":"blk_aaa"`, `"kind":"permission"`, `"provider":"claude"`, `"agent_id":"sub-1"`, `"summary":"Bash: ls"`, `"input":{"command":"ls"}`, `"expires_at":"2026-10-22T10:04:00Z"`}) {
		testing.expectf(t, strings.contains(body, want), "missing %s in %s", want, body)
	}
	testing.expect(t, !strings.contains(body, "dropped"), body)
	testing.expect_value(t, len(svc.blockers.events), 1)
	if len(svc.blockers.events) == 1 do testing.expect_value(t, svc.blockers.events[0], `{"agent_instance_id":"inst_me","revision":100,"count":1}`)

	// The same snapshot again (a heartbeat resync) changes nothing and is silent.
	testing.expect(t, apply_bridge_blockers_snapshot(&svc, "brg_1", BLK_SNAPSHOT_ONE))
	testing.expect_value(t, len(svc.blockers.events), 1)

	// A newer snapshot replaces the list; invalid entries are skipped.
	testing.expect(t, apply_bridge_blockers_snapshot(&svc, "brg_1", BLK_SNAPSHOT_TWO))
	testing.expect_value(t, instance_blocker_count(&svc, "inst_me"), 2)
	body, _, _ = list_instance_blockers(&svc, blk_user(), "inst_me")
	testing.expect(t, strings.contains(body, `"kind":"terminal_prompt"`), body)
	testing.expect(t, !strings.contains(body, "blk_x"), body)
	testing.expect_value(t, len(svc.blockers.events), 2)

	// An empty snapshot clears it.
	testing.expect(t, apply_bridge_blockers_snapshot(&svc, "brg_1", BLK_SNAPSHOT_EMPTY))
	testing.expect_value(t, instance_blocker_count(&svc, "inst_me"), 0)
	body, _, _ = list_instance_blockers(&svc, blk_user(), "inst_me")
	testing.expect(t, strings.contains(body, `"blockers":[]`), body)
	testing.expect_value(t, len(svc.blockers.events), 3)
	if len(svc.blockers.events) == 3 do testing.expect_value(t, svc.blockers.events[2], `{"agent_instance_id":"inst_me","revision":102,"count":0}`)
}

@(test)
test_agent_blockers_scoped_to_the_reporting_bridge :: proc(t: ^testing.T) {
	store: Blk_Store; repo: iface.Agent_Repository; clock: platform.Clock; ids: platform.ID_Generator
	svc := blk_service(&store, &repo, &clock, &ids)
	// brg_2 does not run inst_me; unknown instances and junk are refused.
	testing.expect(t, !apply_bridge_blockers_snapshot(&svc, "brg_2", BLK_SNAPSHOT_ONE))
	testing.expect(t, !apply_bridge_blockers_snapshot(&svc, "brg_1", `{"agent_instance_id":"inst_nope","revision":1,"blockers":[]}`))
	testing.expect(t, !apply_bridge_blockers_snapshot(&svc, "brg_1", `not json`))
	testing.expect_value(t, instance_blocker_count(&svc, "inst_me"), 0)
	testing.expect_value(t, len(svc.blockers.events), 0)

	// A stopped instance has no blockers whatever a late snapshot says.
	store.insts[0].runtime_status = "stopped"
	testing.expect(t, apply_bridge_blockers_snapshot(&svc, "brg_1", BLK_SNAPSHOT_ONE))
	testing.expect_value(t, instance_blocker_count(&svc, "inst_me"), 0)
}

@(test)
test_agent_blockers_rebuild_after_hub_restart :: proc(t: ^testing.T) {
	store: Blk_Store; repo: iface.Agent_Repository; clock: platform.Clock; ids: platform.ID_Generator
	svc := blk_service(&store, &repo, &clock, &ids)
	testing.expect(t, apply_bridge_blockers_snapshot(&svc, "brg_1", BLK_SNAPSHOT_ONE))
	// "Hub restart": a fresh service starts with an empty map ...
	store2: Blk_Store; repo2: iface.Agent_Repository; clock2: platform.Clock; ids2: platform.ID_Generator
	fresh := blk_service(&store2, &repo2, &clock2, &ids2)
	testing.expect_value(t, instance_blocker_count(&fresh, "inst_me"), 0)
	// ... and the bridge's reconnect resync of the still-blocked hook refills it.
	testing.expect(t, apply_bridge_blockers_snapshot(&fresh, "brg_1", BLK_SNAPSHOT_ONE))
	body, ok, _ := list_instance_blockers(&fresh, blk_user(), "inst_me")
	testing.expect(t, ok)
	testing.expect(t, strings.contains(body, `"blocker_id":"blk_aaa"`), body)
	testing.expect_value(t, len(fresh.blockers.events), 1)
}

@(test)
test_agent_blockers_dropped_on_bridge_offline_and_instance_stop :: proc(t: ^testing.T) {
	store: Blk_Store; repo: iface.Agent_Repository; clock: platform.Clock; ids: platform.ID_Generator
	svc := blk_service(&store, &repo, &clock, &ids)
	testing.expect(t, apply_bridge_blockers_snapshot(&svc, "brg_1", BLK_SNAPSHOT_ONE))
	testing.expect(t, apply_bridge_blockers_snapshot(&svc, "brg_1", `{"agent_instance_id":"inst_two","revision":5,"blockers":[{"blocker_id":"term_inst_two","kind":"terminal_prompt"}]}`))
	testing.expect(t, apply_bridge_blockers_snapshot(&svc, "brg_2", `{"agent_instance_id":"inst_other_bridge","revision":5,"blockers":[{"blocker_id":"blk_o","kind":"permission"}]}`))
	events_before := len(svc.blockers.events)

	testing.expect_value(t, clear_bridge_blockers(&svc, "brg_1"), 2)
	testing.expect_value(t, instance_blocker_count(&svc, "inst_me"), 0)
	testing.expect_value(t, instance_blocker_count(&svc, "inst_two"), 0)
	testing.expect_value(t, instance_blocker_count(&svc, "inst_other_bridge"), 1)
	testing.expect_value(t, len(svc.blockers.events), events_before + 2)

	// Instance death clears through the one terminal chokepoint.
	notify_instance_terminal(&svc, "inst_other_bridge")
	testing.expect_value(t, instance_blocker_count(&svc, "inst_other_bridge"), 0)
	testing.expect_value(t, len(svc.blockers.events), events_before + 3)
	testing.expect(t, !clear_instance_blockers(&svc, "inst_other_bridge"), "already clear")
}

@(test)
test_agent_blockers_resolve_authz_and_push :: proc(t: ^testing.T) {
	store: Blk_Store; repo: iface.Agent_Repository; clock: platform.Clock; ids: platform.ID_Generator
	svc := blk_service(&store, &repo, &clock, &ids)
	testing.expect(t, apply_bridge_blockers_snapshot(&svc, "brg_1", BLK_SNAPSHOT_TWO))

	// Agents and bridges can never answer; strangers cannot see the instance.
	_, ok, err := resolve_instance_blocker(&svc, contracts.Auth_Context{kind = .Instance_Token, user_id = "owner", agent_instance_id = "inst_me"}, "inst_me", "blk_aaa", "allow", "")
	testing.expect(t, !ok)
	testing.expect_value(t, err.code, domain.Error_Code.Forbidden)
	_, ok, err = resolve_instance_blocker(&svc, blk_user("intruder"), "inst_me", "blk_aaa", "allow", "")
	testing.expect(t, !ok)
	testing.expect(t, err.code == .Not_Found || err.code == .Forbidden, "non-owner refused")
	_, ok, _ = list_instance_blockers(&svc, blk_user("intruder"), "inst_me")
	testing.expect(t, !ok, "non-owner cannot list")
	// Bad input, unknown blocker (404), terminal prompt (409).
	_, ok, err = resolve_instance_blocker(&svc, blk_user(), "inst_me", "blk_aaa", "maybe", "")
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
	_, ok, err = resolve_instance_blocker(&svc, blk_user(), "inst_me", "blk_nope", "allow", "")
	testing.expect_value(t, err.code, domain.Error_Code.Not_Found)
	_, ok, err = resolve_instance_blocker(&svc, blk_user(), "inst_me", "term_inst_me", "allow", "")
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)
	testing.expect_value(t, len(store.commands), 0)

	// The owner's decision becomes one permission_decision frame for the bridge.
	body, ok2, err2 := resolve_instance_blocker(&svc, blk_user(), "inst_me", "blk_aaa", "Allow", "go ahead")
	testing.expect(t, ok2, err2.message)
	testing.expect(t, strings.contains(body, `"resolved":true`), body)
	testing.expect_value(t, len(store.commands), 1)
	if len(store.commands) == 1 {
		cmd := store.commands[0]
		testing.expect_value(t, cmd.bridge_id, "brg_1")
		for want in ([]string{`"type":"permission_decision"`, `"agent_instance_id":"inst_me"`, `"request_id":"blk_aaa"`, `"decision":"allow"`, `"message":"go ahead"`}) {
			testing.expectf(t, strings.contains(cmd.body_json, want), "missing %s in %s", want, cmd.body_json)
		}
	}

	// Bridge offline: 409.
	store.offline = true
	_, ok, err = resolve_instance_blocker(&svc, blk_user(), "inst_me", "blk_aaa", "deny", "")
	testing.expect(t, !ok)
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)
}
