package main

import "core:c"
import "core:crypto"
import "core:crypto/aes"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:mem"
import "core:strings"
import "core:sys/posix"

VAULT_ARMOR_PREFIX :: "vault:v1:"
ENC_ARMOR_PREFIX   :: "ENC:v1:"
VAULT_NONCE_BYTES  :: 12
VAULT_TAG_BYTES    :: 16
VAULT_KEY_BYTES    :: 32
VAULT_HEADER_BYTES :: VAULT_NONCE_BYTES + VAULT_TAG_BYTES // 28

MADV_DONTDUMP      :: 16

foreign import libc "system:c"
foreign libc {
	madvise :: proc(addr: rawptr, len: c.size_t, advice: c.int) -> c.int ---
}

Secure_Key :: struct {
	ptr:      [^]u8,
	len:      int,
	capacity: int,
	locked:   bool,
	dontdump: bool,
}

// Allocates active key material via posix.mmap, locks it with posix.mlock() so it cannot be
// paged to swap, and flags it with posix.madvise(MADV_DONTDUMP) to prevent key material
// from being written to crash/core dumps.
secure_key_alloc :: proc(size: int) -> (key: Secure_Key, ok: bool) {
	if size <= 0 do return {}, false

	page_size := 4096
	alloc_size := ((size + page_size - 1) / page_size) * page_size

	addr := posix.mmap(
		nil,
		c.size_t(alloc_size),
		posix.Prot_Flags{.READ, .WRITE},
		posix.Map_Flags{.PRIVATE, .ANONYMOUS},
	)
	if addr == posix.MAP_FAILED || addr == nil {
		return {}, false
	}

	key.ptr = cast([^]u8)addr
	key.len = size
	key.capacity = alloc_size

	// Protect with posix.mlock() so it cannot be paged to swap
	lock_res := posix.mlock(addr, c.size_t(alloc_size))
	key.locked = (lock_res == .OK)

	// Apply posix.madvise(ptr, len, MADV_DONTDUMP) to prevent key material from being written to crash/core dumps
	adv_res := madvise(addr, c.size_t(alloc_size), MADV_DONTDUMP)
	key.dontdump = (adv_res == 0)

	return key, true
}

// On lock, shutdown, or scope exit, securely wipe key memory using mem.zero_explicit(),
// then unlock and unmap.
secure_key_wipe_and_free :: proc(key: ^Secure_Key) {
	if key == nil || key.ptr == nil do return

	mem.zero_explicit(rawptr(key.ptr), key.capacity)

	if key.locked {
		_ = posix.munlock(rawptr(key.ptr), c.size_t(key.capacity))
		key.locked = false
	}

	_ = posix.munmap(rawptr(key.ptr), c.size_t(key.capacity))
	key.ptr = nil
	key.len = 0
	key.capacity = 0
	key.dontdump = false
}

bridge_hex_to_nibble :: proc(c: byte) -> (u8, bool) {
	switch c {
	case '0'..='9': return c - '0', true
	case 'a'..='f': return c - 'a' + 10, true
	case 'A'..='F': return c - 'A' + 10, true
	}
	return 0, false
}

bridge_hex_decode_to_buf :: proc(dst: []u8, hex_str: string) -> bool {
	if len(hex_str) != len(dst) * 2 do return false
	for i in 0 ..< len(dst) {
		hi, ok1 := bridge_hex_to_nibble(hex_str[i * 2])
		lo, ok2 := bridge_hex_to_nibble(hex_str[i * 2 + 1])
		if !ok1 || !ok2 do return false
		dst[i] = (hi << 4) | lo
	}
	return true
}

bridge_is_valid_hex_key :: proc(key_hex: string) -> bool {
	if len(key_hex) != 64 do return false
	for i in 0 ..< len(key_hex) {
		c := key_hex[i]
		switch c {
		case '0'..='9', 'a'..='f', 'A'..='F':
		case:
			return false
		}
	}
	return true
}

bridge_vault_prefix_len :: proc(s: string) -> int {
	if strings.has_prefix(s, VAULT_ARMOR_PREFIX) do return len(VAULT_ARMOR_PREFIX)
	if strings.has_prefix(s, ENC_ARMOR_PREFIX) do return len(ENC_ARMOR_PREFIX)
	return 0
}

bridge_has_vault_token :: proc(s: string) -> bool {
	return strings.contains(s, VAULT_ARMOR_PREFIX) || strings.contains(s, ENC_ARMOR_PREFIX)
}

bridge_decrypt_vault_ciphertext :: proc(armored: string, key_bytes: []u8, allocator := context.allocator) -> (plaintext: string, ok: bool) {
	pfx_len := bridge_vault_prefix_len(armored)
	if pfx_len == 0 {
		return strings.clone(armored, allocator), true
	}
	if len(key_bytes) != VAULT_KEY_BYTES do return "", false

	b64 := strings.trim_space(armored[pfx_len:])
	if len(b64) == 0 do return "", false

	for i in 0 ..< len(b64) {
		c := b64[i]
		switch c {
		case 'A'..='Z', 'a'..='z', '0'..='9', '+', '/', '=':
		case:
			return "", false
		}
	}

	payload, err := base64.decode(b64, allocator = context.temp_allocator)
	if err != nil do return "", false
	if len(payload) < VAULT_HEADER_BYTES do return "", false

	nonce := payload[0:VAULT_NONCE_BYTES]
	tag := payload[VAULT_NONCE_BYTES:VAULT_HEADER_BYTES]
	ciphertext := payload[VAULT_HEADER_BYTES:]

	dst := make([]byte, len(ciphertext), allocator)
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, key_bytes)
	defer aes.reset_gcm(&gcm)

	if !aes.open_gcm(&gcm, dst, nonce, nil, ciphertext, tag) {
		delete(dst, allocator)
		return "", false
	}
	return string(dst), true
}

bridge_decrypt_vault_ciphertext_hex :: proc(armored: string, key_hex: string, allocator := context.allocator) -> (plaintext: string, ok: bool) {
	if bridge_vault_prefix_len(armored) == 0 {
		return strings.clone(armored, allocator), true
	}
	if !bridge_is_valid_hex_key(key_hex) do return "", false

	skey, s_ok := secure_key_alloc(VAULT_KEY_BYTES)
	if !s_ok {
		raw_key, hex_ok := hex.decode(transmute([]byte)key_hex, context.temp_allocator)
		if !hex_ok || len(raw_key) != VAULT_KEY_BYTES do return "", false
		defer mem.zero_explicit(raw_data(raw_key), len(raw_key))
		return bridge_decrypt_vault_ciphertext(armored, raw_key, allocator)
	}
	defer secure_key_wipe_and_free(&skey)

	if !bridge_hex_decode_to_buf(skey.ptr[:VAULT_KEY_BYTES], key_hex) {
		return "", false
	}
	return bridge_decrypt_vault_ciphertext(armored, skey.ptr[:VAULT_KEY_BYTES], allocator)
}

// Encrypt plaintext string using 256-bit AES-GCM (matching src/ctl/vault_content.odin)
// Useful for tests and symmetrical bridge encryption if needed.
bridge_encrypt_vault_ciphertext :: proc(plaintext: string, key_bytes: []u8, allocator := context.allocator) -> (armored: string, ok: bool) {
	if len(key_bytes) != VAULT_KEY_BYTES do return "", false

	plaintext_bytes := transmute([]byte)plaintext
	nonce: [VAULT_NONCE_BYTES]byte
	crypto.rand_bytes(nonce[:])

	ciphertext := make([]byte, len(plaintext_bytes), context.temp_allocator)
	tag: [VAULT_TAG_BYTES]byte

	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, key_bytes)
	defer aes.reset_gcm(&gcm)

	aes.seal_gcm(&gcm, ciphertext, tag[:], nonce[:], nil, plaintext_bytes)

	payload_len := VAULT_HEADER_BYTES + len(ciphertext)
	payload := make([]byte, payload_len, context.temp_allocator)
	copy(payload[0:VAULT_NONCE_BYTES], nonce[:])
	copy(payload[VAULT_NONCE_BYTES:VAULT_HEADER_BYTES], tag[:])
	copy(payload[VAULT_HEADER_BYTES:], ciphertext)

	b64, err := base64.encode(payload, allocator = context.temp_allocator)
	if err != nil do return "", false

	res := strings.concatenate({VAULT_ARMOR_PREFIX, b64}, allocator)
	return res, true
}

bridge_encrypt_vault_ciphertext_hex :: proc(plaintext: string, key_hex: string, allocator := context.allocator) -> (armored: string, ok: bool) {
	if !bridge_is_valid_hex_key(key_hex) do return "", false

	skey, s_ok := secure_key_alloc(VAULT_KEY_BYTES)
	if !s_ok {
		raw_key, hex_ok := hex.decode(transmute([]byte)key_hex, context.temp_allocator)
		if !hex_ok || len(raw_key) != VAULT_KEY_BYTES do return "", false
		defer mem.zero_explicit(raw_data(raw_key), len(raw_key))
		return bridge_encrypt_vault_ciphertext(plaintext, raw_key, allocator)
	}
	defer secure_key_wipe_and_free(&skey)

	if !bridge_hex_decode_to_buf(skey.ptr[:VAULT_KEY_BYTES], key_hex) {
		return "", false
	}
	return bridge_encrypt_vault_ciphertext(plaintext, skey.ptr[:VAULT_KEY_BYTES], allocator)
}

// VAULT_LOCKED_MARKER replaces a vault token that cannot be decrypted because no
// vault key is available, for callers that opt in via locked_marker (bootstrap
// files). Raw ciphertext in an agent's AGENTS.md/MEMORY.md reads as garbage and
// hides the real problem; this names it.
VAULT_LOCKED_MARKER :: "[encrypted: bridge vault locked]"

// bridge_vault_token_end returns the end index of the 'vault:v1:<base64>' or
// 'ENC:v1:<base64>' token starting at idx (base64 alphabet, including URL-safe '-' and '_').
bridge_vault_token_end :: proc(text: string, idx: int) -> int {
	pfx_len := bridge_vault_prefix_len(text[idx:])
	if pfx_len == 0 do pfx_len = len(VAULT_ARMOR_PREFIX)
	tok_end := idx + pfx_len
	for tok_end < len(text) {
		switch text[tok_end] {
		case 'A'..='Z', 'a'..='z', '0'..='9', '+', '/', '=', '-', '_':
			tok_end += 1
		case:
			return tok_end
		}
	}
	return tok_end
}

// bridge_decrypt_embedded_vault_tokens scans text for embedded 'vault:v1:<base64>' or 'ENC:v1:<base64>' tokens,
// decrypting each with AES-256-GCM using the vault key read via bridge_read_vault_key().
// Active key material is held in mlock'd + MADV_DONTDUMP memory and zeroed on exit.
// On success, the token is replaced with the decrypted plaintext.
// On decryption failure (e.g. invalid base64 or bad tag), the token is replaced with '[Encrypted]'.
// A bare 'vault:v1:' or 'ENC:v1:' with no payload is prose that mentions the prefix, not a token,
// and is kept verbatim.
// If no vault key is available, each token is replaced with locked_marker, or the
// text is returned unchanged when locked_marker is empty (the default).
// Caller owns the returned string.
bridge_decrypt_embedded_vault_tokens :: proc(text: string, allocator := context.allocator, locked_marker := "") -> string {
	if !bridge_has_vault_token(text) {
		return strings.clone(text, allocator)
	}

	key_hex, key_ok := bridge_read_vault_key()
	if !key_ok {
		return bridge_replace_embedded_vault_tokens(text, nil, locked_marker, allocator)
	}
	defer {
		mem.zero_explicit(raw_data(key_hex), len(key_hex))
		delete(key_hex)
	}

	skey, s_ok := secure_key_alloc(VAULT_KEY_BYTES)
	if !s_ok {
		return bridge_replace_embedded_vault_tokens(text, nil, locked_marker, allocator)
	}
	defer secure_key_wipe_and_free(&skey)

	if !bridge_hex_decode_to_buf(skey.ptr[:VAULT_KEY_BYTES], key_hex) {
		return bridge_replace_embedded_vault_tokens(text, nil, locked_marker, allocator)
	}

	return bridge_replace_embedded_vault_tokens(text, skey.ptr[:VAULT_KEY_BYTES], locked_marker, allocator)
}

bridge_next_vault_token_index :: proc(s: string) -> (idx: int, pfx_len: int) {
	iv := strings.index(s, VAULT_ARMOR_PREFIX)
	ie := strings.index(s, ENC_ARMOR_PREFIX)
	switch {
	case iv >= 0 && (ie < 0 || iv <= ie):
		return iv, len(VAULT_ARMOR_PREFIX)
	case ie >= 0:
		return ie, len(ENC_ARMOR_PREFIX)
	}
	return -1, 0
}

// bridge_replace_embedded_vault_tokens does the token scan for
// bridge_decrypt_embedded_vault_tokens. With a nil raw_key every token becomes
// locked_marker, or the text is cloned unchanged if locked_marker is empty.
@(private = "file")
bridge_replace_embedded_vault_tokens :: proc(text: string, raw_key: []u8, locked_marker: string, allocator := context.allocator) -> string {
	if raw_key == nil && locked_marker == "" {
		return strings.clone(text, allocator)
	}

	b := strings.builder_make(allocator)
	remaining := text
	for len(remaining) > 0 {
		idx, pfx_len := bridge_next_vault_token_index(remaining)
		if idx < 0 {
			strings.write_string(&b, remaining)
			break
		}
		strings.write_string(&b, remaining[:idx])

		tok_end := bridge_vault_token_end(remaining, idx)
		token := remaining[idx:tok_end]
		switch {
		case tok_end == idx + pfx_len:
			strings.write_string(&b, token)
		case raw_key == nil:
			strings.write_string(&b, locked_marker)
		case:
			plaintext, dec_ok := bridge_decrypt_vault_ciphertext(token, raw_key, context.temp_allocator)
			strings.write_string(&b, plaintext if dec_ok else "[Encrypted]")
		}

		remaining = remaining[tok_end:]
	}

	return strings.to_string(b)
}

// Explicitly lock and purge this bridge's unsealed vault key material from the
// kernel keyring / Keychain / Termux sealed file and RAM; other bridges' keys
// are untouched (REQ-T5-3).
// The vault_configured marker stays, so a locked bridge keeps reporting "locked"
// rather than "disabled" across restarts (REQ-T3-2).
bridge_vault_lock :: proc() {
	bridge_task_chain_search_lock()
	keystore_lock_and_purge(bridge_config.daemon_id)
}

// Turns vault encryption off for this bridge: purges the key like a lock AND
// forgets that the vault was ever configured, so it reports "disabled" until the
// next unseal. Bridge-local only (agent vault.reset op); the hub never triggers it.
// Returns false if the marker could not be removed. Under Termux it also deletes
// this bridge's Android Keystore key, so the next unseal generates a fresh one.
bridge_vault_reset :: proc() -> bool {
	bridge_vault_lock()
	when ODIN_OS == .Linux {
		if keystore_android_selected() do _ = keystore_android_delete_keystore_key(bridge_config.daemon_id)
	}
	return bridge_vault_set_configured(bridge_config.daemon_id, false)
}

// Explicitly wipe unsealed vault key material on bridge shutdown
bridge_vault_shutdown :: proc() {
	bridge_task_chain_search_lock()
	keystore_lock_and_purge(bridge_config.daemon_id)
}
