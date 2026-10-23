#+build !windows
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:net"
import "core:time"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"

// Exercise the real launch entry point against a minimal acknowledged PTY host.
// A duplicate wake must confirm the actual spawn key: no rotation/bootstrap/Spawn.
@(test)
startup_wake_duplicate_preserves_child_and_stale_or_stopped_is_denied :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	id := "startup_wake_bridge"
	was_started := sync.atomic_exchange(&bridge_startup_worker_started, true)
	defer sync.atomic_store(&bridge_startup_worker_started, was_started)
	rec := Bridge_Local_Agent_Token_Record{agent_instance_id = id, token_hash = "startup-wake-token", instance_token = "hit_startup_wake_bridge", role = .Agent, run_count = 4}
	sync.mutex_lock(&bridge_local_token_mutex)
	bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record, allocator = runtime.heap_allocator())
	append(&bridge_local_token_records, rec)
	sync.mutex_unlock(&bridge_local_token_mutex)
	path := fmt.tprintf("/tmp/ham-startup-wake-%d.sock", os.get_pid())
	_ = posix.unlink(cstring(raw_data(path)))
	defer _ = posix.unlink(cstring(raw_data(path)))
	listener := posix.socket(.UNIX, .STREAM)
	if !testing.expect(t, listener >= 0) do return
	defer posix.close(listener)
	addr: posix.sockaddr_un
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD {
		addr.sun_len = c.uchar(size_of(addr))
	}
	addr.sun_family = .UNIX
	for ch, i in path do addr.sun_path[i] = c.char(ch)
	if !testing.expect(t, posix.bind(listener, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) == .OK) do return
	if !testing.expect(t, posix.listen(listener, 4) == .OK) do return
	Server :: struct { listener: posix.FD, pings, queries, unexpected: int }
	server := Server{listener = listener}
	worker := thread.create_and_start_with_data(&server, proc(data: rawptr) {
		context.allocator = runtime.heap_allocator()
		s := (^Server)(data)
		for _ in 0..<4 {
			pfd := posix.pollfd{fd = s.listener, events = {.IN}}
			if posix.poll(&pfd, 1, 3000) <= 0 do return
			fd := posix.accept(s.listener, nil, nil)
			if fd < 0 do return
			request, ok := pty_host_read_frame(fd)
			if !ok || len(request) == 0 { posix.close(fd); return }
			payload := make([dynamic]byte)
			switch request[0] {
			case PTY_HOST_T_PING:
				s.pings += 1
				append(&payload, PTY_HOST_T_PONG)
			case PTY_HOST_T_STARTUP_LAUNCH:
				s.queries += 1
				off := 1
				id, iok := pty_host_get_str(request, &off)
				key, kok := pty_host_get_str(request, &off)
				if !iok || !kok { posix.close(fd); return }
				append(&payload, PTY_HOST_T_STARTUP_LAUNCH_REPLY)
				pty_host_put_str(&payload, id)
				pty_host_put_i32(&payload, 123 if key == "startup-wake-token" else 0)
				pty_host_put_str(&payload, key)
				delete(id); delete(key)
			case:
				s.unexpected += 1
				append(&payload, PTY_HOST_T_ERROR)
				pty_host_put_str(&payload, "startup_wake_bridge")
				pty_host_put_str(&payload, "unexpected operation")
			}
			reply := pty_host_frame(payload[:])
			_ = pty_host_send_all(fd, reply)
			delete(request); delete(payload); delete(reply)
			posix.close(fd)
		}
	})
	defer thread.destroy(worker)
	sync.mutex_lock(&pty_host_daemon_lock)
	old_socket, old_started := pty_host_daemon_socket, pty_host_daemon_started
	pty_host_daemon_socket, pty_host_daemon_started = path, true
	sync.mutex_unlock(&pty_host_daemon_lock)
	defer {
		sync.mutex_lock(&pty_host_daemon_lock)
		pty_host_daemon_socket, pty_host_daemon_started = old_socket, old_started
		sync.mutex_unlock(&pty_host_daemon_lock)
	}
	command := bridge_wake_launch_command_json("wake", id, "task", "worker", "future", "model", "agent", "name", "chain", "title", "coordinator", "", "", run_count = 4)
	defer delete(command)
	for i in 0..<2 {
		ok, detail, _ := bridge_runtime_launch_agent("wake", command)
		testing.expect(t, ok, detail)
		if i == 0 {
			sync.mutex_lock(&bridge_runtime_mutex)
			for &inst in bridge_runtime_instances do if inst.agent_instance_id == id {
				inst.startup.fallback_delivered = true
			}
			sync.mutex_unlock(&bridge_runtime_mutex)
		}
	}
	inst, exists := bridge_runtime_instance_snapshot(id)
	testing.expect(t, exists && inst.startup.pty_pid == 123 && inst.startup.armed_at_ms > 0, "recovered host identity arms fallback after bridge restart")
	testing.expect(t, inst.startup.fallback_delivered, "duplicate wake preserves delivered fallback receipt")
	thread.join(worker)
	testing.expect_value(t, server.pings, 2)
	testing.expect_value(t, server.queries, 2)
	testing.expect_value(t, server.unexpected, 0)
	sync.mutex_lock(&bridge_local_token_mutex)
	testing.expect_value(t, len(bridge_local_token_records), 1)
	testing.expect_value(t, bridge_local_token_records[0].token_hash, rec.token_hash)
	testing.expect_value(t, bridge_local_token_records[0].invalidated_at_unix_ms, 0)
	sync.mutex_unlock(&bridge_local_token_mutex)
	old := bridge_wake_launch_command_json("old", id, "task", "worker", "future", "model", "agent", "name", "chain", "title", "coordinator", "", "", run_count = 3)
	defer delete(old)
	ok, detail, _ := bridge_runtime_launch_agent("old", old)
	testing.expect(t, !ok && strings.contains(detail, "superseded"), "delayed old wake cannot replace child")
	bridge_runtime_mark_stop_intent(id)
	ok, detail, _ = bridge_runtime_launch_agent("wake", command)
	testing.expect(t, !ok && strings.contains(detail, "stopped"), "same generation cannot undo stop")
	sync.mutex_lock(&bridge_local_token_mutex)
	bridge_local_token_records[0].invalidated_at_unix_ms = 1
	sync.mutex_unlock(&bridge_local_token_mutex)
	bridge_runtime_clear_stop_intent(id)
	testing.expect_value(t, bridge_agent_instance_run_count(id), 4)
	ok, detail, _ = bridge_runtime_launch_agent("wake", command)
	testing.expect(t, !ok && strings.contains(detail, "revoked"), "persisted revocation fences retry after bridge restart")
}

@(test)
startup_wake_preserved_old_child_after_bootstrap_failure_is_replaced_on_retry :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	id := "startup_wake_failed_bootstrap"
	scratch := fmt.aprintf("/tmp/ham-startup-retry-%d", os.get_pid())
	saved_config := bridge_config
	saved_started, saved_descriptor := bridge_runtime_local_endpoint_started, bridge_runtime_local_endpoint_descriptor
	was_worker := sync.atomic_exchange(&bridge_startup_worker_started, true)
	saved_events := pty_host_events_started
	bridge_runtime_local_endpoint_started = true
	bridge_runtime_local_endpoint_descriptor = "unix:/test-startup-endpoint"
	pty_host_events_started = true
	bridge_config.data_dir = scratch
	bridge_config.local_endpoint_run_dir = scratch
	bridge_config.daemon_url = "http://127.0.0.1:1"
	bridge_config.bridge_token = "" // deterministic bootstrap failure after issuing N
	defer {
		bridge_config = saved_config
		bridge_runtime_local_endpoint_started, bridge_runtime_local_endpoint_descriptor = saved_started, saved_descriptor
		sync.atomic_store(&bridge_startup_worker_started, was_worker)
		pty_host_events_started = saved_events
	}
	sync.mutex_lock(&bridge_local_token_mutex)
	bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record)
	append(&bridge_local_token_records, Bridge_Local_Agent_Token_Record{agent_instance_id = id, token_hash = "old-child-key", instance_token = "hit_old", role = .Agent, run_count = 4})
	sync.mutex_unlock(&bridge_local_token_mutex)

	// An acknowledged socket host owns the child's key, independently of token
	// issuance. Decode actual Spawn env, so only a new Spawn can change it.
	path := fmt.aprintf("%s.sock", scratch)
	_ = posix.unlink(cstring(raw_data(path)))
	defer _ = posix.unlink(cstring(raw_data(path)))
	listener := posix.socket(.UNIX, .STREAM)
	if !testing.expect(t, listener >= 0) do return
	defer posix.close(listener)
	addr: posix.sockaddr_un
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD { addr.sun_len = c.uchar(size_of(addr)) }
	addr.sun_family = .UNIX
	for ch, i in path do addr.sun_path[i] = c.char(ch)
	if !testing.expect(t, posix.bind(listener, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) == .OK) do return
	if !testing.expect(t, posix.listen(listener, 4) == .OK) do return
	Host :: struct { listener: posix.FD, done: bool, key: string, pid: i32, spawns, closes, queries: int }
	host := Host{listener = listener, key = "old-child-key", pid = 101}
	worker := thread.create_and_start_with_data(&host, proc(data: rawptr) {
		context.allocator = runtime.heap_allocator()
		h := (^Host)(data)
		for !sync.atomic_load(&h.done) {
			pfd := posix.pollfd{fd = h.listener, events = {.IN}}
			if posix.poll(&pfd, 1, 100) <= 0 do continue
			fd := posix.accept(h.listener, nil, nil)
			if fd < 0 do return
			request, ok := pty_host_read_frame(fd)
			if !ok || len(request) == 0 { posix.close(fd); return }
			payload := make([dynamic]byte)
			switch request[0] {
			case PTY_HOST_T_PING: append(&payload, PTY_HOST_T_PONG)
			case PTY_HOST_T_STARTUP_LAUNCH:
				h.queries += 1
				off := 1
				inst, _ := pty_host_get_str(request, &off)
				key, _ := pty_host_get_str(request, &off)
				append(&payload, PTY_HOST_T_STARTUP_LAUNCH_REPLY)
				pty_host_put_str(&payload, inst)
				pty_host_put_i32(&payload, h.pid if h.key == key else 0)
				pty_host_put_str(&payload, key)
				delete(inst); delete(key)
			case PTY_HOST_T_LIST:
				append(&payload, PTY_HOST_T_AGENTLIST)
				pty_host_put_u16(&payload, u16(1 if h.pid > 0 else 0))
				if h.pid > 0 {
					pty_host_put_str(&payload, "startup_wake_failed_bootstrap")
					pty_host_put_str(&payload, "/fake/provider")
					pty_host_put_i32(&payload, h.pid)
					append(&payload, 1, 0)
					pty_host_put_u16(&payload, 24); pty_host_put_u16(&payload, 80)
					pty_host_put_u64(&payload, 1000); pty_host_put_u64(&payload, 1000)
					append(&payload, 0)
				}
			case PTY_HOST_T_CLOSE:
				h.closes += 1; h.pid = 0
				append(&payload, PTY_HOST_T_CLOSED)
				pty_host_put_str(&payload, "startup_wake_failed_bootstrap")
			case PTY_HOST_T_SPAWN:
				if h.pid > 0 {
					// The prior Spawn succeeded, but its ACK was lost.
					append(&payload, PTY_HOST_T_ERROR)
					pty_host_put_str(&payload, "startup_wake_failed_bootstrap")
					pty_host_put_str(&payload, "already registered")
				} else {
					off := 1
					inst, _ := pty_host_get_str(request, &off)
					argc, _ := pty_host_get_u16(request, &off)
					for _ in 0..<int(argc) { arg, _ := pty_host_get_str(request, &off); delete(arg) }
					has_cwd := request[off]; off += 1
					if has_cwd != 0 { cwd, _ := pty_host_get_str(request, &off); delete(cwd) }
					envc, _ := pty_host_get_u16(request, &off)
					for _ in 0..<int(envc) {
						k, _ := pty_host_get_str(request, &off)
						v, _ := pty_host_get_str(request, &off)
						if k == "HEIMDALL_STARTUP_KEY" do h.key = strings.clone(v)
						delete(k); delete(v)
					}
					h.spawns += 1; h.pid = 202
					delete(inst)
					// Close without an ACK, just like a dropped Spawn connection.
				}
			case:
				append(&payload, PTY_HOST_T_ERROR)
				pty_host_put_str(&payload, "startup_wake_failed_bootstrap")
				pty_host_put_str(&payload, "unsupported")
			}
			if len(payload) > 0 {
				reply := pty_host_frame(payload[:])
				_ = pty_host_send_all(fd, reply)
				delete(reply)
			}
			delete(request); delete(payload); posix.close(fd)
		}
	})
	defer { sync.atomic_store(&host.done, true); thread.join(worker); thread.destroy(worker) }
	sync.mutex_lock(&pty_host_daemon_lock)
	old_socket, old_daemon := pty_host_daemon_socket, pty_host_daemon_started
	pty_host_daemon_socket, pty_host_daemon_started = path, true
	sync.mutex_unlock(&pty_host_daemon_lock)
	defer { sync.mutex_lock(&pty_host_daemon_lock); pty_host_daemon_socket, pty_host_daemon_started = old_socket, old_daemon; sync.mutex_unlock(&pty_host_daemon_lock) }

	command := bridge_wake_launch_command_json("retry", id, "task", "worker", "future", "model", "agent", "name", "chain", "title", "coordinator", "", "", run_count = 5)
	ok, detail, _ := bridge_runtime_launch_agent("retry", command)
	testing.expect(t, !ok && strings.contains(detail, "bootstrap failed"), "failure occurs after generation N token persistence")
	testing.expect_value(t, bridge_agent_instance_run_count(id), 5)
	old_pid, old_ok := bridge_pty_host_startup_launch(path, id, "old-child-key")
	testing.expect(t, old_ok && old_pid == 101, "N-1 child survives pre-spawn failure")

	// Real bootstrap HTTP request and materialization on retry; no production
	// endpoint or provider is used.
	http_listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if !testing.expect(t, lerr == nil) do return
	defer net.close(http_listener)
	_ = net.set_option(http_listener, .Receive_Timeout, 3 * time.Second)
	bound, _ := net.bound_endpoint(http_listener)
	bridge_config.daemon_url = fmt.aprintf("http://127.0.0.1:%d", bound.port)
	bridge_config.bridge_token = "test-only"
	Http :: struct { listener: net.TCP_Socket, served: bool }
	http := Http{listener = http_listener}
	http_worker := thread.create_and_start_with_data(&http, proc(data: rawptr) {
		h := (^Http)(data)
		client, _, err := net.accept_tcp(h.listener)
		if err != nil do return
		defer net.close(client)
		_ = net.set_option(client, .Receive_Timeout, 3 * time.Second)
		buf: [8192]byte
		n, _ := net.recv_tcp(client, buf[:])
		if n <= 0 do return
		body := "{\"data\":{\"version\":\"test\",\"files\":[],\"skills\":[]}}"
		response := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body)
		_, _ = net.send_tcp(client, transmute([]byte)response)
		h.served = true
	})
	defer thread.destroy(http_worker)
	// Supply a provider-neutral catalog/path with an executable test command.
	models := []Bridge_Catalog_Model{{model_id = "model", label = "model", state = "active"}}
	providers := []Bridge_Catalog_Provider{{provider = "future", display_name = "future", binary = "/bin/sh", model_flag = "--model", state = "active", models = models}}
	snapshot := Bridge_Provider_Catalog_Snapshot{providers = providers}
	prev_catalog, prev_loaded := bridge_provider_catalog_snapshot, bridge_provider_catalog_loaded
	bridge_provider_catalog_snapshot, bridge_provider_catalog_loaded = &snapshot, true
	defer { bridge_provider_catalog_snapshot, bridge_provider_catalog_loaded = prev_catalog, prev_loaded }
	prev_paths, prev_paths_loaded := bridge_provider_paths, bridge_provider_paths_loaded
	bridge_provider_paths = make([dynamic]Bridge_Provider_Path)
	append(&bridge_provider_paths, Bridge_Provider_Path{provider = "future", state = "present", resolved_path = "/bin/sh"})
	bridge_provider_paths_loaded = true
	defer { bridge_provider_paths, bridge_provider_paths_loaded = prev_paths, prev_paths_loaded }
	old_cache := bootstrap_global_cache
	bootstrap_global_cache = {}
	bootstrap_cache_init(&bootstrap_global_cache, scratch, 1024 * 1024)
	defer bootstrap_global_cache = old_cache

	ok, detail, _ = bridge_runtime_launch_agent("retry", command)
	testing.expect(t, !ok && strings.contains(detail, "spawn failed"), "successful Spawn loses ACK; duplicate Spawn is refused")
	thread.join(http_worker)
	testing.expect(t, http.served, "retry must bootstrap and Spawn instead of no-op on old live child")
	// Lose the bridge's in-memory projection, reload persisted credentials, and
	// retry again: PTY-host identity must preserve the genuine replacement.
	sync.mutex_lock(&bridge_runtime_mutex)
	for &inst in bridge_runtime_instances do if inst.agent_instance_id == id { inst.startup.generation = 0; inst.pty_process_alive = false }
	sync.mutex_unlock(&bridge_runtime_mutex)
	bridge_agent_token_store_load()
	ok, detail, _ = bridge_runtime_launch_agent("retry", command)
	testing.expect(t, ok, detail)
	recovered, exists := bridge_runtime_instance_snapshot(id)
	testing.expect(t, exists && recovered.startup.pty_pid == 202 && recovered.pty_process_alive, "restart recovery uses actual replacement PID")
	testing.expect(t, bridge_startup_fallback_due(recovered, recovered.startup.armed_at_ms + BRIDGE_START_SUCCESS_PROMPT_AFTER_MS), "restart recovery retains fallback")
	sync.atomic_store(&host.done, true); thread.join(worker)
	testing.expect_value(t, host.spawns, 1)
	testing.expect_value(t, host.closes, 1)
}
