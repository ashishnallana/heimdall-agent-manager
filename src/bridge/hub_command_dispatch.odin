package main

import "base:runtime"
import "core:fmt"
import "core:crypto"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import jsonx "odin_test:lib/jsonx"
import ws "odin_test:lib/ws"

// Commands known to perform process, PTY-host, filesystem, or network waits are
// admitted here instead of being executed by the Hub WebSocket reader. The first
// slice deliberately covers the incident paths; commands not listed here retain
// their existing path until their state/ordering contract is migrated.
Bridge_Command_Class :: enum {
	Lifecycle,
	Interactive,
	Background,
	Exclusive,
	General_IO,
	Shell,
	Model_Discovery,
}

Bridge_Command_Priority :: enum {
	Control,
	Recovery,
	Interactive,
	Background,
}

Bridge_Command_Key_Kind :: enum {
	None,
	Agent,
	Shell,
	Filesystem,
	VCS,
	Provider_Discovery,
	Bridge,
	LSP,
}

Bridge_Command_Spec :: struct {
	class: Bridge_Command_Class,
	priority: Bridge_Command_Priority,
	key_kind: Bridge_Command_Key_Kind,
	queued: bool,
	requires_id: bool,
	timeout_ms: int,
	cost_units: int,
	coalescible: bool,
	retry_safe: bool,
}

Bridge_Dispatch_Claim_State :: enum {
	Queued,
	Running,
	Completed,
}

Bridge_Dispatch_Job :: struct {
	text: string,
	command_id: string,
	command_type: string,
	ordering_key: string,
	class: Bridge_Command_Class,
	generation: i64,
	deadline_ns: i64,
	enqueued_ns: i64,
	owned_bytes: int,
	cost_units: int,
}

Bridge_Dispatch_Output :: struct {
	text: string,
	generation: i64,
	sensitive: bool,
}

Bridge_Dispatch_Claim :: struct {
	command_id: string,
	state: Bridge_Dispatch_Claim_State,
	result_json: string,
}

Bridge_Dispatch_Worker :: struct {
	index: int,
	class: Bridge_Command_Class,
	sink_conn: ws.Connection,
	current_generation: i64,
	current_command_id: string,
	last_result: string,
	output_failed: bool,
	enqueued_ns: i64,
	started_ns: i64,
	deadline_ns: i64,
}

Bridge_Dispatch_Metrics :: struct {
	accepted: u64,
	rejected: u64,
	completed: u64,
	deadline_expired: u64,
	stale_completions: u64,
	response_backpressure: u64,
	queue_high_water: int,
	max_queue_wait_ms: i64,
	max_execution_ms: i64,
	max_loop_delay_ms: i64,
}

BRIDGE_DISPATCH_TOTAL_LIMIT :: 128
BRIDGE_DISPATCH_RECOVERY_RESERVE :: 8
BRIDGE_DISPATCH_LIFECYCLE_LIMIT :: 32
BRIDGE_DISPATCH_INTERACTIVE_LIMIT :: 48
BRIDGE_DISPATCH_BACKGROUND_LIMIT :: 32
BRIDGE_DISPATCH_EXCLUSIVE_LIMIT :: 4
BRIDGE_DISPATCH_GENERAL_IO_LIMIT :: 24
BRIDGE_DISPATCH_SHELL_LIMIT :: 24
BRIDGE_DISPATCH_MODEL_DISCOVERY_LIMIT :: 4
BRIDGE_DISPATCH_OWNED_BYTES_LIMIT :: 4 * 1024 * 1024
BRIDGE_DISPATCH_RECOVERY_BYTES_RESERVE :: 256 * 1024
BRIDGE_DISPATCH_COMMAND_BYTES_LIMIT :: 1024 * 1024
BRIDGE_DISPATCH_OUTBOX_BYTES_LIMIT :: 8 * 1024 * 1024
BRIDGE_DISPATCH_DEFAULT_TIMEOUT_MS :: 30_000
BRIDGE_DISPATCH_CLAIM_LIMIT :: 256
BRIDGE_DISPATCH_COST_LIMIT :: 256
BRIDGE_DISPATCH_RECOVERY_COST_RESERVE :: 32

bridge_dispatch_mu: sync.Mutex
bridge_dispatch_lifecycle: [dynamic]Bridge_Dispatch_Job
bridge_dispatch_interactive: [dynamic]Bridge_Dispatch_Job
bridge_dispatch_background: [dynamic]Bridge_Dispatch_Job
bridge_dispatch_exclusive: [dynamic]Bridge_Dispatch_Job
bridge_dispatch_general_io: [dynamic]Bridge_Dispatch_Job
bridge_dispatch_shell: [dynamic]Bridge_Dispatch_Job
bridge_dispatch_model_discovery: [dynamic]Bridge_Dispatch_Job
bridge_dispatch_outputs: [dynamic]Bridge_Dispatch_Output
bridge_dispatch_claims: [dynamic]Bridge_Dispatch_Claim
BRIDGE_DISPATCH_WORKER_CLASSES :: [14]Bridge_Command_Class{.Lifecycle, .Lifecycle, .Interactive, .Interactive, .Background, .Background, .Exclusive, .General_IO, .General_IO, .General_IO, .General_IO, .Shell, .Shell, .Model_Discovery}
bridge_dispatch_workers: [len(BRIDGE_DISPATCH_WORKER_CLASSES)]Bridge_Dispatch_Worker
bridge_dispatch_active_keys: [dynamic]string
bridge_dispatch_owned_bytes: int
bridge_dispatch_queued_cost: int
bridge_dispatch_outbox_bytes: int
bridge_dispatch_generation: i64
bridge_dispatch_initialized: bool
bridge_dispatch_metrics: Bridge_Dispatch_Metrics

bridge_command_dispatch_init :: proc() {
	sync.mutex_lock(&bridge_dispatch_mu)
	if bridge_dispatch_initialized {
		sync.mutex_unlock(&bridge_dispatch_mu)
		return
	}
	bridge_dispatch_lifecycle = make([dynamic]Bridge_Dispatch_Job, runtime.default_allocator())
	bridge_dispatch_interactive = make([dynamic]Bridge_Dispatch_Job, runtime.default_allocator())
	bridge_dispatch_background = make([dynamic]Bridge_Dispatch_Job, runtime.default_allocator())
	bridge_dispatch_exclusive = make([dynamic]Bridge_Dispatch_Job, runtime.default_allocator())
	bridge_dispatch_general_io = make([dynamic]Bridge_Dispatch_Job, runtime.default_allocator())
	bridge_dispatch_shell = make([dynamic]Bridge_Dispatch_Job, runtime.default_allocator())
	bridge_dispatch_model_discovery = make([dynamic]Bridge_Dispatch_Job, runtime.default_allocator())
	bridge_dispatch_outputs = make([dynamic]Bridge_Dispatch_Output, runtime.default_allocator())
	bridge_dispatch_claims = make([dynamic]Bridge_Dispatch_Claim, runtime.default_allocator())
	bridge_dispatch_active_keys = make([dynamic]string, runtime.default_allocator())
	for class, i in BRIDGE_DISPATCH_WORKER_CLASSES {
		bridge_dispatch_workers[i].index = i
		bridge_dispatch_workers[i].class = class
	}
	bridge_dispatch_initialized = true
	sync.mutex_unlock(&bridge_dispatch_mu)
	for i in 0..<len(bridge_dispatch_workers) {
		_ = thread.create_and_start_with_data(rawptr(&bridge_dispatch_workers[i]), bridge_command_dispatch_worker)
	}
}

bridge_command_dispatch_begin_connection :: proc() -> i64 {
	bridge_command_dispatch_init()
	sync.mutex_lock(&bridge_dispatch_mu)
	defer sync.mutex_unlock(&bridge_dispatch_mu)
	bridge_dispatch_generation += 1
	bridge_command_dispatch_drop_stale_queue_locked(&bridge_dispatch_lifecycle, bridge_dispatch_generation)
	bridge_command_dispatch_drop_stale_queue_locked(&bridge_dispatch_interactive, bridge_dispatch_generation)
	bridge_command_dispatch_drop_stale_queue_locked(&bridge_dispatch_background, bridge_dispatch_generation)
	bridge_command_dispatch_drop_stale_queue_locked(&bridge_dispatch_exclusive, bridge_dispatch_generation)
	bridge_command_dispatch_drop_stale_queue_locked(&bridge_dispatch_general_io, bridge_dispatch_generation)
	bridge_command_dispatch_drop_stale_queue_locked(&bridge_dispatch_shell, bridge_dispatch_generation)
	bridge_command_dispatch_drop_stale_queue_locked(&bridge_dispatch_model_discovery, bridge_dispatch_generation)
	return bridge_dispatch_generation
}

bridge_command_dispatch_drop_stale_queue_locked :: proc(queue: ^[dynamic]Bridge_Dispatch_Job, generation: i64) {
	for i := 0; i < len(queue); {
		job := queue[i]
		if job.generation == generation { i += 1; continue }
		if claim_i := bridge_command_dispatch_claim_index_locked(job.command_id); claim_i >= 0 {
			delete(bridge_dispatch_claims[claim_i].command_id, runtime.default_allocator())
			delete(bridge_dispatch_claims[claim_i].result_json, runtime.default_allocator())
			ordered_remove(&bridge_dispatch_claims, claim_i)
		}
		bridge_dispatch_owned_bytes -= job.owned_bytes
		bridge_dispatch_queued_cost -= job.cost_units
		if job.command_type=="mcp_transform" && job.text!="" do crypto.zero_explicit(raw_data(job.text),len(job.text))
		delete(job.text, runtime.default_allocator())
		delete(job.command_id, runtime.default_allocator())
		delete(job.command_type, runtime.default_allocator())
		delete(job.ordering_key, runtime.default_allocator())
		ordered_remove(queue, i)
	}
}

// One exhaustive registry is the protocol audit surface. Every accepted Hub frame
// declares whether it runs on the reader or a worker, plus its priority, ordering,
// deadline, cost, coalescing, and retry contract.
bridge_command_spec :: proc(command_type: string) -> (Bridge_Command_Spec, bool) {
	switch command_type {
	case "bridge_heartbeat_ack", "provider_catalog_version", "agent_instance_status_ack", "connection_replaced", "protocol_error", "tool_stream_attach", "tool_stream_detach", "tool_stream_batch":
		return Bridge_Command_Spec{priority = .Control, queued = false, timeout_ms = 1000, cost_units = 1}, true
	// REQ-EA-4: the hub's commit/rollback verdict to an atomic enrollment. Inline on
	// the reader: a rollback is usually followed at once by the socket closing, and a
	// queued job is dropped as stale when the connection ends.
	case "bridge_enrollment_result":
		return Bridge_Command_Spec{priority = .Control, queued = false, timeout_ms = 1000, cost_units = 1}, true
	// REQ-EXT-PERM-1: resolves an in-memory permission waiter; inline because it
	// is cheap and a blocked agent is waiting on it.
	case "permission_decision":
		return Bridge_Command_Spec{priority = .Control, queued = false, timeout_ms = 1000, cost_units = 1}, true
	case "provider_catalog":
		return Bridge_Command_Spec{priority = .Control, key_kind = .Provider_Discovery, queued = false, timeout_ms = 5000, cost_units = 2}, true
	case "lsp_send":
		return Bridge_Command_Spec{priority = .Control, key_kind = .LSP, queued = false, timeout_ms = 1000, cost_units = 1}, true
	case "tunnel_open", "tunnel_data", "tunnel_close", "proxy_data", "proxy_close":
		return Bridge_Command_Spec{priority = .Control, queued = false, timeout_ms = 1000, cost_units = 1}, true
	case "stop_agent":
		return Bridge_Command_Spec{class = .Lifecycle, priority = .Recovery, key_kind = .Agent, queued = true, requires_id = true, timeout_ms = 15_000, cost_units = 4}, true
	case "lsp_stop":
		return Bridge_Command_Spec{class = .Lifecycle, priority = .Recovery, key_kind = .LSP, queued = true, requires_id = true, timeout_ms = 5000, cost_units = 2}, true
	case "shell_kill", "shell_signal", "shell_stream_detach":
		return Bridge_Command_Spec{class = .Shell, priority = .Recovery, key_kind = .Shell, queued = true, requires_id = true, timeout_ms = 10_000, cost_units = 2}, true
	case "launch_agent", "launch_provider_test", "wake_agent":
		return Bridge_Command_Spec{class = .Lifecycle, priority = .Interactive, key_kind = .Agent, queued = true, requires_id = true, timeout_ms = 30_000, cost_units = 8}, true
	case "agent_pty_input", "agent_pty_resize":
		return Bridge_Command_Spec{class = .Lifecycle, priority = .Interactive, key_kind = .Agent, queued = true, requires_id = true, timeout_ms = 5000, cost_units = 1}, true
	case "bridge_unseal", "set_telemetry", "auto_update_config":
		return Bridge_Command_Spec{class = .Lifecycle, priority = .Interactive, key_kind = .Bridge, queued = true, requires_id = true, timeout_ms = 5000, cost_units = 2}, true
	// REQ-PROF-3: sealed provider profile edit/read from the user's browser.
	case "provider_profile_op":
		return Bridge_Command_Spec{class = .Interactive, priority = .Interactive, key_kind = .Bridge, queued = true, requires_id = true, timeout_ms = 10_000, cost_units = 2}, true
	case "task_chain_search":
		return Bridge_Command_Spec{class = .Interactive, priority = .Interactive, key_kind = .Bridge, queued = true, requires_id = true, timeout_ms = 5000, cost_units = 2, retry_safe = true}, true
	case "mcp_transform":
		return Bridge_Command_Spec{class=.Interactive,priority=.Interactive,key_kind=.Bridge,queued=true,requires_id=true,timeout_ms=4000,cost_units=2},true
	case "lsp_start":
		return Bridge_Command_Spec{class = .Lifecycle, priority = .Interactive, key_kind = .LSP, queued = true, requires_id = true, timeout_ms = 15_000, cost_units = 4}, true
	case "notify_agent_message", "notify_task_nudge", "notify_shell_run", "notify_title_nudge", "task_status_changed_notify", "capture_agent_pane", "get_agent_pane":
		return Bridge_Command_Spec{class = .Interactive, priority = .Interactive, key_kind = .Agent, queued = true, requires_id = true, timeout_ms = 10_000, cost_units = 2}, true
	case "provider_discover":
		return Bridge_Command_Spec{class = .Background, priority = .Background, key_kind = .Provider_Discovery, queued = true, requires_id = true, timeout_ms = 10_000, cost_units = 16, coalescible = true, retry_safe = true}, true
	case "provider_models_discover":
		// Slow model metadata cannot consume the two workers used by Stage 1
		// provider detection and extension installation.
		return Bridge_Command_Spec{class = .Model_Discovery, priority = .Background, key_kind = .Provider_Discovery, queued = true, requires_id = true, timeout_ms = 30_000, cost_units = 16, coalescible = true}, true
	case "provider_extension_install":
		return Bridge_Command_Spec{class = .Background, priority = .Interactive, key_kind = .Provider_Discovery, queued = true, requires_id = true, timeout_ms = 60_000, cost_units = 16}, true
	case "shell_stream_attach":
		return Bridge_Command_Spec{class = .Background, priority = .Background, key_kind = .Shell, queued = true, requires_id = true, timeout_ms = 10_000, cost_units = 4, retry_safe = true}, true
	case "bridge_update":
		return Bridge_Command_Spec{class = .Exclusive, priority = .Interactive, key_kind = .Bridge, queued = true, requires_id = true, timeout_ms = 30_000, cost_units = 64}, true
	case "bridge_uninstall":
		return Bridge_Command_Spec{class = .Exclusive, priority = .Interactive, key_kind = .Bridge, queued = true, requires_id = true, timeout_ms = 15_000, cost_units = 64}, true
	case "session_projects":
		return Bridge_Command_Spec{class = .General_IO, priority = .Background, key_kind = .None, queued = true, requires_id = true, timeout_ms = 8000, cost_units = 4, retry_safe = true}, true
	case "validate_project_path", "fs_list_dir", "fs_stat", "fs_read_file", "agent_run_dir_list", "agent_run_dir_read", "fs_find_files", "fs_grep":
		return Bridge_Command_Spec{class = .General_IO, priority = .Background, key_kind = .None, queued = true, requires_id = true, timeout_ms = 15_000, cost_units = 4, retry_safe = true}, true
	case "fs_make_dir", "fs_create_file", "fs_write_file", "fs_batch_write", "fs_move", "fs_delete":
		return Bridge_Command_Spec{class = .General_IO, priority = .Interactive, key_kind = .Filesystem, queued = true, requires_id = true, timeout_ms = 20_000, cost_units = 8}, true
	case "vcs_capabilities", "vcs_status", "vcs_files", "vcs_diff", "vcs_log", "vcs_commit_diff", "vcs_workspaces", "vcs_show_file":
		return Bridge_Command_Spec{class = .General_IO, priority = .Background, key_kind = .VCS, queued = true, requires_id = true, timeout_ms = 20_000, cost_units = 8, retry_safe = true}, true
	case "vcs_stage", "vcs_unstage", "vcs_revert", "vcs_save_file", "vcs_commit":
		return Bridge_Command_Spec{class = .General_IO, priority = .Interactive, key_kind = .VCS, queued = true, requires_id = true, timeout_ms = 30_000, cost_units = 16}, true
	case "taskv2_merge_worktree":
		// Task System v2 merge-back of a task's worktree branch; the hub waits 60s.
		return Bridge_Command_Spec{class = .General_IO, priority = .Interactive, key_kind = .VCS, queued = true, requires_id = true, timeout_ms = 60_000, cost_units = 16}, true
	case "vcs_upload", "vcs_push", "vcs_sync", "vcs_pull":
		// Network round trips to the remote: the hub waits 120s for these
		// (vcs_command_timeout_ms), so the bridge deadline matches it (REQ-ERR-PROTO-B).
		return Bridge_Command_Spec{class = .General_IO, priority = .Interactive, key_kind = .VCS, queued = true, requires_id = true, timeout_ms = 120_000, cost_units = 16}, true
	case "get_shell_output", "shell_pty_input", "shell_pty_resize", "shell_start", "shell_background", "shell_restart", "shell_set_port", "shell_list", "shell_logs", "shell_capture", "shell_get_pane":
		return Bridge_Command_Spec{class = .Shell, priority = .Interactive, key_kind = .Shell, queued = true, requires_id = true, timeout_ms = 30_000, cost_units = 4}, true
	}
	return Bridge_Command_Spec{}, false
}

bridge_command_dispatch_class :: proc(command_type: string) -> (Bridge_Command_Class, bool) {
	spec, ok := bridge_command_spec(command_type)
	if !ok || !spec.queued do return .Interactive, false
	return spec.class, true
}

bridge_command_inline_type :: proc(command_type: string) -> bool {
	spec, ok := bridge_command_spec(command_type)
	return ok && !spec.queued
}

bridge_command_is_recovery :: proc(command_type: string) -> bool {
	spec, ok := bridge_command_spec(command_type)
	return ok && spec.priority == .Recovery
}

bridge_command_may_spawn_process :: proc(command_type: string) -> bool {
	return command_type == "provider_discover" ||
	       command_type == "provider_models_discover" ||
	       command_type == "provider_extension_install" ||
	       command_type == "lsp_start" ||
	       command_type == "bridge_update" ||
	       command_type == "bridge_uninstall" ||
	       strings.has_prefix(command_type, "vcs_")
}

bridge_command_ordering_key :: proc(command_type, text: string) -> string {
	switch command_type {
	// Provider discovery has its own filter-keyed single-flight registry. Leaving
	// the scheduler key empty lets the second background worker join that flight.
	case "provider_discover", "provider_models_discover": return ""
	case "provider_extension_install":
		prov := extract_json_string(text, "provider", "")
		defer delete(prov)
		if prov != "" do return strings.concatenate({"provider-ext-install:", prov})
		return strings.clone("provider-ext-install")
	case "bridge_update", "bridge_uninstall": return strings.clone("bridge-update")
	case "bridge_unseal", "set_telemetry", "auto_update_config": return strings.clone("bridge-control")
	case "provider_profile_op": return strings.clone("provider-profiles")
	case "fs_make_dir", "fs_create_file", "fs_write_file", "fs_batch_write", "fs_move", "fs_delete":
		// Batch operations can touch several paths. A single filesystem mutation key
		// is conservative but correct until canonical roots are part of the contract.
		return strings.clone("fs-mutation")
	case "vcs_stage", "vcs_unstage", "vcs_revert", "vcs_save_file", "vcs_commit", "vcs_upload", "vcs_push", "vcs_sync", "vcs_pull":
		root := extract_json_string(text, "root", "")
		if root == "" {
			delete(root)
			root = extract_json_string(text, "path", "")
		}
		defer delete(root)
		return strings.concatenate({"vcs:", root if root != "" else "global"})
	}
	if command_type == "taskv2_merge_worktree" {
		repo := extract_json_string(text, "repo", "")
		defer delete(repo)
		return strings.concatenate({"vcs:", repo if repo != "" else "global"})
	}
	if strings.has_prefix(command_type, "shell_") || command_type == "get_shell_output" {
		id := extract_json_string(text, "session_id", "")
		if id == "" {
			delete(id)
			id = extract_json_string(text, "shell_id", "")
		}
		defer delete(id)
		if id != "" do return strings.concatenate({"shell:", id})
		return ""
	}
	if strings.has_prefix(command_type, "lsp_") {
		id := extract_json_string(text, "session_id", "")
		defer delete(id)
		if id != "" do return strings.concatenate({"lsp:", id})
		return ""
	}
	switch command_type {
	case "launch_agent", "launch_provider_test", "stop_agent", "agent_pty_input", "agent_pty_resize", "capture_agent_pane", "get_agent_pane", "notify_agent_message", "notify_task_nudge", "notify_shell_run", "notify_title_nudge":
		id := extract_json_string(text, "agent_instance_id", "")
		defer delete(id)
		if id != "" do return strings.concatenate({"agent:", id})
	case "wake_agent", "task_status_changed_notify":
		return strings.clone("agent-control")
	}
	return ""
}

bridge_command_dispatch_queue_len_locked :: proc(class: Bridge_Command_Class) -> int {
	switch class {
	case .Lifecycle: return len(bridge_dispatch_lifecycle)
	case .Interactive: return len(bridge_dispatch_interactive)
	case .Background: return len(bridge_dispatch_background)
	case .Exclusive: return len(bridge_dispatch_exclusive)
	case .General_IO: return len(bridge_dispatch_general_io)
	case .Shell: return len(bridge_dispatch_shell)
	case .Model_Discovery: return len(bridge_dispatch_model_discovery)
	}
	return 0
}

bridge_command_dispatch_class_limit :: proc(class: Bridge_Command_Class) -> int {
	switch class {
	case .Lifecycle: return BRIDGE_DISPATCH_LIFECYCLE_LIMIT
	case .Interactive: return BRIDGE_DISPATCH_INTERACTIVE_LIMIT
	case .Background: return BRIDGE_DISPATCH_BACKGROUND_LIMIT
	case .Exclusive: return BRIDGE_DISPATCH_EXCLUSIVE_LIMIT
	case .General_IO: return BRIDGE_DISPATCH_GENERAL_IO_LIMIT
	case .Shell: return BRIDGE_DISPATCH_SHELL_LIMIT
	case .Model_Discovery: return BRIDGE_DISPATCH_MODEL_DISCOVERY_LIMIT
	}
	return 0
}

bridge_command_dispatch_total_locked :: proc() -> int {
	return len(bridge_dispatch_lifecycle) + len(bridge_dispatch_interactive) + len(bridge_dispatch_background) + len(bridge_dispatch_exclusive) + len(bridge_dispatch_general_io) + len(bridge_dispatch_shell) + len(bridge_dispatch_model_discovery)
}

bridge_command_dispatch_admission_scope :: proc(class: Bridge_Command_Class, total, class_depth, owned_bytes, outbox_bytes, incoming_bytes: int, recovery: bool = false, queued_cost: int = 0, incoming_cost: int = 1) -> string {
	normal_limit := BRIDGE_DISPATCH_TOTAL_LIMIT - BRIDGE_DISPATCH_RECOVERY_RESERVE
	owned_limit := BRIDGE_DISPATCH_OWNED_BYTES_LIMIT if recovery else BRIDGE_DISPATCH_OWNED_BYTES_LIMIT - BRIDGE_DISPATCH_RECOVERY_BYTES_RESERVE
	outbox_limit := BRIDGE_DISPATCH_OUTBOX_BYTES_LIMIT if recovery else BRIDGE_DISPATCH_OUTBOX_BYTES_LIMIT * 3 / 4
	cost_limit := BRIDGE_DISPATCH_COST_LIMIT if recovery else BRIDGE_DISPATCH_COST_LIMIT - BRIDGE_DISPATCH_RECOVERY_COST_RESERVE
	if total >= (BRIDGE_DISPATCH_TOTAL_LIMIT if recovery else normal_limit) || owned_bytes + incoming_bytes > owned_limit || outbox_bytes > outbox_limit || queued_cost + incoming_cost > cost_limit do return "global"
	if class_depth >= bridge_command_dispatch_class_limit(class) + (BRIDGE_DISPATCH_RECOVERY_RESERVE if recovery else 0) {
		if class == .Model_Discovery do return "model_discovery"
		return "background" if class == .Background else ("lifecycle" if class == .Lifecycle else ("exclusive" if class == .Exclusive else "interactive"))
	}
	return ""
}

bridge_command_dispatch_claim_index_locked :: proc(command_id: string) -> int {
	for claim, i in bridge_dispatch_claims {
		if claim.command_id == command_id do return i
	}
	return -1
}

bridge_command_dispatch_prune_claim_locked :: proc() -> bool {
	if len(bridge_dispatch_claims) < BRIDGE_DISPATCH_CLAIM_LIMIT do return true
	for claim, i in bridge_dispatch_claims {
		if claim.state != .Completed do continue
		delete(claim.command_id, runtime.default_allocator())
		delete(claim.result_json, runtime.default_allocator())
		ordered_remove(&bridge_dispatch_claims, i)
		return true
	}
	return false
}

// bridge_command_dispatch_busy_json sheds a command the bridge has no room for:
// retriable, with the floor the hub must wait and the saturated scope.
bridge_command_dispatch_busy_json :: proc(command_id, scope: string, retry_after_ms: int = 1000) -> string {
	return bridge_command_failed_json(command_id, bridge_cause_wire_error("bridge_busy", "bridge command queue is full", i64(retry_after_ms), scope))
}

// bridge_command_dispatch_deadline_json answers a command whose hub deadline passed
// before it ran. The hub caller has already given up, so it is not retried.
bridge_command_dispatch_deadline_json :: proc(command_id: string) -> string {
	err := bridge_cause_wire_error("deadline_exceeded", "command deadline passed before it ran")
	err.class = .fatal
	return bridge_command_failed_json(command_id, err)
}

// bridge_command_dispatch_protocol_error_json refuses a frame the bridge cannot
// process (unknown type, no id, too large, an oversized reply): fatal.
bridge_command_dispatch_protocol_error_json :: proc(command_id, cause: string) -> string {
	err := bridge_cause_wire_error(cause, "bridge refused the command frame")
	err.class = .fatal
	return bridge_command_failed_json(command_id, err)
}

// bridge_wake_synth_counter numbers the ids synthesized for id-less wake_agent
// frames; process-local, which matches the lifetime of the dispatch claim table.
bridge_wake_synth_counter: u64

// bridge_command_dispatch_resolve_id returns the queued command's id: command_id,
// else request_id. Every queued command requires one, except that an id-less
// wake_agent gets a synthesized local "bridge_wake_<n>" id so a new bridge keeps
// servicing reconcile auto start/stop from an older hub that predates
// wake_agent.command_id. ok=false means the caller must reject with
// missing_command_id. The returned id is owned by the caller (context allocator).
bridge_command_dispatch_resolve_id :: proc(command_type, text: string) -> (id: string, ok: bool) {
	id = extract_json_string(text, "command_id", "")
	if id != "" do return id, true
	delete(id)
	id = extract_json_string(text, "request_id", "")
	if id != "" do return id, true
	delete(id)
	if command_type == "wake_agent" {
		n := sync.atomic_add(&bridge_wake_synth_counter, 1) + 1
		return fmt.aprintf("bridge_wake_%d", n), true
	}
	return "", false
}

// bridge_command_budget_ms is how long a queued command may wait and run: the hub's
// top-level timeout_ms (how long it will wait for the result, REQ-ERR-PROTO-B), capped
// by the command's own spec. A timeout_ms inside the command's params is not its budget.
bridge_command_budget_ms :: proc(text: string, spec: Bridge_Command_Spec) -> int {
	timeout_ms := jsonx.extract_int(text, "timeout_ms", spec.timeout_ms, top_level_only = true)
	if timeout_ms <= 0 || timeout_ms > spec.timeout_ms do timeout_ms = spec.timeout_ms
	return timeout_ms
}

bridge_command_dispatch :: proc(conn: ^ws.Connection, text: string, generation: i64) -> bool {
	command_type := extract_json_string(text, "type", "")
	defer delete(command_type)
	spec, known := bridge_command_spec(command_type)
	if !known {
		protocol_error := bridge_command_dispatch_protocol_error_json("", "unknown_command")
		defer delete(protocol_error)
		_ = bridge_hub_send(conn, protocol_error)
		return true
	}
	if !spec.queued do return false
	class := spec.class
	command_id, id_ok := bridge_command_dispatch_resolve_id(command_type, text)
	defer delete(command_id)
	if !id_ok {
		protocol_error := bridge_command_dispatch_protocol_error_json("", "missing_command_id")
		defer delete(protocol_error)
		_ = bridge_hub_send(conn, protocol_error)
		return true
	}
	if len(text) > BRIDGE_DISPATCH_COMMAND_BYTES_LIMIT {
		protocol_error := bridge_command_dispatch_protocol_error_json(command_id, "command_too_large")
		defer delete(protocol_error)
		_ = bridge_hub_send(conn, protocol_error)
		return true
	}
	ordering_key := bridge_command_ordering_key(command_type, text)
	defer delete(ordering_key)

	timeout_ms := bridge_command_budget_ms(text, spec)
	now_ns := time.to_unix_nanoseconds(time.now())
	deadline := now_ns + i64(time.Duration(timeout_ms) * time.Millisecond)
	owned_bytes := len(text) + len(command_id) + len(command_type)

	sync.mutex_lock(&bridge_dispatch_mu)
	claim_index := bridge_command_dispatch_claim_index_locked(command_id)
	if claim_index >= 0 {
		claim := bridge_dispatch_claims[claim_index]
		cached := strings.clone(claim.result_json, runtime.default_allocator())
		sync.mutex_unlock(&bridge_dispatch_mu)
		if cached != "" {
			defer delete(cached, runtime.default_allocator())
			_ = bridge_hub_send(conn, cached)
		} else {
			accepted := bridge_command_result_json(command_id, "accepted", "")
			defer delete(accepted)
			_ = bridge_hub_send(conn, accepted)
		}
		return true
	}

	scope := bridge_command_dispatch_admission_scope(class, bridge_command_dispatch_total_locked(), bridge_command_dispatch_queue_len_locked(class), bridge_dispatch_owned_bytes, bridge_dispatch_outbox_bytes, owned_bytes, spec.priority == .Recovery, bridge_dispatch_queued_cost, spec.cost_units)
	if scope == "" && bridge_command_may_spawn_process(command_type) && bridge_process_slot_count() >= BRIDGE_PROCESS_SLOT_LIMIT do scope = "process"
	if scope == "" && !bridge_command_dispatch_prune_claim_locked() do scope = "global"
	if scope != "" {
		bridge_dispatch_metrics.rejected += 1
		sync.mutex_unlock(&bridge_dispatch_mu)
		busy := bridge_command_dispatch_busy_json(command_id, scope)
		defer delete(busy)
		_ = bridge_hub_send(conn, busy)
		return true
	}

	job := Bridge_Dispatch_Job{
		text = strings.clone(text, runtime.default_allocator()),
		command_id = strings.clone(command_id, runtime.default_allocator()),
		command_type = strings.clone(command_type, runtime.default_allocator()),
		ordering_key = strings.clone(ordering_key, runtime.default_allocator()),
		class = class,
		generation = generation,
		deadline_ns = deadline,
		enqueued_ns = now_ns,
		owned_bytes = owned_bytes,
		cost_units = spec.cost_units,
	}
	switch class {
	case .Lifecycle: append(&bridge_dispatch_lifecycle, job)
	case .Interactive: append(&bridge_dispatch_interactive, job)
	case .Background: append(&bridge_dispatch_background, job)
	case .Exclusive: append(&bridge_dispatch_exclusive, job)
	case .General_IO: append(&bridge_dispatch_general_io, job)
	case .Shell: append(&bridge_dispatch_shell, job)
	case .Model_Discovery: append(&bridge_dispatch_model_discovery, job)
	}
	append(&bridge_dispatch_claims, Bridge_Dispatch_Claim{command_id = strings.clone(command_id, runtime.default_allocator()), state = .Queued})
	bridge_dispatch_owned_bytes += owned_bytes
	bridge_dispatch_queued_cost += spec.cost_units
	bridge_dispatch_metrics.accepted += 1
	bridge_dispatch_metrics.queue_high_water = max(bridge_dispatch_metrics.queue_high_water, bridge_command_dispatch_total_locked())
	sync.mutex_unlock(&bridge_dispatch_mu)
	accepted := bridge_command_result_json(command_id, "accepted", "")
	defer delete(accepted)
	_ = bridge_hub_send(conn, accepted)
	return true
}

bridge_command_dispatch_take :: proc(class: Bridge_Command_Class) -> (Bridge_Dispatch_Job, bool) {
	sync.mutex_lock(&bridge_dispatch_mu)
	defer sync.mutex_unlock(&bridge_dispatch_mu)
	queue: ^[dynamic]Bridge_Dispatch_Job
	switch class {
	case .Lifecycle: queue = &bridge_dispatch_lifecycle
	case .Interactive: queue = &bridge_dispatch_interactive
	case .Background: queue = &bridge_dispatch_background
	case .Exclusive: queue = &bridge_dispatch_exclusive
	case .General_IO: queue = &bridge_dispatch_general_io
	case .Shell: queue = &bridge_dispatch_shell
	case .Model_Discovery: queue = &bridge_dispatch_model_discovery
	}
	if queue == nil do return Bridge_Dispatch_Job{}, false
	job, ok := bridge_command_dispatch_take_queue_locked(queue)
	if !ok do return job, false
	if i := bridge_command_dispatch_claim_index_locked(job.command_id); i >= 0 do bridge_dispatch_claims[i].state = .Running
	now_ns := time.to_unix_nanoseconds(time.now())
	wait_ms := (now_ns - job.enqueued_ns) / i64(time.Millisecond)
	bridge_dispatch_metrics.max_queue_wait_ms = max(bridge_dispatch_metrics.max_queue_wait_ms, wait_ms)
	return job, true
}

bridge_command_dispatch_take_queue_locked :: proc(queue: ^[dynamic]Bridge_Dispatch_Job) -> (Bridge_Dispatch_Job, bool) {
	for job, i in queue {
		blocked := false
		if job.ordering_key != "" {
			for key in bridge_dispatch_active_keys {
				if key == job.ordering_key { blocked = true; break }
			}
		}
		if blocked do continue
		// Range iteration aliases the backing element. ordered_remove zeroes the
		// removed slot, so returning that alias used to erase generation, ids, and
		// payload from the worker's job. The worker then published generation zero
		// and the runtime loop correctly discarded every completion as stale.
		// Build an explicit value and clear the queue's ownership before removal.
		selected := Bridge_Dispatch_Job{
			text = queue[i].text,
			command_id = queue[i].command_id,
			command_type = queue[i].command_type,
			ordering_key = queue[i].ordering_key,
			class = queue[i].class,
			generation = queue[i].generation,
			deadline_ns = queue[i].deadline_ns,
			enqueued_ns = queue[i].enqueued_ns,
			owned_bytes = queue[i].owned_bytes,
			cost_units = queue[i].cost_units,
		}
		queue[i] = {}
		ordered_remove(queue, i)
		if selected.ordering_key != "" do append(&bridge_dispatch_active_keys, strings.clone(selected.ordering_key, runtime.default_allocator()))
		return selected, true
	}
	return Bridge_Dispatch_Job{}, false
}

bridge_command_dispatch_finish :: proc(worker: ^Bridge_Dispatch_Worker, job: ^Bridge_Dispatch_Job) {
	sync.mutex_lock(&bridge_dispatch_mu)
	if job.ordering_key != "" {
		for key, i in bridge_dispatch_active_keys {
			if key != job.ordering_key do continue
			delete(key, runtime.default_allocator())
			ordered_remove(&bridge_dispatch_active_keys, i)
			break
		}
	}
	if i := bridge_command_dispatch_claim_index_locked(job.command_id); i >= 0 {
		bridge_dispatch_claims[i].state = .Completed
		delete(bridge_dispatch_claims[i].result_json, runtime.default_allocator())
		bridge_dispatch_claims[i].result_json=""
		if job.command_type!="mcp_transform" do bridge_dispatch_claims[i].result_json = strings.clone(worker.last_result, runtime.default_allocator())
	}
	bridge_dispatch_owned_bytes -= job.owned_bytes
	bridge_dispatch_queued_cost -= job.cost_units
	bridge_dispatch_metrics.completed += 1
	if worker.started_ns > 0 {
		execution_ms := (time.to_unix_nanoseconds(time.now()) - worker.started_ns) / i64(time.Millisecond)
		bridge_dispatch_metrics.max_execution_ms = max(bridge_dispatch_metrics.max_execution_ms, execution_ms)
	}
	delete(worker.current_command_id, runtime.default_allocator())
	worker.current_command_id = ""
	delete(worker.last_result, runtime.default_allocator())
	worker.last_result = ""
	worker.output_failed = false
	worker.current_generation = 0
	worker.enqueued_ns = 0
	worker.started_ns = 0
	worker.deadline_ns = 0
	sync.mutex_unlock(&bridge_dispatch_mu)
	if job.command_type=="mcp_transform" && job.text!="" do crypto.zero_explicit(raw_data(job.text),len(job.text))
	delete(job.text, runtime.default_allocator())
	delete(job.command_id, runtime.default_allocator())
	delete(job.command_type, runtime.default_allocator())
	delete(job.ordering_key, runtime.default_allocator())
}

bridge_command_dispatch_worker :: proc(data: rawptr) {
	worker := (^Bridge_Dispatch_Worker)(data)
	for {
		job, ok := bridge_command_dispatch_take(worker.class)
		if !ok {
			time.sleep(5 * time.Millisecond)
			continue
		}
		sync.mutex_lock(&bridge_dispatch_mu)
		worker.current_generation = job.generation
		worker.current_command_id = strings.clone(job.command_id, runtime.default_allocator())
		worker.enqueued_ns = job.enqueued_ns
		worker.started_ns = time.to_unix_nanoseconds(time.now())
		worker.deadline_ns = job.deadline_ns
		sync.mutex_unlock(&bridge_dispatch_mu)
		if time.to_unix_nanoseconds(time.now()) >= job.deadline_ns {
			sync.mutex_lock(&bridge_dispatch_mu)
			bridge_dispatch_metrics.deadline_expired += 1
			sync.mutex_unlock(&bridge_dispatch_mu)
			result := bridge_command_dispatch_deadline_json(job.command_id)
			_ = bridge_command_worker_capture_send(&worker.sink_conn, result)
			delete(result)
		} else {
			bridge_hub_handle_command(&worker.sink_conn, job.text)
		}
		bridge_command_dispatch_finish(worker, &job)
	}
}

// Worker-safe command handlers use this to propagate the dispatch budget into
// filesystem walks, HTTP retries, and other interruptible work. A real Hub socket
// is never registered as a worker sink, so reader-local handlers receive zero.
bridge_command_worker_deadline_ns :: proc(conn: ^ws.Connection) -> i64 {
	if conn == nil do return 0
	sync.mutex_lock(&bridge_dispatch_mu)
	defer sync.mutex_unlock(&bridge_dispatch_mu)
	for &worker in bridge_dispatch_workers {
		if rawptr(conn) == rawptr(&worker.sink_conn) do return worker.deadline_ns
	}
	return 0
}

// Single-flight handlers must include time spent queued when deciding whether
// an overlapping explicit request can reuse the operation that just completed.
bridge_command_worker_enqueued_ns :: proc(conn: ^ws.Connection) -> i64 {
	if conn == nil do return 0
	sync.mutex_lock(&bridge_dispatch_mu)
	defer sync.mutex_unlock(&bridge_dispatch_mu)
	for &worker in bridge_dispatch_workers {
		if rawptr(conn) == rawptr(&worker.sink_conn) do return worker.enqueued_ns
	}
	return 0
}

bridge_command_deadline_expired :: proc(deadline_ns: i64) -> bool {
	return deadline_ns > 0 && time.to_unix_nanoseconds(time.now()) >= deadline_ns
}

// bridge_hub_send calls this before touching the real socket. Worker handlers get
// a private sink connection, never the live Hub connection; results cross threads
// only as owned JSON in this bounded outbox.
bridge_command_worker_capture_send :: proc(conn: ^ws.Connection, text: string) -> bool {
	if conn == nil do return false
	sync.mutex_lock(&bridge_dispatch_mu)
	defer sync.mutex_unlock(&bridge_dispatch_mu)
	for &worker in bridge_dispatch_workers {
		if rawptr(conn) != rawptr(&worker.sink_conn) do continue
		if worker.output_failed do return false
		captured := text
		fallback := ""
		if len(text) > BRIDGE_DISPATCH_COMMAND_BYTES_LIMIT || bridge_dispatch_outbox_bytes + len(text) > BRIDGE_DISPATCH_OUTBOX_BYTES_LIMIT {
			// Reserve a bounded terminal answer even when a normal result cannot fit.
			// At most one such small over-cap frame exists per worker, so the byte
			// budget remains bounded and the Hub sees a failure instead of timing out.
			fallback = bridge_command_dispatch_protocol_error_json(worker.current_command_id, "response_backpressure")
			captured = fallback
			worker.output_failed = true
			bridge_dispatch_metrics.response_backpressure += 1
		}
		defer delete(fallback)
		frame_type:=extract_json_string(captured,"type","")
		sensitive:=frame_type=="mcp_transform_result"
		delete(frame_type)
		append(&bridge_dispatch_outputs, Bridge_Dispatch_Output{text = strings.clone(captured, runtime.default_allocator()), generation = worker.current_generation,sensitive=sensitive})
		bridge_dispatch_outbox_bytes += len(captured)
		delete(worker.last_result, runtime.default_allocator())
		if sensitive {worker.last_result=""} else {worker.last_result = strings.clone(captured, runtime.default_allocator())}
		return true
	}
	return false
}

bridge_command_dispatch_drain :: proc(conn: ^ws.Connection, generation: i64) {
	for turn := 0; turn < 4; turn += 1 {
		output: Bridge_Dispatch_Output
		have := false
		sync.mutex_lock(&bridge_dispatch_mu)
		if len(bridge_dispatch_outputs) > 0 {
			output = bridge_dispatch_outputs[0]
			ordered_remove(&bridge_dispatch_outputs, 0)
			bridge_dispatch_outbox_bytes -= len(output.text)
			have = true
		}
		sync.mutex_unlock(&bridge_dispatch_mu)
		if !have do return
		if output.generation == generation {
			if !bridge_hub_send(conn, output.text) {
				if output.sensitive && output.text!="" do crypto.zero_explicit(raw_data(output.text),len(output.text))
				delete(output.text, runtime.default_allocator())
				conn.connected = false
				return
			}
		} else {
			sync.mutex_lock(&bridge_dispatch_mu)
			bridge_dispatch_metrics.stale_completions += 1
			sync.mutex_unlock(&bridge_dispatch_mu)
		}
		if output.sensitive && output.text!="" do crypto.zero_explicit(raw_data(output.text),len(output.text))
		delete(output.text, runtime.default_allocator())
	}
}

bridge_command_dispatch_observe_loop_delay :: proc(delay: time.Duration) {
	ms := i64(delay / time.Millisecond)
	sync.mutex_lock(&bridge_dispatch_mu)
	bridge_dispatch_metrics.max_loop_delay_ms = max(bridge_dispatch_metrics.max_loop_delay_ms, ms)
	sync.mutex_unlock(&bridge_dispatch_mu)
}

// bridge_command_dispatch_diagnostics_write appends the bridge_diagnostics
// command_dispatch family: only the four cumulative counters the hub consumes. The
// legacy heartbeat object (bridge_command_dispatch_metrics_json) keeps every member.
bridge_command_dispatch_diagnostics_write :: proc(b: ^strings.Builder) {
	sync.mutex_lock(&bridge_dispatch_mu)
	m := bridge_dispatch_metrics
	sync.mutex_unlock(&bridge_dispatch_mu)
	fmt.sbprintf(b, `{{"accepted":%d,"rejected":%d,"completed":%d,"deadline_expired":%d}}`, m.accepted, m.rejected, m.completed, m.deadline_expired)
}

bridge_command_dispatch_metrics_json :: proc() -> string {
	sync.mutex_lock(&bridge_dispatch_mu)
	defer sync.mutex_unlock(&bridge_dispatch_mu)
	active := 0
	for worker in bridge_dispatch_workers do if worker.current_command_id != "" do active += 1
	b := strings.builder_make()
	strings.write_string(&b, "{\"queued\":")
	strings.write_string(&b, fmt.tprintf("%d", bridge_command_dispatch_total_locked()))
	strings.write_string(&b, ",\"active_workers\":")
	strings.write_string(&b, fmt.tprintf("%d", active))
	strings.write_string(&b, ",\"owned_bytes\":")
	strings.write_string(&b, fmt.tprintf("%d", bridge_dispatch_owned_bytes))
	strings.write_string(&b, ",\"outbox_bytes\":")
	strings.write_string(&b, fmt.tprintf("%d", bridge_dispatch_outbox_bytes))
	strings.write_string(&b, ",\"queued_cost\":")
	strings.write_string(&b, fmt.tprintf("%d", bridge_dispatch_queued_cost))
	strings.write_string(&b, ",\"accepted\":")
	strings.write_string(&b, fmt.tprintf("%d", bridge_dispatch_metrics.accepted))
	strings.write_string(&b, ",\"rejected\":")
	strings.write_string(&b, fmt.tprintf("%d", bridge_dispatch_metrics.rejected))
	strings.write_string(&b, ",\"completed\":")
	strings.write_string(&b, fmt.tprintf("%d", bridge_dispatch_metrics.completed))
	strings.write_string(&b, ",\"deadline_expired\":")
	strings.write_string(&b, fmt.tprintf("%d", bridge_dispatch_metrics.deadline_expired))
	strings.write_string(&b, ",\"stale_completions\":")
	strings.write_string(&b, fmt.tprintf("%d", bridge_dispatch_metrics.stale_completions))
	strings.write_string(&b, ",\"response_backpressure\":")
	strings.write_string(&b, fmt.tprintf("%d", bridge_dispatch_metrics.response_backpressure))
	strings.write_string(&b, ",\"queue_high_water\":")
	strings.write_string(&b, fmt.tprintf("%d", bridge_dispatch_metrics.queue_high_water))
	strings.write_string(&b, ",\"max_queue_wait_ms\":")
	strings.write_string(&b, fmt.tprintf("%d", bridge_dispatch_metrics.max_queue_wait_ms))
	strings.write_string(&b, ",\"max_execution_ms\":")
	strings.write_string(&b, fmt.tprintf("%d", bridge_dispatch_metrics.max_execution_ms))
	strings.write_string(&b, ",\"max_loop_delay_ms\":")
	strings.write_string(&b, fmt.tprintf("%d", bridge_dispatch_metrics.max_loop_delay_ms))
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}
