-- REQ-TV2-1/2: configured verification commands are removed. Review verdicts
-- are the only gate; workers and reviewers choose and report their own checks.
--
-- Every statement is idempotent: a re-run finds nothing left to change.
--
-- M5 (D2): legacy `verify` facets and verify-labelled events are kept as
-- read-only history. Nothing here deletes them, and no gate, pack or alert
-- reads them any more.
BEGIN;

-- ---------------------------------------------------------------------------
-- M4 (D1): in-flight tasks whose gate was waiting on the independent-verify
-- facet. Those tasks are in review, their brief requires an independent verify,
-- that verify has not passed on the current attempt, and no request_changes is
-- in. An approval given under the old regime assumed a command run, so:
--   * the approvals stay as audit rows, re-keyed under a `legacy-verify:` role
--     prefix that no gate pair matches. Each reviewer then owes a fresh review
--     for the same (agent, role) on the same attempt;
--   * a task with no reviewer and no user approval had only the command as its
--     gate, so it now requires user approval rather than completing by itself;
--   * a `reviews_superseded` audit event records what happened.
-- Tasks on every other chain, and every other task, are untouched here.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE tv2_verify_waiting AS
SELECT t.task_id, t.chain_id, t.owner_user_id, t.attempt_no,
       t.requires_user_approval,
       (COALESCE(json_array_length(json_extract(t.brief_json, '$.review_roles')), 0)
        + COALESCE(json_array_length(json_extract(t.brief_json, '$.reviewers')), 0)) AS reviewer_count
FROM tasks t
WHERE t.state = 'in_review'
  AND t.kind = 'task'
  AND json_valid(t.brief_json)
  AND json_type(t.brief_json, '$.require_independent_verify') = 'true'
  AND NOT EXISTS (
    SELECT 1 FROM task_attempt_facets f
    WHERE f.task_id = t.task_id AND f.attempt_no = t.attempt_no AND f.kind = 'verify'
      AND json_valid(f.body_json)
      AND json_extract(f.body_json, '$.exit_code') = 0
      AND json_type(f.body_json, '$.independent') = 'true')
  AND NOT EXISTS (
    SELECT 1 FROM task_reviews r
    WHERE r.task_id = t.task_id AND r.attempt_no = t.attempt_no AND r.verdict = 'request_changes');

INSERT INTO task_events (task_id, chain_id, owner_user_id, ts_ms, actor_kind, actor_id, kind, payload_json)
SELECT w.task_id, w.chain_id, w.owner_user_id,
       CAST(strftime('%s', 'now') AS INTEGER) * 1000, 'hub', 'verify_removed', 'reviews_superseded',
       json_object(
         'attempt_no', w.attempt_no,
         'reason', 'verify_removed',
         'superseded', (SELECT json_group_array(json_object('role', r.role, 'reviewer', r.reviewer_agent_id))
                        FROM task_reviews r
                        WHERE r.task_id = w.task_id AND r.attempt_no = w.attempt_no
                          AND r.reviewer_kind = 'agent' AND r.verdict = 'approve'
                          AND r.role NOT LIKE 'legacy-verify:%'),
         'requires_user_approval_set', json(CASE WHEN w.reviewer_count = 0 AND w.requires_user_approval = 0 THEN 'true' ELSE 'false' END))
FROM tv2_verify_waiting w;

UPDATE task_reviews SET role = 'legacy-verify:' || role
WHERE reviewer_kind = 'agent' AND verdict = 'approve'
  AND role NOT LIKE 'legacy-verify:%'
  AND EXISTS (SELECT 1 FROM tv2_verify_waiting w WHERE w.task_id = task_reviews.task_id AND w.attempt_no = task_reviews.attempt_no);

UPDATE tasks SET requires_user_approval = 1
WHERE task_id IN (SELECT task_id FROM tv2_verify_waiting WHERE reviewer_count = 0 AND requires_user_approval = 0);

DROP TABLE tv2_verify_waiting;

-- The hub re-evaluates every in-review gate once on its next boot (M4), then
-- deletes this marker.
CREATE TABLE IF NOT EXISTS taskv2_boot_regate (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  reason    TEXT NOT NULL
);
INSERT OR IGNORE INTO taskv2_boot_regate (singleton, reason) VALUES (1, 'verify_removed');

-- ---------------------------------------------------------------------------
-- M1: strip the removed keys from persisted briefs, chain defaults (including
-- a pending proposal's task specs) and stored workflow definitions.
-- ---------------------------------------------------------------------------
-- Workflow-generated task definitions are immutable (099). Like the
-- workflow_definitions guard below, this one-shot data migration lifts that
-- guard for its own brief rewrite and restores it unchanged (text identical
-- to 099). Without this, any workflow task whose brief still carries a removed
-- key aborts the whole migration and the hub cannot start.
DROP TRIGGER IF EXISTS tasks_workflow_definition_immutable;

UPDATE tasks
SET brief_json = json_remove(brief_json, '$.verify', '$.auto_submit', '$.require_independent_verify')
WHERE json_valid(brief_json)
  AND (json_type(brief_json, '$.verify') IS NOT NULL
    OR json_type(brief_json, '$.auto_submit') IS NOT NULL
    OR json_type(brief_json, '$.require_independent_verify') IS NOT NULL);

CREATE TRIGGER tasks_workflow_definition_immutable BEFORE UPDATE ON tasks
WHEN OLD.workflow_run_id != '' AND (NEW.title IS NOT OLD.title OR NEW.description IS NOT OLD.description
 OR NEW.brief_json IS NOT OLD.brief_json OR NEW.kind IS NOT OLD.kind OR NEW.generated_by_json IS NOT OLD.generated_by_json)
BEGIN SELECT RAISE(ABORT,'workflow-generated task definition is immutable'); END;

UPDATE task_chains
SET defaults_json = json_remove(defaults_json, '$.verify', '$.auto_submit', '$.require_independent_verify')
WHERE json_valid(defaults_json)
  AND (json_type(defaults_json, '$.verify') IS NOT NULL
    OR json_type(defaults_json, '$.auto_submit') IS NOT NULL
    OR json_type(defaults_json, '$.require_independent_verify') IS NOT NULL);

UPDATE task_chains
SET defaults_json = json_set(defaults_json, '$.proposal.tasks', (
  SELECT json_group_array(json(v)) FROM (
    SELECT CASE WHEN json_type(s.value, '$.brief') = 'object'
                THEN json_remove(s.value, '$.verify', '$.auto_submit', '$.require_independent_verify',
                                 '$.brief.verify', '$.brief.auto_submit', '$.brief.require_independent_verify')
                ELSE json_remove(s.value, '$.verify', '$.auto_submit', '$.require_independent_verify') END AS v
    FROM json_each(task_chains.defaults_json, '$.proposal.tasks') s
    ORDER BY s.key)))
WHERE json_valid(defaults_json)
  AND json_type(defaults_json, '$.proposal.tasks') = 'array'
  AND EXISTS (
    SELECT 1 FROM json_each(task_chains.defaults_json, '$.proposal.tasks') s
    WHERE json_type(s.value) = 'object'
      AND (json_type(s.value, '$.verify') IS NOT NULL OR json_type(s.value, '$.auto_submit') IS NOT NULL
        OR json_type(s.value, '$.require_independent_verify') IS NOT NULL
        OR json_type(s.value, '$.brief.verify') IS NOT NULL OR json_type(s.value, '$.brief.auto_submit') IS NOT NULL
        OR json_type(s.value, '$.brief.require_independent_verify') IS NOT NULL));

-- workflow_definitions is append-only; this one-shot data migration lifts the
-- guard for its own UPDATEs and restores it unchanged.
DROP TRIGGER IF EXISTS workflow_definitions_append_only;

UPDATE workflow_definitions
SET body_json = json_remove(body_json, '$.defaults.verify', '$.defaults.auto_submit', '$.defaults.require_independent_verify')
WHERE json_valid(body_json)
  AND (json_type(body_json, '$.defaults.verify') IS NOT NULL
    OR json_type(body_json, '$.defaults.auto_submit') IS NOT NULL
    OR json_type(body_json, '$.defaults.require_independent_verify') IS NOT NULL);

UPDATE workflow_definitions
SET body_json = json_set(body_json, '$.stages', (
  SELECT json_group_array(json(v)) FROM (
    SELECT CASE WHEN json_type(s.value, '$.brief') = 'object'
                THEN json_remove(s.value, '$.brief.verify', '$.brief.auto_submit', '$.brief.require_independent_verify')
                ELSE s.value END AS v
    FROM json_each(workflow_definitions.body_json, '$.stages') s
    ORDER BY s.key)))
WHERE json_valid(body_json)
  AND json_type(body_json, '$.stages') = 'array'
  AND EXISTS (
    SELECT 1 FROM json_each(workflow_definitions.body_json, '$.stages') s
    WHERE json_type(s.value, '$.brief.verify') IS NOT NULL
       OR json_type(s.value, '$.brief.auto_submit') IS NOT NULL
       OR json_type(s.value, '$.brief.require_independent_verify') IS NOT NULL);

CREATE TRIGGER IF NOT EXISTS workflow_definitions_append_only BEFORE UPDATE OF body_json, name, version ON workflow_definitions BEGIN SELECT RAISE(ABORT, 'workflow_definitions is append-only'); END;

COMMIT;
