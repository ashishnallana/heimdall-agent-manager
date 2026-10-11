package app

import "core:strings"

Hub_Config :: struct {
	paddle_environment: string,
	paddle_api_key: string,
	paddle_client_token: string,
	paddle_webhook_secret: string,
	paddle_hobbyist_price_id: string,
	paddle_past_due_grace_seconds: int,
	runtime_max_live_bridges: int,
	runtime_max_live_bridges_per_owner: int,
	runtime_max_active_instances: int,
	runtime_max_active_instances_per_owner: int,
	runtime_terminal_entries_per_bridge: int,
	runtime_terminal_retention_seconds: int,
	bind_host: string,
	port: int,
	database_path: string,
	migrations_dir: string,
	username_header: string,
	display_name_header: string,
	email_header: string,
	trusted_proxy_cidrs: []string,
	auto_provision_users: bool,
	login_url: string,
	logout_url: string,
	// Browser origin the Hub returns as `verification_uri` from device authorize.
	// Empty is deliberately invalid for bridge enrollment: the bridge refuses to
	// guess a UI hostname from the Hub API hostname.
	ui_origin: string,
	// Browser-isolated origin used exclusively for shell previews. Empty keeps
	// the legacy same-origin preview path as the canonical URL.
	preview_origin: string,
	preview_legacy_path: bool,
	device_auth_expires_in: int,
	device_auth_interval: int,
	device_auth_rate_limit: int,
	device_auth_rate_window: int,
	// Background stale-instance reaper cadence (seconds). A dedicated hub thread
	// sweeps agent instances whose bridge stopped heartbeating and flips them to
	// 'unreachable', INDEPENDENT of inbound bridge traffic (self-heals a fully-dead
	// bridge, a lost WS close, or a hub restart with a persisted DB). <=0 falls back
	// to the default; it never blocks startup.
	reaper_interval_seconds: int,
	// Cooldown (seconds) between activity-gated title-nudges for the same
	// conversation (REQ-4,5,6). Default 3600 (1h). <=0 falls back to the engine
	// default DEFAULT_TITLE_NUDGE_COOLDOWN_SECONDS.
	title_nudge_cooldown_seconds: int,
	// VAPID keypair for Web Push (WP-STORE-2). Both keys are unpadded base64url;
	// the public key is the uncompressed P-256 point served to clients, the
	// private key is the 32-byte scalar used to sign VAPID JWTs. The private key
	// is a SECRET and MUST NEVER be logged. When either is empty, push sending is
	// disabled (the endpoints still work) — see vapid_is_configured.
	vapid_public_key: string,
	vapid_private_key: string,
	// VAPID JWT `sub` claim — a contact URI (mailto:/https:) per RFC 8292.
	vapid_subject: string,
	// Public origin (scheme://host[:port]) of the deployed PWA, used to build the
	// absolute `href` in Web Push payloads that the service worker opens on click
	// (WP-SEND). The Hub serves only /api/v1; the SW/manifest are same-origin here.
	public_app_origin: string,
}

// vapid_is_configured reports whether a usable VAPID keypair is present. Push
// send is gated on this; when false, subscription endpoints still function.
vapid_is_configured :: proc(config: Hub_Config) -> bool {
	return config.vapid_public_key != "" && config.vapid_private_key != ""
}

default_config :: proc() -> Hub_Config {
	cidrs := make([]string, 1)
	cidrs[0] = "127.0.0.1/32"
	return Hub_Config{
		paddle_environment = "sandbox",
		paddle_past_due_grace_seconds = 3 * 86400,
		bind_host = "127.0.0.1",
		port = 8081,
		database_path = "./hub.db",
		migrations_dir = "src/hub/repository/sqlite/migrations",
		username_header = "X-authentik-username",
		display_name_header = "X-authentik-name",
		email_header = "X-authentik-email",
		trusted_proxy_cidrs = cidrs,
		auto_provision_users = true,
		login_url = "",
		logout_url = "https://auth.example.com/application/o/heimdall/end-session/",
		ui_origin = "",
		preview_origin = "",
		preview_legacy_path = true,
		device_auth_expires_in = 300,
		device_auth_interval = 5,
		device_auth_rate_limit = 10,
		device_auth_rate_window = 60,
		reaper_interval_seconds = 20,
		title_nudge_cooldown_seconds = 3600,
		vapid_subject = "mailto:12tanmayvijay@gmail.com",
		public_app_origin = "https://heimdall.mundus.in",
	}
}

// normalize_preview_origin validates the public preview origin and returns a
// heap-owned canonical value without a trailing slash.
normalize_preview_origin :: proc(preview_origin, ui_origin: string) -> (string, bool, string) {
	if preview_origin == "" do return "", true, ""
	if !strings.has_prefix(strings.to_lower(preview_origin, context.temp_allocator), "https://") {
		return "", false, "--preview-origin must start with https://"
	}
	canonical := strings.trim_right(preview_origin, "/")
	host := canonical[len("https://"):]
	if host == "" || strings.contains(host, "/") {
		return "", false, "--preview-origin must contain only scheme and host[:port] (no path)"
	}
	ui_canonical := strings.trim_right(ui_origin, "/")
	if ui_canonical != "" && strings.equal_fold(canonical, ui_canonical) {
		return "", false, "--preview-origin must differ from --ui-origin"
	}
	return strings.clone(canonical), true, ""
}
