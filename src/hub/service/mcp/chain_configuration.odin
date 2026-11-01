#+feature dynamic-literals
package mcp

import "core:encoding/json"
import "core:crypto"
import auth "odin_test:hub/service/auth"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

control_configuration :: proc(s:^Control_Service,chain:domain.Task_Chain)->(revision:string,fleet:json.Array,ok:bool) {
	rows,err:=iface.taskchain_list_fleets_by_chain(s.chains.repo,chain.chain_id,chain.owner_user_id)
	if err.code!=.None do return "",nil,false
	encoded,eerr:=json.marshal(struct {chain:domain.Task_Chain,fleet:[]domain.Task_Chain_Fleet}{chain,rows},allocator=context.temp_allocator)
	defer if len(encoded)>0 do crypto.zero_explicit(raw_data(encoded),len(encoded))
	if eerr!=nil do return "",nil,false
	visible:=make(json.Array,0,len(rows),context.temp_allocator)
	for row in rows do append(&visible,json.Object{"agent_id"=json.String(row.agent_id),"bridge_id"=json.String(row.bridge_id),"provider"=json.String(row.provider),"provider_profile"=json.String(row.provider_profile),"model"=json.String(row.model),"capacity"=json.Integer(row.capacity),"roles_json"=json.String(row.roles_json),"bridge_models_json"=json.String(row.bridge_models_json)})
	return auth.sha256_hex(string(encoded)),visible,true
}

control_configuration_revision :: proc(s:^Control_Service,chain:domain.Task_Chain)->(string,bool) {revision,_,ok:=control_configuration(s,chain);return revision,ok}
