package iface

import domain "odin_test:hub/domain"

Agent_Runtime_Busy_Proc :: proc(ctx:rawptr,instance_id:string)->(bool,domain.Domain_Error)
// Checked inside the engine grant UOW so a lifecycle intent cannot race a
// fresh task lease between its own lease check and remote command dispatch.
agent_runtime_busy :: proc(repo:^Agent_Repository,instance_id:string)->(bool,domain.Domain_Error) {
	if repo==nil || repo.runtime_busy==nil do return false,{}
	return repo.runtime_busy(repo.ctx,instance_id)
}
