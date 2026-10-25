package main

import "core:fmt"
import "core:strings"

// Shared query-string encoding for every ham-ctl request path. A query value is
// user text (a search phrase, a fetch ref such as `facet:t:1:output` or
// `src/a.odin@HEAD`, a cursor), so it is always percent-encoded; the hub's
// query_value decodes it. Never use safe_path_part for a query value: it maps
// every reserved byte to `_` and the value cannot round-trip.

// write_query_escaped percent-encodes per RFC 3986 (unreserved chars pass through,
// everything else is %XX). Operates byte-wise so UTF-8 is encoded correctly.
write_query_escaped :: proc(b: ^strings.Builder, s: string) {
	for i in 0..<len(s) {
		ch := s[i]
		switch ch {
		case 'A'..='Z', 'a'..='z', '0'..='9', '-', '_', '.', '~':
			strings.write_byte(b, ch)
		case:
			strings.write_byte(b, '%')
			strings.write_byte(b, hex_upper_digit(ch >> 4))
			strings.write_byte(b, hex_upper_digit(ch & 0x0F))
		}
	}
}

hex_upper_digit :: proc(n: byte) -> byte {
	if n < 10 do return '0' + n
	return 'A' + (n - 10)
}

// query_escape returns `s` percent-encoded as one query value.
query_escape :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	write_query_escaped(&b, s)
	return strings.to_string(b)
}

// query_param appends `key=<escaped value>` to `query` when `value` is non-empty.
query_param :: proc(query: ^[dynamic]string, key, value: string) {
	if value == "" do return
	append(query, strings.concatenate({key, "=", query_escape(value)}, context.temp_allocator))
}

// path_with_query joins `path` and the encoded `key=value` pairs; `path` alone
// when there are none.
path_with_query :: proc(path: string, query: []string) -> string {
	if len(query) == 0 do return path
	return strings.concatenate({path, "?", strings.join(query, "&", context.temp_allocator)}, context.temp_allocator)
}

// ctl_task_fetch_path is the user-mode `tasks fetch` route. The ref carries `:`,
// `/`, `#` and `@` (facet:t:1:output, #evt_1, src/a.odin@HEAD), so it travels as
// an encoded query value.
ctl_task_fetch_path :: proc(chain_id, task_id, ref: string) -> string {
	return fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/fetch?ref=%s", safe_path_part(chain_id), safe_path_part(task_id), query_escape(ref))
}
