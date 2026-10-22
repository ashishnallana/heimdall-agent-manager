package iface

import domain "odin_test:hub/domain"

Content_Save_Memory_Proc :: proc(ctx: rawptr, m: domain.Memory) -> (domain.Memory, bool, domain.Domain_Error)
Content_Get_Memory_Proc :: proc(ctx: rawptr, memory_id: string) -> (domain.Memory, bool, domain.Domain_Error)
Content_List_Memories_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Memory, domain.Domain_Error)
Content_Save_Conversation_Proc :: proc(ctx: rawptr, c: domain.Chat_Conversation) -> (domain.Chat_Conversation, bool, domain.Domain_Error)
Content_Get_Conversation_Proc :: proc(ctx: rawptr, conversation_id: string) -> (domain.Chat_Conversation, bool, domain.Domain_Error)
Content_List_Conversations_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID, limit: int, cursor: string) -> ([]domain.Chat_Conversation, domain.Domain_Error)
Content_Save_Message_Proc :: proc(ctx: rawptr, m: domain.Chat_Message) -> (domain.Chat_Message, bool, domain.Domain_Error)
Content_Get_Message_Proc :: proc(ctx: rawptr, message_id: string) -> (domain.Chat_Message, bool, domain.Domain_Error)
Content_Update_Message_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID, conversation_id, message_id, body, message_status, metadata_json: string) -> (domain.Chat_Message, bool, domain.Domain_Error)
Content_List_Messages_Proc :: proc(ctx: rawptr, conversation_id: string, owner_user_id: domain.User_ID, limit: int, cursor: string) -> ([]domain.Chat_Message, domain.Domain_Error)
Content_List_User_Visible_Messages_Proc :: proc(ctx: rawptr, conversation_id: string, owner_user_id: domain.User_ID, limit: int, cursor: string) -> ([]domain.Chat_Message, domain.Domain_Error)
Content_List_Agent_Inbox_Messages_Proc :: proc(ctx: rawptr, conversation_id: string, owner_user_id: domain.User_ID, agent_instance_id: string, unread_only: bool, receiver_only: bool, include_outgoing: bool, include_debug: bool, limit: int, cursor: string) -> ([]domain.Chat_Message, domain.Domain_Error)
Content_Mark_Messages_Read_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID, message_ids: []string, updated_at: string) -> (int, domain.Domain_Error)
// Content_List_Unread_Incoming_IDs_Proc returns the ids of EVERY unread
// agent_to_user message in a conversation (no page cap), for mark-read.
Content_List_Unread_Incoming_IDs_Proc :: proc(ctx: rawptr, conversation_id: string, owner_user_id: domain.User_ID) -> ([]string, domain.Domain_Error)
Content_Save_Artifact_Proc :: proc(ctx: rawptr, a: domain.Artifact) -> (domain.Artifact, bool, domain.Domain_Error)
Content_Get_Artifact_Proc :: proc(ctx: rawptr, artifact_id: string) -> (domain.Artifact, bool, domain.Domain_Error)
Content_List_Artifacts_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID, filter: domain.Artifact_List_Filter) -> ([]domain.Artifact, domain.Domain_Error)
Content_Delete_Artifact_Proc :: proc(ctx: rawptr, artifact_id: string, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error)
Content_Save_Template_Proc :: proc(ctx: rawptr, t: domain.Template) -> (domain.Template, bool, domain.Domain_Error)
Content_Get_Template_Proc :: proc(ctx: rawptr, template_id: string) -> (domain.Template, bool, domain.Domain_Error)
Content_List_Templates_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Template, domain.Domain_Error)
Content_Delete_Template_Proc :: proc(ctx: rawptr, template_id: string, owner_user_id: domain.User_ID) -> (bool, domain.Domain_Error)

Content_List_Conversation_Project_Links_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Conversation_Project_Link, domain.Domain_Error)

Content_Repository :: struct {
	ctx: rawptr,
	save_memory: Content_Save_Memory_Proc,
	get_memory: Content_Get_Memory_Proc,
	list_memories: Content_List_Memories_Proc,
	save_conversation: Content_Save_Conversation_Proc,
	get_conversation: Content_Get_Conversation_Proc,
	list_conversations: Content_List_Conversations_Proc,
	list_conversation_project_links: Content_List_Conversation_Project_Links_Proc,
	save_message: Content_Save_Message_Proc,
	get_message: Content_Get_Message_Proc,
	update_message: Content_Update_Message_Proc,
	list_messages: Content_List_Messages_Proc,
	list_user_visible_messages: Content_List_User_Visible_Messages_Proc,
	list_agent_inbox_messages: Content_List_Agent_Inbox_Messages_Proc,
	mark_messages_read: Content_Mark_Messages_Read_Proc,
	save_artifact: Content_Save_Artifact_Proc,
	get_artifact: Content_Get_Artifact_Proc,
	list_artifacts: Content_List_Artifacts_Proc,
	delete_artifact: Content_Delete_Artifact_Proc,
	save_template: Content_Save_Template_Proc,
	get_template: Content_Get_Template_Proc,
	list_templates: Content_List_Templates_Proc,
	delete_template: Content_Delete_Template_Proc,
	list_unread_incoming_ids: Content_List_Unread_Incoming_IDs_Proc,
}

content_save_memory :: proc(r: ^Content_Repository, m: domain.Memory) -> (domain.Memory, bool, domain.Domain_Error) { if r == nil || r.save_memory == nil do return {}, false, domain.domain_error(.Internal_Error, "content repository is not configured"); return r.save_memory(r.ctx, m) }
content_get_memory :: proc(r: ^Content_Repository, id: string) -> (domain.Memory, bool, domain.Domain_Error) { if r == nil || r.get_memory == nil do return {}, false, domain.domain_error(.Internal_Error, "content repository is not configured"); return r.get_memory(r.ctx, id) }
content_list_memories :: proc(r: ^Content_Repository, owner: domain.User_ID) -> ([]domain.Memory, domain.Domain_Error) { if r == nil || r.list_memories == nil do return nil, domain.domain_error(.Internal_Error, "content repository is not configured"); return r.list_memories(r.ctx, owner) }
content_save_conversation :: proc(r: ^Content_Repository, c: domain.Chat_Conversation) -> (domain.Chat_Conversation, bool, domain.Domain_Error) { if r == nil || r.save_conversation == nil do return {}, false, domain.domain_error(.Internal_Error, "content repository is not configured"); return r.save_conversation(r.ctx, c) }
content_get_conversation :: proc(r: ^Content_Repository, id: string) -> (domain.Chat_Conversation, bool, domain.Domain_Error) { if r == nil || r.get_conversation == nil do return {}, false, domain.domain_error(.Internal_Error, "content repository is not configured"); return r.get_conversation(r.ctx, id) }
content_list_conversations :: proc(r: ^Content_Repository, owner: domain.User_ID, limit: int, cursor: string) -> ([]domain.Chat_Conversation, domain.Domain_Error) { if r == nil || r.list_conversations == nil do return nil, domain.domain_error(.Internal_Error, "content repository is not configured"); return r.list_conversations(r.ctx, owner, limit, cursor) }
content_save_message :: proc(r: ^Content_Repository, m: domain.Chat_Message) -> (domain.Chat_Message, bool, domain.Domain_Error) { if r == nil || r.save_message == nil do return {}, false, domain.domain_error(.Internal_Error, "content repository is not configured"); return r.save_message(r.ctx, m) }
content_get_message :: proc(r: ^Content_Repository, id: string) -> (domain.Chat_Message, bool, domain.Domain_Error) { if r == nil || r.get_message == nil do return {}, false, domain.domain_error(.Internal_Error, "content repository is not configured"); return r.get_message(r.ctx, id) }
content_update_message :: proc(r: ^Content_Repository, owner: domain.User_ID, cid, id, body, status, metadata_json: string) -> (domain.Chat_Message, bool, domain.Domain_Error) { if r == nil || r.update_message == nil do return {}, false, domain.domain_error(.Internal_Error, "content repository is not configured"); return r.update_message(r.ctx, owner, cid, id, body, status, metadata_json) }
content_list_messages :: proc(r: ^Content_Repository, id: string, owner: domain.User_ID, limit: int, cursor: string) -> ([]domain.Chat_Message, domain.Domain_Error) { if r == nil || r.list_messages == nil do return nil, domain.domain_error(.Internal_Error, "content repository is not configured"); return r.list_messages(r.ctx, id, owner, limit, cursor) }
content_list_user_visible_messages :: proc(r: ^Content_Repository, id: string, owner: domain.User_ID, limit: int, cursor: string) -> ([]domain.Chat_Message, domain.Domain_Error) { if r == nil do return nil, domain.domain_error(.Internal_Error, "content repository is not configured"); if r.list_user_visible_messages != nil do return r.list_user_visible_messages(r.ctx, id, owner, limit, cursor); if r.list_messages == nil do return nil, domain.domain_error(.Internal_Error, "content repository is not configured"); return r.list_messages(r.ctx, id, owner, limit, cursor) }
content_list_agent_inbox_messages :: proc(r: ^Content_Repository, id: string, owner: domain.User_ID, agent_instance_id: string, unread_only, receiver_only, include_outgoing, include_debug: bool, limit: int, cursor: string) -> ([]domain.Chat_Message, domain.Domain_Error) { if r == nil || r.list_agent_inbox_messages == nil do return nil, domain.domain_error(.Internal_Error, "content repository is not configured"); return r.list_agent_inbox_messages(r.ctx, id, owner, agent_instance_id, unread_only, receiver_only, include_outgoing, include_debug, limit, cursor) }
content_mark_messages_read :: proc(r: ^Content_Repository, owner: domain.User_ID, message_ids: []string, updated_at: string) -> (int, domain.Domain_Error) { if r == nil || r.mark_messages_read == nil do return 0, domain.domain_error(.Internal_Error, "content repository is not configured"); return r.mark_messages_read(r.ctx, owner, message_ids, updated_at) }
content_save_artifact :: proc(r: ^Content_Repository, a: domain.Artifact) -> (domain.Artifact, bool, domain.Domain_Error) { if r == nil || r.save_artifact == nil do return {}, false, domain.domain_error(.Internal_Error, "content repository is not configured"); return r.save_artifact(r.ctx, a) }
content_get_artifact :: proc(r: ^Content_Repository, id: string) -> (domain.Artifact, bool, domain.Domain_Error) { if r == nil || r.get_artifact == nil do return {}, false, domain.domain_error(.Internal_Error, "content repository is not configured"); return r.get_artifact(r.ctx, id) }
content_list_artifacts :: proc(r: ^Content_Repository, owner: domain.User_ID, filter: domain.Artifact_List_Filter) -> ([]domain.Artifact, domain.Domain_Error) { if r == nil || r.list_artifacts == nil do return nil, domain.domain_error(.Internal_Error, "content repository is not configured"); return r.list_artifacts(r.ctx, owner, filter) }
content_delete_artifact :: proc(r: ^Content_Repository, id: string, owner: domain.User_ID) -> (bool, domain.Domain_Error) { if r == nil || r.delete_artifact == nil do return false, domain.domain_error(.Internal_Error, "content repository is not configured"); return r.delete_artifact(r.ctx, id, owner) }
content_save_template :: proc(r: ^Content_Repository, t: domain.Template) -> (domain.Template, bool, domain.Domain_Error) { if r == nil || r.save_template == nil do return {}, false, domain.domain_error(.Internal_Error, "content repository is not configured"); return r.save_template(r.ctx, t) }
content_get_template :: proc(r: ^Content_Repository, id: string) -> (domain.Template, bool, domain.Domain_Error) { if r == nil || r.get_template == nil do return {}, false, domain.domain_error(.Internal_Error, "content repository is not configured"); return r.get_template(r.ctx, id) }
content_list_templates :: proc(r: ^Content_Repository, owner: domain.User_ID) -> ([]domain.Template, domain.Domain_Error) { if r == nil || r.list_templates == nil do return nil, domain.domain_error(.Internal_Error, "content repository is not configured"); return r.list_templates(r.ctx, owner) }
content_delete_template :: proc(r: ^Content_Repository, id: string, owner: domain.User_ID) -> (bool, domain.Domain_Error) { if r == nil || r.delete_template == nil do return false, domain.domain_error(.Internal_Error, "content repository is not configured"); return r.delete_template(r.ctx, id, owner) }

// content_list_unread_incoming_ids: supported=false when the repository does
// not implement it (callers then fall back to their paged scan).
content_list_unread_incoming_ids :: proc(r: ^Content_Repository, conversation_id: string, owner: domain.User_ID) -> (ids: []string, supported: bool, err: domain.Domain_Error) {
	if r == nil || r.list_unread_incoming_ids == nil do return nil, false, domain.Domain_Error{}
	ids, err = r.list_unread_incoming_ids(r.ctx, conversation_id, owner)
	return ids, true, err
}

// The fallback preserves compatibility with alternate/test repositories.
content_list_conversation_project_links :: proc(r: ^Content_Repository, owner: domain.User_ID) -> ([]domain.Conversation_Project_Link, domain.Domain_Error) {
	if r != nil && r.list_conversation_project_links != nil do return r.list_conversation_project_links(r.ctx, owner)
	rows, err := content_list_conversations(r, owner, 200, "")
	if err.code != .None do return nil, err
	defer delete(rows)
	links := make([dynamic]domain.Conversation_Project_Link)
	for c in rows do append(&links, domain.Conversation_Project_Link{conversation_id=c.conversation_id, agent_instance_id=c.agent_instance_id, project_id=c.project_id, chain_id=c.chain_id})
	return links[:], {}
}
