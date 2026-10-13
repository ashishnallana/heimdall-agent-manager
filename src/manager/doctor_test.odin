// Tests for `heimdall doctor` internals (src/manager/doctor.odin): loopback
// probe classification, health-summary rendering, TCP probing, live probes
// against an in-test mock bridge over real TCP, and the installed-unit
// extraction + unit-hub-vs-unit-config check (REQ-INST-9).
//
// The classification strings are pinned to the real bridge contract
// (src/bridge/main.odin:382 401 body, :403 health json), so a drift there
// must update these tests deliberately.
package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import cfg_lib "odin_test:lib/config"

@(test)
test_manager_classify_loopback_probe :: proc(t: ^testing.T) {
	testing.expect(t, manager_classify_loopback_probe(false, false, 0, "") == .Not_Listening, "closed port")
	testing.expect(t, manager_classify_loopback_probe(true, false, 0, "") == .Other_Service, "port open but not HTTP")

	healthy := `{"ok":true,"contract_version":1,"ws_frame_version":2}`
	testing.expect(t, manager_classify_loopback_probe(true, true, 200, healthy) == .Heimdall_Ok, "healthy bridge")

	unauthorized := `{"ok":false,"message":"bridge loopback unauthorized"}`
	testing.expect(t, manager_classify_loopback_probe(true, true, 401, unauthorized) == .Heimdall_Unauthorized, "bridge 401 body")
	testing.expect(t, manager_classify_loopback_probe(true, true, 401, "") == .Heimdall_Unauthorized, "bare 401 status")

	testing.expect(t, manager_classify_loopback_probe(true, true, 200, `{"contract_version":1,"ws_frame_version":2}`) == .Heimdall_Responding, "contract_version-only body")
	testing.expect(t, manager_classify_loopback_probe(true, true, 404, `{"ok":false,"message":"unsupported_route"}`) == .Heimdall_Responding, "unsupported_route body")

	testing.expect(t, manager_classify_loopback_probe(true, true, 200, `{"hello":"world"}`) == .Other_Service, "foreign 200 body")
	testing.expect(t, manager_classify_loopback_probe(true, true, 404, `{"error":"nope"}`) == .Other_Service, "foreign 404 body")
}

@(test)
test_manager_health_summary :: proc(t: ^testing.T) {
	testing.expect(t, manager_health_summary(`{"ok":true,"contract_version":"1","ws_frame_version":"2"}`) == "contract 1, ws frame 2", "contract summary")
	testing.expect(t, manager_health_summary(`{"ok":true}`) == "ok", "summary without contract falls back to ok")
	testing.expect(t, manager_health_summary("") == "ok", "empty body falls back to ok")
}

@(test)
test_manager_tcp_probe :: proc(t: ^testing.T) {
	listener, port, lok := manager_test_loopback_listener()
	testing.expect(t, lok, "loopback listener bound")
	if !lok do return
	testing.expect(t, manager_tcp_probe(port), fmt.tprintf("open port %d probes true", port))
	_ = posix.shutdown(posix.FD(listener), .RDWR)
	net.close(listener)
	testing.expect(t, !manager_tcp_probe(port), fmt.tprintf("closed port %d probes false", port))
}

@(test)
test_manager_probe_bridge_loopback_against_mock :: proc(t: ^testing.T) {
	// Healthy, token-less bridge.
	listener, port, lok := manager_test_loopback_listener()
	testing.expect(t, lok, "loopback listener bound")
	if !lok do return
	mock := new(Manager_Test_Mock_Hub)
	handle := manager_test_mock_hub_start(mock, listener, 200, `{"ok":true,"contract_version":"1","ws_frame_version":"2"}`)
	testing.expect(t, handle != nil, "mock hub thread started")
	if handle == nil {
		net.close(listener)
		free(mock)
		return
	}
	probe, detail := manager_probe_bridge_loopback(port, "")
	manager_test_mock_hub_join(mock, handle)
	defer manager_test_mock_hub_free(mock)
	testing.expect(t, probe == .Heimdall_Ok, fmt.tprintf("healthy classification: %s", detail))
	testing.expect(t, strings.contains(detail, "healthy"), fmt.tprintf("healthy detail: %s", detail))
	testing.expect(t, strings.contains(detail, "contract 1"), fmt.tprintf("healthy detail carries the contract version: %s", detail))

	// Token-protected bridge rejecting a stale token (401).
	listener2, port2, lok2 := manager_test_loopback_listener()
	testing.expect(t, lok2, "second loopback listener bound")
	if !lok2 do return
	mock2 := new(Manager_Test_Mock_Hub)
	handle2 := manager_test_mock_hub_start(mock2, listener2, 401, `{"ok":false,"message":"bridge loopback unauthorized"}`)
	testing.expect(t, handle2 != nil, "second mock hub thread started")
	if handle2 == nil {
		net.close(listener2)
		free(mock2)
		return
	}
	probe2, detail2 := manager_probe_bridge_loopback(port2, "btk_stale")
	manager_test_mock_hub_join(mock2, handle2)
	defer manager_test_mock_hub_free(mock2)
	testing.expect(t, probe2 == .Heimdall_Unauthorized, fmt.tprintf("401 classification: %s", detail2))
	testing.expect(t, strings.contains(detail2, "token required"), fmt.tprintf("401 detail: %s", detail2))
	testing.expect(t, mock2.served == 1, fmt.tprintf("mock hub captured one HTTP request (%d)", mock2.served))
	if mock2.served == 1 {
		testing.expect(t, strings.contains(manager_test_mock_request(mock2, 0), "Authorization: Bearer btk_stale"), "stored token sent on the probe")
	}

	// Nothing listening on the port.
	closed_listener, closed_port, clok := manager_test_loopback_listener()
	if clok {
		_ = posix.shutdown(posix.FD(closed_listener), .RDWR)
		net.close(closed_listener)
	}
	probe3, _ := manager_probe_bridge_loopback(closed_port, "")
	testing.expect(t, probe3 == .Not_Listening, fmt.tprintf("closed port %d classifies as not listening", closed_port))
}

@(test)
test_manager_unit_present :: proc(t: ^testing.T) {
	testing.expect(t, !manager_unit_present(.Unsupported, MANAGER_SERVICE_UNIT, ""), "unsupported platform has no unit")

	// A unit name that cannot exist reports absent (deterministic even when
	// systemctl is missing: run_capture then fails and reports absent too).
	testing.expect(t, !manager_unit_present(.Linux, "heimdall-manager-missing-unit-xyz", ""), "missing systemd unit reports absent")

	tmp := manager_test_tmp_dir("unit-plist")
	defer manager_test_cleanup(tmp)
	plist := fmt.tprintf("%s/works.earendil.heimdall-bridge.plist", tmp)
	testing.expect(t, !manager_unit_present(.Darwin, "", plist), "missing launchd plist reports absent")
	testing.expect(t, os.write_entire_file(plist, "<plist/>") == nil, "write fake plist")
	testing.expect(t, manager_unit_present(.Darwin, "", plist), "present launchd plist reports present")
}

// ---- REQ-INST-9: unit-baked hub extraction ----

// MANAGER_TEST_INSTALL_SYSTEMD_UNIT is scripts/install.sh:102-126 rendered with
// install_dir=/opt/heimdall: the ExecStart continuation form plus the
// https://hub.example.com placeholder the installer bakes when it ran without
// --hub (install.sh:100).
MANAGER_TEST_INSTALL_SYSTEMD_UNIT :: `[Unit]
Description=Heimdall Bridge
After=network-online.target

[Service]
Type=simple
ExecStart=/opt/heimdall/ham-bridge \
    --hub https://hub.example.com \
    --bridge-token-file %h/.config/heimdall/bridge-token \
    --port 49323 \
    --local-endpoint-port 49324 \
    --local-run-dir /tmp/heimdall-bridge-local
Environment=HEIMDALL_HAM_PTY_HOST_BIN=/opt/heimdall/ham-pty-host
Environment=HEIMDALL_BRIDGE_PTY_HOST=true
Environment=HEIMDALL_HAM_CTL_BIN=/opt/heimdall/ham-ctl
Restart=on-failure
RestartSec=5s
KillMode=process

[Install]
WantedBy=default.target
`

// MANAGER_TEST_INSTALL_PLIST is scripts/install.sh:129-175 rendered with
// install_dir=/opt/heimdall: the bridge argv in the ProgramArguments array.
MANAGER_TEST_INSTALL_PLIST :: `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>works.earendil.heimdall-bridge</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/heimdall/ham-bridge</string>
    <string>--hub</string>
    <string>https://hub.example.com</string>
    <string>--bridge-token-file</string>
    <string>/Users/x/.config/heimdall/bridge-token</string>
    <string>--port</string>
    <string>49323</string>
    <string>--local-endpoint-port</string>
    <string>49324</string>
    <string>--local-run-dir</string>
    <string>/tmp/heimdall-bridge-local</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HEIMDALL_HAM_PTY_HOST_BIN</key>
    <string>/opt/heimdall/ham-pty-host</string>
    <key>HEIMDALL_BRIDGE_PTY_HOST</key>
    <string>true</string>
    <key>HEIMDALL_HAM_CTL_BIN</key>
    <string>/opt/heimdall/ham-ctl</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>Crashed</key>
    <true/>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardOutPath</key>
  <string>/tmp/heimdall-logs/heimdall-bridge.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/heimdall-logs/heimdall-bridge.err.log</string>
</dict>
</plist>
`

// Manager_Test_Unit_Hub_Case drives test_manager_unit_flags: the shapes the
// T4 acceptance names (installer continuation form, plist array, --daemon-url
// alias, no flag, placeholder) plus decoy shapes the parsers must ignore, and
// the --config flag the unit passes to pick the config it loads.
Manager_Test_Unit_Hub_Case :: struct {
	name:         string,
	platform:     Manager_Platform,
	text:         string,
	url:          string,
	found:        bool,
	config:       string,
	config_found: bool,
}

@(test)
test_manager_unit_hub_flag :: proc(t: ^testing.T) {
	cases := []Manager_Test_Unit_Hub_Case {
		{
			name = "systemd: install.sh continuation form with the placeholder",
			platform = .Linux,
			text = MANAGER_TEST_INSTALL_SYSTEMD_UNIT,
			url = "https://hub.example.com",
			found = true,
		},
		{
			// The acceptance machine's real shape: a nix-managed unit passing
			// its own --config plus --hub, verbatim store paths (unit and
			// config agree on https://hub.mundus.in).
			name = "systemd: systemctl cat header + real store-path ExecStart with --config and --hub",
			platform = .Linux,
			text = `# /etc/systemd/user/heimdall-bridge.service -> /nix/store/25mpj4qns6w4kx9vbprbz50gn85dxbvg-unit-heimdall-bridge.service/heimdall-bridge.service
[Unit]
After=network-online.target
Description=Heimdall bridge connected to hub.mundus.in
Wants=network-online.target

[Service]
Environment="TZDIR=/nix/store/p0ff33dca0fbkskqwrl3spvxcn5974h0-tzdata-2026c/share/zoneinfo"
ExecStart=/nix/store/pjh6wfzy7mi6ca4vc4i6rna06q2f8cg6-ham-bridge-0.1.0/bin/ham-bridge --config /nix/store/93jd6ncws19marlb55c8hk9d28l0kx02-heimdall-bridge-prod-config.toml --hub https://hub.mundus.in --bridge-token-file /var/lib/heimdall-bridge/bridge-token --local-run-dir /var/lib/heimdall-bridge/runtime --fs-read-page-bytes 131072
Restart=always
RestartSec=5s
WorkingDirectory=/home/tanmay

[Install]
WantedBy=default.target
`,
			url = "https://hub.mundus.in",
			found = true,
			config = "/nix/store/93jd6ncws19marlb55c8hk9d28l0kx02-heimdall-bridge-prod-config.toml",
			config_found = true,
		},
		{
			name = "systemd: --daemon-url alias",
			platform = .Linux,
			text = `[Service]
ExecStart=/opt/heimdall/ham-bridge --daemon-url https://hub.internal:9000 --port 49323
`,
			url = "https://hub.internal:9000",
			found = true,
		},
		{
			name = "systemd: --hub wins over --daemon-url",
			platform = .Linux,
			text = `[Service]
ExecStart=/opt/heimdall/ham-bridge --daemon-url http://old.example --hub https://new.example
`,
			url = "https://new.example",
			found = true,
		},
		{
			name = "systemd: continuation form with --config and --hub",
			platform = .Linux,
			text = `[Service]
ExecStart=/opt/heimdall/ham-bridge \
    --config /etc/heimdall/prod.toml \
    --hub https://hub.internal:9000 \
    --port 49323
`,
			url = "https://hub.internal:9000",
			found = true,
			config = "/etc/heimdall/prod.toml",
			config_found = true,
		},
		{
			name = "systemd: trailing --config without a value is ignored",
			platform = .Linux,
			text = `[Service]
ExecStart=/opt/heimdall/ham-bridge --port 49323 --config
`,
			url = "",
			found = false,
		},
		{
			name = "systemd: no hub flag at all (continuation form)",
			platform = .Linux,
			text = `[Service]
ExecStart=/opt/heimdall/ham-bridge \
    --port 49323 \
    --local-endpoint-port 49324
`,
			url = "",
			found = false,
		},
		{
			name = "systemd: trailing --hub without a value is ignored",
			platform = .Linux,
			text = `[Service]
ExecStart=/opt/heimdall/ham-bridge --port 49323 --hub
`,
			url = "",
			found = false,
		},
		{
			name = "systemd: comment and Environment mentioning --hub are not argv",
			platform = .Linux,
			text = `# --hub https://decoy.example
[Service]
Environment=NOTE=--hub https://decoy.example
ExecStart=/opt/heimdall/ham-bridge --port 49323
`,
			url = "",
			found = false,
		},
		{
			name = "plist: install.sh ProgramArguments array with the placeholder",
			platform = .Darwin,
			text = MANAGER_TEST_INSTALL_PLIST,
			url = "https://hub.example.com",
			found = true,
		},
		{
			name = "plist: --daemon-url alias",
			platform = .Darwin,
			text = `<plist version="1.0">
<dict>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/heimdall/ham-bridge</string>
    <string>--daemon-url</string>
    <string>https://hub.internal:9000</string>
  </array>
</dict>
</plist>
`,
			url = "https://hub.internal:9000",
			found = true,
		},
		{
			name = "plist: --config with --hub",
			platform = .Darwin,
			text = `<plist version="1.0">
<dict>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/heimdall/ham-bridge</string>
    <string>--config</string>
    <string>/etc/heimdall/prod.toml</string>
    <string>--hub</string>
    <string>https://hub.internal:9000</string>
  </array>
</dict>
</plist>
`,
			url = "https://hub.internal:9000",
			found = true,
			config = "/etc/heimdall/prod.toml",
			config_found = true,
		},
		{
			name = "plist: no hub flag",
			platform = .Darwin,
			text = `<plist version="1.0">
<dict>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/heimdall/ham-bridge</string>
    <string>--port</string>
    <string>49323</string>
  </array>
</dict>
</plist>
`,
			url = "",
			found = false,
		},
		{
			name = "plist: trailing --hub without a value is ignored",
			platform = .Darwin,
			text = `<plist version="1.0">
<dict>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/heimdall/ham-bridge</string>
    <string>--port</string>
    <string>49323</string>
    <string>--hub</string>
  </array>
</dict>
</plist>
`,
			url = "",
			found = false,
		},
		{
			name = "plist: array before ProgramArguments must not be scanned",
			platform = .Darwin,
			text = `<plist version="1.0">
<dict>
  <key>Unrelated</key>
  <array>
    <string>--hub</string>
    <string>https://decoy.example</string>
  </array>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/heimdall/ham-bridge</string>
    <string>--hub</string>
    <string>https://real.example</string>
  </array>
</dict>
</plist>
`,
			url = "https://real.example",
			found = true,
		},
		{
			name = "unsupported platform has no unit text to scan",
			platform = .Unsupported,
			text = MANAGER_TEST_INSTALL_SYSTEMD_UNIT,
			url = "",
			found = false,
		},
	}
	for c in cases {
		flags := manager_unit_flags(c.text, c.platform)
		url, found := manager_pick_unit_hub(flags)
		testing.expect(t, found == c.found && url == c.url && flags.config_found == c.config_found && flags.config == c.config, fmt.tprintf("%s: got (url=%q found=%v config=%q config_found=%v), want (url=%q found=%v config=%q config_found=%v)", c.name, url, found, flags.config, flags.config_found, c.url, c.found, c.config, c.config_found))
	}
}

@(test)
test_manager_unit_config_path :: proc(t: ^testing.T) {
	sync.mutex_lock(&manager_test_env_mutex)
	defer sync.mutex_unlock(&manager_test_env_mutex)
	tmp := manager_test_tmp_dir("unit-config-path")
	defer manager_test_cleanup(tmp)
	previous := os.get_env("HEIMDALL_HOME", context.allocator)
	defer {
		if previous != "" do os.set_env("HEIMDALL_HOME", previous)
		else do os.unset_env("HEIMDALL_HOME")
	}
	os.set_env("HEIMDALL_HOME", tmp)

	absolute := manager_unit_config_path("/etc/heimdall/prod.toml", true)
	testing.expect(t, absolute == "/etc/heimdall/prod.toml", fmt.tprintf("unit --config wins: %s", absolute))
	expanded := manager_unit_config_path("~/prod.toml", true)
	testing.expect(t, expanded == fmt.tprintf("%s/prod.toml", tmp), fmt.tprintf("unit --config ~ expands like the bridge: %s", expanded))
	fallback := manager_unit_config_path("", false)
	testing.expect(t, fallback == fmt.tprintf("%s/config.toml", tmp), fmt.tprintf("no --config falls back to the shared default path: %s", fallback))
	blank := manager_unit_config_path("   ", true)
	testing.expect(t, blank == fmt.tprintf("%s/config.toml", tmp), fmt.tprintf("blank --config is treated as absent: %s", blank))
}

// Manager_Test_Unit_Hub_Check_Case drives test_manager_unit_hub_check. The
// default hub value is read from the config package (config.odin:833) instead
// of being hardcoded here, so a change there must update nothing.
Manager_Test_Unit_Hub_Check_Case :: struct {
	name:            string,
	unit_hub:        string,
	unit_hub_found:  bool,
	config_path:     string,
	config_hub:      string,
	config_readable: bool,
	want_status:     Manager_Check_Status,
	want_contains:   []string,
	want_absent:     []string,
}

@(test)
test_manager_unit_hub_check :: proc(t: ^testing.T) {
	default_hub := cfg_lib.default_config().wrapper.daemon_url
	unit_label := "systemd user unit heimdall-bridge"
	cases := []Manager_Test_Unit_Hub_Check_Case {
		{
			name = "no flag: hub comes from the unit's config",
			config_path = "/etc/heimdall/config.toml",
			config_hub = "https://hub.internal:9000",
			config_readable = true,
			want_status = .Ok,
			want_contains = []string{"/etc/heimdall/config.toml", "https://hub.internal:9000"},
		},
		{
			name = "flag matches the unit's config",
			unit_hub = "https://hub.internal:9000",
			unit_hub_found = true,
			config_path = "/etc/heimdall/config.toml",
			config_hub = "https://hub.internal:9000",
			config_readable = true,
			want_status = .Ok,
			want_contains = []string{"https://hub.internal:9000", "/etc/heimdall/config.toml"},
		},
		{
			name = "flag matches the unit's config after trailing-slash normalization",
			unit_hub = "https://hub.internal:9000/",
			unit_hub_found = true,
			config_path = "/etc/heimdall/config.toml",
			config_hub = "https://hub.internal:9000",
			config_readable = true,
			want_status = .Ok,
			want_contains = []string{"/etc/heimdall/config.toml"},
		},
		{
			name = "mismatch fails and names both hubs plus the exact remediation",
			unit_hub = "https://old.example",
			unit_hub_found = true,
			config_path = "/etc/heimdall/config.toml",
			config_hub = "https://hub.internal:9000",
			config_readable = true,
			want_status = .Fail,
			want_contains = []string{"https://old.example", "https://hub.internal:9000", "/etc/heimdall/config.toml", "scripts/install.sh --hub https://hub.internal:9000"},
			want_absent = []string{"placeholder"},
		},
		{
			name = "placeholder hub fails with its own message",
			unit_hub = MANAGER_UNIT_PLACEHOLDER_HUB,
			unit_hub_found = true,
			config_path = "/etc/heimdall/config.toml",
			config_hub = "https://hub.internal:9000",
			config_readable = true,
			want_status = .Fail,
			want_contains = []string{"placeholder", MANAGER_UNIT_PLACEHOLDER_HUB, "/etc/heimdall/config.toml"},
			want_absent = []string{"https://hub.internal:9000"},
		},
		{
			name = "placeholder fails even when the unit's config is unreadable",
			unit_hub = MANAGER_UNIT_PLACEHOLDER_HUB,
			unit_hub_found = true,
			config_path = "/etc/heimdall/missing.toml",
			config_readable = false,
			want_status = .Fail,
			want_contains = []string{"placeholder", MANAGER_UNIT_PLACEHOLDER_HUB},
		},
		{
			name = "placeholder still fails when the config carries the default hub",
			unit_hub = MANAGER_UNIT_PLACEHOLDER_HUB,
			unit_hub_found = true,
			config_path = "/etc/heimdall/config.toml",
			config_hub = default_hub,
			config_readable = true,
			want_status = .Fail,
			want_contains = []string{"placeholder"},
		},
		{
			name = "unreadable unit config warns",
			unit_hub = "https://hub.internal:9000",
			unit_hub_found = true,
			config_path = "/etc/heimdall/missing.toml",
			config_readable = false,
			want_status = .Warn,
			want_contains = []string{"/etc/heimdall/missing.toml", "https://hub.internal:9000"},
		},
		{
			name = "no flag and unreadable unit config warns",
			config_path = "/etc/heimdall/missing.toml",
			config_readable = false,
			want_status = .Warn,
			want_contains = []string{"/etc/heimdall/missing.toml", "cannot compare"},
		},
		{
			name = "empty config hub warns as not enrolled",
			unit_hub = "https://hub.internal:9000",
			unit_hub_found = true,
			config_path = "/etc/heimdall/config.toml",
			config_hub = "",
			config_readable = true,
			want_status = .Warn,
			want_contains = []string{"/etc/heimdall/config.toml", "empty [wrapper] daemon_url", "ham-bridge enroll"},
		},
		{
			name = "empty config hub without a unit flag warns as not enrolled",
			config_path = "/etc/heimdall/config.toml",
			config_hub = "",
			config_readable = true,
			want_status = .Warn,
			want_contains = []string{"/etc/heimdall/config.toml", "empty [wrapper] daemon_url", "ham-bridge enroll"},
		},
		{
			// config.odin:833 sentinel: the node was never enrolled. The unit
			// driving the bridge is the coordinator correction's case; it must
			// warn, never fail, and never read as a hub mismatch.
			name = "default hub in config plus a real unit hub warns as never enrolled",
			unit_hub = "https://hub.internal:9000",
			unit_hub_found = true,
			config_path = "/etc/heimdall/config.toml",
			config_hub = default_hub,
			config_readable = true,
			want_status = .Warn,
			want_contains = []string{default_hub, "https://hub.internal:9000", "/etc/heimdall/config.toml", "ham-bridge enroll"},
			want_absent = []string{"placeholder"},
		},
		{
			name = "default hub in config without a unit flag warns as never enrolled",
			config_path = "/etc/heimdall/config.toml",
			config_hub = default_hub,
			config_readable = true,
			want_status = .Warn,
			want_contains = []string{default_hub, "/etc/heimdall/config.toml", "ham-bridge enroll"},
		},
	}
	for c in cases {
		status, detail := manager_unit_hub_check(unit_label, c.unit_hub, c.unit_hub_found, c.config_path, c.config_hub, c.config_readable)
		testing.expect(t, status == c.want_status, fmt.tprintf("%s: status %v, want %v (detail: %s)", c.name, status, c.want_status, detail))
		testing.expect(t, strings.contains(detail, unit_label), fmt.tprintf("%s: detail names the inspected scope: %s", c.name, detail))
		for needle in c.want_contains {
			testing.expect(t, strings.contains(detail, needle), fmt.tprintf("%s: detail must contain %q: %s", c.name, needle, detail))
		}
		for needle in c.want_absent {
			testing.expect(t, !strings.contains(detail, needle), fmt.tprintf("%s: detail must not contain %q: %s", c.name, needle, detail))
		}
	}

	// The Darwin scope label is the only other shape the label takes.
	status, detail := manager_unit_hub_check("LaunchAgent plist /Users/x/Library/LaunchAgents/works.earendil.heimdall-bridge.plist", "https://hub.internal:9000", true, "/Users/x/.config/heimdall/config.toml", "https://hub.internal:9000", true)
	testing.expect(t, status == .Ok, fmt.tprintf("LaunchAgent match is ok: %s", detail))
	testing.expect(t, strings.contains(detail, "LaunchAgent plist"), fmt.tprintf("LaunchAgent scope named: %s", detail))
}
