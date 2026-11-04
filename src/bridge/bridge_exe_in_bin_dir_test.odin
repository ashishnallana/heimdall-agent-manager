package main

import "core:fmt"
import "core:os"
import "core:testing"
import "odin_test:lib/bridgesvc"

// riverwood: /proc/self/exe gave /var/home/u/.local/share/.../bin/ham-bridge while
// the profile layout (from $HOME=/home/u, /home -> var/home) gave /home/u/.../bin,
// so every hub update of a valid profile install was refused. A binary in a
// genuinely different directory must still be refused.
@(test)
test_bridge_exe_in_bin_dir_accepts_linked_home :: proc(t: ^testing.T) {
	tmp, terr := os.temp_directory(context.temp_allocator)
	testing.expect(t, terr == nil)
	root := bridgesvc.pjoin(tmp, fmt.tprintf("ham-exe-bin-%d", os.get_pid()))
	_ = os.remove_all(root)
	defer os.remove_all(root)
	real_bin := bridgesvc.pjoin(root, "var", "home", "u", "bin")
	other_bin := bridgesvc.pjoin(root, "elsewhere", "bin")
	testing.expect(t, os.make_directory_all(real_bin) == nil)
	testing.expect(t, os.make_directory_all(other_bin) == nil)
	exe := bridgesvc.pjoin(real_bin, "ham-bridge")
	testing.expect(t, os.write_entire_file(exe, transmute([]byte)string("x")) == nil)

	testing.expect(t, bridge_exe_in_bin_dir(exe, real_bin))
	testing.expect(t, !bridge_exe_in_bin_dir(exe, other_bin))
	testing.expect(t, !bridge_exe_in_bin_dir("", real_bin))
	testing.expect(t, !bridge_exe_in_bin_dir(exe, ""))

	link_home := bridgesvc.pjoin(root, "home")
	if err := os.symlink(bridgesvc.pjoin(root, "var", "home"), link_home); err != nil {
		fmt.eprintfln("symlink unavailable here (%v); skipping the linked-home case", err)
		return
	}
	testing.expect(t, bridge_exe_in_bin_dir(exe, bridgesvc.pjoin(link_home, "u", "bin")))
	testing.expect(t, !bridge_exe_in_bin_dir(bridgesvc.pjoin(other_bin, "ham-bridge"), bridgesvc.pjoin(link_home, "u", "bin")))
}
