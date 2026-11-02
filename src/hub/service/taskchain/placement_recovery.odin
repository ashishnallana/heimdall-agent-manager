package taskchain

import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import taskv2 "odin_test:hub/service/taskv2"

// Recovery is a single native engine transaction, rather than separate generic
// fleet and task edits whose guards could race between reads and writes.
recover_placement :: proc(service: ^Taskchain_Service, auth: contracts.Auth_Context, task_id: domain.Task_ID, input: taskv2.Placement_Recovery_Input) -> (domain.Task, bool, domain.Domain_Error) {
	if service == nil || service.engine == nil do return {}, false, domain.domain_error(.Internal_Error, "task engine is not configured")
	return taskv2.recover_placement(service.engine, auth, task_id, input)
}
