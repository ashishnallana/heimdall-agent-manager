-- Identity ownership is stable across username changes. Email never participates.
CREATE TABLE IF NOT EXISTS user_external_identities (
 issuer TEXT NOT NULL, subject TEXT NOT NULL,
 user_id TEXT NOT NULL UNIQUE REFERENCES users(user_id),
 created_at TEXT NOT NULL,
 PRIMARY KEY (issuer, subject)
);

-- V2 proofs are single-use even across Hub restarts. Keep entries until the
-- entire timestamp acceptance window has elapsed, including future-dated proofs.
CREATE TABLE IF NOT EXISTS vault_request_nonces (
 user_id TEXT NOT NULL,
 device_id TEXT NOT NULL,
 nonce TEXT NOT NULL,
 expires_ms INTEGER NOT NULL,
 PRIMARY KEY (user_id, device_id, nonce)
);
CREATE INDEX IF NOT EXISTS vault_request_nonces_expiry ON vault_request_nonces(expires_ms);
