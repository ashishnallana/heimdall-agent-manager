package http

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskchain_service "odin_test:hub/service/taskchain"
import taskv2 "odin_test:hub/service/taskv2"
import jsonx "odin_test:lib/jsonx"

mixed_wire_json :: proc(value: any) -> string {
	data, err := json.marshal(value, allocator = context.temp_allocator)
	if err != nil do return "{}"
	return string(data)
}

mixed_item :: proc(body, key: string) -> domain.Work_Item_Ref {
	object, _ := jsonx.extract_raw_object(body, key, true, context.temp_allocator)
	return domain.Work_Item_Ref{kind = json_string(object, "kind"), id = json_string(object, "id")}
}

extract_workflow_run_input :: proc(body: string) -> (taskv2.Workflow_Run_Input, bool, domain.Domain_Error) {
	value, err := json.parse(body, allocator = context.temp_allocator)
	if err != nil do return {},false,domain.domain_error(.Validation_Failed,"workflow run requires a JSON object")
	object, ok := value.(json.Object)
	if !ok do return {},false,domain.domain_error(.Validation_Failed,"workflow run requires a JSON object")
	for key in object {
		if key != "ref" && key != "title" && key != "inputs" && key != "request_id" && key != "prerequisites" && key != "chain_id" {
			return {},false,domain.domain_error(.Validation_Failed,fmt.tprintf("unknown workflow run field: %s",key))
		}
	}
	inputs := "{}"
	if field, present := object["inputs"]; present {
		if _, is_object := field.(json.Object); !is_object do return {},false,domain.domain_error(.Validation_Failed,"inputs must be an object")
		inputs = mixed_wire_json(field)
	}
	prerequisites := make([dynamic]domain.Work_Item_Ref,context.temp_allocator)
	if field,present := object["prerequisites"]; present {
		array,is_array := field.(json.Array)
		if !is_array do return {},false,domain.domain_error(.Validation_Failed,"prerequisites must be an array")
		for item in array {
			entry,is_object := item.(json.Object)
			if !is_object do return {},false,domain.domain_error(.Validation_Failed,"prerequisites must contain work references")
			kind,kok := entry["kind"].(json.String); id,iok := entry["id"].(json.String)
			if !kok || !iok do return {},false,domain.domain_error(.Validation_Failed,"work reference requires kind and id")
			append(&prerequisites,domain.Work_Item_Ref{kind=string(kind),id=string(id)})
		}
	}
	return taskv2.Workflow_Run_Input{chain_id=json_string(body,"chain_id"),ref=json_string(body,"ref"),title=json_string(body,"title"),inputs_json=inputs,request_id=json_string(body,"request_id"),prerequisites=prerequisites[:]},true,domain.Domain_Error{}
}

workflow_run_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth, ok, resp := require_auth_any(h.auth, req)
	if !ok do return resp
	input, valid, input_err := extract_workflow_run_input(req.body)
	if !valid do return respond_error(input_err,req.request_id)
	input.chain_id = path_part(req.path, 4)
	run, saved, err := taskv2.workflow_run(h.task_engine, domain.User_ID(auth.user_id), taskv2.actor_from_auth(auth), input)
	if !saved do return respond_error(err, req.request_id)
	status, sok, serr := taskv2.workflow_status_json(h.task_engine, run.run_id, run.owner_user_id)
	if !sok do return respond_error(serr, req.request_id)
	return respond_success(status, req.request_id, auth_ctx_server_time(req), 201)
}

workflow_runs_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth, ok, resp := require_auth_any(h.auth, req)
	if !ok do return resp
	cid := domain.Task_Chain_ID(path_part(req.path, 4))
	if _, ok, err := taskchain_service.get_chain(h.taskchains, auth, cid); !ok do return respond_error(err, req.request_id)
	body, saved, err := taskv2.workflow_list_json(h.task_engine, cid, domain.User_ID(auth.user_id))
	if !saved do return respond_error(err, req.request_id)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

workflow_status_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth, ok, resp := require_auth_any(h.auth, req)
	if !ok do return resp
	if err := workflow_read_access(h.task_engine, h.taskchains, auth, domain.Workflow_Run_ID(path_part(req.path, 4))); err.code != .None do return respond_error(err, req.request_id)
	no, _ := strconv.parse_int(query_value(req.query, "execution_no"))
	body, saved, err := taskv2.workflow_status_json(h.task_engine, domain.Workflow_Run_ID(path_part(req.path, 4)), domain.User_ID(auth.user_id), no)
	if !saved do return respond_error(err, req.request_id)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

workflow_output_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth, ok, resp := require_auth_any(h.auth, req)
	if !ok do return resp
	if err := workflow_read_access(h.task_engine, h.taskchains, auth, domain.Workflow_Run_ID(path_part(req.path, 4))); err.code != .None do return respond_error(err, req.request_id)
	no, _ := strconv.parse_int(query_value(req.query, "execution_no"))
	body, saved, err := taskv2.workflow_stage_output_json(h.task_engine, domain.Workflow_Run_ID(path_part(req.path, 4)), domain.User_ID(auth.user_id), query_value(req.query, "stage_key"), no)
	if !saved do return respond_error(err, req.request_id)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

workflow_history_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth, ok, resp := require_auth_any(h.auth, req)
	if !ok do return resp
	if err := workflow_read_access(h.task_engine, h.taskchains, auth, domain.Workflow_Run_ID(path_part(req.path, 4))); err.code != .None do return respond_error(err, req.request_id)
	run_id := domain.Workflow_Run_ID(path_part(req.path, 4))
	if _, ok, err := taskv2.workflow_context(h.task_engine, run_id, domain.User_ID(auth.user_id)); !ok do return respond_error(err, req.request_id)
	executions, err := iface.taskchain_list_workflow_executions(h.task_engine.repo, run_id, domain.User_ID(auth.user_id))
	if err.code != .None do return respond_error(err, req.request_id)
	events, events_err := iface.taskchain_list_workflow_run_events(h.task_engine.repo, run_id, domain.User_ID(auth.user_id))
 if events_err.code != .None do return respond_error(events_err, req.request_id)
 return respond_success(fmt.tprintf(`{{"executions":%s,"events":%s}}`, mixed_wire_json(executions), mixed_wire_json(events)), req.request_id, auth_ctx_server_time(req))
}

workflow_retry_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth, ok, resp := require_auth_any(h.auth, req)
	if !ok do return resp
	if err := workflow_retry_fields(req.body); err.code != .None do return respond_error(err, req.request_id)
	run, saved, err := taskv2.workflow_retry(h.task_engine, domain.Workflow_Run_ID(path_part(req.path, 4)), domain.User_ID(auth.user_id), taskv2.actor_from_auth(auth), json_string(req.body, "reason"), i64(jsonx.extract_int(req.body, "expected_revision", 0, true)))
	if !saved do return respond_error(err, req.request_id)
	body, _, _ := taskv2.workflow_status_json(h.task_engine, run.run_id, run.owner_user_id)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

workflow_retry_fields :: proc(body: string) -> domain.Domain_Error {
	value, err := json.parse(body, allocator = context.temp_allocator)
	if err != nil do return domain.domain_error(.Validation_Failed, "retry requires a JSON object")
	object, ok := value.(json.Object)
	if !ok do return domain.domain_error(.Validation_Failed, "retry requires a JSON object")
	for key in object {
		if key != "reason" && key != "expected_revision" && key != "run_id" {
			return domain.domain_error(.Validation_Failed, "retry applies to the whole run; only reason and expected_revision are accepted")
		}
	}
	return domain.Domain_Error{}
}

workflow_cancel_fields :: proc(body: string) -> domain.Domain_Error {
 value, err := json.parse(body, allocator = context.temp_allocator)
 if err != nil do return domain.domain_error(.Validation_Failed, "cancel body must be a JSON object")
 object, valid := value.(json.Object)
 if !valid do return domain.domain_error(.Validation_Failed, "cancel body must be a JSON object")
 for key in object {
  if key != "run_id" && key != "execution_no" && key != "reason" do return domain.domain_error(.Validation_Failed, "cancel accepts only run_id, execution_no and reason")
 }
 return domain.Domain_Error{}
}

workflow_cancel_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth, ok, resp := require_auth_any(h.auth, req)
	if !ok do return resp
	if err := workflow_cancel_fields(req.body); err.code != .None do return respond_error(err, req.request_id)
	run, saved, err := taskv2.workflow_cancel(h.task_engine, domain.Workflow_Run_ID(path_part(req.path, 4)), domain.User_ID(auth.user_id), taskv2.actor_from_auth(auth), json_string(req.body, "reason"), jsonx.extract_int(req.body, "execution_no", 0, true))
	if !saved do return respond_error(err, req.request_id)
	body, _, _ := taskv2.workflow_status_json(h.task_engine, run.run_id, run.owner_user_id)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

mixed_work_dispatch :: proc(svc: ^taskv2.Service, chains: ^taskchain_service.Taskchain_Service, auth: contracts.Auth_Context, cid: domain.Task_Chain_ID, action, body: string) -> (string, bool, domain.Domain_Error) {
	chain, ok, err := taskchain_service.get_chain(chains, auth, cid)
	if !ok do return "", false, err
	owner := chain.owner_user_id
	actor := taskv2.actor_from_auth(auth)
	switch action {
	case "graph":
		edges, err := iface.taskchain_list_work_dependencies(svc.repo, cid, owner)
		if err.code != .None do return "", false, err
		scope, serr := iface.taskchain_list_work_scope_decisions(svc.repo, cid, owner)
		if serr.code != .None do return "", false, serr
		return fmt.tprintf(`{{"dependencies":%s,"scope_decisions":%s,"work_revision":%d,"completion_summary":%s}}`, mixed_wire_json(edges), mixed_wire_json(scope), chain.work_revision, mixed_wire_json(chain.completion_summary)), true, domain.Domain_Error{}
	case "depend":
		edge, ok, err := taskv2.work_dependency_add(svc, owner, actor, cid, mixed_item(body, "dependent"), mixed_item(body, "prerequisite"))
		return mixed_wire_json(edge), ok, err
	case "remove-dependency":
		ok, err := taskv2.work_dependency_remove(svc, owner, actor, cid, json_string(body, "dependency_id"), json_string(body, "reason"))
		return `{"removed":true}`, ok, err
	case "scope":
		decision, ok, err := taskv2.work_scope_decide(svc, owner, actor, cid, mixed_item(body, "item"), json_string(body, "action"), json_string(body, "reason"))
		return mixed_wire_json(decision), ok, err
	case "complete":
		completed, ok, err := taskchain_service.complete_chain(chains, auth, cid, i64(jsonx.extract_int(body, "expected_work_revision", -1, true)), json_string(body, "summary"))
		if !ok do return "", false, err
		b := strings.builder_make(context.temp_allocator); write_chain_json(&b, completed)
		return strings.to_string(b), true, domain.Domain_Error{}
	}
	return "", false, domain.domain_error(.Validation_Failed, "unknown work action")
}

mixed_work_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth, ok, resp := require_auth_any(h.auth, req)
	if !ok do return resp
	body, saved, err := mixed_work_dispatch(h.task_engine, h.taskchains, auth, domain.Task_Chain_ID(path_part(req.path, 4)), path_part(req.path, 6), req.body)
	if !saved do return respond_error(err, req.request_id)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

agent_action_work_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := verbatim_params(req.body)
	action := path_part(req.path, 5)
	cid := json_string(params, "chain_id")
	if cid == "" {
		// Completing a chain is destructive: require an explicit chain id rather
		// than defaulting to the calling instance's chain.
		if action == "complete" do return respond_error(domain.domain_error(.Validation_Failed, "chain_id is required to complete a chain"), req.request_id)
		cid = inst.chain_id
	}
	body, saved, err := mixed_work_dispatch(h.task_engine, h.taskchains, auth, domain.Task_Chain_ID(cid), action, params)
	if !saved do return respond_error(err, req.request_id)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

agent_action_workflow_run_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := verbatim_params(req.body)
	input, valid, input_err := extract_workflow_run_input(params)
	if !valid do return respond_error(input_err,req.request_id)
	if input.chain_id == "" do input.chain_id = inst.chain_id
	run, saved, err := taskv2.workflow_run(h.task_engine, inst.owner_user_id, taskv2.actor_from_auth(auth), input)
	if !saved do return respond_error(err, req.request_id)
	body, _, _ := taskv2.workflow_status_json(h.task_engine, run.run_id, inst.owner_user_id)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

agent_action_workflow_status_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := verbatim_params(req.body)
	if err := workflow_read_access(h.task_engine, h.taskchains, auth, domain.Workflow_Run_ID(json_string(params, "run_id"))); err.code != .None do return respond_error(err, req.request_id)
	if json_string(params, "run_id") == "" do return respond_error(domain.domain_error(.Validation_Failed, "run_id is required"), req.request_id)
	body, saved, err := taskv2.workflow_status_json(h.task_engine, domain.Workflow_Run_ID(json_string(params, "run_id")), inst.owner_user_id, jsonx.extract_int(params, "execution_no", 0, true))
	if !saved do return respond_error(err, req.request_id)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

agent_action_workflow_runs_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := verbatim_params(req.body)
	cid := json_string(params, "chain_id"); if cid == "" do cid = inst.chain_id
	if _, allowed, err := taskchain_service.get_chain(h.taskchains, auth, domain.Task_Chain_ID(cid)); !allowed do return respond_error(err, req.request_id)
	body, saved, err := taskv2.workflow_list_json(h.task_engine, domain.Task_Chain_ID(cid), inst.owner_user_id)
	if !saved do return respond_error(err, req.request_id)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

agent_action_workflow_output_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := verbatim_params(req.body)
	if err := workflow_read_access(h.task_engine, h.taskchains, auth, domain.Workflow_Run_ID(json_string(params, "run_id"))); err.code != .None do return respond_error(err, req.request_id)
	body, saved, err := taskv2.workflow_stage_output_json(h.task_engine, domain.Workflow_Run_ID(json_string(params, "run_id")), inst.owner_user_id, json_string(params, "stage_key"), jsonx.extract_int(params, "execution_no", 0, true))
	if !saved do return respond_error(err, req.request_id)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

agent_action_workflow_retry_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := verbatim_params(req.body)
	if err := workflow_retry_fields(params); err.code != .None do return respond_error(err, req.request_id)
	run, saved, err := taskv2.workflow_retry(h.task_engine, domain.Workflow_Run_ID(json_string(params, "run_id")), inst.owner_user_id, taskv2.actor_from_auth(auth), json_string(params, "reason"), i64(jsonx.extract_int(params, "expected_revision", 0, true)))
	if !saved do return respond_error(err, req.request_id)
	body, _, _ := taskv2.workflow_status_json(h.task_engine, run.run_id, inst.owner_user_id)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

agent_action_workflow_cancel_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Agent_Action_Handlers)(ctx)
	auth, inst, ok, resp := require_instance_action_auth(h, req)
	if !ok do return resp
	params := verbatim_params(req.body)
	if err := workflow_cancel_fields(params); err.code != .None do return respond_error(err, req.request_id)
	run, saved, err := taskv2.workflow_cancel(h.task_engine, domain.Workflow_Run_ID(json_string(params, "run_id")), inst.owner_user_id, taskv2.actor_from_auth(auth), json_string(params, "reason"), jsonx.extract_int(params, "execution_no", 0, true))
	if !saved do return respond_error(err, req.request_id)
	body, _, _ := taskv2.workflow_status_json(h.task_engine, run.run_id, inst.owner_user_id)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

agent_action_workflow_history_handler :: proc(ctx: rawptr, req: Request) -> Response {
 h := (^Agent_Action_Handlers)(ctx)
 auth, inst, ok, resp := require_instance_action_auth(h, req)
 if !ok do return resp
 params := verbatim_params(req.body)
 run_id := domain.Workflow_Run_ID(json_string(params, "run_id"))
 wf, found, err := taskv2.workflow_context(h.task_engine, run_id, inst.owner_user_id)
 if !found do return respond_error(err, req.request_id)
 if _, allowed, err := taskchain_service.get_chain(h.taskchains, auth, wf.chain_id); !allowed do return respond_error(err, req.request_id)
 executions, history_err := iface.taskchain_list_workflow_executions(h.task_engine.repo, run_id, inst.owner_user_id)
 if history_err.code != .None do return respond_error(history_err, req.request_id)
 events, events_err := iface.taskchain_list_workflow_run_events(h.task_engine.repo, run_id, inst.owner_user_id)
 if events_err.code != .None do return respond_error(events_err, req.request_id)
 return respond_success(fmt.tprintf(`{{"executions":%s,"events":%s}}`, mixed_wire_json(executions), mixed_wire_json(events)), req.request_id, auth_ctx_server_time(req))
}

workflow_read_access :: proc(svc: ^taskv2.Service, chains: ^taskchain_service.Taskchain_Service, auth: contracts.Auth_Context, run_id: domain.Workflow_Run_ID) -> domain.Domain_Error {
 wf, ok, err := taskv2.workflow_context(svc, run_id, domain.User_ID(auth.user_id))
 if !ok do return err
 if _, allowed, err := taskchain_service.get_chain(chains, auth, wf.chain_id); !allowed do return err
 return domain.Domain_Error{}
}
