-- The original Antigravity models used display labels as ids, and Gemini 3.5
-- Flash is no longer offered. Replace the model set with the canonical ids from
-- `agy models` (agy 1.2.16); `agy --model` accepts these ids (verified).
DELETE FROM provider_models WHERE provider = 'antigravity';

INSERT INTO provider_models (provider, model_id, label, state, rank) VALUES
  ('antigravity', 'gemini-3.8-flash-high', 'Gemini 3.8 Flash (High)', 'active', 10),
  ('antigravity', 'gemini-3.8-flash-medium', 'Gemini 3.8 Flash (Medium)', 'active', 20),
  ('antigravity', 'gemini-3.8-flash-low', 'Gemini 3.8 Flash (Low)', 'active', 30),
  ('antigravity', 'gemini-3.7-flash-high', 'Gemini 3.7 Flash (High)', 'active', 40),
  ('antigravity', 'gemini-3.7-flash-medium', 'Gemini 3.7 Flash (Medium)', 'active', 50),
  ('antigravity', 'gemini-3.7-flash-low', 'Gemini 3.7 Flash (Low)', 'active', 60),
  ('antigravity', 'gemini-3.6-flash-high', 'Gemini 3.6 Flash (High)', 'active', 70),
  ('antigravity', 'gemini-3.6-flash-medium', 'Gemini 3.6 Flash (Medium)', 'active', 80),
  ('antigravity', 'gemini-3.6-flash-low', 'Gemini 3.6 Flash (Low)', 'active', 90),
  ('antigravity', 'gemini-3.1-pro-high', 'Gemini 3.1 Pro (High)', 'active', 100),
  ('antigravity', 'gemini-3.1-pro-low', 'Gemini 3.1 Pro (Low)', 'active', 110),
  ('antigravity', 'claude-opus-5-5-low', 'Claude Opus 5.5 (Low)', 'active', 120),
  ('antigravity', 'claude-opus-5-5-medium', 'Claude Opus 5.5 (Medium)', 'active', 130),
  ('antigravity', 'claude-opus-5-5-high', 'Claude Opus 5.5 (High)', 'active', 140),
  ('antigravity', 'claude-sonnet-5-5-low', 'Claude Sonnet 5.5 (Low)', 'active', 150),
  ('antigravity', 'claude-sonnet-5-5-medium', 'Claude Sonnet 5.5 (Medium)', 'active', 160),
  ('antigravity', 'claude-sonnet-5-5-high', 'Claude Sonnet 5.5 (High)', 'active', 170),
  ('antigravity', 'gpt-oss-120b-medium', 'GPT-OSS 120B (Medium)', 'active', 180);

DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag)
VALUES ('sha256:c975a89dda11336b2cf059d3d7f2499b11bf4426f58d8ac2cd8fd0eb130c63dd');
