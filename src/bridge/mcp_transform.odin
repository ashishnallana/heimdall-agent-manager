package main

import "core:crypto"
import "core:encoding/json"
import "core:strings"
import "core:time"
import vault "odin_test:lib/vault"
import ws "odin_test:lib/ws"

bridge_mcp_transform :: proc(conn:^ws.Connection,text:string) {
	input:struct {command_id:string,job:vault.Control_Job}
	if len(text)>1024*1024 || json.unmarshal_string(text,&input,.JSON,context.temp_allocator)!=nil do return
	// Decode creates a second copy of a create payload; wipe both request copies.
	defer if input.job.payload!="" do crypto.zero_explicit(raw_data(input.job.payload),len(input.job.payload))
	if input.command_id!=input.job.request_id do return
	kr,unlocked:=bridge_read_vault_keyring()
	defer vault.keyring_wipe(&kr)
	if !unlocked do return
	floor,floor_status:=keystore_read_epoch_floor(bridge_config.daemon_id)
	if floor_status!=.Found || !floor.root.set || epoch_floor_check(&floor,bridge_config.daemon_id,&kr)!=.None do return
	owner:=bridge_enrolled_owner_user_id(bridge_config.daemon_id)
	public:=bridge_identity_public_key_hex(bridge_config.daemon_id)
	device,valid:=vault.device_id_from_sign_pub(public,context.temp_allocator)
	if !valid do return
	origin,origin_ok:=bridge_hub_pair_origin(bridge_config.daemon_url,context.temp_allocator)
	if !origin_ok do return
	canonical_resource,resource_ok:=bridge_hub_canonical_base(input.job.resource,context.temp_allocator)
	if !resource_ok || canonical_resource!=strings.concatenate({strings.trim_right(origin,"/"),"/api/v1/mcp"},context.temp_allocator) do return
	resource:=input.job.resource
	now:=time.to_unix_nanoseconds(time.now())/1_000_000
	if !vault.control_job_verify(input.job,owner,resource,device,&kr,now,&floor.root) do return
	result,ok:=vault.control_job_transform(input.job,&kr)
	defer if result!="" do crypto.zero_explicit(raw_data(result),len(result))
	if !ok || time.to_unix_nanoseconds(time.now())/1_000_000>=input.job.deadline_ms do return
	// Identity belongs to this enrolled bridge; sign only this domain-separated
	// request/digest/generation/deadline/result binding, never caller arbitrary text.
	statement:=vault.control_reply_statement(input.job,device,result)
	signature,encoded:=bridge_mcp_sign_result(bridge_config.daemon_id,statement)
	if !encoded do return
	reply:=vault.Control_Reply{request_id=input.job.request_id,generation=input.job.generation,digest=input.job.digest,device_id=device,result=result,signature=signature,deadline_ms=input.job.deadline_ms}
	frame,err:=json.marshal(struct {type,command_id:string,reply:vault.Control_Reply}{"mcp_transform_result",input.command_id,reply},allocator=context.temp_allocator)
	if err!=nil do return
	defer crypto.zero_explicit(raw_data(frame),len(frame))
	_ = bridge_hub_send(conn,string(frame))
}
