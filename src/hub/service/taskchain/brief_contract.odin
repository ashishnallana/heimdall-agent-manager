package taskchain

// Brief contracts (REQ-TV2-4): the one brief schema create, update and propose
// share; the top-level merge `task update` applies; the leased-edit refusal; and
// the reviewer identity check.

import "core:slice"
import "core:strings"
import json "core:encoding/json"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskv2 "odin_test:hub/service/taskv2"

// BRIEF_KEYS is the brief schema. The removed verification keys
// (taskv2.REMOVED_VERIFY_BRIEF_KEYS) are accepted and dropped separately.
BRIEF_KEYS := [?]string{"goal", "acceptance", "inputs", "review_roles", "assignee", "reviewers", "budget", "output", "on_output", "requires_user_approval", "approver", "gate"}

// LEASED_BRIEF_EDIT_KEYS: the brief keys a leased task still accepts, because
// changing them does not change the in-flight work. Everything else waits for
// the hold/checkpoint (REQ-TV2-5) or for the lease to end.
LEASED_BRIEF_EDIT_KEYS := [?]string{"acceptance"}

brief_key_known :: proc(key: string) -> bool {
	for k in BRIEF_KEYS do if k == key do return true
	for k in taskv2.REMOVED_VERIFY_BRIEF_KEYS do if k == key do return true
	return false
}

// brief_unknown_fields lists the top-level brief keys outside the schema,
// sorted. A brief that is not a JSON object yields nil (the caller reports that).
brief_unknown_fields :: proc(brief: string) -> []string {
	if strings.trim_space(brief) == "" do return nil
	parsed, err := json.parse_string(brief, allocator = context.temp_allocator)
	if err != nil do return nil
	obj, ok := parsed.(json.Object)
	if !ok do return nil
	out := make([dynamic]string, context.temp_allocator)
	for key in obj do if !brief_key_known(key) do append(&out, key)
	slice.sort(out[:])
	return out[:]
}

write_json_string_array :: proc(b: ^strings.Builder, items: []string) {
	strings.write_byte(b, '[')
	for s, i in items {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_byte(b, '"'); contracts.write_json_string(b, s); strings.write_byte(b, '"')
	}
	strings.write_byte(b, ']')
}

// unknown_brief_fields_error rejects a brief with keys outside the schema
// instead of dropping them silently.
unknown_brief_fields_error :: proc(fields: []string) -> domain.Domain_Error {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"code":"unknown_brief_fields","unknown_brief_fields":`)
	write_json_string_array(&b, fields)
	strings.write_string(&b, `,"allowed":`)
	write_json_string_array(&b, BRIEF_KEYS[:])
	strings.write_byte(&b, '}')
	return domain.domain_error(.Validation_Failed, strings.concatenate({"unknown_brief_fields: ", strings.join(fields, ", ", context.temp_allocator)}, context.temp_allocator), strings.to_string(b))
}

// validate_brief_schema: a non-empty brief must be a JSON object with only
// schema keys.
validate_brief_schema :: proc(brief: string) -> domain.Domain_Error {
	if strings.trim_space(brief) == "" do return domain.Domain_Error{}
	parsed, err := json.parse_string(brief, allocator = context.temp_allocator)
	if err != nil do return domain.domain_error(.Validation_Failed, "brief must be a JSON object")
	obj, ok := parsed.(json.Object)
	if !ok do return domain.domain_error(.Validation_Failed, "brief must be a JSON object")
	if unknown := brief_unknown_fields(brief); len(unknown) > 0 do return unknown_brief_fields_error(unknown)
	// acceptance: an array of strings, or null to clear it on update.
	if value, has := obj["acceptance"]; has {
		if _, is_null := value.(json.Null); !is_null {
			items, valid := value.(json.Array)
			if !valid do return domain.domain_error(.Validation_Failed, "brief.acceptance must be an array of strings")
			for item in items do if _, is_str := item.(json.String); !is_str do return domain.domain_error(.Validation_Failed, "brief.acceptance must be an array of strings")
		}
	}
	return domain.Domain_Error{}
}

// brief_merge_patch applies `patch` to `existing` as a top-level key merge: a
// key in the patch replaces the stored value, an explicit JSON null removes the
// key, and keys the patch does not name are kept.
brief_merge_patch :: proc(existing, patch: string) -> (string, domain.Domain_Error) {
	pv, perr := json.parse_string(patch, allocator = context.temp_allocator)
	if perr != nil do return "", domain.domain_error(.Validation_Failed, "brief must be a JSON object")
	pobj, pok := pv.(json.Object)
	if !pok do return "", domain.domain_error(.Validation_Failed, "brief must be a JSON object")
	base, berr := json.parse_string(existing if strings.trim_space(existing) != "" else "{}", allocator = context.temp_allocator)
	if berr != nil do return "", domain.domain_error(.Internal_Error, "stored brief is not valid JSON")
	root, rok := base.(json.Object)
	if !rok do return "", domain.domain_error(.Internal_Error, "stored brief is not an object")
	for key, value in pobj {
		if _, is_null := value.(json.Null); is_null {
			delete_key(&root, key)
		} else {
			root[key] = value
		}
	}
	encoded, merr := json.marshal(root, allocator = context.temp_allocator)
	if merr != nil do return "", domain.domain_error(.Internal_Error, "could not encode brief")
	return string(encoded), domain.Domain_Error{}
}

// json_values_equal compares two parsed JSON values structurally (object key
// order does not matter; 1 and 1.0 compare equal).
json_values_equal :: proc(a, b: json.Value) -> bool {
	num :: proc(v: json.Value) -> (f64, bool) {
		#partial switch n in v {
		case json.Integer: return f64(n), true
		case json.Float: return f64(n), true
		}
		return 0, false
	}
	if an, aok := num(a); aok {
		bn, bok := num(b)
		return bok && an == bn
	}
	#partial switch av in a {
	case json.Null:
		_, ok := b.(json.Null); return ok
	case json.Boolean:
		bv, ok := b.(json.Boolean); return ok && av == bv
	case json.String:
		bv, ok := b.(json.String); return ok && av == bv
	case json.Array:
		bv, ok := b.(json.Array)
		if !ok || len(av) != len(bv) do return false
		for item, i in av do if !json_values_equal(item, bv[i]) do return false
		return true
	case json.Object:
		bv, ok := b.(json.Object)
		if !ok || len(av) != len(bv) do return false
		for k, v in av {
			other, has := bv[k]
			if !has || !json_values_equal(v, other) do return false
		}
		return true
	}
	return false
}

// brief_changed_keys lists the top-level keys whose value differs between two
// briefs (added, removed or changed), sorted.
brief_changed_keys :: proc(before, after: string) -> []string {
	parse_obj :: proc(s: string) -> json.Object {
		v, err := json.parse_string(s if strings.trim_space(s) != "" else "{}", allocator = context.temp_allocator)
		if err != nil do return nil
		obj, _ := v.(json.Object)
		return obj
	}
	a, b := parse_obj(before), parse_obj(after)
	out := make([dynamic]string, context.temp_allocator)
	for k, v in a {
		other, has := b[k]
		if !has || !json_values_equal(v, other) do append(&out, k)
	}
	for k in b do if _, has := a[k]; !has do append(&out, k)
	slice.sort(out[:])
	return out[:]
}

// leased_edit_error refuses an edit of a leased task that would change the
// in-flight work, naming the offending fields and the allowed set.
leased_edit_error :: proc(fields: []string) -> domain.Domain_Error {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"code":"task_leased","fields":`)
	write_json_string_array(&b, fields)
	strings.write_string(&b, `,"allowed":["brief.acceptance","priority","depends_on","requires_user_approval"],"see":"REQ-TV2-5 hold/checkpoint"}`)
	msg := strings.concatenate({
		"task is leased: cannot change ", strings.join(fields, ", ", context.temp_allocator),
		" while a worker holds it. Allowed while leased: brief.acceptance, priority, depends_on, requires_user_approval. ",
		"Hold the task at a checkpoint (REQ-TV2-5) or wait for the lease to end, then edit.",
	}, context.temp_allocator)
	return domain.domain_error(.Conflict, msg, strings.to_string(b))
}

// validate_named_reviewers checks every named reviewer is a durable agent id
// (never an inst_… instance id) that resolves to an agent template.
validate_named_reviewers :: proc(service: ^Taskchain_Service, reviewers: []string) -> domain.Domain_Error {
	for raw in reviewers {
		id := strings.trim_space(raw)
		if id == "" do continue
		if strings.has_prefix(id, "inst_") do return taskv2.reviewer_must_be_agent_id_error(id)
		if service.agents != nil {
			if _, ok, _ := iface.agent_get(service.agents, id); !ok do return taskv2.reviewer_must_be_agent_id_error(id)
		}
	}
	return domain.Domain_Error{}
}
