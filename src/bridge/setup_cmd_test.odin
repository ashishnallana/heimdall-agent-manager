package main

import "core:testing"

@(test)
test_bridge_setup_enroll_needed :: proc(t: ^testing.T) {
	base := []string{"setup", "--hub", "https://hub.example.com"}
	testing.expect(t, bridge_setup_enroll_needed(base, ""), "no credential: enroll")
	testing.expect(t, !bridge_setup_enroll_needed(base, "brg_current"), "enrolled: skip")
	testing.expect(t, !bridge_setup_enroll_needed([]string{"setup", "--reuse-bridge", "brg_current"}, "brg_current"), "reuse of the current bridge: skip")
	testing.expect(t, bridge_setup_enroll_needed([]string{"setup", "--reuse-bridge", "brg_other"}, "brg_current"), "reuse of another bridge: enroll")
	testing.expect(t, bridge_setup_enroll_needed([]string{"setup", "--new-bridge"}, "brg_current"), "--new-bridge: enroll")
	testing.expect(t, bridge_setup_enroll_needed([]string{"setup", "--reenroll"}, "brg_current"), "--reenroll: enroll the same bridge again")
	testing.expect(t, bridge_setup_enroll_needed([]string{"setup", "--reenroll", "--reuse-bridge", "brg_current"}, "brg_current"), "--reenroll wins over a matching --reuse-bridge")
}
