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

FACET_HANDOFF   :: "handoff"
FACET_VCS       :: "vcs"
FACET_VERIFY    :: "verify" // legacy, read-only history (D2): nothing writes it, no gate/pack/alert reads it
FACET_OUTPUT    :: "output"
FACET_RUNTIME   :: "runtime"
FACET_ARTIFACTS :: "artifacts"

FACET_WRITER_AGENT  :: "agent"
FACET_WRITER_BRIDGE :: "bridge"
FACET_WRITER_HUB    :: "hub"

// Write-time caps (plan §4c): the brief and findings are capped when written
// so the pack never has to cut them; longer free text is truncated with
// `truncated:true` added to the facet (never inside a field).
HANDOFF_SUMMARY_MAX    :: 4000
HANDOFF_NEXT_STEPS_MAX :: 4000
FINDINGS_MAX           :: 50
FINDING_TEXT_MAX       :: 2000

// save_facet_verbatim stores `body_json` (must be a JSON object) for
// (task, attempt, kind), bumping v when it replaces an earlier body.
// u (when non-nil) receives a task/facet_changed effect on success, so the
// write is announced after COMMIT and never on rollback (REQ-2).
save_facet_verbatim :: proc(svc: ^Service, task: domain.Task, attempt_no: int, kind, body_json, writer: string, u: ^Uow = nil) -> (bool, domain.Domain_Error) {
	body := strings.trim_space(body_json)
	if !strings.has_prefix(body, "{") || !strings.has_suffix(body, "}") {
		return false, domain.domain_error(.Validation_Failed, fmt.tprintf("facet %s must be a JSON object", kind))
	}
	v := 1
	if facets, err := iface.taskchain_list_facets_by_task(svc.repo, task.task_id, task.owner_user_id); err.code == .None {
		for f in facets do if f.attempt_no == attempt_no && f.kind == kind && f.v >= v do v = f.v + 1
	}
	saved, err := iface.taskchain_save_facet(svc.repo, domain.Task_Attempt_Facet{
		task_id = task.task_id, attempt_no = attempt_no, chain_id = task.chain_id, owner_user_id = task.owner_user_id,
		kind = kind, v = v, body_json = body, writer = writer, written_at = platform.clock_now(svc.clock),
	})
	if saved do effect_publish_facet(u, task, attempt_no, kind)
	return saved, err
}

get_facet :: proc(svc: ^Service, task: domain.Task, attempt_no: int, kind: string) -> (domain.Task_Attempt_Facet, bool) {
	facets, err := iface.taskchain_list_facets_by_task(svc.repo, task.task_id, task.owner_user_id)
	if err.code != .None do return {}, false
	for f in facets do if f.attempt_no == attempt_no && f.kind == kind do return f, true
	return {}, false
}

is_vault_armored :: proc(s: string) -> bool {
	t := strings.trim_space(s)
	return domain.is_vault_armored(t)
}

// handoff_body_json builds the stored handoff facet from the agent's object:
// `summary` (required, caller-validated) is kept; `next_steps` and `summary`
// longer than the caps are cut and `truncated:true` is added at the top level
// (unless the value is vault-armored ciphertext, which must never be byte-sliced).
// Every other field of the agent's object is kept verbatim.
handoff_body_json :: proc(summary: string, handoff_json: string) -> string {
	truncated := false
	s := summary
	if len(s) > HANDOFF_SUMMARY_MAX && !is_vault_armored(s) { s = s[:HANDOFF_SUMMARY_MAX]; truncated = true }
	o := json_begin()
	json_str(&o, "summary", s)
	seen_next := false
	if strings.has_prefix(strings.trim_space(handoff_json), "{") {
		if next, ok := jsonx.extract_string_found(handoff_json, "next_steps", true, context.temp_allocator); ok {
			n := next
			if len(n) > HANDOFF_NEXT_STEPS_MAX && !is_vault_armored(n) { n = n[:HANDOFF_NEXT_STEPS_MAX]; truncated = true }
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
		if len(item) > FINDING_TEXT_MAX + 2 && !domain.contains_vault_token(item) {
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

// validate_artifacts_facet_json validates an `artifacts` facet body (plan §4b):
// either `{"items":[...]}` or `[...]` (wrapped into `{"items":[...]}`), where
// each item has `kind` in {"file", "url", "preview_port"} and either `ref` or
// the kind-specific field (`path`, `url`/`uri`, `port`), plus optional `label`/`title`.
validate_artifacts_facet_json :: proc(raw_in: string) -> (string, bool, domain.Domain_Error) {
	raw := strings.trim_space(raw_in)
	if raw == "" || raw == "null" do return "", false, domain.domain_error(.Validation_Failed, "artifacts must be a JSON object or array")
	items_raw := raw
	is_obj := false
	if strings.has_prefix(raw, "{") && strings.has_suffix(raw, "}") {
		is_obj = true
		members := jsonx_top_level_members(raw)
		if it, has := members["items"]; has {
			items_raw = strings.trim_space(it)
		} else {
			return "", false, domain.domain_error(.Validation_Failed, "artifacts object must contain an `items` array")
		}
	}
	if !strings.has_prefix(items_raw, "[") || !strings.has_suffix(items_raw, "]") {
		return "", false, domain.domain_error(.Validation_Failed, "artifacts items must be a JSON array")
	}
	items := jsonx_top_level_array_items(items_raw)
	for it in items {
		item := strings.trim_space(it)
		if !strings.has_prefix(item, "{") || !strings.has_suffix(item, "}") {
			return "", false, domain.domain_error(.Validation_Failed, "each artifact item must be a JSON object")
		}
		kind := strings.trim_space(jsonx.extract_string(item, "kind", "", true, context.temp_allocator))
		ref_str := strings.trim_space(jsonx.extract_string(item, "ref", "", true, context.temp_allocator))
		switch kind {
		case "file":
			p := strings.trim_space(jsonx.extract_string(item, "path", "", true, context.temp_allocator))
			if p == "" do p = ref_str
			if p == "" do return "", false, domain.domain_error(.Validation_Failed, "file artifact requires a non-empty `path` or `ref`")
		case "url", "link":
			u := strings.trim_space(jsonx.extract_string(item, "url", "", true, context.temp_allocator))
			if u == "" do u = strings.trim_space(jsonx.extract_string(item, "uri", "", true, context.temp_allocator))
			if u == "" do u = ref_str
			if u == "" do return "", false, domain.domain_error(.Validation_Failed, "url/link artifact requires a non-empty `url`, `uri`, or `ref`")
		case "preview_port":
			port, pok := jsonx.extract_int_found(item, "port", true)
			if !pok {
				port, pok = jsonx.extract_int_found(item, "ref", true)
			}
			if !pok && ref_str != "" {
				parsed := 0
				valid_digits := true
				for ch in ref_str {
					if ch < '0' || ch > '9' { valid_digits = false; break }
					parsed = parsed * 10 + int(ch - '0')
				}
				if valid_digits && parsed > 0 {
					port = parsed
					pok = true
				}
			}
			if !pok || port <= 0 || port > 65535 do return "", false, domain.domain_error(.Validation_Failed, "preview_port artifact requires a valid `port` or `ref` (1..65535)")
		case:
			return "", false, domain.domain_error(.Validation_Failed, "artifact kind must be file, url, link, or preview_port")
		}
	}
	if is_obj do return raw, true, domain.Domain_Error{}
	o := json_begin()
	json_raw(&o, "items", items_raw)
	return json_end(&o), true, domain.Domain_Error{}
}

// ---- task.fetch -----------------------------------------------------------------------------

// fetch_ref resolves `#<event_id>`, `output:<task_id>`, `facet:<task>:<attempt>:<kind>`,
// `dir:<directory_id>:<rev>:<path>`, or `<path>[@<rev>]` for a task the caller may read.
fetch_ref :: proc(svc: ^Service, task: domain.Task, ref: string) -> (string, bool, domain.Domain_Error) {
	r := strings.trim_space(ref)
	if r == "" do return "", false, domain.domain_error(.Validation_Failed, "ref is required")
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
		// Also search other tasks in the same chain if not found on this task
		if chain_tasks, terr := iface.taskchain_list_tasks_by_chain(svc.repo, task.chain_id, task.owner_user_id); terr.code == .None {
			for ct in chain_tasks {
				if ct.task_id == task.task_id do continue
				cevs, cerr := iface.taskchain_list_events_by_task(svc.repo, ct.task_id, task.owner_user_id)
				if cerr.code != .None do continue
				for e in cevs {
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
			}
		}
		return "", false, domain.domain_error(.Not_Found, "event not found on this task")
	}
	if strings.has_prefix(r, "output:") {
		target_id := strings.trim_space(r[len("output:"):])
		if target_id == "" do return "", false, domain.domain_error(.Validation_Failed, "output ref is output:<task_id>")
		target := task
		if target_id != string(task.task_id) {
			other, ook, _ := iface.taskchain_get_task(svc.repo, domain.Task_ID(target_id))
			if !ook || other.chain_id != task.chain_id || other.owner_user_id != task.owner_user_id {
				return "", false, domain.domain_error(.Not_Found, "output target task not found in chain")
			}
			target = other
		}
		facets, ferr := iface.taskchain_list_facets_by_task(svc.repo, target.task_id, target.owner_user_id)
		if ferr.code != .None do return "", false, ferr
		best := domain.Task_Attempt_Facet{}
		found := false
		for f in facets {
			if f.kind != FACET_OUTPUT do continue
			if !found || f.attempt_no > best.attempt_no || (f.attempt_no == best.attempt_no && f.v > best.v) {
				best = f
				found = true
			}
		}
		if !found do return "", false, domain.domain_error(.Not_Found, "output facet not found")
		o := json_begin()
		json_str(&o, "ref", r)
		json_str(&o, "task_id", string(target.task_id))
		json_str(&o, "kind", best.kind)
		json_int(&o, "attempt_no", i64(best.attempt_no))
		json_int(&o, "v", i64(best.v))
		json_str(&o, "writer", best.writer)
		json_str(&o, "written_at", best.written_at)
		json_raw(&o, "body", best.body_json)
		return json_end(&o), true, domain.Domain_Error{}
	}
	if strings.has_prefix(r, "facet:") {
		parts := strings.split(r, ":", context.temp_allocator)
		if len(parts) != 4 do return "", false, domain.domain_error(.Validation_Failed, "facet ref is facet:<task_id>:<attempt_no>:<kind>")
		target := task
		if parts[1] != string(task.task_id) {
			other, ook, _ := iface.taskchain_get_task(svc.repo, domain.Task_ID(parts[1]))
			if !ook || other.chain_id != task.chain_id || other.owner_user_id != task.owner_user_id {
				return "", false, domain.domain_error(.Validation_Failed, "facet ref names another task")
			}
			target = other
		}
		attempt := jsonx.extract_int(fmt.tprintf(`{{"n":%s}}`, parts[2]), "n", -1, true)
		if attempt < 0 do return "", false, domain.domain_error(.Validation_Failed, "facet attempt_no must be an integer")
		f, ok := get_facet(svc, target, attempt, parts[3])
		if !ok do return "", false, domain.domain_error(.Not_Found, "facet not found")
		o := json_begin()
		json_str(&o, "task_id", string(target.task_id))
		json_str(&o, "kind", f.kind)
		json_int(&o, "attempt_no", i64(f.attempt_no))
		json_int(&o, "v", i64(f.v))
		json_str(&o, "writer", f.writer)
		json_str(&o, "written_at", f.written_at)
		json_raw(&o, "body", f.body_json)
		return json_end(&o), true, domain.Domain_Error{}
	}
	if strings.has_prefix(r, "dir:") {
		parts := strings.split_n(r, ":", 4, context.temp_allocator)
		if len(parts) != 4 || parts[1] == "" || parts[2] == "" || parts[3] == "" {
			return "", false, domain.domain_error(.Validation_Failed, "dir ref is dir:<directory_id>:<rev>:<path>")
		}
		return fetch_file_at_commit(svc, task, parts[1], parts[2], parts[3], r)
	}
	// Path ref: `<path>@<rev>` or `<path>` (resolved at the task's latest vcs.head)
	file_path := r
	rev := ""
	if at := strings.last_index_byte(r, '@'); at > 0 {
		file_path = strings.trim_space(r[:at])
		rev = strings.trim_space(r[at+1:])
	}
	if rev == "" {
		rev = latest_task_vcs_head(svc, task)
	}
	dirs, derr := iface.taskchain_list_directories_by_chain(svc.repo, task.chain_id, task.owner_user_id)
	if derr.code != .None || len(dirs) == 0 || rev == "" {
		return "", false, domain.domain_error(.Validation_Failed, "ref must be #<event_id>, output:<task_id>, facet:<task>:<attempt>:<kind>, or <path>[@<rev>] on a chain with a VCS directory and commit")
	}
	dir_id := dirs[0].directory_id
	if task.bridge_id != "" {
		if resolved := resolve_directory_for_bridge(dirs, task.bridge_id); resolved != "" do dir_id = resolved
	}
	return fetch_file_at_commit(svc, task, dir_id, rev, file_path, r)
}

@(private = "file")
latest_task_vcs_head :: proc(svc: ^Service, task: domain.Task) -> string {
	facets, err := iface.taskchain_list_facets_by_task(svc.repo, task.task_id, task.owner_user_id)
	if err.code != .None do return ""
	best_attempt := -1
	head := ""
	for f in facets {
		if f.kind != FACET_VCS || f.attempt_no < best_attempt do continue
		h := strings.trim_space(jsonx.extract_string(f.body_json, "head", "", true, context.temp_allocator))
		if h != "" {
			best_attempt = f.attempt_no
			head = h
		}
	}
	return head
}

@(private = "file")
fetch_file_at_commit :: proc(svc: ^Service, task: domain.Task, directory_id, rev, file_path, ref: string) -> (string, bool, domain.Domain_Error) {
	if svc.vcs_show_file == nil {
		return "", false, domain.domain_error(.Bridge_Offline, "VCS file fetch is not configured")
	}
	raw, ok, err := svc.vcs_show_file(svc.vcs_show_file_ctx, task.chain_id, task.owner_user_id, directory_id, rev, file_path)
	if !ok do return "", false, err
	// If the bridge callback already returned a JSON object with `content`, enrich/return it; otherwise wrap raw content.
	trimmed := strings.trim_space(raw)
	if strings.has_prefix(trimmed, "{") && strings.has_suffix(trimmed, "}") {
		if content, cok := jsonx.extract_string_found(trimmed, "content", true, context.temp_allocator); cok {
			o := json_begin()
			json_str(&o, "ref", ref)
			json_str(&o, "kind", "file")
			json_str(&o, "directory_id", directory_id)
			json_str(&o, "rev", rev)
			json_str(&o, "path", file_path)
			json_str(&o, "content", content)
			return json_end(&o), true, domain.Domain_Error{}
		}
	}
	o := json_begin()
	json_str(&o, "ref", ref)
	json_str(&o, "kind", "file")
	json_str(&o, "directory_id", directory_id)
	json_str(&o, "rev", rev)
	json_str(&o, "path", file_path)
	json_str(&o, "content", raw)
	return json_end(&o), true, domain.Domain_Error{}
}
