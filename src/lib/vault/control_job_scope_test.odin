package vault

import "core:testing"

@(test)
test_control_job_scoped_operations_cannot_repurpose_consent :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	read:="mcp:chains mcp:tasks:read"
	write:="mcp:chains mcp:tasks:write"
	testing.expect(t,control_job_scope_ok(CONTROL_SCOPE_BASE,"","read"))
	testing.expect(t,control_job_scope_ok(CONTROL_SCOPE_BASE,"","seal"))
	testing.expect(t,!control_job_scope_ok(CONTROL_SCOPE_BASE,"","seal_comment"))
	testing.expect(t,!control_job_scope_ok(CONTROL_SCOPE_BASE,"tasks.comment","seal_comment"))
	testing.expect(t,!control_job_scope_ok(read,"tasks.comment","seal_comment"))
	testing.expect(t,control_job_scope_ok(write,"tasks.comment","seal_comment"))
	testing.expect(t,!control_job_scope_ok(write,"tasks.comment","seal"))
	testing.expect(t,!control_job_scope_ok(write,"tasks.get","read"))
	testing.expect(t,control_job_scope_ok(read,"tasks.get","read"))
	testing.expect(t,!control_job_scope_ok(write,"messages.send","seal_comment"))
	testing.expect(t,control_job_scope_ok(write,"tasks.create","seal_task"))
	testing.expect(t,!control_job_scope_ok(read,"tasks.create","seal_task"))
	testing.expect(t,!control_job_scope_ok(CONTROL_SCOPE_BASE,"","seal_task"))
}
