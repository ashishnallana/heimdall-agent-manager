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

	_, ok, message = normalize_preview_origin("http://preview.example", "https://hub.example")
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(message, "--preview-origin"))
	_, ok, _ = normalize_preview_origin("https://preview.example/path", "https://hub.example")
	testing.expect(t, !ok)
	_, ok, _ = normalize_preview_origin("https://hub.example/", "https://hub.example")
	testing.expect(t, !ok)
}
