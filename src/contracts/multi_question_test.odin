package contracts

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import vault "odin_test:lib/vault"

MQ_TEST_GROUP :: `{"version":1,"questions":[{"id":"target","text":"Where?","options":[{"id":"a","label":"Alpha"},{"id":"b","label":"Beta"}]},{"id":"checks","text":"Checks?","selection_mode":"multiple","options":[{"id":"x","label":"X"},{"id":"y","label":"Y"}]}]}`

@(test)
test_multi_question_schema_validation :: proc(t: ^testing.T) {
	g, invalid := multi_question_parse(MQ_TEST_GROUP, false)
	testing.expect_value(t, invalid, "")
	testing.expect_value(t, len(g.questions), 2)
	testing.expect_value(t, g.questions[0].selection_mode, "single")
	testing.expect_value(t, g.questions[1].selection_mode, "multiple")
	for raw in ([]string{
		"null", "[]", "{}", "{", `{"version":2,"questions":[]}`,
		`{"version":1,"questions":[]}`, `{"version":"1","questions":[]}`,
		mq_test_replace(MQ_TEST_GROUP, `"target"`, `"checks"`),
		mq_test_replace(MQ_TEST_GROUP, `"id":"b"`, `"id":"a"`),
		mq_test_replace(MQ_TEST_GROUP, `"id":"b"`, `"id":"bad id"`),
		mq_test_replace(MQ_TEST_GROUP, `"text":"Where?"`, `"text":false`),
		mq_test_replace(MQ_TEST_GROUP, `"multiple"`, `"all"`),
		mq_test_replace(MQ_TEST_GROUP, `"multiple"`, `null`),
		mq_test_replace(MQ_TEST_GROUP, `"label":"Beta"`, `"label":""`),
		mq_test_replace(MQ_TEST_GROUP, `"id":"b"`, `"id":"b","private":"unsealed"`),
	}) {
		_, error := multi_question_parse(raw, false)
		testing.expectf(t, error != "", "invalid schema rejected: %s", raw)
	}
	_, wire_error := multi_question_parse(MQ_TEST_GROUP, true)
	testing.expect(t, wire_error != "", "Hub refuses unencrypted human text")
	testing.expect(t, !multi_question_valid_text("vault:v2:fake", true, 8192), "prefix alone is not an envelope")
	testing.expect(t, !multi_question_valid_id(strings.repeat("x", 65, context.temp_allocator)), "ID limit")
	testing.expect(t, !multi_question_valid_text(strings.repeat("x", 8193, context.temp_allocator), false, 8192), "text limit")
	testing.expect(t, !multi_question_valid_text(mq_test_seal(strings.repeat("x", 8193, context.temp_allocator)), true, 8192), "encrypted text length is enforced without decrypting")
	testing.expect(t, !multi_question_valid_text(mq_test_seal(""), true, 8192), "an empty encrypted answer is rejected")
	_, too_large := multi_question_parse(strings.repeat(" ", MULTI_QUESTION_MAX_BYTES + 1, context.temp_allocator), false)
	testing.expect(t, too_large != "", "total size limit")
	for count in ([]int{12, 13}) {
		questions := make([]Multi_Question, count, context.temp_allocator)
		for &q, i in questions do q = Multi_Question{id = fmt.tprintf("q%d", i), text = "Q", selection_mode = "single", options = {{id = "o", label = "O"}}}
		raw, _ := json.marshal(Multi_Question_Group{version = 1, questions = questions}, allocator = context.temp_allocator)
		_, error := multi_question_parse(string(raw), false)
		testing.expect_value(t, error == "", count == 12)
		options := make([]Multi_Question_Option, count, context.temp_allocator)
		for &o, i in options do o = {id = fmt.tprintf("o%d", i), label = "O"}
		questions = {{id = "q", text = "Q", selection_mode = "single", options = options}}
		raw, _ = json.marshal(Multi_Question_Group{version = 1, questions = questions}, allocator = context.temp_allocator)
		_, error = multi_question_parse(string(raw), false)
		testing.expect_value(t, error == "", count == 12)
	}
}

mq_test_seal :: proc(text: string) -> string {
	key: [32]byte
	for &b, i in key do b = byte(i)
	kr, _ := vault.keyring_from_single_key("mqtest", {1, 2, 3, 4, 5, 6, 7, 8}, 1, key[:])
	defer vault.keyring_wipe(&kr)
	sealed, _ := vault.seal(transmute([]byte)text, &kr, context.temp_allocator)
	return sealed
}

@(test)
test_multi_question_answer_validation :: proc(t: ^testing.T) {
	g, _ := multi_question_parse(MQ_TEST_GROUP, false)
	body := mq_test_seal("Where? Alpha; Checks? X and Y")
	custom := mq_test_seal("Use my custom checks")
	raw := fmt.tprintf(`{{"version":1,"idempotency_key":"retry_1","body":"%s","answers":[{{"question_id":"target","option_ids":["a"]}},{{"question_id":"checks","option_ids":["x","y"]}}]}}`, body)
	s, invalid := multi_question_parse_submission(raw)
	testing.expect_value(t, invalid, "")
	testing.expect_value(t, multi_question_validate_answers(g, s), "")
	custom_raw := fmt.tprintf(`{{"version":1,"idempotency_key":"retry_2","body":"%s","answers":[{{"question_id":"checks","custom_text":"%s"}},{{"question_id":"target","option_ids":["b"]}}]}}`, body, custom)
	s, invalid = multi_question_parse_submission(custom_raw)
	testing.expect_value(t, invalid, "")
	testing.expect_value(t, multi_question_validate_answers(g, s), "")
	for bad in ([]string{
		mq_test_replace(raw, `"retry_1"`, `""`),
		mq_test_replace(raw, `"question_id":"checks"`, `"question_id":"target"`),
		mq_test_replace(raw, `["a"]`, `["a","a"]`),
		mq_test_replace(raw, `["a"]`, `[]`),
		mq_test_replace(raw, `["a"]`, `null`),
		mq_test_replace(raw, `["a"]`, `[false]`),
		mq_test_replace(raw, body, "plaintext"),
		mq_test_replace(custom_raw, custom, "plaintext"),
		mq_test_replace(custom_raw, `"custom_text":`, `"option_ids":["x"],"custom_text":`),
	}) {
		_, error := multi_question_parse_submission(bad)
		testing.expect(t, error != "", "invalid answers rejected before persistence")
	}
	for bad in ([]string{
		mq_test_replace(raw, `"question_id":"checks"`, `"question_id":"unknown"`),
		mq_test_replace(raw, `["a"]`, `["a","b"]`),
		mq_test_replace(raw, `["a"]`, `["unknown"]`),
	}) {
		s, error := multi_question_parse_submission(bad)
		testing.expect_value(t, error, "")
		testing.expect(t, multi_question_validate_answers(g, s) != "", "source-aware validation rejects unknown IDs/counts")
	}
	s.answers = s.answers[:1]
	testing.expect(t, multi_question_validate_answers(g, s) != "", "all questions are required")
}

mq_test_replace :: proc(s, old, replacement: string) -> string {
 out, _ := strings.replace_all(s, old, replacement, context.temp_allocator)
 return out
}
