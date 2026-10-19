package main

import "core:crypto/hash"
import "core:strings"
import "core:sync"
import vault "odin_test:lib/vault"

// Several bridges can run on one machine for different hubs and accounts, so every
// persisted vault item (keyring, identity record, epoch floor; on every OS backend:
// Credential Manager target, Keychain account, Linux @u description and private
// directory, Termux sealed files) is named by a SCOPE, not by the bridge id alone:
//
//   <bridge_id>_<hex(SHA-256("heimdall-bridge-scope/v1|" + canonical hub base + "|" + bridge_id))[:32]>
//
// The canonical hub base (bridge_hub_canonical_base: lowercase scheme://host:port
// plus any path prefix) is bound to the process once (bridge_keystore_set_hub: from
// --hub at enrollment, from the config's hub at runtime). A hostile hub that hands a
// new bridge another hub's bridge_id therefore names DIFFERENT items and can neither
// read nor overwrite the other bridge's identity, keyring or floor. With no hub bound
// nothing is persisted or found (fail closed). There is no unscoped name to fall back
// to: an id that fails keystore_bridge_id_ok persists nothing and finds nothing.

// Every keystore test uses an id with this prefix (keystore_test_bridge_ids), and
// a test build refuses any other id, so even a full `odin test src/bridge` on a
// host with an enrolled bridge can never read, overwrite or purge its key
// (REQ-T5-4). A real bridge id is `brg_<hex>` and never carries it.
KEYSTORE_TEST_BRIDGE_ID_PREFIX :: "brg_test_"

// Every Hub-issued bridge id carries this prefix.
KEYSTORE_BRIDGE_ID_PREFIX :: "brg_"

// keystore_store_vault_key's err_code when bridge_id cannot name a key.
KEYSTORE_ERR_BAD_BRIDGE_ID :: -2

keystore_bridge_id_ok :: proc(bridge_id: string) -> bool {
	if !keystore_bridge_id_is_enrolled(bridge_id) do return false
	when ODIN_TEST {
		return strings.has_prefix(bridge_id, KEYSTORE_TEST_BRIDGE_ID_PREFIX)
	} else {
		return true
	}
}

// keystore_bridge_id_is_enrolled accepts only a safe, Hub-issued `brg_` id. An
// unenrolled bridge keeps the default daemon_id "local-daemon" (main.odin), which is
// shared by every unenrolled bridge on the host, so letting it name a key would let
// two such bridges read and overwrite each other's key (REQ-T6-6).
keystore_bridge_id_is_enrolled :: proc(bridge_id: string) -> bool {
	if !bridge_vault_is_safe_bridge_id(bridge_id) do return false
	return strings.has_prefix(bridge_id, KEYSTORE_BRIDGE_ID_PREFIX) && len(bridge_id) > len(KEYSTORE_BRIDGE_ID_PREFIX)
}

BRIDGE_SCOPE_HEADER :: "heimdall-bridge-scope/v1|"
BRIDGE_SCOPE_HEX_CHARS :: 32
BRIDGE_HUB_BASE_MAX :: 255

@(private = "file")
g_keystore_hub_mu: sync.Mutex
@(private = "file")
g_keystore_hub_buf: [BRIDGE_HUB_BASE_MAX]u8
@(private = "file")
g_keystore_hub_len: int

// bridge_keystore_set_hub binds this process's vault state to one hub (canonical
// base). "" unbinds (tests only). False for an unusable URL; nothing is bound then.
bridge_keystore_set_hub :: proc(hub_url: string) -> bool {
	sync.mutex_lock(&g_keystore_hub_mu)
	defer sync.mutex_unlock(&g_keystore_hub_mu)
	if hub_url == "" {
		g_keystore_hub_len = 0
		return true
	}
	base, ok := bridge_hub_canonical_base(hub_url, context.temp_allocator)
	if !ok || len(base) > BRIDGE_HUB_BASE_MAX do return false
	copy(g_keystore_hub_buf[:], base)
	g_keystore_hub_len = len(base)
	return true
}

// bridge_keystore_hub is the bound canonical hub base ("" when none). Temp-allocated.
bridge_keystore_hub :: proc() -> string {
	sync.mutex_lock(&g_keystore_hub_mu)
	defer sync.mutex_unlock(&g_keystore_hub_mu)
	if g_keystore_hub_len == 0 {
		when ODIN_TEST {
			// A test that binds nothing still gets a fixed, test-only scope.
			return "http://keystore.test.invalid:1"
		} else {
			return ""
		}
	}
	return strings.clone(string(g_keystore_hub_buf[:g_keystore_hub_len]), context.temp_allocator)
}

// keystore_scope_name is the OS item name for bridge_id under the bound hub.
// Temp-allocated; ok=false (persist/find nothing) without a hub or a valid id.
keystore_scope_name :: proc(bridge_id: string) -> (string, bool) {
	if !keystore_bridge_id_ok(bridge_id) do return "", false
	hub := bridge_keystore_hub()
	if hub == "" do return "", false
	digest: [32]byte
	hash.hash_string_to_buffer(.SHA256, strings.concatenate({BRIDGE_SCOPE_HEADER, hub, "|", bridge_id}, context.temp_allocator), digest[:])
	scope := vault.hex_encode_lower(digest[:], context.temp_allocator)[:BRIDGE_SCOPE_HEX_CHARS]
	name := strings.concatenate({bridge_id, "_", scope}, context.temp_allocator)
	if len(name) > 128 || !bridge_vault_is_safe_bridge_id(name) do return "", false
	return name, true
}