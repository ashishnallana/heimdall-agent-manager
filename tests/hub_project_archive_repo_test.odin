package hub_project_archive_repo_test

// Repo-level coverage for REQ-PROJ-ARCHIVE-1: proves migration 037 (projects.state)
// is idempotent under a double run_migrations + upgrade guard, and that the project
// repo round-trips the new `state` field (defaults to Active; persists Archived).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import auth_service "odin_test:hub/service/auth"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import api_http "odin_test:hub/transport/http"

check :: proc(ok: bool, msg: string) {
	if ok do return
	fmt.eprintln("FAIL:", msg)
	os.exit(1)
}

req :: proc(graph: ^app.App_Graph, method, path, body: string, headers: []contracts.HTTP_Header) -> api_http.Response {
	return api_http.router_dispatch(&graph.router, api_http.Request{method = method, path = path, body = body, request_id = "req_pa", remote_addr = "127.0.0.1", headers = headers})
}

json_str :: proc(body, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\":\""}); defer delete(needle)
	idx := strings.index(body, needle); if idx < 0 do return ""
	tail := body[idx + len(needle):]
	end := strings.index(tail, "\""); if end < 0 do return ""
	return tail[:end]
}

@(test)
test_hub_project_archive :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	db_path := "/tmp/project_archive_repo_test.db"
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	check(open_ok, fmt.tprintf("open db: %s", open_err.message))
	defer sqlite.close(&conn)

	// Test 1: full migration run (includes 037_project_state.sql).
	mig_ok, mig_err := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok, fmt.tprintf("run_migrations: %s", mig_err.message))

	// Test 2: idempotency — a second run_migrations must not error (037 self-heal).
	mig_ok2, mig_err2 := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok2, fmt.tprintf("run_migrations 2nd run: %s", mig_err2.message))

	// Test 3: the end-of-run upgrade guard is itself idempotent.
	check(sqlite.upgrade_projects_state_schema(&conn), "upgrade_projects_state_schema should be idempotent (run 1)")
	check(sqlite.upgrade_projects_state_schema(&conn), "upgrade_projects_state_schema should be idempotent (run 2)")

	repo_impl: sqlite.Project_Repo_SQLite
	repo := sqlite.new_project_repository(&repo_impl, &conn)

	// Test 4: a saved project with no explicit state defaults to Active and round-trips.
	active := domain.Project{
		project_id = domain.Project_ID("proj_arch_active"),
		owner_user_id = domain.User_ID("usr_arch"),
		name = "Active Project",
		slug = "active-project",
		default_path = "/tmp/active",
		created_at = "2026-09-15T00:00:00Z",
		updated_at = "2026-09-15T00:00:00Z",
	}
	_, save_ok, save_err := iface.project_save(&repo, active)
	check(save_ok, fmt.tprintf("save active project: %s", save_err.message))
	got_active, got_active_ok, _ := iface.project_get(&repo, active.project_id)
	check(got_active_ok && got_active.state == .Active, "project must default to Active state on read")

	// Test 5: archiving (state=Archived) persists and reads back as Archived.
	archived := got_active
	archived.state = .Archived
	archived.updated_at = "2026-09-15T01:00:00Z"
	_, upd_ok, upd_err := iface.project_update(&repo, archived)
	check(upd_ok, fmt.tprintf("update project to archived: %s", upd_err.message))
	got_archived, got_archived_ok, _ := iface.project_get(&repo, active.project_id)
	check(got_archived_ok && got_archived.state == .Archived, "archived project must read back as Archived")

	// Test 6: soft-only — the row still exists (archive is not a delete) and remains
	// in the owner's list.
	listed, list_err := iface.project_list_by_owner(&repo, domain.User_ID("usr_arch"), 50, "")
	check(list_err.code == .None, fmt.tprintf("list projects: %s", list_err.message))
	found := false
	for p in listed { if p.project_id == active.project_id { found = true; check(p.state == .Archived, "listed archived project must carry Archived state") } }
	check(found, "archived project must still be listed (soft-archive, no row removal)")

	test_project_archive_http_api()

	fmt.println("PASS: hub project archive repo & api test")
}

test_project_archive_http_api :: proc() {
	api_db_path := "/tmp/project_archive_api_test.db"
	_ = os.remove(api_db_path)
	defer _ = os.remove(api_db_path)

	graph: app.App_Graph
	ok, message := app.build_graph(&graph, app.Hub_Config{
		database_path = api_db_path,
		migrations_dir = "src/hub/repository/sqlite/migrations",
		auto_provision_users = true,
		paddle_environment = "sandbox",
	})
	check(ok, message)
	defer { app.shutdown_graph(&graph); _ = os.remove(api_db_path) }

	// Users authenticate with a Hub browser session (OIDC login); mint them directly.
	graph.auth.web.enabled = true
	alice_session, alice_ok := auth_service.mint_session(&graph.auth, "alice")
	bob_session, bob_ok := auth_service.mint_session(&graph.auth, "bob")
	check(alice_ok && bob_ok, "mint user sessions")
	alice := [?]contracts.HTTP_Header{auth_service.session_cookie_request_header(alice_session)}
	bob := [?]contracts.HTTP_Header{auth_service.session_cookie_request_header(bob_session)}

	created := req(&graph, "POST", "/api/v1/projects", "{\"name\":\"Archive Me\",\"slug\":\"archive-me\",\"default_path\":\"/tmp/archive-me\"}", alice[:])
	check(created.status == 201, fmt.tprintf("create project: %d %s", created.status, created.body))
	check(strings.contains(created.body, "\"state\":\"active\""), "new project must default to state active")
	pid := json_str(created.body, "project_id")
	check(pid != "", "project_id must be present")
	archive_path := strings.concatenate({"/api/v1/projects/", pid, "/archive"})

	bob_arch := req(&graph, "POST", archive_path, "", bob[:])
	check(bob_arch.status == 404, fmt.tprintf("cross-owner archive must be 404, got %d", bob_arch.status))

	arch := req(&graph, "POST", archive_path, "", alice[:])
	check(arch.status == 200 && strings.contains(arch.body, "\"state\":\"archived\""), fmt.tprintf("owner archive must set state archived: %d %s", arch.status, arch.body))

	detail := req(&graph, "GET", strings.concatenate({"/api/v1/projects/", pid}), "", alice[:])
	check(detail.status == 200 && strings.contains(detail.body, "\"state\":\"archived\""), "archived project must still be readable with archived state")

	list := req(&graph, "GET", "/api/v1/projects", "", alice[:])
	check(list.status == 200 && strings.contains(list.body, pid), "archived project must still be listed (parity with agents)")

	arch2 := req(&graph, "POST", archive_path, "", alice[:])
	check(arch2.status == 200 && strings.contains(arch2.body, "\"state\":\"archived\""), "re-archiving must remain archived")

	missing := req(&graph, "POST", "/api/v1/projects/proj_does_not_exist/archive", "", alice[:])
	check(missing.status == 404, fmt.tprintf("archiving a missing project must 404, got %d", missing.status))
}
