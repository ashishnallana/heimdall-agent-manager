-- REQ-EXT-AGY-1: Register Antigravity provider extension in the Hub catalog.
-- Data-driven plugin list probe with installed collection, name/version/enabled keys,
-- load_args for --add-dir workspace plugin loading, and full capability profile.
BEGIN IMMEDIATE;
UPDATE provider_catalog SET extension = json_patch(COALESCE(NULLIF(extension, ''), '{}'), '{"detect_argv":["plugin","list","--json"],"detect_collection":"installed","detect_id_key":"name","detect_version_key":"version","detect_enabled_key":"enabled","plugin_id":"heimdall","min_version":"0.1.0","install_hint":"agy plugin install <repo>/extensions/antigravity","capabilities":["activity","subagents","permissions","file_edits","session_id"],"load_args":["--add-dir"],"load_path_suffix":"extensions/antigravity"}')
WHERE provider = 'antigravity';
DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag) VALUES ('sha256:91ac29d0460206fd696b2aa7744dfb9951174046313413227d4f7d7a42fe49d6');
COMMIT;
