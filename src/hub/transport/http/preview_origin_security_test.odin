package http

import "base:runtime"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

@(test)
test_preview_origin_host_matching :: proc(t: ^testing.T) {
	testing.expect(t, preview_origin_host_matches("preview.example", "https://preview.example"))
	testing.expect(t, preview_origin_host_matches("PREVIEW.EXAMPLE:443", "https://preview.example/"))
	testing.expect(t, !preview_origin_host_matches("preview.example:8443", "https://preview.example"))
	testing.expect(t, !preview_origin_host_matches("hub.example", "https://preview.example"))
}

@(test)
test_preview_origin_legacy_gate_and_owner_check :: proc(t: ^testing.T) {
	testing.expect(t, preview_legacy_path_allowed("", false))
	testing.expect(t, preview_legacy_path_allowed("https://preview.example", true))
	testing.expect(t, !preview_legacy_path_allowed("https://preview.example", false))
	testing.expect(t, preview_owner_allowed("user_a", "user_a"))
	testing.expect(t, !preview_owner_allowed("user_a", "user_b"))
}

@(test)
test_preview_origin_cookie_filter :: proc(t: ^testing.T) {
	actual := _preview_filter_cookie_header("app=1; authentik_proxy_x=secret; AUTHENTIK_SESSION=s; theme=dark")
	defer delete(actual)
	testing.expect_value(t, actual, "app=1; theme=dark")
}

@(test)
test_preview_origin_referrer_policy_default :: proc(t: ^testing.T) {
	added := _preview_filter_response_head("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", "/p/ss_1", 5173, true)
	defer delete(added, runtime.heap_allocator())
	testing.expect(t, strings.contains(added, "Referrer-Policy: same-origin\r\n"))
	preserved := _preview_filter_response_head("HTTP/1.1 200 OK\r\nReferrer-Policy: no-referrer\r\n\r\n", "/p/ss_1", 5173, true)
	defer delete(preserved, runtime.heap_allocator())
	testing.expect(t, strings.contains(preserved, "Referrer-Policy: no-referrer\r\n"))
	testing.expect(t, !strings.contains(preserved, "Referrer-Policy: same-origin"))
}

@(private = "file")
csrf_headers :: proc(values: ..contracts.HTTP_Header) -> []contracts.HTTP_Header { return values[:] }

@(test)
test_csrf_decision_table :: proc(t: ^testing.T) {
	ui := "https://hub.example"
	allow, _ := csrf_decide("POST", csrf_headers({name="Sec-Fetch-Site", value="same-origin"}), ui, false)
	testing.expect(t, allow)
	allow, _ = csrf_decide("POST", csrf_headers({name="Sec-Fetch-Site", value="same-site"}), ui, false)
	testing.expect(t, !allow)
	allow, _ = csrf_decide("POST", csrf_headers({name="Sec-Fetch-Site", value="cross-site"}), ui, false)
	testing.expect(t, !allow)
	allow, _ = csrf_decide("POST", csrf_headers({name="Origin", value="https://preview.example"}), ui, false)
	testing.expect(t, !allow)
	allow, _ = csrf_decide("POST", csrf_headers({name="Origin", value=ui}), ui, false)
	testing.expect(t, allow)
	allow, _ = csrf_decide("POST", nil, ui, false)
	testing.expect(t, allow)
	allow, _ = csrf_decide("POST", csrf_headers({name="Cookie", value="sid=x"}), ui, false)
	testing.expect(t, !allow)
	allow, _ = csrf_decide("GET", csrf_headers({name="Sec-Fetch-Site", value="cross-site"}), ui, false)
	testing.expect(t, allow)
	allow, _ = csrf_decide("GET", csrf_headers({name="Cookie", value="sid=x"}, {name="Origin", value="https://preview.example"}), ui, true)
	testing.expect(t, !allow)
	allow, _ = csrf_decide("GET", csrf_headers({name="Cookie", value="sid=x"}, {name="Origin", value=ui}), ui, true)
	testing.expect(t, allow)
	allow, _ = csrf_decide("GET", nil, ui, true)
	testing.expect(t, allow)
}
