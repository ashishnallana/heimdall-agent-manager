package card

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import iface "odin_test:hub/repository/iface"
import issue_service "odin_test:hub/service/issue"
import content_service "odin_test:hub/service/content"

@(test)
test_validate_card_operations_issue_create :: proc(t: ^testing.T) {
	// Valid with title only
	ok, reason := validate_card_operations(`[{"op":"issue.create","title":"Valid Issue"}]`)
	testing.expect(t, ok, "issue.create with title should validate")
	testing.expect_value(t, reason, "")

	// Valid with title, description, and scope
	ok2, reason2 := validate_card_operations(`[{"op":"issue.create","title":"Valid Issue","description":"details","scope":"project"}]`)
	testing.expect(t, ok2, "issue.create with all fields should validate")
	testing.expect_value(t, reason2, "")

	// Missing title
	ok3, reason3 := validate_card_operations(`[{"op":"issue.create"}]`)
	testing.expect(t, !ok3, "issue.create without title should fail")
	testing.expect(t, strings.contains(reason3, "missing required field \"title\""), "error should specify missing title")

	// Empty title
	ok4, reason4 := validate_card_operations(`[{"op":"issue.create","title":""}]`)
	testing.expect(t, !ok4, "issue.create with empty title should fail")
	testing.expect(t, strings.contains(reason4, "missing required field \"title\""), "error should specify missing title")
}

@(test)
test_validate_card_operations_memory_approve :: proc(t: ^testing.T) {
	// Valid with memory_id
	ok, reason := validate_card_operations(`[{"op":"memory.approve","memory_id":"mem_test_1"}]`)
	testing.expect(t, ok, "memory.approve with memory_id should validate")
	testing.expect_value(t, reason, "")

	// Missing memory_id
	ok2, reason2 := validate_card_operations(`[{"op":"memory.approve"}]`)
	testing.expect(t, !ok2, "memory.approve without memory_id should fail")
	testing.expect(t, strings.contains(reason2, "missing required field \"memory_id\""), "error should specify missing memory_id")
}

@(test)
test_accept_card_executes_issue_create :: proc(t: ^testing.T) {
	db_path := "/tmp/test_card_service_issue.db"
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	card_impl := sqlite.Card_Repo_SQLite{conn = &conn}
	card_repo := sqlite.new_card_repository(&card_impl, &conn)

	issue_impl := sqlite.Issue_Repo_SQLite{conn = &conn}
	issue_repo := sqlite.new_issue_repository(&issue_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()

	iss_svc := issue_service.new_issue_service(&issue_repo, &clock, &ids)

	card_svc := new_card_service(
		cards       = &card_repo,
		projects    = nil,
		taskchains  = nil,
		content     = nil,
		project_svc = nil,
		agents      = nil,
		uow_factory = nil,
		clock       = &clock,
		ids         = &ids,
		issues      = &iss_svc,
	)

	auth := contracts.Auth_Context{
		kind    = .Session,
		user_id = "test_user_owner",
	}

	card_in := Card_Input{
		project_id      = "proj_test",
		title           = "Propose creating blocker issue",
		scope           = "project",
		provider        = "agent",
		operations_json = `[{"op":"issue.create","title":"Crash on startup","description":"Null pointer in main","scope":"project"}]`,
	}

	created_card, cr_ok, cr_err := create_card(&card_svc, auth, card_in)
	testing.expect(t, cr_ok, "create card should succeed")
	testing.expect_value(t, cr_err.code, domain.Error_Code.None)
	testing.expect_value(t, created_card.status, domain.CARD_STATUS_PENDING)

	// Now accept the card
	accepted_card, ac_ok, ac_err := accept_card(&card_svc, auth, created_card.card_id)
	testing.expect(t, ac_ok, "accept card should succeed")
	testing.expect_value(t, ac_err.code, domain.Error_Code.None)
	testing.expect_value(t, accepted_card.status, domain.CARD_STATUS_ACCEPTED)

	// Verify the issue was created in issue repo
	filter := issue_service.Issue_Filter_Input{}
	issues, lerr := issue_service.list_issues(&iss_svc, auth, filter)
	testing.expect_value(t, lerr.code, domain.Error_Code.None)
	testing.expect_value(t, len(issues), 1)
	if len(issues) == 1 {
		testing.expect_value(t, issues[0].title, "Crash on startup")
		testing.expect_value(t, issues[0].description, "Null pointer in main")
		testing.expect_value(t, string(issues[0].owner_user_id), "test_user_owner")
	}
}

@(test)
test_accept_card_executes_memory_approve :: proc(t: ^testing.T) {
	db_path := "/tmp/test_card_service_memory.db"
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	card_impl := sqlite.Card_Repo_SQLite{conn = &conn}
	card_repo := sqlite.new_card_repository(&card_impl, &conn)

	content_impl := sqlite.Content_Repo_SQLite{conn = &conn}
	content_repo := sqlite.new_content_repository(&content_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()

	cnt_svc := content_service.new_content_service(&content_repo, nil, nil, nil, nil, &clock, &ids)

	card_svc := new_card_service(
		cards       = &card_repo,
		projects    = nil,
		taskchains  = nil,
		content     = &cnt_svc,
		project_svc = nil,
		agents      = nil,
		uow_factory = nil,
		clock       = &clock,
		ids         = &ids,
	)

	auth := contracts.Auth_Context{
		kind    = .Session,
		user_id = "test_user_owner",
	}

	// 1. Create a proposed memory
	mem_in := content_service.Memory_Input{
		title  = "Build flag habit",
		body   = "Always use -collection:odin_test=src",
		type   = .Habit,
		status = "proposed",
	}
	mem, mem_ok, mem_err := content_service.create_memory(&cnt_svc, auth, mem_in)
	testing.expect(t, mem_ok, "memory creation should succeed")
	testing.expect_value(t, mem_err.code, domain.Error_Code.None)
	testing.expect_value(t, mem.status, "proposed")

	// 2. Create card with memory.approve op and guard
	ops_json := strings.concatenate({"[{\"op\":\"memory.approve\",\"memory_id\":\"", mem.memory_id, "\"}]"})
	guard_json := strings.concatenate({"{\"memory_id\":\"", mem.memory_id, "\",\"expected_status\":\"proposed\"}"})

	card_in := Card_Input{
		project_id      = "proj_test",
		title           = "Approve build flag habit",
		provider        = "curator",
		operations_json = ops_json,
		guard_json      = guard_json,
	}

	created_card, cr_ok, cr_err := create_card(&card_svc, auth, card_in)
	testing.expect(t, cr_ok, "card creation should succeed")
	testing.expect_value(t, cr_err.code, domain.Error_Code.None)

	// 3. Accept the card
	accepted_card, ac_ok, ac_err := accept_card(&card_svc, auth, created_card.card_id)
	testing.expect(t, ac_ok, "accept card should succeed")
	testing.expect_value(t, ac_err.code, domain.Error_Code.None)
	testing.expect_value(t, accepted_card.status, domain.CARD_STATUS_ACCEPTED)

	// 4. Verify memory status changed to active
	got_mem, got_ok, got_err := content_service.get_memory(&cnt_svc, auth, mem.memory_id)
	testing.expect(t, got_ok, "get memory should succeed")
	testing.expect_value(t, got_err.code, domain.Error_Code.None)
	testing.expect_value(t, got_mem.status, "active")
}

@(test)
test_card_default_ttl_24h :: proc(t: ^testing.T) {
	db_path := "/tmp/test_card_service_ttl.db"
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	card_impl := sqlite.Card_Repo_SQLite{conn = &conn}
	card_repo := sqlite.new_card_repository(&card_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()

	card_svc := new_card_service(
		cards       = &card_repo,
		projects    = nil,
		taskchains  = nil,
		content     = nil,
		project_svc = nil,
		agents      = nil,
		uow_factory = nil,
		clock       = &clock,
		ids         = &ids,
	)

	auth := contracts.Auth_Context{
		kind    = .Session,
		user_id = "test_user_owner",
	}

	now_str := platform.clock_now(&clock)
	now_t, parse_ok := platform.parse_rfc3339_utc(now_str)
	testing.expect(t, parse_ok, "parse now ok")

	// 1. Without ttl_at: should default to ~24h
	card_in1 := Card_Input{
		project_id = "proj_test",
		title      = "Card without TTL",
		scope      = "project",
		provider   = "agent",
	}
	c1, ok1, err1 := create_card(&card_svc, auth, card_in1)
	testing.expect(t, ok1, "create card 1 ok")
	testing.expect_value(t, err1.code, domain.Error_Code.None)
	testing.expect(t, c1.ttl_at != "", "ttl_at should not be empty")

	ttl_t, ttl_ok := platform.parse_rfc3339_utc(c1.ttl_at)
	testing.expect(t, ttl_ok, "parse ttl_at ok")
	diff := time.diff(now_t, ttl_t)
	hours := time.duration_hours(diff)
	testing.expect(t, hours >= 23.99 && hours <= 24.01, "ttl_at should be ~24h in the future")

	// 2. With explicit ttl_at: should be preserved
	card_in2 := Card_Input{
		project_id = "proj_test",
		title      = "Card with TTL",
		scope      = "project",
		provider   = "agent",
		ttl_at     = "2030-01-01T00:00:00Z",
	}
	c2, ok2, err2 := create_card(&card_svc, auth, card_in2)
	testing.expect(t, ok2, "create card 2 ok")
	testing.expect_value(t, err2.code, domain.Error_Code.None)
	testing.expect_value(t, c2.ttl_at, "2030-01-01T00:00:00Z")
}
