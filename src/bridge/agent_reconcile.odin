package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import httpc "odin_test:lib/httpc"

@(private = "file")
_bridge_agent_reconcile_running: bool
@(private = "file")
_bridge_agent_reconcile_mu: sync.Mutex

// bridge_agent_instance_extract_hub_instances parses the JSON response from Hub GET /api/v1/agent-instances
// and returns a map of instance_id -> runtime_status for all instances on this bridge.
// Caller owns the returned map and its cloned keys and values (use bridge_agent_instance_delete_hub_instances).
bridge_agent_instance_extract_hub_instances :: proc(
	body: string,
	allocator := context.allocator,
) -> (map[string]string, bool) {
	parsed, err := json.parse_string(body, json.DEFAULT_SPECIFICATION, false, allocator)
	if err != .None do return nil, false
	defer json.destroy_value(parsed, allocator)

	data_arr: json.Array
	if root_arr, is_arr := parsed.(json.Array); is_arr {
		data_arr = root_arr
	} else if root_obj, is_obj := parsed.(json.Object); is_obj {
		data_val, has_data := root_obj["data"]
		if !has_data do return nil, false
		arr, arr_ok := data_val.(json.Array)
		if !arr_ok do return nil, false
		data_arr = arr
	} else {
		return nil, false
	}

	hub_instances := make(map[string]string, 0, allocator)
	for item in data_arr {
		item_obj, is_obj := item.(json.Object)
		if !is_obj do continue

		id_val, has_id := item_obj["agent_instance_id"]
		if !has_id do continue
		id_str, id_is_str := id_val.(json.String)
		if !id_is_str do continue

		status_val, has_status := item_obj["runtime_status"]
		if !has_status do continue
		status_str, status_is_str := status_val.(json.String)
		if !status_is_str do continue

		id := string(id_str)
		status := string(status_str)
		if !(id in hub_instances) {
			hub_instances[strings.clone(id, allocator)] = strings.clone(status, allocator)
		}
	}
	return hub_instances, true
}

// bridge_agent_instance_delete_hub_instances frees the keys, values, and map returned by bridge_agent_instance_extract_hub_instances.
bridge_agent_instance_delete_hub_instances :: proc(hub_instances: ^map[string]string, allocator := context.allocator) {
	if hub_instances == nil do return
	for k, v in hub_instances {
		delete(k, allocator)
		delete(v, allocator)
	}
	delete(hub_instances^)
}

Bridge_Agent_Reconcile_Plan :: struct {
	to_preserve:      [dynamic]string,
	to_reap:          [dynamic]string,
	to_push_terminal: [dynamic]string,
}

// bridge_agent_instance_compute_reconcile_plan computes the bidirectional reconciliation actions (REQ-RECON-FIX-1):
// - Instances alive on pty-host where Hub status is NOT 'stopped' are preserved and reported running.
// - Instances alive on pty-host where Hub status IS 'stopped' (user stopped while disconnected) are reaped.
// - Instances that are reaped or unknown/dead on pty-host have terminal status pushed to Hub.
bridge_agent_instance_compute_reconcile_plan :: proc(
	pty_agents: []Pty_Host_Agent_Info,
	hub_instances: map[string]string,
	allocator := context.allocator,
) -> Bridge_Agent_Reconcile_Plan {
	plan := Bridge_Agent_Reconcile_Plan{
		to_preserve      = make([dynamic]string, allocator),
		to_reap          = make([dynamic]string, allocator),
		to_push_terminal = make([dynamic]string, allocator),
	}

	// 1. Evaluate physical reality (sessions on pty-host)
	for a in pty_agents {
		if !a.alive do continue
		if !strings.has_prefix(a.instance_id, "inst_") do continue

		hub_status, in_hub := hub_instances[a.instance_id]
		if in_hub && hub_status == "stopped" {
			// User explicitly stopped on Hub while disconnected -> reap on pty-host and push terminal status
			append(&plan.to_reap, strings.clone(a.instance_id, allocator))
			append(&plan.to_push_terminal, strings.clone(a.instance_id, allocator))
		} else {
			// Hub status is not 'stopped' (e.g. running, unreachable, starting, launching, or new)
			// Keep alive, register in runtime, report running
			append(&plan.to_preserve, strings.clone(a.instance_id, allocator))
		}
	}

	// 2. Evaluate Hub instances that are lingering in active statuses but not alive on pty-host
	for hub_id, hub_status in hub_instances {
		if !strings.has_prefix(hub_id, "inst_") do continue
		if hub_status == "stopped" do continue

		// Check if it is alive on pty-host
		is_alive_on_pty := false
		for a in pty_agents {
			if a.alive && a.instance_id == hub_id {
				is_alive_on_pty = true
				break
			}
		}

		if !is_alive_on_pty {
			// Not alive on pty-host (reaped or unknown). Check if already in to_push_terminal
			already_in := false
			for id in plan.to_push_terminal {
				if id == hub_id {
					already_in = true
					break
				}
			}
			if !already_in {
				append(&plan.to_push_terminal, strings.clone(hub_id, allocator))
			}
		}
	}

	return plan
}

bridge_agent_instance_plan_delete :: proc(plan: ^Bridge_Agent_Reconcile_Plan, allocator := context.allocator) {
	if plan == nil do return
	for id in plan.to_preserve do delete(id, allocator)
	delete(plan.to_preserve)
	for id in plan.to_reap do delete(id, allocator)
	delete(plan.to_reap)
	for id in plan.to_push_terminal do delete(id, allocator)
	delete(plan.to_push_terminal)
}

// bridge_agent_instance_reconcile_now reconciles surviving agent instances on ham-pty-host against
// the Hub's active instance list upon bridge connection / restart (REQ-REAP-STARTUP-1..5, REQ-RECON-FIX-1).
// Single-flight execution guarded by sync.Mutex.
bridge_agent_instance_reconcile_now :: proc() {
	sync.mutex_lock(&_bridge_agent_reconcile_mu)
	if _bridge_agent_reconcile_running {
		sync.mutex_unlock(&_bridge_agent_reconcile_mu)
		return
	}
	_bridge_agent_reconcile_running = true
	sync.mutex_unlock(&_bridge_agent_reconcile_mu)
	defer {
		sync.mutex_lock(&_bridge_agent_reconcile_mu)
		_bridge_agent_reconcile_running = false
		sync.mutex_unlock(&_bridge_agent_reconcile_mu)
	}

	credential_snapshot_168 := bridge_credential_snapshot()
	defer delete(credential_snapshot_168)
	if strings.trim_space(bridge_config.daemon_url) == "" || strings.trim_space(credential_snapshot_168) == "" {
		return
	}

	socket, sock_ok := bridge_pty_host_ensure_daemon()
	if !sock_ok do return

	reply, list_ok := bridge_pty_host_list(socket)
	if !list_ok do return
	defer pty_host_reply_delete(reply)

	credential_snapshot_181 := bridge_credential_snapshot()
	defer delete(credential_snapshot_181)
	headers := [?]httpc.Header{httpc.bearer(credential_snapshot_181)}

	resp, http_err := bridge_http_request_retry({
		method = .GET, url = bridge_hub_url(), path = {"api", "v1", "agent-instances"},
		query = {{"bridge_id", bridge_config.daemon_id}, {"limit", "200"}}, headers = headers[:],
	})
	defer httpc.response_destroy(&resp)
	if http_err != .None do return

	// If HTTP request fails or returns non-200, return early without reaping (fail-safe)
	if resp.status != 200 do return

	hub_instances, parse_ok := bridge_agent_instance_extract_hub_instances(httpc.text(resp))
	if !parse_ok do return
	defer bridge_agent_instance_delete_hub_instances(&hub_instances)

	plan := bridge_agent_instance_compute_reconcile_plan(reply.agents, hub_instances)
	defer bridge_agent_instance_plan_delete(&plan)

	// 1. Preserve surviving pty-host instances and report running to Hub
	for id in plan.to_preserve {
		now := bridge_runtime_now_ms()
		sync.mutex_lock(&bridge_runtime_mutex)
		bridge_runtime_set_status_locked(id, "running", "idle", now, true)
		bridge_runtime_set_pty_process_alive_locked(id, true)
		bridge_runtime_enqueue_status_push_locked(id)
		sync.mutex_unlock(&bridge_runtime_mutex)
		fmt.println("bridge agent reconcile: preserved live instance", id)
	}

	// 2. Reap instances on pty-host marked stopped by user
	for id in plan.to_reap {
		if bridge_pty_host_close(socket, id) {
			fmt.println("bridge agent reconcile: reaped stopped instance", id)
		}
		bridge_agent_token_invalidate_instance(id)
	}

	// 3. Push terminal status for reaped or unknown/dead instances so Hub DB does not linger in 'running'
	for id in plan.to_push_terminal {
		now := bridge_runtime_now_ms()
		sync.mutex_lock(&bridge_runtime_mutex)
		bridge_runtime_set_status_locked(id, "stopped", "idle", now, true)
		bridge_runtime_set_pty_process_alive_locked(id, false)
		bridge_runtime_enqueue_status_push_locked(id)
		sync.mutex_unlock(&bridge_runtime_mutex)
		fmt.println("bridge agent reconcile: pushed terminal status for instance", id)
	}
}
