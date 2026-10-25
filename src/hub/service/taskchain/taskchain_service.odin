package taskchain

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"
import platform "odin_test:hub/platform"
import project "odin_test:hub/service/project"
import agent "odin_test:hub/service/agent"
import events "odin_test:hub/service/events"
import shell_session "odin_test:hub/service/shell_session"
import taskv2 "odin_test:hub/service/taskv2"
import jsonx "odin_test:lib/jsonx"
import json "core:encoding/json"

// Taskchain_Service owns chains, members, directories, fleets and the task ROWS
// (create/update/publish/comments/dependencies). Everything about a task's
// lifecycle after publish — state, leases, attempts, reviews, timers — is the
// Task System v2 engine's (service/taskv2), which this service calls on every
// mutation that can change who should act next. There is no manual reconcile.
Taskchain_Service :: struct {
	repo: ^iface.Taskchain_Repository,
	agents: ^iface.Agent_Repository,
	clock: ^platform.Clock,
	ids: ^platform.ID_Generator,
	bridge_command_sink: project.Bridge_Command_Sink,
	agent_service: ^agent.Agent_Service,
	event_bus: ^events.User_Event_Bus,
	// shell_sessions backs REQ-SHELL-9 trigger A: a closed chain's servers are
	// killed. Optional, like agent_service and event_bus above and set the same way
	// (set_shell_session_service) — a service constructed without it simply does not
	// reap, which keeps every existing test that builds a bare Taskchain_Service
	// working unchanged.
	shell_sessions: ^shell_session.Shell_Session_Service,
	// engine is the Task System v2 service. Optional for the same reason: a bare
	// service (tests) records nothing and schedules nothing.
	engine: ^taskv2.Service,
	// uow_factory (Task System v2, M2 / review C1): every mutating verb runs
	// its row writes AND the engine (events, refold, matcher) in ONE unit of
	// work under tx_mutex. The engine's own entry points nest as SAVEPOINTs
	// and hand their effects to the outer commit. nil in bare tests (autocommit).
	uow_factory: ^iface.Unit_Of_Work_Factory,
	// attention reports task/comment writes to the card projector (attention
	// deck). Optional: nil in bare test services; see attention_notify.odin.
	attention: ^contracts.Attention_Notifier,
}

// verb_begin / verb_end wrap a mutating taskchain verb in one unit of work.
// Without a factory (unit tests over fake repos) they are no-ops.
Verb_Tx :: struct {
	tx:  iface.Unit_Of_Work,
	has: bool,
}

verb_begin :: proc(service: ^Taskchain_Service) -> Verb_Tx {
	if service == nil || service.uow_factory == nil do return Verb_Tx{}
	tx, ok, _ := iface.unit_of_work_begin(service.uow_factory)
	if !ok do return Verb_Tx{}
	return Verb_Tx{tx = tx, has = true}
}

verb_end :: proc(v: ^Verb_Tx, ok: bool) -> domain.Domain_Error {
	if !v.has do return domain.Domain_Error{}
	v.has = false
	if ok {
		if committed, err := iface.unit_of_work_commit(&v.tx); !committed do return err
		return domain.Domain_Error{}
	}
	iface.unit_of_work_rollback(&v.tx)
	return domain.Domain_Error{}
}

set_uow_factory :: proc(service: ^Taskchain_Service, factory: ^iface.Unit_Of_Work_Factory) {
	service.uow_factory = factory
}

Create_Chain_Input :: struct {
	title: string,
	description: string,
	owner_user_id: string,
	// kind ∈ {ticket, workflow}; "" and the pre-v2 "team_work" mean ticket.
	kind: string,
	coordinator_agent_id: string,
}

Update_Chain_Input :: struct {
	title: string,
	description: string,
	// has_description distinguishes "absent" (leave as-is) from "explicitly set"
	// (including clearing to empty), mirroring has_coordinator.
	has_description: bool,
	status: string,
	// coordinator_agent_instance_id sets/changes the chain's designated coordinator
	// after creation (H5 finding: chains created via a user token had an empty
	// coordinator and PATCH could not set one). has_coordinator distinguishes
	// "absent" from "explicitly clear". The target must belong to the same chain.
	coordinator_agent_instance_id: string,
	has_coordinator: bool,
	// title_source records who set the title ("default"|"agent"|"user"). When an
	// agent or user explicitly renames the chain we stamp this so the activity-
	// gated title-nudge engine (T2) stops nudging. Empty = leave unchanged.
	title_source: string,
	is_pinned: bool,
	has_is_pinned: bool,
}

// Create_Task_Input (Task System v2). The brief carries goal/acceptance/
// inputs/review_roles/assignee/budget; the convenience fields below are merged
// into it so ctl/UI callers that only know assignee + reviewers keep working.
Create_Task_Input :: struct {
	chain_id: domain.Task_Chain_ID,
	title: string,
	description: string,
	owner_user_id: string,
	// brief_json: a JSON object; "" → built from title/description + the fields below.
	brief_json: string,
	// assignee_agent_id pins the worker TEMPLATE (brief.assignee). Instance pins are gone.
	assignee_agent_id: string,
	// review_roles: fleet roles whose rows must approve (brief.review_roles).
	review_roles: []string,
	// reviewer_agent_ids: templates to add to the chain fleet with the reviewer
	// role (legacy `--reviewer agt_…` spelling); implies review_roles ⊇ ["reviewer"].
	reviewer_agent_ids: []string,
	requires_user_approval: bool,
	has_requires_user_approval: bool,
	// priority sets the task priority (P0/P1/P2) at create time. has_priority
	// distinguishes an explicit choice from "field absent" so a create that omits
	// priority keeps the documented P2 default (REQ-CLI-2).
	priority: domain.Task_Priority,
	has_priority: bool,
	depends_on: []domain.Task_ID,
	// bridge_id pins the task to a specific bridge (REQ-TB-1). Empty = inherit
	// (resolved at grant time). A non-empty value must reference a bridge owned by
	// the chain owner.
	bridge_id: string,
	// kind: task (default) or gate (workflow materialiser only).
	kind: domain.Task_Kind,
}

Update_Task_Input :: struct {
	title: string,
	description: string,
	// brief_json replaces the whole brief when non-empty (409 while leased).
	brief_json: string,
	assignee_agent_id: string,
	has_assignee: bool,
	review_roles: []string,
	has_review_roles: bool,
	reviewer_agent_ids: []string,
	// has_reviewers: the request carried `reviewers` (possibly empty), so the
	// task's named reviewers are replaced; absent leaves them untouched.
	has_reviewers: bool,
	requires_user_approval: bool,
	has_requires_user_approval: bool,
	// priority sets the task priority (P0/P1/P2). has_priority distinguishes an
	// explicit change from "field absent" so a PATCH that omits priority leaves it
	// untouched. A priority change re-orders the matcher's ready queue.
	priority: domain.Task_Priority,
	has_priority: bool,
	depends_on: []domain.Task_ID,
	has_depends_on: bool,
	// bridge_id repins the task's bridge (REQ-TB-1). nil = field absent: leave the
	// current pin untouched. A non-nil pointer is the new value — pointing at ""
	// clears the pin back to inherit. A pin edit is a brief edit: 409 while leased.
	bridge_id: ^string,
}

Task_Comment_Input :: struct {
	task_id: domain.Task_ID,
	body: string,
	notify: []string,
}

Comment_Input :: struct {
	task_id: domain.Task_ID,
	body: string,
}

new_taskchain_service :: proc(repo: ^iface.Taskchain_Repository, agents: ^iface.Agent_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Taskchain_Service {
	return Taskchain_Service{repo = repo, agents = agents, clock = clock, ids = ids}
}

new_taskchain_service_with_runtime :: proc(repo: ^iface.Taskchain_Repository, agents: ^iface.Agent_Repository, bridge_command_sink: project.Bridge_Command_Sink, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Taskchain_Service {
	return Taskchain_Service{repo = repo, agents = agents, clock = clock, ids = ids, bridge_command_sink = bridge_command_sink}
}

set_agent_service :: proc(service: ^Taskchain_Service, agent_svc: ^agent.Agent_Service) {
	if service == nil do return
	service.agent_service = agent_svc
}

set_event_bus :: proc(service: ^Taskchain_Service, bus: ^events.User_Event_Bus) {
	if service == nil do return
	service.event_bus = bus
}

set_shell_session_service :: proc(service: ^Taskchain_Service, shell_svc: ^shell_session.Shell_Session_Service) {
	if service == nil do return
	service.shell_sessions = shell_svc
}

set_engine :: proc(service: ^Taskchain_Service, engine: ^taskv2.Service) {
	if service == nil do return
	service.engine = engine
}

// engine_actor maps the caller to the event actor recorded by the engine.
engine_actor :: proc(auth: contracts.Auth_Context) -> taskv2.Actor {
	return taskv2.actor_from_auth(auth)
}

// reap_chain_servers_on_close kills every live SERVER of a chain that has just reached a
// terminal status (REQ-SHELL-9 trigger A). It is a no-op for any other status and for a
// service with no shell-session service wired.
//
// WHY THIS PROC EXISTS RATHER THAN THREE INLINE CALLS: there are THREE paths that close a
// chain, and no single choke point that sees all three.
//   taskchain_service.odin:402  update_chain          — an explicit status in a PATCH
//   taskchain_service.odin:529  change_chain_status   — the dedicated verb
//   taskchain_service.odin:685  sync_chain_status_from_tasks — THE AUTO-COMPLETE
// The third is the one that matters: it is how a chain finishes in the normal case, when
// the last task reaches a terminal status. Hooking only the two manual paths — which is
// what REQ-SHELL-9's description originally prescribed — would have produced a feature
// that passes its tests and reaps nothing in production.
//
// CALLING ONE IDEMPOTENT PROC FROM EVERY CLOSE PATH IS NOT THE SAME AS HOPING PARTIAL
// COVERAGE ADDS UP. The reap refuses a server that is already terminal or already carries
// a kill intent (shell_session_reap.odin, _reap_kill_if_eligible), so running it twice is
// defined behaviour, not luck. That property is required by the task in its own right;
// this call pattern only depends on it.
//
// THE TERMINAL SET IS {Completed, Cancelled, Archived} — deliberately the SAME set
// broadcast_chain_closed uses below and fanout_chain_status_changed uses at
// subscription.odin:240, rather than a new narrower one. The user asked for "completes";
// cancelled must reap too, because the hub already tells every member "All task
// activities halted" on a cancel and a surviving server would make that a lie; archived
// must reap because valid_chain_transition allows Active -> Archived directly, so it is a
// real close path for a chain that was never completed. Reusing the existing set means
// this cannot drift from the hub's own notion of a closed chain.
//
// REOPENING (Completed -> Active) DOES NOT RESTART ANYTHING. The processes are gone and
// the hub cannot restart what it did not keep; whoever reopens a chain starts what they
// still need.
//
// Deliberately NOT hooked into fanout_chain_status_changed, which IS called by all three
// paths and already has the terminal test: it early-returns at subscription.odin:229 when
// no bridge command sink is configured, which would silently condition a lifecycle
// guarantee on a NOTIFICATION concern.
reap_chain_servers_on_close :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, next: domain.Task_Chain_Status) {
	if service == nil || service.shell_sessions == nil do return
	if next != .Completed && next != .Cancelled && next != .Archived do return
	_ = shell_session.shell_session_reap_chain_servers(service.shell_sessions, string(chain.owner_user_id), string(chain.chain_id))
}

// is_instance_member_or_coordinator: membership OR coordinator authority, read
// from the SINGLE canonical source (H9) — the task_chain_members table. The
// coordinator is just a member whose role is "coordinator"; both notions live in
// one table, so there is no dual-source drift.
is_instance_member_or_coordinator :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, instance_id: string) -> bool {
	if instance_id == "" do return false
	members, err := iface.taskchain_list_members_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if err.code != .None do return false
	for m in members {
		if m.agent_instance_id == instance_id do return true
	}
	return false
}

// is_chain_coordinator (H9): the SINGLE canonical source of who coordinates a
// chain is the task_chain_members table (a member with role == "coordinator").
// The task_chains.coordinator_agent_instance_id column is now only a DERIVED
// MIRROR kept for API/UI back-compat (stamped by coordinator_sync_mirror on
// write) and is NEVER consulted for authority here. This removes the dual-source
// drift where an empty column + a coordinator member locked the real coordinator
// out. Because it reads the members table, one agent can coordinate multiple
// chains and multiple agents could hold the coordinator role on a chain.
is_chain_coordinator :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, instance_id: string) -> bool {
	if instance_id == "" do return false
	members, err := iface.taskchain_list_members_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if err.code != .None do return false
	for m in members {
		if m.agent_instance_id == instance_id && m.role == "coordinator" do return true
	}
	return false
}

// coordinator_primary_instance returns the current coordinator instance id from
// the canonical members table (the earliest-created coordinator member if more
// than one holds the role), or "" if the chain has no coordinator member. Used to
// stamp the derived mirror column and to serialize coordinator identity.
coordinator_primary_instance :: proc(service: ^Taskchain_Service, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> string {
	members, err := iface.taskchain_list_members_by_chain(service.repo, chain_id, owner)
	if err.code != .None do return ""
	// list_members_by_chain is ordered by created_at ASC, so the first coordinator
	// encountered is the earliest-designated one.
	for m in members {
		if m.role == "coordinator" do return m.agent_instance_id
	}
	return ""
}

// coordinator_sync_mirror recomputes the derived coordinator_agent_instance_id
// mirror column from the canonical members table and persists the chain if it
// changed. Call after any coordinator-member mutation so the back-compat column
// always reflects the single source (never independently authoritative).
coordinator_sync_mirror :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain) -> domain.Task_Chain {
	primary := coordinator_primary_instance(service, chain.chain_id, chain.owner_user_id)
	if chain.coordinator_agent_instance_id == primary do return chain
	updated := chain
	updated.coordinator_agent_instance_id = primary
	saved, ok, _ := iface.taskchain_save_chain(service.repo, updated)
	if ok do return saved
	return updated
}

// set_chain_coordinator changes the coordinator via the canonical members table:
// demote any existing coordinator member(s) to "member", upsert the target as a
// "coordinator" member, then sync the derived mirror. An empty target clears the
// coordinator (all coordinators demoted). Returns the chain with the mirror
// stamped. Same-chain/same-owner validation of a non-empty target is the caller's
// responsibility (mirrors the existing agent_instance_same_chain check).
set_chain_coordinator :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, target_instance_id: string) -> domain.Task_Chain {
	now := platform.clock_now(service.clock)
	members, err := iface.taskchain_list_members_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if err.code == .None {
		for m in members {
			if strings.has_prefix(m.agent_instance_id, "agt_") {
				// Clean up any legacy phantom agent_id member
				iface.taskchain_remove_member(service.repo, chain.chain_id, m.agent_instance_id, chain.owner_user_id)
				continue
			}
			if m.role == "coordinator" && m.agent_instance_id != target_instance_id {
				demoted := m
				demoted.role = "member"
				iface.taskchain_save_member(service.repo, demoted)
			}
		}
	}
	if target_instance_id != "" {
		coordinator := domain.Task_Chain_Member{
			chain_id = chain.chain_id,
			agent_instance_id = target_instance_id,
			owner_user_id = chain.owner_user_id,
			role = "coordinator",
			created_at = now,
		}
		iface.taskchain_save_member(service.repo, coordinator)
	}
	return coordinator_sync_mirror(service, chain)
}

list_chains :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context) -> ([]domain.Task_Chain, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err
	chains, list_err := iface.taskchain_list_chains_by_owner(service.repo, owner)
	if list_err.code != .None do return nil, list_err
	// READ (REQ-SEC-3): owner-scoped, not membership-scoped. Both User_Token and
	// Instance_Token see ALL chains of their owner; an agent may list (and then
	// read) chains it is not a member of, as long as they belong to the same owner.
	// owner_from_auth above already guarantees cross-owner isolation.
	return chains, domain.Domain_Error{}
}

search_feed_revision :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context) -> (i64, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return 0, err
	return iface.taskchain_search_latest_revision(service.repo, owner)
}

search_feed_changes :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, after_revision: i64, limit: int) -> ([]domain.Task_Chain_Search_Change, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err
	return iface.taskchain_search_list_changes(service.repo, owner, after_revision, limit)
}

// list_chains_coordinated_by (H9 R4): the chains an agent instance coordinates,
// from the single canonical source (members table, role='coordinator'). When the
// caller is an Instance_Token and no explicit target is given, defaults to the
// caller's own instance. Owner-scoped: an instance token can only ever see its
// own owner's chains.
list_chains_coordinated_by :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, agent_instance_id: string) -> ([]domain.Task_Chain, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err
	target := agent_instance_id
	if target == "" && auth.kind == .Instance_Token do target = auth.agent_instance_id
	if target == "" do return nil, domain.domain_error(.Validation_Failed, "agent_instance_id is required")
	return iface.taskchain_list_chains_by_coordinator(service.repo, target, owner)
}

get_chain :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	chain, ok, err := iface.taskchain_get_chain(service.repo, chain_id)
	if !ok do return domain.Task_Chain{}, false, err
	if owner_ok, owner_err := ownership.require_owner(auth, chain.owner_user_id); !owner_ok do return domain.Task_Chain{}, false, owner_err
	if auth.kind == .Instance_Token {
		if !is_instance_member_or_coordinator(service, chain, auth.agent_instance_id) {
			return domain.Task_Chain{}, false, domain.domain_error(.Forbidden, "agent instance is not a member or coordinator of this chain")
		}
	}
	return chain, true, domain.Domain_Error{}
}

// get_chain_for_read (REQ-SEC-3): the READ-ONLY authorizer. It enforces ONLY
// ownership (require_owner) — an Instance_Token may read ANY chain of its own
// owner, even one it does not belong to (e.g. the Curator or a worker inspecting
// another coordinator's chain). It deliberately DROPS the membership check that
// get_chain applies; owner isolation is untouched (cross-owner still 404s via
// require_owner). WRITES must NOT use this — they call the membership-gated
// get_chain (plus their own coordinator/assignee guards).
get_chain_for_read :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	chain, ok, err := iface.taskchain_get_chain(service.repo, chain_id)
	if !ok do return domain.Task_Chain{}, false, err
	if owner_ok, owner_err := ownership.require_owner(auth, chain.owner_user_id); !owner_ok do return domain.Task_Chain{}, false, owner_err
	return chain, true, domain.Domain_Error{}
}

list_tasks :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID) -> ([]domain.Task, domain.Domain_Error) {
	// READ: owner-scoped, not membership-scoped (REQ-SEC-3).
	chain, ok, err := get_chain_for_read(service, auth, chain_id)
	if !ok do return nil, err
	return iface.taskchain_list_tasks_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
}

// task_counts_by_chain returns chain_id -> task count for the authenticated owner
// in one query. The task-chains list uses it to show per-chain totals and to drop
// empty chains without reading every chain's tasks. Caller owns the map.
task_counts_by_chain :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context) -> (map[string]iface.Chain_Task_Rollup, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return make(map[string]iface.Chain_Task_Rollup), err
	return iface.taskchain_task_counts_by_chain(service.repo, owner)
}

create_chain :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, input: Create_Chain_Input) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return domain.Task_Chain{}, false, err
	if input.title == "" do return domain.Task_Chain{}, false, domain.domain_error(.Validation_Failed, "chain title is required")
	// Only mixed_work is accepted; an empty value uses that same default at this
	// boundary. Deprecated execution types fail validation.
	kind, kind_ok := domain.normalize_chain_kind(input.kind)
	if !kind_ok do return domain.Task_Chain{}, false, domain.domain_error(.Validation_Failed, "all task chains use kind mixed_work; ticket/workflow chain types are unsupported")
	now := platform.clock_now(service.clock)
	coordinator_id := input.coordinator_agent_id
	if auth.kind == .Instance_Token && coordinator_id == "" {
		coordinator_id = auth.agent_instance_id
	}
	chain := domain.Task_Chain{
		chain_id = domain.Task_Chain_ID(platform.generate_id(service.ids, "chain_")),
		owner_user_id = owner,
		title = input.title,
		description = input.description,
		publish_state = .Draft,
		status = .Active,
		kind = kind,
		// coordinator_agent_instance_id is a DERIVED MIRROR (H9): it is stamped from
		// the canonical members table below, never set as an independent authority.
		coordinator_agent_instance_id = "",
		defaults_json = "{}",
		created_at = now,
		updated_at = now,
	}
	saved_chain, save_ok, save_err := iface.taskchain_save_chain(service.repo, chain)
	if !save_ok do return domain.Task_Chain{}, false, save_err

	// Write the coordinator to the SINGLE canonical source (members table), then
	// stamp the derived mirror column. An instance creator defaults to coordinator;
	// a user-token creator may name one via coordinator_agent_id.
	if coordinator_id != "" && !strings.has_prefix(coordinator_id, "agt_") {
		member := domain.Task_Chain_Member{
			chain_id = saved_chain.chain_id,
			agent_instance_id = coordinator_id,
			owner_user_id = owner,
			role = "coordinator",
			created_at = now,
		}
		iface.taskchain_save_member(service.repo, member)
		saved_chain = coordinator_sync_mirror(service, saved_chain)
	}

	return saved_chain, true, domain.Domain_Error{}
}

update_chain :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, input: Update_Chain_Input) -> (domain.Task_Chain, bool, domain.Domain_Error) {
 v := verb_begin(service)
 out, ok, err := update_chain_impl(service, auth, chain_id, input)
 if cerr := verb_end(&v, ok); cerr.code != .None do return {}, false, cerr
 return out, ok, err
}

update_chain_impl :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, input: Update_Chain_Input) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return domain.Task_Chain{}, false, err
	if auth.kind == .Instance_Token && !is_chain_coordinator(service, chain, auth.agent_instance_id) {
		return domain.Task_Chain{}, false, domain.domain_error(.Forbidden, "only chain coordinator can perform this action")
	}
	if input.status != "" && chain_status_from_string(input.status) == .Completed do return {}, false, domain.domain_error(.Validation_Failed, "use complete with expected_work_revision and final summary")
	if input.title != "" do chain.title = input.title
	if input.title_source == "agent" || input.title_source == "user" || input.title_source == "default" do chain.title_source = input.title_source
	// has_description allows explicit clearing (pass ""); a bare non-empty
	// description also still sets it for existing callers that don't set the flag.
	if input.has_description || input.description != "" do chain.description = input.description
	if input.has_coordinator {
		// Setting/changing the coordinator goes through the SINGLE canonical source
		// (members table) via set_chain_coordinator; the column is only the derived
		// mirror. A non-empty target must belong to this chain (same-owner+membership).
		if input.coordinator_agent_instance_id != "" {
			if same, same_err := agent_instance_same_chain(service, input.coordinator_agent_instance_id, chain); !same do return domain.Task_Chain{}, false, same_err
		}
		chain = set_chain_coordinator(service, chain, input.coordinator_agent_instance_id)
		// MEM-6 #9: notify the newly-designated coordinator.
		if input.coordinator_agent_instance_id != "" do notify_coordinator_assigned(service, auth, chain, input.coordinator_agent_instance_id)
	}
	status_closed := false
	closed_status: domain.Task_Chain_Status
	if input.status != "" {
		st := chain_status_from_string(input.status)
        if st == .Cancelled && service.engine != nil {
         if err := taskv2.work_require_chain_merges_settled(service.engine, chain); err.code != .None do return {}, false, err
        }
		if st != chain.status {
			if !valid_chain_transition(chain.status, st) do return domain.Task_Chain{}, false, domain.domain_error(.Conflict, "invalid chain status transition")
			chain.status = st
			if st == .Completed || st == .Cancelled {
				chain.completed_at = platform.clock_now(service.clock)
			} else if st == .Active {
				// Reopening clears the terminal completion timestamp.
				chain.completed_at = ""
			}
			if st == .Completed || st == .Cancelled || st == .Archived {
				status_closed = true
				closed_status = st
			}
		}
	}
	if input.has_is_pinned {
		if input.is_pinned && !chain.is_pinned {
			pinned_count, count_err := iface.taskchain_count_pinned_chains(service.repo, chain.owner_user_id)
			if count_err.code == .None && pinned_count >= domain.TASK_CHAINS_MAX_PINNED {
				return domain.Task_Chain{}, false, domain.domain_error(.Validation_Failed, "maximum of 10 pinned task chains allowed; unpin an existing chain first")
			}
			chain.is_pinned = true
			chain.pinned_at = platform.clock_now(service.clock)
		} else if !input.is_pinned && chain.is_pinned {
			chain.is_pinned = false
			chain.pinned_at = ""
		}
	}
	chain.updated_at = platform.clock_now(service.clock)
	saved, save_ok, save_err := iface.taskchain_save_chain(service.repo, chain)
	if save_ok && status_closed {
		// REQ-SHELL-9 trigger A. Before the broadcast rather than after, so the servers
		// are already dying by the time members are told the chain closed.
		reap_chain_servers_on_close(service, saved, closed_status)
		// Task System v2: a closed chain reclaims every lease (stop[] the holders,
		// coordinator exempt); a CANCELLED chain also cancels its open tasks.
		engine_chain_closed(service, auth, saved, closed_status)
		broadcast_chain_closed(service, auth, saved, closed_status)
	}
	return saved, save_ok, save_err
}

pin_chain :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, pinned: bool) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	chain, ok, err := get_chain_for_read(service, auth, chain_id)
	if !ok do return domain.Task_Chain{}, false, err
	if owner_ok, owner_err := ownership.require_owner(auth, chain.owner_user_id); !owner_ok do return domain.Task_Chain{}, false, owner_err
	if pinned {
		if chain.is_pinned do return chain, true, domain.Domain_Error{}
		count, count_err := iface.taskchain_count_pinned_chains(service.repo, chain.owner_user_id)
		if count_err.code == .None && count >= domain.TASK_CHAINS_MAX_PINNED {
			return domain.Task_Chain{}, false, domain.domain_error(.Validation_Failed, "maximum of 10 pinned task chains allowed; unpin an existing chain first")
		}
		chain.is_pinned = true
		chain.pinned_at = platform.clock_now(service.clock)
	} else {
		if !chain.is_pinned do return chain, true, domain.Domain_Error{}
		chain.is_pinned = false
		chain.pinned_at = ""
	}
	chain.updated_at = platform.clock_now(service.clock)
	return iface.taskchain_save_chain(service.repo, chain)
}

list_pinned_chains :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context) -> ([]domain.Task_Chain, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err
	return iface.taskchain_list_pinned_chains(service.repo, owner)
}

// set_own_chain_title lets an authenticated agent instance rename the chain it
// belongs to (T3/REQ-3), stamping title_source="agent" so the activity-gated
// nudge engine (T2) stops nudging. The instance must be the chain coordinator
// (enforced by update_chain for instance tokens); for a private-conversation
// chain the instance is its own coordinator.
set_own_chain_title :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id, title: string) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	if auth.kind != .Instance_Token || auth.agent_instance_id == "" do return domain.Task_Chain{}, false, domain.domain_error(.Forbidden, "instance token is required")
	next := strings.trim_space(title)
	if next == "" do return domain.Task_Chain{}, false, domain.domain_error(.Validation_Failed, "chain title is required")
	if err := domain.validate_capped_text("chain title", next, domain.CHAIN_TITLE_MAX_BYTES); err.code != .None do return domain.Task_Chain{}, false, err
	return update_chain(service, auth, domain.Task_Chain_ID(chain_id), Update_Chain_Input{title = next, title_source = "agent"})
}

// set_own_chain_description lets an authenticated agent instance set/clear the
// description of the chain it coordinates. Coordinator/membership auth is
// enforced by update_chain for instance tokens. Pass "" to clear.
set_own_chain_description :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id, description: string) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	if auth.kind != .Instance_Token || auth.agent_instance_id == "" do return domain.Task_Chain{}, false, domain.domain_error(.Forbidden, "instance token is required")
	next := strings.trim_space(description)
	if err := domain.validate_capped_text("chain description", next, domain.CHAIN_DESCRIPTION_MAX_BYTES); err.code != .None do return domain.Task_Chain{}, false, err
	return update_chain(service, auth, domain.Task_Chain_ID(chain_id), Update_Chain_Input{description = next, has_description = true})
}

publish_chain_impl :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return domain.Task_Chain{}, false, err
	if auth.kind == .Instance_Token && !is_chain_coordinator(service, chain, auth.agent_instance_id) {
		return domain.Task_Chain{}, false, domain.domain_error(.Forbidden, "only chain coordinator can perform this action")
	}
	if chain.publish_state != .Draft do return domain.Task_Chain{}, false, domain.domain_error(.Conflict, "chain is already published")
	// Atomic: every task's brief must be publishable, or nothing is published.
	if drafts, derr := iface.taskchain_list_tasks_by_chain(service.repo, chain_id, chain.owner_user_id); derr.code == .None {
		problems := make(map[string][]string, context.temp_allocator)
		for t in drafts {
			if missing := brief_publish_problems(service, chain, t); len(missing) > 0 do problems[string(t.task_id)] = missing
		}
		if len(problems) > 0 do return domain.Task_Chain{}, false, publish_problems_error(problems)
	}
	now := platform.clock_now(service.clock)
	chain.publish_state = .Published
	chain.status = .Active
	chain.published_at = now
	chain.updated_at = now
	saved_chain, save_ok, save_err := iface.taskchain_save_chain(service.repo, chain)
	if !save_ok do return domain.Task_Chain{}, false, save_err

	tasks, err_t := iface.taskchain_list_tasks_by_chain(service.repo, chain_id, chain.owner_user_id)
	if err_t.code == .None {
		for t in tasks {
			t_copy := t
			t_copy.publish_state = .Published
			if t_copy.published_at == "" do t_copy.published_at = now
			t_copy.updated_at = now
			_, _, _ = save_task(service, t_copy)
		}
	}
	// Publishing IS the kickoff: the engine records `published` for every task,
	// refolds the chain (entry tasks become ready) and runs the matcher.
	if service.engine != nil {
		if eng_err := taskv2.chain_published(service.engine, saved_chain, engine_actor(auth)); eng_err.code != .None do return domain.Task_Chain{}, false, eng_err
	}
	return saved_chain, true, domain.Domain_Error{}
}

change_chain_status_impl :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, next: domain.Task_Chain_Status) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	if next == .Completed do return {}, false, domain.domain_error(.Validation_Failed, "use complete with expected_work_revision and final summary")
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return domain.Task_Chain{}, false, err
	if auth.kind == .Instance_Token && !is_chain_coordinator(service, chain, auth.agent_instance_id) {
		return domain.Task_Chain{}, false, domain.domain_error(.Forbidden, "only chain coordinator can perform this action")
	}
	if chain.publish_state != .Published do return domain.Task_Chain{}, false, domain.domain_error(.Conflict, "draft chain has no execution status")
 if next == .Cancelled && service.engine != nil {
  if err := taskv2.work_require_chain_merges_settled(service.engine, chain); err.code != .None do return {}, false, err
 }
	if !valid_chain_transition(chain.status, next) do return domain.Task_Chain{}, false, domain.domain_error(.Conflict, "invalid chain status transition")
	now := platform.clock_now(service.clock)
	chain.status = next
	chain.updated_at = now
	if next == .Completed || next == .Cancelled {
		chain.completed_at = now
	} else if next == .Active {
		chain.completed_at = ""
	}
	saved, save_ok, save_err := iface.taskchain_save_chain(service.repo, chain)
	// MEM-6 (#10): on chain close, broadcast a wake to all live members so any
	// long-running loops/tasks halt.
	if save_ok && (next == .Completed || next == .Cancelled || next == .Archived) {
		// REQ-SHELL-9 trigger A — see reap_chain_servers_on_close for why all three
		// close paths call it and why that is safe.
		reap_chain_servers_on_close(service, saved, next)
		engine_chain_closed(service, auth, saved, next)
		broadcast_chain_closed(service, auth, saved, next)
	}
	if save_ok && next == .Active && service.engine != nil {
		// Reopening a chain re-evaluates it (nothing restarts by itself; the
		// matcher grants whatever is ready).
		_ = taskv2.fleet_changed(service.engine, saved)
	}
	return saved, save_ok, save_err
}

// engine_chain_closed forwards a chain close to the engine: leases reclaimed,
// holders stopped, open tasks cancelled on a cancel. Best-effort (the chain row
// is already saved); the engine logs its own failures.
engine_chain_closed :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain: domain.Task_Chain, next: domain.Task_Chain_Status) {
	if service.engine == nil do return
	_ = taskv2.chain_closed(service.engine, chain, engine_actor(auth), next == .Cancelled)
}

// broadcast_chain_closed wakes every live member of a just-closed chain with a
// human-readable [Chain Closed] notice so their loops/tasks stop. Fire-and-forget;
// the actor (closer) is not woken. MEM-6 spec §4 #10.
broadcast_chain_closed :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain: domain.Task_Chain, next: domain.Task_Chain_Status) {
	if service.bridge_command_sink.send_runtime_command == nil || service.agents == nil do return
	actor := auth.agent_instance_id if auth.kind == .Instance_Token else ""
	members, merr := iface.taskchain_list_members_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if merr.code != .None do return

	verb := "completed" if next == .Completed else ("cancelled" if next == .Cancelled else "archived")
	actor_display := resolve_actor_display(service, actor)
	defer delete(actor_display)
	title := strings.trim_space(chain.title)
	if title == "" do title = string(chain.chain_id)
	title_disp := truncate_runes(title, NOTICE_TITLE_MAX_RUNES)
	defer delete(title_disp)
	human_message := strings.concatenate({`[Chain Closed] Task chain "`, title_disp, `" (`, string(chain.chain_id), ") was marked ", verb, " by ", actor_display, ". All task activities halted."})
	defer delete(human_message)

	seen := make(map[string]bool)
	defer delete(seen)
	for m in members {
		id := m.agent_instance_id
		if id == "" || id == actor || seen[id] do continue
		seen[id] = true
		inst, inst_ok, _ := iface.agent_get_instance(service.agents, id)
		if !inst_ok || inst.bridge_id == "" do continue
		cmd_id := platform.generate_id(service.ids, "cmd_")
		b := strings.builder_make()
		strings.write_string(&b, `{"type":"notify_task_nudge","origin":"chain_closed","command_id":"`)
		contracts.write_json_string(&b, cmd_id)
		strings.write_string(&b, `","agent_instance_id":"`)
		contracts.write_json_string(&b, id)
		strings.write_string(&b, `","task_id":"","chain_id":"`)
		contracts.write_json_string(&b, string(chain.chain_id))
		strings.write_string(&b, `","target_instance_id":"`)
		contracts.write_json_string(&b, id)
		strings.write_string(&b, `","target_role":"member","action":"chain_closed","message":"`)
		contracts.write_json_string(&b, human_message)
		strings.write_string(&b, `","human_message":"`)
		contracts.write_json_string(&b, human_message)
		strings.write_string(&b, `","created_at":"`)
		contracts.write_json_string(&b, chain.updated_at)
		strings.write_string(&b, `"}`)
		_, _ = project.bridge_command_send_runtime(service.bridge_command_sink, project.Runtime_Command{bridge_id = inst.bridge_id, command_id = cmd_id, body_json = strings.to_string(b)})
		strings.builder_destroy(&b)
	}
}

valid_chain_transition :: proc(current, next: domain.Task_Chain_Status) -> bool {
	if current == next do return true
	switch current {
	case .Active: return next == .Completed || next == .Cancelled || next == .Archived
	// Recovery path: a completed chain can be reopened to Active by its
	// coordinator so an accidental completion is not permanently terminal.
	// Cancelled remains terminal, except it can be archived.
	case .Completed: return next == .Active || next == .Archived
	case .Cancelled: return next == .Archived
	case .Archived: return next == .Active
	}
	return false
}

// validate_task_bridge (REQ-TB-1): a non-empty per-task bridge pin must reference
// an existing bridge owned by the chain owner; empty is always valid (inherit,
// resolved at promotion time). Unknown and foreign bridges both surface as
// Not_Found so another owner's bridge existence is never leaked (same idiom as
// agent_service.validate_support_input).
validate_task_bridge :: proc(service: ^Taskchain_Service, owner: domain.User_ID, bridge_id: string) -> domain.Domain_Error {
	if bridge_id == "" do return domain.Domain_Error{}
	if service.agent_service == nil || service.agent_service.bridges == nil do return domain.domain_error(.Internal_Error, "bridge store unavailable; cannot validate task bridge_id")
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.agent_service.bridges, bridge_id)
	if !bridge_ok do return bridge_err
	if bridge.owner_user_id != owner do return domain.domain_error(.Not_Found, "bridge not found")
	return domain.Domain_Error{}
}

// sync_chain_status_from_tasks (REQ-CHAIN-AUTO-STATUS-1):
// Synchronizes the parent task chain's status based on the lifecycle of its tasks:
// - Transitions a Completed chain to Active when a task is created or moved to non-terminal status.
// - Transitions an Active chain to Completed when all tasks reach completed or cancelled (with >=1 completed).
sync_chain_status_from_tasks :: proc(service: ^Taskchain_Service, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	if service == nil do return domain.Task_Chain{}, false, domain.domain_error(.Internal_Error, "taskchain service is nil")
	chain, chain_ok, chain_err := iface.taskchain_get_chain(service.repo, chain_id)
	if !chain_ok do return domain.Task_Chain{}, false, chain_err

	// Completion is explicit; an idle batch never closes the work container.
	if owner != "" && chain.owner_user_id != owner do return {}, false, domain.domain_error(.Not_Found, "chain not found")
	return chain, true, domain.Domain_Error{}
}

// --- Tasks ---------------------------------------------------------------------

// build_brief_json merges the convenience fields of a create/update into a
// brief object. An explicit brief_json wins; otherwise goal defaults to the
// description (or the title) and acceptance stays empty until the publish
// validator requires it. The removed verify keys are never carried over.
build_brief_json :: proc(existing_brief, title, description, assignee_agent_id: string, has_assignee: bool, review_roles: []string, has_review_roles: bool, reviewers: []string = nil, has_reviewers := false) -> string {
	goal := jsonx.extract_string(existing_brief, "goal", "", true)
	if goal == "" do goal = strings.trim_space(description)
	if goal == "" do goal = strings.trim_space(title)
	assignee := jsonx.extract_string(existing_brief, "assignee", "", true)
	if has_assignee do assignee = strings.trim_space(assignee_agent_id)
	roles := jsonx.extract_string_array(existing_brief, "review_roles", true)
	if has_review_roles {
		clear(&roles)
		for r in review_roles do if strings.trim_space(r) != "" do append(&roles, strings.trim_space(r))
	}
	acceptance, acc_ok := jsonx.extract_raw_array(existing_brief, "acceptance", true)
	if !acc_ok do acceptance = "[]"
	inputs, in_ok := jsonx.extract_raw_array(existing_brief, "inputs", true)
	if !in_ok do inputs = "[]"
	budget, b_ok := jsonx.extract_raw_object(existing_brief, "budget", true)

	o := taskv2.json_begin()
	taskv2.json_str(&o, "goal", goal)
	taskv2.json_raw(&o, "acceptance", acceptance)
	taskv2.json_raw(&o, "inputs", inputs)
	rb := strings.builder_make()
	defer strings.builder_destroy(&rb)
	strings.write_byte(&rb, '[')
	for r, i in roles {
		if i > 0 do strings.write_byte(&rb, ',')
		strings.write_byte(&rb, '"')
		contracts.write_json_string(&rb, r)
		strings.write_byte(&rb, '"')
	}
	strings.write_byte(&rb, ']')
	taskv2.json_raw(&o, "review_roles", strings.to_string(rb))
	if assignee != "" do taskv2.json_str(&o, "assignee", assignee)
	// Named reviewers (hybrid review model): the agents that must approve THIS task.
	named := taskv2.brief_named_reviewers(existing_brief, context.temp_allocator)
	if has_reviewers {
		clear(&named)
		for r in reviewers do if id := strings.trim_space(r); id != "" do append(&named, id)
	}
	if len(named) > 0 {
		nb := strings.builder_make(context.temp_allocator)
		strings.write_byte(&nb, '[')
		for r, i in named {
			if i > 0 do strings.write_byte(&nb, ',')
			strings.write_byte(&nb, '"'); contracts.write_json_string(&nb, r); strings.write_byte(&nb, '"')
		}
		strings.write_byte(&nb, ']')
		taskv2.json_raw(&o, "reviewers", strings.to_string(nb))
	}
	if b_ok do taskv2.json_raw(&o, "budget", budget)
	if output, ook := jsonx.extract_raw_object(existing_brief, "output", true); ook {
		taskv2.json_raw(&o, "output", output)
	} else if output_str := jsonx.extract_string(existing_brief, "output", "", true); output_str != "" {
		taskv2.json_str(&o, "output", output_str)
	}
	if on_output, onok := jsonx.extract_raw_object(existing_brief, "on_output", true); onok do taskv2.json_raw(&o, "on_output", on_output)
	return taskv2.json_end(&o)
}

// ---- brief validation at publish (plan §2.4, REQ-TV2-2) ---------------------------

is_brief_armored :: proc(s: string) -> bool {
	t := strings.trim_space(s)
	return domain.is_vault_armored(t)
}

// brief_publish_problems lists what a task's brief is missing for publish. It
// is taskv2.brief_publish_missing — the single publish validator (goal, ≥1
// acceptance item, a fleet row per review role) — applied to a stored task.
brief_publish_problems :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, task: domain.Task) -> []string {
	return taskv2.brief_publish_missing(service.repo, chain, task.kind, task.brief_json)
}

@(private = "file")
publish_problems_error :: proc(problems: map[string][]string) -> domain.Domain_Error {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"code":"brief_incomplete","tasks":[`)
	first := true
	for task_id, missing in problems {
		if !first do strings.write_byte(&b, ',')
		first = false
		strings.write_string(&b, `{"task_id":"`); contracts.write_json_string(&b, task_id); strings.write_string(&b, `","missing":[`)
		for m, i in missing {
			if i > 0 do strings.write_byte(&b, ',')
			strings.write_byte(&b, '"'); contracts.write_json_string(&b, m); strings.write_byte(&b, '"')
		}
		strings.write_string(&b, "]}")
	}
	strings.write_string(&b, "]}")
	return domain.domain_error(.Validation_Failed, "brief incomplete: every published task needs a goal (≤2k), ≥1 acceptance item (≤20×200) and a fleet row per review role", strings.to_string(b))
}

// ensure_fleet_role guarantees a fleet row for `agent_id` in the chain carrying
// `role` (adding the role to an existing row when missing). Rows are the
// placement policy the matcher grants from, so a template named on a task must
// exist there (REQ-FLEET-DISPATCHER-1).
ensure_fleet_role :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, agent_id, role: string) -> domain.Domain_Error {
	id := strings.trim_space(agent_id)
	if id == "" do return domain.Domain_Error{}
	if service.agents != nil {
		if _, ok, _ := iface.agent_get(service.agents, id); !ok do return domain.domain_error(.Not_Found, strings.concatenate({"agent template not found: ", id}))
	}
	now := platform.clock_now(service.clock)
	fleets, err := iface.taskchain_list_fleets_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if err.code != .None do return err
	for f in fleets {
		if f.agent_id != id do continue
		if fleet_has_role(f, role) do return domain.Domain_Error{}
		updated := f
		updated.roles_json = fleet_roles_with(f.roles_json, role)
		updated.updated_at = now
		_, uerr := iface.taskchain_upsert_fleet(service.repo, updated)
		return uerr
	}
	roles := fleet_roles_with(`[]`, role)
	fleet := domain.Task_Chain_Fleet{task_chain_id = chain.chain_id, agent_id = id, capacity = 1, min_warm = 0, idle_ttl_seconds = 600, roles_json = roles, created_at = now, updated_at = now}
	return iface.taskchain_ensure_fleet(service.repo, fleet)
}

// ensure_fleet_row_for_named_reviewer gives a named reviewer a fleet row so the
// matcher can place and launch it. An existing row (any roles) is enough; a new
// one carries only FLEET_ROLE_NAMED_REVIEWER, which no task lists in
// review_roles, so the agent is not pulled into other tasks' role reviews.
ensure_fleet_row_for_named_reviewer :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, agent_id: string) -> domain.Domain_Error {
	id := strings.trim_space(agent_id)
	if id == "" do return domain.Domain_Error{}
	fleets, err := iface.taskchain_list_fleets_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if err.code != .None do return err
	for f in fleets do if f.agent_id == id do return domain.Domain_Error{}
	return ensure_fleet_role(service, chain, id, taskv2.FLEET_ROLE_NAMED_REVIEWER)
}

fleet_has_role :: proc(f: domain.Task_Chain_Fleet, role: string) -> bool {
	roles := jsonx.decode_string_array(f.roles_json if f.roles_json != "" else domain.FLEET_ROLES_DEFAULT_JSON, context.temp_allocator)
	for r in roles do if r == role do return true
	return false
}

fleet_roles_with :: proc(roles_json, role: string) -> string {
	roles := jsonx.decode_string_array(roles_json if roles_json != "" else domain.FLEET_ROLES_DEFAULT_JSON, context.temp_allocator)
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for r, i in roles {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_byte(&b, '"'); contracts.write_json_string(&b, r); strings.write_byte(&b, '"')
	}
	if len(roles) > 0 do strings.write_byte(&b, ',')
	strings.write_byte(&b, '"'); contracts.write_json_string(&b, role); strings.write_byte(&b, '"')
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

require_manual_task :: proc(task: domain.Task) -> domain.Domain_Error {
	if task.workflow_run_id != "" do return domain.domain_error(.Forbidden, "workflow task is engine-managed; use the run controls", `{"code":"workflow_task_managed"}`)
	return domain.Domain_Error{}
}

create_task_impl :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, input: Create_Task_Input) -> (domain.Task, bool, domain.Domain_Error) {
	// WRITE. REQ-SEC-3 (close the create_task hole): fetch owner-scoped, then
	// enforce membership EXPLICITLY here. Cross-owner is rejected as Not_Found by
	// get_chain_for_read (require_owner); a same-owner non-member is Forbidden.
	chain, ok, err := get_chain_for_read(service, auth, input.chain_id)
	if !ok do return domain.Task{}, false, err
	if chain.status != .Active do return {}, false, domain.domain_error(.Conflict, "chain must be active")
	// Task System v2: only the chain COORDINATOR (or the owner) shapes the
	// ticket board; workers work their lease. (Ticket chains only — M3b.)
	if auth.kind == .Instance_Token && !is_chain_coordinator(service, chain, auth.agent_instance_id) {
		return domain.Task{}, false, domain.domain_error(.Forbidden, "only the chain coordinator or the owner can create tasks")
	}
	requested_owner := domain.User_ID(input.owner_user_id)
	if requested_owner == "" do requested_owner = chain.owner_user_id
	if same_ok, same_err := ownership.require_same_owner(chain.owner_user_id, requested_owner); !same_ok do return domain.Task{}, false, same_err
	if input.title == "" do return domain.Task{}, false, domain.domain_error(.Validation_Failed, "task title is required")
	if br_err := validate_task_bridge(service, chain.owner_user_id, input.bridge_id); br_err.code != .None do return domain.Task{}, false, br_err

	review_roles := make([dynamic]string, context.temp_allocator)
	for r in input.review_roles do append(&review_roles, r)
	// Reviewer agent ids are NAMED reviewers of this task (hybrid review model):
	// they join the brief's own named reviewers and do not add a chain-wide role.
	named := taskv2.brief_named_reviewers(input.brief_json, context.temp_allocator)
	for rid in input.reviewer_agent_ids {
		id := strings.trim_space(rid)
		dup := id == ""
		for n in named do if n == id { dup = true; break }
		if !dup do append(&named, id)
	}
	has_named := len(input.reviewer_agent_ids) > 0
	// M2: legacy verify keys are accepted and dropped (the handler warns).
	brief, _ := taskv2.strip_removed_verify_keys(input.brief_json)
	if strings.trim_space(brief) == "" || strings.trim_space(brief) == "{}" {
		brief = build_brief_json("{}", input.title, input.description, input.assignee_agent_id, input.assignee_agent_id != "", review_roles[:], true, named[:], has_named)
	} else if input.assignee_agent_id != "" || len(review_roles) > 0 || has_named {
		brief = build_brief_json(brief, input.title, input.description, input.assignee_agent_id, input.assignee_agent_id != "", review_roles[:], len(review_roles) > 0, named[:], has_named)
	}
	// Fleet rows for every template the task names: worker for the assignee, a
	// quiet named-reviewer row (placement only) for each named reviewer.
	if a := taskv2.brief_assignee(brief); a != "" {
		if ferr := ensure_fleet_role(service, chain, a, domain.FLEET_ROLE_WORKER); ferr.code != .None do return domain.Task{}, false, ferr
	}
	for rid in taskv2.brief_named_reviewers(brief, context.temp_allocator) {
		if ferr := ensure_fleet_row_for_named_reviewer(service, chain, rid); ferr.code != .None do return domain.Task{}, false, ferr
	}

	now := platform.clock_now(service.clock)
	task := domain.Task{
		task_id = domain.Task_ID(platform.generate_id(service.ids, "task_")),
		chain_id = chain.chain_id,
		owner_user_id = chain.owner_user_id,
		title = input.title,
		description = input.description,
		publish_state = chain.publish_state,
		state = .Backlog,
		kind = input.kind,
		priority = input.has_priority ? input.priority : .P2,
		brief_json = brief,
		// Solo chains default to "the user reviews" (REQ-SOLO-1a); an explicit
		// value from the caller always wins.
		requires_user_approval = input.requires_user_approval if input.has_requires_user_approval else (service.engine != nil && taskv2.chain_is_solo(service.engine, chain)),
		bridge_id = input.bridge_id,
		created_at = now,
		updated_at = now,
	}
	if task.publish_state == .Published {
		// A task created on a LIVE chain is published at once, so its brief
		// must be publishable now (the same rule publish applies to drafts).
		if missing := brief_publish_problems(service, chain, task); len(missing) > 0 {
			problems := make(map[string][]string, context.temp_allocator)
			problems["(new task)"] = missing
			return domain.Task{}, false, publish_problems_error(problems)
		}
		task.published_at = now
	}
	saved_task, save_ok, save_err := save_task(service, task)
	if !save_ok do return domain.Task{}, false, save_err

	for dep_id in input.depends_on {
		if _, dep_ok, dep_err := add_task_dependency_row(service, auth, saved_task.task_id, dep_id); !dep_ok {
			return domain.Task{}, false, dep_err
		}
	}

	if updated_chain, sync_ok, _ := sync_chain_status_from_tasks(service, chain.chain_id, chain.owner_user_id); sync_ok {
		chain = updated_chain
	}

	// Engine: `created` (+ `published` on a live chain) → refold → match_chain.
	if service.engine != nil {
		if eng_err := taskv2.task_created(service.engine, saved_task, engine_actor(auth)); eng_err.code != .None do return domain.Task{}, false, eng_err
		if fresh, fresh_ok, _ := iface.taskchain_get_task(service.repo, saved_task.task_id); fresh_ok do saved_task = fresh
	}
	return saved_task, true, domain.Domain_Error{}
}

// task_has_work_lease reports whether the engine holds a live work lease on the
// task (scope/placement edits are rejected while it does).
task_has_work_lease :: proc(service: ^Taskchain_Service, task_id: domain.Task_ID) -> bool {
	leases, err := iface.taskchain_list_leases_by_task(service.repo, task_id)
	if err.code != .None do return false
	for l in leases do if l.kind == domain.LEASE_KIND_WORK do return true
	return false
}

// An acceptance-only brief is a patch, not a replacement: it must not erase the
// goal, assignee or review policy. Keep this allowlist narrow while a holder is
// working from its context pack.
acceptance_brief_patch :: proc(existing, incoming: string) -> (string, bool, domain.Domain_Error) {
	parsed, err := json.parse_string(incoming, allocator = context.temp_allocator)
	if err != nil do return "", false, domain.domain_error(.Validation_Failed, "brief must be a JSON object")
	patch, ok := parsed.(json.Object)
	if !ok do return "", false, domain.domain_error(.Validation_Failed, "brief must be a JSON object")
	if len(patch) == 0 do return "", false, domain.Domain_Error{}
	for key in patch do if key != "acceptance" do return "", false, domain.Domain_Error{}
	items, valid := patch["acceptance"].(json.Array)
	if !valid do return "", false, domain.domain_error(.Validation_Failed, "brief.acceptance must be an array of strings")
	for item in items do if _, valid := item.(json.String); !valid do return "", false, domain.domain_error(.Validation_Failed, "brief.acceptance must be an array of strings")
	base, berr := json.parse_string(existing if strings.trim_space(existing) != "" else "{}", allocator = context.temp_allocator)
	if berr != nil do return "", false, domain.domain_error(.Internal_Error, "stored brief is not valid JSON")
	root, root_ok := base.(json.Object)
	if !root_ok do return "", false, domain.domain_error(.Internal_Error, "stored brief is not an object")
	for key, value in patch do root[key] = value
	encoded, merr := json.marshal(root, allocator = context.temp_allocator)
	if merr != nil do return "", false, domain.domain_error(.Internal_Error, "could not encode brief")
	return string(encoded), true, domain.Domain_Error{}
}

update_task_impl :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID, input: Update_Task_Input) -> (domain.Task, bool, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return domain.Task{}, false, err
	if err := require_manual_task(task); err.code != .None do return {}, false, err
	chain, chain_ok, chain_err := iface.taskchain_get_chain(service.repo, task.chain_id)
	if !chain_ok do return domain.Task{}, false, chain_err

	if auth.kind == .Instance_Token {
		if !is_chain_coordinator(service, chain, auth.agent_instance_id) {
			return domain.Task{}, false, domain.domain_error(.Forbidden, "only the chain coordinator or the owner can update a task")
		}
	}

	changed := make([dynamic]string, context.temp_allocator)
	// M2: legacy verify keys are accepted and dropped (the handler warns). A
	// brief that carried nothing else (`task update --verify …` from an old
	// ham-ctl) is no brief edit at all — never a replacement with "{}".
	incoming_brief, dropped := taskv2.strip_removed_verify_keys(input.brief_json)
	if len(dropped) > 0 && strings.trim_space(incoming_brief) == "{}" do incoming_brief = ""
	patched_brief := ""
	acceptance_patch := false
	if incoming_brief != "" {
		patch_err: domain.Domain_Error
		patched_brief, acceptance_patch, patch_err = acceptance_brief_patch(task.brief_json, incoming_brief)
		if patch_err.code != .None do return {}, false, patch_err
	}
	brief_edit := (incoming_brief != "" && !acceptance_patch) || input.has_assignee || input.has_review_roles || input.has_reviewers || len(input.reviewer_agent_ids) > 0 || input.bridge_id != nil || input.title != "" || input.description != ""
	if brief_edit && task_has_work_lease(service, task.task_id) {
		return domain.Task{}, false, domain.domain_error(.Conflict, "task is leased: only acceptance brief patches, priority and dependencies can be edited; cancel the lease or wait before editing scope or placement")
	}

	if input.title != "" { task.title = input.title; append(&changed, "title") }
	if input.description != "" { task.description = input.description; append(&changed, "description") }
	if incoming_brief != "" {
		task.brief_json = patched_brief if acceptance_patch else incoming_brief
		append(&changed, "brief.acceptance" if acceptance_patch else "brief")
	}
	review_roles := make([dynamic]string, context.temp_allocator)
	for r in input.review_roles do append(&review_roles, r)
	has_roles := input.has_review_roles
	// `reviewers` REPLACES the task's named reviewers (an empty list clears them).
	has_named := input.has_reviewers || len(input.reviewer_agent_ids) > 0
	if input.has_assignee || has_roles || has_named || input.title != "" || input.description != "" {
		task.brief_json = build_brief_json(task.brief_json, task.title, task.description, input.assignee_agent_id, input.has_assignee, review_roles[:], has_roles, input.reviewer_agent_ids, has_named)
		if input.has_assignee do append(&changed, "assignee")
		if has_roles do append(&changed, "review_roles")
		if has_named do append(&changed, "reviewers")
	}
	if input.has_requires_user_approval {
		task.requires_user_approval = input.requires_user_approval
		append(&changed, "requires_user_approval")
	}
	if input.has_priority { task.priority = input.priority; append(&changed, "priority") }
	// bridge_id is presence-checked via the pointer: nil leaves the pin untouched,
	// a non-nil pointer (including "") repins — "" clears back to inherit.
	if input.bridge_id != nil {
		if br_err := validate_task_bridge(service, chain.owner_user_id, input.bridge_id^); br_err.code != .None do return domain.Task{}, false, br_err
		task.bridge_id = input.bridge_id^
		append(&changed, "bridge_id")
	}
	if a := taskv2.brief_assignee(task.brief_json); a != "" {
		if ferr := ensure_fleet_role(service, chain, a, domain.FLEET_ROLE_WORKER); ferr.code != .None do return domain.Task{}, false, ferr
	}
	for rid in taskv2.brief_named_reviewers(task.brief_json, context.temp_allocator) {
		if ferr := ensure_fleet_row_for_named_reviewer(service, chain, rid); ferr.code != .None do return domain.Task{}, false, ferr
	}
	task.updated_at = platform.clock_now(service.clock)
	saved, save_ok, save_err := save_task(service, task)
	if !save_ok do return domain.Task{}, false, save_err

	if input.has_depends_on {
		// clear existing deps and add new ones
		existing_deps, _ := list_chain_dependencies(service, auth, chain.chain_id)
		for ed in existing_deps {
			if ed.task_id == task.task_id {
				if _, rem_err := remove_task_dependency_impl(service, auth, task.task_id, ed.depends_on_task_id, reconcile = false); rem_err.code != .None {
					return domain.Task{}, false, rem_err
				}
			}
		}
		for dep_id in input.depends_on {
			if _, dep_ok, dep_err := add_task_dependency_row(service, auth, task.task_id, dep_id); !dep_ok {
				return domain.Task{}, false, dep_err
			}
		}
		append(&changed, "depends_on")
	}

	if service.engine != nil && len(changed) > 0 {
		if eng_err := taskv2.task_updated(service.engine, saved, engine_actor(auth), changed[:]); eng_err.code != .None do return domain.Task{}, false, eng_err
		if fresh, fresh_ok, _ := iface.taskchain_get_task(service.repo, saved.task_id); fresh_ok do saved = fresh
	}
	return saved, true, domain.Domain_Error{}
}

publish_task_impl :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return domain.Task{}, false, err
	if err := require_manual_task(task); err.code != .None do return {}, false, err
	chain, chain_ok, chain_err := iface.taskchain_get_chain(service.repo, task.chain_id)
	if !chain_ok do return domain.Task{}, false, chain_err
	if chain.publish_state != .Published do return domain.Task{}, false, domain.domain_error(.Conflict, "cannot publish task before chain is published")
	if task.publish_state != .Draft do return domain.Task{}, false, domain.domain_error(.Conflict, "task is already published")
	if auth.kind == .Instance_Token {
		if !is_chain_coordinator(service, chain, auth.agent_instance_id) {
			return domain.Task{}, false, domain.domain_error(.Forbidden, "only the chain coordinator or the owner can publish a task")
		}
	}
	if missing := brief_publish_problems(service, chain, task); len(missing) > 0 {
		problems := make(map[string][]string, context.temp_allocator)
		problems[string(task.task_id)] = missing
		return domain.Task{}, false, publish_problems_error(problems)
	}
	now := platform.clock_now(service.clock)
	task.publish_state = .Published
	task.published_at = now
	task.updated_at = now
	saved, save_ok, save_err := save_task(service, task)
	if !save_ok do return domain.Task{}, false, save_err
	// Publishing a task on a live chain is an engine event: it becomes ready as
	// soon as its dependencies allow and the matcher runs.
	if service.engine != nil {
		if eng_err := taskv2.task_published(service.engine, saved, engine_actor(auth)); eng_err.code != .None do return domain.Task{}, false, eng_err
		if fresh, fresh_ok, _ := iface.taskchain_get_task(service.repo, saved.task_id); fresh_ok do saved = fresh
	}
	return saved, true, domain.Domain_Error{}
}

create_comment :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, input: Comment_Input) -> (domain.Task_Comment, bool, domain.Domain_Error) {
	if strings.trim_space(input.body) == "" do return domain.Task_Comment{}, false, domain.domain_error(.Validation_Failed, "comment body is required")
	task, ok, err := get_task(service, auth, input.task_id)
	if !ok do return domain.Task_Comment{}, false, err
	chain, chain_ok, chain_err := get_chain(service, auth, task.chain_id)
	if !chain_ok do return domain.Task_Comment{}, false, chain_err
	if auth.kind == .Instance_Token {
		if auth.agent_instance_id == "" do return domain.Task_Comment{}, false, domain.domain_error(.Forbidden, "instance token is required")
		if same, same_err := agent_instance_same_chain(service, auth.agent_instance_id, chain); !same do return domain.Task_Comment{}, false, same_err
	}
	now := platform.clock_now(service.clock)
	comment := domain.Task_Comment{comment_id = platform.generate_id(service.ids, "cmt_"), task_id = task.task_id, chain_id = task.chain_id, owner_user_id = task.owner_user_id, author_agent_instance_id = auth.agent_instance_id, body = input.body, created_at = now, updated_at = now}
	return save_comment(service, comment)
}

list_comments :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID) -> ([]domain.Task_Comment, domain.Domain_Error) {
	// READ: owner-scoped (REQ-SEC-3).
	task, ok, err := get_task_for_read(service, auth, task_id)
	if !ok do return nil, err
	return iface.taskchain_list_comments_by_task(service.repo, task.task_id, task.owner_user_id)
}

// task_display_name returns the task's human title, falling back to its id when
// the title is empty, so notification messages are always readable.
task_display_name :: proc(task: domain.Task) -> string {
	t := strings.trim_space(task.title)
	if t != "" do return t
	return string(task.task_id)
}

comment_preview_safe :: proc(body: string) -> string {
	trimmed := strings.trim_space(body)
	if domain.contains_vault_token(trimmed) {
		return strings.clone(trimmed)
	}
	b := strings.builder_make()
	count := 0
	truncated := false
	for r in body {
		if count >= 30 {
			truncated = true
			break
		}
		strings.write_rune(&b, r)
		count += 1
	}
	if truncated {
		strings.write_string(&b, "...")
	}
	return strings.to_string(b)
}

// --- MEM-6: human-readable notification messages ---------------------------
// Every task/chain wake carries a `human_message` built here so the bridge can
// deliver a context-rich line instead of the legacy generic string. Format:
//   [<TAG>] @<Actor> <verb> "<title>" (<task-id>)[: "<excerpt>"]

// NOTICE_TITLE_MAX_RUNES caps a task/chain title rendered in a notice. User
// directive (2026-09-09): 20, matching the excerpt cap (spec §2 said 60).
NOTICE_TITLE_MAX_RUNES :: 20

// NOTICE_EXCERPT_MAX_RUNES caps inline free-text excerpts (comment bodies, review
// feedback, custom nudge messages). User directive (2026-09-09): 20, not the
// spec's 140.
NOTICE_EXCERPT_MAX_RUNES :: 20

// truncate_runes clamps s to max runes, appending an ellipsis when it had to cut.
// If s is an encrypted vault token (carries the "vault:v2:" marker), rune truncation
// is bypassed so complete ciphertext is preserved for downstream client decryption.
// Caller owns the returned string.
truncate_runes :: proc(s: string, max: int) -> string {
	trimmed := strings.trim_space(s)
	if domain.contains_vault_token(trimmed) {
		return strings.clone(trimmed)
	}
	b := strings.builder_make()
	count := 0
	truncated := false
	for r in trimmed {
		if count >= max { truncated = true; break }
		strings.write_rune(&b, r)
		count += 1
	}
	if truncated do strings.write_string(&b, "…")
	return strings.to_string(b)
}

// resolve_actor_display renders "@<display-name>" for an actor agent instance,
// falling back to "@<trimmed-id>" when the instance can't be resolved, and to
// "@User" for an empty actor (user-authored / system-with-user origin).
resolve_actor_display :: proc(service: ^Taskchain_Service, actor_instance_id: string) -> string {
	id := strings.trim_space(actor_instance_id)
	if id == "" do return strings.clone("@User")
	if service != nil && service.agents != nil {
		if inst, ok, _ := iface.agent_get_instance(service.agents, id); ok {
			dn := strings.trim_space(inst.display_name)
			if dn != "" do return strings.concatenate({"@", dn})
		}
	}
	return strings.concatenate({"@", id})
}

// notice_task_title returns the task title clamped to NOTICE_TITLE_MAX_RUNES
// (falling back to the task id when blank). Caller owns the returned string.
notice_task_title :: proc(task: domain.Task) -> string {
	return truncate_runes(task_display_name(task), NOTICE_TITLE_MAX_RUNES)
}

// send_chain_level_wake emits a chain-level notify_task_nudge (task_id empty) with
// a prebuilt human_message to one instance. Used for coordinator-assigned and
// member-removed notices (spec §4 #9/#11). MEM-6.
send_chain_level_wake :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, target_instance_id, origin, human_message: string) -> bool {
	if service.bridge_command_sink.send_runtime_command == nil || service.agents == nil do return false
	tid := strings.trim_space(target_instance_id)
	if tid == "" do return false
	inst, inst_ok, _ := iface.agent_get_instance(service.agents, tid)
	if !inst_ok || inst.bridge_id == "" do return false
	now := platform.clock_now(service.clock)
	cmd_id := platform.generate_id(service.ids, "cmd_")
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"type":"notify_task_nudge","origin":"`)
	contracts.write_json_string(&b, origin)
	strings.write_string(&b, `","command_id":"`)
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, `","agent_instance_id":"`)
	contracts.write_json_string(&b, tid)
	strings.write_string(&b, `","task_id":"","chain_id":"`)
	contracts.write_json_string(&b, string(chain.chain_id))
	strings.write_string(&b, `","target_instance_id":"`)
	contracts.write_json_string(&b, tid)
	strings.write_string(&b, `","target_role":"`)
	contracts.write_json_string(&b, origin)
	strings.write_string(&b, `","action":"`)
	contracts.write_json_string(&b, origin)
	strings.write_string(&b, `","message":"`)
	contracts.write_json_string(&b, human_message)
	strings.write_string(&b, `","human_message":"`)
	contracts.write_json_string(&b, human_message)
	strings.write_string(&b, `","created_at":"`)
	contracts.write_json_string(&b, now)
	strings.write_string(&b, `"}`)
	sent, _ := project.bridge_command_send_runtime(service.bridge_command_sink, project.Runtime_Command{bridge_id = inst.bridge_id, command_id = cmd_id, body_json = strings.to_string(b)})
	return sent
}

// comment_task records a comment. Task System v2: a comment is an audit event
// with no protocol meaning — nobody is woken by it (the pack carries the refs
// an agent may fetch). The returned `notified` list is always empty.
comment_task :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, input: Task_Comment_Input) -> (domain.Task_Comment, []string, bool, domain.Domain_Error) {
	if strings.trim_space(input.body) == "" do return domain.Task_Comment{}, nil, false, domain.domain_error(.Validation_Failed, "comment body is required")
	task, ok, err := get_task(service, auth, input.task_id)
	if !ok do return domain.Task_Comment{}, nil, false, err
	if task.publish_state != .Published do return domain.Task_Comment{}, nil, false, domain.domain_error(.Conflict, "draft task cannot be commented on")
	if auth.kind == .Instance_Token && auth.agent_instance_id == "" do return domain.Task_Comment{}, nil, false, domain.domain_error(.Forbidden, "instance token is required")
	now := platform.clock_now(service.clock)
	comment := domain.Task_Comment{comment_id = platform.generate_id(service.ids, "cmt_"), task_id = task.task_id, chain_id = task.chain_id, owner_user_id = task.owner_user_id, author_agent_instance_id = auth.agent_instance_id, body = input.body, created_at = now, updated_at = now}
	saved, ok2, err2 := save_comment(service, comment)
	if !ok2 do return saved, nil, ok2, err2
	if service.engine != nil do _ = taskv2.task_comment(service.engine, task, engine_actor(auth), saved.comment_id)
	return saved, nil, true, domain.Domain_Error{}
}

list_task_comments :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID) -> ([]domain.Task_Comment, domain.Domain_Error) {
	// READ: owner-scoped (REQ-SEC-3).
	task, ok, err := get_task_for_read(service, auth, task_id)
	if !ok do return nil, err
	return iface.taskchain_list_comments_by_task(service.repo, task.task_id, task.owner_user_id)
}

// task_comment_summary returns the compact comment rollup (count + last comment
// metadata + preview) for embedding on task objects. Owner-scoped via get_task.
task_comment_summary :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID) -> (domain.Task_Comment_Summary, domain.Domain_Error) {
	// READ: owner-scoped (REQ-SEC-3).
	task, ok, err := get_task_for_read(service, auth, task_id)
	if !ok do return domain.Task_Comment_Summary{}, err
	return iface.taskchain_comment_summary_by_task(service.repo, task.task_id, task.owner_user_id)
}

// list_recent_task_comments returns the newest `last` comments (ascending), or
// all when last <= 0. Owner-scoped via get_task.
list_recent_task_comments :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID, last: int) -> ([]domain.Task_Comment, domain.Domain_Error) {
	// READ: owner-scoped (REQ-SEC-3).
	task, ok, err := get_task_for_read(service, auth, task_id)
	if !ok do return nil, err
	return iface.taskchain_list_recent_comments_by_task(service.repo, task.task_id, task.owner_user_id, last)
}

// coordinator_chain_of_instance returns the chain_id this instance already
// coordinates (the first one found), or "" if none. Used to enforce invariant 2
// (a coordinator instance coordinates at most one chain).
coordinator_chain_of_instance :: proc(service: ^Taskchain_Service, owner: domain.User_ID, agent_instance_id: string) -> string {
	if service == nil || service.repo == nil || agent_instance_id == "" do return ""
	chains, err := iface.taskchain_list_chains_by_coordinator(service.repo, agent_instance_id, owner)
	if err.code != .None do return ""
	defer delete(chains)
	if len(chains) == 0 do return ""
	return string(chains[0].chain_id)
}

// --- Member Management ---

add_chain_member :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, agent_instance_id: string, role: string) -> (domain.Task_Chain_Member, bool, domain.Domain_Error) {
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return domain.Task_Chain_Member{}, false, err
	if auth.kind == .Instance_Token && !is_chain_coordinator(service, chain, auth.agent_instance_id) {
		return domain.Task_Chain_Member{}, false, domain.domain_error(.Forbidden, "only chain coordinator can add members")
	}
	if agent_instance_id == "" do return domain.Task_Chain_Member{}, false, domain.domain_error(.Validation_Failed, "agent_instance_id is required")
	if strings.has_prefix(agent_instance_id, "agt_") do return domain.Task_Chain_Member{}, false, domain.domain_error(.Validation_Failed, "agent_instance_id must be an instance ID, not an agent ID")

	agent_id := ""
	if service.agents != nil {
		inst, inst_ok, _ := iface.agent_get_instance(service.agents, agent_instance_id)
		if inst_ok {
			if inst.owner_user_id != chain.owner_user_id do return domain.Task_Chain_Member{}, false, domain.domain_error(.Conflict, "agent instance owner mismatch")
			// Invariant 1 (Option A): an instance belongs to exactly ONE chain for
			// its lifetime. Reject adding an instance whose own chain_id names a
			// different chain. (An unbound instance with empty chain_id is allowed;
			// membership in this chain is its binding.)
			if inst.chain_id != "" && inst.chain_id != string(chain.chain_id) {
				return domain.Task_Chain_Member{}, false, domain.domain_error(.Conflict, "an agent instance belongs to a single task chain; launch a new instance to join another chain")
			}
			agent_id = inst.agent_id
		}
	}

	member_role := role
	if member_role == "" do member_role = "worker"

	// Invariant 2 (Option A): a coordinator instance coordinates AT MOST ONE chain.
	// Reject making this instance a coordinator when it already coordinates another.
	if member_role == "coordinator" {
		if existing := coordinator_chain_of_instance(service, chain.owner_user_id, agent_instance_id); existing != "" && existing != string(chain.chain_id) {
			return domain.Task_Chain_Member{}, false, domain.domain_error(.Conflict, "an agent instance can coordinate only one task chain")
		}
	}
	now := platform.clock_now(service.clock)

	member := domain.Task_Chain_Member{
		chain_id = chain.chain_id,
		agent_instance_id = agent_instance_id,
		agent_id = agent_id,
		owner_user_id = chain.owner_user_id,
		role = member_role,
		created_at = now,
	}

	saved_member, saved_ok, save_err := iface.taskchain_save_member(service.repo, member)
	// If a coordinator member was added/updated, keep the derived mirror column in
	// sync with the canonical members table (H9).
	if saved_ok && member_role == "coordinator" do _ = coordinator_sync_mirror(service, chain)
	return saved_member, saved_ok, save_err
}

remove_chain_member :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, agent_instance_id: string) -> (bool, domain.Domain_Error) {
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return false, err
	if auth.kind == .Instance_Token && !is_chain_coordinator(service, chain, auth.agent_instance_id) {
		return false, domain.domain_error(.Forbidden, "only chain coordinator can remove members")
	}

	members, list_err := iface.taskchain_list_members_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if list_err.code != .None do return false, list_err

	// Disallow removing sole coordinator
	is_target_coordinator := false
	coordinator_count := 0
	for m in members {
		if m.role == "coordinator" {
			coordinator_count += 1
			if m.agent_instance_id == agent_instance_id do is_target_coordinator = true
		}
	}

	if is_target_coordinator && coordinator_count <= 1 {
		return false, domain.domain_error(.Conflict, "cannot remove sole coordinator from task chain")
	}

	removed, remove_err := iface.taskchain_remove_member(service.repo, chain.chain_id, agent_instance_id, chain.owner_user_id)
	// If a coordinator member was removed, resync the derived mirror column from
	// the canonical members table (H9).
	if removed && is_target_coordinator do _ = coordinator_sync_mirror(service, chain)

	// Task System v2: a removed member that still HOLDS a lease is treated like a
	// lost instance — the engine expires the lease and re-plans the chain.
	if removed && service.engine != nil do taskv2.on_instance_terminal(service.engine, agent_instance_id)
	return removed, remove_err
}

list_chain_members :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID) -> ([]domain.Task_Chain_Member, domain.Domain_Error) {
	// READ: owner-scoped (REQ-SEC-3).
	chain, ok, err := get_chain_for_read(service, auth, chain_id)
	if !ok do return nil, err
	members, list_err := iface.taskchain_list_members_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if list_err.code != .None do return nil, list_err
	valid_members := make([dynamic]domain.Task_Chain_Member, context.allocator)
	for m in members {
		if !strings.has_prefix(m.agent_instance_id, "agt_") {
			append(&valid_members, m)
		}
	}
	return valid_members[:], domain.Domain_Error{}
}

// --- Task Dependencies ---

// --- Task Dependencies ---

// add_task_dependency_row validates and writes the edge (no engine call). Used by
// create_task, whose engine notification covers the whole new task.
add_task_dependency_row :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id, depends_on_task_id: domain.Task_ID) -> (domain.Task_Dependency, bool, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return {}, false, err
	if service.engine == nil do return {}, false, domain.domain_error(.Internal_Error, "task engine unavailable")
	edge, saved, serr := taskv2.work_dependency_add(service.engine, task.owner_user_id, engine_actor(auth), task.chain_id,
		domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK,id = string(task_id)}, domain.Work_Item_Ref{kind = domain.WORK_ITEM_TASK,id = string(depends_on_task_id)}, reconcile = false)
	return domain.Task_Dependency{task_id = task_id, depends_on_task_id = depends_on_task_id, chain_id = task.chain_id, owner_user_id = task.owner_user_id, created_at = edge.created_at}, saved, serr
}

add_task_dependency_impl :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id, depends_on_task_id: domain.Task_ID) -> (domain.Task_Dependency, bool, domain.Domain_Error) {
    edge, ok, err := add_task_dependency_row(service, auth, task_id, depends_on_task_id)
    if !ok do return {}, false, err
    task, _, _ := get_task(service, auth, task_id)
    if err := taskv2.dep_added(service.engine, task, depends_on_task_id, engine_actor(auth)); err.code != .None do return {}, false, err
    return edge, true, domain.Domain_Error{}
}

remove_task_dependency_impl :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id, depends_on_task_id: domain.Task_ID, reconcile := true) -> (bool, domain.Domain_Error) {
	task, ok, err := get_task(service,auth,task_id)
	if !ok do return false, err
	if err := require_manual_task(task); err.code != .None do return false, err
	edges, eerr := iface.taskchain_list_work_dependencies(service.repo,task.chain_id,task.owner_user_id)
	if eerr.code != .None do return false,eerr
	for edge in edges {
		if edge.removed_at == "" && edge.dependent.kind == domain.WORK_ITEM_TASK && edge.dependent.id == string(task_id) && edge.prerequisite.kind == domain.WORK_ITEM_TASK && edge.prerequisite.id == string(depends_on_task_id) {
			return taskv2.work_dependency_remove(service.engine,task.owner_user_id,engine_actor(auth),task.chain_id,edge.dependency_id,"ticket dependency removed", reconcile = reconcile)
		}
	}
	return false,domain.domain_error(.Not_Found,"dependency not found")
}

list_chain_dependencies :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID) -> ([]domain.Task_Dependency, domain.Domain_Error) {
	chain,ok,err := get_chain_for_read(service,auth,chain_id)
	if !ok do return nil,err
	out, ierr := iface.taskchain_list_dependencies_by_chain(service.repo,chain.chain_id,chain.owner_user_id)
	if ierr.code != .None do return nil,ierr
	edges,eerr := iface.taskchain_list_work_dependencies(service.repo,chain.chain_id,chain.owner_user_id)
	if eerr.code != .None do return nil,eerr
	result := make([dynamic]domain.Task_Dependency,context.allocator)
	append(&result,..out)
	for edge in edges {
		if edge.removed_at == "" && edge.dependent.kind == domain.WORK_ITEM_TASK && edge.prerequisite.kind == domain.WORK_ITEM_TASK {
			append(&result,domain.Task_Dependency{task_id=domain.Task_ID(edge.dependent.id),depends_on_task_id=domain.Task_ID(edge.prerequisite.id),chain_id=chain.chain_id,owner_user_id=chain.owner_user_id,created_at=edge.created_at})
		}
	}
	return result[:],domain.Domain_Error{}
}

has_dependency_cycle :: proc(service: ^Taskchain_Service, chain_id: domain.Task_Chain_ID, owner: domain.User_ID, target_task_id, current_dep_id: domain.Task_ID) -> bool {
	if target_task_id == current_dep_id do return true
	deps, err := iface.taskchain_list_dependencies_by_chain(service.repo, chain_id, owner)
	if err.code != .None do return false
	for d in deps {
		if d.task_id == current_dep_id {
			if has_dependency_cycle(service, chain_id, owner, target_task_id, d.depends_on_task_id) do return true
		}
	}
	return false
}

// --- Reviewer Voting & Quorum ---

get_task :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	task, ok, err := iface.taskchain_get_task(service.repo, task_id)
	if !ok do return domain.Task{}, false, err
	if owner_ok, owner_err := ownership.require_owner(auth, task.owner_user_id); !owner_ok do return domain.Task{}, false, owner_err
	if auth.kind == .Instance_Token {
		chain, chain_ok, chain_err := iface.taskchain_get_chain(service.repo, task.chain_id)
		if !chain_ok do return domain.Task{}, false, chain_err
		if !is_instance_member_or_coordinator(service, chain, auth.agent_instance_id) {
			return domain.Task{}, false, domain.domain_error(.Forbidden, "agent instance is not a member or coordinator of this task's chain")
		}
	}
	return task, true, domain.Domain_Error{}
}

// get_task_for_read (REQ-SEC-3): the READ-ONLY task authorizer. Enforces ONLY
// ownership (require_owner) — an Instance_Token may read ANY task of its own
// owner regardless of chain membership. It drops the membership check that
// get_task applies. Owner isolation is preserved (cross-owner still 404s).
// WRITES must NOT use this — they call the membership-gated get_task.
get_task_for_read :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	task, ok, err := iface.taskchain_get_task(service.repo, task_id)
	if !ok do return domain.Task{}, false, err
	if owner_ok, owner_err := ownership.require_owner(auth, task.owner_user_id); !owner_ok do return domain.Task{}, false, owner_err
	return task, true, domain.Domain_Error{}
}

update_chain_coordinator :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, coordinator_agent_instance_id: string) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return domain.Task_Chain{}, false, err
	if auth.kind == .Instance_Token && !is_chain_coordinator(service, chain, auth.agent_instance_id) {
		return domain.Task_Chain{}, false, domain.domain_error(.Forbidden, "only chain coordinator can change the coordinator")
	}
	if coordinator_agent_instance_id != "" {
		if same, same_err := agent_instance_same_chain(service, coordinator_agent_instance_id, chain); !same do return domain.Task_Chain{}, false, same_err
	}
	// Change the coordinator through the SINGLE canonical source (members table);
	// set_chain_coordinator demotes the old coordinator, promotes the target, and
	// stamps the derived mirror column.
	chain = set_chain_coordinator(service, chain, coordinator_agent_instance_id)
	chain.updated_at = platform.clock_now(service.clock)
	saved, save_ok, save_err := iface.taskchain_save_chain(service.repo, chain)
	// MEM-6 #9: tell the new coordinator they now hold the role.
	if save_ok && coordinator_agent_instance_id != "" {
		notify_coordinator_assigned(service, auth, saved, coordinator_agent_instance_id)
	}
	return saved, save_ok, save_err
}

// notify_coordinator_assigned wakes the newly-designated coordinator with a
// human-readable [Coordinator Assigned] chain-level notice. MEM-6 spec §4 #9.
notify_coordinator_assigned :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain: domain.Task_Chain, new_coordinator: string) {
	if service.bridge_command_sink.send_runtime_command == nil || service.agents == nil do return
	actor := auth.agent_instance_id if auth.kind == .Instance_Token else ""
	if strings.trim_space(new_coordinator) == "" || new_coordinator == actor do return
	title := strings.trim_space(chain.title)
	if title == "" do title = string(chain.chain_id)
	title_disp := truncate_runes(title, NOTICE_TITLE_MAX_RUNES)
	defer delete(title_disp)
	human_message := strings.concatenate({`[Coordinator Assigned] You are now designated Coordinator for task chain "`, title_disp, `" (`, string(chain.chain_id), ")."})
	defer delete(human_message)
	_ = send_chain_level_wake(service, chain, new_coordinator, "coordinator_assigned", human_message)
}

agent_instance_same_chain :: proc(service: ^Taskchain_Service, instance_id: string, chain: domain.Task_Chain) -> (bool, domain.Domain_Error) {
	if service.agents == nil do return false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	inst, ok, err := iface.agent_get_instance(service.agents, instance_id)
	if !ok do return false, err
	if inst.owner_user_id != chain.owner_user_id do return false, domain.domain_error(.Conflict, "agent instance ref must belong to the same chain owner")
	if inst.chain_id == string(chain.chain_id) || instance_id == chain.coordinator_agent_instance_id || is_instance_member_or_coordinator(service, chain, instance_id) {
		return true, domain.Domain_Error{}
	}
	return false, domain.domain_error(.Conflict, "agent instance ref must belong to the same chain")
}

// ensure_chain_member adds instance_id to the chain members with a worker role if not
// already present. Best-effort: failures are non-fatal because the ref will still be
// validated by agent_instance_same_chain (owner + chain checks).
//
// An EXISTING member is left untouched. taskchain_save_member is an upsert that does
// `SET role=excluded.role`, so writing the worker row unconditionally would rewrite the
// role of a member that already has one. That mattered most for the coordinator: since
// is_chain_coordinator (H9) reads this table as the single canonical authority, promoting
// the coordinator instance onto a planning or micro-task demoted its member row to
// "worker" and locked the real coordinator out of every coordinator-gated action
// (reconcile, update_chain/set-title/set-description/set-status, publish). Preserving ANY
// existing role — not just "coordinator" — is the invariant, so a reviewer member is not
// silently rewritten either.
ensure_chain_member :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, instance_id, agent_id: string) {
	if members, err := iface.taskchain_list_members_by_chain(service.repo, chain.chain_id, chain.owner_user_id); err.code == .None {
		defer delete(members)
		for m in members {
			if m.agent_instance_id == instance_id do return
		}
	}
	now := platform.clock_now(service.clock)
	member := domain.Task_Chain_Member{
		chain_id = chain.chain_id,
		agent_instance_id = instance_id,
		agent_id = agent_id,
		owner_user_id = chain.owner_user_id,
		role = "worker",
		created_at = now,
	}
	_, _, _ = iface.taskchain_save_member(service.repo, member)
}

chain_status_from_string :: proc(status: string) -> domain.Task_Chain_Status {
	if status == "completed" do return .Completed
	if status == "cancelled" do return .Cancelled
	if status == "archived" do return .Archived
	return .Active
}

// --- Directory Management (REQ-BE-TASK-CHAIN-RELEVANT-DIRECTORIES) ---

Add_Directory_Input :: struct {
	chain_id:      domain.Task_Chain_ID,
	path:          string,
	bridge_id:     string,
	vcs_kind:      string,
	vcs_info_json: string,
}

Update_Directory_Input :: struct {
	directory_id:  string,
	chain_id:      domain.Task_Chain_ID,
	path:          string,
	bridge_id:     string,
	vcs_kind:      string,
	vcs_info_json: string,
	has_path:      bool,
	has_bridge_id: bool,
	has_vcs_kind:  bool,
	has_vcs_info:  bool,
}

list_chain_directories :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID) -> ([]domain.Task_Chain_Directory, domain.Domain_Error) {
	chain, ok, err := get_chain_for_read(service, auth, chain_id)
	if !ok do return nil, err
	return iface.taskchain_list_directories_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
}

get_chain_directory :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, directory_id: string) -> (domain.Task_Chain_Directory, bool, domain.Domain_Error) {
	if directory_id == "" do return domain.Task_Chain_Directory{}, false, domain.domain_error(.Validation_Failed, "directory_id is required")
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return domain.Task_Chain_Directory{}, false, err
	return iface.taskchain_get_directory(service.repo, directory_id, chain.chain_id, chain.owner_user_id)
}

add_chain_directory :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, input: Add_Directory_Input) -> (domain.Task_Chain_Directory, bool, domain.Domain_Error) {
	trimmed_path := strings.trim_space(input.path)
	if trimmed_path == "" do return domain.Task_Chain_Directory{}, false, domain.domain_error(.Validation_Failed, "directory path is required")
	chain, ok, err := get_chain(service, auth, input.chain_id)
	if !ok do return domain.Task_Chain_Directory{}, false, err

	now := platform.clock_now(service.clock)
	dir_id := platform.generate_id(service.ids, "dir_")
	vcs_json := input.vcs_info_json
	if vcs_json == "" || !strings.starts_with(vcs_json, "{") {
		vcs_json = "{}"
	}

	dir := domain.Task_Chain_Directory{
		directory_id  = dir_id,
		chain_id      = chain.chain_id,
		owner_user_id = chain.owner_user_id,
		path          = trimmed_path,
		bridge_id     = strings.trim_space(input.bridge_id),
		vcs_kind      = strings.trim_space(input.vcs_kind),
		vcs_info_json = vcs_json,
		created_at    = now,
		updated_at    = now,
	}

	saved, save_ok, save_err := iface.taskchain_save_directory(service.repo, dir)
	if !save_ok do return domain.Task_Chain_Directory{}, false, save_err
	return saved, true, domain.Domain_Error{}
}

update_chain_directory :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, input: Update_Directory_Input) -> (domain.Task_Chain_Directory, bool, domain.Domain_Error) {
	if input.directory_id == "" do return domain.Task_Chain_Directory{}, false, domain.domain_error(.Validation_Failed, "directory_id is required")
	chain, ok, err := get_chain(service, auth, input.chain_id)
	if !ok do return domain.Task_Chain_Directory{}, false, err

	existing, get_ok, get_err := iface.taskchain_get_directory(service.repo, input.directory_id, chain.chain_id, chain.owner_user_id)
	if !get_ok do return domain.Task_Chain_Directory{}, false, get_err

	if input.has_path {
		trimmed_path := strings.trim_space(input.path)
		if trimmed_path == "" do return domain.Task_Chain_Directory{}, false, domain.domain_error(.Validation_Failed, "directory path cannot be empty")
		existing.path = trimmed_path
	}
	if input.has_bridge_id do existing.bridge_id = strings.trim_space(input.bridge_id)
	if input.has_vcs_kind do existing.vcs_kind = strings.trim_space(input.vcs_kind)
	if input.has_vcs_info {
		vcs_json := input.vcs_info_json
		if vcs_json == "" || !strings.starts_with(vcs_json, "{") {
			vcs_json = "{}"
		}
		existing.vcs_info_json = vcs_json
	}
	existing.updated_at = platform.clock_now(service.clock)

	saved, save_ok, save_err := iface.taskchain_save_directory(service.repo, existing)
	if !save_ok do return domain.Task_Chain_Directory{}, false, save_err
	return saved, true, domain.Domain_Error{}
}

remove_chain_directory :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, directory_id: string) -> (bool, domain.Domain_Error) {
	if directory_id == "" do return false, domain.domain_error(.Validation_Failed, "directory_id is required")
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return false, err

	removed, rem_err := iface.taskchain_remove_directory(service.repo, directory_id, chain.chain_id, chain.owner_user_id)
	if rem_err.code != .None do return false, rem_err
	if !removed do return false, domain.domain_error(.Not_Found, "directory not found")
	return true, domain.Domain_Error{}
}

// --- Fleet Management (REQ-FLEET-SCHEMA-1, REQ-FLEET-API-CLI-1) ---

// --- Fleet Management (REQ-FLEET-SCHEMA-1, REQ-FLEET-API-CLI-1, Task System v2 §4a) ---

Upsert_Fleet_Input :: struct {
	bridge_models_json: string,
	chain_id:         domain.Task_Chain_ID,
	agent_id:         string,
	capacity:         int,
	min_warm:         int,
	idle_ttl_seconds: int,
	provider:         string,
	model:             string,
	// roles: fleet roles (worker|reviewer); nil keeps the existing roles (default ["worker"]).
	roles:            []string,
	has_roles:        bool,
	// bridge_id: placement; nil leaves the row's bridge untouched, "" clears it.
	bridge_id:        ^string,
}

list_fleets :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID) -> ([]domain.Task_Chain_Fleet, domain.Domain_Error) {
	chain, ok, err := get_chain_for_read(service, auth, chain_id)
	if !ok do return nil, err
	return iface.taskchain_list_fleets_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
}

list_chain_fleets :: list_fleets

// implicit_solo_worker: the Soloist coordinator's implicit worker row (no fleet
// row of its own), for read paths; false on a bare service or any other chain.
implicit_solo_worker :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, fleets: []domain.Task_Chain_Fleet) -> (domain.Task_Chain_Fleet, bool) {
	if service.engine == nil do return {}, false
	return taskv2.implicit_solo_worker(service.engine, chain, fleets)
}

upsert_fleet_impl :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, input: Upsert_Fleet_Input) -> (domain.Task_Chain_Fleet, domain.Domain_Error) {
	trimmed_agent := strings.trim_space(input.agent_id)
	if trimmed_agent == "" do return domain.Task_Chain_Fleet{}, domain.domain_error(.Validation_Failed, "agent_id is required")
	chain, ok, err := get_chain(service, auth, input.chain_id)
	if !ok do return domain.Task_Chain_Fleet{}, err

	capacity := input.capacity
	if capacity < 1 do capacity = 1
	min_warm := input.min_warm
	if min_warm < 0 do min_warm = 0
	idle_ttl := input.idle_ttl_seconds
	if idle_ttl <= 0 do idle_ttl = 600

	prior, prior_err := iface.taskchain_list_fleets_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if prior_err.code != .None do return {}, prior_err
	defer delete(prior)
	existing := domain.Task_Chain_Fleet{roles_json = domain.FLEET_ROLES_DEFAULT_JSON}
	for row in prior { if row.agent_id == trimmed_agent { existing = row; break } }
	bridge_models := input.bridge_models_json
	if bridge_models == "" {
		bridge_models = existing.bridge_models_json
	} else {
		entries: map[string]domain.Fleet_Bridge_Model
		if json.unmarshal((transmute([]u8) bridge_models), &entries, allocator = context.temp_allocator) != nil do return {}, domain.domain_error(.Validation_Failed, "invalid bridge_models")
		for bridge_id, selection in entries {
			if service.agent_service == nil do return {}, domain.domain_error(.Internal_Error, "agent service unavailable")
			bridge, found, _ := iface.bridge_get_bridge(service.agent_service.bridges, bridge_id)
			if !found || bridge.owner_user_id != chain.owner_user_id do return {}, domain.domain_error(.Not_Found, "bridge not found")
			if selection.provider == "" || selection.model == "" do return {}, domain.domain_error(.Validation_Failed, "bridge provider and model are required")
			_, valid, validation_err := agent.validate_provider_model_intersection(service.agent_service, bridge_id, selection.provider, selection.model)
			if !valid do return {}, validation_err
		}
	}
	roles_json := existing.roles_json
	if input.has_roles {
		b := strings.builder_make()
		strings.write_byte(&b, '[')
		n := 0
		seen := make(map[string]bool, context.temp_allocator)
		for r in input.roles {
			role := strings.trim_space(r)
			if !domain.fleet_role_name_valid(role) do return {}, domain.domain_error(.Validation_Failed, "fleet roles must be 'worker' or a review role name (1-32 chars of a-z, 0-9, _ or -, starting with a letter)")
			if seen[role] do continue
			seen[role] = true
			if n > 0 do strings.write_byte(&b, ',')
			strings.write_byte(&b, '"'); contracts.write_json_string(&b, role); strings.write_byte(&b, '"')
			n += 1
		}
		strings.write_byte(&b, ']')
		if n == 0 do return {}, domain.domain_error(.Validation_Failed, "fleet roles must not be empty")
		roles_json = strings.to_string(b)
	}
	if roles_json == "" do roles_json = domain.FLEET_ROLES_DEFAULT_JSON
	bridge_id := existing.bridge_id
	if input.bridge_id != nil {
		if br_err := validate_task_bridge(service, chain.owner_user_id, input.bridge_id^); br_err.code != .None do return {}, br_err
		bridge_id = input.bridge_id^
	}
	now := platform.clock_now(service.clock)
	fleet := domain.Task_Chain_Fleet{
		bridge_models_json = bridge_models,
		task_chain_id    = chain.chain_id,
		agent_id         = trimmed_agent,
		capacity         = capacity,
		min_warm         = min_warm,
		idle_ttl_seconds = idle_ttl,
		provider         = input.provider,
		model             = input.model,
		roles_json       = roles_json,
		bridge_id        = bridge_id,
		created_at       = existing.created_at if existing.created_at != "" else now,
		updated_at       = now,
	}

	saved, save_err := iface.taskchain_upsert_fleet(service.repo, fleet)
	if save_err.code != .None do return saved, save_err
	// Editing a row never touches live leases; the next grant uses the new
	// placement. The engine re-evaluates review gates and ready tasks.
	if service.engine != nil do _ = taskv2.fleet_changed(service.engine, chain, trimmed_agent)
	return saved, domain.Domain_Error{}
}

upsert_chain_fleet :: upsert_fleet

delete_fleet_impl :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, agent_id: string) -> (bool, domain.Domain_Error) {
	trimmed_agent := strings.trim_space(agent_id)
	if trimmed_agent == "" do return false, domain.domain_error(.Validation_Failed, "agent_id is required")
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return false, err

	deleted, del_err := iface.taskchain_delete_fleet(service.repo, chain.chain_id, trimmed_agent, chain.owner_user_id)
	if del_err.code != .None do return false, del_err
	if !deleted do return false, domain.domain_error(.Not_Found, "fleet not found")
	if service.engine != nil do _ = taskv2.fleet_changed(service.engine, chain, trimmed_agent)
	return true, domain.Domain_Error{}
}

delete_chain_fleet :: delete_fleet

remove_chain_fleet :: delete_fleet

// --- Fleet placement helpers (shared with the engine's JIT provisioning) ---

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
	if service == nil || service.agent_service == nil do return strings.clone(provider), strings.clone(model)
	return taskv2.resolve_launch_model(service.agent_service, bridge_id, provider, model)
}

// Effective_Placement is the bridge / provider / model the matcher would apply
// to a fleet row (Task v2 plan REQ-UI-12), with where each value came from, so
// the UI shows real values instead of "inherit" / "default". Strings are
// temp-allocated.
Effective_Placement :: struct {
	bridge_id:     string `json:"bridge_id"`,
	// task_pin | fleet | chain_directory | coordinator | none
	bridge_source: string `json:"bridge_source"`,
	provider:      string `json:"provider"`,
	model:         string `json:"model"`,
	// fleet | bridge_override | catalog_default | none
	model_source:  string `json:"model_source"`,
}

// effective_placement mirrors taskv2.resolve_placement (bridge: task pin, then
// fleet row, then the chain's first directory, then the coordinator's bridge)
// and the matcher's model resolution (the fleet row's model for that bridge,
// else the catalog default the bridge supports). `task_pin` is "" for a fleet
// row on its own.
effective_placement :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, fleet: domain.Task_Chain_Fleet, task_pin := "") -> Effective_Placement {
	out := Effective_Placement{bridge_source = "none", model_source = "none"}
	if pin := strings.trim_space(task_pin); pin != "" {
		out.bridge_id, out.bridge_source = strings.clone(pin, context.temp_allocator), "task_pin"
	} else if fb := strings.trim_space(fleet.bridge_id); fb != "" {
		out.bridge_id, out.bridge_source = strings.clone(fb, context.temp_allocator), "fleet"
	} else {
		if dirs, derr := iface.taskchain_list_directories_by_chain(service.repo, chain.chain_id, chain.owner_user_id); derr.code == .None {
			if len(dirs) > 0 && strings.trim_space(dirs[0].bridge_id) != "" {
				out.bridge_id, out.bridge_source = strings.clone(dirs[0].bridge_id, context.temp_allocator), "chain_directory"
			}
			delete(dirs)
		}
		if out.bridge_id == "" && chain.coordinator_agent_instance_id != "" && service.agents != nil {
			if inst, ok, _ := iface.agent_get_instance(service.agents, chain.coordinator_agent_instance_id); ok && inst.bridge_id != "" {
				out.bridge_id, out.bridge_source = strings.clone(inst.bridge_id, context.temp_allocator), "coordinator"
			}
		}
	}
	if out.bridge_id == "" do return out
	provider, model := fleet_model_on_bridge(fleet, out.bridge_id)
	if provider != "" && model != "" {
		out.provider, out.model = strings.clone(provider, context.temp_allocator), strings.clone(model, context.temp_allocator)
		out.model_source = "fleet" if provider == fleet.provider && model == fleet.model else "bridge_override"
		return out
	}
	rp, rm := resolve_fleet_launch_model(service, out.bridge_id, provider, model)
	defer delete(rp)
	defer delete(rm)
	if rp != "" && rm != "" {
		out.provider, out.model, out.model_source = strings.clone(rp, context.temp_allocator), strings.clone(rm, context.temp_allocator), "catalog_default"
	}
	return out
}

// cancel_task is a human/coordinator verb: the engine records `cancelled`,
// reclaims any lease (stop[] the holder) and re-plans the chain. Dependents are
// not touched (a cancelled prerequisite unblocks them — the human decided).
cancel_task_impl :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID, reason: string) -> (domain.Task, bool, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return domain.Task{}, false, err
	if err := require_manual_task(task); err.code != .None do return {}, false, err
	if auth.kind == .Instance_Token {
		chain, chain_ok, chain_err := iface.taskchain_get_chain(service.repo, task.chain_id)
		if !chain_ok do return domain.Task{}, false, chain_err
		if !is_chain_coordinator(service, chain, auth.agent_instance_id) {
			return domain.Task{}, false, domain.domain_error(.Forbidden, "only the chain coordinator or the owner can cancel a task")
		}
	}
	if domain.task_state_is_terminal(task.state) do return domain.Task{}, false, domain.domain_error(.Conflict, "task is already terminal")
	if service.engine == nil do return domain.Task{}, false, domain.domain_error(.Internal_Error, "task engine is not configured")
	if eng_err := taskv2.cancel_task(service.engine, task, engine_actor(auth), reason); eng_err.code != .None do return domain.Task{}, false, eng_err
	if fresh, fresh_ok, _ := iface.taskchain_get_task(service.repo, task.task_id); fresh_ok do task = fresh
	return task, true, domain.Domain_Error{}
}

// ---- one-UoW wrappers (review C1) --------------------------------------------------
// Each mutating verb runs entirely inside one unit of work; the *_impl bodies
// are unchanged and the engine calls inside them nest as SAVEPOINTs.

publish_chain :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	v := verb_begin(service)
	out, ok, err := publish_chain_impl(service, auth, chain_id)
	if cerr := verb_end(&v, ok); cerr.code != .None do return domain.Task_Chain{}, false, cerr
	return out, ok, err
}

change_chain_status :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, next: domain.Task_Chain_Status) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	v := verb_begin(service)
	out, ok, err := change_chain_status_impl(service, auth, chain_id, next)
	if cerr := verb_end(&v, ok); cerr.code != .None do return domain.Task_Chain{}, false, cerr
	return out, ok, err
}

create_task :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, input: Create_Task_Input) -> (domain.Task, bool, domain.Domain_Error) {
	v := verb_begin(service)
	out, ok, err := create_task_impl(service, auth, input)
	if cerr := verb_end(&v, ok); cerr.code != .None do return domain.Task{}, false, cerr
	return out, ok, err
}

update_task :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID, input: Update_Task_Input) -> (domain.Task, bool, domain.Domain_Error) {
	v := verb_begin(service)
	out, ok, err := update_task_impl(service, auth, task_id, input)
	if cerr := verb_end(&v, ok); cerr.code != .None do return domain.Task{}, false, cerr
	return out, ok, err
}

publish_task :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	v := verb_begin(service)
	out, ok, err := publish_task_impl(service, auth, task_id)
	if cerr := verb_end(&v, ok); cerr.code != .None do return domain.Task{}, false, cerr
	return out, ok, err
}

add_task_dependency :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id, depends_on_task_id: domain.Task_ID) -> (domain.Task_Dependency, bool, domain.Domain_Error) {
	v := verb_begin(service)
	out, ok, err := add_task_dependency_impl(service, auth, task_id, depends_on_task_id)
	if cerr := verb_end(&v, ok); cerr.code != .None do return domain.Task_Dependency{}, false, cerr
	return out, ok, err
}

remove_task_dependency :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id, depends_on_task_id: domain.Task_ID) -> (bool, domain.Domain_Error) {
	v := verb_begin(service)
	ok, err := remove_task_dependency_impl(service, auth, task_id, depends_on_task_id)
	if cerr := verb_end(&v, ok); cerr.code != .None do return false, cerr
	return ok, err
}

upsert_fleet :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, input: Upsert_Fleet_Input) -> (domain.Task_Chain_Fleet, domain.Domain_Error) {
	v := verb_begin(service)
	out, err := upsert_fleet_impl(service, auth, input)
	if cerr := verb_end(&v, err.code == .None); cerr.code != .None do return domain.Task_Chain_Fleet{}, cerr
	return out, err
}

delete_fleet :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, agent_id: string) -> (bool, domain.Domain_Error) {
	v := verb_begin(service)
	ok, err := delete_fleet_impl(service, auth, chain_id, agent_id)
	if cerr := verb_end(&v, ok); cerr.code != .None do return false, cerr
	return ok, err
}

cancel_task :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID, reason: string) -> (domain.Task, bool, domain.Domain_Error) {
	v := verb_begin(service)
	out, ok, err := cancel_task_impl(service, auth, task_id, reason)
	if cerr := verb_end(&v, ok); cerr.code != .None do return domain.Task{}, false, cerr
	return out, ok, err
}

// require_coordinator_for_task: instance tokens may shape the board (create /
// update / depend / publish / cancel) only as the chain coordinator.
require_coordinator_for_task :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID, what: string) -> domain.Domain_Error {
	if auth.kind != .Instance_Token do return domain.Domain_Error{}
	task, ok, err := iface.taskchain_get_task(service.repo, task_id)
	if !ok do return err
	chain, cok, cerr := iface.taskchain_get_chain(service.repo, task.chain_id)
	if !cok do return cerr
	if !is_chain_coordinator(service, chain, auth.agent_instance_id) {
		return domain.domain_error(.Forbidden, fmt.tprintf("only the chain coordinator or the owner can %s", what))
	}
	return domain.Domain_Error{}
}

complete_chain :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, revision: i64, summary: string) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	if service.engine == nil do return {},false,domain.domain_error(.Internal_Error,"task engine unavailable")
	chain,ok,err := taskv2.work_chain_complete(service.engine,domain.User_ID(auth.user_id),engine_actor(auth),chain_id,revision,summary)
	if !ok do return {},false,err
	reap_chain_servers_on_close(service,chain,.Completed)
	engine_chain_closed(service,auth,chain,.Completed)
	broadcast_chain_closed(service,auth,chain,.Completed)
	return chain,true,domain.Domain_Error{}
}
