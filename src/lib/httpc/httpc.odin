// Package httpc is Heimdall's ONLY outbound HTTP client. It wraps libcurl; no
// other package may import libcurl, `vendor:curl`, or hand-roll HTTP over
// `core:net` (scripts/check-http-boundary.sh enforces this). See README.md.
//
// Rules for callers:
//   - Never build a URL, query string, header line or request body with string
//     interpolation or builders. Describe the request instead:
//       base  : a parsed absolute URL (parse_url), validated by libcurl
//       path  : []string segments, each percent-encoded by libcurl
//       query : []Query_Param, encoded by libcurl's URL API
//       headers: []Header, validated here (no CR/LF/NUL, token names)
//       body  : json_body(value) / form_body(fields) / raw_body(type, bytes)
//   - Read results through Response (status, headers, body, may_have_sent) and
//     the typed Error; never through curl codes.
//
// Call init() once in main(), before any thread starts.
package httpc

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"

// MIN_CURL_VERSION is the oldest libcurl this package runs against (checked by
// init, before any other libcurl call). 7.80.0 is set by the newest thing used:
//   CURLOPT_PREREQFUNCTION/PREREQDATA  7.80.0  (may_have_sent)
// Everything else is older: curl_url/curl_url_set/curl_url_get/curl_url_cleanup,
// CURLU_URLENCODE, CURLU_APPENDQUERY 7.62.0; CURLOPT_CURLU 7.63.0;
// CURLOPT_XFERINFOFUNCTION 7.32.0; CURLOPT_PROTOCOLS/REDIR_PROTOCOLS 7.19.4;
// CURLOPT_ACCEPT_ENCODING 7.21.6; *_LARGE / *_MS options, curl_easy_escape,
// curl_slist_*, curl_version_info, curl_global_init and CURLOPT_HEADERFUNCTION
// predate 7.20. Response headers are collected with CURLOPT_HEADERFUNCTION, not
// curl_easy_header (7.83/7.84), so no binding names a symbol missing from 7.80:
// on an older libcurl the binary still loads and init() reports the version.
// CURLE_TOO_LARGE (8.6) is only a code value we map, not a symbol.
// The later WebSocket migration (curl_ws_*) needs 8.11.0.
MIN_CURL_VERSION :: 0x075000
MIN_CURL_VERSION_TEXT :: "7.80.0"

// MAX_RESPONSE_HEADER_BYTES caps the headers of one response (all lines,
// counted per status line); more is .Too_Large.
MAX_RESPONSE_HEADER_BYTES :: 64 * 1024

DEFAULT_TIMEOUT_MS :: 20_000
// For transfers whose size is not bounded by a short budget (ham-ctl, the
// bridge's agent relays, release downloads): a generous total plus a stall
// guard (Request.stall_timeout_ms) restores the old client's "20 s without
// progress" meaning instead of failing a large, healthy response at 20 s.
LONG_TRANSFER_TIMEOUT_MS :: 10 * 60_000
DEFAULT_STALL_TIMEOUT_MS :: 20_000
// DEFAULT_MAX_RESPONSE_BYTES must stay well above the largest response a hub
// legitimately returns: an artifact (content_service.ARTIFACT_MAX_BYTES, 50 MB)
// comes back inside a JSON document, so escaping can grow it. The deleted
// client had no cap; callers talking to third parties set a tight one.
DEFAULT_MAX_RESPONSE_BYTES :: 256 * 1024 * 1024
DEFAULT_USER_AGENT :: "heimdall/" + contracts.APP_VERSION

Method :: enum u8 {
	GET,
	HEAD,
	POST,
	PUT,
	PATCH,
	DELETE,
}

// method_parse maps a method name received on the wire (e.g. a relayed agent
// request) to a Method. Case-sensitive, as HTTP methods are.
method_parse :: proc(name: string) -> (Method, bool) {
	switch name {
	case "GET": return .GET, true
	case "HEAD": return .HEAD, true
	case "POST": return .POST, true
	case "PUT": return .PUT, true
	case "PATCH": return .PATCH, true
	case "DELETE": return .DELETE, true
	}
	return .GET, false
}

method_name :: proc(m: Method) -> string {
	switch m {
	case .GET: return "GET"
	case .HEAD: return "HEAD"
	case .POST: return "POST"
	case .PUT: return "PUT"
	case .PATCH: return "PATCH"
	case .DELETE: return "DELETE"
	}
	return "GET"
}

// Url is an absolute http(s) URL that libcurl parsed and normalised. Build one
// with parse_url; requests append path segments and query parameters to it.
Url :: struct {
	_text: string, // canonical form from curl_url_get; "" = not parsed
}

Query_Param :: struct {
	name, value: string,
}

Header :: struct {
	name, value: string,
}

Form_Field :: struct {
	name, value: string,
}

Json_Body :: struct {
	encoded: []byte,
	failed:  bool, // json.marshal failed; send() reports .Invalid_Body
}
Form_Body :: struct {
	fields: []Form_Field,
}
Raw_Body :: struct {
	content_type: string,
	bytes:        []byte,
}
// Body: nil (no body), JSON, form-urlencoded, or raw bytes with a content type.
Body :: union {
	Json_Body,
	Form_Body,
	Raw_Body,
}

Request :: struct {
	method:  Method,
	url:     Url,
	// Path segments appended to url's path; each is percent-encoded as ONE
	// segment ("a/b" becomes "a%2Fb"). Empty segments, "." and ".." are rejected.
	path:    []string,
	query:   []Query_Param,
	// relay_target: an origin-form "/path?query" received verbatim from a peer
	// protocol (the bridge's agent.rest.request relay) and forwarded unchanged
	// under url's path. Validated, never built: code that constructs a request
	// itself uses path + query. Mutually exclusive with path/query.
	relay_target: string,
	headers: []Header,
	body:    Body,
	// Total budget for DNS + connect + TLS + request + response (0 = default).
	timeout_ms:         int,
	// Connect phase budget (0 = the total budget).
	connect_timeout_ms: int,
	// Abort with .Timeout when no byte moves in either direction for this long
	// (0 = off), including while waiting for the reply (checked by the progress
	// callback, about once a second). Use with a long timeout_ms.
	stall_timeout_ms:   int,
	// Response body cap (0 = DEFAULT_MAX_RESPONSE_BYTES). Larger => .Too_Large.
	max_response_bytes: int,
	// 3xx redirects to follow (0 = none: a 3xx is returned as the response).
	max_redirects:      int,
	// Optional: set (atomically) to true from another thread to abort => .Aborted.
	cancel:             ^bool,
}

Error :: enum u8 {
	None,
	Not_Initialized, // init() failed or libcurl is older than MIN_CURL_VERSION
	Invalid_Url,
	Invalid_Header,
	Invalid_Body,
	Dns,
	Connect,
	Tls,             // handshake / protocol failure
	Certificate,     // peer certificate or trust anchor problem
	Timeout,
	Too_Large,
	Send,
	Recv,
	Protocol,        // malformed / empty / truncated reply, bad content encoding
	Too_Many_Redirects,
	Aborted,
	Io,              // local file I/O (download_to_file)
	Decode,          // send_json: the 2xx body did not decode into the target
	Internal,
}

error_string :: proc(err: Error) -> string {
	switch err {
	case .None: return "ok"
	case .Not_Initialized: return "http client not initialised (libcurl missing or too old)"
	case .Invalid_Url: return "invalid URL"
	case .Invalid_Header: return "invalid header"
	case .Invalid_Body: return "invalid request body"
	case .Dns: return "DNS resolution failed"
	case .Connect: return "connect failed"
	case .Tls: return "TLS handshake failed"
	case .Certificate: return "TLS certificate verification failed"
	case .Timeout: return "timed out"
	case .Too_Large: return "response too large"
	case .Send: return "send failed"
	case .Recv: return "receive failed"
	case .Protocol: return "malformed HTTP response"
	case .Too_Many_Redirects: return "too many redirects"
	case .Aborted: return "aborted"
	case .Io: return "local I/O error"
	case .Decode: return "response did not decode"
	case .Internal: return "internal error"
	}
	return "unknown"
}

// Response owns its headers and body (allocated with the allocator passed to
// send). Release with response_destroy.
Response :: struct {
	status:  int, // 0 when no HTTP response arrived
	headers: []Header,
	body:    []byte,
	// True once any request byte may have left this host: the connection (and TLS
	// handshake) completed and libcurl began sending. False means the server
	// cannot have seen the request (DNS, connect or TLS failure, invalid
	// request). Every response that carries a status has it set. The bridge's
	// refresh journal uses it to fence replay of non-idempotent POSTs.
	may_have_sent: bool,
	// Short human-readable failure detail for logs (libcurl's error buffer); never
	// contains request headers or bodies.
	detail:  string,
	_allocator: runtime.Allocator,
}

// Response_Meta is what send_json returns: no allocations to free.
Response_Meta :: struct {
	status:        int,
	may_have_sent: bool,
}

response_destroy :: proc(r: ^Response) {
	if r == nil do return
	a := r._allocator
	if a.procedure == nil do a = context.allocator
	for h in r.headers {
		delete(h.name, a)
		delete(h.value, a)
	}
	delete(r.headers, a)
	delete(r.body, a)
	delete(r.detail, a)
	r^ = {}
}

// text views the body as a string (no copy; valid until response_destroy).
text :: proc(r: Response) -> string {
	return string(r.body)
}

// header returns the LAST value of a response header, ASCII-case-insensitively.
header :: proc(r: Response, name: string) -> (string, bool) {
	#reverse for h in r.headers {
		if strings.equal_fold(h.name, name) do return h.value, true
	}
	return "", false
}

ok_status :: proc(status: int) -> bool {
	return status >= 200 && status < 300
}

// ---- global init -------------------------------------------------------------

@(private) g_init_once: sync.Once
@(private) g_init_ok: bool
@(private) g_init_message: string
@(private) g_version_text: string

// init initialises libcurl exactly once (curl_global_init is not thread-safe on
// older libcurl, so call this from main() before starting threads) and checks the
// linked libcurl is at least MIN_CURL_VERSION. On failure it returns a message
// the caller should print before exiting.
init :: proc() -> (ok: bool, message: string) {
	sync.once_do(&g_init_once, proc() {
		info := curl_version_info(CURLVERSION_FIRST)
		if info == nil {
			g_init_message = "libcurl: curl_version_info returned nothing"
			return
		}
		g_version_text = strings.clone(string(info.version), runtime.heap_allocator())
		if uint(info.version_num) < MIN_CURL_VERSION {
			g_init_message = fmt.aprintf("libcurl %s is too old: Heimdall needs libcurl >= %s", g_version_text, MIN_CURL_VERSION_TEXT, allocator = runtime.heap_allocator())
			return
		}
		if rc := curl_global_init(CURL_GLOBAL_ALL); rc != CURLE_OK {
			g_init_message = fmt.aprintf("libcurl: curl_global_init failed: %s", curl_easy_strerror(rc), allocator = runtime.heap_allocator())
			return
		}
		g_init_ok = true
	})
	return g_init_ok, g_init_message
}

// libcurl_version is the linked libcurl's version string ("" before init).
libcurl_version :: proc() -> string {
	_, _ = init()
	return g_version_text
}

// ---- URLs --------------------------------------------------------------------

// parse_url validates an absolute http(s) URL with libcurl's URL parser and
// returns its canonical form. Rejected: other schemes, missing host,
// user:password, fragments. The text is allocated with `allocator`.
parse_url :: proc(raw: string, allocator := context.temp_allocator) -> (u: Url, err: Error) {
	if ok, _ := init(); !ok do return {}, .Not_Initialized
	if !text_is_clean(raw) do return {}, .Invalid_Url
	h := curl_url()
	if h == nil do return {}, .Internal
	defer curl_url_cleanup(h)
	craw := strings.clone_to_cstring(strings.trim_space(raw), context.temp_allocator)
	if curl_url_set(h, CURLUPART_URL, craw, CURLU_DISALLOW_USER) != CURLUE_OK do return {}, .Invalid_Url
	scheme := url_part(h, CURLUPART_SCHEME) or_return
	defer curl_free(rawptr(scheme))
	if scheme != "http" && scheme != "https" do return {}, .Invalid_Url
	if url_part_present(h, CURLUPART_FRAGMENT) do return {}, .Invalid_Url
	if url_part_present(h, CURLUPART_PASSWORD) || url_part_present(h, CURLUPART_USER) do return {}, .Invalid_Url
	host := url_part(h, CURLUPART_HOST) or_return
	curl_free(rawptr(host))
	full := url_part(h, CURLUPART_URL) or_return
	defer curl_free(rawptr(full))
	return Url{_text = strings.clone(string(full), allocator)}, .None
}

// url_from_parts builds "<scheme>://<host>:<port>/" from parts with libcurl's
// URL API (no string formatting by the caller), e.g. a loopback probe target.
// scheme must be "http" or "https"; port 1..65535. Allocated with `allocator`.
url_from_parts :: proc(scheme, host: string, port: int, allocator := context.temp_allocator) -> (u: Url, err: Error) {
	if ok, _ := init(); !ok do return {}, .Not_Initialized
	if scheme != "http" && scheme != "https" do return {}, .Invalid_Url
	if port <= 0 || port > 65535 || host == "" || !text_is_clean(host) do return {}, .Invalid_Url
	h := curl_url()
	if h == nil do return {}, .Internal
	defer curl_url_cleanup(h)
	port_buf: [8]byte
	port_text := strconv.write_int(port_buf[:], i64(port), 10)
	if curl_url_set(h, CURLUPART_SCHEME, strings.clone_to_cstring(scheme, context.temp_allocator), 0) != CURLUE_OK do return {}, .Invalid_Url
	host_part := host
	if strings.index_byte(host, ':') >= 0 && !strings.has_prefix(host, "[") {
		bracketed := [3]string{"[", host, "]"} // IPv6 literal
		host_part = strings.concatenate(bracketed[:], context.temp_allocator)
	}
	if curl_url_set(h, CURLUPART_HOST, strings.clone_to_cstring(host_part, context.temp_allocator), 0) != CURLUE_OK do return {}, .Invalid_Url
	if curl_url_set(h, CURLUPART_PORT, strings.clone_to_cstring(port_text, context.temp_allocator), 0) != CURLUE_OK do return {}, .Invalid_Url
	full := url_part(h, CURLUPART_URL) or_return
	defer curl_free(rawptr(full))
	return Url{_text = strings.clone(string(full), allocator)}, .None
}

// url_string is the canonical text of a parsed URL, for logs and equality
// checks. Never concatenate onto it; use Request.path / Request.query.
url_string :: proc(u: Url) -> string {
	return u._text
}

url_is_https :: proc(u: Url) -> bool {
	return strings.has_prefix(u._text, "https://")
}

url_destroy :: proc(u: ^Url, allocator := context.allocator) {
	delete(u._text, allocator)
	u^ = {}
}

// build_url renders base + path segments + query as a URL string (allocated with
// `allocator`) for places that hand a URL to someone else rather than fetch it:
// a browser redirect, a log line, a relayed target. Same encoding as send().
build_url :: proc(base: Url, path: []string = nil, query: []Query_Param = nil, allocator := context.allocator) -> (out: string, err: Error) {
	if ok, _ := init(); !ok do return "", .Not_Initialized
	h := request_url_handle(base, path, query, "") or_return
	defer curl_url_cleanup(h)
	full := url_part(h, CURLUPART_URL) or_return
	defer curl_free(rawptr(full))
	return strings.clone(string(full), allocator), .None
}

// build_target renders path segments + query as an origin-form "/a/b?x=y" string
// (allocated with `allocator`), for protocols that carry a request target as a
// field (the agent.rest.request relay). Same encoding as send().
build_target :: proc(path: []string, query: []Query_Param = nil, allocator := context.allocator) -> (out: string, err: Error) {
	if ok, _ := init(); !ok do return "", .Not_Initialized
	base := Url{_text = "http://relay.invalid/"}
	h := request_url_handle(base, path, query, "") or_return
	defer curl_url_cleanup(h)
	p := url_part(h, CURLUPART_PATH) or_return
	defer curl_free(rawptr(p))
	q, qerr := url_part(h, CURLUPART_QUERY)
	if qerr != .None do return strings.clone(string(p), allocator), .None
	defer curl_free(rawptr(q))
	parts := [3]string{string(p), "?", string(q)}
	return strings.concatenate(parts[:], allocator), .None
}

@(private)
url_part :: proc(h: ^CURLU, what: c.int) -> (cstring, Error) {
	out: cstring
	if curl_url_get(h, what, &out, 0) != CURLUE_OK || out == nil do return nil, .Invalid_Url
	return out, .None
}

@(private)
url_part_present :: proc(h: ^CURLU, what: c.int) -> bool {
	out: cstring
	if curl_url_get(h, what, &out, 0) != CURLUE_OK do return false
	if out != nil do curl_free(rawptr(out))
	return true
}

// text_is_clean: no control characters at all (CR/LF/NUL/TAB/DEL).
@(private)
text_is_clean :: proc(s: string) -> bool {
	for i in 0..<len(s) {
		b := s[i]
		if b < 0x20 || b == 0x7f do return false
	}
	return true
}

// request_url_handle builds the CURLU for a request. The caller frees it.
@(private)
request_url_handle :: proc(base: Url, path: []string, query: []Query_Param, relay_target: string) -> (^CURLU, Error) {
	if base._text == "" do return nil, .Invalid_Url
	if relay_target != "" && (len(path) > 0 || len(query) > 0) do return nil, .Invalid_Url
	h := curl_url()
	if h == nil do return nil, .Internal
	ok := false
	defer if !ok do curl_url_cleanup(h)
	cbase := strings.clone_to_cstring(base._text, context.temp_allocator)
	if curl_url_set(h, CURLUPART_URL, cbase, CURLU_DISALLOW_USER) != CURLUE_OK do return nil, .Invalid_Url

	base_path := ""
	if p, perr := url_part(h, CURLUPART_PATH); perr == .None {
		base_path = strings.clone(string(p), context.temp_allocator)
		curl_free(rawptr(p))
	}
	prefix := strings.trim_right(base_path, "/")

	if relay_target != "" {
		target_path, target_query, valid := relay_target_split(relay_target)
		if !valid do return nil, .Invalid_Url
		joined := [2]string{prefix, target_path}
		cpath := strings.clone_to_cstring(strings.concatenate(joined[:], context.temp_allocator), context.temp_allocator)
		if curl_url_set(h, CURLUPART_PATH, cpath, 0) != CURLUE_OK do return nil, .Invalid_Url
		if target_query != "" {
			// Replace any base query: the relayed target is the whole request target.
			cq := strings.clone_to_cstring(target_query, context.temp_allocator)
			if curl_url_set(h, CURLUPART_QUERY, cq, 0) != CURLUE_OK do return nil, .Invalid_Url
		}
		ok = true
		return h, .None
	}

	if len(path) > 0 {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, prefix)
		for seg in path {
			if seg == "" || seg == "." || seg == ".." || !text_is_clean(seg) do return nil, .Invalid_Url
			escaped := curl_easy_escape(nil, raw_data(seg), c.int(len(seg)))
			if escaped == nil do return nil, .Internal
			strings.write_byte(&b, '/')
			strings.write_string(&b, string(escaped))
			curl_free(rawptr(escaped))
		}
		cpath := strings.clone_to_cstring(strings.to_string(b), context.temp_allocator)
		if curl_url_set(h, CURLUPART_PATH, cpath, 0) != CURLUE_OK do return nil, .Invalid_Url
	}

	for q in query {
		// curl splits "name=value" at the FIRST '=' and percent-encodes both halves
		// (CURLU_URLENCODE), so a name must not contain '='.
		if q.name == "" || strings.index_byte(q.name, '=') >= 0 || !text_is_clean(q.name) || !text_is_clean(q.value) do return nil, .Invalid_Url
		pair := [3]string{q.name, "=", q.value}
		cpair := strings.clone_to_cstring(strings.concatenate(pair[:], context.temp_allocator), context.temp_allocator)
		if curl_url_set(h, CURLUPART_QUERY, cpair, CURLU_APPENDQUERY | CURLU_URLENCODE) != CURLUE_OK do return nil, .Invalid_Url
	}
	ok = true
	return h, .None
}

// relay_target_split validates an origin-form target: "/" then pchars, '/', and
// an optional "?query"; percent escapes must be well formed; no fragment, no
// spaces or controls, no "//" authority form, no dot segments.
@(private)
relay_target_split :: proc(target: string) -> (path: string, query: string, ok: bool) {
	if len(target) == 0 || target[0] != '/' do return "", "", false
	if len(target) > 1 && target[1] == '/' do return "", "", false
	path = target
	if q := strings.index_byte(target, '?'); q >= 0 {
		path = target[:q]
		query = target[q + 1:]
	}
	if !target_chars_ok(path, false) || !target_chars_ok(query, true) do return "", "", false
	rest := path
	for seg in strings.split_iterator(&rest, "/") {
		if seg == "." || seg == ".." || seg == "%2e" || seg == "%2E" || strings.equal_fold(seg, "%2e%2e") do return "", "", false
	}
	return path, query, true
}

@(private)
target_chars_ok :: proc(s: string, is_query: bool) -> bool {
	i := 0
	for i < len(s) {
		b := s[i]
		switch {
		case b >= 'a' && b <= 'z', b >= 'A' && b <= 'Z', b >= '0' && b <= '9':
		case b == '-' || b == '.' || b == '_' || b == '~':
		case b == '!' || b == '$' || b == '&' || b == '\'' || b == '(' || b == ')' || b == '*' || b == '+' || b == ',' || b == ';' || b == '=':
		case b == ':' || b == '@' || b == '/':
		case b == '?' && is_query:
		case b == '%':
			if i + 2 > len(s) - 1 do return false
			if !is_hex(s[i + 1]) || !is_hex(s[i + 2]) do return false
			i += 2
		case:
			return false
		}
		i += 1
	}
	return true
}

@(private)
is_hex :: proc(b: byte) -> bool {
	return (b >= '0' && b <= '9') || (b >= 'a' && b <= 'f') || (b >= 'A' && b <= 'F')
}
