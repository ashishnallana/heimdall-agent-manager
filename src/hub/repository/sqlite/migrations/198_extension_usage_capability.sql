-- Advertise the `usage` capability for the claude and codex extensions (their
-- adapters report provider token usage). Antigravity has no usage source and
-- keeps its original capability list.
BEGIN IMMEDIATE;
UPDATE provider_catalog SET extension = json_patch(COALESCE(NULLIF(extension, ''), '{}'), '{"capabilities":["activity","subagents","permissions","file_edits","session_id","usage"]}')
WHERE provider IN ('claude', 'codex');
DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag) VALUES ('sha256:e0f29408c770fb7a38c509de88c6db09fa2863b44a129cdf0e11f4c5526d67fb');
COMMIT;
