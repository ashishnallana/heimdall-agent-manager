// Tests for the "attach to an existing bridge" device-enrolment path
// (rotate_bridge_for_device_grant), as opposed to the default "mint a new
// bridge" path (enroll_bridge_from_device_grant's existing body, covered by
// bridge_token_service_test.odin's enrol_one-based tests).
//
// Mirrors bridge_token_service_test.odin's fixture shape on purpose: a real
// sqlite repository (ownership and the token-revoke write are real SQL, not
// re-implemented by a fake), a fake connection-closer that records intent
// (the REAL socket teardown is proven on a real socket in
// src/hub/transport/http/bridge_revocation_ws_test.odin -- same split that
// file documents, for the same reason).
package bridge

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

@(private = "file")
attach_test_counter: int = 0

@(private = "file")
Attach_Fixture :: struct {
	db_path:           string,
	conn:              sqlite.Conn,
	impl:              sqlite.Bridge_Repo_SQLite,
	repo:              iface.Bridge_Repository,
	clock:             platform.Clock,
	ids:               platform.ID_Generator,
	svc:               Bridge_Service,
	closed_bridge_ids: [dynamic]string,
}

@(private = "file")
attach_fixture_closer :: proc(ctx: rawptr, bridge_id: string) -> bool {
	f := (^Attach_Fixture)(ctx)
	append(&f.closed_bridge_ids, strings.clone(bridge_id))
	return true
}

@(private = "file")
setup_attach_fixture :: proc(t: ^testing.T, tag: string) -> ^Attach_Fixture {
	f := new(Attach_Fixture)
	seq := sync.atomic_add(&attach_test_counter, 1)
	f.db_path = fmt.tprintf("/tmp/test_bridge_attach_%s_%d_%d_%d.db", tag, os.get_pid(), time.now()._nsec, seq)
	os.remove(f.db_path)
	conn, open_ok, _ := sqlite.open(f.db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	f.conn = conn
	mig_ok, mig_err := sqlite.run_migrations(&f.conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)
	f.repo = sqlite.new_bridge_repository(&f.impl, &f.conn)
	f.clock = platform.real_clock()
	f.ids = platform.real_id_generator()
	f.svc = new_bridge_service(&f.repo, &f.clock, &f.ids)
	f.closed_bridge_ids = make([dynamic]string)
	with_connection_closer(&f.svc, Bridge_Connection_Closer{ctx = rawptr(f), close_bridge_connection = attach_fixture_closer})
	return f
}

@(private = "file")
teardown_attach_fixture :: proc(f: ^Attach_Fixture) {
	if f == nil do return
	sqlite.close(&f.conn)
	os.remove(f.db_path)
	for s in f.closed_bridge_ids do delete(s)
	delete(f.closed_bridge_ids)
	free(f)
}

@(private = "file")
attach_enrol :: proc(t: ^testing.T, f: ^Attach_Fixture, owner, hostname: string) -> Enroll_Bridge_Result {
	result, ok, err := enroll_bridge_from_device_grant(&f.svc, Device_Enroll_Input{
		owner_user_id = owner,
		bridge_public_key = "04aabbccdd",
		bridge_key_fingerprint = "aaaa bbbb cccc dddd",
		os_user = "tanmay",
		machine_hostname = hostname,
		machine_os = "linux",
	})
	testing.expect(t, ok, err.message)
	return result
}

// THE CORE PROPERTY: approving with target_bridge_id set revokes the old
// credential family, keeps the row ALIVE under the SAME bridge_id (not
// .Revoked -- that is rotate's whole distinction from revoke_bridge), and the
// new device's credential authenticates as that same bridge going forward.
@(test)
test_rotate_for_device_grant_reuses_bridge_id_and_revokes_old_credential :: proc(t: ^testing.T) {
	f := setup_attach_fixture(t, "reuse")
	defer teardown_attach_fixture(f)

	old := attach_enrol(t, f, "approving-human", "old-nix-managed-host")
	old_bridge_id := strings.clone(old.bridge.bridge_id); defer delete(old_bridge_id)
	old_token := strings.clone(old.bridge_token); defer delete(old_token)

	_, pre_ok, _ := verify_bridge_token(&f.svc, old_token)
	testing.expect(t, pre_ok, "the old credential authenticates before the attach")

	attached, ok, err := enroll_bridge_from_device_grant(&f.svc, Device_Enroll_Input{
		owner_user_id = "approving-human",
		bridge_public_key = "04eeff0011",
		bridge_key_fingerprint = "eeee ffff 0000 1111",
		os_user = "tanmay",
		machine_hostname = "new-install-sh-host",
		machine_os = "linux",
		target_bridge_id = old_bridge_id,
	})
	testing.expect(t, ok, err.message)

	testing.expect_value(t, attached.bridge.bridge_id, old_bridge_id)
	testing.expect_value(t, attached.bridge.machine_hostname, "new-install-sh-host")
	testing.expect(t, attached.bridge.status != .Revoked, "attaching must not revoke the bridge -- that is the entire point versus revoke+re-enroll")

	// The old credential is dead...
	_, post_ok, post_err := verify_bridge_token(&f.svc, old_token)
	testing.expect(t, !post_ok, "the old credential no longer authenticates after the attach")
	testing.expect(t, post_err.code == .Forbidden, "a revoked credential is rejected as forbidden, not merely invalid")

	// ...and the NEW one resolves to the SAME bridge_id.
	new_auth, new_ok, new_err := verify_bridge_token(&f.svc, attached.bridge_token)
	testing.expect(t, new_ok, new_err.message)
	testing.expect_value(t, new_auth.bridge_id, old_bridge_id)

	// The live connection was asked to close.
	closed := false
	for id in f.closed_bridge_ids do if id == old_bridge_id do closed = true
	testing.expect(t, closed, "the target bridge's live connection was asked to close")
}

// ANTI-ENUMERATION: a target_bridge_id the approving user does not own must be
// rejected exactly like get_bridge/revoke_bridge reject one -- .Not_Found, not
// .Forbidden -- and must touch NOTHING: no revoked tokens, no closed socket,
// no row mutation. A target_bridge_id is attacker-controlled input (it rides
// in the approve POST body), so this is the one check standing between "pick
// your own stale bridge to attach to" and "take over anyone's bridge by
// guessing or enumerating its id".
@(test)
test_rotate_for_device_grant_rejects_unowned_target :: proc(t: ^testing.T) {
	f := setup_attach_fixture(t, "unowned")
	defer teardown_attach_fixture(f)

	alices := attach_enrol(t, f, "alice", "alices-host")
	alices_bridge_id := strings.clone(alices.bridge.bridge_id); defer delete(alices_bridge_id)
	alices_token := strings.clone(alices.bridge_token); defer delete(alices_token)

	_, ok, err := enroll_bridge_from_device_grant(&f.svc, Device_Enroll_Input{
		owner_user_id = "bob", // NOT the owner of alices_bridge_id
		bridge_public_key = "04112233",
		bridge_key_fingerprint = "1111 2222 3333 4444",
		os_user = "bob",
		machine_hostname = "bobs-host",
		machine_os = "linux",
		target_bridge_id = alices_bridge_id,
	})
	testing.expect(t, !ok, "attaching to a bridge the approver does not own must be refused")
	testing.expect(t, err.code == .Not_Found, "refused as not-found, the same anti-enumeration shape get_bridge/revoke_bridge use -- never .Forbidden, which would confirm the id exists")

	// Nothing touched: Alice's credential still works, and the closer was
	// never invoked.
	_, still_ok, still_err := verify_bridge_token(&f.svc, alices_token)
	testing.expect(t, still_ok, still_err.message)
	testing.expect_value(t, len(f.closed_bridge_ids), 0)
}

// A REVOKED bridge is an administrative end, not a parking lot to resurrect
// from. The approval page's <select> excludes revoked bridges, but that is
// client-side convenience -- target_bridge_id rides in a plain JSON body, so
// this asserts the SERVER refuses a revoked target even when nothing client-
// side stopped the request from naming one. Refused with the same
// anti-enumeration shape as an unowned target (.Not_Found), and the revoked
// row must stay exactly as revoke_bridge left it: still .Revoked, no new
// credential issued, connection-closer not invoked a second time.
@(test)
test_rotate_for_device_grant_rejects_revoked_target :: proc(t: ^testing.T) {
	f := setup_attach_fixture(t, "revoked")
	defer teardown_attach_fixture(f)

	owned := attach_enrol(t, f, "approving-human", "already-revoked-host")
	owned_bridge_id := strings.clone(owned.bridge.bridge_id); defer delete(owned_bridge_id)

	owner_auth := contracts.Auth_Context{kind = .User_Token, user_id = "approving-human"}
	revoked, revoke_ok, revoke_err := revoke_bridge(&f.svc, owner_auth, owned_bridge_id)
	testing.expect(t, revoke_ok, revoke_err.message)
	testing.expect_value(t, revoked.status, domain.Bridge_Status.Revoked)
	clear(&f.closed_bridge_ids) // revoke_bridge itself closes the connection; isolate what happens next

	_, ok, err := enroll_bridge_from_device_grant(&f.svc, Device_Enroll_Input{
		owner_user_id = "approving-human", // the OWNER, not an impersonator -- status alone must still refuse this
		bridge_public_key = "04998877",
		bridge_key_fingerprint = "9999 8888 7777 6666",
		os_user = "tanmay",
		machine_hostname = "resurrecting-host",
		machine_os = "linux",
		target_bridge_id = owned_bridge_id,
	})
	testing.expect(t, !ok, "attaching to the approver's OWN revoked bridge must still be refused")
	testing.expect(t, err.code == .Not_Found, "refused as not-found, the same anti-enumeration shape as an unowned target")
	testing.expect_value(t, len(f.closed_bridge_ids), 0)

	still_revoked, get_ok, get_err := get_bridge(&f.svc, owner_auth, owned_bridge_id)
	testing.expect(t, get_ok, get_err.message)
	testing.expect_value(t, still_revoked.status, domain.Bridge_Status.Revoked)
}

// REGRESSION GUARD: omitting target_bridge_id is byte-for-byte today's
// existing behaviour -- every enrolment, with or without this feature's code
// present, mints its own distinct bridge.
@(test)
test_enroll_without_target_bridge_id_mints_distinct_bridges :: proc(t: ^testing.T) {
	f := setup_attach_fixture(t, "distinct")
	defer teardown_attach_fixture(f)

	a := attach_enrol(t, f, "approving-human", "host-a")
	b := attach_enrol(t, f, "approving-human", "host-b")
	testing.expect(t, a.bridge.bridge_id != b.bridge.bridge_id, "two enrolments with no target_bridge_id are two distinct bridges")
	testing.expect_value(t, a.bridge.status, domain.Bridge_Status.Offline)
	testing.expect_value(t, b.bridge.status, domain.Bridge_Status.Offline)
}

@(test)
test_new_device_enrollment_uses_operator_bridge_label :: proc(t: ^testing.T) {
	f := setup_attach_fixture(t, "custom-label")
	defer teardown_attach_fixture(f)

	result, ok, err := enroll_bridge_from_device_grant(&f.svc, Device_Enroll_Input{
		owner_user_id = "approving-human",
		bridge_public_key = "04112233",
		bridge_key_fingerprint = "1111 2222 3333 4444",
		os_user = "tanmay",
		machine_hostname = "dawnstar",
		machine_os = "linux",
		new_bridge_label = "dawnstar-2",
	})
	testing.expect(t, ok, err.message)
	testing.expect_value(t, result.bridge.label, "dawnstar-2")
	testing.expect(t, result.bridge.label_is_user_customized, "operator-entered enrollment label must survive runtime hostname updates")
	testing.expect_value(t, result.bridge.machine_hostname, "dawnstar")
}


// T2: plan caps are checked only for new identities; attaches reuse a slot.
@(private = "file")
plan_test_lookup :: proc(ctx: rawptr, user_id: string) -> (domain.User_Entitlements, domain.Domain_Error) {
	entitlements := domain.unlimited_entitlements()
	entitlements.max_bridges = (^int)(ctx)^
	return entitlements, {}
}

@(test)
test_plan_bridge_approval_cap_pending_and_attach :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := setup_attach_fixture(t, "plan_cap")
	defer teardown_attach_fixture(f)
	limit := 1
	f.svc.entitlements = {ctx = &limit, lookup = plan_test_lookup}
	first := attach_enrol(t, f, "plan_owner", "first")
	_, second_ok, second_err := enroll_bridge_from_device_grant(&f.svc, Device_Enroll_Input{
		owner_user_id = "plan_owner", bridge_public_key = "04bb", machine_hostname = "second",
	})
	testing.expect(t, !second_ok)
	testing.expect_value(t, second_err.code, domain.Error_Code.Plan_Limit_Reached)
	testing.expect(t, strings.contains(second_err.details_json, `"allowed":1`))
	_, attach_ok, attach_err := enroll_bridge_from_device_grant(&f.svc, Device_Enroll_Input{
		owner_user_id = "plan_owner", bridge_public_key = "04cc", target_bridge_id = first.bridge.bridge_id,
	})
	testing.expect(t, attach_ok, "attach still works at the cap")
	testing.expect_value(t, attach_err.code, domain.Error_Code.None)
	count, _ := iface.bridge_count_active_by_owner(&f.repo, domain.User_ID("plan_owner"))
	testing.expect_value(t, count, 1)
	// A different owner's pending row reserves its sole slot too.
	_, pending_ok, _ := enroll_bridge_from_device_grant(&f.svc, Device_Enroll_Input{
		owner_user_id = "pending_owner", bridge_public_key = "04dd", pending = true,
	})
	testing.expect(t, pending_ok)
	_, over_pending, pending_err := enroll_bridge_from_device_grant(&f.svc, Device_Enroll_Input{
		owner_user_id = "pending_owner", bridge_public_key = "04ee", pending = true,
	})
	testing.expect(t, !over_pending)
	testing.expect_value(t, pending_err.code, domain.Error_Code.Plan_Limit_Reached)
	limit = 0
	_, zero_ok, zero_err := enroll_bridge_from_device_grant(&f.svc, Device_Enroll_Input{
		owner_user_id = "new_owner", bridge_public_key = "04ff",
	})
	testing.expect(t, !zero_ok)
	testing.expect_value(t, zero_err.code, domain.Error_Code.Plan_Limit_Reached)
	limit = -1
	_, unlimited_ok, _ := enroll_bridge_from_device_grant(&f.svc, Device_Enroll_Input{
		owner_user_id = "plan_owner", bridge_public_key = "04ff",
	})
	testing.expect(t, unlimited_ok)
}

@(private = "file")
plan_test_disabled :: proc(t: ^testing.T, f: ^Attach_Fixture, id: string) -> bool {
	row, found, err := iface.bridge_get_bridge(&f.repo, id)
	testing.expect(t, found)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	defer domain.bridge_destroy(&row)
	return row.plan_disabled_at != ""
}

@(test)
test_plan_bridge_reconcile_ranking_upgrade_revoke_and_stale_save :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := setup_attach_fixture(t, "plan_rank")
	defer teardown_attach_fixture(f)
	limit := 2
	f.svc.entitlements = {ctx = &limit, lookup = plan_test_lookup}
	base := domain.Bridge{
		owner_user_id = domain.User_ID("rank_owner"), status = .Online,
		created_at = "2026-01-01T00:00:00Z", last_seen_at = "2026-10-01T00:00:00Z",
	}
	versions := [5]string{"0.1.0", "1.10.0", "1.9.0", "1.9.0", "1.9.0"}
	for id, i in ([5]string{"recent", "v110", "v19", "tie_new", "tie_old"}) {
		row := base; row.bridge_id = id
		row.version = versions[i]
		if i == 0 do row.last_seen_at = "2026-10-02T00:00:00Z"
		if id == "tie_new" do row.created_at = "2026-02-01T00:00:00Z"
		_, ok, _ := iface.bridge_save_bridge(&f.repo, row)
		testing.expect(t, ok)
	}
	testing.expect_value(t, reconcile_plan_limits(&f.svc, "rank_owner", limit).code, domain.Error_Code.None)
	testing.expect(t, !plan_test_disabled(t, f, "recent"), "activity outranks version")
	testing.expect(t, !plan_test_disabled(t, f, "v110"), "numeric semver 1.10 outranks 1.9")
	testing.expect(t, plan_test_disabled(t, f, "v19"))
	count, count_err := iface.bridge_count_active_by_owner(&f.repo, domain.User_ID("rank_owner"))
	testing.expect_value(t, count_err.code, domain.Error_Code.None)
	testing.expect_value(t, count, 5)
	_, extra_ok, extra_err := enroll_bridge_from_device_grant(&f.svc, Device_Enroll_Input{
		owner_user_id = "rank_owner", bridge_public_key = "04ff",
	})
	testing.expect(t, !extra_ok, "disabled rows still occupy approval slots")
	testing.expect_value(t, extra_err.code, domain.Error_Code.Plan_Limit_Reached)
	before, _, _ := iface.bridge_get_bridge(&f.repo, "v19")
	defer domain.bridge_destroy(&before)
	testing.expect_value(t, reconcile_plan_limits(&f.svc, "rank_owner", limit).code, domain.Error_Code.None)
	after, _, _ := iface.bridge_get_bridge(&f.repo, "v19")
	defer domain.bridge_destroy(&after)
	testing.expect_value(t, before.plan_disabled_at, after.plan_disabled_at)
	// An in-flight heartbeat that read before the downgrade cannot erase the flag.
	stale := base; stale.bridge_id = "v19"; stale.version = "1.9.0"
	_, saved_ok, _ := iface.bridge_save_bridge(&f.repo, stale)
	testing.expect(t, saved_ok)
	testing.expect(t, plan_test_disabled(t, f, "v19"))
	// Revoking a retained bridge automatically brings the next ranked one back.
	_, revoked_ok, revoked_err := revoke_bridge(&f.svc, contracts.Auth_Context{kind = .User_Token, user_id = "rank_owner"}, "recent")
	testing.expect(t, revoked_ok)
	testing.expect_value(t, revoked_err.code, domain.Error_Code.None)
	testing.expect(t, !plan_test_disabled(t, f, "tie_new"), "created_at resolves same-version ties")
	testing.expect(t, plan_test_disabled(t, f, "tie_old"))
	testing.expect(t, len(f.closed_bridge_ids) == 1, "reconciliation never kills existing sessions")
	testing.expect_value(t, reconcile_plan_limits(&f.svc, "rank_owner", -1).code, domain.Error_Code.None)
	for id in ([4]string{"v110", "v19", "tie_new", "tie_old"}) do testing.expect(t, !plan_test_disabled(t, f, id), "upgrade clears suspension")
	testing.expect_value(t, reconcile_plan_limits(&f.svc, "rank_owner", 0).code, domain.Error_Code.None)
	for id in ([4]string{"v110", "v19", "tie_new", "tie_old"}) do testing.expect(t, plan_test_disabled(t, f, id), "zero disables all non-revoked bridges")
}

@(test)
test_plan_bridge_semver_and_exact_ties :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect(t, bridge_plan_compare_version("v1.10.0", "1.9.9") > 0)
	testing.expect(t, bridge_plan_compare_version("1.2.3", "1.2.3-rc.1") > 0)
	testing.expect(t, bridge_plan_compare_version("1.2.3-rc.10", "1.2.3-rc.2") > 0)
	testing.expect(t, bridge_plan_compare_version("1.2.3-alpha.1", "1.2.3-alpha.beta") < 0)
	testing.expect_value(t, bridge_plan_compare_version("1.2.3+new", "1.2.3+old"), 0)
	a := domain.Bridge{bridge_id = "a", last_seen_at = "2026-10-01T00:00:00Z"}
	b := a; b.bridge_id = "b"
	testing.expect(t, bridge_plan_before(a, b))
	testing.expect(t, !bridge_plan_before(b, a))
}

@(test)
test_plan_bridge_runtime_rejects_before_activity_update :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := setup_attach_fixture(t, "plan_runtime")
	defer teardown_attach_fixture(f)
	enrolled := attach_enrol(t, f, "runtime_owner", "box")
	limit := 0
	f.svc.entitlements = {ctx = &limit, lookup = plan_test_lookup}
	testing.expect_value(t, reconcile_owner_plan(&f.svc, "runtime_owner").code, domain.Error_Code.None)
	_, ok, err := bridge_runtime_connect(&f.svc, enrolled.bridge_token, "updated-host", "", "", "{}")
	testing.expect(t, !ok)
	testing.expect_value(t, err.code, domain.Error_Code.Plan_Limit_Reached)
	row, _, _ := iface.bridge_get_bridge(&f.repo, enrolled.bridge.bridge_id)
	defer domain.bridge_destroy(&row)
	testing.expect(t, row.machine_hostname == "box", "refused hello does not improve its ranking")
	limit = 1
	testing.expect_value(t, reconcile_owner_plan(&f.svc, "runtime_owner").code, domain.Error_Code.None)
	connected, connected_ok, connected_err := bridge_runtime_connect(&f.svc, enrolled.bridge_token, "updated-host", "", "", "{}")
	if connected_ok do domain.bridge_destroy(&connected)
	testing.expect(t, connected_ok, "same credential works after upgrade")
	testing.expect_value(t, connected_err.code, domain.Error_Code.None)
}


@(test)
test_plan_bridge_reconcile_rolls_back_partial_suspensions :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := setup_attach_fixture(t, "plan_rollback")
	defer teardown_attach_fixture(f)
	for id in ([3]string{"a", "b", "c"}) {
		_, ok, _ := iface.bridge_save_bridge(&f.repo, domain.Bridge{
			bridge_id = id, owner_user_id = domain.User_ID("rollback_owner"),
			status = .Offline, created_at = "2026-10-01T00:00:00Z",
		})
		testing.expect(t, ok)
	}
	testing.expect(t, sqlite.exec(&f.conn, "CREATE TRIGGER reject_plan_update BEFORE UPDATE OF plan_disabled_at ON bridges WHEN NEW.bridge_id = 'b' BEGIN SELECT RAISE(ABORT, 'test write failure'); END;"))
	err := reconcile_plan_limits(&f.svc, "rollback_owner", 0)
	testing.expect_value(t, err.code, domain.Error_Code.Internal_Error)
	for id in ([3]string{"a", "b", "c"}) do testing.expect(t, !plan_test_disabled(t, f, id), "all updates roll back, including the first successful one")
	testing.expect(t, sqlite.exec(&f.conn, "DROP TRIGGER reject_plan_update;"))
	testing.expect_value(t, reconcile_plan_limits(&f.svc, "rollback_owner", 0).code, domain.Error_Code.None)
	for id in ([3]string{"a", "b", "c"}) do testing.expect(t, plan_test_disabled(t, f, id), "a later retry succeeds")
}
