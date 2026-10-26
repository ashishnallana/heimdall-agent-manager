package httpc

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

// send performs one request on a fresh libcurl easy handle (no connection reuse:
// every request opens its own connection, as the old client did with
// `Connection: close`, so libcurl can never silently replay a request on a
// stale pooled connection). The response is allocated with `allocator`; release
// it with response_destroy. On failure the Response still carries may_have_sent
// and a short detail; status, headers and body are empty.
send :: proc(req: Request, allocator := context.allocator) -> (Response, Error) {
	t := Transfer{allocator = allocator, ctx = context, mode = .Memory}
	err := perform(req, &t)
	resp := Response{_allocator = allocator, may_have_sent = t.prereq_reached || t.status > 0}
	if err != .None {
		delete(t.body)
		free_headers(t.headers[:], allocator)
		delete(t.headers)
		resp.detail = strings.clone(t.detail, allocator)
		return resp, err
	}
	resp.status = t.status
	resp.headers = t.headers[:]
	shrink(&t.body)
	resp.body = t.body[:]
	return resp, .None
}

// send_json performs `req` and, for a 2xx reply, decodes the body into `out`
// with json.unmarshal (strings and slices allocated with `allocator`). A non-2xx
// reply is returned in meta.status with `out` untouched and no error. The body
// is capped at max_response_bytes (default DEFAULT_MAX_RESPONSE_BYTES).
send_json :: proc(req: Request, out: ^$T, allocator := context.allocator) -> (Response_Meta, Error) {
	resp, err := send(req, context.temp_allocator)
	defer response_destroy(&resp)
	meta := Response_Meta{status = resp.status, may_have_sent = resp.may_have_sent}
	if err != .None do return meta, err
	if !ok_status(resp.status) do return meta, .None
	if json.unmarshal(resp.body, out, allocator = allocator) != nil do return meta, .Decode
	return meta, .None
}

// download_to_file streams a GET into `dest_path` without buffering it: the body
// goes to "<dest_path>.part", renamed over dest_path only after a complete 200.
// Any other outcome removes the .part file and leaves dest_path untouched.
// Follows up to req.max_redirects redirects (callers downloading release assets
// pass e.g. 5). Success is (200, .None).
download_to_file :: proc(req: Request, dest_path: string) -> (status: int, err: Error) {
	parts := [2]string{dest_path, ".part"}
	part_path := strings.concatenate(parts[:], context.temp_allocator)
	f, open_err := os.open(part_path, os.File_Flags{.Write, .Create, .Trunc}, os.Permissions_Default_File)
	if open_err != nil do return 0, .Io
	t := Transfer{allocator = context.temp_allocator, ctx = context, mode = .File, file = f}
	dl := req
	if dl.max_response_bytes == 0 do dl.max_response_bytes = 1 << 31
	err = perform(dl, &t)
	_ = os.close(f)
	free_headers(t.headers[:], context.temp_allocator)
	if err != .None || t.status != 200 {
		_ = os.remove(part_path)
		return t.status if err == .None else 0, err
	}
	if os.rename(part_path, dest_path) != nil {
		_ = os.remove(part_path)
		return 0, .Io
	}
	return 200, .None
}

// ---- internals -----------------------------------------------------------------

@(private)
Sink_Mode :: enum u8 {
	Memory,
	File,
}

@(private)
Transfer :: struct {
	allocator:      runtime.Allocator,
	ctx:            runtime.Context,
	mode:           Sink_Mode,
	body:           [dynamic]byte,
	file:           ^os.File,
	received:       int,
	limit:          int,
	too_large:      bool,
	io_failed:      bool,
	prereq_reached: bool,
	cancel:         ^bool,
	stall:          time.Duration, // 0 = no stall guard
	last_progress:  time.Tick,
	last_dl:        i64,
	last_ul:        i64,
	stalled:        bool,
	status:         int,
	headers:        [dynamic]Header, // the current (final) response's headers
	header_bytes:   int,
	body_started:   bool, // header lines after the body are trailers: ignored
	detail:         string, // temp-allocated
}

@(private)
EMPTY_BODY: cstring = ""
@(private)
CS_EMPTY: cstring = ""
@(private)
CS_USER_AGENT: cstring = DEFAULT_USER_AGENT

@(private)
free_headers :: proc(hs: []Header, allocator: runtime.Allocator) {
	for h in hs {
		delete(h.name, allocator)
		delete(h.value, allocator)
	}
}

@(private)
perform :: proc(req: Request, t: ^Transfer) -> Error {
	if ok, msg := init(); !ok {
		t.detail = msg
		return .Not_Initialized
	}
	if req.timeout_ms < 0 do return .Timeout
	for h in req.headers {
		if !header_valid(h) do return .Invalid_Header
	}

	// Body bytes + content type.
	body_bytes: []byte
	content_type := ""
	has_body := false
	switch b in req.body {
	case Json_Body:
		if b.failed do return .Invalid_Body
		body_bytes, content_type, has_body = b.encoded, CONTENT_TYPE_JSON, true
	case Form_Body:
		encoded := encode_form(b.fields) or_return
		body_bytes, content_type, has_body = transmute([]byte)encoded, CONTENT_TYPE_FORM, true
	case Raw_Body:
		if !header_valid(Header{name = "X-Content-Type-Check", value = b.content_type}) || b.content_type == "" do return .Invalid_Body
		body_bytes, content_type, has_body = b.bytes, b.content_type, true
	}
	if has_body && (req.method == .GET || req.method == .HEAD) do return .Invalid_Body

	easy := curl_easy_init()
	if easy == nil do return .Internal
	defer curl_easy_cleanup(easy)

	urlh := request_url_handle(req.url, req.path, req.query, req.relay_target) or_return
	defer curl_url_cleanup(urlh)

	// Header list. This is the only place a "Name: value" line is formed.
	list: ^curl_slist
	defer if list != nil do curl_slist_free_all(list)
	append_line :: proc(list: ^^curl_slist, name, value: string) -> bool {
		line: string
		if value == "" {
			// "Name;" sends an empty header; "Name:" would delete it.
			parts := [2]string{name, ";"}
			line = strings.concatenate(parts[:], context.temp_allocator)
		} else {
			parts := [3]string{name, ": ", value}
			line = strings.concatenate(parts[:], context.temp_allocator)
		}
		next := curl_slist_append(list^, strings.clone_to_cstring(line, context.temp_allocator))
		if next == nil do return false
		list^ = next
		return true
	}
	remove_line :: proc(list: ^^curl_slist, name: string) -> bool {
		parts := [2]string{name, ":"}
		next := curl_slist_append(list^, strings.clone_to_cstring(strings.concatenate(parts[:], context.temp_allocator), context.temp_allocator))
		if next == nil do return false
		list^ = next
		return true
	}
	for h in req.headers {
		if !append_line(&list, h.name, h.value) do return .Internal
	}
	if has_body {
		if !append_line(&list, "Content-Type", content_type) do return .Internal
	} else {
		// libcurl would otherwise label a body-less POST as a form.
		if !remove_line(&list, "Content-Type") do return .Internal
	}
	// No "Expect: 100-continue" round trip for large bodies.
	if !remove_line(&list, "Expect") do return .Internal

	errbuf: [CURL_ERROR_SIZE]byte
	timeout := req.timeout_ms if req.timeout_ms > 0 else DEFAULT_TIMEOUT_MS
	connect_timeout := req.connect_timeout_ms if req.connect_timeout_ms > 0 && req.connect_timeout_ms < timeout else timeout
	t.limit = req.max_response_bytes if req.max_response_bytes > 0 else DEFAULT_MAX_RESPONSE_BYTES
	t.cancel = req.cancel
	if t.mode == .Memory do t.body = make([dynamic]byte, 0, 0, t.allocator)
	t.headers = make([dynamic]Header, 0, 0, t.allocator)

	set_ok := true
	set_ok &= set_ptr(easy, CURLOPT_CURLU, rawptr(urlh))
	set_ok &= set_ptr(easy, CURLOPT_ERRORBUFFER, rawptr(&errbuf[0]))
	set_ok &= set_long(easy, CURLOPT_NOSIGNAL, c.long(1))
	set_ok &= set_long(easy, CURLOPT_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS)
	set_ok &= set_long(easy, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1)
	set_ok &= set_long(easy, CURLOPT_FRESH_CONNECT, c.long(1))
	set_ok &= set_long(easy, CURLOPT_FORBID_REUSE, c.long(1))
	set_ok &= set_long(easy, CURLOPT_TIMEOUT_MS, c.long(timeout))
	set_ok &= set_long(easy, CURLOPT_CONNECTTIMEOUT_MS, c.long(connect_timeout))
	set_ok &= set_long(easy, CURLOPT_SSL_VERIFYPEER, c.long(1))
	set_ok &= set_long(easy, CURLOPT_SSL_VERIFYHOST, c.long(2))
	// Proxies are never taken from the environment (http_proxy, HTTPS_PROXY,
	// ALL_PROXY...): the previous client never used one, and silently routing hub
	// credentials through an inherited proxy is not acceptable. "" disables them.
	set_ok &= set_ptr(easy, CURLOPT_PROXY, rawptr(CS_EMPTY))
	set_ok &= set_ptr(easy, CURLOPT_USERAGENT, rawptr(CS_USER_AGENT))
	// "" = every encoding this libcurl decodes (gzip/deflate with zlib).
	set_ok &= set_ptr(easy, CURLOPT_ACCEPT_ENCODING, rawptr(CS_EMPTY))
	set_ok &= set_ptr(easy, CURLOPT_HTTPHEADER, rawptr(list))
	set_ok &= set_ptr(easy, CURLOPT_WRITEFUNCTION, rawptr(Curl_Write_Callback(write_cb)))
	set_ok &= set_ptr(easy, CURLOPT_WRITEDATA, rawptr(t))
	set_ok &= set_ptr(easy, CURLOPT_HEADERFUNCTION, rawptr(Curl_Write_Callback(header_cb)))
	set_ok &= set_ptr(easy, CURLOPT_HEADERDATA, rawptr(t))
	set_ok &= set_ptr(easy, CURLOPT_PREREQFUNCTION, rawptr(Curl_Prereq_Callback(prereq_cb)))
	set_ok &= set_ptr(easy, CURLOPT_PREREQDATA, rawptr(t))
	set_ok &= set_off(easy, CURLOPT_MAXFILESIZE_LARGE, i64(t.limit))
	t.stall = time.Duration(req.stall_timeout_ms) * time.Millisecond if req.stall_timeout_ms > 0 else 0
	if req.cancel != nil || t.stall > 0 {
		// The progress callback runs at least about once a second even when no
		// byte moves. (CURLOPT_LOW_SPEED_* averages over a ~5 s window, so it
		// would fire up to 5 s late.)
		t.last_progress = time.tick_now()
		set_ok &= set_long(easy, CURLOPT_NOPROGRESS, c.long(0))
		set_ok &= set_ptr(easy, CURLOPT_XFERINFOFUNCTION, rawptr(Curl_Xferinfo_Callback(xferinfo_cb)))
		set_ok &= set_ptr(easy, CURLOPT_XFERINFODATA, rawptr(t))
	}
	if req.max_redirects > 0 {
		set_ok &= set_long(easy, CURLOPT_FOLLOWLOCATION, c.long(1))
		set_ok &= set_long(easy, CURLOPT_MAXREDIRS, c.long(req.max_redirects))
		// Never downgrade an https request to http on a redirect.
		redir := CURLPROTO_HTTPS if url_is_https(req.url) else CURLPROTO_HTTP | CURLPROTO_HTTPS
		set_ok &= set_long(easy, CURLOPT_REDIR_PROTOCOLS, redir)
	} else {
		set_ok &= set_long(easy, CURLOPT_FOLLOWLOCATION, c.long(0))
	}
	when ODIN_OS == .Windows {
		// Schannel checks certificate revocation by default and fails the handshake
		// when it cannot reach a CRL/OCSP responder (offline or filtered networks, a
		// private CA from HAM_TLS_CA_FILE with no distribution point). The previous
		// SSPI transport did not check revocation. Best effort still rejects a
		// certificate that IS revoked; it only tolerates an unknown status.
		set_ok &= set_long(easy, CURLOPT_SSL_OPTIONS, CURLSSLOPT_REVOKE_BEST_EFFORT)
	}
	trust := trust_anchors(req._test_ca_file, req._test_ca_blob)
	if trust.cainfo != "" {
		set_ok &= set_ptr(easy, CURLOPT_CAINFO, rawptr(strings.clone_to_cstring(trust.cainfo, context.temp_allocator)))
	}
	if trust.exclusive {
		// HAM_TLS_CA_FILE is THE trust anchor: drop any CA directory libcurl was
		// built with (the pinned build has none; an unpinned one may), which
		// CAINFO alone keeps.
		_ = set_ptr(easy, CURLOPT_CAPATH, nil)
	} else if trust.capath != "" {
		// CAPATH is not supported by every TLS backend (Schannel); not fatal.
		_ = set_ptr(easy, CURLOPT_CAPATH, rawptr(strings.clone_to_cstring(trust.capath, context.temp_allocator)))
	}
	if trust.blob != "" {
		// The embedded bundle is a constant: no copy needed.
		blob := curl_blob{data = raw_data(trust.blob), len = len(trust.blob), flags = CURL_BLOB_NOCOPY}
		set_ok &= set_ptr(easy, CURLOPT_CAINFO_BLOB, &blob)
	}

	switch req.method {
	case .GET:
		set_ok &= set_long(easy, CURLOPT_HTTPGET, c.long(1))
	case .HEAD:
		set_ok &= set_long(easy, CURLOPT_NOBODY, c.long(1))
	case .POST, .PUT, .PATCH, .DELETE:
		if req.method != .POST {
			set_ok &= set_ptr(easy, CURLOPT_CUSTOMREQUEST, rawptr(cstring(raw_data(method_cstring(req.method)))))
		}
		if has_body || req.method != .DELETE {
			set_ok &= set_long(easy, CURLOPT_POST, c.long(1))
			set_ok &= set_off(easy, CURLOPT_POSTFIELDSIZE_LARGE, i64(len(body_bytes)))
			if len(body_bytes) > 0 {
				set_ok &= set_ptr(easy, CURLOPT_POSTFIELDS, rawptr(raw_data(body_bytes)))
			} else {
				set_ok &= set_ptr(easy, CURLOPT_POSTFIELDS, rawptr(EMPTY_BODY))
			}
		}
	}
	if !set_ok do return .Internal

	rc := curl_easy_perform(easy)
	code: c.long
	_ = curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &code)
	if rc != CURLE_OK {
		t.detail = strings.clone(string(cstring(&errbuf[0])), context.temp_allocator)
		if t.detail == "" do t.detail = strings.clone(string(curl_easy_strerror(rc)), context.temp_allocator)
		return map_curl_error(rc, t)
	}
	t.status = int(code)
	return .None
}

@(private)
method_cstring :: proc(m: Method) -> string {
	switch m {
	case .GET: return "GET\x00"
	case .HEAD: return "HEAD\x00"
	case .POST: return "POST\x00"
	case .PUT: return "PUT\x00"
	case .PATCH: return "PATCH\x00"
	case .DELETE: return "DELETE\x00"
	}
	return "GET\x00"
}

@(private)
map_curl_error :: proc(rc: CURLcode, t: ^Transfer) -> Error {
	switch rc {
	case CURLE_COULDNT_RESOLVE_HOST, CURLE_COULDNT_RESOLVE_PROXY:
		return .Dns
	case CURLE_COULDNT_CONNECT:
		return .Connect
	case CURLE_OPERATION_TIMEDOUT:
		return .Timeout
	case CURLE_SSL_CONNECT_ERROR, CURLE_SSL_CIPHER, CURLE_SSL_SHUTDOWN_FAILED:
		return .Tls
	case CURLE_PEER_FAILED_VERIFICATION, CURLE_SSL_CACERT_BADFILE, CURLE_SSL_CERTPROBLEM,
	     CURLE_SSL_CRL_BADFILE, CURLE_SSL_ISSUER_ERROR, CURLE_SSL_PINNEDPUBKEYNOTMATCH,
	     CURLE_SSL_INVALIDCERTSTATUS:
		return .Certificate
	case CURLE_WRITE_ERROR:
		if t.too_large do return .Too_Large
		if t.io_failed do return .Io
		return .Internal
	case CURLE_FILESIZE_EXCEEDED, CURLE_TOO_LARGE:
		return .Too_Large
	case CURLE_SEND_ERROR:
		return .Send
	case CURLE_RECV_ERROR:
		return .Recv
	case CURLE_WEIRD_SERVER_REPLY, CURLE_GOT_NOTHING, CURLE_PARTIAL_FILE,
	     CURLE_BAD_CONTENT_ENCODING, CURLE_HTTP2, CURLE_HTTP2_STREAM:
		return .Protocol
	case CURLE_TOO_MANY_REDIRECTS:
		return .Too_Many_Redirects
	case CURLE_ABORTED_BY_CALLBACK:
		if t.stalled do return .Timeout
		return .Aborted
	case CURLE_UNSUPPORTED_PROTOCOL, CURLE_URL_MALFORMAT:
		return .Invalid_Url
	}
	return .Internal
}

// header_cb receives every response header line (CURLOPT_HEADERFUNCTION). A
// status line starts a new response (a 1xx interim reply, a followed
// redirect), so the collected headers reset and only the final response's
// survive. Lines after the body began are trailers and are ignored. Copies go
// to the response allocator; MAX_RESPONSE_HEADER_BYTES bounds one response.
@(private)
header_cb :: proc "c" (ptr: [^]byte, size: c.size_t, nmemb: c.size_t, userdata: rawptr) -> c.size_t {
	t := (^Transfer)(userdata)
	context = t.ctx
	n := int(size * nmemb)
	line := string(ptr[:n])
	if strings.has_prefix(line, "HTTP/") {
		free_headers(t.headers[:], t.allocator)
		clear(&t.headers)
		t.header_bytes = 0
		t.body_started = false
	}
	t.header_bytes += n
	if t.header_bytes > MAX_RESPONSE_HEADER_BYTES {
		t.too_large = true
		return 0
	}
	if t.body_started do return c.size_t(n)
	text := strings.trim_right(line, "\r\n")
	if text == "" || strings.has_prefix(text, "HTTP/") do return c.size_t(n)
	if (text[0] == ' ' || text[0] == '\t') && len(t.headers) > 0 {
		// Obsolete line folding: continue the previous value.
		last := &t.headers[len(t.headers) - 1]
		parts := [3]string{last.value, " ", strings.trim_space(text)}
		joined := strings.concatenate(parts[:], t.allocator)
		delete(last.value, t.allocator)
		last.value = joined
		return c.size_t(n)
	}
	colon := strings.index_byte(text, ':')
	if colon <= 0 do return c.size_t(n)
	append(&t.headers, Header{
		name = strings.clone(strings.trim_space(text[:colon]), t.allocator),
		value = strings.clone(strings.trim_space(text[colon + 1:]), t.allocator),
	})
	return c.size_t(n)
}

@(private)
write_cb :: proc "c" (ptr: [^]byte, size: c.size_t, nmemb: c.size_t, userdata: rawptr) -> c.size_t {
	t := (^Transfer)(userdata)
	context = t.ctx
	n := int(size * nmemb)
	t.body_started = true
	if t.received + n > t.limit {
		t.too_large = true
		return 0
	}
	t.received += n
	switch t.mode {
	case .Memory:
		append(&t.body, ..ptr[:n])
	case .File:
		written, err := os.write(t.file, ptr[:n])
		if err != nil || written != n {
			t.io_failed = true
			return 0
		}
	}
	return c.size_t(n)
}

@(private)
prereq_cb :: proc "c" (clientp: rawptr, conn_primary_ip, conn_local_ip: cstring, conn_primary_port, conn_local_port: c.int) -> c.int {
	t := (^Transfer)(clientp)
	t.prereq_reached = true
	return CURL_PREREQFUNC_OK
}

@(private)
xferinfo_cb :: proc "c" (clientp: rawptr, dltotal, dlnow, ultotal, ulnow: i64) -> c.int {
	t := (^Transfer)(clientp)
	context = t.ctx
	if t.cancel != nil && sync.atomic_load(t.cancel) do return 1
	if t.stall > 0 {
		now := time.tick_now()
		if dlnow != t.last_dl || ulnow != t.last_ul {
			t.last_dl, t.last_ul = dlnow, ulnow
			t.last_progress = now
		} else if time.tick_diff(t.last_progress, now) > t.stall {
			t.stalled = true
			return 1
		}
	}
	return 0
}

// Typed setters: libcurl's curl_easy_setopt is C-variadic, so each value must
// reach it with its exact C type (long, pointer, curl_off_t).
@(private)
set_long :: proc(easy: ^CURL, opt: CURLoption, v: c.long) -> bool {
	return curl_easy_setopt(easy, opt, v) == CURLE_OK
}
@(private)
set_ptr :: proc(easy: ^CURL, opt: CURLoption, v: rawptr) -> bool {
	return curl_easy_setopt(easy, opt, v) == CURLE_OK
}
@(private)
set_off :: proc(easy: ^CURL, opt: CURLoption, v: i64) -> bool {
	return curl_easy_setopt(easy, opt, v) == CURLE_OK
}
