package main

// Passwordless-vault test support for this package: deterministic device keys,
// canonical statements/wraps, signed requests, and the genesis + bridge-approval steps
// bridge enrollment now requires. Fixed key scalars, no randomness, no network.

import "core:crypto/ecdsa"
import "core:fmt"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import api_http "odin_test:hub/transport/http"
import vd "odin_test:hub/service/vault_directory"
import vault "odin_test:lib/vault"

Vt_Dev :: struct {
	priv:     ecdsa.Private_Key,
	sign_pub: string,
	ecdh_pub: string,
	id:       string,
	kind:     string,
}

VT_LABEL_B64 :: "VGVzdA" // "Test"
VT_COMMIT    :: "aabe8c0490f1e4d6754740170728a4ef286c80c1c2d180db826f956c3d9bd402"

@(private = "file")
vt_pub_hex :: proc(priv: ^ecdsa.Private_Key) -> string {
	pub: ecdsa.Public_Key
	ecdsa.public_key_set_priv(&pub, priv)
	raw: [65]byte
	ecdsa.public_key_bytes(&pub, raw[:])
	return vault.hex_encode_lower(raw[:], context.allocator)
}

// vt_make_dev derives a device from a fixed two-byte seed (distinct seeds, distinct keys).
vt_make_dev :: proc(seed: u16, kind := "browser") -> Vt_Dev {
	d := Vt_Dev{kind = kind}
	scalar: [32]byte
	scalar[0] = 0x21
	scalar[30] = byte(seed >> 8)
	scalar[31] = byte(seed)
	_ = ecdsa.private_key_set_bytes(&d.priv, .SECP256R1, scalar[:])
	d.sign_pub = vt_pub_hex(&d.priv)
	if kind != "bridge" {
		other: ecdsa.Private_Key
		scalar[1] = 0x33
		_ = ecdsa.private_key_set_bytes(&other, .SECP256R1, scalar[:])
		d.ecdh_pub = vt_pub_hex(&other)
	}
	d.id, _ = vault.device_id_from_sign_pub(d.sign_pub)
	return d
}

vt_sign :: proc(d: ^Vt_Dev, msg: string) -> string {
	sig, _ := vault.sign_p256(&d.priv, transmute([]byte)msg)
	text, _ := vault.signature_object(&sig)
	return text
}

vt_statement :: proc(type, user_id: string, issuer, subject: ^Vt_Dev, version, epoch: string) -> string {
	st := vault.Statement{type = type, user_id = user_id, directory_version = version, issuer_device_id = issuer.id, issued_at_ms = "1792404000000", epoch = epoch}
	if subject != nil {
		st.subject_device_id = subject.id
		st.subject_kind = subject.kind
		st.subject_sign_pub = subject.sign_pub
		st.subject_ecdh_pub = subject.ecdh_pub
		st.subject_sign_alg = vault.SIGN_ALG_ECDSA_P256_SHA256
		st.subject_wrap_alg = "" if subject.kind == "bridge" else vault.WRAP_ALG_ECDH_P256_HKDF_AES
		st.subject_label_b64 = VT_LABEL_B64
	}
	if type == "epoch" do st.epoch_commit = VT_COMMIT
	text, _ := vault.statement_canonical(&st)
	return text
}

// vt_wrap_json renders a signed wrap (dummy ciphertext: the hub never opens wraps).
vt_wrap_json :: proc(user_id: string, signer, recipient: ^Vt_Dev, version, epoch: u64) -> string {
	w := vault.Keyring_Wrap{
		alg = vault.WRAP_ALG_ECDH_P256_HKDF_AES, recipient_device_id = recipient.id,
		directory_version = version, current_epoch = u32(epoch),
		ephemeral_public_key = recipient.ecdh_pub, iv = "bc20a2fb46127e3a719bdb68",
		ciphertext = "00112233445566778899aabbccddeeff00112233", wrapped_by_device_id = signer.id,
	}
	stmt, _ := vault.wrap_statement(&w, user_id)
	text, _ := vault.wrap_signed_json(&w, vt_sign(signer, stmt))
	return text
}

vt_user_id :: proc(graph: ^app.App_Graph, headers: []contracts.HTTP_Header) -> string {
	me := api_http.router_dispatch(&graph.router, api_http.Request{method = "GET", path = "/api/v1/me", request_id = "req_vt_me", remote_addr = "127.0.0.1", headers = headers})
	return device_test_json_string(me.body, "user_id")
}

vt_genesis_body :: proc(user_id: string, root: ^Vt_Dev) -> string {
	g := vt_statement("genesis", user_id, root, root, "0", "1")
	e := vt_statement("epoch", user_id, root, nil, "0", "1")
	return strings.concatenate({`{"genesis_statement":"`, vt_escape(g), `","signature":`, vt_sign(root, g),
		`,"epoch_statement":"`, vt_escape(e), `","epoch_signature":`, vt_sign(root, e), `,"wrap":`, vt_wrap_json(user_id, root, root, 0, 1), "}"})
}

// vt_escape turns the statement's newlines into JSON escapes.
vt_escape :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "\n", `\n`)
	return out
}

vt_signed_headers :: proc(base: []contracts.HTTP_Header, dev: ^Vt_Dev, user_id, method, path, body, nonce: string, ts_ms: i64) -> []contracts.HTTP_Header {
	ts := fmt.aprintf("%d", ts_ms)
	msg := vd.request_canonical(method, path, user_id, ts, nonce, body)
	out := make([dynamic]contracts.HTTP_Header)
	for h in base do append(&out, h)
	append(&out, contracts.HTTP_Header{name = "X-Heimdall-Device-Id", value = dev.id})
	append(&out, contracts.HTTP_Header{name = "X-Heimdall-Device-Ts", value = ts})
	append(&out, contracts.HTTP_Header{name = "X-Heimdall-Device-Nonce", value = nonce})
	append(&out, contracts.HTTP_Header{name = "X-Heimdall-Device-Sig", value = vt_sign(dev, msg)})
	return out[:]
}

// The root device every enrollment helper approves bridges with.
VT_ROOT_SEED :: 1
@(private = "file")
vt_bridge_seed: u32 = 1000

// vt_ensure_vault makes sure the account behind `headers` has a directory (the root
// is vt_make_dev(VT_ROOT_SEED)) and returns its user id and current version.
vt_ensure_vault :: proc(graph: ^app.App_Graph, headers: []contracts.HTTP_Header) -> (user_id: string, version: i64, ok: bool) {
	user_id = vt_user_id(graph, headers)
	if user_id == "" do return "", 0, false
	root := vt_make_dev(VT_ROOT_SEED)
	view, err := vd.get_directory(&graph.vault_directory, user_id)
	if err.code == .None do return user_id, view.directory.version, true
	res := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/vault/directory/genesis", body = vt_genesis_body(user_id, &root),
		request_id = "req_vt_genesis", remote_addr = "127.0.0.1", headers = headers,
	})
	if res.status != 201 do return "", 0, false
	return user_id, 1, true
}

// vt_bridge_approval returns a fresh bridge identity key and the `vault_approval`
// JSON object the root signs for it.
vt_bridge_approval :: proc(user_id: string, version: i64) -> (identity_pub: string, approval_json: string) {
	seed := sync.atomic_add(&vt_bridge_seed, 1)
	br := vt_make_dev(u16(seed), "bridge")
	root := vt_make_dev(VT_ROOT_SEED)
	st := vt_statement("approve", user_id, &root, &br, fmt.tprintf("%d", version), "1")
	return br.sign_pub, strings.concatenate({`{"expected_version":`, fmt.tprintf("%d", version), `,"statement":"`, vt_escape(st), `","signature":`, vt_sign(&root, st), "}"})
}
