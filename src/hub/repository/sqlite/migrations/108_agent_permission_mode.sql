-- Per-agent permission mode (REQ-EXT-PERM-2). 'yolo' (the default, and the
-- behaviour every existing agent keeps) launches the provider with the catalog
-- yolo_args; 'ask' launches without them so the provider prompts for each
-- permission (in Heimdall when the provider extension is installed, otherwise
-- in the terminal). run_migrations skips this file when the column exists.
ALTER TABLE agents ADD COLUMN permission_mode TEXT NOT NULL DEFAULT 'yolo' CHECK (permission_mode IN ('yolo', 'ask'));
