-- REQ-EXT-VER-1: Update min_version for provider extensions to release 0.4.31
-- Synchronize antigravity, claude, and codex provider_catalog min_version.
BEGIN IMMEDIATE;
UPDATE provider_catalog SET extension = json_patch(COALESCE(NULLIF(extension, ''), '{}'), '{"min_version":"0.4.31"}')
WHERE provider IN ('antigravity', 'claude', 'codex');
DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag) VALUES ('sha256:15b218ee0915b30b61d6567d98682e9b0e73cc6220ac98a513339de2aa4e4928');
COMMIT;
