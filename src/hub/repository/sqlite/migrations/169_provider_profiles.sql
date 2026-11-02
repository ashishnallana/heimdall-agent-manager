BEGIN IMMEDIATE;
-- Registry stores only metadata; private configuration stays on the bridge.
CREATE TABLE bridge_provider_profiles (
 bridge_id TEXT NOT NULL REFERENCES bridges(bridge_id) ON DELETE CASCADE,
 profile_id TEXT NOT NULL, provider TEXT NOT NULL REFERENCES provider_catalog(provider),
 label_enc TEXT NOT NULL DEFAULT '', accent TEXT NOT NULL DEFAULT '',
 enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
 has_config_dir INTEGER NOT NULL DEFAULT 0, has_home_path INTEGER NOT NULL DEFAULT 0,
 has_shadow_home_path INTEGER NOT NULL DEFAULT 0, has_binary INTEGER NOT NULL DEFAULT 0,
 env_count INTEGER NOT NULL DEFAULT 0, args_count INTEGER NOT NULL DEFAULT 0,
 custom_models_count INTEGER NOT NULL DEFAULT 0,
 state TEXT NOT NULL CHECK(state IN ('ok','slug_clash','missing')),
 created_at INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(bridge_id,profile_id)
);
CREATE TABLE bridge_provider_status_next (
 bridge_id TEXT NOT NULL, profile_id TEXT NOT NULL, provider TEXT NOT NULL,
 binary_path TEXT NOT NULL DEFAULT '', version_text TEXT NOT NULL DEFAULT '',
 state TEXT NOT NULL CHECK(state IN ('absent','present','disabled','error')),
 checked_at TEXT NOT NULL, extension_state TEXT NOT NULL DEFAULT '',
 extension_version TEXT NOT NULL DEFAULT '', extension_checked_at TEXT NOT NULL DEFAULT '',
 PRIMARY KEY(bridge_id,profile_id)
);
INSERT INTO bridge_provider_status_next SELECT bridge_id,provider,provider,binary_path,version_text,state,checked_at,extension_state,extension_version,extension_checked_at FROM bridge_provider_status;
DROP TABLE bridge_provider_status;
ALTER TABLE bridge_provider_status_next RENAME TO bridge_provider_status;
CREATE TABLE bridge_provider_settings_next (
 bridge_id TEXT NOT NULL, profile_id TEXT NOT NULL, provider TEXT NOT NULL REFERENCES provider_catalog(provider),
 enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN (0,1)), updated_at TEXT NOT NULL,
 PRIMARY KEY(bridge_id,profile_id)
);
INSERT INTO bridge_provider_settings_next SELECT bridge_id,provider,provider,enabled,updated_at FROM bridge_provider_settings;
DROP TABLE bridge_provider_settings;
ALTER TABLE bridge_provider_settings_next RENAME TO bridge_provider_settings;
CREATE TABLE bridge_provider_models_next (
 bridge_id TEXT NOT NULL REFERENCES bridges(bridge_id) ON DELETE CASCADE,
 profile_id TEXT NOT NULL, provider TEXT NOT NULL REFERENCES provider_catalog(provider),
 binary_path TEXT NOT NULL DEFAULT '', version_text TEXT NOT NULL DEFAULT '',
 has_snapshot INTEGER NOT NULL DEFAULT 0, models_json TEXT NOT NULL DEFAULT '[]',
 models_source TEXT NOT NULL DEFAULT '', models_checked_at TEXT NOT NULL DEFAULT '',
 models_attempted_at TEXT NOT NULL DEFAULT '', models_state TEXT NOT NULL DEFAULT '',
 custom_models_json TEXT NOT NULL DEFAULT '[]',
 PRIMARY KEY(bridge_id,profile_id)
);
INSERT INTO bridge_provider_models_next SELECT bridge_id,provider,provider,binary_path,version_text,has_snapshot,models_json,models_source,models_checked_at,models_attempted_at,models_state,'[]' FROM bridge_provider_models;
DROP TABLE bridge_provider_models;
ALTER TABLE bridge_provider_models_next RENAME TO bridge_provider_models;
ALTER TABLE agent_instances ADD COLUMN provider_profile TEXT NOT NULL DEFAULT '';
UPDATE agent_instances SET provider_profile=provider;
ALTER TABLE task_chain_fleets ADD COLUMN provider_profile TEXT NOT NULL DEFAULT '';
UPDATE task_chain_fleets SET provider_profile=provider;

ALTER TABLE provider_extension_commands ADD COLUMN profile_id TEXT NOT NULL DEFAULT '';
UPDATE provider_extension_commands SET profile_id=provider WHERE kind IN ('install','uninstall');
DROP INDEX IF EXISTS provider_extension_commands_followup;
CREATE UNIQUE INDEX provider_extension_commands_followup
 ON provider_extension_commands(parent_id,kind,provider,profile_id) WHERE parent_id<>'';

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
      AND provider_profile = COALESCE(NULLIF(json_extract(NEW.payload_json, '$.source.provider_profile'),''),json_extract(NEW.payload_json, '$.source.provider'))
      AND model = json_extract(NEW.payload_json, '$.source.model')
  ) THEN RAISE(ABORT, 'configuration changed before move commit') END;
  UPDATE agent_instances SET
    bridge_id = json_extract(NEW.payload_json, '$.destination.bridge_id'),
    project_id = json_extract(NEW.payload_json, '$.destination.project_id'),
    project_path = json_extract(NEW.payload_json, '$.destination.project_path'),
    provider = json_extract(NEW.payload_json, '$.destination.provider'),
    provider_profile = COALESCE(NULLIF(json_extract(NEW.payload_json, '$.destination.provider_profile'),''),json_extract(NEW.payload_json, '$.destination.provider')),
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

ALTER TABLE task_leases ADD COLUMN provider_profile TEXT NOT NULL DEFAULT '';
UPDATE task_leases SET provider_profile=provider;

CREATE INDEX idx_bridge_provider_profiles_driver ON bridge_provider_profiles(bridge_id,provider);
COMMIT;
