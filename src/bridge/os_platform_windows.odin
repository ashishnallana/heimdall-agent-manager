package main

// Win32 twins of os_platform_unix.odin (same signatures; callers are shared).
//
// Windows has no signals: "terminate" and "kill" both end the process with
// TerminateProcess. File modes do not apply either: the bridge keeps its files
// under the user's profile, whose ACL already restricts them to the owner.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import win "core:sys/windows"

WAIT_TIMEOUT :: 258

bridge_os_terminate :: proc(pid: int) -> bool {
	return bridge_os_kill(pid)
}

bridge_os_kill :: proc(pid: int) -> bool {
	if pid <= 0 do return false
	h := win.OpenProcess(win.PROCESS_TERMINATE, false, u32(pid))
	if h == nil do return false
	defer win.CloseHandle(h)
	return bool(win.TerminateProcess(h, 1))
}

// bridge_os_pid_alive: only "no such process" proves pid gone; a process we may
// not open still exists.
bridge_os_pid_alive :: proc(pid: int) -> bool {
	h := win.OpenProcess(win.SYNCHRONIZE | win.PROCESS_QUERY_LIMITED_INFORMATION, false, u32(pid))
	if h == nil do return win.GetLastError() != win.ERROR_INVALID_PARAMETER
	defer win.CloseHandle(h)
	return win.WaitForSingleObject(h, 0) == WAIT_TIMEOUT
}

// bridge_os_process_lstart_and_command returns pid's creation time and its image
// path (Windows keeps no reliable command line for other processes).
bridge_os_process_lstart_and_command :: proc(pid: int) -> (start_unix_sec: i64, command: string, ok: bool) {
	h := win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, false, u32(pid))
	if h == nil do return 0, "", false
	defer win.CloseHandle(h)
	creation, exit_t, kernel_t, user_t: win.FILETIME
	if !win.GetProcessTimes(h, &creation, &exit_t, &kernel_t, &user_t) do return 0, "", false
	ticks := i64(u64(creation.dwHighDateTime) << 32 | u64(creation.dwLowDateTime))
	// FILETIME counts 100 ns ticks since 1601-01-01.
	start_unix_sec = (ticks - 116444736000000000) / 10_000_000
	buf: [1024]u16
	size := u32(len(buf))
	if !QueryFullProcessImageNameW(h, 0, &buf[0], &size) do return 0, "", false
	image, err := win.utf16_to_utf8(buf[:size], context.temp_allocator)
	if err != nil do return 0, "", false
	return start_unix_sec, image, true
}

// bridge_os_exe_base reduces a command line or image path to a comparable
// executable name: quotes and arguments dropped, directory and ".exe" stripped,
// lower-cased (Windows file names are case-insensitive).
bridge_os_exe_base :: proc(command: string) -> string {
	exe := strings.trim_space(command)
	if strings.has_prefix(exe, "\"") {
		exe = exe[1:]
		if i := strings.index_byte(exe, '"'); i >= 0 do exe = exe[:i]
	} else if i := strings.index(strings.to_lower(exe, context.temp_allocator), ".exe"); i >= 0 {
		exe = exe[:i + 4] // an unquoted path may itself contain spaces
	} else if i := strings.index_byte(exe, ' '); i >= 0 {
		exe = exe[:i]
	}
	if i := strings.last_index_any(exe, "/\\"); i >= 0 do exe = exe[i+1:]
	exe = strings.to_lower(exe, context.temp_allocator)
	return strings.trim_suffix(exe, ".exe")
}

bridge_os_disk_free :: proc(path: string) -> (free_bytes: i64, ok: bool) {
	avail, total, free: win.ULARGE_INTEGER
	wpath := win.utf8_to_wstring(path, context.temp_allocator)
	if !win.GetDiskFreeSpaceExW(wpath, &avail, &total, &free) do return 0, false
	return i64(avail), true
}

bridge_os_hostname :: proc(allocator := context.allocator) -> string {
	buf: [256]u16
	size := u32(len(buf))
	if !GetComputerNameExW(COMPUTER_NAME_DNS_HOSTNAME, &buf[0], &size) do return ""
	name, err := win.utf16_to_utf8(buf[:size], context.temp_allocator)
	if err != nil do return ""
	name = strings.trim_space(name)
	if name == "" do return ""
	return strings.clone(name, allocator)
}

bridge_os_user_name :: proc(allocator := context.allocator) -> string {
	buf: [257]u16
	size := u32(len(buf))
	if !GetUserNameW(&buf[0], &size) || size == 0 do return ""
	name, err := win.utf16_to_utf8(buf[:size - 1], context.temp_allocator) // size counts the NUL
	if err != nil do return ""
	name = strings.trim_space(name)
	if name == "" do return ""
	return strings.clone(name, allocator)
}

// bridge_os_release is the NT version, e.g. "10.0.26200".
bridge_os_release :: proc(allocator := context.allocator) -> string {
	info := win.OSVERSIONINFOEXW{dwOSVersionInfoSize = size_of(win.OSVERSIONINFOEXW)}
	if win.RtlGetVersion(&info) != 0 do return ""
	return fmt.aprintf("%d.%d.%d", info.dwMajorVersion, info.dwMinorVersion, info.dwBuildNumber, allocator = allocator)
}

bridge_os_uid :: proc() -> int {
	return 0
}

bridge_os_make_owner_executable :: proc(path: string) {}

bridge_os_remove_file :: proc(path: string) {
	_ = os.remove(path)
}

bridge_os_create_exclusive :: proc(path, content: string) -> (written: bool, existed: bool) {
	f, err := os.open(path, {.Write, .Create, .Excl})
	if err != nil do return false, os.exists(path)
	defer os.close(f)
	n, werr := os.write(f, transmute([]byte)content)
	return werr == nil && n == len(content), false
}

// bridge_os_socket_file_identity: Windows has no inode to compare, so a daemon
// that re-created its socket is told apart by the file's creation time.
bridge_os_socket_file_identity :: proc(path: string) -> (Pty_Host_Daemon_Identity, bool) {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil do return {}, false
	ns := time.to_unix_nanoseconds(fi.creation_time)
	return Pty_Host_Daemon_Identity{
		ctime_sec  = ns / 1_000_000_000,
		ctime_nsec = ns % 1_000_000_000,
	}, true
}

bridge_os_private_dir_name :: proc() -> string {
	return "heimdall-run"
}

bridge_os_dir_exists :: proc(dir: string) -> bool {
	return os.is_dir(dir)
}

// bridge_os_prepare_private_dir creates dir and rejects anything but a real
// directory (a junction or symlink planted there is refused). Ownership needs no
// check: the parent is the user's own profile temp directory.
bridge_os_prepare_private_dir :: proc(dir: string) -> bool {
	_ = os.make_directory(dir)
	fi, err := os.lstat(dir, context.temp_allocator)
	if err != nil do return false
	return fi.type == .Directory
}

// ---- test-only process helpers (see shell_common.odin) ----

// No process groups on Windows: end the child itself.
bridge_os_test_kill_pid :: proc(pid: int) {
	_ = bridge_os_kill(pid)
}

// Windows children never become group leaders; report presence only.
bridge_os_test_is_own_group_leader :: proc(pid: int) -> (leader: bool, found: bool) {
	return false, bridge_os_pid_alive(pid)
}
