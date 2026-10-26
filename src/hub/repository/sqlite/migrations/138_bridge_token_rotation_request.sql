-- A spent refresh token remembers WHICH refresh request spent it (a salted digest
-- of the bridge's X-Heimdall-Refresh-Request-Id), so a retry of that same
-- rotation whose reply was lost can be answered instead of being treated as a
-- stolen-token replay. Additive with a default: a hub that predates this column
-- names its bridge_tokens columns explicitly and starts unchanged on a migrated
-- database (rollback).
ALTER TABLE bridge_tokens ADD COLUMN rotation_request_hash TEXT NOT NULL DEFAULT '';
