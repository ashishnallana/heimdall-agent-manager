package domain

import "core:strings"

Memory_Type :: enum {
	Unknown,
	Fact,
	Habit,
	Episode,
	Expertise,
	Skill,
}

memory_type_from_string :: proc(value: string) -> Memory_Type {
	switch strings.to_lower(strings.trim_space(value)) {
	case "fact", "":
		return .Fact
	case "habit":
		return .Habit
	case "episode":
		return .Episode
	case "expertise":
		return .Expertise
	case "skill":
		return .Skill
	}
	return .Unknown
}

memory_type_string :: proc(t: Memory_Type) -> string {
	switch t {
	case .Unknown:
		return "unknown"
	case .Fact:
		return "fact"
	case .Habit:
		return "habit"
	case .Episode:
		return "episode"
	case .Expertise:
		return "expertise"
	case .Skill:
		return "skill"
	}
	return "unknown"
}

Memory :: struct {
	memory_id: string,
	owner_user_id: User_ID,
	// Targeting is a LIST per dimension. An empty list means "applies to all"
	// for that dimension; a non-empty list means the instance/agent value must
	// be a member. The dimensions are ANDed together (every non-empty list must
	// match) so a memory can be scoped to, e.g., a set of agents on a set of
	// projects. Persisted as JSON-array TEXT columns (see migration 025).
	agent_ids: []string,
	project_ids: []Project_ID,
	template_ids: []string,
	bridge_ids: []string,
	type: Memory_Type,
	status: string,
	title: string,
	description: string,
	body: string,
	evidence: string,
	expires_at: string,
	created_at: string,
	updated_at: string,
}

// CONVERSATION_TITLE_MAX_BYTES bounds the PLAINTEXT conversation title
// (REQ-VCAP-1); an encrypted title is checked against the inflated armored
// budget instead — see domain.validate_capped_text in vault_text_caps.odin.
CONVERSATION_TITLE_MAX_BYTES :: 120

Chat_Conversation :: struct {
	conversation_id: string,
	owner_user_id: User_ID,
	agent_id: string,
	agent_instance_id: string,
	project_id: Project_ID,
	chain_id: string,
	title: string,
	unread_count: int,
	last_message_preview: string,
	last_message_at: string,
	// Additive summary-only fields populated by conversation list queries. They
	// support standard chat-list APIs without changing the persisted conversation
	// table or forcing the UI to fetch every message thread for inbox rows.
	last_message_id: string,
	last_message_direction: string,
	last_message_sender_agent_id: string,
	last_message_sender_agent_instance_id: string,
	last_message_type: string,
	last_message_status: string,
	last_message_created_at: string,
	// Total user-visible messages in the conversation (direction != agent_to_agent).
	// Summary-only, populated by conversation list queries.
	message_count: int,
	// Title-nudge tracking fields (persisted). last_activity_at tracks the most
	// recent meaningful agent/user activity on the conversation; last_title_nudge_at
	// records when the auto-title nudge was last delivered; title_source records how
	// the current title was set: "default" (auto), "agent" (agent set-title), or
	// "user" (user override, which wins and stops nudges forever).
	last_activity_at: string,
	last_title_nudge_at: string,
	title_source: string,
	created_at: string,
	updated_at: string,
}

Chat_Message :: struct {
	message_id: string,
	conversation_id: string,
	owner_user_id: User_ID,
	direction: string,
	sender_agent_id: string,
	sender_agent_instance_id: string,
	body: string,
	artifact_ids_json: string,
	message_type: string,
	message_status: string,
	metadata_json: string,
	created_at: string,
	delivered_at: string,
	read_at: string,
}

Artifact :: struct {
	artifact_id: string,
	owner_user_id: User_ID,
	kind: string,
	name: string,
	description: string,
	content_type: string,
	size_bytes: int,
	blob_ref: string,
	content: string,
	mime: string,
	ext: string,
	sha256: string,
	origin_kind: string,
	origin_ref: string,
	deleted_at: string,
	agent_id: string,
	agent_instance_id: string,
	chain_id: string,
	task_id: string,
	project_id: Project_ID,
	created_at: string,
	updated_at: string,
}

artifact_destroy :: proc(a: ^Artifact) {
	if a == nil do return
	if len(a.artifact_id) > 0 do delete(a.artifact_id)
	if len(string(a.owner_user_id)) > 0 do delete(string(a.owner_user_id))
	if len(a.kind) > 0 do delete(a.kind)
	if len(a.name) > 0 do delete(a.name)
	if len(a.description) > 0 do delete(a.description)
	if len(a.content_type) > 0 do delete(a.content_type)
	if len(a.blob_ref) > 0 do delete(a.blob_ref)
	if len(a.content) > 0 do delete(a.content)
	if len(a.mime) > 0 do delete(a.mime)
	if len(a.ext) > 0 do delete(a.ext)
	if len(a.sha256) > 0 do delete(a.sha256)
	if len(a.origin_kind) > 0 do delete(a.origin_kind)
	if len(a.origin_ref) > 0 do delete(a.origin_ref)
	if len(a.deleted_at) > 0 do delete(a.deleted_at)
	if len(a.agent_id) > 0 do delete(a.agent_id)
	if len(a.agent_instance_id) > 0 do delete(a.agent_instance_id)
	if len(a.chain_id) > 0 do delete(a.chain_id)
	if len(a.task_id) > 0 do delete(a.task_id)
	if len(string(a.project_id)) > 0 do delete(string(a.project_id))
	if len(a.created_at) > 0 do delete(a.created_at)
	if len(a.updated_at) > 0 do delete(a.updated_at)
	a^ = {}
}

artifacts_destroy :: proc(artifacts: []Artifact) {
	for &a in artifacts {
		artifact_destroy(&a)
	}
	delete(artifacts)
}

Artifact_List_Filter :: struct {
	project_id:        Project_ID,
	agent_instance_id: string,
	agent_id:          string,
	chain_id:          string,
	task_id:           string,
	kind:              string,
	since:             string,
	until:             string,
	include_deleted:   bool,
	sort_field:        string,
	sort_order:        string,
	limit:             int,
	cursor:            string,
}

// Built-in AI-native system template IDs. Defined in the domain layer so the
// content and agent services share a single source of truth for these identifiers.
TEMPLATE_COORDINATOR_ID :: "tmpl_coordinator"
TEMPLATE_WORKER_ID :: "tmpl_worker"
TEMPLATE_REVIEWER_ID :: "tmpl_reviewer"
TEMPLATE_SOLOIST_ID :: "tmpl_soloist"
TEMPLATE_EMPTY_ID :: "tmpl_empty"
TEMPLATE_CURATOR_ID :: "tmpl_curator"
TEMPLATE_CURATOR :: TEMPLATE_CURATOR_ID

Template :: struct {
	template_id: string,
	owner_user_id: User_ID,
	is_system: bool,
	name: string,
	description: string,
	persona: string,
	instructions: string,
	created_at: string,
	updated_at: string,
}
