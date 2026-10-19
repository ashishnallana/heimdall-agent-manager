package http

import "core:bytes"
import "core:encoding/base64"
import "core:strings"
import "core:testing"
import agent_service "odin_test:hub/service/agent"
import project_service "odin_test:hub/service/project"
import vault "odin_test:lib/vault"

@(private = "file")
relay_test_token :: proc(epoch: u32) -> (token: string, body: []byte) {
	key: [32]byte
	key[0] = 7
	salt: [vault.PTY_V2_SALT_BYTES]byte
	salt[0] = 9
	frame, ok := vault.pty_seal(transmute([]byte)string("screen bytes"), key[:], epoch, salt[:], 1, "sh_relay", .Out, context.temp_allocator)
	assert(ok)
	// Armored PTY frame: vault:v2:e<N>:b64(salt|nonce|tag|ct) -- everything past the epoch.
	b64, _ := base64.encode(frame[4:], allocator = context.temp_allocator)
	tok := strings.concatenate({"vault:v2:e", "258" if epoch == 258 else "3", ":", b64}, context.temp_allocator)
	return tok, frame[4:]
}

// The snapshot path re-frames vault:v2:e<N>:<b64> as u32be(N) | nonce | tag | ct.
@(test)
test_screen_snapshot_passes_epoch_through :: proc(t: ^testing.T) {
	tok, body := relay_test_token(258)
	reply := strings.concatenate({`{"output":"`, tok, `","cursor_row":1,"cursor_col":2}`}, context.temp_allocator)
	frames, ok := _shell_stream_screen_frames(reply)
	defer { for f in frames do delete(f); delete(frames) }
	testing.expect(t, ok && len(frames) == 1)
	want := make([]byte, 4 + len(body), context.temp_allocator)
	want[2], want[3] = 1, 2 // 258 big-endian
	copy(want[4:], body)
	testing.expect(t, bytes.has_suffix(frames[0], want), "SCREEN payload must be the PTY v2 layout")

	// A malformed or dead-v1 encrypted capture paints nothing / is not decrypted.
	bad, bad_ok := _shell_stream_screen_frames(`{"output":"vault:v2:e0:AAAA"}`)
	defer delete(bad)
	testing.expect(t, !bad_ok)
	// A v2 content token too short to carry salt16|nonce|tag is not a PTY frame.
	key: [32]byte
	nonce: [12]byte
	short, _ := vault.seal_with_nonce(transmute([]byte)string("x"), key[:], 3, nonce[:], context.temp_allocator)
	short_reply := strings.concatenate({`{"output":"`, short, `"}`}, context.temp_allocator)
	short_frames, short_ok := _shell_stream_screen_frames(short_reply)
	defer delete(short_frames)
	testing.expect(t, !short_ok)
}

@(test)
test_pty_input_relay_reframes_armored_input :: proc(t: ^testing.T) {
	tok, body := relay_test_token(3)
	cmd := agent_service.agent_pty_input_command_json("c", "inst", "", tok)
	defer delete(cmd)
	want := make([]byte, 4 + len(body), context.temp_allocator)
	want[3] = 3
	copy(want[4:], body)
	enc, _ := base64.encode(want, allocator = context.temp_allocator)
	testing.expect(t, strings.contains(cmd, strings.concatenate({`"data_b64":"`, enc, `"`}, context.temp_allocator)), cmd)
	testing.expect(t, !strings.contains(cmd, "vault:v2:"))
}

@(test)
test_bridge_hello_unseal_identity_shape_checks :: proc(t: ^testing.T) {
	pub := strings.concatenate({"04", strings.repeat("a", 128, context.temp_allocator)}, context.temp_allocator)
	sig := strings.concatenate({`{"alg":"ecdsa-p256-sha256","sig":"`, strings.repeat("b", 128, context.temp_allocator), `"}`}, context.temp_allocator)
	hello := strings.concatenate({`{"type":"bridge_hello","public_key":"`, pub, `","unseal_boot_id":"0011","unseal_key_signature":`, sig, `,"identity_public_key":"`, pub, `","identity_sign_alg":"ecdsa-p256-sha256"}`}, context.temp_allocator)
	u := bridge_hello_unseal_identity(hello)
	defer project_service.bridge_unseal_identity_destroy(&u)
	testing.expect_value(t, u.unseal_key_signature, sig)
	testing.expect_value(t, u.identity_public_key, pub)

	// Unknown algorithm: the signed fields are dropped, so clients refuse to unseal.
	bad := strings.concatenate({`{"public_key":"`, pub, `","unseal_boot_id":"0011","unseal_key_signature":{"alg":"webauthn-es256","sig":"00"},"identity_public_key":"`, pub, `","identity_sign_alg":"webauthn-es256"}`}, context.temp_allocator)
	u2 := bridge_hello_unseal_identity(bad)
	defer project_service.bridge_unseal_identity_destroy(&u2)
	testing.expect_value(t, u2.public_key, pub)
	testing.expect_value(t, u2.unseal_key_signature, "")
	testing.expect_value(t, u2.identity_public_key, "")

	b := strings.builder_make(context.temp_allocator)
	write_bridge_unseal_identity_fields(&b, u2)
	testing.expect(t, strings.contains(strings.to_string(b), `"unseal_key_signature":null`))
}
