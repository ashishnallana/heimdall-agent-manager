package http

import "core:encoding/base64"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"

@(test)
test_artifact_request_bound_covers_sealed_15_mib_upload :: proc(t: ^testing.T) {
	// The stored bound is the armored size of exactly 15 MiB of plaintext.
	testing.expect_value(t, ARTIFACT_MAX_STORED_BYTES, domain.vault_armored_max_bytes(contracts.ARTIFACT_MAX_CONTENT_BYTES))
	// base64 of that stored value plus metadata fits the per-route and global caps.
	testing.expect(t, ARTIFACT_MAX_REQUEST_BYTES >= 4 * ((ARTIFACT_MAX_STORED_BYTES + 2) / 3), "request bound admits base64 of a sealed 15 MiB artifact")
	testing.expect(t, ARTIFACT_MAX_REQUEST_BYTES <= MAX_HTTP_REQUEST_BYTES, "artifact bound fits the shared reader cap")

	at_limit := Request{body = strings.repeat(" ", ARTIFACT_MAX_REQUEST_BYTES, context.temp_allocator)}
	_, too_large := artifact_request_too_large(at_limit)
	testing.expect(t, !too_large, "a request exactly at the bound is accepted")
	over := Request{body = strings.repeat(" ", ARTIFACT_MAX_REQUEST_BYTES + 1, context.temp_allocator)}
	err, rejected := artifact_request_too_large(over)
	testing.expect(t, rejected, "one byte over the bound is rejected")
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
}

@(test)
test_artifact_input_decodes_binary_content_base64_byte_exact :: proc(t: ^testing.T) {
	payload := []byte{0x50, 0x4b, 0x03, 0x04, 0xff, 0xfe, 0x00, 0x80, 0xc3, 0x28, 0x00, 0x01}
	encoded := base64.encode(payload, allocator = context.temp_allocator)
	body := strings.concatenate({`{"name":"a.zip","kind":"file","content_base64":"`, encoded, `"}`}, context.temp_allocator)
	input := artifact_input(body)
	testing.expect_value(t, len(input.content), len(payload))
	testing.expect(t, input.content == string(payload), "decoded bytes reach the service unchanged")
}

@(test)
test_transfer_body_bounds_cover_15_mib_ciphertext :: proc(t: ^testing.T) {
	testing.expect_value(t, transfer_body_bound("PUT", true), 20_971_598)
	testing.expect_value(t, transfer_body_bound("PATCH", true), 8 * 1024 * 1024)
	testing.expect_value(t, transfer_body_bound("POST", false), 64 * 1024)
	testing.expect_value(t, transfer_body_bound("POST", true), -1)
	testing.expect_value(t, transfer_body_bound("GET", true), -1)
	// Three PATCHes carry the worst-case 15 MiB token.
	testing.expect(t, 3 * transfer_body_bound("PATCH", true) >= transfer_body_bound("PUT", true))
}
