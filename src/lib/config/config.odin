package config

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"

CONFIG_PATH_FLAG :: "--config"

default_config_path :: proc() -> string {
	heimdall_home := os.get_env_alloc("HEIMDALL_HOME", context.allocator)
	if heimdall_home != "" {
		when ODIN_OS == .Windows {
			return strings.concatenate({heimdall_home, "\\config.toml"})
		} else {
			return strings.concatenate({heimdall_home, "/config.toml"})
		}
	}
	when ODIN_OS == .Windows {
		appdata := os.get_env_alloc("APPDATA", context.allocator)
		if appdata != "" do return strings.concatenate({appdata, "\\heimdall\\config.toml"})
		return "heimdall\\config.toml"
	} else when ODIN_OS == .Darwin {
		xdg := os.get_env_alloc("XDG_CONFIG_HOME", context.allocator)
		if xdg != "" do return strings.concatenate({xdg, "/heimdall/config.toml"})
		home := os.get_env_alloc("HOME", context.allocator)
		if home != "" do return strings.concatenate({home, "/.config/heimdall/config.toml"})
		return "config.toml"
	} else {
		xdg := os.get_env_alloc("XDG_CONFIG_HOME", context.allocator)
		if xdg != "" do return strings.concatenate({xdg, "/heimdall/config.toml"})
		home := os.get_env_alloc("HOME", context.allocator)
		if home != "" do return strings.concatenate({home, "/.config/heimdall/config.toml"})
		return "config.toml"
	}
}

Config :: struct {
	daemon: Daemon_Config,
	bridge: Bridge_Config,
	wrapper: Wrapper_Config,
	ctl: Ctl_Config,
}

Bridge_Config :: struct {
	// Nudge/scheduler knobs owned by the bridge (it runs the sweep loop). Parsed
	// from the [bridge] section. nudge_configured is set when any [bridge] nudge
	// key is present, so consumers can prefer these over the legacy [daemon]
	// nudge_* fallback.
	nudge_configured: bool,
	nudge_enabled: bool,
	nudge_interval_seconds: int,
	nudge_ready_after_seconds: int,
	nudge_review_after_seconds: int,
	nudge_working_stale_after_seconds: int,
	nudge_cooldown_seconds: int,
	nudge_restart_grace_seconds: int,
	// Filesystem directory-management sandbox root. All bridge FS browse/stat/mkdir
	// operations are confined to this root (default: $HOME). Parsed from
	// [bridge].fs_root; ~-expanded + symlink-resolved at startup.
	fs_root: string,
	// Default byte chunk size for paginated fs_read_file reads (default: 16_000).
	// Configurable per bridge via [bridge].fs_read_page_bytes or --fs-read-page-bytes.
	fs_read_page_bytes: int,
	// BR-2: drive agents through ham-pty-host instead of tmux. Parsed from
	// [bridge].pty_host_runtime; default false. Also overridable at runtime via
	// the HEIMDALL_BRIDGE_PTY_HOST env var.
	pty_host_runtime: bool,
	// REQ-XM-4: serve the local HTTP proxy entry point on the bridge's local
	// endpoint. ENABLED BY DEFAULT (user decision, 2026-09-21), so this pair
	// follows the nudge_configured idiom rather than a bare bool: the zero value
	// of a bool cannot distinguish "absent" from "explicitly false", and absent
	// must mean enabled. local_proxy_configured is set only when the key is
	// actually present, and only then does local_proxy_enabled override the
	// enabled-by-default.
	local_proxy_configured: bool,
	local_proxy_enabled: bool,
	auto_update_enabled: bool,
	auto_update_configured: bool,
}

Role_Default_Agent_Config :: struct {
	use: string,
	agent_id: string,
}

Daemon_Config :: struct {
	bind_host: string,
	advertise_host: string,
	port: u16,
	data_dir: string,
	daemon_id: string,
	user_id: string,
	namespace: string,
	hub_auth_token: string,
	user_token: string,
	hub_enabled: bool,
	nudge_enabled: bool,
	nudge_interval_seconds: int,
	nudge_ready_after_seconds: int,
	nudge_review_after_seconds: int,
	nudge_need_improvements_after_seconds: int,
	nudge_working_stale_after_seconds: int,
	nudge_cooldown_seconds: int,
	nudge_restart_grace_seconds: int,
	nudge_send_escape_prefix: bool,
	startup_stale_after_seconds: int,
	agent_idle_shutdown_seconds: int, // TODO: remove; idle auto-close disabled
	default_agent_ids: [dynamic]Role_Default_Agent_Config,
	system_agent_ids: []string,
	wrapper_bin: string,
	artifact_max_bytes: int,
	artifact_blob_dir: string,
	bridge_url: string,
	bridge_token: string,
	federation_poll_interval_seconds: int,
	federation_advertised_agent_instance_ids: []string,
}

Wrapper_Config :: struct {
	daemon_url: string,
	credentials_path: string,
	display_name: string,
	requested_access_mode: contracts.Client_Access_Mode,
	tmux_session: string,
	tmux_window_prefix: string,
	agent_run_dir: string,
	use_random_dir: bool,
	project: string,
	memory_templates: []string,
	stop_message: string,
	ham_ctl_bin: string,
}

Startup_Detection_Config :: struct {
	enabled: bool,
	startup_probe_seconds: int,
	capture_interval_ms: int,
	blocked_patterns: []string,
	auto_enter_patterns: []string,
	// Parallel to auto_enter_patterns. Each entry is a tmux send-keys argument
	// dispatched BEFORE the Enter (e.g. "Down" to move selection off the
	// default option). Empty string or missing index = no pre-key, just Enter.
	auto_enter_pre_keys: []string,
	startup_unknown_is_blocked: bool,
	sanitized_reason_mapping: []string,
}

Activity_Detection_Config :: struct {
	enabled: bool,
	sample_line_count: int,
	ignore_bottom_lines: int,
	check_interval_seconds: int,
	min_gap_ms: int,
	max_gap_ms: int,
}

Ctl_Config :: struct {
	daemon_url: string,
}

Load_Result :: struct {
	path: string,
	config: Config,
}

Section :: enum {
	None,
	Daemon,
	Bridge,
	Wrapper,
	Ctl,
}

config_path_from_args :: proc(args: []string) -> string {
	for i in 0..<len(args) {
		if args[i] == CONFIG_PATH_FLAG && i + 1 < len(args) {
			return args[i + 1]
		}
	}

	return default_config_path()
}

load :: proc(path: string) -> (Load_Result, bool) {
	cfg := default_config()
	expanded_path := expand_home(path)
	data, err := os.read_entire_file(expanded_path, context.allocator)
	if err != nil {
		return Load_Result{}, false
	}

	parse_config(string(data), &cfg)
	return Load_Result {
		path = expanded_path,
		config = cfg,
	}, true
}

// home_dir is the user's home directory: $HOME, or on Windows (where HOME is
// usually unset) %USERPROFILE%. "" when neither is known. Caller owns the result.
home_dir :: proc(allocator := context.allocator) -> string {
	home := os.get_env_alloc("HOME", allocator)
	when ODIN_OS == .Windows {
		if home == "" {
			delete(home, allocator)
			home = os.get_env_alloc("USERPROFILE", allocator)
		}
	}
	return home
}

expand_home :: proc(path: string) -> string {
	// Only the "~" case hands `home` itself back; every other path owns a fresh
	// string, so the lookup is freed here instead of leaking on each call.
	home := os.get_env_alloc("HEIMDALL_HOME", context.allocator)
	if home == "" {
		delete(home)
		home = home_dir()
	}
	if path == "~" {
		if home != "" do return home
	}
	defer delete(home)
	if strings.has_prefix(path, "~/") {
		if home != "" do return strings.concatenate({home, "/", path[2:]})
	}
	return path
}

parse_config :: proc(content: string, cfg: ^Config) {
	section := Section.None
	legacy_warned := make([dynamic]string)
	lines := strings.split(content, "\n")

	for raw_line in lines {
		line := strip_comment(raw_line)
		line = strings.trim_space(line)
		if line == "" do continue

		if line == "[daemon]" {
			section = .Daemon
			continue
		}
		if line == "[wrapper]" {
			section = .Wrapper
			continue
		}
		if line == "[bridge]" {
			section = .Bridge
			continue
		}
		if line == "[ctl]" {
			section = .Ctl
			continue
		}

		eq := strings.index_byte(line, '=')
		if eq < 0 do continue

		key := strings.trim_space(line[:eq])
		value := strings.trim_space(line[eq + 1:])
		if legacy_config_key_warned(section, key, &legacy_warned) do continue

		#partial switch section {
		case .Daemon:
			parse_daemon_key(key, value, &cfg.daemon)
		case .Bridge:
			parse_bridge_key(key, value, &cfg.bridge)
		case .Wrapper:
			parse_wrapper_key(key, value, &cfg.wrapper)
		case .Ctl:
			parse_ctl_key(key, value, &cfg.ctl)
		case:
		}
	}
}

legacy_config_key_warned :: proc(section: Section, key: string, warned: ^[dynamic]string) -> bool {
	legacy_key := ""
	#partial switch section {
	case .Wrapper:
		if key == "project" || key == "memory_templates" || key == "default_agent" {
			legacy_key = strings.concatenate({"wrapper.", key})
		}
	case:
	}
	if legacy_key == "" do return false
	for seen in warned^ {
		if seen == legacy_key do return true
	}
	append(warned, strings.clone(legacy_key))
	fmt.fprintf(os.stderr, "WARN deprecated config key ignored: %s\n", legacy_key)
	return true
}

parse_daemon_key :: proc(key, value: string, cfg: ^Daemon_Config) {
	switch key {
	case "bind_host":
		cfg.bind_host = parse_string(value)
	case "advertise_host":
		cfg.advertise_host = parse_string(value)
	case "port":
		if port, ok := strconv.parse_int(value); ok {
			cfg.port = u16(port)
		}
	case "data_dir":
		cfg.data_dir = expand_home(parse_string(value))
	case "daemon_id":
		cfg.daemon_id = parse_string(value)
	case "user_id":
		cfg.user_id = parse_string(value)
	case "namespace":
		cfg.namespace = parse_string(value)
	case "hub_auth_token":
		cfg.hub_auth_token = parse_string(value)
	case "user_token":
		cfg.user_token = parse_string(value)
	case "hub_enabled":
		cfg.hub_enabled = parse_bool(value)
	case "nudge_enabled":
		cfg.nudge_enabled = parse_bool(value)
	case "nudge_interval_seconds":
		if n, ok := strconv.parse_int(value); ok do cfg.nudge_interval_seconds = int(n)
	case "nudge_ready_after_seconds":
		if n, ok := strconv.parse_int(value); ok do cfg.nudge_ready_after_seconds = int(n)
	case "nudge_review_after_seconds":
		if n, ok := strconv.parse_int(value); ok do cfg.nudge_review_after_seconds = int(n)
	case "nudge_need_improvements_after_seconds":
		if n, ok := strconv.parse_int(value); ok do cfg.nudge_need_improvements_after_seconds = int(n)
	case "nudge_working_stale_after_seconds":
		if n, ok := strconv.parse_int(value); ok do cfg.nudge_working_stale_after_seconds = int(n)
	case "nudge_cooldown_seconds":
		if n, ok := strconv.parse_int(value); ok do cfg.nudge_cooldown_seconds = int(n)
	case "nudge_restart_grace_seconds":
		if n, ok := strconv.parse_int(value); ok do cfg.nudge_restart_grace_seconds = int(n)
	case "nudge_send_escape_prefix":
		cfg.nudge_send_escape_prefix = parse_bool(value)
	case "startup_stale_after_seconds":
		if n, ok := strconv.parse_int(value); ok do cfg.startup_stale_after_seconds = int(n)
	case "agent_idle_shutdown_seconds":
		if n, ok := strconv.parse_int(value); ok do cfg.agent_idle_shutdown_seconds = int(n)
	case "team_idle_shutdown_seconds":
		fmt.println("WARN deprecated config key ignored: daemon.team_idle_shutdown_seconds; use agent_idle_shutdown_seconds")
		if n, ok := strconv.parse_int(value); ok do cfg.agent_idle_shutdown_seconds = int(n)
	case "system_agent_ids":
		cfg.system_agent_ids = parse_string_array(value)
	case "wrapper_bin":
		cfg.wrapper_bin = parse_string(value)
	case "artifact_max_bytes":
		if n, ok := strconv.parse_int(value); ok do cfg.artifact_max_bytes = int(n)
	case "artifact_blob_dir":
		cfg.artifact_blob_dir = expand_home(parse_string(value))
	case "bridge_url":
		cfg.bridge_url = parse_string(value)
	case "bridge_token":
		cfg.bridge_token = parse_string(value)
	case "federation_poll_interval_seconds":
		if n, ok := strconv.parse_int(value); ok do cfg.federation_poll_interval_seconds = int(n)
	case "federation_advertised_agent_instance_ids":
		cfg.federation_advertised_agent_instance_ids = parse_string_array(value)
	case:
		if strings.has_prefix(key, "default_agent_id_") {
			default_use := strings.trim_space(key[len("default_agent_id_"):])
			if default_use != "" do daemon_default_agent_id_set(cfg, default_use, parse_string(value))
		}
	}
}

daemon_default_agent_id_set :: proc(cfg: ^Daemon_Config, default_use, agent_id: string) {
	use_key := strings.to_lower(strings.trim_space(default_use))
	if use_key == "" do return
	for existing, idx in cfg.default_agent_ids {
		if existing.use == use_key {
			cfg.default_agent_ids[idx].agent_id = parse_string(agent_id)
			return
		}
	}
	append(&cfg.default_agent_ids, Role_Default_Agent_Config{use = strings.clone(use_key), agent_id = strings.clone(strings.trim_space(agent_id))})
}

// parse_bridge_key parses the [bridge] section. Currently the bridge-owned
// nudge/scheduler knobs live here. Any recognized key marks nudge_configured so
// consumers prefer these over the legacy [daemon] nudge_* fallback.
parse_bridge_key :: proc(key, value: string, cfg: ^Bridge_Config) {
	switch key {
	case "nudge_enabled":
		cfg.nudge_enabled = parse_bool(value); cfg.nudge_configured = true
	case "nudge_interval_seconds":
		if n, ok := strconv.parse_int(value); ok { cfg.nudge_interval_seconds = int(n); cfg.nudge_configured = true }
	case "nudge_ready_after_seconds":
		if n, ok := strconv.parse_int(value); ok { cfg.nudge_ready_after_seconds = int(n); cfg.nudge_configured = true }
	case "nudge_review_after_seconds":
		if n, ok := strconv.parse_int(value); ok { cfg.nudge_review_after_seconds = int(n); cfg.nudge_configured = true }
	case "nudge_working_stale_after_seconds":
		if n, ok := strconv.parse_int(value); ok { cfg.nudge_working_stale_after_seconds = int(n); cfg.nudge_configured = true }
	case "nudge_cooldown_seconds":
		if n, ok := strconv.parse_int(value); ok { cfg.nudge_cooldown_seconds = int(n); cfg.nudge_configured = true }
	case "nudge_restart_grace_seconds":
		if n, ok := strconv.parse_int(value); ok { cfg.nudge_restart_grace_seconds = int(n); cfg.nudge_configured = true }
	case "fs_root":
		cfg.fs_root = parse_string(value)
	case "fs_read_page_bytes":
		if n, ok := strconv.parse_int(value); ok do cfg.fs_read_page_bytes = int(n)
	case "pty_host_runtime":
		cfg.pty_host_runtime = parse_bool(value)
	case "local_proxy_enabled":
		cfg.local_proxy_enabled = parse_bool(value); cfg.local_proxy_configured = true
	case "auto_update_enabled":
		cfg.auto_update_enabled = parse_bool(value); cfg.auto_update_configured = true
	case:
	}
}

parse_wrapper_key :: proc(key, value: string, cfg: ^Wrapper_Config) {
	switch key {
	case "daemon_url":
		cfg.daemon_url = parse_string(value)
	case "credentials_path":
		cfg.credentials_path = expand_home(parse_string(value))
	case "display_name":
		cfg.display_name = parse_string(value)
	case "requested_access_mode":
		cfg.requested_access_mode = parse_access_mode(parse_string(value))
	case "tmux_session":
		cfg.tmux_session = parse_string(value)
	case "tmux_window_prefix":
		cfg.tmux_window_prefix = parse_string(value)
	case "agent_run_dir":
		cfg.agent_run_dir = expand_home(parse_string(value))
	case "use_random_dir":
		cfg.use_random_dir = parse_bool(value)
	case "stop_message":
		cfg.stop_message = parse_string(value)
	case "ham_ctl_bin":
		cfg.ham_ctl_bin = expand_home(parse_string(value))
	case:
	}
}

parse_ctl_key :: proc(key, value: string, cfg: ^Ctl_Config) {
	switch key {
	case "daemon_url":
		cfg.daemon_url = parse_string(value)
	case:
	}
}

parse_bool :: proc(value: string) -> bool {
	v := strings.trim_space(value)
	return v == "true" || v == "True" || v == "1" || v == "yes"
}

parse_string :: proc(value: string) -> string {
	v := strings.trim_space(value)
	if len(v) >= 2 && v[0] == '"' && v[len(v) - 1] == '"' {
		return v[1:len(v) - 1]
	}
	return v
}

parse_string_array :: proc(value: string) -> []string {
	v := strings.trim_space(value)
	if len(v) < 2 || v[0] != '[' || v[len(v) - 1] != ']' {
		return nil
	}

	inner := strings.trim_space(v[1:len(v) - 1])
	if inner == "" do return nil

	parts := split_top_level_commas(inner)
	items := make([]string, len(parts))
	for part, i in parts {
		items[i] = parse_string(part)
	}
	return items
}

// Split on commas that are NOT inside a "..." or '...' string literal. Handles
// backslash escapes inside double-quoted strings so commas in patterns like
// "Yes, I trust this folder" stay grouped.
split_top_level_commas :: proc(s: string) -> []string {
	out: [dynamic]string
	start := 0
	in_dq := false
	in_sq := false
	i := 0
	for i < len(s) {
		ch := s[i]
		if in_dq {
			if ch == '\\' && i + 1 < len(s) { i += 2; continue }
			if ch == '"' do in_dq = false
		} else if in_sq {
			if ch == '\'' do in_sq = false
		} else {
			switch ch {
			case '"':  in_dq = true
			case '\'': in_sq = true
			case ',':
				append(&out, s[start:i])
				start = i + 1
			}
		}
		i += 1
	}
	append(&out, s[start:])
	return out[:]
}

parse_access_mode :: proc(value: string) -> contracts.Client_Access_Mode {
	switch value {
	case "main", "Main":
		return .Main
	case "copy", "Copy":
		return .Copy
	case "read_only", "read-only", "Read_Only":
		return .Read_Only
	case:
		return .Main
	}
}

strip_comment :: proc(line: string) -> string {
	idx := strings.index_byte(line, '#')
	if idx >= 0 {
		return line[:idx]
	}
	return line
}

default_activity_detection_config :: proc() -> Activity_Detection_Config {
	return Activity_Detection_Config{
		enabled = true,
		sample_line_count = 20,
		ignore_bottom_lines = 0,
		check_interval_seconds = 15,
		min_gap_ms = 100,
		max_gap_ms = 500,
	}
}

default_config :: proc() -> Config {
	cfg: Config
	cfg.daemon.bind_host = "127.0.0.1"
	cfg.daemon.advertise_host = ""
	cfg.daemon.port = 49322
	cfg.daemon.data_dir = "~/.local/share/heimdall"
	cfg.daemon.daemon_id = "local-daemon"
	cfg.daemon.user_id = "local-user"
	cfg.daemon.namespace = "default"
	cfg.daemon.hub_auth_token = "local-hub-auth-token"
	cfg.daemon.user_token = "local-user-encryption-token"
	cfg.daemon.hub_enabled = false
	cfg.daemon.nudge_enabled = false
	cfg.daemon.nudge_interval_seconds = 60
	cfg.daemon.nudge_ready_after_seconds = 300
	cfg.daemon.nudge_review_after_seconds = 300
	cfg.daemon.nudge_need_improvements_after_seconds = 300
	cfg.daemon.nudge_working_stale_after_seconds = 900
	cfg.daemon.nudge_cooldown_seconds = 300
	cfg.daemon.nudge_restart_grace_seconds = 60
	cfg.daemon.nudge_send_escape_prefix = false
	cfg.daemon.startup_stale_after_seconds = 120
	cfg.daemon.agent_idle_shutdown_seconds = 1800
	cfg.daemon.default_agent_ids = make([dynamic]Role_Default_Agent_Config)
	daemon_default_agent_id_set(&cfg.daemon, "conversation", "conversation")
	daemon_default_agent_id_set(&cfg.daemon, "guide", "guide")
	daemon_default_agent_id_set(&cfg.daemon, "coordinator", "coordinator")
	daemon_default_agent_id_set(&cfg.daemon, "worker", "worker")
	daemon_default_agent_id_set(&cfg.daemon, "assignee", "worker")
	daemon_default_agent_id_set(&cfg.daemon, "coder", "worker")
	daemon_default_agent_id_set(&cfg.daemon, "tester", "worker")
	daemon_default_agent_id_set(&cfg.daemon, "researcher", "worker")
	daemon_default_agent_id_set(&cfg.daemon, "specialist", "worker")
	daemon_default_agent_id_set(&cfg.daemon, "reviewer", "reviewer")
	cfg.daemon.system_agent_ids = make([]string, 3)
	cfg.daemon.system_agent_ids[0] = "guide"
	cfg.daemon.system_agent_ids[1] = "memory-auditor"
	cfg.daemon.system_agent_ids[2] = "memory-reviewer"
	cfg.daemon.artifact_max_bytes = 50 * 1024 * 1024
	cfg.daemon.artifact_blob_dir = ""
	cfg.daemon.bridge_url = ""
	cfg.daemon.bridge_token = ""
	cfg.daemon.federation_poll_interval_seconds = 10
	cfg.daemon.federation_advertised_agent_instance_ids = nil
	cfg.bridge.fs_read_page_bytes = 16_000

	cfg.wrapper.daemon_url = "http://127.0.0.1:49322"
	cfg.wrapper.credentials_path = "~/.local/share/heimdall/wrapper-credentials.json"
	cfg.wrapper.display_name = "{instance}"
	cfg.wrapper.requested_access_mode = .Main
	cfg.wrapper.tmux_session = "ham-agents"
	cfg.wrapper.tmux_window_prefix = "agent"
	cfg.wrapper.agent_run_dir = ""
	cfg.wrapper.use_random_dir = false
	cfg.wrapper.project = ""
	cfg.wrapper.memory_templates = nil

	cfg.ctl.daemon_url = "http://127.0.0.1:49322"

	return cfg
}
