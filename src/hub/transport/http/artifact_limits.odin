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

// ── E2EE transfer data-path body bounds (docs/plans/mcp-large-artifact-transfers.md §5.2/§7) ──
//
// Transfer bodies are ciphertext of one vault v2 token and are bounded BEFORE they are
// read: PATCH <= 8 MiB, PUT <= the armored size of a 15 MiB plaintext (streamed to
// <= 1 MiB chunk rows), seal/opened JSON <= 64 KiB. All sit far below the shared
// 80 MiB reader cap.
TRANSFER_PUT_MAX_BYTES   :: contracts.ARTIFACT_TRANSFER_CIPHERTEXT_MAX_BYTES
TRANSFER_PATCH_MAX_BYTES :: contracts.ARTIFACT_TRANSFER_CHUNK_MAX_BYTES
// A single download response carries at most one stored window (design §7).
TRANSFER_GET_WINDOW_BYTES :: i64(contracts.ARTIFACT_TRANSFER_STORE_CHUNK_BYTES)
TRANSFER_JSON_MAX_BYTES  :: contracts.ARTIFACT_TRANSFER_JSON_MAX_BYTES
#assert(TRANSFER_PUT_MAX_BYTES == ARTIFACT_MAX_STORED_BYTES)
#assert(TRANSFER_PUT_MAX_BYTES < 80 * 1024 * 1024)

// transfer_body_bound returns the maximum body for a transfer data-path request, or
// -1 when the method/route carries no body.
transfer_body_bound :: proc(method: string, ciphertext_route: bool) -> int {
	switch method {
	case "PUT":   return ciphertext_route ? TRANSFER_PUT_MAX_BYTES : -1
	case "PATCH": return ciphertext_route ? TRANSFER_PATCH_MAX_BYTES : -1
	case "POST":  return ciphertext_route ? -1 : TRANSFER_JSON_MAX_BYTES
	}
	return -1
}
