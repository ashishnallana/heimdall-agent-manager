package main

// Agent blockers (REQ-EXT-BLK-1..5): what keeps an agent instance from making
// progress until a person acts, held IN MEMORY only (never persisted).
//
// Kinds:
//   permission       a blocked agent.extension.permission hook (extension_permission.odin).
//                    It lives in the permission relay's pending registry, and the
//                    blocked hook process (under pty-host) is the source of truth:
//                    after a bridge restart the hook re-registers the SAME
//                    blocker_id, so the registry rebuilds itself.
//   terminal_prompt  screen detection (pane_diff) says waiting_user and there is no
//                    permission blocker: "Waiting for input in terminal". There is
//                    no waiter and no remote answer; the UI links to the terminal.
//
// Sync to the hub: every change to an instance's VISIBLE set (undecided entries
// with a kind) bumps that instance's revision and marks it dirty. The hub loop
// drains dirty instances as FULL per-instance snapshots:
//   {"type":"agent_blockers","protocol_version":1,"agent_instance_id",
//    "revision","blockers":[...]}
// On every hub (re)connect and every bridge heartbeat all known instances are
// re-sent in full (no digest round trip: snapshots are small and the hub
// replaces its map wholesale). An instance whose empty snapshot was delivered is
// forgotten. Revisions are max(prev+1, now_ms), so they stay monotonic across a
// bridge restart.
//
// All state below is guarded by bridge_permission_mutex.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:sync"
import ws "odin_test:lib/ws"
import contracts "odin_test:contracts"

BRIDGE_BLOCKER_KIND_PERMISSION :: "permission"
BRIDGE_BLOCKER_KIND_TERMINAL_PROMPT :: "terminal_prompt"
BRIDGE_BLOCKER_TERMINAL_SUMMARY :: "Waiting for input in terminal"
// Per-blocker cap on the serialized tool input; a larger input is replaced by
// {"truncated":true} (the summary still names the command / file).
BRIDGE_BLOCKER_INPUT_MAX :: 4096
BRIDGE_BLOCKER_SUMMARY_MAX :: 200
BRIDGE_BLOCKER_ID_MAX :: 64
// At most this many blockers per instance go into one snapshot (oldest first).
BRIDGE_BLOCKER_SNAPSHOT_MAX :: 16
// A tool.start for the blocked tool counts as "answered in the terminal" only
// this long after registration: the same call's own PreToolUse hook runs just
// before PermissionRequest and may reach the bridge after it.
BRIDGE_BLOCKER_TOOL_START_GRACE_MS :: i64(2000)
BRIDGE_BLOCKER_TERMINAL_REASON :: "answered in the terminal"

Bridge_Blocker_Instance :: struct {
	revision:     i64,
	dirty:        bool,
	pane_waiting: bool, // last pane_diff classification was waiting_user
}

bridge_blocker_instances: map[string]Bridge_Blocker_Instance

// Bridge_Blocker_Frame is one snapshot taken for sending.
Bridge_Blocker_Frame :: struct {
	agent_instance_id: string,
	revision:          i64,
	count:             int,
	json:              string,
}

bridge_blockers_allocator :: proc() -> runtime.Allocator {
	return runtime.heap_allocator()
}

bridge_blocker_new_id :: proc() -> string {
	return fmt.aprintf("blk_%016x%08x", rand.uint64(), u32(rand.uint32()), allocator = bridge_blockers_allocator())
}

// bridge_blocker_valid_id: [A-Za-z0-9_-], 1..64 chars.
bridge_blocker_valid_id :: proc(id: string) -> bool {
	if id == "" || len(id) > BRIDGE_BLOCKER_ID_MAX do return false
	for ch in id {
		ok := (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-'
		if !ok do return false
	}
	return true
}

@(private = "file")
bridge_blocker_terminal_id :: proc(instance_id: string) -> string {
	return strings.concatenate({"term_", instance_id}, bridge_blockers_allocator())
}

@(private = "file")
bridge_blocker_state_locked :: proc(instance_id: string) -> ^Bridge_Blocker_Instance {
	if bridge_blocker_instances == nil do bridge_blocker_instances = make(map[string]Bridge_Blocker_Instance, 16, bridge_blockers_allocator())
	if _, ok := bridge_blocker_instances[instance_id]; !ok {
		bridge_blocker_instances[strings.clone(instance_id, bridge_blockers_allocator())] = {}
	}
	return &bridge_blocker_instances[instance_id]
}

// bridge_blockers_touch_locked records a change to the instance's visible set.
bridge_blockers_touch_locked :: proc(instance_id: string) {
	if instance_id == "" do return
	st := bridge_blocker_state_locked(instance_id)
	st.revision = max(st.revision + 1, bridge_runtime_now_ms())
	st.dirty = true
}

@(private = "file")
bridge_blockers_has_permission_locked :: proc(instance_id: string) -> bool {
	for p in bridge_permission_pending {
		if p.agent_instance_id == instance_id && p.kind == BRIDGE_BLOCKER_KIND_PERMISSION && !p.decided do return true
	}
	return false
}

@(private = "file")
bridge_blockers_remove_terminal_locked :: proc(instance_id: string) -> bool {
	removed := false
	for i := len(bridge_permission_pending) - 1; i >= 0; i -= 1 {
		p := bridge_permission_pending[i]
		if p.agent_instance_id != instance_id || p.kind != BRIDGE_BLOCKER_KIND_TERMINAL_PROMPT do continue
		ordered_remove(&bridge_permission_pending, i)
		removed = true
	}
	if removed do bridge_blockers_touch_locked(instance_id)
	return removed
}

// bridge_blockers_ensure_terminal_locked adds the screen-detected blocker when the
// pane waits for input and no permission blocker explains it.
@(private = "file")
bridge_blockers_ensure_terminal_locked :: proc(instance_id: string) {
	if bridge_blockers_has_permission_locked(instance_id) do return
	for p in bridge_permission_pending {
		if p.agent_instance_id == instance_id && p.kind == BRIDGE_BLOCKER_KIND_TERMINAL_PROMPT do return
	}
	context.allocator = bridge_blockers_allocator()
	now := bridge_runtime_now_ms()
	append(&bridge_permission_pending, Bridge_Permission_Pending{
		request_id = bridge_blocker_terminal_id(instance_id),
		agent_instance_id = strings.clone(instance_id),
		kind = BRIDGE_BLOCKER_KIND_TERMINAL_PROMPT,
		summary = BRIDGE_BLOCKER_TERMINAL_SUMMARY,
		input = "{}",
		created_unix_ms = now,
		generation = 1,
	})
	bridge_blockers_touch_locked(instance_id)
}

// bridge_blockers_after_removal_locked runs after an undecided blocker left the
// registry (timeout, cancel probe): the snapshot changed, and if the pane is
// still waiting the prompt is now the provider's own TUI prompt.
bridge_blockers_after_removal_locked :: proc(instance_id: string) {
	bridge_blockers_touch_locked(instance_id)
	if st, ok := bridge_blocker_instances[instance_id]; ok && st.pane_waiting do bridge_blockers_ensure_terminal_locked(instance_id)
}

// bridge_blockers_clear_instance_locked empties an instance's blockers when it
// stops: screen-detected entries are dropped (permission waiters were already
// released by the caller) and an empty snapshot is announced.
bridge_blockers_clear_instance_locked :: proc(instance_id: string) {
	_ = bridge_blockers_remove_terminal_locked(instance_id)
	if st, ok := &bridge_blocker_instances[instance_id]; ok {
		st.pane_waiting = false
		bridge_blockers_touch_locked(instance_id)
	}
}

// bridge_blockers_register_permission adds a permission blocker, or refreshes the
// one with the same (instance, blocker_id): a hook re-registering after a lost
// socket or a bridge restart. Returns the generation the caller's waiter owns.
bridge_blockers_register_permission :: proc(pending: Bridge_Permission_Pending) -> (generation: int, refreshed: bool) {
	sync.mutex_lock(&bridge_permission_mutex)
	defer sync.mutex_unlock(&bridge_permission_mutex)
	if bridge_permission_pending == nil do bridge_permission_pending = make([dynamic]Bridge_Permission_Pending, bridge_blockers_allocator())
	for i in 0..<len(bridge_permission_pending) {
		p := &bridge_permission_pending[i]
		if p.request_id != pending.request_id || p.agent_instance_id != pending.agent_instance_id do continue
		p.generation += 1
		p.deadline_unix_ms = pending.deadline_unix_ms
		// A decision that landed while the hook was reconnecting is kept for the
		// new waiter, which returns it at once.
		if !p.decided do bridge_blockers_touch_locked(p.agent_instance_id)
		return p.generation, true
	}
	entry := pending
	entry.kind = BRIDGE_BLOCKER_KIND_PERMISSION
	entry.generation = 1
	_ = bridge_blockers_remove_terminal_locked(entry.agent_instance_id)
	append(&bridge_permission_pending, entry)
	bridge_blockers_touch_locked(entry.agent_instance_id)
	return 1, false
}

// bridge_blockers_note_pane_activity feeds the screen detector's RAW
// classification (source pane_diff, before waiting_user is projected to idle)
// into the terminal_prompt fallback. "unknown" changes nothing.
bridge_blockers_note_pane_activity :: proc(instance_id, activity_status: string) {
	if strings.trim_space(instance_id) == "" do return
	s := strings.to_lower(strings.trim_space(activity_status), context.temp_allocator)
	if s == "" || s == "unknown" do return
	waiting := s == "waiting_user" || s == "waiting" || s == "waiting_approval"
	sync.mutex_lock(&bridge_permission_mutex)
	defer sync.mutex_unlock(&bridge_permission_mutex)
	if waiting {
		bridge_blocker_state_locked(instance_id).pane_waiting = true
		bridge_blockers_ensure_terminal_locked(instance_id)
		return
	}
	if st, ok := &bridge_blocker_instances[instance_id]; ok do st.pane_waiting = false
	_ = bridge_blockers_remove_terminal_locked(instance_id)
}

// bridge_blockers_release_locked releases one waiter with "none" (the provider
// already moved on).
@(private = "file")
bridge_blockers_release_locked :: proc(p: ^Bridge_Permission_Pending, reason: string) {
	p.decided = true
	p.decision = "none"
	p.reason = reason
	bridge_blockers_touch_locked(p.agent_instance_id)
}

// bridge_blockers_on_extension_event auto-resolves permission blockers the user
// answered in the provider's own TUI prompt (the hook is not killed then). A
// later event proves the prompt is gone:
//   tool.end for the same agent + tool          -> the oldest such blocker
//   tool.start for the same agent + tool        -> the oldest, after the grace window
//   subagent.stop                               -> every blocker of that subagent
//   activity idle|active, notification other
//   than permission_prompt                      -> every blocker of the instance
// Releasing with "none" is always safe: the hook prints nothing and the provider
// keeps whatever the terminal decided. Returns how many it released.
bridge_blockers_on_extension_event :: proc(instance_id: string, ev: contracts.Ext_Event, now: i64) -> int {
	if instance_id == "" do return 0
	sync.mutex_lock(&bridge_permission_mutex)
	defer sync.mutex_unlock(&bridge_permission_mutex)
	oldest := -1
	n := 0
	#partial switch ev.kind {
	case .Tool_End, .Tool_Start:
		if ev.tool_name == "" do return 0
		for p, i in bridge_permission_pending {
			if p.agent_instance_id != instance_id || p.kind != BRIDGE_BLOCKER_KIND_PERMISSION || p.decided do continue
			if p.tool != ev.tool_name || p.agent_id != ev.agent_id do continue
			if ev.kind == .Tool_Start && now - p.created_unix_ms < BRIDGE_BLOCKER_TOOL_START_GRACE_MS do continue
			if oldest < 0 || p.created_unix_ms < bridge_permission_pending[oldest].created_unix_ms do oldest = i
		}
		if oldest >= 0 {
			bridge_blockers_release_locked(&bridge_permission_pending[oldest], BRIDGE_BLOCKER_TERMINAL_REASON)
			n = 1
		}
	case .Subagent_Stop, .Activity, .Notification:
		if ev.kind == .Subagent_Stop && ev.agent_id == "" do return 0
		if ev.kind == .Notification && ev.notification_type == "permission_prompt" do return 0
		if ev.kind == .Activity {
			s := strings.to_lower(strings.trim_space(ev.activity_state), context.temp_allocator)
			if s != "idle" && s != "active" do return 0
		}
		for &p in bridge_permission_pending {
			if p.agent_instance_id != instance_id || p.kind != BRIDGE_BLOCKER_KIND_PERMISSION || p.decided do continue
			if ev.kind == .Subagent_Stop && p.agent_id != ev.agent_id do continue
			bridge_blockers_release_locked(&p, BRIDGE_BLOCKER_TERMINAL_REASON)
			n += 1
		}
	}
	return n
}

// bridge_blockers_cancel releases one permission blocker of the caller's
// instance (agent.extension.permission.cancel).
bridge_blockers_cancel :: proc(instance_id, blocker_id: string) -> bool {
	sync.mutex_lock(&bridge_permission_mutex)
	defer sync.mutex_unlock(&bridge_permission_mutex)
	for &p in bridge_permission_pending {
		if p.agent_instance_id != instance_id || p.request_id != blocker_id || p.kind != BRIDGE_BLOCKER_KIND_PERMISSION do continue
		if !p.decided do bridge_blockers_release_locked(&p, "cancelled by the extension")
		return true
	}
	return false
}

// bridge_blocker_summary is a one-line, provider-agnostic description:
// "<tool>: <command | file_path | path | url | pattern | description>".
bridge_blocker_summary :: proc(tool_name, input_json: string, allocator := context.allocator) -> string {
	detail := ""
	value, err := json.parse_string(input_json, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if obj, ok := value.(json.Object); err == .None && ok {
		for key in ([]string{"command", "file_path", "path", "url", "pattern", "description"}) {
			if s, is_str := obj[key].(json.String); is_str && strings.trim_space(s) != "" {
				detail = strings.trim_space(s)
				break
			}
		}
	}
	line := tool_name if detail == "" else strings.concatenate({tool_name, ": ", detail}, context.temp_allocator)
	// One line, clipped on a UTF-8 boundary.
	line, _ = strings.replace_all(line, "\n", " ", context.temp_allocator)
	if len(line) > BRIDGE_BLOCKER_SUMMARY_MAX {
		cut := BRIDGE_BLOCKER_SUMMARY_MAX
		for cut > 0 && (line[cut] & 0xC0) == 0x80 do cut -= 1
		line = strings.concatenate({line[:cut], "…"}, context.temp_allocator)
	}
	return strings.clone(line, allocator)
}

// bridge_blocker_cap_input keeps the tool input when it fits BRIDGE_BLOCKER_INPUT_MAX.
bridge_blocker_cap_input :: proc(input_json: string) -> string {
	trimmed := strings.trim_space(input_json)
	if trimmed == "" || !strings.has_prefix(trimmed, "{") do return "{}"
	if len(trimmed) > BRIDGE_BLOCKER_INPUT_MAX do return `{"truncated":true}`
	return trimmed
}

@(private = "file")
bridge_blocker_write_time :: proc(b: ^strings.Builder, ms: i64) {
	if ms <= 0 { strings.write_string(b, "\"\""); return }
	strings.write_byte(b, '"')
	strings.write_string(b, action_scheduler_format_rfc3339_utc(ms))
	strings.write_byte(b, '"')
}

// bridge_blockers_snapshot_json_locked renders the instance's visible blockers.
@(private = "file")
bridge_blockers_snapshot_json_locked :: proc(instance_id: string, revision: i64, allocator := context.allocator) -> (string, int) {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"type\":\"agent_blockers\",\"protocol_version\":1,\"agent_instance_id\":\"")
	bridge_runtime_write_json_string(&b, instance_id)
	strings.write_string(&b, fmt.tprintf("\",\"revision\":%d,\"blockers\":[", revision))
	count := 0
	for p in bridge_permission_pending {
		if p.agent_instance_id != instance_id || p.kind == "" || p.decided do continue
		if count >= BRIDGE_BLOCKER_SNAPSHOT_MAX do break
		if count > 0 do strings.write_byte(&b, ',')
		count += 1
		strings.write_string(&b, "{\"blocker_id\":\""); bridge_runtime_write_json_string(&b, p.request_id)
		strings.write_string(&b, "\",\"kind\":\""); bridge_runtime_write_json_string(&b, p.kind)
		strings.write_string(&b, "\",\"provider\":\""); bridge_runtime_write_json_string(&b, p.provider)
		strings.write_string(&b, "\",\"agent_id\":\""); bridge_runtime_write_json_string(&b, p.agent_id)
		strings.write_string(&b, "\",\"tool_name\":\""); bridge_runtime_write_json_string(&b, p.tool)
		strings.write_string(&b, "\",\"summary\":\""); bridge_runtime_write_json_string(&b, p.summary)
		strings.write_string(&b, "\",\"input\":"); strings.write_string(&b, p.input if strings.has_prefix(p.input, "{") else "{}")
		strings.write_string(&b, ",\"created_at\":"); bridge_blocker_write_time(&b, p.created_unix_ms)
		strings.write_string(&b, ",\"expires_at\":"); bridge_blocker_write_time(&b, p.deadline_unix_ms if p.kind == BRIDGE_BLOCKER_KIND_PERMISSION else 0)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b), count
}

// bridge_blockers_mark_all_dirty schedules a full resend (hub connect, heartbeat)
// of every known instance, or only of only_instance.
bridge_blockers_mark_all_dirty :: proc(only_instance := "") {
	sync.mutex_lock(&bridge_permission_mutex)
	defer sync.mutex_unlock(&bridge_permission_mutex)
	for id, &st in bridge_blocker_instances {
		if only_instance == "" || id == only_instance do st.dirty = true
	}
}

// bridge_blockers_take_snapshots renders every dirty instance (or only
// only_instance) and clears its dirty flag. The caller sends them and reports
// each outcome with bridge_blockers_ack.
bridge_blockers_take_snapshots :: proc(only_instance := "", allocator := context.allocator) -> [dynamic]Bridge_Blocker_Frame {
	out := make([dynamic]Bridge_Blocker_Frame, allocator)
	sync.mutex_lock(&bridge_permission_mutex)
	defer sync.mutex_unlock(&bridge_permission_mutex)
	for id, &st in bridge_blocker_instances {
		if !st.dirty do continue
		if only_instance != "" && id != only_instance do continue
		json, count := bridge_blockers_snapshot_json_locked(id, st.revision, allocator)
		append(&out, Bridge_Blocker_Frame{agent_instance_id = strings.clone(id, allocator), revision = st.revision, count = count, json = json})
		st.dirty = false
	}
	return out
}

// bridge_blockers_ack: a failed send is retried on the next drain; a delivered
// empty snapshot with nothing newer lets the instance be forgotten.
bridge_blockers_ack :: proc(frame: Bridge_Blocker_Frame, sent: bool) {
	sync.mutex_lock(&bridge_permission_mutex)
	defer sync.mutex_unlock(&bridge_permission_mutex)
	st, ok := &bridge_blocker_instances[frame.agent_instance_id]
	if !ok do return
	if !sent { st.dirty = true; return }
	if frame.count == 0 && !st.dirty && !st.pane_waiting && st.revision == frame.revision {
		key, _ := delete_key(&bridge_blocker_instances, frame.agent_instance_id)
		delete(key, bridge_blockers_allocator())
	}
}

bridge_blocker_frames_destroy :: proc(frames: ^[dynamic]Bridge_Blocker_Frame, allocator := context.allocator) {
	for f in frames {
		delete(f.agent_instance_id, allocator)
		delete(f.json, allocator)
	}
	delete(frames^)
}

// bridge_blockers_drain_outgoing sends dirty snapshots on the hub connection.
bridge_blockers_drain_outgoing :: proc(conn: ^ws.Connection) {
	frames := bridge_blockers_take_snapshots()
	defer bridge_blocker_frames_destroy(&frames)
	failed := false
	for f in frames {
		sent := !failed && bridge_hub_send(conn, f.json)
		if !sent && !failed {
			failed = true
			conn.connected = false
		}
		bridge_blockers_ack(f, sent)
	}
}

// Bridge_Blocker_View is a copy of one visible blocker (tests, status).
Bridge_Blocker_View :: struct {
	blocker_id: string,
	kind:       string,
	tool_name:  string,
	agent_id:   string,
	summary:    string,
}

bridge_blockers_list :: proc(instance_id: string, allocator := context.temp_allocator) -> []Bridge_Blocker_View {
	sync.mutex_lock(&bridge_permission_mutex)
	defer sync.mutex_unlock(&bridge_permission_mutex)
	out := make([dynamic]Bridge_Blocker_View, allocator)
	for p in bridge_permission_pending {
		if p.agent_instance_id != instance_id || p.kind == "" || p.decided do continue
		append(&out, Bridge_Blocker_View{
			blocker_id = strings.clone(p.request_id, allocator), kind = strings.clone(p.kind, allocator),
			tool_name = strings.clone(p.tool, allocator), agent_id = strings.clone(p.agent_id, allocator),
			summary = strings.clone(p.summary, allocator),
		})
	}
	return out[:]
}
