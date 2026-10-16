package contracts

import base64 "core:encoding/base64"
import "core:strings"

// Binary PTY wire frames (REQ-PTY-NET-2).
//
// PTY output and input travel as WebSocket BINARY frames (opcode 0x2) on both hops
// instead of JSON text + base64. Control frames (attach/detach/resize/ready/
// stream_ready/stream_closed/status/error/pane_resync_required/heartbeat) remain JSON
// text frames; a binary frame is always PTY bytes and a text frame never is.
//
//   bridge-ws (bridge<->hub), both directions — "session frame":
//     u8 kind | u8 flags | u16be session_id_len | session_id | payload
//   viewer-ws (hub<->browser), both directions — "viewer frame":
//     u8 kind | u8 flags | [u16be cursor_row | u16be cursor_col]* | payload
//     (*) present only when PTY_WIRE_FLAG_CURSOR is set — a SCREEN frame whose payload
//     is encrypted, so the hub could not prefix the cursor-positioning escape itself and
//     the browser must apply it after decrypting.
//
// kind:
//   PTY_WIRE_KIND_OUTPUT  pty output           bridge->hub, hub->browser
//   PTY_WIRE_KIND_INPUT   keystrokes            browser->hub, hub->bridge
//   PTY_WIRE_KIND_SCREEN  hub pane-capture repaint (absolute, erase+home prefixed)
//                         hub->browser only
// flags:
//   PTY_WIRE_FLAG_SNAPSHOT   payload is a catch-up/screen repaint (viewer must treat it
//                            as an absolute paint and reset its UTF-8 decoder state)
//   PTY_WIRE_FLAG_ENCRYPTED  payload is nonce(12) | tag(16) | AES-256-GCM ciphertext
//                            under the bridge vault key; otherwise raw bytes.
//   PTY_WIRE_FLAG_CURSOR     viewer frame carries the 4-byte cursor block (see above).
//
// There is NO base64 anywhere on this path any more. Anyone adding a `data_b64` field
// back is reintroducing the ~1.33x + JSON envelope this format removed.
//
// Sizing: a session frame must fit the bridge->hub per-message cap WITHOUT the kind:"chunk"
// re-splitter (which is text/base64-only and would reintroduce the overhead). The bridge
// chooses its emit cap from the transport (bridge_pty_stream_emit_caps). The chunker in
// lib/ws/chunk.odin therefore never sees a binary frame — by construction, not by check.

PTY_WIRE_KIND_OUTPUT :: u8(0x01)
PTY_WIRE_KIND_INPUT  :: u8(0x02)
PTY_WIRE_KIND_SCREEN :: u8(0x03)

PTY_WIRE_FLAG_SNAPSHOT  :: u8(0x01)
PTY_WIRE_FLAG_ENCRYPTED :: u8(0x02)
PTY_WIRE_FLAG_CURSOR    :: u8(0x04)

PTY_WIRE_SESSION_HEADER_BYTES :: 4
PTY_WIRE_VIEWER_HEADER_BYTES  :: 2
PTY_WIRE_VIEWER_CURSOR_BYTES  :: 4
PTY_WIRE_MAX_SESSION_ID_BYTES :: 0xFFFF

pty_wire_flags :: proc(snapshot, encrypted: bool) -> u8 {
	f: u8 = 0
	if snapshot do f |= PTY_WIRE_FLAG_SNAPSHOT
	if encrypted do f |= PTY_WIRE_FLAG_ENCRYPTED
	return f
}

pty_wire_is_snapshot  :: proc(flags: u8) -> bool { return flags & PTY_WIRE_FLAG_SNAPSHOT != 0 }
pty_wire_is_encrypted :: proc(flags: u8) -> bool { return flags & PTY_WIRE_FLAG_ENCRYPTED != 0 }

// pty_wire_session_frame_len is the on-wire size of a session frame for a payload.
pty_wire_session_frame_len :: proc(session_id: string, payload_len: int) -> int {
	return PTY_WIRE_SESSION_HEADER_BYTES + len(session_id) + payload_len
}

// pty_wire_encode_session_frame builds a bridge-ws binary frame. Caller owns the result.
// Returns nil when the session id does not fit a u16.
pty_wire_encode_session_frame :: proc(kind, flags: u8, session_id: string, payload: []byte, allocator := context.allocator) -> []byte {
	if len(session_id) > PTY_WIRE_MAX_SESSION_ID_BYTES do return nil
	out := make([]byte, pty_wire_session_frame_len(session_id, len(payload)), allocator)
	out[0] = kind
	out[1] = flags
	out[2] = byte(len(session_id) >> 8)
	out[3] = byte(len(session_id))
	copy(out[4:], transmute([]byte)session_id)
	copy(out[4 + len(session_id):], payload)
	return out
}

// pty_wire_decode_session_frame parses a bridge-ws binary frame. The returned
// session_id and payload BORROW from `frame`.
pty_wire_decode_session_frame :: proc(frame: []byte) -> (kind, flags: u8, session_id: string, payload: []byte, ok: bool) {
	if len(frame) < PTY_WIRE_SESSION_HEADER_BYTES do return 0, 0, "", nil, false
	sid_len := int(frame[2]) << 8 | int(frame[3])
	if sid_len == 0 || len(frame) < PTY_WIRE_SESSION_HEADER_BYTES + sid_len do return 0, 0, "", nil, false
	kind = frame[0]
	flags = frame[1]
	session_id = string(frame[4:4 + sid_len])
	payload = frame[4 + sid_len:]
	return kind, flags, session_id, payload, true
}

// pty_wire_encode_viewer_frame builds a viewer-ws binary frame. Caller owns the result.
// cursor_row/cursor_col >= 0 (both) adds the cursor block and sets PTY_WIRE_FLAG_CURSOR.
pty_wire_encode_viewer_frame :: proc(kind, flags: u8, payload: []byte, cursor_row := -1, cursor_col := -1, allocator := context.allocator) -> []byte {
	has_cursor := cursor_row >= 0 && cursor_col >= 0 && cursor_row <= 0xFFFF && cursor_col <= 0xFFFF
	extra := PTY_WIRE_VIEWER_CURSOR_BYTES if has_cursor else 0
	out := make([]byte, PTY_WIRE_VIEWER_HEADER_BYTES + extra + len(payload), allocator)
	out[0] = kind
	out[1] = flags | (PTY_WIRE_FLAG_CURSOR if has_cursor else 0)
	off := PTY_WIRE_VIEWER_HEADER_BYTES
	if has_cursor {
		out[2] = byte(cursor_row >> 8)
		out[3] = byte(cursor_row)
		out[4] = byte(cursor_col >> 8)
		out[5] = byte(cursor_col)
		off += PTY_WIRE_VIEWER_CURSOR_BYTES
	}
	copy(out[off:], payload)
	return out
}

// pty_wire_decode_viewer_frame parses a viewer-ws binary frame; payload BORROWS from
// `frame`. cursor_row/cursor_col are -1 when the frame carries no cursor block.
pty_wire_decode_viewer_frame :: proc(frame: []byte) -> (kind, flags: u8, payload: []byte, cursor_row, cursor_col: int, ok: bool) {
	if len(frame) < PTY_WIRE_VIEWER_HEADER_BYTES do return 0, 0, nil, -1, -1, false
	kind = frame[0]
	flags = frame[1]
	off := PTY_WIRE_VIEWER_HEADER_BYTES
	cursor_row, cursor_col = -1, -1
	if flags & PTY_WIRE_FLAG_CURSOR != 0 {
		if len(frame) < PTY_WIRE_VIEWER_HEADER_BYTES + PTY_WIRE_VIEWER_CURSOR_BYTES do return 0, 0, nil, -1, -1, false
		cursor_row = int(frame[2]) << 8 | int(frame[3])
		cursor_col = int(frame[4]) << 8 | int(frame[5])
		off += PTY_WIRE_VIEWER_CURSOR_BYTES
	}
	return kind, flags, frame[off:], cursor_row, cursor_col, true
}

// pty_wire_viewer_frame_is_incremental_output: the queue class the hub's per-viewer
// writer uses (incremental output has the tightest bound; snapshot/screen a larger one).
pty_wire_viewer_frame_is_incremental_output :: proc(frame: []byte) -> bool {
	kind, flags, _, _, _, ok := pty_wire_decode_viewer_frame(frame)
	if !ok do return false
	return kind == PTY_WIRE_KIND_OUTPUT && !pty_wire_is_snapshot(flags)
}

// pty_wire_viewer_frame_debug_json renders a viewer frame in the shape of the JSON frame
// it replaced ({"type":"output"|"screen","data_b64":...,"is_encrypted":...,...}). For
// logs and tests only — nothing on the wire is JSON any more.
pty_wire_viewer_frame_debug_json :: proc(frame: []byte, allocator := context.allocator) -> string {
	kind, flags, payload, cursor_row, cursor_col, ok := pty_wire_decode_viewer_frame(frame)
	if !ok do return strings.clone("{\"type\":\"invalid_binary_frame\"}", allocator)
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"type\":\"")
	switch kind {
	case PTY_WIRE_KIND_OUTPUT: strings.write_string(&b, "output")
	case PTY_WIRE_KIND_SCREEN: strings.write_string(&b, "screen")
	case PTY_WIRE_KIND_INPUT:  strings.write_string(&b, "input")
	case:                      strings.write_string(&b, "unknown")
	}
	strings.write_string(&b, "\",\"data_b64\":\"")
	b64 := base64.encode(payload, allocator = context.temp_allocator)
	strings.write_string(&b, string(b64))
	strings.write_string(&b, "\",\"is_encrypted\":")
	strings.write_string(&b, "true" if pty_wire_is_encrypted(flags) else "false")
	if pty_wire_is_snapshot(flags) do strings.write_string(&b, ",\"is_snapshot\":true")
	if cursor_row >= 0 { strings.write_string(&b, ",\"cursor_row\":"); strings.write_int(&b, cursor_row) }
	if cursor_col >= 0 { strings.write_string(&b, ",\"cursor_col\":"); strings.write_int(&b, cursor_col) }
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// pty_wire_session_frame_debug_json renders a bridge-ws session frame in the shape of the
// JSON command it replaced ({"type":"pty_input"|"pty_output","session_id":...,
// "data_b64":...,"is_encrypted":...}). Logs and tests only.
pty_wire_session_frame_debug_json :: proc(frame: []byte, allocator := context.allocator) -> string {
	kind, flags, session_id, payload, ok := pty_wire_decode_session_frame(frame)
	if !ok do return strings.clone("{\"type\":\"invalid_binary_frame\"}", allocator)
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"type\":\"")
	switch kind {
	case PTY_WIRE_KIND_OUTPUT: strings.write_string(&b, "pty_output")
	case PTY_WIRE_KIND_INPUT:  strings.write_string(&b, "pty_input")
	case PTY_WIRE_KIND_SCREEN: strings.write_string(&b, "pty_screen")
	case:                      strings.write_string(&b, "unknown")
	}
	strings.write_string(&b, "\",\"session_id\":\"")
	write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"data_b64\":\"")
	b64 := base64.encode(payload, allocator = context.temp_allocator)
	strings.write_string(&b, string(b64))
	strings.write_string(&b, "\",\"is_encrypted\":")
	strings.write_string(&b, "true" if pty_wire_is_encrypted(flags) else "false")
	if pty_wire_is_snapshot(flags) do strings.write_string(&b, ",\"is_snapshot\":true")
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// pty_screen_split_preamble separates the terminal-colour preamble the pty-host puts in
// front of a captured screen (tools/pty_host/src/vt.rs capture(): OSC 4/10/11/12
// sequences, BEL- or ST-terminated) from the rows that follow. Both halves BORROW from
// `text`. A repaint builder must keep the preamble FIRST — before any alt-screen prefix
// and before the erase-screen+home it adds — and must never let it be trimmed as a
// "blank row": that is exactly how the pane reverted to the UI theme after a repaint.
pty_screen_split_preamble :: proc(text: string) -> (preamble, rest: string) {
	i := 0
	for i + 1 < len(text) && text[i] == 0x1b && text[i + 1] == ']' {
		// Find the terminator: BEL (0x07) or ST (ESC \\).
		j := i + 2
		end := -1
		for j < len(text) {
			if text[j] == 0x07 { end = j + 1; break }
			if text[j] == 0x1b && j + 1 < len(text) && text[j + 1] == '\\' { end = j + 2; break }
			if text[j] == 0x1b do break // another escape started: not a terminated OSC
			j += 1
		}
		if end < 0 do break
		// Only the colour family is a preamble; anything else (a title) stays with the rows.
		body := text[i + 2:end]
		is_color := strings.has_prefix(body, "4;") || strings.has_prefix(body, "10;") || strings.has_prefix(body, "11;") || strings.has_prefix(body, "12;")
		if !is_color do break
		i = end
	}
	return text[:i], text[i:]
}
