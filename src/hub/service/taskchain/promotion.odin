package taskchain

import "core:fmt"
import json "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"
import platform "odin_test:hub/platform"
import project "odin_test:hub/service/project"
import agent "odin_test:hub/service/agent"

// Auto-promotion ports the ham-daemon task_recompute_promotions behavior into the
// lean Hub/Bridge split. It runs entirely against durable Hub state on the
// mutation path (no scheduler thread here): when a task's dependencies clear and
// its assignee slot is free, the task advances into the instance's current task
// and the existing runtime-command fan-out wakes the assignee's bridge.
//
// Current-task model (Phase 2, CT-4/CT-5/CT-7):
//   * Every agent instance has AT MOST ONE current task across both roles
//     (R1, R6, R7). An instance can be an assignee (work) on some tasks and a
//     reviewer (review) on others; we pick a single focus.
//   * Selection order per instance: REVIEW wins over WORK (R7); within a pool,
//     priority P0 > P1 > P2 (CT-3); ties break oldest created_at, then task_id.
//   * The chosen WORK task advances Assigned/Queued -> In_Progress and becomes
//     the instance current_task (role = work).
//   * The chosen REVIEW task (a task the instance reviews, sitting In_Validation)
//     becomes the instance current_task (role = review); its status is untouched.
//   * The instance's OTHER unblocked work tasks (Assigned/In_Progress that are not
//     the chosen focus) are demoted to Queued (R2/CT-2) so exactly one work item is
//     active. Blocked, paused, terminal, and validation tasks are left as-is.
//   * When an instance has no eligible focus, its current_task pointer is cleared
//     (CT-5 auto-advance / CT-7 consistency).

// task_is_terminal reports whether a task status is a chain-dependency-clearing
// terminal state.
task_is_terminal :: proc(status: domain.Task_Status) -> bool {
	return status == .Completed || status == .Cancelled
}

// primary_assignee_instance returns the first agent_instance_id in a task's
// assignee ref blob, or "" if the assignee is a user / unresolved.
primary_assignee_instance :: proc(assignee_ref_json: string) -> string {
	instances := extract_instances_from_ref_blob(assignee_ref_json)
	defer delete(instances)
	if len(instances) == 0 do return ""
	return strings.clone(instances[0])
}

// instance_reviews_task reports whether instance_id is a designated reviewer of
// task (either via the task's own reviewer refs or the chain's default reviewer
// refs). An assignee of a task is never treated as its reviewer (an agent cannot
// review its own work), so an instance that is both assignee and reviewer is only
// eligible to WORK the task, not review it.
instance_reviews_task :: proc(task: domain.Task, chain: domain.Task_Chain, instance_id: string) -> bool {
	if instance_id == "" do return false
	if strings.contains(task.assignee_ref_json, instance_id) do return false
	if strings.contains(task.reviewer_refs_json, instance_id) do return true
	if strings.contains(chain.default_reviewer_refs_json, instance_id) do return true
	return false
}

// deps_satisfied_for_task reports whether every dependency parent of task_id has
// reached a terminal (dependent-unblocking) status. Missing parents are treated
// as satisfied (they cannot block), matching the daemon's permissive behavior.
deps_satisfied_for_task :: proc(tasks: []domain.Task, deps: []domain.Task_Dependency, task_id: domain.Task_ID) -> bool {
	for dep in deps {
		if dep.task_id != task_id do continue
		found := false
		for parent in tasks {
			if parent.task_id != dep.depends_on_task_id do continue
			found = true
			if !domain.task_status_unblocks_dependents(parent.status) do return false
			break
		}
		_ = found
	}
	return true
}

work_task_activity_time :: proc(t: domain.Task) -> string {
	if t.started_at > t.updated_at do return t.started_at
	if t.updated_at != "" do return t.updated_at
	return t.started_at
}

// work_task_prefers is the deterministic ordering within a work candidate pool:
//   1. Rework preference: Validated_Not_Good (NGTM feedback) takes precedence over normal actionable work.
//   2. Recent start preference: If multiple in_progress tasks exist for the same agent, the latest started_at/updated_at wins (respecting explicit user starts).
//   3. Priority model (P0 > P1 > P2).
//   4. Active over inactive to prevent unnecessary churn.
//   5. Tie-breaker: earliest created_at, then lexically smallest task_id.
work_task_prefers :: proc(a, b: domain.Task) -> bool {
	a_vng := a.status == .Validated_Not_Good
	b_vng := b.status == .Validated_Not_Good
	if a_vng != b_vng do return a_vng

	a_prog := a.status == .In_Progress
	b_prog := b.status == .In_Progress
	if a_prog && b_prog {
		a_time := work_task_activity_time(a)
		b_time := work_task_activity_time(b)
		if a_time != b_time do return a_time > b_time
	}

	if a.priority != b.priority do return int(a.priority) < int(b.priority)
	if a_prog != b_prog do return a_prog
	if a.created_at != b.created_at do return a.created_at < b.created_at
	return string(a.task_id) < string(b.task_id)
}

task_prefers :: proc(a, b: domain.Task) -> bool {
	return work_task_prefers(a, b)
}

// work_status_is_actionable reports whether a work (assignee) task status is one
// the assignee is expected to act on, making it a candidate for the instance's
// current work focus. Paused is deliberately held; validation/terminal statuses
// belong to the reviewer/coordinator, not the assignee's work queue.
work_status_is_actionable :: proc(status: domain.Task_Status) -> bool {
	return status == .Assigned || status == .Queued || status == .In_Progress || status == .Validated_Not_Good || status == .Finishing || status == .Pausing
}

// work_task_eligible reports whether task is a candidate for instance's current
// WORK focus: published, deps satisfied, and in an actionable work status.
work_task_eligible :: proc(tasks: []domain.Task, deps: []domain.Task_Dependency, task: domain.Task) -> bool {
	if task.publish_state != .Published do return false
	if !work_status_is_actionable(task.status) do return false
	if !deps_satisfied_for_task(tasks, deps, task.task_id) do return false
	return true
}

// instance_has_pending_validation reports whether the given instance has any task
// currently in_validation (i.e. submitted for review but not yet resolved). Used
// as a promotion gate: an assignee should not pick up new work while review is pending.
instance_has_pending_validation :: proc(tasks: []domain.Task, instance_id: string, offline_task_ids: map[domain.Task_ID]bool) -> bool {
	for t in tasks {
		if t.status != .In_Validation do continue
		if offline_task_ids[t.task_id] do continue
		a := primary_assignee_instance(t.assignee_ref_json)
		is_mine := a == instance_id
		delete(a)
		if is_mine do return true
	}
	return false
}

// instance_has_voted reports whether instance_id has already cast a vote on task_id,
// using the pre-loaded votes_by_task map. Used to exclude already-voted tasks from
// the review pool so reviewers stop being focused on tasks they've voted on.
instance_has_voted :: proc(votes_by_task: map[domain.Task_ID][]string, task_id: domain.Task_ID, instance_id: string) -> bool {
	voters, has := votes_by_task[task_id]
	if !has do return false
	for v in voters do if v == instance_id do return true
	return false
}

// promotion_eligible is retained for compatibility with callers/tests that ask
// whether a task can auto-claim into In_Progress right now (published, Assigned,
// deps satisfied). The richer selection lives in recompute_chain_promotions.
promotion_eligible :: proc(tasks: []domain.Task, deps: []domain.Task_Dependency, task: domain.Task) -> bool {
	if task.publish_state != .Published do return false
	if task.status != .Assigned do return false
	if !deps_satisfied_for_task(tasks, deps, task.task_id) do return false
	return true
}

// Instance_Focus is the resolved current-task decision for one instance.
Instance_Focus :: struct {
	task_id: domain.Task_ID,
	role:    domain.Current_Task_Role,
}

// fleet_capacity_for_agent queries the configured capacity for (chain_id, agent_id), defaulting to 1.
fleet_capacity_for_agent :: proc(fleets: []domain.Task_Chain_Fleet, agent_id: string) -> int {
	for f in fleets {
		if f.agent_id == agent_id do return f.capacity
	}
	return 1
}

// fleet_provider_model_for_agent queries the configured provider/model for
// (chain_id, agent_id); "" means inherit the standard resolution order.
fleet_provider_model_for_agent :: proc(fleets: []domain.Task_Chain_Fleet, agent_id: string) -> (string, string) {
	for f in fleets {
		if f.agent_id == agent_id do return f.provider, f.model
	}
	return "", ""
}

task_effective_bridge :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, task: domain.Task) -> (string, domain.Project_ID) {
	if service == nil do return task.bridge_id, domain.Project_ID("")

	bridge_id := ""
	project_id := domain.Project_ID("")

	if chain.coordinator_agent_instance_id != "" && service.agents != nil {
		if coord, c_ok, _ := iface.agent_get_instance(service.agents, chain.coordinator_agent_instance_id); c_ok {
			bridge_id = coord.bridge_id
			project_id = coord.project_id
		}
	}
	if bridge_id == "" && service.agents != nil && service.repo != nil {
		if members, m_err := iface.taskchain_list_members_by_chain(service.repo, chain.chain_id, chain.owner_user_id); m_err.code == .None {
			defer delete(members)
			for member in members {
				if inst, inst_ok, _ := iface.agent_get_instance(service.agents, member.agent_instance_id); inst_ok && inst.bridge_id != "" {
					bridge_id = inst.bridge_id
					project_id = inst.project_id
					break
				}
			}
		}
	}
	if bridge_id == "" && service.agents != nil {
		if instances, i_err := iface.agent_list_instances_by_owner(service.agents, chain.owner_user_id, 1000, ""); i_err.code == .None {
			defer delete(instances)
			for inst in instances {
				if inst.chain_id == string(chain.chain_id) && inst.bridge_id != "" {
					bridge_id = inst.bridge_id
					project_id = inst.project_id
					break
				}
			}
		}
	}
	if bridge_id == "" && service.repo != nil {
		if dirs, d_err := iface.taskchain_list_directories_by_chain(service.repo, chain.chain_id, chain.owner_user_id); d_err.code == .None {
			defer delete(dirs)
			if len(dirs) > 0 do bridge_id = dirs[0].bridge_id
		}
	}
	if bridge_id == "" && service.agent_service != nil && service.agent_service.bridges != nil {
		if bridges, b_err := iface.bridge_list_by_owner(service.agent_service.bridges, chain.owner_user_id); b_err.code == .None {
			defer delete(bridges)
			if len(bridges) > 0 do bridge_id = bridges[0].bridge_id
		}
	}
	// REQ-TB-3: a non-empty task bridge pin overrides only the effective bridge; the
	// project context resolved above is preserved so JIT instances keep the inherited
	// project_id and receive a per-bridge project_path on the pinned bridge.
	if task.bridge_id != "" do bridge_id = task.bridge_id
	return bridge_id, project_id
}

task_effective_bridge_is_online :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, task: domain.Task) -> (bool, string) {
	bridge_id, _ := task_effective_bridge(service, chain, task)
	if bridge_id == "" do return true, ""
	if service == nil || service.agent_service == nil || service.agent_service.bridges == nil do return true, bridge_id
	bridge, bridge_ok, _ := iface.bridge_get_bridge(service.agent_service.bridges, bridge_id)
	return bridge_ok && bridge.status == .Online, bridge_id
}

// jit_provision_agent_instance launches a new instance of agent_id for the chain
// using agent_service.create_instance and the task's effective bridge.
jit_provision_agent_instance :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, task: domain.Task, agent_id: string, role: string, provider: string, model: string, bridge_models_json: string = "") -> string {
	if service == nil || service.agent_service == nil do return ""

	bridge_id, project_id := task_effective_bridge(service, chain, task)
	if bridge_id == "" do return ""

	selected_provider, selected_model := fleet_model_on_bridge(domain.Task_Chain_Fleet{
		provider = provider, model = model, bridge_models_json = bridge_models_json,
	}, bridge_id)

	// Fleet rows may omit launch settings. Instance creation deliberately requires
	// explicit settings, so resolve those omissions on the selected bridge first.
	launch_provider, launch_model := resolve_fleet_launch_model(service, bridge_id, selected_provider, selected_model)
	defer delete(launch_provider)
	defer delete(launch_model)

	auth := contracts.Auth_Context{
		user_id   = string(chain.owner_user_id),
		kind      = .User_Token,
		bridge_id = bridge_id,
	}
	input := agent.Create_Instance_Input{
		agent_id   = agent_id,
		bridge_id  = bridge_id,
		provider   = launch_provider,
		model       = launch_model,
		chain_id   = string(chain.chain_id),
		project_id = project_id,
	}
	inst, ok, err := agent.create_instance(service.agent_service, auth, input)
	if !ok {
		fmt.eprintfln("[reconcile] JIT provision failed for agent %s on chain %s: %s", agent_id, chain.chain_id, err.message)
		return ""
	}
	return strings.clone(inst.agent_instance_id)
}

fleet_bridge_models_for_agent :: proc(fleets: []domain.Task_Chain_Fleet, agent_id: string) -> string {
	for fleet in fleets { if fleet.agent_id == agent_id do return fleet.bridge_models_json }
	return ""
}

fleet_model_on_bridge :: proc(fleet: domain.Task_Chain_Fleet, bridge_id: string) -> (string, string) {
	if fleet.bridge_models_json != "" {
		entries: map[string]domain.Fleet_Bridge_Model
		if json.unmarshal((transmute([]u8) fleet.bridge_models_json), &entries, allocator = context.temp_allocator) == nil {
			if selection, found := entries[bridge_id]; found { return selection.provider, selection.model }
		}
	}
	return fleet.provider, fleet.model
}

// Catalog order is rank then id, matching the bridge provider-status UI.
// Explicit selections are preserved: an unavailable selection must fail rather
// than silently launch a different provider or model.
resolve_fleet_launch_model :: proc(service: ^Taskchain_Service, bridge_id, provider, model: string) -> (string, string) {
	if provider != "" && model != "" do return strings.clone(provider), strings.clone(model)
	if service == nil || service.agent_service == nil || service.agent_service.providers == nil do return strings.clone(provider), strings.clone(model)
	catalog, err := iface.provider_catalog_list(service.agent_service.providers)
	if err.code != .None do return strings.clone(provider), strings.clone(model)
	defer domain.provider_catalog_destroy(catalog)
	for entry in catalog {
		if entry.state != "active" || (provider != "" && entry.provider != provider) do continue
		for candidate in entry.models {
			if candidate.state != "active" || (model != "" && candidate.model_id != model) do continue
			_, ok, _ := agent.validate_provider_model_intersection(service.agent_service, bridge_id, entry.provider, candidate.model_id)
			if ok do return strings.clone(entry.provider), strings.clone(candidate.model_id)
		}
	}
	return strings.clone(provider), strings.clone(model)
}

instance_is_crashed_or_dead :: proc(service: ^Taskchain_Service, chain_instances: []domain.Agent_Instance, instance_id: string) -> bool {
	if instance_id == "" do return true
	for inst in chain_instances {
		if inst.agent_instance_id == instance_id {
			return inst.runtime_status == "failed" || inst.runtime_status == "terminated"
		}
	}
	if service != nil && service.agents != nil {
		if inst, ok, _ := iface.agent_get_instance(service.agents, instance_id); ok {
			return inst.runtime_status == "failed" || inst.runtime_status == "terminated"
		}
		return true // not found in repo -> dead/orphaned
	}
	return false
}

// allocate_or_jit_worker_instance attempts to resolve an idle or warm-stopped instance
// from the chain, or JIT-provisions a new instance if live count is below fleet capacity.
allocate_or_jit_worker_instance :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, task: domain.Task, target_agent_id: string) -> (string, bool) {
	if service == nil || service.repo == nil do return "", false

	fleets, ferr := iface.taskchain_list_fleets_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	defer if ferr.code == .None do delete(fleets)

	chain_instances := make([dynamic]domain.Agent_Instance)
	defer delete(chain_instances)
	seen_insts := make(map[string]bool)
	defer delete(seen_insts)

	add_chain_inst := proc(seen: ^map[string]bool, list: ^[dynamic]domain.Agent_Instance, inst: domain.Agent_Instance) {
		if inst.agent_instance_id == "" || seen^[inst.agent_instance_id] do return
		seen^[inst.agent_instance_id] = true
		append(list, inst)
	}

	if members, merr := iface.taskchain_list_members_by_chain(service.repo, chain.chain_id, chain.owner_user_id); merr.code == .None {
		defer delete(members)
		for m in members {
			if service.agents != nil {
				if inst, ok, _ := iface.agent_get_instance(service.agents, m.agent_instance_id); ok {
					add_chain_inst(&seen_insts, &chain_instances, inst)
				}
			}
		}
	}
	if chain.coordinator_agent_instance_id != "" && service.agents != nil {
		if coord, ok, _ := iface.agent_get_instance(service.agents, chain.coordinator_agent_instance_id); ok {
			add_chain_inst(&seen_insts, &chain_instances, coord)
		}
	}
	if service.agents != nil {
		if insts, ierr := iface.agent_list_instances_by_owner(service.agents, chain.owner_user_id, 1000, ""); ierr.code == .None {
			defer delete(insts)
			for inst in insts {
				if inst.chain_id == string(chain.chain_id) {
					add_chain_inst(&seen_insts, &chain_instances, inst)
				}
			}
		}
	}

	tasks, terr := iface.taskchain_list_tasks_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	defer if terr.code == .None do delete(tasks)

	offline_task_ids := make(map[domain.Task_ID]bool)
	defer delete(offline_task_ids)
	if terr.code == .None {
		for t in tasks {
			bridge_online, _ := task_effective_bridge_is_online(service, chain, t)
			if !bridge_online {
				offline_task_ids[t.task_id] = true
			}
		}
	}

	busy_instances := make(map[string]bool)
	defer delete(busy_instances)
	busy_keys := make([dynamic]string)
	defer {
		for k in busy_keys do delete(k)
		delete(busy_keys)
	}

	mark_busy := proc(busy: ^map[string]bool, keys: ^[dynamic]string, id: string) {
		if id == "" || busy^[id] do return
		k := strings.clone(id)
		append(keys, k)
		busy^[k] = true
	}

	if terr.code == .None {
		for t in tasks {
			if t.task_id == task.task_id do continue
			if t.status == .In_Progress && !offline_task_ids[t.task_id] {
				a := primary_assignee_instance(t.assignee_ref_json)
				if a != "" {
					if !instance_is_crashed_or_dead(service, chain_instances[:], a) {
						mark_busy(&busy_instances, &busy_keys, a)
					}
					delete(a)
				}
			}
		}
		for inst in chain_instances {
			if instance_has_pending_validation(tasks, inst.agent_instance_id, offline_task_ids) {
				mark_busy(&busy_instances, &busy_keys, inst.agent_instance_id)
			}
		}
		for t in tasks {
			if t.status != .In_Validation do continue
			if offline_task_ids[t.task_id] do continue
			for inst in chain_instances {
				if instance_reviews_task(t, chain, inst.agent_instance_id) {
					mark_busy(&busy_instances, &busy_keys, inst.agent_instance_id)
				}
			}
		}
	}

	capacity := fleet_capacity_for_agent(fleets, target_agent_id)

	idle_instance_id := ""
	warm_stopped_id := ""
	live_count := 0

	for inst in chain_instances {
		if inst.agent_id != target_agent_id do continue
		if inst.runtime_status == "failed" || inst.runtime_status == "terminated" do continue

		if task.bridge_id != "" && inst.bridge_id != task.bridge_id do continue

		if inst.runtime_status == "stopped" {
			if warm_stopped_id == "" && !busy_instances[inst.agent_instance_id] {
				warm_stopped_id = inst.agent_instance_id
			}
			continue
		}

		live_count += 1

		if idle_instance_id == "" && !busy_instances[inst.agent_instance_id] {
			idle_instance_id = inst.agent_instance_id
		}
	}

	chosen_instance_id := idle_instance_id if idle_instance_id != "" else warm_stopped_id

	if chosen_instance_id != "" {
		return strings.clone(chosen_instance_id), true
	} else if live_count < capacity {
		fleet_provider, fleet_model := fleet_provider_model_for_agent(fleets, target_agent_id)
		new_instance_id := jit_provision_agent_instance(service, chain, task, target_agent_id, "worker", fleet_provider, fleet_model, fleet_bridge_models_for_agent(fleets, target_agent_id))
		if new_instance_id != "" {
			return new_instance_id, true
		}
	}

	return "", false
}

// allocate_or_jit_reviewer_instance attempts to resolve an idle or warm-stopped reviewer instance
// from the chain, or JIT-provisions a new reviewer instance if live count is below fleet capacity.
// Ensures candidate reviewer instances exclude the task's primary assignee.
allocate_or_jit_reviewer_instance :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, task: domain.Task, target_agent_id: string) -> (string, bool) {
	if service == nil || service.repo == nil do return "", false

	fleets, ferr := iface.taskchain_list_fleets_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	defer if ferr.code == .None do delete(fleets)

	chain_instances := make([dynamic]domain.Agent_Instance)
	defer delete(chain_instances)
	seen_insts := make(map[string]bool)
	defer delete(seen_insts)

	add_chain_inst := proc(seen: ^map[string]bool, list: ^[dynamic]domain.Agent_Instance, inst: domain.Agent_Instance) {
		if inst.agent_instance_id == "" || seen^[inst.agent_instance_id] do return
		seen^[inst.agent_instance_id] = true
		append(list, inst)
	}

	if members, merr := iface.taskchain_list_members_by_chain(service.repo, chain.chain_id, chain.owner_user_id); merr.code == .None {
		defer delete(members)
		for m in members {
			if service.agents != nil {
				if inst, ok, _ := iface.agent_get_instance(service.agents, m.agent_instance_id); ok {
					add_chain_inst(&seen_insts, &chain_instances, inst)
				}
			}
		}
	}
	if chain.coordinator_agent_instance_id != "" && service.agents != nil {
		if coord, ok, _ := iface.agent_get_instance(service.agents, chain.coordinator_agent_instance_id); ok {
			add_chain_inst(&seen_insts, &chain_instances, coord)
		}
	}
	if service.agents != nil {
		if insts, ierr := iface.agent_list_instances_by_owner(service.agents, chain.owner_user_id, 1000, ""); ierr.code == .None {
			defer delete(insts)
			for inst in insts {
				if inst.chain_id == string(chain.chain_id) {
					add_chain_inst(&seen_insts, &chain_instances, inst)
				}
			}
		}
	}

	tasks, terr := iface.taskchain_list_tasks_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	defer if terr.code == .None do delete(tasks)

	offline_task_ids := make(map[domain.Task_ID]bool)
	defer delete(offline_task_ids)
	if terr.code == .None {
		for t in tasks {
			bridge_online, _ := task_effective_bridge_is_online(service, chain, t)
			if !bridge_online {
				offline_task_ids[t.task_id] = true
			}
		}
	}

	busy_instances := make(map[string]bool)
	defer delete(busy_instances)
	busy_keys := make([dynamic]string)
	defer {
		for k in busy_keys do delete(k)
		delete(busy_keys)
	}

	mark_busy := proc(busy: ^map[string]bool, keys: ^[dynamic]string, id: string) {
		if id == "" || busy^[id] do return
		k := strings.clone(id)
		append(keys, k)
		busy^[k] = true
	}

	if terr.code == .None {
		for t in tasks {
			if t.task_id == task.task_id do continue
			if t.status == .In_Progress && !offline_task_ids[t.task_id] {
				a := primary_assignee_instance(t.assignee_ref_json)
				if a != "" {
					if !instance_is_crashed_or_dead(service, chain_instances[:], a) {
						mark_busy(&busy_instances, &busy_keys, a)
					}
					delete(a)
				}
			}
		}
		for inst in chain_instances {
			if instance_has_pending_validation(tasks, inst.agent_instance_id, offline_task_ids) {
				mark_busy(&busy_instances, &busy_keys, inst.agent_instance_id)
			}
		}
		for t in tasks {
			if t.status != .In_Validation do continue
			if offline_task_ids[t.task_id] do continue
			for inst in chain_instances {
				if instance_reviews_task(t, chain, inst.agent_instance_id) {
					mark_busy(&busy_instances, &busy_keys, inst.agent_instance_id)
				}
			}
		}
	}

	capacity := fleet_capacity_for_agent(fleets, target_agent_id)

	assignee_id := primary_assignee_instance(task.assignee_ref_json)
	defer if assignee_id != "" do delete(assignee_id)

	idle_reviewer_id := ""
	warm_stopped_reviewer_id := ""
	live_count := 0

	for inst in chain_instances {
		if inst.agent_id != target_agent_id do continue
		if assignee_id != "" && inst.agent_instance_id == assignee_id do continue
		if inst.runtime_status == "failed" || inst.runtime_status == "terminated" do continue

		if task.bridge_id != "" && inst.bridge_id != task.bridge_id do continue

		if inst.runtime_status == "stopped" {
			if warm_stopped_reviewer_id == "" && !busy_instances[inst.agent_instance_id] && !strings.contains(task.reviewer_refs_json, inst.agent_instance_id) {
				warm_stopped_reviewer_id = inst.agent_instance_id
			}
			continue
		}

		live_count += 1

		if idle_reviewer_id == "" && !busy_instances[inst.agent_instance_id] && !strings.contains(task.reviewer_refs_json, inst.agent_instance_id) {
			idle_reviewer_id = inst.agent_instance_id
		}
	}

	chosen_reviewer_id := idle_reviewer_id if idle_reviewer_id != "" else warm_stopped_reviewer_id

	if chosen_reviewer_id != "" {
		return strings.clone(chosen_reviewer_id), true
	} else if live_count < capacity {
		fleet_provider, fleet_model := fleet_provider_model_for_agent(fleets, target_agent_id)
		new_instance_id := jit_provision_agent_instance(service, chain, task, target_agent_id, "reviewer", fleet_provider, fleet_model, fleet_bridge_models_for_agent(fleets, target_agent_id))
		if new_instance_id != "" {
			return new_instance_id, true
		}
	}

	return "", false
}

// dynamic_fleet_schedule acts as a dynamic scheduler for tasks with declarative agent_id refs.
// Actionable tasks targeting agent_id are assigned to idle warm pool instances or JIT-provisioned
// up to the chain's fleet capacity. Saturated tasks remain queued in FIFO/priority order.
dynamic_fleet_schedule :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, tasks: []domain.Task, deps: []domain.Task_Dependency, offline_task_ids: map[domain.Task_ID]bool) -> bool {
	if service == nil || service.repo == nil do return false

	fleets, ferr := iface.taskchain_list_fleets_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	defer if ferr.code == .None do delete(fleets)

	chain_instances := make([dynamic]domain.Agent_Instance)
	defer delete(chain_instances)
	seen_insts := make(map[string]bool)
	defer delete(seen_insts)

	add_chain_inst := proc(seen: ^map[string]bool, list: ^[dynamic]domain.Agent_Instance, inst: domain.Agent_Instance) {
		if inst.agent_instance_id == "" || seen^[inst.agent_instance_id] do return
		seen^[inst.agent_instance_id] = true
		append(list, inst)
	}

	if members, merr := iface.taskchain_list_members_by_chain(service.repo, chain.chain_id, chain.owner_user_id); merr.code == .None {
		defer delete(members)
		for m in members {
			if service.agents != nil {
				if inst, ok, _ := iface.agent_get_instance(service.agents, m.agent_instance_id); ok {
					add_chain_inst(&seen_insts, &chain_instances, inst)
				}
			}
		}
	}
	if chain.coordinator_agent_instance_id != "" && service.agents != nil {
		if coord, ok, _ := iface.agent_get_instance(service.agents, chain.coordinator_agent_instance_id); ok {
			add_chain_inst(&seen_insts, &chain_instances, coord)
		}
	}
	if service.agents != nil {
		if insts, ierr := iface.agent_list_instances_by_owner(service.agents, chain.owner_user_id, 1000, ""); ierr.code == .None {
			defer delete(insts)
			for inst in insts {
				if inst.chain_id == string(chain.chain_id) {
					add_chain_inst(&seen_insts, &chain_instances, inst)
				}
			}
		}
	}

	busy_instances := make(map[string]bool)
	defer delete(busy_instances)
	busy_keys := make([dynamic]string)
	defer {
		for k in busy_keys do delete(k)
		delete(busy_keys)
	}

	mark_busy := proc(busy: ^map[string]bool, keys: ^[dynamic]string, id: string) {
		if id == "" || busy^[id] do return
		k := strings.clone(id)
		append(keys, k)
		busy^[k] = true
	}

	for t in tasks {
		if t.status == .In_Progress && !offline_task_ids[t.task_id] {
			a := primary_assignee_instance(t.assignee_ref_json)
			if a != "" {
				if !instance_is_crashed_or_dead(service, chain_instances[:], a) {
					mark_busy(&busy_instances, &busy_keys, a)
				}
				delete(a)
			}
		}
	}
	for inst in chain_instances {
		if instance_has_pending_validation(tasks, inst.agent_instance_id, offline_task_ids) {
			mark_busy(&busy_instances, &busy_keys, inst.agent_instance_id)
		}
	}
	for t in tasks {
		if t.status != .In_Validation do continue
		if offline_task_ids[t.task_id] do continue
		for inst in chain_instances {
			if instance_reviews_task(t, chain, inst.agent_instance_id) {
				mark_busy(&busy_instances, &busy_keys, inst.agent_instance_id)
			}
		}
	}

	now := platform.clock_now(service.clock)
	modified := false

	// WORK DISPATCH PASS
	work_candidates := make([dynamic]domain.Task)
	defer delete(work_candidates)

	for t in tasks {
		if t.publish_state != .Published do continue
		if t.status != .Assigned && t.status != .Queued && t.status != .In_Progress do continue
		if offline_task_ids[t.task_id] do continue
		if !deps_satisfied_for_task(tasks, deps, t.task_id) do continue

		inst_id := primary_assignee_instance(t.assignee_ref_json)
		inst_crashed := false
		if inst_id != "" {
			if t.status == .In_Progress && instance_is_crashed_or_dead(service, chain_instances[:], inst_id) {
				inst_crashed = true
			} else {
				delete(inst_id)
				continue
			}
			delete(inst_id)
		}

		agt_id := primary_assignee_agent_id(t.assignee_ref_json)
		if agt_id == "" && inst_crashed {
			inst_id_ref := primary_assignee_instance(t.assignee_ref_json)
			if inst_id_ref != "" {
				if service.agents != nil {
					if inst, ok, _ := iface.agent_get_instance(service.agents, inst_id_ref); ok && inst.agent_id != "" {
						agt_id = strings.clone(inst.agent_id)
					}
				}
				delete(inst_id_ref)
			}
			if agt_id == "" && len(fleets) > 0 {
				agt_id = strings.clone(fleets[0].agent_id)
			}
		}
		if agt_id == "" do continue
		delete(agt_id)

		append(&work_candidates, t)
	}

	for i := 0; i < len(work_candidates) - 1; i += 1 {
		best := i
		for j := i + 1; j < len(work_candidates); j += 1 {
			if work_task_prefers(work_candidates[j], work_candidates[best]) {
				best = j
			}
		}
		if best != i {
			tmp := work_candidates[i]
			work_candidates[i] = work_candidates[best]
			work_candidates[best] = tmp
		}
	}

	for cand in work_candidates {
		target_agent_id := primary_assignee_agent_id(cand.assignee_ref_json)
		if target_agent_id == "" {
			inst_id_ref := primary_assignee_instance(cand.assignee_ref_json)
			if inst_id_ref != "" {
				if service.agents != nil {
					if inst, ok, _ := iface.agent_get_instance(service.agents, inst_id_ref); ok && inst.agent_id != "" {
						target_agent_id = strings.clone(inst.agent_id)
					}
				}
				delete(inst_id_ref)
			}
			if target_agent_id == "" && len(fleets) > 0 {
				target_agent_id = strings.clone(fleets[0].agent_id)
			}
		}
		defer delete(target_agent_id)
		if target_agent_id == "" do continue

		capacity := fleet_capacity_for_agent(fleets, target_agent_id)

		idle_instance_id := ""
		warm_stopped_id := ""
		live_count := 0

		for inst in chain_instances {
			if inst.agent_id != target_agent_id do continue
			if inst.runtime_status == "failed" || inst.runtime_status == "terminated" do continue

			// REQ-TB-HUB-1: when cand.bridge_id != "", filter candidate instances and
			// scope live_count strictly to the pinned bridge.
			if cand.bridge_id != "" && inst.bridge_id != cand.bridge_id do continue

			if inst.runtime_status == "stopped" {
				if warm_stopped_id == "" && !busy_instances[inst.agent_instance_id] {
					warm_stopped_id = inst.agent_instance_id
				}
				continue
			}

			live_count += 1

			if idle_instance_id == "" && !busy_instances[inst.agent_instance_id] {
				idle_instance_id = inst.agent_instance_id
			}
		}

		chosen_instance_id := idle_instance_id if idle_instance_id != "" else warm_stopped_id

		if chosen_instance_id != "" {
			ensure_chain_member(service, chain, chosen_instance_id, target_agent_id)

			bound_ref: string
			if strings.contains(cand.assignee_ref_json, "\"agent_id\"") {
				bound_ref = bind_agent_id_to_instance(cand.assignee_ref_json, target_agent_id, chosen_instance_id)
			} else {
				bound_ref = agent_instance_ref_json(chosen_instance_id)
			}
			defer delete(bound_ref)

			nt := cand
			nt.assignee_ref_json = bound_ref
			nt.updated_at = now
			_, _, _ = iface.taskchain_save_task(service.repo, nt)

			mark_busy(&busy_instances, &busy_keys, chosen_instance_id)
			modified = true

			if chosen_instance_id == warm_stopped_id {
				for i in 0..<len(chain_instances) {
					if chain_instances[i].agent_instance_id == chosen_instance_id {
						chain_instances[i].runtime_status = "launching"
						break
					}
				}
			}
		} else if live_count < capacity {
			fleet_provider, fleet_model := fleet_provider_model_for_agent(fleets, target_agent_id)
			new_instance_id := jit_provision_agent_instance(service, chain, cand, target_agent_id, "worker", fleet_provider, fleet_model, fleet_bridge_models_for_agent(fleets, target_agent_id))
			if new_instance_id != "" {
				defer delete(new_instance_id)
				ensure_chain_member(service, chain, new_instance_id, target_agent_id)

				bound_ref: string
				if strings.contains(cand.assignee_ref_json, "\"agent_id\"") {
					bound_ref = bind_agent_id_to_instance(cand.assignee_ref_json, target_agent_id, new_instance_id)
				} else {
					bound_ref = agent_instance_ref_json(new_instance_id)
				}
				defer delete(bound_ref)

				nt := cand
				nt.assignee_ref_json = bound_ref
				nt.updated_at = now
				_, _, _ = iface.taskchain_save_task(service.repo, nt)

				mark_busy(&busy_instances, &busy_keys, new_instance_id)
				live_count += 1
				modified = true

				if service.agents != nil {
					if new_inst, n_ok, _ := iface.agent_get_instance(service.agents, new_instance_id); n_ok {
						add_chain_inst(&seen_insts, &chain_instances, new_inst)
					}
				}
			} else {
				if cand.status == .Assigned || cand.status == .In_Progress {
					nt := cand
					nt.status = .Queued
					nt.updated_at = now
					_, _, _ = iface.taskchain_save_task(service.repo, nt)
					modified = true
				}
			}
		} else {
			if cand.status == .Assigned || cand.status == .In_Progress {
				nt := cand
				nt.status = .Queued
				nt.updated_at = now
				_, _, _ = iface.taskchain_save_task(service.repo, nt)
				modified = true
			}
		}
	}

	// REVIEWER DISPATCH PASS
	for t in tasks {
		if t.publish_state != .Published do continue
		if t.status != .In_Validation do continue
		if offline_task_ids[t.task_id] do continue

		assignee_id := primary_assignee_instance(t.assignee_ref_json)
		defer delete(assignee_id)

		target_ref_json := t.reviewer_refs_json
		if target_ref_json == "" || target_ref_json == "[]" {
			target_ref_json = chain.default_reviewer_refs_json
		}

		rev_agent_ids := extract_agent_ids_from_ref_blob(target_ref_json)
		defer {
			for r in rev_agent_ids do delete(r)
			delete(rev_agent_ids)
		}

		if len(rev_agent_ids) == 0 do continue

		allocated_refs := make([dynamic]string)
		defer {
			for r in allocated_refs do delete(r)
			delete(allocated_refs)
		}

		current_rev_json := target_ref_json
		for rev_agent_id in rev_agent_ids {
			capacity := fleet_capacity_for_agent(fleets, rev_agent_id)

			idle_reviewer_id := ""
			warm_stopped_reviewer_id := ""
			live_count := 0

			for inst in chain_instances {
				if inst.agent_id != rev_agent_id do continue
				if inst.agent_instance_id == assignee_id do continue
				if inst.runtime_status == "failed" || inst.runtime_status == "terminated" do continue

				// REQ-TB-HUB-1: when t.bridge_id != "", filter candidate reviewer instances and
				// scope live_count strictly to the pinned bridge.
				if t.bridge_id != "" && inst.bridge_id != t.bridge_id do continue

				if inst.runtime_status == "stopped" {
					if warm_stopped_reviewer_id == "" && !busy_instances[inst.agent_instance_id] && !strings.contains(current_rev_json, inst.agent_instance_id) {
						warm_stopped_reviewer_id = inst.agent_instance_id
					}
					continue
				}

				live_count += 1

				if idle_reviewer_id == "" && !busy_instances[inst.agent_instance_id] && !strings.contains(current_rev_json, inst.agent_instance_id) {
					idle_reviewer_id = inst.agent_instance_id
				}
			}

			chosen_reviewer_id := idle_reviewer_id if idle_reviewer_id != "" else warm_stopped_reviewer_id

			if chosen_reviewer_id != "" {
				ensure_chain_member(service, chain, chosen_reviewer_id, rev_agent_id)

				bound_ref := bind_agent_id_to_instance(current_rev_json, rev_agent_id, chosen_reviewer_id)
				append(&allocated_refs, bound_ref)
				current_rev_json = bound_ref

				nt := t
				nt.reviewer_refs_json = bound_ref
				nt.updated_at = now
				_, _, _ = iface.taskchain_save_task(service.repo, nt)

				mark_busy(&busy_instances, &busy_keys, chosen_reviewer_id)
				modified = true

				if chosen_reviewer_id == warm_stopped_reviewer_id {
					for i in 0..<len(chain_instances) {
						if chain_instances[i].agent_instance_id == chosen_reviewer_id {
							chain_instances[i].runtime_status = "launching"
							break
						}
					}
				}
			} else if live_count < capacity {
				fleet_provider, fleet_model := fleet_provider_model_for_agent(fleets, rev_agent_id)
				new_instance_id := jit_provision_agent_instance(service, chain, t, rev_agent_id, "reviewer", fleet_provider, fleet_model, fleet_bridge_models_for_agent(fleets, rev_agent_id))
				if new_instance_id != "" {
					defer delete(new_instance_id)
					ensure_chain_member(service, chain, new_instance_id, rev_agent_id)

					bound_ref := bind_agent_id_to_instance(current_rev_json, rev_agent_id, new_instance_id)
					append(&allocated_refs, bound_ref)
					current_rev_json = bound_ref

					nt := t
					nt.reviewer_refs_json = bound_ref
					nt.updated_at = now
					_, _, _ = iface.taskchain_save_task(service.repo, nt)

					mark_busy(&busy_instances, &busy_keys, new_instance_id)
					live_count += 1
					modified = true

					if service.agents != nil {
						if new_inst, n_ok, _ := iface.agent_get_instance(service.agents, new_instance_id); n_ok {
							add_chain_inst(&seen_insts, &chain_instances, new_inst)
						}
					}
				}
			}
		}
	}

	return modified
}

// reconcile_chain is the single self-healing pass over one task chain. It:
//   * resolves every relevant instance's single current task (deps + priority
//     aware; review>work), promoting the chosen work task to In_Progress and
//     demoting other unblocked work tasks to Queued,
//   * heals current_task pointers TOTALLY (sets the focus, or CLEARS it for any
//     instance with no eligible focus — including members no longer on any task),
//   * notifies agents whose current_task changed, and nudges idle+actionable
//     agents (10 min min, exponential backoff), and
//   * never runs another reconcile (internal status writes use the low-level repo
//     save, not the high-level status procs).
// Returns the number of tasks newly advanced into In_Progress. Callers must have
// already authorized the mutation/command that triggered it; it operates with the
// chain's owner and is idempotent (change-gated writes, no-op when consistent).
reconcile_chain :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain) -> int {
	if service == nil || service.repo == nil do return 0
	if chain.status != .Active do return 0
	if chain.publish_state != .Published do return 0

	tasks, tasks_err := iface.taskchain_list_tasks_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if tasks_err.code != .None do return 0
	defer delete(tasks)
	deps, deps_err := iface.taskchain_list_dependencies_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if deps_err.code != .None do return 0
	defer delete(deps)

	dispatch_offline_task_ids := make(map[domain.Task_ID]bool)
	defer delete(dispatch_offline_task_ids)
	for task in tasks {
		if task.status != .Assigned && task.status != .Queued && task.status != .In_Validation do continue
		bridge_online, _ := task_effective_bridge_is_online(service, chain, task)
		if !bridge_online do dispatch_offline_task_ids[task.task_id] = true
	}

	// REQ-FLEET-DISPATCHER-1: Dynamic fleet scheduler and JIT agent provisioning pass.
	// For actionable tasks with declarative agent_id targets, allocate idle instances
	// from the chain's warm pool or JIT-provision new instances up to fleet capacity.
	if dynamic_fleet_schedule(service, chain, tasks[:], deps[:], dispatch_offline_task_ids) {
		delete(tasks)
		tasks, tasks_err = iface.taskchain_list_tasks_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
		if tasks_err.code != .None do return 0
	}

	offline_task_ids := make(map[domain.Task_ID]bool)
	defer delete(offline_task_ids)
	for task in tasks {
		if task.status != .Assigned && task.status != .Queued && task.status != .In_Progress && task.status != .Validated_Not_Good && task.status != .In_Validation do continue
		bridge_online, bridge_id := task_effective_bridge_is_online(service, chain, task)
		if bridge_online do continue
		offline_task_ids[task.task_id] = true
		fmt.eprintfln("[reconcile] task %s effective bridge %s offline; holding", task.task_id, bridge_id)
	}

	// Collect the TOTAL set of instances that could hold a pointer in this chain:
	//   assignees ∪ designated reviewers ∪ chain members ∪ owner-instances bound to
	//   this chain (stale pointer holders). The union lets us CLEAR stale pointers
	//   for instances dropped from all tasks, not just re-point referenced ones.
	instance_ids := make([dynamic]string)
	defer { for id in instance_ids do delete(id); delete(instance_ids) }
	seen := make(map[string]bool)
	defer delete(seen)
	add_instance := proc(seen: ^map[string]bool, ids: ^[dynamic]string, id: string) {
		if id == "" || seen[id] do return
		seen[id] = true
		append(ids, strings.clone(id))
	}
	def_reviewers := extract_instances_from_ref_blob(chain.default_reviewer_refs_json)
	defer delete(def_reviewers)
	for t in tasks {
		a := primary_assignee_instance(t.assignee_ref_json)
		add_instance(&seen, &instance_ids, a)
		delete(a)
		reviewers := extract_instances_from_ref_blob(t.reviewer_refs_json)
		for id in reviewers do if instance_reviews_task(t, chain, id) do add_instance(&seen, &instance_ids, id)
		delete(reviewers)
		for id in def_reviewers do if instance_reviews_task(t, chain, id) do add_instance(&seen, &instance_ids, id)
	}
	// Chain members (canonical) + any owner-instance bound to this chain: ensures a
	// member/holder with a now-stale pointer is included so step 4 clears it.
	if members, merr := iface.taskchain_list_members_by_chain(service.repo, chain.chain_id, chain.owner_user_id); merr.code == .None {
		for m in members do add_instance(&seen, &instance_ids, m.agent_instance_id)
		delete(members)
	}
	if service.agents != nil {
		if insts, ierr := iface.agent_list_instances_by_owner(service.agents, chain.owner_user_id, 500, ""); ierr.code == .None {
			for inst in insts do if inst.chain_id == string(chain.chain_id) do add_instance(&seen, &instance_ids, inst.agent_instance_id)
			delete(insts)
		}
	}

	held_instance_ids := make(map[string]bool)
	defer delete(held_instance_ids)
	instance_bridge_ids := make(map[string]string)
	defer delete(instance_bridge_ids)
	if service.agents != nil {
		for instance_id in instance_ids {
			if inst, inst_ok, _ := iface.agent_get_instance(service.agents, instance_id); inst_ok {
				instance_bridge_ids[instance_id] = inst.bridge_id
				if inst.runtime_status == "failed" || inst.runtime_status == "terminated" {
					held_instance_ids[instance_id] = true
				}
				if offline_task_ids[domain.Task_ID(inst.current_task_id)] {
					held_instance_ids[instance_id] = true
				}
			}
		}
	}
	for task in tasks {
		if !offline_task_ids[task.task_id] do continue
		assignee_id := primary_assignee_instance(task.assignee_ref_json)
		if assignee_id != "" do held_instance_ids[assignee_id] = true
		delete(assignee_id)
		reviewer_ids := extract_instances_from_ref_blob(task.reviewer_refs_json)
		for reviewer_id in reviewer_ids do if instance_reviews_task(task, chain, reviewer_id) do held_instance_ids[reviewer_id] = true
		delete(reviewer_ids)
		for reviewer_id in def_reviewers do if instance_reviews_task(task, chain, reviewer_id) do held_instance_ids[reviewer_id] = true
	}

	// Load votes for all in_validation tasks so the review pool can exclude tasks
	// an instance has already voted on (stopping reviewers after they vote).
	votes_by_task := make(map[domain.Task_ID][]string) // task_id -> []voter_instance_ids
	defer {
		for _, voters in votes_by_task do delete(voters)
		delete(votes_by_task)
	}
	for t in tasks {
		if t.status != .In_Validation do continue
		votes, verr := iface.taskchain_list_votes_by_task(service.repo, t.task_id, chain.owner_user_id)
		if verr.code != .None do continue
		voter_ids := make([dynamic]string)
		for v in votes {
			if t.updated_at != "" && v.created_at < t.updated_at do continue
			append(&voter_ids, v.reviewer_agent_instance_id)
		}
		votes_by_task[t.task_id] = voter_ids[:]
		delete(votes)
	}

	// Resolve each instance's focus and collect the resulting task mutations. We
	// stage decisions first, then apply them so the tasks slice remains a stable
	// snapshot during selection.
	focus := make(map[string]Instance_Focus)
	defer delete(focus)
	// promote holds task_ids to advance into In_Progress; queue holds task_ids to
	// demote into Queued. A task_id never appears in both.
	promote := make(map[domain.Task_ID]bool)
	defer delete(promote)
	queue := make(map[domain.Task_ID]bool)
	defer delete(queue)

	for instance_id in instance_ids {
		if held_instance_ids[instance_id] do continue
		// REVIEW pool: tasks in validation this instance reviews. Review wins over
		// work (R7), so if any review candidate exists it takes the focus.
		best_review: domain.Task
		have_review := false
		for t in tasks {
			if t.status != .In_Validation do continue
			if offline_task_ids[t.task_id] do continue
			if !instance_reviews_task(t, chain, instance_id) do continue
			if instance_has_voted(votes_by_task, t.task_id, instance_id) do continue
			if !have_review || task_prefers(t, best_review) { best_review = t; have_review = true }
		}

		// Block new work promotion while this instance has a task pending review.
		if !have_review && instance_has_pending_validation(tasks[:], instance_id, offline_task_ids) {
			// BUG-50 Fix (Bug 1): keep the assignee alive on their pending-review task
			// instead of clearing focus to {"", .None}. Clearing produced a Focus_Change
			// (pointer was {task_id, .Work} while In_Progress) -> stop[] -> the bridge
			// killed the assignee mid-review, forcing a restart to receive NGTM feedback.
			// Pointing focus at the In_Validation task keeps it as {task_id, .Work} (same
			// as In_Progress) -> no change -> no stop[]. The 'continue' still skips the
			// work pool below, so no next task is handed out while a validation is pending.
			// The process ends naturally when the task resolves: completed -> focus clears
			// (not actionable, not pending) -> stop[]; validated_not_good -> the same work
			// focus is restored -> no change -> the running agent just receives a nudge.
			for t in tasks {
				if t.status != .In_Validation do continue
				if offline_task_ids[t.task_id] do continue
				a := primary_assignee_instance(t.assignee_ref_json)
				is_mine := a == instance_id
				delete(a)
				if is_mine {
					focus[instance_id] = Instance_Focus{task_id = t.task_id, role = .Work}
					break
				}
			}
			// Demote any in_progress or assigned work tasks for this instance to Queued
			// while awaiting review so the instance has 0 active in_progress tasks.
			for t in tasks {
				if t.status != .In_Progress && t.status != .Assigned do continue
				if offline_task_ids[t.task_id] do continue
				a := primary_assignee_instance(t.assignee_ref_json)
				is_mine := a == instance_id
				delete(a)
				if is_mine {
					queue[t.task_id] = true
				}
			}
			continue
		}

		inst_bridge := instance_bridge_ids[instance_id]

		// WORK pool: actionable, unblocked tasks assigned to this instance.
		best_work: domain.Task
		have_work := false
		for t in tasks {
			if offline_task_ids[t.task_id] do continue
			// REQ-TB-HUB-1: skip tasks whose bridge_id != inst.bridge_id
			if t.bridge_id != "" && inst_bridge != t.bridge_id do continue
			a := primary_assignee_instance(t.assignee_ref_json)
			is_mine := a == instance_id
			delete(a)
			if !is_mine do continue
			if !work_task_eligible(tasks[:], deps[:], t) do continue
			if !have_work || task_prefers(t, best_work) { best_work = t; have_work = true }
		}

		chosen_work_id := domain.Task_ID("")
		if have_review {
			focus[instance_id] = Instance_Focus{task_id = best_review.task_id, role = .Review}
		} else if have_work {
			focus[instance_id] = Instance_Focus{task_id = best_work.task_id, role = .Work}
			chosen_work_id = best_work.task_id
			// Advance the chosen work task into In_Progress when it is not already
			// there. Assigned/Queued are the normal not-started/held states; a
			// Validated_Not_Good task that the engine picks up is rework the agent
			// is now actively resuming, so it also advances to In_Progress (the
			// Validated_Not_Good -> In_Progress transition is legal). Only a task
			// already In_Progress needs no status change.
			if best_work.status == .Assigned || best_work.status == .Queued || best_work.status == .Validated_Not_Good {
				promote[best_work.task_id] = true
			}
		} else {
			focus[instance_id] = Instance_Focus{task_id = "", role = .None}
		}

		// Post-reconcile invariant: ensure that across all tasks assigned to an
		// instance, only chosen_work_id remains In_Progress. Any other unblocked
		// work tasks assigned to that instance are placed in queue map to be demoted to Queued.
		for t in tasks {
			if t.task_id == chosen_work_id do continue
			if offline_task_ids[t.task_id] do continue
			a := primary_assignee_instance(t.assignee_ref_json)
			is_mine := a == instance_id
			delete(a)
			if !is_mine do continue
			if t.status == .In_Progress {
				queue[t.task_id] = true
			} else if t.status == .Assigned && work_task_eligible(tasks[:], deps[:], t) {
				queue[t.task_id] = true
			}
		}
	}

	// Demote any In_Progress task whose dependencies are not satisfied to Queued.
	// This ensures that adding a blocking dependency to an active task pauses/queues
	// it immediately until its dependencies resolve.
	for t in tasks {
		if offline_task_ids[t.task_id] do continue
		if t.status == .In_Progress && !deps_satisfied_for_task(tasks[:], deps[:], t.task_id) {
			queue[t.task_id] = true
		}
	}

	for q_id in queue {
		delete_key(&promote, q_id)
	}

	// Apply task status mutations first (promotions win over demotions for the same
	// id; they never collide, but be defensive). We stage promoted tasks and defer
	// their notifications until AFTER the instance current_task pointers are
	// persisted, because notification gating (CT-6) reads each recipient's
	// persisted current_task_id — the pointer must be up to date before we notify.
	promoted := 0
	now := platform.clock_now(service.clock)
	promoted_tasks := make([dynamic]domain.Task)
	defer delete(promoted_tasks)
	for t in tasks {
		if promote[t.task_id] {
			nt := t
			nt.status = .In_Progress
			if nt.started_at == "" do nt.started_at = now
			nt.updated_at = now
			saved, ok, _ := iface.taskchain_save_task(service.repo, nt)
			if ok {
				promoted += 1
				append(&promoted_tasks, saved)
			}
		} else if queue[t.task_id] {
			nt := t
			nt.status = .Queued
			nt.updated_at = now
			_, _, _ = iface.taskchain_save_task(service.repo, nt)
		}
	}

	changed_focus := apply_instance_focus_total(service, instance_ids[:], focus, held_instance_ids)
	defer delete(changed_focus)

	// Re-read tasks so notifications reflect just-applied status changes.
	fresh_tasks, ft_err := iface.taskchain_list_tasks_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	defer if ft_err.code == .None do delete(fresh_tasks)
	lookup_task :: proc(tasks: []domain.Task, id: domain.Task_ID) -> (domain.Task, bool) {
		for t in tasks do if t.task_id == id do return t, true
		return domain.Task{}, false
	}

	// Notify and act on focus changes: send the task-changed message, then emit
	// a wake_agent run[] or stop[] for every instance whose current_task pointer
	// moved. Unchanged pointers produce no action (idle nudge removed).
	coordinator_id := chain.coordinator_agent_instance_id
	runs  := make(map[string][dynamic]agent.Wake_Agent_Run_Entry)
	stops := make(map[string][dynamic]string)
	bridge_order := make([dynamic]string)
	seen_bridge  := make(map[string]bool)
	defer {
		for _, entries in runs  do delete(entries)
		for _, entries in stops do delete(entries)
		delete(runs); delete(stops); delete(bridge_order); delete(seen_bridge)
	}
	for cf in changed_focus {
		if cf.new_task_id != "" && offline_task_ids[domain.Task_ID(cf.new_task_id)] do continue
		inst, inst_ok, _ := iface.agent_get_instance(service.agents, cf.instance_id)
		if !inst_ok {
			// BUG-49 diagnostic: no agent record => no bridge_id/provider/etc, so no
			// wake_agent can be built. A reviewer that reached changed_focus without a
			// DB record lands here; surface it (previously a silent skip) so a review
			// task that never starts is traceable to the missing instance record.
			if cf.new_task_id != "" {
				fmt.eprintfln("[reconcile] fan-out: instance %s (focus=%s role=%v) has no agent DB record; no wake dispatched", cf.instance_id, cf.new_task_id, cf.new_role)
			}
			continue
		}
		// Send the task-changed chat message when the new focus is non-empty.
		if cf.new_task_id != "" {
			task, task_ok := lookup_task(fresh_tasks if ft_err.code == .None else tasks[:], domain.Task_ID(cf.new_task_id))
			if task_ok do notify_current_task_changed(service, inst, task, cf.new_role)
		}
		if service.agent_service != nil { if idle, _ := agent.reconfiguration_require_idle(service.agent_service, cf.instance_id); !idle do continue }
		// Emit runtime wake/stop (coordinators exempt).
		if cf.instance_id == coordinator_id do continue
		if cf.new_task_id != "" {
			remove_from_all_stops(&stops, cf.instance_id)
			role := "worker"
			if cf.new_role == .Review do role = "reviewer"
			// REQ-37: carry the full descriptor so the bridge takes the agent-keyed
			// template bootstrap (not the header-only instance fallback). agent_name is
			// looked up like launch_command_json_full does; the rest come from inst/chain.
			agent_name := ""
			if service.agents != nil && inst.agent_id != "" {
				if ag, ag_ok, _ := iface.agent_get(service.agents, inst.agent_id); ag_ok do agent_name = ag.name
			}
			// BUG-49 Fix A: an instance with no bound bridge cannot receive a wake_agent
			// command — the run[] entry would be appended under an empty bridge_id key
			// and note_bridge() no-ops on "", so the entry is silently dropped and
			// the agent (e.g. a reviewer whose task just entered in_validation) is never
			// started. Emit a WARNING so this previously invisible condition is
			// detectable, then skip the undeliverable entry instead of accumulating a
			// dead runs[""] bucket that never fans out.
			if inst.bridge_id == "" {
				fmt.eprintfln("[reconcile] fan-out: WARNING instance %s (focus=%s role=%s) has empty bridge_id; wake_agent cannot be delivered (agent not bound to a bridge)", cf.instance_id, cf.new_task_id, role)
				continue
			}
			entries := runs[inst.bridge_id]
			append(&entries, agent.Wake_Agent_Run_Entry{
				agent_instance_id = cf.instance_id,
				task_id           = cf.new_task_id,
				role              = role,
				provider          = inst.provider,
				model              = inst.model,
				agent_id          = inst.agent_id,
				agent_name        = agent_name,
				chain_id          = string(chain.chain_id),
				chain_title       = chain.title,
				coordinator_id    = chain.coordinator_agent_instance_id,
				project_id        = string(inst.project_id),
				project_path      = inst.project_path,
			})
			runs[inst.bridge_id] = entries
			note_bridge(&bridge_order, &seen_bridge, inst.bridge_id)
		} else if instance_is_live(inst) {
			// BUG-49 Bug 1 assessment (assignee stopped on in_validation): this stop[]
			// is INTENTIONAL — fresh-context-per-task means an assignee whose focus just
			// cleared (its task moved to in_validation, held pending review) is torn down
			// so the next task boots a clean context. The apparent race (this stop is
			// emitted synchronously during recompute, i.e. BEFORE the HTTP 200 returns to
			// the assignee's own `ham-ctl task status ... --status in_validation` call) is
			// benign: (1) the durable in_validation write is already persisted before we
			// reach here, so the assignee's intent is fully recorded regardless of when it
			// dies; and (2) the stop must traverse hub -> WS -> bridge command handler ->
			// runtime stop, many more hops than the 200 already flushing on ham-ctl's own
			// TCP connection, so the response wins in practice. No lifecycle change.
			entries := stops[inst.bridge_id]
			append(&entries, cf.instance_id)
			stops[inst.bridge_id] = entries
			note_bridge(&bridge_order, &seen_bridge, inst.bridge_id)
		}
	}

	// Actionable tasks sweep: evaluate current running states for all actionable
	// tasks and active focus instances. If an In_Progress task has a non-running assignee,
	// an In_Validation task has an unvoted non-running reviewer, or an instance has an active
	// focus, ensure reconciliation starts them and removes them from all stops.
	eval_tasks := fresh_tasks if ft_err.code == .None else tasks[:]
	for t in eval_tasks {
		if offline_task_ids[t.task_id] do continue
		if t.status == .In_Progress {
			assignee_id := primary_assignee_instance(t.assignee_ref_json)
			if assignee_id != "" {
				ensure_actionable_agent_started(service, chain, t, assignee_id, .Work, &runs, &stops, &bridge_order, &seen_bridge, offline_task_ids)
				delete(assignee_id)
			}
		} else if t.status == .In_Validation {
			reviewers := extract_instances_from_ref_blob(t.reviewer_refs_json)
			for rev_id in reviewers {
				if instance_reviews_task(t, chain, rev_id) && !instance_has_voted(votes_by_task, t.task_id, rev_id) {
					ensure_actionable_agent_started(service, chain, t, rev_id, .Review, &runs, &stops, &bridge_order, &seen_bridge, offline_task_ids)
				}
			}
			delete(reviewers)
			def_reviewers := extract_instances_from_ref_blob(chain.default_reviewer_refs_json)
			for rev_id in def_reviewers {
				if instance_reviews_task(t, chain, rev_id) && !instance_has_voted(votes_by_task, t.task_id, rev_id) {
					ensure_actionable_agent_started(service, chain, t, rev_id, .Review, &runs, &stops, &bridge_order, &seen_bridge, offline_task_ids)
				}
			}
			delete(def_reviewers)
		}
	}

	for inst_id, f in focus {
		if f.task_id != "" && f.role != .None {
			task, task_ok := lookup_task(eval_tasks, f.task_id)
			if !task_ok do task, task_ok = lookup_task(tasks[:], f.task_id)
			if task_ok {
				ensure_actionable_agent_started(service, chain, task, inst_id, f.role, &runs, &stops, &bridge_order, &seen_bridge, offline_task_ids)
			}
		}
	}

	// Guarantee actionable agents are safely removed from any pending stops
	for inst_id, f in focus {
		if f.task_id != "" {
			remove_from_all_stops(&stops, inst_id)
		}
	}
	for _, entries in runs {
		for entry in entries {
			remove_from_all_stops(&stops, entry.agent_instance_id)
		}
	}

	// Fan out one wake_agent command per bridge.
	for bridge_id in bridge_order {
		run_entries  := runs[bridge_id]
		stop_entries := stops[bridge_id]
		if len(run_entries) == 0 && len(stop_entries) == 0 do continue
		cmd_id := platform.generate_id(service.ids, "cmd_")
		body   := agent.wake_agent_command_json(cmd_id, string(chain.chain_id), run_entries[:], stop_entries[:])
		_, _ = project.bridge_command_send_runtime(service.bridge_command_sink,
			project.Runtime_Command{bridge_id = bridge_id, command_id = cmd_id, body_json = body})
	}

	// Fan out promotion status-change notifications.
	for saved in promoted_tasks {
		notify_task_status_change(service, contracts.Auth_Context{}, saved, chain)
	}

	return promoted
}

note_bridge :: proc(order: ^[dynamic]string, seen: ^map[string]bool, bridge_id: string) {
	if bridge_id == "" || seen[bridge_id] do return
	seen[bridge_id] = true
	append(order, bridge_id)
}

instance_in_runs :: proc(runs: map[string][dynamic]agent.Wake_Agent_Run_Entry, instance_id: string) -> bool {
	for _, entries in runs {
		for entry in entries {
			if entry.agent_instance_id == instance_id do return true
		}
	}
	return false
}

remove_from_all_stops :: proc(stops: ^map[string][dynamic]string, instance_id: string) {
	if stops == nil do return
	for bridge_id in stops^ {
		entries := stops^[bridge_id]
		removed := false
		for i := len(entries) - 1; i >= 0; i -= 1 {
			if entries[i] == instance_id {
				ordered_remove(&entries, i)
				removed = true
			}
		}
		if removed {
			stops^[bridge_id] = entries
		}
	}
}

ensure_actionable_agent_started :: proc(
	service: ^Taskchain_Service,
	chain: domain.Task_Chain,
	task: domain.Task,
	instance_id: string,
	task_role: domain.Current_Task_Role,
	runs: ^map[string][dynamic]agent.Wake_Agent_Run_Entry,
	stops: ^map[string][dynamic]string,
	bridge_order: ^[dynamic]string,
	seen_bridge: ^map[string]bool,
	offline_task_ids: map[domain.Task_ID]bool,
) {
	if offline_task_ids[task.task_id] do return
	if instance_id == "" || instance_id == chain.coordinator_agent_instance_id do return
	if service == nil || service.agents == nil do return

	inst, ok, _ := iface.agent_get_instance(service.agents, instance_id)
	if !ok do return

	// Actionable instance must never be stopped
	remove_from_all_stops(stops, instance_id)

	if inst.bridge_id == "" {
		fmt.eprintfln("[reconcile] actionable agent check: WARNING instance %s has empty bridge_id", instance_id)
		return
	}

	if instance_is_live(inst) || instance_in_runs(runs^, instance_id) {
		return
	}

	role_str := "worker"
	if task_role == .Review do role_str = "reviewer"

	agent_name := ""
	if inst.agent_id != "" {
		if ag, ag_ok, _ := iface.agent_get(service.agents, inst.agent_id); ag_ok do agent_name = ag.name
	}

	entries := runs[inst.bridge_id]
	append(&entries, agent.Wake_Agent_Run_Entry{
		agent_instance_id = instance_id,
		task_id           = string(task.task_id),
		role              = role_str,
		provider          = inst.provider,
		model              = inst.model,
		agent_id          = inst.agent_id,
		agent_name        = agent_name,
		chain_id          = string(chain.chain_id),
		chain_title       = chain.title,
		coordinator_id    = chain.coordinator_agent_instance_id,
		project_id        = string(inst.project_id),
		project_path      = inst.project_path,
	})
	runs[inst.bridge_id] = entries
	note_bridge(bridge_order, seen_bridge, inst.bridge_id)

	if inst.current_task_id != string(task.task_id) || inst.current_task_role != task_role {
		inst.current_task_id = string(task.task_id)
		inst.current_task_role = task_role
		inst.updated_at = platform.clock_now(service.clock)
		_, _, _ = iface.agent_save_instance(service.agents, inst)
	}
	fmt.eprintfln("[reconcile] actionable agent check: starting non-running agent %s for task %s (role=%s)", instance_id, task.task_id, role_str)
}

// instance_is_live reports whether an instance currently has a running process
// (mirrors the "live" set used by instance_is_idle). Only live instances are eligible
// for a stop[] push; a stopped/launching instance is left alone.
instance_is_live :: proc(inst: domain.Agent_Instance) -> bool {
	return inst.runtime_status == "running" || inst.runtime_status == "idle" || inst.runtime_status == "busy"
}

// recompute_chain_promotions is kept as an alias so existing call sites compile;
// it forwards to the unified reconcile_chain healer.
recompute_chain_promotions :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain) -> int {
	return reconcile_chain(service, chain)
}

// Focus_Change records an instance whose current_task pointer moved during a
// reconcile (old -> new), so we notify only the ones that actually changed.
Focus_Change :: struct {
	instance_id: string,
	new_task_id: string,
	new_role:    domain.Current_Task_Role,
}

// apply_instance_focus_total writes EVERY candidate instance's pointer: to its
// resolved focus, or cleared when it has none. Change-gated. Returns the set of
// instances whose pointer actually changed (with the new focus).
apply_instance_focus_total :: proc(service: ^Taskchain_Service, instance_ids: []string, focus: map[string]Instance_Focus, held_instance_ids: map[string]bool) -> []Focus_Change {
	changed := make([dynamic]Focus_Change)
	if service == nil || service.agents == nil do return changed[:]
	for instance_id in instance_ids {
		if held_instance_ids[instance_id] do continue
		f := focus[instance_id] // zero value = {"", .None} when absent => clear
		inst, ok, _ := iface.agent_get_instance(service.agents, instance_id)
		if !ok {
			// BUG-49 Fix B: an instance with no agent DB record used to be silently
			// skipped here, so a reviewer whose record is missing never produced a
			// Focus_Change and was therefore never woken by the fan-out. When the
			// desired focus is non-empty, still record the change (the fan-out logs the
			// undeliverable wake) so the drop is visible instead of invisible. Clearing
			// a focus for a record that does not exist is a genuine no-op, so skip that.
			if f.task_id != "" {
				fmt.eprintfln("[reconcile] apply_instance_focus_total: instance %s has no agent DB record, desired focus=%s role=%v; recording focus change for wake attempt", instance_id, string(f.task_id), f.role)
				append(&changed, Focus_Change{instance_id = instance_id, new_task_id = string(f.task_id), new_role = f.role})
			}
			continue
		}
		if inst.current_task_id == string(f.task_id) && inst.current_task_role == f.role {
			// BUG-50 Fix (Bug 2): the persisted pointer already equals the desired
			// focus, but a pointer match does NOT imply a live process. A reviewer
			// (or assignee) that was stopped after a prior pass keeps its pointer set
			// to this task, so the purely pointer-based change-gate would record no
			// Focus_Change and the fan-out would never (re)start the dead process.
			// When the focus is a non-empty task and the instance is not live, emit a
			// Focus_Change so the fan-out restarts it. When it IS live, the deliberate
			// no-churn behavior is correct — just log the true no-op for visibility.
			if f.task_id != "" && !instance_is_live(inst) {
				append(&changed, Focus_Change{instance_id = instance_id, new_task_id = string(f.task_id), new_role = f.role})
			} else if f.task_id != "" && instance_is_live(inst) {
				fmt.eprintfln("[reconcile] apply_instance_focus_total: instance %s already at focus=%s role=%v and process is live (no-change; no wake emitted)", instance_id, string(f.task_id), f.role)
			}
			continue
		}
		inst.current_task_id = string(f.task_id)
		inst.current_task_role = f.role
		inst.updated_at = platform.clock_now(service.clock)
		_, _, _ = iface.agent_save_instance(service.agents, inst)
		append(&changed, Focus_Change{instance_id = instance_id, new_task_id = string(f.task_id), new_role = f.role})
	}
	return changed[:]
}

// instance_is_idle reports whether an instance is live but not actively working,
// so a self-heal idle nudge is warranted. Live = runtime running/idle/busy;
// idle = activity_status "idle" (a busy/working agent is never nudged).
instance_is_idle :: proc(inst: domain.Agent_Instance) -> bool {
	live := inst.runtime_status == "running" || inst.runtime_status == "idle" || inst.runtime_status == "busy"
	return live && inst.activity_status == "idle"
}

// apply_instance_focus persists the resolved current_task pointer (id + role) on
// each instance, writing only when the value actually changes so we do not churn
// updated_at on every recompute. No-op when the agent repository is unavailable.
apply_instance_focus :: proc(service: ^Taskchain_Service, focus: map[string]Instance_Focus) {
	if service == nil || service.agents == nil do return
	for instance_id, f in focus {
		inst, ok, _ := iface.agent_get_instance(service.agents, instance_id)
		if !ok do continue
		if inst.current_task_id == string(f.task_id) && inst.current_task_role == f.role do continue
		inst.current_task_id = string(f.task_id)
		inst.current_task_role = f.role
		inst.updated_at = platform.clock_now(service.clock)
		_, _, _ = iface.agent_save_instance(service.agents, inst)
	}
}

// clear_instance_current_task clears the persisted current_task pointer for a
// single instance (CT-7 consistency): used when an instance stops/goes
// unreachable so a stale focus is not shown. No-op when already clear.
clear_instance_current_task :: proc(service: ^Taskchain_Service, instance_id: string) {
	if service == nil || service.agents == nil || instance_id == "" do return
	inst, ok, _ := iface.agent_get_instance(service.agents, instance_id)
	if !ok do return
	if inst.current_task_id == "" && inst.current_task_role == .None do return
	inst.current_task_id = ""
	inst.current_task_role = .None
	inst.updated_at = platform.clock_now(service.clock)
	_, _, _ = iface.agent_save_instance(service.agents, inst)
}

// recompute_promotions_for_chain_id loads the chain by id then recomputes.
recompute_promotions_for_chain_id :: proc(service: ^Taskchain_Service, chain_id: domain.Task_Chain_ID) -> int {
	chain, ok, _ := iface.taskchain_get_chain(service.repo, chain_id)
	if !ok do return 0
	return reconcile_chain(service, chain)
}

// reconcile_task_chain is the AUTHORIZED entry for the explicit `reconcile`
// command (coordinator kickoff + manual re-plan). Only the chain coordinator
// (instance token) or the owner (user/proxy token) may trigger it; workers and
// reviewers are rejected. Returns the number of tasks advanced into In_Progress.
reconcile_task_chain :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID) -> (int, bool, domain.Domain_Error) {
	if service == nil || service.repo == nil do return 0, false, domain.domain_error(.Internal_Error, "taskchain service is not configured")
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return 0, false, err
	// Instance-token callers must be THIS chain's coordinator. User/proxy tokens are
	// already owner-scoped by get_chain.
	if auth.kind == .Instance_Token && !is_chain_coordinator(service, chain, auth.agent_instance_id) {
		return 0, false, domain.domain_error(.Forbidden, "only the chain coordinator or owner can reconcile a task chain")
	}
	return reconcile_chain(service, chain), true, domain.Domain_Error{}
}

// current_task_pointer_valid is a READ-ONLY check (no writes) that the given
// instance's persisted current_task pointer still resolves to an actionable role
// for it (assignee on an actionable task, or reviewer on an In_Validation task).
// Used by the context serializer guard so a stale pointer never surfaces a task
// the agent should not act on, even between reconciles. Returns false if the
// instance/chain/task can't be loaded or the pairing is no longer actionable.
current_task_pointer_valid :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, inst: domain.Agent_Instance) -> bool {
	if service == nil || service.repo == nil do return false
	if inst.chain_id == "" || inst.current_task_id == "" do return false
	chain, chain_ok, _ := iface.taskchain_get_chain(service.repo, domain.Task_Chain_ID(inst.chain_id))
	if !chain_ok do return false
	tasks, tasks_err := iface.taskchain_list_tasks_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if tasks_err.code != .None do return false
	defer delete(tasks)
	deps, deps_err := iface.taskchain_list_dependencies_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if deps_err.code != .None do return false
	defer delete(deps)
	for task in tasks {
		if string(task.task_id) != inst.current_task_id do continue
		_, role_ok, _ := resolve_current_task_role(tasks[:], deps[:], chain, task, inst.agent_instance_id)
		return role_ok
	}
	return false
}

// resolve_current_task_role determines which role an instance would take on a
// task, validating that the pairing is legal and the task is actionable for that
// role. Returns ok=false with a descriptive error otherwise. Rules:
//   * WORK role: instance is the task's primary assignee and the task is in an
//     actionable work status (Assigned/Queued/In_Progress/Validated_Not_Good) with
//     satisfied dependencies.
//   * REVIEW role: instance is a designated reviewer (task or chain default, and
//     not the assignee) and the task is In_Validation.
// Work is preferred over review when an instance is both (it cannot review its own
// task anyway, so the two never collide on the same task).
resolve_current_task_role :: proc(tasks: []domain.Task, deps: []domain.Task_Dependency, chain: domain.Task_Chain, task: domain.Task, instance_id: string) -> (domain.Current_Task_Role, bool, domain.Domain_Error) {
	if task.publish_state != .Published do return .None, false, domain.domain_error(.Conflict, "cannot focus a draft task")
	assignee := primary_assignee_instance(task.assignee_ref_json)
	is_assignee := assignee == instance_id
	delete(assignee)
	if is_assignee {
		if !work_status_is_actionable(task.status) do return .None, false, domain.domain_error(.Conflict, "task is not in an actionable work status for its assignee")
		if !deps_satisfied_for_task(tasks, deps, task.task_id) do return .None, false, domain.domain_error(.Conflict, "task is blocked by unsatisfied dependencies")
		return .Work, true, domain.Domain_Error{}
	}
	if instance_reviews_task(task, chain, instance_id) {
		if task.status != .In_Validation do return .None, false, domain.domain_error(.Conflict, "review task is not awaiting validation")
		return .Review, true, domain.Domain_Error{}
	}
	return .None, false, domain.domain_error(.Forbidden, "instance is neither the assignee nor a reviewer of this task")
}

// set_instance_current_task manually pins an agent instance's current task to a
// specific task on behalf of a coordinator/user (CT-9 manual override). It
// validates ownership + chain scope, that the instance is the task's assignee or
// reviewer, and that the task is actionable for the resolved role; persists the
// pointer (id + role); and notifies the target agent that its current task
// changed with the correct work-vs-review action label (R8). Coordinator is NOT
// exempt from any rule (R5): the same validation applies regardless of caller.
set_instance_current_task :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, instance_id: string, task_id: domain.Task_ID) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	if service == nil || service.repo == nil do return domain.Agent_Instance{}, false, domain.domain_error(.Internal_Error, "taskchain service is not configured")
	if service.agents == nil do return domain.Agent_Instance{}, false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	if strings.trim_space(instance_id) == "" do return domain.Agent_Instance{}, false, domain.domain_error(.Validation_Failed, "instance id is required")

	task, task_ok, task_err := iface.taskchain_get_task(service.repo, task_id)
	if !task_ok do return domain.Agent_Instance{}, false, task_err
	// Ownership: the caller must own the task (mirrors get_task authorization).
	if owner_ok, owner_err := ownership.require_owner(auth, task.owner_user_id); !owner_ok do return domain.Agent_Instance{}, false, owner_err

	chain, chain_ok, chain_err := iface.taskchain_get_chain(service.repo, task.chain_id)
	if !chain_ok do return domain.Agent_Instance{}, false, chain_err
	// Instance-token callers may set their OWN current task (self-service focus
	// switch), but must be the chain coordinator to drive ANOTHER agent's focus.
	// (A user/proxy token is already owner-scoped above.)
	if auth.kind == .Instance_Token {
		is_self := auth.agent_instance_id == instance_id
		if !is_self && !is_chain_coordinator(service, chain, auth.agent_instance_id) {
			return domain.Agent_Instance{}, false, domain.domain_error(.Forbidden, "only the chain coordinator can set another agent's current task")
		}
	}

	inst, inst_ok, inst_err := iface.agent_get_instance(service.agents, instance_id)
	if !inst_ok do return domain.Agent_Instance{}, false, inst_err
	if inst.owner_user_id != task.owner_user_id do return domain.Agent_Instance{}, false, domain.domain_error(.Conflict, "instance and task belong to different owners")
	if task.bridge_id != "" && inst.bridge_id != "" && inst.bridge_id != task.bridge_id {
		return domain.Agent_Instance{}, false, domain.domain_error(.Conflict, "instance bridge does not match task bridge")
	}

	tasks, tasks_err := iface.taskchain_list_tasks_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if tasks_err.code != .None do return domain.Agent_Instance{}, false, tasks_err
	defer delete(tasks)
	deps, deps_err := iface.taskchain_list_dependencies_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if deps_err.code != .None do return domain.Agent_Instance{}, false, deps_err
	defer delete(deps)

	role, role_ok, role_err := resolve_current_task_role(tasks[:], deps[:], chain, task, instance_id)
	if !role_ok do return domain.Agent_Instance{}, false, role_err

	changed := inst.current_task_id != string(task.task_id) || inst.current_task_role != role
	inst.current_task_id = string(task.task_id)
	inst.current_task_role = role
	inst.updated_at = platform.clock_now(service.clock)
	saved, save_ok, save_err := iface.agent_save_instance(service.agents, inst)
	if !save_ok do return domain.Agent_Instance{}, false, save_err

	// Notify the target agent that its current task changed (R8: explicit
	// work-vs-review action label). Only fire on an actual change.
	if changed do notify_current_task_changed(service, saved, task, role)
	return saved, true, domain.Domain_Error{}
}

// notify_current_task_changed wakes the target instance's bridge to tell it its
// current task changed, stating whether the action is WORK (assignee) or REVIEW
// (reviewer) per R8. Fire-and-forget: a delivery failure does not fail the set.
notify_current_task_changed :: proc(service: ^Taskchain_Service, inst: domain.Agent_Instance, task: domain.Task, role: domain.Current_Task_Role) {
	if service.bridge_command_sink.send_runtime_command == nil do return
	if inst.bridge_id == "" do return
	if should_debounce_nudge_dispatch(service, inst.agent_instance_id, string(task.task_id)) do return
	action := "work"
	if role == .Review do action = "review"
	now := platform.clock_now(service.clock)
	cmd_id := platform.generate_id(service.ids, "cmd_")
	// R8: prefer the human-readable title (fall back to id) and state the action.
	name := task_display_name(task)
	verb := "WORK ON" if action == "work" else "REVIEW"
	message := strings.concatenate({"Your current task changed — ", verb, ": ", name})
	defer delete(message)
	// MEM-6: human-readable focus-switch line (spec §3 [Focus Switched]).
	ntitle := notice_task_title(task)
	defer delete(ntitle)
	human_message := strings.concatenate({`[Focus Switched] Your active focus changed to "`, ntitle, `" (`, string(task.task_id), ") (Role: ", action, ")"})
	defer delete(human_message)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"type":"notify_task_nudge","origin":"current_task_changed","command_id":"`)
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, `","agent_instance_id":"`)
	contracts.write_json_string(&b, inst.agent_instance_id)
	strings.write_string(&b, `","task_id":"`)
	contracts.write_json_string(&b, string(task.task_id))
	strings.write_string(&b, `","chain_id":"`)
	contracts.write_json_string(&b, string(task.chain_id))
	strings.write_string(&b, `","target_instance_id":"`)
	contracts.write_json_string(&b, inst.agent_instance_id)
	strings.write_string(&b, `","target_role":"`)
	contracts.write_json_string(&b, action)
	strings.write_string(&b, `","action":"`)
	contracts.write_json_string(&b, action)
	strings.write_string(&b, `","task_status":"`)
	contracts.write_json_string(&b, task_status_string(task.status))
	strings.write_string(&b, `","message":"`)
	contracts.write_json_string(&b, message)
	strings.write_string(&b, `","human_message":"`)
	contracts.write_json_string(&b, human_message)
	strings.write_string(&b, `","created_at":"`)
	contracts.write_json_string(&b, now)
	strings.write_string(&b, `"}`)
	_, _ = project.bridge_command_send_runtime(service.bridge_command_sink, project.Runtime_Command{bridge_id = inst.bridge_id, command_id = cmd_id, body_json = strings.to_string(b)})
}
