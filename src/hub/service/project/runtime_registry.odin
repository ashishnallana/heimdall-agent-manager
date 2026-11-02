package project

import "base:runtime"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"
import domain "odin_test:hub/domain"
import metrics "odin_test:lib/metrics"
import lockorder "odin_test:lib/lockorder"
import ws "odin_test:lib/ws"

Runtime_Registry_Limits :: struct {
	live_bridges: int,
	live_bridges_per_owner: int,
	active_instances: int,
	active_instances_per_owner: int,
	terminal_instances_per_bridge: int,
	terminal_retention: time.Duration,
}

runtime_registry_limits :: proc(r: ^Bridge_Runtime_Registry) -> Runtime_Registry_Limits {
	limits := r.limits
	if limits.live_bridges <= 0 do limits.live_bridges = 1024
	if limits.live_bridges_per_owner <= 0 do limits.live_bridges_per_owner = 256
	if limits.active_instances <= 0 do limits.active_instances = 16384
	if limits.active_instances_per_owner <= 0 do limits.active_instances_per_owner = 2048
	if limits.terminal_instances_per_bridge <= 0 do limits.terminal_instances_per_bridge = 256
	if limits.terminal_retention <= 0 do limits.terminal_retention = 5 * time.Minute
	return limits
}

Runtime_Instance_State :: struct {
	owner_id: string,
	runtime_status: string,
	activity_status: string,
	state_seq: int,
	last_seen_ns: i64,
	expires_ns: i64,
	active: bool,
	reserved: bool,
}

// The registry and every reader/writer each own a reference. Retirement removes
// lookup visibility immediately, but the mutex, strings and state map survive
// until the final reference is released. Never copy a live connection value.
Bridge_Runtime_Connection :: struct {
    // Live-tools routing metadata only, owned by this connection reader.
    tool_live_epoch: [64]u8,
    tool_live_epoch_len: int,
    tool_live_seq: u64,
	bridge_id: string,
	owner_id: string,
	generation: int,
	socket: net.TCP_Socket,
	path_validation_adapter_registered: bool,
	path_validation_url: string,
	public_key: string,
	// Passwordless vault P1: the bridge's signed ephemeral unseal key. Always set
	// together with public_key (bridge_runtime_registry_set_unseal_identity) so a
	// signature can never be paired with a different key.
	unseal_boot_id: string,
	unseal_key_signature: string, // raw {"alg","sig"} object, or ""
	identity_public_key: string,
	identity_sign_alg: string,
	task_chain_search_ready: bool,
	task_chain_search_stale: bool,
	task_chain_search_revision: i64,
	references: int, // registry.metadata_mutex
	retired: bool, // atomic
	// Retirement notice has been sent; reject buffered inbound frames too.
	credential_revoked: bool, // atomic; transport owner still owns socket close
	writer_mutex: sync.Mutex,
	// Held across a whole CHUNKED command (REQ-ERR-PROTO-C) so two chunk sequences
	// never interleave, while writer_mutex is taken per frame so acks, pongs and small
	// commands still go out between chunks. Order: chunk_sequence_mutex, then
	// writer_mutex; never the reverse.
	chunk_sequence_mutex: sync.Mutex,
	// Single-frame writers waiting on writer_mutex (atomic). A chunked send yields to
	// them before each chunk, because writer_mutex is not fair: without this, the chunk
	// loop that just unlocked would usually win the lock straight back.
	writer_waiters: int,
	farewell_sent: bool, // writer_mutex; see bridge_runtime_connection_send_farewell
	retire_mutex: sync.Mutex,
	// state_mutex guards `instances`. Take it ONLY through
	// connection_state_lock/unlock: the allowed lock order is
	// sqlite.tx_mutex → state_mutex (a unit of work may reserve capacity), and
	// NEVER the reverse — code under state_mutex must not begin a unit of work
	// (see lib/lockorder; Task System v2 review B1).
	state_mutex: sync.Mutex,
	instances: map[string]Runtime_Instance_State,
	// Per-connection cached metric series (hot-path atomics only; the series
	// memory is owned by the metrics registry and never freed).
	tx_bytes: ^metrics.Series,
	rx_bytes: ^metrics.Series,
	// Last accepted heartbeat `stats` object (tick ns); enforces the 5 s cap.
	last_stats_tick_ns: i64,
	// bridge_log relay (plan §4.1).
	//   telemetry_enabled: cached owner switch (atomic; written at hello and by
	//                      PATCH); false only for "disabled" -> bridge_log
	//                      frames are dropped on the hub.
	//   log_tokens / log_tokens_tick_ns: per-connection token bucket, touched
	//                      only by this connection's reader thread
	//                      (burst BRIDGE_LOG_BUCKET_BURST, refill
	//                      BRIDGE_LOG_BUCKET_REFILL per BRIDGE_LOG_BUCKET_PERIOD).
	//                      log_tokens_tick_ns == 0 means "not yet initialised"
	//                      (a fresh connection starts with a full bucket).
	telemetry_enabled: bool,
	log_tokens: int,
	log_tokens_tick_ns: i64,
	terminal_count: int,
	next_sweep_ns: i64,
	// SESSION CREDENTIAL BOUND. The bridge WebSocket is authenticated once, at the
	// upgrade, by an `hba_` access token that lives one hour. Without a bound the
	// session outlived its credential: a bridge whose token had expired (or been
	// revoked) kept receiving launch_agent and PTY traffic for as long as the socket
	// stayed up (incident, 2026-10-25). auth_expires_unix_ms is the WALL-CLOCK
	// instant (unix ms) the presented token stops authenticating; 0 = no bound
	// recorded (unit fixtures that drive frames without an upgrade). Atomic: the
	// reader writes it (upgrade, in-band bridge_reauth), command senders read it.
	auth_expires_unix_ms: i64,
	// The token row backing the session, for the reader's periodic revocation
	// re-check. Reader-thread only.
	auth_token_id: [64]u8,
	auth_token_id_len: int,
	// Heartbeat metadata authority (plan T3), state_mutex. Set once by this
	// connection's hello before bridge_ready; see bridge_runtime_connection_set_metadata.
	//   metadata_recorded:   the hello installed a capability record for THIS connection
	//   metadata_omission:   both peers negotiated heartbeat metadata omission
	//   metadata_features:   canonical features array the stored record must hold
	//                        (heap); legacy beats on a non-negotiated connection move it
	metadata_recorded: bool,
	metadata_omission: bool,
	metadata_features: string,
}

// bridge_runtime_connection_set_metadata records the metadata contract this
// connection's hello installed. The caller holds connection_state_lock: the hello
// writes the durable record under the same lock, so a heartbeat (which reads these
// fields under it) can never observe the record without the contract or vice versa.
bridge_runtime_connection_set_metadata :: proc(c: ^Bridge_Runtime_Connection, omission: bool, features: string) {
	if c == nil do return
	heap := runtime.default_allocator()
	delete(c.metadata_features, heap)
	c.metadata_features = strings.clone(features, heap)
	c.metadata_omission = omission
	c.metadata_recorded = true
}

// bridge_runtime_connection_set_metadata_features moves the expected feature list after
// a legacy heartbeat on a NON-negotiated connection applied its own metadata. Caller
// holds connection_state_lock.
bridge_runtime_connection_set_metadata_features :: proc(c: ^Bridge_Runtime_Connection, features: string) {
	if c == nil || !c.metadata_recorded || c.metadata_features == features do return
	heap := runtime.default_allocator()
	delete(c.metadata_features, heap)
	c.metadata_features = strings.clone(features, heap)
}

// bridge_runtime_wall_ms is the clock the session bound is compared against.
bridge_runtime_wall_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

// bridge_runtime_connection_set_auth records the credential backing a session:
// its token id and how long it remains valid from now (`valid_for_ms`, computed by
// the caller against the hub clock so a test's fake clock and the wall clock never
// mix). valid_for_ms <= 0 bounds the session at now.
bridge_runtime_connection_set_auth :: proc(c: ^Bridge_Runtime_Connection, token_id: string, valid_for_ms: i64) {
	if c == nil do return
	n := min(len(token_id), len(c.auth_token_id))
	copy(c.auth_token_id[:], token_id[:n])
	c.auth_token_id_len = n
	sync.atomic_store(&c.auth_expires_unix_ms, bridge_runtime_wall_ms() + max(valid_for_ms, 0))
}

bridge_runtime_connection_auth_token_id :: proc(c: ^Bridge_Runtime_Connection) -> string {
	if c == nil do return ""
	return string(c.auth_token_id[:c.auth_token_id_len])
}

// bridge_runtime_connection_auth_expired reports whether the session's credential
// has run out. A connection with no recorded bound is not expired.
bridge_runtime_connection_auth_expired :: proc(c: ^Bridge_Runtime_Connection, now_ms: i64 = 0) -> bool {
	if c == nil do return false
	expires := sync.atomic_load(&c.auth_expires_unix_ms)
	if expires <= 0 do return false
	now := now_ms if now_ms > 0 else bridge_runtime_wall_ms()
	return now >= expires
}

Bridge_Runtime_Registry :: struct {
	connections: map[string]^Bridge_Runtime_Connection,
	next_generation: int,
	live_bridge_count: int,
	connection_count: int, // includes retired connections with outstanding leases
	metadata_mutex: sync.Mutex,
	connection_cond: sync.Cond,
	limits: Runtime_Registry_Limits,
	quota_mutex: sync.Mutex,
	active_instances: int,
	active_by_owner: map[string]int,
	edge_event_count: int,
	command_ids: [1024]string,
	command_bridge_ids: [1024]string,
	command_generations: [1024]int,
	command_results_json: [1024]string,
	command_results_terminal: [1024]bool,
	command_result_sequence: [1024]u64,
	command_count: int,
	command_slots_used: int,
	command_mutex: sync.Mutex,
	command_cond: sync.Cond,
}

bridge_runtime_registry_command_lock :: proc(r: ^Bridge_Runtime_Registry) { if r != nil do sync.lock(&r.command_mutex) }
bridge_runtime_registry_command_unlock :: proc(r: ^Bridge_Runtime_Registry) { if r != nil do sync.unlock(&r.command_mutex) }

bridge_runtime_connection_acquire :: proc(r: ^Bridge_Runtime_Registry, bridge_id: string, generation: int = 0) -> ^Bridge_Runtime_Connection {
	if r == nil do return nil
	sync.lock(&r.metadata_mutex)
	defer sync.unlock(&r.metadata_mutex)
	c, ok := r.connections[bridge_id]
	if !ok || (generation != 0 && c.generation != generation) do return nil
	c.references += 1
	return c
}

bridge_runtime_connection_release :: proc(r: ^Bridge_Runtime_Registry, c: ^Bridge_Runtime_Connection) {
	if r == nil || c == nil do return
	sync.lock(&r.metadata_mutex)
	c.references -= 1
	destroy := c.references == 0
	if destroy { r.connection_count -= 1; sync.cond_broadcast(&r.connection_cond) }
	sync.unlock(&r.metadata_mutex)
	if !destroy do return
	// No lease remains, so no writer or state reader can hold either mutex.
	heap := runtime.default_allocator()
	for key, state in c.instances {
		delete(key, heap)
		delete(state.owner_id, heap)
		delete(state.runtime_status, heap)
		delete(state.activity_status, heap)
	}
	delete(c.instances)
	delete(c.bridge_id, heap)
	delete(c.owner_id, heap)
	delete(c.path_validation_url, heap)
	delete(c.public_key, heap)
	delete(c.unseal_boot_id, heap)
	delete(c.unseal_key_signature, heap)
	delete(c.identity_public_key, heap)
	delete(c.identity_sign_alg, heap)
	delete(c.metadata_features, heap)
	free(c, heap)
}

runtime_active_change :: proc(r: ^Bridge_Runtime_Registry, owner: string, delta: int) -> bool {
	sync.lock(&r.quota_mutex)
	defer sync.unlock(&r.quota_mutex)
	count := r.active_by_owner[owner]
	limits := runtime_registry_limits(r)
	if delta > 0 && (r.active_instances >= limits.active_instances || count >= limits.active_instances_per_owner) {
		metrics.counter_inc(metrics.with(fleet_metrics.limit_rejections, "max_active_instances" if r.active_instances >= limits.active_instances else "active_instances_per_owner"))
		return false
	}
	if r.active_by_owner == nil do r.active_by_owner = make(map[string]int, runtime.default_allocator())
	if delta > 0 && count == 0 {
		r.active_by_owner[strings.clone(owner, runtime.default_allocator())] = delta
	} else if count + delta <= 0 {
		for key in r.active_by_owner {
			if key == owner {
				delete_key(&r.active_by_owner, key)
				delete(key, runtime.default_allocator())
				break
			}
		}
	} else {
		r.active_by_owner[owner] = count + delta
	}
	r.active_instances += delta
	return true
}

// Retire state and command observations before releasing the registry reference.
// Socket shutdown wakes a blocked writer; the reader remains the sole closer.
// All reader exits pass this barrier before the server closes its descriptor.
// Serializing shutdown and writer drain prevents a replacement thread from
// shutting down an fd after the old reader has closed it and it has been reused.
bridge_runtime_connection_quiesce :: proc(r: ^Bridge_Runtime_Registry, c: ^Bridge_Runtime_Connection) {
	if c == nil do return
	sync.lock(&c.retire_mutex)
	defer sync.unlock(&c.retire_mutex)
	sync.lock(&r.metadata_mutex)
	socket := c.socket
	sync.unlock(&r.metadata_mutex)
	if socket != net.TCP_Socket(0) do _ = net.shutdown(net.Any_Socket(socket), .Both)
	sync.lock(&c.writer_mutex)
	defer sync.unlock(&c.writer_mutex)
	// A socket setter might have been finishing when the first shutdown ran.
	if c.socket != socket && c.socket != net.TCP_Socket(0) do _ = net.shutdown(net.Any_Socket(c.socket), .Both)
	sync.lock(&r.metadata_mutex)
	c.socket = 0
	sync.unlock(&r.metadata_mutex)
}

bridge_runtime_connection_retire :: proc(r: ^Bridge_Runtime_Registry, c: ^Bridge_Runtime_Connection) {
	sync.atomic_store(&c.retired, true)
	bridge_runtime_connection_quiesce(r, c)
	connection_state_lock(c)
	for key, state in c.instances {
		if state.active do _ = runtime_active_change(r, state.owner_id, -1)
		heap := runtime.default_allocator()
		delete(key, heap)
		delete(state.owner_id, heap)
		delete(state.runtime_status, heap)
		delete(state.activity_status, heap)
	}
	delete(c.instances)
	c.instances = nil
	c.terminal_count = 0
	connection_state_unlock(c)
	sync.lock(&r.command_mutex)
	i := 0
	for i < r.command_slots_used {
		if r.command_bridge_ids[i] != c.bridge_id || r.command_generations[i] != c.generation { i += 1; continue }
		heap := runtime.default_allocator()
		delete(r.command_ids[i], heap)
		delete(r.command_bridge_ids[i], heap)
		delete(r.command_results_json[i], heap)
		last := r.command_slots_used - 1
		r.command_ids[i] = r.command_ids[last]
		r.command_bridge_ids[i] = r.command_bridge_ids[last]
		r.command_generations[i] = r.command_generations[last]
		r.command_results_json[i] = r.command_results_json[last]
		r.command_results_terminal[i] = r.command_results_terminal[last]
		r.command_result_sequence[i] = r.command_result_sequence[last]
		r.command_ids[last] = ""
		r.command_bridge_ids[last] = ""
		r.command_results_json[last] = ""
		r.command_slots_used -= 1
	}
	sync.cond_broadcast(&r.command_cond)
	sync.unlock(&r.command_mutex)
	bridge_runtime_connection_release(r, c)
}

// bridge_runtime_connection_send_farewell writes one final text frame (the hub's
// connection_replaced notice) to a SUPERSEDED connection's own socket, at most once
// per connection however many paths race to say it.
//
// Writer discipline: it holds THIS (old) connection's writer_mutex — never the
// replacement's — and reads c.socket under it. Every writer serializes on that mutex,
// and quiesce zeroes c.socket while holding it, before the reader may close the fd;
// so a non-zero socket seen here is still this connection's descriptor and the frame
// cannot interleave with another write or land on a reused fd. retired is NOT
// checked: the caller is by definition talking to a retired connection. A writer
// already blocked on a stalled peer delays this by at most the 5s Send_Timeout that
// set_command_socket installs.
bridge_runtime_connection_send_farewell :: proc(c: ^Bridge_Runtime_Connection, text: string) -> bool {
	if c == nil || text == "" do return false
	sync.lock(&c.writer_mutex)
	defer sync.unlock(&c.writer_mutex)
	if c.farewell_sent || c.socket == net.TCP_Socket(0) do return false
	c.farewell_sent = true
	return ws.write_server_text(c.socket, text, false) == .Ok
}

// replaced_farewell, when set, is delivered to the superseded connection (if any)
// before its retirement shuts the socket down — once the shutdown has run, nothing
// can reach that peer any more.
bridge_runtime_registry_accept_live :: proc(r: ^Bridge_Runtime_Registry, bridge_id: string, adapter: bool, url: string, owner: string = "", replaced_farewell: string = "") -> (replaced: bool, generation: int, ok: bool) {
	if r == nil || bridge_id == "" do return false, 0, false
	sync.lock(&r.metadata_mutex)
	old, exists := r.connections[bridge_id]
	limits := runtime_registry_limits(r)
	owner_count := 0
	for _, c in r.connections { if c.owner_id == owner do owner_count += 1 }
	if (!exists && (r.live_bridge_count >= limits.live_bridges || owner_count >= limits.live_bridges_per_owner)) || (exists && old.owner_id != owner) {
		sync.unlock(&r.metadata_mutex)
		switch {
		case exists:                                       metrics.counter_inc(metrics.with(fleet_metrics.limit_rejections, "owner_mismatch"))
		case r.live_bridge_count >= limits.live_bridges:   metrics.counter_inc(metrics.with(fleet_metrics.limit_rejections, "max_live_bridges"))
		case:                                              metrics.counter_inc(metrics.with(fleet_metrics.limit_rejections, "live_bridges_per_owner"))
		}
		return false, 0, false
	}
	heap := runtime.default_allocator()
	c := new(Bridge_Runtime_Connection, heap)
	r.next_generation += 1 // process-wide epoch; never resets when an ID is removed
	c^ = Bridge_Runtime_Connection{bridge_id = strings.clone(bridge_id, heap), owner_id = strings.clone(owner, heap), generation = r.next_generation, references = 1, path_validation_adapter_registered = adapter, path_validation_url = strings.clone(url, heap), instances = make(map[string]Runtime_Instance_State, heap), telemetry_enabled = true}
	c.tx_bytes = metrics.with(fleet_metrics.bridge_ws_bytes, bridge_id, "tx")
	c.rx_bytes = metrics.with(fleet_metrics.bridge_ws_bytes, bridge_id, "rx")
	if r.connections == nil do r.connections = make(map[string]^Bridge_Runtime_Connection, heap)
	if exists {
		// Remove the old owned map key before publishing the new generation.
		delete_key(&r.connections, old.bridge_id)
		sync.atomic_store(&old.retired, true)
	} else { r.live_bridge_count += 1 }
	r.connections[c.bridge_id] = c
	r.connection_count += 1
	generation = c.generation
	sync.unlock(&r.metadata_mutex)
	if exists {
		// The registry's lease keeps old alive until retire releases it below.
		_ = bridge_runtime_connection_send_farewell(old, replaced_farewell)
		bridge_runtime_connection_retire(r, old)
	}
	return exists, generation, true
}

bridge_runtime_registry_mark_live :: proc(r: ^Bridge_Runtime_Registry, bridge_id: string, adapter: bool, url: string) -> bool {
	if bridge_runtime_registry_has_live(r, bridge_id) do return true
	_, _, ok := bridge_runtime_registry_accept_live(r, bridge_id, adapter, url)
	return ok
}
bridge_runtime_registry_has_live :: proc(r: ^Bridge_Runtime_Registry, id: string) -> bool {
	c := bridge_runtime_connection_acquire(r, id)
	if c == nil do return false
	bridge_runtime_connection_release(r, c)
	return true
}
bridge_runtime_registry_generation :: proc(r: ^Bridge_Runtime_Registry, id: string) -> int {
	c := bridge_runtime_connection_acquire(r, id)
	if c == nil do return 0
	defer bridge_runtime_connection_release(r, c)
	return c.generation
}
bridge_runtime_registry_mark_offline :: proc(r: ^Bridge_Runtime_Registry, id: string, generation: int) {
	if r == nil do return
	sync.lock(&r.metadata_mutex)
	c, ok := r.connections[id]
	if !ok || (generation != 0 && c.generation != generation) { sync.unlock(&r.metadata_mutex); return }
	delete_key(&r.connections, c.bridge_id)
	sync.atomic_store(&c.retired, true)
	r.live_bridge_count -= 1
	sync.unlock(&r.metadata_mutex)
	bridge_runtime_connection_retire(r, c)
}
// bridge_runtime_connection_lock_writer takes writer_mutex for ONE frame and counts
// the caller as waiting meanwhile, so an in-flight chunked command lets it in first
// (REQ-ERR-PROTO-C). Pair with sync.unlock(&c.writer_mutex).
bridge_runtime_connection_lock_writer :: proc(c: ^Bridge_Runtime_Connection) {
	sync.atomic_add(&c.writer_waiters, 1)
	sync.lock(&c.writer_mutex)
	sync.atomic_sub(&c.writer_waiters, 1)
}

bridge_runtime_registry_set_command_socket :: proc(r: ^Bridge_Runtime_Registry, id: string, socket: net.TCP_Socket, generation: int = 0) {
	c := bridge_runtime_connection_acquire(r, id, generation)
	if c == nil do return
	defer bridge_runtime_connection_release(r, c)
	sync.lock(&c.writer_mutex)
	defer sync.unlock(&c.writer_mutex)
	if sync.atomic_load(&c.retired) do return
	// Bound writer teardown even when a peer stops reading.
	_ = net.set_option(socket, .Send_Timeout, 5 * time.Second)
	sync.lock(&r.metadata_mutex)
	c.socket = socket
	sync.unlock(&r.metadata_mutex)
}
// Bridge_Unseal_Identity is what a bridge_hello advertises for unseal: its ephemeral
// ECDH public key, the boot id, the identity key's signature over both, and the
// identity public key itself. The hub only relays these; clients verify them.
Bridge_Unseal_Identity :: struct {
	public_key:           string,
	unseal_boot_id:       string,
	unseal_key_signature: string,
	identity_public_key:  string,
	identity_sign_alg:    string,
}

bridge_unseal_identity_destroy :: proc(u: ^Bridge_Unseal_Identity, allocator := context.allocator) {
	delete(u.public_key, allocator)
	delete(u.unseal_boot_id, allocator)
	delete(u.unseal_key_signature, allocator)
	delete(u.identity_public_key, allocator)
	delete(u.identity_sign_alg, allocator)
	u^ = {}
}

bridge_runtime_registry_set_public_key :: proc(r: ^Bridge_Runtime_Registry, id, public_key: string, generation: int = 0) {
	bridge_runtime_registry_set_unseal_identity(r, id, Bridge_Unseal_Identity{public_key = public_key}, generation)
}

// bridge_runtime_registry_set_unseal_identity replaces ALL unseal fields at once:
// absent fields are cleared, never kept from an earlier hello.
bridge_runtime_registry_set_unseal_identity :: proc(r: ^Bridge_Runtime_Registry, id: string, u: Bridge_Unseal_Identity, generation: int = 0) {
	c := bridge_runtime_connection_acquire(r, id, generation)
	if c == nil do return
	defer bridge_runtime_connection_release(r, c)
	sync.lock(&c.writer_mutex)
	defer sync.unlock(&c.writer_mutex)
	heap := runtime.default_allocator()
	delete(c.public_key, heap)
	delete(c.unseal_boot_id, heap)
	delete(c.unseal_key_signature, heap)
	delete(c.identity_public_key, heap)
	delete(c.identity_sign_alg, heap)
	c.public_key = strings.clone(u.public_key, heap)
	c.unseal_boot_id = strings.clone(u.unseal_boot_id, heap)
	c.unseal_key_signature = strings.clone(u.unseal_key_signature, heap)
	c.identity_public_key = strings.clone(u.identity_public_key, heap)
	c.identity_sign_alg = strings.clone(u.identity_sign_alg, heap)
}

// Metadata strings are returned as caller-owned copies, never borrowed across retirement.
bridge_runtime_registry_public_key :: proc(r: ^Bridge_Runtime_Registry, id: string) -> string {
	c := bridge_runtime_connection_acquire(r, id)
	if c == nil do return ""
	defer bridge_runtime_connection_release(r, c)
	sync.lock(&c.writer_mutex)
	defer sync.unlock(&c.writer_mutex)
	return strings.clone(c.public_key)
}

// bridge_runtime_registry_unseal_identity returns a caller-owned copy of all unseal
// fields, read under one lock so they are mutually consistent.
bridge_runtime_registry_unseal_identity :: proc(r: ^Bridge_Runtime_Registry, id: string, allocator := context.allocator) -> (u: Bridge_Unseal_Identity, found: bool) {
	c := bridge_runtime_connection_acquire(r, id)
	if c == nil do return {}, false
	defer bridge_runtime_connection_release(r, c)
	sync.lock(&c.writer_mutex)
	defer sync.unlock(&c.writer_mutex)
	return Bridge_Unseal_Identity{
		public_key = strings.clone(c.public_key, allocator),
		unseal_boot_id = strings.clone(c.unseal_boot_id, allocator),
		unseal_key_signature = strings.clone(c.unseal_key_signature, allocator),
		identity_public_key = strings.clone(c.identity_public_key, allocator),
		identity_sign_alg = strings.clone(c.identity_sign_alg, allocator),
	}, true
}

bridge_runtime_registry_set_task_chain_search_status :: proc(r: ^Bridge_Runtime_Registry, id: string, generation: int, ready, stale: bool, revision: i64) {
	c := bridge_runtime_connection_acquire(r, id, generation)
	if c == nil do return
	defer bridge_runtime_connection_release(r, c)
	sync.lock(&c.writer_mutex); defer sync.unlock(&c.writer_mutex)
	c.task_chain_search_ready = ready
	c.task_chain_search_stale = stale
	c.task_chain_search_revision = revision
}

// bridge_runtime_registry_set_telemetry_enabled caches the owner's telemetry
// switch on the live connection (hello and PATCH); the bridge_log ingest reads
// it to enforce opt-out on the hub side.
bridge_runtime_registry_set_telemetry_enabled :: proc(r: ^Bridge_Runtime_Registry, id: string, enabled: bool) {
	c := bridge_runtime_connection_acquire(r, id)
	if c == nil do return
	defer bridge_runtime_connection_release(r, c)
	sync.atomic_store(&c.telemetry_enabled, enabled)
}

bridge_runtime_registry_task_chain_search_status :: proc(r: ^Bridge_Runtime_Registry, id: string) -> (ready, stale: bool, revision: i64) {
	c := bridge_runtime_connection_acquire(r, id)
	if c == nil do return false, false, 0
	defer bridge_runtime_connection_release(r, c)
	sync.lock(&c.writer_mutex); defer sync.unlock(&c.writer_mutex)
	return c.task_chain_search_ready, c.task_chain_search_stale, c.task_chain_search_revision
}
bridge_runtime_registry_has_path_validation_adapter :: proc(r: ^Bridge_Runtime_Registry, id: string) -> bool {
	c := bridge_runtime_connection_acquire(r, id)
	if c == nil do return false
	defer bridge_runtime_connection_release(r, c)
	return c.path_validation_adapter_registered || c.path_validation_url != ""
}
bridge_runtime_registry_path_validation_url :: proc(r: ^Bridge_Runtime_Registry, id: string) -> string {
	c := bridge_runtime_connection_acquire(r, id)
	if c == nil do return ""
	defer bridge_runtime_connection_release(r, c)
	return strings.clone(c.path_validation_url)
}
bridge_runtime_registry_shutdown_command_socket :: proc(r: ^Bridge_Runtime_Registry, id: string) -> bool {
	c := bridge_runtime_connection_acquire(r, id)
	if c == nil do return false
	defer bridge_runtime_connection_release(r, c)
	sync.lock(&c.writer_mutex)
	defer sync.unlock(&c.writer_mutex)
	if sync.atomic_load(&c.retired) do return false
	socket := c.socket
	if socket == net.TCP_Socket(0) do return false
	_ = net.shutdown(net.Any_Socket(socket), .Both)
	return true
}
bridge_runtime_registry_command_connection :: proc(r: ^Bridge_Runtime_Registry, id: string) -> (net.TCP_Socket, int, bool) {
	c := bridge_runtime_connection_acquire(r, id)
	if c == nil do return {}, 0, false
	defer bridge_runtime_connection_release(r, c)
	sync.lock(&c.writer_mutex)
	defer sync.unlock(&c.writer_mutex)
	return c.socket, c.generation, c.socket != net.TCP_Socket(0) && !sync.atomic_load(&c.retired)
}
bridge_runtime_registry_command_socket :: proc(r: ^Bridge_Runtime_Registry, id: string) -> (net.TCP_Socket, bool) {
	socket, _, ok := bridge_runtime_registry_command_connection(r, id)
	return socket, ok
}

runtime_state_active :: proc(status: string) -> bool {
	switch status {
	case "launching", "starting", "running", "idle", "busy", "blocked", "stopping": return true
	}
	return false
}

runtime_instance_remove_locked :: proc(c: ^Bridge_Runtime_Connection, key: string) {
	state := c.instances[key]
	if !state.active do c.terminal_count -= 1
	delete_key(&c.instances, key)
	heap := runtime.default_allocator()
	delete(key, heap)
	delete(state.owner_id, heap)
	delete(state.runtime_status, heap)
	delete(state.activity_status, heap)
}

runtime_instances_sweep_locked :: proc(r: ^Bridge_Runtime_Registry, c: ^Bridge_Runtime_Connection, now_ns: i64) -> int {
	keys := make([dynamic]string)
	defer delete(keys)
	for key, state in c.instances {
		if (!state.active || state.reserved) && state.expires_ns <= now_ns { append(&keys, key) }
	}
	for key in keys {
		state := c.instances[key]
		if state.active do _ = runtime_active_change(r, state.owner_id, -1)
		runtime_instance_remove_locked(c, key)
	}
	removed := len(keys)
	return removed
}

// Caller supplies a validated durable owner. Reports are scoped to a live generation.
// reservations consume quota before launch and have a deadline if no report follows.
bridge_runtime_instance_apply :: proc(r: ^Bridge_Runtime_Registry, bridge_id: string, generation: int, instance_id, owner, status, activity: string, seq: int, reserve: bool = false, now_ns: i64 = 0, recover: bool = false) -> (changed: bool, accepted: bool, err: domain.Domain_Error) {
	c := bridge_runtime_connection_acquire(r, bridge_id, generation)
	if c == nil do return false, false, domain.domain_error(.Bridge_Offline, "bridge connection is no longer current")
	defer bridge_runtime_connection_release(r, c)
	if instance_id == "" || (c.owner_id != "" && c.owner_id != owner) do return false, false, domain.domain_error(.Forbidden, "instance owner does not match bridge owner")
	connection_state_lock(c)
	defer connection_state_unlock(c)
	if sync.atomic_load(&c.retired) do return false, false, domain.domain_error(.Bridge_Offline, "bridge connection retired")
	now := now_ns if now_ns > 0 else time.now()._nsec
	if now >= c.next_sweep_ns {
		_ = runtime_instances_sweep_locked(r, c, now)
		c.next_sweep_ns = now + i64(20 * time.Second)
	}
	old, exists := c.instances[instance_id]
	if exists && !reserve && seq <= old.state_seq && !(recover && old.runtime_status == "unreachable" && runtime_state_active(status)) {
		if seq == old.state_seq && old.active && status == old.runtime_status {
			old.last_seen_ns = now
			c.instances[instance_id] = old
		}
		return false, false, domain.Domain_Error{}
	}
	if reserve && exists && old.active do return false, true, domain.Domain_Error{}
	active := runtime_state_active(status)
	if active && (!exists || !old.active) && !runtime_active_change(r, owner, 1) do return false, false, domain.domain_error(.Bridge_Busy, "active instance quota exhausted")
	if exists && old.active && !active do _ = runtime_active_change(r, old.owner_id, -1)
	// Lifecycle counters (plan 3.3), keyed by the status enum only: an instance
	// entering an active state from nothing/terminal is a start; an active one
	// entering a terminal state is an exit. Reservations are not starts.
	if !reserve {
		if active && (!exists || !old.active) do metrics.counter_inc(metrics.with(fleet_metrics.agent_instance_starts, runtime_status_enum(status)))
		if !active && exists && old.active do metrics.counter_inc(metrics.with(fleet_metrics.agent_instance_exits, runtime_status_enum(status)))
	}
	if !active && (!exists || old.active) do c.terminal_count += 1
	if active && exists && !old.active do c.terminal_count -= 1
	heap := runtime.default_allocator()
	state := Runtime_Instance_State{owner_id = strings.clone(owner, heap), runtime_status = strings.clone(status, heap), activity_status = strings.clone(activity, heap), state_seq = seq, last_seen_ns = now, active = active, reserved = reserve}
	if !active do state.expires_ns = now + i64(runtime_registry_limits(r).terminal_retention)
	if reserve {
		state.expires_ns = now + i64(time.Minute)
		if exists do state.state_seq = old.state_seq
	}
	if exists {
		changed = old.runtime_status != "" && old.runtime_status != status
		delete(old.owner_id, heap)
		delete(old.runtime_status, heap)
		delete(old.activity_status, heap)
		c.instances[instance_id] = state
	} else {
		c.instances[strings.clone(instance_id, heap)] = state
	}
	// Terminal state is bounded independently from active admission. Evict the
	// oldest terminal entry if necessary; the durable DB still rejects stale seqs.
	runtime_terminal_prune_locked(r, c)
	if changed do sync.atomic_add(&r.edge_event_count, 1)
	return changed, true, domain.Domain_Error{}
}

bridge_runtime_instance_get :: proc(r: ^Bridge_Runtime_Registry, bridge_id: string, generation: int, id: string) -> (Runtime_Instance_State, bool) {
	c := bridge_runtime_connection_acquire(r, bridge_id, generation)
	if c == nil do return {}, false
	defer bridge_runtime_connection_release(r, c)
	connection_state_lock(c)
	defer connection_state_unlock(c)
	if sync.atomic_load(&c.retired) do return {}, false
	state, ok := c.instances[id]
	if !ok do return {}, false
	state.owner_id = strings.clone(state.owner_id)
	state.runtime_status = strings.clone(state.runtime_status)
	state.activity_status = strings.clone(state.activity_status)
	return state, true
}

bridge_runtime_registry_sweep :: proc(r: ^Bridge_Runtime_Registry, now_ns: i64 = 0) -> int {
	if r == nil do return 0
	now := now_ns if now_ns > 0 else time.now()._nsec
	connections := make([dynamic]^Bridge_Runtime_Connection)
	defer delete(connections)
	sync.lock(&r.metadata_mutex)
	for _, c in r.connections { c.references += 1; append(&connections, c) }
	sync.unlock(&r.metadata_mutex)
	removed := 0
	for c in connections {
		connection_state_lock(c)
		removed += runtime_instances_sweep_locked(r, c, now)
		connection_state_unlock(c)
		bridge_runtime_connection_release(r, c)
	}
	return removed
}

bridge_runtime_registry_destroy :: proc(r: ^Bridge_Runtime_Registry) {
	if r == nil do return
	fleet_metrics_detach_registry(r)
	for len(r.connections) > 0 {
		for key, c in r.connections { bridge_runtime_registry_mark_offline(r, key, c.generation); break }
	}
	// The caller must stop accepting work before destroy. Wait for retired
	// reader/writer leases before the registry itself can leave scope.
	sync.lock(&r.metadata_mutex)
	for r.connection_count > 0 { sync.cond_wait(&r.connection_cond, &r.metadata_mutex) }
	sync.unlock(&r.metadata_mutex)
	delete(r.connections)
	r.connections = nil
	delete(r.active_by_owner)
	r.active_by_owner = nil
}

bridge_runtime_instance_cancel_reservation :: proc(r: ^Bridge_Runtime_Registry, bridge_id: string, generation: int, id: string) {
	c := bridge_runtime_connection_acquire(r, bridge_id, generation)
	if c == nil do return
	defer bridge_runtime_connection_release(r, c)
	connection_state_lock(c)
	defer connection_state_unlock(c)
	for key, state in c.instances {
		if key == id && state.reserved {
			if state.active do _ = runtime_active_change(r, state.owner_id, -1)
			runtime_instance_remove_locked(c, key)
			return
		}
	}
}

// A durable reaper/stop decision frees active quota without discarding the last
// sequence. Retain a bounded tombstone for delayed reports on this generation.
bridge_runtime_instance_retire :: proc(r: ^Bridge_Runtime_Registry, bridge_id: string, generation: int, id: string, status: string) {
	c := bridge_runtime_connection_acquire(r, bridge_id, generation)
	if c == nil do return
	defer bridge_runtime_connection_release(r, c)
	connection_state_lock(c)
	defer connection_state_unlock(c)
	state, ok := c.instances[id]
	if !ok || !state.active do return
	_ = runtime_active_change(r, state.owner_id, -1)
	delete(state.runtime_status, runtime.default_allocator())
	state.runtime_status = strings.clone(status, runtime.default_allocator())
	state.active = false
	c.terminal_count += 1
	state.reserved = false
	state.expires_ns = time.now()._nsec + i64(runtime_registry_limits(r).terminal_retention)
	c.instances[id] = state
	runtime_terminal_prune_locked(r, c)
}

runtime_terminal_prune_locked :: proc(r: ^Bridge_Runtime_Registry, c: ^Bridge_Runtime_Connection) {
	for c.terminal_count > runtime_registry_limits(r).terminal_instances_per_bridge {
		terminals := 0
		oldest_key := ""
		oldest := i64(0x7fff_ffff_ffff_ffff)
		for key, item in c.instances {
			if item.active do continue
			terminals += 1
			if oldest_key == "" || item.last_seen_ns < oldest { oldest = item.last_seen_ns; oldest_key = key }
		}
		if terminals <= runtime_registry_limits(r).terminal_instances_per_bridge do return
		runtime_instance_remove_locked(c, oldest_key)
	}
}

// connection_state_lock / unlock: the only way to take a connection's
// state_mutex (lock-order bookkeeping, see the field comment).
connection_state_lock :: proc(c: ^Bridge_Runtime_Connection) {
	sync.lock(&c.state_mutex)
	lockorder.state_mutex_enter()
}

connection_state_unlock :: proc(c: ^Bridge_Runtime_Connection) {
	lockorder.state_mutex_leave()
	sync.unlock(&c.state_mutex)
}
