package bridge_log

// Optional log-backend push (bridge_logs plan v2 §4.2, L3). When the hub is
// started with --log-push-url, every batch the writer thread has COMMITTED to
// SQLite is also POSTed to `<url>/insert/loki/api/v1/push` (VictoriaLogs and
// Loki both speak it). Stream labels are {job="heimdall-bridge", level} ONLY;
// bridge_id, code, hub version and the typed fields travel as structured
// metadata (the third element of each value tuple), so the backend never sees
// one stream per bridge and `owner` is never sent at all. 2 s deadline, 4xx is
// permanent (dropped, counted), 5xx/timeout retried once, failures counted in
// heimdall_log_push_failures_total. Runs on the writer thread; it can delay
// the next batch by at most ~4 s and never blocks a reader thread.

import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import project_service "odin_test:hub/service/project"
import http_client "odin_test:lib/http_client"
import metrics "odin_test:lib/metrics"

LOKI_PUSH_PATH :: "/insert/loki/api/v1/push"
PUSH_TIMEOUT_MS :: 2000
PUSH_JOB :: "heimdall-bridge"

// Push_Send abstracts the HTTP POST so tests can script status codes.
Push_Send :: proc(ctx: rawptr, base_url, path, body: string, timeout_ms: int) -> (status: int, ok: bool)

Push_Client :: struct {
	base_url:   string, // no trailing slash
	version:    string, // hub version, sent as metadata
	send:       Push_Send,
	send_ctx:   rawptr,
	timeout_ms: int,
	// Test visibility.
	attempts:   int,
	failures:   int,
}

@(private = "file")
http_send :: proc(ctx: rawptr, base_url, path, body: string, timeout_ms: int) -> (int, bool) {
	resp, ok := http_client.post_with_timeout(base_url, path, body, timeout_ms)
	if !ok do return 0, false
	return resp.status, true
}

// new_push_client builds the default client over src/lib/http_client. `url` is
// the --log-push-url value (scheme://host[:port], any trailing slash stripped).
new_push_client :: proc(url: string, version: string = contracts.APP_VERSION) -> Push_Client {
	return Push_Client{base_url = strings.trim_right(strings.trim_space(url), "/"), version = version, send = http_send, timeout_ms = PUSH_TIMEOUT_MS}
}

// install_push installs the client as the service's sink. The client must
// outlive the service.
install_push :: proc(svc: ^Service, client: ^Push_Client) {
	set_push_sink(svc, push_sink, rawptr(client))
}

// push_sink is the Push_Sink adapter: format, send, retry 5xx/timeout once.
push_sink :: proc(ctx: rawptr, events: []domain.Bridge_Log_Event) {
	client := (^Push_Client)(ctx)
	if client == nil || len(events) == 0 || client.base_url == "" do return
	body := loki_push_json(events, client.version, context.temp_allocator)
	_ = push_once_with_retry(client, body)
}

// push_once_with_retry returns true when the backend accepted the batch.
push_once_with_retry :: proc(client: ^Push_Client, body: string) -> bool {
	timeout := client.timeout_ms if client.timeout_ms > 0 else PUSH_TIMEOUT_MS
	for attempt in 0 ..< 2 {
		client.attempts += 1
		status, ok := client.send(client.send_ctx, client.base_url, LOKI_PUSH_PATH, body, timeout)
		if ok && status >= 200 && status < 300 do return true
		// 4xx is a permanent rejection (too old, malformed, limits): never retry.
		if ok && status >= 400 && status < 500 do break
		if attempt == 1 do break
	}
	client.failures += 1
	metrics.counter_inc(project_service.fleet_metrics.log_push_failures)
	return false
}

// loki_push_json renders one Loki push request: one stream per level present,
// values sorted as given (the backend accepts out-of-order within a batch).
loki_push_json :: proc(events: []domain.Bridge_Log_Event, version: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"streams":[`)
	first_stream := true
	for level in ([]string{"warn", "error"}) {
		has := false
		for e in events do if e.level == level { has = true; break }
		if !has do continue
		if !first_stream do strings.write_byte(&b, ',')
		first_stream = false
		strings.write_string(&b, `{"stream":{"job":"`)
		strings.write_string(&b, PUSH_JOB)
		strings.write_string(&b, `","level":"`)
		strings.write_string(&b, level)
		strings.write_string(&b, `"},"values":[`)
		first_value := true
		for e in events {
			if e.level != level do continue
			if !first_value do strings.write_byte(&b, ',')
			first_value = false
			strings.write_string(&b, `["`)
			strings.write_i64(&b, e.ts_ms)
			strings.write_string(&b, `000000","`)
			line := render_message(e.code, e.fields_json, context.temp_allocator)
			write_json_escaped(&b, line)
			if e.count > 1 {
				strings.write_string(&b, " (x")
				strings.write_int(&b, e.count)
				strings.write_byte(&b, ')')
			}
			strings.write_string(&b, `",{"bridge_id":"`)
			write_json_escaped(&b, e.bridge_id)
			strings.write_string(&b, `","code":"`)
			write_json_escaped(&b, e.code)
			strings.write_string(&b, `","class":"`)
			write_json_escaped(&b, render_class(e.code, e.fields_json))
			strings.write_string(&b, `","version":"`)
			write_json_escaped(&b, version)
			strings.write_string(&b, `","count":"`)
			strings.write_int(&b, e.count)
			strings.write_byte(&b, '"')
			write_fields_as_metadata(&b, e.fields_json)
			strings.write_string(&b, "}]")
		}
		strings.write_string(&b, "]}")
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// write_fields_as_metadata appends `,"key":"value"` for every allow-listed
// field (metadata values must be strings).
@(private = "file")
write_fields_as_metadata :: proc(b: ^strings.Builder, fields_json: string) {
	keys := contracts.BRIDGE_LOG_KEY_NAMES
	for key_name in keys {
		raw, found := field_raw(fields_json, key_name)
		if !found do continue
		strings.write_string(b, `,"`)
		strings.write_string(b, key_name)
		strings.write_string(b, `":"`)
		write_json_escaped(b, strings.trim(raw, "\""))
		strings.write_byte(b, '"')
	}
}

@(private = "file")
write_json_escaped :: proc(b: ^strings.Builder, value: string) {
	for ch in value {
		switch ch {
		case '\\': strings.write_string(b, "\\\\")
		case '"':  strings.write_string(b, "\\\"")
		case '\n': strings.write_string(b, "\\n")
		case '\r': strings.write_string(b, "\\r")
		case '\t': strings.write_string(b, "\\t")
		case:
			if ch < 32 {
				strings.write_string(b, "\\u00")
				hex := "0123456789abcdef"
				strings.write_byte(b, hex[int(ch) >> 4])
				strings.write_byte(b, hex[int(ch) & 15])
			} else {
				strings.write_rune(b, ch)
			}
		}
	}
}
