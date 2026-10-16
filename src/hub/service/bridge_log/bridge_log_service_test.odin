package bridge_log

import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project_service "odin_test:hub/service/project"
import metrics "odin_test:lib/metrics"

// A recording repository: the writer's contract is "one insert_batch per
// flush, one cap per touched bridge", which is what these tests pin.
@(private = "file")
Fake_Repo :: struct {
	insert_calls:  int,
	rows:          int,
	last_batch:    int,
	cap_calls:     [dynamic]string,
	cap_keep:      int,
	prune_calls:   int,
	prune_before:  i64,
	deleted:       [dynamic]string,
	fail_insert:   bool,
}

@(private = "file")
fake_insert :: proc(ctx: rawptr, events: []domain.Bridge_Log_Event) -> (int, domain.Domain_Error) {
	f := (^Fake_Repo)(ctx)
	f.insert_calls += 1
	f.last_batch = len(events)
	if f.fail_insert do return 0, domain.domain_error(.Internal_Error, "boom")
	f.rows += len(events)
	return len(events), domain.Domain_Error{}
}
@(private = "file")
fake_cap :: proc(ctx: rawptr, bridge_id: string, keep: int) -> (int, domain.Domain_Error) {
	f := (^Fake_Repo)(ctx)
	append(&f.cap_calls, strings.clone(bridge_id))
	f.cap_keep = keep
	return 1, domain.Domain_Error{}
}
@(private = "file")
fake_prune :: proc(ctx: rawptr, before: i64) -> (int, domain.Domain_Error) {
	f := (^Fake_Repo)(ctx)
	f.prune_calls += 1
	f.prune_before = before
	return 7, domain.Domain_Error{}
}
@(private = "file")
fake_delete :: proc(ctx: rawptr, bridge_id: string) -> (int, domain.Domain_Error) {
	f := (^Fake_Repo)(ctx)
	append(&f.deleted, strings.clone(bridge_id))
	return 2, domain.Domain_Error{}
}
@(private = "file")
fake_list :: proc(ctx: rawptr, bridge_id: string, limit: int, before_id: i64) -> ([]domain.Bridge_Log_Event, domain.Domain_Error) {
	return nil, domain.Domain_Error{}
}
@(private = "file")
fake_count :: proc(ctx: rawptr, bridge_id: string) -> (int, domain.Domain_Error) {
	return (^Fake_Repo)(ctx).rows, domain.Domain_Error{}
}

@(private = "file")
fake_repo :: proc(f: ^Fake_Repo) -> iface.Bridge_Log_Repository {
	return iface.Bridge_Log_Repository{ctx = rawptr(f), insert_batch = fake_insert, cap_bridge = fake_cap, prune_before = fake_prune, list_by_bridge = fake_list, delete_by_bridge = fake_delete, count_by_bridge = fake_count}
}

@(private = "file")
fake_free :: proc(f: ^Fake_Repo) {
	for s in f.cap_calls do delete(s)
	delete(f.cap_calls)
	for s in f.deleted do delete(s)
	delete(f.deleted)
}

@(private = "file")
ev :: proc(bridge_id: string) -> domain.Bridge_Log_Event {
	return domain.Bridge_Log_Event{bridge_id = strings.clone(bridge_id), level = strings.clone("error"), code = strings.clone("internal"), fields_json = strings.clone("{}"), count = 1, ts_ms = 1, received_at = 1}
}

@(test)
test_bridge_log_writer_batches_and_caps_touched_bridges :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	f: Fake_Repo
	defer fake_free(&f)
	repo := fake_repo(&f)
	svc := new_service(&repo)
	defer service_free(&svc)

	for _ in 0 ..< 5 do testing.expect(t, enqueue(&svc, ev("brg_a")), "enqueue a")
	for _ in 0 ..< 3 do testing.expect(t, enqueue(&svc, ev("brg_b")), "enqueue b")
	testing.expect_value(t, pending(&svc), 8)
	before := metrics.counter_value(project_service.fleet_metrics.bridge_log_rows_written)

	st := flush_once(&svc)
	testing.expect(t, st.ok, "flush ok")
	testing.expect_value(t, st.taken, 8)
	testing.expect_value(t, st.inserted, 8)
	testing.expect_value(t, f.insert_calls, 1)
	testing.expect_value(t, f.last_batch, 8)
	testing.expect_value(t, len(f.cap_calls), 2)
	testing.expect_value(t, f.cap_keep, PER_BRIDGE_CAP)
	testing.expect_value(t, st.capped, 2)
	testing.expect_value(t, pending(&svc), 0)
	testing.expect_value(t, metrics.counter_value(project_service.fleet_metrics.bridge_log_rows_written) - before, u64(8))

	// Empty flush: no statement.
	st2 := flush_once(&svc)
	testing.expect(t, st2.ok && st2.taken == 0, "empty flush is a no-op")
	testing.expect_value(t, f.insert_calls, 1)

	// A failed insert does not cap or push, and the batch is released.
	f.fail_insert = true
	_ = enqueue(&svc, ev("brg_c"))
	st3 := flush_once(&svc)
	testing.expect(t, !st3.ok, "insert failure reported")
	testing.expect_value(t, len(f.cap_calls), 2)
	testing.expect_value(t, pending(&svc), 0)
}

@(test)
test_bridge_log_queue_is_bounded :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	f: Fake_Repo
	defer fake_free(&f)
	repo := fake_repo(&f)
	svc := new_service(&repo)
	defer service_free(&svc)
	svc.capacity = 4
	for _ in 0 ..< 4 do testing.expect(t, enqueue(&svc, ev("brg_a")), "under capacity")
	extra := ev("brg_a")
	testing.expect(t, !enqueue(&svc, extra), "over capacity is refused; caller keeps ownership")
	domain.bridge_log_event_destroy(&extra)
	testing.expect_value(t, pending(&svc), 4)
	_ = flush_once(&svc)
	testing.expect(t, enqueue(&svc, ev("brg_a")), "room again after a flush")
}

@(test)
test_bridge_log_push_sink_receives_committed_batch :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	f: Fake_Repo
	defer fake_free(&f)
	repo := fake_repo(&f)
	svc := new_service(&repo)
	defer service_free(&svc)
	Seen :: struct { calls, rows: int, bridge: string }
	seen: Seen
	set_push_sink(&svc, proc(ctx: rawptr, events: []domain.Bridge_Log_Event) {
		s := (^Seen)(ctx)
		s.calls += 1
		s.rows += len(events)
		if len(events) > 0 do s.bridge = events[0].bridge_id
	}, rawptr(&seen))
	_ = enqueue(&svc, ev("brg_push"))
	_ = enqueue(&svc, ev("brg_push"))
	_ = flush_once(&svc)
	testing.expect_value(t, seen.calls, 1)
	testing.expect_value(t, seen.rows, 2)
	testing.expect_value(t, seen.bridge, "brg_push")
	// Sink is NOT called when the insert failed.
	f.fail_insert = true
	_ = enqueue(&svc, ev("brg_push"))
	_ = flush_once(&svc)
	testing.expect_value(t, seen.calls, 1)
}

@(test)
test_bridge_log_prune_cadence_and_purge :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	f: Fake_Repo
	defer fake_free(&f)
	repo := fake_repo(&f)
	svc := new_service(&repo)
	defer service_free(&svc)

	now := i64(1_700_000_000_000)
	n, ran := maybe_prune(&svc, now)
	testing.expect(t, ran, "first sweep prunes")
	testing.expect_value(t, n, 7)
	testing.expect_value(t, f.prune_before, now - i64(RETENTION / time.Millisecond))
	_, ran2 := maybe_prune(&svc, now + i64(14 * time.Minute / time.Millisecond))
	testing.expect(t, !ran2, "not again within 15 min")
	_, ran3 := maybe_prune(&svc, now + i64(15 * time.Minute / time.Millisecond))
	testing.expect(t, ran3, "runs again at 15 min")
	testing.expect_value(t, f.prune_calls, 2)

	// Purge drops queued-but-unwritten rows of that bridge too.
	_ = enqueue(&svc, ev("brg_x"))
	_ = enqueue(&svc, ev("brg_y"))
	deleted, err := purge_bridge(&svc, "brg_x")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, deleted, 2)
	testing.expect_value(t, pending(&svc), 1)
	testing.expect_value(t, len(f.deleted), 1)
	testing.expect_value(t, f.deleted[0], "brg_x")
}

@(test)
test_bridge_log_writer_thread_drains_and_stops :: proc(t: ^testing.T) {
	project_service.fleet_metrics_init(metrics.init_global())
	f: Fake_Repo
	defer fake_free(&f)
	repo := fake_repo(&f)
	svc := new_service(&repo)
	start(&svc)
	for _ in 0 ..< FLUSH_THRESHOLD + 1 do _ = enqueue(&svc, ev("brg_t"))
	// Threshold wake-up: drained well before the 1 s tick.
	deadline := time.tick_now()
	// Wait for the WRITE, not just the dequeue: pending hits 0 as soon as the writer
	// takes the batch, before its rows reach the repo.
	for (pending(&svc) > 0 || sync.atomic_load(&f.rows) < FLUSH_THRESHOLD + 1) && time.tick_since(deadline) < 3 * time.Second do time.sleep(5 * time.Millisecond)
	testing.expect_value(t, pending(&svc), 0)
	testing.expect(t, f.rows >= FLUSH_THRESHOLD + 1, "rows written by the thread")
	_ = enqueue(&svc, ev("brg_t"))
	stop(&svc) // joins + final drain
	testing.expect_value(t, pending(&svc), 0)
	testing.expect_value(t, f.rows, FLUSH_THRESHOLD + 2)
	service_free(&svc)
}
