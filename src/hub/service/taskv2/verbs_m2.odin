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
// Each verb is ONE unit of work: validate →
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
	lease_id:       string,
	summary:        string,
	handoff_json:   string, // optional object: next_steps, decisions, … (verbatim)
	output_json:    string, // optional object: the brief's output contract
	vcs_json:       string, // bridge .Local enrichment: {head, dirty, files:[…]}
	artifacts_json: string, // optional object: {items:[{kind,title,uri?,path?,mime?,bytes?,sha256?}]}
}

Submit_Result :: struct {
	task:    domain.Task,
	outcome: string, // in_review | done
}

// lease_submit (plan §2.5): hard rejects = summary empty · output missing when
// the brief requires one; everything else is truncated with truncated:true.
// The worker reports the checks it chose in the summary/handoff; the review
// gate (not a command result) decides the task. Releases the lease and stops
// the holder.
lease_submit :: proc(svc: ^Service, auth: contracts.Auth_Context, input: Submit_Input) -> (Submit_Result, bool, domain.Domain_Error) {
	if strings.trim_space(input.summary) == "" do return {}, false, domain.domain_error(.Validation_Failed, "summary is required")
	if strings.trim_space(input.artifacts_json) != "" {
		if _, aok, aerr := validate_artifacts_facet_json(input.artifacts_json); !aok {
			return {}, false, aerr
		}
	}
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
	c, ok, err := work_lease_caller(svc, auth, input.lease_id)
	if !ok { _, _ = end_uow(svc, &u, false); return {}, false, err }
	// output contract: brief.output present → an output object is required and validated
	if oerr := validate_task_output_contract(c.task, input.output_json); oerr.code != .None {
		_, _ = end_uow(svc, &u, false)
		return {}, false, oerr
	}
	actor := Actor{kind = ACTOR_AGENT, id = c.inst.agent_instance_id}
	if !write_submit_facets(svc, &u, c.task, c.lease.attempt_no, input) {
		_, _ = end_uow(svc, &u, false)
		return {}, false, domain.domain_error(.Internal_Error, "failed to store the submission facets")
	}
	p := json_begin()
	json_str(&p, "lease_id", c.lease.lease_id)
	json_int(&p, "attempt_no", i64(c.lease.attempt_no))
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
	if ok, _ := save_facet_verbatim(svc, task, attempt_no, FACET_HANDOFF, handoff_body_json(input.summary, input.handoff_json), FACET_WRITER_AGENT, u); !ok do return false
	if strings.has_prefix(strings.trim_space(input.vcs_json), "{") {
		if ok, _ := save_facet_verbatim(svc, task, attempt_no, FACET_VCS, input.vcs_json, FACET_WRITER_BRIDGE, u); !ok do return false
	}
	if strings.has_prefix(strings.trim_space(input.output_json), "{") {
		if ok, _ := save_facet_verbatim(svc, task, attempt_no, FACET_OUTPUT, input.output_json, FACET_WRITER_AGENT, u); !ok do return false
	}
	if trimmed := strings.trim_space(input.artifacts_json); strings.has_prefix(trimmed, "{") {
		if norm, aok, _ := validate_artifacts_facet_json(trimmed); aok {
			if ok, _ := save_facet_verbatim(svc, task, attempt_no, FACET_ARTIFACTS, norm, FACET_WRITER_AGENT, u); !ok do return false
		}
	}
	return true
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
	if fok, _ := save_facet_verbatim(svc, c.task, c.lease.attempt_no, FACET_HANDOFF, handoff_body_json(input.summary, input.handoff_json), FACET_WRITER_AGENT, &u); !fok {
		_, _ = end_uow(svc, &u, false)
		return {}, false, domain.domain_error(.Internal_Error, "failed to store the handoff")
	}
	if strings.has_prefix(strings.trim_space(input.vcs_json), "{") {
		_, _ = save_facet_verbatim(svc, c.task, c.lease.attempt_no, FACET_VCS, input.vcs_json, FACET_WRITER_BRIDGE, &u)
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

// ---- lease.switch (solo mode, REQ-SOLO-4) ----------------------------------------------

Switch_Input :: struct {
	lease_id:     string,
	task_id:      string, // the ready task to take next
	summary:      string, // handoff summary for the task being left (required)
	handoff_json: string,
}

Switch_Result :: struct {
	left:      domain.Task,
	lease:     domain.Task_Lease,
	task:      domain.Task,
	pack_json: string,
}

// lease_switch hands the caller's current work lease off (non-counting, summary
// kept for the next attempt) and grants the named ready task inline — in ONE
// unit of work: if the new task cannot be granted, nothing happened (409).
lease_switch :: proc(svc: ^Service, auth: contracts.Auth_Context, input: Switch_Input) -> (Switch_Result, bool, domain.Domain_Error) {
	if strings.trim_space(input.summary) == "" do return {}, false, domain.domain_error(.Validation_Failed, "summary is required")
	if strings.trim_space(input.task_id) == "" do return {}, false, domain.domain_error(.Validation_Failed, "task_id is required")
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
	c, ok, err := work_lease_caller(svc, auth, input.lease_id)
	if !ok { _, _ = end_uow(svc, &u, false); return {}, false, err }
	if string(c.task.task_id) == strings.trim_space(input.task_id) { _, _ = end_uow(svc, &u, false); return {}, false, domain.domain_error(.Conflict, "already working on that task") }
	chain, cok, cerr := iface.taskchain_get_chain(svc.repo, c.task.chain_id)
	if !cok { _, _ = end_uow(svc, &u, false); return {}, false, cerr }
	if fok, _ := save_facet_verbatim(svc, c.task, c.lease.attempt_no, FACET_HANDOFF, handoff_body_json(input.summary, input.handoff_json), FACET_WRITER_AGENT, &u); !fok {
		_, _ = end_uow(svc, &u, false)
		return {}, false, domain.domain_error(.Internal_Error, "failed to store the handoff")
	}
	p := json_begin()
	json_str(&p, "lease_id", c.lease.lease_id)
	json_int(&p, "attempt_no", i64(c.lease.attempt_no))
	json_str(&p, "switched_to", strings.trim_space(input.task_id))
	// The same process continues inline with the next task: never stopped.
	left, rok, rerr := release_in_uow(svc, &u, c.lease, Actor{kind = ACTOR_AGENT, id = c.inst.agent_instance_id}, EV_HANDOFF, json_end(&p), "handoff", stop_holder = false)
	if !rok { _, _ = end_uow(svc, &u, false); return {}, false, rerr }
	// Grant B BEFORE the matcher runs, so a mixed chain cannot wake-grant it to
	// another worker first.
	lease, task, granted, gerr := grant_inline_task_for_instance(svc, &u, chain, c.inst, domain.Task_ID(strings.trim_space(input.task_id)), .Lease_Next)
	if !granted { _, _ = end_uow(svc, &u, false); return {}, false, gerr }
	if aok, aerr := after_chain_change(svc, &u, chain.chain_id, chain.owner_user_id, .Lease_Released); !aok {
		_, _ = end_uow(svc, &u, false)
		return {}, false, aerr
	}
	pack := build_pack_json(svc, chain, task, lease, c.inst)
	_, ecerr := end_uow(svc, &u, true)
	if ecerr.code != .None do return {}, false, ecerr
	return Switch_Result{left = left, lease = lease, task = task, pack_json = pack}, true, domain.Domain_Error{}
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
		_, _ = save_facet_verbatim(svc, c.task, c.lease.attempt_no, FACET_HANDOFF, handoff_body_json(input.summary, ""), FACET_WRITER_AGENT, &u)
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
	task_id:       string, // optional for agents (their review lease names it); required for users and on_behalf_of:user
	verdict:       string, // approve | request_changes
	findings_json: string, // array, verbatim (capped)
	on_behalf_of:  string, // optional: "user" (coordinator proxy review)
	summary:       string, // optional free-text reason (kept on review_posted; a rejected gate's re-plan reads it)
}

Review_Result :: struct {
	task:  domain.Task,
	gate:  Gate_Result,
	// unmet: why a `.Waiting` gate did not advance (missing review pairs, user
	// approval), for the review_post response (REQ-TV2-3a).
	unmet: []Gate_Unmet,
}

// review_post: the review lease IS the offer — the holder posts a verdict,
// the lease is released, the gate is evaluated. When `on_behalf_of == "user"`,
// a coordinator instance may post a review satisfying `requires_user_approval`
// without holding a review lease.
review_post :: proc(svc: ^Service, auth: contracts.Auth_Context, input: Review_Input) -> (Review_Result, bool, domain.Domain_Error) {
	if input.verdict != "approve" && input.verdict != "request_changes" do return {}, false, domain.domain_error(.Validation_Failed, "verdict must be approve or request_changes")
	if verr := require_change_reason(input); verr.code != .None do return {}, false, verr
	inst, ok, err := instance_from_auth(svc, auth)
	if !ok do return {}, false, err
	if strings.trim_space(input.on_behalf_of) != "" && strings.trim_space(input.on_behalf_of) != "user" {
		return {}, false, domain.domain_error(.Validation_Failed, "on_behalf_of must be \"user\"")
	}
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr

	tid := strings.trim_space(input.task_id)
	target_task := domain.Task{}
	has_target := false
	if tid != "" {
		t_lookup, tok_lookup, _ := iface.taskchain_get_task(svc.repo, domain.Task_ID(tid))
		if tok_lookup && t_lookup.owner_user_id == inst.owner_user_id && (inst.chain_id == "" || string(t_lookup.chain_id) == inst.chain_id) {
			target_task = t_lookup
			has_target = true
		}
	}

	if strings.trim_space(input.on_behalf_of) != "" || (has_target && target_task.kind == .Gate) {
		if tid == "" {
			_, _ = end_uow(svc, &u, false)
			return {}, false, domain.domain_error(.Validation_Failed, "task_id is required when reviewing on_behalf_of user")
		}
		if !has_target {
			_, _ = end_uow(svc, &u, false)
			return {}, false, domain.domain_error(.Not_Found, "task not found")
		}
		task := target_task
		chain, cok, cerr := iface.taskchain_get_chain(svc.repo, task.chain_id)
		if !cok { _, _ = end_uow(svc, &u, false); return {}, false, cerr }
		if inst.agent_id != "coordinator" && !is_coordinator(svc, chain, inst.agent_instance_id) {
			_, _ = end_uow(svc, &u, false)
			return {}, false, domain.domain_error(.Forbidden, "only the coordinator may review a gate or on_behalf_of user")
		}
		// Solo mode: the coordinator did the work, so it may not approve it — not
		// as the user, not at a plan gate (REQ-SOLO-5). The user reviews.
		if chain_is_solo(svc, chain) {
			_, _ = end_uow(svc, &u, false)
			return {}, false, domain.domain_error(.Forbidden, "in solo mode the user reviews the coordinator's work", `{"code":"solo_self_review"}`)
		}
		if task.state != .In_Review {
			_, _ = end_uow(svc, &u, false)
			return {}, false, domain.domain_error(.Conflict, "task is not awaiting review")
		}
		if task.kind == .Gate && gate_approver_policy(task) == "user" && strings.trim_space(input.on_behalf_of) == "" {
			_, _ = end_uow(svc, &u, false)
			return {}, false, domain.domain_error(.Forbidden, "gate stage requires human user approval", `{"code":"gate_requires_user"}`)
		}
		rev_role := "user" if strings.trim_space(input.on_behalf_of) == "user" else "coordinator"
		findings, _ := findings_json_capped(input.findings_json)
		now := platform.clock_now(svc.clock)
		review := domain.Task_Review{
			task_id = task.task_id, chain_id = task.chain_id, owner_user_id = task.owner_user_id, attempt_no = task.attempt_no,
			role = rev_role, reviewer_kind = rev_role, reviewer_agent_id = inst.agent_id, reviewer_instance_id = inst.agent_instance_id,
			verdict = input.verdict, findings_json = findings, created_at = now,
		}
		if _, sok, serr := iface.taskchain_save_review(svc.repo, review); !sok { _, _ = end_uow(svc, &u, false); return {}, false, serr }
		actor := Actor{kind = ACTOR_COORDINATOR, id = inst.agent_instance_id}
		p := json_begin()
		json_int(&p, "attempt_no", i64(task.attempt_no))
		json_str(&p, "role", rev_role)
		json_str(&p, "verdict", input.verdict)
		json_str(&p, "reviewer", rev_role if rev_role == "user" else inst.agent_instance_id)
		json_str(&p, "reviewer_agent_id", inst.agent_id)
		json_str(&p, "reviewer_instance_id", inst.agent_instance_id)
		json_str(&p, "actor_kind", ACTOR_COORDINATOR)
		if strings.trim_space(input.on_behalf_of) == "user" {
			json_str(&p, "on_behalf_of", "user")
			json_str(&p, "proxy_agent_id", inst.agent_id)
		}
		json_raw(&p, "findings", findings)
		if strings.trim_space(input.summary) != "" do json_str(&p, "summary", strings.trim_space(input.summary))
		refolded, _, rok, rerr := record_event(svc, &u, task, actor, EV_REVIEW_POSTED, json_end(&p))
		if !rok { _, _ = end_uow(svc, &u, false); return {}, false, rerr }
		gate, gok, gerr := evaluate_gate_in_uow(svc, &u, chain, refolded, actor)
		if gok && gate == .Rejected do gok, gerr = gate_replan_in_uow(svc, &u, chain, refolded, actor)
		if gok do gok, gerr = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Review_Posted)
		_, cerr2 := end_uow(svc, &u, gok)
		if !gok do return {}, false, gerr
		if cerr2.code != .None do return {}, false, cerr2
			return review_result(svc, task.task_id, gate), true, domain.Domain_Error{}
	}
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
	// One lease covers every (agent, role) pair this reviewer owes on the task
	// (hybrid review model); the verdict is recorded once per pair so the gate
	// stays a strict AND over pairs.
	lease_roles := split_review_roles(lease.review_role)
	if len(lease_roles) == 0 do lease_roles = []string{lease.review_role}
	for role in lease_roles {
		review := domain.Task_Review{
			task_id = task.task_id, chain_id = task.chain_id, owner_user_id = task.owner_user_id, attempt_no = task.attempt_no,
			role = role, reviewer_kind = "agent", reviewer_agent_id = inst.agent_id, reviewer_instance_id = inst.agent_instance_id,
			verdict = input.verdict, findings_json = findings, created_at = now,
		}
		if _, sok, serr := iface.taskchain_save_review(svc.repo, review); !sok { _, _ = end_uow(svc, &u, false); return {}, false, serr }
	}
	// release the review lease (not an attempt; no budget)
	if deleted, _ := iface.taskchain_delete_lease(svc.repo, lease.lease_id); !deleted { _, _ = end_uow(svc, &u, false); return {}, false, lease_lost_error() }
	metric_lease_released(lease.kind)
	actor := Actor{kind = ACTOR_AGENT, id = inst.agent_instance_id}
	p := json_begin()
	json_int(&p, "attempt_no", i64(task.attempt_no))
	json_str(&p, "role", lease.review_role)
	json_str(&p, "verdict", input.verdict)
	json_str(&p, "reviewer", inst.agent_id)
	json_str(&p, "reviewer_agent_id", inst.agent_id)
	json_str(&p, "reviewer_instance_id", inst.agent_instance_id)
	json_raw(&p, "findings", findings)
	if strings.trim_space(input.summary) != "" do json_str(&p, "summary", strings.trim_space(input.summary))
	refolded, _, rok, rerr := record_event(svc, &u, task, actor, EV_REVIEW_POSTED, json_end(&p))
	if !rok { _, _ = end_uow(svc, &u, false); return {}, false, rerr }
	// Idle first so the matcher below may re-grant this same instance.
	mark_instance_idle(svc, &u, inst.agent_instance_id, now)
	gate, gok, gerr := evaluate_gate_in_uow(svc, &u, chain, refolded, actor)
	if gok && gate == .Rejected do gok, gerr = gate_replan_in_uow(svc, &u, chain, refolded, actor)
	if gok do gok, gerr = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Review_Posted)
	// Reviewer lifecycle invariant (REQ-TV2-3a): decide the stop only AFTER the
	// gate and the matcher ran. Re-granted → keep it running. Still owing a
	// review pair anywhere in the chain (e.g. its bridge was offline for the
	// matcher) → keep it alive under the idle TTL instead of stopping it now.
	if gok {
		if _, regranted, _ := iface.taskchain_get_lease_by_holder(svc.repo, inst.agent_instance_id); !regranted {
			if !agent_owes_review_in_chain(svc, task.chain_id, task.owner_user_id, inst.agent_id) {
				effect_stop(&u, inst.bridge_id, string(task.chain_id), inst.agent_instance_id)
			}
			arm_idle_ttl(svc, inst.agent_instance_id, fleet_idle_ttl(svc, task.chain_id, task.owner_user_id, inst.agent_id), now)
		}
	}
	_, cerr2 := end_uow(svc, &u, gok)
	if !gok do return {}, false, gerr
	if cerr2.code != .None do return {}, false, cerr2
	// A waiting gate re-checks the review invariant within the rematch window
	// (fire_rematch → review_stalled), REQ-TV2-3a.
	if gate == .Waiting do timers_arm(svc, .Rematch, string(task.task_id), now_ms(svc.clock) + REMATCH_DELAYS_SECONDS[0] * 1000, domain.task_state_string(domain.Task_State.In_Review))
	return review_result(svc, task.task_id, gate), true, domain.Domain_Error{}
}

// review_result reloads the task after a review and, while its gate waits,
// lists the unmet components.
review_result :: proc(svc: ^Service, task_id: domain.Task_ID, gate: Gate_Result) -> Review_Result {
	fresh, _, _ := iface.taskchain_get_task(svc.repo, task_id)
	out := Review_Result{task = fresh, gate = gate}
	if gate == .Waiting do out.unmet, _ = gate_unmet_components(svc, fresh)
	return out
}

// user_review: the owner approves / requests changes on an in_review task
// (requires_user_approval, or simply as a human reviewer).
user_review :: proc(svc: ^Service, auth: contracts.Auth_Context, task_id: domain.Task_ID, input: Review_Input) -> (Review_Result, bool, domain.Domain_Error) {
	if input.verdict != "approve" && input.verdict != "request_changes" do return {}, false, domain.domain_error(.Validation_Failed, "verdict must be approve or request_changes")
	if auth.kind != .User_Token && auth.kind != .Trusted_Proxy do return {}, false, domain.domain_error(.Forbidden, "user token is required")
	if verr := require_change_reason(input); verr.code != .None do return {}, false, verr
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
	// A user review has no agent; the keys are present (empty) so every
	// review_posted payload has the same shape.
	json_str(&p, "reviewer_agent_id", "")
	json_str(&p, "reviewer_instance_id", "")
	json_raw(&p, "findings", findings)
	if strings.trim_space(input.summary) != "" do json_str(&p, "summary", strings.trim_space(input.summary))
	refolded, _, rok, rerr := record_event(svc, &u, task, actor, EV_REVIEW_POSTED, json_end(&p))
	if !rok { _, _ = end_uow(svc, &u, false); return {}, false, rerr }
	gate, gok, gerr := evaluate_gate_in_uow(svc, &u, chain, refolded, actor)
	if gok && gate == .Rejected do gok, gerr = gate_replan_in_uow(svc, &u, chain, refolded, actor)
	if gok do gok, gerr = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Review_Posted)
	_, cerr2 := end_uow(svc, &u, gok)
	if !gok do return {}, false, gerr
	if cerr2.code != .None do return {}, false, cerr2
	return review_result(svc, task.task_id, gate), true, domain.Domain_Error{}
}

// ---- human verbs: reopen / answer --------------------------------------------------------

// task_reopen: done|cancelled → a new attempt (non-counting grant next).
task_reopen :: proc(svc: ^Service, task: domain.Task, actor: Actor) -> (domain.Task, bool, domain.Domain_Error) {
	if task.workflow_run_id != "" do return {}, false, domain.domain_error(.Conflict, "retry the whole workflow run rather than reopening a generated task", `{"code":"workflow_task_managed"}`)
	if !domain.task_state_is_terminal(task.state) do return {}, false, domain.domain_error(.Conflict, "only a done or cancelled task can be reopened")
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
    if _, allowed, err := work_control_chain(svc, task.owner_user_id, actor, task.chain_id); !allowed {
        _, _ = end_uow(svc, &u, false)
        return {}, false, err
    }
    if err := workflow_require_current_task(svc, task); err.code != .None {
        _, _ = end_uow(svc, &u, false)
        return {}, false, err
    }
	if task.stage_key == "" && task.kind == .Task {
		guard := work_require_unconsumed_in_uow(svc, task.chain_id, task.owner_user_id, domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = string(task.task_id)})
		if guard.code != .None {
			_, _ = end_uow(svc, &u, false)
			return {}, false, guard
		}
	}
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
	if task_is_held(task) do return {}, false, domain.domain_error(.Conflict, "task is held; release it with `task release`")
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
    if _, allowed, err := work_control_chain(svc, task.owner_user_id, actor, task.chain_id); !allowed {
        _, _ = end_uow(svc, &u, false)
        return {}, false, err
    }
    if err := workflow_require_current_task(svc, task); err.code != .None {
        _, _ = end_uow(svc, &u, false)
        return {}, false, err
    }
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

// ---- human/coordinator verbs: hold / release (REQ-TV2-5) -------------------------------

Hold_Result :: struct {
	task:                 domain.Task,
	// changed: false for a no-op (hold on a held task, release on an unheld one).
	changed:              bool,
	// checkpoint_requested: the task was leased; its holder was asked to hand off.
	checkpoint_requested: bool,
	message:              string,
}

// task_hold: the task gets no new lease (work or review) until task_release.
// An unleased task parks in backlog as blocked_on {kind: hold}; a leased one
// keeps its lease and the holder is asked for a checkpoint (lease handoff),
// after which the handoff parks the task instead of re-dispatching it. Never
// revokes a lease; the lease TTL still applies.
task_hold :: proc(svc: ^Service, task: domain.Task, actor: Actor, reason: string) -> (Hold_Result, bool, domain.Domain_Error) {
	if strings.trim_space(reason) == "" do return {}, false, domain.domain_error(.Validation_Failed, "reason is required")
	if domain.task_state_is_terminal(task.state) do return {}, false, domain.domain_error(.Conflict, "a done or cancelled task cannot be held")
	if task.kind == .Gate do return {}, false, domain.domain_error(.Conflict, "gates cannot be held")
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
	if _, allowed, err := work_control_chain(svc, task.owner_user_id, actor, task.chain_id); !allowed {
		_, _ = end_uow(svc, &u, false)
		return {}, false, err
	}
	evs, eerr := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	if eerr.code != .None { _, _ = end_uow(svc, &u, false); return {}, false, eerr }
	pre := fold_task(evs, fold_input_for_task(task, true))
	if pre.held {
		_, _ = end_uow(svc, &u, false)
		return Hold_Result{task = task, message = "task is already held"}, true, domain.Domain_Error{}
	}
	p := json_begin()
	json_str(&p, "reason", strings.trim_space(reason))
	json_str(&p, "by", actor.kind)
	fresh, view, rok, rerr := record_event(svc, &u, task, actor, EV_HELD, json_end(&p))
	checkpoint := rok && view.has_work_lease
	if checkpoint {
		// Ask the holder to refresh TASK.md (its pack now carries the
		// Checkpoint Requested section) and hand off at a safe point.
		if lease, lok, _ := iface.taskchain_get_lease(svc.repo, view.work_lease_id); lok {
			bridge_id := lease.bridge_id
			if inst, iok, _ := iface.agent_get_instance(svc.agents, lease.holder_instance_id); iok && bridge_id == "" do bridge_id = inst.bridge_id
			effect_nudge_instance(&u, lease.holder_instance_id, bridge_id, fmt.tprintf("[taskv2] Checkpoint requested on task %s: run `ham-ctl lease next` to refresh TASK.md, reach a safe point, commit, then `ham-ctl lease handoff`.", task.task_id))
		}
	}
	if rok do rok, rerr = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Task_Updated)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return {}, false, rerr
	if cerr.code != .None do return {}, false, cerr
	if f, fok, _ := iface.taskchain_get_task(svc.repo, task.task_id); fok do fresh = f
	msg := "task held; it will not be dispatched until released"
	if checkpoint do msg = "task held; its current holder was asked to checkpoint and hand off"
	return Hold_Result{task = fresh, changed = true, checkpoint_requested = checkpoint, message = msg}, true, domain.Domain_Error{}
}

// task_release clears a hold; the task becomes dispatchable again (unless
// something else still blocks it). Releasing an unheld task is a no-op.
task_release :: proc(svc: ^Service, task: domain.Task, actor: Actor) -> (Hold_Result, bool, domain.Domain_Error) {
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
	if _, allowed, err := work_control_chain(svc, task.owner_user_id, actor, task.chain_id); !allowed {
		_, _ = end_uow(svc, &u, false)
		return {}, false, err
	}
	evs, eerr := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	if eerr.code != .None { _, _ = end_uow(svc, &u, false); return {}, false, eerr }
	if pre := fold_task(evs, fold_input_for_task(task, true)); !pre.held {
		_, _ = end_uow(svc, &u, false)
		return Hold_Result{task = task, message = "task is not held; nothing to release"}, true, domain.Domain_Error{}
	}
	fresh, _, rok, rerr := record_event(svc, &u, task, actor, EV_HOLD_RELEASED, "{}")
	if rok do rok, rerr = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Task_Updated)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return {}, false, rerr
	if cerr.code != .None do return {}, false, cerr
	if f, fok, _ := iface.taskchain_get_task(svc.repo, task.task_id); fok do fresh = f
	return Hold_Result{task = fresh, changed = true, message = "hold released"}, true, domain.Domain_Error{}
}

// ---- task.fetch -------------------------------------------------------------------------

// task_fetch: read-only; the caller must be able to read the task (owner, or
// an instance of the owner — the HTTP layer resolves the task owner-scoped).
task_fetch :: proc(svc: ^Service, task: domain.Task, ref: string) -> (string, bool, domain.Domain_Error) {
	return fetch_ref(svc, task, ref)
}

// ---- chain.propose & chain.proposal.decide (M3 §2.5) ------------------------------------

BRIEF_GOAL_MAX        :: 2000
BRIEF_ACCEPTANCE_MAX  :: 20
BRIEF_ACCEPTANCE_ITEM :: 200

Propose_Input :: struct {
	chain_id:             string, // optional for agents
	tasks_json:           string, // optional JSON array of task specs [{id?, title, brief, depends_on?}]
	kind:                 string, // proposal item mode: task or workflow_run; never a chain type
	rationale:            string, // optional explanation
	alternative:          string, // optional alternative plan considered
	auto_approve:         bool,   // when true, immediately approves & publishes in the same UoW
	workflow_ref:         string, // optional workflow template/def name or id for a workflow_run proposal
	workflow_inputs_json: string, // optional JSON object of workflow inputs for a workflow_run proposal
}

// chain_proposal_json extracts the pending proposal JSON object from `chain.defaults_json`
// (or "" when none is pending).
chain_proposal_json :: proc(chain: domain.Task_Chain, allocator := context.temp_allocator) -> string {
	if strings.trim_space(chain.defaults_json) == "" do return ""
	prop, ok := jsonx.extract_raw_object(chain.defaults_json, "proposal", true, allocator)
	if !ok do return ""
	return prop
}

set_chain_proposal_json :: proc(defaults_json: string, proposal_obj_json: string, allocator := context.temp_allocator) -> string {
	o := json_begin(allocator)
	if strings.has_prefix(strings.trim_space(defaults_json), "{") {
		for key, raw in jsonx_top_level_members(defaults_json) {
			if key == "proposal" do continue
			// M2: a removed brief default (auto_submit, …) is never re-persisted.
			removed := false
			for k in REMOVED_VERIFY_BRIEF_KEYS do if key == k { removed = true; break }
			if removed do continue
			json_raw(&o, key, raw)
		}
	}
	if strings.trim_space(proposal_obj_json) != "" && strings.has_prefix(strings.trim_space(proposal_obj_json), "{") {
		json_raw(&o, "proposal", proposal_obj_json)
	}
	return json_end(&o)
}

// brief_publish_missing is THE publish validator (REQ-TV2-2), shared by
// chain.propose/decide, workflow-free ticket publish and the taskchain
// service: a worked ticket needs a non-empty goal (≤2k) and 1..20 acceptance
// items (≤200 chars each). Nothing else is required — no verify command and no
// output contract. Every review role must also have a fleet row to hold it, or
// the task could never pass its gate. Gates are exempt (decided, not worked).
brief_publish_missing :: proc(repo: ^iface.Taskchain_Repository, chain: domain.Task_Chain, kind: domain.Task_Kind, brief: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if kind == .Gate do return out[:]
	goal := strings.trim_space(jsonx.extract_string(brief, "goal", "", true, context.temp_allocator))
	if goal == "" || (len(goal) > BRIEF_GOAL_MAX && !is_vault_armored(goal)) do append(&out, "goal")
	acceptance := jsonx.extract_string_array(brief, "acceptance", true, context.temp_allocator)
	acc_ok := len(acceptance) >= 1 && len(acceptance) <= BRIEF_ACCEPTANCE_MAX
	for a in acceptance do if strings.trim_space(a) == "" || (len(a) > BRIEF_ACCEPTANCE_ITEM && !is_vault_armored(a)) do acc_ok = false
	if !acc_ok do append(&out, "acceptance")
	roles := jsonx.extract_string_array(brief, "review_roles", true, context.temp_allocator)
	if len(roles) > 0 && repo != nil {
		fleets, ferr := iface.taskchain_list_fleets_by_chain(repo, chain.chain_id, chain.owner_user_id)
		for r in roles {
			covered := false
			if ferr.code == .None do for f in fleets do if fleet_row_has_role(f, r) { covered = true; break }
			if !covered do append(&out, fmt.tprintf("review_role:%s", r))
		}
	}
	return out[:]
}

// validate_brief_for_publish verifies that all draft tasks on the chain and all
// proposed task specs satisfy brief_publish_missing.
validate_brief_for_publish :: proc(svc: ^Service, chain: domain.Task_Chain, existing_tasks: []domain.Task, specs: []Proposed_Task_Item) -> (bool, domain.Domain_Error) {
	// REQ-TV2-4: proposed briefs meet the same schema and reviewer identity
	// contract as taskchain create/update, before a proposal is stored or
	// materialized (pending, auto-approved and approved alike).
	for spec in specs {
		if spec.explicit_brief {
			if serr := validate_brief_schema(spec.brief_json); serr.code != .None do return false, serr
		}
		if rerr := validate_reviewer_agent_ids(svc.agents if svc != nil else nil, brief_named_reviewers(spec.brief_json, context.temp_allocator)[:]); rerr.code != .None do return false, rerr
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"code":"brief_incomplete","tasks":[`)
	first := true
	has_problem := false
	for t in existing_tasks {
		if t.publish_state == .Published || t.workflow_run_id != "" do continue
		missing := brief_publish_missing(svc.repo if svc != nil else nil, chain, t.kind, t.brief_json)
		if len(missing) > 0 {
			has_problem = true
			if !first do strings.write_byte(&b, ',')
			first = false
			strings.write_string(&b, `{"task_id":"`); contracts.write_json_string(&b, string(t.task_id)); strings.write_string(&b, `","missing":[`)
			for m, i in missing {
				if i > 0 do strings.write_byte(&b, ',')
				strings.write_byte(&b, '"'); contracts.write_json_string(&b, m); strings.write_byte(&b, '"')
			}
			strings.write_string(&b, "]}")
		}
	}
	for spec, idx in specs {
		missing := brief_publish_missing(svc.repo if svc != nil else nil, chain, .Task, spec.brief_json)
		if len(missing) > 0 {
			has_problem = true
			if !first do strings.write_byte(&b, ',')
			first = false
			tid := spec.id if spec.id != "" else fmt.tprintf("proposed_%d", idx + 1)
			strings.write_string(&b, `{"task_id":"`); contracts.write_json_string(&b, tid); strings.write_string(&b, `","missing":[`)
			for m, i in missing {
				if i > 0 do strings.write_byte(&b, ',')
				strings.write_byte(&b, '"'); contracts.write_json_string(&b, m); strings.write_byte(&b, '"')
			}
			strings.write_string(&b, "]}")
		}
	}
	strings.write_string(&b, "]}")
	if has_problem {
		return false, domain.domain_error(.Validation_Failed, "brief incomplete: every published task needs a goal (≤2k), ≥1 acceptance item (≤20×200) and a fleet row per review role", strings.to_string(b))
	}
	return true, domain.Domain_Error{}
}

@(private = "file")
approve_and_publish_chain_in_uow :: proc(svc: ^Service, u: ^Uow, chain_in: domain.Task_Chain, actor: Actor, specs: []Proposed_Task_Item, note: string = "") -> (domain.Task_Chain, []domain.Task, bool, domain.Domain_Error) {
	chain := chain_in
	existing_tasks, _ := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if valid_b, berr := validate_brief_for_publish(svc, chain, existing_tasks, specs); !valid_b {
		return {}, nil, false, berr
	}
	now := platform.clock_now(svc.clock)
	chain.publish_state = .Published
	chain.status = .Active
	if chain.published_at == "" do chain.published_at = now
	chain.defaults_json = set_chain_proposal_json(chain.defaults_json, "")
	chain.updated_at = now
	updated, sok, serr := iface.taskchain_save_chain(svc.repo, chain)
	if !sok do return {}, nil, false, serr

	materialized := make([dynamic]domain.Task, 0, len(existing_tasks) + len(specs), context.temp_allocator)
	existing_by_id := make(map[string]domain.Task, len(existing_tasks), context.temp_allocator)
	for t in existing_tasks {
		t_copy := t
		if t_copy.publish_state != .Published {
			t_copy.publish_state = .Published
			if t_copy.published_at == "" do t_copy.published_at = now
			t_copy.updated_at = now
			saved_t, tok, terr := iface.taskchain_save_task(svc.repo, t_copy)
			if !tok do return {}, nil, false, terr
			t_copy = saved_t
		}
		if !event_exists(svc, t_copy, EV_PUBLISHED) {
			if _, pok_ev, perr_ev := append_event(svc.repo, svc.clock, t_copy, actor, EV_PUBLISHED, "{}"); !pok_ev {
				return {}, nil, false, perr_ev
			}
		}
		existing_by_id[string(t_copy.task_id)] = t_copy
		if len(specs) == 0 do append(&materialized, t_copy)
	}

	created := make([dynamic]domain.Task, 0, len(specs), context.temp_allocator)
	id_map := make(map[string]domain.Task_ID, len(specs), context.temp_allocator)
	// First pass: create proposed tasks without cross-proposal edges so symbolic IDs can map cleanly.
	for spec in specs {
		if spec.id != "" {
			if ex, already := existing_by_id[spec.id]; already {
				if spec.symbolic_id != "" do id_map[spec.symbolic_id] = ex.task_id
				append(&created, ex)
				append(&materialized, ex)
				continue
			}
		}
		tid := domain.Task_ID(spec.id)
		if tid == "" {
			tid = domain.Task_ID(platform.generate_id(svc.ids, "task_"))
		}
		t := domain.Task{
			task_id                = tid,
			chain_id               = chain.chain_id,
			owner_user_id          = chain.owner_user_id,
			title                  = spec.title,
			description            = spec.description,
			publish_state          = .Published,
			state                  = .Backlog,
			kind                   = .Task,
			priority               = domain.task_priority_from_string(spec.priority),
			brief_json             = spec.brief_json,
			requires_user_approval = brief_user_approval(svc, chain, spec.brief_json),
			ready_since            = "",
			created_at             = now,
			updated_at             = now,
			published_at           = now,
		}
		saved_t, tok, terr := iface.taskchain_save_task(svc.repo, t)
		if !tok do return {}, nil, false, terr
		cp := json_begin()
		json_raw(&cp, "brief", saved_t.brief_json)
		if _, cok_ev, cerr_ev := append_event(svc.repo, svc.clock, saved_t, actor, EV_CREATED, json_end(&cp)); !cok_ev {
			return {}, nil, false, cerr_ev
		}
		if _, pok_ev, perr_ev := append_event(svc.repo, svc.clock, saved_t, actor, EV_PUBLISHED, "{}"); !pok_ev {
			return {}, nil, false, perr_ev
		}
		if spec.symbolic_id != "" {
			id_map[spec.symbolic_id] = saved_t.task_id
		}
		append(&created, saved_t)
		append(&materialized, saved_t)
	}
	// Second pass: wire dependency edges (resolving symbolic IDs when used).
	for spec, idx in specs {
		if len(spec.depends_on) == 0 do continue
		for raw_dep in spec.depends_on {
			dep_id := raw_dep
			if mapped, ok := id_map[string(raw_dep)]; ok do dep_id = mapped
            if _, dok, derr := work_dependency_add_in_uow(svc, u, chain.owner_user_id, actor, chain.chain_id,
                domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = string(created[idx].task_id)},
                domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = string(dep_id)}); !dok {
                return {}, nil, false, derr
            }

			dp := json_begin()
			json_str(&dp, "depends_on", string(dep_id))
			if _, eok, eerr := append_event(svc.repo, svc.clock, created[idx], actor, EV_DEP_ADDED, json_end(&dp)); !eok {
				return {}, nil, false, eerr
			}
		}
	}

	ok_after, aerr := after_chain_change(svc, u, chain.chain_id, chain.owner_user_id, .Chain_Published)
	if !ok_after do return {}, nil, false, aerr
	effect_publish_chain(u, updated.chain_id, updated.owner_user_id, "proposal_approved")
	effect_notify_coordinator(svc, u, chain.chain_id, chain.owner_user_id, "proposal_decided", fmt.tprintf("[taskv2] proposal_decided: chain %s proposal approved (%d tasks materialized)%s%s", chain.chain_id, len(materialized), " — " if strings.trim_space(note) != "" else "", strings.trim_space(note)))

	out := make([dynamic]domain.Task, 0, len(materialized), context.temp_allocator)
	for t in materialized {
		if fresh, fok, _ := iface.taskchain_get_task(svc.repo, t.task_id); fok {
			append(&out, fresh)
		} else {
			append(&out, t)
		}
	}
	return updated, out[:], true, domain.Domain_Error{}
}

// chain_propose stores a coordinator/user proposal on `chain.defaults_json` (`proposal`)
// and publishes a chain update so the human can approve or reject it before tasks are materialized.
// When `input.auto_approve` is true, it immediately approves and publishes the chain and tasks in the same UoW.
chain_propose :: proc(svc: ^Service, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID, actor: Actor, input: Propose_Input) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	tasks_raw := strings.trim_space(input.tasks_json)
	specs: []Proposed_Task_Item = nil
	if tasks_raw != "" {
		// M2: legacy verify keys are dropped before the proposal is stored.
		tasks_raw, _ = strip_removed_verify_keys_in_task_specs(tasks_raw)
		if !strings.has_prefix(tasks_raw, "[") {
			return {}, false, domain.domain_error(.Validation_Failed, "tasks must be a JSON array")
		}
		parsed_specs, pok, perr := parse_proposed_tasks_json(tasks_raw)
		if !pok {
			if perr.code != .None do return {}, false, perr
			return {}, false, domain.domain_error(.Validation_Failed, "proposal tasks are invalid")
		}
		specs = parsed_specs
	}
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
	chain, cok, _ := iface.taskchain_get_chain(svc.repo, chain_id)
	if !cok || chain.owner_user_id != owner_user_id {
		_, _ = end_uow(svc, &u, false)
		return {}, false, domain.domain_error(.Not_Found, "chain not found")
	}
	if (actor.kind == ACTOR_AGENT || actor.kind == ACTOR_COORDINATOR) && !is_coordinator(svc, chain, actor.id) {
		_, _ = end_uow(svc, &u, false)
		return {}, false, domain.domain_error(.Forbidden, "only the chain coordinator may propose a chain plan", `{"code":"not_coordinator"}`)
	}
	if chain.status != .Active {
		_, _ = end_uow(svc, &u, false)
		return {}, false, domain.domain_error(.Conflict, "chain must be active")
	}
 if input.kind != "" && input.kind != "task" && input.kind != "workflow_run" {
  _, _ = end_uow(svc, &u, false)
  return {}, false, domain.domain_error(.Validation_Failed, "proposal kind must be task or workflow_run; chain type cannot change")
 }
 if pending := strings.trim_space(chain_proposal_json(chain)); pending != "" && pending != "{}" && pending != "null" {
  _, _ = end_uow(svc, &u, false)
  return {}, false, domain.domain_error(.Conflict, "decide the pending proposal before proposing more work")
 }
 is_wf_proposal := input.kind == "workflow_run" || strings.trim_space(input.workflow_ref) != ""
 if is_wf_proposal && strings.trim_space(input.workflow_ref) == "" {
  _, _ = end_uow(svc, &u, false)
  return {}, false, domain.domain_error(.Validation_Failed, "workflow_run proposal requires workflow reference")
 }
	if is_wf_proposal && strings.trim_space(input.workflow_ref) != "" {
		wf_ref := strings.trim_space(input.workflow_ref)
		wf_inputs := strings.trim_space(input.workflow_inputs_json)
		if wf_inputs == "" do wf_inputs = "{}"
		if input.auto_approve {
			updated, ap_ok, ap_err := workflow_proposal_run_in_uow(svc, &u, chain, actor, wf_ref, wf_inputs)
			_, cerr2 := end_uow(svc, &u, ap_ok)
			if !ap_ok do return {}, false, ap_err
			if cerr2.code != .None do return {}, false, cerr2
			return updated, true, domain.Domain_Error{}
		}
		now := platform.clock_now(svc.clock)
		p := json_begin()
		json_str(&p, "status", "pending")
		json_str(&p, "kind", "workflow_run")
		json_str(&p, "workflow", wf_ref)
		json_raw(&p, "inputs", wf_inputs)
		json_str(&p, "proposed_by_kind", actor.kind)
		json_str(&p, "proposed_by_id", actor.id)
		json_str(&p, "proposed_by", actor.id)
		json_str(&p, "proposed_at", now)
		if strings.trim_space(input.rationale) != "" do json_str(&p, "rationale", strings.trim_space(input.rationale))
		if strings.trim_space(input.alternative) != "" do json_str(&p, "alternative", strings.trim_space(input.alternative))
		json_int(&p, "created_at_ms", now_ms(svc.clock))
		json_raw(&p, "tasks", "[]")
		chain.defaults_json = set_chain_proposal_json(chain.defaults_json, json_end(&p))
		chain.updated_at = now
		updated, sok, serr := iface.taskchain_save_chain(svc.repo, chain)
		if !sok {
			_, _ = end_uow(svc, &u, false)
			return {}, false, serr
		}
		effect_publish_chain(&u, updated.chain_id, updated.owner_user_id, "proposal_created")
		_, cerr2 := end_uow(svc, &u, true)
		if cerr2.code != .None do return {}, false, cerr2
		return updated, true, domain.Domain_Error{}
	}

	existing_tasks, _ := iface.taskchain_list_tasks_by_chain(svc.repo, chain_id, owner_user_id)
	if len(specs) == 0 && len(existing_tasks) == 0 {
		_, _ = end_uow(svc, &u, false)
		return {}, false, domain.domain_error(.Validation_Failed, "proposal must include at least one task")
	}
	if valid_b, berr := validate_brief_for_publish(svc, chain, existing_tasks, specs); !valid_b {
		_, _ = end_uow(svc, &u, false)
		return {}, false, berr
	}
	if input.auto_approve {
		updated, _, ap_ok, ap_err := approve_and_publish_chain_in_uow(svc, &u, chain, actor, specs, "auto-approved")
		_, cerr2 := end_uow(svc, &u, ap_ok)
		if !ap_ok do return {}, false, ap_err
		if cerr2.code != .None do return {}, false, cerr2
		return updated, true, domain.Domain_Error{}
	}
	now := platform.clock_now(svc.clock)
	p := json_begin()
	json_str(&p, "status", "pending")
	if strings.trim_space(input.kind) != "" do json_str(&p, "kind", strings.trim_space(input.kind))
	json_str(&p, "proposed_by_kind", actor.kind)
	json_str(&p, "proposed_by_id", actor.id)
	json_str(&p, "proposed_by", actor.id)
	json_str(&p, "proposed_at", now)
	if strings.trim_space(input.rationale) != "" do json_str(&p, "rationale", strings.trim_space(input.rationale))
	if strings.trim_space(input.alternative) != "" do json_str(&p, "alternative", strings.trim_space(input.alternative))
	json_int(&p, "created_at_ms", now_ms(svc.clock))
	if tasks_raw != "" {
		json_raw(&p, "tasks", tasks_raw)
	} else {
		json_raw(&p, "tasks", "[]")
	}
	chain.defaults_json = set_chain_proposal_json(chain.defaults_json, json_end(&p))
	chain.updated_at = now
	updated, sok, serr := iface.taskchain_save_chain(svc.repo, chain)
	if !sok {
		_, _ = end_uow(svc, &u, false)
		return {}, false, serr
	}
	effect_publish_chain(&u, updated.chain_id, updated.owner_user_id, "proposal_created")
	_, cerr2 := end_uow(svc, &u, true)
	if cerr2.code != .None do return {}, false, cerr2
	return updated, true, domain.Domain_Error{}
}

// chain_proposal_decide approves (`decision == "approve"`) or rejects
// (`decision == "reject"`) the pending proposal on `chain`. On approve, the
// chain and all draft/proposed tasks and dependency edges are published and
// materialized atomically in one UoW and `proposal` is cleared.
chain_proposal_decide :: proc(svc: ^Service, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID, actor: Actor, decision: string, note: string = "") -> (domain.Task_Chain, []domain.Task, bool, domain.Domain_Error) {
	if decision != "approve" && decision != "reject" {
		return {}, nil, false, domain.domain_error(.Validation_Failed, "decision must be approve or reject")
	}
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, nil, false, uerr
	chain, cok, _ := iface.taskchain_get_chain(svc.repo, chain_id)
	if !cok || chain.owner_user_id != owner_user_id {
		_, _ = end_uow(svc, &u, false)
		return {}, nil, false, domain.domain_error(.Not_Found, "chain not found")
	}
	if chain.status != .Active {
		_, _ = end_uow(svc, &u, false)
		return {}, nil, false, domain.domain_error(.Conflict, "chain must be active")
	}
	if _, authorized, auth_err := work_control_chain(svc, owner_user_id, actor, chain_id); !authorized {
        _, _ = end_uow(svc, &u, false)
        return {}, nil, false, auth_err
    }
	prop := strings.trim_space(chain_proposal_json(chain))
	if prop == "" || prop == "null" || prop == "{}" {
		_, _ = end_uow(svc, &u, false)
		return {}, nil, false, domain.domain_error(.Conflict, "chain has no pending proposal")
	}
	now := platform.clock_now(svc.clock)
	if decision == "reject" {
		chain.defaults_json = set_chain_proposal_json(chain.defaults_json, "")
		chain.updated_at = now
		updated, sok, serr := iface.taskchain_save_chain(svc.repo, chain)
		if !sok {
			_, _ = end_uow(svc, &u, false)
			return {}, nil, false, serr
		}
		effect_publish_chain(&u, updated.chain_id, updated.owner_user_id, "proposal_rejected")
		effect_notify_coordinator(svc, &u, chain_id, owner_user_id, "proposal_decided", fmt.tprintf("[taskv2] proposal_decided: chain %s proposal rejected%s%s", chain_id, " — " if strings.trim_space(note) != "" else "", strings.trim_space(note)))
		_, cerr2 := end_uow(svc, &u, true)
		if cerr2.code != .None do return {}, nil, false, cerr2
		return updated, nil, true, domain.Domain_Error{}
	}

	prop_kind := strings.trim_space(jsonx.extract_string(prop, "kind", "", true, context.temp_allocator))
	prop_wf := strings.trim_space(jsonx.extract_string(prop, "workflow", "", true, context.temp_allocator))
	if prop_wf == "" do prop_wf = strings.trim_space(jsonx.extract_string(prop, "template", "", true, context.temp_allocator))
	if prop_kind == "workflow_run" && prop_wf != "" {
		prop_inputs, has_in := jsonx.extract_raw_object(prop, "inputs", true, context.temp_allocator)
		if !has_in || strings.trim_space(prop_inputs) == "" do prop_inputs = "{}"
		updated, ap_ok, ap_err := workflow_proposal_run_in_uow(svc, &u, chain, actor, prop_wf, prop_inputs)
		_, cerr2 := end_uow(svc, &u, ap_ok)
		if !ap_ok do return {}, nil, false, ap_err
		if cerr2.code != .None do return {}, nil, false, cerr2
		mat_tasks, _ := iface.taskchain_list_tasks_by_chain(svc.repo, updated.chain_id, owner_user_id)
		return updated, mat_tasks, true, domain.Domain_Error{}
	}

	specs: []Proposed_Task_Item = nil
	if tasks_arr, has_tasks := jsonx.extract_raw_array(prop, "tasks", true, context.temp_allocator); has_tasks && strings.trim_space(tasks_arr) != "[]" && strings.trim_space(tasks_arr) != "" {
		parsed_specs, pok, perr := parse_proposed_tasks_json(tasks_arr)
		if !pok {
			_, _ = end_uow(svc, &u, false)
			if perr.code != .None do return {}, nil, false, perr
			return {}, nil, false, domain.domain_error(.Validation_Failed, "proposal tasks are invalid")
		}
		specs = parsed_specs
	}
	existing_tasks, _ := iface.taskchain_list_tasks_by_chain(svc.repo, chain_id, owner_user_id)
	if len(specs) == 0 && len(existing_tasks) == 0 {
		_, _ = end_uow(svc, &u, false)
		return {}, nil, false, domain.domain_error(.Validation_Failed, "proposal has no tasks")
	}

	updated, out, ap_ok, ap_err := approve_and_publish_chain_in_uow(svc, &u, chain, actor, specs, note)
	_, cerr2 := end_uow(svc, &u, ap_ok)
	if !ap_ok do return {}, nil, false, ap_err
	if cerr2.code != .None do return {}, nil, false, cerr2
	return updated, out, true, domain.Domain_Error{}
}

Proposed_Task_Item :: struct {
	id:          string,
	symbolic_id: string,
	title:       string,
	description: string,
	priority:    string,
	brief_json:  string,
	depends_on:  []domain.Task_ID,
	// explicit_brief: the spec carried its own `brief` object (schema-checked);
	// otherwise brief_json was synthesized from the shorthand fields.
	explicit_brief: bool,
}

@(private = "file")
parse_proposed_tasks_json :: proc(raw_array: string) -> ([]Proposed_Task_Item, bool, domain.Domain_Error) {
	items, ok := split_json_array_objects(raw_array, context.temp_allocator)
	if !ok do return nil, false, domain.domain_error(.Validation_Failed, "tasks must be a JSON array of objects")
	out := make([dynamic]Proposed_Task_Item, 0, len(items), context.temp_allocator)
	for item in items {
		title := strings.trim_space(jsonx.extract_string(item, "title", "", true, context.temp_allocator))
		if title == "" do return nil, false, domain.domain_error(.Validation_Failed, "each proposed task requires a title")
		desc := strings.trim_space(jsonx.extract_string(item, "description", "", true, context.temp_allocator))
		prio := strings.trim_space(jsonx.extract_string(item, "priority", "p2", true, context.temp_allocator))
		brief_raw, has_brief := jsonx.extract_raw_object(item, "brief", true, context.temp_allocator)
		if !has_brief || strings.trim_space(brief_raw) == "" {
			goal := strings.trim_space(jsonx.extract_string(item, "goal", title, true, context.temp_allocator))
			role := strings.trim_space(jsonx.extract_string(item, "role", "coder", true, context.temp_allocator))
			b := json_begin()
			json_str(&b, "goal", goal)
			if acc_raw, has_acc := jsonx.extract_raw_array(item, "acceptance", true, context.temp_allocator); has_acc {
				json_raw(&b, "acceptance", acc_raw)
			} else if goal != "" {
				ab := strings.builder_make(context.temp_allocator)
				strings.write_string(&ab, `["`)
				contracts.write_json_string(&ab, goal)
				strings.write_string(&ab, `"]`)
				json_raw(&b, "acceptance", strings.to_string(ab))
			} else {
				json_raw(&b, "acceptance", "[]")
			}
			json_str(&b, "role", role)
			brief_raw = json_end(&b)
		} else {
			brief_raw, _ = strip_removed_verify_keys(brief_raw)
		}
		raw_id := strings.trim_space(jsonx.extract_string(item, "id", "", true, context.temp_allocator))
		if raw_id == "" do raw_id = strings.trim_space(jsonx.extract_string(item, "task_id", "", true, context.temp_allocator))
		deps_strs := jsonx.extract_string_array(item, "depends_on", true, context.temp_allocator)
		deps := make([dynamic]domain.Task_ID, 0, len(deps_strs), context.temp_allocator)
		for d in deps_strs {
			trimmed := strings.trim_space(d)
			if trimmed != "" do append(&deps, domain.Task_ID(trimmed))
		}
		explicit_id := raw_id
		append(&out, Proposed_Task_Item{
			id          = explicit_id,
			symbolic_id = raw_id,
			title       = title,
			description = desc,
			priority    = prio,
			brief_json  = brief_raw,
			depends_on  = deps[:],
			explicit_brief = has_brief && strings.trim_space(brief_raw) != "",
		})
	}
	return out[:], true, domain.Domain_Error{}
}

split_json_array_objects :: proc(raw_array: string, allocator := context.temp_allocator) -> ([]string, bool) {
	s := strings.trim_space(raw_array)
	if len(s) < 2 || s[0] != '[' || s[len(s) - 1] != ']' do return nil, false
	out := make([dynamic]string, allocator)
	i := 1
	n := len(s) - 1
	for i < n {
		for i < n && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r' || s[i] == ',') do i += 1
		if i >= n do break
		if s[i] != '{' do return nil, false
		start := i
		depth := 0
		in_str := false
		esc := false
		for i < n {
			ch := s[i]
			if in_str {
				if esc {
					esc = false
				} else if ch == '\\' {
					esc = true
				} else if ch == '"' {
					in_str = false
				}
			} else {
				switch ch {
				case '"': in_str = true
				case '{': depth += 1
				case '}':
					depth -= 1
					if depth == 0 {
						append(&out, s[start:i + 1])
						i += 1
						break
					}
				}
			}
			if depth == 0 do break
			i += 1
		}
		if depth != 0 do return nil, false
	}
	return out[:], true
}

// require_change_reason (REQ-SOLO-8, every reviewer): a request_changes says
// what to change — a summary or at least one finding. Findings first, then the
// verdict.
require_change_reason :: proc(input: Review_Input) -> domain.Domain_Error {
	if input.verdict != "request_changes" do return {}
	if strings.trim_space(input.summary) != "" do return {}
	f := strings.trim_space(input.findings_json)
	if f != "" && f != "[]" && f != "null" do return {}
	return domain.domain_error(.Validation_Failed, "request_changes needs a summary or findings: post your findings first, then the verdict")
}
