package main

// `ham-bridge tray [--hub URL [--profile P] | --service NAME]`: the bridge-owned
// system tray (REQ-ENR-6). setup installs a login entry for it on desktop sessions
// (bridge_tray_install), uninstall removes it (bridge_tray_remove). The loop polls
// bridge_service_status (exactly what `ham-bridge status --json` prints) every
// BRIDGE_TRAY_POLL and every menu entry runs a ham-bridge command
// (bridgesvc.tray_action_argv). The native menu lives in tray_{linux,darwin,windows}.odin
// behind four procs:
//
//   bridge_tray_native_init(title) -> (ok, why)  show the icon; false = unsupported here
//   bridge_tray_native_update(view, enabled)     status line, icon level, greyed entries
//   bridge_tray_native_pump(wait) -> (action, clicked)  run the UI loop for up to `wait`
//   bridge_tray_native_confirm(text) -> bool     a native yes/no dialog
//   bridge_tray_native_shutdown()
//
// A desktop without a tray host (GNOME without the AppIndicator extension, no
// libayatana) degrades to "no icon": the tray logs why and exits 0, so the login
// entry does not respawn it.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import bridgesvc "odin_test:lib/bridgesvc"

BRIDGE_TRAY_POLL :: 2 * time.Second
BRIDGE_TRAY_TICK :: 100 * time.Millisecond

Bridge_Tray_Enabled :: [bridgesvc.Tray_Action]bool

bridge_tray_command :: proc(args: []string) -> bool {
	host := bridge_service_host()
	name, err := bridge_service_resolve(host, args)
	if name == "" {
		fmt.eprintln("ham-bridge tray:", err)
		return false
	}
	if !bridgesvc.tray_supported(host.os) {
		fmt.eprintln("ham-bridge tray: no desktop tray on this platform")
		return true
	}
	l := bridgesvc.layout_for(host, name)
	tl := bridgesvc.tray_layout(host, l)
	// One tray per profile: a second login (or a manual start) leaves the first.
	if pid, ok := bridge_tray_read_pid(tl.pid_file); ok && pid != os.get_pid() && bridge_os_pid_alive(pid) && bridge_tray_pid_is_tray(pid) {
		fmt.printfln("ham-bridge tray: already running (pid %d)", pid)
		return true
	}
	_ = os.make_directory_all(bridgesvc.pdir(tl.pid_file))
	_ = os.write_entire_file_from_string(tl.pid_file, fmt.tprintf("%d\n", os.get_pid()))
	defer if pid, ok := bridge_tray_read_pid(tl.pid_file); ok && pid == os.get_pid() do _ = os.remove(tl.pid_file)

	self, _ := os.get_executable_path(context.temp_allocator)
	if self == "" do self = tl.exe

	if ok, why := bridge_tray_native_init("Heimdall Bridge"); !ok {
		// Graceful degradation: nothing to show on this desktop; exit 0 so the
		// login entry is not restarted in a loop.
		fmt.eprintfln("ham-bridge tray: no system tray available (%s); the bridge is unaffected", why)
		return true
	}
	defer bridge_tray_native_shutdown()

	children := make([dynamic]os.Process)
	defer delete(children)
	last_state, last_vault := "", ""
	next_poll := time.now()
	status: bridgesvc.Status
	for {
		free_all(context.temp_allocator)
		if time.diff(next_poll, time.now()) >= 0 {
			status = bridge_service_status(host, name)
			next_poll = time.time_add(time.now(), BRIDGE_TRAY_POLL)
			if status.state != last_state || status.vault != last_vault {
				delete(last_state)
				delete(last_vault)
				last_state, last_vault = strings.clone(status.state), strings.clone(status.vault)
				bridge_tray_native_update(bridgesvc.tray_view(status), bridge_tray_enabled(status))
			}
			bridge_tray_reap(&children)
		}
		action, clicked := bridge_tray_native_pump(BRIDGE_TRAY_TICK)
		if !clicked do continue
		if action == .Quit do return true
		// The polled status lives in the temp allocator, freed every tick: act on a fresh one.
		status = bridge_service_status(host, name)
		if action == .Uninstall {
			if !bridge_tray_native_confirm(bridgesvc.TRAY_UNINSTALL_CONFIRM) do continue
			// uninstall removes this tray's login entry and stops it; leave first so
			// nothing holds bin/ open (Windows) while it is deleted.
			_ = bridge_tray_spawn(bridgesvc.tray_action_argv(host, status, self, action), nil)
			return true
		}
		if !bridge_tray_spawn(bridgesvc.tray_action_argv(host, status, self, action), &children) {
			fmt.eprintfln("ham-bridge tray: %s failed to start", bridgesvc.TRAY_ACTION_LABELS[action])
		}
		next_poll = time.now() // reflect a restart / re-enroll quickly
	}
}

bridge_tray_enabled :: proc(s: bridgesvc.Status) -> (e: Bridge_Tray_Enabled) {
	for a in bridgesvc.Tray_Action do e[a] = bridgesvc.tray_action_enabled(a, s)
	return
}

// bridge_tray_spawn starts argv without waiting; children (if given) are reaped
// by the loop so no zombie is left behind.
bridge_tray_spawn :: proc(argv: []string, children: ^[dynamic]os.Process) -> bool {
	if len(argv) == 0 do return false
	p, err := os.process_start(os.Process_Desc{command = argv})
	if err != nil do return false
	// The setup / uninstall callers exit right away; the tray loop reaps its own.
	if children != nil do append(children, p)
	return true
}

bridge_tray_reap :: proc(children: ^[dynamic]os.Process) {
	for i := len(children) - 1; i >= 0; i -= 1 {
		state, err := os.process_wait(children[i], timeout = 0)
		if err == nil && state.exited {
			unordered_remove(children, i)
		}
	}
}

bridge_tray_read_pid :: proc(path: string) -> (pid: int, ok: bool) {
	line := bridgesvc.read_first_line(path)
	if line == "" do return 0, false
	n := 0
	for c in transmute([]u8)line {
		if c < '0' || c > '9' do return 0, false
		n = n * 10 + int(c - '0')
	}
	return n, n > 0
}

// bridge_tray_pid_is_tray: a recorded pid counts only while it is a ham-bridge
// process, so a reused pid is never signalled (same rule as uninstall, F20).
bridge_tray_pid_is_tray :: proc(pid: int) -> bool {
	image, known := bridge_uninstall_pid_image(pid)
	if !known do return true
	return strings.has_prefix(strings.to_lower(image, context.temp_allocator), "ham-bridge")
}

// ---- login entry: installed by setup, removed by uninstall -------------------

bridge_tray_desktop_env :: proc(args: []string) -> bridgesvc.Desktop_Env {
	env :: proc(key: string) -> string {
		v, _ := os.lookup_env(key, context.temp_allocator)
		return v
	}
	return {
		display = env("DISPLAY"), wayland_display = env("WAYLAND_DISPLAY"), session_type = env("XDG_SESSION_TYPE"),
		ssh_connection = env("SSH_CONNECTION"), session_name = env("SESSIONNAME"), no_tray = has_flag(args, "--no-tray"),
	}
}

// bridge_tray_install writes and registers the login entry and starts the tray
// now (setup, desktop sessions only). Never fails setup: the bridge works
// without a tray. message is "skipped" when not wanted.
// force_start: setup stopped a running tray to replace bin/; an update run from
// the (headless) service must still bring it back.
bridge_tray_install :: proc(host: bridgesvc.Host, l: bridgesvc.Layout, args: []string, force_start := false) -> (ok: bool, message: string) {
	if want, why := bridgesvc.tray_wanted(host.os, bridge_tray_desktop_env(args)); !want {
		if force_start {
			_ = bridge_tray_spawn(bridgesvc.tray_argv(host, l), nil)
			return true, "tray restarted"
		}
		return true, fmt.tprintf("skipped (%s)", why)
	}
	tl := bridgesvc.tray_layout(host, l)
	if tl.autostart_file != "" {
		_ = os.make_directory_all(bridgesvc.pdir(tl.autostart_file))
		if err := os.write_entire_file_from_string(tl.autostart_file, bridgesvc.render_tray_autostart(host, l)); err != nil {
			return false, fmt.tprintf("cannot write %s: %v", tl.autostart_file, err)
		}
	}
	// macOS: re-bootstrapping an already loaded agent fails; bootout first so an
	// updated plist is picked up.
	if host.os == .Darwin do for argv in bridgesvc.tray_unregister_argv(host, l) do _, _ = bridge_service_exec(argv)
	for argv in bridgesvc.tray_register_argv(host, l) {
		if rok, out := bridge_service_exec(argv); !rok && host.os == .Windows do return false, fmt.tprintf("%s: %s", argv[0], out)
	}
	// launchd starts it on bootstrap; elsewhere start it now unless it already runs.
	if host.os != .Darwin {
		running := false
		if pid, pok := bridge_tray_read_pid(tl.pid_file); pok && bridge_os_pid_alive(pid) && bridge_tray_pid_is_tray(pid) do running = true
		if !running do _ = bridge_tray_spawn(bridgesvc.tray_argv(host, l), nil)
	}
	return true, "tray installed (starts at login)"
}

// bridge_tray_stop ends a running tray of the profile; true when one was running.
bridge_tray_stop :: proc(host: bridgesvc.Host, l: bridgesvc.Layout) -> bool {
	if !bridgesvc.tray_supported(host.os) do return false
	tl := bridgesvc.tray_layout(host, l)
	pid, pok := bridge_tray_read_pid(tl.pid_file)
	if !pok || pid == os.get_pid() || !bridge_os_pid_alive(pid) || !bridge_tray_pid_is_tray(pid) do return false
	_ = bridge_os_terminate(pid)
	for _ in 0 ..< 20 {
		if !bridge_os_pid_alive(pid) do break
		time.sleep(100 * time.Millisecond)
	}
	if bridge_os_pid_alive(pid) do _ = bridge_os_kill(pid)
	_ = os.remove(tl.pid_file)
	return true
}

// bridge_tray_remove unregisters the login entry, deletes it and stops a running
// tray (uninstall). Idempotent; message is "" when there was no tray.
bridge_tray_remove :: proc(host: bridgesvc.Host, l: bridgesvc.Layout) -> (ok: bool, message: string) {
	if !bridgesvc.tray_supported(host.os) do return true, ""
	tl := bridgesvc.tray_layout(host, l)
	removed := false
	for argv in bridgesvc.tray_unregister_argv(host, l) {
		if rok, _ := bridge_service_exec(argv); rok do removed = true
	}
	if bridge_tray_stop(host, l) do removed = true
	_ = os.remove(tl.pid_file)
	if tl.autostart_file != "" && os.exists(tl.autostart_file) {
		if os.remove(tl.autostart_file) != nil do return false, fmt.tprintf("cannot remove %s", tl.autostart_file)
		removed = true
	}
	return true, "tray removed" if removed else ""
}
