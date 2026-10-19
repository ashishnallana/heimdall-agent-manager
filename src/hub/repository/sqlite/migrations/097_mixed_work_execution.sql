-- Breaking mixed-work engine cutover. An installation with chain-owned
-- workflow data must reset that task data explicitly; never reinterpret it.
BEGIN;
CREATE TEMP TABLE mixed_work_cutover_guard (old_workflow_count INTEGER CHECK(old_workflow_count = 0));
INSERT INTO mixed_work_cutover_guard SELECT count(*) FROM task_chains WHERE workflow_snapshot_json != '';
INSERT INTO mixed_work_cutover_guard SELECT count(*) FROM task_dependencies;
DROP TABLE mixed_work_cutover_guard;
DROP TRIGGER IF EXISTS task_chains_workflow_snapshot_immutable;
ALTER TABLE task_chains DROP COLUMN workflow_def_ref;
ALTER TABLE task_chains DROP COLUMN workflow_snapshot_json;
ALTER TABLE task_chains RENAME COLUMN kind TO legacy_execution_kind;
ALTER TABLE task_chains ADD COLUMN kind TEXT NOT NULL DEFAULT 'mixed_work' CHECK(kind = 'mixed_work');
ALTER TABLE task_chains DROP COLUMN legacy_execution_kind;
CREATE TRIGGER task_chains_mixed_kind_insert BEFORE INSERT ON task_chains
WHEN NEW.kind != 'mixed_work' BEGIN SELECT RAISE(ABORT,'all task chains must be mixed_work'); END;
CREATE TRIGGER task_chains_mixed_kind_update BEFORE UPDATE OF kind ON task_chains
WHEN NEW.kind != 'mixed_work' BEGIN SELECT RAISE(ABORT,'all task chains must be mixed_work'); END;
ALTER TABLE tasks ADD COLUMN workflow_run_id TEXT NOT NULL DEFAULT '';
ALTER TABLE tasks ADD COLUMN workflow_execution_no INTEGER NOT NULL DEFAULT 0;
ALTER TABLE task_chains ADD COLUMN work_revision INTEGER NOT NULL DEFAULT 0;
ALTER TABLE task_chains ADD COLUMN completion_summary TEXT NOT NULL DEFAULT '';
DROP INDEX IF EXISTS idx_tasks_chain_stage;
CREATE UNIQUE INDEX idx_tasks_run_stage ON tasks(workflow_run_id, workflow_execution_no, stage_key, stage_index) WHERE workflow_run_id != '';
CREATE INDEX idx_tasks_workflow_execution ON tasks(workflow_run_id, workflow_execution_no);
CREATE TRIGGER tasks_workflow_identity_insert BEFORE INSERT ON tasks
WHEN NOT ((NEW.workflow_run_id = '' AND NEW.workflow_execution_no = 0 AND NEW.stage_key = '' AND NEW.kind = 'task') OR
 (NEW.workflow_run_id != '' AND NEW.workflow_execution_no > 0 AND NEW.stage_key != '' AND EXISTS (
 SELECT 1 FROM workflow_runs r JOIN workflow_run_executions e ON e.run_id = r.run_id AND e.execution_no = r.current_execution_no
 WHERE r.run_id = NEW.workflow_run_id AND e.execution_no = NEW.workflow_execution_no
 AND e.chain_id = NEW.chain_id AND e.owner_user_id = NEW.owner_user_id AND e.state = 'running')))
BEGIN SELECT RAISE(ABORT, 'generated task requires the current owned running workflow execution'); END;
CREATE TRIGGER tasks_workflow_identity_immutable BEFORE UPDATE ON tasks
WHEN NEW.workflow_run_id IS NOT OLD.workflow_run_id OR NEW.workflow_execution_no != OLD.workflow_execution_no
 OR NEW.stage_key IS NOT OLD.stage_key OR NEW.stage_index != OLD.stage_index
BEGIN SELECT RAISE(ABORT, 'workflow task identity is immutable'); END;
CREATE TRIGGER tasks_workflow_execution_active BEFORE UPDATE ON tasks
WHEN OLD.workflow_run_id != '' AND (NEW.state != OLD.state OR NEW.attempt_no != OLD.attempt_no)
 AND NOT EXISTS (SELECT 1 FROM workflow_runs r JOIN workflow_run_executions e
 ON e.run_id = r.run_id AND e.execution_no = r.current_execution_no
 WHERE r.run_id = OLD.workflow_run_id AND e.execution_no = OLD.workflow_execution_no AND e.state = 'running')
BEGIN SELECT RAISE(ABORT,'historical workflow tasks cannot change state'); END;
CREATE TRIGGER tasks_workflow_definition_immutable BEFORE UPDATE ON tasks
WHEN OLD.workflow_run_id != '' AND (NEW.title IS NOT OLD.title OR NEW.description IS NOT OLD.description
 OR NEW.brief_json IS NOT OLD.brief_json OR NEW.kind IS NOT OLD.kind OR NEW.generated_by_json IS NOT OLD.generated_by_json)
BEGIN SELECT RAISE(ABORT,'workflow-generated task definition is immutable'); END;
CREATE TRIGGER tasks_workflow_no_delete BEFORE DELETE ON tasks WHEN OLD.workflow_run_id != ''
BEGIN SELECT RAISE(ABORT,'workflow-generated task history is immutable'); END;
CREATE TRIGGER task_dependencies_internal_only BEFORE INSERT ON task_dependencies
WHEN NOT EXISTS (SELECT 1 FROM tasks a JOIN tasks b ON b.task_id = NEW.depends_on_task_id
 WHERE a.task_id = NEW.task_id AND a.workflow_run_id != '' AND a.workflow_run_id = b.workflow_run_id
 AND a.workflow_execution_no = b.workflow_execution_no AND a.chain_id = NEW.chain_id
 AND b.chain_id = NEW.chain_id AND a.owner_user_id = NEW.owner_user_id AND b.owner_user_id = NEW.owner_user_id)
BEGIN SELECT RAISE(ABORT, 'task_dependencies are private to one workflow execution'); END;
CREATE TRIGGER tasks_work_revision_insert AFTER INSERT ON tasks BEGIN
 UPDATE task_chains SET work_revision = work_revision + 1 WHERE chain_id = NEW.chain_id;
END;
CREATE TRIGGER tasks_work_revision_update AFTER UPDATE ON tasks
WHEN NEW.state != OLD.state OR NEW.attempt_no != OLD.attempt_no OR NEW.publish_state != OLD.publish_state OR NEW.brief_json != OLD.brief_json
BEGIN UPDATE task_chains SET work_revision = work_revision + 1 WHERE chain_id = NEW.chain_id; END;
CREATE TRIGGER workflow_runs_work_revision_insert AFTER INSERT ON workflow_runs BEGIN UPDATE task_chains SET work_revision = work_revision + 1 WHERE chain_id = NEW.chain_id; END;
CREATE TRIGGER workflow_runs_work_revision_update AFTER UPDATE ON workflow_runs BEGIN UPDATE task_chains SET work_revision = work_revision + 1 WHERE chain_id = NEW.chain_id; END;
CREATE TRIGGER workflow_run_executions_work_revision_insert AFTER INSERT ON workflow_run_executions BEGIN UPDATE task_chains SET work_revision = work_revision + 1 WHERE chain_id = NEW.chain_id; END;
CREATE TRIGGER workflow_run_executions_work_revision_update AFTER UPDATE ON workflow_run_executions BEGIN UPDATE task_chains SET work_revision = work_revision + 1 WHERE chain_id = NEW.chain_id; END;
CREATE TRIGGER work_dependencies_work_revision_insert AFTER INSERT ON work_dependencies BEGIN UPDATE task_chains SET work_revision = work_revision + 1 WHERE chain_id = NEW.chain_id; END;
CREATE TRIGGER work_dependencies_work_revision_update AFTER UPDATE ON work_dependencies BEGIN UPDATE task_chains SET work_revision = work_revision + 1 WHERE chain_id = NEW.chain_id; END;
CREATE TRIGGER work_scope_decisions_work_revision_insert AFTER INSERT ON work_scope_decisions BEGIN UPDATE task_chains SET work_revision = work_revision + 1 WHERE chain_id = NEW.chain_id; END;
CREATE TRIGGER task_chains_work_revision_control AFTER UPDATE ON task_chains
WHEN NEW.work_revision = OLD.work_revision AND (NEW.status != OLD.status OR NEW.publish_state != OLD.publish_state OR NEW.coordinator_agent_instance_id != OLD.coordinator_agent_instance_id OR NEW.defaults_json != OLD.defaults_json)
BEGIN UPDATE task_chains SET work_revision = work_revision + 1 WHERE chain_id = NEW.chain_id; END;
CREATE TABLE work_chain_completions (
 completion_id INTEGER PRIMARY KEY AUTOINCREMENT, chain_id TEXT NOT NULL, owner_user_id TEXT NOT NULL,
 work_revision INTEGER NOT NULL, summary TEXT NOT NULL CHECK(length(trim(summary)) > 0), completed_at TEXT NOT NULL,
 FOREIGN KEY(chain_id,owner_user_id) REFERENCES task_chains(chain_id,owner_user_id));
CREATE TRIGGER work_chain_completions_capture AFTER UPDATE OF status ON task_chains
WHEN NEW.status = 'completed' AND OLD.status != 'completed'
BEGIN INSERT INTO work_chain_completions(chain_id,owner_user_id,work_revision,summary,completed_at) VALUES (NEW.chain_id,NEW.owner_user_id,NEW.work_revision,NEW.completion_summary,NEW.completed_at); END;
CREATE TRIGGER work_chain_completions_no_update BEFORE UPDATE ON work_chain_completions BEGIN SELECT RAISE(ABORT,'completion history is immutable'); END;
CREATE TRIGGER work_chain_completions_no_delete BEFORE DELETE ON work_chain_completions BEGIN SELECT RAISE(ABORT,'completion history is immutable'); END;
CREATE TABLE mixed_work_engine_epoch (epoch INTEGER PRIMARY KEY CHECK(epoch = 1));
INSERT INTO mixed_work_engine_epoch VALUES (1);
COMMIT;
