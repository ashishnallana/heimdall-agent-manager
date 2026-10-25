package contracts

Auth_Kind :: enum {
	None,
	Trusted_Proxy,
	User_Token,
	Bridge_Token,
	Enrollment_Token,
	Instance_Token,
	OIDC,
	// Browser session established by the Hub's own OIDC login (opaque cookie).
	Session,
}

Auth_Context :: struct {
	kind: Auth_Kind,
	user_id: string,
	name: string,
	display_name: string,
	email: string,
	bridge_id: string,
	agent_instance_id: string,
	token_scopes: []string,
	// Set only after transport verifies the device request proof. Never from headers alone.
	device_id: string,
	user_token_id: string, // opaque identity for long-lived stream revocation checks
	// Session: the SHA-256 (hex) of the session id, used to re-check long-lived
	// streams against the session store. Never the cookie value itself.
	session_id: string,
	// Unix ms after which this principal is no longer valid (OIDC: token exp plus
	// leeway; Session: absolute session expiry). 0 = no intrinsic bound.
	expires_ms: i64,
}

// is_user_auth reports whether the principal is a human user (as opposed to a
// bridge, enrollment or agent-instance credential).
is_user_auth :: proc(ctx: Auth_Context) -> bool {
	#partial switch ctx.kind {
	case .Session, .OIDC, .User_Token, .Trusted_Proxy:
		return true
	}
	return false
}

// is_interactive_browser_auth reports whether the principal is an interactive
// browser session: the Hub's own session cookie, or (until it is removed) the
// trusted-proxy identity. Never a bearer token.
is_interactive_browser_auth :: proc(ctx: Auth_Context) -> bool {
	return ctx.kind == .Session || ctx.kind == .Trusted_Proxy
}

HTTP_Header :: struct {
	name: string,
	value: string,
}
