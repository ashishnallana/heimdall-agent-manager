package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import http "odin_test:lib/http_client"

@(private = "file")
_bridge_shell_orphan_reconcile_running: bool
@(private = "file")
_bridge_shell_orphan_reconcile_mu: sync.Mutex

// bridge_shell_extract_active_ids parses the JSON response from Hub GET /api/v1/bridges/{bridge_id}/shells
// and returns a set of active shell IDs where status is "running" or "starting".
// Caller owns the returned map and its string keys (use bridge_shell_delete_active_ids).
bridge_shell_extract_active_ids :: proc(
	body: string,
	allocator := context.allocator,
) -> (map[string]bool, bool) {
	parsed, err := json.parse_string(body, json.DEFAULT_SPECIFICATION, false, allocator)
	if err != .None do return nil, false
	defer json.destroy_value(parsed, allocator)

	data_arr: json.Array
	found := false

	if root_arr, is_arr := parsed.(json.Array); is_arr {
		data_arr = root_arr
		found = true
	} else if root_obj, is_obj := parsed.(json.Object); is_obj {
		if data_val, has_data := root_obj["data"]; has_data {
			if arr, arr_ok := data_val.(json.Array); arr_ok {
				data_arr = arr
				found = true
			} else if data_obj, data_is_obj := data_val.(json.Object); data_is_obj {
				if sessions_val, has_sessions := data_obj["sessions"]; has_sessions {
					if arr, arr_ok := sessions_val.(json.Array); arr_ok {
						data_arr = arr
						found = true
					}
				} else if inner_data_val, has_inner_data := data_obj["data"]; has_inner_data {
					if arr, arr_ok := inner_data_val.(json.Array); arr_ok {
						data_arr = arr
						found = true
					}
				}
			}
		}
		if !found {
			if sessions_val, has_sessions := root_obj["sessions"]; has_sessions {
				if arr, arr_ok := sessions_val.(json.Array); arr_ok {
					data_arr = arr
					found = true
				}
			}
		}
	}

	if !found do return nil, false

	active_ids := make(map[string]bool, 0, allocator)
	for item in data_arr {
		item_obj, is_obj := item.(json.Object)
		if !is_obj do continue

		id_str := ""
		if id_val, has_id := item_obj["session_id"]; has_id {
			if s, is_str := id_val.(json.String); is_str do id_str = string(s)
		} else if id_val, has_id := item_obj["id"]; has_id {
			if s, is_str := id_val.(json.String); is_str do id_str = string(s)
		}
		if id_str == "" do continue

		if status_val, has_status := item_obj["status"]; has_status {
			if status_str, status_is_str := status_val.(json.String); status_is_str {
				if status_str != "running" && status_str != "starting" {
					continue
				}
			}
		}

		if !(id_str in active_ids) {
			active_ids[strings.clone(id_str, allocator)] = true
		}
	}
	return active_ids, true
}

// bridge_shell_delete_active_ids frees the keys and map returned by bridge_shell_extract_active_ids.
bridge_shell_delete_active_ids :: proc(active_ids: ^map[string]bool, allocator := context.allocator) {
	if active_ids == nil do return
	for k in active_ids {
		delete(k, allocator)
	}
	delete(active_ids^)
}

// bridge_shell_find_orphans compares live sessions on pty-host against the Hub active set.
// Only sessions starting with "sh_" and alive == true that are absent from active_hub_ids are returned.
// Non-sh_ sessions (e.g. "inst_") and dead sessions are strictly ignored.
// Caller owns the returned dynamic array and its string elements.
bridge_shell_find_orphans :: proc(
	pty_agents: []Pty_Host_Agent_Info,
	active_hub_ids: map[string]bool,
	allocator := context.allocator,
) -> [dynamic]string {
	orphans := make([dynamic]string, allocator)
	for a in pty_agents {
		if !a.alive do continue
		if !strings.has_prefix(a.instance_id, "sh_") do continue
		if a.instance_id in active_hub_ids do continue
		append(&orphans, strings.clone(a.instance_id, allocator))
	}
	return orphans
}

// bridge_shell_orphan_reconcile_now reconciles surviving shell sessions on ham-pty-host against
// the Hub's active shells list upon bridge connection / restart (REQ-REAP-SHELL-1..3).
// Single-flight execution guarded by sync.Mutex.
bridge_shell_orphan_reconcile_now :: proc() {
	sync.mutex_lock(&_bridge_shell_orphan_reconcile_mu)
	if _bridge_shell_orphan_reconcile_running {
		sync.mutex_unlock(&_bridge_shell_orphan_reconcile_mu)
		return
	}
	_bridge_shell_orphan_reconcile_running = true
	sync.mutex_unlock(&_bridge_shell_orphan_reconcile_mu)
	defer {
		sync.mutex_lock(&_bridge_shell_orphan_reconcile_mu)
		_bridge_shell_orphan_reconcile_running = false
		sync.mutex_unlock(&_bridge_shell_orphan_reconcile_mu)
	}

	credential_snapshot_135 := bridge_credential_snapshot()
	defer delete(credential_snapshot_135)
	if strings.trim_space(bridge_config.daemon_url) == "" || strings.trim_space(credential_snapshot_135) == "" {
		return
	}

	socket, sock_ok := bridge_pty_host_ensure_daemon()
	if !sock_ok do return

	reply, list_ok := bridge_pty_host_list(socket)
	if !list_ok do return
	defer pty_host_reply_delete(reply)

	headers := make([dynamic]http.Header)
	defer delete(headers)
	credential_snapshot_148 := bridge_credential_snapshot()
	defer delete(credential_snapshot_148)
	auth_header := strings.concatenate({"Bearer ", credential_snapshot_148})
	defer delete(auth_header)
	append(&headers, http.Header{name = "Authorization", value = auth_header})

	path := fmt.tprintf("/api/v1/bridges/%s/shells?status=running", bridge_config.daemon_id)
	resp, ok := bridge_http_request_retry("GET", bridge_config.daemon_url, path, "", headers[:], http.DEFAULT_TIMEOUT_MS)
	if !ok do return
	defer delete(resp.body)

	// If HTTP request fails or returns non-200, return early without reaping (fail-safe)
	if resp.status != 200 do return

	active_hub_ids, parse_ok := bridge_shell_extract_active_ids(resp.body)
	if !parse_ok do return
	defer bridge_shell_delete_active_ids(&active_hub_ids)

	orphans := bridge_shell_find_orphans(reply.agents, active_hub_ids)
	defer {
		for id in orphans do delete(id)
		delete(orphans)
	}

	raw_dir := strings.trim_space(bridge_config.data_dir)
	if raw_dir == "" do raw_dir = "~/.local/share/heimdall"
	data_dir := bridge_expand_home(raw_dir)
	defer if raw_data(data_dir) != raw_data(raw_dir) do delete(data_dir)

	for orphan_id in orphans {
		bridge_pty_host_close(socket, orphan_id)
		fmt.println("bridge pty-host: reaped orphaned shell session", orphan_id, "(not live in hub)")
		bridge_shell_session_delete_spec(data_dir, orphan_id)
		alt_path := strings.concatenate({strings.trim_right(data_dir, "/"), "/shells/", orphan_id, ".json"})
		_ = os.remove(alt_path)
		delete(alt_path)
	}
}
