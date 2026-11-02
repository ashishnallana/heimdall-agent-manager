-- E2EE artifact transfers (docs/plans/mcp-large-artifact-transfers.md §11).
-- The Hub stages and stores CIPHERTEXT ONLY: chunk rows hold bytes of one vault v2
-- token; no plaintext, plaintext digest, name or description is ever stored in clear.
-- Tokens are stored as sha256 only. chunk byte position is "byte_offset" (OFFSET is
-- an SQL keyword).
CREATE TABLE IF NOT EXISTS mcp_transfers (
  transfer_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL, client_id TEXT NOT NULL,
  grant_id TEXT NOT NULL, family_id TEXT NOT NULL,
  direction TEXT NOT NULL CHECK (direction IN ('upload','download')),
  state TEXT NOT NULL, error TEXT NOT NULL DEFAULT '',
  token_sha256 TEXT NOT NULL,
  artifact_id TEXT NOT NULL,
  artifact_revision TEXT NOT NULL DEFAULT '',
  request_id TEXT NOT NULL, request_digest TEXT NOT NULL,
  kind TEXT NOT NULL, content_type TEXT NOT NULL, ext TEXT NOT NULL DEFAULT '',
  associations TEXT NOT NULL DEFAULT '{}',
  vault_id TEXT NOT NULL, epoch INTEGER NOT NULL,
  received_bytes INTEGER NOT NULL DEFAULT 0,
  ciphertext_bytes INTEGER NOT NULL DEFAULT 0, ciphertext_sha256 TEXT NOT NULL DEFAULT '',
  fetches INTEGER NOT NULL DEFAULT 0,
  seal_statement TEXT NOT NULL DEFAULT '', seal_signature TEXT NOT NULL DEFAULT '',
  seal_device_id TEXT NOT NULL DEFAULT '',
  name_token TEXT NOT NULL DEFAULT '', description_token TEXT NOT NULL DEFAULT '',
  attestation_token TEXT NOT NULL DEFAULT '',
  open_statement TEXT NOT NULL DEFAULT '', open_signature TEXT NOT NULL DEFAULT '',
  open_device_id TEXT NOT NULL DEFAULT '', open_verified INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL, touched_at TEXT NOT NULL, expires_at TEXT NOT NULL,
  UNIQUE (owner_user_id, client_id, request_id)
);
CREATE INDEX IF NOT EXISTS mcp_transfers_expiry ON mcp_transfers(state, expires_at);
CREATE UNIQUE INDEX IF NOT EXISTS mcp_transfers_token ON mcp_transfers(token_sha256);
CREATE INDEX IF NOT EXISTS mcp_transfers_owner_state ON mcp_transfers(owner_user_id, direction, state);
CREATE TABLE IF NOT EXISTS mcp_transfer_chunks (
  transfer_id TEXT NOT NULL REFERENCES mcp_transfers(transfer_id) ON DELETE CASCADE,
  chunk_index INTEGER NOT NULL, byte_offset INTEGER NOT NULL, bytes BLOB NOT NULL,
  PRIMARY KEY (transfer_id, chunk_index)
);
CREATE TABLE IF NOT EXISTS artifact_transfer_receipts (
  artifact_id TEXT PRIMARY KEY, owner_user_id TEXT NOT NULL,
  statement TEXT NOT NULL, signature TEXT NOT NULL, device_id TEXT NOT NULL,
  attestation_token TEXT NOT NULL, ciphertext_sha256 TEXT NOT NULL,
  created_at TEXT NOT NULL
);
-- The receipt row is deleted with its artifact (every delete path, §11).
CREATE TRIGGER IF NOT EXISTS artifact_transfer_receipts_on_artifact_delete AFTER DELETE ON artifacts
BEGIN
  DELETE FROM artifact_transfer_receipts WHERE artifact_id = old.artifact_id;
END;
