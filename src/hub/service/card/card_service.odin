package card

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"
import taskchain_service "odin_test:hub/service/taskchain"
import taskv2 "odin_test:hub/service/taskv2"
import jsonx "odin_test:lib/jsonx"
import content_service "odin_test:hub/service/content"
import project_service "odin_test:hub/service/project"
import agent_service "odin_test:hub/service/agent"
import issue_service "odin_test:hub/service/issue"

is_valid_json_array :: proc(s: string) -> bool {
	trimmed := strings.trim_space(s)
	if trimmed == "" do return false
	val, err := json.parse_string(trimmed)
	if err != .None do return false
	defer json.destroy_value(val)
	_, is_arr := val.(json.Array)
	return is_arr
}

is_valid_json_object :: proc(s: string) -> bool {
	trimmed := strings.trim_space(s)
	if trimmed == "" do return false
	val, err := json.parse_string(trimmed)
	if err != .None do return false
	defer json.destroy_value(val)
	_, is_obj := val.(json.Object)
	return is_obj
}

json_obj_string :: proc(obj: json.Object, key: string) -> string {
	v, ok := obj[key]
	if !ok do return ""
	s, is_str := v.(json.String)
	if is_str do return string(s)
	return ""
}

// op_has_arg: `key` is present (any JSON type) in the op's args or the op itself.
op_has_arg :: proc(obj: json.Object, key: string) -> bool {
	if args_val, has_args := obj["args"]; has_args {
		if args_obj, is_args_obj := args_val.(json.Object); is_args_obj {
			if _, ok := args_obj[key]; ok do return true
		}
	}
	_, ok := obj[key]
	return ok
}

op_arg_string :: proc(obj: json.Object, key: string) -> string {
	if args_val, has_args := obj["args"]; has_args {
		if args_obj, is_args_obj := args_val.(json.Object); is_args_obj {
			if v, ok := args_obj[key]; ok {
				if s, is_s := v.(json.String); is_s do return string(s)
			}
		}
	}
	if v, ok := obj[key]; ok {
		if s, is_s := v.(json.String); is_s do return string(s)
	}
	return ""
}

// op_arg_string_array mirrors op_arg_string's resolution order (args.<key> first,
// then top-level <key>) but for JSON arrays of strings. The returned bool is true
// only when the key is present AS AN ARRAY (even an empty one — meaning "set to the
// empty list" for a scope dimension); an absent key or a non-array value yields
// (nil, false). Non-string elements are silently skipped, matching json_array_present
// in the HTTP handler. The output slice uses context.temp_allocator.
op_arg_string_array :: proc(obj: json.Object, key: string) -> ([]string, bool) {
	lookup :: proc(o: json.Object, k: string) -> ([]string, bool) {
		v, ok := o[k]
		if !ok do return nil, false
		arr, is_arr := v.(json.Array)
		if !is_arr do return nil, false
		out := make([]string, len(arr), context.temp_allocator)
		for elem, i in arr {
			if s, is_s := elem.(json.String); is_s do out[i] = string(s)
		}
		return out, true
	}
	if args_val, has_args := obj["args"]; has_args {
		if args_obj, ok := args_val.(json.Object); ok {
			if vals, present := lookup(args_obj, key); present do return vals, true
		}
	}
	return lookup(obj, key)
}

// validate_card_operations enforces, at CREATE / UPDATE(operations) / ACCEPT time,
// that every operation is a KNOWN op type carrying its required args. It is the
// single source of truth for required fields and MUST stay in lockstep with the
// executor switch in accept_card. Arg resolution goes through op_arg_string (the
// SAME args.<key> / top-level <key> / id-alias resolution the executor uses) so a
// card that validates here will not false-fail there. Multiple ops and extra/unknown
// args are allowed; only missing REQUIRED args and unknown op NAMES are rejected.
// Returns (true, "") when every op is valid, else (false, "operation N (<op>): ...").
validate_card_operations :: proc(ops_json: string) -> (bool, string) {
	trimmed := strings.trim_space(ops_json)
	if trimmed == "" || trimmed == "[]" do return true, ""
	val, err := json.parse_string(trimmed)
	if err != .None do return false, "operations must be a valid JSON array"
	defer json.destroy_value(val)
	arr, is_arr := val.(json.Array)
	if !is_arr do return false, "operations must be a valid JSON array"
	for elem, idx in arr {
		op_obj, is_obj := elem.(json.Object)
		if !is_obj do return false, fmt.tprintf("operation %d: must be a JSON object", idx + 1)
		op_name := json_obj_string(op_obj, "op")
		if op_name == "" do return false, fmt.tprintf("operation %d: missing required field \"op\"", idx + 1)
		if ok, reason := validate_op_required_args(op_name, op_obj); !ok {
			return false, fmt.tprintf("operation %d (%s): %s", idx + 1, op_name, reason)
		}
	}
	return true, ""
}

// op_review_input reads a task.review op's optional verdict (approve |
// request_changes; default approve), summary and findings (a JSON array, inline
// or as a string). request_changes needs a summary, matching reject_card. Used
// by validate_op_required_args (create / update / accept) and the accept_card
// executor so both read the op the same way. findings_json uses temp_allocator.
op_review_input :: proc(op_obj: json.Object) -> (taskv2.Review_Input, bool, string) {
	input := taskv2.Review_Input{
		task_id       = op_arg_string(op_obj, "task_id"),
		verdict       = strings.trim_space(op_arg_string(op_obj, "verdict")),
		summary       = op_arg_string(op_obj, "summary"),
		findings_json = "[]",
	}
	if op_has_arg(op_obj, "verdict") && input.verdict == "" do return {}, false, "\"verdict\" must be \"approve\" or \"request_changes\""
	switch input.verdict {
	case "": input.verdict = "approve"
	case "approve", "request_changes":
	case: return {}, false, fmt.tprintf("unknown verdict %q (want \"approve\" or \"request_changes\")", input.verdict)
	}
	if input.verdict == "request_changes" && strings.trim_space(input.summary) == "" {
		return {}, false, "verdict \"request_changes\" requires a non-empty \"summary\" (say what needs to change)"
	}
	if op_has_arg(op_obj, "findings") {
		v: json.Value
		if args_obj, is_args := op_obj["args"].(json.Object); is_args {
			if av, present := args_obj["findings"]; present do v = av
		}
		if v == nil do v = op_obj["findings"]
		#partial switch f in v {
		case json.Array:
			data, merr := json.marshal(v, allocator = context.temp_allocator)
			if merr != nil do return {}, false, "\"findings\" could not be encoded"
			input.findings_json = string(data)
		case json.String:
			if strings.trim_space(string(f)) != "" {
				if !is_valid_json_array(string(f)) do return {}, false, "\"findings\" must be a JSON array"
				input.findings_json = string(f)
			}
		case json.Null:
		case:
			return {}, false, "\"findings\" must be a JSON array"
		}
	}
	return input, true, ""
}

op_field_missing :: proc(field: string) -> string { return fmt.tprintf("missing required field \"%s\"", field) }

// validate_op_required_args holds the per-op required-field rules. Every case here
// MUST correspond to a case in the accept_card executor switch (and vice versa); an
// unrecognized op name is rejected so unknown ops are caught at create, not accept.
validate_op_required_args :: proc(op_name: string, op_obj: json.Object) -> (bool, string) {
	switch op_name {
	case "task.review", "task.answer":
		if op_arg_string(op_obj, "task_id") == "" do return false, op_field_missing("task_id")
		if !op_has_arg(op_obj, "attempt_no") do return false, op_field_missing("attempt_no")
		if op_name == "task.review" {
			if _, ok, reason := op_review_input(op_obj); !ok do return false, reason
		}
	case "memory.approve", "memory.reject", "memory.update", "memory.delete", "memory.archive":
		if op_arg_string(op_obj, "memory_id") == "" && op_arg_string(op_obj, "id") == "" do return false, op_field_missing("memory_id")
	case "memory.create":
		if op_arg_string(op_obj, "title") == "" do return false, op_field_missing("title")
		if op_arg_string(op_obj, "body") == "" do return false, op_field_missing("body")
	case "issue.create":
		if op_arg_string(op_obj, "title") == "" do return false, op_field_missing("title")
	case "task_chain.set_status":
		if op_arg_string(op_obj, "chain_id") == "" && op_arg_string(op_obj, "id") == "" do return false, op_field_missing("chain_id")
		if op_arg_string(op_obj, "status") == "" do return false, op_field_missing("status")
	case "project.update":
		if op_arg_string(op_obj, "project_id") == "" && op_arg_string(op_obj, "id") == "" do return false, op_field_missing("project_id")
		if op_arg_string(op_obj, "name") == "" && op_arg_string(op_obj, "description") == "" do return false, "requires at least one of \"name\" or \"description\""
	case "project.delete":
		if op_arg_string(op_obj, "project_id") == "" && op_arg_string(op_obj, "id") == "" do return false, op_field_missing("project_id")
	case "agent.prompt":
		if op_arg_string(op_obj, "instance_id") == "" && op_arg_string(op_obj, "agent_instance_id") == "" do return false, op_field_missing("instance_id")
		if op_arg_string(op_obj, "prompt") == "" && op_arg_string(op_obj, "prompt_text") == "" && op_arg_string(op_obj, "body") == "" do return false, op_field_missing("prompt")
	case "agent.update":
		if op_arg_string(op_obj, "agent_id") == "" && op_arg_string(op_obj, "id") == "" do return false, op_field_missing("agent_id")
		if op_arg_string(op_obj, "name") == "" && op_arg_string(op_obj, "slug") == "" && op_arg_string(op_obj, "template_id") == "" && op_arg_string(op_obj, "instructions") == "" {
			return false, "requires at least one updatable field (name/slug/template_id/instructions)"
		}
	case "agent.delete":
		if op_arg_string(op_obj, "agent_id") == "" && op_arg_string(op_obj, "id") == "" do return false, op_field_missing("agent_id")
	case:
		return false, fmt.tprintf("unsupported card operation: %s", op_name)
	}
	return true, ""
}

chain_status_str :: proc(st: domain.Task_Chain_Status) -> string {
	switch st {
	case .Active: return "active"
	case .Completed: return "completed"
	case .Cancelled: return "cancelled"
	case .Archived: return "archived"
	}
	return "active"
}

Card_Input :: struct {
	project_id:       domain.Project_ID,
	title:            string,
	rationale:        string,
	scope:            string,
	provider:         string,
	confidence:       f32,
	source_refs_json: string,
	status:           string,
	operations_json:  string,
	guard_json:       string,
	snooze_until:     string,
	ttl_at:           string,
}

Card_Update_Input :: struct {
	title:            string,
	has_title:        bool,
	rationale:        string,
	has_rationale:    bool,
	scope:            string,
	has_scope:        bool,
	provider:         string,
	has_provider:     bool,
	confidence:       f32,
	has_confidence:   bool,
	source_refs_json: string,
	has_source_refs:  bool,
	status:           string,
	has_status:       bool,
	operations_json:  string,
	has_operations:   bool,
	guard_json:       string,
	has_guard:        bool,
	snooze_until:     string,
	has_snooze_until: bool,
	ttl_at:           string,
	has_ttl_at:       bool,
}

Card_Filter :: struct {
	status:     string,
	scope:      string,
	provider:   string,
	project_id: domain.Project_ID,
}

Card_Service :: struct {
	cards:       ^iface.Card_Repository,
	projects:    ^iface.Project_Repository,
	taskchains:  ^taskchain_service.Taskchain_Service,
	content:     ^content_service.Content_Service,
	project_svc: ^project_service.Project_Service,
	agents:      ^agent_service.Agent_Service,
	issues:      ^issue_service.Issue_Service,
	uow_factory: ^iface.Unit_Of_Work_Factory,
	clock:       ^platform.Clock,
	ids:         ^platform.ID_Generator,
	// Attention deck (card_projector.odin). Set by init_attention; when nil the
	// service keeps the legacy list-time task projection instead.
	attention_repo:     ^iface.Attention_Repository,
	attention_notifier: contracts.Attention_Notifier,
	projector_mutex:    sync.Mutex,
	card_changed:       Card_Changed_Hook,
}

new_card_service :: proc(
	cards:       ^iface.Card_Repository,
	projects:    ^iface.Project_Repository,
	taskchains:  ^taskchain_service.Taskchain_Service = nil,
	content:     ^content_service.Content_Service = nil,
	project_svc: ^project_service.Project_Service = nil,
	agents:      ^agent_service.Agent_Service = nil,
	uow_factory: ^iface.Unit_Of_Work_Factory = nil,
	clock:       ^platform.Clock = nil,
	ids:         ^platform.ID_Generator = nil,
	issues:      ^issue_service.Issue_Service = nil,
) -> Card_Service {
	return Card_Service{
		cards       = cards,
		projects    = projects,
		taskchains  = taskchains,
		content     = content,
		project_svc = project_svc,
		agents      = agents,
		issues      = issues,
		uow_factory = uow_factory,
		clock       = clock,
		ids         = ids,
	}
}

create_card :: proc(s: ^Card_Service, auth: contracts.Auth_Context, input: Card_Input) -> (domain.Card, bool, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return domain.Card{}, false, err

	title := strings.trim_space(input.title)
	if title == "" {
		return domain.Card{}, false, domain.domain_error(.Validation_Failed, "card title is required")
	}

	scope := input.scope
	if scope == "" do scope = domain.CARD_SCOPE_PROJECT

	status := input.status
	if status != domain.CARD_STATUS_SNOOZED {
		status = domain.CARD_STATUS_PENDING
	}

	confidence := input.confidence
	if confidence <= 0.0 do confidence = 1.0

	source_refs := input.source_refs_json
	if source_refs == "" {
		source_refs = "[]"
	} else if !is_valid_json_array(source_refs) {
		return domain.Card{}, false, domain.domain_error(.Validation_Failed, "source_refs must be a valid JSON array")
	}

	ops := input.operations_json
	if ops == "" {
		ops = "[]"
	} else if !is_valid_json_array(ops) {
		return domain.Card{}, false, domain.domain_error(.Validation_Failed, "operations must be a valid JSON array")
	}
	// Validate every operation carries its required args (and is a known op) up front,
	// so a card that would fail on accept is rejected at create with a clear message.
	if ops_ok, ops_reason := validate_card_operations(ops); !ops_ok {
		return domain.Card{}, false, domain.domain_error(.Validation_Failed, ops_reason)
	}

	guard := input.guard_json
	if guard == "" {
		guard = "{}"
	} else if !is_valid_json_object(guard) {
		return domain.Card{}, false, domain.domain_error(.Validation_Failed, "guard must be a valid JSON object")
	}

	now := platform.clock_now(s.clock)
	card_id := domain.Card_ID(platform.generate_id(s.ids, "crd_"))

	ttl_at := input.ttl_at
	if ttl_at == "" {
		if t, t_ok := platform.parse_rfc3339_utc(now); t_ok {
			ttl_at = platform.format_rfc3339_utc(time.time_add(t, 24 * time.Hour))
		} else {
			ttl_at = platform.expires_at_after_seconds(24 * 3600)
		}
	}

	card := domain.Card{
		card_id          = card_id,
		owner_user_id    = owner,
		project_id       = input.project_id,
		title            = title,
		rationale        = input.rationale,
		scope            = scope,
		provider         = input.provider,
		confidence       = confidence,
		source_refs_json = source_refs,
		status           = status,
		operations_json  = ops,
		guard_json       = guard,
		snooze_until     = input.snooze_until,
		ttl_at           = ttl_at,
		created_at       = now,
		updated_at       = now,
	}

	created, created_ok, created_err := iface.card_create(s.cards, card)
	return notify_written(s, created, created_ok, created_err)
}

sync_projected_cards :: proc(s: ^Card_Service, owner: domain.User_ID) {
	if s == nil || s.cards == nil do return
	now := platform.clock_now(s.clock)
	default_ttl := ""
	if t, t_ok := platform.parse_rfc3339_utc(now); t_ok {
		default_ttl = platform.format_rfc3339_utc(time.time_add(t, 24 * time.Hour))
	} else {
		default_ttl = platform.expires_at_after_seconds(24 * 3600)
	}

	// Task cards come only from the write-through projector (card_projector.odin,
	// taskv2.user_attention); there is no list-time task provider.

	// Memory-proposal deterministic provider. Superseded by the projector
	// (card_projector.odin) whenever that is wired.
	if s.attention_repo == nil && s.content != nil && s.content.content != nil {
		mems, merr := iface.content_list_memories(s.content.content, owner)
		if merr.code == .None {
			defer delete(mems)
			for m in mems {
				if m.status != "pending" do continue

				cid := domain.Card_ID(fmt.tprintf("crd_mem_%s", m.memory_id))
				existing, exists, _ := iface.card_get(s.cards, cid)
				if exists {
					if existing.status == domain.CARD_STATUS_SNOOZED {
						if existing.snooze_until != "" && existing.snooze_until <= now {
							_, _ = iface.card_update_status(s.cards, cid, domain.CARD_STATUS_PENDING, now)
						}
					}
					continue
				}

				m_title := m.title
				if m_title == "" do m_title = "memory proposal"
				title := fmt.tprintf("Review memory proposal: %s", m_title)
				rationale := m.description if m.description != "" else m.body
				pid: domain.Project_ID = ""
				if len(m.project_ids) > 0 do pid = m.project_ids[0]

				b_ops := strings.builder_make()
				strings.write_string(&b_ops, `[{"op":"memory.approve","label":"`)
				contracts.write_json_string(&b_ops, fmt.tprintf("Approve memory proposal: %s", m_title))
				strings.write_string(&b_ops, `","args":{"memory_id":"`)
				contracts.write_json_string(&b_ops, m.memory_id)
				strings.write_string(&b_ops, `"}}]`)

				b_guard := strings.builder_make()
				strings.write_string(&b_guard, `{"memory_proposal_id":"`)
				contracts.write_json_string(&b_guard, m.memory_id)
				strings.write_string(&b_guard, `","expected_status":"pending"}`)

				b_refs := strings.builder_make()
				strings.write_string(&b_refs, `[{"type":"memory","id":"`)
				contracts.write_json_string(&b_refs, m.memory_id)
				strings.write_string(&b_refs, `"}]`)

				card := domain.Card{
					card_id          = cid,
					owner_user_id    = owner,
					project_id       = pid,
					title            = title,
					rationale        = rationale,
					scope            = domain.CARD_SCOPE_MEMORY,
					provider         = domain.CARD_PROVIDER_MEMORY_PROPOSAL,
					confidence       = 1.0,
					source_refs_json = strings.to_string(b_refs),
					status           = domain.CARD_STATUS_PENDING,
					operations_json  = strings.to_string(b_ops),
					guard_json       = strings.to_string(b_guard),
					ttl_at           = default_ttl,
					created_at       = now,
					updated_at       = now,
				}
				_, _, _ = iface.card_create(s.cards, card)
			}
		}
	}
}

evaluate_guard :: proc(s: ^Card_Service, owner: domain.User_ID, card: domain.Card) -> (bool, string) {
	if s == nil do return true, ""
	now := platform.clock_now(s.clock)

	// TTL check
	if card.ttl_at != "" && card.ttl_at <= now {
		return false, "card TTL has expired"
	}

	trimmed_guard := strings.trim_space(card.guard_json)
	if trimmed_guard == "" || trimmed_guard == "{}" do return true, ""

	val, err := json.parse_string(trimmed_guard)
	if err != .None do return false, "invalid guard JSON"
	defer json.destroy_value(val)

	obj, is_obj := val.(json.Object)
	if !is_obj do return false, "guard must be a JSON object"

	task_id := json_obj_string(obj, "task_id")
	expected_status := json_obj_string(obj, "expected_status")

	if task_id != "" {
		if s.taskchains == nil || s.taskchains.repo == nil do return false, "task repository not configured"
		task, task_ok, _ := iface.taskchain_get_task(s.taskchains.repo, domain.Task_ID(task_id))
		if !task_ok || task.owner_user_id != owner {
			return false, "referenced task does not exist"
		}
		if expected_status != "" {
			actual_status := domain.task_state_string(task.state)
			if actual_status != expected_status {
				return false, fmt.tprintf("task state is %s, expected %s", actual_status, expected_status)
			}
		}
		// The card was computed for one attempt and one kind of attention (a
		// review or a block); a newer attempt or a different need makes it stale.
		if v, has := obj["expected_attempt"]; has {
			if n, is_num := v.(json.Float); is_num && int(n) != task.attempt_no {
				return false, fmt.tprintf("task is on attempt %d, the card was for attempt %d", task.attempt_no, int(n))
			} else if n, is_int := v.(json.Integer); is_int && int(n) != task.attempt_no {
				return false, fmt.tprintf("task is on attempt %d, the card was for attempt %d", task.attempt_no, int(n))
			}
		}
		// Consistency with the projector: a task card only belongs on the user's
		// feed while the task awaits the user (taskv2.user_attention).
		kind, _ := task_user_attention(s, task)
		if kind == .None do return false, "task no longer awaits you"
		if want := json_obj_string(obj, "expected_attention"); want != "" && want != ("review" if kind == .Review else "blocked") {
			return false, "task now needs something else from you"
		}
		if want := json_obj_string(obj, "expected_block"); want != "" && want != attention_block_id(task.blocked_on_json) {
			return false, "the task is blocked on something newer"
		}
	}

	mem_id := json_obj_string(obj, "memory_proposal_id")
	if mem_id == "" do mem_id = json_obj_string(obj, "memory_id")
	if mem_id != "" {
		if s.content == nil || s.content.content == nil do return false, "content repository not configured"
		mem, mem_ok, _ := iface.content_get_memory(s.content.content, mem_id)
		if !mem_ok || (mem.owner_user_id != "system" && mem.owner_user_id != owner) {
			return false, "referenced memory does not exist"
		}
		if expected_status != "" {
			if mem.status != expected_status {
				return false, fmt.tprintf("memory status is %s, expected %s", mem.status, expected_status)
			}
		}
	}

	chain_id := json_obj_string(obj, "chain_id")
	if chain_id != "" {
		if s.taskchains == nil || s.taskchains.repo == nil do return false, "taskchain repository not configured"
		chain, chain_ok, _ := iface.taskchain_get_chain(s.taskchains.repo, domain.Task_Chain_ID(chain_id))
		if !chain_ok || chain.owner_user_id != owner {
			return false, "referenced chain does not exist"
		}
		if expected_status != "" {
			actual_status := chain_status_str(chain.status)
			if actual_status != expected_status {
				return false, fmt.tprintf("chain status is %s, expected %s", actual_status, expected_status)
			}
		}
	}

	// Agent / project guards (for agent.update / agent.delete / project.delete cards).
	// A card whose target no longer exists, changed owner, or (via expected_state)
	// has already been archived is stale: it drops from list and accept returns 409.
	expected_state := json_obj_string(obj, "expected_state")
	guard_auth := contracts.Auth_Context{kind = .User_Token, user_id = string(owner)}

	agent_id := json_obj_string(obj, "agent_id")
	if agent_id != "" {
		if s.agents == nil do return false, "agent service not configured"
		agent, agent_ok, _ := agent_service.get_agent(s.agents, guard_auth, agent_id)
		if !agent_ok {
			return false, "referenced agent does not exist"
		}
		if expected_state != "" {
			actual_state := domain.agent_state_string(agent.state)
			if actual_state != expected_state {
				return false, fmt.tprintf("agent state is %s, expected %s", actual_state, expected_state)
			}
		}
	}

	guard_project_id := json_obj_string(obj, "project_id")
	if guard_project_id != "" {
		if s.project_svc == nil do return false, "project service not configured"
		project, project_ok, _ := project_service.get(s.project_svc, guard_auth, domain.Project_ID(guard_project_id))
		if !project_ok {
			return false, "referenced project does not exist"
		}
		if expected_state != "" {
			actual_state := domain.project_state_string(project.state)
			if actual_state != expected_state {
				return false, fmt.tprintf("project state is %s, expected %s", actual_state, expected_state)
			}
		}
	}

	return true, ""
}

get_card :: proc(s: ^Card_Service, auth: contracts.Auth_Context, id: domain.Card_ID) -> (domain.Card, bool, domain.Domain_Error) {
	owner, aok, aerr := ownership.owner_from_auth(auth)
	if !aok do return domain.Card{}, false, aerr

	c, ok, err := iface.card_get(s.cards, id)
	if !ok {
		id_str := string(id)
		if strings.has_prefix(id_str, "crd_task_") || strings.has_prefix(id_str, "crd_mem_") {
			sync_projected_cards(s, owner)
			c, ok, err = iface.card_get(s.cards, id)
			if !ok do return domain.Card{}, false, err
		} else {
			return domain.Card{}, false, err
		}
	}

	if ok2, e := ownership.require_owner(auth, c.owner_user_id); !ok2 {
		return domain.Card{}, false, e
	}
	return c, true, domain.Domain_Error{}
}

list_cards :: proc(s: ^Card_Service, auth: contracts.Auth_Context, filter: Card_Filter = {}, limit: int = 50) -> ([]domain.Card, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err

	sync_projected_cards(s, owner)

	all, list_err := iface.card_list(s.cards, owner)
	if list_err.code != .None do return nil, list_err
	defer delete(all)

	eff_limit := limit
	if eff_limit <= 0 do eff_limit = 50
	if eff_limit > 200 do eff_limit = 200

	filtered := make([dynamic]domain.Card, 0, len(all))
	defer delete(filtered)
	now := platform.clock_now(s.clock)

	for c in all {
		card := c
		if card.status == domain.CARD_STATUS_PENDING {
			guard_ok, _ := evaluate_guard(s, owner, card)
			if !guard_ok {
				// A failed guard is the system retiring a stale card, not the
				// user's decision: resolved, so a changed source can bring it back.
				_, _ = iface.card_update_status(s.cards, card.card_id, domain.CARD_STATUS_RESOLVED, now)
				card.status = domain.CARD_STATUS_RESOLVED
				notify_card_changed(s, owner, card.kind)
				continue
			}
		}

		if filter.status != "" && card.status != filter.status do continue
		if filter.scope != "" && card.scope != filter.scope do continue
		if filter.provider != "" && card.provider != filter.provider do continue
		if filter.project_id != "" && card.project_id != filter.project_id do continue
		append(&filtered, card)
	}

	count := len(filtered)
	if count > eff_limit do count = eff_limit

	out := make([]domain.Card, count)
	copy(out, filtered[:count])
	return out, domain.Domain_Error{}
}

list_cards_by_project :: proc(s: ^Card_Service, auth: contracts.Auth_Context, project_id: domain.Project_ID) -> ([]domain.Card, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err

	sync_projected_cards(s, owner)

	all, list_err := iface.card_list_by_project(s.cards, project_id)
	if list_err.code != .None do return nil, list_err
	defer delete(all)

	filtered := make([dynamic]domain.Card, 0, len(all))
	defer delete(filtered)
	now := platform.clock_now(s.clock)

	for c in all {
		if c.owner_user_id != owner do continue
		card := c
		if card.status == domain.CARD_STATUS_PENDING {
			guard_ok, _ := evaluate_guard(s, owner, card)
			if !guard_ok {
				_, _ = iface.card_update_status(s.cards, card.card_id, domain.CARD_STATUS_RESOLVED, now)
				notify_card_changed(s, owner, card.kind)
				continue
			}
		}
		append(&filtered, card)
	}
	out := make([]domain.Card, len(filtered))
	copy(out, filtered[:])
	return out, domain.Domain_Error{}
}

update_card_status :: proc(s: ^Card_Service, auth: contracts.Auth_Context, id: domain.Card_ID, status: string) -> (domain.Card, bool, domain.Domain_Error) {
	card, ok, err := get_card(s, auth, id)
	if !ok do return domain.Card{}, false, err

	now := platform.clock_now(s.clock)
	up_ok, up_err := iface.card_update_status(s.cards, id, status, now)
	if !up_ok do return domain.Card{}, false, up_err

	card.status = status
	card.updated_at = now
	notify_card_changed(s, card.owner_user_id, card.kind)
	return card, true, domain.Domain_Error{}
}

update_card :: proc(s: ^Card_Service, auth: contracts.Auth_Context, id: domain.Card_ID, input: Card_Update_Input) -> (domain.Card, bool, domain.Domain_Error) {
	card, ok, err := get_card(s, auth, id)
	if !ok do return domain.Card{}, false, err

	if input.has_title {
		t := strings.trim_space(input.title)
		if t == "" do return domain.Card{}, false, domain.domain_error(.Validation_Failed, "card title cannot be empty")
		card.title = t
	}
	if input.has_rationale do card.rationale = input.rationale
	if input.has_scope do card.scope = input.scope
	if input.has_provider do card.provider = input.provider
	if input.has_confidence do card.confidence = input.confidence
	if input.has_source_refs {
		if !is_valid_json_array(input.source_refs_json) {
			return domain.Card{}, false, domain.domain_error(.Validation_Failed, "source_refs must be a valid JSON array")
		}
		card.source_refs_json = input.source_refs_json
	}
	if input.has_status do card.status = input.status
	if input.has_operations {
		if !is_valid_json_array(input.operations_json) {
			return domain.Card{}, false, domain.domain_error(.Validation_Failed, "operations must be a valid JSON array")
		}
		if ops_ok, ops_reason := validate_card_operations(input.operations_json); !ops_ok {
			return domain.Card{}, false, domain.domain_error(.Validation_Failed, ops_reason)
		}
		card.operations_json = input.operations_json
	}
	if input.has_guard {
		if !is_valid_json_object(input.guard_json) {
			return domain.Card{}, false, domain.domain_error(.Validation_Failed, "guard must be a valid JSON object")
		}
		card.guard_json = input.guard_json
	}
	if input.has_snooze_until do card.snooze_until = input.snooze_until
	if input.has_ttl_at do card.ttl_at = input.ttl_at

	if input.has_provider do card.kind = domain.card_kind_for_provider(card.provider)
	now := platform.clock_now(s.clock)
	card.updated_at = now
	updated, updated_ok, updated_err := iface.card_update(s.cards, card)
	return notify_written(s, updated, updated_ok, updated_err)
}

discard_card :: proc(s: ^Card_Service, auth: contracts.Auth_Context, id: domain.Card_ID) -> (domain.Card, bool, domain.Domain_Error) {
	return update_card_status(s, auth, id, domain.CARD_STATUS_DISCARDED)
}

// Card_Decision carries the words that go with a decision on a task card: the
// note of an Answer (accept on a blocked card) and the summary / findings of a
// Request changes (reject on a review card). Other cards ignore it.
Card_Decision :: struct {
	note:          string,
	summary:       string,
	findings_json: string,
	// expected_block: the block the client showed the user (details.block_id).
	// The card row is re-projected server-side when the agent blocks again, so
	// only the client knows which question the user actually answered.
	expected_block: string,
}

// task_card_op: the op a task card advertises (task.review | task.answer), "" for
// a card from before Task System v2 (task.vote), which no longer executes.
task_card_op :: proc(card: domain.Card) -> string {
	if strings.contains(card.operations_json, `"op":"task.answer"`) do return "task.answer"
	if strings.contains(card.operations_json, `"op":"task.review"`) do return "task.review"
	return ""
}

// check_task_card_guard re-checks a task card against the live task; a stale
// card is retired to resolved and the caller gets a Conflict.
check_task_card_guard :: proc(s: ^Card_Service, card: domain.Card) -> (domain.Task, bool, domain.Domain_Error) {
	guard_ok, guard_reason := evaluate_guard(s, card.owner_user_id, card)
	if !guard_ok || task_card_op(card) == "" {
		if guard_ok do guard_reason = "the card predates Task System v2"
		now := platform.clock_now(s.clock)
		_, _ = iface.card_update_status(s.cards, card.card_id, domain.CARD_STATUS_RESOLVED, now)
		notify_card_changed(s, card.owner_user_id, card.kind)
		return domain.Task{}, false, domain.domain_error(.Conflict, fmt.tprintf("card precondition changed: %s", guard_reason))
	}
	task_id := jsonx.extract_string(card.guard_json, "task_id", "", true, context.temp_allocator)
	task, tok, terr := iface.taskchain_get_task(s.taskchains.repo, domain.Task_ID(task_id))
	if !tok do return domain.Task{}, false, terr
	return task, true, domain.Domain_Error{}
}

reject_card :: proc(s: ^Card_Service, auth: contracts.Auth_Context, id: domain.Card_ID, decision := Card_Decision{}) -> (domain.Card, bool, domain.Domain_Error) {
	card, ok, err := get_card(s, auth, id)
	if !ok do return domain.Card{}, false, err

	if card.status != domain.CARD_STATUS_PENDING && card.status != domain.CARD_STATUS_SNOOZED {
		return domain.Card{}, false, domain.domain_error(.Conflict, fmt.tprintf("card cannot be rejected in status '%s'", card.status))
	}

	user_auth := contracts.Auth_Context{
		kind    = .User_Token,
		user_id = string(card.owner_user_id),
	}

	// For provider cards, execute negative action:
	if card.provider == domain.CARD_PROVIDER_TASK_VALIDATION {
		// Reject on a review card is Request changes (a gate re-plans with the
		// summary); it runs through the same guard as Accept so a card from an
		// older attempt cannot request changes on a newer one. A blocked card is
		// answered (accept) or its task cancelled, never "rejected".
		task, tok, terr := check_task_card_guard(s, card)
		if !tok do return domain.Card{}, false, terr
		if task_card_op(card) != "task.review" do return domain.Card{}, false, domain.domain_error(.Conflict, "a blocked task is answered or cancelled, not rejected")
		if strings.trim_space(decision.summary) == "" do return domain.Card{}, false, domain.domain_error(.Validation_Failed, "say what needs to change")
		if s.taskchains == nil || s.taskchains.engine == nil do return domain.Card{}, false, domain.domain_error(.Internal_Error, "task engine is not configured")
		findings := decision.findings_json if strings.trim_space(decision.findings_json) != "" else "[]"
		_, rv_ok, rv_err := taskv2.user_review(s.taskchains.engine, user_auth, task.task_id, taskv2.Review_Input{task_id = string(task.task_id), verdict = "request_changes", summary = decision.summary, findings_json = findings})
		if !rv_ok do return domain.Card{}, false, rv_err
	} else if card.provider == domain.CARD_PROVIDER_MEMORY_PROPOSAL {
		mem_id := strings.trim_prefix(string(card.card_id), "crd_mem_")
		if s.content != nil {
			_, rej_ok, rej_err := content_service.reject_memory(s.content, user_auth, mem_id)
			if !rej_ok do return domain.Card{}, false, rej_err
		}
	}

	return update_card_status(s, auth, id, domain.CARD_STATUS_REJECTED)
}

accept_card :: proc(s: ^Card_Service, auth: contracts.Auth_Context, id: domain.Card_ID, decision := Card_Decision{}) -> (domain.Card, bool, domain.Domain_Error) {
	card, ok, err := get_card(s, auth, id)
	if !ok do return domain.Card{}, false, err

	if card.status != domain.CARD_STATUS_PENDING && card.status != domain.CARD_STATUS_SNOOZED {
		return domain.Card{}, false, domain.domain_error(.Conflict, fmt.tprintf("card cannot be accepted in status '%s'", card.status))
	}
	// A message card is answered (reply / mark read), never accepted: accepting
	// it would hide the question without the agent ever hearing back.
	if card.provider == domain.CARD_PROVIDER_MESSAGE_OPTIONS {
		return domain.Card{}, false, domain.domain_error(.Conflict, "message cards are answered by replying or marking the conversation read")
	}

	// Defense-in-depth: validate operations before doing any work (also guards rows
	// created before create-time validation existed).
	if ops_ok, ops_reason := validate_card_operations(card.operations_json); !ops_ok {
		return domain.Card{}, false, domain.domain_error(.Validation_Failed, ops_reason)
	}

	// Re-check guard against live state
	guard_ok, guard_reason := evaluate_guard(s, card.owner_user_id, card)
	if !guard_ok {
		now := platform.clock_now(s.clock)
		_, _ = iface.card_update_status(s.cards, card.card_id, domain.CARD_STATUS_RESOLVED, now)
		notify_card_changed(s, card.owner_user_id, card.kind)
		return domain.Card{}, false, domain.domain_error(.Conflict, fmt.tprintf("card precondition changed: %s", guard_reason))
	}

	trimmed_ops := strings.trim_space(card.operations_json)
	if trimmed_ops == "" || trimmed_ops == "[]" {
		return mark_card_accepted(s, card)
	}

	ops_val, ops_err := json.parse_string(trimmed_ops)
	if ops_err != .None {
		return domain.Card{}, false, domain.domain_error(.Validation_Failed, "invalid operations JSON")
	}
	defer json.destroy_value(ops_val)

	ops_arr, is_arr := ops_val.(json.Array)
	if !is_arr {
		return domain.Card{}, false, domain.domain_error(.Validation_Failed, "operations must be a JSON array")
	}

	has_uow := s.uow_factory != nil
	uow: iface.Unit_Of_Work
	if has_uow {
		var_uow, uow_ok, uow_err := iface.unit_of_work_begin(s.uow_factory)
		if !uow_ok do return domain.Card{}, false, uow_err
		uow = var_uow
	}

	user_auth := contracts.Auth_Context{
		kind    = .User_Token,
		user_id = string(card.owner_user_id),
	}

	for elem in ops_arr {
		op_obj, is_obj := elem.(json.Object)
		if !is_obj {
			if has_uow do iface.unit_of_work_rollback(&uow)
			return domain.Card{}, false, domain.domain_error(.Validation_Failed, "each operation must be a JSON object")
		}

		op_name := json_obj_string(op_obj, "op")

		switch op_name {
		case "task.review", "task.answer":
			// Task System v2: review posts the user's verdict; Answer clears the
			// block (the agent's question, a merge conflict, an exhausted budget).
			// The engine nests its unit of work inside this one.
			if s.taskchains == nil || s.taskchains.engine == nil {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, domain.domain_error(.Internal_Error, "task engine is not configured")
			}
			tid := domain.Task_ID(op_arg_string(op_obj, "task_id"))
			t_ok := false
			t_err: domain.Domain_Error
			if op_name == "task.review" {
				// args.verdict (default approve), args.summary and args.findings;
				// validate_card_operations already rejected a bad verdict above.
				review, r_ok, r_reason := op_review_input(op_obj)
				if !r_ok {
					t_err = domain.domain_error(.Validation_Failed, r_reason)
				} else {
					_, t_ok, t_err = taskv2.user_review(s.taskchains.engine, user_auth, tid, review)
				}
			} else {
				task, found, gerr := iface.taskchain_get_task(s.taskchains.repo, tid)
				if !found {
					t_err = gerr
				} else if decision.expected_block != "" && decision.expected_block != attention_block_id(task.blocked_on_json) {
					t_err = domain.domain_error(.Conflict, "the agent has asked something newer; reload the card")
				} else {
					_, t_ok, t_err = taskv2.task_answer(s.taskchains.engine, task, taskv2.actor_from_auth(user_auth), decision.note)
				}
			}
			if !t_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, t_err
			}

		case "memory.approve":
			mid := op_arg_string(op_obj, "memory_id")
			if mid == "" do mid = op_arg_string(op_obj, "id")
			if s.content == nil {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, domain.domain_error(.Internal_Error, "content service is not configured")
			}
			_, m_ok, m_err := content_service.approve_memory(s.content, user_auth, mid)
			if !m_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, m_err
			}

		case "memory.reject":
			mid := op_arg_string(op_obj, "memory_id")
			if mid == "" do mid = op_arg_string(op_obj, "id")
			if s.content == nil {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, domain.domain_error(.Internal_Error, "content service is not configured")
			}
			_, m_ok, m_err := content_service.reject_memory(s.content, user_auth, mid)
			if !m_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, m_err
			}

		case "memory.create":
			title := op_arg_string(op_obj, "title")
			body := op_arg_string(op_obj, "body")
			type_str := op_arg_string(op_obj, "type")
			description := op_arg_string(op_obj, "description")
			evidence := op_arg_string(op_obj, "evidence")
			typ := domain.memory_type_from_string(type_str)
			if typ == .Unknown do typ = .Fact
			if s.content == nil {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, domain.domain_error(.Internal_Error, "content service is not configured")
			}
			_, cr_ok, cr_err := content_service.create_memory(s.content, user_auth, content_service.Memory_Input{
				title       = title,
				body        = body,
				type        = typ,
				description = description,
				evidence    = evidence,
				status      = "active",
			})
			if !cr_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, cr_err
			}

		case "memory.delete", "memory.archive":
			mid := op_arg_string(op_obj, "memory_id")
			if mid == "" do mid = op_arg_string(op_obj, "id")
			if s.content == nil {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, domain.domain_error(.Internal_Error, "content service is not configured")
			}
			_, a_ok, a_err := content_service.archive_memory(s.content, user_auth, mid)
			if !a_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, a_err
			}

		case "memory.update":
			mid := op_arg_string(op_obj, "memory_id")
			if mid == "" do mid = op_arg_string(op_obj, "id")
			title := op_arg_string(op_obj, "title")
			body := op_arg_string(op_obj, "body")
			description := op_arg_string(op_obj, "description")
			evidence := op_arg_string(op_obj, "evidence")
			agent_ids, has_agent_ids := op_arg_string_array(op_obj, "agent_ids")
			bridge_ids, has_bridge_ids := op_arg_string_array(op_obj, "bridge_ids")
			template_ids, has_template_ids := op_arg_string_array(op_obj, "template_ids")
			project_id_strs, has_project_ids := op_arg_string_array(op_obj, "project_ids")
			project_ids := make([]domain.Project_ID, len(project_id_strs), context.temp_allocator)
			for str, i in project_id_strs do project_ids[i] = domain.Project_ID(str)
			if s.content == nil {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, domain.domain_error(.Internal_Error, "content service is not configured")
			}
			_, u_ok, u_err := content_service.update_memory(s.content, user_auth, mid, content_service.Memory_Update_Input{
				title            = title,
				has_title        = title != "",
				body             = body,
				has_body         = body != "",
				description      = description,
				has_description  = description != "",
				evidence         = evidence,
				has_evidence     = evidence != "",
				agent_ids        = agent_ids,
				has_agent_ids    = has_agent_ids,
				bridge_ids       = bridge_ids,
				has_bridge_ids   = has_bridge_ids,
				template_ids     = template_ids,
				has_template_ids = has_template_ids,
				project_ids      = project_ids,
				has_project_ids  = has_project_ids,
			})
			if !u_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, u_err
			}

		case "task_chain.set_status":
			cid := op_arg_string(op_obj, "chain_id")
			if cid == "" do cid = op_arg_string(op_obj, "id")
			st_str := op_arg_string(op_obj, "status")
			if s.taskchains == nil {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, domain.domain_error(.Internal_Error, "taskchain service is not configured")
			}
			st := taskchain_service.chain_status_from_string(st_str)
			_, ch_ok, ch_err := taskchain_service.change_chain_status(s.taskchains, user_auth, domain.Task_Chain_ID(cid), st)
			if !ch_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, ch_err
			}

		case "issue.create":
			title := op_arg_string(op_obj, "title")
			description := op_arg_string(op_obj, "description")
			scope := op_arg_string(op_obj, "scope")
			if scope == "" do scope = op_arg_string(op_obj, "scope_type")
			target_id := op_arg_string(op_obj, "target_id")
			chain_id := op_arg_string(op_obj, "chain_id")
			if s.issues == nil {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, domain.domain_error(.Internal_Error, "issue service is not configured")
			}
			_, cr_ok, cr_err := issue_service.create_issue(s.issues, user_auth, issue_service.Issue_Create_Input{
				title       = title,
				description = description,
				created_by  = string(card.owner_user_id),
				scope_type  = scope,
				target_id   = target_id,
				chain_id    = chain_id,
			})
			if !cr_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, cr_err
			}

		case "project.update":
			pid := op_arg_string(op_obj, "project_id")
			if pid == "" do pid = op_arg_string(op_obj, "id")
			name := op_arg_string(op_obj, "name")
			desc := op_arg_string(op_obj, "description")
			if s.project_svc == nil {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, domain.domain_error(.Internal_Error, "project service is not configured")
			}
			_, pr_ok, pr_err := project_service.update(s.project_svc, user_auth, domain.Project_ID(pid), project_service.Update_Project_Input{
				name        = name,
				description = desc,
			})
			if !pr_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, pr_err
			}

		case "agent.prompt":
			iid := op_arg_string(op_obj, "instance_id")
			if iid == "" do iid = op_arg_string(op_obj, "agent_instance_id")
			prompt := op_arg_string(op_obj, "prompt")
			if prompt == "" do prompt = op_arg_string(op_obj, "prompt_text")
			if prompt == "" do prompt = op_arg_string(op_obj, "body")
			if s.content == nil {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, domain.domain_error(.Internal_Error, "content service is not configured")
			}
			conv, conv_ok, conv_err := content_service.get_conversation_by_instance(s.content, user_auth, iid)
			if !conv_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, conv_err
			}
			_, snd_ok, snd_err := content_service.send_message(s.content, user_auth, conv.conversation_id, content_service.Message_Input{
				body         = prompt,
				message_type = "action",
			})
			if !snd_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, snd_err
			}

		case "agent.update":
			aid := op_arg_string(op_obj, "agent_id")
			if aid == "" do aid = op_arg_string(op_obj, "id")
			if s.agents == nil {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, domain.domain_error(.Internal_Error, "agent service is not configured")
			}
			name := op_arg_string(op_obj, "name")
			slug := op_arg_string(op_obj, "slug")
			template_id := op_arg_string(op_obj, "template_id")
			instructions := op_arg_string(op_obj, "instructions")
			_, au_ok, au_err := agent_service.update_agent(s.agents, user_auth, aid, agent_service.Create_Agent_Input{
				name                 = name,
				slug                 = slug,
				template_id          = template_id,
				has_template_id      = template_id != "",
				instructions         = instructions,
			})
			if !au_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, au_err
			}

		case "agent.delete":
			aid := op_arg_string(op_obj, "agent_id")
			if aid == "" do aid = op_arg_string(op_obj, "id")
			if s.agents == nil {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, domain.domain_error(.Internal_Error, "agent service is not configured")
			}
			// SOFT delete: archive_agent sets state=Archived (never removes the row).
			_, ad_ok, ad_err := agent_service.archive_agent(s.agents, user_auth, aid)
			if !ad_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, ad_err
			}

		case "project.delete":
			pid := op_arg_string(op_obj, "project_id")
			if pid == "" do pid = op_arg_string(op_obj, "id")
			if s.project_svc == nil {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, domain.domain_error(.Internal_Error, "project service is not configured")
			}
			// SOFT delete: archive_project sets state=Archived (never removes the row).
			_, pd_ok, pd_err := project_service.archive_project(s.project_svc, user_auth, domain.Project_ID(pid))
			if !pd_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, pd_err
			}

		case:
			if has_uow do iface.unit_of_work_rollback(&uow)
			return domain.Card{}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("unsupported card operation: %s", op_name))
		}
	}

	if has_uow {
		commit_ok, commit_err := iface.unit_of_work_commit(&uow)
		if !commit_ok do return domain.Card{}, false, commit_err
	}

	// Status-only write, re-read after: executing the ops usually changed the
	// card's source, and the projector may already have rewritten this row's
	// attention fields; the accept must not clobber them with the copy read
	// above. Writing accepted over a resolved row is intended -- this accept is
	// what made the source stop qualifying.
	return mark_card_accepted(s, card)
}

mark_card_accepted :: proc(s: ^Card_Service, card: domain.Card) -> (domain.Card, bool, domain.Domain_Error) {
	now := platform.clock_now(s.clock)
	if s.attention_repo == nil {
		up_ok, up_err := iface.card_update_status(s.cards, card.card_id, domain.CARD_STATUS_ACCEPTED, now)
		if !up_ok {
			if up_err.code == .None do return domain.Card{}, false, domain.domain_error(.Not_Found, "card not found")
			return domain.Card{}, false, up_err
		}
		saved, found, _ := iface.card_get(s.cards, card.card_id)
		if !found {
			saved = card
			saved.status = domain.CARD_STATUS_ACCEPTED
			saved.updated_at = now
		}
		notify_card_changed(s, saved.owner_user_id, saved.kind)
		return saved, true, domain.Domain_Error{}
	}
	// With the projector wired, accept is a compare-and-set against the source
	// marker the user acted on. If the source moved to a NEW state meanwhile
	// (e.g. the task re-entered validation for another round), the projector's
	// reactivated card stands: the user approved the old state, not the new one.
	// Same marker (including the common case where the projector just retired
	// the card because this accept's ops changed the source): accepted wins.
	for _ in 0 ..< ATTENTION_CAS_ATTEMPTS {
		fresh, found, _ := iface.card_get(s.cards, card.card_id)
		if !found do return domain.Card{}, false, domain.domain_error(.Not_Found, "card not found")
		if fresh.source_marker != card.source_marker do return fresh, true, domain.Domain_Error{}
		next := fresh
		next.status = domain.CARD_STATUS_ACCEPTED
		next.snooze_until = ""
		next.updated_at = now
		changed, err := iface.attention_card_compare_and_set(s.attention_repo, next, fresh.status, fresh.source_marker)
		if err.code != .None do return domain.Card{}, false, err
		if changed {
			notify_card_changed(s, next.owner_user_id, next.kind)
			return next, true, domain.Domain_Error{}
		}
	}
	return domain.Card{}, false, domain.domain_error(.Conflict, "card kept changing during accept")
}

// notify_written passes a card write's result through, telling the attention
// event about it when it succeeded. Every card write path funnels into
// notify_card_changed (here, the status/accept/delete paths, the projector and
// guard retirement), which drives the live attention_changed event.
notify_written :: proc(s: ^Card_Service, card: domain.Card, ok: bool, err: domain.Domain_Error) -> (domain.Card, bool, domain.Domain_Error) {
	if ok do notify_card_changed(s, card.owner_user_id, card.kind)
	return card, ok, err
}

snooze_card :: proc(s: ^Card_Service, auth: contracts.Auth_Context, id: domain.Card_ID, snooze_until: string) -> (domain.Card, bool, domain.Domain_Error) {
	card, ok, err := get_card(s, auth, id)
	if !ok do return domain.Card{}, false, err

	// Re-read immediately before the write so a concurrent projection's
	// attention fields are not overwritten with the copy read above.
	fresh, fresh_ok, _ := iface.card_get(s.cards, id)
	if fresh_ok do card = fresh
	now := platform.clock_now(s.clock)
	card.status = domain.CARD_STATUS_SNOOZED
	card.snooze_until = snooze_until
	card.updated_at = now
	updated, updated_ok, updated_err := iface.card_update(s.cards, card)
	return notify_written(s, updated, updated_ok, updated_err)
}

delete_card :: proc(s: ^Card_Service, auth: contracts.Auth_Context, id: domain.Card_ID) -> (bool, domain.Domain_Error) {
	card, ok, err := get_card(s, auth, id)
	if !ok do return false, err

	deleted, del_err := iface.card_delete(s.cards, id)
	if deleted do notify_card_changed(s, card.owner_user_id, card.kind)
	return deleted, del_err
}
