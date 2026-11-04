-- Advertise the `usage` capability for the claude and codex extensions (their
-- adapters report provider token usage). Antigravity has no usage source and
-- keeps its original capability list.
BEGIN IMMEDIATE;
UPDATE provider_catalog SET extension = json_patch(COALESCE(NULLIF(extension, ''), '{}'), '{"capabilities":["activity","subagents","permissions","file_edits","session_id","usage"]}')
WHERE provider IN ('claude', 'codex');
DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag) VALUES ('sha256:0b65245d785d5b63e6ea9a874500d83d25f23ef136a1b274628f899f67d6866c');
COMMIT;
