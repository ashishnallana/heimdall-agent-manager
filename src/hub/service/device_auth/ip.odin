// Trusted-X-Forwarded-For client-IP resolver (ELDA-6).
//
// resolve_client_ip determines the real client IP for a request:
//   - If the TCP peer (remote_addr) is inside a forwarded-for trusted CIDR
//     (--forwarded-for-trusted-cidr), the request arrived via the reverse
//     proxy, so we trust X-Forwarded-For and
//     take its FIRST hop (the original client). This is how the dev proxy and
//     any configured outpost deliver the true client IP.
//   - Otherwise the TCP peer IS the client; X-Forwarded-For is attacker-
//     controlled and MUST be ignored (spoofing protection — AC4).
//
// CIDR matching reuses auth_service.remote_addr_trusted / strip_port. This list
// has no authentication meaning; it only decides whose X-Forwarded-For to trust.

package device_auth

import "core:strings"
import auth_service "odin_test:hub/service/auth"

// resolve_client_ip returns the effective client IP for rate-limiting and grant
// attribution. `remote_addr` is the TCP peer ("host:port" or "host");
// `xff_header` is the raw X-Forwarded-For header value (may be empty);
// `trusted_cidrs` is the configured forwarded-for trusted CIDR list.
//
// Behind a trusted proxy the answer is the RIGHT-MOST X-Forwarded-For hop that
// is not itself a trusted proxy: every hop to its right was appended by a proxy
// we trust, while anything to its left was supplied by the client and can be
// forged (a client choosing its own "IP" would defeat per-IP rate limits).
resolve_client_ip :: proc(remote_addr, xff_header: string, trusted_cidrs: []string) -> string {
	if remote_addr == "" do return ""
	// Only consult XFF when the TCP peer is itself a trusted proxy.
	if auth_service.remote_addr_trusted(remote_addr, trusted_cidrs) {
		if hop := rightmost_untrusted_xff_hop(xff_header, trusted_cidrs); hop != "" do return hop
	}
	// Untrusted peer (or no XFF): the peer is the client. Strip the port.
	return auth_service.strip_port(remote_addr)
}

// rightmost_untrusted_xff_hop walks X-Forwarded-For ("client, proxy1, proxy2")
// from the right and returns the first hop outside the trusted CIDRs. When
// every hop is a trusted proxy, the left-most hop is returned. "" for an empty
// header.
rightmost_untrusted_xff_hop :: proc(xff_header: string, trusted_cidrs: []string) -> string {
	trimmed := strings.trim_space(xff_header)
	if trimmed == "" do return ""
	hops := strings.split(trimmed, ",", context.temp_allocator)
	leftmost := ""
	for i := len(hops) - 1; i >= 0; i -= 1 {
		hop := strings.trim_space(hops[i])
		if hop == "" do continue
		leftmost = hop
		if !auth_service.remote_addr_trusted(hop, trusted_cidrs) do return hop
	}
	return leftmost
}
