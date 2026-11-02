package main

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"

// OIDC session broker (REQ-DEVAUTH-1..3).
//
// The Hub authenticates browsers only with its OIDC session cookie. A browser
// that reaches this proxy through the Heimdall preview relay can never hold that
// cookie: the relay strips `__Host-heimdall_*` request cookies and rewrites every
// Set-Cookie Path to the preview prefix, which a `__Host-` cookie may not carry.
//
// So the proxy signs in ON BEHALF of the selected dev user, after the relay: it
// runs the Hub's real authorization-code flow headlessly against the local mock
// provider (tools/mock-oidc auto-approves and honours login_hint), keeps the
// resulting Hub session id in memory, and attaches it — with the Origin the Hub's
// CSRF check expects — on the hop to the Hub. The browser never sees Hub tokens.
//
// Brokering only engages for a loopback (mock) provider. Against a real provider
// (Authentik) the proxy keeps the browser-driven flow: forward unchanged and add
// login_hint to the /api/v1/auth/login redirect.

HUB_SESSION_COOKIE :: "__Host-heimdall_session"
HUB_LOGIN_COOKIE :: "__Host-heimdall_login"
HUB_CALLBACK_PATH :: "/api/v1/auth/callback"
BROKER_HTTP_TIMEOUT :: 10 * time.Second
RESPONSE_HEAD_MAX :: 64 * 1024

Dev_Session_Broker :: struct {
	mutex: sync.Mutex,
	// Serializes sign-ins so a burst of first requests creates one session.
	login_mutex: sync.Mutex,
	sessions: map[string]string, // dev username -> Hub session id
	logged_out: map[string]bool, // explicit sign-out: no auto sign-in until /api/v1/auth/login
	ui_origin: string, // the Hub's --ui-origin, learned from its authorize redirect_uri
	real_idp: bool, // provider is not a loopback mock: browser-driven login only
}

Broker_Login_Error :: enum {
	None,
	Hub_Unavailable,
	Hub_Login_Failed,
	Real_Idp,
	Provider_Failed,
	Callback_Failed,
}

broker_login_error_message :: proc(err: Broker_Login_Error) -> string {
	switch err {
	case .None: return ""
	case .Hub_Unavailable: return "dev proxy sign-in: hub unavailable"
	case .Hub_Login_Failed: return "dev proxy sign-in: hub /api/v1/auth/login did not redirect to the provider"
	case .Real_Idp: return "dev proxy sign-in: provider is not a loopback mock; using browser sign-in"
	case .Provider_Failed: return "dev proxy sign-in: mock provider did not redirect back (is tools/mock-oidc running?)"
	case .Callback_Failed: return "dev proxy sign-in: hub callback did not issue a session"
	}
	return ""
}

broker_ui_origin :: proc(b: ^Dev_Session_Broker, config: ^Dev_Proxy_Config) -> string {
	if config.hub_ui_origin != "" do return config.hub_ui_origin
	sync.mutex_lock(&b.mutex)
	defer sync.mutex_unlock(&b.mutex)
	return b.ui_origin
}

broker_is_real_idp :: proc(b: ^Dev_Session_Broker) -> bool {
	sync.mutex_lock(&b.mutex)
	defer sync.mutex_unlock(&b.mutex)
	return b.real_idp
}

broker_cached_session :: proc(b: ^Dev_Session_Broker, username: string) -> string {
	sync.mutex_lock(&b.mutex)
	defer sync.mutex_unlock(&b.mutex)
	return b.sessions[username]
}

// broker_session returns the Hub session for `username`, signing in first when
// none is cached — unless the user explicitly signed out, or the provider is real.
broker_session :: proc(b: ^Dev_Session_Broker, config: ^Dev_Proxy_Config, username: string) -> string {
	sync.mutex_lock(&b.mutex)
	session, cached := b.sessions[username]
	skip := b.logged_out[username] || b.real_idp
	sync.mutex_unlock(&b.mutex)
	if cached do return session
	if skip do return ""
	fresh, err := broker_login(b, config, username, false)
	if err != .None && err != .Real_Idp do fmt.eprintln(broker_login_error_message(err))
	return fresh
}

// broker_invalidate drops `stale` (a session the Hub rejected) unless another
// request already replaced it.
broker_invalidate :: proc(b: ^Dev_Session_Broker, username, stale: string) {
	sync.mutex_lock(&b.mutex)
	defer sync.mutex_unlock(&b.mutex)
	if current, ok := b.sessions[username]; ok && current == stale {
		key, value := delete_key(&b.sessions, username)
		delete(key)
		delete(value)
	}
}

// broker_sign_out forgets the user's session and suppresses auto sign-in.
broker_sign_out :: proc(b: ^Dev_Session_Broker, username: string) {
	sync.mutex_lock(&b.mutex)
	defer sync.mutex_unlock(&b.mutex)
	if username in b.sessions {
		key, value := delete_key(&b.sessions, username)
		delete(key)
		delete(value)
	}
	if username not_in b.logged_out do b.logged_out[strings.clone(username)] = true
}

// broker_login runs the Hub's authorization-code flow for `username` against the
// mock provider and caches the session. `force` replaces a cached session (an
// explicit /api/v1/auth/login) and clears a sign-out.
broker_login :: proc(b: ^Dev_Session_Broker, config: ^Dev_Proxy_Config, username: string, force: bool) -> (string, Broker_Login_Error) {
	sync.mutex_lock(&b.login_mutex)
	defer sync.mutex_unlock(&b.login_mutex)
	if !force {
		if session := broker_cached_session(b, username); session != "" do return session, .None
	}

	hub_base := strings.trim_right(config.hub_url, "/")
	login_resp, login_ok := dev_http_get(fmt.tprintf("%s/api/v1/auth/login?return_to=%%2F", hub_base), "")
	if !login_ok do return "", .Hub_Unavailable
	authorize := response_header(login_resp, "Location")
	login_state := set_cookie_from_response(login_resp, HUB_LOGIN_COOKIE)
	if response_status(login_resp) != 302 || authorize == "" || login_state == "" do return "", .Hub_Login_Failed

	if !is_loopback_http_url(authorize) {
		sync.mutex_lock(&b.mutex)
		b.real_idp = true
		sync.mutex_unlock(&b.mutex)
		fmt.eprintln(broker_login_error_message(.Real_Idp))
		return "", .Real_Idp
	}
	if origin := ui_origin_from_authorize(authorize); origin != "" {
		sync.mutex_lock(&b.mutex)
		if b.ui_origin != origin {
			if b.ui_origin != "" do delete(b.ui_origin)
			b.ui_origin = strings.clone(origin)
		}
		sync.mutex_unlock(&b.mutex)
	}

	hint := net.percent_encode(username, context.temp_allocator)
	sep := "&" if strings.contains(authorize, "?") else "?"
	provider_resp, provider_ok := dev_http_get(strings.concatenate({authorize, sep, "login_hint=", hint}, context.temp_allocator), "")
	callback := response_header(provider_resp, "Location")
	if !provider_ok || response_status(provider_resp) != 302 || callback == "" do return "", .Provider_Failed

	// Deliver the callback to the Hub itself whatever origin the redirect URI
	// names (the UI dev server, a preview origin, ...).
	callback_target := callback_path_and_query(callback)
	if callback_target == "" do return "", .Callback_Failed
	cookie := strings.concatenate({HUB_LOGIN_COOKIE, "=", login_state}, context.temp_allocator)
	callback_resp, callback_ok := dev_http_get(strings.concatenate({hub_base, callback_target}, context.temp_allocator), cookie)
	session := set_cookie_from_response(callback_resp, HUB_SESSION_COOKIE)
	if !callback_ok || response_status(callback_resp) != 302 || session == "" do return "", .Callback_Failed

	sync.mutex_lock(&b.mutex)
	defer sync.mutex_unlock(&b.mutex)
	if username in b.sessions {
		key, value := delete_key(&b.sessions, username)
		delete(key)
		delete(value)
	}
	b.sessions[strings.clone(username)] = strings.clone(session)
	if username in b.logged_out {
		key, _ := delete_key(&b.logged_out, username)
		delete(key)
	}
	fmt.printfln("ham-dev-proxy: signed in to the hub as %s", username)
	return b.sessions[username], .None
}

// broker_request_trusted decides whether the proxy may attach a brokered session
// to this request. A request that already carries a credential (a bearer, or a
// Hub session cookie from a script that signed in itself, e.g. seed.mjs) keeps
// it. A browser request that is cross-site (Sec-Fetch-Site) or comes from a
// foreign Origin never gets a session: the proxy must not turn into a CSRF bypass
// for whatever page the developer has open. Loopback origins and --trusted-origin
// values (the preview origin) are trusted; so is a request with no Origin (curl,
// same-origin GETs).
broker_request_trusted :: proc(config: ^Dev_Proxy_Config, headers: []contracts.HTTP_Header) -> bool {
	if header_value(headers, "Authorization") != "" do return false
	if cookie_present(header_value(headers, "Cookie"), HUB_SESSION_COOKIE) do return false
	site := header_value(headers, "Sec-Fetch-Site")
	if site != "" && !ascii_equal_fold(site, "same-origin") && !ascii_equal_fold(site, "none") do return false
	origin := header_value(headers, "Origin")
	if origin == "" do return true
	return origin_is_trusted(config, origin)
}

// is_browser_navigation: only a browser page load of /api/v1/auth/login is
// brokered. Scripts that run the sign-in flow themselves through the proxy
// (tests/e2e/hubOidc.mjs, tests/hub_oidc_login.py) keep the provider redirect.
is_browser_navigation :: proc(headers: []contracts.HTTP_Header) -> bool {
	if ascii_equal_fold(header_value(headers, "Sec-Fetch-Mode"), "navigate") do return true
	return strings.contains(header_value(headers, "Accept"), "text/html")
}

cookie_present :: proc(cookie_header, name: string) -> bool {
	rest := cookie_header
	for part in strings.split_iterator(&rest, ";") {
		cookie := strings.trim_space(part)
		if eq := strings.index_byte(cookie, '='); eq >= 0 && cookie[:eq] == name && eq + 1 < len(cookie) do return true
	}
	return false
}

// EXPIRED_HUB_SESSION_COOKIE clears a Hub session cookie the browser may still
// hold from browser-driven sign-in, so it stops shadowing the brokered session.
EXPIRED_HUB_SESSION_COOKIE :: HUB_SESSION_COOKIE + "=; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=0"

origin_is_trusted :: proc(config: ^Dev_Proxy_Config, origin: string) -> bool {
	trimmed := strings.trim_right(strings.trim_space(origin), "/")
	for allowed in config.trusted_origins {
		if ascii_equal_fold(trimmed, strings.trim_right(allowed, "/")) do return true
	}
	rest := trimmed
	if ascii_has_prefix_fold(rest, "http://") {
		rest = rest[len("http://"):]
	} else if ascii_has_prefix_fold(rest, "https://") {
		rest = rest[len("https://"):]
	} else {
		return false
	}
	return is_loopback_host(url_host_only(rest))
}

// url_host_only strips the port from "host[:port]" (IPv6 literals in brackets).
url_host_only :: proc(authority: string) -> string {
	if strings.has_prefix(authority, "[") {
		end := strings.index_byte(authority, ']')
		if end < 0 do return authority
		return authority[1:end]
	}
	if colon := strings.last_index_byte(authority, ':'); colon >= 0 do return authority[:colon]
	return authority
}

is_loopback_http_url :: proc(url: string) -> bool {
	if !ascii_has_prefix_fold(url, "http://") do return false
	rest := url[len("http://"):]
	if end := strings.index_any(rest, "/?#"); end >= 0 do rest = rest[:end]
	host := url_host_only(rest)
	return host == "127.0.0.1" || host == "localhost" || host == "::1"
}

// ui_origin_from_authorize extracts the Hub's UI origin from the redirect_uri
// (`<ui_origin>/api/v1/auth/callback`) in its authorize redirect.
ui_origin_from_authorize :: proc(authorize: string) -> string {
	q := strings.index_byte(authorize, '?')
	if q < 0 do return ""
	query := authorize[q + 1:]
	for pair in strings.split_iterator(&query, "&") {
		if !strings.has_prefix(pair, "redirect_uri=") do continue
		decoded, ok := net.percent_decode(pair[len("redirect_uri="):], context.temp_allocator)
		if !ok do return ""
		if !strings.has_suffix(decoded, HUB_CALLBACK_PATH) do return ""
		return decoded[:len(decoded) - len(HUB_CALLBACK_PATH)]
	}
	return ""
}

// callback_path_and_query returns "/path?query" of an absolute or relative URL.
callback_path_and_query :: proc(url: string) -> string {
	rest := url
	if scheme_end := strings.index(rest, "://"); scheme_end >= 0 {
		rest = rest[scheme_end + 3:]
		slash := strings.index_byte(rest, '/')
		if slash < 0 do return ""
		rest = rest[slash:]
	}
	if !strings.has_prefix(rest, "/") do return ""
	if hash := strings.index_byte(rest, '#'); hash >= 0 do rest = rest[:hash]
	return rest
}

// broker_headers_for_hub swaps the browser's cookies for the brokered session and
// sets the Origin the Hub's CSRF check compares against its --ui-origin. Trust was
// already decided by broker_request_trusted, so Sec-Fetch-* is dropped (the Hub
// would otherwise judge the browser's origin, e.g. the preview).
broker_headers_for_hub :: proc(headers: []contracts.HTTP_Header, session, ui_origin: string) -> []contracts.HTTP_Header {
	out := make([dynamic]contracts.HTTP_Header)
	browser_cookie := ""
	for h in headers {
		if ascii_equal_fold(h.name, "Cookie") {
			browser_cookie = h.value
			continue
		}
		if ascii_equal_fold(h.name, "Origin") || ascii_has_prefix_fold(h.name, "Sec-Fetch-") do continue
		append(&out, contracts.HTTP_Header{name = strings.clone(h.name), value = strings.clone(h.value)})
	}
	append(&out, contracts.HTTP_Header{name = strings.clone("Cookie"), value = brokered_cookie_header(browser_cookie, session)})
	if ui_origin != "" do append(&out, contracts.HTTP_Header{name = strings.clone("Origin"), value = strings.clone(ui_origin)})
	return out[:]
}

// brokered_cookie_header keeps the browser's other cookies but replaces any Hub
// session/login cookie and the dev-user selector with the brokered session.
brokered_cookie_header :: proc(browser_cookie, session: string) -> string {
	b := strings.builder_make()
	rest := browser_cookie
	for part in strings.split_iterator(&rest, ";") {
		cookie := strings.trim_space(part)
		if cookie == "" do continue
		name := cookie
		if eq := strings.index_byte(cookie, '='); eq >= 0 do name = cookie[:eq]
		if name == HUB_SESSION_COOKIE || name == HUB_LOGIN_COOKIE || name == "ham_dev_user" do continue
		strings.write_string(&b, cookie)
		strings.write_string(&b, "; ")
	}
	strings.write_string(&b, HUB_SESSION_COOKIE)
	strings.write_string(&b, "=")
	strings.write_string(&b, session)
	return strings.to_string(b)
}

// strip_hub_auth_set_cookies removes the Hub's session/login Set-Cookie lines
// from a brokered response head: the session stays inside the proxy.
strip_hub_auth_set_cookies :: proc(head: string) -> string {
	b := strings.builder_make()
	rest := head
	first := true
	for line in strings.split_lines_iterator(&rest) {
		if ascii_has_prefix_fold(line, "Set-Cookie:") {
			value := strings.trim_space(line[len("Set-Cookie:"):])
			if strings.has_prefix(value, HUB_SESSION_COOKIE + "=") || strings.has_prefix(value, HUB_LOGIN_COOKIE + "=") do continue
		}
		if !first do strings.write_string(&b, "\r\n")
		first = false
		strings.write_string(&b, line)
	}
	return strings.to_string(b)
}

// safe_return_to accepts only a local absolute path, like the Hub does.
safe_return_to :: proc(raw: string) -> string {
	decoded, ok := net.percent_decode(raw, context.temp_allocator)
	if !ok || !strings.has_prefix(decoded, "/") || strings.has_prefix(decoded, "//") || strings.contains_any(decoded, "\r\n\\") do return "/"
	return decoded
}

response_status :: proc(response: string) -> int {
	line_end := strings.index(response, "\r\n")
	line := response if line_end < 0 else response[:line_end]
	parts := strings.split(line, " ", context.temp_allocator)
	if len(parts) < 2 || !strings.has_prefix(parts[0], "HTTP/") do return 0
	status := 0
	for c in transmute([]byte)parts[1] {
		if c < '0' || c > '9' do return 0
		status = status * 10 + int(c - '0')
	}
	return status
}

response_head :: proc(response: string) -> string {
	if idx := strings.index(response, "\r\n\r\n"); idx >= 0 do return response[:idx]
	return response
}

response_header :: proc(response, name: string) -> string {
	head := response_head(response)
	first := true
	for line in strings.split_lines_iterator(&head) {
		if first { first = false; continue }
		colon := strings.index_byte(line, ':')
		if colon <= 0 do continue
		if ascii_equal_fold(strings.trim_space(line[:colon]), name) do return strings.trim_space(line[colon + 1:])
	}
	return ""
}

set_cookie_from_response :: proc(response, name: string) -> string {
	head := response_head(response)
	for line in strings.split_lines_iterator(&head) {
		if !ascii_has_prefix_fold(line, "Set-Cookie:") do continue
		pair := strings.trim_space(line[len("Set-Cookie:"):])
		if semi := strings.index_byte(pair, ';'); semi >= 0 do pair = pair[:semi]
		eq := strings.index_byte(pair, '=')
		if eq < 0 do continue
		if strings.trim_space(pair[:eq]) == name && eq + 1 < len(pair) do return pair[eq + 1:]
	}
	return ""
}

// dev_http_get is a minimal HTTP/1.1 client for the loopback sign-in hops. It
// never follows redirects; the caller reads Location itself.
dev_http_get :: proc(url, cookie: string) -> (string, bool) {
	if !ascii_has_prefix_fold(url, "http://") do return "", false
	rest := url[len("http://"):]
	slash := strings.index_byte(rest, '/')
	authority := rest if slash < 0 else rest[:slash]
	target := "/" if slash < 0 else rest[slash:]
	host, port, ok := parse_base_url(authority)
	if !ok do return "", false
	sock, dial_err := net.dial_tcp_from_hostname_with_port_override(host, port)
	if dial_err != nil do return "", false
	defer net.close(sock)
	_ = net.set_option(sock, .Receive_Timeout, BROKER_HTTP_TIMEOUT)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "GET %s HTTP/1.1\r\nHost: %s\r\nAccept: */*\r\nConnection: close\r\n", target, authority)
	if cookie != "" do fmt.sbprintf(&b, "Cookie: %s\r\n", cookie)
	strings.write_string(&b, "\r\n")
	if _, send_err := net.send_tcp(sock, transmute([]byte)strings.to_string(b)); send_err != nil do return "", false
	data := make([dynamic]byte, 0, 4096, context.temp_allocator)
	buf: [8192]byte
	for {
		n, recv_err := net.recv_tcp(sock, buf[:])
		if recv_err != nil || n <= 0 do break
		append(&data, ..buf[:n])
		if len(data) > 1024 * 1024 do break
	}
	if len(data) == 0 do return "", false
	return string(data[:]), true
}

// read_response_head reads an upstream response up to the end of its header
// block. `data` holds everything read so far (the caller deletes it);
// data[:head_end] is the head without the blank line, data[head_end + 4:] is body
// bytes that arrived with it.
read_response_head :: proc(upstream: net.TCP_Socket) -> (data: [dynamic]byte, head_end: int, ok: bool) {
	data = make([dynamic]byte, 0, 4096)
	buf: [8192]byte
	for {
		n, recv_err := net.recv_tcp(upstream, buf[:])
		if recv_err != nil || n <= 0 do break
		append(&data, ..buf[:n])
		if idx := strings.index(string(data[:]), "\r\n\r\n"); idx >= 0 do return data, idx, true
		if len(data) > RESPONSE_HEAD_MAX do break
	}
	return data, -1, false
}
