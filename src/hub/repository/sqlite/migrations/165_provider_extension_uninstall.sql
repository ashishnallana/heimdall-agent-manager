-- Explicit provider extension uninstall (kind='uninstall'). SQLite cannot alter a
-- CHECK constraint, so the table is rebuilt with the same columns and indexes.
CREATE TABLE provider_extension_commands_v2 (
 command_id TEXT PRIMARY KEY,
 bridge_id TEXT NOT NULL REFERENCES bridges(bridge_id),
 kind TEXT NOT NULL CHECK(kind IN ('bridge_update','discovery','install','uninstall')),
 provider TEXT NOT NULL DEFAULT '',
 parent_id TEXT NOT NULL DEFAULT '',
 state TEXT NOT NULL,
 message TEXT NOT NULL DEFAULT '',
 target_version TEXT NOT NULL DEFAULT '',
 target_commit TEXT NOT NULL DEFAULT '',
 source_version TEXT NOT NULL DEFAULT '',
 source_commit TEXT NOT NULL DEFAULT '',
 update_extensions INTEGER NOT NULL DEFAULT 0,
 progress INTEGER NOT NULL DEFAULT 0
);
INSERT INTO provider_extension_commands_v2
 (command_id,bridge_id,kind,provider,parent_id,state,message,target_version,target_commit,source_version,source_commit,update_extensions,progress)
 SELECT command_id,bridge_id,kind,provider,parent_id,state,message,target_version,target_commit,source_version,source_commit,update_extensions,progress
 FROM provider_extension_commands;
DROP TABLE provider_extension_commands;
ALTER TABLE provider_extension_commands_v2 RENAME TO provider_extension_commands;
CREATE INDEX IF NOT EXISTS provider_extension_commands_bridge ON provider_extension_commands(bridge_id);
CREATE UNIQUE INDEX IF NOT EXISTS provider_extension_commands_followup
 ON provider_extension_commands(parent_id, kind, provider) WHERE parent_id <> '';
