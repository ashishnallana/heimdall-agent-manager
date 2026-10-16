package http

// REQ-EA-4: the hub->bridge enrollment verdict must be well-formed JSON. Built with
// fmt, where a bare `{` is a placeholder: an unescaped template once produced
// `%!(MISSING CLOSE BRACE)…`, which the bridge's lenient extractor half-read.

import "core:encoding/json"
import "core:testing"

@(test)
bridge_enroll_result_json_is_valid_and_carries_the_verdict :: proc(t: ^testing.T) {
	for committed in ([2]bool{true, false}) {
		body := bridge_enroll_result_json("cmd_enroll_result_1", committed)
		defer delete(body)
		value, err := json.parse(transmute([]byte)body)
		defer json.destroy_value(value)
		testing.expectf(t, err == .None, "frame must be valid JSON, got %q (%v)", body, err)
		obj, is_obj := value.(json.Object)
		testing.expect(t, is_obj, "frame is a JSON object")
		if !is_obj do continue
		testing.expect_value(t, obj["type"].(json.String), "bridge_enrollment_result")
		testing.expect_value(t, obj["command_id"].(json.String), "cmd_enroll_result_1")
		testing.expect_value(t, obj["committed"].(json.Boolean), committed)
	}
}
