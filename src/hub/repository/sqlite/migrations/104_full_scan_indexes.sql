-- 104: indexes for three timer/detail reads that were full table scans (REQ-INDEX).
-- Evidence and the rejected candidates: docs/sqlite-index-eval.md. Each index was
-- kept only where the read saving outweighed the measured write cost.

-- shell_session_list_live_by_kind (aged-server reaper, every 20s): seek one kind and
-- walk it in ORDER BY order. status is deliberately NOT a key column: the shell
-- upsert assigns status on every update, so including it would charge index
-- maintenance to the hot write path while saving no VM (the read fetches the row
-- for its result columns anyway).
CREATE INDEX IF NOT EXISTS idx_shell_sessions_kind_started
  ON shell_sessions(kind, started_at, session_id);

-- shell_session_delete_terminal_before_owners (row retention, every 20s). The
-- expression must stay byte-for-byte equal to the one in
-- shell_session_repo_sqlite.odin, or the planner silently falls back to a scan;
-- full_scan_indexes_test.odin asserts the plan through the real repository proc.
CREATE INDEX IF NOT EXISTS idx_shell_sessions_retention
  ON shell_sessions(status, COALESCE(NULLIF(finished_at, ''), NULLIF(last_activity_at, ''), started_at));

-- taskchain_list_dependencies_by_chain (task detail, pack construction): equality
-- on chain and owner, rows already in ORDER BY created_at order.
CREATE INDEX IF NOT EXISTS idx_task_dependencies_chain
  ON task_dependencies(chain_id, owner_user_id, created_at);
