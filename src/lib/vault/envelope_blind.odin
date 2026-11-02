package vault

// ── Blind (keyless) canonical-token checking (docs/plans/mcp-large-artifact-transfers.md §5.4) ──
//
// The Hub stages E2EE artifact transfers as ciphertext only and must enforce the
// decoded 15 MiB content limit WITHOUT any key and WITHOUT decoding the payload into
// a buffer. Blind_Token_Check consumes a token in arbitrary chunks (as they arrive
// from the network or from chunk rows) and decides, at finish, whether the bytes are
// exactly ONE canonical v2 token:
//
//	vault:v2:<16 lowercase hex>:e<[1-9][0-9]{0,9}>:<strict padded base64>
//
// and how many plaintext bytes it carries (AES-GCM: len(ct) == len(pt), so
// plaintext = decoded payload - 28-byte nonce|tag). Nothing here holds or derives
// key material; this file must never import a cipher.

BLIND_MAX_HEADER_LEN :: len(VAULT_V2_PREFIX) + VAULT_ID_HEX_CHARS + 2 + 10 + 1 // 38

Blind_Token_Phase :: enum u8 {
	Header,
	Body,
	Padding,
	Failed,
}

Blind_Token_Check :: struct {
	phase:      Blind_Token_Phase,
	header:     [BLIND_MAX_HEADER_LEN]byte,
	header_len: int,
	body_chars: int,  // base64 characters before padding
	pad:        int,  // '=' characters (0..2)
	last_value: u8,   // value of the last non-pad base64 character
	total:      int,  // bytes consumed
}

Blind_Token_Info :: struct {
	vault_id:        Vault_Id,
	epoch:           u32,
	token_bytes:     int,
	payload_bytes:   int,
	plaintext_bytes: int,
}

// blind_token_check_init resets c.
blind_token_check_init :: proc(c: ^Blind_Token_Check) {
	c^ = {}
}

// blind_token_check_update feeds the next chunk. It returns false as soon as the
// stream can no longer be a single canonical token (the check stays failed).
blind_token_check_update :: proc(c: ^Blind_Token_Check, data: []byte) -> bool {
	for b in data {
		if !blind_token_step(c, b) {
			c.phase = .Failed
			return false
		}
	}
	return c.phase != .Failed
}

@(private = "file")
blind_token_step :: proc(c: ^Blind_Token_Check, b: byte) -> bool {
	c.total += 1
	switch c.phase {
	case .Failed:
		return false
	case .Header:
		if c.header_len >= BLIND_MAX_HEADER_LEN do return false
		i := c.header_len
		c.header[i] = b
		c.header_len += 1
		p := len(VAULT_V2_PREFIX)
		switch {
		case i < p:
			prefix := VAULT_V2_PREFIX
			return b == prefix[i]
		case i < p + VAULT_ID_HEX_CHARS:
			return (b >= '0' && b <= '9') || (b >= 'a' && b <= 'f')
		case i == p + VAULT_ID_HEX_CHARS:
			return b == ':'
		case i == p + VAULT_ID_HEX_CHARS + 1:
			return b == 'e'
		case i == p + VAULT_ID_HEX_CHARS + 2:
			return b >= '1' && b <= '9'
		case:
			if b == ':' {
				c.phase = .Body
				return true
			}
			// at most 10 epoch digits: index of the 10th digit is p+16+2+9
			return b >= '0' && b <= '9' && i <= p + VAULT_ID_HEX_CHARS + 2 + 9
		}
	case .Body:
		if b == '=' {
			if c.body_chars == 0 do return false
			c.phase = .Padding
			c.pad = 1
			return true
		}
		if !is_b64_char(b) do return false
		c.body_chars += 1
		c.last_value = b64_value(b)
		return true
	case .Padding:
		if b != '=' || c.pad >= 2 do return false
		c.pad += 1
		return true
	}
	return false
}

// blind_token_check_finish validates the complete stream and returns the token's
// header fields and the exact plaintext length. ok is false unless the bytes were
// exactly one canonical token whose payload holds at least the nonce and tag.
blind_token_check_finish :: proc(c: ^Blind_Token_Check) -> (info: Blind_Token_Info, ok: bool) {
	if c.phase != .Body && c.phase != .Padding do return {}, false
	chars := c.body_chars + c.pad
	if chars == 0 || chars % 4 != 0 do return {}, false
	// Non-zero bits under the padding make a second spelling of the same bytes.
	if c.pad == 2 && c.last_value & 0x0f != 0 do return {}, false
	if c.pad == 1 && c.last_value & 0x03 != 0 do return {}, false
	header := string(c.header[:c.header_len])
	p := len(VAULT_V2_PREFIX)
	vid, vid_ok := vault_id_from_hex(header[p:p + VAULT_ID_HEX_CHARS])
	if !vid_ok do return {}, false
	ep, ep_ok := parse_epoch(header[p + VAULT_ID_HEX_CHARS + 2:c.header_len - 1])
	if !ep_ok do return {}, false
	payload := (chars / 4) * 3 - c.pad
	if payload < HEADER_BYTES || payload > MAX_PAYLOAD_BYTES do return {}, false
	return Blind_Token_Info{vault_id = vid, epoch = ep, token_bytes = c.total, payload_bytes = payload, plaintext_bytes = payload - HEADER_BYTES}, true
}

// blind_token_check_string checks one complete in-memory token (small values such as
// sealed names, descriptions and attestations).
blind_token_check_string :: proc(token: string) -> (info: Blind_Token_Info, ok: bool) {
	c: Blind_Token_Check
	if !blind_token_check_update(&c, transmute([]byte)token) do return {}, false
	return blind_token_check_finish(&c)
}

// blind_armored_len returns the exact token length of a plaintext of n bytes under a
// header of header_len characters (test and budget helper).
blind_armored_len :: proc(n: int, header_len: int) -> int {
	return header_len + 4 * ((n + HEADER_BYTES + 2) / 3)
}
