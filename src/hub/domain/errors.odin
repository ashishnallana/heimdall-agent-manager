package domain

import "core:strings"

Error_Code :: enum {
	None,
	Unauthenticated,
	Forbidden,
	Not_Found,
	Validation_Failed,
	Conflict,
	Bridge_Offline,
	Bridge_Busy,
	Bridge_Timeout,
	Bridge_Revoked,
	Provider_Unavailable,
	Instance_Not_Running,
	Rate_Limited,
	Gone,
	Unprocessable_Entity,
	Not_Implemented,
	Internal_Error,
	// T10 (REQ-T10-2): the bridge refused because its vault is locked. Appended rather
	// than inserted so no existing ordinal moves.
	Vault_Locked,
}

Domain_Error :: struct {
	code:    Error_Code,
	message: string,
	details_json: string,
}

error_code_string :: proc(code: Error_Code) -> string {
	switch code {
	case .None: return ""
	case .Unauthenticated: return "unauthenticated"
	case .Forbidden: return "forbidden"
	case .Not_Found: return "not_found"
	case .Validation_Failed: return "validation_failed"
	case .Conflict: return "conflict"
	case .Bridge_Offline: return "bridge_offline"
	case .Bridge_Busy: return "bridge_busy"
	case .Bridge_Timeout: return "bridge_timeout"
	case .Bridge_Revoked: return "bridge_revoked"
	case .Provider_Unavailable: return "provider_unavailable"
	case .Instance_Not_Running: return "instance_not_running"
	case .Rate_Limited: return "rate_limited"
	case .Gone: return "gone"
	case .Unprocessable_Entity: return "unprocessable_entity"
	case .Not_Implemented: return "not_implemented"
	case .Internal_Error: return "internal_error"
	case .Vault_Locked: return "vault_locked"
	}
	return "internal_error"
}

domain_error :: proc(code: Error_Code, message: string, details_json := "") -> Domain_Error {
	return Domain_Error{code = code, message = message, details_json = details_json}
}

// VAULT_LOCKED_ERROR_CODE is the stable wire code a bridge sends (`error_code`) when it
// refuses work because its vault is locked, and the code the hub answers with.
VAULT_LOCKED_ERROR_CODE :: "vault_locked"
VAULT_LOCKED_MESSAGE :: "This bridge's vault is locked. Unseal it to continue."

// vault_locked_error builds the typed refusal for a bridge whose vault is locked
// (REQ-T10-2): code `vault_locked`, details {"bridge_id": ...} so a client can open
// the unseal path for exactly that bridge. Message and details live in the per-request
// temp arena, like every other per-request domain error message.
vault_locked_error :: proc(bridge_id: string) -> Domain_Error {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\"bridge_id\":\"")
	for r in bridge_id {
		switch r {
		case '"', '\\': strings.write_byte(&b, '\\'); strings.write_rune(&b, r)
		case 0..<0x20: continue // ids never carry control characters; drop rather than emit invalid JSON
		case: strings.write_rune(&b, r)
		}
	}
	strings.write_string(&b, "\"}")
	return domain_error(.Vault_Locked, VAULT_LOCKED_MESSAGE, strings.to_string(b))
}

// bridge_refusal_error maps a bridge's machine-readable refusal code to a typed domain
// error. ok is false for codes with no typed mapping; callers then keep their generic
// fallback (a genuinely unknown failure stays a 500).
bridge_refusal_error :: proc(error_code, bridge_id: string) -> (err: Domain_Error, ok: bool) {
	switch error_code {
	case VAULT_LOCKED_ERROR_CODE: return vault_locked_error(bridge_id), true
	}
	return {}, false
}
