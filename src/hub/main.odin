package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import app "odin_test:hub/app"
import crashlog "odin_test:lib/crashlog"
import platform "odin_test:hub/platform"
import user_service "odin_test:hub/service/user"
import httpc "odin_test:lib/httpc"


main :: proc() {
	crashlog.install("ham-hub")
	// libcurl global init, once, before any thread (src/lib/httpc).
	if ok, message := httpc.init(); !ok {
		fmt.eprintln("ham-hub:", message)
		os.exit(1)
	}
	config := app.default_config()
	// Before anything else, including the users/tokens subcommands.
	legacy_value, legacy_present := os.lookup_env("HAM_AUTH_MODE", context.allocator)
	if ok, message := app.check_legacy_auth_mode(legacy_value, legacy_present); !ok {
		fmt.eprintln(message)
		os.exit(2)
	}
	apply_oidc_env(&config)
	if is_users_command() {
		ok, message := run_users_command(&config)
		if !ok {
			fmt.eprintln(message)
			os.exit(1)
		}
		return
	}
	if is_tokens_command() {
		fmt.eprintln("ham-hub tokens was removed: Ninjy user tokens are no longer supported; users sign in with OIDC")
		os.exit(1)
	}
	parse_args(&config)
	// The server requires OIDC bearer + browser login configuration; there is no
	// other way for a user to authenticate.
	if oidc_ok, oidc_error := app.require_oidc_config(config); !oidc_ok {
		fmt.eprintln(oidc_error)
		os.exit(2)
	}
	if config.oidc_allow_insecure_localhost {
		fmt.eprintln("ham-hub: WARNING HAM_OIDC_ALLOW_INSECURE_LOCALHOST is set: http:// OIDC endpoints on localhost are accepted. Local development only.")
	}
	normalized_preview_origin, preview_ok, preview_error := app.normalize_preview_origin(config.preview_origin, config.ui_origin)
	if !preview_ok {
		fmt.eprintln(preview_error)
		os.exit(2)
	}
	config.preview_origin = normalized_preview_origin
	fmt.eprintln(app.preview_legacy_path_notice(config.preview_origin, config.preview_legacy_path))
	pairing_origins, pairing_ok, pairing_error := app.parse_pairing_hub_origins(config.pairing_hub_origins)
	if !pairing_ok {
		fmt.eprintln(pairing_error)
		os.exit(2)
	}
	config.pairing_hub_origin_list = pairing_origins
	if config.metrics_addr != "" {
		if _, _, metrics_ok, metrics_error := app.parse_metrics_addr(config.metrics_addr); !metrics_ok {
			fmt.eprintln(metrics_error)
			os.exit(2)
		}
	}
	ok, message := app.run(config)
	if !ok {
		// Non-zero so systemd (and scripts) see a failed boot, e.g. an
		// unsupported HEIMDALL_DB_TELEMETRY value, instead of a clean exit.
		fmt.eprintln(message)
		os.exit(1)
	}
	fmt.println(message)
}

is_tokens_command :: proc() -> bool {
	for i := 1; i < len(os.args); i += 1 {
		if os.args[i] == "tokens" do return true
	}
	return false
}

is_users_command :: proc() -> bool {
	for i := 1; i < len(os.args); i += 1 {
		if os.args[i] == "users" do return true
	}
	return false
}

users_index :: proc() -> int {
	for i := 1; i < len(os.args); i += 1 {
		if os.args[i] == "users" do return i
	}
	return -1
}

run_users_command :: proc(config: ^app.Hub_Config) -> (bool, string) {
	idx := users_index()
	if idx < 0 || idx + 1 >= len(os.args) do return false, USERS_USAGE
	action := os.args[idx + 1]
	parse_token_global_args(config)
	graph: app.App_Graph
	ok, message := app.build_graph(&graph, config^)
	if !ok do return false, message
	defer app.shutdown_graph(&graph)
	switch action {
	case "link-oidc", "unlink-oidc", "logout", "disable", "enable":
		return run_users_oidc_link_command(&graph, action)
	case "create":
		name := arg_value("--name")
		email := arg_value("--email")
		if name == "" || email == "" do return false, "--name and --email are required"
		created, created_ok, created_err := user_service.create_user(&graph.users, user_service.Create_User_Input{name = name, email = email})
		if !created_ok do return false, created_err.message
		fmt.println("user_id=", string(created.user_id))
		fmt.println("next: ham-hub users link-oidc --user", string(created.user_id), "--subject <oidc-subject>")
		return true, ""
	}
	return false, USERS_USAGE
}

USERS_USAGE :: "usage: ham-hub users create --name <name> --email <email> | users link-oidc --user <user_id> [--issuer <iss>] --subject <sub> | users unlink-oidc --user <user_id> [--issuer <iss>] | users logout --user <user_id> | users disable|enable --user <user_id>"

// run_users_oidc_link_command binds/unbinds an OIDC (issuer, subject) to an
// existing Hub user. This is how an operator maps an existing account to its
// identity-provider subject when automatic claiming is off (the default).
run_users_oidc_link_command :: proc(graph: ^app.App_Graph, action: string) -> (bool, string) {
	user_id := arg_value("--user")
	issuer := arg_value("--issuer")
	return app.users_oidc_link_command(&graph.db, graph.config.oidc_issuer, platform.clock_now(&graph.clock), action, user_id, issuer, arg_value("--subject"))
}

parse_token_global_args :: proc(config: ^app.Hub_Config) {
	parse_args(config)
}

arg_value :: proc(name: string) -> string {
	for i := 1; i + 1 < len(os.args); i += 1 {
		if os.args[i] == name do return os.args[i + 1]
	}
	return ""
}

parse_args :: proc(config: ^app.Hub_Config) {
	// VAPID config resolves as: built-in default -> environment -> flags. Applying
	// env first (below) and flags second (in the loop) keeps precedence uniform
	// across all VAPID fields, including vapid_subject which carries a default.
	apply_vapid_env(config)
	apply_paddle_env(config)

	// public_app_origin resolves default -> env -> flag, same shape as the above.
	//
	// This MUST be overridable per deployment: it is the origin baked into the
	// absolute click href of every Web Push notification
	// (agent_action_handlers.odin:72 -> build_push_payload_json). Left at its
	// built-in default, a second instance sends its users' notification clicks to
	// the FIRST instance's host - which is precisely what the brolabs deployment
	// was doing, silently, because no flag existed to say otherwise.
	if v := os.get_env_alloc("HEIMDALL_PUBLIC_APP_ORIGIN", context.allocator); v != "" {
		config.public_app_origin = v
	}
	// metrics_addr resolves default (off) -> env -> flag. Loopback only by
	// convention; see Hub_Config.metrics_addr.
	if v := os.get_env_alloc("HEIMDALL_METRICS_ADDR", context.allocator); v != "" {
		config.metrics_addr = v
	}
	// log_push_url resolves default (off) -> env -> flag. Loopback by convention
	// (VictoriaLogs on 127.0.0.1:9428 in tools/telemetry/hub).
	if v := os.get_env_alloc("HEIMDALL_LOG_PUSH_URL", context.allocator); v != "" {
		config.log_push_url = v
	}
	// DB telemetry is env-only (boot-time; docs/reference/db-telemetry.md).
	config.db_telemetry = os.get_env_alloc("HEIMDALL_DB_TELEMETRY", context.allocator)
	if v := os.get_env_alloc("HEIMDALL_DB_SLOW_MS", context.allocator); v != "" {
		if parsed, ok := strconv.parse_int(v); ok && parsed >= 0 do config.db_slow_ms = int(parsed)
	}
	if v := os.get_env_alloc("HEIMDALL_DB_SAMPLE_N", context.allocator); v != "" {
		if parsed, ok := strconv.parse_int(v); ok && parsed >= 0 do config.db_sample_n = int(parsed)
	}
	// pairing_hub_origins resolves default (none) -> env -> flag.
	if v := os.get_env_alloc("HEIMDALL_PAIRING_HUB_ORIGINS", context.allocator); v != "" {
		config.pairing_hub_origins = v
	}
	for i := 1; i < len(os.args); i += 1 {
		arg := os.args[i]
		if arg == "--listen" && i + 1 < len(os.args) {
			host, port, ok := split_host_port(os.args[i + 1])
			if ok {
				config.bind_host = host
				config.port = port
			}
			i += 1
		} else if arg == "--port" && i + 1 < len(os.args) {
			if parsed, ok := strconv.parse_int(os.args[i + 1]); ok do config.port = int(parsed)
			i += 1
		} else if arg == "--db" && i + 1 < len(os.args) {
			config.database_path = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--migrations-dir" && i + 1 < len(os.args) {
			config.migrations_dir = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--trusted-proxy-cidr" || arg == "--login-url" || arg == "--logout-url" {
			// Removed with trusted-proxy authentication. Fail loudly so a stale
			// deployment config is noticed instead of silently ignored.
			fmt.eprintfln("ham-hub: %s was removed: users authenticate only with OIDC (see --oidc-* / HAM_OIDC_*). For client-IP resolution behind a proxy use --forwarded-for-trusted-cidr.", arg)
			os.exit(2)
		} else if arg == "--forwarded-for-trusted-cidr" && i + 1 < len(os.args) {
			cidrs := make([]string, 1)
			cidrs[0] = strings.clone(os.args[i + 1])
			config.forwarded_for_trusted_cidrs = cidrs
			i += 1
		} else if arg == "--mcp-oauth-spike" {
			config.mcp_oauth_spike = true
		} else if arg == "--mcp-oauth-key-file" && i+1 < len(os.args) {
			config.mcp_oauth_key_file = strings.clone(os.args[i+1]); i += 1
		} else if arg == "--oidc-allow-insecure-localhost" {
			config.oidc_allow_insecure_localhost = true
		} else if arg == "--oidc-issuer" && i + 1 < len(os.args) {
			config.oidc_issuer = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--oidc-jwks-url" && i + 1 < len(os.args) {
			config.oidc_jwks_url = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--oidc-userinfo-url" && i + 1 < len(os.args) {
			config.oidc_userinfo_url = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--oidc-api-audience" && i + 1 < len(os.args) {
			config.oidc_api_audience = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--oidc-api-scope" && i + 1 < len(os.args) {
			config.oidc_api_scope = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--oidc-authorize-url" && i + 1 < len(os.args) {
			config.oidc_authorize_url = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--oidc-token-url" && i + 1 < len(os.args) {
			config.oidc_token_url = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--oidc-end-session-url" && i + 1 < len(os.args) {
			config.oidc_end_session_url = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--oidc-web-client-id" && i + 1 < len(os.args) {
			config.oidc_web_client_id = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--oidc-web-client-secret-file" && i + 1 < len(os.args) {
			config.oidc_web_client_secret_file = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--oidc-redirect-uri" && i + 1 < len(os.args) {
			config.oidc_redirect_uri = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--session-ttl-hours" && i + 1 < len(os.args) {
			parsed, ok := strconv.parse_int(os.args[i + 1])
			if !ok || parsed <= 0 { fmt.eprintln("--session-ttl-hours must be a positive integer"); os.exit(2) }
			config.session_ttl_hours = int(parsed)
			i += 1
		} else if arg == "--session-idle-hours" && i + 1 < len(os.args) {
			parsed, ok := strconv.parse_int(os.args[i + 1])
			if !ok || parsed <= 0 { fmt.eprintln("--session-idle-hours must be a positive integer"); os.exit(2) }
			config.session_idle_hours = int(parsed)
			i += 1
		} else if arg == "--oidc-claim-existing-users" && i + 1 < len(os.args) {
			parsed, ok := app.parse_bool_setting(os.args[i + 1])
			if !ok { fmt.eprintln("--oidc-claim-existing-users must be true or false"); os.exit(2) }
			config.oidc_claim_existing_users = parsed
			i += 1
		} else if arg == "--auto-provision-users" && i + 1 < len(os.args) {
			parsed, ok := app.parse_bool_setting(os.args[i + 1])
			if !ok { fmt.eprintln("--auto-provision-users must be true or false"); os.exit(2) }
			config.auto_provision_users_setting = parsed
			i += 1
		} else if arg == "--ui-origin" && i + 1 < len(os.args) {
			config.ui_origin = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--preview-origin" && i + 1 < len(os.args) {
			config.preview_origin = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--billing-enforce-plan-limits" {
			if i + 1 >= len(os.args) {
				fmt.eprintln("--billing-enforce-plan-limits requires true or false")
				os.exit(2)
			}
			config.billing_enforce_plan_limits = parse_plan_limits_setting(os.args[i + 1], "--billing-enforce-plan-limits")
			i += 1
		} else if arg == "--preview-legacy-path" && i + 1 < len(os.args) {
			value := strings.to_lower(os.args[i + 1], context.temp_allocator)
			if value == "true" {
				config.preview_legacy_path = true
			} else if value == "false" {
				config.preview_legacy_path = false
			} else {
				fmt.eprintln("--preview-legacy-path must be true or false")
				os.exit(2)
			}
			i += 1
		} else if arg == "--pairing-hub-origins" && i + 1 < len(os.args) {
			config.pairing_hub_origins = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--public-app-origin" && i + 1 < len(os.args) {
			config.public_app_origin = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--metrics-addr" && i + 1 < len(os.args) {
			config.metrics_addr = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--log-push-url" && i + 1 < len(os.args) {
			config.log_push_url = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--reaper-interval-seconds" && i + 1 < len(os.args) {
			if parsed, ok := strconv.parse_int(os.args[i + 1]); ok do config.reaper_interval_seconds = int(parsed)
			i += 1
		} else if arg == "--runtime-max-live-bridges" && i + 1 < len(os.args) {
			parsed, ok := strconv.parse_int(os.args[i + 1])
			if !ok || parsed <= 0 { fmt.eprintln("max-live-bridges must be a positive integer"); os.exit(2) }
			config.runtime_max_live_bridges = int(parsed)
			i += 1
		} else if arg == "--runtime-max-live-bridges-per-owner" && i + 1 < len(os.args) {
			parsed, ok := strconv.parse_int(os.args[i + 1])
			if !ok || parsed <= 0 { fmt.eprintln("max-live-bridges-per-owner must be a positive integer"); os.exit(2) }
			config.runtime_max_live_bridges_per_owner = int(parsed)
			i += 1
		} else if arg == "--runtime-max-active-instances" && i + 1 < len(os.args) {
			parsed, ok := strconv.parse_int(os.args[i + 1])
			if !ok || parsed <= 0 { fmt.eprintln("max-active-instances must be a positive integer"); os.exit(2) }
			config.runtime_max_active_instances = int(parsed)
			i += 1
		} else if arg == "--runtime-max-active-instances-per-owner" && i + 1 < len(os.args) {
			parsed, ok := strconv.parse_int(os.args[i + 1])
			if !ok || parsed <= 0 { fmt.eprintln("max-active-instances-per-owner must be a positive integer"); os.exit(2) }
			config.runtime_max_active_instances_per_owner = int(parsed)
			i += 1
		} else if arg == "--runtime-terminal-entries-per-bridge" && i + 1 < len(os.args) {
			parsed, ok := strconv.parse_int(os.args[i + 1])
			if !ok || parsed <= 0 { fmt.eprintln("terminal-entries-per-bridge must be a positive integer"); os.exit(2) }
			config.runtime_terminal_entries_per_bridge = int(parsed)
			i += 1
		} else if arg == "--runtime-terminal-retention-seconds" && i + 1 < len(os.args) {
			parsed, ok := strconv.parse_int(os.args[i + 1])
			if !ok || parsed <= 0 { fmt.eprintln("terminal-retention-seconds must be a positive integer"); os.exit(2) }
			config.runtime_terminal_retention_seconds = int(parsed)
			i += 1
		} else if arg == "--title-nudge-cooldown-seconds" && i + 1 < len(os.args) {
			if parsed, ok := strconv.parse_int(os.args[i + 1]); ok do config.title_nudge_cooldown_seconds = int(parsed)
			i += 1
		} else if arg == "--vapid-public-key" && i + 1 < len(os.args) {
			config.vapid_public_key = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--vapid-private-key" && i + 1 < len(os.args) {
			config.vapid_private_key = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--vapid-private-key-file" && i + 1 < len(os.args) {
			config.vapid_private_key = read_key_file(os.args[i + 1]); i += 1
		} else if arg == "--vapid-subject" && i + 1 < len(os.args) {
			config.vapid_subject = strings.clone(os.args[i + 1]); i += 1
		}
	}
}

// apply_oidc_env seeds OIDC provider settings from HAM_OIDC_* (flags parsed
// later override these). It runs before the users/tokens subcommands so they see
// whether OIDC is configured. No issuer, endpoint or audience is hard-coded.
apply_oidc_env :: proc(config: ^app.Hub_Config) {
	if v := os.get_env_alloc("HAM_OIDC_ISSUER", context.allocator); v != "" do config.oidc_issuer = v
	if v := os.get_env_alloc("HAM_OIDC_JWKS_URL", context.allocator); v != "" do config.oidc_jwks_url = v
	if v := os.get_env_alloc("HAM_OIDC_USERINFO_URL", context.allocator); v != "" do config.oidc_userinfo_url = v
	if v := os.get_env_alloc("HAM_OIDC_API_AUDIENCE", context.allocator); v != "" do config.oidc_api_audience = v
	if v := os.get_env_alloc("HAM_OIDC_API_SCOPE", context.allocator); v != "" do config.oidc_api_scope = v
	if v := os.get_env_alloc("HAM_OIDC_AUTHORIZE_URL", context.allocator); v != "" do config.oidc_authorize_url = v
	if v := os.get_env_alloc("HAM_OIDC_TOKEN_URL", context.allocator); v != "" do config.oidc_token_url = v
	if v := os.get_env_alloc("HAM_OIDC_END_SESSION_URL", context.allocator); v != "" do config.oidc_end_session_url = v
	if v := os.get_env_alloc("HAM_OIDC_WEB_CLIENT_ID", context.allocator); v != "" do config.oidc_web_client_id = v
	if v := os.get_env_alloc("HAM_OIDC_WEB_CLIENT_SECRET_FILE", context.allocator); v != "" do config.oidc_web_client_secret_file = v
	if v := os.get_env_alloc("HAM_OIDC_REDIRECT_URI", context.allocator); v != "" do config.oidc_redirect_uri = v
	if v := os.get_env_alloc("HAM_SESSION_TTL_HOURS", context.allocator); v != "" {
		parsed, ok := strconv.parse_int(v)
		if !ok || parsed <= 0 { fmt.eprintln("HAM_SESSION_TTL_HOURS must be a positive integer"); os.exit(2) }
		config.session_ttl_hours = int(parsed)
	}
	if v := os.get_env_alloc("HAM_SESSION_IDLE_HOURS", context.allocator); v != "" {
		parsed, ok := strconv.parse_int(v)
		if !ok || parsed <= 0 { fmt.eprintln("HAM_SESSION_IDLE_HOURS must be a positive integer"); os.exit(2) }
		config.session_idle_hours = int(parsed)
	}
	// Development only: accept http:// OIDC endpoints whose host is exactly a
	// loopback name. Never set in production; startup prints a warning.
	if v := os.get_env_alloc("HAM_OIDC_ALLOW_INSECURE_LOCALHOST", context.allocator); v != "" {
		if v != "1" { fmt.eprintln("HAM_OIDC_ALLOW_INSECURE_LOCALHOST must be 1 when set"); os.exit(2) }
		config.oidc_allow_insecure_localhost = true
	}
	if v := os.get_env_alloc("HAM_OIDC_CLAIM_EXISTING_USERS", context.allocator); v != "" {
		parsed, ok := app.parse_bool_setting(v)
		if !ok { fmt.eprintln("HAM_OIDC_CLAIM_EXISTING_USERS must be true or false"); os.exit(2) }
		config.oidc_claim_existing_users = parsed
	}
	if v := os.get_env_alloc("HAM_AUTO_PROVISION_USERS", context.allocator); v != "" {
		parsed, ok := app.parse_bool_setting(v)
		if !ok { fmt.eprintln("HAM_AUTO_PROVISION_USERS must be true or false"); os.exit(2) }
		config.auto_provision_users_setting = parsed
	}
}

// apply_vapid_env seeds VAPID config from the environment:
// HEIMDALL_VAPID_PUBLIC_KEY, HEIMDALL_VAPID_PRIVATE_KEY (inline) or
// HEIMDALL_VAPID_PRIVATE_KEY_FILE (path), and HEIMDALL_VAPID_SUBJECT. Command
// line flags are applied afterwards and override these. The private key is a
// secret and is never printed.
apply_vapid_env :: proc(config: ^app.Hub_Config) {
	if v := os.get_env_alloc("HEIMDALL_VAPID_PUBLIC_KEY", context.allocator); v != "" do config.vapid_public_key = v
	if v := os.get_env_alloc("HEIMDALL_VAPID_PRIVATE_KEY", context.allocator); v != "" {
		config.vapid_private_key = v
	} else if path := os.get_env_alloc("HEIMDALL_VAPID_PRIVATE_KEY_FILE", context.allocator); path != "" {
		config.vapid_private_key = read_key_file(path)
	}
	if v := os.get_env_alloc("HEIMDALL_VAPID_SUBJECT", context.allocator); v != "" do config.vapid_subject = v
}

// read_key_file loads a VAPID private key from a file, trimming trailing
// whitespace/newlines. Returns "" (push stays disabled) if the file is missing
// or unreadable, warning to stderr so a misconfigured key path is visible to
// ops (e.g. the NixOS deploy that provides the key via file). The contents are
// secret and are never logged.
read_key_file :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("ham-hub: WARNING could not read VAPID private key file:", path, "- web push send will be disabled")
		return ""
	}
	return strings.clone(strings.trim_space(string(data)))
}

split_host_port :: proc(value: string) -> (string, int, bool) {
	colon := strings.last_index_byte(value, ':')
	if colon < 0 do return "", 0, false
	port_i, ok := strconv.parse_int(value[colon + 1:])
	if !ok do return "", 0, false
	return strings.clone(value[:colon]), int(port_i), true
}

// Reject malformed overrides rather than silently disabling enforcement.
parse_plan_limits_setting :: proc(value, source: string) -> bool {
	normalized := strings.to_lower(value, context.temp_allocator)
	if normalized == "true" do return true
	if normalized == "false" do return false
	fmt.eprintln(source, "must be true or false")
	os.exit(2)
}

// Paddle secrets stay on the server and are never printed.
apply_paddle_env :: proc(config: ^app.Hub_Config) {
	if v := os.get_env_alloc("HEIMDALL_BILLING_ENFORCE_PLAN_LIMITS", context.allocator); v != "" {
		config.billing_enforce_plan_limits = parse_plan_limits_setting(v, "HEIMDALL_BILLING_ENFORCE_PLAN_LIMITS")
	}
	if v := os.get_env_alloc("HEIMDALL_PADDLE_ENVIRONMENT", context.allocator); v != "" do config.paddle_environment = v
	config.paddle_api_key = os.get_env_alloc("HEIMDALL_PADDLE_API_KEY", context.allocator)
	config.paddle_client_token = os.get_env_alloc("HEIMDALL_PADDLE_CLIENT_TOKEN", context.allocator)
	config.paddle_webhook_secret = os.get_env_alloc("HEIMDALL_PADDLE_WEBHOOK_SECRET", context.allocator)
	config.paddle_hobbyist_price_id = os.get_env_alloc("HEIMDALL_PADDLE_HOBBYIST_PRICE_ID", context.allocator)
	if v := os.get_env_alloc("HEIMDALL_PADDLE_PAST_DUE_GRACE_SECONDS", context.allocator); v != "" {
		parsed, ok := strconv.parse_int(v)
		config.paddle_past_due_grace_seconds = int(parsed) if ok && parsed >= 0 else -1
	}
}
