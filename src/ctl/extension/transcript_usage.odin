package extension

// Provider-reported context usage (ham.ext.v1 event.usage), read from the TAIL
// of the session transcript named by the hook's transcript_path.
//
// Budget: the hook must stay far inside the bridge RPC timeout and transcripts
// grow to tens of MiB, so only the last TRANSCRIPT_TAIL_MAX bytes are ever read
// (one positioned read; the file is never scanned). Every failure — no path,
// unreadable file, no usable record in the window, malformed JSON — returns
// ok=false and the caller omits usage. Nothing here writes to stdout or stderr.
//
//   Claude: assistant entries carry message.usage {input_tokens,
//     cache_read_input_tokens, cache_creation_input_tokens, output_tokens}.
//     context_tokens = input + cache_read + cache_creation of the LAST main-chain
//     assistant usage. output_tokens_total is reported only when the whole file
//     fits in the window (then the sum is exact, deduplicated per message.id);
//     a partial window cannot yield a session total.
//   Codex: rollout event_msg {payload:{type:"token_count", info:{
//     total_token_usage, last_token_usage, model_context_window}}}. From the last
//     token_count with non-null info: context_tokens = last total_tokens minus
//     reasoning_output_tokens (Codex's own "tokens in context window"),
//     output_tokens_total = total_token_usage.output_tokens, context_window =
//     model_context_window.

import json "core:encoding/json"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"

TRANSCRIPT_TAIL_MAX :: 64 * 1024

Transcript_Usage :: contracts.Ext_Usage

// transcript_tail reads at most limit bytes from the end of path. When the read
// starts mid-file the (probably partial) first line is dropped. from_start is
// true when the window covers the whole file. Caller deletes data.
transcript_tail :: proc(path: string, limit := TRANSCRIPT_TAIL_MAX) -> (data: []u8, from_start: bool, ok: bool) {
	if strings.trim_space(path) == "" || limit <= 0 do return nil, false, false
	f, oerr := os.open(path)
	if oerr != nil do return nil, false, false
	defer os.close(f)
	size, serr := os.file_size(f)
	if serr != nil || size <= 0 do return nil, false, false
	offset := max(size - i64(limit), 0)
	buf := make([]u8, int(size - offset))
	total := 0
	for total < len(buf) {
		n, rerr := os.read_at(f, buf[total:], offset + i64(total))
		if n <= 0 || (rerr != nil && rerr != .EOF) do break
		total += n
	}
	if total == 0 {
		delete(buf)
		return nil, false, false
	}
	data = buf[:total]
	if offset > 0 {
		nl := strings.index_byte(string(data), '\n')
		if nl < 0 {
			delete(buf)
			return nil, false, false
		}
		data = data[nl + 1:]
	}
	// data aliases buf from a non-zero offset; copy so the caller can delete it.
	out := make([]u8, len(data))
	copy(out, data)
	delete(buf)
	return out, offset == 0, true
}

USAGE_SOURCE_CLAUDE :: "claude_transcript"

// claude_usage_reader is the Claude entry of the usage-source table
// (usage_source.odin): it takes the hook's transcript_path itself.
claude_usage_reader :: proc(root: json.Object) -> (Transcript_Usage, bool) {
	return claude_transcript_usage(json_get_string(root, "transcript_path"))
}

// claude_transcript_usage reads the Claude transcript tail. See file header.
claude_transcript_usage :: proc(path: string) -> (u: Transcript_Usage, ok: bool) {
	data, from_start, rok := transcript_tail(path)
	if !rok do return {}, false
	defer delete(data)
	return claude_usage_from_tail(string(data), from_start)
}

// claude_usage_from_tail parses a tail window (whole lines). from_start says
// the window begins at the start of the file.
claude_usage_from_tail :: proc(tail: string, from_start: bool) -> (u: Transcript_Usage, ok: bool) {
	lines := strings.split_lines(tail)
	defer delete(lines)

	// Context: newest main-chain assistant usage, scanning backwards.
	for i := len(lines) - 1; i >= 0 && !ok; i -= 1 {
		if !strings.contains(lines[i], `"usage"`) do continue
		value, perr := json.parse_string(lines[i], json.DEFAULT_SPECIFICATION, true)
		if perr != .None do continue // e.g. a line still being written
		if usage, _, is := claude_assistant_usage(value); is {
			u.context_tokens = claude_usage_int(usage, "input_tokens") +
				claude_usage_int(usage, "cache_read_input_tokens") +
				claude_usage_int(usage, "cache_creation_input_tokens")
			ok = true
		}
		json.destroy_value(value)
	}
	if !ok do return {}, false
	u.source = USAGE_SOURCE_CLAUDE
	if from_start {
		u.output_tokens_total, u.has_output_tokens_total = claude_output_total(lines)
	}
	return u, true
}

// claude_output_total sums output_tokens over every main-chain assistant
// message in lines. Claude writes one entry per content block, each repeating
// the message's usage, so entries are deduplicated by message.id (max wins).
// Any unparseable usage line makes the sum unreliable → ok=false.
@(private = "file")
claude_output_total :: proc(lines: []string) -> (total: i64, ok: bool) {
	per_message := make(map[string]i64)
	defer {
		for k in per_message do delete(k)
		delete(per_message)
	}
	anonymous: i64
	last := len(lines) - 1
	for last >= 0 && strings.trim_space(lines[last]) == "" do last -= 1
	for line, idx in lines {
		if !strings.contains(line, `"usage"`) do continue
		value, perr := json.parse_string(line, json.DEFAULT_SPECIFICATION, true)
		if perr != .None {
			// Only the final line may legitimately be incomplete.
			if idx >= last do continue
			return 0, false
		}
		defer json.destroy_value(value)
		usage, msg_id, is := claude_assistant_usage(value)
		if !is do continue
		out := claude_usage_int(usage, "output_tokens")
		if msg_id == "" {
			anonymous += out
			continue
		}
		if prev, seen := per_message[msg_id]; seen {
			per_message[msg_id] = max(prev, out)
		} else {
			per_message[strings.clone(msg_id)] = out
		}
	}
	total = anonymous
	for _, v in per_message do total += v
	return total, true
}

// claude_assistant_usage returns message.usage of a main-chain assistant entry
// with real (non-synthetic) usage.
@(private = "file")
claude_assistant_usage :: proc(value: json.Value) -> (usage: json.Object, msg_id: string, ok: bool) {
	root, is_obj := value.(json.Object)
	if !is_obj || json_get_string(root, "type") != "assistant" do return nil, "", false
	if json_get_bool(root, "isSidechain") do return nil, "", false
	msg := json_get_object(root, "message")
	if json_get_string(msg, "model") == "<synthetic>" do return nil, "", false
	usage = json_get_object(msg, "usage")
	if usage == nil do return nil, "", false
	if _, has := json_get_int(usage, "input_tokens"); !has do return nil, "", false
	return usage, json_get_string(msg, "id"), true
}

@(private = "file")
claude_usage_int :: proc(obj: json.Object, key: string) -> i64 {
	n, _ := json_get_int(obj, key)
	return i64(max(n, 0))
}

USAGE_SOURCE_CODEX :: "codex_rollout"

// codex_usage_reader is the Codex entry of the usage-source table.
codex_usage_reader :: proc(root: json.Object) -> (Transcript_Usage, bool) {
	return codex_transcript_usage(json_get_string(root, "transcript_path"))
}

// codex_transcript_usage reads the Codex rollout tail. See file header.
codex_transcript_usage :: proc(path: string) -> (u: Transcript_Usage, ok: bool) {
	data, _, rok := transcript_tail(path)
	if !rok do return {}, false
	defer delete(data)
	return codex_usage_from_tail(string(data))
}

codex_usage_from_tail :: proc(tail: string) -> (u: Transcript_Usage, ok: bool) {
	lines := strings.split_lines(tail)
	defer delete(lines)
	for i := len(lines) - 1; i >= 0; i -= 1 {
		if !strings.contains(lines[i], `"token_count"`) do continue
		value, perr := json.parse_string(lines[i], json.DEFAULT_SPECIFICATION, true)
		if perr != .None do continue
		u, ok = codex_token_count(value)
		json.destroy_value(value)
		if ok do return u, true
	}
	return {}, false
}

@(private = "file")
codex_token_count :: proc(value: json.Value) -> (u: Transcript_Usage, ok: bool) {
	root, is_obj := value.(json.Object)
	if !is_obj do return {}, false
	payload := json_get_object(root, "payload")
	if json_get_string(payload, "type") != "token_count" do return {}, false
	info := json_get_object(payload, "info") // null before the first model reply
	last := json_get_object(info, "last_token_usage")
	if last == nil do return {}, false
	ctx, has_total := json_get_int(last, "total_tokens")
	if !has_total {
		in_t, has_in := json_get_int(last, "input_tokens")
		if !has_in do return {}, false
		out_t, _ := json_get_int(last, "output_tokens")
		ctx = in_t + out_t
	}
	reasoning, _ := json_get_int(last, "reasoning_output_tokens")
	u.context_tokens = i64(max(ctx - max(reasoning, 0), 0))
	if out, has := json_get_int(json_get_object(info, "total_token_usage"), "output_tokens"); has && out >= 0 {
		u.output_tokens_total = i64(out)
		u.has_output_tokens_total = true
	}
	if win, has := json_get_int(info, "model_context_window"); has && win > 0 {
		u.context_window = i64(win)
		u.has_context_window = true
	}
	u.source = USAGE_SOURCE_CODEX
	return u, true
}

// ext_event_usage writes ,"usage":{...} when ok. Call after ext_event_tool (if
// any) and before ext_event_end.
ext_event_usage :: proc(eb: ^Ext_Event_Builder, u: Transcript_Usage, ok: bool) {
	if !ok do return
	b := &eb.b
	buf: [32]u8
	strings.write_string(b, `,"usage":{"context_tokens":`)
	strings.write_string(b, int_text(buf[:], int(u.context_tokens)))
	if u.has_output_tokens_total {
		strings.write_string(b, `,"output_tokens_total":`)
		strings.write_string(b, int_text(buf[:], int(u.output_tokens_total)))
	}
	if u.has_context_window {
		strings.write_string(b, `,"context_window":`)
		strings.write_string(b, int_text(buf[:], int(u.context_window)))
	}
	strings.write_string(b, `,"source":`)
	json_write_string(b, u.source)
	strings.write_byte(b, '}')
}
