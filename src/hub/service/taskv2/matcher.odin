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
	stage_caps := make(map[string]map[string]int, context.temp_allocator)
	for task in ctx.sorted {
		if task.state != .Ready || task.kind == .Gate do continue
		if task_has_live_lease(&ctx, task.task_id, domain.LEASE_KIND_WORK) do continue
		if task.stage_key != "" {
			if cap := workflow_task_max_parallel_cached(svc, &stage_caps, task); cap > 0 {
				if stage_live_work_lease_count(&ctx, task.workflow_run_id, task.workflow_execution_no, task.stage_key) >= cap do continue
			}
		}
		grant_work(svc, u, &ctx, task, trigger)
	}
	return true, domain.Domain_Error{}
}

@(private = "file")
stage_live_work_lease_count :: proc(ctx: ^Match_Context, run_id: domain.Workflow_Run_ID, execution_no: int, stage_key: string) -> int {
	count := 0
	for l in ctx.leases {
		if l.kind != domain.LEASE_KIND_WORK do continue
		for t in ctx.tasks {
			if t.task_id == l.task_id && t.workflow_run_id == run_id && t.workflow_execution_no == execution_no && t.stage_key == stage_key {
				count += 1
				break
			}
		}
	}
	return count
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
	if insts, ierr := iface.agent_list_instances_by_chain(svc.agents, chain.owner_user_id, string(chain.chain_id)); ierr.code == .None {
		for inst in insts do add(&ctx, &seen, inst)
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
	if view.last_release == .Changes_Requested || view.last_release == .Expired {
		prefer = last_attempt_holder(svc, task)
	}
	failure, failed_agent, failure_cause := "", "", ""
	failed_placement: Placement
	queued := false
	// Solo coordinators still pull their work; only an explicit user Start may
	// launch one. Their unavailable process nevertheless needs a user card.
	if ctx.has_coordinator && chain_is_solo(svc, ctx.chain) && (assignee == "" || assignee == ctx.coordinator.agent_id) {
		if !bridge_online(svc, ctx.coordinator.bridge_id) {
			failure, failed_agent, failure_cause = "bridge is offline", ctx.coordinator.agent_id, "bridge_offline"
			failed_placement = Placement{bridge_id = ctx.coordinator.bridge_id, provider = ctx.coordinator.provider, model = ctx.coordinator.model}
		} else if instance_is_live(ctx.coordinator) || instance_is_pending(ctx.coordinator) {
			queued = true
		} else {
			failure, failed_agent = instance_failure_reason(ctx.coordinator), ctx.coordinator.agent_id
			failed_placement = Placement{bridge_id = ctx.coordinator.bridge_id, provider = ctx.coordinator.provider, model = ctx.coordinator.model}
		}
	}
	for fleet in ctx.fleets {
		if ctx.has_coordinator && fleet.agent_id == ctx.coordinator.agent_id do continue
		if !fleet_row_has_role(fleet, domain.FLEET_ROLE_WORKER) do continue
		if assignee != "" && fleet.agent_id != assignee do continue
		if domain.fleet_role_paused(fleet, domain.FLEET_ROLE_WORKER) { queued = true; continue }
		placement, pok := resolve_placement(ctx, task, fleet, true)
		if !pok { failure, failed_agent, failure_cause = "no bridge placement can be resolved", fleet.agent_id, ""; continue }
		if placement.directory_id != "" && directory_has_work_lease_ctx(ctx, placement.directory_id) { queued = true; continue }
		if fleet_row_full(ctx, fleet, placement) { queued = true; continue }
		if !bridge_online(svc, placement.bridge_id) {
			failure, failed_agent, failed_placement, failure_cause = "bridge is offline", fleet.agent_id, placement, "bridge_offline"
			continue
		}
		if svc.agent_service != nil && svc.agent_service.providers != nil {
			provider, model := resolve_launch_model(svc.agent_service, placement.bridge_id, placement.provider, placement.model)
			defer delete(provider)
			defer delete(model)
			if _, valid, err := agent.validate_provider_model_intersection(svc.agent_service, placement.bridge_id, provider, model); !valid {
				failure, failed_agent, failed_placement, failure_cause = err.message, fleet.agent_id, placement, ""
				continue
			}
		}
		inst, found, why := pick_instance(svc, u, ctx, task, fleet, placement, domain.FLEET_ROLE_WORKER, prefer)
		if !found {
			if why != "" { failure, failed_agent, failed_placement, failure_cause = why, fleet.agent_id, placement, "" } else { queued = true }
			continue
		}
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
	if failure != "" && !queued do block_ready_agent_in_uow(svc, u, task, failed_agent, failed_placement, failure, failure_cause)
}

// ---- review pass ---------------------------------------------------------------------

@(private = "file")
grant_reviews :: proc(svc: ^Service, u: ^Uow, ctx: ^Match_Context, task: domain.Task, trigger: Trigger) {
	// A held task gets no new review lease (REQ-TV2-5).
	if task_is_held(task) do return
	author_agent := ""
	if holder := last_attempt_holder(svc, task); holder != "" {
		if inst, iok, _ := iface.agent_get_instance(svc.agents, holder); iok do author_agent = inst.agent_id
	}
	pairs := required_review_pairs(task, ctx.fleets[:], author_agent)
	if len(pairs) == 0 do return
	reviews, _ := iface.taskchain_list_reviews_by_task(svc.repo, task.task_id, task.owner_user_id)
	failure, failed_agent := "", ""
	failed_placement: Placement
	// One review lease per AGENT covering every pair it still owes (hybrid model);
	// the gate is a strict AND over the same pairs (gate.odin).
	for agent_id in distinct_review_agents(pairs) {
		fleet, has_row := fleet_row_for_agent(ctx.fleets[:], agent_id)
		if !has_row do continue
		owed := unpaused_review_roles(fleet, owed_review_roles(pairs, reviews, task, agent_id))
		if len(owed) == 0 do continue
		if review_lease_live_for(ctx, svc, task.task_id, agent_id, "") do continue
		placement, pok := resolve_placement(ctx, task, fleet, false)
		if !pok { failure, failed_agent, failed_placement = "no bridge placement can be resolved", agent_id, {}; continue }
		if !bridge_online(svc, placement.bridge_id) do continue // the bridge hello rematches
		inst, found, why := pick_instance(svc, u, ctx, task, fleet, placement, domain.FLEET_ROLE_REVIEWER, "")
		if !found {
			// Capacity and retriable backoff report no reason and simply wait.
			if why != "" do failure, failed_agent, failed_placement = why, agent_id, placement
			continue
		}
		lease, gok, gerr := grant_in_uow(svc, u, Grant_Request{
			chain = ctx.chain, task = task, instance = inst,
			kind = domain.LEASE_KIND_REVIEW, review_role = join_review_roles(owed), delivery = domain.LEASE_DELIVERY_WAKE,
			placement = placement, actor = hub_actor(), trigger = trigger,
		})
		if !gok {
			fmt.eprintfln("[taskv2] match: review grant skipped task=%s inst=%s: %s", task.task_id, inst.agent_instance_id, gerr.message)
			continue
		}
		append(&ctx.leases, lease)
		ctx.held[inst.agent_instance_id] = true
	}
	// An owed reviewer that cannot be placed would otherwise starve silently.
	// Surface it as the work path does (the same Start agent card); the block
	// takes the task out of the matcher's In_Review scan, so it is raised once.
	// While another review lease runs, its release rematches and decides then.
	if failure == "" do return
	for l in ctx.leases do if l.task_id == task.task_id && l.kind == domain.LEASE_KIND_REVIEW do return
	block_ready_agent_in_uow(svc, u, task, failed_agent, failed_placement, failure)
}

// review_lease_live_for: an instance of `agent_id` already holds a review
// lease on the task. One review lease per agent covers all its roles, so
// `role` only narrows the check when non-empty.
@(private = "file")
review_lease_live_for :: proc(ctx: ^Match_Context, svc: ^Service, task_id: domain.Task_ID, agent_id, role: string) -> bool {
	for l in ctx.leases {
		if l.task_id != task_id || l.kind != domain.LEASE_KIND_REVIEW do continue
		if role != "" {
			covers := false
			for r in split_review_roles(l.review_role) do if r == role { covers = true; break }
			if !covers do continue
		}
		for inst in ctx.instances do if inst.agent_instance_id == l.holder_instance_id && inst.agent_id == agent_id do return true
		if inst, ok, _ := iface.agent_get_instance(svc.agents, l.holder_instance_id); ok && inst.agent_id == agent_id do return true
	}
	return false
}

// Keep provider messages readable in both fleet and solo recovery cards.
instance_failure_reason :: proc(inst: domain.Agent_Instance) -> string {
	reason := fmt.tprintf("instance %s is %s", inst.agent_instance_id, inst.runtime_status)
	if message := jsonx.extract_string(inst.last_error_json, "message", "", true, context.temp_allocator); message != "" {
		return fmt.tprintf("%s: %s", reason, message)
	}
	return reason
}

// ---- instance selection --------------------------------------------------------------

// pick_instance chooses WHO runs a grant for `fleet` on `placement.bridge_id`:
//   1. `prefer` (the previous holder) when it is lease-free and not dead;
//   2. a live, lease-free instance of the template on that bridge;
//   3. a stopped warm instance (same id re-bootstrapped by the wake);
//   4. JIT: a new instance when live count < fleet capacity (default 1).
// Coordinators are never candidates.
@(private = "file")
pick_instance :: proc(svc: ^Service, u: ^Uow, ctx: ^Match_Context, task: domain.Task, fleet: domain.Task_Chain_Fleet, placement: Placement, role: string, prefer: string) -> (domain.Agent_Instance, bool, string) {
	// The coordinator's own fleet row (solo mode) is pull-only: its agent
	// takes work through `lease next`, never by a wake grant, and a JIT copy of
	// it is never spawned (REQ-SOLO-2).
	if ctx.has_coordinator && fleet.agent_id == ctx.coordinator.agent_id do return {}, false, ""
	// Pause (REQ-TV2-5) is decided by the callers before a pick: grant_work
	// checks the worker role and grant_reviews filters the owed review roles
	// with unpaused_review_roles. `role` here is only the JIT spawn role, so a
	// pause check on it would let a paused `reviewer` suppress `security`.
	failure := ""
	live_count := 0
	live_free := domain.Agent_Instance{}
	stopping_free := domain.Agent_Instance{}
	warm := domain.Agent_Instance{}
	preferred := domain.Agent_Instance{}
	have_live, have_stopping, have_warm, have_pref := false, false, false, false
	for inst in ctx.instances {
		if inst.agent_id != fleet.agent_id || inst.bridge_id != placement.bridge_id do continue
		// F4: a person stopped this instance — never re-wake or re-grant it
		// (whatever its runtime state, including as prefer=last holder), and
		// do not count it toward capacity. Without another free instance, ask
		// the user to restart it instead of creating an unsolicited replacement.
		if inst.stopped_by == agent.STOPPED_BY_USER {
			failure = fmt.tprintf("instance %s was stopped by the user", inst.agent_instance_id)
			continue
		}
		if is_coordinator(svc, ctx.chain, inst.agent_instance_id) do continue
		disposition := agent.failed_instance_disposition(inst, ctx.now_ms)
		if disposition == .Hold {
			if werr, typed := agent.instance_last_error(inst); typed && werr.class == .retriable {
				// Standard rematches end at ten minutes; provider backoff may be
				// longer. Recheck this task just after the actual retry deadline.
				due := to_ms(inst.stopped_at) + agent.instance_retry_delay_ms(agent.instance_last_error_attempt(inst), werr.retry_after_ms)
				timers_arm(svc, .Rematch, string(task.task_id), due + 1000, domain.task_state_string(task.state))
				live_count += 1
				continue
			}
		}
		if disposition == .Dead || disposition == .Hold {
			failure = instance_failure_reason(inst)
			continue
		}
		free := !ctx.held[inst.agent_instance_id]
		stopping := u != nil && effect_has_stop(u, inst.bridge_id, string(ctx.chain.chain_id), inst.agent_instance_id)
		// An instance granted earlier in this pass is about to run even if it is a
		// stopped warm instance (the wake starts it after commit), so it counts
		// toward capacity. Without this, waking a warm instance and then JIT-ing
		// another in the same pass exceeded the fleet row's capacity.
		if !free && !(instance_is_live(inst) || instance_is_pending(inst)) {
			live_count += 1
			continue
		}
		if instance_is_live(inst) || instance_is_pending(inst) {
			live_count += 1
			if free {
				if stopping {
					if !have_stopping { stopping_free = inst; have_stopping = true }
				} else if !have_live {
					live_free = inst
					have_live = true
				}
			}
		} else if free && !have_warm {
			warm = inst
			have_warm = true
		}
		if free && prefer != "" && inst.agent_instance_id == prefer { preferred = inst; have_pref = true }
	}
	// Capacity bounds every pick that starts a process: a stopped previous
	// holder or warm instance is re-bootstrapped by the wake, so it may only be
	// chosen below capacity, exactly like a JIT (REQ-TV2-5).
	capacity := fleet.capacity
	if capacity < 1 do capacity = 1
	below_capacity := live_count < capacity
	if have_pref && (instance_is_live(preferred) || instance_is_pending(preferred) || below_capacity) do return preferred, true, ""
	if have_live do return live_free, true, ""
	if have_warm && below_capacity do return warm, true, ""
	if have_stopping do return stopping_free, true, ""
	if !below_capacity do return {}, false, ""
	if failure != "" do return {}, false, failure
	return jit_prepare(svc, u, ctx, fleet, placement, role)
}

// jit_prepare reserves + writes a new instance (no network: the launch is the
// wake run[] entry after commit). The registry reservation is cancelled on
// rollback (Effects.reservations).
@(private = "file")
jit_prepare :: proc(svc: ^Service, u: ^Uow, ctx: ^Match_Context, fleet: domain.Task_Chain_Fleet, placement: Placement, role: string) -> (domain.Agent_Instance, bool, string) {
	if svc.agent_service == nil do return {}, false, "agent launch service is unavailable"
	provider, model := resolve_launch_model(svc.agent_service, placement.bridge_id, placement.provider, placement.model)
	defer delete(provider)
	defer delete(model)
	project_id := domain.Project_ID("")
	if ctx.has_coordinator do project_id = ctx.coordinator.project_id
	auth := contracts.Auth_Context{user_id = string(ctx.chain.owner_user_id), kind = .Internal_User, bridge_id = placement.bridge_id}
	input := agent.Create_Instance_Input{
		agent_id = fleet.agent_id, bridge_id = placement.bridge_id,
		provider = provider, model = model,
		chain_id = string(ctx.chain.chain_id), project_id = project_id,
		member_role = "worker",
	}
	inst, generation, ok, err := agent.prepare_instance(svc.agent_service, auth, input)
	if !ok {
		fmt.eprintfln("[taskv2] match: JIT %s for agent %s on bridge %s failed: %s", role, fleet.agent_id, placement.bridge_id, err.message)
		return {}, false, err.message
	}
	if u != nil do append(&u.effects.reservations, Jit_Reservation{bridge_id = inst.bridge_id, generation = generation, instance_id = inst.agent_instance_id})
	effect_instance_changed(u, inst.agent_instance_id, "created")
	append(&ctx.instances, inst)
	return inst, true, ""
}

// ---- inline grant for a pulling instance (lease.next) ------------------------------

// grant_inline_for_instance is the matcher restricted to ONE candidate holder:
// the instance that just called `lease.next`. Same ordering (review first, then
// work by priority), same checks (grant_in_uow), delivery=inline so the caller
// is never woken. Returns the lease and its task when something was granted.
grant_inline_for_instance :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain, inst: domain.Agent_Instance, trigger: Trigger) -> (domain.Task_Lease, domain.Task, bool) {
	if chain.publish_state != .Published || chain.status != .Active do return {}, {}, false
	coordinator := is_coordinator(svc, chain, inst.agent_instance_id)
	if coordinator && !chain_is_solo(svc, chain) do return {}, {}, false
	metric_matcher_run(trigger)
	ctx, ok, _ := load_match_context(svc, chain)
	if !ok do return {}, {}, false
	defer destroy_match_context(&ctx)
	if ctx.held[inst.agent_instance_id] do return {}, {}, false
	fleet, has_fleet := puller_fleet_row(&ctx, inst, coordinator)
	if !has_fleet do return {}, {}, false

	// Review pass. A solo coordinator never reviews: its work is reviewed by
	// the user (REQ-SOLO-5).
	for task in ctx.sorted {
		if coordinator do break
		if task.state != .In_Review || task.kind == .Gate || task_is_held(task) do continue
		author_agent := ""
		if holder := last_attempt_holder(svc, task); holder != "" {
			if h, hok, _ := iface.agent_get_instance(svc.agents, holder); hok do author_agent = h.agent_id
		}
		if author_agent == inst.agent_id do continue
		pairs := required_review_pairs(task, ctx.fleets[:], author_agent)
		if len(pairs) == 0 do continue
		reviews, _ := iface.taskchain_list_reviews_by_task(svc.repo, task.task_id, task.owner_user_id)
		owed := unpaused_review_roles(fleet, owed_review_roles(pairs, reviews, task, inst.agent_id))
		if len(owed) == 0 do continue
		if review_lease_live_for(&ctx, svc, task.task_id, inst.agent_id, "") do continue
		placement, pok := resolve_placement(&ctx, task, fleet, false)
		if !pok do placement = Placement{bridge_id = inst.bridge_id}
		placement.bridge_id = inst.bridge_id // the caller is where it is
		placement.directory_id = resolve_directory_for_bridge(ctx.dirs, inst.bridge_id)
		lease, gok, _ := grant_in_uow(svc, u, Grant_Request{
			chain = chain, task = task, instance = inst,
			kind = domain.LEASE_KIND_REVIEW, review_role = join_review_roles(owed), delivery = domain.LEASE_DELIVERY_INLINE,
			placement = placement, actor = Actor{kind = ACTOR_AGENT, id = inst.agent_instance_id}, trigger = trigger,
		})
		if gok {
			fresh, _, _ := iface.taskchain_get_task(svc.repo, task.task_id)
			return lease, fresh, true
		}
	}
	// Work pass.
	if !fleet_row_has_role(fleet, domain.FLEET_ROLE_WORKER) do return {}, {}, false
	if domain.fleet_role_paused(fleet, domain.FLEET_ROLE_WORKER) do return {}, {}, false
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

// grant_inline_task_for_instance: the work pass of grant_inline_for_instance
// restricted to ONE named task (lease switch). Returns why it cannot be granted.
grant_inline_task_for_instance :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain, inst: domain.Agent_Instance, task_id: domain.Task_ID, trigger: Trigger) -> (domain.Task_Lease, domain.Task, bool, domain.Domain_Error) {
	if chain.publish_state != .Published || chain.status != .Active do return {}, {}, false, domain.domain_error(.Conflict, "chain is not active")
	if is_coordinator(svc, chain, inst.agent_instance_id) && !chain_is_solo(svc, chain) do return {}, {}, false, domain.domain_error(.Conflict, "the chain coordinator works tasks only in solo mode")
	ctx, ok, err := load_match_context(svc, chain)
	if !ok do return {}, {}, false, err
	defer destroy_match_context(&ctx)
	fleet, has_fleet := puller_fleet_row(&ctx, inst, is_coordinator(svc, chain, inst.agent_instance_id))
	if !has_fleet || !fleet_row_has_role(fleet, domain.FLEET_ROLE_WORKER) do return {}, {}, false, domain.domain_error(.Conflict, "this agent is not a worker on the chain")
	if domain.fleet_role_paused(fleet, domain.FLEET_ROLE_WORKER) do return {}, {}, false, domain.domain_error(.Conflict, "this agent's worker role is paused on the chain")
	for task in ctx.sorted {
		if task.task_id != task_id do continue
		if task.state != .Ready || task.kind == .Gate do return {}, {}, false, domain.domain_error(.Conflict, "task is not ready")
		if task_has_live_lease(&ctx, task.task_id, domain.LEASE_KIND_WORK) do return {}, {}, false, domain.domain_error(.Conflict, "task is already held")
		if assignee := brief_assignee(task.brief_json); assignee != "" && assignee != inst.agent_id do return {}, {}, false, domain.domain_error(.Conflict, "task is assigned to another agent")
		if task.bridge_id != "" && task.bridge_id != inst.bridge_id do return {}, {}, false, domain.domain_error(.Conflict, "task is pinned to another bridge")
		placement, pok := resolve_placement(&ctx, task, fleet, true)
		if !pok do placement = Placement{bridge_id = inst.bridge_id}
		if placement.bridge_id != inst.bridge_id do return {}, {}, false, domain.domain_error(.Conflict, "task is placed on another bridge")
		lease, gok, gerr := grant_in_uow(svc, u, Grant_Request{
			chain = chain, task = task, instance = inst,
			kind = domain.LEASE_KIND_WORK, delivery = domain.LEASE_DELIVERY_INLINE,
			placement = placement, actor = Actor{kind = ACTOR_AGENT, id = inst.agent_instance_id}, trigger = trigger,
		})
		if !gok do return {}, {}, false, gerr
		fresh, _, _ := iface.taskchain_get_task(svc.repo, task.task_id)
		return lease, fresh, true, domain.Domain_Error{}
	}
	return {}, {}, false, domain.domain_error(.Not_Found, "task is not in this chain")
}

// puller_fleet_row: the fleet row an instance pulling work (`lease next`) works
// under. A solo coordinator without a row of its own (the built-in Soloist)
// works under an implicit worker row on its own bridge.
@(private = "file")
puller_fleet_row :: proc(ctx: ^Match_Context, inst: domain.Agent_Instance, coordinator: bool) -> (domain.Task_Chain_Fleet, bool) {
	for f in ctx.fleets do if f.agent_id == inst.agent_id do return f, true
	if coordinator {
		return domain.Task_Chain_Fleet{task_chain_id = ctx.chain.chain_id, agent_id = inst.agent_id, roles_json = `["worker"]`, capacity = 1}, true
	}
	return {}, false
}

// ---- helpers -----------------------------------------------------------------------------

// review_role_paused maps a LEASE review role onto the FLEET role namespace
// that pause uses (REQ-TV2-5). Review roles from brief.review_roles are fleet
// roles verbatim (`reviewer`, `security`, …), so each is paused only by its own
// name. A named review (NAMED_REVIEW_ROLE, a lease-only role) is paused by the
// row's generic review roles: `reviewer` or `named-reviewer`. `["*"]` pauses all.
review_role_paused :: proc(fleet: domain.Task_Chain_Fleet, lease_role: string) -> bool {
	if lease_role == NAMED_REVIEW_ROLE {
		return domain.fleet_role_paused(fleet, domain.FLEET_ROLE_REVIEWER) || domain.fleet_role_paused(fleet, FLEET_ROLE_NAMED_REVIEWER)
	}
	return domain.fleet_role_paused(fleet, lease_role)
}

// unpaused_review_roles drops the owed lease review roles paused on `fleet`.
// The single pause rule for review grants: wake (grant_reviews) and inline
// (grant_inline_for_instance) dispatch both filter through it.
unpaused_review_roles :: proc(fleet: domain.Task_Chain_Fleet, owed: []string) -> []string {
	if !domain.fleet_paused_any(fleet) do return owed
	kept := make([dynamic]string, context.temp_allocator)
	for r in owed do if !review_role_paused(fleet, r) do append(&kept, r)
	return kept[:]
}

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
	// One live work lease per chain directory. VCS directories are exempt only
	// for git when per-lease worktrees are on (PER_LEASE_WORKTREES_ENABLED);
	// otherwise two leases would share one checkout and wipe each other's work.
	if PER_LEASE_WORKTREES_ENABLED {
		for d in ctx.dirs {
			if d.directory_id == directory_id {
				if d.vcs_kind == "git" do return false
			}
		}
	}
	for l in ctx.leases {
		if l.kind != domain.LEASE_KIND_WORK do continue
		if resolve_directory_for_bridge(ctx.dirs, l.bridge_id) == directory_id do return true
	}
	return false
}

_ :: platform

// A full row is queueing even when its bridge is offline.
fleet_row_full :: proc(ctx: ^Match_Context, fleet: domain.Task_Chain_Fleet, placement: Placement) -> bool {
	count := 0
	for inst in ctx.instances {
		if inst.agent_id != fleet.agent_id || inst.bridge_id != placement.bridge_id do continue
		if ctx.held[inst.agent_instance_id] do count += 1
	}
	return count >= max(1, fleet.capacity)
}
