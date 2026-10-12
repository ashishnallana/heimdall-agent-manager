-- The original Copilot recipe could not launch: with no prompt flag the
-- starter prompt became a positional argument, which Copilot CLI rejects as an
-- unrecognized subcommand. Verified against Copilot CLI 1.0.91:
--   -i <prompt>   start interactive mode and run the starter prompt
--   --yolo        allow all tools, paths, and URLs (no permission prompts)
--   --model <id>  model selection
-- Project skills load from .github/skills, .agents/skills, or .claude/skills
-- (not .copilot/skills); AGENTS.md is read as repository instructions.
-- Startup: a fresh folder shows "Do you trust the files in this folder?" with
-- "1. Yes" preselected; expired credentials print an authorization error.
UPDATE provider_catalog
SET yolo_args = '["--yolo"]',
    prompt_args = '["-i"]',
    skill_dir = '.agents/skills',
    startup_detection = '{"enabled":true,"startup_probe_seconds":20,"capture_interval_ms":500,"blocked_patterns":["Authorization error. Your credentials may be expired or invalid.","Run /login to sign in"],"auto_enter_patterns":["Do you trust the files in this folder?"],"auto_enter_pre_keys":[""],"startup_unknown_is_blocked":false,"sanitized_reason_mapping":["login=GitHub Copilot authentication is required","login=GitHub Copilot authentication is required"]}'
WHERE provider = 'copilot';

-- claude-opus-4.6 and gpt-4o are not selectable in Copilot CLI 1.0.91. Replace
-- the model set with ids from `copilot help config`.
DELETE FROM provider_models WHERE provider = 'copilot';

INSERT INTO provider_models (provider, model_id, label, state, rank) VALUES
  ('copilot', 'claude-sonnet-5.5', 'Claude Sonnet 5.5', 'active', 10),
  ('copilot', 'claude-opus-5.5', 'Claude Opus 5.5', 'active', 20),
  ('copilot', 'gpt-6.1-sol', 'GPT-6.1-Sol', 'active', 30),
  ('copilot', 'gemini-3.8-flash', 'Gemini 3.8 Flash', 'active', 40);

DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag)
VALUES ('sha256:90e8d86916c54a0b8919cb2c428213c2811bf88d9c3d500083e680047ad36a68');
