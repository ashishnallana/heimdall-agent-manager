package http

// The enroll-only bridge WebSocket (REQ-EA, plan task_18df06006e581bed).
//
// A pending enrollment's credential (BRIDGE_ENROLL_TOKEN_SCOPE) authenticates ONE
// thing: this socket, which `ham-bridge enroll` holds open while the browser relays
// the vault key to it. It is deliberately NOT the runtime socket with a flag:
//
//   - It registers under its own registry key, BRIDGE_ENROLL_REGISTRY_PREFIX +
//     bridge_id. An attach (REQ-EA-8) shares its bridge_id with a device that may be
//     connected right now; one key would make the two replace each other, and every
//     runtime-path lookup by bridge_id would reach the enroll process.
//   - It never calls bridge_runtime_connect, so a pending bridge is not flipped
//     Online and an attach target's row is not rewritten before the commit.
//   - Its loop dispatches command results and answers heartbeats, nothing else. The
//     runtime heartbeat handler reconciles instances against the reported active
//     set; the enroll process reports none, which on an attach would reap the
//     EXISTING device's running agents.
//
// The commit (bridge_unseal_handler -> bridge_service.commit_pending_enrollment) needs
// what this socket's hello said, so the session records it in g_enroll_hellos for its
// lifetime.

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"
import events "odin_test:hub/service/events"
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import project_service "odin_test:hub/service/project"

BRIDGE_ENROLL_REGISTRY_PREFIX :: "enroll:"

// bridge_enroll_registry_key is the runtime-registry key of a bridge's enroll-only
// socket. The caller owns the returned string.
bridge_enroll_registry_key :: proc(bridge_id: string, allocator := context.allocator) -> string {
	return strings.concatenate({BRIDGE_ENROLL_REGISTRY_PREFIX, bridge_id}, allocator)
}

// Bridge_Enroll_Hello is what the hub observed on an enroll-only socket, keyed by
// bridge_id: the family that authenticated it and the machine facts an attach
// commit writes onto the target row.
Bridge_Enroll_Hello :: struct {
	generation: int,
	family_id:  string,
	hostname:   string,
	os:         string,
	version:    string,
	public_key: string,
}

@(private = "file")
g_enroll_hellos: map[string]Bridge_Enroll_Hello
@(private = "file")
g_enroll_hellos_mu: sync.Mutex

@(private = "file")
bridge_enroll_hello_free :: proc(e: Bridge_Enroll_Hello) {
	delete(e.family_id)
	delete(e.hostname)
	delete(e.os)
	delete(e.version)
	delete(e.public_key)
}

bridge_enroll_hello_store :: proc(bridge_id: string, e: Bridge_Enroll_Hello) {
	sync.lock(&g_enroll_hellos_mu)
	defer sync.unlock(&g_enroll_hellos_mu)
	owned := Bridge_Enroll_Hello{
		generation = e.generation,
		family_id = strings.clone(e.family_id),
		hostname = strings.clone(e.hostname),
		os = strings.clone(e.os),
		version = strings.clone(e.version),
		public_key = strings.clone(e.public_key),
	}
	if old_key, old, found := map_entry_lookup(bridge_id); found {
		bridge_enroll_hello_free(old)
		g_enroll_hellos[old_key] = owned
		return
	}
	g_enroll_hellos[strings.clone(bridge_id)] = owned
}

@(private = "file")
map_entry_lookup :: proc(bridge_id: string) -> (string, Bridge_Enroll_Hello, bool) {
	for k, v in g_enroll_hellos {
		if k == bridge_id do return k, v, true
	}
	return "", Bridge_Enroll_Hello{}, false
}

// bridge_enroll_hello_get returns a CLONE the caller frees with
// bridge_enroll_hello_destroy.
bridge_enroll_hello_get :: proc(bridge_id: string) -> (Bridge_Enroll_Hello, bool) {
	sync.lock(&g_enroll_hellos_mu)
	defer sync.unlock(&g_enroll_hellos_mu)
	e, found := g_enroll_hellos[bridge_id]
	if !found do return Bridge_Enroll_Hello{}, false
	return Bridge_Enroll_Hello{
		generation = e.generation,
		family_id = strings.clone(e.family_id),
		hostname = strings.clone(e.hostname),
		os = strings.clone(e.os),
		version = strings.clone(e.version),
		public_key = strings.clone(e.public_key),
	}, true
}

bridge_enroll_hello_destroy :: proc(e: ^Bridge_Enroll_Hello) {
	bridge_enroll_hello_free(e^)
	e^ = Bridge_Enroll_Hello{}
}

// bridge_enroll_hello_forget drops the record, but only the one this generation
// wrote: a reconnect that already replaced it must keep its own.
bridge_enroll_hello_forget :: proc(bridge_id: string, generation: int) {
	sync.lock(&g_enroll_hellos_mu)
	defer sync.unlock(&g_enroll_hellos_mu)
	k, e, found := map_entry_lookup(bridge_id)
	if !found || e.generation != generation do return
	delete_key(&g_enroll_hellos, k)
	delete(k)
	bridge_enroll_hello_free(e)
}

// bridge_enroll_is_connected reports whether a bridge has a live enroll-only socket.
bridge_enroll_is_connected :: proc(h: ^Bridge_Handlers, bridge_id: string) -> bool {
	key := bridge_enroll_registry_key(bridge_id)
	defer delete(key)
	return project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry, key)
}

// bridge_ws_enroll_session runs an authenticated enroll-only socket until it closes.
// `hello_text` is the bridge_hello already read by the upgrade handler.
bridge_ws_enroll_session :: proc(
	h: ^Bridge_Handlers,
	client: net.TCP_Socket,
	reader: ^Bridge_WS_Reader,
	bridge_id, owner_user_id, family_id: string,
	hello_text, hostname, os_name, version: string,
) {
	key := bridge_enroll_registry_key(bridge_id)
	defer delete(key)
	hello, hello_ok, hello_err := bridge_runtime_service.runtime_accept_hello(h.bridge_runtime_registry, key, json_int(hello_text, "protocol_version", 1), "", owner_user_id, bridge_connection_replaced_payload())
	if !hello_ok {
		_ = write_ws_text_frame(client, bridge_ws_error_payload(hello_err.message))
		return
	}
	connection := project_service.bridge_runtime_connection_acquire(h.bridge_runtime_registry, key, hello.generation)
	if connection == nil do return
	reader.control_context = rawptr(connection)
	reader.control_writer = bridge_reader_write_pong
	defer project_service.bridge_runtime_connection_release(h.bridge_runtime_registry, connection)
	defer project_service.bridge_runtime_connection_quiesce(h.bridge_runtime_registry, connection)
	defer project_service.bridge_runtime_registry_mark_offline(h.bridge_runtime_registry, key, hello.generation)

	project_service.bridge_runtime_registry_set_command_socket(h.bridge_runtime_registry, key, client, hello.generation)
	public_key := json_string(hello_text, "public_key")
	defer delete(public_key)
	if public_key != "" do project_service.bridge_runtime_registry_set_public_key(h.bridge_runtime_registry, key, public_key, hello.generation)
	bridge_enroll_hello_store(bridge_id, Bridge_Enroll_Hello{
		generation = hello.generation,
		family_id = family_id,
		hostname = hostname,
		os = os_name,
		version = version,
		public_key = public_key,
	})
	defer bridge_enroll_hello_forget(bridge_id, hello.generation)

	// bridge_ready carries the REAL bridge_id: the bridge adopts it as its daemon_id.
	// Heartbeat stats are off — nothing on this socket ingests them.
	_ = write_ws_text_frame_locked(h, key, client, bridge_ready_payload(bridge_id, hello.generation, hello.replaced_existing, "", false))
	fmt.eprintfln("hub: bridge %s enroll-only socket connected (generation %d)", bridge_id, hello.generation)
	publish_bridge_enrollment_changed(h, owner_user_id, bridge_id)
	defer publish_bridge_enrollment_changed(h, owner_user_id, bridge_id)

	for {
		text, ok, _ := bridge_ws_read_frame(reader, 120 * time.Second)
		if !ok do return
		if project_service.bridge_runtime_registry_generation(h.bridge_runtime_registry, key) != hello.generation {
			delete(text)
			return
		}
		if reader.last_opcode == 0x2 {
			delete(text)
			continue
		}
		frame_type := json_string(text, "type")
		switch frame_type {
		case "bridge_unseal_result", "command_result":
			command_id := json_string(text, "command_id")
			_ = bridge_runtime_service.runtime_command_result_for_connection(h.bridge_runtime_registry, key, hello.generation, command_id, text)
			delete(command_id)
		case "bridge_heartbeat":
			_ = write_ws_text_frame_locked(h, key, client, bridge_heartbeat_ack_payload(0))
		case:
			// Everything else a full runtime would send — capabilities, vault status,
			// provider discovery, logs — is ignored: none of it may act on a bridge
			// that is not enrolled.
		}
		delete(frame_type)
		delete(text)
	}
}

// publish_bridge_enrollment_changed tells the owner's UI to re-read the bridge list
// and enrollment state. Best-effort: a missed event only delays a refresh.
publish_bridge_enrollment_changed :: proc(h: ^Bridge_Handlers, owner_user_id, bridge_id: string) {
	if h == nil || h.event_bus == nil || owner_user_id == "" do return
	events.publish_resource_changed(h.event_bus, owner_user_id, "bridge", bridge_id, "bridge_enrollment_changed", "{}")
}

// bridge_enroll_send_result tells an enroll-only socket whether its enrollment
// committed. Best-effort: a bridge that never hears keeps what it saved, and a
// rolled-back credential then simply fails to authenticate.
bridge_enroll_send_result :: proc(registry: ^project_service.Bridge_Runtime_Registry, enroll_key: string, committed: bool) {
	if registry == nil do return
	command_id := fmt.aprintf("cmd_enroll_result_%d", time.to_unix_nanoseconds(time.now()))
	defer delete(command_id)
	body := fmt.aprintf(`{"type":"bridge_enrollment_result","command_id":"%s","committed":%v}`, command_id, committed)
	defer delete(body)
	_, _ = bridge_runtime_service.send_runtime_command(rawptr(registry), project_service.Runtime_Command{bridge_id = enroll_key, command_id = command_id, body_json = body})
}
