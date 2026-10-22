package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"

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
BRIDGE_STARTUP_INSTRUCTION :: "Run `./.heimdall/bin/ham-ctl agent start-success` now to confirm that this agent is ready."

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
		if current.startup.ready_pending || current.startup.ready_delivered do return true, false
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
	       inst.stopped_intent_unix_ms == 0 && inst.pty_process_alive &&
	       now >= s.next_attempt_ms && now - s.armed_at_ms >= BRIDGE_START_SUCCESS_PROMPT_AFTER_MS &&
	       now - s.armed_at_ms < BRIDGE_START_SUCCESS_TIMEOUT_MS
}

bridge_startup_relay :: proc(rec: Bridge_Local_Agent_Token_Record) -> bool {
	if rec.instance_token == "" || !sync.atomic_load(&bridge_hub_runtime_up) do return false
	params := fmt.tprintf("{{\"run_count\":%d}}", rec.run_count)
	relay := bridge_local_relay_agent_envelope("/api/v1/agent-actions/start-success", "agent.start_success", params, rec, 10000)
	defer delete(relay.body)
	return relay.ok && relay.status >= 200 && relay.status < 300
}

bridge_startup_deliver :: proc(instance_id: string) -> bool {
	socket := pty_host_socket_path()
	defer delete(socket)
	inst, exists := bridge_runtime_instance_snapshot(instance_id)
	if !exists || inst.startup.pty_pid <= 0 do return false
	// The host remembers a per-child receipt and partial write progress. Lost
	// replies are safely retried with the same key, payload and expected pid.
	text := bridge_startup_fallback_input(instance_id)
	defer delete(text)
	return bridge_startup_deliver_socket(socket, instance_id, inst.startup.pty_pid, inst.startup.launch_key, text)
}

bridge_startup_deliver_socket :: proc(socket, instance_id: string, pid: i32, launch_key, text: string) -> bool {
	frame := pty_host_encode_startup_input(instance_id, pid, launch_key, transmute([]byte)text)
	defer delete(frame)
	reply, ok := pty_host_request(socket, frame)
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
		if (kind != .Fallback && inst.startup.ready_pending && now >= inst.startup.next_attempt_ms) || (kind != .Readiness && bridge_startup_fallback_due(inst, now)) {
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
		ready := inst.startup.ready_pending && now >= inst.startup.next_attempt_ms
		if (kind == .Fallback && ready) || (kind == .Readiness && !ready) {
			sync.mutex_unlock(&bridge_startup_io_mutex)
			continue
		}
		ok := false
		attempted := false
		if ready {
			attempted = true
			// HTTP can be slow. Keep it off the fallback timer and lifecycle gate;
			// the hub authenticates the launch assertion and rejects stopped epochs.
			rec := bridge_startup_clone_rec(inst.startup.rec, context.temp_allocator)
			sync.mutex_unlock(&bridge_startup_io_mutex)
			ok = relay(rec)
		} else if bridge_startup_fallback_due(inst, now) {
			attempted = true
			ok = deliver(job.id)
		}
		if !attempted {
			sync.mutex_unlock(&bridge_startup_io_mutex)
			continue
		}
		report_failure := false
		sync.mutex_lock(&bridge_runtime_mutex)
		for &current in bridge_runtime_instances {
			if current.agent_instance_id != job.id || current.startup.generation != job.generation do continue
			current.startup.next_attempt_ms = now + BRIDGE_STARTUP_RETRY_MS
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
		if report_failure do fmt.eprintln("bridge startup reminder not acknowledged for", job.id, "— retrying; ensure ham-pty-host was updated with the bridge and this launch is still alive")
	}
}
