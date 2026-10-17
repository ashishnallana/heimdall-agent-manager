package main

import "core:os"
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
	path := "/tmp/ham_ctl_handoff_flags_test.json"
	_ = os.write_entire_file(path, transmute([]byte)string(`{"next_steps":"a","decisions":["x"]}`))
	defer os.remove(path)
	h, ok := ctl_handoff_flags([]string{"lease", "handoff", "--summary", "s", "--handoff-file", path})
	testing.expect(t, ok, "file read")
	testing.expect_value(t, h, `{"next_steps":"a","decisions":["x"]}`)
}
