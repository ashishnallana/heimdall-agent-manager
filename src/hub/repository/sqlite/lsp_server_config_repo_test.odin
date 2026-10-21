package sqlite

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_lsp_server_config_repo_sqlite_lifecycle :: proc(t: ^testing.T) {
	conn, db_path, open_ok := tmpl_clone_migrated_into_file(t, "lsp_server_config_repo")
	defer tmpl_remove_db(db_path)
	testing.expect(t, open_ok, "db open ok")
	defer close(&conn)

	testing.expect(t, table_column_exists(&conn, "lsp_server_configs", "dir_prefix"), "dir_prefix column exists")
	testing.expect(t, table_column_exists(&conn, "lsp_server_configs", "dir_pattern"), "dir_pattern column exists")

	impl := Lsp_Server_Config_Repo_SQLite{}
	repo := new_lsp_server_config_repository(&impl, &conn)

	owner  := "user_lsp_test"
	bridge := "brg_test"

	// List returns empty initially.
	list0, err0 := iface.lsp_server_config_list_by_bridge(&repo, owner, bridge)
	testing.expect_value(t, err0.code, domain.Error_Code.None)
	testing.expect_value(t, len(list0), 0)
	delete(list0)

	// Upsert a language default (dir_prefix = "").
	cfg_default := domain.Lsp_Server_Config{
		config_id       = "lspcfg_default",
		owner_user_id   = owner,
		bridge_id       = bridge,
		language        = "go",
		cmd             = "gopls",
		args            = "",
		file_extensions = ".go",
		root_markers    = "go.mod",
		dir_prefix      = "",
		created_at      = "2026-09-22T10:00:00Z",
		updated_at      = "2026-09-22T10:00:00Z",
	}
	ok1, err1 := iface.lsp_server_config_upsert(&repo, cfg_default)
	testing.expect(t, ok1, "upsert default ok")
	testing.expect_value(t, err1.code, domain.Error_Code.None)

	// Upsert a dir-specific override (dir_prefix non-empty).
	cfg_override := domain.Lsp_Server_Config{
		config_id       = "lspcfg_override",
		owner_user_id   = owner,
		bridge_id       = bridge,
		language        = "go",
		cmd             = "gopls-special",
		args            = "--special",
		file_extensions = ".go",
		root_markers    = "go.mod",
		dir_prefix      = "/work/project",
		dir_pattern     = "/work/project/**",
		created_at      = "2026-09-22T10:00:00Z",
		updated_at      = "2026-09-22T10:00:00Z",
	}
	ok2, err2 := iface.lsp_server_config_upsert(&repo, cfg_override)
	testing.expect(t, ok2, "upsert override ok")
	testing.expect_value(t, err2.code, domain.Error_Code.None)

	// List returns both rows ordered by (language ASC, dir_prefix ASC): "" < "/work/project".
	list1, err1b := iface.lsp_server_config_list_by_bridge(&repo, owner, bridge)
	testing.expect_value(t, err1b.code, domain.Error_Code.None)
	testing.expect_value(t, len(list1), 2)
	if len(list1) == 2 {
		testing.expect_value(t, list1[0].dir_prefix, "")
		testing.expect_value(t, list1[0].dir_pattern, "")
		testing.expect_value(t, list1[0].cmd, "gopls")
		testing.expect_value(t, list1[1].dir_prefix, "/work/project")
		testing.expect_value(t, list1[1].dir_pattern, "/work/project/**")
		testing.expect_value(t, list1[1].cmd, "gopls-special")
	}
	for c in list1 { domain.lsp_server_config_destroy(c) }
	delete(list1)

	// --- Durability: close and reopen the database, re-run migrations ---
	// Proves configs survive a Hub restart (REQ-LSP-CFG-1 acceptance criterion).
	// Also exercises the idempotency guard (044_lsp_servers.sql) on a populated DB.
	close(&conn) // explicit close — defer at line 13 is now a no-op (double-close safe)

	conn2, reopen_ok, _ := open(db_path)
	testing.expect(t, reopen_ok, "db reopen ok")
	defer close(&conn2)

	mig2_ok, _ := run_migrations(&conn2)
	testing.expect(t, mig2_ok, "migrations idempotent on populated db")

	impl2 := Lsp_Server_Config_Repo_SQLite{}
	repo2 := new_lsp_server_config_repository(&impl2, &conn2)

	// Both rows must still be present after reopen, including dir_prefix values.
	persisted, perr := iface.lsp_server_config_list_by_bridge(&repo2, owner, bridge)
	testing.expect_value(t, perr.code, domain.Error_Code.None)
	testing.expect_value(t, len(persisted), 2)
	if len(persisted) == 2 {
		testing.expect_value(t, persisted[0].dir_prefix, "")
		testing.expect_value(t, persisted[0].dir_pattern, "")
		testing.expect_value(t, persisted[0].cmd, "gopls")
		testing.expect_value(t, persisted[1].dir_prefix, "/work/project")
		testing.expect_value(t, persisted[1].dir_pattern, "/work/project/**")
		testing.expect_value(t, persisted[1].cmd, "gopls-special")
	}
	for c in persisted { domain.lsp_server_config_destroy(c) }
	delete(persisted)
}
