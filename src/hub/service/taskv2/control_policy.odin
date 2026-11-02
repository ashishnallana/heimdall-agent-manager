package taskv2

import "core:strings"
import domain "odin_test:hub/domain"

// Read-only native preconditions shared by control execution and discovery.
// Availability is a snapshot hint; each verb still rechecks inside its UOW.
task_control_precondition :: proc(svc:^Service,task:domain.Task,actor:Actor,action:string)->domain.Domain_Error {
	if action=="recheck" {_,ok,err:=recheck_authorize(svc,task.owner_user_id,actor,task.chain_id);if !ok do return err;return {}}
	switch action {
	case "hold":
		if domain.task_state_is_terminal(task.state) do return domain.domain_error(.Conflict,"a done or cancelled task cannot be held")
		if task.kind==.Gate do return domain.domain_error(.Conflict,"gates cannot be held")
	case "release":
	case "answer":
		if strings.trim_space(task.blocked_on_json)=="" do return domain.domain_error(.Conflict,"task is not blocked")
		if task_is_held(task) do return domain.domain_error(.Conflict,"task is held; release it with `task release`")
	case "reopen":
		if task.workflow_run_id!="" do return domain.domain_error(.Conflict,"retry the whole workflow run rather than reopening a generated task",`{"code":"workflow_task_managed"}`)
		if !domain.task_state_is_terminal(task.state) do return domain.domain_error(.Conflict,"only a done or cancelled task can be reopened")
	case:return domain.domain_error(.Validation_Failed,"unknown control action")
	}
	if _,ok,err:=work_control_chain(svc,task.owner_user_id,actor,task.chain_id);!ok do return err
	if action=="answer" || action=="reopen" {
		if err:=workflow_require_current_task(svc,task);err.code!=.None do return err
	}
	if action=="reopen" && task.stage_key=="" && task.kind==.Task do return work_require_unconsumed_in_uow(svc,task.chain_id,task.owner_user_id,{kind=domain.WORK_ITEM_TASK,id=string(task.task_id)})
	return {}
}
