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
		kind          = domain.CHAIN_KIND_MIXED_WORK,
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
	return contracts.Auth_Context{kind = .Session, user_id = R9_OWNER}
}

@(test)
test_update_chain_status_completed_cannot_bypass_acceptance :: proc(t: ^testing.T) {
	fx: Fx9
	if !fx9_make(&fx, t, "patch") do return
	defer fx9_free(&fx)

	fx9_chain(&fx, "chain_patch")
	fx9_session(&fx, "srv_patch", domain.Shell_Session_Kind_Server, "chain_patch", "")

    chain, _, _ := iface.taskchain_get_chain(&fx.tc_repo, "chain_patch")
    chain.completion_summary = "previously accepted before reopening"
    _, _, _ = iface.taskchain_save_chain(&fx.tc_repo, chain)
	_, ok, _ := update_chain(&fx.svc, fx9_auth(), "chain_patch", Update_Chain_Input{status = "completed"})

	testing.expect(t, !ok, "generic PATCH cannot complete a reopened chain even with a retained summary")
	testing.expect_value(t, fx9_intent(&fx, "srv_patch"), "")
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
