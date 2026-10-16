package taskv2

import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import jsonx "odin_test:lib/jsonx"

// Facets (plan §4b): typed, versioned bodies attached to (task, attempt) and
// stored VERBATIM — the hub never re-marshals a facet, it only checks that the
// body is a JSON object and (for the kinds it reads) that the fields it needs
// are present. One writer per (attempt, kind); a rewrite bumps `v`.

FACET_HANDOFF :: "handoff"
FACET_VCS     :: "vcs"
FACET_VERIFY  :: "verify"
FACET_OUTPUT  :: "output"

FACET_WRITER_AGENT  :: "agent"
FACET_WRITER_BRIDGE :: "bridge"
FACET_WRITER_HUB    :: "hub"
FACET_WRITER_USER   :: "user"

// Write-time caps (plan §4c): the brief and findings are capped when written
// so the pack never has to cut them; longer free text is truncated with
// `truncated:true` added to the facet (never inside a field).
HANDOFF_SUMMARY_MAX    :: 4000
HANDOFF_NEXT_STEPS_MAX :: 4000
FINDINGS_MAX           :: 50
FINDING_TEXT_MAX       :: 2000

// save_facet_verbatim stores `body_json` (must be a JSON object) for
// (task, attempt, kind), bumping v when it replaces an earlier body.
save_facet_verbatim :: proc(svc: ^Service, task: domain.Task, attempt_no: int, kind, body_json, writer: string) -> (bool, domain.Domain_Error) {
	body := strings.trim_space(body_json)
	if !strings.has_prefix(body, "{") || !strings.has_suffix(body, "}") {
		return false, domain.domain_error(.Validation_Failed, fmt.tprintf("facet %s must be a JSON object", kind))
	}
	v := 1
	if facets, err := iface.taskchain_list_facets_by_task(svc.repo, task.task_id, task.owner_user_id); err.code == .None {
		for f in facets do if f.attempt_no == attempt_no && f.kind == kind && f.v >= v do v = f.v + 1
	}
	return iface.taskchain_save_facet(svc.repo, domain.Task_Attempt_Facet{
		task_id = task.task_id, attempt_no = attempt_no, chain_id = task.chain_id, owner_user_id = task.owner_user_id,
		kind = kind, v = v, body_json = body, writer = writer, written_at = platform.clock_now(svc.clock),
	})
}

get_facet :: proc(svc: ^Service, task: domain.Task, attempt_no: int, kind: string) -> (domain.Task_Attempt_Facet, bool) {
	facets, err := iface.taskchain_list_facets_by_task(svc.repo, task.task_id, task.owner_user_id)
	if err.code != .None do return {}, false
	for f in facets do if f.attempt_no == attempt_no && f.kind == kind do return f, true
	return {}, false
}

// handoff_body_json builds the stored handoff facet from the agent's object:
// `summary` (required, caller-validated) is kept; `next_steps` and `summary`
// longer than the caps are cut and `truncated:true` is added at the top level.
// Every other field of the agent's object is kept verbatim.
handoff_body_json :: proc(summary: string, handoff_json: string) -> string {
	truncated := false
	s := summary
	if len(s) > HANDOFF_SUMMARY_MAX { s = s[:HANDOFF_SUMMARY_MAX]; truncated = true }
	o := json_begin()
	json_str(&o, "summary", s)
	seen_next := false
	if strings.has_prefix(strings.trim_space(handoff_json), "{") {
		if next, ok := jsonx.extract_string_found(handoff_json, "next_steps", true, context.temp_allocator); ok {
			n := next
			if len(n) > HANDOFF_NEXT_STEPS_MAX { n = n[:HANDOFF_NEXT_STEPS_MAX]; truncated = true }
			json_str(&o, "next_steps", n)
			seen_next = true
		}
		// Splice the remaining top-level members verbatim.
		for key, raw in jsonx_top_level_members(handoff_json) {
			if key == "summary" || (key == "next_steps" && seen_next) || key == "truncated" do continue
			json_raw(&o, key, raw)
		}
	}
	if truncated do json_bool(&o, "truncated", true)
	return json_end(&o)
}

// findings_body_json caps the findings array (count and per-finding text).
findings_json_capped :: proc(findings_json: string) -> (string, bool) {
	raw := strings.trim_space(findings_json)
	if raw == "" || raw == "null" do return "[]", false
	if !strings.has_prefix(raw, "[") do return "[]", true
	items := jsonx_top_level_array_items(raw)
	truncated := false
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	n := 0
	for it in items {
		if n >= FINDINGS_MAX { truncated = true; break }
		if n > 0 do strings.write_byte(&b, ',')
		item := it
		if len(item) > FINDING_TEXT_MAX + 2 {
			// an oversized finding is replaced by its (object-preserving) stub
			item = fmt.tprintf(`{{"text":"(finding truncated: %d bytes)","truncated":true}}`, len(it))
			truncated = true
		}
		strings.write_string(&b, item)
		n += 1
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b), truncated
}

// ---- tiny verbatim JSON walkers (no re-marshalling) -------------------------------------

// jsonx_top_level_members returns key → raw value text for a JSON object.
jsonx_top_level_members :: proc(obj: string) -> map[string]string {
	out := make(map[string]string, context.temp_allocator)
	s := strings.trim_space(obj)
	if len(s) < 2 do return out
	i := 1
	n := len(s) - 1
	for i < n {
		for i < n && (s[i] == ' ' || s[i] == '\n' || s[i] == '\t' || s[i] == '\r' || s[i] == ',') do i += 1
		if i >= n || s[i] != '"' do break
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
		out[key] = s[vstart:vend]
		i = vend
	}
	return out
}

jsonx_top_level_array_items :: proc(arr: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	s := strings.trim_space(arr)
	if len(s) < 2 do return out[:]
	i := 1
	n := len(s) - 1
	for i < n {
		for i < n && (s[i] == ' ' || s[i] == '\n' || s[i] == '\t' || s[i] == '\r' || s[i] == ',') do i += 1
		if i >= n do break
		vend := json_value_end(s, i, n)
		append(&out, s[i:vend])
		i = vend
	}
	return out[:]
}

@(private = "file")
json_value_end :: proc(s: string, start, limit: int) -> int {
	i := start
	if i >= limit do return limit
	switch s[i] {
	case '"':
		i += 1
		for i < limit && s[i] != '"' { if s[i] == '\\' do i += 1; i += 1 }
		return min(i + 1, limit)
	case '{', '[':
		depth := 0
		in_str := false
		for i < limit {
			c := s[i]
			if in_str {
				if c == '\\' { i += 2; continue }
				if c == '"' do in_str = false
			} else {
				switch c {
				case '"': in_str = true
				case '{', '[': depth += 1
				case '}', ']':
					depth -= 1
					if depth == 0 do return i + 1
				}
			}
			i += 1
		}
		return limit
	case:
		for i < limit && s[i] != ',' && s[i] != '}' && s[i] != ']' do i += 1
		return i
	}
}

// ---- task.fetch -----------------------------------------------------------------------------

// fetch_ref resolves `#<event_id>` or `facet:<task>:<attempt>:<kind>` for a
// task the caller may read; returns the raw JSON (event row or facet body).
// Path refs (file at a commit) arrive with the commit-diff route in M3.
fetch_ref :: proc(svc: ^Service, task: domain.Task, ref: string) -> (string, bool, domain.Domain_Error) {
	r := strings.trim_space(ref)
	if strings.has_prefix(r, "#") {
		want := r[1:]
		evs, err := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
		if err.code != .None do return "", false, err
		for e in evs {
			if fmt.tprintf("%d", e.event_id) == want {
				o := json_begin()
				json_int(&o, "event_id", e.event_id)
				json_str(&o, "task_id", string(e.task_id))
				json_str(&o, "kind", e.kind)
				json_str(&o, "actor_kind", e.actor_kind)
				json_str(&o, "actor_id", e.actor_id)
				json_int(&o, "ts_ms", e.ts_ms)
				json_raw(&o, "payload", e.payload_json)
				return json_end(&o), true, domain.Domain_Error{}
			}
		}
		return "", false, domain.domain_error(.Not_Found, "event not found on this task")
	}
	if strings.has_prefix(r, "facet:") {
		parts := strings.split(r, ":", context.temp_allocator)
		if len(parts) != 4 do return "", false, domain.domain_error(.Validation_Failed, "facet ref is facet:<task_id>:<attempt_no>:<kind>")
		if parts[1] != string(task.task_id) do return "", false, domain.domain_error(.Validation_Failed, "facet ref names another task")
		attempt := jsonx.extract_int(fmt.tprintf(`{{"n":%s}}`, parts[2]), "n", -1, true)
		if attempt < 0 do return "", false, domain.domain_error(.Validation_Failed, "facet attempt_no must be an integer")
		f, ok := get_facet(svc, task, attempt, parts[3])
		if !ok do return "", false, domain.domain_error(.Not_Found, "facet not found")
		o := json_begin()
		json_str(&o, "kind", f.kind)
		json_int(&o, "attempt_no", i64(f.attempt_no))
		json_int(&o, "v", i64(f.v))
		json_str(&o, "writer", f.writer)
		json_str(&o, "written_at", f.written_at)
		json_raw(&o, "body", f.body_json)
		return json_end(&o), true, domain.Domain_Error{}
	}
	return "", false, domain.domain_error(.Validation_Failed, "ref must be #<event_id> or facet:<task>:<attempt>:<kind> (path refs arrive with the commit-diff route)")
}
