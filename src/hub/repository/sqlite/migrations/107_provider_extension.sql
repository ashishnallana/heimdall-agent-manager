-- REQ-EXT-DET-1: a provider may ship a Heimdall extension (Claude Code plugin,
-- ...). The Hub-owned catalog describes how a Bridge detects it; NULL means the
-- provider has no extension (reported as 'unsupported'). The Bridge measures the
-- result during provider discovery and the Hub stores it next to the binary probe.
-- Atomic, so the runner's guard on the last column means the whole file applied.
BEGIN IMMEDIATE;

ALTER TABLE provider_catalog ADD COLUMN extension TEXT;

UPDATE provider_catalog SET extension =
  '{"detect_argv":["plugin","list","--json"],"plugin_id":"heimdall@heimdall","min_version":"0.1.0","install_hint":"claude plugin marketplace add <repo>/extensions && claude plugin install heimdall@heimdall","capabilities":["activity","subagents","permissions","file_edits","session_id"]}'
WHERE provider = 'claude';

-- '' = never reported (a Bridge older than this migration, or no probe yet).
ALTER TABLE bridge_provider_status ADD COLUMN extension_state TEXT NOT NULL DEFAULT ''
  CHECK (extension_state IN ('', 'present', 'disabled', 'outdated', 'absent', 'error', 'unsupported'));
ALTER TABLE bridge_provider_status ADD COLUMN extension_version TEXT NOT NULL DEFAULT '';
ALTER TABLE bridge_provider_status ADD COLUMN extension_checked_at TEXT NOT NULL DEFAULT '';

-- The canonical catalog body now carries "extension"; keep the audit etag true.
DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag)
VALUES ('sha256:4568931161047aaf35da19e5e55a1bdcf9658b1f5432cbb1a6228acfa13ebcba');

COMMIT;
