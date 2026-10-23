package agent

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"
import events "odin_test:hub/service/events"

// Agent blockers (REQ-EXT-BLK-1..5): what keeps an agent instance from making
// progress until a person acts — a provider permission prompt (kind
// "permission", answerable from the UI) or a prompt screen detection saw in the
// terminal (kind "terminal_prompt", answered there).
//
// NOTHING IS PERSISTED. The hub keeps an in-memory map instance_id → {revision,
// blockers} that each bridge `agent_blockers` snapshot replaces wholesale. The
// map is empty on hub start and refills from the bridges' snapshots (sent on
// connect, on every change and on every heartbeat); a disconnected bridge's
// instances are dropped, and a terminal instance is cleared. The blocked hook
// process re-registers its stable blocker_id after a bridge restart, so a prompt
// reappears after the bridge AND the hub restart while the agent is still blocked.
//
// UI contract:
//   GET  /api/v1/agent-instances/{id}/blockers
//   POST /api/v1/agent-instances/{id}/blockers/{blocker_id}/resolve {decision, message?}
//   realtime resource_changed(agent_instance, {id}, agent_blockers_changed,
//                             {agent_instance_id, revision, count})
//
// The ONLY approval surface is the 'Needs you' attention deck/tray: the card
// service merges list_owner_blockers into GET /api/v1/attention (+ /summary) as
// item kind agent_blocker at read time, and every change also notes an
// attention_changed hint (kind agent_blocker) on the attention debouncer.

AGENT_BLOCKERS_REALTIME_CHANGE :: "agent_blockers_changed"
// Attention item kind (and attention_changed kind) for agent blockers.
AGENT_BLOCKER_ATTENTION_KIND :: "agent_blocker"
AGENT_BLOCKER_KIND_PERMISSION :: "permission"
AGENT_BLOCKER_KIND_TERMINAL_PROMPT :: "terminal_prompt"
// Bounds on what a bridge snapshot may carry (the bridge caps the same way).
AGENT_BLOCKERS_MAX_PER_INSTANCE :: 16
AGENT_BLOCKER_INPUT_MAX_BYTES :: 4096
AGENT_BLOCKER_TEXT_MAX :: 512
AGENT_BLOCKER_ID_MAX :: 64
AGENT_BLOCKER_MESSAGE_MAX :: 2_000

Agent_Blocker :: struct {
	blocker_id: string,
	kind:       string,
	json:       string, // canonical object, as served by the API
}

Agent_Blocker_Entry :: struct {
	bridge_id:     string,
	owner_user_id: string,
	chain_id:      string, // the instance's chain ('' when none), for attention scoping
	revision:      i64,
	blockers:      [dynamic]Agent_Blocker,
}

Agent_Blocker_Store :: struct {
	mutex:   sync.Mutex,
	entries: map[string]Agent_Blocker_Entry,
	// attention: optional debouncer noted (kind agent_blocker) on every change.
	attention: ^events.Attention_Debouncer,
	// record_events keeps every published summary in `events` (tests).
	record_events: bool,
	events:        [dynamic]string,
}

@(private = "file")
blockers_allocator :: proc() -> runtime.Allocator {
	return runtime.heap_allocator()
}

@(private = "file")
blocker_valid_id :: proc(id: string) -> bool {
	if id == "" || len(id) > AGENT_BLOCKER_ID_MAX do return false
	for ch in id {
		ok := (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-'
		if !ok do return false
	}
	return true
}

@(private = "file")
blocker_entry_destroy :: proc(e: ^Agent_Blocker_Entry) {
	context.allocator = blockers_allocator()
	for b in e.blockers {
		delete(b.blocker_id); delete(b.kind); delete(b.json)
	}
	delete(e.blockers)
	delete(e.bridge_id)
	delete(e.owner_user_id)
	delete(e.chain_id)
}

@(private = "file")
blocker_text :: proc(obj: json.Object, key: string) -> string {
	s, _ := obj[key].(json.String)
	if len(s) > AGENT_BLOCKER_TEXT_MAX do return s[:AGENT_BLOCKER_TEXT_MAX]
	return s
}

// blocker_canonical_json validates one bridge blocker object and renders the API
// shape. Unknown fields are dropped; an oversize input becomes {"truncated":true}.
@(private = "file")
blocker_canonical_json :: proc(obj: json.Object, agent_instance_id: string) -> (b: Agent_Blocker, ok: bool) {
	id := blocker_text(obj, "blocker_id")
	kind := blocker_text(obj, "kind")
	if !blocker_valid_id(id) do return {}, false
	if kind != AGENT_BLOCKER_KIND_PERMISSION && kind != AGENT_BLOCKER_KIND_TERMINAL_PROMPT do return {}, false
	input := "{}"
	if in_obj, is_obj := obj["input"].(json.Object); is_obj {
		if bytes, merr := json.marshal(in_obj, allocator = context.temp_allocator); merr == nil {
			input = string(bytes) if len(bytes) <= AGENT_BLOCKER_INPUT_MAX_BYTES else `{"truncated":true}`
		}
	}
	sb := strings.builder_make(blockers_allocator())
	strings.write_string(&sb, "{\"blocker_id\":\""); contracts.write_json_string(&sb, id)
	strings.write_string(&sb, "\",\"kind\":\""); contracts.write_json_string(&sb, kind)
	strings.write_string(&sb, "\",\"agent_instance_id\":\""); contracts.write_json_string(&sb, agent_instance_id)
	for key in ([]string{"provider", "agent_id", "tool_name", "summary", "created_at", "expires_at"}) {
		strings.write_string(&sb, "\",\""); strings.write_string(&sb, key); strings.write_string(&sb, "\":\"")
		contracts.write_json_string(&sb, blocker_text(obj, key))
	}
	strings.write_string(&sb, "\",\"input\":"); strings.write_string(&sb, input)
	strings.write_byte(&sb, '}')
	return Agent_Blocker{
		blocker_id = strings.clone(id, blockers_allocator()),
		kind = strings.clone(kind, blockers_allocator()),
		json = strings.to_string(sb),
	}, true
}

// blockers_publish emits resource_changed(agent_instance, id, agent_blockers_changed).
@(private = "file")
blockers_publish :: proc(service: ^Agent_Service, owner, instance_id: string, revision: i64, count: int) {
	if owner == "" do return
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\"agent_instance_id\":\""); contracts.write_json_string(&b, instance_id)
	strings.write_string(&b, fmt.tprintf("\",\"revision\":%d,\"count\":%d}", revision, count))
	summary := strings.to_string(b)
	if service.blockers.record_events {
		sync.mutex_lock(&service.blockers.mutex)
		append(&service.blockers.events, strings.clone(summary, blockers_allocator()))
		sync.mutex_unlock(&service.blockers.mutex)
	}
	if service.event_bus != nil do events.publish_resource_changed(service.event_bus, owner, "agent_instance", instance_id, AGENT_BLOCKERS_REALTIME_CHANGE, summary)
	if service.blockers.attention != nil do events.attention_debouncer_note(service.blockers.attention, owner, AGENT_BLOCKER_ATTENTION_KIND)
}

// apply_bridge_blockers_snapshot replaces an instance's blockers with the
// bridge's snapshot {agent_instance_id, revision, blockers:[...]}. bridge_id is
// the AUTHENTICATED connection's id: a bridge may only speak for instances it
// runs. Returns whether the snapshot was accepted.
apply_bridge_blockers_snapshot :: proc(service: ^Agent_Service, bridge_id, text: string) -> bool {
	if service == nil || service.agents == nil || bridge_id == "" do return false
	value, err := json.parse_string(text, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err != .None do return false
	root, is_obj := value.(json.Object)
	if !is_obj do return false
	instance_id, _ := root["agent_instance_id"].(json.String)
	if instance_id == "" do return false
	revision: i64
	#partial switch r in root["revision"] {
	case json.Integer: revision = i64(r)
	case json.Float: revision = i64(r)
	}
	inst, got, _ := iface.agent_get_instance(service.agents, instance_id)
	if !got || inst.bridge_id != bridge_id do return false

	fresh := make([dynamic]Agent_Blocker, blockers_allocator())
	// A stopped instance has no blockers whatever a late snapshot says.
	if inst.runtime_status != "stopped" && inst.runtime_status != "failed" {
		if arr, is_arr := root["blockers"].(json.Array); is_arr {
			for item in arr {
				if len(fresh) >= AGENT_BLOCKERS_MAX_PER_INSTANCE do break
				obj, ok := item.(json.Object)
				if !ok do continue
				if b, valid := blocker_canonical_json(obj, instance_id); valid do append(&fresh, b)
			}
		}
	}

	sync.mutex_lock(&service.blockers.mutex)
	if service.blockers.entries == nil do service.blockers.entries = make(map[string]Agent_Blocker_Entry, 16, blockers_allocator())
	old, had := service.blockers.entries[instance_id]
	changed := !had && len(fresh) > 0
	if had {
		changed = old.revision != revision || len(old.blockers) != len(fresh)
		if !changed {
			for b, i in fresh do if b.json != old.blockers[i].json { changed = true; break }
		}
	}
	owner := string(inst.owner_user_id)
	if had {
		key, _ := delete_key(&service.blockers.entries, instance_id)
		blocker_entry_destroy(&old)
		delete(key, blockers_allocator())
	}
	if len(fresh) > 0 {
		service.blockers.entries[strings.clone(instance_id, blockers_allocator())] = Agent_Blocker_Entry{
			bridge_id = strings.clone(bridge_id, blockers_allocator()),
			owner_user_id = strings.clone(owner, blockers_allocator()),
			chain_id = strings.clone(inst.chain_id, blockers_allocator()),
			revision = revision,
			blockers = fresh,
		}
	} else {
		delete(fresh)
	}
	count := len(fresh)
	sync.mutex_unlock(&service.blockers.mutex)
	if changed do blockers_publish(service, owner, instance_id, revision, count)
	return true
}

// clear_instance_blockers drops an instance's blockers (it stopped / died).
clear_instance_blockers :: proc(service: ^Agent_Service, instance_id: string) -> bool {
	if service == nil || instance_id == "" do return false
	sync.mutex_lock(&service.blockers.mutex)
	entry, had := service.blockers.entries[instance_id]
	owner, revision := "", i64(0)
	if had {
		owner = strings.clone(entry.owner_user_id, context.temp_allocator)
		revision = entry.revision
		key, _ := delete_key(&service.blockers.entries, instance_id)
		blocker_entry_destroy(&entry)
		delete(key, blockers_allocator())
	}
	sync.mutex_unlock(&service.blockers.mutex)
	if had do blockers_publish(service, owner, instance_id, revision + 1, 0)
	return had
}

// clear_bridge_blockers drops every blocker of a bridge that went offline; its
// snapshots come back when it reconnects.
clear_bridge_blockers :: proc(service: ^Agent_Service, bridge_id: string) -> int {
	if service == nil || bridge_id == "" do return 0
	ids := make([dynamic]string, context.temp_allocator)
	sync.mutex_lock(&service.blockers.mutex)
	for id, e in service.blockers.entries do if e.bridge_id == bridge_id do append(&ids, strings.clone(id, context.temp_allocator))
	sync.mutex_unlock(&service.blockers.mutex)
	n := 0
	for id in ids do if clear_instance_blockers(service, id) do n += 1
	return n
}

// instance_blocker_count is the current blocker count (0 when unknown).
instance_blocker_count :: proc(service: ^Agent_Service, instance_id: string) -> int {
	if service == nil do return 0
	sync.mutex_lock(&service.blockers.mutex)
	defer sync.mutex_unlock(&service.blockers.mutex)
	if e, ok := service.blockers.entries[instance_id]; ok do return len(e.blockers)
	return 0
}

// Owner_Blocker is one blocker as the attention read needs it (temp strings).
Owner_Blocker :: struct {
	agent_instance_id: string,
	chain_id:          string,
	blocker_id:        string,
	kind:              string,
	json:              string, // canonical API object (see blocker_canonical_json)
}

// list_owner_blockers copies every blocker of the owner's instances into the
// temp allocator, ordered by instance id then bridge order. Read-time only:
// this is what the attention deck merges in as kind agent_blocker.
list_owner_blockers :: proc(service: ^Agent_Service, owner_user_id: string) -> []Owner_Blocker {
	if service == nil || owner_user_id == "" do return nil
	out := make([dynamic]Owner_Blocker, context.temp_allocator)
	sync.mutex_lock(&service.blockers.mutex)
	for id, e in service.blockers.entries {
		if e.owner_user_id != owner_user_id do continue
		for blk in e.blockers {
			append(&out, Owner_Blocker{
				agent_instance_id = strings.clone(id, context.temp_allocator),
				chain_id = strings.clone(e.chain_id, context.temp_allocator),
				blocker_id = strings.clone(blk.blocker_id, context.temp_allocator),
				kind = strings.clone(blk.kind, context.temp_allocator),
				json = strings.clone(blk.json, context.temp_allocator),
			})
		}
	}
	sync.mutex_unlock(&service.blockers.mutex)
	return out[:]
}

// list_instance_blockers renders {agent_instance_id, revision, blockers:[...]} for
// the instance's owner.
list_instance_blockers :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string) -> (string, bool, domain.Domain_Error) {
	if service == nil || service.agents == nil do return "", false, domain.domain_error(.Internal_Error, "agent service is not configured")
	inst, got, err := get_instance(service, auth, instance_id)
	if !got do return "", false, err
	b := strings.builder_make()
	strings.write_string(&b, "{\"agent_instance_id\":\""); contracts.write_json_string(&b, inst.agent_instance_id)
	sync.mutex_lock(&service.blockers.mutex)
	entry, has := service.blockers.entries[instance_id]
	strings.write_string(&b, fmt.tprintf("\",\"revision\":%d,\"blockers\":[", entry.revision if has else 0))
	if has {
		for blk, i in entry.blockers {
			if i > 0 do strings.write_byte(&b, ',')
			strings.write_string(&b, blk.json)
		}
	}
	sync.mutex_unlock(&service.blockers.mutex)
	strings.write_string(&b, "]}")
	return strings.to_string(b), true, {}
}

// resolve_instance_blocker sends a USER's allow/deny for a permission blocker to
// the bridge as the existing permission_decision frame (request_id = blocker_id).
// The blocker leaves the list when the bridge's next snapshot arrives.
resolve_instance_blocker :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id, blocker_id, decision, message: string) -> (string, bool, domain.Domain_Error) {
	if service == nil || service.agents == nil do return "", false, domain.domain_error(.Internal_Error, "agent service is not configured")
	// An agent can never approve its own prompt.
	if auth.kind == .Instance_Token || auth.kind == .Bridge_Token || auth.kind == .Enrollment_Token || auth.kind == .None {
		return "", false, domain.domain_error(.Forbidden, "a user must resolve agent blockers")
	}
	d := strings.to_lower(strings.trim_space(decision), context.temp_allocator)
	if d != "allow" && d != "deny" do return "", false, domain.domain_error(.Validation_Failed, "decision must be allow or deny")
	if len(message) > AGENT_BLOCKER_MESSAGE_MAX do return "", false, domain.domain_error(.Validation_Failed, "message is too long")
	inst, got, err := get_instance(service, auth, instance_id)
	if !got do return "", false, err
	if owner_ok, owner_err := ownership.require_owner(auth, inst.owner_user_id); !owner_ok do return "", false, owner_err

	sync.mutex_lock(&service.blockers.mutex)
	kind, bridge_id := "", ""
	if entry, has := service.blockers.entries[instance_id]; has {
		for blk in entry.blockers {
			if blk.blocker_id != blocker_id do continue
			kind = strings.clone(blk.kind, context.temp_allocator)
			bridge_id = strings.clone(entry.bridge_id, context.temp_allocator)
			break
		}
	}
	sync.mutex_unlock(&service.blockers.mutex)
	if kind == "" do return "", false, domain.domain_error(.Not_Found, "agent blocker not found")
	if kind != AGENT_BLOCKER_KIND_PERMISSION do return "", false, domain.domain_error(.Conflict, "this blocker can only be answered in the terminal")

	command_id := platform.generate_id(service.ids, "cmd_")
	body := permission_decision_frame_json(command_id, instance_id, blocker_id, d, message)
	sent, _ := project_service.bridge_command_send_runtime(service.bridge_command_sink, project_service.Runtime_Command{bridge_id = bridge_id, command_id = command_id, body_json = body})
	if !sent do return "", false, domain.domain_error(.Conflict, "the agent's bridge is offline")
	b := strings.builder_make()
	strings.write_string(&b, "{\"resolved\":true,\"delivered\":true,\"agent_instance_id\":\""); contracts.write_json_string(&b, instance_id)
	strings.write_string(&b, "\",\"blocker_id\":\""); contracts.write_json_string(&b, blocker_id)
	strings.write_string(&b, "\",\"decision\":\""); contracts.write_json_string(&b, d)
	strings.write_string(&b, "\"}")
	return strings.to_string(b), true, {}
}

// permission_decision_frame_json is the hub → bridge frame that releases a
// blocked agent.extension.permission waiter.
permission_decision_frame_json :: proc(command_id, instance_id, blocker_id, decision, message: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"permission_decision\",\"protocol_version\":1,\"command_id\":\""); contracts.write_json_string(&b, command_id)
	strings.write_string(&b, "\",\"agent_instance_id\":\""); contracts.write_json_string(&b, instance_id)
	strings.write_string(&b, "\",\"request_id\":\""); contracts.write_json_string(&b, blocker_id)
	strings.write_string(&b, "\",\"decision\":\""); contracts.write_json_string(&b, decision)
	strings.write_string(&b, "\",\"message\":\""); contracts.write_json_string(&b, message)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}
