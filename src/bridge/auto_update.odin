package main

// Automatic updates use a quiet window, never a forced drain. The detached
// supervisor holds an OS-user-wide kernel lock until setup's verification (or
// rollback) completes, independently of the service it restarts.
import "core:encoding/json"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import cfg_lib "odin_test:lib/config"
import contracts "odin_test:contracts"
import bridgesvc "odin_test:lib/bridgesvc"
import httpc "odin_test:lib/httpc"
import ws "odin_test:lib/ws"

BRIDGE_AUTO_UPDATE_INTERVAL :: i64(6 * 60 * 60 * 1000)
BRIDGE_AUTO_UPDATE_QUIET_MS :: i64(60_000)

Bridge_Auto_Update_State :: struct {
	next_check_ms: i64,
	failures: int,
	pending_version: string,
}

bridge_auto_update_mutex: sync.Mutex
bridge_auto_update_launches: int
bridge_auto_update_reserved_until: i64

bridge_auto_update_delay :: proc(failures: int, entropy: u64) -> i64 {
	return bridge_backoff_delay_ms({base_ms = BRIDGE_AUTO_UPDATE_INTERVAL, max_ms = BRIDGE_AUTO_UPDATE_INTERVAL * 16, jitter_pct = 10}, max(1, failures), entropy)
}

bridge_auto_update_enabled :: proc(path: string) -> bool {
	context.allocator = context.temp_allocator
	loaded, ok := cfg_lib.load(path)
	if !ok do return false // an unreadable config must not authorize an update
	return !loaded.config.bridge.auto_update_configured || loaded.config.bridge.auto_update_enabled
}

bridge_auto_update_state_path :: proc(service: string) -> string {
	l := bridgesvc.layout_for(bridge_service_host(), service)
	return bridgesvc.pjoin(l.state_dir, "auto-update.json")
}

bridge_auto_update_read :: proc(path: string) -> Bridge_Auto_Update_State {
	state: Bridge_Auto_Update_State
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err == nil do _ = json.unmarshal(data, &state, allocator = context.temp_allocator)
	return state
}

bridge_auto_update_write :: proc(path: string, state: Bridge_Auto_Update_State) -> bool {
	data, err := json.marshal(state, allocator = context.temp_allocator)
	return err == nil && bridge_retry_atomic_write(path, data)
}

bridge_auto_update_newer :: proc(candidate, current: string) -> bool {
	return bridge_release_tag_valid(candidate) && bridge_provider_extension_version_compare(candidate, current) > 0
}

bridge_auto_update_resolve :: proc(fetch: Bridge_Hub_Fetch = bridge_hub_http_send, get: Bridge_Release_Get = bridge_release_http_get) -> string {
	credential := bridge_credential_snapshot()
	defer delete(credential)
	resp, err := fetch({method = .GET, url = bridge_hub_url(), path = {"api", "v1", "bridge", "update-catalog"}, headers = {httpc.bearer(credential)}, timeout_ms = 60_000, connect_timeout_ms = 15_000})
	defer httpc.response_destroy(&resp)
	if err == .None && resp.status == 200 {
		// The Hub resolves the promoted catalog for this authenticated bridge.
		body := httpc.text(resp)
		version := extract_json_string(body, "latest_version", "")
		defer delete(version)
		available := extract_json_bool(body, "artifact_available", false)
		if available && bridge_release_tag_valid(version) do return strings.clone(version)
	}
	target, blocked := bridge_release_target()
	if blocked do return ""
	doc, ok, _ := get("https://api.github.com/repos/" + BRIDGE_RELEASE_REPO + "/releases?per_page=30")
	if !ok do return ""
	version, detail := bridge_release_select(doc, target, "latest")
	if detail != "" do return ""
	return strings.clone(version)
}

// Both a launch in preparation and a recorded live child prevent a quiet window.
// Reservation and launch admission use the same mutex, closing the check/spawn race.
bridge_auto_update_launch_enter :: proc() -> bool {
	sync.mutex_lock(&bridge_auto_update_mutex)
	defer sync.mutex_unlock(&bridge_auto_update_mutex)
	if bridge_runtime_now_ms() < bridge_auto_update_reserved_until do return false
	bridge_auto_update_launches += 1
	return true
}

bridge_auto_update_launch_leave :: proc() {
	sync.mutex_lock(&bridge_auto_update_mutex)
	bridge_auto_update_launches -= 1
	sync.mutex_unlock(&bridge_auto_update_mutex)
}

bridge_auto_update_quiet :: proc(reserve := false) -> bool {
	return bridge_auto_update_quiet_with_host(reserve)
}

// The PTY host survives bridge restarts; the current process launch map does not.
// Inspect the own-profile socket without starting or replacing its daemon.
bridge_auto_update_quiet_with_host :: proc(
	reserve := false,
	list: proc(socket: string) -> (Pty_Host_Reply, bool) = bridge_pty_host_list,
) -> bool {
	sync.mutex_lock(&bridge_auto_update_mutex)
	defer sync.mutex_unlock(&bridge_auto_update_mutex)
	if bridge_auto_update_launches > 0 do return false
	sync.mutex_lock(&bridge_runtime_mutex)
	count := len(bridge_runtime_launches)
	sync.mutex_unlock(&bridge_runtime_mutex)
	if count != 0 do return false
	socket := pty_host_socket_path()
	defer delete(socket)
	reply, ok := list(socket)
	if !ok do return false // unavailable live state cannot authorize a restart
	defer pty_host_reply_delete(reply)
	if len(reply.agents) != 0 do return false
	if reserve do bridge_auto_update_reserved_until = bridge_runtime_now_ms() + 30 * 60_000
	return true
}

bridge_auto_update_start :: proc() {
	_, refusal := bridge_update_via_ham_bridge(contracts.APP_VERSION)
	if refusal == "" do thread.run(bridge_auto_update_worker)
}

bridge_auto_update_worker :: proc() {
	service, _ := bridge_update_via_ham_bridge(contracts.APP_VERSION)
	path := strings.clone(bridge_auto_update_state_path(service))
	defer delete(path)
	config := strings.clone(cfg_lib.config_path_from_args(os.args))
	defer delete(config)
	quiet_since: i64
	for {
		bridge_auto_update_tick(service, config, path, &quiet_since, bridge_runtime_now_ms())
		free_all(context.temp_allocator)
		time.sleep(30 * time.Second)
	}
}

bridge_auto_update_latest :: proc() -> string { return bridge_auto_update_resolve() }

bridge_auto_update_tick :: proc(
    service, config, path: string, quiet_since: ^i64, now: i64,
    resolve: proc() -> string = bridge_auto_update_latest,
    spawn: proc(argv: []string) -> bool = bridge_os_spawn_new_session,
    quiet: proc(reserve: bool) -> bool = bridge_auto_update_quiet,
) {
	state := bridge_auto_update_read(path)
	if !bridge_auto_update_enabled(config) {
		quiet_since^ = 0
	} else if state.next_check_ms == 0 {
		state.next_check_ms = now + bridge_auto_update_delay(0, rand.uint64())
		_ = bridge_auto_update_write(path, state)
	} else if now >= state.next_check_ms {
		if !quiet(false) {
			quiet_since^ = 0
		} else if quiet_since^ == 0 {
			quiet_since^ = now
		} else if now - quiet_since^ >= BRIDGE_AUTO_UPDATE_QUIET_MS {
			version := resolve()
			newer := bridge_auto_update_newer(version, contracts.APP_VERSION)
			// Network lookup can take a while. If an agent started in that time,
			// wait for another quiet window without counting an update failure.
			if newer && (!bridge_auto_update_enabled(config) || !quiet(true)) {
				delete(version)
				quiet_since^ = 0
				return
			}
			// Persist conservative backoff BEFORE detaching. A crashed or rolled
			// back supervisor cannot create a restart/update loop.
			if version == "" || newer do state.failures += 1
			else do state.failures = 0
			state.next_check_ms = now + bridge_auto_update_delay(state.failures, rand.uint64())
			state.pending_version = version if newer else ""
			persisted := bridge_auto_update_write(path, state)
			if persisted && newer && bridge_auto_update_enabled(config) {
				exe, _ := os.get_executable_path(context.temp_allocator)
				if !spawn({exe, "update", "--version", version, "--service", service, "--auto-worker"}) {
					sync.mutex_lock(&bridge_auto_update_mutex)
					bridge_auto_update_reserved_until = 0
					sync.mutex_unlock(&bridge_auto_update_mutex)
				}
			} else if newer {
				sync.mutex_lock(&bridge_auto_update_mutex)
				bridge_auto_update_reserved_until = 0
				sync.mutex_unlock(&bridge_auto_update_mutex)
			}
			delete(version)
			quiet_since^ = 0
		}
	}
	// A supervisor that failed before restarting the bridge clears pending.
	if state.pending_version == "" {
		sync.mutex_lock(&bridge_auto_update_mutex)
		bridge_auto_update_reserved_until = 0
		sync.mutex_unlock(&bridge_auto_update_mutex)
	}
}

// Shared across all hubs/accounts/profiles of the OS user. Kernel ownership
// survives the service stop and is released even when the supervisor crashes.
bridge_auto_update_lock_path :: proc() -> string {
	return bridgesvc.pjoin(bridge_service_host().home, ".heimdall-auto-update.lock")
}

bridge_auto_update_finish :: proc(service: string, success: bool) {
	path := bridge_auto_update_state_path(service)
	bridge_auto_update_finish_at(path, success, bridge_runtime_now_ms(), rand.uint64())
}

bridge_auto_update_finish_at :: proc(path: string, success: bool, now: i64, entropy: u64) {
	state := bridge_auto_update_read(path)
	state.pending_version = ""
	if success do state.failures = 0
	else do state.failures = max(1, state.failures)
	state.next_check_ms = now + bridge_auto_update_delay(state.failures, entropy)
	_ = bridge_auto_update_write(path, state)
}

// Update only the bridge section, preserving other settings and comments.
bridge_auto_update_config_text :: proc(text: string, enabled: bool) -> string {
	b := strings.builder_make(allocator = context.temp_allocator)
	inside, seen := false, false
	rest := text
	line_value := "auto_update_enabled = true\n" if enabled else "auto_update_enabled = false\n"
	for line in strings.split_lines_iterator(&rest) {
		trim := strings.trim_space(cfg_lib.strip_comment(line))
		if strings.has_prefix(trim, "[") {
			if inside && !seen {strings.write_string(&b, line_value); seen = true}
			inside = trim == "[bridge]"
		}
		if inside && strings.trim_space(strings.split(trim, "=", context.temp_allocator)[0]) == "auto_update_enabled" {
			if !seen do strings.write_string(&b, line_value)
			seen = true
			continue
		}
		strings.write_string(&b, line); strings.write_byte(&b, '\n')
	}
	if !seen {
		if !inside do strings.write_string(&b, "\n[bridge]\n")
		strings.write_string(&b, line_value)
	}
	return strings.to_string(b)
}

bridge_auto_update_handle_config :: proc(conn: ^ws.Connection, text: string) {
	id := extract_json_string(text, "command_id", "")
	defer delete(id)
	path := cfg_lib.expand_home(cfg_lib.config_path_from_args(os.args))
	ok := true
	if extract_json_bool(text, "write", false) {
		bytes, err := os.read_entire_file(path, context.temp_allocator)
		ok = err == nil
		if ok {
			updated := bridge_auto_update_config_text(string(bytes), extract_json_bool(text, "enabled", true))
			ok = bridge_retry_atomic_write(path, transmute([]byte)updated)
		}
	}
	data, _ := json.marshal(struct {type, command_id: string, ok, enabled: bool}{"auto_update_config_result", id, ok, bridge_auto_update_enabled(path)}, allocator = context.temp_allocator)
	_ = bridge_hub_send(conn, string(data))
}
