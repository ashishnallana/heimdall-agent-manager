package content

import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"

// delete_memory is permanent, works in any status, is owner-only, and never
// touches system memories.
@(test)
test_delete_memory_is_owner_only_and_refuses_system_memories :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	conn, open_ok, _ := sqlite.open(":memory:")
	if !testing.expect(t, open_ok, "db open ok") do return
	defer sqlite.close(&conn)
	mig_ok, _ := sqlite.run_migrations(&conn)
	if !testing.expect(t, mig_ok, "migrations ok") do return

	content_impl := sqlite.Content_Repo_SQLite{conn = &conn}
	content_repo := sqlite.new_content_repository(&content_impl, &conn)
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	svc := new_content_service(&content_repo, nil, nil, nil, nil, &clock, &ids)
	owner := contracts.Auth_Context{user_id = "owner"}

	mem, created, create_err := create_memory(&svc, owner, Memory_Input{title = "Leaked key", body = "sk-not-really", type = .Fact, status = "pending"})
	if !testing.expect(t, created, create_err.message) do return

	other_ok, _ := delete_memory(&svc, contracts.Auth_Context{user_id = "intruder"}, mem.memory_id)
	testing.expect(t, !other_ok, "another owner cannot delete it")
	_, still, _ := get_memory(&svc, owner, mem.memory_id)
	testing.expect(t, still, "memory survives the refused delete")

	// Archived first, then deleted: delete works whatever the status.
	_, archived, _ := archive_memory(&svc, owner, mem.memory_id)
	testing.expect(t, archived, "archive ok")
	deleted, del_err := delete_memory(&svc, owner, mem.memory_id)
	testing.expect(t, deleted, del_err.message)
	_, found, get_err := get_memory(&svc, owner, mem.memory_id)
	testing.expect(t, !found, "memory is gone")
	testing.expect_value(t, get_err.code, domain.Error_Code.Not_Found)

	again, again_err := delete_memory(&svc, owner, mem.memory_id)
	testing.expect(t, !again, "a second delete finds nothing")
	testing.expect_value(t, again_err.code, domain.Error_Code.Not_Found)

	testing.expect(t, sqlite.exec(&conn, `INSERT INTO memories (memory_id, owner_user_id, status, body, created_at, updated_at) VALUES ('mem_sys','system','active','s','t','t');`))
	sys_ok, sys_err := delete_memory(&svc, owner, "mem_sys")
	testing.expect(t, !sys_ok, "system memories are read-only")
	testing.expect_value(t, sys_err.code, domain.Error_Code.Forbidden)
}
