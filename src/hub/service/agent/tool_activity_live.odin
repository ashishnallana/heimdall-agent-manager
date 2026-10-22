package agent

// REQ-LIVE-1..3: a bounded, volatile projection. No repository writes or reads of
// historical extension events. All stored strings use the heap, never request
// arenas. The mutex protects entries and snapshot copies; publishing happens
// after unlock. Consumers reject older revisions (parallel publishers may race).
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"
import iface "odin_test:hub/repository/iface"
import domain "odin_test:hub/domain"
import events "odin_test:hub/service/events"
import platform "odin_test:hub/platform"

TOOL_LIVE_MAX_INSTANCES :: 2048
TOOL_LIVE_MAX_ACTIVE :: 128
TOOL_LIVE_MAX_TOMBSTONES :: 256
TOOL_LIVE_ID_MAX :: 512
TOOL_LIVE_NAME_MAX :: 128

Tool_Live_Call :: struct {
	call_id: string,
	source: string,
	provider_session_id: string,
	agent_id: string,
	tool_use_id: string,
	tool_name: string,
	shell_session_id: string,
	shell_run_seq: int,
	started_at_ms: i64,
}
Tool_Live_Completion :: struct {
	call_id: string,
	source: string,
	tool_name: string,
	duration_ms: i64,
	completed_at_ms: i64,
	status: string, // completed, failed, killed; never infer success from silence
}
Tool_Live_Tombstone :: struct { key: string, ended_ns: i64 }
Tool_Live_Entry :: struct {
	owner: string,
	session: string,
	generation: u64,
	revision: u64,
	floor_ns: i64, // evicted tombstones and lifecycle resets fence older starts
	session_ns: i64,
	session_closed: bool,
	active: [dynamic]Tool_Live_Call,
	tombstones: [dynamic]Tool_Live_Tombstone,
	last: Tool_Live_Completion,
	has_last: bool,
}
Tool_Live_Store :: struct {
	mutex: sync.Mutex,
	epoch: i64, // boot epoch, initialized at service construction
	entries: map[string]^Tool_Live_Entry,
}
Tool_Live_Snapshot :: struct {
	type: string,
	instance_id: string,
	agent_id: string,
	display_name: string,
	chain_id: string,
	epoch: string,
	generation: u64,
	revision: u64,
	active: []Tool_Live_Call,
	last_completion: union {json.Null, Tool_Live_Completion},
}

// Called at construction, not on the first event: a delayed bridge outbox from
// before Hub restart must not repopulate activity.
tool_live_init :: proc(store: ^Tool_Live_Store) {
	store.epoch = time.to_unix_nanoseconds(time.now())
}
tool_live_text :: proc(obj: json.Object, key: string) -> string {
	v, _ := obj[key].(json.String)
	return string(v)
}
tool_live_ns :: proc(ts: string) -> (i64, bool) {
	t, ok := platform.parse_rfc3339_utc(ts)
	if !ok do return 0, false
	return time.to_unix_nanoseconds(t), true
}
tool_live_key :: proc(source, session, agent, use_id: string) -> string {
	bytes, _ := json.marshal([4]string{source, session, agent, use_id}, allocator = context.temp_allocator)
	return string(bytes)
}
tool_live_call_clone :: proc(c: Tool_Live_Call) -> Tool_Live_Call {
	out := c
	out.call_id = strings.clone(c.call_id)
	out.source = strings.clone(c.source)
	out.provider_session_id = strings.clone(c.provider_session_id)
	out.agent_id = strings.clone(c.agent_id)
	out.tool_use_id = strings.clone(c.tool_use_id)
	out.tool_name = strings.clone(c.tool_name)
	out.shell_session_id = strings.clone(c.shell_session_id)
	return out
}
tool_live_call_free :: proc(c: Tool_Live_Call) {
	delete(c.call_id); delete(c.source); delete(c.provider_session_id)
	delete(c.agent_id); delete(c.tool_use_id); delete(c.tool_name); delete(c.shell_session_id)
}
tool_live_last_free :: proc(e: ^Tool_Live_Entry) {
	if !e.has_last do return
	delete(e.last.call_id); delete(e.last.source); delete(e.last.tool_name); delete(e.last.status)
	e.last = {}; e.has_last = false
}
tool_live_reset_locked :: proc(e: ^Tool_Live_Entry, cutoff_ns: i64) {
	for c in e.active do tool_live_call_free(c)
	clear(&e.active)
	for t in e.tombstones do delete(t.key)
	clear(&e.tombstones)
	tool_live_last_free(e)
	e.floor_ns = max(e.floor_ns, cutoff_ns)
	e.generation += 1
	e.revision += 1
}
tool_live_entry_locked :: proc(s: ^Tool_Live_Store, id, owner: string) -> ^Tool_Live_Entry {
	if s.epoch == 0 do tool_live_init(s)
	if e, ok := s.entries[id]; ok {
		if e.owner != owner do return nil
		return e
	}
	if len(s.entries) >= TOOL_LIVE_MAX_INSTANCES || len(id) > TOOL_LIVE_ID_MAX || len(owner) > TOOL_LIVE_ID_MAX do return nil
	if s.entries == nil do s.entries = make(map[string]^Tool_Live_Entry)
	e := new(Tool_Live_Entry)
	e.owner = strings.clone(owner)
	e.floor_ns = s.epoch
	e.generation = 1
	s.entries[strings.clone(id)] = e
	return e
}
tool_live_epoch :: proc(s: ^Tool_Live_Store) -> string {
	return fmt.tprintf("%d", s.epoch)
}
tool_live_snapshot_locked :: proc(s: ^Tool_Live_Store, inst: domain.Agent_Instance, e: ^Tool_Live_Entry) -> Tool_Live_Snapshot {
	snap := Tool_Live_Snapshot{type = "tool_activity_live", instance_id = inst.agent_instance_id,
		agent_id = inst.agent_id, display_name = inst.display_name, chain_id = inst.chain_id, epoch = tool_live_epoch(s),
		generation = 1, active = make([]Tool_Live_Call, 0, context.temp_allocator)}
	if e != nil {
		snap.generation = e.generation
		snap.revision = e.revision
		// Always emit [] when the last call ends, even if the backing array is nil.
		if len(e.active) > 0 do snap.active = e.active[:]
		if e.has_last do snap.last_completion = e.last
	}
	return snap
}
tool_live_json_locked :: proc(s: ^Tool_Live_Store, inst: domain.Agent_Instance, e: ^Tool_Live_Entry) -> string {
	bytes, _ := json.marshal(tool_live_snapshot_locked(s, inst, e))
	return string(bytes)
}
// Caller already authorized the instance with get_instance. Reads only memory.
tool_live_snapshot :: proc(service: ^Agent_Service, inst: domain.Agent_Instance) -> string {
	s := &service.tool_live
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	if s.epoch == 0 do tool_live_init(s)
	e, _ := s.entries[inst.agent_instance_id]
	if e != nil && e.owner != string(inst.owner_user_id) do e = nil
	return tool_live_json_locked(s, inst, e)
}
tool_live_publish :: proc(service: ^Agent_Service, owner, body: string) {
	if body == "" do return
	defer delete(body)
	if service.event_bus != nil do events.publish_raw_to_user(service.event_bus, owner, body)
}
tool_live_tombstone_locked :: proc(e: ^Tool_Live_Entry, key: string, ended_ns: i64) {
	for t in e.tombstones do if t.key == key do return
	if len(e.tombstones) >= TOOL_LIVE_MAX_TOMBSTONES {
		e.floor_ns = max(e.floor_ns, e.tombstones[0].ended_ns)
		delete(e.tombstones[0].key)
		ordered_remove(&e.tombstones, 0)
	}
	append(&e.tombstones, Tool_Live_Tombstone{strings.clone(key), ended_ns})
}
tool_live_start_locked :: proc(e: ^Tool_Live_Entry, c: Tool_Live_Call, ns: i64) -> bool {
	if ns <= e.floor_ns || len(e.active) >= TOOL_LIVE_MAX_ACTIVE do return false
	for t in e.tombstones do if t.key == c.call_id do return false
	for a in e.active do if a.call_id == c.call_id do return false
	append(&e.active, tool_live_call_clone(c))
	e.revision += 1
	return true
}
tool_live_end_locked :: proc(e: ^Tool_Live_Entry, key, status: string, ns: i64, duration_ms: i64 = -1) -> bool {
	for t in e.tombstones do if t.key == key do return false
	for c in e.active {
		if c.call_id == key && ns / 1_000_000 < c.started_at_ms do return false
	}
	// An end arriving before its start prevents a delayed start from becoming live.
	tool_live_tombstone_locked(e, key, ns)
	for c, i in e.active {
		if c.call_id != key do continue
		if ns / 1_000_000 < c.started_at_ms do return false
		if !e.has_last || ns / 1_000_000 >= e.last.completed_at_ms {
			tool_live_last_free(e)
			e.last = Tool_Live_Completion{call_id = strings.clone(key), source = strings.clone(c.source),
				tool_name = strings.clone(c.tool_name), duration_ms = duration_ms if duration_ms >= 0 else ns / 1_000_000 - c.started_at_ms,
				completed_at_ms = ns / 1_000_000, status = strings.clone(status)}
			e.has_last = true
		}
		tool_live_call_free(c)
		ordered_remove(&e.active, i)
		e.revision += 1
		return true
	}
	return false
}

// Identity reads use request-temp memory; the store never retains those strings.
tool_live_instance :: proc(service: ^Agent_Service, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	context.allocator = context.temp_allocator
	return iface.agent_get_instance(service.agents, id)
}
// Recheck under the projection lock: a terminal/configuration write may have
// overtaken the authentication/read before this lock was acquired. Repository
// callbacks do not acquire the projection lock.
tool_live_current_locked :: proc(service: ^Agent_Service, inst: domain.Agent_Instance) -> bool {
	if service.agents == nil do return true
	fresh, ok, _ := tool_live_instance(service, inst.agent_instance_id)
	return ok && fresh.owner_user_id == inst.owner_user_id && fresh.run_count == inst.run_count &&
		fresh.launch_epoch == inst.launch_epoch && !instance_runtime_is_terminal(fresh.runtime_status)
}
tool_live_extension :: proc(service: ^Agent_Service, inst: domain.Agent_Instance, evs: []domain.Agent_Extension_Event) {
	if service == nil || len(evs) == 0 || instance_runtime_is_terminal(inst.runtime_status) do return
	context.allocator = runtime.heap_allocator()
	s := &service.tool_live
	sync.mutex_lock(&s.mutex)
	if !tool_live_current_locked(service, inst) { sync.mutex_unlock(&s.mutex); return }
	e := tool_live_entry_locked(s, inst.agent_instance_id, string(inst.owner_user_id))
	if e == nil { sync.mutex_unlock(&s.mutex); return }
	before := e.revision
	now_ns := time.to_unix_nanoseconds(time.now())
	for ev in evs {
		ns, valid := tool_live_ns(ev.ts)
		// Untimestamped or historical frames remain in the Activity timeline, but
		// cannot resurrect live calls. No history is replayed at startup.
		if !valid || ns <= s.epoch || ns > now_ns + 60 * i64(time.Second) do continue
		if ns <= e.floor_ns && ev.event != "tool.end" && ev.event != "subagent.stop" do continue
		if len(ev.session_id) > TOOL_LIVE_ID_MAX || len(ev.agent_id) > TOOL_LIVE_ID_MAX || len(ev.tool_use_id) > TOOL_LIVE_ID_MAX do continue
		payload, _ := json.parse_string(ev.payload, .JSON, true, context.temp_allocator)
		po, _ := payload.(json.Object)
		if ev.event == "hello" || ev.event == "session" {
			if ev.session_id == "" || ns < e.session_ns do continue
			if e.session != ev.session_id {
				tool_live_reset_locked(e, ns - 1)
				delete(e.session); e.session = strings.clone(ev.session_id)
			}
			e.session_ns = ns
			e.session_closed = false
			if ev.event == "session" && tool_live_text(po, "phase") == "end" {
				tool_live_reset_locked(e, ns)
				e.session_closed = true
			}
			continue
		}
		if e.session_closed || ev.session_id == "" do continue
		if e.session == "" {
			// Initial tool event may arrive before hello. The canonical session in
			// the authenticated instance must agree; never switch session on a tool.
			if ev.session_id != inst.provider_session_id do continue
			e.session = strings.clone(ev.session_id)
		}
		if ev.session_id != e.session do continue
		if ev.event == "subagent.stop" {
			tool_live_tombstone_locked(e, tool_live_key("subagent", ev.session_id, ev.agent_id, ""), ns)
			// A stopped subagent cannot finish its unfinished calls successfully.
			for i := len(e.active)-1; i >= 0; i -= 1 {
				c := e.active[i]
				if c.source == "provider" && c.agent_id == ev.agent_id {
					tool_live_tombstone_locked(e, c.call_id, ns)
					tool_live_call_free(c); ordered_remove(&e.active, i); e.revision += 1
				}
			}
			continue
		}
		if ev.tool_use_id == "" do continue
		if ev.event == "tool.start" && ev.agent_id != "" {
			group_key := tool_live_key("subagent", ev.session_id, ev.agent_id, "")
			stopped := false
			for tomb in e.tombstones do if tomb.key == group_key && ns <= tomb.ended_ns do stopped = true
			if stopped do continue
		}
		key := tool_live_key("provider", ev.session_id, ev.agent_id, ev.tool_use_id)
		// Only explicit identity permits coalescing a provider wrapper with a Hub
		// shell run. Never compare command text, tool names or timing heuristically.
		shell_id := tool_live_text(po, "shell_session_id")
		if len(shell_id) > TOOL_LIVE_ID_MAX do shell_id = ""
		shell_seq := 0
		if seq, ok := po["shell_run_seq"].(json.Integer); ok && int(seq) >= 0 do shell_seq = int(seq)
		if ev.event == "tool.start" && shell_id != "" {
			shell_key := tool_live_key("shell", shell_id, "", fmt.tprintf("%d", shell_seq))
			already_ended := false
			for tomb in e.tombstones do if tomb.key == shell_key do already_ended = true
			if already_ended { tool_live_tombstone_locked(e, key, ns); continue }
			linked := false
			for &c in e.active {
				if c.source != "shell" || c.call_id != shell_key do continue
				linked = true
				if c.tool_use_id == "" {
					delete(c.provider_session_id); delete(c.agent_id); delete(c.tool_use_id)
					c.provider_session_id = strings.clone(ev.session_id)
					c.agent_id = strings.clone(ev.agent_id)
					c.tool_use_id = strings.clone(ev.tool_use_id)
					e.revision += 1
				}
			}
			if linked do continue
		}
		if ev.event == "tool.end" {
			linked := false
			for c in e.active {
				if c.source == "shell" && c.provider_session_id == ev.session_id &&
							c.agent_id == ev.agent_id && c.tool_use_id == ev.tool_use_id { linked = true }
			}
			// Returning from the provider wrapper (especially a background call) is not
			// process completion. The observed shell exit owns the duration and removal.
			if linked do continue
		}
		if ev.event == "tool.start" {
			cut := min(len(ev.tool_name), TOOL_LIVE_NAME_MAX)
			for cut > 0 && cut < len(ev.tool_name) && !utf8.rune_start(ev.tool_name[cut]) do cut -= 1
			name := ev.tool_name[:cut]
			_ = tool_live_start_locked(e, Tool_Live_Call{call_id = key, source = "provider",
				provider_session_id = ev.session_id, agent_id = ev.agent_id, tool_use_id = ev.tool_use_id,
				tool_name = name, shell_session_id = shell_id, shell_run_seq = shell_seq, started_at_ms = ns / 1_000_000}, ns)
		} else if ev.event == "tool.end" {
			status := "completed"
			if tool_live_text(po, "status") == "error" do status = "failed"
			if is_error, _ := po["is_error"].(json.Boolean); bool(is_error) do status = "failed"
			duration: i64 = -1
			if d, has := po["duration_ms"].(json.Integer); has && i64(d) >= 0 do duration = i64(d)
			_ = tool_live_end_locked(e, key, status, ns, duration)
		}
	}
	body: string
	if e.revision != before do body = tool_live_json_locked(s, inst, e)
	sync.mutex_unlock(&s.mutex)
	tool_live_publish(service, string(inst.owner_user_id), body)
}

// Only actual creation may add a shell call. Row refreshes, background changes,
// inventory and recovered DB rows never add calls. Terminal updates require an
// existing live key, preventing stale row resurrection after restart or reset.
tool_live_shell :: proc(service: ^Agent_Service, session: domain.Shell_Session, starting: bool) {
	if service == nil || session.kind != domain.Shell_Session_Kind_Run || session.agent_instance_id == "" ||
		len(session.session_id) > TOOL_LIVE_ID_MAX { return }
	inst := domain.Agent_Instance{agent_instance_id = session.agent_instance_id, owner_user_id = domain.User_ID(session.owner_user_id)}
	if service.agents != nil {
		fresh, ok, _ := tool_live_instance(service, session.agent_instance_id)
		if !ok || string(fresh.owner_user_id) != session.owner_user_id do return
		inst = fresh
	}
	context.allocator = runtime.heap_allocator()
	s := &service.tool_live
	sync.mutex_lock(&s.mutex)
	if starting && !tool_live_current_locked(service, inst) { sync.mutex_unlock(&s.mutex); return }
	e: ^Tool_Live_Entry
	if starting do e = tool_live_entry_locked(s, session.agent_instance_id, session.owner_user_id)
	else {
		e, _ = s.entries[session.agent_instance_id]
		if e != nil && e.owner != session.owner_user_id do e = nil
	}
	if e == nil { sync.mutex_unlock(&s.mutex); return }
	key := tool_live_key("shell", session.session_id, "", fmt.tprintf("%d", session.run_seq))
	ns := time.to_unix_nanoseconds(time.now())
	changed := false
	if starting {
		for &c in e.active {
			if c.source != "provider" || c.shell_session_id != session.session_id || c.shell_run_seq != session.run_seq do continue
			tool_live_tombstone_locked(e, c.call_id, ns)
			delete(c.call_id); delete(c.source)
			c.call_id = strings.clone(key); c.source = strings.clone("shell")
			c.started_at_ms = min(c.started_at_ms, ns / 1_000_000)
			e.revision += 1; changed = true
			break
		}
		if !changed do changed = tool_live_start_locked(e, Tool_Live_Call{call_id = key, source = "shell", tool_name = "shell",
			shell_session_id = session.session_id, shell_run_seq = session.run_seq, started_at_ms = ns / 1_000_000}, ns)
	} else {
		status := "interrupted"
		if session.status == "exited" || session.status == "killed" || session.status == "failed" do status = session.status
		if session.exit_code_set && session.exit_code != 0 && status == "exited" do status = "failed"
		// An inventory guess has no observed end. Label it explicitly rather than
		// presenting a normal completed duration.
		if !session.exit_code_set && status != "failed" && status != "killed" do status = "interrupted"
		changed = tool_live_end_locked(e, key, status, ns)
	}
	body: string
	if changed do body = tool_live_json_locked(s, inst, e)
	sync.mutex_unlock(&s.mutex)
	tool_live_publish(service, session.owner_user_id, body)
}
tool_live_clear :: proc(service: ^Agent_Service, instance_id: string) {
	if service == nil do return
	inst := domain.Agent_Instance{agent_instance_id = instance_id}
	if service.agents != nil {
		if fresh, found, _ := tool_live_instance(service, instance_id); found do inst = fresh
	}
	context.allocator = runtime.heap_allocator()
	s := &service.tool_live
	sync.mutex_lock(&s.mutex)
	e, ok := s.entries[instance_id]
	if !ok { sync.mutex_unlock(&s.mutex); return }
	tool_live_reset_locked(e, time.to_unix_nanoseconds(time.now()))
	body := tool_live_json_locked(s, inst, e)
	owner := strings.clone(e.owner)
	sync.mutex_unlock(&s.mutex)
	defer delete(owner)
	tool_live_publish(service, owner, body)
}
tool_live_destroy :: proc(store: ^Tool_Live_Store) {
	context.allocator = runtime.heap_allocator()
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)
	for k, e in store.entries {
		tool_live_reset_locked(e, 0)
		delete(e.active); delete(e.tombstones); delete(e.owner); delete(e.session); free(e); delete(k)
	}
	delete(store.entries)
	store.entries = nil
}

