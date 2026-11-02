package ws

// Server->client WebSocket text framing, shared by the hub's writers.
//
// REQ-SHELL-33. Every hub-side writer used to open with `if n > 65535 do return
// false`: the RFC 6455 126/2-byte extended length was implemented and the 127/8-byte
// one was not, so any larger payload was DROPPED, silently, on a bool that most
// callers ignore and that the one caller which did inspect it read as "the peer is
// dead". This is that missing protocol case, written once.
//
// TWO THINGS THIS FIXES BEYOND THE MISSING ARM:
//
//  1. THE RESULT IS TYPED. "I could not encode this frame" and "this socket is gone"
//     are different conditions with different recovery, and a bool cannot tell them
//     apart. shell_session_broadcast_output detaching a healthy viewer over an
//     oversized frame is exactly what collapsing them costs.
//
//  2. SHORT WRITES ARE HANDLED. core/net's _send_tcp returns on the first errno with
//     a possibly NON-ZERO total_written, so `_, err := net.send_tcp(...)` can leave
//     HALF A FRAME on the wire and report success-or-failure with no way to tell.
//     A peer that has read half a frame misparses it and every byte after it: the
//     stream is desynchronised permanently. That is worse than dropping the frame,
//     and .Desynchronised names it so the caller can end the session instead of
//     serving corruption. (lsp_write_ws_text_frame_counted reached the same
//     conclusion for the LSP socket; this generalises it.)
//
// WHY allow_64bit IS A PARAMETER AND NOT A CONSTANT. The two peer kinds cannot take
// the same answer:
//   - A BROWSER parses a 127-length frame correctly. It gets the 64-bit arm.
//   - OUR OWN READERS DO NOT. `take_text` in ws.odin drops the connection on a 127
//     length, and the hub's bridge_ws_take_frame returns fatal=true on it. Emitting
//     one toward a bridge would convert a dropped frame into a KILLED bridge
//     connection — strictly worse than the bug. The hub<->bridge channel keeps its
//     16-bit bound on purpose: it already chunks at the APPLICATION level (kind:
//     "chunk") precisely so no frame reaches the cap.
// Passing it at the call site makes that a stated property of each channel rather
// than an assumption buried in a writer.

// WHERE THIS DIVERGES FROM ITS PRIOR ART. lsp_write_ws_text_frame_counted
// (lsp_session_handlers.odin) already solved the same two problems for the LSP socket
// and this generalises it. Four deliberate differences:
//   1. A TYPED RESULT, not (sent, ok). The byte count drives no production decision —
//      lsp_registry_deliver branches on ok and uses `sent` only in its comment — and
//      what the count was actually being read for, "is a partial frame on the wire",
//      is what .Desynchronised says directly.
//   2. allow_64bit IS A PARAMETER. LSP has exactly one peer kind (a browser) so it can
//      hardcode the arm; this writer serves both kinds. See above.
//   3. AN EXPLICIT CAP. LSP has none; a hub-side buffer sized by a remote pane needs one.
//   4. A TOTAL WRITE DEADLINE, shared with the client and TLS pipe writers.

import "core:net"
import "core:time"

// WS_16BIT_MAX_PAYLOAD is the largest payload the 126/2-byte extended length can
// describe, and therefore the hard bound on any channel whose reader stops there.
WS_16BIT_MAX_PAYLOAD :: 65535

// WS_MAX_SERVER_PAYLOAD bounds the 64-bit arm. RFC 6455 allows 2^63-1; we do not,
// because the frame is built in ONE contiguous allocation and a bound nobody
// enforces is how "it fits in a u64" becomes an unbounded allocation driven by a
// remote pane size. 16 MiB is ~2 orders of magnitude above the largest thing that
// travels here (a wide, fully-coloured screen capture runs to a few hundred KB),
// so it is a backstop against the absurd, not a limit anything real meets.
WS_MAX_SERVER_PAYLOAD :: 16 * 1024 * 1024
WS_MAX_HEADER_BYTES   :: 10

// Text_Write_Result is what a frame write actually has to say. Only the last two
// mean the socket is finished; see the note above on why that distinction matters.
Text_Write_Result :: enum {
	Ok,             // the whole frame reached the socket
	Too_Large,      // refused BEFORE any byte went out — the socket is untouched and still healthy
	Peer_Gone,      // nothing was written; the peer is unreachable
	Desynchronised, // a PARTIAL frame is on the wire; this peer's stream can never resynchronise
}

// server_frame_header_len reports how many bytes server_frame_header will use for a
// payload of n bytes.
server_frame_header_len :: proc(n: int) -> int {
	switch {
	case n <= 125:                  return 2
	case n <= WS_16BIT_MAX_PAYLOAD: return 4
	case:                           return 10
	}
}

// server_frame_header_with_opcode writes an unmasked FIN frame header with a specific opcode.
server_frame_header_with_opcode :: proc(out: []byte, opcode: u8, n: int) -> int {
	out[0] = 0x80 | (opcode & 0x0f)
	switch {
	case n <= 125:
		out[1] = byte(n)
		return 2
	case n <= WS_16BIT_MAX_PAYLOAD:
		out[1] = 126
		out[2] = byte((n >> 8) & 0xff)
		out[3] = byte(n & 0xff)
		return 4
	case:
		out[1] = 127
		// 64-bit big-endian length. RFC 6455 requires the high bit clear, which holds
		// because n is bounded by WS_MAX_SERVER_PAYLOAD above.
		for i in 0 ..< 8 {
			out[2 + i] = byte((u64(n) >> uint(8 * (7 - i))) & 0xff)
		}
		return 10
	}
}

// server_frame_header writes the unmasked FIN+text frame header for a payload of n
// bytes into out, returning how many bytes it used. Split out from the socket write
// so all three length encodings are testable without a socket.
server_frame_header :: proc(out: []byte, n: int) -> int {
	return server_frame_header_with_opcode(out, 0x1, n)
}

// write_server_opcode_counted writes one frame with a specific opcode and reports
// both how many bytes went out and the typed result.
write_server_opcode_counted :: proc(socket: net.TCP_Socket, opcode: u8, text: string, allow_64bit: bool, timeout:time.Duration=WRITE_DEADLINE) -> (sent: int, res: Text_Write_Result) {
	n := len(text)
	limit := WS_16BIT_MAX_PAYLOAD
	if allow_64bit do limit = WS_MAX_SERVER_PAYLOAD
	// Refused before allocating or touching the socket: Too_Large is a statement
	// about THIS FRAME and never about the connection.
	if n > limit do return 0, .Too_Large

	header_len := server_frame_header_len(n)
	frame := make([]byte, header_len + n)
	defer delete(frame)
	server_frame_header_with_opcode(frame[:header_len], opcode, n)
	copy(frame[header_len:], transmute([]byte)text)

	ok: bool
	sent, ok = send_socket_bytes(socket, frame,timeout)
	if ok do return sent, .Ok
	if sent == 0 do return 0, .Peer_Gone
	return sent, .Desynchronised
}

// write_server_opcode writes one frame with a specific opcode and says what happened.
write_server_opcode :: proc(socket: net.TCP_Socket, opcode: u8, text: string, allow_64bit: bool) -> Text_Write_Result {
	_, res := write_server_opcode_counted(socket, opcode, text, allow_64bit)
	return res
}

// write_server_text_counted writes one text frame and reports how many bytes were written
// alongside the write result.
write_server_text_counted :: proc(socket: net.TCP_Socket, text: string, allow_64bit: bool = false) -> (sent: int, res: Text_Write_Result) {
	return write_server_opcode_counted(socket, 0x1, text, allow_64bit)
}

// write_server_text writes one text frame and says what happened. It never returns
// Ok on a partial write.
//
// allow_64bit must be true only for peers that parse a 127 length — see the header
// note. With it false the effective payload bound is WS_16BIT_MAX_PAYLOAD; with it
// true, WS_MAX_SERVER_PAYLOAD.
write_server_text :: proc(socket: net.TCP_Socket, text: string, allow_64bit: bool) -> Text_Write_Result {
	return write_server_opcode(socket, 0x1, text, allow_64bit)
}

