package iface

import domain "odin_test:hub/domain"

// Browser session and pending-login persistence (docs/plans/oidc-only-auth.md).
// Only hashes of the session id are ever stored or queried.

User_Session :: struct {
	session_id_hash: string,
	user_id: string,
	created_at_ms, last_seen_at_ms, expires_at_ms, idle_expires_at_ms: i64,
	id_token: string,
	user_agent: string,
}

// OIDC_Login_State is a pending login (carried in the sealed login cookie; it is
// never stored server-side).
OIDC_Login_State :: struct {
	nonce, code_verifier, return_to: string,
	expires_at_ms: i64,
}

Session_Repository :: struct {
	ctx: rawptr,
	create_session: proc(ctx: rawptr, session: User_Session) -> domain.Domain_Error,
	get_session: proc(ctx: rawptr, session_id_hash: string) -> (User_Session, bool, domain.Domain_Error),
	// touch_session moves last_seen/idle expiry forward (callers throttle it).
	touch_session: proc(ctx: rawptr, session_id_hash: string, now_ms, idle_expires_at_ms: i64) -> domain.Domain_Error,
	// delete_session returns the removed row (for the logout id_token_hint).
	delete_session: proc(ctx: rawptr, session_id_hash: string) -> (User_Session, bool, domain.Domain_Error),
	// purge_expired drops expired sessions (absolute or idle) and v2
	// device-proof nonces. Returns the number of rows removed.
	purge_expired: proc(ctx: rawptr, now_ms: i64) -> (int, domain.Domain_Error),
	// delete_user_sessions ends every session of a user (unlink, disable, logout).
	delete_user_sessions: proc(ctx: rawptr, user_id: string) -> (int, domain.Domain_Error),
}
