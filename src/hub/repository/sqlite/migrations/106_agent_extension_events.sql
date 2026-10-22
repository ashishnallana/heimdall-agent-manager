-- Provider extension interface (ham.ext.v1): per-instance provider session and
-- extension identity, plus the ingested extension event log. The extension
-- columns are written ONLY by the extension ingest path (never by the general
-- instance upsert), so a status write can never clobber them.
ALTER TABLE agent_instances ADD COLUMN provider_session_id TEXT NOT NULL DEFAULT '';
ALTER TABLE agent_instances ADD COLUMN provider_transcript_path TEXT NOT NULL DEFAULT '';
ALTER TABLE agent_instances ADD COLUMN extension_provider TEXT NOT NULL DEFAULT '';
ALTER TABLE agent_instances ADD COLUMN extension_version TEXT NOT NULL DEFAULT '';
ALTER TABLE agent_instances ADD COLUMN extension_capabilities TEXT NOT NULL DEFAULT '[]';
ALTER TABLE agent_instances ADD COLUMN extension_last_seen_at TEXT NOT NULL DEFAULT '';

-- seq is hub-assigned and monotonic per instance. Retention: each insert batch
-- trims the instance to its newest AGENT_EXTENSION_EVENTS_KEEP rows.
CREATE TABLE agent_extension_events (
    id INTEGER PRIMARY KEY,
    instance_id TEXT NOT NULL,
    seq INTEGER NOT NULL,
    event TEXT NOT NULL,
    ts TEXT NOT NULL DEFAULT '',
    session_id TEXT NOT NULL DEFAULT '',
    agent_id TEXT NOT NULL DEFAULT '',
    agent_type TEXT NOT NULL DEFAULT '',
    tool_name TEXT NOT NULL DEFAULT '',
    tool_use_id TEXT NOT NULL DEFAULT '',
    file_path TEXT NOT NULL DEFAULT '',
    payload TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX agent_extension_events_instance_seq ON agent_extension_events(instance_id, seq);
CREATE INDEX agent_extension_events_instance_agent ON agent_extension_events(instance_id, agent_id, seq);
