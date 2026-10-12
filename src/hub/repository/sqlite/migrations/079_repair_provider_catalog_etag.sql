-- Migration 073 added the current Claude models but left the previous
-- catalog hash in provider_catalog_meta. Runtime code derives the etag from
-- the canonical body, so this row is audit metadata only; repair it for
-- existing installations and for operators inspecting the database directly
-- (same shape as 068).
DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag)
VALUES ('sha256:4053472e702bb0e34d2e7e74e12155d5d8a04c5cc0085c382ada59c5e2f0e136');
