package main

// BR-2: bridge spawns/controls agents via ham-pty-host instead of tmux.
//
// This is the high-level runtime layer that sits on top of the wire client
// (pty_host_client.odin) and the pre-spawn materializer (BR-1,
// bootstrap_prespawn.odin). It:
//
//   * lazily starts the per-machine ham-pty-host daemon (one per bridge, keyed on
//     the bridge's local endpoint socket dir),
//   * builds a Spawn request from a provider profile (argv + cwd=run_dir + the
//     HEIMDALL_* env from BR-1 + the resolved startup-detection JSON),
//   * maps the bridge's lifecycle ops onto the daemon control plane:
//       launch/relaunch -> host.spawn (or host.restart when already registered)
//       stop            -> host.close
//   * is gated behind a runtime flag (bridge_config.pty_host_runtime) so the tmux
//     path stays the default until DEL-1 flips it — this is the A/B switch.
//
// Event subscription (ChildExited -> status, StartupReady/Blocked/ScreenChanged)
// is layered on in BR-3; BR-2 wires the control plane + a ChildExited-to-status
// mapping helper the subscriber will call.

import local_socket "odin_test:lib/local_socket"
import "base:runtime"
import crypto_hash "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

// Retry/backoff for a spawn that races daemon startup (AC-5 parity with the tmux
// launch path): the daemon may not be accepting connections the instant after we
// start it, so a spawn retries a few times with a short backoff.
PTY_HOST_SPAWN_MAX_ATTEMPTS :: 5
PTY_HOST_SPAWN_BASE_BACKOFF_MS :: 100

// Default VT geometry for a freshly spawned agent pane.
PTY_HOST_DEFAULT_ROWS :: 25
PTY_HOST_DEFAULT_COLS :: 80

// ---- runtime flag -------------------------------------------------------

// bridge_pty_host_runtime_enabled reports whether the bridge should drive agents
// DEL-1: ham-pty-host is now the ONLY agent-launch runtime — the tmux/ham-wrapper
// agent-launch path has been removed. This always returns true; the config flag
// and env override are retained as no-op compatibility shims (a "0"/"false" no
// longer re-enables the deleted tmux path). Kept as a proc so the remaining
// per-command call sites and tests compile unchanged.
bridge_pty_host_runtime_enabled :: proc() -> bool {
	return true
}

bridge_pty_host_truthy :: proc(v: string) -> bool {
	switch strings.to_lower(strings.trim_space(v)) {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}

// ---- daemon lazy-start --------------------------------------------------

pty_host_daemon_started: bool
pty_host_daemon_socket:  string
pty_host_daemon_lock:    sync.Mutex

// REQ-BR-4: the daemon process THIS bridge started, kept so it can be reaped and, if
// it is still alive when its socket stops answering, retired before a replacement is
// started. Dropping the handle is how a wedged daemon (listener dead, process alive)
// came to run alongside its replacement: two daemons, the old one still holding the
// event connection and every run it had spawned. Guarded by pty_host_daemon_lock.
pty_host_daemon_process:     os.Process
pty_host_daemon_has_process: bool

// How long a retiring daemon gets after SIGTERM before SIGKILL, and after SIGKILL
// before we give up waiting on it.
PTY_HOST_DAEMON_TERM_GRACE :: 3 * time.Second
PTY_HOST_DAEMON_KILL_GRACE :: 2 * time.Second

// REQ-BR-3: bumped every time ensure_daemon starts a daemon process. The event watcher
// records it when it dials and re-dials when it moves, so it can never stay attached to
// a daemon the bridge has replaced. Read/written atomically.
pty_host_daemon_generation: u64

// Pty_Host_Daemon_Identity identifies the daemon currently BOUND to the socket path,
// whoever started it: a daemon binds by unlink + bind, which creates a new socket
// inode with a fresh ctime. Comparing inode AND ctime (not inode alone) matters because
// a filesystem may hand the unlinked inode number straight back to the new socket.
Pty_Host_Daemon_Identity :: struct {
	dev:        u64,
	ino:        u64,
	ctime_sec:  i64,
	ctime_nsec: i64,
}

// bridge_pty_host_daemon_identity stats the socket path. ok=false when nothing is there.
bridge_pty_host_daemon_identity :: proc(socket: string) -> (Pty_Host_Daemon_Identity, bool) {
	return bridge_os_socket_file_identity(strings.trim_prefix(socket, "unix:"))
}

// bridge_pty_host_daemon_process_running reports whether the daemon process this
// bridge started is still running, without blocking. An exited one is reaped (it is
// our child; left alone it would stay a zombie) and forgotten, as is one we cannot
// wait on at all.
bridge_pty_host_daemon_process_running :: proc(p: ^os.Process, has: ^bool) -> bool {
	if !has^ do return false
	_, err := os.process_wait(p^, 0)
	if err == os.General_Error.Timeout do return true
	// nil: it exited and was reaped just now. Anything else (ECHILD): not ours to wait
	// on. Either way process_wait has already closed the handle — closing it again
	// could close an unrelated fd that reused the number.
	has^ = false
	return false
}

// bridge_pty_host_retire_daemon_process makes sure the daemon process this bridge
// started is gone before another is started (REQ-BR-4). An exited one is just reaped.
// A live one is a daemon whose socket stopped answering — never leave it running beside
// a replacement: SIGTERM, wait, SIGKILL, wait. Returns false only if it survived both,
// in which case the caller must not start another. Caller holds pty_host_daemon_lock.
bridge_pty_host_retire_daemon_process :: proc(p: ^os.Process, has: ^bool, term_grace := PTY_HOST_DAEMON_TERM_GRACE, kill_grace := PTY_HOST_DAEMON_KILL_GRACE) -> bool {
	if !bridge_pty_host_daemon_process_running(p, has) do return true
	fmt.eprintln("bridge pty-host: the daemon this bridge started (pid", p.pid, ") is ALIVE but not answering on its socket; terminating it before starting a replacement so two daemons never run at once")
	blog_error(.pty_host_unreachable, blog_sym(.stage, .ready))
	_ = os.process_terminate(p^)
	if _, err := os.process_wait(p^, term_grace); err == nil {
		has^ = false
		return true
	}
	fmt.eprintln("bridge pty-host: daemon pid", p.pid, "ignored SIGTERM; sending SIGKILL")
	_ = os.process_kill(p^)
	if _, err := os.process_wait(p^, kill_grace); err == nil {
		has^ = false
		return true
	}
	fmt.eprintln("bridge pty-host: daemon pid", p.pid, "survived SIGKILL; NOT starting a replacement")
	return false
}

// The delivery path receives only an instance id, so retain the provider chosen
// while assembling that instance's spawn request. This store uses the process
// heap explicitly: both strings outlive the request allocator (which is a
// per-test tracking allocator in the test suite).
pty_host_instance_provider_lock: sync.Mutex
pty_host_instance_providers:     map[string]string

bridge_pty_host_track_instance_provider :: proc(instance, provider: string) {
	if strings.trim_space(instance) == "" do return
	heap := runtime.heap_allocator()
	sync.mutex_lock(&pty_host_instance_provider_lock)
	defer sync.mutex_unlock(&pty_host_instance_provider_lock)
	if pty_host_instance_providers == nil {
		pty_host_instance_providers = make(map[string]string, allocator = heap)
	}
	if old_provider, exists := pty_host_instance_providers[instance]; exists {
		for old_key in pty_host_instance_providers {
			if old_key == instance {
				delete_key(&pty_host_instance_providers, old_key)
				delete(old_key, heap)
				break
			}
		}
		delete(old_provider, heap)
	}
	pty_host_instance_providers[strings.clone(instance, heap)] = strings.clone(provider, heap)
}

bridge_pty_host_untrack_instance_provider :: proc(instance: string) {
	heap := runtime.heap_allocator()
	sync.mutex_lock(&pty_host_instance_provider_lock)
	defer sync.mutex_unlock(&pty_host_instance_provider_lock)
	if pty_host_instance_providers == nil do return
	provider, exists := pty_host_instance_providers[instance]
	if !exists do return
	for key in pty_host_instance_providers {
		if key == instance {
			delete_key(&pty_host_instance_providers, key)
			delete(key, heap)
			break
		}
	}
	delete(provider, heap)
}

bridge_pty_host_instance_wants_bracketed_paste :: proc(instance: string) -> bool {
	sync.mutex_lock(&pty_host_instance_provider_lock)
	defer sync.mutex_unlock(&pty_host_instance_provider_lock)
	if pty_host_instance_providers == nil do return false
	provider, exists := pty_host_instance_providers[instance]
	return exists && provider == "codex"
}

// bridge_pty_host_bin resolves the ham-pty-host binary: the HEIMDALL_HAM_PTY_HOST_BIN
// env override (set by the flake app to the matching build) wins, else PATH.
// Always an owned allocation, so the caller can free it on every path (the env value
// used to leak on each daemon start, and the literal fallback could not be freed).
bridge_pty_host_bin :: proc() -> string {
	v := os.get_env_alloc("HEIMDALL_HAM_PTY_HOST_BIN", context.allocator)
	if strings.trim_space(v) != "" do return v
	delete(v)
	if found := bridge_runtime_find_on_path("ham-pty-host"); found != "" do return found
	return strings.clone("ham-pty-host")
}

// bridge_pty_host_ensure_daemon starts the daemon once (idempotent) and returns
// its socket path. The daemon is spawned detached (its own process) listening on
// pty_host_socket_path(); we then poll a Ping until it answers or the deadline
// passes. Safe to call on every launch.
//
// BR-2a: the socket path is BRIDGE-UNIQUE (see pty_host_socket_path). A daemon
// already answering on it therefore belongs to THIS bridge — a prior instance of
// the same bridge identity (e.g. across a bridge restart), never another bridge's
// daemon. Adopting it is correct-by-identity: we never cross-wire two bridges to
// one daemon, and each bridge owns exactly one daemon serving its own agent set.
bridge_pty_host_ensure_daemon :: proc() -> (string, bool) {
	sync.mutex_lock(&pty_host_daemon_lock)
	defer sync.mutex_unlock(&pty_host_daemon_lock)

	if pty_host_daemon_socket == "" {
		pty_host_daemon_socket = pty_host_socket_path()
	}
	socket := pty_host_daemon_socket
	breaker_key := strings.concatenate({"pty-host:", socket})
	defer delete(breaker_key)
	if !bridge_dependency_breaker_allow(breaker_key) do return "", false

	// Already up on this bridge's own socket (this process started it, or a prior
	// instance of THIS bridge left it running across a restart)?
	if pty_host_daemon_started && bridge_pty_host_ping(socket) {
		bridge_dependency_breaker_record(breaker_key, true)
		return socket, true
	}
	if bridge_pty_host_ping(socket) {
		pty_host_daemon_started = true
		bridge_dependency_breaker_record(breaker_key, true)
		return socket, true
	}

	// REQ-BR-4: never start a second daemon while the one we started is still alive.
	// Retiring it takes down every run it hosts, so first make sure it is really not
	// answering rather than momentarily busy: a few more pings over ~1.5s.
	if bridge_pty_host_daemon_process_running(&pty_host_daemon_process, &pty_host_daemon_has_process) {
		for _ in 0..<3 {
			time.sleep(500 * time.Millisecond)
			if bridge_pty_host_ping(socket) {
				pty_host_daemon_started = true
				bridge_dependency_breaker_record(breaker_key, true)
				return socket, true
			}
		}
	}
	if !bridge_pty_host_retire_daemon_process(&pty_host_daemon_process, &pty_host_daemon_has_process) {
		bridge_dependency_breaker_record(breaker_key, false)
		return "", false
	}

	// Ensure the socket's parent dir exists, then spawn the daemon detached.
	if !bridge_unix_socket_prepare_parent(socket) {
		fmt.eprintln("bridge pty-host: cannot prepare socket directory", socket)
		blog_error(.pty_host_spawn_failed, blog_sym(.stage, .socket_dir))
		return "", false
	}
	bin := bridge_pty_host_bin()
	defer delete(bin)
	cmd := []string{bin, "daemon", "--socket", socket}
	// env = nil => the daemon inherits the bridge's environment. The per-agent
	// HEIMDALL_* env is delivered in each Spawn request, not the daemon's env.
	proc_handle, err := os.process_start(os.Process_Desc{command = cmd})
	if err != nil {
		fmt.eprintln("bridge pty-host: failed to start daemon:", bin, err)
		blog_error(.pty_host_spawn_failed, blog_sym(.stage, .exec))
		bridge_dependency_breaker_record(breaker_key, false)
		return "", false
	}
	// The daemon outlives this call, but the handle is KEPT (REQ-BR-4): it is how the
	// next ensure_daemon reaps it once it exits, and retires it if it wedges.
	pty_host_daemon_process = proc_handle
	pty_host_daemon_has_process = true
	sync.atomic_add(&pty_host_daemon_generation, 1)

	// Poll until the daemon accepts + answers Ping.
	deadline := time.time_add(time.now(), 5 * time.Second)
	for time.now()._nsec < deadline._nsec {
		if bridge_pty_host_ping(socket) {
			pty_host_daemon_started = true
			bridge_dependency_breaker_record(breaker_key, true)
			return socket, true
		}
		time.sleep(50 * time.Millisecond)
	}
	fmt.eprintln("bridge pty-host: daemon did not become ready on", socket)
	blog_error(.pty_host_unreachable, blog_sym(.stage, .ready))
	bridge_dependency_breaker_record(breaker_key, false)
	return "", false
}

// bridge_pty_host_ping sends a Ping and expects a Pong. Used both for readiness
// polling and liveness checks.
bridge_pty_host_ping :: proc(socket: string) -> bool {
	req := pty_host_encode_ping()
	defer delete(req)
	reply, ok := pty_host_request(socket, req)
	if !ok do return false
	defer pty_host_reply_delete(reply)
	return reply.kind == .Pong
}

// ---- spawn-request assembly ---------------------------------------------

// bridge_pty_host_build_spawn assembles the daemon Spawn request for an instance:
// the provider argv, cwd=run_dir, the BR-1 HEIMDALL_* env (as (k,v) pairs), and
// the resolved provider startup-detection JSON (stored verbatim; HOST-2 parses).
// Returns ok=false when the provider has no runnable command. Caller owns the
// returned request's heap slices (free with bridge_pty_host_spawn_request_delete).
bridge_pty_host_build_spawn :: proc(instance_id, run_dir, provider, model, agent_token: string, env: []string, display_name := "", timeout_seconds: u64 = 0) -> (Pty_Host_Spawn_Request, bool) {
	if strings.trim_space(provider) == "" || strings.trim_space(model) == "" do return {}, false
	if !bridge_provider_catalog_has_model(provider, model) do return {}, false
	profile, profile_ok := bridge_provider_catalog_profile(provider)
	if !profile_ok do return {}, false
	resolved_path, path_ok := bridge_provider_resolve_path(provider)
	if !path_ok do return {}, false
	defer delete(resolved_path)
	profile.command = []string{resolved_path}
	agent_argv := bridge_runtime_agent_argv_for_profile(profile, model, agent_token, instance_id)
	if len(agent_argv) == 0 do return {}, false

	cloned_argv := make([]string, len(agent_argv))
	for a, i in agent_argv { cloned_argv[i] = strings.clone(a) }
	delete(agent_argv)

	detect_json := bridge_runtime_startup_detection_arg(profile.startup_detection)
	req := Pty_Host_Spawn_Request{
		instance         = strings.clone(instance_id),
		argv             = cloned_argv,
		cwd              = strings.clone(run_dir),
		has_cwd          = true,
		env              = bridge_pty_host_env_pairs(env),
		detect           = detect_json,
		has_detect       = strings.trim_space(detect_json) != "",
		display_name     = strings.clone(display_name),
		has_display_name = strings.trim_space(display_name) != "",
		has_timeout_seconds = timeout_seconds > 0,
		timeout_seconds     = timeout_seconds,
		rows                = PTY_HOST_DEFAULT_ROWS,
		cols                = PTY_HOST_DEFAULT_COLS,
	}
	bridge_pty_host_track_instance_provider(instance_id, provider)
	return req, true
}

// bridge_pty_host_env_pairs converts BR-1's "KEY=VALUE" env slice into the
// (key,value) pairs the Spawn codec wants. Entries without '=' are skipped.
bridge_pty_host_env_pairs :: proc(env: []string) -> [][2]string {
	out := make([dynamic][2]string)
	for e in env {
		if eq := strings.index_byte(e, '='); eq > 0 {
			append(&out, [2]string{strings.clone(e[:eq]), strings.clone(e[eq + 1:])})
		}
	}
	return out[:]
}

bridge_pty_host_spawn_request_delete :: proc(req: Pty_Host_Spawn_Request) {
	if req.instance != "" do delete(req.instance)
	for a in req.argv do delete(a)
	if req.argv != nil do delete(req.argv)
	if req.cwd != "" do delete(req.cwd)
	for kv in req.env { delete(kv[0]); delete(kv[1]) }
	if req.env != nil do delete(req.env)
	if req.detect != "" do delete(req.detect)
	if req.display_name != "" do delete(req.display_name)
	if req.kind != "" do delete(req.kind)
	if req.tee_path != "" do delete(req.tee_path)
}

// ---- control-plane ops --------------------------------------------------

// bridge_pty_host_spawn spawns (or restarts) an instance on the daemon with
// AC-5-style retry/backoff. If the instance is already registered the daemon
// returns an Error; the caller should use bridge_pty_host_restart for a known
// relaunch. Returns (pid, true) on Spawned.
bridge_pty_host_spawn :: proc(socket: string, req: Pty_Host_Spawn_Request) -> (i32, bool) {
	pid, ok, err_msg := bridge_pty_host_spawn_detailed(socket, req)
	delete(err_msg)
	return pid, ok
}

// bridge_pty_host_spawn_detailed is bridge_pty_host_spawn that also says WHY a spawn
// failed: the daemon's own Error message when it refused, or a fixed description when
// it never answered. err_msg is "" on success; the caller owns it either way.
bridge_pty_host_spawn_detailed :: proc(socket: string, req: Pty_Host_Spawn_Request) -> (pid: i32, ok: bool, err_msg: string) {
	frame := pty_host_encode_spawn(req)
	defer delete(frame)
	for attempt in 1..=PTY_HOST_SPAWN_MAX_ATTEMPTS {
		reply, rok := pty_host_request(socket, frame)
		if rok {
			defer pty_host_reply_delete(reply)
			if reply.kind == .Spawned do return reply.pid, true, ""
			if reply.kind == .Error {
				fmt.eprintln("bridge pty-host spawn error:", reply.message)
				return 0, false, strings.clone(reply.message)
			}
		}
		if attempt < PTY_HOST_SPAWN_MAX_ATTEMPTS do bridge_pty_host_backoff(attempt)
	}
	return 0, false, strings.clone("the pty-host daemon did not answer the spawn request")
}

// bridge_pty_host_restart re-spawns an instance from its remembered spec. Maps
// the bridge's relaunch/wake of an already-registered instance.
bridge_pty_host_restart :: proc(socket, instance: string) -> (i32, bool) {
	frame := pty_host_encode_restart(instance)
	defer delete(frame)
	reply, ok := pty_host_request(socket, frame)
	if !ok do return 0, false
	defer pty_host_reply_delete(reply)
	if reply.kind == .Restarted do return reply.pid, true
	if reply.kind == .Error do fmt.eprintln("bridge pty-host restart error:", reply.message)
	return 0, false
}

// bridge_pty_host_close SIGTERM->SIGKILL + unregisters an instance. Maps stop.
bridge_pty_host_close :: proc(socket, instance: string) -> bool {
	frame := pty_host_encode_close(instance)
	defer delete(frame)
	reply, ok := pty_host_request(socket, frame)
	if !ok do return false
	defer pty_host_reply_delete(reply)
	closed := reply.kind == .Closed
	if closed do bridge_pty_host_untrack_instance_provider(instance)
	return closed
}

// bridge_pty_host_list enumerates registered agents. Caller owns the reply.
bridge_pty_host_list :: proc(socket: string) -> (Pty_Host_Reply, bool) {
	frame := pty_host_encode_list()
	defer delete(frame)
	reply, ok := pty_host_request(socket, frame)
	if !ok do return {}, false
	if reply.kind != .Agent_List { pty_host_reply_delete(reply); return {}, false }
	return reply, true
}

// bridge_pty_host_is_registered reports whether instance appears in the daemon's
// current agent list (used to decide spawn vs restart on a relaunch).
bridge_pty_host_is_registered :: proc(socket, instance: string) -> bool {
	reply, ok := bridge_pty_host_list(socket)
	if !ok do return false
	defer pty_host_reply_delete(reply)
	for a in reply.agents do if a.instance_id == instance do return true
	return false
}

bridge_pty_host_backoff :: proc(attempt: int) {
	ms := PTY_HOST_SPAWN_BASE_BACKOFF_MS
	for _ in 1..<attempt do ms *= 2
	time.sleep(time.Duration(ms) * time.Millisecond)
}

// ---- message/prompt/nudge delivery (BR-3) -------------------------------
//
// In the tmux/wrapper model the ham-wrapper received a hub push and injected a
// one-line notice into the pane via tmux.send_text(pane, msg, enter=true) (type
// the text, then press Enter). In the wrapper-free model the bridge does the same
// thing directly against the daemon: host.input(instance, text) followed by
// host.key(instance, Enter). bridge_pty_host_deliver_line is that primitive; the
// hub-push handlers translate each notification into a single notice line exactly
// as the wrapper did, then call it.

// bridge_pty_host_deliver_line types text into the instance then presses Enter,
// mirroring tmux.send_text(pane, text, enter=true). Returns false if either the
// input or the key send fails.
bridge_pty_host_paste_wrap :: proc(text: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "\x1b[200~")
	for i in 0..<len(text) {
		c := text[i]
		if c == '\x1b' || c == '\r' || c == '\n' do continue
		strings.write_byte(&b, c)
	}
	strings.write_string(&b, "\x1b[201~")
	return strings.to_string(b)
}

bridge_pty_host_deliver_line :: proc(socket, instance, text: string) -> bool {
	decrypted := bridge_decrypt_embedded_vault_tokens(text)
	defer delete(decrypted)
	delivery_text := decrypted
	wrapped := ""
	if bridge_pty_host_instance_wants_bracketed_paste(instance) {
		wrapped = bridge_pty_host_paste_wrap(decrypted)
		delivery_text = wrapped
	}
	defer if wrapped != "" do delete(wrapped)
	input := pty_host_encode_input(instance, transmute([]byte)delivery_text)
	defer delete(input)
	if !bridge_pty_host_send_oneway(socket, input) do return false
	// Small settle delay before Enter, matching the wrapper's 300ms pane pause so a
	// TUI input box registers the pasted text before the submit key.
	time.sleep(300 * time.Millisecond)
	key := pty_host_encode_key(instance, .Enter)
	defer delete(key)
	return bridge_pty_host_send_oneway(socket, key)
}

// bridge_pty_host_send_oneway writes a data-plane frame that expects no reply
// (Input/Key/Resize on an attached instance). Dials, sends, closes.
bridge_pty_host_send_oneway :: proc(socket: string, frame: []byte) -> bool {
	fd, ok := pty_host_dial(socket)
	if !ok do return false
	defer local_socket.close(fd)
	return pty_host_send_all(fd, frame)
}

// bridge_pty_host_deliver_raw_input delivers raw input bytes directly to the agent's
// PTY stdin via CtlMsg::Input to the ham-pty-host daemon socket.
bridge_pty_host_deliver_raw_input_socket_bytes :: proc(socket, instance: string, data: []byte) -> bool {
	if strings.trim_space(socket) == "" || strings.trim_space(instance) == "" do return false
	frame := pty_host_encode_input(instance, data)
	defer delete(frame)
	return bridge_pty_host_send_oneway(socket, frame)
}

bridge_pty_host_deliver_raw_input_socket_string :: proc(socket, instance, data: string) -> bool {
	return bridge_pty_host_deliver_raw_input_socket_bytes(socket, instance, transmute([]byte)data)
}

bridge_pty_host_deliver_raw_input_bytes :: proc(instance: string, data: []byte) -> bool {
	if strings.trim_space(instance) == "" do return false
	socket, ok := bridge_pty_host_ensure_daemon()
	if !ok do return false
	return bridge_pty_host_deliver_raw_input_socket_bytes(socket, instance, data)
}

bridge_pty_host_deliver_raw_input_string :: proc(instance, data: string) -> bool {
	return bridge_pty_host_deliver_raw_input_bytes(instance, transmute([]byte)data)
}

bridge_pty_host_deliver_raw_input :: proc{
	bridge_pty_host_deliver_raw_input_bytes,
	bridge_pty_host_deliver_raw_input_string,
	bridge_pty_host_deliver_raw_input_socket_bytes,
	bridge_pty_host_deliver_raw_input_socket_string,
}

// bridge_pty_host_deliver_resize delivers a window resize request directly to the
// agent's PTY and VT screen model via CtlMsg::Resize to the ham-pty-host daemon socket.
bridge_pty_host_deliver_resize_socket :: proc(socket, instance: string, rows, cols: u16) -> bool {
	if strings.trim_space(socket) == "" || strings.trim_space(instance) == "" || rows == 0 || cols == 0 do return false
	frame := pty_host_encode_resize(instance, rows, cols)
	defer delete(frame)
	return bridge_pty_host_send_oneway(socket, frame)
}

bridge_pty_host_deliver_resize_default :: proc(instance: string, rows, cols: u16) -> bool {
	if strings.trim_space(instance) == "" || rows == 0 || cols == 0 do return false
	socket, ok := bridge_pty_host_ensure_daemon()
	if !ok do return false
	return bridge_pty_host_deliver_resize_socket(socket, instance, rows, cols)
}

bridge_pty_host_deliver_resize :: proc{
	bridge_pty_host_deliver_resize_default,
	bridge_pty_host_deliver_resize_socket,
}

// bridge_pty_host_deliver_shell_input delivers raw input bytes directly to a shell's
// PTY stdin via CtlMsg::Input to the ham-pty-host daemon socket.
bridge_pty_host_deliver_shell_input_string :: proc(shell_id: string, data: string) -> bool {
	return bridge_pty_host_deliver_raw_input(shell_id, data)
}

bridge_pty_host_deliver_shell_input_bytes :: proc(shell_id: string, data: []byte) -> bool {
	return bridge_pty_host_deliver_raw_input(shell_id, data)
}

bridge_pty_host_deliver_shell_input_socket_string :: proc(socket, shell_id: string, data: string) -> bool {
	return bridge_pty_host_deliver_raw_input(socket, shell_id, data)
}

bridge_pty_host_deliver_shell_input_socket_bytes :: proc(socket, shell_id: string, data: []byte) -> bool {
	return bridge_pty_host_deliver_raw_input(socket, shell_id, data)
}

bridge_pty_host_deliver_shell_input :: proc{
	bridge_pty_host_deliver_shell_input_string,
	bridge_pty_host_deliver_shell_input_bytes,
	bridge_pty_host_deliver_shell_input_socket_string,
	bridge_pty_host_deliver_shell_input_socket_bytes,
}

// bridge_pty_host_deliver_shell_resize delivers a window resize request directly to a
// shell's PTY and VT screen model via CtlMsg::Resize to the ham-pty-host daemon socket.
bridge_pty_host_deliver_shell_resize_default :: proc(shell_id: string, rows, cols: u16) -> bool {
	return bridge_pty_host_deliver_resize(shell_id, rows, cols)
}

bridge_pty_host_deliver_shell_resize_socket :: proc(socket, shell_id: string, rows, cols: u16) -> bool {
	return bridge_pty_host_deliver_resize(socket, shell_id, rows, cols)
}

bridge_pty_host_deliver_shell_resize :: proc{
	bridge_pty_host_deliver_shell_resize_default,
	bridge_pty_host_deliver_shell_resize_socket,
}


// bridge_pty_host_message_notice renders the agent_message notice text (pure, so
// it is unit-testable). Names the documented `ham-ctl chat read` verb (no `agent` prefix).
bridge_pty_host_message_notice :: proc(sender: string, sender_display_name: string = "") -> string {
	s := sender_display_name if strings.trim_space(sender_display_name) != "" else sender
	if strings.trim_space(s) == "" do s = "user"
	return strings.concatenate({"New message from ", s, " \u2014 run './.heimdall/bin/ham-ctl chat read' to view."})
}

// bridge_pty_host_task_nudge_notice renders the task-nudge notice text (pure).
bridge_pty_host_task_nudge_notice :: proc(task_id, target_role: string, task_title: string = "") -> string {
	tid := task_id
	if strings.trim_space(tid) == "" do tid = "unknown"
	role := target_role
	if strings.trim_space(role) == "" do role = "participant"
	title := strings.trim_space(task_title)
	if title != "" {
		return strings.concatenate({"Nudge: you have been nudged on \"", title, "\" (", tid, ") (", role, "). Run './.heimdall/bin/ham-ctl task list' and complete your assignment."})
	}
	return strings.concatenate({"Nudge: you have been nudged on ", tid, " (", role, "). Run './.heimdall/bin/ham-ctl task list' and complete your assignment."})
}

// bridge_shell_run_notice renders the line an agent sees when one of its BACKGROUND
// runs finishes or is killed (REQ-SHELL-5 §1).
//
// The SESSION ID leads, because it is the handle the agent was given when the run was
// backgrounded and it is what `shell log` takes — the notice is only useful if the
// agent can act on it without a lookup. Status and exit code follow when known.
//
// NO OUTPUT, not even a tail. Output lives on this host and is read on demand; pasting
// it into the agent's pane would both flood the pane and defeat the rule that output
// never travels with status. The closing instruction points at the command that fetches
// it, which is the whole of what the agent needs.
//
// Pure and testable, like bridge_pty_host_task_nudge_notice above. Caller owns the
// returned string.
bridge_shell_run_notice :: proc(session_id, status, exit_code: string) -> string {
	sid := strings.trim_space(session_id)
	if sid == "" do sid = "unknown"
	st := strings.trim_space(status)
	if st == "" do st = "exited"
	code := strings.trim_space(exit_code)
	if code != "" {
		return strings.concatenate({"Shell run ", sid, " ", st, " (exit ", code, "). Run './.heimdall/bin/ham-ctl shell log ", sid, "' to read its output."})
	}
	return strings.concatenate({"Shell run ", sid, " ", st, ". Run './.heimdall/bin/ham-ctl shell log ", sid, "' to read its output."})
}

// bridge_pty_host_deliver_message renders the same notice the wrapper produced for
// an agent_message push and delivers it.
//
// User-initiated messages press ESC BEFORE typing the notice: this interrupts the
// agent's current turn (most CLI agents treat ESC as "cancel/stop") so it drops
// back to an input-ready prompt and picks up the just-arrived user message ASAP
// instead of finishing a long autonomous run first. The ESC is followed by a
// short settle so the pane returns to its input box before we paste the notice.
bridge_pty_host_deliver_message :: proc(socket, instance, sender: string) -> bool {
	esc := pty_host_encode_key(instance, .Esc)
	defer delete(esc)
	if !bridge_pty_host_send_oneway(socket, esc) do return false
	time.sleep(300 * time.Millisecond)
	msg := bridge_pty_host_message_notice(sender)
	defer delete(msg)
	return bridge_pty_host_deliver_line(socket, instance, msg)
}

// bridge_pty_host_deliver_task_nudge delivers the task-nudge notice. MEM-6: when
// the hub supplies a human_message it is delivered verbatim (context-rich line);
// otherwise we fall back to the legacy generated notice for backwards compat with
// older hubs that don't populate human_message.
bridge_pty_host_deliver_task_nudge :: proc(socket, instance, task_id, target_role: string, human_message: string = "", task_title: string = "", interrupt: bool = false) -> bool {
	if interrupt {
		esc := pty_host_encode_key(instance, .Esc)
		defer delete(esc)
		if !bridge_pty_host_send_oneway(socket, esc) do return false
		time.sleep(300 * time.Millisecond)
	}
	msg := bridge_pty_host_task_nudge_line(task_id, target_role, human_message, task_title)
	defer delete(msg)
	return bridge_pty_host_deliver_line(socket, instance, msg)
}

// bridge_pty_host_task_nudge_line picks the line to deliver for a task nudge: the
// hub's human_message verbatim when present, else the legacy generated notice
// (backwards compat with hubs that don't populate human_message). Pure/testable.
// Caller owns the returned string.
bridge_pty_host_task_nudge_line :: proc(task_id, target_role, human_message: string, task_title: string = "") -> string {
	if strings.trim_space(human_message) != "" do return strings.clone(human_message)
	return bridge_pty_host_task_nudge_notice(task_id, target_role, task_title)
}

// bridge_pty_host_deliver_notice delivers an arbitrary prefixed nudge/notice line
// (title-nudge, startup prompt) verbatim.
bridge_pty_host_deliver_notice :: proc(socket, instance, notice: string) -> bool {
	return bridge_pty_host_deliver_line(socket, instance, notice)
}

// bridge_pty_host_deliver_to_agent is the single entry the hub-push handlers call
// in the wrapper-free path: it ensures the daemon is up, then renders+delivers the
// notice for the given kind ("message" | "task_nudge"). Returns false if the daemon
// is unavailable or the delivery fails.
bridge_pty_host_deliver_to_agent :: proc(instance, kind, sender, task_id, target_role: string, human_message: string = "", task_title: string = "", interrupt: bool = false) -> bool {
	socket, ok := bridge_pty_host_ensure_daemon()
	if !ok do return false
	switch kind {
	case "message":
		return bridge_pty_host_deliver_message(socket, instance, sender)
	case "task_nudge":
		return bridge_pty_host_deliver_task_nudge(socket, instance, task_id, target_role, human_message, task_title, interrupt)
	}
	return false
}

// ---- UI capture proxy (BR-4) --------------------------------------------

// bridge_pty_host_capture_result serves a UI pane_capture_request by proxying
// host.capture(instance): it ensures the daemon, requests one Screen snapshot,
// joins the rendered lines into pane text (honoring the request's line_limit),
// and builds the pane_capture_result JSON in the SAME shape the wrapper produced.
// On any failure it returns a failed result with a stable error_code so the UI
// surfaces a clean message instead of hanging on a pending capture.
bridge_pty_host_capture_result :: proc(pending: Bridge_Pane_Capture_Pending) -> string {
	socket, ok := bridge_pty_host_ensure_daemon()
	if !ok {
		return bridge_pane_capture_result_json(pending, false, "host_unavailable", "The ham-pty-host daemon is not available.", "", 0, false)
	}
	frame := pty_host_encode_capture(pending.agent_instance_id)
	defer delete(frame)
	reply, rok := pty_host_request(socket, frame)
	if !rok || reply.kind != .Screen {
		if rok do pty_host_reply_delete(reply)
		return bridge_pane_capture_result_json(pending, false, "capture_failed", "No screen snapshot was returned for this agent.", "", 0, false)
	}
	defer pty_host_reply_delete(reply)
	output, line_count, truncated := bridge_pty_host_screen_to_output(reply.screen.lines, pending.line_limit)
	defer delete(output)
	return bridge_pane_capture_result_json(pending, true, "", "", output, line_count, truncated)
}

// bridge_pty_host_screen_to_output joins a captured screen's rendered lines into
// pane text, keeping only the LAST line_limit lines (the tail, matching the tmux
// capture semantics) and reporting the emitted line count + whether the screen was
// truncated to the tail. Caller owns the returned string.
bridge_pty_host_screen_to_output :: proc(lines: []string, line_limit: int) -> (output: string, line_count: int, truncated: bool) {
	start := 0
	trunc := false
	if line_limit > 0 && len(lines) > line_limit {
		start = len(lines) - line_limit
		trunc = true
	}
	tail := lines[start:]
	joined := strings.join(tail, "\n")
	if start > 0 && len(lines) > 0 && strings.has_prefix(lines[0], "\x1b[?1049h") {
		defer delete(joined)
		prefix := "\x1b[?1049h\x1b[?25l" if strings.has_prefix(lines[0], "\x1b[?1049h\x1b[?25l") else "\x1b[?1049h"
		return strings.concatenate({prefix, joined}), len(tail), trunc
	}
	return joined, len(tail), trunc
}

// bridge_pty_host_pane_hash computes the SHA256 hex string for pane content.
// Caller owns the returned string.
bridge_pty_host_pane_hash :: proc(s: string, allocator := context.allocator) -> string {
	buf: [32]byte
	crypto_hash.hash_string_to_buffer(.SHA256, s, buf[:])
	hex_bytes := hex.encode(buf[:], allocator)
	return string(hex_bytes)
}

// bridge_pty_host_evaluate_pane evaluates rendered screen lines against since_hash.
// If since_hash matches the computed SHA256 hash of the output tail, returns unchanged: true
// with empty output payload. If different or no since_hash, returns unchanged: false with
// output, line_count, and truncated flag. Caller owns the returned hash and output strings.
bridge_pty_host_evaluate_pane :: proc(lines: []string, line_limit: int, since_hash: string) -> (unchanged: bool, hash_val: string, output: string, line_count: int, truncated: bool) {
	out, count, trunc := bridge_pty_host_screen_to_output(lines, line_limit)
	h := bridge_pty_host_pane_hash(out)
	trimmed_since := strings.trim_space(since_hash)
	if trimmed_since != "" && (h == trimmed_since || strings.equal_fold(h, trimmed_since)) {
		delete(out)
		return true, h, "", 0, false
	}
	return false, h, out, count, trunc
}

// bridge_pty_host_get_pane proxies host.capture against the pty-host daemon,
// computes the screen output hash, and evaluates against since_hash (REQ-PANE-2).
// Returns (ok, unchanged, hash, output, line_count, truncated, cursor_row, cursor_col, err_msg).
// Caller owns returned hash and output strings when present.
bridge_pty_host_get_pane :: proc(instance_id: string, since_hash: string, line_limit: int, width: int) -> (ok: bool, unchanged: bool, hash: string, output: string, line_count: int, truncated: bool, cursor_row: int, cursor_col: int, err_msg: string) {
	_ = width
	trimmed_id := strings.trim_space(instance_id)
	if trimmed_id == "" {
		return false, false, "", "", 0, false, 0, 0, "missing agent_instance_id"
	}

	socket, ok_daemon := bridge_pty_host_ensure_daemon()
	if !ok_daemon {
		return false, false, "", "", 0, false, 0, 0, "The ham-pty-host daemon is not available."
	}

	frame := pty_host_encode_capture(trimmed_id)
	defer delete(frame)
	reply, rok := pty_host_request(socket, frame)
	if !rok || reply.kind != .Screen {
		if rok do pty_host_reply_delete(reply)
		return false, false, "", "", 0, false, 0, 0, "No screen snapshot was returned for this agent."
	}
	defer pty_host_reply_delete(reply)

	unchanged_val, h, out, count, trunc := bridge_pty_host_evaluate_pane(reply.screen.lines, line_limit, since_hash)
	return true, unchanged_val, h, out, count, trunc, int(reply.screen.cursor_row), int(reply.screen.cursor_col), ""
}

// ---- event->status mapping (consumed by the BR-3 subscriber) ------------

// bridge_pty_host_apply_child_exited maps a ChildExited event to the bridge's
// runtime status. The child is gone, so we drop the launch record and mark the
// instance stopped/idle; the stop-intent guard inside the status layer prevents a
// deliberately-stopped instance from being resurrected. Restart-reap (a superseded
// launch closing an older child) is handled at launch time via
// bridge_pty_host_reap_superseded, not here.
bridge_pty_host_apply_child_exited :: proc(instance: string, code: i32) {
	if strings.trim_space(instance) == "" do return
	fmt.println("bridge pty-host: child exited", instance, "code", code)
	bridge_runtime_set_pty_process_alive(instance, false)
	// bridge_log relay: an agent that dies within BLOG_EARLY_EXIT_WINDOW of its
	// launch (the launch record still has the tick) is almost always a provider
	// CLI problem — not logged in, bad model flag, missing binary — and is the
	// #1 "agent won't start" support question.
	if launch, has_launch := bridge_runtime_get_launch(instance); has_launch && launch.launched_at_ns != 0 {
		age := time.tick_now()._nsec - launch.launched_at_ns
		if age >= 0 && age < i64(BLOG_EARLY_EXIT_WINDOW) {
			blog_warn(.agent_exited_early, blog_sym(.provider, launch.provider_sym), blog_int(.exit_code, i64(code)), blog_int(.duration_ms, age / 1_000_000))
		}
	}
	bridge_runtime_remove_launch(instance)
	bridge_runtime_set_status(instance, "stopped", "idle")

	// Emit shell_exited WS event for any T4-registered shell session matching this daemon shell_id.
	// An OWNED snapshot: session_id is read after the map lock is released and after
	// the finalize below has mutated the entry.
	//
	// The finalize is shared with the exit safety nets (shell_exit_sweep.odin): the
	// periodic sweep and a refused kill report through the very same path, and its
	// exit claim makes a late or duplicate ChildExited for an already-reported run a
	// no-op instead of a second shell_exited.
	if sess, ok := bridge_shell_session_snapshot_by_shell_id(&bridge_shell_session_map, instance); ok {
		defer bridge_shell_session_snapshot_destroy(&bridge_shell_session_map, sess)
		data_dir := bridge_shell_data_dir()
		defer delete(data_dir)
		_ = bridge_shell_session_finalize_exit(&bridge_shell_session_map, sess.session_id, int(code), true, data_dir)
	}
}

// bridge_pty_host_apply_startup_ready maps a StartupReady event: the startup probe
// saw no blocked pattern. This proves the process launched but is NOT start-success
// (only the agent calling start-success flips to "running"), so we record a
// liveness signal exactly as the wrapper's "startup ready" did — keeping the
// instance "starting" until the agent acknowledges.
bridge_pty_host_apply_startup_ready :: proc(instance: string) {
	if strings.trim_space(instance) == "" do return
	bridge_runtime_note_wrapper_signal(instance, "idle")
}

// bridge_pty_host_apply_startup_blocked maps a StartupBlocked event to the distinct
// "blocked" runtime state (active-but-not-ready), mirroring the wrapper's
// wrapper.startup.report phase=startup_blocked path. reason_code/safe_diagnostic
// are logged for operators; the status layer projects "blocked" upstream.
bridge_pty_host_apply_startup_blocked :: proc(instance, reason_code, safe_diagnostic: string) {
	if strings.trim_space(instance) == "" do return
	fmt.println("bridge pty-host: startup blocked", instance, "reason=", reason_code, "detail=", safe_diagnostic)
	if blog_startup_reason_is_login(reason_code) {
		provider_sym := Blog_Sym.other
		if launch, has_launch := bridge_runtime_get_launch(instance); has_launch do provider_sym = launch.provider_sym
		blog_warn(.provider_not_logged_in, blog_sym(.provider, provider_sym))
	}
	bridge_runtime_set_status(instance, "blocked", "idle")
}

// bridge_pty_host_apply_activity maps a classified burst to a hub activity report,
// tagged with the harness-agnostic "pane_diff" source (same rank the wrapper's pane
// detector used) so it ranks above a plain liveness ping but below a native agent
// extension. waiting_user is projected to idle by the hub.
bridge_pty_host_apply_activity :: proc(instance: string, sample: Bridge_Activity_Sample) {
	if strings.trim_space(instance) == "" do return
	bridge_runtime_note_agent_activity(instance, bridge_activity_status_string(sample.status), "pane_diff")
}

// bridge_pty_host_reap_superseded implements the restart-reap rule for the
// wrapper-free path: when a fresh launch supersedes a prior run of the same
// instance, close the old child on the daemon (SIGTERM->SIGKILL + unregister) so no
// orphaned agent lingers. This is the host analog of the wrapper's H7 token
// self-reap — with a real daemon we close directly instead of waiting for a
// liveness-ping timeout. Best-effort; safe if the instance is not registered.
bridge_pty_host_reap_superseded :: proc(socket, instance: string) {
	if strings.trim_space(instance) == "" do return
	if bridge_pty_host_is_registered(socket, instance) {
		if bridge_pty_host_close(socket, instance) do fmt.println("bridge pty-host: reaped superseded instance", instance)
	}
}
