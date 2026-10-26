package contracts

// Bridge loopback + bridge<->hub runtime shared contracts.
//
// Heimdall runs a star topology: every bridge talks only to the hub, and the
// hub relays cross-bridge traffic. The dead direct bridge<->bridge ("Federation
// v2 Phase 1") seam has been removed. What remains here backs:
//   1. the daemon<->bridge loopback API on :49323 (health + project-path
//      validation), and
//   2. the shared chunk/version constants used by the LIVE bridge<->hub runtime
//      WebSocket channel (bridge_hub_chunk_frames) and the hub's chunk
//      reassembler.


BRIDGE_LOOPBACK_CONTRACT_VERSION :: 1
// 2: PTY output/input are binary frames (pty_wire.odin); shell_pty_output / data_b64 are gone.
BRIDGE_WS_FRAME_VERSION :: 2

// Heartbeat metadata omission (minimal heartbeat plan T3/T4). Negotiated per
// connection and ONLY when both peers opt in:
//   - the Bridge lists BRIDGE_FEATURE_HEARTBEAT_METADATA_OMISSION in its bridge_hello
//     `features` (proof it understands the flag; old Bridges never list it), and
//   - the Hub sets bridge_ready.payload.heartbeat_metadata_omission=true.
// The ready flag alone is a Hub advertisement, not proof: an old Bridge ignores it and
// keeps sending legacy capabilities/features, which the Hub keeps applying. On a
// negotiated connection the hello record is the only metadata authority and heartbeat
// capabilities/features are ignored whether present or not.
BRIDGE_FEATURE_HEARTBEAT_METADATA_OMISSION :: "heartbeat_metadata_omission"
// Cause of the protocol_error the Hub sends before closing a connection whose stored
// metadata no longer matches what this connection's hello installed (e.g. a DB
// restore under a live Hub); the Bridge's ordinary reconnect sends a fresh hello.
BRIDGE_RESYNC_REQUIRED_CAUSE :: "resync_required"

// Loopback routes served by the bridge on :49323.
ROUTE_BRIDGE_HEALTH :: "/bridge/health"
ROUTE_BRIDGE_VALIDATE_PROJECT_PATH :: "/bridge/validate-project-path"

BRIDGE_LOOPBACK_AUTH_HEADER :: "Authorization"
BRIDGE_AUTH_BEARER_PREFIX :: "Bearer "

BRIDGE_HTTP_METHOD_GET :: "GET"
BRIDGE_HTTP_METHOD_POST :: "POST"

Bridge_Binary :: enum {
	Daemon,
	Bridge,
}

// Shared route coverage registry for the daemon<->bridge loopback surface.
// Implementations route through these constants/procs instead of duplicating
// endpoint strings. Unsupported routes must return explicit 404/501-style errors
// instead of falling through to any transport.
bridge_route_supported :: proc(binary: Bridge_Binary, method, route: string) -> bool {
	switch binary {
	case .Bridge:
		return bridge_loopback_route_supported(method, route)
	case .Daemon:
		return false
	}
	return false
}

bridge_loopback_route_supported :: proc(method, route: string) -> bool {
	switch route {
	case ROUTE_BRIDGE_HEALTH:
		return method == BRIDGE_HTTP_METHOD_GET || method == BRIDGE_HTTP_METHOD_POST
	case ROUTE_BRIDGE_VALIDATE_PROJECT_PATH:
		return method == BRIDGE_HTTP_METHOD_POST
	}
	return false
}

BRIDGE_ERROR_UNSUPPORTED_ROUTE :: "unsupported_route"

// ---- bridge<->hub runtime WS chunking (LIVE star channel) ----------------
// The bridge<->hub runtime WS channel transparently chunks large frames into
// ordered kind:"chunk" frames that the hub reassembles by chunk_id. These
// constants are shared by the bridge chunker (bridge_hub_chunk_frames) and the
// hub's reassembler; they are NOT part of the removed direct-peer transport.
BRIDGE_WS_FRAME_KIND_CHUNK :: "chunk"

BRIDGE_WS_DEFAULT_CHUNK_BYTES :: 65536

// Safety bounds for the hub-side chunk reassembler (src/hub bridge_handlers.odin)
// that rebuilds large bridge->hub runtime frames: cap concurrent reassemblies,
// total reassembled bytes per stream, and per-message chunk count so a malformed
// or hostile chunk stream cannot exhaust hub memory. Shared here because the
// bridge chunker and the hub reassembler must agree on the same limits.
BRIDGE_WS_MAX_REASSEMBLIES :: 64
BRIDGE_WS_MAX_REASSEMBLY_BYTES :: 16 * 1024 * 1024
BRIDGE_WS_MAX_CHUNK_COUNT :: 4096
// Raw bytes per chunk on the bridge<->hub RUNTIME channel. That connection
// traverses the edge proxy (nginx -> Caddy) which enforces a ~16 KiB PER-MESSAGE
// WS cap: a single frame at/above it is silently dropped in transit (the >16KB fs
// read timeout). This is far smaller than the cap above because the wire frame is
// base64(fragment) (~1.37x) + the JSON wrapper, so a 6000-byte raw slice yields a
// ~8.2 KiB frame — safely under the proxy cap with margin.
BRIDGE_WS_HUB_RUNTIME_CHUNK_PAYLOAD_BYTES :: 6000
// Raw bytes per hub-runtime chunk when the bridge->hub TLS transport is socat
// (HAM_TLS_BACKEND=socat, the default; selected at runtime by
// bridge_hub_runtime_chunk_payload_bytes). socat is a full-duplex relay that does
// NOT tear down on multi-read bursts, so the ~16 KB s_client ceiling above no
// longer applies. This is raised to 45000: a 45000-byte raw slice base64s to
// ~60000 chars which, plus the JSON wrapper, stays under the 65535-byte
// single-WS-frame limit enforced by ws.send_text. Larger chunks mean far fewer
// frames per large FS read/artifact, cutting framing overhead. The legacy
// s_client fallback keeps the 6000 cap above. NOTE: a prod deployment behind the
// nginx->Caddy edge proxy still has that hop's own per-message WS ceiling; lifting
// it there is a separate, explicit rollout step (this constant governs the
// bridge's own framing).
BRIDGE_WS_HUB_RUNTIME_CHUNK_PAYLOAD_BYTES_SOCAT :: 45000

// ---- hub->bridge command chunking (REQ-SHELL-36) -------------------------
// Raw bytes per chunk in the OPPOSITE direction: the hub splitting an oversized
// command frame for the bridge to reassemble. Deliberately the CONSERVATIVE 6000
// and NOT the 45000 socat value above, for a reason that is about who knows what
// rather than about the wire:
//
//   The socat figure is selected by the BRIDGE, at runtime, from its own
//   HAM_TLS_BACKEND env (bridge_hub_runtime_chunk_payload_bytes). The hub cannot
//   observe that variable — it lives in a different process on a different host.
//   A transport must not size its frames from a value only its peer can read, so
//   the hub takes the figure that is safe on BOTH transports and on the
//   nginx->Caddy edge hop.
//
// The cost is stated rather than hidden: 6000 raw base64s to ~8000 chars which,
// plus the chunk JSON wrapper, is a ~8.2 KiB frame — so a 1 MB LSP didOpen becomes
// roughly 175 frames instead of roughly 24. That is the price of not guessing at
// the peer's configuration, and it is the right trade: an over-large guess is not
// slow, it is SILENTLY DROPPED (this whole defect), while an over-small one is
// merely more frames on an ordered connection.
BRIDGE_WS_HUB_TO_BRIDGE_CHUNK_PAYLOAD_BYTES :: 6000
BRIDGE_WS_LARGE_PAYLOAD_TARGET_BYTES :: 10 * 1024 * 1024
