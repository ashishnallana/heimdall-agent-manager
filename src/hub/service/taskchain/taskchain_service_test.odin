package taskchain

import "core:fmt"
import "core:os"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"

@(test)
test_valid_chain_transitions_with_archived :: proc(t: ^testing.T) {
	// Active transitions
	testing.expect(t, valid_chain_transition(.Active, .Archived), "Active -> Archived must be valid")
	testing.expect(t, valid_chain_transition(.Active, .Completed), "Active -> Completed must be valid")
	testing.expect(t, valid_chain_transition(.Active, .Cancelled), "Active -> Cancelled must be valid")
	testing.expect(t, valid_chain_transition(.Active, .Active), "Active -> Active must be valid")

	// Completed transitions
	testing.expect(t, valid_chain_transition(.Completed, .Archived), "Completed -> Archived must be valid")
	testing.expect(t, valid_chain_transition(.Completed, .Active), "Completed -> Active must be valid")
	testing.expect(t, valid_chain_transition(.Completed, .Completed), "Completed -> Completed must be valid")
	testing.expect(t, !valid_chain_transition(.Completed, .Cancelled), "Completed -> Cancelled must be invalid")

	// Cancelled transitions
	testing.expect(t, valid_chain_transition(.Cancelled, .Archived), "Cancelled -> Archived must be valid")
	testing.expect(t, valid_chain_transition(.Cancelled, .Cancelled), "Cancelled -> Cancelled must be valid")
	testing.expect(t, !valid_chain_transition(.Cancelled, .Active), "Cancelled -> Active must be invalid")
	testing.expect(t, !valid_chain_transition(.Cancelled, .Completed), "Cancelled -> Completed must be invalid")

	// Archived transitions
	testing.expect(t, valid_chain_transition(.Archived, .Active), "Archived -> Active (restore) must be valid")
	testing.expect(t, valid_chain_transition(.Archived, .Archived), "Archived -> Archived must be valid")
	testing.expect(t, !valid_chain_transition(.Archived, .Completed), "Archived -> Completed must be invalid")
	testing.expect(t, !valid_chain_transition(.Archived, .Cancelled), "Archived -> Cancelled must be invalid")
}

@(test)
test_chain_status_from_string_archived :: proc(t: ^testing.T) {
	testing.expect_value(t, chain_status_from_string("archived"), domain.Task_Chain_Status.Archived)
	testing.expect_value(t, chain_status_from_string("active"), domain.Task_Chain_Status.Active)
	testing.expect_value(t, chain_status_from_string("completed"), domain.Task_Chain_Status.Completed)
	testing.expect_value(t, chain_status_from_string("cancelled"), domain.Task_Chain_Status.Cancelled)
	testing.expect_value(t, chain_status_from_string("unknown"), domain.Task_Chain_Status.Active)
}

// Task System v2 §0: chain kind vocabulary is {ticket, workflow}. The pre-v2
// default "team_work" is accepted as an alias for ticket at create time only;
// "" means ticket; anything else is a validation failure.
@(test)
test_all_chain_creations_use_mixed_work :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_chain_kind_alias_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, _ := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	defer sqlite.close(&conn)
	mig_ok, _ := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")

	tc_impl := sqlite.Taskchain_Repo_SQLite{conn = &conn}
	tc_repo := sqlite.new_taskchain_repository(&tc_impl, &conn)
	ag_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	ag_repo := sqlite.new_agent_repository(&ag_impl, &conn)
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	svc := new_taskchain_service(&tc_repo, &ag_repo, &clock, &ids)

	auth := contracts.Auth_Context{kind = .User_Token, user_id = "user_kind_alias"}

	Case :: struct { input, want: string }
	cases := [?]Case{
		{"mixed_work", domain.CHAIN_KIND_MIXED_WORK},
		{"", domain.CHAIN_KIND_MIXED_WORK},
	}
	for c in cases {
		chain, ok, err := create_chain(&svc, auth, Create_Chain_Input{title = "kind alias", kind = c.input})
		testing.expectf(t, ok, "create_chain(kind=%q) must succeed: %v", c.input, err.message)
		testing.expectf(t, chain.kind == c.want, "kind %q: stored %q, want %q", c.input, chain.kind, c.want)
		persisted, got, _ := iface.taskchain_get_chain(&tc_repo, chain.chain_id)
		testing.expect(t, got, "chain must be persisted")
		testing.expectf(t, persisted.kind == c.want, "kind %q: persisted %q, want %q", c.input, persisted.kind, c.want)
	}

	_, bad_ok, bad_err := create_chain(&svc, auth, Create_Chain_Input{title = "kind alias", kind = "swarm"})
	testing.expect(t, !bad_ok, "unknown chain kind must be rejected")
	testing.expect_value(t, bad_err.code, domain.Error_Code.Validation_Failed)
}
