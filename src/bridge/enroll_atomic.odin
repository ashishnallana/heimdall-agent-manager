package main

// Atomic enrollment, bridge half (REQ-EA-4, plan task_18df06006e581bed).
//
// Against a hub that reports "enrollment_pending":true, an approval does NOT enroll
// this machine. The hub holds a pending credential that authenticates only the
// enroll-only socket, and commits the enrollment when this process answers the
// relayed vault key with ok:true. So the order of this process's own writes is the
// safety property:
//
//   1. Nothing is written at approval. The enroll-only runtime is seeded with the
//      credential IN MEMORY (bridge_enroll_atomic_seed_config).
//   2. On a bridge_unseal: decrypt, store in the OS keystore, read it back the way
//      the restarted service will, write the token, refresh token and config.toml
//      — and only then answer ok:true (bridge_enroll_atomic_on_unseal). Any step
//      failing undoes the earlier ones and answers an error: the hub then does not
//      commit, and the browser can retry until the pending deadline.
//   3. The hub answers with bridge_enrollment_result. committed:false — the sweep or
//      the operator rolled the enrollment back in the window — undoes everything
//      this process wrote, restoring what was on disk before.
//
// A deadline with no delivery, or a refusal, prints "enrollment rolled back" and
// leaves the machine as it was. The one window not covered is a crash between the
// writes in (2) and the hub's commit: the files then hold a credential the hub's
// sweep revokes, so the service fails authentication rather than running enrolled.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

// BRIDGE_ENROLL_ATOMIC_WAIT_SECONDS matches the hub's BRIDGE_ENROLL_PENDING_SECONDS:
// past it the hub has rolled the enrollment back, so waiting longer is pointless.
BRIDGE_ENROLL_ATOMIC_WAIT_SECONDS :: 300
// How long to wait for the hub's verdict after answering ok:true. The hub commits
// synchronously before it answers the browser, so this only covers a slow link.
BRIDGE_ENROLL_ATOMIC_RESULT_SECONDS :: 30

Bridge_Enroll_Atomic_State :: enum {
	Waiting,     // no key yet, or the last delivery failed (the browser may retry)
	Acked,       // key stored and files written; answered ok:true
	Committed,   // the hub reported committed:true
	Rolled_Back, // the hub reported committed:false
}

// A file's content before this process touched it, so a rollback can restore it.
@(private = "file")
Bridge_File_Snapshot :: struct {
	path:    string,
	existed: bool,
	content: []byte,
}

@(private = "file")
Bridge_Enroll_Atomic :: struct {
	mu:          sync.Mutex,
	active:      bool,
	state:       Bridge_Enroll_Atomic_State,
	last_error:  string,
	cred:        Bridge_Enroll_Credential,
	token_file:  string,
	config_path: string,
	api_base:    string,
	snapshots:   [dynamic]Bridge_File_Snapshot,
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
	bridge_file_snapshots_free(&g_enroll_atomic.snapshots)
	delete(g_enroll_atomic.snapshots)
	delete(g_enroll_atomic.token_file)
	delete(g_enroll_atomic.config_path)
	delete(g_enroll_atomic.api_base)
	g_enroll_atomic = Bridge_Enroll_Atomic{}
}

// bridge_enroll_atomic_state reports where the enrollment is.
bridge_enroll_atomic_state :: proc() -> Bridge_Enroll_Atomic_State {
	sync.mutex_lock(&g_enroll_atomic.mu)
	defer sync.mutex_unlock(&g_enroll_atomic.mu)
	return g_enroll_atomic.state
}

@(private = "file")
bridge_file_snapshot_take :: proc(path: string) -> Bridge_File_Snapshot {
	snap := Bridge_File_Snapshot{path = strings.clone(path)}
	if data, err := os.read_entire_file(path, context.allocator); err == nil {
		snap.existed = true
		snap.content = data
	}
	return snap
}

@(private = "file")
bridge_file_snapshot_restore :: proc(snap: Bridge_File_Snapshot) {
	if !snap.existed {
		_ = os.remove(snap.path)
		return
	}
	_ = os.write_entire_file(snap.path, snap.content, os.Permissions{.Read_User, .Write_User})
}

@(private = "file")
bridge_file_snapshots_free :: proc(snaps: ^[dynamic]Bridge_File_Snapshot) {
	for s in snaps {
		if len(s.content) > 0 do mem.zero_explicit(raw_data(s.content), len(s.content))
		delete(s.content)
		delete(s.path)
	}
	clear(snaps)
}

// bridge_enroll_atomic_undo_locked restores every file this process wrote and
// purges the delivered key. The caller holds g_enroll_atomic.mu.
@(private = "file")
bridge_enroll_atomic_undo_locked :: proc() {
	for s in g_enroll_atomic.snapshots do bridge_file_snapshot_restore(s)
	bridge_file_snapshots_free(&g_enroll_atomic.snapshots)
	keystore_lock_and_purge(g_enroll_atomic.cred.bridge_id)
	_ = bridge_vault_set_configured(g_enroll_atomic.cred.bridge_id, false)
}

// bridge_enroll_atomic_persist_locked writes the credential and config, snapshotting
// each file first. The caller holds g_enroll_atomic.mu.
@(private = "file")
bridge_enroll_atomic_persist_locked :: proc() -> bool {
	a := &g_enroll_atomic
	append(&a.snapshots, bridge_file_snapshot_take(a.token_file))
	if strings.trim_space(a.cred.refresh_token) != "" {
		append(&a.snapshots, bridge_file_snapshot_take(bridge_enroll_refresh_file_for(a.token_file, context.temp_allocator)))
	}
	if strings.trim_space(a.config_path) != "" {
		append(&a.snapshots, bridge_file_snapshot_take(a.config_path))
	}
	return bridge_enroll_persist(a.cred, a.token_file, a.config_path, a.api_base)
}

// bridge_enroll_atomic_on_unseal runs on the hub socket's thread for a bridge_unseal
// in an atomic enrollment, and decides the answer (step 2 above). On failure every
// write it made is undone, so the next delivery starts clean.
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
	if !bridge_enroll_atomic_persist_locked() {
		bridge_enroll_atomic_undo_locked()
		return false, "the vault key was stored but this bridge's credential could not be written"
	}
	_ = bridge_vault_set_configured(a.cred.bridge_id, true)
	a.state = .Acked
	return true, ""
}

// bridge_enroll_atomic_on_result applies the hub's verdict (step 3 above).
bridge_enroll_atomic_on_result :: proc(text: string) {
	committed := extract_json_bool(text, "committed", false)
	sync.mutex_lock(&g_enroll_atomic.mu)
	defer sync.mutex_unlock(&g_enroll_atomic.mu)
	a := &g_enroll_atomic
	if !a.active do return
	if committed {
		if a.state == .Acked do a.state = .Committed
		return
	}
	if a.state == .Acked || a.state == .Committed do bridge_enroll_atomic_undo_locked()
	if a.state != .Rolled_Back do fmt.println("bridge enroll: the hub reported this enrollment rolled back")
	a.state = .Rolled_Back
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
	fmt.eprintln("  Nothing was kept: this machine is not enrolled and no credential or vault key was saved.")
	fmt.eprintln("  Run `ham-bridge enroll --hub <url>` again to retry.")
}

// bridge_enroll_atomic_run holds the enroll-only socket open until the vault key is
// delivered and the hub commits, or the deadline passes. Returns true only when the
// hub reported the enrollment committed (or, after a successful ack, did not answer
// at all — see below).
bridge_enroll_atomic_run :: proc(args: []string, cred: Bridge_Enroll_Credential, token_file, config_path, api_base: string) -> bool {
	if !bridge_enroll_credential_usable(cred.access_token) {
		fmt.eprintln("enroll FAILED: the Hub returned an access token this bridge will not accept (empty, unprefixed, or missing its secret half); nothing was written")
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
				// The key and credential are saved and the hub was told; it just did
				// not say whether it committed (an older hub never does). Keep the
				// files: if the hub rolled back, its sweep revoked the credential and
				// the service will report that, which is recoverable. Destroying a
				// committed enrollment here would not be.
				fmt.println("")
				fmt.printfln("bridge enroll: vault key delivered and saved for bridge_id=%s, but the hub did not confirm the commit.", cred.bridge_id)
				fmt.println("  If Settings → Bridges does not show this machine, run `ham-bridge enroll` again.")
				return true
			}
		case .Waiting:
			if time.tick_since(deadline) > BRIDGE_ENROLL_ATOMIC_WAIT_SECONDS * time.Second {
				sync.mutex_lock(&g_enroll_atomic.mu)
				if g_enroll_atomic.state == .Waiting {
					keystore_lock_and_purge(cred.bridge_id)
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
