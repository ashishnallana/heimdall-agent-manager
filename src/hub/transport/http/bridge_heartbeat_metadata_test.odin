// Behavioral tests for plan T3 (minimal Bridge heartbeat): the hello record is the
// metadata authority. Heartbeat metadata omission is negotiated per connection — the
// Hub's bridge_ready flag is only an advertisement; the Bridge proves support by listing
// the feature in its hello. Negotiated beats never touch the stored record, legacy beats
// from old Bridges still apply, hello is a full replacement (withdrawal, never a union),
// a record lost under a live connection forces resync, and a replaced generation writes
// nothing.
//
// Each case drives a real SQLite bridge row, a real runtime registry connection and the
// two consumers of the record: live tool admission (tool_stream_bridge_supported) and
// the existing bridge capability JSON (write_bridge_json -> tool_stream_supported).
package http

import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import agent_service "odin_test:hub/service/agent"
import bridge_service "odin_test:hub/service/bridge"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import events "odin_test:hub/service/events"
import metrics "odin_test:lib/metrics"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"
import sqlite "odin_test:hub/repository/sqlite"

@(private = "file")
Meta_Fixture :: struct {
	conn:           sqlite.Conn,
	br_repo_sqlite: sqlite.Bridge_Repo_SQLite,
	ag_repo_sqlite: sqlite.Agent_Repo_SQLite,
	br_repo:        iface.Bridge_Repository,
	ag_repo:        iface.Agent_Repository,
	clock:          platform.Clock,
	ids:            platform.ID_Generator,
	br_svc:         bridge_service.Bridge_Service,
	ag_svc:         agent_service.Agent_Service,
	registry:       project_service.Bridge_Runtime_Registry,
	bus:            events.User_Event_Bus,
	bh:             Bridge_Handlers,
	bridge_id:      string,
	bridge_token:   string,
}

@(private = "file")
META_OWNER :: "usr_meta_owner"

// Current Bridge feature list, plus the omission opt-in a T4 Bridge adds.
@(private = "file")
META_FEATURES :: `["capture_agent_pane","get_agent_pane","instance_reconfiguration_v1","tool_stream_demand_v2"]`
@(private = "file")
META_FEATURES_NEGOTIATING :: `["capture_agent_pane","get_agent_pane","instance_reconfiguration_v1","tool_stream_demand_v2","heartbeat_metadata_omission"]`
// The pre-fix heartbeat list: everything but tool_stream_demand_v2.
@(private = "file")
META_FEATURES_STALE :: `["capture_agent_pane","get_agent_pane","instance_reconfiguration_v1"]`

@(private = "file")
META_BEAT_MINIMAL :: `{"type":"bridge_heartbeat","protocol_version":1,"vault_status":"unlocked","task_chain_search_ready":false,"task_chain_search_stale":false,"task_chain_search_revision":0,"active_instance_ids":[],"instances":[]}`

@(private = "file")
meta_hello :: proc(features: string) -> string {
	if features == "" do return `{"type":"bridge_hello","protocol_version":2,"hostname":"meta-box","capabilities":[],"active_instance_ids":[]}`
	return fmt.tprintf(`{{"type":"bridge_hello","protocol_version":2,"hostname":"meta-box","capabilities":[],"features":%s,"active_instance_ids":[]}}`, features)
}

@(private = "file")
meta_legacy_beat :: proc(features: string) -> string {
	return fmt.tprintf(`{{"type":"bridge_heartbeat","protocol_version":1,"vault_status":"unlocked","capabilities":[],"features":%s,"active_instance_ids":[],"instances":[]}}`, features)
}

@(private = "file")
meta_fixture_open :: proc(t: ^testing.T) -> ^Meta_Fixture {
	f := new(Meta_Fixture)
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
		owner_user_id = META_OWNER,
		bridge_public_key = "04approved",
		bridge_key_fingerprint = "aaaa bbbb cccc dddd",
		machine_hostname = "meta-box",
		os_user = "tanmay",
	})
	testing.expect(t, e_ok, "bridge enrolled")
	f.bridge_id = strings.clone(enrolled.bridge.bridge_id)
	f.bridge_token = strings.clone(enrolled.bridge_token)
	return f
}

@(private = "file")
meta_fixture_close :: proc(f: ^Meta_Fixture) {
	project_service.bridge_runtime_registry_destroy(&f.registry)
	delete(f.bridge_id)
	delete(f.bridge_token)
	sqlite.close(&f.conn)
	free(f)
}

// meta_connect admits a new generation and runs its hello exactly as the WS upgrade
// does: durable record and connection contract written under the state lock.
@(private = "file")
meta_connect :: proc(t: ^testing.T, f: ^Meta_Fixture, hello: string) -> int {
	_, gen, ok := project_service.bridge_runtime_registry_accept_live(&f.registry, f.bridge_id, false, "", META_OWNER)
	testing.expect(t, ok, "generation admitted")
	meta_hello_on(t, f, gen, hello)
	return gen
}

@(private = "file")
meta_hello_on :: proc(t: ^testing.T, f: ^Meta_Fixture, gen: int, hello: string) {
	c := project_service.bridge_runtime_connection_acquire(&f.registry, f.bridge_id, gen)
	testing.expect(t, c != nil, "connection acquired")
	if c == nil do return
	defer project_service.bridge_runtime_connection_release(&f.registry, c)
	context.allocator = context.temp_allocator // the hello handler's request scope
	project_service.connection_state_lock(c)
	row, ok, _ := bridge_service.bridge_runtime_connect(&f.br_svc, f.bridge_token, "meta-box", "linux", "amd64", hello)
	if ok do bridge_record_hello_metadata(c, hello)
	project_service.connection_state_unlock(c)
	testing.expect(t, ok, "hello accepted")
	domain.bridge_destroy(&row)
}

@(private = "file")
meta_record :: proc(t: ^testing.T, f: ^Meta_Fixture) -> string {
	row, ok, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	testing.expect(t, ok, "bridge row readable")
	defer domain.bridge_destroy(&row)
	return strings.clone(row.capabilities_json, context.temp_allocator)
}

// The two consumers of the stored record: live tool admission and the existing bridge
// capability JSON (GET /bridges, GET /bridges/{id}).
@(private = "file")
meta_tool_support :: proc(t: ^testing.T, f: ^Meta_Fixture) -> (admission, api: bool) {
	context.allocator = context.temp_allocator // a request arena in production
	admission = agent_service.tool_stream_bridge_supported(&f.ag_svc, f.bridge_id)
	row, ok, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	testing.expect(t, ok, "bridge row readable")
	defer domain.bridge_destroy(&row)
	b := strings.builder_make(context.temp_allocator)
	write_bridge_json(&b, row, &f.ag_svc)
	body := strings.to_string(b)
	api = strings.contains(body, `"tool_stream_supported":true`)
	testing.expectf(t, api || strings.contains(body, `"tool_stream_supported":false`), "capability JSON carries tool_stream_supported: %s", body)
	return
}

@(private = "file")
meta_connection_negotiated :: proc(f: ^Meta_Fixture, gen: int) -> bool {
	c := project_service.bridge_runtime_connection_acquire(&f.registry, f.bridge_id, gen)
	if c == nil do return false
	defer project_service.bridge_runtime_connection_release(&f.registry, c)
	project_service.connection_state_lock(c)
	defer project_service.connection_state_unlock(c)
	return c.metadata_recorded && c.metadata_omission
}

// The runtime ready frame advertises omission; the enroll-only socket (default) does not.
@(test)
test_bridge_ready_advertises_heartbeat_metadata_omission :: proc(t: ^testing.T) {
	runtime_ready := bridge_ready_payload("brg_x", 3, false, "etag", true, BRIDGE_HUB_HEARTBEAT_METADATA_OMISSION)
	defer delete(runtime_ready)
	testing.expect(t, strings.contains(runtime_ready, `"heartbeat_metadata_omission":true`), runtime_ready)
	enroll_ready := bridge_ready_payload("brg_x", 3, false, "")
	defer delete(enroll_ready)
	testing.expect(t, strings.contains(enroll_ready, `"heartbeat_metadata_omission":false`), enroll_ready)
}

// Negotiated connection: repeated metadata-free beats — and a beat that still carries a
// stale legacy list — leave the hello features in place for admission and the API.
@(test)
test_negotiated_metadata_free_beats_keep_hello_features :: proc(t: ^testing.T) {
	f := meta_fixture_open(t)
	defer meta_fixture_close(f)
	gen := meta_connect(t, f, meta_hello(META_FEATURES_NEGOTIATING))
	testing.expect(t, meta_connection_negotiated(f, gen), "hello listing the feature + hub advertisement => negotiated")
	hello_record := meta_record(t, f)
	admission, api := meta_tool_support(t, f)
	testing.expect(t, admission && api, "hello installed tool_stream_demand_v2")

	seq := f.bus.event_seq
	for _ in 0 ..< 5 {
		testing.expect_value(t, bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, gen, META_BEAT_MINIMAL), Heartbeat_Metadata_Result.Applied)
	}
	// A negotiated Bridge's beat is never metadata authority, even if it carries some.
	testing.expect_value(t, bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, gen, meta_legacy_beat(META_FEATURES_STALE)), Heartbeat_Metadata_Result.Applied)
	testing.expect_value(t, meta_record(t, f), hello_record)
	testing.expect_value(t, f.bus.event_seq, seq)
	admission, api = meta_tool_support(t, f)
	testing.expect(t, admission, "live tool admission still sees the hello feature")
	testing.expect(t, api, "capability API still reports tool_stream_supported")
}

// Old Bridge x new Hub: the ready flag went out, but the hello did not list the feature,
// so nothing is negotiated. Legacy beat metadata keeps full-replacement authority (a
// withdrawing list fails closed, a complete one restores), and a beat that omits it
// without negotiation changes nothing and is not treated as negotiated.
@(test)
test_unnegotiated_bridge_keeps_legacy_heartbeat_metadata :: proc(t: ^testing.T) {
	f := meta_fixture_open(t)
	defer meta_fixture_close(f)
	gen := meta_connect(t, f, meta_hello(META_FEATURES))
	testing.expect(t, !meta_connection_negotiated(f, gen), "a ready advertisement alone is not negotiation")

	for _ in 0 ..< 3 do testing.expect_value(t, bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, gen, meta_legacy_beat(META_FEATURES)), Heartbeat_Metadata_Result.Applied)
	admission, api := meta_tool_support(t, f)
	testing.expect(t, admission && api, "legacy beats with the full list keep support")

	testing.expect_value(t, bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, gen, meta_legacy_beat(META_FEATURES_STALE)), Heartbeat_Metadata_Result.Applied)
	admission, api = meta_tool_support(t, f)
	testing.expect(t, !admission && !api, "legacy withdrawal still applies and fails closed")

	// Unsupported omission: no write, no resync (the record matches what this
	// connection last installed), and the legacy path stays in force.
	before := meta_record(t, f)
	testing.expect_value(t, bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, gen, META_BEAT_MINIMAL), Heartbeat_Metadata_Result.Applied)
	testing.expect_value(t, meta_record(t, f), before)
	testing.expect_value(t, bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, gen, meta_legacy_beat(META_FEATURES)), Heartbeat_Metadata_Result.Applied)
	admission, api = meta_tool_support(t, f)
	testing.expect(t, admission && api, "legacy restore after an unnegotiated omission")
}

// Hello is a full replacement per connection: a reconnect whose hello withdraws a
// feature (or omits features entirely) never inherits the previous connection's list.
@(test)
test_hello_full_replacement_withdraws_features :: proc(t: ^testing.T) {
	f := meta_fixture_open(t)
	defer meta_fixture_close(f)
	_ = meta_connect(t, f, meta_hello(META_FEATURES_NEGOTIATING))
	admission, api := meta_tool_support(t, f)
	testing.expect(t, admission && api, "first connection supports tool streams")

	gen2 := meta_connect(t, f, meta_hello(META_FEATURES_STALE))
	admission, api = meta_tool_support(t, f)
	testing.expect(t, !admission && !api, "downgraded hello withdraws tool_stream_demand_v2")
	testing.expect(t, !meta_connection_negotiated(f, gen2), "withdrawn omission feature is no longer negotiated")

	gen3 := meta_connect(t, f, meta_hello(""))
	record := meta_record(t, f)
	testing.expect(t, strings.contains(record, `"features":[]`), record)
	testing.expect(t, strings.contains(record, `"enrolled_via":"device_authorization"`), record)
	admission, api = meta_tool_support(t, f)
	testing.expect(t, !admission && !api, "hello without features withdraws all")
	// The explicit empty list is this connection's expectation: no spurious resync.
	testing.expect_value(t, bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, gen3, META_BEAT_MINIMAL), Heartbeat_Metadata_Result.Applied)
}

// Metadata lost or rewritten under a surviving connection (DB restore, a record written
// by something other than this connection's hello) fails closed: admission and the API
// stop reporting support, and the next beat demands resync. Through the real frame
// dispatcher the beat is refused (connection closed) and counted.
@(test)
test_metadata_loss_under_live_connection_requires_resync :: proc(t: ^testing.T) {
	f := meta_fixture_open(t)
	defer meta_fixture_close(f)
	gen := meta_connect(t, f, meta_hello(META_FEATURES_NEGOTIATING))
	testing.expect_value(t, bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, gen, META_BEAT_MINIMAL), Heartbeat_Metadata_Result.Applied)

	// Loss: the record keeps only the enrollment keys.
	_ = sqlite.exec(&f.conn, fmt.tprintf(`UPDATE bridges SET capabilities_json = '{{"public_key":"04approved","enrolled_via":"device_authorization"}}' WHERE bridge_id = '%s';`, f.bridge_id))
	admission, api := meta_tool_support(t, f)
	testing.expect(t, !admission && !api, "lost metadata fails closed")
	testing.expect_value(t, bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, gen, META_BEAT_MINIMAL), Heartbeat_Metadata_Result.Resync_Required)

	// The frame dispatcher refuses the beat (closing the connection) and counts it.
	reassemblies: [dynamic]Bridge_Chunk_Reassembly
	defer delete(reassemblies)
	project_service.fleet_metrics_init(metrics.init_global())
	label := HEARTBEAT_METADATA_REJECT_RESYNC
	rejected := metrics.counter_value(metrics.with(project_service.fleet_metrics.bridge_frames_rejected, label))
	c := project_service.bridge_runtime_connection_acquire(&f.registry, f.bridge_id, gen)
	testing.expect(t, !bridge_ws_process_frame(&f.bh, f.bridge_id, gen, net.TCP_Socket(0), &reassemblies, strings.clone(META_BEAT_MINIMAL), c), "resync beat closes the connection")
	project_service.bridge_runtime_connection_release(&f.registry, c)
	testing.expect_value(t, metrics.counter_value(metrics.with(project_service.fleet_metrics.bridge_frames_rejected, label)), rejected + 1)

	// Rewrite: a restored record from an older connection (stale list) also resyncs, even
	// though `features` is present.
	_ = sqlite.exec(&f.conn, fmt.tprintf(`UPDATE bridges SET capabilities_json = '{{"capabilities":[],"features":%s}}' WHERE bridge_id = '%s';`, META_FEATURES_STALE, f.bridge_id))
	testing.expect_value(t, bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, gen, META_BEAT_MINIMAL), Heartbeat_Metadata_Result.Resync_Required)

	// The resync itself: the reconnect's hello reinstalls the record.
	gen2 := meta_connect(t, f, meta_hello(META_FEATURES_NEGOTIATING))
	testing.expect_value(t, bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, gen2, META_BEAT_MINIMAL), Heartbeat_Metadata_Result.Applied)
	admission, api = meta_tool_support(t, f)
	testing.expect(t, admission && api, "fresh hello restores support")

	// An unnegotiated connection that omits metadata after loss also resyncs.
	gen3 := meta_connect(t, f, meta_hello(META_FEATURES))
	_ = sqlite.exec(&f.conn, fmt.tprintf(`UPDATE bridges SET capabilities_json = '{{}}' WHERE bridge_id = '%s';`, f.bridge_id))
	testing.expect_value(t, bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, gen3, META_BEAT_MINIMAL), Heartbeat_Metadata_Result.Resync_Required)
	// ...while its legacy beat repairs the record instead.
	testing.expect_value(t, bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, gen3, meta_legacy_beat(META_FEATURES)), Heartbeat_Metadata_Result.Applied)
	admission, api = meta_tool_support(t, f)
	testing.expect(t, admission && api, "legacy beat repaired the record")
}

// Generation replacement fences every metadata write: a delayed legacy beat from the old
// connection — arriving after the new generation is admitted but before its hello, or
// after its hello — never overwrites the new connection's record or its contract.
@(test)
test_replaced_generation_cannot_overwrite_hello_metadata :: proc(t: ^testing.T) {
	f := meta_fixture_open(t)
	defer meta_fixture_close(f)
	old_gen := meta_connect(t, f, meta_hello(META_FEATURES_STALE)) // old, unnegotiated Bridge

	// New connection admitted; its hello has not run yet.
	_, new_gen, ok := project_service.bridge_runtime_registry_accept_live(&f.registry, f.bridge_id, false, "", META_OWNER)
	testing.expect(t, ok && new_gen != old_gen, "replacement generation admitted")
	before := meta_record(t, f)
	testing.expect_value(t, bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, old_gen, meta_legacy_beat(META_FEATURES)), Heartbeat_Metadata_Result.Stale)
	testing.expect_value(t, meta_record(t, f), before)

	meta_hello_on(t, f, new_gen, meta_hello(META_FEATURES_NEGOTIATING))
	installed := meta_record(t, f)
	testing.expect_value(t, bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, old_gen, meta_legacy_beat(META_FEATURES_STALE)), Heartbeat_Metadata_Result.Stale)
	testing.expect_value(t, bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, old_gen, META_BEAT_MINIMAL), Heartbeat_Metadata_Result.Stale)
	testing.expect_value(t, meta_record(t, f), installed)
	testing.expect(t, meta_connection_negotiated(f, new_gen), "new connection's contract intact")
	testing.expect_value(t, bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, new_gen, META_BEAT_MINIMAL), Heartbeat_Metadata_Result.Applied)
	admission, api := meta_tool_support(t, f)
	testing.expect(t, admission && api, "current generation's hello features exposed")

	// The hello of a retired generation cannot install metadata either (the WS upgrade
	// checks retirement under the same lock before bridge_runtime_connect).
	c := project_service.bridge_runtime_connection_acquire(&f.registry, f.bridge_id, old_gen)
	testing.expect(t, c == nil, "retired generation cannot be acquired for a late hello")
	if c != nil do project_service.bridge_runtime_connection_release(&f.registry, c)
	testing.expect(t, strings.contains(installed, contracts.BRIDGE_FEATURE_HEARTBEAT_METADATA_OMISSION), installed)
}
