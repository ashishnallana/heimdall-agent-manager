package main

// `ham-bridge service start|stop|restart|status`, `ham-bridge status [--json]` and
// `ham-bridge list [--json]`: the local lifecycle surface Electron, the tray and
// the installers read. Naming, layout and ports come from odin_test:lib/bridgesvc,
// the one platform-service module; this file only supplies the live Host and runs
// the supervisor argv it returns. None of it needs the rotating bridge token (F22).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import bridgesvc "odin_test:lib/bridgesvc"
import cfg_lib "odin_test:lib/config"
import contracts "odin_test:contracts"

// bridge_service_host describes this machine for bridgesvc (temp-allocated).
bridge_service_host :: proc() -> bridgesvc.Host {
	env :: proc(key: string) -> string {
		v, _ := os.lookup_env(key, context.temp_allocator)
		return v
	}
	host := bridgesvc.Host{home = env("HOME"), uid = bridge_os_uid()}
	when ODIN_OS == .Windows {
		host.os = .Windows
		host.appdata, host.local_appdata = env("APPDATA"), env("LOCALAPPDATA")
		if host.home == "" do host.home = env("USERPROFILE")
	} else when ODIN_OS == .Darwin {
		host.os = .Darwin
	} else {
		host.os = .Linux
		// Termux: no systemd; termux-services (runit) supervises $PREFIX/var/service.
		if prefix := env("PREFIX"); prefix != "" && env("TERMUX_VERSION") != "" {
			host.os, host.prefix = .Termux, prefix
		}
	}
	return host
}

// bridge_service_resolve picks the profile a command acts on: --service NAME,
// else --hub URL [--profile P], else the service this process runs as
// (HEIMDALL_BRIDGE_SERVICE_NAME, set by every rendered service file), else the
// only installed profile. Returns "" with a message when it is ambiguous.
bridge_service_resolve :: proc(host: bridgesvc.Host, args: []string) -> (name: string, err: string) {
	if s := strings.trim_space(option_value(args, "--service", "")); s != "" {
		if !strings.has_prefix(s, bridgesvc.SERVICE_PREFIX) do return "", fmt.tprintf("--service %q is not a heimdall-bridge-* service", s)
		return s, ""
	}
	if hub := strings.trim_space(option_value(args, "--hub", "")); hub != "" {
		profile := strings.trim_space(option_value(args, "--profile", ""))
		p, ok := bridgesvc.profile_from(hub, profile, context.temp_allocator)
		if !ok do return "", fmt.tprintf("invalid --hub %q or --profile %q (profile: [a-z0-9][a-z0-9-]{{0,30}})", hub, profile)
		return p.service_name, ""
	}
	if env, found := os.lookup_env("HEIMDALL_BRIDGE_SERVICE_NAME", context.temp_allocator); found && env != "" {
		env = strings.trim_suffix(env, ".service")
		if strings.has_prefix(env, bridgesvc.SERVICE_PREFIX) do return env, ""
	}
	names := bridgesvc.list_services(host)
	switch len(names) {
	case 0: return "", "no bridge profile is installed for this user (run ham-bridge setup --hub <url>)"
	case 1: return names[0], ""
	}
	return "", fmt.tprintf("%d bridge profiles are installed; pick one with --hub <url> [--profile P] or --service <name> (see ham-bridge list)", len(names))
}

bridge_service_exec :: proc(argv: []string) -> (ok: bool, output: string) {
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{command = argv}, context.temp_allocator)
	out := strings.trim_space(strings.concatenate({string(stdout), string(stderr)}, context.temp_allocator))
	return err == nil && state.success, out
}

// bridge_service_running asks the supervisor whether the service is up.
bridge_service_running :: proc(host: bridgesvc.Host, l: bridgesvc.Layout) -> bool {
	if l.backend == .Schtasks {
		ok, out := bridge_service_exec(bridgesvc.windows_task_state_argv(l))
		return ok && out == "Running"
	}
	argv := bridgesvc.service_argv(host, l, .Status)
	if argv == nil do return false
	ok, out := bridge_service_exec(argv)
	if !ok do return false
	#partial switch l.backend {
	case .Runit:    return strings.has_prefix(out, "run:")
	case .Launchd:  return strings.contains(out, "state = running")
	}
	return true // systemctl is-active exits 0 only when active
}

// bridge_service_action runs start/stop/restart for a resolved service. Windows
// has no restart verb: End, then Run. launchd restarts reload the plist.
bridge_service_action :: proc(host: bridgesvc.Host, name: string, action: bridgesvc.Action) -> (ok: bool, msg: string) {
	l := bridgesvc.layout_for(host, name)
	argv := bridgesvc.service_argv(host, l, action)
	if argv == nil do return false, "no supported service manager on this platform"
	if l.backend == .Launchd && action == .Restart do return bridge_launchd_reload(host, l)
	ok, msg = bridge_service_exec(argv)
	if l.backend == .Schtasks && action == .Restart {
		ok, msg = bridge_service_exec(bridgesvc.service_argv(host, l, .Start))
	}
	// launchd: bootstrap of an already-loaded agent fails; reload it instead.
	if !ok && l.backend == .Launchd && action == .Start do return bridge_launchd_reload(host, l)
	return ok, msg
}

// bridge_launchd_reload restarts a LaunchAgent so launchd re-reads its plist:
// `kickstart -k` only restarts the job definition launchd already loaded, which
// would ignore a re-rendered plist (new ports, PATH, args) until logout. bootout
// returns before the job is fully unloaded, so bootstrap is retried briefly;
// kickstart is the last resort for a job that will not unload.
bridge_launchd_reload :: proc(host: bridgesvc.Host, l: bridgesvc.Layout) -> (ok: bool, msg: string) {
	_, _ = bridge_service_exec(bridgesvc.service_argv(host, l, .Stop))
	for attempt in 0 ..< 10 {
		if attempt > 0 do time.sleep(300 * time.Millisecond)
		ok, msg = bridge_service_exec(bridgesvc.service_argv(host, l, .Start))
		if ok do return
	}
	return bridge_service_exec(bridgesvc.service_argv(host, l, .Restart))
}

// since / stale_pid: see bridgesvc.gather_status (setup's Verify after a restart).
bridge_service_status :: proc(host: bridgesvc.Host, name: string, since: i64 = 0, stale_pid := 0) -> bridgesvc.Status {
	s := bridgesvc.gather_status(host, name, time.now(), since, stale_pid)
	l := bridgesvc.layout_for(host, name)
	if s.installed do s.running = bridge_service_running(host, l)
	if !s.running do s.connected = false
	return s
}

// bridge_service_command: `ham-bridge service <start|stop|restart|status> [...]`.
bridge_service_command :: proc(args: []string) -> bool {
	verb := args[2] if len(args) > 2 else ""
	action: bridgesvc.Action
	switch verb {
	case "start":   action = .Start
	case "stop":    action = .Stop
	case "restart": action = .Restart
	case "status":  action = .Status
	case:
		fmt.eprintln("usage: ham-bridge service start|stop|restart|status [--hub URL [--profile P] | --service NAME] [--json]")
		return false
	}
	host := bridge_service_host()
	name, err := bridge_service_resolve(host, args)
	if name == "" {
		fmt.eprintln("ham-bridge service:", err)
		return false
	}
	if action == .Status do return bridge_status_print(host, name, has_flag(args, "--json"))
	ok, out := bridge_service_action(host, name, action)
	if !ok {
		fmt.eprintfln("ham-bridge service %s %s FAILED: %s", verb, name, out)
		return false
	}
	fmt.printfln("ham-bridge service %s %s: ok", verb, name)
	return true
}

bridge_status_print :: proc(host: bridgesvc.Host, name: string, as_json: bool) -> bool {
	s := bridge_service_status(host, name)
	if as_json {
		fmt.println(bridgesvc.status_json(s, context.temp_allocator))
		return true
	}
	fmt.printfln("service    %s (%s)", s.service, s.backend)
	fmt.printfln("hub        %s", s.hub if s.hub != "" else "-")
	fmt.printfln("profile    %s", s.profile if s.profile != "" else "(default)")
	fmt.printfln("installed  %v  running %v  enrolled %v  connected %v", s.installed, s.running, s.enrolled, s.connected)
	fmt.printfln("vault      %s  version %s  bridge %s", s.vault, s.version if s.version != "" else "-", s.bridge_id if s.bridge_id != "" else "-")
	fmt.printfln("ports      bridge %d  endpoint %d", s.bridge_port, s.endpoint_port)
	return true
}

// bridge_status_command: `ham-bridge status [--json] [--hub URL [--profile P] | --service NAME]`.
bridge_status_command :: proc(args: []string) -> bool {
	host := bridge_service_host()
	name, err := bridge_service_resolve(host, args)
	if name == "" {
		if has_flag(args, "--json") {
			fmt.printfln(`{{"installed":false,"error":%q}}`, err)
			return true
		}
		fmt.eprintln("ham-bridge status:", err)
		return false
	}
	return bridge_status_print(host, name, has_flag(args, "--json"))
}

// bridge_list_command: `ham-bridge list [--json]` — every profile of this OS user.
bridge_list_command :: proc(args: []string) -> bool {
	host := bridge_service_host()
	names := bridgesvc.list_services(host)
	statuses := make([]bridgesvc.Status, len(names), context.temp_allocator)
	for n, i in names do statuses[i] = bridge_service_status(host, n)
	if has_flag(args, "--json") {
		fmt.println(bridgesvc.list_json(statuses, context.temp_allocator))
		return true
	}
	if len(statuses) == 0 do fmt.println("no bridge profiles installed for this user")
	for s in statuses {
		fmt.printfln("%-48s %-36s running=%v connected=%v vault=%s", s.service, s.hub, s.running, s.connected, s.vault)
	}
	return true
}

// ---- runtime status file (written by the running bridge) -------------------

// bridge_local_status_write records connection/vault/version next to this
// bridge's config.toml (the profile state dir), owner-only, so `status --json` can
// report them without the bridge token. Best effort: a failure only makes status
// show "unknown".
bridge_local_status_write :: proc(connected: bool) {
	cfg_path := cfg_lib.expand_home(cfg_lib.config_path_from_args(os.args))
	if cfg_path == "" do return
	dir := bridgesvc.pdir(cfg_path)
	if dir == "" || !os.is_dir(dir) do return
	rt := bridgesvc.Runtime_Status {
		pid        = os.get_pid(),
		connected  = connected,
		vault      = bridge_hub_vault_status_for_report(),
		version    = contracts.APP_VERSION,
		bridge_id  = strings.trim_space(bridge_config.daemon_id),
		updated_at = time.to_unix_seconds(time.now()),
	}
	text := bridgesvc.runtime_status_json(rt, context.temp_allocator)
	final := bridgesvc.pjoin(dir, bridgesvc.RUNTIME_STATUS_FILE)
	tmp := strings.concatenate({final, ".tmp"}, context.temp_allocator)
	if os.write_entire_file_from_string(tmp, text, {.Read_User, .Write_User}) != nil do return
	_ = os.rename(tmp, final)
}

// Pre-profile installs used one fixed service name per OS user.
BRIDGE_LEGACY_SYSTEMD_SERVICE :: "heimdall-bridge"
BRIDGE_LEGACY_LAUNCHD_SERVICE :: "works.earendil.heimdall-bridge"
BRIDGE_LEGACY_RUNIT_SERVICE :: "ham-bridge"

// bridge_enroll_service_for names the registered service an enrollment restarts:
// the profile whose state dir holds --config (installers enroll with
// --config <state_dir>/config.toml), else the --hub [--profile] profile, else the
// service this process runs as, else a legacy fixed-name install. installed is
// false when none of them is registered on this machine.
bridge_enroll_service_for :: proc(host: bridgesvc.Host, args: []string) -> (name: string, installed: bool) {
	candidates := make([dynamic]string, context.temp_allocator)
	if cfg := strings.trim_space(option_value(args, "--config", "")); cfg != "" {
		dir := bridgesvc.pdir(cfg_lib.expand_home(cfg))
		base := dir[strings.last_index_any(dir, "/\\") + 1:]
		if strings.has_prefix(base, bridgesvc.SERVICE_PREFIX) do append(&candidates, base)
	}
	if hub := strings.trim_space(option_value(args, "--hub", "")); hub != "" {
		if p, ok := bridgesvc.profile_from(hub, strings.trim_space(option_value(args, "--profile", "")), context.temp_allocator); ok {
			append(&candidates, p.service_name)
		}
	}
	if env, found := os.lookup_env("HEIMDALL_BRIDGE_SERVICE_NAME", context.temp_allocator); found && env != "" {
		append(&candidates, strings.trim_suffix(env, ".service"))
	}
	switch host.os {
	case .Linux:   append(&candidates, BRIDGE_LEGACY_SYSTEMD_SERVICE)
	case .Darwin:  append(&candidates, BRIDGE_LEGACY_LAUNCHD_SERVICE)
	case .Termux:  append(&candidates, BRIDGE_LEGACY_RUNIT_SERVICE)
	case .Windows:
	}
	for c in candidates {
		if bridge_service_registered(host, c) do return c, true
	}
	return "", false
}

// bridge_service_registered: the supervisor knows this service.
bridge_service_registered :: proc(host: bridgesvc.Host, name: string) -> bool {
	l := bridgesvc.layout_for(host, name)
	if l.backend == .Schtasks {
		ok, _ := bridge_service_exec(bridgesvc.service_argv(host, l, .Status))
		return ok
	}
	return l.service_file != "" && os.exists(l.service_file)
}
