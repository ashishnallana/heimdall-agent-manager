package taskv2

import "core:strings"
import contracts "odin_test:contracts"

// Configured verification commands were removed (REQ-TV2-1). For one release
// the hub ACCEPTS AND DROPS the old keys (migration M2): they are stripped from
// every brief, chain default, proposal and workflow spec before storage, never
// executed, and the response carries
//   warnings:[{"code":"verify_removed","fields":[…]}]
// Afterwards they become an unknown-key error (REQ-TV2-4).

WARNING_VERIFY_REMOVED :: "verify_removed"

// REMOVED_VERIFY_BRIEF_KEYS: the brief / chain-default keys that are dropped.
REMOVED_VERIFY_BRIEF_KEYS := [?]string{"verify", "auto_submit", "require_independent_verify"}

// REMOVED_VERIFY_SUBMIT_KEYS: the lease.submit params that are dropped.
REMOVED_VERIFY_SUBMIT_KEYS := [?]string{"verify", "skip_verify", "skip_verify_reason", "auto"}

@(private = "file")
Json_Member :: struct {
	key: string, // still JSON-escaped, without quotes
	raw: string,
}

// top_level_members_ordered splits a JSON object into its members in source
// order (jsonx_top_level_members returns a map and loses the order).
@(private = "file")
top_level_members_ordered :: proc(obj: string) -> ([]Json_Member, bool) {
	s := strings.trim_space(obj)
	if len(s) < 2 || s[0] != '{' || s[len(s) - 1] != '}' do return nil, false
	out := make([dynamic]Json_Member, context.temp_allocator)
	i := 1
	n := len(s) - 1
	for i < n {
		for i < n && (s[i] == ' ' || s[i] == '\n' || s[i] == '\t' || s[i] == '\r' || s[i] == ',') do i += 1
		if i >= n do break
		if s[i] != '"' do return nil, false
		kstart := i + 1
		kend := kstart
		for kend < n && s[kend] != '"' { if s[kend] == '\\' do kend += 1; kend += 1 }
		key := s[kstart:kend]
		i = kend + 1
		for i < n && s[i] != ':' do i += 1
		i += 1
		for i < n && (s[i] == ' ' || s[i] == '\n' || s[i] == '\t' || s[i] == '\r') do i += 1
		vstart := i
		vend := json_value_end(s, vstart, n)
		append(&out, Json_Member{key = key, raw = s[vstart:vend]})
		i = vend
	}
	return out[:], true
}

@(private = "file")
key_in :: proc(key: string, keys: []string) -> bool {
	for k in keys do if k == key do return true
	return false
}

// strip_object_keys returns `obj` without the top-level members named in
// `keys`, keeping the remaining members (and their order) verbatim. The input
// is returned unchanged when it is not an object or none of the keys is present.
strip_object_keys :: proc(obj: string, keys: []string, allocator := context.temp_allocator) -> (clean: string, removed: []string) {
	members, ok := top_level_members_ordered(obj)
	if !ok do return obj, nil
	found := make([dynamic]string, allocator)
	for m in members do if key_in(m.key, keys) && !key_in(m.key, found[:]) do append(&found, m.key)
	if len(found) == 0 do return obj, nil
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '{')
	first := true
	for m in members {
		if key_in(m.key, keys) do continue
		if !first do strings.write_byte(&b, ',')
		first = false
		strings.write_byte(&b, '"')
		strings.write_string(&b, m.key)
		strings.write_string(&b, `":`)
		strings.write_string(&b, m.raw)
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b), found[:]
}

// strip_removed_verify_keys drops verify / auto_submit /
// require_independent_verify from one brief or chain-defaults object.
strip_removed_verify_keys :: proc(obj: string, allocator := context.temp_allocator) -> (clean: string, removed: []string) {
	return strip_object_keys(obj, REMOVED_VERIFY_BRIEF_KEYS[:], allocator)
}

// strip_removed_verify_keys_in_task_specs strips the removed keys from each
// proposed task spec of a chain.propose `tasks` array: from the spec's `brief`
// object and from the spec itself (the brief-less shorthand carried `verify`
// at the top level). Returns the array unchanged when nothing was removed.
strip_removed_verify_keys_in_task_specs :: proc(arr: string, allocator := context.temp_allocator) -> (clean: string, removed: []string) {
	items, ok := split_json_array_objects(arr, context.temp_allocator)
	if !ok do return arr, nil
	found := make([dynamic]string, allocator)
	out := make([dynamic]string, 0, len(items), context.temp_allocator)
	for item in items {
		spec, top := strip_removed_verify_keys(item)
		merge_removed(&found, top)
		if members, mok := top_level_members_ordered(spec); mok {
			for m in members {
				if m.key != "brief" do continue
				clean_brief, inner := strip_removed_verify_keys(m.raw)
				if len(inner) == 0 do break
				merge_removed(&found, inner)
				spec = replace_member_raw(members, "brief", clean_brief)
				break
			}
		}
		append(&out, spec)
	}
	if len(found) == 0 do return arr, nil
	return join_json_array(out[:], allocator), found[:]
}

// strip_removed_verify_keys_in_workflow_spec strips the removed keys from a
// workflow spec's `defaults` and from every stage `brief`.
strip_removed_verify_keys_in_workflow_spec :: proc(spec: string, allocator := context.temp_allocator) -> (clean: string, removed: []string) {
	members, ok := top_level_members_ordered(spec)
	if !ok do return spec, nil
	found := make([dynamic]string, allocator)
	changed := false
	for &m in members {
		switch m.key {
		case "defaults":
			if c, r := strip_removed_verify_keys(m.raw); len(r) > 0 {
				m.raw = c
				merge_removed(&found, r)
				changed = true
			}
		case "stages":
			stages, sok := split_json_array_objects(m.raw, context.temp_allocator)
			if !sok do continue
			stage_changed := false
			out := make([dynamic]string, 0, len(stages), context.temp_allocator)
			for st in stages {
				new_st := st
				if smembers, smok := top_level_members_ordered(st); smok {
					for sm in smembers {
						if sm.key != "brief" do continue
						if c, r := strip_removed_verify_keys(sm.raw); len(r) > 0 {
							new_st = replace_member_raw(smembers, "brief", c)
							merge_removed(&found, r)
							stage_changed = true
						}
						break
					}
				}
				append(&out, new_st)
			}
			if stage_changed {
				m.raw = join_json_array(out[:], context.temp_allocator)
				changed = true
			}
		}
	}
	if !changed do return spec, nil
	return members_to_object(members, allocator), found[:]
}

// verify_removed_warnings_json renders the response `warnings` array for the
// dropped fields, or "" when nothing was dropped.
verify_removed_warnings_json :: proc(fields: []string, allocator := context.temp_allocator) -> string {
	if len(fields) == 0 do return ""
	b := strings.builder_make(allocator)
	strings.write_string(&b, `[{"code":"`)
	strings.write_string(&b, WARNING_VERIFY_REMOVED)
	strings.write_string(&b, `","fields":[`)
	for f, i in fields {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_byte(&b, '"')
		contracts.write_json_string(&b, f)
		strings.write_byte(&b, '"')
	}
	strings.write_string(&b, `]}]`)
	return strings.to_string(b)
}

// merge_removed appends the names in `more` not already in `dst`.
merge_removed :: proc(dst: ^[dynamic]string, more: []string) {
	for f in more do if !key_in(f, dst[:]) do append(dst, f)
}

@(private = "file")
replace_member_raw :: proc(members: []Json_Member, key, raw: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	for m, i in members {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_byte(&b, '"')
		strings.write_string(&b, m.key)
		strings.write_string(&b, `":`)
		strings.write_string(&b, raw if m.key == key else m.raw)
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

@(private = "file")
members_to_object :: proc(members: []Json_Member, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '{')
	for m, i in members {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_byte(&b, '"')
		strings.write_string(&b, m.key)
		strings.write_string(&b, `":`)
		strings.write_string(&b, m.raw)
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

@(private = "file")
join_json_array :: proc(items: []string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '[')
	for it, i in items {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, it)
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}
