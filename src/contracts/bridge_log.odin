package contracts

// Bridge error-event relay (bridge_log frames) — the shared allow-list.
//
// Bridges run on customer machines, so the only things a bridge may say about a
// failure are a CODE from the fixed enum below and a handful of FIELDS whose keys
// are from a fixed enum and whose values are either an integer or a symbol from
// another fixed enum. No free-text message is ever shipped: the bridge renders
// its own stderr line locally and the hub renders human text per code
// (src/hub/transport/http/bridge_log_render.odin). Nothing free-form can be
// constructed, so there is nothing to scrub.
//
// Both ends import this file so the names on the wire come from ONE table. A
// hub older than the bridge maps an unknown code to "other" and an unknown
// symbol to .other; it never rejects the entry for being newer.
//
// Frame (bridge -> hub, after bridge_ready, only when telemetry is enabled):
//   {"type":"bridge_log","seq_from":N,"seq_to":N,"dropped":N,
//    "entries":[{"seq":N,"ts_ms":N,"level":"warn|error","code":"<name>",
//                "fields":{"<key>":<int|"<sym>">,...},"count":N}, ...]}
// Caps: <= BRIDGE_LOG_MAX_ENTRIES entries and <= BRIDGE_LOG_MAX_FRAME_BYTES, so a
// frame never reaches BRIDGE_WS_HUB_RUNTIME_CHUNK_PAYLOAD_BYTES and is never
// base64-chunked.

BRIDGE_LOG_FRAME_TYPE :: "bridge_log"
BRIDGE_LOG_MAX_ENTRIES :: 10
BRIDGE_LOG_MAX_FRAME_BYTES :: 4096
BRIDGE_LOG_MAX_FIELDS :: 4
BRIDGE_LOG_MAX_COUNT :: 1000
BRIDGE_LOG_MAX_DROPPED :: 65535
#assert(BRIDGE_LOG_MAX_FRAME_BYTES < BRIDGE_WS_HUB_RUNTIME_CHUNK_PAYLOAD_BYTES)

Bridge_Log_Level :: enum u8 {
	Warn,
	Error,
}

BRIDGE_LOG_LEVEL_NAMES :: [Bridge_Log_Level]string{
	.Warn  = "warn",
	.Error = "error",
}

Bridge_Log_Code :: enum u8 {
	// hub link
	hub_connect_failed,
	tls_backend_missing,
	hub_rejected,
	hub_ready_timeout,
	hub_connection_replaced,
	hub_ws_closed,
	clock_skew,
	// identity / vault
	enroll_failed,
	token_persist_failed,
	config_write_failed,
	vault_locked,
	vault_unseal_failed,
	keystore_unavailable,
	outbox_persist_failed,
	// agents
	pty_host_spawn_failed,
	pty_host_unreachable,
	pty_host_exited,
	agent_launch_failed,
	agent_exited_early,
	agent_bootstrap_invalid,
	provider_missing,
	provider_not_logged_in,
	provider_discovery_failed,
	// shells / lsp / tunnel
	shell_start_failed,
	shell_exited_error,
	lsp_start_failed,
	lsp_crashed,
	tunnel_error,
	preview_proxy_error,
	// update
	update_download_failed,
	update_apply_failed,
	update_rollback,
	// misc
	telemetry_collector_failed,
	search_index_error,
	internal,
}

BRIDGE_LOG_CODE_NAMES :: [Bridge_Log_Code]string{
	.hub_connect_failed         = "hub_connect_failed",
	.tls_backend_missing        = "tls_backend_missing",
	.hub_rejected               = "hub_rejected",
	.hub_ready_timeout          = "hub_ready_timeout",
	.hub_connection_replaced    = "hub_connection_replaced",
	.hub_ws_closed              = "hub_ws_closed",
	.clock_skew                 = "clock_skew",
	.enroll_failed              = "enroll_failed",
	.token_persist_failed       = "token_persist_failed",
	.config_write_failed        = "config_write_failed",
	.vault_locked               = "vault_locked",
	.vault_unseal_failed        = "vault_unseal_failed",
	.keystore_unavailable       = "keystore_unavailable",
	.outbox_persist_failed      = "outbox_persist_failed",
	.pty_host_spawn_failed      = "pty_host_spawn_failed",
	.pty_host_unreachable       = "pty_host_unreachable",
	.pty_host_exited            = "pty_host_exited",
	.agent_launch_failed        = "agent_launch_failed",
	.agent_exited_early         = "agent_exited_early",
	.agent_bootstrap_invalid    = "agent_bootstrap_invalid",
	.provider_missing           = "provider_missing",
	.provider_not_logged_in     = "provider_not_logged_in",
	.provider_discovery_failed  = "provider_discovery_failed",
	.shell_start_failed         = "shell_start_failed",
	.shell_exited_error         = "shell_exited_error",
	.lsp_start_failed           = "lsp_start_failed",
	.lsp_crashed                = "lsp_crashed",
	.tunnel_error               = "tunnel_error",
	.preview_proxy_error        = "preview_proxy_error",
	.update_download_failed     = "update_download_failed",
	.update_apply_failed        = "update_apply_failed",
	.update_rollback            = "update_rollback",
	.telemetry_collector_failed = "telemetry_collector_failed",
	.search_index_error         = "search_index_error",
	.internal                   = "internal",
}

// Field keys. Int-valued keys carry a JSON integer; symbol-valued keys carry a
// JSON string that must name a Bridge_Log_Sym.
Bridge_Log_Key :: enum u8 {
	stage,        // sym
	reason,       // sym
	provider,     // sym
	command_kind, // sym
	hub_status,   // int
	exit_code,    // int
	errno,        // int
	attempt,      // int
	port,         // int
	duration_ms,  // int
}

BRIDGE_LOG_KEY_NAMES :: [Bridge_Log_Key]string{
	.stage        = "stage",
	.reason       = "reason",
	.provider     = "provider",
	.command_kind = "command_kind",
	.hub_status   = "hub_status",
	.exit_code    = "exit_code",
	.errno        = "errno",
	.attempt      = "attempt",
	.port         = "port",
	.duration_ms  = "duration_ms",
}

bridge_log_key_is_symbolic :: proc(key: Bridge_Log_Key) -> bool {
	#partial switch key {
	case .stage, .reason, .provider, .command_kind:
		return true
	}
	return false
}

// Symbolic field values. One flat namespace for every symbol-valued key: the
// hub stores and renders the name, never interprets it per key.
Bridge_Log_Sym :: enum u8 {
	other,
	// stage
	dns, tcp, tls, ws_upgrade, hello, ready,
	authorize, poll, token, write, chmod, rename, config, vault,
	socket_dir, exec, spawn, startup,
	manifest, blob, assemble, materialize,
	download, verify, extract, preflight, supervisor, staging, drain,
	android_keystore, linux_keyring, macos_keychain, sqlite,
	// reason
	eof, timeout, write_error, replaced, revoked, limit, unsupported, denied, expired,
	transport, missing_binary, not_executable, login_required, unknown,
	// provider
	claude, codex, copilot, antigravity, gemini,
	// command_kind
	launch_agent, wake_agent, shell_start, shell_restart, agent_pty_input, provider_test, bridge_update,
}

BRIDGE_LOG_SYM_NAMES :: [Bridge_Log_Sym]string{
	.other            = "other",
	.dns              = "dns",
	.tcp              = "tcp",
	.tls              = "tls",
	.ws_upgrade       = "ws_upgrade",
	.hello            = "hello",
	.ready            = "ready",
	.authorize        = "authorize",
	.poll             = "poll",
	.token            = "token",
	.write            = "write",
	.chmod            = "chmod",
	.rename           = "rename",
	.config           = "config",
	.vault            = "vault",
	.socket_dir       = "socket_dir",
	.exec             = "exec",
	.spawn            = "spawn",
	.startup          = "startup",
	.manifest         = "manifest",
	.blob             = "blob",
	.assemble         = "assemble",
	.materialize      = "materialize",
	.download         = "download",
	.verify           = "verify",
	.extract          = "extract",
	.preflight        = "preflight",
	.supervisor       = "supervisor",
	.staging          = "staging",
	.drain            = "drain",
	.android_keystore = "android_keystore",
	.linux_keyring    = "linux_keyring",
	.macos_keychain   = "macos_keychain",
	.sqlite           = "sqlite",
	.eof              = "eof",
	.timeout          = "timeout",
	.write_error      = "write_error",
	.replaced         = "replaced",
	.revoked          = "revoked",
	.limit            = "limit",
	.unsupported      = "unsupported",
	.denied           = "denied",
	.expired          = "expired",
	.transport        = "transport",
	.missing_binary   = "missing_binary",
	.not_executable   = "not_executable",
	.login_required   = "login_required",
	.unknown          = "unknown",
	.claude           = "claude",
	.codex            = "codex",
	.copilot          = "copilot",
	.antigravity      = "antigravity",
	.gemini           = "gemini",
	.launch_agent     = "launch_agent",
	.wake_agent       = "wake_agent",
	.shell_start      = "shell_start",
	.shell_restart    = "shell_restart",
	.agent_pty_input  = "agent_pty_input",
	.provider_test    = "provider_test",
	.bridge_update    = "bridge_update",
}

// Name -> enum lookups (linear over small tables; only the hub's validator and
// tests use them) and enum -> name accessors (constant tables cannot be indexed
// with a runtime value directly).
bridge_log_code_name :: proc(code: Bridge_Log_Code) -> string {
	names := BRIDGE_LOG_CODE_NAMES
	return names[code]
}

bridge_log_key_name :: proc(key: Bridge_Log_Key) -> string {
	names := BRIDGE_LOG_KEY_NAMES
	return names[key]
}

bridge_log_sym_name :: proc(sym: Bridge_Log_Sym) -> string {
	names := BRIDGE_LOG_SYM_NAMES
	return names[sym]
}

bridge_log_level_name :: proc(level: Bridge_Log_Level) -> string {
	return "error" if level == .Error else "warn"
}

bridge_log_code_from_name :: proc(name: string) -> (Bridge_Log_Code, bool) {
	names := BRIDGE_LOG_CODE_NAMES
	for n, c in names do if n == name do return c, true
	return .internal, false
}

bridge_log_key_from_name :: proc(name: string) -> (Bridge_Log_Key, bool) {
	names := BRIDGE_LOG_KEY_NAMES
	for n, k in names do if n == name do return k, true
	return .stage, false
}

bridge_log_sym_from_name :: proc(name: string) -> (Bridge_Log_Sym, bool) {
	names := BRIDGE_LOG_SYM_NAMES
	for n, s in names do if n == name do return s, true
	return .other, false
}

bridge_log_level_from_name :: proc(name: string) -> (Bridge_Log_Level, bool) {
	switch name {
	case "warn":  return .Warn, true
	case "error": return .Error, true
	}
	return .Warn, false
}

// bridge_log_provider_sym maps a provider id (as the hub's catalog names them) to
// its symbol; anything unknown is .other, never a new value.
bridge_log_provider_sym :: proc(provider: string) -> Bridge_Log_Sym {
	switch provider {
	case "claude":      return .claude
	case "codex":       return .codex
	case "copilot":     return .copilot
	case "antigravity": return .antigravity
	case "gemini":      return .gemini
	}
	return .other
}

// ---- error classes -------------------------------------------------------
//
// Every code has ONE default class saying what the bridge may do about it:
//   retriable   — transient; the identical request can succeed later. Retry with
//                 exponential backoff, always (the cap keeps it cheap).
//   recoverable — keeps failing until something EXTERNAL changes (an install, a
//                 login, an unseal, a config push). Park; never retry on a timer;
//                 resume on the matching trigger.
//   fatal       — the request itself is invalid, or retrying cannot help. Fail
//                 once, report, never retry.
// The table is an exhaustive enumerated array, so a new code without a class is
// a compile error. bridge_error_classify refines the default with the reason
// symbol and the hub HTTP status, which carry more specific evidence. Both ends
// import this, so the hub derives the same class from (code, fields) without the
// class ever riding the wire.

Bridge_Error_Class :: enum u8 {
	retriable,
	recoverable,
	fatal,
}

BRIDGE_ERROR_CLASS_NAMES :: [Bridge_Error_Class]string{
	.retriable   = "retriable",
	.recoverable = "recoverable",
	.fatal       = "fatal",
}

BRIDGE_LOG_CODE_DEFAULT_CLASS :: [Bridge_Log_Code]Bridge_Error_Class{
	// hub link
	.hub_connect_failed         = .retriable,
	.tls_backend_missing        = .recoverable, // install a TLS backend
	.hub_rejected               = .retriable,   // refined by hub_status
	.hub_ready_timeout          = .retriable,
	.hub_connection_replaced    = .retriable,
	.hub_ws_closed              = .retriable,
	.clock_skew                 = .recoverable, // sync the clock
	// identity / vault
	.enroll_failed              = .retriable,   // refined: expired/denied -> recoverable
	.token_persist_failed       = .recoverable, // fix permissions / disk
	.config_write_failed        = .recoverable, // fix permissions / disk
	.vault_locked               = .recoverable, // unseal
	.vault_unseal_failed        = .recoverable, // correct key
	.keystore_unavailable       = .retriable,
	.outbox_persist_failed      = .retriable,
	// agents
	.pty_host_spawn_failed      = .retriable,
	.pty_host_unreachable       = .retriable,
	.pty_host_exited            = .retriable,
	.agent_launch_failed        = .retriable,   // refined by reason
	.agent_exited_early         = .retriable,
	.agent_bootstrap_invalid    = .recoverable, // hub pushes a fixed config
	.provider_missing           = .recoverable, // install / configure provider
	.provider_not_logged_in     = .recoverable, // log in
	.provider_discovery_failed  = .retriable,
	// shells / lsp / tunnel
	.shell_start_failed         = .fatal,       // bad cwd / command for this request
	.shell_exited_error         = .fatal,       // the user's command failed, not the bridge
	.lsp_start_failed           = .recoverable, // install the language server
	.lsp_crashed                = .retriable,
	.tunnel_error               = .retriable,
	.preview_proxy_error        = .retriable,
	// update
	.update_download_failed     = .retriable,
	.update_apply_failed        = .fatal,       // never re-apply the same version automatically
	.update_rollback            = .fatal,
	// misc
	.telemetry_collector_failed = .retriable,
	.search_index_error         = .retriable,
	.internal                   = .fatal,       // a bug: report, never loop on it
}

bridge_error_class_name :: proc(class: Bridge_Error_Class) -> string {
	names := BRIDGE_ERROR_CLASS_NAMES
	return names[class]
}

// bridge_error_http_class classifies a hub HTTP outcome. status 0 means the
// request never got a response (transport failure).
bridge_error_http_class :: proc(status: int) -> Bridge_Error_Class {
	switch {
	case status == 0, status == 429, status >= 500: return .retriable
	// 409/423: the resource is in the wrong state (e.g. "not launchable") and
	// becomes valid when that state changes, not by repeating the request.
	case status == 401, status == 403, status == 409, status == 423: return .recoverable
	case status >= 400:                               return .fatal
	}
	return .retriable
}

// bridge_error_classify_unknown classes an event whose code this side does not
// know (a newer peer; the hub stores it as "other"). The fields still carry
// evidence, so hub_status and the reason are applied as usual. With neither, the
// result is fatal: an error that is not understood must never be retried
// automatically.
bridge_error_classify_unknown :: proc(reason: Bridge_Log_Sym = .other, hub_status := 0) -> Bridge_Error_Class {
	if hub_status > 0 do return bridge_error_http_class(hub_status)
	#partial switch reason {
	case .timeout, .transport, .eof:
		return .retriable
	case .missing_binary, .not_executable, .login_required, .revoked, .expired, .denied:
		return .recoverable
	}
	return .fatal
}

// bridge_error_classify returns the class of (code, reason, hub_status). Precedence:
// a fatal default is final (a reason never softens a bug or a rolled-back update);
// otherwise a hub HTTP status (> 0) is the most specific evidence, then the reason
// symbol, then the code's default.
bridge_error_classify :: proc(code: Bridge_Log_Code, reason: Bridge_Log_Sym = .other, hub_status := 0) -> Bridge_Error_Class {
	defaults := BRIDGE_LOG_CODE_DEFAULT_CLASS
	if defaults[code] == .fatal do return .fatal
	if hub_status > 0 do return bridge_error_http_class(hub_status)
	#partial switch reason {
	case .timeout, .transport, .eof:
		return .retriable
	case .missing_binary, .not_executable, .login_required, .revoked, .expired, .denied:
		return .recoverable
	case .unsupported:
		return .fatal
	}
	return defaults[code]
}
