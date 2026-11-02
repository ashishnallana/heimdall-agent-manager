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

// ── E2EE artifact transfer limits (docs/plans/mcp-large-artifact-transfers.md §7) ──
//
// The Hub stages and serves CIPHERTEXT only. A transfer carries one vault v2 token
// whose plaintext is at most ARTIFACT_MAX_CONTENT_BYTES; the Hub enforces that blind
// from the token length. Overhead of a 15 MiB plaintext: 28 B nonce+tag, x4/3 base64,
// <= 38 B header -> 20,971,598 B worst case (20,971,589 B at a 1-digit epoch).
ARTIFACT_TRANSFER_MAX_HEADER_BYTES     :: 38 // "vault:v2:" + 16 hex + ":e" + 10 digits + ":"
ARTIFACT_TRANSFER_CIPHERTEXT_MAX_BYTES :: ARTIFACT_TRANSFER_MAX_HEADER_BYTES + 4 * ((ARTIFACT_MAX_CONTENT_BYTES + 28 + 2) / 3)
ARTIFACT_TRANSFER_CHUNK_MAX_BYTES      :: 8 * 1024 * 1024 // PATCH body
ARTIFACT_TRANSFER_STORE_CHUNK_BYTES    :: 1024 * 1024     // PUT is streamed to rows of <= 1 MiB; GET windows
ARTIFACT_TRANSFER_JSON_MAX_BYTES       :: 64 * 1024       // seal / opened bodies
ARTIFACT_TRANSFER_MAX_UPLOADS_PER_OWNER   :: 2
ARTIFACT_TRANSFER_MAX_DOWNLOADS_PER_OWNER :: 4
ARTIFACT_TRANSFER_STAGED_MAX_PER_OWNER    :: 48 * 1024 * 1024
ARTIFACT_TRANSFER_STAGED_MAX_GLOBAL       :: 512 * 1024 * 1024
ARTIFACT_TRANSFER_IDLE_TTL_MS     :: 15 * 60 * 1000
ARTIFACT_TRANSFER_ABSOLUTE_TTL_MS :: 60 * 60 * 1000
ARTIFACT_TRANSFER_TERMINAL_KEEP_MS :: 24 * 60 * 60 * 1000
ARTIFACT_TRANSFER_MAX_FETCHES     :: 8
ARTIFACT_TRANSFER_DATA_PATH_MAX_CONCURRENT :: 8
ARTIFACT_TRANSFER_COMMIT_MAX_CONCURRENT    :: 2
ARTIFACT_TRANSFER_RETRY_AFTER_MS           :: 2000

#assert(ARTIFACT_TRANSFER_CIPHERTEXT_MAX_BYTES == 20_971_598)
