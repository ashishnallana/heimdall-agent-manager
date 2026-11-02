package contracts

Artifact_ID :: distinct string

// ── Artifact content limit (REQ-ART-1) ──
//
// "15 MB" for an artifact means exactly 15 MiB = 15 * 1024 * 1024 = 15,728,640
// bytes of DECODED content: the raw file bytes (binary) or the UTF-8 bytes
// (text), i.e. after any base64 / JSON-string / multipart decoding and before any
// vault encryption. 15,728,640 is accepted; 15,728,641 is rejected.
//
// Transport and vault overhead is accounted for SEPARATELY, never by loosening
// this number:
//   - vault armor: the Hub is zero-knowledge, so a sealed value is checked
//     against domain.vault_armored_max_bytes(ARTIFACT_MAX_CONTENT_BYTES)
//     (prefix + base64(nonce|tag|ct)), the storage bound of a 15 MiB plaintext;
//   - request framing: base64 of that stored value inside JSON, or multipart
//     boundaries, plus metadata, bounded per route by the HTTP layer.
// Clients (ham-ctl, the web UI) enforce the plaintext limit before sealing.
ARTIFACT_MAX_CONTENT_BYTES :: 15 * 1024 * 1024

// ARTIFACT_MAX_CONTENT_LABEL is the human wording used in errors, UI and docs.
ARTIFACT_MAX_CONTENT_LABEL :: "15 MB (15 MiB, 15,728,640 bytes)"

#assert(ARTIFACT_MAX_CONTENT_BYTES == 15_728_640)
