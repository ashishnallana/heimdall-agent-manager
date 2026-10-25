package taskchain

// Brief contracts (REQ-TV2-4): the top-level merge `task update` applies and
// the leased-edit refusal. The brief schema and the reviewer identity check
// live in taskv2 (brief_schema.odin) so chain.propose/decide share them.

import "core:slice"
import "core:strings"
import json "core:encoding/json"
import domain "odin_test:hub/domain"
import taskv2 "odin_test:hub/service/taskv2"

// LEASED_BRIEF_EDIT_KEYS: the brief keys a leased task still accepts, because
// changing them does not change the in-flight work. Everything else waits for
// the hold/checkpoint (REQ-TV2-5) or for the lease to end.
LEASED_BRIEF_EDIT_KEYS := [?]string{"acceptance"}

write_json_string_array :: proc(b: ^strings.Builder, items: []string) {
	taskv2.write_json_string_array(b, items)
}

// validate_brief_schema / validate_named_reviewers are the shared taskv2
// contracts (create, update, chain.propose/decide and workflow runs use them).
validate_brief_schema :: proc(brief: string) -> domain.Domain_Error {
	return taskv2.validate_brief_schema(brief)
}

validate_named_reviewers :: proc(service: ^Taskchain_Service, reviewers: []string) -> domain.Domain_Error {
	return taskv2.validate_reviewer_agent_ids(service.agents, reviewers)
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

// brief_apply_actor_fields sets the update convenience fields on a brief as
// top-level keys: assignee ("" removes it), review_roles (replaced), reviewers
// (replaced; an empty list removes the key). Other keys are left untouched.
brief_apply_actor_fields :: proc(brief, assignee: string, has_assignee: bool, review_roles: []string, has_roles: bool, reviewers: []string, has_reviewers: bool) -> (string, domain.Domain_Error) {
	base, berr := json.parse_string(brief if strings.trim_space(brief) != "" else "{}", allocator = context.temp_allocator)
	if berr != nil do return "", domain.domain_error(.Internal_Error, "stored brief is not valid JSON")
	root, rok := base.(json.Object)
	if !rok do return "", domain.domain_error(.Internal_Error, "stored brief is not an object")
	string_list :: proc(items: []string) -> json.Array {
		out := make(json.Array, context.temp_allocator)
		for raw in items {
			id := strings.trim_space(raw)
			if id == "" do continue
			dup := false
			for v in out do if string(v.(json.String)) == id { dup = true; break }
			if !dup do append(&out, json.String(id))
		}
		return out
	}
	if has_assignee {
		if a := strings.trim_space(assignee); a != "" {
			root["assignee"] = json.String(a)
		} else {
			delete_key(&root, "assignee")
		}
	}
	if has_roles do root["review_roles"] = string_list(review_roles)
	if has_reviewers {
		named := string_list(reviewers)
		if len(named) > 0 {
			root["reviewers"] = named
		} else {
			delete_key(&root, "reviewers")
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
