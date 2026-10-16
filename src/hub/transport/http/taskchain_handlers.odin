package http

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import auth_service "odin_test:hub/service/auth"
import agent_service "odin_test:hub/service/agent"
import content_service "odin_test:hub/service/content"
import project_service "odin_test:hub/service/project"
import taskchain_service "odin_test:hub/service/taskchain"
import events "odin_test:hub/service/events"
import "core:encoding/json"
import jsonx "odin_test:lib/jsonx"

Taskchain_Handlers :: struct {
	auth: ^auth_service.Auth_Service,
	taskchains: ^taskchain_service.Taskchain_Service,
	agents: ^agent_service.Agent_Service,
	// content + projects power the project-grouped task-chains list (TC-API): a
	// chain has no project_id column, so its project is resolved via the
	// coordinator instance's conversation (content) and named via the project
	// service. Both may be nil in reduced test wirings; resolution degrades to the
	// "Unassigned" bucket when so.
	content: ^content_service.Content_Service,
	projects: ^project_service.Project_Service,
	event_bus: ^events.User_Event_Bus,
}

Task_Chain_Search_Document_Wire :: struct {
	revision: i64,
	operation: string,
	chain_id: string,
	project_id: string,
	status: string,
	updated_at: string,
	title: string,
	description: string,
}

Task_Chain_Search_Feed_Wire :: struct {
	snapshot_revision: i64,
	next_revision: i64,
	has_more: bool,
	documents: []Task_Chain_Search_Document_Wire,
}

// UI-BE-7: publish a lightweight resource_changed event to the owning user's
// live WebSocket clients so the browser can invalidate the smallest relevant
// RTK Query cache and update task/chain views without a manual refresh. These
// are fire-and-forget invalidation hints; the UI refetches authoritative state.
// event_bus may be nil in some test wirings, in which case publish is a no-op.
publish_chain_event :: proc(bus: ^events.User_Event_Bus, owner_user_id, chain_id, change: string) {
	if bus == nil || owner_user_id == "" do return
	summary := taskchain_resource_summary_json("chain_id", chain_id)
	defer delete(summary)
	events.publish_resource_changed(bus, owner_user_id, "task_chain", chain_id, change, summary)
}

publish_task_event :: proc(bus: ^events.User_Event_Bus, owner_user_id, task_id, chain_id, change: string) {
	if bus == nil || owner_user_id == "" do return
	summary := taskchain_task_summary_json(task_id, chain_id)
	defer delete(summary)
	events.publish_resource_changed(bus, owner_user_id, "task", task_id, change, summary)
}

publish_chain_changed :: proc(h: ^Taskchain_Handlers, owner_user_id, chain_id, change: string) {
	if h == nil do return
	publish_chain_event(h.event_bus, owner_user_id, chain_id, change)
}

publish_task_changed :: proc(h: ^Taskchain_Handlers, owner_user_id, task_id, chain_id, change: string) {
	if h == nil do return
	publish_task_event(h.event_bus, owner_user_id, task_id, chain_id, change)
}



// ------------------------------------------------ Wire Models & Helpers (REQ-P2-TASKCHAIN-HANDLERS)

JSON_MARSHAL_OPT :: json.Marshal_Options{
	sort_maps_by_key = true,
}

json_value_or_empty_object :: proc(raw: string) -> json.Value {
	trimmed := strings.trim_space(raw)
	if trimmed != "" {
		if val, err := json.parse_string(trimmed, json.DEFAULT_SPECIFICATION, false, context.temp_allocator); err == .None {
			#partial switch v in val {
			case json.Object:
				return v
			}
		}
	}
	return json.Object{}
}

json_value_or_empty_array :: proc(raw: string) -> json.Value {
	trimmed := strings.trim_space(raw)
	if trimmed != "" {
		if val, err := json.parse_string(trimmed, json.DEFAULT_SPECIFICATION, false, context.temp_allocator); err == .None {
			#partial switch v in val {
			case json.Array:
				return v
			}
		}
	}
	return json.Array{}
}

json_value_raw :: proc(raw: string) -> json.Value {
	trimmed := strings.trim_space(raw)
	if trimmed != "" {
		if val, err := json.parse_string(trimmed, json.DEFAULT_SPECIFICATION, false, context.temp_allocator); err == .None {
			return val
		}
	}
	return json.Object{}
}

Task_Chain_Wire :: struct {
	chain_id:                      string     `json:"chain_id"`,
	title:                         string     `json:"title"`,
	description:                   string     `json:"description"`,
	publish_state:                 string     `json:"publish_state"`,
	status:                        string     `json:"status"`,
	kind:                          string     `json:"kind"`,
	coordinator_agent_instance_id: string     `json:"coordinator_agent_instance_id"`,
	default_reviewer_refs:         json.Value `json:"default_reviewer_refs"`,
	created_at:                    string     `json:"created_at"`,
	updated_at:                    string     `json:"updated_at"`,
	is_pinned:                     bool       `json:"is_pinned"`,
	pinned_at:                     string     `json:"pinned_at"`,
}

Chain_List_Item_Wire :: struct {
	chain_id:                      string `json:"chain_id"`,
	title:                         string `json:"title"`,
	status:                        string `json:"status"`,
	updated_at:                    string `json:"updated_at"`,
	coordinator_agent_instance_id: string `json:"coordinator_agent_instance_id"`,
	project_id:                    string `json:"project_id"`,
	project_name:                  string `json:"project_name"`,
	task_count:                    int    `json:"task_count"`,
	completed_task_count:          int    `json:"completed_task_count"`,
	user_validation_count:         int    `json:"user_validation_count"`,
	is_pinned:                     bool   `json:"is_pinned"`,
	pinned_at:                     string `json:"pinned_at"`,
}

Chain_Project_Group_Wire :: struct {
	project_id:   string                 `json:"project_id"`,
	project_name: string                 `json:"project_name"`,
	chains:       []Chain_List_Item_Wire `json:"chains"`,
	chain_total:  int                    `json:"chain_total"`,
	has_more:     bool                   `json:"has_more"`,
	next_cursor:  string                 `json:"next_cursor"`,
}

Task_Subscription_Wire :: struct {
	subscription_id:              string `json:"subscription_id"`,
	owner_user_id:                string `json:"owner_user_id"`,
	subscriber_agent_instance_id: string `json:"subscriber_agent_instance_id"`,
	chain_id:                     string `json:"chain_id"`,
	task_id:                      string `json:"task_id"`,
	event_type:                   string `json:"event_type"`,
	created_at:                   string `json:"created_at"`,
}

Subscription_Removed_Wire :: struct {
	removed: bool `json:"removed"`,
}

Simple_Task_Wire :: struct {
	task_id:             string        `json:"task_id"`,
	chain_id:            string        `json:"chain_id"`,
	title:               string        `json:"title"`,
	description:         string        `json:"description"`,
	publish_state:       string        `json:"publish_state"`,
	status:              string        `json:"status"`,
	priority:            string        `json:"priority"`,
	bridge_id:           string        `json:"bridge_id"`,
	assignee_ref:        json.Value    `json:"assignee_ref"`,
	reviewer_refs:       json.Value    `json:"reviewer_refs"`,
	requires_user_approval: bool       `json:"requires_user_approval"`,
	unblocks_dependents: bool          `json:"unblocks_dependents"`,
	updated_at:          string        `json:"updated_at"`,
	requested_status:    Maybe(string) `json:"requested_status,omitempty"`,
	allowed_transitions: []string      `json:"allowed_transitions"`,
	next_states:         []string      `json:"next_states"`,
	allowed_actions:     []string      `json:"allowed_actions"`,
}

reviewer_refs_wire_value :: proc(t: domain.Task) -> json.Value {
	refs, _, ok := taskchain_service.parse_actor_refs(t.reviewer_refs_json, context.temp_allocator)
	if !ok do return json_value_or_empty_array("[]")
	for &ref in refs {
		if ref.type == "user" && ref.user_id == string(t.owner_user_id) {
			ref.username = ref.user_id
		}
	}
	encoded, err := json.marshal(refs[:], allocator = context.temp_allocator)
	if err != nil do return json_value_or_empty_array("[]")
	return json_value_or_empty_array(string(encoded))
}

Task_Vote_Wire :: struct {
	task_id:                    string `json:"task_id"`,
	reviewer_agent_instance_id: string `json:"reviewer_agent_instance_id"`,
	vote:                       string `json:"vote"`,
	comment:                    string `json:"comment"`,
	created_at:                 string `json:"created_at"`,
}

Task_Comment_Summary_Wire :: struct {
	count:                                 int    `json:"count"`,
	last_comment_at:                       string `json:"last_comment_at"`,
	last_comment_author_agent_instance_id: string `json:"last_comment_author_agent_instance_id"`,
	last_comment_preview:                  string `json:"last_comment_preview"`,
}

Task_Detail_Wire :: struct {
	task_id:             string                    `json:"task_id"`,
	chain_id:            string                    `json:"chain_id"`,
	title:               string                    `json:"title"`,
	description:         Maybe(string)             `json:"description,omitempty"`,
	publish_state:       string                    `json:"publish_state"`,
	status:              string                    `json:"status"`,
	priority:            string                    `json:"priority"`,
	bridge_id:           string                    `json:"bridge_id"`,
	assignee_ref:        json.Value                `json:"assignee_ref"`,
	reviewer_refs:       json.Value                `json:"reviewer_refs"`,
	requires_user_approval: bool                   `json:"requires_user_approval"`,
	blocked:             bool                      `json:"blocked"`,
	unblocks_dependents: bool                      `json:"unblocks_dependents"`,
	depends_on:          []string                  `json:"depends_on"`,
	comment_summary:     Task_Comment_Summary_Wire `json:"comment_summary"`,
	votes:               []Task_Vote_Wire          `json:"votes"`,
	created_at:          string                    `json:"created_at"`,
	updated_at:          string                    `json:"updated_at"`,
	allowed_transitions: []string                  `json:"allowed_transitions"`,
	next_states:         []string                  `json:"next_states"`,
	allowed_actions:     []string                  `json:"allowed_actions"`,
}

Task_FSM_Wire :: struct {
	allowed_transitions: []string `json:"allowed_transitions"`,
	next_states:         []string `json:"next_states"`,
	allowed_actions:     []string `json:"allowed_actions"`,
}

Task_Chain_Member_Wire :: struct {
	chain_id:          string `json:"chain_id"`,
	agent_instance_id: string `json:"agent_instance_id"`,
	agent_id:          string `json:"agent_id"`,
	role:              string `json:"role"`,
	display_name:      string `json:"display_name"`,
	runtime_status:    string `json:"runtime_status"`,
	activity_status:   string `json:"activity_status"`,
	created_at:        string `json:"created_at"`,
}

Task_Chain_Directory_Wire :: struct {
	directory_id: string     `json:"directory_id"`,
	path:         string     `json:"path"`,
	bridge_id:    string     `json:"bridge_id"`,
	vcs_kind:     string     `json:"vcs_kind"`,
	vcs:          json.Value `json:"vcs"`,
}

Fleet_Restart_Failure :: struct {
	instance_id: string `json:"instance_id"`,
	message:     string `json:"message"`,
}

Task_Chain_Fleet_Wire :: struct {
	bridge_models: map[string]domain.Fleet_Bridge_Model `json:"bridge_models"`,
	task_chain_id:          string                         `json:"task_chain_id"`,
	agent_id:               string                         `json:"agent_id"`,
	capacity:               int                            `json:"capacity"`,
	active_count:           int                            `json:"active_count"`,
	min_warm:               int                            `json:"min_warm"`,
	idle_ttl_seconds:       int                            `json:"idle_ttl_seconds"`,
	created_at:             string                         `json:"created_at"`,
	updated_at:             string                         `json:"updated_at"`,
	provider:               string                         `json:"provider"`,
	model:                   string                         `json:"model"`,
	restarted_instance_ids: Maybe([]string)                `json:"restarted_instance_ids,omitempty"`,
	restart_failures:       Maybe([]Fleet_Restart_Failure) `json:"restart_failures,omitempty"`,
}

Task_Comment_Wire :: struct {
	comment_id:               string `json:"comment_id"`,
	task_id:                  string `json:"task_id"`,
	chain_id:                 string `json:"chain_id"`,
	author_agent_instance_id: string `json:"author_agent_instance_id"`,
	author_display_name:      string `json:"author_display_name"`,
	author_user_id:           string `json:"author_user_id"`,
	body:                     string `json:"body"`,
	created_at:               string `json:"created_at"`,
}

Task_Comment_Response_Wire :: struct {
	comment_id:               string   `json:"comment_id"`,
	task_id:                  string   `json:"task_id"`,
	chain_id:                 string   `json:"chain_id"`,
	author_agent_instance_id: string   `json:"author_agent_instance_id"`,
	author_display_name:      string   `json:"author_display_name"`,
	author_user_id:           string   `json:"author_user_id"`,
	body:                     string   `json:"body"`,
	created_at:               string   `json:"created_at"`,
	notified:                 []string `json:"notified"`,
}

Task_Current_Task_Response_Wire :: struct {
	agent_instance_id: string `json:"agent_instance_id"`,
	current_task_id:   string `json:"current_task_id"`,
	current_task_role: string `json:"current_task_role"`,
}

Task_Nudge_Response_Wire :: struct {
	task_id:        string     `json:"task_id"`,
	nudge_id:       string     `json:"nudge_id"`,
	delivery_state: string     `json:"delivery_state"`,
	live_delivered: int        `json:"live_delivered"`,
	durable_queued: int        `json:"durable_queued"`,
	failed:         int        `json:"failed"`,
	target_role:    string     `json:"target_role"`,
	created_at:     string     `json:"created_at"`,
	targets:        json.Value `json:"targets"`,
}

Task_Summary_Wire :: struct {
	task_id:  string `json:"task_id"`,
	chain_id: string `json:"chain_id"`,
}

Task_Chain_Detail_Response_Wire :: struct {
	chain_id:                      string                      `json:"chain_id"`,
	title:                         string                      `json:"title"`,
	description:                   string                      `json:"description"`,
	publish_state:                 string                      `json:"publish_state"`,
	status:                        string                      `json:"status"`,
	kind:                          string                      `json:"kind"`,
	coordinator_agent_instance_id: string                      `json:"coordinator_agent_instance_id"`,
	default_reviewer_refs:         json.Value                  `json:"default_reviewer_refs"`,
	created_at:                    string                      `json:"created_at"`,
	updated_at:                    string                      `json:"updated_at"`,
	is_pinned:                     bool                        `json:"is_pinned"`,
	pinned_at:                     string                      `json:"pinned_at"`,
	members:                       []Task_Chain_Member_Wire    `json:"members"`,
	tasks:                         []Task_Detail_Wire          `json:"tasks"`,
	directories:                   []Task_Chain_Directory_Wire `json:"directories"`,
}

Agents_Live_Response_Wire :: struct {
	projects: []Agents_Live_Project `json:"projects"`,
}

make_chain_wire :: proc(c: domain.Task_Chain) -> Task_Chain_Wire {
	return Task_Chain_Wire{
		chain_id                      = string(c.chain_id),
		title                         = c.title,
		description                   = c.description,
		publish_state                 = publish_state_http(c.publish_state),
		status                        = chain_status_http(c.status),
		kind                          = c.kind,
		coordinator_agent_instance_id = c.coordinator_agent_instance_id,
		default_reviewer_refs         = json_value_or_empty_array(c.default_reviewer_refs_json),
		created_at                    = c.created_at,
		updated_at                    = c.updated_at,
		is_pinned                     = c.is_pinned,
		pinned_at                     = c.pinned_at,
	}
}

make_chain_list_item_wire :: proc(it: Chain_List_Item) -> Chain_List_Item_Wire {
	return Chain_List_Item_Wire{
		chain_id                      = it.chain_id,
		title                         = it.title,
		status                        = it.status,
		updated_at                    = it.updated_at,
		coordinator_agent_instance_id = it.coordinator_agent_instance_id,
		project_id                    = it.project_id,
		project_name                  = it.project_name,
		task_count                    = it.task_count,
		completed_task_count          = it.completed_task_count,
		user_validation_count         = it.user_validation_count,
		is_pinned                     = it.is_pinned,
		pinned_at                     = it.pinned_at,
	}
}

make_chain_project_group_wire :: proc(g: Chain_Project_Group) -> Chain_Project_Group_Wire {
	chains_wire := make([]Chain_List_Item_Wire, len(g.chains), context.temp_allocator)
	for it, i in g.chains {
		chains_wire[i] = make_chain_list_item_wire(it)
	}
	return Chain_Project_Group_Wire{
		project_id   = g.project_id,
		project_name = g.project_name,
		chains       = chains_wire,
		chain_total  = g.chain_total,
		has_more     = g.has_more,
		next_cursor  = g.next_cursor,
	}
}

make_chain_project_page_wire :: proc(p: Chain_Project_Page) -> Chain_Project_Group_Wire {
	chains_wire := make([]Chain_List_Item_Wire, len(p.chains), context.temp_allocator)
	for it, i in p.chains {
		chains_wire[i] = make_chain_list_item_wire(it)
	}
	return Chain_Project_Group_Wire{
		project_id   = p.project_id,
		project_name = p.project_name,
		chains       = chains_wire,
		chain_total  = p.chain_total,
		has_more     = p.has_more,
		next_cursor  = p.next_cursor,
	}
}

task_fsm_wire_slices :: proc(status: domain.Task_Status, allocator := context.temp_allocator) -> (transitions: []string, actions: []string) {
	trans := domain.task_allowed_transitions(status)
	acts := domain.task_allowed_actions(status)
	t_strings := make([]string, len(trans), allocator)
	for st, i in trans {
		t_strings[i] = task_status_http(st)
	}
	a_strings := make([]string, len(acts), allocator)
	for a, i in acts {
		a_strings[i] = a
	}
	return t_strings, a_strings
}

make_simple_task_wire :: proc(t: domain.Task, requested_status := "") -> Simple_Task_Wire {
	trans, acts := task_fsm_wire_slices(t.status, context.temp_allocator)
	req_status_maybe: Maybe(string) = nil
	if requested_status != "" && requested_status != task_status_http(t.status) {
		req_status_maybe = requested_status
	}
	return Simple_Task_Wire{
		task_id             = string(t.task_id),
		chain_id            = string(t.chain_id),
		title               = t.title,
		description         = t.description,
		publish_state       = publish_state_http(t.publish_state),
		status              = task_status_http(t.status),
		priority            = domain.task_priority_string(t.priority),
		bridge_id           = t.bridge_id,
		assignee_ref        = json_value_or_empty_object(t.assignee_ref_json),
		reviewer_refs       = reviewer_refs_wire_value(t),
		requires_user_approval = taskchain_service.task_requires_user_approval(t),
		unblocks_dependents = domain.task_status_unblocks_dependents(t.status),
		updated_at          = t.updated_at,
		requested_status    = req_status_maybe,
		allowed_transitions = trans,
		next_states         = trans,
		allowed_actions     = acts,
	}
}

make_task_detail_wire :: proc(h: ^Taskchain_Handlers, auth_ctx: contracts.Auth_Context, t: domain.Task, deps: []domain.Task_Dependency, include_description := true) -> Task_Detail_Wire {
	is_blocked := false
	dep_ids := make([dynamic]string, context.temp_allocator)
	for d in deps {
		if d.task_id == t.task_id {
			append(&dep_ids, string(d.depends_on_task_id))
			if parent, p_ok, _ := taskchain_service.get_task_for_read(h.taskchains, auth_ctx, d.depends_on_task_id); p_ok {
				if !domain.task_status_unblocks_dependents(parent.status) do is_blocked = true
			}
		}
	}

	comment_summary, _ := taskchain_service.task_comment_summary(h.taskchains, auth_ctx, t.task_id)
	votes, _ := taskchain_service.list_task_votes(h.taskchains, auth_ctx, t.task_id)
	defer delete(votes)

	votes_wire := make([]Task_Vote_Wire, len(votes), context.temp_allocator)
	for v, i in votes {
		votes_wire[i] = make_task_vote_wire(v)
	}

	summary_wire := make_task_comment_summary_wire(comment_summary)
	trans, acts := task_fsm_wire_slices(t.status, context.temp_allocator)

	desc_maybe: Maybe(string) = nil
	if include_description {
		desc_maybe = t.description
	}

	return Task_Detail_Wire{
		task_id             = string(t.task_id),
		chain_id            = string(t.chain_id),
		title               = t.title,
		description         = desc_maybe,
		publish_state       = publish_state_http(t.publish_state),
		status              = task_status_http(t.status),
		priority            = domain.task_priority_string(t.priority),
		bridge_id           = t.bridge_id,
		assignee_ref        = json_value_or_empty_object(t.assignee_ref_json),
		reviewer_refs       = reviewer_refs_wire_value(t),
		requires_user_approval = taskchain_service.task_requires_user_approval(t),
		blocked             = is_blocked,
		unblocks_dependents = domain.task_status_unblocks_dependents(t.status),
		depends_on          = dep_ids[:],
		comment_summary     = summary_wire,
		votes               = votes_wire,
		created_at          = t.created_at,
		updated_at          = t.updated_at,
		allowed_transitions = trans,
		next_states         = trans,
		allowed_actions     = acts,
	}
}

make_chain_member_wire :: proc(h: ^Taskchain_Handlers, auth: contracts.Auth_Context, m: domain.Task_Chain_Member) -> Task_Chain_Member_Wire {
	display_name := ""
	runtime_status := ""
	activity_status := ""
	if h != nil && h.agents != nil && strings.trim_space(m.agent_instance_id) != "" {
		if inst, inst_ok, _ := agent_service.get_instance(h.agents, auth, m.agent_instance_id); inst_ok {
			display_name = inst.display_name
			runtime_status = inst.runtime_status
			activity_status = inst.activity_status
		}
		if strings.trim_space(display_name) == "" && strings.trim_space(m.agent_id) != "" {
			if agent, agent_ok, _ := agent_service.get_agent(h.agents, auth, m.agent_id); agent_ok {
				display_name = agent.name
			}
		}
	}
	return Task_Chain_Member_Wire{
		chain_id          = string(m.chain_id),
		agent_instance_id = m.agent_instance_id,
		agent_id          = m.agent_id,
		role              = m.role,
		display_name      = display_name,
		runtime_status    = runtime_status,
		activity_status   = activity_status,
		created_at        = m.created_at,
	}
}

make_task_vote_wire :: proc(v: domain.Task_Vote) -> Task_Vote_Wire {
	return Task_Vote_Wire{
		task_id                    = string(v.task_id),
		reviewer_agent_instance_id = v.reviewer_agent_instance_id,
		vote                       = v.vote,
		comment                    = v.comment,
		created_at                 = v.created_at,
	}
}

make_task_comment_summary_wire :: proc(s: domain.Task_Comment_Summary) -> Task_Comment_Summary_Wire {
	return Task_Comment_Summary_Wire{
		count                                 = s.count,
		last_comment_at                       = s.last_comment_at,
		last_comment_author_agent_instance_id = s.last_comment_author,
		last_comment_preview                  = s.last_comment_preview,
	}
}

make_task_comment_wire :: proc(c: domain.Task_Comment, author_display_name: string) -> Task_Comment_Wire {
	return Task_Comment_Wire{
		comment_id               = c.comment_id,
		task_id                  = string(c.task_id),
		chain_id                 = string(c.chain_id),
		author_agent_instance_id = c.author_agent_instance_id,
		author_display_name      = author_display_name,
		author_user_id           = string(c.owner_user_id),
		body                     = c.body,
		created_at               = c.created_at,
	}
}

make_task_comment_response_wire :: proc(c: domain.Task_Comment, author_display_name: string, notified: []string) -> Task_Comment_Response_Wire {
	notified_slice := notified
	if notified_slice == nil {
		notified_slice = []string{}
	}
	return Task_Comment_Response_Wire{
		comment_id               = c.comment_id,
		task_id                  = string(c.task_id),
		chain_id                 = string(c.chain_id),
		author_agent_instance_id = c.author_agent_instance_id,
		author_display_name      = author_display_name,
		author_user_id           = string(c.owner_user_id),
		body                     = c.body,
		created_at               = c.created_at,
		notified                 = notified_slice,
	}
}

make_chain_directory_wire :: proc(dir: domain.Task_Chain_Directory) -> Task_Chain_Directory_Wire {
	return Task_Chain_Directory_Wire{
		directory_id = dir.directory_id,
		path         = dir.path,
		bridge_id    = dir.bridge_id,
		vcs_kind     = dir.vcs_kind,
		vcs          = json_value_or_empty_object(dir.vcs_info_json),
	}
}

make_chain_fleet_wire :: proc(
	f: domain.Task_Chain_Fleet,
	active_count: int = 0,
	restarted_instance_ids: ^[]string = nil,
	restart_failures: ^[]Fleet_Restart_Failure = nil,
) -> Task_Chain_Fleet_Wire {
	restarted_ids_maybe: Maybe([]string) = nil
	if restarted_instance_ids != nil {
		restarted_ids_maybe = restarted_instance_ids^
	}
	restart_failures_maybe: Maybe([]Fleet_Restart_Failure) = nil
	if restart_failures != nil {
		restart_failures_maybe = restart_failures^
	}
	bridge_models := make(map[string]domain.Fleet_Bridge_Model, context.temp_allocator)
	if f.bridge_models_json != "" { _ = json.unmarshal((transmute([]u8) f.bridge_models_json), &bridge_models, allocator = context.temp_allocator) }
	return Task_Chain_Fleet_Wire{
		bridge_models = bridge_models,
		task_chain_id          = string(f.task_chain_id),
		agent_id               = f.agent_id,
		capacity               = f.capacity,
		active_count           = active_count,
		min_warm               = f.min_warm,
		idle_ttl_seconds       = f.idle_ttl_seconds,
		created_at             = f.created_at,
		updated_at             = f.updated_at,
		provider               = f.provider,
		model                   = f.model,
		restarted_instance_ids = restarted_ids_maybe,
		restart_failures       = restart_failures_maybe,
	}
}

make_subscription_wire :: proc(s: domain.Task_Subscription) -> Task_Subscription_Wire {
	return Task_Subscription_Wire{
		subscription_id              = s.subscription_id,
		owner_user_id                = string(s.owner_user_id),
		subscriber_agent_instance_id = s.subscriber_agent_instance_id,
		chain_id                     = string(s.chain_id),
		task_id                      = string(s.task_id),
		event_type                   = s.event_type,
		created_at                   = s.created_at,
	}
}

make_chain_detail_response_wire :: proc(
	h: ^Taskchain_Handlers,
	auth_ctx: contracts.Auth_Context,
	chain: domain.Task_Chain,
	members: []domain.Task_Chain_Member,
	tasks: []domain.Task,
	deps: []domain.Task_Dependency,
	dirs: []domain.Task_Chain_Directory,
) -> Task_Chain_Detail_Response_Wire {
	members_wire := make([]Task_Chain_Member_Wire, len(members), context.temp_allocator)
	for m, i in members {
		members_wire[i] = make_chain_member_wire(h, auth_ctx, m)
	}

	tasks_wire := make([]Task_Detail_Wire, len(tasks), context.temp_allocator)
	for t, i in tasks {
		tasks_wire[i] = make_task_detail_wire(h, auth_ctx, t, deps, false)
	}

	dirs_wire := make([]Task_Chain_Directory_Wire, len(dirs), context.temp_allocator)
	for d, i in dirs {
		dirs_wire[i] = make_chain_directory_wire(d)
	}

	return Task_Chain_Detail_Response_Wire{
		chain_id                      = string(chain.chain_id),
		title                         = chain.title,
		description                   = chain.description,
		publish_state                 = publish_state_http(chain.publish_state),
		status                        = chain_status_http(chain.status),
		kind                          = chain.kind,
		coordinator_agent_instance_id = chain.coordinator_agent_instance_id,
		default_reviewer_refs         = json_value_or_empty_array(chain.default_reviewer_refs_json),
		created_at                    = chain.created_at,
		updated_at                    = chain.updated_at,
		is_pinned                     = chain.is_pinned,
		pinned_at                     = chain.pinned_at,
		members                       = members_wire,
		tasks                         = tasks_wire,
		directories                   = dirs_wire,
	}
}

publish_instance_current_task_changed :: proc(h: ^Taskchain_Handlers, owner_user_id, agent_instance_id, current_task_id, current_task_role: string) {
	if h == nil || h.event_bus == nil || owner_user_id == "" do return
	wire := Task_Current_Task_Response_Wire{
		agent_instance_id = agent_instance_id,
		current_task_id   = current_task_id,
		current_task_role = current_task_role,
	}
	data, _ := json.marshal(wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	events.publish_resource_changed(h.event_bus, owner_user_id, "agent_instance", agent_instance_id, "current_task_changed", string(data))
}

taskchain_resource_summary_json :: proc(key, value: string) -> string {
	obj := make(json.Object, context.temp_allocator)
	obj[key] = json.String(value)
	data, _ := json.marshal(obj, JSON_MARSHAL_OPT, allocator = context.allocator)
	return string(data)
}

taskchain_task_summary_json :: proc(task_id, chain_id: string) -> string {
	wire := Task_Summary_Wire{
		task_id  = task_id,
		chain_id = chain_id,
	}
	data, _ := json.marshal(wire, JSON_MARSHAL_OPT, allocator = context.allocator)
	return string(data)
}

// has_coordinated_by reports whether the query string carries a coordinated_by
// key (even empty), so an instance token can request "chains I coordinate" via
// ?coordinated_by (value defaults to the caller's own instance server-side).
has_coordinated_by :: proc(query: string) -> bool {
	parts := strings.split(query, "&"); defer delete(parts)
	for p in parts {
		if p == "coordinated_by" do return true
		if eq := strings.index_byte(p, '='); eq >= 0 && p[:eq] == "coordinated_by" do return true
	}
	return false
}

list_task_chains_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	// H9 R4: ?coordinated_by=<instance_id> returns the chains that agent instance
	// coordinates (single canonical source). An empty value with an instance token
	// defaults to the caller's own instance. Owner-scoped in the service.
	if has_coordinated_by(req.query) {
		coord_chains, coord_err := taskchain_service.list_chains_coordinated_by(h.taskchains, auth_ctx, query_value(req.query, "coordinated_by"))
		if coord_err.code != .None do return respond_error(coord_err, req.request_id)
		defer delete(coord_chains)
		wires := make([]Task_Chain_Wire, len(coord_chains), context.temp_allocator)
		for chain, i in coord_chains {
			wires[i] = make_chain_wire(chain)
		}
		data, _ := json.marshal(wires, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
		return respond_list(string(data), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
	}
	include_archived := query_bool(req.query, "include_archived", false) || (has_query_key(req.query, "project_id") && query_value(req.query, "project_id") != "") || (has_query_key(req.query, "status") && query_value(req.query, "status") == "archived")
	if query_bool(req.query, "pinned", false) || query_value(req.query, "pinned") == "1" {
		pinned_chains, pinned_err := taskchain_service.list_pinned_chains(h.taskchains, auth_ctx)
		if pinned_err.code != .None do return respond_error(pinned_err, req.request_id)
		defer delete(pinned_chains)
		items := enrich_chain_list_items(h, auth_ctx, pinned_chains, false, include_archived)
		defer delete(items)
		wires := make([]Chain_List_Item_Wire, len(items), context.temp_allocator)
		for it, i in items {
			wires[i] = make_chain_list_item_wire(it)
		}
		data, _ := json.marshal(wires, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
		return respond_success(string(data), req.request_id, auth_ctx_server_time(req))
	}
	// Default (no ?coordinated_by): the project-grouped task-chains list (TC-API).
	// Enrich every visible chain with its project (resolved via the coordinator
	// instance's conversation), then either page ONE project or group them ALL.
	chains, err := taskchain_service.list_chains(h.taskchains, auth_ctx)
	if err.code != .None do return respond_error(err, req.request_id)
	// ?has_tasks=1 (or true/yes) hides chains that carry no tasks yet — on real data
	// that is roughly half of them, and an empty chain has nothing to show.
	items := enrich_chain_list_items(h, auth_ctx, chains, query_bool(req.query, "has_tasks", false), include_archived)
	defer delete(items)

	// ?flat=1 or ?all=1 returns a flat JSON array of all visible chains without project grouping or preview caps.
	if query_bool(req.query, "flat", false) || query_bool(req.query, "all", false) {
		wires := make([]Chain_List_Item_Wire, len(items), context.temp_allocator)
		for it, i in items {
			wires[i] = make_chain_list_item_wire(it)
		}
		data, _ := json.marshal(wires, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
		return respond_success(string(data), req.request_id, auth_ctx_server_time(req))
	}

	// ?project_id=<id> (value may be empty for the Unassigned bucket) selects the
	// single-project, cursor-paginated view. Its absence returns the grouped view.
	if has_query_key(req.query, "project_id") {
		limit := query_int(req.query, "limit", TASK_CHAINS_PAGE_DEFAULT)
		if limit <= 0 do limit = TASK_CHAINS_PAGE_DEFAULT
		if limit > TASK_CHAINS_PAGE_MAX do limit = TASK_CHAINS_PAGE_MAX
		page := paginate_project_chains(items[:], query_value(req.query, "project_id"), limit, query_value(req.query, "cursor"))
		defer delete(page.chains)
		defer if page.next_cursor != "" do delete(page.next_cursor) // chain_cursor_encode alloc
		wire := make_chain_project_page_wire(page)
		data, _ := json.marshal(wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
		return respond_success(string(data), req.request_id, auth_ctx_server_time(req))
	}

	groups := group_chains_by_project(items[:], TASK_CHAINS_GROUP_PREVIEW_CAP)
	defer free_chain_project_groups(groups)
	wires := make([]Chain_Project_Group_Wire, len(groups), context.temp_allocator)
	for g, i in groups {
		wires[i] = make_chain_project_group_wire(g)
	}
	data, _ := json.marshal(wires, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	return respond_success(string(data), req.request_id, auth_ctx_server_time(req))
}

// Bridge-only ciphertext document feed. The Hub returns the canonical encrypted
// title/description bytes and revision metadata; only the unsealed Bridge turns
// them into the ephemeral plaintext FTS index.
task_chain_search_documents_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_or_bridge_token(h.auth, req)
	if !ok do return auth_resp
	if auth_ctx.kind != .Bridge_Token {
		return respond_error(domain.domain_error(.Forbidden, "bridge authentication is required"), req.request_id)
	}

	after_revision := i64(query_int(req.query, "after_revision", 0))
	if after_revision < 0 do return respond_error(domain.domain_error(.Validation_Failed, "after_revision must be non-negative"), req.request_id)
	limit := query_int(req.query, "limit", 100)
	if limit <= 0 do limit = 100
	if limit > 500 do limit = 500

	snapshot_revision, revision_err := taskchain_service.search_feed_revision(h.taskchains, auth_ctx)
	if revision_err.code != .None do return respond_error(revision_err, req.request_id)

	documents := make([dynamic]Task_Chain_Search_Document_Wire)
	defer delete(documents)
	if after_revision == 0 {
		chains, chains_err := taskchain_service.list_chains(h.taskchains, auth_ctx)
		if chains_err.code != .None do return respond_error(chains_err, req.request_id)
		defer delete(chains)
		items := enrich_chain_list_items(h, auth_ctx, chains, false, true)
		defer delete(items)
		project_by_chain := make(map[string]string)
		defer delete(project_by_chain)
		for item in items do project_by_chain[item.chain_id] = item.project_id
		for chain in chains {
			append(&documents, Task_Chain_Search_Document_Wire{
				revision = snapshot_revision,
				operation = "upsert",
				chain_id = string(chain.chain_id),
				project_id = project_by_chain[string(chain.chain_id)] or_else "",
				status = chain_status_http(chain.status),
				updated_at = chain.updated_at,
				title = chain.title,
				description = chain.description,
			})
		}
		wire := Task_Chain_Search_Feed_Wire{snapshot_revision = snapshot_revision, next_revision = snapshot_revision, has_more = false, documents = documents[:]}
		data, _ := json.marshal(wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
		return respond_success(string(data), req.request_id, auth_ctx_server_time(req))
	}

	changes, changes_err := taskchain_service.search_feed_changes(h.taskchains, auth_ctx, after_revision, limit)
	if changes_err.code != .None do return respond_error(changes_err, req.request_id)
	defer delete(changes)
	upsert_chains := make([dynamic]domain.Task_Chain)
	defer delete(upsert_chains)
	chain_by_id := make(map[string]domain.Task_Chain)
	defer delete(chain_by_id)
	for change in changes {
		if change.operation != "upsert" do continue
		chain, found, _ := taskchain_service.get_chain(h.taskchains, auth_ctx, change.chain_id)
		if found {
			append(&upsert_chains, chain)
			chain_by_id[string(change.chain_id)] = chain
		}
	}
	items := enrich_chain_list_items(h, auth_ctx, upsert_chains[:], false, true)
	defer delete(items)
	project_by_chain := make(map[string]string)
	defer delete(project_by_chain)
	for item in items do project_by_chain[item.chain_id] = item.project_id

	next_revision := after_revision
	for change in changes {
		if change.revision > next_revision do next_revision = change.revision
		chain, found := chain_by_id[string(change.chain_id)]
		operation := change.operation
		if operation == "upsert" && !found do operation = "delete"
		doc := Task_Chain_Search_Document_Wire{
			revision = change.revision,
			operation = operation,
			chain_id = string(change.chain_id),
		}
		if operation == "upsert" {
			doc.project_id = project_by_chain[string(change.chain_id)] or_else ""
			doc.status = chain_status_http(chain.status)
			doc.updated_at = chain.updated_at
			doc.title = chain.title
			doc.description = chain.description
		}
		append(&documents, doc)
	}
	wire := Task_Chain_Search_Feed_Wire{
		snapshot_revision = snapshot_revision,
		next_revision = next_revision,
		has_more = len(changes) == limit && next_revision < snapshot_revision,
		documents = documents[:],
	}
	data, _ := json.marshal(wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	return respond_success(string(data), req.request_id, auth_ctx_server_time(req))
}

TASK_CHAINS_GROUP_PREVIEW_CAP :: 5
TASK_CHAINS_PAGE_DEFAULT :: 20
TASK_CHAINS_PAGE_MAX :: 100

// has_query_key reports whether the query string carries `key` at all, even with
// an empty value — this distinguishes ?project_id= (the Unassigned bucket) from
// an absent project_id (the grouped view). Mirrors has_coordinated_by.
has_query_key :: proc(query, key: string) -> bool {
	parts := strings.split(query, "&"); defer delete(parts)
	for p in parts {
		if p == key do return true
		if eq := strings.index_byte(p, '='); eq >= 0 && p[:eq] == key do return true
	}
	return false
}

// Chain_List_Item is the flattened, project-enriched chain used by the grouped
// and per-project task-chains views. Its string fields are views into the
// caller-owned chain slice (valid for the request); the JSON serializer copies
// them out. Field set matches the TC-API wire contract exactly.
Chain_List_Item :: struct {
	chain_id:                      string,
	title:                         string,
	status:                        string,
	created_at:                    string,
	updated_at:                    string,
	coordinator_agent_instance_id: string,
	project_id:                    string,
	project_name:                  string,
	task_count:                    int,
	completed_task_count:          int,
	user_validation_count:         int,
	is_pinned:                     bool,
	pinned_at:                     string,
}

// enrich_chain_list_items resolves each chain's project once, memoizing the
// coordinator-instance -> project_id and project_id -> project_name lookups so a
// project shared by many chains costs a single conversation/project fetch. The
// returned dynamic array is caller-owned (delete it); its strings are not.
enrich_chain_list_items :: proc(h: ^Taskchain_Handlers, auth: contracts.Auth_Context, chains: []domain.Task_Chain, only_with_tasks: bool, include_archived: bool) -> [dynamic]Chain_List_Item {
	items := make([dynamic]Chain_List_Item)
	proj_idx := conversation_project_index(h, auth)
	defer destroy_conversation_project_index(&proj_idx)
	meta_by_project := make(map[string]Resolved_Project_Meta); defer delete(meta_by_project)
	// One grouped rollup for every chain, not one query per chain.
	task_counts, counts_err := taskchain_service.task_counts_by_chain(h.taskchains, auth)
	defer delete(task_counts)
	// A failed rollup must not silently empty the list: fall back to showing every
	// chain with an unknown (0) count rather than filtering them all away.
	counts_ok := counts_err.code == .None
	for c in chains {
		if !include_archived && c.status == .Archived do continue
		rollup := task_counts[string(c.chain_id)] or_else iface.Chain_Task_Rollup{}
		if only_with_tasks && counts_ok && rollup.total_count == 0 do continue
		coord_id := c.coordinator_agent_instance_id
		if coord_id == "" do coord_id = proj_idx.coord_by_chain[string(c.chain_id)] or_else ""
		project_id := proj_idx.by_instance[c.coordinator_agent_instance_id] or_else ""
		if project_id == "" && string(c.chain_id) in proj_idx.by_chain {
			project_id = proj_idx.by_chain[string(c.chain_id)]
		}
		meta := resolve_project_meta(h, auth, project_id, &meta_by_project)
		if !include_archived && meta.is_archived do continue
		append(&items, Chain_List_Item{
			chain_id = string(c.chain_id),
			title = c.title,
			status = chain_status_http(c.status),
			created_at = c.created_at,
			updated_at = c.updated_at,
			coordinator_agent_instance_id = coord_id,
			project_id = project_id,
			project_name = meta.name,
			task_count = rollup.total_count,
			completed_task_count = rollup.completed_count,
			user_validation_count = rollup.user_validation_count,
			is_pinned = c.is_pinned,
			pinned_at = c.pinned_at,
		})
	}
	return items
}

Conversation_Project_Index :: struct {
	by_instance:    map[string]string,
	by_chain:       map[string]string,
	coord_by_chain: map[string]string,
}

destroy_conversation_project_index :: proc(idx: ^Conversation_Project_Index) {
	delete(idx.by_instance)
	delete(idx.by_chain)
	delete(idx.coord_by_chain)
}

// conversation_project_index maps coordinator instance -> project id AND chain id -> project id
// for the whole request in ONE conversation listing.
//
// This used to be a per-chain lookup (get_conversation_by_instance), memoized by
// coordinator instance. The memo never hit: coordinator instances are unique per
// chain, so an owner with N chains paid N listings — and each listing runs eight
// correlated subqueries per conversation over chat_messages, which has no index on
// conversation_id. Measured on production data (87 chains, 165 conversations, 3491
// messages) that was ~1.4s per listing x 78 coordinators = ~106s, past nginx's 60s
// proxy_read_timeout, so the endpoint 504'd. One listing is one lookup.
//
// Chains with no coordinator, no content service, or no conversation resolve to ""
// and fall into the "Unassigned" bucket.
// NOTE: the listing is bounded (the repository clamps to 200), so an owner with more
// conversations than that would misfile the overflow as "Unassigned" — the same
// bound the old per-chain path had. A by-instance index is the real fix.
conversation_project_index :: proc(h: ^Taskchain_Handlers, auth: contracts.Auth_Context) -> Conversation_Project_Index {
	idx := Conversation_Project_Index{
		by_instance    = make(map[string]string),
		by_chain       = make(map[string]string),
		coord_by_chain = make(map[string]string),
	}
	if h.content == nil do return idx
	rows, err := content_service.list_conversations(h.content, auth, 200, "")
	if err.code != .None do return idx
	defer delete(rows)
	for c in rows {
		if c.agent_instance_id != "" && string(c.project_id) != "" {
			idx.by_instance[c.agent_instance_id] = string(c.project_id)
		}
		if c.chain_id != "" {
			if string(c.project_id) != "" {
				idx.by_chain[c.chain_id] = string(c.project_id)
			}
			if c.agent_instance_id != "" && !(c.chain_id in idx.coord_by_chain) {
				idx.coord_by_chain[c.chain_id] = c.agent_instance_id
			}
		}
	}
	return idx
}

Resolved_Project_Meta :: struct {
	name:        string,
	is_archived: bool,
}

// resolve_project_meta looks up a project's display name and archive status,
// memoized by project id. Empty project id (Unassigned) and unresolved/deleted
// projects return empty name and is_archived = false.
resolve_project_meta :: proc(h: ^Taskchain_Handlers, auth: contracts.Auth_Context, project_id: string, cache: ^map[string]Resolved_Project_Meta) -> Resolved_Project_Meta {
	if project_id == "" do return {}
	if cached, ok := cache[project_id]; ok do return cached
	if h.projects == nil do return {}
	p, ok, err := project_service.get(h.projects, auth, domain.Project_ID(project_id))
	// As above: cache a real answer, but not a transient backend error.
	if err.code != .None && err.code != .Not_Found do return {}
	meta := Resolved_Project_Meta{
		name = p.name if ok else "",
		is_archived = ok && p.state == .Archived,
	}
	cache[project_id] = meta
	return meta
}

// chain_list_item_less orders items newest-first by created_at, breaking ties on
// chain_id (descending) so pagination and grouping are deterministic.
chain_list_item_less :: proc(a, b: Chain_List_Item) -> bool {
	if a.created_at != b.created_at do return a.created_at > b.created_at
	return a.chain_id > b.chain_id
}

// chain_cursor_encode / _decode form a COMPOSITE (created_at, chain_id)
// pagination cursor. created_at alone is ambiguous when chains share a timestamp:
// a purely-created_at cursor with a `>=`/`<` filter drops (or repeats) a tied row
// that straddles a page boundary. Carrying chain_id (the sort's tie-breaker) lets
// resumption land strictly AFTER (created_at, chain_id) in the newest-first order,
// so every chain is returned exactly once. Separator mirrors the chat-conversation
// repo's `order|id` cursor convention. Caller owns the returned string.
chain_cursor_encode :: proc(it: Chain_List_Item) -> string {
	return strings.concatenate({it.created_at, "|", it.chain_id})
}
chain_cursor_decode :: proc(cursor: string) -> (created_at: string, chain_id: string) {
	if sep := strings.index_byte(cursor, '|'); sep >= 0 do return cursor[:sep], cursor[sep + 1:]
	return cursor, ""
}
// chain_after_cursor reports whether `it` sorts strictly after the cursor in the
// newest-first (created_at desc, then chain_id desc) order used throughout. An
// empty cursor means "from the start" (include everything).
chain_after_cursor :: proc(it: Chain_List_Item, cur_created_at, cur_chain_id: string) -> bool {
	if cur_created_at == "" do return true
	if it.created_at != cur_created_at do return it.created_at < cur_created_at
	return it.chain_id < cur_chain_id
}

// project_display_name labels the Unassigned bucket; a resolved-but-unnamed
// project (e.g. deleted) keeps its empty name.
project_display_name :: proc(project_id, name: string) -> string {
	if project_id == "" do return "Unassigned"
	return name
}

// Chain_Project_Group is one project's entry in the grouped view: a bounded
// preview of its most-recent chains plus the total/has_more/next_cursor needed to
// page the rest via the per-project view.
Chain_Project_Group :: struct {
	project_id:   string,
	project_name: string,
	chains:       []Chain_List_Item,
	chain_total:  int,
	has_more:     bool,
	next_cursor:  string,
}

// group_chains_by_project groups enriched chains by project, sorts each group's
// chains newest-first, previews up to `preview_cap` per project, and orders the
// groups by their most-recent chain activity. Caller owns the result — free it
// with free_chain_project_groups.
group_chains_by_project :: proc(items: []Chain_List_Item, preview_cap: int) -> []Chain_Project_Group {
	// Collect chains per project, preserving one bucket per distinct project id.
	index_by_project := make(map[string]int); defer delete(index_by_project)
	buckets := make([dynamic][dynamic]Chain_List_Item)
	defer { for &bkt in buckets do delete(bkt); delete(buckets) }
	order := make([dynamic]string); defer delete(order) // project ids, first-seen order
	for it in items {
		idx, seen := index_by_project[it.project_id]
		if !seen {
			idx = len(buckets)
			index_by_project[it.project_id] = idx
			append(&buckets, make([dynamic]Chain_List_Item))
			append(&order, it.project_id)
		}
		append(&buckets[idx], it)
	}

	groups := make([dynamic]Chain_Project_Group)
	for project_id, i in order {
		bucket := buckets[i]
		slice.sort_by(bucket[:], chain_list_item_less)
		total := len(bucket)
		preview_n := total
		if preview_cap >= 0 && preview_n > preview_cap do preview_n = preview_cap
		preview := make([]Chain_List_Item, preview_n)
		for j in 0..<preview_n do preview[j] = bucket[j]
		has_more := total > preview_n
		next_cursor := ""
		// Composite cursor so the client can page the rest of THIS project via the
		// per-project view without losing a chain tied on created_at at the handoff.
		if has_more && preview_n > 0 do next_cursor = chain_cursor_encode(preview[preview_n - 1])
		append(&groups, Chain_Project_Group{
			project_id = project_id,
			project_name = project_display_name(project_id, bucket[0].project_name if total > 0 else ""),
			chains = preview,
			chain_total = total,
			has_more = has_more,
			next_cursor = next_cursor,
		})
	}
	// Order projects by most-recent chain activity (each group's first chain is its
	// newest after the per-group sort); tie-break on project id for determinism.
	slice.sort_by(groups[:], proc(a, b: Chain_Project_Group) -> bool {
		a_at := a.chains[0].updated_at if len(a.chains) > 0 else ""
		b_at := b.chains[0].updated_at if len(b.chains) > 0 else ""
		if a_at != b_at do return a_at > b_at
		return a.project_id < b.project_id
	})
	return groups[:]
}

free_chain_project_groups :: proc(groups: []Chain_Project_Group) {
	for g in groups {
		delete(g.chains)
		if g.next_cursor != "" do delete(g.next_cursor) // chain_cursor_encode alloc
	}
	delete(groups)
}

// Chain_Project_Page is the single-project, cursor-paginated view. chain_total is
// the project's full match count (independent of limit/cursor) — the same figure
// the grouped view carries — so the client's count pill is exact, not per-page.
Chain_Project_Page :: struct {
	project_id:   string,
	project_name: string,
	chains:       []Chain_List_Item,
	chain_total:  int,
	has_more:     bool,
	next_cursor:  string,
}

// paginate_project_chains returns one page of a single project's chains,
// newest-first. `cursor` is a composite (created_at, chain_id) watermark (see
// chain_cursor_encode): only chains that sort strictly after it are returned, so
// chains sharing a created_at across a page boundary are never skipped. The
// returned chains slice and next_cursor are caller-owned (delete them).
paginate_project_chains :: proc(items: []Chain_List_Item, project_id: string, limit: int, cursor: string) -> Chain_Project_Page {
	cur_at, cur_id := chain_cursor_decode(cursor)
	matched := make([dynamic]Chain_List_Item); defer delete(matched)
	project_name := ""
	project_total := 0
	for it in items {
		if it.project_id != project_id do continue
		project_name = it.project_name
		project_total += 1 // full project match count, before the cursor filter
		if !chain_after_cursor(it, cur_at, cur_id) do continue
		append(&matched, it)
	}
	slice.sort_by(matched[:], chain_list_item_less)

	eff_limit := limit
	if eff_limit <= 0 do eff_limit = TASK_CHAINS_PAGE_DEFAULT
	page_n := len(matched)
	if page_n > eff_limit do page_n = eff_limit
	page := make([]Chain_List_Item, page_n)
	for j in 0..<page_n do page[j] = matched[j]
	has_more := len(matched) > page_n
	next_cursor := ""
	if has_more && page_n > 0 do next_cursor = chain_cursor_encode(page[page_n - 1])
	return Chain_Project_Page{
		project_id = project_id,
		project_name = project_display_name(project_id, project_name),
		chains = page,
		chain_total = project_total,
		has_more = has_more,
		next_cursor = next_cursor,
	}
}

// write_chain_list_item_json emits ONE chain in the TC-API wire shape. Field set
// (chain_id,title,status,updated_at,coordinator_agent_instance_id,project_id,
// project_name,task_count) is contractual — keep it in sync with the client.
write_chain_list_item_json :: proc(b: ^strings.Builder, it: Chain_List_Item) {
	wire := make_chain_list_item_wire(it)
	data, _ := json.marshal(wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	strings.write_string(b, string(data))
}

write_chain_list_items_json :: proc(b: ^strings.Builder, items: []Chain_List_Item) {
	wires := make([]Chain_List_Item_Wire, len(items), context.temp_allocator)
	for it, i in items {
		wires[i] = make_chain_list_item_wire(it)
	}
	data, _ := json.marshal(wires, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	strings.write_string(b, string(data))
}

write_chain_project_group_json :: proc(b: ^strings.Builder, g: Chain_Project_Group) {
	wire := make_chain_project_group_wire(g)
	data, _ := json.marshal(wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	strings.write_string(b, string(data))
}

write_chain_project_page_json :: proc(b: ^strings.Builder, p: Chain_Project_Page) {
	wire := make_chain_project_page_wire(p)
	data, _ := json.marshal(wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	strings.write_string(b, string(data))
}

create_task_chain_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	coord_inst_id := json_string(req.body, "coordinator_agent_instance_id")
	chain, created, err := taskchain_service.create_chain(h.taskchains, auth_ctx, taskchain_service.Create_Chain_Input{
		title = json_string(req.body, "title"),
		description = json_string(req.body, "description"),
		owner_user_id = json_string(req.body, "owner_user_id"),
		kind = json_string(req.body, "kind"),
		coordinator_agent_id = coord_inst_id,
		default_reviewer_refs_json = json_array_raw(req.body, "default_reviewer_refs"),
	})
	if !created do return respond_error(err, req.request_id)
	if coord_agent_id := json_string(req.body, "coordinator_agent_id"); coord_agent_id != "" {
		if h.agents == nil do return respond_error(domain.domain_error(.Internal_Error, "agent service is not configured"), req.request_id)
		inst, inst_created, inst_err := agent_service.create_instance(h.agents, auth_ctx, agent_service.Create_Instance_Input{agent_id = coord_agent_id, bridge_id = json_string(req.body, "bridge_id"), provider = json_string(req.body, "provider"), model = json_string(req.body, "model"), project_id = domain.Project_ID(json_string(req.body, "project_id")), chain_id = string(chain.chain_id)})
		if !inst_created do return respond_error(inst_err, req.request_id)
		chain, created, err = taskchain_service.update_chain_coordinator(h.taskchains, auth_ctx, chain.chain_id, inst.agent_instance_id)
		if !created do return respond_error(err, req.request_id)
	}
	publish_chain_changed(h, string(chain.owner_user_id), string(chain.chain_id), "created")
	b := strings.builder_make(); write_chain_json(&b, chain)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

// chain_patch_title_source records who renamed a chain so the chain-scoped title
// nudge stops (REQ-TN-A): "agent" for an instance token, "user" otherwise. A PATCH
// without a title returns "" so update_chain leaves title_source untouched.
chain_patch_title_source :: proc(title: string, kind: contracts.Auth_Kind) -> string {
	if title == "" do return ""
	return "agent" if kind == .Instance_Token else "user"
}

patch_task_chain_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	has_pinned := strings.contains(req.body, "\"is_pinned\"") || strings.contains(req.body, "\"pinned\"")
	is_pinned_val := json_bool(req.body, "is_pinned") if strings.contains(req.body, "\"is_pinned\"") else json_bool(req.body, "pinned")
	title := json_string(req.body, "title")
	chain, updated, err := taskchain_service.update_chain(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id), taskchain_service.Update_Chain_Input{
		title = title,
		title_source = chain_patch_title_source(title, auth_ctx.kind),
		description = json_string(req.body, "description"),
		status = json_string(req.body, "status"),
		coordinator_agent_instance_id = json_string(req.body, "coordinator_agent_instance_id"),
		has_coordinator = strings.contains(req.body, "\"coordinator_agent_instance_id\""),
		is_pinned = is_pinned_val,
		has_is_pinned = has_pinned,
	})
	if !updated do return respond_error(err, req.request_id)
	publish_chain_changed(h, string(chain.owner_user_id), string(chain.chain_id), "updated")
	b := strings.builder_make(); write_chain_json(&b, chain)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

task_chain_detail_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	// READ (REQ-SEC-3): owner-scoped detail; a same-owner non-member may view it.
	chain, got, err := taskchain_service.get_chain_for_read(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id))
	if !got do return respond_error(err, req.request_id)

	tasks, _ := taskchain_service.list_tasks(h.taskchains, auth_ctx, chain.chain_id)
	members, _ := taskchain_service.list_chain_members(h.taskchains, auth_ctx, chain.chain_id)
	deps, _ := taskchain_service.list_chain_dependencies(h.taskchains, auth_ctx, chain.chain_id)
	dirs, _ := taskchain_service.list_chain_directories(h.taskchains, auth_ctx, chain.chain_id)

		defer {
		delete(tasks)
		delete(members)
		delete(deps)
		delete(dirs)
	}
	resp_wire := make_chain_detail_response_wire(h, auth_ctx, chain, members, tasks, deps, dirs)
	data, _ := json.marshal(resp_wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	return respond_success(string(data), req.request_id, auth_ctx_server_time(req))
}

publish_task_chain_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	chain, got, err := taskchain_service.publish_chain(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id))
	if !got do return respond_error(err, req.request_id)
	publish_chain_changed(h, string(chain.owner_user_id), string(chain.chain_id), "updated")
	b := strings.builder_make(); write_chain_json(&b, chain)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

complete_task_chain_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	chain, got, err := taskchain_service.change_chain_status(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id), .Completed)
	if !got do return respond_error(err, req.request_id)
	publish_chain_changed(h, string(chain.owner_user_id), string(chain.chain_id), "updated")
	b := strings.builder_make(); write_chain_json(&b, chain)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

pin_task_chain_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	has_pinned_field := strings.contains(req.body, "\"pinned\"") || strings.contains(req.body, "\"is_pinned\"")
	pinned := true
	if has_pinned_field {
		pinned = json_bool(req.body, "is_pinned") if strings.contains(req.body, "\"is_pinned\"") else json_bool(req.body, "pinned")
	} else {
		cur_chain, cur_ok, cur_err := taskchain_service.get_chain_for_read(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id))
		if !cur_ok do return respond_error(cur_err, req.request_id)
		pinned = !cur_chain.is_pinned
	}
	chain, updated, err := taskchain_service.pin_chain(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id), pinned)
	if !updated do return respond_error(err, req.request_id)
	publish_chain_changed(h, string(chain.owner_user_id), string(chain.chain_id), "updated")
	b := strings.builder_make(); write_chain_json(&b, chain)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

task_chain_subscribe_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	if chain_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "chain_id is required"), req.request_id)
	if auth_ctx.agent_instance_id == "" {
		if inst_id := json_string(req.body, "agent_instance_id"); inst_id != "" {
			auth_ctx.agent_instance_id = inst_id
		} else if inst_id2 := json_string(req.body, "subscriber_agent_instance_id"); inst_id2 != "" {
			auth_ctx.agent_instance_id = inst_id2
		} else if inst_id3 := query_value(req.query, "agent_instance_id"); inst_id3 != "" {
			auth_ctx.agent_instance_id = inst_id3
		} else if inst_id4 := query_value(req.query, "subscriber_agent_instance_id"); inst_id4 != "" {
			auth_ctx.agent_instance_id = inst_id4
		}
	}
	events_val := json_string(req.body, "events")
	if events_val == "" do events_val = json_string(req.body, "event_type")
	if events_val == "" do events_val = query_value(req.query, "events")
	if events_val == "" do events_val = query_value(req.query, "event_type")
	sub, saved, err := taskchain_service.subscribe_taskchain(h.taskchains, auth_ctx, chain_id, events_val)
	if !saved do return respond_error(err, req.request_id)
	publish_chain_changed(h, string(sub.owner_user_id), string(sub.chain_id), "updated")
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_subscription_json(&b, sub)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

task_chain_unsubscribe_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	if chain_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "chain_id is required"), req.request_id)
	if auth_ctx.agent_instance_id == "" {
		if inst_id := json_string(req.body, "agent_instance_id"); inst_id != "" {
			auth_ctx.agent_instance_id = inst_id
		} else if inst_id2 := json_string(req.body, "subscriber_agent_instance_id"); inst_id2 != "" {
			auth_ctx.agent_instance_id = inst_id2
		} else if inst_id3 := query_value(req.query, "agent_instance_id"); inst_id3 != "" {
			auth_ctx.agent_instance_id = inst_id3
		} else if inst_id4 := query_value(req.query, "subscriber_agent_instance_id"); inst_id4 != "" {
			auth_ctx.agent_instance_id = inst_id4
		}
	}
	events_val := json_string(req.body, "events")
	if events_val == "" do events_val = json_string(req.body, "event_type")
	if events_val == "" do events_val = query_value(req.query, "events")
	if events_val == "" do events_val = query_value(req.query, "event_type")
	removed, err := taskchain_service.unsubscribe_taskchain(h.taskchains, auth_ctx, chain_id, events_val)
	if err.code != .None do return respond_error(err, req.request_id)
	publish_chain_changed(h, auth_ctx.user_id, string(chain_id), "updated")
	unsub_wire := Subscription_Removed_Wire{removed = removed}
	data, _ := json.marshal(unsub_wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	return respond_success(string(data), req.request_id, auth_ctx_server_time(req), 200)
}

list_tasks_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	tasks, err := taskchain_service.list_tasks(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id))
	if err.code != .None do return respond_error(err, req.request_id)
	deps, _ := taskchain_service.list_chain_dependencies(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id))
	b := strings.builder_make(); strings.write_byte(&b, '[')
	written := 0
	for task in tasks {
		if !task_matches_query(task, req.query) do continue
		if written > 0 do strings.write_byte(&b, ',')
		write_task_detail_json(&b, h, auth_ctx, task, deps, false)
		written += 1
	}
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

// get_task_handler returns ONE task with its comment_summary + votes (slim: no
// comment bodies). Agents/UI fetch the thread separately via .../comments?last=N.
get_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	// READ (REQ-SEC-3): owner-scoped; a same-owner non-member may view the task.
	task, got, err := taskchain_service.get_task_for_read(h.taskchains, auth_ctx, task_id)
	if !got do return respond_error(err, req.request_id)
	deps, _ := taskchain_service.list_chain_dependencies(h.taskchains, auth_ctx, chain_id)
	b := strings.builder_make()
	write_task_detail_json(&b, h, auth_ctx, task, deps)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

// create_priority_from_body reads an optional "priority" field for a task CREATE.
// Unlike domain.task_priority_from_string — which coerces anything unrecognised to
// P2 — an explicitly present but invalid value is REJECTED here (REQ-CLI-2): a
// create that silently seats "urgent" at p2 is the exact failure this fixes. Absent
// means absent (has = false) and the service applies the documented P2 default.
// Scoped to create on purpose; the update/patch path keeps its existing behaviour.
create_priority_from_body :: proc(body: string) -> (priority: domain.Task_Priority, has: bool, ok: bool, err: domain.Domain_Error) {
	if !strings.contains(body, "\"priority\"") do return .P2, false, true, {}
	raw := strings.trim_space(json_string(body, "priority"))
	switch raw {
	case "p0", "P0": return .P0, true, true, {}
	case "p1", "P1": return .P1, true, true, {}
	case "p2", "P2": return .P2, true, true, {}
	}
	return .P2, false, false, domain.domain_error(.Validation_Failed, "priority must be one of p0, p1, p2")
}

// task_bridge_id_from_body reads the optional "bridge_id" pin for a task CREATE or
// PATCH. Both the cookie API and the agent-action API call it so the two transports
// cannot diverge (same rationale as the shared depends_on parse). `present` is true
// when the key was sent AT ALL — an explicitly empty string is a deliberate clear
// back to inherit on PATCH, while an absent key means inherit on create and "leave
// the pin untouched" on PATCH. The service applies that distinction through
// Create_Task_Input.bridge_id (plain) and the presence-checked
// Update_Task_Input.bridge_id (nil = absent).
task_bridge_id_from_body :: proc(body: string) -> (value: string, present: bool) {
	return json_string(body, "bridge_id"), strings.contains(body, "\"bridge_id\"")
}

create_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	deps := json_array_of_strings(req.body, "depends_on")
	priority, has_priority, prio_ok, prio_err := create_priority_from_body(req.body)
	if !prio_ok do return respond_error(prio_err, req.request_id)
	bridge_id, _ := task_bridge_id_from_body(req.body)
	has_requires_user_approval := json_key_present(req.body, "requires_user_approval")
	requires_user_approval, valid_requires_user_approval := json_bool_literal(req.body, "requires_user_approval")
	if has_requires_user_approval && !valid_requires_user_approval do return respond_error(domain.domain_error(.Validation_Failed, "requires_user_approval must be a boolean"), req.request_id)
	task, created, err := taskchain_service.create_task(h.taskchains, auth_ctx, taskchain_service.Create_Task_Input{chain_id = domain.Task_Chain_ID(chain_id), title = json_string(req.body, "title"), description = json_string(req.body, "description"), owner_user_id = json_string(req.body, "owner_user_id"), assignee_ref_json = json_object_or_empty(req.body, "assignee_ref"), reviewer_refs_json = json_array_optional(req.body, "reviewer_refs"), requires_user_approval = requires_user_approval, has_requires_user_approval = has_requires_user_approval, priority = priority, has_priority = has_priority, depends_on = deps, bridge_id = bridge_id})
	if !created do return respond_error(err, req.request_id)
	publish_task_changed(h, string(task.owner_user_id), string(task.task_id), string(task.chain_id), "created")
	publish_chain_changed(h, string(task.owner_user_id), string(task.chain_id), "updated")
	chain_deps, _ := taskchain_service.list_chain_dependencies(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id))
	b := strings.builder_make()
	write_task_detail_json(&b, h, auth_ctx, task, chain_deps)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

patch_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	has_deps := strings.contains(req.body, "\"depends_on\"")
	deps := json_array_of_strings(req.body, "depends_on")
	has_priority := strings.contains(req.body, "\"priority\"")
	priority := domain.task_priority_from_string(json_string(req.body, "priority"))
	// bridge_id is presence-checked, not defaulted: absent leaves the pin untouched
	// (nil), present "" clears it back to inherit, and present non-empty repins.
	bridge_id, has_bridge := task_bridge_id_from_body(req.body)
	bridge_pin: ^string
	if has_bridge do bridge_pin = &bridge_id
	has_requires_user_approval := json_key_present(req.body, "requires_user_approval")
	requires_user_approval, valid_requires_user_approval := json_bool_literal(req.body, "requires_user_approval")
	if has_requires_user_approval && !valid_requires_user_approval do return respond_error(domain.domain_error(.Validation_Failed, "requires_user_approval must be a boolean"), req.request_id)
	task, updated, err := taskchain_service.update_task(h.taskchains, auth_ctx, task_id, taskchain_service.Update_Task_Input{title = json_string(req.body, "title"), description = json_string(req.body, "description"), assignee_ref_json = json_object_or_empty(req.body, "assignee_ref"), reviewer_refs_json = json_array_optional(req.body, "reviewer_refs"), requires_user_approval = requires_user_approval, has_requires_user_approval = has_requires_user_approval, priority = priority, has_priority = has_priority, depends_on = deps, has_depends_on = has_deps, bridge_id = bridge_pin})
	if !updated do return respond_error(err, req.request_id)
	publish_task_changed(h, string(task.owner_user_id), string(task.task_id), string(task.chain_id), "updated")
	publish_chain_changed(h, string(task.owner_user_id), string(task.chain_id), "updated")
	b := strings.builder_make(); write_task_json(&b, task)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

update_task_handler :: patch_task_handler

publish_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	task, got, err := taskchain_service.publish_task(h.taskchains, auth_ctx, task_id)
	if !got do return respond_error(err, req.request_id)
	publish_task_changed(h, string(task.owner_user_id), string(task.task_id), string(task.chain_id), "updated")
	b := strings.builder_make(); write_task_json(&b, task)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

change_task_status_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	status, status_ok := task_status_from_http(json_string(req.body, "status"))
	if !status_ok do return respond_error(domain.domain_error(.Validation_Failed, "invalid task status"), req.request_id)
	task, changed, err := taskchain_service.change_task_status(h.taskchains, auth_ctx, task_id, status)
	if !changed do return respond_error(err, req.request_id)
	publish_task_changed(h, string(task.owner_user_id), string(task.task_id), string(task.chain_id), "status_changed")
	publish_chain_changed(h, string(task.owner_user_id), string(task.chain_id), "updated")
	// `task` is the RE-READ row (see change_task_status), so its status is what the
	// database holds — which is not always what was asked for: the promotion engine may
	// demote it again in the same request. Pass the requested value so a caller can see
	// both rather than being told its request took effect when it did not.
	b := strings.builder_make(); write_task_json(&b, task, task_status_http(status))
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

cancel_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	task, changed, err := taskchain_service.change_task_status(h.taskchains, auth_ctx, task_id, .Cancelled)
	if !changed do return respond_error(err, req.request_id)
	publish_task_changed(h, string(task.owner_user_id), string(task.task_id), string(task.chain_id), "status_changed")
	publish_chain_changed(h, string(task.owner_user_id), string(task.chain_id), "updated")
	b := strings.builder_make(); write_task_json(&b, task)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

nudge_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	nudge, nudged, err := taskchain_service.manual_nudge(h.taskchains, auth_ctx, task_id, json_string(req.body, "message"))
	if !nudged do return respond_error(err, req.request_id)
	
		nudge_wire := Task_Nudge_Response_Wire{
		task_id        = string(nudge.task_id),
		nudge_id       = nudge.nudge_id,
		delivery_state = nudge.delivery_state,
		live_delivered = nudge.live_delivered,
		durable_queued = nudge.durable_queued,
		failed         = nudge.failed,
		target_role    = taskchain_service.target_string(nudge.target),
		created_at     = nudge.created_at,
		targets        = json_value_raw(nudge.targets_json),
	}
	data, _ := json.marshal(nudge_wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	return respond_success(string(data), req.request_id, auth_ctx_server_time(req))
}

// set_task_current_task_handler lets a coordinator/user pin an agent instance's
// current task to this task (CT-9 manual override). Body: {"agent_instance_id"}.
// The service validates assignee/reviewer eligibility + actionability, persists
// the pointer, and notifies the target agent (work vs review label).
set_task_current_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	instance_id := json_string(req.body, "agent_instance_id")
	if strings.trim_space(instance_id) == "" do return respond_error(domain.domain_error(.Validation_Failed, "agent_instance_id is required"), req.request_id)
	inst, set_ok, err := taskchain_service.set_instance_current_task(h.taskchains, auth_ctx, instance_id, task_id)
	if !set_ok do return respond_error(err, req.request_id)
	publish_task_changed(h, string(inst.owner_user_id), string(task_id), string(chain_id), "current_task_set")
	publish_instance_current_task_changed(h, string(inst.owner_user_id), inst.agent_instance_id, inst.current_task_id, domain.current_task_role_string(inst.current_task_role))
		ct_wire := Task_Current_Task_Response_Wire{
		agent_instance_id = inst.agent_instance_id,
		current_task_id   = inst.current_task_id,
		current_task_role = domain.current_task_role_string(inst.current_task_role),
	}
	data, _ := json.marshal(ct_wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	return respond_success(string(data), req.request_id, auth_ctx_server_time(req))
}

list_task_comments_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	// ?last=N returns only the newest N comments (bounded); absent/<=0 => all.
	// Cap at TASK_COMMENTS_LAST_MAX so a huge N can't be used to dump everything.
	last := query_int(req.query, "last", 0)
	if last > TASK_COMMENTS_LAST_MAX do last = TASK_COMMENTS_LAST_MAX
	comments, err := taskchain_service.list_recent_task_comments(h.taskchains, auth_ctx, task_id, last)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make(); strings.write_byte(&b, '[')
	for c, i in comments { if i > 0 do strings.write_byte(&b, ','); write_task_comment_json(&b, c, resolve_comment_author_display(h, auth_ctx, c)) }
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

// TASK_COMMENTS_LAST_MAX caps the ?last=N tail fetch so agents can bound payloads
// but can't dump an unbounded thread through the "recent" path.
TASK_COMMENTS_LAST_MAX :: 100

create_task_comment_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	notify := json_array_of_strings_raw(req.body, "notify")
	comment, notified, saved, err := taskchain_service.comment_task(h.taskchains, auth_ctx, taskchain_service.Task_Comment_Input{task_id = task_id, body = json_string(req.body, "body"), notify = notify})
	if !saved do return respond_error(err, req.request_id)
	publish_task_changed(h, string(comment.owner_user_id), string(comment.task_id), string(comment.chain_id), "commented")
	b := strings.builder_make()
	write_task_comment_response_json(&b, comment, resolve_comment_author_display(h, auth_ctx, comment), notified)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

list_task_votes_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	votes, err := taskchain_service.list_task_votes(h.taskchains, auth_ctx, task_id)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make(); strings.write_byte(&b, '[')
	for v, i in votes { if i > 0 do strings.write_byte(&b, ','); write_task_vote_json(&b, v) }
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

vote_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	vote, recorded, err := taskchain_service.record_task_vote(h.taskchains, auth_ctx, taskchain_service.Vote_Input{task_id = task_id, vote = json_string(req.body, "vote"), comment = json_string(req.body, "comment")})
	if !recorded do return respond_error(err, req.request_id)
	publish_task_changed(h, string(vote.owner_user_id), string(vote.task_id), string(vote.chain_id), "voted")
	publish_chain_changed(h, string(vote.owner_user_id), string(vote.chain_id), "updated")
	if updated_task, task_ok, _ := taskchain_service.get_task(h.taskchains, auth_ctx, vote.task_id); task_ok {
		if updated_task.status == .Completed || updated_task.status == .Validated_Not_Good {
			publish_task_changed(h, string(vote.owner_user_id), string(vote.task_id), string(vote.chain_id), "status_changed")
		}
	}
	b := strings.builder_make(); write_task_vote_json(&b, vote)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

task_subscribe_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	task_id: domain.Task_ID
	if path_part(req.path, 3) == "task-chains" && path_part(req.path, 5) == "tasks" {
		chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
		task_id = domain.Task_ID(path_part(req.path, 6))
		if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	} else if path_part(req.path, 3) == "tasks" {
		task_id = domain.Task_ID(path_part(req.path, 4))
	} else {
		task_id = domain.Task_ID(path_part(req.path, 6))
	}
	if task_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "task_id is required"), req.request_id)
	if auth_ctx.agent_instance_id == "" {
		if inst_id := json_string(req.body, "agent_instance_id"); inst_id != "" {
			auth_ctx.agent_instance_id = inst_id
		} else if inst_id2 := json_string(req.body, "subscriber_agent_instance_id"); inst_id2 != "" {
			auth_ctx.agent_instance_id = inst_id2
		} else if inst_id3 := query_value(req.query, "agent_instance_id"); inst_id3 != "" {
			auth_ctx.agent_instance_id = inst_id3
		} else if inst_id4 := query_value(req.query, "subscriber_agent_instance_id"); inst_id4 != "" {
			auth_ctx.agent_instance_id = inst_id4
		}
	}
	events_val := json_string(req.body, "events")
	if events_val == "" do events_val = json_string(req.body, "event_type")
	if events_val == "" do events_val = query_value(req.query, "events")
	if events_val == "" do events_val = query_value(req.query, "event_type")
	sub, saved, err := taskchain_service.subscribe_task(h.taskchains, auth_ctx, task_id, events_val)
	if !saved do return respond_error(err, req.request_id)
	publish_task_changed(h, string(sub.owner_user_id), string(sub.task_id), string(sub.chain_id), "updated")
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_subscription_json(&b, sub)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

task_unsubscribe_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	task_id: domain.Task_ID
	chain_for_pub: domain.Task_Chain_ID = ""
	if path_part(req.path, 3) == "task-chains" && path_part(req.path, 5) == "tasks" {
		chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
		task_id = domain.Task_ID(path_part(req.path, 6))
		chain_for_pub = chain_id
		if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	} else if path_part(req.path, 3) == "tasks" {
		task_id = domain.Task_ID(path_part(req.path, 4))
	} else {
		task_id = domain.Task_ID(path_part(req.path, 6))
	}
	if task_id == "" do return respond_error(domain.domain_error(.Validation_Failed, "task_id is required"), req.request_id)
	if auth_ctx.agent_instance_id == "" {
		if inst_id := json_string(req.body, "agent_instance_id"); inst_id != "" {
			auth_ctx.agent_instance_id = inst_id
		} else if inst_id2 := json_string(req.body, "subscriber_agent_instance_id"); inst_id2 != "" {
			auth_ctx.agent_instance_id = inst_id2
		} else if inst_id3 := query_value(req.query, "agent_instance_id"); inst_id3 != "" {
			auth_ctx.agent_instance_id = inst_id3
		} else if inst_id4 := query_value(req.query, "subscriber_agent_instance_id"); inst_id4 != "" {
			auth_ctx.agent_instance_id = inst_id4
		}
	}
	events_val := json_string(req.body, "events")
	if events_val == "" do events_val = json_string(req.body, "event_type")
	if events_val == "" do events_val = query_value(req.query, "events")
	if events_val == "" do events_val = query_value(req.query, "event_type")
	removed, err := taskchain_service.unsubscribe_task(h.taskchains, auth_ctx, task_id, events_val)
	if err.code != .None do return respond_error(err, req.request_id)
	if chain_for_pub != "" {
		publish_chain_changed(h, auth_ctx.user_id, string(chain_for_pub), "updated")
	}
	unsub_wire := Subscription_Removed_Wire{removed = removed}
	data, _ := json.marshal(unsub_wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	return respond_success(string(data), req.request_id, auth_ctx_server_time(req), 200)
}

list_chain_members_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	members, err := taskchain_service.list_chain_members(h.taskchains, auth_ctx, chain_id)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make(); strings.write_byte(&b, '[')
	for m, i in members { if i > 0 do strings.write_byte(&b, ','); write_member_json(&b, h, auth_ctx, m) }
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

add_chain_member_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	member, added, err := taskchain_service.add_chain_member(h.taskchains, auth_ctx, chain_id, json_string(req.body, "agent_instance_id"), json_string(req.body, "role"))
	if !added do return respond_error(err, req.request_id)
	publish_chain_changed(h, string(member.owner_user_id), string(member.chain_id), "updated")
	b := strings.builder_make(); write_member_json(&b, h, auth_ctx, member)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

remove_chain_member_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	agent_instance_id := path_part(req.path, 6)
	removed, err := taskchain_service.remove_chain_member(h.taskchains, auth_ctx, chain_id, agent_instance_id)
	if !removed do return respond_error(err, req.request_id)
	publish_chain_changed(h, auth_ctx.user_id, string(chain_id), "updated")
	return respond_success("{\"removed\":true}", req.request_id, auth_ctx_server_time(req))
}

write_directory_json :: proc(b: ^strings.Builder, dir: domain.Task_Chain_Directory) {
	wire := make_chain_directory_wire(dir)
	data, _ := json.marshal(wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	strings.write_string(b, string(data))
}

list_chain_directories_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	dirs, err := taskchain_service.list_chain_directories(h.taskchains, auth_ctx, chain_id)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for d, i in dirs {
		if i > 0 do strings.write_byte(&b, ',')
		write_directory_json(&b, d)
	}
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

add_chain_directory_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	path := json_string(req.body, "path")
	bridge_id := json_string(req.body, "bridge_id")
	vcs_kind := json_string(req.body, "vcs_kind")
	vcs_info_json := "{}"
	if obj, has_obj := json_object_raw_balanced(req.body, "vcs"); has_obj {
		vcs_info_json = obj
	} else if obj2, has_obj2 := json_object_raw_balanced(req.body, "vcs_info"); has_obj2 {
		vcs_info_json = obj2
	} else if s := json_string(req.body, "vcs_info_json"); s != "" {
		vcs_info_json = s
	}
	if vcs_kind == "" {
		if obj_vk := json_string(vcs_info_json, "vcs_kind"); obj_vk != "" {
			vcs_kind = obj_vk
		} else if obj_k := json_string(vcs_info_json, "kind"); obj_k != "" {
			vcs_kind = obj_k
		}
	}
	dir, added, err := taskchain_service.add_chain_directory(h.taskchains, auth_ctx, taskchain_service.Add_Directory_Input{
		chain_id      = chain_id,
		path          = path,
		bridge_id     = bridge_id,
		vcs_kind      = vcs_kind,
		vcs_info_json = vcs_info_json,
	})
	if !added do return respond_error(err, req.request_id)
	publish_chain_changed(h, string(dir.owner_user_id), string(dir.chain_id), "updated")
	b := strings.builder_make()
	write_directory_json(&b, dir)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

patch_chain_directory_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	dir_id := path_part(req.path, 6)
	has_path := strings.contains(req.body, "\"path\"")
	has_bridge_id := strings.contains(req.body, "\"bridge_id\"")
	has_vcs_kind := strings.contains(req.body, "\"vcs_kind\"")
	has_vcs_info := strings.contains(req.body, "\"vcs\"") || strings.contains(req.body, "\"vcs_info\"") || strings.contains(req.body, "\"vcs_info_json\"")
	vcs_info_json := "{}"
	if obj, has_obj := json_object_raw_balanced(req.body, "vcs"); has_obj {
		vcs_info_json = obj
	} else if obj2, has_obj2 := json_object_raw_balanced(req.body, "vcs_info"); has_obj2 {
		vcs_info_json = obj2
	} else if s := json_string(req.body, "vcs_info_json"); s != "" {
		vcs_info_json = s
	}
	dir, updated, err := taskchain_service.update_chain_directory(h.taskchains, auth_ctx, taskchain_service.Update_Directory_Input{
		directory_id  = dir_id,
		chain_id      = chain_id,
		path          = json_string(req.body, "path"),
		bridge_id     = json_string(req.body, "bridge_id"),
		vcs_kind      = json_string(req.body, "vcs_kind"),
		vcs_info_json = vcs_info_json,
		has_path      = has_path,
		has_bridge_id = has_bridge_id,
		has_vcs_kind  = has_vcs_kind,
		has_vcs_info  = has_vcs_info,
	})
	if !updated do return respond_error(err, req.request_id)
	publish_chain_changed(h, string(dir.owner_user_id), string(dir.chain_id), "updated")
	b := strings.builder_make()
	write_directory_json(&b, dir)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

remove_chain_directory_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	dir_id := path_part(req.path, 6)
	removed, err := taskchain_service.remove_chain_directory(h.taskchains, auth_ctx, chain_id, dir_id)
	if !removed do return respond_error(err, req.request_id)
	publish_chain_changed(h, auth_ctx.user_id, string(chain_id), "updated")
	return respond_success("{\"removed\":true}", req.request_id, auth_ctx_server_time(req))
}

get_chain_directory_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	dir_id := path_part(req.path, 6)
	dir, found, err := taskchain_service.get_chain_directory(h.taskchains, auth_ctx, chain_id, dir_id)
	if !found do return respond_error(err, req.request_id)
	b := strings.builder_make()
	write_directory_json(&b, dir)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

// The two restart_live_instances bookkeeping params are pointer-optional on purpose:
// the GET list (and any flag-less PUT) passes nil for both, so its payload stays
// byte-identical to the pre-restart contract; the upsert handler passes non-nil
// (possibly empty) values whenever the request carried the flag, and each field is
// emitted only when its pointer is non-nil.
write_fleet_json :: proc(
	b: ^strings.Builder,
	f: domain.Task_Chain_Fleet,
	active_count: int = 0,
	restarted_instance_ids: ^[]string = nil,
	restart_failures: ^[]Fleet_Restart_Failure = nil,
) {
	wire := make_chain_fleet_wire(f, active_count, restarted_instance_ids, restart_failures)
	data, _ := json.marshal(wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	strings.write_string(b, string(data))
}

json_int_field :: proc(body, key: string, default_value: int) -> int {
	return jsonx.extract_int(body, key, default_value)
}

// fleet_provider_model_changed reports whether a fleet upsert actually changes the
// role's provider or model relative to the prior row. Capacity/min_warm/TTL edits
// alone never restart live instances, and a missing prior row has nothing to
// compare against, so both cases report false.
fleet_provider_model_changed :: proc(prior_provider, prior_model, provider, model: string) -> bool {
	return prior_provider != provider || prior_model != model
}

// fleet_restart_instance_live mirrors the active_count predicate of the fleet list
// handler: an instance counts as live unless its runtime_status is terminal.
fleet_restart_instance_live :: proc(runtime_status: string) -> bool {
	return runtime_status != "stopped" && runtime_status != "failed" && runtime_status != "terminated"
}

list_chain_fleets_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	fleets, err := taskchain_service.list_fleets(h.taskchains, auth_ctx, chain_id)
	if err.code != .None do return respond_error(err, req.request_id)
	defer delete(fleets)
	members, _ := taskchain_service.list_chain_members(h.taskchains, auth_ctx, chain_id)
	defer delete(members)
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for f, i in fleets {
		if i > 0 do strings.write_byte(&b, ',')
		active_count := 0
		for m in members {
			if m.agent_id == f.agent_id {
				if h.agents != nil {
					if inst, inst_ok, _ := agent_service.get_instance(h.agents, auth_ctx, m.agent_instance_id); inst_ok {
						if inst.runtime_status != "stopped" && inst.runtime_status != "failed" && inst.runtime_status != "terminated" {
							active_count += 1
						}
					}
				} else {
					active_count += 1
				}
			}
		}
		write_fleet_json(&b, f, active_count)
	}
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

upsert_chain_fleet_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	agent_id := path_part(req.path, 6)
	capacity := json_int_field(req.body, "capacity", 1)
	min_warm := json_int_field(req.body, "min_warm", 0)
	idle_ttl_seconds := json_int_field(req.body, "idle_ttl_seconds", 600)
	provider := json_string(req.body, "provider")
	model := json_string(req.body, "model")
	bridge_models, bridge_models_present := jsonx.extract_raw_object(req.body, "bridge_models", top_level_only = true, allocator = context.temp_allocator)
	if jsonx.has_key(req.body, "bridge_models", top_level_only = true) && !bridge_models_present do return respond_error(domain.domain_error(.Validation_Failed, "bridge_models must be an object"), req.request_id)
	// Optional user-confirmed restart of the role's live instances when this PUT
	// actually changes the role's provider/model. Absent or malformed values keep the
	// historical flag-less behavior (persist only), so only a well-formed JSON
	// boolean counts as "carried the flag".
	restart_live_instances, restart_flag_ok := json_bool_literal(req.body, "restart_live_instances")
	restart_role_instances := false
	if restart_flag_ok && restart_live_instances {
		role := strings.trim_space(agent_id)
		prior_fleets, prior_err := taskchain_service.list_fleets(h.taskchains, auth_ctx, chain_id)
		defer if prior_err.code == .None do delete(prior_fleets)
		for prior in prior_fleets {
			if prior.agent_id == role {
				restart_role_instances = fleet_provider_model_changed(prior.provider, prior.model, provider, model) || (bridge_models_present && prior.bridge_models_json != bridge_models)
				break
			}
		}
	}
	fleet, err := taskchain_service.upsert_fleet(h.taskchains, auth_ctx, taskchain_service.Upsert_Fleet_Input{
		chain_id         = chain_id,
		agent_id         = agent_id,
		capacity         = capacity,
		min_warm         = min_warm,
		idle_ttl_seconds = idle_ttl_seconds,
		provider         = provider,
		model             = model,
		bridge_models_json = bridge_models,
	})
	if err.code != .None do return respond_error(err, req.request_id)
	restarted_ids := make([dynamic]string)
	defer delete(restarted_ids)
	restart_failures := make([dynamic]Fleet_Restart_Failure)
	defer delete(restart_failures)
	defer {
		for failure in restart_failures do delete(failure.message)
	}
	if restart_role_instances && h.agents != nil {
		members, members_err := taskchain_service.list_chain_members(h.taskchains, auth_ctx, chain_id)
		defer delete(members)
		role := strings.trim_space(agent_id)
		if members_err.code == .None {
			for m in members {
				if m.agent_id != role do continue
				// Unresolvable members (get_instance miss) are skipped silently, and the
				// liveness check matches the fleet list's active_count predicate.
				inst, inst_ok, _ := agent_service.get_instance(h.agents, auth_ctx, m.agent_instance_id)
				if !inst_ok || !fleet_restart_instance_live(inst.runtime_status) do continue
				// relaunch_instance is the primitive that persists the NEW provider/model
				// verbatim on the same instance id ("" resolves through the standard
				// inheritance order) and re-sends the launch command.
				selected_provider, selected_model := taskchain_service.fleet_model_on_bridge(fleet, inst.bridge_id)
				launch_provider, launch_model := taskchain_service.resolve_fleet_launch_model(h.taskchains, inst.bridge_id, selected_provider, selected_model)
				defer delete(launch_provider)
				defer delete(launch_model)
				if inst.provider == launch_provider && inst.model == launch_model do continue
				if _, relaunched, relaunch_err := agent_service.relaunch_instance(h.agents, auth_ctx, inst, launch_provider, launch_model); relaunched {
					append(&restarted_ids, inst.agent_instance_id)
				} else {
					// Clone: relaunch path messages can come from fmt.tprintf (temp memory).
					append(&restart_failures, Fleet_Restart_Failure{instance_id = inst.agent_instance_id, message = strings.clone(relaunch_err.message)})
				}
			}
		}
	}
	publish_chain_changed(h, auth_ctx.user_id, string(chain_id), "updated")
	b := strings.builder_make()
	restarted_out := restarted_ids[:]
	failures_out := restart_failures[:]
	restarted_ptr: ^[]string
	failures_ptr: ^[]Fleet_Restart_Failure
	if restart_flag_ok {
		restarted_ptr = &restarted_out
		failures_ptr = &failures_out
	}
	write_fleet_json(&b, fleet, 0, restarted_ptr, failures_ptr)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

delete_chain_fleet_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	agent_id := path_part(req.path, 6)
	deleted, err := taskchain_service.delete_fleet(h.taskchains, auth_ctx, chain_id, agent_id)
	if !deleted do return respond_error(err, req.request_id)
	publish_chain_changed(h, auth_ctx.user_id, string(chain_id), "updated")
	return respond_success("{\"deleted\":true,\"removed\":true}", req.request_id, auth_ctx_server_time(req))
}

write_chain_json :: proc(b: ^strings.Builder, c: domain.Task_Chain) {
	wire := make_chain_wire(c)
	data, _ := json.marshal(wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	strings.write_string(b, string(data))
}

write_subscription_json :: proc(b: ^strings.Builder, s: domain.Task_Subscription) {
	wire := make_subscription_wire(s)
	data, _ := json.marshal(wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	strings.write_string(b, string(data))
}

write_task_fsm_fields_json :: proc(b: ^strings.Builder, status: domain.Task_Status) {
	trans_strings, act_strings := task_fsm_wire_slices(status, context.temp_allocator)
	fsm := Task_FSM_Wire{
		allowed_transitions = trans_strings,
		next_states         = trans_strings,
		allowed_actions     = act_strings,
	}
	data, _ := json.marshal(fsm, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	if len(data) >= 2 {
		strings.write_byte(b, ',')
		strings.write_string(b, string(data[1:len(data)-1]))
	}
}

// requested_status is OBSERVATIONAL and optional: pass it only when the caller asked
// for a status the row did not end up holding, and it is emitted alongside the actual
// one so the response cannot imply a change that did not stick. It is a defaulted
// parameter so no existing call site changes, and an additive JSON field so no existing
// consumer breaks. It reports what happened; it never predicts what will happen.
write_task_json :: proc(b: ^strings.Builder, t: domain.Task, requested_status := "") {
	wire := make_simple_task_wire(t, requested_status)
	data, _ := json.marshal(wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	strings.write_string(b, string(data))
}

write_task_detail_json :: proc(b: ^strings.Builder, h: ^Taskchain_Handlers, auth_ctx: contracts.Auth_Context, t: domain.Task, deps: []domain.Task_Dependency, include_description := true) {
	wire := make_task_detail_wire(h, auth_ctx, t, deps, include_description)
	data, _ := json.marshal(wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	strings.write_string(b, string(data))
}

write_member_json :: proc(b: ^strings.Builder, h: ^Taskchain_Handlers, auth: contracts.Auth_Context, m: domain.Task_Chain_Member) {
	wire := make_chain_member_wire(h, auth, m)
	data, _ := json.marshal(wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	strings.write_string(b, string(data))
}

// ---- GET /api/v1/agents/live : project -> live-chains -> agents tree ---------
// One call that powers the sidebar rail. It returns EVERY project (alphabetical
// by name, even with nothing live), and a chain is listed under a project when
// the chain has any member (live or dead) in that project AND the chain has >=1
// RUNNING agent somewhere (chains with no running agent are omitted). Per project
// entry: live_agents = that project's running agents (may be empty for a
// dead-only project); members = the full chain roster (live or not). Each agent
// and member carries its own project_id. "live" mirrors the agent-instance live
// filter (agent_service.runtime_expected_active). Field names/casing reuse the
// existing project / chain-member wire contracts.
Agents_Live_Agent :: struct {
	agent_instance_id: string `json:"agent_instance_id"`,
	display_name:      string `json:"display_name"`,
	is_coordinator:    bool   `json:"is_coordinator"`,
	runtime_status:    string `json:"runtime_status"`,
	activity_status:   string `json:"activity_status"`,
	project_id:        string `json:"project_id"`,
	created_at:        string `json:"created_at"`,
}

Agents_Live_Member :: struct {
	agent_instance_id: string `json:"agent_instance_id"`,
	display_name:      string `json:"display_name"`,
	role:              string `json:"role"`,
	is_coordinator:    bool   `json:"is_coordinator"`,
	is_live:           bool   `json:"is_live"`,
	runtime_status:    string `json:"runtime_status"`,
	project_id:        string `json:"project_id"`,
	created_at:        string `json:"created_at"`,
}

Agents_Live_Chain :: struct {
	chain_id:                      string               `json:"chain_id"`,
	title:                         string               `json:"title"`,
	coordinator_agent_instance_id: string               `json:"coordinator_agent_instance_id"`,
	live_agents:                   []Agents_Live_Agent  `json:"live_agents"`,
	members:                       []Agents_Live_Member `json:"members"`,
	// group_created_at is the per-project ordering key: MIN(created_at) across this
	// chain's members that belong to THIS project (live AND dead). Not serialized;
	// used only to order chain groups within a project. Empty sorts last.
	group_created_at:              string               `json:"-"`,
}

Agents_Live_Project :: struct {
	project_id: string              `json:"project_id"`,
	name:       string              `json:"name"`,
	chains:     []Agents_Live_Chain `json:"chains"`,
}

// Deterministic orderings (user-finalized): chain GROUPS within a project by the
// group's earliest member creation time (empty created_at sorts LAST), tie-break
// chain_id; agents/members oldest-first by created_at, tie-break instance id.
agents_live_created_at_less :: proc(a_created, a_id, b_created, b_id: string) -> bool {
	if a_created != b_created {
		// Empty created_at (unknown) sorts after any known timestamp.
		if a_created == "" do return false
		if b_created == "" do return true
		return a_created < b_created
	}
	return a_id < b_id
}
agents_live_chain_less :: proc(a, b: Agents_Live_Chain) -> bool {
	return agents_live_created_at_less(a.group_created_at, a.chain_id, b.group_created_at, b.chain_id)
}
agents_live_agent_less :: proc(a, b: Agents_Live_Agent) -> bool {
	return agents_live_created_at_less(a.created_at, a.agent_instance_id, b.created_at, b.agent_instance_id)
}
agents_live_member_less :: proc(a, b: Agents_Live_Member) -> bool {
	return agents_live_created_at_less(a.created_at, a.agent_instance_id, b.created_at, b.agent_instance_id)
}

// build_agents_live_tree assembles the projects->live-chains->agents tree from
// already-fetched data. It is kept pure (no services) so it is unit-testable
// without a DB. Inputs:
//   projects          all of the owner's projects
//   chains            all of the owner's chains
//   members_by_chain  chain_id -> its canonical member roster (incl. non-live)
//   instances_by_id   agent_instance_id -> instance (liveness + project + labels)
// Cross-project (Option A): a chain is emitted under EVERY project that has >=1
// of its LIVE agents, and under a given project its live_agents are scoped to
// THAT project's live agents only. members[] on every entry is the FULL chain
// roster (all projects, live + non-live), each carrying its own project_id. A
// chain with no live agent anywhere is omitted. Projects are alphabetical by
// name; a trailing "Unassigned" bucket (project_id "") holds live agents whose
// instance has no resolvable project. String fields are VIEWS into the inputs;
// the JSON serializer copies them out. The returned tree is caller-owned — free
// it with free_agents_live_tree.
build_agents_live_tree :: proc(projects: []domain.Project, chains: []domain.Task_Chain, members_by_chain: map[string][]domain.Task_Chain_Member, instances_by_id: map[string]domain.Agent_Instance) -> []Agents_Live_Project {
	// Per-project buckets of chain entries. Each (chain, project) entry owns fresh
	// live_agents/members slices, so a chain appearing under multiple projects
	// never shares (and thus never double-frees) backing arrays.
	chains_by_project := make(map[string][dynamic]Agents_Live_Chain)
	defer { for _, bkt in chains_by_project do delete(bkt); delete(chains_by_project) }

	for chain in chains {
		members := members_by_chain[string(chain.chain_id)] or_else nil
		// Canonical coordinator (H9): the earliest member with role "coordinator";
		// members come ordered by created_at ASC. Fall back to the derived mirror.
		coordinator_id := chain.coordinator_agent_instance_id
		for m in members {
			if m.role == "coordinator" { coordinator_id = m.agent_instance_id; break }
		}
		// Full roster (members[]), built once and copied into each project entry.
		roster_src := make([dynamic]Agents_Live_Member); defer delete(roster_src)
		// Running agents grouped by their instance.project_id, plus the set of
		// DISTINCT project_ids across ALL members (live+dead) — that set decides which
		// projects the chain is emitted under (placement is member-based, not
		// live-agent-based). has_live gates inclusion: a chain with no running agent
		// anywhere is omitted entirely.
		live_by_project := make(map[string][dynamic]Agents_Live_Agent)
		defer { for _, bkt in live_by_project do delete(bkt); delete(live_by_project) }
		member_project_ids := make(map[string]bool); defer delete(member_project_ids)
		has_live := false
		for m in members {
			inst, has_inst := instances_by_id[m.agent_instance_id]
			live := has_inst && agent_service.runtime_expected_active(inst.runtime_status)
			is_coord := m.agent_instance_id == coordinator_id
			pid := string(inst.project_id) if has_inst else ""
			created_at := inst.created_at if has_inst else ""
			append(&roster_src, Agents_Live_Member{
				agent_instance_id = m.agent_instance_id,
				display_name = inst.display_name if has_inst else "",
				role = m.role,
				is_coordinator = is_coord,
				is_live = live,
				runtime_status = inst.runtime_status if has_inst else "",
				project_id = pid,
				created_at = created_at,
			})
			member_project_ids[pid] = true
			if live {
				has_live = true
				if pid not_in live_by_project do live_by_project[pid] = make([dynamic]Agents_Live_Agent)
				append(&live_by_project[pid], Agents_Live_Agent{
					agent_instance_id = m.agent_instance_id,
					display_name = inst.display_name,
					is_coordinator = is_coord,
					runtime_status = inst.runtime_status,
					activity_status = inst.activity_status,
					project_id = pid,
					created_at = created_at,
				})
			}
		}
		if !has_live do continue // no RUNNING agent anywhere -> omit the chain
		slice.sort_by(roster_src[:], agents_live_member_less)

		// One entry per project that has ANY member (live or dead) of this chain.
		// live_agents is scoped to that project's running agents (may be EMPTY for a
		// dead-only project); members[] is the full (copied) roster. Output order is
		// made deterministic by the project + per-project chain sorts below, so the
		// map iteration order here does not leak.
		for pid in member_project_ids {
			live_dyn, has_here := live_by_project[pid]
			n := len(live_dyn) if has_here else 0
			live_agents := make([]Agents_Live_Agent, n)
			if has_here {
				for a, i in live_dyn do live_agents[i] = a
			}
			slice.sort_by(live_agents, agents_live_agent_less)
			members_copy := make([]Agents_Live_Member, len(roster_src))
			for m, i in roster_src do members_copy[i] = m
			// Group ordering key: earliest created_at among THIS project's members
			// (live or dead). Empty timestamps are ignored unless none are known.
			group_created_at := ""
			for m in roster_src {
				if m.project_id != pid || m.created_at == "" do continue
				if group_created_at == "" || m.created_at < group_created_at do group_created_at = m.created_at
			}
			if pid not_in chains_by_project do chains_by_project[pid] = make([dynamic]Agents_Live_Chain)
			append(&chains_by_project[pid], Agents_Live_Chain{
				chain_id = string(chain.chain_id),
				title = chain.title,
				coordinator_agent_instance_id = coordinator_id,
				live_agents = live_agents,
				members = members_copy,
				group_created_at = group_created_at,
			})
		}
	}

	// Emit ALL projects alphabetically, attaching their live chains; then a
	//    trailing "Unassigned" bucket for live chains with no known project.
	out := make([dynamic]Agents_Live_Project)
	sorted_projects := make([]domain.Project, len(projects)); defer delete(sorted_projects)
	for p, i in projects do sorted_projects[i] = p
	slice.sort_by(sorted_projects, proc(a, b: domain.Project) -> bool {
		if a.name != b.name do return a.name < b.name
		return string(a.project_id) < string(b.project_id)
	})
	matched := make(map[string]bool); defer delete(matched)
	for p in sorted_projects {
		pid := string(p.project_id)
		matched[pid] = true
		bucket := chains_by_project[pid] or_else nil
		if p.state == .Archived {
			for lc in bucket {
				delete(lc.live_agents)
				delete(lc.members)
			}
			continue
		}
		append(&out, Agents_Live_Project{ project_id = pid, name = p.name, chains = agents_live_copy_sorted_chains(bucket[:]) })
	}
	unassigned := make([dynamic]Agents_Live_Chain); defer delete(unassigned)
	for pid, bucket in chains_by_project {
		if matched[pid] do continue
		for lc in bucket do append(&unassigned, lc)
	}
	if len(unassigned) > 0 {
		append(&out, Agents_Live_Project{ project_id = "", name = "Unassigned", chains = agents_live_copy_sorted_chains(unassigned[:]) })
	}
	return out[:]
}

// agents_live_copy_sorted_chains copies a bucket into a fresh owned slice sorted
// by agents_live_chain_less. The copied structs reference the per-entry
// live_agents/members arrays. Ownership stays single: the builder allocates fresh
// live_agents/members for EACH (chain, project) entry, so even a cross-project
// chain (present in multiple buckets) never shares backing arrays across entries.
agents_live_copy_sorted_chains :: proc(bucket: []Agents_Live_Chain) -> []Agents_Live_Chain {
	out := make([]Agents_Live_Chain, len(bucket))
	for c, i in bucket do out[i] = c
	slice.sort_by(out, agents_live_chain_less)
	return out
}

free_agents_live_tree :: proc(tree: []Agents_Live_Project) {
	for p in tree {
		for c in p.chains {
			delete(c.live_agents)
			delete(c.members)
		}
		delete(p.chains)
	}
	delete(tree)
}

write_agents_live_json :: proc(b: ^strings.Builder, tree: []Agents_Live_Project) {
	resp := Agents_Live_Response_Wire{projects = tree}
	data, _ := json.marshal(resp, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	strings.write_string(b, string(data))
}

// agents_live_handler serves GET /api/v1/agents/live. It gathers the owner's
// instances (labels + liveness + project in one query), chains, and projects,
// fetches members only for chains that actually have a live instance (bounded),
// then builds + serializes the tree.
agents_live_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	instances, inst_err := agent_service.list_instances(h.agents, auth_ctx, 2000)
	if inst_err.code != .None do return respond_error(inst_err, req.request_id)
	instances_by_id := make(map[string]domain.Agent_Instance); defer delete(instances_by_id)
	live_chain_ids := make(map[string]bool); defer delete(live_chain_ids)
	for inst in instances {
		instances_by_id[inst.agent_instance_id] = inst
		if inst.chain_id != "" && agent_service.runtime_expected_active(inst.runtime_status) do live_chain_ids[inst.chain_id] = true
	}
	chains, chain_err := taskchain_service.list_chains(h.taskchains, auth_ctx)
	if chain_err.code != .None do return respond_error(chain_err, req.request_id)
	projects: []domain.Project
	if h.projects != nil {
		ps, perr := project_service.list(h.projects, auth_ctx, 500)
		if perr.code != .None do return respond_error(perr, req.request_id)
		projects = ps
	}
	// Members only for chains with a live instance — the only chains that can be
	// emitted — so we avoid fetching rosters for the (often larger) dormant set.
	members_by_chain := make(map[string][]domain.Task_Chain_Member)
	defer { for _, v in members_by_chain do delete(v); delete(members_by_chain) }
	for chain in chains {
		if !live_chain_ids[string(chain.chain_id)] do continue
		members, merr := taskchain_service.list_chain_members(h.taskchains, auth_ctx, chain.chain_id)
		if merr.code != .None do continue
		members_by_chain[string(chain.chain_id)] = members
	}
	tree := build_agents_live_tree(projects, chains, members_by_chain, instances_by_id)
	defer free_agents_live_tree(tree)
	b := strings.builder_make(); write_agents_live_json(&b, tree)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

write_task_vote_json :: proc(b: ^strings.Builder, v: domain.Task_Vote) {
	wire := make_task_vote_wire(v)
	data, _ := json.marshal(wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	strings.write_string(b, string(data))
}

// resolve_comment_author_display returns the display name for a comment's author
// agent instance (MEM-7), mirroring write_member_json: prefer the instance's
// display_name, else the durable agent's name. Empty for user-authored comments
// (no author instance) or when it can't be resolved.
resolve_comment_author_display :: proc(h: ^Taskchain_Handlers, auth: contracts.Auth_Context, c: domain.Task_Comment) -> string {
	if h == nil || h.agents == nil do return ""
	if strings.trim_space(c.author_agent_instance_id) == "" do return ""
	display_name := ""
	agent_id := ""
	if inst, inst_ok, _ := agent_service.get_instance(h.agents, auth, c.author_agent_instance_id); inst_ok {
		display_name = inst.display_name
		agent_id = inst.agent_id
	}
	if strings.trim_space(display_name) == "" && strings.trim_space(agent_id) != "" {
		if agent, agent_ok, _ := agent_service.get_agent(h.agents, auth, agent_id); agent_ok {
			display_name = agent.name
		}
	}
	return display_name
}

// write_task_comment_json emits a comment. MEM-7: it also carries the resolved
// author_display_name so UI clients never pay an extra per-comment lookup.
write_task_comment_json :: proc(b: ^strings.Builder, c: domain.Task_Comment, author_display_name: string) {
	wire := make_task_comment_wire(c, author_display_name)
	data, _ := json.marshal(wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	strings.write_string(b, string(data))
}

// write_task_comment_summary_json emits the compact comment rollup embedded on
// tasks. MEM-8: replaces the old comment_count int with a rich preview.
write_task_comment_summary_json :: proc(b: ^strings.Builder, s: domain.Task_Comment_Summary) {
	wire := make_task_comment_summary_wire(s)
	data, _ := json.marshal(wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	strings.write_string(b, string(data))
}

write_task_comment_response_json :: proc(b: ^strings.Builder, c: domain.Task_Comment, author_display_name: string, notified: []string) {
	wire := make_task_comment_response_wire(c, author_display_name, notified)
	data, _ := json.marshal(wire, JSON_MARSHAL_OPT, allocator = context.temp_allocator)
	strings.write_string(b, string(data))
}

json_array_of_strings_raw :: proc(body: string, key: string, allocator := context.allocator) -> []string {
	dyn := jsonx.extract_string_array(body, key, false, allocator)
	return dyn[:]
}

path_part :: proc(path: string, index: int) -> string {
	parts := strings.split(path, "/"); defer delete(parts)
	if index < 0 || index >= len(parts) do return ""
	return parts[index]
}

publish_state_http :: proc(state: domain.Publish_State) -> string { if state == .Published do return "published"; return "draft" }
chain_status_http :: proc(status: domain.Task_Chain_Status) -> string { if status == .Completed do return "completed"; if status == .Cancelled do return "cancelled"; if status == .Archived do return "archived"; return "active" }
task_status_http :: proc(status: domain.Task_Status) -> string { switch status { case .Assigned: return "assigned"; case .Queued: return "queued"; case .In_Progress: return "in_progress"; case .In_Validation: return "in_validation"; case .Finishing: return "finishing"; case .Pausing: return "pausing"; case .Validated_Good: return "validated_good"; case .Validated_Not_Good: return "validated_not_good"; case .Paused: return "paused"; case .Completed: return "completed"; case .Cancelled: return "cancelled" }; return "assigned" }
task_status_from_http :: proc(status: string) -> (domain.Task_Status, bool) { if status == "assigned" do return .Assigned, true; if status == "queued" do return .Queued, true; if status == "in_progress" do return .In_Progress, true; if status == "in_validation" do return .In_Validation, true; if status == "finishing" do return .Finishing, true; if status == "pausing" do return .Pausing, true; if status == "validated_good" do return .Validated_Good, true; if status == "validated_not_good" do return .Validated_Not_Good, true; if status == "paused" do return .Paused, true; if status == "completed" do return .Completed, true; if status == "cancelled" do return .Cancelled, true; return .Assigned, false }


json_or_empty_array :: proc(value: string) -> string { if strings.trim_space(value) == "" do return "[]"; return value }
json_or_empty_object :: proc(value: string) -> string { if strings.trim_space(value) == "" do return "{}"; return value }
json_array_optional :: proc(body, key: string, allocator := context.allocator) -> string {
	res, ok := jsonx.extract_raw_array(body, key, false, allocator)
	if !ok do return ""
	return res
}
json_object_or_empty :: proc(body, key: string, allocator := context.allocator) -> string {
	res, ok := jsonx.extract_raw_object(body, key, false, allocator)
	if !ok do return ""
	return res
}
json_object_raw :: proc(body, key: string, allocator := context.allocator) -> string {
	res, ok := jsonx.extract_raw_object(body, key, false, allocator)
	if !ok do return ""
	return res
}
task_matches_query :: proc(task: domain.Task, query: string) -> bool {
	assignee := query_value(query, "assignee_agent_instance_id")
	if assignee != "" {
		refs, _, ok := taskchain_service.parse_actor_refs(task.assignee_ref_json, context.temp_allocator)
		if !ok do return false
		matched := false
		for r in refs {
			if r.agent_instance_id == assignee {
				matched = true
				break
			}
		}
		if !matched do return false
	}

	reviewer := query_value(query, "reviewer_agent_instance_id")
	reviewer_user := query_value(query, "reviewer_user_id")
	if reviewer != "" || reviewer_user != "" {
		refs, _, ok := taskchain_service.parse_actor_refs(task.reviewer_refs_json, context.temp_allocator)
		if !ok do return false
		if reviewer != "" {
			matched := false
			for r in refs {
				if r.agent_instance_id == reviewer {
					matched = true
					break
				}
			}
			if !matched do return false
		}
		if reviewer_user != "" {
			matched := false
			for r in refs {
				if r.user_id == reviewer_user {
					matched = true
					break
				}
			}
			if !matched do return false
		}
	}

	return true
}

// require_task_path_scope validates that the task exists, is owned by the caller,
// and lives in the chain named in the path. It is a PATH-CONSISTENCY + ownership
// precheck only — it uses the owner-scoped read authorizer (REQ-SEC-3), NOT the
// membership gate, so read handlers work for same-owner non-members. Write
// handlers that call this still enforce membership/coordinator at the service
// layer (create_task/update_task/change_task_status/comment_task/record_task_vote/
// manual_nudge/set_instance_current_task each guard independently).
require_task_path_scope :: proc(h: ^Taskchain_Handlers, auth_ctx: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, task_id: domain.Task_ID, req: Request) -> (bool, Response) {
	task, ok, err := taskchain_service.get_task_for_read(h.taskchains, auth_ctx, task_id)
	if !ok do return false, respond_error(err, req.request_id)
	if task.chain_id != chain_id do return false, respond_error(domain.domain_error(.Not_Found, "task not found in chain"), req.request_id)
	return true, Response{}
}

json_array_of_strings :: proc(body: string, key: string, allocator := context.allocator) -> []domain.Task_ID {
	dyn := jsonx.extract_string_array(body, key, false, allocator)
	defer delete(dyn)
	if len(dyn) == 0 do return nil
	res := make([]domain.Task_ID, len(dyn), allocator)
	for s, i in dyn {
		res[i] = domain.Task_ID(s)
	}
	return res
}
