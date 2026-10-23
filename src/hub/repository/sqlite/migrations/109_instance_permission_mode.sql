-- Per-instance permission mode override (composer "Bypass permissions" toggle).
-- '' (the default, and what every existing instance keeps) inherits the durable
-- agent's agents.permission_mode (108); 'yolo' / 'ask' override it for this
-- instance only. A reconfiguration carries the destination value in
-- $.destination.permission_mode and the move commit applies it atomically with
-- the rest of the destination, so a permission-only change restarts through the
-- same operation machinery. Older payloads without the key keep the stored value.
-- run_migrations skips this file when the commit trigger already mentions
-- permission_mode (the LAST statement below).
BEGIN;
ALTER TABLE agent_instances ADD COLUMN permission_mode TEXT NOT NULL DEFAULT '' CHECK (permission_mode IN ('', 'yolo', 'ask'));
DROP TRIGGER IF EXISTS instance_reconfiguration_commit;
CREATE TRIGGER instance_reconfiguration_commit
BEFORE UPDATE OF phase ON instance_reconfigurations
WHEN NEW.phase = 'launching' AND OLD.phase = 'source_stopped'
BEGIN
  SELECT CASE WHEN json_extract(NEW.payload_json, '$.source_stopped') != 1
    OR json_extract(NEW.payload_json, '$.destination_committed') != 1
    THEN RAISE(ABORT, 'source termination must be confirmed') END;
  SELECT CASE WHEN NOT EXISTS (
    SELECT 1 FROM agent_instances WHERE agent_instance_id = NEW.agent_instance_id
      AND owner_user_id = NEW.owner_user_id
      AND configuration_revision = json_extract(NEW.payload_json, '$.expected_revision')
      AND bridge_id = json_extract(NEW.payload_json, '$.source.bridge_id')
      AND project_id = json_extract(NEW.payload_json, '$.source.project_id')
      AND provider = json_extract(NEW.payload_json, '$.source.provider')
      AND model = json_extract(NEW.payload_json, '$.source.model')
  ) THEN RAISE(ABORT, 'configuration changed before move commit') END;
  UPDATE agent_instances SET
    bridge_id = json_extract(NEW.payload_json, '$.destination.bridge_id'),
    project_id = json_extract(NEW.payload_json, '$.destination.project_id'),
    project_path = json_extract(NEW.payload_json, '$.destination.project_path'),
    provider = json_extract(NEW.payload_json, '$.destination.provider'),
    model = json_extract(NEW.payload_json, '$.destination.model'),
    permission_mode = COALESCE(json_extract(NEW.payload_json, '$.destination.permission_mode'), permission_mode),
    configuration_revision = configuration_revision + 1,
    launch_epoch = json_extract(NEW.payload_json, '$.launch_epoch'),
    runtime_status = 'launching', startup_status = 'starting', activity_status = 'unknown',
    run_count = run_count + 1, last_applied_seq = 0,
    started_at = NEW.updated_at, stopped_at = '', updated_at = NEW.updated_at,
    last_seen_at = NEW.updated_at
  WHERE agent_instance_id = NEW.agent_instance_id AND owner_user_id = NEW.owner_user_id;
  UPDATE chat_conversations SET project_id = json_extract(NEW.payload_json, '$.destination.project_id'),
    updated_at = NEW.updated_at
  WHERE conversation_id = json_extract(NEW.payload_json, '$.conversation_id')
    AND agent_instance_id = NEW.agent_instance_id AND owner_user_id = NEW.owner_user_id;
END;
COMMIT;
