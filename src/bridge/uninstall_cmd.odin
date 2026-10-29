package main

// `ham-bridge uninstall [--hub URL [--profile P] | --service NAME] [--keep-data | --purge]
// [--json-progress] [--yes]`: remove one bridge profile and every credential and
// secret it holds (F20, REQ-ENR-6). Step order, remediation and reporting live in
// bridgesvc.run_uninstall; this file supplies the side effects. The hub's remote
// uninstall (`bridge_uninstall` frame, bridge_hub_handle_bridge_uninstall) runs the
// same command, detached, with --purge.
//
// The default is --keep-data: logs and agent data stay, everything else (secrets,
// service, binaries, extensions, caches, state) goes. --purge removes the data too.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import bridgesvc "odin_test:lib/bridgesvc"

BRIDGE_UNINSTALL_USAGE :: "usage: ham-bridge uninstall [--hub URL [--profile P] | --service NAME] [--keep-data | --purge] [--json-progress] [--yes]"
// Set on the copy a Windows uninstall re-executes from %TEMP%: a running .exe
// cannot be deleted, so the binary that removes bin/ must not live in it.
BRIDGE_UNINSTALL_RELOCATED_FLAG :: "--relocated"
// The relocated copy waits for this pid (the bin/ ham-bridge.exe that started it)
// to exit before it runs, so nothing in bin/ is still running or locked.
BRIDGE_UNINSTALL_WAIT_PID_FLAG :: "--wait-pid"
BRIDGE_UNINSTALL_PARENT_WAIT :: 30 * time.Second
// Basename prefix of every temp copy uninstall runs from; a relocated run removes
// its own executable only when it carries this prefix.
BRIDGE_UNINSTALL_COPY_PREFIX :: "ham-bridge-uninstall-"
BRIDGE_UNINSTALL_STOP_WAIT :: 10 * time.Second

Bridge_Uninstall :: struct {
	host:          bridgesvc.Host,
	layout:        bridgesvc.Layout,
	json_progress: bool,
	// Read before anything is deleted: the revoke needs the bridge's own token.
	hub:           string,
	bridge_id:     string,
	token:         string,
	token_files:   [dynamic]string,
	config_path:   string,
	bridge_pid:    int,
	leftovers:     [dynamic]string,
}

bridge_uninstall_command :: proc(args: []string) -> bool {
	keep, purge := has_flag(args, "--keep-data"), has_flag(args, "--purge")
	if keep && purge {
		fmt.eprintln("ham-bridge uninstall: --keep-data and --purge are mutually exclusive")
		fmt.eprintln(BRIDGE_UNINSTALL_USAGE)
		return false
	}
	mode: bridgesvc.Uninstall_Mode = .Purge if purge else .Keep_Data
	host := bridge_service_host()
	name, err := bridge_service_resolve(host, args)
	if name == "" {
		fmt.eprintln("ham-bridge uninstall:", err)
		return false
	}
	u := Bridge_Uninstall {
		host          = host,
		layout        = bridgesvc.layout_for(host, name),
		json_progress = has_flag(args, "--json-progress"),
		token_files   = make([dynamic]string, context.temp_allocator),
		leftovers     = make([dynamic]string, context.temp_allocator),
	}
	if !has_flag(args, "--yes") && bridge_stdin_is_terminal(args) && !bridge_uninstall_confirm(name, mode) {
		fmt.println("ham-bridge uninstall: cancelled; nothing was changed")
		return false
	}
	when ODIN_OS == .Windows {
		if relocated, ok := bridge_uninstall_relocate(u.layout, args); relocated do return ok
	}
	relocated := has_flag(args, BRIDGE_UNINSTALL_RELOCATED_FLAG)
	// A temp copy removes itself last, whatever the outcome: --purge leaves no binary.
	defer if relocated do bridge_uninstall_remove_own_copy()
	if wait_pid, ok := bridge_uninstall_wait_pid_arg(args); ok {
		if !bridge_uninstall_wait_pid_exit(wait_pid, bridge_os_pid_alive, BRIDGE_UNINSTALL_PARENT_WAIT) {
			fmt.eprintfln("ham-bridge uninstall: pid %d (the ham-bridge that started this copy) is still running; bin/ may be left behind", wait_pid)
		}
	}
	bridge_uninstall_snapshot(&u)
	ops := bridgesvc.Uninstall_Ops {
		data      = &u,
		run       = bridge_uninstall_run,
		remediate = bridge_uninstall_remediate,
		emit      = bridge_uninstall_emit,
	}
	res := bridgesvc.run_uninstall(ops, mode)
	if !u.json_progress && len(u.leftovers) > 0 {
		fmt.eprintfln("ham-bridge uninstall: could not remove: %s", strings.join(u.leftovers[:], ", ", context.temp_allocator))
	}
	return res.failed == {}
}

bridge_uninstall_confirm :: proc(name: string, mode: bridgesvc.Uninstall_Mode) -> bool {
	fmt.printfln("Uninstall bridge %s? This revokes it on the hub and deletes its credentials, identity and vault key%s.", name, " and ALL its logs and data" if mode == .Purge else " (logs and data are kept)")
	fmt.print("  Continue? [y/N] ")
	if !bridge_stdin_wait_readable(BRIDGE_ENROLL_PROMPT_TIMEOUT_MS) do return false
	buf: [64]byte
	n, rerr := os.read(os.stdin, buf[:])
	if rerr != nil || n <= 0 do return false
	answer := strings.to_lower(strings.trim_space(string(buf[:n])), context.temp_allocator)
	return answer == "y" || answer == "yes"
}

// bridge_uninstall_snapshot reads what later steps need before anything is gone:
// the credential (hub, bridge id, token) and the running bridge's pid.
bridge_uninstall_snapshot :: proc(u: ^Bridge_Uninstall) {
	l := u.layout
	u.config_path = bridgesvc.pjoin(l.state_dir, bridgesvc.CONFIG_FILE)
	profile_token := bridgesvc.pjoin(l.state_dir, bridgesvc.TOKEN_FILE)
	append(&u.token_files, profile_token)
	if data, err := os.read_entire_file(profile_token, context.temp_allocator); err == nil {
		tok, hub, id, owned := bridge_credential_split(string(data))
		if owned do u.hub, u.bridge_id = hub, id
		u.token = tok
	}
	// The config's hub keeps any path prefix the credential header has too.
	if cfg_hub := bridgesvc.hub_from_config(u.config_path); cfg_hub != "" && u.hub == "" do u.hub = cfg_hub
	if u.hub == "" do u.hub = bridgesvc.read_first_line(bridgesvc.pjoin(l.state_dir, bridgesvc.HUB_URL_FILE))
	if rt, ok := bridgesvc.read_runtime_status(l.state_dir); ok {
		// runtime-status.json outlives the bridge (it is only rewritten, never
		// removed on exit), so its pid may have been reused by an unrelated process
		// that Stop must not wait on and remediation must never TERM/KILL.
		image, image_known := bridge_uninstall_pid_image(rt.pid)
		running := bridge_service_registered(u.host, l.service_name) && bridge_service_running(u.host, l)
		if bridge_uninstall_trust_pid(rt.pid, os.get_pid(), running, image, image_known) do u.bridge_pid = rt.pid
		if u.bridge_id == "" do u.bridge_id = rt.bridge_id
	}
	if u.bridge_id == "" {
		if m, ok := bridgesvc.read_reenroll_marker(l.state_dir); ok do u.bridge_id = m.bridge_id
	}
	// A credential enrolled without --bridge-token-file lives at the per-scope default.
	if u.hub != "" && u.bridge_id != "" {
		if p := bridge_enroll_default_credential_path(u.hub, u.bridge_id, context.temp_allocator); p != "" && p != profile_token {
			append(&u.token_files, p)
			if u.token == "" {
				if data, err := os.read_entire_file(p, context.temp_allocator); err == nil {
					u.token, _, _, _ = bridge_credential_split(string(data))
				}
			}
		}
	}
	if u.hub != "" do _ = bridge_keystore_set_hub(u.hub)
}

bridge_uninstall_emit :: proc(data: rawptr, ev: bridgesvc.Event) {
	u := (^Bridge_Uninstall)(data)
	if u.json_progress {
		fmt.println(bridgesvc.event_json(ev, context.temp_allocator))
		return
	}
	switch ev.state {
	case "start":            fmt.printf("[%3d%%] %-10s ...", ev.pct, ev.step)
	case "ok":               fmt.printfln(" ok%s%s", " — " if ev.message != "" else "", ev.message)
	case "skipped":          fmt.printfln(" skipped%s%s", " — " if ev.message != "skipped" else "", ev.message if ev.message != "skipped" else "")
	case "retry":            fmt.printfln(" retry (attempt %d): %s", ev.attempt, ev.message)
	case "warning":          fmt.printfln(" WARNING: %s", ev.message)
	case "failed":
		if ev.step == "uninstall" do fmt.printfln("[100%%] %s", ev.message)
		else do fmt.printfln(" FAILED: %s", ev.message)
	case "done":             fmt.printfln("[100%%] %s", ev.message)
	}
}

// bridge_uninstall_remove deletes paths, recording what survives. busy: something
// is left that a stopped bridge would release (Windows keeps open files locked).
bridge_uninstall_remove :: proc(u: ^Bridge_Uninstall, paths: []string) -> (removed: int, busy: bool, left: string) {
	still := make([dynamic]string, context.temp_allocator)
	for p in paths {
		if p == "" || !os.exists(p) do continue
		_ = os.remove_all(p)
		if os.exists(p) do append(&still, p)
		else do removed += 1
	}
	if len(still) > 0 {
		left = strings.join(still[:], ", ", context.temp_allocator)
		return removed, true, left
	}
	return removed, false, ""
}

bridge_uninstall_run :: proc(data: rawptr, step: bridgesvc.Uninstall_Step) -> (bool, bridgesvc.Uninstall_Failure, string) {
	u := (^Bridge_Uninstall)(data)
	l := u.layout
	paths := bridgesvc.uninstall_paths(l)
	switch step {
	case .Revoke:
		if u.token == "" do return true, .None, "skipped"
		if u.hub == "" do return false, .Fatal, "no hub recorded for this profile; revoke the bridge in Settings -> Devices"
		ok, detail := bridge_self_revoke(u.hub, u.token)
		if ok do return true, .None, fmt.tprintf("bridge %s revoked on %s", u.bridge_id if u.bridge_id != "" else "?", u.hub)
		// No HTTP answer at all: worth retrying. An HTTP error will not change.
		if !strings.has_prefix(detail, "HTTP ") do return false, .Hub_Unreachable, fmt.tprintf("cannot reach %s (%s); revoke %s in Settings -> Devices", u.hub, detail, u.bridge_id)
		return false, .Fatal, fmt.tprintf("hub answered %s; revoke %s in Settings -> Devices", detail, u.bridge_id)

	case .Stop:
		registered := bridge_service_registered(u.host, l.service_name)
		if registered && bridge_service_running(u.host, l) {
			_, _ = bridge_service_action(u.host, l.service_name, .Stop)
		}
		if !bridge_uninstall_wait_stopped(u) do return false, .Still_Running, fmt.tprintf("bridge pid %d is still running", u.bridge_pid)
		if registered && bridge_service_running(u.host, l) do return false, .Still_Running, "the service is still running"
		return true, .None, "stopped" if registered else "skipped"

	case .Unregister:
		files := bridgesvc.unregister_files(l)
		registered := bridge_service_registered(u.host, l.service_name)
		any_file := false
		for f in files do if os.exists(f) do any_file = true
		// Nothing registered and no file left: never touch the user's service manager.
		if !registered && !any_file do return true, .None, "skipped"
		for argv in bridgesvc.unregister_argv(u.host, l) do _, _ = bridge_service_exec(argv)
		if _, busy, left := bridge_uninstall_remove(u, files); busy do return false, .Busy, fmt.tprintf("cannot remove %s", left)
		// systemd: forget the removed unit.
		if l.backend == .Systemd do _, _ = bridge_service_exec({"systemctl", "--user", "daemon-reload"})
		if bridge_service_registered(u.host, l.service_name) do return false, .Busy, fmt.tprintf("%s still registered", l.service_name)
		return true, .None, fmt.tprintf("%s %s removed", bridgesvc.backend_name(l.backend), l.service_name)

	case .Secrets:
		return bridge_uninstall_secrets(u)

	case .Extensions:
		n, busy, left := bridge_uninstall_remove(u, paths.extensions)
		if busy do return false, .Busy, fmt.tprintf("cannot remove %s", left)
		return true, .None, "skipped" if n == 0 else "extensions generation removed"

	case .Caches:
		n, busy, left := bridge_uninstall_remove(u, paths.caches)
		if busy do return false, .Busy, fmt.tprintf("cannot remove %s", left)
		return true, .None, "skipped" if n == 0 else fmt.tprintf("%d cache dir(s) removed", n)

	case .Binaries:
		n, busy, left := bridge_uninstall_remove(u, paths.binaries)
		if busy do return false, .Busy, fmt.tprintf("cannot remove %s", left)
		return true, .None, "skipped" if n == 0 else fmt.tprintf("removed %s", l.bin_dir)

	case .State:
		n, busy, left := bridge_uninstall_remove(u, paths.state)
		if busy do return false, .Busy, fmt.tprintf("cannot remove %s", left)
		return true, .None, "skipped" if n == 0 else fmt.tprintf("removed %s", l.state_dir)

	case .Data:
		n, busy, left := bridge_uninstall_remove(u, paths.data)
		if busy do return false, .Busy, fmt.tprintf("cannot remove %s", left)
		return true, .None, "skipped" if n == 0 else fmt.tprintf("removed %s", l.data_dir)
	}
	return false, .Fatal, "unknown step"
}

// bridge_uninstall_secrets wipes every token file (with its refresh, pending and
// marker siblings), the vault keyring, identity record and epoch floor from the OS
// store (Keychain, Credential Manager, kernel keyring / private files), and the
// per-scope vault directory.
bridge_uninstall_secrets :: proc(u: ^Bridge_Uninstall) -> (bool, bridgesvc.Uninstall_Failure, string) {
	still := make([dynamic]string, context.temp_allocator)
	removed := 0
	for tf in u.token_files {
		existed := os.exists(tf)
		for p in bridge_enroll_wipe_bridge(u.config_path, tf, u.bridge_id) do append(&still, p)
		if existed do removed += 1
	}
	if keystore_bridge_id_is_enrolled(u.bridge_id) && u.hub != "" {
		if scope, ok := keystore_scope_name_for_hub(u.hub, u.bridge_id); ok {
			if dir, dok := bridge_vault_bridge_dir(scope, context.temp_allocator); dok && os.exists(dir) {
				_ = os.remove_all(dir)
				if os.exists(dir) do append(&still, dir)
			}
		}
	}
	if len(still) > 0 {
		for p in still do append(&u.leftovers, p)
		return false, .Busy, fmt.tprintf("could not delete: %s", strings.join(still[:], ", ", context.temp_allocator))
	}
	if u.bridge_id == "" do return true, .None, fmt.tprintf("%d credential file(s) removed (no enrolled bridge id: no keystore items)", removed)
	return true, .None, fmt.tprintf("credentials, identity key, epoch floor and vault key of %s deleted", u.bridge_id)
}

// bridge_uninstall_wait_stopped waits for the bridge process recorded in
// runtime-status.json to exit (the supervisor stop is asynchronous).
bridge_uninstall_wait_stopped :: proc(u: ^Bridge_Uninstall) -> bool {
	if u.bridge_pid <= 0 || u.bridge_pid == os.get_pid() do return true
	deadline := time.time_add(time.now(), BRIDGE_UNINSTALL_STOP_WAIT)
	for bridge_os_pid_alive(u.bridge_pid) {
		if time.diff(time.now(), deadline) <= 0 do return false
		time.sleep(250 * time.Millisecond)
	}
	return true
}

// bridge_uninstall_remediate: stop again, then end a bridge process that ignores
// the supervisor (TERM first, KILL on the second attempt).
bridge_uninstall_remediate :: proc(data: rawptr, step: bridgesvc.Uninstall_Step, failure: bridgesvc.Uninstall_Failure) -> (bool, string) {
	u := (^Bridge_Uninstall)(data)
	if failure == .Hub_Unreachable {
		time.sleep(2 * time.Second)
		return true, "retrying the hub"
	}
	plan := bridgesvc.uninstall_remediation_plan(step, failure)
	if .Stop_Service not_in plan do return false, "no remediation"
	_, _ = bridge_service_action(u.host, u.layout.service_name, .Stop)
	if u.bridge_pid > 0 && u.bridge_pid != os.get_pid() && bridge_os_pid_alive(u.bridge_pid) {
		if bridge_os_terminate(u.bridge_pid) {
			time.sleep(1 * time.Second)
		}
		if bridge_os_pid_alive(u.bridge_pid) do _ = bridge_os_kill(u.bridge_pid)
		return true, fmt.tprintf("stopped the service and ended bridge pid %d", u.bridge_pid)
	}
	time.sleep(500 * time.Millisecond)
	return true, "stopped the service again"
}

// bridge_uninstall_trust_pid decides whether the pid recorded in
// runtime-status.json is this profile's bridge. The process image is checked when
// the OS can tell it (a ham-bridge executable, any name the copies use); when it
// cannot, the pid is trusted only while the service reports running.
bridge_uninstall_trust_pid :: proc(pid, own_pid: int, service_running: bool, image: string, image_known: bool) -> bool {
	if pid <= 0 || pid == own_pid do return false
	if !image_known do return service_running
	base := strings.to_lower(bridgesvc.pbase(strings.trim_space(image)), context.temp_allocator)
	return strings.has_prefix(base, "ham-bridge")
}

// bridge_uninstall_pid_image names the executable running as pid (known=false when
// the pid does not exist or the OS cannot tell). Linux reads /proc/<pid>/comm,
// Windows asks Get-Process, other POSIX systems ask ps.
bridge_uninstall_pid_image :: proc(pid: int) -> (image: string, known: bool) {
	if pid <= 0 do return "", false
	when ODIN_OS == .Linux {
		data, err := os.read_entire_file(fmt.tprintf("/proc/%d/comm", pid), context.temp_allocator)
		if err != nil do return "", false
		image = strings.trim_space(string(data))
		return image, image != ""
	} else {
		argv: []string
		when ODIN_OS == .Windows {
			argv = {"powershell", "-NoProfile", "-NonInteractive", "-Command", fmt.tprintf("(Get-Process -Id %d -ErrorAction Stop).Path", pid)}
		} else {
			argv = {"ps", "-p", fmt.tprintf("%d", pid), "-o", "comm="}
		}
		out, errout, ok, _ := bridge_process_run_capture(argv, 5 * time.Second)
		defer {delete(out); delete(errout)}
		image = strings.clone(strings.trim_space(out), context.temp_allocator)
		return image, ok && image != ""
	}
}

// bridge_uninstall_wait_pid_arg reads --wait-pid N.
bridge_uninstall_wait_pid_arg :: proc(args: []string) -> (pid: int, ok: bool) {
	v := strings.trim_space(option_value(args, BRIDGE_UNINSTALL_WAIT_PID_FLAG, ""))
	if v == "" do return 0, false
	n, nok := strconv.parse_int(v, 10)
	if !nok || n <= 0 do return 0, false
	return n, true
}

// bridge_uninstall_wait_pid_exit waits until alive(pid) is false (true) or the
// timeout passes (false).
bridge_uninstall_wait_pid_exit :: proc(pid: int, alive: proc(pid: int) -> bool, timeout: time.Duration, poll := 100 * time.Millisecond) -> bool {
	deadline := time.time_add(time.now(), timeout)
	for alive(pid) {
		if time.diff(time.now(), deadline) <= 0 do return false
		time.sleep(poll)
	}
	return true
}

// bridge_uninstall_relocated_argv: argv for the temp copy that carries on an
// uninstall started from bin/. The user already confirmed (--yes), the copy names
// the profile by service (it may not resolve --hub the same way from %TEMP%) and
// waits for parent_pid to exit before touching anything.
bridge_uninstall_relocated_argv :: proc(copy_path: string, args: []string, service_name: string, parent_pid: int) -> []string {
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, copy_path)
	for a in args[1:] do append(&argv, a)
	if !has_flag(args, "--service") do append(&argv, "--service", service_name)
	if !has_flag(args, "--yes") do append(&argv, "--yes")
	append(&argv, BRIDGE_UNINSTALL_RELOCATED_FLAG, BRIDGE_UNINSTALL_WAIT_PID_FLAG, fmt.tprintf("%d", parent_pid))
	return argv[:]
}

// bridge_uninstall_relocate (Windows): when this ham-bridge.exe lives in the bin/
// being removed, copy it to %TEMP%, start the copy on this console and exit at
// once: a running .exe is locked, so bin\ham-bridge.exe can only be deleted after
// this process is gone, which the copy waits for (--wait-pid). relocated=false
// means "carry on in this process".
bridge_uninstall_relocate :: proc(l: bridgesvc.Layout, args: []string) -> (relocated: bool, ok: bool) {
	if has_flag(args, BRIDGE_UNINSTALL_RELOCATED_FLAG) do return false, false
	exe, _ := os.get_executable_path(context.temp_allocator)
	bin := strings.to_lower(strings.trim_right(l.bin_dir, "/\\"), context.temp_allocator)
	exe_dir := strings.to_lower(bridgesvc.pdir(exe), context.temp_allocator)
	same, _ := strings.replace_all(exe_dir, "\\", "/", context.temp_allocator)
	want, _ := strings.replace_all(bin, "\\", "/", context.temp_allocator)
	if exe == "" || same != want do return false, false
	tmp, _ := os.lookup_env("TEMP", context.temp_allocator)
	if tmp == "" do return false, false
	copy_path := bridgesvc.pjoin(tmp, fmt.tprintf("%s%d.exe", BRIDGE_UNINSTALL_COPY_PREFIX, os.get_pid()))
	if os.copy_file(copy_path, exe) != nil do return false, false
	argv := bridge_uninstall_relocated_argv(copy_path, args, l.service_name, os.get_pid())
	// Same console, no stdin: the copy prints its progress here after we exit.
	p, err := os.process_start(os.Process_Desc{command = argv, stdout = os.stdout, stderr = os.stderr})
	if err != nil {
		_ = os.remove(copy_path)
		fmt.eprintfln("ham-bridge uninstall: cannot start %s (%v); uninstalling in place, bin/ may be left behind", copy_path, err)
		return false, false
	}
	_ = p
	fmt.println("ham-bridge uninstall: continuing from a temporary copy so bin/ can be removed; its progress follows")
	return true, true
}

// bridge_uninstall_remove_own_copy deletes the temp copy this relocated run
// executes from. POSIX unlinks a running executable; Windows cannot, so a hidden
// PowerShell deletes it a few seconds after this process exits.
bridge_uninstall_remove_own_copy :: proc() {
	exe, _ := os.get_executable_path(context.temp_allocator)
	if exe == "" || !strings.has_prefix(bridgesvc.pbase(exe), BRIDGE_UNINSTALL_COPY_PREFIX) do return
	when ODIN_OS == .Windows {
		_ = bridge_os_spawn_new_session(bridge_uninstall_delayed_delete_argv(exe))
	} else {
		_ = os.remove(exe)
	}
}

// bridge_uninstall_delayed_delete_argv: PowerShell that waits, then deletes path
// (single quotes doubled for the -LiteralPath string).
bridge_uninstall_delayed_delete_argv :: proc(path: string) -> []string {
	quoted, _ := strings.replace_all(path, "'", "''", context.temp_allocator)
	argv := make([]string, 7, context.temp_allocator)
	argv[0], argv[1], argv[2], argv[3], argv[4], argv[5] = "powershell", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command"
	argv[6] = fmt.tprintf("Start-Sleep -Seconds 3; Remove-Item -LiteralPath '%s' -Force -ErrorAction SilentlyContinue", quoted)
	return argv
}

// bridge_uninstall_spawn_detached starts `ham-bridge uninstall` for this
// process's own profile in a session of its own, from a copy of the executable
// outside bin/, so it survives the service stop it performs (KillMode=process,
// AbandonProcessGroup, Scheduled Task End only ends the bridge itself). Used by
// the hub's remote uninstall.
bridge_uninstall_spawn_detached :: proc(service_name: string, purge: bool) -> (ok: bool, detail: string) {
	exe, _ := os.get_executable_path(context.temp_allocator)
	if exe == "" do return false, "cannot resolve the bridge executable"
	tmp_dir := ""
	when ODIN_OS == .Windows {
		tmp_dir, _ = os.lookup_env("TEMP", context.temp_allocator)
	} else {
		tmp_dir, _ = os.lookup_env("TMPDIR", context.temp_allocator)
		if tmp_dir == "" do tmp_dir = "/tmp"
	}
	copy_path := bridgesvc.pjoin(tmp_dir, fmt.tprintf("%s%d%s", BRIDGE_UNINSTALL_COPY_PREFIX, os.get_pid(), BRIDGE_EXE_SUFFIX))
	if err := os.copy_file(copy_path, exe); err != nil do return false, fmt.tprintf("cannot copy %s: %v", exe, err)
	_ = os.chmod(copy_path, {.Read_User, .Write_User, .Execute_User})
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, copy_path, "uninstall", "--purge" if purge else "--keep-data", "--yes", "--headless", "--json-progress", "--service", service_name, BRIDGE_UNINSTALL_RELOCATED_FLAG)
	if !bridge_os_spawn_new_session(argv[:]) do return false, "cannot start the detached uninstall"
	return true, ""
}
