package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

Legacy_Inbox_Message_Wire :: struct {
	id:                     string `json:"id"`,
	from_agent_instance_id: string `json:"from_agent_instance_id"`,
	body:                   string `json:"body"`,
}

Legacy_Inbox_Envelope_Wire :: struct {
	messages: []Legacy_Inbox_Message_Wire `json:"messages"`,
	data: struct {
		messages: []Legacy_Inbox_Message_Wire `json:"messages"`,
	} `json:"data"`,
}

parse_legacy_inbox_messages :: proc(body: string, allocator := context.temp_allocator) -> []Legacy_Inbox_Message_Wire {
	if len(body) == 0 do return nil
	envelope: Legacy_Inbox_Envelope_Wire
	if err := json.unmarshal_string(body, &envelope, json.DEFAULT_SPECIFICATION, allocator); err == nil {
		if len(envelope.messages) > 0 {
			return envelope.messages
		}
		if len(envelope.data.messages) > 0 {
			return envelope.data.messages
		}
	}
	direct_msgs: []Legacy_Inbox_Message_Wire
	if err := json.unmarshal_string(body, &direct_msgs, json.DEFAULT_SPECIFICATION, allocator); err == nil {
		return direct_msgs
	}
	return nil
}

format_legacy_inbox_human :: proc(body: string, allocator := context.temp_allocator) -> string {
	messages := parse_legacy_inbox_messages(body, allocator)
	if len(messages) == 0 {
		return "No unread messages."
	}
	b := strings.builder_make(allocator)
	for msg, idx in messages {
		if idx > 0 do strings.write_string(&b, "\n")
		strings.write_string(&b, fmt.tprintf("%s from %s:\n%s", msg.id, msg.from_agent_instance_id, msg.body))
	}
	return strings.to_string(b)
}

@(test)
test_legacy_inbox_single_message :: proc(t: ^testing.T) {
	raw := `{"ok":true,"messages":[{"id":"msg_101","from_agent_instance_id":"inst_coord","body":"Hello worker, start task."}]}`
	msgs := parse_legacy_inbox_messages(raw, context.temp_allocator)
	testing.expect_value(t, len(msgs), 1)
	testing.expect_value(t, msgs[0].id, "msg_101")
	testing.expect_value(t, msgs[0].from_agent_instance_id, "inst_coord")
	testing.expect_value(t, msgs[0].body, "Hello worker, start task.")

	formatted := format_legacy_inbox_human(raw, context.temp_allocator)
	expected := "msg_101 from inst_coord:\nHello worker, start task."
	testing.expect_value(t, formatted, expected)
}

@(test)
test_legacy_inbox_multiple_messages :: proc(t: ^testing.T) {
	raw := `{"messages":[{"id":"msg_1","from_agent_instance_id":"inst_a","body":"First message"},{"id":"msg_2","from_agent_instance_id":"inst_b","body":"Second message"},{"id":"msg_3","from_agent_instance_id":"inst_c","body":"Third message"}]}`
	msgs := parse_legacy_inbox_messages(raw, context.temp_allocator)
	testing.expect_value(t, len(msgs), 3)

	testing.expect_value(t, msgs[0].id, "msg_1")
	testing.expect_value(t, msgs[0].from_agent_instance_id, "inst_a")
	testing.expect_value(t, msgs[0].body, "First message")

	testing.expect_value(t, msgs[1].id, "msg_2")
	testing.expect_value(t, msgs[1].from_agent_instance_id, "inst_b")
	testing.expect_value(t, msgs[1].body, "Second message")

	testing.expect_value(t, msgs[2].id, "msg_3")
	testing.expect_value(t, msgs[2].from_agent_instance_id, "inst_c")
	testing.expect_value(t, msgs[2].body, "Third message")
}

@(test)
test_legacy_inbox_nested_data_envelope :: proc(t: ^testing.T) {
	raw := `{"v":1,"ok":true,"data":{"messages":[{"id":"msg_data_1","from_agent_instance_id":"inst_coordinator","body":"Payload inside data.messages"}]}}`
	msgs := parse_legacy_inbox_messages(raw, context.temp_allocator)
	testing.expect_value(t, len(msgs), 1)
	testing.expect_value(t, msgs[0].id, "msg_data_1")
	testing.expect_value(t, msgs[0].from_agent_instance_id, "inst_coordinator")
	testing.expect_value(t, msgs[0].body, "Payload inside data.messages")
}

@(test)
test_legacy_inbox_direct_array :: proc(t: ^testing.T) {
	raw := `[{"id":"msg_arr","from_agent_instance_id":"inst_arr","body":"Direct array payload"}]`
	msgs := parse_legacy_inbox_messages(raw, context.temp_allocator)
	testing.expect_value(t, len(msgs), 1)
	testing.expect_value(t, msgs[0].id, "msg_arr")
	testing.expect_value(t, msgs[0].from_agent_instance_id, "inst_arr")
	testing.expect_value(t, msgs[0].body, "Direct array payload")
}

@(test)
test_legacy_inbox_braces_in_message_body :: proc(t: ^testing.T) {
	// Braces inside the body caused the legacy parser's `strings.index(body[start:], "}")` to cut off prematurely.
	raw := `{"messages":[{"id":"msg_nested_json","from_agent_instance_id":"inst_subagent","body":"{\"action\":\"run\",\"nested\":{\"key\":\"value\"},\"closing\":\"}\"}"}]}`
	msgs := parse_legacy_inbox_messages(raw, context.temp_allocator)
	testing.expect_value(t, len(msgs), 1)
	testing.expect_value(t, msgs[0].id, "msg_nested_json")
	testing.expect_value(t, msgs[0].from_agent_instance_id, "inst_subagent")
	expected_body := `{"action":"run","nested":{"key":"value"},"closing":"}"}`
	testing.expect_value(t, msgs[0].body, expected_body)
}

@(test)
test_legacy_inbox_quotes_and_special_chars :: proc(t: ^testing.T) {
	raw := `{"messages":[{"id":"msg_quotes","from_agent_instance_id":"inst_reporter","body":"Message with \"quotes\", backslash \\, and \nnewline."}]}`
	msgs := parse_legacy_inbox_messages(raw, context.temp_allocator)
	testing.expect_value(t, len(msgs), 1)
	testing.expect_value(t, msgs[0].id, "msg_quotes")
	expected_body := "Message with \"quotes\", backslash \\, and \nnewline."
	testing.expect_value(t, msgs[0].body, expected_body)
}

@(test)
test_legacy_inbox_empty_and_missing_messages :: proc(t: ^testing.T) {
	empty_cases := [?]string{
		`{"ok":true,"messages":[]}`,
		`{"v":1,"ok":true,"data":{"messages":[]}}`,
		`{"ok":true}`,
		`{"messages":null}`,
		`{}`,
		``,
		`not valid json`,
	}
	for c in empty_cases {
		msgs := parse_legacy_inbox_messages(c, context.temp_allocator)
		testing.expect_value(t, len(msgs), 0)
		formatted := format_legacy_inbox_human(c, context.temp_allocator)
		testing.expect_value(t, formatted, "No unread messages.")
	}
}

@(test)
test_legacy_inbox_key_reordering_and_whitespace :: proc(t: ^testing.T) {
	// Legacy substring search failed if keys were in a different order or had extra spaces.
	raw := `
	{
		"ok": true,
		"messages": [
			{
				"body": "Reordered keys with whitespace",
				"from_agent_instance_id": "inst_reorder",
				"id": "msg_reordered"
			}
		]
	}
	`
	msgs := parse_legacy_inbox_messages(raw, context.temp_allocator)
	testing.expect_value(t, len(msgs), 1)
	testing.expect_value(t, msgs[0].id, "msg_reordered")
	testing.expect_value(t, msgs[0].from_agent_instance_id, "inst_reorder")
	testing.expect_value(t, msgs[0].body, "Reordered keys with whitespace")
}

@(test)
test_legacy_inbox_tracking_allocator_clean :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	context.allocator = mem.tracking_allocator(&track)

	payloads := [?]string{
		`{"ok":true,"messages":[{"id":"m1","from_agent_instance_id":"i1","body":"b1"}]}`,
		`{"v":1,"ok":true,"data":{"messages":[{"id":"m2","from_agent_instance_id":"i2","body":"{\"brace\":\"}\"}"}]}}`,
		`{"messages":[]}`,
		`{"ok":true}`,
		`[{"id":"m3","from_agent_instance_id":"i3","body":"direct"}]`,
	}

	for p in payloads {
		msgs := parse_legacy_inbox_messages(p, context.temp_allocator)
		formatted := format_legacy_inbox_human(p, context.temp_allocator)
		testing.expect(t, len(formatted) > 0, "formatted string must not be empty")
	}

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
	if len(track.allocation_map) > 0 {
		testing.fail_now(t, "Memory leak detected in legacy inbox message parsing")
	}
}
