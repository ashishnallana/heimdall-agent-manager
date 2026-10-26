// Plan T2: heartbeat inventory presence and completeness. These drive
// bridge_reconcile_heartbeat_inventory (the heartbeat arm's instance work) against a
// real SQLite agent repository, a connected runtime registry and a fake clock, so the
// 90s stale window is simulated rather than waited for.
package http

import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import agent_service "odin_test:hub/service/agent"
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import bridge_service "odin_test:hub/service/bridge"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import metrics "odin_test:lib/metrics"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"
import sqlite "odin_test:hub/repository/sqlite"

@(private = "file")
Inv_Clock :: struct {
	unix_seconds: i64, // atomic
}

@(private = "file")
inv_clock_now :: proc(ctx: rawptr) -> string {
	c := (^Inv_Clock)(ctx)
	return platform.format_rfc3339_utc(time.Time{_nsec = sync.atomic_load(&c.unix_seconds) * 1_000_000_000})
}

@(private = "file")
Inv_Fixture :: struct {
	conn:           sqlite.Conn,
	br_repo_sqlite: sqlite.Bridge_Repo_SQLite,
	ag_repo_sqlite: sqlite.Agent_Repo_SQLite,
	br_repo:        iface.Bridge_Repository,
	ag_repo:        iface.Agent_Repository,
	fake:           Inv_Clock,
	clock:          platform.Clock,
	ids:            platform.ID_Generator,
	br_svc:         bridge_service.Bridge_Service,
	ag_svc:         agent_service.Agent_Service,
	registry:       project_service.Bridge_Runtime_Registry,
	bh:             Bridge_Handlers,
	owner:          string,
	bridge_id:      string,
	other_bridge:   string,
	generation:     int,
}

@(private = "file")
INV_OWNER :: "usr_inventory_owner"

@(private = "file")
inv_enroll :: proc(t: ^testing.T, f: ^Inv_Fixture, key, host: string) -> string {
	owned := context.allocator
	context.allocator = context.temp_allocator // request-scoped in production
	enrolled, ok, _ := bridge_service.enroll_bridge_from_device_grant(&f.br_svc, bridge_service.Device_Enroll_Input{
		owner_user_id = INV_OWNER, bridge_public_key = key, bridge_key_fingerprint = "aaaa bbbb", machine_hostname = host, os_user = "tanmay",
	})
	testing.expect(t, ok, "bridge enrolled")
	return strings.clone(enrolled.bridge.bridge_id, owned)
}

@(private = "file")
inv_open :: proc(t: ^testing.T) -> ^Inv_Fixture {
	project_service.fleet_metrics_init(metrics.init_global())
	f := new(Inv_Fixture)
	conn, open_ok, _ := sqlite.open(":memory:")
	testing.expect(t, open_ok, "sqlite open ok")
	f.conn = conn
	mig_ok, _ := sqlite.run_migrations(&f.conn)
	testing.expect(t, mig_ok, "migrations ok")
	f.br_repo = sqlite.new_bridge_repository(&f.br_repo_sqlite, &f.conn)
	f.ag_repo = sqlite.new_agent_repository(&f.ag_repo_sqlite, &f.conn)
	f.fake = Inv_Clock{unix_seconds = 1_790_000_000}
	f.clock = platform.Clock{ctx = rawptr(&f.fake), now = inv_clock_now}
	f.ids = http_test_id_generator()
	f.br_svc = bridge_service.new_bridge_service(&f.br_repo, &f.clock, &f.ids)
	f.ag_svc = agent_service.new_agent_service(&f.ag_repo, &f.br_repo, &f.clock, &f.ids)
	f.bridge_id = inv_enroll(t, f, "04inventory", "inventory-box")
	f.other_bridge = inv_enroll(t, f, "04inventoryother", "other-box")
	_, hello_ok, _ := bridge_runtime_service.runtime_accept_hello(&f.registry, f.bridge_id, bridge_runtime_service.PROTOCOL_VERSION, "", INV_OWNER)
	testing.expect(t, hello_ok, "bridge connected")
	f.generation = project_service.bridge_runtime_registry_generation(&f.registry, f.bridge_id)
	f.bh = Bridge_Handlers{bridges = &f.br_svc, agents = &f.ag_svc, bridge_runtime_registry = &f.registry}
	return f
}

@(private = "file")
inv_close :: proc(f: ^Inv_Fixture) {
	agent_service.tool_live_destroy(&f.ag_svc.tool_live)
	bridge_runtime_service.runtime_command_cache_destroy(&f.registry)
	project_service.bridge_runtime_registry_destroy(&f.registry)
	sqlite.close(&f.conn)
	delete(f.bridge_id)
	delete(f.other_bridge)
	free(f)
}

@(private = "file")
inv_advance :: proc(f: ^Inv_Fixture, seconds: i64) {
	sync.atomic_add(&f.fake.unix_seconds, seconds)
}

@(private = "file")
inv_save :: proc(t: ^testing.T, f: ^Inv_Fixture, id, status: string, seq := 1, epoch := "", bridge_id := "") {
	now := platform.clock_now(&f.clock)
	_, ok, err := iface.agent_save_instance(&f.ag_repo, domain.Agent_Instance{
		agent_instance_id = id, agent_id = "agt_inventory", owner_user_id = domain.User_ID(INV_OWNER),
		bridge_id = bridge_id if bridge_id != "" else f.bridge_id, kind = "agent", runtime_status = status, activity_status = "idle",
		startup_status = "ready", last_applied_seq = seq, launch_epoch = epoch, last_seen_at = now, updated_at = now, created_at = now,
	})
	testing.expect(t, ok, err.message)
}

// Durable runtime_status and last_seen_at, caller owns both.
@(private = "file")
inv_get :: proc(t: ^testing.T, f: ^Inv_Fixture, id: string) -> (status, last_seen: string) {
	inst, ok, _ := iface.agent_get_instance(&f.ag_repo, id)
	testing.expect(t, ok, "instance readable")
	status = strings.clone(inst.runtime_status, context.temp_allocator)
	last_seen = strings.clone(inst.last_seen_at, context.temp_allocator)
	domain.agent_instance_destroy(&inst)
	return
}

// One beat under a per-frame arena, as the heartbeat arm runs it.
@(private = "file")
inv_beat :: proc(f: ^Inv_Fixture, text: string) -> (reconciled: int, state: Bridge_Heartbeat_Inventory_State) {
	scratch: virtual.Arena
	_ = virtual.arena_init_growing(&scratch)
	defer virtual.arena_destroy(&scratch)
	context.allocator = virtual.arena_allocator(&scratch)
	reconciled, _, state = bridge_reconcile_heartbeat_inventory(&f.bh, f.bridge_id, f.generation, text)
	return
}

@(private = "file")
inv_rejected :: proc(reason: string) -> u64 {
	return metrics.counter_value(metrics.with(project_service.fleet_metrics.bridge_frames_rejected, reason))
}

@(test)
test_heartbeat_inventory_decoder_distinguishes_complete_absent_malformed :: proc(t: ^testing.T) {
	Case :: struct { text: string, state: Bridge_Heartbeat_Inventory_State, reason: string }
	cases := []Case{
		{`{"type":"bridge_heartbeat","active_instance_ids":[],"instances":[]}`, .Complete, ""},
		{`{"type":"bridge_heartbeat","active_instance_ids":[]}`, .Complete, ""},
		{`{"type":"bridge_heartbeat","active_instance_ids":["a"],"instances":[{"agent_instance_id":"a","launch_epoch":"e","state_seq":3,"runtime_status":"running","activity_status":"idle","activity_source":"hook","error":{"code":"x"}}]}`, .Complete, ""},
		{`{"type":"bridge_heartbeat","digest":[{"agent_instance_id":"a","state_seq":1,"runtime_status":"running"}]}`, .Complete, ""},
		{`{"type":"bridge_heartbeat","digest":[{"agent_instance_id":"a","state_seq":1}],"instances":[{"state_seq":1,"agent_instance_id":"a"}]}`, .Complete, ""},
		{`{"type":"bridge_heartbeat","protocol_version":1,"vault_status":"unlocked"}`, .Absent, HEARTBEAT_INVENTORY_REJECT_ABSENT},
		{`{"type":"bridge_heartbeat","active_instance_ids":["a"],"instances":[{"agent_instance_id":"a"`, .Malformed, HEARTBEAT_INVENTORY_REJECT_MALFORMED},
		{`{"type":"bridge_heartbeat","active_instance_ids":[]} {"type":"x"}`, .Malformed, HEARTBEAT_INVENTORY_REJECT_MALFORMED},
		{"{\"type\":\"bridge_heartbeat\",\"active_instance_ids\":[\"\xff\"]}", .Malformed, HEARTBEAT_INVENTORY_REJECT_MALFORMED},
		{`{"type":"bridge_heartbeat","active_instance_ids":null,"instances":[]}`, .Malformed, HEARTBEAT_INVENTORY_REJECT_MALFORMED},
		{`{"type":"bridge_heartbeat","active_instance_ids":["a",7],"instances":[]}`, .Malformed, HEARTBEAT_INVENTORY_REJECT_MALFORMED},
		{`{"type":"bridge_heartbeat","active_instance_ids":[""],"instances":[]}`, .Malformed, HEARTBEAT_INVENTORY_REJECT_MALFORMED},
		{`{"type":"bridge_heartbeat","instances":{"agent_instance_id":"a"}}`, .Malformed, HEARTBEAT_INVENTORY_REJECT_MALFORMED},
		{`{"type":"bridge_heartbeat","instances":["a"]}`, .Malformed, HEARTBEAT_INVENTORY_REJECT_MALFORMED},
		{`{"type":"bridge_heartbeat","instances":[{"agent_instance_id":""}]}`, .Malformed, HEARTBEAT_INVENTORY_REJECT_MALFORMED},
		{`{"type":"bridge_heartbeat","instances":[{"agent_instance_id":"a","state_seq":"3"}]}`, .Malformed, HEARTBEAT_INVENTORY_REJECT_MALFORMED},
		{`{"type":"bridge_heartbeat","instances":[{"agent_instance_id":"a","state_seq":3.5}]}`, .Malformed, HEARTBEAT_INVENTORY_REJECT_MALFORMED},
		{`{"type":"bridge_heartbeat","instances":[{"agent_instance_id":"a","runtime_status":1}]}`, .Malformed, HEARTBEAT_INVENTORY_REJECT_MALFORMED},
		{`{"type":"bridge_heartbeat","digest":[{"agent_instance_id":"a"}],"instances":[{"agent_instance_id":"b"}]}`, .Malformed, HEARTBEAT_INVENTORY_REJECT_CONFLICT},
		{`{"type":"bridge_heartbeat","digest":[],"instances":[{"agent_instance_id":"a","runtime_status":"running"}]}`, .Malformed, HEARTBEAT_INVENTORY_REJECT_CONFLICT},
		{`{"type":"bridge_heartbeat","digest":[{"agent_instance_id":"a","state_seq":1}],"instances":[{"agent_instance_id":"a","state_seq":2}]}`, .Malformed, HEARTBEAT_INVENTORY_REJECT_CONFLICT},
		{`{"type":"bridge_heartbeat","digest":"x","instances":[]}`, .Malformed, HEARTBEAT_INVENTORY_REJECT_MALFORMED},
		{``, .Malformed, HEARTBEAT_INVENTORY_REJECT_MALFORMED},
		{`[]`, .Malformed, HEARTBEAT_INVENTORY_REJECT_MALFORMED},
	}
	for c in cases {
		inv: Bridge_Heartbeat_Inventory
		bridge_decode_heartbeat_inventory(&inv, c.text)
		testing.expectf(t, inv.state == c.state, "%s: state %v, want %v", c.text, inv.state, c.state)
		testing.expectf(t, inv.reason == c.reason, "%s: reason %q, want %q", c.text, inv.reason, c.reason)
		bridge_heartbeat_inventory_destroy(&inv)
	}
}

// Terminal rows recur in instances[] so a dropped terminal push is repaired; when
// active_instance_ids is empty the fallback takes only the active rows from them.
@(test)
test_heartbeat_inventory_fallback_filters_terminal_reports :: proc(t: ^testing.T) {
	inv: Bridge_Heartbeat_Inventory
	bridge_decode_heartbeat_inventory(&inv, `{"type":"bridge_heartbeat","active_instance_ids":[],"instances":[{"agent_instance_id":"live","runtime_status":"busy"},{"agent_instance_id":"done","runtime_status":"stopped"},{"agent_instance_id":"dead","runtime_status":"failed"},{"agent_instance_id":"held","runtime_status":"blocked"}]}`)
	defer bridge_heartbeat_inventory_destroy(&inv)
	active := bridge_heartbeat_inventory_active_ids(&inv)
	defer delete(active)
	testing.expect_value(t, len(active), 2)
	if len(active) == 2 {
		testing.expect_value(t, active[0], "live")
		testing.expect_value(t, active[1], "held")
	}
	// A non-empty active list is authoritative as before.
	listed: Bridge_Heartbeat_Inventory
	bridge_decode_heartbeat_inventory(&listed, `{"type":"bridge_heartbeat","active_instance_ids":["x"],"instances":[{"agent_instance_id":"live","runtime_status":"running"}]}`)
	defer bridge_heartbeat_inventory_destroy(&listed)
	listed_active := bridge_heartbeat_inventory_active_ids(&listed)
	defer delete(listed_active)
	testing.expect_value(t, len(listed_active), 1)
	if len(listed_active) == 1 do testing.expect_value(t, listed_active[0], "x")
}

// An idle agent whose state_seq never moves stays live across >90s of beats, because
// each complete beat is the liveness proof; the stale reaper never fires.
@(test)
test_heartbeat_inventory_idle_agent_survives_beyond_stale_window :: proc(t: ^testing.T) {
	f := inv_open(t)
	defer inv_close(f)
	inv_save(t, f, "inst_idle", "running", seq = 5, epoch = "ep1")
	BEAT :: `{"type":"bridge_heartbeat","active_instance_ids":["inst_idle"],"instances":[{"agent_instance_id":"inst_idle","launch_epoch":"ep1","state_seq":5,"runtime_status":"running","activity_status":"idle"}]}`
	for _ in 0 ..< 8 { // 8 * 30s = 240s, well past BRIDGE_INSTANCE_STALE_MS
		inv_advance(f, 30)
		reconciled, state := inv_beat(f, BEAT)
		testing.expect_value(t, state, Bridge_Heartbeat_Inventory_State.Complete)
		testing.expect_value(t, reconciled, 0)
	}
	status, last_seen := inv_get(t, f, "inst_idle")
	now := platform.clock_now(&f.clock)
	testing.expect_value(t, status, "running")
	testing.expect_value(t, last_seen, now)
}

// A complete inventory that no longer lists an instance is authoritative absence, and
// a complete EMPTY inventory is authoritative for every instance on the Bridge.
@(test)
test_heartbeat_inventory_true_disappearance_marks_unreachable :: proc(t: ^testing.T) {
	f := inv_open(t)
	defer inv_close(f)
	inv_save(t, f, "inst_kept", "running")
	inv_save(t, f, "inst_gone", "running")
	reconciled, _ := inv_beat(f, `{"type":"bridge_heartbeat","active_instance_ids":["inst_kept"],"instances":[{"agent_instance_id":"inst_kept","state_seq":1,"runtime_status":"running"}]}`)
	testing.expect_value(t, reconciled, 1)
	gone, _ := inv_get(t, f, "inst_gone")
	kept, _ := inv_get(t, f, "inst_kept")
	testing.expect_value(t, gone, "unreachable")
	testing.expect_value(t, kept, "running")

	reconciled, _ = inv_beat(f, `{"type":"bridge_heartbeat","active_instance_ids":[],"instances":[]}`)
	testing.expect(t, reconciled >= 1, "empty complete inventory reconciles")
	kept, _ = inv_get(t, f, "inst_kept")
	testing.expect_value(t, kept, "unreachable")
}

// Absent and malformed inventories change no instance, are counted, and do not stop
// the Bridge's own durable liveness from being refreshed by the same beat.
@(test)
test_heartbeat_inventory_absent_or_malformed_skips_absence_reconciliation :: proc(t: ^testing.T) {
	f := inv_open(t)
	defer inv_close(f)
	inv_save(t, f, "inst_live", "running", seq = 4)
	frames := []string{
		`{"type":"bridge_heartbeat","protocol_version":1,"vault_status":"unlocked"}`,
		// Truncated: what used to parse as an empty digest with the active set applied.
		`{"type":"bridge_heartbeat","active_instance_ids":[],"instances":[{"agent_instance_id":"inst_live","state_seq":9,"runtime_status":"stopped"`,
		// Typed wrongly: must not repair status from the half that did parse.
		`{"type":"bridge_heartbeat","active_instance_ids":[],"instances":[{"agent_instance_id":"inst_live","state_seq":9,"runtime_status":"stopped"},{"agent_instance_id":7}]}`,
		// Legacy digest disagreeing with instances.
		`{"type":"bridge_heartbeat","active_instance_ids":[],"digest":[],"instances":[{"agent_instance_id":"inst_live","state_seq":9,"runtime_status":"stopped"}]}`,
	}
	want := []Bridge_Heartbeat_Inventory_State{.Absent, .Malformed, .Malformed, .Malformed}
	absent_before := inv_rejected(HEARTBEAT_INVENTORY_REJECT_ABSENT)
	malformed_before := inv_rejected(HEARTBEAT_INVENTORY_REJECT_MALFORMED)
	conflict_before := inv_rejected(HEARTBEAT_INVENTORY_REJECT_CONFLICT)
	for frame, i in frames {
		inv_advance(f, 20)
		bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, f.generation, frame)
		reconciled, state := inv_beat(f, frame)
		testing.expect_value(t, state, want[i])
		testing.expect_value(t, reconciled, 0)
		status, _ := inv_get(t, f, "inst_live")
		testing.expect_value(t, status, "running")
	}
	testing.expect(t, inv_rejected(HEARTBEAT_INVENTORY_REJECT_ABSENT) >= absent_before + 1, "absent counted")
	testing.expect(t, inv_rejected(HEARTBEAT_INVENTORY_REJECT_MALFORMED) >= malformed_before + 2, "malformed counted")
	testing.expect(t, inv_rejected(HEARTBEAT_INVENTORY_REJECT_CONFLICT) >= conflict_before + 1, "conflict counted")
	row, ok, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	testing.expect(t, ok, "bridge row readable")
	defer domain.bridge_destroy(&row)
	now := platform.clock_now(&f.clock)
	testing.expect_value(t, row.status, domain.Bridge_Status.Online)
	testing.expect_value(t, row.last_seen_at, now)
	// The legacy wrapper applies nothing for these either.
	for frame in frames do testing.expect_value(t, len(bridge_apply_heartbeat_digest(&f.bh, f.bridge_id, frame, f.generation)), 0)
}

// Terminal-only inventory: a dropped terminal push is repaired from the recurring row,
// and a terminal row whose repair is fenced off (stale seq) is still never treated as
// active — before T2 the fallback kept such an instance "running" indefinitely.
@(test)
test_heartbeat_inventory_terminal_only_repairs_and_never_refreshes :: proc(t: ^testing.T) {
	f := inv_open(t)
	defer inv_close(f)
	inv_save(t, f, "inst_dropped", "running", seq = 3)
	inv_save(t, f, "inst_fenced", "running", seq = 10)
	inv_save(t, f, "inst_live", "running", seq = 2)
	reconciled, state := inv_beat(f, `{"type":"bridge_heartbeat","active_instance_ids":[],"instances":[{"agent_instance_id":"inst_dropped","state_seq":4,"runtime_status":"stopped","activity_status":"idle"},{"agent_instance_id":"inst_fenced","state_seq":6,"runtime_status":"stopped"},{"agent_instance_id":"inst_live","state_seq":2,"runtime_status":"running"}]}`)
	testing.expect_value(t, state, Bridge_Heartbeat_Inventory_State.Complete)
	dropped, _ := inv_get(t, f, "inst_dropped")
	fenced, _ := inv_get(t, f, "inst_fenced")
	live, _ := inv_get(t, f, "inst_live")
	testing.expect_value(t, dropped, "stopped")
	testing.expect_value(t, fenced, "unreachable")
	testing.expect_value(t, live, "running")
	testing.expect_value(t, reconciled, 1)
}

// Launch-epoch and state_seq fencing still hold: a superseded launch's report and a
// stale sequence change nothing, while the active listing keeps the instance live.
@(test)
test_heartbeat_inventory_stale_launch_and_sequence_are_fenced :: proc(t: ^testing.T) {
	f := inv_open(t)
	defer inv_close(f)
	inv_save(t, f, "inst_fence", "running", seq = 10, epoch = "ep2")
	frames := []string{
		`{"type":"bridge_heartbeat","active_instance_ids":["inst_fence"],"instances":[{"agent_instance_id":"inst_fence","launch_epoch":"ep1","state_seq":20,"runtime_status":"failed"}]}`,
		`{"type":"bridge_heartbeat","active_instance_ids":["inst_fence"],"instances":[{"agent_instance_id":"inst_fence","launch_epoch":"ep2","state_seq":5,"runtime_status":"stopped"}]}`,
	}
	for frame in frames {
		inv_advance(f, 60)
		reconciled, state := inv_beat(f, frame)
		testing.expect_value(t, state, Bridge_Heartbeat_Inventory_State.Complete)
		testing.expect_value(t, reconciled, 0)
		status, _ := inv_get(t, f, "inst_fence")
		testing.expect_value(t, status, "running")
	}
	inst, ok, _ := iface.agent_get_instance(&f.ag_repo, "inst_fence")
	testing.expect(t, ok, "instance readable")
	testing.expect_value(t, inst.last_applied_seq, 10)
	domain.agent_instance_destroy(&inst)
}

// H7: an instance reported active here but canonically on another Bridge is returned
// as superseded and reaches the ack with the schedule freshness tokens. A rejected
// inventory names no superseded ids, but the ack still carries the schedule tokens.
@(test)
test_heartbeat_inventory_superseded_ids_and_schedule_ack :: proc(t: ^testing.T) {
	f := inv_open(t)
	defer inv_close(f)
	inv_save(t, f, "inst_moved", "running", bridge_id = f.other_bridge)
	inv_save(t, f, "inst_here", "running")
	scratch: virtual.Arena
	_ = virtual.arena_init_growing(&scratch)
	defer virtual.arena_destroy(&scratch)
	context.allocator = virtual.arena_allocator(&scratch)
	reconciled, superseded, state := bridge_reconcile_heartbeat_inventory(&f.bh, f.bridge_id, f.generation, `{"type":"bridge_heartbeat","active_instance_ids":["inst_here","inst_moved"],"instances":[{"agent_instance_id":"inst_here","state_seq":1,"runtime_status":"running"},{"agent_instance_id":"inst_moved","state_seq":1,"runtime_status":"running"}]}`)
	testing.expect_value(t, state, Bridge_Heartbeat_Inventory_State.Complete)
	testing.expect_value(t, len(superseded), 1)
	if len(superseded) == 1 do testing.expect_value(t, superseded[0], "inst_moved")
	ack := bridge_heartbeat_ack_payload(reconciled, superseded, 3, "sched_epoch", 7)
	testing.expect(t, strings.contains(ack, `"superseded_instance_ids":["inst_moved"]`), ack)
	testing.expect(t, strings.contains(ack, `"schedules_version":3,"schedules_epoch":"sched_epoch","schedules_revision":7`), ack)
	moved, _ := inv_get(t, f, "inst_moved")
	testing.expect_value(t, moved, "running") // owned by the other Bridge; untouched here

	rejected_reconciled, rejected_superseded, rejected_state := bridge_reconcile_heartbeat_inventory(&f.bh, f.bridge_id, f.generation, `{"type":"bridge_heartbeat"}`)
	testing.expect_value(t, rejected_state, Bridge_Heartbeat_Inventory_State.Absent)
	testing.expect_value(t, len(rejected_superseded), 0)
	rejected_ack := bridge_heartbeat_ack_payload(rejected_reconciled, rejected_superseded, 3, "sched_epoch", 7)
	testing.expect(t, strings.contains(rejected_ack, `"schedules_epoch":"sched_epoch","schedules_revision":7,"superseded_instance_ids":[]`), rejected_ack)
}
