package tool_live

// REQ-LIVE-7: Bridge-owned bounded volatile tracker. No writes or reads of
// historical extension events. All stored strings use the heap, never request
// arenas. The mutex protects entries and snapshot copies; change notification happens
// after unlock. Consumers reject older revisions (parallel publishers may race).
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"

TOOL_LIVE_MAX_INSTANCES :: 256
TOOL_LIVE_MAX_ACTIVE :: 32
TOOL_LIVE_MAX_TOMBSTONES :: 32
TOOL_LIVE_ID_MAX :: 64
TOOL_LIVE_NAME_MAX :: 96

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
	touched: u64,
	run_count: int,
}
Tool_Live_Store :: struct {
	mutex: sync.Mutex,
	epoch: i64, // boot epoch, initialized at service construction
	entries: map[string]^Tool_Live_Entry,
	admission_floor_ns: i64, // conservative replay fence after inactive entry reclamation
	revision_floor: u64, // revisions of forgotten instances must never move backwards
	next_touch: u64,
}
Tool_Live_Snapshot :: struct {
	type: string,
	instance_id: string,
	agent_id: string,
	display_name: string,
	chain_id: string,
	run_count: int,
	epoch: string,
	generation: u64,
	revision: u64,
	active: []Tool_Live_Call,
	last_completion: union {json.Null, Tool_Live_Completion},
}

// Model types deliberately have no Hub/repository dependency. Only Bridge owns
// a Tracker; Hub imports Snapshot for its authenticated volatile mirror.
Tracker :: struct {
	tool_live: Tool_Live_Store,
	ctx: rawptr,
	get_instance: proc(ctx: rawptr, id: string) -> (Instance, bool),
	publish: proc(ctx: rawptr, body: string),
}
Instance :: struct {
	agent_instance_id, owner_user_id, provider_session_id, agent_id, display_name, chain_id: string,
	runtime_status, launch_epoch: string,
	run_count: int,
}
Event :: struct { event, ts, session_id, agent_id, tool_use_id, tool_name, payload: string }
Shell :: struct {
	session_id, kind, agent_instance_id, owner_user_id, status: string,
	run_seq, exit_code: int,
	exit_code_set: bool,
	started_at_ms, finished_at_ms: i64,
}
terminal :: proc(status: string) -> bool {
	return status == "stopped" || status == "failed" || status == "exited" || status == "unreachable" || status == "terminated"
}
// Called at construction, not on the first event: a delayed bridge outbox from
// before Bridge restart must not repopulate activity.
tool_live_init :: proc(store: ^Tool_Live_Store) {
	store.epoch = time.to_unix_nanoseconds(time.now())
}
tool_live_text :: proc(obj: json.Object, key: string) -> string {
	v, _ := obj[key].(json.String)
	return string(v)
}
tool_live_ns :: proc(ts: string) -> (i64, bool) {
	t, consumed := time.rfc3339_to_time_utc(ts)
	if consumed == 0 do return 0, false
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
Tool_Live_Publication :: struct { owner, body: string }
tool_live_publish_eviction :: proc(service: ^Tracker, p: Tool_Live_Publication) {
	defer delete(p.owner)
	tool_live_publish(service, p.owner, p.body)
}
tool_live_entry_free :: proc(e: ^Tool_Live_Entry) {
	tool_live_reset_locked(e, 0)
	delete(e.active); delete(e.tombstones); delete(e.owner); delete(e.session); free(e)
}
// Reclaim the least recently touched INACTIVE entry. Active calls are never
// evicted. A shared admission cutoff remembers forgotten lifecycle/tombstone
// fences without an unbounded per-instance graveyard. It applies only to newly
// admitted entries; existing active instances keep their own event cutoffs.
tool_live_entry_locked :: proc(service: ^Tracker, id, owner: string, evicted: ^Tool_Live_Publication) -> ^Tool_Live_Entry {
	s := &service.tool_live
	if s.epoch == 0 do tool_live_init(s)
	if len(id) > TOOL_LIVE_ID_MAX || len(owner) > TOOL_LIVE_ID_MAX do return nil
	s.next_touch += 1
	if e, ok := s.entries[id]; ok {
		if e.owner != owner do return nil
		e.touched = s.next_touch
		return e
	}
	if len(s.entries) >= TOOL_LIVE_MAX_INSTANCES {
		victim: ^Tool_Live_Entry
		victim_id: string
		for key, e in s.entries {
			if len(e.active) == 0 && (victim == nil || e.touched < victim.touched) {
				victim = e; victim_id = key
			}
		}
		if victim == nil do return nil
		s.admission_floor_ns = max(s.admission_floor_ns, time.to_unix_nanoseconds(time.now()), victim.floor_ns, victim.session_ns)
		for tomb in victim.tombstones do s.admission_floor_ns = max(s.admission_floor_ns, tomb.ended_ns)
		if victim.has_last do s.admission_floor_ns = max(s.admission_floor_ns, (victim.last.completed_at_ms + 1) * 1_000_000)
		s.revision_floor = max(s.revision_floor, victim.revision) + 1
		inst := Instance{agent_instance_id = victim_id}
		if service.get_instance != nil {
			if fresh, found := tool_live_instance(service, victim_id); found do inst = fresh
		}
		// Publish the reclaimed empty snapshot with a newer revision, so connected
		// clients and reconnect readers agree that the old summary was forgotten.
		evicted.owner = strings.clone(victim.owner)
		evicted.body = tool_live_json_locked(s, inst, nil)
		delete_key(&s.entries, victim_id)
		tool_live_entry_free(victim); delete(victim_id)
	}
	if s.entries == nil do s.entries = make(map[string]^Tool_Live_Entry)
	e := new(Tool_Live_Entry)
	e.owner = strings.clone(owner)
	e.floor_ns = max(s.epoch, s.admission_floor_ns)
	e.generation = s.revision_floor + 1
	e.revision = s.revision_floor
	e.touched = s.next_touch
	s.entries[strings.clone(id)] = e
	return e
}
tool_live_epoch :: proc(s: ^Tool_Live_Store) -> string {
	return fmt.tprintf("%d", s.epoch)
}
tool_live_snapshot_locked :: proc(s: ^Tool_Live_Store, inst: Instance, e: ^Tool_Live_Entry) -> Tool_Live_Snapshot {
	snap := Tool_Live_Snapshot{type = "tool_activity_live", instance_id = inst.agent_instance_id,
		agent_id = inst.agent_id, display_name = inst.display_name, chain_id = inst.chain_id, run_count = inst.run_count, epoch = tool_live_epoch(s),
		generation = s.revision_floor + 1, revision = s.revision_floor, active = make([]Tool_Live_Call, 0, context.temp_allocator)}
	if e != nil {
		snap.run_count = e.run_count
		snap.generation = e.generation
		snap.revision = e.revision
		// Always emit [] when the last call ends, even if the backing array is nil.
		if len(e.active) > 0 do snap.active = e.active[:]
		if e.has_last do snap.last_completion = e.last
	}
	return snap
}
tool_live_json_locked :: proc(s: ^Tool_Live_Store, inst: Instance, e: ^Tool_Live_Entry) -> string {
	bytes, _ := json.marshal(tool_live_snapshot_locked(s, inst, e))
	return string(bytes)
}
// Caller already authorized the instance with get_instance. Reads only memory.
tool_live_snapshot :: proc(service: ^Tracker, inst: Instance) -> string {
	s := &service.tool_live
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	if s.epoch == 0 do tool_live_init(s)
	e, _ := s.entries[inst.agent_instance_id]
	if e != nil && e.owner != string(inst.owner_user_id) do e = nil
	return tool_live_json_locked(s, inst, e)
}
tool_live_publish :: proc(service: ^Tracker, owner, body: string) {
	if body == "" do return
	defer delete(body)
	if service.publish != nil do service.publish(service.ctx, body)
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

tool_live_instance :: proc(service: ^Tracker, id: string) -> (Instance, bool) {
	return service.get_instance(service.ctx, id)
}
tool_live_current_locked :: proc(service: ^Tracker, inst: Instance) -> bool {
	if service.get_instance == nil do return true
	fresh, ok := tool_live_instance(service, inst.agent_instance_id)
	return ok && fresh.owner_user_id == inst.owner_user_id && fresh.run_count == inst.run_count &&
		fresh.launch_epoch == inst.launch_epoch && !terminal(fresh.runtime_status)
}
tool_live_extension :: proc(service: ^Tracker, inst: Instance, evs: []Event) {
	if service == nil || len(evs) == 0 || terminal(inst.runtime_status) do return
	context.allocator = runtime.heap_allocator()
	s := &service.tool_live
	sync.mutex_lock(&s.mutex)
	if !tool_live_current_locked(service, inst) { sync.mutex_unlock(&s.mutex); return }
	evicted: Tool_Live_Publication
	defer tool_live_publish_eviction(service, evicted)
	e := tool_live_entry_locked(service, inst.agent_instance_id, string(inst.owner_user_id), &evicted)
	if e == nil { sync.mutex_unlock(&s.mutex); return }
	e.run_count = inst.run_count
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

// Only actual creation or successful restart may add a shell call. Row
// refreshes, background changes, inventory and recovered DB rows never add calls. Terminal updates require an
// existing live key, preventing stale row resurrection after restart or reset.
tool_live_shell :: proc(service: ^Tracker, session: Shell, starting: bool, replaced_run_seq: int = -1) {
	if service == nil || session.kind != "run" || session.agent_instance_id == "" ||
		len(session.session_id) > TOOL_LIVE_ID_MAX { return }
	inst := Instance{agent_instance_id = session.agent_instance_id, owner_user_id = session.owner_user_id}
	if service.get_instance != nil {
		fresh, ok := tool_live_instance(service, session.agent_instance_id)
		if !ok || string(fresh.owner_user_id) != session.owner_user_id do return
		inst = fresh
	}
	context.allocator = runtime.heap_allocator()
	s := &service.tool_live
	sync.mutex_lock(&s.mutex)
	if starting && !tool_live_current_locked(service, inst) { sync.mutex_unlock(&s.mutex); return }
	evicted: Tool_Live_Publication
	defer tool_live_publish_eviction(service, evicted)
	e: ^Tool_Live_Entry
	if starting do e = tool_live_entry_locked(service, session.agent_instance_id, session.owner_user_id, &evicted)
	else {
		e, _ = s.entries[session.agent_instance_id]
		if e != nil && e.owner != session.owner_user_id do e = nil
	}
	if e == nil { sync.mutex_unlock(&s.mutex); return }
	e.run_count = inst.run_count
	key := tool_live_key("shell", session.session_id, "", fmt.tprintf("%d", session.run_seq))
	ns := time.to_unix_nanoseconds(time.now())
    if starting && session.started_at_ms > 0 do ns = session.started_at_ms * 1_000_000
    if !starting && session.finished_at_ms > 0 do ns = session.finished_at_ms * 1_000_000
	changed := false
	if starting {
		if replaced_run_seq >= 0 && replaced_run_seq < session.run_seq {
			old_key := tool_live_key("shell", session.session_id, "", fmt.tprintf("%d", replaced_run_seq))
			tool_live_tombstone_locked(e, old_key, ns)
			for i := len(e.active)-1; i >= 0; i -= 1 {
				c := e.active[i]
				if c.shell_session_id != session.session_id || c.shell_run_seq != replaced_run_seq do continue
				tool_live_tombstone_locked(e, c.call_id, ns)
				tool_live_call_free(c); ordered_remove(&e.active, i)
				e.revision += 1; changed = true
			}
		}
		linked := false
		for &c in e.active {
			if c.source != "provider" || c.shell_session_id != session.session_id || c.shell_run_seq != session.run_seq do continue
			tool_live_tombstone_locked(e, c.call_id, ns)
			delete(c.call_id); delete(c.source)
			c.call_id = strings.clone(key); c.source = strings.clone("shell")
			c.started_at_ms = min(c.started_at_ms, ns / 1_000_000)
			e.revision += 1; changed = true; linked = true
			break
		}
		if !linked do changed = tool_live_start_locked(e, Tool_Live_Call{call_id = key, source = "shell", tool_name = "shell",
			shell_session_id = session.session_id, shell_run_seq = session.run_seq, started_at_ms = ns / 1_000_000}, ns) || changed
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
tool_live_clear :: proc(service: ^Tracker, instance_id: string) {
	if service == nil do return
	inst := Instance{agent_instance_id = instance_id}
	if service.get_instance != nil {
		if fresh, found := tool_live_instance(service, instance_id); found do inst = fresh
	}
	context.allocator = runtime.heap_allocator()
	s := &service.tool_live
	sync.mutex_lock(&s.mutex)
	evicted: Tool_Live_Publication
	defer tool_live_publish_eviction(service, evicted)
	e, ok := s.entries[instance_id]
	now_ns := time.to_unix_nanoseconds(time.now())
	if !ok {
		if inst.owner_user_id != "" do e = tool_live_entry_locked(service, instance_id, string(inst.owner_user_id), &evicted)
		if e == nil {
			// Even at all-active capacity, retain a cutoff for unseen instances.
			s.admission_floor_ns = max(s.admission_floor_ns, now_ns)
			sync.mutex_unlock(&s.mutex); return
		}
	}
	e.run_count = inst.run_count
	tool_live_reset_locked(e, now_ns)
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
		tool_live_entry_free(e); delete(k)
	}
	delete(store.entries)
	store.entries = nil
}


// An owned coherent copy for a reconnect/full resync. No historical calls.
tool_live_all :: proc(service: ^Tracker) -> [dynamic]string {
	context.allocator = runtime.heap_allocator()
	s := &service.tool_live
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	out := make([dynamic]string)
	for id, e in s.entries {
		inst := Instance{agent_instance_id = id}
		append(&out, tool_live_json_locked(s, inst, e))
	}
	return out
}
