#+build !windows
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import bridgesvc "odin_test:lib/bridgesvc"

// Where agent shims find ham-ctl, and that setup leaves it there across bin/ swaps.

@(private = "file")
ham_ctl_loc_test_dir :: proc(t: ^testing.T, tag: string) -> string {
	dir := fmt.aprintf("%s/.cache/heimdall-tests/ham-ctl-loc-%s-%d", os.get_env("HOME", context.temp_allocator), tag, int(posix.getpid()))
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil, "test dir")
	return dir
}

@(private = "file")
ham_ctl_loc_test_exe :: proc(t: ^testing.T, path: string) {
	testing.expect(t, os.write_entire_file_from_string(path, "#!/bin/sh\n", {.Read_User, .Write_User, .Execute_User}) == nil, path)
}

@(test)
test_bridge_resolve_ham_ctl_prefers_env_then_sibling :: proc(t: ^testing.T) {
	dir := ham_ctl_loc_test_dir(t, "resolve")
	defer delete(dir)
	defer _ = os.remove_all(dir)
	bridge := strings.concatenate({dir, "/ham-bridge"}, context.temp_allocator)
	sibling := strings.concatenate({dir, "/ham-ctl"}, context.temp_allocator)
	ham_ctl_loc_test_exe(t, bridge)
	ham_ctl_loc_test_exe(t, sibling)

	// An executable env value wins.
	got := bridge_bootstrap_resolve_ham_ctl("/bin/sh", bridge)
	testing.expect_value(t, got, bridge_bootstrap_normalize_executable_path("/bin/sh"))

	// The pre-fix service files named bin/ham-ctl-<service>, which setup never
	// installed: skip it and use the ham-ctl beside ham-bridge.
	got = bridge_bootstrap_resolve_ham_ctl(strings.concatenate({dir, "/ham-ctl-heimdall-bridge-hub-x"}, context.temp_allocator), bridge)
	testing.expect_value(t, got, sibling)

	// No env value: the sibling, not whatever ham-ctl PATH holds.
	got = bridge_bootstrap_resolve_ham_ctl("", bridge)
	testing.expect_value(t, got, sibling)

	// A non-executable sibling is not used.
	_ = os.chmod(sibling, {.Read_User, .Write_User})
	got = bridge_bootstrap_resolve_ham_ctl("", bridge)
	testing.expect(t, got != sibling, "non-executable sibling skipped")
}

@(test)
test_bridge_setup_ctl_wrapper_survives_bin_swap :: proc(t: ^testing.T) {
	home := ham_ctl_loc_test_dir(t, "wrapper")
	defer delete(home)
	defer _ = os.remove_all(home)
	host := bridgesvc.Host{os = .Linux, home = home, uid = 1000}
	s := Bridge_Setup{host = host, layout = bridgesvc.layout_for(host, "heimdall-bridge-hub-example-com")}
	in_ := bridgesvc.Render_Input{hub = "https://hub.example.com", bridge_port = 49325, endpoint_port = 49326}
	wrapper := bridgesvc.ctl_wrapper_path(host, s.layout)

	// install: bin/ is fresh from staging (binaries only); the Service step adds the wrapper.
	testing.expect(t, os.make_directory_all(s.layout.bin_dir) == nil)
	testing.expect(t, bridge_setup_write_ctl_wrapper(&s, in_).ok, "install writes the wrapper")
	testing.expect(t, bridge_os_is_executable(wrapper), "wrapper is executable after install")

	// update: the Binaries step swaps in a new bin/ without it; the Service step restores it.
	testing.expect(t, os.remove_all(s.layout.bin_dir) == nil)
	testing.expect(t, os.make_directory_all(s.layout.bin_dir) == nil)
	testing.expect(t, !os.exists(wrapper))
	testing.expect(t, bridge_setup_write_ctl_wrapper(&s, in_).ok, "update writes the wrapper")
	testing.expect(t, bridge_os_is_executable(wrapper), "wrapper is executable after update")
	data, err := os.read_entire_file_from_path(wrapper, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, strings.contains(string(data), "tcp:127.0.0.1:49326"), "wrapper carries this profile's endpoint")
}
