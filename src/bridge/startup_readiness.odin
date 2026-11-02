package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:encoding/json"
import httpc "odin_test:lib/httpc"
import contracts "odin_test:contracts"
import agent_runtime "odin_test:lib/agent_runtime"

// All state belongs to one token issuance/launch, not to an extension session
// (SessionStart can also occur after /clear). bridge_runtime_mutex owns it.
Bridge_Startup_State :: struct {
	generation: u64,
	rec: Bridge_Local_Agent_Token_Record,
	launch_key: string,
	pty_pid: i32,
	extension_expected: bool,
	armed_at_ms: i64,
	ready_pending: bool,
	ready_delivered: bool,
	fallback_delivered: bool,
	fallback_error_reported: bool,
	next_attempt_ms: i64,
	relay_state, fallback_state: Bridge_Operation_State,
}

bridge_startup_generation: u64
// Only lifecycle changes and startup I/O take this gate. Neither ingest nor the
// runtime registry mutex is held across network or PTY I/O. A stop/relaunch waits
// for an in-progress write, so old work cannot target the replacement child.
bridge_startup_io_mutex: sync.Mutex
bridge_startup_worker_started: bool

Bridge_Startup_Work_Kind :: enum { All, Readiness, Fallback }

bridge_startup_worker_ensure_started :: proc() {
	if _, swapped := sync.atomic_compare_exchange_strong(&bridge_startup_worker_started, false, true); swapped {
		thread.run(proc() {
			for {
				time.sleep(100 * time.Millisecond)
				bridge_startup_tick(bridge_runtime_now_ms(), kind = .Fallback)
				free_all(context.temp_allocator)
			}
		})
		thread.run(proc() {
			for {
				time.sleep(100 * time.Millisecond)
				bridge_startup_tick(bridge_runtime_now_ms(), kind = .Readiness)
				free_all(context.temp_allocator)
			}
		})
	}
}

BRIDGE_STARTUP_RETRY_MS :: 1_000
BRIDGE_STARTUP_INSTRUCTION :: "Run `" + agent_runtime.CTL_SHIM_INVOCATION + " agent start-success` now to confirm that this agent is ready."

bridge_startup_event :: proc(ev: contracts.Ext_Event) -> bool {
	// Unknown agent types and subagent identities cannot establish main readiness.
	if ev.agent_id != "" || (ev.agent_type != "" && ev.agent_type != "main") do return false
	if strings.trim_space(ev.session_id) == "" do return false
	return ev.kind == .Hello || (ev.kind == .Session && ev.session_phase == "start")
}

bridge_startup_rec_current :: proc(rec: Bridge_Local_Agent_Token_Record) -> bool {
	if rec.token_hash == "" || rec.invalidated_at_unix_ms != 0 do return false
	sync.mutex_lock(&bridge_local_token_mutex)
	defer sync.mutex_unlock(&bridge_local_token_mutex)
	for r in bridge_local_token_records {
		if r.token_hash == rec.token_hash && r.agent_instance_id == rec.agent_instance_id &&
		   r.instance_token == rec.instance_token && r.run_count == rec.run_count && r.invalidated_at_unix_ms == 0 { return true }
	}
	return false
}

bridge_startup_clone_rec :: proc(rec: Bridge_Local_Agent_Token_Record, allocator := context.allocator) -> Bridge_Local_Agent_Token_Record {
	out := rec
	out.token_hash = strings.clone(rec.token_hash, allocator)
	out.agent_instance_id = strings.clone(rec.agent_instance_id, allocator)
	out.instance_token = strings.clone(rec.instance_token, allocator)
	return out
}

bridge_startup_begin :: proc(agent_token: string) {
	rec, valid := bridge_agent_token_verify(agent_token)
	if !valid do return
	sync.mutex_lock(&bridge_startup_io_mutex)
	defer sync.mutex_unlock(&bridge_startup_io_mutex)
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	bridge_startup_begin_locked(rec, bridge_runtime_now_ms())
	bridge_startup_worker_ensure_started()
}

bridge_startup_begin_locked :: proc(rec: Bridge_Local_Agent_Token_Record, now: i64) {
	context.allocator = runtime.heap_allocator()
	bridge_runtime_set_status_locked(rec.agent_instance_id, "starting", "active", now, true)
	for &inst in bridge_runtime_instances {
		if inst.agent_instance_id != rec.agent_instance_id do continue
		old := inst.startup.rec
		delete(old.token_hash); delete(old.agent_instance_id); delete(old.instance_token)
		delete(inst.startup.launch_key)
		bridge_startup_generation += 1
		inst.startup = Bridge_Startup_State{generation = bridge_startup_generation, rec = bridge_startup_clone_rec(rec), launch_key = strings.clone(rec.token_hash)}
		inst.start_success_seen = false
		inst.last_start_prompt_unix_ms = 0
		inst.stopped_intent_unix_ms = 0
		inst.pty_process_alive = false
		inst.start_deadline_unix_ms = now + BRIDGE_START_SUCCESS_TIMEOUT_MS
		return
	}
}

bridge_startup_set_expectation :: proc(instance_id, agent_token: string, expected: bool) {
	hash := bridge_local_hash_token(agent_token)
	defer delete(hash)
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for &inst in bridge_runtime_instances {
		if inst.agent_instance_id == instance_id && inst.startup.launch_key == hash {
			inst.startup.extension_expected = expected
			return
		}
	}
}

bridge_startup_arm :: proc(instance_id, agent_token: string, now: i64) {
	hash := bridge_local_hash_token(agent_token)
	defer delete(hash)
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for &inst in bridge_runtime_instances {
		if inst.agent_instance_id == instance_id && inst.startup.launch_key == hash {
			inst.startup.armed_at_ms = now
			if !inst.start_success_seen do inst.start_deadline_unix_ms = now + BRIDGE_START_SUCCESS_TIMEOUT_MS
			return
		}
	}
}

bridge_startup_spawned :: proc(instance_id, agent_token: string, pid: i32) {
	hash := bridge_local_hash_token(agent_token)
	defer delete(hash)
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for &inst in bridge_runtime_instances {
		if inst.agent_instance_id == instance_id && inst.startup.launch_key == hash {
			inst.startup.pty_pid = pid
			return
		}
	}
}

// CLI and extension events share the same claim. Re-check revocation because a
// request can authenticate just before a concurrent stop or replacement launch.
// Returns (valid for this launch, first readiness signal).
bridge_startup_accept :: proc(rec: Bridge_Local_Agent_Token_Record, now: i64) -> (bool, bool) {
	sync.mutex_lock(&bridge_startup_io_mutex)
	defer sync.mutex_unlock(&bridge_startup_io_mutex)
	if !bridge_startup_rec_current(rec) do return false, false
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	if bridge_runtime_stop_intent_active_locked(rec.agent_instance_id, now) do return false, false
	inst, exists := bridge_runtime_instance_snapshot_locked(rec.agent_instance_id)
	if exists && inst.stopped_intent_unix_ms != 0 do return false, false
	if exists && (inst.runtime_status == "stopped" || inst.runtime_status == "stopping" || inst.runtime_status == "failed") do return false, false
	// After a bridge restart, persisted current tokens may precede rediscovery.
	// Adopt them only if no managed launch/tombstone has replaced them.
	if !exists || inst.startup.generation == 0 do bridge_startup_begin_locked(rec, now)
	for &current in bridge_runtime_instances {
		if current.agent_instance_id != rec.agent_instance_id do continue
		if current.startup.rec.token_hash != rec.token_hash do return false, false
		if current.startup.ready_pending || current.startup.ready_delivered || bridge_operation_terminal({state = current.startup.relay_state}) do return true, false
		current.startup.ready_pending = true
		current.startup.next_attempt_ms = 0
		bridge_runtime_set_status_locked(rec.agent_instance_id, "running", "idle", now, true)
		return true, true
	}
	return false, false
}

// Rotation changes the local credential, not the launch identity or readiness.
bridge_startup_rotate_token :: proc(old_rec: Bridge_Local_Agent_Token_Record, new_token: string) {
	context.allocator = runtime.heap_allocator()
	hash := bridge_local_hash_token(new_token)
	sync.mutex_lock(&bridge_startup_io_mutex)
	defer sync.mutex_unlock(&bridge_startup_io_mutex)
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for &inst in bridge_runtime_instances {
		if inst.agent_instance_id == old_rec.agent_instance_id && inst.startup.rec.token_hash == old_rec.token_hash {
			delete(inst.startup.rec.token_hash)
			inst.startup.rec.token_hash = hash
			return
		}
	}
	delete(hash)
}

bridge_startup_fallback_due :: proc(inst: Bridge_Runtime_Instance, now: i64) -> bool {
	s := inst.startup
	return s.generation != 0 && s.armed_at_ms > 0 && !s.fallback_delivered &&
	       !inst.start_success_seen && inst.runtime_status == "starting" &&
           !bridge_operation_terminal({state = s.fallback_state}) &&
	       inst.stopped_intent_unix_ms == 0 && inst.pty_process_alive &&
	       now >= s.next_attempt_ms && now - s.armed_at_ms >= BRIDGE_START_SUCCESS_PROMPT_AFTER_MS &&
	       now - s.armed_at_ms < BRIDGE_START_SUCCESS_TIMEOUT_MS
}

Bridge_Startup_Relay_Result :: struct { ok: bool, error: contracts.Wire_Error }

bridge_startup_receipt_key :: proc(rec: Bridge_Local_Agent_Token_Record, fallback := false) -> string {
    assertion := bridge_local_hash_token(rec.instance_token)
    defer delete(assertion)
    return fmt.aprintf("ready:%s:%d:%s:%s", rec.agent_instance_id, rec.run_count, assertion, "fallback" if fallback else "relay")
}

bridge_startup_relay :: proc(rec: Bridge_Local_Agent_Token_Record, timeout_ms: int) -> Bridge_Startup_Relay_Result {
    if rec.instance_token == "" do return {error = contracts.wire_error(.Unauthenticated)}
    if !sync.atomic_load(&bridge_hub_runtime_up) do return {error = contracts.wire_error(.Bridge_Offline)}
    params := make(json.Object, 1, context.temp_allocator)
    params["run_count"] = json.Integer(rec.run_count)
    envelope := Bridge_Agent_Relay_Envelope{method = "agent.start_success", agent_instance_id = rec.agent_instance_id, params = params}
    credential := bridge_credential_snapshot()
    defer delete(credential)
    headers := [?]httpc.Header{httpc.bearer(credential), {name = "X-Heimdall-Instance-Token", value = rec.instance_token}}
    resp, err := bridge_hub_http_send_alloc({
        method = .POST, url = bridge_hub_url(), path = {"api", "v1", "agent-actions", "start-success"},
        headers = headers[:], body = httpc.json_body(envelope), timeout_ms = bridge_deadline_ms(timeout_ms),
    })
    defer httpc.response_destroy(&resp)
    ok := err == .None
    return {ok = ok && resp.status >= 200 && resp.status < 300, error = bridge_operation_http_error(resp, ok)}
}

bridge_startup_deliver :: proc(instance_id: string, timeout_ms: int) -> bool {
	socket := pty_host_socket_path()
	defer delete(socket)
	inst, exists := bridge_runtime_instance_snapshot(instance_id)
	if !exists || inst.startup.pty_pid <= 0 do return false
	// The host remembers a per-child receipt and partial write progress. Lost
	// replies are safely retried with the same key, payload and expected pid.
	text := bridge_startup_fallback_input(instance_id)
	defer delete(text)
	return bridge_startup_deliver_socket(socket, instance_id, inst.startup.pty_pid, inst.startup.launch_key, text, timeout_ms)
}

bridge_startup_deliver_socket :: proc(socket, instance_id: string, pid: i32, launch_key, text: string, timeout_ms := 10_000) -> bool {
	frame := pty_host_encode_startup_input(instance_id, pid, launch_key, transmute([]byte)text)
	defer delete(frame)
	reply, ok := pty_host_request_deadline(socket, frame, timeout_ms)
	if !ok do return false
	defer pty_host_reply_delete(reply)
	return reply.kind == .Startup_Input_Done && reply.instance == instance_id && reply.pid == pid && reply.startup_key == launch_key
}

bridge_startup_fallback_input :: proc(instance_id: string) -> string {
	text := BRIDGE_STARTUP_INSTRUCTION
	if bridge_pty_host_instance_wants_bracketed_paste(instance_id) {
		wrapped := bridge_pty_host_paste_wrap(text)
		defer delete(wrapped)
		return strings.concatenate({wrapped, "\r"})
	}
	return strings.concatenate({text, "\r"})
}

// Independent workers keep the timer off slow extension/HTTP relays, even when
// no extension event ever arrives. Snapshot jobs under the runtime lock, then
// fence/recheck each job at the I/O gate.
bridge_startup_tick :: proc(now: i64, relay := bridge_startup_relay, deliver := bridge_startup_deliver, only_instance := "", kind := Bridge_Startup_Work_Kind.All) {
	Job :: struct { id: string, generation: u64 }
	jobs := make([dynamic]Job, context.temp_allocator)
	sync.mutex_lock(&bridge_runtime_mutex)
	for inst in bridge_runtime_instances {
		if only_instance != "" && inst.agent_instance_id != only_instance do continue
		if (kind != .Fallback && inst.startup.ready_pending && !bridge_operation_terminal({state = inst.startup.relay_state}) && now >= inst.startup.next_attempt_ms) || (kind != .Readiness && bridge_startup_fallback_due(inst, now)) {
			append(&jobs, Job{strings.clone(inst.agent_instance_id, context.temp_allocator), inst.startup.generation})
		}
	}
	sync.mutex_unlock(&bridge_runtime_mutex)
	for job in jobs {
		sync.mutex_lock(&bridge_startup_io_mutex)
		inst, exists := bridge_runtime_instance_snapshot(job.id)
		if !exists || inst.startup.generation != job.generation ||
		   inst.runtime_status == "stopped" || inst.runtime_status == "stopping" ||
		   inst.runtime_status == "failed" || inst.stopped_intent_unix_ms != 0 || !bridge_startup_rec_current(inst.startup.rec) {
			sync.mutex_unlock(&bridge_startup_io_mutex)
			continue
		}
		ready := inst.startup.ready_pending && !bridge_operation_terminal({state = inst.startup.relay_state}) && now >= inst.startup.next_attempt_ms
		if (kind == .Fallback && ready) || (kind == .Readiness && !ready) {
			sync.mutex_unlock(&bridge_startup_io_mutex)
			continue
		}
        key := bridge_startup_receipt_key(inst.startup.rec, fallback = !ready)
        duration := BRIDGE_OPERATION_DEADLINE_MS
        if !ready do duration = min(duration, inst.startup.armed_at_ms + BRIDGE_START_SUCCESS_TIMEOUT_MS - now)
        budget, reserved := bridge_retry_reserve(key, now, duration)
        if !reserved {
            sync.mutex_lock(&bridge_runtime_mutex)
            for &current in bridge_runtime_instances {
                if current.agent_instance_id == job.id && current.startup.generation == job.generation {
                    if ready { current.startup.relay_state = budget.state }
                    else { current.startup.fallback_state = budget.state }
                }
            }
            sync.mutex_unlock(&bridge_runtime_mutex)
            delete(key)
            sync.mutex_unlock(&bridge_startup_io_mutex)
            continue
        }
        started := time.tick_now()
        err := contracts.wire_error(.Bridge_Timeout)
        ok := false
        attempted := false
		if ready {
			attempted = true
			// HTTP can be slow. Keep it off the fallback timer and lifecycle gate;
			// the hub authenticates the launch assertion and rejects stopped epochs.
			rec := bridge_startup_clone_rec(inst.startup.rec, context.temp_allocator)
			sync.mutex_unlock(&bridge_startup_io_mutex)
            result := relay(rec, bridge_operation_timeout_ms(budget, now))
            ok = result.ok; err = result.error
		} else if bridge_startup_fallback_due(inst, now) {
			attempted = true
			ok = deliver(job.id, bridge_operation_timeout_ms(budget, now))
		}
		if !attempted {
			sync.mutex_unlock(&bridge_startup_io_mutex)
			continue
		}
        if !bridge_startup_job_current(job.id, job.generation) {
            ok = false
            bridge_retry_cancel(key)
        }
        finished := bridge_retry_finish(key, bridge_operation_monotonic_finish_ms(now, started), ok, err)
        delete(key)
        report_failure := false
		sync.mutex_lock(&bridge_runtime_mutex)
		for &current in bridge_runtime_instances {
			if current.agent_instance_id != job.id || current.startup.generation != job.generation ||
               current.stopped_intent_unix_ms != 0 || current.runtime_status == "stopped" ||
               current.runtime_status == "stopping" || current.runtime_status == "failed" { continue }
			current.startup.next_attempt_ms = finished.next_ms
            if ready { current.startup.relay_state = finished.state }
            else { current.startup.fallback_state = finished.state }
			if !ready && !ok && !current.startup.fallback_error_reported {
				current.startup.fallback_error_reported = true
				report_failure = true
			}
			if ok {
				if ready {
					current.startup.ready_pending = false
					current.startup.ready_delivered = true
				} else {
					current.startup.fallback_delivered = true
					current.last_start_prompt_unix_ms = now
				}
			}
			break
		}
		sync.mutex_unlock(&bridge_runtime_mutex)
		if !ready do sync.mutex_unlock(&bridge_startup_io_mutex)
		if report_failure do fmt.eprintln("bridge startup reminder not acknowledged for", job.id, "— bounded recovery pending; inspect readiness status")
	}
}

// Token persistence proves issuance, not spawn. Ask the surviving PTY host to
// match the key in its actual child's immutable spec before acknowledging a retry.
// The I/O gate fences concurrent stop/relaunch; registry locks never cover I/O.
bridge_startup_confirm_spawned :: proc(socket, instance_id: string, run_count: int) -> (confirmed, queried: bool) {
	sync.mutex_lock(&bridge_startup_io_mutex)
	defer sync.mutex_unlock(&bridge_startup_io_mutex)
	rec: Bridge_Local_Agent_Token_Record
	sync.mutex_lock(&bridge_local_token_mutex)
	for i := len(bridge_local_token_records) - 1; i >= 0; i -= 1 {
		r := bridge_local_token_records[i]
		if r.agent_instance_id == instance_id && r.role == .Agent && r.invalidated_at_unix_ms == 0 {
			rec = bridge_startup_clone_rec(r)
			break
		}
	}
	sync.mutex_unlock(&bridge_local_token_mutex)
	defer { delete(rec.token_hash); delete(rec.agent_instance_id); delete(rec.instance_token) }
	if rec.token_hash == "" || (run_count > 0 && rec.run_count != run_count) do return false, false
	pid, ok := bridge_pty_host_startup_launch(socket, instance_id, rec.token_hash)
	if !ok do return false, false
	if !bridge_startup_rec_current(rec) do return false, false
	if pid == 0 do return false, true

	now := bridge_runtime_now_ms()
	sync.mutex_lock(&bridge_runtime_mutex)
	inst, exists := bridge_runtime_instance_snapshot_locked(instance_id)
	if bridge_runtime_stop_intent_active_locked(instance_id, now) ||
	   (exists && (inst.stopped_intent_unix_ms != 0 || inst.runtime_status == "stopped" || inst.runtime_status == "stopping")) {
		sync.mutex_unlock(&bridge_runtime_mutex)
		return false, false
	}
	// Restore startup state after bridge restart or a lost Spawn acknowledgment.
	// Duplicate delivery must preserve an already-recorded ready/fallback receipt.
	if !exists || inst.startup.generation == 0 || inst.startup.launch_key != rec.token_hash {
		bridge_startup_begin_locked(rec, now)
	}
	for &current in bridge_runtime_instances {
		if current.agent_instance_id != instance_id do continue
		current.pty_process_alive = true
		current.startup.pty_pid = pid
		if current.startup.armed_at_ms == 0 do current.startup.armed_at_ms = now
		ready := current.start_success_seen || current.startup.ready_pending || current.startup.ready_delivered || bridge_operation_terminal({state = current.startup.relay_state})
		if current.runtime_status == "failed" || current.runtime_status == "unknown" || current.runtime_status == "starting" {
			bridge_runtime_set_status_locked(instance_id, "running" if ready else "starting", "idle" if ready else "active", now, true)
		}
		break
	}
	sync.mutex_unlock(&bridge_runtime_mutex)
	bridge_startup_worker_ensure_started()
	return true, true
}

bridge_startup_job_current :: proc(id: string, generation: u64) -> bool {
    sync.mutex_lock(&bridge_runtime_mutex)
    inst, exists := bridge_runtime_instance_snapshot_locked(id)
    current := exists && inst.startup.generation == generation &&
        inst.stopped_intent_unix_ms == 0 && inst.runtime_status != "stopped" &&
        inst.runtime_status != "stopping" && inst.runtime_status != "failed"
    rec := bridge_startup_clone_rec(inst.startup.rec, context.temp_allocator)
    sync.mutex_unlock(&bridge_runtime_mutex)
    return current && bridge_startup_rec_current(rec)
}
