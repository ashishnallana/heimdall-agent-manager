package bridge_runtime

import "core:testing"

// REQ-ERR-PROTO-B: every waited command tells the bridge how long the hub waits.
@(test)
test_runtime_command_with_timeout :: proc(t: ^testing.T) {
	testing.expect_value(t, runtime_command_with_timeout(`{"type":"vcs_push","command_id":"c1"}`, 120_000), `{"type":"vcs_push","command_id":"c1","timeout_ms":120000}`)
	testing.expect_value(t, runtime_command_with_timeout("{\"type\":\"fs_stat\"}\n", 10_000), `{"type":"fs_stat","timeout_ms":10000}`)
	testing.expect_value(t, runtime_command_with_timeout(`{}`, 5000), `{"timeout_ms":5000}`)
	// A top-level timeout longer than the hub's wait is lowered to it (shell_kill sends
	// 10s while the hub waits 5s); a shorter one is kept.
	testing.expect_value(t, runtime_command_with_timeout(`{"type":"shell_kill","timeout_ms":10000,"session_id":"s"}`, 5000), `{"type":"shell_kill","timeout_ms":5000,"session_id":"s"}`)
	testing.expect_value(t, runtime_command_with_timeout(`{"type":"shell_kill","timeout_ms": 10000}`, 5000), `{"type":"shell_kill","timeout_ms": 5000}`)
	testing.expect_value(t, runtime_command_with_timeout(`{"type":"shell_start","timeout_ms":3000}`, 30000), `{"type":"shell_start","timeout_ms":3000}`)
	// timeout_ms nested in params, or quoted inside content, is not the command budget.
	testing.expect_value(t, runtime_command_with_timeout(`{"type":"shell_start","params":{"timeout_ms":600000}}`, 30000), `{"type":"shell_start","params":{"timeout_ms":600000},"timeout_ms":30000}`)
	testing.expect_value(t, runtime_command_with_timeout(`{"type":"fs_write_file","content":"{\"timeout_ms\":1}"}`, 20000), `{"type":"fs_write_file","content":"{\"timeout_ms\":1}","timeout_ms":20000}`)
	testing.expect_value(t, runtime_command_with_timeout(`{"type":"x","content":"\"timeout_ms\":5"}`, 20000), `{"type":"x","content":"\"timeout_ms\":5","timeout_ms":20000}`)
	// Nothing to add, or not an object.
	testing.expect_value(t, runtime_command_with_timeout(`{"type":"x"}`, 0), `{"type":"x"}`)
	testing.expect_value(t, runtime_command_with_timeout(`[1]`, 1000), `[1]`)
}
