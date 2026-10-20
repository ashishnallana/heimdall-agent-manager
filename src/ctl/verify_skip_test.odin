package main

import "core:strings"
import "core:testing"

@(test)
test_submit_skip_flags_require_a_reason :: proc(t: ^testing.T) {
	for extra in ([][]string{
		{"--skip-verify"},
		{"--skip-verify", "--skip-verify-reason", "  "},
		{"--skip-verify-reason", "unavailable"},
	}) {
		args := make([dynamic]string)
		append(&args, "lease", "submit", "--summary", "done")
		append(&args, ..extra)
		_, ok := ctl_v2_lease_submit_params(args[:], cwd_override = "/work")
		testing.expect(t, !ok, "skip flag and non-empty reason must be paired")
		delete(args)
	}
	args := []string{"ham-ctl", "lease", "submit", "--summary", "done", "--skip-verify", "--skip-verify-reason", `  runner says "offline"  `}
	p, ok := ctl_v2_lease_submit_params(args, cwd_override = "/work")
	defer delete(p)
	testing.expect(t, ok, "valid explicit skip")
	testing.expect(t, strings.contains(p, `"skip_verify":true`) && strings.contains(p, `"skip_verify_reason":"runner says \"offline\""`), "skip reason trimmed and JSON escaped")
	tokens := command_tokens(args)
	defer delete(tokens)
	testing.expect_value(t, len(tokens), 2)
}
