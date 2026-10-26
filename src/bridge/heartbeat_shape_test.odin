package main

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import "core:sync"
import "core:testing"

// Minimal heartbeat plan T4: the heartbeat honours bridge_ready's
// heartbeat_metadata_omission and diagnostics_frame_v1 independently, per connection.
// No flags keeps the legacy frame (with the complete runtime feature list); metadata
// alone drops only capabilities/features; diagnostics alone drops only the diagnostic
// members; both give the eight-member core of plan §2.1. Instance tuples are always
// the five members the hub decodes, while agent_instance_status keeps
// activity_source/error.
//
// The goldens drive the pure serializer with fixed inputs, so they are byte-exact and
// touch no process state. The live tests hold bridge_test_config_mutex (the
// negotiation flags and stats switch are process globals) and keystore_test_mutex
// (vault status), keep resource stats off (stats fork `ps`), and insert runtime
// instances directly under unique ids, removing them again.

@(private = "file")
SHAPE_LEGACY :: Bridge_Heartbeat_Shape{}
@(private = "file")
SHAPE_METADATA :: Bridge_Heartbeat_Shape{omit_metadata = true}
@(private = "file")
SHAPE_DIAGNOSTICS :: Bridge_Heartbeat_Shape{omit_diagnostics = true}
@(private = "file")
SHAPE_CORE :: Bridge_Heartbeat_Shape{omit_metadata = true, omit_diagnostics = true}

@(private = "file")
GOLDEN_FEATURES :: `["capture_agent_pane","get_agent_pane","instance_reconfiguration_v1","tool_stream_demand_v2","heartbeat_metadata_omission"]`
@(private = "file")
GOLDEN_DISPATCH :: `{"accepted":1,"rejected":0,"completed":1,"deadline_expired":0}`
@(private = "file")
GOLDEN_BREAKERS :: `{"open":0,"opened":0}`
@(private = "file")
GOLDEN_RETRIES :: `{"retry":0,"recovered":0,"gave_up":0,"deferred":0}`
@(private = "file")
GOLDEN_RECOVERY :: `{"rows":[]}`
@(private = "file")
GOLDEN_STATS :: `{"rss":1}`

@(private = "file")
golden_frame :: proc(vault: string, ready, stale: bool, revision: i64, instances: []Bridge_Heartbeat_Instance) -> Bridge_Heartbeat_Frame {
	return Bridge_Heartbeat_Frame{
		vault_status = vault, search_ready = ready, search_stale = stale, search_revision = revision,
		features = GOLDEN_FEATURES,
		command_dispatch = GOLDEN_DISPATCH, dependency_breakers = GOLDEN_BREAKERS,
		http_retries = GOLDEN_RETRIES, operation_recovery = GOLDEN_RECOVERY, stats = GOLDEN_STATS,
		instances = instances,
	}
}

@(private = "file")
expect_golden :: proc(t: ^testing.T, frame: Bridge_Heartbeat_Frame, shape: Bridge_Heartbeat_Shape, want: string, loc := #caller_location) {
	got := bridge_heartbeat_frame_json(frame, shape)
	defer delete(got)
	testing.expect_value(t, got, want, loc)
	// Every golden is valid JSON with nothing trailing.
	value, err := json.parse_string(got, .JSON, true, context.temp_allocator)
	testing.expect_value(t, err, json.Error.None, loc)
	_, is_obj := value.(json.Object)
	testing.expect(t, is_obj, "heartbeat is a JSON object", loc = loc)
}

@(test)
test_heartbeat_golden_core_matches_plan_examples :: proc(t: ^testing.T) {
	// Plan §2.1: idle Bridge, no instances. Both arrays stay present when empty.
	expect_golden(t, golden_frame("locked", false, false, 0, nil), SHAPE_CORE,
		`{"type":"bridge_heartbeat","protocol_version":1,"vault_status":"locked","task_chain_search_ready":false,"task_chain_search_stale":false,"task_chain_search_revision":0,"active_instance_ids":[],"instances":[]}`)

	// Plan §2.1: two running agents.
	running := []Bridge_Heartbeat_Instance{
		{agent_instance_id = "inst_18e1aa00000000a1", launch_epoch = "ep_18e1aa0000000001", state_seq = 1729940000123, runtime_status = "running", activity_status = "busy"},
		{agent_instance_id = "inst_18e1aa00000000b2", launch_epoch = "ep_18e1aa0000000002", state_seq = 1729940000456, runtime_status = "running", activity_status = "idle"},
	}
	expect_golden(t, golden_frame("unlocked", true, false, 412, running), SHAPE_CORE,
		`{"type":"bridge_heartbeat","protocol_version":1,"vault_status":"unlocked","task_chain_search_ready":true,"task_chain_search_stale":false,"task_chain_search_revision":412,` +
		`"active_instance_ids":["inst_18e1aa00000000a1","inst_18e1aa00000000b2"],` +
		`"instances":[` +
		`{"agent_instance_id":"inst_18e1aa00000000a1","launch_epoch":"ep_18e1aa0000000001","state_seq":1729940000123,"runtime_status":"running","activity_status":"busy"},` +
		`{"agent_instance_id":"inst_18e1aa00000000b2","launch_epoch":"ep_18e1aa0000000002","state_seq":1729940000456,"runtime_status":"running","activity_status":"idle"}]}`)

	// Plan §2.1: terminal status repair. The failed instance is not active but its
	// tuple still recurs; a status-less entry is never reported.
	terminal := []Bridge_Heartbeat_Instance{
		{agent_instance_id = "inst_18e1aa00000000a1", launch_epoch = "ep_18e1aa0000000001", state_seq = 1729940009001, runtime_status = "failed", activity_status = "idle"},
		{agent_instance_id = "inst_18e1aa00000000b2", launch_epoch = "ep_18e1aa0000000002", state_seq = 1729940000456, runtime_status = "running", activity_status = "idle"},
		{agent_instance_id = "inst_18e1aa00000000c3", runtime_status = " "},
	}
	expect_golden(t, golden_frame("unlocked", true, true, 412, terminal), SHAPE_CORE,
		`{"type":"bridge_heartbeat","protocol_version":1,"vault_status":"unlocked","task_chain_search_ready":true,"task_chain_search_stale":true,"task_chain_search_revision":412,` +
		`"active_instance_ids":["inst_18e1aa00000000b2"],` +
		`"instances":[` +
		`{"agent_instance_id":"inst_18e1aa00000000a1","launch_epoch":"ep_18e1aa0000000001","state_seq":1729940009001,"runtime_status":"failed","activity_status":"idle"},` +
		`{"agent_instance_id":"inst_18e1aa00000000b2","launch_epoch":"ep_18e1aa0000000002","state_seq":1729940000456,"runtime_status":"running","activity_status":"idle"}]}`)
}

@(test)
test_heartbeat_golden_each_flag_is_independent :: proc(t: ^testing.T) {
	instances := []Bridge_Heartbeat_Instance{
		{agent_instance_id = "inst_a", launch_epoch = "ep_a", state_seq = 7, runtime_status = "running", activity_status = "busy"},
	}
	frame := golden_frame("unlocked", true, false, 9, instances)
	HEAD :: `{"type":"bridge_heartbeat","protocol_version":1,"vault_status":"unlocked","task_chain_search_ready":true,"task_chain_search_stale":false,"task_chain_search_revision":9`
	METADATA :: `,"capabilities":[],"features":` + GOLDEN_FEATURES
	DIAGNOSTICS :: `,"command_dispatch":` + GOLDEN_DISPATCH + `,"dependency_breakers":` + GOLDEN_BREAKERS + `,"http_retries":` + GOLDEN_RETRIES + `,"operation_recovery":` + GOLDEN_RECOVERY + `,"stats":` + GOLDEN_STATS
	TAIL :: `,"active_instance_ids":["inst_a"],"instances":[{"agent_instance_id":"inst_a","launch_epoch":"ep_a","state_seq":7,"runtime_status":"running","activity_status":"busy"}]}`

	// No flags: the legacy frame, complete feature list and every diagnostic member.
	expect_golden(t, frame, SHAPE_LEGACY, HEAD + METADATA + DIAGNOSTICS + TAIL)
	// Metadata flag alone removes only capabilities/features.
	expect_golden(t, frame, SHAPE_METADATA, HEAD + DIAGNOSTICS + TAIL)
	// Diagnostics omission alone removes only the diagnostic members.
	expect_golden(t, frame, SHAPE_DIAGNOSTICS, HEAD + METADATA + TAIL)
	// Both: the eight-member core.
	expect_golden(t, frame, SHAPE_CORE, HEAD + TAIL)

	// Resource stats switched off: legacy frame simply lacks the optional member.
	frame.stats = ""
	expect_golden(t, frame, SHAPE_LEGACY, HEAD + METADATA + `,"command_dispatch":` + GOLDEN_DISPATCH + `,"dependency_breakers":` + GOLDEN_BREAKERS + `,"http_retries":` + GOLDEN_RETRIES + `,"operation_recovery":` + GOLDEN_RECOVERY + TAIL)

	// The core has exactly eight top-level members.
	core := bridge_heartbeat_frame_json(frame, SHAPE_CORE)
	defer delete(core)
	value, _ := json.parse_string(core, .JSON, true, context.temp_allocator)
	obj, _ := value.(json.Object)
	testing.expect_value(t, len(obj), 8)
}

// ---- live builder ----

@(private = "file")
shape_test_instances_add :: proc(entries: [][2]string) {
	now := bridge_runtime_now_ms()
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	// The table is process-lifetime: never let a test's tracking allocator own it.
	if bridge_runtime_instances == nil do bridge_runtime_instances = make([dynamic]Bridge_Runtime_Instance, runtime.heap_allocator())
	for e in entries {
		inst := Bridge_Runtime_Instance{
			agent_instance_id = strings.clone(e[0]), state_seq = 3,
			runtime_status = strings.clone(e[1]), activity_status = strings.clone("idle"),
			activity_source = strings.clone("hook"), activity_updated_unix_ms = now,
			last_seen_unix_ms = now, start_success_seen = true, pty_process_alive = e[1] == "running",
		}
		if e[1] == "failed" {
			inst.last_error = bridge_error(.agent_launch_failed, .timeout)
			inst.has_last_error = true
		}
		append(&bridge_runtime_instances, inst)
	}
}

@(private = "file")
shape_test_instances_remove :: proc(entries: [][2]string) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for e in entries {
		for i := len(bridge_runtime_instances) - 1; i >= 0; i -= 1 {
			inst := bridge_runtime_instances[i]
			if inst.agent_instance_id != e[0] do continue
			delete(inst.agent_instance_id); delete(inst.runtime_status)
			delete(inst.activity_status); delete(inst.activity_source)
			ordered_remove(&bridge_runtime_instances, i)
		}
	}
}

@(private = "file")
shape_test_parse :: proc(t: ^testing.T, frame: string, loc := #caller_location) -> json.Object {
	value, err := json.parse_string(frame, .JSON, true, context.temp_allocator)
	testing.expect_value(t, err, json.Error.None, loc)
	obj, _ := value.(json.Object)
	return obj
}

@(private = "file")
METADATA_MEMBERS := [?]string{"capabilities", "features"}
@(private = "file")
DIAGNOSTIC_MEMBERS := [?]string{"command_dispatch", "dependency_breakers", "http_retries", "operation_recovery"}
@(private = "file")
CORE_MEMBERS := [?]string{"type", "protocol_version", "vault_status", "task_chain_search_ready", "task_chain_search_stale", "task_chain_search_revision", "active_instance_ids", "instances"}

@(private = "file")
expect_members :: proc(t: ^testing.T, obj: json.Object, metadata, diagnostics: bool, loc := #caller_location) {
	for m in CORE_MEMBERS do testing.expectf(t, m in obj, "core member %s present", m, loc = loc)
	for m in METADATA_MEMBERS do testing.expectf(t, (m in obj) == metadata, "metadata member %s present=%v", m, metadata, loc = loc)
	for m in DIAGNOSTIC_MEMBERS do testing.expectf(t, (m in obj) == diagnostics, "diagnostic member %s present=%v", m, diagnostics, loc = loc)
	want := len(CORE_MEMBERS)
	if metadata do want += len(METADATA_MEMBERS)
	if diagnostics do want += len(DIAGNOSTIC_MEMBERS) // stats are off in these tests
	testing.expect_value(t, len(obj), want, loc)
}

@(test)
test_heartbeat_live_shape_follows_each_connection_ready :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	defer bridge_hub_reset_heartbeat_negotiation()
	defer bridge_hub_set_heartbeat_interval(0)
	defer bridge_heartbeat_stats_set_enabled(true)
	defer sync.atomic_store(&bridge_hub_credential_reauth_supported, false)

	shared := bridge_runtime_features_json()
	check :: proc(t: ^testing.T, ready: string, metadata: bool, shared: string, loc := #caller_location) {
		bridge_hub_reset_heartbeat_negotiation()
		bridge_hub_apply_ready_settings(ready)
		// Stats off after ready, which would otherwise re-enable them.
		bridge_heartbeat_stats_set_enabled(false)
		hb := bridge_hub_heartbeat_json()
		defer delete(hb)
		obj := shape_test_parse(t, hb, loc)
		// Diagnostics stay until this Bridge sends bridge_diagnostics, whatever the
		// hub advertises: nothing disappears before its replacement sender exists.
		expect_members(t, obj, metadata, !BRIDGE_DIAGNOSTICS_SENDER_AVAILABLE || !strings.contains(ready, `"diagnostics_frame_v1":true`), loc)
		if metadata {
			start := strings.index(hb, `"features":`) + len(`"features":`)
			end := strings.index_byte(hb[start:], ']')
			testing.expect_value(t, hb[start:start + end + 1], shared, loc)
		}
	}
	// Ready payloads as the hub nests them under "payload".
	check(t, `{"type":"bridge_ready","payload":{"bridge_id":"brg_x","heartbeat_metadata_omission":false}}`, true, shared)
	check(t, `{"type":"bridge_ready","payload":{"bridge_id":"brg_x","heartbeat_metadata_omission":true}}`, false, shared)
	check(t, `{"type":"bridge_ready","payload":{"bridge_id":"brg_x","diagnostics_frame_v1":true}}`, true, shared)
	check(t, `{"type":"bridge_ready","payload":{"bridge_id":"brg_x","heartbeat_metadata_omission":true,"diagnostics_frame_v1":true}}`, false, shared)
	testing.expect(t, sync.atomic_load(&bridge_hub_diagnostics_frame_v1), "diagnostics flag parsed and recorded")
	testing.expect_value(t, bridge_hub_heartbeat_shape(), Bridge_Heartbeat_Shape{omit_metadata = true, omit_diagnostics = BRIDGE_DIAGNOSTICS_SENDER_AVAILABLE})

	// Reconnect to a downgraded hub that sends neither flag: legacy frame again, with
	// the complete feature list.
	check(t, `{"type":"bridge_ready","payload":{"bridge_id":"brg_x"}}`, true, shared)
	testing.expect(t, !sync.atomic_load(&bridge_hub_heartbeat_metadata_omission), "metadata flag cleared by a ready without it")
	testing.expect(t, !sync.atomic_load(&bridge_hub_diagnostics_frame_v1), "diagnostics flag cleared by a ready without it")

	// A new connection attempt clears what the previous connection negotiated even
	// before (or without) its own bridge_ready.
	bridge_hub_apply_ready_settings(`{"type":"bridge_ready","payload":{"heartbeat_metadata_omission":true,"diagnostics_frame_v1":true}}`)
	bridge_hub_reset_heartbeat_negotiation()
	testing.expect_value(t, bridge_hub_heartbeat_shape(), SHAPE_LEGACY)
}

@(test)
test_heartbeat_live_tuples_drop_source_and_error_but_status_push_keeps_them :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	bridge_heartbeat_stats_set_enabled(false)
	defer bridge_heartbeat_stats_set_enabled(true)

	RUNNING :: "inst_hb_shape_running_7f1c"
	FAILED :: "inst_hb_shape_failed_7f1c"
	entries := [][2]string{{RUNNING, "running"}, {FAILED, "failed"}}
	shape_test_instances_add(entries)
	defer shape_test_instances_remove(entries)

	shapes := [?]Bridge_Heartbeat_Shape{SHAPE_LEGACY, SHAPE_METADATA, SHAPE_DIAGNOSTICS, SHAPE_CORE}
	for shape in shapes {
		hb := bridge_hub_heartbeat_json_shaped(shape)
		defer delete(hb)
		obj := shape_test_parse(t, hb)
		expect_members(t, obj, !shape.omit_metadata, !shape.omit_diagnostics)

		active, _ := obj["active_instance_ids"].(json.Array)
		saw_running_active, saw_failed_active := false, false
		for v in active {
			id, _ := v.(json.String)
			if string(id) == RUNNING do saw_running_active = true
			if string(id) == FAILED do saw_failed_active = true
		}
		testing.expect(t, saw_running_active, "running instance is active")
		testing.expect(t, !saw_failed_active, "terminal instance is not active")

		instances, _ := obj["instances"].(json.Array)
		found := 0
		for v in instances {
			entry, _ := v.(json.Object)
			id, _ := entry["agent_instance_id"].(json.String)
			if string(id) != RUNNING && string(id) != FAILED do continue
			found += 1
			// Exactly the five-member tuple, terminal included.
			testing.expect_value(t, len(entry), 5)
			for m in ([]string{"agent_instance_id", "launch_epoch", "state_seq", "runtime_status", "activity_status"}) {
				testing.expectf(t, m in entry, "tuple member %s present", m)
			}
			status, _ := entry["runtime_status"].(json.String)
			testing.expect_value(t, string(status), "running" if string(id) == RUNNING else "failed")
		}
		testing.expect_value(t, found, 2)
	}

	// The immediate agent_instance_status push still carries activity_source, and the
	// error for the failed instance.
	failed_push := bridge_instance_status_json(FAILED)
	defer delete(failed_push)
	failed_obj := shape_test_parse(t, failed_push)
	source, _ := failed_obj["activity_source"].(json.String)
	testing.expect_value(t, string(source), "hook")
	_, has_error := failed_obj["error"].(json.Object)
	testing.expect(t, has_error, "status push keeps the failure error")

	running_push := bridge_instance_status_json(RUNNING)
	defer delete(running_push)
	running_obj := shape_test_parse(t, running_push)
	testing.expect(t, "activity_source" in running_obj, "status push keeps activity_source")
}
