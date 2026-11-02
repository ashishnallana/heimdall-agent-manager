package main

import "core:strings"
import contracts "odin_test:contracts"

// The Hub authenticates users only with OIDC (its own session cookie or a bearer),
// so this proxy never injects identity headers. The dev-user selector and legacy
// identity headers are always stripped so a client can never smuggle them upstream.
//
// The selected dev user is applied through a real Hub session instead: with the
// local mock provider the proxy signs in on the user's behalf and attaches that
// session (broker.odin); requests carrying their own credential pass unchanged.
// Against a real provider, or for a script running the sign-in itself, the Hub's
// /api/v1/auth/login redirect gets `login_hint=<user>` appended
// (rewrite_login_location) and tools/mock-oidc signs in as that user.
rewrite_headers_for_hub :: proc(config: ^Dev_Proxy_Config, incoming: []contracts.HTTP_Header, cookie_header: string) -> ([]contracts.HTTP_Header, Dev_User, bool) {
	user, ok := select_dev_user(config, incoming, cookie_header)
	if !ok do return nil, {}, false
	out := make([dynamic]contracts.HTTP_Header)
	for header in incoming {
		if is_client_control_header(header.name) do continue
		append(&out, contracts.HTTP_Header{name = strings.clone(header.name), value = strings.clone(header.value)})
	}
	return out[:], user, true
}

free_headers :: proc(headers: []contracts.HTTP_Header) {
	for h in headers {
		delete(h.name)
		delete(h.value)
	}
	delete(headers)
}

// is_client_control_header: never forwarded. X-authentik-* identity headers are
// meaningless to the Hub now, but stripping them keeps old clients/scripts from
// believing they still work.
is_client_control_header :: proc(name: string) -> bool {
	if ascii_has_prefix_fold(name, "X-authentik-") do return true
	if ascii_equal_fold(name, "X-Dev-User") do return true
	return false
}

// rewrite_login_location appends login_hint=<username> to the Location of the
// Hub's /api/v1/auth/login redirect (the provider authorize URL). Only the
// Location header of that one response is touched.
rewrite_login_location :: proc(response, username: string) -> string {
	head_end := strings.index(response, "\r\n\r\n")
	if head_end < 0 || username == "" do return response
	head := response[:head_end]
	b := strings.builder_make()
	rest := head
	first := true
	for line in strings.split_lines_iterator(&rest) {
		if !first do strings.write_string(&b, "\r\n")
		first = false
		if ascii_has_prefix_fold(line, "Location:") {
			location := strings.trim_space(line[len("Location:"):])
			sep := "&" if strings.contains(location, "?") else "?"
			strings.write_string(&b, "Location: ")
			strings.write_string(&b, location)
			strings.write_string(&b, sep)
			strings.write_string(&b, "login_hint=")
			strings.write_string(&b, username)
			continue
		}
		strings.write_string(&b, line)
	}
	strings.write_string(&b, response[head_end:])
	return strings.to_string(b)
}

login_response_cookie :: proc(username: string) -> string {
	return strings.concatenate({"ham_dev_user=", username, "; Path=/; SameSite=Lax"})
}

logout_response_cookie :: proc() -> string {
	return "ham_dev_user=; Path=/; Max-Age=0; SameSite=Lax"
}
