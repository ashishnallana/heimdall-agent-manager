package bridgesvc

// `ham-bridge tray` model (REQ-ENR-6, T9): the bridge-owned tray companion.
//
// The tray is a second process of the installed ham-bridge binary
// (`<bin>/ham-bridge tray --service <name>`), one per profile, started at user
// login next to the bridge service and only on a desktop session:
//
//   Linux    XDG autostart  ~/.config/autostart/<service>-tray.desktop
//   macOS    LaunchAgent    ~/Library/LaunchAgents/<service>.tray.plist (Aqua sessions only)
//   Windows  HKCU Run value <service>-tray
//   Termux   none (no desktop)
//
// It never keeps its own idea of the bridge: the state shown is gather_status
// (the same as `ham-bridge status --json`) and every menu entry runs a ham-bridge
// command (tray_action_argv). Like the rest of this package everything here is
// pure; src/bridge/tray_*.odin supplies the native menus and runs the argv.

import "core:fmt"
import "core:strings"

TRAY_SUFFIX :: "-tray"
TRAY_PID_FILE :: "tray.pid"
WINDOWS_RUN_KEY :: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`

Tray_Layout :: struct {
	autostart_file: string, // .desktop / plist; "" on Windows (registry) and Termux
	run_value:      string, // Windows Run value name
	label:          string, // launchd label
	pid_file:       string, // <data_dir>/run/tray.pid, written by the running tray
	exe:            string, // the installed ham-bridge the tray runs from
}

// tray_supported: the OSes with a native tray backend.
tray_supported :: proc(target: Target_OS) -> bool {
	return target == .Linux || target == .Darwin || target == .Windows
}

tray_layout :: proc(host: Host, l: Layout) -> Tray_Layout {
	t := Tray_Layout{pid_file = pjoin(l.data_dir, "run", TRAY_PID_FILE), exe = pjoin(l.bin_dir, exe_name(host, "ham-bridge"))}
	switch host.os {
	case .Linux:
		t.autostart_file = pjoin(host.home, ".config", "autostart", strings.concatenate({l.service_name, TRAY_SUFFIX, ".desktop"}, context.temp_allocator))
	case .Darwin:
		t.label = strings.concatenate({l.service_name, ".tray"}, context.temp_allocator)
		t.autostart_file = pjoin(host.home, "Library", "LaunchAgents", strings.concatenate({t.label, ".plist"}, context.temp_allocator))
	case .Windows:
		t.run_value = strings.concatenate({l.service_name, TRAY_SUFFIX}, context.temp_allocator)
	case .Termux:
	}
	return t
}

// tray_argv: the tray's own command line (temp-allocated).
tray_argv :: proc(host: Host, l: Layout) -> []string {
	a := make([]string, 4, context.temp_allocator)
	a[0], a[1], a[2], a[3] = tray_layout(host, l).exe, "tray", "--service", l.service_name
	return a
}

// tray_launch_argv: how the login entry, setup and update start the tray
// (temp-allocated). On Windows ham-bridge is a console program, so it runs under
// `conhost.exe --headless`: no console window at login, and the tray keeps a
// hidden console that the helpers it runs every poll (powershell.exe for the
// Scheduled Task state, the service/setup menu actions) inherit instead of each
// opening a console window of their own.
tray_launch_argv :: proc(host: Host, l: Layout) -> []string {
	argv := tray_argv(host, l)
	if host.os != .Windows do return argv
	a := make([]string, len(argv) + 2, context.temp_allocator)
	a[0], a[1] = "conhost.exe", "--headless"
	copy(a[2:], argv)
	return a
}

// Desktop_Env is the part of the environment that says whether a user can see a tray.
Desktop_Env :: struct {
	display, wayland_display, session_type: string, // Linux
	ssh_connection:                         string, // all: a remote shell is not the desktop
	session_name:                           string, // Windows SESSIONNAME ("Console", "RDP-Tcp#3"; "" for a service)
	no_tray:                                bool, // setup --no-tray
}

// tray_wanted decides whether setup installs the tray: never on Termux or with
// --no-tray; on Linux only when a graphical session is visible; on macOS and Windows
// unless setup runs from a remote shell (or, on Windows, outside any session).
// Note setup --headless is NOT a signal: it only means "no browser approval"
// (update passes it), not "this machine has no desktop".
tray_wanted :: proc(target: Target_OS, env: Desktop_Env) -> (wanted: bool, reason: string) {
	if env.no_tray do return false, "--no-tray"
	if !tray_supported(target) do return false, "no desktop tray on this platform"
	switch target {
	case .Linux:
		st := strings.to_lower(env.session_type, context.temp_allocator)
		if env.display == "" && env.wayland_display == "" && st != "x11" && st != "wayland" do return false, "headless (no graphical session)"
	case .Darwin:
		if env.ssh_connection != "" do return false, "headless (ssh session)"
	case .Windows:
		if env.ssh_connection != "" || env.session_name == "" || env.session_name == "Services" do return false, "headless (no interactive session)"
	case .Termux:
	}
	return true, ""
}

// render_tray_autostart is the login entry's file (temp-allocated); "" when the OS
// uses the registry (Windows) or has no tray.
render_tray_autostart :: proc(host: Host, l: Layout) -> string {
	t := tray_layout(host, l)
	argv := tray_launch_argv(host, l)
	b := strings.builder_make(context.temp_allocator)
	#partial switch host.os {
	case .Linux:
		// Desktop Entry Exec: quote every argument, escaping \ " ` $ (spec §Exec).
		strings.write_string(&b, "[Desktop Entry]\nType=Application\nName=Heimdall Bridge\n")
		fmt.sbprintf(&b, "Comment=Heimdall bridge status for %s\nExec=", l.service_name)
		for a, i in argv {
			if i > 0 do strings.write_byte(&b, ' ')
			strings.write_byte(&b, '"')
			for r in a {
				switch r {
				case '"', '`', '$', '\\': strings.write_byte(&b, '\\'); strings.write_rune(&b, r)
				case '%':                 strings.write_string(&b, "%%")
				case:                     strings.write_rune(&b, r)
				}
			}
			strings.write_byte(&b, '"')
		}
		strings.write_string(&b, "\nIcon=network-server\nTerminal=false\nNoDisplay=true\nX-GNOME-Autostart-enabled=true\nX-Heimdall-Generated=ham-bridge setup\n")
	case .Darwin:
		strings.write_string(&b, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n")
		// AbandonProcessGroup: the tray's children (Uninstall above all, which outlives
		// the tray by design; Restart / Re-enroll after Close tray) must not be killed
		// with the job when the tray exits. Same reason as the bridge's own plist.
		fmt.sbprintf(&b, "<plist version=\"1.0\">\n<dict>\n\t<key>AbandonProcessGroup</key>\n\t<true/>\n\t<key>Label</key>\n\t<string>%s</string>\n", xml_escape(t.label))
		strings.write_string(&b, "\t<key>LimitLoadToSessionType</key>\n\t<string>Aqua</string>\n\t<key>ProcessType</key>\n\t<string>Interactive</string>\n\t<key>ProgramArguments</key>\n\t<array>\n")
		for a in argv do fmt.sbprintf(&b, "\t\t<string>%s</string>\n", xml_escape(a))
		strings.write_string(&b, "\t</array>\n\t<key>RunAtLoad</key>\n\t<true/>\n\t<key>KeepAlive</key>\n\t<dict>\n\t\t<key>SuccessfulExit</key>\n\t\t<false/>\n\t</dict>\n")
		fmt.sbprintf(&b, "\t<key>StandardErrorPath</key>\n\t<string>%s</string>\n</dict>\n</plist>\n", xml_escape(pjoin(l.data_dir, "logs", "tray.err.log")))
	}
	return strings.to_string(b)
}

// tray_windows_command is the Run value's data: the quoted command line.
tray_windows_command :: proc(host: Host, l: Layout) -> string {
	b := strings.builder_make(context.temp_allocator)
	for a, i in tray_launch_argv(host, l) {
		if i > 0 do strings.write_byte(&b, ' ')
		fmt.sbprintf(&b, "\"%s\"", a)
	}
	return strings.to_string(b)
}

// tray_register_argv: commands that make the tray start at login (after the
// autostart file, if any, is written). Linux needs none: the session reads
// ~/.config/autostart itself.
tray_register_argv :: proc(host: Host, l: Layout) -> [][]string {
	t := tray_layout(host, l)
	out := make([dynamic][]string, context.temp_allocator)
	#partial switch host.os {
	case .Windows:
		append(&out, clone_argv({"reg", "add", WINDOWS_RUN_KEY, "/v", t.run_value, "/t", "REG_SZ", "/d", tray_windows_command(host, l), "/f"}))
	case .Darwin:
		// Load it now too; a failure (already loaded) is harmless, login loads it anyway.
		append(&out, clone_argv({"launchctl", "bootstrap", fmt.tprintf("gui/%d", host.uid), t.autostart_file}))
	}
	return out[:]
}

// tray_unregister_argv: commands that stop the tray starting at login (before the
// autostart file, if any, is deleted). Failures mean "already gone".
tray_unregister_argv :: proc(host: Host, l: Layout) -> [][]string {
	t := tray_layout(host, l)
	out := make([dynamic][]string, context.temp_allocator)
	#partial switch host.os {
	case .Windows:
		append(&out, clone_argv({"reg", "delete", WINDOWS_RUN_KEY, "/v", t.run_value, "/f"}))
	case .Darwin:
		append(&out, clone_argv({"launchctl", "bootout", fmt.tprintf("gui/%d/%s", host.uid, t.label)}))
	}
	return out[:]
}

@(private = "file")
clone_argv :: proc(parts: []string) -> []string {
	a := make([]string, len(parts), context.temp_allocator)
	copy(a, parts)
	return a
}

// ---- what the tray shows ---------------------------------------------------

Tray_Level :: enum {
	Ok, // connected
	Warning, // offline / stopped / vault locked: will recover or needs a restart
	Error, // needs re-enrollment / not installed: needs the user
}

Tray_View :: struct {
	level:   Tray_Level,
	title:   string, // the status line at the top of the menu
	tooltip: string,
}

// tray_view folds a Status into what the tray shows (temp-allocated).
tray_view :: proc(s: Status) -> Tray_View {
	v := Tray_View{level = .Warning}
	switch s.state {
	case "connected":
		if s.vault == "locked" {
			v.title = "Vault locked"
		} else {
			v.level, v.title = .Ok, "Connected"
		}
	case "needs_reenrollment": v.level, v.title = .Error, "Needs re-enrollment"
	case "not_enrolled":       v.level, v.title = .Error, "Not enrolled"
	case "not_installed":      v.level, v.title = .Error, "Not installed"
	case "stopped":            v.title = "Offline (bridge stopped)"
	case "disconnected":       v.title = "Offline (hub unreachable)"
	case:                      v.title = "Unknown"
	}
	hub := s.hub if s.hub != "" else s.service
	v.tooltip = fmt.tprintf("Heimdall Bridge: %s - %s", v.title, hub)
	return v
}

// tray_ico_pick finds the image in an .ico file (ICONDIR + 16-byte entries)
// that best fits want px: the smallest at least that big, else the largest. image
// is the entry's bytes (BMP DIB or PNG), what CreateIconFromResourceEx takes; ok
// is false for a malformed file.
tray_ico_pick :: proc(ico: []byte, want: int) -> (image: []byte, size: int, ok: bool) {
	u16le :: proc(b: []byte, at: int) -> int {return int(b[at]) | int(b[at + 1]) << 8}
	u32le :: proc(b: []byte, at: int) -> int {return u16le(b, at) | u16le(b, at + 2) << 16}
	if len(ico) < 6 || u16le(ico, 0) != 0 || u16le(ico, 2) != 1 do return nil, 0, false
	count := u16le(ico, 4)
	if count == 0 || len(ico) < 6 + 16 * count do return nil, 0, false
	best := -1
	for i in 0 ..< count {
		e := 6 + 16 * i
		w := int(ico[e]) if ico[e] != 0 else 256
		n, off := u32le(ico, e + 8), u32le(ico, e + 12)
		if n <= 0 || off < 6 + 16 * count || off + n > len(ico) do continue
		better := best < 0 || (w >= want && (size < want || w < size)) || (w < want && size < want && w > size)
		if better do best, size, image = i, w, ico[off:off + n]
	}
	return image, size, best >= 0
}

Tray_Action :: enum {
	Open_Heimdall,
	Update,
	Restart,
	Reenroll,
	View_Logs,
	Uninstall,
	Quit, // closes the tray only; the bridge keeps running
}

TRAY_ACTION_LABELS := [Tray_Action]string {
	.Open_Heimdall = "Open Heimdall",
	.Update        = "Update",
	.Restart       = "Restart",
	.Reenroll      = "Re-enroll",
	.View_Logs     = "View logs",
	.Uninstall     = "Uninstall...",
	.Quit          = "Close tray",
}

// tray_action_enabled: menu entries that cannot do anything in a state are greyed.
tray_action_enabled :: proc(a: Tray_Action, s: Status) -> bool {
	#partial switch a {
	case .Open_Heimdall, .Update: return s.hub != ""
	case .Restart:                return s.installed
	case .Reenroll:               return s.installed && s.hub != ""
	}
	return true
}

TRAY_UNINSTALL_CONFIRM :: "Uninstall this Heimdall bridge?\n\nThe bridge service, its credentials and every secret it holds (tokens, vault key) are removed from this computer and the hub is told to revoke it. Logs are kept."

// open_url_argv opens a URL or a directory with the desktop's default handler.
open_url_argv :: proc(target: Target_OS, url: string) -> []string {
	#partial switch target {
	case .Darwin:  return clone_argv({"open", url})
	case .Windows: return clone_argv({"explorer.exe", url})
	}
	return clone_argv({"xdg-open", url})
}

// tray_action_argv: the command one menu entry runs (temp-allocated); nil for
// Quit. self is the running ham-bridge (the installed binary). Uninstall is run
// only after the user confirmed TRAY_UNINSTALL_CONFIRM.
tray_action_argv :: proc(host: Host, s: Status, self: string, a: Tray_Action) -> []string {
	l := layout_for(host, s.service)
	switch a {
	case .Open_Heimdall:
		return open_url_argv(host.os, s.hub)
	case .Update:
		// Updates are applied by the hub-initiated flow (Settings > Bridges > Update),
		// which stages the release and runs `ham-bridge update --bundle`. A local
		// `update --version` (release download + SHA-256) belongs to the bootstraps
		// (w5); until it exists the tray opens that page for this bridge.
		return open_url_argv(host.os, fmt.tprintf("%s/settings/bridges", strings.trim_right(s.hub, "/")))
	case .Restart:
		return clone_argv({self, "service", "restart", "--service", s.service})
	case .Reenroll:
		// setup re-renders and re-enrolls in place; --new-bridge forces a fresh
		// enrollment even when a (revoked) credential is still on disk.
		argv := make([dynamic]string, context.temp_allocator)
		append(&argv, self, "setup", "--hub", s.hub)
		if s.profile != "" do append(&argv, "--profile", s.profile)
		append(&argv, "--new-bridge")
		return argv[:]
	case .View_Logs:
		return open_url_argv(host.os, pjoin(l.data_dir, "logs"))
	case .Uninstall:
		return clone_argv({self, "uninstall", "--service", s.service, "--keep-data", "--yes"})
	case .Quit:
	}
	return nil
}
