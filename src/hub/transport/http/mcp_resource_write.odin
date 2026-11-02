package http

import "core:encoding/base64"
import "core:encoding/json"
import "core:strings"
import "core:crypto"
import "core:sync"
import "core:time"
import mcp "odin_test:hub/service/mcp"
import hb "odin_test:lib/html_bundle"

// Hub-wide bound on concurrent html-bundle work (artifacts.create with
// entry/files, artifacts.get of a bundle). Each holds roughly 150 MiB of request
// body, decoded members, archive, base64, job payload and relay command, so the
// Hub admits MCP_BUNDLE_MAX_CONCURRENT at a time and answers the rest with a
// retryable busy result. Text artifacts and every other tool are not counted.
MCP_BUNDLE_MAX_CONCURRENT :: 2
MCP_BUNDLE_BUSY :: "busy: html-bundle capacity is exhausted; retry shortly with the same request_id"
@(private="file") mcp_bundle_active:int
mcp_bundle_slot_acquire :: proc()->bool {
	for {
		current:=sync.atomic_load(&mcp_bundle_active)
		if current>=MCP_BUNDLE_MAX_CONCURRENT do return false
		if _,swapped:=sync.atomic_compare_exchange_strong(&mcp_bundle_active,current,current+1);swapped do return true
	}
}
mcp_bundle_slot_release :: proc() {sync.atomic_sub(&mcp_bundle_active,1)}
mcp_bundle_slots_in_use :: proc()->int {return sync.atomic_load(&mcp_bundle_active)}
mcp_resource_write_call :: proc(h:^MCP_Control_Handlers,id:json.Value,raw:string,view:mcp.Access_View,tool:string,a:mcp.Resource_Arguments,handle:mcp.Request_Handle,started:time.Tick)->Response {
	if h.mutate_resource==nil do return mcp_tool_result(id,"request_failed",true)
	digest:=mcp.resource_write_digest(a);args:=a;args.fields=nil
	// Probe before encryption/ownership lookups: destructive issue retries must
	// remain valid after the resource and its comments have been deleted.
	prior,prior_code:=h.mutate_resource(h.create_ctx,raw,view,{tool=tool,digest=digest,args=args,replay_only=true})
	if prior_code=="invalid_token" do return mcp_unauthorized(h)
	if prior_code=="" do return mcp_tool_result(id,prior,false)
	if prior_code!="receipt_missing" do return mcp_tool_result(id,prior_code,true)
	if a.id!="" {
		row,_,code:=mcp.resource_get(&h.control,view.owner,mcp.resource_kind(tool),a.id,false)
		if code!="" do return mcp_tool_result(id,code,true)
		if read_only,_:=row["read_only"].(json.Boolean);bool(read_only) do return mcp_tool_result(id,"read_only",true)
	}
	sealed:=make(json.Object,context.temp_allocator)
	fields:=a.fields
	// Function-scope wipes: the packed archive and its base64 live until sealed.
	archive:[]byte;archive64:string
	defer if len(archive)>0 do crypto.zero_explicit(raw_data(archive),len(archive))
	defer if len(archive64)>0 do crypto.zero_explicit(raw_data(archive64),len(archive64))
	if tool=="artifacts.create" && a.files!=nil {
		// Bounded concurrency: each bundle create holds ~150 MiB transiently.
		if !mcp_bundle_slot_acquire() do return mcp_tool_result(id,MCP_BUNDLE_BUSY,true)
		defer mcp_bundle_slot_release()
		// Existing relay trust model: the Hub sees the plaintext tool input, packs the
		// html-bundle and relays only the archive to the device/hosted sealer, which
		// re-validates it before sealing the exact bytes (vault content_base64).
		bundle,bundle_err:=hb.html_bundle_from_entry_files(a.entry,a.files,context.temp_allocator)
		if bundle_err!="" do return mcp_tool_result(id,strings.concatenate({"invalid_bundle: ",bundle_err},context.temp_allocator),true)
		archive=bundle.zip
		encode_err:base64.Error
		archive64,encode_err=base64.encode(archive,allocator=context.temp_allocator)
		if encode_err!=nil do return mcp_tool_result(id,"request_failed",true)
		fields=make(json.Object,context.temp_allocator)
		for key,value in a.fields do fields[key]=value
		fields["content_base64"]=json.String(archive64)
	}
	if len(fields)>0 {
		op:=mcp.Control_Transform{tool=tool,resource_fields=fields};result:mcp.Delegation_Result
		if view.mode=="hosted" {result=mcp.hosted_with_access(h.delegation.service,h.delegation.grant_directory,raw,view.client,mcp.control_hosted_transform,&op)} else {result=mcp_device_transform(h,view,&op,handle,started)}
		defer if result.response!="" do crypto.zero_explicit(raw_data(result.response),len(result.response))
		if result.error=="invalid_token" do return mcp_unauthorized(h)
		if result.error!="" do return mcp_tool_result(id,result.error,true)
		value,err:=json.parse_string(result.response,parse_integers=true,allocator=context.temp_allocator)
		obj,typed:=value.(json.Object);if err!=nil || !typed || !mcp_task_sealed_fields(view,fields,obj) do return mcp_tool_result(id,"decryption_unavailable",true)
		sealed=obj
	}
	if time.tick_since(started)>=30*time.Second || mcp.request_cancelled(&h.requests,handle) do return mcp_tool_result(id,"cancelled",true)
	result,code:=h.mutate_resource(h.create_ctx,raw,view,{tool=tool,digest=digest,args=args,sealed=sealed})
	if code=="invalid_token" do return mcp_unauthorized(h)
	if code!="" do return mcp_tool_result(id,code,true)
	return mcp_tool_result(id,result,false)
}
