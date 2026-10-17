package taskv2

import "core:strings"
import domain "odin_test:hub/domain"
import jsonx "odin_test:lib/jsonx"

// Who must review a task (hybrid review model):
//
//   * brief.reviewers      — agents named on THIS task (a person picks them).
//                            Each owes one review, recorded with role NAMED_REVIEW_ROLE.
//   * brief.review_roles   — optional roles (templates, coordinators). Every
//                            fleet row holding the role owes a review for it.
//
// The author template never reviews its own work. An agent that owes several
// pairs on a task gets ONE review lease covering all of them (lease.review_role
// is the comma-joined list) and its verdict is recorded once per pair, so the
// gate stays a strict AND over pairs.

// NAMED_REVIEW_ROLE is the review row / lease role of a reviewer named on the task.
NAMED_REVIEW_ROLE :: "named"

// FLEET_ROLE_NAMED_REVIEWER marks a fleet row created only so a named reviewer
// can be placed and launched. Tasks never list it in review_roles, so holding it
// does not pull the agent into role-based reviews of other tasks.
FLEET_ROLE_NAMED_REVIEWER :: "named-reviewer"

Review_Pair :: struct {
	agent_id: string,
	role:     string,
}

// brief_named_reviewers: brief.reviewers (agent template ids), trimmed, no blanks.
brief_named_reviewers :: proc(brief_json: string, allocator := context.allocator) -> [dynamic]string {
	raw := jsonx.extract_string_array(brief_json, "reviewers", true, context.temp_allocator)
	out := make([dynamic]string, allocator)
	for r in raw {
		id := strings.trim_space(r)
		if id == "" do continue
		dup := false
		for o in out do if o == id { dup = true; break }
		if !dup do append(&out, strings.clone(id, allocator))
	}
	return out
}

// required_review_pairs lists every (agent, role) that must approve the task's
// current attempt: role holders for each brief.review_roles entry, then each
// named reviewer. The author template is excluded. Temp-allocated.
required_review_pairs :: proc(task: domain.Task, fleets: []domain.Task_Chain_Fleet, author_agent: string) -> []Review_Pair {
	out := make([dynamic]Review_Pair, context.temp_allocator)
	add :: proc(out: ^[dynamic]Review_Pair, agent_id, role: string) {
		for p in out^ do if p.agent_id == agent_id && p.role == role do return
		append(out, Review_Pair{agent_id = agent_id, role = role})
	}
	for role in brief_review_roles(task.brief_json, context.temp_allocator) {
		if role == NAMED_REVIEW_ROLE || role == FLEET_ROLE_NAMED_REVIEWER do continue
		for f in fleets {
			if !fleet_row_has_role(f, role) do continue
			if author_agent != "" && f.agent_id == author_agent do continue
			add(&out, f.agent_id, role)
		}
	}
	for agent_id in brief_named_reviewers(task.brief_json, context.temp_allocator) {
		if author_agent != "" && agent_id == author_agent do continue
		add(&out, agent_id, NAMED_REVIEW_ROLE)
	}
	return out[:]
}

// owed_review_roles: the roles `agent_id` still owes on the current attempt.
owed_review_roles :: proc(pairs: []Review_Pair, reviews: []domain.Task_Review, task: domain.Task, agent_id: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for p in pairs {
		if p.agent_id != agent_id do continue
		if review_needed_from(reviews, task, agent_id, p.role) do append(&out, p.role)
	}
	return out[:]
}

// distinct_review_agents: the agents in `pairs`, in first-seen order.
distinct_review_agents :: proc(pairs: []Review_Pair) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	outer: for p in pairs {
		for a in out do if a == p.agent_id do continue outer
		append(&out, p.agent_id)
	}
	return out[:]
}

// join_review_roles / split_review_roles: the comma-joined lease.review_role.
join_review_roles :: proc(roles: []string) -> string {
	return strings.join(roles, ",", context.temp_allocator)
}

split_review_roles :: proc(lease_role: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for part in strings.split(lease_role, ",", context.temp_allocator) {
		r := strings.trim_space(part)
		if r != "" do append(&out, r)
	}
	return out[:]
}

// fleet_row_for_agent: the agent's fleet row in the chain (named reviewers get
// one via FLEET_ROLE_NAMED_REVIEWER at create/update).
fleet_row_for_agent :: proc(fleets: []domain.Task_Chain_Fleet, agent_id: string) -> (domain.Task_Chain_Fleet, bool) {
	for f in fleets do if f.agent_id == agent_id do return f, true
	return {}, false
}

// review_role_description: what a review role checks, from
// chain.defaults_json.review_roles.<name>.description ("" when unset). A named
// reviewer (NAMED_REVIEW_ROLE) reviews the whole task.
review_role_description :: proc(defaults_json, role: string) -> string {
	if role == NAMED_REVIEW_ROLE do return "You were named as a reviewer of this task: review it as a whole."
	roles_obj, ok := jsonx.extract_raw_object(defaults_json, "review_roles", true, context.temp_allocator)
	if !ok do return ""
	entry, eok := jsonx.extract_raw_object(roles_obj, role, true, context.temp_allocator)
	if !eok do return ""
	return jsonx.extract_string(entry, "description", "", true, context.temp_allocator)
}

// review_roles_pack_json: [{"role","description"}] for every role a review lease
// covers, so the reviewer knows what each role asks it to check.
review_roles_pack_json :: proc(chain: domain.Task_Chain, lease_role: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for role, i in split_review_roles(lease_role) {
		if i > 0 do strings.write_byte(&b, ',')
		o := json_begin()
		json_str(&o, "role", role)
		json_str(&o, "description", review_role_description(chain.defaults_json, role))
		strings.write_string(&b, json_end(&o))
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}
