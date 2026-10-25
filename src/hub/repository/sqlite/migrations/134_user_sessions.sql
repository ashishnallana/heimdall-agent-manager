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

-- Pending authorization-code logins. Keyed by SHA-256 (hex) of `state`; single use.
CREATE TABLE IF NOT EXISTS oidc_login_states (
 state_hash TEXT PRIMARY KEY,
 nonce TEXT NOT NULL,
 code_verifier TEXT NOT NULL,
 return_to TEXT NOT NULL,
 expires_at_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS oidc_login_states_expiry ON oidc_login_states(expires_at_ms);
