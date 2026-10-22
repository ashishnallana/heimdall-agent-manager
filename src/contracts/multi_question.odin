package contracts

import "core:encoding/json"
import "core:strings"
import jsonx "odin_test:lib/jsonx"
import vault "odin_test:lib/vault"

MULTI_QUESTION_MAX_BYTES :: 256 * 1024
MULTI_QUESTION_MAX_QUESTIONS :: 12
MULTI_QUESTION_MAX_OPTIONS :: 12

Multi_Question_Option :: struct { id, label: string }
Multi_Question :: struct {
	id, text, selection_mode: string,
	options: []Multi_Question_Option,
}
Multi_Question_Group :: struct { version: int, questions: []Multi_Question }
Multi_Question_Answer :: struct {
	question_id: string,
	option_ids: []string `json:"option_ids,omitempty"`,
	custom_text: string `json:"custom_text,omitempty"`,
}
Multi_Question_Submission :: struct {
	version: int,
	idempotency_key, body: string,
	answers: []Multi_Question_Answer,
}

multi_question_valid_id :: proc(id: string) -> bool {
	if len(id) < 1 || len(id) > 64 do return false
	for c in id {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-') do return false
	}
	return true
}

// Human text is encrypted before crossing the wire. Structural validation never
// needs a vault key; parsing the envelope also rejects fake armor prefixes.
multi_question_valid_text :: proc(text: string, sealed: bool, max_plain: int) -> bool {
	if strings.trim_space(text) == "" || len(text) > max_plain * 2 + 512 do return false
	if !sealed do return len(text) <= max_plain
	_, _, payload, result := vault.envelope_parse(text, context.temp_allocator)
	// GCM preserves plaintext length. Enforce its byte limit without decrypting.
	plain_bytes := len(payload) - vault.HEADER_BYTES
	return result == .Ok && plain_bytes > 0 && plain_bytes <= max_plain
}

mq_string :: proc(o: json.Object, key: string) -> string {
	s, _ := o[key].(json.String)
	return string(s)
}

mq_known_fields :: proc(o: json.Object, allowed: []string) -> bool {
	for key in o {
		known := false
		for field in allowed do if key == field do known = true
		if !known do return false
	}
	return true
}

// Returned strings and slices live in the request temp arena.
multi_question_parse :: proc(raw: string, sealed: bool) -> (Multi_Question_Group, string) {
	if len(raw) > MULTI_QUESTION_MAX_BYTES do return {}, "questions payload is too large"
	root, ok := jsonx.parse_body(raw, context.temp_allocator)
	if !ok do return {}, "questions must be valid JSON"
	o, obj_ok := root.(json.Object)
	if !obj_ok do return {}, "questions must be an object"
	if !mq_known_fields(o, {"version", "questions"}) do return {}, "unknown questions field"
	v, _ := o["version"].(json.Integer)
	if v != 1 do return {}, "questions version must be 1"
	rows, rows_ok := o["questions"].(json.Array)
	if !rows_ok || len(rows) < 1 || len(rows) > MULTI_QUESTION_MAX_QUESTIONS do return {}, "provide 1 to 12 questions"
	g := Multi_Question_Group{version = 1, questions = make([]Multi_Question, len(rows), context.temp_allocator)}
	for row, i in rows {
		q, q_ok := row.(json.Object)
		if !q_ok do return {}, "each question must be an object"
		if !mq_known_fields(q, {"id", "text", "selection_mode", "options"}) do return {}, "unknown question field"
		id := mq_string(q, "id")
		if !multi_question_valid_id(id) do return {}, "invalid question id"
		for previous in g.questions[:i] do if previous.id == id do return {}, "duplicate question id"
		text := mq_string(q, "text")
		if !multi_question_valid_text(text, sealed, 8192) do return {}, "question text is missing, too long, or not encrypted"
		mode := mq_string(q, "selection_mode")
		if mode == "" {
			if _, exists := q["selection_mode"]; exists do return {}, "selection_mode must be single or multiple"
			mode = "single"
		}
		if mode != "single" && mode != "multiple" do return {}, "selection_mode must be single or multiple"
		opts, opts_ok := q["options"].(json.Array)
		if !opts_ok || len(opts) < 1 || len(opts) > MULTI_QUESTION_MAX_OPTIONS do return {}, "provide 1 to 12 options per question"
		out := Multi_Question{id = id, text = text, selection_mode = mode, options = make([]Multi_Question_Option, len(opts), context.temp_allocator)}
		for opt, j in opts {
			a, a_ok := opt.(json.Object)
			if !a_ok do return {}, "each option must be an object"
			if !mq_known_fields(a, {"id", "label"}) do return {}, "unknown option field"
			oid, label := mq_string(a, "id"), mq_string(a, "label")
			if !multi_question_valid_id(oid) do return {}, "invalid option id"
			for previous in out.options[:j] do if previous.id == oid do return {}, "duplicate option id"
			if !multi_question_valid_text(label, sealed, 2048) do return {}, "option label is missing, too long, or not encrypted"
			out.options[j] = {id = oid, label = label}
		}
		g.questions[i] = out
	}
	return g, ""
}

multi_question_parse_submission :: proc(raw: string) -> (Multi_Question_Submission, string) {
	if len(raw) > MULTI_QUESTION_MAX_BYTES do return {}, "answer payload is too large"
	root, ok := jsonx.parse_body(raw, context.temp_allocator)
	if !ok do return {}, "answer must be valid JSON"
	o, obj_ok := root.(json.Object)
	if !obj_ok do return {}, "answer must be an object"
	if !mq_known_fields(o, {"version", "idempotency_key", "body", "answers"}) do return {}, "unknown answer submission field"
	v, _ := o["version"].(json.Integer)
	if v != 1 do return {}, "answer version must be 1"
	out := Multi_Question_Submission{version = 1, idempotency_key = mq_string(o, "idempotency_key"), body = mq_string(o, "body")}
	if !multi_question_valid_id(out.idempotency_key) do return {}, "invalid idempotency key"
	if !multi_question_valid_text(out.body, true, 65536) do return {}, "answer body must be encrypted and nonempty"
	rows, rows_ok := o["answers"].(json.Array)
	if !rows_ok || len(rows) < 1 || len(rows) > MULTI_QUESTION_MAX_QUESTIONS do return {}, "provide 1 to 12 answers"
	out.answers = make([]Multi_Question_Answer, len(rows), context.temp_allocator)
	for row, i in rows {
		a, a_ok := row.(json.Object)
		if !a_ok do return {}, "each answer must be an object"
		if !mq_known_fields(a, {"question_id", "option_ids", "custom_text"}) do return {}, "unknown answer field"
		answer := Multi_Question_Answer{question_id = mq_string(a, "question_id"), custom_text = mq_string(a, "custom_text")}
		if !multi_question_valid_id(answer.question_id) do return {}, "invalid answer question id"
		for previous in out.answers[:i] do if previous.question_id == answer.question_id do return {}, "duplicate answer question id"
		if cv, exists := a["custom_text"]; exists {
			if _, str_ok := cv.(json.String); !str_ok do return {}, "custom_text must be a string"
		}
		if ids_v, exists := a["option_ids"]; exists {
			ids, ids_ok := ids_v.(json.Array)
			if !ids_ok || len(ids) > MULTI_QUESTION_MAX_OPTIONS do return {}, "invalid option_ids"
			answer.option_ids = make([]string, len(ids), context.temp_allocator)
			for id_v, j in ids {
				id, str_ok := id_v.(json.String)
				if !str_ok || !multi_question_valid_id(string(id)) do return {}, "invalid selected option id"
				for previous in answer.option_ids[:j] do if previous == string(id) do return {}, "duplicate selected option id"
				answer.option_ids[j] = string(id)
			}
		}
		if answer.custom_text != "" {
			if len(answer.option_ids) != 0 || !multi_question_valid_text(answer.custom_text, true, 8192) do return {}, "custom text must be encrypted and is an alternative to options"
		} else if len(answer.option_ids) == 0 do return {}, "each question needs an answer"
		out.answers[i] = answer
	}
	return out, ""
}

multi_question_validate_answers :: proc(g: Multi_Question_Group, submission: Multi_Question_Submission) -> string {
	if len(submission.answers) != len(g.questions) do return "answer every question"
	for a in submission.answers {
		found := false
		for q in g.questions {
			if q.id != a.question_id do continue
			found = true
			if q.selection_mode == "single" && len(a.option_ids) > 1 do return "single selection question accepts one option"
			for id in a.option_ids {
				known := false
				for o in q.options do if o.id == id do known = true
				if !known do return "unknown option id"
			}
		}
		if !found do return "unknown question id"
	}
	return ""
}
