package httpc

// libcurl-backed WebSocket transport. The easy handle owns DNS, TCP, TLS,
// certificate/hostname verification, the HTTP Upgrade, masking, control frames,
// and the socket. Callers never see CURL types or codes.

import "core:c"
import "core:strings"
import "core:sync"
import "core:time"

CS_WS_PROTOCOLS: cstring = "ws,wss"

WebSocket_Frame_Kind :: enum u8 {
	Again,
	Text,
	Binary,
	Close,
	Ping,
	Pong,
}

WebSocket_Chunk :: struct {
	kind:         WebSocket_Frame_Kind,
	continuation: bool, // more frames belong to this message after this frame
	bytes_left:   i64,  // bytes still pending in the current frame
}

WebSocket :: struct {
	_easy:      ^CURL,
	_mu:        sync.Mutex,
	_connected: bool,
	_aborted:   bool,
}

websocket_url :: proc(raw: string, allocator := context.temp_allocator) -> (out: string, err: Error) {
	if ok, _ := init(); !ok do return "", .Not_Initialized
	if !text_is_clean(raw) do return "", .Invalid_Url
	h := curl_url()
	if h == nil do return "", .Internal
	defer curl_url_cleanup(h)
	if curl_url_set(h, CURLUPART_URL, strings.clone_to_cstring(strings.trim_space(raw), context.temp_allocator), CURLU_DISALLOW_USER) != CURLUE_OK {
		return "", .Invalid_Url
	}
	scheme := url_part(h, CURLUPART_SCHEME) or_return
	defer curl_free(rawptr(scheme))
	if scheme != "ws" && scheme != "wss" do return "", .Invalid_Url
	if url_part_present(h, CURLUPART_FRAGMENT) || url_part_present(h, CURLUPART_PASSWORD) || url_part_present(h, CURLUPART_USER) {
		return "", .Invalid_Url
	}
	host := url_part(h, CURLUPART_HOST) or_return
	defer curl_free(rawptr(host))
	if strings.trim_space(string(host)) == "" do return "", .Invalid_Url
	full := url_part(h, CURLUPART_URL) or_return
	defer curl_free(rawptr(full))
	return strings.clone(string(full), allocator), .None
}

// _test_ca_file is the test-only exclusive trust anchor (as Request._test_ca_file):
// tests run in parallel and must not set HAM_TLS_CA_FILE.
websocket_connect :: proc(raw_url, bearer_token: string, timeout_ms := DEFAULT_TIMEOUT_MS, _test_ca_file := "") -> (WebSocket, Error, string) {
	url, url_err := websocket_url(raw_url, context.temp_allocator)
	if url_err != .None do return {}, url_err, error_string(url_err)
	if timeout_ms <= 0 do return {}, .Timeout, error_string(.Timeout)
	if strings.contains_any(bearer_token, "\r\n\x00") do return {}, .Invalid_Header, error_string(.Invalid_Header)

	easy := curl_easy_init()
	if easy == nil do return {}, .Internal, "libcurl could not allocate a WebSocket handle"
	ok := false
	defer if !ok do curl_easy_cleanup(easy)

	list: ^curl_slist
	defer if list != nil do curl_slist_free_all(list)
	if bearer_token != "" {
		line := strings.concatenate({"Authorization: Bearer ", bearer_token}, context.temp_allocator)
		list = curl_slist_append(nil, strings.clone_to_cstring(line, context.temp_allocator))
		if list == nil do return {}, .Internal, "libcurl could not allocate WebSocket headers"
	}

	errbuf: [CURL_ERROR_SIZE]byte
	set_ok := true
	set_ok &= set_ptr(easy, CURLOPT_URL, rawptr(strings.clone_to_cstring(url, context.temp_allocator)))
	set_ok &= set_ptr(easy, CURLOPT_ERRORBUFFER, rawptr(&errbuf[0]))
	set_ok &= set_long(easy, CURLOPT_NOSIGNAL, c.long(1))
	set_ok &= set_ptr(easy, CURLOPT_PROTOCOLS_STR, rawptr(CS_WS_PROTOCOLS))
	set_ok &= set_long(easy, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1)
	set_ok &= set_long(easy, CURLOPT_CONNECT_ONLY, c.long(2))
	set_ok &= set_long(easy, CURLOPT_TIMEOUT_MS, c.long(timeout_ms))
	set_ok &= set_long(easy, CURLOPT_CONNECTTIMEOUT_MS, c.long(timeout_ms))
	set_ok &= set_long(easy, CURLOPT_SSL_VERIFYPEER, c.long(1))
	set_ok &= set_long(easy, CURLOPT_SSL_VERIFYHOST, c.long(2))
	set_ok &= set_ptr(easy, CURLOPT_PROXY, rawptr(CS_EMPTY))
	set_ok &= set_ptr(easy, CURLOPT_USERAGENT, rawptr(CS_USER_AGENT))
	set_ok &= set_ptr(easy, CURLOPT_HTTPHEADER, rawptr(list))
	when ODIN_OS == .Windows {
		set_ok &= set_long(easy, CURLOPT_SSL_OPTIONS, CURLSSLOPT_REVOKE_BEST_EFFORT)
	}
	trust := trust_anchors(_test_ca_file)
	if trust.cainfo != "" {
		set_ok &= set_ptr(easy, CURLOPT_CAINFO, rawptr(strings.clone_to_cstring(trust.cainfo, context.temp_allocator)))
	}
	if trust.exclusive {
		_ = set_ptr(easy, CURLOPT_CAPATH, nil)
	} else if trust.capath != "" {
		_ = set_ptr(easy, CURLOPT_CAPATH, rawptr(strings.clone_to_cstring(trust.capath, context.temp_allocator)))
	}
	if trust.blob != "" {
		blob := curl_blob{data = raw_data(trust.blob), len = len(trust.blob), flags = CURL_BLOB_NOCOPY}
		set_ok &= set_ptr(easy, CURLOPT_CAINFO_BLOB, &blob)
	}
	if !set_ok do return {}, .Internal, "libcurl rejected a required WebSocket option"

	rc := curl_easy_perform(easy)
	if rc != CURLE_OK {
		detail := string(cstring(&errbuf[0]))
		if detail == "" do detail = string(curl_easy_strerror(rc))
		t: Transfer
		err := map_curl_error(rc, &t)
		return {}, err, strings.clone(detail, context.temp_allocator)
	}
	ok = true
	return WebSocket{_easy = easy, _connected = true}, .None, ""
}

websocket_receive :: proc(ws: ^WebSocket, out: []byte) -> (n: int, chunk: WebSocket_Chunk, ok: bool) {
	if ws == nil || ws._easy == nil || !ws._connected || sync.atomic_load(&ws._aborted) do return 0, {}, false
	sync.mutex_lock(&ws._mu)
	defer sync.mutex_unlock(&ws._mu)
	if ws._easy == nil || !ws._connected || sync.atomic_load(&ws._aborted) do return 0, {}, false
	received: c.size_t
	meta: ^curl_ws_frame
	rc := curl_ws_recv(ws._easy, raw_data(out), c.size_t(len(out)), &received, &meta)
	if rc == CURLE_AGAIN do return 0, {kind = .Again}, true
	if rc != CURLE_OK || meta == nil {
		ws._connected = false
		return 0, {}, false
	}
	flags := c.uint(meta.flags)
	kind := WebSocket_Frame_Kind.Text
	switch {
	case flags & CURLWS_CLOSE != 0:  kind = .Close
	case flags & CURLWS_PING != 0:   kind = .Ping
	case flags & CURLWS_PONG != 0:   kind = .Pong
	case flags & CURLWS_BINARY != 0: kind = .Binary
	case flags & CURLWS_TEXT != 0:   kind = .Text
	case:
		ws._connected = false
		return 0, {}, false
	}
	return int(received), {kind = kind, continuation = flags & CURLWS_CONT != 0, bytes_left = meta.bytesleft}, true
}

websocket_send :: proc(ws: ^WebSocket, payload: []byte, binary := false, timeout := 5 * time.Second) -> bool {
	if ws == nil || ws._easy == nil || !ws._connected || sync.atomic_load(&ws._aborted) do return false
	flags := CURLWS_BINARY if binary else CURLWS_TEXT
	sent_total := 0
	started := time.tick_now()
	for sent_total < len(payload) || (len(payload) == 0 && sent_total == 0) {
		if sync.atomic_load(&ws._aborted) || time.tick_since(started) >= timeout do return false
		sent: c.size_t
		sync.mutex_lock(&ws._mu)
		if ws._easy == nil || !ws._connected || sync.atomic_load(&ws._aborted) {
			sync.mutex_unlock(&ws._mu)
			return false
		}
		remaining := payload[sent_total:]
		ptr := rawptr(nil)
		if len(remaining) > 0 do ptr = raw_data(remaining)
		rc := curl_ws_send(ws._easy, ptr, c.size_t(len(remaining)), &sent, 0, flags)
		if rc != CURLE_OK && rc != CURLE_AGAIN {
			ws._connected = false
		}
		sync.mutex_unlock(&ws._mu)
		sent_total += int(sent)
		if rc == CURLE_AGAIN { time.sleep(time.Millisecond); continue }
		if rc != CURLE_OK do return false
		if len(payload) == 0 do break
		if sent == 0 { time.sleep(time.Millisecond) }
	}
	return true
}

websocket_abort :: proc(ws: ^WebSocket) {
	if ws == nil do return
	sync.atomic_store(&ws._aborted, true)
}

websocket_close :: proc(ws: ^WebSocket) {
	if ws == nil do return
	sync.atomic_store(&ws._aborted, true)
	sync.mutex_lock(&ws._mu)
	defer sync.mutex_unlock(&ws._mu)
	if ws._easy != nil do curl_easy_cleanup(ws._easy)
	ws._easy = nil
	ws._connected = false
}
