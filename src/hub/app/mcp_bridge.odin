package app

import "core:crypto"
import "core:encoding/json"
import "core:time"
import contracts "odin_test:contracts"
import bridge "odin_test:hub/service/bridge"
import br "odin_test:hub/service/bridge_runtime"
import mcp "odin_test:hub/service/mcp"
import project "odin_test:hub/service/project"
import domain "odin_test:hub/domain"
import vault "odin_test:lib/vault"
import jsonx "odin_test:lib/jsonx"

mcp_bridge_transform :: proc(ctx:rawptr,job:vault.Control_Job)->(string,bool) {
	g:=(^App_Graph)(ctx)
	all,err:=bridge.list_bridges(&g.bridges,mcp.control_auth(job.owner))
	if err.code!=.None do return "",false
	defer {for &b in all do domain.bridge_destroy(&b);delete(all)}
	for b in all {
		if b.status!=.Online || b.plan_disabled_at!="" || b.enrollment_pending_until!="" do continue
		features:=jsonx.extract_string_array(b.capabilities_json,"features")
		supported:=false
		for f in features do if f=="mcp_transform_v1" do supported=true
		for f in features do delete(f)
		delete(features)
		if !supported do continue
		generation:=project.bridge_runtime_registry_generation(&g.bridge_runtime_registry,b.bridge_id)
		identity,live:=project.bridge_runtime_registry_unseal_identity(&g.bridge_runtime_registry,b.bridge_id,context.temp_allocator)
		if !live do continue
		device,valid:=vault.device_id_from_sign_pub(identity.identity_public_key,context.temp_allocator)
		if !valid do continue
		// Only a currently approved bridge directory identity may receive the job.
		trusted:=false
		for d in job.directory.devices do if d.id==device && d.kind=="bridge" && d.approved do trusted=true
		if !trusted || generation==0 || !mcp.worker_assign(&g.mcp_control_handlers.workers,job.request_id,job.generation,device,generation) do continue
		defer mcp.worker_unclaim(&g.mcp_control_handlers.workers,job.request_id,job.generation,device)
		command,enc_err:=json.marshal(struct {type,command_id:string,job:vault.Control_Job}{"mcp_transform",job.request_id,job},allocator=context.temp_allocator)
		// 1 MiB for every job except artifact bundle seal/download jobs, which carry
		// base64 of <=15 MiB (vault.control_job_payload_max) plus the job envelope.
		if enc_err!=nil || len(command)>mcp_bridge_command_max(job) do return "",false
		defer crypto.zero_explicit(raw_data(command),len(command))
		if !mcp.public_job_live(&g.mcp_delegation,&g.mcp_vault_view,job) do return "",false
		if project.bridge_runtime_registry_generation(&g.bridge_runtime_registry,b.bridge_id)!=generation do return "",false
		// No generic result registry: plaintext replies go to the request broker.
		sent,_:=br.send_runtime_command(&g.bridge_runtime_registry,{bridge_id=b.bridge_id,command_id=job.request_id,body_json=string(command)})
		if !sent do return "",false
		started:=time.tick_now()
		// Bundle jobs move ~21 MiB each way, so they may use the job deadline;
		// small jobs keep 1.5 s and leave the rest for an unlocked browser.
		wait:=1500*time.Millisecond
		if mcp_bridge_command_max(job)>MCP_BRIDGE_COMMAND_MAX {if remaining:=job.deadline_ms-time.to_unix_nanoseconds(time.now())/1_000_000;remaining>0 do wait=time.Duration(remaining)*time.Millisecond}
		for time.tick_since(started)<wait {
			if project.bridge_runtime_registry_generation(&g.bridge_runtime_registry,b.bridge_id)!=generation do return "",false
			result,done:=mcp.worker_result(&g.mcp_control_handlers.workers,job.request_id,job.generation)
			if done do return result,true
			time.sleep(20*time.Millisecond)
		}
		// One candidate only: leave the remaining budget for an unlocked browser.
		return "",false
	}
	return "",false
}

MCP_BRIDGE_COMMAND_MAX :: 1024*1024
// A full bundle job must fit one chunked hub->bridge message.
#assert(vault.CONTROL_JOB_ARTIFACT_PAYLOAD_MAX+2*1024*1024<=contracts.BRIDGE_WS_MAX_REASSEMBLY_BYTES)
// Hub->bridge mcp_transform command bound; mirrors the bridge dispatcher's
// BRIDGE_DISPATCH_MCP_LARGE_BYTES_LIMIT (payload max + 2 MiB envelope).
mcp_bridge_command_max :: proc(job:vault.Control_Job)->int {
	max:=vault.control_job_payload_max(job.operation,job.tool)
	if max<=vault.CONTROL_JOB_PAYLOAD_MAX do return MCP_BRIDGE_COMMAND_MAX
	return max+2*1024*1024
}
