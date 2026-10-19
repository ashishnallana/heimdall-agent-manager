package main

// Bridge glue over lib/vault (the single Odin implementation of the v2 envelope and
// the HKR1 keyring). Nothing here knows a wire format: tokens of any older format
// are plain text to this bridge and are never decrypted.

import "core:crypto"
import "core:strings"
import vault "odin_test:lib/vault"

Secure_Key :: struct {
	ptr:      [^]u8,
	len:      int,
	capacity: int,
	locked:   bool,
	dontdump: bool,
}

// VAULT_LOCKED_MARKER replaces a vault token that cannot be decrypted because its
// epoch key is not held (no keyring, or an epoch this keyring lacks), for callers
// that opt in via locked_marker (bootstrap files). Raw ciphertext in an agent's
// AGENTS.md/MEMORY.md reads as garbage and hides the real problem; this names it.
VAULT_LOCKED_MARKER :: "[encrypted: bridge vault locked]"

bridge_has_vault_token :: proc(s: string) -> bool {
	return vault.contains_token(s)
}

// bridge_decrypt_vault_token opens one complete v2 token with kr. Plain (non-armored)
// text is NOT accepted here: callers that hold a field which must be encrypted get
// ok=false rather than a plaintext pass-through.
bridge_decrypt_vault_token :: proc(token: string, kr: ^vault.Vault_Keyring, allocator := context.allocator) -> (plaintext: string, ok: bool) {
	plain, res := vault.open(token, kr, allocator)
	return plain, res == .Ok
}

// bridge_vault_decrypt_field decrypts a stored content field: plain text (a vault
// that was never configured) is returned as is, a v2 token must open under some
// epoch kr holds. Use bridge_open_current_epoch_token for COMMAND fields instead.
bridge_vault_decrypt_field :: proc(s: string, kr: ^vault.Vault_Keyring, allocator := context.allocator) -> (plaintext: string, ok: bool) {
	if !vault.is_armored(s) do return strings.clone(s, allocator), true
	return bridge_decrypt_vault_token(s, kr, allocator)
}

// bridge_open_current_epoch_token is the command epoch floor (enc_spec): the token
// must be sealed under kr's CURRENT epoch. Anything else, including an older epoch
// the keyring still holds, is rejected before decryption.
bridge_open_current_epoch_token :: proc(token: string, kr: ^vault.Vault_Keyring, allocator := context.allocator) -> (plaintext: string, ok: bool) {
	if kr == nil do return "", false
	epoch, payload, res := vault.envelope_parse(token, context.temp_allocator)
	if res != .Ok do return "", false
	crypto.zero_explicit(raw_data(payload), len(payload))
	if epoch != kr.current_epoch do return "", false
	return bridge_decrypt_vault_token(token, kr, allocator)
}

// bridge_encrypt_vault_text seals under kr's current epoch with a fresh CSPRNG
// nonce; a randomness failure returns ok=false and nothing is produced.
bridge_encrypt_vault_text :: proc(plaintext: string, kr: ^vault.Vault_Keyring, allocator := context.allocator) -> (armored: string, ok: bool) {
	return vault.seal_string(plaintext, kr, allocator)
}

// bridge_decrypt_embedded_vault_tokens replaces every v2 token in text with its
// plaintext using this bridge's keyring. A token whose epoch is not held becomes
// locked_marker (or stays verbatim when locked_marker is empty, the default); a
// token that does not authenticate becomes "[Encrypted]". Caller owns the result.
bridge_decrypt_embedded_vault_tokens :: proc(text: string, allocator := context.allocator, locked_marker := "") -> string {
	if !vault.contains_token(text) do return strings.clone(text, allocator)
	kr, ok := bridge_read_vault_keyring()
	defer vault.keyring_wipe(&kr)
	return vault.replace_embedded_tokens(text, &kr if ok else nil, locked_marker, vault.FAILED_MARKER, allocator)
}

// Explicitly lock and purge this bridge's unsealed keyring from the kernel keyring
// / Keychain / Credential Manager / Termux sealed file and RAM; other bridges' keys
// are untouched (REQ-T5-3). The identity key stays: a locked bridge is still the
// same, enrolled bridge and keeps reporting "locked".
bridge_vault_lock :: proc() {
	bridge_task_chain_search_lock()
	keystore_lock_and_purge(bridge_config.daemon_id)
}

// Purges the keyring like a lock and deletes the identity key, so a human must
// approve a new enrollment before this bridge is trusted with a keyring again
// (purge-on-revoke). Bridge-local only (agent vault.reset op); the hub never
// triggers it. Under Termux it also deletes this bridge's Android Keystore key.
bridge_vault_reset :: proc() {
	bridge_vault_lock()
	_ = keystore_delete_identity_key(bridge_config.daemon_id)
	bridge_unseal_forget_identity()
	when ODIN_OS == .Linux {
		if keystore_android_selected() do _ = keystore_android_delete_keystore_key(bridge_config.daemon_id)
	}
}

// Explicitly wipe unsealed vault key material on bridge shutdown
bridge_vault_shutdown :: proc() {
	bridge_task_chain_search_lock()
	keystore_lock_and_purge(bridge_config.daemon_id)
}

// bridge_keyring_bytes_from_env decodes HEIMDALL_VAULT_KEYRING (standard base64 of
// the HKR1 bytes). present reports the variable is set and non-blank: a present but
// invalid value yields no keyring and must not fall through to other sources.
bridge_keyring_from_env_value :: proc(value: string) -> (kr: vault.Vault_Keyring, present: bool, ok: bool) {
	trimmed := strings.trim_space(value)
	if trimmed == "" do return {}, false, false
	raw, dec_ok := vault.b64_decode_strict(trimmed, context.temp_allocator)
	if !dec_ok do return {}, true, false
	defer crypto.zero_explicit(raw_data(raw), len(raw))
	kr, ok = vault.keyring_parse(raw)
	return kr, true, ok
}
