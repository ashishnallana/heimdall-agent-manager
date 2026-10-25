package main

import "core:encoding/json"
import "core:strings"
import "core:testing"

// REQ-TV2-1 / M2 / M3: configured verification commands were removed from the
// CLI. The old flags are accepted for one release and never sent; the
// `ham-ctl verify` stub prints parseable JSON and does nothing else.

@(test)
test_verify_stub_prints_the_removed_json :: proc(t: ^testing.T) {
	out := ctl_verify_removed_json()
	testing.expect_value(t, out, `{"ok":true,"verify":"removed","message":"Verification commands were removed; choose and report your own checks"}`)
	parsed, err := json.parse(transmute([]byte)out, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	testing.expect(t, err == nil, "stub output parses")
	obj, _ := parsed.(json.Object)
	ok, _ := obj["ok"].(json.Boolean)
	testing.expect(t, bool(ok), "ok:true")
}

@(test)
test_submit_accepts_and_drops_removed_verify_flags :: proc(t: ^testing.T) {
	args := []string{"ham-ctl", "lease", "submit", "--summary", "done", "--verify", "make test", "--skip-verify", "--skip-verify-reason", "offline", "--auto"}
	p, ok := ctl_v2_lease_submit_params(args, cwd_override = "/work")
	defer delete(p)
	testing.expect(t, ok, "old flags do not fail submit")
	testing.expect_value(t, p, `{"summary":"done","cwd":"/work"}`)
	removed := ctl_lease_submit_removed_flags(args)
	testing.expect_value(t, strings.join(removed, ",", context.temp_allocator), "--verify,--skip-verify,--skip-verify-reason,--auto")
	testing.expect_value(t, len(ctl_lease_submit_removed_flags([]string{"ham-ctl", "lease", "submit", "--summary", "x"})), 0)

	// The removed value flags still consume their value, so it never becomes a positional.
	tokens := command_tokens(args)
	defer delete(tokens)
	testing.expect_value(t, len(tokens), 2)

	_, no_summary := ctl_v2_lease_submit_params([]string{"ham-ctl", "lease", "submit"}, cwd_override = "/work")
	testing.expect(t, !no_summary, "--summary is still required")
}

@(test)
test_brief_drops_removed_verify_fields :: proc(t: ^testing.T) {
	args := []string{"ham-ctl", "task", "create", "--goal", "g", "--acceptance", "a", "--verify", "make test", "--auto-submit", "--require-independent-verify"}
	brief, ok := ctl_task_brief_json(args, "")
	defer delete(brief)
	testing.expect(t, ok, "brief present")
	testing.expect_value(t, brief, `{"goal":"g","acceptance":["a"]}`)
	testing.expect_value(t, strings.join(ctl_task_brief_removed_fields(args, ""), ",", context.temp_allocator), "verify,auto_submit,require_independent_verify")

	file := `{"goal":"f","acceptance":["x"],"verify":"go test ./...","auto_submit":true,"require_independent_verify":false}`
	fb, fok := ctl_task_brief_json([]string{"ham-ctl"}, file)
	defer delete(fb)
	testing.expect(t, fok, "file brief present")
	testing.expect_value(t, fb, `{"goal":"f","acceptance":["x"]}`)
	testing.expect_value(t, strings.join(ctl_task_brief_removed_fields([]string{"ham-ctl", "--verify", "x"}, file), ",", context.temp_allocator), "verify,auto_submit,require_independent_verify")

	// A verify-only update sends no brief at all.
	_, only := ctl_task_brief_json([]string{"ham-ctl", "task", "update", "t1", "--verify", "make"}, "")
	testing.expect(t, !only, "verify-only update carries no brief")
	// A key nested deeper than the brief's top level is not a removed field.
	testing.expect_value(t, len(ctl_task_brief_removed_fields([]string{"ham-ctl"}, `{"goal":"g","output":{"verify":"x"}}`)), 0)
}
