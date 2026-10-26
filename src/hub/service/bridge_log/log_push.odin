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

import "core:encoding/json"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import project_service "odin_test:hub/service/project"
import httpc "odin_test:lib/httpc"
import metrics "odin_test:lib/metrics"

LOKI_PUSH_PATH :: [?]string{"insert", "loki", "api", "v1", "push"}
PUSH_TIMEOUT_MS :: 2000
PUSH_JOB :: "heimdall-bridge"

// Push_Send abstracts the HTTP POST so tests can script status codes.
Push_Send :: proc(ctx: rawptr, endpoint: httpc.Url, path: []string, body: httpc.Body, timeout_ms: int) -> (status: int, ok: bool)

Push_Client :: struct {
	base_url:   string, // no trailing slash; "" = push disabled
	endpoint:   httpc.Url, // base_url parsed once (heap)
	version:    string, // hub version, sent as metadata
	send:       Push_Send,
	send_ctx:   rawptr,
	timeout_ms: int,
	// Test visibility.
	attempts:   int,
	failures:   int,
}

@(private = "file")
http_send :: proc(ctx: rawptr, endpoint: httpc.Url, path: []string, body: httpc.Body, timeout_ms: int) -> (int, bool) {
	resp, err := httpc.send({method = .POST, url = endpoint, path = path, body = body, timeout_ms = timeout_ms}, context.temp_allocator)
	if err != .None do return 0, false
	return resp.status, true
}

// new_push_client builds the default client over src/lib/httpc. `url` is the
// --log-push-url value (scheme://host[:port], any trailing slash stripped). An
// unparsable URL disables the push (base_url "").
new_push_client :: proc(url: string, version: string = contracts.APP_VERSION) -> Push_Client {
	base := strings.trim_right(strings.trim_space(url), "/")
	endpoint: httpc.Url
	if base != "" {
		parsed, err := httpc.parse_url(base, context.allocator)
		if err != .None do base = ""
		else do endpoint = parsed
	}
	return Push_Client{base_url = base, endpoint = endpoint, version = version, send = http_send, timeout_ms = PUSH_TIMEOUT_MS}
}

// push_client_destroy frees the parsed endpoint (tests; the hub's client lives
// for the process).
push_client_destroy :: proc(c: ^Push_Client) {
	httpc.url_destroy(&c.endpoint)
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
	payload := loki_push_payload(events, client.version, context.temp_allocator)
	_ = push_once_with_retry(client, httpc.json_body(payload, sort_keys = true))
}

// push_once_with_retry returns true when the backend accepted the batch.
push_once_with_retry :: proc(client: ^Push_Client, body: httpc.Body) -> bool {
	path := LOKI_PUSH_PATH
	timeout := client.timeout_ms if client.timeout_ms > 0 else PUSH_TIMEOUT_MS
	for attempt in 0 ..< 2 {
		client.attempts += 1
		status, ok := client.send(client.send_ctx, client.endpoint, path[:], body, timeout)
		if ok && status >= 200 && status < 300 do return true
		// 4xx is a permanent rejection (too old, malformed, limits): never retry.
		if ok && status >= 400 && status < 500 do break
		if attempt == 1 do break
	}
	client.failures += 1
	metrics.counter_inc(project_service.fleet_metrics.log_push_failures)
	return false
}

// loki_push_payload builds one Loki push request as a JSON value: one stream per
// level present, values in the order given (the backend accepts out-of-order
// within a batch). Each value is [ns, line, metadata]; metadata values are
// strings. Marshal it with sorted keys (httpc.json_body(.., sort_keys = true)).
// Everything is allocated with `allocator` (callers pass a temp allocator).
loki_push_payload :: proc(events: []domain.Bridge_Log_Event, version: string, allocator := context.allocator) -> json.Value {
	context.allocator = allocator
	streams := make(json.Array, 0, 2)
	for level in ([]string{"warn", "error"}) {
		values := make(json.Array)
		for e in events {
			if e.level != level do continue
			ns_buf: [32]byte
			ns := strings.concatenate({strconv.write_int(ns_buf[:], e.ts_ms, 10), "000000"})
			line := render_message(e.code, e.fields_json, allocator)
			if e.count > 1 {
				count_buf: [32]byte
				line = strings.concatenate({line, " (x", strconv.write_int(count_buf[:], i64(e.count), 10), ")"})
			}
			count_buf: [32]byte
			meta := make(json.Object)
			meta["bridge_id"] = json.String(e.bridge_id)
			meta["code"] = json.String(e.code)
			meta["class"] = json.String(render_class(e.code, e.fields_json))
			meta["version"] = json.String(version)
			meta["count"] = json.String(strings.clone(strconv.write_int(count_buf[:], i64(e.count), 10)))
			add_fields_as_metadata(&meta, e.fields_json)
			tuple := make(json.Array, 0, 3)
			append(&tuple, json.String(ns), json.String(line), meta)
			append(&values, tuple)
		}
		if len(values) == 0 do continue
		stream := make(json.Object)
		labels := make(json.Object)
		labels["job"] = json.String(PUSH_JOB)
		labels["level"] = json.String(level)
		stream["stream"] = labels
		stream["values"] = values
		append(&streams, stream)
	}
	root := make(json.Object)
	root["streams"] = streams
	return root
}

// add_fields_as_metadata copies every allow-listed field into the metadata
// (metadata values must be strings).
@(private = "file")
add_fields_as_metadata :: proc(meta: ^json.Object, fields_json: string) {
	keys := contracts.BRIDGE_LOG_KEY_NAMES
	for key_name in keys {
		raw, found := field_raw(fields_json, key_name)
		if !found do continue
		meta[key_name] = json.String(strings.clone(strings.trim(raw, "\"")))
	}
}

