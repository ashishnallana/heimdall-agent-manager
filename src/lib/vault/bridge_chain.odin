package vault

import "core:crypto/sha2"
import "core:encoding/json"
import "core:strconv"
import "core:strings"

// ── Bridge keyring authentication (plan §1, finding C1) ─────────────────────
//
// The ECDH unseal proves only that the sender saw this boot's signed key, never WHO
// the sender is: a hostile hub can seal a keyring of its own choosing. So every unseal
// v2 payload carries, next to the sealed HKR2 keyring, a `chain_proof` member: public,
// signed directory-log data showing that EVERY epoch in the keyring was introduced by
// an approver of the bridge's account, and that this bridge is itself approved. The
// sender is the approving browser (src/ui/utils/vaultDirectoryVerify.ts
// buildBridgeChainProof; TS reference verifier verifyBridgeChainProof — this file
// implements the same rules). Every signature is self-authenticating, so the proof
// needs no AEAD binding.
//
//   chain_proof = {
//     "v": 2,
//     "user_id":        account,
//     "root_device_id": "dev_…" (= device id of root_sign_pub),
//     "root_sign_alg":  "ecdsa-p256-sha256",
//     "root_sign_pub":  130 hex,
//     "genesis":  {"statement": <canonical genesis (log seq 1)>, "signature": <sig object or its JSON text>},
//     "epochs":   [carrier…],  one per keyring epoch, ascending, the last = current_epoch
//     "subject_approval": {"statement": <approve stmt for this bridge>, "signature": …,
//                          "issuer_chain": [link…]}
//   }
//   carrier = {"epoch": n, "statement": <the log op that introduced epoch n: genesis
//              (n = 1), revoke or rotate>, "signature": …, "issuer_chain": [link…]}
//   link    = {"device_id","kind","sign_alg","sign_public_key","approval_statement","approval_signature"}
//   issuer_chain: the issuer's approvals, root-first, root excluded ([] when the root issued it).
//
// Verification (bridge_chain_verify), all fail closed:
//   - v = 2; user_id = the bridge's enrolled owner = the keyring's user_id.
//   - root: alg allowlisted, valid point, root_device_id derived from root_sign_pub.
//     When a root is pinned (every unseal after the first) it must be exactly that
//     root; on the first unseal the verified root is returned for the caller to pin.
//   - genesis: canonical, type genesis at log seq 1 with no prev_hash, user_id,
//     self-issued by the root, subject = root (id, pub, alg), root kind may approve;
//     signature by root_sign_pub.
//   - each link: canonical approve statement for the proof's user, issued by the
//     previous link (the root first), subject = the link (id, kind, pub, alg), link id
//     derived from its key, link kind may approve (never a bridge), signature by the
//     previous link's key, and a log seq strictly greater than the previous link's
//     (an issuer is approved before it approves).
//   - epochs: exactly one carrier per keyring entry, in keyring order. Each is a log
//     op that introduces its epoch (genesis for epoch 1 — the genesis above — revoke
//     or rotate otherwise), for the proof's user, issued by the last link of its own
//     issuer_chain (or the root) at a log seq greater than that issuer's approval,
//     signed by it, with epoch_commit equal (constant time) to the HMAC of the
//     keyring's key for that epoch. Carrier seqs strictly increase with the epoch.
//     So no epoch key in the keyring — current or older — is unattested.
//   - subject_approval: canonical approve statement, user_id, issued by the last link
//     of its own issuer_chain (or the root) at a later seq, signed by it, subject_kind
//     bridge, subject_sign_pub = this bridge's identity key, subject_device_id derived.
//
// Residuals (plan §1): the bridge cannot hold or verify the whole directory log (no
// revocation is visible to it). The FIRST unseal after enrollment pins whatever root
// it carries (ham-bridge enroll prints the account fingerprint for the owner to
// compare). A compromised approver keeps producing valid-looking proofs after it is
// revoked; it never learns the post-revocation epoch key, so the epoch floor (only
// keyrings that extend the stored epochs with identical keys) stops it once this
// bridge has accepted the newer epoch — a bridge offline across the revocation can
// still be fed a fake newer epoch by it.

BRIDGE_CHAIN_MAX_LINKS :: 16
DEVICE_ID_BYTES        :: len(DEVICE_ID_PREFIX) + DEVICE_ID_HEX_CHARS
BRIDGE_CHAIN_PROOF_VERSION :: 2

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
	Epoch_Mismatch,    // the epoch carriers do not match the keyring's epochs
	Commit_Mismatch,   // an epoch_commit does not match the delivered key
	Not_This_Bridge,   // subject_approval does not approve this bridge's identity
	Wrong_Vault,       // the keyring's vault id is not the one the proof's root names
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
	case .Epoch_Mismatch:  return "keyring chain proof: the signed epochs do not match the keyring's epochs"
	case .Commit_Mismatch: return "keyring chain proof: an epoch_commit does not match the delivered key"
	case .Not_This_Bridge: return "keyring chain proof: the approval does not name this bridge's identity key"
	case .Wrong_Vault:     return "keyring chain proof: the keyring belongs to another vault than the proof's root"
	}
	return "keyring chain proof rejected"
}

@(private = "file")
Signer :: struct {
	id, alg, pub: string,
	seq:          u64, // log seq of this signer's approval (1 for the root: its genesis)
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

// statement_seq parses the log seq of a log-op statement (>= 1).
@(private = "file")
statement_seq :: proc(st: ^Statement) -> (u64, bool) {
	n, ok := decimal_u64(st.seq)
	if !ok || n < 1 do return 0, false
	return n, true
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
		seq, seq_ok := statement_seq(&st)
		if !seq_ok || seq <= prev.seq do return {}, .Link_Invalid
		if st.subject_device_id != id || st.subject_sign_pub != pub || st.subject_kind != kind || st.subject_sign_alg != alg do return {}, .Link_Invalid
		if !kind_policy(device_kind_from_id(kind)).can_approve || sign_alg_from_id(alg) == .Unknown do return {}, .Link_Invalid
		derived, d_ok := device_id_from_sign_pub(pub, context.temp_allocator)
		if !d_ok || derived != id do return {}, .Link_Invalid
		if !verify(prev.alg, prev.pub, transmute([]byte)text, sig) do return {}, .Bad_Signature
		prev = Signer{id, alg, pub, seq}
	}
	return prev, .None
}

// verify_epoch_carrier checks one `epochs` element for keyring entry `entry` and
// returns the carrier's log seq.
@(private = "file")
verify_epoch_carrier :: proc(v: json.Value, root: Signer, user_id: string, entry: ^Keyring_Entry) -> (seq: u64, err: Chain_Error) {
	obj, is_obj := v.(json.Object)
	if !is_obj do return 0, .Malformed
	num, n_ok := obj["epoch"].(json.Integer)
	text, t_ok := get_string(obj, "statement")
	sig, s_ok := get_signature(obj, "signature")
	chain_v, c_has := obj["issuer_chain"]
	if !(n_ok && t_ok && s_ok && c_has) do return 0, .Malformed
	if num != i64(entry.epoch) do return 0, .Epoch_Mismatch
	st, parsed := statement_parse(text)
	if !parsed || !introduces_epoch(st.type) do return 0, .Malformed
	if st.user_id != user_id do return 0, .Wrong_Account
	ebuf: [16]byte
	if st.epoch != strconv.write_uint(ebuf[:], u64(entry.epoch), 10) do return 0, .Epoch_Mismatch
	// Epoch 1 is introduced by the genesis only, and the genesis introduces only epoch 1.
	if (st.type == "genesis") != (entry.epoch == 1) do return 0, .Epoch_Mismatch
	issuer, ie := verify_links(chain_v, root, user_id)
	if ie != .None do return 0, ie
	if st.issuer_device_id != issuer.id do return 0, .Link_Invalid
	s, seq_ok := statement_seq(&st)
	if !seq_ok do return 0, .Malformed
	if st.type == "genesis" {
		if s != 1 || st.prev_hash != "" || issuer.id != root.id do return 0, .Genesis_Invalid
	} else if s <= issuer.seq {
		return 0, .Link_Invalid
	}
	if !verify(issuer.alg, issuer.pub, transmute([]byte)text, sig) do return 0, .Bad_Signature
	commit: [32]byte
	if len(st.epoch_commit) != EPOCH_COMMIT_HEX_CHARS || !is_lower_hex(st.epoch_commit) || !hex_decode_into(commit[:], st.epoch_commit) do return 0, .Malformed
	if !epoch_commit_verify(entry.key[:], user_id, entry.epoch, commit[:]) do return 0, .Commit_Mismatch
	return s, .None
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
	if !ver_ok || ver != BRIDGE_CHAIN_PROOF_VERSION do return {}, .Malformed
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
	// The keyring names its vault (vault id = SHA-256(root key)[:8]): it must be this
	// root's, so a keyring of another (or a reset) vault never passes as this one's.
	want_vault, wv_ok := vault_id_from_root_sign_pub(root_pub)
	if !wv_ok do return {}, .Root_Invalid
	if want_vault != kr.vault_id do return {}, .Wrong_Vault
	root_signer := Signer{root_id, root_alg, root_pub, 1}

	// Genesis, self-signed by the root, log seq 1.
	g_obj, g_is := p["genesis"].(json.Object)
	if !g_is do return {}, .Malformed
	g_text, gt_ok := get_string(g_obj, "statement")
	g_sig, gs_ok := get_signature(g_obj, "signature")
	if !gt_ok || !gs_ok do return {}, .Malformed
	g, g_parsed := statement_parse(g_text)
	if !g_parsed do return {}, .Malformed
	if g.user_id != user_id do return {}, .Wrong_Account
	if g.type != "genesis" || g.seq != "1" || g.prev_hash != "" || g.issuer_device_id != root_id || g.subject_device_id != root_id || g.subject_sign_pub != root_pub || g.subject_sign_alg != root_alg do return {}, .Genesis_Invalid
	if !kind_policy(device_kind_from_id(g.subject_kind)).can_approve do return {}, .Genesis_Invalid
	if !verify(root_alg, root_pub, transmute([]byte)g_text, g_sig) do return {}, .Bad_Signature

	// One signed carrier per keyring epoch, in keyring order (the last is current).
	carriers, c_is := p["epochs"].(json.Array)
	if !c_is do return {}, .Malformed
	if len(carriers) != kr.count do return {}, .Epoch_Mismatch
	last_seq: u64 = 0
	for i in 0 ..< kr.count {
		s, ce := verify_epoch_carrier(carriers[i], root_signer, user_id, &kr.entries[i])
		if ce != .None do return {}, ce
		if s <= last_seq do return {}, .Epoch_Mismatch
		last_seq = s
	}
	if kr.entries[kr.count - 1].epoch != kr.current_epoch do return {}, .Epoch_Mismatch

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
	s_seq, s_seq_ok := statement_seq(&s)
	if !s_seq_ok || s_seq <= approver.seq do return {}, .Link_Invalid
	bridge_id_derived, b_ok := device_id_from_sign_pub(bridge_identity_pub_hex, context.temp_allocator)
	if !b_ok || s.subject_kind != "bridge" || s.subject_sign_pub != bridge_identity_pub_hex || s.subject_device_id != bridge_id_derived do return {}, .Not_This_Bridge
	if !verify(approver.alg, approver.pub, transmute([]byte)s_text, s_sig) do return {}, .Bad_Signature
	return pin, .None
}
