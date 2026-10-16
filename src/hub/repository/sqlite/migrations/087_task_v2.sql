-- Task System v2 (M0): event-sourced task engine schema + one-shot legacy
-- migration. Hard cutover — there is no shadow mode and no engine flag.
--
-- Every new table carries owner_user_id + an owner-immutable trigger and none of
-- them is added to FTS. The legacy columns (tasks.status, assignee_ref_json,
-- reviewer_refs_json, task_chains.default_reviewer_refs_json) and tables
-- (task_votes, task_subscriptions) are dropped by upgrade_task_v2_schema in
-- migrations.odin AFTER this file has converted their data; SQLite's DROP COLUMN
-- can refuse (column referenced by an index/trigger) and that step must tolerate
-- it rather than abort startup.
--
-- Timestamps: TEXT RFC3339 ("YYYY-MM-DDTHH:MM:SSZ"), the hub's canonical format,
-- except task_events.ts_ms (INTEGER unix ms) which orders the audit trail.
--
-- ATOMIC: the whole file runs in one transaction. ALTER TABLE ADD COLUMN is not
-- idempotent, so a half-applied 087 would make the re-run a hard "duplicate
-- column" error; wrapping it means a failure leaves NOTHING behind and the
-- re-run starts clean. The skip guard in run_migrations is keyed on the LAST
-- object this file creates (idx_tasks_chain_state, at the bottom).
BEGIN;

-- ---------------------------------------------------------------------------
-- 1. New tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS task_events (
  event_id      INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id       TEXT NOT NULL,
  chain_id      TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  ts_ms         INTEGER NOT NULL,
  actor_kind    TEXT NOT NULL DEFAULT 'hub',
  actor_id      TEXT NOT NULL DEFAULT '',
  kind          TEXT NOT NULL,
  payload_json  TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_task_events_task ON task_events(task_id, event_id);
CREATE INDEX IF NOT EXISTS idx_task_events_chain ON task_events(chain_id, event_id);
CREATE TRIGGER IF NOT EXISTS task_events_owner_immutable BEFORE UPDATE OF owner_user_id ON task_events BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;

CREATE TABLE IF NOT EXISTS task_attempts (
  task_id              TEXT NOT NULL,
  attempt_no           INTEGER NOT NULL,
  chain_id             TEXT NOT NULL,
  owner_user_id        TEXT NOT NULL,
  started_at           TEXT NOT NULL,
  ended_at             TEXT NOT NULL DEFAULT '',
  holder_instance_id   TEXT NOT NULL DEFAULT '',
  outcome              TEXT NOT NULL DEFAULT '',
  counts_toward_budget INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (task_id, attempt_no)
);
CREATE INDEX IF NOT EXISTS idx_task_attempts_chain ON task_attempts(chain_id);
CREATE TRIGGER IF NOT EXISTS task_attempts_owner_immutable BEFORE UPDATE OF owner_user_id ON task_attempts BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;

CREATE TABLE IF NOT EXISTS task_attempt_facets (
  task_id       TEXT NOT NULL,
  attempt_no    INTEGER NOT NULL,
  chain_id      TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  kind          TEXT NOT NULL,
  v             INTEGER NOT NULL DEFAULT 1,
  body_json     TEXT NOT NULL,
  writer        TEXT NOT NULL CHECK (writer IN ('bridge', 'hub', 'agent', 'user')),
  written_at    TEXT NOT NULL,
  PRIMARY KEY (task_id, attempt_no, kind)
);
CREATE TRIGGER IF NOT EXISTS task_attempt_facets_owner_immutable BEFORE UPDATE OF owner_user_id ON task_attempt_facets BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;

CREATE TABLE IF NOT EXISTS task_leases (
  lease_id           TEXT PRIMARY KEY,
  task_id            TEXT NOT NULL,
  chain_id           TEXT NOT NULL,
  owner_user_id      TEXT NOT NULL,
  attempt_no         INTEGER NOT NULL,
  holder_instance_id TEXT NOT NULL UNIQUE,
  kind               TEXT NOT NULL CHECK (kind IN ('work', 'review')),
  review_role        TEXT NOT NULL DEFAULT '',
  bridge_id          TEXT NOT NULL DEFAULT '',
  provider           TEXT NOT NULL DEFAULT '',
  model              TEXT NOT NULL DEFAULT '',
  granted_at         TEXT NOT NULL,
  confirmed_at       TEXT NOT NULL DEFAULT '',
  expires_at         TEXT NOT NULL,
  hard_deadline_at   TEXT NOT NULL,
  last_beat_at       TEXT NOT NULL DEFAULT '',
  delivery           TEXT NOT NULL CHECK (delivery IN ('wake', 'inline'))
);
-- INV-ONE-LEASE: at most one live work lease per task (review leases are many).
CREATE UNIQUE INDEX IF NOT EXISTS idx_task_leases_one_work_per_task ON task_leases(task_id) WHERE kind = 'work';
CREATE INDEX IF NOT EXISTS idx_task_leases_chain ON task_leases(chain_id);
CREATE INDEX IF NOT EXISTS idx_task_leases_bridge ON task_leases(bridge_id);
CREATE TRIGGER IF NOT EXISTS task_leases_owner_immutable BEFORE UPDATE OF owner_user_id ON task_leases BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;

CREATE TABLE IF NOT EXISTS task_reviews (
  task_id              TEXT NOT NULL,
  chain_id             TEXT NOT NULL,
  owner_user_id        TEXT NOT NULL,
  attempt_no           INTEGER NOT NULL,
  role                 TEXT NOT NULL,
  reviewer_kind        TEXT NOT NULL CHECK (reviewer_kind IN ('agent', 'user')),
  reviewer_agent_id    TEXT NOT NULL DEFAULT '',
  reviewer_instance_id TEXT NOT NULL DEFAULT '',
  verdict              TEXT NOT NULL,
  findings_json        TEXT NOT NULL DEFAULT '[]',
  created_at           TEXT NOT NULL,
  PRIMARY KEY (task_id, attempt_no, role, reviewer_agent_id)
);
CREATE TRIGGER IF NOT EXISTS task_reviews_owner_immutable BEFORE UPDATE OF owner_user_id ON task_reviews BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;

CREATE TABLE IF NOT EXISTS chain_summaries (
  chain_id      TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  body          TEXT NOT NULL DEFAULT '',
  line_count    INTEGER NOT NULL DEFAULT 0,
  version       INTEGER NOT NULL DEFAULT 0,
  updated_at    TEXT NOT NULL
);
CREATE TRIGGER IF NOT EXISTS chain_summaries_owner_immutable BEFORE UPDATE OF owner_user_id ON chain_summaries BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;

-- Append-only: an edit is a new version; a run snapshot pins (def_id, version).
CREATE TABLE IF NOT EXISTS workflow_definitions (
  def_id        TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  name          TEXT NOT NULL,
  version       INTEGER NOT NULL,
  body_json     TEXT NOT NULL,
  created_at    TEXT NOT NULL,
  UNIQUE (owner_user_id, name, version)
);
CREATE TRIGGER IF NOT EXISTS workflow_definitions_owner_immutable BEFORE UPDATE OF owner_user_id ON workflow_definitions BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
CREATE TRIGGER IF NOT EXISTS workflow_definitions_append_only BEFORE UPDATE OF body_json, name, version ON workflow_definitions BEGIN SELECT RAISE(ABORT, 'workflow_definitions is append-only'); END;

-- ---------------------------------------------------------------------------
-- 2. Altered tables (additive)
-- ---------------------------------------------------------------------------
ALTER TABLE tasks ADD COLUMN state TEXT NOT NULL DEFAULT 'backlog';
ALTER TABLE tasks ADD COLUMN kind TEXT NOT NULL DEFAULT 'task';
ALTER TABLE tasks ADD COLUMN attempt_no INTEGER NOT NULL DEFAULT 0;
ALTER TABLE tasks ADD COLUMN brief_json TEXT NOT NULL DEFAULT '{}';
ALTER TABLE tasks ADD COLUMN blocked_on_json TEXT NOT NULL DEFAULT '';
ALTER TABLE tasks ADD COLUMN requires_user_approval INTEGER NOT NULL DEFAULT 0;
ALTER TABLE tasks ADD COLUMN ready_since TEXT NOT NULL DEFAULT '';
ALTER TABLE tasks ADD COLUMN stage_key TEXT NOT NULL DEFAULT '';
ALTER TABLE tasks ADD COLUMN stage_index INTEGER NOT NULL DEFAULT 0;
ALTER TABLE tasks ADD COLUMN generated_by_json TEXT NOT NULL DEFAULT '';
-- Materialisation idempotency: one instance per (chain, stage, index). Hand-made
-- tickets carry stage_key = '' and must not collide, hence the partial index.
CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_chain_stage ON tasks(chain_id, stage_key, stage_index) WHERE stage_key <> '';

ALTER TABLE task_chains ADD COLUMN workflow_def_ref TEXT NOT NULL DEFAULT '';
ALTER TABLE task_chains ADD COLUMN workflow_snapshot_json TEXT NOT NULL DEFAULT '';
ALTER TABLE task_chains ADD COLUMN defaults_json TEXT NOT NULL DEFAULT '{}';
-- The run snapshot is written once at workflow.run and never changes.
CREATE TRIGGER IF NOT EXISTS task_chains_workflow_snapshot_immutable BEFORE UPDATE OF workflow_snapshot_json ON task_chains WHEN old.workflow_snapshot_json <> '' BEGIN SELECT RAISE(ABORT, 'workflow_snapshot_json is immutable'); END;

ALTER TABLE task_chain_fleets ADD COLUMN roles_json TEXT NOT NULL DEFAULT '["worker"]';
ALTER TABLE task_chain_fleets ADD COLUMN bridge_id TEXT NOT NULL DEFAULT '';

-- ---------------------------------------------------------------------------
-- 3. Data migration
-- ---------------------------------------------------------------------------
-- 3a. Chain kind: team_work (and anything unknown) → ticket. private_conversation
--     (the per-instance chat chain the agent service creates) keeps its label; the
--     engine treats it as a ticket chain.
UPDATE task_chains SET kind = 'ticket' WHERE kind NOT IN ('workflow', 'private_conversation');

-- 3b. Legacy reviewer refs → fleet rows carrying the reviewer role. agent_id refs
--     map directly; agent_instance refs map through the instance's template.
--     Task-level refs first, then chain defaults.
INSERT OR IGNORE INTO task_chain_fleets (task_chain_id, agent_id, capacity, min_warm, idle_ttl_seconds, created_at, updated_at, bridge_models_json, roles_json, bridge_id)
SELECT DISTINCT t.chain_id,
       COALESCE(json_extract(r.value, '$.agent_id'), (SELECT ai.agent_id FROM agent_instances ai WHERE ai.agent_instance_id = json_extract(r.value, '$.agent_instance_id'))),
       1, 0, 600, t.updated_at, t.updated_at, '{}', '["reviewer"]', ''
FROM tasks t, json_each(CASE WHEN json_valid(t.reviewer_refs_json) THEN t.reviewer_refs_json ELSE '[]' END) r
WHERE json_type(r.value) = 'object'
  AND COALESCE(json_extract(r.value, '$.agent_id'), (SELECT ai.agent_id FROM agent_instances ai WHERE ai.agent_instance_id = json_extract(r.value, '$.agent_instance_id'))) IS NOT NULL;

INSERT OR IGNORE INTO task_chain_fleets (task_chain_id, agent_id, capacity, min_warm, idle_ttl_seconds, created_at, updated_at, bridge_models_json, roles_json, bridge_id)
SELECT DISTINCT c.chain_id,
       COALESCE(json_extract(r.value, '$.agent_id'), (SELECT ai.agent_id FROM agent_instances ai WHERE ai.agent_instance_id = json_extract(r.value, '$.agent_instance_id'))),
       1, 0, 600, c.updated_at, c.updated_at, '{}', '["reviewer"]', ''
FROM task_chains c, json_each(CASE WHEN json_valid(c.default_reviewer_refs_json) THEN c.default_reviewer_refs_json ELSE '[]' END) r
WHERE json_type(r.value) = 'object'
  AND COALESCE(json_extract(r.value, '$.agent_id'), (SELECT ai.agent_id FROM agent_instances ai WHERE ai.agent_instance_id = json_extract(r.value, '$.agent_instance_id'))) IS NOT NULL;

-- Existing fleet rows (auto-created per assignee/reviewer ref) that are referenced
-- as reviewers gain the reviewer role in addition to worker.
UPDATE task_chain_fleets SET roles_json = json_insert(roles_json, '$[#]', 'reviewer')
WHERE NOT EXISTS (SELECT 1 FROM json_each(task_chain_fleets.roles_json) j WHERE j.value = 'reviewer')
  AND (
    EXISTS (
      SELECT 1 FROM tasks t, json_each(CASE WHEN json_valid(t.reviewer_refs_json) THEN t.reviewer_refs_json ELSE '[]' END) r
      WHERE t.chain_id = task_chain_fleets.task_chain_id AND json_type(r.value) = 'object'
        AND COALESCE(json_extract(r.value, '$.agent_id'), (SELECT ai.agent_id FROM agent_instances ai WHERE ai.agent_instance_id = json_extract(r.value, '$.agent_instance_id'))) = task_chain_fleets.agent_id)
    OR EXISTS (
      SELECT 1 FROM task_chains c, json_each(CASE WHEN json_valid(c.default_reviewer_refs_json) THEN c.default_reviewer_refs_json ELSE '[]' END) r
      WHERE c.chain_id = task_chain_fleets.task_chain_id AND json_type(r.value) = 'object'
        AND COALESCE(json_extract(r.value, '$.agent_id'), (SELECT ai.agent_id FROM agent_instances ai WHERE ai.agent_instance_id = json_extract(r.value, '$.agent_instance_id'))) = task_chain_fleets.agent_id)
  );

-- 3c. Migrated fleet rows default to the chain's CURRENT effective bridge
--     (coordinator → members → directories → first owner bridge), so the new
--     resolution order (fleet row before directory/coordinator) moves nothing.
UPDATE task_chain_fleets SET bridge_id = COALESCE(
  (SELECT ai.bridge_id FROM task_chains tc JOIN agent_instances ai ON ai.agent_instance_id = tc.coordinator_agent_instance_id
     WHERE tc.chain_id = task_chain_fleets.task_chain_id AND ai.bridge_id <> ''),
  (SELECT ai.bridge_id FROM task_chain_members m JOIN agent_instances ai ON ai.agent_instance_id = m.agent_instance_id
     WHERE m.chain_id = task_chain_fleets.task_chain_id AND ai.bridge_id <> '' ORDER BY m.created_at ASC LIMIT 1),
  (SELECT ai.bridge_id FROM agent_instances ai
     WHERE ai.chain_id = task_chain_fleets.task_chain_id AND ai.bridge_id <> '' ORDER BY ai.created_at ASC LIMIT 1),
  (SELECT d.bridge_id FROM task_chain_directories d
     WHERE d.chain_id = task_chain_fleets.task_chain_id AND d.bridge_id <> '' ORDER BY d.created_at ASC LIMIT 1),
  (SELECT b.bridge_id FROM bridges b JOIN task_chains tc ON tc.owner_user_id = b.owner_user_id
     WHERE tc.chain_id = task_chain_fleets.task_chain_id ORDER BY b.created_at ASC LIMIT 1),
  '')
WHERE bridge_id = '';

-- 3d. Per-task fields: requires_user_approval from a `user` reviewer ref; brief
--     from title/description + assignee template + review_roles.
UPDATE tasks SET requires_user_approval = 1
WHERE EXISTS (
  SELECT 1 FROM json_each(CASE WHEN json_valid(tasks.reviewer_refs_json) THEN tasks.reviewer_refs_json ELSE '[]' END) r
  WHERE json_type(r.value) = 'object' AND (json_extract(r.value, '$.type') = 'user' OR COALESCE(json_extract(r.value, '$.user_id'), '') <> '')
);

UPDATE tasks SET brief_json = json_remove(
  json_object(
    'goal', CASE WHEN description <> '' THEN description ELSE title END,
    'acceptance', json('[]'),
    'verify', '',
    'review_roles', CASE WHEN
      (SELECT COUNT(*) FROM json_each(CASE WHEN json_valid(tasks.reviewer_refs_json) THEN tasks.reviewer_refs_json ELSE '[]' END) r
         WHERE json_type(r.value) = 'object' AND (
           json_extract(r.value, '$.agent_id') IS NOT NULL
           OR EXISTS (SELECT 1 FROM agent_instances ai WHERE ai.agent_instance_id = json_extract(r.value, '$.agent_instance_id'))))
      + (SELECT COUNT(*) FROM task_chains c, json_each(CASE WHEN json_valid(c.default_reviewer_refs_json) THEN c.default_reviewer_refs_json ELSE '[]' END) r
         WHERE c.chain_id = tasks.chain_id AND json_type(r.value) = 'object' AND (
           json_extract(r.value, '$.agent_id') IS NOT NULL
           OR EXISTS (SELECT 1 FROM agent_instances ai WHERE ai.agent_instance_id = json_extract(r.value, '$.agent_instance_id'))))
      > 0 THEN json('["reviewer"]') ELSE json('[]') END,
    'assignee', COALESCE(
      CASE WHEN json_valid(tasks.assignee_ref_json) THEN json_extract(tasks.assignee_ref_json, '$.agent_id') END,
      (SELECT ai.agent_id FROM agent_instances ai WHERE json_valid(tasks.assignee_ref_json) AND ai.agent_instance_id = json_extract(tasks.assignee_ref_json, '$.agent_instance_id'))),
    'migrated_from', json_object('status', status)
  ),
  CASE WHEN COALESCE(
      CASE WHEN json_valid(tasks.assignee_ref_json) THEN json_extract(tasks.assignee_ref_json, '$.agent_id') END,
      (SELECT ai.agent_id FROM agent_instances ai WHERE json_valid(tasks.assignee_ref_json) AND ai.agent_instance_id = json_extract(tasks.assignee_ref_json, '$.agent_instance_id'))) IS NULL
    THEN '$.assignee' ELSE '$.__absent' END);

-- 3e. Legacy status → v2 state. assigned/queued → ready only when published AND
--     every dependency is already terminal; otherwise backlog. in_progress /
--     validated_not_good / finishing → in_progress. in_validation /
--     validated_good → in_review. paused → backlog + blocked_on human.
--     completed → done. cancelled → cancelled. pausing → in_progress.
UPDATE tasks SET state = CASE status
  WHEN 'completed' THEN 'done'
  WHEN 'cancelled' THEN 'cancelled'
  WHEN 'in_validation' THEN 'in_review'
  WHEN 'validated_good' THEN 'in_review'
  WHEN 'in_progress' THEN 'in_progress'
  WHEN 'validated_not_good' THEN 'in_progress'
  WHEN 'finishing' THEN 'in_progress'
  WHEN 'pausing' THEN 'in_progress'
  WHEN 'paused' THEN 'backlog'
  ELSE CASE
    WHEN publish_state = 'published' AND NOT EXISTS (
      SELECT 1 FROM task_dependencies d JOIN tasks p ON p.task_id = d.depends_on_task_id
      WHERE d.task_id = tasks.task_id AND p.status NOT IN ('completed', 'cancelled'))
    THEN 'ready' ELSE 'backlog' END
  END;

UPDATE tasks SET blocked_on_json = json_object('kind', 'human', 'reason', 'paused_before_v2', 'since', updated_at)
WHERE status = 'paused';

UPDATE tasks SET ready_since = updated_at WHERE state = 'ready';

-- Tasks that already had a running or reviewed attempt start at attempt 1 so the
-- next grant (attempt 2) is attributable; never-started tasks stay at 0.
UPDATE tasks SET attempt_no = 1 WHERE status IN ('in_progress', 'validated_not_good', 'finishing', 'pausing', 'in_validation', 'validated_good', 'completed');

-- 3f. One synthetic `migrated` event per task so the fold has a baseline; the
--     fold treats it as the authoritative pre-v2 state.
INSERT INTO task_events (task_id, chain_id, owner_user_id, ts_ms, actor_kind, actor_id, kind, payload_json)
SELECT t.task_id, t.chain_id, t.owner_user_id,
       CAST(strftime('%s', 'now') AS INTEGER) * 1000,
       'hub', '', 'migrated',
       json_object('from_status', t.status, 'state', t.state, 'published', t.publish_state = 'published', 'attempt_no', t.attempt_no,
                   'blocked_on', CASE WHEN t.blocked_on_json <> '' THEN json(t.blocked_on_json) ELSE NULL END)
FROM tasks t
WHERE NOT EXISTS (SELECT 1 FROM task_events e WHERE e.task_id = t.task_id AND e.kind = 'migrated');

-- The legacy votes carry no attempt number and cannot be mapped honestly; they
-- are dropped (with the table) by upgrade_task_v2_schema.

-- LAST OBJECT (skip-guard key): created only once everything above succeeded.
CREATE INDEX IF NOT EXISTS idx_tasks_chain_state ON tasks(chain_id, state);
COMMIT;
