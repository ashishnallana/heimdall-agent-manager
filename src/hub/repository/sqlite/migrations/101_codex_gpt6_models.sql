-- Codex 0.162 advertises the GPT-6 family (~/.codex/models_cache.json, listed
-- models in priority order: gpt-6.1-sol, gpt-6-astra, gpt-6-sol, gpt-6-luna).
-- Pi 1.1 exposes the same ids under openai-codex/ (`pi --list-models`).
-- Keep the GPT-5.6 rows for historical references but retire them so new
-- launches select current IDs; they rank after every active model.
UPDATE provider_models SET state = 'deprecated', rank = rank + 100
WHERE state = 'active'
  AND ((provider = 'codex' AND model_id IN ('gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna'))
    OR (provider = 'pi' AND model_id IN ('openai-codex/gpt-5.6-sol', 'openai-codex/gpt-5.6-luna')));

INSERT INTO provider_models (provider, model_id, label, state, rank) VALUES
  ('codex', 'gpt-6.1-sol', 'GPT-6.1-Sol', 'active', 10),
  ('codex', 'gpt-6-astra', 'GPT-6-Astra', 'active', 20),
  ('codex', 'gpt-6-sol', 'GPT-6-Sol', 'active', 30),
  ('codex', 'gpt-6-luna', 'GPT-6-Luna', 'active', 40),
  ('pi', 'openai-codex/gpt-6.1-sol', 'GPT-6.1-Sol (OpenAI Codex)', 'active', 40),
  ('pi', 'openai-codex/gpt-6-astra', 'GPT-6-Astra (OpenAI Codex)', 'active', 50),
  ('pi', 'openai-codex/gpt-6-sol', 'GPT-6-Sol (OpenAI Codex)', 'active', 60),
  ('pi', 'openai-codex/gpt-6-luna', 'GPT-6-Luna (OpenAI Codex)', 'active', 70)
ON CONFLICT(provider, model_id) DO UPDATE SET
  label = excluded.label, state = excluded.state, rank = excluded.rank;

DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag)
VALUES ('sha256:6b0a1c8b34186ddead79b0c1676fb2618c5f54aa39ca1d02d40630e20e1adb85');
