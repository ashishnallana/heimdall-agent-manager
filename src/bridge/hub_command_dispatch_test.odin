package main

import "core:strings"
import "core:sync"
import "core:testing"
import ws "odin_test:lib/ws"

@(test)
bridge_dispatch_queue_take_transfers_job_ownership :: proc(t: ^testing.T) {
	queue := make([dynamic]Bridge_Dispatch_Job)
	defer delete(queue)
	append(&queue, Bridge_Dispatch_Job{
		text = strings.clone(`{"type":"provider_discover"}`),
		command_id = strings.clone("cmd_take"),
		command_type = strings.clone("provider_discover"),
		generation = 7,
		owned_bytes = 64,
		cost_units = 16,
	})

	job, ok := bridge_command_dispatch_take_queue_locked(&queue)
	testing.expect(t, ok, "queued job is available")
	testing.expect_value(t, len(queue), 0)
	testing.expect_value(t, job.command_id, "cmd_take")
	testing.expect_value(t, job.command_type, "provider_discover")
	testing.expect_value(t, job.generation, i64(7))
	testing.expect(t, strings.contains(job.text, "provider_discover"), "worker retains the owned command body")
	delete(job.text)
	delete(job.command_id)
	delete(job.command_type)
	delete(job.ordering_key)
}

@(test)
bridge_dispatch_classifies_blocking_incident_paths :: proc(t: ^testing.T) {
	lifecycle, lifecycle_ok := bridge_command_dispatch_class("launch_agent")
	background, background_ok := bridge_command_dispatch_class("provider_discover")
	models, models_ok := bridge_command_dispatch_class("provider_models_discover")
	ext_install, ext_install_ok := bridge_command_dispatch_class("provider_extension_install")
	interactive, interactive_ok := bridge_command_dispatch_class("notify_task_nudge")
	exclusive, exclusive_ok := bridge_command_dispatch_class("bridge_update")
	general_io, general_io_ok := bridge_command_dispatch_class("vcs_status")
	shell, shell_ok := bridge_command_dispatch_class("shell_start")
	_, heartbeat_async := bridge_command_dispatch_class("bridge_heartbeat_ack")
	_, tunnel_async := bridge_command_dispatch_class("tunnel_data")
	testing.expect(t, lifecycle_ok && lifecycle == .Lifecycle, "agent launch must use the isolated lifecycle lane")
	testing.expect(t, background_ok && background == .Background, "provider discovery must use the shed-first background lane")
	testing.expect(t, models_ok && models == .Model_Discovery, "slow model probes have their own lane")
	testing.expect(t, ext_install_ok && ext_install == .Background, "provider extension install must use the background lane")
	testing.expect(t, interactive_ok && interactive == .Interactive, "notifications must not share the background lane")
	testing.expect(t, exclusive_ok && exclusive == .Exclusive, "Bridge update must never execute on the reader or lifecycle lane")
	testing.expect(t, general_io_ok && general_io == .General_IO, "filesystem and VCS work must use a bounded IO lane")
	testing.expect(t, shell_ok && shell == .Shell, "shell control must preserve its own FIFO lane")
	testing.expect(t, !heartbeat_async, "heartbeat acknowledgement must remain reader-local control traffic")
	testing.expect(t, !tunnel_async, "stream data remains on its specialized data plane")
	testing.expect(t, bridge_command_inline_type("bridge_heartbeat_ack"), "heartbeat acknowledgement is an explicit inline control type")
	testing.expect(t, bridge_command_inline_type("tunnel_data"), "tunnel data is an explicit specialized data-plane type")
	testing.expect(t, !bridge_command_inline_type("made_up_command"), "unknown commands must not fall through to inline execution")
}

@(test)
bridge_dispatch_models_cannot_starve_provider_detection :: proc(t: ^testing.T) {
	stage1, _ := bridge_command_spec("provider_discover")
	stage2, _ := bridge_command_spec("provider_models_discover")
	extension, _ := bridge_command_spec("provider_extension_install")
	occupied: [len(BRIDGE_DISPATCH_WORKER_CLASSES)]bool
	// All stage-two workers are occupied; further stage-two requests queue in
	// that same class. One extension install occupies a background worker too.
	extension_started := false
	for class, i in BRIDGE_DISPATCH_WORKER_CLASSES {
		if class == stage2.class { occupied[i] = true; continue }
		if class == extension.class && !extension_started { occupied[i] = true; extension_started = true }
	}
	stage1_can_start := false
	for class, i in BRIDGE_DISPATCH_WORKER_CLASSES {
		if class == stage1.class && !occupied[i] do stage1_can_start = true
	}
	testing.expect(t, stage1_can_start, "stage-one detection still has a worker while models and an extension install are running")
	testing.expect_value(t, bridge_command_dispatch_admission_scope(stage2.class, 4, BRIDGE_DISPATCH_MODEL_DISCOVERY_LIMIT, 0, 0, 128), "model_discovery")
	testing.expect_value(t, bridge_command_dispatch_admission_scope(stage1.class, 4, 0, 0, 0, 128), "")
}

@(test)
bridge_dispatch_admission_is_bounded_and_reserves_control_path :: proc(t: ^testing.T) {
	testing.expect_value(t, bridge_command_dispatch_admission_scope(.Background, 0, 0, 0, 0, 128), "")
	testing.expect_value(t, bridge_command_dispatch_admission_scope(.Background, 0, BRIDGE_DISPATCH_BACKGROUND_LIMIT, 0, 0, 128), "background")
	testing.expect_value(t, bridge_command_dispatch_admission_scope(.Lifecycle, BRIDGE_DISPATCH_TOTAL_LIMIT, 0, 0, 0, 128), "global")
	testing.expect_value(t, bridge_command_dispatch_admission_scope(.Interactive, 0, 0, BRIDGE_DISPATCH_OWNED_BYTES_LIMIT, 0, 1), "global")
	testing.expect_value(t, bridge_command_dispatch_admission_scope(.Interactive, 0, 0, 0, BRIDGE_DISPATCH_OUTBOX_BYTES_LIMIT, 1), "global")
	testing.expect_value(t, bridge_command_dispatch_admission_scope(.Lifecycle, BRIDGE_DISPATCH_TOTAL_LIMIT - BRIDGE_DISPATCH_RECOVERY_RESERVE, 0, 0, 0, 128), "global")
	testing.expect_value(t, bridge_command_dispatch_admission_scope(.Lifecycle, BRIDGE_DISPATCH_TOTAL_LIMIT - BRIDGE_DISPATCH_RECOVERY_RESERVE, 0, 0, 0, 128, true), "")
	testing.expect_value(t, bridge_command_dispatch_admission_scope(.Lifecycle, 0, 0, BRIDGE_DISPATCH_OWNED_BYTES_LIMIT - BRIDGE_DISPATCH_RECOVERY_BYTES_RESERVE, 0, 1), "global")
	testing.expect_value(t, bridge_command_dispatch_admission_scope(.Lifecycle, 0, 0, BRIDGE_DISPATCH_OWNED_BYTES_LIMIT - BRIDGE_DISPATCH_RECOVERY_BYTES_RESERVE, 0, 1, true), "")
	testing.expect(t, bridge_command_is_recovery("stop_agent"), "agent stop must retain reserved recovery admission")
	testing.expect(t, bridge_command_is_recovery("shell_kill"), "shell kill must retain reserved recovery admission")
	testing.expect(t, !bridge_command_is_recovery("launch_agent"), "new work must not consume recovery reserve")
}

@(test)
bridge_dispatch_overload_result_has_retry_contract :: proc(t: ^testing.T) {
	result := bridge_command_dispatch_busy_json("cmd_busy", "background", 1250)
	defer delete(result)
	testing.expect(t, strings.contains(result, `"status":"failed"`), "overload is terminal for this attempt")
	testing.expect(t, strings.contains(result, `"cause":"bridge_busy"`), "overload has a stable error code")
	testing.expect(t, strings.contains(result, `"class":"retriable"`), "overload declares retry safety")
	testing.expect(t, strings.contains(result, `"retry_after_ms":1250`), "overload supplies bounded retry guidance")
	testing.expect(t, strings.contains(result, `"scope":"background"`), "overload identifies only a bounded scope")
}

@(test)
bridge_dispatch_protocol_errors_are_terminal_and_not_retryable :: proc(t: ^testing.T) {
	result := bridge_command_dispatch_protocol_error_json("cmd_bad", "command_too_large")
	defer delete(result)
	testing.expect(t, strings.contains(result, `"command_id":"cmd_bad"`), "protocol error retains command correlation")
	testing.expect(t, strings.contains(result, `"status":"failed"`), "protocol error is terminal")
	testing.expect(t, strings.contains(result, `"cause":"command_too_large"`), "protocol error has a stable reason")
	testing.expect(t, strings.contains(result, `"class":"fatal"`), "malformed work must not be retried")
}

@(test)
bridge_dispatch_ordering_keys_serialize_conflicting_mutations :: proc(t: ^testing.T) {
	a1 := bridge_command_ordering_key("launch_agent", `{"agent_instance_id":"inst_a"}`)
	a2 := bridge_command_ordering_key("agent_pty_input", `{"agent_instance_id":"inst_a"}`)
	b := bridge_command_ordering_key("launch_agent", `{"agent_instance_id":"inst_b"}`)
	s1 := bridge_command_ordering_key("shell_start", `{"session_id":"sh_1"}`)
	s2 := bridge_command_ordering_key("shell_kill", `{"session_id":"sh_1"}`)
	fs1 := bridge_command_ordering_key("fs_write_file", `{"path":"/a"}`)
	fs2 := bridge_command_ordering_key("fs_delete", `{"path":"/b"}`)
	defer { delete(a1); delete(a2); delete(b); delete(s1); delete(s2); delete(fs1); delete(fs2) }
	testing.expect_value(t, a1, a2)
	testing.expect(t, a1 != b, "independent agents may execute in parallel")
	testing.expect_value(t, s1, s2)
	testing.expect_value(t, fs1, fs2)
}

@(test)
bridge_command_registry_covers_every_reader_command :: proc(t: ^testing.T) {
	types := []string{
		"bridge_heartbeat_ack", "provider_catalog_version", "provider_catalog", "lsp_send", "tunnel_open", "tunnel_data", "tunnel_close", "proxy_data", "proxy_close",
		"launch_agent", "launch_provider_test", "stop_agent", "wake_agent", "agent_pty_input", "agent_pty_resize", "bridge_unseal", "set_telemetry", "lsp_start", "lsp_stop",
		"notify_agent_message", "notify_task_nudge", "notify_shell_run", "notify_title_nudge", "task_status_changed_notify", "capture_agent_pane", "get_agent_pane",
		"provider_discover", "shell_stream_attach", "bridge_update",
		"session_projects", "fs_list_dir", "fs_stat", "fs_make_dir", "fs_read_file", "agent_run_dir_list", "agent_run_dir_read", "fs_create_file", "fs_write_file", "fs_batch_write", "fs_move", "fs_delete", "fs_find_files", "fs_grep",
		"vcs_capabilities", "vcs_status", "vcs_files", "vcs_diff", "vcs_stage", "vcs_unstage", "vcs_revert", "vcs_save_file", "vcs_commit", "vcs_upload", "vcs_push", "vcs_sync", "vcs_pull", "vcs_log", "vcs_commit_diff", "vcs_workspaces",
		"get_shell_output", "shell_pty_input", "shell_pty_resize", "shell_stream_detach", "shell_start", "shell_background", "shell_kill", "shell_signal", "shell_restart", "shell_set_port", "shell_list", "shell_logs", "shell_capture", "shell_get_pane",
	}
	for command_type in types {
		spec, ok := bridge_command_spec(command_type)
		testing.expect(t, ok, "every reader command must have a dispatch spec")
		testing.expect(t, spec.timeout_ms > 0 && spec.cost_units > 0, "every command spec must declare bounded time and cost")
		if spec.queued do testing.expect(t, spec.requires_id, "queued commands require stable command ids")
	}
	_, unknown := bridge_command_spec("unknown_reader_command")
	testing.expect(t, !unknown, "unknown commands fail closed")
}

@(test)
bridge_dispatch_cost_budget_preserves_recovery_reserve :: proc(t: ^testing.T) {
	normal_cost := BRIDGE_DISPATCH_COST_LIMIT - BRIDGE_DISPATCH_RECOVERY_COST_RESERVE
	testing.expect_value(t, bridge_command_dispatch_admission_scope(.General_IO, 0, 0, 0, 0, 10, false, normal_cost, 1), "global")
	testing.expect_value(t, bridge_command_dispatch_admission_scope(.Lifecycle, 0, 0, 0, 0, 10, true, normal_cost, 1), "")
}

@(test)
bridge_dispatch_metrics_are_bounded_and_non_secret :: proc(t: ^testing.T) {
	json := bridge_command_dispatch_metrics_json()
	defer delete(json)
	testing.expect(t, strings.contains(json, `"queued":`))
	testing.expect(t, strings.contains(json, `"queue_high_water":`))
	testing.expect(t, strings.contains(json, `"max_execution_ms":`))
	testing.expect(t, !strings.contains(json, "command_id"), "metrics must not expose command identities")
}

@(test)
bridge_child_process_budget_is_explicit_and_bounded :: proc(t: ^testing.T) {
	testing.expect(t, bridge_process_slot_has_capacity(0))
	testing.expect(t, bridge_process_slot_has_capacity(BRIDGE_PROCESS_SLOT_LIMIT - 1))
	testing.expect(t, !bridge_process_slot_has_capacity(BRIDGE_PROCESS_SLOT_LIMIT))
	testing.expect(t, bridge_command_may_spawn_process("provider_discover"))
	testing.expect(t, bridge_command_may_spawn_process("vcs_status"))
	testing.expect(t, bridge_command_may_spawn_process("lsp_start"))
	testing.expect(t, !bridge_command_may_spawn_process("shell_kill"), "recovery commands retain their reserved lane")
}

@(test)
bridge_dispatch_resolve_id_synthesizes_for_idless_wake_agent :: proc(t: ^testing.T) {
	// An older hub sends wake_agent without command_id; rejecting it with
	// missing_command_id silently kills reconcile auto start/stop.
	text := `{"type":"wake_agent","chain_id":"chain_1","payload":{"run":[],"stop":["inst_1"]}}`
	first, ok := bridge_command_dispatch_resolve_id("wake_agent", text)
	defer delete(first)
	testing.expect(t, ok, "id-less wake_agent must not be rejected")
	testing.expectf(t, strings.has_prefix(first, "bridge_wake_"), "synthesized id has bridge_wake_ prefix; got %q", first)
	second, ok2 := bridge_command_dispatch_resolve_id("wake_agent", text)
	defer delete(second)
	testing.expect(t, ok2)
	testing.expect(t, first != second, "synthesized ids are unique so the claim table never dedups two wakes")
}

@(test)
bridge_dispatch_resolve_id_prefers_hub_ids :: proc(t: ^testing.T) {
	id, ok := bridge_command_dispatch_resolve_id("wake_agent", `{"type":"wake_agent","protocol_version":1,"command_id":"cmd_x","chain_id":"c"}`)
	defer delete(id)
	testing.expect(t, ok)
	testing.expect_value(t, id, "cmd_x")
	req, req_ok := bridge_command_dispatch_resolve_id("stop_agent", `{"type":"stop_agent","request_id":"req_1"}`)
	defer delete(req)
	testing.expect(t, req_ok)
	testing.expect_value(t, req, "req_1")
}

@(test)
bridge_dispatch_resolve_id_rejects_idless_non_wake_commands :: proc(t: ^testing.T) {
	// The wake_agent tolerance must not leak into any other queued command.
	for command_type in ([]string{"stop_agent", "launch_agent", "notify_agent_message"}) {
		text := strings.concatenate({`{"type":"`, command_type, `","payload":{}}`})
		defer delete(text)
		id, ok := bridge_command_dispatch_resolve_id(command_type, text)
		defer delete(id)
		testing.expectf(t, !ok, "%s without id must resolve ok=false", command_type)
		testing.expect_value(t, id, "")
	}
}

@(test)
bridge_dispatch_spec_accepts_status_ack_and_connection_replaced :: proc(t: ^testing.T) {
	// Both are hub->bridge control frames handled on the reader (queued=false), so
	// bridge_command_dispatch returns false and they fall through to
	// bridge_hub_handle_command instead of drawing an unknown_command reply.
	for command_type in ([]string{"agent_instance_status_ack", "connection_replaced", "bridge_enrollment_result", "tool_stream_attach", "tool_stream_detach", "tool_stream_batch"}) {
		spec, known := bridge_command_spec(command_type)
		testing.expectf(t, known, "%s must be a known hub frame", command_type)
		testing.expectf(t, !spec.queued, "%s must not be queued", command_type)
		testing.expectf(t, !spec.requires_id, "%s must not require an id", command_type)
	}
}

@(test)
bridge_hub_replaced_backoff_next_doubles_to_cap :: proc(t: ^testing.T) {
	expected := []int{30, 60, 120, 240, 300, 300}
	prev := 0
	for want in expected {
		prev = bridge_hub_replaced_backoff_next(prev)
		testing.expect_value(t, prev, want)
	}
}

@(test)
bridge_hub_connection_replaced_sets_backoff_and_status_ack_is_noop :: proc(t: ^testing.T) {
	// The only test touching the replaced flag/backoff globals; restore them after.
	saved_flag := sync.atomic_load(&bridge_hub_replaced_flag)
	saved_backoff := sync.atomic_load(&bridge_hub_replaced_backoff_s)
	defer {
		sync.atomic_store(&bridge_hub_replaced_flag, saved_flag)
		sync.atomic_store(&bridge_hub_replaced_backoff_s, saved_backoff)
	}
	sync.atomic_store(&bridge_hub_replaced_flag, false)
	sync.atomic_store(&bridge_hub_replaced_backoff_s, 0)
	conn: ws.Connection

	// agent_instance_status_ack: silent no-op, touches no reconnect state.
	bridge_hub_handle_command(&conn, `{"type":"agent_instance_status_ack","protocol_version":1,"payload":{"agent_instance_id":"inst_1","applied":true}}`)
	testing.expect(t, !sync.atomic_load(&bridge_hub_replaced_flag), "status ack must not flag a replacement")

	replaced_frame := `{"type":"connection_replaced","protocol_version":1,"payload":{"reason":"newer_bridge_connection"}}`
	bridge_hub_handle_command(&conn, replaced_frame)
	testing.expect(t, sync.atomic_load(&bridge_hub_replaced_flag), "connection_replaced flags the reconnect loop")
	// The hub answers every frame on a stale socket; repeats on one connection do not double.
	bridge_hub_handle_command(&conn, replaced_frame)
	backoff, replaced := bridge_hub_take_replaced_backoff()
	testing.expect(t, replaced)
	testing.expect_value(t, backoff, 30)

	// Consecutive replaced connections double.
	bridge_hub_handle_command(&conn, replaced_frame)
	backoff, replaced = bridge_hub_take_replaced_backoff()
	testing.expect(t, replaced)
	testing.expect_value(t, backoff, 60)

	// A connection that closes without replacement resets the backoff.
	backoff, replaced = bridge_hub_take_replaced_backoff()
	testing.expect(t, !replaced)
	testing.expect_value(t, backoff, 0)
	bridge_hub_handle_command(&conn, replaced_frame)
	backoff, replaced = bridge_hub_take_replaced_backoff()
	testing.expect(t, replaced)
	testing.expect_value(t, backoff, 30)
}

// Every frame type the hub writes to a bridge runtime socket. Derived (2026-10-11)
// by enumerating the frame builders in src/hub/** whose output goes to a bridge:
//   - `"type":"<x>"` literals (escaped and raw-string) in builders sent via
//     bridge_command_send_runtime / send_runtime_command(_wait) /
//     write_ws_text_frame_locked on the bridge socket;
//   - command_type values fed to the generic builders bridge_fs_command_json,
//     project_fs_command_json, project_vcs_command_json, instance_fs_command_json
//     (bridge_fs_relay / project_handle_vcs_write / Project_*_Command literals).
// Excluded: hub->UI websocket frames (chat_event, resource_changed, output, screen,
// status, stream_ready/closed, shell_session_*, lsp_* to the browser, user_ws_ready)
// and the handshake frames bridge_ready/bridge_error, which hub_runtime_client
// consumes before dispatch. Adding a new hub->bridge command requires updating BOTH
// this list and bridge_command_spec.
HUB_TO_BRIDGE_RUNTIME_FRAME_TYPES := []string{
	// control / acks
	"bridge_heartbeat_ack", "agent_instance_status_ack", "connection_replaced",
	"provider_catalog", "provider_catalog_version",
	// REQ-EA-4: atomic enrollment verdict (bridge_enroll_ws.odin)
	"bridge_enrollment_result",
	// REQ-EXT-PERM-1: user permission decision (extension_permission.odin)
	"permission_decision",
	// bridge lifecycle
	"bridge_unseal", "set_telemetry", "auto_update_config", "bridge_update", "provider_discover", "provider_models_discover", "provider_extension_install",
	// agents
	"launch_agent", "launch_provider_test", "stop_agent", "wake_agent",
	"get_agent_pane", "capture_agent_pane",
	"notify_agent_message", "notify_title_nudge", "notify_task_nudge", "notify_shell_run", "task_status_changed_notify",
	// lsp
	"lsp_start", "lsp_stop", "lsp_send",
	// shell
	"shell_pty_input", "shell_pty_resize", "shell_start", "shell_background", "shell_capture", "shell_get_pane",
	"shell_kill", "shell_logs", "shell_restart", "shell_set_port", "shell_signal",
	"shell_stream_attach", "shell_stream_detach",
	// tunnels / preview proxy
	"tunnel_open", "tunnel_data", "tunnel_close", "proxy_data", "proxy_close",
	// filesystem
	"session_projects", "validate_project_path", "fs_list_dir", "fs_stat", "fs_read_file", "fs_make_dir", "fs_create_file",
	"fs_write_file", "fs_batch_write", "fs_move", "fs_delete", "fs_find_files", "fs_grep",
	"agent_run_dir_list", "agent_run_dir_read",
	// vcs
	"vcs_capabilities", "vcs_status", "vcs_files", "vcs_diff", "vcs_log", "vcs_commit_diff", "vcs_workspaces",
	"vcs_stage", "vcs_unstage", "vcs_revert", "vcs_save_file", "vcs_commit", "vcs_upload", "vcs_push", "vcs_sync", "vcs_pull",
}

@(test)
bridge_dispatch_spec_covers_every_hub_to_bridge_frame :: proc(t: ^testing.T) {
	// A hub frame missing from bridge_command_spec draws unknown_command and is
	// dropped (the wake_agent/status-ack regressions after 551b0ba6).
	for command_type in HUB_TO_BRIDGE_RUNTIME_FRAME_TYPES {
		_, known := bridge_command_spec(command_type)
		testing.expectf(t, known, "hub->bridge frame %q is missing from bridge_command_spec", command_type)
	}
}

@(test)
hub_runtime_bridge_error_preserves_hub_diagnostic :: proc(t: ^testing.T) {
	message := bridge_hub_error_log_message(
		`{"type":"bridge_error","protocol_version":1,"payload":{"message":"provider catalog unavailable"}}`,
	)
	defer delete(message)
	testing.expect(
		t,
		strings.contains(message, "provider catalog unavailable"),
		"bridge log preserves the Hub's actual setup error",
	)
	testing.expect(
		t,
		!strings.contains(message, "token rejected"),
		"post-authentication setup errors are not mislabeled as token rejection",
	)
}

@(test)
hub_runtime_bridge_error_without_message_has_safe_fallback :: proc(t: ^testing.T) {
	message := bridge_hub_error_log_message(`{"type":"bridge_error","payload":{}}`)
	defer delete(message)
	testing.expect(
		t,
		strings.contains(message, "without a diagnostic message"),
		"malformed Hub errors retain an actionable fallback",
	)
}


@(test)
test_bridge_hub_plan_refusal_logs_upgrade_url :: proc(t: ^testing.T) {
	previous := bridge_config.daemon_url
	bridge_config.daemon_url = "https://hub.example.test/"
	defer bridge_config.daemon_url = previous
	message := bridge_hub_error_log_message(`{"type":"bridge_error","payload":{"code":"plan_limit_reached","message":"Bridge disabled by plan limits","upgrade_path":"/settings/account"}}`)
	defer delete(message)
	testing.expect(t, strings.contains(message, "Bridge disabled by plan limits"))
	testing.expect(t, strings.contains(message, "https://hub.example.test/#/settings/account"))
}
