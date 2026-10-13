package sqlite

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_artifact_repo_sqlite_lifecycle_and_pagination :: proc(t: ^testing.T) {
	db_path := ":memory:"
	conn, open_ok, open_err := open(db_path)
	testing.expect(t, open_ok, "db open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer close(&conn)

	mig_ok, mig_err := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	// Verify migration 041 indexes exist
	testing.expect(t, sqlite_object_exists(&conn, "idx_artifacts_owner_created"), "idx_artifacts_owner_created exists")
	testing.expect(t, sqlite_object_exists(&conn, "idx_artifacts_owner_updated"), "idx_artifacts_owner_updated exists")
	testing.expect(t, sqlite_object_exists(&conn, "idx_artifacts_owner_project_created"), "idx_artifacts_owner_project_created exists")

	repo_impl := Content_Repo_SQLite{conn = &conn}
	repo := new_content_repository(&repo_impl, &conn)

	owner := domain.User_ID("user_test")

	// Insert 3 artifacts with different attributes
	a1 := domain.Artifact{
		artifact_id       = "art_001",
		owner_user_id     = owner,
		kind              = "file",
		name              = "alpha.txt",
		description       = "first",
		content_type      = "text/plain",
		size_bytes        = 100,
		content           = "HELLO ALPHA",
		agent_id          = "agt_1",
		agent_instance_id = "inst_1",
		chain_id          = "chain_1",
		task_id           = "task_1",
		project_id        = "proj_A",
		created_at        = "2026-01-01T10:00:00Z",
		updated_at        = "2026-01-01T10:00:00Z",
	}
	a2 := domain.Artifact{
		artifact_id       = "art_002",
		owner_user_id     = owner,
		kind              = "patch",
		name              = "beta.patch",
		description       = "second",
		content_type      = "text/x-diff",
		size_bytes        = 500,
		content           = "DIFF BETA",
		agent_id          = "agt_2",
		agent_instance_id = "inst_2",
		chain_id          = "chain_1",
		task_id           = "task_2",
		project_id        = "proj_A",
		created_at        = "2026-01-02T10:00:00Z",
		updated_at        = "2026-01-02T12:00:00Z",
	}
	a3 := domain.Artifact{
		artifact_id       = "art_003",
		owner_user_id     = owner,
		kind              = "log",
		name              = "gamma.log",
		description       = "third",
		content_type      = "text/plain",
		size_bytes        = 50,
		content           = "LOG GAMMA",
		agent_id          = "agt_1",
		agent_instance_id = "inst_1",
		chain_id          = "chain_2",
		task_id           = "task_3",
		project_id        = "proj_B",
		created_at        = "2026-01-03T10:00:00Z",
		updated_at        = "2026-01-03T10:00:00Z",
	}

	saved1, ok1, _ := iface.content_save_artifact(&repo, a1)
	testing.expect(t, ok1, "save a1 ok")
	testing.expect_value(t, saved1.artifact_id, "art_001")

	_, ok2, _ := iface.content_save_artifact(&repo, a2)
	testing.expect(t, ok2, "save a2 ok")

	_, ok3, _ := iface.content_save_artifact(&repo, a3)
	testing.expect(t, ok3, "save a3 ok")

	// Verify get_artifact returns content
	got1, got_ok1, _ := iface.content_get_artifact(&repo, "art_001")
	defer domain.artifact_destroy(&got1)
	testing.expect(t, got_ok1, "get a1 ok")
	testing.expect_value(t, got1.content, "HELLO ALPHA")

	// 1. List all: verify content is omitted ("") in list projection
	all_rows, list_err := iface.content_list_artifacts(&repo, owner, domain.Artifact_List_Filter{})
	defer domain.artifacts_destroy(all_rows)
	testing.expect_value(t, list_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(all_rows), 3)
	for r in all_rows {
		testing.expect_value(t, r.content, "") // Content must be excluded!
	}

	// 2. Filter by project_id = proj_A -> should return a1 and a2
	proj_rows, _ := iface.content_list_artifacts(&repo, owner, domain.Artifact_List_Filter{project_id = "proj_A"})
	defer domain.artifacts_destroy(proj_rows)
	testing.expect_value(t, len(proj_rows), 2)

	// 3. Filter by kind = patch -> should return a2
	patch_rows, _ := iface.content_list_artifacts(&repo, owner, domain.Artifact_List_Filter{kind = "patch"})
	defer domain.artifacts_destroy(patch_rows)
	testing.expect_value(t, len(patch_rows), 1)
	testing.expect_value(t, patch_rows[0].artifact_id, "art_002")

	// 4. Filter by chain_id = chain_2 -> should return a3
	chain_rows, _ := iface.content_list_artifacts(&repo, owner, domain.Artifact_List_Filter{chain_id = "chain_2"})
	defer domain.artifacts_destroy(chain_rows)
	testing.expect_value(t, len(chain_rows), 1)
	testing.expect_value(t, chain_rows[0].artifact_id, "art_003")

	// 5. Sorting by name asc -> alpha (a1), beta (a2), gamma (a3)
	sort_name_asc, _ := iface.content_list_artifacts(&repo, owner, domain.Artifact_List_Filter{sort_field = "name", sort_order = "asc"})
	defer domain.artifacts_destroy(sort_name_asc)
	testing.expect_value(t, len(sort_name_asc), 3)
	testing.expect_value(t, sort_name_asc[0].artifact_id, "art_001")
	testing.expect_value(t, sort_name_asc[1].artifact_id, "art_002")
	testing.expect_value(t, sort_name_asc[2].artifact_id, "art_003")

	// 6. Sorting by size_bytes desc -> beta (500), alpha (100), gamma (50)
	sort_size_desc, _ := iface.content_list_artifacts(&repo, owner, domain.Artifact_List_Filter{sort_field = "size_bytes", sort_order = "desc"})
	defer domain.artifacts_destroy(sort_size_desc)
	testing.expect_value(t, len(sort_size_desc), 3)
	testing.expect_value(t, sort_size_desc[0].artifact_id, "art_002")
	testing.expect_value(t, sort_size_desc[1].artifact_id, "art_001")
	testing.expect_value(t, sort_size_desc[2].artifact_id, "art_003")

	// 7. Cursor pagination with limit = 1 on name asc:
	// Page 1: limit 1 -> returns 2 items (limit + 1)
	p1, _ := iface.content_list_artifacts(&repo, owner, domain.Artifact_List_Filter{sort_field = "name", sort_order = "asc", limit = 1})
	defer domain.artifacts_destroy(p1)
	testing.expect_value(t, len(p1), 2) // limit + 1
	testing.expect_value(t, p1[0].artifact_id, "art_001")

	// Page 2: cursor = alpha.txt|art_001 -> should return beta and gamma (2 items for limit=1)
	p2, _ := iface.content_list_artifacts(&repo, owner, domain.Artifact_List_Filter{sort_field = "name", sort_order = "asc", limit = 1, cursor = "alpha.txt|art_001"})
	defer domain.artifacts_destroy(p2)
	testing.expect_value(t, len(p2), 2) // limit + 1
	testing.expect_value(t, p2[0].artifact_id, "art_002")

	// Page 3: cursor = beta.patch|art_002 -> should return gamma only (1 item, no more)
	p3, _ := iface.content_list_artifacts(&repo, owner, domain.Artifact_List_Filter{sort_field = "name", sort_order = "asc", limit = 1, cursor = "beta.patch|art_002"})
	defer domain.artifacts_destroy(p3)
	testing.expect_value(t, len(p3), 1) // 1 item <= limit, no more
	testing.expect_value(t, p3[0].artifact_id, "art_003")
}

@(test)
test_artifact_repo_sqlite_tracking_allocator :: proc(t: ^testing.T) {
	db_path := ":memory:"
	conn, open_ok, _ := open(db_path)
	testing.expect(t, open_ok, "db open ok")
	defer close(&conn)

	mig_ok, _ := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")

	repo_impl := Content_Repo_SQLite{conn = &conn}
	repo := new_content_repository(&repo_impl, &conn)
	owner := domain.User_ID("user_track")

	// Track allocations during artifact operations
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	a1 := domain.Artifact{
		artifact_id       = "art_t1",
		owner_user_id     = owner,
		kind              = "file",
		name              = "track1.txt",
		description       = "desc",
		content_type      = "text/plain",
		size_bytes        = 42,
		content           = "TRACKING TEST 1",
		agent_id          = "agt_1",
		agent_instance_id = "inst_1",
		chain_id          = "chain_1",
		task_id           = "task_1",
		project_id        = "proj_1",
		created_at        = "2026-01-01T00:00:00Z",
		updated_at        = "2026-01-01T00:00:00Z",
	}

	saved, save_ok, _ := iface.content_save_artifact(&repo, a1)
	testing.expect(t, save_ok, "save ok")

	got, got_ok, _ := iface.content_get_artifact(&repo, "art_t1")
	testing.expect(t, got_ok, "get ok")
	testing.expect_value(t, got.size_bytes, 42)
	domain.artifact_destroy(&got)

	// List with filtering, sorting, cursor
	filter := domain.Artifact_List_Filter{
		project_id = "proj_1",
		sort_field = "created_at",
		sort_order = "desc",
		limit      = 10,
	}
	rows, list_err := iface.content_list_artifacts(&repo, owner, filter)
	testing.expect_value(t, list_err.code, domain.Error_Code.None)
	testing.expect_value(t, len(rows), 1)
	domain.artifacts_destroy(rows)

	testing.expect_value(t, len(track.bad_free_array), 0)
	testing.expect_value(t, len(track.allocation_map), 0)
}
