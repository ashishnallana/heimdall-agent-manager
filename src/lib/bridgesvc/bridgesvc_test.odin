package bridgesvc

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_canonical_hub_and_service_name :: proc(t: ^testing.T) {
	cases := [?]struct {
		raw, url, name: string,
	}{
		{"https://Hub.Example.com/", "https://hub.example.com", "hub-example-com"},
		{"https://hub.example.com:443/prefix", "https://hub.example.com", "hub-example-com"},
		{"http://localhost:8989", "http://localhost:8989", "localhost-8989"},
		{"http://10.0.0.5:80", "http://10.0.0.5", "10-0-0-5"},
		{"  https://hub.example.com.  ", "https://hub.example.com", "hub-example-com"},
	}
	for c in cases {
		url, name, ok := canonical_hub(c.raw, context.temp_allocator)
		testing.expectf(t, ok, "canonical_hub(%q) failed", c.raw)
		testing.expect_value(t, url, c.url)
		testing.expect_value(t, name, c.name)
	}
	for bad in ([?]string{"", "ftp://x", "https://", "https://u@h", "https://h:0", "https://h:70000", "https://h_x"}) {
		_, _, ok := canonical_hub(bad, context.temp_allocator)
		testing.expectf(t, !ok, "canonical_hub(%q) accepted", bad)
	}
	p, ok := profile_from("https://hub.example.com", "work", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, p.service_name, "heimdall-bridge-hub-example-com_work")
	d, _ := profile_from("https://hub.example.com", "", context.temp_allocator)
	testing.expect_value(t, d.service_name, "heimdall-bridge-hub-example-com")
	_, bad_ok := profile_from("https://hub.example.com", "Work_1", context.temp_allocator)
	testing.expect(t, !bad_ok)
}

@(test)
test_valid_profile :: proc(t: ^testing.T) {
	testing.expect(t, valid_profile("a"))
	testing.expect(t, valid_profile("team-2"))
	testing.expect(t, valid_profile(strings.repeat("a", 31, context.temp_allocator)))
	testing.expect(t, !valid_profile(strings.repeat("a", 32, context.temp_allocator)))
	testing.expect(t, !valid_profile("-x"))
	testing.expect(t, !valid_profile("A"))
	testing.expect(t, !valid_profile("a_b"))
	testing.expect(t, !valid_profile(""))
}

@(test)
test_layout_and_argv_per_os :: proc(t: ^testing.T) {
	name := "heimdall-bridge-hub-example-com_work"
	linux := Host{os = .Linux, home = "/home/u", uid = 1000}
	l := layout_for(linux, name)
	testing.expect_value(t, l.state_dir, "/home/u/.config/heimdall/bridges/" + "heimdall-bridge-hub-example-com_work")
	testing.expect_value(t, l.service_file, "/home/u/.config/systemd/user/heimdall-bridge-hub-example-com_work.service")
	testing.expect_value(t, strings.join(service_argv(linux, l, .Restart), " ", context.temp_allocator), "systemctl --user restart heimdall-bridge-hub-example-com_work.service")

	mac := Host{os = .Darwin, home = "/Users/u", uid = 501}
	m := layout_for(mac, name)
	testing.expect_value(t, m.service_file, "/Users/u/Library/LaunchAgents/heimdall-bridge-hub-example-com_work.plist")
	testing.expect_value(t, strings.join(service_argv(mac, m, .Restart), " ", context.temp_allocator), "launchctl kickstart -k gui/501/heimdall-bridge-hub-example-com_work")
	testing.expect_value(t, service_argv(mac, m, .Start)[1], "bootstrap")

	win := Host{os = .Windows, appdata = "C:/U/AppData/Roaming", local_appdata = "C:/U/AppData/Local"}
	w := layout_for(win, name)
	testing.expect(t, strings.has_suffix(w.state_dir, "Roaming/heimdall/bridges/heimdall-bridge-hub-example-com_work"))
	testing.expect(t, strings.has_suffix(w.bin_dir, "Local/heimdall/bridges/heimdall-bridge-hub-example-com_work/bin"))
	testing.expect_value(t, strings.join(service_argv(win, w, .Start), " ", context.temp_allocator), "schtasks /Run /TN \\heimdall-bridge-hub-example-com_work")
	state := windows_task_state_argv(w)
	testing.expect_value(t, state[0], "powershell.exe")
	testing.expect_value(t, state[len(state) - 1], "(Get-ScheduledTask -TaskPath '\\' -TaskName 'heimdall-bridge-hub-example-com_work').State")
	testing.expect(t, strings.contains(windows_task_state_argv(Layout{service_name = "heimdall-bridge-x'y"})[4], "'heimdall-bridge-x''y'"))

	termux := Host{os = .Termux, home = "/data/home", prefix = "/data/usr"}
	r := layout_for(termux, name)
	testing.expect_value(t, strings.join(service_argv(termux, r, .Restart), " ", context.temp_allocator), "sv restart /data/usr/var/service/heimdall-bridge-hub-example-com_work")
	testing.expect(t, service_argv(Host{}, Layout{}, .Start) == nil)
}

@(private = "file")
test_busy_ports: [dynamic]int

@(private = "file")
fake_busy :: proc(port: int) -> bool {
	for p in test_busy_ports do if p == port do return true
	return false
}

@(private = "file")
make_temp_root :: proc(t: ^testing.T, tag: string) -> string {
	root := fmt.tprintf("/tmp/bridgesvc-%s-%d", tag, os.get_pid())
	_ = os.remove_all(root)
	testing.expect(t, os.make_directory_all(root) == nil)
	return root
}

@(test)
test_allocate_ports_per_profile :: proc(t: ^testing.T) {
	root := make_temp_root(t, "ports")
	defer os.remove_all(root)
	a := pjoin(root, "heimdall-bridge-a")
	b := pjoin(root, "heimdall-bridge-b")
	test_busy_ports = make([dynamic]int, context.temp_allocator)

	pa, reused_a, ok := allocate_ports(root, a, fake_busy)
	testing.expect(t, ok)
	testing.expect(t, !reused_a)
	testing.expect_value(t, pa, [2]int{49323, 49324})
	// A second profile never takes the first one's recorded pair.
	pb, _, okb := allocate_ports(root, b, fake_busy)
	testing.expect(t, okb)
	testing.expect_value(t, pb, [2]int{49325, 49326})
	// Re-running keeps the persisted pair (idempotent).
	pa2, reused_a2, _ := allocate_ports(root, a, fake_busy)
	testing.expect_value(t, pa2, pa)
	testing.expect(t, reused_a2)
	persisted, rok := read_ports(a)
	testing.expect(t, rok)
	testing.expect_value(t, persisted, pa)
	// Port in use (another OS user's bridge): move on and persist the new pair.
	append(&test_busy_ports, 49323)
	pa3, reused_a3, _ := allocate_ports(root, a, fake_busy)
	testing.expect(t, !reused_a3)
	testing.expect_value(t, pa3, [2]int{49327, 49324})
	p4, _ := read_ports(a)
	testing.expect_value(t, p4, pa3)
}

@(test)
test_parse_ports :: proc(t: ^testing.T) {
	p, ok := parse_ports(" [49323, 49324]\n")
	testing.expect(t, ok)
	testing.expect_value(t, p, [2]int{49323, 49324})
	for bad in ([?]string{"[]", "[1]", "[49323,49323]", "[80, 81]", "49323,49324", "[a,b]", "[1,2,3]"}) {
		_, bok := parse_ports(bad)
		testing.expectf(t, !bok, "parse_ports(%q) accepted", bad)
	}
}

@(test)
test_status_json_from_state_dir :: proc(t: ^testing.T) {
	home := make_temp_root(t, "status")
	defer os.remove_all(home)
	host := Host{os = .Linux, home = home, uid = 1000}
	name := "heimdall-bridge-hub-example-com_work"
	l := layout_for(host, name)
	testing.expect(t, os.make_directory_all(l.state_dir) == nil)

	// Nothing installed yet.
	s0 := gather_status(host, name, time.now())
	testing.expect(t, !s0.installed && !s0.enrolled && !s0.connected)
	testing.expect_value(t, s0.vault, "unknown")

	testing.expect(t, os.make_directory_all(pdir(l.service_file)) == nil)
	_ = os.write_entire_file_from_string(l.service_file, string("[Unit]\n"))
	_ = os.write_entire_file(pjoin(l.state_dir, HUB_URL_FILE), transmute([]u8)string("https://hub.example.com\n"))
	_ = os.write_entire_file(pjoin(l.state_dir, PROFILE_FILE), transmute([]u8)string("work\n"))
	_ = os.write_entire_file(pjoin(l.state_dir, TOKEN_FILE), transmute([]u8)string("heimdall-bridge-credential/v1 s3cret brg_abc123\n"))
	_ = os.write_entire_file(pjoin(l.state_dir, PORTS_FILE), transmute([]u8)string("[49325, 49326]\n"))
	now := time.now()
	rt := Runtime_Status{pid = 42, connected = true, vault = "unlocked", version = "0.5.18", bridge_id = "brg_abc123", updated_at = time.to_unix_seconds(now)}
	_ = os.write_entire_file(pjoin(l.state_dir, RUNTIME_STATUS_FILE), transmute([]u8)runtime_status_json(rt, context.temp_allocator))

	s := gather_status(host, name, now)
	testing.expect(t, s.installed && s.enrolled && s.connected)
	testing.expect_value(t, s.hub, "https://hub.example.com")
	testing.expect_value(t, s.profile, "work")
	testing.expect_value(t, s.vault, "unlocked")
	testing.expect_value(t, s.version, "0.5.18")
	testing.expect_value(t, s.bridge_id, "brg_abc123")
	testing.expect_value(t, s.bridge_port, 49325)

	// The JSON carries every documented field and never the secret.
	text := status_json(s, context.temp_allocator)
	testing.expect(t, !strings.contains(text, "s3cret"))
	v, err := json.parse_string(text, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	obj := v.(json.Object)
	for key in ([?]string{"installed", "enrolled", "connected", "vault", "version", "profile", "hub", "service", "running", "bridge_port", "endpoint_port"}) {
		_, has := obj[key]
		testing.expectf(t, has, "status json lacks %q: %s", key, text)
	}

	// A stale runtime file does not claim a live connection.
	stale := gather_status(host, name, time.time_add(now, 2 * RUNTIME_STATUS_MAX_AGE))
	testing.expect(t, !stale.connected)

	// After setup restarts the bridge, the replaced bridge's file (pid 42, never
	// rewritten because it was SIGTERMed) and anything older than the restart do
	// not count; the new bridge's first write does.
	restart := time.to_unix_seconds(now)
	testing.expect(t, !gather_status(host, name, now, restart, 42).connected)
	testing.expect(t, !gather_status(host, name, now, restart + 5, 0).connected)
	rt.pid = 43
	_ = os.write_entire_file(pjoin(l.state_dir, RUNTIME_STATUS_FILE), transmute([]u8)runtime_status_json(rt, context.temp_allocator))
	testing.expect(t, gather_status(host, name, now, restart, 42).connected)
	r2, rok := read_runtime_status(l.state_dir)
	testing.expect(t, rok && r2.pid == 43)

	names := list_services(host)
	testing.expect_value(t, len(names), 1)
	testing.expect_value(t, names[0], name)
	lj := list_json([]Status{s}, context.temp_allocator)
	testing.expect(t, strings.has_prefix(lj, `{"profiles":[{`))
}

@(test)
test_hub_from_legacy_config :: proc(t: ^testing.T) {
	root := make_temp_root(t, "cfg")
	defer os.remove_all(root)
	path := pjoin(root, "config.toml")
	_ = os.write_entire_file_from_string(path, string("[daemon]\nurl = \"https://hub.example.com\"\n"))
	testing.expect_value(t, hub_from_config(path), "https://hub.example.com")
}
