package main

import "core:os"
import "core:strings"
import win "core:sys/windows"

// Retained loaded images keep their original path after a binary directory
// rename. Discover old account sockets only through this profile's own images.
bridge_uninstall_discover_pty_hosts :: proc(u: ^Bridge_Uninstall) -> (bool, string) {
	pids, err := os.process_list(context.temp_allocator)
	if err != nil do return false, "cannot discover this profile's retained PTY daemons"
	for pid in pids {
		process, open_error := os.process_open(pid, {.Mem_Read})
		if open_error != nil do continue
		defer win.CloseHandle(win.HANDLE(process.handle))
		// Bind both image and arguments to this handle; the core Executable_Path
		// field uses a separate PID lookup and cannot establish that guarantee.
		_, image, known := bridge_os_process_identity_handle(win.HANDLE(process.handle))
		if !known || !bridge_uninstall_pty_image_owned(u.layout, image) do continue
		// This Odin version enters its PEB reader only when all three base
		// fields are selected; Command_Args alone does not read the command.
		info, _ := os.process_info_by_handle(process, {.Command_Line, .Command_Args, .Environment, .Working_Dir}, context.temp_allocator)
		defer os.free_process_info(info, context.temp_allocator)
		if .Command_Args not_in info.fields do return false, "cannot inspect the selected profile's retained PTY daemon arguments"
		daemon := false
		for arg in info.command_args do if arg == "daemon" do daemon = true
		if !daemon do continue
		for arg, i in info.command_args {
			if arg == "--socket" && i+1 < len(info.command_args) {
				append(&u.pty_sockets, strings.clone(info.command_args[i+1], context.temp_allocator))
				break
			}
		}
	}
	return true, ""
}
