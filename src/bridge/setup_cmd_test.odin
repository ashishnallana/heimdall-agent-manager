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

@(test)
test_bridge_setup_service_path_merges_login_shell_and_known_dirs :: proc(t: ^testing.T) {
	exists :: proc(path: string) -> bool {
		return path == "/Users/u/.local/bin" || path == "/opt/homebrew/bin" || path == "/etc/profiles/per-user/u/bin"
	}
	// A GUI/launchd PATH plus the login shell's: the order is kept, duplicates
	// dropped, existing well-known dirs added, the system dirs always last.
	got := bridge_setup_service_path("/usr/bin:/bin", "/opt/homebrew/bin:/Users/u/.npm/bin:/usr/bin", "/Users/u", "u", exists)
	testing.expect_value(t, got, "/usr/bin:/bin:/opt/homebrew/bin:/Users/u/.npm/bin:/Users/u/.local/bin:/etc/profiles/per-user/u/bin:/usr/sbin:/sbin")
	// No login shell: the known dirs still make Homebrew and ~/.local/bin visible.
	got = bridge_setup_service_path("/usr/bin:/bin:/usr/sbin:/sbin", "", "/Users/u", "u", exists)
	testing.expect_value(t, got, "/usr/bin:/bin:/usr/sbin:/sbin:/Users/u/.local/bin:/etc/profiles/per-user/u/bin:/opt/homebrew/bin")
}

@(test)
test_bridge_setup_extract_marked_path_ignores_shell_noise :: proc(t: ^testing.T) {
	out := "Last login: today\nwelcome!\n" + BRIDGE_SETUP_PATH_MARK + "/a:/b" + BRIDGE_SETUP_PATH_MARK + "\n% "
	testing.expect_value(t, bridge_setup_extract_marked_path(out), "/a:/b")
	testing.expect_value(t, bridge_setup_extract_marked_path("no markers"), "")
	testing.expect_value(t, bridge_setup_extract_marked_path(BRIDGE_SETUP_PATH_MARK + "/a"), "")
}

@(test)
test_bridge_setup_windows_user :: proc(t: ^testing.T) {
	testing.expect_value(t, bridge_setup_windows_user("CORP", "ann"), "CORP\\ann")
	testing.expect_value(t, bridge_setup_windows_user("", "ann"), "ann")
	testing.expect_value(t, bridge_setup_windows_user("CORP", " "), "")
}
