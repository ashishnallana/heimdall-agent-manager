package taskv2

import "core:crypto/hash"
import "core:encoding/hex"
import "core:slice"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import agent "odin_test:hub/service/agent"

// Hub-owned snapshot, independent of blocked_on and the business event fold.
// Attempt zero is valid: placement can fail before the first work grant.
FACET_PLACEMENT :: "placement"

Placement_Failure :: struct {
	phase:            string,
	agent_id:         string,
	role:             string,
	bridge_id:        string,
	directory_id:     string,
	source:           string,
	reason:           string,
	message:          string,
	provider:         string,
	model:            string,
	provider_profile: string,
	configuration:    string,
	fingerprint:      string,
}

// Match dispatch and diagnosis share this check. Queue checks belong BEFORE it.
placement_problem :: proc(svc: ^Service, ctx: ^Match_Context, placement: Placement, resolved: bool, agent_id := "") -> (string, string) {
	if !resolved do return "placement_missing", "no bridge placement can be resolved"
	bridge, found, err := iface.bridge_get_bridge(svc.bridges, placement.bridge_id)
	if err.code != .None || !found do return "bridge_missing", "placement bridge is missing"
	if bridge.owner_user_id != ctx.chain.owner_user_id do return "bridge_ineligible", "placement bridge is not owned by the chain owner"
	if bridge.revoked_at != "" || bridge.status == .Revoked || bridge.enrollment_pending_until != "" do return "bridge_ineligible", "placement bridge is not enrolled and active"
	if bridge.plan_disabled_at != "" do return "bridge_ineligible", "placement bridge is disabled"
	if bridge.status != .Online do return "bridge_offline", "placement bridge is offline"
	if agent_id != "" {
		if support, supported, _ := iface.agent_get_support(svc.agents, agent_id, placement.bridge_id); supported && (!support.enabled || support.owner_user_id != ctx.chain.owner_user_id) {
			return "bridge_ineligible", "agent is disabled on the placement bridge"
		}
	}
	if len(ctx.dirs) > 0 && placement.directory_id == "" do return "workspace_missing", "no chain workspace is mapped on the placement bridge"
	if svc.agent_service != nil && svc.agent_service.providers != nil {
		provider, model := resolve_launch_model(svc.agent_service, placement.bridge_id, placement.provider, placement.model, placement.provider_profile)
		defer delete(provider)
		defer delete(model)
		if _, valid, perr := agent.validate_provider_model_intersection(svc.agent_service, placement.bridge_id, provider, model, placement.provider_profile); !valid {
			return "provider_ineligible", perr.message
		}
	}
	return "", ""
}

placement_source :: proc(ctx: ^Match_Context, task: domain.Task, fleet: domain.Task_Chain_Fleet, worker: bool) -> string {
	if worker && strings.trim_space(task.bridge_id) != "" do return "task"
	if strings.trim_space(fleet.bridge_id) != "" do return "fleet"
	if len(ctx.dirs) > 0 do return "directory"
	if ctx.has_coordinator && ctx.coordinator.bridge_id != "" do return "coordinator"
	return "unresolved"
}

placement_failure_json :: proc(f: Placement_Failure, include_fingerprint := true) -> string {
	o := json_begin()
	json_str(&o, "phase", f.phase)
	json_str(&o, "agent_id", f.agent_id)
	json_str(&o, "role", f.role)
	json_str(&o, "bridge_id", f.bridge_id)
	json_str(&o, "directory_id", f.directory_id)
	json_str(&o, "source", f.source)
	json_str(&o, "reason", f.reason)
	json_str(&o, "message", f.message)
	json_str(&o, "provider", f.provider)
	json_str(&o, "model", f.model)
	json_str(&o, "provider_profile", f.provider_profile)
	json_str(&o, "configuration", f.configuration)
	if include_fingerprint do json_str(&o, "fingerprint", f.fingerprint)
	return json_end(&o)
}

append_placement_failure :: proc(out: ^[dynamic]Placement_Failure, ctx: ^Match_Context, task: domain.Task, fleet: domain.Task_Chain_Fleet, placement: Placement, phase, role, reason, message: string, source := "") {
	// Hash relevant configuration rather than task.updated_at (heartbeats and
	// unrelated business events must not invalidate a placement operation).
	c := json_begin()
	json_str(&c, "phase", phase)
	json_str(&c, "agent_id", fleet.agent_id)
	json_str(&c, "role", role)
	json_str(&c, "bridge_id", placement.bridge_id)
	json_str(&c, "directory_id", placement.directory_id)
	json_str(&c, "provider", placement.provider)
	json_str(&c, "model", placement.model)
	json_str(&c, "provider_profile", placement.provider_profile)
	json_str(&c, "source", source if source != "" else placement_source(ctx, task, fleet, phase == "work"))
	json_str(&c, "task_id", string(task.task_id))
	json_int(&c, "attempt_no", i64(task.attempt_no))
	json_str(&c, "brief", task.brief_json)
	json_str(&c, "task_bridge", task.bridge_id)
	json_str(&c, "fleet_bridge", fleet.bridge_id)
	json_int(&c, "fleet_capacity", i64(fleet.capacity))
	json_str(&c, "fleet_roles", fleet.roles_json)
	json_str(&c, "fleet_paused_roles", fleet.paused_roles_json)
	json_str(&c, "fleet_models", fleet.bridge_models_json)
	json_str(&c, "fleet_provider", fleet.provider)
	json_str(&c, "fleet_model", fleet.model)
	json_str(&c, "fleet_profile", fleet.provider_profile)
	json_str(&c, "fleet_updated_at", fleet.updated_at)
	for d in ctx.dirs {
		if d.directory_id != placement.directory_id do continue
		json_str(&c, "directory_path", d.path)
		json_str(&c, "directory_updated_at", d.updated_at)
	}
	f := Placement_Failure{
		phase = phase, agent_id = fleet.agent_id, role = role,
		bridge_id = placement.bridge_id, directory_id = placement.directory_id,
		source = source if source != "" else placement_source(ctx, task, fleet, phase == "work"),
		reason = reason, message = message, provider = placement.provider, model = placement.model,
		provider_profile = placement.provider_profile, configuration = placement_hash(json_end(&c)),
	}
	f.fingerprint = placement_hash(placement_failure_json(f, false))
	append(out, f)
}

// Read-only collection: never launches, resets instances, changes requirements,
// releases leases or appends task business events.
collect_placement_failures :: proc(svc: ^Service, ctx: ^Match_Context, task: domain.Task) -> ([]Placement_Failure, domain.Domain_Error) {
	out := make([dynamic]Placement_Failure, context.temp_allocator)
	if ctx.chain.publish_state != .Published || ctx.chain.status != .Active || task.kind == .Gate || task_is_held(task) do return out[:], {}
	if task.state == .Ready {
		if task_has_live_lease(ctx, task.task_id, domain.LEASE_KIND_WORK) do return out[:], {}
		if task.stage_key == "" {
			ready, err := work_dependencies_ready_in_uow(svc, task.chain_id, task.owner_user_id, domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK, id = string(task.task_id)})
			if err.code != .None do return nil, err
			if !ready do return out[:], {}
		} else {
			caps := make(map[string]map[string]int, context.temp_allocator)
			if cap := workflow_task_max_parallel_cached(svc, &caps, task); cap > 0 && stage_live_work_lease_count(ctx, task.workflow_run_id, task.workflow_execution_no, task.stage_key) >= cap do return out[:], {}
		}
		assignee := brief_assignee(task.brief_json)
		if ctx.has_coordinator && chain_is_solo(svc, ctx.chain) && (assignee == "" || assignee == ctx.coordinator.agent_id) {
			if !ctx.held[ctx.coordinator.agent_instance_id] {
				p := Placement{bridge_id = ctx.coordinator.bridge_id, directory_id = resolve_directory_for_bridge(ctx.dirs, ctx.coordinator.bridge_id), provider = ctx.coordinator.provider, model = ctx.coordinator.model}
				if reason, message := placement_problem(svc, ctx, p, p.bridge_id != "", ctx.coordinator.agent_id); reason != "" {
					append_placement_failure(&out, ctx, task, domain.Task_Chain_Fleet{agent_id = ctx.coordinator.agent_id}, p, "work", "worker", reason, message, "coordinator")
				}
			}
			return out[:], {}
		}
		rows := 0
		queued := false
		for f in ctx.fleets {
			if ctx.has_coordinator && f.agent_id == ctx.coordinator.agent_id do continue
			if !fleet_row_has_role(f, domain.FLEET_ROLE_WORKER) || (assignee != "" && f.agent_id != assignee) do continue
			rows += 1
			if domain.fleet_role_paused(f, domain.FLEET_ROLE_WORKER) { queued = true; continue }
			p, resolved := resolve_placement(ctx, task, f, true)
			if placement_target_queued(svc, ctx, f, p) || (p.directory_id != "" && directory_has_work_lease_ctx(ctx, p.directory_id)) { queued = true; continue }
			reason, message := placement_problem(svc, ctx, p, resolved, f.agent_id)
			if reason == "" { queued = true; continue }
			append_placement_failure(&out, ctx, task, f, p, "work", "worker", reason, message)
		}
		// An unassigned worker has alternatives. A usable queued alternative
		// means placement is not what prevents this task from dispatching.
		if assignee == "" && queued do return nil, {}
		if rows == 0 do append_placement_failure(&out, ctx, task, domain.Task_Chain_Fleet{agent_id = assignee}, {}, "work", "worker", "worker_missing", "no eligible worker row in the chain fleet", "unresolved")
	} else if task.state == .In_Review && !requirements_stale_review(svc, task) {
		author := ""
		if holder := last_attempt_holder(svc, task); holder != "" {
			if inst, found, _ := iface.agent_get_instance(svc.agents, holder); found do author = inst.agent_id
		}
		pairs := required_review_pairs(task, ctx.fleets, author)
		reviews, err := iface.taskchain_list_reviews_by_task(svc.repo, task.task_id, task.owner_user_id)
		if err.code != .None do return nil, err
		for id in distinct_review_agents(pairs) {
			if review_lease_live_for(ctx, svc, task.task_id, id, "") do continue
			f, has_row := fleet_row_for_agent(ctx.fleets, id)
			if !has_row do f.agent_id = id
			owed := owed_review_roles(pairs, reviews, task, id)
			if has_row do owed = unpaused_review_roles(f, owed)
			if len(owed) == 0 do continue
			p, resolved := resolve_placement(ctx, task, f, false)
			if has_row && placement_target_queued(svc, ctx, f, p) do continue
			reason, message := placement_problem(svc, ctx, p, resolved, f.agent_id)
			if !has_row { p = {}; reason, message = "reviewer_missing", "named reviewer has no chain fleet row" }
			if reason == "" do continue
			for role in owed do append_placement_failure(&out, ctx, task, f, p, "review", role, reason, message, "unresolved" if !has_row else "")
		}
	}
	slice.sort_by(out[:], proc(a, b: Placement_Failure) -> bool {
		if a.phase != b.phase do return a.phase < b.phase
		if a.agent_id != b.agent_id do return a.agent_id < b.agent_id
		return a.role < b.role
	})
	return out[:], {}
}

placement_snapshot_json :: proc(failures: []Placement_Failure) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for f, i in failures {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, placement_failure_json(f))
	}
	strings.write_byte(&b, ']')
	o := json_begin()
	json_int(&o, "schema_version", 1)
	json_raw(&o, "failures", strings.to_string(b))
	return json_end(&o)
}

// Fresh context is required: grants in this UoW may have changed both attempt
// and state since the matcher's initial load. Failures roll back with the UoW.
reconcile_placement_in_uow :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain) -> (bool, domain.Domain_Error) {
	ctx, ok, err := load_match_context(svc, chain)
	if !ok do return false, err
	defer destroy_match_context(&ctx)
	for task in ctx.tasks {
		failures, perr := collect_placement_failures(svc, &ctx, task)
		if perr.code != .None do return false, perr
		facets, ferr := iface.taskchain_list_facets_by_task(svc.repo, task.task_id, task.owner_user_id)
		if ferr.code != .None do return false, ferr
		old: domain.Task_Attempt_Facet
		exists := false
		for f in facets {
			if f.attempt_no == task.attempt_no && f.kind == FACET_PLACEMENT { old = f; exists = true; break }
		}
		if len(failures) == 0 && !exists do continue
		body := placement_snapshot_json(failures)
		if exists && old.body_json == body do continue
		if saved, serr := save_facet_verbatim(svc, task, task.attempt_no, FACET_PLACEMENT, body, FACET_WRITER_HUB, u); !saved do return false, serr
		effect_attention(u, task)
	}
	return true, {}
}

// A bridge can disconnect without any running instance, so instance-terminal
// callbacks alone cannot diagnose its queued workers/reviewers.
on_bridge_placement_changed :: proc(svc: ^Service) {
	if svc == nil || svc.repo == nil do return
	scratch: Scratch
	context.allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	u, ok, _ := begin_uow(svc)
	if !ok do return
	chains, err := iface.taskchain_list_published_active_chains(svc.repo)
	ok = err.code == .None
	for chain in chains {
		if rok, _ := reconcile_placement_in_uow(svc, &u, chain); !rok { ok = false; break }
	}
	_, _ = end_uow(svc, &u, ok)
}

placement_hash :: proc(raw: string) -> string {
	buf: [32]byte
	hash.hash_string_to_buffer(.SHA256, raw, buf[:])
	return string(hex.encode(buf[:], context.temp_allocator))
}

// Pending runtime operations and transient provider retry windows are queueing,
// including on a bridge that is temporarily away. Match pick_instance capacity.
placement_target_queued :: proc(svc: ^Service, ctx: ^Match_Context, fleet: domain.Task_Chain_Fleet, p: Placement) -> bool {
	if fleet_row_full(ctx, fleet, p) do return true
	waiting := 0
	for inst in ctx.instances {
		if inst.agent_id != fleet.agent_id || inst.bridge_id != p.bridge_id do continue
		if ctx.held[inst.agent_instance_id] { waiting += 1; continue }
		if busy, err := iface.agent_runtime_busy(svc.agents, inst.agent_instance_id); busy || err.code != .None { waiting += 1; continue }
		if inst.stopped_by == agent.STOPPED_BY_USER do continue
		if agent.failed_instance_disposition(inst, ctx.now_ms) == .Hold {
			if werr, typed := agent.instance_last_error(inst); typed && werr.class == .retriable do waiting += 1
		}
	}
	return waiting >= max(1, fleet.capacity)
}
