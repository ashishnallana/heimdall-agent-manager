package contracts

// Attention_Notifier lets a source service (taskchain, content) tell the card
// projector that an attention source changed, without importing the card
// package: card already imports those services, so a direct call back would be
// an import cycle. The app composition root injects the projector here.
//
// notify is fire-and-forget and is called AFTER the source write committed. It
// carries only identifiers; the projector re-reads the current source state
// itself, so a late or out-of-order notification can never project stale data.
// A missed notification is repaired by the projector's periodic reconciliation.
Attention_Notifier :: struct {
	ctx:    rawptr,
	notify: proc(ctx: rawptr, owner_user_id: string, source_kind: string, source_id: string),
}

// Attention source kinds a service can report.
ATTENTION_SOURCE_TASK          :: "task"          // source_id = task_id
ATTENTION_SOURCE_AGENT_MESSAGE :: "agent_message" // source_id = agent_instance_id (the sender)
ATTENTION_SOURCE_MEMORY        :: "memory"        // source_id = memory_id

// attention_notify is nil-safe so services built without a notifier (most
// unit tests) need no special casing.
attention_notify :: proc(n: ^Attention_Notifier, owner_user_id, source_kind, source_id: string) {
	if n == nil || n.notify == nil || owner_user_id == "" || source_id == "" do return
	n.notify(n.ctx, owner_user_id, source_kind, source_id)
}
