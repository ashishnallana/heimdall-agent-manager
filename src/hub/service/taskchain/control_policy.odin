package taskchain

import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import tv2 "odin_test:hub/service/taskv2"

task_publish_precondition :: proc(s:^Taskchain_Service,auth:contracts.Auth_Context,task:domain.Task)->domain.Domain_Error {
	if err:=require_manual_task(task);err.code!=.None do return err
	chain,ok,err:=get_chain_for_read(s,auth,task.chain_id)
	if !ok do return err
	if chain.publish_state!=.Published do return domain.domain_error(.Conflict,"cannot publish task before chain is published")
	if task.publish_state!=.Draft do return domain.domain_error(.Conflict,"task is already published")
	if auth.kind==.Instance_Token && !is_chain_coordinator(s,chain,auth.agent_instance_id) do return domain.domain_error(.Forbidden,"only the chain coordinator or the owner can publish a task")
	if missing:=brief_publish_problems(s,chain,task);len(missing)>0 {
		problems:=make(map[string][]string,context.temp_allocator);problems[string(task.task_id)]=missing
		return publish_problems_error(problems)
	}
	return {}
}

task_control_actions :: proc(s:^Taskchain_Service,auth:contracts.Auth_Context,task:domain.Task)->([]string,domain.Domain_Error) {
	if string(task.owner_user_id)!=auth.user_id do return nil,domain.domain_error(.Not_Found,"task not found")
	out:=make([dynamic]string,context.temp_allocator)
	if s.engine==nil do return out[:],{}
	if task_publish_precondition(s,auth,task).code==.None do append(&out,"publish")
	// The native cancel verb is owner-scoped, manual-task only, nonterminal.
	if require_manual_task(task).code==.None && !domain.task_state_is_terminal(task.state) do append(&out,"cancel")
	for action in ([]string{"hold","release","reopen","answer","recheck"}) do if tv2.task_control_precondition(s.engine,task,engine_actor(auth),action).code==.None do append(&out,action)
	return out[:],{}
}
