package agent

import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// Provider extension (ham.ext.v1) ingest + reads. Provider-agnostic: the hub only
// knows the canonical envelope, never a harness's native hook format.

// Retention: newest events kept per instance (older rows are trimmed on insert).
AGENT_EXTENSION_EVENTS_KEEP :: 5000
// Max events one ingest call may carry (the bridge flushes at 50).
AGENT_EXTENSION_BATCH_MAX :: 500

Extension_Ingest_Result :: struct {
	stored:          []domain.Agent_Extension_Event,
	rejected:        int,
	session_changed: bool,
	instance:        domain.Agent_Instance,
}

// extension_normalize_event maps one decoded ham.ext.v1 object onto a storable
// event plus the instance fields it implies (hello/session). ok=false rejects it.
extension_normalize_event :: proc(obj: json.Object, now: string) -> (ev: domain.Agent_Extension_Event, upd: domain.Agent_Extension_Instance_Update, ok: bool) {
	if ext_obj_string(obj, "schema") != contracts.EXT_SCHEMA_V1 do return
	event := ext_obj_string(obj, "event")
	if _, known := contracts.ext_event_kind_from_string(event); !known do return
	provider := ext_obj_string(obj, "provider")
	if strings.trim_space(provider) == "" do return

	payload_raw := "{}"
	payload_obj: json.Object
	if p, has := obj["payload"]; has {
		if po, is_obj := p.(json.Object); is_obj {
			payload_obj = po
			if bytes, merr := json.marshal(p, allocator = context.temp_allocator); merr == nil do payload_raw = string(bytes)
		}
	}
	if len(payload_raw) > contracts.EXT_EVENT_MAX_BYTES do return

	ev.event = strings.clone(event)
	ev.ts = strings.clone(ext_obj_string(obj, "ts"))
	ev.session_id = strings.clone(ext_obj_string(obj, "session_id"))
	if a, has := obj["agent"]; has {
		if ao, is_obj := a.(json.Object); is_obj {
			ev.agent_id = strings.clone(ext_obj_string(ao, "id"))
			ev.agent_type = strings.clone(ext_obj_string(ao, "type"))
		}
	}
	tool_input: json.Object
	if t, has := obj["tool"]; has {
		if to, is_obj := t.(json.Object); is_obj {
			ev.tool_name = strings.clone(ext_obj_string(to, "name"))
			ev.tool_use_id = strings.clone(ext_obj_string(to, "use_id"))
			if ti, has_in := to["input"]; has_in {
				if tio, in_obj := ti.(json.Object); in_obj do tool_input = tio
			}
		}
	}
	if event == "file.edit" {
		fp := ext_obj_string(payload_obj, "file_path")
		if fp == "" do fp = ext_obj_string(tool_input, "file_path")
		ev.file_path = strings.clone(fp)
	}
	ev.payload = strings.clone(payload_raw)
	ev.created_at = now

	upd.extension_provider = strings.clone(provider)
	upd.extension_version = strings.clone(ext_obj_string(obj, "ext_version"))
	upd.extension_last_seen_at = now
	if event == "hello" || event == "session" {
		upd.provider_session_id = ev.session_id
		upd.provider_transcript_path = strings.clone(ext_obj_string(obj, "transcript_path"))
	}
	if event == "hello" {
		if caps, has := payload_obj["capabilities"]; has {
			if _, is_arr := caps.(json.Array); is_arr {
				if bytes, merr := json.marshal(caps, allocator = context.temp_allocator); merr == nil do upd.extension_capabilities = strings.clone(string(bytes))
			}
		}
	}
	ok = true
	return
}

@(private = "file")
ext_obj_string :: proc(obj: json.Object, key: string) -> string {
	if obj == nil do return ""
	v, has := obj[key]
	if !has do return ""
	s, is_str := v.(json.String)
	if !is_str do return ""
	return string(s)
}

// extension_merge_update folds a later event's instance hints over an earlier
// one (last writer wins per non-empty field).
extension_merge_update :: proc(into: ^domain.Agent_Extension_Instance_Update, upd: domain.Agent_Extension_Instance_Update) {
	if upd.provider_session_id != "" do into.provider_session_id = upd.provider_session_id
	if upd.provider_transcript_path != "" do into.provider_transcript_path = upd.provider_transcript_path
	if upd.extension_provider != "" do into.extension_provider = upd.extension_provider
	if upd.extension_version != "" do into.extension_version = upd.extension_version
	if upd.extension_capabilities != "" do into.extension_capabilities = upd.extension_capabilities
	if upd.extension_last_seen_at != "" do into.extension_last_seen_at = upd.extension_last_seen_at
}

// extension_decode_batch accepts the ingest params: either {"events":[...]} or a
// single ham.ext.v1 object. Returns the decoded objects (temp-allocated).
extension_decode_batch :: proc(params: string) -> (objs: [dynamic]json.Object, ok: bool) {
	value, err := json.parse_string(params, .JSON, true, context.temp_allocator)
	if err != nil do return
	root, is_obj := value.(json.Object)
	if !is_obj do return
	objs = make([dynamic]json.Object, context.temp_allocator)
	if evs, has := root["events"]; has {
		arr, is_arr := evs.(json.Array)
		if !is_arr do return
		for item in arr {
			// Non-object items are kept as nil so they count as rejected.
			o, item_obj := item.(json.Object)
			append(&objs, o if item_obj else nil)
		}
		ok = true
		return
	}
	append(&objs, root)
	ok = true
	return
}

// ingest_extension_events stores a batch for the CALLER's instance (identity
// comes only from the instance token, never the payload) and applies the
// instance-level hints. Invalid events are counted, not fatal.
ingest_extension_events :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, params: string) -> (Extension_Ingest_Result, bool, domain.Domain_Error) {
	if service == nil || service.agents == nil do return {}, false, domain.domain_error(.Internal_Error, "agent service is not configured")
	if auth.kind != .Instance_Token || auth.agent_instance_id == "" do return {}, false, domain.domain_error(.Forbidden, "instance token is required")
	inst, got, err := iface.agent_get_instance(service.agents, auth.agent_instance_id)
	if !got do return {}, false, err
	if inst.owner_user_id != domain.User_ID(auth.user_id) do return {}, false, domain.domain_error(.Not_Found, "agent instance not found")

	objs, decoded := extension_decode_batch(params)
	if !decoded do return {}, false, domain.domain_error(.Validation_Failed, "params must be a ham.ext.v1 event or {\"events\":[...]}")
	if len(objs) > AGENT_EXTENSION_BATCH_MAX do return {}, false, domain.domain_error(.Validation_Failed, "too many events in one batch")

	now := platform.clock_now(service.clock)
	result := Extension_Ingest_Result{}
	events := make([dynamic]domain.Agent_Extension_Event, context.temp_allocator)
	upd := domain.Agent_Extension_Instance_Update{}
	for obj in objs {
		ev, ev_upd, ok := extension_normalize_event(obj, now)
		if !ok { result.rejected += 1; continue }
		append(&events, ev)
		extension_merge_update(&upd, ev_upd)
	}
	if len(events) > 0 {
		stored, ins_err := iface.agent_ext_insert_events(service.agents, inst.agent_instance_id, events[:], AGENT_EXTENSION_EVENTS_KEEP)
		if ins_err.code != .None do return {}, false, ins_err
		result.stored = stored
		if _, up_err := iface.agent_ext_update_instance(service.agents, inst.agent_instance_id, upd); up_err.code != .None do return {}, false, up_err
		result.session_changed = upd.provider_session_id != "" && upd.provider_session_id != inst.provider_session_id
		if fresh, ok2, _ := iface.agent_get_instance(service.agents, inst.agent_instance_id); ok2 do inst = fresh
	}
	tool_live_extension(service, inst, events[:])
	result.instance = inst
	return result, true, {}
}

// Reads (owner-scoped through get_instance).

list_extension_events :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id, agent_id: string, after_seq, limit: int) -> ([]domain.Agent_Extension_Event, bool, domain.Domain_Error) {
	inst, ok, err := get_instance(service, auth, instance_id)
	if !ok do return nil, false, err
	evs, lerr := iface.agent_ext_list_events(service.agents, inst.agent_instance_id, agent_id, after_seq, limit)
	if lerr.code != .None do return nil, false, lerr
	return evs, true, {}
}

list_extension_subagents :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string) -> ([]domain.Agent_Subagent_Summary, bool, domain.Domain_Error) {
	inst, ok, err := get_instance(service, auth, instance_id)
	if !ok do return nil, false, err
	subs, lerr := iface.agent_ext_list_subagents(service.agents, inst.agent_instance_id)
	if lerr.code != .None do return nil, false, lerr
	return subs, true, {}
}

list_extension_files :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string) -> ([]domain.Agent_File_Edit_Summary, bool, domain.Domain_Error) {
	inst, ok, err := get_instance(service, auth, instance_id)
	if !ok do return nil, false, err
	files, lerr := iface.agent_ext_list_files(service.agents, inst.agent_instance_id)
	if lerr.code != .None do return nil, false, lerr
	return files, true, {}
}
