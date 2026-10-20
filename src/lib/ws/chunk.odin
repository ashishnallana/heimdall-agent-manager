package ws

// Application-level chunking for oversized TEXT frames on the bridge<->hub channel:
// a JSON envelope carrying base64 fragments, reassembled by chunk_id.
//
// REQ-PTY-NET-2: BINARY frames (pty_wire output/input) are NEVER chunked here. The
// envelope is text/base64 and would reintroduce the ~1.37x + JSON overhead the binary
// format exists to remove (and under the legacy s_client cap it base64'd base64, 1.78x).
// Instead the pty emitter sizes its frames to fit the per-message cap on their own
// (bridge_pty_stream_emit_caps) and bridge_hub_send_binary refuses anything larger.

import base64 "core:encoding/base64"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import jsonx "../jsonx"

CHUNK_RAW_BYTES         :: 24 * 1024
CHUNK_MAX_BUFFERED_BYTES :: 16 * 1024 * 1024
CHUNK_MAX_MESSAGE_BYTES :: 16 * 1024 * 1024
CHUNK_MAX_INFLIGHT      :: 64
CHUNK_MAX_COUNT         :: 4096
CHUNK_REASSEMBLY_TTL    :: 30 * time.Second

Chunk_Outcome :: enum {
	Pass_Through,
	Absorbed,
	Completed,
	Dropped,
}

Chunk_Reassembly :: struct {
	chunk_id:        string,
	chunk_count:     int,
	total_bytes:     int,
	received_chunks: int,
	received_bytes:  int,
	fragments:       []string,
	started_at_ns:   i64,
}

@(private = "file")
_chunk_seq: u64

chunk_next_id :: proc(prefix: string = "hubcmd") -> string {
	n := sync.atomic_add(&_chunk_seq, 1)
	ns_buf: [32]byte
	seq_buf: [32]byte
	ns := strconv.write_int(ns_buf[:], time.to_unix_nanoseconds(time.now()), 10)
	seq := strconv.write_int(seq_buf[:], i64(n), 10)
	return strings.concatenate({prefix, ns, "_", seq})
}

chunk_count :: proc(total, payload: int) -> int {
	if payload <= 0 do return 0
	return (total + payload - 1) / payload
}

@(private = "file")
chunk_write_json_escaped_string :: proc(b: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		ch := s[i]
		switch ch {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\r':
			strings.write_string(b, "\\r")
		case '\t':
			strings.write_string(b, "\\t")
		case:
			strings.write_byte(b, ch)
		}
	}
}

chunk_json :: proc(chunk_id: string, chunk_index, chunk_count, total_bytes: int, fragment: string) -> string {
	b := strings.builder_make()
	ibuf: [32]byte
	strings.write_string(&b, `{"version":1,"kind":"chunk","stream_id":"`)
	chunk_write_json_escaped_string(&b, chunk_id)
	strings.write_string(&b, `","chunk_id":"`)
	chunk_write_json_escaped_string(&b, chunk_id)
	strings.write_string(&b, `","chunk_index":`)
	strings.write_string(&b, strconv.write_int(ibuf[:], i64(chunk_index), 10))
	strings.write_string(&b, `,"chunk_count":`)
	strings.write_string(&b, strconv.write_int(ibuf[:], i64(chunk_count), 10))
	strings.write_string(&b, `,"total_bytes":`)
	strings.write_string(&b, strconv.write_int(ibuf[:], i64(total_bytes), 10))
	strings.write_string(&b, `,"payload_fragment":"`)
	strings.write_string(&b, fragment)
	strings.write_string(&b, `","end_stream":`)
	strings.write_string(&b, "true" if chunk_index + 1 == chunk_count else "false")
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

frame_is_chunk :: proc(text: string) -> bool {
	kind := jsonx.extract_string(text, "kind", "", top_level_only = true)
	defer delete(kind)
	if kind != "chunk" do return false
	type_str := jsonx.extract_string(text, "type", "", top_level_only = true)
	defer delete(type_str)
	return type_str == ""
}

is_chunkable :: proc(
	text: string,
	payload: int = CHUNK_RAW_BYTES,
	max_bytes := CHUNK_MAX_MESSAGE_BYTES,
	max_chunks := CHUNK_MAX_COUNT,
) -> bool {
	if len(text) > max_bytes do return false
	if payload <= 0 do return false
	count := chunk_count(len(text), payload)
	return count <= max_chunks
}

chunk_frames :: proc(
	text: string,
	payload: int = CHUNK_RAW_BYTES,
	id_hint: string = "",
) -> []string {
	if payload <= 0 do return nil
	if len(text) <= payload do return nil
	count := chunk_count(len(text), payload)
	id := strings.clone(id_hint) if id_hint != "" else chunk_next_id()
	defer delete(id)
	frames := make([]string, count)
	for i in 0 ..< count {
		start := i * payload
		end := start + payload
		if end > len(text) do end = len(text)
		frag := base64.encode(transmute([]byte)text[start:end])
		frames[i] = chunk_json(id, i, count, len(text), string(frag))
		delete(frag)
	}
	return frames
}

chunk_reassembly_free :: proc(reassemblies: ^[dynamic]Chunk_Reassembly, idx: int) {
	for frag in reassemblies[idx].fragments do delete(frag)
	delete(reassemblies[idx].fragments)
	delete(reassemblies[idx].chunk_id)
	unordered_remove(reassemblies, idx)
}

chunk_reassemblies_free :: proc(reassemblies: ^[dynamic]Chunk_Reassembly) {
	for i in 0 ..< len(reassemblies) {
		for frag in reassemblies[i].fragments do delete(frag)
		delete(reassemblies[i].fragments)
		delete(reassemblies[i].chunk_id)
	}
	delete(reassemblies^)
}

chunk_reassembly_sweep :: proc(
	reassemblies: ^[dynamic]Chunk_Reassembly,
	now_ns: i64,
	ttl := CHUNK_REASSEMBLY_TTL,
) -> int {
	dropped := 0
	for i := len(reassemblies) - 1; i >= 0; i -= 1 {
		if now_ns - reassemblies[i].started_at_ns >= i64(ttl) {
			chunk_reassembly_free(reassemblies, i)
			dropped += 1
		}
	}
	return dropped
}

chunk_reassembly_oldest :: proc(reassemblies: ^[dynamic]Chunk_Reassembly) -> int {
	idx := -1
	for i in 0 ..< len(reassemblies) {
		if idx < 0 || reassemblies[i].started_at_ns < reassemblies[idx].started_at_ns do idx = i
	}
	return idx
}

reassemble_chunk :: proc(
	reassemblies: ^[dynamic]Chunk_Reassembly,
	text: string,
	now_ns: i64 = 0,
	max_message_bytes := CHUNK_MAX_MESSAGE_BYTES,
	max_inflight := CHUNK_MAX_INFLIGHT,
	max_count := CHUNK_MAX_COUNT,
	ttl := CHUNK_REASSEMBLY_TTL,
	max_buffered_bytes := CHUNK_MAX_BUFFERED_BYTES,
) -> (assembled: string, complete: bool, ok: bool) {
	chunk_id := jsonx.extract_string(text, "chunk_id", "", top_level_only = true)
	defer delete(chunk_id)
	fragment_b64 := jsonx.extract_string(text, "payload_fragment", "", top_level_only = true)
	defer delete(fragment_b64)
	chunk_index := jsonx.extract_int(text, "chunk_index", -1, top_level_only = true)
	chunk_count := jsonx.extract_int(text, "chunk_count", 0, top_level_only = true)
	total_bytes := jsonx.extract_int(text, "total_bytes", 0, top_level_only = true)

	if chunk_id == "" || len(chunk_id) > 256 || chunk_index < 0 || chunk_count <= 0 || chunk_index >= chunk_count || total_bytes <= 0 || fragment_b64 == "" {
		return "", false, false
	}
	if chunk_count > max_count || chunk_count > total_bytes || total_bytes > max_message_bytes {
		return "", false, false
	}
	decoded, derr := base64.decode(fragment_b64)
	if derr != nil || len(decoded) == 0 do return "", false, false
	defer delete(decoded)
	decoded_text := string(decoded)

	idx := -1
	for i in 0 ..< len(reassemblies) {
		if reassemblies[i].chunk_id == chunk_id { idx = i; break }
	}
	created := idx < 0
	if idx < 0 {
		current_time_ns := now_ns if now_ns > 0 else time.to_unix_nanoseconds(time.now())
		_ = chunk_reassembly_sweep(reassemblies, current_time_ns, ttl)
		reserved := 0
		for r in reassemblies^ do reserved += r.total_bytes
		if len(reassemblies) >= max_inflight || total_bytes > max_buffered_bytes - reserved do return "", false, false
		append(reassemblies, Chunk_Reassembly{
			chunk_id      = strings.clone(chunk_id),
			chunk_count   = chunk_count,
			total_bytes   = total_bytes,
			fragments     = make([]string, chunk_count),
			started_at_ns = current_time_ns,
		})
		idx = len(reassemblies) - 1
	}
	if reassemblies[idx].chunk_count != chunk_count || reassemblies[idx].total_bytes != total_bytes {
		return "", false, false
	}
	if reassemblies[idx].fragments[chunk_index] == "" {
		if reassemblies[idx].received_bytes + len(decoded_text) > reassemblies[idx].total_bytes {
			if created do chunk_reassembly_free(reassemblies, idx)
			return "", false, false
		}
		reassemblies[idx].fragments[chunk_index] = strings.clone(decoded_text)
		reassemblies[idx].received_chunks += 1
		reassemblies[idx].received_bytes += len(decoded_text)
	}
	if reassemblies[idx].received_chunks == reassemblies[idx].chunk_count {
		if reassemblies[idx].received_bytes != reassemblies[idx].total_bytes {
			chunk_reassembly_free(reassemblies, idx)
			return "", false, false
		}
		b := strings.builder_make()
		for frag in reassemblies[idx].fragments {
			strings.write_string(&b, frag)
		}
		out := strings.to_string(b)
		chunk_reassembly_free(reassemblies, idx)
		return out, true, true
	}
	return "", false, true
}

reassemble_chunk_outcome :: proc(
	reassemblies: ^[dynamic]Chunk_Reassembly,
	text: string,
	now_ns: i64 = 0,
	max_message_bytes := CHUNK_MAX_MESSAGE_BYTES,
	max_inflight := CHUNK_MAX_INFLIGHT,
	max_count := CHUNK_MAX_COUNT,
	ttl := CHUNK_REASSEMBLY_TTL,
) -> (outcome: Chunk_Outcome, full_payload: string) {
	if !frame_is_chunk(text) {
		return .Pass_Through, ""
	}
	assembled, complete, ok := reassemble_chunk(reassemblies, text, now_ns, max_message_bytes, max_inflight, max_count, ttl)
	if !ok do return .Dropped, ""
	if complete do return .Completed, assembled
	return .Absorbed, ""
}
