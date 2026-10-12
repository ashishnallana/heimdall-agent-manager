-- Add the Pi coding agent (pi 1.1.0). Verified with live tmux launches:
--   --approve       trust project-local files so .agents/skills loads without
--                   the project-trust prompt (Pi never asks per tool call)
--   --model <id>    "provider/model" ids from `pi --list-models`
--   -- <prompt>     the starter prompt is a positional message; "--" ends
--                   option parsing
-- AGENTS.md loads as a context file regardless of trust. With no subscription
-- configured Pi reports "No API key found for <provider>" plus a /login hint;
-- an expired OAuth login reports "OAuth refresh failed for <provider>". Both
-- block startup instead of looking ready.
-- Requires Bridge >= 0.3.40: older Bridges accept exactly four providers and
-- keep their cached catalog when the Hub adds one.
INSERT INTO provider_catalog (
  provider, display_name, icon_url, binary, base_args, yolo_args, model_flag,
  prompt_args, prompt_delivery, starter_prompt, bootstrap_file, skill_dir,
  startup_detection, activity_detection, state, rank
) VALUES (
  'pi', 'Pi', '/api/v1/providers/pi/icon', 'pi', '[]', '["--approve"]', '--model', '["--"]', 'flag-injection',
  'First, run: {ctl_bin} agent start-success. Then read AGENTS.md for context.',
  'AGENTS.md', '.agents/skills',
  '{"enabled":true,"startup_probe_seconds":20,"capture_interval_ms":500,"blocked_patterns":["No API key found for","Use /login to log into a provider","OAuth refresh failed for"],"auto_enter_patterns":[],"auto_enter_pre_keys":[],"startup_unknown_is_blocked":false,"sanitized_reason_mapping":["login=Pi provider authentication is required","login=Pi provider authentication is required","login=Pi provider authentication is required"]}',
  '{"enabled":true,"sample_line_count":20,"ignore_bottom_lines":0,"check_interval_seconds":15,"min_gap_ms":100,"max_gap_ms":500}', 'active', 50
) ON CONFLICT(provider) DO NOTHING;

INSERT INTO provider_models (provider, model_id, label, state, rank) VALUES
  ('pi', 'anthropic/claude-opus-5-5', 'Claude Opus 5.5 (Anthropic)', 'active', 10),
  ('pi', 'anthropic/claude-sonnet-5-5', 'Claude Sonnet 5.5 (Anthropic)', 'active', 20),
  ('pi', 'anthropic/claude-haiku-5-5', 'Claude Haiku 5.5 (Anthropic)', 'active', 30),
  ('pi', 'openai-codex/gpt-6.1-sol', 'GPT-6.1-Sol (OpenAI Codex)', 'active', 40),
  ('pi', 'openai-codex/gpt-6-sol', 'GPT-6-Sol (OpenAI Codex)', 'active', 50),
  ('pi', 'openai-codex/gpt-5.6-sol', 'GPT-5.6-Sol (OpenAI Codex)', 'active', 60),
  ('pi', 'openai-codex/gpt-5.6-luna', 'GPT-5.6-Luna (OpenAI Codex)', 'active', 70),
  ('pi', 'zai/glm-5.3', 'GLM-5.3 (Z.ai)', 'active', 80)
ON CONFLICT(provider, model_id) DO NOTHING;

INSERT INTO provider_icons (provider, content_type, content) VALUES
  ('pi', 'image/svg+xml', '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64"><rect width="64" height="64" rx="15" fill="#111827"/><text x="32" y="43" text-anchor="middle" font-family="serif" font-size="34" font-weight="700" fill="#fff">π</text></svg>')
ON CONFLICT(provider) DO NOTHING;

DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag)
VALUES ('sha256:0e08e81c1f4211e6d433c0b719bf65273a9a320c5a982912e93525a5884ee837');
