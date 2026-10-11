package main

import "core:testing"

@(test)
test_ctl_shell_preview_url_from_response :: proc(t: ^testing.T) {
	response := `{"v":1,"data":{"ok":true,"session":{"session_id":"ss_1","preview_url":"https://preview.example/p/ss_1/"}}}`
	actual := ctl_shell_preview_url_from_response(response)
	defer delete(actual)
	testing.expect_value(t, actual, "https://preview.example/p/ss_1/")
}
