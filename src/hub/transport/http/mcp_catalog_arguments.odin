package http

import "core:encoding/json"
import "core:strings"
import "core:crypto"
import mcp "odin_test:hub/service/mcp"
import vault "odin_test:lib/vault"

catalog_id :: proc(id,prefix:string)->bool {return len(id)>len(prefix) && len(id)<=256 && strings.has_prefix(id,prefix) && vault.valid_id_value(id)}
mcp_catalog_arguments :: proc(tool:string,value:json.Value)->(mcp.Control_Arguments,bool) {
	obj,typed:=value.(json.Object);if value==nil {obj=make(json.Object,context.temp_allocator);typed=true};if !typed do return {},false
	allowed:[]string
	switch tool {
	case "agents.list":allowed=[]string{"state","limit","cursor"}
	case "agents.get":allowed=[]string{"agent_id"}
	case "agents.create":allowed=[]string{"request_id","name","slug","instructions","template_id","permission_mode","supports"}
	case "agents.update":allowed=[]string{"agent_id","request_id","expected_revision","name","slug","instructions","template_id","permission_mode","supports"}
	case "agents.archive":allowed=[]string{"agent_id","request_id","expected_revision"}
	case "instances.list":allowed=[]string{"agent_id","bridge_id","state","limit","cursor"}
	case "instances.get":allowed=[]string{"agent_instance_id"}
	case "bridges.list":allowed=[]string{"limit","cursor"}
	case "providers.list":allowed=[]string{"bridge_id","agent_id","limit","cursor","provider_profile","model_limit","model_cursor"}
	case:return {},false
	}
	a:mcp.Catalog_Arguments
	accepted:=false
	defer if !accepted {for text in ([]string{a.name,a.slug,a.instructions}) do if text!="" do crypto.zero_explicit(raw_data(text),len(text))}
	for key,v in obj {
		known:=false;for k in allowed do if k==key do known=true
		if !known do return {},false
		for k,i in mcp.CATALOG_KEYS do if k==key do a.present|=u64(1)<<u64(i)
		if key=="limit" || key=="model_limit" {n,ok:=v.(json.Integer);if !ok || n<1 || n>100 do return {},false;continue}
		if key=="supports" {
			rows,ok:=v.(json.Array);if !ok || len(rows)>100 do return {},false
			seen:=make(map[string]bool,context.temp_allocator)
			for raw in rows {
				r,ok:=raw.(json.Object);if !ok do return {},false
				id,valid:=r["bridge_id"].(json.String);if !valid || !catalog_id(string(id),"brg_") || seen[string(id)] do return {},false
				seen[string(id)]=true
				if _,ok:=r["enabled"].(json.Boolean);!ok do return {},false
				for k,v in r {
					switch k {case "bridge_id","enabled":case "priority","max_instances":n,ok:=v.(json.Integer);if !ok || n<0 || k=="priority" && n>100 || k=="max_instances" && n>64 do return {},false;case:return {},false}
				}
			}
			continue
		}
		s,ok:=v.(json.String);if !ok do return {},false
		limit:=256;switch key {case "name","slug":limit=500;case "instructions":limit=65536;case "cursor","model_cursor":limit=2048}
		if len(s)>limit do return {},false
		if (key=="name" || key=="slug") && strings.trim_space(string(s))=="" do return {},false
	}
	encoded,err:=json.marshal(obj,allocator=context.temp_allocator);if err!=nil do return {},false
	defer if len(encoded)>0 do crypto.zero_explicit(raw_data(encoded),len(encoded))
	// These bytes only back validated arguments until the enclosing request wipes them.
	mask:=a.present
	if json.unmarshal(encoded,&a,.JSON,context.temp_allocator)!=nil do return {},false
	a.present=mask
	if mcp.catalog_present(a,"agent_id") && !catalog_id(a.agent_id,"agt_") do return {},false
	if mcp.catalog_present(a,"agent_instance_id") && !catalog_id(a.agent_instance_id,"inst_") do return {},false
	if mcp.catalog_present(a,"bridge_id") && !catalog_id(a.bridge_id,"brg_") do return {},false
	if mcp.catalog_present(a,"template_id") && a.template_id!="" && !vault.valid_id_value(a.template_id) do return {},false
	if mcp.catalog_present(a,"permission_mode") && a.permission_mode!="ask" && a.permission_mode!="yolo" do return {},false
	if mcp.catalog_present(a,"provider_profile") && !catalog_profile_valid(a.provider_profile) do return {},false
	if a.model_cursor!="" && (a.provider_profile=="" || a.cursor!="") do return {},false
	if mcp.catalog_present(a,"state") {
		valid:=a.state=="active" || a.state=="archived"
		if tool=="instances.list" {valid=false;for s in ([]string{"running","idle","busy","launching","starting","stopping","stopped","failed","unreachable","created","pending"}) do if a.state==s do valid=true}
		if !valid do return {},false
	}
	if mcp.catalog_write(tool) {
		if a.request_id=="" || !vault.valid_id_value(a.request_id) do return {},false
		if tool=="agents.create" {if a.name=="" do return {},false} else {if a.agent_id=="" || len(a.expected_revision)!=64 || !vault.is_lower_hex(a.expected_revision) do return {},false}
		if tool=="agents.update" && len(obj)<4 do return {},false
	}
	if tool=="agents.get" && a.agent_id=="" || tool=="instances.get" && a.agent_instance_id=="" || tool=="providers.list" && a.bridge_id=="" do return {},false
	accepted=true
	return {catalog=a},true
}

catalog_profile_valid :: proc(id:string)->bool {
	if len(id)<1 || len(id)>32 || id[0]<'a' || id[0]>'z' do return false
	for c in id do if !(c>='a' && c<='z' || c>='0' && c<='9' || c=='_' || c=='-') do return false
	return true
}
