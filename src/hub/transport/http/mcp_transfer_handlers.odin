package http

// ── E2EE artifact transfer data path (docs/plans/mcp-large-artifact-transfers.md §5.2) ──
//
// /api/v1/mcp/transfers/{id}[/ciphertext|/seal|/opened]. Bodies are CIPHERTEXT of one
// vault v2 token (never parsed as JSON) or small seal/open receipt JSON. Nothing here
// holds a key: the handlers only move ciphertext between the client and
// mcp.Transfer_Service. Authentication is a per-transfer bearer token (hxt_…); there is
// no ?t= query token and no unauthenticated link. OAuth MCP access tokens are refused.

import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import mcp "odin_test:hub/service/mcp"

MCP_TRANSFERS_PATH :: MCP_PATH + "/transfers"

MCP_Transfer_Handlers :: struct {
	svc: ^mcp.Transfer_Service,
	// grant_live reports whether the transfer's grant/family/account is still live
	// (revocation fails every data-path request with 401 and wipes staging, §9).
	grant_live: proc(ctx: rawptr, x: domain.Mcp_Transfer) -> bool,
	grant_ctx:  rawptr,
	// delegation enables the browser executor's auth (§5.2): the native same-origin
	// session plus an approved-device v2 request proof. nil = bearer hxt_ only.
	delegation: ^MCP_Delegation_Handlers,
}

// xfr_browser_owner authenticates a browser executor request: a Hub session (never
// OIDC or an MCP bearer), same Origin for every non-GET/HEAD method, and a v2 request
// proof from an APPROVED device of that user. Returns the owner whose transfers it may
// reach; ownership itself is checked by transfer_get_owned (foreign -> 404).
@(private = "file")
xfr_browser_owner :: proc(h: ^MCP_Transfer_Handlers, req: Request) -> (string, bool, Response) {
	d := h.delegation
	principal, ok, _ := require_auth(d.auth, req)
	if !ok || principal.kind != .Session do return "", false, xfr_error(401, "unauthenticated")
	if req.method != "GET" && req.method != "HEAD" && header_value(req.headers, "Origin") != d.origin do return "", false, xfr_error(403, "origin_required")
	vh := Vault_Directory_Handlers{auth = d.auth, vault = d.directory}
	if _, err := vault_request_signer(&vh, principal, req, .Approved); err.code != .None do return "", false, xfr_error(401, "device_proof_required")
	return principal.user_id, true, {}
}

// mcp_transfer_pre_body is the server's pre-body gate for transfer routes (§7): the
// declared Content-Length is bounded per method BEFORE the body is read (413), and a
// data-path request (PUT/PATCH/GET .../ciphertext) takes its global slot BEFORE the
// body is read (503 + Retry-After when full). Only admitted requests are buffered, so
// in-flight transfer bodies are bounded by slots x per-method bound. A missing
// Content-Length counts as 0 (the reader then stops at the header terminator).
mcp_transfer_pre_body :: proc(ctx: rawptr, method, path: string, content_length: int) -> Pre_Body_Verdict {
	h := (^MCP_Transfer_Handlers)(ctx)
	if h == nil || h.svc == nil || !strings.has_prefix(path, MCP_TRANSFERS_PATH + "/") do return {}
	is_ciphertext := strings.has_suffix(path, "/ciphertext")
	bound := TRANSFER_JSON_MAX_BYTES
	if is_ciphertext && method == "PUT" do bound = TRANSFER_PUT_MAX_BYTES
	else if is_ciphertext && method == "PATCH" do bound = TRANSFER_PATCH_MAX_BYTES
	else if method == "GET" || method == "HEAD" || method == "DELETE" do bound = 0
	if content_length < 0 || content_length > bound {
		return {status = 413, body = `{"error":"body_too_large"}`, headers = xfr_headers()}
	}
	if is_ciphertext && (method == "PUT" || method == "PATCH" || method == "GET") {
		if !mcp.transfer_data_path_acquire(h.svc) {
			b := busy_response()
			return {status = b.status, body = b.body, headers = b.headers}
		}
		return {held = true}
	}
	return {}
}

mcp_transfer_pre_body_release :: proc(ctx: rawptr) {
	h := (^MCP_Transfer_Handlers)(ctx)
	if h != nil && h.svc != nil do mcp.transfer_data_path_release(h.svc)
}

mcp_transfer_register_routes :: proc(r: ^Router, h: ^MCP_Transfer_Handlers) {
	router_add(r, "ANY", MCP_TRANSFERS_PATH + "/**", h, mcp_transfer_handler)
}

@(private = "file")
xfr_headers :: proc(extra: ..contracts.HTTP_Header) -> []contracts.HTTP_Header {
	out := make([dynamic]contracts.HTTP_Header, context.temp_allocator)
	append(&out, contracts.HTTP_Header{"Cache-Control", "no-store"}, contracts.HTTP_Header{"X-Content-Type-Options", "nosniff"}, contracts.HTTP_Header{"Referrer-Policy", "no-referrer"})
	for e in extra do append(&out, e)
	return out[:]
}

@(private = "file")
xfr_json :: proc(status: int, value: $T, extra: ..contracts.HTTP_Header) -> Response {
	body, _ := json.marshal(value, allocator = context.temp_allocator)
	return Response{status = status, content_type = "application/json", body = string(body), headers = xfr_headers(..extra)}
}

@(private = "file")
xfr_error :: proc(status: int, reason: string, extra: ..contracts.HTTP_Header) -> Response {
	return xfr_json(status, struct {error: string}{reason}, ..extra)
}

@(private = "file")
fail_response :: proc(f: mcp.Transfer_Fail) -> Response {
	#partial switch f.code {
	case .Unauthenticated: return xfr_error(401, f.reason)
	case .Not_Found:       return xfr_error(404, "not_found")
	case .Gone:            return xfr_error(410, f.reason)
	case .Conflict:
		if f.reason == "offset_mismatch" {
			return xfr_json(409, struct {error: string, offset: i64}{f.reason, f.offset}, contracts.HTTP_Header{"Upload-Offset", fmt.tprintf("%d", f.offset)})
		}
		return xfr_error(409, f.reason)
	case .Rate_Limited:
		if f.reason == "busy" do return busy_response()
		return xfr_json(429, struct {error: string, retry_after_ms: int}{f.reason, f.retry_after_ms}, contracts.HTTP_Header{"Retry-After", "2"})
	case .Validation_Failed: return xfr_error(422, f.reason)
	}
	return xfr_error(500, "internal")
}

@(private = "file")
busy_response :: proc() -> Response {
	return xfr_json(503, struct {error: string, retry_after_ms: int}{"busy", contracts.ARTIFACT_TRANSFER_RETRY_AFTER_MS}, contracts.HTTP_Header{"Retry-After", "2"})
}

@(private = "file")
bearer_token :: proc(req: Request) -> string {
	auth := header_value(req.headers, "Authorization")
	if len(auth) < 7 || !strings.equal_fold(auth[:7], "Bearer ") do return ""
	return strings.trim_space(auth[7:])
}

@(private = "file")
repr_digest :: proc(sha_hex: string) -> string {
	raw, ok := hex.decode(transmute([]byte)sha_hex, context.temp_allocator)
	if !ok || len(raw) != 32 do return ""
	enc, _ := base64.encode(raw, allocator = context.temp_allocator)
	return fmt.tprintf("sha-256=:%s:", enc)
}

Transfer_Descriptor :: struct {
	transfer_id, direction, artifact_id, owner_user_id, vault_id: string,
	current_epoch: i64,
	kind, content_type, ext, state: string,
	received_bytes, ciphertext_bytes: i64,
	ciphertext_sha256: string,
	receipt_present: bool,
	receipt, receipt_signature, receipt_device_id, attestation_token: string,
	limits: struct {plaintext_max_bytes, ciphertext_max_bytes, chunk_max_bytes: int},
	expires_at: string,
}

@(private = "file")
descriptor :: proc(h: ^MCP_Transfer_Handlers, x: domain.Mcp_Transfer) -> Transfer_Descriptor {
	d := Transfer_Descriptor{transfer_id = x.transfer_id, direction = x.direction, artifact_id = x.artifact_id, owner_user_id = x.owner_user_id,
		vault_id = x.vault_id, current_epoch = x.epoch, kind = x.kind, content_type = x.content_type, ext = x.ext, state = x.state,
		received_bytes = x.received_bytes, ciphertext_bytes = x.ciphertext_bytes, ciphertext_sha256 = x.ciphertext_sha256, expires_at = x.expires_at}
	d.limits = {contracts.ARTIFACT_MAX_CONTENT_BYTES, contracts.ARTIFACT_TRANSFER_CIPHERTEXT_MAX_BYTES, contracts.ARTIFACT_TRANSFER_CHUNK_MAX_BYTES}
	if x.direction == domain.MCP_TRANSFER_DOWNLOAD {
		// Untrusted hint for the executor (§5.3 receipt policy): it verifies itself.
		st, sig, dev, att, _, found, _ := h.svc.repo.get_receipt(h.svc.repo.ctx, x.artifact_id, x.owner_user_id)
		if found do d.receipt_present, d.receipt, d.receipt_signature, d.receipt_device_id, d.attestation_token = true, st, sig, dev, att
	}
	return d
}

// parse_single_range accepts exactly "bytes=a-b", "bytes=a-" or "bytes=-n".
@(private = "file")
parse_single_range :: proc(v: string, total: i64) -> (start, end: i64, ok: bool) {
	if !strings.has_prefix(v, "bytes=") || strings.contains(v, ",") || total <= 0 do return 0, 0, false
	spec := v[len("bytes="):]
	dash := strings.index_byte(spec, '-')
	if dash < 0 do return 0, 0, false
	a, b := spec[:dash], spec[dash + 1:]
	if a == "" {
		n, nok := strconv.parse_i64(b)
		if !nok || n <= 0 do return 0, 0, false
		return max(total - n, 0), total - 1, true
	}
	s, sok := strconv.parse_i64(a)
	if !sok || s < 0 || s >= total do return 0, 0, false
	if b == "" do return s, total - 1, true
	e, eok := strconv.parse_i64(b)
	if !eok || e < s do return 0, 0, false
	return s, min(e, total - 1), true
}

mcp_transfer_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^MCP_Transfer_Handlers)(ctx)
	if h == nil || h.svc == nil do return xfr_error(503, "unavailable")
	// No token in the URL, ever.
	if req.query != "" do return xfr_error(400, "query_not_allowed")
	rest := strings.trim_prefix(req.path, MCP_TRANSFERS_PATH + "/")
	parts := strings.split(rest, "/", context.temp_allocator)
	if len(parts) < 1 || len(parts) > 2 || len(parts[0]) == 0 || len(parts[0]) > 64 do return xfr_error(404, "not_found")
	id := parts[0]
	sub := len(parts) == 2 ? parts[1] : ""
	// Either a per-transfer bearer (shell executor) or, with NO Authorization header,
	// the browser session + device proof. Any other bearer (OAuth MCP, OIDC) is 401.
	token := bearer_token(req)
	browser_owner := ""
	if header_value(req.headers, "Authorization") == "" && h.delegation != nil {
		owner, bok, bresp := xfr_browser_owner(h, req)
		if !bok do return bresp
		browser_owner = owner
	} else if !strings.has_prefix(token, mcp.TRANSFER_TOKEN_PREFIX) {
		return xfr_error(401, "unauthenticated")
	}

	is_data := sub == "ciphertext" && (req.method == "PUT" || req.method == "PATCH" || req.method == "GET")
	// Global data-path admission before touching SQLite (§7). In the server this
	// already happened before the body was read (mcp_transfer_pre_body); direct
	// dispatch (tests, other transports) acquires here.
	acquired := false
	if is_data && !req.admitted {
		if !mcp.transfer_data_path_acquire(h.svc) do return busy_response()
		acquired = true
	}
	defer if acquired do mcp.transfer_data_path_release(h.svc)

	x: domain.Mcp_Transfer
	af: mcp.Transfer_Fail
	if browser_owner != "" do x, af = mcp.transfer_get_owned(h.svc, browser_owner, id)
	else do x, af = mcp.transfer_authenticate(h.svc, token, id)
	if !mcp.transfer_ok(af) do return fail_response(af)
	if h.grant_live != nil && !h.grant_live(h.grant_ctx, x) {
		mcp.transfer_fail_for_revocation(h.svc, x)
		return xfr_error(401, "revoked")
	}
	// Per-grant data-path rate limit (429 + Retry-After) applies before the work.
	if !mcp.transfer_rate_allow(h.svc, x.grant_id, false) do return fail_response(mcp.rate_limited())

	switch {
	case sub == "" && req.method == "GET":
		return xfr_json(200, descriptor(h, x))
	case sub == "" && req.method == "DELETE":
		y, f := mcp.transfer_cancel(h.svc, x)
		if !mcp.transfer_ok(f) do return fail_response(f)
		return xfr_json(200, struct {state: string}{y.state})
	case sub == "ciphertext" && req.method == "HEAD":
		if x.direction == domain.MCP_TRANSFER_UPLOAD {
			return Response{status = 200, content_type = "application/octet-stream", headers = xfr_headers(contracts.HTTP_Header{"Upload-Offset", fmt.tprintf("%d", x.received_bytes)})}
		}
		return Response{status = 200, content_type = "application/octet-stream", headers = xfr_headers(
			contracts.HTTP_Header{"Accept-Ranges", "bytes"}, contracts.HTTP_Header{"Repr-Digest", repr_digest(x.ciphertext_sha256)},
			contracts.HTTP_Header{"X-Ciphertext-Length", fmt.tprintf("%d", x.ciphertext_bytes)})}
	case sub == "ciphertext" && req.method == "PUT":
		if x.direction != domain.MCP_TRANSFER_UPLOAD do return xfr_error(405, "wrong_direction")
		if x.received_bytes != 0 do return fail_response({code = .Conflict, reason = "offset_mismatch", offset = x.received_bytes})
		if len(req.body) > TRANSFER_PUT_MAX_BYTES do return xfr_error(413, "ciphertext_too_large")
		n, f := mcp.transfer_append(h.svc, x, 0, transmute([]byte)req.body)
		if !mcp.transfer_ok(f) do return fail_response(f)
		return xfr_json(200, struct {received_bytes: i64}{n}, contracts.HTTP_Header{"Upload-Offset", fmt.tprintf("%d", n)})
	case sub == "ciphertext" && req.method == "PATCH":
		if x.direction != domain.MCP_TRANSFER_UPLOAD do return xfr_error(405, "wrong_direction")
		if len(req.body) == 0 || len(req.body) > TRANSFER_PATCH_MAX_BYTES do return xfr_error(413, "chunk_size")
		off, ook := strconv.parse_i64(header_value(req.headers, "Upload-Offset"))
		if !ook || off < 0 do return xfr_error(400, "upload_offset_required")
		n, f := mcp.transfer_append(h.svc, x, off, transmute([]byte)req.body)
		if !mcp.transfer_ok(f) do return fail_response(f)
		return xfr_json(200, struct {received_bytes: i64}{n}, contracts.HTTP_Header{"Upload-Offset", fmt.tprintf("%d", n)})
	case sub == "ciphertext" && req.method == "GET":
		if x.direction != domain.MCP_TRANSFER_DOWNLOAD do return xfr_error(405, "wrong_direction")
		start, end := i64(0), x.ciphertext_bytes - 1
		status := 200
		if rv := header_value(req.headers, "Range"); rv != "" {
			s, e, rok := parse_single_range(rv, x.ciphertext_bytes)
			if !rok do return xfr_error(416, "range_not_satisfiable", contracts.HTTP_Header{"Content-Range", fmt.tprintf("bytes */%d", x.ciphertext_bytes)})
			start, end, status = s, e, 206
		}
		// Design §7: one response is at most one 1 MiB window, so a data-path slot
		// holds <= 1 MiB of response body. Larger requests get a 206 for the first
		// window; clients continue with Range from Content-Range's end + 1.
		if end - start + 1 > TRANSFER_GET_WINDOW_BYTES {
			end = start + TRANSFER_GET_WINDOW_BYTES - 1
			status = 206
		}
		if !mcp.transfer_owner_get_acquire(h.svc, x.owner_user_id) do return fail_response(mcp.rate_limited())
		defer mcp.transfer_owner_get_release(h.svc, x.owner_user_id)
		if f := mcp.transfer_fetch_begin(h.svc, x, start == 0); !mcp.transfer_ok(f) do return fail_response(f)
		// One <= 1 MiB substr() window; never a full-value SQLite copy.
		body := make([]byte, int(end - start + 1), context.temp_allocator)
		pos := 0
		for pos < len(body) {
			n, f := mcp.transfer_read_window(h.svc, x, start + i64(pos), body[pos:])
			if !mcp.transfer_ok(f) do return fail_response(f)
			if n == 0 do return xfr_error(500, "internal")
			pos += n
		}
		hdrs := xfr_headers(contracts.HTTP_Header{"Content-Disposition", "attachment"}, contracts.HTTP_Header{"Accept-Ranges", "bytes"},
			contracts.HTTP_Header{"Repr-Digest", repr_digest(x.ciphertext_sha256)})
		if status == 206 {
			extra := make([dynamic]contracts.HTTP_Header, context.temp_allocator)
			append(&extra, ..hdrs)
			append(&extra, contracts.HTTP_Header{"Content-Range", fmt.tprintf("bytes %d-%d/%d", start, end, x.ciphertext_bytes)})
			hdrs = extra[:]
		}
		return Response{status = status, content_type = "application/octet-stream", body = string(body), headers = hdrs}
	case sub == "seal" && req.method == "POST":
		if len(req.body) > TRANSFER_JSON_MAX_BYTES do return xfr_error(413, "body_too_large")
		in_: struct {receipt, signature, device_id, name_token, description_token, attestation_token: string}
		if err := json.unmarshal_string(req.body, &in_, allocator = context.temp_allocator); err != nil do return xfr_error(400, "invalid_json")
		y, f := mcp.transfer_seal(h.svc, x, {receipt = in_.receipt, signature = in_.signature, device_id = in_.device_id,
			name_token = in_.name_token, description_token = in_.description_token, attestation_token = in_.attestation_token})
		if !mcp.transfer_ok(f) do return fail_response(f)
		return xfr_json(200, struct {transfer_id, artifact_id, state, ciphertext_sha256: string}{y.transfer_id, y.artifact_id, y.state, y.ciphertext_sha256})
	case sub == "opened" && req.method == "POST":
		if len(req.body) > TRANSFER_JSON_MAX_BYTES do return xfr_error(413, "body_too_large")
		in_: struct {receipt, signature, device_id: string}
		if err := json.unmarshal_string(req.body, &in_, allocator = context.temp_allocator); err != nil do return xfr_error(400, "invalid_json")
		y, f := mcp.transfer_opened(h.svc, x, in_.receipt, in_.signature, in_.device_id)
		if !mcp.transfer_ok(f) do return fail_response(f)
		return xfr_json(200, struct {state: string, verified: bool}{y.state, y.open_verified})
	}
	return xfr_error(405, "method_not_allowed")
}
