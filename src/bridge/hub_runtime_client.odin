package main

import "base:runtime"
import "core:crypto"
import "core:crypto/hash"
import base64 "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import bridgesvc "odin_test:lib/bridgesvc"
import contracts "odin_test:contracts"
import cfg_lib "odin_test:lib/config"
import httpc "odin_test:lib/httpc"
import local_socket "odin_test:lib/local_socket"
import ws "odin_test:lib/ws"
import vault "odin_test:lib/vault"

PROVIDER_TEST_TIMEOUT_SECONDS :: 120

// Vault state (passwordless vault: there is no plaintext "vault not configured"
// mode). It derives from what this bridge holds and nothing else:
//   - a keyring                  → Unlocked
//   - an identity, no keyring    → Locked (approved, awaiting a key)
//   - no usable identity         → Not_Enrolled (never enrolled, or identity lost)
// Only Unlocked may execute a command or return content; the other two refuse.
Vault_Status :: enum {
	Not_Enrolled,
	Locked,
	Unlocked,
}

// bridge_vault_bridge_dir is the per-bridge state directory,
// ~/.config/heimdall/bridges/<bridge_id>/ (trailing slash included). Several
// bridges can run on one machine under different accounts and must never share
// vault state, so everything vault-related a bridge persists is keyed by its id
// (REQ-T3-6). ok is false for an empty id or one that is not a single safe path
// segment, so a hostile or corrupt daemon_id can never escape the directory.
bridge_vault_bridge_dir :: proc(bridge_id: string, allocator := context.allocator) -> (dir: string, ok: bool) {
	if !bridge_vault_is_safe_bridge_id(bridge_id) do return "", false
	rel := strings.concatenate({"~/.config/heimdall/bridges/", bridge_id, "/"}, context.temp_allocator)
	expanded := cfg_lib.expand_home(rel)
	defer delete(expanded)
	return strings.clone(expanded, allocator), true
}

// bridge_vault_is_safe_bridge_id: a non-empty single path segment of
// [A-Za-z0-9_.-], never "." or "..". Shared by the per-bridge state directory
// and the per-bridge keyring/Keychain names (keystore_bridge_id_ok).
bridge_vault_is_safe_bridge_id :: proc(bridge_id: string) -> bool {
	if bridge_id == "" || bridge_id == "." || bridge_id == ".." do return false
	for c in transmute([]u8)bridge_id {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '-', '.':
		case:
			return false
		}
	}
	return true
}

bridge_vault_status :: proc() -> Vault_Status {
	status, kr := bridge_vault_status_and_key()
	vault.keyring_wipe(&kr)
	return status
}

// bridge_vault_status_and_key resolves the state AND hands back the key it read, so
// a gate that needs both decides on one read rather than two. kr is only populated
// when status is .Unlocked; the caller always wipes it. Gates branch on
// `status == .Unlocked`, never on anything weaker.
bridge_vault_status_and_key :: proc() -> (status: Vault_Status, kr: vault.Vault_Keyring) {
	if k, ok := bridge_read_vault_keyring(); ok do return .Unlocked, k
	bridge_id := bridge_config.daemon_id
	if keystore_bridge_id_is_enrolled(bridge_id) && bridge_identity_state(bridge_id) == .Ready do return .Locked, {}
	return .Not_Enrolled, {}
}

bridge_vault_status_string :: proc(status: Maybe(Vault_Status) = nil) -> string {
	s := status.? or_else bridge_vault_status()
	switch s {
	case .Not_Enrolled: return "not_enrolled"
	case .Locked:       return "locked"
	case .Unlocked:     return "unlocked"
	}
	return "not_enrolled"
}

// BRIDGE_WRAPPER_STALE_MS is how long an ACTIVE instance may go without any
// liveness signal before the bridge reconciles it to "unreachable". In the
// pty-host runtime, per-child liveness is proven by the daemon's pushed
// Host_Heartbeat digest (HOST_HEARTBEAT_INTERVAL = 30s in the Rust daemon), NOT
// by pane activity — so an alive-but-idle agent, or one that legitimately takes
// several seconds before calling start-success, stays fresh. Kept at 3x the
// 30s digest cadence so a couple of missed digests (a briefly busy daemon or an
// event-connection reconnect) never falsely reap a live agent; only a genuinely
// gone child/daemon crosses this window (and ChildExited reaps that instantly).
BRIDGE_WRAPPER_STALE_MS :: 90_000
BRIDGE_START_SUCCESS_TIMEOUT_MS :: 120_000
BRIDGE_START_SUCCESS_PROMPT_AFTER_MS :: 30_000
BRIDGE_START_SUCCESS_PROMPT_INTERVAL_MS :: 60_000
BRIDGE_ACTIVITY_ACTIVE_SOURCE_TTL_MS :: 12_000
BRIDGE_ACTIVITY_IDLE_SOURCE_TTL_MS :: 30_000
BRIDGE_STATE_SEQ_FLOOR_OFFSET_MS :: 3_600_000
// How long an operator stop suppresses wrapper-signal resurrection. Long enough
// to cover a slow wrapper teardown + one or two liveness ticks, short enough that
// a genuine relaunch of the SAME instance id is never blocked (launch clears it).
BRIDGE_STOP_INTENT_TTL_MS :: 15_000

Bridge_Runtime_Instance :: struct {
	agent_instance_id: string,
	state_seq: int,
	runtime_status: string,
	activity_status: string,
	activity_source: string,
	activity_updated_unix_ms: i64,
	last_seen_unix_ms: i64,
	start_deadline_unix_ms: i64,
	start_success_seen: bool,
	last_start_prompt_unix_ms: i64,
	startup: Bridge_Startup_State,
	// stopped_intent_unix_ms is set when an operator-requested stop begins. While it
	// is recent (< BRIDGE_STOP_INTENT_TTL_MS) a late wrapper liveness/subscribe
	// signal is IGNORED for status purposes so it cannot resurrect an intentionally
	// stopped instance back to running/starting. A fresh launch clears it.
	stopped_intent_unix_ms: i64,
	pty_process_alive: bool,
	// last_error is why the instance last went "failed" (REQ-ERR-PROTO-A); reported on
	// agent_instance_status so the hub can act on its class. Cleared on any other status.
	last_error:     Bridge_Error,
	has_last_error: bool,
}

Bridge_Runtime_Command_Result :: struct {
	command_id: string,
	result_json: string,
}

Bridge_Runtime_Launch :: struct {
	agent_instance_id: string,
	command_id: string,
	run_dir: string,
	// project_path is the project/chain directory from the launch descriptor
	// (what AGENTS.md tells the agent to work in). "" when the launch carried none.
	// Task System v2 uses it as the fallback repository for lease vcs enrichment
	// when ham-ctl's own cwd is not a git repository (agent_taskv2_vcs.odin).
	project_path: string,
	pane_id: string,
	agent_token: string,
	// role is the action role from the wake_agent run[] entry that (re)started this
	// instance ("worker"/"reviewer"). Empty means unknown (a launch predating this
	// field, or a non-wake launch). Used only for the coordinator stop-exemption
	// (defense in depth); unknown is treated as non-coordinator.
	role: string,
	// bridge_log relay: provider symbol and launch tick so a ChildExited within
	// BLOG_EARLY_EXIT_WINDOW becomes an agent_exited_early{provider,exit_code,
	// duration_ms} event. Plain values, nothing to free.
	provider_sym:   Blog_Sym,
	launched_at_ns: i64,
}

Bridge_Pane_Capture_Pending :: struct {
	command_id: string,
	pane_capture_request_id: string,
	conversation_id: string,
	message_id: string,
	agent_instance_id: string,
	width: int,
	line_limit: int,
	deadline_unix_ms: i64,
}

Bridge_Pane_Capture_Outgoing :: struct {
	command_id: string,
	result_json: string,
}

bridge_runtime_mutex: sync.Mutex
bridge_runtime_instances: [dynamic]Bridge_Runtime_Instance
bridge_runtime_results: [dynamic]Bridge_Runtime_Command_Result
bridge_runtime_launches: [dynamic]Bridge_Runtime_Launch
bridge_pane_capture_pending: [dynamic]Bridge_Pane_Capture_Pending
bridge_pane_capture_outgoing: [dynamic]Bridge_Pane_Capture_Outgoing
Bridge_Shell_Output_Outgoing :: struct {
	command_id:  string,
	result_json: string,
}
bridge_shell_output_outgoing: [dynamic]Bridge_Shell_Output_Outgoing

Bridge_Shell_Exited_Outgoing :: struct {
	event_json: string,
	// REQ-SHELL-4: path of this exit's durable envelope under
	// <data_dir>/shell_exited_outbox, or "" when it could not be persisted. The
	// drain removes it only after the frame goes out, so a restart replays
	// anything that was queued but not yet delivered.
	outbox_path: string,
}
bridge_shell_exited_outgoing: [dynamic]Bridge_Shell_Exited_Outgoing

// T8: preview tunnel streams — each open tunnel maps stream_id → live TCP socket.
Bridge_Tunnel_Stream :: struct {
	stream_id:  string,
	session_id: string,
	tcp_conn:   net.TCP_Socket,
	closed:     bool,
}
Bridge_Tunnel_Data_Outgoing :: struct {
	// Pre-built bridge→hub frame JSON. Carries tunnel_data/tunnel_close (preview
	// responses) and, since REQ-XM-4, proxy_open/proxy_data/proxy_close for streams
	// this bridge originated. The queue is frame-agnostic — it just hands JSON to the
	// runtime loop that owns the WS connection.
	json: string,
}
bridge_tunnel_streams:      map[string]^Bridge_Tunnel_Stream
bridge_tunnel_mu:           sync.Mutex
bridge_tunnel_data_outgoing: [dynamic]Bridge_Tunnel_Data_Outgoing
// Queue of instance ids whose status changed on a BACKGROUND thread (e.g. the
// pty-host events worker applying a ChildExited) and must be pushed to the hub
// immediately, without waiting for the next 45s bridge_heartbeat. The hub runtime
// loop (which owns the WS conn) drains this every tick. This is what keeps a
// self-exiting/crashed agent's "stopped" visible at the hub in ~real time.
bridge_runtime_status_outgoing: [dynamic]string
bridge_runtime_local_endpoint_started: bool
bridge_runtime_local_endpoint_unix_started: bool
bridge_runtime_local_endpoint_loopback_started: bool
bridge_runtime_local_endpoint_descriptor: string

bridge_hub_runtime_init :: proc() {
	bridge_command_dispatch_init()
	bridge_runtime_mutex = sync.Mutex{}
	bridge_runtime_instances = make([dynamic]Bridge_Runtime_Instance)
	bridge_runtime_results = make([dynamic]Bridge_Runtime_Command_Result, runtime.default_allocator())
	bridge_runtime_launches = make([dynamic]Bridge_Runtime_Launch)
	bridge_pane_capture_pending = make([dynamic]Bridge_Pane_Capture_Pending)
	bridge_pane_capture_outgoing = make([dynamic]Bridge_Pane_Capture_Outgoing)
	bridge_shell_output_outgoing = make([dynamic]Bridge_Shell_Output_Outgoing)
	bridge_shell_exited_outgoing = make([dynamic]Bridge_Shell_Exited_Outgoing)
	bridge_runtime_status_outgoing = make([dynamic]string)
	bridge_tunnel_streams = make(map[string]^Bridge_Tunnel_Stream, runtime.heap_allocator())
	bridge_tunnel_data_outgoing = make([dynamic]Bridge_Tunnel_Data_Outgoing)
	bridge_proxy_init()
	bridge_lsp_init()
}

// Reset / clear runtime instance and launch registries under lock (for tests).
bridge_runtime_test_reset :: proc() {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	clear(&bridge_runtime_instances)
	delete(bridge_runtime_launches)
	bridge_runtime_launches = make([dynamic]Bridge_Runtime_Launch)
	for s in bridge_runtime_status_outgoing {
		delete(s, runtime.default_allocator())
	}
	clear(&bridge_runtime_status_outgoing)
}

// bridge_hub_connection_teardown ends one hub connection: it retires every PTY stream
// worker and THEN closes the socket. It is the ONLY way this file closes a hub
// connection, and that is the point.
//
// WHY A WRAPPER RATHER THAN TWO STATEMENTS AND A COMMENT (REQ-SHELL-40). The ordering
// is load-bearing: `ws.close` does not take the send mutex REQ-SHELL-32 added, so a
// stream worker can be inside `bridge_hub_send` at the moment the fd is closed. Running
// the teardown FIRST means that once it returns no worker is eligible to write at all,
// which shrinks that window instead of widening it. But an ordering that lives in the
// sequence of two statements at a call site is only as durable as the next reader's
// attention — and a reordering would keep every test in the suite green, because the
// unit tests can assert what the teardown DOES without a live WS and cannot assert WHEN
// it is called relative to a close.
//
// So the ordering is made unrepresentable instead of documented. There is no `ws.close`
// left in the reconnect path to reorder; both halves sit in one procedure, adjacent, with
// the reason between them. This is the same conclusion REQ-SHELL-32 reached about its
// send mutex — the lock belonged inside `ws.send_text` rather than with the callers who
// had to remember it, because caller-side discipline is exactly what had failed.
//
// Safe on every path, including the two that never had a live connection: the teardown
// returns 0 and logs nothing when there are no workers, and `ws.close` is guarded by
// `conn.connected` and is therefore idempotent.
bridge_hub_connection_teardown :: proc(conn: ^ws.Connection) {
	// FIRST: no worker may outlive the connection it was created for. Each one holds a
	// pointer to a stack local of bridge_hub_runtime_worker's reconnect loop, which the
	// next iteration refills — so a survivor would begin writing into a connection it was
	// never attached to. See bridge_pty_stream_stop_all_for_reconnect for the full
	// reasoning and for what re-establishes the streams (the hub re-attaches out of its
	// inventory convergence, REQ-SHELL-40 Pass 3).
	_ = bridge_pty_stream_stop_all_for_reconnect()
	// THEN, and only then, the socket.
	ws.close(conn)
}

// connection_replaced handling: the hub sends it on the OLD socket when the same
// bridge id reconnects ("newest connection wins"). A flat 500ms reconnect would make
// two processes sharing one identity flap forever, so a replaced connection waits a
// long, doubling backoff instead. The reader sets the flag and the next backoff; the
// reconnect loop consumes them. Atomic because they cross the handler/loop boundary.
BRIDGE_HUB_REPLACED_BACKOFF_MIN_S :: 30
BRIDGE_HUB_REPLACED_BACKOFF_MAX_S :: 300
bridge_hub_replaced_flag: bool
bridge_hub_replaced_backoff_s: int

// bridge_hub_replaced_backoff_next returns the backoff after one more consecutive
// replacement: 30s first, doubling, capped at 300s.
bridge_hub_replaced_backoff_next :: proc(prev_s: int) -> int {
	if prev_s <= 0 do return BRIDGE_HUB_REPLACED_BACKOFF_MIN_S
	return min(prev_s * 2, BRIDGE_HUB_REPLACED_BACKOFF_MAX_S)
}

// bridge_hub_note_connection_replaced records a replacement and returns the backoff
// (seconds) the reconnect loop will wait once this connection closes. The hub answers
// EVERY frame on a stale socket with connection_replaced, so repeats on the same
// connection neither advance the backoff again nor report first=true.
bridge_hub_note_connection_replaced :: proc() -> (backoff_s: int, first: bool) {
	if sync.atomic_load(&bridge_hub_replaced_flag) do return sync.atomic_load(&bridge_hub_replaced_backoff_s), false
	next := bridge_hub_replaced_backoff_next(sync.atomic_load(&bridge_hub_replaced_backoff_s))
	sync.atomic_store(&bridge_hub_replaced_backoff_s, next)
	sync.atomic_store(&bridge_hub_replaced_flag, true)
	return next, true
}

// bridge_hub_take_replaced_backoff is called once per closed READY connection. It
// returns the backoff to wait if that connection was replaced; otherwise the
// connection ended normally, so the consecutive-replacement backoff resets to 0.
bridge_hub_take_replaced_backoff :: proc() -> (backoff_s: int, replaced: bool) {
	if sync.atomic_exchange(&bridge_hub_replaced_flag, false) {
		return sync.atomic_load(&bridge_hub_replaced_backoff_s), true
	}
	sync.atomic_store(&bridge_hub_replaced_backoff_s, 0)
	return 0, false
}

bridge_hub_runtime_worker :: proc() {
	credential_snapshot_337 := bridge_credential_snapshot()
	defer delete(credential_snapshot_337)
	if strings.trim_space(bridge_config.daemon_url) == "" || strings.trim_space(credential_snapshot_337) == "" {
		fmt.println("bridge hub runtime disabled: missing daemon_url or bridge_token (has the bridge enrolled? check the bridge_token/--bridge-token-file)")
		return
	}
	// Only log each distinct failure the FIRST time (and periodically) so a down
	// proxy/tunnel doesn't spam the log on every reconnect, but the operator still sees
	// exactly which step is failing.
	// The structured twin of each line is a blog_warn (bridge_log relay): it is
	// rate-limited by the same rule, dedup'd into `count` in the ring, and ships
	// to the hub after the NEXT successful bridge_ready — which is exactly when
	// "why did this bridge keep failing to connect" becomes answerable remotely.
	last_failure := ""
	defer delete(last_failure)
	attempts := 0
	reconnect_failures := 0 // consecutive attempts that did not reach bridge_ready
	log_failure :: proc(last: ^string, count: ^int, msg: string, code: Blog_Code, fields: ..Blog_Field) {
		count^ += 1
		if msg != last^ || count^ % 20 == 1 {
			fmt.printfln("bridge hub runtime: %s (attempt %d)", msg, count^)
			blog_emit(.Warn, code, fields)
			delete(last^)
			last^ = strings.clone(msg)
		}
	}
	for {
		if sync.atomic_load(&bridge_hub_traffic_stopped) do return
		ws_url := bridge_hub_ws_url(bridge_config.daemon_url)
		if ws_url == "" {
			fmt.println("bridge hub runtime disabled: daemon_url must be an http:// or https:// base URL")
			return
		}
		credential := bridge_credential_snapshot()
        conn, ok := ws.connect_with_bearer(ws_url, credential)
        delete(credential)
		conn.send_disabled = &bridge_hub_traffic_stopped
		if !ok {
			connect_err := ws.last_connect_error()
			code, stage, why := blog_connect_failure(connect_err)
			if status := blog_http_status_from_reason(connect_err); status != 0 {
				log_failure(&last_failure, &attempts, fmt.tprintf("cannot connect WS %s — %s", ws_url, connect_err), code, blog_sym(.stage, stage), blog_int(.hub_status, status))
			} else {
				log_failure(&last_failure, &attempts, fmt.tprintf("cannot connect WS %s — %s", ws_url, connect_err), code, blog_sym(.stage, stage), blog_sym(.reason, why))
			}
			bridge_hub_reconnect_sleep(&reconnect_failures)
			continue
		}
		// Nothing negotiated on a previous connection carries over: only this
		// connection's bridge_ready can re-enable a heartbeat omission.
		bridge_hub_reset_heartbeat_negotiation()
		hello := bridge_hub_hello_json()
		if !ws.send_text(&conn, hello) {
			log_failure(&last_failure, &attempts, "WS connected but sending hello failed (connection dropped immediately)", .hub_connect_failed, blog_sym(.stage, .hello), blog_sym(.reason, .write_error))
			bridge_hub_connection_teardown(&conn)
			bridge_hub_reconnect_sleep(&reconnect_failures)
			continue
		}
		ready_deadline := time.to_unix_nanoseconds(time.now()) + i64(5 * time.Second)
		ready := false
		got_error := false
		plan_disabled := false
		hub_error := ""
		hub_catalog_etag := ""
		for time.to_unix_nanoseconds(time.now()) < ready_deadline {
			if text, got := ws.poll_text(&conn); got {
				msg_type := extract_json_string(text, "type", "")
				if msg_type == "bridge_ready" {
					ready_bridge_id := extract_json_string(text, "bridge_id", "")
					if ready_bridge_id != "" {
						bridge_config.daemon_id = ready_bridge_id
					} else {
						delete(ready_bridge_id)
					}
					hub_catalog_etag = extract_json_string(text, "catalog_etag", "")
					bridge_hub_apply_ready_settings(text)
					// This connection was opened with the current credential.
					sync.atomic_store(&bridge_credential_reauth_pending, false)
					ready = true
					delete(msg_type)
					delete(text)
					break
				}
				if msg_type == "bridge_error" {
					got_error = true
					hub_error = bridge_hub_error_log_message(text)
					code := extract_json_string(text, "code", "")
					plan_disabled = code == "plan_limit_reached"
					delete(code)
					// REQ-EA-4: an atomic enrollment whose credential the hub now refuses
					// was rolled back (cancel or deadline), whether or not the
					// bridge_enrollment_result frame arrived first.
					if bridge_enroll_atomic_is_active() && strings.contains(hub_error, "bridge token is invalid") {
						bridge_enroll_atomic_on_result(`{"type":"bridge_enrollment_result","committed":false}`)
					}
					_ = bridge_hub_session_frame(msg_type, text)
					delete(msg_type)
					delete(text)
					break
				}
				delete(msg_type)
				delete(text)
			}
			time.sleep(25 * time.Millisecond)
		}
		if ready {
			fmt.println("bridge hub runtime ready")
			delete(last_failure); last_failure = ""; attempts = 0; reconnect_failures = 0
			if bridge_provider_catalog_needs_sync(hub_catalog_etag) {
				request := bridge_provider_catalog_request_json()
				_ = ws.send_text(&conn, request)
				delete(request)
			}
			delete(hub_catalog_etag)
			// REQ-RECON-1: reconcile persisted shell sessions against the live
			// pty-host agent list on every hub-WS reconnect. Runs on a background
			// thread: bridge_pty_host_ensure_daemon may spawn the daemon and poll it
			// for up to 5s, and doing that inline would stall the WS service loop
			// (heartbeats and command replies) on every reconnect. The shell_exited
			// events it enqueues are drained by the loop started just below.
			thread.run(bridge_shell_session_reconcile_now)
			// REQ-BR-1: and periodically in between, so a lost exit is reported within
			// one sweep interval instead of waiting for the next reconnect.
			bridge_shell_session_sweep_ensure_started()
			// REQ-REAP-STARTUP-1: reconcile surviving agent instances on pty-host
			// against Hub's active instance list on reconnect to reap orphaned processes.
			thread.run(bridge_agent_instance_reconcile_now)
			// REQ-REAP-SHELL-1: reconcile surviving shell sessions on pty-host
			// against Hub's active shells list on reconnect to reap orphaned processes.
			thread.run(bridge_shell_orphan_reconcile_now)
			bridge_action_scheduler_connection_changed()
            sync.atomic_store(&bridge_hub_runtime_up, true)
			if !bridge_hub_is_enroll_only_runtime() do bridge_local_status_write(true)
			bridge_hub_runtime_loop(&conn)
			bridge_action_scheduler_connection_changed()
            sync.atomic_store(&bridge_hub_runtime_up, false)
			if !bridge_hub_is_enroll_only_runtime() do bridge_local_status_write(false)
			// NOT beside the PTY stream teardown, and not inside
			// bridge_hub_connection_teardown with it, deliberately: this one has no
			// before-close requirement. It closes stdin fds, SIGTERMs language servers
			// and sets statuses, and never touches `conn` — so naming it in a procedure
			// whose entire purpose is the close ordering would imply a constraint it
			// does not have, and would additionally start running it on the two paths
			// below that never had a ready connection.
			bridge_lsp_stop_all()
			if backoff_s, replaced := bridge_hub_take_replaced_backoff(); replaced {
				// Never exit here: under systemd Restart=always that would just
				// restart the process and keep the flapping.
				fmt.printfln("bridge hub runtime: connection closed after replacement, reconnecting in %ds…", backoff_s)
				blog_warn(.hub_ws_closed, blog_sym(.reason, .replaced), blog_int(.duration_ms, i64(backoff_s) * 1000))
				bridge_hub_connection_teardown(&conn)
				time.sleep(time.Duration(backoff_s) * time.Second)
				continue
			}
			fmt.println("bridge hub runtime: connection closed, reconnecting…")
			blog_warn(.hub_ws_closed, blog_sym(.reason, .eof))
		} else if got_error {
			delete(hub_catalog_etag)
			log_failure(&last_failure, &attempts, hub_error, .hub_rejected, blog_sym(.reason, blog_hub_error_reason(hub_error)))
			delete(hub_error)
		} else {
			delete(hub_catalog_etag)
			log_failure(&last_failure, &attempts, "no bridge_ready within 5s after hello — hub didn't accept the session (slow link over the tunnel, or hub-side rejection)", .hub_ready_timeout, blog_sym(.stage, .ready))
		}
		bridge_hub_connection_teardown(&conn)
		if sync.atomic_load(&bridge_hub_traffic_stopped) do return
		if plan_disabled {
			fmt.println("bridge hub runtime: disabled by plan limits; retrying in 60s")
			time.sleep(60 * time.Second)
			continue
		}
		bridge_hub_reconnect_sleep(&reconnect_failures)
	}
}

// bridge_hub_runtime_up: true while a hub runtime session is established
// (between bridge_ready and the loop ending). The local endpoint answers lease
// verbs with `hub_unreachable` while it is false — the request was provably
// never sent, so ham-ctl may retry it (Task System v2 F2).
bridge_hub_runtime_up: bool

// REQ-ERR-PROTO-B: reconnects back off exponentially from 500ms to 30s with +-20%
// jitter, so a hub restart is not met by every bridge redialling twice a second in
// lockstep. The count resets once a connection reaches bridge_ready, so the first
// redial after a healthy session ends still comes after ~500ms.
BRIDGE_HUB_RECONNECT_BACKOFF :: Bridge_Backoff_Policy{base_ms = 500, max_ms = 30_000, jitter_pct = 20}

bridge_hub_reconnect_sleep :: proc(failures: ^int) {
	failures^ += 1
	time.sleep(time.Duration(bridge_backoff_delay_ms(BRIDGE_HUB_RECONNECT_BACKOFF, failures^, rand.uint64())) * time.Millisecond)
}

// A bridge_error is a post-upgrade protocol error, not proof that bearer-token
// authentication failed. Preserve the Hub's message so catalog/schema/runtime
// failures are actionable instead of being mislabeled as an enrollment problem.
bridge_hub_error_log_message :: proc(text: string) -> string {
	detail := extract_json_string(text, "message", "")
	defer delete(detail)
	if strings.trim_space(detail) == "" {
		return strings.clone("hub sent bridge_error after hello without a diagnostic message")
	}
	path := extract_json_string(text, "upgrade_path", "")
	defer delete(path)
	if path == "/settings/account" {
		// The UI uses hash routing; accept only the hub-owned account path.
		return strings.concatenate({"hub rejected bridge session after hello: ", detail, " Upgrade: ", strings.trim_right(bridge_config.daemon_url, "/"), "/#/settings/account"})
	}
	return strings.concatenate({"hub rejected bridge session after hello: ", detail})
}

// BRIDGE_HUB_HEARTBEAT_INTERVAL is the idle cadence of the bridge->hub
// bridge_heartbeat digest. It is only a reconciliation/keepalive/schedules-version
// backstop: live instance status changes are pushed IMMEDIATELY as separate
// agent_instance_status frames (see bridge_runtime_set_status callers), so the
// hub and UI stay live regardless of this cadence. Kept comfortably below the
// hub's 120s bridge-WS read deadline so a single delayed heartbeat never trips a
// spurious disconnect, and below the 90s stale-reap window so reconciliation stays
// timely. schedules_version rides the heartbeat ack, so this also bounds
// scheduled-prompt pickup latency (~45s), which is fine for cron/interval work.
//
// That is the default; the hub's bridge_ready heartbeat_interval_seconds overrides
// it (REQ-ERR-PROTO-B), clamped so a bad value can neither flood the hub nor let the
// connection go quiet past its read deadline.
BRIDGE_HUB_HEARTBEAT_INTERVAL :: 45 * time.Second
BRIDGE_HUB_HEARTBEAT_INTERVAL_MIN_S :: 5
BRIDGE_HUB_HEARTBEAT_INTERVAL_MAX_S :: 60

bridge_hub_heartbeat_interval_ns := i64(BRIDGE_HUB_HEARTBEAT_INTERVAL)

// bridge_hub_set_heartbeat_interval applies bridge_ready's heartbeat_interval_seconds;
// 0 (an older hub that does not send it) restores the default.
bridge_hub_set_heartbeat_interval :: proc(seconds: int) {
	interval := i64(BRIDGE_HUB_HEARTBEAT_INTERVAL)
	if seconds > 0 do interval = i64(clamp(seconds, BRIDGE_HUB_HEARTBEAT_INTERVAL_MIN_S, BRIDGE_HUB_HEARTBEAT_INTERVAL_MAX_S)) * i64(time.Second)
	sync.atomic_store(&bridge_hub_heartbeat_interval_ns, interval)
}

// bridge_hub_apply_ready_settings applies the session-tuning members of bridge_ready.
// Every one is optional: an older hub omits them and the bridge keeps the default.
bridge_hub_apply_ready_settings :: proc(text: string) {
	// Absent -> keep the default (on).
	bridge_heartbeat_stats_set_enabled(extract_json_bool(text, "heartbeat_stats", true))
	// Absent -> the 45s default.
	bridge_hub_set_heartbeat_interval(extract_json_int(text, "heartbeat_interval_seconds", 0))
	// Absent on older hubs, which neither bound the session by its credential nor
	// understand bridge_reauth.
	sync.atomic_store(&bridge_hub_credential_reauth_supported, extract_json_bool(text, "credential_reauth", false))
	// Minimal heartbeat plan T4: each flag is honoured on its own and only for the
	// connection whose bridge_ready carried it; absent (an older or rolled-back hub)
	// means the legacy members stay.
	sync.atomic_store(&bridge_hub_heartbeat_metadata_omission, extract_json_bool(text, "heartbeat_metadata_omission", false))
	sync.atomic_store(&bridge_hub_diagnostics_frame_v1, extract_json_bool(text, "diagnostics_frame_v1", false))
}

// Per-connection heartbeat negotiation (minimal heartbeat plan §4.4, T4). Both start
// false and are cleared again before every connection's hello
// (bridge_hub_reset_heartbeat_negotiation), so a reconnect to a hub that no longer
// advertises a flag (downgrade, rollback) sends the legacy heartbeat.
//
// heartbeat_metadata_omission: the hub treats this connection's hello as the only
// metadata authority (it also requires our hello to list
// contracts.BRIDGE_FEATURE_HEARTBEAT_METADATA_OMISSION), so heartbeats may drop
// capabilities/features.
bridge_hub_heartbeat_metadata_omission: bool
// diagnostics_frame_v1: the hub accepts the separate bridge_diagnostics frame. Our
// heartbeat drops its diagnostic members only once that frame is actually sent
// (BRIDGE_DIAGNOSTICS_SENDER_AVAILABLE); until then the flag is recorded but the
// diagnostics keep riding the heartbeat, so the hub never loses them.
bridge_hub_diagnostics_frame_v1: bool

// BRIDGE_DIAGNOSTICS_SENDER_AVAILABLE: this Bridge emits the bridge_diagnostics frame
// (plan T6, bridge_diagnostics.odin), so a connection that negotiated
// diagnostics_frame_v1 drops the diagnostic members from its heartbeat. Turning it
// off restores the legacy heartbeat diagnostics and stops the new frame together.
BRIDGE_DIAGNOSTICS_SENDER_AVAILABLE :: true

bridge_hub_reset_heartbeat_negotiation :: proc() {
	sync.atomic_store(&bridge_hub_heartbeat_metadata_omission, false)
	sync.atomic_store(&bridge_hub_diagnostics_frame_v1, false)
}

// Bridge_Heartbeat_Shape selects which optional member groups a heartbeat carries.
// The zero value is the legacy frame: capabilities/features and every diagnostic
// member. The two omissions are independent; with both set the frame is the
// eight-member core (plan §2.1).
Bridge_Heartbeat_Shape :: struct {
	omit_metadata:    bool,
	omit_diagnostics: bool,
}

// bridge_hub_heartbeat_shape is the shape the current connection negotiated.
bridge_hub_heartbeat_shape :: proc() -> Bridge_Heartbeat_Shape {
	return Bridge_Heartbeat_Shape{
		omit_metadata    = sync.atomic_load(&bridge_hub_heartbeat_metadata_omission),
		omit_diagnostics = bridge_diagnostics_negotiated(),
	}
}

// bridge_hub_send_connect_heartbeat sends the one heartbeat every connection opens
// with, right after bridge_ready is handled (plan T1b), and returns the anchor the
// periodic cadence counts from. Waiting a full interval instead would leave the hub
// without the search tuple, the instance status tuples (the repair for status pushes
// dropped around the disconnect) and heartbeat liveness for that long after every
// reconnect. It is an ordinary heartbeat frame, so hubs of every version accept it.
bridge_hub_send_connect_heartbeat :: proc(conn: ^ws.Connection) -> (anchor_ns: i64) {
	if sync.atomic_load(&bridge_hub_traffic_stopped) do return time.to_unix_nanoseconds(time.now())
	hb := bridge_hub_heartbeat_json()
	_ = ws.send_text(conn, hb)
	delete(hb)
	// Anchored after the send, so building the frame (stats fork `ps`) does not pull
	// the first periodic beat earlier than one interval after this one.
	return time.to_unix_nanoseconds(time.now())
}

// bridge_hub_heartbeat_due reports whether the periodic heartbeat is due and, when it
// is, moves the anchor to now, so a tick sends at most one beat. The interval is the
// one current at the tick: a shorter interval from a newer bridge_ready fires one
// overdue beat at once, never a catch-up burst.
bridge_hub_heartbeat_due :: proc(last_ns: ^i64, now_ns, interval_ns: i64) -> bool {
	if now_ns - last_ns^ < interval_ns do return false
	last_ns^ = now_ns
	return true
}

BRIDGE_HUB_INBOUND_BUDGET :: 32

bridge_hub_runtime_loop :: proc(conn: ^ws.Connection) {
	if sync.atomic_load(&bridge_hub_traffic_stopped) do return
	defer bridge_tool_live_disconnect()
	connection_generation := bridge_command_dispatch_begin_connection()
	// PER-CONNECTION inbound chunk reassembly (REQ-SHELL-36). The hub splits any
	// hub->bridge command larger than one 16-bit WS frame into ordered kind:"chunk"
	// frames (write_ws_command); we rebuild the original command here before it reaches
	// the dispatcher. Small commands — the overwhelming majority — never touch this.
	//
	// DECLARED HERE, AND THAT IS THE DESIGN, NOT AN ACCIDENT OF SCOPE: its lifetime is
	// exactly this connection's. When the loop exits on a disconnect the deferred free
	// below discards every partial stream, so a chunk sequence interrupted by a
	// reconnect is a command that never arrived rather than half a command that did.
	// Hoisting this to a global to "keep partials across reconnects" would be a bug: the
	// hub does not retransmit, so the tail is never coming, and the two ends would then
	// disagree about an in-flight command — the exact state the core invariant forbids.
	reassemblies := make([dynamic]Hub_Command_Reassembly)
	defer hub_command_reassemblies_free(&reassemblies)
	// Send one heartbeat immediately on connect so the hub gets the initial
	// instance digest + schedules_version handshake without waiting a full cycle.
	last_heartbeat := bridge_hub_send_connect_heartbeat(conn)
	// Plan T6: the connect-time diagnostics snapshot, collected off this thread and
	// sent by bridge_diagnostics_tick once ready, then its own interval timer.
	diagnostics_cadence: Bridge_Diagnostics_Cadence
	bridge_diagnostics_connect(&diagnostics_cadence, last_heartbeat)
	// The hub keeps agent blockers in memory only: resend every snapshot on connect.
	bridge_blockers_mark_all_dirty()
	bridge_tool_live_drain(conn, true)
	last_iteration := time.now()
	for conn.connected && !sync.atomic_load(&bridge_hub_traffic_stopped) {
		now_iteration := time.now()
		bridge_command_dispatch_observe_loop_delay(time.diff(last_iteration, now_iteration))
		last_iteration = now_iteration
		inbound_count := 0
		for inbound_count < BRIDGE_HUB_INBOUND_BUDGET {
			text, opcode, got := ws.poll_frame(conn)
			if !got do break
			inbound_count += 1
			// REQ-PTY-NET-3: a BINARY frame from the hub is pty input (a pty_wire session
			// frame). It never enters the command dispatcher: no command_id, no result.
			if opcode == 0x2 {
				bridge_hub_handle_binary_frame(conn, transmute([]byte)text)
				delete(text)
				continue
			}
			if hub_command_frame_is_chunk(text) {
				// A chunk frame is NEVER dispatched as a command. Only a complete
				// stream is.
				assembled, complete, ok := hub_command_reassemble(&reassemblies, text)
				if !ok { ws.abort(conn); delete(text); break }
				if ok && complete {
					if !bridge_command_dispatch(conn, assembled, connection_generation) do bridge_hub_handle_command(conn, assembled)
					delete(assembled)
				}
			} else {
				if !bridge_command_dispatch(conn, text, connection_generation) do bridge_hub_handle_command(conn, text)
			}
			delete(text)
			if sync.atomic_load(&bridge_hub_traffic_stopped) do break
		}
		// Stop before ANY drain or heartbeat in the iteration receiving retirement.
		if sync.atomic_load(&bridge_hub_traffic_stopped) do break
		bridge_command_dispatch_drain(conn, connection_generation)
		bridge_pane_capture_expire_pending()
		bridge_pane_capture_drain_outgoing(conn)
		bridge_shell_output_drain_outgoing(conn)
		bridge_shell_exited_drain_outgoing(conn)
		bridge_tool_live_drain(conn)
		// REQ-SHELL-10: immediately after the exit drain, so the fast path's exits are
		// on the wire ahead of the snapshot that is meant to be the safety net for
		// whatever it lost.
		//
		// Ordering is an optimisation, NOT the correctness argument. Do not read this
		// placement as the thing that keeps the exit outbox and the inventory from
		// disagreeing — the outbox makes no ordering promise across a bridge restart, so
		// a reorder here would look harmless and change nothing about what is guaranteed.
		// What keeps them honest is the pair of guards on APPLY: an outbox exit is
		// OBSERVED and wins permanently, a status the hub synthesizes from a missing
		// inventory entry is not and yields to a later observed exit. See
		// shell_inventory.odin.
		bridge_shell_inventory_drain_outgoing(conn)
		// REQ-PTY-NET-1: the pty drain is byte-budgeted per turn and says whether it
		// left records behind; that counts as "busy" for the sleep below, so a pane
		// streaming faster than one budget per 25 ms is not throttled by the idle cadence.
		pty_more := bridge_pty_stream_drain_outgoing(conn)
		bridge_tunnel_data_drain_outgoing(conn)
		bridge_lsp_drain_outgoing(conn)
		// bridge_log relay: at most one frame per iteration, only after
		// bridge_ready (this loop), gated by the telemetry switch inside.
		bridge_log_drain_outgoing(conn)
		// Flush any status transitions applied on background threads (e.g. a
		// pty-host ChildExited) so "stopped"/"unreachable" reaches the hub now,
		// not on the next heartbeat.
		bridge_runtime_drain_status_pushes(conn)
		bridge_blockers_drain_outgoing(conn)
		bridge_credential_reauth_drain(conn)
		now := time.to_unix_nanoseconds(time.now())
		if bridge_hub_heartbeat_due(&last_heartbeat, now, sync.atomic_load(&bridge_hub_heartbeat_interval_ns)) {
			hb := bridge_hub_heartbeat_json()
			_ = ws.send_text(conn, hb)
			delete(hb)
			// Reconcile: the next drain resends every instance's full snapshot.
			bridge_blockers_mark_all_dirty()
			hub_command_reassembly_sweep(&reassemblies, now)
			// Keep the token-free local status (ham-bridge status --json) fresh, vault included.
			if !bridge_hub_is_enroll_only_runtime() do bridge_local_status_write(true)
		}
		bridge_diagnostics_tick(conn, &diagnostics_cadence, now, sync.atomic_load(&bridge_hub_heartbeat_interval_ns))
		// Yield after a bounded burst. Idle connections retain the low-wake cadence;
		// busy connections do not artificially process only 40 frames per second.
		time.sleep(1 * time.Millisecond if inbound_count > 0 || pty_more else 25 * time.Millisecond)
	}
}

Bridge_Nudge_Record :: struct {
	key: string,
	timestamp_ms: i64,
}
bridge_recent_nudges: [dynamic]Bridge_Nudge_Record
bridge_recent_nudges_mutex: sync.Mutex

bridge_should_debounce_nudge :: proc(instance_id, task_id: string) -> bool {
	if instance_id == "" || task_id == "" do return false
	key := strings.concatenate({instance_id, ":", task_id})
	defer delete(key)
	now := time.now()
	now_ms := time.to_unix_nanoseconds(now) / 1_000_000

	sync.mutex_lock(&bridge_recent_nudges_mutex)
	defer sync.mutex_unlock(&bridge_recent_nudges_mutex)

	i := 0
	for i < len(bridge_recent_nudges) {
		if now_ms - bridge_recent_nudges[i].timestamp_ms > 3000 {
			delete(bridge_recent_nudges[i].key)
			unordered_remove(&bridge_recent_nudges, i)
		} else {
			i += 1
		}
	}

	for rec in bridge_recent_nudges {
		if rec.key == key && (now_ms - rec.timestamp_ms < 1500) {
			return true
		}
	}

	append(&bridge_recent_nudges, Bridge_Nudge_Record{key = strings.clone(key), timestamp_ms = now_ms})
	return false
}

// ===== Session credential renewal (bridge_reauth) =====
//
// A hub that advertises credential_reauth ends a bridge session when the access
// token that opened it expires. After every successful refresh the bridge renews
// the live session in-band with the new access token, so a healthy bridge is never
// disconnected. Against an older hub nothing is sent (it would not understand it,
// and does not end sessions). If the renewal is refused or never sent, the hub
// closes the session with bridge_token_expired and the reconnect loop dials again
// with the current (refreshed) credential.
bridge_hub_credential_reauth_supported: bool
bridge_credential_reauth_pending: bool

BRIDGE_REAUTH_FRAME :: struct {
	type:         string,
	access_token: string,
}

bridge_credential_reauth_drain :: proc(conn: ^ws.Connection) {
	if !sync.atomic_load(&bridge_credential_reauth_pending) do return
	sync.atomic_store(&bridge_credential_reauth_pending, false)
	if !sync.atomic_load(&bridge_hub_credential_reauth_supported) do return
	credential := bridge_credential_snapshot()
	defer delete(credential)
	if strings.trim_space(credential) == "" do return
	data, err := json.marshal(BRIDGE_REAUTH_FRAME{type = "bridge_reauth", access_token = credential}, allocator = context.temp_allocator)
	if err != nil do return
	_ = ws.send_text(conn, string(data))
}

// bridge_hub_session_frame logs the hub's answers about the session credential.
// Returns true when the frame was one of them.
bridge_hub_session_frame :: proc(type, text: string) -> bool {
	if type == "bridge_reauth_result" {
		if extract_json_bool(text, "ok", false) {
			fmt.printfln("bridge hub session renewed with the refreshed credential (valid for %ds)", extract_json_int(text, "expires_in", 0))
		} else {
			code := extract_json_string(text, "code", "")
			defer delete(code)
			if code == "bridge_sunset_pending" do bridge_hub_stop_traffic(false)
			if code == "bridge_credential_revoked" do bridge_hub_stop_traffic(true)
			msg := extract_json_string(text, "message", "")
			defer delete(msg)
			if sync.atomic_load(&bridge_hub_traffic_stopped) {
				fmt.eprintfln("bridge hub refused the session renewal: %s; Hub traffic paused until explicit activation", msg)
			} else {
				fmt.eprintfln("bridge hub refused the session renewal: %s; the session will end at the old credential's expiry and reconnect", msg)
			}
		}
		return true
	}
	if type == "bridge_error" {
		code := extract_json_string(text, "code", "")
		defer delete(code)
		msg := extract_json_string(text, "message", "")
		defer delete(msg)
		switch code {
		case "bridge_token_expired":
			fmt.eprintfln("bridge hub ended the session: the access token expired (%s); reconnecting with the current credential", msg)
		case "bridge_sunset_pending":
			// The hub may restore this machine if replacement enrollment rolls
			// back. Keep credential files and the profile intact across restarts.
			bridge_hub_stop_traffic(false)
			fmt.eprintfln("bridge retirement is pending enrollment (%s); Hub traffic paused; retain credentials and explicitly resume after rollback", msg)
		case "bridge_credential_revoked":
			bridge_hub_stop_traffic(true)
			fmt.eprintfln("bridge hub ended the session: this bridge's credential is revoked (%s); re-enrollment is required", msg)
			// Stay parked. The runtime owner joins stream writers before closing
			// its connection; process exit here would bypass that teardown.
		case:
			fmt.eprintfln("bridge hub error: %s", msg)
		}
		return true
	}
	return false
}

bridge_hub_handle_command :: proc(conn: ^ws.Connection, text: string) {
	type := extract_json_string(text, "type", "")
	defer delete(type)
	if bridge_hub_session_frame(type, text) do return
	if bridge_provider_catalog_handle_frame(conn, type, text) do return
	if bridge_provider_handle_discover_frame(conn, type, text) do return
	if bridge_provider_handle_models_frame(conn, type, text) do return
	if type == "bridge_heartbeat_ack" {
		// H7 cross-bridge reap: the hub tells us which of the instances we reported
		// active have actually been relaunched on ANOTHER bridge. We hold a stale old
		// runtime for each, so invalidate its local tokens: the old ham-wrapper then
		// fails its next wrapper.liveness.ping and self-terminates. Transport/host
		// independent — no tmux/PID reaping needed.
		superseded, _ := bridge_provider_json_extract_string_array(text, "superseded_instance_ids")
		defer {
			for id in superseded do delete(id)
			delete(superseded)
		}
		for id in superseded {
			if strings.trim_space(id) == "" do continue
			n := bridge_agent_token_invalidate_instance(id)
			if n > 0 {
				fmt.println("bridge reap: instance relaunched on another bridge; invalidated local tokens", id, "count", n)
				bridge_runtime_set_status(id, "stopped", "idle")
				bridge_runtime_remove_launch(id)
			}
		}
		schedules_version := extract_json_int(text, "schedules_version", 0)
		bridge_action_scheduler_notify_version(schedules_version)
        bridge_action_scheduler_notify_snapshot(extract_json_string(text, "schedules_epoch", ""), i64(extract_json_int(text, "schedules_revision", -1)), bridge_runtime_now_ms())
		return
	}
	if type == "agent_instance_status_ack" {
		// The hub acks every agent status report; the bridge relies on periodic
		// re-reports rather than acks, so this is deliberately a no-op.
		return
	}
	if type == "protocol_error" {
		// The hub refused a frame it could not process (REQ-ERR-PROTO-A). Never
		// answered, so two peers cannot bounce refusals; logged for protocol drift.
		werr, _ := contracts.wire_error_parse(text, context.temp_allocator)
		frame_type := extract_json_string(text, "frame_type", "", context.temp_allocator)
		fmt.println("bridge hub runtime: hub refused frame", frame_type, contracts.error_code_string(werr.code), werr.cause)
		return
	}
	if type == "connection_replaced" {
		backoff_s, first := bridge_hub_note_connection_replaced()
		if !first do return
		reason := extract_json_string(text, "reason", "unknown")
		defer delete(reason)
		fmt.printfln("bridge hub runtime: connection replaced by a newer connection for this bridge id (reason=%s); another bridge process may be running with the same identity — backing off %ds", reason, backoff_s)
		blog_warn(.hub_connection_replaced, blog_sym(.reason, blog_replaced_reason(reason)), blog_int(.duration_ms, i64(backoff_s) * 1000))
		return
	}
	if type == "bridge_uninstall" {
		bridge_hub_handle_uninstall_command(conn, text)
		return
	}
	if type == "bridge_update" {
		bridge_hub_handle_update_command(conn, text)
		return
	}
	if type == "auto_update_config" {
		bridge_auto_update_handle_config(conn, text)
		return
	}
	if type == "provider_extension_install" {
		bridge_hub_handle_extension_install_command(conn, text)
		return
	}
	if type == "provider_profile_op" {
		bridge_hub_handle_provider_profile_op(conn, text)
		return
	}
	if type == "task_chain_search" {
		bridge_task_chain_search_handle_command(conn, text)
		return
	}
	if type == "mcp_transform" {bridge_mcp_transform(conn,text);return}
	if type == "set_telemetry" {
		command_id := extract_json_string(text, "command_id", "")
		defer delete(command_id)
		enabled_str := extract_json_string(text, "enabled", "")
		defer delete(enabled_str)
		enabled := enabled_str == "true" || bridge_local_extract_json_bool(text, "enabled", false)
		// Two switches ride this command. `enabled` is the local Telegraf
		// exporter (true only for telemetry_enabled=enabled). `heartbeat_stats`
		// governs the heartbeat resource stats AND bridge_log shipping and is
		// true unless the owner chose "disabled" — the same rule as
		// bridge_ready.heartbeat_stats, so "inherit" means stats ON / Telegraf
		// OFF at PATCH time exactly as it does at hello time. An old hub sends
		// only `enabled`; then it is the switch for both (legacy semantics).
		bridge_heartbeat_stats_set_enabled(extract_json_bool(text, "heartbeat_stats", enabled))
		if enabled {
			if !bridge_telemetry_status() {
				_ = bridge_telemetry_start()
			}
		} else {
			_ = bridge_telemetry_stop()
		}
		if command_id != "" && conn != nil {
			res := bridge_command_result_json(command_id, "succeeded", "telemetry_running" if bridge_telemetry_status() else "telemetry_stopped")
			defer delete(res)
			_ = bridge_hub_send(conn, res)
		}
		return
	}
	if type == "validate_project_path" {
		result := bridge_project_path_validation_result_json(text, use_cache = false)
		defer delete(result)
		_ = bridge_hub_send(conn, result)
		return
	}
	if type == "launch_agent" {
		fmt.println("bridge hub runtime command launch_agent")
		command_id := extract_json_string(text, "command_id", "")
		defer delete(command_id)
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = bridge_hub_send(conn, cached); return }
		accepted := bridge_command_result_json(command_id, "accepted", "")
		defer delete(accepted)
		bridge_runtime_cache_command(command_id, accepted)
		_ = bridge_hub_send(conn, accepted)
		ok, detail, launch_err := bridge_runtime_launch_agent(command_id, text, bridge_command_worker_deadline_ns(conn))
		instance_id := extract_json_string(text, "agent_instance_id", "")
		defer delete(instance_id)
		st_json := bridge_instance_status_json(instance_id)
		defer delete(st_json)
		_ = bridge_hub_send(conn, st_json)
		final := bridge_command_result_json(command_id, "succeeded", "starting") if ok else bridge_command_failed_json(command_id, bridge_error_wire(launch_err, detail), "failed")
		defer delete(final)
		if !ok do fmt.println("bridge launch_agent failed", detail, bridge_error_string(launch_err))
		bridge_runtime_cache_command(command_id, final)
		_ = bridge_hub_send(conn, final)
		return
	}
	if type == "launch_provider_test" {
		command_id := extract_json_string(text, "command_id", "")
		defer delete(command_id)
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = bridge_hub_send(conn, cached); return }
		accepted := bridge_command_result_json(command_id, "accepted", "")
		defer delete(accepted)
		bridge_runtime_cache_command(command_id, accepted)
		_ = bridge_hub_send(conn, accepted)
		ok, detail, test_err := bridge_runtime_launch_provider_test(command_id, text)
		instance_id := extract_json_string(text, "agent_instance_id", "")
		defer delete(instance_id)
		st_json := bridge_instance_status_json(instance_id)
		defer delete(st_json)
		_ = bridge_hub_send(conn, st_json)
		final := bridge_command_result_json(command_id, "succeeded", "starting") if ok else bridge_command_failed_json(command_id, bridge_error_wire(test_err, detail), "failed")
		defer delete(final)
		bridge_runtime_cache_command(command_id, final)
		_ = bridge_hub_send(conn, final)
		return
	}
	if type == "stop_agent" {
		fmt.println("bridge hub runtime command stop_agent")
		command_id := extract_json_string(text, "command_id", "")
		defer delete(command_id)
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = bridge_hub_send(conn, cached); return }
		accepted := bridge_command_result_json(command_id, "accepted", "")
		defer delete(accepted)
		bridge_runtime_cache_command(command_id, accepted)
		_ = bridge_hub_send(conn, accepted)
		instance_id := extract_json_string(text, "agent_instance_id", "")
		defer delete(instance_id)
		ok, restored := bridge_runtime_stop_or_restore(instance_id, extract_json_bool(text, "force", false))
		defer delete(restored)
		st_json := bridge_instance_status_json(instance_id)
		defer delete(st_json)
		_ = bridge_hub_send(conn, st_json)
		final := bridge_command_result_json(command_id, "succeeded", "stopped") if ok else bridge_command_failed_json(command_id, bridge_cause_wire_error("stop_failed", "the agent did not stop"), restored)
		defer delete(final)
		bridge_runtime_cache_command(command_id, final)
		_ = bridge_hub_send(conn, final)
		return
	}
	if type == "notify_agent_message" {
		command_id := extract_json_string(text, "command_id", "")
		defer delete(command_id)
		instance_id := extract_json_string(text, "agent_instance_id", "")
		defer delete(instance_id)
		// Deliver the notice directly to the agent via the daemon (host.input+Enter).
		sender_dn := extract_json_string(text, "sender_display_name", "")
		defer delete(sender_dn)
		sender_user := extract_json_string(text, "sender", "user")
		defer delete(sender_user)
		sender_id := extract_json_string(text, "sender_agent_instance_id", sender_user)
		defer delete(sender_id)
		sender := sender_dn if sender_dn != "" else sender_id
		ok := bridge_pty_host_deliver_to_agent(instance_id, "message", sender, "", "")
		if !ok do fmt.println("bridge notification pending/no-agent-subscription", instance_id, command_id)
		if command_id != "" {
			res := bridge_command_result_json(command_id, "succeeded" if ok else "accepted", "")
			defer delete(res)
			_ = bridge_hub_send(conn, res)
		}
		return
	}
	if type == "notify_task_nudge" {
		command_id := extract_json_string(text, "command_id", "")
		defer delete(command_id)
		instance_id := extract_json_string(text, "agent_instance_id", "")
		defer delete(instance_id)
		task_id := extract_json_string(text, "task_id", "")
		defer delete(task_id)
		fmt.println("bridge hub runtime command notify_task_nudge", instance_id, command_id)
		if bridge_should_debounce_nudge(instance_id, task_id) {
			if command_id != "" {
				res := bridge_command_result_json(command_id, "succeeded", "")
				defer delete(res)
				_ = bridge_hub_send(conn, res)
			}
			return
		}
		// Deliver the task-nudge notice straight to the agent via the daemon.
		// MEM-6: prefer the hub's human_message (verbatim) when present.
		target_role := extract_json_string(text, "target_role", "participant")
		defer delete(target_role)
		human_message := extract_json_string(text, "human_message", "")
		defer delete(human_message)
		task_title_fallback := extract_json_string(text, "task_title", "")
		defer delete(task_title_fallback)
		task_title := extract_json_string(text, "title", task_title_fallback)
		defer delete(task_title)
		origin := extract_json_string(text, "origin", "")
		defer delete(origin)
		interrupt := extract_json_bool(text, "interrupt", false) || origin == "pausing" || origin == "finishing"
		ok := bridge_pty_host_deliver_to_agent(instance_id, "task_nudge", "", task_id, target_role, human_message, task_title, interrupt)
		if !ok do fmt.println("bridge notify_task_nudge pending/no-agent-subscription", instance_id, command_id)
		if command_id != "" {
			res := bridge_command_result_json(command_id, "succeeded" if ok else "accepted", "")
			defer delete(res)
			_ = bridge_hub_send(conn, res)
		}
		return
	}
	if type == "notify_shell_run" {
		// REQ-SHELL-5 §1 — a BACKGROUND run of this agent's has finished or been killed.
		//
		// Delivered over the SAME gated path as notify_title_nudge: push the notice to a
		// live wrapper, else wake the local agent so it picks it up on boot. Never a new
		// notifier, and never a chat message — the run's one conversation entry was
		// written by the hub at creation.
		//
		// The notice leads with the SESSION ID because that is the handle the agent was
		// given when its run was backgrounded, and it is what `shell log` takes. No
		// output is carried or fetched here: output stays on this host and is read on
		// demand.
		command_id := extract_json_string(text, "command_id", "")
		defer delete(command_id)
		instance_id := extract_json_string(text, "agent_instance_id", "")
		defer delete(instance_id)
		session_id := extract_json_string(text, "session_id", "")
		defer delete(session_id)
		status := extract_json_string(text, "status", "exited")
		defer delete(status)
		exit_code := extract_json_string(text, "exit_code", "")
		defer delete(exit_code)
		notice := bridge_shell_run_notice(session_id, status, exit_code)
		defer delete(notice)
		fmt.println("bridge hub runtime command notify_shell_run", instance_id, session_id, status)
		if socket, sok := bridge_pty_host_ensure_daemon(); sok {
			ok := bridge_pty_host_deliver_notice(socket, instance_id, notice)
			if command_id != "" {
				res := bridge_command_result_json(command_id, "succeeded" if ok else "accepted", "")
				defer delete(res)
				_ = bridge_hub_send(conn, res)
			}
			return
		}
		ok := bridge_task_status_notify_wake_local(instance_id)
		if !ok do fmt.println("bridge notify_shell_run pending/no-daemon", instance_id, command_id)
		if command_id != "" {
			res := bridge_command_result_json(command_id, "succeeded" if ok else "accepted", "")
			defer delete(res)
			_ = bridge_hub_send(conn, res)
		}
		return
	}
	if type == "notify_title_nudge" {
		// Activity-gated title-nudge (REQ-4,5,6). Delivered over the SAME gated
		// path as notify_task_nudge: push to a live wrapper, else wake the local
		// agent so it picks up the nudge on boot. Never a new notifier.
		command_id := extract_json_string(text, "command_id", "")
		defer delete(command_id)
		instance_id := extract_json_string(text, "agent_instance_id", "")
		defer delete(instance_id)
		message := extract_json_string(text, "message", "Please set a short, human-meaningful title for this task chain: ham-ctl task-chain set-title \"<title>\"")
		defer delete(message)
		notice := strings.concatenate({"Nudge: ", message})
		defer delete(notice)
		if socket, sok := bridge_pty_host_ensure_daemon(); sok {
			ok := bridge_pty_host_deliver_notice(socket, instance_id, notice)
			if command_id != "" {
				res := bridge_command_result_json(command_id, "succeeded" if ok else "accepted", "")
				defer delete(res)
				_ = bridge_hub_send(conn, res)
			}
			return
		}
		// Daemon unavailable: wake the local agent so it picks up the nudge on boot.
		ok := bridge_task_status_notify_wake_local(instance_id)
		if !ok do fmt.println("bridge notify_title_nudge pending/no-daemon", instance_id, command_id)
		if command_id != "" {
			res := bridge_command_result_json(command_id, "succeeded" if ok else "accepted", "")
			defer delete(res)
			_ = bridge_hub_send(conn, res)
		}
		return
	}
	if type == "task_status_changed_notify" {
		command_id := extract_json_string(text, "command_id", "")
		defer delete(command_id)
		task_id := extract_json_string(text, "task_id", "")
		defer delete(task_id)
		new_status := extract_json_string(text, "new_status", "")
		defer delete(new_status)
		actor_agent_instance_id := extract_json_string(text, "actor_agent_instance_id", "")
		defer delete(actor_agent_instance_id)
		mutation_id := extract_json_string(text, "mutation_id", "")
		defer delete(mutation_id)
		// MEM-6: human_message (verbatim) preferred over the legacy generated notice.
		human_message := extract_json_string(text, "human_message", "")
		defer delete(human_message)

		assignees_arr, _ := bridge_provider_json_extract_array(text, "assignee_instance_ids")
		defer delete(assignees_arr)
		assignees := bridge_provider_json_parse_string_array(assignees_arr)
		defer {
			for s in assignees do delete(s)
			delete(assignees)
		}
		
		reviewers_arr, _ := bridge_provider_json_extract_array(text, "reviewer_instance_ids")
		defer delete(reviewers_arr)
		reviewers := bridge_provider_json_parse_string_array(reviewers_arr)
		defer {
			for s in reviewers do delete(s)
			delete(reviewers)
		}
		
		def_reviewers_arr, _ := bridge_provider_json_extract_array(text, "default_reviewer_instance_ids")
		defer delete(def_reviewers_arr)
		def_reviewers := bridge_provider_json_parse_string_array(def_reviewers_arr)
		defer {
			for s in def_reviewers do delete(s)
			delete(def_reviewers)
		}
		
		targets := make([dynamic]string)
		defer delete(targets)

		if new_status == "in_progress" {
			for inst in assignees {
				if inst != actor_agent_instance_id do append(&targets, inst)
			}
		} else if new_status == "in_validation" {
			if len(reviewers) == 0 {
				for inst in def_reviewers {
					if inst != actor_agent_instance_id do append(&targets, inst)
				}
			} else {
				for inst in reviewers {
					if inst != actor_agent_instance_id do append(&targets, inst)
				}
			}
		} else if new_status == "validated_not_good" {
			is_reviewer := false
			for inst in reviewers {
				if inst == actor_agent_instance_id { is_reviewer = true; break }
			}
			if !is_reviewer && len(reviewers) == 0 {
				for inst in def_reviewers {
					if inst == actor_agent_instance_id { is_reviewer = true; break }
				}
			}
			if is_reviewer {
				for inst in assignees do append(&targets, inst)
			}
		}

		delivered := 0
		failed := 0
		if len(targets) > 0 {
			for inst in targets {
				// Cross-bridge cascade: a status change on another bridge (e.g. an
				// upstream task completing) can promote a downstream task whose target
				// lives here. Deliver straight to the local agent via the daemon;
				// otherwise wake the local agent (coalesced) so it can pick up the work
				// on boot. Targets not local to this bridge are ignored.
				if bridge_pty_host_deliver_to_agent(inst, "task_nudge", "", task_id, "participant", human_message) {
					delivered += 1
					continue
				}
				if bridge_task_status_notify_wake_local(inst) {
					delivered += 1
					fmt.println("bridge task_status_changed_notify woke local target", inst, command_id)
				} else {
					failed += 1
					fmt.println("bridge task_status_changed_notify target not local or wake failed", inst, command_id)
				}
			}
		}
		_ = mutation_id
		
		if command_id != "" {
			res := ""
			if delivered > 0 || len(targets) == 0 {
				res = bridge_command_result_json(command_id, "succeeded", "")
			} else if failed > 0 {
				res = bridge_command_failed_json(command_id, bridge_cause_wire_error("wake_failed", "no target agent could be woken"))
			} else {
				res = bridge_command_result_json(command_id, "accepted", "")
			}
			defer delete(res)
			_ = bridge_hub_send(conn, res)
		}
		return
	}
	if type == "capture_agent_pane" {
		bridge_hub_handle_pane_capture_command(conn, text)
		return
	}
	if type == "get_agent_pane" {
		bridge_hub_handle_get_agent_pane(conn, text)
		return
	}
	if type == "wake_agent" {
		bridge_hub_handle_wake_agent(conn, text)
		return
	}
	if type == "get_shell_output" {
		bridge_hub_handle_get_shell_output(conn, text)
		return
	}
	if type == "agent_pty_input" {
		bridge_hub_handle_agent_pty_input(conn, text)
		return
	}
	if type == "agent_pty_resize" {
		bridge_hub_handle_agent_pty_resize(conn, text)
		return
	}
	if type == "shell_pty_input" {
		bridge_hub_handle_shell_pty_input(conn, text)
		return
	}
	if type == "shell_pty_resize" {
		bridge_hub_handle_shell_pty_resize(conn, text)
		return
	}
	if type == "shell_stream_attach" {
		bridge_hub_handle_shell_stream_attach(conn, text)
		return
	}
	if type == "shell_stream_detach" {
		bridge_hub_handle_shell_stream_detach(conn, text)
		return
	}
	if type == "tool_stream_batch" {
        bridge_tool_live_handle_batch(conn, text)
        return
    }
    if type == "tool_stream_attach" || type == "tool_stream_detach" {
		bridge_tool_live_handle_subscription(conn, text)
		return
	}
	if type == "shell_start" {
		bridge_hub_handle_shell_start(conn, text)
		return
	}
	if type == "shell_background" {
		bridge_hub_handle_shell_background(text)
		return
	}
	if type == "shell_kill" {
		bridge_hub_handle_shell_kill(text)
		command_id := extract_json_string(text, "command_id", "")
		defer delete(command_id)
		if command_id != "" {
			final := bridge_command_result_json(command_id, "succeeded", "kill_recorded")
			defer delete(final)
			bridge_runtime_cache_command(command_id, final)
			_ = bridge_hub_send(conn, final)
		}
		return
	}
	if type == "shell_signal" {
		bridge_hub_handle_shell_signal(text)
		return
	}
	if type == "shell_restart" {
		bridge_hub_handle_shell_restart(conn, text)
		return
	}
	if type == "shell_set_port" {
		bridge_hub_handle_shell_set_port(conn, text)
		return
	}
	if type == "shell_list" {
		bridge_hub_handle_shell_list(conn, text)
		return
	}
	if type == "shell_logs" {
		bridge_hub_handle_shell_logs(conn, text)
		return
	}
	if type == "shell_capture" {
		bridge_hub_handle_shell_capture(conn, text)
		return
	}
	if type == "shell_get_pane" {
		bridge_hub_handle_shell_get_pane(conn, text)
		return
	}
	if type == "tunnel_open" {
		bridge_hub_handle_tunnel_open(conn, text)
		return
	}
	if type == "tunnel_data" {
		bridge_hub_handle_tunnel_data(text)
		return
	}
	if type == "tunnel_close" {
		bridge_hub_handle_tunnel_close(text)
		return
	}
	// REQ-XM-4: hub→bridge frames for streams this bridge ORIGINATED (local_proxy.odin).
	// Distinct from tunnel_* above, which are streams the hub originated toward us.
	if type == "proxy_data" {
		bridge_hub_handle_proxy_data(text)
		return
	}
	if type == "proxy_close" {
		bridge_hub_handle_proxy_close(text)
		return
	}
	if type == "bridge_unseal" {
		command_id := bridge_vault_command_id(text)
		now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000
		ok: bool
		err_msg: string
		atomic_enroll := bridge_enroll_atomic_is_active()
		if atomic_enroll {
			// REQ-EA-4: ok:true commits the enrollment at the hub, so it is sent only
			// after the key AND the credential are persisted (enroll_atomic.odin).
			ok, err_msg = bridge_enroll_atomic_on_unseal(text, now_ms)
		} else {
			ok, err_msg = bridge_unseal_decrypt_and_verify(text, bridge_config.daemon_id, now_ms)
		}

		reply := Bridge_Vault_Command_Result{type = "bridge_unseal_result", command_id = command_id, ok = ok, status = "unlocked"}
		if !ok {
			reply.status = "error"
			reply.error = bridge_result_error("vault_unseal_failed", err_msg)
		}
		res, _ := vault.wire_encode(reply)
		defer delete(res)
		bridge_runtime_cache_command(command_id, res)
		if conn != nil {
			_ = bridge_hub_send(conn, res)
		}
		// Only a SUCCESSFUL unseal moved the vault; a failed one left it where it was,
		// and reporting there would be a no-op the hub would have to filter out.
		if ok do bridge_hub_send_vault_status(conn)
		if ok do bridge_task_chain_search_refresh_async()
		return
	}
	if type == "bridge_enrollment_result" {
		// REQ-EA-4: the hub's verdict on an atomic enrollment this process acked.
		bridge_enroll_atomic_on_result(text)
		return
	}
	if type == "permission_decision" {
		// REQ-EXT-PERM-1: a user's allow/deny for a pending agent.extension.permission.
		_ = bridge_ext_permission_handle_decision_frame(text)
		return
	}
	if bridge_session_projects_handle_command(conn, type, text) do return
	if bridge_fs_handle_command(conn, type, text) do return
	if bridge_vcs_handle_command(conn, type, text) do return
	if bridge_taskv2_handle_command(conn, type, text) do return
	if bridge_lsp_handle_command(conn, type, text) do return
}

bridge_update_progress_json :: proc(command_id, bridge_id, stage: string, progress_percent: int, message: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"bridge_update_progress\",\"command_id\":\"")
	bridge_runtime_write_json_string(&b, command_id)
	strings.write_string(&b, "\",\"bridge_id\":\"")
	bridge_runtime_write_json_string(&b, bridge_id)
	strings.write_string(&b, "\",\"stage\":\"")
	bridge_runtime_write_json_string(&b, stage)
	strings.write_string(&b, "\",\"progress_percent\":")
	strings.write_string(&b, fmt.tprintf("%d", progress_percent))
	strings.write_string(&b, ",\"message\":\"")
	bridge_runtime_write_json_string(&b, message)
	strings.write_string(&b, "\"")
	if stage == "failed" {
		strings.write_string(&b, ",\"error\":")
		contracts.write_wire_error(&b, bridge_error_wire(bridge_error(.update_apply_failed), message))
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

bridge_update_send_progress :: proc(conn: ^ws.Connection, command_id, stage: string, progress_percent: int, message: string) -> bool {
	frame := bridge_update_progress_json(command_id, bridge_config.daemon_id, stage, progress_percent, message)
	defer delete(frame)
	if conn == nil do return false
	return bridge_hub_send(conn, frame)
}

bridge_update_copy_file :: proc(src, dest: string) -> bool {
	src_file, open_err := os.open(src, os.File_Flags{.Read})
	if open_err != nil do return false
	defer os.close(src_file)
	out, create_err := os.open(dest, os.File_Flags{.Write, .Create, .Trunc}, os.Permissions{.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})
	if create_err != nil do return false
	defer os.close(out)
	buf: [65536]byte
	for {
		n, rerr := os.read(src_file, buf[:])
		if n > 0 {
			written, werr := os.write(out, buf[:n])
			if werr != nil || written != n do return false
		}
		if rerr != nil do return rerr == .EOF
		if n == 0 do return true
	}
}

// A stall guard plus a generous total: a large tarball on a slow but working
// link must not fail at a fixed 120 s.
BRIDGE_UPDATE_DOWNLOAD_TIMEOUT_MS :: httpc.LONG_TRANSFER_TIMEOUT_MS
BRIDGE_UPDATE_DOWNLOAD_STALL_TIMEOUT_MS :: 30_000
BRIDGE_UPDATE_DOWNLOAD_CONNECT_TIMEOUT_MS :: 15_000
BRIDGE_UPDATE_DOWNLOAD_ATTEMPTS :: 3
// GitHub release assets redirect to objects.githubusercontent.com.
BRIDGE_UPDATE_DOWNLOAD_MAX_REDIRECTS :: 5

// Bridge_Update_Download is the injectable transport (tests script it); the
// production value is httpc.download_to_file, which streams into a sibling .part
// file and renames it only after a complete 200.
Bridge_Update_Download :: #type proc(req: httpc.Request, dest_path: string) -> (status: int, err: httpc.Error)

// bridge_update_download fetches the update tarball through libcurl (src/lib/httpc):
// redirects followed (never https -> http), 15 s connect, 30 s without progress
// or 10 min total per attempt, up to 3 attempts on transient failures. download_url is either an
// absolute http(s) URL or a hub-relative target ("/api/v1/...") from the update
// command, resolved under the configured hub base URL without concatenation.
bridge_update_download :: proc(download_url, dest_path: string, download: Bridge_Update_Download = httpc.download_to_file) -> (bool, string) {
	if sync.atomic_load(&bridge_hub_traffic_stopped) do return false, "Hub traffic is paused"
	req := httpc.Request{
		method = .GET, timeout_ms = BRIDGE_UPDATE_DOWNLOAD_TIMEOUT_MS,
		connect_timeout_ms = BRIDGE_UPDATE_DOWNLOAD_CONNECT_TIMEOUT_MS,
		stall_timeout_ms = BRIDGE_UPDATE_DOWNLOAD_STALL_TIMEOUT_MS,
		max_redirects = BRIDGE_UPDATE_DOWNLOAD_MAX_REDIRECTS,
	}
	if strings.has_prefix(download_url, "/") {
		req.url = bridge_hub_url()
		req.relay_target = download_url
	} else {
		u, url_err := httpc.parse_url(download_url)
		if url_err != .None do return false, "tarball download failed: the download URL is not a valid http(s) URL"
		req.url = u
	}
	status := 0
	err := httpc.Error.None
	for attempt in 1..=BRIDGE_UPDATE_DOWNLOAD_ATTEMPTS {
		status, err = download(req, dest_path)
		if err == .None && status == 200 do return true, ""
		transient := status >= 500 || status == 429
		#partial switch err {
		case .Dns, .Connect, .Timeout, .Send, .Recv, .Protocol, .Tls: transient = true
		}
		if !transient || attempt == BRIDGE_UPDATE_DOWNLOAD_ATTEMPTS do break
		time.sleep(time.Duration(attempt) * time.Second)
	}
	if err == .Timeout do return false, fmt.tprintf("tarball download failed: timed out (no progress for %d seconds, or over %d seconds in total)", BRIDGE_UPDATE_DOWNLOAD_STALL_TIMEOUT_MS / 1000, BRIDGE_UPDATE_DOWNLOAD_TIMEOUT_MS / 1000)
	if err != .None do return false, fmt.tprintf("tarball download failed: %s", httpc.error_string(err))
	return false, fmt.tprintf("tarball download failed: HTTP %d", status)
}

// bridge_update_via_ham_bridge decides whether this bridge can apply a hub update:
// every update runs the staged binary's `ham-bridge update` (setup's transaction:
// bin.bak, service re-render, extensions, health incl. the hub connection,
// rollback). That needs a bridgesvc profile install running from that profile's
// bin/, and a target that is not older than this version (older binaries have no
// `update` subcommand). Anything else is refused before anything is downloaded or
// stopped, with the one-time reinstall that fixes it (temp-allocated refusal).
bridge_update_via_ham_bridge :: proc(target_version: string) -> (service: string, refusal: string) {
	host := bridge_service_host()
	name, registered := bridge_enroll_service_for(host, os.args)
	exe, _ := os.get_executable_path(context.temp_allocator)
	norm :: proc(p: string) -> string {
		out, _ := strings.replace_all(strings.trim_right(p, "/\\"), "\\", "/", context.temp_allocator)
		return out
	}
	if !registered || !strings.has_prefix(name, bridgesvc.SERVICE_PREFIX) || exe == "" || norm(bridgesvc.pdir(exe)) != norm(bridgesvc.layout_for(host, name).bin_dir) {
		return "", fmt.tprintf("this bridge is not a ham-bridge profile install, so it cannot apply updates; reinstall it once with %s", BRIDGE_REINSTALL_HINT)
	}
	if bridge_provider_extension_version_compare(target_version, contracts.APP_VERSION) < 0 {
		return "", fmt.tprintf("cannot update from %s to the older %s from the hub; install that version with the installer's --version flag (%s)", contracts.APP_VERSION, target_version, BRIDGE_REINSTALL_HINT)
	}
	return name, ""
}

// BRIDGE_REINSTALL_HINT names the headless installers (scripts/install.sh, .ps1).
// The host is its own literal: scripts/check-http-boundary.sh reads a single
// literal holding "curl" and ".a…" as a static libcurl path.
BRIDGE_INSTALLER_HOST :: "install.ninjy.ai"
BRIDGE_REINSTALL_HINT :: "'irm " + BRIDGE_INSTALLER_HOST + "/ps1 | iex'" when ODIN_OS == .Windows else "'curl -fsSL " + BRIDGE_INSTALLER_HOST + " | bash'"

// bridge_hub_handle_uninstall_command: the owning account asked (hub
// POST /api/v1/bridges/{id}/uninstall, owner-checked and audit-logged there) for
// this bridge to uninstall itself. The detached `ham-bridge uninstall` revokes the
// bridge with its own token, stops and unregisters this service and wipes every
// secret; it runs from a copy outside bin/ in a session of its own, so the service
// stop it performs does not take it down. Acknowledged before it starts.
bridge_hub_handle_uninstall_command :: proc(conn: ^ws.Connection, text: string) {
	command_id := extract_json_string(text, "command_id", "")
	defer delete(command_id)
	if cached, ok := bridge_runtime_cached_command(command_id); ok {
		if conn != nil do _ = bridge_hub_send(conn, cached)
		return
	}
	mode := extract_json_string(text, "mode", "purge")
	defer delete(mode)
	fmt.println("bridge hub runtime command bridge_uninstall mode", mode)
	name, registered := bridge_enroll_service_for(bridge_service_host(), os.args)
	ok, detail := false, "this bridge does not run as a registered service; uninstall it on the machine: ham-bridge uninstall"
	// A legacy service name (heimdall-bridge, ham-bridge, ...) would be refused by the
	// detached uninstall's resolver after the hub was already told "accepted".
	if registered && !bridge_service_name_safe(name) {
		registered = false
		detail = fmt.tprintf("this bridge is a legacy install (%s); reinstall it once with %s, or uninstall it on the machine", name, BRIDGE_REINSTALL_HINT)
	}
	if registered do ok, detail = bridge_uninstall_spawn_detached(name, mode != "keep_data")
	result: string
	if ok {
		result = bridge_command_result_json(command_id, "accepted", "")
	} else {
		fmt.println("bridge uninstall failed:", detail)
		result = bridge_command_failed_json(command_id, bridge_cause_wire_error("uninstall_failed", detail))
	}
	defer delete(result)
	if command_id != "" do bridge_runtime_cache_command(command_id, result)
	if conn != nil && command_id != "" do _ = bridge_hub_send(conn, result)
}

bridge_hub_handle_update_command :: proc(conn: ^ws.Connection, text: string) {
	fmt.println("bridge hub runtime command bridge_update")
	command_id := extract_json_string(text, "command_id", "")
	if cached, ok := bridge_runtime_cached_command(command_id); ok {
		if conn != nil do _ = bridge_hub_send(conn, cached)
		return
	}
	if command_id != "" {
		accepted := bridge_command_result_json(command_id, "accepted", "")
		defer delete(accepted)
		bridge_runtime_cache_command(command_id, accepted)
		if conn != nil do _ = bridge_hub_send(conn, accepted)
	}

	target_version := extract_json_string(text, "target_version", "")
	download_url := extract_json_string(text, "download_url", "")
	sha256 := extract_json_string(text, "sha256", "")
	force := bridge_local_extract_json_bool(text, "force", false)
	drain_timeout := extract_json_int(text, "drain_timeout_seconds", 60)

	ok, detail := bridge_runtime_apply_update(conn, command_id, target_version, download_url, sha256, force, drain_timeout)
	if !ok {
		fmt.println("bridge update failed:", detail)
		fail_progress := bridge_update_progress_json(command_id, bridge_config.daemon_id, "failed", 0, detail)
		defer delete(fail_progress)
		if conn != nil do _ = bridge_hub_send(conn, fail_progress)

		if command_id != "" {
			final := bridge_command_failed_json(command_id, bridge_error_wire(bridge_error(.update_apply_failed), detail))
			defer delete(final)
			bridge_runtime_cache_command(command_id, final)
			if conn != nil do _ = bridge_hub_send(conn, final)
		}
		return
	}

	if command_id != "" {
		final := bridge_command_result_json(command_id, "succeeded", "restarting")
		defer delete(final)
		bridge_runtime_cache_command(command_id, final)
		if conn != nil do _ = bridge_hub_send(conn, final)
	}
}

// bridge_update_target_refusal returns why this bridge must not apply the
// bundle at download_url, or "" when it may (temp-allocated).
bridge_update_target_refusal :: proc(download_url: string) -> string {
	target, blocked := bridge_release_target()
	return bridge_update_target_refusal_for(target, blocked, download_url)
}

bridge_update_target_refusal_for :: proc(target: string, update_blocked: bool, download_url: string) -> string {
	if update_blocked {
		return fmt.tprintf("self-update refused: this bridge runs under Termux but is not the %s build; reinstall with install.sh to get the %s bundle", target, target)
	}
	if contracts.release_asset_names_other_target(download_url, target) {
		return fmt.tprintf("self-update refused: the offered bundle is not built for this bridge's target %s", target)
	}
	return ""
}

// bridge_update_stop_pty_host stops the PTY host daemon answering on socket, and
// with it every agent it hosts, before the update swaps ham-pty-host: the daemon
// outlives bridge restarts by design (KillMode=process, AbandonProcessGroup), so
// the service restart would leave the old binary running (and, on Windows, its
// executable locked). The daemon is found through the socket's peer pid, so one
// an earlier bridge process started is stopped too, and only a process whose
// image is ham-pty-host is ever signalled. SIGTERM lets it tear its agents down;
// SIGKILL follows after PTY_HOST_DAEMON_TERM_GRACE. ok=false (temp-allocated
// detail) aborts the update before anything is swapped.
bridge_update_stop_pty_host :: proc(socket: string) -> (ok: bool, detail: string) {
	if !bridge_pty_host_ping(socket) do return true, ""
	s, dialed := pty_host_dial(socket)
	if !dialed do return true, "" // stopped between the ping and the dial
	pid, has_pid := local_socket.peer_pid(s)
	local_socket.close(s)
	if !has_pid {
		return false, fmt.tprintf("failed to stop bridge-owned PTY host: cannot identify the process serving %s; update aborted before restart", socket)
	}
	if !bridge_update_pid_is_pty_host(pid) {
		return false, fmt.tprintf("failed to stop bridge-owned PTY host: pid %d serving %s is not ham-pty-host; update aborted before restart", pid, socket)
	}
	gone :: proc(pid: int, within: time.Duration) -> bool {
		deadline := time.time_add(time.now(), within)
		for bridge_os_pid_alive(pid) {
			if time.diff(time.now(), deadline) <= 0 do return false
			time.sleep(50 * time.Millisecond)
		}
		return true
	}
	_ = bridge_os_terminate(pid)
	if !gone(pid, PTY_HOST_DAEMON_TERM_GRACE) {
		_ = bridge_os_kill(pid)
		if !gone(pid, PTY_HOST_DAEMON_KILL_GRACE) {
			return false, fmt.tprintf("failed to stop bridge-owned PTY host (pid %d survived SIGKILL); update aborted before restart", pid)
		}
	}
	// Reap it if this process started it, and make the next use start a new one.
	sync.mutex_lock(&pty_host_daemon_lock)
	_ = bridge_pty_host_daemon_process_running(&pty_host_daemon_process, &pty_host_daemon_has_process)
	pty_host_daemon_started = false
	sync.mutex_unlock(&pty_host_daemon_lock)
	return true, ""
}

// bridge_update_pid_is_pty_host: pid's command names ham-pty-host. When the OS
// cannot report the command at all, the socket's own peer is trusted.
bridge_update_pid_is_pty_host :: proc(pid: int) -> bool {
	_, command, ok := bridge_os_process_lstart_and_command(pid)
	if !ok do return true
	return strings.contains(command, "ham-pty-host")
}

bridge_runtime_apply_update :: proc(
	conn: ^ws.Connection,
	command_id, target_version, download_url, sha256: string,
	force: bool,
	drain_timeout_seconds: int,
) -> (bool, string) {
	if strings.trim_space(download_url) == "" {
		return false, "missing download_url"
	}
	// `ham-bridge update` is chosen by the version being installed; the Hub always
	// resolves one, so an empty value is refused before any download.
	if strings.trim_space(target_version) == "" {
		return false, "missing target_version"
	}
	service, refusal := bridge_update_via_ham_bridge(target_version)
	if refusal != "" do return false, refusal
	// REQ-T13-1: refuse before draining or downloading anything. Installing a
	// bundle for another target would leave the bridge unable to start (the
	// glibc linux-* bundle dies on Android's seccomp filter) with no way back.
	if refusal := bridge_update_target_refusal(download_url); refusal != "" {
		return false, refusal
	}

	// 1. Drain active tasks if not forced
	if !force && drain_timeout_seconds > 0 {
		_ = bridge_update_send_progress(conn, command_id, "draining", 5, "Waiting for active agent tasks to finish...")
		deadline := time.to_unix_nanoseconds(time.now()) + i64(drain_timeout_seconds) * 1_000_000_000
		for time.to_unix_nanoseconds(time.now()) < deadline {
			sync.mutex_lock(&bridge_runtime_mutex)
			count := len(bridge_runtime_launches)
			sync.mutex_unlock(&bridge_runtime_mutex)
			if count == 0 do break
			time.sleep(1000 * time.Millisecond)
		}
	}
	_ = bridge_update_send_progress(conn, command_id, "preparing", 10, "Preparing update staging directory...")

	// 2. Resolve data and staging directories
	data_dir := bridge_expand_home(bridge_config.data_dir)
	if strings.trim_space(data_dir) == "" {
		data_dir = bridge_os_default_data_dir()
	}
	updates_dir := fmt.tprintf("%s/updates", data_dir)
	stage_dir := fmt.tprintf("%s/updates/stage", data_dir)
	_ = os.remove_all(stage_dir)
	if bridge_make_directory_all(stage_dir) != nil {
		blog_error(.update_apply_failed, blog_sym(.stage, .staging))
		return false, fmt.tprintf("cannot create staging directory %s", stage_dir)
	}

	// 3. Download the release artifact. Each milestone is persisted by the Hub
	// before the next destructive phase begins, so the UI can show live progress.
	_ = bridge_update_send_progress(conn, command_id, "downloading", 20, "Downloading update tarball...")

	tarball_path := fmt.tprintf("%s/bundle.tar.gz", stage_dir)

	// Stream tarball from download_url (absolute, or hub-relative: see bridge_update_download).

	if strings.has_prefix(download_url, "file://") || (os.exists(download_url) && !strings.has_prefix(download_url, "http://") && !strings.has_prefix(download_url, "https://")) {
		local_src := download_url
		if strings.has_prefix(local_src, "file://") {
			local_src = local_src[7:]
		}
		if !bridge_update_copy_file(local_src, tarball_path) {
			_ = os.remove_all(stage_dir)
			blog_error(.update_download_failed, blog_sym(.stage, .download), blog_sym(.reason, .transport))
			return false, fmt.tprintf("failed to copy local bundle from %s", local_src)
		}
	} else {
		dl_ok, dl_error := bridge_update_download(download_url, tarball_path)
		if !dl_ok {
			_ = os.remove_all(stage_dir)
			blog_error(.update_download_failed, blog_sym(.stage, .download))
			return false, dl_error
		}
	}
	_ = bridge_update_send_progress(conn, command_id, "downloaded", 40, "Update tarball downloaded.")

	// 4. Verify SHA-256 hash before extraction
	_ = bridge_update_send_progress(conn, command_id, "verifying", 45, "Verifying update tarball checksum...")
	tarball_bytes, rerr := os.read_entire_file(tarball_path, context.allocator)
	if rerr != nil {
		_ = os.remove_all(stage_dir)
		blog_error(.update_download_failed, blog_sym(.stage, .verify))
		return false, "failed to read downloaded tarball"
	}
	defer delete(tarball_bytes)

	digest: [32]byte
	hash.hash_bytes_to_buffer(.SHA256, tarball_bytes, digest[:])
	hex_bytes := hex.encode(digest[:])
	defer delete(hex_bytes)
	actual_sha256 := strings.to_lower(string(hex_bytes), context.allocator)
	defer delete(actual_sha256)

	if strings.trim_space(sha256) != "" {
		expected_sha256 := strings.trim_space(sha256)
		if strings.has_prefix(expected_sha256, "sha256:") {
			expected_sha256 = expected_sha256[7:]
		}
		if !strings.equal_fold(expected_sha256, actual_sha256) {
			_ = os.remove_all(stage_dir)
			blog_error(.update_apply_failed, blog_sym(.stage, .verify))
			return false, fmt.tprintf("SHA-256 mismatch for bundle (expected %s, got %s)", expected_sha256, actual_sha256)
		}
	}
	_ = bridge_update_send_progress(conn, command_id, "verified", 55, "Update tarball checksum verified.")

	// 5. Extract tarball.
	_ = bridge_update_send_progress(conn, command_id, "extracting", 60, "Extracting update tarball...")
	tar_argv := []string{"tar", "-xzf", tarball_path, "-C", stage_dir}
	tar_out, tar_err, tar_ok, _ := bridge_process_run_capture(tar_argv, 30 * time.Second)
	defer { delete(tar_out); delete(tar_err) }
	if !tar_ok {
		_ = os.remove_all(stage_dir)
		blog_error(.update_apply_failed, blog_sym(.stage, .extract))
		return false, "tarball extraction failed"
	}

	// 6. In-situ preflight check: locate ham-bridge and run `./stage/bin/ham-bridge --version`
	_ = bridge_update_send_progress(conn, command_id, "preflight", 70, "Validating staged bridge binaries...")
	stage_bin_dir := fmt.tprintf("%s/bin", stage_dir)
	bridge_binary := fmt.tprintf("%s/ham-bridge%s", stage_bin_dir, BRIDGE_EXE_SUFFIX)
	if !os.exists(bridge_binary) {
		candidates := []string{
			fmt.tprintf("%s/extract/bin/ham-bridge%s", stage_dir, BRIDGE_EXE_SUFFIX),
			fmt.tprintf("%s/heimdall-cloudtop/bin/ham-bridge%s", stage_dir, BRIDGE_EXE_SUFFIX),
			fmt.tprintf("%s/ham-bridge%s", stage_dir, BRIDGE_EXE_SUFFIX),
		}
		found := false
		for c in candidates {
			if os.exists(c) {
				_ = bridge_make_directory_all(stage_bin_dir)
				if bridge_update_copy_file(c, bridge_binary) {
					found = true
					break
				}
			}
		}
		if !found {
			_ = os.remove_all(stage_dir)
			blog_error(.update_apply_failed, blog_sym(.stage, .preflight), blog_sym(.reason, .missing_binary))
			return false, "ham-bridge executable not found in staged bundle"
		}
	}

	_ = os.chmod(bridge_binary, os.Permissions{.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})
	pf_argv := []string{bridge_binary, "--version"}
	pf_out, pf_err, pf_ok, _ := bridge_process_run_capture(pf_argv, 5 * time.Second)
	defer { delete(pf_out); delete(pf_err) }
	if !pf_ok {
		_ = os.remove_all(stage_dir)
		blog_error(.update_apply_failed, blog_sym(.stage, .preflight), blog_sym(.reason, .not_executable))
		return false, fmt.tprintf("preflight execution check failed (%s --version)", bridge_binary)
	}

	_ = bridge_update_send_progress(conn, command_id, "staged", 78, "Update bundle staged and validated.")

	// 7. Stop the PTY host (and the agents it hosts) while this control connection
	// can still report both the attempt and its result.
	_ = bridge_update_send_progress(conn, command_id, "stopping_pty_host", 82, "Stopping bridge-owned PTY host and agent processes...")
	pty_socket := pty_host_socket_path()
	defer delete(pty_socket)
	if stop_ok, stop_detail := bridge_update_stop_pty_host(pty_socket); !stop_ok {
		_ = os.remove_all(stage_dir)
		blog_error(.update_apply_failed, blog_sym(.stage, .drain))
		return false, stop_detail
	}
	_ = bridge_update_send_progress(conn, command_id, "pty_host_stopped", 88, "Bridge-owned PTY host and agent processes stopped.")

	// 8. Hand off to the STAGED binary's transactional `ham-bridge update`. This
	// process is NOT exited here: setup restarts the service itself, and must see it
	// running to restart the old bridge on rollback. `update --detach` is waited
	// for: it preflights (hub recorded, bundle binary runs) and only then starts
	// setup in a session of its own (stdio on the null device, so this capture does
	// not wait for setup). An early failure is reported to the hub; the PTY host
	// restarts on the next agent launch.
	argv := []string{bridge_binary, "update", "--bundle", bridgesvc.pdir(bridge_binary), "--service", service, "--detach"}
	_ = bridge_update_send_progress(conn, command_id, "restarting", 95, "PTY host stopped. Handing off to ham-bridge update...")
	h_out, h_err, h_exit, h_ok, h_timed_out := bridge_process_run_capture_status(argv, 30 * time.Second)
	defer {delete(h_out); delete(h_err)}
	if h_ok && h_exit == 0 do return true, "restarting"
	_ = os.remove_all(stage_dir)
	blog_error(.update_apply_failed, blog_sym(.stage, .preflight))
	// The install is unchanged, but the PTY host and its agents were stopped above.
	STOPPED :: "the install was not changed, but the PTY host and its agents were stopped (they restart on the next agent launch)"
	if h_timed_out do return false, "ham-bridge update did not start within 30 seconds; " + STOPPED
	return false, fmt.tprintf("ham-bridge update did not start (exit %d): %s; %s", h_exit, strings.trim_space(h_err), STOPPED)
}

bridge_hub_handle_agent_pty_input :: proc(conn: ^ws.Connection, text: string) {
	temp := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp)
	cmd := bridge_pty_command_decode(text)
	command_id := cmd.command_id
	if cached, ok := bridge_runtime_cached_command(command_id); ok {
		if conn != nil do _ = bridge_hub_send(conn, cached)
		return
	}
	instance_id := cmd.agent_instance_id

	// This legacy type carries PLAINTEXT `data` only and has no encrypted form; the hub
	// sends agent-pane keystrokes as encrypted `shell_pty_input`. There is no plaintext
	// vault mode, so it is always refused: vault_locked when no key is held, otherwise
	// invalid_vault_key.
	if bridge_vault_status() != .Unlocked {
		fmt.println("bridge agent_pty_input rejected: vault_locked for instance", instance_id)
		blog_warn(.vault_locked, blog_sym(.command_kind, .agent_pty_input))
		bridge_pty_input_reply_vault_locked(conn, command_id, instance_id)
		return
	}
	fmt.println("bridge agent_pty_input rejected: plaintext input is refused (use encrypted shell_pty_input) for instance", instance_id)
	if command_id != "" {
		result := bridge_command_failed_json(command_id, bridge_cause_wire_error("invalid_vault_key", "plaintext input is refused"))
		defer delete(result)
		bridge_runtime_cache_command(command_id, result)
		if conn != nil do _ = bridge_hub_send(conn, result)
	}
}

bridge_hub_handle_agent_pty_resize :: proc(conn: ^ws.Connection, text: string) {
	cmd := bridge_pty_command_decode(text)
	command_id := cmd.command_id
	if cached, ok := bridge_runtime_cached_command(command_id); ok {
		if conn != nil do _ = bridge_hub_send(conn, cached)
		return
	}
	instance_id := cmd.agent_instance_id
	rows := bridge_pty_dimension(cmd.rows)
	cols := bridge_pty_dimension(cmd.cols)

	ok := bridge_pty_host_deliver_resize(instance_id, rows, cols)
	if !ok do fmt.println("bridge agent_pty_resize delivery failed for instance", instance_id)

	if command_id != "" {
		result := bridge_command_result_json(command_id, "succeeded", "") if ok else bridge_command_failed_json(command_id, bridge_cause_wire_error("delivery_failed", "the pane did not accept the input"))
		defer delete(result)
		bridge_runtime_cache_command(command_id, result)
		if conn != nil do _ = bridge_hub_send(conn, result)
	}
}

// bridge_hub_handle_binary_frame routes one hub->bridge BINARY frame (REQ-PTY-NET-3).
// kind=INPUT: the same tri-state vault gate as the JSON shell_pty_input below — Locked
// drops the keystrokes and answers with the typed shell_pty_vault_locked stream frame,
// Unlocked accepts only ciphertext, Disabled accepts only plaintext — then delivers to the
// pty-host. No command_result is produced: the frame carries no command_id by design.
bridge_hub_handle_binary_frame :: proc(conn: ^ws.Connection, frame: []byte) {
	temp := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp)
	kind, flags, shell_id, payload, ok := contracts.pty_wire_decode_session_frame(frame)
	if !ok {
		fmt.println("bridge binary frame rejected: not a pty_wire session frame, bytes", len(frame))
		return
	}
	if kind != contracts.PTY_WIRE_KIND_INPUT {
		fmt.println("bridge binary frame ignored: unexpected kind", kind, "for shell", shell_id)
		return
	}
	encrypted := contracts.pty_wire_is_encrypted(flags)
	vault_status, kr := bridge_vault_status_and_key()
	defer vault.keyring_wipe(&kr)
	data := ""
	decoded_ok := false
	reject_reason := "invalid payload or vault encryption mode"
	if vault_status != .Unlocked {
		reject_reason = "vault_locked"
	} else if encrypted {
		// Command epoch floor: input sealed under any epoch but the current one is
		// refused, even when this keyring still holds that older key. A replayed
		// (non-increasing) input counter is refused too (finding M1).
		if plain, pok := bridge_pty_open_input(payload, &kr, shell_id, bridge_unseal_boot_id()); pok { data = plain; decoded_ok = true }
	}
	if !decoded_ok {
		fmt.println("bridge pty input rejected:", reject_reason, "for shell", shell_id)
		if vault_status != .Unlocked {
			blog_warn(.vault_locked, blog_sym(.command_kind, .agent_pty_input))
			bridge_pty_input_reply_vault_locked(conn, "", shell_id)
		}
		return
	}
	if !bridge_pty_host_deliver_shell_input(shell_id, data) {
		// Ack-less (no command_result to carry a typed error), so report it the typed
		// way the bridge reports any failure: a bridge_log event the hub relays and
		// counts (REQ-ERR-PROTO-A), rate-limited and dedup'd by the blog ring.
		fmt.println("bridge pty input delivery failed for shell", shell_id)
		blog_warn(.pty_host_unreachable, blog_sym(.command_kind, .agent_pty_input))
	}
}

bridge_hub_handle_shell_pty_input :: proc(conn: ^ws.Connection, text: string) {
	temp := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp)
	cmd := bridge_pty_command_decode(text)
	command_id := cmd.command_id
	if cached, ok := bridge_runtime_cached_command(command_id); ok {
		if conn != nil do _ = bridge_hub_send(conn, cached)
		return
	}
	shell_id := cmd.shell_id if cmd.shell_id != "" else cmd.agent_instance_id
	data_b64 := cmd.data_b64
	encrypted, flag_ok := cmd.is_encrypted.?
	// T9 (REQ-T9-1): same tri-state gate as shell_start. Keystrokes are execution
	// too, so a Locked bridge drops them whatever the payload claims to be.
	vault_status, kr := bridge_vault_status_and_key()
	defer vault.keyring_wipe(&kr)
	data := ""
	decoded_ok := false
	reject_reason := "invalid payload or vault encryption mode"
	if vault_status != .Unlocked {
		reject_reason = "vault_locked"
	} else if flag_ok && encrypted {
		// data_b64 is base64 of a PTY v2 "in" frame; current epoch only, and its
		// input counter must increase (replay defence, finding M1).
		if frame, frame_ok := vault.b64_decode_strict(data_b64, context.temp_allocator); frame_ok {
			if plain, pok := bridge_pty_open_input(frame, &kr, shell_id, bridge_unseal_boot_id()); pok { data = plain; decoded_ok = true }
		}
	}
	if !decoded_ok {
		fmt.println("bridge shell_pty_input rejected:", reject_reason, "for shell", shell_id)
		if vault_status != .Unlocked {
			// T10: typed refusal so the hub/UI can show "locked" rather than a crash.
			bridge_pty_input_reply_vault_locked(conn, command_id, shell_id)
			return
		}
		if command_id != "" {
			result := bridge_command_failed_json(command_id, bridge_cause_wire_error("invalid_payload", reject_reason))
			defer delete(result)
			bridge_runtime_cache_command(command_id, result)
			if conn != nil do _ = bridge_hub_send(conn, result)
		}
		return
	}

	ok := bridge_pty_host_deliver_shell_input(shell_id, data)
	if !ok do fmt.println("bridge shell_pty_input delivery failed for shell", shell_id)

	if command_id != "" {
		result := bridge_command_result_json(command_id, "succeeded", "") if ok else bridge_command_failed_json(command_id, bridge_cause_wire_error("delivery_failed", "the pane did not accept the input"))
		defer delete(result)
		bridge_runtime_cache_command(command_id, result)
		if conn != nil do _ = bridge_hub_send(conn, result)
	}
}

bridge_hub_handle_shell_pty_resize :: proc(conn: ^ws.Connection, text: string) {
	cmd := bridge_pty_command_decode(text)
	command_id := cmd.command_id
	if cached, ok := bridge_runtime_cached_command(command_id); ok {
		if conn != nil do _ = bridge_hub_send(conn, cached)
		return
	}
	shell_id := cmd.shell_id if cmd.shell_id != "" else cmd.agent_instance_id
	rows := bridge_pty_dimension(cmd.rows)
	cols := bridge_pty_dimension(cmd.cols)

	ok := bridge_pty_host_deliver_shell_resize(shell_id, rows, cols)
	if !ok do fmt.println("bridge shell_pty_resize delivery failed for shell", shell_id)

	if command_id != "" {
		result := bridge_command_result_json(command_id, "succeeded", "") if ok else bridge_command_failed_json(command_id, bridge_cause_wire_error("delivery_failed", "the pane did not accept the input"))
		defer delete(result)
		bridge_runtime_cache_command(command_id, result)
		if conn != nil do _ = bridge_hub_send(conn, result)
	}
}

bridge_hub_handle_shell_stream_attach :: proc(conn: ^ws.Connection, text: string) {
	cmd := bridge_pty_command_decode(text)
	command_id := cmd.command_id
	if cached, ok := bridge_runtime_cached_command(command_id); ok {
		if conn != nil do _ = bridge_hub_send(conn, cached)
		return
	}
	session_id := cmd.session_id
	if session_id == "" do session_id = cmd.shell_id
	if session_id == "" do session_id = cmd.agent_instance_id

	send_result :: proc(conn: ^ws.Connection, command_id: string, ok: bool, cause: string = "", err_msg: string = "") {
		if command_id == "" do return
		result := bridge_command_result_json(command_id, "succeeded", "") if ok else bridge_command_failed_json(command_id, bridge_cause_wire_error(cause if cause != "" else "stream_detach_failed", err_msg))
		defer delete(result)
		bridge_runtime_cache_command(command_id, result)
		if conn != nil do _ = bridge_hub_send(conn, result)
	}

	if session_id == "" {
		send_result(conn, command_id, false, "missing_session_id", "missing session_id")
		return
	}

	// An OWNED clone of the daemon key; an unknown session streams under its own id,
	// which is what the fallback inside the accessor resolves to anyway. The delete is
	// deferred to THIS scope, not to an `if` body — a defer inside the `if` would fire
	// before the id is used.
	key, have_key := bridge_shell_session_shell_id(&bridge_shell_session_map, session_id)
	defer if have_key do bridge_shell_session_str_delete(&bridge_shell_session_map, key)
	shell_id := key if have_key else session_id

	ok := bridge_pty_stream_worker_start(session_id, shell_id, conn)
	if !ok {
		send_result(conn, command_id, false, "stream_start_failed", "failed to start streaming worker")
		return
	}
	send_result(conn, command_id, true)
}

bridge_hub_handle_shell_stream_detach :: proc(conn: ^ws.Connection, text: string) {
	cmd := bridge_pty_command_decode(text)
	command_id := cmd.command_id
	if cached, ok := bridge_runtime_cached_command(command_id); ok {
		if conn != nil do _ = bridge_hub_send(conn, cached)
		return
	}
	session_id := cmd.session_id
	if session_id == "" do session_id = cmd.shell_id
	if session_id == "" do session_id = cmd.agent_instance_id

	send_result :: proc(conn: ^ws.Connection, command_id: string, ok: bool, cause: string = "", err_msg: string = "") {
		if command_id == "" do return
		result := bridge_command_result_json(command_id, "succeeded", "") if ok else bridge_command_failed_json(command_id, bridge_cause_wire_error(cause if cause != "" else "stream_detach_failed", err_msg))
		defer delete(result)
		bridge_runtime_cache_command(command_id, result)
		if conn != nil do _ = bridge_hub_send(conn, result)
	}

	if session_id == "" {
		send_result(conn, command_id, false, "missing_session_id", "missing session_id")
		return
	}

	ok := bridge_pty_stream_worker_detach(session_id)
	send_result(conn, command_id, ok)
}

bridge_hub_handle_get_agent_pane :: proc(conn: ^ws.Connection, text: string) {
	cmd := bridge_pty_command_decode(text)
	command_id := cmd.command_id
	if cached, ok := bridge_runtime_cached_command(command_id); ok {
		_ = bridge_hub_send(conn, cached)
		return
	}
	instance_id := cmd.agent_instance_id
	since_hash := cmd.since_hash
	width := bridge_json_positive_int(cmd.width, 80)
	line_limit := bridge_json_positive_int(cmd.line_limit, 120)

	ok, unchanged, h, output, line_count, truncated, cursor_row, cursor_col, err_msg := bridge_pty_host_get_pane(instance_id, since_hash, line_limit, width)
	defer if h != "" do delete(h)
	defer if output != "" do delete(output)

	result := bridge_get_pane_reply_json(command_id, instance_id, ok, unchanged, h, output, line_count, truncated, cursor_row, cursor_col, err_msg)
	defer delete(result)
	bridge_runtime_cache_command(command_id, result)
	_ = bridge_hub_send(conn, result)
}

// Bridge_Pane_Capture_Command is the capture_agent_pane command (top-level members).
Bridge_Pane_Capture_Command :: struct {
	command_id:              string,
	protocol_version:        int,
	agent_instance_id:       string,
	pane_capture_request_id: string,
	conversation_id:         string,
	message_id:              string,
	width:                   json.Value,
	line_limit:              json.Value,
	settle_ms:               json.Value,
}

bridge_hub_handle_pane_capture_command :: proc(conn: ^ws.Connection, text: string) {
	cmd: Bridge_Pane_Capture_Command
	_ = vault.wire_decode(text, &cmd) // malformed: no command_id, protocol_version 0 -> refused below
	command_id := cmd.command_id
	if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = bridge_hub_send(conn, cached); return }
	if cmd.protocol_version != 1 {
		failed := bridge_command_failed_json(command_id, bridge_cause_wire_error("unsupported_command", "capture_agent_pane protocol_version must be 1"))
		bridge_runtime_cache_command(command_id, failed)
		_ = bridge_hub_send(conn, failed)
		return
	}
	instance_id := cmd.agent_instance_id
	pending := Bridge_Pane_Capture_Pending{
		command_id = strings.clone(command_id),
		pane_capture_request_id = strings.clone(cmd.pane_capture_request_id),
		conversation_id = strings.clone(cmd.conversation_id),
		message_id = strings.clone(cmd.message_id),
		agent_instance_id = strings.clone(instance_id),
		width = clamp(bridge_json_int(cmd.width, 80), 40, 200),
		line_limit = clamp(bridge_json_int(cmd.line_limit, 120), 20, 300),
		deadline_unix_ms = bridge_runtime_now_ms() + i64(clamp(bridge_json_int(cmd.settle_ms, 3000), 500, 10000) + 30000),
	}
	// Serve the capture by proxying host.capture synchronously against the daemon,
	// which returns the rendered VT screen joined into the pane-text result shape
	// the UI expects.
	_ = instance_id
	accepted := bridge_command_result_json(command_id, "accepted", "")
	bridge_runtime_cache_command(command_id, accepted)
	_ = bridge_hub_send(conn, accepted)
	result := bridge_pty_host_capture_result(pending)
	_ = bridge_hub_send(conn, result)
}

// bridge_hub_handle_wake_agent services the ephemeral-lifecycle push from the hub
// (REQ-10/REQ-11). The reconcile pass sends one wake_agent per (chain × bridge):
//   {"type":"wake_agent","chain_id":"..","payload":{"run":[{"agent_instance_id":"..",
//    "task_id":"..","role":".."}],"stop":["..",..]}}
// run[] names the non-coordinator agents that SHOULD be running for the chain right
// now — started fresh (full bootstrap) when we hold no launch record, or restarted
// (process re-fork from the saved spec, reusing run_dir + token) when a record
// exists but the process is not registered with the daemon; an already-running agent
// is left alone. stop[] names the instances whose task is no longer actionable and
// should be stopped. Coordinators are never emitted by the hub, but we re-check the
// role here (both from run[] entries and from the local launch record) as defense in
// depth so this path can never stop or churn a coordinator. The command body carries
// no command_id and the hub fire-and-forgets the send, so there is normally nothing
// to ack; we still ack if a command_id is ever present.
bridge_hub_handle_wake_agent :: proc(conn: ^ws.Connection, text: string) {
	command_id := extract_json_string(text, "command_id", "")
	payload, payload_ok := bridge_provider_json_extract_object(text, "payload")
	if !payload_ok {
		if command_id != "" do _ = bridge_hub_send(conn, bridge_command_result_json(command_id, "succeeded", ""))
		return
	}

	// coordinator_ids collects any instance the hub (unexpectedly) marked coordinator
	// in run[]; combined with the local launch-record role in the stop loop below it
	// guarantees a coordinator can never be terminated by this path.
	coordinator_ids := make(map[string]bool)
	defer delete(coordinator_ids)

	// RUN: start fresh, restart, or no-op each entry.
	if run_arr, run_ok := bridge_provider_json_extract_array(payload, "run"); run_ok {
		entries := bridge_provider_json_top_level_objects(run_arr)
		defer { for e in entries do delete(e); delete(entries) }
		for entry in entries {
			instance_id := extract_json_string(entry, "agent_instance_id", "")
			role := extract_json_string(entry, "role", "")
			if role == "coordinator" {
				if strings.trim_space(instance_id) != "" do coordinator_ids[instance_id] = true
				continue
			}
			if strings.trim_space(instance_id) == "" do continue
			task_id  := extract_json_string(entry, "task_id", "")
			provider := extract_json_string(entry, "provider", "")
			provider_profile:=extract_json_string(entry,"provider_profile","");defer delete(provider_profile)
			model     := extract_json_string(entry, "model", "")
			// REQ-37: the enriched descriptor fields the hub now carries per run[] entry.
			// Forwarding them into the synthetic launch_agent payload makes the bridge
			// take the full agent-keyed template bootstrap instead of the header-only
			// instance fallback. Missing (old hub) -> empty -> launch fails loudly at the
			// agent_id guard rather than silently producing a 6-line CLAUDE.md.
			agent_id       := extract_json_string(entry, "agent_id", "")
			agent_name     := extract_json_string(entry, "agent_name", "")
			chain_id       := extract_json_string(entry, "chain_id", "")
			chain_title    := extract_json_string(entry, "chain_title", "")
			coordinator_id           := extract_json_string(entry, "coordinator_agent_instance_id", "")
			coordinator_display_name := extract_json_string(entry, "coordinator_display_name", "")
			project_id               := extract_json_string(entry, "project_id", "")
			project_path             := extract_json_string(entry, "project_path", "")
			// Task System v2: the lease this wake delivers and its context pack.
			// Forwarded verbatim into the synthetic launch so the bootstrap (M3)
			// can write <run_dir>/TASK.md; the agent's first act is `lease next`.
			lease_id := extract_json_string(entry, "lease_id", "")
			permission_mode := extract_json_string(entry, "permission_mode", "")
			run_count, _ := bridge_provider_json_extract_int(entry, "run_count")
			pack_json, _ := bridge_provider_json_extract_object(entry, "pack")
			defer delete(pack_json)

			if _, has := bridge_runtime_get_launch(instance_id); has {
				// A launch record exists, but restart via the pty-host's remembered
				// spec would reuse the ORIGINAL run_dir contents — including a stale
				// CLAUDE.md written at first launch. Re-bootstrap instead: run the full
				// launch path (deterministic run_dir, fresh token, current bootstrap
				// template) so template updates take effect on each reconcile restart.
				// bridge_runtime_launch_agent_pty_host already closes any registered
				// instance before re-spawning, so no separate is_registered check.
				syn_command_id := fmt.tprintf("wake_restart_%s_%d", instance_id, bridge_runtime_now_ms())
				command_json := bridge_wake_launch_command_json(syn_command_id, instance_id, task_id, role, provider, model, agent_id, agent_name, chain_id, chain_title, coordinator_id, project_id, project_path, coordinator_display_name, lease_id, pack_json, permission_mode, run_count,provider_profile)
				defer delete(command_json)
				ok, detail, launch_err := bridge_runtime_launch_agent(syn_command_id, command_json, bridge_command_worker_deadline_ns(conn))
				if ok {
					bridge_runtime_set_launch_role(instance_id, role)
					fmt.println("bridge wake_agent: re-bootstrapped and restarted instance", instance_id)
				} else {
					fmt.eprintln("bridge wake_agent: restart via re-bootstrap failed", instance_id, detail, bridge_error_string(launch_err))
					bridge_wake_report_failed_status(conn, instance_id)
					blog_error(.agent_launch_failed, blog_sym(.command_kind, .wake_agent), blog_sym(.stage, .materialize))
				}
			} else {
				// No launch record: fresh full bootstrap via the standard launch path.
				// The instance id MUST live inside a "payload" object (matching the hub
				// launch_agent contract) so bridge_bootstrap_descriptor_from_launch can
				// resolve it — a top-level-only id aborts the launch at validate. This
				// mirrors the scheduler sched_wake synthetic launch.
				syn_command_id := fmt.tprintf("wake_launch_%s_%d", instance_id, bridge_runtime_now_ms())
				command_json := bridge_wake_launch_command_json(syn_command_id, instance_id, task_id, role, provider, model, agent_id, agent_name, chain_id, chain_title, coordinator_id, project_id, project_path, "", lease_id, pack_json, permission_mode, run_count,provider_profile)
				defer delete(command_json)
				ok, detail, launch_err := bridge_runtime_launch_agent(syn_command_id, command_json, bridge_command_worker_deadline_ns(conn))
				if ok {
					bridge_runtime_set_launch_role(instance_id, role)
					fmt.println("bridge wake_agent: launched instance", instance_id)
				} else {
					fmt.eprintln("bridge wake_agent: launch failed", instance_id, detail, bridge_error_string(launch_err))
					bridge_wake_report_failed_status(conn, instance_id)
					blog_error(.agent_launch_failed, blog_sym(.command_kind, .wake_agent), blog_sym(.stage, .spawn))
				}
			}
		}
	}

	// STOP: terminate each instance whose task is no longer actionable, honoring the
	// coordinator exemption (defense in depth — the hub never emits coordinators).
	if stop_ids, stop_ok := bridge_provider_json_extract_string_array(payload, "stop"); stop_ok {
		defer delete(stop_ids)
		for id in stop_ids {
			if strings.trim_space(id) == "" do continue
			if coordinator_ids[id] do continue
			if launch, has := bridge_runtime_get_launch(id); has && launch.role == "coordinator" do continue
			bridge_runtime_stop_agent(id)
			fmt.println("bridge wake_agent: stopped instance", id)
		}
	}

	if command_id != "" do _ = bridge_hub_send(conn, bridge_command_result_json(command_id, "succeeded", ""))
}

// bridge_wake_report_failed_status sends a woken instance's failed status, with its
// typed error, right away (REQ-ERR-PROTO-A) so the hub can act on the class instead
// of waiting for the next heartbeat.
bridge_wake_report_failed_status :: proc(conn: ^ws.Connection, instance_id: string) {
	if conn == nil do return
	st_json := bridge_instance_status_json(instance_id)
	defer delete(st_json)
	_ = bridge_hub_send(conn, st_json)
}

// bridge_wake_launch_command_json builds the synthetic launch_agent command the
// wake_agent handler feeds to bridge_runtime_launch_agent. It carries the SAME
// payload keys as the hub's launch_command_json_full so the resulting descriptor
// (bridge_bootstrap_descriptor_from_launch) is fully populated and the launch takes
// the agent-keyed template bootstrap path rather than the header-only fallback
// (REQ-37). Free-text fields (agent_name, chain_title) are JSON-escaped. Fields are
// emitted unconditionally (empty is harmless) so the descriptor is deterministic.
bridge_wake_launch_command_json :: proc(command_id, instance_id, task_id, role, provider, model, agent_id, agent_name, chain_id, chain_title, coordinator_id, project_id, project_path: string, coordinator_display_name: string = "", lease_id: string = "", pack_json: string = "", permission_mode: string = "", run_count := 0,provider_profile:string = "") -> string {
	b := strings.builder_make()
	write_field :: proc(b: ^strings.Builder, first: ^bool, key, val: string) {
		if !first^ do strings.write_byte(b, ',')
		first^ = false
		strings.write_byte(b, '"'); strings.write_string(b, key); strings.write_string(b, "\":\"")
		bridge_runtime_write_json_string(b, val)
		strings.write_byte(b, '"')
	}
	strings.write_string(&b, "{\"type\":\"launch_agent\",\"command_id\":\"")
	bridge_runtime_write_json_string(&b, command_id)
	strings.write_string(&b, "\",\"payload\":{")
	first := true
	write_field(&b, &first, "agent_instance_id", instance_id)
	write_field(&b, &first, "task_id", task_id)
	write_field(&b, &first, "role", role)
	write_field(&b, &first, "provider", provider)
	write_field(&b,&first,"provider_profile",profile_effective_id(provider,provider_profile))
	write_field(&b, &first, "model", model)
	write_field(&b, &first, "agent_id", agent_id)
	write_field(&b, &first, "agent_name", agent_name)
	write_field(&b, &first, "chain_id", chain_id)
	write_field(&b, &first, "chain_title", chain_title)
	write_field(&b, &first, "coordinator_agent_instance_id", coordinator_id)
	if coordinator_display_name != "" {
		write_field(&b, &first, "coordinator_display_name", coordinator_display_name)
	}
	write_field(&b, &first, "project_id", project_id)
	write_field(&b, &first, "project_path", project_path)
	strings.write_string(&b, ",\"run_count\":"); strings.write_string(&b, fmt.tprintf("%d", run_count))
	// Task System v2 lease delivery (empty on non-lease wakes).
	if lease_id != "" {
		write_field(&b, &first, "lease_id", lease_id)
	}
	// REQ-EXT-PERM-2: omitted when the hub did not send one (launch stays yolo).
	if permission_mode != "" {
		write_field(&b, &first, "permission_mode", permission_mode)
	}
	if strings.has_prefix(strings.trim_space(pack_json), "{") {
		strings.write_string(&b, ",\"pack\":")
		strings.write_string(&b, strings.trim_space(pack_json))
	}
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

// bridge_runtime_launch_agent launches (or confirms) the instance named in a
// launch_agent command. On failure `err` carries the typed code + class so callers
// decide retry/park/fail from the class, never from the `detail` text.
bridge_runtime_launch_agent :: proc(command_id, command_json: string, deadline_ns: i64 = 0) -> (ok: bool, detail: string, err: Bridge_Error) {
	if !bridge_auto_update_launch_enter() do return false, "bridge is applying an automatic update; retry after reconnect", bridge_error(.agent_launch_failed, .other, retry_after_ms = 30_000)
	defer bridge_auto_update_launch_leave()
	instance_id := extract_json_string(command_json, "agent_instance_id", "")
	if strings.trim_space(instance_id) == "" do return false, "missing agent_instance_id", bridge_error(.agent_launch_failed, .unsupported)
	defer if !ok do bridge_runtime_record_failure(instance_id, err)
	launch_epoch := extract_json_string(command_json, "launch_epoch", "")
	run_count, _ := bridge_provider_json_extract_int(command_json, "run_count")
	defer delete(launch_epoch)
	instance_token := extract_json_string(command_json, "instance_token", "")
	defer delete(instance_token)
	if instance_token == "" {
		instance_token = bridge_agent_instance_last_assertion(instance_id)
		if instance_token == "" do instance_token = strings.concatenate({"hit_", instance_id})
	}
	// Task wakes carry a persisted generation even without a migration epoch.
	// A duplicate wake must preserve an already-live child and its local token;
	// delayed commands must never replace a newer launch or undo its stop.
	if run_count > 0 && launch_epoch == "" {
		current := bridge_agent_instance_run_count(instance_id)
		if run_count < current do return false, "superseded startup generation", bridge_error(.agent_launch_failed, .denied)
		if run_count == current {
			assertion := bridge_agent_instance_assertion(instance_id)
			defer delete(assertion)
			if assertion == "" do return false, "startup generation was revoked", bridge_error(.agent_launch_failed, .denied)
			sync.mutex_lock(&bridge_runtime_mutex)
			stopped := bridge_runtime_stop_intent_active_locked(instance_id, bridge_runtime_now_ms())
			sync.mutex_unlock(&bridge_runtime_mutex)
			if stopped do return false, "startup generation was stopped", bridge_error(.agent_launch_failed, .denied)
			socket, daemon_ok := bridge_pty_host_ensure_daemon()
			if !daemon_ok do return false, "ham-pty-host daemon unavailable", bridge_error(.pty_host_unreachable)
			confirmed, queried := bridge_startup_confirm_spawned(socket, instance_id, run_count)
			if !queried do return false, "cannot confirm existing launch identity", bridge_error(.pty_host_unreachable)
			if confirmed { bridge_task_wake_note_launched(instance_id); return true, "", {} }
		}
	}
	if launch_epoch != "" {
		socket, daemon_ok := bridge_pty_host_ensure_daemon()
		if !daemon_ok do return false, "ham-pty-host daemon unavailable", bridge_error(.pty_host_unreachable)
		existing, listed := bridge_pty_host_list(socket)
		if !listed do return false, "cannot inspect existing destination runtime", bridge_error(.pty_host_unreachable)
		registered, alive := false, false
		for agent in existing.agents do if agent.instance_id == instance_id { registered = true; alive = agent.alive; break }
		pty_host_reply_delete(existing)
		if registered {
			assertion := bridge_agent_instance_assertion(instance_id)
			defer delete(assertion)
			if assertion == instance_token {
				if alive {
					confirmed, queried := bridge_startup_confirm_spawned(socket, instance_id, run_count)
					if !queried do return false, "cannot confirm destination launch identity", bridge_error(.pty_host_unreachable)
					if confirmed { bridge_task_wake_note_launched(instance_id); return true, "", {} }
					return false, "destination has an unconfirmed launch identity", bridge_error(.agent_launch_failed, .denied)
				}
				if !bridge_pty_host_close(socket, instance_id) do return false, "cannot close exited destination runtime", bridge_error(.agent_launch_failed, .replaced)
			} else {
				// Recoverable: the launch may proceed once the other runtime is gone.
				return false, "destination has an unrelated or unconfirmed runtime; refusing duplicate launch", bridge_error(.agent_launch_failed, .denied)
			}
		}
	}
	// A genuine (re)launch supersedes any prior stop intent for this instance id.
	bridge_runtime_clear_stop_intent(instance_id)
	// Agents always run in their own managed run dir (never the project path).
	// The project path/description is provided to the agent via AGENTS.md instead,
	// so the agent decides when/how to work against the project checkout.
	run_dir := bridge_runtime_default_run_dir(instance_id)
	// The bridge is the sole writer of run_dir contents: bootstrap materialization
	// below clean-slates and writes the assembled file set directly.
	_ = bridge_make_directory_all(run_dir)
	endpoint, endpoint_ok := bridge_runtime_ensure_local_endpoint()
	if !endpoint_ok do return false, "local endpoint unavailable", bridge_error(.agent_launch_failed, .socket_dir)
	bridge_runtime_set_status(instance_id, "starting", "active")
	// H7 restart-reap: invalidate ANY prior local tokens for this instance BEFORE
	// issuing fresh ones. A superseded old runtime then fails its next liveness
	// ping (its token is no longer valid). The freshly issued agent token below is
	// non-deterministic (hlat_<nanos>_<seq>), so the new runtime is
	// cryptographically distinct from the old one.
	invalidated := bridge_agent_token_invalidate_instance(instance_id)
	if invalidated > 0 do fmt.println("bridge launch: invalidated prior local tokens for instance", instance_id, "count", invalidated)
	agent_issue := bridge_agent_token_issue(instance_id, instance_token, .Agent, run_count)
	bridge_startup_begin(agent_issue.plaintext_token)
	provider, model := bridge_runtime_provider_model(command_json)
	// Conditional, per-hash bootstrap (BRG-1..BRG-4): build the per-instance
	// descriptor from the enriched launch payload, run one conditional manifest GET
	// + per-hash blob fetches (only what is missing from disk), then ASSEMBLE +
	// PUBLISH the finished file set for the wrapper RPCs. The bridge does NOT write
	// the run_dir — the wrapper materializes it via bootstrap.list/.file (WRP-1).
	// A staged failure surfaces the stage + HTTP status instead of a generic string.
	descriptor := bridge_bootstrap_descriptor_from_launch(command_json)
	if strings.trim_space(descriptor.provider) == "" do descriptor.provider = provider
	// DEL-1: pty-host is the only agent-launch runtime. The bridge clean-slates the
	// run_dir and WRITES the assembled file set directly (wrapper-free), then spawns
	// the agent under the ham-pty-host daemon.
	credential_snapshot_2312 := bridge_credential_snapshot()
	defer delete(credential_snapshot_2312)
	boot_res := bridge_bootstrap_launch_materialize_run_dir(bridge_config.daemon_url, credential_snapshot_2312, run_dir, endpoint, agent_issue.plaintext_token, descriptor, &bootstrap_global_cache, deadline_ns)
	if !boot_res.ok {
		bridge_runtime_set_status(instance_id, "failed", "idle")
		detail := fmt.tprintf("bootstrap failed at stage=%s http_status=%d: %s", boot_res.stage, boot_res.http_status, boot_res.detail)
		fmt.println("bridge launch_agent bootstrap failed", "instance=", instance_id, "stage=", boot_res.stage, "http_status=", boot_res.http_status, "detail=", boot_res.detail)
		blog_error(.agent_bootstrap_invalid, blog_sym(.stage, blog_bootstrap_stage(boot_res.stage)), blog_int(.hub_status, i64(boot_res.http_status)), blog_provider(provider))
		return false, detail, bridge_bootstrap_result_error(boot_res)
	}
	// REQ-EXT-PERM-2: the agent's permission mode ("ask" drops the catalog yolo
	// flags). Absent (older hub) means the historical yolo launch.
	permission_mode := extract_json_string(command_json, "permission_mode", "")
	defer delete(permission_mode)
	provider_profile := extract_json_string(command_json, "provider_profile", "")
	defer delete(provider_profile)
	return bridge_runtime_launch_agent_pty_host(command_id, instance_id, run_dir, endpoint, provider, model, agent_issue.plaintext_token, descriptor.display_name, 0, descriptor.project_path, permission_mode, provider_profile)
}

bridge_runtime_launch_provider_test :: proc(command_id, command_json: string) -> (ok: bool, detail: string, err: Bridge_Error) {
	instance_id := extract_json_string(command_json, "agent_instance_id", "")
	defer delete(instance_id)
	provider, model := bridge_runtime_provider_model(command_json)
	defer { delete(provider); delete(model) }
	provider_profile := extract_json_string(command_json, "provider_profile", "")
	defer delete(provider_profile)
	pp,profile_error := profile_lookup(provider,provider_profile)
	if profile_error != .None do return false,profile_error_code(profile_error),bridge_error(.agent_launch_failed,.unsupported)
	if strings.trim_space(instance_id) == "" || !profile_has_model(&pp,provider,model) do return false,"invalid provider test request",bridge_error(.agent_launch_failed,.unsupported)
	defer if !ok do bridge_runtime_record_failure(instance_id, err)
	bridge_runtime_clear_stop_intent(instance_id)
	run_dir := bridge_runtime_default_run_dir(instance_id)
	defer delete(run_dir)
	_ = bridge_make_directory_all(run_dir)
	endpoint, endpoint_ok := bridge_runtime_ensure_local_endpoint()
	if !endpoint_ok do return false, "local endpoint unavailable", bridge_error(.agent_launch_failed, .socket_dir)
	bridge_runtime_set_status(instance_id, "starting", "active")
	_ = bridge_agent_token_invalidate_instance(instance_id)
	instance_token := strings.concatenate({"hit_", instance_id})
	defer delete(instance_token)
	run_count, _ := bridge_provider_json_extract_int(command_json, "run_count")
	agent_issue := bridge_agent_token_issue(instance_id, instance_token, .Agent, run_count)
	bridge_startup_begin(agent_issue.plaintext_token)
	if !bridge_bootstrap_materialize_local_provider_test(run_dir, endpoint, agent_issue.plaintext_token, instance_id, provider) {
		bridge_runtime_set_status(instance_id, "failed", "idle")
		return false, "provider test bootstrap failed", bridge_error(.agent_bootstrap_invalid)
	}
	return bridge_runtime_launch_agent_pty_host(command_id, instance_id, run_dir, endpoint, provider, model, agent_issue.plaintext_token, "Provider test", PROVIDER_TEST_TIMEOUT_SECONDS, provider_profile = provider_profile)
}

// bridge_runtime_launch_agent_pty_host is the wrapper-free launch path (BR-2).
// The bootstrap was already assembled/published above; here we (1) materialize
// the run_dir + HEIMDALL_* env directly on disk via BR-1, (2) lazy-start the
// ham-pty-host daemon, and (3) spawn (or restart, if the instance is already
// registered) the agent under the daemon PTY. Retry/backoff on spawn preserves
// AC-5 launch resilience.
bridge_runtime_launch_agent_pty_host :: proc(command_id, instance_id, run_dir, endpoint, provider, model, agent_token, display_name: string, timeout_seconds: u64, project_path: string = "", permission_mode: string = "", provider_profile: string = "") -> (ok: bool, detail: string, err: Bridge_Error) {
	// REQ-PROF-4: an unknown or disabled profile fails the launch; it never falls
	// back to the default profile, which could run under the wrong account.
	pp, pp_err := profile_lookup(provider, provider_profile)
	if pp_err != .None {
		bridge_runtime_set_status(instance_id, "failed", "idle")
		return false, profile_error_code(pp_err), bridge_error(.agent_launch_failed, .unsupported)
	}
	pp_ref: ^Provider_Profile = &pp
	// Bootstrap files were already clean-slated + written to run_dir by
	// bridge_bootstrap_launch_materialize_run_dir in the caller (the bridge is the
	// sole materializer in the pty-host runtime). Here we only build the agent env.
	env := bridge_prespawn_env(run_dir, endpoint, agent_token, instance_id)
	defer { for e in env do delete(e); delete(env) }

	socket, daemon_ok := bridge_pty_host_ensure_daemon()
	if !daemon_ok {
		bridge_runtime_set_status(instance_id, "failed", "idle")
		return false, "ham-pty-host daemon unavailable", bridge_error(.pty_host_unreachable)
	}

	req, req_ok := bridge_pty_host_build_spawn(instance_id, run_dir, provider, model, agent_token, env, display_name, timeout_seconds, permission_mode, pp_ref)
	if !req_ok {
		bridge_runtime_set_status(instance_id, "failed", "idle")
		blog_error(.provider_missing, blog_provider(provider))
		return false, "provider has no runnable command", bridge_error(.provider_missing)
	}
	defer bridge_pty_host_spawn_request_delete(req)

	// The hub's launch_agent command always carries the authoritative
	// provider/model, and we just rebuilt argv/env from it. host.restart would
	// re-spawn from the daemon's REMEMBERED spec (stale argv → stale model on a
	// reconfigure, e.g. model smart still launching the old sonnet binary). So if
	// the instance is already registered, close it first, then spawn fresh with
	// the new spec. This makes provider/model changes actually take effect.
	pid: i32
	stream_conn, stream_was_active := bridge_pty_stream_worker_get_active_conn(instance_id)
	if stream_was_active {
		bridge_pty_stream_worker_detach(instance_id)
	}
	if bridge_pty_host_is_registered(socket, instance_id) {
		if !bridge_pty_host_close(socket, instance_id) {
			bridge_runtime_set_status(instance_id, "failed", "idle")
			blog_error(.agent_launch_failed, blog_provider(provider), blog_sym(.stage, .spawn), blog_sym(.reason, .replaced))
			return false, "failed to close existing instance before respawn", bridge_error(.agent_launch_failed, .replaced)
		}
	}
	// Arm before Spawn: a hook may call the local endpoint before Spawn returns.
	bridge_startup_arm(instance_id, agent_token, bridge_runtime_now_ms())
	pid, ok = bridge_pty_host_spawn(socket, req)
	if !ok {
		bridge_runtime_set_status(instance_id, "failed", "idle")
		blog_error(.agent_launch_failed, blog_provider(provider), blog_sym(.stage, .spawn))
		return false, "ham-pty-host spawn failed", bridge_error(.agent_launch_failed, .spawn)
	}
	bridge_runtime_set_pty_process_alive(instance_id, true)
	bridge_startup_spawned(instance_id, agent_token, pid)
	bridge_runtime_record_launch(Bridge_Runtime_Launch{agent_instance_id = strings.clone(instance_id), command_id = strings.clone(command_id), run_dir = strings.clone(run_dir), project_path = strings.clone(strings.trim_space(project_path)), pane_id = fmt.tprintf("pty-host:%d", pid), agent_token = strings.clone(agent_token), provider_sym = contracts.bridge_log_provider_sym(provider), launched_at_ns = time.tick_now()._nsec})
	// BR-3: ensure the event-subscription worker is running so this instance's
	// ChildExited/StartupReady/StartupBlocked/ScreenChanged events flow to the hub
	// status/activity surface without polling.
	bridge_pty_host_events_ensure()
	if stream_was_active {
		bridge_pty_stream_worker_start(instance_id, instance_id, stream_conn)
	}
	bridge_task_wake_note_launched(instance_id)
	return true, "", {}
}

// Stop the PTY child before invalidating credentials and declaring it stopped.
// A failed close leaves stop intent active and must never acknowledge success.
bridge_runtime_stop_agent :: proc(instance_id: string, force: bool = false) -> bool {
	if strings.trim_space(instance_id) == "" do return false
	// Record the operator's intent to stop, so a late/duplicate wrapper signal that
	// races the ~1s self-reap window cannot resurrect the instance back to
	// running/starting (see bridge_runtime_note_activity_signal).
	bridge_runtime_mark_stop_intent(instance_id)
	bridge_runtime_set_status(instance_id, "stopping", "idle")
	// Wrapper-free: the bridge closes the instance on the ham-pty-host daemon
	// directly (SIGTERM->SIGKILL + unregister). Token invalidation below is still
	// done for defense-in-depth.
	socket, daemon_ok := bridge_pty_host_ensure_daemon()
	if !daemon_ok do return false
	// An absent instance is an idempotent stop only after a successful list.
	// is_registered alone cannot distinguish absence from transport failure.
	reply, list_ok := bridge_pty_host_list(socket)
	if !list_ok do return false
	registered, alive := false, false
	for agent in reply.agents do if agent.instance_id == instance_id { registered = true; alive = agent.alive; break }
	pty_host_reply_delete(reply)
	if force && registered && alive {
		client := Pty_Host_Client{socket = socket}
		// An instance that exited between the list and the SIGKILL is already stopped.
		if result, _ := bridge_pty_host_signal_detailed(&client, instance_id, 9); result == .Refused do return false
	}
	if registered && !bridge_pty_host_close(socket, instance_id) do return false

	// Invalidate every local token for this instance (persisted to disk).
	invalidated := bridge_agent_token_invalidate_instance(instance_id)
	if invalidated > 0 do fmt.println("bridge stop: invalidated local tokens for instance", instance_id, "count", invalidated)
	// Drop any in-memory launch record so we don't hold stale pane/token data.
	bridge_runtime_remove_launch(instance_id)
	bridge_runtime_set_status(instance_id, "stopped", "idle")
	return true
}

bridge_runtime_ensure_local_endpoint :: proc() -> (string, bool) {
	if bridge_config.local_endpoint_port == 0 do bridge_config.local_endpoint_port = 49324
	local_config := bridge_local_endpoint_config_default(bridge_config.local_endpoint_run_dir, bridge_config.local_endpoint_port)
	if !bridge_runtime_local_endpoint_started {
		bridge_runtime_local_endpoint_unix_started = bridge_local_endpoint_start_unix(local_config)
		bridge_runtime_local_endpoint_loopback_started = bridge_local_endpoint_start_loopback(local_config)
		bridge_runtime_local_endpoint_started = bridge_runtime_local_endpoint_unix_started || bridge_runtime_local_endpoint_loopback_started
		if bridge_runtime_local_endpoint_started {
			bridge_runtime_local_endpoint_descriptor = bridge_runtime_select_endpoint(local_config)
		}
	}
	if !bridge_runtime_local_endpoint_started do return "", false
	if bridge_runtime_local_endpoint_descriptor == "" do bridge_runtime_local_endpoint_descriptor = bridge_runtime_select_endpoint(local_config)
	return bridge_runtime_local_endpoint_descriptor, bridge_runtime_local_endpoint_descriptor != ""
}

bridge_runtime_select_endpoint :: proc(local_config: Bridge_Local_Endpoint_Config) -> string {
	// §12.0.2 contract: Unix-domain socket 0600 is primary; loopback TCP is fallback.
	// Only return a descriptor for a transport that actually started listening.
	if bridge_runtime_local_endpoint_unix_started do return bridge_local_endpoint_env_value(local_config, true)
	if bridge_runtime_local_endpoint_loopback_started do return bridge_local_endpoint_env_value(local_config, false)
	return ""
}

bridge_runtime_provider_model :: proc(command_json: string) -> (string, string) {
	provider := extract_json_string(command_json, "provider", "")
	model := extract_json_string(command_json, "model", "")
	if provider == "" || model == "" {
		payload := bridge_provider_payload_object(command_json)
		if provider == "" do provider = bridge_provider_json_extract_string(payload, "name", "")
		if model == "" do model = bridge_provider_json_extract_string(payload, "model", "")
	}
	return provider, model
}

bridge_runtime_agent_command :: proc(command_json, agent_token, agent_instance_id: string) -> string {
	provider, model := bridge_runtime_provider_model(command_json)
	defer { delete(provider); delete(model) }
	if strings.trim_space(provider) == "" || strings.trim_space(model) == "" do return ""
	if !bridge_provider_catalog_has_model(provider, model) do return ""
	if profile, ok := bridge_provider_catalog_profile(provider); ok {
		path, path_ok := bridge_provider_resolve_path(provider)
		if !path_ok do return ""
		defer delete(path)
		profile.command = []string{path}
		return bridge_runtime_shell_command_for_profile(profile, model, agent_token, agent_instance_id)
	}
	return ""
}

// bridge_runtime_startup_detection_arg renders a Startup_Detection_Config as the
// compact JSON blob passed via --startup-detection. Reuses the same writer that
// serializes provider startup_detection for the provider store JSON so the shape
// stays identical on both sides of the round-trip.
bridge_runtime_startup_detection_arg :: proc(sd: cfg_lib.Startup_Detection_Config) -> string {
	b := strings.builder_make()
	bridge_provider_write_startup_json(&b, sd)
	return strings.to_string(b)
}

bridge_runtime_find_on_path :: proc(name: string) -> string {
	path := os.get_env_alloc("PATH", context.allocator)
	defer delete(path)
	start := 0
	for start <= len(path) {
		end_rel := strings.index_byte(path[start:], BRIDGE_PATH_LIST_SEPARATOR)
		end := len(path)
		if end_rel >= 0 do end = start + end_rel
		dir := path[start:end]
		if strings.trim_space(dir) != "" do for file_name in bridge_os_executable_names(name) {
			candidate := strings.concatenate({strings.trim_right(dir, "/\\"), "/", file_name})
			if _, err := os.stat(candidate, context.allocator); err == nil {
				if absolute, abs_err := os.get_absolute_path(candidate, context.allocator); abs_err == nil && strings.trim_space(absolute) != "" {
					// get_absolute_path may return its input unchanged when candidate is
					// already absolute. Preserve the single owned allocation in that case;
					// deleting candidate before returning absolute would return a dangling
					// string and later crash its caller during cleanup.
					if raw_data(absolute) == raw_data(candidate) do return candidate
					delete(candidate)
					return absolute
				}
				return candidate
			}
			delete(candidate)
		}
		if end_rel < 0 do break
		start = end + 1
	}
	return ""
}

bridge_runtime_default_run_dir :: proc(instance_id: string) -> string {
	base := strings.trim_right(bridge_config.local_endpoint_run_dir, "/")
	if base == "" do base = bridge_scratch_local_default(context.temp_allocator)
	return strings.concatenate({base, "/instances/", bridge_runtime_safe_part(instance_id)})
}

bridge_runtime_safe_part :: proc(value: string) -> string {
	b := strings.builder_make()
	for ch in value {
		switch ch {
		case 'a'..='z', 'A'..='Z', '0'..='9', '_', '-', '@', '.': strings.write_rune(&b, ch)
		case: strings.write_string(&b, "_")
		}
	}
	return strings.to_string(b)
}

bridge_runtime_get_launch :: proc(instance_id: string) -> (Bridge_Runtime_Launch, bool) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for launch in bridge_runtime_launches { if launch.agent_instance_id == instance_id do return launch, true }
	return {}, false
}

bridge_runtime_record_launch :: proc(launch: Bridge_Runtime_Launch) {
	// The launch registry outlives the RPC/test allocator that reports it.
	context.allocator = runtime.heap_allocator()
	defer bridge_tool_live_note_launch(launch.agent_instance_id)
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_runtime_launches) {
		if bridge_runtime_launches[i].agent_instance_id == launch.agent_instance_id { bridge_runtime_launches[i] = launch; return }
	}
	append(&bridge_runtime_launches, launch)
}

bridge_runtime_remove_launch :: proc(instance_id: string) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_runtime_launches) {
		if bridge_runtime_launches[i].agent_instance_id == instance_id { unordered_remove(&bridge_runtime_launches, i); return }
	}
}

bridge_runtime_update_launch_pane :: proc(instance_id, pane_id: string) {
	if strings.trim_space(instance_id) == "" || strings.trim_space(pane_id) == "" do return
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_runtime_launches) {
		if bridge_runtime_launches[i].agent_instance_id == instance_id {
			bridge_runtime_launches[i].pane_id = strings.clone(pane_id)
			break
		}
	}
}

// bridge_runtime_set_launch_role stamps the wake_agent action role onto an existing
// launch record so a later stop[] push can honor the coordinator exemption. No-op if
// no launch record exists for the instance yet.
bridge_runtime_set_launch_role :: proc(instance_id, role: string) {
	if strings.trim_space(instance_id) == "" || strings.trim_space(role) == "" do return
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_runtime_launches) {
		if bridge_runtime_launches[i].agent_instance_id == instance_id {
			bridge_runtime_launches[i].role = strings.clone(role)
			break
		}
	}
}

bridge_runtime_now_ms :: proc() -> i64 {
	return bridge_now_unix_ms()
}

// bridge_runtime_record_failure attaches err to a "failed" instance so the next
// agent_instance_status carries it. A no-op unless the instance is failed.
bridge_runtime_record_failure :: proc(instance_id: string, err: Bridge_Error) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for &inst in bridge_runtime_instances {
		if inst.agent_instance_id != instance_id do continue
		if inst.runtime_status == "failed" {
			inst.last_error = err
			inst.has_last_error = true
		}
		return
	}
}

// bridge_runtime_stop_or_restore stops an instance; if the stop does not happen it
// must not leave the instance "stopping" on either side (REQ-ERR-PROTO-A). It clears
// the stop intent and puts back the pre-stop status, or "unreachable" when there was
// none to put back (an empty registry after a bridge restart): the agent may still be
// alive, and the liveness reconciler settles it from there. restored is that status
// ("" on success; caller owns it); the failed command_result carries it for the hub.
// stop is a seam for tests.
bridge_runtime_stop_or_restore :: proc(instance_id: string, force: bool, stop := bridge_runtime_stop_agent) -> (ok: bool, restored: string) {
	prior_runtime, prior_activity, had_prior := bridge_runtime_status_snapshot(instance_id)
	defer { delete(prior_runtime); delete(prior_activity) }
	if stop(instance_id, force) do return true, ""
	runtime_status, activity := "unreachable", "idle"
	if had_prior && prior_runtime != "" && prior_runtime != "stopping" {
		runtime_status, activity = prior_runtime, prior_activity
	}
	bridge_runtime_clear_stop_intent(instance_id)
	bridge_runtime_set_status(instance_id, runtime_status, activity)
	return false, strings.clone(runtime_status)
}

// bridge_runtime_status_snapshot returns an instance's current statuses (owned clones).
bridge_runtime_status_snapshot :: proc(instance_id: string) -> (runtime_status, activity_status: string, found: bool) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for inst in bridge_runtime_instances {
		if inst.agent_instance_id == instance_id do return strings.clone(inst.runtime_status), strings.clone(inst.activity_status), true
	}
	return "", "", false
}

bridge_runtime_set_status :: proc(instance_id, runtime_status, activity_status: string) {
    defer {
        if runtime_status == "stopped" || runtime_status == "failed" || runtime_status == "unreachable" do bridge_tool_live_clear(instance_id)
    }
	if strings.trim_space(instance_id) == "" do return
	// A stopped/failed agent can no longer act on a permission decision: release
	// its blocked permission waiters with "none".
	now := bridge_runtime_now_ms()
	if runtime_status == "stopped" || runtime_status == "failed" {
		bridge_permission_cancel_instance(instance_id)
	}
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	bridge_runtime_set_status_locked(instance_id, runtime_status, activity_status, now, true)
}

bridge_runtime_note_wrapper_signal :: proc(instance_id, activity_status: string) {
	bridge_runtime_note_activity_signal(instance_id, activity_status, "wrapper")
}

bridge_runtime_note_agent_activity :: proc(instance_id, activity_status, activity_source: string) {
	source := strings.trim_space(activity_source)
	if source == "" do source = "agent_extension"
	// Screen detection drives the terminal_prompt blocker fallback (REQ-EXT-BLK-5).
	if source == "pane_diff" do bridge_blockers_note_pane_activity(instance_id, activity_status)
	bridge_runtime_note_activity_signal(instance_id, bridge_runtime_normalize_activity_status(activity_status), source)
}

bridge_runtime_note_activity_signal :: proc(instance_id, activity_status, activity_source: string) {
	if strings.trim_space(instance_id) == "" do return
	now := bridge_runtime_now_ms()
	activity := bridge_runtime_normalize_activity_status(activity_status)
	should_prompt := false
	sync.mutex_lock(&bridge_runtime_mutex)
	// Stop-intent guard: if an operator stop is in flight for this instance, drop
	// the signal so a late/racing wrapper liveness or subscribe cannot resurrect a
	// deliberately stopped instance back to running/starting. The intent is
	// time-boxed (BRIDGE_STOP_INTENT_TTL_MS) and cleared by a genuine relaunch.
	if bridge_runtime_stop_intent_active_locked(instance_id, now) {
		sync.mutex_unlock(&bridge_runtime_mutex)
		return
	}
	if inst, ok := bridge_runtime_instance_snapshot_locked(instance_id); ok {
		// A wrapper or extension activity signal proves the local process is alive,
		// but it is NOT equivalent to agent start-success. Any pre-success state
		// remains "starting" until the agent explicitly calls start-success.
		if !inst.start_success_seen {
			if inst.runtime_status == "failed" {
				bridge_runtime_set_status_with_source_locked(instance_id, "failed", activity, activity_source, now, true, false)
				should_prompt = bridge_runtime_maybe_mark_start_prompt_locked(instance_id, now, true)
			} else if inst.runtime_status == "blocked" {
				// A wrapper liveness/activity ping proves the process is alive but does NOT
				// resolve a blocked startup prompt. Keep the instance "blocked" (updating
				// only liveness/activity) instead of forcing it back to "starting", which
				// would erase the blocked signal on the very next ping. Only an explicit
				// start-success (-> "running", start_success_seen) clears it.
				bridge_runtime_set_status_with_source_locked(instance_id, "blocked", activity, activity_source, now, true, false)
			} else {
				bridge_runtime_set_status_with_source_locked(instance_id, "starting", activity, activity_source, now, true, false)
				should_prompt = bridge_runtime_maybe_mark_start_prompt_locked(instance_id, now, inst.runtime_status == "unreachable" || inst.runtime_status == "stopped")
			}
			sync.mutex_unlock(&bridge_runtime_mutex)
			if should_prompt do bridge_wrapper_push_startup_prompt(instance_id)
			return
		}
		bridge_runtime_set_status_with_source_locked(instance_id, "running", activity, activity_source, now, true, false)
		sync.mutex_unlock(&bridge_runtime_mutex)
		return
	}
	// No in-memory record usually means bridge restart while the tmux wrapper kept
	// running. Rediscover it as "starting" rather than "running"; Hub will keep a
	// durable already-ready instance running if appropriate, and otherwise the pane
	// receives an explicit start-success prompt.
	bridge_runtime_set_status_with_source_locked(instance_id, "starting", activity, activity_source, now, true, false)
	should_prompt = bridge_runtime_maybe_mark_start_prompt_locked(instance_id, now, true)
	sync.mutex_unlock(&bridge_runtime_mutex)
	if should_prompt do bridge_wrapper_push_startup_prompt(instance_id)
}

// bridge_runtime_mark_stop_intent records that an operator-requested stop has
// begun for this instance. It creates the in-memory record if missing (e.g. after
// a bridge restart where the registry is empty) so the tombstone survives the
// subsequent set_status calls and blocks resurrection by a late wrapper signal.
bridge_runtime_mark_stop_intent :: proc(instance_id: string) {
	if strings.trim_space(instance_id) == "" do return
	// Serialize a stop against an already claimed PTY fallback. The runtime mutex
	// is never held while waiting for the delivery to finish.
	sync.mutex_lock(&bridge_startup_io_mutex)
	defer sync.mutex_unlock(&bridge_startup_io_mutex)
	now := bridge_runtime_now_ms()
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_runtime_instances) {
		if bridge_runtime_instances[i].agent_instance_id == instance_id {
			bridge_runtime_instances[i].stopped_intent_unix_ms = now
			return
		}
	}
	append(&bridge_runtime_instances, Bridge_Runtime_Instance{agent_instance_id = strings.clone(instance_id), state_seq = bridge_runtime_next_state_seq(0, now), runtime_status = "stopping", activity_status = "idle", last_seen_unix_ms = now, stopped_intent_unix_ms = now})
}

// bridge_runtime_clear_stop_intent removes the stop tombstone (called when a
// genuine launch/relaunch of the same instance begins).
bridge_runtime_clear_stop_intent :: proc(instance_id: string) {
	if strings.trim_space(instance_id) == "" do return
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_runtime_instances) {
		if bridge_runtime_instances[i].agent_instance_id == instance_id {
			bridge_runtime_instances[i].stopped_intent_unix_ms = 0
			return
		}
	}
}

// bridge_runtime_stop_intent_active_locked reports whether a recent stop intent is
// still in effect. Caller must hold bridge_runtime_mutex.
bridge_runtime_stop_intent_active_locked :: proc(instance_id: string, now: i64) -> bool {
	for i in 0..<len(bridge_runtime_instances) {
		if bridge_runtime_instances[i].agent_instance_id == instance_id {
			ts := bridge_runtime_instances[i].stopped_intent_unix_ms
			return ts > 0 && now - ts < i64(BRIDGE_STOP_INTENT_TTL_MS)
		}
	}
	return false
}

bridge_runtime_mark_start_success :: proc(instance_id: string) {
	if strings.trim_space(instance_id) == "" do return
	now := bridge_runtime_now_ms()
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	if bridge_runtime_stop_intent_active_locked(instance_id, now) do return
	if inst, ok := bridge_runtime_instance_snapshot_locked(instance_id); ok {
		if inst.runtime_status == "stopped" || inst.runtime_status == "stopping" do return
	}
	bridge_runtime_set_status_locked(instance_id, "running", "idle", now, true)
}

bridge_runtime_set_status_locked :: proc(instance_id, runtime_status, activity_status: string, now: i64, touch_seen: bool) {
	bridge_runtime_set_status_with_source_locked(instance_id, runtime_status, activity_status, "bridge", now, touch_seen, true)
}

bridge_runtime_set_status_with_source_locked :: proc(instance_id, runtime_status, activity_status, activity_source: string, now: i64, touch_seen: bool, force_activity: bool) {
	// Registry snapshots outlive the RPC/test context that reported the status.
	context.allocator = runtime.heap_allocator()
	for i in 0..<len(bridge_runtime_instances) {
		if bridge_runtime_instances[i].agent_instance_id == instance_id {
			inst := &bridge_runtime_instances[i]
			old_runtime := inst.runtime_status
			accept_activity := activity_status != "" && (force_activity || bridge_runtime_accept_activity_update(inst, activity_source, now))
			runtime_changed := inst.runtime_status != runtime_status
			activity_changed := accept_activity && inst.activity_status != activity_status
			if runtime_changed || activity_changed {
				inst.state_seq = bridge_runtime_next_state_seq(inst.state_seq, now)
				if runtime_status != "failed" do inst.has_last_error = false
				inst.runtime_status = runtime_status
				if accept_activity do inst.activity_status = activity_status
			}
			// Independent lifecycle and screen-derived transitions reach the hub
			// immediately. The drain coalesces IDs and reads current state.
			// Native extension activity stays local until the normal heartbeat.
			// Native extension activity is local state, sampled by the normal
            // heartbeat. An event must never schedule an immediate durable
            // status/last-seen write, even when no live viewer exists.
            if (runtime_changed || activity_changed) && !strings.contains(activity_source, "extension") do bridge_runtime_enqueue_status_push_locked(instance_id)
			if accept_activity {
				inst.activity_source = strings.clone(activity_source)
				inst.activity_updated_unix_ms = now
			}
			if touch_seen || inst.last_seen_unix_ms == 0 do inst.last_seen_unix_ms = now
			if runtime_status == "starting" {
				inst.start_success_seen = false
				if old_runtime != "starting" || inst.start_deadline_unix_ms == 0 do inst.start_deadline_unix_ms = now + BRIDGE_START_SUCCESS_TIMEOUT_MS
			} else if runtime_status == "running" {
				inst.start_success_seen = true
				inst.start_deadline_unix_ms = 0
				inst.last_start_prompt_unix_ms = 0
				inst.pty_process_alive = true
			} else if runtime_status == "blocked" {
				// Blocked is a terminal-until-operator startup state: not ready (do NOT
				// set start_success_seen) but no longer racing the start-success deadline,
				// so clear the deadline to stop the starting->failed reaper from firing.
				inst.start_deadline_unix_ms = 0
			} else if !bridge_runtime_status_active(runtime_status) {
				inst.start_deadline_unix_ms = 0
				inst.pty_process_alive = false
			}
			return
		}
	}
	deadline: i64 = 0
	seen := runtime_status == "running"
	if runtime_status == "starting" do deadline = now + BRIDGE_START_SUCCESS_TIMEOUT_MS
	// Bridge-local state is memory-only and resets on bridge relaunch while Hub
	// keeps the durable last_applied_seq. Seed new local records from wall-clock ms
	// plus a safety offset so post-relaunch reports remain newer than prior Hub seqs
	// even if direct agent-actions (like repeated start-success) advanced the DB.
	if bridge_runtime_instances == nil do bridge_runtime_instances = make([dynamic]Bridge_Runtime_Instance)
	append(&bridge_runtime_instances, Bridge_Runtime_Instance{agent_instance_id = strings.clone(instance_id), state_seq = bridge_runtime_next_state_seq(0, now), runtime_status = strings.clone(runtime_status), activity_status = strings.clone(activity_status), activity_source = strings.clone(activity_source), activity_updated_unix_ms = now, last_seen_unix_ms = now, start_deadline_unix_ms = deadline, start_success_seen = seen, pty_process_alive = (runtime_status == "running")})
	if !strings.contains(activity_source, "extension") do bridge_runtime_enqueue_status_push_locked(instance_id)
}

bridge_runtime_next_state_seq :: proc(current: int, now: i64) -> int {
	floor := int(now + i64(BRIDGE_STATE_SEQ_FLOOR_OFFSET_MS))
	if current + 1 > floor do return current + 1
	return floor
}

bridge_runtime_accept_activity_update :: proc(inst: ^Bridge_Runtime_Instance, source: string, now: i64) -> bool {
	if inst == nil do return true
	current_rank := bridge_runtime_activity_source_rank(inst.activity_source)
	new_rank := bridge_runtime_activity_source_rank(source)
	if current_rank <= 0 || new_rank >= current_rank do return true
	if inst.activity_updated_unix_ms <= 0 do return true
	ttl := i64(BRIDGE_ACTIVITY_IDLE_SOURCE_TTL_MS)
	if inst.activity_status == "active" do ttl = i64(BRIDGE_ACTIVITY_ACTIVE_SOURCE_TTL_MS)
	return now - inst.activity_updated_unix_ms > ttl
}

bridge_runtime_activity_source_rank :: proc(source: string) -> int {
	s := strings.to_lower(strings.trim_space(source))
	defer delete(s)
	// NOTE: the pi_extension==100 fast-path was REMOVED with the pi activity
	// extension (task_18d129291c6a455d). It was the high-priority source that
	// suppressed a correct pane_diff 'idle' (the stuck 'working · settling' bug).
	// A native harness extension (e.g. antigravity) still ranks via the generic
	// contains("extension")=>80 branch below.
	if strings.contains(s, "extension") do return 80
	// Harness-agnostic tmux pane-capture detector: now the primary activity source
	// for every provider.
	if s == "pane_diff" do return 40
	// Permission gate (waiting_user while a blocking approval is outstanding, then
	// active on resolve). Ranked EQUAL to pane_diff on purpose: equal ranks always
	// accept (new_rank >= current_rank), so the gate's waiting_user shows
	// immediately AND the next pane_diff cycle can override it right after the gate
	// resolves — a higher rank would recreate a mini stuck-suppression until TTL.
	if s == "permission_gate" do return 40
	if s == "wrapper" do return 10
	if s == "bridge" do return 5
	return 1
}

// The result is borrowed (canonical literal or request-temp normalized text).
bridge_runtime_normalize_activity_status :: proc(status: string) -> string {
	s := strings.to_lower(strings.trim_space(status), context.temp_allocator)
	if s == "active" || s == "working" || s == "busy" do return "active"
	// waiting_user / waiting / waiting_approval: the agent has finished its turn and
	// is BLOCKED on a human (an empty prompt, a y/n approval, "press enter", …). It
	// is NOT doing work, so it must NOT surface as "active"/"working" in the hub —
	// otherwise an idle agent sitting on the user reads as busy forever. We collapse
	// these to the idle-equivalent projection; the finer-grained "waiting_user"
	// signal is still available on the wrapper sample for callers that want it.
	if s == "waiting_user" || s == "waiting" || s == "waiting_approval" do return "idle"
	if s == "idle" || s == "inactive" do return "idle"
	if s == "unknown" do return "unknown"
	if s == "" do return "unknown"
	return s
}

bridge_runtime_maybe_mark_start_prompt_locked :: proc(instance_id: string, now: i64, force: bool) -> bool {
	for i in 0..<len(bridge_runtime_instances) {
		if bridge_runtime_instances[i].agent_instance_id != instance_id do continue
		inst := &bridge_runtime_instances[i]
		// Managed PTY launches use the lifecycle-safe timer in startup_readiness.
		if inst.startup.generation != 0 do return false
		if inst.start_success_seen do return false
		if !force {
			started_at := inst.start_deadline_unix_ms - BRIDGE_START_SUCCESS_TIMEOUT_MS
			if inst.start_deadline_unix_ms == 0 || now - started_at < BRIDGE_START_SUCCESS_PROMPT_AFTER_MS do return false
		}
		if inst.last_start_prompt_unix_ms > 0 && now - inst.last_start_prompt_unix_ms < BRIDGE_START_SUCCESS_PROMPT_INTERVAL_MS do return false
		inst.last_start_prompt_unix_ms = now
		return true
	}
	return false
}

bridge_runtime_instance_snapshot :: proc(instance_id: string) -> (Bridge_Runtime_Instance, bool) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	return bridge_runtime_instance_snapshot_locked(instance_id)
}

// bridge_runtime_touch_liveness refreshes an ACTIVE instance's last_seen without
// otherwise mutating its runtime/activity state. It is the pty-host per-child
// liveness proof: the events subscriber (pane activity) is not a reliable liveness
// clock because an alive-but-idle agent emits no ScreenChanged, so a periodic
// worker calls this for every child the daemon still reports alive. The
// stop-intent guard is honored so a deliberately-stopped instance is never kept
// alive by a racing liveness tick, and start-success/deadline bookkeeping is left
// untouched (this proves "process alive", not "agent ready").
bridge_runtime_touch_liveness :: proc(instance_id: string, pty_process_alive: bool = false) {
	if strings.trim_space(instance_id) == "" do return
	now := bridge_runtime_now_ms()
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	if bridge_runtime_stop_intent_active_locked(instance_id, now) do return
	for i in 0..<len(bridge_runtime_instances) {
		if bridge_runtime_instances[i].agent_instance_id == instance_id {
			inst := &bridge_runtime_instances[i]
			if pty_process_alive do inst.pty_process_alive = true
			if inst.runtime_status == "unreachable" {
				if inst.start_success_seen {
					inst.runtime_status = "running"
				} else {
					inst.runtime_status = "starting"
				}
				inst.state_seq = bridge_runtime_next_state_seq(inst.state_seq, now)
				bridge_runtime_enqueue_status_push_locked(instance_id)
			} else if !bridge_runtime_status_active(inst.runtime_status) {
				return
			}
			inst.last_seen_unix_ms = now
			return
		}
	}
}

bridge_runtime_set_pty_process_alive_locked :: proc(instance_id: string, alive: bool) {
	if strings.trim_space(instance_id) == "" do return
	for i in 0..<len(bridge_runtime_instances) {
		if bridge_runtime_instances[i].agent_instance_id == instance_id {
			bridge_runtime_instances[i].pty_process_alive = alive
			return
		}
	}
}

bridge_runtime_set_pty_process_alive :: proc(instance_id: string, alive: bool) {
	if strings.trim_space(instance_id) == "" do return
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	bridge_runtime_set_pty_process_alive_locked(instance_id, alive)
}

bridge_runtime_instance_snapshot_locked :: proc(instance_id: string) -> (Bridge_Runtime_Instance, bool) {
	for inst in bridge_runtime_instances { if inst.agent_instance_id == instance_id do return inst, true }
	return {}, false
}

bridge_instance_status_json :: proc(instance_id: string) -> string {
	inst, ok := bridge_runtime_instance_snapshot(instance_id)
	if !ok do return strings.clone("{}")
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"agent_instance_status\",\"protocol_version\":1,\"agent_instance_id\":\"")
	bridge_runtime_write_json_string(&b, inst.agent_instance_id)
	epoch := bridge_agent_instance_launch_epoch(inst.agent_instance_id)
	strings.write_string(&b, "\",\"launch_epoch\":\""); bridge_runtime_write_json_string(&b, epoch); delete(epoch)
	strings.write_string(&b, "\",\"state_seq\":")
	strings.write_string(&b, fmt.tprintf("%d", inst.state_seq))
	strings.write_string(&b, ",\"runtime_status\":\"")
	bridge_runtime_write_json_string(&b, inst.runtime_status)
	strings.write_string(&b, "\",\"activity_status\":\"")
	bridge_runtime_write_json_string(&b, inst.activity_status)
	strings.write_string(&b, "\",\"activity_source\":\"")
	bridge_runtime_write_json_string(&b, inst.activity_source)
	strings.write_string(&b, "\"")
	bridge_runtime_write_instance_error(&b, inst)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// bridge_runtime_write_instance_error appends `,"error":{...}` for a failed instance
// whose cause is known (REQ-ERR-PROTO-A).
bridge_runtime_write_instance_error :: proc(b: ^strings.Builder, inst: Bridge_Runtime_Instance) {
	if inst.runtime_status != "failed" || !inst.has_last_error do return
	strings.write_string(b, ",\"error\":")
	contracts.write_wire_error(b, bridge_error_wire(inst.last_error))
}

// g_bridge_hub_enroll_only_runtime marks the `ham-bridge enroll` process, which
// brings up the Hub WebSocket only to receive the vault key and then restarts the
// registered service and exits (REQ-T2-3).
g_bridge_hub_enroll_only_runtime: bool

bridge_hub_set_enroll_only_runtime :: proc(enabled: bool) {
	sync.atomic_store(&g_bridge_hub_enroll_only_runtime, enabled)
}

bridge_hub_is_enroll_only_runtime :: proc() -> bool {
	return sync.atomic_load(&g_bridge_hub_enroll_only_runtime)
}

// bridge_hub_vault_status_for_report is the vault_status this process tells the hub.
//
// The enroll-only runtime always says "locked", even after it has received and
// stored the key. It holds that key only until it restarts the service and exits,
// so an "unlocked" from it would describe a process that is about to vanish, and
// the approval page would confirm the bridge unsealed even when the restarted
// service could not read the persisted key. Saying "locked" (rather than sending
// nothing, which the hub ignores) also overwrites an "unlocked" left over from a
// previous run of this bridge. The hub can then only see "unlocked" once the
// restarted service's on-connect heartbeat (bridge_hub_runtime_loop) reports
// what it actually read back from the keyring / Keychain.
//
// The hub's vocabulary is unlocked/locked: a bridge with no usable identity reports
// "locked" there too (it holds no key and refuses everything); the distinction is
// only visible bridge-locally through agent.vault.status.
//
// "unpaired": an enrolled bridge (identity ready) that never pinned an account root and
// holds no pairing keys can never accept a first unseal (it missed the one its
// enrollment allowed). It says so, so the UI can show it and offer revoke + re-enroll,
// instead of looking like an ordinary locked bridge that a key delivery would fix.
bridge_hub_vault_status_for_report :: proc() -> string {
	enroll_only := bridge_hub_is_enroll_only_runtime()
	status := bridge_vault_status_reported(enroll_only)
	if status == .Unlocked do return "unlocked"
	if !enroll_only && status == .Locked && bridge_vault_unpaired(strings.trim_space(bridge_config.daemon_id)) do return "unpaired"
	return "locked"
}

// bridge_vault_unpaired: no account root pinned and no armed pairing keys.
bridge_vault_unpaired :: proc(bridge_id: string) -> bool {
	return bridge_account_fingerprint(bridge_id) == "" && !bridge_pairing_is_armed()
}

// bridge_vault_status_reported is the decision above, with the process-wide flag
// as a parameter so tests can exercise it without flipping state that concurrent
// frame tests read.
bridge_vault_status_reported :: proc(enroll_only: bool) -> Vault_Status {
	if enroll_only do return .Locked
	return bridge_vault_status()
}

// bridge_vault_status_report_json is the IMMEDIATE vault report (REQ-BVS-1), sent
// right after a successful unseal or lock so the UI does not wait up to a heartbeat
// interval to see the new state.
//
// WHY A DEDICATED FRAME RATHER THAN RE-SENDING bridge_heartbeat, which also carries
// the field: the hub's bridge_heartbeat arm is not a status write. It runs the
// instance-digest reconciliation, the cross-bridge supersede detection and the
// stale-instance reap, and answers with a heartbeat ack. Firing all of that as a side
// effect of a vault operation would couple the vault path to instance lifecycle
// decisions whose wrong answer reaps live instances. This frame reports exactly the
// one thing that changed; the hub stores it through the same service proc the
// heartbeat uses, so there is still a single store-and-publish path.
Bridge_Vault_Status_Report :: struct {
	type:             string,
	protocol_version: int,
	vault_status:     string,
}

bridge_vault_status_report_json :: proc() -> string {
	out, _ := vault.wire_encode(Bridge_Vault_Status_Report{type = "bridge_vault_status", protocol_version = 1, vault_status = bridge_hub_vault_status_for_report()})
	return out
}

// Bridge_Vault_Command is the part of a bridge_unseal command the
// dispatcher reads (the unseal payload itself is decoded by unseal_protocol.odin).
Bridge_Vault_Command :: struct {
	command_id: string,
}

// bridge_vault_command_id decodes a vault command's command_id ("" when absent or
// malformed; temp-allocated).
bridge_vault_command_id :: proc(text: string) -> string {
	cmd: Bridge_Vault_Command
	if !vault.wire_decode(text, &cmd) do return ""
	return cmd.command_id
}

// Bridge_Vault_Command_Result is the reply to bridge_unseal: ok:true
// with the new status, or ok:false, status "error" and the typed wire error.
Bridge_Vault_Command_Result :: struct {
	type:       string,
	command_id: string,
	ok:         bool,
	status:     string,
	error:      Maybe(Bridge_Result_Error) `json:"error,omitempty"`,
}

// bridge_hub_send_vault_status pushes the immediate vault report (REQ-BVS-1).
// Best-effort by design: a failed send is not an error for the vault operation that
// triggered it, because the next bridge_heartbeat carries the same field and the hub
// converges either way. conn == nil is the replayed-from-cache path, where there is
// no socket to write to.
bridge_hub_send_vault_status :: proc(conn: ^ws.Connection) {
	if conn == nil do return
	// The enroll-only runtime would report the key it is about to exit with; the
	// restarted service's on-connect heartbeat is the report that counts.
	if bridge_hub_is_enroll_only_runtime() do return
	frame := bridge_vault_status_report_json()
	defer delete(frame)
	_ = bridge_hub_send(conn, frame)
}

// bridge_hub_heartbeat_json builds the heartbeat in the shape this connection
// negotiated (bridge_hub_heartbeat_shape).
bridge_hub_heartbeat_json :: proc() -> string {
	return bridge_hub_heartbeat_json_shaped(bridge_hub_heartbeat_shape())
}

// bridge_hub_heartbeat_json_shaped collects the live state for one heartbeat and
// serializes it with bridge_heartbeat_frame_json.
bridge_hub_heartbeat_json_shaped :: proc(shape: Bridge_Heartbeat_Shape) -> string {
	frame: Bridge_Heartbeat_Frame
	if !shape.omit_metadata do frame.features = bridge_runtime_features_json()
	// Diagnostics are collected only when sent, and BEFORE bridge_runtime_mutex is
	// taken: stats fork `ps` and read /proc, none of which belongs inside that lock.
	if !shape.omit_diagnostics {
		frame.stats = bridge_heartbeat_stats_json()
		frame.command_dispatch = bridge_command_dispatch_metrics_json()
		frame.dependency_breakers = bridge_dependency_breaker_metrics_json()
		frame.operation_recovery = bridge_recovery_status_json()
		frame.http_retries = bridge_http_retry_metrics_json()
	}
	defer if !shape.omit_diagnostics {
		delete(frame.stats)
		delete(frame.command_dispatch)
		delete(frame.dependency_breakers)
		delete(frame.operation_recovery)
		delete(frame.http_retries)
	}
	// REQ-BVS-1: read the vault tri-state BEFORE taking bridge_runtime_mutex.
	// bridge_vault_status() touches the kernel keyring and the filesystem, and no
	// blocking I/O belongs inside a lock the per-instance reporters also contend on.
	frame.vault_status = bridge_hub_vault_status_for_report()
	frame.search_ready, frame.search_stale, frame.search_revision = bridge_task_chain_search_status()
	now := bridge_runtime_now_ms()
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	bridge_runtime_expire_stale_locked(now)
	instances := make([dynamic]Bridge_Heartbeat_Instance, 0, len(bridge_runtime_instances), context.temp_allocator)
	for inst in bridge_runtime_instances {
		epoch := bridge_agent_instance_launch_epoch(inst.agent_instance_id)
		append(&instances, Bridge_Heartbeat_Instance{
			agent_instance_id = inst.agent_instance_id,
			launch_epoch      = strings.clone(epoch, context.temp_allocator),
			state_seq         = inst.state_seq,
			runtime_status    = inst.runtime_status,
			activity_status   = inst.activity_status,
		})
		delete(epoch)
	}
	frame.instances = instances[:]
	return bridge_heartbeat_frame_json(frame, shape)
}

// Bridge_Heartbeat_Instance is the five-member repair tuple of heartbeat instances[].
Bridge_Heartbeat_Instance :: struct {
	agent_instance_id: string,
	launch_epoch:      string,
	state_seq:         int,
	runtime_status:    string,
	activity_status:   string,
}

// Bridge_Heartbeat_Frame is everything one heartbeat may carry. features and the
// diagnostic members are pre-serialized JSON, written only when the shape keeps them.
Bridge_Heartbeat_Frame :: struct {
	vault_status:        string,
	search_ready:        bool,
	search_stale:        bool,
	search_revision:     i64,
	features:            string,
	command_dispatch:    string,
	dependency_breakers: string,
	http_retries:        string,
	operation_recovery:  string,
	stats:               string, // "" when resource stats are off: member omitted
	instances:           []Bridge_Heartbeat_Instance,
}

// bridge_heartbeat_frame_json serializes one heartbeat. Always present, in this
// order: type, protocol_version (the legacy per-frame envelope constant 1, unrelated
// to hello's negotiated version), vault_status, the task_chain_search tuple,
// active_instance_ids and instances, both arrays even when empty. shape.omit_metadata
// drops only capabilities/features; shape.omit_diagnostics drops only
// command_dispatch, dependency_breakers, http_retries, operation_recovery and stats.
//
// active_instance_ids lists the instances with an active runtime status; instances[]
// lists every instance with a status, terminal ones included, so a dropped terminal
// status push is repaired. Each entry is the five-member tuple the hub decodes: the
// ignored activity_source and error members are not sent here (decision D3-a); the
// immediate agent_instance_status push (bridge_instance_status_json) still carries
// both.
bridge_heartbeat_frame_json :: proc(frame: Bridge_Heartbeat_Frame, shape: Bridge_Heartbeat_Shape) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"bridge_heartbeat\",\"protocol_version\":1,\"vault_status\":\"")
	bridge_runtime_write_json_string(&b, frame.vault_status)
	strings.write_string(&b, `","task_chain_search_ready":`); strings.write_string(&b, "true" if frame.search_ready else "false")
	strings.write_string(&b, `,"task_chain_search_stale":`); strings.write_string(&b, "true" if frame.search_stale else "false")
	strings.write_string(&b, `,"task_chain_search_revision":`); strings.write_string(&b, fmt.tprintf("%d", frame.search_revision))
	if !shape.omit_metadata {
		strings.write_string(&b, `,"capabilities":[],"features":`)
		strings.write_string(&b, frame.features)
	}
	if !shape.omit_diagnostics {
		strings.write_string(&b, `,"command_dispatch":`)
		strings.write_string(&b, frame.command_dispatch)
		strings.write_string(&b, `,"dependency_breakers":`)
		strings.write_string(&b, frame.dependency_breakers)
		strings.write_string(&b, `,"http_retries":`)
		strings.write_string(&b, frame.http_retries)
		strings.write_string(&b, `,"operation_recovery":`)
		strings.write_string(&b, frame.operation_recovery)
		if frame.stats != "" {
			strings.write_string(&b, `,"stats":`)
			strings.write_string(&b, frame.stats)
		}
	}
	strings.write_string(&b, `,"active_instance_ids":[`)
	first_active := true
	for inst in frame.instances {
		if !bridge_runtime_status_active(inst.runtime_status) do continue
		if !first_active do strings.write_byte(&b, ',')
		first_active = false
		strings.write_byte(&b, '"')
		bridge_runtime_write_json_string(&b, inst.agent_instance_id)
		strings.write_byte(&b, '"')
	}
	strings.write_string(&b, `],"instances":[`)
	first := true
	for inst in frame.instances {
		if strings.trim_space(inst.runtime_status) == "" do continue
		if !first do strings.write_byte(&b, ',')
		first = false
		strings.write_string(&b, `{"agent_instance_id":"`)
		bridge_runtime_write_json_string(&b, inst.agent_instance_id)
		strings.write_string(&b, `","launch_epoch":"`)
		bridge_runtime_write_json_string(&b, inst.launch_epoch)
		strings.write_string(&b, `","state_seq":`)
		strings.write_string(&b, fmt.tprintf("%d", inst.state_seq))
		strings.write_string(&b, `,"runtime_status":"`)
		bridge_runtime_write_json_string(&b, inst.runtime_status)
		strings.write_string(&b, `","activity_status":"`)
		bridge_runtime_write_json_string(&b, inst.activity_status)
		strings.write_string(&b, `"}`)
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

bridge_runtime_expire_stale_locked :: proc(now: i64) {
	for i in 0..<len(bridge_runtime_instances) {
		inst := &bridge_runtime_instances[i]
		if !bridge_runtime_status_active(inst.runtime_status) do continue
		if inst.last_seen_unix_ms > 0 && now - inst.last_seen_unix_ms > BRIDGE_WRAPPER_STALE_MS {
			if inst.pty_process_alive {
				inst.last_seen_unix_ms = now
				continue
			}
			inst.state_seq = bridge_runtime_next_state_seq(inst.state_seq, now)
			inst.runtime_status = "unreachable"
			inst.activity_status = "idle"
			inst.activity_source = "bridge"
			inst.activity_updated_unix_ms = now
			inst.start_deadline_unix_ms = 0
			continue
		}
		if inst.runtime_status == "starting" && !inst.start_success_seen && inst.start_deadline_unix_ms > 0 && now >= inst.start_deadline_unix_ms {
			inst.state_seq = bridge_runtime_next_state_seq(inst.state_seq, now)
			inst.runtime_status = "failed"
			inst.last_error = bridge_error(.agent_launch_failed, .timeout)
			inst.has_last_error = true
			inst.activity_status = "idle"
			inst.activity_source = "bridge"
			inst.activity_updated_unix_ms = now
			inst.start_deadline_unix_ms = 0
		}
	}
}

bridge_runtime_status_active :: proc(runtime_status: string) -> bool {
	// "blocked" is active-but-not-ready: the wrapper is alive and still pinging, so
	// the instance must stay in the heartbeat digest and must NOT be reconciled to
	// unreachable, but it is not "ready" (that requires start-success -> "running").
	return runtime_status == "launching" || runtime_status == "starting" || runtime_status == "running" || runtime_status == "idle" || runtime_status == "busy" || runtime_status == "stopping" || runtime_status == "blocked"
}

bridge_runtime_active_agent_count :: proc() -> int {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	count := 0
	for inst in bridge_runtime_instances {
		if bridge_runtime_status_active(inst.runtime_status) {
			count += 1
		}
	}
	return count
}

bridge_runtime_cached_command :: proc(command_id: string) -> (string, bool) {
	if command_id == "" do return "", false
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for result in bridge_runtime_results { if result.command_id == command_id do return result.result_json, true }
	return "", false
}

BRIDGE_RUNTIME_RESULT_LIMIT :: 256

bridge_runtime_cache_command :: proc(command_id, result_json: string) {
	if command_id == "" do return
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	alloc := runtime.default_allocator()
	if bridge_runtime_results.allocator.procedure == nil {
		bridge_runtime_results = make([dynamic]Bridge_Runtime_Command_Result, alloc)
	}
	for i in 0..<len(bridge_runtime_results) {
		if bridge_runtime_results[i].command_id == command_id {
			delete(bridge_runtime_results[i].result_json, alloc)
			bridge_runtime_results[i].result_json = strings.clone(result_json, alloc)
			return
		}
	}
	if len(bridge_runtime_results) >= BRIDGE_RUNTIME_RESULT_LIMIT {
		delete(bridge_runtime_results[0].command_id, alloc)
		delete(bridge_runtime_results[0].result_json, alloc)
		ordered_remove(&bridge_runtime_results, 0)
	}
	append(&bridge_runtime_results, Bridge_Runtime_Command_Result{
		command_id = strings.clone(command_id, alloc),
		result_json = strings.clone(result_json, alloc),
	})
}

bridge_pane_capture_register_pending :: proc(pending: Bridge_Pane_Capture_Pending) {
	if pending.command_id == "" && pending.pane_capture_request_id == "" do return
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_pane_capture_pending) { if bridge_pane_capture_pending[i].command_id == pending.command_id || bridge_pane_capture_pending[i].pane_capture_request_id == pending.pane_capture_request_id { bridge_pane_capture_pending[i] = pending; return } }
	append(&bridge_pane_capture_pending, pending)
}

bridge_pane_capture_remove_pending :: proc(command_id, request_id: string) -> (Bridge_Pane_Capture_Pending, bool) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for i in 0..<len(bridge_pane_capture_pending) {
		if (command_id != "" && bridge_pane_capture_pending[i].command_id == command_id) || (request_id != "" && bridge_pane_capture_pending[i].pane_capture_request_id == request_id) {
			pending := bridge_pane_capture_pending[i]
			unordered_remove(&bridge_pane_capture_pending, i)
			return pending, true
		}
	}
	return {}, false
}

bridge_pane_capture_enqueue_result :: proc(result_json, command_id: string) {
	if strings.trim_space(result_json) == "" do return
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	append(&bridge_pane_capture_outgoing, Bridge_Pane_Capture_Outgoing{command_id=strings.clone(command_id),result_json=strings.clone(result_json)})
}

bridge_shell_output_enqueue_result :: proc(result_json, command_id: string) {
	if strings.trim_space(result_json) == "" do return
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	append(&bridge_shell_output_outgoing, Bridge_Shell_Output_Outgoing{command_id=strings.clone(command_id),result_json=strings.clone(result_json)})
}

bridge_shell_output_drain_outgoing :: proc(conn: ^ws.Connection) {
	for {
		item: Bridge_Shell_Output_Outgoing
		have := false
		sync.mutex_lock(&bridge_runtime_mutex)
		if len(bridge_shell_output_outgoing) > 0 { item = bridge_shell_output_outgoing[0]; ordered_remove(&bridge_shell_output_outgoing, 0); have = true }
		sync.mutex_unlock(&bridge_runtime_mutex)
		if !have do return
		if !bridge_hub_send(conn, item.result_json) {
			sync.mutex_lock(&bridge_runtime_mutex)
			inject_at(&bridge_shell_output_outgoing, 0, item)
			sync.mutex_unlock(&bridge_runtime_mutex)
			conn.connected = false
			return
		}
	}
}

bridge_hub_handle_get_shell_output :: proc(conn: ^ws.Connection, text: string) {
	command_id := extract_json_string(text, "command_id", "")
	exec_id := extract_json_string(text, "exec_id", "")
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"command_result\",\"command_id\":\"")
	bridge_runtime_write_json_string(&b, command_id)
	strings.write_byte(&b, '"')
	if command_id == "" || exec_id == "" {
		strings.write_string(&b, ",")
		bridge_write_failure(&b, bridge_cause_wire_error("missing_fields", "command_id and exec_id are required"))
		strings.write_byte(&b, '}')
		bridge_shell_output_enqueue_result(strings.to_string(b), command_id)
		return
	}
	strings.write_string(&b, ",\"exec_id\":\"")
	bridge_runtime_write_json_string(&b, exec_id)
	strings.write_byte(&b, '"')
	output_str, out_state := bridge_shell_output_read(exec_id)
	defer if out_state == .Available do delete(output_str)
	if out_state == .Reclaimed {
		// Explicit refusal rather than an empty log (REQ-SHELL-8 AC3). The hub maps
		// this code to domain .Gone, which is distinct both from an offline bridge
		// (no reply at all -> .Bridge_Offline) and from a successful empty log.
		strings.write_string(&b, ",")
		bridge_write_failure(&b, bridge_cause_wire_error(BRIDGE_SHELL_OUTPUT_RECLAIMED_CODE, BRIDGE_SHELL_OUTPUT_RECLAIMED_MESSAGE))
		strings.write_byte(&b, '}')
		bridge_shell_output_enqueue_result(strings.to_string(b), command_id)
		return
	}
	tail, truncated := bridge_shell_tail(output_str, BRIDGE_SHELL_TAIL_THRESHOLD, BRIDGE_SHELL_TAIL_KEEP)
	strings.write_string(&b, ",\"ok\":true,\"output\":\"")
	bridge_runtime_write_json_string(&b, tail)
	strings.write_string(&b, "\",\"truncated\":")
	strings.write_string(&b, "true" if truncated else "false")
	strings.write_byte(&b, '}')
	bridge_shell_output_enqueue_result(strings.to_string(b), command_id)
}

// bridge_runtime_enqueue_status_push_locked records that instance_id's runtime
// status changed and should be pushed to the hub immediately. MUST be called with
// bridge_runtime_mutex held. Deduplicates so a burst of transitions on one
// instance collapses to a single pending push (the drain re-reads current status).
bridge_runtime_enqueue_status_push_locked :: proc(instance_id: string) {
	if strings.trim_space(instance_id) == "" do return
	if bridge_runtime_status_outgoing == nil do bridge_runtime_status_outgoing = make([dynamic]string)
	for id in bridge_runtime_status_outgoing do if id == instance_id do return
	append(&bridge_runtime_status_outgoing, strings.clone(instance_id, runtime.default_allocator()))
}

// bridge_runtime_drain_status_pushes flushes queued immediate status pushes to the
// hub. Called every hub-loop tick (alongside the pane-capture drain). Each entry
// is serialized from CURRENT state via bridge_instance_status_json, so a value
// queued slightly stale still sends the latest status. On send failure the id is
// requeued and the connection is dropped so the reconnect path re-syncs.
bridge_runtime_drain_status_pushes :: proc(conn: ^ws.Connection) {
	for {
		id := ""
		sync.mutex_lock(&bridge_runtime_mutex)
		if len(bridge_runtime_status_outgoing) > 0 { id = bridge_runtime_status_outgoing[0]; ordered_remove(&bridge_runtime_status_outgoing, 0) }
		sync.mutex_unlock(&bridge_runtime_mutex)
		if id == "" do return
		if inst, exists := bridge_runtime_instance_snapshot(id); exists {
			if inst.runtime_status == "stopped" || inst.runtime_status == "failed" || inst.runtime_status == "unreachable" do bridge_tool_live_clear(id)
		}
		payload := bridge_instance_status_json(id)
		defer delete(payload)
		if payload == "" || payload == "{}" { delete(id, runtime.default_allocator()); continue }
		if !bridge_hub_send(conn, payload) {
			sync.mutex_lock(&bridge_runtime_mutex)
			inject_at(&bridge_runtime_status_outgoing, 0, id)
			sync.mutex_unlock(&bridge_runtime_mutex)
			conn.connected = false
			return
		}
		delete(id, runtime.default_allocator())
	}
}

bridge_pane_capture_drain_outgoing :: proc(conn: ^ws.Connection) {
	for {
		item: Bridge_Pane_Capture_Outgoing
		have := false
		sync.mutex_lock(&bridge_runtime_mutex)
		if len(bridge_pane_capture_outgoing) > 0 { item = bridge_pane_capture_outgoing[0]; ordered_remove(&bridge_pane_capture_outgoing, 0); have = true }
		sync.mutex_unlock(&bridge_runtime_mutex)
		if !have do return
		if !bridge_hub_send(conn, item.result_json) {
			sync.mutex_lock(&bridge_runtime_mutex)
			append(&bridge_pane_capture_outgoing, item)
			sync.mutex_unlock(&bridge_runtime_mutex)
			conn.connected = false
			return
		}
		if item.command_id != "" do bridge_runtime_cache_command(item.command_id, bridge_command_result_payload_json(item.command_id,"succeeded","{}"))
	}
}

bridge_pane_capture_expire_pending :: proc() {
	now := bridge_runtime_now_ms()
	expired := make([dynamic]Bridge_Pane_Capture_Pending)
	sync.mutex_lock(&bridge_runtime_mutex)
	for i:=0; i<len(bridge_pane_capture_pending); {
		if bridge_pane_capture_pending[i].deadline_unix_ms > 0 && now >= bridge_pane_capture_pending[i].deadline_unix_ms { append(&expired, bridge_pane_capture_pending[i]); unordered_remove(&bridge_pane_capture_pending, i); continue }
		i += 1
	}
	sync.mutex_unlock(&bridge_runtime_mutex)
	for pending in expired { bridge_pane_capture_enqueue_result(bridge_pane_capture_result_wire_json(pending,false,"capture_timeout","The pane capture request timed out.","",0,false), pending.command_id) }
}

Bridge_Pane_Capture_Push :: struct {
	push:    string,
	payload: struct {
		protocol_version:        int,
		command_id:              string,
		pane_capture_request_id: string,
		message_id:              string,
		width:                   int,
		settle_ms:               int,
		line_limit:              int,
	},
}

// bridge_pane_capture_push_json is the pane_capture_request push (newline-terminated).
bridge_pane_capture_push_json :: proc(pending: Bridge_Pane_Capture_Pending, settle_ms: int) -> string {
	push: Bridge_Pane_Capture_Push
	push.push = "pane_capture_request"
	push.payload = {protocol_version = 1, command_id = pending.command_id, pane_capture_request_id = pending.pane_capture_request_id, message_id = pending.message_id, width = pending.width, settle_ms = settle_ms, line_limit = pending.line_limit}
	body, _ := vault.wire_encode(push, context.temp_allocator)
	return strings.concatenate({body, "\n"})
}

// bridge_pane_capture_result_json is the pane_capture_result every capture path sends.
// A successful capture is sealed when the vault is configured
// (bridge_pane_capture_seal_with): a locked vault answers vault_locked and a sealing
// failure encryption_failed -- never the plaintext screen.
bridge_pane_capture_result_json :: proc(pending: Bridge_Pane_Capture_Pending, ok:bool, error_code,message,output:string,line_count:int,truncated:bool)->string{
	if !ok do return bridge_pane_capture_result_wire_json(pending, false, error_code, message, "", line_count, truncated)
	status, kr := bridge_vault_status_and_key()
	defer vault.keyring_wipe(&kr)
	return bridge_pane_capture_result_sealed_json(pending, status, &kr, output, line_count, truncated, bridge_pty_random_source)
}

// bridge_pane_capture_result_sealed_json is the testable core: vault state, keyring
// and randomness are passed in.
bridge_pane_capture_result_sealed_json :: proc(pending: Bridge_Pane_Capture_Pending, status: Vault_Status, kr: ^vault.Vault_Keyring, output: string, line_count: int, truncated: bool, random_source: string) -> string {
	sealed, res, cut := bridge_pane_capture_seal_with(status, kr, output, random_source)
	defer if sealed != "" do delete(sealed)
	switch res {
	case .Locked:
		return bridge_pane_capture_result_wire_json(pending, false, "vault_locked", "the bridge vault is locked", "", 0, false)
	case .Failed:
		return bridge_pane_capture_result_wire_json(pending, false, "encryption_failed", "the pane capture could not be encrypted", "", 0, false)
	case .Sealed:
	}
	return bridge_pane_capture_result_wire_json(pending, true, "", "", sealed, line_count, truncated || cut)
}

// Bridge_Pane_Capture_Result_Wire is the pane_capture_result frame: ok and output only
// on success, the typed error only on failure.
Bridge_Pane_Capture_Result_Wire :: struct {
	type:                    string,
	protocol_version:        int,
	command_id:              string,
	pane_capture_request_id: string,
	conversation_id:         string,
	message_id:              string,
	agent_instance_id:       string,
	ok:                      bool,
	width:                   int,
	line_count:              int,
	truncated:               bool,
	output:                  Maybe(string) `json:"output,omitempty"`,
	error:                   Maybe(contracts.Wire_Error_Json) `json:"error,omitempty"`,
}

bridge_pane_capture_result_wire_json :: proc(pending: Bridge_Pane_Capture_Pending, ok: bool, error_code, message, output: string, line_count: int, truncated: bool) -> string {
	res := Bridge_Pane_Capture_Result_Wire{
		type = "pane_capture_result", protocol_version = 1, command_id = pending.command_id,
		pane_capture_request_id = pending.pane_capture_request_id, conversation_id = pending.conversation_id,
		message_id = pending.message_id, agent_instance_id = pending.agent_instance_id,
		ok = ok, width = pending.width, line_count = line_count, truncated = truncated,
	}
	if ok do res.output = output
	else do res.error = contracts.wire_error_json_value(bridge_cause_wire_error(error_code, message))
	out, _ := vault.wire_encode(res)
	return out
}


// bridge_get_pane_reply_json is the get_agent_pane / shell_get_pane reply with the
// capture sealed for the viewer (bridge_pane_output_seal) whenever the vault is
// configured. session_id is the id the viewer decrypts under (the shell session id or
// agent instance id the hub asked for). A locked vault or a sealing failure answers
// with an error and never with the plaintext capture.
bridge_get_pane_reply_json :: proc(command_id, session_id: string, ok: bool, unchanged: bool, hash_val: string, output: string, line_count: int, truncated: bool, cursor_row: int = 0, cursor_col: int = 0, err_msg: string = "") -> string {
	if !ok do return bridge_get_agent_pane_result_json(command_id, false, false, "", "", 0, false, 0, 0, err_msg)
	sealed, res := bridge_pane_output_seal("" if unchanged else output, session_id)
	defer if sealed != "" do delete(sealed)
	return bridge_pane_reply_from_seal(command_id, unchanged, hash_val, sealed, res, line_count, truncated, cursor_row, cursor_col)
}

// bridge_pane_reply_from_seal renders the pane reply for an already sealed capture.
bridge_pane_reply_from_seal :: proc(command_id: string, unchanged: bool, hash_val: string, sealed: string, res: Bridge_Pane_Seal, line_count: int, truncated: bool, cursor_row: int = 0, cursor_col: int = 0) -> string {
	switch res {
	case .Locked:
		return bridge_get_agent_pane_result_json(command_id, false, false, "", "", 0, false, 0, 0, "the bridge vault is locked", "vault_locked")
	case .Failed:
		return bridge_get_agent_pane_result_json(command_id, false, false, "", "", 0, false, 0, 0, "the pane capture could not be encrypted", "encryption_failed")
	case .Sealed:
	}
	return bridge_get_agent_pane_result_json(command_id, true, unchanged, hash_val, sealed, line_count, truncated, cursor_row, cursor_col)
}

// Bridge_Pane_Result_Wire is the get_agent_pane / shell_get_pane command_result. hash
// only on success; the capture members only when it changed; error only on failure.
Bridge_Pane_Result_Wire :: struct {
	type:             string,
	protocol_version: int,
	command_id:       string,
	ok:               bool,
	unchanged:        bool,
	hash:             Maybe(string) `json:"hash,omitempty"`,
	output:           Maybe(string) `json:"output,omitempty"`,
	line_count:       Maybe(int)    `json:"line_count,omitempty"`,
	truncated:        Maybe(bool)   `json:"truncated,omitempty"`,
	cursor_row:       Maybe(int)    `json:"cursor_row,omitempty"`,
	cursor_col:       Maybe(int)    `json:"cursor_col,omitempty"`,
	error:            Maybe(contracts.Wire_Error_Json) `json:"error,omitempty"`,
}

bridge_get_agent_pane_result_json :: proc(command_id: string, ok: bool, unchanged: bool, hash_val: string, output: string, line_count: int, truncated: bool, cursor_row: int = 0, cursor_col: int = 0, err_msg: string = "", err_cause: string = "") -> string {
	res := Bridge_Pane_Result_Wire{type = "command_result", protocol_version = 1, command_id = command_id, ok = ok}
	if ok {
		res.unchanged = unchanged
		res.hash = hash_val
		if !unchanged {
			res.output = output
			res.line_count = line_count
			res.truncated = truncated
			res.cursor_row = cursor_row
			res.cursor_col = cursor_col
		}
	} else {
		res.error = contracts.wire_error_json_value(bridge_cause_wire_error(err_cause if err_cause != "" else "capture_failed", err_msg))
	}
	out, _ := vault.wire_encode(res)
	return out
}

// bridge_command_result_json is a non-failed command_result (accepted / succeeded);
// failures go through bridge_command_failed_json so they always carry a typed error.
Bridge_Command_Runtime_Status :: struct {
	runtime_status: string,
}

// Bridge_Command_Result_Wire is a command_result frame: ok:true with payload.status,
// or ok:false with the typed wire error and payload.status "failed".
Bridge_Command_Result_Wire :: struct {
	type:             string,
	protocol_version: int,
	command_id:       string,
	ok:               bool,
	error:            Maybe(contracts.Wire_Error_Json) `json:"error,omitempty"`,
	payload:          struct {
		status: string,
		result: Maybe(Bridge_Command_Runtime_Status) `json:"result,omitempty"`,
	},
}

@(private = "file")
bridge_command_result_wire :: proc(command_id, status, runtime_status: string) -> Bridge_Command_Result_Wire {
	res := Bridge_Command_Result_Wire{type = "command_result", protocol_version = 1, command_id = command_id}
	res.payload.status = status
	if runtime_status != "" do res.payload.result = Bridge_Command_Runtime_Status{runtime_status = runtime_status}
	return res
}

bridge_command_result_json :: proc(command_id, status, runtime_status: string) -> string {
	assert(status != "failed", "use bridge_command_failed_json for failures")
	res := bridge_command_result_wire(command_id, status, runtime_status)
	res.ok = true
	out, _ := vault.wire_encode(res)
	return out
}

// bridge_command_failed_json is a FAILED command_result (REQ-ERR-PROTO-A): top-level
// "ok":false plus the typed wire error, so the hub acts on code/class and never on
// text. payload.status stays "failed" for the hub's terminal-state check; a
// runtime_status (launch/stop) rides in payload.result as on success. Caller owns
// the result.
bridge_command_failed_json :: proc(command_id: string, err: contracts.Wire_Error, runtime_status := "") -> string {
	res := bridge_command_result_wire(command_id, "failed", runtime_status)
	res.error = contracts.wire_error_json_value(err)
	out, _ := vault.wire_encode(res)
	return out
}

// bridge_pty_vault_locked_frame_json is the typed in-stream signal (T10, REQ-T10-3) that
// a pane's input or output was refused because this bridge's vault is locked. The hub
// relays it to the pane's viewers as an `error` frame with code `vault_locked`, so the
// UI never has to parse the human-readable banner. Caller owns the result.
Bridge_Pty_Vault_Locked_Frame :: struct {
	type:       string,
	session_id: string,
	error:      contracts.Wire_Error_Json,
}

bridge_pty_vault_locked_frame_json :: proc(session_id: string, allocator := context.allocator) -> string {
	out, _ := vault.wire_encode(Bridge_Pty_Vault_Locked_Frame{
		type = "shell_pty_vault_locked", session_id = session_id,
		error = contracts.wire_error_json_value(bridge_cause_wire_error("vault_locked", "this bridge's vault is locked")),
	}, allocator)
	return out
}

// ---- typed decode of the pty / pane commands ---------------------------------

// Bridge_Pty_Command_Fields are the members the pty input/resize, stream
// attach/detach and pane commands read. The hub may put them at the top level or
// under "payload" (bridge_pty_command_decode merges, top level first). Dimensions
// are json.Value because older hubs send them as decimal strings.
Bridge_Pty_Command_Fields :: struct {
	command_id:        string,
	session_id:        string,
	shell_id:          string,
	agent_instance_id: string,
	data_b64:          string,
	is_encrypted:      Maybe(bool),
	since_hash:        string,
	rows:              json.Value,
	cols:              json.Value,
	width:             json.Value,
	line_limit:        json.Value,
}

// bridge_pty_command_decode decodes a pty/pane command (temp-allocated). A command
// that does not decode yields empty fields, which every caller refuses.
bridge_pty_command_decode :: proc(text: string) -> Bridge_Pty_Command_Fields {
	top: Bridge_Pty_Command_Fields
	_ = vault.wire_decode(text, &top)
	wrapped: struct {
		payload: Bridge_Pty_Command_Fields,
	}
	if !vault.wire_decode(text, &wrapped) do return top
	p := wrapped.payload
	pick :: proc(a, b: string) -> string { return a if a != "" else b }
	pick_num :: proc(a, b: json.Value) -> json.Value { return a if bridge_json_int(a, 0) > 0 else b }
	top.command_id = pick(top.command_id, p.command_id)
	top.session_id = pick(top.session_id, p.session_id)
	top.shell_id = pick(top.shell_id, p.shell_id)
	top.agent_instance_id = pick(top.agent_instance_id, p.agent_instance_id)
	top.data_b64 = pick(top.data_b64, p.data_b64)
	top.since_hash = pick(top.since_hash, p.since_hash)
	if _, has := top.is_encrypted.?; !has do top.is_encrypted = p.is_encrypted
	top.rows = pick_num(top.rows, p.rows)
	top.cols = pick_num(top.cols, p.cols)
	top.width = pick_num(top.width, p.width)
	top.line_limit = pick_num(top.line_limit, p.line_limit)
	return top
}

// bridge_json_int reads an integer member given as a JSON number or a decimal
// string; anything else is fallback.
bridge_json_int :: proc(v: json.Value, fallback: int) -> int {
	#partial switch n in v {
	case json.Integer:
		return int(n)
	case json.Float:
		return int(n)
	case json.String:
		if parsed, ok := strconv.parse_int(string(n)); ok do return parsed
	}
	return fallback
}

// bridge_json_positive_int is bridge_json_int with any value <= 0 as fallback.
bridge_json_positive_int :: proc(v: json.Value, fallback: int) -> int {
	n := bridge_json_int(v, fallback)
	return n if n > 0 else fallback
}

// bridge_pty_dimension is a terminal row/column count: 1..65535, else 0 (unchanged).
bridge_pty_dimension :: proc(v: json.Value) -> u16 {
	n := bridge_json_int(v, 0)
	if n > 0 && n <= 65535 do return u16(n)
	return 0
}

// bridge_pty_input_reply_vault_locked answers a keystroke refused by a Locked vault:
// the command_result carries error_code `vault_locked` (cached like any result, so a
// retried command_id gets the same answer) and the pane gets the typed stream frame.
bridge_pty_input_reply_vault_locked :: proc(conn: ^ws.Connection, command_id, session_id: string) {
	if command_id != "" {
		result := bridge_command_failed_json(command_id, bridge_cause_wire_error("vault_locked", "this bridge's vault is locked"))
		defer delete(result)
		bridge_runtime_cache_command(command_id, result)
		if conn != nil do _ = bridge_hub_send(conn, result)
	}
	if session_id != "" && conn != nil {
		frame := bridge_pty_vault_locked_frame_json(session_id)
		defer delete(frame)
		_ = bridge_hub_send(conn, frame)
	}
}

bridge_command_result_payload_json :: proc(command_id, status, result_json: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"command_result\",\"protocol_version\":1,\"command_id\":\"")
	bridge_runtime_write_json_string(&b, command_id)
	strings.write_string(&b, "\",\"ok\":true,\"payload\":{\"status\":\"")
	bridge_runtime_write_json_string(&b, status)
	strings.write_string(&b, "\",\"result\":")
	if strings.trim_space(result_json) == "" { strings.write_string(&b, "{}") } else { strings.write_string(&b, result_json) }
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

bridge_providers_report_json :: proc(command_id, payload_json: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"providers_report\",\"protocol_version\":1,\"command_id\":\"")
	bridge_runtime_write_json_string(&b, command_id)
	strings.write_string(&b, "\",\"payload\":")
	if strings.trim_space(payload_json) == "" { strings.write_string(&b, "{}") } else { strings.write_string(&b, payload_json) }
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

bridge_provider_payload_object :: proc(text: string) -> string {
	if payload, ok := bridge_provider_json_extract_object(text, "payload"); ok do return payload
	return "{}"
}

bridge_runtime_json_escaped :: proc(value: string) -> string {
	b := strings.builder_make()
	bridge_runtime_write_json_string(&b, value)
	return strings.to_string(b)
}

bridge_os_string :: proc() -> string {
	when ODIN_OS == .Linux {
		return "linux"
	} else when ODIN_OS == .Darwin {
		return "darwin"
	} else when ODIN_OS == .Windows {
		return "windows"
	} else {
		return "unknown"
	}
}

bridge_arch_string :: proc() -> string {
	when ODIN_ARCH == .amd64 {
		return "amd64"
	} else when ODIN_ARCH == .arm64 {
		return "arm64"
	} else {
		return "unknown"
	}
}

// bridge_target_string is the release target this bridge reports to the Hub
// and updates from (REQ-T13-1): the compile-time HAM_RELEASE_TARGET (the
// termux-arm64 bundle), else <os>-<arch>. A linux-* build running under Termux
// reports termux-<arch> so the Hub never resolves the glibc bundle for it.
bridge_target_string :: proc() -> string {
	target, _ := bridge_release_target()
	return target
}

// bridge_release_target also reports whether self-update must be refused
// because this binary was not built for the platform it runs on.
bridge_release_target :: proc() -> (target: string, update_blocked: bool) {
	native := fmt.tprintf("%s-%s", bridge_os_string(), bridge_arch_string())
	return contracts.release_target_resolve(contracts.RELEASE_TARGET, native, keystore_android_selected())
}

// Bridge_Hello_Wire is the bridge_hello frame (typed; json.marshal).
// protocol_version is the bridge-ws frame version (contracts.BRIDGE_WS_FRAME_VERSION);
// the hub refuses a mismatch at hello, which is how a wire-format change fails loudly.
Bridge_Hello_Wire :: struct {
	type:                     string,
	protocol_version:         int,
	version:                  string,
	commit_sha:               string,
	built_at:                 string,
	target:                   string,
	bootstrap_fragment_cache: bool,
	// REQ-IMPL-4: the REAL hostname, not bridge_config.daemon_id.
	//
	// WHY THIS IS NOT COSMETIC. The hub treats this field as the machine's hostname:
	// bridge_runtime_connect assigns it to `machine_hostname` and, when the label is
	// not user-customized, to `label` as well. Sending daemon_id therefore OVERWROTE
	// the real hostname captured at enrollment with the bridge's own `brg_` id --
	// and daemon_id is set to exactly that id when the hub's ready frame arrives, so
	// every bridge renamed itself after its own identifier within seconds of
	// starting. An unresolvable hostname sends "", which the hub's
	// `if hostname != ""` guard leaves alone.
	hostname:                 string,
	public_key:               string,
	// Unseal v2: the boot id, the identity-signed ephemeral key and the identity key.
	// Omitted (so no browser will unseal) when the key cannot be signed.
	using _:                  Bridge_Unseal_Hello_Fields,
	capabilities:             []string,
	features:                 []string,
	active_instance_ids:      []string,
}

// BRIDGE_RUNTIME_FEATURES is the single source for the features bridge_hello and the
// legacy (non-omitting) bridge_heartbeat advertise; the hub replaces its stored list
// on every hello and on every legacy beat that carries features.
// heartbeat_metadata_omission tells the hub this Bridge understands the bridge_ready
// flag of the same name (contracts.BRIDGE_FEATURE_HEARTBEAT_METADATA_OMISSION).
BRIDGE_RUNTIME_FEATURES := [?]string{"capture_agent_pane", "get_agent_pane", "instance_reconfiguration_v1", "tool_stream_demand_v2", "mcp_transform_v1", contracts.BRIDGE_FEATURE_HEARTBEAT_METADATA_OMISSION}

bridge_hub_hello_json :: proc() -> string {
	hello := Bridge_Hello_Wire{
		type = "bridge_hello",
		protocol_version = contracts.BRIDGE_WS_FRAME_VERSION,
		version = contracts.APP_VERSION,
		commit_sha = contracts.GIT_COMMIT,
		built_at = contracts.BUILD_TIMESTAMP,
		target = bridge_target_string(),
		bootstrap_fragment_cache = true,
		hostname = bridge_hello_hostname(),
		public_key = bridge_get_public_key_hex(),
		capabilities = []string{},
		features = BRIDGE_RUNTIME_FEATURES[:],
	}
	unseal := bridge_unseal_hello_fields(bridge_config.daemon_id)
	hello.identity_state = unseal.identity_state
	hello.unseal_boot_id = unseal.unseal_boot_id
	hello.unseal_key_signature = unseal.unseal_key_signature
	hello.identity_public_key = unseal.identity_public_key
	hello.identity_sign_alg = unseal.identity_sign_alg
	ids := make([dynamic]string, context.temp_allocator)
	sync.mutex_lock(&bridge_runtime_mutex)
	for launch in bridge_runtime_launches do append(&ids, strings.clone(launch.agent_instance_id, context.temp_allocator))
	sync.mutex_unlock(&bridge_runtime_mutex)
	hello.active_instance_ids = ids[:]
	out, _ := vault.wire_encode(hello)
	return out
}

// bridge_runtime_features_json serializes BRIDGE_RUNTIME_FEATURES for the legacy
// hand-built heartbeat. The hub stores the features of every hello AND heartbeat
// frame, so a heartbeat that advertised a different list than the hello silently
// withdrew whatever it omitted (tool_stream_demand_v2 was lost ~45s after connect).
bridge_runtime_features_json :: proc(allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '[')
	for feature, i in BRIDGE_RUNTIME_FEATURES {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_byte(&b, '"')
		bridge_runtime_write_json_string(&b, feature)
		strings.write_byte(&b, '"')
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

bridge_runtime_write_json_string :: proc(b: ^strings.Builder, value: string) {
	logged_ctrl := false
	for ch in value {
		switch ch {
		case '\\': strings.write_string(b, "\\\\")
		case '"': strings.write_string(b, "\\\"")
		case '\n': strings.write_string(b, "\\n")
		case '\r': strings.write_string(b, "\\r")
		case '\t': strings.write_string(b, "\\t")
		case:
			if ch < 32 {
				if !logged_ctrl {
					fmt.eprintln("bridge_runtime_write_json_string: escaping control char(s); first=", fmt.tprintf("\\u%04x", u32(ch)), "in payload len=", len(value))
					logged_ctrl = true
				}
				strings.write_string(b, fmt.tprintf("\\u%04x", u32(ch)))
			} else {
				strings.write_rune(b, ch)
			}
		}
	}
}

// ---- shell_exited outgoing event queue ------------------------------------

// bridge_shell_exited_enqueue queues an exit for the hub and, in the same call,
// writes it to the durable outbox (REQ-SHELL-4). Persisting BEFORE the in-memory
// append means a crash anywhere after this point still replays the exit: the window
// in which an exit exists only in RAM is now the window inside this proc, not the
// whole time the bridge is disconnected.
//
// A failed write is not fatal — the exit is still queued in memory and will be
// delivered normally if the process lives long enough. bridge_shell_exited_outbox_write
// reports the failure itself.
bridge_shell_exited_enqueue :: proc(event_json: string) {
	bridge_tool_live_shell_exit(event_json)
	if strings.trim_space(event_json) == "" do return

	outbox_path: string
	// Persisted outside the lock: this is file I/O, and bridge_runtime_mutex is the
	// hot lock the WS service loop takes every 25ms tick.
	if data_dir := bridge_shell_data_dir(); data_dir != "" {
		defer delete(data_dir)
		session_id := extract_json_string(event_json, "session_id", "")
		defer if session_id != "" do delete(session_id)
		// run_seq is read back OUT of the frame rather than passed in alongside it, so
		// the envelope's key and the frame's contents cannot disagree: whatever run the
		// hub will be told about is the run the file is named for.
		run_seq := extract_json_int(event_json, "run_seq", 0)
		outbox_path = bridge_shell_exited_outbox_write(data_dir, session_id, event_json, bridge_now_unix_ms(), run_seq)
	}

	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	append(&bridge_shell_exited_outgoing, Bridge_Shell_Exited_Outgoing{
		event_json  = strings.clone(event_json),
		outbox_path = outbox_path,
	})
}

// bridge_shell_exited_outbox_restore reloads exits persisted by a PREVIOUS bridge
// process and puts them back at the FRONT of the in-memory queue, so a restart's
// backlog drains ahead of whatever this process has since produced. Called once from
// bridge_hub_runtime_start; the existing drain in bridge_hub_runtime_loop sends them
// as soon as the hub WS is up, with no poller and no extra thread.
bridge_shell_exited_outbox_restore :: proc() {
	data_dir := bridge_shell_data_dir()
	if data_dir == "" do return
	defer delete(data_dir)

	entries := bridge_shell_exited_outbox_load(data_dir, bridge_now_unix_ms())
	if len(entries) == 0 {
		delete(entries)
		return
	}
	defer delete(entries)

	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for e, i in entries {
		inject_at(&bridge_shell_exited_outgoing, i, Bridge_Shell_Exited_Outgoing{
			// event_json and path are re-homed into the queue item, which owns them
			// from here; only session_id is surplus to the queue's needs.
			event_json  = e.event_json,
			outbox_path = e.path,
		})
		if e.session_id != "" do delete(e.session_id)
	}
	fmt.println("bridge shell_exited outbox: restored", len(entries), "undelivered exit(s) from disk")
}

bridge_shell_exited_drain_outgoing :: proc(conn: ^ws.Connection) {
	for {
		item: Bridge_Shell_Exited_Outgoing
		have := false
		sync.mutex_lock(&bridge_runtime_mutex)
		if len(bridge_shell_exited_outgoing) > 0 {
			item = bridge_shell_exited_outgoing[0]
			ordered_remove(&bridge_shell_exited_outgoing, 0)
			have = true
		}
		sync.mutex_unlock(&bridge_runtime_mutex)
		if !have do return
		if !bridge_hub_send(conn, item.event_json) {
			sync.mutex_lock(&bridge_runtime_mutex)
			inject_at(&bridge_shell_exited_outgoing, 0, item)
			sync.mutex_unlock(&bridge_runtime_mutex)
			conn.connected = false
			return
		}
		// Only now is the exit durably OFF the queue. Removing the envelope before
		// the send would reintroduce exactly the loss this outbox exists to stop; a
		// crash between the send and this remove replays the exit instead, which the
		// hub's idempotent apply absorbs.
		bridge_shell_exited_outbox_remove(item.outbox_path)
		if item.outbox_path != "" do delete(item.outbox_path)
		delete(item.event_json)
	}
}

// ---- Typed wire command and event structs (REQ-P1-WIRE-CMD) ----------------

Bridge_Shell_Enc_Spec :: struct {
	cmd:       string,
	cwd:       string,
	env:       [][2]string,
	has_env:   bool,
	timestamp: i64,
	nonce:     string,
	// Binding (finding N1): the spec authorizes exactly one start of one session on
	// one bridge process. boot_id is this bridge's unseal boot id, so a spec captured
	// before a restart (whose nonce cache is gone) no longer authenticates.
	bridge_id:  string,
	session_id: string,
	kind:       string,
	boot_id:    string,
}

// bridge_enc_spec_check_binding verifies the sealed binding against what this bridge
// is and what the request asks for. Every field is required. Returns "" or the error.
bridge_enc_spec_check_binding :: proc(spec: Bridge_Shell_Enc_Spec, bridge_id, session_id, kind, boot_id: string) -> string {
	if spec.bridge_id == "" || spec.bridge_id != bridge_id do return "unauthorized: execution spec is for a different bridge"
	if spec.session_id == "" || spec.session_id != session_id do return "unauthorized: execution spec is for a different session"
	if spec.kind == "" || spec.kind != kind do return "unauthorized: execution spec is for a different session kind"
	if spec.boot_id == "" || boot_id == "" || spec.boot_id != boot_id do return "unauthorized: execution spec is for a previous bridge process"
	return ""
}

// enc_spec freshness (finding M1): the timestamp must be within ±60 s and the
// nonce must not have been seen inside that window. The nonce is recorded for
// ENC_SPEC_NONCE_TTL_MS, which outlives any timestamp the window accepts, and a
// full cache refuses rather than evicting a live nonce. Called only after the
// enc_spec decrypted under the current epoch, so only authenticated nonces are
// recorded. Returns "" or the error message.
ENC_SPEC_MAX_SKEW_MS :: 60_000
ENC_SPEC_NONCE_TTL_MS :: 2 * ENC_SPEC_MAX_SKEW_MS + 1_000
ENC_SPEC_NONCE_MIN_LEN :: 16

g_enc_spec_nonce_cache: Nonce_Replay_Cache

bridge_enc_spec_check_fresh :: proc(timestamp: i64, nonce: string, now_ms: i64) -> string {
	ts_ms := timestamp
	if ts_ms > 0 && ts_ms < 10_000_000_000 {
		ts_ms *= 1000
	}
	drift := now_ms - ts_ms
	if ts_ms == 0 || drift < -ENC_SPEC_MAX_SKEW_MS || drift > ENC_SPEC_MAX_SKEW_MS {
		return "unauthorized: expired execution timestamp"
	}
	if len(nonce) < ENC_SPEC_NONCE_MIN_LEN || len(nonce) > 64 {
		return "unauthorized: missing or invalid execution nonce"
	}
	switch nonce_cache_insert(&g_enc_spec_nonce_cache, nonce, now_ms, ENC_SPEC_NONCE_TTL_MS) {
	case .Inserted:
		return ""
	case .Replay:
		return "unauthorized: replayed execution request"
	case .Full:
		return "unauthorized: too many recent execution requests; retry shortly"
	case .Invalid:
	}
	return "unauthorized: missing or invalid execution nonce"
}

// Bridge_Shell_Enc_Spec_Wire is the decrypted enc_spec document (typed decode). env
// stays a json.Value: it may be [[k,v],...], ["K=V",...] or {"K":"V",...}.
Bridge_Shell_Enc_Spec_Wire :: struct {
	cmd:        string,
	cwd:        string,
	env:        json.Value,
	timestamp:  i64,
	nonce:      string,
	bridge_id:  string,
	session_id: string,
	kind:       string,
	boot_id:    string,
}

// bridge_shell_parse_enc_spec decodes a decrypted enc_spec. A member of the wrong
// type (or a document that is not a JSON object) fails the whole spec.
bridge_shell_parse_enc_spec :: proc(json_text: string, allocator := context.temp_allocator) -> (spec: Bridge_Shell_Enc_Spec, ok: bool) {
	wire: Bridge_Shell_Enc_Spec_Wire
	if !vault.wire_decode(json_text, &wire, allocator) do return {}, false
	spec = Bridge_Shell_Enc_Spec{
		cmd = wire.cmd, cwd = wire.cwd, timestamp = wire.timestamp, nonce = wire.nonce,
		bridge_id = wire.bridge_id, session_id = wire.session_id, kind = wire.kind, boot_id = wire.boot_id,
	}
	if wire.env == nil do return spec, true
	spec.has_env = true
	env_list := make([dynamic][2]string, allocator)
	#partial switch e in wire.env {
	case json.Array:
		for item in e {
			#partial switch it in item {
			case json.Array:
				if len(it) >= 2 {
					k, kok := it[0].(json.String)
					val_str, vok := it[1].(json.String)
					if kok && vok do append(&env_list, [2]string{string(k), string(val_str)})
				}
			case json.String:
				if eq := strings.index_byte(string(it), '='); eq > 0 {
					append(&env_list, [2]string{string(it[:eq]), string(it[eq + 1:])})
				}
			}
		}
	case json.Object:
		for k, item in e {
			if val_str, vok := item.(json.String); vok do append(&env_list, [2]string{k, string(val_str)})
		}
	}
	spec.env = env_list[:]
	return spec, true
}

Bridge_Shell_Start_Command :: struct {
	type:              string `json:"type"`,
	command_id:        string `json:"command_id"`,
	session_id:        string `json:"session_id"`,
	kind:              string `json:"kind"`,
	cmd:               string `json:"cmd"`,
	cwd:               string `json:"cwd"`,
	enc_spec:          string `json:"enc_spec"`,
	label:             string `json:"label"`,
	project_id:        string `json:"project_id"`,
	chain_id:          string `json:"chain_id"`,
	agent_instance_id: string `json:"agent_instance_id"`,
	owner_user_id:     string `json:"owner_user_id"`,
	started_at:        string `json:"started_at"`,
	server_port:       int    `json:"server_port"`,
	background:        bool   `json:"background"`,
	run_seq:           int    `json:"run_seq"`,
}

Bridge_Shell_Exited_Event :: struct {
	type:          string `json:"type"`,
	session_id:    string `json:"session_id"`,
	exit_code:     int    `json:"exit_code"`,
	exit_code_set: bool   `json:"exit_code_set"`,
	status:        string `json:"status"`,
	finished_at:   string `json:"finished_at"`,
	run_seq:       int    `json:"run_seq"`,
}

// Bridge_Shell_Exited_Event_No_Code is the same frame for an exit nobody observed a
// status for (a run found gone by the sweep, REQ-BR-1). It has NO exit_code key, on
// purpose: the hub decides exit_code_set by the key's PRESENCE, so sending
// `"exit_code":0` would record a clean exit that never happened.
Bridge_Shell_Exited_Event_No_Code :: struct {
	type:          string `json:"type"`,
	session_id:    string `json:"session_id"`,
	exit_code_set: bool   `json:"exit_code_set"`,
	status:        string `json:"status"`,
	finished_at:   string `json:"finished_at"`,
	run_seq:       int    `json:"run_seq"`,
}

Bridge_Shell_Error_Result :: struct {
	type:        string     `json:"type"`,
	session_id:  string     `json:"session_id"`,
	command_id:  string     `json:"command_id"`,
	ok:          bool       `json:"ok"`,
	error:       string     `json:"error"`,
	error_code:  string     `json:"error_code,omitempty"`,
	server_port: Maybe(int) `json:"server_port,omitempty"`,
	pid:         Maybe(int) `json:"pid,omitempty"`,
}

Bridge_Shell_Start_Result :: struct {
	type:       string `json:"type"`,
	session_id: string `json:"session_id"`,
	command_id: string `json:"command_id"`,
	ok:         bool   `json:"ok"`,
	pid:        int    `json:"pid"`,
	shell_id:   string `json:"shell_id"`,
}

Bridge_Shell_Set_Port_Command :: struct {
	type:        string `json:"type"`,
	session_id:  string `json:"session_id"`,
	command_id:  string `json:"command_id"`,
	server_port: int    `json:"server_port"`,
}

Bridge_Shell_Set_Port_Result :: struct {
	type:       string `json:"type"`,
	session_id: string `json:"session_id"`,
	command_id: string `json:"command_id"`,
	ok:         bool   `json:"ok"`,
	error:      Bridge_Result_Error `json:"error"`,
}

Bridge_Shell_Restart_Command :: struct {
	type:       string `json:"type"`,
	session_id: string `json:"session_id"`,
	command_id: string `json:"command_id"`,
	run_seq:    int    `json:"run_seq"`,
}

Bridge_Shell_Restart_Result :: struct {
	type:       string     `json:"type"`,
	session_id: string     `json:"session_id"`,
	command_id: string     `json:"command_id"`,
	ok:         bool       `json:"ok"`,
	pid:        Maybe(int) `json:"pid,omitempty"`,
	// Typed refusal (REQ-ERR-PROTO-A); nil on success.
	error:      Bridge_Result_Error `json:"error"`,
}

Bridge_Shell_Logs_Command :: struct {
	type:       string `json:"type"`,
	session_id: string `json:"session_id"`,
	command_id: string `json:"command_id"`,
	offset:     int    `json:"offset"`,
	limit:      int    `json:"limit"`,
	grep:       string `json:"grep"`,
}

Bridge_Shell_Background_Command :: struct {
	type:       string `json:"type"`,
	session_id: string `json:"session_id"`,
}

Bridge_Shell_Kill_Command :: struct {
	type:       string `json:"type"`,
	session_id: string `json:"session_id"`,
}

Bridge_Shell_Signal_Command :: struct {
	type:       string `json:"type"`,
	session_id: string `json:"session_id"`,
	signal:     int    `json:"signal"`,
}

// ---- shell_exited event JSON serializer (REQ-P1-WIRE-CMD) ---------------

// run_seq (REQ-SHELL-4) names which RUN of the session exited. The hub discards a
// report whose run_seq is older than its row's, which is what stops an exit replayed
// from the durable outbox from terminating a session that has since been restarted
// and is genuinely alive.
//
// exit_code_set=false omits the exit_code key entirely (see
// Bridge_Shell_Exited_Event_No_Code); exit_code is ignored then.
bridge_shell_exited_event_json :: proc(session_id: string, exit_code: int, exit_code_set: bool, status: string, run_seq: int) -> string {
	if !exit_code_set {
		evt := Bridge_Shell_Exited_Event_No_Code{
			type          = "shell_exited",
			session_id    = session_id,
			exit_code_set = false,
			status        = status,
			finished_at   = action_scheduler_format_rfc3339_utc(bridge_now_unix_ms()),
			run_seq       = run_seq,
		}
		data, err := json.marshal(evt, allocator = context.allocator)
		if err != nil do return ""
		return string(data)
	}
	evt := Bridge_Shell_Exited_Event{
		type          = "shell_exited",
		session_id    = session_id,
		exit_code     = exit_code,
		exit_code_set = exit_code_set,
		status        = status,
		finished_at   = action_scheduler_format_rfc3339_utc(bridge_now_unix_ms()),
		run_seq       = run_seq,
	}
	data, err := json.marshal(evt, allocator = context.allocator)
	if err != nil do return ""
	return string(data)
}

// ---- REQ-SHELL-16 D1a: one rejection path, and it is never silent ----

// bridge_shell_send_error replies to a failed shell_* request AND records the reason
// on the host. It replaces three byte-identical nested `send_error` helpers (shell_start,
// shell_logs, shell_capture) that differed only in the `type` string and their
// zero-valued padding fields, and that shared one defect: none of them logged, so the
// bridge could refuse a request and leave no trace anywhere. The reason reached the hub
// in the reply's `error` field, the hub replaced it with a constant (REQ-SHELL-16 D1b),
// and the cause of a user-visible failure was then recoverable from NOWHERE — not the
// session row, not the journal, not the hub's error.
//
// It is ONE proc rather than three edited copies on purpose. Three bodies carrying the
// same obligation is how the obligation came to be missing from all three; a caller
// cannot now add a rejection site that forgets to log, because there is no other way to
// send one.
//
// `extra_json` carries the per-type fields a failed reply must still include so the
// shape stays uniform for the hub's parser (e.g. `"lines":[],"truncated":false` for
// logs). Pass "" when the type needs none. It is written raw, so callers pass a
// literal — never interpolated input.
//
// Logged at plain stdout, the bridge's normal journal level (cf. pty_host_runtime.odin
// child-exit logging), NOT behind a debug flag: a rejection that is only visible when
// someone thought to turn logging on ahead of time is the exact failure being fixed.
bridge_shell_send_error :: proc(conn: ^ws.Connection, result_type, session_id, command_id, cause, msg, extra_json: string) {
	line := bridge_shell_error_log_line(result_type, session_id, command_id, msg)
	fmt.println(line)
	delete(line)

	result := bridge_shell_error_result_json(result_type, session_id, command_id, cause, msg, extra_json)
	defer delete(result)
	if conn != nil do _ = bridge_hub_send(conn, result)
}

// bridge_shell_error_log_line formats the host-side record of a refusal. Split out
// from the print for the same reason the reply body is: this line IS the diagnostic
// contract REQ-SHELL-16 exists to create, so its shape is pinned by a test rather than
// by whoever reads it next. A future edit that drops session_id or command_id from it
// would restore the original defect — a refusal you can see happened but cannot tie to
// a session — while every other test still passed. Caller owns the result.
bridge_shell_error_log_line :: proc(result_type, session_id, command_id, msg: string) -> string {
	return fmt.aprintf(
		"bridge shell: rejected %s session_id=%s command_id=%s reason=%s",
		result_type, session_id, command_id, msg,
	)
}

// bridge_shell_error_result_json builds the failure reply body. Split out from the
// send so the wire shape is assertable without a live connection: this refactor
// collapsed three hand-written builders into one, and the three replies are a
// CONTRACT the hub parses, so "still byte-identical per type" needs to be a test
// rather than a careful reading. Caller owns the result.
bridge_shell_error_result_json :: proc(result_type, session_id, command_id, cause, msg, extra_json: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"")
	bridge_runtime_write_json_string(&b, result_type)
	strings.write_string(&b, "\",\"session_id\":\"")
	bridge_runtime_write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"command_id\":\"")
	bridge_runtime_write_json_string(&b, command_id)
	strings.write_string(&b, "\",")
	strings.write_string(&b, extra_json)
	bridge_write_failure(&b, bridge_cause_wire_error(cause, msg))
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// REQ-PAGER-1, REQ-PAGER-2, REQ-PAGER-3: inject non-interactive pager overrides into
// kind=run sessions so interactive pagers (less) do not block one-shot commands on stdin.
// Caller owns the returned slice and its cloned strings; bridge_pty_host_spawn_request_delete
// frees both.
bridge_shell_run_env :: proc() -> [][2]string {
	out := make([][2]string, 3)
	out[0] = [2]string{strings.clone("PAGER"), strings.clone("cat")}
	out[1] = [2]string{strings.clone("GIT_PAGER"), strings.clone("cat")}
	out[2] = [2]string{strings.clone("SYSTEMD_PAGER"), strings.clone("cat")}
	return out
}

// ---- T4: hub→bridge WS runtime command handlers (REQ-SH-CONTRACT §3) ----

// bridge_hub_handle_shell_start handles the "shell_start" command.
// REQUEST/REPLY: spawns a new PTY session via the daemon and returns shell_start_result.
bridge_hub_handle_shell_start :: proc(conn: ^ws.Connection, text: string) {
	// REQ-SHELL-8: the session-create trigger, on the hub-driven side. Same debounced
	// sweep the agent run path calls; both spellings of "a session was created" reach
	// retention so neither can be the one that never tidies up.
	bridge_shell_output_sweep_if_due()

	// REQ-SHELL-16: this is now a two-constant binding over bridge_shell_send_error,
	// not a body. It stays as a nested proc only so the handler's rejection sites keep
	// reading `send_error(conn, session_id, command_id, "reason")` and cannot forget
	// which result type they are answering. The JSON building — and the logging they
	// were all missing — lives in exactly one place.
	send_error :: proc(conn: ^ws.Connection, session_id, command_id, cause, msg: string) {
		bridge_shell_send_error(conn, "shell_start_result", session_id, command_id, cause, msg, "")
	}

	cmd_wire: Bridge_Shell_Start_Command
	if err := json.unmarshal(transmute([]byte)text, &cmd_wire, allocator = context.temp_allocator); err != nil {
		send_error(conn, "", "", "invalid_payload", "invalid json")
		return
	}

	session_id  := cmd_wire.session_id
	command_id  := cmd_wire.command_id
	kind_str    := cmd_wire.kind if cmd_wire.kind != "" else "run"
	label       := cmd_wire.label
	project_id  := cmd_wire.project_id
	chain_id    := cmd_wire.chain_id
	agent_iid   := cmd_wire.agent_instance_id
	owner_uid   := cmd_wire.owner_user_id
	// REQ-SHELL-1 §8: the HUB clock is authoritative for every lifecycle and age
	// decision, so the hub sends the started_at it assigned and the bridge stores
	// THAT rather than stamping its own. Falls back to the local clock only when a
	// caller omits it (there is no hub-side path that does).
	hub_started_at := cmd_wire.started_at
	server_port := cmd_wire.server_port
	// REQ-SHELL-2: a run may be born background (--bg). Only a run uses this; a
	// shell and a server have no foreground form to convert from.
	background := cmd_wire.background
	// REQ-SHELL-4: the hub-assigned run number, echoed back on every exit this
	// session reports. Same "hub assigns, bridge stores THAT" rule as started_at
	// above. Absent means run 0, the first run.
	run_seq := cmd_wire.run_seq

	if session_id == "" {
		send_error(conn, session_id, command_id, "missing_session_id", "missing session_id")
		return
	}

	kind := bridge_shell_session_kind_from_str(kind_str)

	// REQ-SHELL-ENC-1: the execution spec is authenticated and decrypted from enc_spec;
	// the plaintext cmd/cwd on the wire are never executed (there is no plaintext
	// vault mode). A bridge without a key fails closed before anything can reach
	// `cmd`; `vault_locked` is the stable code the fs handlers already use (REQ-T9-2).
	vault_status, kr := bridge_vault_status_and_key()
	defer vault.keyring_wipe(&kr)
	if vault_status != .Unlocked {
		send_error(conn, session_id, command_id, "vault_locked", "unauthorized: vault locked")
		return
	}
	if cmd_wire.enc_spec == "" || !vault.is_armored(cmd_wire.enc_spec) {
		send_error(conn, session_id, command_id, "invalid_vault_key", "unauthorized: missing or invalid vault enc_spec")
		return
	}

	// Command epoch floor: an enc_spec sealed under any epoch but the current one
	// is refused, even when the keyring still holds that older key.
	plaintext, dec_ok := bridge_open_current_epoch_token(cmd_wire.enc_spec, &kr, context.temp_allocator)
	if !dec_ok || len(plaintext) == 0 {
		send_error(conn, session_id, command_id, "invalid_vault_key", "unauthorized: invalid vault encryption")
		return
	}

	spec, parse_ok := bridge_shell_parse_enc_spec(plaintext, context.temp_allocator)
	if !parse_ok {
		send_error(conn, session_id, command_id, "invalid_vault_key", "unauthorized: invalid vault encryption")
		return
	}

	// Binding before freshness: a spec for another bridge, session, kind or bridge
	// process must not consume a nonce slot here.
	if bind_err := bridge_enc_spec_check_binding(spec, bridge_config.daemon_id, session_id, cmd_wire.kind, bridge_unseal_boot_id()); bind_err != "" {
		send_error(conn, session_id, command_id, "invalid_vault_key", bind_err)
		return
	}

	if fresh_err := bridge_enc_spec_check_fresh(spec.timestamp, spec.nonce, bridge_now_unix_ms()); fresh_err != "" {
		send_error(conn, session_id, command_id, "invalid_vault_key", fresh_err)
		return
	}

	cmd := spec.cmd
	cwd := spec.cwd
	decrypted_env := spec.env
	has_decrypted_env := spec.has_env

	// T11-BUG-3: an interactive `shell` has no command of its own — it *is* the
	// user's login shell. Default to $SHELL (falling back to /bin/sh; PowerShell on
	// Windows) instead of rejecting the request. Every other kind still requires an
	// explicit cmd.
	cmd_defaulted := false
	if kind == .Shell && cmd == "" {
		cmd = bridge_os_default_shell()
		cmd_defaulted = true
	}
	if cmd == "" {
		send_error(conn, session_id, command_id, "missing_cmd", "missing cmd")
		return
	}

	// REQ-SHELL-20: REFUSE A CWD THAT DOES NOT EXIST OR IS NOT A DIRECTORY, before any
	// daemon work. Until this guard, such a cwd was SILENTLY DISCARDED inside the
	// vendored portable-pty crate (0.9.0, src/cmdbuilder.rs:501-507,
	// `.filter(|dir| Path::new(dir).is_dir()).unwrap_or(home)`) and the command ran in
	// $HOME reporting exit 0 — see src/bridge/shell_cwd.odin for the full mechanism and
	// for why /root already failed loudly while /nonexistent did not.
	//
	// This RESTORES A CONTRACT THE PRODUCT ALREADY MADE rather than inventing one: the
	// retired bridge-local exec surface this path replaced validated the same two cases
	// ("the directory must exist"), so callers moving to `shell run` had lost a check.
	// The refusal wording now lives once, in bridge_shell_cwd_reject_message.
	//
	// BEFORE bridge_pty_host_ensure_daemon deliberately: a doomed request should not
	// start a daemon. `cwd` itself is left as the caller wrote it — the session row and
	// the hub row then spell it the same way — and only the spawn uses the resolved
	// form.
	cwd_resolved, cwd_verdict := bridge_shell_cwd_resolve(cwd)
	defer delete(cwd_resolved)
	if cwd_verdict != .Ok {
		msg := bridge_shell_cwd_reject_message(cwd_verdict, cwd_resolved)
		defer delete(msg)
		send_error(conn, session_id, command_id, "invalid_cwd", msg)
		return
	}

	// EVERY kind spawns under session_id as the daemon key (REQ-SHELL-1 §2). The
	// old kind=Agent branch that keyed the daemon by agent_instance_id instead is
	// gone with the kind itself: agent terminal panes never came through here, they
	// are served by capture_agent_pane / get_agent_pane.
	spawn_instance := session_id

	socket, daemon_ok := bridge_pty_host_ensure_daemon()
	if !daemon_ok {
		send_error(conn, session_id, command_id, "pty_host_unreachable", "daemon unavailable")
		return
	}

	// T11-BUG-2: for server sessions, `exec` into the command so the shell replaces
	// itself with the server process. Without it `sh` forks, exits as soon as the
	// command is backgrounded/daemonised, and pty-host reports the session as exited
	// while the real server is still running. The session still records the original
	// cmd (below) so the UI shows what the user asked for, not the exec wrapper.
	spawn_cmd := cmd
	spawn_cmd_owned := false
	defer if spawn_cmd_owned do delete(spawn_cmd)
	// Both rewrites below are sh syntax. On Windows a server needs no exec: the
	// pty-host keeps the whole session tree in one Job Object, so cmd.exe staying
	// as the parent does not end the session early.
	if kind == .Server && ODIN_OS != .Windows {
		spawn_cmd = strings.concatenate({"exec ", cmd})
		spawn_cmd_owned = true
	} else if cmd_defaulted && ODIN_OS != .Windows {
		// T11-BUG-11 (REQ-SHELL-ENV-1): a `shell` session with no cmd means
		// "give me my shell", so start it as a *login* shell. Without -l only
		// ~/.zshrc runs; ~/.zprofile, ~/.zlogin and /etc/profile never do, so the
		// session misses everything the user sets up in their profile.
		//
		// -l on its own is NOT enough, and this was measured rather than assumed.
		// The pty-host daemon outlives bridge restarts (bridge_pty_host_ensure_daemon
		// adopts a daemon already on the socket), so a shell inherits whatever env
		// that daemon froze. On NixOS the system env setup is guarded by "already
		// done" flags that are part of that inherited env, so the login shell
		// faithfully re-runs the profile files and they all short-circuit:
		//   /etc/profile, /etc/zshenv   -> source <store>-set-environment (the file
		//                                  that defines the real PATH, including
		//                                  /etc/profiles/per-user/$USER/bin) ONLY if
		//                                  __NIXOS_SET_ENVIRONMENT_DONE is unset.
		//   /etc/zprofile               -> never sources set-environment at all.
		// Result: a login shell under a stale daemon keeps the stale PATH verbatim.
		// Clearing the guards first is what actually rebuilds the environment from
		// the system's own definition, which is also what makes this self-healing
		// regardless of how old the daemon is.
		//
		// CAUTION — this guard list is EMPIRICAL, not a documented API. It was read
		// off the generated files on a NixOS + home-manager host; nothing validates
		// it, and if NixOS or home-manager introduces another guard this silently
		// degrades back to the inherited-env behaviour with no build or test
		// failure. The three families, so the next person knows what to look for:
		//   __NIXOS_SET_ENVIRONMENT_DONE  - NixOS set-environment (the PATH source)
		//   __ETC_*_SOURCED / _DONE       - the generated /etc profile + zsh + bash
		//                                   chain's once-per-shell guards
		//   __HM_*_SESS_VARS_SOURCED      - home-manager's session-variables guards
		// Note this REBUILDS PATH rather than extending it, so store paths the
		// bridge's own environment contributed (ham-ctl, tmux, ...) are not carried
		// into the session. That is intended: the session gets the user's own
		// environment, and per REQ-SHELL-ENV-1 no HEIMDALL_* is injected either.
		//
		// `exec` keeps the uniform ["sh","-c",...] wrapper from leaving an extra
		// sh in the process tree. Only the defaulted case is rewritten: a
		// caller-supplied cmd is always passed through exactly as given, for every
		// kind — asking for a command means asking for that command.
		b := strings.builder_make()
		strings.write_string(&b, "unset __NIXOS_SET_ENVIRONMENT_DONE __ETC_PROFILE_SOURCED __ETC_PROFILE_DONE __ETC_ZSHENV_SOURCED __ETC_ZPROFILE_SOURCED __ETC_ZSHRC_SOURCED __ETC_BASHRC_SOURCED __HM_SESS_VARS_SOURCED __HM_ZSH_SESS_VARS_SOURCED; exec ")
		bridge_bootstrap_shell_quote(&b, cmd)
		strings.write_string(&b, " -l")
		spawn_cmd = strings.to_string(b)
		spawn_cmd_owned = true
	}

	// Build argv: wrap cmd in sh -c. No external setsid: portable-pty's pre_exec
	// calls setsid(2) before exec, making the child a session leader. If we also
	// exec the setsid binary, it sees EPERM (already a leader), forks, and the
	// parent exits immediately with code 0 — pty-host sees the direct child exit
	// while the actual shell runs as an orphan grandchild disconnected from the PTY.
	argv := bridge_os_shell_argv(spawn_cmd)
	when ODIN_OS == .Windows {
		// The defaulted interactive shell is launched directly, not via cmd.exe /c.
		if cmd_defaulted {
			argv = make([]string, 1, context.temp_allocator)
			argv[0] = spawn_cmd
		}
	}
	cloned_argv := make([]string, len(argv))
	for a, i in argv { cloned_argv[i] = strings.clone(a) }

	tee_path := bridge_shell_output_path(session_id)
	// T11-BUG-1: pty-host cannot tee into a directory that does not exist yet. The
	// path itself comes from bridge_shell_output_path (src/bridge/shell_common.odin),
	// which is also what the log and retention paths resolve, so the three agree.
	spawn_env: [][2]string = nil
	if has_decrypted_env {
		dyn_env := make([dynamic][2]string, context.allocator)
		for pair in decrypted_env {
			append(&dyn_env, [2]string{strings.clone(pair[0]), strings.clone(pair[1])})
		}
		if kind == .Run {
			has_pager := false
			has_git_pager := false
			has_systemd_pager := false
			for pair in dyn_env {
				if pair[0] == "PAGER" do has_pager = true
				if pair[0] == "GIT_PAGER" do has_git_pager = true
				if pair[0] == "SYSTEMD_PAGER" do has_systemd_pager = true
			}
			if !has_pager do append(&dyn_env, [2]string{strings.clone("PAGER"), strings.clone("cat")})
			if !has_git_pager do append(&dyn_env, [2]string{strings.clone("GIT_PAGER"), strings.clone("cat")})
			if !has_systemd_pager do append(&dyn_env, [2]string{strings.clone("SYSTEMD_PAGER"), strings.clone("cat")})
		}
		spawn_env = dyn_env[:]
	} else if kind == .Run {
		spawn_env = bridge_shell_run_env()
	}

	// The PTY host appends the session's output to tee_path; make sure its
	// directory exists before the request (a fresh install's first session
	// lost its saved output to ENOENT when nothing had created it yet).
	if slash := strings.last_index_byte(tee_path, '/'); slash > 0 {
		_ = bridge_make_directory_all(tee_path[:slash])
	}
	req := Pty_Host_Spawn_Request{
		instance         = strings.clone(spawn_instance),
		argv             = cloned_argv,
		// THE RESOLVED FORM, not the raw one: expansion and validation happen together
		// (REQ-SHELL-20), so spawning with the raw value would spawn something other
		// than what was checked.
		has_cwd          = cwd_resolved != "",
		cwd              = strings.clone(cwd_resolved),
		env              = spawn_env,
		rows             = PTY_HOST_DEFAULT_ROWS,
		cols             = PTY_HOST_DEFAULT_COLS,
		display_name     = strings.clone(label),
		has_display_name = label != "",
		kind             = strings.clone(kind_str),
		has_kind         = kind_str != "",
		tee_path         = tee_path,
		has_tee_path     = true,
	}
	defer bridge_pty_host_spawn_request_delete(req)

	pid, ok, spawn_err := bridge_pty_host_spawn_detailed(socket, req)
	defer delete(spawn_err)
	if !ok {
		// The DAEMON'S OWN reason leads the message: "spawn failed (cwd: X)" alone read
		// as a cwd problem when the real cause was the daemon out of file descriptors.
		// The cwd is still appended as STATE, never as a diagnosis — it is the one piece
		// of context the reader cannot otherwise recover.
		msg: string
		if cwd_resolved != "" {
			msg = strings.concatenate({"spawn failed: ", spawn_err, " (cwd: ", cwd_resolved, ")"})
		} else {
			msg = strings.concatenate({"spawn failed: ", spawn_err})
		}
		defer delete(msg)
		send_error(conn, session_id, command_id, "shell_start_failed", msg)
		return
	}

	now_ms := bridge_now_unix_ms()
	started_at := strings.clone(bridge_shell_authoritative_started_at(hub_started_at, action_scheduler_format_rfc3339_utc(now_ms)))
	defer delete(started_at)

	// THE MAP'S ALLOCATOR, explicitly: register below takes ownership of every string
	// here and the map frees them when this entry is superseded (reconcile, on a
	// background thread) or removed. context.allocator differs per thread, so cloning
	// through it would free through a different allocator than it allocated from.
	map_heap := bridge_shell_session_map_allocator(&bridge_shell_session_map)
	sess := Bridge_Shell_Session{
		session_id        = strings.clone(session_id, map_heap),
		kind              = kind,
		label             = strings.clone(label, map_heap),
		cmd               = strings.clone(cmd, map_heap),
		cwd               = strings.clone(cwd, map_heap),
		bridge_id         = strings.clone(bridge_config.daemon_id, map_heap),
		project_id        = strings.clone(project_id, map_heap),
		chain_id          = strings.clone(chain_id, map_heap),
		agent_instance_id = strings.clone(agent_iid, map_heap),
		owner_user_id     = strings.clone(owner_uid, map_heap),
		pid               = int(pid),
		server_port       = server_port,
		run_seq           = run_seq,
		status            = .Running,
		started_at        = strings.clone(started_at, map_heap),
		// shell_id == session_id for every kind now, which is what reconcile matches
		// on (d.shell_id == s.shell_id). Kept as spawn_instance rather than inlining
		// session_id so the daemon key stays spelled once.
		shell_id          = strings.clone(spawn_instance, map_heap),
		started_unix_ms   = now_ms,
		background        = background,
		// Spawned BY THE PTY-HOST DAEMON, so this session does appear in its roster and
		// reconcile resolves it there. THIS IS NOW THE ONLY SPAWN PATH — REQ-SHELL-7
		// deleted the bridge-local exec path, whose direct os.process_start child set
		// this false and could never be in the roster. Reconcile still branches on the
		// flag rather than on kind, because specs written before that commit describe
		// such children and are still read back.
		pty_host          = true,
		pty_host_provenance_known = true,
	}
	// SPEC FIRST, THEN REGISTER (REQ-SHELL-11 review). save_spec reads every string of
	// `sess`, and once register has it the MAP owns those strings — a concurrent
	// re-register of this session_id (a reconcile pass on the background thread, which
	// a hub WS reconnect triggers while the hub is reissuing starts) would free them
	// mid-read. The bridge_expand_home calls below used to sit inside that window and
	// widen it.
	//   Reordering DELETES the window instead of making it safe: `sess` is fully
	// populated before either call — the pid included, so REQ-SHELL-2's "save the spec
	// only once the pid is known" rule still holds — so the spec content is identical
	// either way. It is also the better crash ordering: a crash between the two now
	// leaves a spec with no map entry, which reconcile's orphan path already handles,
	// rather than a map entry with no spec, which a restart simply loses.
	data_dir := bridge_expand_home(bridge_config.data_dir)
	if strings.trim_space(data_dir) == "" do data_dir = bridge_expand_home("~/.local/share/heimdall")
	bridge_shell_session_save_spec(data_dir, sess)

	// CONSUMES sess: it is zeroed here and must not be read below.
	bridge_shell_session_register(&bridge_shell_session_map, &sess)
	if started, tracked := bridge_shell_session_snapshot(&bridge_shell_session_map, session_id); tracked {
		bridge_tool_live_shell(started, true)
		bridge_shell_session_snapshot_destroy(&bridge_shell_session_map, started)
	}

	bridge_pty_host_events_ensure()

	// REQ-SHELL-2 §8: arm the 30-minute hard cap. Only a RUN is armed — a server is
	// long-running by definition and must never be capped — see
	// bridge_shell_run_cap_start for why the cap needs its own watchdog on this path
	// at all (the retired reaper that used to enforce it owned a direct child it could
	// simply wait on; a hub-path run's process belongs to the daemon, so nothing here
	// has a child to wait for).
	bridge_shell_run_cap_start(session_id, kind)

	res_wire := Bridge_Shell_Start_Result{
		type       = "shell_start_result",
		session_id = session_id,
		command_id = command_id,
		ok         = true,
		pid        = int(pid),
		shell_id   = spawn_instance,
	}
	if res_bytes, err := json.marshal(res_wire, allocator = context.temp_allocator); err == nil {
		if conn != nil do _ = bridge_hub_send(conn, string(res_bytes))
	}

	// KILL BEFORE START, THE APPLY HALF (REQ-SHELL-3 work item 5b). A kill that
	// arrived while this start was in flight was recorded as a pending intent, because
	// there was no session and no pid to act on at the time. There is now, so apply it:
	// a session that starts carrying a kill intent must be killed immediately, never
	// left running.
	//
	// AFTER the start_result reply, deliberately. The hub is blocked on that reply and
	// uses it to learn the pid and write status=running; answering first keeps the
	// create path's contract unchanged, and the kill then arrives at the hub as the
	// shell_exited it would have seen for any other kill. The hub re-checks its own row
	// after the reply and re-dispatches if an intent is still pending, so neither side
	// depends on the other's ordering to get this right.
	if bridge_shell_kill_intent_take(session_id) {
		// RE-READ THE DAEMON KEY FROM THE MAP rather than from `sess`. `sess` was handed
		// to bridge_shell_session_register above, so the map owns its strings from that
		// point and reading sess.shell_id here is a read of map-owned memory after the
		// mutex was released — the very borrow REQ-SHELL-11 removes, and a
		// use-after-free the moment register started freeing superseded strings (a
		// reconcile pass racing this start is enough).
		if shell_id, have_key := bridge_shell_session_shell_id(&bridge_shell_session_map, session_id); have_key {
			bridge_shell_kill_arm(session_id, shell_id)
			bridge_shell_session_str_delete(&bridge_shell_session_map, shell_id)
		}
	}
}

// bridge_shell_authoritative_started_at picks the started_at a session records.
//
// REQ-SHELL-1 §8: THE HUB CLOCK IS AUTHORITATIVE for every lifecycle and age
// decision. started_at used to be stamped twice for one fact — once hub-side, on
// the row the 1-day server reap reads, and once bridge-side, on the spec the
// 5-day output-retention sweep reads — so clock skew between the two hosts made
// them disagree about the same session's age. The hub now sends the value it
// assigned and the bridge stores THAT, so both sweeps measure against one clock.
//
// local_fallback is used only when the hub sent nothing, which no hub-side path
// does; it keeps a hand-rolled or replayed frame from recording an empty
// timestamp. Bridge-local stamps (Bridge_Shell_Session.started_unix_ms) survive
// as DIAGNOSTICS — they feed execution_time_ms — and must never drive a
// lifecycle decision.
bridge_shell_authoritative_started_at :: proc(hub_started_at, local_fallback: string) -> string {
	return hub_started_at != "" ? hub_started_at : local_fallback
}

// Bridge_Shell_Kill_Ctx carries state for the background kill thread.
// Bridge_Shell_Kill_Ctx is handed to bridge_shell_kill_worker on another thread.
//
// ALLOCATOR: context.allocator, on BOTH sides, at EVERY arming site. The struct and
// its two strings are allocated with the implicit context.allocator by whoever arms
// the kill, and bridge_shell_kill_worker frees them the same way. Stated here, at
// the struct, because it is the kind of rule that is remembered at one call site and
// forgotten at the next: pinning the allocation at one site while the worker's free
// stays implicit pairs a pinned alloc with an unpinned free, which is correct only
// while the context happens to carry the default allocator.
//
// It is NOT pinned to runtime.default_allocator() the way Bridge_Shell_Async_Ctx and
// the waiter registry are. Those are pinned because they cross into a thread whose
// context legitimately differs; this one is uniform and self-consistent as it
// stands, and pinning it properly means changing every arming site together —
// tracked as REQ-SHELL-13 (N8) rather than done piecemeal here.
Bridge_Shell_Kill_Ctx :: struct {
	session_id: string,
	shell_id:   string,
}

// bridge_shell_kill_shell_is_alive asks the DAEMON whether shell_id is still a live
// child. This is the escalation guard: it must NOT be inferred from
// Bridge_Shell_Session.status, because bridge_hub_handle_shell_kill deliberately
// writes .Killed before this worker even starts (so ChildExited can report
// status="killed"). Reading that field here made the SIGKILL branch unreachable for
// every session, which left SIGTERM-ignoring interactive shells unkillable (BUG-9).
// A shell missing from the roster has already been reaped, so absent => not alive.
bridge_shell_kill_shell_is_alive :: proc(socket, shell_id: string) -> bool {
	reply, ok := bridge_pty_host_list(socket)
	if !ok do return false
	defer pty_host_reply_delete(reply)
	for a in reply.agents {
		if a.instance_id == shell_id do return a.alive
	}
	return false
}

// bridge_shell_kill_worker sends SIGTERM, waits 5s, then SIGKILLs if the daemon still
// reports the child alive. The escalation stays bridge-side (rather than delegating to
// bridge_pty_host_close) on purpose: the daemon suppresses its ChildExited broadcast
// while tearing an instance down via close, and the bridge needs that event to fire the
// shell_exited notification that carries status="killed" to the hub.
bridge_shell_kill_worker :: proc(data: rawptr) {
	ctx := (^Bridge_Shell_Kill_Ctx)(data)
	defer {
		delete(ctx.session_id)
		delete(ctx.shell_id)
		free(ctx)
	}
	socket, ok := bridge_pty_host_ensure_daemon()
	if ok {
		// The signal results ARE checked now (REQ-SHELL-23). Both were `_ =`, so a kill
		// that reached the daemon and was refused by it — an unknown shell_id, a killpg
		// that failed — completed silently and looked exactly like a successful kill. A
		// kill this bridge could not execute must say so: the hub's row still carries the
		// intent, so the next reconnect retries, but an operator needs to be able to see
		// that it is retrying rather than succeeding.
		switch result, exit_code := bridge_pty_host_signal_detailed(&Pty_Host_Client{socket = socket}, ctx.shell_id, 15); result {
		case .Delivered:
		case .Already_Exited:
			// REQ-BR-2: the daemon says outright that the process is gone and hands us
			// its exit code — report it now (a no-op if already reported). There is
			// nothing left to escalate either way.
			data_dir := bridge_shell_data_dir()
			defer delete(data_dir)
			_ = bridge_shell_kill_resolve_already_exited(&bridge_shell_session_map, ctx.session_id, int(exit_code), data_dir)
			return
		case .Refused:
			fmt.println("bridge shell_kill: SIGTERM was REFUSED by the pty-host daemon", ctx.shell_id)
			// REQ-BR-2: a refusal usually means there is nothing left to kill — the
			// daemon already reaped the process and its ChildExited never reached us.
			// An older daemon says so only with a generic Error, so resolve the session
			// against the roster and report it if it is gone.
			if bridge_shell_kill_refused_finalize(socket, ctx.session_id) do return
		}
		time.sleep(5 * time.Second)
		if bridge_shell_kill_shell_is_alive(socket, ctx.shell_id) {
			if !bridge_pty_host_signal(&Pty_Host_Client{socket = socket}, ctx.shell_id, 9) {
				fmt.println("bridge shell_kill: SIGKILL was REFUSED by the pty-host daemon; the session is still alive", ctx.shell_id)
			}
		}
	} else {
		fmt.println("bridge shell_kill: pty-host daemon unreachable; kill not executed", ctx.shell_id)
		blog_warn(.pty_host_unreachable, blog_sym(.stage, .exec))
	}
}

// bridge_shell_kill_refused_finalize reads the roster and hands it to
// bridge_shell_kill_resolve_refused (shell_exit_sweep.odin). Returns true when the
// session was found gone and reported, so the caller has nothing left to escalate.
bridge_shell_kill_refused_finalize :: proc(socket, session_id: string) -> bool {
	reply, ok := bridge_pty_host_list(socket)
	if !ok do return false
	defer pty_host_reply_delete(reply)
	data_dir := bridge_shell_data_dir()
	defer delete(data_dir)
	return bridge_shell_kill_resolve_refused(&bridge_shell_session_map, session_id, reply.agents, data_dir)
}

// bridge_hub_handle_shell_kill handles the "shell_kill" command.
// FIRE-AND-FORGET: sends SIGTERM then (after 5s) SIGKILL if still alive.
//
// REQ-SHELL-3 made this IDEMPOTENT and gave it a KILL-BEFORE-START path. Both are
// required because a kill is now durable on the hub row and re-issued on every
// reconnect, so this handler must expect to be called more than once for the same
// session, and to be called for a session it has never heard of.
bridge_hub_handle_shell_kill :: proc(text: string) {
	cmd: Bridge_Shell_Kill_Command
	if err := json.unmarshal(transmute([]byte)text, &cmd, allocator = context.temp_allocator); err != nil {
		return
	}
	if cmd.session_id == "" do return
	session_id := cmd.session_id

	sc, ok := bridge_shell_session_scalars(&bridge_shell_session_map, session_id)
	if !ok {
		// KILL BEFORE START (REQ-SHELL-3 work item 5b). The hub writes its row and then
		// sends shell_start, so a kill accepted in between arrives here for a session
		// that does not exist yet — there is no pid to signal and nothing to mark. This
		// used to return silently and the process leaked the instant it spawned.
		//
		// Record the intent instead. It now has TWO consumers, and that is the whole of
		// REQ-SHELL-23 (see bridge_shell_kill_intent_resolve):
		//   bridge_hub_handle_shell_start — applies it the moment a spawn yields a pid;
		//   reconcile's resolver          — applies it to a session this bridge ADOPTED
		//                                   from the surviving pty-host daemon after a
		//                                   restart, which is never re-spawned and so was
		//                                   never reached by the first consumer.
		// That second case is why this branch is no longer a dead end. The old comment
		// here read "the entry is inert, because it can only ever be consumed by a spawn
		// of that same session_id" — true as written, and describing the reconnect replay's
		// kills without realising it: EVERY durable kill landed here and stopped.
		bridge_shell_kill_intent_record(session_id)
		// LOGGED, because the silence here is what let REQ-SHELL-23 ship. This branch and
		// the success path below were both wordless, so a kill that arrived and was parked
		// as an intent looked, in every log on the host, identical to a kill that never
		// arrived at all — and the reconnect replay's kills landed here every time.
		fmt.println("bridge shell_kill: session not in map; parked as a kill intent", session_id)
		return
	}

	// IDEMPOTENT REDELIVERY (REQ-SHELL-3 work item 3). A kill may legitimately arrive
	// twice — the hub replays outstanding intents on every reconnect, and reconnects
	// can race — so killing an already-terminal session must be a no-op rather than an
	// error. The check is on the session's own status, which the arming step below
	// sets to .Killed BEFORE the worker starts; that is what makes the second delivery
	// see a terminal session.
	//
	// This is not merely tidiness. Without it, a redelivered kill would arm a SECOND
	// SIGTERM/SIGKILL pair against a pid whose process has since exited, and the 5s
	// grace window between them is exactly when the OS is free to hand that pid to an
	// unrelated process — the PID-reuse hazard that
	// bridge_shell_session_orphan_kill_worker's identity re-check exists to prevent.
	// Not arming the second worker at all is the strongest available guard.
	if bridge_shell_session_status_is_terminal(sc.status) do return

	// An OWNED clone of the daemon key. THIS is the path the old leak comment named as
	// the use-after-free window: kill_arm's worker reads the key across a
	// bridge_pty_host_ensure_daemon call that can block for up to 5s, while reconcile
	// re-registers the same session from a background thread. The clone is what makes
	// holding it across that call safe.
	shell_id, have_key := bridge_shell_session_shell_id(&bridge_shell_session_map, session_id)
	if !have_key do return // removed between the two reads; nothing left to kill
	defer bridge_shell_session_str_delete(&bridge_shell_session_map, shell_id)
	bridge_shell_kill_arm(session_id, shell_id)
}

// bridge_shell_kill_arm marks a session .Killed and starts its kill worker. Factored
// out of bridge_hub_handle_shell_kill so the spawn path (which must apply a pending
// intent the moment a pid exists) uses the SAME arming sequence rather than its own
// copy — one place decides what killing a session means.
//
// The status is written before the worker starts, and that ordering is load-bearing
// in two ways: ChildExited then reports status="killed" rather than a plain exit, and
// it is what makes a redelivered kill see a terminal session and no-op.
// REQ-SHELL-11 changed the second parameter from the whole Bridge_Shell_Session to
// the resolved daemon key, which is the only field this proc ever read. Taking the
// struct meant every caller had to hold a borrowed copy of a map entry to call it;
// taking the string means the caller passes an owned clone from
// bridge_shell_session_shell_id (which also resolves the shell_id-or-session_id
// fallback that used to be spelled out here). The four statements below are otherwise
// unchanged, ordering included.
bridge_shell_kill_arm :: proc(session_id: string, shell_id: string) {
	// One line at the one place that decides what killing a session means, so "the kill
	// was actioned" is positively observable rather than inferred from the absence of
	// the not-in-map line above (REQ-SHELL-23 AC3).
	fmt.println("bridge shell_kill: arming kill", session_id, "shell_id", shell_id)
	// Mark intent to kill immediately so ChildExited can report status="killed".
	bridge_shell_session_update_status(&bridge_shell_session_map, session_id, .Killed, -1, false)

	ctx := new(Bridge_Shell_Kill_Ctx)
	ctx.session_id = strings.clone(session_id)
	ctx.shell_id   = strings.clone(shell_id)
	thread.run_with_data(rawptr(ctx), bridge_shell_kill_worker)
}

// bridge_hub_handle_shell_background handles the "shell_background" command
// (REQ-SHELL-2 §3): convert a LIVE FOREGROUND run to a background one at runtime.
//
// This is the transition the user drives from the UI (REQ-SHELL-6 builds the
// control) and that the hub's agent-liveness hook drives when a run's owning
// agent instance goes unreachable. Both arrive here as the same command, because
// they are the same state change — there is no second "converted differently"
// flavour of background for a consumer to have to distinguish.
//
// Fire-and-forget, like shell_kill and shell_signal: bridge_shell_set_background
// persists the flag and releases the blocked caller locally, and the hub has
// already written its own row. There is nothing for the hub to wait on.
bridge_hub_handle_shell_background :: proc(text: string) {
	cmd: Bridge_Shell_Background_Command
	if err := json.unmarshal(transmute([]byte)text, &cmd, allocator = context.temp_allocator); err != nil {
		return
	}
	if cmd.session_id == "" do return
	_ = bridge_shell_set_background(cmd.session_id)
}

// bridge_hub_handle_shell_signal handles the "shell_signal" command.
// FIRE-AND-FORGET: delivers signal to process group.
bridge_hub_handle_shell_signal :: proc(text: string) {
	cmd: Bridge_Shell_Signal_Command
	cmd.signal = 15
	if err := json.unmarshal(transmute([]byte)text, &cmd, allocator = context.temp_allocator); err != nil {
		return
	}
	if cmd.session_id == "" do return
	session_id := cmd.session_id
	signal     := cmd.signal if cmd.signal != 0 else 15

	// An OWNED clone, held across bridge_pty_host_ensure_daemon below — the other half
	// of the window the old leak comment named (see bridge_hub_handle_shell_kill).
	shell_id, ok := bridge_shell_session_shell_id(&bridge_shell_session_map, session_id)
	if !ok do return
	defer bridge_shell_session_str_delete(&bridge_shell_session_map, shell_id)

	socket, daemon_ok := bridge_pty_host_ensure_daemon()
	if !daemon_ok do return
	_ = bridge_pty_host_signal(&Pty_Host_Client{socket = socket}, shell_id, u8(signal))
}

// bridge_hub_handle_shell_set_port handles the "shell_set_port" command (XM-9).
// REQUEST/REPLY: declares (or clears, with server_port 0) the port of a session
// that is already running.
//
// This exists because the bridge keeps its OWN copy of the session and
// bridge_hub_handle_tunnel_open re-validates server_port against that copy, not
// against the hub's row. Updating the hub alone would make the hub authorise a
// dial the bridge then refused with no_server_port. The spec file is re-saved so
// the port also survives a bridge restart, exactly as a start-time port does.
//
// Ownership is NOT re-checked here: the hub settles it before sending, the same
// division of labour tunnel_open uses.
bridge_hub_handle_shell_set_port :: proc(conn: ^ws.Connection, text: string) {
	cmd: Bridge_Shell_Set_Port_Command
	if err := json.unmarshal(transmute([]byte)text, &cmd, allocator = context.temp_allocator); err != nil {
		return
	}
	session_id := cmd.session_id
	command_id := cmd.command_id
	port       := cmd.server_port

	send_result :: proc(conn: ^ws.Connection, session_id, command_id: string, ok: bool, reason: string) {
		res := Bridge_Shell_Set_Port_Result{
			type       = "shell_set_port_result",
			session_id = session_id,
			command_id = command_id,
			ok         = ok,
			error      = bridge_result_error("" if ok else reason, reason),
		}
		if data, err := json.marshal(res, allocator = context.temp_allocator); err == nil {
			if conn != nil do _ = bridge_hub_send(conn, string(data))
		}
	}

	if session_id == "" {
		send_result(conn, session_id, command_id, false, "session_not_found")
		return
	}

	// Same refusal vocabulary the hub and tunnel_open use, so one set of reason
	// strings describes a refusal wherever it is decided.
	sc, found := bridge_shell_session_scalars(&bridge_shell_session_map, session_id)
	if !found {
		send_result(conn, session_id, command_id, false, "session_not_found")
		return
	}
	if sc.status != .Running {
		send_result(conn, session_id, command_id, false, "session_not_running")
		return
	}

	// An OWNED snapshot of the updated record, so the spec re-save below reads memory
	// nothing else can supersede.
	updated, ok := bridge_shell_session_set_server_port(&bridge_shell_session_map, session_id, port)
	if !ok {
		send_result(conn, session_id, command_id, false, "session_not_found")
		return
	}
	defer bridge_shell_session_snapshot_destroy(&bridge_shell_session_map, updated)

	data_dir := bridge_expand_home(bridge_config.data_dir)
	if strings.trim_space(data_dir) == "" do data_dir = bridge_expand_home("~/.local/share/heimdall")
	bridge_shell_session_save_spec(data_dir, updated)

	send_result(conn, session_id, command_id, true, "")
}

// bridge_hub_handle_shell_restart handles the "shell_restart" command.
// REQUEST/REPLY: closes the existing child and re-spawns with same spec.
bridge_hub_handle_shell_restart :: proc(conn: ^ws.Connection, text: string) {
	cmd: Bridge_Shell_Restart_Command
	if err := json.unmarshal(transmute([]byte)text, &cmd, allocator = context.temp_allocator); err != nil {
		return
	}
	session_id := cmd.session_id
	command_id := cmd.command_id
	// REQ-SHELL-4: the run number this session is to carry FROM NOW ON. Adopted only
	// on a SUCCESSFUL respawn (see below), which is what keeps the two sides in step
	// when a restart fails — the hub does not advance its row on a failure either.
	new_run_seq := cmd.run_seq

	send_result :: proc(conn: ^ws.Connection, session_id, command_id: string, ok: bool, pid: int, cause := "shell_restart_failed") {
		res := Bridge_Shell_Restart_Result{
			type       = "shell_restart_result",
			session_id = session_id,
			command_id = command_id,
			ok         = ok,
			pid        = pid if ok else nil,
			error      = bridge_result_error("" if ok else cause, "shell restart failed"),
		}
		if data, err := json.marshal(res, allocator = context.temp_allocator); err == nil {
			if conn != nil do _ = bridge_hub_send(conn, string(data))
		}
	}

	if session_id == "" {
		send_result(conn, session_id, command_id, false, 0)
		return
	}

	// T9: a restart re-executes the stored cmd on the hub's say-so alone, so a Locked
	// bridge must refuse it exactly as it refuses a fresh shell_start. T10: the reply
	// names the reason in error_code so the hub answers a typed 423, not a 500.
	if bridge_vault_status() != .Unlocked {
		fmt.println("bridge shell_restart rejected: vault_locked for session", session_id)
		blog_warn(.vault_locked, blog_sym(.command_kind, .shell_restart))
		send_result(conn, session_id, command_id, false, 0, "vault_locked")
		return
	}

	// A SNAPSHOT: this path needs cmd as well as the daemon key, and it holds both
	// across bridge_pty_host_ensure_daemon, a pty-host close and a fresh spawn.
	sess, ok := bridge_shell_session_snapshot(&bridge_shell_session_map, session_id)
	if !ok {
		send_result(conn, session_id, command_id, false, 0)
		return
	}
	defer bridge_shell_session_snapshot_destroy(&bridge_shell_session_map, sess)

	shell_id := sess.shell_id if sess.shell_id != "" else sess.session_id

	socket, daemon_ok := bridge_pty_host_ensure_daemon()
	if !daemon_ok {
		send_result(conn, session_id, command_id, false, 0)
		return
	}

	// Close the existing child.
	_ = bridge_pty_host_close(socket, shell_id)

	// REQ-SHELL-20: the stored cwd is the caller's spelling, so a restart must resolve
	// it the same way the original start did — spawning the raw value here would hand a
	// literal `~/x` back to portable-pty's silent is_dir filter and restart the session
	// in $HOME. A directory that has since been deleted is refused rather than silently
	// relocated; this path's failure reply carries no message, so the refusal reads as
	// the spawn failure it is.
	cwd_resolved, cwd_verdict := bridge_shell_cwd_resolve(sess.cwd)
	defer delete(cwd_resolved)
	if cwd_verdict != .Ok {
		send_result(conn, session_id, command_id, false, 0)
		return
	}

	// Re-spawn with same cmd/cwd/label. AFTER the cwd check, so the refusal above
	// cannot leak this argv — only `req` has a deferred delete.
	argv := bridge_os_shell_argv(sess.cmd)
	cloned_argv := make([]string, len(argv))
	for a, i in argv { cloned_argv[i] = strings.clone(a) }

	req := Pty_Host_Spawn_Request{
		instance         = strings.clone(shell_id),
		argv             = cloned_argv,
		has_cwd          = cwd_resolved != "",
		cwd              = strings.clone(cwd_resolved),
		env              = sess.kind == .Run ? bridge_shell_run_env() : nil,
		rows             = PTY_HOST_DEFAULT_ROWS,
		cols             = PTY_HOST_DEFAULT_COLS,
		display_name     = strings.clone(sess.label),
		has_display_name = sess.label != "",
	}
	defer bridge_pty_host_spawn_request_delete(req)

	pid, spawn_ok := bridge_pty_host_spawn(socket, req)
	if !spawn_ok {
		send_result(conn, session_id, command_id, false, 0)
		return
	}

	// ADOPT THE NEW RUN NUMBER ONLY NOW, after the spawn succeeded. Every exit this
	// session reports from here on is stamped with it, so the previous run's exits —
	// including the one the close above just produced, and anything still sitting in
	// the durable outbox — carry the OLD number and are discarded hub-side as stale.
	//
	// On any failure path above we returned without touching it, so a restart that did
	// not happen leaves the bridge on the run the hub's row still names.
	// Status first, run number second, so the SNAPSHOT the re-save reads already
	// carries both — one spec write per restart rather than two, and never a spec on
	// disk that names the new run while still claiming the old status.
	bridge_shell_session_update_status(&bridge_shell_session_map, session_id, .Running, 0, false)
	if updated, ok := bridge_shell_session_set_run_seq(&bridge_shell_session_map, session_id, new_run_seq); ok {
		defer bridge_shell_session_snapshot_destroy(&bridge_shell_session_map, updated)
		// PERSISTED, not just held in memory: the spec is what a restarted BRIDGE
		// reloads, and a bridge that came back on the OLD run number would stamp every
		// exit with it and have them all discarded hub-side as stale.
		data_dir := bridge_expand_home(bridge_config.data_dir)
		if strings.trim_space(data_dir) == "" do data_dir = bridge_expand_home("~/.local/share/heimdall")
		bridge_shell_session_save_spec(data_dir, updated)
		bridge_tool_live_shell(updated, true, sess.run_seq)
	}
	send_result(conn, session_id, command_id, true, int(pid))
}

// bridge_hub_handle_shell_list handles the "shell_list" command.
// REQUEST/REPLY: returns the serialized session list.
bridge_hub_handle_shell_list :: proc(conn: ^ws.Connection, text: string) {
	command_id := extract_json_string(text, "command_id", "")
	// DEEP-CLONED: the loop below serializes every string field of every entry, and the
	// old by-value list handed out a borrowed pointer for each one.
	sessions := bridge_shell_session_list_snapshot(&bridge_shell_session_map)
	defer bridge_shell_session_list_destroy(&bridge_shell_session_map, sessions)

	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_list_result\",\"command_id\":\"")
	bridge_runtime_write_json_string(&b, command_id)
	strings.write_string(&b, "\",\"ok\":true,\"sessions\":[")
	for s, i in sessions {
		if i > 0 do strings.write_byte(&b, ',')
		bridge_shell_session_write_json(&b, s)
	}
	strings.write_string(&b, "]}")
	result := strings.to_string(b)
	if conn != nil do _ = bridge_hub_send(conn, result)
	delete(result)
}

// bridge_shell_session_write_json serializes one session to JSON (for shell_list_result).
bridge_shell_session_write_json :: proc(b: ^strings.Builder, s: Bridge_Shell_Session) {
	strings.write_string(b, "{\"session_id\":\"")
	bridge_runtime_write_json_string(b, s.session_id)
	strings.write_string(b, "\",\"kind\":\"")
	bridge_runtime_write_json_string(b, bridge_shell_session_kind_str(s.kind))
	strings.write_string(b, "\",\"label\":\"")
	bridge_runtime_write_json_string(b, s.label)
	strings.write_string(b, "\",\"cmd\":\"")
	bridge_runtime_write_json_string(b, s.cmd)
	strings.write_string(b, "\",\"cwd\":\"")
	bridge_runtime_write_json_string(b, s.cwd)
	strings.write_string(b, "\",\"bridge_id\":\"")
	bridge_runtime_write_json_string(b, s.bridge_id)
	strings.write_string(b, "\",\"project_id\":\"")
	bridge_runtime_write_json_string(b, s.project_id)
	strings.write_string(b, "\",\"chain_id\":\"")
	bridge_runtime_write_json_string(b, s.chain_id)
	strings.write_string(b, "\",\"agent_instance_id\":\"")
	bridge_runtime_write_json_string(b, s.agent_instance_id)
	strings.write_string(b, "\",\"owner_user_id\":\"")
	bridge_runtime_write_json_string(b, s.owner_user_id)
	strings.write_string(b, "\",\"pid\":")
	bridge_agent_write_int(b, s.pid)
	strings.write_string(b, ",\"server_port\":")
	bridge_agent_write_int(b, s.server_port)
	strings.write_string(b, ",\"status\":\"")
	bridge_runtime_write_json_string(b, bridge_shell_session_status_str(s.status))
	strings.write_string(b, "\",\"exit_code\":")
	bridge_agent_write_int(b, s.exit_code)
	strings.write_string(b, ",\"exit_code_set\":")
	strings.write_string(b, "true" if s.exit_code_set else "false")
	strings.write_string(b, ",\"started_at\":\"")
	bridge_runtime_write_json_string(b, s.started_at)
	strings.write_string(b, "\",\"finished_at\":\"")
	bridge_runtime_write_json_string(b, s.finished_at)
	strings.write_string(b, "\",\"shell_id\":\"")
	bridge_runtime_write_json_string(b, s.shell_id)
	strings.write_string(b, "\"}")
}

// bridge_hub_handle_shell_logs handles the "shell_logs" command.
// REQUEST/REPLY: reads lines from the session tee_path with optional paging and grep.
bridge_hub_handle_shell_logs :: proc(conn: ^ws.Connection, text: string) {
	cmd: Bridge_Shell_Logs_Command
	cmd.limit = BRIDGE_SHELL_TAIL_KEEP
	if err := json.unmarshal(transmute([]byte)text, &cmd, allocator = context.temp_allocator); err != nil {
		// Proceed; if session_id is empty, send_error below handles it
	}
	session_id := cmd.session_id
	command_id := cmd.command_id
	offset     := cmd.offset
	limit      := cmd.limit if cmd.limit > 0 else BRIDGE_SHELL_TAIL_KEEP
	grep       := cmd.grep

	send_error :: proc(conn: ^ws.Connection, session_id, command_id, cause, msg: string) {
		bridge_shell_send_error(conn, "shell_logs_result", session_id, command_id, cause, msg, "\"lines\":[],\"truncated\":false,\"total_lines\":0,")
	}

	if session_id == "" {
		send_error(conn, session_id, command_id, "missing_session_id", "missing session_id")
		return
	}

	// DISK, NOT THE MAP, DECIDES. This used to require the session in the map and
	// answer "session not found" otherwise, which made the 5-day window unreachable
	// across a bridge restart: a terminal session's spec is deleted when it ends, so
	// after a restart NOTHING terminal is in the map, and a hub row still well inside
	// its own (longer) retention would be told its session never existed. The hub has
	// already authorised the caller against that row — an owner-scoped lookup in
	// shell_session_get, before this command is ever sent — so the map lookup was
	// never an access control and dropping it grants nothing.
	//
	// The precedence is exactly three-way, and the last branch matters as much as the
	// first two: an id that never ran here, or whose tombstone has itself aged out
	// after 30 days, stays genuinely not_found. Retention must not turn every unknown
	// id into "reclaimed" — that is the same class of wrong answer as the silent-empty
	// behaviour this replaces.
	output_str, out_state := bridge_shell_output_read(session_id)
	defer if out_state == .Available do delete(output_str)
	switch out_state {
	case .Reclaimed:
		// Explicitly allocated and freed rather than temp-allocated: this runs on the
		// long-lived hub WS handler, which never reclaims a temp arena, so anything
		// left there would accumulate for the life of the bridge.
		bridge_shell_send_error(conn, "shell_logs_result", session_id, command_id, BRIDGE_SHELL_OUTPUT_RECLAIMED_CODE, BRIDGE_SHELL_OUTPUT_RECLAIMED_MESSAGE, "\"lines\":[],\"truncated\":false,\"total_lines\":0,")
		return
	case .Absent:
		// No output file and no tombstone. A session the map still knows has simply
		// not written its first byte yet and gets an honest empty log; one the map
		// does not know either never existed here at all.
		if !bridge_shell_session_exists(&bridge_shell_session_map, session_id) {
			send_error(conn, session_id, command_id, "session_not_found", "session not found")
			return
		}
	case .Available:
		// Served below — including a zero-byte file, which is a real empty log.
	}

	// SANITISE FIRST — BEFORE counting, BEFORE grep, BEFORE offset/limit (REQ-SHELL-27).
	// The ordering IS the requirement, not a tidiness preference:
	//   - `--grep error` must match a word the compiler wrapped in SGR red. Against raw
	//     text it cannot, and that is a silent wrong ANSWER, not a cosmetic blemish.
	//   - total_lines and offset/limit must count the lines a human sees, so CRLF and
	//     bare-\r progress redraws have to be resolved before anything counts them.
	//   - a limit boundary must not be able to land mid-escape and emit `[0;32m`.
	// Read-time only: bridge_shell_output_read's string is a copy, the tee file on disk
	// keeps the raw bytes, and nothing here writes back (AC5).
	//
	// NOT gated on session kind, deliberately. What is protected is the TRANSPORT, not
	// the kind: this command answers with a JSON array of text lines that no one renders
	// into a terminal. The live terminal is served by bridge_hub_handle_shell_capture and
	// bridge_hub_handle_shell_get_pane, which are untouched and must stay byte-exact. A
	// `shell` is tee'd like any other kind (see the unconditional tee_path at the spawn
	// site), so gating would only ever mis-serve someone reading an interactive session's
	// scrollback back as text.
	sanitized := bridge_shell_sanitize_output(output_str)
	defer delete(sanitized)

	total_lines := 0
	for i in 0..<len(sanitized) { if sanitized[i] == '\n' do total_lines += 1 }

	lines_str, truncated := bridge_shell_page(sanitized, offset, limit, grep)
	defer delete(lines_str)

	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_logs_result\",\"session_id\":\"")
	bridge_runtime_write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"command_id\":\"")
	bridge_runtime_write_json_string(&b, command_id)
	strings.write_string(&b, "\",\"ok\":true,\"lines\":[")
	start := 0
	first := true
	for i := 0; i <= len(lines_str); i += 1 {
		if i == len(lines_str) || lines_str[i] == '\n' {
			line := lines_str[start:i]
			if !first do strings.write_byte(&b, ',')
			first = false
			strings.write_byte(&b, '"')
			bridge_runtime_write_json_string(&b, line)
			strings.write_byte(&b, '"')
			start = i + 1
		}
	}
	strings.write_string(&b, "],\"truncated\":")
	strings.write_string(&b, "true" if truncated else "false")
	strings.write_string(&b, ",\"total_lines\":")
	bridge_agent_write_int(&b, total_lines)
	strings.write_string(&b, "}")
	result := strings.to_string(b)
	if conn != nil do _ = bridge_hub_send(conn, result)
	delete(result)
}

// bridge_hub_handle_shell_get_pane handles the "shell_get_pane" command (REQ-PTY-STREAM-1).
// This is the shell-session twin of bridge_hub_handle_get_agent_pane: same polled-capture
// model, same since_hash diffing, same command_result shape — the only shell-specific part
// is resolving session_id to the pty-host instance key. A shell session IS a pty-host
// instance keyed by its shell_id, with the session_id fallback the T4 registration and the
// BUG-7 reconcile both use, so bridge_pty_host_get_pane is reused verbatim and no new
// pty-host primitive is introduced.
//
// Deliberately distinct from "shell_capture": that command's {content,rows,cols} reply is a
// shipped contract consumed by ham-ctl and GET /shells/*/capture, and it runs on a 30s hub
// timeout. This one is polled twice a second, so it carries the pane shape instead.
bridge_hub_handle_shell_get_pane :: proc(conn: ^ws.Connection, text: string) {
	cmd := bridge_pty_command_decode(text)
	command_id := cmd.command_id
	if cached, ok := bridge_runtime_cached_command(command_id); ok {
		_ = bridge_hub_send(conn, cached)
		return
	}

	session_id := cmd.session_id
	since_hash := cmd.since_hash
	width := bridge_json_positive_int(cmd.width, 80)
	line_limit := bridge_json_positive_int(cmd.line_limit, 120)

	send_failure :: proc(conn: ^ws.Connection, command_id, msg: string) {
		result := bridge_get_agent_pane_result_json(command_id, false, false, "", "", 0, false, 0, 0, msg)
		defer delete(result)
		bridge_runtime_cache_command(command_id, result)
		_ = bridge_hub_send(conn, result)
	}

	if session_id == "" {
		send_failure(conn, command_id, "missing session_id")
		return
	}

	shell_id, ok := bridge_shell_session_shell_id(&bridge_shell_session_map, session_id)
	if !ok {
		send_failure(conn, command_id, "session not found")
		return
	}
	defer bridge_shell_session_str_delete(&bridge_shell_session_map, shell_id)

	pane_ok, unchanged, h, output, line_count, truncated, cursor_row, cursor_col, err_msg := bridge_pty_host_get_pane(shell_id, since_hash, line_limit, width)
	defer if h != "" do delete(h)
	defer if output != "" do delete(output)

	result := bridge_get_pane_reply_json(command_id, session_id, pane_ok, unchanged, h, output, line_count, truncated, cursor_row, cursor_col, err_msg)
	defer delete(result)
	bridge_runtime_cache_command(command_id, result)
	_ = bridge_hub_send(conn, result)
}

// bridge_shell_capture_seal seals a shell screen capture (empty stays empty).
bridge_shell_capture_seal :: proc(plain: string) -> (armored: string, res: Bridge_Pane_Seal) {
	status, kr := bridge_vault_status_and_key()
	defer vault.keyring_wipe(&kr)
	return bridge_shell_capture_seal_with(status, &kr, plain)
}

// bridge_shell_capture_seal_with is the pure core (tests pass the state in).
bridge_shell_capture_seal_with :: proc(status: Vault_Status, kr: ^vault.Vault_Keyring, plain: string, allocator := context.allocator) -> (armored: string, res: Bridge_Pane_Seal) {
	if status != .Unlocked do return "", .Locked
	if plain == "" do return strings.clone("", allocator), .Sealed
	tok, ok := vault.seal_string(plain, kr, allocator)
	if !ok do return "", .Failed
	return tok, .Sealed
}

// bridge_hub_handle_shell_capture handles the "shell_capture" command.
// REQUEST/REPLY: returns a pty screen snapshot for the session.
bridge_hub_handle_shell_capture :: proc(conn: ^ws.Connection, text: string) {
	session_id := extract_json_string(text, "session_id", "")
	command_id := extract_json_string(text, "command_id", "")

	send_error :: proc(conn: ^ws.Connection, session_id, command_id, cause, msg: string) {
		bridge_shell_send_error(conn, "shell_capture_result", session_id, command_id, cause, msg, "\"content\":\"\",\"rows\":0,\"cols\":0,")
	}

	if session_id == "" {
		send_error(conn, session_id, command_id, "missing_session_id", "missing session_id")
		return
	}

	shell_id, ok := bridge_shell_session_shell_id(&bridge_shell_session_map, session_id)
	if !ok {
		send_error(conn, session_id, command_id, "session_not_found", "session not found")
		return
	}
	defer bridge_shell_session_str_delete(&bridge_shell_session_map, shell_id)

	socket, daemon_ok := bridge_pty_host_ensure_daemon()
	if !daemon_ok {
		send_error(conn, session_id, command_id, "pty_host_unreachable", "daemon unavailable")
		return
	}

	frame := pty_host_encode_capture(shell_id)
	defer delete(frame)
	reply, rok := pty_host_request(socket, frame)
	if !rok || reply.kind != .Screen {
		if rok do pty_host_reply_delete(reply)
		send_error(conn, session_id, command_id, "capture_failed", "capture failed")
		return
	}
	defer pty_host_reply_delete(reply)

	plain, _, _ := bridge_pty_host_screen_to_output(reply.screen.lines, 0)
	defer {
		crypto.zero_explicit(raw_data(plain), len(plain))
		delete(plain)
	}
	// The screen is sealed as a v2 content envelope under the current epoch, like the
	// pane captures: a locked vault or a seal failure is an error, never plaintext.
	content, cres := bridge_shell_capture_seal(plain)
	switch cres {
	case .Locked:
		send_error(conn, session_id, command_id, "vault_locked", "bridge vault is locked; the screen cannot be sent")
		return
	case .Failed:
		send_error(conn, session_id, command_id, "encryption_failed", "could not seal the screen capture")
		return
	case .Sealed:
	}
	defer delete(content)

	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_capture_result\",\"session_id\":\"")
	bridge_runtime_write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"command_id\":\"")
	bridge_runtime_write_json_string(&b, command_id)
	strings.write_string(&b, "\",\"ok\":true,\"content\":\"")
	bridge_runtime_write_json_string(&b, content)
	strings.write_string(&b, "\",\"rows\":")
	bridge_agent_write_int(&b, int(reply.screen.rows))
	strings.write_string(&b, ",\"cols\":")
	bridge_agent_write_int(&b, int(reply.screen.cols))
	strings.write_string(&b, ",\"cursor_row\":")
	bridge_agent_write_int(&b, int(reply.screen.cursor_row))
	strings.write_string(&b, ",\"cursor_col\":")
	bridge_agent_write_int(&b, int(reply.screen.cursor_col))
	strings.write_string(&b, "}")
	result := strings.to_string(b)
	if conn != nil do _ = bridge_hub_send(conn, result)
	delete(result)
}

bridge_hub_ws_url :: proc(base_url: string) -> string {
	trimmed := bridge_hub_base_url_for_runtime(base_url)
	if strings.has_prefix(trimmed, "http://") do return strings.concatenate({"ws://", trimmed[len("http://"):], "/api/v1/bridge-ws"})
	if strings.has_prefix(trimmed, "https://") do return strings.concatenate({"wss://", trimmed[len("https://"):], "/api/v1/bridge-ws"})
	return ""
}

bridge_hub_base_url_for_runtime :: proc(base_url: string) -> string {
	return strings.trim_right(strings.trim_space(base_url), "/")
}

bridge_hub_runtime_start :: proc() {
	bridge_hub_runtime_init()
	// REQ-SHELL-4: pick up exits this bridge queued before it was restarted, so the
	// hub converges on the next connect rather than showing those sessions running
	// forever. Must follow init (it appends to the queue init makes) and precede the
	// worker that drains it.
	bridge_shell_exited_outbox_restore()
	credential_snapshot_5593 := bridge_credential_snapshot()
	defer delete(credential_snapshot_5593)
	if strings.trim_space(credential_snapshot_5593) != "" && strings.trim_space(bridge_config.daemon_url) != "" {
		thread.run(bridge_hub_runtime_worker)
	}
}

// ---- T8: preview tunnel frame handlers (REQ-SH-CONTRACT §6) ----

// bridge_tunnel_data_drain_outgoing flushes queued tunnel_data/tunnel_close WS frames.
bridge_tunnel_data_drain_outgoing :: proc(conn: ^ws.Connection) {
	sync.mutex_lock(&bridge_runtime_mutex)
	if len(bridge_tunnel_data_outgoing) == 0 {
		sync.mutex_unlock(&bridge_runtime_mutex)
		return
	}
	items := bridge_tunnel_data_outgoing[:]
	bridge_tunnel_data_outgoing = make([dynamic]Bridge_Tunnel_Data_Outgoing, runtime.heap_allocator())
	sync.mutex_unlock(&bridge_runtime_mutex)
	for item in items {
		_ = ws.send_text(conn, item.json)
		delete(item.json)
	}
	delete(items)
}

// bridge_preview_dial_loopback connects to a preview server without ever leaving the
// loopback interface. IPv4 remains the preferred path; IPv6 is tried only when the
// IPv4 connection fails.
bridge_preview_dial_loopback :: proc(port: int) -> (net.TCP_Socket, bool) {
	tcp_conn, dial_err := net.dial_tcp_from_address_and_port(net.IP4_Loopback, port)
	if dial_err == nil {
		return tcp_conn, true
	}

	tcp_conn, dial_err = net.dial_tcp_from_address_and_port(net.IP6_Loopback, port)
	if dial_err == nil {
		return tcp_conn, true
	}

	return net.TCP_Socket(0), false
}

// bridge_hub_handle_tunnel_open handles a tunnel_open command from the hub.
// Validates session ownership, dials loopback:{server_port}, and starts the TCP→WS pump.
bridge_hub_handle_tunnel_open :: proc(conn: ^ws.Connection, text: string) {
	stream_id  := extract_json_string(text, "stream_id", "")
	session_id := extract_json_string(text, "session_id", "")
	defer { if stream_id == "" do delete(stream_id); if session_id == "" do delete(session_id) }

	_send_tunnel_close :: proc(conn: ^ws.Connection, stream_id, reason: string) {
		b := strings.builder_make()
		strings.write_string(&b, "{\"type\":\"tunnel_close\",\"stream_id\":\"")
		bridge_runtime_write_json_string(&b, stream_id)
		strings.write_string(&b, "\",\"reason\":\"")
		bridge_runtime_write_json_string(&b, reason)
		strings.write_string(&b, "\"}")
		frame := strings.to_string(b)
		_ = ws.send_text(conn, frame)
		delete(frame)
	}

	if stream_id == "" || session_id == "" {
		return
	}

	// Security: validate the session is Running and has a declared server_port.
	// XM-8: kind is deliberately not checked.  A session that declared a port at start is
	// reachable whatever its kind, so an interactive shell started with --port 3000 works.
	// The two properties that actually fence this path are unchanged: the port comes from
	// the session record (never the request) and the dial below is loopback-only.
	session, found := bridge_shell_session_scalars(&bridge_shell_session_map, session_id)
	if !found || session.status != .Running || session.server_port <= 0 {
		// XM-8: these are PRECONDITIONS, not an authorisation decision — ownership is
		// settled in the hub before tunnel_open is ever sent, and kind is no longer part
		// of the test.  "forbidden" would now name the wrong thing, so each cause reports
		// itself using the hub's existing vocabulary (bridge_proxy_authorise_target), so
		// that one set of reason strings describes a refusal end to end.
		reason := "session_not_found"
		if found && session.status != .Running {
			reason = "session_not_running"
		} else if found {
			reason = "no_server_port"
		}
		_send_tunnel_close(conn, stream_id, reason)
		delete(stream_id)
		delete(session_id)
		return
	}

	// Security: only dial IPv4 or IPv6 loopback.
	tcp_conn, connected := bridge_preview_dial_loopback(session.server_port)
	if !connected {
		_send_tunnel_close(conn, stream_id, "port_closed")
		delete(stream_id)
		delete(session_id)
		return
	}

	// FD OWNERSHIP (see AGENTS.md, "Socket lifetime across threads"): the worker spawned
	// below is the SOLE closer of tcp_conn.  The receive timeout is its backstop wake — if a
	// teardown path ever forgets the shutdown, the worker still wakes within one period,
	// sees its stream unregistered and exits, instead of leaking a thread that pins an
	// orphaned socket forever.
	//
	// Set here, BEFORE the stream is registered, deliberately.  Registering publishes the
	// struct to bridge_hub_handle_tunnel_close, which may free it; anything done between
	// that publish and the worker taking its stack copies widens an existing window in
	// which the worker can dereference freed memory.  This needs only the local handle, so
	// it belongs on this side of the publish.
	_ = net.set_option(tcp_conn, .Receive_Timeout, BRIDGE_TUNNEL_RECV_TIMEOUT)

	// Register stream.
	heap := runtime.heap_allocator()
	stream := new(Bridge_Tunnel_Stream, heap)
	stream.stream_id  = stream_id  // ownership transferred
	stream.session_id = session_id // ownership transferred
	stream.tcp_conn   = tcp_conn
	stream.closed     = false

	sync.mutex_lock(&bridge_tunnel_mu)
	bridge_tunnel_streams[strings.clone(stream_id, heap)] = stream
	sync.mutex_unlock(&bridge_tunnel_mu)

	// Start TCP→WS pump on a background thread.
	thread.run_with_data(rawptr(stream), bridge_tunnel_tcp_to_ws_worker)
}

// BRIDGE_TUNNEL_RECV_TIMEOUT is the tunnel reader's periodic wake.  It is a backstop, not
// the mechanism: shutdown(.Receive) wakes a parked recv in tens of microseconds (measured),
// so this only matters on a path that forgot to shut down, or a platform where SHUT_RD does
// not wake a blocked reader.  Long enough to be free on an idle tunnel, short enough that a
// missed shutdown costs seconds rather than the process lifetime.
BRIDGE_TUNNEL_RECV_TIMEOUT :: 5 * time.Second

// bridge_tunnel_stream_registered reports whether a stream_id is still in the table.
//
// The tunnel reader uses this on a timeout wake to ask "has teardown already happened?"
// WITHOUT dereferencing its ^Bridge_Tunnel_Stream, which a concurrent teardown may already
// have freed.  Compares by value against the independent map keys for exactly the reason
// the probe pattern exists: the key is owned by the table, the struct is not.
bridge_tunnel_stream_registered :: proc(stream_id: string) -> bool {
	sync.mutex_lock(&bridge_tunnel_mu)
	defer sync.mutex_unlock(&bridge_tunnel_mu)
	for k in bridge_tunnel_streams {
		if k == stream_id do return true
	}
	return false
}

// bridge_tunnel_tcp_to_ws_worker reads from the TCP socket and enqueues tunnel_data frames.
// When the TCP connection closes, it enqueues a tunnel_close frame and removes the stream.
//
// TWO RESOURCES, TWO DIFFERENT OWNERS.  Getting these confused is the bug this file has
// produced repeatedly; see AGENTS.md, "Socket lifetime across threads" for the full rule.
//
// MEMORY — the independent-key probe.  Capture tcp_conn and stream_id as stack-locals at
// entry so the recv loop and teardown never dereference 'stream' after
// bridge_hub_handle_tunnel_close may have freed it.  Whoever removes the map key is the sole
// freer; the loser finds the key absent and returns without touching the struct pointer.
//
// THE FD — NOT covered by that probe, and it must not be.  THIS THREAD is the sole closer
// of the socket, on every exit path, whether or not it won the key race.  Teardown on the
// WS-reader thread only shutdown(.Receive)s to wake us; it must never net.close.  Two
// reasons, both measured:
//   - close() cannot unblock a recv that is already parked: the parked recv holds the
//     struct file, so the socket is merely orphaned and this thread would sleep forever.
//     That leaked one thread per teardown, unbounded, and pinned each orphaned socket.
//   - if this thread is instead BETWEEN recv calls (in the base64/JSON section below) when
//     the close lands, its next recv_tcp re-resolves the fd NUMBER, which a new connection
//     may already own — and we would forward a stranger's bytes as tunnel_data under this
//     dead stream_id.
// Deciding the close by 'did I win the key race' is what made the fd leak possible, so the
// close below is deliberately unconditional and sits outside that branch.
bridge_tunnel_tcp_to_ws_worker :: proc(data: rawptr) {
	stream := (^Bridge_Tunnel_Stream)(data)
	heap := runtime.heap_allocator()
	// Local copies — valid for this goroutine's entire lifetime regardless of struct free.
	local_tcp_conn  := stream.tcp_conn
	local_stream_id := strings.clone(stream.stream_id, heap)

	// 32 KB chunk size: 8x reduction in WS frames compared to 4 KB, comfortably
	// under the 65,535-byte WebSocket frame ceiling after base64 expansion (~43.7 KB).
	buf: [32768]byte
	for {
		if sync.atomic_load(&bridge_hub_traffic_stopped) do break
		n, recv_err := net.recv_tcp(local_tcp_conn, buf[:])
		// A receive timeout is a periodic wake, NOT end-of-stream.  core:net reports a
		// graceful close as (0, nil), so the plain `n <= 0` test below cannot tell the two
		// apart and would tear down a live idle tunnel once per period.  On a timeout,
		// exit only if teardown has already unregistered us — checked via the stream_id,
		// never by dereferencing 'stream'.
		if recv_err == .Timeout || recv_err == .Would_Block {
			if !bridge_tunnel_stream_registered(local_stream_id) do break
			continue
		}
		if recv_err != nil || n <= 0 do break
		encoded := base64.encode(buf[:n])
		b := strings.builder_make(heap)
		strings.write_string(&b, "{\"type\":\"tunnel_data\",\"stream_id\":\"")
		bridge_runtime_write_json_string(&b, local_stream_id)
		strings.write_string(&b, "\",\"data_b64\":\"")
		bridge_runtime_write_json_string(&b, string(encoded))
		strings.write_string(&b, "\",\"last\":false}")
		frame := strings.to_string(b)
		delete(encoded)
		sync.mutex_lock(&bridge_runtime_mutex)
		append(&bridge_tunnel_data_outgoing, Bridge_Tunnel_Data_Outgoing{json = frame})
		sync.mutex_unlock(&bridge_runtime_mutex)
	}

	// TCP closed — enqueue tunnel_close to hub.
	b2 := strings.builder_make(heap)
	strings.write_string(&b2, "{\"type\":\"tunnel_close\",\"stream_id\":\"")
	bridge_runtime_write_json_string(&b2, local_stream_id)
	strings.write_string(&b2, "\",\"reason\":\"connection_closed\"}")
	close_frame := strings.to_string(b2)
	sync.mutex_lock(&bridge_runtime_mutex)
	append(&bridge_tunnel_data_outgoing, Bridge_Tunnel_Data_Outgoing{json = close_frame})
	sync.mutex_unlock(&bridge_runtime_mutex)

	// Independent-key probe: whoever removes the map key owns the struct free.
	// If !found, bridge_hub_handle_tunnel_close already removed+freed the struct —
	// we must not dereference 'stream' at all in that path.
	sync.mutex_lock(&bridge_tunnel_mu)
	found := false
	for k in bridge_tunnel_streams {
		if k == local_stream_id {
			delete_key(&bridge_tunnel_streams, k)
			delete(k)
			found = true
			break
		}
	}
	sync.mutex_unlock(&bridge_tunnel_mu)

	// THE FD: unconditional, and deliberately before the memory branch.  This thread is the
	// only closer; no other thread can be blocked reading this socket, because no other
	// thread ever reads it.  Doing this inside `if found` would leak the fd on exactly the
	// path where teardown won the key race.
	net.close(local_tcp_conn)

	// MEMORY: only the key-race winner frees the struct.
	if found {
		delete(stream.stream_id, heap)
		delete(stream.session_id, heap)
		free(stream, heap)
	}
	delete(local_stream_id, heap)
}

// bridge_hub_handle_tunnel_data writes hub→bridge request bytes to the TCP socket.
bridge_hub_handle_tunnel_data :: proc(text: string) {
	stream_id := extract_json_string(text, "stream_id", "")
	data_b64  := extract_json_string(text, "data_b64", "")
	defer { delete(stream_id); delete(data_b64) }

	if stream_id == "" || data_b64 == "" do return

	decoded, decode_err := base64.decode(data_b64)
	if decode_err != nil || len(decoded) == 0 {
		delete(decoded)
		return
	}
	defer delete(decoded)

	// Hold bridge_tunnel_mu across the send so the worker cannot free the struct
	// between the map lookup and the net.send_tcp dereference of stream.tcp_conn.
	sync.mutex_lock(&bridge_tunnel_mu)
	if stream, ok := bridge_tunnel_streams[stream_id]; ok {
		_, _ = net.send_tcp(stream.tcp_conn, decoded)
	}
	sync.mutex_unlock(&bridge_tunnel_mu)
}

// bridge_hub_handle_tunnel_close retires a tunnel stream on the WS-reader thread.
//
// It does NOT close the socket.  bridge_tunnel_tcp_to_ws_worker owns that fd for its whole
// life (see the rule in its doc comment, and AGENTS.md "Socket lifetime across threads");
// all this does is shutdown(.Receive) to wake the worker out of recv so it can run its own
// exit path and close.  Waking is enough and does not block: the worker is not joined here
// on purpose, because this runs on the WS reader and must not stall the whole hub
// connection waiting on one local socket.
bridge_hub_handle_tunnel_close :: proc(text: string) {
	stream_id := extract_json_string(text, "stream_id", "")
	defer delete(stream_id)

	if stream_id == "" do return

	heap := runtime.heap_allocator()
	sync.mutex_lock(&bridge_tunnel_mu)
	stream, ok := bridge_tunnel_streams[stream_id]
	if ok {
		for k in bridge_tunnel_streams {
			if k == stream_id {
				delete_key(&bridge_tunnel_streams, k)
				delete(k)
				break
			}
		}
	}
	sync.mutex_unlock(&bridge_tunnel_mu)

	// Only free if we removed the key. If !ok the worker already removed+freed the struct.
	if !ok do return

	// THE FD: wake the reader, do not close.  shutdown(.Receive) on a still-open fd makes a
	// parked recv return (0, nil) immediately; the worker then closes.  Ordered before the
	// free only for clarity — the worker reads its own stack copy of the handle, never this
	// struct, so it is already safe against the free below.
	net.shutdown(stream.tcp_conn, .Receive)

	// MEMORY: we removed the key, so the struct is ours to free.
	delete(stream.stream_id, heap)
	delete(stream.session_id, heap)
	free(stream, heap)
}
