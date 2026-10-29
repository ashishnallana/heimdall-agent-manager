package main

// Enrollment hardening: account replace, running-service enroll, needs re-enrollment.
//   odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_NAMES=main.test_enroll_account_decision,...

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import bridgesvc "odin_test:lib/bridgesvc"

@(private = "file")
REPLACE_HUB :: "https://hub-replace.example.com"

@(test)
test_enroll_account_decision :: proc(t: ^testing.T) {
	D :: Bridge_Account_Decision
	testing.expect_value(t, bridge_enroll_account_decision("", "usr_b", false, .Unavailable), D.Same_Account)
	testing.expect_value(t, bridge_enroll_account_decision("usr_a", "", false, .Unavailable), D.Same_Account)
	testing.expect_value(t, bridge_enroll_account_decision("usr_a", "usr_a", false, .No), D.Same_Account)
	// Another account: never replaced silently, a headless run without the flag refuses.
	testing.expect_value(t, bridge_enroll_account_decision("usr_a", "usr_b", false, .Unavailable), D.Refuse)
	testing.expect_value(t, bridge_enroll_account_decision("usr_a", "usr_b", false, .No), D.Refuse)
	testing.expect_value(t, bridge_enroll_account_decision("usr_a", "usr_b", false, .Yes), D.Replace)
	testing.expect_value(t, bridge_enroll_account_decision("usr_a", "usr_b", true, .Unavailable), D.Replace)
}

// Account B replacing account A's bridge: confirmed by the flag, A's bridge is wiped
// (token, refresh, rotation leftovers, keyring, identity) and the self-revoke is
// attempted with A's own token. The hub is unreachable here, so the revoke is best
// effort and the replacement still succeeds.
@(test)
test_enroll_replace_other_account_wipes_old_secrets :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	old_id, new_id := keystore_test_bridge_ids()
	testing.expect(t, bridge_keystore_set_hub("http://127.0.0.1:9"))
	defer { keystore_lock_and_purge(old_id); _ = keystore_delete_identity_key(old_id); bridge_unseal_forget_identity(); _ = bridge_keystore_set_hub("") }

	dir := fmt.tprintf("/tmp/enroll-replace-%d", os.get_pid())
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)
	defer os.remove_all(dir)
	config := strings.concatenate({dir, "/config.toml"}, context.temp_allocator)
	token_file := strings.concatenate({dir, "/bridge-token"}, context.temp_allocator)
	_ = os.write_entire_file_from_string(config, "")

	testing.expect(t, test_provision_identity(old_id, "usr_alice"), "A enrolled this machine")
	bridge_unseal_forget_identity()
	testing.expect(t, bridge_write_credential_file(token_file, "http://127.0.0.1:9", old_id, "hbt_old.secret"))
	_ = os.write_entire_file_from_string(bridge_enroll_refresh_file_for(token_file, context.temp_allocator), "hbr_old.secret")
	_ = os.write_entire_file_from_string(strings.concatenate({token_file, ".pending-rotation-v1"}, context.temp_allocator), "{}")
	bridge_reenroll_mark(config, "http://127.0.0.1:9", old_id, .Revoked)
	testing.expect_value(t, bridge_enroll_previous_owner(old_id), "usr_alice")

	args := []string{"ham-bridge", "enroll", "--hub", "http://127.0.0.1:9", "--config", config, "--bridge-token-file", token_file, "--headless"}
	cred := Bridge_Enroll_Credential{bridge_id = new_id, owner_user_id = "usr_bob", access_token = "hbt_new.secret"}

	// Without the flag (and no terminal) it refuses and keeps everything of A.
	ok, replaced := bridge_enroll_resolve_account(args, "http://127.0.0.1:9", config, old_id, cred)
	testing.expect(t, !ok && !replaced)
	testing.expect(t, os.exists(token_file), "A's credential kept when not confirmed")
	testing.expect_value(t, bridge_enroll_previous_owner(old_id), "usr_alice")

	// Same account: nothing to replace.
	same := cred
	same.owner_user_id = "usr_alice"
	ok, replaced = bridge_enroll_resolve_account(args, "http://127.0.0.1:9", config, old_id, same)
	testing.expect(t, ok && !replaced)

	confirmed := make([dynamic]string, context.temp_allocator)
	append(&confirmed, ..args)
	append(&confirmed, BRIDGE_ENROLL_REPLACE_ACCOUNT_FLAG)
	ok, replaced = bridge_enroll_resolve_account(confirmed[:], "http://127.0.0.1:9", config, old_id, cred)
	testing.expect(t, ok && replaced)
	testing.expect(t, !os.exists(token_file), "A's access token deleted")
	testing.expect(t, !os.exists(bridge_enroll_refresh_file_for(token_file, context.temp_allocator)), "A's refresh token deleted")
	testing.expect(t, !os.exists(strings.concatenate({token_file, ".pending-rotation-v1"}, context.temp_allocator)), "rotation leftovers deleted")
	rec: Bridge_Identity_Record
	testing.expect_value(t, keystore_read_identity(old_id, &rec), Keystore_Read_Status.Not_Found)
	_, has_kr := keystore_read_vault_keyring(old_id)
	testing.expect(t, !has_kr, "A's keyring deleted")
	_, marker := bridgesvc.read_reenroll_marker(dir)
	testing.expect(t, !marker, "A's needs-reenrollment marker cleared")
}

// The revoked / refresh-401 state: marked, pending for that bridge only, parks
// rather than exits, and the hint names this profile's config and hub.
@(test)
test_enroll_needs_reenrollment_marker :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/enroll-reenroll-%d", os.get_pid())
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)
	defer os.remove_all(dir)
	config := strings.concatenate({dir, "/config.toml"}, context.temp_allocator)
	_, pending := bridge_reenroll_pending(config, "brg_x")
	testing.expect(t, !pending)
	bridge_reenroll_mark(config, REPLACE_HUB, "brg_x", .Refresh_Rejected)
	m, ok := bridge_reenroll_pending(config, "brg_x")
	testing.expect(t, ok)
	testing.expect_value(t, m.reason, "refresh_rejected")
	testing.expect_value(t, m.hint, strings.concatenate({"ham-bridge enroll --hub ", REPLACE_HUB, " --config ", config}, context.temp_allocator))
	bridge_reenroll_clear(config)
	_, ok = bridge_reenroll_pending(config, "brg_x")
	testing.expect(t, !ok)
	for r in Bridge_Reenroll_Reason do testing.expect(t, bridge_reenroll_reason_word(r) != "")
}

// Enroll with the service running: the config lock is retried (a stopping
// service releases it asynchronously) and taken once free. POSIX record locks are
// per process, so the "held by another process" half is not observable in-process.
@(test)
test_enroll_config_lock_retry_takes_a_free_lock :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/enroll-lock-%d", os.get_pid())
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)
	defer os.remove_all(dir)
	config := strings.concatenate({dir, "/config.toml"}, context.temp_allocator)
	got, ok := bridge_enroll_config_lock_retry(config, 300)
	testing.expect(t, ok, "a free lock is taken")
	bridge_instance_unlock(got)
}

// ===== Running-service enroll (F2): a simulated supervisor =====

@(private = "file")
Sim_Service :: struct {
	registered:  bool,
	running:     bool,
	stop_fails:  bool,
	start_fails: bool,
	stops:       int,
	starts:      int,
}

@(private = "file")
sim_service_ops :: proc(s: ^Sim_Service) -> Bridge_Enroll_Service_Ops {
	return {
		state = s,
		registered = proc(state: rawptr) -> (string, bool) {return "heimdall-bridge-sim", (^Sim_Service)(state).registered},
		running = proc(state: rawptr, _: string) -> bool {return (^Sim_Service)(state).running},
		stop = proc(state: rawptr, _: string) -> (bool, string) {
			s := (^Sim_Service)(state)
			s.stops += 1
			if s.stop_fails do return false, "stop refused"
			s.running = false
			return true, ""
		},
		start = proc(state: rawptr, _: string) -> (bool, string) {
			s := (^Sim_Service)(state)
			s.starts += 1
			if s.start_fails do return false, "start refused"
			s.running = true
			return true, ""
		},
	}
}

// A ceremony that succeeds hands its credential to the service through its own
// restart (bridge_enroll_restart_service sets the flag); one that fails does not.
@(private = "file")
sim_ceremony_ok :: proc(_: []string) -> bool {
	g_bridge_enroll_service_restarted = true
	return true
}

@(private = "file")
sim_ceremony_fails :: proc(_: []string) -> bool {return false}

@(test)
test_enroll_with_own_service_stops_and_restores_it :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	args := []string{"ham-bridge", "enroll", "--hub", REPLACE_HUB, "--headless"}

	// Running + success: stopped once, NOT started again here (the ceremony restarted it).
	s := Sim_Service{registered = true, running = true}
	ok, out := bridge_enroll_with_own_service(sim_service_ops(&s), args, sim_ceremony_ok)
	testing.expect(t, ok)
	testing.expect_value(t, out.stopped, "heimdall-bridge-sim")
	testing.expect_value(t, s.stops, 1)
	testing.expect_value(t, s.starts, 0)
	testing.expect(t, !out.started_again)

	// Running + failure: started again exactly once, left running.
	s = Sim_Service{registered = true, running = true}
	ok, out = bridge_enroll_with_own_service(sim_service_ops(&s), args, sim_ceremony_fails)
	testing.expect(t, !ok)
	testing.expect_value(t, s.stops, 1)
	testing.expect_value(t, s.starts, 1)
	testing.expect(t, out.started_again && s.running)

	// Not running + failure: nothing stopped, nothing started.
	s = Sim_Service{registered = true, running = false}
	ok, out = bridge_enroll_with_own_service(sim_service_ops(&s), args, sim_ceremony_fails)
	testing.expect(t, !ok)
	testing.expect_value(t, s.stops, 0)
	testing.expect_value(t, s.starts, 0)
	testing.expect_value(t, out.stopped, "")

	// Not registered: the supervisor is never touched.
	s = Sim_Service{registered = false, running = true}
	_, out = bridge_enroll_with_own_service(sim_service_ops(&s), args, sim_ceremony_fails)
	testing.expect_value(t, s.stops + s.starts, 0)

	// A stop that fails is not "stopped", so a failure does not start it on top.
	s = Sim_Service{registered = true, running = true, stop_fails = true}
	_, out = bridge_enroll_with_own_service(sim_service_ops(&s), args, sim_ceremony_fails)
	testing.expect_value(t, s.stops, 1)
	testing.expect_value(t, s.starts, 0)

	// The start after a failure fails: reported, tried once.
	s = Sim_Service{registered = true, running = true, start_fails = true}
	ok, out = bridge_enroll_with_own_service(sim_service_ops(&s), args, sim_ceremony_fails)
	testing.expect(t, !ok)
	testing.expect_value(t, s.starts, 1)
	testing.expect(t, out.restart_failed && !out.started_again)
}

// ===== Device code lost on a hub restart (REQ-ENR-12) =====

@(test)
test_enroll_reissues_a_lost_or_expired_device_code :: proc(t: ^testing.T) {
	testing.expect(t, bridge_enroll_code_lost("1730000000000000001", "1730000099000000002"), "a new grant-store epoch: the code is gone")
	testing.expect(t, !bridge_enroll_code_lost("1730000000000000001", "1730000000000000001"))
	testing.expect(t, !bridge_enroll_code_lost("", "1730000000000000001"), "an older hub's authorize carried no epoch")
	testing.expect(t, !bridge_enroll_code_lost("1730000000000000001", ""), "an older hub's poll carried no epoch")

	S :: Bridge_Enroll_Poll_Status
	testing.expect(t, bridge_enroll_should_reissue(S.Code_Lost, 0))
	testing.expect(t, bridge_enroll_should_reissue(S.Expired, 0))
	testing.expect(t, bridge_enroll_should_reissue(S.Code_Lost, BRIDGE_ENROLL_MAX_REISSUES - 1))
	testing.expect(t, !bridge_enroll_should_reissue(S.Code_Lost, BRIDGE_ENROLL_MAX_REISSUES), "bounded")
	testing.expect(t, !bridge_enroll_should_reissue(S.Expired, BRIDGE_ENROLL_MAX_REISSUES), "bounded")
	for s in ([?]S{.Pending, .Approved, .Denied, .Slow_Down, .Fatal}) {
		testing.expectf(t, !bridge_enroll_should_reissue(s, 0), "%v is not recovered by a new code", s)
	}
}

// ===== Vault key never delivered (F7, legacy hub) =====

@(test)
test_enroll_vault_key_timeout_marks_needs_reenrollment :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/enroll-vkt-%d", os.get_pid())
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)
	defer os.remove_all(dir)
	config := strings.concatenate({dir, "/config.toml"}, context.temp_allocator)
	hint := bridge_enroll_mark_vault_key_timeout(config, REPLACE_HUB, "brg_vkt")
	m, ok := bridgesvc.read_reenroll_marker(dir)
	testing.expect(t, ok, "the profile is marked")
	testing.expect_value(t, m.reason, "vault_key_timeout")
	testing.expect_value(t, m.bridge_id, "brg_vkt")
	testing.expect_value(t, m.hint, hint)
	testing.expect(t, strings.contains(hint, config) && strings.contains(hint, REPLACE_HUB), "the retry command names this profile")
	// A successful (re-)enrollment clears it before the service restarts.
	bridge_reenroll_clear(config)
	_, ok = bridgesvc.read_reenroll_marker(dir)
	testing.expect(t, !ok)
}
