CREATE TABLE IF NOT EXISTS bridge_provider_models (
 bridge_id TEXT NOT NULL REFERENCES bridges(bridge_id) ON DELETE CASCADE,
 provider TEXT NOT NULL REFERENCES provider_catalog(provider),
 binary_path TEXT NOT NULL DEFAULT '', version_text TEXT NOT NULL DEFAULT '',
 has_snapshot INTEGER NOT NULL DEFAULT 0,
 models_json TEXT NOT NULL DEFAULT '[]', models_source TEXT NOT NULL DEFAULT '',
 models_checked_at TEXT NOT NULL DEFAULT '', models_attempted_at TEXT NOT NULL DEFAULT '',
 models_state TEXT NOT NULL DEFAULT '',
 PRIMARY KEY (bridge_id, provider)
);
