package taskv2

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import jsonx "odin_test:lib/jsonx"

// Context pack (plan §3b / §4c) — M3 FULL PACK. The hub builds the complete
// structure; the bridge decrypts vault tokens, applies the 8 k-token cap after
// decryption (never inside a field) and writes <run_dir>/TASK.md.
PACK_VERSION :: 1
CHAIN_SUMMARY_MAX_LINES :: 60

build_pack_json :: proc(svc: ^Service, chain: domain.Task_Chain, task: domain.Task, lease: domain.Task_Lease, inst: domain.Agent_Instance) -> string {
	evs, _ := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	view := fold_task(evs, fold_input_for_task(task, true))
	// "why this attempt exists" is the release that PRECEDED the current grant:
	// fold up to (excluding) the last lease_granted for this lease.
	pre := view
	for i := len(evs) - 1; i >= 0; i -= 1 {
		if evs[i].kind == EV_LEASE_GRANTED && strings.contains(evs[i].payload_json, lease.lease_id) {
			pre = fold_task(evs[:i], fold_input_for_task(task, true))
			break
		}
	}

	max_attempts := brief_max_attempts(task.brief_json)
	if max_attempts <= 0 do max_attempts = domain.TASK_MAX_ATTEMPTS
	dirs, _ := iface.taskchain_list_directories_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	dir_id := resolve_directory_for_bridge(dirs, lease.bridge_id if lease.bridge_id != "" else inst.bridge_id)
	provider := lease.provider if lease.provider != "" else inst.provider
	model := lease.model if lease.model != "" else inst.model
	bridge_id := lease.bridge_id if lease.bridge_id != "" else inst.bridge_id

	placement_obj := json_begin()
	json_str(&placement_obj, "bridge_id", bridge_id)
	json_str(&placement_obj, "directory_id", dir_id)
	// The directory's path on that bridge, so `ham-ctl verify` / submit run in the
	// task's repository even when the agent's own cwd is its instance dir.
	dir_path := ""
	workdir, branch := "", ""
	for d in dirs do if d.directory_id == dir_id {
		dir_path = d.path
		workdir, branch = task_worktree(d, task.task_id)
		break
	}
	json_str(&placement_obj, "directory_path", dir_path)
	// Per-task checkout (git directories): the agent works, verifies and
	// submits here; the hub merges `branch` back when the task is done.
	if workdir != "" {
		json_str(&placement_obj, "workdir", workdir)
		json_str(&placement_obj, "branch", branch)
	}
	json_str(&placement_obj, "provider", provider)
	json_str(&placement_obj, "model", model)
	placement_json := json_end(&placement_obj)

	o := json_begin()
	json_int(&o, "version", PACK_VERSION)
	// Top-level convenience fields (plan §3b) alongside nested `lease` object.
	json_str(&o, "lease_id", lease.lease_id)
	json_str(&o, "task_id", string(task.task_id))
	json_int(&o, "attempt_no", i64(lease.attempt_no))
	json_int(&o, "max_attempts", i64(max_attempts))
	json_int(&o, "review_round", i64(view.review_rounds))
	json_int(&o, "review_rounds", i64(view.review_rounds))
	json_str(&o, "expires_at", lease.expires_at)
	json_str(&o, "hard_deadline_at", lease.hard_deadline_at)
	json_raw(&o, "placement", placement_json)

	l := json_begin()
	json_str(&l, "lease_id", lease.lease_id)
	json_str(&l, "kind", lease.kind)
	json_str(&l, "review_role", lease.review_role)
	// Hybrid review model: one review lease covers every role this agent owes
	// on the task; each comes with what that role is asked to check.
	if lease.kind == domain.LEASE_KIND_REVIEW do json_raw(&l, "review_roles", review_roles_pack_json(chain, lease.review_role))
	json_int(&l, "attempt_no", i64(lease.attempt_no))
	json_int(&l, "max_attempts", i64(max_attempts))
	json_int(&l, "review_round", i64(view.review_rounds))
	json_int(&l, "review_rounds", i64(view.review_rounds))
	json_str(&l, "granted_at", lease.granted_at)
	json_str(&l, "expires_at", lease.expires_at)
	json_str(&l, "hard_deadline_at", lease.hard_deadline_at)
	json_str(&l, "delivery", lease.delivery)
	json_raw(&l, "placement", placement_json)
	json_raw(&o, "lease", json_end(&l))

	brief_raw := task.brief_json if strings.has_prefix(strings.trim_space(task.brief_json), "{") else "{}"
	t := json_begin()
	json_str(&t, "task_id", string(task.task_id))
	json_str(&t, "title", task.title)
	json_str(&t, "description", task.description)
	json_str(&t, "priority", domain.task_priority_string(task.priority))
	json_str(&t, "state", domain.task_state_string(task.state))
	json_str(&t, "kind", domain.task_kind_string(task.kind))
	json_raw(&t, "brief", brief_raw)
	json_raw(&o, "task", json_end(&t))
	json_raw(&o, "brief", brief_raw)

	c := json_begin()
	json_str(&c, "chain_id", string(chain.chain_id))
	json_str(&c, "title", chain.title)
	json_str(&c, "kind", chain.kind)
	summary := ""
	if s, sok, _ := iface.taskchain_get_chain_summary(svc.repo, chain.chain_id, chain.owner_user_id); sok {
		summary = s.body
	}
	if summary == "" {
		summary, _ = build_mechanical_chain_summary(svc, chain)
	}
	json_str(&c, "summary", summary)
	// Solo mode: the coordinator works its own chain (REQ-SOLO-1).
	if chain_is_solo(svc, chain) do json_bool(&c, "solo", true)
	json_raw(&o, "chain", json_end(&c))
	json_str(&o, "chain_summary", summary)
	if task.stage_key != "" {
		json_raw(&o, "workflow_stage", workflow_stage_pack_json(svc, chain, task))
	}

	json_raw(&o, "inputs", resolve_brief_inputs_json(svc, task))

	prev_json, where_vcs, prev_outcome := previous_attempt_and_vcs_json(svc, task, lease, pre.last_release == .Handoff, evs)
	json_raw(&o, "where_you_are", where_vcs)
	json_raw(&o, "previous_attempt", prev_json)
	json_raw(&o, "findings", open_findings_json(svc, task, lease))
	json_str(&o, "why", pack_why(pre, lease, prev_outcome))
	// The task was done but its branch did not merge into the directory: this
	// attempt reconciles the branch (merge the directory's branch in, resolve,
	// verify, resubmit). Only while no later approval has cleared it.
	for i := len(evs) - 1; i >= 0; i -= 1 {
		if evs[i].kind == EV_APPROVED || evs[i].kind == EV_MERGED do break
		if evs[i].kind == EV_MERGE_CONFLICT {
			json_raw(&o, "merge_conflict", evs[i].payload_json)
			break
		}
	}
	// A gate rejected this stage's previous output (F1): the reviewer's reason,
	// until this task submits again.
	for i := len(evs) - 1; i >= 0; i -= 1 {
		if evs[i].kind == EV_SUBMITTED do break
		if evs[i].kind == EV_GATE_FEEDBACK {
			json_raw(&o, "gate_feedback", evs[i].payload_json)
			break
		}
	}

	// The block this attempt resumes from was answered: the question and the
	// answer (a human's note, or the hub's auto-answer when the referenced task
	// finished), until the task submits again.
	for i := len(evs) - 1; i >= 0; i -= 1 {
		if evs[i].kind == EV_SUBMITTED do break
		if evs[i].kind != EV_ANSWERED do continue
		a := json_begin()
		json_str(&a, "question", answered_question(evs, i, fold_input_for_task(task, true)))
		json_str(&a, "note", jsonx.extract_string(evs[i].payload_json, "note", "", true, context.temp_allocator))
		json_str(&a, "by", evs[i].actor_kind)
		json_raw(&o, "answer", json_end(&a))
		break
	}

	proto := json_begin()
	json_int(&proto, "heartbeat_ttl_seconds", LEASE_TTL_SECONDS)
	json_int(&proto, "hard_cap_seconds", LEASE_HARD_CAP_SECONDS)
	json_raw(&proto, "verbs", `["lease next","lease heartbeat","lease submit","lease handoff","lease block","verify","review post","task fetch","task comment"]`)
	json_raw(&proto, "rules", protocol_rules_json())
	json_raw(&o, "protocol", json_end(&proto))
	return cap_pack_json_field_safe(json_end(&o), string(task.task_id))
}

PACK_MAX_BYTES :: 32 * 1024

// cap_pack_json_field_safe applies the field-safe 32 KiB cap to a pack JSON object,
// dropping in order: 1. resolved input bodies -> 2. previous_attempt.verify ->
// 3. previous_attempt.handoff.summary (replaced with ham-ctl task fetch pointers),
// while preserving brief, dead_ends, and open findings intact.
cap_pack_json_field_safe :: proc(pack_json: string, task_id: string, max_bytes: int = PACK_MAX_BYTES) -> string {
	if len(pack_json) <= max_bytes || !strings.has_prefix(strings.trim_space(pack_json), "{") {
		return pack_json
	}
	cur := pack_json
	// Step 1: drop resolved input bodies, replacing with ham-ctl task fetch pointers
	top_members := jsonx_top_level_members(cur)
	if inputs_raw, has_inputs := top_members["inputs"]; has_inputs && strings.has_prefix(strings.trim_space(inputs_raw), "[") {
		items := jsonx_top_level_array_items(inputs_raw)
		if len(items) > 0 {
			ib := strings.builder_make(context.temp_allocator)
			strings.write_byte(&ib, '[')
			for it, idx in items {
				if idx > 0 do strings.write_byte(&ib, ',')
				ref := jsonx.extract_string(it, "ref", "input", true, context.temp_allocator)
				resolved := jsonx.extract_bool(it, "resolved", true, true)
				io := json_begin()
				json_str(&io, "ref", ref)
				json_bool(&io, "resolved", resolved)
				json_bool(&io, "omitted", true)
				json_str(&io, "fetch", fmt.tprintf("ham-ctl task fetch %s %s", task_id, ref))
				strings.write_string(&ib, json_end(&io))
			}
			strings.write_byte(&ib, ']')
			cur = replace_top_level_member_raw(cur, "inputs", strings.to_string(ib))
		}
	}
	if len(cur) <= max_bytes do return cur

	// Step 2: drop previous_attempt.verify body, replacing with ham-ctl task fetch pointer
	if prev_raw, has_prev := jsonx.extract_raw_object(cur, "previous_attempt", true, context.temp_allocator); has_prev && strings.has_prefix(strings.trim_space(prev_raw), "{") {
		prev_att := jsonx.extract_int(prev_raw, "attempt_no", jsonx.extract_int(prev_raw, "attempt", 1, true), true)
		vo := json_begin()
		json_bool(&vo, "omitted", true)
		json_str(&vo, "fetch", fmt.tprintf("ham-ctl task fetch %s facet:%s:%d:verify", task_id, task_id, prev_att))
		new_prev := replace_top_level_member_raw(prev_raw, "verify", json_end(&vo))
		cur = replace_top_level_member_raw(cur, "previous_attempt", new_prev)
	}
	if len(cur) <= max_bytes do return cur

	// Step 3: drop previous_attempt.handoff.summary while keeping dead_ends intact
	if prev_raw, has_prev := jsonx.extract_raw_object(cur, "previous_attempt", true, context.temp_allocator); has_prev && strings.has_prefix(strings.trim_space(prev_raw), "{") {
		prev_att := jsonx.extract_int(prev_raw, "attempt_no", jsonx.extract_int(prev_raw, "attempt", 1, true), true)
		if ho_raw, has_ho := jsonx.extract_raw_object(prev_raw, "handoff", true, context.temp_allocator); has_ho && strings.has_prefix(strings.trim_space(ho_raw), "{") {
			pointer := fmt.tprintf("(omitted for 8k-token cap — run: ham-ctl task fetch %s facet:%s:%d:handoff)", task_id, task_id, prev_att)
			pb := strings.builder_make(context.temp_allocator)
			strings.write_byte(&pb, '"')
			contracts.write_json_string(&pb, pointer)
			strings.write_byte(&pb, '"')
			new_ho := replace_top_level_member_raw(ho_raw, "summary", strings.to_string(pb))
			new_prev := replace_top_level_member_raw(prev_raw, "handoff", new_ho)
			cur = replace_top_level_member_raw(cur, "previous_attempt", new_prev)
		}
	}
	return cur
}

@(private = "file")
replace_top_level_member_raw :: proc(obj_json, target_key, new_raw_val: string) -> string {
	o := json_begin()
	replaced := false
	for key, raw in jsonx_top_level_members(obj_json) {
		if key == target_key {
			json_raw(&o, key, new_raw_val)
			replaced = true
		} else {
			json_raw(&o, key, raw)
		}
	}
	if !replaced {
		json_raw(&o, target_key, new_raw_val)
	}
	return json_end(&o)
}

@(private = "file")
protocol_rules_json :: proc() -> string {
	return `["1. Read TASK.md first; it is your authoritative lease context pack. When it names a Workdir, cd there and do ALL work and commits in it (your own branch); the hub merges it when the task is done.","2. Confirm or inspect your lease with: ham-ctl lease next","3. Send a heartbeat every <15m during long work: ham-ctl lease heartbeat --note \"<progress>\"","4. Run verification at the exact commit you will submit: ham-ctl verify","5. Submit completed work on a clean working tree: ham-ctl lease submit --summary \"<summary>\"","6. Hand off unfinished work for a fresh context window: ham-ctl lease handoff --summary \"<summary>\" --next-steps \"<steps>\"","7. Block when waiting on a human or external dependency: ham-ctl lease block --kind human --reason \"<question>\"","8. Reviewers post verdicts with: ham-ctl review post --verdict approve|request_changes [--findings-file <json>]","9. Fetch omitted or referenced context on demand: ham-ctl task fetch <task_id> <ref>","10. On 409 lease_lost, stop immediately; the hub will re-wake you with a fresh pack if needed."]`
}

// resolve_brief_inputs_json resolves each ref in `brief.inputs` into a JSON array:
// `[{"ref":"...","resolved":true,"data":{...}}, ...]`.
@(private = "file")
resolve_brief_inputs_json :: proc(svc: ^Service, task: domain.Task) -> string {
	refs := jsonx.extract_string_array(task.brief_json, "inputs", true, context.temp_allocator)
	if len(refs) == 0 do return "[]"
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	written := 0
	for r in refs {
		ref := strings.trim_space(r)
		if ref == "" do continue
		if written > 0 do strings.write_byte(&b, ',')
		item := json_begin()
		json_str(&item, "ref", ref)
		if body, ok, _ := fetch_ref(svc, task, ref); ok {
			json_bool(&item, "resolved", true)
			json_raw(&item, "data", body)
		} else {
			json_bool(&item, "resolved", false)
			json_raw(&item, "data", "null")
		}
		strings.write_string(&b, json_end(&item))
		written += 1
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

// previous_attempt_and_vcs_json returns:
// 1. previous_attempt JSON (`{attempt_no, outcome, holder_instance_id, handoff, vcs, verify, output, artifacts, runtime, last_heartbeat_note, note}` or `"null"`),
// 2. where_you_are JSON (the `vcs` facet of the previous/current attempt, or `"null"`),
// 3. the previous attempt's outcome string.
@(private = "file")
previous_attempt_and_vcs_json :: proc(svc: ^Service, task: domain.Task, lease: domain.Task_Lease, handoff_continuation: bool, evs: []domain.Task_Event) -> (string, string, string) {
	attempts, err := iface.taskchain_list_attempts_by_task(svc.repo, task.task_id, task.owner_user_id)
	if err.code != .None do return "null", "null", ""
	prev := domain.Task_Attempt{}
	found := false
	for a in attempts {
		if a.attempt_no > lease.attempt_no do continue
		// the current (open) attempt is "previous" only when it was handed off or under review
		if a.attempt_no == lease.attempt_no && lease.kind == domain.LEASE_KIND_WORK && !handoff_continuation do continue
		if !found || a.attempt_no > prev.attempt_no { prev = a; found = true }
	}
	if !found do return "null", "null", ""
	o := json_begin()
	json_int(&o, "attempt_no", i64(prev.attempt_no))
	json_str(&o, "outcome", prev.outcome)
	json_str(&o, "holder_instance_id", prev.holder_instance_id)
	handoff := "null"
	vcs := "null"
	verify := "null"
	output := "null"
	artifacts := "null"
	runtime_facet := "null"
	if facets, ferr := iface.taskchain_list_facets_by_task(svc.repo, task.task_id, task.owner_user_id); ferr.code == .None {
		for f in facets {
			if f.attempt_no != prev.attempt_no || !strings.has_prefix(strings.trim_space(f.body_json), "{") do continue
			switch f.kind {
			case FACET_HANDOFF:   handoff = f.body_json
			case FACET_VCS:       vcs = f.body_json
			case FACET_VERIFY:    verify = f.body_json
			case FACET_OUTPUT:    output = f.body_json
			case FACET_ARTIFACTS: artifacts = f.body_json
			case FACET_RUNTIME:   runtime_facet = f.body_json
			}
		}
	}
	last_note := last_heartbeat_note_for_attempt(evs, prev.attempt_no)
	json_raw(&o, "handoff", handoff)
	json_raw(&o, "vcs", vcs)
	json_raw(&o, "verify", verify)
	json_raw(&o, "output", output)
	json_raw(&o, "artifacts", artifacts)
	json_raw(&o, "runtime", runtime_facet)
	json_str(&o, "last_heartbeat_note", last_note)
	json_str(&o, "note", last_note)
	return json_end(&o), vcs, prev.outcome
}

@(private = "file")
last_heartbeat_note_for_attempt :: proc(evs: []domain.Task_Event, target_attempt: int) -> string {
	cur_attempt := 0
	last_rel := Last_Release.None
	note := ""
	for e in evs {
		switch e.kind {
		case EV_LEASE_GRANTED:
			kind := jsonx.extract_string(e.payload_json, "kind", domain.LEASE_KIND_WORK, true, context.temp_allocator)
			if kind == domain.LEASE_KIND_WORK {
				if last_rel != .Handoff do cur_attempt += 1
				last_rel = .None
			}
		case EV_HANDOFF:
			last_rel = .Handoff
		case EV_SUBMITTED:
			last_rel = .Submitted
		case EV_BLOCKED:
			last_rel = .Blocked
		case EV_LEASE_EXPIRED:
			kind := jsonx.extract_string(e.payload_json, "kind", domain.LEASE_KIND_WORK, true, context.temp_allocator)
			if kind == domain.LEASE_KIND_WORK do last_rel = .Expired
		case EV_HEARTBEAT:
			if cur_attempt == target_attempt {
				if n := strings.trim_space(jsonx.extract_string(e.payload_json, "note", "", true, context.temp_allocator)); n != "" {
					note = n
				}
			}
		}
	}
	return note
}

@(private = "file")
open_findings_json :: proc(svc: ^Service, task: domain.Task, lease: domain.Task_Lease) -> string {
	reviews, err := iface.taskchain_list_reviews_by_task(svc.repo, task.task_id, task.owner_user_id)
	if err.code != .None || len(reviews) == 0 do return "[]"
	target_attempt := lease.attempt_no - 1
	if lease.kind == domain.LEASE_KIND_REVIEW do target_attempt = lease.attempt_no
	if target_attempt < 1 do return "[]"
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	written := 0
	for r in reviews {
		if r.attempt_no != target_attempt || r.verdict != "request_changes" do continue
		items := jsonx_top_level_array_items(r.findings_json)
		for it in items {
			item := strings.trim_space(it)
			if !strings.has_prefix(item, "{") || !strings.has_suffix(item, "}") do continue
			if written > 0 do strings.write_byte(&b, ',')
			strings.write_string(&b, item)
			written += 1
		}
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

@(private = "file")
pack_why :: proc(view: Task_View, lease: domain.Task_Lease, prev_outcome: string) -> string {
	if lease.kind == domain.LEASE_KIND_REVIEW do return "review"
	#partial switch view.last_release {
	case .Expired:
		if strings.has_prefix(prev_outcome, "expired:") do return prev_outcome
		if prev_outcome == "expired" do return "expired"
		return "retry_after_expiry"
	case .Changes_Requested: return "changes_requested"
	case .Handoff: return "handoff"
	case .Reopened: return "reopened"
	case .User_Stopped: return "user_stopped"
	case .Released_Noncounting: return "released"
	case .Blocked: return "answered"
	}
	return "first_grant"
}

// ---- Mechanical Chain Summary (plan §3b / §4c) ----------------------------------------

// build_mechanical_chain_summary builds the <=60-line mechanical summary from
// completed tasks (with vcs.head and 1-line handoff summaries), active/ready/blocked
// tasks, and dead_ends preserved across all attempts, while preserving any
// coordinator-curated summary lines (`coordinator_lines`). Returns (summary_body, overflowed).
build_mechanical_chain_summary :: proc(svc: ^Service, chain: domain.Task_Chain, coordinator_lines: []string = nil) -> (string, bool) {
	tasks, terr := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if terr.code != .None do return "", false

	done_lines := make([dynamic]string, context.temp_allocator)
	open_lines := make([dynamic]string, context.temp_allocator)
	dead_end_lines := make([dynamic]string, context.temp_allocator)

	for t in tasks {
		facets, ferr := iface.taskchain_list_facets_by_task(svc.repo, t.task_id, t.owner_user_id)
		latest_summary := ""
		latest_attempt := -1
		latest_head := ""
		latest_vcs_attempt := -1
		if ferr.code == .None {
			for f in facets {
				if f.kind == FACET_VCS && f.attempt_no >= latest_vcs_attempt {
					if h := first_line_trimmed(jsonx.extract_string(f.body_json, "head", "", true, context.temp_allocator)); h != "" {
						latest_head = h
						latest_vcs_attempt = f.attempt_no
					}
				}
				if f.kind != FACET_HANDOFF do continue
				if f.attempt_no >= latest_attempt {
					if s := first_line_trimmed(jsonx.extract_string(f.body_json, "summary", "", true, context.temp_allocator)); s != "" {
						latest_summary = s
						latest_attempt = f.attempt_no
					}
				}
				// Collect dead_ends from every attempt's handoff facet
				de_arr := jsonx.extract_string_array(f.body_json, "dead_ends", true, context.temp_allocator)
				for de in de_arr {
					clean := first_line_trimmed(de)
					if clean != "" {
						append(&dead_end_lines, fmt.tprintf("- [%s#%d] %s", t.task_id, f.attempt_no, clean))
					}
				}
				if len(de_arr) == 0 {
					if de_str := first_line_trimmed(jsonx.extract_string(f.body_json, "dead_ends", "", true, context.temp_allocator)); de_str != "" {
						append(&dead_end_lines, fmt.tprintf("- [%s#%d] %s", t.task_id, f.attempt_no, de_str))
					}
				}
			}
		}
		switch t.state {
		case .Done:
			head_suffix := fmt.tprintf(" @%s", latest_head) if latest_head != "" else ""
			if latest_summary != "" {
				append(&done_lines, fmt.tprintf("- [x] %s (%s)%s: %s", t.task_id, first_line_trimmed(t.title), head_suffix, latest_summary))
			} else {
				append(&done_lines, fmt.tprintf("- [x] %s (%s)%s", t.task_id, first_line_trimmed(t.title), head_suffix))
			}
		case .Cancelled:
			append(&done_lines, fmt.tprintf("- [-] %s (%s): cancelled", t.task_id, first_line_trimmed(t.title)))
		case .In_Progress, .In_Review, .Ready, .Backlog:
			badge := domain.task_state_string(t.state)
			if t.blocked_on_json != "" do badge = "blocked"
			if latest_summary != "" {
				append(&open_lines, fmt.tprintf("- [ ] %s [%s] (%s): %s", t.task_id, badge, first_line_trimmed(t.title), latest_summary))
			} else {
				append(&open_lines, fmt.tprintf("- [ ] %s [%s] (%s)", t.task_id, badge, first_line_trimmed(t.title)))
			}
		}
	}

	// Dead ends are NEVER dropped when trimming to 60 lines. If dead_ends alone
	// exceed 60 lines, overflow=true so the caller emits EV_SUMMARY_OVERFLOW.
	overflow := false
	if len(dead_end_lines) + 2 > CHAIN_SUMMARY_MAX_LINES {
		overflow = true
	}

	out := make([dynamic]string, context.temp_allocator)
	append(&out, fmt.tprintf("# Chain %s: %s", chain.chain_id, first_line_trimmed(chain.title)))

	// Reserve budget for dead_ends section first
	reserved_for_dead_ends := 0
	if len(dead_end_lines) > 0 {
		reserved_for_dead_ends = min(len(dead_end_lines) + 1, CHAIN_SUMMARY_MAX_LINES - 1)
	}
	if len(coordinator_lines) > 0 {
		max_coord := CHAIN_SUMMARY_MAX_LINES - len(out) - reserved_for_dead_ends
		for cline in coordinator_lines {
			if max_coord <= 0 do break
			append(&out, cline)
			max_coord -= 1
		}
	}
	task_budget := CHAIN_SUMMARY_MAX_LINES - len(out) - reserved_for_dead_ends
	if task_budget < 0 do task_budget = 0

	// Prefer keeping open tasks visible + most recent completed tasks within budget
	if len(open_lines) > 0 && task_budget > 1 {
		append(&out, "## Active & Pending")
		task_budget -= 1
		for line in open_lines {
			if task_budget <= 0 do break
			append(&out, line)
			task_budget -= 1
		}
	}
	if len(done_lines) > 0 && task_budget > 1 {
		append(&out, "## Completed")
		task_budget -= 1
		start_idx := 0
		if len(done_lines) > task_budget do start_idx = len(done_lines) - task_budget
		for line in done_lines[start_idx:] {
			if task_budget <= 0 do break
			append(&out, line)
			task_budget -= 1
		}
	}
	if len(dead_end_lines) > 0 && len(out) < CHAIN_SUMMARY_MAX_LINES {
		append(&out, "## Dead Ends")
		for line in dead_end_lines {
			if len(out) >= CHAIN_SUMMARY_MAX_LINES {
				overflow = true
				break
			}
			append(&out, line)
		}
	}
	return strings.join(out[:], "\n", context.temp_allocator), overflow
}

@(private = "file")
extract_coordinator_summary_lines :: proc(svc: ^Service, chain: domain.Task_Chain, prev_body: string) -> []string {
	if strings.trim_space(prev_body) == "" do return nil
	tasks, _ := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	lines := strings.split_lines(prev_body, context.temp_allocator)
	coord := make([dynamic]string, context.temp_allocator)
	mech_header_prefix := fmt.tprintf("# Chain %s:", chain.chain_id)
	for line in lines {
		trimmed := strings.trim_space(line)
		if trimmed == "" do continue
		if strings.has_prefix(trimmed, mech_header_prefix) do continue
		if trimmed == "## Active & Pending" || trimmed == "## Completed" || trimmed == "## Dead Ends" do continue
		is_mech_bullet := false
		if strings.has_prefix(trimmed, "- [") {
			for t in tasks {
				if string(t.task_id) != "" && strings.contains(trimmed, string(t.task_id)) {
					is_mech_bullet = true
					break
				}
			}
		}
		if !is_mech_bullet {
			append(&coord, line)
		}
	}
	return coord[:]
}

rebuild_chain_summary_in_uow :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain) {
	if svc == nil || svc.repo == nil do return
	prev_ver := 0
	var_coord_lines: []string = nil
	if prev, pok, _ := iface.taskchain_get_chain_summary(svc.repo, chain.chain_id, chain.owner_user_id); pok {
		prev_ver = prev.version
		var_coord_lines = extract_coordinator_summary_lines(svc, chain, prev.body)
	}
	body, overflow := build_mechanical_chain_summary(svc, chain, var_coord_lines)
	lines := strings.split_lines(body, context.temp_allocator) if body != "" else nil
	now := platform.clock_now(svc.clock)
	_, _, _ = iface.taskchain_save_chain_summary(svc.repo, domain.Chain_Summary{
		chain_id      = chain.chain_id,
		owner_user_id = chain.owner_user_id,
		body          = body,
		line_count    = len(lines),
		version       = prev_ver + 1,
		updated_at    = now,
	})
	if u != nil {
		effect_publish_chain(u, chain.chain_id, chain.owner_user_id, "summary_updated")
	}
	if overflow {
		if tasks, terr := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id); terr.code == .None && len(tasks) > 0 {
			p := json_begin()
			json_int(&p, "max_lines", CHAIN_SUMMARY_MAX_LINES)
			_, _, _ = append_event(svc.repo, svc.clock, tasks[len(tasks)-1], hub_actor(), EV_SUMMARY_OVERFLOW, json_end(&p))
		}
		if u != nil {
			effect_notify_coordinator(svc, u, chain.chain_id, chain.owner_user_id, "summary_overflow", fmt.tprintf("[taskv2] summary_overflow: chain %s dead_ends exceed %d lines; run `ham-ctl task-chain summary set` to compact", chain.chain_id, CHAIN_SUMMARY_MAX_LINES))
		}
	}
}

// chain_summary_set allows the coordinator or chain owner to set the chain
// summary (capped at 60 lines).
chain_summary_set :: proc(svc: ^Service, auth: contracts.Auth_Context, chain_id_in: domain.Task_Chain_ID, body_in: string) -> (domain.Chain_Summary, bool, domain.Domain_Error) {
	chain_id := chain_id_in
	if auth.kind == .Instance_Token {
		inst, iok, ierr := instance_from_auth(svc, auth)
		if !iok do return {}, false, ierr
		if chain_id == "" do chain_id = domain.Task_Chain_ID(inst.chain_id)
		chain, cok, _ := iface.taskchain_get_chain(svc.repo, chain_id)
		if !cok || chain.owner_user_id != inst.owner_user_id do return {}, false, domain.domain_error(.Not_Found, "task chain not found")
		if !is_coordinator(svc, chain, inst.agent_instance_id) {
			return {}, false, domain.domain_error(.Forbidden, "only the chain coordinator or owner can set the chain summary")
		}
	} else if auth.kind == .User_Token || auth.kind == .Trusted_Proxy {
		if chain_id == "" do return {}, false, domain.domain_error(.Validation_Failed, "chain_id is required")
		chain, cok, _ := iface.taskchain_get_chain(svc.repo, chain_id)
		if !cok || string(chain.owner_user_id) != auth.user_id do return {}, false, domain.domain_error(.Not_Found, "task chain not found")
	} else {
		return {}, false, domain.domain_error(.Forbidden, "authentication required")
	}

	body := strings.trim_right_space(body_in)
	lines := strings.split_lines(body, context.temp_allocator) if body != "" else nil
	if len(lines) > CHAIN_SUMMARY_MAX_LINES {
		return {}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("chain summary must be at most %d lines (got %d)", CHAIN_SUMMARY_MAX_LINES, len(lines)))
	}
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
	chain, cok, _ := iface.taskchain_get_chain(svc.repo, chain_id)
	if !cok {
		_, _ = end_uow(svc, &u, false)
		return {}, false, domain.domain_error(.Not_Found, "task chain not found")
	}
	prev_ver := 0
	if prev, pok, _ := iface.taskchain_get_chain_summary(svc.repo, chain.chain_id, chain.owner_user_id); pok {
		prev_ver = prev.version
	}
	now := platform.clock_now(svc.clock)
	saved, sok, serr := iface.taskchain_save_chain_summary(svc.repo, domain.Chain_Summary{
		chain_id      = chain.chain_id,
		owner_user_id = chain.owner_user_id,
		body          = body,
		line_count    = len(lines),
		version       = prev_ver + 1,
		updated_at    = now,
	})
	if sok do effect_publish_chain(&u, chain.chain_id, chain.owner_user_id, "summary_updated")
	_, cerr := end_uow(svc, &u, sok)
	if !sok do return {}, false, serr
	if cerr.code != .None do return {}, false, cerr
	return saved, true, domain.Domain_Error{}
}

// answered_question: what the `answered` event at evs[at] answered — the
// blocked_on that was active just before it, read from the fold of the events
// before it (so system blocks the fold raises itself — budget, oscillation,
// merge_conflict — are covered, and an older, already-answered question never
// is). Pure; temp-allocated.
answered_question :: proc(evs: []domain.Task_Event, at: int, input: Fold_Input) -> string {
	if at <= 0 || at >= len(evs) do return ""
	blocked := fold_task(evs[:at], input).blocked_on_json
	if blocked == "" do return ""
	reason := jsonx.extract_string(blocked, "reason", "", true, context.temp_allocator)
	switch reason {
	case "merge_conflict":
		for j := at - 1; j >= 0; j -= 1 {
			if evs[j].kind != EV_MERGE_CONFLICT do continue
			if files := jsonx.extract_string(evs[j].payload_json, "files", "", true, context.temp_allocator); files != "" {
				return fmt.tprintf("Your finished branch did not merge (conflicting files: %s).", files)
			}
			break
		}
		return "Your finished branch did not merge."
	case "budget_exhausted": return "The task ran out of attempts."
	case "oscillation":      return "The task went through too many review rounds."
	case "blocked":          return ""
	}
	return reason
}
