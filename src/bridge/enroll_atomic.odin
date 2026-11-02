package main

// Atomic enrollment, bridge half (REQ-EA-4, plan task_18df06006e581bed).
//
// Against a hub that reports "enrollment_pending":true, an approval does NOT enroll
// this machine. The hub holds a pending credential that authenticates only the
// enroll-only socket, and commits the enrollment when this process answers the
// relayed vault key with ok:true. This process's writes are TWO-PHASE, so no crash
// point leaves a machine that is usable but not enrolled, or enrolled but without its
// credential:
//
//   1. Nothing is written at approval. The enroll-only runtime is seeded with the
//      credential IN MEMORY (bridge_enroll_atomic_seed_config).
//   2. STAGE, then ack. On a bridge_unseal: decrypt, store in the OS keystore, read it
//      back the way the restarted service will, write the token, refresh token and
//      config.toml as `<file>.pending` siblings, then the marker
//      `<token file>.enrolling` LAST — and only then answer ok:true. The live files
//      are untouched. Any failure removes the staging and answers an error: the hub
//      does not commit, and the browser can retry until the deadline.
//   3. PROMOTE or DISCARD on the hub's bridge_enrollment_result: committed:true renames
//      the staged files over the live ones (refresh first, as the refresh worker
//      orders them) and removes the marker; committed:false removes the staging and
//      purges the key, leaving the previous files exactly as they were.
//   4. RECOVER (bridge_enroll_atomic_recover), at every service start and every
//      `enroll`, for a process that died between 2 and 3. Staging without a marker
//      never reached the ack, so it is discarded. With a marker, the staged refresh
//      token is presented to the hub: it rotates only for a COMMITTED family (the hub
//      refuses refresh for a pending one), so success promotes the staging with the
//      rotated pair, and invalid_grant discards it and purges the key. An unreachable
//      hub leaves the staging for the next start.
//
// A deadline with no delivery, or a refusal, prints "enrollment rolled back".

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import cfg_lib "odin_test:lib/config"
import vault "odin_test:lib/vault"

// BRIDGE_ENROLL_ATOMIC_WAIT_SECONDS matches the hub's BRIDGE_ENROLL_PENDING_SECONDS:
// past it the hub has rolled the enrollment back, so waiting longer is pointless.
BRIDGE_ENROLL_ATOMIC_WAIT_SECONDS :: 300
// How long to wait for the hub's verdict after answering ok:true. The hub commits
// synchronously before it answers the browser, so this only covers a slow link.
BRIDGE_ENROLL_ATOMIC_RESULT_SECONDS :: 30

BRIDGE_ENROLL_STAGE_SUFFIX :: ".pending"
BRIDGE_ENROLL_MARKER_SUFFIX :: ".enrolling"

Bridge_Enroll_Atomic_State :: enum {
	Waiting,     // no key yet, or the last delivery failed (the browser may retry)
	Acked,       // key stored and files STAGED; answered ok:true
	Committed,   // the hub reported committed:true and the staging was promoted
	Rolled_Back, // the hub reported committed:false; the staging was discarded
}

@(private = "file")
Bridge_Enroll_Atomic :: struct {
	mu:          sync.Mutex,
	active:      bool,
	state:       Bridge_Enroll_Atomic_State,
	cred:        Bridge_Enroll_Credential,
	token_file:  string,
	config_path: string,
	api_base:    string,
}

@(private = "file")
g_enroll_atomic: Bridge_Enroll_Atomic

// bridge_enroll_atomic_is_active reports whether this process is an atomic
// enrollment, i.e. whether a bridge_unseal must persist before it is acknowledged.
bridge_enroll_atomic_is_active :: proc() -> bool {
	sync.mutex_lock(&g_enroll_atomic.mu)
	defer sync.mutex_unlock(&g_enroll_atomic.mu)
	return g_enroll_atomic.active
}

// bridge_enroll_atomic_arm makes the next bridge_unseal on this process persist
// before it acknowledges. Separate from _run so tests can drive the state machine
// without a hub socket.
bridge_enroll_atomic_arm :: proc(cred: Bridge_Enroll_Credential, token_file, config_path, api_base: string) {
	sync.mutex_lock(&g_enroll_atomic.mu)
	defer sync.mutex_unlock(&g_enroll_atomic.mu)
	g_enroll_atomic.active = true
	g_enroll_atomic.state = .Waiting
	g_enroll_atomic.cred = cred
	g_enroll_atomic.token_file = strings.clone(token_file)
	g_enroll_atomic.config_path = strings.clone(config_path)
	g_enroll_atomic.api_base = strings.clone(api_base)
}

// bridge_enroll_atomic_disarm returns the process to an ordinary bridge (tests).
bridge_enroll_atomic_disarm :: proc() {
	sync.mutex_lock(&g_enroll_atomic.mu)
	defer sync.mutex_unlock(&g_enroll_atomic.mu)
	delete(g_enroll_atomic.token_file)
	delete(g_enroll_atomic.config_path)
	delete(g_enroll_atomic.api_base)
	// Keep the held mutex intact; resetting it before the deferred unlock
	// corrupts Windows SRWLOCK state and hangs the next enrollment test.
	g_enroll_atomic.active = false
	g_enroll_atomic.state = .Waiting
	g_enroll_atomic.cred = {}
	g_enroll_atomic.token_file = ""
	g_enroll_atomic.config_path = ""
	g_enroll_atomic.api_base = ""
}

// bridge_enroll_atomic_state reports where the enrollment is.
bridge_enroll_atomic_state :: proc() -> Bridge_Enroll_Atomic_State {
	sync.mutex_lock(&g_enroll_atomic.mu)
	defer sync.mutex_unlock(&g_enroll_atomic.mu)
	return g_enroll_atomic.state
}

// ===== Staging: paths and the marker =====

// Bridge_Enroll_Stage names every file of one staged enrollment. All strings are
// temp-allocated.
Bridge_Enroll_Stage :: struct {
	token_file, refresh_file, config_path: string, // the LIVE files
	marker: string,
}

bridge_enroll_stage_for :: proc(token_file, config_path: string) -> Bridge_Enroll_Stage {
	return Bridge_Enroll_Stage{
		token_file = token_file,
		refresh_file = bridge_enroll_refresh_file_for(token_file, context.temp_allocator),
		config_path = config_path,
		marker = strings.concatenate({token_file, BRIDGE_ENROLL_MARKER_SUFFIX}, context.temp_allocator),
	}
}

@(private = "file")
staged :: proc(path: string) -> string {
	return strings.concatenate({path, BRIDGE_ENROLL_STAGE_SUFFIX}, context.temp_allocator)
}

@(private = "file")
file_exists :: proc(path: string) -> bool {
	return path != "" && os.exists(path)
}

// bridge_enroll_stage_discard removes the staging and the marker; the live files
// are never touched. Idempotent.
bridge_enroll_stage_discard :: proc(st: Bridge_Enroll_Stage) {
	_ = os.remove(st.marker)
	_ = os.remove(staged(st.token_file))
	_ = os.remove(staged(st.refresh_file))
	if st.config_path != "" do _ = os.remove(staged(st.config_path))
}

// bridge_enroll_stage_write writes the credential and config as .pending siblings,
// then the marker last: a marker means the staging is complete. Nothing live changes.
@(private = "file")
bridge_enroll_stage_write :: proc(st: Bridge_Enroll_Stage, cred: Bridge_Enroll_Credential, api_base: string) -> bool {
	if !bridge_enroll_credential_usable(cred.access_token) do return false
	if !bridge_write_credential_file(staged(st.token_file), api_base, cred.bridge_id, cred.access_token) do return false
	if strings.trim_space(cred.refresh_token) != "" {
		if !bridge_enroll_credential_usable(cred.refresh_token) do return false
		if !bridge_write_secret_file(staged(st.refresh_file), cred.refresh_token) do return false
	}
	if st.config_path != "" {
		existing := ""
		if data, err := os.read_entire_file(st.config_path, context.temp_allocator); err == nil do existing = string(data)
		// Empty token argument on purpose: nothing secret goes to config.toml (F2).
		merged := bridge_config_merge(existing, api_base, "", cred.bridge_id)
		defer delete(merged)
		if os.write_entire_file(staged(st.config_path), transmute([]byte)merged) != nil do return false
	}
	marker_json, marker_ok := vault.wire_encode(Bridge_Enroll_Stage_Marker{bridge_id = cred.bridge_id, hub = api_base}, context.temp_allocator)
	if !marker_ok do return false
	marker := strings.concatenate({marker_json, "\n"}, context.temp_allocator)
	return os.write_entire_file(st.marker, transmute([]byte)marker, os.Permissions{.Read_User, .Write_User}) == nil
}

// Bridge_Enroll_Stage_Marker is the staging marker file: which enrollment, against
// which hub, the staged files belong to.
Bridge_Enroll_Stage_Marker :: struct {
	bridge_id: string,
	hub:       string,
}

// Bridge_Enrollment_Result is the hub's bridge_enrollment_result frame.
Bridge_Enrollment_Result :: struct {
	committed: bool,
}

// bridge_enroll_stage_promote renames the staging over the live files and removes
// the marker LAST, so a crash midway is finished by the next recovery. The refresh
// half goes first for the reason the refresh worker writes it first. A
// re-enrollment of the same bridge id (reenroll_identity.odin) drops the previous
// identity's backup before the marker goes: the commit is final.
bridge_enroll_stage_promote :: proc(st: Bridge_Enroll_Stage, bridge_id: string) -> bool {
	ok := true
	for path in ([3]string{st.refresh_file, st.token_file, st.config_path}) {
		if path == "" || !file_exists(staged(path)) do continue
		if err := os.rename(staged(path), path); err != nil {
			fmt.eprintfln("bridge enroll: could not move %s into place: %v", staged(path), err)
			ok = false
		}
	}
	if ok {
		_ = bridge_reenroll_resolve(st.config_path, bridge_id, true)
		_ = os.remove(st.marker)
	}
	return ok
}

// bridge_enroll_atomic_discard_locked undoes a staged enrollment: staging gone, key
// purged. The caller holds g_enroll_atomic.mu.
@(private = "file")
bridge_enroll_atomic_discard_locked :: proc() {
	a := &g_enroll_atomic
	bridge_enroll_stage_discard(bridge_enroll_stage_for(a.token_file, a.config_path))
	keystore_lock_and_purge(a.cred.bridge_id)
	bridge_enroll_discard_identity(a.config_path, a.cred.bridge_id)
}

// bridge_enroll_atomic_on_unseal runs on the hub socket's thread for a bridge_unseal
// in an atomic enrollment, and decides the answer (step 2 above).
bridge_enroll_atomic_on_unseal :: proc(text: string, now_ms: i64) -> (ok: bool, err_msg: string) {
	sync.mutex_lock(&g_enroll_atomic.mu)
	defer sync.mutex_unlock(&g_enroll_atomic.mu)
	a := &g_enroll_atomic
	if a.state != .Waiting {
		// Already answered ok (a relay retry): answer the same, write nothing again.
		if a.state == .Acked || a.state == .Committed do return true, ""
		return false, "this enrollment was rolled back; run `ham-bridge enroll` again"
	}
	decrypted, decrypt_err := bridge_unseal_decrypt_and_verify(text, a.cred.bridge_id, now_ms)
	if !decrypted {
		keystore_lock_and_purge(a.cred.bridge_id)
		return false, decrypt_err
	}
	when ODIN_OS == .Linux || ODIN_OS == .Darwin {
		if !bridge_enroll_vault_key_persisted(a.cred.bridge_id) {
			keystore_lock_and_purge(a.cred.bridge_id)
			return false, "the vault key was decrypted but could not be read back from the OS keystore"
		}
	}
	st := bridge_enroll_stage_for(a.token_file, a.config_path)
	if !bridge_enroll_stage_write(st, a.cred, a.api_base) {
		bridge_enroll_atomic_discard_locked()
		return false, "the vault key was stored but this bridge's credential could not be staged"
	}
	a.state = .Acked
	return true, ""
}

// bridge_enroll_atomic_on_result applies the hub's verdict (step 3 above).
bridge_enroll_atomic_on_result :: proc(text: string) {
	verdict: Bridge_Enrollment_Result
	committed := vault.wire_decode(text, &verdict) && verdict.committed // malformed: not committed
	sync.mutex_lock(&g_enroll_atomic.mu)
	defer sync.mutex_unlock(&g_enroll_atomic.mu)
	a := &g_enroll_atomic
	if !a.active do return
	if committed {
		if a.state == .Acked {
			if !bridge_enroll_stage_promote(bridge_enroll_stage_for(a.token_file, a.config_path), a.cred.bridge_id) {
				// The hub committed; the marker stays, so the next start finishes this.
				fmt.eprintln("bridge enroll: committed, but the credential could not be moved into place; the next start will finish it")
			}
			a.state = .Committed
		}
		return
	}
	// A commit is final at the hub: a later committed:false (a stale or duplicate
	// verdict) must never undo it.
	if a.state == .Committed do return
	if a.state == .Acked {
		bridge_enroll_atomic_discard_locked()
	} else if a.state == .Waiting {
		// Nothing was staged, but the identity committed at approval goes (or, for a
		// re-enrollment, the previous one comes back).
		bridge_enroll_discard_identity(a.config_path, a.cred.bridge_id)
	}
	if a.state != .Rolled_Back do fmt.println("bridge enroll: the hub reported this enrollment rolled back")
	a.state = .Rolled_Back
}

// ===== Recovery (step 4) =====

Bridge_Enroll_Recovery :: enum {
	None,        // nothing staged
	Discarded,   // staging that never reached the ack, or a rolled-back enrollment
	Promoted,    // a committed enrollment whose promotion had not finished
	Unresolved,  // the hub could not be asked; the staging is kept for the next start
}

// Bridge_Enroll_Refresh_Proc is the hub probe, injectable for tests; nil means the
// real refresh call.
Bridge_Enroll_Refresh_Proc :: proc(api_base, refresh_token: string) -> (Bridge_Enroll_Credential, Bridge_Refresh_Outcome)

// bridge_enroll_atomic_recover_paths resolves a staged enrollment left by a process
// that died between staging and promotion.
bridge_enroll_atomic_recover_paths :: proc(token_file, config_path: string, refresh: Bridge_Enroll_Refresh_Proc = nil) -> Bridge_Enroll_Recovery {
	if strings.trim_space(token_file) == "" do return .None
	st := bridge_enroll_stage_for(token_file, config_path)
	has_marker := file_exists(st.marker)
	has_staging := file_exists(staged(st.token_file)) || file_exists(staged(st.refresh_file)) || (config_path != "" && file_exists(staged(config_path)))
	if !has_marker && !has_staging do return .None
	marker_bridge_id, marker_hub := "", ""
	if data, err := os.read_entire_file(st.marker, context.temp_allocator); err == nil {
		marker: Bridge_Enroll_Stage_Marker
		if vault.wire_decode(string(data), &marker) {
			marker_bridge_id, marker_hub = marker.bridge_id, marker.hub
		}
	}
	// Keystore items are scoped to the hub the staged enrollment was made with.
	if marker_hub != "" do _ = bridge_keystore_set_hub(marker_hub)
	if !has_marker || marker_bridge_id == "" {
		// Incomplete staging never reached the ack, so the hub never committed it.
		bridge_enroll_stage_discard(st)
		fmt.println("bridge enroll recovery: discarded an incomplete staged enrollment")
		return .Discarded
	}
	refresh_token, has_refresh := bridge_read_token_file(staged(st.refresh_file))
	if !has_refresh || !file_exists(staged(st.token_file)) {
		// Promotion was underway: whatever is still staged is the committed credential.
		if bridge_enroll_stage_promote(st, marker_bridge_id) do return .Promoted
		return .Unresolved
	}
	defer delete(refresh_token)
	rotated: Bridge_Enroll_Credential
	outcome: Bridge_Refresh_Outcome
	if refresh != nil {
		rotated, outcome = refresh(marker_hub, refresh_token)
	} else {
		rotated, outcome = bridge_credential_refresh_once(marker_hub, refresh_token)
	}
	switch outcome {
	case .Rotated:
		// Committed at the hub. The staged pair is now spent: stage the rotated one.
		_ = bridge_write_secret_file(staged(st.refresh_file), rotated.refresh_token)
		_ = bridge_write_credential_file(staged(st.token_file), marker_hub, marker_bridge_id, rotated.access_token)
		if bridge_enroll_stage_promote(st, marker_bridge_id) {
			fmt.printfln("bridge enroll recovery: enrollment of %s was committed; credential moved into place", marker_bridge_id)
			return .Promoted
		}
		return .Unresolved
	case .Revoked:
		bridge_enroll_stage_discard(st)
		keystore_lock_and_purge(marker_bridge_id)
		bridge_enroll_discard_identity(config_path, marker_bridge_id)
		fmt.printfln("bridge enroll recovery: enrollment of %s was rolled back by the hub; discarded its staged credential and key", marker_bridge_id)
		return .Discarded
	case .Retry:
	}
	fmt.println("bridge enroll recovery: the hub could not be reached to resolve a staged enrollment; will retry at the next start")
	return .Unresolved
}

// bridge_enroll_atomic_recover runs recovery for the paths the command line names.
// With no explicit credential file the credential path is per (hub, bridge id); the
// staged config (written before the marker) names both.
bridge_enroll_atomic_recover :: proc(args: []string) -> Bridge_Enroll_Recovery {
	config_path := cfg_lib.config_path_from_args(args)
	token_file := bridge_enroll_token_file_from_args(args, "", "", context.temp_allocator)
	if token_file == "" && config_path != "" && file_exists(staged(config_path)) {
		if loaded, ok := cfg_lib.load(staged(config_path)); ok {
			token_file = bridge_enroll_token_file_from_args(args, loaded.config.wrapper.daemon_url, strings.trim_space(loaded.config.daemon.daemon_id), context.temp_allocator)
		}
	}
	if token_file == "" do return .None
	return bridge_enroll_atomic_recover_paths(token_file, config_path)
}

// bridge_enroll_atomic_seed_config builds the enroll-only runtime's config from the
// command line and the credential held in memory, since nothing is on disk yet.
@(private = "file")
bridge_enroll_atomic_seed_config :: proc(args: []string, cred: Bridge_Enroll_Credential, api_base: string) {
	bridge_config = bridge_config_from_args(args)
	bridge_config.bridge_token = strings.clone(strings.trim_space(cred.access_token))
	bridge_config.daemon_id = strings.clone(cred.bridge_id)
	bridge_config.daemon_url = strings.clone(api_base)
}

// bridge_enroll_atomic_rolled_back prints the single outcome a failed atomic
// enrollment has, whatever the cause.
@(private = "file")
bridge_enroll_atomic_rolled_back :: proc(reason: string) {
	fmt.eprintfln("bridge enroll FAILED: enrollment rolled back — %s", reason)
	fmt.eprintln("  Nothing was kept: no new credential or vault key was saved (a re-enrolled bridge keeps its previous identity and credential).")
	fmt.eprintln("  Run `ham-bridge enroll --hub <url>` again to retry.")
}

// bridge_enroll_atomic_run holds the enroll-only socket open until the vault key is
// delivered and the hub commits, or the deadline passes. Returns true only when the
// hub reported the enrollment committed (or, after a successful ack, did not answer
// at all — see below).
bridge_enroll_atomic_run :: proc(args: []string, cred: Bridge_Enroll_Credential, token_file, config_path, api_base: string) -> bool {
	if !bridge_enroll_credential_usable(cred.access_token) {
		fmt.eprintln("enroll FAILED: the Hub returned an access token this bridge will not accept (empty, unprefixed, or missing its secret half); nothing was written")
		bridge_enroll_discard_identity(config_path, cred.bridge_id)
		return false
	}
	bridge_enroll_atomic_arm(cred, token_file, config_path, api_base)
	bridge_enrollment_unseal_reset()
	bridge_hub_set_enroll_only_runtime(true)
	bridge_enroll_atomic_seed_config(args, cred, api_base)
	bridge_runtime_init()
	bridge_hub_runtime_start()
	fmt.println("")
	fmt.printfln("Approved. Unlock your vault in the browser to finish (waiting up to %dm).", BRIDGE_ENROLL_ATOMIC_WAIT_SECONDS / 60)
	fmt.println("  This machine is enrolled only once its vault key is delivered; until then nothing is saved.")

	deadline := time.tick_now()
	acked_at: time.Tick
	acked := false
	for {
		state := bridge_enroll_atomic_state()
		switch state {
		case .Committed:
			fmt.println("")
			fmt.printfln("bridge enroll SUCCESS: enrolled as bridge_id=%s (vault unlocked)", cred.bridge_id)
			if cred.approver_username != "" do fmt.printfln("  approved by     %s", cred.approver_username)
			fmt.printfln("  credential      %s (0600)", token_file)
			fmt.println("  nothing secret was written to config.toml (audit F2)")
			bridge_enroll_print_account_fingerprint(cred.bridge_id)
			return true
		case .Rolled_Back:
			bridge_enroll_atomic_rolled_back("the hub cancelled the enrollment before it was committed")
			return false
		case .Acked:
			if !acked {
				acked = true
				acked_at = time.tick_now()
			}
			if time.tick_since(acked_at) > BRIDGE_ENROLL_ATOMIC_RESULT_SECONDS * time.Second {
				// The key and credential are staged and the hub was told; it just did
				// not say whether it committed. Keep the staging: the restarted
				// service resolves it against the hub (bridge_enroll_atomic_recover),
				// promoting a committed enrollment and discarding a rolled-back one.
				fmt.println("")
				fmt.printfln("bridge enroll: vault key delivered for bridge_id=%s, but the hub did not confirm the commit.", cred.bridge_id)
				fmt.println("  The restarted service will check with the hub and finish or discard the enrollment.")
				return true
			}
		case .Waiting:
			if time.tick_since(deadline) > BRIDGE_ENROLL_ATOMIC_WAIT_SECONDS * time.Second {
				sync.mutex_lock(&g_enroll_atomic.mu)
				if g_enroll_atomic.state == .Waiting {
					keystore_lock_and_purge(cred.bridge_id)
					bridge_enroll_discard_identity(config_path, cred.bridge_id)
					g_enroll_atomic.state = .Rolled_Back
					sync.mutex_unlock(&g_enroll_atomic.mu)
					bridge_enroll_atomic_rolled_back("the vault key was not delivered in time")
					return false
				}
				sync.mutex_unlock(&g_enroll_atomic.mu)
			}
		}
		time.sleep(100 * time.Millisecond)
	}
}
