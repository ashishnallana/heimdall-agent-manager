-- Refresh retry grace, hardened (review of migration 138):
--   first_used_at   on an ACCESS row: when it first authenticated anything. A used
--                   descendant access token proves the reply carrying it was
--                   delivered, so the spent refresh token's retry grace ends.
--   regrant_claim   on a SPENT refresh row: compare-and-set claim taken by every
--                   graced re-grant, so two concurrent retries cannot both mint a
--                   live generation (the loser takes the theft path).
-- Additive with defaults: an older hub names its columns explicitly and starts
-- unchanged on a migrated database (rollback).
ALTER TABLE bridge_tokens ADD COLUMN first_used_at TEXT NOT NULL DEFAULT '';
ALTER TABLE bridge_tokens ADD COLUMN regrant_claim TEXT NOT NULL DEFAULT '';
