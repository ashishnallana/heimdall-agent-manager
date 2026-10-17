package main

// Task System v2 (M2): bridge-side VCS enrichment for the lease verbs and for
// `ham-ctl verify` exits (docs: m2 wire contract §"Bridge .Local enrichment" and
// §verify step 6).
//
//   agent.lease.next      -> params.vcs_base = <git HEAD of the agent's repo>
//   agent.lease.submit    -> params.vcs = {head, dirty, files:[{path,status,add,del}]}
//   agent.lease.handoff   -> same as submit
//   shell_exited frame    -> when the session label starts with "verify ":
//                            "vcs":{"head","dirty"} + "tail":"<last ≤40 log lines>"
//
// All git calls go through the bridge's own `vcs_run` (argv, no shell, bounded
// by VCS_LOCAL_TIMEOUT) and FAIL SOFT: a directory that is not a git repository
// simply produces no enrichment and the params relay unchanged.
//
// Repository resolution (bridge_taskv2_repo_for_agent): the agent's working
// directory is not something the bridge observes directly, so it is derived in
// order of fidelity:
//   1. params.cwd — ham-ctl sends its own cwd, which IS the agent's cwd (ham-ctl
//      runs as the agent's child). Used only when it is a git repository.
//   2. the launch record's project_path (the chain/project directory the agent
//      was told about in AGENTS.md).
//   3. the launch record's run_dir (the managed run directory; normally not a
//      repo, included so a repo-initialised run dir still works).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import jsonx "odin_test:lib/jsonx"

// Per-instance cached vcs_base captured on `agent.lease.next` so a subsequent
// `agent.lease.submit` / `handoff` in a clean committed tree still reports
// `git diff --numstat <vcs_base>..HEAD` in `vcs.files`.
bridge_taskv2_vcs_base_mutex: sync.Mutex
bridge_taskv2_vcs_base_by_instance: map[string]string

bridge_taskv2_cache_vcs_base :: proc(instance_id, base: string) {
	id := strings.trim_space(instance_id)
	if id == "" || strings.trim_space(base) == "" do return
	sync.mutex_lock(&bridge_taskv2_vcs_base_mutex)
	defer sync.mutex_unlock(&bridge_taskv2_vcs_base_mutex)
	if old, has := bridge_taskv2_vcs_base_by_instance[id]; has {
		delete(old)
		bridge_taskv2_vcs_base_by_instance[id] = strings.clone(base)
	} else {
		bridge_taskv2_vcs_base_by_instance[strings.clone(id)] = strings.clone(base)
	}
}

bridge_taskv2_lookup_vcs_base :: proc(instance_id: string, allocator := context.temp_allocator) -> string {
	id := strings.trim_space(instance_id)
	if id == "" do return ""
	sync.mutex_lock(&bridge_taskv2_vcs_base_mutex)
	defer sync.mutex_unlock(&bridge_taskv2_vcs_base_mutex)
	if v, has := bridge_taskv2_vcs_base_by_instance[id]; has do return strings.clone(v, allocator)
	return ""
}

// bridge_taskv2_git_head returns HEAD's sha for `dir`, or ("", false) when the
// directory is not a usable git repository (no repo, unborn branch, git missing).
// The returned sha is an owned clone.
bridge_taskv2_git_head :: proc(dir: string) -> (string, bool) {
	if strings.trim_space(dir) == "" do return "", false
	out, ok := vcs_run([]string{"git", "-C", dir, "rev-parse", "--verify", "HEAD"})
	defer if len(out) > 0 do delete(out)
	if !ok do return "", false
	sha := strings.trim_space(out)
	if sha == "" do return "", false
	return strings.clone(sha), true
}

// bridge_taskv2_git_dirty reports whether the working tree has any change
// (`git status --porcelain` non-empty). ok=false when the directory is not a repo.
bridge_taskv2_git_dirty :: proc(dir: string) -> (dirty: bool, ok: bool) {
	if strings.trim_space(dir) == "" do return false, false
	out, run_ok := vcs_run([]string{"git", "-C", dir, "status", "--porcelain"})
	defer if len(out) > 0 do delete(out)
	if !run_ok do return false, false
	return strings.trim_space(out) != "", true
}

// bridge_taskv2_git_files_json renders the vcs facet's `files` array for `dir`:
// every working-tree change (status words from vcs_git_changed_files, with
// +/- counts) and, when `base` names a commit, every file committed between
// base and HEAD (status "committed"). Returns "[]" when nothing changed or the
// directory is not a repo. The returned string is an owned clone.
bridge_taskv2_git_files_json :: proc(dir, base: string) -> string {
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	first := true

	files, _, _, ok := vcs_git_changed_files(dir, "", VCS_FILES_MAX_LIMIT)
	defer if ok {
		for f in files do if len(f.path) > 0 do delete(f.path)
		if len(files) > 0 do delete(files)
	}
	if ok {
		for f in files {
			if !first do strings.write_byte(&b, ',')
			first = false
			bridge_taskv2_write_file_change(&b, f.path, f.status, f.additions, f.deletions)
		}
	}

	if base_sha := strings.trim_space(base); base_sha != "" && !strings.has_prefix(base_sha, "-") {
		revspec := strings.concatenate({base_sha, "..HEAD"})
		defer delete(revspec)
		out, run_ok := vcs_run([]string{"git", "-C", dir, "diff", "--numstat", revspec, "--"})
		defer if len(out) > 0 do delete(out)
		if run_ok {
			for line in strings.split_lines_iterator(&out) {
				parts := strings.fields(line, context.temp_allocator)
				if len(parts) < 3 do continue
				if !first do strings.write_byte(&b, ',')
				first = false
				bridge_taskv2_write_file_change(&b, strings.join(parts[2:], " ", context.temp_allocator), "committed", vcs_atoi(parts[0]), vcs_atoi(parts[1]))
			}
		}
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

bridge_taskv2_write_file_change :: proc(b: ^strings.Builder, path, status: string, add, del: int) {
	strings.write_string(b, "{\"path\":\"")
	bridge_local_write_json_string(b, path)
	strings.write_string(b, "\",\"status\":\"")
	bridge_local_write_json_string(b, status)
	strings.write_string(b, "\",\"add\":")
	bridge_agent_write_int(b, add)
	strings.write_string(b, ",\"del\":")
	bridge_agent_write_int(b, del)
	strings.write_byte(b, '}')
}

// bridge_taskv2_vcs_object_json builds the `vcs` params object for submit /
// handoff from already-computed pieces. Pure; `files_json` is spliced raw.
bridge_taskv2_vcs_object_json :: proc(head: string, dirty: bool, files_json: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"kind\":\"git\",\"head\":\"")
	bridge_local_write_json_string(&b, head)
	strings.write_string(&b, "\",\"dirty\":")
	strings.write_string(&b, "true" if dirty else "false")
	strings.write_string(&b, ",\"files\":")
	strings.write_string(&b, files_json if strings.trim_space(files_json) != "" else "[]")
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// bridge_taskv2_params_inject prepends `"key":<raw_json>` to a params object.
// Pure. A missing / empty / non-object params becomes `{"key":<raw>}`. When the
// object already carries `key` at its top level the caller's value wins and the
// params are returned unchanged (an agent that passes --vcs-base explicitly is
// not second-guessed).
bridge_taskv2_params_inject :: proc(params, key, raw_json: string) -> string {
	body := strings.trim_space(params)
	if _, has_str := jsonx.extract_string_found(body, key, true, context.temp_allocator); has_str do return strings.clone(params)
	if _, has_obj := jsonx.extract_raw_object(body, key, true, context.temp_allocator); has_obj do return strings.clone(params)
	if body == "" || body == "{}" || body[0] != '{' {
		return strings.concatenate({"{\"", key, "\":", raw_json, "}"})
	}
	return strings.concatenate({"{\"", key, "\":", raw_json, ",", body[1:]})
}

// bridge_taskv2_repo_for_agent resolves the git repository the lease verbs
// describe (see the file header for the order). Returns ("", false) when none of
// the candidates is a git repository. The path is an owned clone.
bridge_taskv2_repo_for_agent :: proc(params: string, rec: Bridge_Local_Agent_Token_Record) -> (string, bool) {
	if cwd := strings.trim_space(bridge_local_extract_json_string(params, "cwd", "", context.temp_allocator)); cwd != "" {
		if _, ok := bridge_taskv2_git_dirty(cwd); ok do return strings.clone(cwd), true
	}
	if launch, has := bridge_runtime_get_launch(rec.agent_instance_id); has {
		if p := strings.trim_space(launch.project_path); p != "" {
			if _, ok := bridge_taskv2_git_dirty(p); ok do return strings.clone(p), true
		}
		if p := strings.trim_space(launch.run_dir); p != "" {
			if _, ok := bridge_taskv2_git_dirty(p); ok do return strings.clone(p), true
		}
	}
	return "", false
}

// bridge_taskv2_enrich_lease_params returns the params the bridge relays for a
// lease verb: next gets `vcs_base`, submit/handoff get `vcs`. Anything else, or
// no repository, relays `params` unchanged (always an owned clone).
bridge_taskv2_enrich_lease_params :: proc(method, params: string, rec: Bridge_Local_Agent_Token_Record) -> string {
	repo, has_repo := bridge_taskv2_repo_for_agent(params, rec)
	if !has_repo do return strings.clone(params)
	defer delete(repo)
	head, head_ok := bridge_taskv2_git_head(repo)
	if !head_ok do return strings.clone(params)
	defer delete(head)

	switch method {
	case "agent.lease.next":
		peek, _ := jsonx.extract_bool_literal(params, "peek", true)
		if !peek do bridge_taskv2_cache_vcs_base(rec.agent_instance_id, head)
		quoted := bridge_local_json_escaped(head)
		defer delete(quoted)
		raw := strings.concatenate({"\"", quoted, "\""})
		defer delete(raw)
		return bridge_taskv2_params_inject(params, "vcs_base", raw)
	case "agent.lease.submit", "agent.lease.handoff":
		dirty, _ := bridge_taskv2_git_dirty(repo)
		base := bridge_local_extract_json_string(params, "vcs_base", "", context.temp_allocator)
		if strings.trim_space(base) == "" do base = bridge_taskv2_lookup_vcs_base(rec.agent_instance_id, context.temp_allocator)
		files := bridge_taskv2_git_files_json(repo, base)
		defer delete(files)
		obj := bridge_taskv2_vcs_object_json(head, dirty, files)
		defer delete(obj)
		return bridge_taskv2_params_inject(params, "vcs", obj)
	}
	return strings.clone(params)
}

// bridge_agent_lease_local_rpc fulfils the .Local lease routes: enrich, then
// relay to the SAME hub agent-actions path a plain .Envelope route would use,
// with identical error mapping (mirrors the .Envelope branch of the dispatcher).
// On a non-peek `agent.lease.next` that returns a `pack`, materializes `<run_dir>/TASK.md`.
bridge_agent_lease_local_rpc :: proc(request_id, method, hub_path, params: string, rec: Bridge_Local_Agent_Token_Record) -> string {
	if strings.trim_space(rec.instance_token) == "" do return bridge_local_response_error(request_id, "unavailable", "Bridge-held instance token is unavailable")
	eff := bridge_taskv2_enrich_lease_params(method, params, rec)
	defer delete(eff)
	relay := bridge_local_relay_agent_envelope(hub_path, method, eff, rec)
	if !relay.ok do return bridge_local_response_error(request_id, "retryable_unavailable", "Hub relay failed")
	if relay.status < 200 || relay.status >= 300 do return bridge_local_response_error(request_id, "hub_error", relay.body)
	if strings.trim_space(relay.body) == "" do return bridge_local_response_data(request_id, "{}")
	if method == "agent.lease.next" {
		peek, _ := jsonx.extract_bool_literal(params, "peek", true)
		if !peek {
			data_obj, has_data := jsonx.extract_raw_object(relay.body, "data", true, context.temp_allocator)
			target := data_obj if has_data else relay.body
			if pack_obj, has_pack := jsonx.extract_raw_object(target, "pack", true, context.temp_allocator); has_pack && strings.has_prefix(strings.trim_space(pack_obj), "{") {
				run_dir := ""
				if launch, has_launch := bridge_runtime_get_launch(rec.agent_instance_id); has_launch && strings.trim_space(launch.run_dir) != "" {
					run_dir = strings.clone(launch.run_dir, context.temp_allocator)
				} else if strings.trim_space(rec.agent_instance_id) != "" {
					run_dir = bridge_runtime_default_run_dir(rec.agent_instance_id)
					defer delete(run_dir)
				}
				if strings.trim_space(run_dir) != "" {
					_ = bridge_taskv2_materialize_task_md(run_dir, pack_obj)
				}
			}
		}
	}
	return bridge_local_response_data(request_id, relay.body)
}

// ---- shell_exited enrichment for `ham-ctl verify` runs ---------------------

BRIDGE_TASKV2_VERIFY_LABEL_PREFIX :: "verify "
BRIDGE_TASKV2_VERIFY_TAIL_LINES :: 40

// bridge_taskv2_verify_exit_enrich_json splices `vcs` and `tail` into a
// shell_exited frame. Pure. dirty_known=false renders `"dirty":null` (contract:
// absent values are unknown). head may be "" (not a repo) and is still written so
// the hub can tell "no repo" from "frame predates enrichment".
bridge_taskv2_verify_exit_enrich_json :: proc(event_json, head: string, dirty_known, dirty: bool, tail: string) -> string {
	body := strings.trim_space(event_json)
	if body == "" || body[len(body) - 1] != '}' do return strings.clone(event_json)
	b := strings.builder_make()
	strings.write_string(&b, body[:len(body) - 1])
	if len(body) > 2 do strings.write_byte(&b, ',')
	strings.write_string(&b, "\"vcs\":{\"head\":\"")
	bridge_local_write_json_string(&b, head)
	strings.write_string(&b, "\",\"dirty\":")
	if dirty_known {
		strings.write_string(&b, "true" if dirty else "false")
	} else {
		strings.write_string(&b, "null")
	}
	strings.write_string(&b, "},\"tail\":\"")
	bridge_local_write_json_string(&b, tail)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// bridge_taskv2_tail_lines returns the last `keep` lines of output (slice into
// `output`, no copy). Unlike bridge_shell_tail it has no threshold: a verify log
// is always cut to the keep count because the hub stores it in a facet.
bridge_taskv2_tail_lines :: proc(output: string, keep: int) -> string {
	tail, _ := bridge_shell_tail(output, keep, keep)
	return tail
}

// bridge_taskv2_maybe_enrich_verify_exit returns the frame to enqueue for a
// shell_exited event: enriched when the session is a `ham-ctl verify` run,
// otherwise an unchanged clone. Looks the session up by the frame's session_id so
// every producer of an exit (pty-host ChildExited, reconcile, orphan sweep) is
// covered from the single enqueue chokepoint.
bridge_taskv2_maybe_enrich_verify_exit :: proc(event_json: string) -> string {
	session_id := extract_json_string(event_json, "session_id", "", context.temp_allocator)
	if strings.trim_space(session_id) == "" do return strings.clone(event_json)
	sess, found := bridge_shell_session_snapshot(&bridge_shell_session_map, session_id)
	if !found do return strings.clone(event_json)
	defer bridge_shell_session_snapshot_destroy(&bridge_shell_session_map, sess)
	if sess.kind != .Run || !strings.has_prefix(sess.label, BRIDGE_TASKV2_VERIFY_LABEL_PREFIX) do return strings.clone(event_json)

	head := ""
	if h, ok := bridge_taskv2_git_head(sess.cwd); ok do head = h
	defer if head != "" do delete(head)
	dirty, dirty_known := bridge_taskv2_git_dirty(sess.cwd)

	tail := ""
	output, state := bridge_shell_output_read(session_id)
	defer if state == .Available do delete(output)
	sanitized := ""
	if state == .Available {
		sanitized = bridge_shell_sanitize_output(output)
		tail = bridge_taskv2_tail_lines(sanitized, BRIDGE_TASKV2_VERIFY_TAIL_LINES)
	}
	defer if sanitized != "" do delete(sanitized)

	return bridge_taskv2_verify_exit_enrich_json(event_json, head, dirty_known, dirty, tail)
}

// ---- M3: TASK.md Materialiser + Vault Decryption + 8k-Token Field-Safe Cap -

BRIDGE_TASK_MD_MAX_BYTES :: 32_000 // ~8k tokens (@ 4 bytes/token)

Bridge_Task_Md_Input :: struct {
	ref:      string,
	resolved: bool,
	body:     string,
	dropped:  bool,
}

bridge_taskv2_decrypt_field :: proc(s: string, allocator := context.temp_allocator) -> string {
	if !bridge_has_vault_token(s) do return strings.clone(s, allocator)
	return bridge_decrypt_embedded_vault_tokens(s, allocator = allocator, locked_marker = VAULT_LOCKED_MARKER)
}

// bridge_taskv2_render_task_md decrypts all vault:v1: / ENC:v1: tokens in pack_json,
// applies the field-safe 8k-token (max_bytes) cap AFTER decryption (never inside a
// field, dropping in order: 1. resolved input bodies -> 2. previous verify summary/tail
// -> 3. previous handoff summary; preserving brief, dead_ends, and open findings intact),
// and renders the Markdown document for <run_dir>/TASK.md.
bridge_taskv2_render_task_md :: proc(pack_json: string, max_bytes: int = BRIDGE_TASK_MD_MAX_BYTES, allocator := context.allocator) -> string {
	if !strings.has_prefix(strings.trim_space(pack_json), "{") {
		return strings.clone("", allocator)
	}
	lease_obj, _ := jsonx.extract_raw_object(pack_json, "lease", true, context.temp_allocator)
	task_obj, _ := jsonx.extract_raw_object(pack_json, "task", true, context.temp_allocator)
	brief_obj, has_brief := jsonx.extract_raw_object(pack_json, "brief", true, context.temp_allocator)
	if !has_brief && task_obj != "" {
		brief_obj, _ = jsonx.extract_raw_object(task_obj, "brief", true, context.temp_allocator)
	}
	chain_obj, _ := jsonx.extract_raw_object(pack_json, "chain", true, context.temp_allocator)
	placement_obj, has_place := jsonx.extract_raw_object(pack_json, "placement", true, context.temp_allocator)
	if !has_place && lease_obj != "" {
		placement_obj, _ = jsonx.extract_raw_object(lease_obj, "placement", true, context.temp_allocator)
	}
	where_obj, _ := jsonx.extract_raw_object(pack_json, "where_you_are", true, context.temp_allocator)
	prev_obj, _ := jsonx.extract_raw_object(pack_json, "previous_attempt", true, context.temp_allocator)
	proto_obj, _ := jsonx.extract_raw_object(pack_json, "protocol", true, context.temp_allocator)

	lease_id := jsonx.extract_string(pack_json, "lease_id", jsonx.extract_string(lease_obj, "lease_id", "", true, context.temp_allocator), true, context.temp_allocator)
	task_id := jsonx.extract_string(pack_json, "task_id", jsonx.extract_string(task_obj, "task_id", "", true, context.temp_allocator), true, context.temp_allocator)
	lease_kind := jsonx.extract_string(lease_obj, "kind", "work", true, context.temp_allocator)
	review_role := jsonx.extract_string(lease_obj, "review_role", "", true, context.temp_allocator)
	role_label := review_role if (lease_kind == "review" && review_role != "") else ("reviewer" if lease_kind == "review" else "worker")
	attempt_no := jsonx.extract_int(pack_json, "attempt_no", jsonx.extract_int(lease_obj, "attempt_no", 1, true), true)
	max_attempts := jsonx.extract_int(pack_json, "max_attempts", jsonx.extract_int(lease_obj, "max_attempts", 3, true), true)
	review_rounds := jsonx.extract_int(pack_json, "review_rounds", jsonx.extract_int(lease_obj, "review_rounds", 0, true), true)
	expires_at := jsonx.extract_string(pack_json, "expires_at", jsonx.extract_string(lease_obj, "expires_at", "", true, context.temp_allocator), true, context.temp_allocator)
	hard_deadline_at := jsonx.extract_string(pack_json, "hard_deadline_at", jsonx.extract_string(lease_obj, "hard_deadline_at", "", true, context.temp_allocator), true, context.temp_allocator)
	why := jsonx.extract_string(pack_json, "why", "first_grant", true, context.temp_allocator)

	bridge_id := jsonx.extract_string(placement_obj, "bridge_id", "", true, context.temp_allocator)
	directory_id := jsonx.extract_string(placement_obj, "directory_id", "", true, context.temp_allocator)
	provider := jsonx.extract_string(placement_obj, "provider", "", true, context.temp_allocator)
	model := jsonx.extract_string(placement_obj, "model", "", true, context.temp_allocator)

	raw_title := jsonx.extract_string(task_obj, "title", "", true, context.temp_allocator)
	raw_desc := jsonx.extract_string(task_obj, "description", "", true, context.temp_allocator)
	title := bridge_taskv2_decrypt_field(raw_title, context.temp_allocator)
	description := bridge_taskv2_decrypt_field(raw_desc, context.temp_allocator)

	goal := bridge_taskv2_decrypt_field(jsonx.extract_string(brief_obj, "goal", "", true, context.temp_allocator), context.temp_allocator)
	if strings.trim_space(goal) == "" do goal = description
	verify_cmd := bridge_taskv2_decrypt_field(jsonx.extract_string(brief_obj, "verify", "", true, context.temp_allocator), context.temp_allocator)
	acc_raw := jsonx.extract_string_array(brief_obj, "acceptance", true, context.temp_allocator)
	acceptance := make([dynamic]string, context.temp_allocator)
	for a in acc_raw {
		append(&acceptance, bridge_taskv2_decrypt_field(a, context.temp_allocator))
	}

	raw_chain_summary := jsonx.extract_string(chain_obj, "summary", jsonx.extract_string(pack_json, "chain_summary", "", true, context.temp_allocator), true, context.temp_allocator)
	chain_summary := bridge_taskv2_decrypt_field(raw_chain_summary, context.temp_allocator)

	// Resolved inputs
	inputs := make([dynamic]Bridge_Task_Md_Input, context.temp_allocator)
	if inputs_arr, has_inputs := bridge_provider_json_extract_array(pack_json, "inputs"); has_inputs {
		objs := bridge_provider_json_top_level_objects(inputs_arr)
		defer bridge_bootstrap_free_object_slice(objs)
		for obj in objs {
			ref := jsonx.extract_string(obj, "ref", "", true, context.temp_allocator)
			resolved, _ := jsonx.extract_bool_literal(obj, "resolved", true)
			data_raw := ""
			if d_obj, has_d := jsonx.extract_raw_object(obj, "data", true, context.temp_allocator); has_d {
				data_raw = d_obj
			} else {
				data_raw = jsonx.extract_string(obj, "data", "", true, context.temp_allocator)
			}
			append(&inputs, Bridge_Task_Md_Input{
				ref      = ref,
				resolved = resolved,
				body     = bridge_taskv2_decrypt_field(data_raw, context.temp_allocator),
			})
		}
	}

	// Where You Are (vcs)
	vcs_head := jsonx.extract_string(where_obj, "head", "", true, context.temp_allocator)
	vcs_dirty, vcs_has_dirty := jsonx.extract_bool_literal(where_obj, "dirty", true)
	vcs_files_arr, _ := bridge_provider_json_extract_array(where_obj, "files")
	defer if vcs_files_arr != "" do delete(vcs_files_arr)

	// Previous Attempt
	has_prev := strings.has_prefix(strings.trim_space(prev_obj), "{")
	prev_attempt_no := jsonx.extract_int(prev_obj, "attempt_no", attempt_no - 1, true)
	prev_outcome := jsonx.extract_string(prev_obj, "outcome", "", true, context.temp_allocator)
	prev_note := bridge_taskv2_decrypt_field(jsonx.extract_string(prev_obj, "last_heartbeat_note", jsonx.extract_string(prev_obj, "note", "", true, context.temp_allocator), true, context.temp_allocator), context.temp_allocator)

	handoff_obj, _ := jsonx.extract_raw_object(prev_obj, "handoff", true, context.temp_allocator)
	handoff_summary := bridge_taskv2_decrypt_field(jsonx.extract_string(handoff_obj, "summary", "", true, context.temp_allocator), context.temp_allocator)
	handoff_decisions := jsonx.extract_string_array(handoff_obj, "decisions", true, context.temp_allocator)
	handoff_dead_ends := jsonx.extract_string_array(handoff_obj, "dead_ends", true, context.temp_allocator)
	handoff_next_steps := jsonx.extract_string_array(handoff_obj, "next_steps", true, context.temp_allocator)
	if len(handoff_next_steps) == 0 {
		if ns := jsonx.extract_string(handoff_obj, "next_steps", "", true, context.temp_allocator); strings.trim_space(ns) != "" {
			append(&handoff_next_steps, ns)
		}
	}
	if len(handoff_dead_ends) == 0 {
		if de := jsonx.extract_string(handoff_obj, "dead_ends", "", true, context.temp_allocator); strings.trim_space(de) != "" {
			append(&handoff_dead_ends, de)
		}
	}

	verify_obj, _ := jsonx.extract_raw_object(prev_obj, "verify", true, context.temp_allocator)
	verify_cmd_prev := bridge_taskv2_decrypt_field(jsonx.extract_string(verify_obj, "cmd", "", true, context.temp_allocator), context.temp_allocator)
	verify_exit, has_verify_exit := jsonx.extract_int_found(verify_obj, "exit_code", true)
	verify_head := jsonx.extract_string(verify_obj, "head", "", true, context.temp_allocator)
	verify_tail := bridge_taskv2_decrypt_field(jsonx.extract_string(verify_obj, "tail", jsonx.extract_string(verify_obj, "summary", "", true, context.temp_allocator), true, context.temp_allocator), context.temp_allocator)

	// Open Findings (never dropped)
	findings_lines := make([dynamic]string, context.temp_allocator)
	if findings_arr, has_f := bridge_provider_json_extract_array(pack_json, "findings"); has_f {
		f_objs := bridge_provider_json_top_level_objects(findings_arr)
		defer bridge_bootstrap_free_object_slice(f_objs)
		for f_obj in f_objs {
			f_path := bridge_taskv2_decrypt_field(jsonx.extract_string(f_obj, "path", "", true, context.temp_allocator), context.temp_allocator)
			f_line := jsonx.extract_int(f_obj, "line", 0, true)
			f_sev := jsonx.extract_string(f_obj, "severity", "major", true, context.temp_allocator)
			f_txt := bridge_taskv2_decrypt_field(jsonx.extract_string(f_obj, "text", jsonx.extract_string(f_obj, "message", "", true, context.temp_allocator), true, context.temp_allocator), context.temp_allocator)
			if f_path != "" && f_line > 0 {
				append(&findings_lines, fmt.tprintf("- [%s] `%s:%d` — %s", f_sev, f_path, f_line, f_txt))
			} else if f_path != "" {
				append(&findings_lines, fmt.tprintf("- [%s] `%s` — %s", f_sev, f_path, f_txt))
			} else if f_txt != "" {
				append(&findings_lines, fmt.tprintf("- [%s] %s", f_sev, f_txt))
			}
		}
	}

	// Protocol Rules
	rules := jsonx.extract_string_array(proto_obj, "rules", true, context.temp_allocator)

	drop_verify_summary := false
	drop_handoff_summary := false

	build_doc :: proc(
		task_id, title, role_label, lease_id, expires_at, hard_deadline_at, bridge_id, directory_id, provider, model, why: string,
		attempt_no, max_attempts, review_rounds: int,
		goal, verify_cmd: string, acceptance: []string,
		chain_summary: string,
		inputs: []Bridge_Task_Md_Input,
		vcs_head: string, vcs_has_dirty, vcs_dirty: bool, vcs_files_arr: string,
		has_prev: bool, prev_attempt_no: int, prev_outcome, prev_note: string,
		handoff_summary: string, drop_handoff_summary: bool,
		handoff_decisions, handoff_dead_ends, handoff_next_steps: []string,
		verify_cmd_prev: string, has_verify_exit: bool, verify_exit: int, verify_head, verify_tail: string, drop_verify_summary: bool,
		findings_lines: []string,
		rules: []string,
		alloc := context.temp_allocator,
	) -> string {
		b := strings.builder_make(alloc)
		fmt.sbprintf(&b, "# Task %s: %s (%s, attempt #%d)\n\n", task_id, title, role_label, attempt_no)
		fmt.sbprintf(&b, "- **Lease**: `%s` (attempt %d/%d, review_rounds: %d)\n", lease_id, attempt_no, max_attempts, review_rounds)
		if expires_at != "" || hard_deadline_at != "" {
			fmt.sbprintf(&b, "- **Deadlines**: expires `%s`, hard_deadline `%s`\n", expires_at, hard_deadline_at)
		}
		if bridge_id != "" || directory_id != "" || provider != "" || model != "" {
			fmt.sbprintf(&b, "- **Placement**: bridge=`%s` directory=`%s` provider=`%s` model=`%s`\n", bridge_id, directory_id, provider, model)
		}
		strings.write_string(&b, "\n## Brief\n")
		if goal != "" {
			fmt.sbprintf(&b, "**Goal**: %s\n", goal)
		}
		if len(acceptance) > 0 {
			strings.write_string(&b, "**Acceptance**:\n")
			for a in acceptance {
				fmt.sbprintf(&b, "- %s\n", a)
			}
		}
		if verify_cmd != "" {
			fmt.sbprintf(&b, "**Verify**: `%s`\n", verify_cmd)
		}

		strings.write_string(&b, "\n## Chain Summary\n")
		if strings.trim_space(chain_summary) != "" {
			strings.write_string(&b, chain_summary)
			if !strings.has_suffix(chain_summary, "\n") do strings.write_byte(&b, '\n')
		} else {
			strings.write_string(&b, "_(none)_\n")
		}

		if len(inputs) > 0 {
			strings.write_string(&b, "\n## Resolved Inputs\n")
			for inp in inputs {
				if inp.dropped {
					fmt.sbprintf(&b, "- `%s`: omitted for size — fetch with `ham-ctl task fetch %s %s`\n", inp.ref, task_id, inp.ref)
				} else if inp.resolved {
					fmt.sbprintf(&b, "- `%s`: %s\n", inp.ref, inp.body)
				} else {
					fmt.sbprintf(&b, "- `%s`: _(unresolved — `ham-ctl task fetch %s %s`)_\n", inp.ref, task_id, inp.ref)
				}
			}
		}

		strings.write_string(&b, "\n## Where You Are\n")
		if vcs_head != "" {
			fmt.sbprintf(&b, "- **HEAD**: `%s` (dirty: `%v`)\n", vcs_head, vcs_dirty if vcs_has_dirty else false)
			if strings.has_prefix(strings.trim_space(vcs_files_arr), "[") && strings.trim_space(vcs_files_arr) != "[]" {
				fmt.sbprintf(&b, "- **Changed files**: `%s`\n", strings.trim_space(vcs_files_arr))
			}
		} else {
			strings.write_string(&b, "- No prior VCS state recorded.\n")
		}

		if has_prev {
			fmt.sbprintf(&b, "\n## Previous Attempt (#%d)\n", prev_attempt_no)
			if prev_outcome != "" {
				fmt.sbprintf(&b, "- **Outcome**: `%s`\n", prev_outcome)
			}
			if prev_note != "" {
				fmt.sbprintf(&b, "- **Last Heartbeat Note**: %s\n", prev_note)
			}
			if drop_handoff_summary {
				fmt.sbprintf(&b, "- **Handoff Summary**: omitted for size — fetch with `ham-ctl task fetch %s facet:%s:%d:handoff`\n", task_id, task_id, prev_attempt_no)
			} else if handoff_summary != "" {
				fmt.sbprintf(&b, "- **Handoff Summary**: %s\n", handoff_summary)
			}
			if len(handoff_decisions) > 0 {
				strings.write_string(&b, "- **Decisions**:\n")
				for d in handoff_decisions {
					fmt.sbprintf(&b, "  - %s\n", bridge_taskv2_decrypt_field(d, context.temp_allocator))
				}
			}
			if len(handoff_dead_ends) > 0 {
				strings.write_string(&b, "- **Dead Ends (DO NOT REPEAT)**:\n")
				for de in handoff_dead_ends {
					fmt.sbprintf(&b, "  - %s\n", bridge_taskv2_decrypt_field(de, context.temp_allocator))
				}
			}
			if len(handoff_next_steps) > 0 {
				strings.write_string(&b, "- **Next Steps**:\n")
				for ns in handoff_next_steps {
					fmt.sbprintf(&b, "  - %s\n", bridge_taskv2_decrypt_field(ns, context.temp_allocator))
				}
			}
			if has_verify_exit || verify_cmd_prev != "" || verify_tail != "" || drop_verify_summary {
				fmt.sbprintf(&b, "- **Previous Verify**: cmd=`%s` exit_code=`%d` head=`%s`\n", verify_cmd_prev, verify_exit, verify_head)
				if drop_verify_summary {
					fmt.sbprintf(&b, "  - Output omitted for size — fetch with `ham-ctl task fetch %s facet:%s:%d:verify`\n", task_id, task_id, prev_attempt_no)
				} else if verify_tail != "" {
					fmt.sbprintf(&b, "  - Output tail:\n```\n%s\n```\n", verify_tail)
				}
			}
		}

		if len(findings_lines) > 0 {
			strings.write_string(&b, "\n## Open Findings\n")
			for fl in findings_lines {
				strings.write_string(&b, fl)
				strings.write_byte(&b, '\n')
			}
		}

		fmt.sbprintf(&b, "\n## Why You Were Chosen\n`%s`\n", why)

		strings.write_string(&b, "\n## Protocol Rules\n")
		if len(rules) > 0 {
			for r in rules {
				strings.write_string(&b, r)
				strings.write_byte(&b, '\n')
			}
		} else {
			strings.write_string(&b, "1. Confirm lease with `ham-ctl lease next`.\n2. Run `ham-ctl verify` and `ham-ctl lease submit --summary \"...\"` when done.\n")
		}
		return strings.to_string(b)
	}

	rendered := build_doc(
		task_id, title, role_label, lease_id, expires_at, hard_deadline_at, bridge_id, directory_id, provider, model, why,
		attempt_no, max_attempts, review_rounds,
		goal, verify_cmd, acceptance[:],
		chain_summary,
		inputs[:],
		vcs_head, vcs_has_dirty, vcs_dirty, vcs_files_arr,
		has_prev, prev_attempt_no, prev_outcome, prev_note,
		handoff_summary, drop_handoff_summary,
		handoff_decisions[:], handoff_dead_ends[:], handoff_next_steps[:],
		verify_cmd_prev, has_verify_exit, verify_exit, verify_head, verify_tail, drop_verify_summary,
		findings_lines[:],
		rules[:],
		context.temp_allocator,
	)

	// Step 1 of field-safe cap: drop resolved input bodies (from last to first)
	if max_bytes > 0 && len(rendered) > max_bytes {
		for i := len(inputs) - 1; i >= 0 && len(rendered) > max_bytes; i -= 1 {
			if inputs[i].dropped do continue
			inputs[i].dropped = true
			rendered = build_doc(
				task_id, title, role_label, lease_id, expires_at, hard_deadline_at, bridge_id, directory_id, provider, model, why,
				attempt_no, max_attempts, review_rounds,
				goal, verify_cmd, acceptance[:],
				chain_summary,
				inputs[:],
				vcs_head, vcs_has_dirty, vcs_dirty, vcs_files_arr,
				has_prev, prev_attempt_no, prev_outcome, prev_note,
				handoff_summary, drop_handoff_summary,
				handoff_decisions[:], handoff_dead_ends[:], handoff_next_steps[:],
				verify_cmd_prev, has_verify_exit, verify_exit, verify_head, verify_tail, drop_verify_summary,
				findings_lines[:],
				rules[:],
				context.temp_allocator,
			)
		}
	}

	// Step 2 of field-safe cap: drop previous verify summary/tail
	if max_bytes > 0 && len(rendered) > max_bytes && verify_tail != "" {
		drop_verify_summary = true
		rendered = build_doc(
			task_id, title, role_label, lease_id, expires_at, hard_deadline_at, bridge_id, directory_id, provider, model, why,
			attempt_no, max_attempts, review_rounds,
			goal, verify_cmd, acceptance[:],
			chain_summary,
			inputs[:],
			vcs_head, vcs_has_dirty, vcs_dirty, vcs_files_arr,
			has_prev, prev_attempt_no, prev_outcome, prev_note,
			handoff_summary, drop_handoff_summary,
			handoff_decisions[:], handoff_dead_ends[:], handoff_next_steps[:],
			verify_cmd_prev, has_verify_exit, verify_exit, verify_head, verify_tail, drop_verify_summary,
			findings_lines[:],
			rules[:],
			context.temp_allocator,
		)
	}

	// Step 3 of field-safe cap: drop previous handoff summary (preserving dead_ends!)
	if max_bytes > 0 && len(rendered) > max_bytes && handoff_summary != "" {
		drop_handoff_summary = true
		rendered = build_doc(
			task_id, title, role_label, lease_id, expires_at, hard_deadline_at, bridge_id, directory_id, provider, model, why,
			attempt_no, max_attempts, review_rounds,
			goal, verify_cmd, acceptance[:],
			chain_summary,
			inputs[:],
			vcs_head, vcs_has_dirty, vcs_dirty, vcs_files_arr,
			has_prev, prev_attempt_no, prev_outcome, prev_note,
			handoff_summary, drop_handoff_summary,
			handoff_decisions[:], handoff_dead_ends[:], handoff_next_steps[:],
			verify_cmd_prev, has_verify_exit, verify_exit, verify_head, verify_tail, drop_verify_summary,
			findings_lines[:],
			rules[:],
			context.temp_allocator,
		)
	}

	return strings.clone(rendered, allocator)
}

// bridge_taskv2_materialize_task_md renders and writes `<run_dir>/TASK.md`.
bridge_taskv2_materialize_task_md :: proc(run_dir, pack_json: string, max_bytes: int = BRIDGE_TASK_MD_MAX_BYTES) -> bool {
	clean := strings.trim_right(strings.trim_space(run_dir), "/")
	if clean == "" || !strings.has_prefix(strings.trim_space(pack_json), "{") do return false
	_ = bridge_make_directory_all(clean)
	md := bridge_taskv2_render_task_md(pack_json, max_bytes)
	defer delete(md)
	if strings.trim_space(md) == "" do return false
	path := strings.concatenate({clean, "/TASK.md"})
	defer delete(path)
	return os.write_entire_file(path, transmute([]byte)md) == nil
}

// bridge_taskv2_worktree_add_detached creates an ephemeral detached git worktree at `rev`
// (`git -C <repo> worktree add --detach <wt_path> <rev>`) for independent re-verification.
bridge_taskv2_worktree_add_detached :: proc(repo_dir, wt_path, rev: string) -> bool {
	if strings.trim_space(repo_dir) == "" || strings.trim_space(wt_path) == "" || strings.trim_space(rev) == "" do return false
	out, ok := vcs_run([]string{"git", "-C", repo_dir, "worktree", "add", "--detach", wt_path, rev})
	defer if len(out) > 0 do delete(out)
	return ok
}

// bridge_taskv2_worktree_remove_force removes an ephemeral detached git worktree
// (`git -C <repo> worktree remove --force <wt_path>`).
bridge_taskv2_worktree_remove_force :: proc(repo_dir, wt_path: string) -> bool {
	if strings.trim_space(repo_dir) == "" || strings.trim_space(wt_path) == "" do return false
	out, ok := vcs_run([]string{"git", "-C", repo_dir, "worktree", "remove", "--force", wt_path})
	defer if len(out) > 0 do delete(out)
	_ = os.remove_all(wt_path)
	return ok
}

// bridge_taskv2_lease_worktree_path returns the canonical filesystem path for an isolated lease worktree
// under `<repo_dir>/.heimdall/worktrees/<lease_id>`.
bridge_taskv2_lease_worktree_path :: proc(repo_dir, lease_id: string, allocator := context.allocator) -> string {
	clean_repo := strings.trim_right(repo_dir, "/\\")
	return fmt.aprintf("%s/.heimdall/worktrees/%s", clean_repo, lease_id, allocator = allocator)
}

// bridge_taskv2_setup_lease_worktree creates an isolated git worktree for a lease at `<repo_dir>/.heimdall/worktrees/<lease_id>`
// checked out at `base_ref` (or HEAD if base_ref is empty).
bridge_taskv2_setup_lease_worktree :: proc(repo_dir, lease_id, base_ref: string, allocator := context.allocator) -> (string, bool) {
	if strings.trim_space(repo_dir) == "" || strings.trim_space(lease_id) == "" do return "", false
	wt_path := bridge_taskv2_lease_worktree_path(repo_dir, lease_id, allocator)
	rev := base_ref if strings.trim_space(base_ref) != "" else "HEAD"
	parent := fmt.tprintf("%s/.heimdall/worktrees", strings.trim_right(repo_dir, "/\\"))
	_ = bridge_make_directory_all(parent)
	ok := bridge_taskv2_worktree_add_detached(repo_dir, wt_path, rev)
	if !ok {
		delete(wt_path, allocator)
		return "", false
	}
	return wt_path, true
}

// bridge_taskv2_teardown_lease_worktree cleans up the isolated git worktree for a lease.
bridge_taskv2_teardown_lease_worktree :: proc(repo_dir, lease_id: string) -> bool {
	if strings.trim_space(repo_dir) == "" || strings.trim_space(lease_id) == "" do return false
	wt_path := bridge_taskv2_lease_worktree_path(repo_dir, lease_id, context.temp_allocator)
	return bridge_taskv2_worktree_remove_force(repo_dir, wt_path)
}

// bridge_taskv2_should_auto_submit checks whether a verify run qualifies for automatic
// lease submission (`brief.auto_submit == true`, `exit_code == 0`, `!independent`, and `!dirty`).
bridge_taskv2_should_auto_submit :: proc(exit_code: int, independent, dirty, auto_submit: bool) -> bool {
	return auto_submit && exit_code == 0 && !independent && !dirty
}


