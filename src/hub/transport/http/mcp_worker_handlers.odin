package http

import "core:crypto"
import "core:encoding/json"
import "core:time"
import domain "odin_test:hub/domain"
import auth "odin_test:hub/service/auth"
import events "odin_test:hub/service/events"
import mcp "odin_test:hub/service/mcp"
import vd "odin_test:hub/service/vault_directory"
import iface "odin_test:hub/repository/iface"
import project "odin_test:hub/service/project"
import vault "odin_test:lib/vault"

// Called only from the live enrolled bridge connection's generation-checked
// frame dispatcher. Never add this frame to the generic command-result cache.
mcp_bridge_result :: proc(h:^Bridge_Handlers,bridge_id,text:string,connection_generation:int) {
	defer if text!="" do crypto.zero_explicit(raw_data(text),len(text))
	if h.mcp_control==nil || h.mcp_control.delegation==nil || len(text)>MCP_WORKER_MAX_REPLY_BYTES do return
	if project.bridge_runtime_registry_generation(h.bridge_runtime_registry,bridge_id)!=connection_generation do return
	c:=h.mcp_control
	bridge,found,err:=iface.bridge_get_bridge(h.bridges.repo,bridge_id)
	if !found || err.code!=.None do return
	defer domain.bridge_destroy(&bridge)
	if bridge.status!=.Online || bridge.plan_disabled_at!="" || bridge.enrollment_pending_until!="" do return
	identity,live:=project.bridge_runtime_registry_unseal_identity(h.bridge_runtime_registry,bridge_id,context.temp_allocator)
	if !live do return
	device,valid:=vault.device_id_from_sign_pub(identity.identity_public_key,context.temp_allocator)
	if !valid do return
	frame:struct {reply:vault.Control_Reply}
	if json.unmarshal_string(text,&frame,.JSON,context.temp_allocator)!=nil do return
	defer if frame.reply.result!="" do crypto.zero_explicit(raw_data(frame.reply.result),len(frame.reply.result))
	now,clock_ok:=auth.now_unix_ms(c.delegation.auth)
	if !clock_ok do return
	job,has_job:=mcp.worker_job(&c.workers,string(bridge.owner_user_id),device,frame.reply.request_id,frame.reply.generation,now,connection_generation=connection_generation)
	defer if job.payload!="" do crypto.zero_explicit(raw_data(job.payload),len(job.payload))
	if !has_job || !mcp_verify_reply(job,frame.reply,device,now) || !mcp.public_job_live(c.delegation.service,c.delegation.grant_directory,job) do return
	_ = mcp.worker_complete(&c.workers,string(bridge.owner_user_id),device,frame.reply,now,connection_generation=connection_generation)
}

mcp_worker_directory :: proc(h:^MCP_Control_Handlers,view:mcp.Access_View)->(vault.Directory_Verification_Input,bool) {
	snapshot,err:=vd.get_directory(h.delegation.directory,view.owner)
	if err.code!=.None || snapshot.directory.head_hash!=view.head || snapshot.directory.current_epoch!=i64(view.epoch) do return {},false
	c:vault.Control_Consent
	if json.unmarshal_string(view.consent,&c,.JSON,context.temp_allocator)!=nil do return {},false
	d:=vault.Directory_Verification_Input{owner=view.owner,root_device_id=snapshot.directory.root_device_id,head_hash=view.head,version=view.version,current_epoch=i64(view.epoch),pin_seq=c.directory_version,pin_hash=c.directory_head,vault_id=c.vault_id}
	d.log=make([]vault.Directory_Log_Item,len(snapshot.log),context.temp_allocator)
	for entry,i in snapshot.log do d.log[i]={entry.seq,entry.statement,entry.signature}
	d.devices=make([]vault.Directory_Device_Item,len(snapshot.devices),context.temp_allocator)
	for device,i in snapshot.devices do d.devices[i]={device.device_id,device.kind,device.sign_alg,device.wrap_alg,device.sign_public_key,device.ecdh_public_key,device.status==.Approved,device.status==.Pending}
	_,verified:=vault.directory_verify(d)
	return d,verified
}
mcp_verify_reply :: proc(job:vault.Control_Job,reply:vault.Control_Reply,expected_device:string,now:i64)->bool {
	if reply.request_id!=job.request_id || reply.generation!=job.generation || reply.digest!=job.digest || reply.deadline_ms!=job.deadline_ms || reply.deadline_ms<=now || reply.device_id!=expected_device || reply.result=="" || len(reply.result)>vault.control_reply_max(job.operation,job.tool) do return false
	dir,verified:=vault.directory_verify(job.directory)
	if !verified do return false
	device,trusted:=dir.trusted[expected_device]
	if !trusted || (device.kind!="bridge" && !vault.kind_policy(vault.device_kind_from_id(device.kind)).receives_wrap) do return false
	statement:=vault.control_reply_statement(job,expected_device,reply.result)
	return vault.verify(device.sign_alg,device.sign_public_key,transmute([]byte)statement,reply.signature)
}
// Worker/bridge reply envelope: largest result (artifact bundle seal) + 1 MiB of
// reply metadata. Every result is still bounded per job by control_reply_max.
MCP_WORKER_MAX_REPLY_BYTES :: vault.CONTROL_JOB_ARTIFACT_PAYLOAD_MAX+1024*1024
mcp_device_transform :: proc(h:^MCP_Control_Handlers,view:mcp.Access_View,op:^mcp.Control_Transform,handle:mcp.Request_Handle,started:time.Tick)->mcp.Delegation_Result {
	device_started:=time.tick_now()
	if view.mode!="device" do return {error="decryption_unavailable"}
	d,verified:=mcp_worker_directory(h,view)
	if !verified do return {error="decryption_unavailable"}
	job:=vault.Control_Job{owner=view.owner,resource=h.delegation.service.resource,grant=view.grant,revision=view.revision,head=view.head,epoch=view.epoch,consent=view.consent,signature=view.signature,directory=d,operation="read"}
	job.tool=op.tool
	now,clock_ok:=auth.now_unix_ms(h.delegation.auth)
	if !clock_ok do return {error="decryption_unavailable"}
	job.request_id,_=auth.random_token();job.generation,_=auth.random_token()
	if job.request_id=="" || job.generation=="" do return {error="decryption_unavailable"}
	job.deadline_ms=min(now+4000,view.expires_ms)
	encoded:[]byte
	err:json.Marshal_Error
	if op.resource_fields!=nil {job.operation="seal_resource";encoded,err=json.marshal(op.resource_fields,allocator=context.temp_allocator)} else if op.agent_fields!=nil {job.operation="seal_agent";encoded,err=json.marshal(op.agent_fields,allocator=context.temp_allocator)} else if op.task_fields!=nil {job.operation="seal_task";encoded,err=json.marshal(op.task_fields,allocator=context.temp_allocator)} else if op.tool=="tasks.comment" {job.operation="seal_comment";encoded,err=json.marshal(struct {body:string}{op.body},allocator=context.temp_allocator)} else if op.seal {job.operation="seal";encoded,err=json.marshal(struct {title,description:string}{op.title,op.description},allocator=context.temp_allocator)} else {encoded,err=json.marshal(op.data,allocator=context.temp_allocator)}
	defer if len(encoded)>0 do crypto.zero_explicit(raw_data(encoded),len(encoded))
	if err!=nil || len(encoded)>vault.control_job_payload_max(job.operation,job.tool) do return {error="result_too_large"}
	job.payload=string(encoded);job.digest=vault.control_job_digest(job)
	if !mcp.worker_begin(&h.workers,job) do return {error="decryption_unavailable"}
	defer mcp.worker_end(&h.workers,job.request_id,job.generation)
	if h.bridge_transform!=nil && !mcp.request_cancelled(&h.requests,handle) {
		result,ok:=h.bridge_transform(h.bridge_ctx,job)
		if ok {
			device,registration:=mcp.worker_receiver(&h.workers,job.request_id,job.generation)
			if registration!="" && !mcp.worker_registered(&h.registrations,view.owner,device,registration,now) {if result!="" do crypto.zero_explicit(raw_data(result),len(result));return {error="decryption_unavailable"}}
			return {response=result}
		}
	}
	if mcp.request_cancelled(&h.requests,handle) || time.tick_since(started)>=29*time.Second do return {error="cancelled"}
	// Only a bounded hint is broadcast. The approved device fetches the bound job
	// using its normal session/OIDC + approved-device request proof.
	events.publish_mcp_worker_hint(h.bus,view.owner)
	for {
		if mcp.request_cancelled(&h.requests,handle) do return {error="cancelled"}
		now,clock_ok=auth.now_unix_ms(h.delegation.auth)
		if !clock_ok || now>=job.deadline_ms || time.tick_since(device_started)>=4*time.Second || time.tick_since(started)>=29*time.Second do return {error="decryption_unavailable"}
		result,ok:=mcp.worker_result(&h.workers,job.request_id,job.generation)
		if ok {
			device,registration:=mcp.worker_receiver(&h.workers,job.request_id,job.generation)
			if registration!="" && !mcp.worker_registered(&h.registrations,view.owner,device,registration,now) {if result!="" do crypto.zero_explicit(raw_data(result),len(result));return {error="decryption_unavailable"}}
			return {response=result}
		}
		time.sleep(20*time.Millisecond)
	}
}
mcp_worker_handler :: proc(ctx:rawptr,req:Request)->Response {
	h:=(^MCP_Control_Handlers)(ctx)
	principal,device,ok,resp:=mcp_delegation_user(h.delegation,req,true)
	if !ok do return resp
	now,clock_ok:=auth.now_unix_ms(h.delegation.auth)
	if !clock_ok do return mcp_oauth_error("temporarily_unavailable",503)
	registration:=query_value(req.query,"generation")
	if !mcp.worker_registered(&h.registrations,principal.user_id,device.device_id,registration,now) do return mcp_oauth_error("access_denied",403)
	if req.method=="GET" {
		text,found:=mcp.worker_take(&h.workers,principal.user_id,device.device_id,now,registration)
		if !found do return mcp_json(struct {}{},204)
		job:vault.Control_Job
		if json.unmarshal_string(text,&job,.JSON,context.temp_allocator)!=nil || !mcp.public_job_live(h.delegation.service,h.delegation.grant_directory,job) {if text!="" do crypto.zero_explicit(raw_data(text),len(text));return mcp_oauth_error("access_denied",403)}
		defer if job.payload!="" do crypto.zero_explicit(raw_data(job.payload),len(job.payload))
		response:=Response{status=200,content_type="application/json",body=text,sensitive=true,write_timeout_ms=1000,headers=mcp_json(struct {}{}).headers}
		return response
	}
	// Device-authenticated above; bundle seal replies carry the armored archive.
	if len(req.body)>MCP_WORKER_MAX_REPLY_BYTES do return mcp_oauth_error("invalid_request")
	defer if req.body!="" do crypto.zero_explicit(raw_data(req.body),len(req.body))
	reply:vault.Control_Reply
	defer if reply.result!="" do crypto.zero_explicit(raw_data(reply.result),len(reply.result))
	if json.unmarshal_string(req.body,&reply,.JSON,context.temp_allocator)!=nil || reply.device_id!=device.device_id do return mcp_oauth_error("invalid_request")
	job,found:=mcp.worker_job(&h.workers,principal.user_id,device.device_id,reply.request_id,reply.generation,now,registration)
	defer if job.payload!="" do crypto.zero_explicit(raw_data(job.payload),len(job.payload))
	if !found || !mcp_verify_reply(job,reply,device.device_id,now) || !mcp.public_job_live(h.delegation.service,h.delegation.grant_directory,job) do return mcp_oauth_error("access_denied",403)
	// The outer native proof/session and inner result signature are both required.
	// Final access/head checks still run in the waiting tool request.
	if !mcp.worker_complete(&h.workers,principal.user_id,device.device_id,reply,now,registration) do return mcp_oauth_error("access_denied",403)
	return mcp_json(struct {accepted:bool}{true})
}

mcp_worker_registration_handler :: proc(ctx:rawptr,req:Request)->Response {
	h:=(^MCP_Control_Handlers)(ctx)
	principal,device,ok,resp:=mcp_delegation_user(h.delegation,req,true)
	if !ok do return resp
	if len(req.body)>1024 do return mcp_oauth_error("invalid_request")
	input:struct {generation:string,enabled:bool,expires_ms:i64}
	if json.unmarshal_string(req.body,&input,.JSON,context.temp_allocator)!=nil || !vault.valid_id_value(input.generation) do return mcp_oauth_error("invalid_request")
	now,clock_ok:=auth.now_unix_ms(h.delegation.auth)
	if !clock_ok || !mcp.worker_register(&h.registrations,principal.user_id,device.device_id,input.generation,input.enabled,input.expires_ms,now) do return mcp_oauth_error("temporarily_unavailable",503)
	return mcp_json(struct {registered:bool,generation:string,expires_ms:i64}{input.enabled,input.generation,input.expires_ms})
}
