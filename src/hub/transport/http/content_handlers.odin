package http

import "core:fmt"
import "core:strconv"
import "core:strings"
import internal_b64 "core:encoding/base64"

import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import auth_service "odin_test:hub/service/auth"
import agent_service "odin_test:hub/service/agent"
import content_service "odin_test:hub/service/content"
import events "odin_test:hub/service/events"
import jsonx "odin_test:lib/jsonx"

Content_Handlers :: struct { auth: ^auth_service.Auth_Service, agents: ^agent_service.Agent_Service, content: ^content_service.Content_Service, event_bus: ^events.User_Event_Bus }

list_memories_handler :: proc(ctx:rawptr, req:Request)->Response{
	h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp
	limit:=query_int(req.query,"limit",50)
	if limit<=0 do limit=50
	if limit>200 do limit=200
	cursor:=query_value(req.query,"cursor")
	status:=query_value(req.query,"status")
	type_str:=query_value(req.query,"type")
	// Targeting filters accept the plural list names (agent_ids/project_ids/
	// bridge_ids/template_ids) as a CSV or repeated query param, falling back to
	// the singular name. Memory_Filter narrows by a single value per dimension, so
	// the first token is used; a memory matches when its list is empty (global) OR
	// contains the value.
	agent_id:=memory_filter_query(req.query,"agent_ids","agent_id")
	project_id:=memory_filter_query(req.query,"project_ids","project_id")
	bridge_id:=memory_filter_query(req.query,"bridge_ids","bridge_id")
	template_id:=memory_filter_query(req.query,"template_ids","template_id")
	filter:=content_service.Memory_Filter{status=status,type=type_str,agent_id=agent_id,project_id=domain.Project_ID(project_id),bridge_id=bridge_id,template_id=template_id}
	rows,err:=content_service.list_memories(h.content,auth,filter,limit,cursor)
	if err.code!=.None do return respond_error(err,req.request_id)
	defer delete(rows)
	b:=strings.builder_make(); strings.write_byte(&b,'[')
	next_cursor:=""
	for r,i in rows{ if i>0 do strings.write_byte(&b,','); write_memory_json(&b,r,true); next_cursor=r.updated_at }
	strings.write_byte(&b,']')
	has_more:=len(rows)>=limit
	return respond_list(strings.to_string(b),contracts.API_Page{limit=limit,next_cursor=next_cursor if has_more else "",has_more=has_more},req.request_id,auth_ctx_server_time(req))
}
create_memory_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; m,saved,err:=content_service.create_memory(h.content,auth,memory_input(req.body)); if !saved do return respond_error(err,req.request_id); b:=strings.builder_make(); write_memory_json(&b,m,false); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req),201) }
memory_detail_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; m,got,err:=content_service.get_memory(h.content,auth,path_part(req.path,4)); if !got do return respond_error(err,req.request_id); b:=strings.builder_make(); write_memory_json(&b,m,false); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req)) }
patch_memory_handler :: proc(ctx:rawptr, req:Request)->Response{
	h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp
	id:=path_part(req.path,4)
	input,_:=memory_update_input(req.body)
	m,updated,err:=content_service.update_memory(h.content,auth,id,input)
	if !updated do return respond_error(err,req.request_id)
	b:=strings.builder_make(); write_memory_json(&b,m,false)
	return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req))
}
memory_action_handler :: proc(ctx:rawptr, req:Request)->Response{
	h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp
	id:=path_part(req.path,4)
	action:=path_part(req.path,5)
	m:domain.Memory; good:=false; err:domain.Domain_Error
	if action=="approve" {
		input,has_edits:=memory_update_input(req.body)
		m,good,err=content_service.approve_memory(h.content,auth,id,input,has_edits)
	} else if action=="reject" {
		m,good,err=content_service.reject_memory(h.content,auth,id)
	} else if action=="archive" {
		m,good,err=content_service.archive_memory(h.content,auth,id)
	} else {
		return respond_error(domain.domain_error(.Not_Found,"route not found"),req.request_id)
	}
	if !good do return respond_error(err,req.request_id)
	b:=strings.builder_make(); write_memory_json(&b,m,false)
	return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req))
}

list_chats_handler :: proc(ctx:rawptr, req:Request)->Response{
	h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp
	limit:=query_int(req.query,"limit",50); if limit<=0 do limit=50; if limit>200 do limit=200
	cursor:=query_value(req.query,"cursor")
	// Standard chat-list affordances are additive/optional. The existing sidebar
	// path keeps working with bare /chats?limit=N, while richer consumers can ask
	// for conventional includes/sort without receiving a different envelope.
	include:=query_value(req.query,"include"); sort:=query_value(req.query,"sort"); order:=query_value(req.query,"order"); _=include; _=sort; _=order
	// Optional "active only" filter: ?active=true (or ?status=active) returns only
	// conversations whose bound agent instance is in a live runtime state, so the
	// sidebar can show just the running agents. Filtering is applied AFTER the
	// durable list fetch (conversations have no runtime column; liveness lives on
	// the instance), so pagination still advances by the underlying rows.
	active_only:=query_bool(req.query,"active",false) || query_value(req.query,"status")=="active"
	rows,err:=content_service.list_conversations(h.content,auth,limit,cursor); if err.code!=.None do return respond_error(err,req.request_id)
	b:=strings.builder_make(); strings.write_byte(&b,'[')
	next:=""; emitted:=0
	for r,i in rows{
		next=chat_page_cursor(r)
		if active_only && !chat_instance_runtime_active(r,h,auth) do continue
		if emitted>0 do strings.write_byte(&b,','); write_chat_json_with_runtime(&b,r,h,auth); emitted+=1
		_=i
	}
	strings.write_byte(&b,']')
	has_more:=len(rows)>=limit
	return respond_list(strings.to_string(b),contracts.API_Page{limit=limit,next_cursor=next if has_more else "",has_more=has_more},req.request_id,auth_ctx_server_time(req))
}
// get_chat_by_instance_handler resolves the SINGLE conversation bound to an agent
// instance: GET /api/v1/chats/by-instance/{agent_instance_id}. The conversation
// UI polls this instead of listing all chats to .find() one, so a conversation
// page's periodic refresh is O(1) instead of fetching the whole inbox.
get_chat_by_instance_handler :: proc(ctx:rawptr, req:Request)->Response{
	h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp
	instance_id:=path_part(req.path,5)
	if strings.trim_space(instance_id)=="" do return respond_error(domain.domain_error(.Validation_Failed,"agent_instance_id is required"),req.request_id)
	c,found,find_err:=content_service.get_conversation_by_instance(h.content,auth,instance_id)
	if !found do return respond_error(find_err,req.request_id)
	b:=strings.builder_make(); write_chat_json_with_runtime(&b,c,h,auth)
	return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req))
}
create_chat_handler :: proc(ctx:rawptr, req:Request)->Response{
	h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp
	input:=chat_input(req.body)
	if input.agent_instance_id=="" {
		if h.agents==nil do return respond_error(domain.domain_error(.Internal_Error,"agent service is not configured"),req.request_id)
		initial:=content_service.Message_Input{body=input.initial_body,artifact_ids_json=input.artifact_ids_json}
		if strings.trim_space(input.initial_body)!="" { if msg_ok,msg_err:=content_service.validate_initial_message(h.content,auth,initial); !msg_ok do return respond_error(msg_err,req.request_id) }
		inst,created,create_err:=agent_service.create_instance(h.agents,auth,agent_service.Create_Instance_Input{agent_id=input.agent_id,bridge_id=input.bridge_id,provider=input.provider,provider_profile=input.provider_profile,model=input.model,project_id=input.project_id,chain_id=input.chain_id})
		if !created do return respond_error(create_err,req.request_id)
		c,found,find_err:=content_service.get_conversation_by_instance(h.content,auth,inst.agent_instance_id)
		if !found do return respond_error(find_err,req.request_id)
		publish_instance_changed(h.event_bus,inst,"created")
		// Send the initial message when present, but do NOT derive the conversation
		// title from it: seeding the title from the first message discourages long
		// messages. The per-run default title ('<agent-name> #<n>', title_source=
		// default) stays in place so the activity-gated title-nudge engine
		// (title_nudge.odin) can set a real title later.
		// The instance and its conversation are committed by create_instance, so
		// announce the conversation before the optional initial send: a failed
		// send must not hide a conversation that already exists.
		publish_conversation_changed(h.event_bus,c,"created")
		if strings.trim_space(input.initial_body)!="" { m,sent,send_err := content_service.send_message(h.content,auth,c.conversation_id,initial); if !sent do return respond_error(send_err,req.request_id); updated,updated_ok,updated_err:=content_service.get_conversation(h.content,auth,c.conversation_id); if !updated_ok do return respond_error(updated_err,req.request_id); c=updated; publish_chat_message_created(h.event_bus,c,m) }
		b:=strings.builder_make(); write_chat_json(&b,c); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req),201)
	}
	c,saved,err:=content_service.create_conversation(h.content,auth,input); if !saved do return respond_error(err,req.request_id); publish_conversation_changed(h.event_bus,c,"created"); b:=strings.builder_make(); write_chat_json(&b,c); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req),201)
}
patch_chat_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; c,saved,err:=content_service.update_conversation_title(h.content,auth,path_part(req.path,4),json_string(req.body,"title")); if !saved do return respond_error(err,req.request_id); publish_conversation_changed(h.event_bus, c, "updated"); b:=strings.builder_make(); write_chat_json(&b,c); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req)) }
list_chat_messages_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; limit:=query_int(req.query,"limit",50); cursor:=query_value(req.query,"cursor"); rows,err:=content_service.list_user_visible_messages(h.content,auth,path_part(req.path,4),limit,cursor); if err.code!=.None do return respond_error(err,req.request_id); b:=strings.builder_make(); strings.write_byte(&b,'['); next:=""; for r,i in rows{ if i>0 do strings.write_byte(&b,','); write_message_json(&b,r,h.content); next=strings.concatenate({r.created_at,"|",r.message_id},context.temp_allocator)}; strings.write_byte(&b,']'); has_more:=len(rows)>=limit; return respond_list(strings.to_string(b),contracts.API_Page{limit=limit,next_cursor=next if has_more else "",has_more=has_more},req.request_id,auth_ctx_server_time(req)) }
send_chat_message_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; cid:=path_part(req.path,4); if restarted,restart_err:=restart_stopped_conversation_instance(h,auth,cid); !restarted do return respond_error(restart_err,req.request_id); m,saved,err:=content_service.send_message(h.content,auth,cid,message_input(req.body)); if !saved do return respond_error(err,req.request_id); publish_user_message_created(h,auth,cid,m); b:=strings.builder_make(); write_message_json(&b,m,h.content); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req),201) }

// publish_user_message_created tells every socket of the owner (other tabs and
// devices included) about a user->agent message that send_message persisted.
// The conversation row is re-read so last_message_at/unread_count reflect the
// committed state; if that read fails the event still goes out with ids only.
publish_user_message_created :: proc(h:^Content_Handlers, auth:contracts.Auth_Context, cid:string, m:domain.Chat_Message){
	if h==nil || h.event_bus==nil do return
	c,got,_:=content_service.get_conversation(h.content,auth,cid)
	if !got { c=domain.Chat_Conversation{conversation_id=cid,owner_user_id=m.owner_user_id,agent_instance_id=m.sender_agent_instance_id} }
	publish_chat_message_created(h.event_bus,c,m)
}
pane_capture_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; m,saved,err:=content_service.request_pane_capture(h.content,auth,path_part(req.path,4),pane_capture_input(req.body)); if !saved do return respond_error(err,req.request_id); publish_user_message_created(h,auth,path_part(req.path,4),m); b:=strings.builder_make(); strings.write_string(&b,"{\"message\":"); write_message_json(&b,m,h.content); strings.write_string(&b,",\"pane_capture_request_id\":\""); write_handler_json_string(&b,pane_capture_request_id_from_metadata(m.metadata_json)); strings.write_string(&b,"\"}"); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req),202) }
read_chat_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; c,marked_ids,saved,err:=content_service.mark_read_with_receipts(h.content,auth,path_part(req.path,4)); if !saved do return respond_error(err,req.request_id); publish_messages_read(h,string(c.owner_user_id),c,marked_ids,"user"); delete(marked_ids); b:=strings.builder_make(); write_chat_json(&b,c); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req)) }

// Publish a `messages_read` WS event to the conversation owner's live clients
// so senders can render read receipts without polling. `reader` is "user" or
// the agent instance id. No-op when the event bus is unavailable (test wiring).
publish_messages_read :: proc(h:^Content_Handlers, owner_user_id:string, c:domain.Chat_Conversation, message_ids:[]string, reader:string){
	if h==nil || h.event_bus==nil || owner_user_id=="" || len(message_ids)==0 do return
	events.publish_owned(h.event_bus, owner_user_id, messages_read_event_json(c, message_ids, reader))
}

// read_at is the timestamp the mark wrote; it defaults to the conversation's
// updated_at, which mark_read_with_receipts sets to that same instant.
messages_read_event_json :: proc(c:domain.Chat_Conversation, message_ids:[]string, reader:string, read_at:="")->string{
	b:=strings.builder_make()
	strings.write_string(&b,"{\"type\":\"chat_event\",\"event\":\"messages_read\",\"conversation_id\":\""); write_handler_json_string(&b,c.conversation_id)
	strings.write_string(&b,"\",\"agent_instance_id\":\""); write_handler_json_string(&b,c.agent_instance_id)
	strings.write_string(&b,"\",\"reader\":\""); write_handler_json_string(&b,reader)
	strings.write_string(&b,"\",\"read_at\":\""); write_handler_json_string(&b,read_at if read_at!="" else c.updated_at)
	fmt.sbprintf(&b,"\",\"unread_count\":%d",c.unread_count)
	strings.write_string(&b,",\"message_ids\":[")
	for id,i in message_ids { if i>0 do strings.write_byte(&b,','); strings.write_byte(&b,'"'); write_handler_json_string(&b,id); strings.write_byte(&b,'"') }
	strings.write_string(&b,"]}")
	return strings.to_string(b)
}

list_artifacts_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Content_Handlers)(ctx)
	auth, ok, resp := require_auth(h.auth, req)
	if !ok do return resp

	project_id := query_value(req.query, "project_id")
	agent_instance_id := query_value(req.query, "agent_instance_id")
	agent_id := query_value(req.query, "agent_id")
	chain_id := query_value(req.query, "chain_id")
	task_id := query_value(req.query, "task_id")
	kind := query_value(req.query, "kind")
	since := query_value(req.query, "since")
	until := query_value(req.query, "until")
	include_deleted := query_bool(req.query, "include_deleted", false)
	sort := query_value(req.query, "sort")
	if sort == "" do sort = query_value(req.query, "sort_field")
	order := query_value(req.query, "order")
	if order == "" do order = query_value(req.query, "sort_order")
	limit := query_int(req.query, "limit", 50)
	cursor := query_value(req.query, "cursor")

	filter := domain.Artifact_List_Filter{
		project_id        = domain.Project_ID(project_id),
		agent_instance_id = agent_instance_id,
		agent_id          = agent_id,
		chain_id          = chain_id,
		task_id           = task_id,
		kind              = kind,
		since             = since,
		until             = until,
		include_deleted   = include_deleted,
		sort_field        = sort,
		sort_order        = order,
		limit             = limit,
		cursor            = cursor,
	}

	rows, err := content_service.list_artifacts(h.content, auth, filter)
	if err.code != .None do return respond_error(err, req.request_id)
	defer domain.artifacts_destroy(rows)

	eff_limit := limit
	if eff_limit <= 0 do eff_limit = 50
	if eff_limit > 200 do eff_limit = 200

	has_more := len(rows) > eff_limit
	page_count := len(rows)
	if page_count > eff_limit do page_count = eff_limit

	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for i in 0..<page_count {
		if i > 0 do strings.write_byte(&b, ',')
		write_artifact_json(&b, rows[i], false)
	}
	strings.write_byte(&b, ']')

	next_cursor := ""
	if has_more && page_count > 0 {
		next_cursor = artifact_page_cursor(rows[page_count - 1], filter.sort_field)
	}

	return respond_list(strings.to_string(b), contracts.API_Page{limit = eff_limit, next_cursor = next_cursor, has_more = has_more}, req.request_id, auth_ctx_server_time(req))
}
create_artifact_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; a,saved,err:=content_service.create_artifact(h.content,auth,artifact_input_from_request(req)); if !saved do return respond_error(err,req.request_id); b:=strings.builder_make(); write_artifact_json(&b,a,false); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req),201) }
artifact_detail_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; a,got,err:=content_service.get_artifact(h.content,auth,path_part(req.path,4)); if !got do return respond_error(err,req.request_id); b:=strings.builder_make(); write_artifact_json(&b,a,false); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req)) }
artifact_content_handler :: proc(ctx:rawptr, req:Request)->Response{
	return artifact_content_response(ctx, req, false)
}
artifact_download_handler :: proc(ctx:rawptr, req:Request)->Response{
	return artifact_content_response(ctx, req, true)
}
artifact_content_response :: proc(ctx:rawptr, req:Request, force_download:bool)->Response{
	h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp;
	a,got,err:=content_service.get_artifact(h.content,auth,path_part(req.path,4)); if !got do return respond_error(err,req.request_id);
	ctype := artifact_response_content_type(a)
	disposition := "inline"
	if force_download || artifact_query_download(req.query) do disposition = "attachment"
	headers := make([dynamic]contracts.HTTP_Header, 0, 4)
	append(&headers, contracts.HTTP_Header{name = "Content-Disposition", value = artifact_content_disposition(disposition, a.name)})
	append(&headers, contracts.HTTP_Header{name = "Cache-Control", value = "private, max-age=60"})
	append(&headers, contracts.HTTP_Header{name = "X-Content-Type-Options", value = "nosniff"})
	return Response{
		status = 200,
		content_type = ctype,
		body = a.content,
		headers = headers[:],
	}
}
artifact_response_content_type :: proc(a:domain.Artifact)->string{
	ctype:=strings.trim_space(a.mime); if ctype=="" do ctype=strings.trim_space(a.content_type); if ctype=="" do ctype="application/octet-stream"; return ctype
}
artifact_query_download :: proc(query:string)->bool{
	v:=strings.to_lower(query_value(query,"download")); if v=="" do v=strings.to_lower(query_value(query,"dl"))
	disposition:=strings.to_lower(query_value(query,"disposition"))
	return v=="1" || v=="true" || v=="yes" || disposition=="attachment" || disposition=="download"
}
artifact_content_disposition :: proc(disposition,name:string)->string{
	safe:=artifact_header_filename(name); if safe=="" do safe="artifact"
	return fmt.tprintf("%s; filename=\"%s\"; filename*=UTF-8''%s", disposition, safe, artifact_filename_star(name))
}
artifact_header_filename :: proc(name:string)->string{
	trimmed:=strings.trim_space(name); if trimmed=="" do return "artifact"
	b:=strings.builder_make()
	for i:=0; i<len(trimmed); i+=1{
		ch:=trimmed[i]
		if ch<32 || ch==127 || ch=='"' || ch=='\\' || ch=='/' || ch=='\r' || ch=='\n' {
			strings.write_byte(&b,'_')
		} else {
			strings.write_byte(&b,ch)
		}
	}
	return strings.to_string(b)
}
artifact_filename_star :: proc(name:string)->string{
	trimmed:=strings.trim_space(name); if trimmed=="" do trimmed="artifact"
	b:=strings.builder_make()
	for i:=0; i<len(trimmed); i+=1{
		ch:=trimmed[i]
		unreserved := (ch>='a' && ch<='z') || (ch>='A' && ch<='Z') || (ch>='0' && ch<='9') || ch=='-' || ch=='.' || ch=='_' || ch=='~'
		if unreserved { strings.write_byte(&b,ch) } else { strings.write_string(&b,fmt.tprintf("%%%02X",int(ch))) }
	}
	return strings.to_string(b)
}

patch_artifact_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; a,saved,err:=content_service.update_artifact(h.content,auth,path_part(req.path,4),json_string(req.body,"name"),json_string(req.body,"description")); if !saved do return respond_error(err,req.request_id); b:=strings.builder_make(); write_artifact_json(&b,a,false); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req)) }
delete_artifact_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; deleted,err:=content_service.delete_artifact(h.content,auth,path_part(req.path,4)); if !deleted do return respond_error(err,req.request_id); return Response{status=204,content_type="application/json",body=""} }

list_templates_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth_any(h.auth,req); if !ok do return resp; rows,err:=content_service.list_templates(h.content,auth); if err.code!=.None do return respond_error(err,req.request_id); b:=strings.builder_make(); strings.write_byte(&b,'['); for r,i in rows{ if i>0 do strings.write_byte(&b,','); write_template_json(&b,r)}; strings.write_byte(&b,']'); return respond_list(strings.to_string(b),contracts.API_Page{limit=contracts.API_DEFAULT_PAGE_LIMIT,has_more=false},req.request_id,auth_ctx_server_time(req)) }
create_template_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth_any(h.auth,req); if !ok do return resp; t,saved,err:=content_service.create_template(h.content,auth,template_input(req.body)); if !saved do return respond_error(err,req.request_id); b:=strings.builder_make(); write_template_json(&b,t); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req),201) }
update_template_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; t,saved,err:=content_service.update_template(h.content,auth,path_part(req.path,4),template_input(req.body)); if !saved do return respond_error(err,req.request_id); b:=strings.builder_make(); write_template_json(&b,t); return respond_success(strings.to_string(b),req.request_id,auth_ctx_server_time(req)) }
delete_template_handler :: proc(ctx:rawptr, req:Request)->Response{ h:=(^Content_Handlers)(ctx); auth,ok,resp:=require_auth(h.auth,req); if !ok do return resp; deleted,err:=content_service.delete_template(h.content,auth,path_part(req.path,4)); if !deleted do return respond_error(err,req.request_id); return Response{status=204,content_type="application/json",body=""} }

restart_stopped_conversation_instance :: proc(h:^Content_Handlers, auth:contracts.Auth_Context, cid:string)->(bool,domain.Domain_Error){ c,got,err:=content_service.get_conversation(h.content,auth,cid); if !got do return false,err; if c.agent_instance_id=="" || h.agents==nil do return true,{}; if h.content.agent_configuration_service != nil { if valid, validity_err := agent_service.validate_instance_message_configuration(h.agents,c.owner_user_id,c.agent_instance_id); !valid do return false,validity_err }; inst,inst_ok,inst_err:=agent_service.get_instance(h.agents,auth,c.agent_instance_id); if !inst_ok do return false,inst_err; if inst.runtime_status=="stopped" || inst.runtime_status=="failed" || inst.runtime_status=="unreachable" { restarted_inst,restarted,restart_err:=agent_service.restart_instance(h.agents,auth,c.agent_instance_id); if !restarted do return false,restart_err; publish_instance_changed(h.event_bus,restarted_inst,"status_changed") }; return true,{} }

// memory_input reads the memory targeting lists as JSON string arrays:
// agent_ids/project_ids/template_ids/bridge_ids. An omitted or empty array means
// "applies to all" for that dimension.
memory_input :: proc(body:string)->content_service.Memory_Input{
	return content_service.Memory_Input{agent_ids=json_string_array(body,"agent_ids"),project_ids=json_project_id_array(body,"project_ids"),template_ids=json_string_array(body,"template_ids"),bridge_ids=json_string_array(body,"bridge_ids"),type=domain.memory_type_from_string(json_string(body,"type")),title=json_string(body,"title"),description=json_string(body,"description"),body=json_string(body,"body"),evidence=json_string(body,"evidence"),status=json_string(body,"status"),expires_at=json_string(body,"expires_at")}
}
// json_project_id_array reads a JSON string array and maps it to Project_IDs.
json_project_id_array :: proc(body, key: string) -> []domain.Project_ID {
	ids := json_string_array(body, key)
	out := make([]domain.Project_ID, len(ids))
	for id, i in ids do out[i] = domain.Project_ID(id)
	return out
}
// json_array_present reports whether key appears as a JSON array in body,
// returning its string elements. Used for PATCH semantics where presence of the
// key (even as an empty array) means "replace this dimension".
json_array_present :: proc(body, key: string) -> ([]string, bool) {
	needle := strings.concatenate({"\"", key, "\""}); defer delete(needle)
	idx := strings.index(body, needle); if idx < 0 do return nil, false
	rest := body[idx + len(needle):]
	colon := strings.index_byte(rest, ':'); if colon < 0 do return nil, false
	rest = strings.trim_space(rest[colon + 1:])
	if len(rest) == 0 || rest[0] != '[' do return nil, false
	return json_string_array(body, key), true
}

// json_property reports whether `key` is present in `body` and returns its value DECODED.
json_property :: proc(body, key: string, allocator := context.allocator) -> (value: string, present: bool) {
	if !jsonx.has_key(body, key, top_level_only = true) do return "", false
	return jsonx.extract_string(body, key, top_level_only = true, allocator = allocator), true
}

memory_update_input :: proc(body: string) -> (content_service.Memory_Update_Input, bool) {
	trimmed := strings.trim_space(body)
	if trimmed == "" || trimmed == "{}" do return {}, false
	input: content_service.Memory_Update_Input
	has_any := false

	if val, ok := json_property(body, "title"); ok { input.title = val; input.has_title = true; has_any = true }
	if val, ok := json_property(body, "description"); ok { input.description = val; input.has_description = true; has_any = true }
	if val, ok := json_property(body, "body"); ok { input.body = val; input.has_body = true; has_any = true }
	if val, ok := json_property(body, "evidence"); ok { input.evidence = val; input.has_evidence = true; has_any = true }
	if val, ok := json_property(body, "type"); ok { input.type = domain.memory_type_from_string(val); input.has_type = true; has_any = true }
	if val, ok := json_property(body, "expires_at"); ok { input.expires_at = val; input.has_expires_at = true; has_any = true }

	// Targeting is replaced by dimension: the presence of an agent_ids /
	// project_ids / template_ids / bridge_ids array (even empty) means "set this
	// dimension to exactly these ids" (empty array = applies to all).
	if vals, ok := json_array_present(body, "agent_ids"); ok {
		input.agent_ids = vals; input.has_agent_ids = true; has_any = true
	}
	if vals, ok := json_array_present(body, "project_ids"); ok {
		out := make([]domain.Project_ID, len(vals))
		for id, i in vals do out[i] = domain.Project_ID(id)
		input.project_ids = out; input.has_project_ids = true; has_any = true
	}
	if vals, ok := json_array_present(body, "bridge_ids"); ok {
		input.bridge_ids = vals; input.has_bridge_ids = true; has_any = true
	}
	if vals, ok := json_array_present(body, "template_ids"); ok {
		input.template_ids = vals; input.has_template_ids = true; has_any = true
	}

	return input, has_any
}
chat_input :: proc(body:string)->content_service.Chat_Input{ return content_service.Chat_Input{agent_id=json_string(body,"agent_id"),agent_instance_id=json_string(body,"agent_instance_id"),chain_id=json_string(body,"chain_id"),project_id=domain.Project_ID(json_string(body,"project_id")),title=json_string(body,"title"),initial_body=json_object_string(body,"initial_message","body"),artifact_ids_json=json_array_raw(body,"artifact_ids"),bridge_id=json_string(body,"bridge_id"),provider=json_string(body,"provider"),provider_profile=json_string(body,"provider_profile"),model=json_string(body,"model")} }
message_input :: proc(body:string)->content_service.Message_Input{ return content_service.Message_Input{body=json_string(body,"body"),artifact_ids_json=json_array_raw(body,"artifact_ids")} }
pane_capture_input :: proc(body:string)->content_service.Pane_Capture_Input{ return content_service.Pane_Capture_Input{width=json_body_int(body,"width",80),settle_ms=json_body_int(body,"settle_ms",3000),line_limit=json_body_int(body,"line_limit",120)} }
artifact_input :: proc(body:string)->content_service.Artifact_Input{
	content := json_string(body,"content")
	b64 := json_string(body,"content_base64")
	if b64 != "" {
		dec, _ := internal_b64.decode(b64, allocator = context.temp_allocator)
		if len(dec) > 0 {
			content = string(dec)
		}
	}
	return content_service.Artifact_Input{kind=json_string(body,"kind"),name=json_string(body,"name"),description=json_string(body,"description"),content_type=json_string(body,"content_type"),content=content,filename=json_string(body,"filename"),agent_id=json_string(body,"agent_id"),agent_instance_id=json_string(body,"agent_instance_id"),chain_id=json_string(body,"chain_id"),task_id=json_string(body,"task_id"),project_id=domain.Project_ID(json_string(body,"project_id")),mime=json_string(body,"mime"),ext=json_string(body,"ext"),sha256=json_string(body,"sha256"),origin_kind=json_string(body,"origin_kind"),origin_ref=json_string(body,"origin_ref")}
}
artifact_input_from_request :: proc(req:Request)->content_service.Artifact_Input{
	ctype := header_value(req.headers,"Content-Type")
	if strings.contains(ctype,"multipart/form-data") {
		if input, ok := multipart_artifact_input(req.body,ctype); ok do return input
	}
	return artifact_input(req.body)
}
multipart_artifact_input :: proc(body,ctype:string)->(content_service.Artifact_Input,bool){
	boundary := multipart_boundary(ctype)
	if boundary == "" do return {},false
	marker := strings.concatenate({"--",boundary}); defer delete(marker)
	marker_crlf := strings.concatenate({"\r\n",marker}); defer delete(marker_crlf)
	marker_lf := strings.concatenate({"\n",marker}); defer delete(marker_lf)
	input: content_service.Artifact_Input
	pos := 0
	seen := false
	for {
		rel := strings.index(body[pos:],marker)
		if rel < 0 do break
		start := pos + rel + len(marker)
		if start + 2 <= len(body) && body[start:start+2] == "--" do break
		if start + 2 <= len(body) && body[start:start+2] == "\r\n" { start += 2 } else if start < len(body) && body[start] == '\n' { start += 1 }
		head_rel := strings.index(body[start:],"\r\n\r\n")
		sep_len := 4
		if head_rel < 0 { head_rel = strings.index(body[start:],"\n\n"); sep_len = 2 }
		if head_rel < 0 do break
		head := body[start:start+head_rel]
		content_start := start + head_rel + sep_len
		next_rel := strings.index(body[content_start:],marker_crlf)
		if next_rel < 0 do next_rel = strings.index(body[content_start:],marker_lf)
		if next_rel < 0 do break
		content_end := content_start + next_rel
		part_body := body[content_start:content_end]
		part_name := multipart_disposition_param(head,"name")
		filename := multipart_disposition_param(head,"filename")
		part_ctype := multipart_header_value(head,"Content-Type")
		if filename != "" && (part_name == "file" || input.content == "") {
			input.content = part_body
			input.filename = filename
			if input.name == "" do input.name = filename
			if part_ctype != "" { input.content_type = part_ctype; input.mime = part_ctype }
			seen = true
		} else if part_name != "" {
			multipart_set_artifact_field(&input,part_name,part_body)
			seen = true
		}
		pos = content_end
	}
	return input,seen
}
multipart_boundary :: proc(ctype:string)->string{
	idx := strings.index(ctype,"boundary=")
	if idx < 0 do return ""
	value := strings.trim_space(ctype[idx+len("boundary="):])
	if semi := strings.index_byte(value,';'); semi >= 0 do value = strings.trim_space(value[:semi])
	if len(value) >= 2 && value[0] == '"' {
		if end := strings.index_byte(value[1:],'"'); end >= 0 do return value[1:1+end]
	}
	return value
}
multipart_header_value :: proc(headers,key:string)->string{
	text := headers
	for line in strings.split_lines_iterator(&text) {
		colon := strings.index_byte(line,':')
		if colon <= 0 do continue
		if ascii_equal_fold(strings.trim_space(line[:colon]),key) do return strings.trim_space(line[colon+1:])
	}
	return ""
}
multipart_disposition_param :: proc(headers,param:string)->string{
	disp := multipart_header_value(headers,"Content-Disposition")
	needle := strings.concatenate({param,"="}); defer delete(needle)
	idx := strings.index(disp,needle)
	if idx < 0 do return ""
	value := strings.trim_space(disp[idx+len(needle):])
	if len(value) >= 1 && value[0] == '"' {
		if end := strings.index_byte(value[1:],'"'); end >= 0 do return value[1:1+end]
	}
	if semi := strings.index_byte(value,';'); semi >= 0 do return strings.trim_space(value[:semi])
	return strings.trim_space(value)
}
multipart_set_artifact_field :: proc(input:^content_service.Artifact_Input,name,value:string){
	switch name {
	case "name": input.name = value
	case "kind": input.kind = value
	case "description": input.description = value
	case "content_type": input.content_type = value
	case "mime": input.mime = value
	case "ext": input.ext = value
	case "sha256": input.sha256 = value
	case "origin_kind": input.origin_kind = value
	case "origin_ref": input.origin_ref = value
	case "filename": input.filename = value
	case "agent_id": input.agent_id = value
	case "agent_instance_id": input.agent_instance_id = value
	case "chain_id": input.chain_id = value
	case "task_id": input.task_id = value
	case "project_id": input.project_id = domain.Project_ID(value)
	}
}
// template_input parses a template create/update body. It uses json_property (not
// json_string) so the service can tell an ABSENT field from one explicitly set to
// empty — a PATCH that omits a field must leave it alone rather than blank it
// (REQ-CLI-8). Same parser the memory PATCH already uses.
template_input :: proc(body:string)->content_service.Template_Input{
	input := content_service.Template_Input{}
	if val, ok := json_property(body,"name"); ok { input.name=val; input.has_name=true }
	if val, ok := json_property(body,"description"); ok { input.description=val; input.has_description=true }
	if val, ok := json_property(body,"persona"); ok { input.persona=val; input.has_persona=true }
	if val, ok := json_property(body,"instructions"); ok { input.instructions=val; input.has_instructions=true }
	return input
}

// write_memory_json emits a memory as JSON. Targeting is exposed as string
// arrays agent_ids/project_ids/template_ids/bridge_ids (empty array = applies to
// all). The legacy scalar agent_id/... and target_* keys are intentionally gone.
write_memory_json :: proc(b:^strings.Builder,m:domain.Memory,preview:bool){ typ:=domain.memory_type_string(m.type); strings.write_string(b,"{\"memory_id\":\""); write_handler_json_string(b,m.memory_id); strings.write_string(b,"\",\"agent_ids\":"); write_memory_id_array(b,m.agent_ids); strings.write_string(b,",\"project_ids\":"); write_memory_project_array(b,m.project_ids); strings.write_string(b,",\"template_ids\":"); write_memory_id_array(b,m.template_ids); strings.write_string(b,",\"bridge_ids\":"); write_memory_id_array(b,m.bridge_ids); strings.write_string(b,",\"type\":\""); write_handler_json_string(b,typ); strings.write_string(b,"\",\"status\":\""); write_handler_json_string(b,m.status); strings.write_string(b,"\",\"title\":\""); write_handler_json_string(b,m.title); strings.write_string(b,"\",\"description\":\""); write_handler_json_string(b,m.description); if preview { strings.write_string(b,"\",\"body_preview\":\""); write_handler_json_string(b,m.body); strings.write_string(b,"\",\"evidence\":\""); write_handler_json_string(b,m.evidence) } else { strings.write_string(b,"\",\"body\":\""); write_handler_json_string(b,m.body); strings.write_string(b,"\",\"evidence\":\""); write_handler_json_string(b,m.evidence) }; strings.write_string(b,"\",\"expires_at\":\""); write_handler_json_string(b,m.expires_at); strings.write_string(b,"\",\"updated_at\":\""); write_handler_json_string(b,m.updated_at); strings.write_string(b,"\"}") }
write_memory_id_array :: proc(b:^strings.Builder, values:[]string){ strings.write_byte(b,'['); for v,i in values { if i>0 do strings.write_byte(b,','); strings.write_byte(b,'"'); write_handler_json_string(b,v); strings.write_byte(b,'"') }; strings.write_byte(b,']') }
write_memory_project_array :: proc(b:^strings.Builder, values:[]domain.Project_ID){ strings.write_byte(b,'['); for v,i in values { if i>0 do strings.write_byte(b,','); strings.write_byte(b,'"'); write_handler_json_string(b,string(v)); strings.write_byte(b,'"') }; strings.write_byte(b,']') }
write_chat_json :: proc(b:^strings.Builder,c:domain.Chat_Conversation){ strings.write_string(b,"{\"conversation_id\":\""); write_handler_json_string(b,c.conversation_id); strings.write_string(b,"\",\"agent_id\":\""); write_handler_json_string(b,c.agent_id); strings.write_string(b,"\",\"agent_instance_id\":\""); write_handler_json_string(b,c.agent_instance_id); strings.write_string(b,"\",\"project_id\":\""); write_handler_json_string(b,string(c.project_id)); strings.write_string(b,"\",\"chain_id\":\""); write_handler_json_string(b,c.chain_id); strings.write_string(b,"\",\"title\":\""); write_handler_json_string(b,c.title); strings.write_string(b,"\",\"unread_count\":"); strings.write_string(b,fmt.tprintf("%d",c.unread_count)); strings.write_string(b,",\"last_message_preview\":\""); write_handler_json_string(b,c.last_message_preview); strings.write_string(b,"\",\"last_message_at\":\""); write_handler_json_string(b,c.last_message_at); strings.write_string(b,"\",\"updated_at\":\""); write_handler_json_string(b,c.updated_at); strings.write_string(b,"\"}") }
write_chat_json_with_runtime :: proc(b:^strings.Builder,c:domain.Chat_Conversation,h:^Content_Handlers,auth:contracts.Auth_Context){
	bridge_id:=""; runtime_status:=""; activity_status:=""; agent_name:=""; agent_slug:=""; agent_display_name:=""
	if h!=nil && h.agents!=nil { if c.agent_instance_id!="" { if inst,inst_ok,_:=agent_service.get_instance(h.agents,auth,c.agent_instance_id); inst_ok { bridge_id=inst.bridge_id; runtime_status=inst.runtime_status; activity_status=inst.activity_status; agent_display_name=inst.display_name } }; if c.agent_id!="" { if agent,agent_ok,_:=agent_service.get_agent(h.agents,auth,c.agent_id); agent_ok { agent_name=agent.name; agent_slug=agent.slug } } }
	last_at:=chat_last_message_at(c)
	standard_direction:=chat_last_message_standard_direction(c.last_message_direction)
	sender_name:="You" if standard_direction=="sent" else agent_name
	strings.write_string(b,"{\"conversation_id\":\""); write_handler_json_string(b,c.conversation_id)
	strings.write_string(b,"\",\"agent_id\":\""); write_handler_json_string(b,c.agent_id)
	strings.write_string(b,"\",\"agent_name\":\""); write_handler_json_string(b,agent_name)
	strings.write_string(b,"\",\"agent_display_name\":\""); write_handler_json_string(b,agent_display_name)
	strings.write_string(b,"\",\"agent_slug\":\""); write_handler_json_string(b,agent_slug)
	strings.write_string(b,"\",\"agent_instance_id\":\""); write_handler_json_string(b,c.agent_instance_id)
	strings.write_string(b,"\",\"bridge_id\":\""); write_handler_json_string(b,bridge_id)
	strings.write_string(b,"\",\"runtime_status\":\""); write_handler_json_string(b,runtime_status)
	// H13: emit activity_status so the sidebar status dot can animate ONLY when the
	// agent is actually WORKING (runtime live AND activity active/busy/working),
	// not merely live-idle. Additive/optional — existing consumers ignore it.
	strings.write_string(b,"\",\"activity_status\":\""); write_handler_json_string(b,activity_status)
	strings.write_string(b,"\",\"project_id\":\""); write_handler_json_string(b,string(c.project_id))
	strings.write_string(b,"\",\"chain_id\":\""); write_handler_json_string(b,c.chain_id)
	strings.write_string(b,"\",\"title\":\""); write_handler_json_string(b,c.title)
	strings.write_string(b,"\",\"unread_count\":"); strings.write_string(b,fmt.tprintf("%d",c.unread_count))
	strings.write_string(b,",\"message_count\":"); strings.write_string(b,fmt.tprintf("%d",c.message_count))
	strings.write_string(b,",\"last_message_preview\":\""); write_handler_json_string(b,c.last_message_preview)
	strings.write_string(b,"\",\"last_message_at\":\""); write_handler_json_string(b,last_at)
	strings.write_string(b,"\",\"last_message_direction\":\""); write_handler_json_string(b,c.last_message_direction)
	strings.write_string(b,"\",\"last_message_unix_ms\":"); strings.write_string(b,fmt.tprintf("%d",rfc3339_unix_ms(last_at)))
	strings.write_string(b,",\"updated_at\":\""); write_handler_json_string(b,c.updated_at)
	strings.write_string(b,"\",\"participants\":[{\"role\":\"user\",\"display_name\":\"You\"},{\"role\":\"agent\",\"agent_id\":\""); write_handler_json_string(b,c.agent_id)
	strings.write_string(b,"\",\"agent_instance_id\":\""); write_handler_json_string(b,c.agent_instance_id)
	strings.write_string(b,"\",\"display_name\":\""); write_handler_json_string(b,agent_name)
	strings.write_string(b,"\"}],\"last_message\":{\"message_id\":\""); write_handler_json_string(b,c.last_message_id)
	strings.write_string(b,"\",\"direction\":\""); write_handler_json_string(b,standard_direction)
	strings.write_string(b,"\",\"raw_direction\":\""); write_handler_json_string(b,c.last_message_direction)
	strings.write_string(b,"\",\"body_preview\":\""); write_handler_json_string(b,c.last_message_preview)
	strings.write_string(b,"\",\"created_at\":\""); write_handler_json_string(b,last_at)
	strings.write_string(b,"\",\"created_unix_ms\":"); strings.write_string(b,fmt.tprintf("%d",rfc3339_unix_ms(last_at)))
	strings.write_string(b,",\"message_type\":\""); write_handler_json_string(b,c.last_message_type)
	strings.write_string(b,"\",\"message_status\":\""); write_handler_json_string(b,c.last_message_status)
	strings.write_string(b,"\",\"sender\":{\"display_name\":\""); write_handler_json_string(b,sender_name)
	strings.write_string(b,"\",\"agent_id\":\""); write_handler_json_string(b,c.last_message_sender_agent_id)
	strings.write_string(b,"\",\"agent_instance_id\":\""); write_handler_json_string(b,c.last_message_sender_agent_instance_id)
	strings.write_string(b,"\"}}}")
}
write_message_json :: proc(b:^strings.Builder,m:domain.Chat_Message,svc:^content_service.Content_Service){ body:=content_service.message_body_for_response(svc,m); typ:=m.message_type; if typ=="" do typ="text"; status:=m.message_status; if status=="" do status="complete"; metadata:=m.metadata_json; if strings.trim_space(metadata)=="" do metadata="{}"; strings.write_string(b,"{\"message_id\":\""); write_handler_json_string(b,m.message_id); strings.write_string(b,"\",\"conversation_id\":\""); write_handler_json_string(b,m.conversation_id); strings.write_string(b,"\",\"direction\":\""); write_handler_json_string(b,m.direction); strings.write_string(b,"\",\"body\":\""); write_handler_json_string(b,body); strings.write_string(b,"\",\"artifact_ids\":"); strings.write_string(b,artifact_json_or_empty(m.artifact_ids_json)); strings.write_string(b,",\"message_type\":\""); write_handler_json_string(b,typ); strings.write_string(b,"\",\"message_status\":\""); write_handler_json_string(b,status); strings.write_string(b,"\",\"metadata\":"); strings.write_string(b,metadata); strings.write_string(b,",\"metadata_json\":\""); write_handler_json_string(b,metadata); strings.write_string(b,"\",\"created_at\":\""); write_handler_json_string(b,m.created_at); strings.write_string(b,"\",\"delivered_at\":\""); write_handler_json_string(b,m.delivered_at); strings.write_string(b,"\",\"read_at\":\""); write_handler_json_string(b,m.read_at); strings.write_byte(b, '"'); write_question_answer_state(b,m,svc); strings.write_byte(b, '}') }
write_artifact_json :: proc(b:^strings.Builder,a:domain.Artifact,with_content:bool){ strings.write_string(b,"{\"artifact_id\":\""); write_handler_json_string(b,a.artifact_id); strings.write_string(b,"\",\"kind\":\""); write_handler_json_string(b,a.kind); strings.write_string(b,"\",\"name\":\""); write_handler_json_string(b,a.name); strings.write_string(b,"\",\"description\":\""); write_handler_json_string(b,a.description); strings.write_string(b,"\",\"content_type\":\""); write_handler_json_string(b,a.content_type); strings.write_string(b,"\",\"mime\":\""); write_handler_json_string(b,a.mime); strings.write_string(b,"\",\"ext\":\""); write_handler_json_string(b,a.ext); strings.write_string(b,"\",\"sha256\":\""); write_handler_json_string(b,a.sha256); strings.write_string(b,"\",\"origin_kind\":\""); write_handler_json_string(b,a.origin_kind); strings.write_string(b,"\",\"origin_ref\":\""); write_handler_json_string(b,a.origin_ref); strings.write_string(b,"\",\"agent_id\":\""); write_handler_json_string(b,a.agent_id); strings.write_string(b,"\",\"agent_instance_id\":\""); write_handler_json_string(b,a.agent_instance_id); strings.write_string(b,"\",\"chain_id\":\""); write_handler_json_string(b,a.chain_id); strings.write_string(b,"\",\"task_id\":\""); write_handler_json_string(b,a.task_id); strings.write_string(b,"\",\"project_id\":\""); write_handler_json_string(b,string(a.project_id)); strings.write_string(b,"\",\"link\":\"artifact://"); write_handler_json_string(b,a.artifact_id); strings.write_string(b,"\",\"size_bytes\":"); strings.write_string(b,fmt.tprintf("%d",a.size_bytes)); if with_content {strings.write_string(b,",\"content\":\""); write_handler_json_string(b,a.content); strings.write_byte(b,'"')}; strings.write_string(b,",\"deleted_at\":\""); write_handler_json_string(b,a.deleted_at); strings.write_string(b,"\",\"created_at\":\""); write_handler_json_string(b,a.created_at); strings.write_string(b,"\",\"updated_at\":\""); write_handler_json_string(b,a.updated_at); strings.write_string(b,"\"}") }
write_template_json :: proc(b:^strings.Builder,t:domain.Template){ strings.write_string(b,"{\"template_id\":\""); write_handler_json_string(b,t.template_id); strings.write_string(b,"\",\"is_system\":"); strings.write_string(b,"true" if t.is_system else "false"); strings.write_string(b,",\"name\":\""); write_handler_json_string(b,t.name); strings.write_string(b,"\",\"description\":\""); write_handler_json_string(b,t.description); strings.write_string(b,"\",\"persona\":\""); write_handler_json_string(b,t.persona); strings.write_string(b,"\",\"instructions\":\""); write_handler_json_string(b,t.instructions); strings.write_string(b,"\"}") }

// chat_instance_runtime_active reports whether the conversation's bound agent
// instance is in a live runtime state (used by the ?active filter). No instance,
// or an unresolvable/stopped one, counts as inactive.
chat_instance_runtime_active :: proc(c:domain.Chat_Conversation,h:^Content_Handlers,auth:contracts.Auth_Context)->bool{
	if h==nil || h.agents==nil || c.agent_instance_id=="" do return false
	inst,inst_ok,_:=agent_service.get_instance(h.agents,auth,c.agent_instance_id)
	if !inst_ok do return false
	return agent_service.runtime_expected_active(inst.runtime_status)
}

chat_last_message_at :: proc(c:domain.Chat_Conversation)->string{ if c.last_message_created_at!="" do return c.last_message_created_at; if c.last_message_at!="" do return c.last_message_at; if c.updated_at!="" do return c.updated_at; return c.created_at }
chat_page_cursor :: proc(c:domain.Chat_Conversation)->string{ at:=chat_last_message_at(c); if at=="" do return ""; return strings.concatenate({at,"|",c.conversation_id}) }
artifact_page_cursor :: proc(a: domain.Artifact, sort_field: string) -> string {
	sort_val := a.updated_at
	switch strings.to_lower(strings.trim_space(sort_field), context.temp_allocator) {
	case "created_at":
		sort_val = a.created_at
	case "name":
		sort_val = a.name
	case "size_bytes":
		sort_val = fmt.tprintf("%d", a.size_bytes)
	case:
		sort_val = a.updated_at
	}
	return fmt.tprintf("%s|%s", sort_val, a.artifact_id)
}
chat_last_message_standard_direction :: proc(direction:string)->string{ switch direction { case "user_to_agent": return "sent"; case "agent_to_user": return "received" }; if direction=="" do return ""; return direction }

rfc3339_unix_ms :: proc(value:string)->i64{
	if len(value)<19 do return 0
	year,ok:=rfc3339_part(value,0,4); if !ok do return 0
	month,ok2:=rfc3339_part(value,5,2); if !ok2 do return 0
	day,ok3:=rfc3339_part(value,8,2); if !ok3 do return 0
	hour,ok4:=rfc3339_part(value,11,2); if !ok4 do return 0
	minute,ok5:=rfc3339_part(value,14,2); if !ok5 do return 0
	second,ok6:=rfc3339_part(value,17,2); if !ok6 do return 0
	if month<1 || month>12 || day<1 || day>31 || hour<0 || hour>23 || minute<0 || minute>59 || second<0 || second>60 do return 0
	days:i64=0
	for y:=1970; y<year; y+=1 { days += 366 if rfc3339_leap_year(y) else 365 }
	for m:=1; m<month; m+=1 { days += i64(rfc3339_month_days(year,m)) }
	days += i64(day-1)
	return (((days*24 + i64(hour))*60 + i64(minute))*60 + i64(second))*1000
}
rfc3339_part :: proc(value:string,start,count:int)->(int,bool){ if start<0 || count<=0 || start+count>len(value) do return 0,false; parsed,ok:=strconv.parse_int(value[start:start+count]); if !ok do return 0,false; return int(parsed),true }
rfc3339_leap_year :: proc(year:int)->bool{ if year%400==0 do return true; if year%100==0 do return false; return year%4==0 }
rfc3339_month_days :: proc(year,month:int)->int{ switch month { case 1,3,5,7,8,10,12: return 31; case 4,6,9,11: return 30; case 2: return 29 if rfc3339_leap_year(year) else 28 }; return 30 }

query_value :: proc(q,key:string)->string{ parts:=strings.split(q,"&"); defer delete(parts); for p in parts{ eq:=strings.index_byte(p,'='); if eq>=0 && p[:eq]==key do return query_component_decode(p[eq+1:]) }; return "" }
// memory_filter_query resolves a single filter value for a targeting dimension.
// It prefers the plural key (agent_ids/...) and falls back to the singular key,
// accepting a CSV or repeated value and returning the first non-empty token.
memory_filter_query :: proc(q, plural_key, singular_key: string) -> string {
	raw := query_value(q, plural_key)
	if raw == "" do raw = query_value(q, singular_key)
	if raw == "" do return ""
	if comma := strings.index_byte(raw, ','); comma >= 0 do return strings.trim_space(raw[:comma])
	return strings.trim_space(raw)
}
query_component_decode :: proc(value:string)->string{
	if strings.index_byte(value,'%')<0 && strings.index_byte(value,'+')<0 do return value
	b:=strings.builder_make()
	i:=0
	for i<len(value) {
		ch:=value[i]
		if ch=='+' { strings.write_byte(&b,' '); i+=1; continue }
		if ch=='%' && i+2<len(value) {
			hi,ok_hi:=query_hex_nibble(value[i+1]); lo,ok_lo:=query_hex_nibble(value[i+2])
			if ok_hi && ok_lo { strings.write_byte(&b,byte(hi*16+lo)); i+=3; continue }
		}
		strings.write_byte(&b,ch); i+=1
	}
	return strings.to_string(b)
}
query_hex_nibble :: proc(ch:byte)->(int,bool){ if ch>='0' && ch<='9' do return int(ch-'0'),true; if ch>='a' && ch<='f' do return int(ch-'a')+10,true; if ch>='A' && ch<='F' do return int(ch-'A')+10,true; return 0,false }
query_int :: proc(q,key:string,d:int)->int{ v:=query_value(q,key); if p,ok:=strconv.parse_int(v); ok do return int(p); return d }
query_bool :: proc(q,key:string,d:bool)->bool{ v:=query_value(q,key); if v=="" do return d; return v=="true" || v=="1" || v=="yes" }
json_body_int :: proc(body, key: string, d: int) -> int { return jsonx.extract_int(body, key, d) }
pane_capture_request_id_from_metadata :: proc(metadata:string)->string{ return json_string(metadata,"pane_capture_request_id") }
json_array_raw :: proc(body, key: string, allocator := context.allocator) -> string {
	res, ok := jsonx.extract_raw_array(body, key, false, allocator)
	if !ok do return "[]"
	return res
}
json_object_string :: proc(body, obj, key: string, allocator := context.allocator) -> string {
	raw_obj, ok := jsonx.extract_raw_object(body, obj, false, context.temp_allocator)
	if !ok do return ""
	return jsonx.extract_string(raw_obj, key, "", false, allocator)
}
artifact_json_or_empty :: proc(v:string)->string{ if strings.trim_space(v)=="" do return "[]"; return v }
