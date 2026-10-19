package http

import "core:strings"
import "core:testing"
import device_auth "odin_test:hub/service/device_auth"

// REQ-T1-1 / REQ-T1-4: GET /api/v1/device/add folds the path-form enrollment
// link back into the UI hash route, carrying the code only in its canonical,
// re-derived form.

@(private = "file")
device_add_redirect_test_get :: proc(ui_origin, query: string) -> Response {
	handlers := Device_Auth_Handlers{ui_origin = ui_origin}
	return device_add_redirect_handler(rawptr(&handlers), Request{method = "GET", path = "/api/v1/device/add", query = query})
}

@(private = "file")
device_add_redirect_test_location :: proc(resp: Response) -> (string, bool) {
	for h in resp.headers {
		if h.name == "Location" do return h.value, true
	}
	return "", false
}

@(test)
test_device_add_redirect_variants :: proc(t: ^testing.T) {
	cases := []struct {
		name:      string,
		ui_origin: string,
		query:     string,
		expected:  string,
	} {
		{"valid code, relative", "", "code=ABCD-2345", "/#/device/add"},
		{"valid code, ui origin", "https://heimdall.example.com", "code=ABCD-2345", "https://heimdall.example.com/#/device/add"},
		{"ui origin trailing slash", "https://heimdall.example.com/", "code=ABCD-2345", "https://heimdall.example.com/#/device/add"},
		{"lowercase, no dash", "", "code=abcd2345", "/#/device/add"},
		{"encoded spaces", "", "code=abcd%202345", "/#/device/add"},
		{"code among other params", "", "x=1&code=WXYZ-7777&y=2", "/#/device/add"},
		{"missing code, relative", "", "", "/#/device/add"},
		{"missing code, ui origin", "https://heimdall.example.com", "", "https://heimdall.example.com/#/device/add"},
		{"empty code", "", "code=", "/#/device/add"},
		{"too short", "", "code=ABCD-234", "/#/device/add"},
		{"overlong", "", "code=ABCD-23456", "/#/device/add"},
		{"very overlong", "", "code=ABCDEFGHABCDEFGHABCDEFGHABCDEFGHABCDEFGH", "/#/device/add"},
		{"excluded digits", "", "code=ABCD-2189", "/#/device/add"},
		{"CRLF injection", "", "code=ABCD-2345%0D%0ASet-Cookie:%20x=1", "/#/device/add"},
		{"raw CRLF", "", "code=ABCD\r\n2345", "/#/device/add"},
		{"bare LF inside code", "", "code=ABCD%0A2345", "/#/device/add"},
		{"html injection", "", "code=%3Cscript%3EABCD2345", "/#/device/add"},
		{"angle bracket", "", "code=ABCD<2345", "/#/device/add"},
		{"fragment smuggling", "", "code=ABCD-2345%23/evil", "/#/device/add"},
	}
	for tc in cases {
		resp := device_add_redirect_test_get(tc.ui_origin, tc.query)
		testing.expectf(t, resp.status == 302, "%s: status = %d, want 302", tc.name, resp.status)
		location, ok := device_add_redirect_test_location(resp)
		testing.expectf(t, ok, "%s: no Location header", tc.name)
		testing.expectf(t, location == tc.expected, "%s: Location = %q, want %q", tc.name, location, tc.expected)
		for forbidden in ([?]string{"\r", "\n", "<", ">", "script", "Set-Cookie", "evil"}) {
			testing.expectf(t, !strings.contains(location, forbidden), "%s: Location echoed %q", tc.name, forbidden)
		}
		testing.expectf(t, len(resp.headers) == 1, "%s: expected exactly one header, got %d", tc.name, len(resp.headers))
		delete(resp.headers)
	}
}

@(test)
test_status_text_302_is_found :: proc(t: ^testing.T) {
	testing.expect_value(t, status_text(302), "Found")
}

@(test)
test_normalize_user_code :: proc(t: ^testing.T) {
	valid := []struct {
		raw:      string,
		expected: string,
	} {
		{"ABCD-2345", "ABCD-2345"},
		{"ABCD2345", "ABCD-2345"},
		{"abcd-2345", "ABCD-2345"},
		{"  aBcD 23\t45  ", "ABCD-2345"},
		{"AB-CD-23-45", "ABCD-2345"},
		{"ZZZZ7777", "ZZZZ-7777"},
	}
	for tc in valid {
		code, ok := device_auth.normalize_user_code(tc.raw, context.temp_allocator)
		testing.expectf(t, ok, "%q: rejected, want %q", tc.raw, tc.expected)
		testing.expectf(t, code == tc.expected, "%q: got %q, want %q", tc.raw, code, tc.expected)
	}
	invalid := []string{
		"", "-", "ABCD", "ABCD-234", "ABCD-23456", "ABCDEFGHI",
		"ABCD-2340", "ABCD-2381", "ABCD-2389", // 0/1/8/9 are outside the alphabet
		"ABCD\r\n2345", "ABCD\n2345", "ABCD<2345", "ABCD>2345", "ABCD_2345", "ABCD.2345",
		"ABCD-2345#", "ABCD-2345?x=1", "ÄBCD-2345", "ABCD\x002345",
	}
	for raw in invalid {
		code, ok := device_auth.normalize_user_code(raw, context.temp_allocator)
		testing.expectf(t, !ok, "%q: accepted as %q, want rejection", raw, code)
		testing.expectf(t, code == "", "%q: rejected but returned %q", raw, code)
	}
}
