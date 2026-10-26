package main

import "core:strings"
import "core:testing"
import httpc "odin_test:lib/httpc"

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

// ctl_test_target renders a request the way both transports encode it.
ctl_test_target :: proc(t: ^testing.T, req: Ctl_Request, loc := #caller_location) -> string {
	target, err := httpc.build_target(req.path, req.query, context.temp_allocator)
	testing.expectf(t, err == .None, "build_target: %v", err, loc = loc)
	return target
}

@(test)
test_query_values_encode_reserved_bytes :: proc(t: ^testing.T) {
	for v in ([]string{"task brief", "facet:t1:2:output", "#evt_1", "src/a b.odin@HEAD", "a&b=c+d%e?", "Az09-_.~", "é"}) {
		query := []httpc.Query_Param{{"query", v}}
		target := ctl_test_target(t, {method = .GET, path = ctl_api("issues"), query = query})
		prefix := "/api/v1/issues?query="
		testing.expectf(t, strings.has_prefix(target, prefix), "route: %s", target)
		encoded := target[len(prefix):]
		testing.expectf(t, !strings.contains_any(encoded, "/:#&?@ ="), "reserved byte left raw in %s", encoded)
		testing.expect_value(t, test_query_decode(encoded), v)
	}
}

@(test)
test_query_add_skips_unset_values :: proc(t: ^testing.T) {
	q := ctl_query_make()
	ctl_query_add(&q, "query", "task brief")
	ctl_query_add(&q, "status", "")
	ctl_query_add(&q, "agent_ids", "agt_a,agt_b")
	testing.expect_value(t, len(q), 2)
	target := ctl_test_target(t, {method = .GET, path = ctl_api("issues"), query = q[:]})
	testing.expectf(t, target == "/api/v1/issues?query=task+brief&agent_ids=agt_a%2Cagt_b" || target == "/api/v1/issues?query=task%20brief&agent_ids=agt_a%2Cagt_b", "target: %s", target)
	testing.expect_value(t, ctl_test_target(t, {method = .GET, path = ctl_api("issues")}), "/api/v1/issues")
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
		path := ctl_test_target(t, ctl_task_fetch_request("chain_1", "task_1", ref))
		prefix := "/api/v1/task-chains/chain_1/tasks/task_1/fetch?ref="
		testing.expectf(t, strings.has_prefix(path, prefix), "route: %s", path)
		encoded := path[len(prefix):]
		testing.expectf(t, !strings.contains_any(encoded, "/:#&?@ "), "reserved byte left raw in %s", encoded)
		testing.expect_value(t, test_query_decode(encoded), ref)
	}
}
