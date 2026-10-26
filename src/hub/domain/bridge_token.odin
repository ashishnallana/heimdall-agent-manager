package domain

// Bridge_Token is one credential in a bridge's rotation lineage (REQ-IMPL-3,
// design §7.2/§7.4). Two rows exist per generation — one `.Access`, one
// `.Refresh` — and every generation of one enrollment shares a family_id.
//
// WHAT EACH FIELD IS FOR, since three of them look redundant and are not:
//
//   expires_at         — this ROW's expiry. Access: issued_at + 1h. Refresh:
//                        issued_at + 30d, re-based on every rotation (§7.4.5's
//                        sliding window).
//   family_expires_at  — the ABSOLUTE cap on the lineage, copied forward
//                        unchanged through every rotation. Sliding expiry alone
//                        means a refresh token that is used often never expires;
//                        this is what eventually forces re-enrollment. Carried on
//                        every row rather than in a family table so the verify
//                        path reads it from the row it already fetched.
//   rotated_at         — non-empty means this refresh token WAS SPENT. It is not
//                        a soft-delete: the row has to outlive its own
//                        replacement, because presenting a spent refresh token is
//                        the theft signal that revokes the whole family (§7.4.3).
//                        A rotated row that were deleted instead would make the
//                        replay indistinguishable from an unknown token.
//
// token_id is PUBLIC: it is the lookup half of `<prefix><token_id>.<secret>`
// (settled 6), and only token_hash's secret is confidential.
Bridge_Token_Kind :: enum {
	Access,
	Refresh,
}

Bridge_Token :: struct {
	token_id:          string,
	bridge_id:         string,
	kind:              Bridge_Token_Kind,
	token_hash:        string,
	family_id:         string,
	generation:        int,
	scope:             string,
	issued_at:         string,
	expires_at:        string,
	family_expires_at: string,
	rotated_at:        string,
	revoked_at:        string,
	// rotation_request_hash: on a SPENT refresh row, the salted digest of the
	// bridge's refresh request id that spent it (X-Heimdall-Refresh-Request-Id).
	// It is what lets a retry of THAT rotation, whose reply was lost, be answered
	// instead of read as theft (refresh_bridge_token). '' for rows spent by a
	// bridge that sent no request id, and for every unspent row.
	rotation_request_hash: string,
	// first_used_at: on an ACCESS row, when it first authenticated anything. Proof
	// that the reply which carried it was delivered (ends the retry grace).
	first_used_at: string,
	// regrant_claim: on a SPENT refresh row, the compare-and-set claim of the last
	// graced re-grant ("<generation it minted>"); serializes concurrent retries.
	regrant_claim: string,
}

bridge_token_kind_string :: proc(kind: Bridge_Token_Kind) -> string {
	switch kind {
	case .Access: return "access"
	case .Refresh: return "refresh"
	}
	return "access"
}

// bridge_token_kind_from_string fails CLOSED on anything unrecognised, and the
// bool matters: an unknown kind must not silently decode as `.Access`, which is
// the kind that authenticates WS connects. A row whose kind cannot be read is
// unusable, not usable as the more privileged of the two.
bridge_token_kind_from_string :: proc(value: string) -> (Bridge_Token_Kind, bool) {
	switch value {
	case "access": return .Access, true
	case "refresh": return .Refresh, true
	}
	return .Access, false
}

// bridge_token_destroy frees every heap string on a row read from a repository.
// Mirrors bridge_destroy, and exists for the same reason: the token sweep and the
// family-revocation path both read rows outside any per-request arena.
bridge_token_destroy :: proc(t: ^Bridge_Token) {
	if t == nil do return
	if len(t.token_id) > 0 do delete(t.token_id)
	if len(t.bridge_id) > 0 do delete(t.bridge_id)
	if len(t.token_hash) > 0 do delete(t.token_hash)
	if len(t.family_id) > 0 do delete(t.family_id)
	if len(t.scope) > 0 do delete(t.scope)
	if len(t.issued_at) > 0 do delete(t.issued_at)
	if len(t.expires_at) > 0 do delete(t.expires_at)
	if len(t.family_expires_at) > 0 do delete(t.family_expires_at)
	if len(t.rotated_at) > 0 do delete(t.rotated_at)
	if len(t.rotation_request_hash) > 0 do delete(t.rotation_request_hash)
	if len(t.first_used_at) > 0 do delete(t.first_used_at)
	if len(t.regrant_claim) > 0 do delete(t.regrant_claim)
	if len(t.revoked_at) > 0 do delete(t.revoked_at)
	t^ = Bridge_Token{}
}
