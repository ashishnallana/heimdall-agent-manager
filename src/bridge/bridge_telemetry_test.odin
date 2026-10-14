package main

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

@(test)
test_bridge_telemetry_hydration :: proc(t: ^testing.T) {
	tpl := `[global_tags]
  bridge_id = "${HEIMDALL_BRIDGE_ID}"
  bridge_host = "${HOSTNAME}"
[[outputs.prometheus_client]]
  listen = "127.0.0.1:${TELEMETRY_PORT:-9273}"
  port = "${TELEMETRY_PORT}"`

	hydrated := bridge_telemetry_hydrate_template(tpl, "brg_abc123", "test-host.local", "9555", context.allocator)
	defer delete(hydrated)

	testing.expect(t, strings.contains(hydrated, `bridge_id = "brg_abc123"`), "bridge_id hydrated")
	testing.expect(t, strings.contains(hydrated, `bridge_host = "test-host.local"`), "hostname hydrated")
	testing.expect(t, strings.contains(hydrated, `listen = "127.0.0.1:9555"`), "default port token hydrated")
	testing.expect(t, strings.contains(hydrated, `port = "9555"`), "plain port token hydrated")
	testing.expect(t, !strings.contains(hydrated, "${"), "no unhydrated variables remaining")
}

@(test)
test_bridge_telemetry_conf_path :: proc(t: ^testing.T) {
	p := bridge_telemetry_conf_path("brg/test:special@1")
	defer delete(p)
	testing.expect_value(t, p, "/tmp/heimdall-telegraf-brg_test_special@1.conf")
}

@(test)
test_bridge_telemetry_agents_count_endpoints :: proc(t: ^testing.T) {
	testing.expect(t, bridge_telemetry_looks_like_agents_count("GET /api/v1/telemetry/agents-count HTTP/1.1"), "valid GET matches")
	testing.expect(t, bridge_telemetry_looks_like_agents_count("GET /api/v1/telemetry/agents-count"), "valid prefix matches")
	testing.expect(t, !bridge_telemetry_looks_like_agents_count("POST /api/v1/telemetry/agents-count HTTP/1.1"), "POST does not match")
	testing.expect(t, !bridge_telemetry_looks_like_agents_count("GET /api/v1/other HTTP/1.1"), "other path does not match")

	json := bridge_telemetry_agents_count_json()
	defer delete(json)
	testing.expect(t, strings.has_prefix(json, "{\"active_count\":"), "json has active_count field")

	resp := bridge_telemetry_agents_count_http_response()
	defer delete(resp)
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 200 OK\r\n"), "valid HTTP 200 header")
	testing.expect(t, strings.contains(resp, "Content-Type: application/json\r\n"), "valid Content-Type")
	testing.expect(t, strings.contains(resp, "{\"active_count\":"), "valid body embedded")
}

@(test)
test_bridge_telemetry_agent_api :: proc(t: ^testing.T) {
	testing.expect(t, bridge_agent_method_allowed("agent.telemetry.agents_count"), "telemetry method is allowlisted")

	rec := Bridge_Local_Agent_Token_Record{
		role = .Agent,
		agent_instance_id = "inst_test",
	}
	resp := bridge_local_handle_agent_local_op("req_tel_test", "telemetry.agents_count", "{}", rec)
	defer delete(resp)
	testing.expect(t, strings.contains(resp, "\"ok\":true"), "op succeeded")
	testing.expect(t, strings.contains(resp, "\"active_count\":"), "contains active_count in payload")
}

@(test)
test_bridge_telemetry_command_toggle :: proc(t: ^testing.T) {
	// set_telemetry flips process-global switches (Telegraf supervisor and the
	// heartbeat-stats/bridge_log switch); serialize with the other tests that
	// read or toggle them.
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	// Calling set_telemetry with false stops supervisor and reports stopped
	bridge_hub_handle_command(nil, `{"type":"set_telemetry","command_id":"cmd_tel_off","enabled":false}`)
	testing.expect(t, !bridge_telemetry_status(), "telemetry status is false after stop command")
}

@(test)
test_bridge_telemetry_lifecycle :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	os.set_env("TELEMETRY_PORT", "29871")
	bridge_config.daemon_id = "test-daemon-lifecycle"

	// Ensure stopped to begin
	_ = bridge_telemetry_stop()
	testing.expect(t, !bridge_telemetry_status(), "initially stopped")

	// Start supervisor
	started := bridge_telemetry_start()
	testing.expect(t, started, "telegraf started successfully")
	testing.expect(t, bridge_telemetry_status(), "status reports running")

	conf_path := bridge_telemetry_conf_path("test-daemon-lifecycle")
	defer delete(conf_path)
	testing.expect(t, os.exists(conf_path), "configuration file was generated on disk")

	// Second start is idempotent and returns true
	testing.expect(t, bridge_telemetry_start(), "idempotent start returns true")
	testing.expect(t, bridge_telemetry_status(), "still running")

	// Stop supervisor
	stopped := bridge_telemetry_stop()
	testing.expect(t, stopped, "telegraf stopped cleanly with SIGTERM")
	testing.expect(t, !bridge_telemetry_status(), "status reports stopped")
	testing.expect(t, !os.exists(conf_path), "configuration file was removed on stop")
}
