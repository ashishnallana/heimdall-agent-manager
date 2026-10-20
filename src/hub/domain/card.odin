package domain

CARD_STATUS_PENDING   :: "pending"
CARD_STATUS_ACCEPTED  :: "accepted"
CARD_STATUS_REJECTED  :: "rejected"
CARD_STATUS_SNOOZED   :: "snoozed"
CARD_STATUS_DISCARDED :: "discarded"
// CARD_STATUS_RESOLVED: retired by the system because its source no longer needs
// the user (the task left review, the message was read, ...). Distinct from the
// user's own discard/reject so analytics and precedence can tell them apart.
CARD_STATUS_RESOLVED  :: "resolved"

CARD_SCOPE_MEMORY  :: "memory"
CARD_SCOPE_PROJECT :: "project"
CARD_SCOPE_AGENT   :: "agent"
CARD_SCOPE_TASK    :: "task"

CARD_PROVIDER_TASK_VALIDATION :: "task_validation"
CARD_PROVIDER_MEMORY_PROPOSAL :: "memory_proposal"
CARD_PROVIDER_CURATOR_LLM     :: "curator_llm"
// CARD_PROVIDER_MESSAGE_OPTIONS: the latest unread agent message that offers
// reply options, one card per agent instance.
CARD_PROVIDER_MESSAGE_OPTIONS :: "message_options"

// Canonical attention kinds. Every card maps to exactly one kind, so the deck
// never double counts. The attention deck v1 serves message and task only;
// memory and approval exist so every stored card still has a kind.
CARD_KIND_MESSAGE  :: "message"
CARD_KIND_TASK     :: "task"
CARD_KIND_APPROVAL :: "approval"
CARD_KIND_MEMORY   :: "memory"

// card_kind_for_provider is the single provider -> kind mapping. Any provider
// that is not source-backed (curator, agent-created, ...) is a generic approval.
card_kind_for_provider :: proc(provider: string) -> string {
	switch provider {
	case CARD_PROVIDER_TASK_VALIDATION: return CARD_KIND_TASK
	case CARD_PROVIDER_MEMORY_PROPOSAL: return CARD_KIND_MEMORY
	case CARD_PROVIDER_MESSAGE_OPTIONS: return CARD_KIND_MESSAGE
	}
	return CARD_KIND_APPROVAL
}

Card :: struct {
	card_id:          Card_ID,
	owner_user_id:    User_ID,
	project_id:       Project_ID,
	title:            string,
	rationale:        string,
	scope:            string,
	provider:         string,
	confidence:       f32,
	source_refs_json: string,
	status:           string,
	operations_json:  string,
	guard_json:       string,
	snooze_until:     string,
	ttl_at:           string,
	created_at:       string,
	updated_at:       string,
	// Attention fields (migration 087).
	kind:             string,
	attention_since:  string,
	source_marker:    string,
	details_json:     string,
	action_refs_json: string,
}
