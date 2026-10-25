package http

import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import auth_service "odin_test:hub/service/auth"
import vd "odin_test:hub/service/vault_directory"

request_signature_target :: proc(req: Request) -> string {
	if req.raw_target != "" do return req.raw_target
	if req.query != "" do return strings.concatenate({req.path, "?", req.query}, context.temp_allocator)
	return req.path
}

// This runs after bearer resolution in every user authentication middleware.
// The allowlist is exact in both method and path; everything else fails closed.
oidc_device_gate :: proc(
	auth: ^auth_service.Auth_Service,
	ctx: contracts.Auth_Context,
	req: Request,
) -> (
	contracts.Auth_Context,
	bool,
	Response,
) {
	if ctx.kind != .OIDC do return ctx, true, {}
	proof := signed_request(req)
	supplied := vd.has_signature_headers(proof)
	for header in req.headers {
		if strings.has_prefix(strings.to_lower(header.name, context.temp_allocator), "x-heimdall-device-") do supplied = true
	}
	me := req.method == "GET" && req.path == "/api/v1/me"
	directory := req.method == "GET" && req.path == "/api/v1/vault/directory"
	bootstrap :=
		req.method == "POST" &&
		(req.path == "/api/v1/vault/directory/genesis" ||
				req.path == "/api/v1/vault/devices/register")
	if !supplied && (me || directory || bootstrap) do return ctx, true, {}
	fail := domain.domain_error(.Unauthenticated, "v2 device request signature required")
	if auth == nil || auth.vault == nil || proof.version != "2" do return {}, false, respond_error(fail, req.request_id)
	// Repeated headers are ambiguous across HTTP stacks; accept each field once.
	for name in ([]string {
			"X-Heimdall-Device-Sig-Version",
			"X-Heimdall-Device-Id",
			"X-Heimdall-Device-Ts",
			"X-Heimdall-Device-Nonce",
			"X-Heimdall-Device-Sig",
		}) {
		count := 0
		for header in req.headers {if strings.equal_fold(header.name, name) do count += 1}
		if count != 1 do return {}, false, respond_error(fail, req.request_id)
	}
	need := vd.Signer_Requirement.Approved
	if req.method == "GET" && req.path == "/api/v1/vault/devices/self" do need = .Self
	if directory {
		// A brand-new key cannot authenticate yet. Known keys must prove possession,
		// including pending/revoked devices. A bearer alone can always read this route.
		devices, err := iface.vault_list_devices(auth.vault.repo, ctx.user_id)
		if err.code != .None do return {}, false, respond_error(err, req.request_id)
		found := false
		for device in devices {if device.device_id == proof.device_id do found = true}
		if !found do return ctx, true, {}
		need = .Self
	}
	device, err := vd.verify_request(auth.vault, ctx.user_id, proof, need)
	if err.code != .None do return {}, false, respond_error(err, req.request_id)
	verified := ctx
	verified.device_id = device.device_id
	return verified, true, {}
}

// The middleware already consumed the v2 nonce. Reuse its verified signer rather
// than verifying twice; re-read ownership/status for the handler's stronger policy.
vault_request_signer :: proc(
	h: ^Vault_Directory_Handlers,
	auth: contracts.Auth_Context,
	req: Request,
	need: vd.Signer_Requirement,
) -> (
	domain.Vault_Device,
	domain.Domain_Error,
) {
	if auth.kind != .OIDC do return vd.verify_request(h.vault, auth.user_id, signed_request(req), need)
	if auth.device_id == "" do return {}, domain.domain_error(.Unauthenticated, "verified device required")
	devices, err := iface.vault_list_devices(h.vault.repo, auth.user_id)
	if err.code != .None do return {}, err
	for device in devices {
		if device.device_id != auth.device_id do continue
		if need == .Approver && (device.status != .Approved || !domain.vault_kind_policy(device.kind).can_approve) do return {}, domain.domain_error(.Forbidden, "approved approver required")
		return device, {}
	}
	return {}, domain.domain_error(.Forbidden, "device is not owned by this user")
}
