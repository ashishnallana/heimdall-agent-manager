-- REQ-MW-4/5/6/9: external mixed-work DAG and durable consumption provenance.
-- These tables are the canonical new contracts, not adapters to task_dependencies.
BEGIN;
CREATE TABLE work_dependencies (
  dependency_id TEXT PRIMARY KEY CHECK(length(dependency_id) > 0),
  chain_id TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  dependent_kind TEXT NOT NULL CHECK(dependent_kind IN ('task', 'workflow_run')),
  dependent_id TEXT NOT NULL,
  prerequisite_kind TEXT NOT NULL CHECK(prerequisite_kind IN ('task', 'workflow_run')),
  prerequisite_id TEXT NOT NULL,
  created_by_kind TEXT NOT NULL CHECK(created_by_kind IN ('user', 'agent', 'hub')),
  created_by_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  removed_at TEXT NOT NULL DEFAULT '',
  removed_by_kind TEXT NOT NULL DEFAULT '' CHECK(removed_by_kind IN ('', 'user', 'agent', 'hub')),
  removed_by_id TEXT NOT NULL DEFAULT '',
  removal_reason TEXT NOT NULL DEFAULT '',
  CHECK(dependent_kind != prerequisite_kind OR dependent_id != prerequisite_id),
  CHECK((removed_at = '' AND removed_by_kind = '' AND removed_by_id = '' AND removal_reason = '')
     OR (removed_at != '' AND removed_by_kind != '' AND length(trim(removal_reason)) > 0)),
  FOREIGN KEY(chain_id, owner_user_id) REFERENCES task_chains(chain_id, owner_user_id)
);
CREATE UNIQUE INDEX idx_work_dependencies_active ON work_dependencies(chain_id, dependent_kind, dependent_id, prerequisite_kind, prerequisite_id) WHERE removed_at = '';
CREATE INDEX idx_work_dependencies_chain ON work_dependencies(chain_id, owner_user_id, created_at, dependency_id);

CREATE TABLE work_input_receipts (
  receipt_id TEXT PRIMARY KEY CHECK(length(receipt_id) > 0),
  chain_id TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  dependent_kind TEXT NOT NULL CHECK(dependent_kind IN ('task', 'workflow_run')),
  dependent_id TEXT NOT NULL,
  dependent_generation INTEGER NOT NULL CHECK(dependent_generation > 0),
  prerequisite_kind TEXT NOT NULL CHECK(prerequisite_kind IN ('task', 'workflow_run')),
  prerequisite_id TEXT NOT NULL,
  prerequisite_generation INTEGER NOT NULL CHECK(prerequisite_generation > 0),
  output_manifest_json TEXT NOT NULL CHECK(json_valid(output_manifest_json) AND json_type(output_manifest_json) = 'object'),
  created_at TEXT NOT NULL,
  UNIQUE(dependent_kind, dependent_id, dependent_generation, prerequisite_kind, prerequisite_id),
  FOREIGN KEY(chain_id, owner_user_id) REFERENCES task_chains(chain_id, owner_user_id)
);
CREATE INDEX idx_work_receipts_prerequisite ON work_input_receipts(prerequisite_kind, prerequisite_id, owner_user_id);
CREATE INDEX idx_work_receipts_dependent ON work_input_receipts(dependent_kind, dependent_id, owner_user_id);

CREATE TABLE work_scope_decisions (
  decision_id INTEGER PRIMARY KEY AUTOINCREMENT,
  chain_id TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  item_kind TEXT NOT NULL CHECK(item_kind IN ('task', 'workflow_run')),
  item_id TEXT NOT NULL,
  action TEXT NOT NULL CHECK(action IN ('include', 'exclude')),
  reason TEXT NOT NULL CHECK(length(trim(reason)) > 0),
  actor_kind TEXT NOT NULL CHECK(actor_kind IN ('user', 'agent', 'hub')),
  actor_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  FOREIGN KEY(chain_id, owner_user_id) REFERENCES task_chains(chain_id, owner_user_id)
);
CREATE INDEX idx_work_scope_chain ON work_scope_decisions(chain_id, owner_user_id, decision_id);

CREATE TRIGGER work_dependencies_endpoint_scope BEFORE INSERT ON work_dependencies
WHEN NOT (((NEW.dependent_kind = 'task' AND EXISTS (
 SELECT 1 FROM tasks t WHERE t.task_id = NEW.dependent_id
 AND t.chain_id = NEW.chain_id AND t.owner_user_id = NEW.owner_user_id
 AND t.stage_key = '' AND t.kind = 'task')) OR
 (NEW.dependent_kind = 'workflow_run' AND EXISTS (
 SELECT 1 FROM workflow_runs r WHERE r.run_id = NEW.dependent_id
 AND r.chain_id = NEW.chain_id AND r.owner_user_id = NEW.owner_user_id))) AND ((NEW.prerequisite_kind = 'task' AND EXISTS (
 SELECT 1 FROM tasks t WHERE t.task_id = NEW.prerequisite_id
 AND t.chain_id = NEW.chain_id AND t.owner_user_id = NEW.owner_user_id
 AND t.stage_key = '' AND t.kind = 'task')) OR
 (NEW.prerequisite_kind = 'workflow_run' AND EXISTS (
 SELECT 1 FROM workflow_runs r WHERE r.run_id = NEW.prerequisite_id
 AND r.chain_id = NEW.chain_id AND r.owner_user_id = NEW.owner_user_id))))
BEGIN SELECT RAISE(ABORT, 'mixed-work endpoints must be ordinary tickets or runs in the same owned chain'); END;

CREATE TRIGGER work_input_receipts_endpoint_scope BEFORE INSERT ON work_input_receipts
WHEN NOT (((NEW.dependent_kind = 'task' AND EXISTS (
 SELECT 1 FROM tasks t WHERE t.task_id = NEW.dependent_id
 AND t.chain_id = NEW.chain_id AND t.owner_user_id = NEW.owner_user_id
 AND t.stage_key = '' AND t.kind = 'task')) OR
 (NEW.dependent_kind = 'workflow_run' AND EXISTS (
 SELECT 1 FROM workflow_runs r WHERE r.run_id = NEW.dependent_id
 AND r.chain_id = NEW.chain_id AND r.owner_user_id = NEW.owner_user_id))) AND ((NEW.prerequisite_kind = 'task' AND EXISTS (
 SELECT 1 FROM tasks t WHERE t.task_id = NEW.prerequisite_id
 AND t.chain_id = NEW.chain_id AND t.owner_user_id = NEW.owner_user_id
 AND t.stage_key = '' AND t.kind = 'task')) OR
 (NEW.prerequisite_kind = 'workflow_run' AND EXISTS (
 SELECT 1 FROM workflow_runs r WHERE r.run_id = NEW.prerequisite_id
 AND r.chain_id = NEW.chain_id AND r.owner_user_id = NEW.owner_user_id))))
BEGIN SELECT RAISE(ABORT, 'mixed-work endpoints must be ordinary tickets or runs in the same owned chain'); END;

CREATE TRIGGER work_scope_decisions_endpoint_scope BEFORE INSERT ON work_scope_decisions
WHEN NOT (((NEW.item_kind = 'task' AND EXISTS (
 SELECT 1 FROM tasks t WHERE t.task_id = NEW.item_id
 AND t.chain_id = NEW.chain_id AND t.owner_user_id = NEW.owner_user_id
 AND t.stage_key = '' AND t.kind = 'task')) OR
 (NEW.item_kind = 'workflow_run' AND EXISTS (
 SELECT 1 FROM workflow_runs r WHERE r.run_id = NEW.item_id
 AND r.chain_id = NEW.chain_id AND r.owner_user_id = NEW.owner_user_id))))
BEGIN SELECT RAISE(ABORT, 'mixed-work endpoints must be ordinary tickets or runs in the same owned chain'); END;

CREATE TRIGGER work_dependencies_initial BEFORE INSERT ON work_dependencies
WHEN NEW.removed_at != ''
BEGIN SELECT RAISE(ABORT, 'new dependency must be active'); END;

CREATE TRIGGER work_dependencies_cycle BEFORE INSERT ON work_dependencies
WHEN EXISTS (
 WITH RECURSIVE reachable(kind, id) AS (
   SELECT NEW.prerequisite_kind, NEW.prerequisite_id
   UNION
   SELECT d.prerequisite_kind, d.prerequisite_id FROM work_dependencies d
   JOIN reachable n ON n.kind = d.dependent_kind AND n.id = d.dependent_id
   WHERE d.chain_id = NEW.chain_id AND d.owner_user_id = NEW.owner_user_id AND d.removed_at = ''
 ) SELECT 1 FROM reachable WHERE kind = NEW.dependent_kind AND id = NEW.dependent_id)
BEGIN SELECT RAISE(ABORT, 'mixed-work dependency cycle'); END;

CREATE TRIGGER work_dependencies_consumer_started BEFORE INSERT ON work_dependencies
WHEN (NEW.dependent_kind = 'task' AND EXISTS (
 SELECT 1 FROM tasks WHERE task_id = NEW.dependent_id
 AND (attempt_no > 0 OR state NOT IN ('backlog', 'ready'))))
 OR (NEW.dependent_kind = 'workflow_run' AND EXISTS (
 SELECT 1 FROM workflow_runs r JOIN workflow_run_executions e
 ON e.run_id = r.run_id AND e.execution_no = r.current_execution_no
 WHERE r.run_id = NEW.dependent_id AND (e.state NOT IN ('draft', 'pending') OR e.started_at != '')))
BEGIN SELECT RAISE(ABORT, 'cannot add prerequisites to started work'); END;

CREATE TRIGGER work_dependencies_remove_only BEFORE UPDATE ON work_dependencies
WHEN OLD.removed_at != '' OR NEW.removed_at = ''
 OR NEW.dependency_id IS NOT OLD.dependency_id OR NEW.chain_id IS NOT OLD.chain_id
 OR NEW.owner_user_id IS NOT OLD.owner_user_id OR NEW.dependent_kind IS NOT OLD.dependent_kind
 OR NEW.dependent_id IS NOT OLD.dependent_id OR NEW.prerequisite_kind IS NOT OLD.prerequisite_kind
 OR NEW.prerequisite_id IS NOT OLD.prerequisite_id OR NEW.created_by_kind IS NOT OLD.created_by_kind
 OR NEW.created_by_id IS NOT OLD.created_by_id OR NEW.created_at IS NOT OLD.created_at
BEGIN SELECT RAISE(ABORT, 'dependency may only be removed once with provenance'); END;
CREATE TRIGGER work_dependencies_no_delete BEFORE DELETE ON work_dependencies
BEGIN SELECT RAISE(ABORT, 'dependency history is immutable'); END;

CREATE TRIGGER work_input_receipts_active_edge BEFORE INSERT ON work_input_receipts
WHEN NOT EXISTS (SELECT 1 FROM work_dependencies d
 WHERE d.chain_id = NEW.chain_id AND d.owner_user_id = NEW.owner_user_id AND d.removed_at = ''
 AND d.dependent_kind = NEW.dependent_kind AND d.dependent_id = NEW.dependent_id
 AND d.prerequisite_kind = NEW.prerequisite_kind AND d.prerequisite_id = NEW.prerequisite_id)
BEGIN SELECT RAISE(ABORT, 'receipt requires an active dependency'); END;

CREATE TRIGGER work_input_receipts_provider_success BEFORE INSERT ON work_input_receipts
WHEN NOT (
 (NEW.prerequisite_kind = 'task' AND EXISTS (
   SELECT 1 FROM tasks t JOIN task_attempts a ON a.task_id = t.task_id AND a.attempt_no = t.attempt_no
   WHERE t.task_id = NEW.prerequisite_id AND t.state = 'done' AND t.attempt_no = NEW.prerequisite_generation
   AND a.chain_id = NEW.chain_id AND a.owner_user_id = NEW.owner_user_id)) OR
 (NEW.prerequisite_kind = 'workflow_run' AND EXISTS (
   SELECT 1 FROM workflow_runs r JOIN workflow_run_executions e ON e.run_id = r.run_id AND e.execution_no = r.current_execution_no
   WHERE r.run_id = NEW.prerequisite_id AND e.execution_no = NEW.prerequisite_generation AND e.state = 'succeeded'
   AND e.output_manifest_json = NEW.output_manifest_json)))
BEGIN SELECT RAISE(ABORT, 'receipt requires the current successful prerequisite generation'); END;

CREATE TRIGGER work_input_receipts_consumer_started BEFORE INSERT ON work_input_receipts
WHEN NOT (
 (NEW.dependent_kind = 'task' AND EXISTS (
   SELECT 1 FROM tasks t JOIN task_attempts a ON a.task_id = t.task_id AND a.attempt_no = t.attempt_no
   WHERE t.task_id = NEW.dependent_id AND t.state = 'in_progress' AND t.attempt_no = NEW.dependent_generation
   AND a.chain_id = NEW.chain_id AND a.owner_user_id = NEW.owner_user_id)) OR
 (NEW.dependent_kind = 'workflow_run' AND EXISTS (
   SELECT 1 FROM workflow_runs r JOIN workflow_run_executions e ON e.run_id = r.run_id AND e.execution_no = r.current_execution_no
   WHERE r.run_id = NEW.dependent_id AND e.execution_no = NEW.dependent_generation AND e.state = 'running')))
BEGIN SELECT RAISE(ABORT, 'receipt consumer must be the current started generation'); END;

CREATE TRIGGER workflow_runs_consumed_output BEFORE UPDATE OF current_execution_no ON workflow_runs
WHEN NEW.current_execution_no != OLD.current_execution_no AND EXISTS (
 SELECT 1 FROM work_input_receipts WHERE prerequisite_kind = 'workflow_run' AND prerequisite_id = OLD.run_id)
BEGIN SELECT RAISE(ABORT, 'workflow output already consumed; create a replacement run'); END;

CREATE TRIGGER tasks_consumed_output BEFORE UPDATE OF state, attempt_no ON tasks
WHEN (NEW.attempt_no != OLD.attempt_no OR (OLD.state = 'done' AND NEW.state != 'done')) AND EXISTS (
 SELECT 1 FROM work_input_receipts WHERE prerequisite_kind = 'task' AND prerequisite_id = OLD.task_id)
BEGIN SELECT RAISE(ABORT, 'task output already consumed; create a replacement ticket'); END;

CREATE TRIGGER task_output_facets_consumed_update BEFORE UPDATE ON task_attempt_facets
WHEN OLD.kind = 'output' AND EXISTS (
 SELECT 1 FROM work_input_receipts WHERE prerequisite_kind = 'task' AND prerequisite_id = OLD.task_id
 AND prerequisite_generation = OLD.attempt_no)
BEGIN SELECT RAISE(ABORT, 'consumed output facet is immutable'); END;
CREATE TRIGGER task_output_facets_consumed_delete BEFORE DELETE ON task_attempt_facets
WHEN OLD.kind = 'output' AND EXISTS (
 SELECT 1 FROM work_input_receipts WHERE prerequisite_kind = 'task' AND prerequisite_id = OLD.task_id
 AND prerequisite_generation = OLD.attempt_no)
BEGIN SELECT RAISE(ABORT, 'consumed output facet is immutable'); END;

CREATE TRIGGER task_output_facets_consumed_insert BEFORE INSERT ON task_attempt_facets
WHEN NEW.kind = 'output' AND EXISTS (
 SELECT 1 FROM work_input_receipts WHERE prerequisite_kind = 'task' AND prerequisite_id = NEW.task_id
 AND prerequisite_generation = NEW.attempt_no)
BEGIN SELECT RAISE(ABORT, 'cannot add output to an already consumed attempt'); END;

-- Polymorphic endpoints use insert validation rather than a generic node table.
-- Preserve that validation when a ticket's identity or classification changes.
CREATE TRIGGER work_tasks_identity_immutable BEFORE UPDATE ON tasks
WHEN (NEW.task_id IS NOT OLD.task_id OR NEW.chain_id IS NOT OLD.chain_id
 OR NEW.owner_user_id IS NOT OLD.owner_user_id OR NEW.stage_key IS NOT OLD.stage_key OR NEW.kind IS NOT OLD.kind)
 AND (EXISTS (SELECT 1 FROM work_dependencies WHERE
   (dependent_kind = 'task' AND dependent_id = OLD.task_id) OR (prerequisite_kind = 'task' AND prerequisite_id = OLD.task_id))
 OR EXISTS (SELECT 1 FROM work_input_receipts WHERE
   (dependent_kind = 'task' AND dependent_id = OLD.task_id) OR (prerequisite_kind = 'task' AND prerequisite_id = OLD.task_id))
 OR EXISTS (SELECT 1 FROM work_scope_decisions WHERE item_kind = 'task' AND item_id = OLD.task_id))
BEGIN SELECT RAISE(ABORT, 'referenced work item identity is immutable'); END;

CREATE TRIGGER work_tasks_no_delete BEFORE DELETE ON tasks
WHEN EXISTS (SELECT 1 FROM work_dependencies WHERE
 (dependent_kind = 'task' AND dependent_id = OLD.task_id) OR (prerequisite_kind = 'task' AND prerequisite_id = OLD.task_id))
 OR EXISTS (SELECT 1 FROM work_input_receipts WHERE
 (dependent_kind = 'task' AND dependent_id = OLD.task_id) OR (prerequisite_kind = 'task' AND prerequisite_id = OLD.task_id))
 OR EXISTS (SELECT 1 FROM work_scope_decisions WHERE item_kind = 'task' AND item_id = OLD.task_id)
BEGIN SELECT RAISE(ABORT, 'referenced work item history is immutable'); END;

CREATE TRIGGER work_scope_decisions_exclude_terminal BEFORE INSERT ON work_scope_decisions
WHEN NEW.action = 'exclude' AND NOT (
 (NEW.item_kind = 'task' AND EXISTS (SELECT 1 FROM tasks WHERE task_id = NEW.item_id AND state IN ('done', 'cancelled'))) OR
 (NEW.item_kind = 'workflow_run' AND EXISTS (
 SELECT 1 FROM workflow_runs r JOIN workflow_run_executions e ON e.run_id = r.run_id AND e.execution_no = r.current_execution_no
 WHERE r.run_id = NEW.item_id AND e.state IN ('succeeded', 'failed', 'cancelled'))))
BEGIN SELECT RAISE(ABORT, 'cancel active work before excluding it'); END;

CREATE TRIGGER work_input_receipts_no_update BEFORE UPDATE ON work_input_receipts
BEGIN SELECT RAISE(ABORT, 'mixed-work provenance is append-only'); END;

CREATE TRIGGER work_input_receipts_no_delete BEFORE DELETE ON work_input_receipts
BEGIN SELECT RAISE(ABORT, 'mixed-work provenance is append-only'); END;

CREATE TRIGGER work_scope_decisions_no_update BEFORE UPDATE ON work_scope_decisions
BEGIN SELECT RAISE(ABORT, 'mixed-work provenance is append-only'); END;

CREATE TRIGGER work_scope_decisions_no_delete BEFORE DELETE ON work_scope_decisions
BEGIN SELECT RAISE(ABORT, 'mixed-work provenance is append-only'); END;

COMMIT;
