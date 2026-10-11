package taskchain

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
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
import jsonx "odin_test:lib/jsonx"
import json "core:encoding/json"

Nudge_Target :: enum {
	None,
	Assignee,
	Reviewer,
	Coordinator,
}

Manual_Nudge :: struct {
	task_id: domain.Task_ID,
	owner_user_id: domain.User_ID,
	target: Nudge_Target,
	message: string,
	created_at: string,
	nudge_id: string,
	delivery_state: string,
	live_delivered: int,
	durable_queued: int,
	failed: int,
	targets_json: string,
}

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
	nudge_debounce_mutex: sync.Mutex,
	nudge_debounce_last_unix_ms: map[string]i64,
}

Create_Chain_Input :: struct {
	title: string,
	description: string,
	owner_user_id: string,
	kind: string,
	coordinator_agent_id: string,
	default_reviewer_refs_json: string,
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

Create_Task_Input :: struct {
	chain_id: domain.Task_Chain_ID,
	title: string,
	description: string,
	owner_user_id: string,
	assignee_ref_json: string,
	reviewer_refs_json: string,
	requires_user_approval: bool,
	has_requires_user_approval: bool,
	// priority sets the task priority (P0/P1/P2) at create time. has_priority
	// distinguishes an explicit choice from "field absent" so a create that omits
	// priority keeps the documented P2 default. Mirrors Update_Task_Input below;
	// its absence here is REQ-CLI-2: the CLIs sent priority and create dropped it.
	priority: domain.Task_Priority,
	has_priority: bool,
	depends_on: []domain.Task_ID,
	// bridge_id pins the task to a specific bridge for instantiating its
	// agent-id actors (REQ-TB-1). Empty = inherit (resolved at promotion time).
	// A non-empty value must reference a bridge owned by the chain owner.
	bridge_id: string,
}

Update_Task_Input :: struct {
	title: string,
	description: string,
	assignee_ref_json: string,
	reviewer_refs_json: string,
	requires_user_approval: bool,
	has_requires_user_approval: bool,
	// priority sets the task priority (P0/P1/P2). has_priority distinguishes an
	// explicit change from "field absent" so a PATCH that omits priority leaves it
	// untouched. A priority change re-orders the auto-promotion selection.
	priority: domain.Task_Priority,
	has_priority: bool,
	depends_on: []domain.Task_ID,
	has_depends_on: bool,
	// bridge_id repins the task's bridge (REQ-TB-1). nil = field absent: leave the
	// current pin untouched. A non-nil pointer is the new value — pointing at ""
	// clears the pin back to inherit (resolved at promotion time). A non-empty
	// value must reference a bridge owned by the chain owner.
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

Vote_Input :: struct {
	task_id: domain.Task_ID,
	vote: string, // "lgtm" or "ngtm"
	comment: string,
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
	now := platform.clock_now(service.clock)
	kind := input.kind; if kind == "" do kind = "team_work"
	default_reviewers := input.default_reviewer_refs_json; if default_reviewers == "" do default_reviewers = "[]"
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
		default_reviewer_refs_json = default_reviewers,
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
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return domain.Task_Chain{}, false, err
	if auth.kind == .Instance_Token && !is_chain_coordinator(service, chain, auth.agent_instance_id) {
		return domain.Task_Chain{}, false, domain.domain_error(.Forbidden, "only chain coordinator can perform this action")
	}
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
		broadcast_chain_closed(service, auth, saved, closed_status)
	}
	if save_ok && input.status != "" {
		fanout_chain_status_changed(service, auth, saved)
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

publish_chain :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return domain.Task_Chain{}, false, err
	if auth.kind == .Instance_Token && !is_chain_coordinator(service, chain, auth.agent_instance_id) {
		return domain.Task_Chain{}, false, domain.domain_error(.Forbidden, "only chain coordinator can perform this action")
	}
	if chain.publish_state != .Draft do return domain.Task_Chain{}, false, domain.domain_error(.Conflict, "chain is already published")
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
			_, _, _ = iface.taskchain_save_task(service.repo, t_copy)
		}
	}
	// Auto-promotion on publish: any task with satisfied deps and a free assignee
	// auto-claims into In_Progress so a manual refresh shows the work as started.
	_ = recompute_chain_promotions(service, saved_chain)
	return saved_chain, true, domain.Domain_Error{}
}

change_chain_status :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, next: domain.Task_Chain_Status) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return domain.Task_Chain{}, false, err
	if auth.kind == .Instance_Token && !is_chain_coordinator(service, chain, auth.agent_instance_id) {
		return domain.Task_Chain{}, false, domain.domain_error(.Forbidden, "only chain coordinator can perform this action")
	}
	if chain.publish_state != .Published do return domain.Task_Chain{}, false, domain.domain_error(.Conflict, "draft chain has no execution status")
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
		broadcast_chain_closed(service, auth, saved, next)
	}
	if save_ok {
		fanout_chain_status_changed(service, auth, saved)
	}
	return saved, save_ok, save_err
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

// validate_task_assignee_bridge_match (REQ-TB-HUB-1):
// Rejects task creation or update with Conflict if a concrete assignee instance
// is specified and its bridge_id does not match the task's non-empty bridge_id.
validate_task_assignee_bridge_match :: proc(service: ^Taskchain_Service, task_bridge_id: string, assignee_ref_json: string) -> (bool, domain.Domain_Error) {
	if task_bridge_id == "" || service == nil || service.agents == nil do return true, domain.Domain_Error{}
	instances := extract_instances_from_ref_blob(assignee_ref_json)
	defer delete(instances)
	for inst_id in instances {
		if inst, ok, _ := iface.agent_get_instance(service.agents, inst_id); ok {
			if inst.bridge_id != "" && inst.bridge_id != task_bridge_id {
				return false, domain.domain_error(.Conflict, "assignee instance bridge does not match task bridge")
			}
		}
	}
	return true, domain.Domain_Error{}
}

// sync_chain_status_from_tasks (REQ-CHAIN-AUTO-STATUS-1):
// Synchronizes the parent task chain's status based on the lifecycle of its tasks:
// - Transitions a Completed chain to Active when a task is created or moved to non-terminal status.
// - Transitions an Active chain to Completed when all tasks reach completed or cancelled (with >=1 completed).
sync_chain_status_from_tasks :: proc(service: ^Taskchain_Service, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	if service == nil do return domain.Task_Chain{}, false, domain.domain_error(.Internal_Error, "taskchain service is nil")
	chain, chain_ok, chain_err := iface.taskchain_get_chain(service.repo, chain_id)
	if !chain_ok do return domain.Task_Chain{}, false, chain_err

	// Draft chains have no execution status; leave untouched
	if chain.publish_state != .Published {
		return chain, true, domain.Domain_Error{}
	}

	actual_owner := owner
	if actual_owner == "" do actual_owner = chain.owner_user_id

	tasks, tasks_err := iface.taskchain_list_tasks_by_chain(service.repo, chain_id, actual_owner)
	if tasks_err.code != .None do return chain, false, tasks_err
	defer delete(tasks)

	non_terminal := 0
	completed := 0
	for t in tasks {
		if t.status != .Completed && t.status != .Cancelled {
			non_terminal += 1
		}
		if t.status == .Completed {
			completed += 1
		}
	}

	modified := false
	now := platform.clock_now(service.clock)

	if non_terminal > 0 {
		if chain.status == .Completed {
			chain.status = .Active
			chain.completed_at = ""
			modified = true
		}
	} else if non_terminal == 0 && len(tasks) > 0 && completed > 0 {
		if chain.status == .Active {
			chain.status = .Completed
			chain.completed_at = now
			modified = true
		}
	}

	if modified {
		chain.updated_at = now
		saved, save_ok, save_err := iface.taskchain_save_chain(service.repo, chain)
		if !save_ok do return chain, false, save_err
		chain = saved

		if service.event_bus != nil && chain.owner_user_id != "" {
			summary := fmt.aprintf("{{\"chain_id\":\"%s\"}}", chain.chain_id)
			defer delete(summary)
			events.publish_resource_changed(service.event_bus, string(chain.owner_user_id), "task_chain", string(chain.chain_id), "updated", summary)
		}
		// REQ-SHELL-9 trigger A, and THE ONE THAT MATTERS: this is the auto-complete,
		// reached when the last task of a chain goes terminal. It is how a chain closes
		// in the normal case, and it is the path REQ-SHELL-9's description did not name.
		// `chain.status` rather than a `next` parameter because this block also handles
		// the reopen (.Active at :679), which the reap refuses.
		reap_chain_servers_on_close(service, chain, chain.status)
		fanout_chain_status_changed(service, contracts.Auth_Context{kind = .None}, chain)
	}

	return chain, true, domain.Domain_Error{}
}

create_task :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, input: Create_Task_Input) -> (domain.Task, bool, domain.Domain_Error) {
	// WRITE. REQ-SEC-3 (close the create_task hole): fetch owner-scoped, then
	// enforce membership EXPLICITLY here. create_task previously relied entirely on
	// the shared get_chain gate; making the membership check local and independent
	// keeps task creation restricted to chain members/coordinator regardless of how
	// the read gate evolves. Cross-owner is rejected as Not_Found by get_chain_for_read
	// (require_owner); a same-owner non-member is rejected as Forbidden below.
	chain, ok, err := get_chain_for_read(service, auth, input.chain_id)
	if !ok do return domain.Task{}, false, err
	if auth.kind == .Instance_Token && !is_instance_member_or_coordinator(service, chain, auth.agent_instance_id) {
		return domain.Task{}, false, domain.domain_error(.Forbidden, "only a member or coordinator of the chain can create tasks")
	}
	requested_owner := domain.User_ID(input.owner_user_id)
	if requested_owner == "" do requested_owner = chain.owner_user_id
	if same_ok, same_err := ownership.require_same_owner(chain.owner_user_id, requested_owner); !same_ok do return domain.Task{}, false, same_err
	if input.title == "" do return domain.Task{}, false, domain.domain_error(.Validation_Failed, "task title is required")
	if br_err := validate_task_bridge(service, chain.owner_user_id, input.bridge_id); br_err.code != .None do return domain.Task{}, false, br_err
	assignee_ref := input.assignee_ref_json
	if assignee_ref == "" && chain.coordinator_agent_instance_id != "" do assignee_ref = agent_instance_ref_json(chain.coordinator_agent_instance_id)
	if assignee_ref == "" do assignee_ref = user_ref_json(string(chain.owner_user_id))
	reviewer_refs := input.reviewer_refs_json
	if reviewer_refs != "" && actor_refs_contain_user(reviewer_refs) {
		return domain.Task{}, false, domain.domain_error(.Validation_Failed, "user reviewer refs are not accepted; use requires_user_approval")
	}
	if reviewer_refs == "" do reviewer_refs = chain.default_reviewer_refs_json
	if reviewer_refs == "" do reviewer_refs = "[]"
	// Resolve any durable agent_id refs into concrete agent_instance refs (reuse or,
	// in Phase 2, launch) before validation so callers can assign/review by agent_id.
	if norm, norm_ok, norm_err := normalize_actor_refs(service, chain, assignee_ref); norm_ok { assignee_ref = norm } else { return domain.Task{}, false, norm_err }
	if norm, norm_ok, norm_err := normalize_actor_refs(service, chain, reviewer_refs); norm_ok { reviewer_refs = norm } else { return domain.Task{}, false, norm_err }
	if input.has_requires_user_approval {
		if adjusted, adjusted_ok := set_owner_user_approval(reviewer_refs, string(chain.owner_user_id), input.requires_user_approval); adjusted_ok {
			reviewer_refs = adjusted
			defer delete(adjusted)
		} else {
			return domain.Task{}, false, domain.domain_error(.Validation_Failed, "invalid reviewer ref JSON")
		}
	}
	if refs_ok, refs_err := validate_actor_refs(service, chain, assignee_ref, reviewer_refs); !refs_ok do return domain.Task{}, false, refs_err
	if bm_ok, bm_err := validate_task_assignee_bridge_match(service, input.bridge_id, assignee_ref); !bm_ok do return domain.Task{}, false, bm_err
	now := platform.clock_now(service.clock)
	task := domain.Task{
		task_id = domain.Task_ID(platform.generate_id(service.ids, "task_")),
		chain_id = chain.chain_id,
		owner_user_id = chain.owner_user_id,
		title = input.title,
		description = input.description,
		publish_state = chain.publish_state,
		status = .Assigned,
		// Tasks default to the lowest priority (P2) unless the caller explicitly
		// escalates via input.priority (REQ-CLI-2).
		priority = input.has_priority ? input.priority : .P2,
		assignee_ref_json = assignee_ref,
		reviewer_refs_json = reviewer_refs,
		bridge_id = input.bridge_id,
		created_at = now,
		updated_at = now,
	}
	saved_task, save_ok, save_err := iface.taskchain_save_task(service.repo, task)
	if !save_ok do return domain.Task{}, false, save_err

	for dep_id in input.depends_on {
		if _, dep_ok, dep_err := add_task_dependency(service, auth, saved_task.task_id, dep_id); !dep_ok {
			return domain.Task{}, false, dep_err
		}
	}
	if ensure_err := ensure_durable_actor_fleets(service, saved_task); ensure_err.code != .None do return domain.Task{}, false, ensure_err

	if updated_chain, sync_ok, _ := sync_chain_status_from_tasks(service, chain.chain_id, chain.owner_user_id); sync_ok {
		chain = updated_chain
	}

	// NO auto-reconcile on create (setup-phase rule): the coordinator stages the
	// whole plan, then triggers `reconcile` explicitly. A newly-created task does
	// not promote/nudge until the coordinator kicks off or re-plans.

	// MEM-6 #1: on an ACTIVE, published chain a new task assignment notifies the
	// assignee + coordinator (draft chains stay silent to avoid setup thrashing).
	if chain.publish_state == .Published && chain.status == .Active && saved_task.publish_state == .Published {
		actor := auth.agent_instance_id if auth.kind == .Instance_Token else ""
		prio := task_priority_label(saved_task.priority)
		assignee := primary_assignee_instance(saved_task.assignee_ref_json)
		defer delete(assignee)
		_ = send_task_wake(service, saved_task, assignee, "assigned", "Task Assigned", "assigned to you", prio, actor)
		if chain.coordinator_agent_instance_id != assignee do _ = send_task_wake(service, saved_task, chain.coordinator_agent_instance_id, "assigned", "Task Assigned", "assigned", prio, actor)
	}

	return saved_task, true, domain.Domain_Error{}
}

update_task :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID, input: Update_Task_Input) -> (domain.Task, bool, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return domain.Task{}, false, err
	chain, chain_ok, chain_err := iface.taskchain_get_chain(service.repo, task.chain_id)
	if !chain_ok do return domain.Task{}, false, chain_err

	if auth.kind == .Instance_Token {
		is_coord := is_chain_coordinator(service, chain, auth.agent_instance_id)
		is_assignee := strings.contains(task.assignee_ref_json, auth.agent_instance_id)
		if !is_coord && !is_assignee {
			return domain.Task{}, false, domain.domain_error(.Forbidden, "only assignee or coordinator can update task")
		}
	}

	// Remember the prior assignee so a reassign-away can clear that instance's
	// current_task pointer if it no longer holds the task (CT-7 consistency).
	prev_assignee := primary_assignee_instance(task.assignee_ref_json)
	defer delete(prev_assignee)
	prev_priority := task.priority // MEM-6 #2: detect a P0 escalation.
	prior_requires_user_approval := task_requires_user_approval(task)

	if input.title != "" do task.title = input.title
	if input.description != "" do task.description = input.description
	if input.assignee_ref_json != "" do task.assignee_ref_json = input.assignee_ref_json
	if input.reviewer_refs_json != "" {
		if actor_refs_contain_user(input.reviewer_refs_json) {
			return domain.Task{}, false, domain.domain_error(.Validation_Failed, "user reviewer refs are not accepted; use requires_user_approval")
		}
		task.reviewer_refs_json = input.reviewer_refs_json
		if !input.has_requires_user_approval && prior_requires_user_approval {
			if adjusted, adjusted_ok := set_owner_user_approval(task.reviewer_refs_json, string(chain.owner_user_id), true); adjusted_ok {
				task.reviewer_refs_json = adjusted
				defer delete(adjusted)
			} else {
				return domain.Task{}, false, domain.domain_error(.Validation_Failed, "invalid reviewer ref JSON")
			}
		}
	}
	if input.has_requires_user_approval {
		if adjusted, adjusted_ok := set_owner_user_approval(task.reviewer_refs_json, string(chain.owner_user_id), input.requires_user_approval); adjusted_ok {
			task.reviewer_refs_json = adjusted
			defer delete(adjusted)
		} else {
			return domain.Task{}, false, domain.domain_error(.Validation_Failed, "invalid reviewer ref JSON")
		}
	}
	if input.has_priority do task.priority = input.priority
	// bridge_id is presence-checked via the pointer: nil leaves the pin untouched,
	// a non-nil pointer (including "") repins — "" clears back to inherit.
	if input.bridge_id != nil {
		if br_err := validate_task_bridge(service, chain.owner_user_id, input.bridge_id^); br_err.code != .None do return domain.Task{}, false, br_err
		task.bridge_id = input.bridge_id^
	}

	// Resolve durable agent_id refs into concrete agent_instance refs before validation.
	if norm, norm_ok, norm_err := normalize_actor_refs(service, chain, task.assignee_ref_json); norm_ok { task.assignee_ref_json = norm } else { return domain.Task{}, false, norm_err }
	if norm, norm_ok, norm_err := normalize_actor_refs(service, chain, task.reviewer_refs_json); norm_ok { task.reviewer_refs_json = norm } else { return domain.Task{}, false, norm_err }
	if refs_ok, refs_err := validate_actor_refs(service, chain, task.assignee_ref_json, task.reviewer_refs_json); !refs_ok do return domain.Task{}, false, refs_err
	if bm_ok, bm_err := validate_task_assignee_bridge_match(service, task.bridge_id, task.assignee_ref_json); !bm_ok do return domain.Task{}, false, bm_err
	task.updated_at = platform.clock_now(service.clock)
	saved, save_ok, save_err := iface.taskchain_save_task(service.repo, task)
	if !save_ok do return domain.Task{}, false, save_err

	// Pointer healing (including clearing a reassigned-away instance's stale
	// pointer) is now handled TOTALLY by reconcile_chain — no ad-hoc clear here.
	_ = prev_assignee

	if input.has_depends_on {
		// clear existing deps and add new ones
		existing_deps, _ := iface.taskchain_list_dependencies_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
		for ed in existing_deps {
			if ed.task_id == task.task_id {
				iface.taskchain_remove_dependency(service.repo, task.task_id, ed.depends_on_task_id, chain.owner_user_id)
			}
		}
		for dep_id in input.depends_on {
			if _, dep_ok, dep_err := add_task_dependency(service, auth, task.task_id, dep_id); !dep_ok {
				return domain.Task{}, false, dep_err
			}
		}
	}
	if ensure_err := ensure_durable_actor_fleets(service, saved); ensure_err.code != .None do return domain.Task{}, false, ensure_err

	// NO auto-reconcile on update (assignee/reviewer/priority/dependency edits are
	// setup-phase changes): the coordinator triggers `reconcile` when the new plan
	// should take effect. (Task STATUS changes reconcile — that's a different proc,
	// change_task_status.)

	// MEM-6 #2: on an ACTIVE, published chain, a reassignment notifies the new
	// assignee + coordinator, and a P0 escalation notifies the assignee. Text-only
	// edits stay silent (UI-only). Draft chains stay silent.
	if chain.publish_state == .Published && chain.status == .Active && saved.publish_state == .Published {
		actor := auth.agent_instance_id if auth.kind == .Instance_Token else ""
		new_assignee := primary_assignee_instance(saved.assignee_ref_json)
		defer delete(new_assignee)
		if new_assignee != "" && new_assignee != prev_assignee {
			_ = send_task_wake(service, saved, new_assignee, "reassigned", "Task Reassigned", "reassigned to you", "", actor)
			if chain.coordinator_agent_instance_id != new_assignee do _ = send_task_wake(service, saved, chain.coordinator_agent_instance_id, "reassigned", "Task Reassigned", "reassigned", "", actor)
		}
		if input.has_priority && saved.priority == .P0 && prev_priority != .P0 {
			_ = send_task_wake(service, saved, new_assignee, "priority", "Priority P0", "escalated to P0", "", actor)
		}
	}

	return saved, true, domain.Domain_Error{}
}

publish_task :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return domain.Task{}, false, err
	chain, chain_ok, chain_err := iface.taskchain_get_chain(service.repo, task.chain_id)
	if !chain_ok do return domain.Task{}, false, chain_err
	if chain.publish_state != .Published do return domain.Task{}, false, domain.domain_error(.Conflict, "cannot publish task before chain is published")
	if task.publish_state != .Draft do return domain.Task{}, false, domain.domain_error(.Conflict, "task is already published")
	if auth.kind == .Instance_Token {
		is_coord := is_chain_coordinator(service, chain, auth.agent_instance_id)
		is_assignee := strings.contains(task.assignee_ref_json, auth.agent_instance_id)
		if !is_coord && !is_assignee {
			return domain.Task{}, false, domain.domain_error(.Forbidden, "only assignee or coordinator can publish task")
		}
	}
	now := platform.clock_now(service.clock)
	task.publish_state = .Published
	task.status = .Assigned
	task.published_at = now
	task.updated_at = now
	saved, save_ok, save_err := iface.taskchain_save_task(service.repo, task)
	if !save_ok do return domain.Task{}, false, save_err
	// NO auto-reconcile: publishing a task is a setup-phase change. The coordinator
	// triggers `reconcile` when the plan should take effect.
	return saved, true, domain.Domain_Error{}
}

change_task_status :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID, next: domain.Task_Status) -> (domain.Task, bool, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return domain.Task{}, false, err
	if task.publish_state != .Published do return domain.Task{}, false, domain.domain_error(.Conflict, "draft task has no execution status")

	target_next := next
	if next == .Paused {
		if task.status == .In_Progress || task.status == .Finishing {
			target_next = .Pausing
		}
	}

	if !valid_task_transition(task.status, target_next) do return domain.Task{}, false, domain.domain_error(.Conflict, "invalid task status transition")

	chain, chain_ok, chain_err := iface.taskchain_get_chain(service.repo, task.chain_id)
	if !chain_ok do return domain.Task{}, false, chain_err
	if auth.kind == .Instance_Token {
		is_coord := is_chain_coordinator(service, chain, auth.agent_instance_id)
		is_assignee := strings.contains(task.assignee_ref_json, auth.agent_instance_id)
		if !is_coord && !is_assignee {
			return domain.Task{}, false, domain.domain_error(.Forbidden, "only assignee or coordinator can change task status")
		}
	}

	new_assignee_ref := ""
	defer if new_assignee_ref != "" do delete(new_assignee_ref)

	new_reviewer_refs := make([dynamic]string)
	defer {
		for r in new_reviewer_refs do delete(r)
		delete(new_reviewer_refs)
	}

	// Dependency Gating: reject transition to In_Progress if any dependency is blocked
	if target_next == .In_Progress {
		deps, dep_err := iface.taskchain_list_dependencies_by_chain(service.repo, task.chain_id, task.owner_user_id)
		if dep_err.code == .None {
			defer delete(deps)
			for dep in deps {
				if dep.task_id == task.task_id {
					parent_task, p_ok, _ := iface.taskchain_get_task(service.repo, dep.depends_on_task_id)
					if p_ok {
						if !domain.task_status_unblocks_dependents(parent_task.status) {
							return domain.Task{}, false, domain.domain_error(.Conflict, "task is blocked by dependencies")
						}
					}
				}
			}
		}

		// REQ-FSM-UNIFIED-1: Atomic Start & JIT Agent Instance Binding
		inst_id := primary_assignee_instance(task.assignee_ref_json)
		defer if inst_id != "" do delete(inst_id)
		target_agent_id := primary_assignee_agent_id(task.assignee_ref_json)
		defer if target_agent_id != "" do delete(target_agent_id)

		if inst_id == "" && target_agent_id != "" {
			allocated_inst, alloc_ok := allocate_or_jit_worker_instance(service, chain, task, target_agent_id)
			if alloc_ok {
				defer delete(allocated_inst)
				ensure_chain_member(service, chain, allocated_inst, target_agent_id)
				new_assignee_ref = bind_agent_id_to_instance(task.assignee_ref_json, target_agent_id, allocated_inst)
				task.assignee_ref_json = new_assignee_ref
			}
		}
	}

	// REQ-FSM-REV-1: Atomic Reviewer JIT Agent Instance Binding on In_Validation
	if target_next == .In_Validation {
		target_ref_json := task.reviewer_refs_json
		if target_ref_json == "" || target_ref_json == "[]" {
			target_ref_json = chain.default_reviewer_refs_json
		}

		rev_agent_ids := extract_agent_ids_from_ref_blob(target_ref_json)
		defer {
			for r in rev_agent_ids do delete(r)
			delete(rev_agent_ids)
		}

		current_rev_json := target_ref_json
		for rev_agent_id in rev_agent_ids {
			allocated_inst, alloc_ok := allocate_or_jit_reviewer_instance(service, chain, task, rev_agent_id)
			if alloc_ok {
				defer delete(allocated_inst)
				ensure_chain_member(service, chain, allocated_inst, rev_agent_id)
				bound_ref := bind_agent_id_to_instance(current_rev_json, rev_agent_id, allocated_inst)
				append(&new_reviewer_refs, bound_ref)
				current_rev_json = bound_ref
				task.reviewer_refs_json = bound_ref
			}
		}
	}

	now := platform.clock_now(service.clock)
	if task.status != .In_Validation && target_next == .In_Validation {
		_, _ = iface.taskchain_delete_votes_by_task(service.repo, task.task_id, task.owner_user_id)
	}
	task.status = target_next
	task.updated_at = now
	if target_next == .In_Progress && task.started_at == "" do task.started_at = now
	if target_next == .Completed || target_next == .Cancelled {
		task.completed_at = now
	} else {
		task.completed_at = ""
	}
	task_ret, saved_ok, save_err := iface.taskchain_save_task(service.repo, task)
	if saved_ok {
		if updated_chain, sync_ok, _ := sync_chain_status_from_tasks(service, task.chain_id, task.owner_user_id); sync_ok {
			chain = updated_chain
		}
		// Auto-promotion + auto-advance (CT-4/CT-5) runs FIRST so every instance's
		// persisted current_task pointer is up to date before we notify: a terminal
		// transition unblocks dependents, entering/leaving In_Progress frees or
		// claims the work slot, and entering In_Validation makes the task a review
		// focus for its reviewers. recompute persists focus + wakes any newly
		// promoted assignees. Then the gated status-change notify (CT-6) wakes only
		// the recipients whose current_task is THIS task, with the correct action
		// label (R8). Ordering matters: gating reads the persisted pointer.
		_ = recompute_chain_promotions(service, chain)
		notify_task_status_change(service, auth, task_ret, chain)
		// MEM-6 #6/#7: paused/cancelled/validated_good policy wakes (not covered by
		// the CT-6 work/review gate above).
		notify_status_policy(service, auth, task_ret, chain)
		fanout_task_status_changed(service, auth, task_ret, chain)
		// REPORT THE ROW, NOT OUR INTENTION.
		//
		// recompute_chain_promotions above is allowed to change this task's status
		// again, in this same request, and it regularly does: reconcile enforces
		// "one In_Progress task per instance" and "zero while any task of yours is
		// in_validation", and demotes back to Queued at promotion.odin:398-400.
		// That is deliberate scheduling behaviour and is NOT a bug.
		//
		// The bug was that we returned task_ret — the in-memory struct we saved
		// BEFORE recompute ran — so the API answered ok:true carrying a status the
		// database no longer held. Callers recorded a state the Hub had already
		// discarded, with nothing in the response to hint at it.
		//
		// Re-reading makes the response observational: it states what the row holds
		// once everything that runs after the save has finished. It deliberately does
		// NOT predict or re-implement the engine's rules — a second copy of those
		// rules would drift from the engine and lie in a new way.
		//
		// ON THE FALLBACK: if the re-read fails we keep task_ret, which is the
		// pre-recompute struct — i.e. exactly the value this fix exists to stop
		// returning. That is a knowing trade, not an oversight: the status change
		// itself has already succeeded and been persisted, so failing the whole call
		// because a follow-up read failed would report a write that did happen as a
		// failure — a worse lie than the one being fixed here, and in the opposite
		// direction. If this path ever needs to be tightened, return the read error
		// rather than silently substituting a stale struct.
		if persisted, got, _ := iface.taskchain_get_task(service.repo, task.task_id); got {
			task_ret = persisted
		}
	}
	return task_ret, saved_ok, save_err
}

notify_task_status_change :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task: domain.Task, chain: domain.Task_Chain) {
	if service.bridge_command_sink.send_runtime_command == nil do return
	actor_agent_instance_id := auth.agent_instance_id if auth.kind == .Instance_Token else ""

	// CT-6 gating: the bridge derives its wake targets from the assignee/reviewer
	// id arrays by status. We gate those arrays here through the recipient's
	// persisted current_task so only instances whose current task is THIS task are
	// woken (fail-open when the pointer is unset/unknown). The explicit "action"
	// field states work-vs-review per R8 for unambiguous messaging.
	all_assignees := extract_instances_from_ref_blob(task.assignee_ref_json)
	defer delete(all_assignees)
	all_reviewers := extract_instances_from_ref_blob(task.reviewer_refs_json)
	defer delete(all_reviewers)
	all_def_reviewers := extract_instances_from_ref_blob(chain.default_reviewer_refs_json)
	defer delete(all_def_reviewers)

	assignees := make([dynamic]string)
	defer delete(assignees)
	for id in all_assignees { if allowed, _ := notification_allowed_for_recipient(service, id, task); allowed do append(&assignees, id) }
	reviewers := make([dynamic]string)
	defer delete(reviewers)
	for id in all_reviewers { if allowed, _ := notification_allowed_for_recipient(service, id, task); allowed do append(&reviewers, id) }
	def_reviewers := make([dynamic]string)
	defer delete(def_reviewers)
	for id in all_def_reviewers { if allowed, _ := notification_allowed_for_recipient(service, id, task); allowed do append(&def_reviewers, id) }

	action := action_for_status(task.status)
	// R8: never fire a wake with an empty action — those statuses (assigned/queued/
	// paused/validated_good/terminal) do not wake anyone here, so a notify would
	// carry no actionable meaning. The status change still persists + recomputes;
	// this only suppresses a meaningless wake command.
	if action == "" do return
	message := status_notify_message(task, action)
	defer delete(message)
	// MEM-6: human-readable message for the bridge to deliver verbatim.
	human_message := status_human_message(service, task, actor_agent_instance_id)
	defer delete(human_message)

	// Bridges to notify: the union of gated recipients' bridges plus the
	// coordinator's (kept for cross-bridge fan-out parity). A bridge that ends up
	// with no gated local target simply wakes no one — harmless.
	instance_ids := make([dynamic]string)
	defer delete(instance_ids)
	if chain.coordinator_agent_instance_id != "" do append(&instance_ids, chain.coordinator_agent_instance_id)
	for id in assignees do append(&instance_ids, id)
	for id in reviewers do append(&instance_ids, id)
	for id in def_reviewers do append(&instance_ids, id)

	bridge_ids := make(map[string]bool)
	defer delete(bridge_ids)
	for id in instance_ids {
		inst, inst_ok, _ := iface.agent_get_instance(service.agents, id)
		if inst_ok && inst.bridge_id != "" do bridge_ids[inst.bridge_id] = true
	}

	for bridge_id in bridge_ids {
		cmd_id := platform.generate_id(service.ids, "cmd_")
		b := strings.builder_make()
		strings.write_string(&b, `{"type":"task_status_changed_notify","command_id":"`)
		contracts.write_json_string(&b, cmd_id)
		strings.write_string(&b, `","task_id":"`)
		contracts.write_json_string(&b, string(task.task_id))
		strings.write_string(&b, `","chain_id":"`)
		contracts.write_json_string(&b, string(task.chain_id))
		strings.write_string(&b, `","new_status":"`)
		contracts.write_json_string(&b, task_status_string(task.status))
		strings.write_string(&b, `","action":"`)
		contracts.write_json_string(&b, action)
		strings.write_string(&b, `","message":"`)
		contracts.write_json_string(&b, message)
		strings.write_string(&b, `","human_message":"`)
		contracts.write_json_string(&b, human_message)
		strings.write_string(&b, `","assignee_instance_ids":[`)
		for id, i in assignees { if i>0 do strings.write_string(&b, ","); strings.write_string(&b, `"`); contracts.write_json_string(&b, id); strings.write_string(&b, `"`) }
		strings.write_string(&b, `],"reviewer_instance_ids":[`)
		for id, i in reviewers { if i>0 do strings.write_string(&b, ","); strings.write_string(&b, `"`); contracts.write_json_string(&b, id); strings.write_string(&b, `"`) }
		strings.write_string(&b, `],"default_reviewer_instance_ids":[`)
		for id, i in def_reviewers { if i>0 do strings.write_string(&b, ","); strings.write_string(&b, `"`); contracts.write_json_string(&b, id); strings.write_string(&b, `"`) }
		strings.write_string(&b, `],"mutation_id":"`)
		contracts.write_json_string(&b, cmd_id)
		strings.write_string(&b, `","actor_agent_instance_id":"`)
		contracts.write_json_string(&b, actor_agent_instance_id)
		strings.write_string(&b, `","updated_at":"`)
		contracts.write_json_string(&b, task.updated_at)
		strings.write_string(&b, `"}`)
		
		sent, err := project.bridge_command_send_runtime(service.bridge_command_sink, project.Runtime_Command{bridge_id=bridge_id, command_id=cmd_id, body_json=strings.to_string(b)})
		strings.builder_destroy(&b)
	}
}



// notify_status_policy emits human-readable wakes for status transitions the CT-6
// work/review gate (notify_task_status_change) does NOT cover: paused/cancelled
// (assignee + coordinator stop execution) and validated_good (coordinator sign-off).
// MEM-6 spec §4 #6/#7. Fire-and-forget; the actor is never self-woken.
notify_status_policy :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task: domain.Task, chain: domain.Task_Chain) {
	if service.bridge_command_sink.send_runtime_command == nil || service.agents == nil do return
	actor := auth.agent_instance_id if auth.kind == .Instance_Token else ""
	coord := chain.coordinator_agent_instance_id
	#partial switch task.status {
	case .Pausing:
		tag := "Task Pausing"
		assignee := primary_assignee_instance(task.assignee_ref_json)
		defer delete(assignee)
		instruction := fmt.tprintf("wrap up, post handoff comment, stash/commit changes, then run './.heimdall/bin/ham-ctl task status %s --status paused'", task.task_id)
		_ = send_task_wake(service, task, assignee, "pausing", tag, "pausing", instruction, actor)
		if coord != assignee do _ = send_task_wake(service, task, coord, "pausing", tag, "entered pausing state", "", actor)
	case .Paused, .Cancelled:
		tag := "Task Paused" if task.status == .Paused else "Task Cancelled"
		verb := "paused" if task.status == .Paused else "cancelled"
		assignee := primary_assignee_instance(task.assignee_ref_json)
		defer delete(assignee)
		_ = send_task_wake(service, task, assignee, "status", tag, verb, "", actor)
		if coord != assignee do _ = send_task_wake(service, task, coord, "status", tag, verb, "", actor)
	case .Validated_Good:
		_ = send_task_wake(service, task, coord, "status", "Review Consensus", "marked ready for sign-off", "", actor)
	case .Completed:
		_ = send_task_wake(service, task, coord, "status", "Task Completed", "has completed", "", actor)
	}
}

valid_task_transition :: proc(current, next: domain.Task_Status) -> bool {
	if current == next do return true
	switch current {
	case .Assigned: return next == .Queued || next == .In_Progress || next == .Paused || next == .Cancelled
	// Queued is a holding state managed by the auto-promotion engine: it may be
	// promoted back to Assigned/In_Progress when the instance is free, or paused/
	// cancelled.
	case .Queued: return next == .Assigned || next == .In_Progress || next == .Paused || next == .Cancelled
	case .In_Progress: return next == .Queued || next == .In_Validation || next == .Pausing || next == .Paused || next == .Cancelled || next == .Assigned
	// In_Validation -> Finishing is legal: it is the quorum auto-finalize path
	// (evaluate_task_quorum advances a fully-approved task to Finishing).
	case .In_Validation: return next == .Validated_Good || next == .Validated_Not_Good || next == .Finishing || next == .Completed || next == .Paused || next == .Cancelled || next == .In_Progress || next == .Assigned
	case .Finishing: return next == .Completed || next == .In_Validation || next == .In_Progress || next == .Pausing || next == .Paused || next == .Cancelled || next == .Assigned
	case .Pausing: return next == .Paused || next == .In_Progress || next == .Cancelled || next == .Assigned
	case .Validated_Not_Good: return next == .In_Progress || next == .Paused || next == .Cancelled || next == .Assigned
	case .Validated_Good: return next == .Completed || next == .Paused || next == .Cancelled || next == .Assigned
	case .Paused: return next == .In_Progress || next == .Assigned || next == .Cancelled
	case .Cancelled: return next == .Assigned || next == .In_Progress
	case .Completed: return next == .Assigned || next == .In_Progress || next == .In_Validation
	}
	for allowed in domain.task_allowed_transitions(current) {
		if allowed == next do return true
	}
	return false
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
	return iface.taskchain_save_comment(service.repo, comment)
}

list_comments :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID) -> ([]domain.Task_Comment, domain.Domain_Error) {
	// READ: owner-scoped (REQ-SEC-3).
	task, ok, err := get_task_for_read(service, auth, task_id)
	if !ok do return nil, err
	return iface.taskchain_list_comments_by_task(service.repo, task.task_id, task.owner_user_id)
}

target_string :: proc(target: Nudge_Target) -> string {
	switch target {
	case .Assignee: return "assignee"
	case .Reviewer: return "reviewer"
	case .Coordinator: return "coordinator"
	case .None: return "none"
	}
	return "none"
}

// nudge_target_action maps a Nudge_Target to the canonical R8 action label used
// consistently across every task notification ("work" for assignee, "review" for
// reviewer, "coordinate" for coordinator, "" for none). This keeps the wrapper's
// parsing uniform: every task notify carries an "action" field.
nudge_target_action :: proc(target: Nudge_Target) -> string {
	switch target {
	case .Assignee:    return "work"
	case .Reviewer:    return "review"
	case .Coordinator: return "coordinate"
	case .None:        return ""
	}
	return ""
}

// current_task_role_action maps a persisted Current_Task_Role to the R8 action
// label the notification must state: "work" (assignee) or "review" (reviewer).
// Returns "" for None (the instance has no current task).
current_task_role_action :: proc(role: domain.Current_Task_Role) -> string {
	switch role {
	case .Work:   return "work"
	case .Review: return "review"
	case .None:   return ""
	}
	return ""
}

// notification_gate_action is the STRICT CT-6 gate used for comment fan-out (R4):
// it returns (action, true) ONLY when `task_id` is exactly `instance_id`'s
// persisted current task, deriving the work-vs-review action from the persisted
// role. Any other case — pointer unset, different task, no role, or no agent repo
// — returns ("", false). Unlike notification_allowed_for_recipient (used for
// status-change wakes, which fail open on an unknown pointer), comments are purely
// informational and must never wake a participant who is not currently focused on
// the task, so this variant fails CLOSED.
notification_gate_action :: proc(service: ^Taskchain_Service, instance_id: string, task_id: domain.Task_ID) -> (string, bool) {
	if service == nil || service.agents == nil do return "", false
	if strings.trim_space(instance_id) == "" do return "", false
	inst, ok, _ := iface.agent_get_instance(service.agents, instance_id)
	if !ok do return "", false
	if inst.current_task_id != string(task_id) do return "", false
	action := current_task_role_action(inst.current_task_role)
	if action == "" do return "", false
	return action, true
}

// action_for_status is the R8 action label implied by a status-change wake: the
// bridge wakes the ASSIGNEE (work) when a task enters In_Progress or bounces back
// Validated_Not_Good (rework), and the REVIEWER (review) when it enters
// In_Validation. Other statuses do not wake anyone here.
action_for_status :: proc(status: domain.Task_Status) -> string {
	#partial switch status {
	case .In_Progress, .Validated_Not_Good: return "work"
	case .In_Validation:                     return "review"
	}
	return ""
}

// task_display_name returns the task's human title, falling back to its id when
// the title is empty, so notification messages are always readable.
task_display_name :: proc(task: domain.Task) -> string {
	t := strings.trim_space(task.title)
	if t != "" do return t
	return string(task.task_id)
}

// status_notify_message builds the natural-language wake message for a
// status-change notify, derived from the R8 action + task title (R8: every notify
// must say WORK / REVIEW unambiguously). Validated_Not_Good is phrased as a rework
// request so the assignee knows changes were requested.
status_notify_message :: proc(task: domain.Task, action: string) -> string {
	name := task_display_name(task)
	switch action {
	case "review": return strings.concatenate({"Review requested: ", name})
	case "work":
		if task.status == .Validated_Not_Good do return strings.concatenate({"Rework requested (changes requested): ", name})
		return strings.concatenate({"Work ready: ", name})
	}
	return strings.concatenate({"Task updated: ", name})
}

// comment_notify_message builds the natural-language wake message for a comment
// notify, stating whether the recipient should now work or review (R8) + title.
comment_notify_message :: proc(task: domain.Task, action: string) -> string {
	name := task_display_name(task)
	switch action {
	case "review": return strings.concatenate({"New comment on \"", name, "\" — please REVIEW"})
	case "work":   return strings.concatenate({"New comment on \"", name, "\" — please continue WORK"})
	}
	return strings.concatenate({"New comment on \"", name, "\""})
}

comment_preview_safe :: proc(body: string) -> string {
	trimmed := strings.trim_space(body)
	if strings.contains(trimmed, "vault:v1:") {
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
// If s is an encrypted vault token (starts with "vault:v1:"), rune truncation
// is bypassed so complete ciphertext is preserved for downstream client decryption.
// Caller owns the returned string.
truncate_runes :: proc(s: string, max: int) -> string {
	trimmed := strings.trim_space(s)
	if strings.contains(trimmed, "vault:v1:") {
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

// build_human_readable_task_notice renders the standardized notice (spec §2).
// `excerpt` is optional; when non-blank it is appended as a 20-rune-max quoted
// tail. Caller owns the returned string.
build_human_readable_task_notice :: proc(service: ^Taskchain_Service, task: domain.Task, actor_instance_id, event_tag, action_verb, excerpt: string) -> string {
	actor := resolve_actor_display(service, actor_instance_id)
	defer delete(actor)
	title := notice_task_title(task)
	defer delete(title)
	head := strings.concatenate({"[", event_tag, "] ", actor, " ", action_verb, " \"", title, "\" (", string(task.task_id), ")"})
	if strings.trim_space(excerpt) == "" do return head
	defer delete(head)
	ex: string
	if event_tag == "Task Pausing" || event_tag == "Task Approved" {
		ex = strings.clone(strings.trim_space(excerpt))
	} else {
		ex = truncate_runes(excerpt, NOTICE_EXCERPT_MAX_RUNES)
	}
	defer delete(ex)
	return strings.concatenate({head, ": \"", ex, "\""})
}

// status_human_message builds the human_message for a status-change wake from the
// task's new status (spec §3). Returns "" for statuses that carry no wake.
status_human_message :: proc(service: ^Taskchain_Service, task: domain.Task, actor_instance_id: string) -> string {
	assignee := primary_assignee_instance(task.assignee_ref_json)
	defer delete(assignee)
	#partial switch task.status {
	case .In_Progress:
		return build_human_readable_task_notice(service, task, assignee, "Work Started", "started work on", "")
	case .In_Validation:
		return build_human_readable_task_notice(service, task, assignee, "Review Requested", "submitted for review", "")
	case .Validated_Not_Good:
		return build_human_readable_task_notice(service, task, actor_instance_id, "Changes Requested", "requested changes on", "")
	}
	return ""
}

should_debounce_nudge_dispatch :: proc(service: ^Taskchain_Service, instance_id, task_id: string) -> bool {
	if service == nil || instance_id == "" || task_id == "" do return false
	key := strings.concatenate({instance_id, ":", task_id})
	defer delete(key)
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000

	sync.mutex_lock(&service.nudge_debounce_mutex)
	defer sync.mutex_unlock(&service.nudge_debounce_mutex)

	if service.nudge_debounce_last_unix_ms == nil {
		service.nudge_debounce_last_unix_ms = make(map[string]i64, runtime.heap_allocator())
	}

	if last_ms, ok := service.nudge_debounce_last_unix_ms[key]; ok {
		if now_ms - last_ms < 1500 {
			return true
		}
	}

	// The debounce map outlives this request. On the request path context.allocator
	// is the per-request arena (MEM-4), so the key MUST be cloned onto the persistent
	// heap or it dangles the moment the arena is freed after the response (a
	// use-after-free on the next map probe/resize). Mirrors the fragment/device_auth
	// caches.
	service.nudge_debounce_last_unix_ms[strings.clone(key, runtime.heap_allocator())] = now_ms
	return false
}

// notification_allowed_for_recipient implements CT-6 gating with a fail-open bias:
// a recipient is SUPPRESSED only when we positively know its persisted current
// task is a DIFFERENT task. When the instance's current_task is this task we allow
// with the persisted role's action label; when the pointer is unset/unknown (or no
// agent repo is wired) we allow with the status-implied action, so legitimate
// cross-bridge/replay/promotion wakes are never dropped just because a pointer has
// not been computed yet. The net effect is the intended noise reduction: an
// instance actively focused on task B is never woken for an event on task A, while
// still guaranteeing an agent is woken for its own current task.
notification_allowed_for_recipient :: proc(service: ^Taskchain_Service, instance_id: string, task: domain.Task) -> (bool, string) {
	status_action := action_for_status(task.status)
	if service == nil || service.agents == nil do return true, status_action
	if strings.trim_space(instance_id) == "" do return true, status_action
	inst, ok, _ := iface.agent_get_instance(service.agents, instance_id)
	if !ok do return true, status_action
	if inst.current_task_id == "" do return true, status_action
	if inst.current_task_id != string(task.task_id) do return false, ""
	// Positively this recipient's current task: prefer the persisted role's label.
	action := current_task_role_action(inst.current_task_role)
	if action == "" do action = status_action
	return true, action
}

task_status_string :: proc(status: domain.Task_Status) -> string {
	switch status {
	case .Assigned: return "assigned"
	case .Queued: return "queued"
	case .In_Progress: return "in_progress"
	case .In_Validation: return "in_validation"
	case .Finishing: return "finishing"
	case .Pausing: return "pausing"
	case .Validated_Good: return "validated_good"
	case .Validated_Not_Good: return "validated_not_good"
	case .Paused: return "paused"
	case .Completed: return "completed"
	case .Cancelled: return "cancelled"
	}
	return "assigned"
}

task_action :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID, action: string) -> (domain.Task, bool, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return domain.Task{}, false, err
	if action == "pause" {
		target_status: domain.Task_Status = .Paused
		if task.status == .In_Progress || task.status == .Finishing {
			target_status = .Pausing
		} else if task.status == .Pausing {
			target_status = .Paused
		}
		return change_task_status(service, auth, task_id, target_status)
	}
	return domain.Task{}, false, domain.domain_error(.Validation_Failed, "unsupported task action")
}

parse_actor_refs :: proc(blob: string, allocator := context.temp_allocator) -> (refs: [dynamic]domain.Actor_Ref, is_array: bool, ok: bool) {
	trimmed := strings.trim_space(blob)
	if len(trimmed) == 0 {
		return make([dynamic]domain.Actor_Ref, allocator), false, true
	}
	parsed, err := json.parse_string(trimmed, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if err != .None {
		return nil, false, false
	}
	refs = make([dynamic]domain.Actor_Ref, allocator)
	#partial switch val in parsed {
	case json.Object:
		ref := actor_ref_from_json_object(val)
		append(&refs, ref)
		return refs, false, true
	case json.Array:
		for item in val {
			if obj, is_obj := item.(json.Object); is_obj {
				append(&refs, actor_ref_from_json_object(obj))
			}
		}
		return refs, true, true
	case:
		return nil, false, false
	}
}

actor_refs_contain_user :: proc(blob: string) -> bool {
	refs, _, ok := parse_actor_refs(blob, context.temp_allocator)
	if !ok do return false
	for ref in refs do if ref.type == "user" || ref.user_id != "" do return true
	return false
}

task_requires_user_approval :: proc(task: domain.Task) -> bool {
	refs, _, ok := parse_actor_refs(task.reviewer_refs_json, context.temp_allocator)
	if !ok do return false
	owner := string(task.owner_user_id)
	for ref in refs do if ref.type == "user" && ref.user_id == owner do return true
	return false
}

set_owner_user_approval :: proc(blob, owner_user_id: string, required: bool, allocator := context.allocator) -> (string, bool) {
	refs, _, ok := parse_actor_refs(blob, context.temp_allocator)
	if !ok do return "", false
	out := make([dynamic]domain.Actor_Ref, allocator)
	defer delete(out)
	owner_seen := false
	for ref in refs {
		if ref.type == "user" || ref.user_id != "" {
			if ref.type == "user" && ref.user_id == owner_user_id {
				if required && !owner_seen {
					append(&out, ref)
					owner_seen = true
				}
			} else {
				append(&out, ref)
			}
			continue
		}
		append(&out, ref)
	}
	if required && !owner_seen do append(&out, domain.Actor_Ref{type = "user", user_id = owner_user_id})
	return marshal_actor_refs(out[:], true, allocator)
}

actor_ref_from_json_object :: proc(obj: json.Object) -> domain.Actor_Ref {
	ref: domain.Actor_Ref
	if t, ok := obj["type"].(json.String); ok {
		ref.type = string(t)
	}
	if a, ok := obj["agent_id"].(json.String); ok {
		ref.agent_id = string(a)
	}
	if inst, ok := obj["agent_instance_id"].(json.String); ok {
		ref.agent_instance_id = string(inst)
	}
	if u, ok := obj["user_id"].(json.String); ok {
		ref.user_id = string(u)
	}
	return ref
}

marshal_actor_refs :: proc(refs: []domain.Actor_Ref, is_array: bool, allocator := context.allocator) -> (string, bool) {
	if is_array {
		bytes, err := json.marshal(refs, allocator = allocator)
		if err != nil do return "", false
		return string(bytes), true
	} else if len(refs) > 0 {
		bytes, err := json.marshal(refs[0], allocator = allocator)
		if err != nil do return "", false
		return string(bytes), true
	}
	return strings.clone("", allocator), true
}

extract_instances_from_ref_blob :: proc(blob: string) -> [dynamic]string {
	instances := make([dynamic]string)
	if blob == "" do return instances
	refs, _, ok := parse_actor_refs(blob, context.temp_allocator)
	if !ok do return instances
	for ref in refs {
		id := ref.agent_instance_id
		if id != "" {
			if idx := strings.index(blob, id); idx >= 0 {
				append(&instances, blob[idx : idx + len(id)])
			} else {
				append(&instances, strings.clone(id, context.temp_allocator))
			}
		}
	}
	return instances
}

manual_nudge :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID, message: string) -> (Manual_Nudge, bool, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return Manual_Nudge{}, false, err
	if task.publish_state != .Published do return Manual_Nudge{}, false, domain.domain_error(.Conflict, "draft task cannot be nudged")
	if task.status == .Completed || task.status == .Cancelled do return Manual_Nudge{}, false, domain.domain_error(.Conflict, "terminal task cannot be nudged")
	
	target := nudge_target_for_status(task.status)
	nudge_id := platform.generate_id(service.ids, "ndg_")
	now := platform.clock_now(service.clock)
	nudge := Manual_Nudge{task_id = task.task_id, owner_user_id = task.owner_user_id, target = target, message = message, created_at = now, nudge_id = nudge_id}
	
	instance_ids := make([dynamic]string)
	defer delete(instance_ids)
	
	if target == .Assignee {
		extracted := extract_instances_from_ref_blob(task.assignee_ref_json)
		for id in extracted {
			found := false
			for existing in instance_ids {
				if existing == id {
					found = true
					break
				}
			}
			if !found do append(&instance_ids, id)
		}
		delete(extracted)
	} else if target == .Reviewer {
		extracted := extract_instances_from_ref_blob(task.reviewer_refs_json)
		for id in extracted {
			found := false
			for existing in instance_ids {
				if existing == id {
					found = true
					break
				}
			}
			if !found do append(&instance_ids, id)
		}
		delete(extracted)
	} else if target == .Coordinator {
		chain, chain_ok, _ := iface.taskchain_get_chain(service.repo, task.chain_id)
		if chain_ok && chain.coordinator_agent_instance_id != "" {
			append(&instance_ids, chain.coordinator_agent_instance_id)
		}
	}
	
	if target == .None || len(instance_ids) == 0 {
		nudge.delivery_state = "no_targets"
		nudge.targets_json = "[]"
		return nudge, true, domain.Domain_Error{}
	}
	
	// MEM-6: human-readable nudge line — custom message if provided, else a
	// stable fallback. Actor is the nudger (empty => "@User").
	nudger := auth.agent_instance_id if auth.kind == .Instance_Token else ""
	nudge_excerpt := strings.trim_space(message)
	if nudge_excerpt == "" do nudge_excerpt = "Awaiting progress update"
	nudge_human_message := build_human_readable_task_notice(service, task, nudger, "Nudge", "nudged on", nudge_excerpt)
	defer delete(nudge_human_message)

	live_delivered := 0
	durable_queued := 0
	failed := 0
	targets_b := strings.builder_make()
	defer strings.builder_destroy(&targets_b)
	strings.write_string(&targets_b, "[")
	
	for id, i in instance_ids {
		if i > 0 do strings.write_string(&targets_b, ",")
		strings.write_string(&targets_b, `{"agent_instance_id":"`)
		contracts.write_json_string(&targets_b, id)
		strings.write_string(&targets_b, `","role":"`)
		contracts.write_json_string(&targets_b, target_string(target))
		
		inst, inst_ok, _ := iface.agent_get_instance(service.agents, id)
		if !inst_ok || inst.bridge_id == "" {
			failed += 1
			strings.write_string(&targets_b, `","state":"failed"}`)
			continue
		}

		if should_debounce_nudge_dispatch(service, id, string(task.task_id)) {
			live_delivered += 1
			strings.write_string(&targets_b, `","state":"delivered"}`)
			continue
		}
		
		strings.write_string(&targets_b, `","bridge_id":"`)
		contracts.write_json_string(&targets_b, inst.bridge_id)
		
		cmd_id := platform.generate_id(service.ids, "cmd_")
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		strings.write_string(&b, `{"type":"notify_task_nudge","command_id":"`)
		contracts.write_json_string(&b, cmd_id)
		strings.write_string(&b, `","agent_instance_id":"`)
		contracts.write_json_string(&b, id)
		strings.write_string(&b, `","task_id":"`)
		contracts.write_json_string(&b, string(task.task_id))
		strings.write_string(&b, `","chain_id":"`)
		contracts.write_json_string(&b, string(task.chain_id))
		strings.write_string(&b, `","nudge_id":"`)
		contracts.write_json_string(&b, nudge_id)
		strings.write_string(&b, `","target_role":"`)
		contracts.write_json_string(&b, target_string(target))
		strings.write_string(&b, `","action":"`)
		contracts.write_json_string(&b, nudge_target_action(target))
		strings.write_string(&b, `","task_status":"`)
		contracts.write_json_string(&b, task_status_string(task.status))
		strings.write_string(&b, `","body":"`)
		contracts.write_json_string(&b, message)
		strings.write_string(&b, `","human_message":"`)
		contracts.write_json_string(&b, nudge_human_message)
		strings.write_string(&b, `","created_at":"`)
		contracts.write_json_string(&b, now)
		strings.write_string(&b, `"}`)

		sent := false
		if service.bridge_command_sink.send_runtime_command_wait != nil {
			result_json, sent, _ := project.bridge_command_send_runtime_wait(service.bridge_command_sink, project.Runtime_Command{bridge_id=inst.bridge_id, command_id=cmd_id, body_json=strings.to_string(b)}, 1000)
			if sent {
				if strings.contains(result_json, `"status":"succeeded"`) {
					live_delivered += 1
					strings.write_string(&targets_b, `","state":"delivered"}`)
				} else {
					durable_queued += 1
					strings.write_string(&targets_b, `","state":"queued"}`)
				}
			} else {
				failed += 1
				strings.write_string(&targets_b, `","state":"failed"}`)
			}
		} else {
			if service.bridge_command_sink.send_runtime_command != nil {
				sent, _ = project.bridge_command_send_runtime(service.bridge_command_sink, project.Runtime_Command{bridge_id=inst.bridge_id, command_id=cmd_id, body_json=strings.to_string(b)})
			}
			if sent {
				durable_queued += 1
				strings.write_string(&targets_b, `","state":"queued"}`)
			} else {
				failed += 1
				strings.write_string(&targets_b, `","state":"failed"}`)
			}
		}
	}
	strings.write_string(&targets_b, "]")
	
	nudge.targets_json = strings.clone(strings.to_string(targets_b))
	nudge.live_delivered = live_delivered
	nudge.durable_queued = durable_queued
	nudge.failed = failed
	
	if live_delivered > 0 {
		nudge.delivery_state = "delivered"
	} else if durable_queued > 0 {
		nudge.delivery_state = "queued"
	} else {
		nudge.delivery_state = "failed"
	}

	return nudge, true, domain.Domain_Error{}
}

// send_task_wake emits one human-readable notify_task_nudge for a task-level event
// to a single instance. `origin`/`tag`/`verb`/`excerpt` shape the [tag] @actor verb
// "title" (id): "excerpt" message; `actor_instance` is the acting agent ("" =>
// "@User"). Returns true when a command was actually sent (instance live + bridge).
// MEM-6. Skips the actor itself and blank/unresolvable targets.
send_task_wake :: proc(service: ^Taskchain_Service, task: domain.Task, target_instance_id, origin, tag, verb, excerpt, actor_instance: string) -> bool {
	if service.bridge_command_sink.send_runtime_command == nil || service.agents == nil do return false
	tid := strings.trim_space(target_instance_id)
	if tid == "" || tid == strings.trim_space(actor_instance) do return false
	inst, inst_ok, _ := iface.agent_get_instance(service.agents, tid)
	if !inst_ok || inst.bridge_id == "" do return false
	hm := build_human_readable_task_notice(service, task, actor_instance, tag, verb, excerpt)
	defer delete(hm)
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
	strings.write_string(&b, `","task_id":"`)
	contracts.write_json_string(&b, string(task.task_id))
	strings.write_string(&b, `","chain_id":"`)
	contracts.write_json_string(&b, string(task.chain_id))
	strings.write_string(&b, `","target_instance_id":"`)
	contracts.write_json_string(&b, tid)
	strings.write_string(&b, `","target_role":"`)
	contracts.write_json_string(&b, origin)
	strings.write_string(&b, `","action":"`)
	contracts.write_json_string(&b, origin)
	strings.write_string(&b, `","task_status":"`)
	contracts.write_json_string(&b, task_status_string(task.status))
	strings.write_string(&b, `","message":"`)
	contracts.write_json_string(&b, hm)
	strings.write_string(&b, `","human_message":"`)
	contracts.write_json_string(&b, hm)
	strings.write_string(&b, `","created_at":"`)
	contracts.write_json_string(&b, now)
	strings.write_string(&b, `"`)
	if origin == "pausing" || origin == "finishing" {
		strings.write_string(&b, `,"interrupt":true`)
	}
	strings.write_string(&b, `}`)
	sent, _ := project.bridge_command_send_runtime(service.bridge_command_sink, project.Runtime_Command{bridge_id = inst.bridge_id, command_id = cmd_id, body_json = strings.to_string(b)})
	return sent
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

// task_priority_label renders a priority as its P0/P1/P2 label for notices.
task_priority_label :: proc(p: domain.Task_Priority) -> string {
	switch p {
	case .P0: return "P0"
	case .P1: return "P1"
	case .P2: return "P2"
	}
	return "P2"
}

// send_comment_wake pushes one comment/progress wake (notify_task_nudge, origin
// "comment") to a single instance. Returns true when a command was actually sent
// (the instance is resolvable and has a live bridge). MEM-6.
send_comment_wake :: proc(service: ^Taskchain_Service, task: domain.Task, target_instance_id, legacy_message, human_message, now: string) -> bool {
	if service.agents == nil do return false
	inst, inst_ok, _ := iface.agent_get_instance(service.agents, target_instance_id)
	if !inst_ok || inst.bridge_id == "" do return false
	cmd_id := platform.generate_id(service.ids, "cmd_")
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"type":"notify_task_nudge","origin":"comment","command_id":"`)
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, `","agent_instance_id":"`)
	contracts.write_json_string(&b, target_instance_id)
	strings.write_string(&b, `","task_id":"`)
	contracts.write_json_string(&b, string(task.task_id))
	strings.write_string(&b, `","chain_id":"`)
	contracts.write_json_string(&b, string(task.chain_id))
	strings.write_string(&b, `","target_instance_id":"`)
	contracts.write_json_string(&b, target_instance_id)
	strings.write_string(&b, `","target_role":"comment","action":"comment","task_status":"`)
	contracts.write_json_string(&b, task_status_string(task.status))
	strings.write_string(&b, `","message":"`)
	contracts.write_json_string(&b, legacy_message)
	strings.write_string(&b, `","human_message":"`)
	contracts.write_json_string(&b, human_message)
	strings.write_string(&b, `","created_at":"`)
	contracts.write_json_string(&b, now)
	strings.write_string(&b, `"}`)
	sent, _ := project.bridge_command_send_runtime(service.bridge_command_sink, project.Runtime_Command{bridge_id = inst.bridge_id, command_id = cmd_id, body_json = strings.to_string(b)})
	return sent
}

comment_task :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, input: Task_Comment_Input) -> (domain.Task_Comment, []string, bool, domain.Domain_Error) {
	if strings.trim_space(input.body) == "" do return domain.Task_Comment{}, nil, false, domain.domain_error(.Validation_Failed, "comment body is required")
	task, ok, err := get_task(service, auth, input.task_id)
	if !ok do return domain.Task_Comment{}, nil, false, err
	if task.publish_state != .Published do return domain.Task_Comment{}, nil, false, domain.domain_error(.Conflict, "draft task cannot be commented on")
	if auth.kind == .Instance_Token {
		if auth.agent_instance_id == "" do return domain.Task_Comment{}, nil, false, domain.domain_error(.Forbidden, "instance token is required")
		chain, chain_ok, _ := iface.taskchain_get_chain(service.repo, task.chain_id)
		is_coord := chain_ok && is_chain_coordinator(service, chain, auth.agent_instance_id)
		is_actor := strings.contains(task.assignee_ref_json, auth.agent_instance_id) || strings.contains(task.reviewer_refs_json, auth.agent_instance_id)
		if !is_coord && !is_actor do return domain.Task_Comment{}, nil, false, domain.domain_error(.Forbidden, "instance token is not assigned to or coordinator of this task")
	}
	invalid_ids := make([dynamic]string)
	defer delete(invalid_ids)
	if len(input.notify) > 0 {
		for target in input.notify {
			t := strings.trim_space(target)
			if t == "" do continue
			if service.agents == nil {
				append(&invalid_ids, t)
				continue
			}
			inst, inst_ok, _ := iface.agent_get_instance(service.agents, t)
			if !inst_ok || inst.agent_instance_id == "" {
				append(&invalid_ids, t)
			}
		}
	}
	if len(invalid_ids) > 0 {
		msg := fmt.tprintf("invalid target instance IDs: %s", strings.join(invalid_ids[:], ", "))
		return domain.Task_Comment{}, nil, false, domain.domain_error(.Validation_Failed, msg)
	}

	now := platform.clock_now(service.clock)
	comment := domain.Task_Comment{comment_id = platform.generate_id(service.ids, "cmt_"), task_id = task.task_id, chain_id = task.chain_id, owner_user_id = task.owner_user_id, author_agent_instance_id = auth.agent_instance_id, body = input.body, created_at = now, updated_at = now}
	saved, ok2, err2 := iface.taskchain_save_comment(service.repo, comment)
	if !ok2 do return saved, nil, ok2, err2

	// MEM-6 comment fan-out. Recipients (de-duped, author excluded):
	//   * explicit --notify ids                         -> [Comment]
	//   * chain coordinator, always kept informed       -> [Progress Update] for an
	//     agent comment, [Comment] for a user comment
	//   * USER-authored comment (any task): every role-holder (assignee + reviewer(s)
	//     + default reviewers) regardless of --notify   -> [Comment]
	//     (user directive 2026-09-09)
	notified := make([dynamic]string)
	if service.bridge_command_sink.send_runtime_command != nil && service.agents != nil {
		author := auth.agent_instance_id if auth.kind == .Instance_Token && auth.agent_instance_id != "" else (auth.user_id if auth.user_id != "" else "user")
		author_name := author
		if auth.kind == .Instance_Token && auth.agent_instance_id != "" {
			if inst, ok, _ := iface.agent_get_instance(service.agents, auth.agent_instance_id); ok {
				if dn := strings.trim_space(inst.display_name); dn != "" {
					author_name = dn
				}
			}
		}
		preview := comment_preview_safe(input.body)
		defer delete(preview)
		legacy_message := fmt.tprintf("Comment from %s on task %s: %s", author_name, string(task.task_id), preview)
		// Actor is the authoring instance ("" => "@User" for a user-authored comment).
		author_instance := auth.agent_instance_id if auth.kind == .Instance_Token && auth.agent_instance_id != "" else ""
		is_user_author := auth.kind != .Instance_Token
		comment_msg := build_human_readable_task_notice(service, task, author_instance, "Comment", "commented on", input.body)
		defer delete(comment_msg)
		progress_msg := build_human_readable_task_notice(service, task, author_instance, "Progress Update", "posted an update on", input.body)
		defer delete(progress_msg)

		chain, chain_ok, _ := iface.taskchain_get_chain(service.repo, task.chain_id)

		recips := make(map[string]string)
		defer delete(recips)
		order := make([dynamic]string)
		defer delete(order)
		// Keys are cloned (the source blobs/refs are freed below before we send), so
		// `order`/`recips` own their ids; freed after the send loop.
		add_recip := proc(recips: ^map[string]string, order: ^[dynamic]string, author_instance, id, msg: string) {
			t := strings.trim_space(id)
			if t == "" || t == author_instance do return
			if _, exists := recips[t]; exists do return
			key := strings.clone(t)
			recips[key] = msg
			append(order, key)
		}

		// Explicit --notify targets: [Comment].
		for target in input.notify do add_recip(&recips, &order, author_instance, target, comment_msg)
		// User-authored comment: wake every role-holder regardless of --notify.
		if is_user_author {
			a := primary_assignee_instance(task.assignee_ref_json)
			add_recip(&recips, &order, author_instance, a, comment_msg)
			delete(a)
			revs := extract_instances_from_ref_blob(task.reviewer_refs_json)
			for id in revs do add_recip(&recips, &order, author_instance, id, comment_msg)
			delete(revs)
			if chain_ok {
				drevs := extract_instances_from_ref_blob(chain.default_reviewer_refs_json)
				for id in drevs do add_recip(&recips, &order, author_instance, id, comment_msg)
				delete(drevs)
			}
		}

		for id in order {
			if send_comment_wake(service, task, id, legacy_message, recips[id], now) do append(&notified, strings.clone(id))
		}
		for id in order do delete(id)
	}

	return saved, notified[:], true, domain.Domain_Error{}
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

	// MEM-6 #11: capture the non-terminal tasks this member still holds (as assignee)
	// BEFORE removal so we can alert the coordinator that a reassignment is needed.
	held_tasks := make([dynamic]string)
	defer delete(held_tasks)
	if tasks, terr := iface.taskchain_list_tasks_by_chain(service.repo, chain.chain_id, chain.owner_user_id); terr.code == .None {
		for t in tasks {
			if task_is_terminal(t.status) do continue
			a := primary_assignee_instance(t.assignee_ref_json)
			if a == agent_instance_id do append(&held_tasks, string(t.task_id))
			delete(a)
		}
		delete(tasks)
	}

	removed, remove_err := iface.taskchain_remove_member(service.repo, chain.chain_id, agent_instance_id, chain.owner_user_id)
	// If a coordinator member was removed, resync the derived mirror column from
	// the canonical members table (H9).
	if removed && is_target_coordinator do _ = coordinator_sync_mirror(service, chain)

	// MEM-6 #11: if the removed member still held tasks, alert the coordinator that a
	// reassignment is required (skip when the coordinator is the one being removed).
	if removed && len(held_tasks) > 0 {
		coord := chain.coordinator_agent_instance_id
		if coord != "" && coord != agent_instance_id {
			removed_display := resolve_actor_display(service, agent_instance_id)
			defer delete(removed_display)
			ids_joined := strings.join(held_tasks[:], ", ")
			defer delete(ids_joined)
			ids_excerpt := truncate_runes(ids_joined, NOTICE_EXCERPT_MAX_RUNES)
			defer delete(ids_excerpt)
			human_message := strings.concatenate({"[Member Removed] ", removed_display, " was removed while holding tasks (", ids_excerpt, "). Reassignment required."})
			defer delete(human_message)
			_ = send_chain_level_wake(service, chain, coord, "member_removed", human_message)
		}
	}
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

add_task_dependency :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id, depends_on_task_id: domain.Task_ID) -> (domain.Task_Dependency, bool, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return domain.Task_Dependency{}, false, err
	dep_task, dep_ok, dep_err := get_task(service, auth, depends_on_task_id)
	if !dep_ok do return domain.Task_Dependency{}, false, dep_err

	if task.chain_id != dep_task.chain_id do return domain.Task_Dependency{}, false, domain.domain_error(.Conflict, "dependencies must be in the same chain")
	if task.task_id == dep_task.task_id do return domain.Task_Dependency{}, false, domain.domain_error(.Conflict, "task cannot depend on itself")

	// Cycle detection
	if has_dependency_cycle(service, task.chain_id, task.owner_user_id, task.task_id, dep_task.task_id) {
		return domain.Task_Dependency{}, false, domain.domain_error(.Conflict, "circular dependency detected")
	}

	now := platform.clock_now(service.clock)
	dep := domain.Task_Dependency{
		task_id = task.task_id,
		depends_on_task_id = dep_task.task_id,
		chain_id = task.chain_id,
		owner_user_id = task.owner_user_id,
		created_at = now,
	}

	saved_dep, dep_save_ok, dep_save_err := iface.taskchain_save_dependency(service.repo, dep)
	if !dep_save_ok do return domain.Task_Dependency{}, false, dep_save_err
	// NO auto-reconcile on dependency change (explicit decision): the coordinator
	// restructures dependencies freely, then triggers `reconcile` when ready.
	return saved_dep, true, domain.Domain_Error{}
}

remove_task_dependency :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id, depends_on_task_id: domain.Task_ID) -> (bool, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, task_id)
	if !ok do return false, err
	removed, remove_err := iface.taskchain_remove_dependency(service.repo, task.task_id, depends_on_task_id, task.owner_user_id)
	if remove_err.code != .None do return removed, remove_err

	// MEM-6 #3: removing a dependency can UNBLOCK the task. On an active/published
	// chain, notify the coordinator [Task Unblocked] and auto-reconcile so the
	// assignee is promoted/woken to the now-ready work (the promotion wake is the
	// assignee's "ready" signal; a per-instance debounce coalesces any overlap).
	if removed {
		if chain, chain_ok, _ := iface.taskchain_get_chain(service.repo, task.chain_id); chain_ok && chain.publish_state == .Published && chain.status == .Active {
			tasks, terr := iface.taskchain_list_tasks_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
			deps, derr := iface.taskchain_list_dependencies_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
			if terr.code == .None && derr.code == .None {
				fresh, fresh_ok, _ := iface.taskchain_get_task(service.repo, task.task_id)
				if fresh_ok && work_status_is_actionable(fresh.status) && deps_satisfied_for_task(tasks, deps, fresh.task_id) {
					actor := auth.agent_instance_id if auth.kind == .Instance_Token else ""
					_ = send_task_wake(service, fresh, chain.coordinator_agent_instance_id, "unblocked", "Task Unblocked", "is now unblocked —", "dependencies satisfied", actor)
				}
				delete(tasks); delete(deps)
			}
			_ = recompute_chain_promotions(service, chain)
		}
	}
	return removed, remove_err
}

list_chain_dependencies :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID) -> ([]domain.Task_Dependency, domain.Domain_Error) {
	// READ: owner-scoped (REQ-SEC-3).
	chain, ok, err := get_chain_for_read(service, auth, chain_id)
	if !ok do return nil, err
	return iface.taskchain_list_dependencies_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
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

record_task_vote :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, input: Vote_Input) -> (domain.Task_Vote, bool, domain.Domain_Error) {
	task, ok, err := get_task(service, auth, input.task_id)
	if !ok do return domain.Task_Vote{}, false, err
	if task.publish_state != .Published do return domain.Task_Vote{}, false, domain.domain_error(.Conflict, "draft task cannot receive votes")

	voter_instance_id := ""
	if auth.kind == .Instance_Token {
		voter_instance_id = auth.agent_instance_id
	}

	// Assignee cannot vote on own task
	if voter_instance_id != "" && strings.contains(task.assignee_ref_json, voter_instance_id) {
		return domain.Task_Vote{}, false, domain.domain_error(.Forbidden, "assignee cannot vote on their own task")
	}

	if auth.kind == .Instance_Token {
		chain, chain_ok, _ := iface.taskchain_get_chain(service.repo, task.chain_id)
		is_reviewer := strings.contains(task.reviewer_refs_json, voter_instance_id)
		if !is_reviewer && chain_ok {
			is_reviewer = strings.contains(chain.default_reviewer_refs_json, voter_instance_id)
		}
		if !is_reviewer {
			return domain.Task_Vote{}, false, domain.domain_error(.Forbidden, "voter is not a designated reviewer for this task")
		}
	}
	if auth.kind == .User_Token && !task_requires_user_approval(task) {
		return domain.Task_Vote{}, false, domain.domain_error(.Forbidden, "user is not a designated reviewer for this task")
	}

	now := platform.clock_now(service.clock)
	v := input.vote
	if v != "lgtm" && v != "ngtm" do return domain.Task_Vote{}, false, domain.domain_error(.Validation_Failed, "vote must be lgtm or ngtm")

	vote := domain.Task_Vote{
		task_id = task.task_id,
		reviewer_agent_instance_id = voter_instance_id,
		chain_id = task.chain_id,
		owner_user_id = task.owner_user_id,
		vote = v,
		comment = input.comment,
		created_at = now,
		updated_at = now,
	}

	saved_vote, save_ok, save_err := iface.taskchain_save_vote(service.repo, vote)
	if !save_ok do return domain.Task_Vote{}, false, save_err

	// Evaluate Quorum and auto-promote task status
	evaluate_task_quorum(service, task)

	// MEM-6 #5: vote visibility. Coordinator is always informed; on an approving
	// quorum the assignee is told; on a pending LGTM the remaining reviewers are too;
	// an NGTM tells the coordinator changes were requested (the assignee is already
	// re-focused by the quorum -> Validated_Not_Good reconcile).
	if chain, chain_ok, _ := iface.taskchain_get_chain(service.repo, task.chain_id); chain_ok {
		coord := chain.coordinator_agent_instance_id
		updated, _, _ := iface.taskchain_get_task(service.repo, task.task_id)
		if v == "lgtm" {
			if updated.status == .Finishing {
				assignee := primary_assignee_instance(updated.assignee_ref_json)
				defer delete(assignee)
				instruction := fmt.tprintf("wrap up, commit/push changes, then run './.heimdall/bin/ham-ctl task status %s --status completed'", updated.task_id)
				_ = send_task_wake(service, updated, assignee, "finishing", "Task Approved", "is approved — please wrap up and complete", instruction, voter_instance_id)
				_ = send_task_wake(service, updated, coord, "finishing", "Task Approved", "entered finishing state", input.comment, voter_instance_id)
			} else if updated.status == .Completed {
				assignee := primary_assignee_instance(updated.assignee_ref_json)
				defer delete(assignee)
				_ = send_task_wake(service, updated, assignee, "vote", "Task Approved", "voted LGTM on", input.comment, voter_instance_id)
				_ = send_task_wake(service, updated, coord, "vote", "Task Approved", "voted LGTM on", input.comment, voter_instance_id)
			} else {
				_ = send_task_wake(service, updated, coord, "vote", "Review Progress", "voted LGTM on", input.comment, voter_instance_id)
				reviewers := extract_instances_from_ref_blob(updated.reviewer_refs_json)
				defer delete(reviewers)
				for rid in reviewers do if rid != voter_instance_id do _ = send_task_wake(service, updated, rid, "vote", "Review Progress", "voted LGTM on", input.comment, voter_instance_id)
			}
		} else {
			_ = send_task_wake(service, updated, coord, "vote", "Changes Requested", "requested changes on", input.comment, voter_instance_id)
		}
	}

	// Always reconcile after a vote so the reviewer is stopped once their focus
	// clears (REQ-30 excludes already-voted tasks from the review pool). On a
	// resolving vote, evaluate_task_quorum already called recompute above; calling
	// it again is idempotent with snapshot-diff-act — the second diff sees no
	// change and emits nothing.
	if chain2, chain2_ok, _ := iface.taskchain_get_chain(service.repo, task.chain_id); chain2_ok {
		_ = recompute_chain_promotions(service, chain2)
	}

	return saved_vote, true, domain.Domain_Error{}
}

evaluate_task_quorum :: proc(service: ^Taskchain_Service, task: domain.Task) {
	if task.status != .In_Validation do return

	votes, err := iface.taskchain_list_votes_by_task(service.repo, task.task_id, task.owner_user_id)
	if err.code != .None do return

	has_ngtm := false
	lgtm_count := 0
	for v in votes {
		if v.vote == "ngtm" do has_ngtm = true
		if v.vote == "lgtm" do lgtm_count += 1
	}

	// Determine the quorum outcome. Any ngtm fails the task; otherwise a
	// satisfied lgtm quorum means the task is fully approved.
	updated_status := task.status
	quorum_approved := false
	if has_ngtm {
		updated_status = .Validated_Not_Good
	} else {
		required_count := count_required_reviewers(task.reviewer_refs_json)
		if required_count <= 1 && lgtm_count >= 1 {
			quorum_approved = true
		} else if required_count > 1 && lgtm_count >= required_count {
			quorum_approved = true
		}
	}

	// When all required reviewers approve (no ngtm), auto-finalize the task all
	// the way to Completed rather than lingering in Validated_Good. This is the
	// only path that unblocks dependents: task_status_unblocks_dependents treats
	// just Completed/Cancelled as clearing — Validated_Good does NOT unblock. We
	// go In_Validation -> Completed directly (a legal transition here since the
	// quorum is satisfied) and set completed_at exactly once. Idempotency: the
	// early return above (status != In_Validation) makes late/duplicate votes a
	// no-op, so completion side-effects run once.
	if quorum_approved {
		updated_status = .Finishing
	}

	if updated_status != task.status {
		now := platform.clock_now(service.clock)
		t := task
		t.status = updated_status
		t.updated_at = now
		if updated_status == .Completed do t.completed_at = now
		saved, ok, _ := iface.taskchain_save_task(service.repo, t)
		// CT-10: recompute whenever a review RESOLVES the task, not just on the
		// Completed path. Both outcomes change an instance's current focus:
		//   * Completed (LGTM quorum): frees the reviewer + unblocks dependents so
		//     downstream tasks auto-claim.
		//   * Validated_Not_Good (any NGTM): the reviewer is done reviewing and must
		//     advance to its next focus, AND the not-good task re-enters the
		//     assignee's promotable pool (work_status_is_actionable includes
		//     Validated_Not_Good) so auto-promotion flows the rework back to the
		//     assignee without a manual bump.
		// Guarding on updated_status != task.status keeps this a single recompute
		// per real resolution and a no-op for idempotent/duplicate votes.
		if ok && updated_status != task.status {
			_, _, _ = sync_chain_status_from_tasks(service, saved.chain_id, saved.owner_user_id)
			chain, chain_ok, _ := iface.taskchain_get_chain(service.repo, saved.chain_id)
			if chain_ok {
				_ = recompute_chain_promotions(service, chain)
				fanout_task_status_changed(service, contracts.Auth_Context{kind = .None}, saved, chain)
			}
		}
	}
}

count_required_reviewers :: proc(reviewer_refs_json: string) -> int {
	if reviewer_refs_json == "" || reviewer_refs_json == "[]" do return 0
	refs, _, ok := parse_actor_refs(reviewer_refs_json, context.temp_allocator)
	if !ok do return 0
	count := 0
	for ref in refs {
		if ref.agent_instance_id != "" || ref.user_id != "" || (ref.type == "agent_id" && ref.agent_id != "") {
			count += 1
		}
	}
	return count
}

list_task_votes :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID) -> ([]domain.Task_Vote, domain.Domain_Error) {
	// READ: owner-scoped (REQ-SEC-3).
	task, ok, err := get_task_for_read(service, auth, task_id)
	if !ok do return nil, err
	return iface.taskchain_list_votes_by_task(service.repo, task.task_id, task.owner_user_id)
}

nudge_target_for_status :: proc(status: domain.Task_Status) -> Nudge_Target {
	switch status {
	// Queued tasks are held back deliberately, so they do not target a nudge.
	case .Queued: return .None
	case .Assigned, .In_Progress, .Validated_Not_Good, .Finishing, .Pausing, .Paused: return .Assignee
	case .In_Validation: return .Reviewer
	case .Validated_Good: return .Coordinator
	case .Completed, .Cancelled: return .None
	}
	return .None
}

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

validate_actor_refs :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, assignee_ref_json, reviewer_refs_json: string) -> (bool, domain.Domain_Error) {
	if ok, err := validate_ref_blob(service, chain, assignee_ref_json); !ok do return false, err
	if ok, err := validate_ref_blob(service, chain, reviewer_refs_json); !ok do return false, err
	return true, domain.Domain_Error{}
}

validate_ref_blob :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, blob: string) -> (bool, domain.Domain_Error) {
	if blob == "" do return true, domain.Domain_Error{}
	refs, _, ok := parse_actor_refs(blob, context.temp_allocator)
	if !ok do return false, domain.domain_error(.Validation_Failed, "invalid actor ref JSON")
	for ref in refs {
		if ref.agent_instance_id != "" {
			if same, same_err := agent_instance_same_chain(service, ref.agent_instance_id, chain); !same do return false, same_err
		}
		if ref.user_id != "" && ref.user_id != string(chain.owner_user_id) do return false, domain.domain_error(.Not_Found, "task actor ref not found")
	}
	return true, domain.Domain_Error{}
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

agent_instance_ref_json :: proc(instance_id: string) -> string { return strings.concatenate({`{"type":"agent_instance","agent_instance_id":"`, instance_id, `"}`}) }
user_ref_json :: proc(user_id: string) -> string { return strings.concatenate({`{"type":"user","user_id":"`, user_id, `"}`}) }

// normalize_actor_refs handles actor ref normalization.
// With Fleet Management (REQ-FLEET-DISPATCHER-1), tasks store declarative
// {"type":"agent_id","agent_id":"agt_..."} refs without requiring an instance upfront
// or failing if none exists. The reconcile engine acts as the dynamic fleet scheduler.
normalize_actor_refs :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, blob: string) -> (string, bool, domain.Domain_Error) {
	if blob == "" do return blob, true, domain.Domain_Error{}
	if !strings.contains(blob, "\"agent_id\"") do return blob, true, domain.Domain_Error{}
	_, _, ok := parse_actor_refs(blob, context.temp_allocator)
	if !ok do return blob, false, domain.domain_error(.Validation_Failed, "invalid actor ref JSON")
	return blob, true, domain.Domain_Error{}
}

primary_assignee_agent_id :: proc(assignee_ref_json: string) -> string {
	if assignee_ref_json == "" do return ""
	refs, _, ok := parse_actor_refs(assignee_ref_json, context.temp_allocator)
	if !ok do return ""
	for ref in refs {
		if ref.type == "agent_id" && ref.agent_id != "" {
			return strings.clone(ref.agent_id)
		}
	}
	return ""
}

collect_durable_actor_ids :: proc(ids: ^[dynamic]string, seen: ^map[string]bool, blob: string) {
	if blob == "" do return
	refs, _, ok := parse_actor_refs(blob, context.temp_allocator)
	if !ok do return
	for ref in refs {
		if ref.type == "agent_id" && ref.agent_id != "" {
			if !seen[ref.agent_id] {
				seen[ref.agent_id] = true
				append(ids, strings.clone(ref.agent_id))
			}
		}
	}
}

durable_actor_ids :: proc(task: domain.Task) -> [dynamic]string {
	ids := make([dynamic]string)
	seen := make(map[string]bool)
	defer delete(seen)
	collect_durable_actor_ids(&ids, &seen, task.assignee_ref_json)
	collect_durable_actor_ids(&ids, &seen, task.reviewer_refs_json)
	return ids
}

ensure_durable_actor_fleets :: proc(service: ^Taskchain_Service, task: domain.Task) -> domain.Domain_Error {
	ids := durable_actor_ids(task)
	defer { for id in ids do delete(id); delete(ids) }
	now := platform.clock_now(service.clock)
	for agent_id in ids {
		if service == nil || service.agents == nil do continue
		if _, ok, _ := iface.agent_get(service.agents, agent_id); !ok do continue
		fleet := domain.Task_Chain_Fleet{task_chain_id = task.chain_id, agent_id = agent_id, capacity = 1, min_warm = 0, idle_ttl_seconds = 600, created_at = now, updated_at = now}
		if err := iface.taskchain_ensure_fleet(service.repo, fleet); err.code != .None do return err
	}
	return domain.Domain_Error{}
}

extract_agent_ids_from_ref_blob :: proc(blob: string) -> [dynamic]string {
	agent_ids := make([dynamic]string)
	if blob == "" do return agent_ids
	refs, _, ok := parse_actor_refs(blob, context.temp_allocator)
	if !ok do return agent_ids
	for ref in refs {
		if ref.agent_id != "" {
			append(&agent_ids, strings.clone(ref.agent_id))
		}
	}
	return agent_ids
}

bind_agent_id_to_instance :: proc(blob: string, target_agent_id: string, instance_id: string) -> string {
	if blob == "" do return strings.clone(blob)
	refs, is_array, ok := parse_actor_refs(blob, context.temp_allocator)
	if !ok do return strings.clone(blob)
	replaced := false
	for &ref in refs {
		if ref.type == "agent_id" && ref.agent_id == target_agent_id {
			ref.type = "agent_instance"
			ref.agent_instance_id = instance_id
			ref.agent_id = ""
			replaced = true
			break
		}
	}
	if !replaced do return strings.clone(blob)
	out, marshal_ok := marshal_actor_refs(refs[:], is_array, context.allocator)
	if !marshal_ok do return strings.clone(blob)
	return out
}

// resolve_agent_id_instance finds a reusable instance of the durable agent_id for the
// chain owner. Prefers in-chain instances, then any owner-owned instance.
resolve_agent_id_instance :: proc(service: ^Taskchain_Service, chain: domain.Task_Chain, agent_id: string) -> (string, bool, domain.Domain_Error) {
	if service.agents == nil do return "", false, domain.domain_error(.Internal_Error, "agent repository is not configured")
	// 1) Prefer an instance already in this chain (coordinator or member).
	if chain.coordinator_agent_instance_id != "" {
		if inst, ok, _ := iface.agent_get_instance(service.agents, chain.coordinator_agent_instance_id); ok && inst.agent_id == agent_id {
			return inst.agent_instance_id, true, domain.Domain_Error{}
		}
	}
	if members, err := iface.taskchain_list_members_by_chain(service.repo, chain.chain_id, chain.owner_user_id); err.code == .None {
		for m in members {
			if m.agent_id == agent_id && m.agent_instance_id != "" do return m.agent_instance_id, true, domain.Domain_Error{}
		}
	}
	// 2) Any active instance of this agent_id owned by the chain owner.
	instances, list_err := iface.agent_list_instances_by_owner(service.agents, chain.owner_user_id, 1000, "")
	if list_err.code == .None {
		for inst in instances {
			if inst.agent_id != agent_id do continue
			if inst.runtime_status == "stopped" || inst.runtime_status == "failed" do continue
			return inst.agent_instance_id, true, domain.Domain_Error{}
		}
	}
	return "", false, domain.domain_error(.Not_Found, strings.concatenate({"no reusable instance found for agent_id '", agent_id, "'; launch one or add it to the chain"}))
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

Upsert_Fleet_Input :: struct {
	bridge_models_json: string,
	chain_id:         domain.Task_Chain_ID,
	agent_id:         string,
	capacity:         int,
	min_warm:         int,
	idle_ttl_seconds: int,
	provider:         string,
	model:             string,
}

list_fleets :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID) -> ([]domain.Task_Chain_Fleet, domain.Domain_Error) {
	chain, ok, err := get_chain_for_read(service, auth, chain_id)
	if !ok do return nil, err
	return iface.taskchain_list_fleets_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
}

list_chain_fleets :: list_fleets

upsert_fleet :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, input: Upsert_Fleet_Input) -> (domain.Task_Chain_Fleet, domain.Domain_Error) {
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

	bridge_models := input.bridge_models_json
	if bridge_models == "" {
		prior, prior_err := iface.taskchain_list_fleets_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
		if prior_err.code != .None do return {}, prior_err
		defer if prior_err.code == .None do delete(prior)
		for row in prior { if row.agent_id == trimmed_agent { bridge_models = row.bridge_models_json; break } }
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
		created_at       = now,
		updated_at       = now,
	}

	return iface.taskchain_upsert_fleet(service.repo, fleet)
}

upsert_chain_fleet :: upsert_fleet

delete_fleet :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, agent_id: string) -> (bool, domain.Domain_Error) {
	trimmed_agent := strings.trim_space(agent_id)
	if trimmed_agent == "" do return false, domain.domain_error(.Validation_Failed, "agent_id is required")
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return false, err

	deleted, del_err := iface.taskchain_delete_fleet(service.repo, chain.chain_id, trimmed_agent, chain.owner_user_id)
	if del_err.code != .None do return false, del_err
	if !deleted do return false, domain.domain_error(.Not_Found, "fleet not found")
	return true, domain.Domain_Error{}
}

delete_chain_fleet :: delete_fleet
remove_chain_fleet :: delete_fleet
