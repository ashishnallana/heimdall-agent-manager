package sqlite

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"

// step_changes must report the rows ITS statement changed even while another thread
// writes on the same connection — the hub's shape (one conn, one thread per request).
// A bare step + sqlite3_changes read the noise thread's 0-row count often enough to
// make a real single-use spend look like reuse; that revoked a live bridge's token
// family in production.

@(private = "file")
Step_Changes_Noise :: struct {
	conn: ^Conn,
	stop: bool,
}

@(private = "file")
step_changes_noise_run :: proc(data: rawptr) {
	noise := (^Step_Changes_Noise)(data)
	query := "UPDATE spend_probe SET spent = spent WHERE id = -1;"
	for !sync.atomic_load(&noise.stop) {
		stmt: sqlite3_stmt = nil
		if sqlite3_prepare_v2(noise.conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return
		_ = sqlite3_step(stmt)
		sqlite3_finalize(stmt)
	}
}

@(test)
test_step_changes_is_per_statement_under_concurrent_writes :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("%s/test_step_changes_%d.db", os.get_env("HOME", context.temp_allocator), os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)
	conn, open_ok, _ := open(db_path)
	testing.expect(t, open_ok, "open succeeds")
	defer close(&conn)

	ROWS :: 2000
	testing.expect(t, exec(&conn, "CREATE TABLE spend_probe(id INTEGER PRIMARY KEY, spent INTEGER NOT NULL DEFAULT 0);"), "create table")
	testing.expect(t, exec(&conn, fmt.tprintf("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i < %d) INSERT INTO spend_probe(id) SELECT i FROM n;", ROWS)), "seed rows")

	noise := Step_Changes_Noise{conn = &conn}
	worker := thread.create_and_start_with_data(rawptr(&noise), step_changes_noise_run)

	query := "UPDATE spend_probe SET spent = 1 WHERE id = ? AND spent = 0;"
	misreported := 0
	for id in 1 ..= ROWS {
		stmt: sqlite3_stmt = nil
		if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do break
		sqlite3_bind_int(stmt, 1, i32(id))
		rc, changes := step_changes(conn.db, stmt)
		sqlite3_finalize(stmt)
		if rc != SQLITE_DONE || changes != 1 do misreported += 1
	}

	sync.atomic_store(&noise.stop, true)
	thread.join(worker)
	thread.destroy(worker)
	testing.expect_value(t, misreported, 0)
}
