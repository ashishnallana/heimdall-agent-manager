package mcp

import "core:encoding/json"
import domain "odin_test:hub/domain"
import auth "odin_test:hub/service/auth"

Runtime_Arguments :: struct {
	agent_id,agent_instance_id,bridge_id,project_id,chain_id,provider,provider_profile,model,request_id,expected_revision,operation_tool,retry_request_id:string,
	expected_operation_revision:int,
}
Runtime_Result :: struct {
	operation_id,tool,agent_instance_id,agent_id,status,phase,error_code,revision,created_at:string,
	native_operation_id:string,
	operation_revision:int,
}
Runtime_Proc :: proc(ctx:rawptr,raw:string,view:Access_View,tool:string,args:Runtime_Arguments,cancel_ctx:rawptr,cancel:proc(ctx:rawptr)->bool)->(string,string)
runtime_tool :: proc(tool:string)->bool {switch tool {case "instances.create","instances.start","instances.stop","instances.reconfigure","instances.operations":return true};return false}
runtime_write :: proc(tool:string)->bool {return runtime_tool(tool) && tool!="instances.operations"}
runtime_write_digest :: proc(a:Runtime_Arguments)->string {
	// Versioned write-only shape: future polling arguments must not invalidate
	// successful retries already recorded by an older server.
	binding:=struct {v:int,agent_id,agent_instance_id,bridge_id,project_id,chain_id,provider,provider_profile,model,request_id,expected_revision,retry_request_id:string,expected_operation_revision:int}{1,a.agent_id,a.agent_instance_id,a.bridge_id,a.project_id,a.chain_id,a.provider,a.provider_profile,a.model,a.request_id,a.expected_revision,a.retry_request_id,a.expected_operation_revision}
	encoded,_:=json.marshal(binding,allocator=context.temp_allocator)
	return auth.sha256_hex(string(encoded))
}
// Runtime revisions exclude heartbeat timestamps, but cover launch generations,
// effective permissions and task binding as well as native configuration CAS.
runtime_revision :: proc(i:domain.Agent_Instance)->string {
	value:=struct {id,agent_id,bridge_id,project_id,chain_id,provider,profile,model,permission_mode,launch_epoch,status,startup,stopped_by,task:string,revision,run_count:int}{i.agent_instance_id,i.agent_id,i.bridge_id,string(i.project_id),i.chain_id,i.provider,domain.profile_effective_id(i.provider,i.provider_profile),i.model,domain.agent_instance_effective_permission_mode(i),i.launch_epoch,i.runtime_status,i.startup_status,i.stopped_by,string(i.current_task_id),i.configuration_revision,i.run_count}
	encoded,_:=json.marshal(value,allocator=context.temp_allocator)
	return auth.sha256_hex(string(encoded))
}
