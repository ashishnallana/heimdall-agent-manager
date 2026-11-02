package iface

import domain "odin_test:hub/domain"

// Transfer_Repository stores E2EE transfer rows and their CIPHERTEXT chunk rows
// (docs/plans/mcp-large-artifact-transfers.md §11). It never sees plaintext.
Transfer_Chunk_Visitor :: proc(user: rawptr, bytes: []byte) -> bool

// Transfer_Quota bounds enforced atomically by the repository; 0 = unbounded.
Transfer_Quota :: struct {
	max_active:        int,
	max_owner_staged:  i64,
	max_global_staged: i64,
}

Transfer_Repository :: struct {
	ctx: rawptr,
	// insert creates the row iff the owner is still under q (active transfers of
	// t.direction and upload staged bytes), evaluated in the same statement so
	// concurrent begins cannot overshoot; inserted=false means quota exceeded.
	insert: proc(ctx: rawptr, t: domain.Mcp_Transfer, q: Transfer_Quota) -> (inserted: bool, err: domain.Domain_Error),
	get: proc(ctx: rawptr, transfer_id: string) -> (domain.Mcp_Transfer, bool, domain.Domain_Error),
	get_by_request: proc(ctx: rawptr, owner, client_id, request_id: string) -> (domain.Mcp_Transfer, bool, domain.Domain_Error),
	get_by_token: proc(ctx: rawptr, token_sha256: string) -> (domain.Mcp_Transfer, bool, domain.Domain_Error),
	rotate_token: proc(ctx: rawptr, transfer_id, token_sha256, touched_at: string) -> domain.Domain_Error,
	// append_chunk stores bytes at offset iff received_bytes == offset, the state is
	// receiving (CAS) and the owner/global staged sums plus len(bytes) stay within q,
	// all in the same UPDATE; ok=false means the offset moved, the state changed or
	// a staging quota would be exceeded.
	append_chunk: proc(ctx: rawptr, transfer_id: string, offset: i64, bytes: []byte, touched_at, expires_at: string, q: Transfer_Quota) -> (bool, domain.Domain_Error),
	visit_chunks: proc(ctx: rawptr, transfer_id: string, user: rawptr, visit: Transfer_Chunk_Visitor) -> domain.Domain_Error,
	// set_state CAS: from -> to, optionally recording error; deletes chunks when to is terminal.
	set_state: proc(ctx: rawptr, transfer_id, from, to, error, touched_at: string) -> (bool, domain.Domain_Error),
	// mark_sealed CAS receiving -> sealed storing the receipt and sealed metadata tokens.
	mark_sealed: proc(ctx: rawptr, t: domain.Mcp_Transfer) -> (bool, domain.Domain_Error),
	// commit CAS sealed -> committed + artifact insert (content = staged chunks) +
	// receipt row + chunk delete, in ONE transaction.
	commit: proc(ctx: rawptr, transfer_id: string, c: domain.Mcp_Transfer_Commit) -> (bool, domain.Domain_Error),
	// count_fetch increments fetches iff fetches < max (download).
	count_fetch: proc(ctx: rawptr, transfer_id: string, max_fetches: i64, touched_at: string) -> (bool, domain.Domain_Error),
	mark_opened: proc(ctx: rawptr, t: domain.Mcp_Transfer) -> (bool, domain.Domain_Error),
	// usage: active (non-terminal) transfers of direction for owner and staged bytes.
	owner_usage: proc(ctx: rawptr, owner, direction: string) -> (active: int, staged_bytes: i64, err: domain.Domain_Error),
	global_staged_bytes: proc(ctx: rawptr) -> (i64, domain.Domain_Error),
	// expire marks every non-terminal row past expires_at (or idle) expired and wipes
	// its chunks; purge deletes terminal rows older than before.
	expire: proc(ctx: rawptr, now, idle_before: string) -> (int, domain.Domain_Error),
	purge: proc(ctx: rawptr, before: string) -> (int, domain.Domain_Error),
	delete_receipt: proc(ctx: rawptr, artifact_id, owner: string) -> domain.Domain_Error,
	get_receipt: proc(ctx: rawptr, artifact_id, owner: string) -> (statement, signature, device_id, attestation_token, ciphertext_sha256: string, found: bool, err: domain.Domain_Error),
	// read_artifact_window copies at most len(dst) bytes of an owned, live artifact's
	// stored content starting at offset, plus the total stored length.
	read_artifact_window: proc(ctx: rawptr, artifact_id, owner: string, offset: i64, dst: []byte) -> (n: int, total: i64, found: bool, err: domain.Domain_Error),
}
