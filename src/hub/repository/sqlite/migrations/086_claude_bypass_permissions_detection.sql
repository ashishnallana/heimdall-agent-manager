-- Claude launched with --dangerously-skip-permissions shows a one-time
-- "WARNING: Claude Code running in Bypass Permissions mode" confirm whose
-- default selection is "1. No, exit". Heimdall launches claude that way on
-- purpose, so accept it: Down moves to "2. Yes, I accept", then Enter.
-- Earlier theme-chooser and folder-trust screens stay supported (same as 063).
UPDATE provider_catalog
SET startup_detection = '{"enabled":true,"startup_probe_seconds":20,"capture_interval_ms":500,"blocked_patterns":["Select login method:","Not logged in. Run claude auth login to authenticate.","Please run /login"],"auto_enter_patterns":["Choose the text style that looks best with your terminal","Yes, I trust this folder","Bypass Permissions mode"],"auto_enter_pre_keys":["Up","Up","Down"],"startup_unknown_is_blocked":false,"sanitized_reason_mapping":["login=Claude Code authentication is required","login=Claude Code authentication is required","login=Claude Code authentication is required"]}'
WHERE provider = 'claude';

DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag)
VALUES ('sha256:e47c8feab736c5a682ac035f75b2abfe0d9572d44ba5d3ecc446c8594c5802e0');
