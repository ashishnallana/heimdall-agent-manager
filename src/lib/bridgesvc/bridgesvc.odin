package bridgesvc

// One platform-service model for every bridge lifecycle command (service, status,
// list, setup, enroll's restart): which supervisor runs the bridge, what its
// service is called, where its state lives and which loopback ports it owns.
//
// Everything is derived from the bridge PROFILE = (hub, optional profile name), the
// same identity scripts/install.sh and install.ps1 use, so an existing per-Hub install
// (~/.config/heimdall/bridges/<service>, %APPDATA%\heimdall\bridges\<service>) is
// adopted in place:
//
//   service name  heimdall-bridge-<hub name>[_<profile>]
//   hub name      lower-cased host with every char outside [a-z0-9-] -> '-', plus
//                 "-<port>" for a non-default port (never contains '_', so the
//                 "_<profile>" suffix cannot collide with another Hub's name)
//
// This package is pure: it never touches the process environment or runs a
// command. Callers pass a Host (home, APPDATA, PREFIX, uid, OS) and execute the argv
// it returns, so every derivation is unit-testable for every OS on any OS.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

SERVICE_PREFIX :: "heimdall-bridge-"
PROFILE_MAX_LEN :: 31
// The first pair a profile tries; later profiles take the next free ports.
DEFAULT_BRIDGE_PORT :: 49323
DEFAULT_ENDPOINT_PORT :: 49324
PORTS_FILE :: "ports.json"
HUB_URL_FILE :: "hub-url"
PROFILE_FILE :: "profile"
TOKEN_FILE :: "bridge-token"
CONFIG_FILE :: "config.toml"
// Written by the running bridge (see bridge_local_status_write) so status is
// readable without the rotating bridge token (F22).
RUNTIME_STATUS_FILE :: "runtime-status.json"
CREDENTIAL_HEADER :: "heimdall-bridge-credential/v1 "

Backend :: enum {
	None,
	Systemd, // Linux: systemd --user unit
	Launchd, // macOS: per-user LaunchAgent
	Schtasks, // Windows: per-user Scheduled Task
	Runit, // Termux: termux-services
}

Target_OS :: enum {
	Linux,
	Darwin,
	Windows,
	Termux,
}

Action :: enum {
	Start,
	Stop,
	Restart,
	Status,
}

// Host is everything about the machine a derivation depends on.
Host :: struct {
	os:            Target_OS,
	home:          string,
	appdata:       string, // Windows %APPDATA%
	local_appdata: string, // Windows %LOCALAPPDATA%
	prefix:        string, // Termux $PREFIX
	uid:           int, // launchd gui/<uid> domain
}

Profile :: struct {
	hub_url:      string, // canonical scheme://host[:port]
	hub_name:     string,
	profile:      string, // "" = the Hub's default profile
	service_name: string,
}

Layout :: struct {
	backend:      Backend,
	service_name: string,
	state_root:   string, // parent of every profile's state_dir (port reservations, list)
	state_dir:    string, // config.toml, bridge-token, hub-url, profile, ports.json
	data_dir:     string,
	bin_dir:      string,
	service_file: string, // unit / plist / runit run file; "" for a Scheduled Task
}

backend_for :: proc(target: Target_OS) -> Backend {
	switch target {
	case .Linux:   return .Systemd
	case .Darwin:  return .Launchd
	case .Windows: return .Schtasks
	case .Termux:  return .Runit
	}
	return .None
}

backend_name :: proc(b: Backend) -> string {
	switch b {
	case .None:     return "none"
	case .Systemd:  return "systemd"
	case .Launchd:  return "launchd"
	case .Schtasks: return "schtasks"
	case .Runit:    return "runit"
	}
	return "none"
}

// valid_profile mirrors install.sh: ^[a-z0-9][a-z0-9-]{0,30}$ (path- and unit-safe).
valid_profile :: proc(p: string) -> bool {
	if len(p) == 0 || len(p) > PROFILE_MAX_LEN do return false
	for c, i in transmute([]u8)p {
		alnum := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
		if !alnum && !(i > 0 && c == '-') do return false
	}
	return true
}

// canonical_hub reduces a Hub URL to scheme://host[:port] and its service-name
// component, like install.sh canonical_hub. Path prefixes do not change the
// identity. Results are allocated with `allocator`.
canonical_hub :: proc(raw: string, allocator := context.allocator) -> (url: string, name: string, ok: bool) {
	s := strings.trim_space(raw)
	scheme := ""
	switch {
	case strings.has_prefix(strings.to_lower(s, context.temp_allocator), "https://"):
		scheme, s = "https", s[8:]
	case strings.has_prefix(strings.to_lower(s, context.temp_allocator), "http://"):
		scheme, s = "http", s[7:]
	case:
		return "", "", false
	}
	if i := strings.index_any(s, "/?#"); i >= 0 do s = s[:i]
	if strings.contains(s, "@") || s == "" do return "", "", false
	host, port := s, ""
	if strings.has_prefix(s, "[") {
		end := strings.index_byte(s, ']')
		if end < 0 do return "", "", false
		host = s[1:end]
		rest := s[end + 1:]
		if strings.has_prefix(rest, ":") do port = rest[1:]
		else if rest != "" do return "", "", false
	} else if i := strings.last_index_byte(s, ':'); i >= 0 {
		host, port = s[:i], s[i + 1:]
	}
	host = strings.trim_right(strings.to_lower(host, context.temp_allocator), ".")
	if host == "" || len(host) > 253 do return "", "", false
	for c in transmute([]u8)host {
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-' || c == ':') do return "", "", false
	}
	if port != "" {
		n, nok := strconv.parse_int(port, 10)
		if !nok || n < 1 || n > 65535 do return "", "", false
		port = fmt.tprintf("%d", n)
		if (scheme == "http" && n == 80) || (scheme == "https" && n == 443) do port = ""
	}
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)host {
		strings.write_byte(&b, c if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' else '-')
	}
	if port != "" do fmt.sbprintf(&b, "-%s", port)
	name = strings.clone(strings.to_string(b), allocator)
	shown_host := fmt.tprintf("[%s]", host) if strings.contains(host, ":") else host
	url = fmt.aprintf("%s://%s%s%s", scheme, shown_host, ":" if port != "" else "", port, allocator = allocator)
	return url, name, true
}

// profile_from :: hub URL + optional profile name -> Profile (allocator-owned).
profile_from :: proc(hub: string, profile: string, allocator := context.allocator) -> (p: Profile, ok: bool) {
	if profile != "" && !valid_profile(profile) do return {}, false
	p.hub_url, p.hub_name = canonical_hub(hub, allocator) or_return
	p.profile = strings.clone(profile, allocator)
	p.service_name = service_name(p.hub_name, profile, allocator)
	return p, true
}

profile_destroy :: proc(p: ^Profile, allocator := context.allocator) {
	delete(p.hub_url, allocator)
	delete(p.hub_name, allocator)
	delete(p.profile, allocator)
	delete(p.service_name, allocator)
	p^ = {}
}

service_name :: proc(hub_name, profile: string, allocator := context.allocator) -> string {
	if profile == "" do return strings.concatenate({SERVICE_PREFIX, hub_name}, allocator)
	return strings.concatenate({SERVICE_PREFIX, hub_name, "_", profile}, allocator)
}

// layout_for gives the on-disk layout of a service (temp-allocated strings).
layout_for :: proc(host: Host, name: string) -> Layout {
	j :: proc(parts: ..string) -> string {return pjoin(..parts)}
	l := Layout{backend = backend_for(host.os), service_name = name}
	switch host.os {
	case .Windows:
		l.state_root = j(host.appdata, "heimdall", "bridges")
		l.data_dir = j(host.local_appdata, "heimdall", "bridges", name)
	case .Linux, .Darwin, .Termux:
		l.state_root = j(host.home, ".config", "heimdall", "bridges")
		l.data_dir = j(host.home, ".local", "share", "heimdall", "bridges", name)
	}
	l.state_dir = j(l.state_root, name)
	l.bin_dir = j(l.data_dir, "bin")
	switch l.backend {
	case .Systemd:  l.service_file = j(host.home, ".config", "systemd", "user", strings.concatenate({name, ".service"}, context.temp_allocator))
	case .Launchd:  l.service_file = j(host.home, "Library", "LaunchAgents", strings.concatenate({name, ".plist"}, context.temp_allocator))
	case .Runit:    l.service_file = j(host.prefix, "var", "service", name, "run")
	case .Schtasks, .None:
	}
	return l
}

// service_argv is the supervisor command for an action (temp-allocated), nil
// for Backend.None. Nothing here runs a shell.
service_argv :: proc(host: Host, l: Layout, action: Action) -> []string {
	a := make([dynamic]string, context.temp_allocator)
	switch l.backend {
	case .None:
		return nil
	case .Systemd:
		verb := [Action]string{.Start = "start", .Stop = "stop", .Restart = "restart", .Status = "is-active"}
		append(&a, "systemctl", "--user", verb[action], strings.concatenate({l.service_name, ".service"}, context.temp_allocator))
	case .Launchd:
		target := fmt.tprintf("gui/%d/%s", host.uid, l.service_name)
		switch action {
		case .Start:   append(&a, "launchctl", "bootstrap", fmt.tprintf("gui/%d", host.uid), l.service_file)
		case .Stop:    append(&a, "launchctl", "bootout", target)
		case .Restart: append(&a, "launchctl", "kickstart", "-k", target)
		case .Status:  append(&a, "launchctl", "print", target)
		}
	case .Schtasks:
		tn := strings.concatenate({"\\", l.service_name}, context.temp_allocator)
		switch action {
		case .Start:   append(&a, "schtasks", "/Run", "/TN", tn)
		case .Stop:    append(&a, "schtasks", "/End", "/TN", tn)
		case .Restart: append(&a, "schtasks", "/End", "/TN", tn) // caller follows with Start
		case .Status:  append(&a, "schtasks", "/Query", "/TN", tn, "/FO", "CSV", "/NH")
		}
	case .Runit:
		dir := pdir(l.service_file)
		verb := [Action]string{.Start = "up", .Stop = "down", .Restart = "restart", .Status = "status"}
		append(&a, "sv", verb[action], dir)
	}
	return a[:]
}

// ---- ports -----------------------------------------------------------------

// parse_ports reads a flat JSON integer list such as "[49323, 49324]".
parse_ports :: proc(text: string) -> (ports: [2]int, ok: bool) {
	t := strings.trim_space(text)
	if !strings.has_prefix(t, "[") || !strings.has_suffix(t, "]") do return {}, false
	parts := strings.split(t[1:len(t) - 1], ",", context.temp_allocator)
	if len(parts) != 2 do return {}, false
	for part, i in parts {
		n, nok := strconv.parse_int(strings.trim_space(part), 10)
		if !nok || n < 1024 || n > 65535 do return {}, false
		ports[i] = n
	}
	return ports, ports[0] != ports[1]
}

Port_Busy_Proc :: #type proc(port: int) -> bool

// allocate_ports keeps this profile's persisted pair while it is free, never takes
// a pair another profile under state_root has recorded, and otherwise walks up
// from the defaults. The result is written to <state_dir>/ports.json. reused
// reports that the persisted pair was kept unchanged.
allocate_ports :: proc(state_root, state_dir: string, busy: Port_Busy_Proc) -> (ports: [2]int, reused: bool, ok: bool) {
	reserved := make([dynamic]int, context.temp_allocator)
	preferred := [2]int{DEFAULT_BRIDGE_PORT, DEFAULT_ENDPOINT_PORT}
	own_clean := strings.trim_right(state_dir, "/\\")
	have_own := false
	if entries, err := os.read_all_directory_by_path(state_root, context.temp_allocator); err == nil {
		for e in entries {
			if e.type != .Directory do continue
			data, rerr := os.read_entire_file_from_path(pjoin(e.fullpath, PORTS_FILE), context.temp_allocator)
			if rerr != nil do continue
			p, pok := parse_ports(string(data))
			if !pok do continue
			if strings.trim_right(e.fullpath, "/\\") == own_clean {
				preferred, have_own = p, true
			} else {
				append(&reserved, p[0], p[1])
			}
		}
	}
	for start, i in preferred {
		port := max(start, 1024)
		for port <= 65535 {
			// Never let the bridge port walk onto this profile's own endpoint port.
			taken := slice.contains(reserved[:], port) || (i == 0 && port == preferred[1]) || (i == 1 && port == ports[0])
			if !taken && !busy(port) do break
			port += 1
		}
		if port > 65535 do return {}, false, false
		ports[i] = port
	}
	reused = have_own && ports == preferred
	if !reused {
		_ = os.make_directory_all(state_dir)
		if os.write_entire_file_from_string(pjoin(state_dir, PORTS_FILE), fmt.tprintf("[%d, %d]\n", ports[0], ports[1])) != nil do return {}, false, false
	}
	return ports, reused, true
}

read_ports :: proc(state_dir: string) -> (ports: [2]int, ok: bool) {
	data, err := os.read_entire_file_from_path(pjoin(state_dir, PORTS_FILE), context.temp_allocator)
	if err != nil do return {}, false
	return parse_ports(string(data))
}

// pjoin joins path parts with '/' (accepted by every supported OS; temp-allocated).
pjoin :: proc(parts: ..string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for p, i in parts {
		part := p if i == 0 else strings.trim_left(p, "/\\")
		if i > 0 && strings.builder_len(b) > 0 && !strings.has_suffix(strings.to_string(b), "/") && !strings.has_suffix(strings.to_string(b), "\\") do strings.write_byte(&b, '/')
		strings.write_string(&b, part)
	}
	return strings.to_string(b)
}

// pdir is the parent directory of a path (a view into it).
pdir :: proc(path: string) -> string {
	p := strings.trim_right(path, "/\\")
	i := strings.last_index_any(p, "/\\")
	return p[:i] if i > 0 else p
}
