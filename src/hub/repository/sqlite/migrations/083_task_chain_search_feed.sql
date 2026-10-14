-- Monotonic owner-scoped change feed for Bridge-local task-chain search.
-- The feed stores identifiers and operations only; encrypted task-chain content
-- remains canonical in task_chains and is read at delivery time.
CREATE TABLE IF NOT EXISTS task_chain_search_changes (
  revision INTEGER PRIMARY KEY AUTOINCREMENT,
  owner_user_id TEXT NOT NULL,
  chain_id TEXT NOT NULL,
  operation TEXT NOT NULL CHECK (operation IN ('upsert', 'delete')),
  changed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_task_chain_search_changes_owner_revision
  ON task_chain_search_changes(owner_user_id, revision);

CREATE TRIGGER IF NOT EXISTS task_chain_search_changes_ai
AFTER INSERT ON task_chains BEGIN
  INSERT INTO task_chain_search_changes(owner_user_id, chain_id, operation)
  VALUES (new.owner_user_id, new.chain_id, 'upsert');
END;

CREATE TRIGGER IF NOT EXISTS task_chain_search_changes_au
AFTER UPDATE OF title, description, status, coordinator_agent_instance_id, updated_at
ON task_chains BEGIN
  INSERT INTO task_chain_search_changes(owner_user_id, chain_id, operation)
  VALUES (new.owner_user_id, new.chain_id, 'upsert');
END;

CREATE TRIGGER IF NOT EXISTS task_chain_search_changes_ad
AFTER DELETE ON task_chains BEGIN
  INSERT INTO task_chain_search_changes(owner_user_id, chain_id, operation)
  VALUES (old.owner_user_id, old.chain_id, 'delete');
END;

-- Seed existing rows so every owner has a non-zero snapshot watermark.
INSERT INTO task_chain_search_changes(owner_user_id, chain_id, operation)
SELECT tc.owner_user_id, tc.chain_id, 'upsert'
FROM task_chains tc
WHERE NOT EXISTS (
  SELECT 1 FROM task_chain_search_changes c
  WHERE c.owner_user_id = tc.owner_user_id AND c.chain_id = tc.chain_id
);
