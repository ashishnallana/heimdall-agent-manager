-- Mixed-work foundation (REQ-MW-1/3/9). No backfill, legacy conversion or
-- alternate readers: the engine cutover will remove chain-owned workflows.
-- Run + first execution + created event must be inserted in one UoW, because
-- the current execution reference is deferred until commit.
BEGIN;

CREATE UNIQUE INDEX idx_task_chains_owner_identity ON task_chains(chain_id, owner_user_id);

CREATE TABLE workflow_runs (
  run_id TEXT PRIMARY KEY CHECK(length(run_id) > 0),
  chain_id TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  title TEXT NOT NULL,
  definition_ref TEXT NOT NULL CHECK(length(definition_ref) > 0),
  spec_json TEXT NOT NULL CHECK(json_valid(spec_json) AND json_type(spec_json) = 'object'),
  inputs_json TEXT NOT NULL CHECK(json_valid(inputs_json) AND json_type(inputs_json) = 'object'),
  current_execution_no INTEGER NOT NULL CHECK(current_execution_no > 0),
  request_id TEXT NOT NULL CHECK(length(request_id) > 0),
  request_hash TEXT NOT NULL CHECK(length(request_hash) > 0),
  created_by_kind TEXT NOT NULL CHECK(created_by_kind IN ('user', 'agent', 'hub')),
  created_by_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision > 0),
  UNIQUE(run_id, chain_id, owner_user_id),
  UNIQUE(owner_user_id, chain_id, request_id),
  FOREIGN KEY(chain_id, owner_user_id) REFERENCES task_chains(chain_id, owner_user_id),
  FOREIGN KEY(run_id, current_execution_no) REFERENCES workflow_run_executions(run_id, execution_no) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX idx_workflow_runs_chain ON workflow_runs(chain_id, owner_user_id, created_at, run_id);

CREATE TABLE workflow_run_executions (
  run_id TEXT NOT NULL,
  execution_no INTEGER NOT NULL CHECK(execution_no > 0),
  chain_id TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('draft', 'pending', 'running', 'succeeded', 'failed', 'cancelled')),
  resolved_inputs_json TEXT NOT NULL CHECK(json_valid(resolved_inputs_json) AND json_type(resolved_inputs_json) = 'object'),
  started_at TEXT NOT NULL DEFAULT '',
  ended_at TEXT NOT NULL DEFAULT '',
  failure_code TEXT NOT NULL DEFAULT '',
  failure_detail TEXT NOT NULL DEFAULT '',
  output_manifest_json TEXT NOT NULL CHECK(json_valid(output_manifest_json) AND json_type(output_manifest_json) = 'object'),
  revision INTEGER NOT NULL CHECK(revision > 0),
  PRIMARY KEY(run_id, execution_no),
  UNIQUE(run_id, execution_no, chain_id, owner_user_id),
  FOREIGN KEY(run_id, chain_id, owner_user_id) REFERENCES workflow_runs(run_id, chain_id, owner_user_id)
);

CREATE TABLE workflow_stage_executions (
  run_id TEXT NOT NULL,
  execution_no INTEGER NOT NULL,
  stage_key TEXT NOT NULL CHECK(length(stage_key) > 0),
  chain_id TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  item_count INTEGER NOT NULL CHECK(item_count >= 0),
  expanded_at TEXT NOT NULL,
  PRIMARY KEY(run_id, execution_no, stage_key),
  FOREIGN KEY(run_id, execution_no, chain_id, owner_user_id) REFERENCES workflow_run_executions(run_id, execution_no, chain_id, owner_user_id)
);

CREATE TABLE workflow_run_events (
  event_id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  execution_no INTEGER NOT NULL,
  chain_id TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  ts_ms INTEGER NOT NULL,
  actor_kind TEXT NOT NULL CHECK(actor_kind IN ('user', 'agent', 'hub')),
  actor_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(length(kind) > 0),
  payload_json TEXT NOT NULL CHECK(json_valid(payload_json) AND json_type(payload_json) = 'object'),
  FOREIGN KEY(run_id, execution_no, chain_id, owner_user_id) REFERENCES workflow_run_executions(run_id, execution_no, chain_id, owner_user_id)
);
CREATE INDEX idx_workflow_run_events_run ON workflow_run_events(run_id, event_id);
CREATE INDEX idx_workflow_run_events_chain ON workflow_run_events(chain_id, owner_user_id, event_id);

CREATE TRIGGER workflow_runs_identity_immutable BEFORE UPDATE ON workflow_runs
WHEN NEW.run_id IS NOT OLD.run_id OR NEW.chain_id IS NOT OLD.chain_id
  OR NEW.owner_user_id IS NOT OLD.owner_user_id OR NEW.definition_ref IS NOT OLD.definition_ref
  OR NEW.spec_json IS NOT OLD.spec_json OR NEW.inputs_json IS NOT OLD.inputs_json
  OR NEW.request_id IS NOT OLD.request_id OR NEW.request_hash IS NOT OLD.request_hash
  OR NEW.created_by_kind IS NOT OLD.created_by_kind OR NEW.created_by_id IS NOT OLD.created_by_id
  OR NEW.created_at IS NOT OLD.created_at
BEGIN SELECT RAISE(ABORT, 'workflow run identity and snapshot are immutable'); END;

CREATE TRIGGER workflow_runs_revision BEFORE UPDATE ON workflow_runs
WHEN NEW.revision != OLD.revision + 1
BEGIN SELECT RAISE(ABORT, 'workflow run revision must advance by one'); END;

CREATE TRIGGER workflow_runs_generation BEFORE UPDATE OF current_execution_no ON workflow_runs
WHEN NEW.current_execution_no != OLD.current_execution_no
  AND (NEW.current_execution_no != OLD.current_execution_no + 1
    OR NOT EXISTS (SELECT 1 FROM workflow_run_executions e
      WHERE e.run_id = OLD.run_id AND e.execution_no = OLD.current_execution_no
        AND e.state IN ('succeeded', 'failed', 'cancelled')))
BEGIN SELECT RAISE(ABORT, 'retry requires the next generation and a terminal execution'); END;

CREATE TRIGGER workflow_executions_identity_immutable BEFORE UPDATE ON workflow_run_executions
WHEN NEW.run_id IS NOT OLD.run_id OR NEW.execution_no IS NOT OLD.execution_no
  OR NEW.chain_id IS NOT OLD.chain_id OR NEW.owner_user_id IS NOT OLD.owner_user_id
BEGIN SELECT RAISE(ABORT, 'workflow execution identity is immutable'); END;

CREATE TRIGGER workflow_executions_revision BEFORE UPDATE ON workflow_run_executions
WHEN NEW.revision != OLD.revision + 1
BEGIN SELECT RAISE(ABORT, 'workflow execution revision must advance by one'); END;

CREATE TRIGGER workflow_executions_terminal_immutable BEFORE UPDATE ON workflow_run_executions
WHEN OLD.state IN ('succeeded', 'failed', 'cancelled')
BEGIN SELECT RAISE(ABORT, 'terminal workflow execution is immutable'); END;

CREATE TRIGGER workflow_executions_state_transition BEFORE UPDATE OF state ON workflow_run_executions
WHEN NEW.state != OLD.state AND NOT (
  (OLD.state = 'draft' AND NEW.state IN ('pending', 'cancelled')) OR
  (OLD.state = 'pending' AND NEW.state IN ('running', 'failed', 'cancelled')) OR
  (OLD.state = 'running' AND NEW.state IN ('succeeded', 'failed', 'cancelled')))
BEGIN SELECT RAISE(ABORT, 'invalid workflow execution transition'); END;

CREATE TRIGGER workflow_executions_inputs_immutable BEFORE UPDATE OF resolved_inputs_json ON workflow_run_executions
WHEN OLD.state NOT IN ('draft', 'pending') AND NEW.resolved_inputs_json IS NOT OLD.resolved_inputs_json
BEGIN SELECT RAISE(ABORT, 'started workflow inputs are immutable'); END;

CREATE TRIGGER workflow_stage_executions_immutable BEFORE UPDATE ON workflow_stage_executions
BEGIN SELECT RAISE(ABORT, 'workflow expansion is immutable'); END;
CREATE TRIGGER workflow_stage_executions_no_delete BEFORE DELETE ON workflow_stage_executions
BEGIN SELECT RAISE(ABORT, 'workflow expansion history is immutable'); END;
CREATE TRIGGER workflow_run_events_immutable BEFORE UPDATE ON workflow_run_events
BEGIN SELECT RAISE(ABORT, 'workflow events are append-only'); END;
CREATE TRIGGER workflow_run_events_no_delete BEFORE DELETE ON workflow_run_events
BEGIN SELECT RAISE(ABORT, 'workflow events are append-only'); END;
CREATE TRIGGER workflow_run_executions_no_delete BEFORE DELETE ON workflow_run_executions
BEGIN SELECT RAISE(ABORT, 'workflow execution history is immutable'); END;
CREATE TRIGGER workflow_runs_no_delete BEFORE DELETE ON workflow_runs
BEGIN SELECT RAISE(ABORT, 'workflow run history is immutable'); END;

COMMIT;
