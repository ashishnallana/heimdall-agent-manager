package vault

// ── Artifact transfer receipts (docs/plans/mcp-large-artifact-transfers.md §6) ──
//
// A receipt is a newline-joined canonical statement signed by the device that sealed
// (verb "seal") or opened (verb "open") an E2EE transfer. The Hub only BUILDS the
// expected statement from its own transfer row and VERIFIES the signature against a
// verified device directory; it never holds a key that opens content. Every field is
// a restricted single-line value, so a field cannot smuggle a second line.

import "core:strconv"
import "core:strings"

TRANSFER_RECEIPT_HEADER :: "heimdall-artifact-transfer-receipt/v1"
TRANSFER_RECEIPT_MAX_BYTES :: 4096

Transfer_Receipt_Verb :: enum u8 {
	Seal,
	Open,
}

// Transfer_Seal_Receipt carries every field of the §6.1 upload statement.
Transfer_Seal_Receipt :: struct {
	owner_user_id:              string,
	vault_id:                   string, // 16 lowercase hex
	epoch:                      u32,
	transfer_id:                string,
	artifact_id:                string,
	kind:                       string,
	content_type:               string,
	ciphertext_bytes:           i64,
	ciphertext_sha256:          string,
	name_token_sha256:          string,
	description_token_sha256:   string,
	attestation_token_sha256:   string,
	device_id:                  string,
	issued_ms:                  i64,
}

// Transfer_Open_Receipt carries every field of the §6.3 download statement.
Transfer_Open_Receipt :: struct {
	owner_user_id:     string,
	vault_id:          string,
	epoch:             u32,
	transfer_id:       string,
	artifact_id:       string,
	verified:          bool, // signed "verified" | "unverified"
	ciphertext_bytes:  i64,
	ciphertext_sha256: string,
	device_id:         string,
	issued_ms:         i64,
}

// transfer_field_ok accepts a restricted single-line value: printable ASCII with no
// space, newline or control character, 1..256 bytes. MIME types such as
// "application/zip" and "text/plain;charset=utf-8" fit; free text does not.
transfer_field_ok :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > 256 do return false
	for i in 0 ..< len(s) {
		c := s[i]
		if c <= 0x20 || c >= 0x7f do return false
	}
	return true
}

@(private = "file")
sha_hex_ok :: proc(s: string) -> bool {
	return len(s) == 64 && is_lower_hex(s)
}

@(private = "file")
seal_fields_ok :: proc(r: ^Transfer_Seal_Receipt) -> bool {
	if !transfer_field_ok(r.owner_user_id) || !transfer_field_ok(r.transfer_id) || !transfer_field_ok(r.artifact_id) do return false
	if !transfer_field_ok(r.kind) || !transfer_field_ok(r.content_type) || !transfer_field_ok(r.device_id) do return false
	if len(r.vault_id) != VAULT_ID_HEX_CHARS || !is_lower_hex(r.vault_id) do return false
	if r.epoch == 0 || r.ciphertext_bytes <= 0 || r.issued_ms <= 0 do return false
	return sha_hex_ok(r.ciphertext_sha256) && sha_hex_ok(r.name_token_sha256) && sha_hex_ok(r.description_token_sha256) && sha_hex_ok(r.attestation_token_sha256)
}

@(private = "file")
open_fields_ok :: proc(r: ^Transfer_Open_Receipt) -> bool {
	if !transfer_field_ok(r.owner_user_id) || !transfer_field_ok(r.transfer_id) || !transfer_field_ok(r.artifact_id) || !transfer_field_ok(r.device_id) do return false
	if len(r.vault_id) != VAULT_ID_HEX_CHARS || !is_lower_hex(r.vault_id) do return false
	if r.epoch == 0 || r.ciphertext_bytes <= 0 || r.issued_ms <= 0 do return false
	return sha_hex_ok(r.ciphertext_sha256)
}

// transfer_seal_statement renders the canonical §6.1 statement, or fails when any
// field is not a restricted value.
transfer_seal_statement :: proc(r: Transfer_Seal_Receipt, allocator := context.allocator) -> (string, bool) {
	r := r
	if !seal_fields_ok(&r) do return "", false
	b := strings.builder_make(allocator)
	strings.write_string(&b, TRANSFER_RECEIPT_HEADER); strings.write_string(&b, "\nseal\n")
	strings.write_string(&b, r.owner_user_id); strings.write_byte(&b, '\n')
	strings.write_string(&b, r.vault_id); strings.write_string(&b, "\ne")
	strings.write_u64(&b, u64(r.epoch)); strings.write_byte(&b, '\n')
	strings.write_string(&b, r.transfer_id); strings.write_byte(&b, '\n')
	strings.write_string(&b, r.artifact_id); strings.write_byte(&b, '\n')
	strings.write_string(&b, r.kind); strings.write_byte(&b, '\n')
	strings.write_string(&b, r.content_type); strings.write_byte(&b, '\n')
	strings.write_i64(&b, r.ciphertext_bytes); strings.write_byte(&b, '\n')
	strings.write_string(&b, r.ciphertext_sha256); strings.write_byte(&b, '\n')
	strings.write_string(&b, r.name_token_sha256); strings.write_byte(&b, '\n')
	strings.write_string(&b, r.description_token_sha256); strings.write_byte(&b, '\n')
	strings.write_string(&b, r.attestation_token_sha256); strings.write_byte(&b, '\n')
	strings.write_string(&b, r.device_id); strings.write_byte(&b, '\n')
	strings.write_i64(&b, r.issued_ms)
	return strings.to_string(b), true
}

// transfer_open_statement renders the canonical §6.3 statement.
transfer_open_statement :: proc(r: Transfer_Open_Receipt, allocator := context.allocator) -> (string, bool) {
	r := r
	if !open_fields_ok(&r) do return "", false
	b := strings.builder_make(allocator)
	strings.write_string(&b, TRANSFER_RECEIPT_HEADER); strings.write_string(&b, "\nopen\n")
	strings.write_string(&b, r.owner_user_id); strings.write_byte(&b, '\n')
	strings.write_string(&b, r.vault_id); strings.write_string(&b, "\ne")
	strings.write_u64(&b, u64(r.epoch)); strings.write_byte(&b, '\n')
	strings.write_string(&b, r.transfer_id); strings.write_byte(&b, '\n')
	strings.write_string(&b, r.artifact_id); strings.write_byte(&b, '\n')
	strings.write_string(&b, r.verified ? "verified" : "unverified"); strings.write_byte(&b, '\n')
	strings.write_i64(&b, r.ciphertext_bytes); strings.write_byte(&b, '\n')
	strings.write_string(&b, r.ciphertext_sha256); strings.write_byte(&b, '\n')
	strings.write_string(&b, r.device_id); strings.write_byte(&b, '\n')
	strings.write_i64(&b, r.issued_ms)
	return strings.to_string(b), true
}

@(private = "file")
parse_positive_i64 :: proc(s: string) -> (i64, bool) {
	if len(s) == 0 || len(s) > 18 || s[0] < '1' || s[0] > '9' do return 0, false
	for i in 0 ..< len(s) do if s[i] < '0' || s[i] > '9' do return 0, false
	v, ok := strconv.parse_i64(s)
	return v, ok && v > 0
}

@(private = "file")
receipt_lines :: proc(text: string, verb: string, want: int) -> ([]string, bool) {
	if len(text) == 0 || len(text) > TRANSFER_RECEIPT_MAX_BYTES do return nil, false
	lines := strings.split(text, "\n", context.temp_allocator)
	if len(lines) != want || lines[0] != TRANSFER_RECEIPT_HEADER || lines[1] != verb do return nil, false
	if len(lines[4]) < 2 || lines[4][0] != 'e' do return nil, false
	return lines, true
}

// transfer_seal_receipt_parse parses a seal statement and re-renders it: only the
// exact canonical bytes are accepted. Strings alias text.
transfer_seal_receipt_parse :: proc(text: string) -> (r: Transfer_Seal_Receipt, ok: bool) {
	lines := receipt_lines(text, "seal", 16) or_return
	ep := parse_epoch(lines[4][1:]) or_return
	cb := parse_positive_i64(lines[9]) or_return
	ms := parse_positive_i64(lines[15]) or_return
	r = {owner_user_id = lines[2], vault_id = lines[3], epoch = ep, transfer_id = lines[5], artifact_id = lines[6], kind = lines[7], content_type = lines[8],
		ciphertext_bytes = cb, ciphertext_sha256 = lines[10], name_token_sha256 = lines[11], description_token_sha256 = lines[12],
		attestation_token_sha256 = lines[13], device_id = lines[14], issued_ms = ms}
	again := transfer_seal_statement(r, context.temp_allocator) or_return
	return r, again == text
}

// transfer_open_receipt_parse parses an open statement (canonical bytes only).
transfer_open_receipt_parse :: proc(text: string) -> (r: Transfer_Open_Receipt, ok: bool) {
	lines := receipt_lines(text, "open", 12) or_return
	ep := parse_epoch(lines[4][1:]) or_return
	verified: bool
	switch lines[7] {
	case "verified":   verified = true
	case "unverified": verified = false
	case:              return {}, false
	}
	cb := parse_positive_i64(lines[8]) or_return
	ms := parse_positive_i64(lines[11]) or_return
	r = {owner_user_id = lines[2], vault_id = lines[3], epoch = ep, transfer_id = lines[5], artifact_id = lines[6], verified = verified,
		ciphertext_bytes = cb, ciphertext_sha256 = lines[9], device_id = lines[10], issued_ms = ms}
	again := transfer_open_statement(r, context.temp_allocator) or_return
	return r, again == text
}

Transfer_Receipt_Error :: enum u8 {
	None,
	Malformed,
	Untrusted_Device, // not currently trusted in the verified directory
	Kind_Not_Allowed, // trusted, but its kind may not seal/open transfers
	Bad_Signature,
}

// transfer_receipt_signer_ok decides whether device_id may sign transfer receipts
// in dir: it must be CURRENTLY trusted (a revoked device fails) and be a bridge or a
// browser device (a recovery credential never handles content).
@(private = "file")
transfer_receipt_signer :: proc(dir: ^Verified_Directory, device_id: string) -> (Verified_Directory_Device, Transfer_Receipt_Error) {
	d, trusted := dir.trusted[device_id]
	if !trusted do return {}, .Untrusted_Device
	switch device_kind_from_id(d.kind) {
	case .Bridge, .Browser:
	case .Recovery, .Unknown:
		return {}, .Kind_Not_Allowed
	}
	return d, .None
}

// transfer_receipt_verify verifies signature_json over statement by device_id under
// the verified directory. The caller compares the parsed fields with its own row.
transfer_receipt_verify :: proc(dir: ^Verified_Directory, device_id, statement, signature_json: string) -> Transfer_Receipt_Error {
	if dir == nil || len(statement) == 0 || len(statement) > TRANSFER_RECEIPT_MAX_BYTES do return .Malformed
	d, err := transfer_receipt_signer(dir, device_id)
	if err != .None do return err
	if !verify(d.sign_alg, d.sign_public_key, transmute([]byte)statement, signature_json) do return .Bad_Signature
	return .None
}
