package taskv2

import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// This is a target operation, not an arbitrary task/fleet patch. All fields
// identifying the observation are required, including an empty assignment.
Placement_Recovery_Input :: struct {
	expected_attempt:       int,
	phase:                  string,
	agent_id:               string,
	role:                   string,
	fingerprint:            string,
	configuration:          string,
	expected_assignment:    string,
	action:                 string, // change_bridge | change_assignee | change_reviewer
	bridge_id:              string,
	replacement_agent_id:   string,
	scope:                  string, // ticket | chain_fleet
}

// Read the current attempt only. Consumers must not infer authorization from
// the snapshot; repair below recollects under the native transaction lock.
placement_failures :: proc(svc: ^Service, task: domain.Task) -> ([]Placement_Failure, domain.Domain_Error) {
	facets, err := iface.taskchain_list_facets_by_task(svc.repo, task.task_id, task.owner_user_id)
	if err.code != .None do return nil, err
	for f in facets {
		if f.attempt_no != task.attempt_no || f.kind != FACET_PLACEMENT do continue
		body: struct {schema_version: int, failures: []Placement_Failure}
		if json.unmarshal(transmute([]u8)f.body_json, &body, allocator = context.temp_allocator) != nil || body.schema_version != 1 {
			return nil, domain.domain_error(.Internal_Error, "invalid placement snapshot")
		}
		return body.failures, {}
	}
	return nil, {}
}

recover_placement :: proc(svc: ^Service, auth: contracts.Auth_Context, task_id: domain.Task_ID, input: Placement_Recovery_Input) -> (domain.Task, bool, domain.Domain_Error) {
	if !contracts.is_user_auth(auth) do return {}, false, domain.domain_error(.Forbidden, "only the owner may repair placement")
	if svc == nil || svc.repo == nil do return {}, false, domain.domain_error(.Internal_Error, "task engine unavailable")
	u, ok, err := begin_uow(svc)
	if !ok do return {}, false, err
	task, repaired, rerr := recover_placement_in_uow(svc, &u, auth, task_id, input)
	committed, cerr := end_uow(svc, &u, repaired)
	if !repaired do return {}, false, rerr
	if !committed do return {}, false, cerr
	if fresh, found, _ := iface.taskchain_get_task(svc.repo, task_id); found do task = fresh
	return task, true, {}
}

@(private = "file")
recover_placement_in_uow :: proc(svc: ^Service, u: ^Uow, auth: contracts.Auth_Context, task_id: domain.Task_ID, input: Placement_Recovery_Input) -> (domain.Task, bool, domain.Domain_Error) {
	task, found, err := iface.taskchain_get_task(svc.repo, task_id)
	if !found do return {}, false, err
	if string(task.owner_user_id) != auth.user_id do return {}, false, domain.domain_error(.Not_Found, "task not found")
	if task.workflow_run_id != "" || task.stage_key != "" do return {}, false, domain.domain_error(.Conflict, "workflow placement must be changed through workflow configuration")
	if input.fingerprint == "" || input.configuration == "" || input.role == "" || (input.phase != "work" && input.phase != "review") {
		return {}, false, domain.domain_error(.Validation_Failed, "placement target and observation guards are required")
	}
	if task.attempt_no != input.expected_attempt do return {}, false, domain.domain_error(.Conflict, "placement attempt changed; refresh the card")
	assignment := brief_assignee(task.brief_json) if input.phase == "work" else input.agent_id
	if assignment != input.expected_assignment do return {}, false, domain.domain_error(.Conflict, "assignment changed; refresh the card")
	chain, cok, cerr := iface.taskchain_get_chain(svc.repo, task.chain_id)
	if !cok do return {}, false, cerr
	ctx, loaded, lerr := load_match_context(svc, chain)
	if !loaded do return {}, false, lerr
	defer destroy_match_context(&ctx)
	worker := input.phase == "work"
	// Check before collection, which correctly excludes already leased targets,
	// so an owner receives the checkpoint guidance rather than a vague conflict.
	for l in ctx.leases {
		if l.task_id != task.task_id do continue
		if worker && l.kind == domain.LEASE_KIND_WORK do return {}, false, domain.domain_error(.Conflict, "worker lease is live; use the checkpoint/hold workflow")
		if !worker && l.kind == domain.LEASE_KIND_REVIEW {
			inst, iok, ierr := iface.agent_get_instance(svc.agents, l.holder_instance_id)
			if !iok do return {}, false, ierr
			if inst.agent_id == input.agent_id do return {}, false, domain.domain_error(.Conflict, "reviewer lease is live; use the checkpoint/hold workflow")
		}
	}
	failures, ferr := collect_placement_failures(svc, &ctx, task)
	if ferr.code != .None do return {}, false, ferr
	current := false
	current_source := ""
	for f in failures {
		if f.phase == input.phase && f.agent_id == input.agent_id && f.role == input.role && f.fingerprint == input.fingerprint && f.configuration == input.configuration { current = true; current_source = f.source; break }
	}
	if !current do return {}, false, domain.domain_error(.Conflict, "placement failure changed or resolved; refresh the card")
	scope := "ticket" if worker || input.action != "change_bridge" else "chain_fleet"
	if input.scope != scope do return {}, false, domain.domain_error(.Validation_Failed, "confirm the explicit ticket or chain_fleet scope")
	fleet, has_fleet := fleet_row_for_agent(ctx.fleets[:], input.agent_id)
	actor := actor_from_auth(auth)
	switch input.action {
	case "change_bridge":
		if current_source == "coordinator" do return {}, false, domain.domain_error(.Conflict, "coordinator placement belongs to its instance; change the ticket assignee or configure the coordinator")
		if input.bridge_id == "" do return {}, false, domain.domain_error(.Validation_Failed, "an enrolled bridge is required")
		if !has_fleet do return {}, false, domain.domain_error(.Conflict, "configure this agent in the chain fleet before changing its bridge")
		target, owned, target_err := iface.agent_get(svc.agents, input.agent_id)
		if target_err.code != .None || !owned || target.owner_user_id != task.owner_user_id || target.state != .Active do return {}, false, domain.domain_error(.Validation_Failed, "target must be an owned active durable agent")
		if worker { task.bridge_id = input.bridge_id } else { fleet.bridge_id = input.bridge_id }
		p, resolved := resolve_placement(&ctx, task, fleet, worker)
		if reason, message := placement_problem(svc, &ctx, p, resolved, fleet.agent_id); reason != "" do return {}, false, domain.domain_error(.Validation_Failed, message)
		if !worker {
			fleet.updated_at = platform.clock_now(svc.clock)
			if _, e := iface.taskchain_upsert_fleet(svc.repo, fleet); e.code != .None do return {}, false, e
		}
	case "change_assignee", "change_reviewer":
		if (worker && input.action != "change_assignee") || (!worker && input.action != "change_reviewer") do return {}, false, domain.domain_error(.Validation_Failed, "action does not match placement phase")
		if !worker && input.role != NAMED_REVIEW_ROLE do return {}, false, domain.domain_error(.Conflict, "role reviewers are configured in the chain fleet; keep the role requirement")
		id := strings.trim_space(input.replacement_agent_id)
		if !strings.has_prefix(id, "agt_") || id == input.agent_id do return {}, false, domain.domain_error(.Validation_Failed, "choose a different durable agent")
		agent, exists, aerr := iface.agent_get(svc.agents, id)
		if !exists || agent.owner_user_id != task.owner_user_id || agent.state != .Active do return {}, false, domain.domain_error(.Validation_Failed, "replacement must be an owned active durable agent")
		if aerr.code != .None do return {}, false, aerr
		replacement, eligible := fleet_row_for_agent(ctx.fleets[:], id)
		if !eligible || (worker && !fleet_row_has_role(replacement, domain.FLEET_ROLE_WORKER)) || (!worker && !fleet_row_has_role(replacement, domain.FLEET_ROLE_REVIEWER) && !fleet_row_has_role(replacement, FLEET_ROLE_NAMED_REVIEWER)) {
			return {}, false, domain.domain_error(.Validation_Failed, "replacement must have an eligible chain fleet role; configure the fleet first")
		}
		if (worker && domain.fleet_role_paused(replacement, domain.FLEET_ROLE_WORKER)) || (!worker && review_role_paused(replacement, NAMED_REVIEW_ROLE)) do return {}, false, domain.domain_error(.Validation_Failed, "replacement fleet role is paused")
		if !worker {
			if holder := last_attempt_holder(svc, task); holder != "" {
				if author, known, _ := iface.agent_get_instance(svc.agents, holder); known && author.agent_id == id do return {}, false, domain.domain_error(.Validation_Failed, "the author cannot review its own work")
			}
		}
		p, resolved := resolve_placement(&ctx, task, replacement, worker)
		if reason, message := placement_problem(svc, &ctx, p, resolved, id); reason != "" do return {}, false, domain.domain_error(.Validation_Failed, message)
		value, jerr := json.parse_string(task.brief_json, allocator = context.temp_allocator)
		root, object := value.(json.Object)
		if jerr != nil || !object do return {}, false, domain.domain_error(.Internal_Error, "invalid task brief")
		if worker {
			root["assignee"] = json.String(id)
		} else {
			named := brief_named_reviewers(task.brief_json, context.temp_allocator)
			items := make(json.Array, context.temp_allocator)
			for reviewer in named {
				if reviewer == id do return {}, false, domain.domain_error(.Validation_Failed, "replacement is already a named reviewer")
				append(&items, json.String(id if reviewer == input.agent_id else reviewer))
			}
			root["reviewers"] = items
		}
		encoded, e := json.marshal(root, allocator = context.temp_allocator)
		if e != nil do return {}, false, domain.domain_error(.Internal_Error, "could not encode repaired brief")
		task.brief_json = string(encoded)
	case:
		return {}, false, domain.domain_error(.Validation_Failed, "unsupported placement recovery action")
	}
	task.updated_at = platform.clock_now(svc.clock)
	if _, saved, e := iface.taskchain_save_task(svc.repo, task); !saved do return {}, false, e
	payload := json_begin()
	json_raw(&payload, "fields", `["placement"]`)
	json_str(&payload, "action", input.action)
	json_str(&payload, "scope", input.scope)
	json_str(&payload, "target_agent_id", input.agent_id)
	json_str(&payload, "target_role", input.role)
	json_str(&payload, "fingerprint", input.fingerprint)
	json_str(&payload, "bridge_id", input.bridge_id)
	json_str(&payload, "replacement_agent_id", input.replacement_agent_id)
	if _, _, recorded, e := record_event(svc, u, task, actor, EV_UPDATED, json_end(&payload)); !recorded do return {}, false, e
	if input.action == "change_reviewer" {
		if regated, e := regate_after_reviewer_change(svc, u, task, actor); !regated do return {}, false, e
	}
	// Do not use fleet_changed(agent_id): it explicitly resets idle instances
	// for Start recovery. Placement repair must retain user-stop consent.
	if matched, e := after_chain_change(svc, u, task.chain_id, task.owner_user_id, .Task_Updated); !matched do return {}, false, e
	effect_publish_chain(u, task.chain_id, task.owner_user_id, "updated")
	return task, true, {}
}
