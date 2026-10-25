package http

import "core:testing"

// REQ-TV2-6: ham-ctl percent-encodes every query value with one shared encoder
// (src/ctl/query.odin). These are its exact encodings (pinned by
// src/ctl/query_test.odin); query_value must decode each back to the original,
// so `tasks fetch` refs carrying `/`, `:`, `#` and `@` and multi-word issue
// queries round-trip.
@(test)
test_query_value_decodes_ctl_encoded_values :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	cases := [][2]string{
		{"ref=facet%3Atask_1%3A2%3Aoutput", "facet:task_1:2:output"},
		{"ref=%23evt_18e1", "#evt_18e1"},
		{"ref=dir%3Adir_1%3Aabc123%3Asrc%2Fctl%2Fmain.odin", "dir:dir_1:abc123:src/ctl/main.odin"},
		{"ref=src%2Fctl%2Fmain.odin%40HEAD", "src/ctl/main.odin@HEAD"},
		{"ref=docs%2Fa%20b%2Bc%25d.md%23frag", "docs/a b+c%d.md#frag"},
		{"status=open&query=task%20brief&limit=5", "task brief"},
	}
	for c in cases {
		key := "query" if c[1] == "task brief" else "ref"
		testing.expect_value(t, query_value(c[0], key), c[1])
	}
}
