package main

// Bridge -> hub HTTP helpers over src/lib/httpc. Every outbound request is an
// httpc.Request: the hub base URL parsed by libcurl, path segments, query
// params, validated headers and a typed body. Nothing here formats a URL,
// header line or body by hand.

import httpc "odin_test:lib/httpc"

// Bridge_Hub_Fetch is the injectable hub transport (tests script it). The
// production value is bridge_hub_http_send.
Bridge_Hub_Fetch :: #type proc(req: httpc.Request) -> (httpc.Response, httpc.Error)

// bridge_hub_http_send performs one request; the response is heap-allocated
// (context.allocator) and must be released with httpc.response_destroy.
bridge_hub_http_send :: proc(req: httpc.Request) -> (httpc.Response, httpc.Error) {
	return httpc.send(req)
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
