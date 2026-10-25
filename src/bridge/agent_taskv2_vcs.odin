package main

// Task System v2 (M2): bridge-side VCS enrichment for the lease verbs (docs: m2
// wire contract §"Bridge .Local enrichment").
//
//   agent.lease.next      -> params.vcs_base = <git HEAD of the agent's repo>
//   agent.lease.submit    -> params.vcs = {head, dirty, files:[{path,status,add,del}]}
//   agent.lease.handoff   -> same as submit
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
import ws "odin_test:lib/ws"

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
// On a non-peek `agent.lease.next` (or `agent.lease.switch`) that returns a
// `pack`, materializes `<run_dir>/TASK.md`.
bridge_agent_lease_local_rpc :: proc(request_id, method, hub_path, params: string, rec: Bridge_Local_Agent_Token_Record) -> string {
	if strings.trim_space(rec.instance_token) == "" do return bridge_local_response_error(request_id, "unavailable", "Bridge-held instance token is unavailable")
	// The hub is down (no runtime session): nothing is sent, so the caller can
	// safely retry. A relay failure after sending stays retryable_unavailable —
	// the hub may have committed it (F2).
	if !sync.atomic_load(&bridge_hub_runtime_up) do return bridge_local_response_error(request_id, "hub_unreachable", "Hub is unreachable; the request was not sent")
	eff := bridge_taskv2_enrich_lease_params(method, params, rec)
	defer delete(eff)
	relay := bridge_local_relay_agent_envelope(hub_path, method, eff, rec)
	if !relay.ok do return bridge_local_response_error(request_id, "retryable_unavailable", "Hub relay failed")
	if relay.status < 200 || relay.status >= 300 do return bridge_local_response_error(request_id, "hub_error", relay.body)
	if strings.trim_space(relay.body) == "" do return bridge_local_response_data(request_id, "{}")
	if method == "agent.lease.next" || method == "agent.lease.switch" {
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
				// The task's checkout must exist before the agent reads TASK.md
				// and cds into it.
				bridge_taskv2_ensure_pack_worktree(pack_obj)
				if strings.trim_space(run_dir) != "" {
					_ = bridge_taskv2_materialize_task_md(run_dir, pack_obj)
				}
			}
		}
	}
	return bridge_local_response_data(request_id, relay.body)
}

// ---- M3: TASK.md Materialiser + Vault Decryption + 8k-Token Field-Safe Cap -

BRIDGE_TASK_MD_MAX_BYTES :: 32_000 // ~8k tokens (@ 4 bytes/token)

Bridge_Task_Md_Input :: struct {
	fetch: string, // exact pinned generation command for mixed-work inputs
	ref:      string,
	resolved: bool,
	body:     string,
	dropped:  bool,
}

// A task this one waits for, as the hub's pack `dependencies` entry describes
// it: its latest handoff, output and last commit. `dropped` hides the output for
// size (the summary and dead ends always stay). A legacy pack's `verify` result
// is ignored: verification commands were removed.
Bridge_Task_Md_Dependency :: struct {
	task_id, title, state, summary:   string,
	decisions, dead_ends, next_steps: []string,
	output, output_ref:               string,
	output_omitted, dropped:          bool,
	head:                             string,
}

bridge_taskv2_parse_dependencies :: proc(pack_json: string) -> []Bridge_Task_Md_Dependency {
	out := make([dynamic]Bridge_Task_Md_Dependency, context.temp_allocator)
	arr, has := bridge_provider_json_extract_array(pack_json, "dependencies")
	if !has do return out[:]
	defer delete(arr)
	objs := bridge_provider_json_top_level_objects(arr)
	defer bridge_bootstrap_free_object_slice(objs)
	dec_list :: proc(obj, key: string) -> []string {
		raw := jsonx.extract_string_array(obj, key, true, context.temp_allocator)
		for &v in raw do v = bridge_taskv2_decrypt_field(v, context.temp_allocator)
		return raw[:]
	}
	for obj in objs {
		d := Bridge_Task_Md_Dependency{
			task_id        = jsonx.extract_string(obj, "task_id", "", true, context.temp_allocator),
			title          = bridge_taskv2_decrypt_field(jsonx.extract_string(obj, "title", "", true, context.temp_allocator), context.temp_allocator),
			state          = jsonx.extract_string(obj, "state", "", true, context.temp_allocator),
			summary        = bridge_taskv2_decrypt_field(jsonx.extract_string(obj, "summary", "", true, context.temp_allocator), context.temp_allocator),
			decisions      = dec_list(obj, "decisions"),
			dead_ends      = dec_list(obj, "dead_ends"),
			next_steps     = dec_list(obj, "next_steps"),
			output_ref     = jsonx.extract_string(obj, "output_ref", "", true, context.temp_allocator),
			head           = jsonx.extract_string(obj, "head", "", true, context.temp_allocator),
		}
		d.output_omitted, _ = jsonx.extract_bool_literal(obj, "output_omitted", true)
		if o, ok := jsonx.extract_raw_object(obj, "output", true, context.temp_allocator); ok do d.output = bridge_taskv2_decrypt_field(o, context.temp_allocator)
		append(&out, d)
	}
	return out[:]
}

// bridge_taskv2_write_dependencies renders the "From The Tasks This One Waits
// For" section of TASK.md.
bridge_taskv2_write_dependencies :: proc(b: ^strings.Builder, deps: []Bridge_Task_Md_Dependency, task_id: string) {
	if len(deps) == 0 do return
	strings.write_string(b, "\n## From The Tasks This One Waits For\n")
	strings.write_string(b, "Their work is already merged into your checkout. Build on it; do not redo it, and do not repeat their dead ends.\n")
	for d in deps {
		fmt.sbprintf(b, "\n### %s: %s (%s)\n", d.task_id, d.title, d.state if d.state != "" else "unknown")
		if d.state == "cancelled" do strings.write_string(b, "- This task was **cancelled**; its work may be missing or partial.\n")
		if d.summary != "" {
			fmt.sbprintf(b, "- **Handoff Summary**: %s\n", d.summary)
		} else {
			strings.write_string(b, "- No handoff summary was recorded.\n")
		}
		write_list :: proc(b: ^strings.Builder, label: string, items: []string) {
			if len(items) == 0 do return
			fmt.sbprintf(b, "- **%s**:\n", label)
			for it in items do fmt.sbprintf(b, "  - %s\n", it)
		}
		write_list(b, "Decisions", d.decisions)
		write_list(b, "Dead Ends (DO NOT REPEAT)", d.dead_ends)
		write_list(b, "Next Steps It Left", d.next_steps)
		if d.head != "" do fmt.sbprintf(b, "- **Last Commit**: `%s` (see what it changed with `git show --stat %s`)\n", d.head, d.head)
		ref := d.output_ref if d.output_ref != "" else fmt.tprintf("output:%s", d.task_id)
		switch {
		case d.output != "" && !d.dropped:
			fmt.sbprintf(b, "- **Output**: `%s`\n", d.output)
		case d.output != "" || d.output_omitted:
			fmt.sbprintf(b, "- **Output**: omitted for size — fetch with `ham-ctl task fetch %s %s`\n", task_id, ref)
		case d.output_ref != "":
			fmt.sbprintf(b, "- **Output**: see `%s` under Resolved Inputs\n", d.output_ref)
		}
	}
}

bridge_taskv2_decrypt_field :: proc(s: string, allocator := context.temp_allocator) -> string {
	if !bridge_has_vault_token(s) do return strings.clone(s, allocator)
	return bridge_decrypt_embedded_vault_tokens(s, allocator = allocator, locked_marker = VAULT_LOCKED_MARKER)
}

// The least of a description the size cap keeps when it has to cut one.
BRIDGE_TASK_MD_DESCRIPTION_MIN_HEAD :: 2_000

// Everything bridge_taskv2_render_task_md has extracted (and decrypted) from a
// pack. The size cap flips the drop_* / truncation fields and renders again.
Bridge_Task_Md_Doc :: struct {
	task_id, title, role_label, lease_id, expires_at, hard_deadline_at:           string,
	bridge_id, directory_id, provider, model, why, workdir, branch:               string,
	merge_conflict, gate_feedback:                                                string,
	attempt_no, max_attempts, review_rounds:                                      int,
	goal:                                                                         string,
	acceptance:                                                                   []string,
	description:                                                                  string,
	description_truncated:                                                        bool,
	chain_summary:                                                                string,
	inputs:                                                                       []Bridge_Task_Md_Input,
	deps:                                                                         []Bridge_Task_Md_Dependency,
	vcs_head:                                                                     string,
	vcs_has_dirty, vcs_dirty:                                                     bool,
	vcs_files_arr:                                                                string,
	has_prev:                                                                     bool,
	prev_attempt_no:                                                              int,
	prev_outcome, prev_note:                                                      string,
	handoff_summary:                                                              string,
	drop_handoff_summary:                                                         bool,
	handoff_decisions, handoff_dead_ends, handoff_next_steps:                     []string,
	findings_lines:                                                               []string,
	rules:                                                                        []string,
}

bridge_taskv2_description_trailer :: proc(task_id: string) -> string {
	return fmt.tprintf("_(description truncated — run `ham-ctl task show %s` for the full text)_\n", task_id)
}

// bridge_taskv2_utf8_head returns at most n bytes of s, cut on a rune boundary.
bridge_taskv2_utf8_head :: proc(s: string, n: int) -> string {
	if n >= len(s) do return s
	if n <= 0 do return ""
	i := n
	for i > 0 && (s[i] & 0xC0) == 0x80 do i -= 1
	return s[:i]
}

bridge_taskv2_build_task_md :: proc(d: ^Bridge_Task_Md_Doc, alloc := context.temp_allocator) -> string {
	b := strings.builder_make(alloc)
	fmt.sbprintf(&b, "# Task %s: %s (%s, attempt #%d)\n\n", d.task_id, d.title, d.role_label, d.attempt_no)
	fmt.sbprintf(&b, "- **Lease**: `%s` (attempt %d/%d, review_rounds: %d)\n", d.lease_id, d.attempt_no, d.max_attempts, d.review_rounds)
	if d.expires_at != "" || d.hard_deadline_at != "" {
		fmt.sbprintf(&b, "- **Deadlines**: expires `%s`, hard_deadline `%s`\n", d.expires_at, d.hard_deadline_at)
	}
	if d.bridge_id != "" || d.directory_id != "" || d.provider != "" || d.model != "" {
		fmt.sbprintf(&b, "- **Placement**: bridge=`%s` directory=`%s` provider=`%s` model=`%s`\n", d.bridge_id, d.directory_id, d.provider, d.model)
	}
	if d.workdir != "" {
		fmt.sbprintf(&b, "- **Workdir**: `%s` on branch `%s`. `cd` there and do all work and commits in it; it is your own checkout, merged into the directory when the task is done.\n", d.workdir, d.branch)
	}
	// gate_feedback carries ready-made sections (answered block, gate rejection).
	if d.gate_feedback != "" do strings.write_string(&b, d.gate_feedback)
	if d.merge_conflict != "" {
		strings.write_string(&b, "\n## Merge Conflict\n")
		fmt.sbprintf(&b, "This task was done, but branch `%s` did not merge into its directory: %s\n", d.branch, d.merge_conflict)
		strings.write_string(&b, "In the Workdir, merge the directory's current branch into yours (`git merge <that branch>`), resolve the conflicts, commit, run checks appropriate to the change, and submit with the commands and outcomes in the summary.\n")
	}
	strings.write_string(&b, "\n## Brief\n")
	if d.goal != "" {
		fmt.sbprintf(&b, "**Goal**: %s\n", d.goal)
	}
	if len(d.acceptance) > 0 {
		strings.write_string(&b, "**Acceptance**:\n")
		for a in d.acceptance {
			fmt.sbprintf(&b, "- %s\n", a)
		}
	}

	if strings.trim_space(d.description) != "" {
		strings.write_string(&b, "\n## Description\n")
		strings.write_string(&b, d.description)
		if !strings.has_suffix(d.description, "\n") do strings.write_byte(&b, '\n')
		if d.description_truncated do strings.write_string(&b, bridge_taskv2_description_trailer(d.task_id))
	}

	strings.write_string(&b, "\n## Chain Summary\n")
	if strings.trim_space(d.chain_summary) != "" {
		strings.write_string(&b, d.chain_summary)
		if !strings.has_suffix(d.chain_summary, "\n") do strings.write_byte(&b, '\n')
	} else {
		strings.write_string(&b, "_(none)_\n")
	}

	bridge_taskv2_write_dependencies(&b, d.deps, d.task_id)

	if len(d.inputs) > 0 {
		strings.write_string(&b, "\n## Resolved Inputs\n")
		for inp in d.inputs {
			if inp.dropped && inp.fetch != "" {
				fmt.sbprintf(&b, "- `%s`: output omitted; fetch the pinned generation with `%s`\n", inp.ref, inp.fetch)
			} else if inp.dropped {
				fmt.sbprintf(&b, "- `%s`: omitted for size — fetch with `ham-ctl task fetch %s %s`\n", inp.ref, d.task_id, inp.ref)
			} else if inp.resolved {
				fmt.sbprintf(&b, "- `%s`: %s\n", inp.ref, inp.body)
			} else {
				fmt.sbprintf(&b, "- `%s`: _(unresolved — `ham-ctl task fetch %s %s`)_\n", inp.ref, d.task_id, inp.ref)
			}
		}
	}

	strings.write_string(&b, "\n## Where You Are\n")
	if d.vcs_head != "" {
		fmt.sbprintf(&b, "- **HEAD**: `%s` (dirty: `%v`)\n", d.vcs_head, d.vcs_dirty if d.vcs_has_dirty else false)
		if strings.has_prefix(strings.trim_space(d.vcs_files_arr), "[") && strings.trim_space(d.vcs_files_arr) != "[]" {
			fmt.sbprintf(&b, "- **Changed files**: `%s`\n", strings.trim_space(d.vcs_files_arr))
		}
	} else {
		strings.write_string(&b, "- No prior VCS state recorded.\n")
	}

	if d.has_prev {
		fmt.sbprintf(&b, "\n## Previous Attempt (#%d)\n", d.prev_attempt_no)
		if d.prev_outcome != "" {
			fmt.sbprintf(&b, "- **Outcome**: `%s`\n", d.prev_outcome)
		}
		if d.prev_note != "" {
			fmt.sbprintf(&b, "- **Last Heartbeat Note**: %s\n", d.prev_note)
		}
		if d.drop_handoff_summary {
			fmt.sbprintf(&b, "- **Handoff Summary**: omitted for size — fetch with `ham-ctl task fetch %s facet:%s:%d:handoff`\n", d.task_id, d.task_id, d.prev_attempt_no)
		} else if d.handoff_summary != "" {
			fmt.sbprintf(&b, "- **Handoff Summary**: %s\n", d.handoff_summary)
		}
		if len(d.handoff_decisions) > 0 {
			strings.write_string(&b, "- **Decisions**:\n")
			for dec in d.handoff_decisions {
				fmt.sbprintf(&b, "  - %s\n", bridge_taskv2_decrypt_field(dec, context.temp_allocator))
			}
		}
		if len(d.handoff_dead_ends) > 0 {
			strings.write_string(&b, "- **Dead Ends (DO NOT REPEAT)**:\n")
			for de in d.handoff_dead_ends {
				fmt.sbprintf(&b, "  - %s\n", bridge_taskv2_decrypt_field(de, context.temp_allocator))
			}
		}
		if len(d.handoff_next_steps) > 0 {
			strings.write_string(&b, "- **Next Steps**:\n")
			for ns in d.handoff_next_steps {
				fmt.sbprintf(&b, "  - %s\n", bridge_taskv2_decrypt_field(ns, context.temp_allocator))
			}
		}
	}

	if len(d.findings_lines) > 0 {
		strings.write_string(&b, "\n## Open Findings\n")
		for fl in d.findings_lines {
			strings.write_string(&b, fl)
			strings.write_byte(&b, '\n')
		}
	}

	fmt.sbprintf(&b, "\n## Why You Were Chosen\n`%s`\n", d.why)

	strings.write_string(&b, "\n## Protocol Rules\n")
	if len(d.rules) > 0 {
		for r in d.rules {
			strings.write_string(&b, r)
			strings.write_byte(&b, '\n')
		}
	} else {
		strings.write_string(&b, "1. Confirm lease with `ham-ctl lease next`.\n2. Choose and run checks appropriate to the change; report the commands and their outcomes in `ham-ctl lease submit --summary \"...\"` when done.\n")
	}
	return strings.to_string(b)
}

// bridge_taskv2_render_task_md decrypts all vault:v2 tokens in pack_json,
// applies the field-safe 8k-token (max_bytes) cap AFTER decryption (never inside a
// field, dropping in order: 1. resolved input bodies, then dependency outputs
// -> 2. previous handoff summary -> 3. task description cut to a head with a trailer;
// preserving brief, dead_ends, and open findings intact),
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
	workdir := jsonx.extract_string(placement_obj, "workdir", "", true, context.temp_allocator)
	branch := jsonx.extract_string(placement_obj, "branch", "", true, context.temp_allocator)
	merge_conflict := ""
	if mc, has_mc := jsonx.extract_raw_object(pack_json, "merge_conflict", true, context.temp_allocator); has_mc {
		detail := jsonx.extract_string(mc, "detail", "", true, context.temp_allocator)
		files := jsonx.extract_string(mc, "files", "", true, context.temp_allocator)
		merge_conflict = fmt.tprintf("%s%s", detail, fmt.tprintf(" (files: %s)", files) if files != "" else "")
		if merge_conflict == "" do merge_conflict = "the branch did not merge"
	}
	gate_feedback := ""
	answer_section := ""
	if gf, has_gf := jsonx.extract_raw_object(pack_json, "gate_feedback", true, context.temp_allocator); has_gf {
		summary := bridge_taskv2_decrypt_field(jsonx.extract_string(gf, "summary", "", true, context.temp_allocator), context.temp_allocator)
		findings_raw, _ := jsonx.extract_raw_array(gf, "findings", true, context.temp_allocator)
		round := jsonx.extract_int(gf, "round", 1, true)
		gb := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&gb, "Your previous output was rejected at the approval gate (round %d).\n", round)
		if strings.trim_space(summary) != "" do fmt.sbprintf(&gb, "**Reviewer's reason**: %s\n", summary)
		if strings.trim_space(findings_raw) != "" && strings.trim_space(findings_raw) != "[]" do fmt.sbprintf(&gb, "**Findings**: `%s`\n", strings.trim_space(findings_raw))
		strings.write_string(&gb, "Address this feedback in a new output; a new gate follows your submission.\n")
		gate_feedback = strings.to_string(gb)
	}

	// A block this attempt resumes from was answered: shown before the gate
	// feedback, in the same "notices" slot of the document.
	if ans, has_ans := jsonx.extract_raw_object(pack_json, "answer", true, context.temp_allocator); has_ans {
		q := bridge_taskv2_decrypt_field(jsonx.extract_string(ans, "question", "", true, context.temp_allocator), context.temp_allocator)
		note := bridge_taskv2_decrypt_field(jsonx.extract_string(ans, "note", "", true, context.temp_allocator), context.temp_allocator)
		by := jsonx.extract_string(ans, "by", "", true, context.temp_allocator)
		ab := strings.builder_make(context.temp_allocator)
		strings.write_string(&ab, "\n## Your Block Was Answered\n")
		if strings.trim_space(q) != "" do fmt.sbprintf(&ab, "**You asked**: %s\n", q)
		if strings.trim_space(note) != "" {
			fmt.sbprintf(&ab, "**%s answered**: %s\n", "The user" if by == "user" else "The hub" if by == "hub" else "Answer", note)
		} else {
			strings.write_string(&ab, "The block was cleared without a note; continue with what you know.\n")
		}
		answer_section = strings.to_string(ab)
	}

	// The coordinator or owner put this task on hold while it is leased: check
	// in a safe state and hand off; the hub parks the task until it is released.
	if cp, has_cp := jsonx.extract_raw_object(pack_json, "checkpoint", true, context.temp_allocator); has_cp {
		reason := bridge_taskv2_decrypt_field(jsonx.extract_string(cp, "reason", "", true, context.temp_allocator), context.temp_allocator)
		cb := strings.builder_make(context.temp_allocator)
		strings.write_string(&cb, "\n## Checkpoint Requested\n")
		strings.write_string(&cb, "This task was put on hold. Reach a safe stopping point, commit your work, then run `ham-ctl lease handoff --summary … --next-steps …`. The task stays parked until it is released; your lease is not revoked meanwhile. Holding a review lease? Do not post a verdict: run `ham-ctl lease handoff --summary <review progress>`; your review is re-dispatched after the release.\n")
		if strings.trim_space(reason) != "" do fmt.sbprintf(&cb, "**Reason**: %s\n", reason)
		answer_section = strings.concatenate({strings.to_string(cb), answer_section}, context.temp_allocator)
	}

	// Ready-made notice sections for the document (build_doc cannot see locals).
	if gate_feedback != "" do gate_feedback = strings.concatenate({"\n## Rejected At The Gate\n", gate_feedback}, context.temp_allocator)
	if answer_section != "" do gate_feedback = strings.concatenate({answer_section, gate_feedback}, context.temp_allocator)
	// Solo mode: say how this chain works, ahead of the other notices.
	if solo, sok := jsonx.extract_bool_literal(chain_obj, "solo", true); sok && solo {
		gate_feedback = strings.concatenate({"\n## Solo Mode\nYou are this chain's coordinator AND its worker; the user reviews every task. Pull work with `ham-ctl lease next`, submit with `ham-ctl lease submit`, switch with `ham-ctl lease switch <task> --summary …`. Never set task status by hand; never review your own work.\n", gate_feedback}, context.temp_allocator)
	}

	raw_title := jsonx.extract_string(task_obj, "title", "", true, context.temp_allocator)
	raw_desc := jsonx.extract_string(task_obj, "description", "", true, context.temp_allocator)
	title := bridge_taskv2_decrypt_field(raw_title, context.temp_allocator)
	description := bridge_taskv2_decrypt_field(raw_desc, context.temp_allocator)

	goal := bridge_taskv2_decrypt_field(jsonx.extract_string(brief_obj, "goal", "", true, context.temp_allocator), context.temp_allocator)
	if strings.trim_space(goal) == "" do goal = description
	acc_raw := jsonx.extract_string_array(brief_obj, "acceptance", true, context.temp_allocator)
	acceptance := make([dynamic]string, context.temp_allocator)
	for a in acc_raw {
		append(&acceptance, bridge_taskv2_decrypt_field(a, context.temp_allocator))
	}

	raw_chain_summary := jsonx.extract_string(chain_obj, "summary", jsonx.extract_string(pack_json, "chain_summary", "", true, context.temp_allocator), true, context.temp_allocator)
	chain_summary := bridge_taskv2_decrypt_field(raw_chain_summary, context.temp_allocator)

	// Resolved inputs
	inputs := make([dynamic]Bridge_Task_Md_Input, context.temp_allocator)
	if inputs_arr, has_inputs := bridge_provider_json_extract_array(pack_json, "inputs", context.temp_allocator); has_inputs {
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

    // The receipt is scoped to a task attempt or parent run execution, so
    // workers never accidentally fetch the newest output of a retried source.
    if array, present := bridge_provider_json_extract_array(pack_json, "work_inputs", context.temp_allocator); present {
        objects := bridge_provider_json_top_level_objects(array)
        defer bridge_bootstrap_free_object_slice(objects)
        for object in objects {
            kind := jsonx.extract_string(object, "kind", "", true, context.temp_allocator)
            id := jsonx.extract_string(object, "id", "", true, context.temp_allocator)
            generation := jsonx.extract_int(object, "generation", 0, true)
            manifest, has_manifest := jsonx.extract_raw_object(object, "output_manifest", true, context.temp_allocator)
            append(&inputs, Bridge_Task_Md_Input{
                ref = fmt.tprintf("%s:%s generation %d", kind, id, generation),
                fetch = jsonx.extract_string(object, "fetch", "", true, context.temp_allocator),
                resolved = true, dropped = !has_manifest,
                body = bridge_taskv2_decrypt_field(manifest, context.temp_allocator),
            })
        }
    }
    if stage, present := jsonx.extract_raw_object(pack_json, "workflow_stage", true, context.temp_allocator); present {
        notice := fmt.tprintf("\n## Workflow Run\nRun `%s`, execution `%d`, stage `%s` (item %d of %d). The same chain coordinator owns this run. Work only the task covered by your lease.\n",
            jsonx.extract_string(stage, "run_id", "", true, context.temp_allocator),
            jsonx.extract_int(stage, "execution_no", 0, true),
            jsonx.extract_string(stage, "stage_key", "", true, context.temp_allocator),
            jsonx.extract_int(stage, "stage_index", 0, true) + 1,
            jsonx.extract_int(stage, "stage_count", 1, true))
        gate_feedback = strings.concatenate({gate_feedback, notice}, context.temp_allocator)
    }

	deps := bridge_taskv2_parse_dependencies(pack_json)

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

	// Open Findings (never dropped)
	findings_lines := make([dynamic]string, context.temp_allocator)
	if findings_arr, has_f := bridge_provider_json_extract_array(pack_json, "findings", context.temp_allocator); has_f {
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

	// When the brief has no goal, the goal line already shows the description;
	// don't repeat it under its own heading.
	if goal == description do description = ""

	doc := Bridge_Task_Md_Doc{
		task_id = task_id, title = title, role_label = role_label, lease_id = lease_id,
		expires_at = expires_at, hard_deadline_at = hard_deadline_at,
		bridge_id = bridge_id, directory_id = directory_id, provider = provider, model = model,
		why = why, workdir = workdir, branch = branch, merge_conflict = merge_conflict, gate_feedback = gate_feedback,
		attempt_no = attempt_no, max_attempts = max_attempts, review_rounds = review_rounds,
		goal = goal, acceptance = acceptance[:],
		description = description,
		chain_summary = chain_summary,
		inputs = inputs[:],
		deps = deps[:],
		vcs_head = vcs_head, vcs_has_dirty = vcs_has_dirty, vcs_dirty = vcs_dirty, vcs_files_arr = vcs_files_arr,
		has_prev = has_prev, prev_attempt_no = prev_attempt_no, prev_outcome = prev_outcome, prev_note = prev_note,
		handoff_summary = handoff_summary,
		handoff_decisions = handoff_decisions[:], handoff_dead_ends = handoff_dead_ends[:], handoff_next_steps = handoff_next_steps[:],
		findings_lines = findings_lines[:],
		rules = rules[:],
	}

	rendered := bridge_taskv2_build_task_md(&doc)

	// Step 1 of field-safe cap: drop resolved input bodies (from last to first)
	if max_bytes > 0 && len(rendered) > max_bytes {
		for i := len(inputs) - 1; i >= 0 && len(rendered) > max_bytes; i -= 1 {
			if inputs[i].dropped do continue
			inputs[i].dropped = true
			rendered = bridge_taskv2_build_task_md(&doc)
		}
	}

	// Step 1b: drop dependency outputs (from last to first); their summaries and
	// dead ends stay, and the agent can fetch the output by ref.
	if max_bytes > 0 && len(rendered) > max_bytes {
		for i := len(deps) - 1; i >= 0 && len(rendered) > max_bytes; i -= 1 {
			if deps[i].dropped || deps[i].output == "" do continue
			deps[i].dropped = true
			rendered = bridge_taskv2_build_task_md(&doc)
		}
	}

	// Step 2 of field-safe cap: drop previous handoff summary (preserving dead_ends!)
	if max_bytes > 0 && len(rendered) > max_bytes && handoff_summary != "" {
		doc.drop_handoff_summary = true
		rendered = bridge_taskv2_build_task_md(&doc)
	}

	// Step 3 of field-safe cap: cut the task description to a head that fits,
	// keeping at least BRIDGE_TASK_MD_DESCRIPTION_MIN_HEAD bytes, with a trailer
	// pointing at the full text. The brief's goal and acceptance are never cut.
	if max_bytes > 0 && len(rendered) > max_bytes && doc.description != "" {
		trailer_len := len(bridge_taskv2_description_trailer(task_id))
		head := len(description) - (len(rendered) - max_bytes) - trailer_len
		head = max(head, min(BRIDGE_TASK_MD_DESCRIPTION_MIN_HEAD, len(description)))
		if head < len(description) {
			doc.description = bridge_taskv2_utf8_head(description, head)
			doc.description_truncated = true
			rendered = bridge_taskv2_build_task_md(&doc)
		}
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

// ---- per-task worktrees (hub: lease.odin task_worktree, merge.odin) --------
//
// A task placed in a git directory works on branch `heimdall/<task_id>` in
// `<repo>/.heimdall/worktrees/<task_id>`. The hub names both in the pack's
// placement; the bridge creates the checkout when it materializes TASK.md on
// `lease.next` and merges it back on the hub's `taskv2_merge_worktree`.

// bridge_taskv2_is_checkout_root reports whether `dir` is the top level of a
// git checkout (a worktree dir that is merely a subdirectory of the main
// checkout does not count).
bridge_taskv2_is_checkout_root :: proc(dir: string) -> bool {
	if strings.trim_space(dir) == "" || !os.exists(dir) do return false
	out, ok := vcs_run([]string{"git", "-C", dir, "rev-parse", "--show-toplevel"})
	defer if len(out) > 0 do delete(out)
	if !ok do return false
	return strings.trim_right(strings.trim_space(out), "/") == strings.trim_right(strings.trim_space(dir), "/")
}

// bridge_taskv2_exclude_worktrees keeps `.heimdall/` out of the main checkout's
// status (worktrees live inside the repository directory).
bridge_taskv2_exclude_worktrees :: proc(repo: string) {
	out, ok := vcs_run([]string{"git", "-C", repo, "rev-parse", "--git-path", "info/exclude"})
	defer if len(out) > 0 do delete(out)
	if !ok do return
	path := strings.trim_space(out)
	if path == "" do return
	if !strings.has_prefix(path, "/") do path = fmt.tprintf("%s/%s", strings.trim_right(repo, "/"), path)
	existing, _ := os.read_entire_file(path, context.temp_allocator)
	for line in strings.split_lines(string(existing), context.temp_allocator) {
		if strings.trim_space(line) == ".heimdall/" || strings.trim_space(line) == ".heimdall" do return
	}
	_ = bridge_make_directory_all(path[:strings.last_index_byte(path, '/')])
	body := string(existing)
	if body != "" && !strings.has_suffix(body, "\n") do body = strings.concatenate({body, "\n"}, context.temp_allocator)
	body = strings.concatenate({body, ".heimdall/\n"}, context.temp_allocator)
	_ = os.write_entire_file(path, transmute([]byte)body)
}

bridge_taskv2_branch_exists :: proc(repo, branch: string) -> bool {
	out, ok := vcs_run([]string{"git", "-C", repo, "rev-parse", "--verify", "--quiet", strings.concatenate({"refs/heads/", branch}, context.temp_allocator)})
	defer if len(out) > 0 do delete(out)
	return ok
}

// bridge_taskv2_ensure_task_worktree makes `workdir` a checkout of `branch`,
// creating the branch from the repo's HEAD the first time. Idempotent: an
// existing checkout (a retry, a review lease, a changes-requested round) is
// left as is, so the task's work carries across attempts.
bridge_taskv2_ensure_task_worktree :: proc(repo, workdir, branch: string) -> bool {
	if strings.trim_space(repo) == "" || strings.trim_space(workdir) == "" || strings.trim_space(branch) == "" do return false
	if bridge_taskv2_is_checkout_root(workdir) do return true
	bridge_taskv2_exclude_worktrees(repo)
	if prune, pok := vcs_run([]string{"git", "-C", repo, "worktree", "prune"}); pok || len(prune) > 0 do delete(prune)
	if slash := strings.last_index_byte(strings.trim_right(workdir, "/"), '/'); slash > 0 do _ = bridge_make_directory_all(workdir[:slash])
	args: []string
	if bridge_taskv2_branch_exists(repo, branch) {
		args = []string{"git", "-C", repo, "worktree", "add", workdir, branch}
	} else {
		args = []string{"git", "-C", repo, "worktree", "add", "-b", branch, workdir, "HEAD"}
	}
	out, errs, ok := vcs_run_capture(args)
	defer if len(out) > 0 do delete(out)
	defer if len(errs) > 0 do delete(errs)
	if !ok do fmt.eprintfln("taskv2: worktree add %s failed: %s", workdir, strings.trim_space(errs))
	return ok
}

// bridge_taskv2_ensure_pack_worktree creates the checkout a lease pack names
// (placement.workdir/branch in placement.directory_path). No-op for packs
// without a workdir.
bridge_taskv2_ensure_pack_worktree :: proc(pack_json: string) {
	place, has := jsonx.extract_raw_object(pack_json, "placement", true, context.temp_allocator)
	if !has {
		if lease_obj, lok := jsonx.extract_raw_object(pack_json, "lease", true, context.temp_allocator); lok {
			place, has = jsonx.extract_raw_object(lease_obj, "placement", true, context.temp_allocator)
		}
	}
	if !has do return
	repo := jsonx.extract_string(place, "directory_path", "", true, context.temp_allocator)
	workdir := jsonx.extract_string(place, "workdir", "", true, context.temp_allocator)
	branch := jsonx.extract_string(place, "branch", "", true, context.temp_allocator)
	if workdir == "" || repo == "" || branch == "" do return
	_ = bridge_taskv2_ensure_task_worktree(repo, workdir, branch)
}

Bridge_Taskv2_Merge_Result :: struct {
	ok:       bool,
	conflict: bool,
	detail:   string,
	head:     string,
	mode:     string, // "fast-forward" | "merge" | "none"
	files:    [dynamic]string,
}

// bridge_taskv2_git_identity_args supplies a committer identity for the merge
// commit when the repository has none configured (bridge services often run
// without a global git identity).
bridge_taskv2_git_identity_args :: proc(repo: string) -> []string {
	out, ok := vcs_run([]string{"git", "-C", repo, "config", "user.email"})
	defer if len(out) > 0 do delete(out)
	if ok && strings.trim_space(out) != "" do return nil
	args := make([]string, 4, context.temp_allocator)
	args[0], args[1], args[2], args[3] = "-c", "user.name=Heimdall", "-c", "user.email=heimdall@localhost"
	return args
}

// bridge_taskv2_merge_task_worktree merges `branch` into the branch checked
// out in `repo`, then removes the worktree and the branch. Uncommitted work
// left in the worktree is committed first so nothing is lost. Any merge
// failure (conflict, dirty main checkout) aborts the merge and keeps the
// worktree and branch: the hub blocks the task on a human.
bridge_taskv2_merge_task_worktree :: proc(repo, workdir, branch, task_id: string) -> Bridge_Taskv2_Merge_Result {
	r := Bridge_Taskv2_Merge_Result{files = make([dynamic]string, context.temp_allocator)}
	if strings.trim_space(repo) == "" || strings.trim_space(branch) == "" {
		r.detail = "missing repo or branch"
		return r
	}
	ident := bridge_taskv2_git_identity_args(repo)
	if bridge_taskv2_is_checkout_root(workdir) {
		if dirty, dok := bridge_taskv2_git_dirty(workdir); dok && dirty {
			add, _ := vcs_run([]string{"git", "-C", workdir, "add", "-A"})
			if len(add) > 0 do delete(add)
			commit_args := make([dynamic]string, context.temp_allocator)
			append(&commit_args, "git", "-C", workdir)
			for a in ident do append(&commit_args, a)
			append(&commit_args, "commit", "-m", fmt.tprintf("heimdall: uncommitted work left in %s", task_id))
			c, _ := vcs_run(commit_args[:])
			if len(c) > 0 do delete(c)
		}
	}
	if !bridge_taskv2_branch_exists(repo, branch) {
		r.ok = true
		r.mode = "none"
		r.detail = "branch not found; nothing to merge"
		return r
	}
	before, _ := bridge_taskv2_git_head(repo)
	defer if before != "" do delete(before)
	tip_out, _ := vcs_run([]string{"git", "-C", repo, "rev-parse", "--verify", branch})
	defer if len(tip_out) > 0 do delete(tip_out)
	tip := strings.trim_space(tip_out)

	merge_args := make([dynamic]string, context.temp_allocator)
	append(&merge_args, "git", "-C", repo)
	for a in ident do append(&merge_args, a)
	append(&merge_args, "merge", "--no-edit", "-m", fmt.tprintf("Merge %s (%s)", branch, task_id), branch)
	mout, merr, mok := vcs_run_capture(merge_args[:])
	defer if len(mout) > 0 do delete(mout)
	defer if len(merr) > 0 do delete(merr)
	if !mok {
		r.conflict = true
		if u, uok := vcs_run([]string{"git", "-C", repo, "diff", "--name-only", "--diff-filter=U"}); uok {
			for line in strings.split_lines(u, context.temp_allocator) {
				if f := strings.trim_space(line); f != "" do append(&r.files, strings.clone(f, context.temp_allocator))
			}
			delete(u)
		}
		ab, _ := vcs_run([]string{"git", "-C", repo, "merge", "--abort"})
		if len(ab) > 0 do delete(ab)
		detail := strings.trim_space(merr) if strings.trim_space(merr) != "" else strings.trim_space(mout)
		if len(detail) > VCS_ERROR_DETAIL_MAX do detail = detail[len(detail) - VCS_ERROR_DETAIL_MAX:]
		r.detail = strings.clone(detail, context.temp_allocator)
		return r
	}
	r.ok = true
	if after, aok := bridge_taskv2_git_head(repo); aok {
		r.head = strings.clone(after, context.temp_allocator)
		delete(after)
	}
	switch {
	case r.head == before: r.mode = "none"
	case r.head == tip:    r.mode = "fast-forward"
	case:                  r.mode = "merge"
	}
	if bridge_taskv2_is_checkout_root(workdir) do _ = bridge_taskv2_worktree_remove_force(repo, workdir)
	del, _ := vcs_run([]string{"git", "-C", repo, "branch", "-D", branch})
	if len(del) > 0 do delete(del)
	return r
}

bridge_taskv2_merge_result_json :: proc(command_id: string, r: Bridge_Taskv2_Merge_Result) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"taskv2_merge_worktree_result\",\"command_id\":\"")
	bridge_local_write_json_string(&b, command_id)
	fmt.sbprintf(&b, "\",\"ok\":%v,\"conflict\":%v,\"detail\":\"", r.ok, r.conflict)
	bridge_local_write_json_string(&b, r.detail)
	strings.write_string(&b, "\",\"head\":\"")
	bridge_local_write_json_string(&b, r.head)
	strings.write_string(&b, "\",\"mode\":\"")
	bridge_local_write_json_string(&b, r.mode)
	strings.write_string(&b, "\",\"files\":[")
	for f, i in r.files {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_byte(&b, '"')
		bridge_local_write_json_string(&b, f)
		strings.write_byte(&b, '"')
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// bridge_taskv2_handle_command serves the hub's task-system commands on the
// runtime WS. Returns false for any other type.
bridge_taskv2_handle_command :: proc(conn: ^ws.Connection, type, text: string) -> bool {
	if type != "taskv2_merge_worktree" do return false
	command_id := jsonx.extract_string(text, "command_id", "", true, context.temp_allocator)
	if cached, ok := bridge_runtime_cached_command(command_id); ok {
		_ = bridge_hub_send(conn, cached)
		return true
	}
    // Hub uses one stable command identity per task attempt. Keep the settled
    // result on disk as well as in the bounded runtime cache: a delayed replay
    // must never re-run a previously conflicted branch after the run retries.
    repo := jsonx.extract_string(text, "repo", "", true, context.temp_allocator)
    if command_id == "" || strings.contains(command_id, "/") || strings.contains(command_id, "\\") || strings.contains(command_id, "..") {
     out := bridge_taskv2_merge_result_json(command_id, Bridge_Taskv2_Merge_Result{detail = "invalid merge command identity"})
     defer delete(out)
     _ = bridge_hub_send(conn, out)
     return true
    }
    receipt_dir := fmt.tprintf("%s/.heimdall/merge-results", strings.trim_right(repo, "/"))
    receipt_path := fmt.tprintf("%s/%s.json", receipt_dir, command_id)
    if stored, err := os.read_entire_file(receipt_path, context.temp_allocator); err == nil {
     _ = bridge_hub_send(conn, string(stored))
     return true
    }
	r := bridge_taskv2_merge_task_worktree(
		jsonx.extract_string(text, "repo", "", true, context.temp_allocator),
		jsonx.extract_string(text, "workdir", "", true, context.temp_allocator),
		jsonx.extract_string(text, "branch", "", true, context.temp_allocator),
		jsonx.extract_string(text, "task_id", "", true, context.temp_allocator),
	)
	out := bridge_taskv2_merge_result_json(command_id, r)
	defer delete(out)
    // Do not acknowledge a settled merge until duplicate suppression is durable.
    _ = bridge_make_directory_all(receipt_dir)
    if err := os.write_entire_file(receipt_path, transmute([]byte)out); err != nil {
     failure := bridge_taskv2_merge_result_json(command_id, Bridge_Taskv2_Merge_Result{detail = "merge outcome could not be persisted; settle before retry"})
     defer delete(failure)
     _ = bridge_hub_send(conn, failure)
     return true
    }
	bridge_runtime_cache_command(command_id, out)
	_ = bridge_hub_send(conn, out)
	return true
}
