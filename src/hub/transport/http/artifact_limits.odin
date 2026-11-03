package http

import "core:fmt"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"

// ── Artifact request size accounting (REQ-ART-1) ──
//
// The content limit is contracts.ARTIFACT_MAX_CONTENT_BYTES (15 MiB of decoded bytes),
// enforced by content_service.create_artifact. These constants only bound the
// TRANSPORT around it so an oversized request is refused before it is decoded:
//
//   stored  <= ARTIFACT_MAX_STORED_BYTES   (a 15 MiB plaintext once vault-armored:
//                                           token header + base64(28-byte nonce|tag + ct))
//   request <= base64(stored) + ARTIFACT_REQUEST_METADATA_BYTES
//
// base64 inside a JSON string needs no escaping, and raw multipart content is smaller
// than its base64 form, so this one bound covers JSON and multipart uploads.
ARTIFACT_MAX_STORED_BYTES :: domain.VAULT_MAX_TOKEN_HEADER_LEN + 4 * ((contracts.ARTIFACT_MAX_CONTENT_BYTES + domain.VAULT_HEADER_BYTES + 2) / 3)
// Room for the JSON/multipart envelope and metadata (armored name/description, ids,
// MIME, origin), far above the 48 KiB armored per-field metadata caps.
ARTIFACT_REQUEST_METADATA_BYTES :: 1024 * 1024
ARTIFACT_MAX_REQUEST_BYTES :: 4 * ((ARTIFACT_MAX_STORED_BYTES + 2) / 3) + ARTIFACT_REQUEST_METADATA_BYTES

// artifact_request_too_large reports whether an artifact create body exceeds the
// transport bound; the error names both numbers.
artifact_request_too_large :: proc(req: Request) -> (domain.Domain_Error, bool) {
	if len(req.body) <= ARTIFACT_MAX_REQUEST_BYTES do return {}, false
	return domain.domain_error(.Validation_Failed, fmt.tprintf("artifact request is too large: %d bytes, limit %d (content limit %s)", len(req.body), ARTIFACT_MAX_REQUEST_BYTES, contracts.ARTIFACT_MAX_CONTENT_LABEL)), true
}
