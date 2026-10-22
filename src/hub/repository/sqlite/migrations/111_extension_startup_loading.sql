-- REQ-START-2: the catalog owns provider-specific argv knowledge. A directory
-- loader only predicts the Heimdall extension when its path names this extension,
-- rather than some unrelated plugin. Older bridges ignore the optional fields.
BEGIN IMMEDIATE;

UPDATE provider_catalog
SET extension = json_set(extension,
  '$.load_args', json('["--plugin-dir"]'),
  '$.load_path_suffix', 'extensions/claude')
WHERE provider = 'claude' AND json_valid(extension);

DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag)
VALUES ('sha256:01e898e89b226a56e8ab4a249dadda1c71ca83ae8ed199b42855cd501421df26');

COMMIT;
