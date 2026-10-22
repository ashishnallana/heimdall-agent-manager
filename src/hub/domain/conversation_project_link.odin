package domain

// Internal projection for chain/project association; deliberately excludes message
// summaries. Ordering and the bounded conversation window match list_conversations.
Conversation_Project_Link :: struct {
	conversation_id: string,
	agent_instance_id: string,
	project_id: Project_ID,
	chain_id: string,
}
