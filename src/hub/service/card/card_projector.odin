package card

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:strings"
import "core:mem/virtual"
import "core:sync"
import contracts "odin_test:contracts"
import dbt "odin_test:hub/platform/dbtelemetry"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import taskchain_service "odin_test:hub/service/taskchain"
import taskv2 "odin_test:hub/service/taskv2"
import jsonx "odin_test:lib/jsonx"

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
// Same id the legacy list-time provider used, so reject_card's memory path
// (which strips this prefix) keeps working for projected cards.
ATTENTION_MEMORY_CARD_PREFIX  :: "crd_mem_"

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
	case contracts.ATTENTION_SOURCE_MEMORY:
		ok, err = project_memory_card(s, domain.User_ID(owner_user_id), source_id)
	case:
		return
	}
	// Fire-and-forget by contract: log, and let reconciliation repair it.
	if !ok do fmt.eprintfln("ham-hub WARN attention projection failed kind=%s id=%s: %s", source_kind, source_id, err.message)
}

attention_task_card_id :: proc(task_id: domain.Task_ID) -> domain.Card_ID {
	return domain.Card_ID(fmt.tprintf("%s%s", ATTENTION_TASK_CARD_PREFIX, string(task_id)))
}

attention_memory_card_id :: proc(memory_id: string) -> domain.Card_ID {
	return domain.Card_ID(fmt.tprintf("%s%s", ATTENTION_MEMORY_CARD_PREFIX, memory_id))
}

attention_message_card_id :: proc(agent_instance_id: string) -> domain.Card_ID {
	return domain.Card_ID(fmt.tprintf("%s%s", ATTENTION_MESSAGE_CARD_PREFIX, agent_instance_id))
}

// ---------------------------------------------------------------------------
// task_validation

task_user_attention :: proc(s: ^Card_Service, task: domain.Task) -> (taskv2.User_Attention, string) {
	if s == nil || s.taskchains == nil || s.taskchains.engine == nil do return .None, ""
	return taskv2.user_attention(s.taskchains.engine, task)
}

project_task_card :: proc(s: ^Card_Service, owner: domain.User_ID, task_id: domain.Task_ID) -> (bool, domain.Domain_Error) {
	if s == nil || s.attention_repo == nil || s.cards == nil do return true, domain.Domain_Error{}
	if s.taskchains == nil || s.taskchains.repo == nil do return false, domain.domain_error(.Internal_Error, "taskchain repository is not configured")
	lock_tok := dbt.timed_lock(&s.projector_mutex, .Projector)
	defer dbt.timed_unlock(&s.projector_mutex, .Projector, lock_tok)

	task, found, get_err := iface.taskchain_get_task(s.taskchains.repo, task_id)
	// Only a definite "no such task" may retire a card; any other read failure
	// leaves the card untouched (reconciliation retries it).
	if !found && get_err.code != .Not_Found do return false, get_err
	kind := taskv2.User_Attention.None
	badge := ""
	if found && task.owner_user_id == owner do kind, badge = task_user_attention(s, task)
	qualifies := kind != .None
	desired: domain.Card
	if qualifies do desired = build_task_card(s, task, kind, badge)
	return apply_attention_projection(s, owner, attention_task_card_id(task_id), desired, qualifies)
}

// build_task_card renders one task's attention card. A review card advertises
// task.review (approve; reject = request changes with a summary), a blocked
// card task.answer (accept with a note). The guard pins the state, the attempt
// and the attention kind, so a card from an older attempt or an earlier block
// cannot act on the task as it is now.
build_task_card :: proc(s: ^Card_Service, task: domain.Task, kind: taskv2.User_Attention, badge: string) -> domain.Card {
	task_id := string(task.task_id)
	state := domain.task_state_string(task.state)
	attention := "review" if kind == .Review else "blocked"

	ops := strings.builder_make(context.temp_allocator)
	if kind == .Review {
		strings.write_string(&ops, `[{"op":"task.review","label":"Approve","args":{"task_id":"`)
	} else if taskv2.is_agent_not_running_block(task.blocked_on_json) {
		strings.write_string(&ops, `[{"op":"agent.start","label":"Start agent","args":{"task_id":"`)
	} else {
		strings.write_string(&ops, `[{"op":"task.answer","label":"Answer","args":{"task_id":"`)
	}
	contracts.write_json_string(&ops, task_id)
	// (No fmt here: fmt reads `}}` as an escaped brace.)
	strings.write_string(&ops, `","attempt_no":`)
	strings.write_int(&ops, task.attempt_no)
	strings.write_string(&ops, `}}]`)

	guard := strings.builder_make(context.temp_allocator)
	strings.write_string(&guard, `{"task_id":"`)
	contracts.write_json_string(&guard, task_id)
	strings.write_string(&guard, `","expected_status":"`)
	contracts.write_json_string(&guard, state)
	strings.write_string(&guard, `","expected_attempt":`)
	strings.write_int(&guard, task.attempt_no)
	strings.write_string(&guard, `,"expected_attention":"`)
	strings.write_string(&guard, attention)
	if kind == .Blocked {
		// Pin WHICH block the card answers: a newer block in the same attempt
		// (the agent asks again) must not take the answer written for this one.
		strings.write_string(&guard, `","expected_block":"`)
		strings.write_string(&guard, attention_block_id(task.blocked_on_json))
	}
	strings.write_string(&guard, `"}`)

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

	holder := attention_task_holder(s, task)
	excerpt_author, excerpt_body, excerpt_at := attention_task_excerpt(s, task, kind, holder)

	// details: what the deck renders. Vault ciphertext is copied verbatim; the
	// client decrypts. `status` mirrors `state` for older clients.
	details := strings.builder_make(context.temp_allocator)
	strings.write_string(&details, `{"priority":"`)
	contracts.write_json_string(&details, domain.task_priority_string(task.priority))
	strings.write_string(&details, `","status":"`)
	contracts.write_json_string(&details, state)
	strings.write_string(&details, `","state":"`)
	contracts.write_json_string(&details, state)
	strings.write_string(&details, `","attention":"`)
	contracts.write_json_string(&details, attention)
	strings.write_string(&details, `","badge":"`)
	contracts.write_json_string(&details, badge)
	strings.write_string(&details, `","task_kind":"`)
	contracts.write_json_string(&details, domain.task_kind_string(task.kind))
	fmt.sbprintf(&details, `","attempt_no":%d,"block_id":"%s","bridge_id":"`, task.attempt_no, attention_block_id(task.blocked_on_json) if kind == .Blocked else "")
	contracts.write_json_string(&details, task.bridge_id)
	strings.write_string(&details, `","holder_instance_id":"`)
	contracts.write_json_string(&details, holder)
	strings.write_string(&details, `","assignee_name":"`)
	contracts.write_json_string(&details, attention_instance_name(s, holder))
	strings.write_string(&details, `","excerpt":`)
	if excerpt_body != "" {
		strings.write_string(&details, `{"author_name":"`)
		contracts.write_json_string(&details, excerpt_author)
		strings.write_string(&details, `","body":"`)
		contracts.write_json_string(&details, excerpt_body)
		strings.write_string(&details, `","at":"`)
		contracts.write_json_string(&details, excerpt_at)
		strings.write_string(&details, `"}`)
	} else {
		strings.write_string(&details, `null`)
	}
	if kind == .Review && s.taskchains.engine != nil {
		if handoff, ok := taskv2.get_facet(s.taskchains.engine, task, task.attempt_no, taskv2.FACET_HANDOFF); ok {
			if reason := jsonx.extract_string(handoff.body_json, "skip_verify_reason", "", true, context.temp_allocator); reason != "" {
				strings.write_string(&details, `,"skip_verify_reason":"`)
				contracts.write_json_string(&details, reason)
				strings.write_byte(&details, '"')
			}
		}
	}
	strings.write_string(&details, `}`)

	rationale := "Waiting on your review"
	switch {
	case kind == .Review && task.kind == .Gate: rationale = "Approve the plan to continue"
	case kind == .Blocked && badge == "merge_conflict": rationale = "Merge conflict needs you"
	case kind == .Blocked && badge == "budget_exhausted": rationale = "Out of attempts — needs you"
	case kind == .Blocked && badge == "oscillation": rationale = "Stuck in review rounds — needs you"
	case kind == .Blocked && badge == "agent_not_running": rationale = jsonx.extract_string(task.blocked_on_json, "reason", "Agent is not running", true, context.temp_allocator)
	case kind == .Blocked: rationale = "Agent is asking you"
	}

	return domain.Card{
		owner_user_id    = task.owner_user_id,
		title            = task.title,
		rationale        = rationale,
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
		// A new state, attention kind, block or attempt reactivates the card.
		source_marker    = fmt.tprintf("v2|%s|%s|%s|%d|%s", state, attention, task.blocked_on_json, task.attempt_no, task.updated_at),
	}
}

// attention_block_id identifies one block: a hash of the task's blocked_on
// JSON, which carries the block's since_ms, kind and reason.
attention_block_id :: proc(blocked_on_json: string) -> string {
	return fmt.tprintf("%08x", hash.fnv32a(transmute([]u8)blocked_on_json))
}

// attention_task_holder: the instance that worked the task — the live work
// lease holder, else the holder of the latest lease of any kind.
attention_task_holder :: proc(s: ^Card_Service, task: domain.Task) -> string {
	if s.taskchains == nil || s.taskchains.repo == nil do return ""
	leases, err := iface.taskchain_list_leases_by_task(s.taskchains.repo, task.task_id)
	if err.code != .None do return ""
	for l in leases do if l.kind == domain.LEASE_KIND_WORK && l.holder_instance_id != "" do return l.holder_instance_id
	if s.taskchains.engine == nil do return ""
	return taskv2.last_attempt_holder(s.taskchains.engine, task)
}

// attention_task_excerpt: what the card quotes. A review quotes the agent's
// submit summary (gate: the plan stage's output summary when the gate has none);
// a block quotes its reason (the agent's question, conflicting files). Falls
// back to the latest task comment.
attention_task_excerpt :: proc(s: ^Card_Service, task: domain.Task, kind: taskv2.User_Attention, holder: string) -> (author, body, at: string) {
	eng := s.taskchains.engine
	if kind == .Blocked {
		reason := jsonx.extract_string(task.blocked_on_json, "reason", "", true, context.temp_allocator)
		if reason == "merge_conflict" {
			// The block only says merge_conflict; the files and git's message are
			// on the latest merge_conflict event.
			reason = "The finished branch did not merge."
			if evs, eerr := iface.taskchain_list_events_by_task(s.taskchains.repo, task.task_id, task.owner_user_id); eerr.code == .None {
				for i := len(evs) - 1; i >= 0; i -= 1 {
					if evs[i].kind != taskv2.EV_MERGE_CONFLICT do continue
					if files := jsonx.extract_string(evs[i].payload_json, "files", "", true, context.temp_allocator); files != "" {
						reason = fmt.tprintf("The finished branch did not merge. Conflicting files: %s", files)
					}
					break
				}
			}
		}
		if reason != "" do return attention_instance_name(s, holder), reason, task.updated_at
	} else if eng != nil && task.kind == .Gate {
		if body, at, ok := attention_gate_plan_excerpt(s, task); ok do return "Plan", body, at
	} else if eng != nil {
		if f, ok := taskv2.get_facet(eng, task, task.attempt_no, taskv2.FACET_HANDOFF); ok {
			if sum := jsonx.extract_string(f.body_json, "summary", "", true, context.temp_allocator); sum != "" {
				return attention_instance_name(s, holder), sum, f.written_at
			}
		}
	}
	comments, comments_err := iface.taskchain_list_recent_comments_by_task(s.taskchains.repo, task.task_id, task.owner_user_id, 1)
	if comments_err.code == .None && len(comments) > 0 {
		latest := comments[len(comments) - 1]
		return attention_instance_name(s, latest.author_agent_instance_id), latest.body, latest.created_at
	}
	return "", "", ""
}

// attention_gate_plan_excerpt: what a plan gate asks the user to approve — the
// output of the stage just before it (the latest done task of the chain created
// before the gate with an output facet): a task_list renders as a numbered list
// of item titles/goals, anything else as its summary.
attention_gate_plan_excerpt :: proc(s: ^Card_Service, gate: domain.Task) -> (string, string, bool) {
	eng := s.taskchains.engine
	tasks, err := iface.taskchain_list_tasks_by_chain(s.taskchains.repo, gate.chain_id, gate.owner_user_id)
	if err.code != .None do return "", "", false
	best: domain.Task
	found := false
	for t in tasks {
		if t.kind == .Gate || t.state != .Done || t.created_at > gate.created_at do continue
		if found && t.updated_at <= best.updated_at do continue
		if _, ok := taskv2.get_facet(eng, t, t.attempt_no, taskv2.FACET_OUTPUT); !ok do continue
		best = t
		found = true
	}
	if !found do return "", "", false
	f, _ := taskv2.get_facet(eng, best, best.attempt_no, taskv2.FACET_OUTPUT)
	b := strings.builder_make(context.temp_allocator)
	if items_raw, has := jsonx.extract_raw_array(f.body_json, "tasks", true, context.temp_allocator); has {
		items := taskv2.jsonx_top_level_array_items(items_raw)
		fmt.sbprintf(&b, "%d task(s) planned:\n", len(items))
		for it, i in items {
			label := jsonx.extract_string(it, "title", "", true, context.temp_allocator)
			if label == "" do label = jsonx.extract_string(it, "goal", "", true, context.temp_allocator)
			fmt.sbprintf(&b, "%d. %s\n", i + 1, label)
		}
	} else {
		strings.write_string(&b, jsonx.extract_string(f.body_json, "summary", "", true, context.temp_allocator))
	}
	body := strings.trim_space(strings.to_string(b))
	if body == "" do return "", "", false
	return body, f.written_at, true
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
	lock_tok := dbt.timed_lock(&s.projector_mutex, .Projector)
	defer dbt.timed_unlock(&s.projector_mutex, .Projector, lock_tok)

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
// memory_proposal

// memory_awaits_user: a proposal still pending and not past its expiry.
memory_awaits_user :: proc(m: domain.Memory, now: string) -> bool {
	return m.status == "pending" && (m.expires_at == "" || m.expires_at > now)
}

project_memory_card :: proc(s: ^Card_Service, owner: domain.User_ID, memory_id: string) -> (bool, domain.Domain_Error) {
	if s == nil || s.attention_repo == nil || s.cards == nil do return true, domain.Domain_Error{}
	if memory_id == "" do return true, domain.Domain_Error{}
	if s.content == nil || s.content.content == nil do return false, domain.domain_error(.Internal_Error, "content repository is not configured")
	lock_tok := dbt.timed_lock(&s.projector_mutex, .Projector)
	defer dbt.timed_unlock(&s.projector_mutex, .Projector, lock_tok)

	m, found, get_err := iface.content_get_memory(s.content.content, memory_id)
	// As for tasks: only a definite "no such memory" may retire a card.
	if !found && get_err.code != .Not_Found do return false, get_err
	qualifies := found && m.owner_user_id == owner && memory_awaits_user(m, platform.clock_now(s.clock))
	desired: domain.Card
	if qualifies do desired = build_memory_card(s, m)
	return apply_attention_projection(s, owner, attention_memory_card_id(memory_id), desired, qualifies)
}

build_memory_card :: proc(s: ^Card_Service, m: domain.Memory) -> domain.Card {
	ops := strings.builder_make(context.temp_allocator)
	strings.write_string(&ops, `[{"op":"memory.approve","label":"Approve","args":{"memory_id":"`)
	contracts.write_json_string(&ops, m.memory_id)
	strings.write_string(&ops, `"}}]`)

	guard := strings.builder_make(context.temp_allocator)
	strings.write_string(&guard, `{"memory_proposal_id":"`)
	contracts.write_json_string(&guard, m.memory_id)
	strings.write_string(&guard, `","expected_status":"pending"}`)

	refs := strings.builder_make(context.temp_allocator)
	strings.write_string(&refs, `[{"type":"memory","id":"`)
	contracts.write_json_string(&refs, m.memory_id)
	strings.write_string(&refs, `"}]`)

	action_refs := strings.builder_make(context.temp_allocator)
	strings.write_string(&action_refs, `{"memory_id":"`)
	contracts.write_json_string(&action_refs, m.memory_id)
	strings.write_string(&action_refs, `","agent_instance_id":"`)
	contracts.write_json_string(&action_refs, m.proposed_by_instance_id)
	strings.write_string(&action_refs, `","chain_id":"`)
	contracts.write_json_string(&action_refs, m.proposed_in_chain_id)
	strings.write_string(&action_refs, `"}`)

	// details: what the deck renders. Title/description/body may be vault
	// ciphertext and are copied verbatim (the client decrypts); the scope lists
	// are ids, named at read time by the attention API.
	details := strings.builder_make(context.temp_allocator)
	strings.write_string(&details, `{"type":"`)
	contracts.write_json_string(&details, domain.memory_type_string(m.type))
	strings.write_string(&details, `","title":"`)
	contracts.write_json_string(&details, m.title)
	strings.write_string(&details, `","description":"`)
	contracts.write_json_string(&details, m.description)
	strings.write_string(&details, `","body":"`)
	contracts.write_json_string(&details, m.body)
	strings.write_string(&details, `","expires_at":"`)
	contracts.write_json_string(&details, m.expires_at)
	strings.write_string(&details, `","proposer_name":"`)
	contracts.write_json_string(&details, attention_instance_name(s, m.proposed_by_instance_id))
	strings.write_string(&details, `","agent_ids":`)
	write_json_string_list(&details, m.agent_ids)
	strings.write_string(&details, `,"project_ids":`)
	project_ids := make([]string, len(m.project_ids), context.temp_allocator)
	for p, i in m.project_ids do project_ids[i] = string(p)
	write_json_string_list(&details, project_ids)
	strings.write_string(&details, `,"bridge_ids":`)
	write_json_string_list(&details, m.bridge_ids)
	strings.write_string(&details, `,"template_ids":`)
	write_json_string_list(&details, m.template_ids)
	strings.write_byte(&details, '}')

	return domain.Card{
		owner_user_id    = m.owner_user_id,
		title            = m.title,
		rationale        = "Waiting on your approval",
		scope            = domain.CARD_SCOPE_MEMORY,
		provider         = domain.CARD_PROVIDER_MEMORY_PROPOSAL,
		kind             = domain.CARD_KIND_MEMORY,
		confidence       = 1.0,
		source_refs_json = strings.to_string(refs),
		operations_json  = strings.to_string(ops),
		guard_json       = strings.to_string(guard),
		action_refs_json = strings.to_string(action_refs),
		details_json     = strings.to_string(details),
		attention_since  = m.created_at,
		// An edit (updated_at) or a new expiry is a new state: it wakes a snooze
		// and re-opens a dismissed card, like a new review round on a task.
		source_marker    = fmt.tprintf("%s|%s|%s", m.status, m.updated_at, m.expires_at),
	}
}

write_json_string_list :: proc(b: ^strings.Builder, values: []string) {
	strings.write_byte(b, '[')
	n := 0
	for v in values {
		if v == "" do continue
		if n > 0 do strings.write_byte(b, ',')
		strings.write_byte(b, '"')
		contracts.write_json_string(b, v)
		strings.write_byte(b, '"')
		n += 1
	}
	strings.write_byte(b, ']')
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
	memory_ids, mem_err := iface.attention_list_pending_memory_ids(s.attention_repo, owner)
	if mem_err.code != .None {
		query_failed(stats, "list pending memories", mem_err)
	} else {
		for id in memory_ids {
			ok, err := project_memory_card(s, owner, id)
			project_result(stats, ok, err)
		}
	}
	// Also retires expired proposals (the expiry itself writes nothing).
	live_mems, live_mem_err := iface.attention_list_live_cards(s.attention_repo, owner, domain.CARD_PROVIDER_MEMORY_PROPOSAL)
	if live_mem_err.code != .None {
		query_failed(stats, "list live memory cards", live_mem_err)
	} else {
		for c in live_mems {
			id := string(c.card_id)
			if !strings.has_prefix(id, ATTENTION_MEMORY_CARD_PREFIX) do continue
			ok, err := project_memory_card(s, owner, id[len(ATTENTION_MEMORY_CARD_PREFIX):])
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
