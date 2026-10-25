-- Hub-issued user API tokens (hut_) were removed: users authenticate only with
-- OIDC (bearer or the Hub browser session). The rows are deleted so no token
-- works even if an older binary is rolled back onto this database.
--
-- The TABLE is deliberately kept for one release: older binaries (e.g. the
-- native-v0445 lineage) run `upgrade_user_api_tokens_schema` after every
-- migration pass and ALTER this table, so dropping it would make a rollback
-- crash-loop. Drop it in a later release (docs/plans/oidc-only-auth.md).
DELETE FROM user_api_tokens;
