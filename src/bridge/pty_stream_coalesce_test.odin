package main

// REQ-PTY-NET-1 — coalescing in the bridge pty drain.
//
// The queue holds PLAINTEXT records; the drain folds adjacent records of one session into
// one wire frame and encrypts once per merged frame. These tests pin the four properties
// that make that safe: order is preserved, boundaries (session / snapshot / control frame)
// are respected, the per-frame cap is respected, and an encrypted merged frame still
// round-trips through the chunk decryptor.

import "base:runtime"
import base64 "core:encoding/base64"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

@(private = "file")
_p1_disable_vault :: proc() -> (restore: proc(prev_key, prev_cfg: string, had_key, had_cfg, saved_ws: bool), prev_key, prev_cfg: string, had_key, had_cfg, saved_ws: bool) {
	prev_key, had_key = os.lookup_env("HEIMDALL_VAULT_KEY", context.allocator)
	prev_cfg, had_cfg = os.lookup_env("HEIMDALL_VAULT_CONFIGURED", context.allocator)
	saved_ws = bridge_workspace_vault_configured
	bridge_workspace_vault_configured = false
	_ = os.set_env("HEIMDALL_VAULT_KEY", "unconfigured_key")
	_ = os.set_env("HEIMDALL_VAULT_CONFIGURED", "false")
	restore = proc(prev_key, prev_cfg: string, had_key, had_cfg, saved_ws: bool) {
		bridge_workspace_vault_configured = saved_ws
		if had_key { _ = os.set_env("HEIMDALL_VAULT_KEY", prev_key); delete(prev_key) } else { os.unset_env("HEIMDALL_VAULT_KEY") }
		if had_cfg { _ = os.set_env("HEIMDALL_VAULT_CONFIGURED", prev_cfg); delete(prev_cfg) } else { os.unset_env("HEIMDALL_VAULT_CONFIGURED") }
	}
	return
}

@(private = "file")
_p1_payload :: proc(frame: string) -> string {
	b64 := extract_json_string(frame, "data_b64", "", context.temp_allocator)
	decoded, err := base64.decode(b64, allocator = context.temp_allocator)
	if err != nil do return ""
	return string(decoded)
}

@(test)
pty_drain_merges_adjacent_same_session_records_in_order :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()
	restore, pk, pc, hk, hc, sw := _p1_disable_vault()
	defer restore(pk, pc, hk, hc, sw)

	for i in 0 ..< 20 {
		chunk := strings.repeat("x", 150, context.temp_allocator)
		buf := strings.concatenate({chunk, "|"}, context.temp_allocator)
		buf_bytes := transmute([]byte)buf
		buf_bytes[0] = byte('a' + i)
		bridge_pty_stream_emit_frame(nil, "sh_merge", buf_bytes)
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
	testing.expect(t, !strings.contains(frames[0], "is_snapshot"), "incremental merge is not a snapshot")
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
	restore, pk, pc, hk, hc, sw := _p1_disable_vault()
	defer restore(pk, pc, hk, hc, sw)

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
	testing.expect(t, strings.contains(frames[0], `"session_id":"A"`))
	testing.expect_value(t, _p1_payload(frames[1]), "b1")
	testing.expect_value(t, _p1_payload(frames[2]), "a3")
	testing.expect_value(t, _p1_payload(frames[3]), "S1S2")
	testing.expect(t, strings.contains(frames[3], `"is_snapshot":true`), "merged snapshot keeps the flag")
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
	restore, pk, pc, hk, hc, sw := _p1_disable_vault()
	defer restore(pk, pc, hk, hc, sw)

	// 5 x 6 KiB = 30 KiB incremental: fits in 16 KiB frames as 12 + 12 + 6.
	chunk := strings.repeat("y", 6 * 1024, context.temp_allocator)
	for _ in 0 ..< 5 do bridge_pty_stream_emit_frame(nil, "sh_cap", transmute([]byte)chunk)
	frames := bridge_pty_stream_take_outgoing()
	defer { for f in frames do delete(f, runtime.heap_allocator()); delete(frames) }
	testing.expect_value(t, len(frames), 3)
	total := 0
	for f in frames {
		n := len(_p1_payload(f))
		testing.expect(t, n <= BRIDGE_PTY_STREAM_EMIT_INCREMENTAL_BYTES, "merged frame within the incremental cap")
		total += n
	}
	testing.expect_value(t, total, 5 * 6 * 1024)

	// A single oversized emit is split at enqueue, never dropped.
	big := strings.repeat("z", 40 * 1024, context.temp_allocator)
	bridge_pty_stream_emit_frame(nil, "sh_big", transmute([]byte)big)
	frames2 := bridge_pty_stream_take_outgoing()
	defer { for f in frames2 do delete(f, runtime.heap_allocator()); delete(frames2) }
	testing.expect_value(t, len(frames2), 3) // 16 + 16 + 8
}

@(test)
pty_drain_encrypts_once_per_merged_frame_and_round_trips :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()
	prev_key, found := os.lookup_env("HEIMDALL_VAULT_KEY", context.allocator)
	defer { if found { _ = os.set_env("HEIMDALL_VAULT_KEY", prev_key); delete(prev_key) } else { os.unset_env("HEIMDALL_VAULT_KEY") } }
	_ = os.set_env("HEIMDALL_VAULT_KEY", TEST_ENC_VAULT_KEY)

	w := Bridge_PTY_Stream_Worker{active = true, fd = -1, salt = {1, 2, 3, 4}}
	bridge_pty_stream_emit_frame(&w, "sh_enc", transmute([]byte)string("hello "))
	bridge_pty_stream_emit_frame(&w, "sh_enc", transmute([]byte)string("merged "))
	bridge_pty_stream_emit_frame(&w, "sh_enc", transmute([]byte)string("world\r\n"))
	testing.expect_value(t, w.seq, u64(3)) // three nonces reserved at enqueue

	frames := bridge_pty_stream_take_outgoing()
	defer { for f in frames do delete(f, runtime.heap_allocator()); delete(frames) }
	testing.expect_value(t, len(frames), 1)
	if len(frames) != 1 do return
	testing.expect(t, strings.contains(frames[0], `"is_encrypted":true`))
	enc_b64 := extract_json_string(frames[0], "data_b64", "", context.temp_allocator)
	plain, ok := bridge_pty_stream_decrypt_chunk(enc_b64, TEST_ENC_VAULT_KEY, context.temp_allocator)
	testing.expect(t, ok, "merged ciphertext decrypts with one GCM header")
	testing.expect_value(t, string(plain), "hello merged world\r\n")
	// The merged frame carries the FIRST record's nonce (seq 1); nothing is reused.
	raw, _ := base64.decode(enc_b64, allocator = context.temp_allocator)
	testing.expect_value(t, raw[11], byte(1))
}
