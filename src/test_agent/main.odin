package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import httpc "odin_test:lib/httpc"
import jsonx "odin_test:lib/jsonx"

Target :: struct {
	agent_instance_id: string,
	frequency_ms: i64,
	next_send_unix_ms: i64,
	sent_seq: int,
}

Stats :: struct {
	sent_messages: int,
	sent_bytes: int,
	received_messages: int,
	received_bytes: int,
	send_errors: int,
	fetch_errors: int,
	fetch_calls: int,
	started_unix_ms: i64,
	updated_unix_ms: i64,
}

Config :: struct {
	daemon_url: string,
	agent_instance_id: string,
	agent_token: string,
	targets_arg: string,
	duration_sec: int,
	message_size: int,
	stats_dir: string,
	log_dir: string,
	fetch_interval_ms: i64,
	max_sent: int,
	send_jitter_ms: i64,
	random_state: u64,
}

main :: proc() {
	// libcurl global init, once, before any thread (src/lib/httpc).
	if ok, message := httpc.init(); !ok {
		fmt.eprintln("ham-test-agent:", message)
		os.exit(1)
	}
	if has_flag(os.args, "--version") {
		fmt.println("ham-test-agent", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
		return
	}
	if has_flag(os.args, "--help") || has_flag(os.args, "-h") {
		print_usage()
		return
	}

	cfg := parse_args(os.args)
	if cfg.agent_instance_id == "" || cfg.agent_token == "" {
		fmt.println("required: --agent-instance-id <id> --agent-token <token>")
		return
	}

	os.make_directory_all(cfg.stats_dir)
	os.make_directory_all(cfg.log_dir)

	targets := parse_targets(cfg.targets_arg)
	defer delete(targets)

	stats := Stats{started_unix_ms = now_unix_ms(), updated_unix_ms = now_unix_ms()}
	end_unix_ms := stats.started_unix_ms + i64(cfg.duration_sec) * 1000
	next_fetch_unix_ms := stats.started_unix_ms
	next_stats_unix_ms := stats.started_unix_ms
	conversation_id := conversation_id_for_instance(cfg.agent_instance_id)

	fmt.println("ham-test-agent starting", cfg.agent_instance_id, "targets", len(targets))
	for now_unix_ms() < end_unix_ms {
		now := now_unix_ms()
		for i in 0..<len(targets) {
			if cfg.max_sent > 0 && stats.sent_messages >= cfg.max_sent do break
			if now >= targets[i].next_send_unix_ms {
				body := build_message_body(cfg.agent_instance_id, targets[i].agent_instance_id, targets[i].sent_seq + 1, now, cfg.message_size)
				ok, error_message := rpc_send_message(cfg.daemon_url, cfg.agent_token, targets[i].agent_instance_id, body)
				if ok {
					targets[i].sent_seq += 1
					stats.sent_messages += 1
					stats.sent_bytes += len(body)
				} else {
					stats.send_errors += 1
					append_error(cfg, fmt.tprintf("send_message failed target=%s seq=%d error=%s", targets[i].agent_instance_id, targets[i].sent_seq + 1, error_message))
				}
				targets[i].next_send_unix_ms = now + targets[i].frequency_ms + next_jitter_ms(&cfg)
			}
		}

		if now >= next_fetch_unix_ms {
			stats.fetch_calls += 1
			response, ok := rpc_fetch_messages(cfg.daemon_url, cfg.agent_token, conversation_id)
			if ok {
				count, bytes := log_incoming_messages(cfg, response)
				stats.received_messages += count
				stats.received_bytes += bytes
			} else {
				stats.fetch_errors += 1
				append_error(cfg, fmt.tprintf("fetch_messages failed response=%s", response))
			}
			next_fetch_unix_ms = now + cfg.fetch_interval_ms
		}

		if now >= next_stats_unix_ms {
			stats.updated_unix_ms = now
			write_stats(cfg, stats)
			next_stats_unix_ms = now + 1000
		}
		time.sleep(75 * time.Millisecond)
	}

	stats.updated_unix_ms = now_unix_ms()
	write_stats(cfg, stats)
	fmt.println("ham-test-agent done", cfg.agent_instance_id, "sent", stats.sent_messages, "received", stats.received_messages)
}

has_flag :: proc(args: []string, flag: string) -> bool {
	for arg in args {
		if arg == flag do return true
	}
	return false
}

print_usage :: proc() {
	fmt.println("ham-test-agent", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
	fmt.println("usage: ham-test-agent --agent-instance-id <id> --agent-token <token> [--daemon-url <url>] [--targets <id:ms,...>] [--duration-sec N] [--version] [--help]")
}

parse_args :: proc(args: []string) -> Config {
	cfg := Config{
		daemon_url = "http://127.0.0.1:49322",
		duration_sec = 60,
		message_size = 256,
		stats_dir = "/tmp/ham-test/stats",
		log_dir = "/tmp/ham-test/logs",
		fetch_interval_ms = 500,
	}
	for i := 1; i < len(args); i += 1 {
		if i + 1 >= len(args) do break
		key := args[i]
		value := args[i + 1]
		switch key {
		case "--daemon-url": cfg.daemon_url = value
		case "--agent-instance-id": cfg.agent_instance_id = value
		case "--agent-token": cfg.agent_token = value
		case "--targets": cfg.targets_arg = value
		case "--duration-sec": cfg.duration_sec = parse_int(value, cfg.duration_sec)
		case "--message-size": cfg.message_size = parse_int(value, cfg.message_size)
		case "--stats-dir": cfg.stats_dir = value
		case "--log-dir": cfg.log_dir = value
		case "--fetch-interval-ms": cfg.fetch_interval_ms = i64(parse_int(value, int(cfg.fetch_interval_ms)))
		case "--max-sent": cfg.max_sent = parse_int(value, cfg.max_sent)
		case "--send-jitter-ms": cfg.send_jitter_ms = i64(parse_int(value, int(cfg.send_jitter_ms)))
		case: continue
		}
		i += 1
	}
	if cfg.random_state == 0 {
		cfg.random_state = u64(now_unix_ms())
		for ch in cfg.agent_instance_id do cfg.random_state = cfg.random_state * 131 + u64(ch)
	}
	return cfg
}

next_jitter_ms :: proc(cfg: ^Config) -> i64 {
	if cfg.send_jitter_ms <= 0 do return 0
	cfg.random_state = cfg.random_state * 6364136223846793005 + 1442695040888963407
	return i64(cfg.random_state % u64(cfg.send_jitter_ms + 1))
}

parse_targets :: proc(value: string) -> [dynamic]Target {
	targets := make([dynamic]Target)
	if value == "" do return targets
	parts := strings.split(value, ",")
	defer delete(parts)
	base := now_unix_ms()
	for part in parts {
		colon := strings.last_index_byte(part, ':')
		if colon <= 0 do continue
		freq := parse_int(part[colon + 1:], 1000)
		if freq <= 0 do freq = 1000
		append(&targets, Target{agent_instance_id = strings.clone(part[:colon]), frequency_ms = i64(freq), next_send_unix_ms = base})
	}
	return targets
}

Rpc_Send_Message :: struct {
	agent_token:              string,
	action:                   string,
	target_agent_instance_id: string,
	payload:                  string,
}

Rpc_Fetch_Messages :: struct {
	agent_token:     string,
	action:          string,
	conversation_id: string,
	include_read:    bool,
	limit:           int,
}

// rpc_post POSTs a JSON body to <daemon_url>/agent-rpc; the reply body is
// temp-allocated.
rpc_post :: proc(daemon_url: string, body: httpc.Body) -> (status: int, reply: string, ok: bool) {
	base, url_err := httpc.parse_url(daemon_url)
	if url_err != .None do return 0, "", false
	resp, err := httpc.send({method = .POST, url = base, path = {"agent-rpc"}, body = body}, context.temp_allocator)
	if err != .None do return 0, "", false
	return resp.status, httpc.text(resp), true
}

rpc_send_message :: proc(daemon_url, agent_token, target, body: string) -> (bool, string) {
	msg := Rpc_Send_Message{agent_token = agent_token, action = "send_message", target_agent_instance_id = target, payload = body}
	status, reply, ok := rpc_post(daemon_url, httpc.json_body(msg))
	if ok && (status == 200 || status == 202) do return true, ""
	if !ok do return false, "http_post_failed"
	return false, fmt.tprintf("status=%d body=%s", status, reply)
}

rpc_fetch_messages :: proc(daemon_url, agent_token, conversation_id: string) -> (string, bool) {
	req := Rpc_Fetch_Messages{agent_token = agent_token, action = "fetch_messages", conversation_id = conversation_id, include_read = false, limit = 100}
	status, reply, ok := rpc_post(daemon_url, httpc.json_body(req))
	return reply, ok && status == 200
}

build_message_body :: proc(from, to: string, seq: int, created_unix_ms: i64, size: int) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, fmt.tprintf("from=%s;to=%s;seq=%d;created_unix_ms=%d;payload=", from, to, seq, created_unix_ms))
	for strings.builder_len(builder) < size {
		strings.write_string(&builder, "x")
	}
	body := strings.to_string(builder)
	if len(body) > size do return body[:size]
	return body
}

log_incoming_messages :: proc(cfg: Config, response_body: string) -> (count: int, bytes: int) {
	idx := 0
	for {
		msg_idx := strings.index(response_body[idx:], `{"id":"`)
		if msg_idx < 0 do break
		start := idx + msg_idx
		end_rel := strings.index(response_body[start:], `}`)
		if end_rel < 0 do break
		object := response_body[start:start + end_rel + 1]
		body := extract_json_string(object, "body", "")
		line := incoming_log_line(cfg.agent_instance_id, object, body)
		append_file(log_path(cfg), line)
		count += 1
		bytes += len(body)
		idx = start + end_rel + 1
	}
	return
}

incoming_log_line :: proc(agent_instance_id, object, body: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "{\"ts_unix_ms\":")
	strings.write_string(&builder, fmt.tprintf("%d", now_unix_ms()))
	strings.write_string(&builder, ",\"message_id\":\"")
	strings.write_string(&builder, extract_json_string(object, "id", ""))
	strings.write_string(&builder, "\",\"conversation_id\":\"")
	strings.write_string(&builder, extract_json_string(object, "conversation_id", ""))
	strings.write_string(&builder, "\",\"from_agent_instance_id\":\"")
	strings.write_string(&builder, extract_json_string(object, "from_agent_instance_id", ""))
	strings.write_string(&builder, "\",\"target_agent_instance_id\":\"")
	strings.write_string(&builder, extract_json_string(object, "target_agent_instance_id", agent_instance_id))
	strings.write_string(&builder, "\",\"bytes\":")
	strings.write_string(&builder, fmt.tprintf("%d", len(body)))
	strings.write_string(&builder, ",\"body\":\"")
	strings.write_string(&builder, json_escape(body))
	strings.write_string(&builder, "\"}\n")
	return strings.to_string(builder)
}

write_stats :: proc(cfg: Config, stats: Stats) {
	builder := strings.builder_make()
	strings.write_string(&builder, "{\"agent_instance_id\":\"")
	strings.write_string(&builder, cfg.agent_instance_id)
	strings.write_string(&builder, "\",\"sent_messages\":")
	strings.write_string(&builder, fmt.tprintf("%d", stats.sent_messages))
	strings.write_string(&builder, ",\"sent_bytes\":")
	strings.write_string(&builder, fmt.tprintf("%d", stats.sent_bytes))
	strings.write_string(&builder, ",\"received_messages\":")
	strings.write_string(&builder, fmt.tprintf("%d", stats.received_messages))
	strings.write_string(&builder, ",\"received_bytes\":")
	strings.write_string(&builder, fmt.tprintf("%d", stats.received_bytes))
	strings.write_string(&builder, ",\"send_errors\":")
	strings.write_string(&builder, fmt.tprintf("%d", stats.send_errors))
	strings.write_string(&builder, ",\"fetch_errors\":")
	strings.write_string(&builder, fmt.tprintf("%d", stats.fetch_errors))
	strings.write_string(&builder, ",\"fetch_calls\":")
	strings.write_string(&builder, fmt.tprintf("%d", stats.fetch_calls))
	strings.write_string(&builder, ",\"max_sent\":")
	strings.write_string(&builder, fmt.tprintf("%d", cfg.max_sent))
	strings.write_string(&builder, ",\"send_jitter_ms\":")
	strings.write_string(&builder, fmt.tprintf("%d", cfg.send_jitter_ms))
	strings.write_string(&builder, ",\"started_unix_ms\":")
	strings.write_string(&builder, fmt.tprintf("%d", stats.started_unix_ms))
	strings.write_string(&builder, ",\"updated_unix_ms\":")
	strings.write_string(&builder, fmt.tprintf("%d", stats.updated_unix_ms))
	strings.write_string(&builder, "}")

	path := stats_path(cfg)
	tmp_path := fmt.tprintf("%s.tmp", path)
	if os.write_entire_file(tmp_path, strings.to_string(builder)) == nil {
		_ = os.rename(tmp_path, path)
	}
}

append_error :: proc(cfg: Config, message: string) {
	append_file(error_path(cfg), fmt.tprintf("%d %s\n", now_unix_ms(), message))
}

append_file :: proc(path, text: string) {
	file, err := os.open(path, os.O_CREATE | os.O_APPEND | os.O_WRONLY)
	if err != nil do return
	defer os.close(file)
	os.write_string(file, text)
}

stats_path :: proc(cfg: Config) -> string { return fmt.tprintf("%s/%s.stats.json", cfg.stats_dir, cfg.agent_instance_id) }
log_path :: proc(cfg: Config) -> string { return fmt.tprintf("%s/%s.incoming.jsonl", cfg.log_dir, cfg.agent_instance_id) }
error_path :: proc(cfg: Config) -> string { return fmt.tprintf("%s/%s.errors.log", cfg.log_dir, cfg.agent_instance_id) }

conversation_id_for_instance :: proc(agent_instance_id: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "conv_")
	for ch in agent_instance_id {
		switch ch {
		case 'a'..='z', 'A'..='Z', '0'..='9', '_', '-': strings.write_rune(&builder, ch)
		case: strings.write_string(&builder, "_")
		}
	}
	return strings.to_string(builder)
}

extract_json_string :: proc(body, key, fallback: string, allocator := context.allocator) -> string {
	return jsonx.extract_string(body, key, fallback, false, allocator)
}

json_unescape :: proc(value: string, allocator := context.allocator) -> string {
	return jsonx.json_unescape_string(value, allocator)
}

json_escape :: proc(value: string) -> string {
	builder := strings.builder_make()
	for ch in value {
		switch ch {
		case '\\': strings.write_string(&builder, "\\\\")
		case '"': strings.write_string(&builder, "\\\"")
		case '\n': strings.write_string(&builder, "\\n")
		case '\r': strings.write_string(&builder, "\\r")
		case '\t': strings.write_string(&builder, "\\t")
		case: strings.write_rune(&builder, ch)
		}
	}
	return strings.to_string(builder)
}

parse_int :: proc(value: string, fallback: int) -> int {
	parsed, ok := strconv.parse_int(value)
	if !ok do return fallback
	return int(parsed)
}

now_unix_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}
