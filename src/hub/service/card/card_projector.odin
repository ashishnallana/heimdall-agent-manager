package card

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:mem/virtual"
import "core:sync"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import taskchain_service "odin_test:hub/service/taskchain"

// Attention card projector (attention deck v1).
//
// Action cards are the canonical envelope for what needs the user. This file
// keeps two kinds of source-backed card in step with their source, write-through:
//
//   task_validation  crd_task_<task_id>         a task awaiting the user's review
//   message_options  crd_msg_<agent_instance_id> the latest unread agent message
//                                                with reply options, per instance
//
// The taskchain and content services report writes through
// contracts.Attention_Notifier (see init_attention); a periodic reconciliation
// (reconcile_attention) repairs anything a notification missed.
//
// CONSISTENCY. A projection never trusts its caller: it takes only ids, re-reads
// the CURRENT source and computes the card from that. Projections are serialized
// by projector_mutex, and every write is a compare-and-set on the (status,
// source_marker) it read, retried after a re-read when the row moved. A late or
// out-of-order notification therefore always writes current state, and a card
// write that lands concurrently from outside the projector (accept, reject,
// snooze) is never silently overwritten. (A database transaction would not do
// this: the hub shares one SQLite connection across request threads.)
//
// PRECEDENCE, for a source that still qualifies:
//   - the user's own decision (accepted / rejected / discarded) stands while the
//     source_marker is unchanged; a CHANGED marker (new source state) reactivates;
//   - a snoozed card stays snoozed until its marker changes, then wakes early;
//   - a system-retired (resolved) card comes back.
// A source that stops qualifying retires a live (pending/snoozed) card to
// resolved and leaves a user-decided one alone, so accept can still write
// accepted over a resolved row it caused itself.

ATTENTION_TASK_CARD_PREFIX    :: "crd_task_"
ATTENTION_MESSAGE_CARD_PREFIX :: "crd_msg_"

// ATTENTION_CAS_ATTEMPTS bounds the re-read/recompute loop when the row keeps
// moving underneath (only possible under a write storm on one card).
ATTENTION_CAS_ATTEMPTS :: 4

// Card_Changed_Hook is told about every card write that can change what the
// attention deck shows (wired to the live attention_changed event).
Card_Changed_Hook :: struct {
	ctx:     rawptr,
	changed: proc(ctx: rawptr, owner_user_id: string, kind: string),
}

// init_attention wires the projector: it needs the attention repository and
// exposes s.attention_notifier for the source services to call.
init_attention :: proc(s: ^Card_Service, repo: ^iface.Attention_Repository) {
	if s == nil do return
	s.attention_repo = repo
	s.attention_notifier = contracts.Attention_Notifier{ctx = rawptr(s), notify = attention_notifier_proc}
}

attention_notifier_proc :: proc(ctx: rawptr, owner_user_id: string, source_kind: string, source_id: string) {
	s := (^Card_Service)(ctx)
	ok: bool
	err: domain.Domain_Error
	switch source_kind {
	case contracts.ATTENTION_SOURCE_TASK:
		ok, err = project_task_card(s, domain.User_ID(owner_user_id), domain.Task_ID(source_id))
	case contracts.ATTENTION_SOURCE_AGENT_MESSAGE:
		ok, err = project_message_card(s, domain.User_ID(owner_user_id), source_id)
	case:
		return
	}
	// Fire-and-forget by contract: log, and let reconciliation repair it.
	if !ok do fmt.eprintfln("ham-hub WARN attention projection failed kind=%s id=%s: %s", source_kind, source_id, err.message)
}

attention_task_card_id :: proc(task_id: domain.Task_ID) -> domain.Card_ID {
	return domain.Card_ID(fmt.tprintf("%s%s", ATTENTION_TASK_CARD_PREFIX, string(task_id)))
}

attention_message_card_id :: proc(agent_instance_id: string) -> domain.Card_ID {
	return domain.Card_ID(fmt.tprintf("%s%s", ATTENTION_MESSAGE_CARD_PREFIX, agent_instance_id))
}

// ---------------------------------------------------------------------------
// task_validation

// task_awaits_user is the single "this task needs the user's review" rule,
// shared with the accept-time guard: in validation, and the owning user is an
// explicit reviewer. It deliberately matches the vote authorization in
// taskchain.record_task_vote (task_requires_user_approval), so every card it
// projects can actually execute its advertised task.vote -- a task with no
// reviewer at all is not "awaiting the user" because the user cannot vote on it.
task_awaits_user :: proc(task: domain.Task) -> bool {
	return task.status == .In_Validation && taskchain_service.task_requires_user_approval(task)
}

project_task_card :: proc(s: ^Card_Service, owner: domain.User_ID, task_id: domain.Task_ID) -> (bool, domain.Domain_Error) {
	if s == nil || s.attention_repo == nil || s.cards == nil do return true, domain.Domain_Error{}
	if s.taskchains == nil || s.taskchains.repo == nil do return false, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	sync.mutex_lock(&s.projector_mutex)
	defer sync.mutex_unlock(&s.projector_mutex)

	task, found, get_err := iface.taskchain_get_task(s.taskchains.repo, task_id)
	// Only a definite "no such task" may retire a card; any other read failure
	// leaves the card untouched (reconciliation retries it).
	if !found && get_err.code != .Not_Found do return false, get_err
	qualifies := found && task.owner_user_id == owner && task_awaits_user(task)
	desired: domain.Card
	if qualifies do desired = build_task_card(s, task)
	return apply_attention_projection(s, owner, attention_task_card_id(task_id), desired, qualifies)
}

build_task_card :: proc(s: ^Card_Service, task: domain.Task) -> domain.Card {
	task_id := string(task.task_id)

	ops := strings.builder_make(context.temp_allocator)
	strings.write_string(&ops, `[{"op":"task.vote","label":"Approve","args":{"task_id":"`)
	contracts.write_json_string(&ops, task_id)
	strings.write_string(&ops, `","result":"lgtm"}}]`)

	guard := strings.builder_make(context.temp_allocator)
	strings.write_string(&guard, `{"task_id":"`)
	contracts.write_json_string(&guard, task_id)
	strings.write_string(&guard, `","expected_status":"in_validation"}`)

	refs := strings.builder_make(context.temp_allocator)
	strings.write_string(&refs, `[{"type":"task","id":"`)
	contracts.write_json_string(&refs, task_id)
	strings.write_string(&refs, `"}]`)

	action_refs := strings.builder_make(context.temp_allocator)
	strings.write_string(&action_refs, `{"chain_id":"`)
	contracts.write_json_string(&action_refs, string(task.chain_id))
	strings.write_string(&action_refs, `","task_id":"`)
	contracts.write_json_string(&action_refs, task_id)
	strings.write_string(&action_refs, `"}`)

	// details: what the deck renders. Vault ciphertext (comment body) is copied
	// verbatim; the client decrypts.
	details := strings.builder_make(context.temp_allocator)
	strings.write_string(&details, `{"priority":"`)
	contracts.write_json_string(&details, domain.task_priority_string(task.priority))
	strings.write_string(&details, `","status":"`)
	contracts.write_json_string(&details, task_status_str(task.status))
	strings.write_string(&details, `","bridge_id":"`)
	contracts.write_json_string(&details, task.bridge_id)
	strings.write_string(&details, `","assignee_name":"`)
	contracts.write_json_string(&details, attention_assignee_name(s, task))
	strings.write_string(&details, `","excerpt":`)
	comments, comments_err := iface.taskchain_list_recent_comments_by_task(s.taskchains.repo, task.task_id, task.owner_user_id, 1)
	if comments_err.code == .None && len(comments) > 0 {
		latest := comments[len(comments) - 1]
		strings.write_string(&details, `{"author_name":"`)
		contracts.write_json_string(&details, attention_instance_name(s, latest.author_agent_instance_id))
		strings.write_string(&details, `","body":"`)
		contracts.write_json_string(&details, latest.body)
		strings.write_string(&details, `","at":"`)
		contracts.write_json_string(&details, latest.created_at)
		strings.write_string(&details, `"}`)
	} else {
		strings.write_string(&details, `null`)
	}
	strings.write_string(&details, `}`)

	return domain.Card{
		owner_user_id    = task.owner_user_id,
		title            = task.title,
		rationale        = "Waiting on your review",
		scope            = domain.CARD_SCOPE_TASK,
		provider         = domain.CARD_PROVIDER_TASK_VALIDATION,
		kind             = domain.CARD_KIND_TASK,
		confidence       = 1.0,
		source_refs_json = strings.to_string(refs),
		operations_json  = strings.to_string(ops),
		guard_json       = strings.to_string(guard),
		action_refs_json = strings.to_string(action_refs),
		details_json     = strings.to_string(details),
		// User decision: a task's age is its updated_at.
		attention_since  = task.updated_at,
		source_marker    = fmt.tprintf("%s|%s", task_status_str(task.status), task.updated_at),
	}
}

attention_assignee_name :: proc(s: ^Card_Service, task: domain.Task) -> string {
	assignees := taskchain_service.extract_instances_from_ref_blob(task.assignee_ref_json)
	defer delete(assignees)
	if len(assignees) == 0 do return ""
	return attention_instance_name(s, assignees[0])
}

attention_instance_name :: proc(s: ^Card_Service, agent_instance_id: string) -> string {
	if agent_instance_id == "" || s.taskchains == nil || s.taskchains.agents == nil do return ""
	inst, ok, _ := iface.agent_get_instance(s.taskchains.agents, agent_instance_id)
	if !ok do return ""
	return inst.display_name
}

// ---------------------------------------------------------------------------
// message_options

project_message_card :: proc(s: ^Card_Service, owner: domain.User_ID, agent_instance_id: string) -> (bool, domain.Domain_Error) {
	if s == nil || s.attention_repo == nil || s.cards == nil do return true, domain.Domain_Error{}
	if agent_instance_id == "" do return true, domain.Domain_Error{}
	sync.mutex_lock(&s.projector_mutex)
	defer sync.mutex_unlock(&s.projector_mutex)

	msg, found, other_unread, err := iface.attention_latest_actionable_message(s.attention_repo, owner, agent_instance_id)
	if err.code != .None do return false, err
	desired: domain.Card
	if found do desired = build_message_card(s, msg, other_unread)
	return apply_attention_projection(s, owner, attention_message_card_id(agent_instance_id), desired, found)
}

build_message_card :: proc(s: ^Card_Service, msg: domain.Chat_Message, other_unread: int) -> domain.Card {
	refs := strings.builder_make(context.temp_allocator)
	strings.write_string(&refs, `[{"type":"message","id":"`)
	contracts.write_json_string(&refs, msg.message_id)
	strings.write_string(&refs, `"}]`)

	action_refs := strings.builder_make(context.temp_allocator)
	strings.write_string(&action_refs, `{"conversation_id":"`)
	contracts.write_json_string(&action_refs, msg.conversation_id)
	strings.write_string(&action_refs, `","agent_instance_id":"`)
	contracts.write_json_string(&action_refs, msg.sender_agent_instance_id)
	strings.write_string(&action_refs, `","message_id":"`)
	contracts.write_json_string(&action_refs, msg.message_id)
	strings.write_string(&action_refs, `"}`)

	details := strings.builder_make(context.temp_allocator)
	strings.write_string(&details, `{"excerpt":{"author_name":"`)
	contracts.write_json_string(&details, attention_instance_name(s, msg.sender_agent_instance_id))
	strings.write_string(&details, `","body":"`)
	contracts.write_json_string(&details, msg.body)
	strings.write_string(&details, `","at":"`)
	contracts.write_json_string(&details, msg.created_at)
	strings.write_string(&details, `"},"options":`)
	write_message_options(&details, msg.metadata_json)
	strings.write_string(&details, `,"other_unread":`)
	strings.write_int(&details, other_unread)
	strings.write_byte(&details, '}')

	return domain.Card{
		owner_user_id    = msg.owner_user_id,
		title            = msg.body,
		rationale        = "Waiting on your reply",
		scope            = domain.CARD_SCOPE_AGENT,
		provider         = domain.CARD_PROVIDER_MESSAGE_OPTIONS,
		kind             = domain.CARD_KIND_MESSAGE,
		confidence       = 1.0,
		source_refs_json = strings.to_string(refs),
		operations_json  = "[]",
		guard_json       = "{}",
		action_refs_json = strings.to_string(action_refs),
		details_json     = strings.to_string(details),
		attention_since  = msg.created_at,
		source_marker    = msg.message_id,
	}
}

// write_message_options copies metadata.options as a JSON array of strings.
// Non-string entries are skipped; the option text itself is plain UI text.
write_message_options :: proc(b: ^strings.Builder, metadata_json: string) {
	strings.write_byte(b, '[')
	defer strings.write_byte(b, ']')
	val, err := json.parse_string(metadata_json, allocator = context.temp_allocator)
	if err != .None do return
	obj, is_obj := val.(json.Object)
	if !is_obj do return
	arr, is_arr := obj["options"].(json.Array)
	if !is_arr do return
	n := 0
	for item in arr {
		text, is_str := item.(json.String)
		if !is_str do continue
		if n > 0 do strings.write_byte(b, ',')
		strings.write_byte(b, '"')
		contracts.write_json_string(b, string(text))
		strings.write_byte(b, '"')
		n += 1
	}
}

// ---------------------------------------------------------------------------
// shared write path

// apply_attention_projection reconciles the stored card cid with the source:
// desired is the card the current source implies (ignored when !qualifies).
// The caller holds projector_mutex.
apply_attention_projection :: proc(s: ^Card_Service, owner: domain.User_ID, cid: domain.Card_ID, desired: domain.Card, qualifies: bool) -> (bool, domain.Domain_Error) {
	for _ in 0 ..< ATTENTION_CAS_ATTEMPTS {
		now := platform.clock_now(s.clock)
		existing, exists, get_err := iface.card_get(s.cards, cid)
		if !exists && get_err.code != .Not_Found do return false, get_err
		if exists && existing.owner_user_id != owner {
			return false, domain.domain_error(.Forbidden, "attention card belongs to another owner")
		}
		if !exists {
			if !qualifies do return true, domain.Domain_Error{}
			card := desired
			card.card_id = cid
			card.owner_user_id = owner
			card.status = domain.CARD_STATUS_PENDING
			card.created_at = now
			card.updated_at = now
			inserted, err := iface.attention_card_insert_if_absent(s.attention_repo, card)
			if err.code != .None do return false, err
			if inserted {
				notify_card_changed(s, owner, card.kind)
				return true, domain.Domain_Error{}
			}
			continue // someone inserted it first: re-read and reconcile
		}
		next, write := next_attention_card_state(existing, desired, qualifies, now)
		if !write do return true, domain.Domain_Error{}
		changed, err := iface.attention_card_compare_and_set(s.attention_repo, next, existing.status, existing.source_marker)
		if err.code != .None do return false, err
		if changed {
			notify_card_changed(s, owner, next.kind)
			return true, domain.Domain_Error{}
		}
	}
	return false, domain.domain_error(.Conflict, "attention card kept changing during projection")
}

// next_attention_card_state applies the precedence rules (see the file header).
// write=false means the stored card already reflects the source.
next_attention_card_state :: proc(existing, desired: domain.Card, qualifies: bool, now: string) -> (domain.Card, bool) {
	if !qualifies {
		if existing.status != domain.CARD_STATUS_PENDING && existing.status != domain.CARD_STATUS_SNOOZED do return {}, false
		n := existing
		n.status = domain.CARD_STATUS_RESOLVED
		n.snooze_until = ""
		n.updated_at = now
		return n, true
	}

	n := desired
	n.card_id = existing.card_id
	n.owner_user_id = existing.owner_user_id
	n.project_id = existing.project_id
	n.created_at = existing.created_at
	n.ttl_at = "" // source-backed: the source decides its lifetime
	marker_changed := existing.source_marker != desired.source_marker
	switch existing.status {
	case domain.CARD_STATUS_SNOOZED:
		if marker_changed {
			n.status = domain.CARD_STATUS_PENDING
			n.snooze_until = ""
		} else {
			n.status = domain.CARD_STATUS_SNOOZED
			n.snooze_until = existing.snooze_until
		}
	case domain.CARD_STATUS_ACCEPTED, domain.CARD_STATUS_REJECTED, domain.CARD_STATUS_DISCARDED:
		n.status = domain.CARD_STATUS_PENDING if marker_changed else existing.status
	case:
		// pending stays pending; resolved (or anything unknown) comes back.
		n.status = domain.CARD_STATUS_PENDING
	}
	if !attention_card_differs(existing, n) do return {}, false
	n.updated_at = now
	return n, true
}

attention_card_differs :: proc(a, b: domain.Card) -> bool {
	return a.status != b.status || a.snooze_until != b.snooze_until || a.ttl_at != b.ttl_at ||
		a.title != b.title || a.rationale != b.rationale || a.scope != b.scope ||
		a.provider != b.provider || a.kind != b.kind ||
		a.source_refs_json != b.source_refs_json || a.operations_json != b.operations_json ||
		a.guard_json != b.guard_json || a.action_refs_json != b.action_refs_json ||
		a.details_json != b.details_json || a.attention_since != b.attention_since ||
		a.source_marker != b.source_marker
}

notify_card_changed :: proc(s: ^Card_Service, owner: domain.User_ID, kind: string) {
	if s == nil || s.card_changed.changed == nil do return
	s.card_changed.changed(s.card_changed.ctx, string(owner), kind)
}

// ---------------------------------------------------------------------------
// reconciliation

Attention_Reconcile_Stats :: struct {
	owners:    int,
	projected: int,
	failed:    int, // failed projections AND failed source/card queries
	// What failed last, for the reaper's log line. A string LITERAL plus the
	// error code only: the sweep frees its allocations per owner, so an error
	// message would dangle by the time the caller logs it.
	last_failure:      string,
	last_failure_code: domain.Error_Code,
}

// reconcile_attention re-projects, for every owner, each source that currently
// qualifies (creating missing cards) and each live card (retiring stale ones).
// Run at hub startup and periodically; it repairs any missed notification.
reconcile_attention :: proc(s: ^Card_Service) -> Attention_Reconcile_Stats {
	stats: Attention_Reconcile_Stats
	if s == nil || s.attention_repo == nil do return stats
	// The sweep makes many short-lived allocations on a long-lived thread. Give
	// it a private growing arena (as both allocator and temp allocator), reset
	// after each owner and destroyed at the end, so a sweep leaks nothing and
	// never frees memory that belongs to its caller's temp allocator.
	sweep_arena: virtual.Arena
	if virtual.arena_init_growing(&sweep_arena) != nil {
		stats.failed += 1
		stats.last_failure = "sweep arena"
		return stats
	}
	defer virtual.arena_destroy(&sweep_arena)
	context.allocator = virtual.arena_allocator(&sweep_arena)
	context.temp_allocator = context.allocator

	owners_tmp, err := iface.attention_list_owners(s.attention_repo)
	if err.code != .None {
		stats.failed += 1
		stats.last_failure = "list owners"
		stats.last_failure_code = err.code
		return stats
	}
	owners := make([]string, len(owners_tmp), runtime.heap_allocator())
	for o, i in owners_tmp do owners[i] = strings.clone(string(o), runtime.heap_allocator())
	defer {
		for o in owners do delete(o, runtime.heap_allocator())
		delete(owners, runtime.heap_allocator())
	}
	free_all(context.allocator)
	for owner in owners {
		stats.owners += 1
		reconcile_attention_owner(s, domain.User_ID(owner), &stats)
		free_all(context.allocator)
	}
	return stats
}

reconcile_attention_owner :: proc(s: ^Card_Service, owner: domain.User_ID, stats: ^Attention_Reconcile_Stats) {
	project_result :: proc(stats: ^Attention_Reconcile_Stats, ok: bool, err: domain.Domain_Error) {
		if ok {
			stats.projected += 1
		} else {
			stats.failed += 1
			stats.last_failure = "projection"
			stats.last_failure_code = err.code
		}
	}
	query_failed :: proc(stats: ^Attention_Reconcile_Stats, what: string, err: domain.Domain_Error) {
		stats.failed += 1
		stats.last_failure = what // always a literal at the call sites below
		stats.last_failure_code = err.code
	}

	task_ids, task_err := iface.attention_list_validation_task_ids(s.attention_repo, owner)
	if task_err.code != .None {
		query_failed(stats, "list validation tasks", task_err)
	} else {
		for id in task_ids {
			ok, err := project_task_card(s, owner, id)
			project_result(stats, ok, err)
		}
	}
	live_tasks, live_task_err := iface.attention_list_live_cards(s.attention_repo, owner, domain.CARD_PROVIDER_TASK_VALIDATION)
	if live_task_err.code != .None {
		query_failed(stats, "list live task cards", live_task_err)
	} else {
		for c in live_tasks {
			id := string(c.card_id)
			if !strings.has_prefix(id, ATTENTION_TASK_CARD_PREFIX) do continue
			ok, err := project_task_card(s, owner, domain.Task_ID(id[len(ATTENTION_TASK_CARD_PREFIX):]))
			project_result(stats, ok, err)
		}
	}

	instance_ids, inst_err := iface.attention_list_actionable_instance_ids(s.attention_repo, owner)
	if inst_err.code != .None {
		query_failed(stats, "list actionable instances", inst_err)
	} else {
		for id in instance_ids {
			ok, err := project_message_card(s, owner, id)
			project_result(stats, ok, err)
		}
	}
	live_msgs, live_msg_err := iface.attention_list_live_cards(s.attention_repo, owner, domain.CARD_PROVIDER_MESSAGE_OPTIONS)
	if live_msg_err.code != .None {
		query_failed(stats, "list live message cards", live_msg_err)
	} else {
		for c in live_msgs {
			id := string(c.card_id)
			if !strings.has_prefix(id, ATTENTION_MESSAGE_CARD_PREFIX) do continue
			ok, err := project_message_card(s, owner, id[len(ATTENTION_MESSAGE_CARD_PREFIX):])
			project_result(stats, ok, err)
		}
	}
}
