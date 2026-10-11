package http

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"

@(private = "file")
preview_url_test_session :: proc(port: int = 5173) -> domain.Shell_Session {
	return domain.Shell_Session{session_id = "ss_1", server_port = port}
}

@(test)
test_shell_session_preview_url_variants :: proc(t: ^testing.T) {
	cases := []struct {
		preview_origin: string,
		ui_origin:      string,
		port:           int,
		expected:       string,
	}{
		{"https://preview.example", "https://hub.example", 5173, "https://preview.example/p/ss_1/"},
		{"https://preview.example/", "https://hub.example", 5173, "https://preview.example/p/ss_1/"},
		{"", "https://hub.example", 5173, "https://hub.example/api/v1/preview/ss_1/"},
		{"", "", 5173, "/api/v1/preview/ss_1/"},
		{"https://preview.example", "https://hub.example", 0, ""},
	}
	for tc in cases {
		actual := shell_session_preview_url(preview_url_test_session(tc.port), tc.preview_origin, tc.ui_origin)
		testing.expect_value(t, actual, tc.expected)
		delete(actual)
	}
}

@(test)
test_shell_session_json_contains_preview_url :: proc(t: ^testing.T) {
	b := strings.builder_make()
	write_shell_session_json(&b, preview_url_test_session(), nil, "https://preview.example", "https://hub.example")
	actual := strings.to_string(b)
	defer delete(actual)
	testing.expect(t, strings.contains(actual, `"preview_url":"https://preview.example/p/ss_1/"`))
}
