// Minimal heartbeat plan T6 final acceptance, Hub side: a Bridge that negotiated both
// flags sends hello once, then many eight-member heartbeats interleaved with
// bridge_diagnostics snapshots in exactly the shape src/bridge/bridge_diagnostics.odin
// writes. Through the real handlers (heartbeat liveness, diagnostics apply, live tool
// relay) and a real SQLite bridge row + runtime registry, the existing capability
// JSON keeps tool_stream_supported, an external (UI) viewer is admitted and receives
// a current-session tool update, and a withdrawing hello or an old Bridge that never
// listed the feature fails closed.
package http

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import agent_service "odin_test:hub/service/agent"
import bridge_service "odin_test:hub/service/bridge"
import project_service "odin_test:hub/service/project"
import domain "odin_test:hub/domain"
import events "odin_test:hub/service/events"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"

@(private = "file")
DIAG_OWNER :: "usr_diag_owner"
@(private = "file")
DIAG_INSTANCE :: "inst_diag_live"
@(private = "file")
DIAG_CONVERSATION :: "conv_diag_live"
@(private = "file")
DIAG_FEATURES_NEGOTIATING :: `["capture_agent_pane","get_agent_pane","instance_reconfiguration_v1","tool_stream_demand_v2","heartbeat_metadata_omission"]`
@(private = "file")
DIAG_FEATURES_WITHDRAWN :: `["capture_agent_pane","get_agent_pane","instance_reconfiguration_v1","heartbeat_metadata_omission"]`
// The eight-member core a Bridge sends once both flags are negotiated.
@(private = "file")
DIAG_BEAT_CORE :: `{"type":"bridge_heartbeat","protocol_version":1,"vault_status":"unlocked","task_chain_search_ready":true,"task_chain_search_stale":false,"task_chain_search_revision":7,"active_instance_ids":["inst_diag_live"],"instances":[{"agent_instance_id":"inst_diag_live","launch_epoch":"ep_1","state_seq":1,"runtime_status":"running","activity_status":"busy"}]}`

@(private = "file")
Diag_Fixture :: struct {
	conn:           sqlite.Conn,
	br_repo_sqlite: sqlite.Bridge_Repo_SQLite,
	ag_repo_sqlite: sqlite.Agent_Repo_SQLite,
	br_repo:        iface.Bridge_Repository,
	ag_repo:        iface.Agent_Repository,
	tool_repo:      iface.Agent_Repository,
	content_repo:   iface.Content_Repository,
	clock:          platform.Clock,
	ids:            platform.ID_Generator,
	br_svc:         bridge_service.Bridge_Service,
	ag_svc:         agent_service.Agent_Service,
	registry:       project_service.Bridge_Runtime_Registry,
	bus:            events.User_Event_Bus,
	bh:             Bridge_Handlers,
	bridge_id:      string,
	bridge_token:   string,
	viewer:         agent_service.Tool_Stream_Viewer,
}

@(private = "file")
diag_fixture_open :: proc(t: ^testing.T) -> ^Diag_Fixture {
	f := new(Diag_Fixture)
	conn, open_ok, _ := sqlite.open(":memory:")
	testing.expect(t, open_ok, "sqlite open ok")
	f.conn = conn
	mig_ok, _ := sqlite.run_migrations(&f.conn)
	testing.expect(t, mig_ok, "migrations ok")
	f.br_repo = sqlite.new_bridge_repository(&f.br_repo_sqlite, &f.conn)
	f.ag_repo = sqlite.new_agent_repository(&f.ag_repo_sqlite, &f.conn)
	f.clock = platform.real_clock()
	f.ids = http_test_id_generator()
	f.br_svc = bridge_service.new_bridge_service(&f.br_repo, &f.clock, &f.ids)
	f.ag_svc = agent_service.new_agent_service(&f.ag_repo, &f.br_repo, &f.clock, &f.ids)
	f.ag_svc.bridge_runtime_registry = &f.registry
	f.bh = Bridge_Handlers{bridges = &f.br_svc, agents = &f.ag_svc, event_bus = &f.bus, bridge_runtime_registry = &f.registry}
	enrolled, e_ok, _ := bridge_service.enroll_bridge_from_device_grant(&f.br_svc, bridge_service.Device_Enroll_Input{
		owner_user_id = DIAG_OWNER, bridge_public_key = "04diag", bridge_key_fingerprint = "aaaa bbbb cccc dddd",
		machine_hostname = "diag-box", os_user = "tanmay",
	})
	testing.expect(t, e_ok, "bridge enrolled")
	f.bridge_id = strings.clone(enrolled.bridge.bridge_id)
	f.bridge_token = strings.clone(enrolled.bridge_token)

	// The live instance runs on this bridge; its chat conversation authorizes the viewer.
	f.tool_repo = iface.Agent_Repository{ctx = f, get_tool_instance = proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
		f := (^Diag_Fixture)(ctx)
		return domain.Agent_Instance{agent_instance_id = id, bridge_id = f.bridge_id, owner_user_id = DIAG_OWNER, run_count = 1, runtime_status = "running"}, true, {}
	}}
	f.ag_svc.agents = &f.tool_repo
	f.content_repo = iface.Content_Repository{get_conversation = proc(ctx: rawptr, id: string) -> (domain.Chat_Conversation, bool, domain.Domain_Error) {
		if id != DIAG_CONVERSATION do return {}, false, {}
		return domain.Chat_Conversation{conversation_id = DIAG_CONVERSATION, owner_user_id = DIAG_OWNER, agent_instance_id = DIAG_INSTANCE}, true, {}
	}}
	f.ag_svc.content = &f.content_repo
	heap := runtime.heap_allocator()
	s := &f.ag_svc.tool_live
	s.routes = make(map[string]^agent_service.Tool_Stream_Route, heap)
	s.viewers = make(map[net.TCP_Socket]^agent_service.Tool_Stream_Viewer, heap)
	s.controls = make([dynamic]agent_service.Tool_Stream_Control, heap)
	f.viewer = {owner = DIAG_OWNER, socket = net.TCP_Socket(-1), external = true, ids = make(map[string]bool, heap), queue = make([dynamic]agent_service.Tool_Stream_Frame, heap)}
	s.viewers[f.viewer.socket] = &f.viewer
	return f
}

@(private = "file")
diag_fixture_close :: proc(f: ^Diag_Fixture) {
	heap := runtime.heap_allocator()
	_ = agent_service.tool_stream_subscribe(&f.ag_svc, &f.viewer, nil)
	diag_viewer_clear(&f.viewer)
	for key in f.viewer.ids do delete(key, heap)
	delete(f.viewer.ids); delete(f.viewer.queue)
	agent_service.tool_live_destroy(&f.ag_svc.tool_live)
	project_service.fleet_metrics_tombstone_bridge(f.bridge_id)
	project_service.bridge_runtime_registry_destroy(&f.registry)
	delete(f.bridge_id)
	delete(f.bridge_token)
	sqlite.close(&f.conn)
	free(f)
}

@(private = "file")
diag_viewer_clear :: proc(w: ^agent_service.Tool_Stream_Viewer) {
	for frame in w.queue { delete(frame.text, runtime.heap_allocator()); delete(frame.instance_id, runtime.heap_allocator()) }
	clear(&w.queue); w.bytes = 0
}

@(private = "file")
diag_hello :: proc(features: string) -> string {
	if features == "" do return `{"type":"bridge_hello","protocol_version":2,"hostname":"diag-box","capabilities":[],"active_instance_ids":[]}`
	return fmt.tprintf(`{{"type":"bridge_hello","protocol_version":2,"hostname":"diag-box","capabilities":[],"features":%s,"active_instance_ids":[]}}`, features)
}

// diag_connect admits a generation and runs its hello as the WS upgrade does.
@(private = "file")
diag_connect :: proc(t: ^testing.T, f: ^Diag_Fixture, hello: string) -> int {
	_, gen, ok := project_service.bridge_runtime_registry_accept_live(&f.registry, f.bridge_id, false, "", DIAG_OWNER)
	testing.expect(t, ok, "generation admitted")
	c := project_service.bridge_runtime_connection_acquire(&f.registry, f.bridge_id, gen)
	testing.expect(t, c != nil, "connection acquired")
	if c == nil do return gen
	defer project_service.bridge_runtime_connection_release(&f.registry, c)
	context.allocator = context.temp_allocator // the hello handler's request scope
	project_service.connection_state_lock(c)
	row, hello_ok, _ := bridge_service.bridge_runtime_connect(&f.br_svc, f.bridge_token, "diag-box", "linux", "amd64", hello)
	if hello_ok do bridge_record_hello_metadata(c, hello)
	project_service.connection_state_unlock(c)
	testing.expect(t, hello_ok, "hello accepted")
	domain.bridge_destroy(&row)
	return gen
}

// A snapshot in the exact member order and number formats bridge_diagnostics.odin
// writes (stats on, load1 unsampled).
@(private = "file")
diag_bridge_snapshot :: proc(epoch: string, seq, accepted: int) -> string {
	return fmt.tprintf(`{{"type":"bridge_diagnostics","schema":1,"process_epoch":"%s","sample_seq":%d,"collected_at_ms":1729940000000,"command_dispatch":{{"accepted":%d,"rejected":0,"completed":%d,"deadline_expired":0}},"dependency_breakers":{{"open":0,"opened":1}},"http_retries":{{"retry":3,"recovered":3,"gave_up":0,"deferred":0}},"operation_recovery":{{"rows":[{{"operation":"sync","state":"Backoff","code":"","class":"retriable","receipts":1}}]}},"stats":{{"rss":52428800,"pty_host_rss":10485760,"cpu_s":12.34,"host_mem_total":33554432000,"host_mem_avail":16777216000,"disk_free":50000000000,"instances":[{{"provider":"claude","rss":209715200,"cpu_s":88.10}}]}},"unavailable":["load1"]}}`, epoch, seq, accepted, accepted)
}

// The same Bridge with resource stats off (telemetry opt-out): reliability only.
@(private = "file")
diag_bridge_snapshot_no_stats :: proc(epoch: string, seq: int) -> string {
	return fmt.tprintf(`{{"type":"bridge_diagnostics","schema":1,"process_epoch":"%s","sample_seq":%d,"collected_at_ms":1729940000000,"command_dispatch":{{"accepted":500,"rejected":0,"completed":500,"deadline_expired":0}},"dependency_breakers":{{"open":0,"opened":1}},"http_retries":{{"retry":3,"recovered":3,"gave_up":0,"deferred":0}},"operation_recovery":{{"rows":[]}}}}`, epoch, seq)
}

@(private = "file")
diag_tool_support :: proc(t: ^testing.T, f: ^Diag_Fixture) -> (admission, api: bool) {
	context.allocator = context.temp_allocator
	admission = agent_service.tool_stream_bridge_supported(&f.ag_svc, f.bridge_id)
	row, ok, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	testing.expect(t, ok, "bridge row readable")
	defer domain.bridge_destroy(&row)
	b := strings.builder_make(context.temp_allocator)
	write_bridge_json(&b, row, &f.ag_svc)
	api = strings.contains(strings.to_string(b), `"tool_stream_supported":true`)
	return
}

@(private = "file")
diag_subscribe :: proc(f: ^Diag_Fixture) -> string {
	heap := runtime.heap_allocator()
	scopes := make(map[string]string, heap)
	scopes[strings.clone(DIAG_INSTANCE, heap)] = strings.clone(DIAG_CONVERSATION, heap)
	ids := [1]string{DIAG_INSTANCE}
	result := agent_service.tool_stream_subscribe(&f.ag_svc, &f.viewer, ids[:], scopes)
	if result != "" do agent_service.tool_stream_scopes_free(scopes)
	return result
}

// A Bridge tool_stream_state for the route's current subscription; the first one after
// attach is the fresh baseline.
@(private = "file")
diag_tool_update :: proc(token: string, revision: int, baseline := false) -> string {
	return fmt.tprintf(`{{"type":"tool_stream_state","epoch":"1000","subscription_id":"%s","baseline":%v,"run_count":1,"snapshot":{{"instance_id":"%s","epoch":"1000","generation":1,"revision":%d,"run_count":1,"active":[{{"call_id":"call_live","source":"provider","tool_name":"Bash","summary":"echo live","summary_truncated":false,"shell_session_id":"","started_at_ms":1000}}],"completed_since_last":[]}}}}`, token, baseline, DIAG_INSTANCE, revision)
}

@(private = "file")
diag_queue_has_state :: proc(w: ^agent_service.Tool_Stream_Viewer) -> bool {
	for frame in w.queue {
		if strings.contains(frame.text, `"type":"state"`) && strings.contains(frame.text, `"call_live"`) do return true
	}
	return false
}

@(test)
test_negotiated_bridge_many_beats_and_diagnostics_keep_tool_stream_live :: proc(t: ^testing.T) {
	f := diag_fixture_open(t)
	defer diag_fixture_close(f)

	gen := diag_connect(t, f, diag_hello(DIAG_FEATURES_NEGOTIATING))
	c := project_service.bridge_runtime_connection_acquire(&f.registry, f.bridge_id, gen)
	testing.expect(t, c != nil, "connection live")
	if c == nil do return
	defer project_service.bridge_runtime_connection_release(&f.registry, c)

	// Many beats, a diagnostics snapshot every few: the Bridge's T6 cadence compressed.
	epoch := "pe_000018e1aa000000a1b2c3d4e5f60718"
	seq := 0
	for i in 0 ..< 120 {
		testing.expect_value(t, bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, gen, DIAG_BEAT_CORE), Heartbeat_Metadata_Result.Applied)
		if i % 4 == 0 {
			seq += 1
			testing.expect_value(t, bridge_apply_diagnostics_frame(&f.registry, f.bridge_id, gen, diag_bridge_snapshot(epoch, seq, 100 + i), c), Diagnostics_Frame_Result.Applied)
		}
	}
	// Telemetry opt-out shape and a duplicate are handled without touching liveness.
	seq += 1
	testing.expect_value(t, bridge_apply_diagnostics_frame(&f.registry, f.bridge_id, gen, diag_bridge_snapshot_no_stats(epoch, seq), c), Diagnostics_Frame_Result.Applied)
	testing.expect_value(t, bridge_apply_diagnostics_frame(&f.registry, f.bridge_id, gen, diag_bridge_snapshot_no_stats(epoch, seq), c), Diagnostics_Frame_Result.Stale)

	admission, api := diag_tool_support(t, f)
	testing.expect(t, admission, "live tool admission sees tool_stream_demand_v2 after 120 beats")
	testing.expect(t, api, "capability JSON reports tool_stream_supported after 120 beats")

	// The UI viewer is admitted and the current session's tool update reaches it.
	testing.expect_value(t, diag_subscribe(f), "")
	route := f.ag_svc.tool_live.routes[DIAG_INSTANCE]
	testing.expect(t, route != nil, "route created")
	if route == nil do return
	diag_viewer_clear(&f.viewer)
	testing.expect(t, agent_service.tool_live_apply_bridge(&f.ag_svc, f.bridge_id, gen, "1000", diag_tool_update(route.token, 1, baseline = true)), "current-session update applied")
	testing.expect(t, diag_queue_has_state(&f.viewer), "viewer queue holds the live tool state")
	// Hand the exact delivered viewer frame to the UI consumer test
	// (tests/ui_t6_hub_tool_frame_test.ts) when asked to.
	if out, want := os.lookup_env("HEIMDALL_T6_UI_FRAME_OUT", context.temp_allocator); want {
		for frame in f.viewer.queue {
			if !strings.contains(frame.text, `"type":"state"`) do continue
			_ = os.write_entire_file(out, transmute([]byte)frame.text)
			break
		}
	}

	// More beats after delivery change nothing.
	for _ in 0 ..< 20 do _ = bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, gen, DIAG_BEAT_CORE)
	admission, api = diag_tool_support(t, f)
	testing.expect(t, admission && api, "still supported")
}

@(test)
test_withdrawn_or_old_bridge_tool_stream_fails_closed_after_beats :: proc(t: ^testing.T) {
	f := diag_fixture_open(t)
	defer diag_fixture_close(f)

	gen := diag_connect(t, f, diag_hello(DIAG_FEATURES_NEGOTIATING))
	for _ in 0 ..< 10 do _ = bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, gen, DIAG_BEAT_CORE)
	testing.expect_value(t, diag_subscribe(f), "")
	route := f.ag_svc.tool_live.routes[DIAG_INSTANCE]
	testing.expect(t, route != nil, "route created")
	if route == nil do return

	// Reconnect with a hello that withdraws the feature: hello is a full replacement.
	gen2 := diag_connect(t, f, diag_hello(DIAG_FEATURES_WITHDRAWN))
	for _ in 0 ..< 10 do _ = bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, gen2, DIAG_BEAT_CORE)
	admission, api := diag_tool_support(t, f)
	testing.expect(t, !admission && !api, "withdrawn feature fails closed in admission and API")
	testing.expect_value(t, diag_subscribe(f), "upgrade_required")
	diag_viewer_clear(&f.viewer)
	agent_service.tool_stream_bridge_ready(&f.ag_svc, f.bridge_id, gen2)
	_ = agent_service.tool_live_apply_bridge(&f.ag_svc, f.bridge_id, gen2, "1000", diag_tool_update(route.token, 5))
	testing.expect(t, !diag_queue_has_state(&f.viewer), "no tool state delivered once the feature is withdrawn")

	// An old Bridge whose hello never listed features (and sends legacy-free beats it
	// did not negotiate) stays unsupported.
	gen3 := diag_connect(t, f, diag_hello(""))
	for _ in 0 ..< 10 do _ = bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, gen3, DIAG_BEAT_CORE)
	admission, api = diag_tool_support(t, f)
	testing.expect(t, !admission && !api, "old Bridge without the feature fails closed")
	testing.expect_value(t, diag_subscribe(f), "upgrade_required")
}

// A Bridge restart (new process_epoch, sample_seq back to 1, lower counters) applies as
// a reset; the same epoch with lower counters does not.
@(test)
test_bridge_t6_snapshot_restart_and_regression :: proc(t: ^testing.T) {
	f := diag_fixture_open(t)
	defer diag_fixture_close(f)
	gen := diag_connect(t, f, diag_hello(DIAG_FEATURES_NEGOTIATING))
	c := project_service.bridge_runtime_connection_acquire(&f.registry, f.bridge_id, gen)
	if c == nil do return
	defer project_service.bridge_runtime_connection_release(&f.registry, c)

	testing.expect_value(t, bridge_apply_diagnostics_frame(&f.registry, f.bridge_id, gen, diag_bridge_snapshot("pe_a", 1, 900), c), Diagnostics_Frame_Result.Applied)
	testing.expect_value(t, bridge_apply_diagnostics_frame(&f.registry, f.bridge_id, gen, diag_bridge_snapshot("pe_a", 2, 950), c), Diagnostics_Frame_Result.Applied)
	// Reconnect keeps the epoch; sequence continues.
	gen2 := diag_connect(t, f, diag_hello(DIAG_FEATURES_NEGOTIATING))
	c2 := project_service.bridge_runtime_connection_acquire(&f.registry, f.bridge_id, gen2)
	if c2 == nil do return
	defer project_service.bridge_runtime_connection_release(&f.registry, c2)
	testing.expect_value(t, bridge_apply_diagnostics_frame(&f.registry, f.bridge_id, gen2, diag_bridge_snapshot("pe_a", 3, 960), c2), Diagnostics_Frame_Result.Applied)
	// Restart: new epoch, seq 1, lower counters.
	testing.expect_value(t, bridge_apply_diagnostics_frame(&f.registry, f.bridge_id, gen2, diag_bridge_snapshot("pe_b", 1, 5), c2), Diagnostics_Frame_Result.Applied)
	// Old generation can no longer write.
	testing.expect(t, bridge_apply_diagnostics_frame(&f.registry, f.bridge_id, gen, diag_bridge_snapshot("pe_b", 9, 10), c) != Diagnostics_Frame_Result.Applied, "replaced generation dropped")

	// The emitted shape decodes with every family valid.
	snap: project_service.Bridge_Diagnostics_Snapshot
	testing.expect_value(t, bridge_decode_diagnostics(&snap, diag_bridge_snapshot("pe_b", 2, 6), context.temp_allocator), Diagnostics_Frame_Result.Applied)
	for part in snap.parts do testing.expect(t, part == .Valid, "every family valid")
}
