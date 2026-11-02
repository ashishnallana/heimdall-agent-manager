package http

import "core:encoding/json"
import "core:fmt"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import project_service "odin_test:hub/service/project"
import provider_service "odin_test:hub/service/provider"

// Same public provider endpoint, explicit second stage. The client cannot widen
// the filter: provider presence and user enablement come only from durable state.
bridge_provider_models_refresh_response :: proc(h: ^Provider_Handlers, req: Request, bridge: domain.Bridge) -> Response {
	views, view_err := provider_service.list_bridge_providers(h.providers,bridge.bridge_id)
	if view_err.code != .None do return respond_error(view_err,req.request_id)
	defer provider_service.bridge_provider_views_destroy(views)
 profile_id:=json_string(req.body,"profile_id");defer delete(profile_id)
 selected:=make([dynamic]provider_service.Bridge_Provider_View,context.temp_allocator)
 for v in views {
  if (profile_id=="" && v.profile_id!=v.catalog.provider) || (profile_id!="" && v.profile_id!=profile_id) do continue
  append(&selected,v)
 }
 providers := provider_service.model_discovery_providers(selected[:],context.temp_allocator)
	if len(providers)==0 do return bridge_provider_status_response(h,bridge.bridge_id,req.request_id,auth_ctx_server_time(req))
	request_id := fmt.tprintf("pmr_%d",time.to_unix_nanoseconds(time.now()))
	command, encode_err := json.marshal(struct{
		type: string `json:"type"`,
		request_id: string `json:"request_id"`,
		providers: []string `json:"providers"`,
		profile_id: string `json:"profile_id"`,
	}{"provider_models_discover",request_id,providers[:],profile_id},allocator=context.temp_allocator)
	if encode_err!=nil do return respond_error(domain.domain_error(.Internal_Error,"cannot encode model request"),req.request_id)
	reply, reply_ok, reply_err := bridge_runtime_service.send_runtime_command_wait(
		h.bridge_runtime_registry,
		project_service.Runtime_Command{bridge_id=bridge.bridge_id,command_id=request_id,body_json=string(command)},
		30000,
	)
	if !reply_ok {
		state := provider_models_failure_state(reply_err.code,reply_err.cause)
		now := platform.clock_now(h.clock); defer delete(now)
		if err := provider_models_record_failure(h.providers,bridge.bridge_id,providers[:],state,now,profile_id); err.code!=.None do return respond_error(err,req.request_id)
		publish_bridge_provider_status_changed(h.event_bus,string(bridge.owner_user_id),bridge.bridge_id,"")
		return bridge_provider_status_response(h,bridge.bridge_id,req.request_id,auth_ctx_server_time(req))
	}
	defer delete(reply)
	now := platform.clock_now(h.clock); defer delete(now)
	apply_err := provider_models_apply_reply(h.providers,bridge.bridge_id,request_id,providers[:],reply,now,profile_id)
	if apply_err.code==.Validation_Failed || apply_err.code==.Forbidden {
		if err := provider_models_record_failure(h.providers,bridge.bridge_id,providers[:],"invalid_response",now,profile_id); err.code!=.None do return respond_error(err,req.request_id)
	} else if apply_err.code!=.None {
		return respond_error(apply_err,req.request_id)
	}
	publish_bridge_provider_status_changed(h.event_bus,string(bridge.owner_user_id),bridge.bridge_id,"")
	return bridge_provider_status_response(h,bridge.bridge_id,req.request_id,auth_ctx_server_time(req))
}

provider_models_record_failure :: proc(service: ^provider_service.Provider_Service,bridge_id: string,providers: []string,state,attempted: string,profile_id:string = "") -> domain.Domain_Error {
	items:=make([]provider_service.Model_Discovery_Item,len(providers),context.temp_allocator)
	for p,i in providers do items[i]={provider=p,profile_id=domain.profile_effective_id(p,profile_id),models_state=state,models_attempted_at=attempted}
	return provider_service.apply_model_discovery_report(service,bridge_id,providers,items,profile_id,false)
}
// Correlation is mandatory; unsolicited frames never enter the model store.
provider_models_apply_reply :: proc(service: ^provider_service.Provider_Service,bridge_id,request_id: string,providers: []string,reply,attempted: string,profile_id:string = "") -> domain.Domain_Error {
	report: struct{
		type: string `json:"type"`,
		request_id: string `json:"request_id"`,
		command_id: string `json:"command_id"`,
		providers: []provider_service.Model_Discovery_Item `json:"providers"`,
	}
	if json.unmarshal_string(reply,&report,allocator=context.temp_allocator)!=nil do return domain.domain_error(.Validation_Failed,"malformed model report")
	if report.type=="command_result" && report.command_id==request_id {
		state:="error"
		if werr,found:=contracts.wire_error_parse(reply,context.temp_allocator); found do state=provider_models_failure_state(werr.code,werr.cause)
		return provider_models_record_failure(service,bridge_id,providers,state,attempted,profile_id)
	}
	if report.type!="provider_model_discovery_report" || report.request_id!=request_id || report.command_id!=request_id do return domain.domain_error(.Validation_Failed,"uncorrelated model report")
	raw,parse_err:=json.parse_string(reply,json.DEFAULT_SPECIFICATION,true,context.temp_allocator)
	if parse_err!=.None do return domain.domain_error(.Validation_Failed,"malformed model report")
	root,is_object:=raw.(json.Object)
	if !is_object do return domain.domain_error(.Validation_Failed,"model report must be an object")
	raw_items,is_array:=root["providers"].(json.Array)
	if !is_array || len(raw_items)!=len(report.providers) do return domain.domain_error(.Validation_Failed,"model providers must be an array")
	for item,i in report.providers {
		if !item.has_snapshot do continue
		object,ok:=raw_items[i].(json.Object)
		if !ok do return domain.domain_error(.Validation_Failed,"model snapshot must be an object")
		_,models_present:=object["models"].(json.Array)
		if !models_present do return domain.domain_error(.Validation_Failed,"model snapshot must contain an explicit models array")
	}
	return provider_service.apply_model_discovery_report(service,bridge_id,providers,report.providers,profile_id)
}

provider_models_failure_state :: proc(code: domain.Error_Code,cause: string) -> string {
	switch cause {
	case "unknown_command","unsupported_command": return "unsupported"
	case "queue_full","queue_overflow","busy","bridge_busy": return "busy"
	case "deadline_exceeded","command_timeout": return "timeout"
	}
	return "timeout" if code==.Bridge_Timeout else "error"
}
