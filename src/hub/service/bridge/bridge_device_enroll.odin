// Bridge enrollment via the device-authorization grant (REQ-IMPL-2).
//
// This is the mint side of the browser-approval flow. The Hub's existing RFC
// 8628 device grant (src/hub/service/device_auth/) now accepts a bridge public
// key at /device/authorize; when a signed-in human approves that grant, this
// proc creates the machine's identity.
//
// WHAT MAKES THIS DIFFERENT FROM THE PRE-EXISTING DEVICE MINTER, and why the
// difference is the whole point: the Electron path mints a USER API token whose
// only identity is owner_user_id, with the machine carried as a free-text label
// (src/hub/app/wiring.odin device_minter -> issue_device_authorization_token).
// Two bridges owned by one user therefore hold tokens that are
// indistinguishable in authority, and nothing stops one from acting for the
// other. A credential minted here resolves to exactly one `brg_` through
// verify_bridge_token (bridge_service.odin), and resolve_bridge_instance_auth
// then rejects any attempt to act for an instance that bridge does not own
// (src/hub/service/auth/auth_service.odin "bridge cannot act for an instance it
// does not own"). That per-machine scoping is what the user approved, so it is
// what the credential must carry.
//
// THERE IS NO ENROLLMENT TOKEN ANYWHERE ANY MORE. The deleted `enroll_bridge()`
// consumed a pre-shared secret a human had to carry to the machine; this path
// replaces that secret with a human's approval in a browser, so there is nothing
// to carry and nothing to leak in transit. REQ-IMPL-6 deleted the one-time-token
// flow outright, which makes this the ONLY way a bridge is enrolled.
//
// Lives in its own file rather than in bridge_service.odin so REQ-IMPL-1 could
// replace the credential machinery underneath it without a merge conflict. That
// has now landed: the old unsalted `hash_token` placeholder is DELETED, and this
// proc mints through `issue_credential` (bridge_credential.odin) — a 256-bit
// CSPRNG secret, stored as `sha256:v1:<salt_hex>:<digest_hex>`. Nothing on this
// path may derive a secret from `platform.generate_id`, which is
// prefix + unix-nanoseconds and therefore enumerable from the enrollment time;
// `generate_id` is used here ONLY for the non-secret `brg_` id.

package bridge

import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// Device_Enroll_Input is the approved grant's content, as forwarded by the
// device_auth service's bridge minter.
//
// owner_user_id MUST come from the approving user's Auth_Context. The device
// grant binds it there (device_auth.approve takes it as an argument and never
// reads it from the request body) and this proc refuses an empty one, so an
// unauthenticated approval cannot produce an owned bridge.
Device_Enroll_Input :: struct {
	owner_user_id:          string,
	bridge_public_key:      string, // host-asserted, confirmed by the approving human
	bridge_key_fingerprint: string, // hub-computed from the key above
	os_user:                string, // host-asserted
	machine_hostname:       string,
	machine_os:             string,
	bridge_version:         string,
	// target_bridge_id is the approving human's "attach to an existing bridge"
	// choice. Empty (the default) mints a new bridge, below. Non-empty routes
	// to rotate_bridge_for_device_grant instead, which re-checks ownership
	// before touching anything -- see that proc.
	target_bridge_id:       string,
	new_bridge_label:       string,
	// sunset_bridge_id is the approver's "register this machine as NEW and retire
	// that one" choice (a full plan's way to make room). It is retired in the same
	// repository transaction that creates the new row (see iface.Bridge_Sunset), so
	// the approver never ends up with the old bridge gone and no new one. Only valid
	// for a new bridge: attach (target_bridge_id) keeps the slot count unchanged, so
	// the two together are refused.
	sunset_bridge_id:       string,
	// pending is true when the approving owner has a vault (REQ-EA-1): the
	// enrollment then does not count until the hub observes the vault key reach the
	// bridge (commit_pending_enrollment). The credential is minted in
	// BRIDGE_ENROLL_TOKEN_SCOPE, a new bridge's row is marked pending, and an
	// attach leaves the target's existing credential and row untouched.
	pending:                bool,
}

// enroll_bridge_from_device_grant mints the per-machine identity + credential
// for an approved bridge-enrollment grant. Returns the saved bridge and the
// PLAINTEXT token, which the caller hands to the bridge exactly once (the grant
// is single-use). The Hub never stores that plaintext: `issue_credential` returns
// the salted digest to persist instead, and only the secret half of
// `hbr_<bridge_id>.<secret>` is hashed — the id half is the lookup key.
enroll_bridge_from_device_grant :: proc(service: ^Bridge_Service, input: Device_Enroll_Input) -> (Enroll_Bridge_Result, bool, domain.Domain_Error) {
	// Fail closed on a missing owner. Reaching here without one would mean the
	// approval path lost the Auth_Context binding, and an unowned bridge row is
	// worse than a failed enrollment: ownership is what every later
	// authorization check reads.
	owner := strings.trim_space(input.owner_user_id)
	if owner == "" {
		return Enroll_Bridge_Result{}, false, domain.domain_error(.Unauthenticated, "an approving user is required to enroll a bridge")
	}
	if input.bridge_public_key == "" {
		return Enroll_Bridge_Result{}, false, domain.domain_error(.Validation_Failed, "bridge_public_key is required")
	}
	sunset_bridge_id := strings.trim_space(input.sunset_bridge_id)
	if strings.trim_space(input.target_bridge_id) != "" {
		if sunset_bridge_id != "" {
			return Enroll_Bridge_Result{}, false, domain.domain_error(.Validation_Failed, "sunset_bridge_id is only valid when creating a new bridge")
		}
		return rotate_bridge_for_device_grant(service, owner, input)
	}
	entitlements, entitlement_err := domain.lookup_entitlements(service.entitlements, owner)
	if entitlement_err.code != .None do return {}, false, entitlement_err
	hostname := strings.trim_space(input.machine_hostname)
	if hostname == "" do hostname = "unknown-host"
	label := strings.trim_space(input.new_bridge_label)
	label_is_custom := label != ""
	if label == "" do label = hostname
	now := platform.clock_now(service.clock)
	// ===== REQ-IMPL-3: THE CREDENTIAL IS NOW AN EXPIRING PAIR =====
	// REQ-IMPL-2 left this seam with a deliberately non-expiring `hbr_` and the note
	// that REQ-IMPL-3 owns the re-shape. This is that re-shape: a device-enrolled
	// bridge receives `hba_` (1h) + `hbf_` (30d, single-use, rotated), minted by
	// issue_bridge_token_pair (bridge_token_service.odin). `bridges.bridge_token_hash`
	// is left EMPTY on this path on purpose — an empty stored hash verifies nothing
	// (verify_credential), so nothing non-expiring is created for this bridge.
	//
	// The `bridges.bridge_token_hash` column is now DEAD for authentication: it was
	// written only by the deleted one-time-token flow, and REQ-IMPL-6 removed the
	// lookup that read it. It is left in place because dropping a column is a
	// migration against existing deployments, not because anything consults it.
	//
	// ORDER: the bridge row is saved BEFORE the credential is minted, because a token
	// row references its bridge_id and a credential for a bridge that does not exist
	// is unusable. A crash between them leaves an enrolled bridge with no credential;
	// the human approves again, which is the recoverable direction.
	bridge_id := platform.generate_id(service.ids, "brg_")
	bridge := domain.Bridge{
		bridge_id = bridge_id,
		owner_user_id = domain.User_ID(owner),
		// The label starts as the machine's own hostname and is NOT marked
		// user-customized: the operator never typed it, the host asserted it, and
		// a later rename is what sets that flag (see patch_bridge/rename_bridge).
		label = label,
		label_is_user_customized = label_is_custom,
		machine_hostname = hostname,
		machine_os = input.machine_os,
		capabilities_json = device_enroll_capabilities_json(input),
		status = .Offline,
		// Deliberately empty: this bridge's credentials live in bridge_tokens.
		bridge_token_hash = "",
		version = input.bridge_version,
		created_at = now,
		updated_at = now,
		last_seen_at = now,
	}
	scope := BRIDGE_TOKEN_SCOPE
	if input.pending {
		pending_until, until_ok := platform.expires_at_after_seconds_from(now, BRIDGE_ENROLL_PENDING_SECONDS)
		if !until_ok do return Enroll_Bridge_Result{}, false, domain.domain_error(.Internal_Error, "could not derive an enrollment deadline from the hub clock")
		bridge.enrollment_pending_until = pending_until
		scope = BRIDGE_ENROLL_TOKEN_SCOPE
	}
	// The sunset (if any) is revoked inside the admission transaction, before the
	// plan count, so its slot is the one this bridge takes; a refusal anywhere in
	// that transaction leaves the sunset bridge untouched. For a pending bridge the
	// same transaction stores a durable receipt, so every later rollback of this
	// enrollment (rollback_pending_enrollment) gives the sunset bridge back.
	saved, ok, err := iface.bridge_create_limited_with_sunset(service.repo, bridge, entitlements.max_bridges, iface.Bridge_Sunset{bridge_id = sunset_bridge_id, revoked_at = now})
	if !ok {
		// The repository enforces the count atomically; add account metadata only
		// after its transaction releases the commit mutex.
		if err.code == .Plan_Limit_Reached {
			// Preserve the admission transaction's count, even if another request
			// approves or revokes a bridge before we format this response.
			details: struct {allowed, current: int}
			if json.unmarshal_string(err.details_json, &details, .JSON, context.temp_allocator) == nil {
				return {}, false, domain.entitlement_limit_error(service.entitlements, owner, "max_bridges", details.allowed, details.current)
			}
		}
		return Enroll_Bridge_Result{}, false, err
	}
	if sunset_bridge_id != "" {
		// Same last step as revoke_bridge: its credentials are already dead, so this
		// only drops a socket that can no longer authenticate anything.
		code := "bridge_sunset_pending" if input.pending else "bridge_credential_revoked"
		_ = close_bridge_connection(service, sunset_bridge_id, code)
	}
	// Fail closed when the OS entropy source is unavailable (settled 8): 503 with a
	// retry hint, never a weaker credential and never `.Internal_Error`. The bridge
	// row survives an entropy failure; the human approves again and that approval
	// mints into a new family.
	pair, pair_ok, pair_err := issue_bridge_token_pair(service, saved.bridge_id, scope)
	if !pair_ok {
		// A pending row with no credential can never be committed; remove it now
		// rather than leave it for the sweep (REQ-EA-3). The same transaction gives
		// back a bridge this approval sunset.
		if input.pending do _, _ = delete_pending_restoring_sunset(service, saved.bridge_id)
		return Enroll_Bridge_Result{}, false, pair_err
	}
	return Enroll_Bridge_Result{
		bridge = saved,
		family_id = pair.family_id,
		bridge_token = pair.access_token,
		refresh_token = pair.refresh_token,
		expires_in = pair.expires_in,
		refresh_expires_in = pair.refresh_expires_in,
	}, true, domain.Domain_Error{}
}

// rotate_bridge_for_device_grant attaches an approved device grant to an
// EXISTING bridge instead of minting a new one -- the "replace credential of
// ..." choice on the approval page, as opposed to "create a new bridge".
//
// It revokes the target's current credential family, kicks its live
// connection, and issues the NEW device a fresh credential under the SAME
// bridge_id -- so agent/telemetry history keyed on bridge_id carries over
// untouched. That's safe with no migration: migrations/057_bridge_tokens.sql
// states bridge_id carries no DB foreign key anywhere in this schema, so
// nothing needs to be moved, only the row this proc already writes.
//
// Ownership is re-checked here with get_bridge, the SAME anti-enumeration
// shape revoke_bridge uses (.Not_Found, not .Forbidden) -- a target_bridge_id
// the approving user does not own must look identical to one that does not
// exist, or this becomes an oracle for enumerating other users' bridge ids.
// get_bridge wants a contracts.Auth_Context; this flow has no HTTP request to
// take one from, so a minimal one is built from just the approved owner
// (the only field get_bridge/require_owner actually reads).
rotate_bridge_for_device_grant :: proc(service: ^Bridge_Service, owner: string, input: Device_Enroll_Input) -> (Enroll_Bridge_Result, bool, domain.Domain_Error) {
	target_bridge_id := strings.trim_space(input.target_bridge_id)
	bridge, get_ok, get_err := get_bridge(service, contracts.Auth_Context{user_id = owner}, target_bridge_id)
	if !get_ok do return Enroll_Bridge_Result{}, false, get_err
	// A revoked bridge is an administrative end (see get_bridge callers'
	// treatment elsewhere, e.g. bridge_absence_marker's "revocation is an
	// administrative end" above in bridge_service.odin), not a parking lot to
	// resurrect from. The approval page's own <select> already excludes
	// revoked bridges, but that is client-side convenience, not a boundary --
	// target_bridge_id rides in a plain JSON body, so a revoked id must be
	// refused HERE too, with the same anti-enumeration shape as the ownership
	// check just above (a revoked bridge this user does not own, and a
	// revoked bridge they do, must look identical from outside).
	if bridge.status == .Revoked {
		return Enroll_Bridge_Result{}, false, domain.domain_error(.Not_Found, "resource not found")
	}

	// REQ-EA-8: a PENDING attach changes nothing about the target yet. Its current
	// credential keeps working, its row is not rewritten and its socket is not
	// kicked; the new device only gets an enroll-scoped family under the same
	// bridge_id. commit_pending_enrollment performs the swap below once the vault
	// key has been delivered, and a rollback revokes just the new family — so a
	// failed attach leaves the existing bridge exactly as it was.
	if input.pending {
		pair, pair_ok, pair_err := issue_bridge_token_pair(service, bridge.bridge_id, BRIDGE_ENROLL_TOKEN_SCOPE)
		if !pair_ok do return Enroll_Bridge_Result{}, false, pair_err
		return Enroll_Bridge_Result{
			bridge = bridge,
			family_id = pair.family_id,
			bridge_token = pair.access_token,
			refresh_token = pair.refresh_token,
			expires_in = pair.expires_in,
			refresh_expires_in = pair.refresh_expires_in,
		}, true, domain.Domain_Error{}
	}

	now := platform.clock_now(service.clock)
	// Credentials first, same order and same reasoning as revoke_bridge
	// (bridge_service.odin): a device that reconnects in the gap between this
	// and the row flip must not be able to re-authenticate with the OLD family.
	if _, revoke_ok, revoke_err := iface.bridge_revoke_tokens_for_bridge(service.repo, target_bridge_id, now); !revoke_ok {
		return Enroll_Bridge_Result{}, false, revoke_err
	}

	hostname := strings.trim_space(input.machine_hostname)
	if hostname == "" do hostname = bridge.machine_hostname
	bridge.machine_hostname = hostname
	bridge.machine_os = input.machine_os
	bridge.capabilities_json = device_enroll_capabilities_json(input)
	bridge.version = input.bridge_version
	// Unlike revoke_bridge this does NOT set .Revoked -- the row stays alive
	// under the new device's credential, which is the entire point of
	// "attach" over "revoke and re-enroll as new".
	bridge.status = .Offline
	bridge.updated_at = now
	saved, save_ok, save_err := iface.bridge_save_bridge(service.repo, bridge)
	if !save_ok do return Enroll_Bridge_Result{}, false, save_err

	// Last, same reasoning as revoke_bridge step 3: the only step whose
	// failure is survivable, because nothing can authenticate as the old
	// family by this point regardless of whether the socket actually closes.
	_ = close_bridge_connection(service, target_bridge_id)

	pair, pair_ok, pair_err := issue_bridge_token_pair(service, saved.bridge_id)
	if !pair_ok do return Enroll_Bridge_Result{}, false, pair_err
	return Enroll_Bridge_Result{
		bridge = saved,
		bridge_token = pair.access_token,
		refresh_token = pair.refresh_token,
		expires_in = pair.expires_in,
		refresh_expires_in = pair.refresh_expires_in,
	}, true, domain.Domain_Error{}
}

// device_enroll_capabilities_json records the approved key on the bridge row,
// which is design §11.4 step 4's "bind by record": the triple
// (brg_, bridge_public_key, token_hash) is written in one place, so a later
// reader can say which machine's key the approving human actually confirmed.
//
// `public_key` is the existing key name in capabilities_json — the Hub already
// falls back to it when the live runtime registry has no entry
// (the public-key handler and write_bridge_json, src/hub/transport/http/bridge_handlers.odin), so
// GET /api/v1/bridges/<id>/public-key returns the APPROVED key from the moment
// of enrollment, before the bridge has ever connected. That precedence is the
// right way round and is deliberate: the registry value comes from the current
// bridge_hello, and the bridge's ECDH keypair is ephemeral — regenerated every
// process (src/bridge/unseal_protocol.odin) — so the live key wins for
// encryption while this one remains the record of what was approved.
//
// `enrollment_key_fingerprint` is the hub-computed fingerprint, kept alongside
// so an audit does not have to re-derive it, and `os_user` is retained as the
// host-asserted value the approver saw.
device_enroll_capabilities_json :: proc(input: Device_Enroll_Input) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"public_key\":\"")
	write_service_json_string(&b, input.bridge_public_key)
	strings.write_string(&b, "\",\"enrollment_public_key\":\"")
	write_service_json_string(&b, input.bridge_public_key)
	strings.write_string(&b, "\",\"enrollment_key_fingerprint\":\"")
	write_service_json_string(&b, input.bridge_key_fingerprint)
	strings.write_string(&b, "\",\"os_user\":\"")
	write_service_json_string(&b, input.os_user)
	strings.write_string(&b, "\",\"enrolled_via\":\"device_authorization\"}")
	return strings.to_string(b)
}
