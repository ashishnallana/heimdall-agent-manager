package taskv2

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import jsonx "odin_test:lib/jsonx"

// M2 verbs (plan §2.5/§3): lease.submit, lease.handoff, lease.block,
// review.post (agent) + user review, task.fetch, reopen/answer (human), and
// the hub-written verify facet. Each verb is ONE unit of work: validate →
// facets → event(s) → refold → gate → match → commit → effects.

// ---- shared ---------------------------------------------------------------------------

Work_Lease_Caller :: struct {
	inst:  domain.Agent_Instance,
	lease: domain.Task_Lease,
	task:  domain.Task,
	chain: domain.Task_Chain,
}

// work_lease_caller resolves the calling instance's live WORK lease (and names
// the lease when `lease_id` is given). Anything else is 409 lease_lost.
@(private = "file")
work_lease_caller :: proc(svc: ^Service, auth: contracts.Auth_Context, lease_id: string) -> (Work_Lease_Caller, bool, domain.Domain_Error) {
	inst, ok, err := instance_from_auth(svc, auth)
	if !ok do return {}, false, err
	lease, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, inst.agent_instance_id)
	if !held || lease.kind != domain.LEASE_KIND_WORK do return {}, false, lease_lost_error()
	if strings.trim_space(lease_id) != "" && lease_id != lease.lease_id do return {}, false, lease_lost_error()
	task, tok, terr := iface.taskchain_get_task(svc.repo, lease.task_id)
	if !tok do return {}, false, terr
	chain, cok, cerr := iface.taskchain_get_chain(svc.repo, task.chain_id)
	if !cok do return {}, false, cerr
	return Work_Lease_Caller{inst = inst, lease = lease, task = task, chain = chain}, true, domain.Domain_Error{}
}

// ---- lease.submit ---------------------------------------------------------------------

Submit_Input :: struct {
	lease_id:     string,
	summary:      string,
	handoff_json: string, // optional object: next_steps, decisions, … (verbatim)
	output_json:  string, // optional object: the brief's output contract
	vcs_json:     string, // bridge .Local enrichment: {head, dirty, files:[…]}
	verify:       string, // "" | "none"
}

Submit_Result :: struct {
	task:    domain.Task,
	outcome: string, // in_review | done
}

// lease_submit (plan §2.5): hard rejects = summary empty · verify gate
// unsatisfied · output missing when the brief requires one; everything else is
// truncated with truncated:true. Releases the lease and stops the holder.
lease_submit :: proc(svc: ^Service, auth: contracts.Auth_Context, input: Submit_Input) -> (Submit_Result, bool, domain.Domain_Error) {
	if strings.trim_space(input.summary) == "" do return {}, false, domain.domain_error(.Validation_Failed, "summary is required")
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
	c, ok, err := work_lease_caller(svc, auth, input.lease_id)
	if !ok { _, _ = end_uow(svc, &u, false); return {}, false, err }
	// output contract: brief.output present → an output object is required
	if _, has_output_contract := jsonx.extract_raw_object(c.task.brief_json, "output", true, context.temp_allocator); has_output_contract {
		if !strings.has_prefix(strings.trim_space(input.output_json), "{") {
			_, _ = end_uow(svc, &u, false)
			return {}, false, domain.domain_error(.Validation_Failed, "this brief declares an output contract; submit must carry `output`")
		}
	}
	// verify gate (plan §4d)
	if gerr := verify_gate(svc, c.task, c.lease.attempt_no, input); gerr.code != .None {
		_, _ = end_uow(svc, &u, false)
		return {}, false, gerr
	}
	actor := Actor{kind = ACTOR_AGENT, id = c.inst.agent_instance_id}
	if !write_submit_facets(svc, &u, c.task, c.lease.attempt_no, input) {
		_, _ = end_uow(svc, &u, false)
		return {}, false, domain.domain_error(.Internal_Error, "failed to store the submission facets")
	}
	p := json_begin()
	json_str(&p, "lease_id", c.lease.lease_id)
	json_int(&p, "attempt_no", i64(c.lease.attempt_no))
	if input.verify == "none" do json_str(&p, "verify", "none")
	task, rok, rerr := release_in_uow(svc, &u, c.lease, actor, EV_SUBMITTED, json_end(&p), "submitted")
	if rok do rok, rerr = after_chain_change(svc, &u, c.task.chain_id, c.task.owner_user_id, .Lease_Released)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return {}, false, rerr
	if cerr.code != .None do return {}, false, cerr
	fresh, _, _ := iface.taskchain_get_task(svc.repo, task.task_id)
	return Submit_Result{task = fresh, outcome = "done" if fresh.state == .Done else "in_review"}, true, domain.Domain_Error{}
}

@(private = "file")
write_submit_facets :: proc(svc: ^Service, u: ^Uow, task: domain.Task, attempt_no: int, input: Submit_Input) -> bool {
	if ok, _ := save_facet_verbatim(svc, task, attempt_no, FACET_HANDOFF, handoff_body_json(input.summary, input.handoff_json), FACET_WRITER_AGENT); !ok do return false
	if strings.has_prefix(strings.trim_space(input.vcs_json), "{") {
		if ok, _ := save_facet_verbatim(svc, task, attempt_no, FACET_VCS, input.vcs_json, FACET_WRITER_BRIDGE); !ok do return false
	}
	if strings.has_prefix(strings.trim_space(input.output_json), "{") {
		if ok, _ := save_facet_verbatim(svc, task, attempt_no, FACET_OUTPUT, input.output_json, FACET_WRITER_AGENT); !ok do return false
	}
	return true
}

// verify_gate (plan §4d): outcome=submitted requires a `verify` facet on this
// attempt with exit_code==0 ∧ head_at_start==head_at_end==submit.head ∧
// dirty==false. `dirty` may be null when the chain has no VCS directory; the
// facet must then postdate the attempt's last handoff/note. verify:"none" is
// allowed only when the brief declares an output contract (flag stored).
@(private = "file")
verify_gate :: proc(svc: ^Service, task: domain.Task, attempt_no: int, input: Submit_Input) -> domain.Domain_Error {
	if input.verify == "none" {
		if _, has_output := jsonx.extract_raw_object(task.brief_json, "output", true, context.temp_allocator); has_output do return domain.Domain_Error{}
		return domain.domain_error(.Conflict, "verify:none is allowed only when the brief declares an output contract", `{"code":"verify_required"}`)
	}
	f, ok := get_facet(svc, task, attempt_no, FACET_VERIFY)
	if !ok do return domain.domain_error(.Conflict, "no verify result on this attempt: run `ham-ctl verify` (brief.verify) at the head you are submitting", `{"code":"verify_required"}`)
	if n, nok := jsonx.extract_int_found(f.body_json, "exit_code", true); !nok || n != 0 {
		return domain.domain_error(.Conflict, "last verify run did not pass (exit_code != 0)", `{"code":"verify_failed"}`)
	}
	head_start := jsonx.extract_string(f.body_json, "head_at_start", "", true, context.temp_allocator)
	head_end := jsonx.extract_string(f.body_json, "head_at_end", "", true, context.temp_allocator)
	submit_head := ""
	if strings.has_prefix(strings.trim_space(input.vcs_json), "{") do submit_head = jsonx.extract_string(input.vcs_json, "head", "", true, context.temp_allocator)
	if head_start != head_end || (submit_head != "" && head_end != submit_head) {
		return domain.domain_error(.Conflict, "verify ran at a different head than the one being submitted: re-run `ham-ctl verify`", `{"code":"verify_stale"}`)
	}
	if dirty, dok := jsonx.extract_bool_literal(f.body_json, "dirty", true); dok {
		if dirty do return domain.domain_error(.Conflict, "verify ran on a dirty tree: commit, then re-run `ham-ctl verify`", `{"code":"verify_dirty"}`)
	} else {
		// no VCS truth: the verify must postdate the attempt's last handoff/note
		if h, hok := get_facet(svc, task, attempt_no, FACET_HANDOFF); hok && h.written_at > f.written_at {
			return domain.domain_error(.Conflict, "verify predates the latest handoff on this attempt: re-run `ham-ctl verify`", `{"code":"verify_stale"}`)
		}
		if last_note := last_heartbeat_note_at(svc, task, attempt_no); last_note != "" && last_note > f.written_at {
			return domain.domain_error(.Conflict, "verify predates your latest progress note: re-run `ham-ctl verify`", `{"code":"verify_stale"}`)
		}
	}
	return domain.Domain_Error{}
}

@(private = "file")
last_heartbeat_note_at :: proc(svc: ^Service, task: domain.Task, attempt_no: int) -> string {
	evs, err := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	if err.code != .None do return ""
	latest := i64(0)
	for e in evs do if e.kind == EV_HEARTBEAT && e.ts_ms > latest do latest = e.ts_ms
	if latest == 0 do return ""
	return platform.format_rfc3339_utc({_nsec = latest * 1_000_000})
}

// ---- lease.handoff ---------------------------------------------------------------------

Handoff_Input :: struct {
	lease_id:     string,
	summary:      string,
	handoff_json: string,
	vcs_json:     string,
}

// lease_handoff: the holder gives the attempt up for a fresh holder (same
// attempt number; the pack carries the handoff). Summary required.
lease_handoff :: proc(svc: ^Service, auth: contracts.Auth_Context, input: Handoff_Input) -> (domain.Task, bool, domain.Domain_Error) {
	if strings.trim_space(input.summary) == "" do return {}, false, domain.domain_error(.Validation_Failed, "summary is required")
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
	c, ok, err := work_lease_caller(svc, auth, input.lease_id)
	if !ok { _, _ = end_uow(svc, &u, false); return {}, false, err }
	if fok, _ := save_facet_verbatim(svc, c.task, c.lease.attempt_no, FACET_HANDOFF, handoff_body_json(input.summary, input.handoff_json), FACET_WRITER_AGENT); !fok {
		_, _ = end_uow(svc, &u, false)
		return {}, false, domain.domain_error(.Internal_Error, "failed to store the handoff")
	}
	if strings.has_prefix(strings.trim_space(input.vcs_json), "{") {
		_, _ = save_facet_verbatim(svc, c.task, c.lease.attempt_no, FACET_VCS, input.vcs_json, FACET_WRITER_BRIDGE)
	}
	p := json_begin()
	json_str(&p, "lease_id", c.lease.lease_id)
	json_int(&p, "attempt_no", i64(c.lease.attempt_no))
	task, rok, rerr := release_in_uow(svc, &u, c.lease, Actor{kind = ACTOR_AGENT, id = c.inst.agent_instance_id}, EV_HANDOFF, json_end(&p), "handoff")
	if rok do rok, rerr = after_chain_change(svc, &u, c.task.chain_id, c.task.owner_user_id, .Lease_Released)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return {}, false, rerr
	if cerr.code != .None do return {}, false, cerr
	fresh, _, _ := iface.taskchain_get_task(svc.repo, task.task_id)
	return fresh, true, domain.Domain_Error{}
}

// ---- lease.block -----------------------------------------------------------------------

Block_Input :: struct {
	lease_id:        string,
	waiting_on_json: string, // {kind: human|task|external|…, ref?, reason}
	summary:         string, // optional progress note stored as the handoff facet
}

lease_block :: proc(svc: ^Service, auth: contracts.Auth_Context, input: Block_Input) -> (domain.Task, bool, domain.Domain_Error) {
	waiting := strings.trim_space(input.waiting_on_json)
	if !strings.has_prefix(waiting, "{") do return {}, false, domain.domain_error(.Validation_Failed, "waiting_on {kind, reason} is required")
	if jsonx.extract_string(waiting, "kind", "", true, context.temp_allocator) == "" do return {}, false, domain.domain_error(.Validation_Failed, "waiting_on.kind is required")
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
	c, ok, err := work_lease_caller(svc, auth, input.lease_id)
	if !ok { _, _ = end_uow(svc, &u, false); return {}, false, err }
	if strings.trim_space(input.summary) != "" {
		_, _ = save_facet_verbatim(svc, c.task, c.lease.attempt_no, FACET_HANDOFF, handoff_body_json(input.summary, ""), FACET_WRITER_AGENT)
	}
	p := json_begin()
	json_str(&p, "lease_id", c.lease.lease_id)
	json_int(&p, "attempt_no", i64(c.lease.attempt_no))
	json_raw(&p, "waiting_on", waiting_with_since(waiting, now_ms(svc.clock)))
	task, rok, rerr := release_in_uow(svc, &u, c.lease, Actor{kind = ACTOR_AGENT, id = c.inst.agent_instance_id}, EV_BLOCKED, json_end(&p), "blocked")
	if rok do rok, rerr = after_chain_change(svc, &u, c.task.chain_id, c.task.owner_user_id, .Lease_Released)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return {}, false, rerr
	if cerr.code != .None do return {}, false, cerr
	fresh, _, _ := iface.taskchain_get_task(svc.repo, task.task_id)
	return fresh, true, domain.Domain_Error{}
}

@(private = "file")
waiting_with_since :: proc(waiting: string, since_ms: i64) -> string {
	if _, has := jsonx.extract_int_found(waiting, "since_ms", true); has do return waiting
	body := strings.trim_space(waiting)
	inner := strings.trim_space(body[1:len(body)-1])
	if inner == "" do return fmt.tprintf(`{{"since_ms":%d}}`, since_ms)
	return fmt.tprintf(`{{%s,"since_ms":%d}}`, inner, since_ms)
}

// ---- review.post (agent) ---------------------------------------------------------------

Review_Input :: struct {
	task_id:       string, // optional for agents (their review lease names it); required for users
	verdict:       string, // approve | request_changes
	findings_json: string, // array, verbatim (capped)
}

Review_Result :: struct {
	task: domain.Task,
	gate: Gate_Result,
}

// review_post: the review lease IS the offer — the holder posts a verdict,
// the lease is released, the gate is evaluated.
review_post :: proc(svc: ^Service, auth: contracts.Auth_Context, input: Review_Input) -> (Review_Result, bool, domain.Domain_Error) {
	if input.verdict != "approve" && input.verdict != "request_changes" do return {}, false, domain.domain_error(.Validation_Failed, "verdict must be approve or request_changes")
	inst, ok, err := instance_from_auth(svc, auth)
	if !ok do return {}, false, err
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
	lease, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, inst.agent_instance_id)
	if !held || lease.kind != domain.LEASE_KIND_REVIEW || (strings.trim_space(input.task_id) != "" && input.task_id != string(lease.task_id)) {
		_, _ = end_uow(svc, &u, false)
		return {}, false, lease_lost_error()
	}
	task, tok, terr := iface.taskchain_get_task(svc.repo, lease.task_id)
	if !tok { _, _ = end_uow(svc, &u, false); return {}, false, terr }
	chain, cok, cerr := iface.taskchain_get_chain(svc.repo, task.chain_id)
	if !cok { _, _ = end_uow(svc, &u, false); return {}, false, cerr }
	findings, _ := findings_json_capped(input.findings_json)
	now := platform.clock_now(svc.clock)
	review := domain.Task_Review{
		task_id = task.task_id, chain_id = task.chain_id, owner_user_id = task.owner_user_id, attempt_no = task.attempt_no,
		role = lease.review_role, reviewer_kind = "agent", reviewer_agent_id = inst.agent_id, reviewer_instance_id = inst.agent_instance_id,
		verdict = input.verdict, findings_json = findings, created_at = now,
	}
	if _, sok, serr := iface.taskchain_save_review(svc.repo, review); !sok { _, _ = end_uow(svc, &u, false); return {}, false, serr }
	// release the review lease (not an attempt; no budget)
	if deleted, _ := iface.taskchain_delete_lease(svc.repo, lease.lease_id); !deleted { _, _ = end_uow(svc, &u, false); return {}, false, lease_lost_error() }
	metric_lease_released(lease.kind)
	actor := Actor{kind = ACTOR_AGENT, id = inst.agent_instance_id}
	p := json_begin()
	json_int(&p, "attempt_no", i64(task.attempt_no))
	json_str(&p, "role", lease.review_role)
	json_str(&p, "verdict", input.verdict)
	json_str(&p, "reviewer", inst.agent_id)
	json_raw(&p, "findings", findings)
	refolded, _, rok, rerr := record_event(svc, &u, task, actor, EV_REVIEW_POSTED, json_end(&p))
	if !rok { _, _ = end_uow(svc, &u, false); return {}, false, rerr }
	mark_instance_idle(svc, inst.agent_instance_id, now)
	effect_stop(&u, inst.bridge_id, string(task.chain_id), inst.agent_instance_id)
	arm_idle_ttl(svc, inst.agent_instance_id, fleet_idle_ttl(svc, task.chain_id, task.owner_user_id, inst.agent_id), now)
	gate, gok, gerr := evaluate_gate_in_uow(svc, &u, chain, refolded, actor)
	if gok do gok, gerr = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Review_Posted)
	_, cerr2 := end_uow(svc, &u, gok)
	if !gok do return {}, false, gerr
	if cerr2.code != .None do return {}, false, cerr2
	fresh, _, _ := iface.taskchain_get_task(svc.repo, task.task_id)
	return Review_Result{task = fresh, gate = gate}, true, domain.Domain_Error{}
}

// user_review: the owner approves / requests changes on an in_review task
// (requires_user_approval, or simply as a human reviewer).
user_review :: proc(svc: ^Service, auth: contracts.Auth_Context, task_id: domain.Task_ID, input: Review_Input) -> (Review_Result, bool, domain.Domain_Error) {
	if input.verdict != "approve" && input.verdict != "request_changes" do return {}, false, domain.domain_error(.Validation_Failed, "verdict must be approve or request_changes")
	if auth.kind != .User_Token && auth.kind != .Trusted_Proxy do return {}, false, domain.domain_error(.Forbidden, "user token is required")
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
	task, tok, terr := iface.taskchain_get_task(svc.repo, task_id)
	if !tok || string(task.owner_user_id) != auth.user_id { _, _ = end_uow(svc, &u, false); return {}, false, domain.domain_error(.Not_Found, "task not found") }
	if task.state != .In_Review { _, _ = end_uow(svc, &u, false); return {}, false, domain.domain_error(.Conflict, "task is not awaiting review") }
	chain, cok, cerr := iface.taskchain_get_chain(svc.repo, task.chain_id)
	if !cok { _, _ = end_uow(svc, &u, false); return {}, false, cerr }
	findings, _ := findings_json_capped(input.findings_json)
	now := platform.clock_now(svc.clock)
	review := domain.Task_Review{task_id = task.task_id, chain_id = task.chain_id, owner_user_id = task.owner_user_id, attempt_no = task.attempt_no, role = "user", reviewer_kind = "user", verdict = input.verdict, findings_json = findings, created_at = now}
	if _, sok, serr := iface.taskchain_save_review(svc.repo, review); !sok { _, _ = end_uow(svc, &u, false); return {}, false, serr }
	actor := Actor{kind = ACTOR_USER, id = auth.user_id}
	p := json_begin()
	json_int(&p, "attempt_no", i64(task.attempt_no))
	json_str(&p, "role", "user")
	json_str(&p, "verdict", input.verdict)
	json_str(&p, "reviewer", "user")
	json_raw(&p, "findings", findings)
	refolded, _, rok, rerr := record_event(svc, &u, task, actor, EV_REVIEW_POSTED, json_end(&p))
	if !rok { _, _ = end_uow(svc, &u, false); return {}, false, rerr }
	gate, gok, gerr := evaluate_gate_in_uow(svc, &u, chain, refolded, actor)
	if gok do gok, gerr = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Review_Posted)
	_, cerr2 := end_uow(svc, &u, gok)
	if !gok do return {}, false, gerr
	if cerr2.code != .None do return {}, false, cerr2
	fresh, _, _ := iface.taskchain_get_task(svc.repo, task.task_id)
	return Review_Result{task = fresh, gate = gate}, true, domain.Domain_Error{}
}

// ---- human verbs: reopen / answer --------------------------------------------------------

// task_reopen: done|cancelled → a new attempt (non-counting grant next).
task_reopen :: proc(svc: ^Service, task: domain.Task, actor: Actor) -> (domain.Task, bool, domain.Domain_Error) {
	if !domain.task_state_is_terminal(task.state) do return {}, false, domain.domain_error(.Conflict, "only a done or cancelled task can be reopened")
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
	_, _, rok, rerr := record_event(svc, &u, task, actor, EV_REOPENED, "{}")
	if rok do rok, rerr = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Task_Reopened)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return {}, false, rerr
	if cerr.code != .None do return {}, false, cerr
	fresh, _, _ := iface.taskchain_get_task(svc.repo, task.task_id)
	return fresh, true, domain.Domain_Error{}
}

// task_answer: a human clears a blocked_on (block, budget, oscillation) badge.
task_answer :: proc(svc: ^Service, task: domain.Task, actor: Actor, note: string) -> (domain.Task, bool, domain.Domain_Error) {
	if strings.trim_space(task.blocked_on_json) == "" do return {}, false, domain.domain_error(.Conflict, "task is not blocked")
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
	p := json_begin()
	if strings.trim_space(note) != "" do json_str(&p, "note", note)
	_, _, rok, rerr := record_event(svc, &u, task, actor, EV_ANSWERED, json_end(&p))
	if rok do rok, rerr = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Task_Updated)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return {}, false, rerr
	if cerr.code != .None do return {}, false, cerr
	fresh, _, _ := iface.taskchain_get_task(svc.repo, task.task_id)
	return fresh, true, domain.Domain_Error{}
}

// ---- verify facet (hub-written from shell_exited) -------------------------------------

// VERIFY_LABEL_PREFIX: `ham-ctl verify` starts a Run session labelled
//   "verify <task_id> #<attempt_no> @<head_at_start>"
// so the hub can attribute its exit without a metadata column.
VERIFY_LABEL_PREFIX :: "verify "

Verify_Exit :: struct {
	session_id:    string,
	label:         string,
	owner_user_id: string,
	status:        string,
	exit_code:     int,
	exit_code_set: bool,
	duration_ms:   i64,
	head_at_end:   string, // bridge enrichment on the exit frame, "" when unknown
	dirty:         string, // "true" | "false" | "" (unknown / no VCS)
	tail:          string, // last lines of the log (≤ 40), optional
}

parse_verify_label :: proc(label: string) -> (task_id, head: string, attempt_no: int, ok: bool) {
	if !strings.has_prefix(label, VERIFY_LABEL_PREFIX) do return "", "", 0, false
	rest := strings.trim_space(label[len(VERIFY_LABEL_PREFIX):])
	parts := strings.fields(rest, context.temp_allocator)
	if len(parts) < 2 do return "", "", 0, false
	task_id = parts[0]
	if !strings.has_prefix(parts[1], "#") do return "", "", 0, false
	attempt_no = jsonx.extract_int(fmt.tprintf(`{{"n":%s}}`, parts[1][1:]), "n", -1, true)
	if attempt_no < 0 do return "", "", 0, false
	if len(parts) >= 3 && strings.has_prefix(parts[2], "@") do head = parts[2][1:]
	return task_id, head, attempt_no, true
}

// on_verify_session_exited writes the `verify` facet for a terminal verify Run
// session: exit_code (−1 when the session died without one: bridge death),
// duration, log_ref = session id, heads, dirty, summary (≤ 40 lines).
on_verify_session_exited :: proc(svc: ^Service, exit: Verify_Exit) {
	if svc == nil || svc.repo == nil do return
	task_id, head_start, attempt_no, ok := parse_verify_label(exit.label)
	if !ok do return
	task, tok, _ := iface.taskchain_get_task(svc.repo, domain.Task_ID(task_id))
	if !tok || string(task.owner_user_id) != exit.owner_user_id do return
	code := exit.exit_code if exit.exit_code_set else -1
	if exit.status == "killed" || exit.status == "failed" {
		if !exit.exit_code_set || exit.status == "failed" do code = -1
	}
	u, uok, _ := begin_uow(svc)
	if !uok do return
	// Don't let an unobserved inventory reap overwrite an already-observed verify facet.
	if !exit.exit_code_set {
		if existing, has := get_facet(svc, task, attempt_no, FACET_VERIFY); has {
			if prev_code := jsonx.extract_int(existing.body_json, "exit_code", -1, true); prev_code != -1 {
				_, _ = end_uow(svc, &u, false)
				return
			}
		}
	}
	o := json_begin()
	json_int(&o, "exit_code", i64(code))
	json_int(&o, "duration_ms", exit.duration_ms)
	json_str(&o, "log_ref", exit.session_id)
	json_str(&o, "head_at_start", head_start)
	json_str(&o, "head_at_end", exit.head_at_end if exit.head_at_end != "" else head_start)
	switch exit.dirty {
	case "true": json_bool(&o, "dirty", true)
	case "false": json_bool(&o, "dirty", false)
	case: json_raw(&o, "dirty", "null")
	}
	json_str(&o, "status", exit.status)
	json_str(&o, "summary", tail_lines(exit.tail, 40))
	saved, _ := save_facet_verbatim(svc, task, attempt_no, FACET_VERIFY, json_end(&o), FACET_WRITER_HUB)
	if saved do effect_publish_task(&u, task, "verify")
	_, _ = end_uow(svc, &u, saved)
}

@(private = "file")
tail_lines :: proc(text: string, max_lines: int) -> string {
	if text == "" do return ""
	lines := strings.split_lines(text, context.temp_allocator)
	if len(lines) <= max_lines do return text
	return strings.join(lines[len(lines)-max_lines:], "\n", context.temp_allocator)
}

// ---- task.fetch -------------------------------------------------------------------------

// task_fetch: read-only; the caller must be able to read the task (owner, or
// an instance of the owner — the HTTP layer resolves the task owner-scoped).
task_fetch :: proc(svc: ^Service, task: domain.Task, ref: string) -> (string, bool, domain.Domain_Error) {
	return fetch_ref(svc, task, ref)
}
