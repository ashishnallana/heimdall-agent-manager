package domain

import "core:encoding/json"
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
	// Hub-blind pairing (plan §1 "Pairing"): a pending request is indexed by
	// pair_lookup (derived from the code the new device shows; the hub never sees the
	// code). pair_key_mac + register_statement let the approver verify the keys;
	// pair_mac (stored at approval) lets the new device verify its approval. The
	// pending fields are cleared on approval.
	pair_lookup:           string,
	pair_key_mac:          string,
	register_statement:    string,
	pair_mac:              string,
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
	// The approver's pair_mac for the new device (the pending pairing fields are cleared).
	approve_pair_mac:      string,

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
Vault_Conflict_Details :: struct {
	reason:          string,
	current_version: i64,
}

Vault_Reason_Details :: struct {
	reason: string,
}

vault_conflict_error :: proc(current_version: i64) -> Domain_Error {
	details, _ := json.marshal(Vault_Conflict_Details{reason = "version_conflict", current_version = current_version}, allocator = context.temp_allocator)
	return domain_error(.Conflict, "vault directory version conflict", string(details))
}

vault_reason_error :: proc(code: Error_Code, reason, message: string) -> Domain_Error {
	details, _ := json.marshal(Vault_Reason_Details{reason = reason}, allocator = context.temp_allocator)
	return domain_error(code, message, string(details))
}

// ── Kind validation (credential agility) ────────────────────────────────────

vault_kind_valid :: proc(kind: string) -> bool {
	return vault.device_kind_from_id(kind) != .Unknown
}

vault_kind_policy :: proc(kind: string) -> vault.Kind_Policy {
	return vault.kind_policy(vault.device_kind_from_id(kind))
}

// ── Pending devices ─────────────────────────────────────────────────────────
// A pending request lives as long as its pairing code (vault.PAIR_CODE_TTL_SECONDS);
// expired requests are purged on every registration and hidden from the listing.

VAULT_CODE_TTL_SECONDS :: vault.PAIR_CODE_TTL_SECONDS
// At most this many live (unexpired) pending devices per account.
VAULT_PENDING_PER_USER_MAX :: 10

// vault_register_supersedes reports whether a self-signed register statement is
// strictly newer than the one a live pending request was made with. Only then does a
// re-registration replace the request's pairing lookup (a new code on the device): a
// replayed register body can never take over a live request.
vault_register_supersedes :: proc(new_statement, old_statement: string) -> bool {
	n, n_ok := vault.statement_parse(new_statement)
	o, o_ok := vault.statement_parse(old_statement)
	if !n_ok || !o_ok do return false
	nt, nt_ok := vault.decimal_u64(n.issued_at_ms)
	ot, ot_ok := vault.decimal_u64(o.issued_at_ms)
	return nt_ok && ot_ok && nt > ot
}