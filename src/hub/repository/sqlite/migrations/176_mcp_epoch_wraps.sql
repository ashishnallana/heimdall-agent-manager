-- Mutable current-epoch delivery is separate from immutable signed consent.
-- Only public metadata and signed ECDH-encrypted keyring wraps belong here.
CREATE TABLE mcp_epoch_wraps (
    kind TEXT NOT NULL CHECK (kind = 'wrap'),
    id TEXT NOT NULL,
    owner_user_id TEXT NOT NULL,
    metadata_json TEXT NOT NULL,
    PRIMARY KEY (kind, id)
);
CREATE INDEX mcp_epoch_wraps_owner ON mcp_epoch_wraps(kind, owner_user_id);
