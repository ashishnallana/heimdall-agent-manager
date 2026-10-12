package main

import "core:strings"

// Several bridges can run on one machine under different accounts, so the
// persisted vault key is addressed by the owning bridge's id (REQ-T5-1): the
// Linux @u description is KEY_DESC_VAULT_PREFIX + <bridge_id>, the macOS
// Keychain account is <bridge_id>. There is no unscoped name to fall back to: an
// id that fails keystore_bridge_id_ok persists nothing and finds nothing.

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
