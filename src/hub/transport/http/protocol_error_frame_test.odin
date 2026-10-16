package http

import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import jsonx "odin_test:lib/jsonx"

// REQ-ERR-PROTO-A: a frame the hub cannot process is refused with a typed,
// fatal protocol_error naming the frame type, never dropped silently.
@(test)
test_err_proto_protocol_error_frame_shape :: proc(t: ^testing.T) {
	frame := bridge_protocol_error_frame("mystery_frame", contracts.wire_error(.Not_Implemented, "unknown_frame_type", "hub does not handle this frame type"))
	defer delete(frame)
	testing.expect_value(t, jsonx.extract_string(frame, "type", "", true, context.temp_allocator), "protocol_error")
	testing.expect_value(t, jsonx.extract_string(frame, "frame_type", "", true, context.temp_allocator), "mystery_frame")
	werr, found := contracts.wire_error_parse(frame, context.temp_allocator)
	testing.expect(t, found, frame)
	testing.expect_value(t, werr.code, contracts.Error_Code.Not_Implemented)
	testing.expect_value(t, werr.class, contracts.Bridge_Error_Class.fatal)
	testing.expect_value(t, werr.cause, "unknown_frame_type")
}

// The HTTP envelope carries the class and cause of a bridge-relayed error.
@(test)
test_err_proto_respond_error_carries_class_and_cause :: proc(t: ^testing.T) {
	resp := respond_error(domain.domain_error_from_wire(contracts.wire_error_from_bridge(.provider_not_logged_in, .recoverable, "log in")), "req_1")
	defer delete(resp.body)
	testing.expect_value(t, resp.status, 503)
	werr, found := contracts.wire_error_parse(resp.body, context.temp_allocator)
	testing.expect(t, found, resp.body)
	testing.expect_value(t, werr.class, contracts.Bridge_Error_Class.recoverable)
	testing.expect_value(t, werr.cause, "provider_not_logged_in")
}
