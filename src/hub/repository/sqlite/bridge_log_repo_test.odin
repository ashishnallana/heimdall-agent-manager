package sqlite

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(private = "file")
mk_event :: proc(bridge_id: string, i: int, received_at: i64) -> domain.Bridge_Log_Event {
	return domain.Bridge_Log_Event{
		bridge_id   = bridge_id,
		ts_ms       = received_at - 5,
		received_at = received_at,
		level       = "error" if i % 2 == 0 else "warn",
		code        = "provider_missing",
		fields_json = `{"provider":"claude"}`,
		count       = 1 + i % 3,
	}
}

@(test)
test_bridge_log_repo_sqlite_batch_cap_page_prune :: proc(t: ^testing.T) {
	conn, mig_ok := tmpl_clone_migrated(t)
	testing.expect(t, mig_ok, "migrated template clone ok")
	defer close(&conn)
	testing.expect(t, table_column_exists(&conn, "bridge_log_events", "fields_json"), "084 applied")

	impl := Bridge_Log_Repo_SQLite{}
	repo := new_bridge_log_repository(&impl, &conn)

	// One batch bigger than the per-statement chunk: 600 rows for A, 5 for B.
	batch := make([dynamic]domain.Bridge_Log_Event)
	defer delete(batch)
	for i in 0 ..< 600 do append(&batch, mk_event("brg_a", i, 1_000_000 + i64(i)))
	for i in 0 ..< 5 do append(&batch, mk_event("brg_b", i, 2_000_000 + i64(i)))
	n, err := iface.bridge_log_insert_batch(&repo, batch[:])
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, n, 605)
	ca, _ := iface.bridge_log_count_by_bridge(&repo, "brg_a")
	testing.expect_value(t, ca, 600)

	// Per-bridge cap keeps the NEWEST 500 of A and leaves B alone.
	removed, cap_err := iface.bridge_log_cap_bridge(&repo, "brg_a", 500)
	testing.expect_value(t, cap_err.code, domain.Error_Code.None)
	testing.expect_value(t, removed, 100)
	ca, _ = iface.bridge_log_count_by_bridge(&repo, "brg_a")
	testing.expect_value(t, ca, 500)
	cb, _ := iface.bridge_log_count_by_bridge(&repo, "brg_b")
	testing.expect_value(t, cb, 5)
	removed2, _ := iface.bridge_log_cap_bridge(&repo, "brg_a", 500)
	testing.expect_value(t, removed2, 0)

	// Newest first, paginated by id.
	page1, lerr := iface.bridge_log_list_by_bridge(&repo, "brg_a", 3, 0)
	testing.expect_value(t, lerr.code, domain.Error_Code.None)
	testing.expect_value(t, len(page1), 3)
	testing.expect(t, page1[0].id > page1[1].id && page1[1].id > page1[2].id, "descending ids")
	testing.expect_value(t, page1[0].received_at, i64(1_000_599))
	testing.expect_value(t, page1[0].fields_json, `{"provider":"claude"}`)
	testing.expect_value(t, page1[0].bridge_id, "brg_a")
	last := page1[2].id
	domain.bridge_log_events_destroy(page1)
	page2, _ := iface.bridge_log_list_by_bridge(&repo, "brg_a", 3, last)
	testing.expect_value(t, len(page2), 3)
	testing.expect(t, page2[0].id < last, "before_id excludes the cursor row")
	testing.expect_value(t, page2[0].received_at, i64(1_000_596))
	domain.bridge_log_events_destroy(page2)
	// The oldest surviving A row is #100 (0..99 were capped away).
	tail, _ := iface.bridge_log_list_by_bridge(&repo, "brg_a", 1000, 0)
	testing.expect_value(t, len(tail), 500)
	testing.expect_value(t, tail[len(tail) - 1].received_at, i64(1_000_100))
	domain.bridge_log_events_destroy(tail)

	// Time prune by received_at: everything of A is older than 1_500_000.
	pruned, perr := iface.bridge_log_prune_before(&repo, 1_500_000)
	testing.expect_value(t, perr.code, domain.Error_Code.None)
	testing.expect_value(t, pruned, 500)
	cb, _ = iface.bridge_log_count_by_bridge(&repo, "brg_b")
	testing.expect_value(t, cb, 5)

	// Revoke / owner purge.
	deleted, derr := iface.bridge_log_delete_by_bridge(&repo, "brg_b")
	testing.expect_value(t, derr.code, domain.Error_Code.None)
	testing.expect_value(t, deleted, 5)
	cb, _ = iface.bridge_log_count_by_bridge(&repo, "brg_b")
	testing.expect_value(t, cb, 0)

	// Empty batch is a no-op.
	n0, e0 := iface.bridge_log_insert_batch(&repo, nil)
	testing.expect_value(t, n0, 0)
	testing.expect_value(t, e0.code, domain.Error_Code.None)
}
