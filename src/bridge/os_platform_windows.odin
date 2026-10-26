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

// ---- executables, PATH and the system shell ----

BRIDGE_PATH_LIST_SEPARATOR :: ';'

// bridge_os_executable_names lists the file names `name` may have on disk: as
// given when it carries an extension, else with each PATHEXT-style extension in
// order. A bare name is not tried -- npm installs an extension-less bash shim
// next to the .cmd one (for Git Bash), and CreateProcess cannot run it.
bridge_os_executable_names :: proc(name: string) -> []string {
	base := name[strings.last_index_any(name, "/\\") + 1:]
	if strings.contains_rune(base, '.') {
		names := make([]string, 1, context.temp_allocator)
		names[0] = name
		return names
	}
	exts := [?]string{".exe", ".cmd", ".bat", ".com"}
	names := make([]string, len(exts), context.temp_allocator)
	for ext, i in exts do names[i] = strings.concatenate({name, ext}, context.temp_allocator)
	return names
}

// bridge_os_path_is_explicit: a value naming a file rather than a PATH lookup.
bridge_os_path_is_explicit :: proc(value: string) -> bool {
	if strings.contains_any(value, "/\\") do return true
	return len(value) >= 2 && value[1] == ':'
}

// bridge_os_default_shell is the interactive shell: PowerShell 7 (pwsh) when it
// is installed, else the Windows PowerShell every Windows ships with.
bridge_os_default_shell :: proc() -> string {
	if pwsh := bridge_runtime_find_on_path("pwsh"); pwsh != "" {
		defer delete(pwsh)
		return strings.clone(pwsh, context.temp_allocator)
	}
	return "powershell.exe"
}

// bridge_os_shell_argv runs a command line through the system shell, cmd.exe.
// /s with /c keeps the caller's command verbatim: cmd strips only the outer
// quotes the argv encoding adds. /d skips AutoRun registry hooks.
bridge_os_shell_argv :: proc(cmd: string) -> []string {
	argv := make([]string, 5, context.temp_allocator)
	argv[0], argv[1], argv[2], argv[3], argv[4] = "cmd.exe", "/d", "/s", "/c", cmd
	return argv
}

// bridge_os_ps renders the process table in the same row format `ps -A -o
// pid=,ppid=,rss=,<cpu>=,args=` prints on Unix, so the parsers stay shared:
// rss is the working set in KiB, cputime is [hh:]mm:ss of user+kernel time,
// %cpu is the lifetime average (as Linux ps reports it), args is the image name
// (Windows keeps no cheap view of another process's command line).
bridge_os_ps :: proc(cpu: Bridge_Ps_Cpu_Column, allocator := context.allocator) -> (output: string, ok: bool) {
	snap := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0)
	if snap == win.INVALID_HANDLE_VALUE do return "", false
	defer win.CloseHandle(snap)
	now_ft: win.FILETIME
	win.GetSystemTimeAsFileTime(&now_ft)
	now_ticks := i64(u64(now_ft.dwHighDateTime) << 32 | u64(now_ft.dwLowDateTime))

	b := strings.builder_make(allocator)
	entry := win.PROCESSENTRY32W{dwSize = size_of(win.PROCESSENTRY32W)}
	for more := win.Process32FirstW(snap, &entry); more; more = win.Process32NextW(snap, &entry) {
		pid := entry.th32ProcessID
		if pid == 0 do continue
		rss_kib: i64
		cpu_secs: f64
		created_ticks: i64
		if h := win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, false, pid); h != nil {
			counters := Process_Memory_Counters{cb = size_of(Process_Memory_Counters)}
			if K32GetProcessMemoryInfo(h, &counters, counters.cb) do rss_kib = i64(counters.WorkingSetSize / 1024)
			c, e, k, u: win.FILETIME
			if win.GetProcessTimes(h, &c, &e, &k, &u) {
				kt := u64(k.dwHighDateTime) << 32 | u64(k.dwLowDateTime)
				ut := u64(u.dwHighDateTime) << 32 | u64(u.dwLowDateTime)
				cpu_secs = f64(kt + ut) / 10_000_000
				created_ticks = i64(u64(c.dwHighDateTime) << 32 | u64(c.dwLowDateTime))
			}
			win.CloseHandle(h)
		}
		name_len := 0
		for name_len < len(entry.szExeFile) && entry.szExeFile[name_len] != 0 do name_len += 1
		name, _ := win.utf16_to_utf8(entry.szExeFile[:name_len], context.temp_allocator)
		cpu_text: string
		switch cpu {
		case .Cputime:
			total := int(cpu_secs)
			cpu_text = fmt.tprintf("%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
		case .Percent:
			wall := f64(now_ticks - created_ticks) / 10_000_000
			pct := cpu_secs / wall * 100 if created_ticks > 0 && wall > 0 else 0
			cpu_text = fmt.tprintf("%.1f", pct)
		}
		fmt.sbprintf(&b, "%d %d %d %s %s\n", pid, entry.th32ParentProcessID, rss_kib, cpu_text, name)
	}
	return strings.to_string(b), true
}

// ---- self-update ----

BRIDGE_EXE_SUFFIX :: ".exe"
BRIDGE_UPDATE_SUPERVISOR_NAME :: "apply-bridge-update.ps1"

// bridge_os_supervisor_argv starts the update supervisor script with the Windows
// PowerShell every Windows ships; the caller appends the script's --flags, which
// the .ps1 parses exactly like the .sh does.
bridge_os_supervisor_argv :: proc(script: string) -> [dynamic]string {
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script)
	return argv
}

// BRIDGE_UPDATE_SPAWN_DETACHES: Windows has no sessions or process groups that
// a service stop would take down with the bridge, so nothing is claimed to the
// supervisor (no --already-detached).
BRIDGE_UPDATE_SPAWN_DETACHES :: false

// bridge_os_spawn_new_session starts argv without waiting for it; the child
// outlives the bridge and is reaped by the OS once the bridge exits.
bridge_os_spawn_new_session :: proc(argv: []string) -> bool {
	if len(argv) == 0 do return false
	process, err := os.process_start(os.Process_Desc{command = argv})
	_ = process
	return err == nil
}

// bridge_os_default_data_dir is %LOCALAPPDATA%\heimdall (per user, not roamed).
bridge_os_default_data_dir :: proc() -> string {
	if local := os.get_env("LOCALAPPDATA", context.temp_allocator); local != "" {
		return strings.concatenate({local, "/heimdall"})
	}
	return bridge_expand_home("~/.local/share/heimdall")
}

// bridge_os_is_executable: Windows has no execute bit (the CRT's _access cannot
// test X_OK); a regular file with an extension CreateProcess or cmd.exe will run
// counts as executable.
bridge_os_is_executable :: proc(path: string) -> bool {
	if !os.is_file(path) do return false
	ext := strings.to_lower(path[max(strings.last_index_byte(path, '.'), 0):], context.temp_allocator)
	return ext == ".exe" || ext == ".cmd" || ext == ".bat" || ext == ".com"
}
