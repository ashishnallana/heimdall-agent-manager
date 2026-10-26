// heimdall status: one report showing everything an operator needs to answer
// "is this node healthy and connected?": enrollment files, the bridge service
// state, the Hub connection for this bridge, the loopback health contract and
// the installed binary versions. It is a report, not a healthcheck gate — it
// always exits 0 (use `heimdall doctor` for pass/fail diagnostics).
package main

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import httpc "odin_test:lib/httpc"
import cfg_lib "odin_test:lib/config"

manager_probe_binary :: proc(bin: string) -> (path: string, version_line: string, found: bool, version_ok: bool) {
	path, found = manager_bin_on_path(bin)
	if !found do return
	out, _, ok := manager_run_capture({bin, "--version"})
	version_line = strings.trim_space(manager_first_line(out))
	return path, version_line, true, ok
}

manager_status_command :: proc(args: []string) {
	if manager_has_flag(args, "--help") || manager_has_flag(args, "-h") {
		fmt.println("usage: heimdall status [--config <path>]")
		fmt.println("")
		fmt.println("Reports enrollment, the heimdall-bridge service state, Hub connectivity,")
		fmt.println("the loopback health contract and installed binary versions. Always exits 0.")
		return
	}
	platform := manager_host_platform()
	config_path := manager_config_path(args)
	load_result, config_loaded := cfg_lib.load(config_path)
	hub_url, bridge_id, config_token, data_dir := "", "", "", ""
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

	fmt.println(manager_version_line())
	fmt.println("")

	// Enrollment.
	fmt.println("Enrollment")
	if config_loaded {
		fmt.printfln("  config:       %s", config_path)
	} else {
		fmt.printfln("  config:       %s (missing)", config_path)
	}
	if hub_url != "" {
		fmt.printfln("  hub url:      %s", hub_url)
	} else {
		fmt.println("  hub url:      (not set — run: ham-bridge enroll --hub <your-heimdall-url>)")
	}
	if bridge_id != "" {
		fmt.printfln("  bridge id:    %s", bridge_id)
	} else {
		fmt.println("  bridge id:    (not enrolled)")
	}
	switch {
	case manager_path_exists(token_path):
		fi, stat_err := os.stat(token_path, context.allocator)
		if stat_err == nil {
			fmt.printfln("  token file:   %s (mode %s, %d bytes)", token_path, manager_mode_string(manager_permissions_mode(fi.mode)), fi.size)
			os.file_info_delete(fi, context.allocator)
		}
	case strings.trim_space(config_token) != "":
		fmt.printfln("  token file:   %s (missing; using config.toml [daemon] bridge_token)", token_path)
	case:
		fmt.printfln("  token file:   %s (missing)", token_path)
	}
	data_dir_display := data_dir
	if data_dir_display == "" do data_dir_display = MANAGER_DEFAULT_DATA_DIR
	// Config defaults carry a literal "~"; expand before display/checks.
	fmt.printfln("  data dir:     %s", cfg_lib.expand_home(data_dir_display))

	// Bridge service.
	fmt.println("")
	fmt.println("Bridge service")
	if platform == .Unsupported {
		fmt.println("  unsupported platform (service management requires Linux or macOS)")
	} else {
		state := manager_service_state(platform, MANAGER_SERVICE_UNIT, MANAGER_LAUNCHD_LABEL, manager_launchd_plist_path())
		if platform == .Linux {
			fmt.printfln("  unit:         %s (systemd --user)", MANAGER_SERVICE_UNIT)
		} else {
			fmt.printfln("  agent:        %s (launchd)", MANAGER_LAUNCHD_LABEL)
		}
		switch {
		case !state.loaded:
			fmt.printfln("  state:        not loaded (%s)", state.detail)
		case state.active:
			if state.since != "" && state.pid > 0 {
				fmt.printfln("  state:        active (pid %d, since %s)", state.pid, state.since)
			} else if state.pid > 0 {
				fmt.printfln("  state:        active (pid %d)", state.pid)
			} else {
				fmt.printfln("  state:        active (%s)", state.detail)
			}
		case:
			fmt.printfln("  state:        %s", state.detail)
		}
	}

	// Hub connection: the Hub's own view of this bridge (authenticated with the
	// bridge token; the Hub accepts bridge tokens on the detail route).
	fmt.println("")
	fmt.println("Hub connection")
	switch {
	case hub_url == "" || bridge_id == "":
		fmt.println("  skipped (not enrolled)")
	case token == "":
		fmt.println("  skipped (no bridge token — run: ham-bridge enroll --hub <your-heimdall-url>)")
	case:
		detail := [?]string{"api", "v1", "bridges", bridge_id}
		hub, url_err := httpc.parse_url(hub_url)
		target := hub_url
		if url_err == .None {
			if rendered, render_err := httpc.build_url(hub, detail[:], allocator = context.temp_allocator); render_err == .None do target = rendered
		}
		headers := [?]httpc.Header{httpc.bearer(token)}
		resp: httpc.Response
		err := httpc.Error.Invalid_Url
		if url_err == .None {
			resp, err = httpc.send({method = .GET, url = hub, path = detail[:], headers = headers[:], timeout_ms = MANAGER_PROBE_TIMEOUT_MS}, context.temp_allocator)
		}
		body := httpc.text(resp)
		switch {
		case err != .None:
			fmt.printfln("  GET %s: unreachable (%s — is the Hub/proxy up?)", target, httpc.error_string(err))
		case resp.status == 200:
			status := manager_extract_json_string(body, "status", "unknown")
			last_seen := manager_extract_json_string(body, "last_seen_at", "")
			machine := manager_extract_json_string(body, "machine_hostname", "")
			fmt.printfln("  GET %s: %s (machine %s, last seen %s)", target, status, machine, last_seen)
		case:
			fmt.printfln("  GET %s: HTTP %d — %s", target, resp.status, body)
			if resp.status == 401 || resp.status == 403 do fmt.println("  hint: bridge token rejected — re-run: ham-bridge enroll --hub <your-heimdall-url>")
		}
	}

	// Bridge loopback health.
	fmt.println("")
	fmt.printfln("Bridge loopback (:%d)", MANAGER_LOOPBACK_PORT)
	health_url := fmt.tprintf("http://127.0.0.1:%d/bridge/health", MANAGER_LOOPBACK_PORT)
	_, probe_detail := manager_probe_bridge_loopback(MANAGER_LOOPBACK_PORT, token)
	fmt.printfln("  %s: %s", health_url, probe_detail)

	// Installed binaries.
	fmt.println("")
	fmt.println("Binaries")
	fmt.printfln("  %-12s %s (this binary)", "heimdall", contracts.APP_VERSION)
	for bin in ([]string{"ham-bridge", "ham-pty-host", "ham-ctl"}) {
		path, version_line, found, version_ok := manager_probe_binary(bin)
		switch {
		case !found:
			fmt.printfln("  %-12s not found on PATH", bin)
		case version_ok && version_line != "":
			fmt.printfln("  %-12s %s (%s)", bin, version_line, path)
		case:
			fmt.printfln("  %-12s version unknown (%s)", bin, path)
		}
	}
}
