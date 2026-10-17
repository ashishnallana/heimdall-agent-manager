package taskv2

import "core:fmt"
import "core:strings"
import "core:sync"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import agent "odin_test:hub/service/agent"
import events "odin_test:hub/service/events"
import project "odin_test:hub/service/project"

import lockorder "odin_test:lib/lockorder"
import jsonx "odin_test:lib/jsonx"

// Service is the Task System v2 engine: events + fold (M0), leases, timers and
// the matcher (M1). It sits BELOW the taskchain service (which calls into it on
// every chain/task mutation) and above the agent service (JIT instances, bridge
// lookups, wakes).
//
// Concurrency contract: every entry point that mutates state is exactly ONE
// unit of work (with_uow: begin_uow / end_uow) under sqlite.tx_mutex, and
// lockorder (src/lib/lockorder) enforces tx_mutex -> state_mutex. Nothing in a UoW
// touches the network; bridge wakes and user-event publishes are queued on an
// Effects list and flushed AFTER commit.
Service :: struct {
	repo:                ^iface.Taskchain_Repository,
	agents:              ^iface.Agent_Repository,
	bridges:             ^iface.Bridge_Repository,
	clock:               ^platform.Clock,
	ids:                 ^platform.ID_Generator,
	// uow_factory may be nil (unit tests over fake repos): mutations then run
	// without a transaction, which is fine for in-memory fakes.
	uow_factory:         ^iface.Unit_Of_Work_Factory,
	agent_service:       ^agent.Agent_Service,
	bridge_command_sink: project.Bridge_Command_Sink,
	event_bus:           ^events.User_Event_Bus,
	// on_tasks_changed is called AFTER commit whenever a task of `chain_id`
	// reached a terminal state or left one, so the owning taskchain service can
	// auto-complete / reopen the chain (sync_chain_status_from_tasks). It is a
	// callback because taskchain imports taskv2, not the other way round.
	on_tasks_changed:     proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID),
	on_tasks_changed_ctx: rawptr,
	// M1 state (timers / lease cache) lives behind this mutex; see timers.odin.
	state_mutex:         sync.Mutex,
	timers:              Timer_Service,
	// recent_expiries: holder → expiry time (ms) for the lease.next refusal
	// window; guarded by state_mutex, keys heap-owned (lease.odin).
	recent_expiries:     map[string]i64,
	// wake_observer sees every wake_agent push after commit (tests).
	wake_observer:       proc(ctx: rawptr, cmd: Wake_Command),
	wake_observer_ctx:   rawptr,
	// notify_observer sees every 1-line coordinator attention notification after commit (tests).
	notify_observer:     proc(ctx: rawptr, instance_id, trigger, line: string),
	notify_observer_ctx: rawptr,
	// vcs_show_file resolves a file at a commit on a chain directory via the bridge (M3 R2.2).
	vcs_show_file:       proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, directory_id, rev, file_path: string) -> (string, bool, domain.Domain_Error),
	vcs_show_file_ctx:   rawptr,
}

new_service :: proc(repo: ^iface.Taskchain_Repository, agents: ^iface.Agent_Repository, bridges: ^iface.Bridge_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Service {
	init_task_metrics()
	return Service{repo = repo, agents = agents, bridges = bridges, clock = clock, ids = ids}
}

// Trigger names the event that caused a chain re-evaluation; it labels
// heimdall_task_matcher_runs_total{trigger} (never an id).
Trigger :: enum {
	Boot,
	Chain_Published,
	Task_Published,
	Task_Created,
	Task_Updated,
	Dep_Added,
	Dep_Removed,
	Lease_Released,
	Lease_Expired,
	Review_Posted,
	Fleet_Changed,
	Instance_Terminal,
	Bridge_Hello,
	Chain_Closed,
	Task_Cancelled,
	Task_Reopened,
	Timer,
	Lease_Next,
	Start_Success,
}

trigger_label :: proc(t: Trigger) -> string {
	switch t {
	case .Boot: return "boot"
	case .Chain_Published: return "chain_published"
	case .Task_Published: return "task_published"
	case .Task_Created: return "task_created"
	case .Task_Updated: return "task_updated"
	case .Dep_Added: return "dep_added"
	case .Dep_Removed: return "dep_removed"
	case .Lease_Released: return "lease_released"
	case .Lease_Expired: return "lease_expired"
	case .Review_Posted: return "review_posted"
	case .Fleet_Changed: return "fleet_changed"
	case .Instance_Terminal: return "instance_terminal"
	case .Bridge_Hello: return "bridge_hello"
	case .Chain_Closed: return "chain_closed"
	case .Task_Cancelled: return "task_cancelled"
	case .Task_Reopened: return "task_reopened"
	case .Timer: return "timer"
	case .Lease_Next: return "lease_next"
	case .Start_Success: return "start_success"
	}
	return "unknown"
}

// ---- unit of work + post-commit effects ----------------------------------------

// Effects collects the side effects a UoW decided on; they run after COMMIT.
Effects :: struct {
	// wake runs/stops keyed by bridge id (see wake.odin, M1).
	runs:        map[string][dynamic]agent.Wake_Agent_Run_Entry,
	stops:       map[string][dynamic]string,
	// resource_changed publishes: (owner, resource, id, change)
	publishes:   [dynamic]Publish_Effect,
	// chains whose task set changed terminal-ness (→ on_tasks_changed).
	changed_chains: [dynamic]Changed_Chain,
	// JIT launch reservations taken in the bridge runtime registry during this
	// UoW; cancelled on rollback (the instance row is rolled back with the tx).
	reservations: [dynamic]Jit_Reservation,
	// 1-line coordinator attention notifications (M3 §3c), flushed after commit.
	notifications: [dynamic]Coordinator_Notification,
	// task-branch merge-backs for tasks that became done (merge.odin).
	merges: [dynamic]Merge_Effect,
	// one-line nudges typed into an agent's terminal (F2 resume after outage).
	nudges: [dynamic]Agent_Nudge,
	// keys owns the (bridge × chain) map keys of runs/stops (heap-cloned per
	// UoW, freed in destroy_effects — never the request's temp allocator).
	keys: [dynamic]string,
}

Coordinator_Notification :: struct {
	coordinator_instance_id: string,
	bridge_id:               string,
	chain_id:                string,
	owner:                   string,
	trigger:                 string,
	line:                    string,
}

// effects_key returns the owned "<bridge>\x00<chain>" key for runs/stops,
// cloning it once per UoW.
effects_key :: proc(e: ^Effects, bridge_id, chain_id: string) -> string {
	probe := fmt.tprintf("%s\x00%s", bridge_id, chain_id)
	for k in e.keys do if k == probe do return k
	owned := strings.clone(probe)
	append(&e.keys, owned)
	return owned
}

Jit_Reservation :: struct {
	bridge_id:   string,
	generation:  int,
	instance_id: string,
}

Publish_Effect :: struct {
	owner:       string,
	resource:    string,
	resource_id: string,
	change:      string,
	chain_id:    string,
}

Changed_Chain :: struct {
	chain_id: domain.Task_Chain_ID,
	owner:    domain.User_ID,
}

Uow :: struct {
	tx:      iface.Unit_Of_Work,
	has_tx:  bool,
	effects: Effects,
}

// begin_uow opens the engine's unit of work (process-wide exclusive). A service
// without a uow_factory (tests) gets a no-op transaction.
begin_uow :: proc(svc: ^Service) -> (Uow, bool, domain.Domain_Error) {
	u := Uow{}
	u.effects.runs = make(map[string][dynamic]agent.Wake_Agent_Run_Entry)
	u.effects.stops = make(map[string][dynamic]string)
	u.effects.publishes = make([dynamic]Publish_Effect)
	u.effects.changed_chains = make([dynamic]Changed_Chain)
	u.effects.reservations = make([dynamic]Jit_Reservation)
	u.effects.notifications = make([dynamic]Coordinator_Notification)
	u.effects.merges = make([dynamic]Merge_Effect)
	u.effects.nudges = make([dynamic]Agent_Nudge)
	u.effects.keys = make([dynamic]string)
	if svc.uow_factory == nil {
		lockorder.assert_tx_mutex_allowed()
		return u, true, domain.Domain_Error{}
	}
	tx, ok, err := iface.unit_of_work_begin(svc.uow_factory)
	if !ok do return u, false, err
	u.tx = tx
	u.has_tx = true
	return u, true, domain.Domain_Error{}
}

// end_uow commits (ok) or rolls back (!ok) and, on commit, flushes the effects
// — network I/O strictly after the lock is released. A NESTED unit of work
// (SAVEPOINT inside a caller's transaction) hands its effects to the outer
// transaction's after-commit hooks instead of flushing under the lock (S7).
end_uow :: proc(svc: ^Service, u: ^Uow, ok: bool) -> (bool, domain.Domain_Error) {
	committed := ok
	err := domain.Domain_Error{}
	nested := u.has_tx && u.tx.nested
	if u.has_tx {
		if ok && nested {
			// Register BEFORE the savepoint release so a failed release drops it.
			d := new(Deferred_Effects)
			d.svc = svc
			d.effects = u.effects
			if iface.unit_of_work_after_commit(&u.tx, iface.After_Commit_Hook{ctx = rawptr(d), run = deferred_effects_run}) {
				u.effects = Effects{} // ownership moved
			} else {
				free(d)
				nested = false
			}
		}
		if ok {
			committed, err = iface.unit_of_work_commit(&u.tx)
		} else {
			iface.unit_of_work_rollback(&u.tx)
		}
		u.has_tx = false
	}
	if committed && !nested do flush_effects(svc, &u.effects)
	else if !committed do cancel_reservations(svc, &u.effects)
	destroy_effects(&u.effects)
	return committed, err
}

Deferred_Effects :: struct {
	svc:     ^Service,
	effects: Effects,
}

@(private = "file")
deferred_effects_run :: proc(ctx: rawptr) {
	d := (^Deferred_Effects)(ctx)
	if d == nil do return
	flush_effects(d.svc, &d.effects)
	destroy_effects(&d.effects)
	free(d)
}

@(private = "file")
cancel_reservations :: proc(svc: ^Service, e: ^Effects) {
	if svc.agent_service == nil do return
	for r in e.reservations {
		project.bridge_runtime_instance_cancel_reservation(svc.agent_service.bridge_runtime_registry, r.bridge_id, r.generation, r.instance_id)
	}
}

@(private = "file")
destroy_effects :: proc(e: ^Effects) {
	for _, entries in e.runs do delete(entries)
	delete(e.runs)
	for _, entries in e.stops do delete(entries)
	delete(e.stops)
	delete(e.publishes)
	delete(e.changed_chains)
	delete(e.reservations)
	for n in e.notifications {
		delete(n.coordinator_instance_id)
		delete(n.bridge_id)
		delete(n.chain_id)
		delete(n.owner)
		delete(n.trigger)
		delete(n.line)
	}
	delete(e.notifications)
	for m in e.merges do destroy_merge_effect(m)
	delete(e.merges)
	for n in e.nudges { delete(n.instance_id); delete(n.bridge_id); delete(n.line) }
	delete(e.nudges)
	for k in e.keys do delete(k)
	delete(e.keys)
}

@(private = "file")
flush_effects :: proc(svc: ^Service, e: ^Effects) {
	flush_wakes(svc, e)
	for n in e.notifications {
		if svc.notify_observer != nil {
			svc.notify_observer(svc.notify_observer_ctx, n.coordinator_instance_id, n.trigger, n.line)
		}
		if n.bridge_id != "" && svc.bridge_command_sink.send_runtime_command != nil {
			cmd_id := platform.generate_id(svc.ids, "cmd_notify_")
			cmd_json := agent.agent_pty_input_command_json(cmd_id, n.coordinator_instance_id, strings.concatenate({n.line, "\r"}, context.temp_allocator))
			defer delete(cmd_json)
			_, _ = project.bridge_command_send_runtime(svc.bridge_command_sink, project.Runtime_Command{
				bridge_id  = n.bridge_id,
				command_id = cmd_id,
				body_json  = cmd_json,
			})
		}
		if svc.event_bus != nil {
			summary := fmt.tprintf("{{\"coordinator_instance_id\":\"%s\",\"chain_id\":\"%s\",\"trigger\":\"%s\"}}", n.coordinator_instance_id, n.chain_id, n.trigger)
			events.publish_resource_changed(svc.event_bus, n.owner, "coordinator_attention", n.coordinator_instance_id, n.trigger, summary)
		}
	}
	for p in e.publishes {
		if svc.event_bus == nil do continue
		summary := fmt.tprintf("{{\"%s_id\":\"%s\",\"chain_id\":\"%s\"}}", p.resource, p.resource_id, p.chain_id)
		events.publish_resource_changed(svc.event_bus, p.owner, p.resource, p.resource_id, p.change, summary)
	}
	for c in e.changed_chains {
		if svc.on_tasks_changed != nil do svc.on_tasks_changed(svc.on_tasks_changed_ctx, c.chain_id, c.owner)
	}
	flush_merges(svc, e)
	for n in e.nudges {
		if svc.bridge_command_sink.send_runtime_command == nil do break
		cmd_id := platform.generate_id(svc.ids, "cmd_nudge_")
		cmd_json := agent.agent_pty_input_command_json(cmd_id, n.instance_id, strings.concatenate({n.line, "\r"}, context.temp_allocator))
		defer delete(cmd_json)
		_, _ = project.bridge_command_send_runtime(svc.bridge_command_sink, project.Runtime_Command{bridge_id = n.bridge_id, command_id = cmd_id, body_json = cmd_json})
	}
}

Agent_Nudge :: struct {
	instance_id: string,
	bridge_id:   string,
	line:        string,
}

// effect_nudge_instance queues one line typed into an agent's terminal after
// commit; deduplicated per instance within the unit of work.
effect_nudge_instance :: proc(u: ^Uow, instance_id, bridge_id, line: string) {
	if u == nil || instance_id == "" || bridge_id == "" do return
	for n in u.effects.nudges do if n.instance_id == instance_id do return
	append(&u.effects.nudges, Agent_Nudge{instance_id = strings.clone(instance_id), bridge_id = strings.clone(bridge_id), line = strings.clone(first_line_trimmed(line))})
}

// effect_notify_coordinator queues a 1-line coordinator attention notification
// (plan §3c: proposal_decided, blocked_on human, budget_exhausted, oscillation,
// ready_unclaimed, chain_complete, review_requested_from_user, summary_overflow).
effect_notify_coordinator :: proc(svc: ^Service, u: ^Uow, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, trigger, line: string) {
	if svc == nil || svc.repo == nil || u == nil || strings.trim_space(line) == "" do return
	chain, cok, _ := iface.taskchain_get_chain(svc.repo, chain_id)
	if !cok do return
	coord_id := strings.trim_space(chain.coordinator_agent_instance_id)
	if coord_id == "" {
		if members, merr := iface.taskchain_list_members_by_chain(svc.repo, chain_id, owner); merr.code == .None {
			for m in members do if m.role == "coordinator" && m.agent_instance_id != "" { coord_id = m.agent_instance_id; break }
		}
	}
	if coord_id == "" do return
	bridge_id := ""
	if svc.agents != nil {
		if inst, iok, _ := iface.agent_get_instance(svc.agents, coord_id); iok do bridge_id = inst.bridge_id
	}
	clean_line := first_line_trimmed(line)
	for existing in u.effects.notifications {
		if existing.coordinator_instance_id == coord_id && existing.trigger == trigger && existing.line == clean_line do return
	}
	append(&u.effects.notifications, Coordinator_Notification{
		coordinator_instance_id = strings.clone(coord_id),
		bridge_id               = strings.clone(bridge_id),
		chain_id                = strings.clone(string(chain_id)),
		owner                   = strings.clone(string(owner)),
		trigger                 = strings.clone(trigger),
		line                    = strings.clone(clean_line),
	})
}

first_line_trimmed :: proc(s: string) -> string {
	t := strings.trim_space(s)
	if nl := strings.index_byte(t, '\n'); nl >= 0 do t = strings.trim_space(t[:nl])
	if cr := strings.index_byte(t, '\r'); cr >= 0 do t = strings.trim_space(t[:cr])
	return t
}

effect_publish_task :: proc(u: ^Uow, task: domain.Task, change: string) {
	append(&u.effects.publishes, Publish_Effect{owner = string(task.owner_user_id), resource = "task", resource_id = string(task.task_id), change = change, chain_id = string(task.chain_id)})
}

effect_publish_chain :: proc(u: ^Uow, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, change: string) {
	append(&u.effects.publishes, Publish_Effect{owner = string(owner), resource = "task_chain", resource_id = string(chain_id), change = change, chain_id = string(chain_id)})
}

effect_tasks_changed :: proc(u: ^Uow, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) {
	for c in u.effects.changed_chains do if c.chain_id == chain_id do return
	append(&u.effects.changed_chains, Changed_Chain{chain_id = chain_id, owner = owner})
}

// ---- event recording + projection -----------------------------------------------

// record_event appends an event for `task` inside the current UoW and refolds
// the task's cached projection. It returns the refolded task row (saved) and
// its view. `tasks`/`deps` are the chain snapshot used for deps_done; pass nil
// to have them loaded.
record_event :: proc(svc: ^Service, u: ^Uow, task: domain.Task, actor: Actor, kind: string, payload_json: string, tasks: []domain.Task = nil, deps: []domain.Task_Dependency = nil) -> (domain.Task, Task_View, bool, domain.Domain_Error) {
	if _, ok, err := append_event(svc.repo, svc.clock, task, actor, kind, payload_json); !ok {
		return task, Task_View{}, false, err
	}
	return refold_task(svc, u, task, tasks, deps)
}

// refold_task recomputes `task`'s view from its events and persists the
// projection fields when they changed. Terminal-ness changes are queued for the
// chain-status callback.
refold_task :: proc(svc: ^Service, u: ^Uow, task: domain.Task, tasks: []domain.Task = nil, deps: []domain.Task_Dependency = nil) -> (domain.Task, Task_View, bool, domain.Domain_Error) {
	all_tasks := tasks
	all_deps := deps
	if all_tasks == nil {
		loaded, err := iface.taskchain_list_tasks_by_chain(svc.repo, task.chain_id, task.owner_user_id)
		if err.code != .None do return task, Task_View{}, false, err
		all_tasks = loaded
	}
	if all_deps == nil {
		loaded, err := iface.taskchain_list_dependencies_by_chain(svc.repo, task.chain_id, task.owner_user_id)
		if err.code != .None do return task, Task_View{}, false, err
		all_deps = loaded
	}
	evs, ev_err := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	if ev_err.code != .None do return task, Task_View{}, false, ev_err
	view := fold_task(evs, fold_input_for_task(task, deps_done_for(task.task_id, all_tasks, all_deps)))
	now := platform.clock_now(svc.clock)
	next := apply_view_to_task(task, view, now)
	if projection_equal(task, next) do return task, view, true, domain.Domain_Error{}
	saved, ok, err := iface.taskchain_save_task(svc.repo, next)
	if !ok do return task, view, false, err
	if saved.state != task.state {
		metric_task_transition(task.state, saved.state)
	}
	// Column-backed alerts: ready_unclaimed (ready_since) and blocked-on-human
	// re-alert (blocked_on_json) are armed whenever the column they key on moves.
	if saved.ready_since != task.ready_since || saved.blocked_on_json != task.blocked_on_json || saved.state != task.state {
		arm_task_timers(svc, saved)
	}
	if u != nil {
		effect_publish_task(u, saved, "updated")
		if domain.task_state_is_terminal(task.state) != domain.task_state_is_terminal(saved.state) {
			effect_tasks_changed(u, saved.chain_id, saved.owner_user_id)
		}
		check_coordinator_attention_on_refold(svc, u, task, saved, view, all_tasks)
		if saved.state == .Done && task.state != .Done do effect_merge_worktree(svc, u, saved, evs)
	}
	return saved, view, true, domain.Domain_Error{}
}

@(private = "file")
check_coordinator_attention_on_refold :: proc(svc: ^Service, u: ^Uow, before, after: domain.Task, view: Task_View, all_tasks: []domain.Task) {
	if u == nil do return
	if after.blocked_on_json != before.blocked_on_json && after.blocked_on_json != "" {
		if view.budget_exhausted || strings.contains(after.blocked_on_json, `"budget_exhausted"`) {
			effect_notify_coordinator(svc, u, after.chain_id, after.owner_user_id, "budget_exhausted", fmt.tprintf("[taskv2] budget_exhausted: task %s (%s) exhausted attempt budget (#%d)", after.task_id, after.title, after.attempt_no))
		} else if view.oscillating || strings.contains(after.blocked_on_json, `"oscillation"`) {
			effect_notify_coordinator(svc, u, after.chain_id, after.owner_user_id, "oscillation", fmt.tprintf("[taskv2] oscillation: task %s (%s) parked after %d review rounds", after.task_id, after.title, view.review_rounds))
		} else if strings.contains(after.blocked_on_json, `"human"`) {
			effect_notify_coordinator(svc, u, after.chain_id, after.owner_user_id, "blocked_on human", fmt.tprintf("[taskv2] blocked_on human: task %s (%s) is waiting on human input", after.task_id, after.title))
		}
	}
	if after.state == .In_Review && before.state != .In_Review {
		// Notify coordinator when user approval is required and all agent review roles are already satisfied (or empty).
		if after.requires_user_approval && brief_review_roles_count(after.brief_json) == 0 {
			effect_notify_coordinator(svc, u, after.chain_id, after.owner_user_id, "review_requested_from_user", fmt.tprintf("[taskv2] review_requested_from_user: task %s (%s) is in_review and awaits user approval", after.task_id, after.title))
		}
	}
	if domain.task_state_is_terminal(after.state) && !domain.task_state_is_terminal(before.state) && len(all_tasks) > 0 {
		all_done := true
		for t in all_tasks {
			st := after.state if t.task_id == after.task_id else t.state
			if !domain.task_state_is_terminal(st) {
				all_done = false
				break
			}
		}
		if all_done {
			chain, cok, _ := iface.taskchain_get_chain(svc.repo, after.chain_id)
			if !cok || chain.kind != domain.CHAIN_KIND_WORKFLOW || workflow_all_stages_complete(svc, chain, all_tasks) {
				effect_notify_coordinator(svc, u, after.chain_id, after.owner_user_id, "chain_complete", fmt.tprintf("[taskv2] chain_complete: chain %s has all %d tasks in terminal state", after.chain_id, len(all_tasks)))
			}
		}
	}
}

@(private = "file")
projection_equal :: proc(a, b: domain.Task) -> bool {
	return a.state == b.state && a.attempt_no == b.attempt_no && a.blocked_on_json == b.blocked_on_json && a.ready_since == b.ready_since && a.started_at == b.started_at && a.completed_at == b.completed_at
}

// refold_chain recomputes every task of `chain` until the projection is stable
// (a task becoming done can make its dependents ready, which is a second
// pass). Bounded by the number of tasks.
refold_chain :: proc(svc: ^Service, u: ^Uow, chain: domain.Task_Chain) -> ([]domain.Task, bool, domain.Domain_Error) {
	tasks, err := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if err.code != .None do return nil, false, err
	deps, dep_err := iface.taskchain_list_dependencies_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if dep_err.code != .None do return nil, false, dep_err
	for pass := 0; pass < len(tasks) + 1; pass += 1 {
		changed := false
		for i in 0..<len(tasks) {
			before := tasks[i]
			after, _, ok, rerr := refold_task(svc, u, before, tasks, deps)
			if !ok do return tasks, false, rerr
			if after.state != before.state || after.attempt_no != before.attempt_no || after.blocked_on_json != before.blocked_on_json {
				changed = true
			}
			tasks[i] = after
		}
		if !changed do break
	}
	return tasks, true, domain.Domain_Error{}
}

// ---- chain-event entry points (called by the taskchain service) ------------------
// Each one is one UoW: event(s) → refold → match_chain (M1) → commit → effects.

task_created :: proc(svc: ^Service, task: domain.Task, actor: Actor) -> domain.Domain_Error {
	u, ok, err := begin_uow(svc)
	if !ok do return err
	payload := json_begin()
	json_raw(&payload, "brief", task.brief_json)
	_, _, rok, rerr := record_event(svc, &u, task, actor, EV_CREATED, json_end(&payload))
	if rok && task.publish_state == .Published {
		fresh, _, _ := iface.taskchain_get_task(svc.repo, task.task_id)
		_, _, rok, rerr = record_event(svc, &u, fresh, actor, EV_PUBLISHED, "{}")
	}
	if rok do rok, rerr = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Task_Created)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return rerr
	return cerr
}

task_published :: proc(svc: ^Service, task: domain.Task, actor: Actor) -> domain.Domain_Error {
	u, ok, err := begin_uow(svc)
	if !ok do return err
	_, _, rok, rerr := record_event(svc, &u, task, actor, EV_PUBLISHED, "{}")
	if rok do rok, rerr = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Task_Published)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return rerr
	return cerr
}

// chain_published records `published` for every task that just went live.
chain_published :: proc(svc: ^Service, chain: domain.Task_Chain, actor: Actor) -> domain.Domain_Error {
	u, ok, err := begin_uow(svc)
	if !ok do return err
	tasks, terr := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	rok := terr.code == .None
	rerr := terr
	if rok {
		for t in tasks {
			if !event_exists(svc, t, EV_PUBLISHED) {
				if _, aok, aerr := append_event(svc.repo, svc.clock, t, actor, EV_PUBLISHED, "{}"); !aok {
					rok = false
					rerr = aerr
					break
				}
			}
		}
	}
	if rok do rok, rerr = after_chain_change(svc, &u, chain.chain_id, chain.owner_user_id, .Chain_Published)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return rerr
	return cerr
}

// task_updated records an audit event; `fields` names what changed.
task_updated :: proc(svc: ^Service, task: domain.Task, actor: Actor, fields: []string) -> domain.Domain_Error {
	u, ok, err := begin_uow(svc)
	if !ok do return err
	payload := json_begin()
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for f, i in fields {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_byte(&b, '"')
		strings.write_string(&b, f)
		strings.write_byte(&b, '"')
	}
	strings.write_byte(&b, ']')
	json_raw(&payload, "fields", strings.to_string(b))
	_, _, rok, rerr := record_event(svc, &u, task, actor, EV_UPDATED, json_end(&payload))
	reviewers_changed := false
	for f in fields do if f == "reviewers" || f == "review_roles" || f == "brief" { reviewers_changed = true; break }
	if rok && reviewers_changed do rok, rerr = regate_after_reviewer_change(svc, &u, task, actor)
	if rok do rok, rerr = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Task_Updated)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return rerr
	return cerr
}

dep_added :: proc(svc: ^Service, task: domain.Task, depends_on: domain.Task_ID, actor: Actor) -> domain.Domain_Error {
	u, ok, err := begin_uow(svc)
	if !ok do return err
	payload := json_begin()
	json_str(&payload, "depends_on", string(depends_on))
	rok, rerr := on_dep_added_in_uow(svc, &u, task, actor)
	if rok {
		_, _, rok, rerr = record_event(svc, &u, task, actor, EV_DEP_ADDED, json_end(&payload))
	}
	if rok do rok, rerr = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Dep_Added)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return rerr
	return cerr
}

dep_removed :: proc(svc: ^Service, task: domain.Task, depends_on: domain.Task_ID, actor: Actor) -> domain.Domain_Error {
	u, ok, err := begin_uow(svc)
	if !ok do return err
	payload := json_begin()
	json_str(&payload, "depends_on", string(depends_on))
	_, _, rok, rerr := record_event(svc, &u, task, actor, EV_DEP_REMOVED, json_end(&payload))
	if rok do rok, rerr = after_chain_change(svc, &u, task.chain_id, task.owner_user_id, .Dep_Removed)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return rerr
	return cerr
}

// fleet_changed re-evaluates the chain after a fleet row upsert/delete.
fleet_changed :: proc(svc: ^Service, chain: domain.Task_Chain) -> domain.Domain_Error {
	u, ok, err := begin_uow(svc)
	if !ok do return err
	// A fleet row added/removed changes who must review: re-evaluate the gate
	// of every in_review task before matching (plan §2.4).
	rok, rerr := reevaluate_gates_in_uow(svc, &u, chain)
	if rok do rok, rerr = after_chain_change(svc, &u, chain.chain_id, chain.owner_user_id, .Fleet_Changed)
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return rerr
	return cerr
}

// task_comment records a `comment` audit event (no wake, no state change).
task_comment :: proc(svc: ^Service, task: domain.Task, actor: Actor, comment_id: string) -> domain.Domain_Error {
	u, ok, err := begin_uow(svc)
	if !ok do return err
	payload := json_begin()
	json_str(&payload, "comment_id", comment_id)
	_, aok, aerr := append_event(svc.repo, svc.clock, task, actor, EV_COMMENT, json_end(&payload))
	_, cerr := end_uow(svc, &u, aok)
	if !aok do return aerr
	return cerr
}

event_exists :: proc(svc: ^Service, task: domain.Task, kind: string) -> bool {
	evs, err := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	if err.code != .None do return false
	for e in evs do if e.kind == kind do return true
	return false
}

// after_chain_change is the one place every chain mutation funnels through
// inside its UoW: refold the chain's projections, materialise ready workflow
// stages, trigger on_output workflow spawns, rebuild the mechanical chain
// summary on task transitions, then run the matcher.
// release_task_blocks_in_uow clears a `blocked_on {kind: "task", ref}` badge
// once the referenced task is done: the hub records `answered` on the agent's
// behalf, so the task is ready again without a human. Covers both a ref that
// completes later and one that was already done when the agent blocked (both
// paths run after_chain_change). A ref in another chain is picked up on this
// chain's next change or on boot. Returns whether any task was released.
release_task_blocks_in_uow :: proc(svc: ^Service, u: ^Uow, tasks: []domain.Task) -> (bool, bool, domain.Domain_Error) {
	released := false
	for t in tasks {
		if t.state != .Backlog || strings.trim_space(t.blocked_on_json) == "" do continue
		if jsonx.extract_string(t.blocked_on_json, "kind", "", true, context.temp_allocator) != "task" do continue
		ref := strings.trim_space(jsonx.extract_string(t.blocked_on_json, "ref", "", true, context.temp_allocator))
		if ref == "" || ref == string(t.task_id) do continue
		ref_done := false
		found := false
		for o in tasks do if string(o.task_id) == ref { found = true; ref_done = o.state == .Done; break }
		if !found {
			if o, ok, _ := iface.taskchain_get_task(svc.repo, domain.Task_ID(ref)); ok && o.owner_user_id == t.owner_user_id do ref_done = o.state == .Done
		}
		if !ref_done do continue
		p := json_begin()
		json_bool(&p, "auto", true)
		json_str(&p, "reason", "ref_task_done")
		json_str(&p, "ref", ref)
		json_str(&p, "note", fmt.tprintf("referenced task %s is done", ref))
		if _, _, ok, err := record_event(svc, u, t, hub_actor(), EV_ANSWERED, json_end(&p), tasks); !ok do return released, false, err
		released = true
	}
	return released, true, domain.Domain_Error{}
}

after_chain_change :: proc(svc: ^Service, u: ^Uow, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, trigger: Trigger) -> (bool, domain.Domain_Error) {
	chain, ok, err := iface.taskchain_get_chain(svc.repo, chain_id)
	if !ok do return false, err
	tasks, rok, rerr := refold_chain(svc, u, chain)
	if !rok do return false, rerr
	if released, uok, uerr := release_task_blocks_in_uow(svc, u, tasks); !uok {
		return false, uerr
	} else if released {
		tasks, rok, rerr = refold_chain(svc, u, chain)
		if !rok do return false, rerr
	}
	if chain.kind == domain.CHAIN_KIND_WORKFLOW && chain.workflow_snapshot_json != "" {
		if mat_changed, mok, merr := materialize_ready_stages_in_uow(svc, u, chain); !mok {
			return false, merr
		} else if mat_changed {
			tasks, rok, rerr = refold_chain(svc, u, chain)
			if !rok do return false, rerr
		}
	}
	if tok, terr := trigger_on_output_workflows_in_uow(svc, u, chain, tasks); !tok {
		return false, terr
	}
	#partial switch trigger {
	case .Lease_Released, .Lease_Expired, .Review_Posted, .Task_Reopened, .Task_Cancelled, .Chain_Published, .Task_Published:
		rebuild_chain_summary_in_uow(svc, u, chain)
	}
	return match_chain_in_uow(svc, u, chain, trigger)
}
