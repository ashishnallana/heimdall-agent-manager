// heimdall: user-facing management CLI for non-hub Heimdall nodes.
// REQ-DIST-2/REQ-DIST-3 (task_18d8becfe6c85dd1): CLI core and lifecycle
// operations. Subcommands: enroll, status, start, stop, restart, logs, doctor,
// update. (The old `vault` group managed a machine-wide key file that nothing
// reads any more; bridges are unsealed per bridge from Settings -> User Vault.)
//
// This binary is the smaller sibling of ham-ctl: it owns only what a plain
// (non-hub) node needs — enrollment against a Hub and local lifecycle of the
// heimdall-bridge user service. It deliberately does not talk to the bridge
// runtime WS; the bridge reads the token file written by `enroll` directly.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import contracts "odin_test:contracts"
import cfg_lib "odin_test:lib/config"
import jsonx "odin_test:lib/jsonx"

// Service identity for the primary bridge, shared with nix/home-manager.nix
// (serviceName/label at nix/home-manager.nix:94) and scripts/install.sh.
MANAGER_SERVICE_UNIT :: "heimdall-bridge"
MANAGER_LAUNCHD_LABEL :: "works.earendil.heimdall-bridge"

// Bridge endpoints (defaults from src/bridge/main.odin: port, and
// src/bridge/hub_runtime_client.odin for the local-endpoint TCP fallback).
MANAGER_LOOPBACK_PORT :: 49323
MANAGER_LOCAL_ENDPOINT_PORT :: 49324

// Token file and data dir conventions (scripts/install.sh writes
// --bridge-token-file %h/.config/heimdall/bridge-token; the bridge default
// data dir is ~/.local/share/heimdall).
MANAGER_TOKEN_FILE_NAME :: "bridge-token"
MANAGER_DEFAULT_DATA_DIR :: "~/.local/share/heimdall"
MANAGER_MACOS_LOG_DIR :: "/tmp/heimdall-logs"

// Interactive probes (status/doctor) use a short timeout so a down Hub does
// not stall the report; enroll keeps the shared 20s default.
MANAGER_PROBE_TIMEOUT_MS :: 5000

main :: proc() {
	args := os.args
	if len(args) <= 1 {
		manager_print_usage()
		return
	}
	command := args[1]
	switch command {
	case "help", "--help", "-h":
		manager_print_usage()
		return
	case "--version", "version":
		fmt.println(manager_version_line())
		return
	case "enroll":
		// `heimdall enroll` drove the deleted one-time-token flow (REQ-ENROLL-9).
		// It is kept as an explicit redirect rather than removed outright: an
		// operator who types it — or a runbook, or an old install script — must be
		// told WHERE enrollment moved, not given "unknown command".
		manager_print_enroll_usage()
		os.exit(1)
	case "status":
		manager_status_command(args)
		return
	case "start", "stop", "restart":
		os.exit(manager_service_verb_command(command, args))
	case "logs":
		if manager_has_flag(args, "--help") || manager_has_flag(args, "-h") {
			manager_print_logs_usage()
			return
		}
		os.exit(manager_logs_command(args))
	case "doctor":
		os.exit(manager_doctor_command(args))
	case "update":
		if manager_has_flag(args, "--help") || manager_has_flag(args, "-h") {
			manager_print_update_usage()
			return
		}
		os.exit(manager_update_command(args))
	case:
		fmt.eprintfln("heimdall: unknown command %q", command)
		manager_print_usage()
		os.exit(2)
	}
}

manager_version_line :: proc() -> string {
	return fmt.tprintf("heimdall %s protocol %d", contracts.APP_VERSION, contracts.PROTOCOL_VERSION)
}

manager_print_usage :: proc() {
	fmt.println(manager_version_line())
	fmt.println("usage: heimdall <command> [options]")
	fmt.println("")
	fmt.println("Manage this machine's Heimdall node: Hub enrollment plus lifecycle of")
	fmt.println("the heimdall-bridge user service.")
	fmt.println("")
	fmt.println("Commands:")
	fmt.println("  enroll    Removed — use 'ham-bridge enroll --hub <url>' (browser-approved)")
	fmt.println("  status    Report enrollment, bridge service, Hub connection and binary versions")
	fmt.println("  start     Start the heimdall-bridge user service")
	fmt.println("  stop      Stop the heimdall-bridge user service")
	fmt.println("  restart   Restart the heimdall-bridge user service")
	fmt.println("  logs      Show bridge service logs ([-n N] [-f|--follow])")
	fmt.println("  doctor    Diagnose this node: ports, permissions, harnesses, service unit")
	fmt.println("  update    Check for and apply in-place binary updates ([--check] [--version <tag>] [--hub <url>])")
	fmt.println("")
	fmt.println("Global options:")
	fmt.println("  --config <path>   config.toml to read/update; default $HEIMDALL_HOME/config.toml,")
	fmt.println("                    else $XDG_CONFIG_HOME/heimdall/config.toml, else ~/.config/heimdall/config.toml")
	fmt.println("")
	fmt.println("Run 'heimdall enroll --help', 'heimdall logs --help' or 'heimdall update --help' for command options.")
}

// manager_print_enroll_usage tells an operator where enrollment went.
//
// It prints to stderr and the caller exits non-zero, because this is a FAILURE:
// the command the user typed did not enroll anything. A script that checked the
// exit status keeps working; one that ignored it sees the reason on stderr.
manager_print_enroll_usage :: proc() {
	fmt.eprintln("heimdall enroll has been replaced by browser-approved enrollment.")
	fmt.eprintln("")
	fmt.eprintln("There is no enrollment token any more. Run this on THIS machine:")
	fmt.eprintln("")
	fmt.eprintln("    ham-bridge enroll --hub <https://your-heimdall-url>")
	fmt.eprintln("")
	fmt.eprintln("It prints a URL and a short code; open the URL, check the code matches,")
	fmt.eprintln("and approve. The bridge receives its credential directly — no secret is")
	fmt.eprintln("copied between machines and none is written into config.toml.")
	fmt.eprintln("")
	fmt.eprintln("Add --headless if this machine has no browser of its own.")
}

manager_print_logs_usage :: proc() {
	fmt.println("usage: heimdall logs [-n <lines>|--lines <lines>] [-f|--follow]")
	fmt.println("")
	fmt.println("Shows the heimdall-bridge service logs (journalctl --user on Linux,")
	fmt.println("~/Library/LaunchAgents logs on macOS). Default: last 200 lines.")
}

// ---- argument helpers (modeled on src/ctl/args.odin, package-private there) ----

manager_has_flag :: proc(args: []string, name: string) -> bool {
	for arg in args {
		if arg == name do return true
	}
	return false
}

manager_option_value :: proc(args: []string, name, fallback: string) -> string {
	for i := 0; i+1 < len(args); i += 1 {
		if args[i] == name do return args[i+1]
	}
	return fallback
}

// manager_first_positional returns the first bare argument after the
// subcommand, skipping known value-flags and their values.
manager_first_positional :: proc(args: []string, value_flags: []string) -> string {
	skip_next := false
	for i := 2; i < len(args); i += 1 {
		arg := args[i]
		if skip_next {
			skip_next = false
			continue
		}
		is_value_flag := false
		for flag in value_flags {
			if arg == flag {
				is_value_flag = true
				break
			}
		}
		if is_value_flag {
			skip_next = true
			continue
		}
		if strings.has_prefix(arg, "-") do continue
		return arg
	}
	return ""
}

// ---- JSON helpers (substring reader matching the Hub's json_string; see
// src/hub/transport/http/bridge_handlers.odin) ----

manager_json_write_string :: proc(builder: ^strings.Builder, value: string) {
	for ch in value {
		switch ch {
		case '\\': strings.write_string(builder, "\\\\")
		case '"': strings.write_string(builder, "\\\"")
		case '\n': strings.write_string(builder, "\\n")
		case '\r': strings.write_string(builder, "\\r")
		case '\t': strings.write_string(builder, "\\t")
		case:
			if ch < 32 {
				strings.write_string(builder, fmt.tprintf("\\u%04x", u32(ch)))
			} else {
				strings.write_rune(builder, ch)
			}
		}
	}
}

// manager_extract_json_string reads the string value of `key` from a JSON
// body. The Hub unescapes the small identity fields this CLI consumes
// (ids, urls, statuses) as plain ASCII, so only the common escapes are
// decoded here.
manager_extract_json_string :: proc(body, key, fallback: string, allocator := context.allocator) -> string {
	return jsonx.extract_string(body, key, fallback, false, allocator)
}

manager_json_unescape :: proc(raw: string, allocator := context.allocator) -> string {
	return jsonx.json_unescape_string(raw, allocator)
}

// ---- subprocess helpers ----

// manager_run_capture executes argv (PATH-resolved, no shell) and returns its
// stdout, stderr and whether the process ran and exited 0.
manager_run_capture :: proc(argv: []string) -> (out: string, err_out: string, ok: bool) {
	if len(argv) == 0 do return "", "", false
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{command = argv}, context.allocator)
	if err != nil {
		if len(stdout) > 0 do delete(stdout)
		if len(stderr) > 0 do delete(stderr)
		return "", "", false
	}
	return string(stdout), string(stderr), state.success
}

// manager_run_inherit runs argv with this process' stdout/stderr so streaming
// output (heimdall logs -f) reaches the terminal live. Returns the child's
// exit code, or 1 when the process could not be started.
manager_run_inherit :: proc(argv: []string) -> int {
	if len(argv) == 0 do return 1
	process, start_err := os.process_start(os.Process_Desc{
		command = argv,
		stdin = os.stdin,
		stdout = os.stdout,
		stderr = os.stderr,
	})
	if start_err != nil do return 1
	state, wait_err := os.process_wait(process)
	if wait_err != nil do return 1
	if state.exited do return state.exit_code
	return 1
}

// ---- filesystem helpers ----

manager_path_exists :: proc(path: string) -> bool {
	if strings.trim_space(path) == "" do return false
	fi, err := os.stat(path, context.allocator)
	if err == nil do os.file_info_delete(fi, context.allocator)
	return err == nil
}

manager_is_dir :: proc(path: string) -> bool {
	fi, err := os.stat(path, context.allocator)
	if err != nil do return false
	defer os.file_info_delete(fi, context.allocator)
	return fi.type == .Directory
}

manager_make_parent_dirs :: proc(path: string) {
	if slash := strings.last_index_byte(path, '/'); slash > 0 {
		_ = os.make_directory_all(path[:slash])
	}
}

manager_dir_of :: proc(path: string) -> string {
	slash := strings.last_index_byte(path, '/')
	if slash > 0 do return path[:slash]
	if slash == 0 do return "/"
	return "."
}

// manager_write_probe verifies `dir` is writable by creating and removing a
// small probe file. Real write access is what enroll (token file) and the
// bridge (data dir) need, so a stat-based check is not enough.
manager_write_probe :: proc(dir: string) -> bool {
	if !manager_is_dir(dir) do return false
	probe := strings.concatenate({strings.trim_right(dir, "/"), "/.heimdall-write-probe"})
	defer delete(probe)
	if os.write_entire_file(probe, "probe") != nil do return false
	_ = os.remove(probe)
	return true
}

// manager_nearest_existing_dir walks up from `path` to the closest directory
// that exists (used to judge whether a data dir can be created at first run).
manager_nearest_existing_dir :: proc(path: string) -> string {
	dir := strings.trim_right(path, "/")
	for strings.trim_space(dir) != "" {
		if manager_is_dir(dir) do return dir
		parent := manager_dir_of(dir)
		if parent == dir do break
		dir = parent
	}
	return ""
}

// manager_bin_on_path resolves a bare command name against $PATH entries
// (modeled on ham-ctl setup's setup_bin_on_path).
manager_bin_on_path :: proc(bin: string) -> (string, bool) {
	if strings.trim_space(bin) == "" do return "", false
	path_env := os.get_env_alloc("PATH", context.allocator)
	if path_env == "" do return "", false
	dirs := strings.split(path_env, ":")
	defer delete(dirs)
	for d in dirs {
		if d == "" do continue
		candidate := strings.concatenate({strings.trim_right(d, "/"), "/", bin})
		if manager_path_exists(candidate) do return candidate, true
	}
	return "", false
}

manager_first_line :: proc(text: string) -> string {
	if newline := strings.index_byte(text, '\n'); newline >= 0 do return text[:newline]
	return text
}

manager_permissions_mode :: proc(perms: os.Permissions) -> int {
	mode := 0
	if .Read_User in perms do mode |= 0o400
	if .Write_User in perms do mode |= 0o200
	if .Execute_User in perms do mode |= 0o100
	if .Read_Group in perms do mode |= 0o040
	if .Write_Group in perms do mode |= 0o020
	if .Execute_Group in perms do mode |= 0o010
	if .Read_Other in perms do mode |= 0o004
	if .Write_Other in perms do mode |= 0o002
	if .Execute_Other in perms do mode |= 0o001
	return mode
}

manager_mode_string :: proc(mode: int) -> string {
	return fmt.tprintf("0%o", mode)
}

// ---- config/token path helpers ----

manager_config_path :: proc(args: []string) -> string {
	path := manager_option_value(args, "--config", "")
	if path == "" do path = cfg_lib.default_config_path()
	return cfg_lib.expand_home(path)
}

manager_token_path :: proc(args: []string, config_path: string) -> string {
	if path := manager_option_value(args, "--token-file", ""); path != "" {
		return cfg_lib.expand_home(path)
	}
	return strings.concatenate({manager_dir_of(config_path), "/", MANAGER_TOKEN_FILE_NAME})
}

manager_read_token_file :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return ""
	return strings.trim_space(string(data))
}

manager_write_token_file :: proc(path, token: string) -> bool {
	if strings.trim_space(path) == "" || strings.trim_space(token) == "" do return false
	manager_make_parent_dirs(path)
	content := strings.concatenate({strings.trim_space(token), "\n"})
	defer delete(content)
	if os.write_entire_file(path, content, os.Permissions{.Read_User, .Write_User}) != nil {
		return false
	}
	// write_entire_file only applies permissions when creating; enforce 0600
	// even when re-enrolling over an existing (possibly too-open) token file.
	return os.chmod(path, os.Permissions{.Read_User, .Write_User}) == nil
}

// ---- platform helpers ----

Manager_Platform :: enum {
	Linux,
	Darwin,
	Unsupported,
}

manager_host_platform :: proc() -> Manager_Platform {
	when ODIN_OS == .Linux {
		return .Linux
	} else when ODIN_OS == .Darwin {
		return .Darwin
	} else {
		return .Unsupported
	}
}

manager_os_string :: proc() -> string {
	when ODIN_OS == .Linux {
		return "linux"
	} else when ODIN_OS == .Darwin {
		return "darwin"
	} else {
		return "unknown"
	}
}

manager_arch_string :: proc() -> string {
	when ODIN_ARCH == .amd64 {
		return "amd64"
	} else when ODIN_ARCH == .arm64 {
		return "arm64"
	} else {
		return "unknown"
	}
}

manager_hostname :: proc() -> string {
	when ODIN_OS == .Linux || ODIN_OS == .Darwin {
		uname: posix.utsname
		if posix.uname(&uname) == 0 {
			name := string(cstring(&uname.nodename[0]))
			if strings.trim_space(name) != "" do return name
		}
	}
	return "unknown-host"
}

// ---- hub URL validation (mirrors ham-bridge enroll) ----

manager_hub_url_supported :: proc(hub_url: string) -> bool {
	trimmed := strings.trim_right(strings.trim_space(hub_url), "/")
	authority := ""
	if strings.has_prefix(trimmed, "http://") {
		authority = trimmed[len("http://"):]
	} else if strings.has_prefix(trimmed, "https://") {
		authority = trimmed[len("https://"):]
	} else {
		return false
	}
	if strings.trim_space(authority) == "" do return false
	if strings.contains(authority, "/") || strings.contains(authority, "?") || strings.contains(authority, "#") do return false
	return true
}

manager_parse_line_number :: proc(value: string, fallback: int) -> int {
	trimmed := strings.trim_space(value)
	if trimmed == "" do return fallback
	if n, ok := strconv.parse_int(trimmed); ok && n > 0 do return int(n)
	return fallback
}
