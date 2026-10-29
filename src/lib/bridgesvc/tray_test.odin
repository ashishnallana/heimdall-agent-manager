package bridgesvc

import "core:strings"
import "core:testing"

@(private = "file")
tray_host :: proc(target: Target_OS) -> Host {
	#partial switch target {
	case .Windows: return {os = .Windows, home = `C:\Users\u`, appdata = `C:\Users\u\AppData\Roaming`, local_appdata = `C:\Users\u\AppData\Local`}
	case .Darwin:  return {os = .Darwin, home = "/Users/u", uid = 501}
	}
	return {os = target, home = "/home/u"}
}

@(test)
test_tray_wanted_only_on_a_desktop_session :: proc(t: ^testing.T) {
	w, _ := tray_wanted(.Linux, {})
	testing.expect(t, !w, "linux without DISPLAY/WAYLAND_DISPLAY is headless")
	w, _ = tray_wanted(.Linux, {display = ":0"})
	testing.expect(t, w, "X11 session")
	w, _ = tray_wanted(.Linux, {wayland_display = "wayland-0"})
	testing.expect(t, w, "Wayland session")
	w, _ = tray_wanted(.Linux, {display = ":0", no_tray = true})
	testing.expect(t, !w, "--no-tray wins")
	w, _ = tray_wanted(.Darwin, {})
	testing.expect(t, w, "macOS local session")
	w, _ = tray_wanted(.Darwin, {ssh_connection = "1.2.3.4 5 6.7.8.9 22"})
	testing.expect(t, !w, "macOS over ssh is headless")
	w, _ = tray_wanted(.Windows, {session_name = "Console"})
	testing.expect(t, w, "Windows console session")
	w, _ = tray_wanted(.Windows, {})
	testing.expect(t, !w, "Windows outside an interactive session")
	w, _ = tray_wanted(.Termux, {display = ":0"})
	testing.expect(t, !w, "no tray on Termux")
}

@(test)
test_tray_autostart_per_os :: proc(t: ^testing.T) {
	name := "heimdall-bridge-hub-example-com_work"
	lin := tray_layout(tray_host(.Linux), layout_for(tray_host(.Linux), name))
	testing.expect_value(t, lin.autostart_file, "/home/u/.config/autostart/heimdall-bridge-hub-example-com_work-tray.desktop")
	testing.expect_value(t, lin.pid_file, "/home/u/.local/share/heimdall/bridges/heimdall-bridge-hub-example-com_work/run/tray.pid")
	desktop := render_tray_autostart(tray_host(.Linux), layout_for(tray_host(.Linux), name))
	testing.expect(t, strings.contains(desktop, `Exec="/home/u/.local/share/heimdall/bridges/heimdall-bridge-hub-example-com_work/bin/ham-bridge" "tray" "--service" "heimdall-bridge-hub-example-com_work"`), desktop)
	testing.expect(t, len(tray_register_argv(tray_host(.Linux), layout_for(tray_host(.Linux), name))) == 0, "XDG autostart needs no registration")

	mh := tray_host(.Darwin)
	mac := tray_layout(mh, layout_for(mh, name))
	testing.expect_value(t, mac.autostart_file, "/Users/u/Library/LaunchAgents/heimdall-bridge-hub-example-com_work.tray.plist")
	plist := render_tray_autostart(mh, layout_for(mh, name))
	testing.expect(t, strings.contains(plist, "<string>Aqua</string>"), "only GUI sessions load the tray")
	testing.expect(t, strings.contains(plist, "<string>tray</string>"), plist)
	reg := tray_register_argv(mh, layout_for(mh, name))
	testing.expect(t, len(reg) == 1 && reg[0][3] == mac.autostart_file, "bootstrap the tray agent")
	unreg := tray_unregister_argv(mh, layout_for(mh, name))
	testing.expect(t, len(unreg) == 1 && unreg[0][2] == "gui/501/heimdall-bridge-hub-example-com_work.tray", "bootout by label")

	wh := tray_host(.Windows)
	win := tray_layout(wh, layout_for(wh, name))
	testing.expect_value(t, win.autostart_file, "")
	testing.expect_value(t, win.run_value, "heimdall-bridge-hub-example-com_work-tray")
	wreg := tray_register_argv(wh, layout_for(wh, name))
	testing.expect(t, len(wreg) == 1 && wreg[0][0] == "reg" && wreg[0][1] == "add", "HKCU Run value")
	testing.expect(t, strings.has_suffix(wreg[0][8], `ham-bridge.exe" "tray" "--service" "heimdall-bridge-hub-example-com_work"`), wreg[0][8])
	wun := tray_unregister_argv(wh, layout_for(wh, name))
	testing.expect(t, len(wun) == 1 && wun[0][1] == "delete" && wun[0][4] == win.run_value, "Run value removed")
	testing.expect_value(t, render_tray_autostart(wh, layout_for(wh, name)), "")
}

@(test)
test_tray_desktop_exec_escapes :: proc(t: ^testing.T) {
	h := Host{os = .Linux, home = `/home/a "b"$x`}
	out := render_tray_autostart(h, layout_for(h, "heimdall-bridge-h"))
	testing.expect(t, strings.contains(out, `Exec="/home/a \"b\"\$x/`), out)
}

@(test)
test_tray_view_states :: proc(t: ^testing.T) {
	v := tray_view(Status{state = "connected", vault = "unlocked", hub = "https://h"})
	testing.expect(t, v.level == .Ok && v.title == "Connected", v.title)
	v = tray_view(Status{state = "connected", vault = "locked"})
	testing.expect(t, v.level == .Warning && v.title == "Vault locked", v.title)
	v = tray_view(Status{state = "disconnected"})
	testing.expect(t, v.level == .Warning && strings.has_prefix(v.title, "Offline"), v.title)
	v = tray_view(Status{state = "stopped"})
	testing.expect(t, v.level == .Warning && strings.has_prefix(v.title, "Offline"), v.title)
	v = tray_view(Status{state = "needs_reenrollment"})
	testing.expect(t, v.level == .Error && v.title == "Needs re-enrollment", v.title)
}

@(test)
test_tray_actions_run_ham_bridge :: proc(t: ^testing.T) {
	h := tray_host(.Linux)
	s := Status{service = "heimdall-bridge-h_work", hub = "https://h.example", profile = "work", installed = true}
	self := "/bin/ham-bridge"
	expect_argv :: proc(t: ^testing.T, got: []string, want: []string) {
		ok := len(got) == len(want)
		if ok do for g, i in got do if g != want[i] do ok = false
		testing.expectf(t, ok, "argv %v, want %v", got, want)
	}
	expect_argv(t, tray_action_argv(h, s, self, .Open_Heimdall), {"xdg-open", "https://h.example"})
	expect_argv(t, tray_action_argv(h, s, self, .Update), {"xdg-open", "https://h.example/settings/bridges"})
	expect_argv(t, tray_action_argv(h, s, self, .Restart), {self, "service", "restart", "--service", s.service})
	expect_argv(t, tray_action_argv(h, s, self, .Reenroll), {self, "setup", "--hub", s.hub, "--profile", "work", "--new-bridge"})
	expect_argv(t, tray_action_argv(h, s, self, .View_Logs), {"xdg-open", "/home/u/.local/share/heimdall/bridges/heimdall-bridge-h_work/logs"})
	expect_argv(t, tray_action_argv(h, s, self, .Uninstall), {self, "uninstall", "--service", s.service, "--keep-data", "--yes"})
	testing.expect(t, tray_action_argv(h, s, self, .Quit) == nil, "Quit runs nothing")
	expect_argv(t, tray_action_argv(tray_host(.Darwin), s, self, .Open_Heimdall), {"open", "https://h.example"})
	testing.expect(t, !tray_action_enabled(.Restart, Status{}), "nothing to restart when not installed")
	testing.expect(t, tray_action_enabled(.Uninstall, Status{}), "uninstall always offered")
}
