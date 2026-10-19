package vault

import "core:crypto/sha2"
import "core:encoding/json"
import "core:strconv"
import "core:strings"

// ── Bridge keyring authentication (plan §1, finding C1) ─────────────────────
//
// The ECDH unseal proves only that the sender saw this boot's signed key, never WHO
// the sender is: a hostile hub can seal a keyring of its own choosing. So every unseal
// v2 payload carries, next to the sealed HKR1 keyring, a `chain_proof` member: public,
// signed directory data showing that the keyring's current epoch was committed by an
// approver of the bridge's account, and that this bridge is itself approved. The
// sender is the approving browser (src/ui/utils/vaultDirectoryVerify.ts
// buildBridgeChainProof; TS reference verifier verifyBridgeChainProof — this file
// implements the same rules). Every signature is self-authenticating, so the proof
// needs no AEAD binding.
//
//   chain_proof = {
//     "v": 1,
//     "user_id":        account,
//     "root_device_id": "dev_…" (= device id of root_sign_pub),
//     "root_sign_alg":  "ecdsa-p256-sha256",
//     "root_sign_pub":  130 hex,
//     "genesis":  {"statement": <canonical genesis>, "signature": <sig object or its JSON text>},
//     "epoch":    {"epoch": current_epoch, "statement": <canonical epoch stmt>, "signature": …},
//     "issuer_chain": [link…],   approval chain of the epoch statement's issuer,
//                                root-first, root excluded ([] when the root issued it)
//     "subject_approval": {"statement": <approve stmt for this bridge>, "signature": …,
//                          "issuer_chain": [link…]}
//   }
//   link = {"device_id","kind","sign_alg","sign_public_key","approval_statement","approval_signature"}
//
// Verification (bridge_chain_verify), all fail closed:
//   - v = 1; user_id = the bridge's enrolled owner = the keyring's user_id.
//   - root: alg allowlisted, valid point, root_device_id derived from root_sign_pub.
//     When a root is pinned (every unseal after the first) it must be exactly that
//     root; on the first unseal the verified root is returned for the caller to pin.
//   - genesis: canonical, type genesis, user_id, self-issued by the root, subject =
//     root (id, pub, alg), root kind may approve; signature by root_sign_pub.
//   - each link: canonical approve statement for the proof's user, issued by the
//     previous link (the root first), subject = the link (id, kind, pub, alg), link id
//     derived from its key, link kind may approve (never a bridge), signature by the
//     previous link's key.
//   - epoch: canonical, type epoch, user_id, epoch = "epoch" member = keyring
//     current_epoch, issued by the last issuer_chain link (or the root), signed by it,
//     epoch_commit = HMAC(keyring current key, …) compared in constant time.
//   - subject_approval: canonical approve statement, user_id, issued by the last link
//     of its own issuer_chain (or the root), signed by it, subject_kind bridge,
//     subject_sign_pub = this bridge's identity key, subject_device_id derived from it.
//
// Residuals (plan §1): the FIRST unseal after enrollment pins whatever root it
// carries (sealed by the approving device in the normal flow; a hostile hub racing
// it could substitute its own root — ham-bridge enroll prints the account
// fingerprint for the owner to compare). The proof carries no revocations, so a
// compromised approver keeps producing valid proofs after being revoked; only the
// epoch floor (it never learns the post-revocation epoch key) stops it, and only
// once this bridge has accepted that newer epoch.

BRIDGE_CHAIN_MAX_LINKS :: 16
DEVICE_ID_BYTES        :: len(DEVICE_ID_PREFIX) + DEVICE_ID_HEX_CHARS

// ── Root pin ────────────────────────────────────────────────────────────────

Root_Pin :: struct {
	set:       bool,
	sign_alg:  Sign_Alg,
	sign_pub:  [P256_PUBLIC_KEY_BYTES]byte,
	device_id: [DEVICE_ID_BYTES]byte,
}

root_pin_device_id :: proc(p: ^Root_Pin) -> string {
	return string(p.device_id[:])
}

root_pin_equal :: proc(a, b: ^Root_Pin) -> bool {
	return a.set && b.set && a.sign_alg == b.sign_alg && a.sign_pub == b.sign_pub && a.device_id == b.device_id
}

// root_pin_from_hex builds a pin from wire values (all validated).
root_pin_from_hex :: proc(device_id, sign_alg_id, sign_pub_hex: string) -> (p: Root_Pin, ok: bool) {
	alg := sign_alg_from_id(sign_alg_id)
	if alg == .Unknown || !valid_p256_public_key(sign_pub_hex) do return {}, false
	want, id_ok := device_id_from_sign_pub(sign_pub_hex, context.temp_allocator)
	if !id_ok || device_id != want || len(device_id) != DEVICE_ID_BYTES do return {}, false
	_ = hex_decode_into(p.sign_pub[:], sign_pub_hex)
	copy(p.device_id[:], device_id)
	p.sign_alg = alg
	p.set = true
	return p, true
}

// account_fingerprint = first 8 bytes of SHA256(root_sign_pub_raw65), as four
// space-separated groups of four hex digits: what a human compares between devices.
account_fingerprint :: proc(p: ^Root_Pin, allocator := context.allocator) -> (string, bool) {
	if !p.set do return "", false
	digest: [32]byte
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, p.sign_pub[:])
	sha2.final(&ctx, digest[:])
	h := hex_encode_lower(digest[:8], context.temp_allocator)
	return strings.concatenate({h[0:4], " ", h[4:8], " ", h[8:12], " ", h[12:16]}, allocator), true
}

// ── Verification ────────────────────────────────────────────────────────────

Chain_Error :: enum {
	None,
	Malformed,         // missing/extra member, wrong type, non-canonical statement
	Wrong_Account,     // proof or a statement names another user
	Root_Invalid,      // root key/alg/id invalid
	Root_Mismatch,     // root differs from the pinned root
	Genesis_Invalid,
	Link_Invalid,      // issuer chain link does not chain or is not an approver
	Bad_Signature,
	Epoch_Mismatch,    // epoch statement not for the keyring's current epoch
	Commit_Mismatch,   // epoch_commit does not match the delivered current key
	Not_This_Bridge,   // subject_approval does not approve this bridge's identity
}

chain_error_message :: proc(e: Chain_Error) -> string {
	switch e {
	case .None:            return ""
	case .Malformed:       return "keyring chain proof is missing or malformed"
	case .Wrong_Account:   return "keyring chain proof belongs to another account"
	case .Root_Invalid:    return "keyring chain proof: the account root is invalid"
	case .Root_Mismatch:   return "keyring chain proof: the account root differs from the one this bridge pinned"
	case .Genesis_Invalid: return "keyring chain proof: the account genesis is invalid"
	case .Link_Invalid:    return "keyring chain proof: an issuer is not an approver chained to the root"
	case .Bad_Signature:   return "keyring chain proof: a signature does not verify"
	case .Epoch_Mismatch:  return "keyring chain proof: the epoch statement is not for the keyring's current epoch"
	case .Commit_Mismatch: return "keyring chain proof: epoch_commit does not match the delivered key"
	case .Not_This_Bridge: return "keyring chain proof: the approval does not name this bridge's identity key"
	}
	return "keyring chain proof rejected"
}

@(private = "file")
Signer :: struct {
	id, alg, pub: string,
}

@(private = "file")
get_string :: proc(o: json.Object, key: string) -> (string, bool) {
	v, has := o[key]
	if !has do return "", false
	s, ok := v.(json.String)
	return string(s), ok
}

@(private = "file")
get_signature :: proc(o: json.Object, key: string) -> (string, bool) {
	v, has := o[key]
	if !has do return "", false
	return signature_text_from_value(v, context.temp_allocator)
}

// verify_links walks issuer_chain from the root and returns the last signer.
@(private = "file")
verify_links :: proc(v: json.Value, root: Signer, user_id: string) -> (last: Signer, err: Chain_Error) {
	links, is_arr := v.(json.Array)
	if !is_arr || len(links) > BRIDGE_CHAIN_MAX_LINKS do return {}, .Malformed
	prev := root
	for lv in links {
		link, is_obj := lv.(json.Object)
		if !is_obj do return {}, .Malformed
		id, i_ok := get_string(link, "device_id")
		kind, k_ok := get_string(link, "kind")
		alg, a_ok := get_string(link, "sign_alg")
		pub, p_ok := get_string(link, "sign_public_key")
		text, t_ok := get_string(link, "approval_statement")
		sig, s_ok := get_signature(link, "approval_signature")
		if !(i_ok && k_ok && a_ok && p_ok && t_ok && s_ok) do return {}, .Malformed
		st, parsed := statement_parse(text)
		if !parsed do return {}, .Malformed
		if st.type != "approve" || st.issuer_device_id != prev.id do return {}, .Link_Invalid
		if st.user_id != user_id do return {}, .Wrong_Account
		if st.subject_device_id != id || st.subject_sign_pub != pub || st.subject_kind != kind || st.subject_sign_alg != alg do return {}, .Link_Invalid
		if !kind_policy(device_kind_from_id(kind)).can_approve || sign_alg_from_id(alg) == .Unknown do return {}, .Link_Invalid
		derived, d_ok := device_id_from_sign_pub(pub, context.temp_allocator)
		if !d_ok || derived != id do return {}, .Link_Invalid
		if !verify(prev.alg, prev.pub, transmute([]byte)text, sig) do return {}, .Bad_Signature
		prev = Signer{id, alg, pub}
	}
	return prev, .None
}

// bridge_chain_verify checks a chain_proof value (see the file header) for the keyring
// kr delivered to the bridge whose identity public key is bridge_identity_pub_hex and
// whose enrolled owner is owner_user_id. pinned may be nil or unset (first unseal):
// the verified root is returned for the caller to pin. Nothing is trusted on failure.
bridge_chain_verify :: proc(
	proof_value: json.Value,
	owner_user_id: string,
	bridge_identity_pub_hex: string,
	kr: ^Vault_Keyring,
	pinned: ^Root_Pin,
) -> (root: Root_Pin, err: Chain_Error) {
	if kr == nil || !keyring_validate(kr) || owner_user_id == "" do return {}, .Malformed
	if keyring_user_id(kr) != owner_user_id do return {}, .Wrong_Account
	p, is_obj := proof_value.(json.Object)
	if !is_obj do return {}, .Malformed
	ver, ver_ok := p["v"].(json.Integer)
	if !ver_ok || ver != 1 do return {}, .Malformed
	user_id, u_ok := get_string(p, "user_id")
	if !u_ok do return {}, .Malformed
	if user_id != owner_user_id do return {}, .Wrong_Account

	// Root.
	root_id, ri_ok := get_string(p, "root_device_id")
	root_alg, ra_ok := get_string(p, "root_sign_alg")
	root_pub, rp_ok := get_string(p, "root_sign_pub")
	if !(ri_ok && ra_ok && rp_ok) do return {}, .Malformed
	pin, pin_ok := root_pin_from_hex(root_id, root_alg, root_pub)
	if !pin_ok do return {}, .Root_Invalid
	if pinned != nil && pinned.set && !root_pin_equal(pinned, &pin) do return {}, .Root_Mismatch
	root_signer := Signer{root_id, root_alg, root_pub}

	// Genesis, self-signed by the root.
	g_obj, g_is := p["genesis"].(json.Object)
	if !g_is do return {}, .Malformed
	g_text, gt_ok := get_string(g_obj, "statement")
	g_sig, gs_ok := get_signature(g_obj, "signature")
	if !gt_ok || !gs_ok do return {}, .Malformed
	g, g_parsed := statement_parse(g_text)
	if !g_parsed do return {}, .Malformed
	if g.user_id != user_id do return {}, .Wrong_Account
	if g.type != "genesis" || g.issuer_device_id != root_id || g.subject_device_id != root_id || g.subject_sign_pub != root_pub || g.subject_sign_alg != root_alg do return {}, .Genesis_Invalid
	if !kind_policy(device_kind_from_id(g.subject_kind)).can_approve do return {}, .Genesis_Invalid
	if !verify(root_alg, root_pub, transmute([]byte)g_text, g_sig) do return {}, .Bad_Signature

	// The epoch statement for the keyring's current epoch, by an approver chained to the root.
	issuer_chain, ic_has := p["issuer_chain"]
	if !ic_has do return {}, .Malformed
	issuer, ie := verify_links(issuer_chain, root_signer, user_id)
	if ie != .None do return {}, ie
	e_obj, e_is := p["epoch"].(json.Object)
	if !e_is do return {}, .Malformed
	e_num, en_ok := e_obj["epoch"].(json.Integer)
	e_text, et_ok := get_string(e_obj, "statement")
	e_sig, es_ok := get_signature(e_obj, "signature")
	if !(en_ok && et_ok && es_ok) do return {}, .Malformed
	e, e_parsed := statement_parse(e_text)
	if !e_parsed || e.type != "epoch" do return {}, .Malformed
	if e.user_id != user_id do return {}, .Wrong_Account
	cur_buf: [16]byte
	cur := strconv.write_uint(cur_buf[:], u64(kr.current_epoch), 10)
	if e.epoch != cur || e_num != i64(kr.current_epoch) do return {}, .Epoch_Mismatch
	if e.issuer_device_id != issuer.id do return {}, .Link_Invalid
	if !verify(issuer.alg, issuer.pub, transmute([]byte)e_text, e_sig) do return {}, .Bad_Signature
	commit: [32]byte
	if len(e.epoch_commit) != EPOCH_COMMIT_HEX_CHARS || !is_lower_hex(e.epoch_commit) || !hex_decode_into(commit[:], e.epoch_commit) do return {}, .Malformed
	key, has_key := keyring_current_key(kr)
	if !has_key || !epoch_commit_verify(key, user_id, kr.current_epoch, commit[:]) do return {}, .Commit_Mismatch

	// This bridge's own approval.
	sa, sa_is := p["subject_approval"].(json.Object)
	if !sa_is do return {}, .Malformed
	sa_chain, sac_has := sa["issuer_chain"]
	if !sac_has do return {}, .Malformed
	approver, ae := verify_links(sa_chain, root_signer, user_id)
	if ae != .None do return {}, ae
	s_text, st_ok := get_string(sa, "statement")
	s_sig, ss_ok := get_signature(sa, "signature")
	if !st_ok || !ss_ok do return {}, .Malformed
	s, s_parsed := statement_parse(s_text)
	if !s_parsed || s.type != "approve" do return {}, .Malformed
	if s.user_id != user_id do return {}, .Wrong_Account
	if s.issuer_device_id != approver.id do return {}, .Link_Invalid
	bridge_id_derived, b_ok := device_id_from_sign_pub(bridge_identity_pub_hex, context.temp_allocator)
	if !b_ok || s.subject_kind != "bridge" || s.subject_sign_pub != bridge_identity_pub_hex || s.subject_device_id != bridge_id_derived do return {}, .Not_This_Bridge
	if !verify(approver.alg, approver.pub, transmute([]byte)s_text, s_sig) do return {}, .Bad_Signature
	return pin, .None
}

