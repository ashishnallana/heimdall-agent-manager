// MSG-2 handler coverage: the REST/RPC search response is rendered by
// http.search_groups_json(), which only emits groups listed in
// SEARCH_RESPONSE_TYPE_ORDER. This asserts, at the handler layer (not the repo),
// that (a) 'message' now survives that order so message hits reach BOTH
// /api/v1/search and /api/v1/agent-actions/search, and (b) conversation_position /
// conversation_total are emitted for message hits ONLY (omitted for other types).
package hub_search_message_handler_test

import "core:fmt"
import "core:testing"
import "core:os"
import "core:strings"
import iface "odin_test:hub/repository/iface"
import http "odin_test:hub/transport/http"

check :: proc(ok: bool, msg: string) {
	if ok do return
	fmt.eprintln("FAIL:", msg)
	os.exit(1)
}

@(test)
test_hub_search_message_handler_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	hits := []iface.Search_Hit{
		// A conversation (top-level entity) hit: must NOT carry position fields.
		{resource_type = "conversation", id = "inst_1", label = "Deploy chat", sublabel = "agt · chain c1", route = "/conversations/inst_1", score = 90, matched_field = "label"},
		// A message hit with a known in-conversation position.
		{resource_type = "message", id = "msg_1", label = "positronix three", sublabel = "Deploy chat", route = "/conversations/inst_1", score = 40, preview = "[positronix] three", matched_field = "body", conversation_position = 3, conversation_total = 5},
	}
	out := http.search_groups_json(hits)
	defer delete(out)

	// (a) the bug fix: a 'message' group is present (it survives SEARCH_RESPONSE_TYPE_ORDER).
	check(strings.contains(out, "\"type\":\"message\""), fmt.tprintf("response must contain a 'message' group; got %s", out))
	check(strings.contains(out, "\"id\":\"msg_1\""), "the message hit must be rendered")

	// (b) position fields present on the message hit and CORRECT.
	check(strings.contains(out, "\"conversation_position\":3"), fmt.tprintf("message hit must emit conversation_position:3; got %s", out))
	check(strings.contains(out, "\"conversation_total\":5"), fmt.tprintf("message hit must emit conversation_total:5; got %s", out))

	// (c) position fields are message-only: they appear exactly once (never on the
	// conversation hit).
	check(strings.count(out, "conversation_position") == 1, fmt.tprintf("conversation_position must appear once (message only); got %s", out))
	check(strings.count(out, "conversation_total") == 1, fmt.tprintf("conversation_total must appear once (message only); got %s", out))

	fmt.println("PASS: hub search message handler (message group survives response order + message-only conversation_position/total)")
}
