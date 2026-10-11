package app

import "core:strings"
import "core:testing"

@(test)
test_preview_origin_validation :: proc(t: ^testing.T) {
	valid, ok, message := normalize_preview_origin("https://preview.example/", "https://hub.example")
	testing.expect(t, ok)
	testing.expect_value(t, valid, "https://preview.example")
	testing.expect_value(t, message, "")
	delete(valid)
	valid, ok, message = normalize_preview_origin("https://preview.example:8443", "https://hub.example")
	testing.expect(t, ok)
	testing.expect_value(t, valid, "https://preview.example:8443")
	delete(valid)
	valid, ok, message = normalize_preview_origin("https://[2001:db8::1]:8443", "https://hub.example")
	testing.expect(t, ok)
	testing.expect_value(t, valid, "https://[2001:db8::1]:8443")
	delete(valid)

	_, ok, message = normalize_preview_origin("http://preview.example", "https://hub.example")
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(message, "--preview-origin"))
	_, ok, _ = normalize_preview_origin("https://preview.example/path", "https://hub.example")
	testing.expect(t, !ok)
	_, ok, _ = normalize_preview_origin("https://hub.example/", "https://hub.example")
	testing.expect(t, !ok)
	invalid_origins := []string{
		"https://",
		"https:///",
		"https://preview.example?x=1",
		"https://preview.example#x",
		"https://user@preview.example",
		"https://preview.example:",
		"https://preview.example:70000",
		"https://[not-an-ip]",
		"https://[2001:db8::1",
		"https://bad_host.example",
		"https://-preview.example",
		"https://preview-.example",
		"https://999.999.999.999",
	}
	for invalid in invalid_origins {
		_, case_ok, case_message := normalize_preview_origin(invalid, "https://hub.example")
		testing.expect(t, !case_ok)
		testing.expect(t, strings.contains(case_message, "--preview-origin"))
	}
}
