package http

import "core:testing"
import contracts "odin_test:contracts"

// REQ-TN-A: renaming a chain stamps who set the title, so the chain-scoped title
// nudge stops; a PATCH that does not touch the title leaves title_source alone.
@(test)
test_chain_patch_title_source :: proc(t: ^testing.T) {
	testing.expect_value(t, chain_patch_title_source("Windows port", .Session), "user")
	testing.expect_value(t, chain_patch_title_source("Windows port", .OIDC), "user")
	testing.expect_value(t, chain_patch_title_source("Windows port", .Instance_Token), "agent")
	testing.expect_value(t, chain_patch_title_source("", .Session), "")
	testing.expect_value(t, chain_patch_title_source("", .Instance_Token), "")
}
