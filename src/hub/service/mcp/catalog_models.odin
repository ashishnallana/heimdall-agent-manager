#+feature dynamic-literals
package mcp

import "core:encoding/json"
import "core:slice"
import "core:strings"
import domain "odin_test:hub/domain"

Catalog_Model_Cursor :: struct {owner,bridge_id,agent_id,provider_profile,id:string}
catalog_models_page :: proc(owner:string,a:Catalog_Arguments,profile:string,models:[]domain.Provider_Model,eligible:bool)->(json.Array,string,string) {
	c:=Catalog_Model_Cursor{owner=owner,bridge_id=a.bridge_id,agent_id=a.agent_id,provider_profile=profile}
	if a.model_cursor!="" {
		parsed:Catalog_Model_Cursor
		if json.unmarshal_string(a.model_cursor,&parsed,.JSON,context.temp_allocator)!=nil do return nil,"","invalid_arguments"
		encoded,err:=json.marshal(parsed,allocator=context.temp_allocator)
		if err!=nil || string(encoded)!=a.model_cursor || parsed.owner!=owner || parsed.bridge_id!=a.bridge_id || parsed.agent_id!=a.agent_id || parsed.provider_profile!=profile || parsed.id=="" || len(parsed.id)>256 do return nil,"","invalid_arguments"
		c=parsed
	}
	ordered:=make([]domain.Provider_Model,len(models),context.temp_allocator);copy(ordered,models)
	slice.sort_by(ordered,proc(a,b:domain.Provider_Model)->bool {return a.model_id<b.model_id})
	limit:=a.model_limit;if limit==0 do limit=50
	rows:=make(json.Array,0,min(limit,len(models)),context.temp_allocator)
	last,next:string
	for model in ordered {
		if model.model_id<=c.id do continue
		if len(rows)==limit {c.id=last;encoded,_:=json.marshal(c,allocator=context.temp_allocator);next=string(encoded);break}
		append(&rows,json.Object{"model_id"=json.String(model.model_id),"label"=json.String(model.label),"state"=json.String(model.state),"rank"=json.Integer(model.rank),"eligible"=json.Boolean(eligible && model.state=="active")})
		last=model.model_id
	}
	return rows,next,""
}

// Native provider views own their strings and are destroyed before transport
// returns. Copy only the already-allowlisted public projection into the request.
catalog_public_copy :: proc(value:json.Value)->json.Value {
	#partial switch v in value {
	case json.String:return json.String(strings.clone(string(v),context.temp_allocator))
	case json.Array:
		out:=make(json.Array,0,len(v),context.temp_allocator);for item in v do append(&out,catalog_public_copy(item));return out
	case json.Object:
		out:=make(json.Object,context.temp_allocator);for key,item in v do out[key]=catalog_public_copy(item);return out
	}
	return value
}
