package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import bridgesvc "odin_test:lib/bridgesvc"

@(test)
test_setup_rejects_colliding_hub_owner_before_stopping_or_staging :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/bridge-owner-preflight-%d", os.temp_dir(context.temp_allocator), os.get_pid())
	defer os.remove_all(root)
	host := bridgesvc.Host{os = .Linux, home = root, uid = 1000}
	a, a_ok := bridgesvc.profile_from("https://a.b", "work", context.temp_allocator)
	b, b_ok := bridgesvc.profile_from("https://a-b", "work", context.temp_allocator)
	testing.expect(t, a_ok && b_ok)
	testing.expect_value(t, a.service_name, b.service_name)
	l := bridgesvc.layout_for(host, a.service_name)
	testing.expect(t, os.make_directory_all(l.state_dir) == nil)
	testing.expect(t, os.write_entire_file_from_string(bridgesvc.pjoin(l.state_dir, bridgesvc.HUB_URL_FILE), a.hub_url) == nil)
	s := Bridge_Setup{host = host, profile = b, layout = l, copy_binaries = true, staging = bridgesvc.pjoin(l.data_dir, ".staging")}
	result := bridge_setup_run(&s, .Stage)
	testing.expect(t, !result.ok && result.failure == .Fatal)
	testing.expect(t, !s.snapshot_taken && !s.stopped_for_setup, "ownership must be checked before service discovery or stop")
	testing.expect(t, !os.exists(s.staging), "another Hub's profile must not be staged over")
}

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

// --separate-account always asks for a profile of its own; without it a
// non-interactive setup (installers, --headless) never prompts and keeps the
// requested profile, and --replace-other-account keeps it too.
@(test)
test_bridge_setup_wants_separate_account :: proc(t: ^testing.T) {
	host := bridgesvc.Host{os = .Linux, home = "/nonexistent-ham-home", uid = 1000}
	profile, ok := bridgesvc.profile_from("https://hub.example.com", "", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, bridge_setup_wants_separate_account(host, []string{"setup", "--separate-account"}, profile))
	testing.expect(t, !bridge_setup_wants_separate_account(host, []string{"setup", "--headless", "--new-bridge"}, profile))
	testing.expect(t, !bridge_setup_wants_separate_account(host, []string{"setup", "--replace-other-account"}, profile))
	// Nothing enrolled: the requested profile is used as is.
	selected_1, found_1 := bridgesvc.separate_account_profile(host, profile.hub_name, "")
	testing.expect(t, found_1)
	testing.expect_value(t, selected_1, "")
	selected_2, found_2 := bridgesvc.separate_account_profile(host, profile.hub_name, "work")
	testing.expect(t, found_2)
	testing.expect_value(t, selected_2, "work")
}

// Headless (installers, Electron) nobody can confirm a replace: a run that would
// enroll a new bridge into another account's enrolled profile goes to a separate
// profile, and the enrolled one is left alone.
@(test)
test_bridge_setup_headless_enrolled_profile_defaults_to_separate :: proc(t: ^testing.T) {
	home := fmt.aprintf("%s/.cache/heimdall-tests/setup-separate-%d", os.get_env("HOME", context.temp_allocator), os.get_pid())
	defer delete(home)
	_ = os.remove_all(home)
	defer os.remove_all(home)
	host := bridgesvc.Host{os = .Linux, home = home, uid = 1000}
	profile, ok := bridgesvc.profile_from("https://hub.example.com", "", context.temp_allocator)
	testing.expect(t, ok)
	l := bridgesvc.layout_for(host, profile.service_name)
	testing.expect(t, os.make_directory_all(l.state_dir) == nil)
	credential := strings.concatenate({bridgesvc.CREDENTIAL_HEADER, "secret brg_account_a\n"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file_from_string(bridgesvc.pjoin(l.state_dir, bridgesvc.TOKEN_FILE), credential) == nil)

	headless := []string{"setup", "--hub", "https://hub.example.com", "--headless", "--json-progress"}
	with :: proc(base: []string, extra: ..string) -> []string {
		out := make([dynamic]string, context.temp_allocator)
		append(&out, ..base)
		append(&out, ..extra)
		return out[:]
	}
	testing.expect(t, bridge_setup_wants_separate_account(host, with(headless, "--new-bridge"), profile), "new bridge into an enrolled profile: separate")
	testing.expect(t, bridge_setup_wants_separate_account(host, with(headless, "--reuse-bridge", "brg_other"), profile), "another bridge into an enrolled profile: separate")
	testing.expect(t, !bridge_setup_wants_separate_account(host, headless, profile), "update of the enrolled profile stays in place")
	testing.expect(t, !bridge_setup_wants_separate_account(host, with(headless, "--reuse-bridge", "brg_account_a"), profile), "reuse of the current bridge stays in place")
	testing.expect(t, !bridge_setup_wants_separate_account(host, with(headless, "--reenroll"), profile), "re-pairing its own bridge stays in place")
	testing.expect(t, !bridge_setup_wants_separate_account(host, with(headless, "--new-bridge", "--replace-other-account"), profile), "an explicit replace is honoured")
	// The separate profile is a fresh one; the enrolled default is never chosen.
	selected_3, found_3 := bridgesvc.separate_account_profile(host, profile.hub_name, "")
	testing.expect(t, found_3)
	testing.expect_value(t, selected_3, "account-2")
}
