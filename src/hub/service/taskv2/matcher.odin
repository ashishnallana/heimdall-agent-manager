package taskv2

import "core:fmt"
import "core:slice"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import agent "odin_test:hub/service/agent"
import jsonx "odin_test:lib/jsonx"

// match_chain_in_uow is the matcher for one chain (plan §2.4/§2.5): a pure
// function of (tasks, leases, fleets, instances, bridges) that grants leases.
// It is invoked ONLY from the trigger table (after_chain_change, timers,
// on_instance_terminal, bridge hello, start-success, boot) and always inside
// the caller's unit of work. There is no manual run.
//
// Order: review pass first (an in_review task is closer to done than a ready
// one), then the work pass by priority P0 > P1 > P2, oldest ready_since first.
// Every grant check lives in grant_in_uow; a failed grant is a skip, never an
// error for the chain (the DB uniques are the backstop under any race).
match_chain_in_uow :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain, trigger: Trigger) -> (bool, domain.Domain_Error) {
	if chain.publish_state != .Published || chain.status != .Active do return true, domain.Domain_Error{}
	metric_matcher_run(trigger)
	ctx, ok, err := load_match_context(svc, chain)
	if !ok do return false, err
	defer destroy_match_context(&ctx)

	// Review pass.
	for task in ctx.sorted {
		if task.state != .In_Review || task.kind == .Gate do continue
		grant_reviews(svc, u, &ctx, task, trigger)
	}
	// Work pass.
	for task in ctx.sorted {
		if task.state != .Ready || task.kind == .Gate do continue
		if task_has_live_lease(&ctx, task.task_id, domain.LEASE_KIND_WORK) do continue
		grant_work(svc, u, &ctx, task, trigger)
	}
	return true, domain.Domain_Error{}
}

// ---- context ------------------------------------------------------------------------

Match_Context :: struct {
	chain:     domain.Task_Chain,
	tasks:     []domain.Task,
	sorted:    []domain.Task,
	fleets:    []domain.Task_Chain_Fleet,
	dirs:      []domain.Task_Chain_Directory,
	leases:    [dynamic]domain.Task_Lease,
	instances: [dynamic]domain.Agent_Instance,
	// held: instance ids that hold a lease (existing or granted in this run).
	held:      map[string]bool,
	coordinator: domain.Agent_Instance,
	has_coordinator: bool,
	now_ms:    i64,
}

@(private = "file")
load_match_context :: proc(svc: ^Service, chain: domain.Task_Chain) -> (Match_Context, bool, domain.Domain_Error) {
	ctx := Match_Context{chain = chain, now_ms = now_ms(svc.clock)}
	tasks, terr := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if terr.code != .None do return ctx, false, terr
	ctx.tasks = tasks
	ctx.sorted = slice.clone(tasks)
	slice.sort_by(ctx.sorted, proc(a, b: domain.Task) -> bool {
		if a.priority != b.priority do return a.priority < b.priority
		ra, rb := a.ready_since, b.ready_since
		if ra != rb {
			if ra == "" do return false
			if rb == "" do return true
			return ra < rb
		}
		if a.created_at != b.created_at do return a.created_at < b.created_at
		return a.task_id < b.task_id
	})
	fleets, ferr := iface.taskchain_list_fleets_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if ferr.code != .None do return ctx, false, ferr
	ctx.fleets = fleets
	dirs, derr := iface.taskchain_list_directories_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if derr.code == .None do ctx.dirs = dirs
	leases, lerr := iface.taskchain_list_leases_by_chain(svc.repo, chain.chain_id)
	if lerr.code != .None do return ctx, false, lerr
	ctx.leases = make([dynamic]domain.Task_Lease)
	append(&ctx.leases, ..leases)
	ctx.held = make(map[string]bool)
	for l in ctx.leases do ctx.held[l.holder_instance_id] = true
	// Chain instances: members ∪ owner instances bound to the chain ∪ coordinator.
	ctx.instances = make([dynamic]domain.Agent_Instance)
	seen := make(map[string]bool, context.temp_allocator)
	add := proc(ctx: ^Match_Context, seen: ^map[string]bool, inst: domain.Agent_Instance) {
		if inst.agent_instance_id == "" || seen[inst.agent_instance_id] do return
		seen[inst.agent_instance_id] = true
		append(&ctx.instances, inst)
	}
	if members, merr := iface.taskchain_list_members_by_chain(svc.repo, chain.chain_id, chain.owner_user_id); merr.code == .None {
		for m in members {
			if inst, iok, _ := iface.agent_get_instance(svc.agents, m.agent_instance_id); iok do add(&ctx, &seen, inst)
		}
	}
	if insts, ierr := iface.agent_list_instances_by_owner(svc.agents, chain.owner_user_id, 1000, ""); ierr.code == .None {
		for inst in insts do if inst.chain_id == string(chain.chain_id) do add(&ctx, &seen, inst)
	}
	if chain.coordinator_agent_instance_id != "" {
		if coord, cok, _ := iface.agent_get_instance(svc.agents, chain.coordinator_agent_instance_id); cok {
			add(&ctx, &seen, coord)
			ctx.coordinator = coord
			ctx.has_coordinator = true
		}
	}
	return ctx, true, domain.Domain_Error{}
}

@(private = "file")
destroy_match_context :: proc(ctx: ^Match_Context) {
	delete(ctx.sorted)
	delete(ctx.leases)
	delete(ctx.instances)
	delete(ctx.held)
}

@(private = "file")
task_has_live_lease :: proc(ctx: ^Match_Context, task_id: domain.Task_ID, kind: string, review_role := "") -> bool {
	for l in ctx.leases {
		if l.task_id != task_id || l.kind != kind do continue
		if kind == domain.LEASE_KIND_REVIEW && review_role != "" && l.review_role != review_role do continue
		return true
	}
	return false
}

// ---- placement (plan §4a) -------------------------------------------------------------

// resolve_placement: task pin → fleet row bridge_id → chain directory bridge →
// coordinator bridge. directory_id is the chain directory on that bridge ("" if
// none) — the unit of the ≤ 1 live work lease rule.
resolve_placement :: proc(ctx: ^Match_Context, task: domain.Task, fleet: domain.Task_Chain_Fleet, honour_pin: bool) -> (Placement, bool) {
	bridge_id := ""
	if honour_pin do bridge_id = strings.trim_space(task.bridge_id)
	if bridge_id == "" do bridge_id = strings.trim_space(fleet.bridge_id)
	if bridge_id == "" && len(ctx.dirs) > 0 do bridge_id = ctx.dirs[0].bridge_id
	if bridge_id == "" && ctx.has_coordinator do bridge_id = ctx.coordinator.bridge_id
	if bridge_id == "" do return Placement{}, false
	provider, model := fleet_model_on_bridge(fleet, bridge_id)
	return Placement{
		bridge_id    = bridge_id,
		directory_id = resolve_directory_for_bridge(ctx.dirs, bridge_id),
		provider     = provider,
		model        = model,
	}, true
}

// ---- work pass -----------------------------------------------------------------------

@(private = "file")
grant_work :: proc(svc: ^Service, u: ^Uow, ctx: ^Match_Context, task: domain.Task, trigger: Trigger) {
	assignee := brief_assignee(task.brief_json)
	evs, _ := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	view := fold_task(evs, fold_input_for_task(task, true))
	prefer := ""
	if view.last_release == .Changes_Requested || view.last_release == .Handoff || view.last_release == .Expired {
		prefer = last_attempt_holder(svc, task)
	}
	for fleet in ctx.fleets {
		if !fleet_row_has_role(fleet, domain.FLEET_ROLE_WORKER) do continue
		if assignee != "" && fleet.agent_id != assignee do continue
		placement, pok := resolve_placement(ctx, task, fleet, true)
		if !pok do continue
		if !bridge_online(svc, placement.bridge_id) do continue // held: bridge offline
		if placement.directory_id != "" && directory_has_work_lease_ctx(ctx, placement.directory_id) do continue
		inst, found := pick_instance(svc, u, ctx, fleet, placement, domain.FLEET_ROLE_WORKER, prefer)
		if !found do continue
		lease, gok, gerr := grant_in_uow(svc, u, Grant_Request{
			chain = ctx.chain, task = task, instance = inst,
			kind = domain.LEASE_KIND_WORK, delivery = domain.LEASE_DELIVERY_WAKE,
			placement = placement, actor = hub_actor(), trigger = trigger,
		})
		if !gok {
			fmt.eprintfln("[taskv2] match: work grant skipped task=%s inst=%s: %s", task.task_id, inst.agent_instance_id, gerr.message)
			continue
		}
		append(&ctx.leases, lease)
		ctx.held[inst.agent_instance_id] = true
		return
	}
}

// ---- review pass ---------------------------------------------------------------------

@(private = "file")
grant_reviews :: proc(svc: ^Service, u: ^Uow, ctx: ^Match_Context, task: domain.Task, trigger: Trigger) {
	roles := brief_review_roles(task.brief_json, context.temp_allocator)
	if len(roles) == 0 do return
	author_agent := ""
	if holder := last_attempt_holder(svc, task); holder != "" {
		if inst, iok, _ := iface.agent_get_instance(svc.agents, holder); iok do author_agent = inst.agent_id
	}
	reviews, _ := iface.taskchain_list_reviews_by_task(svc.repo, task.task_id, task.owner_user_id)
	// One review lease per needed (fleet row, role) pair — the gate is a strict
	// AND over the same pairs (gate.odin).
	for role in roles {
		for fleet in ctx.fleets {
			if !fleet_row_has_role(fleet, role) do continue
			if author_agent != "" && fleet.agent_id == author_agent do continue // never review your own work
			if !review_needed_from(reviews, task, fleet.agent_id, role) do continue
			if review_lease_live_for(ctx, svc, task.task_id, fleet.agent_id, role) do continue
			placement, pok := resolve_placement(ctx, task, fleet, false)
			if !pok do continue
			if !bridge_online(svc, placement.bridge_id) do continue
			inst, found := pick_instance(svc, u, ctx, fleet, placement, domain.FLEET_ROLE_REVIEWER, "")
			if !found do continue
			lease, gok, gerr := grant_in_uow(svc, u, Grant_Request{
				chain = ctx.chain, task = task, instance = inst,
				kind = domain.LEASE_KIND_REVIEW, review_role = role, delivery = domain.LEASE_DELIVERY_WAKE,
				placement = placement, actor = hub_actor(), trigger = trigger,
			})
			if !gok {
				fmt.eprintfln("[taskv2] match: review grant skipped task=%s inst=%s: %s", task.task_id, inst.agent_instance_id, gerr.message)
				continue
			}
			append(&ctx.leases, lease)
			ctx.held[inst.agent_instance_id] = true
		}
	}
}

// review_lease_live_for: an instance of `agent_id` already holds a review
// lease for `role` on the task.
@(private = "file")
review_lease_live_for :: proc(ctx: ^Match_Context, svc: ^Service, task_id: domain.Task_ID, agent_id, role: string) -> bool {
	for l in ctx.leases {
		if l.task_id != task_id || l.kind != domain.LEASE_KIND_REVIEW || l.review_role != role do continue
		for inst in ctx.instances do if inst.agent_instance_id == l.holder_instance_id && inst.agent_id == agent_id do return true
		if inst, ok, _ := iface.agent_get_instance(svc.agents, l.holder_instance_id); ok && inst.agent_id == agent_id do return true
	}
	return false
}

// ---- instance selection --------------------------------------------------------------

// pick_instance chooses WHO runs a grant for `fleet` on `placement.bridge_id`:
//   1. `prefer` (the previous holder) when it is lease-free and not dead;
//   2. a live, lease-free instance of the template on that bridge;
//   3. a stopped warm instance (same id re-bootstrapped by the wake);
//   4. JIT: a new instance when live count < fleet capacity (default 1).
// Coordinators are never candidates.
@(private = "file")
pick_instance :: proc(svc: ^Service, u: ^Uow, ctx: ^Match_Context, fleet: domain.Task_Chain_Fleet, placement: Placement, role: string, prefer: string) -> (domain.Agent_Instance, bool) {
	live_count := 0
	live_free := domain.Agent_Instance{}
	warm := domain.Agent_Instance{}
	preferred := domain.Agent_Instance{}
	have_live, have_warm, have_pref := false, false, false
	for inst in ctx.instances {
		if inst.agent_id != fleet.agent_id || inst.bridge_id != placement.bridge_id do continue
		if is_coordinator(svc, ctx.chain, inst.agent_instance_id) do continue
		disposition := agent.failed_instance_disposition(inst, ctx.now_ms)
		if disposition == .Dead do continue
		if disposition == .Hold { live_count += 1; continue }
		free := !ctx.held[inst.agent_instance_id]
		if instance_is_live(inst) || instance_is_pending(inst) {
			live_count += 1
			if free && !have_live { live_free = inst; have_live = true }
		} else if free && !have_warm {
			warm = inst
			have_warm = true
		}
		if free && prefer != "" && inst.agent_instance_id == prefer { preferred = inst; have_pref = true }
	}
	if have_pref do return preferred, true
	if have_live do return live_free, true
	if have_warm do return warm, true
	capacity := fleet.capacity
	if capacity < 1 do capacity = 1
	if live_count >= capacity do return {}, false
	return jit_prepare(svc, u, ctx, fleet, placement, role)
}

// jit_prepare reserves + writes a new instance (no network: the launch is the
// wake run[] entry after commit). The registry reservation is cancelled on
// rollback (Effects.reservations).
@(private = "file")
jit_prepare :: proc(svc: ^Service, u: ^Uow, ctx: ^Match_Context, fleet: domain.Task_Chain_Fleet, placement: Placement, role: string) -> (domain.Agent_Instance, bool) {
	if svc.agent_service == nil do return {}, false
	provider, model := resolve_launch_model(svc.agent_service, placement.bridge_id, placement.provider, placement.model)
	defer delete(provider)
	defer delete(model)
	project_id := domain.Project_ID("")
	if ctx.has_coordinator do project_id = ctx.coordinator.project_id
	auth := contracts.Auth_Context{user_id = string(ctx.chain.owner_user_id), kind = .User_Token, bridge_id = placement.bridge_id}
	input := agent.Create_Instance_Input{
		agent_id = fleet.agent_id, bridge_id = placement.bridge_id,
		provider = provider, model = model,
		chain_id = string(ctx.chain.chain_id), project_id = project_id,
		member_role = "worker",
	}
	inst, generation, ok, err := agent.prepare_instance(svc.agent_service, auth, input)
	if !ok {
		fmt.eprintfln("[taskv2] match: JIT %s for agent %s on bridge %s failed: %s", role, fleet.agent_id, placement.bridge_id, err.message)
		return {}, false
	}
	if u != nil do append(&u.effects.reservations, Jit_Reservation{bridge_id = inst.bridge_id, generation = generation, instance_id = inst.agent_instance_id})
	append(&ctx.instances, inst)
	return inst, true
}

// ---- inline grant for a pulling instance (lease.next) ------------------------------

// grant_inline_for_instance is the matcher restricted to ONE candidate holder:
// the instance that just called `lease.next`. Same ordering (review first, then
// work by priority), same checks (grant_in_uow), delivery=inline so the caller
// is never woken. Returns the lease and its task when something was granted.
grant_inline_for_instance :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain, inst: domain.Agent_Instance, trigger: Trigger) -> (domain.Task_Lease, domain.Task, bool) {
	if chain.publish_state != .Published || chain.status != .Active do return {}, {}, false
	if is_coordinator(svc, chain, inst.agent_instance_id) do return {}, {}, false
	metric_matcher_run(trigger)
	ctx, ok, _ := load_match_context(svc, chain)
	if !ok do return {}, {}, false
	defer destroy_match_context(&ctx)
	if ctx.held[inst.agent_instance_id] do return {}, {}, false
	fleet := domain.Task_Chain_Fleet{}
	has_fleet := false
	for f in ctx.fleets do if f.agent_id == inst.agent_id { fleet = f; has_fleet = true; break }
	if !has_fleet do return {}, {}, false

	// Review pass.
	for task in ctx.sorted {
		if task.state != .In_Review || task.kind == .Gate do continue
		roles := brief_review_roles(task.brief_json, context.temp_allocator)
		if len(roles) == 0 do continue
		author_agent := ""
		if holder := last_attempt_holder(svc, task); holder != "" {
			if h, hok, _ := iface.agent_get_instance(svc.agents, holder); hok do author_agent = h.agent_id
		}
		if author_agent == inst.agent_id do continue
		reviews, _ := iface.taskchain_list_reviews_by_task(svc.repo, task.task_id, task.owner_user_id)
		for role in roles {
			if !fleet_row_has_role(fleet, role) do continue
			if !review_needed_from(reviews, task, fleet.agent_id, role) do continue
			if review_lease_live_for(&ctx, svc, task.task_id, fleet.agent_id, role) do continue
			placement, pok := resolve_placement(&ctx, task, fleet, false)
			if !pok do placement = Placement{bridge_id = inst.bridge_id}
			placement.bridge_id = inst.bridge_id // the caller is where it is
			placement.directory_id = resolve_directory_for_bridge(ctx.dirs, inst.bridge_id)
			lease, gok, _ := grant_in_uow(svc, u, Grant_Request{
				chain = chain, task = task, instance = inst,
				kind = domain.LEASE_KIND_REVIEW, review_role = role, delivery = domain.LEASE_DELIVERY_INLINE,
				placement = placement, actor = Actor{kind = ACTOR_AGENT, id = inst.agent_instance_id}, trigger = trigger,
			})
			if gok {
				fresh, _, _ := iface.taskchain_get_task(svc.repo, task.task_id)
				return lease, fresh, true
			}
		}
	}
	// Work pass.
	if !fleet_row_has_role(fleet, domain.FLEET_ROLE_WORKER) do return {}, {}, false
	for task in ctx.sorted {
		if task.state != .Ready || task.kind == .Gate do continue
		if task_has_live_lease(&ctx, task.task_id, domain.LEASE_KIND_WORK) do continue
		if assignee := brief_assignee(task.brief_json); assignee != "" && assignee != inst.agent_id do continue
		if task.bridge_id != "" && task.bridge_id != inst.bridge_id do continue
		placement, pok := resolve_placement(&ctx, task, fleet, true)
		if !pok do placement = Placement{bridge_id = inst.bridge_id}
		if placement.bridge_id != inst.bridge_id do continue
		if placement.directory_id != "" && directory_has_work_lease_ctx(&ctx, placement.directory_id) do continue
		lease, gok, _ := grant_in_uow(svc, u, Grant_Request{
			chain = chain, task = task, instance = inst,
			kind = domain.LEASE_KIND_WORK, delivery = domain.LEASE_DELIVERY_INLINE,
			placement = placement, actor = Actor{kind = ACTOR_AGENT, id = inst.agent_instance_id}, trigger = trigger,
		})
		if gok {
			fresh, _, _ := iface.taskchain_get_task(svc.repo, task.task_id)
			return lease, fresh, true
		}
	}
	return {}, {}, false
}

// ---- helpers -----------------------------------------------------------------------------

fleet_row_has_role :: proc(f: domain.Task_Chain_Fleet, role: string) -> bool {
	roles := jsonx.decode_string_array(f.roles_json if f.roles_json != "" else domain.FLEET_ROLES_DEFAULT_JSON, context.temp_allocator)
	for r in roles do if r == role do return true
	return false
}

// last_attempt_holder: the holder of the highest-numbered attempt row.
last_attempt_holder :: proc(svc: ^Service, task: domain.Task) -> string {
	attempts, err := iface.taskchain_list_attempts_by_task(svc.repo, task.task_id, task.owner_user_id)
	if err.code != .None do return ""
	best := domain.Task_Attempt{attempt_no = -1}
	for a in attempts do if a.attempt_no > best.attempt_no do best = a
	return best.holder_instance_id if best.attempt_no >= 0 else ""
}

@(private = "file")
directory_has_work_lease_ctx :: proc(ctx: ^Match_Context, directory_id: string) -> bool {
	for l in ctx.leases {
		if l.kind != domain.LEASE_KIND_WORK do continue
		if resolve_directory_for_bridge(ctx.dirs, l.bridge_id) == directory_id do return true
	}
	return false
}

_ :: platform
