package taskv2

import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Context pack (plan §4c) — M1 SKELETON. The hub builds the structure; the
// bridge (M3) decrypts vault tokens, applies the 8 k-token cap after decryption
// and writes <run_dir>/TASK.md. Nothing here is truncated: the brief and the
// findings are capped at write time, and the previous-attempt sections are what
// the bridge trims first when it must.
//
// Shape (JSON object, all keys always present):
//   {
//     "version": 1,
//     "lease": {lease_id, kind, review_role, attempt_no, max_attempts, review_round,
//               granted_at, expires_at, hard_deadline_at, delivery,
//               placement: {bridge_id, provider, model}},
//     "task":  {task_id, title, description, priority, state, kind, brief},
//     "chain": {chain_id, title, kind, summary},
//     "previous_attempt": {attempt_no, outcome, handoff, vcs} | null,
//     "why": "first_grant" | "retry_after_expiry" | "changes_requested" | "handoff" | "reopened",
//     "protocol": {heartbeat_ttl_seconds, hard_cap_seconds, verbs:[…]}
//   }
PACK_VERSION :: 1

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

	o := json_begin()
	json_int(&o, "version", PACK_VERSION)

	l := json_begin()
	json_str(&l, "lease_id", lease.lease_id)
	json_str(&l, "kind", lease.kind)
	json_str(&l, "review_role", lease.review_role)
	json_int(&l, "attempt_no", i64(lease.attempt_no))
	max_attempts := brief_max_attempts(task.brief_json)
	if max_attempts <= 0 do max_attempts = domain.TASK_MAX_ATTEMPTS
	json_int(&l, "max_attempts", i64(max_attempts))
	json_int(&l, "review_round", i64(view.review_rounds))
	json_str(&l, "granted_at", lease.granted_at)
	json_str(&l, "expires_at", lease.expires_at)
	json_str(&l, "hard_deadline_at", lease.hard_deadline_at)
	json_str(&l, "delivery", lease.delivery)
	p := json_begin()
	json_str(&p, "bridge_id", lease.bridge_id)
	json_str(&p, "provider", lease.provider if lease.provider != "" else inst.provider)
	json_str(&p, "model", lease.model if lease.model != "" else inst.model)
	json_raw(&l, "placement", json_end(&p))
	json_raw(&o, "lease", json_end(&l))

	t := json_begin()
	json_str(&t, "task_id", string(task.task_id))
	json_str(&t, "title", task.title)
	json_str(&t, "description", task.description)
	json_str(&t, "priority", domain.task_priority_string(task.priority))
	json_str(&t, "state", domain.task_state_string(task.state))
	json_str(&t, "kind", domain.task_kind_string(task.kind))
	json_raw(&t, "brief", task.brief_json if strings.has_prefix(strings.trim_space(task.brief_json), "{") else "{}")
	json_raw(&o, "task", json_end(&t))

	c := json_begin()
	json_str(&c, "chain_id", string(chain.chain_id))
	json_str(&c, "title", chain.title)
	json_str(&c, "kind", chain.kind)
	summary := ""
	if s, sok, _ := iface.taskchain_get_chain_summary(svc.repo, chain.chain_id, chain.owner_user_id); sok do summary = s.body
	json_str(&c, "summary", summary)
	json_raw(&o, "chain", json_end(&c))

	json_raw(&o, "previous_attempt", previous_attempt_json(svc, task, lease, pre.last_release == .Handoff))
	json_str(&o, "why", pack_why(pre, lease))

	proto := json_begin()
	json_int(&proto, "heartbeat_ttl_seconds", LEASE_TTL_SECONDS)
	json_int(&proto, "hard_cap_seconds", LEASE_HARD_CAP_SECONDS)
	json_raw(&proto, "verbs", `["lease next","lease heartbeat","lease submit","lease handoff","lease block","review post","task fetch","task comment"]`)
	json_raw(&o, "protocol", json_end(&proto))
	return json_end(&o)
}

// previous_attempt_json: the last closed attempt's outcome plus its handoff and
// vcs facets (verbatim), or "null" on a first grant.
@(private = "file")
previous_attempt_json :: proc(svc: ^Service, task: domain.Task, lease: domain.Task_Lease, handoff_continuation: bool) -> string {
	attempts, err := iface.taskchain_list_attempts_by_task(svc.repo, task.task_id, task.owner_user_id)
	if err.code != .None do return "null"
	prev := domain.Task_Attempt{}
	found := false
	for a in attempts {
		if a.attempt_no > lease.attempt_no do continue
		// the current (open) attempt is "previous" only when it was handed off
		if a.attempt_no == lease.attempt_no && lease.kind == domain.LEASE_KIND_WORK && !handoff_continuation do continue
		if !found || a.attempt_no > prev.attempt_no { prev = a; found = true }
	}
	if !found do return "null"
	o := json_begin()
	json_int(&o, "attempt_no", i64(prev.attempt_no))
	json_str(&o, "outcome", prev.outcome)
	json_str(&o, "holder_instance_id", prev.holder_instance_id)
	handoff := "null"
	vcs := "null"
	if facets, ferr := iface.taskchain_list_facets_by_task(svc.repo, task.task_id, task.owner_user_id); ferr.code == .None {
		for f in facets {
			if f.attempt_no != prev.attempt_no || !strings.has_prefix(strings.trim_space(f.body_json), "{") do continue
			switch f.kind {
			case "handoff": handoff = f.body_json
			case "vcs": vcs = f.body_json
			}
		}
	}
	json_raw(&o, "handoff", handoff)
	json_raw(&o, "vcs", vcs)
	return json_end(&o)
}

@(private = "file")
pack_why :: proc(view: Task_View, lease: domain.Task_Lease) -> string {
	if lease.kind == domain.LEASE_KIND_REVIEW do return "review"
	#partial switch view.last_release {
	case .Expired: return "retry_after_expiry"
	case .Changes_Requested: return "changes_requested"
	case .Handoff: return "handoff"
	case .Reopened: return "reopened"
	case .Blocked: return "answered"
	}
	return "first_grant"
}
