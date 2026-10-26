// Focused tests for the bridge_diagnostics frame (minimal heartbeat plan §4.3, T5):
// strict limits and vocabularies, required scalars, validate-before-mutate, process
// restart vs. same-epoch ordering, generation fencing, unavailable/freshness, provider
// and recovery tombstones, and the stats opt-out. Every test uses its own bridge_id
// because the metrics registry and the diagnostics ordering state are process-global;
// rejection counters are fleet-wide (reason only), so tests assert growth, not deltas.
package http

import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import project_service "odin_test:hub/service/project"
import metrics "odin_test:lib/metrics"

@(private = "file")
DIAG_DISPATCH :: `"command_dispatch":{"accepted":120,"rejected":1,"completed":118,"deadline_expired":2}`
@(private = "file")
DIAG_BREAKERS :: `"dependency_breakers":{"open":1,"opened":3}`
@(private = "file")
DIAG_HTTP :: `"http_retries":{"retry":3,"recovered":2,"gave_up":1,"deferred":0}`
@(private = "file")
DIAG_RECOVERY :: `"operation_recovery":{"rows":[{"operation":"sync","state":"Backoff","code":"","class":"retriable","receipts":1}]}`
@(private = "file")
DIAG_STATS :: `"stats":{"rss":52428800,"pty_host_rss":10485760,"cpu_s":12.34,"host_mem_total":33554432000,"host_mem_avail":16777216000,"load1":0.42,"disk_free":50000000000,"instances":[{"provider":"claude","rss":209715200,"cpu_s":88.1}]}`

// diag_frame builds a frame; body is the comma-joined family members (may be "").
@(private = "file")
diag_frame :: proc(epoch: string, seq: int, body: string) -> string {
	sep := "," if body != "" else ""
	return fmt.tprintf(`{{"type":"bridge_diagnostics","schema":1,"process_epoch":"%s","sample_seq":%d,"collected_at_ms":1729940000000%s%s}}`, epoch, seq, sep, body)
}

@(private = "file")
diag_full :: proc(epoch: string, seq: int) -> string {
	return diag_frame(epoch, seq, strings.join({DIAG_DISPATCH, DIAG_BREAKERS, DIAG_HTTP, DIAG_RECOVERY, DIAG_STATS}, ",", context.temp_allocator))
}

@(private = "file")
diag_apply :: proc(bid: string, gen: int, text: string, connection: ^project_service.Bridge_Runtime_Connection = nil, now: i64 = 1_000) -> Diagnostics_Frame_Result {
	return bridge_apply_diagnostics_frame(nil, bid, gen, text, connection, now)
}

@(private = "file")
diag_rejected :: proc(reason: string) -> u64 {
	return metrics.counter_value(metrics.with(project_service.fleet_metrics.bridge_frames_rejected, reason))
}

@(private = "file")
diag_live :: proc(f: ^metrics.Family, values: ..string) -> bool {
	for s in f.series {
		if len(s.label_values) != len(values) do continue
		match := true
		for v, i in values do if s.label_values[i] != v { match = false; break }
		if match do return !metrics.series_is_dead(s)
	}
	return false
}

@(private = "file")
diag_fresh :: proc(bid, family: string) -> i64 {
	return metrics.gauge_value(metrics.with(project_service.fleet_metrics.bridge_diagnostics_last_sample, bid, family))
}

@(test)
test_diagnostics_full_snapshot_applied :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	m := &project_service.fleet_metrics
	bid := "brg_diag_full"
	defer project_service.fleet_metrics_tombstone_bridge(bid)
	testing.expect_value(t, diag_apply(bid, 1, diag_full("pe_a", 1), nil, 500), Diagnostics_Frame_Result.Applied)
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_dispatch, bid, "accepted")), u64(120))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_dispatch, bid, "shed")), u64(1))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_dispatch, bid, "completed")), u64(118))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_dispatch, bid, "deadline_expired")), u64(2))
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.bridge_breakers_open, bid)), i64(1))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_breaker_trips, bid)), u64(3))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_http_retries, bid, "gave_up")), u64(1))
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.bridge_recovery, bid, "sync", "Backoff", "", "retriable")), i64(1))
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.bridge_process_resident, bid, "bridge")), i64(52428800))
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.bridge_process_resident, bid, "pty_host")), i64(10485760))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_process_cpu, bid, "bridge")), u64(1234))
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.bridge_host_memory, bid, "total")), i64(33554432000))
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.bridge_host_load1, bid)), i64(42))
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.bridge_disk_free, bid)), i64(50000000000))
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.instance_resident, bid, "claude")), i64(209715200))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.instance_cpu, bid, "claude")), u64(8810))
	for family in ([]string{"frame", "command_dispatch", "dependency_breakers", "http_retries", "operation_recovery", "stats"}) {
		testing.expectf(t, diag_fresh(bid, family) == 500, "freshness for %s", family)
	}
	// Disconnect tombstones the freshness series with the rest.
	project_service.fleet_metrics_tombstone_bridge(bid)
	testing.expect(t, !diag_live(m.bridge_diagnostics_last_sample, bid, "frame"), "freshness tombstoned on disconnect")
	testing.expect(t, !diag_live(m.bridge_dispatch, bid, "accepted"), "dispatch tombstoned on disconnect")
}

// Frame-level rejections apply nothing: the series seeded by a good frame survive.
@(test)
test_diagnostics_frame_rejections_leave_series_untouched :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	m := &project_service.fleet_metrics
	bid := "brg_diag_reject"
	defer project_service.fleet_metrics_tombstone_bridge(bid)
	testing.expect_value(t, diag_apply(bid, 1, diag_full("pe_a", 1)), Diagnostics_Frame_Result.Applied)

	lower := diag_frame("pe_a", 9, `"command_dispatch":{"accepted":999,"rejected":1,"completed":200,"deadline_expired":2}`)
	padding := strings.repeat(" ", DIAGNOSTICS_MAX_FRAME_BYTES, context.temp_allocator)
	Case :: struct { text: string, want: Diagnostics_Frame_Result, reason: string }
	cases := []Case{
		{strings.concatenate({lower[:len(lower)-1], padding, "}"}, context.temp_allocator), .Rejected_Oversize, project_service.DIAGNOSTICS_REJECT_OVERSIZE},
		{strings.concatenate({lower, " {}"}, context.temp_allocator), .Rejected_Bad_Json, project_service.DIAGNOSTICS_REJECT_BAD_JSON},
		{strings.concatenate({lower[:len(lower)-1], `,"sample_seq":10}`}, context.temp_allocator), .Rejected_Bad_Json, project_service.DIAGNOSTICS_REJECT_BAD_JSON},
		{strings.concatenate({lower[:len(lower)-1], ",\"x\":\"\xff\"}"}, context.temp_allocator), .Rejected_Bad_Json, project_service.DIAGNOSTICS_REJECT_BAD_JSON},
		{`[1]`, .Rejected_Bad_Json, project_service.DIAGNOSTICS_REJECT_BAD_JSON},
		{strings.concatenate({`{"type":"bridge_heartbeat"`, lower[len(`{"type":"bridge_diagnostics"`):]}, context.temp_allocator), .Rejected_Envelope, project_service.DIAGNOSTICS_REJECT_ENVELOPE},
		{`{"type":"bridge_diagnostics","schema":2,"process_epoch":"pe_a","sample_seq":9,"collected_at_ms":1}`, .Rejected_Envelope, project_service.DIAGNOSTICS_REJECT_ENVELOPE},
		{`{"type":"bridge_diagnostics","schema":1,"sample_seq":9,"collected_at_ms":1}`, .Rejected_Envelope, project_service.DIAGNOSTICS_REJECT_ENVELOPE},
		{`{"type":"bridge_diagnostics","schema":1,"process_epoch":"","sample_seq":9,"collected_at_ms":1}`, .Rejected_Envelope, project_service.DIAGNOSTICS_REJECT_ENVELOPE},
		{`{"type":"bridge_diagnostics","schema":1,"process_epoch":"pe a","sample_seq":9,"collected_at_ms":1}`, .Rejected_Envelope, project_service.DIAGNOSTICS_REJECT_ENVELOPE},
		{`{"type":"bridge_diagnostics","schema":1,"process_epoch":"pe_a","sample_seq":0,"collected_at_ms":1}`, .Rejected_Envelope, project_service.DIAGNOSTICS_REJECT_ENVELOPE},
		{`{"type":"bridge_diagnostics","schema":1,"process_epoch":"pe_a","sample_seq":9.5,"collected_at_ms":1}`, .Rejected_Envelope, project_service.DIAGNOSTICS_REJECT_ENVELOPE},
		{`{"type":"bridge_diagnostics","schema":1,"process_epoch":"pe_a","sample_seq":"9","collected_at_ms":1}`, .Rejected_Envelope, project_service.DIAGNOSTICS_REJECT_ENVELOPE},
		{`{"type":"bridge_diagnostics","schema":1,"process_epoch":"pe_a","sample_seq":9}`, .Rejected_Envelope, project_service.DIAGNOSTICS_REJECT_ENVELOPE},
		{diag_frame("pe_a", 9, `"command_dispatch":[1,2,3,4]`), .Rejected_Envelope, project_service.DIAGNOSTICS_REJECT_ENVELOPE},
		{diag_frame("pe_a", 9, `"stats":null`), .Rejected_Envelope, project_service.DIAGNOSTICS_REJECT_ENVELOPE},
	}
	for c, i in cases {
		before := diag_rejected(c.reason)
		got := diag_apply(bid, 1, c.text)
		testing.expectf(t, got == c.want, "case %d: got %v want %v", i, got, c.want)
		testing.expectf(t, diag_rejected(c.reason) >= before + 1, "case %d counted as %s", i, c.reason)
	}
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_dispatch, bid, "accepted")), u64(120))
	// None of the rejected frames advanced ordering: seq 2 still applies.
	testing.expect_value(t, diag_apply(bid, 1, lower), Diagnostics_Frame_Result.Applied)
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_dispatch, bid, "accepted")), u64(999))
}

// A missing, mistyped or negative scalar inside a present family rejects that family
// only (never read as zero); the other families in the same frame still apply.
@(test)
test_diagnostics_missing_scalar_rejects_family_only :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	m := &project_service.fleet_metrics
	bid := "brg_diag_scalar"
	defer project_service.fleet_metrics_tombstone_bridge(bid)
	testing.expect_value(t, diag_apply(bid, 1, diag_full("pe_a", 1), nil, 100), Diagnostics_Frame_Result.Applied)
	bad := []string{
		`"command_dispatch":{"accepted":130,"rejected":1,"deadline_expired":2}`,
		`"command_dispatch":{"accepted":130,"rejected":1,"completed":"119","deadline_expired":2}`,
		`"command_dispatch":{"accepted":130,"rejected":-1,"completed":119,"deadline_expired":2}`,
		`"command_dispatch":{"accepted":130.5,"rejected":1,"completed":119,"deadline_expired":2}`,
		`"command_dispatch":{"accepted":9007199254740993,"rejected":1,"completed":119,"deadline_expired":2}`,
	}
	for body, i in bad {
		before := diag_rejected(project_service.DIAGNOSTICS_REJECT_INVALID_OBJECT)
		frame := diag_frame("pe_a", 2 + i, strings.concatenate({body, `,"http_retries":{"retry":4,"recovered":2,"gave_up":1,"deferred":0}`}, context.temp_allocator))
		testing.expectf(t, diag_apply(bid, 1, frame, nil, 200) == .Applied, "case %d frame accepted", i)
		testing.expectf(t, diag_rejected(project_service.DIAGNOSTICS_REJECT_INVALID_OBJECT) >= before + 1, "case %d counted", i)
		testing.expectf(t, metrics.counter_value(metrics.with(m.bridge_dispatch, bid, "accepted")) == 120, "case %d: dispatch untouched", i)
		testing.expectf(t, metrics.counter_value(metrics.with(m.bridge_dispatch, bid, "completed")) == 118, "case %d: completed not zeroed", i)
	}
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_http_retries, bid, "retry")), u64(4))
	testing.expect_value(t, diag_fresh(bid, "command_dispatch"), i64(100))
	testing.expect_value(t, diag_fresh(bid, "http_retries"), i64(200))
	// Stats: a missing gauge that was not declared unavailable rejects stats.
	before := diag_rejected(project_service.DIAGNOSTICS_REJECT_INVALID_OBJECT)
	testing.expect_value(t, diag_apply(bid, 1, diag_frame("pe_a", 20, `"stats":{"rss":1,"pty_host_rss":1,"cpu_s":13,"host_mem_total":1,"host_mem_avail":1,"disk_free":1,"instances":[]}`)), Diagnostics_Frame_Result.Applied)
	testing.expect(t, diag_rejected(project_service.DIAGNOSTICS_REJECT_INVALID_OBJECT) >= before + 1, "rejection counted")
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.bridge_host_load1, bid)), i64(42))
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.instance_resident, bid, "claude")), i64(209715200))
}

@(test)
test_diagnostics_recovery_vocab_and_limits :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	m := &project_service.fleet_metrics
	bid := "brg_diag_recovery"
	defer project_service.fleet_metrics_tombstone_bridge(bid)
	testing.expect_value(t, diag_apply(bid, 1, diag_full("pe_a", 1)), Diagnostics_Frame_Result.Applied)
	row :: proc(operation, state, code, class: string, receipts: int) -> string {
		return fmt.tprintf(`{{"operation":"%s","state":"%s","code":"%s","class":"%s","receipts":%d}}`, operation, state, code, class, receipts)
	}
	good := row("refresh", "Pending", "", "fatal", 2)
	// 257 valid rows cannot fit in a 16 KiB frame, so the row cap is exercised with
	// minimal items (each would also fail on its own; the cap is checked first).
	many := make([]string, 257, context.temp_allocator)
	for &r in many do r = "{}"
	wide := make([]string, 120, context.temp_allocator) // 120 rows * ~70 bytes > 8 KiB, < 16 KiB frame
	for &r, i in wide do r = row("sync", "Waiting_Repair", "", "recoverable", i % 10)
	bad := []string{
		row("sync", "backoff", "", "retriable", 1),          // lower-case state
		row("upload", "Backoff", "", "retriable", 1),        // unknown operation
		row("sync", "Backoff", "", "", 1),                   // empty class
		row("sync", "Backoff", "", "transient", 1),          // unknown class
		row("sync", "Backoff", "not_a_code", "retriable", 1), // unknown code
		row("sync", "Backoff", "", "retriable", 4097),       // receipts over cap
		`{"operation":"sync","state":"Backoff","class":"retriable","receipts":1}`, // missing code
		strings.join(many, ",", context.temp_allocator),     // 257 rows
		strings.join(wide, ",", context.temp_allocator),     // canonical size > 8 KiB
	}
	for rows, i in bad {
		before := diag_rejected(project_service.DIAGNOSTICS_REJECT_INVALID_OBJECT)
		// One bad row among good ones rejects the whole object.
		frame := diag_frame("pe_a", 2 + i, fmt.tprintf(`"operation_recovery":{{"rows":[%s,%s]}}`, good, rows))
		testing.expectf(t, diag_apply(bid, 1, frame) == .Applied, "case %d accepted at frame level", i)
		testing.expectf(t, diag_rejected(project_service.DIAGNOSTICS_REJECT_INVALID_OBJECT) >= before + 1, "case %d rejected object", i)
		testing.expectf(t, diag_live(m.bridge_recovery, bid, "sync", "Backoff", "", "retriable"), "case %d: previous rows kept", i)
		testing.expectf(t, !diag_live(m.bridge_recovery, bid, "refresh", "Pending", "", "fatal"), "case %d: no partial apply", i)
	}
	// Duplicate tuples are summed; a valid known code is accepted.
	dup := diag_frame("pe_a", 40, fmt.tprintf(`"operation_recovery":{{"rows":[%s,%s,%s]}}`, good, good, row("slot", "Exhausted", "bridge_offline", "retriable", 4)))
	testing.expect_value(t, diag_apply(bid, 1, dup), Diagnostics_Frame_Result.Applied)
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.bridge_recovery, bid, "refresh", "Pending", "", "fatal")), i64(4))
	testing.expect(t, !diag_live(m.bridge_recovery, bid, "sync", "Backoff", "", "retriable"), "full replacement tombstones unreported rows")
	// A valid empty list tombstones every recovery series.
	testing.expect_value(t, diag_apply(bid, 1, diag_frame("pe_a", 41, `"operation_recovery":{"rows":[]}`)), Diagnostics_Frame_Result.Applied)
	testing.expect(t, !diag_live(m.bridge_recovery, bid, "refresh", "Pending", "", "fatal"), "empty rows tombstone")
	// rows missing entirely is a missing scalar: rejected, nothing changes.
	before := diag_rejected(project_service.DIAGNOSTICS_REJECT_INVALID_OBJECT)
	testing.expect_value(t, diag_apply(bid, 1, diag_frame("pe_a", 42, `"operation_recovery":{}`)), Diagnostics_Frame_Result.Applied)
	testing.expect(t, diag_rejected(project_service.DIAGNOSTICS_REJECT_INVALID_OBJECT) >= before + 1, "rejection counted")
}

// Ordering: (process_epoch, sample_seq). Same epoch: duplicates and reordered samples
// drop, a lower cumulative counter rejects its family. New epoch: a Bridge restart,
// applied as a counter reset whatever its sample_seq, and counted.
@(test)
test_diagnostics_process_restart_and_ordering :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	m := &project_service.fleet_metrics
	bid := "brg_diag_order"
	defer project_service.fleet_metrics_tombstone_bridge(bid)
	restarts := metrics.with(m.bridge_diagnostics_restarts, bid)
	testing.expect_value(t, diag_apply(bid, 1, diag_full("pe_a", 1)), Diagnostics_Frame_Result.Applied)
	testing.expect_value(t, metrics.counter_value(restarts), u64(0)) // first sample is a baseline, not a restart

	stale_before := diag_rejected(project_service.DIAGNOSTICS_REJECT_STALE)
	testing.expect_value(t, diag_apply(bid, 1, diag_full("pe_a", 1)), Diagnostics_Frame_Result.Stale)
	higher := diag_frame("pe_a", 3, `"command_dispatch":{"accepted":200,"rejected":1,"completed":190,"deadline_expired":2}`)
	testing.expect_value(t, diag_apply(bid, 1, higher), Diagnostics_Frame_Result.Applied)
	reordered := diag_frame("pe_a", 2, `"command_dispatch":{"accepted":150,"rejected":1,"completed":140,"deadline_expired":2}`)
	testing.expect_value(t, diag_apply(bid, 1, reordered), Diagnostics_Frame_Result.Stale)
	testing.expect(t, diag_rejected(project_service.DIAGNOSTICS_REJECT_STALE) >= stale_before + 2, "rejection counted")
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_dispatch, bid, "accepted")), u64(200))

	// Same epoch, newer seq, lower counter: that family is rejected, the rest applies.
	regress_before := diag_rejected(project_service.DIAGNOSTICS_REJECT_COUNTER_REGRESSION)
	regress := diag_frame("pe_a", 4, `"command_dispatch":{"accepted":10,"rejected":1,"completed":190,"deadline_expired":2},"http_retries":{"retry":5,"recovered":2,"gave_up":1,"deferred":0},"dependency_breakers":{"open":0,"opened":2},"stats":{"rss":1,"pty_host_rss":1,"cpu_s":1.5,"host_mem_total":1,"host_mem_avail":1,"load1":0,"disk_free":1,"instances":[]}`)
	testing.expect_value(t, diag_apply(bid, 1, regress), Diagnostics_Frame_Result.Applied)
	testing.expect(t, diag_rejected(project_service.DIAGNOSTICS_REJECT_COUNTER_REGRESSION) >= regress_before + 3, "rejection counted") // dispatch, breakers, stats cpu
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_dispatch, bid, "accepted")), u64(200))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_breaker_trips, bid)), u64(3))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_process_cpu, bid, "bridge")), u64(1234))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_http_retries, bid, "retry")), u64(5))

	// New process: lower absolutes and sample_seq back to 1 are a reset, not a regression.
	restart := diag_frame("pe_b", 1, `"command_dispatch":{"accepted":5,"rejected":0,"completed":4,"deadline_expired":0},"dependency_breakers":{"open":0,"opened":0},"stats":{"rss":1,"pty_host_rss":1,"cpu_s":0.5,"host_mem_total":1,"host_mem_avail":1,"load1":0,"disk_free":1,"instances":[]}`)
	testing.expect_value(t, diag_apply(bid, 1, restart), Diagnostics_Frame_Result.Applied)
	testing.expect_value(t, metrics.counter_value(restarts), u64(1))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_dispatch, bid, "accepted")), u64(5))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_breaker_trips, bid)), u64(0))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_process_cpu, bid, "bridge")), u64(50))
	// From here on, same-epoch ordering and regression are measured against pe_b.
	testing.expect_value(t, diag_apply(bid, 1, diag_frame("pe_b", 2, `"command_dispatch":{"accepted":6,"rejected":0,"completed":5,"deadline_expired":0}`)), Diagnostics_Frame_Result.Applied)
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_dispatch, bid, "accepted")), u64(6))

	// Disconnect (tombstone) forgets ordering: the next connection's first snapshot is
	// a baseline, not a restart, and sample_seq starts over.
	project_service.fleet_metrics_tombstone_bridge(bid)
	testing.expect_value(t, diag_apply(bid, 2, diag_frame("pe_c", 1, DIAG_DISPATCH)), Diagnostics_Frame_Result.Applied)
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_diagnostics_restarts, bid)), u64(0))
}

// Generation fencing: once a newer connection generation delivered a snapshot, frames
// from older generations are dropped; the registry barrier drops a frame whose
// connection is no longer current even before any newer snapshot arrived.
@(test)
test_diagnostics_generation_superseded :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	m := &project_service.fleet_metrics
	bid := "brg_diag_generation"
	defer project_service.fleet_metrics_tombstone_bridge(bid)
	testing.expect_value(t, diag_apply(bid, 5, diag_frame("pe_a", 10, DIAG_DISPATCH)), Diagnostics_Frame_Result.Applied)
	testing.expect(t, project_service.bridge_diagnostics_owns_generation(bid, 5), "generation 5 owns diagnostics")
	testing.expect(t, !project_service.bridge_diagnostics_owns_generation(bid, 4), "generation 4 does not")
	before := diag_rejected(project_service.DIAGNOSTICS_REJECT_SUPERSEDED)
	testing.expect_value(t, diag_apply(bid, 4, diag_frame("pe_old", 99, `"command_dispatch":{"accepted":1,"rejected":0,"completed":0,"deadline_expired":0}`)), Diagnostics_Frame_Result.Superseded)
	testing.expect(t, diag_rejected(project_service.DIAGNOSTICS_REJECT_SUPERSEDED) >= before + 1, "rejection counted")
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_dispatch, bid, "accepted")), u64(120))
	// Reconnect of the same process: a newer generation continues the sequence.
	testing.expect_value(t, diag_apply(bid, 6, diag_frame("pe_a", 11, `"command_dispatch":{"accepted":121,"rejected":1,"completed":119,"deadline_expired":2}`)), Diagnostics_Frame_Result.Applied)
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_diagnostics_restarts, bid)), u64(0))

	// Registry barrier, with a real registry.
	reg: project_service.Bridge_Runtime_Registry
	defer project_service.bridge_runtime_registry_destroy(&reg)
	rbid := "brg_diag_generation_reg"
	defer project_service.fleet_metrics_tombstone_bridge(rbid)
	_, gen1, ok1 := project_service.bridge_runtime_registry_accept_live(&reg, rbid, false, "", "usr_diag")
	testing.expect(t, ok1, "gen1 admitted")
	_, gen2, ok2 := project_service.bridge_runtime_registry_accept_live(&reg, rbid, false, "", "usr_diag")
	testing.expect(t, ok2 && gen2 > gen1, "gen2 replaces gen1")
	testing.expect_value(t, bridge_apply_diagnostics_frame(&reg, rbid, gen1, diag_frame("pe_a", 1, DIAG_DISPATCH)), Diagnostics_Frame_Result.Superseded)
	testing.expect(t, !diag_live(m.bridge_dispatch, rbid, "accepted"), "replaced connection wrote nothing")
	testing.expect_value(t, bridge_apply_diagnostics_frame(&reg, rbid, gen2, diag_frame("pe_a", 1, DIAG_DISPATCH)), Diagnostics_Frame_Result.Applied)
}

// unavailable clears a gauge; a gauge both unavailable and sampled, an unknown or
// repeated name, or half of the host memory pair rejects stats; an absent family keeps
// its series and its (aging) freshness timestamp.
@(test)
test_diagnostics_unavailable_and_freshness :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	m := &project_service.fleet_metrics
	bid := "brg_diag_unavailable"
	defer project_service.fleet_metrics_tombstone_bridge(bid)
	testing.expect_value(t, diag_apply(bid, 1, diag_full("pe_a", 1), nil, 100), Diagnostics_Frame_Result.Applied)

	no_load := `"stats":{"rss":1,"pty_host_rss":1,"cpu_s":13,"host_mem_total":1,"host_mem_avail":1,"disk_free":1,"instances":[]}`
	bad := []string{
		strings.concatenate({DIAG_STATS, `,"unavailable":["load1"]`}, context.temp_allocator), // sampled and unavailable
		strings.concatenate({no_load, `,"unavailable":["load5"]`}, context.temp_allocator),
		strings.concatenate({no_load, `,"unavailable":["load1","load1"]`}, context.temp_allocator),
		strings.concatenate({no_load, `,"unavailable":"load1"`}, context.temp_allocator),
		`"stats":{"rss":1,"pty_host_rss":1,"cpu_s":13,"host_mem_avail":1,"load1":0,"disk_free":1,"instances":[]},"unavailable":["host_mem_total"]`,
	}
	for body, i in bad {
		before := diag_rejected(project_service.DIAGNOSTICS_REJECT_INVALID_OBJECT)
		testing.expectf(t, diag_apply(bid, 1, diag_frame("pe_a", 2 + i, body), nil, 200) == .Applied, "case %d frame accepted", i)
		testing.expectf(t, diag_rejected(project_service.DIAGNOSTICS_REJECT_INVALID_OBJECT) >= before + 1, "case %d rejected stats", i)
		testing.expectf(t, metrics.gauge_value(metrics.with(m.bridge_host_load1, bid)) == 42, "case %d: load1 untouched", i)
	}
	testing.expect_value(t, diag_fresh(bid, "stats"), i64(100))
	testing.expect_value(t, diag_fresh(bid, "frame"), i64(200))

	// Valid: load1 and the host memory pair unavailable -> cleared, the rest applied.
	ok_body := `"stats":{"rss":7,"pty_host_rss":1,"cpu_s":13,"disk_free":1,"instances":[]},"unavailable":["load1","host_mem_avail","host_mem_total"]`
	testing.expect_value(t, diag_apply(bid, 1, diag_frame("pe_a", 10, ok_body), nil, 300), Diagnostics_Frame_Result.Applied)
	testing.expect(t, !diag_live(m.bridge_host_load1, bid), "unavailable load1 cleared")
	testing.expect(t, !diag_live(m.bridge_host_memory, bid, "total"), "unavailable host memory cleared")
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.bridge_process_resident, bid, "bridge")), i64(7))
	testing.expect_value(t, diag_fresh(bid, "stats"), i64(300))

	// Absent stats: series kept, stats freshness keeps aging while the frame's advances.
	testing.expect_value(t, diag_apply(bid, 1, diag_frame("pe_a", 11, `"unavailable":["disk_free"]`), nil, 400), Diagnostics_Frame_Result.Applied)
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.bridge_disk_free, bid)), i64(1))
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.bridge_process_resident, bid, "bridge")), i64(7))
	testing.expect_value(t, diag_fresh(bid, "stats"), i64(300))
	testing.expect_value(t, diag_fresh(bid, "frame"), i64(400))
	testing.expect_value(t, diag_fresh(bid, "command_dispatch"), i64(100))
}

@(test)
test_diagnostics_provider_aggregates_tombstoned :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	m := &project_service.fleet_metrics
	bid := "brg_diag_providers"
	defer project_service.fleet_metrics_tombstone_bridge(bid)
	two := `"stats":{"rss":1,"pty_host_rss":1,"cpu_s":1,"host_mem_total":1,"host_mem_avail":1,"load1":0,"disk_free":1,"instances":[{"provider":"claude","rss":3,"cpu_s":1},{"provider":"/opt/weird","rss":4,"cpu_s":0.25},{"provider":"mystery","rss":5,"cpu_s":0.25}]}`
	testing.expect_value(t, diag_apply(bid, 1, diag_frame("pe_a", 1, two)), Diagnostics_Frame_Result.Applied)
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.instance_resident, bid, "other")), i64(9))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.instance_cpu, bid, "other")), u64(50))
	// Per-provider CPU legitimately drops when an instance exits: not a regression.
	one := `"stats":{"rss":1,"pty_host_rss":1,"cpu_s":2,"host_mem_total":1,"host_mem_avail":1,"load1":0,"disk_free":1,"instances":[{"provider":"claude","rss":3,"cpu_s":0.5}]}`
	testing.expect_value(t, diag_apply(bid, 1, diag_frame("pe_a", 2, one)), Diagnostics_Frame_Result.Applied)
	testing.expect_value(t, metrics.counter_value(metrics.with(m.instance_cpu, bid, "claude")), u64(50))
	testing.expect(t, !diag_live(m.instance_resident, bid, "other"), "vanished provider tombstoned")
	none := `"stats":{"rss":1,"pty_host_rss":1,"cpu_s":3,"host_mem_total":1,"host_mem_avail":1,"load1":0,"disk_free":1,"instances":[]}`
	testing.expect_value(t, diag_apply(bid, 1, diag_frame("pe_a", 3, none)), Diagnostics_Frame_Result.Applied)
	testing.expect(t, !diag_live(m.instance_resident, bid, "claude"), "valid empty list tombstones every provider")
	testing.expect(t, !diag_live(m.instance_cpu, bid, "claude"), "valid empty list tombstones provider cpu")
	// Over 16 entries rejects stats.
	items := make([]string, 17, context.temp_allocator)
	for &it in items do it = `{"provider":"codex","rss":1,"cpu_s":0}`
	over := fmt.tprintf(`"stats":{{"rss":1,"pty_host_rss":1,"cpu_s":4,"host_mem_total":1,"host_mem_avail":1,"load1":0,"disk_free":1,"instances":[%s]}}`, strings.join(items, ",", context.temp_allocator))
	before := diag_rejected(project_service.DIAGNOSTICS_REJECT_INVALID_OBJECT)
	testing.expect_value(t, diag_apply(bid, 1, diag_frame("pe_a", 4, over)), Diagnostics_Frame_Result.Applied)
	testing.expect(t, diag_rejected(project_service.DIAGNOSTICS_REJECT_INVALID_OBJECT) >= before + 1, "rejection counted")
	testing.expect(t, !diag_live(m.instance_resident, bid, "codex"), "rejected stats applied nothing")
}

// Owner telemetry "disabled": stats series are cleared on the first snapshot and any
// stats a frame still carries are ignored; reliability families apply unconditionally.
@(test)
test_diagnostics_stats_opt_out :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	m := &project_service.fleet_metrics
	bid := "brg_diag_optout"
	defer project_service.fleet_metrics_tombstone_bridge(bid)
	conn := project_service.Bridge_Runtime_Connection{telemetry_enabled = true}
	testing.expect_value(t, diag_apply(bid, 1, diag_full("pe_a", 1), &conn), Diagnostics_Frame_Result.Applied)
	testing.expect(t, diag_live(m.bridge_process_resident, bid, "bridge"), "stats applied while enabled")

	conn.telemetry_enabled = false
	testing.expect_value(t, diag_apply(bid, 1, diag_frame("pe_a", 2, `"http_retries":{"retry":9,"recovered":2,"gave_up":1,"deferred":0}`), &conn), Diagnostics_Frame_Result.Applied)
	for fam in ([]^metrics.Family{m.bridge_process_resident, m.bridge_process_cpu, m.bridge_host_memory, m.bridge_host_load1, m.bridge_disk_free, m.instance_resident, m.instance_cpu}) {
		for s in fam.series do if s.label_values[0] == bid do testing.expectf(t, metrics.series_is_dead(s), "%s cleared on opt-out", fam.name)
	}
	testing.expect(t, !diag_live(m.bridge_diagnostics_last_sample, bid, "stats"), "stats freshness cleared")
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_http_retries, bid, "retry")), u64(9))
	// A frame that still carries stats while disabled does not revive them.
	testing.expect_value(t, diag_apply(bid, 1, diag_full("pe_a", 3), &conn), Diagnostics_Frame_Result.Applied)
	testing.expect(t, !diag_live(m.bridge_process_resident, bid, "bridge"), "stats ignored while disabled")
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_dispatch, bid, "accepted")), u64(120))

	// Re-enabled: stats apply again (the cleared CPU baseline is not a regression).
	conn.telemetry_enabled = true
	testing.expect_value(t, diag_apply(bid, 1, diag_frame("pe_a", 4, `"stats":{"rss":2,"pty_host_rss":1,"cpu_s":1,"host_mem_total":1,"host_mem_avail":1,"load1":0,"disk_free":1,"instances":[]}`), &conn), Diagnostics_Frame_Result.Applied)
	testing.expect_value(t, metrics.gauge_value(metrics.with(m.bridge_process_resident, bid, "bridge")), i64(2))
}

// Through the real WS frame dispatcher: the new arm routes bridge_diagnostics, and the
// bridge_ready a runtime socket receives advertises diagnostics_frame_v1 (the enroll
// socket's default does not). Legacy heartbeat ingestion is untouched until a snapshot
// has been accepted on that generation.
@(test)
test_diagnostics_ws_arm_and_ready_flag :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	m := &project_service.fleet_metrics
	reg: project_service.Bridge_Runtime_Registry
	defer project_service.bridge_runtime_registry_destroy(&reg)
	bid := "brg_diag_ws"
	defer project_service.fleet_metrics_tombstone_bridge(bid)
	_, gen, ok := project_service.bridge_runtime_registry_accept_live(&reg, bid, false, "", "usr_diag")
	testing.expect(t, ok, "admitted")
	h := Bridge_Handlers{bridge_runtime_registry = &reg}
	testing.expect(t, !project_service.bridge_diagnostics_owns_generation(bid, gen), "legacy heartbeat diagnostics still ingested before any snapshot")
	frame := strings.clone(diag_full("pe_ws", 1))
	testing.expect(t, bridge_ws_process_frame(&h, bid, gen, net.TCP_Socket(0), nil, frame), "frame handled, connection kept")
	testing.expect_value(t, metrics.counter_value(metrics.with(m.bridge_dispatch, bid, "accepted")), u64(120))
	testing.expect(t, project_service.bridge_diagnostics_owns_generation(bid, gen), "snapshot now owns this generation's series")
	// A rejected frame is counted, never fatal.
	testing.expect(t, bridge_ws_process_frame(&h, bid, gen, net.TCP_Socket(0), nil, strings.clone(`{"type":"bridge_diagnostics","schema":1}`)), "malformed frame does not close")

	runtime_ready := bridge_ready_payload(bid, gen, false, "etag", true, BRIDGE_HUB_HEARTBEAT_METADATA_OMISSION, BRIDGE_HUB_DIAGNOSTICS_FRAME_V1)
	defer delete(runtime_ready)
	testing.expect(t, strings.contains(runtime_ready, `"diagnostics_frame_v1":true`), runtime_ready)
	testing.expect(t, strings.contains(runtime_ready, `"heartbeat_metadata_omission":true`), runtime_ready)
	enroll_ready := bridge_ready_payload(bid, gen, false, "", false)
	defer delete(enroll_ready)
	testing.expect(t, strings.contains(enroll_ready, `"diagnostics_frame_v1":false`), enroll_ready)
}
