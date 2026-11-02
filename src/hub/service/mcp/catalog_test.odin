#+feature dynamic-literals
package mcp

import "core:encoding/json"
import "core:testing"
import "core:fmt"
import domain "odin_test:hub/domain"

@(test)
test_catalog_model_pages_bind_owner_bridge_agent_profile :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	models:=make([]domain.Provider_Model,205,context.temp_allocator)
	for &model,i in models do model={model_id=fmt.tprintf("model_%03d",i),label="Model",state="active",rank=i}
	a:=Catalog_Arguments{bridge_id="brg_a",agent_id="agt_a",provider_profile="work",model_limit=100}
	count:=0;last:="";first_cursor:string
	for i in 0..<3 {
		rows,next,code:=catalog_models_page("owner",a,"work",models,true)
		if !testing.expect(t,code=="" && len(rows)<=100) do return
		for value in rows {row,_:=value.(json.Object);id:=string(row["model_id"].(json.String));testing.expect(t,id>last);last=id;count+=1}
		if i==0 do first_cursor=next
		if next=="" do break
		a.model_cursor=next
	}
	testing.expect_value(t,count,205)
	a.model_cursor=first_cursor
	_,_,foreign_owner:=catalog_models_page("foreign",a,"work",models,true);testing.expect_value(t,foreign_owner,"invalid_arguments")
	for field in 0..<3 {
		bad:=a;profile:="work"
		if field==0 do bad.bridge_id="brg_other"
		if field==1 do bad.agent_id="agt_other"
		if field==2 do profile="other"
		_,_,code:=catalog_models_page("owner",bad,profile,models,true);testing.expect_value(t,code,"invalid_arguments")
	}
}

@(test)
test_catalog_agent_retry_digest_ignores_read_argument_growth :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	a:=Catalog_Arguments{request_id="req_a",name="Agent"}
	first,ok:=catalog_write_digest(a);testing.expect(t,ok)
	a.model_limit=100;a.model_cursor="read cursor";a.provider_profile="work";a.cursor="read page"
	second,_:=catalog_write_digest(a);testing.expect_value(t,second,first)
	a.name="Different"
	third,_:=catalog_write_digest(a);testing.expect(t,third!=first)
}

@(test)
test_catalog_device_result_cannot_forge_target_or_model_metadata :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	model:=json.Object{"model_id"=json.String("model_a"),"label"=json.String("encrypted label"),"state"=json.String("active"),"rank"=json.Integer(1),"eligible"=json.Boolean(true)}
	row:=json.Object{"bridge_id"=json.String("brg_a"),"provider"=json.String("codex"),"provider_profile"=json.String("work"),"label"=json.String("encrypted label"),"models"=json.Array{model},"models_next_cursor"=json.String("bound_cursor")}
	data:=Control_Data{records_kind="provider",records=[]json.Object{row}}
	encoded,_:=json.marshal(data,allocator=context.temp_allocator)
	value,_:=json.parse_string(string(encoded),parse_integers=true,allocator=context.temp_allocator)
	root,_:=value.(json.Object);records,_:=root["records"].(json.Array);actual,_:=records[0].(json.Object)
	actual["label"]=json.String("Readable profile")
	models,_:=actual["models"].(json.Array);actual_model,_:=models[0].(json.Object);actual_model["label"]=json.String("Readable model")
	valid,_:=json.marshal(root,allocator=context.temp_allocator);testing.expect(t,control_result_ok(data,string(valid)))
	for key in ([]string{"bridge_id","provider_profile","models_next_cursor"}) {
		original:=actual[key];actual[key]=json.String("forged")
		bad,_:=json.marshal(root,allocator=context.temp_allocator);testing.expect(t,!control_result_ok(data,string(bad)));actual[key]=original
	}
	actual_model["eligible"]=json.Boolean(false)
	bad,_:=json.marshal(root,allocator=context.temp_allocator);testing.expect(t,!control_result_ok(data,string(bad)))
	actual_model["eligible"]=json.Boolean(true)
	root["records_kind"]=json.String("agent")
	bad,_=json.marshal(root,allocator=context.temp_allocator);testing.expect(t,!control_result_ok(data,string(bad)))
}
