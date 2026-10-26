package main

import "base:runtime"
import "core:encoding/json"
import "core:net"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import ws "odin_test:lib/ws"

// Minimal heartbeat plan T6: the bridge_diagnostics sender. The frame carries only
// consumed members, stats obey the telemetry switch while reliability families are
// unconditional, process_epoch is constant per process with a monotonic sample_seq,
// and a stalled collection never delays the heartbeat.
//
// The sampler (which would fork `ps` and ensure a REAL pty-host daemon) is always
// substituted with synthetic stats. Tests hold bridge_diagnostics_test_mutex (sampler,
// collector), bridge_test_config_mutex (negotiation flags, stats switch) and
// keystore_test_mutex (vault status in heartbeats), in that order.

bridge_diagnostics_test_mutex: sync.Mutex

@(private = "file")
diag_test_stats :: proc(allocator: runtime.Allocator) -> Heartbeat_Stats {
	st := Heartbeat_Stats{
		ok = true, rss = 52428800, pty_host_rss = 10485760, cpu_seconds = 12.34,
		host_mem_total = 33554432000, host_mem_avail = 16777216000, has_host_mem = true,
		has_load1 = false, disk_free = 50000000000, has_disk_free = true,
	}
	st.instances = make([dynamic]Stats_Instance, allocator)
	append(&st.instances, Stats_Instance{provider = "claude", rss_bytes = 209715200, cpu_seconds = 88.1})
	return st
}

@(private = "file")
diag_test_lock :: proc() {
	sync.mutex_lock(&bridge_diagnostics_test_mutex)
	sync.mutex_lock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
}

@(private = "file")
diag_test_unlock :: proc() {
	bridge_diagnostics_sample_stats = bridge_diagnostics_sample_stats_default
	bridge_heartbeat_stats_set_enabled(true)
	bridge_hub_reset_heartbeat_negotiation()
	bridge_hub_set_heartbeat_interval(0)
	sync.mutex_unlock(&keystore_test_mutex)
	sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_unlock(&bridge_diagnostics_test_mutex)
}

@(private = "file")
diag_test_parse :: proc(t: ^testing.T, text: string, loc := #caller_location) -> json.Object {
	value, err := json.parse_string(text, .JSON, true, context.temp_allocator)
	testing.expect_value(t, err, json.Error.None, loc)
	obj, ok := value.(json.Object)
	testing.expect(t, ok, "frame is a JSON object", loc = loc)
	return obj
}

@(private = "file")
diag_test_expect_keys :: proc(t: ^testing.T, obj: json.Object, want: []string, loc := #caller_location) {
	got := make([dynamic]string, context.temp_allocator)
	for k in obj do append(&got, k)
	slice.sort(got[:])
	sorted := slice.clone(want, context.temp_allocator)
	slice.sort(sorted)
	testing.expectf(t, slice.equal(got[:], sorted), "member set: got %v want %v", got[:], sorted, loc = loc)
}

@(private = "file")
diag_test_family :: proc(obj: json.Object, key: string) -> json.Object {
	o, _ := obj[key].(json.Object)
	return o
}

@(test)
test_diagnostics_frame_carries_only_consumed_members :: proc(t: ^testing.T) {
	diag_test_lock()
	defer diag_test_unlock()
	bridge_diagnostics_sample_stats = diag_test_stats
	bridge_heartbeat_stats_set_enabled(true)

	text := bridge_diagnostics_snapshot_json()
	defer delete(text)
	obj := diag_test_parse(t, text)
	diag_test_expect_keys(t, obj, {"type", "schema", "process_epoch", "sample_seq", "collected_at_ms", "command_dispatch", "dependency_breakers", "http_retries", "operation_recovery", "stats", "unavailable"})
	kind, _ := obj["type"].(json.String)
	testing.expect_value(t, string(kind), "bridge_diagnostics")
	schema, _ := obj["schema"].(json.Integer)
	testing.expect_value(t, schema, 1)
	diag_test_expect_keys(t, diag_test_family(obj, "command_dispatch"), {"accepted", "rejected", "completed", "deadline_expired"})
	diag_test_expect_keys(t, diag_test_family(obj, "dependency_breakers"), {"open", "opened"})
	diag_test_expect_keys(t, diag_test_family(obj, "http_retries"), {"retry", "recovered", "gave_up", "deferred"})
	diag_test_expect_keys(t, diag_test_family(obj, "operation_recovery"), {"rows"})
	rows, _ := diag_test_family(obj, "operation_recovery")["rows"].(json.Array)
	for row in rows do diag_test_expect_keys(t, row.(json.Object), {"operation", "state", "code", "class", "receipts"})

	// load1 was not sampled: absent from stats AND named unavailable, never both.
	stats := diag_test_family(obj, "stats")
	diag_test_expect_keys(t, stats, {"rss", "pty_host_rss", "cpu_s", "host_mem_total", "host_mem_avail", "disk_free", "instances"})
	unavailable, _ := obj["unavailable"].(json.Array)
	testing.expect_value(t, len(unavailable), 1)
	if len(unavailable) == 1 do testing.expect_value(t, string(unavailable[0].(json.String)), "load1")
	providers, _ := stats["instances"].(json.Array)
	testing.expect_value(t, len(providers), 1)
	if len(providers) == 1 do diag_test_expect_keys(t, providers[0].(json.Object), {"provider", "rss", "cpu_s"})
}

@(test)
test_diagnostics_unavailable_pairs_host_memory_and_is_omitted_when_complete :: proc(t: ^testing.T) {
	st := Heartbeat_Stats{ok = true, rss = 1, cpu_seconds = 0.5}
	b := strings.builder_make(context.temp_allocator)
	unavailable := heartbeat_stats_diagnostics_write(&b, st)
	testing.expect_value(t, unavailable, `["host_mem_total","host_mem_avail","load1","disk_free"]`)
	testing.expect_value(t, strings.to_string(b), `{"rss":1,"pty_host_rss":0,"cpu_s":0.50,"instances":[]}`)

	full := Heartbeat_Stats{ok = true, rss = 1, cpu_seconds = 1, host_mem_total = 4, host_mem_avail = 2, has_host_mem = true, load1 = 0.25, has_load1 = true, disk_free = 9, has_disk_free = true}
	b2 := strings.builder_make(context.temp_allocator)
	testing.expect_value(t, heartbeat_stats_diagnostics_write(&b2, full), "")
	testing.expect_value(t, strings.to_string(b2), `{"rss":1,"pty_host_rss":0,"cpu_s":1.00,"host_mem_total":4,"host_mem_avail":2,"load1":0.25,"disk_free":9,"instances":[]}`)

	// Providers are capped at the hub's 16-aggregate limit.
	many := Heartbeat_Stats{ok = true, has_host_mem = true, has_load1 = true, has_disk_free = true}
	many.instances = make([dynamic]Stats_Instance, context.temp_allocator)
	for _ in 0 ..< 20 do append(&many.instances, Stats_Instance{provider = "other"})
	b3 := strings.builder_make(context.temp_allocator)
	_ = heartbeat_stats_diagnostics_write(&b3, many)
	testing.expect_value(t, strings.count(strings.to_string(b3), `"provider"`), HEARTBEAT_STATS_DIAGNOSTICS_MAX_PROVIDERS)
}

@(test)
test_diagnostics_stats_follow_telemetry_switch_reliability_does_not :: proc(t: ^testing.T) {
	diag_test_lock()
	defer diag_test_unlock()
	bridge_diagnostics_sample_stats = diag_test_stats

	bridge_heartbeat_stats_set_enabled(false)
	off := bridge_diagnostics_snapshot_json()
	defer delete(off)
	diag_test_expect_keys(t, diag_test_parse(t, off), {"type", "schema", "process_epoch", "sample_seq", "collected_at_ms", "command_dispatch", "dependency_breakers", "http_retries", "operation_recovery"})

	// set_telemetry re-enables stats from the next snapshot.
	bridge_heartbeat_stats_set_enabled(true)
	on := bridge_diagnostics_snapshot_json()
	defer delete(on)
	on_obj := diag_test_parse(t, on)
	_, has_stats := on_obj["stats"]
	testing.expect(t, has_stats, "stats back after re-enable")

	// A failed `ps` sample omits stats (and unavailable) rather than inventing zeros.
	bridge_diagnostics_sample_stats = proc(allocator: runtime.Allocator) -> Heartbeat_Stats { return {} }
	failed := bridge_diagnostics_snapshot_json()
	defer delete(failed)
	failed_obj := diag_test_parse(t, failed)
	_, failed_stats := failed_obj["stats"]
	_, failed_unavailable := failed_obj["unavailable"]
	testing.expect(t, !failed_stats && !failed_unavailable, "no stats family on a failed sample")
}

@(test)
test_diagnostics_epoch_constant_and_sample_seq_monotonic_across_reconnect :: proc(t: ^testing.T) {
	diag_test_lock()
	defer diag_test_unlock()
	bridge_diagnostics_sample_stats = diag_test_stats

	epoch := bridge_diagnostics_process_epoch()
	testing.expect(t, strings.has_prefix(epoch, "pe_") && len(epoch) <= 64, "opaque bounded epoch")
	for i in 0 ..< len(epoch) do testing.expect(t, epoch[i] > 0x20 && epoch[i] < 0x7f, "printable ASCII epoch")

	last: i64 = 0
	for round in 0 ..< 3 {
		// A reconnect clears negotiation but never the process epoch or sequence.
		bridge_hub_reset_heartbeat_negotiation()
		bridge_hub_apply_ready_settings(`{"type":"bridge_ready","payload":{"heartbeat_metadata_omission":true,"diagnostics_frame_v1":true}}`)
		text := bridge_diagnostics_snapshot_json()
		defer delete(text)
		obj := diag_test_parse(t, text)
		got_epoch, _ := obj["process_epoch"].(json.String)
		testing.expect_value(t, string(got_epoch), epoch)
		seq, _ := obj["sample_seq"].(json.Integer)
		testing.expect(t, seq >= 1 && seq > last, "sample_seq strictly increases")
		last = seq
		_ = round
	}
}

@(private = "file")
Diag_Test_Pair :: struct {
	listener: net.TCP_Socket,
	sock:     net.TCP_Socket,
	peer:     net.TCP_Socket,
	conn:     ws.Connection,
	reader:   ws.Frame_Reader,
}

@(private = "file")
diag_test_pair_open :: proc(t: ^testing.T, pair: ^Diag_Test_Pair) {
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
}

@(private = "file")
diag_test_pair_close :: proc(pair: ^Diag_Test_Pair) {
	ws.reader_destroy(&pair.reader)
	net.close(pair.sock)
	net.close(pair.peer)
	net.close(pair.listener)
}

// Counts frames by type that arrive within `wait`; returns the diagnostics seqs.
@(private = "file")
diag_test_read :: proc(t: ^testing.T, pair: ^Diag_Test_Pair, wait: time.Duration) -> (heartbeats: int, diagnostics: [dynamic]i64, last_heartbeat: json.Object) {
	diagnostics = make([dynamic]i64, context.temp_allocator)
	for {
		_, body, got := ws.read_frame(pair.peer, &pair.reader, wait)
		if !got do return
		defer delete(body)
		obj := diag_test_parse(t, body)
		kind, _ := obj["type"].(json.String)
		switch string(kind) {
		case "bridge_heartbeat":
			heartbeats += 1
			last_heartbeat = obj
		case "bridge_diagnostics":
			seq, _ := obj["sample_seq"].(json.Integer)
			append(&diagnostics, seq)
		}
	}
}

@(private = "file")
diag_test_gate: sync.Sema
@(private = "file")
diag_test_entered: sync.Sema

@(test)
test_diagnostics_stalled_collection_never_delays_heartbeat :: proc(t: ^testing.T) {
	diag_test_lock()
	defer diag_test_unlock()
	bridge_diagnostics_discard()
	bridge_heartbeat_stats_set_enabled(true)
	// The sampler parks until released: a `ps` that hangs.
	bridge_diagnostics_sample_stats = proc(allocator: runtime.Allocator) -> Heartbeat_Stats {
		sync.sema_post(&diag_test_entered)
		sync.sema_wait(&diag_test_gate)
		return diag_test_stats(allocator)
	}

	pair: Diag_Test_Pair
	diag_test_pair_open(t, &pair)
	defer diag_test_pair_close(&pair)

	bridge_hub_reset_heartbeat_negotiation()
	bridge_hub_apply_ready_settings(`{"type":"bridge_ready","payload":{"heartbeat_interval_seconds":1,"heartbeat_metadata_omission":true,"diagnostics_frame_v1":true}}`)
	bridge_heartbeat_stats_set_enabled(true)
	interval := sync.atomic_load(&bridge_hub_heartbeat_interval_ns)

	started := time.now()
	last_heartbeat := bridge_hub_send_connect_heartbeat(&pair.conn)
	cadence: Bridge_Diagnostics_Cadence
	bridge_diagnostics_connect(&cadence, last_heartbeat)
	testing.expect(t, sync.sema_wait_with_timeout(&diag_test_entered, 2 * time.Second), "collector entered the stalled sample")

	// Several intervals pass while collection is stuck: the loop keeps beating and
	// requests coalesce into a flag; nothing is sent and nothing blocks.
	beats_sent := 1
	now := last_heartbeat
	for _ in 0 ..< 5 {
		now += interval
		tick_started := time.now()
		if bridge_hub_heartbeat_due(&last_heartbeat, now, interval) {
			hb := bridge_hub_heartbeat_json()
			_ = ws.send_text(&pair.conn, hb)
			delete(hb)
			beats_sent += 1
		}
		bridge_diagnostics_tick(&pair.conn, &cadence, now, interval)
		testing.expect(t, time.duration_milliseconds(time.since(tick_started)) < 500, "a loop tick never waits for collection")
	}
	testing.expect(t, time.duration_seconds(time.since(started)) < 2, "liveness unaffected by the stall")
	heartbeats, diagnostics, core := diag_test_read(t, &pair, 200 * time.Millisecond)
	testing.expect_value(t, heartbeats, beats_sent)
	testing.expect_value(t, len(diagnostics), 0)
	// Negotiated both flags: the eight-member core, no diagnostics riding it.
	diag_test_expect_keys(t, core, {"type", "protocol_version", "vault_status", "task_chain_search_ready", "task_chain_search_stale", "task_chain_search_revision", "active_instance_ids", "instances"})

	// Release the sample: the finished snapshot(s) go out on later ticks. The pending
	// requests coalesced, so at most one more collection follows.
	sync.sema_post(&diag_test_gate, 2)
	sent := false
	deadline := time.now()
	for time.duration_seconds(time.since(deadline)) < 3 {
		if frame, ok := bridge_diagnostics_take(); ok {
			_ = ws.send_text(&pair.conn, frame)
			bridge_diagnostics_frame_free(frame)
			sent = true
		} else if sent {
			// Allow a coalesced follow-up collection to finish.
			time.sleep(100 * time.Millisecond)
			if frame2, ok2 := bridge_diagnostics_take(); ok2 {
				_ = ws.send_text(&pair.conn, frame2)
				bridge_diagnostics_frame_free(frame2)
			}
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, sent, "snapshot delivered after the stall cleared")
	_, after, _ := diag_test_read(t, &pair, 200 * time.Millisecond)
	testing.expect(t, len(after) >= 1 && len(after) <= 2, "requests coalesced: one or two snapshots, not one per tick")
	for i in 1 ..< len(after) do testing.expect(t, after[i] > after[i - 1], "sample_seq increases")
	// Drain the semaphore credits a coalesced follow-up did not use.
	for sync.sema_wait_with_timeout(&diag_test_entered, 10 * time.Millisecond) {}
	for sync.sema_wait_with_timeout(&diag_test_gate, 0) {}
	bridge_diagnostics_discard()
}

@(test)
test_diagnostics_not_sent_without_flag :: proc(t: ^testing.T) {
	diag_test_lock()
	defer diag_test_unlock()
	bridge_diagnostics_sample_stats = diag_test_stats
	pair: Diag_Test_Pair
	diag_test_pair_open(t, &pair)
	defer diag_test_pair_close(&pair)

	// Metadata alone (or no flags): no frame, and the heartbeat keeps diagnostics.
	for ready in ([]string{`{"type":"bridge_ready","payload":{"heartbeat_metadata_omission":true}}`, `{"type":"bridge_ready","payload":{}}`}) {
		bridge_hub_reset_heartbeat_negotiation()
		bridge_hub_apply_ready_settings(ready)
		bridge_heartbeat_stats_set_enabled(false)
		now := time.to_unix_nanoseconds(time.now())
		cadence: Bridge_Diagnostics_Cadence
		bridge_diagnostics_connect(&cadence, now)
		bridge_diagnostics_tick(&pair.conn, &cadence, now + i64(time.Hour), i64(time.Second))
		hb := bridge_hub_heartbeat_json()
		obj := diag_test_parse(t, hb)
		_, has_dispatch := obj["command_dispatch"]
		testing.expect(t, has_dispatch, "legacy diagnostics stay on the heartbeat without the flag")
		delete(hb)
	}
	_, diagnostics, _ := diag_test_read(t, &pair, 150 * time.Millisecond)
	testing.expect_value(t, len(diagnostics), 0)
}
