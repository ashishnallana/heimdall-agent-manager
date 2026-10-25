package taskchain

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import taskv2 "odin_test:hub/service/taskv2"
import jsonx "odin_test:lib/jsonx"

// REQ-TV2-4 brief contracts: top-level merge, null-clear, replace, one schema,
// leased refusals that name the fields, and reviewer identity.

Brief_Contract_Fixture :: struct {
	db_path: string,
	conn:    sqlite.Conn,
	tc_impl: sqlite.Taskchain_Repo_SQLite,
	ag_impl: sqlite.Agent_Repo_SQLite,
	repo:    iface.Taskchain_Repository,
	agents:  iface.Agent_Repository,
	clock:   platform.Clock,
	ids:     platform.ID_Generator,
	svc:     Taskchain_Service,
	chain:   domain.Task_Chain,
	owner:   contracts.Auth_Context,
}

brief_contract_open :: proc(t: ^testing.T, f: ^Brief_Contract_Fixture, name: string) -> bool {
	f.db_path = fmt.tprintf("%s/.cache/heimdall-tests/brief_contract_%s_%d.db", os.get_env("HOME", context.temp_allocator), name, os.get_pid())
	os.remove(f.db_path)
	ok: bool
	f.conn, ok, _ = sqlite.open(f.db_path)
	if !testing.expect(t, ok, "open database") do return false
	_, _ = sqlite.run_migrations(&f.conn)
	f.repo = sqlite.new_taskchain_repository(&f.tc_impl, &f.conn)
	f.agents = sqlite.new_agent_repository(&f.ag_impl, &f.conn)
	f.clock = platform.real_clock()
	f.ids = platform.real_id_generator()
	f.svc = new_taskchain_service(&f.repo, &f.agents, &f.clock, &f.ids)
	f.owner = contracts.Auth_Context{kind = .User_Token, user_id = "owner"}
	now := platform.clock_now(&f.clock)
	for id in ([]string{"agt_worker", "agt_rev", "agt_rev2"}) {
		_, _, _ = iface.agent_save(&f.agents, domain.Agent{agent_id = id, owner_user_id = "owner", name = id, slug = id, created_at = now, updated_at = now})
	}
	chain, cok, cerr := create_chain(&f.svc, f.owner, Create_Chain_Input{title = "brief contracts"})
	if !testing.expectf(t, cok, "create chain: %s", cerr.message) do return false
	f.chain = chain
	return true
}

brief_contract_close :: proc(f: ^Brief_Contract_Fixture) {
	sqlite.close(&f.conn)
	os.remove(f.db_path)
}

FULL_BRIEF :: `{"goal":"original goal","acceptance":["a1","a2"],"inputs":["output:x"],"review_roles":[],"assignee":"agt_worker","reviewers":["agt_rev"],"budget":{"max_attempts":3},"output":"findings.v1"}`

@(test)
test_brief_goal_only_update_preserves_other_fields :: proc(t: ^testing.T) {
	f: Brief_Contract_Fixture
	if !brief_contract_open(t, &f, "goal_only") do return
	defer brief_contract_close(&f)
	task, ok, err := create_task(&f.svc, f.owner, Create_Task_Input{chain_id = f.chain.chain_id, title = "t", brief_json = FULL_BRIEF, requires_user_approval = true, has_requires_user_approval = true})
	if !testing.expectf(t, ok, "create: %s", err.message) do return
	updated, uok, uerr := update_task(&f.svc, f.owner, task.task_id, Update_Task_Input{brief_json = `{"goal":"new goal"}`})
	if !testing.expectf(t, uok, "goal-only update: %s", uerr.message) do return
	b := updated.brief_json
	testing.expect_value(t, jsonx.extract_string(b, "goal", "", true, context.temp_allocator), "new goal")
	testing.expect_value(t, len(jsonx.extract_string_array(b, "acceptance", true)), 2)
	testing.expect_value(t, jsonx.extract_string(b, "assignee", "", true, context.temp_allocator), "agt_worker")
	testing.expect_value(t, len(taskv2.brief_named_reviewers(b, context.temp_allocator)), 1)
	testing.expect(t, jsonx.has_key(b, "review_roles", top_level_only = true), "review_roles kept")
	testing.expect_value(t, len(jsonx.extract_string_array(b, "inputs", true)), 1)
	testing.expect_value(t, jsonx.extract_string(b, "output", "", true, context.temp_allocator), "findings.v1")
	_, has_budget := jsonx.extract_raw_object(b, "budget", true, context.temp_allocator)
	testing.expect(t, has_budget, "budget kept")
	testing.expect(t, updated.requires_user_approval, "requires_user_approval kept")
	// Read back the stored row, not just the response.
	stored, _, _ := iface.taskchain_get_task(&f.repo, task.task_id)
	testing.expect_value(t, stored.brief_json, updated.brief_json)
}

@(test)
test_brief_null_clears_and_replace_brief_replaces :: proc(t: ^testing.T) {
	f: Brief_Contract_Fixture
	if !brief_contract_open(t, &f, "null_replace") do return
	defer brief_contract_close(&f)
	task, ok, err := create_task(&f.svc, f.owner, Create_Task_Input{chain_id = f.chain.chain_id, title = "t", brief_json = FULL_BRIEF})
	if !testing.expectf(t, ok, "create: %s", err.message) do return
	cleared, cok, cerr := update_task(&f.svc, f.owner, task.task_id, Update_Task_Input{brief_json = `{"budget":null,"reviewers":null}`})
	if !testing.expectf(t, cok, "null clear: %s", cerr.message) do return
	testing.expect(t, !jsonx.has_key(cleared.brief_json, "budget", top_level_only = true), "budget removed by null")
	testing.expect(t, !jsonx.has_key(cleared.brief_json, "reviewers", top_level_only = true), "reviewers removed by null")
	testing.expect_value(t, jsonx.extract_string(cleared.brief_json, "goal", "", true, context.temp_allocator), "original goal")
	replaced, rok, rerr := update_task(&f.svc, f.owner, task.task_id, Update_Task_Input{brief_json = `{"goal":"only","acceptance":["x"]}`, replace_brief = true})
	if !testing.expectf(t, rok, "replace: %s", rerr.message) do return
	testing.expect(t, !jsonx.has_key(replaced.brief_json, "assignee", top_level_only = true), "replace drops assignee")
	testing.expect(t, !jsonx.has_key(replaced.brief_json, "inputs", top_level_only = true), "replace drops inputs")
	testing.expect_value(t, jsonx.extract_string(replaced.brief_json, "goal", "", true, context.temp_allocator), "only")
}

@(test)
test_brief_file_reviewers_persist_and_unknown_keys_rejected :: proc(t: ^testing.T) {
	f: Brief_Contract_Fixture
	if !brief_contract_open(t, &f, "reviewers_unknown") do return
	defer brief_contract_close(&f)
	task, ok, err := create_task(&f.svc, f.owner, Create_Task_Input{chain_id = f.chain.chain_id, title = "t", brief_json = `{"goal":"g","acceptance":["a"]}`})
	if !testing.expectf(t, ok, "create: %s", err.message) do return
	// reviewers in the brief (the --brief-file shape) persist.
	withrev, wok, werr := update_task(&f.svc, f.owner, task.task_id, Update_Task_Input{brief_json = `{"reviewers":["agt_rev","agt_rev2"]}`})
	if !testing.expectf(t, wok, "brief reviewers: %s", werr.message) do return
	stored, _, _ := iface.taskchain_get_task(&f.repo, task.task_id)
	testing.expect_value(t, len(taskv2.brief_named_reviewers(stored.brief_json, context.temp_allocator)), 2)
	testing.expect_value(t, withrev.brief_json, stored.brief_json)
	// Unknown keys: 400 listing them, on update and on create; nothing saved.
	_, bad, berr := update_task(&f.svc, f.owner, task.task_id, Update_Task_Input{brief_json = `{"goal":"g2","descripton":"typo","extra":1}`})
	testing.expect(t, !bad && berr.code == .Validation_Failed, "unknown key rejected on update")
	testing.expect(t, strings.contains(berr.details_json, `"unknown_brief_fields":["descripton","extra"]`), berr.details_json)
	after, _, _ := iface.taskchain_get_task(&f.repo, task.task_id)
	testing.expect_value(t, jsonx.extract_string(after.brief_json, "goal", "", true, context.temp_allocator), "g")
	_, cbad, cberr := create_task(&f.svc, f.owner, Create_Task_Input{chain_id = f.chain.chain_id, title = "t2", brief_json = `{"goal":"g","bogus":true}`})
	testing.expect(t, !cbad && cberr.code == .Validation_Failed && strings.contains(cberr.details_json, "unknown_brief_fields"), "unknown key rejected on create")
	// The removed verify keys are still accepted and dropped, not "unknown".
	_, vok, verr := update_task(&f.svc, f.owner, task.task_id, Update_Task_Input{brief_json = `{"goal":"g3","verify":"make"}`})
	testing.expectf(t, vok, "legacy verify key is not unknown: %s", verr.message)
}

@(test)
test_brief_instance_reviewer_rejected_explicitly :: proc(t: ^testing.T) {
	f: Brief_Contract_Fixture
	if !brief_contract_open(t, &f, "inst_reviewer") do return
	defer brief_contract_close(&f)
	_, ok, err := create_task(&f.svc, f.owner, Create_Task_Input{chain_id = f.chain.chain_id, title = "t", brief_json = `{"goal":"g","acceptance":["a"],"reviewers":["inst_18e1abc"]}`})
	testing.expect(t, !ok && err.code == .Validation_Failed, "inst_ reviewer rejected on create")
	testing.expect(t, strings.contains(err.details_json, `"code":"reviewer_must_be_agent_id"`) && strings.contains(err.details_json, "inst_18e1abc"), err.details_json)
	task, tok, terr := create_task(&f.svc, f.owner, Create_Task_Input{chain_id = f.chain.chain_id, title = "t", brief_json = `{"goal":"g","acceptance":["a"]}`})
	if !testing.expectf(t, tok, "create: %s", terr.message) do return
	_, uok, uerr := update_task(&f.svc, f.owner, task.task_id, Update_Task_Input{reviewer_agent_ids = []string{"inst_18e1abc"}, has_reviewers = true})
	testing.expect(t, !uok && strings.contains(uerr.details_json, "reviewer_must_be_agent_id"), "inst_ reviewer flag rejected on update")
	_, nok, nerr := update_task(&f.svc, f.owner, task.task_id, Update_Task_Input{brief_json = `{"reviewers":["agt_nobody"]}`})
	testing.expect(t, !nok && strings.contains(nerr.details_json, "reviewer_must_be_agent_id"), "unknown agent reviewer rejected")
}

@(test)
test_brief_leased_edit_lists_fields :: proc(t: ^testing.T) {
	f: Brief_Contract_Fixture
	if !brief_contract_open(t, &f, "leased") do return
	defer brief_contract_close(&f)
	task, ok, err := create_task(&f.svc, f.owner, Create_Task_Input{chain_id = f.chain.chain_id, title = "t", brief_json = FULL_BRIEF})
	if !testing.expectf(t, ok, "create: %s", err.message) do return
	now := platform.clock_now(&f.clock)
	_, lok, lerr := iface.taskchain_save_lease(&f.repo, domain.Task_Lease{lease_id = "lease_held", task_id = task.task_id, chain_id = f.chain.chain_id, owner_user_id = "owner", holder_instance_id = "holder", attempt_no = 1, kind = domain.LEASE_KIND_WORK, delivery = "inline", granted_at = now, confirmed_at = now, expires_at = "2099-01-01T00:00:00Z", hard_deadline_at = "2099-01-01T01:00:00Z"})
	if !testing.expectf(t, lok, "seed lease: %s", lerr.message) do return
	_, bad, berr := update_task(&f.svc, f.owner, task.task_id, Update_Task_Input{brief_json = `{"goal":"changed","budget":null,"acceptance":["ok"]}`})
	testing.expect(t, !bad && berr.code == .Conflict, "leased scope edit refused")
	testing.expect(t, strings.contains(berr.details_json, `"fields":["brief.budget","brief.goal"]`), berr.details_json)
	testing.expect(t, strings.contains(berr.details_json, `"allowed":["brief.acceptance"`), berr.details_json)
	testing.expect(t, strings.contains(berr.message, "REQ-TV2-5"), berr.message)
	_, tbad, tberr := update_task(&f.svc, f.owner, task.task_id, Update_Task_Input{title = "renamed", has_assignee = true, assignee_agent_id = "agt_rev"})
	testing.expect(t, !tbad && strings.contains(tberr.details_json, `"fields":["title","brief.assignee"]`), tberr.details_json)
	// acceptance still edits; resending an unchanged value is not an edit.
	same, sok, serr := update_task(&f.svc, f.owner, task.task_id, Update_Task_Input{brief_json = `{"acceptance":["b1"],"goal":"original goal"}`})
	if !testing.expectf(t, sok, "acceptance patch while leased: %s", serr.message) do return
	testing.expect_value(t, len(jsonx.extract_string_array(same.brief_json, "acceptance", true)), 1)
	testing.expect_value(t, jsonx.extract_string(same.brief_json, "assignee", "", true, context.temp_allocator), "agt_worker")
}
