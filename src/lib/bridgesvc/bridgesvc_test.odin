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

@(test)
test_needs_reenrollment_marker_and_state :: proc(t: ^testing.T) {
	home := make_temp_root(t, "reenroll")
	defer os.remove_all(home)
	host := Host{os = .Linux, home = home, uid = 1000}
	name := "heimdall-bridge-hub-example-com"
	l := layout_for(host, name)
	testing.expect(t, os.make_directory_all(l.state_dir) == nil)
	testing.expect(t, os.make_directory_all(pdir(l.service_file)) == nil)
	_ = os.write_entire_file_from_string(l.service_file, "[Unit]\n")
	_ = os.write_entire_file_from_string(pjoin(l.state_dir, TOKEN_FILE), "heimdall-bridge-credential/v1 s3cret brg_old\n")
	testing.expect_value(t, gather_status(host, name, time.now()).state, "stopped")

	// A revoked bridge: stable needs_reenrollment with its recovery command.
	m := Reenroll_Marker{bridge_id = "brg_old", hub = "https://hub.example.com", reason = "revoked", hint = "ham-bridge enroll --hub https://hub.example.com", at = 1}
	testing.expect(t, write_reenroll_marker(l.state_dir, m))
	testing.expect(t, !os.exists(pjoin(l.state_dir, NEEDS_REENROLL_FILE + ".tmp")), "no temp file left")
	s := gather_status(host, name, time.now())
	testing.expect(t, s.needs_reenrollment)
	testing.expect_value(t, s.state, "needs_reenrollment")
	testing.expect_value(t, s.reenroll_reason, "revoked")
	text := status_json(s, context.temp_allocator)
	testing.expect(t, strings.contains(text, `"state":"needs_reenrollment"`), text)
	testing.expect(t, strings.contains(text, `"reenroll_hint":"ham-bridge enroll --hub https://hub.example.com"`), text)
	testing.expect(t, !strings.contains(text, "s3cret"))

	// Credential deleted by a rejected refresh: still needs re-enrollment, and the
	// marker names the bridge.
	_ = os.remove(pjoin(l.state_dir, TOKEN_FILE))
	s2 := gather_status(host, name, time.now())
	testing.expect(t, s2.needs_reenrollment)
	testing.expect_value(t, s2.bridge_id, "brg_old")

	// A newly enrolled bridge makes an old bridge's marker moot.
	_ = os.write_entire_file_from_string(pjoin(l.state_dir, TOKEN_FILE), "heimdall-bridge-credential/v1 s3cret brg_new\n")
	testing.expect(t, !gather_status(host, name, time.now()).needs_reenrollment)
	testing.expect(t, reenroll_marker_applies(m, false, ""))
	testing.expect(t, reenroll_marker_applies(m, true, "brg_old"))
	testing.expect(t, !reenroll_marker_applies(m, true, "brg_new"))

	clear_reenroll_marker(l.state_dir)
	_, still := read_reenroll_marker(l.state_dir)
	testing.expect(t, !still)
}

@(test)
test_status_state_words :: proc(t: ^testing.T) {
	testing.expect_value(t, status_state(Status{}), "not_installed")
	testing.expect_value(t, status_state(Status{installed = true}), "not_enrolled")
	testing.expect_value(t, status_state(Status{installed = true, enrolled = true}), "stopped")
	testing.expect_value(t, status_state(Status{installed = true, enrolled = true, running = true}), "disconnected")
	testing.expect_value(t, status_state(Status{installed = true, enrolled = true, running = true, connected = true}), "connected")
	testing.expect_value(t, status_state(Status{installed = true, enrolled = true, running = true, connected = true, needs_reenrollment = true}), "needs_reenrollment")
}

// Two Ninjy accounts on one OS user and hub: the second account lands in its
// own profile (never the first's), with its own service, state/data/bin dirs,
// ham-ctl and ports. Uninstalling either one, in both orders, removes only its
// own paths and leaves the other's install and the shared extensions root.
@(test)
test_separate_account_default_is_available_not_exhausted :: proc(t: ^testing.T) {
	root := make_temp_root(t, "profile-selection")
	defer os.remove_all(root)
	host := Host{os = .Linux, home = root, uid = 1000}
	_, hub, _ := canonical_hub("https://hub.example.com", context.temp_allocator)
	selected, found := separate_account_profile(host, hub, "")
	testing.expect(t, found, "a fresh install has an available default profile")
	testing.expect_value(t, selected, "")
	testing.expect_value(t, list_json([]Status{}, context.temp_allocator), `{"profiles":[]}`)
	// Occupy the default and every automatic account slot. Only now is the
	// empty selection an error; a new explicit name must still be available.
	for n in 1 ..< 100 {
		name := "" if n == 1 else fmt.tprintf("account-%d", n)
		l := layout_for(host, service_name(hub, name, context.temp_allocator))
		testing.expect(t, os.make_directory_all(l.state_dir) == nil)
		testing.expect(t, os.write_entire_file_from_string(pjoin(l.state_dir, TOKEN_FILE), strings.concatenate({CREDENTIAL_HEADER, "secret brg_existing\n"}, context.temp_allocator)) == nil)
	}
	_, exhausted := separate_account_profile(host, hub, "")
	testing.expect(t, !exhausted, "all automatic profiles are actually enrolled")
	personal, personal_found := separate_account_profile(host, hub, "personal")
	testing.expect(t, personal_found)
	testing.expect_value(t, personal, "personal")
}

@(test)
test_two_accounts_install_uninstall_both_orders :: proc(t: ^testing.T) {
	_, hub_name, _ := canonical_hub("https://hub.example.com", context.temp_allocator)
	for first in 0 ..< 2 {
		home := make_temp_root(t, fmt.tprintf("accounts-%d", first))
		defer os.remove_all(home)
		host := Host{os = .Linux, home = home, uid = 1000}
		free :: proc(port: int) -> bool {return false}

		install :: proc(t: ^testing.T, host: Host, hub_name, profile: string, free: Port_Busy_Proc) -> (l: Layout, ports: [2]int) {
			l = layout_for(host, service_name(hub_name, profile, context.temp_allocator))
			for d in ([]string{l.state_dir, l.bin_dir, pjoin(l.data_dir, "extensions")}) do testing.expect(t, os.make_directory_all(d) == nil)
			_ = os.write_entire_file_from_string(pjoin(l.bin_dir, "ham-ctl"), l.service_name)
			ok: bool
			ports, _, ok = allocate_ports(l.state_root, l.state_dir, free)
			testing.expect(t, ok)
			id := "brg_a" if profile == "" else "brg_b"
			_ = os.write_entire_file_from_string(pjoin(l.state_dir, TOKEN_FILE), strings.concatenate({CREDENTIAL_HEADER, "secret ", id, "\n"}, context.temp_allocator))
			return
		}

		// Account A takes the default profile; account B asks for it too.
		selected_1, found_1 := separate_account_profile(host, hub_name, "")
		testing.expect(t, found_1)
		testing.expect_value(t, selected_1, "")
		a, a_ports := install(t, host, hub_name, "", free)
		b_profile, b_found := separate_account_profile(host, hub_name, "")
		testing.expect(t, b_found)
		testing.expect_value(t, b_profile, "account-2")
		b, b_ports := install(t, host, hub_name, b_profile, free)
		selected_2, found_2 := separate_account_profile(host, hub_name, "")
		testing.expect(t, found_2)
		testing.expect_value(t, selected_2, "account-3")
		testing.expect(t, a.service_name != b.service_name && a.service_file != b.service_file)
		testing.expect(t, a.state_dir != b.state_dir && a.data_dir != b.data_dir && a.bin_dir != b.bin_dir)
		testing.expect(t, a_ports[0] != b_ports[0] && a_ports[1] != b_ports[1] && a_ports[0] != b_ports[1] && a_ports[1] != b_ports[0])
		shared := pjoin(pdir(a.data_dir), ".shared-extensions", "1.0.0", "extensions")
		testing.expect_value(t, pdir(a.data_dir), pdir(b.data_dir))
		testing.expect(t, os.make_directory_all(shared) == nil)
		testing.expect_value(t, len(list_services(host)), 2)

		gone, kept := a, b
		if first == 1 do gone, kept = b, a
		kept_ports, _ := read_ports(kept.state_dir)
		p := uninstall_paths(gone)
		for group in ([][]string{p.extensions, p.caches, p.binaries, p.state, p.data}) {
			for path in group {
				for own in ([]string{kept.state_dir, kept.data_dir}) {
					testing.expect(t, path != own && !strings.has_prefix(path, strings.concatenate({own, "/"}, context.temp_allocator)), path)
				}
				_ = os.remove_all(path)
			}
		}
		names := list_services(host)
		testing.expect_value(t, len(names), 1)
		if len(names) == 1 do testing.expect_value(t, names[0], kept.service_name)
		testing.expect(t, os.is_file(pjoin(kept.bin_dir, "ham-ctl")), "the other account keeps its ham-ctl")
		testing.expect(t, os.is_dir(pjoin(kept.data_dir, "extensions")))
		testing.expect(t, os.is_dir(shared), "the shared extensions root outlives any one profile")
		testing.expect(t, profile_enrolled(host, kept.service_name))
		after, _ := read_ports(kept.state_dir)
		testing.expect_value(t, after, kept_ports)
		// A reinstall of the removed account gets ports that do not collide.
		re_profile := "" if gone.service_name == a.service_name else b_profile
		_, re_ports := install(t, host, hub_name, re_profile, free)
		testing.expect(t, re_ports[0] != after[0] && re_ports[1] != after[1])
	}
}

// A home directory reached through a link (Fedora Atomic /home -> /var/home, macOS
// /var -> /private/var, a Windows junction) must give the same key as its target,
// or a valid profile install looks like a foreign binary to update/uninstall.
@(test)
test_path_key_resolves_linked_directory :: proc(t: ^testing.T) {
	tmp, terr := os.temp_directory(context.temp_allocator)
	testing.expect(t, terr == nil)
	root := pjoin(tmp, fmt.tprintf("bridgesvc-pathkey-%d", os.get_pid()))
	_ = os.remove_all(root)
	defer os.remove_all(root)
	real_bin := pjoin(root, "var", "home", "u", "bin")
	other_bin := pjoin(root, "other", "u", "bin")
	testing.expect(t, os.make_directory_all(real_bin) == nil)
	testing.expect(t, os.make_directory_all(other_bin) == nil)
	link_home := pjoin(root, "home")
	if err := os.symlink(pjoin(root, "var", "home"), link_home); err != nil {
		fmt.eprintfln("symlink unavailable here (%v); skipping the linked-path case", err)
		return
	}
	linked_bin := pjoin(link_home, "u", "bin")
	testing.expect_value(t, path_key(linked_bin), path_key(real_bin))
	testing.expect_value(t, path_key(strings.concatenate({linked_bin, "/"}, context.temp_allocator)), path_key(real_bin))
	testing.expect(t, path_key(other_bin) != path_key(real_bin))
	// A missing path keeps its lexical form rather than failing.
	missing := pjoin(root, "missing", "bin")
	testing.expect_value(t, path_key(missing), path_key(missing))
}
