#+feature dynamic-literals
package html_bundle

import "core:encoding/base64"
import "core:encoding/json"
import "core:strings"
import "core:testing"

@(private = "file")
parse_files :: proc(t: ^testing.T, text: string) -> json.Object {
	value, err := json.parse_string(text, parse_integers = true, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	obj, _ := value.(json.Object)
	return obj
}

@(test)
test_entry_files_packs_text_and_binary_byte_exact :: proc(t: ^testing.T) {
	png := []byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0xff, 0x80, 0x01}
	encoded, _ := base64.encode(png, allocator = context.temp_allocator)
	files := parse_files(t, strings.concatenate({`{"index.html":{"text":"<!doctype html><link rel=stylesheet href=styles.css><img src=logo.png>"},"styles.css":{"text":"body {color:red}"},"logo.png":{"base64":"`, encoded, `","type":"image/png"}}`}, context.temp_allocator))
	result, err := html_bundle_from_entry_files("index.html", files, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, result.entry, "index.html")
	testing.expect_value(t, result.files, 3)
	testing.expect_value(t, result.pages, 1)
	archive, parse_err := html_bundle_parse_zip(result.zip)
	testing.expect_value(t, parse_err, "")
	found := 0
	for m in archive.members {
		data, read_err := html_bundle_read_member(&archive, m, context.temp_allocator)
		testing.expect_value(t, read_err, "")
		switch m.path {
		case "logo.png": testing.expect(t, string(data) == string(png)); found += 1
		case "styles.css": testing.expect_value(t, string(data), "body {color:red}"); found += 1
		case HTML_BUNDLE_MANIFEST:
			entry, manifest_err := html_bundle_parse_manifest(data)
			testing.expect_value(t, manifest_err, ""); testing.expect_value(t, entry, "index.html"); found += 1
		}
	}
	testing.expect_value(t, found, 3)
	// Deterministic: the same input packs to identical bytes.
	again, _ := html_bundle_from_entry_files("index.html", files, context.temp_allocator)
	testing.expect(t, string(again.zip) == string(result.zip))
}

@(test)
test_entry_files_rejects_unsafe_and_malformed_input :: proc(t: ^testing.T) {
	cases := [][2]string{
		{"index.html", `{"../index.html":{"text":"x"}}`},
		{"index.html", `{"a/./b.html":{"text":"x"},"index.html":{"text":"x"}}`},
		{"index.html", `{"/abs.html":{"text":"x"},"index.html":{"text":"x"}}`},
		{"index.html", `{"a\\b.html":{"text":"x"},"index.html":{"text":"x"}}`},
		{"index.html", `{"other.html":{"text":"x"}}`},                       // missing entry
		{"", `{"index.html":{"text":"x"}}`},                                  // empty entry
		{"style.css", `{"style.css":{"text":"x"}}`},                          // entry not HTML
		{"index.html", `{"index.html":{"text":"x","base64":"eA=="}}`},        // conflicting
		{"index.html", `{"index.html":{}}`},                                  // neither
		{"index.html", `{"index.html":{"text":"x"},"a.png":{"base64":"not base64!"}}`},
		{"index.html", `{"index.html":{"text":"x"},"a.png":{"base64":"eA="}}`},      // bad padding
		{"index.html", `{"index.html":{"text":"x"},"a.png":{"base64":"eB=="}}`},     // non-canonical
		{"index.html", `{"index.html":{"text":"x"},"a.png":{"base64":"eA==\n"}}`},   // whitespace
		{"index.html", `{"index.html":{"text":"x"},"a.exe":{"base64":"eA=="}}`},     // type
		{"index.html", `{"index.html":{"text":"x"},"README":{"text":"x"}}`},         // no extension
		{"index.html", `{"index.html":{"text":"x"},"a.png":{"base64":"eA==","type":"text/html"}}`},
		{"index.html", `{"index.html":{"text":"x"},"a.zip":{"base64":"eA=="}}`},     // nested by name
		{"index.html", `{"index.html":{"text":"x"},"a.png":{"base64":"UEsDBA=="}}`}, // nested by magic
		{"index.html", `{"index.html":{"text":"x"},"heimdall-artifact.json":{"text":"{}"}}`},
		{"index.html", `{"index.html":{"text":"x"},"a":{"text":"x"},"a/b.css":{"text":"x"}}`},
		{"index.html", `{"index.html":{"text":"x","mode":"0755"}}`},                 // unknown key
		{"index.html", `{"index.html":"x"}`},                                        // not an object
		{"index.html", `{"index.html":{"text":5}}`},
		{"index.html", `{}`},
	}
	for c in cases {
		_, err := html_bundle_from_entry_files(c[0], parse_files(t, c[1]), context.temp_allocator)
		testing.expectf(t, err != "", "expected rejection for entry=%q files=%s", c[0], c[1])
	}
}

@(test)
test_entry_files_enforces_15_mib_decoded_budget :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	// One member just under the archive limit after ZIP + manifest overhead fits;
	// the exact limit of decoded bytes plus any overhead is rejected with a size error.
	big := make([]byte, HTML_BUNDLE_MAX_ARCHIVE - 4096, context.temp_allocator)
	for i in 0 ..< len(big) do big[i] = byte(i * 31)
	encoded, _ := base64.encode(big, allocator = context.temp_allocator)
	files := make(json.Object, allocator = context.temp_allocator)
	files["index.html"] = json.Object{"text" = json.String("<p>x</p>")}
	files["blob.png"] = json.Object{"base64" = json.String(encoded)}
	result, err := html_bundle_from_entry_files("index.html", files, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect(t, len(result.zip) <= HTML_BUNDLE_MAX_ARCHIVE)
	over := make([]byte, HTML_BUNDLE_MAX_ARCHIVE, context.temp_allocator)
	over_encoded, _ := base64.encode(over, allocator = context.temp_allocator)
	files["blob.png"] = json.Object{"base64" = json.String(over_encoded)}
	_, over_err := html_bundle_from_entry_files("index.html", files, context.temp_allocator)
	testing.expect(t, strings.contains(over_err, "15 MiB"))
}
