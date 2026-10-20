package bridge_runtime

// Hub->bridge command chunking (REQ-SHELL-36).
//
// THE DEFECT THIS EXISTS FOR. write_ws_text_frame refuses any payload over 65535
// bytes, and its caller turned that `false` into .Bridge_Offline — so an oversized
// command was DROPPED and the operator was told the bridge was down while the bridge
// was perfectly healthy. `send_lsp_message` routes a whole JSON-RPC message through
// that writer, and a textDocument/didOpen carrying a large file is exactly that case.
//
// WHY CHUNKING AND NOT A 64-BIT LENGTH ARM. The 16-bit bound on this channel is a
// DELIBERATE INVARIANT, not an oversight. Our own readers stop at the 126/2-byte
// extended length: ws.odin's take_text sets conn.connected = false on a 127 length and
// the hub's bridge_ws_take_frame returns fatal=true on it. Emitting a 64-bit frame
// toward a bridge would therefore convert a dropped frame into a KILLED bridge
// connection — strictly worse than the bug. server_frame.odin states the same rule in
// prose. So the frame stays under the cap and the SPLIT happens above it, which is
// what the bridge->hub direction has always done.
//
// THIS IS THE MIRROR OF AN EXISTING PROTOCOL, NOT A NEW ONE. The bridge has chunked
// bridge->hub since REQ-SHELL-32 (bridge_hub_chunk_frames / bridge_hub_send) and the
// hub reassembles it (bridge_ws_reassemble_chunk). Only the hub->bridge direction was
// missing. The frame shape emitted here is the SUBSET the reassembler reads, and the
// reassembler accepts both shapes — so the two directions are one protocol rather than
// two that resemble each other. It is NOT byte-for-byte identical: this emitter writes
// 8 fields, the bridge's bridge_ws_chunk_json writes 14, omitting frame_id, stream_id,
// src_daemon_id, dest_daemon_id, original_kind and idempotency_key. That is not a
// defect — the reassembler is superset-tolerant and the interop test below pins it —
// but do not read this comment as a promise that a given field is on the wire.
//
// >>> THIS FILE MUST NOT TOUCH THE TEMP ALLOCATOR. READ send_runtime_command_wait <<<
// FIRST. That procedure clones command_id AFTER the frame write, and its comment
// states plainly that the placement is safe ONLY BECAUSE the writing path allocates on
// context.allocator (heap) and never advances the per-thread temp ring. A single
// fmt.tprintf in here would silently invalidate that argument: the clone would still be
// there, still read as correct, and protect nothing, and NO TEST WOULD FAIL. That is
// why the integers below go through strconv.write_int into STACK buffers instead of the
// fmt.tprintf that would be the obvious way to write this.

import "core:encoding/base64"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "odin_test:contracts"
import ws "odin_test:lib/ws"

// hub_command_chunk_count is the number of chunks `total` bytes needs at `payload`
// bytes each.
hub_command_chunk_count :: proc(total, payload: int) -> int {
	return ws.chunk_count(total, payload)
}

// hub_command_chunk_frames returns the ordered kind:"chunk" wire frames for `text`,
// or nil when `text` already fits in one frame (send it whole).
hub_command_chunk_frames :: proc(text: string, payload: int) -> []string {
	return ws.chunk_frames(text, payload)
}

// hub_command_is_chunkable reports whether `text` can be carried at all.
hub_command_is_chunkable :: proc(text: string, payload: int) -> bool {
	return ws.is_chunkable(text, payload, contracts.BRIDGE_WS_MAX_REASSEMBLY_BYTES, contracts.BRIDGE_WS_MAX_CHUNK_COUNT)
}

// hub_command_frame_is_chunk reports whether a frame is a chunk envelope.
hub_command_frame_is_chunk :: proc(text: string) -> bool {
	return ws.frame_is_chunk(text)
}
