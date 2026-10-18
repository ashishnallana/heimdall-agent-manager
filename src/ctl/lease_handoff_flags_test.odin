package main

import "core:os"
import "core:strings"
import "core:testing"

// ham-ctl lease handoff/switch: --next-steps is the one-line form TASK.md
// teaches; it must reach the hub as handoff {next_steps}, not be dropped.

@(test)
test_handoff_flags_next_steps_becomes_handoff_object :: proc(t: ^testing.T) {
	h, ok := ctl_handoff_flags([]string{"lease", "switch", "task_b", "--summary", "paused", "--next-steps", `finish the "printer"`})
	testing.expect(t, ok, "--next-steps yields a handoff object")
	testing.expect_value(t, h, `{"next_steps":"finish the \"printer\""}`)
}

@(test)
test_handoff_flags_absent_or_blank_sends_nothing :: proc(t: ^testing.T) {
	_, ok := ctl_handoff_flags([]string{"lease", "handoff", "--summary", "s"})
	testing.expect(t, !ok, "no flag → no handoff field")
	_, blank := ctl_handoff_flags([]string{"lease", "handoff", "--summary", "s", "--next-steps", "   "})
	testing.expect(t, !blank, "a blank --next-steps is ignored")
}

@(test)
test_handoff_flags_file_passes_through :: proc(t: ^testing.T) {
	tmp, _ := os.temp_dir(context.temp_allocator)
	path := strings.concatenate({tmp, "/ham_ctl_handoff_flags_test.json"}, context.temp_allocator)
	_ = os.write_entire_file(path, transmute([]byte)string(`{"next_steps":"a","decisions":["x"]}`))
	defer os.remove(path)
	h, ok := ctl_handoff_flags([]string{"lease", "handoff", "--summary", "s", "--handoff-file", path})
	testing.expect(t, ok, "file read")
	testing.expect_value(t, h, `{"next_steps":"a","decisions":["x"]}`)
}

// --decision / --dead-end are repeatable (one item per flag) and land as
// arrays next to next_steps; blanks are dropped.
@(test)
test_handoff_flags_decisions_and_dead_ends :: proc(t: ^testing.T) {
	h, ok := ctl_handoff_flags([]string{
		"lease", "submit", "--summary", "done",
		"--decision", "sha256 for token hashes",
		"--dead-end", `bcrypt "cost 12": too slow`,
		"--decision", "  ",
		"--dead-end", "partial index unsupported",
		"--next-steps", "wire rotation",
	})
	testing.expect(t, ok, "inline flags yield a handoff object")
	testing.expect_value(t, h, `{"next_steps":"wire rotation","decisions":["sha256 for token hashes"],"dead_ends":["bcrypt \"cost 12\": too slow","partial index unsupported"]}`)
	d, dok := ctl_handoff_flags([]string{"lease", "handoff", "--summary", "s", "--dead-end", "x"})
	testing.expect(t, dok, "a dead end alone is enough")
	testing.expect_value(t, d, `{"dead_ends":["x"]}`)
}

// lease submit builds its handoff from the same flags (it used to read only
// --handoff-file).
@(test)
test_lease_submit_params_carry_inline_handoff :: proc(t: ^testing.T) {
	args := []string{"lease", "submit", "--summary", "done", "--dead-end", "tried X"}
	h, _ := ctl_handoff_flags(args)
	params, ok := ctl_v2_lease_submit_params(args, h, "", "", "/tmp")
	testing.expect(t, ok, "params built")
	testing.expect(t, strings.contains(params, `"handoff":{"dead_ends":["tried X"]}`), params)
}
