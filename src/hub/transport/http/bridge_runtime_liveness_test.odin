// Behavioral tests for plan T1 (minimal Bridge heartbeat): durable Bridge liveness is
// refreshed by EVERY current-generation heartbeat, metadata or not, and every runtime
// Bridge-row write (liveness, legacy capability metadata, vault status, disconnect) is a
// narrow fenced UPDATE that never reverts a concurrent edit or un-revokes a Bridge.
//
// Races are made deterministic with an interposed repository whose get_bridge lets a
// "concurrent" writer commit straight to SQLite AFTER the service has read the row and
// BEFORE it writes — exactly the window the old full-row INSERT … ON CONFLICT save
// silently reverted.
package http

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import bridge_service "odin_test:hub/service/bridge"
import domain "odin_test:hub/domain"
import events "odin_test:hub/service/events"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"
import sqlite "odin_test:hub/repository/sqlite"

@(private = "file")
Live_Clock :: struct {
	unix_seconds: i64, // atomic
}

@(private = "file")
live_clock_now :: proc(ctx: rawptr) -> string {
	c := (^Live_Clock)(ctx)
	return platform.format_rfc3339_utc(time.Time{_nsec = sync.atomic_load(&c.unix_seconds) * 1_000_000_000})
}

// The concurrent writer, run once from inside the interposed get_bridge. Thread-local:
// the test runner executes tests on several threads at once.
@(private = "file", thread_local)
live_race_sql: string

@(private = "file", thread_local)
live_race_conn: ^sqlite.Conn

@(private = "file", thread_local)
live_race_inner: iface.Bridge_Repository

@(private = "file")
live_racing_get :: proc(ctx: rawptr, bridge_id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	row, ok, err := live_race_inner.get_bridge(ctx, bridge_id)
	if live_race_sql != "" {
		sql := live_race_sql
		live_race_sql = ""
		_ = sqlite.exec(live_race_conn, sql)
	}
	return row, ok, err
}

@(private = "file")
Live_Fixture :: struct {
	conn:           sqlite.Conn,
	br_repo_sqlite: sqlite.Bridge_Repo_SQLite,
	br_repo:        iface.Bridge_Repository, // the real repository
	racing_repo:    iface.Bridge_Repository, // same, with a race injected after each read
	clock:          platform.Clock,
	fake:           Live_Clock,
	ids:            platform.ID_Generator,
	br_svc:         bridge_service.Bridge_Service,
	registry:       project_service.Bridge_Runtime_Registry,
	bus:            events.User_Event_Bus,
	bh:             Bridge_Handlers,
	bridge_id:      string,
}

LIVE_T0 :: i64(1_790_000_000)

@(private = "file")
live_fixture_open :: proc(t: ^testing.T) -> ^Live_Fixture {
	f := new(Live_Fixture)
	conn, open_ok, _ := sqlite.open(":memory:")
	testing.expect(t, open_ok, "sqlite open ok")
	f.conn = conn
	mig_ok, _ := sqlite.run_migrations(&f.conn)
	testing.expect(t, mig_ok, "migrations ok")
	f.br_repo = sqlite.new_bridge_repository(&f.br_repo_sqlite, &f.conn)
	f.racing_repo = f.br_repo
	f.racing_repo.get_bridge = live_racing_get
	live_race_inner = f.br_repo
	live_race_conn = &f.conn
	live_race_sql = ""
	f.fake = Live_Clock{unix_seconds = LIVE_T0}
	f.clock = platform.Clock{ctx = rawptr(&f.fake), now = live_clock_now}
	f.ids = http_test_id_generator()
	f.br_svc = bridge_service.new_bridge_service(&f.racing_repo, &f.clock, &f.ids)
	f.bh = Bridge_Handlers{bridges = &f.br_svc, event_bus = &f.bus, bridge_runtime_registry = &f.registry}
	enrolled, e_ok, _ := bridge_service.enroll_bridge_from_device_grant(&f.br_svc, bridge_service.Device_Enroll_Input{
		owner_user_id = "usr_live_owner",
		bridge_public_key = "04approved",
		bridge_key_fingerprint = "aaaa bbbb cccc dddd",
		machine_hostname = "live-box",
		os_user = "tanmay",
	})
	testing.expect(t, e_ok, "bridge enrolled")
	f.bridge_id = strings.clone(enrolled.bridge.bridge_id)
	return f
}

@(private = "file")
live_fixture_close :: proc(f: ^Live_Fixture) {
	live_race_sql = ""
	project_service.bridge_runtime_registry_destroy(&f.registry)
	delete(f.bridge_id)
	sqlite.close(&f.conn)
	free(f)
}

@(private = "file")
live_advance :: proc(f: ^Live_Fixture, seconds: i64) {
	sync.atomic_add(&f.fake.unix_seconds, seconds)
}

@(private = "file")
live_row :: proc(t: ^testing.T, f: ^Live_Fixture) -> domain.Bridge {
	row, ok, _ := iface.bridge_get_bridge(&f.br_repo, f.bridge_id)
	testing.expect(t, ok, "bridge row readable")
	return row
}

@(private = "file")
live_race :: proc(f: ^Live_Fixture, set_clause: string) {
	live_race_sql = fmt.tprintf("UPDATE bridges SET %s WHERE bridge_id = '%s';", set_clause, f.bridge_id)
}

// The minimal (metadata-omitted) heartbeat a negotiated Bridge will send, and the legacy
// one that still carries capability metadata.
@(private = "file")
LIVE_BEAT_MINIMAL :: `{"type":"bridge_heartbeat","protocol_version":1,"vault_status":"unlocked","task_chain_search_ready":false,"task_chain_search_stale":false,"task_chain_search_revision":0,"active_instance_ids":[],"instances":[]}`

@(private = "file")
LIVE_BEAT_LEGACY :: `{"type":"bridge_heartbeat","protocol_version":1,"vault_status":"unlocked","capabilities":[{"provider":"claude","models":[],"default_model":"opus"}],"features":["capture_agent_pane","tool_stream_demand_v2"],"active_instance_ids":[],"instances":[]}`

// A heartbeat WITHOUT capability metadata refreshes durable Online/last_seen_at. Before
// T1 it refreshed nothing (liveness rode on the capabilities save), so an idle Bridge
// sending minimal beats aged past the 1h gone-bridge reaper. Simulated over >1h of
// 45s beats on a fake clock — no real waiting.
@(test)
test_minimal_heartbeat_refreshes_bridge_liveness_over_idle_hour :: proc(t: ^testing.T) {
	f := live_fixture_open(t)
	defer live_fixture_close(f)

	// Disconnected before the beats start, so the first beat must also flip status.
	_, _ = iface.bridge_update_runtime(&f.br_repo, .Offline, f.bridge_id, "2026-01-01T00:00:00Z")
	for _ in 0 ..< 82 { // 82 * 45s = 61.5 minutes
		live_advance(f, 45)
		bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, 0, LIVE_BEAT_MINIMAL)
	}
	row := live_row(t, f)
	defer domain.bridge_destroy(&row)
	now := platform.clock_now(&f.clock)
	testing.expect_value(t, row.status, domain.Bridge_Status.Online)
	testing.expect_value(t, row.last_seen_at, now)
	// What the reaper reads: the absence marker is the latest beat, not the hour-old one.
	marker, eligible := bridge_service.bridge_absence_marker(&f.br_svc, f.bridge_id)
	defer delete(marker)
	testing.expect(t, eligible, "bridge eligible for the absence sweep")
	testing.expect_value(t, marker, now)
	testing.expect(t, !strings.contains(row.capabilities_json, "tool_stream_demand_v2"), "a minimal beat never writes metadata")
}

// An unchanged beat publishes nothing and writes no capability/vault value; only a real
// change of status, metadata or vault status is news.
@(test)
test_unchanged_heartbeat_metadata_publishes_nothing :: proc(t: ^testing.T) {
	f := live_fixture_open(t)
	defer live_fixture_close(f)

	bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, 0, LIVE_BEAT_LEGACY)
	bridge_apply_vault_status_report(&f.bh, f.bridge_id, LIVE_BEAT_LEGACY)
	settled := f.bus.event_seq
	first := live_row(t, f)
	defer domain.bridge_destroy(&first)
	testing.expect(t, strings.contains(first.capabilities_json, "tool_stream_demand_v2"), first.capabilities_json)
	testing.expect(t, strings.contains(first.capabilities_json, `"enrolled_via":"device_authorization"`), "enrollment record kept")

	for _ in 0 ..< 5 {
		live_advance(f, 45)
		bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, 0, LIVE_BEAT_LEGACY)
		bridge_apply_vault_status_report(&f.bh, f.bridge_id, LIVE_BEAT_LEGACY)
		bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, 0, LIVE_BEAT_MINIMAL)
	}
	testing.expect_value(t, f.bus.event_seq, settled)
	again := live_row(t, f)
	defer domain.bridge_destroy(&again)
	testing.expect_value(t, again.capabilities_json, first.capabilities_json)
	testing.expect_value(t, again.last_seen_at, platform.clock_now(&f.clock))
	// The metadata and vault writes themselves report no row change.
	caps_changed, _ := bridge_service.update_runtime_metadata(&f.br_svc, f.bridge_id, LIVE_BEAT_LEGACY)
	testing.expect(t, !caps_changed, "identical metadata writes nothing")
	vault_written, _ := iface.bridge_update_runtime(&f.br_repo, .Vault_Status, f.bridge_id, "x", "unlocked")
	testing.expect(t, !vault_written, "identical vault status writes nothing")

	// A real feature withdrawal is published exactly once.
	bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, 0, `{"type":"bridge_heartbeat","capabilities":[],"features":["capture_agent_pane"]}`)
	testing.expect_value(t, f.bus.event_seq, settled + 1)
}

// Label, token rotation, telemetry and enrollment edits that land between a runtime
// write's read and its write survive it. Each of these was reverted by the full-row save.
@(test)
test_runtime_writes_preserve_concurrent_bridge_edits :: proc(t: ^testing.T) {
	f := live_fixture_open(t)
	defer live_fixture_close(f)

	EDIT :: "label = 'renamed-by-user', label_is_user_customized = '1', bridge_token_hash = 'rotated-hash', telemetry_enabled = 'disabled', enrollment_pending_until = ''"
	check :: proc(t: ^testing.T, f: ^Live_Fixture, step: string) {
		row := live_row(t, f)
		defer domain.bridge_destroy(&row)
		testing.expectf(t, row.label == "renamed-by-user" && row.label_is_user_customized, "%s: label kept, got %q", step, row.label)
		testing.expectf(t, row.bridge_token_hash == "rotated-hash", "%s: rotated token hash kept, got %q", step, row.bridge_token_hash)
		testing.expectf(t, row.telemetry_enabled == "disabled", "%s: telemetry toggle kept, got %q", step, row.telemetry_enabled)
	}

	live_race(f, EDIT)
	_, _, err := bridge_service.touch_runtime_liveness(&f.br_svc, f.bridge_id)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	check(t, f, "liveness")

	// Vault flip racing token rotation + telemetry toggle: both survive, flip lands.
	live_race(f, "bridge_token_hash = 'rotated-again', telemetry_enabled = 'enabled'")
	vrow, vchanged, _ := bridge_service.update_vault_status(&f.br_svc, f.bridge_id, "locked")
	domain.bridge_destroy(&vrow)
	testing.expect(t, vchanged, "vault flip applied")
	{
		row := live_row(t, f)
		defer domain.bridge_destroy(&row)
		testing.expect_value(t, row.vault_status, "locked")
		testing.expect_value(t, row.bridge_token_hash, "rotated-again")
		testing.expect_value(t, row.telemetry_enabled, "enabled")
		testing.expect_value(t, row.label, "renamed-by-user")
	}

	// Metadata racing an enrollment-record change: compare-and-set skips our write
	// rather than erase the newer record; the next beat re-derives from it.
	live_race(f, `capabilities_json = '{"public_key":"04rekeyed","enrolled_via":"device_authorization"}'`)
	changed, _ := bridge_service.update_runtime_metadata(&f.br_svc, f.bridge_id, LIVE_BEAT_LEGACY)
	testing.expect(t, !changed, "stale-derived metadata is not written over a concurrent change")
	{
		row := live_row(t, f)
		defer domain.bridge_destroy(&row)
		testing.expect_value(t, row.capabilities_json, `{"public_key":"04rekeyed","enrolled_via":"device_authorization"}`)
	}
	changed, _ = bridge_service.update_runtime_metadata(&f.br_svc, f.bridge_id, LIVE_BEAT_LEGACY)
	testing.expect(t, changed, "next beat applies on top of the new record")
	{
		row := live_row(t, f)
		defer domain.bridge_destroy(&row)
		testing.expect(t, strings.contains(row.capabilities_json, `"public_key":"04rekeyed"`), row.capabilities_json)
		testing.expect(t, strings.contains(row.capabilities_json, "tool_stream_demand_v2"), row.capabilities_json)
	}

	// Disconnect racing a rename: offline lands, the rename survives.
	live_race(f, "label = 'renamed-twice'")
	orow, ochanged, _ := bridge_service.mark_bridge_offline(&f.br_svc, f.bridge_id)
	domain.bridge_destroy(&orow)
	testing.expect(t, ochanged, "offline applied")
	row := live_row(t, f)
	defer domain.bridge_destroy(&row)
	testing.expect_value(t, row.status, domain.Bridge_Status.Offline)
	testing.expect_value(t, row.label, "renamed-twice")
	testing.expect_value(t, row.bridge_token_hash, "rotated-again")
}

// A revoke that lands between a runtime write's read and its write stays revoked: no
// liveness, metadata, vault or offline write may resurrect or alter it.
@(test)
test_revoke_racing_heartbeat_stays_revoked :: proc(t: ^testing.T) {
	f := live_fixture_open(t)
	defer live_fixture_close(f)
	REVOKE :: "status = 'revoked', revoked_at = '2026-01-01T00:00:00Z'"

	before := live_row(t, f)
	defer domain.bridge_destroy(&before)
	live_advance(f, 45)

	live_race(f, REVOKE)
	_, _, err := bridge_service.touch_runtime_liveness(&f.br_svc, f.bridge_id)
	testing.expect_value(t, err.code, domain.Error_Code.Bridge_Revoked)
	seq := f.bus.event_seq
	bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, 0, LIVE_BEAT_LEGACY)
	bridge_apply_vault_status_report(&f.bh, f.bridge_id, `{"type":"bridge_vault_status","vault_status":"locked"}`)
	_, offline_changed, _ := bridge_service.mark_bridge_offline(&f.br_svc, f.bridge_id)
	testing.expect(t, !offline_changed, "offline never overwrites revoked")
	testing.expect_value(t, f.bus.event_seq, seq)

	row := live_row(t, f)
	defer domain.bridge_destroy(&row)
	testing.expect_value(t, row.status, domain.Bridge_Status.Revoked)
	testing.expect_value(t, row.last_seen_at, before.last_seen_at)
	testing.expect_value(t, row.vault_status, before.vault_status)
	testing.expect_value(t, row.capabilities_json, before.capabilities_json)

	// Revoked between the vault read and write as well (row was live when read).
	g := live_fixture_open(t)
	defer live_fixture_close(g)
	live_race(g, REVOKE)
	vrow, vchanged, _ := bridge_service.update_vault_status(&g.br_svc, g.bridge_id, "unlocked")
	domain.bridge_destroy(&vrow)
	testing.expect(t, !vchanged, "vault write fenced by revoke")
	grow := live_row(t, g)
	defer domain.bridge_destroy(&grow)
	testing.expect_value(t, grow.status, domain.Bridge_Status.Revoked)
	testing.expect_value(t, grow.vault_status, "")
	// Offline racing a revoke.
	h := live_fixture_open(t)
	defer live_fixture_close(h)
	_, _, _ = bridge_service.touch_runtime_liveness(&h.br_svc, h.bridge_id)
	live_race(h, REVOKE)
	_, hchanged, _ := bridge_service.mark_bridge_offline(&h.br_svc, h.bridge_id)
	testing.expect(t, !hchanged, "offline fenced by revoke")
	hrow := live_row(t, h)
	defer domain.bridge_destroy(&hrow)
	testing.expect_value(t, hrow.status, domain.Bridge_Status.Revoked)
}

// A heartbeat (or vault report) from a connection generation that has been replaced
// writes nothing durable: a delayed old frame cannot land after the new hello.
@(test)
test_delayed_old_generation_cannot_write_bridge_row :: proc(t: ^testing.T) {
	f := live_fixture_open(t)
	defer live_fixture_close(f)

	_, old_gen, ok := project_service.bridge_runtime_registry_accept_live(&f.registry, f.bridge_id, false, "", "usr_live_owner")
	testing.expect(t, ok, "first generation admitted")
	_, new_gen, ok2 := project_service.bridge_runtime_registry_accept_live(&f.registry, f.bridge_id, false, "", "usr_live_owner")
	testing.expect(t, ok2 && new_gen != old_gen, "replacement generation admitted")

	_, _ = iface.bridge_update_runtime(&f.br_repo, .Offline, f.bridge_id, "2026-01-01T00:00:00Z")
	before := live_row(t, f)
	defer domain.bridge_destroy(&before)
	seq := f.bus.event_seq
	live_advance(f, 45)

	bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, old_gen, LIVE_BEAT_LEGACY)
	bridge_apply_vault_status_report(&f.bh, f.bridge_id, LIVE_BEAT_LEGACY, old_gen)
	stale := live_row(t, f)
	defer domain.bridge_destroy(&stale)
	testing.expect_value(t, stale.status, before.status)
	testing.expect_value(t, stale.last_seen_at, before.last_seen_at)
	testing.expect_value(t, stale.capabilities_json, before.capabilities_json)
	testing.expect_value(t, stale.vault_status, before.vault_status)
	testing.expect_value(t, f.bus.event_seq, seq)

	// The current generation's identical frame does land.
	bridge_apply_heartbeat_liveness(&f.bh, f.bridge_id, new_gen, LIVE_BEAT_LEGACY)
	bridge_apply_vault_status_report(&f.bh, f.bridge_id, LIVE_BEAT_LEGACY, new_gen)
	fresh := live_row(t, f)
	defer domain.bridge_destroy(&fresh)
	testing.expect_value(t, fresh.status, domain.Bridge_Status.Online)
	testing.expect_value(t, fresh.last_seen_at, platform.clock_now(&f.clock))
	testing.expect_value(t, fresh.vault_status, "unlocked")
	testing.expect(t, strings.contains(fresh.capabilities_json, "tool_stream_demand_v2"), fresh.capabilities_json)
}
