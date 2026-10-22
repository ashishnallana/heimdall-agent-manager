package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import app "odin_test:hub/app"
import crashlog "odin_test:lib/crashlog"
import domain "odin_test:hub/domain"
import auth_service "odin_test:hub/service/auth"
import platform "odin_test:hub/platform"
import user_service "odin_test:hub/service/user"

main :: proc() {
	crashlog.install("ham-hub")
	config := app.default_config()
	if is_users_command() {
		ok, message := run_users_command(&config)
		if !ok {
			fmt.eprintln(message)
			os.exit(1)
		}
		return
	}
	if is_tokens_command() {
		ok, message := run_tokens_command(&config)
		if !ok {
			fmt.eprintln(message)
			os.exit(1)
		}
		return
	}
	parse_args(&config)
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
	if idx < 0 || idx + 1 >= len(os.args) do return false, "usage: ham-hub users create --name <name> --email <email> [--label <label>] [--expires-in 90d]"
	action := os.args[idx + 1]
	parse_token_global_args(config)
	graph: app.App_Graph
	ok, message := app.build_graph(&graph, config^)
	if !ok do return false, message
	defer app.shutdown_graph(&graph)
	switch action {
	case "create":
		name := arg_value("--name")
		email := arg_value("--email")
		if name == "" || email == "" do return false, "--name and --email are required"
		created, created_ok, created_err := user_service.create_user(&graph.users, user_service.Create_User_Input{name = name, email = email})
		if !created_ok do return false, created_err.message
		result, issued, err := auth_service.issue_user_api_token(&graph.auth, auth_service.Issue_User_API_Token_Input{owner_user_id = created.user_id, label = arg_value("--label"), expires_at = token_expires_at()})
		if !issued do return false, err.message
		fmt.println("user_id=", string(created.user_id))
		fmt.println("token_id=", result.token.token_id)
		fmt.println("token=", result.plaintext)
		fmt.println("expires_at=", result.token.expires_at)
		return true, ""
	}
	return false, "usage: ham-hub users create --name <name> --email <email> [--label <label>] [--expires-in 90d]"
}

run_tokens_command :: proc(config: ^app.Hub_Config) -> (bool, string) {
	idx := tokens_index()
	if idx < 0 || idx + 1 >= len(os.args) do return false, "usage: ham-hub tokens issue --user <user_id> [--label <label>] [--expires-in 90d] | tokens list --user <user_id> | tokens revoke --token-id <token_id>"
	action := os.args[idx + 1]
	parse_token_global_args(config)
	graph: app.App_Graph
	ok, message := app.build_graph(&graph, config^)
	if !ok do return false, message
	defer app.shutdown_graph(&graph)
	switch action {
	case "issue":
		user_id := arg_value("--user")
		if user_id == "" do return false, "--user is required"
		result, issued, err := auth_service.issue_user_api_token(&graph.auth, auth_service.Issue_User_API_Token_Input{owner_user_id = domain.User_ID(user_id), label = arg_value("--label"), expires_at = token_expires_at()})
		if !issued do return false, err.message
		fmt.println("token_id=", result.token.token_id)
		fmt.println("user_id=", string(result.token.owner_user_id))
		fmt.println("token=", result.plaintext)
		fmt.println("expires_at=", result.token.expires_at)
		return true, ""
	case "list":
		user_id := arg_value("--user")
		if user_id == "" do return false, "--user is required"
		tokens, err := auth_service.list_user_api_tokens(&graph.auth, domain.User_ID(user_id))
		if err.code != .None do return false, err.message
		for token in tokens do print_token_metadata(token)
		return true, ""
	case "revoke":
		token_id := arg_value("--token-id")
		if token_id == "" do return false, "--token-id is required"
		token, revoked, err := auth_service.revoke_user_api_token(&graph.auth, token_id)
		if !revoked do return false, err.message
		fmt.println("revoked_token_id=", token.token_id)
		fmt.println("revoked_at=", token.revoked_at)
		return true, ""
	}
	return false, "usage: ham-hub tokens issue|list|revoke [options]"
}

print_token_metadata :: proc(token: domain.User_API_Token) {
	status := "active"
	if token.revoked_at != "" do status = "revoked"
	fmt.println(strings.concatenate({
		"token_id=", token.token_id,
		" user_id=", string(token.owner_user_id),
		" label=", token.label,
		" created_from=", token.created_from,
		" device_label=", token.device_label,
		" status=", status,
		" created_at=", token.created_at,
		" last_used_at=", token.last_used_at,
		" expires_at=", token.expires_at,
		" revoked_at=", token.revoked_at,
	}))
}

parse_token_global_args :: proc(config: ^app.Hub_Config) {
	parse_args(config)
}

tokens_index :: proc() -> int {
	for i := 1; i < len(os.args); i += 1 {
		if os.args[i] == "tokens" do return i
	}
	return -1
}

arg_value :: proc(name: string) -> string {
	for i := 1; i + 1 < len(os.args); i += 1 {
		if os.args[i] == name do return os.args[i + 1]
	}
	return ""
}

token_expires_at :: proc() -> string {
	if v := arg_value("--expires-at"); v != "" do return v
	if v := arg_value("--expires-in"); v != "" {
		seconds, ok := parse_duration_seconds(v)
		if ok do return platform.expires_at_after_seconds(seconds)
	}
	return ""
}

parse_duration_seconds :: proc(value: string) -> (int, bool) {
	if value == "" do return 0, false
	unit := value[len(value) - 1]
	number := value
	mult := 1
	if unit == 'd' || unit == 'h' || unit == 'm' || unit == 's' {
		number = value[:len(value) - 1]
		switch unit {
		case 'd': mult = 86400
		case 'h': mult = 3600
		case 'm': mult = 60
		case 's': mult = 1
		}
	}
	parsed, ok := strconv.parse_int(number)
	if !ok || parsed <= 0 do return 0, false
	return int(parsed) * mult, true
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
		} else if arg == "--trusted-proxy-cidr" && i + 1 < len(os.args) {
			cidrs := make([]string, 1)
			cidrs[0] = strings.clone(os.args[i + 1])
			config.trusted_proxy_cidrs = cidrs
			i += 1
		} else if arg == "--login-url" && i + 1 < len(os.args) {
			config.login_url = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--logout-url" && i + 1 < len(os.args) {
			config.logout_url = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--ui-origin" && i + 1 < len(os.args) {
			config.ui_origin = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--preview-origin" && i + 1 < len(os.args) {
			config.preview_origin = strings.clone(os.args[i + 1]); i += 1
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

// Paddle secrets stay on the server and are never printed.
apply_paddle_env :: proc(config: ^app.Hub_Config) {
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
