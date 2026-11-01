ALTER TABLE task_comments ADD COLUMN delegated_client_id TEXT NOT NULL DEFAULT '';
ALTER TABLE task_comments ADD COLUMN delegated_grant_id TEXT NOT NULL DEFAULT '';
-- Public outcome metadata only; encrypted prose stays in its domain record.
ALTER TABLE mcp_mutation_receipts ADD COLUMN result_json TEXT NOT NULL DEFAULT '';
CREATE INDEX IF NOT EXISTS idx_task_comments_page
ON task_comments(owner_user_id, task_id, created_at, comment_id);
