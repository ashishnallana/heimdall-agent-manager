package bridge_log

import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"

// Server-side rendering of bridge error events (bridge_logs plan v2 §4.4).
// The bridge ships only `code` + typed fields; THIS table is the single source
// of human text — the owner API and the optional log-backend push both use
// it — so copy improves without a bridge upgrade and nothing free-form ever
// crosses the wire. Every Bridge_Log_Code has an entry (the http render test
// checks that), and "other" covers a code from a bridge newer than this hub.

// bridge_log_render_title gives the headline for a code.
render_title :: proc(code: string) -> string {
	c, known := contracts.bridge_log_code_from_name(code)
	if !known do return "Bridge reported an event this hub does not recognise (bridge newer than hub)"
	switch c {
	case .hub_connect_failed:         return "Could not connect to the hub"
	case .tls_backend_missing:        return "TLS relay (socat/openssl) is missing on the bridge host"
	case .hub_rejected:               return "The hub rejected the bridge session"
	case .hub_ready_timeout:          return "The hub did not acknowledge the session in time"
	case .hub_connection_replaced:    return "Another bridge process with the same identity connected; this one backed off"
	case .hub_ws_closed:              return "Connection to the hub closed; reconnecting"
	case .clock_skew:                 return "Bridge clock differs from the hub clock"
	case .enroll_failed:              return "Enrollment failed"
	case .token_persist_failed:       return "Could not save the bridge credential"
	case .config_write_failed:        return "Could not write the bridge configuration"
	case .vault_locked:               return "A command was refused because the vault is locked"
	case .vault_unseal_failed:        return "The vault key could not be unsealed"
	case .keystore_unavailable:       return "The OS keystore is unavailable; the vault key was not persisted"
	case .outbox_persist_failed:      return "Could not persist an event to disk; it will not survive a restart"
	case .pty_host_spawn_failed:      return "Could not start the PTY host daemon"
	case .pty_host_unreachable:       return "The PTY host daemon is not answering"
	case .pty_host_exited:            return "The PTY host daemon exited"
	case .agent_launch_failed:        return "Agent launch failed"
	case .agent_exited_early:         return "Agent exited right after launch"
	case .agent_bootstrap_invalid:    return "Agent bootstrap could not be assembled"
	case .provider_missing:           return "Provider CLI is not installed or has no runnable command"
	case .provider_not_logged_in:     return "Provider CLI needs an interactive login"
	case .provider_discovery_failed:  return "Provider discovery failed"
	case .shell_start_failed:         return "Shell session failed to start"
	case .shell_exited_error:         return "Shell session exited with an error"
	case .lsp_start_failed:           return "Language server failed to start"
	case .lsp_crashed:                return "Language server crashed"
	case .tunnel_error:               return "Tunnel error"
	case .preview_proxy_error:        return "Preview proxy error"
	case .update_download_failed:     return "Bridge update download failed"
	case .update_apply_failed:        return "Bridge update could not be applied"
	case .update_rollback:            return "Bridge update was rolled back"
	case .telemetry_collector_failed: return "Telemetry collector (telegraf) failed"
	case .search_index_error:         return "Task-chain search index error"
	case .internal:                   return "Internal bridge error"
	}
	return "Bridge event"
}

// bridge_log_render_message renders "<title> (key: value, …)" from the stored,
// already-normalised fields object. Field values are enum names or integers, so
// the output is safe to show as-is; a couple of keys get units/labels.
render_message :: proc(code, fields_json: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, render_title(code))
	first := true
	keys := contracts.BRIDGE_LOG_KEY_NAMES
	for key_name, key in keys {
		raw, found := field_raw(fields_json, key_name)
		if !found do continue
		strings.write_string(&b, " (" if first else ", ")
		first = false
		switch key {
		case .stage:        strings.write_string(&b, "stage: ")
		case .reason:       strings.write_string(&b, "reason: ")
		case .provider:     strings.write_string(&b, "provider: ")
		case .command_kind: strings.write_string(&b, "command: ")
		case .hub_status:   strings.write_string(&b, "HTTP ")
		case .exit_code:    strings.write_string(&b, "exit code ")
		case .errno:        strings.write_string(&b, "errno ")
		case .attempt:      strings.write_string(&b, "attempt ")
		case .port:         strings.write_string(&b, "port ")
		case .duration_ms:  strings.write_string(&b, "after ")
		}
		if contracts.bridge_log_key_is_symbolic(key) {
			strings.write_string(&b, strings.trim(raw, "\""))
		} else if key == .duration_ms {
			ms, _ := strconv.parse_i64(raw)
			if ms >= 1000 {
				strings.write_i64(&b, ms / 1000)
				strings.write_string(&b, " s")
			} else {
				strings.write_string(&b, raw)
				strings.write_string(&b, " ms")
			}
		} else {
			strings.write_string(&b, raw)
		}
	}
	if !first do strings.write_byte(&b, ')')
	return strings.to_string(b)
}

// bridge_log_field_raw returns the unparsed scalar after `"key":` in a flat
// object (the stored fields_json is flat by construction).
field_raw :: proc(obj, key: string) -> (string, bool) {
	needle_buf: [48]byte
	if len(key) + 3 > len(needle_buf) do return "", false
	n := copy(needle_buf[:], "\"")
	n += copy(needle_buf[n:], key)
	n += copy(needle_buf[n:], "\":")
	idx := strings.index(obj, string(needle_buf[:n]))
	if idx < 0 do return "", false
	rest := strings.trim_left_space(obj[idx + n:])
	if len(rest) == 0 do return "", false
	if rest[0] == '"' {
		end := strings.index_byte(rest[1:], '"')
		if end < 0 do return "", false
		return rest[:end + 2], true
	}
	end := 0
	for end < len(rest) && rest[end] != ',' && rest[end] != '}' && rest[end] != ' ' do end += 1
	return rest[:end], true
}

// render_class derives the error class (retriable / recoverable / fatal) from the
// code + fields with the same contracts.bridge_error_classify the bridge uses, so
// the class never rides the wire and a hub upgrade alone can refine it. A code
// this hub does not know (stored as "other") is classed from its fields by
// contracts.bridge_error_classify_unknown, so the result is always a valid class.
render_class :: proc(code: string, fields_json: string) -> string {
	c, known := contracts.bridge_log_code_from_name(code)
	reason := contracts.Bridge_Log_Sym.other
	if raw, found := field_raw(fields_json, "reason"); found && len(raw) >= 2 && raw[0] == '"' {
		if sym, sym_ok := contracts.bridge_log_sym_from_name(raw[1:len(raw) - 1]); sym_ok do reason = sym
	}
	hub_status := 0
	if raw, found := field_raw(fields_json, "hub_status"); found {
		if n, n_ok := strconv.parse_int(raw); n_ok do hub_status = n
	}
	if !known do return contracts.bridge_error_class_name(contracts.bridge_error_classify_unknown(reason, hub_status))
	return contracts.bridge_error_class_name(contracts.bridge_error_classify(c, reason, hub_status))
}
