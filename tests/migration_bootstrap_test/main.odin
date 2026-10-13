package migration_bootstrap_test

// BUG-14 / REQ-MIGRATE-1 — fresh-database bootstrap guard.
//
// A hub must be able to start against an EMPTY database and reach migration
// head. This test exists because that stopped being true without anyone
// noticing: migrations 001-028 were hand-copied into string literals in
// migrations.odin while migrations/*.sql kept evolving, so the two diverged.
// run_migrations reads <migrations_dir>/<name> when that relative directory
// resolves and falls back to the embedded constants otherwise — meaning a
// packaged binary run from anywhere but the repo root bootstrapped a fresh db
// onto a stale schema and died at 018, 030, 032 and 040 in turn. Every
// deployment passes --migrations-dir, which is exactly why QA and prod never
// saw it.
//
// So the assertion that matters is not just "migrations pass". It is:
//
//   1. the EMBEDDED path bootstraps an empty db to head (the path a packaged
//      binary takes, and the one that was broken),
//   2. the DISK path does too, and
//   3. the two produce the SAME schema — the drift guard. A stale literal that
//      still happens to be valid SQL would slip past (1) and (2) and silently
//      give a fresh install the wrong schema; only (3) catches that.
//
// Run: ham-migration-bootstrap-test [migrations-dir]
// The disk half self-skips with a notice when the directory is not found, so
// the test is still meaningful from an arbitrary working directory.

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import sqlite "odin_test:hub/repository/sqlite"

DEFAULT_MIGRATIONS_DIR :: "src/hub/repository/sqlite/migrations"

failures := 0

@(test)
test_migration_bootstrap :: proc(t: ^testing.T) {
	main()
	testing.expect_value(t, failures, 0)
}

fail :: proc(msg: string) {
	fmt.eprintfln("FAIL: %s", msg)
	failures += 1
}

check :: proc(ok: bool, msg: string) {
	if !ok do fail(msg)
}

// dump_schema returns every user object in the database as one normalized,
// sorted line per object, so two databases can be compared as plain text.
dump_schema :: proc(conn: ^sqlite.Conn) -> string {
	query := "SELECT type || ' ' || name || ' :: ' || COALESCE(sql, '') FROM sqlite_master WHERE name NOT LIKE 'sqlite_autoindex%' ORDER BY type, name;"
	stmt: sqlite.sqlite3_stmt = nil
	if sqlite.sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), c.int(-1), &stmt, nil) != sqlite.SQLITE_OK {
		return ""
	}
	defer sqlite.sqlite3_finalize(stmt)
	b := strings.builder_make()
	for sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW {
		// Collapse whitespace so formatting-only differences never trip the diff.
		for field in strings.fields(sqlite.column_text_unowned(stmt, 0), context.temp_allocator) {
			strings.write_string(&b, field)
			strings.write_byte(&b, ' ')
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// bootstrap runs the full chain against a brand-new database file and asserts
// it reaches head. migrations_dir == "" forces the embedded-constant path.
bootstrap :: proc(db_path, migrations_dir, label: string) -> (string, bool) {
	_ = os.remove(db_path)
	conn, open_ok, open_err := sqlite.open(db_path)
	if !open_ok {
		fail(fmt.tprintf("%s: open %s: %s", label, db_path, open_err.message))
		return "", false
	}
	defer sqlite.close(&conn)

	if ok, err := sqlite.run_migrations(&conn, migrations_dir); !ok {
		fail(fmt.tprintf("%s: a hub cannot bootstrap an EMPTY database: %s", label, err.message))
		return "", false
	}

	// Head reached means every version recorded, not merely "no error".
	for name in sqlite.migration_order {
		check(sqlite.migration_applied(&conn, name), fmt.tprintf("%s: migration %s did not reach head", label, name))
	}

	// Re-running must be a clean no-op: the already-migrated path stays intact.
	if ok, err := sqlite.run_migrations(&conn, migrations_dir); !ok {
		fail(fmt.tprintf("%s: re-running migrations is not a no-op: %s", label, err.message))
	}

	assert_bug14_anchors(&conn, label)
	return dump_schema(&conn), true
}

// assert_bug14_anchors pins the four shapes whose absence was each of BUG-14's
// four fatal migration failures, so a regression names itself instead of
// surfacing as an opaque "migration failed".
assert_bug14_anchors :: proc(conn: ^sqlite.Conn, label: string) {
	col :: proc(conn: ^sqlite.Conn, label, table, column, why: string) {
		if !sqlite.table_column_exists(conn, table, column) {
			fail(fmt.tprintf("%s: %s.%s missing on a fresh db (%s)", label, table, column, why))
		}
	}
	// (1) 018_coordinator_member_backfill backfills from this column.
	col(conn, label, "task_chains", "coordinator_agent_instance_id", "breaks 018")
	// (2) 030_search_fts_all rebuilds artifacts_fts from these.
	col(conn, label, "artifacts", "description", "breaks 030")
	// (3) 032_ai_native_templates inserts these and supplies no `body`.
	for c in ([]string{"is_system", "description", "persona", "instructions"}) {
		col(conn, label, "templates", c, "breaks 032")
	}
	check(!sqlite.table_column_exists(conn, "templates", "body"), fmt.tprintf("%s: templates.body is back; 032's insert does not supply it and it is NOT NULL", label))
	// (4) 040_artifact_list_indexes indexes these columns.
	for c in ([]string{"project_id", "agent_instance_id", "chain_id", "task_id"}) {
		col(conn, label, "artifacts", c, "breaks 040")
	}
	for idx in ([]string{"idx_artifacts_owner_created", "idx_artifacts_owner_project_created", "idx_artifacts_owner_instance_created", "idx_artifacts_owner_chain_created", "idx_artifacts_owner_task_created"}) {
		check(sqlite.sqlite_object_exists(conn, idx), fmt.tprintf("%s: index %s missing on a fresh db", label, idx))
	}
}

main :: proc() {
	failures = 0
	migrations_dir := DEFAULT_MIGRATIONS_DIR
	if len(os.args) > 1 && os.exists(os.args[1]) do migrations_dir = os.args[1]

	tmp := "/tmp/ham-migration-bootstrap-test"
	os.make_directory(tmp)

	// The path a packaged binary takes when --migrations-dir is not passed.
	// This is the half that was broken, so it is never skipped.
	embedded_db := strings.concatenate({tmp, "/embedded.db"}, context.temp_allocator)
	embedded_schema, embedded_ok := bootstrap(embedded_db, "", "embedded")
	defer _ = os.remove(embedded_db)
	compared := false

	// The path every deployment takes via --migrations-dir.
	disk_db := strings.concatenate({tmp, "/disk.db"}, context.temp_allocator)
	defer _ = os.remove(disk_db)
	if !os.exists(migrations_dir) {
		fmt.printfln("SKIP: migrations dir %q not found — disk-path and drift checks skipped.", migrations_dir)
		fmt.println("      Pass the directory as argv[1] (or run from the repo root) to enable them.")
	} else {
		disk_schema, disk_ok := bootstrap(disk_db, migrations_dir, "disk")
		compared = embedded_ok && disk_ok
		if compared && embedded_schema != disk_schema {
			fail("embedded migrations have DRIFTED from migrations/*.sql: the two bootstrap paths build different schemas.")
			fmt.eprintln("  Every MIGRATION_* constant must be #load(\"migrations/<file>.sql\", string) — never a hand-copied literal.")
			report_drift(embedded_schema, disk_schema)
		}
	}

	if failures > 0 {
		fmt.eprintfln("migration bootstrap test FAILED (%d problem(s))", failures)
		os.exit(1)
	}
	if compared {
		fmt.println("migration bootstrap test OK: an empty database reaches migration head on both the embedded and on-disk paths, with identical schemas.")
		return
	}
	// Say what was actually verified — a skipped drift check must not report as one that passed.
	fmt.println("migration bootstrap test OK (embedded path only): an empty database reaches migration head. Drift check SKIPPED — no migrations dir.")
}

// report_drift prints the objects that differ between the two schemas so the
// failure points at the migration to look at rather than just asserting.
report_drift :: proc(embedded, disk: string) {
	e := strings.split_lines(embedded, context.temp_allocator)
	d := strings.split_lines(disk, context.temp_allocator)
	side :: proc(lines: []string, other: []string, tag: string) {
		shown := 0
		for line in lines {
			if line == "" do continue
			found := false
			for o in other {
				if o == line {
					found = true
					break
				}
			}
			if found do continue
			if shown >= 10 {
				fmt.eprintln("  ... (more)")
				return
			}
			fmt.eprintfln("  %s only: %s", tag, line)
			shown += 1
		}
	}
	side(e, d, "embedded")
	side(d, e, "disk")
}
