package main

// Persistent anti-rollback floor for unsealed keyrings (follow-up to C1).
//
// A lock deletes the stored keyring, so the superset check in
// bridge_unseal_decrypt_and_verify has nothing to compare a later unseal against.
// The floor survives that: the highest current_epoch ever accepted, and for every
// accepted epoch a commitment to its key,
//
//   commit = HMAC-SHA256(key = epoch key, "heimdall-bridge-epoch-commit-v1|<bridge_id>|<epoch>")
//
// so a later keyring is refused if its current epoch is below the floor or if it
// maps a known epoch to a different key. The commitment reveals nothing about the
// key. The record is created (empty) at enrollment; afterwards "not found" is an
// error, exactly like "unreadable": both refuse every unseal.
//
// Record (keystore slot .Epoch_Floor):
//   "HEF1" | u32be floor_epoch | u16be count | count × (u32be epoch | commit[32])
// entries strictly ascending; at most EPOCH_FLOOR_MAX_ENTRIES (the newest kept).

import "core:crypto"
import "core:crypto/hmac"
import "core:encoding/endian"
import "core:strconv"
import "core:strings"
import vault "odin_test:lib/vault"

EPOCH_FLOOR_MAGIC       :: "HEF1"
EPOCH_FLOOR_INFO        :: "heimdall-bridge-epoch-commit-v1"
EPOCH_FLOOR_COMMIT_BYTES :: 32
EPOCH_FLOOR_MAX_ENTRIES :: vault.KEYRING_MAX_EPOCHS
EPOCH_FLOOR_ENTRY_BYTES :: 4 + EPOCH_FLOOR_COMMIT_BYTES
EPOCH_FLOOR_MAX_BYTES   :: 4 + 4 + 2 + EPOCH_FLOOR_MAX_ENTRIES * EPOCH_FLOOR_ENTRY_BYTES // 2314

Epoch_Floor_Entry :: struct {
	epoch:  u32,
	commit: [EPOCH_FLOOR_COMMIT_BYTES]byte,
}

Epoch_Floor :: struct {
	floor_epoch: u32,
	entries:     [EPOCH_FLOOR_MAX_ENTRIES]Epoch_Floor_Entry,
	count:       int,
}

Epoch_Floor_Error :: enum {
	None,
	Rollback,     // current_epoch below the floor
	Key_Mismatch, // a known epoch with a different key
	Missing_Epoch, // the newest accepted epoch is absent (a keyring of only unknown epochs)
}

epoch_floor_commit :: proc(bridge_id: string, epoch: u32, key: []byte, dst: ^[EPOCH_FLOOR_COMMIT_BYTES]byte) {
	buf: [24]byte
	msg := strings.concatenate({EPOCH_FLOOR_INFO, "|", bridge_id, "|", strconv.write_uint(buf[:], u64(epoch), 10)}, context.temp_allocator)
	hmac.sum(.SHA256, dst[:], transmute([]byte)msg, key)
}

epoch_floor_serialize :: proc(f: ^Epoch_Floor, dst: []byte) -> (out: []byte, ok: bool) {
	need := 4 + 4 + 2 + f.count * EPOCH_FLOOR_ENTRY_BYTES
	if f.count < 0 || f.count > EPOCH_FLOOR_MAX_ENTRIES || len(dst) < need do return nil, false
	copy(dst[:4], EPOCH_FLOOR_MAGIC)
	endian.unchecked_put_u32be(dst[4:8], f.floor_epoch)
	endian.unchecked_put_u16be(dst[8:10], u16(f.count))
	off := 10
	for i in 0 ..< f.count {
		endian.unchecked_put_u32be(dst[off:off + 4], f.entries[i].epoch)
		copy(dst[off + 4:off + EPOCH_FLOOR_ENTRY_BYTES], f.entries[i].commit[:])
		off += EPOCH_FLOOR_ENTRY_BYTES
	}
	return dst[:off], true
}

epoch_floor_parse :: proc(data: []byte) -> (f: Epoch_Floor, ok: bool) {
	if len(data) < 10 || string(data[:4]) != EPOCH_FLOOR_MAGIC do return {}, false
	f.floor_epoch = endian.unchecked_get_u32be(data[4:8])
	count := int(endian.unchecked_get_u16be(data[8:10]))
	if count > EPOCH_FLOOR_MAX_ENTRIES || len(data) != 10 + count * EPOCH_FLOOR_ENTRY_BYTES do return {}, false
	off := 10
	prev: u32 = 0
	for i in 0 ..< count {
		e := endian.unchecked_get_u32be(data[off:off + 4])
		if e == 0 || e <= prev do return {}, false
		prev = e
		f.entries[i].epoch = e
		copy(f.entries[i].commit[:], data[off + 4:off + EPOCH_FLOOR_ENTRY_BYTES])
		off += EPOCH_FLOOR_ENTRY_BYTES
	}
	f.count = count
	return f, true
}

// epoch_floor_check: kr must not roll back below the floor, must contain the newest
// epoch the floor has accepted, and every epoch the floor knows must carry the
// committed key (constant-time compare). Requiring the newest accepted epoch is what
// stops a hostile hub, after a lock or restart purged the stored keyring, from
// installing a keyring made only of fresh epochs (> floor) under keys it chose: it
// cannot produce the committed key for an epoch it never held.
epoch_floor_check :: proc(f: ^Epoch_Floor, bridge_id: string, kr: ^vault.Vault_Keyring) -> Epoch_Floor_Error {
	if kr.current_epoch < f.floor_epoch do return .Rollback
	if f.count > 0 {
		if _, has := vault.keyring_key_for_epoch(kr, f.entries[f.count - 1].epoch); !has do return .Missing_Epoch
	}
	diff := 0
	for i in 0 ..< kr.count {
		for j in 0 ..< f.count {
			if f.entries[j].epoch != kr.entries[i].epoch do continue
			c: [EPOCH_FLOOR_COMMIT_BYTES]byte
			epoch_floor_commit(bridge_id, kr.entries[i].epoch, kr.entries[i].key[:], &c)
			diff |= 1 - crypto.compare_constant_time(c[:], f.entries[j].commit[:])
		}
	}
	if diff != 0 do return .Key_Mismatch
	return .None
}

// epoch_floor_merge raises the floor to kr.current_epoch and adds commitments for
// kr's epochs, keeping the newest EPOCH_FLOOR_MAX_ENTRIES. Call only after
// epoch_floor_check passed.
epoch_floor_merge :: proc(f: ^Epoch_Floor, bridge_id: string, kr: ^vault.Vault_Keyring) {
	merged: [EPOCH_FLOOR_MAX_ENTRIES * 2]Epoch_Floor_Entry
	n := 0
	i, j := 0, 0
	for i < f.count || j < kr.count {
		take_floor := j >= kr.count || (i < f.count && f.entries[i].epoch < kr.entries[j].epoch)
		if take_floor {
			merged[n] = f.entries[i]
			i += 1
		} else {
			if i < f.count && f.entries[i].epoch == kr.entries[j].epoch do i += 1
			merged[n].epoch = kr.entries[j].epoch
			epoch_floor_commit(bridge_id, kr.entries[j].epoch, kr.entries[j].key[:], &merged[n].commit)
			j += 1
		}
		n += 1
	}
	start := max(0, n - EPOCH_FLOOR_MAX_ENTRIES)
	f.count = n - start
	copy(f.entries[:f.count], merged[start:n])
	f.floor_epoch = max(f.floor_epoch, kr.current_epoch)
}

keystore_store_epoch_floor :: proc(bridge_id: string, f: ^Epoch_Floor) -> bool {
	if !keystore_bridge_id_ok(bridge_id) do return false
	buf: [EPOCH_FLOOR_MAX_BYTES]byte
	out, ok := epoch_floor_serialize(f, buf[:])
	if !ok do return false
	return keystore_backend_write(.Epoch_Floor, bridge_id, out) == 0
}

keystore_read_epoch_floor :: proc(bridge_id: string) -> (f: Epoch_Floor, status: Keystore_Read_Status) {
	if !keystore_bridge_id_ok(bridge_id) do return {}, .Error
	buf: [EPOCH_FLOOR_MAX_BYTES + 1]byte
	n, st := keystore_backend_read(.Epoch_Floor, bridge_id, buf[:])
	if st != .Found do return {}, st
	parsed, ok := epoch_floor_parse(buf[:n])
	if !ok do return {}, .Error
	return parsed, .Found
}

keystore_delete_epoch_floor :: proc(bridge_id: string) -> bool {
	if !keystore_bridge_id_ok(bridge_id) do return true
	return keystore_backend_delete(.Epoch_Floor, bridge_id)
}
