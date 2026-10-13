package push_crypto_test

// Flake/CI-registered runnable check for the Web Push crypto layer. It reuses
// the push package's exported crypto to reproduce the RFC 8291 Appendix A
// encryption test vector byte-for-byte — the correctness gate for WP-CRYPTO-2.
//
// The in-package @(test) procs in src/hub/service/push/webpush_crypto_test.odin
// cover the same vector plus VAPID/base64url; this dir mirrors the repo's
// runnable-binary test convention (like tests/task_store_repository_test) so
// `nix build .#ham-push-crypto-test` runs it in CI.

import "core:crypto/ecdh"
import "core:fmt"
import "core:os"
import "core:testing"
import push "odin_test:hub/service/push"

@(test)
test_push_crypto_rfc8291 :: proc(t: ^testing.T) {
	_ = t
	main()
}

check :: proc(ok: bool, msg: string) {
	if ok do return
	fmt.eprintln("FAIL:", msg)
	os.exit(1)
}

main :: proc() {
	// RFC 8291 Appendix A inputs.
	as_private_b64 := "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"
	ua_public_b64 := "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
	auth_b64 := "BTBZMqHH6r4Tts7J_aSIgg"
	salt_b64 := "DGv6ra1nlYgDCS1FRnbzlw"
	plaintext := "When I grow up, I want to be a watermelon"
	// header || ciphertext from RFC 8291 Section 5 (whitespace removed).
	expected_body_b64 := "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"

	as_private, ok1 := push.base64url_decode(as_private_b64)
	check(ok1, "decode as_private")
	ua_public, ok2 := push.base64url_decode(ua_public_b64)
	check(ok2, "decode ua_public")
	auth_secret, ok3 := push.base64url_decode(auth_b64)
	check(ok3, "decode auth_secret")
	salt, ok4 := push.base64url_decode(salt_b64)
	check(ok4, "decode salt")

	as_priv: ecdh.Private_Key
	defer ecdh.private_key_clear(&as_priv)
	check(ecdh.private_key_set_bytes(&as_priv, .SECP256R1, as_private), "load as_private scalar")

	enc, ok := push.webpush_encrypt_with(transmute([]byte)plaintext, ua_public, auth_secret, &as_priv, salt)
	check(ok, "webpush_encrypt_with")
	defer delete(enc.body)

	got := push.base64url_encode(enc.body)
	defer delete(got)
	check(got == expected_body_b64, fmt.tprintf("RFC 8291 Appendix A mismatch\n got=%s\nwant=%s", got, expected_body_b64))

	fmt.println("PUSH CRYPTO RFC 8291 APPENDIX A VECTOR PASSED")
}
