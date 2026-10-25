-- Browser sessions created by the Hub's OIDC login (docs/plans/oidc-only-auth.md).
-- Only SHA-256 (hex) of the session id is stored; the cookie value never is.
CREATE TABLE IF NOT EXISTS user_sessions (
 session_id_hash TEXT PRIMARY KEY,
 user_id TEXT NOT NULL REFERENCES users(user_id),
 created_at_ms INTEGER NOT NULL,
 last_seen_at_ms INTEGER NOT NULL,
 expires_at_ms INTEGER NOT NULL,
 idle_expires_at_ms INTEGER NOT NULL,
 id_token TEXT, -- only for the RP-initiated logout id_token_hint
 user_agent TEXT
);
CREATE INDEX IF NOT EXISTS user_sessions_user ON user_sessions(user_id);
CREATE INDEX IF NOT EXISTS user_sessions_expiry ON user_sessions(expires_at_ms);

-- Pending logins are not stored: they travel in the sealed __Host-heimdall_login
-- cookie (docs/plans/oidc-only-auth.md).
