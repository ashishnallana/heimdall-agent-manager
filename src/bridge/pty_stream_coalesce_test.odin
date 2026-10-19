#+build !windows
package main

// REQ-PTY-NET-1 — coalescing in the bridge pty drain.
//
// The queue holds PLAINTEXT records; the drain folds adjacent records of one session into
// one wire frame and encrypts once per merged frame. These tests pin the four properties
// that make that safe: order is preserved, boundaries (session / snapshot / control frame)
// are respected, the per-frame cap is respected, and an encrypted merged frame still
// round-trips through the chunk decryptor.

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"
import ws "odin_test:lib/ws"
import vault "odin_test:lib/vault"

// _p1_unlock_vault gives the process a keyring (there is no plaintext stream mode),
// so every output record is sealed and the helpers below decrypt it.
@(private = "file")
_p1_unlock_vault :: proc() -> (prev_key: string, had_key: bool) {
	prev_key, had_key = os.lookup_env("HEIMDALL_VAULT_KEYRING", context.allocator)
	_ = os.set_env("HEIMDALL_VAULT_KEYRING", test_keyring_env_value(TEST_ENC_VAULT_KEY))
	return
}

@(private = "file")
_p1_restore_vault :: proc(prev_key: string, had_key: bool) {
	if had_key { _ = os.set_env("HEIMDALL_VAULT_KEYRING", prev_key); delete(prev_key) } else { os.unset_env("HEIMDALL_VAULT_KEYRING") }
}

// pty_test_decode_output decodes one bridge->hub pty_wire OUTPUT frame as the hub would
// (REQ-PTY-NET-2), decrypting with `key_hex` when the frame says it is encrypted. The
// payload is temp-allocated. Package-visible: every pty stream test reads frames through it.
pty_test_decode_output :: proc(frame: string, key_hex := "") -> (session_id: string, payload: string, snapshot, encrypted, ok: bool) {
	kind, flags, sid, body, dok := contracts.pty_wire_decode_session_frame(transmute([]byte)frame)
	if !dok || kind != contracts.PTY_WIRE_KIND_OUTPUT do return "", "", false, false, false
	snapshot = contracts.pty_wire_is_snapshot(flags)
	encrypted = contracts.pty_wire_is_encrypted(flags)
	if encrypted {
		if key_hex == "" do return sid, "", snapshot, encrypted, true
		kr := test_keyring_from_hex(key_hex)
		defer vault.keyring_wipe(&kr)
		plain, _, _, pok := vault.pty_open(body, &kr, sid, .Out, 0, "", context.temp_allocator)
		if !pok do return sid, "", snapshot, encrypted, false
		return sid, string(plain), snapshot, encrypted, true
	}
	return sid, string(body), snapshot, encrypted, true
}

// pty_test_frame_is_output says whether a drained frame is a binary pty output frame
// (as opposed to a JSON control frame).
pty_test_frame_is_output :: proc(frame: string) -> bool {
	_, _, _, _, ok := pty_test_decode_output(frame)
	return ok
}

@(private = "file")
_p1_payload :: proc(frame: string) -> string {
	_, payload, _, _, _ := pty_test_decode_output(frame, TEST_ENC_VAULT_KEY)
	return payload
}

@(private = "file")
_p1_session :: proc(frame: string) -> string {
	sid, _, _, _, _ := pty_test_decode_output(frame, TEST_ENC_VAULT_KEY)
	return sid
}

@(private = "file")
_p1_snapshot :: proc(frame: string) -> bool {
	_, _, snap, _, _ := pty_test_decode_output(frame, TEST_ENC_VAULT_KEY)
	return snap
}

@(test)
pty_drain_merges_adjacent_same_session_records_in_order :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()
	pk, hk := _p1_unlock_vault()
	defer _p1_restore_vault(pk, hk)

	mw := Bridge_PTY_Stream_Worker{active = true, fd = -1}
	for i in 0 ..< 20 {
		chunk := strings.repeat("x", 150, context.temp_allocator)
		buf := strings.concatenate({chunk, "|"}, context.temp_allocator)
		buf_bytes := transmute([]byte)buf
		buf_bytes[0] = byte('a' + i)
		bridge_pty_stream_emit_frame(&mw, "sh_merge", buf_bytes)
	}
	testing.expect_value(t, bridge_pty_stream_queued_frames(), 20)
	frames := bridge_pty_stream_take_outgoing()
	defer { for f in frames do delete(f, runtime.heap_allocator()); delete(frames) }
	testing.expect_value(t, len(frames), 1)
	if len(frames) != 1 do return
	payload := _p1_payload(frames[0])
	testing.expect_value(t, len(payload), 20 * 151)
	// Order: the first byte of every 151-byte run counts up a..t.
	for i in 0 ..< 20 do testing.expect_value(t, payload[i * 151], byte('a' + i))
	testing.expect(t, !_p1_snapshot(frames[0]), "incremental merge is not a snapshot")
	testing.expect_value(t, bridge_pty_stream_outgoing_bytes, 0)
}

@(test)
pty_drain_never_merges_across_session_snapshot_or_control_boundaries :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()
	pk, hk := _p1_unlock_vault()
	defer _p1_restore_vault(pk, hk)

	w := Bridge_PTY_Stream_Worker{active = true, fd = -1}
	bridge_pty_stream_emit_frame(&w, "A", transmute([]byte)string("a1"))
	bridge_pty_stream_emit_frame(&w, "A", transmute([]byte)string("a2"))
	bridge_pty_stream_emit_frame(&w, "B", transmute([]byte)string("b1"))   // session boundary
	bridge_pty_stream_emit_frame(&w, "A", transmute([]byte)string("a3"))   // not adjacent to a1/a2
	w.emitting_snapshot = true
	bridge_pty_stream_emit_frame(&w, "A", transmute([]byte)string("S1"))   // snapshot boundary
	bridge_pty_stream_emit_frame(&w, "A", transmute([]byte)string("S2"))
	w.emitting_snapshot = false
	bridge_pty_stream_emit_lifecycle_event(&w, "shell_pty_stream_ready", "A", "A") // control boundary
	bridge_pty_stream_emit_frame(&w, "A", transmute([]byte)string("a4"))
	bridge_pty_stream_emit_frame(&w, "A", transmute([]byte)string("a5"))

	frames := bridge_pty_stream_take_outgoing()
	defer { for f in frames do delete(f, runtime.heap_allocator()); delete(frames) }
	testing.expect_value(t, len(frames), 6)
	if len(frames) != 6 do return
	testing.expect_value(t, _p1_payload(frames[0]), "a1a2")
	testing.expect_value(t, _p1_session(frames[0]), "A")
	testing.expect_value(t, _p1_payload(frames[1]), "b1")
	testing.expect_value(t, _p1_payload(frames[2]), "a3")
	testing.expect_value(t, _p1_payload(frames[3]), "S1S2")
	testing.expect(t, _p1_snapshot(frames[3]), "merged snapshot keeps the flag")
	testing.expect(t, strings.contains(frames[4], `"type":"shell_pty_stream_ready"`), "control frame stays in place")
	testing.expect_value(t, _p1_payload(frames[5]), "a4a5")
}

@(test)
pty_drain_respects_the_per_frame_byte_cap :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()
	pk, hk := _p1_unlock_vault()
	defer _p1_restore_vault(pk, hk)

	// 5 x 5 KiB = 25 KiB incremental: fits in 12 KiB frames as 10 + 10 + 5.
	cw := Bridge_PTY_Stream_Worker{active = true, fd = -1}
	chunk := strings.repeat("y", 5 * 1024, context.temp_allocator)
	for _ in 0 ..< 5 do bridge_pty_stream_emit_frame(&cw, "sh_cap", transmute([]byte)chunk)
	frames := bridge_pty_stream_take_outgoing()
	defer { for f in frames do delete(f, runtime.heap_allocator()); delete(frames) }
	testing.expect_value(t, len(frames), 3)
	total := 0
	for f in frames {
		n := len(_p1_payload(f))
		testing.expect(t, n <= BRIDGE_PTY_STREAM_EMIT_INCREMENTAL_BYTES, "merged frame within the incremental cap")
		total += n
	}
	testing.expect_value(t, total, 5 * 5 * 1024)

	// A single oversized emit is split at enqueue, never dropped.
	big := strings.repeat("z", 30 * 1024, context.temp_allocator)
	bridge_pty_stream_emit_frame(&cw, "sh_big", transmute([]byte)big)
	frames2 := bridge_pty_stream_take_outgoing()
	defer { for f in frames2 do delete(f, runtime.heap_allocator()); delete(frames2) }
	testing.expect_value(t, len(frames2), 3) // 12 + 12 + 6
	// Every frame — payload, header and session id — stays under the 16 KiB edge ceiling.
	for f in frames2 do testing.expect(t, len(f) < 16 * 1024, "wire frame under the edge-proxy per-message ceiling")
}

@(test)
pty_drain_encrypts_once_per_merged_frame_and_round_trips :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()
	prev_key, found := os.lookup_env("HEIMDALL_VAULT_KEYRING", context.allocator)
	defer { if found { _ = os.set_env("HEIMDALL_VAULT_KEYRING", prev_key); delete(prev_key) } else { os.unset_env("HEIMDALL_VAULT_KEYRING") } }
	_ = os.set_env("HEIMDALL_VAULT_KEYRING", test_keyring_env_value(TEST_ENC_VAULT_KEY))

	w := Bridge_PTY_Stream_Worker{active = true, fd = -1}
	bridge_pty_stream_emit_frame(&w, "sh_enc", transmute([]byte)string("hello "))
	bridge_pty_stream_emit_frame(&w, "sh_enc", transmute([]byte)string("merged "))
	bridge_pty_stream_emit_frame(&w, "sh_enc", transmute([]byte)string("world\r\n"))
	testing.expect_value(t, w.seq, u64(3)) // three nonces reserved at enqueue

	frames := bridge_pty_stream_take_outgoing()
	defer { for f in frames do delete(f, runtime.heap_allocator()); delete(frames) }
	testing.expect_value(t, len(frames), 1)
	if len(frames) != 1 do return
	_, plain, _, encrypted, ok := pty_test_decode_output(frames[0], TEST_ENC_VAULT_KEY)
	testing.expect(t, encrypted, "frame is flagged encrypted")
	testing.expect(t, ok, "merged ciphertext decrypts with one GCM header")
	testing.expect_value(t, plain, "hello merged world\r\n")
	// The merged frame carries the FIRST record's nonce (seq 1); nothing is reused.
	_, _, _, body, _ := contracts.pty_wire_decode_session_frame(transmute([]byte)frames[0])
	_, counter, _ := vault.pty_frame_salt_counter(body)
	testing.expect_value(t, counter, u64(1))
	// And the wire frame carries NO base64 and NO JSON: header + 48 B PTY v2 header + plaintext length.
	testing.expect_value(t, len(frames[0]), contracts.PTY_WIRE_SESSION_HEADER_BYTES + len("sh_enc") + vault.PTY_V2_HEADER_BYTES + len(plain))
}

// REQ-PTY-NET-7: the s_client "double base64" is moot for pty output — a binary frame never
// meets the text chunker. Under the legacy 6000 B cap the emit shrinks to 4 KiB so the
// LARGEST possible frame (cap + 256 B session id + GCM header + pty_wire header) still fits
// whole; under socat the 12 KiB emits fit the 45000 B cap AND the 16 KiB edge ceiling.
@(test)
pty_binary_frames_fit_every_transport_cap_without_the_chunker :: proc(t: ^testing.T) {
	incr_s, snap_s := bridge_pty_stream_emit_caps_for(contracts.BRIDGE_WS_HUB_RUNTIME_CHUNK_PAYLOAD_BYTES)
	testing.expect_value(t, incr_s, BRIDGE_PTY_STREAM_EMIT_SCLIENT_BYTES)
	testing.expect_value(t, snap_s, BRIDGE_PTY_STREAM_EMIT_SCLIENT_BYTES)
	long_sid := strings.repeat("s", 256, context.temp_allocator)
	worst := contracts.pty_wire_session_frame_len(long_sid, snap_s + vault.PTY_V2_HEADER_BYTES)
	testing.expect(t, worst <= contracts.BRIDGE_WS_HUB_RUNTIME_CHUNK_PAYLOAD_BYTES, "worst-case s_client frame fits the 6000 B cap whole")
	// And it is not chunkable material anyway: chunk_frames would only split TEXT above the cap.
	testing.expect(t, ws.chunk_frames(strings.repeat("x", worst, context.temp_allocator), contracts.BRIDGE_WS_HUB_RUNTIME_CHUNK_PAYLOAD_BYTES) == nil, "a frame of that size never reaches the chunker")

	incr_c, snap_c := bridge_pty_stream_emit_caps_for(contracts.BRIDGE_WS_HUB_RUNTIME_CHUNK_PAYLOAD_BYTES_SOCAT)
	testing.expect_value(t, incr_c, BRIDGE_PTY_STREAM_EMIT_EDGE_SAFE_BYTES)
	testing.expect_value(t, snap_c, BRIDGE_PTY_STREAM_EMIT_EDGE_SAFE_BYTES)
	worst_c := contracts.pty_wire_session_frame_len(long_sid, snap_c + vault.PTY_V2_HEADER_BYTES) + 8 /* ws header */
	testing.expect(t, worst_c < 16 * 1024, "worst-case socat frame stays under the edge-proxy per-message ceiling")
}

// REQ-PTY-COLOR-1: the pty-host's colour preamble (OSC 10/11/12/4) leads the catch-up
// payload — before the alt-screen prefix and the erase+home, after nothing — and
// survives trailing-blank trimming and an all-blank screen.
@(test)
pty_screen_preamble_leads_catchup_and_survives_trimming :: proc(t: ^testing.T) {
	pre := "\x1b]4;1;rgb:ff/00/00\x07\x1b]11;#1e1e2e\x07"
	// Preamble sits in row 0 exactly as capture() emits it (before the alt prefix).
	alt := bridge_pty_stream_screen_payload({strings.concatenate({pre, "\x1b[?1049h\x1b[?25l~"}, context.temp_allocator), "-- NORMAL --", "", ""}, 1, 0)
	defer delete(alt)
	testing.expect_value(t, alt, strings.concatenate({pre, "\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H~\r\n-- NORMAL --\x1b[2;1H"}, context.temp_allocator))

	plain := bridge_pty_stream_screen_payload({strings.concatenate({pre, "$ "}, context.temp_allocator), "", ""}, 0, 2)
	defer delete(plain)
	testing.expect_value(t, plain, strings.concatenate({pre, "$ \x1b[1;3H"}, context.temp_allocator))

	// All-blank rows: the trim would reduce the rows to nothing; the preamble must remain.
	blank := bridge_pty_stream_screen_payload({pre, "", ""}, -1, -1)
	defer delete(blank)
	testing.expect_value(t, blank, pre)

	// No preamble: byte-identical to before (the common case).
	none := bridge_pty_stream_screen_payload({"row 1", "row 2", ""}, -1, -1)
	defer delete(none)
	testing.expect_value(t, none, "row 1\r\nrow 2")

	// The splitter leaves titles and ST-terminated non-colour OSCs with the rows.
	p, rest := contracts.pty_screen_split_preamble("\x1b]11;#000000\x1b\\\x1b]0;title\x07text")
	testing.expect_value(t, p, "\x1b]11;#000000\x1b\\")
	testing.expect_value(t, rest, "\x1b]0;title\x07text")
}
