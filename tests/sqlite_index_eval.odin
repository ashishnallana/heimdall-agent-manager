// Standalone index evaluation for REQ-INDEX; never connects to a Hub.
// Usage: sqlite_index_eval <scratch.db> <t1|prod>
// Calls the REAL repository procs; the SQL they prepare is captured through
// sqlite3_trace_v2 and only then EXPLAINed, so no workload SQL is copied here.
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:encoding/json"
import domain "odin_test:hub/domain"
import dbt "odin_test:hub/platform/dbtelemetry"
import metrics "odin_test:lib/metrics"
import sql "odin_test:hub/repository/sqlite"

when ODIN_OS == .Windows {
	foreign import sqlite3_lib "system:sqlite3.lib"
} else {
	foreign import sqlite3_lib "system:sqlite3"
}
@(default_calling_convention = "c")
foreign sqlite3_lib {
	sqlite3_trace_v2 :: proc(db: sql.sqlite3, mask: c.uint, cb: proc "c" (c.uint, rawptr, rawptr, rawptr) -> c.int, ctx: rawptr) -> c.int ---
}
SQLITE_TRACE_STMT :: 0x01

NOW :: "2026-10-22T00:00:00Z"
OLD :: "2026-09-01T00:00:00Z"
OWNER :: "index-owner"
WARM_N :: 50

Counts :: struct { vm, fullscan, sort, page_writes: i64 }

reg: ^metrics.Registry
conn: sql.Conn
db_path: string
shell_impl: sql.Shell_Session_Repo_SQLite
content_impl: sql.Content_Repo_SQLite
task_impl: sql.Taskchain_Repo_SQLite
captured: [dynamic]string
capturing: bool

trace_cb :: proc "c" (mask: c.uint, ctx, p, x: rawptr) -> c.int {
	context = runtime.default_context()
	if capturing && mask == SQLITE_TRACE_STMT {
		text := string(sql.sqlite3_sql(sql.sqlite3_stmt(p)))
		if !strings.has_prefix(strings.trim_space(text), "--") do append(&captured, strings.clone(text, context.temp_allocator))
	}
	return 0
}

snapshot :: proc() -> Counts {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	metrics.gather(reg, &b)
	r: Counts
	for line in strings.split_lines(strings.to_string(b)) {
		fields := strings.fields(line)
		if len(fields) != 2 do continue
		v, ok := strconv.parse_i64(fields[1]); if !ok do continue
		if strings.has_prefix(line, "heimdall_sqlite_vm_steps_total{") do r.vm += v
		if strings.has_prefix(line, "heimdall_sqlite_fullscan_steps_total{") do r.fullscan += v
		if strings.has_prefix(line, "heimdall_sqlite_sort_total{") do r.sort += v
		if strings.has_prefix(line, "heimdall_sqlite_cache_events_total{") && strings.contains(line, `kind="write"`) do r.page_writes += v
	}
	return r
}

check :: proc(err: domain.Domain_Error, loc := #caller_location) { if err.code != .None { fmt.eprintln(loc, err); os.exit(1) } }
require :: proc(ok: bool, msg := "", loc := #caller_location) { if !ok { fmt.eprintln("assertion failed:", msg, loc, string(sql.sqlite3_errmsg(conn.db))); os.exit(1) } }
exec :: proc(q: string) { require(sql.exec(&conn, q), q) }

scalar_i64 :: proc(q: string) -> i64 {
	stmt: sql.sqlite3_stmt
	require(sql.sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(q), -1, &stmt, nil) == sql.SQLITE_OK, q)
	defer sql.sqlite3_finalize(stmt)
	require(sql.sqlite3_step(stmt) == sql.SQLITE_ROW, q)
	return sql.sqlite3_column_int64(stmt, 0)
}

used_bytes :: proc() -> i64 {
	return (scalar_i64("PRAGMA page_count;") - scalar_i64("PRAGMA freelist_count;")) * scalar_i64("PRAGMA page_size;")
}

reopen :: proc() {
	// Drops SQLite's connection page cache only; the OS cache stays warm.
	sql.close(&conn)
	c2, ok, err := sql.open(db_path, .Main); check(err); require(ok)
	conn = c2
	exec("PRAGMA synchronous=NORMAL;")
	exec("PRAGMA busy_timeout=5000;")
	sqlite3_trace_v2(conn.db, SQLITE_TRACE_STMT, trace_cb, nil)
}

eqp :: proc(q: string) -> string {
	stmt: sql.sqlite3_stmt
	full := strings.concatenate({"EXPLAIN QUERY PLAN ", q})
	require(sql.sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(full), -1, &stmt, nil) == sql.SQLITE_OK, full)
	defer sql.sqlite3_finalize(stmt)
	b := strings.builder_make()
	for sql.sqlite3_step(stmt) == sql.SQLITE_ROW {
		if strings.builder_len(b) > 0 do strings.write_string(&b, " ; ")
		strings.write_string(&b, string(sql.sqlite3_column_text(stmt, 3)))
	}
	return strings.to_string(b)
}

// ---- candidate calls (real repo procs) ----
Call :: enum { Live_Bridge_Ids, Live_By_Kind, Retention_Noop, Conversations, Dependencies }

call_once :: proc(which: Call) -> string {
	out: []u8
	switch which {
	case .Live_Bridge_Ids:
		rows, e := sql.shell_session_list_live_bridge_ids_sqlite(&shell_impl, 1024); check(e)
		out, _ = json.marshal(rows[:])
	case .Live_By_Kind:
		rows, e := sql.shell_session_list_live_by_kind_sqlite(&shell_impl, "server", 100); check(e)
		ids := make([dynamic]string); for r in rows do append(&ids, r.session_id)
		out, _ = json.marshal(ids[:])
	case .Retention_Noop:
		// Production steady state: the 20s sweep usually finds nothing older than 7d
		// beyond what the previous sweep removed. Cutoff before every fixture row.
		owners, e := sql.shell_session_delete_terminal_before_owners_sqlite(&shell_impl, "2026-01-01T00:00:00Z"); check(e)
		out, _ = json.marshal(len(owners))
	case .Conversations:
		rows, e := sql.content_list_conversations_sqlite(&content_impl, OWNER, 200, ""); check(e)
		out, _ = json.marshal(rows)
	case .Dependencies:
		rows, e := sql.taskchain_list_dependencies_by_chain_sqlite(&task_impl, "chain_0", OWNER); check(e)
		out, _ = json.marshal(rows)
	}
	return string(out)
}

capture_sql :: proc(which: Call) -> string {
	clear(&captured); capturing = true
	_ = call_once(which)
	capturing = false
	require(len(captured) == 1, fmt.tprint("expected exactly one statement, got", len(captured)))
	return captured[0]
}

Result :: struct { vm, fullscan, sort: f64, cold_us, warm_us: f64, plan, digest: string }

measure_read :: proc(which: Call) -> Result {
	r: Result
	q := capture_sql(which)
	r.plan = eqp(q)
	reopen()
	t0 := time.tick_now()
	r.digest = call_once(which)
	r.cold_us = f64(time.duration_microseconds(time.tick_since(t0)))
	before := snapshot()
	samples := make([]f64, WARM_N)
	for i in 0..<WARM_N {
		t := time.tick_now()
		d := call_once(which)
		samples[i] = f64(time.duration_microseconds(time.tick_since(t)))
		require(d == r.digest, "result changed between repeats")
	}
	after := snapshot()
	slice.sort(samples)
	r.warm_us = samples[WARM_N/2]
	r.vm = f64(after.vm-before.vm)/WARM_N
	r.fullscan = f64(after.fullscan-before.fullscan)/WARM_N
	r.sort = f64(after.sort-before.sort)/WARM_N
	return r
}

// ---- candidate indexes ----
Candidate :: struct { name, table, ddl: string, calls: []Call }

CANDIDATES := []Candidate{
	{"idx_eval_shell_bridge_status", "shell_sessions", "CREATE INDEX idx_eval_shell_bridge_status ON shell_sessions(bridge_id, status);", {.Live_Bridge_Ids}},
	{"idx_eval_shell_kind_started_status", "shell_sessions", "CREATE INDEX idx_eval_shell_kind_started_status ON shell_sessions(kind, started_at, session_id, status);", {.Live_By_Kind}},
	{"idx_eval_shell_kind_started", "shell_sessions", "CREATE INDEX idx_eval_shell_kind_started ON shell_sessions(kind, started_at, session_id);", {.Live_By_Kind}},
	{"idx_eval_shell_retention", "shell_sessions", "CREATE INDEX idx_eval_shell_retention ON shell_sessions(status, COALESCE(NULLIF(finished_at, ''), NULLIF(last_activity_at, ''), started_at));", {.Retention_Noop}},
	{"idx_eval_conv_owner_order", "chat_conversations", "CREATE INDEX idx_eval_conv_owner_order ON chat_conversations(owner_user_id, COALESCE(NULLIF(last_message_at,''), updated_at, created_at) DESC, conversation_id DESC);", {.Conversations}},
	{"idx_eval_msg_conv_direction", "chat_messages", "CREATE INDEX idx_eval_msg_conv_direction ON chat_messages(conversation_id, owner_user_id, direction, created_at DESC, message_id DESC);", {.Conversations}},
	{"idx_eval_dependencies_chain", "task_dependencies", "CREATE INDEX idx_eval_dependencies_chain ON task_dependencies(chain_id, owner_user_id, created_at);", {.Dependencies}},
}

SHIPPED := []string{"idx_shell_sessions_kind_started", "idx_shell_sessions_retention", "idx_task_dependencies_chain"}

// ---- write workloads (real repo procs) ----
Write_Cost :: struct { vm, page_writes: i64, us: f64 }

write_seq: int

shell_lifecycle :: proc(n: int) -> [4]Write_Cost {
	// insert running -> activity touch -> exited -> retention delete: every write a
	// production shell row sees, through the real upsert and real retention DELETE.
	out: [4]Write_Cost
	write_seq += 1
	base := fmt.tprintf("wl%d_", write_seq)
	phases := [3]string{"running", "running", "exited"}
	for phase in 0..<3 {
		exec("BEGIN;")
		b := snapshot(); t := time.tick_now()
		for i in 0..<n {
			s := domain.Shell_Session{session_id=fmt.tprintf("%s%d", base, i), owner_user_id=OWNER,
				bridge_id=fmt.tprintf("bridge_%d", i%20), kind="run", status=phases[phase], cmd="true",
				started_at=OLD, created_at=OLD}
			if phase == 1 do s.last_activity_at = "2026-09-01T00:00:05Z"
			if phase == 2 { s.finished_at = "2026-09-01T00:00:09Z"; s.exit_code = 0 }
			ok, e := sql.shell_session_upsert_sqlite(&shell_impl, s); check(e); require(ok)
		}
		exec("COMMIT;")
		a := snapshot()
		out[phase] = {a.vm-b.vm, a.page_writes-b.page_writes, f64(time.duration_microseconds(time.tick_since(t)))}
	}
	b := snapshot(); t := time.tick_now()
	owners, e := sql.shell_session_delete_terminal_before_owners_sqlite(&shell_impl, "2026-09-02T00:00:00Z"); check(e)
	a := snapshot()
	require(owners[OWNER] == n, fmt.tprint("retention must delete exactly the workload rows", owners[OWNER], n))
	out[3] = {a.vm-b.vm, a.page_writes-b.page_writes, f64(time.duration_microseconds(time.tick_since(t)))}
	return out
}

conversation_writes :: proc(n: int) -> [2]Write_Cost {
	out: [2]Write_Cost
	write_seq += 1
	exec("BEGIN;")
	b := snapshot(); t := time.tick_now()
	for i in 0..<n {
		ts := fmt.tprintf("2026-10-22T01:%02d:%02dZ", (write_seq*7+i/60)%60, i%60)
		_, ok, e := sql.content_save_conversation_sqlite(&content_impl, domain.Chat_Conversation{
			conversation_id=fmt.tprintf("chat_%d", i%10), owner_user_id=OWNER, agent_id="agent", agent_instance_id="instance",
			title="fixture", unread_count=i, last_message_at=ts, created_at=NOW, updated_at=ts})
		check(e); require(ok)
	}
	exec("COMMIT;")
	a := snapshot()
	out[0] = {a.vm-b.vm, a.page_writes-b.page_writes, f64(time.duration_microseconds(time.tick_since(t)))}
	exec("BEGIN;")
	b = snapshot(); t = time.tick_now()
	for i in 0..<n {
		_, ok, e := sql.content_save_message_sqlite(&content_impl, domain.Chat_Message{
			message_id=fmt.tprintf("wmsg_%d_%d", write_seq, i), conversation_id=fmt.tprintf("chat_%d", i%10),
			owner_user_id=OWNER, direction="agent_to_user", body="fixture", artifact_ids_json="[]", created_at=NOW})
		check(e); require(ok)
	}
	exec("COMMIT;")
	a = snapshot()
	out[1] = {a.vm-b.vm, a.page_writes-b.page_writes, f64(time.duration_microseconds(time.tick_since(t)))}
	return out
}

// Inserts every not-yet-present edge (a -> b, b < a-1) inside chain_0's single
// workflow execution: 171 rows for 20 tasks. They are removed again afterwards.
DEP_WRITE_ROWS :: 171
dependency_writes :: proc() -> Write_Cost {
	write_seq += 1
	exec("BEGIN;")
	b := snapshot(); t := time.tick_now()
	rows := 0
	for x in 2..<20 do for y in 0..<x-1 {
		_, ok, e := sql.taskchain_save_dependency_sqlite(&task_impl, domain.Task_Dependency{
			task_id=domain.Task_ID(fmt.tprintf("task_0_%d", x)), depends_on_task_id=domain.Task_ID(fmt.tprintf("task_0_%d", y)),
			chain_id="chain_0", owner_user_id=OWNER, created_at=NOW})
		check(e); require(ok); rows += 1
	}
	exec("COMMIT;")
	a := snapshot()
	require(rows == DEP_WRITE_ROWS)
	exec(fmt.tprintf("DELETE FROM task_dependencies WHERE chain_id='chain_0' AND created_at='%s';", NOW))
	return {a.vm-b.vm, a.page_writes-b.page_writes, f64(time.duration_microseconds(time.tick_since(t)))}
}

// ---- fixture ----
Scale :: struct { shells, live_every, servers_every, shells_every, bridges, convs, msgs, chains, tasks: int }

seed :: proc(s: Scale) {
	exec("BEGIN;")
	for n in 0..<s.shells {
		kind := "run"
		if n%s.servers_every == 0 do kind = "server"
		else if n%s.shells_every == 0 do kind = "shell"
		started := fmt.tprintf("2026-10-%02dT%02d:%02d:%02dZ", 15 + (n/1440)%7, (n/60)%24, n%60, n%60)
		sess := domain.Shell_Session{session_id=fmt.tprintf("sh_%05d", n), owner_user_id=OWNER,
			bridge_id=fmt.tprintf("bridge_%d", (n/7)%s.bridges), kind=kind, status="exited", cmd="true",
			agent_instance_id="fixture-instance", chain_id="chain_0", started_at=started, created_at=started, finished_at=started}
		if n%s.live_every == 0 { sess.status = "running"; sess.finished_at = "" }
		ok, e := sql.shell_session_upsert_sqlite(&shell_impl, sess); check(e); require(ok)
	}
	for n in 0..<s.convs {
		ts := fmt.tprintf("2026-10-21T%02d:%02d:00Z", (n/60)%24, n%60)
		_, ok, e := sql.content_save_conversation_sqlite(&content_impl, domain.Chat_Conversation{
			conversation_id=fmt.tprintf("chat_%d", n), owner_user_id=OWNER, agent_id="agent", agent_instance_id=fmt.tprintf("instance_%d", n),
			title="fixture", unread_count=0, last_message_at=ts, created_at=NOW, updated_at=ts})
		check(e); require(ok)
		for m in 0..<s.msgs {
			dir := "agent_to_user"
			if m%3 == 1 do dir = "user_to_agent"
			if m%3 == 2 do dir = "agent_to_agent"
			_, ok2, e2 := sql.content_save_message_sqlite(&content_impl, domain.Chat_Message{
				message_id=fmt.tprintf("msg_%d_%d", n, m), conversation_id=fmt.tprintf("chat_%d", n),
				owner_user_id=OWNER, direction=dir, body="fixture", artifact_ids_json="[]",
				created_at=fmt.tprintf("2026-10-20T%02d:%02d:%02dZ", (m/3600)%24, (m/60)%60, m%60)})
			check(e2); require(ok2)
		}
	}
	for n in 0..<s.chains {
		cid := domain.Task_Chain_ID(fmt.tprintf("chain_%d", n))
		_, ok, e := sql.taskchain_save_chain_sqlite(&task_impl, domain.Task_Chain{chain_id=cid, owner_user_id=OWNER, title="fixture",
			kind=domain.CHAIN_KIND_MIXED_WORK, created_at=NOW, updated_at=NOW})
		check(e); require(ok)
		// task_dependencies_internal_only (099) requires both tasks in one workflow execution.
		rid := domain.Workflow_Run_ID(fmt.tprintf("fixture-run-%d", n))
		_, rok, rerr := sql.insert_workflow_run_sqlite(&task_impl, domain.Workflow_Run{
			run_id=rid, chain_id=cid, owner_user_id=OWNER, title="fixture", definition_ref="fixture@1", spec_json="{}", inputs_json="{}",
			current_execution_no=1, request_id=fmt.tprintf("request-%d", n), request_hash="fixture", created_by_kind="hub", created_by_id="fixture", created_at=NOW, updated_at=NOW, revision=1})
		check(rerr); require(rok)
		_, xok, xerr := sql.insert_workflow_execution_sqlite(&task_impl, domain.Workflow_Run_Execution{
			run_id=rid, execution_no=1, chain_id=cid, owner_user_id=OWNER, state="running", resolved_inputs_json="{}", output_manifest_json="{}", revision=1})
		check(xerr); require(xok)
		for m in 0..<s.tasks {
			_, ok2, e2 := sql.task_save_sqlite(&task_impl, domain.Task{task_id=domain.Task_ID(fmt.tprintf("task_%d_%d", n, m)),
				chain_id=cid, owner_user_id=OWNER, title="fixture", publish_state=.Published, workflow_run_id=rid, workflow_execution_no=1,
				stage_key="fixture", stage_index=m, created_at=NOW, updated_at=NOW})
			check(e2); require(ok2)
		}
		for m in 1..<s.tasks {
			_, ok3, e3 := sql.taskchain_save_dependency_sqlite(&task_impl, domain.Task_Dependency{
				task_id=domain.Task_ID(fmt.tprintf("task_%d_%d", n, m)), depends_on_task_id=domain.Task_ID(fmt.tprintf("task_%d_%d", n, m-1)),
				chain_id=cid, owner_user_id=OWNER, created_at=fmt.tprintf("2026-10-21T00:00:%02dZ", m)})
			check(e3); require(ok3)
		}
	}
	exec("COMMIT;")
}

call_name :: proc(cl: Call) -> string {
	switch cl {
	case .Live_Bridge_Ids: return "shell_session_list_live_bridge_ids"
	case .Live_By_Kind: return "shell_session_list_live_by_kind(server,100)"
	case .Retention_Noop: return "shell_session_delete_terminal_before_owners (no expired rows)"
	case .Conversations: return "content_list_conversations_sqlite(limit 200)"
	case .Dependencies: return "taskchain_list_dependencies_by_chain"
	}
	return ""
}

print_read :: proc(label, stats: string, r: Result) {
	fmt.printf("| %s | %s | %.0f | %.0f | %.0f | %.0f | %.0f | `%s` |\n", label, stats, r.vm, r.fullscan, r.sort, r.cold_us, r.warm_us, r.plan)
}

main :: proc() {
	context.allocator = context.temp_allocator
	require(len(os.args) == 3, "usage: sqlite_index_eval <db> <t1|prod>")
	db_path = os.args[1]
	scale: Scale
	switch os.args[2] {
	// t1: task-1 shape (600 shells, 30 live, 200/kind, 20 bridges; 60x100 messages; 30x20 tasks).
	case "t1":   scale = {shells=600, live_every=20, servers_every=3, shells_every=3, bridges=20, convs=60, msgs=100, chains=30, tasks=20}
	// prod: shell row count implied by W40 fullscan/call (~1.7k rows); servers ~5%, 1% live.
	case "prod": scale = {shells=1800, live_every=100, servers_every=20, shells_every=7, bridges=30, convs=300, msgs=60, chains=90, tasks=20}
	case: require(false, "scale must be t1 or prod")
	}
	dbt.set_mode(.Basic)
	reg = metrics.init_global()
	dbt.init(reg)
	sql.sqlite_metrics_init(reg)
	c0, ok, err := sql.open(db_path, .Main); check(err); require(ok)
	conn = c0
	exec("PRAGMA journal_mode=WAL;")
	exec("PRAGMA synchronous=NORMAL;")
	exec("PRAGMA busy_timeout=5000;")
	migrated, merr := sql.run_migrations(&conn); check(merr); require(migrated)
	user_impl: sql.User_Repo_SQLite
	_ = sql.new_user_repository(&user_impl, &conn)
	_, uok, uerr := sql.user_save_sqlite(&user_impl, domain.User{user_id=OWNER, name=OWNER, status=.Active, created_at=NOW, updated_at=NOW})
	check(uerr); require(uok)
	_ = sql.new_shell_session_repository(&shell_impl, &conn)
	_ = sql.new_content_repository(&content_impl, &conn)
	_ = sql.new_taskchain_repository(&task_impl, &conn)
	// Baseline = schema WITHOUT migration 104, so every variant is measured against
	// the pre-104 state; the shipped migration is re-applied as its own variant below.
	for name in SHIPPED do exec(fmt.tprintf("DROP INDEX %s;", name))
	seed(scale)
	reopen()
	fmt.printf("SQLite %s; scale=%s %v; WAL/NORMAL; scratch DB %s\n", string(sql.sqlite3_libversion()), os.args[2], scale, db_path)
	fmt.printf("sqlite_stat1 present after migrations: %v\n", sql.sqlite_object_exists(&conn, "sqlite_stat1"))

	fmt.println("\n## Reads (per call; warm = median of 50 after one cold call on a reopened connection; us = microseconds)")
	fmt.println("| Variant | Stats | VM | Fullscan | Sort | Cold us | Warm us | EXPLAIN QUERY PLAN |")
	fmt.println("|---|---|---:|---:|---:|---:|---:|---|")
	baseline_digest: [Call]string
	for cl in Call {
		fmt.printf("| **%s** — SQL: `%s` | | | | | | | |\n", call_name(cl), capture_sql(cl))
		r := measure_read(cl)
		baseline_digest[cl] = r.digest
		print_read("no new index", "none", r)
		exec("ANALYZE;"); reopen()
		print_read("no new index", "ANALYZE", measure_read(cl))
		exec("DROP TABLE sqlite_stat1;"); reopen()
		for cand in CANDIDATES {
			if !slice.contains(cand.calls, cl) do continue
			exec(cand.ddl); reopen()
			r2 := measure_read(cl)
			require(r2.digest == baseline_digest[cl], fmt.tprint("index changed results for", call_name(cl), cand.name))
			print_read(cand.name, "none", r2)
			exec("ANALYZE;"); reopen()
			r3 := measure_read(cl)
			require(r3.digest == baseline_digest[cl], "index+ANALYZE changed results")
			print_read(cand.name, "ANALYZE", r3)
			exec("DROP TABLE sqlite_stat1;")
			exec(fmt.tprintf("DROP INDEX %s;", cand.name)); reopen()
		}
	}

	fmt.println("\n## Shipped migration 104 applied together (stat-less, as production)")
	exec(sql.MIGRATION_104_FULL_SCAN_INDEXES); reopen()
	fmt.println("| Call | VM | Fullscan | Sort | Cold us | Warm us | EXPLAIN QUERY PLAN |")
	fmt.println("|---|---:|---:|---:|---:|---:|---|")
	for cl in Call {
		r := measure_read(cl)
		require(r.digest == baseline_digest[cl], "shipped indexes changed results")
		fmt.printf("| %s | %.0f | %.0f | %.0f | %.0f | %.0f | `%s` |\n", call_name(cl), r.vm, r.fullscan, r.sort, r.cold_us, r.warm_us, r.plan)
	}
	for name in SHIPPED do exec(fmt.tprintf("DROP INDEX %s;", name))
	reopen()

	fmt.println("\n## Index size and write amplification (200 rows per workload, one transaction per phase; deltas vs no new index)")
	fmt.println("| Variant | Size bytes | Shell insert VM/pw | Shell activity upsert VM/pw | Shell exit upsert VM/pw | Retention delete 200 VM/pw | Conv save VM/pw | Msg insert VM/pw | Dep insert (171) VM/pw |")
	fmt.println("|---|---:|---|---|---|---|---|---|---|")
	N :: 200
	// warm-up so the first measured variant is not penalised by page allocation
	_ = shell_lifecycle(N); _ = conversation_writes(N); _ = dependency_writes()
	variants := make([dynamic]Candidate)
	append(&variants, Candidate{name="no new index"})
	for cand in CANDIDATES do append(&variants, cand)
	append(&variants, Candidate{name="shipped migration 104 (all three)", ddl=sql.MIGRATION_104_FULL_SCAN_INDEXES})
	for v in variants {
		size: i64 = 0
		if v.ddl != "" {
			b := used_bytes(); exec(v.ddl); size = used_bytes() - b
		}
		reopen()
		sh := shell_lifecycle(N)
		cv := conversation_writes(N)
		dp := dependency_writes()
		fmt.printf("| %s | %d | %d/%d | %d/%d | %d/%d | %d/%d | %d/%d | %d/%d | %d/%d |\n", v.name, size,
			sh[0].vm, sh[0].page_writes, sh[1].vm, sh[1].page_writes, sh[2].vm, sh[2].page_writes, sh[3].vm, sh[3].page_writes,
			cv[0].vm, cv[0].page_writes, cv[1].vm, cv[1].page_writes, dp.vm, dp.page_writes)
		if v.ddl == sql.MIGRATION_104_FULL_SCAN_INDEXES {
			for name in SHIPPED do exec(fmt.tprintf("DROP INDEX %s;", name))
		} else if v.ddl != "" do exec(fmt.tprintf("DROP INDEX %s;", v.name))
	}
	sql.close(&conn)
}
