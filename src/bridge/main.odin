package main

import "core:crypto"
import "core:crypto/legacy/sha1"
import base64 "core:encoding/base64"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import cfg_lib "odin_test:lib/config"
import crashlog "odin_test:lib/crashlog"
import httpc "odin_test:lib/httpc"
import ws "odin_test:lib/ws"
import jsonx "odin_test:lib/jsonx"
import vault "odin_test:lib/vault"

Bridge_Config :: struct {
	bind_host: string,
	port: u16,
	daemon_url: string,
	daemon_id: string,
	bridge_token: string,
	// REQ-IMPL-4: path of the 0600 file holding the access token, when one was used.
	// The proactive-refresh worker rewrites it in place; see
	// bridge_credential_refresh_start.
	credential_file: string,
	data_dir: string,
	chunk_bytes: int,
	bootstrap_cache_max_bytes: int,
	local_endpoint_port: u16,
	local_endpoint_run_dir: string,
	// REQ-XM-4: serve the local HTTP proxy entry point (/proxy/<session_id>/<path>) on
	// the local endpoint. ENABLED BY DEFAULT by user decision (2026-09-21); --no-local-proxy
	// or [bridge] local_proxy_enabled=false turns it off. This is an off switch, not an
	// opt-in: a deployment that sets nothing gets the proxy.
	local_proxy_enabled: bool,
	fs_root: string,
	fs_read_page_bytes: i64,
	// BR-2: when true the bridge drives agents through ham-pty-host instead of
	// tmux. Default false (tmux path) until DEL-1 flips it. Also overridable at
	// runtime via HEIMDALL_BRIDGE_PTY_HOST for A/B testing.
	pty_host_runtime: bool,
}

bridge_config: Bridge_Config
bridge_sequence: i64

main :: proc() {
	when ODIN_OS != .Windows {
		_ = posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
		crashlog.install("ham-bridge")
	}
	bridge_strip_parent_session_env()
	if !bridge_capture_keyring_env_override() {
		fmt.eprintln("ERROR: could not remove HEIMDALL_VAULT_KEYRING from the environment; refusing to start so no child inherits it")
		os.exit(1)
	}
	// libcurl global init, once, before any thread; refuses a too-old libcurl.
	if ok, message := httpc.init(); !ok {
		fmt.eprintln("ham-bridge:", message)
		os.exit(1)
	}
	if has_flag(os.args, "--version") {
		fmt.println("ham-bridge", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION, "bridge", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION, "ws", contracts.BRIDGE_WS_FRAME_VERSION)
		return
	}
	if has_flag(os.args, "--help") || has_flag(os.args, "-h") {
		print_usage()
		return
	}

	// --probe-hub <url>: reach the Hub through the bridge's OWN HTTPS client
	// (src/lib/httpc, its statically linked libcurl), not the curl CLI. The
	// output names the TLS library and the trust anchors in use. The installer runs this after the
	// download and before touching any service, because curl succeeding while
	// this path fails is exactly what a phone showed.
	if has_flag(os.args, "--probe-hub") {
		raw := option_value(os.args, "--probe-hub", "")
		api_base, origin_ok := bridge_enroll_hub_url(raw)
		if !origin_ok {
			fmt.eprintln("probe-hub: --probe-hub needs the Hub API origin, e.g. https://hub.example.com")
			os.exit(2)
		}
		started := time.now()
		hub := bridge_hub_url(api_base)
		health := [?]string{"api", "v1", "health"}
		target, _ := httpc.build_url(hub, health[:], allocator = context.temp_allocator)
		resp, probe_err := bridge_hub_http_send_alloc({method = .GET, url = hub, path = health[:]})
		defer httpc.response_destroy(&resp)
		if probe_err != .None {
			fmt.eprintfln("probe-hub FAILED: no HTTP response from %s through libcurl %s (%s; CA: %s) after %v — %s (%s); check TLS trust (HAM_TLS_CA_FILE / SSL_CERT_FILE) and the network", target, httpc.libcurl_version(), httpc.libcurl_tls_version(), httpc.trust_summary(), time.since(started), httpc.error_string(probe_err), resp.detail)
			os.exit(1)
		}
		fmt.printfln("probe-hub OK: %s -> HTTP %d via libcurl %s (%s; CA: %s) in %v", target, resp.status, httpc.libcurl_version(), httpc.libcurl_tls_version(), httpc.trust_summary(), time.since(started))
		return
	}

	if len(os.args) > 2 && os.args[1] == "vault" && os.args[2] == "prune" {
		if !bridge_vault_prune_command(os.args) do os.exit(1)
		return
	}
	// Local lifecycle surface (bridgesvc): never needs the bridge token (F22).
	if len(os.args) > 1 && os.args[1] == "service" {
		if !bridge_service_command(os.args) do os.exit(1)
		return
	}
	if len(os.args) > 1 && os.args[1] == "status" {
		if !bridge_status_command(os.args) do os.exit(1)
		return
	}
	if len(os.args) > 1 && os.args[1] == "setup" {
		if !bridge_setup_command(os.args) do os.exit(1)
		return
	}
	if len(os.args) > 1 && os.args[1] == "update" {
		if !bridge_update_command(os.args) do os.exit(1)
		return
	}
	if len(os.args) > 1 && os.args[1] == "uninstall" {
		if !bridge_uninstall_command(os.args) do os.exit(1)
		return
	}
	if len(os.args) > 1 && os.args[1] == "tray" {
		if !bridge_tray_command(os.args) do os.exit(1)
		return
	}
	if len(os.args) > 1 && os.args[1] == "extensions" {
		if !bridge_extensions_command(os.args) do os.exit(1)
		return
	}
	if len(os.args) > 1 && os.args[1] == "list" {
		if !bridge_list_command(os.args) do os.exit(1)
		return
	}
	if len(os.args) > 1 && os.args[1] == "enroll" {
		if strings.trim_space(option_value(os.args, "--hub", "")) == "" {
			fmt.eprintln("ham-bridge enroll requires --hub <http(s)://your-hub-url[/prefix]>: the bridge is bound to exactly that hub")
			fmt.eprintln("")
			fmt.eprintln("  There is no enrollment token: approval happens in the browser.")
			fmt.eprintln("  Enrollment is approved in the browser, so no secret is copied to this machine.")
			fmt.eprintln("")
			fmt.eprintln("    ham-bridge enroll --hub https://your-hub-url [--bridge-token-file PATH] [--headless] [--json-progress] [--approval-base-url URL] [--reuse-bridge BRIDGE_ID | --new-bridge] [--replace-other-account]")
			os.exit(1)
		}
		if !bridge_enroll_device_command(os.args) do os.exit(3 if bridge_enroll_service_start_failed else 1)
		return
	}
	if has_flag(os.args, "--bridge-wrapper-supervisor") || (len(os.args) > 1 && os.args[1] == "wrapper-supervisor") {
		fmt.eprintln("ham-bridge wrapper-supervisor is removed; use ham-wrapper bridge-runtime")
		os.exit(1)
	}

	// REQ-EA-4: finish or discard an atomic enrollment a crash left staged, BEFORE the
	// credential is read: a committed one must start with its new credential, a
	// rolled-back one must not leave its staging behind.
    resume_sunset := len(os.args) > 2 && os.args[1] == "recovery" && os.args[2] == "resume-sunset"
    recovery_command := resume_sunset || (len(os.args) > 2 && os.args[1] == "recovery" && (os.args[2] == "resume-sync" || os.args[2] == "resume-refresh"))
    bridge_hub_traffic_config_path = cfg_lib.config_path_from_args(os.args)
    if resume_sunset {
        cfg := bridge_config_from_args(os.args)
        if !bridge_hub_resume_sunset(cfg, bridge_hub_traffic_config_path) {
            fmt.eprintln("sunset resume refused: stop the service first; only a matching temporary pause can resume")
            os.exit(1)
        }
        fmt.println("temporary Hub traffic pause cleared locally; start the bridge service after confirming rollback")
        return
    }
    // Check BEFORE atomic enrollment recovery, which may itself contact the Hub.
    // Remain alive so service managers cannot restart into a network retry loop.
    if !recovery_command {
        if _, exists, _ := bridge_hub_pause_read(bridge_hub_traffic_config_path); exists {
            pause_lock, locked := bridge_config_lock(bridge_hub_traffic_config_path)
            if !locked do os.exit(0)
            defer bridge_instance_unlock(pause_lock)
            fmt.eprintln("bridge Hub traffic is paused; stop service, then use recovery resume-sunset after rollback, or enroll again")
            for { time.sleep(30 * time.Second) }
        }
        startup_cfg := bridge_config_from_args(os.args)
        if m, pending := bridge_reenroll_pending(bridge_hub_traffic_config_path, startup_cfg.daemon_id); pending {
            bridge_config = startup_cfg
            bridge_reenroll_park(bridge_hub_traffic_config_path, m)
        }
    }
    // Offline recovery must acquire exclusion before any durable-state repair.
    if !recovery_command do _ = bridge_enroll_atomic_recover(os.args)
	bridge_config = bridge_config_from_args(os.args)
	default_credential_path := bridge_enroll_default_credential_path(bridge_config.daemon_url, strings.trim_space(bridge_config.daemon_id))
	bridge_adopt_default_credential_if_needed(&bridge_config, default_credential_path)
	delete(default_credential_path)
    if recovery_command {
        if !bridge_recovery_resume(bridge_config, cfg_lib.config_path_from_args(os.args), os.args[2] == "resume-refresh") do os.exit(1)
        fmt.println("recovery resumed; restart the bridge with the repaired configuration")
        return
    }
	// REQ-IMPL-4 / audit F4: an enrolled bridge holding no credential must not run.
	// Checked before anything is initialised, so the loopback listener never opens
	// in the state where its authorizer admits everyone.
	//
	// Enrollment returns from main after restarting the registered service; this
	// guard applies only to ordinary runtime starts.
	// F21: a profile the hub refused (revoked, refresh 401, vault key never delivered)
	// parks until it is re-enrolled instead of exiting non-zero into a crash loop.
	if m, pending := bridge_reenroll_pending(cfg_lib.config_path_from_args(os.args), bridge_config.daemon_id); pending {
		bridge_reenroll_park(cfg_lib.config_path_from_args(os.args), m)
	}
	if bridge_refuse_tokenless_start(bridge_config) {
		config_path := cfg_lib.config_path_from_args(os.args)
		bridge_reenroll_mark(config_path, bridge_config.daemon_url, bridge_config.daemon_id, .Credential_Missing)
		if m, pending := bridge_reenroll_pending(config_path, bridge_config.daemon_id); pending do bridge_reenroll_park(config_path, m)
		os.exit(1)
	}
	// Multi-bridge isolation: bind vault state to the configured hub and refuse a hub
	// mismatch or a second instance on the same config/scope.
	if !bridge_bind_runtime_hub(bridge_config, cfg_lib.config_path_from_args(os.args)) do os.exit(1)
	bridge_fs_init(bridge_config.fs_root, bridge_config.fs_read_page_bytes)
	vcs_init()
	bridge_provider_store_init()
	bridge_provider_catalog_init()
	bridge_provider_paths_init()
	bridge_provider_startup_log()
	bootstrap_cache_init(&bootstrap_global_cache, bridge_config.data_dir, bridge_config.bootstrap_cache_max_bytes)
	if has_flag(os.args, "--bootstrap-fetch") {
		instance_id := option_value(os.args, "--instance-id", "")
		run_dir := option_value(os.args, "--run-dir", "")
		bridge_endpoint := option_value(os.args, "--bridge-endpoint", os.get_env_alloc("HEIMDALL_BRIDGE_ENDPOINT", context.allocator))
		agent_token := option_value(os.args, "--agent-token", os.get_env_alloc("HEIMDALL_AGENT_TOKEN", context.allocator))
		provider := option_value(os.args, "--provider", "")
		credential_snapshot_146 := bridge_credential_snapshot()
		defer delete(credential_snapshot_146)
		if !bridge_bootstrap_fetch_manifest_and_materialize(bridge_config.daemon_url, credential_snapshot_146, instance_id, run_dir, bridge_endpoint, agent_token, provider, &bootstrap_global_cache) {
			credential_snapshot_147 := bridge_credential_snapshot()
			defer delete(credential_snapshot_147)
			if !bridge_bootstrap_fetch_and_materialize(bridge_config.daemon_url, credential_snapshot_147, instance_id, run_dir, bridge_endpoint, agent_token, provider) {
				fmt.eprintln("bootstrap fetch/materialization failed")
				os.exit(1)
			}
		}
		fmt.println("bootstrap materialized", run_dir)
		return
	}
	bridge_runtime_init()
	bridge_tool_live_init()
	// REQ-SHELL-8: reclaim shell output past its retention window. Bridge start is a
	// trigger rather than a tick — this is the first of three events that already
	// happen (start, session create, hub reconnect) and between them they age output
	// out with no poller anywhere. Safe this early because the sweep decides liveness
	// from the on-disk specs, which is exactly the evidence that survives a restart.
	bridge_shell_output_sweep_if_due()
	bridge_agent_token_store_init()
	// Start the local endpoint at bridge boot, not lazily on launch. Wrappers may
	// outlive and reconnect after a bridge restart, so recovery requires the local
	// JSONL socket before any new launch command arrives.
	if endpoint, endpoint_ok := bridge_runtime_ensure_local_endpoint(); endpoint_ok {
		local_config := bridge_local_endpoint_config_default(bridge_config.local_endpoint_run_dir, bridge_config.local_endpoint_port)
		fmt.println("bridge local endpoint", endpoint, "fallback", bridge_local_endpoint_env_value(local_config, false), "socket_mode", "0600")
	}
	// Wake state must exist before the hub worker can run a launch, which
	// records itself via bridge_task_wake_note_launched.
	bridge_agent_wake_init()
	// Name the HTTPS client and its trust anchors once, so a host whose CA store
	// was not found (embedded Mozilla fallback) is visible in the service log.
	// (Locals, not inline calls: check-http-boundary.sh's library-path pattern
	// would read `", httpc.lib...` between two string literals as a path.)
	https_version, https_tls, https_ca := httpc.libcurl_version(), httpc.libcurl_tls_version(), httpc.trust_summary()
	fmt.println("bridge https client: libcurl", https_version, https_tls, "CA:", https_ca)
	bridge_hub_runtime_start()
	// REQ-IMPL-4 / design §7.5: renew the access token at 80% of its lifetime with
	// jitter, rather than waiting for a 401 — by which time in-flight work has
	// already failed. No-ops for a non-expiring legacy credential.
	bridge_credential_refresh_start(bridge_config.credential_file)
	bridge_task_chain_search_start()
	bridge_action_scheduler_start()
	bridge_auto_update_start()
	if bridge_config.chunk_bytes <= 0 do bridge_config.chunk_bytes = contracts.BRIDGE_WS_DEFAULT_CHUNK_BYTES
	_ = run_bridge_server(bridge_config)
	bridge_telemetry_stop()
}

print_usage :: proc() {
	fmt.println("ham-bridge", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
	fmt.println("usage: ham-bridge [--config <path>] [--bind-host 127.0.0.1] [--port 49323] [--daemon-url URL|--hub URL] [--daemon-id ID] [--bridge-token TOKEN|--bridge-token-file PATH] [--chunk-bytes N] [--local-endpoint-port PORT] [--local-run-dir DIR] [--no-local-proxy] [--agent-command CMD]")
	fmt.println("bridge runtime: ham-wrapper bridge-runtime --bridge-endpoint unix:/run/heimdall/bridge.sock --agent-token hlat_... --agent-instance-id inst_... --provider codex --model gpt-6.1-sol --run-dir <dir> -- <agent-command>")
	fmt.println("enroll: ham-bridge enroll --hub https://hub.example.com [--bridge-token-file PATH] [--headless] [--json-progress] [--approval-base-url URL] [--reuse-bridge BRIDGE_ID | --new-bridge] [--replace-other-account]")
	fmt.println("        opens the approval page when possible; --headless suppresses it; no enrollment token is needed")
	fmt.println("        asks the approver to reuse this config's bridge id (or --reuse-bridge BRIDGE_ID); --new-bridge asks for a new one")
	fmt.println("recovery: ham-bridge recovery resume-sunset --config PATH  (offline; stop service first; resume a temporary sunset after rollback)")
	fmt.println("service: ham-bridge service start|stop|restart|status [--hub URL [--profile P] | --service NAME] [--json]")
	fmt.println("status:  ham-bridge status [--json] [--hub URL [--profile P] | --service NAME]   (installed/enrolled/running/connected/vault/version; no token needed)")
	fmt.println("setup:   ham-bridge setup --hub URL [--profile P] [--new-bridge | --reuse-bridge BRIDGE_ID] [--reenroll] [--headless] [--json-progress]   (transactional install from this bundle; see docs/bridge-setup-progress.md)")
	fmt.println("list:    ham-bridge list [--json]   (every bridge profile of this OS user)")
	fmt.println("vault:  ham-bridge vault prune [--config PATH [--bridge-token-file PATH] [--remove]] [--remove-scope BRIDGE_ID --hub URL]   (list / prune vault state of bridges whose hub rejects them; never silent)")
	fmt.println("probe:  ham-bridge --probe-hub https://hub.example.com   (GET /api/v1/health through the bridge's own TLS transport; exit 0/1)")
	fmt.println("TLS: https:// Hub URLs use HTTPS and wss:// with certificate/hostname validation; http:// tunnel URLs use ws://.")
	fmt.println("bootstrap fetch: ham-bridge --bootstrap-fetch --daemon-url URL --bridge-token TOKEN|--bridge-token-file PATH --instance-id INST --run-dir DIR")
	fmt.println("bridge runtime: ham-wrapper bridge-runtime --bridge-endpoint unix:/run/bridge.sock --agent-token hlat_... --agent-instance-id INST --run-dir DIR -- <agent-command>")
	fmt.println("loopback routes:", contracts.ROUTE_BRIDGE_HEALTH, contracts.ROUTE_BRIDGE_VALIDATE_PROJECT_PATH)
}

bridge_hub_url_supported :: proc(hub_url: string) -> bool {
	trimmed := strings.trim_right(strings.trim_space(hub_url), "/")
	authority := ""
	if strings.has_prefix(trimmed, "http://") {
		authority = trimmed[len("http://"):]
	} else if strings.has_prefix(trimmed, "https://") {
		authority = trimmed[len("https://"):]
	} else {
		return false
	}
	// An optional path prefix (a hub behind a reverse proxy) is allowed; a query or
	// fragment is not, and every byte must be a plain URL character.
	if strings.contains(authority, "?") || strings.contains(authority, "#") do return false
	path := ""
	if slash := strings.index_byte(authority, '/'); slash >= 0 {
		path = authority[slash:]
		authority = authority[:slash]
	}
	if strings.trim_space(authority) == "" do return false
	for ch in transmute([]u8)authority {
		switch ch {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '-', ':', '[', ']':
		case: return false
		}
	}
	for ch in transmute([]u8)path {
		switch ch {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '-', '_', '~', '/':
		case: return false
		}
	}
	return !strings.contains(path, "//") && !strings.contains(path, "/../") && !strings.has_suffix(path, "/..")
}

// bridge_hub_canonical_base is the identity of a hub for this bridge's local state:
// lowercase scheme and host, an explicit port, and the path prefix (no trailing
// slash). Two different hubs (host, port or prefix) never share a canonical base.
bridge_hub_canonical_base :: proc(hub_url: string, allocator := context.allocator) -> (string, bool) {
	trimmed := strings.trim_right(strings.trim_space(hub_url), "/")
	if !bridge_hub_url_supported(trimmed) do return "", false
	secure := strings.has_prefix(trimmed, "https://")
	rest := trimmed[len("https://") if secure else len("http://"):]
	path := ""
	if slash := strings.index_byte(rest, '/'); slash >= 0 {
		path = rest[slash:]
		rest = rest[:slash]
	}
	host := strings.to_lower(rest, context.temp_allocator)
	port := 443 if secure else 80
	// A bracketed IPv6 literal keeps its colons; the port follows the bracket.
	if colon := strings.last_index_byte(host, ':'); colon >= 0 && colon > strings.last_index_byte(host, ']') {
		digits := host[colon + 1:]
		host = host[:colon]
		// A decimal integer 1..65535; leading zeros are normalized away ("08080" -> 8080).
		if digits == "" || len(digits) > 10 do return "", false
		port = 0
		for ch in transmute([]u8)digits {
			if ch < '0' || ch > '9' do return "", false
			port = port * 10 + int(ch - '0')
		}
		if port < 1 || port > 65535 do return "", false
	}
	// "hub.example.com." and "hub.example.com" are the same host.
	if strings.has_suffix(host, ".") && !strings.has_prefix(host, "[") do host = host[:len(host) - 1]
	if host == "" || !bridge_hub_host_canonical(host) do return "", false
	return strings.concatenate({"https://" if secure else "http://", host, ":", fmt.tprintf("%d", port), path}, allocator), true
}

// bridge_hub_host_canonical refuses hosts that name the same machine in more than
// one spelling: a numeric host (one whose last label is all digits or 0x-hex, which
// URL parsers read as IPv4) must be a dotted quad of four 0..255 decimals without
// leading zeros, so "127.1", "2130706433", "0x7f.0.0.1" and "127.000.0.1" are refused
// rather than becoming a second identity for 127.0.0.1. Empty labels are refused.
bridge_hub_host_canonical :: proc(host: string) -> bool {
	if strings.has_prefix(host, "[") do return strings.has_suffix(host, "]") && len(host) > 2
	labels := strings.split(host, ".", context.temp_allocator)
	for l in labels do if l == "" do return false
	last := labels[len(labels) - 1]
	numeric := strings.has_prefix(last, "0x")
	if !numeric {
		numeric = true
		for ch in transmute([]u8)last do if ch < '0' || ch > '9' do numeric = false
	}
	if !numeric do return true
	if len(labels) != 4 do return false
	for l in labels {
		if len(l) > 3 || (len(l) > 1 && l[0] == '0') do return false
		n := 0
		for ch in transmute([]u8)l {
			if ch < '0' || ch > '9' do return false
			n = n * 10 + int(ch - '0')
		}
		if n > 255 do return false
	}
	return true
}

// bridge_hub_pair_origin is the hub origin the pairing stretch binds
// (vault.Pair_Context.hub_origin): the canonical base without its path prefix,
// "scheme://host:port". The approving browser computes the same from the API base it
// talks to (pairHubOrigin in src/ui/utils/vaultPairing.ts).
bridge_hub_pair_origin :: proc(hub_url: string, allocator := context.allocator) -> (string, bool) {
	base, ok := bridge_hub_canonical_base(hub_url, context.temp_allocator)
	if !ok do return "", false
	scheme_end := strings.index(base, "://") + len("://")
	origin := base
	if slash := strings.index_byte(base[scheme_end:], '/'); slash >= 0 do origin = base[:scheme_end + slash]
	if !vault.valid_pair_hub_origin(origin) do return "", false
	return strings.clone(origin, allocator), true
}

bridge_config_line_key :: proc(trimmed_line: string) -> string {
	eq := strings.index_byte(trimmed_line, '=')
	if eq <= 0 do return ""
	return strings.trim_space(trimmed_line[:eq])
}

bridge_config_write_assignment :: proc(b: ^strings.Builder, key, value: string) {
	strings.write_string(b, key)
	strings.write_string(b, " = \"")
	json_write_string(b, value)
	strings.write_string(b, "\"")
}

bridge_config_merge :: proc(existing, hub_url, bridge_token, bridge_id: string) -> string {
	b := strings.builder_make()
	section := ""
	wrapper_written := false
	daemon_id_written := false
	token_written := false
	has_token := strings.trim_space(bridge_token) != ""
	text := existing
	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "[") && strings.has_suffix(trimmed, "]") {
			section = trimmed
		}
		key := bridge_config_line_key(trimmed)
		if section == "[wrapper]" && key == "daemon_url" {
			bridge_config_write_assignment(&b, "daemon_url", hub_url)
			wrapper_written = true
			strings.write_byte(&b, '\n')
			continue
		}
		if section == "[daemon]" && key == "daemon_id" {
			bridge_config_write_assignment(&b, "daemon_id", bridge_id)
			daemon_id_written = true
			strings.write_byte(&b, '\n')
			continue
		}
		if has_token && section == "[daemon]" && key == "bridge_token" {
			bridge_config_write_assignment(&b, "bridge_token", bridge_token)
			token_written = true
			strings.write_byte(&b, '\n')
			continue
		}
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	if !wrapper_written {
		if strings.builder_len(b) > 0 do strings.write_byte(&b, '\n')
		strings.write_string(&b, "[wrapper]\n")
		bridge_config_write_assignment(&b, "daemon_url", hub_url)
		strings.write_byte(&b, '\n')
	}
	if !daemon_id_written || (has_token && !token_written) {
		if strings.builder_len(b) > 0 do strings.write_byte(&b, '\n')
		strings.write_string(&b, "[daemon]\n")
		if has_token && !token_written {
			bridge_config_write_assignment(&b, "bridge_token", bridge_token)
			strings.write_byte(&b, '\n')
		}
		if !daemon_id_written {
			bridge_config_write_assignment(&b, "daemon_id", bridge_id)
			strings.write_byte(&b, '\n')
		}
	}
	return strings.to_string(b)
}

bridge_write_enrolled_config :: proc(path, hub_url, bridge_token, bridge_id: string) -> bool {
	if strings.trim_space(path) == "" || strings.trim_space(hub_url) == "" do return false
	if slash := strings.last_index_byte(path, '/'); slash > 0 { _ = bridge_make_directory_all(path[:slash]) }
	existing := ""
	if data, err := os.read_entire_file(path, context.allocator); err == nil {
		existing = string(data)
		defer delete(data)
	}
	merged := bridge_config_merge(existing, hub_url, bridge_token, bridge_id)
	return os.write_entire_file(path, transmute([]byte)merged) == nil
}

bridge_write_token_file :: proc(path, token: string) -> bool {
	if strings.trim_space(path) == "" || strings.trim_space(token) == "" do return false
	if slash := strings.last_index_byte(path, '/'); slash > 0 { _ = bridge_make_directory_all(path[:slash]) }
	content := strings.concatenate({strings.trim_space(token), "\n"})
	defer delete(content)
	err := os.write_entire_file(path, content, os.Permissions{.Read_User, .Write_User})
	if err != nil {
		fmt.eprintln("failed to write bridge token file", path)
		return false
	}
	_ = os.chmod(path, os.Permissions{.Read_User, .Write_User})
	return true
}

// bridge_adopt_default_credential_if_needed falls back to the path `enroll --hub`
// writes when nothing else supplied a credential.
//
// WHY THIS IS A STARTUP STEP AND NOT PART OF bridge_config_from_args. It reads an
// ambient file in the user's home directory, and `bridge_config_from_args` is called
// directly by tests — so having the probe there made the suite's behaviour depend on
// whether a real credential happened to exist on the developer's machine (it did on
// mine right after an end-to-end run, and did not on the reviewer's). Resolving
// config and touching the filesystem are different jobs; only `main` does the second.
//
// WHY THE FALLBACK EXISTS AT ALL: the device flow deliberately stops writing the
// credential into config.toml (audit F2), which would otherwise leave
// `ham-bridge --hub <url>` with no token and the runtime logging "disabled: missing
// daemon_url or bridge_token" — trading a security defect for a usability one.
//
// It is reached ONLY when nothing else supplied a token, so it cannot override an
// explicit --bridge-token, --bridge-token-file, HAM_BRIDGE_TOKEN_FILE or a
// config.toml value: the one case it changes is the one that is broken anyway.
// `candidate` is passed in rather than resolved here so a test can point it at a
// file it created. Resolving it internally made the test vacuous: on a machine with
// no credential at the default location, the proc did nothing whatever the config
// said, so the assertions passed with BOTH early returns deleted.
bridge_adopt_default_credential_if_needed :: proc(cfg: ^Bridge_Config, candidate: string) {
	if strings.trim_space(cfg.bridge_token) != "" do return
	if strings.trim_space(cfg.credential_file) != "" do return
	default_credential := strings.trim_space(candidate)
	if default_credential == "" do return
	// Probed QUIETLY: an absent default file is the normal case for a bridge started
	// with an explicit token, and bridge_read_token_file would print a read failure
	// that reads like an error when nothing is wrong.
	if !os.exists(default_credential) do return
	token_from_default, default_ok := bridge_read_token_file(default_credential)
	if !default_ok do return
	cfg.bridge_token = token_from_default
	cfg.credential_file = strings.clone(default_credential)
	fmt.println("bridge credential loaded from the default location", default_credential)
}

bridge_read_token_file :: proc(path: string) -> (string, bool) {
	trimmed_path := strings.trim_space(path)
	if trimmed_path == "" do return "", false
	data, err := os.read_entire_file(trimmed_path, context.allocator)
	if err != nil {
		fmt.eprintln("failed to read bridge token file", trimmed_path)
		return "", false
	}
	// The returned string is a CLONE, so the file buffer is ours to release. It
	// previously leaked on every call, which the refresh worker turns from a
	// one-off into a per-rotation leak for the life of the process.
	defer delete(data)
	// An access-token file carries an owner header (credential_owner.odin); the
	// token is what follows it. Refresh files and hand-given tokens have none.
	text, _, _, _ := bridge_credential_split(string(data))
	if text == "" do return "", false
	return strings.clone(text), true
}

bridge_config_from_args :: proc(args: []string) -> Bridge_Config {
	cfg := Bridge_Config{
		bind_host = "127.0.0.1",
		port = 49323,
		fs_read_page_bytes = BRIDGE_FS_READ_PAGE_BYTES,
		daemon_url = "http://127.0.0.1:49322",
		daemon_id = "local-daemon",
		bridge_token = "",
		data_dir = "~/.local/share/heimdall",
		chunk_bytes = contracts.BRIDGE_WS_DEFAULT_CHUNK_BYTES,
		bootstrap_cache_max_bytes = 256 * 1024 * 1024,
		local_endpoint_port = 0,
		local_endpoint_run_dir = bridge_scratch_local_default(),
		local_proxy_enabled = true,
	}

	config_path := cfg_lib.config_path_from_args(args)
	if loaded, ok := cfg_lib.load(config_path); ok {
		cfg.daemon_url = loaded.config.wrapper.daemon_url
		cfg.daemon_id = loaded.config.daemon.daemon_id
		cfg.bridge_token = loaded.config.daemon.bridge_token
		cfg.data_dir = loaded.config.daemon.data_dir
		// Task System v2: the bridge no longer polls the hub for actionable tasks,
		// so the [bridge]/[daemon] nudge_* keys are parsed but ignored here.
		cfg.fs_root = loaded.config.bridge.fs_root
		if loaded.config.bridge.fs_read_page_bytes > 0 {
			cfg.fs_read_page_bytes = i64(loaded.config.bridge.fs_read_page_bytes)
		}
		cfg.pty_host_runtime = loaded.config.bridge.pty_host_runtime
		// REQ-XM-4: only an explicitly present [bridge].local_proxy_enabled key
		// overrides the enabled-by-default. --no-local-proxy is applied after the
		// config load below, so the CLI flag still wins over the file.
		if loaded.config.bridge.local_proxy_configured {
			cfg.local_proxy_enabled = loaded.config.bridge.local_proxy_enabled
		}
	}

	cfg.bind_host = option_value(args, "--bind-host", cfg.bind_host)
	cfg.daemon_url = option_value(args, "--daemon-url", cfg.daemon_url)
	cfg.daemon_url = option_value(args, "--hub", cfg.daemon_url)
	cfg.daemon_id = option_value(args, "--daemon-id", cfg.daemon_id)
	bridge_token_file := option_value(args, "--bridge-token-file", os.get_env("HAM_BRIDGE_TOKEN_FILE", context.allocator))
	// REQ-IMPL-4: remembered so the refresh worker knows which file to rewrite when
	// it rotates an expiring credential. Empty when the token came from --bridge-token
	// or config.toml, and the worker then declines to rotate rather than rotating
	// into memory only and losing the new credential at the next restart.
	cfg.credential_file = strings.trim_space(bridge_token_file)
	if token_from_file, token_file_ok := bridge_read_token_file(bridge_token_file); token_file_ok do cfg.bridge_token = token_from_file
	cfg.bridge_token = option_value(args, "--bridge-token", cfg.bridge_token)
	if port_s := option_value(args, "--port", ""); port_s != "" {
		if port_i, ok := strconv.parse_int(port_s); ok do cfg.port = u16(port_i)
	}
	if chunk_s := option_value(args, "--chunk-bytes", ""); chunk_s != "" {
		if chunk_i, ok := strconv.parse_int(chunk_s); ok do cfg.chunk_bytes = int(chunk_i)
	}
	if fs_page_s := option_value(args, "--fs-read-page-bytes", ""); fs_page_s != "" {
		if fs_page_i, ok := strconv.parse_int(fs_page_s); ok && fs_page_i > 0 do cfg.fs_read_page_bytes = i64(fs_page_i)
	}
	if cache_bytes_s := option_value(args, "--bootstrap-cache-max-bytes", ""); cache_bytes_s != "" {
		if cache_bytes_i, ok := strconv.parse_int(cache_bytes_s); ok do cfg.bootstrap_cache_max_bytes = int(cache_bytes_i)
	}
	if local_port_s := option_value(args, "--local-endpoint-port", ""); local_port_s != "" {
		if local_port_i, ok := strconv.parse_int(local_port_s); ok do cfg.local_endpoint_port = u16(local_port_i)
	}
	// REQ-XM-4: default is enabled, so only the negative flag is wired here.
	if has_flag(args, "--no-local-proxy") do cfg.local_proxy_enabled = false
	cfg.local_endpoint_run_dir = option_value(args, "--local-run-dir", cfg.local_endpoint_run_dir)
	cfg.data_dir = option_value(args, "--data-dir", cfg.data_dir)
	// Expand a leading ~ in data_dir. The default (and typical config value) is
	// "~/.local/share/heimdall", but nothing expanded it before, so a bridge whose
	// cwd is not $HOME (e.g. launchd starts it with cwd=/) resolved the bootstrap
	// blob cache to a LITERAL "~/.local/share/heimdall" directory. That made every
	// cache lookup miss and every cache_put fail its file write, so bootstrap blob
	// resolution failed with "blob hash verify/cache failed" and NO agent could
	// launch. Expand here so the cache always lands under the real home dir
	// regardless of the process working directory.
	cfg.data_dir = cfg_lib.expand_home(cfg.data_dir)
	return cfg
}

bridge_runtime_init :: proc() {
	bridge_sequence = 0
}

bridge_next_id :: proc(prefix: string) -> string {
	bridge_sequence += 1
	return fmt.tprintf("%s_%d_%d", prefix, bridge_now_unix_ms(), bridge_sequence)
}

run_bridge_server :: proc(cfg: Bridge_Config) -> bool {
	address := net.IP4_Loopback
	if cfg.bind_host != "127.0.0.1" {
		if parsed, ok := net.parse_ip4_address(cfg.bind_host); ok do address = parsed
	}
	listener, err := net.listen_tcp({address, int(cfg.port)})
	if err != nil {
		fmt.println("failed to listen", cfg.bind_host, cfg.port, "error:", err)
		return false
	}
	if !bridge_os_socket_close_on_exec(i64(listener)) {
		net.close(listener)
		fmt.println("failed to secure listener", cfg.bind_host, cfg.port, "against child-process inheritance")
		return false
	}
	defer net.close(listener)
	fmt.println("ham-bridge listening", cfg.bind_host, cfg.port, "daemon_url", cfg.daemon_url)
	for {
		client, _, accept_err := net.accept_tcp(listener)
		if accept_err != nil do continue
		thread.run_with_poly_data(client, handle_bridge_client)
	}
}

handle_bridge_client :: proc(client: net.TCP_Socket) {
	defer net.close(client)
	request, ok := read_http_request(client)
	if !ok do return
	method, route := request_method_route(request)
	if method == "OPTIONS" {
		write_response(client, 200, "OK", `{}`)
		return
	}
	if method == "GET" && route == "/api/v1/telemetry/agents-count" {
		body := bridge_telemetry_agents_count_json()
		defer delete(body)
		write_response(client, 200, "OK", body)
		return
	}
	if !contracts.bridge_route_supported(.Bridge, method, route) {
		write_response(client, 404, "Not Found", bridge_unsupported_route_json(method, route))
		return
	}
	if !bridge_loopback_authorized(request) {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"bridge loopback unauthorized"}`)
		return
	}
	switch route {
	case contracts.ROUTE_BRIDGE_HEALTH:
		write_response(client, 200, "OK", bridge_health_json())
	case contracts.ROUTE_BRIDGE_VALIDATE_PROJECT_PATH:
		bridge_handle_validate_project_path(client, request_body(request))
	case:
		write_response(client, 404, "Not Found", bridge_unsupported_route_json(method, route))
	}
}

// bridge_loopback_authorized gates every loopback route on the bridge's own token.
//
// ===== AUDIT F4: THIS NOW FAILS CLOSED (REQ-ENROLL-9) =====
//
// The first line used to read:
//
//     if strings.trim_space(bridge_config.bridge_token) == "" do return true
//
// A BLANK CONFIGURED TOKEN AUTHORISED EVERYTHING. That is not a narrow edge case:
// a bridge is token-less for its entire life before it enrolls, and a bridge whose
// token file is missing, empty or unreadable is token-less too. In every one of
// those states the loopback surface — which spawns agents and reads project files —
// was open to any local process, with no credential at all.
//
// WHY IT WAS SAFE TO FLIP ONLY NOW, AND WHY IT WAS NOT SAFE EARLIER. The permissive
// branch had exactly one legitimate consumer: a locally started bridge that had been
// given no token, which is how the old static-token path let a developer run a stack
// without enrolling. Flipping it while that path still existed would have broken
// every such bridge — including the `dev-stack.sh` harnesses other agents in this
// chain are running. REQ-IMPL-6 deletes the static-token path and rewrites
// `dev-stack.sh` to enroll through the device flow, so the only configuration that
// relied on fail-open no longer exists. REQ-IMPL-4 had already closed the narrower
// case, refusing to persist an empty credential or to start enrolled-but-tokenless.
//
// The consequence is intended: a bridge with no usable credential serves NOTHING on
// loopback. That is the correct posture — an unenrolled bridge has no owner, so
// there is no one whose authority it could be acting on.
bridge_loopback_authorized :: proc(request: string) -> bool {
	credential_snapshot_633 := bridge_credential_snapshot()
	defer delete(credential_snapshot_633)
	configured := strings.trim_space(credential_snapshot_633)
	if configured == "" do return false
	auth := extract_header(request, contracts.BRIDGE_LOOPBACK_AUTH_HEADER)
	// Compared against the TRIMMED token so the blank test above and the equality
	// test below agree on what the token is. bridge_read_token_file already trims,
	// so this only affects a token supplied via config.toml `daemon.bridge_token`
	// or `--bridge-token`, neither of which is trimmed on the way in: such a value
	// with surrounding whitespace used to pass the blank test and then reject every
	// correctly-formed request. Narrow, but it is a silent-misauthentication bug,
	// and the two tests disagreeing is what caused it.
	// The expected value is built on the heap and freed here. It leaked on every
	// loopback request before — harmless-looking at a few bytes a call, but this is
	// the hot path for every agent spawn and file read, so it accumulated for the
	// life of the process. Surfaced by the tracking allocator once this proc finally
	// had tests exercising it.
	expected := strings.concatenate({contracts.BRIDGE_AUTH_BEARER_PREFIX, configured})
	defer delete(expected)
	return auth == expected
}

bridge_health_json :: proc() -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"contract_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION))
	strings.write_string(&b, `,"ws_frame_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_WS_FRAME_VERSION))
	strings.write_string(&b, `,"self_daemon_id":"`); json_write_string(&b, bridge_config.daemon_id)
	strings.write_string(&b, `","bridge_id":"ham-bridge","chunk_bytes":`)
	strings.write_string(&b, fmt.tprintf("%d", bridge_config.chunk_bytes))
	strings.write_string(&b, `,"large_payload_target_bytes":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_WS_LARGE_PAYLOAD_TARGET_BYTES))
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

bridge_handle_validate_project_path :: proc(client: net.TCP_Socket, body: string) {
	write_response(client, 200, "OK", bridge_project_path_validation_result_json(body))
}

bridge_project_path_validation_result_json :: proc(body: string, use_cache: bool = true) -> string {
	command_id := extract_json_string(body, "command_id", "")
	if use_cache { if cached, cached_ok := bridge_validation_command_cached(command_id); cached_ok do return cached }
	project_id := extract_json_string(body, "project_id", "")
	path := extract_json_string(body, "path", "")
	vcs_kind := extract_json_string(body, "vcs_kind", "")
	repo_url := extract_json_string(body, "repo_url", "")
	defer if !use_cache { delete(command_id); delete(project_id); delete(path); delete(vcs_kind); delete(repo_url) }
	result := bridge_validate_project_path_local(path, vcs_kind, repo_url)
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"project_path_validation_result\",\"command_id\":\""); json_write_string(&b, command_id)
	strings.write_string(&b, "\",\"project_id\":\""); json_write_string(&b, project_id)
	strings.write_string(&b, "\",\"path\":\""); json_write_string(&b, path)
	strings.write_string(&b, "\",")
	if result.ok {
		strings.write_string(&b, "\"ok\":true}")
	} else {
		bridge_write_failure(&b, bridge_cause_wire_error(result.error_code if result.error_code != "" else "path_validation_failed", result.message))
		strings.write_string(&b, "}")
	}
	result_json := strings.to_string(b)
	if use_cache do bridge_validation_command_store(command_id, result_json)
	return result_json
}

bridge_unsupported_route_json :: proc(method, route: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{`)
	bridge_write_failure(&b, bridge_cause_wire_error(contracts.BRIDGE_ERROR_UNSUPPORTED_ROUTE, "unsupported bridge route"))
	strings.write_string(&b, `,"method":"`)
	json_write_string(&b, method)
	strings.write_string(&b, `","route":"`)
	json_write_string(&b, route)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

bridge_payload_needs_chunking :: proc(payload: []byte) -> bool {
	return len(payload) > bridge_config.chunk_bytes
}

bridge_ws_chunk_count :: proc(total_bytes, chunk_bytes: int) -> int {
	if total_bytes <= 0 do return 0
	effective_chunk_bytes := chunk_bytes
	if effective_chunk_bytes <= 0 do effective_chunk_bytes = contracts.BRIDGE_WS_DEFAULT_CHUNK_BYTES
	return ws.chunk_count(total_bytes, effective_chunk_bytes)
}

read_http_request :: proc(client: net.TCP_Socket) -> (string, bool) {
	buf: [4096]byte
	n, recv_err := net.recv_tcp(client, buf[:])
	if recv_err != nil || n <= 0 do return "", false
	request := strings.clone(string(buf[:n]))
	for !http_request_complete(request) {
		m, err := net.recv_tcp(client, buf[:])
		if err != nil || m <= 0 do break
		request = strings.concatenate({request, string(buf[:m])})
	}
	return request, true
}

http_request_complete :: proc(request: string) -> bool {
	head_end := strings.index(request, "\r\n\r\n")
	if head_end < 0 do return false
	content_length := request_content_length(request)
	if content_length <= 0 do return true
	body_len := len(request) - (head_end + 4)
	return body_len >= content_length
}

request_body :: proc(request: string) -> string {
	if idx := strings.index(request, "\r\n\r\n"); idx >= 0 do return request[idx + 4:]
	return ""
}

request_content_length :: proc(request: string) -> int {
	value := extract_header(request, "Content-Length")
	if value == "" do value = extract_header(request, "content-length")
	if value == "" do return 0
	if parsed, ok := strconv.parse_int(value); ok do return int(parsed)
	return 0
}

extract_header :: proc(request, name: string) -> string {
	pattern := fmt.tprintf("%s:", name)
	idx := strings.index(request, pattern)
	if idx < 0 do return ""
	start := idx + len(pattern)
	end := strings.index(request[start:], "\r\n")
	if end < 0 do return ""
	return strings.trim_space(request[start:start + end])
}

bridge_tcp_send_all :: proc(client: net.TCP_Socket, data: []byte) -> bool {
	sent_total := 0
	for sent_total < len(data) {
		sent, err := net.send_tcp(client, data[sent_total:])
		if err != nil || sent <= 0 do return false
		sent_total += sent
	}
	return true
}

write_response :: proc(client: net.TCP_Socket, status: int, status_text, body: string) {
	builder := strings.builder_make()
	strings.write_string(&builder, fmt.tprintf("HTTP/1.1 %d %s\r\n", status, status_text))
	strings.write_string(&builder, "Content-Type: application/json\r\n")
	strings.write_string(&builder, fmt.tprintf("Content-Length: %d\r\n", len(body)))
	strings.write_string(&builder, "Access-Control-Allow-Origin: *\r\n")
	strings.write_string(&builder, "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n")
	strings.write_string(&builder, "Access-Control-Allow-Headers: Content-Type, Authorization\r\n")
	strings.write_string(&builder, "Connection: close\r\n\r\n")
	header_bytes := transmute([]byte)strings.to_string(builder)
	if !bridge_tcp_send_all(client, header_bytes) do return
	if len(body) > 0 do _ = bridge_tcp_send_all(client, transmute([]byte)body)
}

write_ws_upgrade :: proc(client: net.TCP_Socket, accept_key: string) {
	response := fmt.tprintf("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept_key)
	net.send_tcp(client, transmute([]byte)response)
}

ws_accept_key :: proc(key: string) -> string {
	GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	combined := fmt.tprintf("%s%s", key, GUID)
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]byte)combined)
	digest: [sha1.DIGEST_SIZE]byte
	sha1.final(&ctx, digest[:])
	return base64.encode(digest[:])
}

// bridge_hub_runtime_chunk_payload_bytes returns the raw bytes-per-chunk for the
// bridge->hub runtime WS channel. The pinned in-process libcurl transport safely
// carries the existing 45 KiB application frames and has no subprocess pipe cap.
bridge_hub_runtime_chunk_payload_bytes :: proc() -> int {
	return contracts.BRIDGE_WS_HUB_RUNTIME_CHUNK_PAYLOAD_BYTES_SOCAT
}

// bridge_hub_chunk_frames returns the ordered kind:"chunk" wire frames for `text`
// when it exceeds the bridge<->hub runtime per-message cap, or nil when `text`
// already fits in one frame (send it whole). Pure and socket-free so it can be
// unit-tested: base64-decoding each frame's payload_fragment and concatenating in
// index order reconstructs `text` exactly. Reuses the same frame shape as the
// federation sender (bridge_ws_chunk_json).
bridge_hub_chunk_frames :: proc(text: string) -> []string {
	return bridge_hub_chunk_frames_with_payload(text, bridge_hub_runtime_chunk_payload_bytes())
}

// bridge_hub_chunk_frames_with_payload is the pure core of bridge_hub_chunk_frames
// with the per-chunk raw byte size passed in explicitly. Splitting it out lets unit
// tests exercise a specific payload deterministically WITHOUT mutating the global
// process-global environment (the Odin test runner executes tests concurrently).
bridge_hub_chunk_frames_with_payload :: proc(text: string, payload: int) -> []string {
	return ws.chunk_frames(text, payload)
}

bridge_ws_frame_is_chunk :: proc(text: string) -> bool {
	return ws.frame_is_chunk(text)
}

// bridge_hub_send writes one outbound frame to the hub-runtime WS, transparently
// chunking any frame larger than the ~16 KiB edge-proxy per-message cap into
// ordered kind:"chunk" frames the hub reassembles by chunk_id (see the hub's
// bridge_ws_reassemble_chunk). Small frames pass through unchanged.
//
// THE PROPERTY THIS MUST PRESERVE: one chunk SEQUENCE reaches the hub contiguously.
// The hub reassembles by chunk_id, so another frame's CHUNKS may not appear between
// this sequence's chunks. (Whole non-chunk frames — a heartbeat between chunks — are
// fine and always were: the hub passes those straight through while a reassembly is
// in flight.) That is a coarser requirement than the byte-level one below, and the
// two are enforced by DIFFERENT locks. REQ-SHELL-32.
//
// HOW IT IS ACHIEVED TODAY, and the history that matters:
// There are TWO writers on this connection, not one. The hub-runtime loop thread
// (bridge_hub_runtime_loop) writes, AND so does one background stream worker per
// active PTY stream (pty_host_stream_worker.odin), each handed the same `conn`.
//   - BYTE-level serialisation — no two writers interleaving bytes WITHIN one frame —
//     is ws.Connection.send_mu, taken inside ws.send_text itself. It lives with the
//     socket, so no caller can bypass it.
//   - SEQUENCE-level serialisation — the property named at the top — is
//     _bridge_hub_send_mu here, held across the whole multi-frame loop below.
//
// This comment previously asserted the opposite: that a single loop thread was the
// only writer, and that a mutex should be added "here" if that ever changed. Both
// had already stopped being true. The bug that produced REQ-SHELL-32 was written by
// satisfying that sentence's letter — a lock was added HERE, in bridge_hub_send — and
// leaving the loop thread's own four direct ws.send_text calls unlocked. A lock only
// one party takes serialises nothing. The text is rewritten rather than deleted so
// that failure is legible to the next reader.
//
// >>> DO NOT DELETE EITHER LOCK AS REDUNDANT. <<<
// They enforce different properties and neither implies the other. Note the honest
// frequency: the sequence lock only has multi-frame work to do when a frame exceeds
// bridge_hub_runtime_chunk_payload_bytes() — 45000 on the socat default, so rarely —
// but "rarely" is not "never", and on the s_client path the threshold is 6000.
//
// Still ACK-LESS: unlike the federation sender we do NOT wait for a chunk_ack. The
// hub-runtime channel has no ack path, and with both locks held in order the hub sees
// the chunks in order anyway, so per-chunk acks would be pure latency.
@(private = "file")
_bridge_hub_send_mu: sync.Mutex

bridge_hub_send :: proc(conn: ^ws.Connection, text: string) -> bool {
	if bridge_command_worker_capture_send(conn, text) do return true
	sync.mutex_lock(&_bridge_hub_send_mu)
	defer sync.mutex_unlock(&_bridge_hub_send_mu)
	frames := bridge_hub_chunk_frames(text)
	if frames == nil do return ws.send_text(conn, text)
	defer delete(frames)
	// Send in order, stopping on the first failed write, but always free every
	// frame string (bridge_ws_chunk_json allocates each) so a large read never
	// leaks on this hot path.
	all_sent := true
	started := time.tick_now()
	for f in frames {
		remaining := ws.WRITE_DEADLINE - time.tick_since(started)
		if all_sent && !ws.send_text_with_deadline(conn, f, remaining) do all_sent = false
		delete(f)
	}
	return all_sent
}

// bridge_hub_send_binary writes one BINARY frame (a pty_wire session frame) to the
// hub-runtime WS. Binary frames are NEVER chunked: the kind:"chunk" re-splitter is a
// text/base64 envelope and would reintroduce exactly the overhead REQ-PTY-NET-2 removes.
// The pty drain sizes its frames to fit (bridge_pty_stream_emit_caps); an over-cap frame
// here is a programming error and is refused loudly rather than silently dropped by the
// edge proxy.
bridge_hub_send_binary :: proc(conn: ^ws.Connection, frame: []byte) -> bool {
	if len(frame) > bridge_hub_runtime_chunk_payload_bytes() {
		fmt.eprintfln("bridge WARN binary frame exceeds the hub-runtime per-message cap and was NOT sent bytes=%d cap=%d", len(frame), bridge_hub_runtime_chunk_payload_bytes())
		return true // the connection is healthy; only this frame is lost
	}
	sync.mutex_lock(&_bridge_hub_send_mu)
	defer sync.mutex_unlock(&_bridge_hub_send_mu)
	return ws.send_binary(conn, frame)
}

bridge_ws_chunk_json :: proc(chunk_id: string, chunk_index, chunk_count, total_bytes: int, fragment: string) -> string {
	return ws.chunk_json(chunk_id, chunk_index, chunk_count, total_bytes, fragment)
}

json_write_string :: proc(builder: ^strings.Builder, value: string) {
	for ch in value {
		switch ch {
		case '\\': strings.write_string(builder, "\\\\")
		case '"': strings.write_string(builder, "\\\"")
		case '\n': strings.write_string(builder, "\\n")
		case '\r': strings.write_string(builder, "\\r")
		case '\t': strings.write_string(builder, "\\t")
		case:
			if ch < 32 {
				strings.write_string(builder, fmt.tprintf("\\u%04x", ch))
			} else {
				strings.write_rune(builder, ch)
			}
		}
	}
}

extract_json_string :: proc(body, key, fallback: string, allocator := context.allocator) -> string {
	return jsonx.extract_string(body, key, fallback, false, allocator)
}

json_unescape :: proc(value: string, allocator := context.allocator) -> string {
	return jsonx.json_unescape_string(value, allocator)
}

extract_json_int :: proc(body, key: string, fallback: int) -> int {
	return jsonx.extract_int(body, key, fallback)
}

extract_json_bool :: proc(body, key: string, fallback: bool) -> bool {
	return jsonx.extract_bool(body, key, fallback)
}


option_value :: proc(args: []string, name, fallback: string) -> string {
	for i in 0..<len(args) {
		if args[i] == name && i + 1 < len(args) do return args[i + 1]
	}
	return fallback
}

request_method_route :: proc(request: string) -> (method: string, route: string) {
	first_space := strings.index_byte(request, ' ')
	if first_space < 0 do return "", ""
	method = request[:first_space]
	path_start := first_space + 1
	path_end_rel := strings.index_byte(request[path_start:], ' ')
	if path_end_rel < 0 do return method, ""
	path := request[path_start:path_start + path_end_rel]
	if q := strings.index_byte(path, '?'); q >= 0 do path = path[:q]
	return method, path
}

has_flag :: proc(args: []string, flag: string) -> bool {
	for arg in args {
		if arg == flag do return true
	}
	return false
}

bridge_now_unix_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

// Resolves the running bridge's vault keyring (HKR2, lib/vault). The OS store
// lookup is scoped to bridge_config.daemon_id, so another bridge of the same OS
// user is never read (REQ-T5-2). The caller wipes the result (vault.keyring_wipe).
//
// HEIMDALL_VAULT_KEYRING (standard base64 of the HKR2 bytes) is a single-bridge
// development override, global to the process environment. A set but invalid value
// is "no keyring" and does NOT fall through to the OS store.
bridge_read_vault_keyring :: proc() -> (vault.Vault_Keyring, bool) {
	if kr, present, ok := bridge_captured_env_keyring(); present do return kr, ok
	if env_val, found := os.lookup_env("HEIMDALL_VAULT_KEYRING", context.temp_allocator); found {
		kr, present, ok := bridge_keyring_from_env_value(env_val)
		if present do return kr, ok
	}
	return keystore_read_vault_keyring(bridge_config.daemon_id)
}

// bridge_current_vault_epoch returns the keyring's current epoch, or 0 when locked.
bridge_current_vault_epoch :: proc() -> u32 {
	kr, ok := bridge_read_vault_keyring()
	defer vault.keyring_wipe(&kr)
	if !ok do return 0
	return kr.current_epoch
}

// permissions_valid is kept for the vault.status wire shape; with no on-disk key
// source left it simply mirrors `configured`. key_length is the epoch key size.
bridge_vault_key_status :: proc() -> (configured: bool, permissions_valid: bool, key_length: int) {
	kr, ok := bridge_read_vault_keyring()
	defer vault.keyring_wipe(&kr)
	if !ok do return false, false, 0
	return true, true, vault.KEY_BYTES
}

// BRIDGE_PARENT_SESSION_ENV are the per-session markers an interactive Claude
// Code session exports to its children. A bridge started from such a session
// (dev stacks, manual runs) would pass them on through the pty-host to every
// agent, which then treats itself as a child session: transcript saving off,
// messaging wired to the parent. Configuration variables (provider, model,
// auth) are NOT in this list and keep flowing.
BRIDGE_PARENT_SESSION_ENV :: [?]string{
	"CLAUDECODE",
	"CLAUDE_CODE_ENTRYPOINT",
	"CLAUDE_CODE_SESSION_ID",
	"CLAUDE_CODE_CHILD_SESSION",
	"CLAUDE_CODE_SESSION_ATTENDED",
	"CLAUDE_CODE_MESSAGING_SOCKET",
	"CLAUDE_CODE_MESSAGING_TOKEN",
	"CLAUDE_CODE_EXECPATH",
	"CLAUDE_PID",
	"CLAUDE_EFFORT",
}

// The HEIMDALL_VAULT_KEYRING override as captured at startup (finding L3). main
// moves it out of the process environment before anything is spawned, so no
// agent, shell, pty-host or helper child can inherit the keyring.
@(private = "file")
g_bridge_env_keyring: vault.Vault_Keyring
@(private = "file")
g_bridge_env_keyring_present: bool
@(private = "file")
g_bridge_env_keyring_ok: bool
@(private = "file")
g_bridge_env_keyring_mu: sync.Mutex

// bridge_capture_keyring_env_override reads HEIMDALL_VAULT_KEYRING into memory and
// removes it from the environment. Returns false only if it could not be removed.
bridge_capture_keyring_env_override :: proc() -> bool {
	env_val, found := os.lookup_env("HEIMDALL_VAULT_KEYRING", context.temp_allocator)
	if !found do return true
	defer crypto.zero_explicit(raw_data(env_val), len(env_val))
	sync.mutex_lock(&g_bridge_env_keyring_mu)
	vault.keyring_wipe(&g_bridge_env_keyring)
	kr, present, ok := bridge_keyring_from_env_value(env_val)
	g_bridge_env_keyring, g_bridge_env_keyring_present, g_bridge_env_keyring_ok = kr, present, ok
	sync.mutex_unlock(&g_bridge_env_keyring_mu)
	_ = os.unset_env("HEIMDALL_VAULT_KEYRING")
	_, still := os.lookup_env("HEIMDALL_VAULT_KEYRING", context.temp_allocator)
	return !still
}

// bridge_captured_env_keyring returns a copy of the captured override (wipe it).
bridge_captured_env_keyring :: proc() -> (kr: vault.Vault_Keyring, present: bool, ok: bool) {
	sync.mutex_lock(&g_bridge_env_keyring_mu)
	defer sync.mutex_unlock(&g_bridge_env_keyring_mu)
	if !g_bridge_env_keyring_present do return {}, false, false
	if !g_bridge_env_keyring_ok do return {}, true, false
	return g_bridge_env_keyring, true, true
}

// bridge_forget_captured_env_keyring drops the captured override (tests).
bridge_forget_captured_env_keyring :: proc() {
	sync.mutex_lock(&g_bridge_env_keyring_mu)
	defer sync.mutex_unlock(&g_bridge_env_keyring_mu)
	vault.keyring_wipe(&g_bridge_env_keyring)
	g_bridge_env_keyring_present, g_bridge_env_keyring_ok = false, false
}

// bridge_strip_parent_session_env removes BRIDGE_PARENT_SESSION_ENV from the
// bridge's own environment at startup, before the pty-host or any agent is
// spawned, so nothing downstream inherits them.
bridge_strip_parent_session_env :: proc() {
	for key in BRIDGE_PARENT_SESSION_ENV do _ = os.unset_env(key)
}
