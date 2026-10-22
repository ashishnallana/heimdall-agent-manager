package sqlite

import "core:fmt"
import "core:strconv"
import "core:strings"
import bootcache "odin_test:hub/bootcache"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import jsonx "odin_test:lib/jsonx"

Content_Repo_SQLite :: struct { conn: ^Conn }

new_content_repository :: proc(impl: ^Content_Repo_SQLite, conn: ^Conn) -> iface.Content_Repository {
	impl.conn = conn
	return iface.Content_Repository{ctx=rawptr(impl), list_unread_incoming_ids=content_list_unread_incoming_ids_sqlite, save_memory=content_save_memory_sqlite, get_memory=content_get_memory_sqlite, list_memories=content_list_memories_sqlite, save_conversation=content_save_conversation_sqlite, get_conversation=content_get_conversation_sqlite, list_conversations=content_list_conversations_sqlite, list_conversation_project_links=content_list_conversation_project_links_sqlite, save_message=content_save_message_sqlite, get_message=content_get_message_sqlite, update_message=content_update_message_sqlite, list_messages=content_list_messages_sqlite, list_user_visible_messages=content_list_user_visible_messages_sqlite, list_agent_inbox_messages=content_list_agent_inbox_messages_sqlite, mark_messages_read=content_mark_messages_read_sqlite, save_artifact=content_save_artifact_sqlite, get_artifact=content_get_artifact_sqlite, list_artifacts=content_list_artifacts_sqlite, delete_artifact=content_delete_artifact_sqlite, save_template=content_save_template_sqlite, get_template=content_get_template_sqlite, list_templates=content_list_templates_sqlite, delete_template=content_delete_template_sqlite}
}

content_save_memory_sqlite :: proc(ctx: rawptr, m: domain.Memory) -> (domain.Memory, bool, domain.Domain_Error) {
	impl := (^Content_Repo_SQLite)(ctx); stmt: sqlite3_stmt=nil
	q := "INSERT INTO memories (memory_id, owner_user_id, agent_ids, project_ids, template_ids, bridge_ids, type, status, title, description, body, evidence, expires_at, created_at, updated_at, proposed_by_instance_id, proposed_in_chain_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(memory_id) DO UPDATE SET agent_ids=excluded.agent_ids, project_ids=excluded.project_ids, template_ids=excluded.template_ids, bridge_ids=excluded.bridge_ids, type=excluded.type, status=excluded.status, title=excluded.title, description=excluded.description, body=excluded.body, evidence=excluded.evidence, expires_at=excluded.expires_at, updated_at=excluded.updated_at;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return {}, false, domain.domain_error(.Internal_Error,"failed to prepare memory save")
	defer sqlite3_finalize(stmt); bind_memory(stmt,m)
	if sqlite3_step(stmt) != SQLITE_DONE do return {}, false, domain.domain_error(.Conflict,"memory could not be saved")
	// A memory write can change any agent's rendered memories fragment (and, for
	// `system`-scoped memories, every agent's), so invalidate the bootstrap
	// manifest cache by bumping the shared content epoch.
	bootcache.bump_content_epoch()
	return m,true,{}
}
content_get_memory_sqlite :: proc(ctx: rawptr, id: string) -> (domain.Memory,bool,domain.Domain_Error) { impl:=(^Content_Repo_SQLite)(ctx); stmt:sqlite3_stmt=nil; q:="SELECT memory_id, owner_user_id, agent_ids, project_ids, template_ids, bridge_ids, type, status, title, description, body, evidence, expires_at, created_at, updated_at, proposed_by_instance_id, proposed_in_chain_id FROM memories WHERE memory_id=?;"; if sqlite3_prepare_v2(impl.conn.db,cstring(raw_data(q)),-1,&stmt,nil)!=SQLITE_OK do return {},false,domain.domain_error(.Internal_Error,"failed memory lookup"); defer sqlite3_finalize(stmt); bind_text(stmt,1,id); if sqlite3_step(stmt)!=SQLITE_ROW do return {},false,domain.domain_error(.Not_Found,"memory not found"); return memory_from_stmt(stmt),true,{} }
content_list_memories_sqlite :: proc(ctx: rawptr, owner: domain.User_ID) -> ([]domain.Memory,domain.Domain_Error) { impl:=(^Content_Repo_SQLite)(ctx); stmt:sqlite3_stmt=nil; q:="SELECT memory_id, owner_user_id, agent_ids, project_ids, template_ids, bridge_ids, type, status, title, description, body, evidence, expires_at, created_at, updated_at, proposed_by_instance_id, proposed_in_chain_id FROM memories WHERE owner_user_id=? OR owner_user_id='system' ORDER BY updated_at DESC;"; if sqlite3_prepare_v2(impl.conn.db,cstring(raw_data(q)),-1,&stmt,nil)!=SQLITE_OK do return nil,domain.domain_error(.Internal_Error,"failed memory list"); defer sqlite3_finalize(stmt); bind_text(stmt,1,string(owner)); out:=make([dynamic]domain.Memory); for sqlite3_step(stmt)==SQLITE_ROW do append(&out,memory_from_stmt(stmt)); return out[:],{} }

content_save_conversation_sqlite :: proc(ctx: rawptr, c: domain.Chat_Conversation) -> (domain.Chat_Conversation,bool,domain.Domain_Error) { impl:=(^Content_Repo_SQLite)(ctx); stmt:sqlite3_stmt=nil; q:="INSERT INTO chat_conversations (conversation_id, owner_user_id, agent_id, agent_instance_id, project_id, chain_id, title, unread_count, last_message_preview, last_message_at, created_at, updated_at, last_activity_at, last_title_nudge_at, title_source) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(conversation_id) DO UPDATE SET title=excluded.title, unread_count=excluded.unread_count, last_message_preview=excluded.last_message_preview, last_message_at=excluded.last_message_at, updated_at=excluded.updated_at, last_activity_at=excluded.last_activity_at, last_title_nudge_at=excluded.last_title_nudge_at, title_source=excluded.title_source;"; if sqlite3_prepare_v2(impl.conn.db,cstring(raw_data(q)),-1,&stmt,nil)!=SQLITE_OK do return {},false,domain.domain_error(.Internal_Error,"failed conversation save"); defer sqlite3_finalize(stmt); bind_conversation(stmt,c); if sqlite3_step(stmt)!=SQLITE_DONE do return {},false,domain.domain_error(.Conflict,"conversation could not be saved"); return c,true,{} }
content_get_conversation_sqlite :: proc(ctx: rawptr, id:string)->(domain.Chat_Conversation,bool,domain.Domain_Error){ impl:=(^Content_Repo_SQLite)(ctx); stmt:sqlite3_stmt=nil; q:="SELECT conversation_id, owner_user_id, agent_id, agent_instance_id, project_id, chain_id, title, unread_count, last_message_preview, last_message_at, created_at, updated_at, last_activity_at, last_title_nudge_at, title_source FROM chat_conversations WHERE conversation_id=?;"; if sqlite3_prepare_v2(impl.conn.db,cstring(raw_data(q)),-1,&stmt,nil)!=SQLITE_OK do return {},false,domain.domain_error(.Internal_Error,"failed conversation lookup"); defer sqlite3_finalize(stmt); bind_text(stmt,1,id); if sqlite3_step(stmt)!=SQLITE_ROW do return {},false,domain.domain_error(.Not_Found,"conversation not found"); return conversation_from_stmt(stmt),true,{} }
content_list_conversations_sqlite :: proc(ctx:rawptr, owner:domain.User_ID, limit:int, cursor:string)->([]domain.Chat_Conversation,domain.Domain_Error){
	impl:=(^Content_Repo_SQLite)(ctx); stmt:sqlite3_stmt=nil
	eff_limit:=limit; if eff_limit<=0 do eff_limit=50; if eff_limit>200 do eff_limit=200
	cursor_order_at:=cursor; cursor_conversation_id:=""
	if sep:=strings.index_byte(cursor,'|'); sep>=0 {
		cursor_order_at=cursor[:sep]
		cursor_conversation_id=cursor[sep+1:]
	}
	select_fields := "c.conversation_id, c.owner_user_id, c.agent_id, c.agent_instance_id, c.project_id, c.chain_id, c.title, c.unread_count, c.last_message_preview, c.last_message_at, c.created_at, c.updated_at, c.last_activity_at, c.last_title_nudge_at, c.title_source, COALESCE((SELECT m.message_id FROM chat_messages m WHERE m.conversation_id=c.conversation_id AND m.owner_user_id=c.owner_user_id AND m.direction != 'agent_to_agent' ORDER BY m.created_at DESC, m.message_id DESC LIMIT 1), ''), COALESCE((SELECT m.direction FROM chat_messages m WHERE m.conversation_id=c.conversation_id AND m.owner_user_id=c.owner_user_id AND m.direction != 'agent_to_agent' ORDER BY m.created_at DESC, m.message_id DESC LIMIT 1), ''), COALESCE((SELECT m.sender_agent_id FROM chat_messages m WHERE m.conversation_id=c.conversation_id AND m.owner_user_id=c.owner_user_id AND m.direction != 'agent_to_agent' ORDER BY m.created_at DESC, m.message_id DESC LIMIT 1), ''), COALESCE((SELECT m.sender_agent_instance_id FROM chat_messages m WHERE m.conversation_id=c.conversation_id AND m.owner_user_id=c.owner_user_id AND m.direction != 'agent_to_agent' ORDER BY m.created_at DESC, m.message_id DESC LIMIT 1), ''), COALESCE((SELECT COALESCE(m.message_type, 'text') FROM chat_messages m WHERE m.conversation_id=c.conversation_id AND m.owner_user_id=c.owner_user_id AND m.direction != 'agent_to_agent' ORDER BY m.created_at DESC, m.message_id DESC LIMIT 1), 'text'), COALESCE((SELECT COALESCE(m.message_status, 'complete') FROM chat_messages m WHERE m.conversation_id=c.conversation_id AND m.owner_user_id=c.owner_user_id AND m.direction != 'agent_to_agent' ORDER BY m.created_at DESC, m.message_id DESC LIMIT 1), 'complete'), COALESCE((SELECT m.created_at FROM chat_messages m WHERE m.conversation_id=c.conversation_id AND m.owner_user_id=c.owner_user_id AND m.direction != 'agent_to_agent' ORDER BY m.created_at DESC, m.message_id DESC LIMIT 1), c.last_message_at), (SELECT COUNT(*) FROM chat_messages m WHERE m.conversation_id=c.conversation_id AND m.owner_user_id=c.owner_user_id AND m.direction != 'agent_to_agent')"
	order_expr := "COALESCE(NULLIF(c.last_message_at,''), c.updated_at, c.created_at)"
	q := strings.concatenate({"SELECT ", select_fields, " FROM chat_conversations c WHERE c.owner_user_id=? ORDER BY ", order_expr, " DESC, c.conversation_id DESC LIMIT ?;"})
	if cursor_order_at!="" && cursor_conversation_id!="" {
		q=strings.concatenate({"SELECT ", select_fields, " FROM chat_conversations c WHERE c.owner_user_id=? AND (", order_expr, " < ? OR (", order_expr, " = ? AND c.conversation_id < ?)) ORDER BY ", order_expr, " DESC, c.conversation_id DESC LIMIT ?;"})
	} else if cursor_order_at!="" {
		q=strings.concatenate({"SELECT ", select_fields, " FROM chat_conversations c WHERE c.owner_user_id=? AND ", order_expr, " < ? ORDER BY ", order_expr, " DESC, c.conversation_id DESC LIMIT ?;"})
	}
	if sqlite3_prepare_v2(impl.conn.db,cstring(raw_data(q)),-1,&stmt,nil)!=SQLITE_OK do return nil,domain.domain_error(.Internal_Error,"failed conversation list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt,1,string(owner))
	if cursor_order_at!="" && cursor_conversation_id!="" {
		bind_text(stmt,2,cursor_order_at); bind_text(stmt,3,cursor_order_at); bind_text(stmt,4,cursor_conversation_id); bind_text(stmt,5,int_s(eff_limit))
	} else if cursor_order_at!="" {
		bind_text(stmt,2,cursor_order_at); bind_text(stmt,3,int_s(eff_limit))
	} else {
		bind_text(stmt,2,int_s(eff_limit))
	}
	out:=make([dynamic]domain.Chat_Conversation)
	for sqlite3_step(stmt)==SQLITE_ROW do append(&out,conversation_summary_from_stmt(stmt))
	return out[:],{}
}

CHAT_MESSAGE_SELECT :: "message_id, conversation_id, owner_user_id, direction, sender_agent_id, sender_agent_instance_id, body, artifact_ids_json, COALESCE(message_type, 'text'), COALESCE(message_status, 'complete'), COALESCE(metadata_json, '{}'), created_at, delivered_at, read_at"
// CHAT_MESSAGE_SELECT_M is CHAT_MESSAGE_SELECT qualified with the alias m, for
// queries that join chat_messages to itself (attention_repo_sqlite.odin).
CHAT_MESSAGE_SELECT_M :: "m.message_id, m.conversation_id, m.owner_user_id, m.direction, m.sender_agent_id, m.sender_agent_instance_id, m.body, m.artifact_ids_json, COALESCE(m.message_type, 'text'), COALESCE(m.message_status, 'complete'), COALESCE(m.metadata_json, '{}'), m.created_at, m.delivered_at, m.read_at"

content_save_message_sqlite :: proc(ctx:rawptr, m:domain.Chat_Message)->(domain.Chat_Message,bool,domain.Domain_Error){ impl:=(^Content_Repo_SQLite)(ctx); stmt:sqlite3_stmt=nil; q:="INSERT INTO chat_messages (message_id, conversation_id, owner_user_id, direction, sender_agent_id, sender_agent_instance_id, body, artifact_ids_json, message_type, message_status, metadata_json, created_at, delivered_at, read_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(message_id) DO UPDATE SET delivered_at=excluded.delivered_at, read_at=excluded.read_at;"; if sqlite3_prepare_v2(impl.conn.db,cstring(raw_data(q)),-1,&stmt,nil)!=SQLITE_OK do return {},false,domain.domain_error(.Internal_Error,"failed message save"); defer sqlite3_finalize(stmt); bind_message(stmt,m); if sqlite3_step(stmt)!=SQLITE_DONE do return {},false,domain.domain_error(.Conflict,"message could not be saved"); return normalize_message_defaults(m),true,{} }
content_get_message_sqlite :: proc(ctx:rawptr, id:string)->(domain.Chat_Message,bool,domain.Domain_Error){ impl:=(^Content_Repo_SQLite)(ctx); stmt:sqlite3_stmt=nil; q:=strings.concatenate({"SELECT ",CHAT_MESSAGE_SELECT," FROM chat_messages WHERE message_id=?;"}); if sqlite3_prepare_v2(impl.conn.db,cstring(raw_data(q)),-1,&stmt,nil)!=SQLITE_OK do return {},false,domain.domain_error(.Internal_Error,"failed message lookup"); defer sqlite3_finalize(stmt); bind_text(stmt,1,id); if sqlite3_step(stmt)!=SQLITE_ROW do return {},false,domain.domain_error(.Not_Found,"message not found"); return message_from_stmt(stmt),true,{} }
content_update_message_sqlite :: proc(ctx:rawptr, owner:domain.User_ID, cid,id,body,status,metadata_json:string)->(domain.Chat_Message,bool,domain.Domain_Error){ impl:=(^Content_Repo_SQLite)(ctx); stmt:sqlite3_stmt=nil; q:="UPDATE chat_messages SET body=?, message_status=?, metadata_json=? WHERE owner_user_id=? AND conversation_id=? AND message_id=?;"; if sqlite3_prepare_v2(impl.conn.db,cstring(raw_data(q)),-1,&stmt,nil)!=SQLITE_OK do return {},false,domain.domain_error(.Internal_Error,"failed message update"); defer sqlite3_finalize(stmt); bind_text(stmt,1,body); bind_text(stmt,2,normalize_message_status(status)); bind_text(stmt,3,json_object_or_empty(metadata_json)); bind_text(stmt,4,string(owner)); bind_text(stmt,5,cid); bind_text(stmt,6,id); if sqlite3_step(stmt)!=SQLITE_DONE do return {},false,domain.domain_error(.Conflict,"message could not be updated"); return content_get_message_sqlite(ctx,id) }
content_list_messages_sqlite :: proc(ctx:rawptr, cid:string, owner:domain.User_ID, limit:int, cursor:string)->([]domain.Chat_Message,domain.Domain_Error){ impl:=(^Content_Repo_SQLite)(ctx); stmt:sqlite3_stmt=nil; q:=strings.concatenate({"SELECT ",CHAT_MESSAGE_SELECT," FROM chat_messages WHERE conversation_id=? AND owner_user_id=? ORDER BY created_at DESC LIMIT ?;"}); if cursor!="" do q=strings.concatenate({"SELECT ",CHAT_MESSAGE_SELECT," FROM chat_messages WHERE conversation_id=? AND owner_user_id=? AND created_at < ? ORDER BY created_at DESC LIMIT ?;"}); if sqlite3_prepare_v2(impl.conn.db,cstring(raw_data(q)),-1,&stmt,nil)!=SQLITE_OK do return nil,domain.domain_error(.Internal_Error,"failed message list"); defer sqlite3_finalize(stmt); bind_text(stmt,1,cid); bind_text(stmt,2,string(owner)); if cursor!="" {bind_text(stmt,3,cursor); bind_text(stmt,4,int_s(limit))} else {bind_text(stmt,3,int_s(limit))}; out:=make([dynamic]domain.Chat_Message); for sqlite3_step(stmt)==SQLITE_ROW do append(&out,message_from_stmt(stmt)); return out[:],{} }
content_list_user_visible_messages_sqlite :: proc(ctx:rawptr, cid:string, owner:domain.User_ID, limit:int, cursor:string)->([]domain.Chat_Message,domain.Domain_Error){ impl:=(^Content_Repo_SQLite)(ctx); stmt:sqlite3_stmt=nil; q:=strings.concatenate({"SELECT ",CHAT_MESSAGE_SELECT," FROM chat_messages WHERE conversation_id=? AND owner_user_id=? AND direction != 'agent_to_agent' ORDER BY created_at DESC LIMIT ?;"}); if cursor!="" do q=strings.concatenate({"SELECT ",CHAT_MESSAGE_SELECT," FROM chat_messages WHERE conversation_id=? AND owner_user_id=? AND direction != 'agent_to_agent' AND created_at < ? ORDER BY created_at DESC LIMIT ?;"}); if sqlite3_prepare_v2(impl.conn.db,cstring(raw_data(q)),-1,&stmt,nil)!=SQLITE_OK do return nil,domain.domain_error(.Internal_Error,"failed visible message list"); defer sqlite3_finalize(stmt); bind_text(stmt,1,cid); bind_text(stmt,2,string(owner)); if cursor!="" {bind_text(stmt,3,cursor); bind_text(stmt,4,int_s(limit))} else {bind_text(stmt,3,int_s(limit))}; out:=make([dynamic]domain.Chat_Message); for sqlite3_step(stmt)==SQLITE_ROW do append(&out,message_from_stmt(stmt)); return out[:],{} }

content_list_agent_inbox_messages_sqlite :: proc(ctx:rawptr, cid:string, owner:domain.User_ID, agent_instance_id: string, unread_only, receiver_only, include_outgoing, include_debug: bool, limit:int, cursor:string)->([]domain.Chat_Message,domain.Domain_Error){
	impl:=(^Content_Repo_SQLite)(ctx); stmt:sqlite3_stmt=nil
	
	filters := make([dynamic]string)
	append(&filters, "conversation_id=? AND owner_user_id=?")
	if unread_only do append(&filters, "read_at=''")
	if !include_outgoing {
		append(&filters, "direction != 'agent_to_user'")
	}
	if receiver_only {
		// user_to_agent rows set sender_agent_instance_id to the receiving agent, so IS NULL fails.
		// Instead, filter out caller-sent agent_to_agent messages directly.
		append(&filters, "(direction != 'agent_to_agent' OR sender_agent_instance_id != ?)")
	}
	// 'shell_run' joins the UI-only message types here (REQ-SHELL-5): it is a marker
	// the UI renders as a run indicator, not correspondence addressed to the agent.
	// The agent learns its background run finished from a transient nudge instead, so
	// surfacing the marker in its inbox would be the same fact twice, as noise.
	if !include_debug do append(&filters, "message_type NOT IN ('pane_capture', 'status_update', 'pane_capture_result', 'shell_run')")
	
	if cursor != "" do append(&filters, "created_at < ?")
	
	filter_str := strings.join(filters[:], " AND ")
	
	q:=strings.concatenate({"SELECT ",CHAT_MESSAGE_SELECT," FROM chat_messages WHERE ", filter_str, " ORDER BY created_at DESC LIMIT ?;"})
	
	if sqlite3_prepare_v2(impl.conn.db,cstring(raw_data(q)),-1,&stmt,nil)!=SQLITE_OK do return nil,domain.domain_error(.Internal_Error,"failed agent inbox list")
	defer sqlite3_finalize(stmt)
	
	bind_text(stmt,1,cid)
	bind_text(stmt,2,string(owner))
	
	bind_idx := 3
	
	if receiver_only {
		bind_text(stmt,bind_idx,agent_instance_id)
		bind_idx += 1
	}
	
	if cursor != "" {
		bind_text(stmt,bind_idx,cursor)
		bind_idx += 1
	}
	bind_text(stmt,bind_idx,int_s(limit))
	
	out:=make([dynamic]domain.Chat_Message)
	for sqlite3_step(stmt)==SQLITE_ROW do append(&out,message_from_stmt(stmt))
	return out[:],{}
}

content_mark_messages_read_sqlite :: proc(ctx:rawptr, owner:domain.User_ID, message_ids:[]string, updated_at:string)->(int,domain.Domain_Error){
	if len(message_ids) == 0 do return 0, {}
	impl:=(^Content_Repo_SQLite)(ctx); stmt:sqlite3_stmt=nil
	
	// Preserve latest-read timestamps and the input-count return contract. Only
	// suppress exact timestamp repeats; metadata-only changes no longer reindex FTS.
	// Create an IN clause with enough ?'s
	qs := make([dynamic]string, context.temp_allocator)
	for _ in message_ids { append(&qs, "?") }
	in_clause := strings.join(qs[:], ",", context.temp_allocator)
	
	q:=strings.concatenate({"UPDATE chat_messages SET read_at=? WHERE read_at IS NOT ?1 AND owner_user_id=? AND message_id IN (", in_clause, ");"}, context.temp_allocator)
	// A concatenated string is not NUL-terminated; give sqlite a real cstring.
	if sqlite3_prepare_v2(impl.conn.db,strings.clone_to_cstring(q, context.temp_allocator),-1,&stmt,nil)!=SQLITE_OK do return 0,domain.domain_error(.Internal_Error,"failed mark messages read")
	defer sqlite3_finalize(stmt)
	
	bind_text(stmt, 1, updated_at)
	bind_text(stmt, 2, string(owner))
	for id, i in message_ids {
		bind_text(stmt, 3 + i, id)
	}
	
	if sqlite3_step(stmt)!=SQLITE_DONE do return 0,domain.domain_error(.Internal_Error,"failed mark messages read exec")
	return len(message_ids), {}
}

content_save_artifact_sqlite :: proc(ctx:rawptr, a:domain.Artifact)->(domain.Artifact,bool,domain.Domain_Error){ impl:=(^Content_Repo_SQLite)(ctx); stmt:sqlite3_stmt=nil; q:="INSERT INTO artifacts (artifact_id, owner_user_id, kind, name, description, content_type, size_bytes, blob_ref, content, agent_id, agent_instance_id, chain_id, task_id, project_id, mime, ext, sha256, origin_kind, origin_ref, deleted_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(artifact_id) DO UPDATE SET kind=excluded.kind, name=excluded.name, description=excluded.description, content_type=excluded.content_type, size_bytes=excluded.size_bytes, blob_ref=excluded.blob_ref, content=excluded.content, mime=excluded.mime, ext=excluded.ext, sha256=excluded.sha256, origin_kind=excluded.origin_kind, origin_ref=excluded.origin_ref, deleted_at=excluded.deleted_at, updated_at=excluded.updated_at;"; if sqlite3_prepare_v2(impl.conn.db,cstring(raw_data(q)),-1,&stmt,nil)!=SQLITE_OK do return {},false,domain.domain_error(.Internal_Error,"failed artifact save"); defer sqlite3_finalize(stmt); bind_artifact(stmt,a); if sqlite3_step(stmt)!=SQLITE_DONE do return {},false,domain.domain_error(.Conflict,"artifact could not be saved"); return a,true,{} }
content_get_artifact_sqlite :: proc(ctx:rawptr,id:string)->(domain.Artifact,bool,domain.Domain_Error){ impl:=(^Content_Repo_SQLite)(ctx); stmt:sqlite3_stmt=nil; q:="SELECT artifact_id, owner_user_id, kind, name, description, content_type, size_bytes, blob_ref, content, agent_id, agent_instance_id, chain_id, task_id, project_id, mime, ext, sha256, origin_kind, origin_ref, deleted_at, created_at, updated_at FROM artifacts WHERE artifact_id=?;"; if sqlite3_prepare_v2(impl.conn.db,cstring(raw_data(q)),-1,&stmt,nil)!=SQLITE_OK do return {},false,domain.domain_error(.Internal_Error,"failed artifact lookup"); defer sqlite3_finalize(stmt); bind_text(stmt,1,id); if sqlite3_step(stmt)!=SQLITE_ROW do return {},false,domain.domain_error(.Not_Found,"artifact not found"); return artifact_from_stmt(stmt),true,{} }
content_list_artifacts_sqlite :: proc(ctx: rawptr, owner: domain.User_ID, filter: domain.Artifact_List_Filter) -> ([]domain.Artifact, domain.Domain_Error) {
	impl := (^Content_Repo_SQLite)(ctx)
	clauses := make([dynamic]string, context.temp_allocator)
	bind_vals := make([dynamic]string, context.temp_allocator)

	append(&clauses, "owner_user_id = ?")
	append(&bind_vals, string(owner))

	if string(filter.project_id) != "" {
		append(&clauses, "project_id = ?")
		append(&bind_vals, string(filter.project_id))
	}
	if filter.agent_instance_id != "" {
		append(&clauses, "agent_instance_id = ?")
		append(&bind_vals, filter.agent_instance_id)
	}
	if filter.agent_id != "" {
		append(&clauses, "agent_id = ?")
		append(&bind_vals, filter.agent_id)
	}
	if filter.chain_id != "" {
		append(&clauses, "chain_id = ?")
		append(&bind_vals, filter.chain_id)
	}
	if filter.task_id != "" {
		append(&clauses, "task_id = ?")
		append(&bind_vals, filter.task_id)
	}
	if filter.kind != "" {
		append(&clauses, "kind = ?")
		append(&bind_vals, filter.kind)
	}
	if filter.since != "" {
		append(&clauses, "created_at >= ?")
		append(&bind_vals, filter.since)
	}
	if filter.until != "" {
		append(&clauses, "created_at <= ?")
		append(&bind_vals, filter.until)
	}
	if !filter.include_deleted {
		append(&clauses, "(deleted_at IS NULL OR deleted_at = '')")
	}

	sort_col := "updated_at"
	switch strings.to_lower(strings.trim_space(filter.sort_field), context.temp_allocator) {
	case "created_at":
		sort_col = "created_at"
	case "name":
		sort_col = "name"
	case "size_bytes":
		sort_col = "size_bytes"
	case:
		sort_col = "updated_at"
	}

	is_asc := strings.to_lower(strings.trim_space(filter.sort_order), context.temp_allocator) == "asc"
	sort_dir := "ASC" if is_asc else "DESC"

	if filter.cursor != "" {
		cursor_val := filter.cursor
		cursor_id := ""
		if sep := strings.index_byte(filter.cursor, '|'); sep >= 0 {
			cursor_val = filter.cursor[:sep]
			cursor_id = filter.cursor[sep+1:]
		}
		if is_asc {
			if cursor_id != "" {
				append(&clauses, fmt.tprintf("(%s > ? OR (%s = ? AND artifact_id > ?))", sort_col, sort_col))
				append(&bind_vals, cursor_val)
				append(&bind_vals, cursor_val)
				append(&bind_vals, cursor_id)
			} else {
				append(&clauses, fmt.tprintf("%s > ?", sort_col))
				append(&bind_vals, cursor_val)
			}
		} else {
			if cursor_id != "" {
				append(&clauses, fmt.tprintf("(%s < ? OR (%s = ? AND artifact_id < ?))", sort_col, sort_col))
				append(&bind_vals, cursor_val)
				append(&bind_vals, cursor_val)
				append(&bind_vals, cursor_id)
			} else {
				append(&clauses, fmt.tprintf("%s < ?", sort_col))
				append(&bind_vals, cursor_val)
			}
		}
	}

	eff_limit := filter.limit
	if eff_limit <= 0 do eff_limit = 50
	if eff_limit > 200 do eff_limit = 200

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "SELECT artifact_id, owner_user_id, kind, name, description, content_type, size_bytes, blob_ref, agent_id, agent_instance_id, chain_id, task_id, project_id, mime, ext, sha256, origin_kind, origin_ref, deleted_at, created_at, updated_at FROM artifacts WHERE ")
	for clause, i in clauses {
		if i > 0 do strings.write_string(&b, " AND ")
		strings.write_string(&b, clause)
	}
	strings.write_string(&b, " ORDER BY ")
	strings.write_string(&b, sort_col)
	strings.write_string(&b, " ")
	strings.write_string(&b, sort_dir)
	strings.write_string(&b, ", artifact_id ")
	strings.write_string(&b, sort_dir)
	strings.write_string(&b, " LIMIT ?;")

	append(&bind_vals, int_s(eff_limit + 1))

	q := strings.to_string(b)
	stmt: sqlite3_stmt = nil
	q_c := strings.clone_to_cstring(q, context.temp_allocator)
	if sqlite3_prepare_v2(impl.conn.db, q_c, -1, &stmt, nil) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "failed artifact list")
	}
	defer sqlite3_finalize(stmt)

	for val, i in bind_vals {
		bind_text(stmt, i + 1, val)
	}

	out := make([dynamic]domain.Artifact)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&out, artifact_summary_from_stmt(stmt))
	}
	return out[:], {}
}
content_delete_artifact_sqlite :: proc(ctx:rawptr,id:string,owner:domain.User_ID)->(bool,domain.Domain_Error){ impl:=(^Content_Repo_SQLite)(ctx); stmt:sqlite3_stmt=nil; q:="DELETE FROM artifacts WHERE artifact_id=? AND owner_user_id=?;"; if sqlite3_prepare_v2(impl.conn.db,cstring(raw_data(q)),-1,&stmt,nil)!=SQLITE_OK do return false,domain.domain_error(.Internal_Error,"failed artifact delete"); defer sqlite3_finalize(stmt); bind_text(stmt,1,id); bind_text(stmt,2,string(owner)); if sqlite3_step(stmt)!=SQLITE_DONE do return false,domain.domain_error(.Internal_Error,"artifact could not be deleted"); return true,{} }

content_save_template_sqlite :: proc(ctx:rawptr,t:domain.Template)->(domain.Template,bool,domain.Domain_Error){ impl:=(^Content_Repo_SQLite)(ctx); stmt:sqlite3_stmt=nil; q:="INSERT INTO templates (template_id, owner_user_id, is_system, name, description, persona, instructions, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(template_id) DO UPDATE SET name=excluded.name, description=excluded.description, persona=excluded.persona, instructions=excluded.instructions, updated_at=excluded.updated_at;"; if sqlite3_prepare_v2(impl.conn.db,cstring(raw_data(q)),-1,&stmt,nil)!=SQLITE_OK do return {},false,domain.domain_error(.Internal_Error,"failed template save"); defer sqlite3_finalize(stmt); bind_template(stmt,t); if sqlite3_step(stmt)!=SQLITE_DONE do return {},false,domain.domain_error(.Conflict,"template could not be saved"); return t,true,{} }
content_get_template_sqlite :: proc(ctx:rawptr,id:string)->(domain.Template,bool,domain.Domain_Error){ impl:=(^Content_Repo_SQLite)(ctx); stmt:sqlite3_stmt=nil; q:="SELECT template_id, owner_user_id, is_system, name, description, persona, instructions, created_at, updated_at FROM templates WHERE template_id=?;"; if sqlite3_prepare_v2(impl.conn.db,cstring(raw_data(q)),-1,&stmt,nil)!=SQLITE_OK do return {},false,domain.domain_error(.Internal_Error,"failed template lookup"); defer sqlite3_finalize(stmt); bind_text(stmt,1,id); if sqlite3_step(stmt)!=SQLITE_ROW do return {},false,domain.domain_error(.Not_Found,"template not found"); return template_from_stmt(stmt),true,{} }
content_list_templates_sqlite :: proc(ctx:rawptr, owner:domain.User_ID)->([]domain.Template,domain.Domain_Error){ impl:=(^Content_Repo_SQLite)(ctx); stmt:sqlite3_stmt=nil; q:="SELECT template_id, owner_user_id, is_system, name, description, persona, instructions, created_at, updated_at FROM templates WHERE owner_user_id=? OR is_system='1' ORDER BY is_system DESC, name ASC;"; if sqlite3_prepare_v2(impl.conn.db,cstring(raw_data(q)),-1,&stmt,nil)!=SQLITE_OK do return nil,domain.domain_error(.Internal_Error,"failed template list"); defer sqlite3_finalize(stmt); bind_text(stmt,1,string(owner)); out:=make([dynamic]domain.Template); for sqlite3_step(stmt)==SQLITE_ROW do append(&out,template_from_stmt(stmt)); return out[:],{} }
content_delete_template_sqlite :: proc(ctx:rawptr,id:string,owner:domain.User_ID)->(bool,domain.Domain_Error){ impl:=(^Content_Repo_SQLite)(ctx); stmt:sqlite3_stmt=nil; q:="DELETE FROM templates WHERE template_id=? AND owner_user_id=? AND is_system='0';"; if sqlite3_prepare_v2(impl.conn.db,cstring(raw_data(q)),-1,&stmt,nil)!=SQLITE_OK do return false,domain.domain_error(.Internal_Error,"failed template delete"); defer sqlite3_finalize(stmt); bind_text(stmt,1,id); bind_text(stmt,2,string(owner)); if sqlite3_step(stmt)!=SQLITE_DONE do return false,domain.domain_error(.Internal_Error,"template could not be deleted"); return true,{} }

bind_memory :: proc(s:sqlite3_stmt,m:domain.Memory){ bind_text(s,1,m.memory_id);bind_text(s,2,string(m.owner_user_id));bind_text(s,3,memory_id_list_to_json(m.agent_ids));bind_text(s,4,memory_project_list_to_json(m.project_ids));bind_text(s,5,memory_id_list_to_json(m.template_ids));bind_text(s,6,memory_id_list_to_json(m.bridge_ids));bind_text(s,7,domain.memory_type_string(m.type));bind_text(s,8,m.status);bind_text(s,9,m.title);bind_text(s,10,m.description);bind_text(s,11,m.body);bind_text(s,12,m.evidence);bind_text(s,13,m.expires_at);bind_text(s,14,m.created_at);bind_text(s,15,m.updated_at);bind_text(s,16,m.proposed_by_instance_id);bind_text(s,17,m.proposed_in_chain_id) }
memory_from_stmt :: proc(s:sqlite3_stmt)->domain.Memory { return domain.Memory{memory_id=column_text(s,0),owner_user_id=domain.User_ID(column_text(s,1)),agent_ids=memory_json_to_id_list(column_text(s,2)),project_ids=memory_json_to_project_list(column_text(s,3)),template_ids=memory_json_to_id_list(column_text(s,4)),bridge_ids=memory_json_to_id_list(column_text(s,5)),type=domain.memory_type_from_string(column_text(s,6)),status=column_text(s,7),title=column_text(s,8),description=column_text(s,9),body=column_text(s,10),evidence=column_text(s,11),expires_at=column_text(s,12),created_at=column_text(s,13),updated_at=column_text(s,14),proposed_by_instance_id=column_text(s,15),proposed_in_chain_id=column_text(s,16)} }

// memory_id_list_to_json encodes a targeting list as a JSON string array for
// storage. An empty/nil list is stored as "[]" (meaning "applies to all").
memory_id_list_to_json :: proc(values: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for v, i in values {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_byte(&b, '"')
		contracts.write_json_string(&b, v)
		strings.write_byte(&b, '"')
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}
memory_project_list_to_json :: proc(values: []domain.Project_ID) -> string {
	tmp := make([]string, len(values)); defer delete(tmp)
	for v, i in values do tmp[i] = string(v)
	return memory_id_list_to_json(tmp)
}
// memory_json_to_id_list decodes a stored JSON string array back into a slice.
memory_json_to_id_list :: proc(text: string) -> []string {
	return decode_json_string_array(text)
}
memory_json_to_project_list :: proc(text: string) -> []domain.Project_ID {
	ids := decode_json_string_array(text)
	out := make([]domain.Project_ID, len(ids))
	for id, i in ids do out[i] = domain.Project_ID(id)
	delete(ids)
	return out
}
// decode_json_string_array parses a flat JSON array of strings, e.g. ["a","b"].
decode_json_string_array :: proc(text: string, allocator := context.allocator) -> []string {
	dyn := jsonx.decode_string_array(text, allocator = allocator)
	return dyn[:]
}
bind_conversation :: proc(s:sqlite3_stmt,c:domain.Chat_Conversation){ bind_text(s,1,c.conversation_id);bind_text(s,2,string(c.owner_user_id));bind_text(s,3,c.agent_id);bind_text(s,4,c.agent_instance_id);bind_text(s,5,string(c.project_id));bind_text(s,6,c.chain_id);bind_text(s,7,c.title);bind_text(s,8,int_s(c.unread_count));bind_text(s,9,c.last_message_preview);bind_text(s,10,c.last_message_at);bind_text(s,11,c.created_at);bind_text(s,12,c.updated_at);bind_text(s,13,c.last_activity_at);bind_text(s,14,c.last_title_nudge_at);bind_text(s,15,normalize_title_source(c.title_source)) }
conversation_from_stmt :: proc(s:sqlite3_stmt)->domain.Chat_Conversation { return domain.Chat_Conversation{conversation_id=column_text(s,0),owner_user_id=domain.User_ID(column_text(s,1)),agent_id=column_text(s,2),agent_instance_id=column_text(s,3),project_id=domain.Project_ID(column_text(s,4)),chain_id=column_text(s,5),title=column_text(s,6),unread_count=int_v(column_text(s,7)),last_message_preview=column_text(s,8),last_message_at=column_text(s,9),created_at=column_text(s,10),updated_at=column_text(s,11),last_activity_at=column_text(s,12),last_title_nudge_at=column_text(s,13),title_source=normalize_title_source(column_text(s,14))} }
conversation_summary_from_stmt :: proc(s:sqlite3_stmt)->domain.Chat_Conversation {
	c := conversation_from_stmt(s)
	c.last_message_id=column_text(s,15)
	c.last_message_direction=column_text(s,16)
	c.last_message_sender_agent_id=column_text(s,17)
	c.last_message_sender_agent_instance_id=column_text(s,18)
	c.last_message_type=column_text(s,19)
	c.last_message_status=column_text(s,20)
	c.last_message_created_at=column_text(s,21)
	c.message_count=int_v(column_text(s,22))
	return c
}
normalize_title_source :: proc(s: string) -> string { switch s { case "agent", "user", "default": return s }; return "default" }
bind_message :: proc(s:sqlite3_stmt,m:domain.Chat_Message){ n:=normalize_message_defaults(m); bind_text(s,1,n.message_id);bind_text(s,2,n.conversation_id);bind_text(s,3,string(n.owner_user_id));bind_text(s,4,n.direction);bind_text(s,5,n.sender_agent_id);bind_text(s,6,n.sender_agent_instance_id);bind_text(s,7,n.body);bind_text(s,8,n.artifact_ids_json);bind_text(s,9,n.message_type);bind_text(s,10,n.message_status);bind_text(s,11,n.metadata_json);bind_text(s,12,n.created_at);bind_text(s,13,n.delivered_at);bind_text(s,14,n.read_at) }
message_from_stmt :: proc(s:sqlite3_stmt)->domain.Chat_Message { return normalize_message_defaults(domain.Chat_Message{message_id=column_text(s,0),conversation_id=column_text(s,1),owner_user_id=domain.User_ID(column_text(s,2)),direction=column_text(s,3),sender_agent_id=column_text(s,4),sender_agent_instance_id=column_text(s,5),body=column_text(s,6),artifact_ids_json=column_text(s,7),message_type=column_text(s,8),message_status=column_text(s,9),metadata_json=column_text(s,10),created_at=column_text(s,11),delivered_at=column_text(s,12),read_at=column_text(s,13)}) }
normalize_message_defaults :: proc(m:domain.Chat_Message)->domain.Chat_Message{ n:=m; if strings.trim_space(n.artifact_ids_json)=="" do n.artifact_ids_json="[]"; if strings.trim_space(n.message_type)=="" do n.message_type="text"; if strings.trim_space(n.message_status)=="" do n.message_status="complete"; if strings.trim_space(n.metadata_json)=="" do n.metadata_json="{}"; return n }
normalize_message_status :: proc(status:string)->string{ if strings.trim_space(status)=="" do return "complete"; return status }
json_object_or_empty :: proc(value:string)->string{ if strings.trim_space(value)=="" do return "{}"; return value }
bind_artifact :: proc(s:sqlite3_stmt,a:domain.Artifact){ bind_text(s,1,a.artifact_id);bind_text(s,2,string(a.owner_user_id));bind_text(s,3,a.kind);bind_text(s,4,a.name);bind_text(s,5,a.description);bind_text(s,6,a.content_type);bind_text(s,7,int_s(a.size_bytes));bind_text(s,8,a.blob_ref);bind_text(s,9,a.content);bind_text(s,10,a.agent_id);bind_text(s,11,a.agent_instance_id);bind_text(s,12,a.chain_id);bind_text(s,13,a.task_id);bind_text(s,14,string(a.project_id));bind_text(s,15,a.mime);bind_text(s,16,a.ext);bind_text(s,17,a.sha256);bind_text(s,18,a.origin_kind);bind_text(s,19,a.origin_ref);bind_text(s,20,a.deleted_at);bind_text(s,21,a.created_at);bind_text(s,22,a.updated_at) }
artifact_from_stmt :: proc(s:sqlite3_stmt)->domain.Artifact { return domain.Artifact{artifact_id=column_text(s,0),owner_user_id=domain.User_ID(column_text(s,1)),kind=column_text(s,2),name=column_text(s,3),description=column_text(s,4),content_type=column_text(s,5),size_bytes=int_v(column_text_unowned(s,6)),blob_ref=column_text(s,7),content=column_text(s,8),agent_id=column_text(s,9),agent_instance_id=column_text(s,10),chain_id=column_text(s,11),task_id=column_text(s,12),project_id=domain.Project_ID(column_text(s,13)),mime=column_text(s,14),ext=column_text(s,15),sha256=column_text(s,16),origin_kind=column_text(s,17),origin_ref=column_text(s,18),deleted_at=column_text(s,19),created_at=column_text(s,20),updated_at=column_text(s,21)} }
artifact_summary_from_stmt :: proc(s: sqlite3_stmt) -> domain.Artifact {
	return domain.Artifact{
		artifact_id       = column_text(s, 0),
		owner_user_id     = domain.User_ID(column_text(s, 1)),
		kind              = column_text(s, 2),
		name              = column_text(s, 3),
		description       = column_text(s, 4),
		content_type      = column_text(s, 5),
		size_bytes        = int_v(column_text_unowned(s, 6)),
		blob_ref          = column_text(s, 7),
		content           = "",
		agent_id          = column_text(s, 8),
		agent_instance_id = column_text(s, 9),
		chain_id          = column_text(s, 10),
		task_id           = column_text(s, 11),
		project_id        = domain.Project_ID(column_text(s, 12)),
		mime              = column_text(s, 13),
		ext               = column_text(s, 14),
		sha256            = column_text(s, 15),
		origin_kind       = column_text(s, 16),
		origin_ref        = column_text(s, 17),
		deleted_at        = column_text(s, 18),
		created_at        = column_text(s, 19),
		updated_at        = column_text(s, 20),
	}
}
bind_template :: proc(s:sqlite3_stmt,t:domain.Template){ bind_text(s,1,t.template_id);bind_text(s,2,string(t.owner_user_id));bind_text(s,3,"1" if t.is_system else "0");bind_text(s,4,t.name);bind_text(s,5,t.description);bind_text(s,6,t.persona);bind_text(s,7,t.instructions);bind_text(s,8,t.created_at);bind_text(s,9,t.updated_at) }
template_from_stmt :: proc(s:sqlite3_stmt)->domain.Template { return domain.Template{template_id=column_text(s,0),owner_user_id=domain.User_ID(column_text(s,1)),is_system=column_text(s,2)=="1",name=column_text(s,3),description=column_text(s,4),persona=column_text(s,5),instructions=column_text(s,6),created_at=column_text(s,7),updated_at=column_text(s,8)} }
int_s :: proc(v:int)->string { return fmt.tprintf("%d",v) }
int_v :: proc(v:string)->int { p,ok:=strconv.parse_int(v); if !ok do return 0; return int(p) }

content_list_unread_incoming_ids_sqlite :: proc(ctx: rawptr, cid: string, owner: domain.User_ID) -> ([]string, domain.Domain_Error) {
	impl := (^Content_Repo_SQLite)(ctx); stmt: sqlite3_stmt = nil
	q := "SELECT message_id FROM chat_messages WHERE owner_user_id = ? AND conversation_id = ? AND direction = 'agent_to_user' AND read_at = '' ORDER BY created_at ASC, message_id ASC;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed unread incoming list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner)); bind_text(stmt, 2, cid)
	out := make([dynamic]string)
	for sqlite3_step(stmt) == SQLITE_ROW do append(&out, column_text(stmt, 0))
	return out[:], {}
}

// Same owner, ordering expression, tie break and 200-row boundary as the full
// conversation listing; association needs no latest-message or count subqueries.
content_list_conversation_project_links_sqlite :: proc(ctx: rawptr, owner: domain.User_ID) -> ([]domain.Conversation_Project_Link, domain.Domain_Error) {
	impl := (^Content_Repo_SQLite)(ctx)
	stmt: sqlite3_stmt
	q := "SELECT c.conversation_id, c.agent_instance_id, c.project_id, c.chain_id FROM chat_conversations c WHERE c.owner_user_id=? ORDER BY COALESCE(NULLIF(c.last_message_at,''), c.updated_at, c.created_at) DESC, c.conversation_id DESC LIMIT 200;"
	if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed conversation project link list")
	defer sqlite3_finalize(stmt)
	bind_text(stmt, 1, string(owner))
	out := make([dynamic]domain.Conversation_Project_Link)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&out, domain.Conversation_Project_Link{
			conversation_id = column_text(stmt, 0),
			agent_instance_id = column_text(stmt, 1),
			project_id = domain.Project_ID(column_text(stmt, 2)),
			chain_id = column_text(stmt, 3),
		})
	}
	return out[:], {}
}
