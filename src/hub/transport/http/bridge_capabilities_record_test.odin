// Behavioral tests for the stored bridges.capabilities_json record and the
// heartbeat row's ownership (the heartbeat arm runs on the WS reader thread,
// which has no per-request arena).
package http

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import bridge_service "odin_test:hub/service/bridge"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"

@(private = "file")
caps_fixture :: struct {
	conn:           sqlite.Conn,
	br_repo_sqlite: sqlite.Bridge_Repo_SQLite,
	br_repo:        iface.Bridge_Repository,
	clock:          platform.Clock,
	ids:            platform.ID_Generator,
	br_svc:         bridge_service.Bridge_Service,
	bridge_id:      string,
	bridge_token:   string,
}

@(private = "file")
caps_fixture_open :: proc(t: ^testing.T) -> ^caps_fixture {
	f := new(caps_fixture)
	conn, open_ok, _ := sqlite.open(":memory:")
	testing.expect(t, open_ok, "sqlite open ok")
	f.conn = conn
	mig_ok, _ := sqlite.run_migrations(&f.conn)
	testing.expect(t, mig_ok, "migrations ok")
	f.br_repo = sqlite.new_bridge_repository(&f.br_repo_sqlite, &f.conn)
	f.clock = platform.real_clock()
	f.ids = http_test_id_generator()
	f.br_svc = bridge_service.new_bridge_service(&f.br_repo, &f.clock, &f.ids)
	enrolled, e_ok, _ := bridge_service.enroll_bridge_from_device_grant(&f.br_svc, bridge_service.Device_Enroll_Input{
		owner_user_id = "usr_caps_owner",
		bridge_public_key = "04approved",
		bridge_key_fingerprint = "aaaa bbbb cccc dddd",
		machine_hostname = "caps-box",
		os_user = "tanmay",
	})
	testing.expect(t, e_ok, "bridge enrolled")
	f.bridge_token = strings.clone(enrolled.bridge_token)
	f.bridge_id = strings.clone(enrolled.bridge.bridge_id)
	return f
}

@(private = "file")
caps_fixture_close :: proc(f: ^caps_fixture) {
	delete(f.bridge_token)
	delete(f.bridge_id)
	sqlite.close(&f.conn)
	free(f)
}

@(private = "file")
CAPS_HELLO :: `{"type":"bridge_hello","protocol_version":1,"hostname":"caps-box","public_key":"04ephemeral","capabilities":[{"provider":"claude","models":[],"default_model":"opus"}],"features":["capture_agent_pane","instance_reconfiguration_v1"],"active_instance_ids":["inst_a"]}`

@(private = "file")
CAPS_HEARTBEAT :: `{"type":"bridge_heartbeat","protocol_version":1,"vault_status":"unlocked","capabilities":[{"provider":"claude","models":[],"default_model":"opus"}],"features":["capture_agent_pane","instance_reconfiguration_v1"],"command_dispatch":{"queued":0},"stats":{"rss":1},"active_instance_ids":["inst_a"],"instances":[{"agent_instance_id":"inst_a","state_seq":7}]}`

// The stored record keeps what its readers use and nothing else: the runtime
// keys from the latest frame, and the enrollment record from approval time —
// which hello and every heartbeat used to overwrite with the whole frame.
@(test)
test_heartbeat_stores_capabilities_record_not_the_frame :: proc(t: ^testing.T) {
	f := caps_fixture_open(t)
	defer caps_fixture_close(f)

	hello_row, hok, _ := bridge_service.bridge_runtime_connect(&f.br_svc, f.bridge_token, "caps-box", "linux", "amd64", CAPS_HELLO)
	testing.expect(t, hok, "hello accepted")
	domain.bridge_destroy(&hello_row)
	beat_row, bok, _ := bridge_service.update_runtime_capabilities(&f.br_svc, f.bridge_id, CAPS_HEARTBEAT)
	testing.expect(t, bok, "heartbeat applied")
	domain.bridge_destroy(&beat_row)

	row, found, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	testing.expect(t, found, "bridge row")
	defer domain.bridge_destroy(&row)
	caps := row.capabilities_json
	for absent in ([]string{"bridge_heartbeat", "instances", "stats", "command_dispatch", "active_instance_ids", "vault_status", "04ephemeral"}) {
		testing.expectf(t, !strings.contains(caps, absent), "stored record omits %s: %s", absent, caps)
	}
	for present in ([]string{`"public_key":"04approved"`, `"enrolled_via":"device_authorization"`, `"os_user":"tanmay"`, `"enrollment_key_fingerprint":"aaaa bbbb cccc dddd"`, `"features":["capture_agent_pane","instance_reconfiguration_v1"]`}) {
		testing.expectf(t, strings.contains(caps, present), "stored record keeps %s: %s", present, caps)
	}
	served := bridge_capabilities_json(row)
	for part in ([]string{`"provider":"claude"`, `"default_model":"opus"`, `"models":[]`}) do testing.expectf(t, strings.contains(served, part), "served capabilities keep %s: %s", part, served)
}

// A row with no enrollment record (pre-device-authorization, or one an earlier
// hub already overwrote) keeps tracking the frame's live key, as before.
@(test)
test_capabilities_record_unenrolled_row_tracks_live_key :: proc(t: ^testing.T) {
	record := bridge_service.bridge_capabilities_record(`{"public_key":"04old","capabilities":[]}`, CAPS_HELLO, context.temp_allocator)
	testing.expect(t, strings.contains(record, `"public_key":"04ephemeral"`), record)
	testing.expect(t, !strings.contains(record, "04old"), record)
	kept := bridge_service.bridge_capabilities_record(`{"public_key":"04old","enrolled_via":"device_authorization"}`, CAPS_HELLO, context.temp_allocator)
	testing.expect(t, strings.contains(kept, `"public_key":"04old"`), kept)
}

// The heartbeat row comes back fully owned: destroying it frees every byte the
// call left on the heap and nothing it does not own. The tracking allocator
// stands in for the WS reader's heap; temp scratch (JSON lookups, clock_now) is
// reclaimed per frame on that thread, so it gets its own arena here.
@(test)
test_update_runtime_capabilities_row_is_fully_owned :: proc(t: ^testing.T) {
	f := caps_fixture_open(t)
	defer caps_fixture_close(f)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, runtime.heap_allocator())
	defer mem.tracking_allocator_destroy(&track)
	temp: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&temp) == nil, "temp arena")
	defer virtual.arena_destroy(&temp)
	{
		context.allocator = mem.tracking_allocator(&track)
		context.temp_allocator = virtual.arena_allocator(&temp)
		row, ok, _ := bridge_service.update_runtime_capabilities(&f.br_svc, f.bridge_id, CAPS_HEARTBEAT)
		testing.expect(t, ok, "heartbeat applied")
		domain.bridge_destroy(&row)
	}
	testing.expectf(t, len(track.bad_free_array) == 0, "destroy freed %d pointers the row did not own", len(track.bad_free_array))
	residue := 0
	for _, entry in track.allocation_map do residue += entry.size
	testing.expectf(t, len(track.allocation_map) == 0, "heartbeat left %d allocations (%d bytes) behind", len(track.allocation_map), residue)
}
