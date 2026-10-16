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

import "core:strings"

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
	if ok {
		for f in files {
			if !first do strings.write_byte(&b, ',')
			first = false
			bridge_taskv2_write_file_change(&b, f.path, f.status, f.additions, f.deletions)
		}
	}

	if base_sha := strings.trim_space(base); base_sha != "" {
		revspec := strings.concatenate({base_sha, "..HEAD"})
		defer delete(revspec)
		out, run_ok := vcs_run([]string{"git", "-C", dir, "diff", "--numstat", revspec})
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
	probe := strings.concatenate({"\"", key, "\":"})
	defer delete(probe)
	if strings.contains(body, probe) do return strings.clone(params)
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
		quoted := bridge_local_json_escaped(head)
		defer delete(quoted)
		raw := strings.concatenate({"\"", quoted, "\""})
		defer delete(raw)
		return bridge_taskv2_params_inject(params, "vcs_base", raw)
	case "agent.lease.submit", "agent.lease.handoff":
		dirty, _ := bridge_taskv2_git_dirty(repo)
		base := bridge_local_extract_json_string(params, "vcs_base", "", context.temp_allocator)
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
bridge_agent_lease_local_rpc :: proc(request_id, method, hub_path, params: string, rec: Bridge_Local_Agent_Token_Record) -> string {
	if strings.trim_space(rec.instance_token) == "" do return bridge_local_response_error(request_id, "unavailable", "Bridge-held instance token is unavailable")
	eff := bridge_taskv2_enrich_lease_params(method, params, rec)
	defer delete(eff)
	relay := bridge_local_relay_agent_envelope(hub_path, method, eff, rec)
	if !relay.ok do return bridge_local_response_error(request_id, "retryable_unavailable", "Hub relay failed")
	if relay.status < 200 || relay.status >= 300 do return bridge_local_response_error(request_id, "hub_error", relay.body)
	if strings.trim_space(relay.body) == "" do return bridge_local_response_data(request_id, "{}")
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
