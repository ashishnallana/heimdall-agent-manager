package domain

// Public OAuth/grant metadata only. This type intentionally has no field for a
// raw code/token, private recipient scalar, plaintext keyring or tool response.
// retry_capsule is client-secret encrypted, never service-key recoverable.
MCP_Record :: struct {
	kind, id, owner, client, resource, scope: string,
	redirect, challenge, oauth_state: string,
	grant, family, vault_id, recipient, recipient_public_key, mode: string,
	approver, consent, signature, wrap_json, directory_head: string,
	revision, directory_version, epoch, created_ms, expires_ms: i64,
	revoked, consumed: bool,
	child_hash, retry_capsule: string,
	retry_deadline_ms: i64,
	retry_count: int,
}
