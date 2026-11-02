package main

// Sealed provider profile operations (REQ-PROF-3, amendments 4 and 5).
//
// The hub relays `provider_profile_op {command_id, sealed}` without being able to
// read it: `sealed` is a vault:v2 token under the account keyring's CURRENT epoch,
// made by the user's browser. Its plaintext is
//
//   {op, profile_id, body, bridge_id, boot_id, ts, nonce}
//
// with op one of upsert | remove | reset | get | list. The provider is named only
// in an upsert body; remove/get take it from the stored record and reset from
// profile_id, which for a default profile is the provider slug. Before acting, the bridge
// requires: unsealed vault; a current-epoch token that opens (older epochs are
// refused, which is how device revocation is enforced); bridge_id and boot_id equal
// to its own; ts within the enc_spec window and a nonce not seen this boot. Every
// failure is a typed error and changes nothing.
//
// The reply `provider_profile_op_result {command_id, ok, error, sealed}` carries,
// for get/list, the profile(s) sealed back under the current epoch with sensitive
// env values removed (value_redacted). After any change the bridge sends a fresh
// provider_profiles_report.

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import vault "odin_test:lib/vault"
import ws "odin_test:lib/ws"

Provider_Profile_Env_Wire :: struct {
	name:           string `json:"name"`,
	value:          string `json:"value"`,
	sensitive:      bool `json:"sensitive"`,
	value_redacted: bool `json:"value_redacted"`,
	// upsert only: keep the stored value of this sensitive variable.
	keep:           bool `json:"keep"`,
}

Provider_Profile_Body_Wire :: struct {
	provider:    string `json:"provider"`,
	label_enc:   string `json:"label_enc"`,
	accent:      string `json:"accent"`,
	enabled:     bool `json:"enabled"`,
	environment: []Provider_Profile_Env_Wire `json:"environment"`,
	config:      Provider_Profile_Config `json:"config"`,
}

Provider_Profile_Op_Wire :: struct {
	op:         string `json:"op"`,
	profile_id: string `json:"profile_id"`,
	bridge_id:  string `json:"bridge_id"`,
	boot_id:    string `json:"boot_id"`,
	ts:         i64 `json:"ts"`,
	nonce:      string `json:"nonce"`,
	body:       Provider_Profile_Body_Wire `json:"body"`,
}

Provider_Profile_View_Wire :: Provider_Profile

Provider_Profile_Op_Response_Wire :: struct {
	nonce:    string `json:"nonce"`,
	profiles: []Provider_Profile_View_Wire `json:"profiles"`,
}

Provider_Profile_Op_Result_Wire :: struct {
	type:       string `json:"type"`,
	command_id: string `json:"command_id"`,
	ok:         bool `json:"ok"`,
	error:      string `json:"error"`,
	sealed:     string `json:"sealed"`,
}

// profile_view redacts a profile for the browser: sensitive values never leave.
profile_view :: proc(
	p: ^Provider_Profile,
	allocator := context.temp_allocator,
) -> Provider_Profile_View_Wire {
	out := p^
	out.environment = make([]Provider_Profile_Env, len(p.environment), allocator)
	copy(out.environment, p.environment)
	for &e in out.environment {
		if e.sensitive {
			e.value_redacted = e.value_redacted || e.value != ""
			e.value = ""
		} else {
			e.value_redacted = false
		}
	}
	out.config.api_key_redacted = out.config.api_key_redacted || out.config.api_key != ""
	out.config.api_key = ""
	return out
}

Profile_Op_Outcome :: struct {
	error:    string, // "" on success
	response: string, // plaintext JSON to seal back (get/list), else ""
	changed:  bool,
}

// profile_op_apply runs an already authenticated op. Split out for tests.
profile_op_apply :: proc(op: ^Provider_Profile_Op_Wire, now_ms: i64) -> Profile_Op_Outcome {
	switch op.op {
	case "upsert":
		body := &op.body
		env := make([]Provider_Profile_Env, len(body.environment), context.temp_allocator)
		keep := make([dynamic]string, context.temp_allocator)
		for e, i in body.environment {
			env[i] = Provider_Profile_Env {
				name           = e.name,
				value          = e.value,
				sensitive      = e.sensitive,
				value_redacted = e.value_redacted,
			}
			if e.keep && e.sensitive && e.value == "" do append(&keep, e.name)
		}
		p := Provider_Profile {
			profile_id  = op.profile_id,
			provider    = body.provider,
			label_enc   = body.label_enc,
			accent      = body.accent,
			enabled     = body.enabled,
			environment = env,
			config      = body.config,
		}
		if e := profile_upsert(&p, keep[:], now_ms); e != .None do return {error = profile_error_code(e)}
		return {changed = true}
	case "remove":
		if e := profile_remove(op.profile_id); e != .None do return {error = profile_error_code(e)}
		return {changed = true}
	case "reset":
		// Only a default profile resets, and its id is its provider slug.
		if !profile_catalog_has(op.profile_id) do return {error = profile_error_code(.Invalid_Id)}
		if e := profile_reset(op.profile_id); e != .None do return {error = profile_error_code(e)}
		return {changed = true}
	case "get", "list":
		profiles, err := profile_list()
		if err != .None do return {error = profile_error_code(err)}
		views := make([dynamic]Provider_Profile_View_Wire, context.temp_allocator)
		for &p in profiles {
			if op.op == "get" && p.profile_id != op.profile_id do continue
			append(&views, profile_view(&p))
		}
		if op.op == "get" && len(views) == 0 {
			// An unedited default profile exists without a record.
			if op.profile_id != "" && profile_catalog_has(op.profile_id) {
				def := Provider_Profile {
					profile_id = op.profile_id,
					provider   = op.profile_id,
					enabled    = true,
				}
				append(&views, profile_view(&def))
			} else {
				return {error = profile_error_code(.Not_Found)}
			}
		}
		data, merr := json.marshal(
			Provider_Profile_Op_Response_Wire{nonce = op.nonce, profiles = views[:]},
			allocator = context.temp_allocator,
		)
		if merr != nil do return {error = profile_error_code(.Store_Unavailable)}
		return {response = string(data)}
	}
	return {error = "profile_bad_op"}
}

// profile_op_open authenticates a sealed op (amendment 5): current epoch only, then
// binding, then freshness (so a foreign op never consumes a nonce slot).
profile_op_open :: proc(
	sealed: string,
	kr: ^vault.Vault_Keyring,
	bridge_id, boot_id: string,
	now_ms: i64,
) -> (
	op: Provider_Profile_Op_Wire,
	err: string,
) {
	if sealed == "" || !vault.is_armored(sealed) do return {}, "profile_bad_seal"
	if kr == nil do return {}, "profile_locked"
	if _, epoch, payload, res := vault.envelope_parse(sealed, context.temp_allocator); res == .Ok {
		_ = payload
		if epoch != kr.current_epoch do return {}, "profile_stale_epoch"
	}
	plaintext, ok := bridge_open_current_epoch_token(sealed, kr, context.temp_allocator)
	if !ok do return {}, "profile_bad_seal"
	if !vault.wire_decode(plaintext, &op, context.temp_allocator) do return {}, "profile_bad_seal"
	if op.bridge_id == "" || op.bridge_id != bridge_id do return {}, "profile_wrong_bridge"
	if op.boot_id == "" || boot_id == "" || op.boot_id != boot_id do return {}, "profile_stale_boot"
	if fresh := bridge_enc_spec_check_fresh(op.ts, op.nonce, now_ms); fresh != "" {
		return {}, "profile_replay" if strings.contains(fresh, "replayed") else "profile_expired"
	}
	return op, ""
}

profile_op_result_json :: proc(
	command_id: string,
	err, sealed: string,
	allocator := context.allocator,
) -> string {
	data, merr := json.marshal(
		Provider_Profile_Op_Result_Wire {
			type = "provider_profile_op_result",
			command_id = command_id,
			ok = err == "",
			error = err,
			sealed = sealed,
		},
		allocator = allocator,
	)
	if merr != nil do return strings.clone(`{"type":"provider_profile_op_result","ok":false,"error":"profile_error"}`, allocator)
	return string(data)
}

// bridge_hub_handle_provider_profile_op is the provider_profile_op frame handler.
bridge_hub_handle_provider_profile_op :: proc(conn: ^ws.Connection, text: string) {
	command_id := extract_json_string(text, "command_id", "")
	defer delete(command_id)
	sealed := extract_json_string(text, "sealed", "")
	defer delete(sealed)
	reply :: proc(conn: ^ws.Connection, command_id, err, sealed: string) {
		frame := profile_op_result_json(command_id, err, sealed)
		defer delete(frame)
		if conn != nil do _ = bridge_hub_send(conn, frame)
	}

	status, kr := bridge_vault_status_and_key()
	defer vault.keyring_wipe(&kr)
	if status != .Unlocked {
		reply(conn, command_id, "profile_locked", "")
		return
	}
	op, err := profile_op_open(
		sealed,
		&kr,
		bridge_config.daemon_id,
		bridge_unseal_boot_id(),
		bridge_now_unix_ms(),
	)
	if err != "" {
		fmt.printfln("bridge provider profile op refused: %s", err)
		reply(conn, command_id, err, "")
		return
	}
 route_op:=extract_json_string(text,"op","");defer delete(route_op)
 route_id:=extract_json_string(text,"profile_id","");defer delete(route_id)
 if !profile_op_route_matches(&op,route_op,route_id) {
  reply(conn,command_id,"profile_route_mismatch","");return
 }
	outcome := profile_op_apply(&op, bridge_now_unix_ms())
	if outcome.error != "" {
		reply(conn, command_id, outcome.error, "")
		return
	}
	resp_sealed := ""
	if outcome.response != "" {
		s, sok := bridge_encrypt_vault_text(outcome.response, &kr, context.temp_allocator)
		if !sok {
			reply(conn, command_id, profile_error_code(.Store_Unavailable), "")
			return
		}
		resp_sealed = s
	}
	reply(conn, command_id, "", resp_sealed)
	if outcome.changed do bridge_send_provider_profiles_report(conn)
}

// bridge_send_provider_profiles_report sends the metadata-only report; called on
// connect (catalog version), after a catalog update and after every change.
bridge_send_provider_profiles_report :: proc(conn: ^ws.Connection) {
	if conn == nil do return
	frame := profile_report_json()
	defer delete(frame)
	_ = bridge_hub_send(conn, frame)
}

// Route metadata cannot authorize a different operation from the sealed body.
profile_op_route_matches :: proc(op:^Provider_Profile_Op_Wire,route_op,route_id:string) -> bool {
 return op!=nil && route_op!="" && route_id!="" && route_op==op.op && route_id==op.profile_id
}
