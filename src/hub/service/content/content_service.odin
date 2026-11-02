package content

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"
import platform "odin_test:hub/platform"
import agent_service "odin_test:hub/service/agent"
import project_service "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"

ARTIFACT_MAX_BYTES :: 50 * 1024 * 1024

// Built-in template content lives in domain (builtin_templates.odin) so the
// template API and the agent bootstrap share one compiled-in source.
coordinator_template :: proc() -> domain.Template { t, _ := domain.builtin_template(domain.TEMPLATE_COORDINATOR_ID); return t }
worker_template :: proc() -> domain.Template { t, _ := domain.builtin_template(domain.TEMPLATE_WORKER_ID); return t }
reviewer_template :: proc() -> domain.Template { t, _ := domain.builtin_template(domain.TEMPLATE_REVIEWER_ID); return t }
soloist_template :: proc() -> domain.Template { t, _ := domain.builtin_template(domain.TEMPLATE_SOLOIST_ID); return t }
empty_template :: proc() -> domain.Template { t, _ := domain.builtin_template(domain.TEMPLATE_EMPTY_ID); return t }

Content_Service :: struct { agent_configuration_service: ^agent_service.Agent_Service, content: ^iface.Content_Repository, agents: ^iface.Agent_Repository, bridges: ^iface.Bridge_Repository, projects: ^iface.Project_Repository, taskchains: ^iface.Taskchain_Repository, bridge_command_sink: project_service.Bridge_Command_Sink, clock: ^platform.Clock, ids: ^platform.ID_Generator, title_nudge_cooldown_seconds: int, audit_mode: bool, attention: ^contracts.Attention_Notifier }
Memory_Input :: struct { title,description,body,evidence,status,expires_at: string, proposed_by_instance_id,proposed_in_chain_id: string, agent_ids,template_ids,bridge_ids: []string, project_ids: []domain.Project_ID, type: domain.Memory_Type }
Memory_Update_Input :: struct {
	title:            string,
	description:      string,
	body:             string,
	evidence:         string,
	expires_at:       string,
	type:             domain.Memory_Type,
	agent_ids:        []string,
	project_ids:      []domain.Project_ID,
	bridge_ids:       []string,
	template_ids:     []string,
	has_title:        bool,
	has_description:  bool,
	has_body:         bool,
	has_evidence:     bool,
	has_expires_at:   bool,
	has_type:         bool,
	has_agent_ids:    bool,
	has_project_ids:  bool,
	has_bridge_ids:   bool,
	has_template_ids: bool,
}
// Memory_Filter narrows a memory listing by a single value per dimension. A
// memory matches a dimension filter when its targeting list is empty (a global
// memory that applies to all) OR the filter value is a member of the list.
Memory_Filter :: struct {
	status:      string,
	type:        string,
	agent_id:    string,
	project_id:  domain.Project_ID,
	bridge_id:   string,
	template_id: string,
}
Chat_Input :: struct { agent_id,agent_instance_id,chain_id,title,initial_body,artifact_ids_json,bridge_id,provider,provider_profile,model: string, project_id: domain.Project_ID }
Message_Input :: struct { body,artifact_ids_json,message_type,metadata_json: string }
Pane_Capture_Input :: struct { width, settle_ms, line_limit: int }
Pane_Capture_Result_Input :: struct { command_id,pane_capture_request_id,conversation_id,message_id,agent_instance_id,output,error_code,message: string, ok,truncated: bool, width,line_count: int }
Agent_Inbox_Filter :: struct { agent_instance_id: string, unread_only: bool, receiver_only: bool, include_outgoing: bool, include_debug: bool, limit: int, cursor: string }
Artifact_Input :: struct { kind,name,description,content_type,content,mime,ext,sha256,origin_kind,origin_ref,filename,agent_id,agent_instance_id,chain_id,task_id: string, project_id: domain.Project_ID }
// Template_Input carries a template create/update payload. The has_<field> flags
// distinguish "absent from the PATCH body" from "explicitly set to empty"
// (REQ-CLI-8) — without them, update_template assigned description/persona/
// instructions unconditionally, so a PATCH sending only `name` BLANKED the other
// three and returned 200. Same presence-flag convention as Memory_Update_Input
// just above, and Update_Task_Input in taskchain_service.
// create_template ignores the flags and reads the values directly.
Template_Input :: struct { name,description,persona,instructions: string, has_name,has_description,has_persona,has_instructions: bool }

new_content_service :: proc(content: ^iface.Content_Repository, agents: ^iface.Agent_Repository, bridges: ^iface.Bridge_Repository, projects: ^iface.Project_Repository, taskchains: ^iface.Taskchain_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Content_Service { return Content_Service{content=content, agents=agents, bridges=bridges, projects=projects, taskchains=taskchains, clock=clock, ids=ids} }
new_content_service_with_runtime :: proc(content: ^iface.Content_Repository, agents: ^iface.Agent_Repository, bridges: ^iface.Bridge_Repository, projects: ^iface.Project_Repository, taskchains: ^iface.Taskchain_Repository, sink: project_service.Bridge_Command_Sink, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Content_Service { return Content_Service{content=content, agents=agents, bridges=bridges, projects=projects, taskchains=taskchains, bridge_command_sink=sink, clock=clock, ids=ids} }

create_memory :: proc(s:^Content_Service, auth:contracts.Auth_Context, input:Memory_Input)->(domain.Memory,bool,domain.Domain_Error){
	owner,ok,err:=ownership.owner_from_auth(auth); if !ok do return {},false,err;
	if strings.trim_space(input.body)=="" do return {},false,domain.domain_error(.Validation_Failed,"memory body is required");
	if input.type==.Unknown do return {},false,domain.domain_error(.Validation_Failed,"memory type is invalid");
	if verr:=validate_memory_targets(s,owner,input.agent_ids,input.project_ids,input.template_ids,input.bridge_ids); verr.code!=.None do return {},false,verr;
	now:=platform.clock_now(s.clock);
	status:=input.status; if status=="" do status="pending";
	typ:=input.type; if typ==.Unknown do typ=.Fact;
	expires_at := input.expires_at;
	if expires_at == "" {
		if t, t_ok := platform.parse_rfc3339_utc(now); t_ok {
			expires_at = platform.format_rfc3339_utc(time.time_add(t, 24 * time.Hour))
		} else {
			expires_at = platform.expires_at_after_seconds(24 * 3600)
		}
	}
	m:=domain.Memory{memory_id=platform.generate_id(s.ids,"mem_"),owner_user_id=owner,agent_ids=input.agent_ids,project_ids=input.project_ids,template_ids=input.template_ids,bridge_ids=input.bridge_ids,type=typ,status=status,title=input.title,description=input.description,body=input.body,evidence=input.evidence,expires_at=expires_at,created_at=now,updated_at=now,proposed_by_instance_id=input.proposed_by_instance_id,proposed_in_chain_id=input.proposed_in_chain_id};
	return save_memory(s,m)
}

// validate_memory_targets checks that every id in each targeting list is owned
// by (or available to) the caller. Empty lists are always valid ("applies to
// all"). Returns a zero Domain_Error when all ids validate.
validate_memory_targets :: proc(s:^Content_Service, owner:domain.User_ID, agent_ids:[]string, project_ids:[]domain.Project_ID, template_ids:[]string, bridge_ids:[]string)->domain.Domain_Error{
	for id in agent_ids { if id!="" && !agent_owned(s,owner,id) do return domain.domain_error(.Not_Found,"agent not found") }
	for id in project_ids { if string(id)!="" && !project_owned(s,owner,id) do return domain.domain_error(.Not_Found,"project not found") }
	for id in template_ids { if id!="" && !template_available(s,owner,id) do return domain.domain_error(.Not_Found,"template not found") }
	for id in bridge_ids { if id!="" && !bridge_owned(s,owner,id) do return domain.domain_error(.Not_Found,"bridge not found") }
	return {}
}
list_memories :: proc(s:^Content_Service, auth:contracts.Auth_Context, filter:Memory_Filter={}, limit:int=50, cursor:string="")->([]domain.Memory,domain.Domain_Error){
	owner,ok,err:=ownership.owner_from_auth(auth); if !ok do return nil,err
	all,list_err:=iface.content_list_memories(s.content,owner); if list_err.code!=.None do return nil,list_err
	eff_limit:=limit; if eff_limit<=0 do eff_limit=50; if eff_limit>200 do eff_limit=200
	filtered:=make([dynamic]domain.Memory,0,len(all)); defer delete(filtered)
	for m in all {
		if filter.status!="" && m.status!=filter.status do continue
		if filter.type!="" && domain.memory_type_string(m.type)!=filter.type do continue
		// A dimension filter matches when the memory's targeting list is empty
		// (a global memory that applies to all) OR the filter value is a member.
		if !memory_filter_matches(m.agent_ids,filter.agent_id) do continue
		if !memory_filter_project_matches(m.project_ids,filter.project_id) do continue
		if !memory_filter_matches(m.bridge_ids,filter.bridge_id) do continue
		if !memory_filter_matches(m.template_ids,filter.template_id) do continue
		append(&filtered,m)
	}
	out:=make([dynamic]domain.Memory)
	seeking:=cursor!=""
	for m in filtered {
		if seeking {
			if m.updated_at < cursor {
				seeking=false
			} else {
				continue
			}
		}
		if len(out)>=eff_limit do break
		append(&out,m)
	}
	return out[:],{}
}
// memory_filter_matches: an empty filter value imposes no constraint; otherwise
// the memory matches when its targeting list is empty (global) OR contains the
// filter value.
memory_filter_matches :: proc(list:[]string, value:string)->bool{ if value=="" do return true; if len(list)==0 do return true; for v in list do if v==value do return true; return false }
memory_filter_project_matches :: proc(list:[]domain.Project_ID, value:domain.Project_ID)->bool{ if string(value)=="" do return true; if len(list)==0 do return true; for v in list do if v==value do return true; return false }
get_memory :: proc(s:^Content_Service, auth:contracts.Auth_Context, id:string)->(domain.Memory,bool,domain.Domain_Error){ m,ok,err:=iface.content_get_memory(s.content,id); if !ok do return {},false,err; if m.owner_user_id=="system" do return m,true,{}; if ok2,e:=ownership.require_owner(auth,m.owner_user_id); !ok2 do return {},false,e; return m,true,{} }
update_memory :: proc(s:^Content_Service, auth:contracts.Auth_Context, id:string, input:Memory_Update_Input)->(domain.Memory,bool,domain.Domain_Error){
	m,ok,err:=iface.content_get_memory(s.content,id); if !ok do return {},false,err
	if m.owner_user_id=="system" do return {},false,domain.domain_error(.Forbidden,"system memories are read-only")
	if ok2,e:=ownership.require_owner(auth,m.owner_user_id); !ok2 do return {},false,e
	if m.status!="pending" && m.status!="active" do return {},false,domain.domain_error(.Validation_Failed,"only pending or active memories can be updated")
	owner,own_ok,own_err:=ownership.owner_from_auth(auth); if !own_ok do return {},false,own_err
	if input.has_agent_ids { for id in input.agent_ids { if id!="" && !agent_owned(s,owner,id) do return {},false,domain.domain_error(.Not_Found,"agent not found") } }
	if input.has_project_ids { for id in input.project_ids { if string(id)!="" && !project_owned(s,owner,id) do return {},false,domain.domain_error(.Not_Found,"project not found") } }
	if input.has_template_ids { for id in input.template_ids { if id!="" && !template_available(s,owner,id) do return {},false,domain.domain_error(.Not_Found,"template not found") } }
	if input.has_bridge_ids { for id in input.bridge_ids { if id!="" && !bridge_owned(s,owner,id) do return {},false,domain.domain_error(.Not_Found,"bridge not found") } }
	if input.has_title do m.title=input.title
	if input.has_description do m.description=input.description
	if input.has_body { if strings.trim_space(input.body)=="" do return {},false,domain.domain_error(.Validation_Failed,"memory body is required"); m.body=input.body }
	if input.has_evidence do m.evidence=input.evidence
	if input.has_expires_at do m.expires_at=input.expires_at
	if input.has_type { if input.type==.Unknown do return {},false,domain.domain_error(.Validation_Failed,"memory type is invalid"); m.type=input.type }
	if input.has_agent_ids do m.agent_ids=input.agent_ids
	if input.has_project_ids do m.project_ids=input.project_ids
	if input.has_bridge_ids do m.bridge_ids=input.bridge_ids
	if input.has_template_ids do m.template_ids=input.template_ids
	m.updated_at=platform.clock_now(s.clock)
	return save_memory(s,m)
}
update_memory_status :: proc(s:^Content_Service, auth:contracts.Auth_Context, id,status:string)->(domain.Memory,bool,domain.Domain_Error){ m,ok,err:=iface.content_get_memory(s.content,id); if !ok do return {},false,err; if m.owner_user_id=="system" do return {},false,domain.domain_error(.Forbidden,"system memories are read-only"); if ok2,e:=ownership.require_owner(auth,m.owner_user_id); !ok2 do return {},false,e; m.status=status; m.updated_at=platform.clock_now(s.clock); return save_memory(s,m) }
archive_memory :: proc(s:^Content_Service, auth:contracts.Auth_Context,id:string)->(domain.Memory,bool,domain.Domain_Error){ return update_memory_status(s,auth,id,"archived") }
approve_memory :: proc(s:^Content_Service, auth:contracts.Auth_Context,id:string, input:Memory_Update_Input={}, has_edits:bool=false)->(domain.Memory,bool,domain.Domain_Error){
	if !has_edits do return update_memory_status(s,auth,id,"active")
	m,ok,err:=iface.content_get_memory(s.content,id); if !ok do return {},false,err
	if m.owner_user_id=="system" do return {},false,domain.domain_error(.Forbidden,"system memories are read-only")
	if ok2,e:=ownership.require_owner(auth,m.owner_user_id); !ok2 do return {},false,e
	owner,own_ok,own_err:=ownership.owner_from_auth(auth); if !own_ok do return {},false,own_err
	if input.has_agent_ids { for id in input.agent_ids { if id!="" && !agent_owned(s,owner,id) do return {},false,domain.domain_error(.Not_Found,"agent not found") } }
	if input.has_project_ids { for id in input.project_ids { if string(id)!="" && !project_owned(s,owner,id) do return {},false,domain.domain_error(.Not_Found,"project not found") } }
	if input.has_template_ids { for id in input.template_ids { if id!="" && !template_available(s,owner,id) do return {},false,domain.domain_error(.Not_Found,"template not found") } }
	if input.has_bridge_ids { for id in input.bridge_ids { if id!="" && !bridge_owned(s,owner,id) do return {},false,domain.domain_error(.Not_Found,"bridge not found") } }
	if input.has_title do m.title=input.title
	if input.has_description do m.description=input.description
	if input.has_body { if strings.trim_space(input.body)=="" do return {},false,domain.domain_error(.Validation_Failed,"memory body is required"); m.body=input.body }
	if input.has_evidence do m.evidence=input.evidence
	if input.has_expires_at do m.expires_at=input.expires_at
	if input.has_type { if input.type==.Unknown do return {},false,domain.domain_error(.Validation_Failed,"memory type is invalid"); m.type=input.type }
	if input.has_agent_ids do m.agent_ids=input.agent_ids
	if input.has_project_ids do m.project_ids=input.project_ids
	if input.has_bridge_ids do m.bridge_ids=input.bridge_ids
	if input.has_template_ids do m.template_ids=input.template_ids
	m.status="active"
	m.updated_at=platform.clock_now(s.clock)
	return save_memory(s,m)
}
reject_memory :: proc(s:^Content_Service, auth:contracts.Auth_Context,id:string)->(domain.Memory,bool,domain.Domain_Error){ return update_memory_status(s,auth,id,"rejected") }

create_conversation :: proc(s:^Content_Service, auth:contracts.Auth_Context, input:Chat_Input)->(domain.Chat_Conversation,bool,domain.Domain_Error){ owner,ok,err:=ownership.owner_from_auth(auth); if !ok do return {},false,err; if input.agent_id=="" do return {},false,domain.domain_error(.Validation_Failed,"agent_id is required"); if input.agent_instance_id=="" do return {},false,domain.domain_error(.Validation_Failed,"agent_instance_id is required"); if !agent_owned(s,owner,input.agent_id) do return {},false,domain.domain_error(.Not_Found,"agent not found"); if bind_ok,bind_err:=conversation_instance_binding_valid(s,owner,input); !bind_ok do return {},false,bind_err; initial:=Message_Input{body=input.initial_body,artifact_ids_json=input.artifact_ids_json}; if strings.trim_space(input.initial_body)!="" { if msg_ok,msg_err:=validate_initial_message(s,auth,initial); !msg_ok do return {},false,msg_err }; now:=platform.clock_now(s.clock); title:=conversation_title_from_input(input.title,input.agent_id); c:=domain.Chat_Conversation{conversation_id=platform.generate_id(s.ids,"chat_"),owner_user_id=owner,agent_id=input.agent_id,agent_instance_id=input.agent_instance_id,project_id=input.project_id,chain_id=input.chain_id,title=title,created_at=now,updated_at=now}; saved,save_ok,save_err:=iface.content_save_conversation(s.content,c); if !save_ok do return {},false,save_err; if strings.trim_space(input.initial_body)!="" { _,sent,send_err := send_message(s,auth,saved.conversation_id,initial); if !sent do return {},false,send_err; updated,got,_:=iface.content_get_conversation(s.content,saved.conversation_id); if got do saved=updated }; return saved,true,{} }
list_conversations :: proc(s:^Content_Service, auth:contracts.Auth_Context, limit:int, cursor:string)->([]domain.Chat_Conversation,domain.Domain_Error){ owner,ok,err:=ownership.owner_from_auth(auth); if !ok do return nil,err; return iface.content_list_conversations(s.content,owner,limit,cursor) }
list_conversation_project_links :: proc(s: ^Content_Service, auth: contracts.Auth_Context) -> ([]domain.Conversation_Project_Link, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err
	return iface.content_list_conversation_project_links(s.content, owner)
}
get_conversation :: proc(s:^Content_Service, auth:contracts.Auth_Context,id:string)->(domain.Chat_Conversation,bool,domain.Domain_Error){ c,ok,err:=iface.content_get_conversation(s.content,id); if !ok do return {},false,err; if ok2,e:=ownership.require_owner(auth,c.owner_user_id); !ok2 do return {},false,e; return c,true,{} }
update_conversation_title :: proc(s:^Content_Service, auth:contracts.Auth_Context,id,title:string, source:string="")->(domain.Chat_Conversation,bool,domain.Domain_Error){ c,ok,err:=get_conversation(s,auth,id); if !ok do return {},false,err; next_title:=strings.trim_space(title); if next_title=="" do return {},false,domain.domain_error(.Validation_Failed,"conversation title is required"); if cap_err:=domain.validate_capped_text("conversation title",next_title,domain.CONVERSATION_TITLE_MAX_BYTES); cap_err.code!=.None do return {},false,cap_err; c.title=next_title; if source=="agent" || source=="user" || source=="default" do c.title_source=source; c.updated_at=platform.clock_now(s.clock); return iface.content_save_conversation(s.content,c) }

// set_own_conversation_title lets an authenticated agent instance rename ITS OWN
// bound conversation (T3/REQ-3). Resolves the conversation from the instance
// token, sets the title, and stamps title_source="agent" so the activity-gated
// nudge engine (T2) stops nudging this conversation.
set_own_conversation_title :: proc(s:^Content_Service, auth:contracts.Auth_Context, instance_id, title:string)->(domain.Chat_Conversation,bool,domain.Domain_Error){ if auth.kind!=.Instance_Token || auth.agent_instance_id=="" || auth.agent_instance_id!=instance_id do return {},false,domain.domain_error(.Forbidden,"instance token is required"); c,ok,err:=get_conversation_by_instance(s,auth,instance_id); if !ok do return {},false,err; return update_conversation_title(s,auth,c.conversation_id,title,"agent") }
get_conversation_by_instance :: proc(s:^Content_Service, auth:contracts.Auth_Context, instance_id:string)->(domain.Chat_Conversation,bool,domain.Domain_Error){ owner,ok,err:=ownership.owner_from_auth(auth); if !ok do return {},false,err; rows,list_err:=iface.content_list_conversations(s.content,owner,512,""); if list_err.code!=.None do return {},false,list_err; for c in rows { if c.agent_instance_id==instance_id do return c,true,{} }; return {},false,domain.domain_error(.Not_Found,"conversation not found") }
list_messages :: proc(s:^Content_Service, auth:contracts.Auth_Context,cid:string,limit:int,cursor:string)->([]domain.Chat_Message,domain.Domain_Error){ c,ok,err:=get_conversation(s,auth,cid); if !ok do return nil,err; rows,list_err:=iface.content_list_messages(s.content,c.conversation_id,c.owner_user_id,limit,cursor); if list_err.code!=.None do return nil,list_err; repair_stale_pane_captures(s, rows); return rows,{} }
list_user_visible_messages :: proc(s:^Content_Service, auth:contracts.Auth_Context,cid:string,limit:int,cursor:string)->([]domain.Chat_Message,domain.Domain_Error){ c,ok,err:=get_conversation(s,auth,cid); if !ok do return nil,err; rows,list_err:=iface.content_list_user_visible_messages(s.content,c.conversation_id,c.owner_user_id,limit,cursor); if list_err.code!=.None do return nil,list_err; repair_stale_pane_captures(s, rows); return rows,{} }
list_agent_inbox_messages :: proc(s:^Content_Service, auth:contracts.Auth_Context, filter: Agent_Inbox_Filter) -> ([]domain.Chat_Message,domain.Domain_Error){ owner,ok,err:=ownership.owner_from_auth(auth); if !ok do return nil,err; c,conv_ok,conv_err:=get_conversation_by_instance(s,auth,filter.agent_instance_id); if !conv_ok do return nil,conv_err; limit := filter.limit; if limit <= 0 do limit = 50; if limit > 200 do limit = 200; rows,list_err:=iface.content_list_agent_inbox_messages(s.content,c.conversation_id,c.owner_user_id,filter.agent_instance_id,filter.unread_only,filter.receiver_only,filter.include_outgoing,filter.include_debug,limit,filter.cursor); if list_err.code!=.None do return nil,list_err; repair_stale_pane_captures(s, rows); return rows,{} }
mark_messages_read_by_ids :: proc(s:^Content_Service, auth:contracts.Auth_Context, message_ids:[]string) -> (int,domain.Domain_Error){ n,_,err:=mark_messages_read_by_ids_at(s,auth,message_ids); return n,err }
// mark_messages_read_by_ids_at also returns the read_at it wrote, so callers can
// report the committed receipt instead of the pre-mark row (E4).
mark_messages_read_by_ids_at :: proc(s:^Content_Service, auth:contracts.Auth_Context, message_ids:[]string) -> (int,string,domain.Domain_Error){ owner,ok,err:=ownership.owner_from_auth(auth); if !ok do return 0,"",err; read_at:=platform.clock_now(s.clock); n,mark_err:=iface.content_mark_messages_read(s.content, owner, message_ids, read_at); return n,read_at,mark_err }
send_message :: proc(s:^Content_Service, auth:contracts.Auth_Context,cid:string,input:Message_Input)->(domain.Chat_Message,bool,domain.Domain_Error){ c,ok,err:=get_conversation(s,auth,cid); if !ok do return {},false,err; if s.agent_configuration_service != nil { if valid, validity_err := agent_service.validate_instance_message_configuration(s.agent_configuration_service,c.owner_user_id,c.agent_instance_id); !valid do return {},false,validity_err } else { if idle, idle_err := agent_service.reconfiguration_require_idle(&agent_service.Agent_Service{agents=s.agents}, c.agent_instance_id); !idle do return {},false,idle_err }; if msg_ok,msg_err:=validate_initial_message_for_owner(s,c.owner_user_id,input); !msg_ok do return {},false,msg_err; now:=platform.clock_now(s.clock); m_type:=input.message_type if input.message_type!="" else "text"; m:=domain.Chat_Message{message_id=platform.generate_id(s.ids,"msg_"),conversation_id=c.conversation_id,owner_user_id=c.owner_user_id,direction="user_to_agent",sender_agent_id=c.agent_id,sender_agent_instance_id=c.agent_instance_id,body=input.body,artifact_ids_json=artifact_json_or_empty(input.artifact_ids_json),message_type=m_type,metadata_json=input.metadata_json,created_at=now}; saved,save_ok,save_err:=save_message(s,m); if !save_ok do return {},false,save_err; c.last_message_preview=input.body; c.last_message_at=now; c.updated_at=now; _,_,_=iface.content_save_conversation(s.content,c); notify_agent_message(s,c,"user_to_agent","user",saved.message_id,"User"); record_activity_and_maybe_nudge(s,c.conversation_id,now); return saved,true,{} }
send_agent_message :: proc(s:^Content_Service, auth:contracts.Auth_Context, instance_id:string, input:Message_Input)->(domain.Chat_Message,bool,domain.Domain_Error){
	return send_agent_message_with_id(s, auth, instance_id, input, platform.generate_id(s.ids, "msg_"))
}

send_agent_message_with_id :: proc(s: ^Content_Service, auth: contracts.Auth_Context, instance_id: string, input: Message_Input, message_id: string) -> (domain.Chat_Message, bool, domain.Domain_Error) {
	if auth.kind != .Instance_Token || auth.agent_instance_id == "" || auth.agent_instance_id != instance_id do return {}, false, domain.domain_error(.Forbidden, "instance token is required")
	c, ok, err := get_conversation_by_instance(s, auth, instance_id)
	if !ok do return {}, false, err
	if msg_ok, msg_err := validate_initial_message_for_owner(s, c.owner_user_id, input); !msg_ok do return {}, false, msg_err
	now := platform.clock_now(s.clock)
	m_type := input.message_type if input.message_type != "" else "text"
	m := domain.Chat_Message{message_id = message_id, conversation_id = c.conversation_id, owner_user_id = c.owner_user_id, direction = "agent_to_user", sender_agent_id = c.agent_id, sender_agent_instance_id = c.agent_instance_id, body = input.body, artifact_ids_json = artifact_json_or_empty(input.artifact_ids_json), message_type = m_type, metadata_json = input.metadata_json, created_at = now}
	saved, save_ok, save_err := save_message(s, m)
	if !save_ok do return {}, false, save_err
	c.last_message_preview = input.body
	c.last_message_at = now
	c.unread_count += 1
	c.updated_at = now
	_, _, _ = iface.content_save_conversation(s.content, c)
	record_activity_and_maybe_nudge(s, c.conversation_id, now)
	return saved, true, {}
}
send_agent_to_agent :: proc(s:^Content_Service, auth:contracts.Auth_Context, target_instance_id:string, input:Message_Input)->(domain.Chat_Message,bool,domain.Domain_Error){ if auth.kind!=.Instance_Token || auth.agent_instance_id=="" do return {},false,domain.domain_error(.Forbidden,"instance token is required"); if strings.trim_space(target_instance_id)=="" do return {},false,domain.domain_error(.Validation_Failed,"to_instance is required"); if s.agents==nil do return {},false,domain.domain_error(.Internal_Error,"agent repository is not configured"); sender, sender_ok, _ := iface.agent_get_instance(s.agents, auth.agent_instance_id); if !sender_ok do return {},false,domain.domain_error(.Not_Found,"sender instance not found"); if s.agent_configuration_service != nil { if valid, validity_err := agent_service.validate_instance_message_configuration(s.agent_configuration_service,sender.owner_user_id,target_instance_id); !valid do return {},false,validity_err } else { if idle, idle_err := agent_service.reconfiguration_require_idle(&agent_service.Agent_Service{agents=s.agents}, target_instance_id); !idle do return {},false,idle_err }; target, target_ok, _ := iface.agent_get_instance(s.agents, target_instance_id); if !target_ok || target.owner_user_id!=sender.owner_user_id do return {},false,domain.domain_error(.Not_Found,"target instance not found"); c,conv_ok,conv_err:=get_conversation_by_instance(s,contracts.Auth_Context{kind=.Internal_User,user_id=string(target.owner_user_id)},target.agent_instance_id); if !conv_ok do return {},false,conv_err; if msg_ok,msg_err:=validate_initial_message_for_owner(s,c.owner_user_id,input); !msg_ok do return {},false,msg_err; now:=platform.clock_now(s.clock); m_type:=input.message_type if input.message_type!="" else "text"; m:=domain.Chat_Message{message_id=platform.generate_id(s.ids,"msg_"),conversation_id=c.conversation_id,owner_user_id=c.owner_user_id,direction="agent_to_agent",sender_agent_id=sender.agent_id,sender_agent_instance_id=sender.agent_instance_id,body=input.body,artifact_ids_json=artifact_json_or_empty(input.artifact_ids_json),message_type=m_type,metadata_json=input.metadata_json,created_at=now}; saved,save_ok,save_err:=save_message(s,m); if !save_ok do return {},false,save_err; c.last_message_preview=input.body; c.last_message_at=now; c.updated_at=now; _,_,_=iface.content_save_conversation(s.content,c); notify_agent_message(s,c,"agent_to_agent",sender.agent_instance_id,saved.message_id,sender.display_name); record_activity_and_maybe_nudge(s,c.conversation_id,now); return saved,true,{} }
request_pane_capture :: proc(s:^Content_Service, auth:contracts.Auth_Context,cid:string,input:Pane_Capture_Input)->(domain.Chat_Message,bool,domain.Domain_Error){ c,ok,err:=get_conversation(s,auth,cid); if !ok do return {},false,err; if s.audit_mode { env_user := os.get_env("USER", context.allocator); conv_owner := string(c.owner_user_id); is_owner := (auth.user_id == conv_owner) || (env_user != "" && auth.user_id == env_user) || (auth.user_id == "default"); if !is_owner do return {},false,domain.domain_error(.Forbidden,"audit mode active: pane capture/PTY operations disabled for non-owner"); }; if s.agents==nil do return {},false,domain.domain_error(.Internal_Error,"agent repository is not configured"); if c.agent_instance_id=="" do return {},false,domain.domain_error(.Validation_Failed,"conversation has no agent instance"); inst,inst_ok,_:=iface.agent_get_instance(s.agents,c.agent_instance_id); if !inst_ok || inst.owner_user_id!=c.owner_user_id do return {},false,domain.domain_error(.Not_Found,"agent instance not found"); if inst.bridge_id=="" do return {},false,domain.domain_error(.Bridge_Offline,"agent instance has no bridge"); if !bridge_supports_pane_capture(s,inst.bridge_id) do return {},false,domain.domain_error(.Validation_Failed,"bridge does not support pane capture"); width:=pane_capture_clamp(input.width,80,40,200); settle:=pane_capture_clamp(input.settle_ms,3000,500,10000); lines:=pane_capture_clamp(input.line_limit,120,20,300); if pending,pending_ok:=pending_pane_capture(s,c); pending_ok do return pending,true,{}; now:=platform.clock_now(s.clock); req_id:=platform.generate_id(s.ids,"cap_"); msg_id:=platform.generate_id(s.ids,"msg_"); timeout_at:=platform.expires_at_after_seconds((settle+30000)/1000); metadata:=pane_capture_metadata(req_id,c.agent_instance_id,inst.bridge_id,width,settle,lines,0,false,"",timeout_at); m:=domain.Chat_Message{message_id=msg_id,conversation_id=c.conversation_id,owner_user_id=c.owner_user_id,direction="agent_to_user",sender_agent_id=c.agent_id,sender_agent_instance_id=c.agent_instance_id,body="Requesting pane capture...",artifact_ids_json="[]",message_type="pane_capture",message_status="pending",metadata_json=metadata,created_at=now}; saved,save_ok,save_err:=save_message(s,m); if !save_ok do return {},false,save_err; c.last_message_preview="Requesting pane capture..."; c.last_message_at=now; c.updated_at=now; _,_,_=iface.content_save_conversation(s.content,c); command_id:=platform.generate_id(s.ids,"cmd_"); sent,send_err:=project_service.bridge_command_send_runtime(s.bridge_command_sink, project_service.Runtime_Command{bridge_id=inst.bridge_id,command_id=command_id,body_json=pane_capture_command_json(command_id,req_id,c.conversation_id,msg_id,c.agent_instance_id,width,settle,lines)}); if !sent { failed,_:=mark_pane_capture_failed(s,saved,"bridge_unavailable",send_err.message); if failed.message_id!="" { c.last_message_preview=failed.body; c.last_message_at=platform.clock_now(s.clock); c.updated_at=c.last_message_at; _,_,_=iface.content_save_conversation(s.content,c) }; return failed,true,{} }; return saved,true,{} }
complete_pane_capture :: proc(s:^Content_Service, bridge_id:string,input:Pane_Capture_Result_Input)->(domain.Chat_Message,domain.Chat_Conversation,bool,domain.Domain_Error){
	if strings.trim_space(input.conversation_id)=="" || strings.trim_space(input.message_id)=="" do return {},{},false,domain.domain_error(.Validation_Failed,"pane capture result ids are required")
	c,conv_ok,conv_err:=iface.content_get_conversation(s.content,input.conversation_id)
	if !conv_ok do return {},{},false,conv_err
	if s.agents==nil do return {},{},false,domain.domain_error(.Internal_Error,"agent repository is not configured")
	inst,inst_ok,_:=iface.agent_get_instance(s.agents,c.agent_instance_id)
	if !inst_ok || inst.bridge_id!=bridge_id || input.agent_instance_id!=c.agent_instance_id do return {},{},false,domain.domain_error(.Forbidden,"pane capture result does not match conversation bridge")
	m,msg_ok,msg_err:=iface.content_get_message(s.content,input.message_id)
	if !msg_ok do return {},{},false,msg_err
	if m.owner_user_id!=c.owner_user_id || m.conversation_id!=c.conversation_id || m.message_type!="pane_capture" do return {},{},false,domain.domain_error(.Forbidden,"pane capture placeholder mismatch")
	expected_req:=pane_capture_json_string(m.metadata_json,"pane_capture_request_id")
	defer delete(expected_req)
	if expected_req=="" || input.pane_capture_request_id!=expected_req do return {},{},false,domain.domain_error(.Forbidden,"pane capture request mismatch")
	if m.message_status=="complete" || m.message_status=="failed" do return m,c,true,{}
	status:="complete"
	body:=pane_capture_limit_output(input.output)
	error_code:=""
	output_truncated:=input.truncated || len(input.output)>48000
	if !input.ok {
		status="failed"
		error_code=input.error_code
		if error_code=="" do error_code="capture_failed"
		body=pane_capture_limit_output(input.message)
		if strings.trim_space(body)=="" do body=pane_capture_failure_message(error_code)
	}
	metadata:=pane_capture_metadata(input.pane_capture_request_id,c.agent_instance_id,inst.bridge_id,input.width,0,0,input.line_count,output_truncated,error_code,"")
	defer delete(metadata)
	updated,updated_ok,update_err:=update_message(s,c.owner_user_id,c.conversation_id,m.message_id,body,status,metadata)
	if !updated_ok do return {},{},false,update_err
	c.last_message_preview="Pane capture ready" if input.ok else body
	c.last_message_at=platform.clock_now(s.clock)
	c.updated_at=c.last_message_at
	_,_,_=iface.content_save_conversation(s.content,c)
	return updated,c,true,{}
}
mark_read :: proc(s:^Content_Service, auth:contracts.Auth_Context,cid:string)->(domain.Chat_Conversation,bool,domain.Domain_Error){ c,ids,ok,err:=mark_read_with_receipts(s,auth,cid); delete(ids); return c,ok,err }
// Marks a conversation read: stamps read_at on every unread incoming
// (agent_to_user) message and zeros the conversation unread_count. Returns the
// updated conversation plus the ids of the messages that were newly stamped so
// callers can emit read-receipt events. The returned id slice is heap-allocated
// (caller owns it); it is empty when nothing needed marking.
mark_read_with_receipts :: proc(s:^Content_Service, auth:contracts.Auth_Context,cid:string)->(domain.Chat_Conversation,[]string,bool,domain.Domain_Error){
	c,ok,err:=get_conversation(s,auth,cid); if !ok do return {},nil,false,err
	// Collect EVERY unread incoming message (read_at empty, direction
	// agent_to_user). A capped page would leave older unread rows behind -- and an
	// older unread question would immediately resurface as an attention card.
	marked_ids:=make([dynamic]string)
	all_ids,all_supported,all_err:=iface.content_list_unread_incoming_ids(s.content,c.conversation_id,c.owner_user_id)
	if all_supported {
		if all_err.code!=.None { delete(marked_ids); return {},nil,false,all_err }
		append(&marked_ids,..all_ids)
	} else {
		// Repositories without the unbounded lookup (test fakes): newest 200.
		rows,list_err:=iface.content_list_user_visible_messages(s.content,c.conversation_id,c.owner_user_id,200,"")
		if list_err.code==.None {
			for m in rows {
				if m.read_at=="" && m.direction=="agent_to_user" do append(&marked_ids,m.message_id)
			}
		}
	}
	// One instant for the receipts and the row's updated_at, so the
	// messages_read event's read_at equals what a refetch returns.
	read_at:=platform.clock_now(s.clock)
	if len(marked_ids)>0 {
		owner,owner_ok,owner_err:=ownership.owner_from_auth(auth); if !owner_ok { delete(marked_ids); return {},nil,false,owner_err }
		// Batched: one statement binds one parameter per id, and a conversation
		// can hold more unread rows than SQLite allows variables in a statement.
		MARK_READ_BATCH :: 500
		for start:=0; start<len(marked_ids); start+=MARK_READ_BATCH {
			end:=min(start+MARK_READ_BATCH,len(marked_ids))
			_,mark_err:=iface.content_mark_messages_read(s.content,owner,marked_ids[start:end],read_at)
			if mark_err.code!=.None {
				// Earlier batches did commit: let the projector re-read so the
				// card matches what is actually still unread, then report.
				if start>0 do notify_conversation_attention(s,c)
				delete(marked_ids); return {},nil,false,mark_err
			}
		}
	}
	c.unread_count=0; c.updated_at=read_at
	saved,save_ok,save_err:=iface.content_save_conversation(s.content,c)
	if !save_ok { delete(marked_ids); return {},nil,false,save_err }
	if len(marked_ids)>0 do notify_conversation_attention(s,saved)
	return saved,marked_ids[:],true,{}
}
message_body_for_response :: proc(s:^Content_Service, m:domain.Chat_Message)->string{ if artifact_refs_have_missing(s,m.owner_user_id,m.artifact_ids_json) do return strings.concatenate({m.body,"\n[artifact unavailable/deleted]"}); return m.body }

create_artifact :: proc(s:^Content_Service, auth:contracts.Auth_Context,input:Artifact_Input)->(domain.Artifact,bool,domain.Domain_Error){ owner,ok,err:=ownership.owner_from_auth(auth); if !ok do return {},false,err; if len(input.content)>ARTIFACT_MAX_BYTES do return {},false,domain.domain_error(.Validation_Failed,fmt.tprintf("artifact is too large; maximum size is %d MB", ARTIFACT_MAX_BYTES/(1024*1024))); if ok_ctx,ctx_err:=artifact_context_owned(s,owner,input); !ok_ctx do return {},false,ctx_err; name:=input.name; if name=="" do name=input.filename; if name=="" do name="artifact"; kind:=input.kind; if kind=="" do kind="file"; now:=platform.clock_now(s.clock); a:=domain.Artifact{artifact_id=platform.generate_id(s.ids,"art_"),owner_user_id=owner,kind=kind,name=name,description=input.description,content_type=input.content_type,size_bytes=len(input.content),content=input.content,mime=input.mime,ext=input.ext,sha256=input.sha256,origin_kind=input.origin_kind,origin_ref=input.origin_ref,agent_id=input.agent_id,agent_instance_id=input.agent_instance_id,chain_id=input.chain_id,task_id=input.task_id,project_id=input.project_id,created_at=now,updated_at=now}; return iface.content_save_artifact(s.content,a) }
list_artifacts :: proc(s: ^Content_Service, auth: contracts.Auth_Context, filter: domain.Artifact_List_Filter) -> ([]domain.Artifact, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err

	f := filter
	if f.limit <= 0 do f.limit = 50
	if f.limit > 200 do f.limit = 200

	sort_field_lower := strings.to_lower(strings.trim_space(f.sort_field), context.temp_allocator)
	switch sort_field_lower {
	case "created_at", "updated_at", "name", "size_bytes":
	case "":
		f.sort_field = "updated_at"
	case:
		return nil, domain.domain_error(.Validation_Failed, "invalid sort field; allowed: created_at, updated_at, name, size_bytes")
	}

	sort_order_lower := strings.to_lower(strings.trim_space(f.sort_order), context.temp_allocator)
	switch sort_order_lower {
	case "asc", "desc":
	case "":
		f.sort_order = "desc"
	case:
		return nil, domain.domain_error(.Validation_Failed, "invalid sort order; allowed: asc, desc")
	}

	return iface.content_list_artifacts(s.content, owner, f)
}
get_artifact :: proc(s:^Content_Service, auth:contracts.Auth_Context,id:string)->(domain.Artifact,bool,domain.Domain_Error){ a,ok,err:=iface.content_get_artifact(s.content,id); if !ok do return {},false,err; if ok2,e:=ownership.require_owner(auth,a.owner_user_id); !ok2 do return {},false,e; return a,true,{} }
update_artifact :: proc(s:^Content_Service, auth:contracts.Auth_Context,id,name,description:string)->(domain.Artifact,bool,domain.Domain_Error){ a,ok,err:=get_artifact(s,auth,id); if !ok do return {},false,err; if name!="" do a.name=name; if description!="" do a.description=description; a.updated_at=platform.clock_now(s.clock); return iface.content_save_artifact(s.content,a) }
delete_artifact :: proc(s:^Content_Service, auth:contracts.Auth_Context,id:string)->(bool,domain.Domain_Error){ a,ok,err:=get_artifact(s,auth,id); if !ok do return false,err; return iface.content_delete_artifact(s.content,a.artifact_id,a.owner_user_id) }

create_template :: proc(s:^Content_Service, auth:contracts.Auth_Context,input:Template_Input)->(domain.Template,bool,domain.Domain_Error){ owner,ok,err:=ownership.owner_from_auth(auth); if !ok do return {},false,err; if input.name=="" do return {},false,domain.domain_error(.Validation_Failed,"template name is required"); now:=platform.clock_now(s.clock); t:=domain.Template{template_id=platform.generate_id(s.ids,"tmpl_"),owner_user_id=owner,name=input.name,description=input.description,persona=input.persona,instructions=input.instructions,created_at=now,updated_at=now}; return iface.content_save_template(s.content,t) }
get_template :: proc(s:^Content_Service, auth:contracts.Auth_Context,id:string)->(domain.Template,bool,domain.Domain_Error){
	owner,ok,err:=ownership.owner_from_auth(auth); if !ok do return {},false,err;
	if builtin, is_builtin := domain.builtin_template(id); is_builtin do return builtin, true, {}
	t,ok2,err2:=iface.content_get_template(s.content,id); if !ok2 do return {},false,err2;
	if !t.is_system && t.owner_user_id!=owner do return {},false,domain.domain_error(.Not_Found,"template not found");
	return t,true,{}
}
update_template :: proc(s:^Content_Service, auth:contracts.Auth_Context,id:string,input:Template_Input)->(domain.Template,bool,domain.Domain_Error){
	owner,ok,err:=ownership.owner_from_auth(auth); if !ok do return {},false,err;
	switch id {
	case domain.TEMPLATE_EMPTY_ID, domain.TEMPLATE_COORDINATOR_ID, domain.TEMPLATE_WORKER_ID, domain.TEMPLATE_REVIEWER_ID, domain.TEMPLATE_SOLOIST_ID, domain.TEMPLATE_CURATOR_ID:
		return {}, false, domain.domain_error(.Validation_Failed, "built-in templates cannot be edited")
	}
	t,ok2,err2:=iface.content_get_template(s.content,id); if !ok2 do return {},false,err2;
	if t.is_system do return {},false,domain.domain_error(.Validation_Failed,"built-in templates cannot be edited");
	if t.owner_user_id!=owner do return {},false,domain.domain_error(.Not_Found,"template not found");
	// PATCH semantics (REQ-CLI-8): a field ABSENT from the body is left unchanged;
	// a field PRESENT and empty is an explicit clear. Previously only `name` was
	// presence-checked and the other three were assigned unconditionally, so the
	// obvious partial PATCH silently destroyed them. `name` is the exception to
	// clearing: it is required, so an explicit empty name is rejected rather than
	// stored (same shape as has_body in update_memory).
	if input.has_name {
		if strings.trim_space(input.name)=="" do return {},false,domain.domain_error(.Validation_Failed,"template name is required");
		t.name=input.name;
	}
	if input.has_description do t.description=input.description;
	if input.has_persona do t.persona=input.persona;
	if input.has_instructions do t.instructions=input.instructions;
	t.updated_at=platform.clock_now(s.clock);
	return iface.content_save_template(s.content,t)
}
delete_template :: proc(s:^Content_Service, auth:contracts.Auth_Context,id:string)->(bool,domain.Domain_Error){
	owner,ok,err:=ownership.owner_from_auth(auth); if !ok do return false,err;
	switch id {
	case domain.TEMPLATE_EMPTY_ID, domain.TEMPLATE_COORDINATOR_ID, domain.TEMPLATE_WORKER_ID, domain.TEMPLATE_REVIEWER_ID, domain.TEMPLATE_SOLOIST_ID, domain.TEMPLATE_CURATOR_ID:
		return false, domain.domain_error(.Validation_Failed, "built-in templates cannot be deleted")
	}
	t,ok2,err2:=iface.content_get_template(s.content,id); if !ok2 do return false,err2;
	if t.is_system do return false,domain.domain_error(.Validation_Failed,"built-in templates cannot be deleted");
	if t.owner_user_id!=owner do return false,domain.domain_error(.Not_Found,"template not found");
	return iface.content_delete_template(s.content,id,owner)
}
list_templates :: proc(s:^Content_Service, auth:contracts.Auth_Context)->([]domain.Template,domain.Domain_Error){
	owner,ok,err:=ownership.owner_from_auth(auth); if !ok do return nil,err
	rows, list_err := iface.content_list_templates(s.content,owner)
	if list_err.code != .None do return nil, list_err
	defer delete(rows)
	out := make([dynamic]domain.Template)
	append(&out, ..rows)

	has_empty := false
	has_coordinator := false
	has_worker := false
	has_reviewer := false
	has_soloist := false

	for tmpl in out {
		switch tmpl.template_id {
		case domain.TEMPLATE_EMPTY_ID:
			has_empty = true
		case domain.TEMPLATE_COORDINATOR_ID:
			has_coordinator = true
		case domain.TEMPLATE_WORKER_ID:
			has_worker = true
		case domain.TEMPLATE_REVIEWER_ID:
			has_reviewer = true
		case domain.TEMPLATE_SOLOIST_ID:
			has_soloist = true
		}
	}

	if !has_coordinator do append(&out, coordinator_template())
	if !has_worker do append(&out, worker_template())
	if !has_reviewer do append(&out, reviewer_template())
	if !has_soloist do append(&out, soloist_template())
	if !has_empty do append(&out, empty_template())

	return out[:], {}
}

validate_initial_message :: proc(s:^Content_Service, auth:contracts.Auth_Context, input:Message_Input)->(bool,domain.Domain_Error){ owner,ok,err:=ownership.owner_from_auth(auth); if !ok do return false,err; return validate_initial_message_for_owner(s,owner,input) }
validate_initial_message_for_owner :: proc(s:^Content_Service, owner:domain.User_ID, input:Message_Input)->(bool,domain.Domain_Error){ if strings.trim_space(input.body)=="" do return false,domain.domain_error(.Validation_Failed,"message body is required"); if invalid:=validate_question_message(input); invalid!="" do return false,domain.domain_error(.Question_Invalid,invalid); if !artifacts_owned_json(s,owner,input.artifact_ids_json) do return false,domain.domain_error(.Not_Found,"artifact not found"); return true,{} }
agent_owned :: proc(s:^Content_Service, owner:domain.User_ID, agent_id:string)->bool{ if s.agents==nil || agent_id=="" do return false; a,ok,_:=iface.agent_get(s.agents,agent_id); return ok && a.owner_user_id==owner }
project_owned :: proc(s:^Content_Service, owner:domain.User_ID, project_id:domain.Project_ID)->bool{ if s.projects==nil || string(project_id)=="" do return false; p,ok,_:=iface.project_get(s.projects,project_id); return ok && p.owner_user_id==owner }
template_available :: proc(s:^Content_Service, owner:domain.User_ID, template_id:string)->bool{
	if s.content==nil || template_id=="" do return false;
	switch template_id {
	case domain.TEMPLATE_EMPTY_ID, domain.TEMPLATE_COORDINATOR_ID, domain.TEMPLATE_WORKER_ID, domain.TEMPLATE_REVIEWER_ID, domain.TEMPLATE_SOLOIST_ID, domain.TEMPLATE_CURATOR_ID:
		return true
	}
	t,ok,_:=iface.content_get_template(s.content,template_id);
	return ok && (t.is_system || t.owner_user_id==owner)
}
bridge_owned :: proc(s:^Content_Service, owner:domain.User_ID, bridge_id:string)->bool{ if s.bridges==nil || bridge_id=="" do return false; b,ok,_:=iface.bridge_get_bridge(s.bridges,bridge_id); return ok && b.owner_user_id==owner }
bridge_supports_pane_capture :: proc(s:^Content_Service, bridge_id:string)->bool{ if s.bridges==nil || bridge_id=="" do return false; b,ok,_:=iface.bridge_get_bridge(s.bridges,bridge_id); return ok && strings.contains(b.capabilities_json,"\"capture_agent_pane\"") }
conversation_instance_binding_valid :: proc(s:^Content_Service, owner:domain.User_ID, input:Chat_Input)->(bool,domain.Domain_Error){
	if input.agent_instance_id=="" do return true,{}
	if s.agents==nil do return false,domain.domain_error(.Internal_Error,"agent repository is not configured")
	inst,inst_ok,_:=iface.agent_get_instance(s.agents,input.agent_instance_id)
	if !inst_ok || inst.owner_user_id!=owner do return false,domain.domain_error(.Not_Found,"agent instance not found")
	if inst.agent_id!=input.agent_id do return false,domain.domain_error(.Conflict,"conversation agent_id must match agent instance")
	if input.chain_id!="" && inst.chain_id!=input.chain_id do return false,domain.domain_error(.Conflict,"conversation chain_id must match agent instance")
	if string(input.project_id)!="" && inst.project_id!=input.project_id do return false,domain.domain_error(.Conflict,"conversation project_id must match agent instance")
	existing,list_err:=iface.content_list_conversations(s.content,owner,256,"")
	if list_err.code!=.None do return false,list_err
	for c in existing { if c.agent_instance_id==input.agent_instance_id do return false,domain.domain_error(.Conflict,"agent instance already has a conversation") }
	return true,{}
}
artifact_context_owned :: proc(s:^Content_Service, owner:domain.User_ID, input:Artifact_Input)->(bool,domain.Domain_Error){
	if input.agent_id!="" && !agent_owned(s,owner,input.agent_id) do return false,domain.domain_error(.Not_Found,"artifact context not found")
	if input.agent_instance_id!="" { if s.agents==nil do return false,domain.domain_error(.Internal_Error,"agent repository is not configured"); inst,ok,_:=iface.agent_get_instance(s.agents,input.agent_instance_id); if !ok || inst.owner_user_id!=owner do return false,domain.domain_error(.Not_Found,"artifact context not found"); if input.agent_id!="" && inst.agent_id!=input.agent_id do return false,domain.domain_error(.Conflict,"artifact context is inconsistent"); if string(input.project_id)!="" && inst.project_id!=input.project_id do return false,domain.domain_error(.Conflict,"artifact context is inconsistent") }
	if string(input.project_id)!="" { if s.projects==nil do return false,domain.domain_error(.Internal_Error,"project repository is not configured"); p,ok,_:=iface.project_get(s.projects,input.project_id); if !ok || p.owner_user_id!=owner do return false,domain.domain_error(.Not_Found,"artifact context not found") }
	if input.chain_id!="" { if s.taskchains==nil do return false,domain.domain_error(.Internal_Error,"taskchain repository is not configured"); c,ok,_:=iface.taskchain_get_chain(s.taskchains,domain.Task_Chain_ID(input.chain_id)); if !ok || c.owner_user_id!=owner do return false,domain.domain_error(.Not_Found,"artifact context not found") }
	if input.task_id!="" { if s.taskchains==nil do return false,domain.domain_error(.Internal_Error,"taskchain repository is not configured"); t,ok,_:=iface.taskchain_get_task(s.taskchains,domain.Task_ID(input.task_id)); if !ok || t.owner_user_id!=owner do return false,domain.domain_error(.Not_Found,"artifact context not found"); if input.chain_id!="" && t.chain_id!=domain.Task_Chain_ID(input.chain_id) do return false,domain.domain_error(.Conflict,"artifact context is inconsistent") }
	return true,{}
}
// conversation_title_from_input seeds the conversation title from an EXPLICIT
// caller-provided title only, falling back to the given default when none is
// set. It deliberately does NOT derive the title from the initial message body:
// seeding titles from the first message discourages long messages, and the
// per-run default title ('<agent-name> #<n>', title_source=default) is left in
// place so the activity-gated title-nudge engine can set a real title later.
conversation_title_from_input :: proc(explicit_title, fallback: string) -> string {
	seed := strings.trim_space(explicit_title)
	if seed == "" do seed = fallback
	b := strings.builder_make()
	last_space := false
	written := 0
	for i := 0; i < len(seed) && written < 120; i += 1 {
		ch := seed[i]
		is_space := ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r'
		if is_space {
			if !last_space { strings.write_byte(&b, ' '); last_space = true; written += 1 }
		} else {
			strings.write_byte(&b, ch); last_space = false; written += 1
		}
	}
	return strings.trim_space(strings.to_string(b))
}
artifact_json_or_empty :: proc(v:string)->string{ if strings.trim_space(v)=="" do return "[]"; return v }
artifacts_owned_json :: proc(s:^Content_Service, owner:domain.User_ID, ids_json:string)->bool{ return !artifact_refs_have_missing(s,owner,ids_json) }
artifact_refs_have_missing :: proc(s:^Content_Service, owner:domain.User_ID, ids_json:string)->bool{ if strings.trim_space(ids_json)=="" || ids_json=="[]" do return false; search:=0; for search<len(ids_json){ rel:=strings.index(ids_json[search:],"\""); if rel<0 do break; start:=search+rel+1; end:=start; for end<len(ids_json)&&ids_json[end]!='"' do end+=1; if end>start { a,ok,_:=iface.content_get_artifact(s.content,ids_json[start:end]); if !ok || a.owner_user_id!=owner do return true }; search=end+1 }; return false }

pane_capture_clamp :: proc(value, fallback, min, max: int)->int{ v:=value; if v<=0 do v=fallback; if v<min do v=min; if v>max do v=max; return v }
pending_pane_capture :: proc(s:^Content_Service,c:domain.Chat_Conversation)->(domain.Chat_Message,bool){ rows,err:=iface.content_list_user_visible_messages(s.content,c.conversation_id,c.owner_user_id,50,""); if err.code!=.None do return {},false; repair_stale_pane_captures(s,rows); for m in rows { if m.message_type=="pane_capture" && m.message_status=="pending" do return m,true }; return {},false }
repair_stale_pane_captures :: proc(s:^Content_Service, rows:[]domain.Chat_Message){
	now:=platform.clock_now(s.clock)
	for &m in rows {
		if m.message_type!="pane_capture" || m.message_status!="pending" do continue
		timeout:=pane_capture_json_string(m.metadata_json,"pending_timeout_at")
		defer delete(timeout)
		if timeout!="" && now!="" && timeout < now {
			failed,_:=mark_pane_capture_failed(s,m,"capture_timeout","")
			m=failed
		}
	}
}
mark_pane_capture_failed :: proc(s:^Content_Service,m:domain.Chat_Message,error_code,message:string)->(domain.Chat_Message,bool){
	body:=message
	if strings.trim_space(body)=="" do body=pane_capture_failure_message(error_code)
	req_id:=pane_capture_json_string(m.metadata_json,"pane_capture_request_id")
	defer delete(req_id)
	inst_id:=pane_capture_json_string(m.metadata_json,"agent_instance_id")
	defer delete(inst_id)
	bridge_id:=pane_capture_json_string(m.metadata_json,"bridge_id")
	defer delete(bridge_id)
	width:=pane_capture_json_int(m.metadata_json,"width",80)
	settle_ms:=pane_capture_json_int(m.metadata_json,"settle_ms",3000)
	line_limit:=pane_capture_json_int(m.metadata_json,"line_limit",120)
	metadata:=pane_capture_metadata(req_id,inst_id,bridge_id,width,settle_ms,line_limit,0,false,error_code,"")
	defer delete(metadata)
	updated,ok,_:=update_message(s,m.owner_user_id,m.conversation_id,m.message_id,body,"failed",metadata)
	return updated,ok
}
pane_capture_failure_message :: proc(error_code:string)->string{ switch error_code { case "wrapper_unavailable": return "The agent wrapper is not connected, so its pane could not be captured."; case "pane_not_running": return "The agent tmux pane is no longer running."; case "resize_failed": return "The agent pane could not be resized before capture."; case "capture_timeout": return "The pane capture request timed out."; case "bridge_unavailable": return "The Bridge is not connected, so its pane could not be captured." }; return "The pane capture failed." }
pane_capture_limit_output :: proc(output:string)->string{ if len(output)<=48000 do return output; return output[:48000] }
pane_capture_metadata :: proc(req_id,agent_instance_id,bridge_id:string,width,settle,line_limit,line_count:int,truncated:bool,error_code,timeout_at:string)->string{ b:=strings.builder_make(); strings.write_string(&b,"{\"pane_capture_request_id\":\""); content_json_write(&b,req_id); strings.write_string(&b,"\",\"agent_instance_id\":\""); content_json_write(&b,agent_instance_id); strings.write_string(&b,"\",\"bridge_id\":\""); content_json_write(&b,bridge_id); strings.write_string(&b,"\",\"width\":"); strings.write_string(&b,fmt.tprintf("%d",width)); if settle>0 { strings.write_string(&b,",\"settle_ms\":"); strings.write_string(&b,fmt.tprintf("%d",settle)) }; if line_limit>0 { strings.write_string(&b,",\"line_limit\":"); strings.write_string(&b,fmt.tprintf("%d",line_limit)) }; if line_count>0 { strings.write_string(&b,",\"line_count\":"); strings.write_string(&b,fmt.tprintf("%d",line_count)) }; strings.write_string(&b,",\"truncated\":"); strings.write_string(&b,"true" if truncated else "false"); if error_code!="" { strings.write_string(&b,",\"error_code\":\""); content_json_write(&b,error_code); strings.write_string(&b,"\"") }; if timeout_at!="" { strings.write_string(&b,",\"pending_timeout_at\":\""); content_json_write(&b,timeout_at); strings.write_string(&b,"\"") }; strings.write_string(&b,"}"); return strings.to_string(b) }
pane_capture_command_json :: proc(command_id,req_id,conversation_id,message_id,agent_instance_id:string,width,settle,line_limit:int)->string{ b:=strings.builder_make(); strings.write_string(&b,"{\"type\":\"capture_agent_pane\",\"protocol_version\":1,\"command_id\":\""); content_json_write(&b,command_id); strings.write_string(&b,"\",\"pane_capture_request_id\":\""); content_json_write(&b,req_id); strings.write_string(&b,"\",\"conversation_id\":\""); content_json_write(&b,conversation_id); strings.write_string(&b,"\",\"message_id\":\""); content_json_write(&b,message_id); strings.write_string(&b,"\",\"agent_instance_id\":\""); content_json_write(&b,agent_instance_id); strings.write_string(&b,"\",\"width\":"); strings.write_string(&b,fmt.tprintf("%d",width)); strings.write_string(&b,",\"settle_ms\":"); strings.write_string(&b,fmt.tprintf("%d",settle)); strings.write_string(&b,",\"line_limit\":"); strings.write_string(&b,fmt.tprintf("%d",line_limit)); strings.write_string(&b,"}"); return strings.to_string(b) }
pane_capture_json_string :: proc(body,key:string,allocator:=context.allocator)->string{
	return jsonx.extract_string(body,key,allocator=allocator)
}
pane_capture_json_int :: proc(body,key:string,fallback:int)->int{
	return jsonx.extract_int(body,key,fallback)
}

notify_agent_message :: proc(s:^Content_Service, c:domain.Chat_Conversation, direction,sender_instance_id,message_id:string, sender_display_name:string=""){ if s==nil || s.agents==nil || s.bridge_command_sink.send_runtime_command==nil do return; inst,ok,_:=iface.agent_get_instance(s.agents,c.agent_instance_id); if !ok || inst.bridge_id=="" do return; command_id:=platform.generate_id(s.ids,"cmd_"); sndr_dn:=sender_display_name; if sndr_dn=="" && sender_instance_id!="" && sender_instance_id!="user" { if sndr,sndr_ok,_:=iface.agent_get_instance(s.agents,sender_instance_id); sndr_ok do sndr_dn=sndr.display_name }; if sndr_dn=="" && sender_instance_id=="user" do sndr_dn="User"; b:=strings.builder_make(); strings.write_string(&b,"{\"type\":\"notify_agent_message\",\"command_id\":\""); content_json_write(&b,command_id); strings.write_string(&b,"\",\"bridge_id\":\""); content_json_write(&b,inst.bridge_id); strings.write_string(&b,"\",\"agent_instance_id\":\""); content_json_write(&b,c.agent_instance_id); strings.write_string(&b,"\",\"conversation_id\":\""); content_json_write(&b,c.conversation_id); strings.write_string(&b,"\",\"message_id\":\""); content_json_write(&b,message_id); strings.write_string(&b,"\",\"direction\":\""); content_json_write(&b,direction); strings.write_string(&b,"\",\"sender\":\""); content_json_write(&b,sender_instance_id); strings.write_string(&b,"\",\"sender_agent_instance_id\":\""); content_json_write(&b,sender_instance_id); if sndr_dn!="" { strings.write_string(&b,"\",\"sender_display_name\":\""); content_json_write(&b,sndr_dn) }; strings.write_string(&b,"\",\"unread_count\":"); strings.write_string(&b,fmt.tprintf("%d",c.unread_count)); strings.write_string(&b,"}"); _,_=project_service.bridge_command_send_runtime(s.bridge_command_sink,project_service.Runtime_Command{bridge_id=inst.bridge_id,command_id=command_id,body_json=strings.to_string(b)}) }
content_json_write :: proc(b:^strings.Builder, v:string){ contracts.write_json_string(b,v) }
