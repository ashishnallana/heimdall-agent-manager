package bridgesvc

// Local, token-free bridge status (F22). Everything here is read from files the OS
// user already owns: the profile's state dir (installed / enrolled / hub / ports)
// and runtime-status.json, which the running bridge rewrites on every hub connect,
// disconnect and vault change. Callers add `running` from the supervisor.

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:time"

// A runtime-status.json older than this is not trusted for `connected`: the bridge
// that wrote it may have died without rewriting it.
RUNTIME_STATUS_MAX_AGE :: 10 * time.Minute

Runtime_Status :: struct {
	pid:        int    `json:"pid"`,
	connected:  bool   `json:"connected"`,
	vault:      string `json:"vault"`,
	version:    string `json:"version"`,
	bridge_id:  string `json:"bridge_id"`,
	updated_at: i64    `json:"updated_at"`, // unix seconds
}

Status :: struct {
	profile:       string `json:"profile"`,
	service:       string `json:"service"`,
	backend:       string `json:"backend"`,
	hub:           string `json:"hub"`,
	installed:     bool   `json:"installed"`,
	enrolled:      bool   `json:"enrolled"`,
	running:       bool   `json:"running"`,
	connected:     bool   `json:"connected"`,
	vault:         string `json:"vault"`, // unlocked|locked|unpaired|unknown
	version:       string `json:"version"`,
	bridge_id:     string `json:"bridge_id"`,
	bridge_port:   int    `json:"bridge_port"`,
	endpoint_port: int    `json:"endpoint_port"`,
	state_dir:     string `json:"state_dir"`,
	// state is the one word a tray / Electron shows (status_state):
	// not_installed|not_enrolled|needs_reenrollment|stopped|disconnected|connected.
	state:              string `json:"state"`,
	needs_reenrollment: bool   `json:"needs_reenrollment"`,
	reenroll_reason: string `json:"reenroll_reason,omitempty"`,
	reenroll_hint:   string `json:"reenroll_hint,omitempty"`,
}

// NEEDS_REENROLL_FILE marks a profile whose credential the hub refused (revoked
// bridge, refresh 401, enrolled but tokenless, vault key never delivered). The
// bridge writes it and then PARKS instead of exiting non-zero, so a supervisor
// with Restart=on-failure does not crash-loop it (F21); a successful enroll
// removes it.
NEEDS_REENROLL_FILE :: "needs-reenrollment.json"

Reenroll_Marker :: struct {
	bridge_id: string `json:"bridge_id"`,
	hub:       string `json:"hub"`,
	reason:    string `json:"reason"`, // revoked|refresh_rejected|credential_missing|vault_key_timeout
	hint:      string `json:"hint"`,   // the command that recovers it
	at:        i64    `json:"at"`,     // unix seconds
}

reenroll_marker_json :: proc(m: Reenroll_Marker, allocator := context.allocator) -> string {
	data, _ := json.marshal(m, allocator = allocator)
	return string(data)
}

read_reenroll_marker :: proc(state_dir: string) -> (m: Reenroll_Marker, ok: bool) {
	data, err := os.read_entire_file_from_path(pjoin(state_dir, NEEDS_REENROLL_FILE), context.temp_allocator)
	if err != nil do return {}, false
	return m, json.unmarshal_string(string(data), &m, allocator = context.temp_allocator) == nil
}

// write_reenroll_marker writes the marker owner-only via temp + rename.
write_reenroll_marker :: proc(state_dir: string, m: Reenroll_Marker) -> bool {
	final := pjoin(state_dir, NEEDS_REENROLL_FILE)
	tmp := strings.concatenate({final, ".tmp"}, context.temp_allocator)
	if os.write_entire_file_from_string(tmp, reenroll_marker_json(m, context.temp_allocator), {.Read_User, .Write_User}) != nil do return false
	return os.rename(tmp, final) == nil
}

clear_reenroll_marker :: proc(state_dir: string) {
	_ = os.remove(pjoin(state_dir, NEEDS_REENROLL_FILE))
}

// reenroll_marker_applies: a marker of an older bridge id is moot once the profile
// holds a credential of a different (newly enrolled) bridge.
reenroll_marker_applies :: proc(m: Reenroll_Marker, enrolled: bool, bridge_id: string) -> bool {
	if !enrolled do return true
	return m.bridge_id == bridge_id
}

// status_state folds a Status into the single word clients render.
// Callers that change running/connected after gather_status recompute it.
status_state :: proc(s: Status) -> string {
	switch {
	case s.needs_reenrollment:       return "needs_reenrollment"
	case !s.installed && !s.enrolled: return "not_installed"
	case !s.enrolled:              return "not_enrolled"
	case !s.running:               return "stopped"
	case !s.connected:             return "disconnected"
	}
	return "connected"
}

runtime_status_json :: proc(r: Runtime_Status, allocator := context.allocator) -> string {
	data, _ := json.marshal(r, allocator = allocator)
	return string(data)
}

parse_runtime_status :: proc(text: string, allocator := context.allocator) -> (r: Runtime_Status, ok: bool) {
	return r, json.unmarshal_string(text, &r, allocator = allocator) == nil
}

read_first_line :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil do return ""
	text := string(data)
	if i := strings.index_any(text, "\r\n"); i >= 0 do text = text[:i]
	return strings.trim_space(text)
}

// credential_bridge_id: "heimdall-bridge-credential/v1 <secret> <brg_id>" -> brg_id.
credential_bridge_id :: proc(line: string) -> string {
	if !strings.has_prefix(line, CREDENTIAL_HEADER) do return ""
	fields := strings.fields(line, context.temp_allocator)
	if len(fields) < 3 do return ""
	id := fields[len(fields) - 1]
	return id if strings.has_prefix(id, "brg_") else ""
}

// read_runtime_status reads the runtime-status.json the bridge of a state dir wrote.
read_runtime_status :: proc(state_dir: string) -> (r: Runtime_Status, ok: bool) {
	data, err := os.read_entire_file_from_path(pjoin(state_dir, RUNTIME_STATUS_FILE), context.temp_allocator)
	if err != nil do return {}, false
	return parse_runtime_status(string(data), context.temp_allocator)
}

// gather_status reads one profile's status from disk (temp-allocated strings).
// now is injected for tests. A caller that just (re)started the bridge passes
// since (unix seconds of the restart) and stale_pid (the pid of the bridge it
// replaced): a runtime file written before the restart or by that old process
// does not count as connected, because a SIGTERMed bridge never rewrites it.
gather_status :: proc(host: Host, name: string, now: time.Time, since: i64 = 0, stale_pid := 0) -> Status {
	l := layout_for(host, name)
	s := Status{service = name, backend = backend_name(l.backend), state_dir = l.state_dir, vault = "unknown"}
	s.hub = read_first_line(pjoin(l.state_dir, HUB_URL_FILE))
	s.profile = read_first_line(pjoin(l.state_dir, PROFILE_FILE))
	if s.hub == "" do s.hub = hub_from_config(pjoin(l.state_dir, CONFIG_FILE))
	switch l.backend {
	case .Schtasks, .None: s.installed = os.exists(pjoin(l.bin_dir, "ham-bridge.exe"))
	case .Systemd, .Launchd, .Runit: s.installed = os.exists(l.service_file)
	}
	cred := read_first_line(pjoin(l.state_dir, TOKEN_FILE))
	s.bridge_id = credential_bridge_id(cred)
	s.enrolled = s.bridge_id != ""
	if p, ok := read_ports(l.state_dir); ok do s.bridge_port, s.endpoint_port = p[0], p[1]
	if m, ok := read_reenroll_marker(l.state_dir); ok && reenroll_marker_applies(m, s.enrolled, s.bridge_id) {
		s.needs_reenrollment = true
		s.reenroll_reason, s.reenroll_hint = m.reason, m.hint
		if s.bridge_id == "" do s.bridge_id = m.bridge_id
	}
	if r, ok := read_runtime_status(l.state_dir); ok {
		fresh := time.diff(time.unix(r.updated_at, 0), now) <= RUNTIME_STATUS_MAX_AGE
		current := r.updated_at >= since && (stale_pid == 0 || r.pid != stale_pid)
		s.connected = r.connected && fresh && current
		if r.vault != "" do s.vault = r.vault
		s.version = r.version
		if s.bridge_id == "" do s.bridge_id = r.bridge_id
	}
	s.state = status_state(s)
	return s
}

// hub_from_config pulls daemon.url / hub_url out of a config.toml for installs
// that predate the hub-url file.
hub_from_config :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil do return ""
	for line in strings.split_lines(string(data), context.temp_allocator) {
		t := strings.trim_space(line)
		for key in ([?]string{"hub_url", "url", "daemon_url"}) {
			if !strings.has_prefix(t, key) do continue
			rest := strings.trim_space(t[len(key):])
			if !strings.has_prefix(rest, "=") do continue
			v := strings.trim(strings.trim_space(rest[1:]), "\"'")
			if strings.has_prefix(v, "http://") || strings.has_prefix(v, "https://") do return v
		}
	}
	return ""
}

status_json :: proc(s: Status, allocator := context.allocator) -> string {
	data, _ := json.marshal(s, allocator = allocator)
	return string(data)
}

// list_services: every profile service directory under the state root, sorted.
list_services :: proc(host: Host, allocator := context.temp_allocator) -> []string {
	l := layout_for(host, "x")
	out := make([dynamic]string, allocator)
	entries, err := os.read_all_directory_by_path(l.state_root, context.temp_allocator)
	if err != nil do return out[:]
	for e in entries {
		if e.type == .Directory && strings.has_prefix(e.name, SERVICE_PREFIX) do append(&out, strings.clone(e.name, allocator))
	}
	sort_strings(out[:])
	return out[:]
}

sort_strings :: proc(a: []string) {
	for i in 1 ..< len(a) {
		for j := i; j > 0 && a[j] < a[j - 1]; j -= 1 do a[j], a[j - 1] = a[j - 1], a[j]
	}
}

list_json :: proc(statuses: []Status, allocator := context.allocator) -> string {
	wrapper := struct {
		profiles: []Status `json:"profiles"`,
	}{statuses}
	data, _ := json.marshal(wrapper, allocator = allocator)
	return string(data)
}
