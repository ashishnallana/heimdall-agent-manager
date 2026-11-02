package main

import "core:strings"
import contracts "odin_test:contracts"

Dev_User :: struct {
	username: string,
	display_name: string,
	email: string,
}

Dev_Proxy_Config :: struct {
	listen: string,
	hub_url: string,
	default_user: string,
	users: []Dev_User,
	// DP-7: management API/UI (/_dev/*) are served ONLY on a loopback bind.
	// Set in main() from the parsed --listen host; non-loopback binds get 404
	// on every /_dev/ route so management is never exposed remotely.
	management_enabled: bool,
	// The Hub's --ui-origin, sent as Origin on brokered requests. Empty: learned
	// from the redirect_uri of the Hub's sign-in redirect (broker.odin).
	hub_ui_origin: string,
	// Browser origins besides loopback that may use the brokered session, e.g. the
	// Heimdall preview origin when the dev UI is viewed through a preview.
	trusted_origins: [dynamic]string,
}

default_dev_proxy_config :: proc() -> Dev_Proxy_Config {
	// "paid" is the local paid-plan account: scripts/local-hub.sh seeds it on the
	// hobbyist plan, while every other user stays on the free default.
	users := make([]Dev_User, 3)
	users[0] = Dev_User{username = "tanmay", display_name = "Tanmay Vijay", email = "tanmay@example.com"}
	users[1] = Dev_User{username = "reviewer", display_name = "Reviewer User", email = "reviewer@example.com"}
	users[2] = Dev_User{username = "paid", display_name = "Paid User", email = "paid@example.com"}
	return Dev_Proxy_Config{
		listen = "127.0.0.1:8080",
		hub_url = "http://127.0.0.1:8081",
		default_user = "tanmay",
		users = users,
	}
}

select_dev_user :: proc(config: ^Dev_Proxy_Config, headers: []contracts.HTTP_Header, cookie_header: string) -> (Dev_User, bool) {
	selected := header_value(headers, "X-Dev-User")
	if selected == "" do selected = cookie_value(cookie_header, "ham_dev_user")
	if selected == "" do selected = config.default_user
	for user in config.users {
		if user.username == selected do return user, true
	}
	return Dev_User{}, false
}

cookie_value :: proc(cookie_header, name: string) -> string {
	parts := strings.split(cookie_header, ";")
	defer delete(parts)
	for part in parts {
		trimmed := strings.trim_space(part)
		eq := strings.index_byte(trimmed, '=')
		if eq < 0 do continue
		if trimmed[:eq] == name do return strings.clone(trimmed[eq + 1:])
	}
	return ""
}

header_value :: proc(headers: []contracts.HTTP_Header, name: string) -> string {
	for h in headers {
		if ascii_equal_fold(h.name, name) do return strings.trim_space(h.value)
	}
	return ""
}

ascii_equal_fold :: proc(a, b: string) -> bool {
	if len(a) != len(b) do return false
	for i in 0..<len(a) {
		ca := a[i]
		cb := b[i]
		if ca >= 'A' && ca <= 'Z' do ca += 32
		if cb >= 'A' && cb <= 'Z' do cb += 32
		if ca != cb do return false
	}
	return true
}
