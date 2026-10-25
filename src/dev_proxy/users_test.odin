package main

import "core:testing"
import contracts "odin_test:contracts"

@(test)
test_default_roster_has_free_default_and_paid_user :: proc(t: ^testing.T) {
	config := default_dev_proxy_config()
	defer delete(config.users)
	testing.expect_value(t, config.default_user, "tanmay")

	found_paid := false
	for user in config.users {
		if user.username == "paid" {
			found_paid = true
			testing.expect_value(t, user.display_name, "Paid User")
			testing.expect_value(t, user.email, "paid@example.com")
		}
	}
	testing.expect(t, found_paid, "default roster must include the paid seed user")

	headers := []contracts.HTTP_Header{{name = "X-Dev-User", value = "paid"}}
	selected, ok := select_dev_user(&config, headers, "")
	testing.expect(t, ok)
	testing.expect_value(t, selected.username, "paid")

	fallback, fallback_ok := select_dev_user(&config, nil, "")
	testing.expect(t, fallback_ok)
	testing.expect_value(t, fallback.username, "tanmay")
}

@(test)
test_proxy_strips_identity_headers_and_hints_login :: proc(t: ^testing.T) {
	config := default_dev_proxy_config()
	defer delete(config.users)
	incoming := []contracts.HTTP_Header{
		{name = "X-authentik-username", value = "mallory"},
		{name = "X-Dev-User", value = "paid"},
		{name = "Cookie", value = "__Host-heimdall_session=abc"},
		{name = "Authorization", value = "Bearer token"},
	}
	out, user, ok := rewrite_headers_for_hub(&config, incoming, "")
	defer free_headers(out)
	testing.expect(t, ok)
	testing.expect_value(t, user.username, "paid")
	testing.expect_value(t, len(out), 2) // cookie + Authorization pass through unchanged
	for h in out do testing.expect(t, !is_client_control_header(h.name), h.name)
	response := "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:9400/application/o/heimdall-native/authorize/?state=s\r\nContent-Length: 0\r\n\r\n"
	rewritten := rewrite_login_location(response, "paid")
	defer delete(rewritten)
	testing.expect_value(t, rewritten, "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:9400/application/o/heimdall-native/authorize/?state=s&login_hint=paid\r\nContent-Length: 0\r\n\r\n")
}
