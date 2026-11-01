package sqlite

import "core:testing"
import "core:sync"
import "core:thread"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Reconfiguration_Tx_Worker :: struct {repo:^iface.Agent_Repository,op:domain.Instance_Reconfiguration,initial,started,done,ok:bool}
reconfiguration_tx_worker :: proc(th:^thread.Thread) {
	w:=(^Reconfiguration_Tx_Worker)(th.data)
	sync.atomic_store(&w.started,true)
	stored:domain.Instance_Reconfiguration
	if w.initial {stored,w.ok,_=iface.instance_reconfiguration_begin(w.repo,w.op)} else {stored,w.ok,_=iface.instance_reconfiguration_advance(w.repo,w.op,w.op.revision-1)}
	if w.ok do domain.instance_reconfiguration_destroy(&stored)
	sync.atomic_store(&w.done,true)
}

@(test)
test_reconfiguration_writes_survive_other_request_rollback :: proc(t:^testing.T) {
	for initial in ([]bool{true,false}) {
		conn:Conn;impl:Agent_Repo_SQLite
		repo:=reconfiguration_test_setup(t,&conn,&impl)
		op:=reconfiguration_test_op()
		if !initial {
			stored,ok,err:=iface.instance_reconfiguration_begin(&repo,op)
			if !testing.expect(t,ok,err.message) {close(&conn);return}
			domain.instance_reconfiguration_destroy(&stored)
			op.phase=.Stopping;op.revision=2
		}
		factory_impl:SQLite_Unit_Of_Work_Factory
		factory:=new_unit_of_work_factory(&factory_impl,&conn,nil)
		uow,ok,err:=iface.unit_of_work_begin(&factory)
		if !testing.expect(t,ok,err.message) {close(&conn);return}
		w:=Reconfiguration_Tx_Worker{repo=&repo,op=op,initial=initial}
		th:=thread.create(reconfiguration_tx_worker);th.data=&w;thread.start(th)
		for !sync.atomic_load(&w.started) do time.sleep(time.Millisecond)
		time.sleep(60*time.Millisecond)
		testing.expect(t,!sync.atomic_load(&w.done),"native move write must wait for the unrelated request transaction")
		iface.unit_of_work_rollback(&uow)
		thread.join(th);thread.destroy(th)
		testing.expect(t,w.ok,"native move write commits after the other request rolls back")
		stored,found,_:=iface.instance_reconfiguration_get(&repo,"owner","inst_move","key_move")
		testing.expect(t,found,"request rollback must not erase native move progress")
		if found {testing.expect_value(t,stored.phase,op.phase);domain.instance_reconfiguration_destroy(&stored)}
		close(&conn)
	}
}

reconfiguration_test_setup :: proc(t: ^testing.T, conn: ^Conn, impl: ^Agent_Repo_SQLite) -> iface.Agent_Repository {
	opened, ok := tmpl_clone_migrated(t)
	conn^ = opened
	if !ok do return {}
	repo := new_agent_repository(impl, conn)
	_, saved, save_err := iface.agent_save_instance(&repo, domain.Agent_Instance{agent_instance_id = "inst_move", owner_user_id = "owner", agent_id = "agent", bridge_id = "source", provider = "codex", model = "smart", project_id = "project_old", project_path = "/old", conversation_id = "chat_move", runtime_status = "running", created_at = "2026-10-10T10:00:00Z", updated_at = "2026-10-10T10:00:00Z"})
	testing.expect(t, saved, save_err.message)
	testing.expect(t, exec(conn, "INSERT INTO chat_conversations (conversation_id, owner_user_id, agent_id, agent_instance_id, project_id, created_at, updated_at) VALUES ('chat_move','owner','agent','inst_move','project_old','2026-10-10T10:00:00Z','2026-10-10T10:00:00Z');"))
	return repo
}
reconfiguration_test_op :: proc() -> domain.Instance_Reconfiguration {
	return domain.Instance_Reconfiguration{operation_id = "op_move", owner_user_id = "owner", agent_instance_id = "inst_move", conversation_id = "chat_move", actor_user_id = "owner", idempotency_key = "key_move", revision = 1, phase = .Prepared, source = domain.Instance_Configuration{bridge_id = "source", bridge_label = "Laptop", project_id = "project_old", project_path = "/old", provider = "codex", model = "smart"}, destination = domain.Instance_Configuration{bridge_id = "destination", bridge_label = "Server", project_id = "project_new", project_path = "/new", provider = "claude", model = "normal"}, stop_command_id = "stop_move", launch_command_id = "launch_move", launch_epoch = "epoch_move", created_at = "2026-10-10T10:01:00Z", updated_at = "2026-10-10T10:01:00Z"}
}

@(test)
test_reconfiguration_idempotency_exclusivity_and_revision :: proc(t: ^testing.T) {
	conn: Conn; impl: Agent_Repo_SQLite
	repo := reconfiguration_test_setup(t, &conn, &impl)
	defer close(&conn)
	op := reconfiguration_test_op()
	created, ok, err := iface.instance_reconfiguration_begin(&repo, op)
	if !testing.expect(t, ok, err.message) do return
	defer domain.instance_reconfiguration_destroy(&created)
	retry, retried, _ := iface.instance_reconfiguration_begin(&repo, op)
	testing.expect(t, retried, "same request returns original operation")
	testing.expect_value(t, retry.operation_id, op.operation_id)
	domain.instance_reconfiguration_destroy(&retry)
	different := op; different.destination.model = "other"
	_, accepted, _ := iface.instance_reconfiguration_begin(&repo, different)
	testing.expect(t, !accepted, "same key cannot change destination")
	concurrent := op; concurrent.operation_id = "op_other"; concurrent.idempotency_key = "other"
	_, accepted, _ = iface.instance_reconfiguration_begin(&repo, concurrent)
	testing.expect(t, !accepted, "one active operation per instance")
	wrong_owner := op; wrong_owner.owner_user_id = "another"; wrong_owner.operation_id = "op_unauthorized"; wrong_owner.idempotency_key = "unauthorized"
	_, accepted, _ = iface.instance_reconfiguration_begin(&repo, wrong_owner)
	testing.expect(t, !accepted, "owner must match instance")
	next := op; next.phase = .Stopping; next.revision = 2
	advanced: domain.Instance_Reconfiguration
	advanced, accepted, err = iface.instance_reconfiguration_advance(&repo, next, 1)
	testing.expect(t, accepted, err.message)
	domain.instance_reconfiguration_destroy(&advanced)
	_, accepted, _ = iface.instance_reconfiguration_advance(&repo, next, 1)
	testing.expect(t, !accepted, "stale progress cannot overwrite newer progress")
}

@(test)
test_reconfiguration_commit_requires_stop_and_changes_scope_atomically :: proc(t: ^testing.T) {
	conn: Conn; impl: Agent_Repo_SQLite
	repo := reconfiguration_test_setup(t, &conn, &impl)
	defer close(&conn)
	op := reconfiguration_test_op()
	initial, ok, err := iface.instance_reconfiguration_begin(&repo, op)
	if !testing.expect(t, ok, err.message) do return
	domain.instance_reconfiguration_destroy(&initial)
	invalid := op; invalid.phase = .Launching; invalid.revision = 2; invalid.destination_committed = true
	_, accepted, _ := iface.instance_reconfiguration_advance(&repo, invalid, 1)
	testing.expect(t, !accepted, "cannot skip stop confirmation")
	op.phase = .Source_Stopped; op.source_stopped = true; op.revision = 2
	stopped: domain.Instance_Reconfiguration
	stopped, accepted, err = iface.instance_reconfiguration_advance(&repo, op, 1)
	if !testing.expect(t, accepted, err.message) do return
	domain.instance_reconfiguration_destroy(&stopped)
	op.phase = .Launching; op.destination_committed = true; op.revision = 3
	committed: domain.Instance_Reconfiguration
	committed, accepted, err = iface.instance_reconfiguration_advance(&repo, op, 2)
	if !testing.expect(t, accepted, err.message) do return
	domain.instance_reconfiguration_destroy(&committed)
	inst, found, _ := iface.agent_get_instance(&repo, "inst_move")
	testing.expect(t, found)
	defer domain.agent_instance_destroy(&inst)
	testing.expect_value(t, inst.bridge_id, "destination")
	testing.expect_value(t, string(inst.project_id), "project_new")
	testing.expect_value(t, inst.project_path, "/new")
	testing.expect_value(t, inst.launch_epoch, "epoch_move")
	testing.expect_value(t, inst.configuration_revision, 1)
	testing.expect_value(t, inst.last_applied_seq, 0)
	testing.expect_value(t, inst.run_count, 1)
	content_impl: Content_Repo_SQLite
	content_repo := new_content_repository(&content_impl, &conn)
	conversation: domain.Chat_Conversation
	conversation, found, _ = iface.content_get_conversation(&content_repo, "chat_move")
	testing.expect(t, found)
	testing.expect_value(t, conversation.project_id, "project_new")
	// A generic heartbeat save cannot undo the committed bridge or epoch.
	stale := inst; stale.bridge_id = "source"; stale.launch_epoch = ""; stale.configuration_revision = 0
	_, _, _ = iface.agent_save_instance(&repo, stale)
	reloaded, _, _ := iface.agent_get_instance(&repo, "inst_move")
	testing.expect_value(t, reloaded.bridge_id, "destination")
	testing.expect_value(t, reloaded.launch_epoch, "epoch_move")
	domain.agent_instance_destroy(&reloaded)
}

@(test)
test_reconfiguration_recovery_blocks_input_and_emits_durable_events :: proc(t: ^testing.T) {
	conn: Conn; impl: Agent_Repo_SQLite
	repo := reconfiguration_test_setup(t, &conn, &impl)
	defer close(&conn)
	op := reconfiguration_test_op()
	stored, accepted, _ := iface.instance_reconfiguration_begin(&repo, op)
	if !testing.expect(t, accepted) do return
	domain.instance_reconfiguration_destroy(&stored)
	op.phase = .Stopping; op.revision = 2
	stored, accepted, _ = iface.instance_reconfiguration_advance(&repo, op, 1)
	testing.expect(t, accepted); domain.instance_reconfiguration_destroy(&stored)
	op.phase = .Recovery_Required; op.revision = 3; op.failure_code = "stop_unconfirmed"
	stored, accepted, _ = iface.instance_reconfiguration_advance(&repo, op, 2)
	testing.expect(t, accepted)
	testing.expect(t, domain.instance_reconfiguration_blocks_input(stored))
	domain.instance_reconfiguration_destroy(&stored)
	active, err := iface.instance_reconfiguration_list(&repo, "owner", "inst_move", true)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, len(active), 1)
	for &record in active do domain.instance_reconfiguration_destroy(&record)
	delete(active)
	content_impl: Content_Repo_SQLite
	content_repo := new_content_repository(&content_impl, &conn)
	messages, _ := iface.content_list_messages(&content_repo, "chat_move", "owner", 20, "")
	testing.expect_value(t, len(messages), 2)
	for message in messages do testing.expect_value(t, message.message_type, "configuration_change")
}
