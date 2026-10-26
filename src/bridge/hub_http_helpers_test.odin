package main

import "core:strings"
import httpc "odin_test:lib/httpc"

// hub_test_response is a canned httpc.Response for scripted hub transports. The
// body is heap-cloned so the code under test may response_destroy it.
hub_test_response :: proc(status: int, body := "", may_have_sent := true) -> httpc.Response {
	return httpc.Response{status = status, body = transmute([]byte)strings.clone(body), may_have_sent = may_have_sent}
}

// hub_test_has_header reports whether a scripted request carries a header.
hub_test_has_header :: proc(req: httpc.Request, name: string) -> bool {
	for h in req.headers {
		if strings.equal_fold(h.name, name) do return true
	}
	return false
}
