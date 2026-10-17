package main

// REQ-EA-4: the bridge half of atomic enrollment (enroll_atomic.odin). Each test
// drives the state machine directly — arm, deliver a sealed key, then the hub's
// verdict — inside the vault sandbox, so the files and keyring entries it writes
// never touch the operator's own.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

@(private = "file")
ENROLL_ATOMIC_TEST_KEY :: "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"

@(private = "file")
enroll_atomic_test_cred :: proc(bridge_id: string) -> Bridge_Enroll_Credential {
	return Bridge_Enroll_Credential{
		bridge_id = bridge_id,
		access_token = "hba_enrolltest.secret",
		refresh_token = "hbf_enrolltest.secret",
		expires_in = 3600,
		vault_delivery_expected = true,
		enrollment_pending = true,
	}
}

@(private = "file")
enroll_atomic_test_file_exists :: proc(path: string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	_ = data
	return err == nil
}

@(private = "file")
enroll_atomic_test_read :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return ""
	return string(data)
}

// The shared fixture: sandbox + armed state + a pre-existing config.toml whose
// content a rollback must restore byte for byte.
@(private = "file")
Enroll_Atomic_Fixture :: struct {
	sb:          Bridge_Vault_Test_Sandbox,
	bridge_id:   string,
	token_file:  string,
	config_path: string,
}

@(private = "file")
ENROLL_ATOMIC_TEST_OLD_CONFIG :: "# operator config before enrollment\n[daemon]\ndaemon_id = \"previous\"\n"

@(private = "file")
enroll_atomic_fixture_open :: proc(t: ^testing.T, f: ^Enroll_Atomic_Fixture, label: string) -> bool {
	sb, ok := bridge_vault_test_sandbox_open(t, label)
	f.sb = sb
	if !ok do return false
	f.bridge_id, _ = keystore_test_bridge_ids()
	f.token_file = fmt.aprintf("%s/cred/bridge.token", sb.dir)
	f.config_path = fmt.aprintf("%s/config.toml", sb.dir)
	if os.write_entire_file(f.config_path, transmute([]byte)string(ENROLL_ATOMIC_TEST_OLD_CONFIG)) != nil {
		testing.fail_now(t, "could not seed config.toml")
	}
	unseal_nonce_cache_clear(&g_unseal_nonce_cache)
	bridge_unseal_init()
	bridge_enroll_atomic_arm(enroll_atomic_test_cred(f.bridge_id), f.token_file, f.config_path, "https://hub.example.test")
	return true
}

@(private = "file")
enroll_atomic_fixture_close :: proc(f: ^Enroll_Atomic_Fixture) {
	bridge_enroll_atomic_disarm()
	keystore_lock_and_purge(f.bridge_id)
	delete(f.token_file)
	delete(f.config_path)
	bridge_vault_test_sandbox_close(&f.sb)
}

@(private = "file")
enroll_atomic_test_envelope :: proc(bridge_id, nonce: string, tamper := false) -> (string, i64) {
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000
	pub := bridge_get_public_key_hex()
	defer delete(pub)
	return create_sec_test_envelope(bridge_id, pub, ENROLL_ATOMIC_TEST_KEY, now_ms, nonce, tamper), now_ms
}

@(test)
test_enroll_atomic_ack_only_after_key_and_credential_persist :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f: Enroll_Atomic_Fixture
	defer enroll_atomic_fixture_close(&f)
	if !enroll_atomic_fixture_open(t, &f, "ea_ack") do return

	// Nothing is on disk while waiting: approval alone wrote no credential.
	testing.expect(t, !enroll_atomic_test_file_exists(f.token_file), "no credential before the key is delivered")

	payload, now_ms := enroll_atomic_test_envelope(f.bridge_id, "nonce_ea_ack_1")
	defer delete(payload)
	ok, err_msg := bridge_enroll_atomic_on_unseal(payload, now_ms)
	testing.expect(t, ok, fmt.tprintf("delivery must succeed: %s", err_msg))
	testing.expect_value(t, bridge_enroll_atomic_state(), Bridge_Enroll_Atomic_State.Acked)
	// STAGED before the ack: the live files are untouched until the hub commits.
	st := bridge_enroll_stage_for(f.token_file, f.config_path)
	testing.expect(t, strings.contains(enroll_atomic_test_read(strings.concatenate({f.token_file, BRIDGE_ENROLL_STAGE_SUFFIX}, context.temp_allocator)), "hba_enrolltest.secret"), "access token staged before the ack")
	testing.expect(t, enroll_atomic_test_file_exists(strings.concatenate({st.refresh_file, BRIDGE_ENROLL_STAGE_SUFFIX}, context.temp_allocator)), "refresh token staged before the ack")
	testing.expect(t, enroll_atomic_test_file_exists(st.marker), "the staging marker is written before the ack")
	testing.expect(t, !enroll_atomic_test_file_exists(f.token_file), "the live credential is not written before the commit")
	testing.expect_value(t, enroll_atomic_test_read(f.config_path), ENROLL_ATOMIC_TEST_OLD_CONFIG)
	testing.expect(t, bridge_enroll_vault_key_persisted(f.bridge_id), "vault key readable from the OS store before the ack")

	bridge_enroll_atomic_on_result(`{"type":"bridge_enrollment_result","committed":true}`)
	testing.expect_value(t, bridge_enroll_atomic_state(), Bridge_Enroll_Atomic_State.Committed)
	testing.expect(t, strings.contains(enroll_atomic_test_read(f.token_file), "hba_enrolltest.secret"), "the commit moves the credential into place")
	testing.expect(t, enroll_atomic_test_file_exists(st.refresh_file), "the commit moves the refresh token into place")
	testing.expect(t, enroll_atomic_test_read(f.config_path) != ENROLL_ATOMIC_TEST_OLD_CONFIG, "the commit moves the new config into place")
	testing.expect(t, !enroll_atomic_test_file_exists(st.marker), "the marker is gone once promoted")
	testing.expect(t, bridge_enroll_vault_key_persisted(f.bridge_id), "a committed enrollment keeps its key")

	// A stale or duplicate committed:false after the commit must NOT undo it.
	bridge_enroll_atomic_on_result(`{"type":"bridge_enrollment_result","committed":false}`)
	testing.expect_value(t, bridge_enroll_atomic_state(), Bridge_Enroll_Atomic_State.Committed)
	testing.expect(t, enroll_atomic_test_file_exists(f.token_file), "a stale rollback leaves the committed credential")
	testing.expect(t, bridge_enroll_vault_key_persisted(f.bridge_id), "a stale rollback leaves the committed key")
}

@(test)
test_enroll_atomic_hub_rollback_restores_previous_files_and_purges_key :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f: Enroll_Atomic_Fixture
	defer enroll_atomic_fixture_close(&f)
	if !enroll_atomic_fixture_open(t, &f, "ea_rollback") do return

	payload, now_ms := enroll_atomic_test_envelope(f.bridge_id, "nonce_ea_rb_1")
	defer delete(payload)
	ok, err_msg := bridge_enroll_atomic_on_unseal(payload, now_ms)
	testing.expect(t, ok, fmt.tprintf("delivery must succeed: %s", err_msg))
	testing.expect_value(t, enroll_atomic_test_read(f.config_path), ENROLL_ATOMIC_TEST_OLD_CONFIG)

	bridge_enroll_atomic_on_result(`{"type":"bridge_enrollment_result","committed":false}`)
	testing.expect_value(t, bridge_enroll_atomic_state(), Bridge_Enroll_Atomic_State.Rolled_Back)
	testing.expect(t, !enroll_atomic_test_file_exists(f.token_file), "rollback removes a credential that did not exist before")
	testing.expect(t, !enroll_atomic_test_file_exists(bridge_enroll_refresh_file_for(f.token_file, context.temp_allocator)), "rollback removes the refresh token")
	st := bridge_enroll_stage_for(f.token_file, f.config_path)
	testing.expect(t, !enroll_atomic_test_file_exists(st.marker), "rollback removes the marker")
	testing.expect(t, !enroll_atomic_test_file_exists(strings.concatenate({f.token_file, BRIDGE_ENROLL_STAGE_SUFFIX}, context.temp_allocator)), "rollback removes the staging")
	testing.expect_value(t, enroll_atomic_test_read(f.config_path), ENROLL_ATOMIC_TEST_OLD_CONFIG)
	testing.expect(t, !bridge_enroll_vault_key_persisted(f.bridge_id), "rollback purges the delivered key")

	// A late re-delivery after a rollback is refused and writes nothing.
	again, again_ms := enroll_atomic_test_envelope(f.bridge_id, "nonce_ea_rb_2")
	defer delete(again)
	late_ok, _ := bridge_enroll_atomic_on_unseal(again, again_ms)
	testing.expect(t, !late_ok, "a delivery after rollback must not be acknowledged")
	testing.expect(t, !enroll_atomic_test_file_exists(f.token_file), "a refused late delivery writes nothing")
}

@(test)
test_enroll_atomic_failed_delivery_writes_nothing_and_allows_retry :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f: Enroll_Atomic_Fixture
	defer enroll_atomic_fixture_close(&f)
	if !enroll_atomic_fixture_open(t, &f, "ea_retry") do return

	bad, bad_ms := enroll_atomic_test_envelope(f.bridge_id, "nonce_ea_retry_1", true)
	defer delete(bad)
	bad_ok, _ := bridge_enroll_atomic_on_unseal(bad, bad_ms)
	testing.expect(t, !bad_ok, "a tampered delivery must fail")
	testing.expect_value(t, bridge_enroll_atomic_state(), Bridge_Enroll_Atomic_State.Waiting)
	testing.expect(t, !enroll_atomic_test_file_exists(f.token_file), "a failed delivery writes no credential")
	testing.expect_value(t, enroll_atomic_test_read(f.config_path), ENROLL_ATOMIC_TEST_OLD_CONFIG)
	testing.expect(t, !bridge_enroll_vault_key_persisted(f.bridge_id), "a failed delivery leaves no key")

	good, good_ms := enroll_atomic_test_envelope(f.bridge_id, "nonce_ea_retry_2")
	defer delete(good)
	good_ok, err_msg := bridge_enroll_atomic_on_unseal(good, good_ms)
	testing.expect(t, good_ok, fmt.tprintf("the retry must succeed: %s", err_msg))
	testing.expect_value(t, bridge_enroll_atomic_state(), Bridge_Enroll_Atomic_State.Acked)

	// A relayed duplicate after the ack answers ok again and writes nothing new.
	dup_ok, _ := bridge_enroll_atomic_on_unseal(good, good_ms)
	testing.expect(t, dup_ok, "a duplicate after the ack is answered ok, idempotently")
}

// ===== Crash recovery (step 4) =====
//
// Each test stages an enrollment through the real ack path, then DISARMS the state
// machine — which is what a crash leaves: files on disk, no process — and runs the
// recovery a service start runs, against a scripted hub answer.

@(private = "file")
g_recovery_probe_outcome: Bridge_Refresh_Outcome
@(private = "file")
g_recovery_probe_calls: int

@(private = "file")
recovery_probe :: proc(api_base, refresh_token: string) -> (Bridge_Enroll_Credential, Bridge_Refresh_Outcome) {
	g_recovery_probe_calls += 1
	if g_recovery_probe_outcome == .Rotated {
		return Bridge_Enroll_Credential{access_token = "hba_rotated.secret", refresh_token = "hbf_rotated.secret", expires_in = 3600}, .Rotated
	}
	return Bridge_Enroll_Credential{}, g_recovery_probe_outcome
}

@(private = "file")
enroll_atomic_stage_then_crash :: proc(t: ^testing.T, f: ^Enroll_Atomic_Fixture, nonce: string) {
	payload, now_ms := enroll_atomic_test_envelope(f.bridge_id, nonce)
	defer delete(payload)
	ok, err_msg := bridge_enroll_atomic_on_unseal(payload, now_ms)
	testing.expect(t, ok, fmt.tprintf("delivery must succeed: %s", err_msg))
	bridge_enroll_atomic_disarm() // the process is gone; only the disk remains
}

@(test)
test_enroll_recovery_promotes_a_committed_enrollment_with_the_rotated_pair :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f: Enroll_Atomic_Fixture
	defer enroll_atomic_fixture_close(&f)
	if !enroll_atomic_fixture_open(t, &f, "ea_rec_commit") do return
	enroll_atomic_stage_then_crash(t, &f, "nonce_ea_rec_c")

	g_recovery_probe_outcome = .Rotated
	g_recovery_probe_calls = 0
	got := bridge_enroll_atomic_recover_paths(f.token_file, f.config_path, recovery_probe)
	testing.expect_value(t, got, Bridge_Enroll_Recovery.Promoted)
	testing.expect_value(t, g_recovery_probe_calls, 1)
	st := bridge_enroll_stage_for(f.token_file, f.config_path)
	testing.expect(t, strings.contains(enroll_atomic_test_read(f.token_file), "hba_rotated.secret"), "the ROTATED access token is live (the staged one is spent)")
	testing.expect(t, strings.contains(enroll_atomic_test_read(st.refresh_file), "hbf_rotated.secret"), "the ROTATED refresh token is live")
	testing.expect(t, enroll_atomic_test_read(f.config_path) != ENROLL_ATOMIC_TEST_OLD_CONFIG, "the staged config is live")
	testing.expect(t, !enroll_atomic_test_file_exists(st.marker), "the marker is gone")
	testing.expect(t, bridge_enroll_vault_key_persisted(f.bridge_id), "the key stays")
	testing.expect_value(t, bridge_enroll_atomic_recover_paths(f.token_file, f.config_path, recovery_probe), Bridge_Enroll_Recovery.None)
}

@(test)
test_enroll_recovery_discards_a_rolled_back_enrollment_and_its_key :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f: Enroll_Atomic_Fixture
	defer enroll_atomic_fixture_close(&f)
	if !enroll_atomic_fixture_open(t, &f, "ea_rec_rb") do return
	enroll_atomic_stage_then_crash(t, &f, "nonce_ea_rec_r")

	// invalid_grant: the hub refuses refresh for a pending OR revoked family.
	g_recovery_probe_outcome = .Revoked
	got := bridge_enroll_atomic_recover_paths(f.token_file, f.config_path, recovery_probe)
	testing.expect_value(t, got, Bridge_Enroll_Recovery.Discarded)
	st := bridge_enroll_stage_for(f.token_file, f.config_path)
	testing.expect(t, !enroll_atomic_test_file_exists(f.token_file), "no live credential")
	testing.expect(t, !enroll_atomic_test_file_exists(strings.concatenate({f.token_file, BRIDGE_ENROLL_STAGE_SUFFIX}, context.temp_allocator)), "no staged credential")
	testing.expect(t, !enroll_atomic_test_file_exists(st.marker), "no marker")
	testing.expect_value(t, enroll_atomic_test_read(f.config_path), ENROLL_ATOMIC_TEST_OLD_CONFIG)
	testing.expect(t, !bridge_enroll_vault_key_persisted(f.bridge_id), "the delivered key is purged")
}

@(test)
test_enroll_recovery_keeps_staging_when_the_hub_is_unreachable :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f: Enroll_Atomic_Fixture
	defer enroll_atomic_fixture_close(&f)
	if !enroll_atomic_fixture_open(t, &f, "ea_rec_retry") do return
	enroll_atomic_stage_then_crash(t, &f, "nonce_ea_rec_u")

	g_recovery_probe_outcome = .Retry
	testing.expect_value(t, bridge_enroll_atomic_recover_paths(f.token_file, f.config_path, recovery_probe), Bridge_Enroll_Recovery.Unresolved)
	st := bridge_enroll_stage_for(f.token_file, f.config_path)
	testing.expect(t, enroll_atomic_test_file_exists(st.marker), "the staging survives for the next start")
	testing.expect(t, !enroll_atomic_test_file_exists(f.token_file), "nothing was promoted on a guess")
	// The next start, with the hub back and the enrollment committed, finishes it.
	g_recovery_probe_outcome = .Rotated
	testing.expect_value(t, bridge_enroll_atomic_recover_paths(f.token_file, f.config_path, recovery_probe), Bridge_Enroll_Recovery.Promoted)
}

@(test)
test_enroll_recovery_discards_incomplete_staging_without_asking_the_hub :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f: Enroll_Atomic_Fixture
	defer enroll_atomic_fixture_close(&f)
	if !enroll_atomic_fixture_open(t, &f, "ea_rec_partial") do return
	bridge_enroll_atomic_disarm()
	// A crash mid-staging: a staged token, no marker (the marker is written LAST).
	_ = bridge_write_secret_file(strings.concatenate({f.token_file, BRIDGE_ENROLL_STAGE_SUFFIX}, context.temp_allocator), "hba_partial.secret")
	g_recovery_probe_calls = 0
	testing.expect_value(t, bridge_enroll_atomic_recover_paths(f.token_file, f.config_path, recovery_probe), Bridge_Enroll_Recovery.Discarded)
	testing.expect_value(t, g_recovery_probe_calls, 0)
	testing.expect(t, !enroll_atomic_test_file_exists(strings.concatenate({f.token_file, BRIDGE_ENROLL_STAGE_SUFFIX}, context.temp_allocator)), "the partial staging is gone")
	testing.expect(t, !enroll_atomic_test_file_exists(f.token_file), "nothing became live")
}

@(test)
test_enroll_recovery_finishes_an_interrupted_promotion :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f: Enroll_Atomic_Fixture
	defer enroll_atomic_fixture_close(&f)
	if !enroll_atomic_fixture_open(t, &f, "ea_rec_half") do return
	enroll_atomic_stage_then_crash(t, &f, "nonce_ea_rec_h")
	// A crash after the refresh half was renamed but before the access half: the
	// hub committed (promotion only starts on committed:true).
	st := bridge_enroll_stage_for(f.token_file, f.config_path)
	_ = os.rename(strings.concatenate({st.refresh_file, BRIDGE_ENROLL_STAGE_SUFFIX}, context.temp_allocator), st.refresh_file)
	g_recovery_probe_calls = 0
	testing.expect_value(t, bridge_enroll_atomic_recover_paths(f.token_file, f.config_path, recovery_probe), Bridge_Enroll_Recovery.Promoted)
	testing.expect_value(t, g_recovery_probe_calls, 0)
	testing.expect(t, strings.contains(enroll_atomic_test_read(f.token_file), "hba_enrolltest.secret"), "the access half is moved into place")
	testing.expect(t, !enroll_atomic_test_file_exists(st.marker), "the marker is gone")
}

@(test)
test_enroll_stage_marker_is_valid_json :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	f: Enroll_Atomic_Fixture
	defer enroll_atomic_fixture_close(&f)
	if !enroll_atomic_fixture_open(t, &f, "ea_marker") do return
	payload, now_ms := enroll_atomic_test_envelope(f.bridge_id, "nonce_ea_marker")
	defer delete(payload)
	ok, _ := bridge_enroll_atomic_on_unseal(payload, now_ms)
	testing.expect(t, ok, "delivery succeeds")
	marker := enroll_atomic_test_read(bridge_enroll_stage_for(f.token_file, f.config_path).marker)
	testing.expectf(t, strings.has_prefix(marker, `{"bridge_id":"`), "marker is JSON, got %q", marker)
	testing.expect_value(t, extract_json_string(marker, "bridge_id", "", context.temp_allocator), f.bridge_id)
	testing.expect_value(t, extract_json_string(marker, "hub", "", context.temp_allocator), "https://hub.example.test")
}
