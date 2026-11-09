package main

// Bridge -> hub HTTP helpers over src/lib/httpc. Every outbound request is an
// httpc.Request: the hub base URL parsed by libcurl, path segments, query
// params, validated headers and a typed body. Nothing here formats a URL,
// header line or body by hand.

import httpc "odin_test:lib/httpc"
import contracts "odin_test:contracts"
import "core:strings"
import "core:sync"

// Bridge_Hub_Fetch is the injectable hub transport (tests script it). The
// production value is bridge_hub_http_send.
Bridge_Hub_Fetch :: #type proc(req: httpc.Request) -> (httpc.Response, httpc.Error)

// bridge_hub_http_send performs one request; the response is heap-allocated
// (context.allocator) and must be released with httpc.response_destroy.
bridge_hub_http_send :: proc(req: httpc.Request) -> (httpc.Response, httpc.Error) {
	return bridge_hub_http_send_alloc(req)
}

bridge_hub_http_send_alloc :: proc(req: httpc.Request, allocator := context.allocator) -> (httpc.Response, httpc.Error) {
    context.allocator = allocator
    return bridge_hub_http_send_using(req)
}

bridge_hub_http_raw :: proc(req: httpc.Request) -> (httpc.Response, httpc.Error) {
    return httpc.send(req)
}

bridge_hub_http_send_using :: proc(req: httpc.Request, fetch: Bridge_Hub_Fetch = bridge_hub_http_raw) -> (httpc.Response, httpc.Error) {
    // Admission boundary: requests already admitted may complete after a pause.
    // No later request (including retries and refreshes) reaches libcurl.
    if sync.atomic_load(&bridge_hub_traffic_stopped) do return {}, .Aborted
    // A parked credential owner (credential_state.odin) admits no new request.
    if bridge_credential_traffic_blocked() do return {}, .Aborted
    resp, err := fetch(req)
    if err == .None && resp.status >= 400 {
        wire := bridge_operation_http_error(resp, true)
        if wire.cause == "bridge_sunset_pending" do bridge_hub_stop_traffic(false)
        if wire.cause == "bridge_credential_revoked" do bridge_hub_stop_traffic(true)
        if resp.status == 401 do bridge_hub_http_note_auth_rejection(req, wire)
    }
    return resp, err
}

// bridge_hub_http_note_auth_rejection (D3): a typed expired-access 401 asks for at
// most one renewal of the generation that was presented. A request that presented
// an older credential than the current one spends nothing. A bare 401 (no typed
// Hub body) never triggers a renewal.
bridge_hub_http_note_auth_rejection :: proc(req: httpc.Request, wire: contracts.Wire_Error) {
    if wire.code != .Unauthenticated do return
    expired := wire.cause == "bridge_token_expired" || wire.message == BRIDGE_HUB_ACCESS_EXPIRED_MESSAGE
    if !expired do return
    presented := ""
    for h in req.headers {
        if strings.equal_fold(h.name, "Authorization") && strings.has_prefix(h.value, "Bearer ") {
            presented = strings.trim_space(h.value[len("Bearer "):])
        }
    }
    if presented == "" do return
    current, generation := bridge_credential_peek(context.temp_allocator)
    if presented != current do return // an older credential: the caller retries with the current one
    _ = bridge_credential_note_rejection(generation, .Access_Expired)
}

// bridge_hub_url parses a hub base URL (default: the configured hub) with
// libcurl. An invalid URL yields the zero Url, which httpc.send rejects with
// .Invalid_Url before any I/O.
bridge_hub_url :: proc(raw := "") -> httpc.Url {
	text := raw if raw != "" else bridge_config.daemon_url
	u, _ := httpc.parse_url(text)
	return u
}

// bridge_deadline_ms maps a remaining operation budget to an httpc timeout. A
// spent budget (<= 0) must fail immediately without I/O, never fall back to
// httpc's default timeout, so it becomes -1 (httpc: .Timeout, may_have_sent
// false).
bridge_deadline_ms :: proc(remaining_ms: int) -> int {
	return remaining_ms if remaining_ms > 0 else -1
}
