package bridge

import "core:fmt"
import base64 "core:encoding/base64"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"
import platform "odin_test:hub/platform"
import jsonx "odin_test:lib/jsonx"
import project_service "odin_test:hub/service/project"

Bridge_Service :: struct {
	entitlements: domain.Entitlement_Lookup,
	repo: ^iface.Bridge_Repository,
	clock: ^platform.Clock,
	ids: ^platform.ID_Generator,
	bridge_command_sink: project_service.Bridge_Command_Sink,
	catalog: ^Bridge_Update_Catalog,
	provider_repo: ^iface.Provider_Repository,
	// connection_closer terminates a bridge's LIVE control WebSocket (audit F6).
	// A seam rather than a direct registry dependency for two reasons: this package
	// must not reach into the transport layer that owns the socket, and a test needs
	// to observe that revocation actually asked for the close — "the DB row says
	// revoked" is exactly the evidence F6 proves insufficient.
	//
	// May be nil (every service constructed without runtime wiring, i.e. most
	// tests). Revocation then still revokes; see revoke_bridge for why that is
	// reported rather than ignored.
	connection_closer: Bridge_Connection_Closer,
}

// Bridge_Connection_Closer closes a bridge's in-flight control connection.
//
// `ctx` is the transport's runtime registry. Returns whether a live connection was
// found and torn down — false means the bridge was not connected, which is a normal
// outcome and not an error.
Bridge_Connection_Closer :: struct {
	ctx: rawptr,
	close_bridge_connection: proc(ctx: rawptr, bridge_id: string) -> bool,
	// Production sends a typed retirement notice before waking the socket reader.
	close_with_reason: proc(ctx: rawptr, bridge_id, code: string) -> bool,
}

// with_connection_closer attaches the F6 socket teardown. Called by app wiring once
// the runtime registry exists; tests inject a fake that records the bridge_id.
with_connection_closer :: proc(service: ^Bridge_Service, closer: Bridge_Connection_Closer) {
	service.connection_closer = closer
}

// close_bridge_connection invokes the seam, or reports false when none is wired.
close_bridge_connection :: proc(service: ^Bridge_Service, bridge_id: string, code := "bridge_credential_revoked") -> bool {
	if service == nil do return false
	if bridge_id == "" do return false
	if service.connection_closer.close_with_reason != nil do return service.connection_closer.close_with_reason(service.connection_closer.ctx, bridge_id, code)
	if service.connection_closer.close_bridge_connection == nil do return false
	return service.connection_closer.close_bridge_connection(service.connection_closer.ctx, bridge_id)
}

// Enroll_Bridge_Result is what a completed enrollment hands back. There is now
// exactly ONE producer, enroll_bridge_from_device_grant (bridge_device_enroll.odin):
// REQ-IMPL-6 deleted `enroll_bridge`, the pre-shared-token path that was the other.
//
// `bridge_token` keeps its name — the wire field is `access_token` — but it is now
// always the EXPIRING half of a pair, so `refresh_token` and both lifetimes are
// always populated. They used to be zero on the deleted path, which is why every
// consumer had to treat them as optional; none of them does any more.
Enroll_Bridge_Result :: struct {
	bridge: domain.Bridge,
	// family_id is the credential lineage just minted; for a pending enrollment it is
	// what commit_pending_enrollment promotes and a rollback revokes (REQ-EA-2/3).
	family_id: string,
	bridge_token: string,
	refresh_token: string,
	expires_in: int,
	refresh_expires_in: int,
}

new_bridge_service :: proc(repo: ^iface.Bridge_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Bridge_Service {
	return Bridge_Service{repo = repo, clock = clock, ids = ids}
}

new_bridge_service_with_runtime :: proc(repo: ^iface.Bridge_Repository, bridge_command_sink: project_service.Bridge_Command_Sink, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Bridge_Service {
	return Bridge_Service{repo = repo, bridge_command_sink = bridge_command_sink, clock = clock, ids = ids}
}

list_bridges :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context) -> ([]domain.Bridge, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err
	return iface.bridge_list_by_owner(service.repo, owner)
}

// list_pending_bridges is an owner's pending enrollments (REQ-EA-1), for the one view
// that shows them. The caller frees each bridge and the slice.
list_pending_bridges :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context) -> []domain.Bridge {
	owner, ok, _ := ownership.owner_from_auth(auth)
	if !ok do return nil
	rows, err := iface.bridge_list_pending(service.repo)
	if err.code != .None do return nil
	out := make([dynamic]domain.Bridge)
	for &r in rows {
		if r.owner_user_id == owner {
			append(&out, r)
		} else {
			domain.bridge_destroy(&r)
		}
	}
	delete(rows)
	return out[:]
}

// REQ-ENROLL-PENDING: replacement enrollments have no pending bridge row.
// Include their enroll-scoped credential families without changing the durable
// target or removing the still-working bridge from ordinary discovery.
list_pending_enrollments :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context) -> ([]domain.Bridge, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err
	tokens, token_err := iface.bridge_list_live_tokens_by_scope(service.repo, BRIDGE_ENROLL_TOKEN_SCOPE)
	if token_err.code != .None do return nil, token_err
	defer free_bridge_tokens(tokens)
	rows, row_err := iface.bridge_list_pending(service.repo)
	if row_err.code != .None do return nil, row_err
	out := make([dynamic]domain.Bridge)
	seen := make(map[string]bool)
	defer delete(seen)
	for &r in rows {
		if r.owner_user_id == owner {
			append(&out, r)
			seen[r.bridge_id] = true
		} else {
			domain.bridge_destroy(&r)
		}
	}
	delete(rows)
	for token in tokens {
		if seen[token.bridge_id] do continue
		r, found, get_err := iface.bridge_get_bridge(service.repo, token.bridge_id)
		if get_err.code != .None {
			for &b in out do domain.bridge_destroy(&b)
			delete(out)
			return nil, get_err
		}
		if !found do continue
		if r.owner_user_id == owner && r.status != .Revoked {
			append(&out, r)
			seen[r.bridge_id] = true
		} else {
			domain.bridge_destroy(&r)
		}
	}
	return out[:], domain.Domain_Error{}
}

// get_bridge is the owner-scoped lookup behind every user-facing bridge operation,
// and it does NOT return a pending enrollment (REQ-EA-1): until its vault key is
// delivered a bridge is not enrolled, so it must not be a launch, command, rename or
// file target. The anti-enumeration shape is the same as a missing bridge. The
// enrollment endpoints themselves use get_bridge_for_enrollment.
get_bridge :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, bridge_id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	bridge, ok, err := get_bridge_for_enrollment(service, auth, bridge_id)
	if !ok do return domain.Bridge{}, false, err
	if domain.bridge_is_pending(bridge) {
		domain.bridge_destroy(&bridge)
		return domain.Bridge{}, false, domain.domain_error(.Not_Found, "bridge not found")
	}
	return bridge, true, domain.Domain_Error{}
}

// get_bridge_for_enrollment is get_bridge without the pending gate, for the few
// paths that exist to finish an enrollment: the unseal relay, the public key and
// the enrollment status. Ownership is still enforced.
get_bridge_for_enrollment :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, bridge_id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	bridge, ok, err := iface.bridge_get_bridge(service.repo, bridge_id)
	if !ok do return domain.Bridge{}, false, err
	if owner_ok, owner_err := ownership.require_owner(auth, bridge.owner_user_id); !owner_ok do return domain.Bridge{}, false, owner_err
	return bridge, true, domain.Domain_Error{}
}

bridge_owner_user_id :: proc(service: ^Bridge_Service, bridge_id: string) -> string {
	bridge, ok, _ := iface.bridge_get_bridge(service.repo, bridge_id)
	if !ok do return ""
	return string(bridge.owner_user_id)
}

// bridge_absence_marker reports when a bridge was last HEARD FROM, and whether it is
// eligible to be judged absent at all. Unauthenticated and internal, like
// bridge_owner_user_id above and for the same reason: the caller is the hub's own
// periodic sweep, which acts for no user.
//
// WHY last_seen_at IS THE RIGHT CLOCK, and it is not obvious from the column name.
// It is refreshed on EVERY current-generation heartbeat, ~45s, by
// touch_runtime_liveness, whether or not the beat carries capability metadata
// (heartbeat metadata may be omitted once negotiated). So it tracks LIVENESS, not
// the moment the connection was established.
// And mark_bridge_offline deliberately does NOT touch it, which is what makes it an
// absence clock rather than a proxy for one: on disconnect the value FREEZES at the
// last heartbeat and nothing moves it until the bridge genuinely returns. `now` minus
// this is therefore "how long since we last had this bridge".
//
// eligible is false for a REVOKED bridge: revocation is an administrative end, its
// sessions are not "maybe still running somewhere", and aging out a revoked bridge
// would be a second mechanism acting on a decision already taken.
// THE RETURNED STRING IS A CLONE AND THE CALLER OWNS IT. The repository's row reader
// hands back an owned string for every text column; this proc destroys the bridge before returning, so
// the one value that escapes cannot alias freed memory. That matters more than usual
// here because the caller runs on the reaper's process-scoped thread with no
// per-request arena — returning a borrowed field, as bridge_owner_user_id does, would
// leak all the rest on every sweep.
bridge_absence_marker :: proc(service: ^Bridge_Service, bridge_id: string) -> (last_seen_at: string, eligible: bool) {
	if service == nil || service.repo == nil || bridge_id == "" do return "", false
	bridge, ok, _ := iface.bridge_get_bridge(service.repo, bridge_id)
	if !ok do return "", false
	defer { b := bridge; domain.bridge_destroy(&b) }
	if bridge.status == .Revoked do return "", false
	if bridge.last_seen_at == "" do return "", false
	return strings.clone(bridge.last_seen_at), true
}

patch_bridge :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, bridge_id: string, label: string, has_label: bool, telemetry_enabled: string, has_telemetry: bool) -> (domain.Bridge, bool, domain.Domain_Error) {
	bridge, ok, err := get_bridge(service, auth, bridge_id)
	if !ok do return domain.Bridge{}, false, err
	if has_label {
		if strings.trim_space(label) == "" do return domain.Bridge{}, false, domain.domain_error(.Validation_Failed, "label is required")
		bridge.label = label
		bridge.label_is_user_customized = true
	}
	if has_telemetry {
		val := strings.trim_space(telemetry_enabled)
		if val != "inherit" && val != "enabled" && val != "disabled" {
			return domain.Bridge{}, false, domain.domain_error(.Validation_Failed, "telemetry_enabled must be 'inherit', 'enabled', or 'disabled'")
		}
		bridge.telemetry_enabled = val
	}
	bridge.updated_at = platform.clock_now(service.clock)
	return iface.bridge_save_bridge(service.repo, bridge)
}

rename_bridge :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, bridge_id, label: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	return patch_bridge(service, auth, bridge_id, label, true, "", false)
}

bridge_runtime_connect :: proc(service: ^Bridge_Service, token: string, hostname, os_name, arch, capabilities_json: string, version: string = "", commit_sha: string = "", build_timestamp: string = "") -> (domain.Bridge, bool, domain.Domain_Error) {
	auth, auth_ok, auth_err := verify_bridge_token(service, token)
	if !auth_ok do return domain.Bridge{}, false, auth_err
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.repo, auth.bridge_id)
	if !bridge_ok do return domain.Bridge{}, false, bridge_err
	if bridge.status == .Revoked { domain.bridge_destroy(&bridge); return domain.Bridge{}, false, domain.domain_error(.Bridge_Revoked, "bridge is revoked") }
	if plan_err := check_bridge_plan(service, bridge); plan_err.code != .None { domain.bridge_destroy(&bridge); return {}, false, plan_err }
	if hostname != "" {
		delete(bridge.machine_hostname)
		bridge.machine_hostname = strings.clone(hostname)
		if !bridge.label_is_user_customized { delete(bridge.label); bridge.label = strings.clone(hostname) }
	}
	if os_name != "" { delete(bridge.machine_os); bridge.machine_os = strings.clone(os_name) }
	if arch != "" { delete(bridge.machine_arch); bridge.machine_arch = strings.clone(arch) }
	// Every hello is a FULL replacement of the runtime metadata (plan T3): a hello that
	// omits `features` withdraws them all rather than inheriting a previous
	// connection's list. Only internal callers that apply no frame pass "".
	if capabilities_json != "" {
		record := bridge_capabilities_record(bridge.capabilities_json, capabilities_json)
		delete(bridge.capabilities_json)
		bridge.capabilities_json = record
	}
	if version != "" { delete(bridge.version); bridge.version = strings.clone(version) }
	if commit_sha != "" { delete(bridge.commit_sha); bridge.commit_sha = strings.clone(commit_sha) }
	if build_timestamp != "" { delete(bridge.build_timestamp); bridge.build_timestamp = strings.clone(build_timestamp) }
	if bridge_update_status_active(bridge.update_status) {
		delete(bridge.update_status)
		bridge.update_status = strings.clone("idle")
		delete(bridge.update_message)
		bridge.update_message = strings.clone("")
		bridge.update_progress = 0
	}
	now := platform.clock_now(service.clock)
	bridge.status = .Online
	delete(bridge.last_seen_at)
	bridge.last_seen_at = strings.clone(now)
	delete(bridge.updated_at)
	bridge.updated_at = strings.clone(now)
	saved, saved_ok, save_err := iface.bridge_save_bridge(service.repo, bridge)
	if !saved_ok do domain.bridge_destroy(&bridge)
	return saved, saved_ok, save_err
}

// mark_bridge_offline flips a bridge's durable status to .Offline on a WS
// disconnect. bridge_runtime_connect sets .Online but nothing symmetric marked
// the durable record offline when the control WS dropped, so the bridge row
// stayed .Online forever. Idempotent: the write is a narrow conditional UPDATE
// (status='online' only), so a .Revoked bridge is never touched — even one revoked
// between the read and the write — and no other column is rewritten. Returns the
// bridge + whether the status actually changed so the caller can avoid a
// spurious event when nothing moved. The returned row is fully owned.
mark_bridge_offline :: proc(service: ^Bridge_Service, bridge_id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.repo, bridge_id)
	if !bridge_ok do return domain.Bridge{}, false, bridge_err
	// Never override a terminal revoked state, and skip the write if already offline.
	if bridge.status == .Revoked || bridge.status == .Offline do return bridge, false, domain.Domain_Error{}
	now := platform.clock_now(service.clock)
	changed, err := iface.bridge_update_runtime(service.repo, .Offline, bridge_id, now)
	if err.code != .None { domain.bridge_destroy(&bridge); return domain.Bridge{}, false, err }
	if !changed do return bridge, false, domain.Domain_Error{}
	bridge.status = .Offline
	bridge_row_set(&bridge.updated_at, now)
	return bridge, true, domain.Domain_Error{}
}

// bridge_row_set replaces one owned string field of a row with an owned clone.
// clock_now returns a temp-allocated string, so it is never assigned directly into a
// row a caller will destroy (see update_vault_status).
@(private = "file")
bridge_row_set :: proc(field: ^string, value: string) {
	if len(field^) > 0 do delete(field^)
	field^ = strings.clone(value)
}

// touch_runtime_liveness records that a current-generation runtime frame arrived:
// status='online', last_seen_at=now, nothing else. It runs on EVERY accepted heartbeat,
// whether or not the frame carries capability metadata — liveness used to be refreshed
// only as a side effect of the capabilities save, so a heartbeat without metadata let
// last_seen_at age until the reaper declared the Bridge gone. A revoked Bridge stays
// revoked: the UPDATE is fenced on status != 'revoked' and reports Bridge_Revoked.
//
// moved is true when the durable status changed (offline -> online). The returned row is
// fully owned; columns other than status/last_seen_at/updated_at are as read just before
// the write and are never written back.
touch_runtime_liveness :: proc(service: ^Bridge_Service, bridge_id: string) -> (bridge: domain.Bridge, moved: bool, err: domain.Domain_Error) {
	if service == nil || service.repo == nil || bridge_id == "" do return domain.Bridge{}, false, domain.domain_error(.Validation_Failed, "bridge_id is required")
	row, ok, get_err := iface.bridge_get_bridge(service.repo, bridge_id)
	if !ok do return domain.Bridge{}, false, get_err
	if row.status == .Revoked { domain.bridge_destroy(&row); return domain.Bridge{}, false, domain.domain_error(.Bridge_Revoked, "bridge is revoked") }
	now := platform.clock_now(service.clock)
	written, write_err := iface.bridge_update_runtime(service.repo, .Liveness, bridge_id, now)
	if write_err.code != .None { domain.bridge_destroy(&row); return domain.Bridge{}, false, write_err }
	// Zero rows: revoked (or deleted) between the read and the write. Fail closed.
	if !written { domain.bridge_destroy(&row); return domain.Bridge{}, false, domain.domain_error(.Bridge_Revoked, "bridge is revoked") }
	moved = row.status != .Online
	row.status = .Online
	bridge_row_set(&row.last_seen_at, now)
	bridge_row_set(&row.updated_at, now)
	return row, moved, domain.Domain_Error{}
}

// update_runtime_metadata stores the legacy capability/feature metadata a heartbeat
// (or other runtime frame) carries, via a compare-and-set on capabilities_json: the
// write lands only if the column still holds the value the record was derived from, so
// a concurrent enrollment commit is never overwritten (the next beat re-derives from
// the new value). An unchanged record writes nothing and reports changed=false, which
// is what keeps an ordinary beat from publishing a resource notification. A frame
// without "capabilities" is a no-op: liveness is touch_runtime_liveness's job.
update_runtime_metadata :: proc(service: ^Bridge_Service, bridge_id, frame: string) -> (changed: bool, err: domain.Domain_Error) {
	if frame == "" || !strings.contains(frame, "\"capabilities\"") do return false, domain.Domain_Error{}
	row, ok, get_err := iface.bridge_get_bridge(service.repo, bridge_id)
	if !ok do return false, get_err
	defer domain.bridge_destroy(&row)
	if row.status == .Revoked do return false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	record := bridge_capabilities_record(row.capabilities_json, frame, context.temp_allocator)
	if record == row.capabilities_json do return false, domain.Domain_Error{}
	return iface.bridge_update_runtime(service.repo, .Capabilities, bridge_id, platform.clock_now(service.clock), record, row.capabilities_json)
}

// update_runtime_capabilities is liveness + legacy metadata in one call (the shape the
// heartbeat arm used before they were split; kept for callers that apply a whole
// runtime frame). Both halves are narrow fenced writes — no full-row save.
// changed (optional) reports whether a user-visible field moved: the stored
// capability record or the status (REQ-2: unchanged beats publish nothing).
// The returned row is fully owned and reflects the stored record.
update_runtime_capabilities :: proc(service: ^Bridge_Service, bridge_id, capabilities_json: string, changed: ^bool = nil) -> (domain.Bridge, bool, domain.Domain_Error) {
	if changed != nil do changed^ = false
	bridge, moved, err := touch_runtime_liveness(service, bridge_id)
	if err.code != .None do return domain.Bridge{}, false, err
	caps_changed, caps_err := update_runtime_metadata(service, bridge_id, capabilities_json)
	if caps_err.code != .None { domain.bridge_destroy(&bridge); return domain.Bridge{}, false, caps_err }
	if caps_changed {
		// Re-read only the moved column's source of truth: the row as stored now.
		fresh, fresh_ok, _ := iface.bridge_get_bridge(service.repo, bridge_id)
		if fresh_ok {
			bridge_row_set(&bridge.capabilities_json, fresh.capabilities_json)
			domain.bridge_destroy(&fresh)
		}
	}
	if changed != nil do changed^ = moved || caps_changed
	return bridge, true, domain.Domain_Error{}
}

// BRIDGE_RUNTIME_CAPABILITY_KEYS are the top-level fields of a bridge_hello /
// bridge_heartbeat frame that readers of bridges.capabilities_json use:
// bridge_capabilities_json (capabilities, provider, default_model), instance
// reconfiguration and pane capture (features).
BRIDGE_RUNTIME_CAPABILITY_KEYS :: [?]string{"capabilities", "features"}
BRIDGE_RUNTIME_CAPABILITY_STRING_KEYS :: [?]string{"provider", "default_model"}

// BRIDGE_ENROLLMENT_RECORD_KEYS are written once, at approval, by
// device_enroll_capabilities_json: the record of which key the human approved.
BRIDGE_ENROLLMENT_RECORD_KEYS :: [?]string{"public_key", "enrollment_public_key", "enrollment_key_fingerprint", "os_user", "enrolled_via"}

// bridge_capabilities_record builds the stored capabilities_json from the row's
// current value and an incoming hello/heartbeat frame. The row used to be
// replaced by the whole frame — instance lists, stats, search status — so it grew
// to ~60 KB, was rewritten every 45 s and re-read on every bridge-token auth, and
// the first frame erased the enrollment record. Now the runtime keys come from the
// frame and the enrollment keys survive from the row; a key absent from both is
// omitted. A row with an enrollment record (enrolled_via) keeps its approved
// public_key; one without (enrolled before device authorization, or already
// overwritten by an earlier version) keeps tracking the frame's live key.
bridge_capabilities_record :: proc(existing, frame: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '{')
	first := true
	write_key :: proc(b: ^strings.Builder, first: ^bool, key: string) {
		if !first^ do strings.write_byte(b, ',')
		first^ = false
		strings.write_byte(b, '"')
		write_service_json_string(b, key)
		strings.write_string(b, "\":")
	}
	write_string_member :: proc(b: ^strings.Builder, first: ^bool, key, value: string) {
		write_key(b, first, key)
		strings.write_byte(b, '"')
		write_service_json_string(b, value)
		strings.write_byte(b, '"')
	}
	for key in BRIDGE_RUNTIME_CAPABILITY_KEYS {
		if key == "features" {
			// Always present: an absent list is an explicit withdrawal ([]), which
			// lets a reader tell "no features" from "record lost its metadata".
			write_key(&b, &first, key)
			strings.write_string(&b, bridge_runtime_features_raw(frame, context.temp_allocator))
			continue
		}
		// sort_keys: the capability objects are re-marshalled from a map, and without a
		// fixed key order an identical frame produced a different record on most beats,
		// so every heartbeat looked like a capability change (write + notification).
		if raw, ok := jsonx.extract_raw_array(frame, key, true, context.temp_allocator, sort_keys = true); ok {
			write_key(&b, &first, key)
			strings.write_string(&b, raw)
		}
	}
	for key in BRIDGE_RUNTIME_CAPABILITY_STRING_KEYS {
		if value, ok := jsonx.extract_string_found(frame, key, true, context.temp_allocator); ok do write_string_member(&b, &first, key, value)
	}
	enrolled := jsonx.has_key(existing, "enrolled_via", true)
	for key in BRIDGE_ENROLLMENT_RECORD_KEYS {
		value, ok := jsonx.extract_string_found(existing, key, true, context.temp_allocator)
		if key == "public_key" && !enrolled {
			if live, live_ok := jsonx.extract_string_found(frame, key, true, context.temp_allocator); live_ok do value, ok = live, true
		}
		if ok do write_string_member(&b, &first, key, value)
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// bridge_runtime_features_raw is the canonical `features` array of a hello/heartbeat
// frame, exactly as bridge_capabilities_record stores it; an absent or non-array
// member is the empty list (full replacement withdraws everything).
bridge_runtime_features_raw :: proc(frame: string, allocator := context.allocator) -> string {
	if raw, ok := jsonx.extract_raw_array(frame, "features", true, allocator, sort_keys = true); ok do return raw
	return strings.clone("[]", allocator)
}

// bridge_stored_features_raw is the `features` array a stored capability record holds,
// in the same canonical form; found=false when the record has lost it (a row from
// before full-replacement records, or one restored/rewritten under a live connection).
bridge_stored_features_raw :: proc(record: string, allocator := context.allocator) -> (string, bool) {
	return jsonx.extract_raw_array(record, "features", true, allocator, sort_keys = true)
}

// BRIDGE_VAULT_STATUS_VALUES are the only values a bridge may report (REQ-BVS-1),
// matching bridge_vault_status_string on the bridge side. Anything else is dropped
// rather than stored: the field is rendered straight into the UI, and a bridge is
// free to send whatever it likes down the WS, so the hub pins the vocabulary here.
// "unpaired": enrolled, but it never pinned an account root and can no longer (it
// missed its enrollment's first unseal); the UI offers revoke + re-enroll.
// There is no plaintext ("disabled") mode: a bridge either holds the keyring or not.
BRIDGE_VAULT_STATUS_VALUES :: [3]string{"unlocked", "locked", "unpaired"}

bridge_vault_status_valid :: proc(value: string) -> bool {
	for allowed in BRIDGE_VAULT_STATUS_VALUES {
		if value == allowed do return true
	}
	return false
}

// update_vault_status stores a bridge's self-reported vault tri-state (REQ-BVS-1).
//
// changed is true ONLY when the stored value actually moved, and the DB write is
// skipped entirely when it did not. That is what makes the "invalidate on change, not
// on every heartbeat" requirement true at the source rather than at each call site:
// a bridge reports this in every heartbeat, ~45s, forever, and a caller that had to
// remember to diff first would eventually forget and flood every connected browser.
//
// An empty or unrecognised value is a no-op, NOT an error and NOT a write: an older
// bridge omits the field, and that must leave an existing reported value alone rather
// than erasing it to "".
//
// Unauthenticated and internal, like update_runtime_capabilities above and for the
// same reason: the caller is the bridge's own WS frame handler, already authenticated
// as this bridge by its token.
//
// THE RETURNED ROW IS FULLY OWNED ON EVERY SUCCESSFUL PATH and the caller must
// destroy it with domain.bridge_destroy.
//
// NOTHING MAY GATE ON THE RESULT. See the field comment on domain.Bridge.vault_status.
update_vault_status :: proc(service: ^Bridge_Service, bridge_id, vault_status: string) -> (bridge: domain.Bridge, changed: bool, err: domain.Domain_Error) {
	if service == nil || service.repo == nil || bridge_id == "" do return domain.Bridge{}, false, domain.domain_error(.Validation_Failed, "bridge_id is required")
	if !bridge_vault_status_valid(vault_status) do return domain.Bridge{}, false, domain.domain_error(.Validation_Failed, "vault_status must be 'unlocked' or 'locked'")
	existing, ok, get_err := iface.bridge_get_bridge(service.repo, bridge_id)
	if !ok do return domain.Bridge{}, false, get_err
	if existing.status == .Revoked {
		e := existing
		domain.bridge_destroy(&e)
		return domain.Bridge{}, false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	}
	if existing.vault_status == vault_status {
		// Unchanged: hand the row back so a caller can still read owner_user_id, but
		// report changed=false so no event is published and no row is rewritten.
		// The row is owned on every path out of here, so the caller destroys it
		// without having to know which path it came from.
		return existing, false, domain.Domain_Error{}
	}
	// A narrow conditional UPDATE of vault_status alone, never a full-row save: the
	// old read-modify-save reverted any label, token rotation, telemetry or revoke that
	// landed between its read and its write. changed comes from the affected-row count,
	// so a concurrent writer that already stored this value (or a revoke) yields no
	// write and no event.
	now := platform.clock_now(service.clock)
	written, write_err := iface.bridge_update_runtime(service.repo, .Vault_Status, bridge_id, now, vault_status)
	if write_err.code != .None { domain.bridge_destroy(&existing); return domain.Bridge{}, false, write_err }
	if !written do return existing, false, domain.Domain_Error{}
	// Cloned, never borrowed (and clock_now is temp-allocated): every field stays owned
	// so the caller can destroy the row with domain.bridge_destroy.
	bridge_row_set(&existing.vault_status, vault_status)
	bridge_row_set(&existing.updated_at, now)
	return existing, true, domain.Domain_Error{}
}

// revoke_bridge ends one machine's access. Audit F6: this used to flip a DB row and
// nothing else, which left a CONNECTED bridge fully operational until it next chose
// to reconnect — and REQ-IMPL-3 makes that worse before it makes it better, because
// a bridge that refreshes proactively may never re-present a credential at all. A
// revocation that only blocks reconnects does not revoke.
//
// SO IT DOES THREE THINGS, IN THIS ORDER, AND THE ORDER IS THE POINT:
//
//  1. REVOKE THE CREDENTIALS (every `bridge_tokens` row of this bridge, both kinds,
//     every family). First, so that a bridge which reconnects in the microseconds
//     between steps cannot re-authenticate.
//  2. FLIP THE DURABLE ROW. Second, so the state an operator reads is consistent
//     with credentials that are already dead rather than ahead of them.
//  3. CLOSE THE LIVE SOCKET. Last, because it is the only step whose failure is
//     survivable: a bridge whose socket somehow outlives this can no longer
//     authenticate anything, so the worst case is a connection that is already inert.
//
// PER-MACHINE BY CONSTRUCTION (§11.7): every write here is keyed by `bridge_id` —
// the token rows, the bridge row, the socket lookup — so revoking bridge A cannot
// touch a row or a connection belonging to bridge B, including another bridge of the
// same owner. There is deliberately no "revoke all my bridges" path; the operator
// thinks in machines.
//
// A MISSING CLOSER SEAM IS REPORTED, NOT IGNORED. If no closer is wired, revocation
// still revokes but a live socket survives until its next frame fails
// authentication. `connection_closed` says which happened, so a caller (and a test)
// can tell the difference between "closed it" and "there was nothing to close".
revoke_bridge :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, bridge_id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	bridge, ok, err := get_bridge(service, auth, bridge_id)
	if !ok do return domain.Bridge{}, false, err
	now := platform.clock_now(service.clock)
	// Credentials first. A repository without the REQ-IMPL-3 procs wired returns an
	// Internal_Error here, which must FAIL the revocation rather than proceed to a
	// row flip that an operator would read as "revoked" while the credential still
	// authenticates. The one exception is a bridge with no token rows at all (a
	// legacy `hbr_` bridge): that reports 0 changed rows and ok=true.
	if _, revoke_ok, revoke_err := iface.bridge_revoke_tokens_for_bridge(service.repo, bridge_id, now); !revoke_ok {
		return domain.Bridge{}, false, revoke_err
	}
	bridge.status = .Revoked
	bridge.updated_at = now
	bridge.revoked_at = now
	saved, save_ok, save_err := iface.bridge_save_bridge(service.repo, bridge)
	if !save_ok do return domain.Bridge{}, false, save_err
	_ = close_bridge_connection(service, bridge_id)
	if plan_err := reconcile_owner_plan(service, string(bridge.owner_user_id)); plan_err.code != .None {
		// Revocation already succeeded. The reaper retries freeing the plan slot.
		fmt.eprintfln("hub: bridge %s revoked; plan reconciliation failed: %s", bridge_id, plan_err.message)
	}
	return saved, true, domain.Domain_Error{}
}

valid_hub_base_url :: proc(value: string) -> bool {
	if strings.has_prefix(value, "http://") do return valid_hub_authority(value[len("http://"):])
	if strings.has_prefix(value, "https://") do return valid_hub_authority(value[len("https://"):])
	return false
}

valid_hub_authority :: proc(value: string) -> bool {
	if strings.trim_space(value) == "" do return false
	if strings.contains(value, "?") || strings.contains(value, "#") do return false
	if strings.contains(value, "/") do return false
	return true
}

// verify_bridge_token authenticates a bridge credential. There is now exactly ONE
// shape that authenticates:
//
//   hba_  the expiring access token (REQ-IMPL-3). Row in `bridge_tokens`, 1h TTL,
//         rotated through a refresh token. Every enrolled bridge has one.
//
// REQ-IMPL-6 DELETED THE SECOND SHAPE. `hbr_` was the non-expiring token minted by
// `enroll_bridge` from a pre-shared enrollment secret, stored on the `bridges` row. Its
// flow, its minting and its lookup are all gone, so no `hbr_` can authenticate.
//
// IT IS RECOGNISED RATHER THAN SIMPLY UNRECOGNISED, and that is deliberate. An
// `hbr_` presented today is not an attack in the common case — it is a bridge that
// was enrolled before this change and still has its old credential on disk, which
// is EVERY bridge enrolled the old way. A bare "bridge token is invalid" would send
// that operator looking for a network or clock fault. So this one prefix gets a
// message that names the remedy; see BRIDGE_LEGACY_CREDENTIAL_MESSAGE.
//
// WHY NAMING IT LEAKS NOTHING. The reply is identical for every `hbr_`, whether or
// not the bridge id exists and whether or not the secret would once have matched:
// there is no lookup, so there is no oracle, and the message is derivable from the
// changelog anyway. Contrast the `hba_` path, which still equalises its miss timing.
//
// A token with NEITHER prefix (an `hbf_` refresh token, say) is rejected without a
// lookup. A refresh token must never authenticate a connection: it is the long-lived
// half of the pair and is accepted at exactly one endpoint.
verify_bridge_token :: proc(service: ^Bridge_Service, token: string) -> (contracts.Auth_Context, bool, domain.Domain_Error) {
	if token == "" do return contracts.Auth_Context{}, false, domain.domain_error(.Unauthenticated, "bridge token is required")
	if strings.has_prefix(token, ACCESS_TOKEN_PREFIX) do return verify_access_token(service, token)
	if strings.has_prefix(token, BRIDGE_TOKEN_PREFIX) {
		return contracts.Auth_Context{}, false, domain.domain_error(.Unauthenticated, BRIDGE_LEGACY_CREDENTIAL_MESSAGE)
	}
	return contracts.Auth_Context{}, false, domain.domain_error(.Unauthenticated, "bridge token is invalid")
}

// BRIDGE_LEGACY_CREDENTIAL_MESSAGE is the operator story for REQ-ENROLL-9, in the
// one place an operator is guaranteed to meet it: the rejection itself.
//
// Every bridge enrolled through the deleted flow stops working at this change and
// must re-enroll. That is a known, accepted consequence, so the error names the
// command that fixes it rather than describing the problem. The bridge logs this
// message verbatim when the Hub refuses it, and `ham-bridge status` surfaces the
// same instruction.
BRIDGE_LEGACY_CREDENTIAL_MESSAGE :: "this bridge's credential was issued by the removed enrollment flow and is no longer accepted; re-enroll this machine with: ham-bridge enroll --hub <your-hub-url>"

refresh_hostname :: proc(service: ^Bridge_Service, bridge: domain.Bridge, hostname: string) -> domain.Bridge {
	updated := bridge
	if hostname == "" do return updated
	updated.machine_hostname = hostname
	if !updated.label_is_user_customized do updated.label = hostname
	updated.updated_at = platform.clock_now(service.clock)
	return updated
}

write_service_json_string :: proc(b: ^strings.Builder, value: string) {
	contracts.write_json_string(b, value)
}

// shell_pty_input_command_json is the JSON (acked, command_id-bearing) form of pty input,
// used by the REST fallback which must wait for a typed refusal. The pane WebSocket uses
// the binary ack-less form (send_shell_input_binary). REQ-PTY-NET-3 dropped the duplicated
// `agent_instance_id`: the bridge keys on `shell_id` for both panes.
shell_pty_input_command_json :: proc(command_id, shell_id, data: string, enc_b64: string = "") -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_pty_input\",\"command_id\":\"")
	write_service_json_string(&b, command_id)
	strings.write_string(&b, "\",\"shell_id\":\"")
	write_service_json_string(&b, shell_id)
	strings.write_string(&b, "\",\"data_b64\":\"")
	payload := enc_b64
	if payload == "" { payload = string(base64.encode(transmute([]byte)data, allocator = context.temp_allocator)) }
	// An armored v2 token is re-framed to the PTY v2 binary layout (u32be epoch |
	// salt16 | nonce | tag | ct) so the bridge sees the epoch it must check; a non-armored
	// enc_b64 is already base64 of that layout and passes through untouched.
	if domain.is_vault_armored(payload) {
		if framed, ok := domain.vault_pty_v2_payload_from_armor(payload, context.temp_allocator); ok {
			payload = string(base64.encode(framed, allocator = context.temp_allocator))
		} else {
			payload = ""
		}
	}
	write_service_json_string(&b, payload)
	strings.write_string(&b, "\",\"is_encrypted\":")
	strings.write_string(&b, "true" if enc_b64 != "" else "false")
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

shell_pty_resize_command_json :: proc(command_id, shell_id: string, rows, cols: int) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"shell_pty_resize\",\"command_id\":\"")
	write_service_json_string(&b, command_id)
	strings.write_string(&b, "\",\"shell_id\":\"")
	write_service_json_string(&b, shell_id)
	strings.write_string(&b, "\",\"agent_instance_id\":\"")
	write_service_json_string(&b, shell_id)
	strings.write_string(&b, "\",\"rows\":")
	strings.write_int(&b, rows)
	strings.write_string(&b, ",\"cols\":")
	strings.write_int(&b, cols)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// send_shell_input relays keystrokes to the bridge. wait_for_result (REST callers)
// waits for the bridge's command_result so a typed refusal such as `vault_locked`
// comes back as a typed error; the WebSocket pane path stays fire-and-forget and
// learns of a locked vault from the bridge's in-stream `shell_pty_vault_locked` frame.
send_shell_input :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, bridge_id, shell_id, data: string, enc_b64: string = "", sink_override: project_service.Bridge_Command_Sink = {}, wait_for_result := false) -> (bool, domain.Domain_Error) {
	if strings.trim_space(shell_id) == "" {
		return false, domain.domain_error(.Validation_Failed, "shell_id is required")
	}
	bridge, ok, err := get_bridge(service, auth, bridge_id)
	if !ok do return false, err

	if bridge.status == .Revoked {
		return false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	}
	if bridge.status != .Online {
		return false, domain.domain_error(.Bridge_Offline, fmt.tprintf("Bridge %s is not connected", bridge.bridge_id))
	}

	sink := service.bridge_command_sink
	if sink.send_runtime_command == nil && sink_override.send_runtime_command != nil {
		sink = sink_override
	}

	cmd_id := ""
	if service.ids != nil {
		cmd_id = platform.generate_id(service.ids, "cmd_sh_input_")
	}

	cmd_json := shell_pty_input_command_json(cmd_id, shell_id, data, enc_b64)
	defer delete(cmd_json)

	command := project_service.Runtime_Command{
		bridge_id = bridge.bridge_id,
		command_id = cmd_id,
		body_json = cmd_json,
	}
	sent, send_err := project_service.bridge_command_send_runtime_checked(sink, command, wait_for_result)
	if !sent do return false, send_err
	return true, domain.Domain_Error{}
}

// send_shell_input_binary relays keystrokes from a pane WebSocket as ONE binary pty_wire
// INPUT session frame (REQ-PTY-NET-3): no command_id, no command_result, no base64.
// `payload` is plaintext or nonce|tag|ciphertext exactly as the browser sent it; the hub
// never decrypts keystrokes. A locked vault is reported by the bridge's in-stream
// shell_pty_vault_locked frame, as before.
send_shell_input_binary :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, bridge_id, shell_id: string, payload: []byte, encrypted: bool, sink_override: project_service.Bridge_Command_Sink = {}) -> (bool, domain.Domain_Error) {
	if strings.trim_space(shell_id) == "" {
		return false, domain.domain_error(.Validation_Failed, "shell_id is required")
	}
	if len(payload) == 0 do return true, domain.Domain_Error{}
	bridge, ok, err := get_bridge(service, auth, bridge_id)
	if !ok do return false, err
	if bridge.status == .Revoked {
		return false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	}
	if bridge.status != .Online {
		return false, domain.domain_error(.Bridge_Offline, fmt.tprintf("Bridge %s is not connected", bridge.bridge_id))
	}
	sink := service.bridge_command_sink
	if sink.send_runtime_binary == nil && sink_override.send_runtime_binary != nil {
		sink = sink_override
	}
	frame := contracts.pty_wire_encode_session_frame(contracts.PTY_WIRE_KIND_INPUT, contracts.pty_wire_flags(false, encrypted), shell_id, payload, context.temp_allocator)
	if frame == nil do return false, domain.domain_error(.Validation_Failed, "shell_id too long for a pty frame")
	return project_service.bridge_command_send_runtime_binary(sink, bridge.bridge_id, frame)
}

send_shell_resize :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, bridge_id, shell_id: string, rows, cols: int, sink_override: project_service.Bridge_Command_Sink = {}) -> (bool, domain.Domain_Error) {
	if strings.trim_space(shell_id) == "" {
		return false, domain.domain_error(.Validation_Failed, "shell_id is required")
	}
	if rows < 1 || cols < 1 {
		return false, domain.domain_error(.Validation_Failed, "rows and cols must be at least 1")
	}
	bridge, ok, err := get_bridge(service, auth, bridge_id)
	if !ok do return false, err

	if bridge.status == .Revoked {
		return false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	}
	if bridge.status != .Online {
		return false, domain.domain_error(.Bridge_Offline, fmt.tprintf("Bridge %s is not connected", bridge.bridge_id))
	}

	r := rows
	c := cols
	if r > 65535 do r = 65535
	if c > 65535 do c = 65535

	sink := service.bridge_command_sink
	if sink.send_runtime_command == nil && sink_override.send_runtime_command != nil {
		sink = sink_override
	}

	cmd_id := ""
	if service.ids != nil {
		cmd_id = platform.generate_id(service.ids, "cmd_sh_resize_")
	}

	cmd_json := shell_pty_resize_command_json(cmd_id, shell_id, r, c)
	defer delete(cmd_json)

	sent, send_err := project_service.bridge_command_send_runtime(
		sink,
		project_service.Runtime_Command{
			bridge_id = bridge.bridge_id,
			command_id = cmd_id,
			body_json = cmd_json,
		},
	)
	if !sent do return false, send_err
	return true, domain.Domain_Error{}
}

// --- LSP session commands (REQ-LSP-RLY-1) ------------------------------------
//
// These mirror send_shell_input/send_shell_resize above: same bridge lookup, same
// revoked/offline gating, same command sink. The frame types are the ones the
// bridge's bridge_lsp_handle_command dispatches (src/bridge/lsp_session.odin).
//
// session_id here is the HUB WIRE ID, not the client-supplied session id. The
// bridge keys its own session map by this string alone, so two users choosing the
// same client session id must not collide on it; the relay allocates an opaque
// wire id per session and that is what crosses this boundary.

lsp_start_command_json :: proc(cmd_id, session_id, language, cmd, args, cwd, owner_user_id: string, root_markers: string = "", file_path: string = "") -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"lsp_start\",\"command_id\":\"")
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, "\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"language\":\"")
	contracts.write_json_string(&b, language)
	strings.write_string(&b, "\",\"cmd\":\"")
	contracts.write_json_string(&b, cmd)
	strings.write_string(&b, "\",\"args\":\"")
	contracts.write_json_string(&b, args)
	strings.write_string(&b, "\",\"cwd\":\"")
	contracts.write_json_string(&b, cwd)
	strings.write_string(&b, "\",\"owner_user_id\":\"")
	contracts.write_json_string(&b, owner_user_id)
	strings.write_string(&b, "\"")
	if strings.trim_space(root_markers) != "" {
		strings.write_string(&b, ",\"root_markers\":\"")
		contracts.write_json_string(&b, root_markers)
		strings.write_string(&b, "\"")
	}
	if strings.trim_space(file_path) != "" {
		strings.write_string(&b, ",\"file_path\":\"")
		contracts.write_json_string(&b, file_path)
		strings.write_string(&b, "\"")
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

lsp_send_command_json :: proc(session_id, message: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"lsp_send\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\",\"message\":\"")
	contracts.write_json_string(&b, message)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

lsp_stop_command_json :: proc(cmd_id, session_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"lsp_stop\",\"command_id\":\"")
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, "\",\"session_id\":\"")
	contracts.write_json_string(&b, session_id)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// lsp_bridge_ready resolves the bridge and rejects revoked/offline ones. Shared by
// the three senders below so the gating cannot drift between them.
lsp_bridge_ready :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, bridge_id, session_id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	if strings.trim_space(session_id) == "" {
		return domain.Bridge{}, false, domain.domain_error(.Validation_Failed, "session_id is required")
	}
	bridge, ok, err := get_bridge(service, auth, bridge_id)
	if !ok do return domain.Bridge{}, false, err
	if bridge.status == .Revoked {
		return domain.Bridge{}, false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	}
	if bridge.status != .Online {
		return domain.Bridge{}, false, domain.domain_error(.Bridge_Offline, fmt.tprintf("Bridge %s is not connected", bridge.bridge_id))
	}
	return bridge, true, domain.Domain_Error{}
}

lsp_sink_for :: proc(service: ^Bridge_Service, sink_override: project_service.Bridge_Command_Sink) -> project_service.Bridge_Command_Sink {
	sink := service.bridge_command_sink
	if sink.send_runtime_command == nil && sink_override.send_runtime_command != nil {
		sink = sink_override
	}
	return sink
}

send_lsp_start :: proc(
	service: ^Bridge_Service,
	auth: contracts.Auth_Context,
	bridge_id, session_id, language, cmd, args, cwd, owner_user_id: string,
	root_markers: string = "",
	file_path: string = "",
	sink_override: project_service.Bridge_Command_Sink = {},
) -> (bool, domain.Domain_Error) {
	if strings.trim_space(cmd) == "" {
		return false, domain.domain_error(.Validation_Failed, "cmd is required")
	}
	bridge, ok, err := lsp_bridge_ready(service, auth, bridge_id, session_id)
	if !ok do return false, err

	cmd_id := ""
	if service.ids != nil do cmd_id = platform.generate_id(service.ids, "cmd_lsp_start_")

	cmd_json := lsp_start_command_json(cmd_id, session_id, language, cmd, args, cwd, owner_user_id, root_markers, file_path)
	defer delete(cmd_json)

	sent, send_err := project_service.bridge_command_send_runtime(
		lsp_sink_for(service, sink_override),
		project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = cmd_id, body_json = cmd_json},
	)
	if !sent do return false, send_err
	return true, domain.Domain_Error{}
}

send_lsp_message :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, bridge_id, session_id, message: string, sink_override: project_service.Bridge_Command_Sink = {}) -> (bool, domain.Domain_Error) {
	if strings.trim_space(message) == "" {
		return false, domain.domain_error(.Validation_Failed, "message is required")
	}
	bridge, ok, err := lsp_bridge_ready(service, auth, bridge_id, session_id)
	if !ok do return false, err

	// lsp_send carries no command_id: it is a stream of JSON-RPC traffic, not a
	// request/result pair, and the bridge's handler does not read one.
	cmd_json := lsp_send_command_json(session_id, message)
	defer delete(cmd_json)

	sent, send_err := project_service.bridge_command_send_runtime(
		lsp_sink_for(service, sink_override),
		project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = "", body_json = cmd_json},
	)
	if !sent do return false, send_err
	return true, domain.Domain_Error{}
}

send_lsp_stop :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, bridge_id, session_id: string, sink_override: project_service.Bridge_Command_Sink = {}) -> (bool, domain.Domain_Error) {
	bridge, ok, err := lsp_bridge_ready(service, auth, bridge_id, session_id)
	if !ok do return false, err

	cmd_id := ""
	if service.ids != nil do cmd_id = platform.generate_id(service.ids, "cmd_lsp_stop_")

	cmd_json := lsp_stop_command_json(cmd_id, session_id)
	defer delete(cmd_json)

	sent, send_err := project_service.bridge_command_send_runtime(
		lsp_sink_for(service, sink_override),
		project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = cmd_id, body_json = cmd_json},
	)
	if !sent do return false, send_err
	return true, domain.Domain_Error{}
}

bridge_update_command_json :: proc(cmd_id, target_version, download_url, sha256: string, force: bool, drain_timeout_seconds: int) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"bridge_update\",\"command_id\":\"")
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, "\",\"target_version\":\"")
	contracts.write_json_string(&b, target_version)
	strings.write_string(&b, "\",\"download_url\":\"")
	contracts.write_json_string(&b, download_url)
	strings.write_string(&b, "\",\"sha256\":\"")
	contracts.write_json_string(&b, sha256)
	strings.write_string(&b, "\",\"force\":")
	strings.write_string(&b, "true" if force else "false")
	strings.write_string(&b, ",\"drain_timeout_seconds\":")
	strings.write_string(&b, fmt.tprintf("%d", drain_timeout_seconds))
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

send_bridge_update :: proc(
	service: ^Bridge_Service,
	auth: contracts.Auth_Context,
	bridge_id: string,
	target_version: string = "latest",
	force: bool = false,
	drain_timeout_seconds: int = 60,
	sink_override: project_service.Bridge_Command_Sink = {},
	update_extensions: bool = false,
) -> (
	string,
	bool,
	domain.Domain_Error,
) {
	if strings.trim_space(bridge_id) == "" {
		return "", false, domain.domain_error(.Validation_Failed, "bridge_id is required")
	}
	if !contracts.is_user_auth(auth) {
		return "", false, domain.domain_error(.Forbidden, "user authentication required to update bridge")
	}
	bridge, ok, err := get_bridge(service, auth, bridge_id)
	if !ok do return "", false, err

	if bridge.status == .Revoked {
		return "", false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	}
	if bridge.status != .Online {
		return "", false, domain.domain_error(
			.Unprocessable_Entity,
			fmt.tprintf("Bridge %s is not online", bridge.bridge_id),
		)
	}

	info := resolve_bridge_update_info(service.catalog, bridge)
	if !info.artifact_available {
		return "", false, domain.domain_error(
			.Validation_Failed,
			fmt.tprintf(
				"update %s is not available for this target (%s): no verified update artifact",
				info.latest_version,
				info.target,
			),
		)
	}
	effective_version := target_version
	if effective_version == "" || effective_version == "latest" {
		effective_version = info.latest_version
	} else if strings.trim_prefix(effective_version, "v") != strings.trim_prefix(info.latest_version, "v") {
		// A Settings modal may predate a newly promoted release. Never dispatch
		// the new bundle/hash under the modal's old version label.
		return "", false, domain.domain_error(.Validation_Failed, "update catalog changed; refresh bridge update information and retry")
	}
	download_url := info.download_url
	sha256 := info.sha256

	sink := service.bridge_command_sink
	if sink.send_runtime_command == nil && sink_override.send_runtime_command != nil {
		sink = sink_override
	}

	cmd_id := ""
	if service.ids != nil {
		cmd_id = platform.generate_id(service.ids, "cmd_upd_")
	} else {
		cmd_id = "cmd_upd_default"
	}


	// Save consent BEFORE dispatch: a successful send can immediately restart the Bridge.
	tracked := domain.Provider_Extension_Command {
		command_id        = cmd_id,
		bridge_id         = bridge.bridge_id,
		kind              = "bridge_update",
		state             = "dispatched",
		update_extensions = update_extensions,
		target_version    = effective_version,
		target_commit     = info.latest_commit_sha,
		source_version    = bridge.version,
		source_commit     = bridge.commit_sha,
	}
	if service.provider_repo != nil {
		created, track_err := iface.provider_extension_command_create(
			service.provider_repo,
			tracked,
		)
		if !created do return "", false, track_err
	} else if update_extensions {
		return "", false, domain.domain_error(
			.Internal_Error,
			"extension update tracking is not configured",
		)
	}
	cmd_json := bridge_update_command_json(
		cmd_id,
		effective_version,
		download_url,
		sha256,
		force,
		drain_timeout_seconds,
	)
	defer delete(cmd_json)

	sent, send_err := project_service.bridge_command_send_runtime(
		sink,
		project_service.Runtime_Command {
			bridge_id = bridge.bridge_id,
			command_id = cmd_id,
			body_json = cmd_json,
		},
	)

	if !sent {
		if service.provider_repo != nil {
			tracked.state = "failed"
			tracked.message = send_err.message
			_ = iface.provider_extension_command_save(service.provider_repo, tracked)
		}
		return "", false, send_err
	}

	bridge.update_status = "updating"
	bridge.update_message = "Update command dispatched"
	bridge.update_progress = 0
	bridge.updated_at = platform.clock_now(service.clock)
	iface.bridge_save_bridge(service.repo, bridge)

	return strings.clone(cmd_id), true, domain.Domain_Error{}
}

// record_bridge_update_progress persists terminal failures (and useful
// in-flight stages) reported by the Bridge so the UI cannot remain stuck on
// `updating` after the command has already failed.
bridge_update_status_active :: proc(stage: string) -> bool {
	switch stage {
	case "updating", "draining", "preparing", "downloading", "downloaded", "validating", "verifying", "verified", "extracting", "preflight", "staged", "stopping_pty_host", "pty_host_stopped", "restarting":
		return true
	}
	return false
}

record_bridge_update_progress :: proc(service: ^Bridge_Service, bridge_id, stage, message: string, progress_percent: int = 0) -> (bool, domain.Domain_Error) {
	if service == nil || strings.trim_space(bridge_id) == "" {
		return false, domain.domain_error(.Validation_Failed, "bridge_id is required")
	}
	bridge, found, err := iface.bridge_get_bridge(service.repo, bridge_id)
	if !found do return false, err

	if !bridge_update_status_active(stage) && stage != "failed" && stage != "succeeded" {
		domain.bridge_destroy(&bridge)
		return false, domain.domain_error(.Validation_Failed, "invalid bridge update progress stage")
	}
	status := stage
	if stage == "succeeded" do status = "idle"
	delete(bridge.update_status)
	bridge.update_status = strings.clone(status)
	delete(bridge.update_message)
	bridge.update_message = strings.clone(message)
	if stage != "failed" || progress_percent != 0 {
		bridge.update_progress = progress_percent
		if bridge.update_progress < 0 do bridge.update_progress = 0
		if bridge.update_progress > 100 do bridge.update_progress = 100
	}
	delete(bridge.update_error)
	bridge.update_error = strings.clone(message if stage == "failed" else "")
	delete(bridge.updated_at)
	bridge.updated_at = strings.clone(platform.clock_now(service.clock))

	saved, saved_ok, save_err := iface.bridge_save_bridge(service.repo, bridge)
	if saved_ok {
		// The repository returns the same owned Bridge value on a successful
		// save, so destroy exactly once through the returned alias.
		domain.bridge_destroy(&saved)
	} else {
		domain.bridge_destroy(&bridge)
	}
	return saved_ok, save_err
}

// ── Remote uninstall (REQ-ENR-10, F20) ──────────────────────────────────────

// bridge_uninstall_audit_hook, when non-nil, receives each remote-uninstall audit
// event instead of the stdout logger (tests assert on it).
bridge_uninstall_audit_hook: proc(outcome, bridge_id, user_id, command_id, request_id, detail: string)

// log_bridge_uninstall emits one greppable audit line per remote-uninstall request,
// accepted or refused: `grep bridge_uninstall` over the hub log lists who asked to
// wipe which machine. outcome: dispatched | denied | offline | failed.
log_bridge_uninstall :: proc(outcome, bridge_id, user_id, command_id, request_id, detail: string) {
	if bridge_uninstall_audit_hook != nil {
		bridge_uninstall_audit_hook(outcome, bridge_id, user_id, command_id, request_id, detail)
		return
	}
	fmt.printfln(
		"ham-hub bridge_uninstall outcome=%s bridge_id=%s user_id=%s command_id=%s request_id=%s detail=%q",
		outcome, bridge_id, user_id, command_id, request_id, detail,
	)
}

bridge_uninstall_command_json :: proc(cmd_id: string, purge: bool) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"bridge_uninstall\",\"command_id\":\"")
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, "\",\"mode\":\"")
	strings.write_string(&b, "purge" if purge else "keep_data")
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// send_bridge_uninstall asks an ONLINE bridge of the caller's own account to
// uninstall itself (`ham-bridge uninstall`, detached on the bridge): it wipes its
// service, binaries and secrets and stays on the hub as offline, so a reinstall
// can reuse it (revoking is the separate, explicit Revoke). Only a user session of the owning account may ask; another account
// gets the owner check's Not_Found, a bridge token Forbidden. An offline bridge
// cannot be told: the caller revokes it instead. Returns the command id
// (allocated with the context allocator).
send_bridge_uninstall :: proc(
	service: ^Bridge_Service,
	auth: contracts.Auth_Context,
	bridge_id: string,
	purge: bool = true,
	live: bool = true,
	sink_override: project_service.Bridge_Command_Sink = {},
) -> (
	string,
	bool,
	domain.Domain_Error,
) {
	if strings.trim_space(bridge_id) == "" {
		return "", false, domain.domain_error(.Validation_Failed, "bridge_id is required")
	}
	if !contracts.is_user_auth(auth) {
		return "", false, domain.domain_error(.Forbidden, "user authentication required to uninstall a bridge")
	}
	bridge, ok, err := get_bridge(service, auth, bridge_id)
	if !ok do return "", false, err
	if bridge.status == .Revoked {
		return "", false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	}
	if bridge.status != .Online || !live {
		return "", false, domain.domain_error(
			.Unprocessable_Entity,
			fmt.tprintf("Bridge %s is not online; revoke it instead", bridge.bridge_id),
		)
	}
	sink := service.bridge_command_sink
	if sink.send_runtime_command == nil && sink_override.send_runtime_command != nil {
		sink = sink_override
	}
	// generate_id is temp-allocated; the caller owns (and deletes) the result.
	cmd_id := strings.clone(platform.generate_id(service.ids, "cmd_uninst_") if service.ids != nil else "cmd_uninst_default")
	cmd_json := bridge_uninstall_command_json(cmd_id, purge)
	defer delete(cmd_json)
	sent, send_err := project_service.bridge_command_send_runtime(
		sink,
		project_service.Runtime_Command{bridge_id = bridge.bridge_id, command_id = cmd_id, body_json = cmd_json},
	)
	if !sent {
		delete(cmd_id)
		return "", false, send_err
	}
	return cmd_id, true, domain.Domain_Error{}
}
