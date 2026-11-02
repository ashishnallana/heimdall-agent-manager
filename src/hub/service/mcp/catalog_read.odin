#+feature dynamic-literals
package mcp

import "core:encoding/json"
import "core:slice"
import agent "odin_test:hub/service/agent"
import provider "odin_test:hub/service/provider"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

catalog_agent_record :: proc(s:^Control_Service,a:domain.Agent,detail:bool)->(json.Object,string) {
	revision,ok:=catalog_agent_revision(s,a);if !ok do return nil,"request_failed"
	row:=json.Object{"owner_user_id"=json.String(a.owner_user_id),"agent_id"=json.String(a.agent_id),"name"=json.String(a.name),"slug"=json.String(a.slug),"template_id"=json.String(a.template_id),"state"=json.String("archived" if a.state==.Archived else "active"),"permission_mode"=json.String(a.permission_mode),"created_at"=json.String(a.created_at),"updated_at"=json.String(a.updated_at),"revision"=json.String(revision)}
	if detail {
		if len(a.instructions)>128*1024 {row["instructions_error"]=json.String("instructions_too_large")} else {row["instructions"]=json.String(a.instructions)}
		supports,err:=agent.list_support(s.agents,control_auth(string(a.owner_user_id)),a.agent_id)
		if err.code!=.None || len(supports)>100 do return nil,"result_too_large"
		items:=make(json.Array,0,len(supports),context.temp_allocator)
		for support in supports do append(&items,json.Object{"bridge_id"=json.String(support.bridge_id),"enabled"=json.Boolean(support.enabled),"priority"=json.Integer(support.priority),"max_instances"=json.Integer(support.max_instances)})
		row["supports"]=items
	}
	return row,""
}
catalog_instance_record :: proc(i:domain.Agent_Instance)->json.Object {
	return json.Object{"owner_user_id"=json.String(i.owner_user_id),"agent_instance_id"=json.String(i.agent_instance_id),"agent_id"=json.String(i.agent_id),"bridge_id"=json.String(i.bridge_id),"display_name"=json.String(i.display_name),"provider"=json.String(i.provider),"provider_profile"=json.String(domain.profile_effective_id(i.provider,i.provider_profile)),"model"=json.String(i.model),"runtime_status"=json.String(i.runtime_status),"startup_status"=json.String(i.startup_status),"activity_status"=json.String(i.activity_status),"project_id"=json.String(i.project_id),"chain_id"=json.String(i.chain_id),"current_task_id"=json.String(i.current_task_id),"current_task_role"=json.String(domain.current_task_role_string(i.current_task_role)),"revision"=json.String(runtime_revision(i)),"configuration_revision"=json.Integer(i.configuration_revision),"permission_mode"=json.String(domain.agent_instance_effective_permission_mode(i)),"created_at"=json.String(i.created_at),"updated_at"=json.String(i.updated_at),"last_seen_at"=json.String(i.last_seen_at)}
}
catalog_bridge_eligible :: proc(b:domain.Bridge)->bool {return b.status==.Online && b.plan_disabled_at=="" && b.enrollment_pending_until==""}
catalog_bridge_record :: proc(b:domain.Bridge)->json.Object {
	state:="offline";if b.status==.Online do state="online";if b.status==.Revoked do state="revoked"
	return json.Object{"owner_user_id"=json.String(b.owner_user_id),"bridge_id"=json.String(b.bridge_id),"label"=json.String(b.label),"status"=json.String(state),"machine_os"=json.String(b.machine_os),"machine_arch"=json.String(b.machine_arch),"version"=json.String(b.version),"plan_disabled"=json.Boolean(b.plan_disabled_at!=""),"enrollment_pending"=json.Boolean(b.enrollment_pending_until!=""),"eligible"=json.Boolean(catalog_bridge_eligible(b)),"created_at"=json.String(b.created_at),"last_seen_at"=json.String(b.last_seen_at)}
}
control_read_catalog :: proc(s:^Control_Service,owner,tool:string,a:Catalog_Arguments)->(Control_Data,string) {
	if s.agents==nil || s.agents.agents==nil || s.bridges==nil do return {},"request_failed"
	auth:=control_auth(owner)
	agent_active:=true
	if a.agent_id!="" {row,found,err:=agent.get_agent(s.agents,auth,a.agent_id);if !found || err.code!=.None do return {},"not_found";agent_active=row.state==.Active}
	bridge:domain.Bridge
	if a.bridge_id!="" {b,found,err:=iface.bridge_get_bridge(s.bridges,a.bridge_id);if !found || err.code!=.None || string(b.owner_user_id)!=owner do return {},"not_found";bridge=b}
	if a.agent_id!="" && a.bridge_id!="" {
		support,found,err:=iface.agent_get_support(s.agents.agents,a.agent_id,a.bridge_id)
		if err.code!=.None && err.code!=.Not_Found do return {},"request_failed"
		if found {if string(support.owner_user_id)!=owner do return {},"not_found";agent_active=agent_active && support.enabled}
	}
	cursor,valid:=catalog_cursor(owner,tool,a);if !valid do return {},"invalid_arguments"
	limit:=a.limit;if limit==0 do limit=50
	out:=Control_Data{}
	switch tool {
	case "agents.list","agents.get":out.records_kind="agent"
	case "instances.list","instances.get":out.records_kind="instance"
	case "bridges.list":out.records_kind="bridge"
	case "providers.list":out.records_kind="provider"
	case:return {},"invalid_arguments"
	}
	rows:=make([dynamic]json.Object,context.temp_allocator)
	if tool=="agents.get" {
		value,found,err:=agent.get_agent(s.agents,auth,a.agent_id);if !found || err.code!=.None do return {},"not_found"
		row,code:=catalog_agent_record(s,value,true);if code!="" do return {},code
		append(&rows,row)
	} else if tool=="instances.get" {
		value,found,err:=agent.get_instance(s.agents,auth,a.agent_instance_id);if !found || err.code!=.None || value.kind!="agent" do return {},"not_found"
		append(&rows,catalog_instance_record(value))
	} else if tool=="agents.list" || tool=="instances.list" {
		page:=s.agents.agents.list_agent_refs;if tool=="instances.list" do page=s.agents.agents.list_instance_refs
		if page==nil do return {},"request_failed"
		refs,err:=page(s.agents.agents.ctx,catalog_query(owner,cursor,limit));if err.code!=.None do return {},"request_failed"
		for ref,i in refs {
			if i==limit {last:=refs[i-1];out.next_cursor=catalog_next(cursor,last.created_at,last.id);break}
			if tool=="agents.list" {
				value,found,e:=agent.get_agent(s.agents,auth,ref.id);if !found || e.code!=.None do return {},"request_failed"
				row,code:=catalog_agent_record(s,value,false);if code!="" do return {},code;append(&rows,row)
			} else {
				value,found,e:=agent.get_instance(s.agents,auth,ref.id);if !found || e.code!=.None do return {},"request_failed"
				append(&rows,catalog_instance_record(value))
			}
		}
	} else if tool=="bridges.list" {
		bridges,err:=iface.bridge_list_by_owner(s.bridges,domain.User_ID(owner));if err.code!=.None do return {},"request_failed"
		slice.sort_by(bridges,proc(a,b:domain.Bridge)->bool {if a.created_at!=b.created_at do return a.created_at<b.created_at;return a.bridge_id<b.bridge_id})
		last_created,last_id:string
		for b in bridges {
			if string(b.owner_user_id)!=owner do return {},"request_failed"
			if !catalog_ref_after(cursor,b.created_at,b.bridge_id) do continue
			if len(rows)==limit {out.next_cursor=catalog_next(cursor,last_created,last_id);break}
			append(&rows,catalog_bridge_record(b));last_created=b.created_at;last_id=b.bridge_id
		}
	} else {
		if s.providers==nil || a.bridge_id=="" do return {},"invalid_arguments"
		profiles,err:=provider.list_bridge_providers(s.providers,a.bridge_id);if err.code!=.None do return {},"request_failed"
		defer provider.bridge_provider_views_destroy(profiles)
		slice.sort_by(profiles[:],proc(a,b:provider.Bridge_Provider_View)->bool {return a.profile_id<b.profile_id})
		last:string
		profile_found:=false
		for p in profiles {
			if a.provider_profile!="" && p.profile_id!=a.provider_profile do continue
			profile_found=true
			if !catalog_ref_after(cursor,"catalog",p.profile_id) do continue
			if len(rows)==limit {out.next_cursor=catalog_next(cursor,"catalog",last);break}
			eligible:=false
			// The native view already contains effective models and detection /
			// enablement. Validate the profile once, not a full catalog per model.
			profile_eligible:=agent_active && catalog_bridge_eligible(bridge) && p.enabled && p.catalog.state=="active" && p.detection_state=="present" && provider.validate_profile(s.providers.repo,a.bridge_id,p.catalog.provider,p.profile_id).code==.None
			for model in p.catalog.models do eligible=eligible || profile_eligible && model.state=="active"
			models,model_cursor,code:=catalog_models_page(owner,a,p.profile_id,p.catalog.models[:],profile_eligible);if code!="" do return {},code
			row:=json.Object{"owner_user_id"=json.String(owner),"bridge_id"=json.String(a.bridge_id),"provider"=json.String(p.catalog.provider),"provider_profile"=json.String(p.profile_id),"display_name"=json.String(p.catalog.display_name),"label"=json.String(p.label_enc),"enabled"=json.Boolean(p.enabled),"profile_state"=json.String(p.profile_state),"detection_state"=json.String(p.detection_state),"models_state"=json.String(p.models_state),"models_source"=json.String(p.models_source),"models_checked_at"=json.String(p.models_checked_at),"eligible"=json.Boolean(eligible),"models"=models}
			if model_cursor!="" do row["models_next_cursor"]=json.String(model_cursor)
			owned:=catalog_public_copy(row).(json.Object);append(&rows,owned)
			last=p.profile_id
		}
		if a.provider_profile!="" && !profile_found do return {},"not_found"
	}
	out.records=rows[:]
	return out,""
}
