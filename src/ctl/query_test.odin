package main

import "core:strings"
import "core:testing"

// REQ-TV2-6: one shared query encoder for every ham-ctl query value.

// test_query_decode mirrors the hub's query_component_decode
// (src/hub/transport/http/content_handlers.odin), so a round trip here is the
// round trip the hub performs.
@(private = "file")
test_query_decode :: proc(v: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	nib :: proc(c: byte) -> (int, bool) {
		switch c {
		case '0'..='9': return int(c - '0'), true
		case 'a'..='f': return int(c - 'a') + 10, true
		case 'A'..='F': return int(c - 'A') + 10, true
		}
		return 0, false
	}
	for i := 0; i < len(v); {
		if v[i] == '+' { strings.write_byte(&b, ' '); i += 1; continue }
		if v[i] == '%' && i + 2 < len(v) {
			hi, ok1 := nib(v[i + 1]); lo, ok2 := nib(v[i + 2])
			if ok1 && ok2 { strings.write_byte(&b, byte(hi * 16 + lo)); i += 3; continue }
		}
		strings.write_byte(&b, v[i]); i += 1
	}
	return strings.to_string(b)
}

@(test)
test_query_escape_encodes_reserved_bytes :: proc(t: ^testing.T) {
	testing.expect_value(t, query_escape("task brief"), "task%20brief")
	testing.expect_value(t, query_escape("facet:t1:2:output"), "facet%3At1%3A2%3Aoutput")
	testing.expect_value(t, query_escape("#evt_1"), "%23evt_1")
	testing.expect_value(t, query_escape("src/a b.odin@HEAD"), "src%2Fa%20b.odin%40HEAD")
	testing.expect_value(t, query_escape("a&b=c+d%e?"), "a%26b%3Dc%2Bd%25e%3F")
	testing.expect_value(t, query_escape("Az09-_.~"), "Az09-_.~")
	testing.expect_value(t, query_escape("é"), "%C3%A9")
	testing.expect_value(t, query_escape(""), "")
}

@(test)
test_query_param_and_path_with_query :: proc(t: ^testing.T) {
	q := make([dynamic]string, context.temp_allocator)
	query_param(&q, "query", "task brief")
	query_param(&q, "status", "")
	query_param(&q, "agent_ids", "agt_a,agt_b")
	testing.expect_value(t, len(q), 2)
	testing.expect_value(t, path_with_query("/api/v1/issues", q[:]), "/api/v1/issues?query=task%20brief&agent_ids=agt_a%2Cagt_b")
	testing.expect_value(t, path_with_query("/api/v1/issues", nil), "/api/v1/issues")
}

@(test)
test_task_fetch_ref_round_trips :: proc(t: ^testing.T) {
	for ref in ([]string{
		"facet:task_1:2:output",
		"#evt_18e1",
		"output:task_1",
		"dir:dir_1:abc123:src/ctl/main.odin",
		"src/ctl/main.odin@HEAD",
		"docs/a b+c%d.md#frag",
	}) {
		path := ctl_task_fetch_path("chain_1", "task_1", ref)
		prefix := "/api/v1/task-chains/chain_1/tasks/task_1/fetch?ref="
		testing.expectf(t, strings.has_prefix(path, prefix), "route: %s", path)
		encoded := path[len(prefix):]
		testing.expectf(t, !strings.contains_any(encoded, "/:#&?@ +"), "reserved byte left raw in %s", encoded)
		testing.expect_value(t, test_query_decode(encoded), ref)
	}
}
