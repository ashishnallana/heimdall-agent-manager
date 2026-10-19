package domain

import "core:strings"
import contracts "odin_test:contracts"

// Error_Code is the shared bridge<->hub contract code (src/contracts/errors.odin);
// its table fixes each code's wire name, class and HTTP status.
Error_Code :: contracts.Error_Code

Domain_Error :: struct {
	code:    Error_Code,
	message: string,
	details_json: string,
	// cause is the fine-grained reason relayed from the bridge (a Bridge_Log_Code or
	// fs/vcs reason name); "" for hub-originated errors.
	cause: string,
	// class overrides the code's table class when the side that saw the failure
	// classified it differently (a bridge-relayed error carries its own class).
	class: Maybe(contracts.Bridge_Error_Class),
}

error_code_string :: contracts.error_code_string

// domain_error_class is the class a client should act on.
domain_error_class :: proc(err: Domain_Error) -> contracts.Bridge_Error_Class {
	if class, ok := err.class.?; ok do return class
	return contracts.error_code_class(err.code)
}

// domain_error_from_wire turns a bridge-relayed wire error into a domain error that
// keeps the bridge's code, class and cause. Message is cloned into the temp arena.
domain_error_from_wire :: proc(w: contracts.Wire_Error) -> Domain_Error {
	code := w.code
	if code == .None do code = .Internal_Error
	message := w.message
	if message == "" do message = w.cause
	if message == "" do message = error_code_string(code)
	return Domain_Error{code = code, message = message, cause = w.cause, class = w.class}
}

domain_error :: proc(code: Error_Code, message: string, details_json := "") -> Domain_Error {
	return Domain_Error{code = code, message = message, details_json = details_json}
}

// VAULT_LOCKED_ERROR_CODE is the stable wire code a bridge sends (`error_code`) when it
// refuses work because its vault is locked, and the code the hub answers with.
VAULT_LOCKED_ERROR_CODE :: "vault_locked"
// It matches the UI headline (vaultLockedError.ts VAULT_LOCKED_HEADLINE): approved
// devices deliver the key automatically; the user does not "unseal" anything.
VAULT_LOCKED_MESSAGE :: "This bridge is awaiting the vault key."

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
