-- Unreleased MCP schema follows main's 174 release migration.
-- This table contains PUBLIC bindings, signed grants, encrypted keyring wraps,
-- credential hashes and client-secret-encrypted bounded retry capsules only.
-- Raw OAuth credentials and recipient private capabilities MUST NOT be stored.
CREATE TABLE mcp_records (
    kind TEXT NOT NULL CHECK (kind IN ('client','pending','grant','code','access','refresh','family')),
    id TEXT NOT NULL,
    owner_user_id TEXT NOT NULL,
    metadata_json TEXT NOT NULL,
    PRIMARY KEY (kind, id)
);
CREATE INDEX mcp_records_owner ON mcp_records(kind, owner_user_id);
