// Behavioral tests for the bridge `status_changed` online publish on runtime connect (REQ-ENR-1).
package http

import bridge_service "odin_test:hub/service/bridge"
import domain "odin_test:hub/domain"
import events "odin_test:hub/service/events"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import "core:strings"
import "core:testing"

@(private = "file")
online_status_fixture :: struct {
	conn: sqlite.Conn,
	br_repo_sqlite: sqlite.Bridge_Repo_SQLite,
	br_repo: iface.Bridge_Repository,
	clock: platform.Clock,
	ids: platform.ID_Generator,
	br_svc: bridge_service.Bridge_Service,
	bus: events.User_Event_Bus,
	bh: Bridge_Handlers,
	bridge_token: string,
}

@(private = "file")
setup_online_status_fixture :: proc(t: ^testing.T) -> ^online_status_fixture {
	f := new(online_status_fixture)
	conn, open_ok, _ := sqlite.open(":memory:")
	testing.expect(t, open_ok, "sqlite open ok")
	f.conn = conn
	mig_ok, _ := sqlite.run_migrations(&f.conn)
	testing.expect(t, mig_ok, "migrations ok")
	f.br_repo = sqlite.new_bridge_repository(&f.br_repo_sqlite, &f.conn)
	f.clock = platform.real_clock()
	f.ids = http_test_id_generator()
	f.br_svc = bridge_service.new_bridge_service(&f.br_repo, &f.clock, &f.ids)
	f.bh = Bridge_Handlers{bridges = &f.br_svc, event_bus = &f.bus}
	enrolled, e_ok, _ := bridge_service.enroll_bridge_from_device_grant(&f.br_svc, bridge_service.Device_Enroll_Input{
		owner_user_id = "usr_online_status_owner",
		bridge_public_key = "04aabb",
		bridge_key_fingerprint = "aaaa bbbb cccc dddd",
		machine_hostname = "online-box",
	})
	testing.expect(t, e_ok, "bridge enrolled")
	// The enroll result is not caller-owned (sibling fixtures clone, never free it).
	f.bridge_token = strings.clone(enrolled.bridge_token)
	return f
}

@(private = "file")
teardown_online_status_fixture :: proc(f: ^online_status_fixture) {
	if f == nil do return
	delete(f.bridge_token)
	sqlite.close(&f.conn)
	free(f)
}

// REQ-ENR-1: the row a runtime connect saves is Online, and publishing it bumps the
// bus exactly once with the same `{"status":"online"}` summary the UI's listBridges
// cache merges (the disconnect path's format, with the other status word).
@(test)
test_runtime_connect_publishes_online_status_once :: proc(t: ^testing.T) {
	f := setup_online_status_fixture(t)
	defer teardown_online_status_fixture(f)

	bridge, ok, err := bridge_service.bridge_runtime_connect(&f.br_svc, f.bridge_token, "online-box", "linux", "amd64", "")
	defer domain.bridge_destroy(&bridge)
	testing.expect(t, ok, "runtime connect accepted")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, bridge.status, domain.Bridge_Status.Online)

	before := f.bus.event_seq
	bridge_publish_online_status(&f.bh, bridge)
	testing.expect_value(t, f.bus.event_seq, before + 1)

	summary := bridge_status_summary_json(domain.bridge_status_string(bridge.status))
	defer delete(summary)
	testing.expect_value(t, summary, `{"status":"online"}`)
}

// REQ-ENR-1: the helper announces Online only. A non-Online row, or one with no owner
// to route to, publishes nothing — so it can never contradict the disconnect path.
@(test)
test_publish_online_status_ignores_non_online_and_ownerless_rows :: proc(t: ^testing.T) {
	f := setup_online_status_fixture(t)
	defer teardown_online_status_fixture(f)

	before := f.bus.event_seq
	for status in ([2]domain.Bridge_Status{.Offline, .Revoked}) {
		bridge_publish_online_status(&f.bh, domain.Bridge{bridge_id = "brg_x", owner_user_id = "usr_online_status_owner", status = status})
	}
	bridge_publish_online_status(&f.bh, domain.Bridge{bridge_id = "brg_x", status = .Online})
	bridge_publish_online_status(nil, domain.Bridge{bridge_id = "brg_x", owner_user_id = "usr_online_status_owner", status = .Online})
	testing.expect_value(t, f.bus.event_seq, before)
}
