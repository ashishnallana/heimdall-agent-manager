package main

// `ham-bridge setup --hub <url> [--profile P] [--new-bridge|--reuse-bridge ID] [--reenroll]
// [--replace-other-account] [--headless] [--no-tray] [--json-progress]`: install this bridge from the bundle the running
// binary ships in, transactionally (F6, F9). The step order, retry/remediation and
// rollback live in bridgesvc.run_setup; this file supplies the real side effects.
// Every run re-renders the service file and adopts an existing per-Hub install
// (same service name, state and data dirs as install.sh / install.ps1) in place.
// Progress protocol: docs/bridge-setup-progress.md.

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"
import bridgesvc "odin_test:lib/bridgesvc"

// Binaries a release bundle carries next to ham-bridge; only ham-bridge is required.
BRIDGE_SETUP_BINARIES :: [?]string{"ham-bridge", "ham-pty-host", "ham-ctl", "ham-wrapper"}
BRIDGE_SETUP_VERIFY_TIMEOUT :: 45 * time.Second

Bridge_Setup :: struct {
	host:           bridgesvc.Host,
	profile:        bridgesvc.Profile,
	layout:         bridgesvc.Layout,
	args:           []string,
	json_progress:  bool,
	bundle_dir:     string,
	staging:        string,
	lock_path:      string,
	pid:            int,
	// Taken once, by the first Stage run: a remediation that re-stages after
	// stopping the service must not forget that the previous install was running.
	snapshot_taken: bool,
	was_installed:  bool,
	was_running:    bool,
	copy_binaries:  bool,
	// Snapshots for rollback: nil = the file did not exist.
	backups:        map[string]Maybe(string),
	ports:          [2]int,
	enrolled_now:   bool,
	// Set by every (re)start: Verify only trusts runtime status written after it,
	// by a process other than the bridge that was running before.
	restart_at:     i64,
	stale_pid:      int,
	tray_stopped:   bool, // Binaries stopped a running tray; finish restarts it
}

bridge_setup_command :: proc(args: []string) -> bool {
	hub := strings.trim_space(option_value(args, "--hub", ""))
	profile_name := strings.trim_space(option_value(args, "--profile", ""))
	if hub == "" {
		fmt.eprintln("usage: ham-bridge setup --hub <url> [--profile P] [--new-bridge | --reuse-bridge BRIDGE_ID] [--reenroll] [--replace-other-account] [--headless] [--no-tray] [--json-progress]")
		return false
	}
	profile, ok := bridgesvc.profile_from(hub, profile_name, context.temp_allocator)
	if !ok {
		fmt.eprintfln("ham-bridge setup: invalid --hub %q or --profile %q (profile: [a-z0-9][a-z0-9-]{{0,30}})", hub, profile_name)
		return false
	}
	s := Bridge_Setup {
		host          = bridge_service_host(),
		profile       = profile,
		args          = args,
		json_progress = has_flag(args, "--json-progress"),
		pid           = os.get_pid(),
		backups       = make(map[string]Maybe(string), context.temp_allocator),
	}
	s.layout = bridgesvc.layout_for(s.host, profile.service_name)
	if s.layout.backend == .None {
		fmt.eprintln("ham-bridge setup: no supported service manager on this platform")
		return false
	}
	exe, _ := os.get_executable_path(context.temp_allocator)
	if exe == "" && len(os.args) > 0 do exe = os.args[0]
	s.bundle_dir = bridgesvc.pdir(exe)
	s.staging = bridgesvc.pjoin(s.layout.data_dir, ".staging")
	s.lock_path = bridgesvc.pjoin(s.layout.state_dir, bridgesvc.LOCK_FILE)
	s.copy_binaries = strings.trim_right(s.bundle_dir, "/\\") != strings.trim_right(s.layout.bin_dir, "/\\")

	ops := bridgesvc.Setup_Ops {
		data      = &s,
		run       = bridge_setup_run,
		remediate = bridge_setup_remediate,
		undo      = bridge_setup_undo,
		emit      = bridge_setup_emit,
		finish    = bridge_setup_finish,
	}
	done, failed := bridgesvc.run_setup(ops)
	if !done && !s.json_progress {
		fmt.eprintfln("ham-bridge setup FAILED at step %q; the previous install was restored%s.", bridgesvc.STEP_NAMES[failed], " and restarted" if s.was_running else "")
	}
	return done
}

// bridge_setup_enroll_needed: an enrolled profile skips the enroll step, unless
// --new-bridge, --reenroll (re-pair the same bridge, e.g. after its credential was
// revoked), or --reuse-bridge naming another bridge than the current credential's.
bridge_setup_enroll_needed :: proc(args: []string, current_bridge_id: string) -> bool {
	if current_bridge_id == "" || has_flag(args, "--new-bridge") || has_flag(args, "--reenroll") do return true
	reuse := strings.trim_space(option_value(args, "--reuse-bridge", ""))
	return reuse != "" && reuse != current_bridge_id
}

bridge_setup_emit :: proc(data: rawptr, ev: bridgesvc.Event) {
	s := (^Bridge_Setup)(data)
	if s.json_progress {
		fmt.println(bridgesvc.event_json(ev, context.temp_allocator))
		return
	}
	switch ev.state {
	case "start": fmt.printf("[%3d%%] %-10s ...", ev.pct, ev.step)
	case "progress": fmt.printfln("\n        %s", ev.message)
	case "ok", "skipped": fmt.printfln(" %s%s%s", ev.state, " — " if ev.message != "" && ev.message != "skipped" else "", ev.message if ev.message != "skipped" else "")
	case "retry": fmt.printfln(" retry (attempt %d): %s", ev.attempt, ev.message)
	case "failed": fmt.printfln(" FAILED: %s", ev.message)
	case "warning": fmt.printfln(" warning: %s", ev.message)
	case "rollback": fmt.printfln("        rollback %s", ev.step)
	case "done": fmt.printfln("[100%%] %s", ev.message)
	}
}

// ---- snapshots ---------------------------------------------------------------

bridge_setup_backup :: proc(s: ^Bridge_Setup, path: string) {
	if path == "" || path in s.backups do return
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	s.backups[path] = string(data) if err == nil else nil
}

bridge_setup_restore :: proc(s: ^Bridge_Setup, path: string) {
	prev, had := s.backups[path]
	if !had do return
	if text, existed := prev.?; existed {
		_ = os.write_entire_file_from_string(path, text, {.Read_User, .Write_User})
	} else {
		_ = os.remove(path)
	}
}

bridge_setup_port_busy :: proc(port: int) -> bool {
	sock, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = port}, 1)
	if err != nil do return true
	net.close(sock)
	return false
}

bridge_setup_exec_inherit :: proc(argv: []string) -> bool {
	p, err := os.process_start(os.Process_Desc{command = argv, stdin = os.stdin, stdout = os.stdout, stderr = os.stderr})
	if err != nil do return false
	state, werr := os.process_wait(p)
	// core:os on Windows reports success for every exited process (dev-2026-09/10
	// _process_wait sets success = true), so the exit code decides.
	return werr == nil && state.success && state.exit_code == 0
}

// bridge_setup_service_path is the PATH baked into the service. A service
// manager (launchd above all) starts the bridge with a minimal PATH, and setup
// often runs where PATH is just as minimal: the desktop app opened from the
// Dock/Finder, or the .pkg postinstall. Provider CLIs in the user's PATH
// (Homebrew, npm, ~/.local/bin, Nix profiles) were then invisible to the
// bridge. So the service gets, in order and without duplicates: this process's
// PATH, the user's login-shell PATH, then well-known per-user and system bin
// directories that exist. Windows services already see the user's PATH.
bridge_setup_service_path :: proc(current, login_path, home, user: string, exists: proc(path: string) -> bool) -> string {
	seen := make(map[string]bool, 32, context.temp_allocator)
	out := make([dynamic]string, context.temp_allocator)
	add :: proc(seen: ^map[string]bool, out: ^[dynamic]string, dir: string) {
		d := strings.trim_space(dir)
		if d == "" || seen[d] do return
		seen[d] = true
		append(out, d)
	}
	for list in ([]string{current, login_path}) {
		for d in strings.split(list, ":", context.temp_allocator) do add(&seen, &out, d)
	}
	known := make([dynamic]string, context.temp_allocator)
	if home != "" {
		for rel in ([]string{".local/bin", "bin", ".claude/local", ".npm-global/bin", ".bun/bin", ".volta/bin", ".cargo/bin", ".deno/bin", ".nix-profile/bin", ".local/state/nix/profile/bin"}) {
			append(&known, strings.concatenate({home, "/", rel}, context.temp_allocator))
		}
	}
	if user != "" do append(&known, strings.concatenate({"/etc/profiles/per-user/", user, "/bin"}, context.temp_allocator))
	for d in ([]string{"/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/run/current-system/sw/bin", "/nix/var/nix/profiles/default/bin"}) do append(&known, d)
	for d in known do if exists(d) do add(&seen, &out, d)
	for d in ([]string{"/usr/bin", "/bin", "/usr/sbin", "/sbin"}) do add(&seen, &out, d)
	return strings.join(out[:], ":", context.temp_allocator)
}

BRIDGE_SETUP_PATH_MARK :: "__HAM_SETUP_PATH__"

// bridge_setup_login_shell_path asks the user's login shell for its PATH
// (interactive too: zsh users commonly extend PATH in .zshrc). Output around
// the markers is ignored (motd, prompts); any failure or timeout yields "".
bridge_setup_login_shell_path :: proc() -> string {
	shell, _ := os.lookup_env("SHELL", context.temp_allocator)
	if shell == "" || !os.exists(shell) do return ""
	script := "printf '" + BRIDGE_SETUP_PATH_MARK + "%s" + BRIDGE_SETUP_PATH_MARK + "' \"$PATH\""
	stdout, _, ok, _ := bridge_process_run_capture({shell, "-ilc", script}, 5 * time.Second)
	if !ok do return ""
	return bridge_setup_extract_marked_path(stdout)
}

bridge_setup_extract_marked_path :: proc(stdout: string) -> string {
	start := strings.index(stdout, BRIDGE_SETUP_PATH_MARK)
	if start < 0 do return ""
	rest := stdout[start + len(BRIDGE_SETUP_PATH_MARK):]
	end := strings.index(rest, BRIDGE_SETUP_PATH_MARK)
	if end < 0 do return ""
	return strings.clone(rest[:end], context.temp_allocator)
}

bridge_setup_dir_exists :: proc(path: string) -> bool { return os.is_dir(path) }

bridge_setup_render_input :: proc(s: ^Bridge_Setup) -> bridgesvc.Render_Input {
	path, _ := os.lookup_env("PATH", context.temp_allocator)
	when ODIN_OS != .Windows {
		home, _ := os.lookup_env("HOME", context.temp_allocator)
		user, _ := os.lookup_env("USER", context.temp_allocator)
		path = bridge_setup_service_path(path, bridge_setup_login_shell_path(), home, user, bridge_setup_dir_exists)
	}
	tv, _ := os.lookup_env("TERMUX_VERSION", context.temp_allocator)
	return {hub = s.profile.hub_url, profile = s.profile.profile, path_env = path, termux_version = tv, bridge_port = s.ports[0], endpoint_port = s.ports[1]}
}

// ---- steps -------------------------------------------------------------------

bridge_setup_run :: proc(data: rawptr, step: bridgesvc.Step) -> bridgesvc.Step_Result {
	s := (^Bridge_Setup)(data)
	l := s.layout
	switch step {
	case .Lock:
		if err := os.make_directory_all(l.state_dir); err != nil && !os.is_dir(l.state_dir) do return {failure = .Fatal, message = fmt.tprintf("cannot create %s: %v", l.state_dir, err)}
		return bridgesvc.lock_acquire(s.lock_path, s.pid, time.now(), bridge_os_pid_alive)

	case .Stage:
		if !s.snapshot_taken {
			s.snapshot_taken = true
			s.was_installed = bridge_service_registered(s.host, l.service_name)
			s.was_running = s.was_installed && bridge_service_running(s.host, l)
		}
		if !s.copy_binaries do return {ok = true, message = "skipped"}
		if os.exists(s.staging) {
			return {failure = .Partial_Install, message = fmt.tprintf("leftover staging dir %s from an interrupted setup", s.staging)}
		}
		if err := os.make_directory_all(s.staging); err != nil && !os.is_dir(s.staging) do return {failure = .Fatal, message = fmt.tprintf("cannot create %s: %v", s.staging, err)}
		for base in BRIDGE_SETUP_BINARIES {
			name := bridgesvc.exe_name(s.host, base)
			src := bridgesvc.pjoin(s.bundle_dir, name)
			if !os.exists(src) {
				if base == "ham-bridge" do return {failure = .Fatal, message = fmt.tprintf("bundle %s has no %s", s.bundle_dir, name)}
				continue
			}
			dst := bridgesvc.pjoin(s.staging, name)
			if err := os.copy_file(dst, src); err != nil do return {failure = .Partial_Install, message = fmt.tprintf("copy %s: %v", src, err)}
			_ = os.chmod(dst, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})
		}
		return {ok = true, message = fmt.tprintf("staged from %s", s.bundle_dir)}

	case .Binaries:
		if !s.copy_binaries do return {ok = true, message = "skipped"}
		bak := strings.concatenate({l.bin_dir, ".bak"}, context.temp_allocator)
		if os.exists(l.bin_dir) {
			// A running tray executes bin/ham-bridge too. Windows keeps bin/ busy:
			// stop it there; finish starts it again from the new binaries. On
			// Linux/macOS the rename works under it and the tray relaunches itself
			// once it sees the new binary, staying in the user's login session.
			if s.host.os == .Windows && bridge_tray_stop(s.host, l) do s.tray_stopped = true
			_ = os.remove_all(bak)
			if err := os.rename(l.bin_dir, bak); err != nil {
				// Windows: a running bridge keeps its executable's directory busy.
				return {failure = .Stale_Service, message = fmt.tprintf("cannot move %s aside (in use?): %v", l.bin_dir, err)}
			}
		}
		if err := os.rename(s.staging, l.bin_dir); err != nil {
			if os.exists(bak) && !os.exists(l.bin_dir) do _ = os.rename(bak, l.bin_dir)
			return {failure = .Partial_Install, message = fmt.tprintf("cannot install %s: %v", l.bin_dir, err)}
		}
		return {ok = true, message = fmt.tprintf("installed into %s (previous kept as bin.bak)", l.bin_dir)}

	case .Config:
		cfg := bridgesvc.pjoin(l.state_dir, bridgesvc.CONFIG_FILE)
		hub_file := bridgesvc.pjoin(l.state_dir, bridgesvc.HUB_URL_FILE)
		profile_file := bridgesvc.pjoin(l.state_dir, bridgesvc.PROFILE_FILE)
		for p in ([?]string{cfg, hub_file, profile_file}) do bridge_setup_backup(s, p)
		existing := bridgesvc.read_first_line(hub_file)
		if existing == "" do existing = bridgesvc.hub_from_config(cfg)
		if existing != "" {
			if canon, _, ok := bridgesvc.canonical_hub(existing, context.temp_allocator); ok && canon != s.profile.hub_url {
				return {failure = .Fatal, message = fmt.tprintf("%s belongs to hub %s, not %s", l.state_dir, canon, s.profile.hub_url)}
			}
		}
		migrated := "kept"
		if !os.exists(cfg) {
			if os.write_entire_file_from_string(cfg, bridgesvc.default_config_toml(s.profile.hub_url, l.data_dir), {.Read_User, .Write_User}) != nil do return {failure = .Fatal, message = "cannot write config.toml"}
			migrated = "written"
		}
		_ = os.write_entire_file_from_string(hub_file, strings.concatenate({s.profile.hub_url, "\n"}, context.temp_allocator))
		if s.profile.profile != "" do _ = os.write_entire_file_from_string(profile_file, strings.concatenate({s.profile.profile, "\n"}, context.temp_allocator))
		return {ok = true, message = fmt.tprintf("config.toml %s", migrated)}

	case .Ports:
		bridge_setup_backup(s, bridgesvc.pjoin(l.state_dir, bridgesvc.PORTS_FILE))
		// The running bridge holds its own ports; they are free for it after restart.
		busy := bridge_setup_port_busy if !s.was_running else proc(port: int) -> bool {return false}
		ports, reused, ok := bridgesvc.allocate_ports(l.state_root, l.state_dir, busy)
		if !ok do return {failure = .Fatal, message = "no free loopback ports"}
		s.ports = ports
		return {ok = true, message = fmt.tprintf("bridge %d, endpoint %d%s", ports[0], ports[1], " (kept)" if reused else "")}

	case .Service:
		return bridge_setup_register(s)

	case .Enroll:
		token := bridgesvc.pjoin(l.state_dir, bridgesvc.TOKEN_FILE)
		reuse := strings.trim_space(option_value(s.args, "--reuse-bridge", ""))
		current := bridgesvc.credential_bridge_id(bridgesvc.read_first_line(token))
		if !bridge_setup_enroll_needed(s.args, current) do return {ok = true, message = "skipped"}
		// --reenroll keeps this profile's identity: offer the credential's bridge for reuse.
		if reuse == "" && current != "" && !has_flag(s.args, "--new-bridge") do reuse = current
		argv := make([dynamic]string, context.temp_allocator)
		append(&argv, bridgesvc.pjoin(l.bin_dir, bridgesvc.exe_name(s.host, "ham-bridge")), "enroll", "--hub", s.profile.hub_url,
			"--config", bridgesvc.pjoin(l.state_dir, bridgesvc.CONFIG_FILE), "--bridge-token-file", token)
		if has_flag(s.args, "--headless") do append(&argv, "--headless")
		if has_flag(s.args, "--new-bridge") do append(&argv, "--new-bridge")
		if reuse != "" do append(&argv, "--reuse-bridge", reuse)
		// F1: a machine enrolled by another account is replaced only when the
		// caller (the desktop wizard after the user confirmed) says so.
		if has_flag(s.args, "--replace-other-account") do append(&argv, "--replace-other-account")
		if !bridge_setup_exec_inherit(argv[:]) do return {failure = .Fatal, message = "enrollment did not complete"}
		s.enrolled_now = true
		if current != "" do return {ok = true, message = fmt.tprintf("re-enrolled (was %s)", current)}
		return {ok = true, message = "enrolled"}

	case .Extensions:
		return bridge_setup_extensions(s)

	case .Start:
		return bridge_setup_start(s)

	case .Verify:
		deadline := time.time_add(time.now(), BRIDGE_SETUP_VERIFY_TIMEOUT)
		for time.diff(time.now(), deadline) > 0 {
			st := bridge_service_status(s.host, l.service_name, s.restart_at, s.stale_pid)
			if st.running && st.connected do return {ok = true, message = fmt.tprintf("connected to %s (vault %s)", st.hub, st.vault)}
			time.sleep(500 * time.Millisecond)
		}
		st := bridge_service_status(s.host, l.service_name, s.restart_at, s.stale_pid)
		log := bridgesvc.pjoin(l.data_dir, "logs", "bridge.err.log")
		if !st.running {
			if bridge_setup_port_busy(s.ports[0]) do return {failure = .Port_In_Use, message = fmt.tprintf("service is not running and port %d is held by another process", s.ports[0]), log = log}
			return {failure = .Stale_Service, message = "service is not running", log = log}
		}
		return {failure = .Fatal, message = "service runs but did not connect to the hub in time", log = log}
	}
	return {failure = .Fatal, message = "unknown step"}
}

// bridge_setup_extensions installs the bundle's provider extensions into the
// data dir and ensures them for every detected provider, one progress event
// per provider. A provider that still fails after self-healing is reported in
// the step's message but does not roll back the install.
bridge_setup_extensions :: proc(s: ^Bridge_Setup) -> bridgesvc.Step_Result {
	l := s.layout
	src := bridge_extensions_bundle_source(s.bundle_dir)
	copied := "skipped"
	if src != "" {
		ok, msg := bridge_extensions_install_bundle(src, l.data_dir)
		if !ok do return {failure = .Fatal, message = msg}
		copied = msg
	}
	ext_root := bridgesvc.pjoin(l.data_dir, "extensions")
	if !os.is_dir(ext_root) do return {ok = true, message = "skipped"}
	on_line := proc(data: rawptr, line: Bridge_Extension_Sync_Line) {
		bridge_setup_emit(data, bridgesvc.Event{step = "extensions", state = "progress",
			pct = bridgesvc.step_pct(.Extensions, false), message = line.line, attempt = 1})
	}
	lines, failures := bridge_extensions_sync_providers(ext_root, on_line, s)
	installed := 0
	for line in lines do if line.ok && !line.skipped do installed += 1
	msg := fmt.tprintf("%d provider extension(s) ready, %d failed (bundle: %s)", installed, failures, copied)
	return {ok = true, message = msg}
}

// bridge_setup_start (re)starts the service and records what Verify must not
// mistake for the new bridge: the old bridge's runtime-status.json (it has no
// SIGTERM handler, so it never writes connected=false) and anything older.
bridge_setup_start :: proc(s: ^Bridge_Setup) -> bridgesvc.Step_Result {
	l := s.layout
	s.stale_pid = 0
	if rt, ok := bridgesvc.read_runtime_status(l.state_dir); ok do s.stale_pid = rt.pid
	s.restart_at = time.to_unix_seconds(time.now())
	action: bridgesvc.Action = .Restart if bridge_service_running(s.host, l) else .Start
	ok, out := bridge_service_action(s.host, l.service_name, action)
	if !ok do return {failure = .Stale_Service, message = fmt.tprintf("service %s failed: %s", bridgesvc.backend_name(l.backend), out)}
	return {ok = true}
}

// bridge_setup_register renders the service definition and registers it.
bridge_setup_register :: proc(s: ^Bridge_Setup) -> bridgesvc.Step_Result {
	l := s.layout
	in_ := bridge_setup_render_input(s)
	_ = os.make_directory_all(bridgesvc.pjoin(l.data_dir, "logs"))
	_ = os.make_directory_all(bridgesvc.pjoin(l.data_dir, "run"))
	switch l.backend {
	case .None:
		return {failure = .Fatal, message = "no service manager"}
	case .Systemd, .Launchd, .Runit:
		bridge_setup_backup(s, l.service_file)
		_ = os.make_directory_all(bridgesvc.pdir(l.service_file))
		mode: os.Permissions = {.Read_User, .Write_User, .Read_Group, .Read_Other}
		if l.backend == .Runit do mode += {.Execute_User, .Execute_Group, .Execute_Other}
		if err := os.write_entire_file_from_string(l.service_file, bridgesvc.render_service_file(s.host, l, in_), mode); err != nil {
			return {failure = .Fatal, message = fmt.tprintf("cannot write %s: %v", l.service_file, err)}
		}
		if l.backend == .Systemd {
			if ok, out := bridge_service_exec({"systemctl", "--user", "daemon-reload"}); !ok do return {failure = .Stale_Service, message = fmt.tprintf("systemctl daemon-reload: %s", out)}
			_, _ = bridge_service_exec({"systemctl", "--user", "enable", strings.concatenate({l.service_name, ".service"}, context.temp_allocator)})
		}
	case .Schtasks:
		run_cmd := bridgesvc.windows_run_cmd_path(l)
		bridge_setup_backup(s, run_cmd)
		if err := os.write_entire_file_from_string(run_cmd, bridgesvc.render_windows_run_cmd(s.host, l, in_)); err != nil do return {failure = .Fatal, message = fmt.tprintf("cannot write %s: %v", run_cmd, err)}
		xml := bridgesvc.pjoin(l.data_dir, "task.xml")
		_ = os.write_entire_file_from_string(xml, bridgesvc.render_service_file(s.host, l, in_))
		tn := strings.concatenate({"\\", l.service_name}, context.temp_allocator)
		if ok, out := bridge_service_exec({"schtasks", "/Create", "/TN", tn, "/XML", xml, "/F"}); !ok do return {failure = .Stale_Service, message = fmt.tprintf("schtasks /Create: %s", out)}
	}
	return {ok = true, message = fmt.tprintf("%s rendered", bridgesvc.backend_name(l.backend))}
}

// bridge_setup_remediate executes bridgesvc.remediation_plan for a known failure.
bridge_setup_remediate :: proc(data: rawptr, step: bridgesvc.Step, failure: bridgesvc.Failure) -> (bool, string) {
	s := (^Bridge_Setup)(data)
	l := s.layout
	plan := bridgesvc.remediation_plan(step, failure)
	if plan == {} do return false, "no remediation"
	bak := strings.concatenate({l.bin_dir, ".bak"}, context.temp_allocator)
	did := make([dynamic]string, context.temp_allocator)
	for r in plan {
		switch r {
		case .Break_Lock:
			if !bridgesvc.lock_break(s.lock_path) do return false, "cannot remove the dead owner's install lock"
			append(&did, "removed the dead owner's install lock")
		case .Discard_Staging:
			_ = os.remove_all(s.staging)
			if !os.exists(l.bin_dir) && os.exists(bak) do _ = os.rename(bak, l.bin_dir)
			append(&did, "discarded the partial install")
		case .Restage:
			if res := bridge_setup_run(data, .Stage); !res.ok do return false, fmt.tprintf("re-staging failed: %s", res.message)
			append(&did, "re-staged the bundle")
		case .Stop_Service:
			_, _ = bridge_service_action(s.host, l.service_name, .Stop)
			append(&did, "stopped the service")
		case .Reallocate_Ports:
			ports, _, ok := bridgesvc.allocate_ports(l.state_root, l.state_dir, bridge_setup_port_busy)
			if !ok do return false, "no free loopback ports"
			s.ports = ports
			append(&did, fmt.tprintf("moved to ports %d/%d", ports[0], ports[1]))
		case .Register:
			if res := bridge_setup_register(s); !res.ok do return false, fmt.tprintf("re-registering failed: %s", res.message)
			append(&did, "re-rendered and re-registered the service")
		case .Start_Service:
			if res := bridge_setup_start(s); !res.ok do return false, res.message
			append(&did, "started it again")
		}
	}
	return true, strings.join(did[:], ", ", context.temp_allocator)
}

bridge_setup_undo :: proc(data: rawptr, step: bridgesvc.Step) {
	s := (^Bridge_Setup)(data)
	l := s.layout
	switch step {
	case .Lock: // released in finish
	case .Stage:
		_ = os.remove_all(s.staging)
	case .Binaries:
		if !s.copy_binaries do return
		bak := strings.concatenate({l.bin_dir, ".bak"}, context.temp_allocator)
		if os.exists(bak) {
			_, _ = bridge_service_action(s.host, l.service_name, .Stop)
			_ = os.remove_all(l.bin_dir)
			_ = os.rename(bak, l.bin_dir)
		}
	case .Config:
		for p in ([?]string{bridgesvc.CONFIG_FILE, bridgesvc.HUB_URL_FILE, bridgesvc.PROFILE_FILE}) do bridge_setup_restore(s, bridgesvc.pjoin(l.state_dir, p))
	case .Ports:
		bridge_setup_restore(s, bridgesvc.pjoin(l.state_dir, bridgesvc.PORTS_FILE))
	case .Service:
		#partial switch l.backend {
		case .Schtasks:
			bridge_setup_restore(s, bridgesvc.windows_run_cmd_path(l))
			if !s.was_installed do _, _ = bridge_service_exec({"schtasks", "/Delete", "/TN", strings.concatenate({"\\", l.service_name}, context.temp_allocator), "/F"})
		case:
			bridge_setup_restore(s, l.service_file)
			if l.backend == .Systemd do _, _ = bridge_service_exec({"systemctl", "--user", "daemon-reload"})
		}
	case .Extensions:
		// Provider registrations are left as repaired; only the bundle copy is undone.
		bridge_extensions_restore(l.data_dir)
	case .Enroll:
		// An enrollment that completed is kept: the credential is valid for this hub
		// and re-running setup reuses it instead of creating another bridge.
	case .Start, .Verify:
		_, _ = bridge_service_action(s.host, l.service_name, .Stop)
	}
}

bridge_setup_finish :: proc(data: rawptr, ok: bool) {
	s := (^Bridge_Setup)(data)
	if !ok && s.tray_stopped do _ = bridge_tray_spawn(bridgesvc.tray_launch_argv(s.host, s.layout), nil)
	if !ok && s.was_running {
		// Leave the previous install running, as it was before setup.
		_, _ = bridge_service_action(s.host, s.layout.service_name, .Start)
	}
	if ok {
		_ = os.remove_all(s.staging)
		// The tray is a convenience: it is reported, never a reason to roll back.
		bridge_setup_emit(data, bridgesvc.Event{step = "tray", state = "start", pct = 100, attempt = 1})
		tok, msg := bridge_tray_install(s.host, s.layout, s.args, force_start = s.tray_stopped)
		state := "ok" if tok else "warning"
		if tok && strings.has_prefix(msg, "skipped") do state = "skipped"
		bridge_setup_emit(data, bridgesvc.Event{step = "tray", state = state, pct = 100, message = msg, attempt = 1})
	}
	bridgesvc.lock_release(s.lock_path, s.pid)
}
