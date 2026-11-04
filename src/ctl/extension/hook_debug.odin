package extension

// Opt-in hook debug log (HEIMDALL_EXTENSION_DEBUG_LOG=<absolute file path>).
//
// One JSON line is appended per `ham-ctl extension hook` invocation. Hooks must
// never write to stdout/stderr (the provider feeds hook stdout to the model and
// treats stderr as a hook failure), so the log goes to a file only and every
// failure to write it is swallowed. Unset (or not absolute): nothing happens and
// no file is created. Prompt and tool content is never logged: only identifiers,
// the transcript path and the usage-reader outcome.

import json "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

HOOK_DEBUG_LOG_ENV :: "HEIMDALL_EXTENSION_DEBUG_LOG"
HOOK_DEBUG_FIELD_MAX :: 512
HOOK_DEBUG_ERROR_MAX :: 256

// Hook_Debug collects what one invocation did. Hook processes are single-shot and
// single-threaded, so one package-level record is enough (and keeps the seam out
// of every adapter signature).
Hook_Debug :: struct {
	active:          bool,
	usage_reader:    bool, // a reader exists for the provider
	usage_ok:        bool,
	context_tokens:  i64,
	usage_source:    string,
	usage_emitted:   bool, // usage block put on the event
	unavailable:     bool, // usage_unavailable:true put on the event
	posted:          bool, // an event POST was attempted
	post_ok:         bool,
	error:           string,
}

@(private = "file")
hook_debug: Hook_Debug

hook_debug_reset :: proc(active: bool) {
	hook_debug = Hook_Debug{active = active}
}

hook_debug_note_usage :: proc(has_reader, ok: bool, u: Transcript_Usage) {
	if !hook_debug.active do return
	hook_debug.usage_reader = has_reader
	hook_debug.usage_ok = ok
	if ok {
		hook_debug.context_tokens = u.context_tokens
		hook_debug.usage_source = strings.clone(u.source, context.temp_allocator)
		hook_debug.usage_emitted = true
	} else if has_reader {
		hook_debug.unavailable = true
	}
}

hook_debug_note_error :: proc(msg: string) {
	if !hook_debug.active || hook_debug.error != "" do return
	hook_debug.error = msg
}

// hook_send_event delivers a non-permission event and records the outcome.
hook_send_event :: proc(env: Hook_Env, send: Send_Proc, events_params: string) {
	_, ok := send(env.endpoint, env.token, "agent.extension.event", events_params, EVENT_SOCKET_TIMEOUT_MS)
	if hook_debug.active {
		hook_debug.posted = true
		hook_debug.post_ok = ok
		if !ok do hook_debug_note_error("event POST to bridge failed")
	}
}

@(private = "file")
hook_debug_clip :: proc(s: string, max: int) -> string {
	if len(s) <= max do return s
	return strings.concatenate({s[:max], "...(truncated)"}, context.temp_allocator)
}

@(private = "file")
hook_debug_str :: proc(b: ^strings.Builder, key, val: string, max := HOOK_DEBUG_FIELD_MAX) {
	fmt.sbprintf(b, `,"%s":`, key)
	enc, err := json.marshal(hook_debug_clip(val, max), allocator = context.temp_allocator)
	if err != nil do strings.write_string(b, `""`)
	else do strings.write_string(b, string(enc))
}

// hook_debug_line renders the JSONL record (no trailing newline).
hook_debug_line :: proc(provider, raw, ts: string, latency_ms: i64, hook_error: string) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	fmt.sbprintf(&b, `{{"ts":"%s"`, ts)
	hook_debug_str(&b, "provider", provider, 64)
	hook_event, session_id, transcript: string
	if v, err := json.parse_string(strings.trim_space(raw), json.DEFAULT_SPECIFICATION, true, context.temp_allocator); err == .None {
		if root, is_obj := v.(json.Object); is_obj {
			hook_event = json_get_string(root, "hook_event_name")
			if hook_event == "" do hook_event = json_get_string(root, "hook_event")
			session_id = json_get_string(root, "session_id")
			transcript = json_get_string(root, "transcript_path")
		}
	} else {
		hook_debug_note_error("hook stdin is not valid JSON")
	}
	hook_debug_str(&b, "hook_event", hook_event, 128)
	hook_debug_str(&b, "session_id", session_id, 128)
	hook_debug_str(&b, "transcript_path", transcript)
	d := hook_debug
	fmt.sbprintf(&b, `,"usage_reader":%v,"usage_ok":%v`, d.usage_reader, d.usage_ok)
	if d.usage_ok {
		fmt.sbprintf(&b, `,"context_tokens":%d`, d.context_tokens)
		hook_debug_str(&b, "usage_source", d.usage_source, 128)
	} else if !d.usage_reader {
		hook_debug_str(&b, "usage_reason", "no usage reader for provider or event carries no usage", 128)
	} else {
		hook_debug_str(&b, "usage_reason", "transcript usage unavailable (no path, unreadable, or no usable record)", 128)
	}
	fmt.sbprintf(&b, `,"usage_unavailable_emitted":%v,"event_posted":%v,"event_post_ok":%v,"latency_ms":%d`, d.unavailable, d.posted, d.post_ok, latency_ms)
	err_text := d.error if d.error != "" else hook_error
	hook_debug_str(&b, "error", err_text, HOOK_DEBUG_ERROR_MAX)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// hook_debug_path returns the configured log path, or "" when logging is off.
hook_debug_path :: proc() -> string {
	p := strings.trim_space(os.get_env(HOOK_DEBUG_LOG_ENV, context.temp_allocator))
	if p == "" || !strings.has_prefix(p, "/") do return ""
	return p
}

// hook_debug_append appends one line; every error is swallowed.
hook_debug_append :: proc(path, line: string) {
	f, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_APPEND, {.Read_User, .Write_User})
	if err != nil do return
	defer os.close(f)
	data := strings.concatenate({line, "\n"}, context.temp_allocator)
	_, _ = os.write(f, transmute([]u8)data)
}

// hook_run_logged wraps hook_run with the opt-in debug record. Without the env
// var it is exactly hook_run.
hook_run_logged :: proc(provider, raw: string, env: Hook_Env, send: Send_Proc) -> string {
	path := hook_debug_path()
	if path == "" do return hook_run(provider, raw, env, send)
	hook_debug_reset(true)
	start := time.now()
	out := hook_run(provider, raw, env, send)
	latency := time.duration_milliseconds(time.since(start))
	hook_debug_append(path, hook_debug_line(provider, raw, env.ts, i64(latency), ""))
	hook_debug_reset(false)
	return out
}
