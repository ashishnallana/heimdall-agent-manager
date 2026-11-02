CREATE INDEX IF NOT EXISTS idx_mcp_memory_page ON memories(owner_user_id,created_at,memory_id);
CREATE INDEX IF NOT EXISTS idx_mcp_project_page ON projects(owner_user_id,created_at,project_id);
CREATE INDEX IF NOT EXISTS idx_mcp_issue_page ON issues(owner_user_id,created_at,issue_id);
CREATE INDEX IF NOT EXISTS idx_mcp_issue_comment_page ON issue_comments(owner_user_id,issue_id,created_at,comment_id);
