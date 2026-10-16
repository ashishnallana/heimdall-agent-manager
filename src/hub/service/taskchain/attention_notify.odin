package taskchain

import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Attention write-through (attention deck v1). Every task and task-comment write
// in this package goes through these helpers, so the card projector hears about
// each change that can put a task into, or take it out of, "awaiting the user's
// validation" -- status, reviewers, or a new comment (the card's excerpt) --
// whichever path made it (HTTP, agent RPC, promotion, chain sync). The
// projector re-reads the task itself; the notification carries ids only.

set_attention_notifier :: proc(service: ^Taskchain_Service, n: ^contracts.Attention_Notifier) {
	if service == nil do return
	service.attention = n
}

save_task :: proc(service: ^Taskchain_Service, task: domain.Task) -> (domain.Task, bool, domain.Domain_Error) {
	saved, ok, err := iface.taskchain_save_task(service.repo, task)
	if ok do contracts.attention_notify(service.attention, string(saved.owner_user_id), contracts.ATTENTION_SOURCE_TASK, string(saved.task_id))
	return saved, ok, err
}

save_comment :: proc(service: ^Taskchain_Service, comment: domain.Task_Comment) -> (domain.Task_Comment, bool, domain.Domain_Error) {
	saved, ok, err := iface.taskchain_save_comment(service.repo, comment)
	if ok do contracts.attention_notify(service.attention, string(saved.owner_user_id), contracts.ATTENTION_SOURCE_TASK, string(saved.task_id))
	return saved, ok, err
}
