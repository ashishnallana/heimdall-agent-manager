CREATE TABLE IF NOT EXISTS provider_extension_commands (
 command_id TEXT PRIMARY KEY,
 bridge_id TEXT NOT NULL REFERENCES bridges(bridge_id),
 kind TEXT NOT NULL CHECK(kind IN ('bridge_update','discovery','install')),
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
CREATE INDEX IF NOT EXISTS provider_extension_commands_bridge ON provider_extension_commands(bridge_id);
CREATE UNIQUE INDEX IF NOT EXISTS provider_extension_commands_followup
 ON provider_extension_commands(parent_id, kind, provider) WHERE parent_id <> '';
