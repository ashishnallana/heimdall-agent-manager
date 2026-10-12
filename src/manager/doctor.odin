// heimdall doctor: read-only diagnostics for this node. Verifies the pieces
// that must line up for the heimdall-bridge service to run: enrollment files,
// filesystem permissions, the loopback endpoint (:49323), the local endpoint
// port (:49324), the service unit (including any hub URL baked into it, which
// would override the hub in the config the unit loads at bridge startup), and
// the coding harnesses the bridge can launch. Exits 1 iff any check FAILs;
// warnings never fail the run.
package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import http "odin_test:lib/http_client"
import cfg_lib "odin_test:lib/config"

Manager_Check_Status :: enum {
	Ok,
	Warn,
	Fail,
}

Manager_Check :: struct {
	name:   string,
	status: Manager_Check_Status,
	detail: string,
}

Manager_Loopback_Probe :: enum {
	Not_Listening,
	Heimdall_Ok,
	Heimdall_Unauthorized,
	Heimdall_Responding,
	Other_Service,
}

Manager_Harness :: struct {
	name: string, // harness label, as reported by ham-ctl setup
	bin:  string, // command to detect on PATH
}

// The harness set mirrors ham-ctl setup (src/ctl/setup.odin): the companions a
// bridge can launch.
MANAGER_DOCTOR_HARNESSES :: []Manager_Harness {
	{name = "pi", bin = "pi"},
	{name = "antigravity", bin = "agy"},
	{name = "claude", bin = "claude"},
	{name = "codex", bin = "codex"},
}

manager_tcp_probe :: proc(port: int) -> bool {
	socket, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = port})
	if err != nil do return false
	net.close(socket)
	return true
}

// manager_probe_bridge_loopback probes the given loopback port and, when the
// port answers, asks /bridge/health who is listening. Returns the
// classification and a short human-readable detail for the report.
manager_probe_bridge_loopback :: proc(port: int, token: string) -> (Manager_Loopback_Probe, string) {
	if !manager_tcp_probe(port) {
		return .Not_Listening, "not listening"
	}
	base_url := fmt.tprintf("http://127.0.0.1:%d", port)
	resp: http.Response
	ok: bool
	if strings.trim_space(token) != "" {
		headers := [?]http.Header{{name = "Authorization", value = strings.concatenate({"Bearer ", token})}}
		resp, ok = http.request_with_headers_timeout("GET", base_url, "/bridge/health", "", headers[:], MANAGER_PROBE_TIMEOUT_MS)
	} else {
		resp, ok = http.request_with_timeout("GET", base_url, "/bridge/health", "", MANAGER_PROBE_TIMEOUT_MS)
	}
	probe := manager_classify_loopback_probe(true, ok, resp.status, resp.body)
	switch probe {
	case .Heimdall_Ok:
		return probe, strings.concatenate({"healthy (", manager_health_summary(resp.body), ")"})
	case .Heimdall_Unauthorized:
		return probe, fmt.tprintf("heimdall bridge responding (HTTP %d, token required)", resp.status)
	case .Heimdall_Responding:
		return probe, fmt.tprintf("heimdall bridge responding (HTTP %d)", resp.status)
	case .Other_Service:
		if !ok do return probe, "port open but not an HTTP service"
		return probe, fmt.tprintf("HTTP %d from a non-heimdall service", resp.status)
	case .Not_Listening:
		return probe, "not listening"
	}
	return probe, ""
}

manager_classify_loopback_probe :: proc(port_open, http_ok: bool, status: int, body: string) -> Manager_Loopback_Probe {
	if !port_open do return .Not_Listening
	if !http_ok do return .Other_Service
	if status == 200 && strings.contains(body, "\"ok\":true") do return .Heimdall_Ok
	if status == 401 || strings.contains(body, "bridge loopback unauthorized") do return .Heimdall_Unauthorized
	if strings.contains(body, "contract_version") || strings.contains(body, "unsupported_route") do return .Heimdall_Responding
	return .Other_Service
}

manager_health_summary :: proc(body: string) -> string {
	contract := manager_extract_json_string(body, "contract_version", "")
	frame := manager_extract_json_string(body, "ws_frame_version", "")
	if contract == "" do return "ok"
	return fmt.tprintf("contract %s, ws frame %s", contract, frame)
}

// manager_unit_contents returns the installed service definition (Linux: the
// systemd user unit as `systemctl --user cat` resolves it, so nix-store
// symlinked units read correctly; Darwin: the LaunchAgent plist). The returned
// string is owned by the caller.
manager_unit_contents :: proc(platform: Manager_Platform, unit, plist_path: string) -> (string, bool) {
	switch platform {
	case .Linux:
		out, err_out, ok := manager_run_capture({"systemctl", "--user", "cat", unit})
		if len(err_out) > 0 do delete(err_out)
		if !ok {
			if len(out) > 0 do delete(out)
			return "", false
		}
		return out, true
	case .Darwin:
		data, err := os.read_entire_file(plist_path, context.allocator)
		if err != nil do return "", false
		return string(data), true
	case .Unsupported:
		return "", false
	}
	return "", false
}

// manager_unit_present reports whether the service manager knows the unit
// (systemd) or the LaunchAgent plist is installed.
manager_unit_present :: proc(platform: Manager_Platform, unit, plist_path: string) -> bool {
	content, ok := manager_unit_contents(platform, unit, plist_path)
	if ok && len(content) > 0 do delete(content)
	return ok
}

// ---- installed-unit flag extraction (REQ-INST-9) ----
//
// A unit may bake flags into its command line. Because the bridge applies
// --hub/--daemon-url on top of the config it loads (src/bridge/main.odin:301-302)
// and picks that config from --config (main.odin:256-257, config.odin:226),
// a stale or placeholder flag silently overrides what `heimdall enroll` wrote
// into the config the unit reads. The parsers below extract the flags the
// service definition actually passes; manager_unit_hub_check compares them
// against the config the unit would load. Parsing works on slices of the unit
// text, so it allocates nothing.

Manager_Unit_Flags :: struct {
	hub:          string,
	hub_found:    bool,
	daemon:       string,
	daemon_found: bool,
	config:       string,
	config_found: bool,
}

// manager_unit_flags extracts the command-line flags a service definition
// passes: Linux reads the systemd ExecStart, Darwin the LaunchAgent
// ProgramArguments. The returned slices alias `text`.
manager_unit_flags :: proc(text: string, platform: Manager_Platform) -> Manager_Unit_Flags {
	switch platform {
	case .Linux:
		return manager_systemd_unit_flags(text)
	case .Darwin:
		return manager_plist_unit_flags(text)
	case .Unsupported:
		return {}
	}
	return {}
}

// manager_systemd_unit_flags scans the unit's ExecStart command lines. systemd
// joins a line ending in a backslash with the following line (the form
// scripts/install.sh:110-115 renders), so continuation lines keep feeding the
// same command line.
manager_systemd_unit_flags :: proc(text: string) -> Manager_Unit_Flags {
	flags: Manager_Unit_Flags
	body := text
	in_exec := false
	for raw_line in strings.split_lines_iterator(&body) {
		line, continues := manager_strip_line_continuation(raw_line)
		if in_exec {
			manager_scan_unit_tokens(line, &flags)
		} else {
			trimmed := strings.trim_left(line, " \t")
			if strings.has_prefix(trimmed, "ExecStart=") {
				manager_scan_unit_tokens(trimmed[len("ExecStart="):], &flags)
				in_exec = true
			}
		}
		in_exec = in_exec && continues
	}
	return flags
}

// manager_plist_unit_flags scans the plist ProgramArguments array only: the
// bridge argv lives there (scripts/install.sh:138-149), while values under
// other keys must never be mistaken for command-line flags.
manager_plist_unit_flags :: proc(text: string) -> Manager_Unit_Flags {
	array_key := "<key>ProgramArguments</key>"
	key := strings.index(text, array_key)
	if key < 0 do return {}
	rest := text[key + len(array_key):]
	array_open := strings.index(rest, "<array>")
	if array_open < 0 do return {}
	body := rest[array_open + len("<array>"):]
	array_close := strings.index(body, "</array>")
	if array_close < 0 do return {}
	body = body[:array_close]

	flags: Manager_Unit_Flags
	pending := ""
	pos := 0
	for {
		value, ok := manager_next_plist_value(body, &pos)
		if !ok do break
		switch pending {
		case "--hub":
			if !flags.hub_found {
				flags.hub = value
				flags.hub_found = true
			}
			pending = ""
		case "--daemon-url":
			if !flags.daemon_found {
				flags.daemon = value
				flags.daemon_found = true
			}
			pending = ""
		case "--config":
			if !flags.config_found {
				flags.config = value
				flags.config_found = true
			}
			pending = ""
		case:
			if value == "--hub" || value == "--daemon-url" || value == "--config" do pending = value
		}
	}
	return flags
}

// manager_pick_unit_hub mirrors src/bridge/main.odin:301-302: --hub is applied
// after --daemon-url, so --hub wins when both appear; the first value of a flag
// wins (option_value semantics), and a trailing flag without a value is ignored
// like option_value's fallback.
manager_pick_unit_hub :: proc(flags: Manager_Unit_Flags) -> (url: string, found: bool) {
	if flags.hub_found do return flags.hub, true
	if flags.daemon_found do return flags.daemon, true
	return "", false
}

// manager_scan_unit_tokens walks one whitespace-separated command line and
// records the first value of each recognized flag on it.
manager_scan_unit_tokens :: proc(line: string, flags: ^Manager_Unit_Flags) {
	pos := 0
	for {
		token, ok := manager_next_token(line, &pos)
		if !ok do break
		switch token {
		case "--hub":
			if value, value_ok := manager_next_token(line, &pos); value_ok && !flags.hub_found {
				flags.hub = value
				flags.hub_found = true
			}
		case "--daemon-url":
			if value, value_ok := manager_next_token(line, &pos); value_ok && !flags.daemon_found {
				flags.daemon = value
				flags.daemon_found = true
			}
		case "--config":
			if value, value_ok := manager_next_token(line, &pos); value_ok && !flags.config_found {
				flags.config = value
				flags.config_found = true
			}
		}
	}
}

// manager_unit_config_path resolves the config file the unit would load: its
// own --config argument when present (expanded the way cfg_lib.load expands
// paths), else the same default path the bridge falls back to
// (config.odin:226-234). The result may alias the caller's unit text and must
// not outlive it (path resolution follows the manager's existing convention,
// like manager_config_path).
manager_unit_config_path :: proc(unit_config: string, unit_config_found: bool) -> string {
	if unit_config_found && strings.trim_space(unit_config) != "" {
		return cfg_lib.expand_home(unit_config)
	}
	return cfg_lib.default_config_path()
}

// manager_strip_line_continuation drops trailing whitespace and, when the line
// ends in a backslash, reports it as a systemd line continuation.
manager_strip_line_continuation :: proc(line: string) -> (body: string, continues: bool) {
	trimmed := strings.trim_right(line, " \t\r")
	if strings.has_suffix(trimmed, "\\") do return trimmed[:len(trimmed) - 1], true
	return trimmed, false
}

// manager_next_token returns the next whitespace-separated token and advances
// `pos` past it.
manager_next_token :: proc(line: string, pos: ^int) -> (token: string, ok: bool) {
	i := pos^
	for i < len(line) && (line[i] == ' ' || line[i] == '\t' || line[i] == '\r') do i += 1
	if i >= len(line) do return "", false
	start := i
	for i < len(line) && line[i] != ' ' && line[i] != '\t' && line[i] != '\r' do i += 1
	pos^ = i
	return line[start:i], true
}

// manager_next_plist_value returns the next <string>...</string> element value
// inside an XML fragment and advances `pos` past it.
manager_next_plist_value :: proc(fragment: string, pos: ^int) -> (value: string, ok: bool) {
	open := strings.index(fragment[pos^:], "<string>")
	if open < 0 do return "", false
	start := pos^ + open + len("<string>")
	close := strings.index(fragment[start:], "</string>")
	if close < 0 do return "", false
	pos^ = start + close + len("</string>")
	return fragment[start:start + close], true
}

// MANAGER_UNIT_PLACEHOLDER_HUB mirrors the fallback scripts/install.sh bakes
// into a unit installed without --hub (install.sh:100, service_hub_url). It
// never names a real hub, so finding it in a unit is always a defect.
MANAGER_UNIT_PLACEHOLDER_HUB :: "https://hub.example.com"

// manager_urls_equal compares two hub URLs, tolerating a trailing slash
// (https://hub.example.com/ == https://hub.example.com).
manager_urls_equal :: proc(a, b: string) -> bool {
	return strings.trim_right(strings.trim_space(a), "/") == strings.trim_right(strings.trim_space(b), "/")
}

// manager_unit_hub_check answers one question — when this unit starts, will the
// bridge talk to the hub this node is enrolled with? — by comparing the hub the
// unit's command line passes against the hub of the config the UNIT would load
// (never a config the unit does not read). unit_label names the scope that was
// inspected and every detail names the compared config path.
//
// Outcomes: the install.sh placeholder FAILs unconditionally; a real hub that
// differs from the unit's config FAILs as a mismatch with the exact
// remediation; everything that cannot be compared WARNs — an unreadable unit
// config, a genuinely empty [wrapper] daemon_url, or the bridge's built-in
// default hub (the "this node was never enrolled" signal, main.odin:243+258,
// config.odin:833).
manager_unit_hub_check :: proc(unit_label, unit_hub: string, unit_hub_found: bool, config_path, config_hub: string, config_readable: bool) -> (Manager_Check_Status, string) {
	if unit_hub_found && manager_urls_equal(unit_hub, MANAGER_UNIT_PLACEHOLDER_HUB) {
		return .Fail, fmt.tprintf("%s passes the install.sh placeholder hub %s (the installer ran without --hub) — the bridge would use it instead of the hub in %s; reinstall with a real hub: scripts/install.sh --hub <url>", unit_label, unit_hub, config_path)
	}
	if !config_readable {
		if unit_hub_found {
			return .Warn, fmt.tprintf("cannot compare: the config this unit loads (%s) is not readable; %s passes %s", config_path, unit_label, unit_hub)
		}
		return .Warn, fmt.tprintf("cannot compare: the config this unit loads (%s) is not readable; %s passes no --hub/--daemon-url", config_path, unit_label)
	}
	if config_hub == "" {
		if unit_hub_found {
			return .Warn, fmt.tprintf("not enrolled: %s has an empty [wrapper] daemon_url; the hub %s passed by %s would drive the bridge — enroll this node: ham-bridge enroll --hub <your-heimdall-url>", config_path, unit_hub, unit_label)
		}
		return .Warn, fmt.tprintf("not enrolled: %s has an empty [wrapper] daemon_url; %s passes no --hub/--daemon-url — enroll this node: ham-bridge enroll --hub <your-heimdall-url>", config_path, unit_label)
	}
	if manager_urls_equal(config_hub, cfg_lib.default_config().wrapper.daemon_url) {
		if unit_hub_found {
			return .Warn, fmt.tprintf("not enrolled: %s still carries the default hub %s; %s passes %s and would drive the bridge — enroll this node: ham-bridge enroll --hub <your-heimdall-url>", config_path, config_hub, unit_label, unit_hub)
		}
		return .Warn, fmt.tprintf("not enrolled: %s still carries the default hub %s; %s passes no --hub/--daemon-url — enroll this node: ham-bridge enroll --hub <your-heimdall-url>", config_path, config_hub, unit_label)
	}
	if unit_hub_found {
		if manager_urls_equal(unit_hub, config_hub) {
			return .Ok, fmt.tprintf("%s passes %s, matching the hub in %s", unit_label, unit_hub, config_path)
		}
		return .Fail, fmt.tprintf("%s passes %s but %s has %s — the unit flag overrides the config at bridge startup; fix: scripts/install.sh --hub %s (or re-enroll this node)", unit_label, unit_hub, config_path, config_hub, config_hub)
	}
	return .Ok, fmt.tprintf("%s passes no --hub/--daemon-url; the bridge takes the hub from %s: %s", unit_label, config_path, config_hub)
}

manager_doctor_command :: proc(args: []string) -> int {
	platform := manager_host_platform()
	config_path := manager_config_path(args)
	load_result, config_loaded := cfg_lib.load(config_path)
	hub_url := ""
	bridge_id := ""
	config_token := ""
	data_dir := ""
	if config_loaded {
		hub_url = load_result.config.wrapper.daemon_url
		if hub_url == "" do hub_url = load_result.config.ctl.daemon_url
		bridge_id = load_result.config.daemon.daemon_id
		config_token = load_result.config.daemon.bridge_token
		data_dir = load_result.config.daemon.data_dir
	}
	token_path := manager_token_path(args, config_path)
	token := manager_read_token_file(token_path)
	token_from_file := token != ""
	if !token_from_file do token = config_token

	checks := make([dynamic]Manager_Check, 0, 16)
	defer delete(checks)

	// Enrollment.
	if hub_url != "" && bridge_id != "" {
		append(&checks, Manager_Check{name = "enrollment", status = .Ok, detail = fmt.tprintf("enrolled as %s (hub %s)", bridge_id, hub_url)})
	} else {
		append(&checks, Manager_Check{name = "enrollment", status = .Warn, detail = "not enrolled — run: ham-bridge enroll --hub <your-heimdall-url>"})
	}

	// Bridge token file and its permissions.
	if token_from_file {
		fi, stat_err := os.stat(token_path, context.allocator)
		if stat_err == nil {
			mode := manager_permissions_mode(fi.mode)
			os.file_info_delete(fi, context.allocator)
			if mode & 0o077 == 0 {
				append(&checks, Manager_Check{name = "token file", status = .Ok, detail = fmt.tprintf("%s (mode %s)", token_path, manager_mode_string(mode))})
			} else {
				append(&checks, Manager_Check{name = "token file", status = .Fail, detail = fmt.tprintf("%s has insecure mode %s (group/other bits set) — fix: chmod 600 %s", token_path, manager_mode_string(mode), token_path)})
			}
		}
	} else if strings.trim_space(config_token) != "" {
		append(&checks, Manager_Check{name = "token file", status = .Warn, detail = fmt.tprintf("no token file at %s; using [daemon] bridge_token from config.toml (service units expect the file)", token_path)})
	} else {
		append(&checks, Manager_Check{name = "token file", status = .Warn, detail = fmt.tprintf("no bridge token at %s — enroll this node", token_path)})
	}

	// Config directory writability (enroll rewrites config.toml + token here).
	config_dir := manager_dir_of(config_path)
	if manager_is_dir(config_dir) {
		if manager_write_probe(config_dir) {
			append(&checks, Manager_Check{name = "config dir", status = .Ok, detail = fmt.tprintf("%s writable", config_dir)})
		} else {
			append(&checks, Manager_Check{name = "config dir", status = .Fail, detail = fmt.tprintf("%s is not writable", config_dir)})
		}
	} else {
		append(&checks, Manager_Check{name = "config dir", status = .Warn, detail = fmt.tprintf("%s missing (created by ham-bridge enroll)", config_dir)})
	}

	// Data directory writability (bridge writes bootstrap cache/artifacts here).
	// The config default carries a literal "~", so always expand first.
	raw_data_dir := data_dir if data_dir != "" else MANAGER_DEFAULT_DATA_DIR
	effective_data_dir := cfg_lib.expand_home(raw_data_dir)
	if manager_is_dir(effective_data_dir) {
		if manager_write_probe(effective_data_dir) {
			append(&checks, Manager_Check{name = "data dir", status = .Ok, detail = fmt.tprintf("%s writable", effective_data_dir)})
		} else {
			append(&checks, Manager_Check{name = "data dir", status = .Fail, detail = fmt.tprintf("%s is not writable — the bridge cannot persist its cache", effective_data_dir)})
		}
	} else {
		parent := manager_nearest_existing_dir(effective_data_dir)
		if parent == "" || !manager_write_probe(parent) {
			append(&checks, Manager_Check{name = "data dir", status = .Fail, detail = fmt.tprintf("%s cannot be created (no writable parent)", effective_data_dir)})
		} else {
			append(&checks, Manager_Check{name = "data dir", status = .Ok, detail = fmt.tprintf("%s absent — created on first bridge run", effective_data_dir)})
		}
	}

	// Bridge loopback endpoint (the service's health contract).
	probe, probe_detail := manager_probe_bridge_loopback(MANAGER_LOOPBACK_PORT, token)
	switch probe {
	case .Heimdall_Ok, .Heimdall_Responding:
		append(&checks, Manager_Check{name = fmt.tprintf("bridge :%d", MANAGER_LOOPBACK_PORT), status = .Ok, detail = probe_detail})
	case .Heimdall_Unauthorized:
		if token != "" {
			append(&checks, Manager_Check{name = fmt.tprintf("bridge :%d", MANAGER_LOOPBACK_PORT), status = .Fail, detail = "bridge rejected the stored token (401) — re-run: ham-bridge enroll --hub <your-heimdall-url>"})
		} else {
			append(&checks, Manager_Check{name = fmt.tprintf("bridge :%d", MANAGER_LOOPBACK_PORT), status = .Ok, detail = probe_detail})
		}
	case .Other_Service:
		append(&checks, Manager_Check{name = fmt.tprintf("bridge :%d", MANAGER_LOOPBACK_PORT), status = .Fail, detail = fmt.tprintf("port %d is held by another service — free it for heimdall-bridge", MANAGER_LOOPBACK_PORT)})
	case .Not_Listening:
		append(&checks, Manager_Check{name = fmt.tprintf("bridge :%d", MANAGER_LOOPBACK_PORT), status = .Fail, detail = "bridge is not listening — start it: heimdall start"})
	}

	// Local endpoint port: the bridge prefers a unix socket and only falls back
	// to TCP here, so "not listening" is normal and never a failure.
	if manager_tcp_probe(MANAGER_LOCAL_ENDPOINT_PORT) {
		append(&checks, Manager_Check{name = fmt.tprintf("local endpoint :%d", MANAGER_LOCAL_ENDPOINT_PORT), status = .Ok, detail = "listening (proxy/shell input fallback)"})
	} else {
		append(&checks, Manager_Check{name = fmt.tprintf("local endpoint :%d", MANAGER_LOCAL_ENDPOINT_PORT), status = .Ok, detail = "not listening (unix socket mode is the default; fallback only)"})
	}

	// Service unit / agent presence. The unit contents are kept for the hub
	// check below and freed once the report is built.
	plist_path := manager_launchd_plist_path()
	unit_present := false
	unit_text := ""
	if platform == .Unsupported {
		append(&checks, Manager_Check{name = "service unit", status = .Fail, detail = "unsupported platform (service management requires Linux or macOS)"})
	} else {
		unit_text, unit_present = manager_unit_contents(platform, MANAGER_SERVICE_UNIT, plist_path)
		if unit_present {
			location := MANAGER_SERVICE_UNIT if platform == .Linux else plist_path
			append(&checks, Manager_Check{name = "service unit", status = .Ok, detail = fmt.tprintf("%s present", location)})
		} else if platform == .Linux {
			append(&checks, Manager_Check{name = "service unit", status = .Fail, detail = fmt.tprintf("systemd user unit %s not found — install it (nix/home-manager or scripts/install.sh)", MANAGER_SERVICE_UNIT)})
		} else {
			append(&checks, Manager_Check{name = "service unit", status = .Fail, detail = fmt.tprintf("%s not found — install it (nix/home-manager or scripts/install.sh)", plist_path)})
		}
	}
	defer {
		if len(unit_text) > 0 do delete(unit_text)
	}

	// The hub the unit's command line would pass, against the config the unit
	// itself loads (REQ-INST-9): such a flag overrides the enrolled hub at
	// bridge startup (src/bridge/main.odin:256-302).
	if unit_present {
		unit_label := fmt.tprintf("systemd user unit %s", MANAGER_SERVICE_UNIT) if platform == .Linux else fmt.tprintf("LaunchAgent plist %s", plist_path)
		flags := manager_unit_flags(unit_text, platform)
		unit_hub, unit_hub_found := manager_pick_unit_hub(flags)
		unit_config_path := manager_unit_config_path(flags.config, flags.config_found)
		unit_config_hub := ""
		unit_config_readable := false
		if config_loaded && unit_config_path == load_result.path {
			unit_config_hub = load_result.config.wrapper.daemon_url
			unit_config_readable = true
		} else if unit_load, unit_loaded := cfg_lib.load(unit_config_path); unit_loaded {
			unit_config_hub = unit_load.config.wrapper.daemon_url
			unit_config_readable = true
		}
		unit_status, unit_detail := manager_unit_hub_check(unit_label, unit_hub, unit_hub_found, unit_config_path, unit_config_hub, unit_config_readable)
		append(&checks, Manager_Check{name = "unit hub", status = unit_status, detail = unit_detail})
	}

	// Coding harnesses are optional: report, never fail.
	for harness in MANAGER_DOCTOR_HARNESSES {
		if path, found := manager_bin_on_path(harness.bin); found {
			append(&checks, Manager_Check{name = fmt.tprintf("harness %s", harness.name), status = .Ok, detail = path})
		} else {
			append(&checks, Manager_Check{name = fmt.tprintf("harness %s", harness.name), status = .Warn, detail = fmt.tprintf("%s not found on PATH (harness optional)", harness.bin)})
		}
	}

	fmt.printfln("heimdall doctor — %s (%s/%s)", config_path, manager_os_string(), manager_arch_string())
	ok_count, warn_count, fail_count := 0, 0, 0
	for check in checks {
		label := "ok"
		switch check.status {
		case .Ok: ok_count += 1
		case .Warn:
			label = "warn"
			warn_count += 1
		case .Fail:
			label = "FAIL"
			fail_count += 1
		}
		fmt.printfln("  %-4s %s: %s", label, check.name, check.detail)
	}
	fmt.printfln("doctor: %d ok, %d warnings, %d failures", ok_count, warn_count, fail_count)
	if fail_count > 0 do return 1
	return 0
}
