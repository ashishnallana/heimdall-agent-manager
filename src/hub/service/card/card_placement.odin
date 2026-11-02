package card

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskv2 "odin_test:hub/service/taskv2"

ATTENTION_PLACEMENT_CARD_PREFIX :: "crd_placement_"
CARD_PROVIDER_TASK_PLACEMENT :: domain.CARD_PROVIDER_TASK_PLACEMENT

attention_placement_card_id :: proc(task: domain.Task) -> domain.Card_ID {
	return domain.Card_ID(fmt.tprintf("%s%s_%d", ATTENTION_PLACEMENT_CARD_PREFIX, task.task_id, task.attempt_no))
}

// Called under projector_mutex with the same freshly read task as the ordinary
// attention projection. The separate ID preserves review/question/Start cards.
project_placement_card :: proc(s: ^Card_Service, owner: domain.User_ID, task_id: domain.Task_ID, task: domain.Task, found: bool) -> (bool, domain.Domain_Error) {
	if s.taskchains.engine == nil do return true, {}
	failures: []taskv2.Placement_Failure
	if found && task.owner_user_id == owner && !domain.task_state_is_terminal(task.state) {
		err: domain.Domain_Error
		failures, err = taskv2.placement_failures(s.taskchains.engine, task)
		if err.code != .None do return false, err
	}
	id := attention_placement_card_id(task)
	// Retire previous attempts as well as a resolved current attempt. Never
	// reactivate a user-dismissed observation until its marker changes.
	live, lerr := iface.attention_list_live_cards(s.attention_repo, owner, CARD_PROVIDER_TASK_PLACEMENT)
	if lerr.code != .None do return false, lerr
	for c in live {
		if attention_json_field(c.action_refs_json, "task_id") != string(task_id) do continue
		if !found || c.card_id != id || len(failures) == 0 {
			if ok, err := apply_attention_projection(s, owner, c.card_id, {}, false); !ok do return false, err
		}
	}
	if len(failures) == 0 do return true, {}
	desired, derr := build_placement_card(s, task, failures)
	if derr.code != .None do return false, derr
	return apply_attention_projection(s, owner, id, desired, true)
}

build_placement_card :: proc(s: ^Card_Service, task: domain.Task, failures: []taskv2.Placement_Failure) -> (domain.Card, domain.Domain_Error) {
	// Each target carries its own observation guard. The endpoint only accepts
	// typed recovery fields; no client-supplied generic card operation executes.
	Target :: struct {
		failure: taskv2.Placement_Failure,
		guard: taskv2.Placement_Recovery_Input,
		bridge_action: string,
		bridge_action_label: string,
		bridge_scope_label: string,
		identity_action: string,
		identity_action_label: string,
		identity_scope: string,
		fleet_configuration: bool,
		affected_task_ids: []string, // ready/review work potentially using the fleet row
	}
	chain_tasks, terr := iface.taskchain_list_tasks_by_chain(s.taskchains.repo, task.chain_id, task.owner_user_id)
	if terr.code != .None do return {}, terr
	fleets, ferr := iface.taskchain_list_fleets_by_chain(s.taskchains.repo, task.chain_id, task.owner_user_id)
	if ferr.code != .None do return {}, ferr
	targets := make([dynamic]Target, context.temp_allocator)
	for f in failures {
		worker := f.phase == "work"
		affected := make([dynamic]string, context.temp_allocator)
		if !worker {
			fleet, has_fleet := taskv2.fleet_row_for_agent(fleets, f.agent_id)
			worker_row := has_fleet && taskv2.fleet_row_has_role(fleet, domain.FLEET_ROLE_WORKER)
			for queued in chain_tasks {
				if queued.publish_state != .Published do continue
				uses_agent := worker_row && queued.state == .Ready && queued.bridge_id == "" && (taskv2.brief_assignee(queued.brief_json) == f.agent_id || taskv2.brief_assignee(queued.brief_json) == "")
				if queued.state == .In_Review {
					for pair in taskv2.required_review_pairs(queued, fleets, "") do if pair.agent_id == f.agent_id { uses_agent = true; break }
				}
				if uses_agent do append(&affected, string(queued.task_id))
			}
		}
		append(&targets, Target{
			failure = f,
			guard = taskv2.Placement_Recovery_Input{
				expected_attempt = task.attempt_no, phase = f.phase, agent_id = f.agent_id,
				role = f.role, fingerprint = f.fingerprint, configuration = f.configuration,
				expected_assignment = taskv2.brief_assignee(task.brief_json) if worker else f.agent_id,
				scope = "ticket" if worker else "chain_fleet",
			},
			bridge_action = "configure_coordinator" if f.source == "coordinator" else "change_bridge",
			bridge_action_label = "Configure coordinator" if f.source == "coordinator" else "Change bridge",
			bridge_scope_label = "This ticket" if worker else "All tickets using this fleet; existing leases keep their placement",
			identity_action = "change_assignee" if worker else ("change_reviewer" if f.role == taskv2.NAMED_REVIEW_ROLE else "configure_fleet"),
			identity_action_label = "Change assignee" if worker else ("Change reviewer" if f.role == taskv2.NAMED_REVIEW_ROLE else "Configure fleet role"),
			identity_scope = "ticket" if worker || f.role == taskv2.NAMED_REVIEW_ROLE else "chain_fleet",
			fleet_configuration = !worker && f.role != taskv2.NAMED_REVIEW_ROLE,
			affected_task_ids = affected[:],
		})
	}
	details, _ := json.marshal(struct {
		attention: string,
		attempt_no: int,
		targets: []Target,
	}{"placement", task.attempt_no, targets[:]}, allocator = context.temp_allocator)
	refs, _ := json.marshal(struct {chain_id: string, task_id: string, recovery_path: string}{
		string(task.chain_id), string(task.task_id), fmt.tprintf("/api/v1/tasks/%s/placement-recovery", task.task_id),
	}, allocator = context.temp_allocator)
	guard, _ := json.marshal(struct {task_id: string, expected_attempt: int, expected_placement: string}{
		string(task.task_id), task.attempt_no, string(details),
	}, allocator = context.temp_allocator)
	return domain.Card{
		owner_user_id = task.owner_user_id, title = task.title,
		rationale = "Worker or reviewer placement needs repair",
		scope = domain.CARD_SCOPE_TASK, provider = CARD_PROVIDER_TASK_PLACEMENT,
		kind = domain.CARD_KIND_TASK, confidence = 1,
		operations_json = "[]", source_refs_json = "[]",
		details_json = string(details), action_refs_json = string(refs), guard_json = string(guard),
		source_marker = string(details), attention_since = task.updated_at,
	}, {}
}

placement_card_guard :: proc(s: ^Card_Service, task: domain.Task, card: domain.Card) -> bool {
	if s.taskchains.engine == nil || domain.task_state_is_terminal(task.state) || card.card_id != attention_placement_card_id(task) do return false
	failures, err := taskv2.placement_failures(s.taskchains.engine, task)
	if err.code != .None || len(failures) == 0 do return false
	desired, derr := build_placement_card(s, task, failures)
	return derr.code == .None && desired.source_marker == card.source_marker
}

// Reconciliation parses the deterministic ID only to find its source task;
// action authority always comes from native recover_placement's fresh guards.
placement_task_id_from_card :: proc(id: domain.Card_ID) -> domain.Task_ID {
	raw := string(id)
	if !strings.has_prefix(raw, ATTENTION_PLACEMENT_CARD_PREFIX) do return ""
	rest := raw[len(ATTENTION_PLACEMENT_CARD_PREFIX):]
	last := strings.last_index_byte(rest, '_')
	if last < 1 do return ""
	if _, ok := strconv.parse_int(rest[last+1:]); !ok do return ""
	return domain.Task_ID(rest[:last])
}

recover_card_placement :: proc(s: ^Card_Service, auth: contracts.Auth_Context, id: domain.Card_ID, input: taskv2.Placement_Recovery_Input) -> (domain.Task, bool, domain.Domain_Error) {
	if !contracts.is_user_auth(auth) do return {}, false, domain.domain_error(.Forbidden, "only the owner may repair placement")
	c, found, err := get_card(s, auth, id)
	if !found do return {}, false, err
	if c.provider != CARD_PROVIDER_TASK_PLACEMENT do return {}, false, domain.domain_error(.Validation_Failed, "not a placement card")
	if s.taskchains == nil || s.taskchains.engine == nil do return {}, false, domain.domain_error(.Internal_Error, "task engine unavailable")
	tid := placement_task_id_from_card(id)
	if tid == "" do return {}, false, domain.domain_error(.Validation_Failed, "invalid placement card identity")
	if id != attention_placement_card_id(domain.Task{task_id = tid, attempt_no = input.expected_attempt}) {
		return {}, false, domain.domain_error(.Conflict, "placement card is for another attempt; refresh the card")
	}
	task, repaired, rerr := taskv2.recover_placement(s.taskchains.engine, auth, tid, input)
	// Conflicts also refresh the source-backed card for the next owner read.
	_, _ = project_task_card(s, c.owner_user_id, tid)
	return task, repaired, rerr
}
