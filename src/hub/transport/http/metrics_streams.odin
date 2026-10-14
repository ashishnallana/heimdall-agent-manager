package http

// Browser-facing stream telemetry owned by the HTTP layer (hub telemetry plan 3.6)
// plus the helpers the four upgrade handlers use for the plan 3.4 ws_* families,
// whose definitions live in project_service.fleet_metrics.
//
//   heimdall_preview_requests_total{status_class}   1xx..5xx / other
//   heimdall_preview_bytes_total{direction}         to_bridge / to_browser
//   heimdall_preview_active_tunnels{bridge_id}      gauge, inc/dec around a tunnel
//   heimdall_lsp_sessions{language}                 gauge, inc on start / dec on stop
//
// Label discipline: every label value here passes through a fixed mapper; the
// browser can never mint a series. Per-bridge series carry only bridge_id.

import project_service "odin_test:hub/service/project"
import shell_session_svc "odin_test:hub/service/shell_session"
import metrics "odin_test:lib/metrics"
import ws "odin_test:lib/ws"

Streams_Metrics :: struct {
	preview_requests:       ^metrics.Family, // {status_class}
	preview_bytes:          ^metrics.Family, // {direction}
	preview_active_tunnels: ^metrics.Family, // {bridge_id}
	lsp_sessions:           ^metrics.Family, // {language}
}

streams_metrics: Streams_Metrics

streams_metrics_init :: proc(reg: ^metrics.Registry) {
	if reg == nil do return
	m := &streams_metrics
	m.preview_requests = metrics.new_counter(reg, "heimdall_preview_requests_total", "Preview tunnel requests by upstream status class (other = no valid response head).", {"status_class"})
	m.preview_bytes = metrics.new_counter(reg, "heimdall_preview_bytes_total", "Preview tunnel payload bytes by direction.", {"direction"})
	m.preview_active_tunnels = metrics.new_gauge(reg, "heimdall_preview_active_tunnels", "Open preview/proxy tunnels per target bridge.", {"bridge_id"})
	m.lsp_sessions = metrics.new_gauge(reg, "heimdall_lsp_sessions", "Language server sessions started through the hub relay, by language.", {"language"})
	for d in ([]string{"to_bridge", "to_browser"}) do metrics.with(m.preview_bytes, d)
}

// ---------------------------------------------------------------------------
// Preview.

preview_status_class :: proc(code: int) -> string {
	switch {
	case code >= 100 && code < 200: return "1xx"
	case code >= 200 && code < 300: return "2xx"
	case code >= 300 && code < 400: return "3xx"
	case code >= 400 && code < 500: return "4xx"
	case code >= 500 && code < 600: return "5xx"
	}
	return "other"
}

preview_note_request :: proc(status_code: int) {
	metrics.counter_inc(metrics.with(streams_metrics.preview_requests, preview_status_class(status_code)))
}

preview_note_bytes_to_bridge :: proc(n: int) {
	if n <= 0 do return
	metrics.counter_add(metrics.with(streams_metrics.preview_bytes, "to_bridge"), u64(n))
}

preview_note_bytes_to_browser :: proc(n: int) {
	if n <= 0 do return
	metrics.counter_add(metrics.with(streams_metrics.preview_bytes, "to_browser"), u64(n))
}

// preview_tunnel_open returns the cached active-tunnels series for the target
// bridge after incrementing it; pass it to preview_tunnel_close (defer).
preview_tunnel_open :: proc(bridge_id: string) -> ^metrics.Series {
	s := metrics.with(streams_metrics.preview_active_tunnels, bridge_id)
	metrics.gauge_inc(s)
	return s
}

preview_tunnel_close :: proc(s: ^metrics.Series) {
	metrics.gauge_dec(s)
}

// ---------------------------------------------------------------------------
// LSP.

// lsp_language_enum maps the browser-supplied language id onto the fixed set the
// UI can emit (src/ui/lsp/lspProtocol.ts LSP_LANGUAGE_BY_EXT); anything else is
// "other" so a client cannot mint series.
lsp_language_enum :: proc(language: string) -> string {
	switch language {
	case "typescript", "typescriptreact", "javascript", "javascriptreact", "python", "go", "rust",
	     "ruby", "java", "kotlin", "c", "cpp", "csharp", "swift", "php", "lua", "shellscript",
	     "json", "jsonc", "yaml", "toml", "markdown", "html", "css", "scss", "less", "sql",
	     "graphql", "proto", "nix", "odin", "zig", "vue", "svelte", "dockerfile", "makefile":
		return language
	}
	return "other"
}

// lsp_session_started returns the cached gauge series (already incremented) for the
// session's language; hand it back to lsp_session_stopped exactly once.
lsp_session_started :: proc(language: string) -> ^metrics.Series {
	s := metrics.with(streams_metrics.lsp_sessions, lsp_language_enum(language))
	metrics.gauge_inc(s)
	return s
}

lsp_session_stopped :: proc(s: ^metrics.Series) {
	metrics.gauge_dec(s)
}

// ---------------------------------------------------------------------------
// ws_* helpers shared by the upgrade handlers (families in project_service).

// ws_bytes_series returns the cached heimdall_ws_bytes_total series for one
// direction of one connection. bridge_id is "" for user/lsp streams.
ws_bytes_series :: proc(kind, direction, bridge_id: string) -> ^metrics.Series {
	return metrics.with(project_service.fleet_metrics.ws_bytes, kind, direction, bridge_id)
}

// ws_note_write counts a browser-bound frame write: payload bytes on success, a
// write error by reason otherwise.
ws_note_write :: proc(kind: string, tx: ^metrics.Series, res: ws.Text_Write_Result, payload_len: int) {
	if res == .Ok {
		metrics.counter_add(tx, u64(payload_len))
		return
	}
	metrics.counter_inc(metrics.with(project_service.fleet_metrics.ws_write_errors, kind, shell_session_svc.ws_write_reason_string(res)))
}

// ws_note_write_ok is ws_note_write for callers that only have a bool.
ws_note_write_ok :: proc(kind: string, tx: ^metrics.Series, ok: bool, payload_len: int) {
	ws_note_write(kind, tx, .Ok if ok else .Peer_Gone, payload_len)
}

// ws_disconnect_reason_string maps the shared frame reader's reason onto the
// heimdall_ws_disconnects_total vocabulary.
ws_disconnect_reason_string :: proc(reason: ws.Frame_Disconnect_Reason) -> string {
	switch reason {
	case .None:          return "clean_close"
	case .Clean_Close:   return "clean_close"
	case .Read_Deadline: return "read_deadline"
	case .Fatal_Frame:   return "fatal_frame"
	case .Recv_Error:    return "recv_error"
	}
	return "other"
}

// ws_note_rx counts one received browser frame on the connection's rx series.
ws_note_rx :: proc(rx: ^metrics.Series, payload_len: int) {
	metrics.counter_add(rx, u64(payload_len))
}
