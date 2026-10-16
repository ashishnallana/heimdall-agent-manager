package http

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import card_service "odin_test:hub/service/card"

// Golden wire contract for the attention API, one item per provider. The UI
// builds on these exact shapes; ciphertext must pass through byte-for-byte.

@(test)
test_attention_item_json_task_golden :: proc(t: ^testing.T) {
	item := card_service.Attention_Item{
		card = domain.Card{
			card_id = "crd_task_task_1", kind = "task", provider = "task_validation", status = "pending",
			attention_since = "2026-10-01T02:00:00Z", title = "vault:v1:abc==", rationale = "Waiting on your review",
			operations_json = `[{"op":"task.vote","label":"Approve","args":{"task_id":"task_1","result":"lgtm"}}]`,
			details_json = `{"priority":"p1","status":"in_validation","bridge_id":"brg_1","assignee_name":"soloist #1","excerpt":null}`,
			action_refs_json = `{"chain_id":"chain_1","task_id":"task_1"}`,
		},
		reason = "awaiting_review", urgency = "warn", primary_op = "task.vote",
		ctx = card_service.Attention_Item_Context{chain_title = "vault:v1:chain==", agent_name = "soloist #1"},
	}
	b := strings.builder_make(context.temp_allocator)
	write_attention_item_json(&b, item)
	testing.expect_value(t, strings.to_string(b), `{"card_id":"crd_task_task_1","kind":"task","provider":"task_validation","reason":"awaiting_review","urgency":"warn","status":"pending","attention_since":"2026-10-01T02:00:00Z","title":"vault:v1:abc==","rationale":"Waiting on your review","primary_op":"task.vote","operations":[{"op":"task.vote","label":"Approve","args":{"task_id":"task_1","result":"lgtm"}}],"details":{"priority":"p1","status":"in_validation","bridge_id":"brg_1","assignee_name":"soloist #1","excerpt":null},"action_refs":{"chain_id":"chain_1","task_id":"task_1"},"context":{"chain_title":"vault:v1:chain==","agent_name":"soloist #1","project_name":""}}`)
}

@(test)
test_attention_item_json_message_golden :: proc(t: ^testing.T) {
	item := card_service.Attention_Item{
		card = domain.Card{
			card_id = "crd_msg_inst_1", kind = "message", provider = "message_options", status = "pending",
			attention_since = "2026-10-01T01:05:00Z", title = "vault:v1:q==", rationale = "Waiting on your reply",
			operations_json = "[]",
			details_json = `{"excerpt":{"author_name":"soloist #1","body":"vault:v1:q==","at":"2026-10-01T01:05:00Z"},"options":["Yes","No"],"other_unread":2}`,
			action_refs_json = `{"conversation_id":"chat_1","agent_instance_id":"inst_1","message_id":"msg_1"}`,
		},
		reason = "question", urgency = "info",
		ctx = card_service.Attention_Item_Context{chain_title = "", agent_name = "soloist #1"},
	}
	b := strings.builder_make(context.temp_allocator)
	write_attention_item_json(&b, item)
	testing.expect_value(t, strings.to_string(b), `{"card_id":"crd_msg_inst_1","kind":"message","provider":"message_options","reason":"question","urgency":"info","status":"pending","attention_since":"2026-10-01T01:05:00Z","title":"vault:v1:q==","rationale":"Waiting on your reply","primary_op":null,"operations":[],"details":{"excerpt":{"author_name":"soloist #1","body":"vault:v1:q==","at":"2026-10-01T01:05:00Z"},"options":["Yes","No"],"other_unread":2},"action_refs":{"conversation_id":"chat_1","agent_instance_id":"inst_1","message_id":"msg_1"},"context":{"chain_title":"","agent_name":"soloist #1","project_name":""}}`)
}

@(test)
test_attention_counts_json_golden :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	write_attention_counts_json(&b, iface.Attention_Counts{message = 1, task = 2, older = 4})
	testing.expect_value(t, strings.to_string(b), `{"total":3,"older":4,"message":1,"task":2}`)
}
