package app

import "core:strings"
import "core:strconv"
import "core:net"
import vault "odin_test:lib/vault"

Hub_Config :: struct {
	// Unset: any Paddle credential/price enables limits. Explicit false opts out.
	billing_enforce_plan_limits: Maybe(bool),
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
	// Keep /api/v1/preview/** open even though preview_origin is set. Default false:
	// configuring a dedicated origin closes the same-origin route, because a previewed
	// app served from the Hub origin can call every Hub API as the viewer. Ignored when
	// preview_origin is empty (the legacy route is then the only transport).
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
	// Loopback "host:port" for the private Prometheus /metrics listener
	// (plan 4.2). Empty (the default) disables the listener; in-process
	// counters are still maintained. Must never be the public bind address:
	// /metrics exposes owner ids via heimdall_bridge_info.
	metrics_addr: string,
	// Optional log backend for relayed bridge error events (bridge_logs plan v2
	// §4.2): base URL of a VictoriaLogs/Loki instance; the writer thread POSTs
	// `<url>/insert/loki/api/v1/push`. Empty (the default) disables the push;
	// the SQLite ring and the owner API work regardless.
	log_push_url: string,
	// --pairing-hub-origins / HEIMDALL_PAIRING_HUB_ORIGINS (comma-separated): the
	// OTHER hub addresses a new device may have enrolled against and still be
	// approved here (an API alias such as https://hub.example next to the UI's own
	// origin). The approver accepts a pending device's declared pairing origin only
	// if it is its own API origin or one of these. Raw value; main canonicalizes it
	// into pairing_hub_origin_list (parse_pairing_hub_origins) and refuses to start
	// on a malformed entry.
	pairing_hub_origins: string,
	pairing_hub_origin_list: []string,
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
		preview_legacy_path = false,
		device_auth_expires_in = 300,
		device_auth_interval = 5,
		device_auth_rate_limit = 10,
		device_auth_rate_window = 60,
		reaper_interval_seconds = 20,
		title_nudge_cooldown_seconds = 3600,
		vapid_subject = "mailto:12tanmayvijay@gmail.com",
		public_app_origin = "https://heimdall.mundus.in",
		metrics_addr = "",
		log_push_url = "",
	}
}

// canonical_pair_hub_origin turns an operator-written origin ("https://Hub.Example/",
// "http://127.0.0.1:8081") into the canonical pairing form "scheme://host:port"
// (lowercase, explicit default port, no trailing slash) and validates it with
// vault.valid_pair_hub_origin. The result is temp-allocated.
canonical_pair_hub_origin :: proc(value: string) -> (string, bool) {
	s := strings.to_lower(strings.trim_space(value), context.temp_allocator)
	if strings.has_suffix(s, "/") do s = s[:len(s) - 1]
	scheme_end := strings.index(s, "://")
	if scheme_end < 0 do return "", false
	scheme := s[:scheme_end]
	if scheme != "https" && scheme != "http" do return "", false
	rest := s[scheme_end + 3:]
	has_port := false
	if strings.has_prefix(rest, "[") {
		close_br := strings.index_byte(rest, ']')
		if close_br < 0 do return "", false
		has_port = close_br + 1 < len(rest) && rest[close_br + 1] == ':'
	} else {
		has_port = strings.index_byte(rest, ':') >= 0
	}
	if !has_port do s = strings.concatenate({s, ":443" if scheme == "https" else ":80"}, context.temp_allocator)
	if !vault.valid_pair_hub_origin(s) do return "", false
	return s, true
}

// parse_pairing_hub_origins validates the comma-separated --pairing-hub-origins
// value into canonical pairing origins (duplicates dropped). Empty is valid (no
// aliases: approvers accept only their own API origin). Any malformed entry fails.
parse_pairing_hub_origins :: proc(raw: string, allocator := context.allocator) -> ([]string, bool, string) {
	out := make([dynamic]string, 0, 4, allocator)
	for part in strings.split(raw, ",", context.temp_allocator) {
		if strings.trim_space(part) == "" do continue
		origin, ok := canonical_pair_hub_origin(part)
		if !ok {
			for o in out do delete(o, allocator)
			delete(out)
			return nil, false, strings.concatenate({"--pairing-hub-origins: not an http(s) origin (scheme://host[:port], no path): ", strings.trim_space(part)}, context.temp_allocator)
		}
		dup := false
		for o in out do if o == origin do dup = true
		if !dup do append(&out, strings.clone(origin, allocator))
	}
	return out[:], true, ""
}

// parse_metrics_addr validates a `host:port` for the metrics listener. Only
// IPv4 literals are accepted (no DNS: this is an operator-supplied loopback
// address). Returns ok=false with a message for anything else.
parse_metrics_addr :: proc(value: string) -> (address: net.IP4_Address, port: int, ok: bool, message: string) {
	colon := strings.last_index_byte(value, ':')
	if colon <= 0 || colon == len(value) - 1 do return {}, 0, false, "--metrics-addr must be host:port (e.g. 127.0.0.1:9464)"
	parsed_port, port_ok := strconv.parse_int(value[colon+1:])
	if !port_ok || parsed_port < 1 || parsed_port > 65535 do return {}, 0, false, "--metrics-addr port must be between 1 and 65535"
	addr, addr_ok := net.parse_ip4_address(value[:colon])
	if !addr_ok do return {}, 0, false, "--metrics-addr host must be an IPv4 address literal"
	return addr, int(parsed_port), true, ""
}

// normalize_preview_origin validates the public preview origin and returns a
// heap-owned canonical value without a trailing slash.
normalize_preview_origin :: proc(preview_origin, ui_origin: string) -> (string, bool, string) {
	if preview_origin == "" do return "", true, ""
	if !strings.has_prefix(strings.to_lower(preview_origin, context.temp_allocator), "https://") {
		return "", false, "--preview-origin must start with https://"
	}
	canonical := preview_origin
	if len(canonical) > len("https://") && strings.has_suffix(canonical, "/") do canonical = canonical[:len(canonical)-1]
	authority := canonical[len("https://"):]
	if authority == "" || strings.contains_any(authority, "/?#@ \t\r\n") {
		return "", false, "--preview-origin must contain only scheme and host[:port] (no path)"
	}
	host := authority
	port := ""
	if strings.has_prefix(authority, "[") {
		close := strings.index_byte(authority, ']')
		if close <= 1 || (close + 1 < len(authority) && authority[close+1] != ':') {
			return "", false, "--preview-origin must contain a valid host[:port]"
		}
		host = authority[1:close]
		if _, ipv6_ok := net.parse_ip6_address(host); !ipv6_ok {
			return "", false, "--preview-origin must contain a valid IPv6 host"
		}
		if close + 1 < len(authority) do port = authority[close+2:]
	} else if colon := strings.last_index_byte(authority, ':'); colon >= 0 {
		if strings.index_byte(authority, ':') != colon {
			return "", false, "--preview-origin IPv6 hosts must use brackets"
		}
		host, port = authority[:colon], authority[colon+1:]
	}
	if host == "" {
		return "", false, "--preview-origin must contain a non-empty host"
	}
	if !strings.has_prefix(authority, "[") && !preview_origin_host_valid(host) {
		return "", false, "--preview-origin must contain a valid hostname or IP address"
	}
	if port != "" {
		port_number, port_ok := strconv.parse_int(port)
		if !port_ok || port_number < 1 || port_number > 65535 {
			return "", false, "--preview-origin port must be between 1 and 65535"
		}
	} else if strings.has_suffix(authority, ":") {
		return "", false, "--preview-origin must contain a valid host[:port]"
	}
	ui_canonical := strings.trim_right(ui_origin, "/")
	if ui_canonical != "" && strings.equal_fold(canonical, ui_canonical) {
		return "", false, "--preview-origin must differ from --ui-origin"
	}
	return strings.clone(canonical), true, ""
}

// preview_legacy_path_notice is the startup line describing how previews are isolated,
// so an operator can see from the log whether previewed apps share the Hub origin.
preview_legacy_path_notice :: proc(preview_origin: string, legacy_path: bool) -> string {
	if preview_origin == "" {
		return "WARNING: --preview-origin is not set; previews are served from the Hub origin (/api/v1/preview/) and a previewed app can use the Hub API as its viewer"
	}
	if legacy_path {
		return "WARNING: --preview-legacy-path true keeps the same-origin /api/v1/preview/ route open next to --preview-origin; previewed apps reached through it can use the Hub API as their viewer"
	}
	return "previews are isolated on --preview-origin; the same-origin /api/v1/preview/ route is closed"
}

preview_origin_host_valid :: proc(host: string) -> bool {
	if len(host) == 0 || len(host) > 253 do return false
	if _, ok := net.parse_ip4_address(host); ok do return true
	numeric_address := true
	label_start := 0
	for i in 0..<len(host) {
		c := host[i]
		if c == '.' {
			label_len := i - label_start
			if label_len == 0 || label_len > 63 || host[label_start] == '-' || host[i-1] == '-' do return false
			label_start = i + 1
			continue
		}
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-') do return false
		if c < '0' || c > '9' do numeric_address = false
	}
	label_len := len(host) - label_start
	return !numeric_address && label_len > 0 && label_len <= 63 && host[label_start] != '-' && host[len(host)-1] != '-'
}
