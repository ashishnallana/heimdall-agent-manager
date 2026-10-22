-- Codex0.162.0 native installed-plugin shape, independent of hook trust.
-- Merge optional extension keys instead of overwriting startup/load metadata.
BEGIN IMMEDIATE;
UPDATE provider_catalog SET extension = json_patch(COALESCE(NULLIF(extension, ''), '{}'), '{"detect_argv":["plugin","list","--json"],"detect_collection":"installed","detect_id_key":"pluginId","detect_version_key":"version","detect_enabled_key":"enabled","plugin_id":"heimdall@heimdall-codex","min_version":"0.1.0","install_hint":"codex plugin marketplace add <repo>/extensions && codex plugin add heimdall@heimdall-codex; then review hooks with /hooks","capabilities":["activity","subagents","permissions","file_edits","session_id"]}')
WHERE provider = 'codex';
DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag) VALUES ('sha256:e3a0e535b27639c97c60cf9f25baea587863a4cdfbc71f2feb844da9e164d127');
COMMIT;
