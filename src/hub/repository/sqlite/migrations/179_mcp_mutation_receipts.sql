-- Only public result identifiers and digests; never credentials or plaintext.
CREATE TABLE IF NOT EXISTS mcp_mutation_receipts (
  owner_user_id TEXT NOT NULL,
  grant_id TEXT NOT NULL,
  tool TEXT NOT NULL,
  request_id TEXT NOT NULL,
  argument_digest TEXT NOT NULL,
  result_id TEXT NOT NULL,
  PRIMARY KEY(owner_user_id, grant_id, tool, request_id)
);
