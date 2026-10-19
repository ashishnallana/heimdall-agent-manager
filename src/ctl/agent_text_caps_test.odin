package main

import "core:strings"
import "core:testing"
import vault "odin_test:lib/vault"

// ── REQ-VCAP-4/5: ctl's early PLAINTEXT cap, iss_18d940db15f9accb ────────────
//
// ctl encrypts before sending, so it is the only side that can check the real
// plaintext budget. These tests pin the mirrored caps to the armor arithmetic:
// a plaintext at the cap must still fit the Hub's armored budget once encrypted,
// otherwise ctl would accept a value the Hub then rejects.

@(test)
test_ctl_plaintext_caps_mirror_hub_domain :: proc(t: ^testing.T) {
	// Mirrors src/hub/domain/taskchain.odin CHAIN_TITLE_MAX_BYTES /
	// CHAIN_DESCRIPTION_MAX_BYTES. If the Hub's caps change, this fails.
	testing.expect_value(t, CTL_CHAIN_TITLE_MAX_BYTES, 120)
	testing.expect_value(t, CTL_CHAIN_DESCRIPTION_MAX_BYTES, 4000)
}

@(test)
test_ctl_plaintext_cap_boundary :: proc(t: ^testing.T) {
	at_cap := strings.repeat("a", CTL_CHAIN_TITLE_MAX_BYTES, context.temp_allocator)
	testing.expect(
		t,
		ctl_check_plaintext_cap("chain title", at_cap, CTL_CHAIN_TITLE_MAX_BYTES),
		"a plaintext title exactly at the cap must be accepted locally",
	)
	testing.expect(
		t,
		ctl_check_plaintext_cap("chain title", "", CTL_CHAIN_TITLE_MAX_BYTES),
		"an empty value must not trip the cap",
	)
	over := strings.repeat("a", CTL_CHAIN_TITLE_MAX_BYTES + 1, context.temp_allocator)
	testing.expect(
		t,
		!ctl_check_plaintext_cap("chain title", over, CTL_CHAIN_TITLE_MAX_BYTES),
		"a plaintext title one byte over the cap must be rejected locally",
	)
}

// An at-cap plaintext, once really encrypted, must fit the armored budget the
// Hub enforces (len("vault:v2:") + 16 vault-id hex + len(":e") + 10 epoch digits + 1 + 4*ceil((n+28)/3)). This is the contract that
// keeps the two sides from disagreeing.
@(test)
test_ctl_at_cap_plaintext_fits_hub_armored_budget :: proc(t: ^testing.T) {
	kr := tkr("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")

	for n in ([2]int{CTL_CHAIN_TITLE_MAX_BYTES, CTL_CHAIN_DESCRIPTION_MAX_BYTES}) {
		plaintext := strings.repeat("a", n, context.temp_allocator)
		armored, ok := ctl_vault_seal(plaintext, kr, context.temp_allocator)
		testing.expect(t, ok, "encryption of an at-cap plaintext must succeed")
		testing.expect(t, is_vault_armored(armored), "value must be armored")

		budget := len(VAULT_ARMOR_PREFIX) + vault.VAULT_ID_HEX_CHARS + 2 + 10 + 1 + 4 * ((n + vault.HEADER_BYTES + 2) / 3)
		testing.expectf(
			t,
			len(armored) <= budget,
			"plaintext %d bytes -> armored %d bytes, but the Hub's derived budget is %d",
			n,
			len(armored),
			budget,
		)
	}
}
