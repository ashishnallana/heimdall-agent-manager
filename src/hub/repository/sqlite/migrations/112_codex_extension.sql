-- Codex0.162.0 native installed-plugin shape, independent of hook trust.
-- Restrict inventory to this marketplace: authenticated remote inventory can
-- exceed the bounded probe deadline even when the local package is installed.
-- Merge optional extension keys instead of overwriting startup/load metadata.
BEGIN IMMEDIATE;
UPDATE provider_catalog SET extension = json_patch(COALESCE(NULLIF(extension, ''), '{}'), '{"detect_argv":["plugin","list","--marketplace","heimdall-codex","--json"],"detect_collection":"installed","detect_id_key":"pluginId","detect_version_key":"version","detect_enabled_key":"enabled","plugin_id":"heimdall@heimdall-codex","min_version":"0.1.0","install_hint":"codex plugin marketplace add <repo>/extensions && codex plugin add heimdall@heimdall-codex; then review hooks with /hooks","capabilities":["activity","subagents","permissions","file_edits","session_id"]}')
WHERE provider = 'codex';
DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag) VALUES ('sha256:1daf61a29fbb201b189af3a46c73923df8a91e7930a6e3b2f7589fe2e5ee23e6');
COMMIT;
