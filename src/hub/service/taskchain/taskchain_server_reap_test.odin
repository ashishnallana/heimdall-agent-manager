package taskchain

// REQ-SHELL-9 chain-close server reaping tests — end-to-end through the real SQLite
// repositories.

import "core:fmt"
import "core:os"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import shell_session "odin_test:hub/service/shell_session"

@(private = "file")
R9_OWNER :: "user_req9"

@(private = "file")
Fx9 :: struct {
	conn:      sqlite.Conn,
	tc_impl:   sqlite.Taskchain_Repo_SQLite,
	tc_repo:   iface.Taskchain_Repository,
	ag_impl:   sqlite.Agent_Repo_SQLite,
	ag_repo:   iface.Agent_Repository,
	sh_impl:   sqlite.Shell_Session_Repo_SQLite,
	sh_repo:   iface.Shell_Session_Repository,
	shell_svc: shell_session.Shell_Session_Service,
	svc:       Taskchain_Service,
	clock:     platform.Clock,
	ids:       platform.ID_Generator,
	db_path:   string,
}

@(private = "file")
fx9_make :: proc(fx: ^Fx9, t: ^testing.T, name: string) -> bool {
	fx.db_path = fmt.tprintf("/tmp/test_req9_%s_%d.db", name, os.get_pid())
	os.remove(fx.db_path)

	open_ok: bool
	fx.conn, open_ok, _ = sqlite.open(fx.db_path)
	if !testing.expect(t, open_ok, "sqlite open ok") do return false
	mig_ok, _ := sqlite.run_migrations(&fx.conn)
	if !testing.expect(t, mig_ok, "migrations ok") do return false

	fx.tc_impl = sqlite.Taskchain_Repo_SQLite{conn = &fx.conn}
	fx.tc_repo = sqlite.new_taskchain_repository(&fx.tc_impl, &fx.conn)
	fx.ag_impl = sqlite.Agent_Repo_SQLite{conn = &fx.conn}
	fx.ag_repo = sqlite.new_agent_repository(&fx.ag_impl, &fx.conn)
	fx.sh_impl = sqlite.Shell_Session_Repo_SQLite{conn = &fx.conn}
	fx.sh_repo = sqlite.new_shell_session_repository(&fx.sh_impl, &fx.conn)

	fx.clock = platform.real_clock()
	fx.ids = platform.real_id_generator()
	fx.shell_svc = shell_session.new_shell_session_service(repo = &fx.sh_repo, ids = &fx.ids, clock = &fx.clock)
	fx.svc = new_taskchain_service(&fx.tc_repo, &fx.ag_repo, &fx.clock, &fx.ids)
	set_shell_session_service(&fx.svc, &fx.shell_svc)
	return true
}

@(private = "file")
fx9_free :: proc(fx: ^Fx9) {
	shell_session.shell_session_service_free(&fx.shell_svc)
	sqlite.close(&fx.conn)
	os.remove(fx.db_path)
}

@(private = "file")
fx9_chain :: proc(fx: ^Fx9, chain_id: string, status := domain.Task_Chain_Status.Active) {
	_, _, _ = iface.taskchain_save_chain(&fx.tc_repo, domain.Task_Chain{
		chain_id      = domain.Task_Chain_ID(chain_id),
		owner_user_id = domain.User_ID(R9_OWNER),
		title         = "REQ-SHELL-9 chain",
		publish_state = .Published,
		status        = status,
		kind          = domain.CHAIN_KIND_TICKET,
		created_at    = "2026-09-29T10:00:00Z",
		updated_at    = "2026-09-29T10:00:00Z",
	})
}

@(private = "file")
fx9_task :: proc(fx: ^Fx9, chain_id, task_id: string, state: domain.Task_State) {
	_, _, _ = iface.taskchain_save_task(&fx.tc_repo, domain.Task{
		task_id       = domain.Task_ID(task_id),
		chain_id      = domain.Task_Chain_ID(chain_id),
		owner_user_id = domain.User_ID(R9_OWNER),
		title         = "REQ-SHELL-9 task",
		publish_state = .Published,
		state         = state,
		created_at    = "2026-09-29T10:00:00Z",
		updated_at    = "2026-09-29T10:00:00Z",
	})
}

@(private = "file")
fx9_session :: proc(fx: ^Fx9, session_id, kind, chain_id, agent_id: string) {
	_, _ = iface.shell_session_upsert(&fx.sh_repo, domain.Shell_Session{
		session_id        = session_id,
		owner_user_id     = R9_OWNER,
		bridge_id         = "brg_req9",
		chain_id          = chain_id,
		agent_instance_id = agent_id,
		kind              = kind,
		cmd               = "npm run dev",
		status            = domain.Shell_Session_Status_Running,
		started_at        = "2026-09-29T10:00:00Z",
		created_at        = "2026-09-29T10:00:00Z",
	})
}

@(private = "file")
fx9_intent :: proc(fx: ^Fx9, session_id: string) -> string {
	s, found, _ := iface.shell_session_get(&fx.sh_repo, R9_OWNER, session_id)
	if !found do return "<missing>"
	defer domain.shell_session_destroy(s)
	return fmt.tprintf("%s", s.kill_requested_at)
}

@(private = "file")
fx9_auth :: proc() -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .User_Token, user_id = R9_OWNER}
}

@(test)
test_sync_chain_status_from_tasks_auto_complete_reaps_servers :: proc(t: ^testing.T) {
	fx: Fx9
	if !fx9_make(&fx, t, "auto") do return
	defer fx9_free(&fx)

	fx9_chain(&fx, "chain_auto")
	fx9_task(&fx, "chain_auto", "task_1", .Done)
	fx9_session(&fx, "srv_auto", domain.Shell_Session_Kind_Server, "chain_auto", "")

	chain, ok, _ := sync_chain_status_from_tasks(&fx.svc, "chain_auto", domain.User_ID(R9_OWNER))

	testing.expect(t, ok, "sync ok")
	testing.expect_value(t, chain.status, domain.Task_Chain_Status.Completed)
	testing.expect(t, fx9_intent(&fx, "srv_auto") != "", "auto-completing a chain must reap its servers")
}

@(test)
test_change_chain_status_completed_reaps_only_target_chain_servers :: proc(t: ^testing.T) {
	fx: Fx9
	if !fx9_make(&fx, t, "verb") do return
	defer fx9_free(&fx)

	fx9_chain(&fx, "chain_verb")
	fx9_session(&fx, "srv_verb",  domain.Shell_Session_Kind_Server, "chain_verb",  "")
	fx9_chain(&fx, "chain_other")
	fx9_session(&fx, "srv_other", domain.Shell_Session_Kind_Server, "chain_other", "")

	_, ok, _ := change_chain_status(&fx.svc, fx9_auth(), "chain_verb", .Completed)

	testing.expect(t, ok, "change_chain_status ok")
	testing.expect(t, fx9_intent(&fx, "srv_verb") != "", "the closed chain's server must be reaped")
	testing.expect_value(t, fx9_intent(&fx, "srv_other"), "")
}

@(test)
test_update_chain_status_completed_reaps_servers :: proc(t: ^testing.T) {
	fx: Fx9
	if !fx9_make(&fx, t, "patch") do return
	defer fx9_free(&fx)

	fx9_chain(&fx, "chain_patch")
	fx9_session(&fx, "srv_patch", domain.Shell_Session_Kind_Server, "chain_patch", "")

	_, ok, _ := update_chain(&fx.svc, fx9_auth(), "chain_patch", Update_Chain_Input{status = "completed"})

	testing.expect(t, ok, "update_chain ok")
	testing.expect(t, fx9_intent(&fx, "srv_patch") != "", "a PATCH that closes a chain must reap too")
}

@(test)
test_change_chain_status_completed_spares_runs_and_shells :: proc(t: ^testing.T) {
	fx: Fx9
	if !fx9_make(&fx, t, "kinds") do return
	defer fx9_free(&fx)

	fx9_chain(&fx, "chain_kinds")
	fx9_session(&fx, "srv_k",   domain.Shell_Session_Kind_Server, "chain_kinds", "")
	fx9_session(&fx, "run_k",   domain.Shell_Session_Kind_Run,    "chain_kinds", "inst_1")
	fx9_session(&fx, "shell_k", domain.Shell_Session_Kind_Shell,  "chain_kinds", "")

	_, ok, _ := change_chain_status(&fx.svc, fx9_auth(), "chain_kinds", .Completed)

	testing.expect(t, ok, "change_chain_status ok")
	testing.expect(t, fx9_intent(&fx, "srv_k") != "", "the server is reaped")
	testing.expect_value(t, fx9_intent(&fx, "run_k"), "")
	testing.expect_value(t, fx9_intent(&fx, "shell_k"), "")
}

@(test)
test_change_chain_status_cancelled_and_archived_reap_servers :: proc(t: ^testing.T) {
	fx: Fx9
	if !fx9_make(&fx, t, "canarch") do return
	defer fx9_free(&fx)

	fx9_chain(&fx, "chain_cancel")
	fx9_session(&fx, "srv_cancel", domain.Shell_Session_Kind_Server, "chain_cancel", "")
	fx9_chain(&fx, "chain_archive")
	fx9_session(&fx, "srv_archive", domain.Shell_Session_Kind_Server, "chain_archive", "")

	_, c_ok, _ := change_chain_status(&fx.svc, fx9_auth(), "chain_cancel", .Cancelled)
	_, a_ok, _ := change_chain_status(&fx.svc, fx9_auth(), "chain_archive", .Archived)

	testing.expect(t, c_ok, "cancel ok")
	testing.expect(t, a_ok, "archive ok")
	testing.expect(t, fx9_intent(&fx, "srv_cancel") != "", "a cancelled chain must reap")
	testing.expect(t, fx9_intent(&fx, "srv_archive") != "", "an archived chain must reap")
}

@(test)
test_change_chain_status_reopen_does_not_resurrect_reaped_servers :: proc(t: ^testing.T) {
	fx: Fx9
	if !fx9_make(&fx, t, "reopen") do return
	defer fx9_free(&fx)

	fx9_chain(&fx, "chain_reopen")
	fx9_session(&fx, "srv_reopen", domain.Shell_Session_Kind_Server, "chain_reopen", "")

	_, close_ok, _ := change_chain_status(&fx.svc, fx9_auth(), "chain_reopen", .Completed)
	testing.expect(t, close_ok, "close ok")
	intent_after_close := fx9_intent(&fx, "srv_reopen")
	testing.expect(t, intent_after_close != "", "closed, so reaped")

	_, open_ok, _ := change_chain_status(&fx.svc, fx9_auth(), "chain_reopen", .Active)

	testing.expect(t, open_ok, "reopen ok")
	testing.expect_value(t, fx9_intent(&fx, "srv_reopen"), intent_after_close)
}
