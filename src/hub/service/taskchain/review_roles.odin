package taskchain

import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskv2 "odin_test:hub/service/taskv2"
import jsonx "odin_test:lib/jsonx"

// Chain review roles (hybrid review model). Roles are an optional layer for
// templates and coordinators: a role has a description (what it checks, handed
// to the reviewer in its pack) and its members are the fleet rows that hold it.
// Descriptions live in chain.defaults_json.review_roles.<name>.description.

Review_Role_Info :: struct {
	name:            string   `json:"name"`,
	description:     string   `json:"description"`,
	// agent template ids whose fleet row holds the role
	holders:         []string `json:"holders"`,
	// open (not done/cancelled) tasks whose brief requires the role
	open_task_count: int      `json:"open_task_count"`,
}

review_role_reserved :: proc(name: string) -> bool {
	return name == domain.FLEET_ROLE_WORKER || name == taskv2.FLEET_ROLE_NAMED_REVIEWER || name == taskv2.NAMED_REVIEW_ROLE
}

// list_review_roles: described roles ∪ roles held on fleet rows ∪ "reviewer".
list_review_roles :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID) -> ([]Review_Role_Info, domain.Domain_Error) {
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return nil, err
	fleets, ferr := iface.taskchain_list_fleets_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if ferr.code != .None do return nil, ferr
	tasks, terr := iface.taskchain_list_tasks_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if terr.code != .None do return nil, terr

	names := make([dynamic]string, context.temp_allocator)
	add :: proc(names: ^[dynamic]string, n: string) {
		if n == "" || review_role_reserved(n) do return
		for x in names^ do if x == n do return
		append(names, n)
	}
	add(&names, domain.FLEET_ROLE_REVIEWER)
	if roles_obj, rok := jsonx.extract_raw_object(chain.defaults_json, "review_roles", true, context.temp_allocator); rok {
		if parsed, perr := json.parse_string(roles_obj, allocator = context.temp_allocator); perr == nil {
			if obj, is_obj := parsed.(json.Object); is_obj do for k in obj do add(&names, k)
		}
	}
	for f in fleets do for r in jsonx.decode_string_array(f.roles_json, context.temp_allocator) do add(&names, r)

	out := make([dynamic]Review_Role_Info, context.temp_allocator)
	for n in names {
		info := Review_Role_Info{name = n, description = taskv2.review_role_description(chain.defaults_json, n)}
		holders := make([dynamic]string, context.temp_allocator)
		for f in fleets do if fleet_has_role(f, n) do append(&holders, f.agent_id)
		info.holders = holders[:]
		for t in tasks {
			if t.state == .Done || t.state == .Cancelled do continue
			for r in taskv2.brief_review_roles(t.brief_json, context.temp_allocator) do if r == n { info.open_task_count += 1; break }
		}
		append(&out, info)
	}
	return out[:], domain.Domain_Error{}
}

// set_review_role creates a role or changes its description.
set_review_role :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, name, description: string) -> domain.Domain_Error {
	n := strings.trim_space(name)
	if !domain.fleet_role_name_valid(n) || review_role_reserved(n) {
		return domain.domain_error(.Validation_Failed, "review role names are 1-32 chars of a-z, 0-9, _ or -, starting with a letter (not worker / named)")
	}
	if len(description) > 1000 do return domain.domain_error(.Validation_Failed, "a role description is at most 1000 characters")
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return err
	return write_review_role_description(service, chain, n, strings.trim_space(description), false)
}

// delete_review_role removes a role: refused while an open task requires it;
// otherwise its description goes and every fleet row drops the role (a row left
// with no role is removed).
delete_review_role :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, name: string) -> domain.Domain_Error {
	v := verb_begin(service)
	err := delete_review_role_impl(service, auth, chain_id, name)
	if cerr := verb_end(&v, err.code == .None); cerr.code != .None do return cerr
	return err
}

@(private = "file")
delete_review_role_impl :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, name: string) -> domain.Domain_Error {
	n := strings.trim_space(name)
	chain, ok, err := get_chain(service, auth, chain_id)
	if !ok do return err
	tasks, terr := iface.taskchain_list_tasks_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if terr.code != .None do return terr
	blocking := make([dynamic]string, context.temp_allocator)
	for t in tasks {
		if t.state == .Done || t.state == .Cancelled do continue
		for r in taskv2.brief_review_roles(t.brief_json, context.temp_allocator) do if r == n { append(&blocking, t.title); break }
	}
	if len(blocking) > 0 {
		return domain.domain_error(.Conflict, strings.concatenate({"open tasks still require this role: ", strings.join(blocking[:], ", ", context.temp_allocator)}, context.temp_allocator))
	}
	if werr := write_review_role_description(service, chain, n, "", true); werr.code != .None do return werr
	fleets, ferr := iface.taskchain_list_fleets_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if ferr.code != .None do return ferr
	for f in fleets {
		if !fleet_has_role(f, n) do continue
		kept := make([dynamic]string, context.temp_allocator)
		for r in jsonx.decode_string_array(f.roles_json, context.temp_allocator) do if r != n do append(&kept, r)
		if len(kept) == 0 {
			if _, derr := delete_fleet_impl(service, auth, chain.chain_id, f.agent_id); derr.code != .None do return derr
			continue
		}
		if _, uerr := upsert_fleet_impl(service, auth, Upsert_Fleet_Input{
			chain_id = chain.chain_id, agent_id = f.agent_id, capacity = f.capacity, min_warm = f.min_warm,
			idle_ttl_seconds = f.idle_ttl_seconds, provider = f.provider, model = f.model,
			bridge_models_json = f.bridge_models_json, roles = kept[:], has_roles = true,
		}); uerr.code != .None do return uerr
	}
	return domain.Domain_Error{}
}

// write_review_role_description edits defaults_json.review_roles, keeping every
// other defaults key (e.g. a pending chain proposal) as it was.
@(private = "file")
write_review_role_description :: proc(service: ^Taskchain_Service, chain_in: domain.Task_Chain, name, description: string, remove: bool) -> domain.Domain_Error {
	chain := chain_in
	defaults := chain.defaults_json if strings.has_prefix(strings.trim_space(chain.defaults_json), "{") else "{}"
	parsed, perr := json.parse_string(defaults, allocator = context.temp_allocator)
	if perr != nil do return domain.domain_error(.Internal_Error, "chain defaults are not valid JSON")
	root, is_obj := parsed.(json.Object)
	if !is_obj do root = make(json.Object, allocator = context.temp_allocator)
	roles: json.Object
	if existing, has := root["review_roles"]; has {
		if eobj, eok := existing.(json.Object); eok do roles = eobj
	}
	if roles == nil do roles = make(json.Object, allocator = context.temp_allocator)
	if remove {
		delete_key(&roles, name)
	} else {
		entry := make(json.Object, allocator = context.temp_allocator)
		entry["description"] = json.String(description)
		roles[name] = entry
	}
	root["review_roles"] = roles
	data, merr := json.marshal(root, allocator = context.temp_allocator)
	if merr != nil do return domain.domain_error(.Internal_Error, "could not encode chain defaults")
	chain.defaults_json = string(data)
	if _, sok, serr := iface.taskchain_save_chain(service.repo, chain); !sok do return serr
	return domain.Domain_Error{}
}
