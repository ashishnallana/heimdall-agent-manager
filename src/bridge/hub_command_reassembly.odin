package main

// Bridge-side reassembly of chunked hub->bridge COMMANDS (REQ-SHELL-36, unified in REQ-WS-UNIFY-1).
// Delegates directly to the canonical ws.Chunk_Reassembly implementation in src/lib/ws/chunk.odin.

import "core:time"
import ws "odin_test:lib/ws"

Hub_Command_Reassembly :: ws.Chunk_Reassembly
HUB_COMMAND_REASSEMBLY_TTL :: ws.CHUNK_REASSEMBLY_TTL

hub_command_reassemblies_free :: proc(buf: ^[dynamic]Hub_Command_Reassembly) {
	ws.chunk_reassemblies_free(buf)
}

hub_command_reassembly_sweep :: proc(buf: ^[dynamic]Hub_Command_Reassembly, now_ns: i64) -> int {
	return ws.chunk_reassembly_sweep(buf, now_ns)
}

hub_command_frame_is_chunk :: proc(text: string) -> bool {
	return ws.frame_is_chunk(text)
}

hub_command_reassemble :: proc(buf: ^[dynamic]Hub_Command_Reassembly, text: string) -> (assembled: string, complete: bool, ok: bool) {
	return ws.reassemble_chunk(buf, text)
}
