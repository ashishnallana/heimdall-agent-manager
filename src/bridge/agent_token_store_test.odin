package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// Tests for per-bridge local-token store isolation + atomic persistence
// (task_18d0f1f7b6c80449): two bridges sharing one store used to clobber each
// other's tokens on full-file rewrite, leaving agents permanently unauthenticated
// on reconnect. The store is now namespaced by local_endpoint_run_dir.
//
// NOTE: Odin runs a package's tests concurrently across threads. All three
// token-store tests mutate the SAME process globals (bridge_config.data_dir,
// bridge_config.local_endpoint_run_dir, and bridge_local_token_records), so they
// must not run interleaved or one test's config change makes another resolve the
// wrong store path. In a real deployment each bridge is its own process, so this
// only matters for the test harness; serialize them with a shared mutex.
//
// THE MUTEX IS NOT ENOUGH, AND THE REASON IS THE POINT: bridge_test_config_mutex is
// a process-local sync.Mutex. It serialises THREADS INSIDE ONE BINARY and does
// nothing whatsoever between two concurrent `odin test` invocations. Any test here
// that also writes a SHARED FILESYSTEM PATH is still unsafe across processes, so
// every data_dir below is run-scoped with os.get_pid(). The question to ask of any
// lock before calling a test isolated: what is this lock actually serialising?
//
// Note which paths are NOT scoped, deliberately: the local_endpoint_run_dir values
// ("/tmp/bridgeA", "/tmp/bridgeRT", ...) are never used as directories. They are
// NAMESPACE INPUTS, slugified into a single path segment by
// bridge_agent_token_store_namespace (agent_token_store.odin:132-148), so sharing
// them between processes is harmless — and scoping them would silently weaken the
// per-bridge-namespace assertions that are the whole point of these tests.
bridge_test_config_mutex: sync.Mutex

@(test)
bridge_token_store_namespace_is_per_bridge :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved := bridge_config.local_endpoint_run_dir
	defer { bridge_config.local_endpoint_run_dir = saved }

	bridge_config.local_endpoint_run_dir = "/tmp/heimdall-bridge-local"
	a := bridge_agent_token_store_namespace()
	defer delete(a)
	bridge_config.local_endpoint_run_dir = "/tmp/heimdall-bridge-local-macbook-remote"
	b := bridge_agent_token_store_namespace()
	defer delete(b)
	testing.expect(t, a != b, "distinct run dirs must yield distinct namespaces")
	testing.expect(t, !strings.contains(a, "/"), "namespace must be a single safe path segment")
	testing.expect(t, !strings.contains(b, "/"), "namespace must be a single safe path segment")

	bridge_config.local_endpoint_run_dir = ""
	testing.expect(t, bridge_agent_token_store_namespace() == "default", "empty run dir -> default namespace")
}

@(test)
bridge_token_store_two_bridges_do_not_clobber :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	// Isolate to a scratch data dir so we never touch a real store. Run-scoped by pid
	// so two CONCURRENT `odin test` processes cannot share it (see the note above).
	scratch := fmt.aprintf("/tmp/ham-token-store-test-%d", os.get_pid())
	saved_dir := bridge_config.local_endpoint_run_dir
	saved_data := bridge_config.data_dir
	defer {
		bridge_config.local_endpoint_run_dir = saved_dir
		bridge_config.data_dir = saved_data
		delete(scratch)
	}
	bridge_config.data_dir = scratch

	// Bridge A issues a token.
	bridge_config.local_endpoint_run_dir = "/tmp/bridgeA"
	bridge_agent_token_store_init()
	issue_a := bridge_agent_token_issue("inst_A", "hit_inst_A", .Wrapper)
	rec_a, ok_a := bridge_agent_token_verify(issue_a.plaintext_token)
	testing.expect(t, ok_a && rec_a.agent_instance_id == "inst_A", "bridge A token verifies after issue")

	// Bridge B (different run dir) issues its own token; this MUST NOT wipe A.
	bridge_config.local_endpoint_run_dir = "/tmp/bridgeB"
	bridge_agent_token_store_init() // reloads B's (separate) store into memory
	_ = bridge_agent_token_issue("inst_B", "hit_inst_B", .Wrapper)

	// Reload bridge A's store from disk; its token must still be present.
	bridge_config.local_endpoint_run_dir = "/tmp/bridgeA"
	bridge_agent_token_store_init()
	rec_a2, ok_a2 := bridge_agent_token_verify(issue_a.plaintext_token)
	testing.expect(t, ok_a2 && rec_a2.agent_instance_id == "inst_A", "bridge A token SURVIVES bridge B issuing its own token")

}

@(test)
bridge_token_store_save_load_roundtrip :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	// Run-scoped by pid: shared across concurrent processes otherwise (see note above).
	data_dir := fmt.aprintf("/tmp/ham-token-store-rt-%d", os.get_pid())
	saved_dir := bridge_config.local_endpoint_run_dir
	saved_data := bridge_config.data_dir
	defer {
		bridge_config.local_endpoint_run_dir = saved_dir
		bridge_config.data_dir = saved_data
		delete(data_dir)
	}
	bridge_config.data_dir = data_dir
	bridge_config.local_endpoint_run_dir = "/tmp/bridgeRT"

	bridge_agent_token_store_init()
	issue := bridge_agent_token_issue("inst_RT", "hit_inst_RT", .Agent, 4)

	// Fresh init reloads from disk (atomic-written file) and still verifies.
	bridge_agent_token_store_init()
	rec, ok := bridge_agent_token_verify(issue.plaintext_token)
	testing.expect(t, ok && rec.agent_instance_id == "inst_RT" && rec.role == .Agent, "token roundtrips through atomic save + reload")
	testing.expect_value(t, rec.run_count, 4)
	rotated, rotated_ok := bridge_agent_token_rotate(issue.plaintext_token)
	testing.expect(t, rotated_ok)
	bridge_agent_token_store_init()
	reloaded, reload_ok := bridge_agent_token_verify(rotated.plaintext_token)
	testing.expect(t, reload_ok && reloaded.run_count == 4, "generation survives token rotation and reload")

}

// H7 restart-reap: invalidating an instance's tokens must kill EVERY valid token
// for that instance (wrapper + agent roles) while leaving other instances' tokens
// intact, so a superseded old ham-wrapper fails its next liveness ping.
@(test)
bridge_token_invalidate_instance_reaps_all_roles :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	// Run-scoped by pid: shared across concurrent processes otherwise (see note above).
	data_dir := fmt.aprintf("/tmp/ham-token-store-reap-%d", os.get_pid())
	saved_dir := bridge_config.local_endpoint_run_dir
	saved_data := bridge_config.data_dir
	defer {
		bridge_config.local_endpoint_run_dir = saved_dir
		bridge_config.data_dir = saved_data
		delete(data_dir)
	}
	bridge_config.data_dir = data_dir
	bridge_config.local_endpoint_run_dir = "/tmp/bridgeREAP"
	bridge_agent_token_store_init()
	// Hermetic: drop any records persisted by a prior run so counts are exact.
	os.remove(bridge_agent_token_store_path())
	clear(&bridge_local_token_records)

	// Old runtime for inst_X: both wrapper + agent tokens.
	old_wrapper := bridge_agent_token_issue("inst_X", "hit_inst_X", .Wrapper)
	old_agent := bridge_agent_token_issue("inst_X", "hit_inst_X", .Agent)
	// A different instance whose tokens must be untouched.
	other := bridge_agent_token_issue("inst_Y", "hit_inst_Y", .Wrapper)

	_, ow_ok := bridge_agent_token_verify(old_wrapper.plaintext_token)
	_, oa_ok := bridge_agent_token_verify(old_agent.plaintext_token)
	testing.expect(t, ow_ok && oa_ok, "both old-runtime tokens valid before invalidation")

	n := bridge_agent_token_invalidate_instance("inst_X")
	testing.expect(t, n == 2, "invalidate_instance must invalidate BOTH inst_X tokens")

	_, ow_after := bridge_agent_token_verify(old_wrapper.plaintext_token)
	_, oa_after := bridge_agent_token_verify(old_agent.plaintext_token)
	testing.expect(t, !ow_after && !oa_after, "old-runtime tokens must NOT verify after invalidation")

	_, other_ok := bridge_agent_token_verify(other.plaintext_token)
	testing.expect(t, other_ok, "a different instance's token must survive")

	// Idempotent: invalidating again finds nothing left to do.
	testing.expect(t, bridge_agent_token_invalidate_instance("inst_X") == 0, "re-invalidation is a no-op")

	// The NEW runtime re-issues a token that is cryptographically distinct from
	// the old one (non-deterministic), so old vs new are never confusable.
	new_wrapper := bridge_agent_token_issue("inst_X", "hit_inst_X", .Wrapper)
	testing.expect(t, new_wrapper.plaintext_token != old_wrapper.plaintext_token, "re-issued token must differ from the invalidated one (non-deterministic)")
	_, nw_ok := bridge_agent_token_verify(new_wrapper.plaintext_token)
	testing.expect(t, nw_ok, "the newly issued token verifies")
}
