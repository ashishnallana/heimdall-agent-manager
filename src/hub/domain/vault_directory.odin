package domain

import "core:strconv"
import "core:strings"
import vault "odin_test:lib/vault"

// Passwordless vault device directory (docs/plans/passwordless-vault.md §2 P2).
//
// The hub is assumed hostile for confidentiality: it stores public keys, signed
// statements and ECDH-wrapped keyrings only. It still ENFORCES authorization and
// compare-and-set as defense in depth — every statement is re-verified here with
// lib/vault, and every directory mutation is a versioned CAS.
//
// `kind` is validated here (vault.device_kind_from_id), never by an SQL CHECK, so a
// new credential kind needs no table rebuild. What a kind may DO is decided by the
// single vault.kind_policy.

Vault_Device_Status :: enum {
	Pending,
	Approved,
	Revoked,
}

vault_device_status_string :: proc(s: Vault_Device_Status) -> string {
	switch s {
	case .Pending:  return "pending"
	case .Approved: return "approved"
	case .Revoked:  return "revoked"
	}
	return "revoked"
}

vault_device_status_from_string :: proc(s: string) -> (Vault_Device_Status, bool) {
	switch s {
	case "pending":  return .Pending, true
	case "approved": return .Approved, true
	case "revoked":  return .Revoked, true
	}
	return .Revoked, false
}

Vault_Directory :: struct {
	user_id:           string,
	version:           i64,
	current_epoch:     i64,
	root_device_id:    string,
	// head_hash: entry hash of the log op at seq = version (vault.log_entry_hash).
	head_hash:         string,
	genesis_statement: string,
	genesis_signature: string,
	created_at:        string,
	updated_at:        string,
}

Vault_Device :: struct {
	device_id:             string,
	user_id:               string,
	kind:                  string,
	label:                 string,
	sign_alg:              string,
	wrap_alg:              string,
	sign_public_key:       string,
	ecdh_public_key:       string,
	fingerprint:           string,
	bridge_id:             string,
	status:                Vault_Device_Status,
	user_code:             string,
	code_expires_at:       string,
	approval_statement:    string,
	approval_signature:    string,
	approved_by_device_id: string,
	revocation_statement:  string,
	revocation_signature:  string,
	revoked_by_device_id:  string,
	recovery_blob:         string,
	created_at:            string,
	approved_at:           string,
	revoked_at:            string,
	last_seen_at:          string,
	// retired_at: a hub retirement HINT (see migration 092). The identity stays
	// approved in the signed log until an approved browser signs its revoke.
	retired_at:            string,
}

// Vault_Log_Entry is one signed directory op (plan §1 "Directory log").
Vault_Log_Entry :: struct {
	user_id:    string,
	seq:        i64,
	statement:  string,
	signature:  string,
	entry_hash: string,
	created_at: string,
}

// Vault_Epoch is the log op that introduced an epoch (genesis, revoke or rotate).
Vault_Epoch :: struct {
	user_id:    string,
	epoch:      i64,
	statement:  string,
	signature:  string,
	created_at: string,
}

Vault_Wrap_Row :: struct {
	user_id:           string,
	device_id:         string,
	directory_version: i64,
	current_epoch:     i64,
	wrap_json:         string,
	updated_at:        string,
}

// Vault_Reset is a scheduled owner reset of the whole directory (see
// service/vault_directory schedule_reset): at due_at the directory, its devices,
// epochs and wraps are deleted and the owner's bridges lose their credentials.
Vault_Reset :: struct {
	user_id:      string,
	requested_at: string,
	due_at:       string,
}

// Vault_Directory_Commit is ONE versioned directory mutation: exactly one signed log op
// (log_statement, at seq = expected_version + 1, linked to expected_head_hash) plus the
// row changes it implies. The repository applies every populated part inside a single
// transaction that starts with
//   UPDATE vault_directories SET version = version + 1, head_hash = ? ... WHERE user_id = ? AND version = ? AND head_hash = ?
// and rolls everything back if any guarded write changes no row. There is no commit
// without a signed log op: the hub never bumps the version on its own.
Vault_Directory_Commit :: struct {
	user_id:            string,
	expected_version:   i64,
	expected_head_hash: string,
	now:                string,

	// The signed log op this commit appends (required) and its entry hash.
	log_statement:  string,
	log_signature:  string,
	log_entry_hash: string,

	// Approve a pending device (browser path). Guarded on status='pending'.
	approve_device_id:     string,
	approval_statement:    string,
	approval_signature:    string,
	approved_by_device_id: string,

	// Insert an already-approved device (bridge path: approved together with its grant).
	insert_device: Maybe(Vault_Device),

	// An attach approving a new identity for a bridge_id marks the previous approved
	// identity of that bridge_id retired (a HINT: retired_at only, still approved in
	// the log) in the same transaction. Guarded on status='approved' AND bridge_id.
	hint_retire_device_id: string,
	hint_retire_bridge_id: string,

	// Revoke an approved device. Guarded on status='approved'.
	revoke_device_id:     string,
	revocation_statement: string,
	revocation_signature: string,
	revoked_by_device_id: string,

	// Advance the epoch (revoke or rotate: the log op itself introduces it).
	// new_epoch must be the current epoch + 1; guarded.
	new_epoch: i64,

	// Set an approved device's label. Only from a signed approval statement (the
	// browser approve path): there is no unsigned relabel endpoint.
	label_device_id: string,
	label:           string,

	// Wraps to upsert. replace_all_wraps first deletes every wrap of the user (a new
	// epoch invalidates them all).
	wraps:             []Vault_Wrap_Row,
	replace_all_wraps: bool,
}

// Vault_Genesis is the first write of a directory: version 1 (log seq 1), epoch 1, the
// root device approved by itself, the genesis log entry and its own wrap.
Vault_Genesis :: struct {
	directory: Vault_Directory,
	device:    Vault_Device,
	epoch:     Vault_Epoch,
	wrap:      Vault_Wrap_Row,
	log:       Vault_Log_Entry,
}

// vault_conflict_error is the 409 for a stale expected_version: it names the current
// version so the client can re-fetch, re-verify and retry.
vault_conflict_error :: proc(current_version: i64) -> Domain_Error {
	buf: [24]byte
	return domain_error(.Conflict, "vault directory version conflict", strings.concatenate({`{"reason":"version_conflict","current_version":`, strconv.write_int(buf[:], current_version, 10), "}"}, context.temp_allocator))
}

vault_reason_error :: proc(code: Error_Code, reason, message: string) -> Domain_Error {
	return domain_error(code, message, strings.concatenate({`{"reason":"`, reason, `"}`}, context.temp_allocator))
}

// ── Kind validation (credential agility) ────────────────────────────────────

vault_kind_valid :: proc(kind: string) -> bool {
	return vault.device_kind_from_id(kind) != .Unknown
}

vault_kind_policy :: proc(kind: string) -> vault.Kind_Policy {
	return vault.kind_policy(vault.device_kind_from_id(kind))
}

// ── Pending-device codes ────────────────────────────────────────────────────
// A browser's pending code is 12 base32 symbols "XXXX-XXXX-XXXX"; a bridge grant's
// user code is 8 ("XXXX-XXXX"). The lengths differ on purpose so a code can never be
// resolved against the wrong namespace: the length alone routes it.

VAULT_CODE_ALPHABET :: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
VAULT_CODE_SYMBOLS  :: 12
VAULT_CODE_TTL_SECONDS :: 600
// At most this many live (unexpired) pending devices per account; expired ones are
// purged on every registration and hidden from the directory listing.
VAULT_PENDING_PER_USER_MAX :: 10

// normalize_vault_device_code folds case and ignores spaces/dashes; anything else, or
// a symbol count other than 12, is rejected. The result is rebuilt from validated
// symbols only.
normalize_vault_device_code :: proc(raw: string, allocator := context.allocator) -> (string, bool) {
	symbols: [VAULT_CODE_SYMBOLS]u8
	count := 0
	if len(raw) > 64 do return "", false
	for i := 0; i < len(raw); i += 1 {
		c := raw[i]
		switch c {
		case ' ', '\t', '-':
			continue
		case 'a' ..= 'z':
			c -= 'a' - 'A'
		}
		if strings.index_byte(VAULT_CODE_ALPHABET, c) < 0 do return "", false
		if count == VAULT_CODE_SYMBOLS do return "", false
		symbols[count] = c
		count += 1
	}
	if count != VAULT_CODE_SYMBOLS do return "", false
	return strings.concatenate({string(symbols[0:4]), "-", string(symbols[4:8]), "-", string(symbols[8:12])}, allocator), true
}

// vault_device_code_from_random renders 12 random bytes as a code (256 % 32 == 0, so
// the mapping has no modulo bias).
vault_device_code_from_random :: proc(raw: []byte, allocator := context.allocator) -> (string, bool) {
	if len(raw) != VAULT_CODE_SYMBOLS do return "", false
	out: [VAULT_CODE_SYMBOLS + 2]u8
	j := 0
	alphabet := VAULT_CODE_ALPHABET
	for i in 0 ..< VAULT_CODE_SYMBOLS {
		if i == 4 || i == 8 {
			out[j] = '-'
			j += 1
		}
		out[j] = alphabet[int(raw[i]) % len(alphabet)]
		j += 1
	}
	return strings.clone(string(out[:]), allocator), true
}
