package bridge

import "core:fmt"
import base64 "core:encoding/base64"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"

Bridge_Service :: struct {
	repo: ^iface.Bridge_Repository,
	clock: ^platform.Clock,
	ids: ^platform.ID_Generator,
	bridge_command_sink: project_service.Bridge_Command_Sink,
	catalog: ^Bridge_Update_Catalog,
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
}

// with_connection_closer attaches the F6 socket teardown. Called by app wiring once
// the runtime registry exists; tests inject a fake that records the bridge_id.
with_connection_closer :: proc(service: ^Bridge_Service, closer: Bridge_Connection_Closer) {
	service.connection_closer = closer
}

// close_bridge_connection invokes the seam, or reports false when none is wired.
close_bridge_connection :: proc(service: ^Bridge_Service, bridge_id: string) -> bool {
	if service == nil || service.connection_closer.close_bridge_connection == nil do return false
	if bridge_id == "" do return false
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

get_bridge :: proc(service: ^Bridge_Service, auth: contracts.Auth_Context, bridge_id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
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
// It is refreshed on EVERY heartbeat, ~45s: the bridge writes "capabilities" into
// every bridge_heartbeat frame unconditionally (bridge/hub_runtime_client.odin), the
// heartbeat handler therefore always calls update_runtime_capabilities, and that
// proc sets last_seen_at unconditionally. So it tracks LIVENESS, not the moment the
// connection was established.
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
	if hostname != "" {
		delete(bridge.machine_hostname)
		bridge.machine_hostname = strings.clone(hostname)
		if !bridge.label_is_user_customized { delete(bridge.label); bridge.label = strings.clone(hostname) }
	}
	if os_name != "" { delete(bridge.machine_os); bridge.machine_os = strings.clone(os_name) }
	if arch != "" { delete(bridge.machine_arch); bridge.machine_arch = strings.clone(arch) }
	if capabilities_json != "" && strings.contains(capabilities_json, "\"capabilities\"") { delete(bridge.capabilities_json); bridge.capabilities_json = strings.clone(capabilities_json) }
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
// stayed .Online forever. Idempotent: a .Revoked bridge is left untouched, and
// re-marking an already-.Offline bridge is a cheap no-op save. Returns the
// bridge + whether the status actually changed so the caller can avoid a
// spurious event when nothing moved.
mark_bridge_offline :: proc(service: ^Bridge_Service, bridge_id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.repo, bridge_id)
	if !bridge_ok do return domain.Bridge{}, false, bridge_err
	// Never override a terminal revoked state, and skip the write if already offline.
	if bridge.status == .Revoked || bridge.status == .Offline do return bridge, false, domain.Domain_Error{}
	now := platform.clock_now(service.clock)
	bridge.status = .Offline
	delete(bridge.updated_at)
	bridge.updated_at = strings.clone(now)
	saved, ok, err := iface.bridge_save_bridge(service.repo, bridge)
	if !ok { domain.bridge_destroy(&bridge); return domain.Bridge{}, false, err }
	return saved, true, domain.Domain_Error{}
}

update_runtime_capabilities :: proc(service: ^Bridge_Service, bridge_id, capabilities_json: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	bridge, bridge_ok, bridge_err := iface.bridge_get_bridge(service.repo, bridge_id)
	if !bridge_ok do return domain.Bridge{}, false, bridge_err
	if bridge.status == .Revoked do return domain.Bridge{}, false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	if capabilities_json != "" && strings.contains(capabilities_json, "\"capabilities\"") do bridge.capabilities_json = capabilities_json
	now := platform.clock_now(service.clock)
	bridge.status = .Online
	bridge.last_seen_at = now
	bridge.updated_at = now
	return iface.bridge_save_bridge(service.repo, bridge)
}

// BRIDGE_VAULT_STATUS_VALUES are the only values a bridge may report (REQ-BVS-1),
// matching bridge_vault_status_string on the bridge side. Anything else is dropped
// rather than stored: the field is rendered straight into the UI, and a bridge is
// free to send whatever it likes down the WS, so the hub pins the vocabulary here.
BRIDGE_VAULT_STATUS_VALUES :: [3]string{"unlocked", "locked", "disabled"}

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
	if !bridge_vault_status_valid(vault_status) do return domain.Bridge{}, false, domain.domain_error(.Validation_Failed, "vault_status must be 'unlocked', 'locked', or 'disabled'")
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
	// CLONED, not borrowed. patch_bridge and update_runtime_capabilities both assign
	// the caller's string straight into the row, which leaves the returned row a mix of
	// owned and borrowed fields that nothing can safely destroy — so their callers
	// leak the whole row instead. Cloning here keeps every field owned, which is what
	// lets the caller do the obvious thing and call domain.bridge_destroy on it.
	if len(existing.vault_status) > 0 do delete(existing.vault_status)
	existing.vault_status = strings.clone(vault_status)
	// updated_at is CLONED for the same reason, and this one is a trap worth naming:
	// platform.clock_now returns a fmt.tprintf string, so it lives in the TEMP
	// allocator, not the heap. Every other service proc here assigns it straight into
	// the row — which is safe only because none of them destroy the row afterwards.
	// Pairing that idiom with a bridge_destroy frees a temp pointer, and the test
	// suite reports it as a `bad free` against domain.bridge_destroy.
	if len(existing.updated_at) > 0 do delete(existing.updated_at)
	existing.updated_at = strings.clone(platform.clock_now(service.clock))
	saved, save_ok, save_err := iface.bridge_save_bridge(service.repo, existing)
	if !save_ok do return domain.Bridge{}, false, save_err
	return saved, true, domain.Domain_Error{}
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
// message verbatim when the Hub refuses it, and `heimdall status`/`heimdall doctor`
// surface the same instruction.
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
	if strings.has_prefix(payload, "vault:v1:") do payload = payload[len("vault:v1:"):]
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
) -> (string, bool, domain.Domain_Error) {
	if strings.trim_space(bridge_id) == "" {
		return "", false, domain.domain_error(.Validation_Failed, "bridge_id is required")
	}
	if auth.kind != .User_Token && auth.kind != .Trusted_Proxy {
		return "", false, domain.domain_error(.Forbidden, "user authentication required to update bridge")
	}
	bridge, ok, err := get_bridge(service, auth, bridge_id)
	if !ok do return "", false, err

	if bridge.status == .Revoked {
		return "", false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	}
	if bridge.status != .Online {
		return "", false, domain.domain_error(.Unprocessable_Entity, fmt.tprintf("Bridge %s is not online", bridge.bridge_id))
	}

	info := resolve_bridge_update_info(service.catalog, bridge)
	if !info.artifact_available {
		return "", false, domain.domain_error(
			.Validation_Failed,
			fmt.tprintf("update %s is not available for this target (%s): no verified update artifact", info.latest_version, info.target),
		)
	}
	effective_version := target_version
	if effective_version == "" || effective_version == "latest" {
		effective_version = info.latest_version
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

	cmd_json := bridge_update_command_json(cmd_id, effective_version, download_url, sha256, force, drain_timeout_seconds)
	defer delete(cmd_json)

	sent, send_err := project_service.bridge_command_send_runtime(
		sink,
		project_service.Runtime_Command{
			bridge_id = bridge.bridge_id,
			command_id = cmd_id,
			body_json = cmd_json,
		},
	)
	if !sent do return "", false, send_err

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
