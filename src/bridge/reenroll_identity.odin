package main

// Re-enrolling the SAME bridge id (bridge reuse, chain "new vs reuse identity").
//
// When the approver reuses this bridge's previous id, the new enrollment lands in
// the SAME (hub, bridge id) keystore scope as the enrollment it replaces: same
// identity slot, same epoch floor, same default credential path. Every rollback
// path of an enrollment deletes the identity it committed, so without care a
// rolled-back re-enrollment would destroy the still-working previous one (whose
// hub identity is only retired once the new enrollment COMMITS).
//
// So the previous enrollment is kept until the new one commits:
//
//   1. JOURNAL: `<config>.reenroll` (0600) records {bridge_id, hub, token_file}.
//      Written first, so a crash at any later point is found by recovery.
//   2. BACKUP: the previous .Identity and .Epoch_Floor are copied VERBATIM into
//      .Identity_Previous / .Epoch_Floor_Previous (identity last: its presence is
//      what makes the backup complete).
//   3. The new identity and an empty floor are written as for a fresh enrollment.
//   4. COMMIT (hub committed, credential promoted): drop the backup, then remove the
//      journal — both BEFORE the staging marker is removed, so "journal without a
//      marker" always means "never acknowledged".
//      ROLLBACK (refused, expired, failed, or the hub rolled it back): restore the
//      backup over the new identity, then remove the journal.
//   5. RECOVERY, under the config lock (bridge_reenroll_recover): a journal whose
//      staging marker is present is left to the atomic-enrollment recovery, which
//      promotes or discards and resolves the journal with it; a journal with no
//      marker never reached the ack, so the hub never committed: restore.
//
// The vault keyring is NOT backed up: it is the same account's keyring, and a
// restored bridge simply starts locked until the browser unlocks it again.

import "core:crypto"
import "core:fmt"
import "core:os"
import "core:strings"
import vault "odin_test:lib/vault"

BRIDGE_REENROLL_JOURNAL_SUFFIX :: ".reenroll"

// Large enough for any raw identity record or epoch floor (the OS backends cap
// both well below it).
@(private = "file")
KEYSTORE_SLOT_COPY_MAX :: 4096

Bridge_Reenroll_Journal :: struct {
	bridge_id:  string,
	hub:        string,
	token_file: string,
}

bridge_reenroll_journal_path :: proc(config_path: string) -> string {
	if strings.trim_space(config_path) == "" do return ""
	return strings.concatenate({config_path, BRIDGE_REENROLL_JOURNAL_SUFFIX}, context.temp_allocator)
}

// bridge_reenroll_journal_read reads the journal next to config_path. ok=false when
// there is none or it does not parse. Strings are temp-allocated.
bridge_reenroll_journal_read :: proc(config_path: string) -> (j: Bridge_Reenroll_Journal, ok: bool) {
	path := bridge_reenroll_journal_path(config_path)
	if path == "" || !os.exists(path) do return {}, false
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return {}, false
	if !vault.wire_decode(strings.trim_space(string(data)), &j) do return {}, false
	if !keystore_bridge_id_is_enrolled(j.bridge_id) do return {}, false
	return j, true
}

// ===== Keystore backup of the previous enrollment =====

// keystore_slot_copy copies one slot's raw bytes into another. A missing source
// deletes the destination (so a stale copy never survives) and reports .Not_Found.
@(private = "file")
keystore_slot_copy :: proc(from, to: Keystore_Slot, bridge_id: string) -> Keystore_Read_Status {
	buf: [KEYSTORE_SLOT_COPY_MAX]byte
	defer crypto.zero_explicit(&buf, size_of(buf))
	n, status := keystore_backend_read(from, bridge_id, buf[:])
	switch status {
	case .Found:
		if keystore_backend_write(to, bridge_id, buf[:n]) != 0 do return .Error
		return .Found
	case .Not_Found:
		if !keystore_backend_delete(to, bridge_id) do return .Error
		return .Not_Found
	case .Error:
	}
	return .Error
}

// keystore_identity_backup_status reports whether a backup of a previous
// enrollment exists for bridge_id.
keystore_identity_backup_status :: proc(bridge_id: string) -> Keystore_Read_Status {
	buf: [KEYSTORE_SLOT_COPY_MAX]byte
	defer crypto.zero_explicit(&buf, size_of(buf))
	_, status := keystore_backend_read(.Identity_Previous, bridge_id, buf[:])
	return status
}

// keystore_identity_backup_create copies the current identity record and epoch
// floor aside. Fails when there is no readable identity to keep, or when a backup
// already exists (an earlier re-enrollment is unresolved: never overwrite it).
keystore_identity_backup_create :: proc(bridge_id: string) -> bool {
	if !keystore_bridge_id_ok(bridge_id) do return false
	if keystore_identity_backup_status(bridge_id) != .Not_Found do return false
	if keystore_slot_copy(.Epoch_Floor, .Epoch_Floor_Previous, bridge_id) == .Error do return false
	// The identity copy is written last: its presence marks a complete backup.
	if keystore_slot_copy(.Identity, .Identity_Previous, bridge_id) != .Found {
		_ = keystore_backend_delete(.Epoch_Floor_Previous, bridge_id)
		return false
	}
	return true
}

// keystore_identity_backup_restore puts the backed-up identity and floor back over
// whatever the slots hold now, then removes the backup. True (and a no-op) when
// there is no backup.
keystore_identity_backup_restore :: proc(bridge_id: string) -> bool {
	if !keystore_bridge_id_ok(bridge_id) do return false
	switch keystore_identity_backup_status(bridge_id) {
	case .Not_Found:
		_ = keystore_backend_delete(.Epoch_Floor_Previous, bridge_id) // a half-made backup
		return true
	case .Error:
		return false
	case .Found:
	}
	if keystore_slot_copy(.Identity_Previous, .Identity, bridge_id) != .Found do return false
	if keystore_slot_copy(.Epoch_Floor_Previous, .Epoch_Floor, bridge_id) == .Error do return false
	return keystore_identity_backup_drop(bridge_id)
}

// keystore_identity_backup_drop forgets the backup (the re-enrollment committed).
keystore_identity_backup_drop :: proc(bridge_id: string) -> bool {
	if !keystore_bridge_id_ok(bridge_id) do return true
	id_ok := keystore_backend_delete(.Identity_Previous, bridge_id)
	floor_ok := keystore_backend_delete(.Epoch_Floor_Previous, bridge_id)
	return id_ok && floor_ok
}

// ===== The re-enrollment lifecycle =====

// REQ-ENROLL-REPLACE: approval can select an existing identity even when this
// install has no config/reuse hint. Caller holds the target's scope lock. Always
// journal and back up an existing identity before attempting its replacement.
bridge_enroll_commit_identity :: proc(config_path, hub_url, bridge_id, token_file, owner_user_id: string) -> bool {
	existing: Bridge_Identity_Record
	status := keystore_read_identity(bridge_id, &existing)
	crypto.zero_explicit(&existing, size_of(existing))
	replacing := status != .Not_Found
	if replacing && !bridge_reenroll_begin(config_path, hub_url, bridge_id, token_file) {
		fmt.eprintfln("bridge enroll FAILED: could not back up the previous identity of %s (or an earlier re-enrollment is unresolved). Nothing was written.", bridge_id)
		return false
	}
	if !bridge_unseal_identity_commit_enrollment(bridge_id, owner_user_id, replacing) {
		if replacing do _ = bridge_reenroll_resolve(config_path, bridge_id, false)
		return false
	}
	return true
}

// bridge_reenroll_begin journals and backs up the previous enrollment of bridge_id
// before its identity is replaced. On false nothing changed (no journal is left).
bridge_reenroll_begin :: proc(config_path, hub_url, bridge_id, token_file: string) -> bool {
	path := bridge_reenroll_journal_path(config_path)
	if path == "" || !keystore_bridge_id_ok(bridge_id) do return false
	// An unresolved re-enrollment (its journal or backup still present) is never
	// overwritten: replacing its journal would orphan the backup it points at.
	if os.exists(path) || keystore_identity_backup_status(bridge_id) != .Not_Found do return false
	text, ok := vault.wire_encode(Bridge_Reenroll_Journal{bridge_id = bridge_id, hub = hub_url, token_file = token_file}, context.temp_allocator)
	if !ok || !bridge_write_secret_file(path, text) do return false
	if !keystore_identity_backup_create(bridge_id) {
		_ = os.remove(path)
		return false
	}
	return true
}

// bridge_reenroll_resolve finishes the re-enrollment of bridge_id journaled next to
// config_path: committed drops the backup, otherwise the backup is restored. The
// journal is removed only once that succeeded. handled=false when no journal names
// bridge_id (an ordinary, new-id enrollment).
bridge_reenroll_resolve :: proc(config_path, bridge_id: string, committed: bool) -> (handled: bool) {
	j, ok := bridge_reenroll_journal_read(config_path)
	if !ok || j.bridge_id != bridge_id do return false
	done := keystore_identity_backup_drop(bridge_id) if committed else keystore_identity_backup_restore(bridge_id)
	if done do _ = os.remove(bridge_reenroll_journal_path(config_path))
	return true
}

// bridge_enroll_discard_identity undoes the identity an enrollment committed: a
// re-enrollment of the same id restores the previous one; a new id is deleted.
// Call it ONCE per rolled-back enrollment (a second call would delete the
// restored identity).
bridge_enroll_discard_identity :: proc(config_path, bridge_id: string) {
	if bridge_reenroll_resolve(config_path, bridge_id, false) do return
	_ = keystore_delete_identity_key(bridge_id)
}

// bridge_reenroll_recover resolves a journal a crash left behind. Run it with the
// config lock held and the keystore bound to the config's hub. A journal whose
// staging marker exists is left alone: the atomic-enrollment recovery owns it.
bridge_reenroll_recover :: proc(config_path: string) {
	j, ok := bridge_reenroll_journal_read(config_path)
	if !ok do return
	if j.token_file != "" && os.exists(strings.concatenate({j.token_file, BRIDGE_ENROLL_MARKER_SUFFIX}, context.temp_allocator)) do return
	bound, b_ok := bridge_hub_canonical_base(bridge_keystore_hub(), context.temp_allocator)
	want, w_ok := bridge_hub_canonical_base(j.hub, context.temp_allocator)
	if !b_ok || !w_ok || bound != want do return // another hub's scope: resolved when that hub is bound
	if bridge_reenroll_resolve(config_path, j.bridge_id, false) {
		bridge_unseal_forget_identity()
		fmt.printfln("bridge enroll recovery: a re-enrollment of %s was never committed; restored its previous identity", j.bridge_id)
	}
}
