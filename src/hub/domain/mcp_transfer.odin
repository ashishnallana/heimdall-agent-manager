package domain

// E2EE artifact transfer row (docs/plans/mcp-large-artifact-transfers.md §11). Every
// content-bearing field is CIPHERTEXT (vault v2 tokens) or a ciphertext digest; the
// Hub never holds plaintext, a plaintext digest or a key that opens either.
Mcp_Transfer :: struct {
	transfer_id, owner_user_id, client_id, grant_id, family_id: string,
	direction, state, error: string,
	token_sha256: string,
	artifact_id, artifact_revision: string,
	request_id, request_digest: string,
	kind, content_type, ext, associations: string,
	vault_id: string,
	epoch: i64,
	received_bytes, ciphertext_bytes: i64,
	ciphertext_sha256: string,
	fetches: i64,
	seal_statement, seal_signature, seal_device_id: string,
	name_token, description_token, attestation_token: string,
	open_statement, open_signature, open_device_id: string,
	open_verified: bool,
	created_at, touched_at, expires_at: string,
}

MCP_TRANSFER_UPLOAD   :: "upload"
MCP_TRANSFER_DOWNLOAD :: "download"

MCP_TRANSFER_RECEIVING :: "receiving"
MCP_TRANSFER_SEALED    :: "sealed"
MCP_TRANSFER_COMMITTED :: "committed"
MCP_TRANSFER_READY     :: "ready"
MCP_TRANSFER_DELIVERED :: "delivered"
MCP_TRANSFER_CANCELLED :: "cancelled"
MCP_TRANSFER_EXPIRED   :: "expired"
MCP_TRANSFER_FAILED    :: "failed"

mcp_transfer_state_terminal :: proc(state: string) -> bool {
	switch state {
	case MCP_TRANSFER_COMMITTED, MCP_TRANSFER_CANCELLED, MCP_TRANSFER_EXPIRED, MCP_TRANSFER_FAILED:
		return true
	}
	return false
}

// Mcp_Transfer_Commit is the metadata of the artifact created at commit. Its content
// is NOT carried here: the repository concatenates the staged ciphertext chunk rows
// inside the commit transaction.
Mcp_Transfer_Commit :: struct {
	artifact: Artifact, // content left empty; name/description are the sealed tokens
	receipt_created_at: string,
}
