-- REQ-EXT-PERM-2: permission_mode 'ask' omits the catalog yolo_args, but a
-- provider launched with no explicit mode falls back to the user's configured
-- default (Claude's may be "auto", which auto-approves and never raises a
-- PermissionRequest). ask_args is the data-driven recipe appended in place of
-- yolo_args for 'ask'; '[]' means the provider prompts by default.
-- Atomic, so the runner's guard on the column means the whole file applied.
BEGIN IMMEDIATE;

ALTER TABLE provider_catalog ADD COLUMN ask_args TEXT NOT NULL DEFAULT '[]';

UPDATE provider_catalog SET ask_args = '["--permission-mode","default"]'
WHERE provider = 'claude';

-- The canonical catalog body now carries "ask_args"; keep the audit etag true.
DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag)
VALUES ('sha256:0298fe6bdbfea589802947303c1089ed0c05ee0b10e4d9ec0d6caf5e041f5c5a');

COMMIT;
