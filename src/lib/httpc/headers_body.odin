package httpc

import "core:c"
import "core:encoding/base64"
import "core:encoding/json"
import "core:strings"

CONTENT_TYPE_JSON :: "application/json"
CONTENT_TYPE_FORM :: "application/x-www-form-urlencoded"
CONTENT_TYPE_OCTET_STREAM :: "application/octet-stream"

// ---- header helpers -----------------------------------------------------------

// bearer is "Authorization: Bearer <token>". The value is temp-allocated.
bearer :: proc(token: string) -> Header {
	parts := [2]string{"Bearer ", token}
	return Header{name = "Authorization", value = strings.concatenate(parts[:], context.temp_allocator)}
}

accept :: proc(media_type: string) -> Header {
	return Header{name = "Accept", value = media_type}
}

accept_json :: proc() -> Header {
	return Header{name = "Accept", value = CONTENT_TYPE_JSON}
}

user_agent :: proc(value: string) -> Header {
	return Header{name = "User-Agent", value = value}
}

// oauth_client_basic is HTTP Basic client authentication for an OAuth 2.0 token
// endpoint (RFC 6749 §2.3.1): client id and secret are each form-urlencoded,
// joined with ':' and base64-encoded. Temp-allocated.
oauth_client_basic :: proc(client_id, client_secret: string) -> (h: Header, err: Error) {
	if ok, _ := init(); !ok do return {}, .Not_Initialized
	id := escape_temp(client_id) or_return
	secret := escape_temp(client_secret) or_return
	pair := [3]string{id, ":", secret}
	joined := strings.concatenate(pair[:], context.temp_allocator)
	encoded, b64_err := base64.encode(transmute([]byte)joined, allocator = context.temp_allocator)
	if b64_err != nil do return {}, .Internal
	value := [2]string{"Basic ", encoded}
	return Header{name = "Authorization", value = strings.concatenate(value[:], context.temp_allocator)}, .None
}

// Header names the wrapper (or libcurl) owns: setting them by hand would let a
// caller desynchronise framing or bypass the body's content type.
@(private)
RESERVED_HEADERS :: [?]string{
	"host", "content-length", "transfer-encoding", "connection", "expect",
	"content-type", "accept-encoding", "te", "upgrade", "keep-alive",
	"proxy-connection", "proxy-authorization", "trailer",
}

// header_valid reports whether a request header may be sent: the name is a
// non-empty RFC 9110 token and not reserved; the value carries no CR, LF, NUL or
// other control character except horizontal tab.
header_valid :: proc(h: Header) -> bool {
	if len(h.name) == 0 || len(h.name) > 256 do return false
	for i in 0..<len(h.name) {
		if !is_tchar(h.name[i]) do return false
	}
	for r in RESERVED_HEADERS {
		if strings.equal_fold(h.name, r) do return false
	}
	if len(h.value) > 16 * 1024 do return false
	for i in 0..<len(h.value) {
		b := h.value[i]
		if (b < 0x20 && b != '\t') || b == 0x7f do return false
	}
	return true
}

@(private)
is_tchar :: proc(b: byte) -> bool {
	switch {
	case b >= 'a' && b <= 'z', b >= 'A' && b <= 'Z', b >= '0' && b <= '9':
		return true
	}
	switch b {
	case '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~':
		return true
	}
	return false
}

// ---- bodies -----------------------------------------------------------------

// json_body marshals `value` with core:encoding/json now (so the body never
// aliases a caller temporary). Bytes are allocated with `allocator`.
json_body :: proc(value: any, allocator := context.temp_allocator) -> Body {
	data, err := json.marshal(value, allocator = allocator)
	if err != nil do return Json_Body{failed = true}
	return Json_Body{encoded = data}
}

// form_body sends fields as application/x-www-form-urlencoded, each name and
// value percent-encoded by libcurl. `fields` must outlive send().
form_body :: proc(fields: []Form_Field) -> Body {
	return Form_Body{fields = fields}
}

// raw_body sends bytes verbatim with the given content type (binary payloads
// such as an encrypted Web Push record).
raw_body :: proc(content_type: string, bytes: []byte) -> Body {
	return Raw_Body{content_type = content_type, bytes = bytes}
}

// relay_json_body forwards a JSON document received verbatim from a peer (an
// agent's request body the bridge relays to the hub). Never build the bytes by
// hand: marshal a value with json_body instead.
relay_json_body :: proc(document: string) -> Body {
	return Raw_Body{content_type = CONTENT_TYPE_JSON, bytes = transmute([]byte)document}
}

@(private)
escape_temp :: proc(s: string) -> (string, Error) {
	if len(s) == 0 do return "", .None
	escaped := curl_easy_escape(nil, raw_data(s), c.int(len(s)))
	if escaped == nil do return "", .Internal
	defer curl_free(rawptr(escaped))
	return strings.clone(string(escaped), context.temp_allocator), .None
}

// encode_form renders fields as "a=1&b=2" with libcurl's percent-encoding.
@(private)
encode_form :: proc(fields: []Form_Field) -> (out: string, err: Error) {
	b := strings.builder_make(context.temp_allocator)
	for f, i in fields {
		if f.name == "" do return "", .Invalid_Body
		if i > 0 do strings.write_byte(&b, '&')
		strings.write_string(&b, escape_temp(f.name) or_return)
		strings.write_byte(&b, '=')
		strings.write_string(&b, escape_temp(f.value) or_return)
	}
	return strings.to_string(b), .None
}
