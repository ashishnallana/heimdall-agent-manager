package contracts

// Typed wire shapes for bridge credential replies, shared by the hub (which
// marshals them) and the bridge (which unmarshals them), so the two cannot drift
// and no credential reply is ever assembled by string concatenation.

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// Bridge_Refresh_Reply is the `data` of POST /api/v1/device/bridge-refresh. The
// field ORDER and names are the historical wire format byte for byte (0.4.x and
// 0.5.x bridges parse it). expires_in / refresh_expires_in are durations in
// seconds, never timestamps.
Bridge_Refresh_Reply :: struct {
	access_token:       string,
	refresh_token:      string,
	bridge_id:          string,
	token_type:         string,
	expires_in:         int,
	refresh_expires_in: int,
}

// Bridge_Token_Data is everything a bridge reads from a token-bearing reply: the
// device-grant poll (status/interval and the approval facts) and the refresh reply.
Bridge_Token_Data :: struct {
	status:                  string,
	interval:                int,
	approver_username:       string,
	owner_user_id:           string,
	bridge_id:               string,
	access_token:            string,
	refresh_token:           string,
	expires_in:              int,
	refresh_expires_in:      int,
	vault_delivery_expected: bool,
	enrollment_pending:      bool,
}

// bridge_token_response_decode_checked reads a token reply inside the API envelope
// ({"data":{...}}) or bare. On failure the second result says why, as text that is
// safe to log: the decoder's error kind, never any part of the body (which carries
// secrets). Temp-allocated.
bridge_token_response_decode_checked :: proc(body: string) -> (Bridge_Token_Data, string) {
	if strings.trim_space(body) == "" do return {}, "empty body"
	envelope: struct {
		data: Maybe(Bridge_Token_Data),
	}
	env_err := json.unmarshal_string(body, &envelope, json.Specification.JSON, context.temp_allocator)
	if env_err == nil {
		if data, has := envelope.data.?; has do return data, ""
	}
	flat: Bridge_Token_Data
	flat_err := json.unmarshal_string(body, &flat, json.Specification.JSON, context.temp_allocator)
	if flat_err == nil do return flat, ""
	return {}, fmt.tprintf("json decode failed: %v", env_err if env_err != nil else flat_err)
}

// bridge_token_response_decode is the checked decoder without the reason: anything
// that does not decode is the zero value, which callers treat as unusable.
bridge_token_response_decode :: proc(body: string) -> Bridge_Token_Data {
	data, _ := bridge_token_response_decode_checked(body)
	return data
}
