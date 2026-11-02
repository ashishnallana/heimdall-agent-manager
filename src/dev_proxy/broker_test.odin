package main

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

@(test)
test_broker_learns_ui_origin_and_detects_mock_provider :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	authorize := "http://127.0.0.1:18090/application/o/heimdall-native/authorize/?response_type=code&client_id=heimdall-web&redirect_uri=http%3A%2F%2F127.0.0.1%3A15173%2Fapi%2Fv1%2Fauth%2Fcallback&state=s"
	testing.expect_value(t, ui_origin_from_authorize(authorize), "http://127.0.0.1:15173")
	testing.expect_value(t, ui_origin_from_authorize("http://127.0.0.1:1/authorize/?redirect_uri=http%3A%2F%2Fx%2Fother"), "")
	testing.expect(t, is_loopback_http_url(authorize))
	testing.expect(t, is_loopback_http_url("http://localhost:9000/authorize"))
	testing.expect(t, !is_loopback_http_url("https://auth.mundus.in/application/o/heimdall-native/authorize/"))
	testing.expect(t, !is_loopback_http_url("http://127.0.0.1.evil.example/authorize"))
	testing.expect_value(t, callback_path_and_query("http://127.0.0.1:15173/api/v1/auth/callback?code=c&state=s"), "/api/v1/auth/callback?code=c&state=s")
	testing.expect_value(t, callback_path_and_query("/api/v1/auth/callback?code=c#frag"), "/api/v1/auth/callback?code=c")
	testing.expect_value(t, callback_path_and_query("http://127.0.0.1:15173"), "")
}

@(test)
test_broker_trusts_only_local_or_configured_browser_requests :: proc(t: ^testing.T) {
	config := default_dev_proxy_config()
	defer delete(config.users)
	defer delete(config.trusted_origins)
	testing.expect(t, broker_request_trusted(&config, nil), "no Origin (curl, same-origin GET)")
	testing.expect(t, broker_request_trusted(&config, []contracts.HTTP_Header{{name = "Origin", value = "http://127.0.0.1:15173"}}))
	testing.expect(t, broker_request_trusted(&config, []contracts.HTTP_Header{{name = "Origin", value = "http://localhost:5173"}, {name = "Sec-Fetch-Site", value = "same-origin"}}))
	testing.expect(t, !broker_request_trusted(&config, []contracts.HTTP_Header{{name = "Origin", value = "http://localhost.evil.example"}}))
	testing.expect(t, !broker_request_trusted(&config, []contracts.HTTP_Header{{name = "Sec-Fetch-Site", value = "cross-site"}}))
	testing.expect(t, !broker_request_trusted(&config, []contracts.HTTP_Header{{name = "Origin", value = "http://127.0.0.1:3000"}, {name = "Sec-Fetch-Site", value = "same-site"}}))
	testing.expect(t, !broker_request_trusted(&config, []contracts.HTTP_Header{{name = "Authorization", value = "Bearer t"}}), "bearer keeps its own credential")

	preview := []contracts.HTTP_Header{{name = "Origin", value = "https://heimdall-preview.mundus.in"}}
	testing.expect(t, !broker_request_trusted(&config, preview))
	append(&config.trusted_origins, "https://heimdall-preview.mundus.in")
	testing.expect(t, broker_request_trusted(&config, preview))
}

@(test)
test_broker_swaps_cookies_and_origin_for_the_hub :: proc(t: ^testing.T) {
	incoming := []contracts.HTTP_Header{
		{name = "Accept", value = "application/json"},
		{name = "Cookie", value = "theme=dark; __Host-heimdall_session=browser; ham_dev_user=paid; __Host-heimdall_login=x"},
		{name = "Origin", value = "https://heimdall-preview.mundus.in"},
		{name = "Sec-Fetch-Site", value = "same-origin"},
		{name = "Sec-Fetch-Mode", value = "cors"},
	}
	out := broker_headers_for_hub(incoming, "brokered", "http://127.0.0.1:15173")
	defer free_headers(out)
	testing.expect_value(t, header_value(out, "Accept"), "application/json")
	testing.expect_value(t, header_value(out, "Cookie"), "theme=dark; __Host-heimdall_session=brokered")
	testing.expect_value(t, header_value(out, "Origin"), "http://127.0.0.1:15173")
	testing.expect_value(t, header_value(out, "Sec-Fetch-Site"), "")
	testing.expect_value(t, header_value(out, "Sec-Fetch-Mode"), "")
	testing.expect_value(t, len(out), 3)
}

@(test)
test_broker_keeps_hub_cookies_out_of_responses :: proc(t: ^testing.T) {
	head := "HTTP/1.1 200 OK\r\nSet-Cookie: __Host-heimdall_session=; Path=/; Max-Age=0\r\nSet-Cookie: other=1; Path=/\r\nSet-Cookie: __Host-heimdall_login=z; Path=/\r\nContent-Length: 2"
	stripped := strip_hub_auth_set_cookies(head)
	defer delete(stripped)
	testing.expect_value(t, stripped, "HTTP/1.1 200 OK\r\nSet-Cookie: other=1; Path=/\r\nContent-Length: 2")

	defer free_all(context.temp_allocator)
	response := "HTTP/1.1 302 Found\r\nLocation: /\r\nSet-Cookie: __Host-heimdall_session=abc; Path=/; Secure; HttpOnly\r\n\r\n"
	testing.expect_value(t, response_status(response), 302)
	testing.expect_value(t, response_status("garbage"), 0)
	testing.expect_value(t, response_header(response, "location"), "/")
	testing.expect_value(t, set_cookie_from_response(response, HUB_SESSION_COOKIE), "abc")
	testing.expect_value(t, set_cookie_from_response(response, HUB_LOGIN_COOKIE), "")
}

@(test)
test_broker_return_to_stays_local :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, safe_return_to("%2Fsettings%3Ftab%3D1"), "/settings?tab=1")
	testing.expect_value(t, safe_return_to("/tasks"), "/tasks")
	testing.expect_value(t, safe_return_to(""), "/")
	testing.expect_value(t, safe_return_to("%2F%2Fevil.example"), "/")
	testing.expect_value(t, safe_return_to("https%3A%2F%2Fevil.example"), "/")
	testing.expect_value(t, safe_return_to("/%5Cevil.example"), "/")
}

@(test)
test_broker_session_cache_invalidate_and_sign_out :: proc(t: ^testing.T) {
	config := default_dev_proxy_config()
	defer delete(config.users)
	b: Dev_Session_Broker
	defer {
		for k, v in b.sessions { delete(k); delete(v) }
		delete(b.sessions)
		for k in b.logged_out do delete(k)
		delete(b.logged_out)
	}
	b.sessions[strings.clone("paid")] = strings.clone("s1")
	testing.expect_value(t, broker_session(&b, &config, "paid"), "s1")

	broker_invalidate(&b, "paid", "stale")
	testing.expect_value(t, broker_cached_session(&b, "paid"), "s1")
	broker_invalidate(&b, "paid", "s1")
	testing.expect_value(t, broker_cached_session(&b, "paid"), "")

	b.sessions[strings.clone("paid")] = strings.clone("s2")
	broker_sign_out(&b, "paid")
	broker_sign_out(&b, "paid")
	testing.expect_value(t, broker_cached_session(&b, "paid"), "")
	// Signed out: no automatic sign-in (and so no network) until /api/v1/auth/login.
	testing.expect_value(t, broker_session(&b, &config, "paid"), "")
}

@(test)
test_broker_leaves_script_credentials_and_sign_in_alone :: proc(t: ^testing.T) {
	config := default_dev_proxy_config()
	defer delete(config.users)
	own_session := []contracts.HTTP_Header{{name = "Cookie", value = "__Host-heimdall_session=script"}, {name = "Origin", value = "http://127.0.0.1:18080"}}
	testing.expect(t, !broker_request_trusted(&config, own_session), "a script's own session is kept")
	testing.expect(t, broker_request_trusted(&config, []contracts.HTTP_Header{{name = "Cookie", value = "__Host-heimdall_session=; theme=dark"}}), "an empty session cookie is no credential")

	testing.expect(t, is_browser_navigation([]contracts.HTTP_Header{{name = "Accept", value = "text/html,application/xhtml+xml,*/*;q=0.8"}}))
	testing.expect(t, is_browser_navigation([]contracts.HTTP_Header{{name = "Sec-Fetch-Mode", value = "navigate"}}))
	testing.expect(t, !is_browser_navigation([]contracts.HTTP_Header{{name = "Accept", value = "*/*"}}), "fetch()-driven sign-in keeps the provider redirect")
	testing.expect(t, !is_browser_navigation(nil))
}
