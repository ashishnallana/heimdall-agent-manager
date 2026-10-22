package main

import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"

// Validate the plaintext file BEFORE acquiring keys or sending anything. Only
// structural IDs/modes stay plaintext; all human text uses the normal vault path.
ctl_multi_question_send_params :: proc(to, body, raw: string, args: []string) -> (string, string) {
	if to != "user" do return "", "--questions-file requires --to user"
	if strings.trim_space(body) == "" || len(body) > 65536 do return "", "a question message body of 1 to 65536 bytes is required"
	opts := collect_multi_values(args, "--options", "--option", "--expected-answers", "--choices")
	defer delete(opts)
	if len(opts) > 0 do return "", "--questions-file cannot be combined with flat options"
	group, invalid := contracts.multi_question_parse(raw, false)
	if invalid != "" do return "", invalid
	keyring := ctl_vault_keyring_for_write(args)
	for &q in group.questions {
		q.text = ctl_seal_or_exit(q.text, keyring)
		for &o in q.options do o.label = ctl_seal_or_exit(o.label, keyring)
	}
	chat_body := body
	if !is_vault_armored(body) do chat_body = ctl_seal_or_exit(body, keyring)
	actions := collect_multi_values(args, "--actions", "--action", "--action-id", "--action-ids")
	defer delete(actions)
	request := struct {
		to, body, message_type: string,
		metadata: struct {
			multi_question: contracts.Multi_Question_Group,
			action_ids: []string `json:"action_ids,omitempty"`,
		},
	}{}
	request.to = to
	request.body = chat_body
	request.message_type = "multi_question"
	request.metadata.multi_question = group
	request.metadata.action_ids = actions[:]
	encoded, err := json.marshal(request, allocator = context.temp_allocator)
	if err != nil || len(encoded) > contracts.MULTI_QUESTION_MAX_BYTES do return "", "encrypted question payload exceeds limit"
	return string(encoded), ""
}
