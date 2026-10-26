package main

import "base:runtime"
import "core:encoding/json"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import ws "odin_test:lib/ws"

// Plan T1b: every hub connection opens with exactly one heartbeat, sent right after
// bridge_ready is handled, and the periodic cadence counts from that beat. The hub
// restores the search tuple, the instance status tuples and heartbeat liveness from
// it instead of waiting a full interval after every reconnect.
//
// Hermetic and parallel-safe: every process global these tests touch is held under
// the package test mutex that guards it (bridge config, keystore, search index), the
// heartbeat is built with resource stats off (stats fork `ps` and ensure a REAL
// pty-host daemon on the shared socket), runtime instances are inserted directly
// (no status-push queue, permission or tool-live side effects) under unique ids and
// removed again, and each connection is its own loopback socket pair.

@(private = "file")
Connect_Heartbeat_Pair :: struct {
	listener: net.TCP_Socket,
	sock:     net.TCP_Socket,
	peer:     net.TCP_Socket,
	conn:     ws.Connection,
	reader:   ws.Frame_Reader,
}

@(private = "file")
connect_heartbeat_pair_open :: proc(t: ^testing.T, pair: ^Connect_Heartbeat_Pair) -> bool {
	le: net.Network_Error
	pair.listener, le = net.listen_tcp({address = net.IP4_Loopback, port = 0})
	if le != nil do testing.fail_now(t, "listen")
	bound, _ := net.bound_endpoint(pair.listener)
	pe: net.Network_Error
	pair.peer, pe = net.dial_tcp(bound)
	if pe != nil do testing.fail_now(t, "dial")
	ae: net.Network_Error
	pair.sock, _, ae = net.accept_tcp(pair.listener)
	if ae != nil do testing.fail_now(t, "accept")
	pair.conn = ws.Connection{socket = pair.sock, connected = true}
	pair.reader = ws.reader_make()
	return true
}

@(private = "file")
connect_heartbeat_pair_close :: proc(pair: ^Connect_Heartbeat_Pair) {
	ws.reader_destroy(&pair.reader)
	net.close(pair.sock)
	net.close(pair.peer)
	net.close(pair.listener)
}

// Reads every frame that arrives within `wait`, counting the bridge_heartbeat ones;
// the first heartbeat is returned parsed (temp-allocated).
@(private = "file")
connect_heartbeat_read :: proc(t: ^testing.T, pair: ^Connect_Heartbeat_Pair, wait: time.Duration) -> (first: json.Object, heartbeats: int) {
	for {
		_, body, got := ws.read_frame(pair.peer, &pair.reader, wait)
		if !got do return
		defer delete(body)
		value, err := json.parse_string(body, .JSON, true, context.temp_allocator)
		testing.expect_value(t, err, json.Error.None)
		obj, _ := value.(json.Object)
		kind, _ := obj["type"].(json.String)
		if string(kind) != "bridge_heartbeat" do continue
		if heartbeats == 0 do first = obj
		heartbeats += 1
	}
}

@(private = "file")
connect_heartbeat_instance :: proc(frame: json.Object, id: string) -> (json.Object, bool) {
	instances, _ := frame["instances"].(json.Array)
	for entry in instances {
		obj, _ := entry.(json.Object)
		got, _ := obj["agent_instance_id"].(json.String)
		if string(got) == id do return obj, true
	}
	return nil, false
}

@(private = "file")
connect_heartbeat_instances_add :: proc(entries: [][2]string) {
	now := bridge_runtime_now_ms()
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	// The table is process-lifetime: never let a test's tracking allocator own it.
	if bridge_runtime_instances == nil do bridge_runtime_instances = make([dynamic]Bridge_Runtime_Instance, runtime.heap_allocator())
	for e in entries {
		append(&bridge_runtime_instances, Bridge_Runtime_Instance{
			agent_instance_id = strings.clone(e[0]), state_seq = 1,
			runtime_status = strings.clone(e[1]), activity_status = strings.clone("idle"),
			activity_source = strings.clone(""), activity_updated_unix_ms = now,
			last_seen_unix_ms = now, start_success_seen = true, pty_process_alive = e[1] == "running",
		})
	}
}

@(private = "file")
connect_heartbeat_instances_remove :: proc(entries: [][2]string) {
	sync.mutex_lock(&bridge_runtime_mutex)
	defer sync.mutex_unlock(&bridge_runtime_mutex)
	for e in entries {
		for i := len(bridge_runtime_instances) - 1; i >= 0; i -= 1 {
			inst := bridge_runtime_instances[i]
			if inst.agent_instance_id != e[0] do continue
			delete(inst.agent_instance_id); delete(inst.runtime_status)
			delete(inst.activity_status); delete(inst.activity_source)
			ordered_remove(&bridge_runtime_instances, i)
		}
	}
}

@(test)
test_connect_heartbeat_is_immediate_single_and_carries_repair_tuples :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	sync.mutex_lock(&task_chain_search_global_test_mutex)
	defer sync.mutex_unlock(&task_chain_search_global_test_mutex)
	bridge_heartbeat_stats_set_enabled(false)
	defer bridge_heartbeat_stats_set_enabled(true)

	// Search projection the hub must learn on connect, not 45s later.
	bridge_task_chain_search_lock()
	defer bridge_task_chain_search_lock()
	documents := [?]Task_Chain_Search_Document{{
		chain_id = "chain_connect_beat", project_id = "proj", status = "active",
		source_revision = 11, updated_at = "2026-10-26T13:00:00Z",
		title = "Connect heartbeat", description = "search tuple on the first beat",
	}}
	testing.expect(t, bridge_task_chain_search_rebuild(documents[:], 11), "rebuild should succeed")
	// One active and one terminal instance: the terminal tuple is the repair for a
	// status push dropped around the disconnect.
	active_id := "inst_connect_beat_active"
	stopped_id := "inst_connect_beat_stopped"
	entries := [?][2]string{{active_id, "running"}, {stopped_id, "failed"}}
	connect_heartbeat_instances_add(entries[:])
	defer connect_heartbeat_instances_remove(entries[:])

	pair: Connect_Heartbeat_Pair
	if !connect_heartbeat_pair_open(t, &pair) do return
	defer connect_heartbeat_pair_close(&pair)

	before := time.to_unix_nanoseconds(time.now())
	anchor := bridge_hub_send_connect_heartbeat(&pair.conn)
	testing.expect(t, anchor >= before, "the cadence is anchored at the connect beat")

	frame, beats := connect_heartbeat_read(t, &pair, 200 * time.Millisecond)
	testing.expect_value(t, beats, 1)
	if beats == 0 do return
	ready, _ := frame["task_chain_search_ready"].(json.Boolean)
	stale, _ := frame["task_chain_search_stale"].(json.Boolean)
	revision, _ := frame["task_chain_search_revision"].(json.Integer)
	testing.expect(t, bool(ready), "search ready reaches the hub on the connect beat")
	testing.expect(t, !bool(stale), "fresh index is not stale")
	testing.expect_value(t, i64(revision), i64(11))

	active_ids, _ := frame["active_instance_ids"].(json.Array)
	listed := false
	for v in active_ids {
		s, _ := v.(json.String)
		if string(s) == active_id do listed = true
		testing.expect(t, string(s) != stopped_id, "terminal instances are never listed active")
	}
	testing.expect(t, listed, "the active instance is listed for liveness reconcile")
	active, has_active := connect_heartbeat_instance(frame, active_id)
	testing.expect(t, has_active, "active status tuple present")
	if has_active {
		status, _ := active["runtime_status"].(json.String)
		testing.expect_value(t, string(status), "running")
	}
	stopped, has_stopped := connect_heartbeat_instance(frame, stopped_id)
	testing.expect(t, has_stopped, "terminal status tuple present for repair")
	if has_stopped {
		status, _ := stopped["runtime_status"].(json.String)
		testing.expect_value(t, string(status), "failed")
	}

	// Nothing is due on the same tick, nor just before one interval has passed.
	interval := i64(BRIDGE_HUB_HEARTBEAT_INTERVAL)
	last := anchor
	testing.expect(t, !bridge_hub_heartbeat_due(&last, anchor, interval), "no second beat in the connect tick")
	testing.expect(t, !bridge_hub_heartbeat_due(&last, anchor + interval - 1, interval), "no beat before the interval")
	testing.expect_value(t, last, anchor)
}

@(test)
test_heartbeat_cadence_sends_once_per_interval :: proc(t: ^testing.T) {
	interval := i64(45 * time.Second)
	anchor := i64(1_000_000_000)
	last := anchor
	testing.expect(t, !bridge_hub_heartbeat_due(&last, anchor, interval), "not due on the connect tick")
	testing.expect(t, bridge_hub_heartbeat_due(&last, anchor + interval, interval), "due exactly at one interval")
	testing.expect_value(t, last, anchor + interval)
	testing.expect(t, !bridge_hub_heartbeat_due(&last, anchor + interval, interval), "never twice in one tick")
	testing.expect(t, !bridge_hub_heartbeat_due(&last, anchor + 2 * interval - 1, interval), "not before the next interval")
	// A late tick (stalled loop) sends one beat and re-anchors on it.
	testing.expect(t, bridge_hub_heartbeat_due(&last, anchor + 2 * interval + 7, interval), "late tick sends")
	testing.expect_value(t, last, anchor + 2 * interval + 7)

	// Busy-loop ticks every 1ms over 3.5 intervals send exactly three beats.
	last = anchor
	sent := 0
	for now := anchor; now <= anchor + interval * 7 / 2; now += i64(time.Millisecond) {
		if bridge_hub_heartbeat_due(&last, now, interval) do sent += 1
	}
	testing.expect_value(t, sent, 3)
}

@(test)
test_heartbeat_interval_change_never_bursts :: proc(t: ^testing.T) {
	long := i64(45 * time.Second)
	short := i64(5 * time.Second)
	anchor := i64(0)
	last := anchor
	// A newer bridge_ready shortened the interval 20s after the last beat: four short
	// intervals are "missed", but exactly one beat goes out and the cadence restarts.
	now := anchor + 20 * i64(time.Second)
	testing.expect(t, bridge_hub_heartbeat_due(&last, now, short), "overdue beat goes out at once")
	testing.expect(t, !bridge_hub_heartbeat_due(&last, now, short), "no catch-up burst in the same tick")
	testing.expect(t, !bridge_hub_heartbeat_due(&last, now + short - 1, short), "next beat waits a short interval")
	testing.expect(t, bridge_hub_heartbeat_due(&last, now + short, short), "short cadence honoured")
	// Lengthened again: the longer interval counts from the last beat.
	last = now + short
	testing.expect(t, !bridge_hub_heartbeat_due(&last, last + short, long), "longer interval honoured")
	testing.expect(t, bridge_hub_heartbeat_due(&last, last + long, long), "due after the longer interval")
}

@(test)
test_reconnect_storm_sends_one_connect_heartbeat_per_connection :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	defer bridge_hub_set_heartbeat_interval(0)
	defer bridge_heartbeat_stats_set_enabled(true)

	previous_anchor := i64(0)
	for attempt in 0 ..< 3 {
		// Each reconnect's bridge_ready may move the interval; the connect beat is
		// sent regardless and the new connection's cadence starts from it.
		bridge_hub_apply_ready_settings(`{"type":"bridge_ready","heartbeat_stats":false,"heartbeat_interval_seconds":5}` if attempt % 2 == 0 else `{"type":"bridge_ready","heartbeat_stats":false}`)
		pair: Connect_Heartbeat_Pair
		if !connect_heartbeat_pair_open(t, &pair) do return
		anchor := bridge_hub_send_connect_heartbeat(&pair.conn)
		interval := sync.atomic_load(&bridge_hub_heartbeat_interval_ns)
		last := anchor
		// The connection's loop ticks right away: nothing more is due.
		for tick in 0 ..< 5 {
			testing.expect(t, !bridge_hub_heartbeat_due(&last, anchor + i64(tick) * i64(time.Millisecond), interval), "no same-tick double send after reconnect")
		}
		_, beats := connect_heartbeat_read(t, &pair, 150 * time.Millisecond)
		testing.expect_value(t, beats, 1)
		testing.expect(t, anchor >= previous_anchor, "each connection gets its own anchor")
		previous_anchor = anchor
		connect_heartbeat_pair_close(&pair)
	}
}

@(test)
test_ready_settings_tolerate_older_hub_payloads :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	defer bridge_hub_set_heartbeat_interval(0)
	defer bridge_heartbeat_stats_set_enabled(true)
	defer sync.atomic_store(&bridge_hub_credential_reauth_supported, false)

	// A current hub sets each member.
	bridge_hub_apply_ready_settings(`{"type":"bridge_ready","bridge_id":"brg_x","heartbeat_stats":false,"heartbeat_interval_seconds":30,"credential_reauth":true}`)
	testing.expect_value(t, sync.atomic_load(&bridge_hub_heartbeat_interval_ns), i64(30 * time.Second))
	testing.expect(t, !bridge_heartbeat_stats_enabled(), "heartbeat_stats:false opts out")
	testing.expect(t, sync.atomic_load(&bridge_hub_credential_reauth_supported), "credential_reauth negotiated")

	// An older hub sends none of them (and none of the newer plan flags): every
	// setting falls back to its default instead of keeping the previous session's.
	bridge_hub_apply_ready_settings(`{"type":"bridge_ready","bridge_id":"brg_x","catalog_etag":"e1"}`)
	testing.expect_value(t, sync.atomic_load(&bridge_hub_heartbeat_interval_ns), i64(BRIDGE_HUB_HEARTBEAT_INTERVAL))
	testing.expect(t, bridge_heartbeat_stats_enabled(), "stats default on")
	testing.expect(t, !sync.atomic_load(&bridge_hub_credential_reauth_supported), "reauth off without the flag")

	testing.expect(t, !sync.atomic_load(&bridge_hub_heartbeat_metadata_omission), "metadata omission off without the flag")
	testing.expect(t, !sync.atomic_load(&bridge_hub_diagnostics_frame_v1), "diagnostics frame off without the flag")

	// The plan T4 flags are parsed independently of the other members.
	defer bridge_hub_reset_heartbeat_negotiation()
	bridge_hub_apply_ready_settings(`{"type":"bridge_ready","heartbeat_interval_seconds":20,"heartbeat_metadata_omission":true,"diagnostics_frame_v1":true}`)
	testing.expect_value(t, sync.atomic_load(&bridge_hub_heartbeat_interval_ns), i64(20 * time.Second))
	testing.expect(t, sync.atomic_load(&bridge_hub_heartbeat_metadata_omission), "metadata omission negotiated")
	testing.expect(t, sync.atomic_load(&bridge_hub_diagnostics_frame_v1), "diagnostics frame advertised")
}
