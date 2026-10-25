-- Hub-issued user API tokens (hut_) were removed: users authenticate only with
-- OIDC (bearer or the Hub browser session). No other table references
-- user_api_tokens, so it is dropped with its trigger and index.
DROP TRIGGER IF EXISTS user_api_tokens_owner_immutable;
DROP INDEX IF EXISTS idx_user_api_tokens_token_hash;
DROP TABLE IF EXISTS user_api_tokens;
