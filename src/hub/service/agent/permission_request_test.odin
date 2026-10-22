package agent

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"

// REQ-EXT-PERM-1: permission relay ingest (instance token only), user decision
// authz (owner only, never an agent), CAS transitions, decision push to the
// bridge, expiry on timeout and cancellation on instance death.

@(private = "file")
Perm_Store :: struct {
	inst:     domain.Agent_Instance,
	rows:     [dynamic]domain.Permission_Request,
	now:      string,
	commands: [dynamic]project_service.Runtime_Command,
}

@(private = "file")
perm_store_get_instance :: proc(ctx: rawptr, instance_id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	s := (^Perm_Store)(ctx)
	if instance_id != s.inst.agent_instance_id do return {}, false, domain.domain_error(.Not_Found, "agent instance not found")
	return s.inst, true, {}
}

@(private = "file")
perm_store_insert :: proc(ctx: rawptr, req: domain.Permission_Request) -> domain.Domain_Error {
	s := (^Perm_Store)(ctx)
	for r in s.rows do if r.id == req.id do return domain.domain_error(.Conflict, "duplicate")
	append(&s.rows, req)
	return {}
}

@(private = "file")
perm_store_get :: proc(ctx: rawptr, id: string) -> (domain.Permission_Request, bool, domain.Domain_Error) {
	s := (^Perm_Store)(ctx)
	for r in s.rows do if r.id == id do return r, true, {}
	return {}, false, domain.domain_error(.Not_Found, "permission request not found")
}

@(private = "file")
perm_store_list :: proc(ctx: rawptr, f: domain.Permission_Request_Filter) -> ([]domain.Permission_Request, domain.Domain_Error) {
	s := (^Perm_Store)(ctx)
	out := make([dynamic]domain.Permission_Request, context.temp_allocator)
	for r in s.rows {
		if f.owner_user_id != "" && r.owner_user_id != f.owner_user_id do continue
		if f.instance_id != "" && r.instance_id != f.instance_id do continue
		if f.chain_id != "" && r.chain_id != f.chain_id do continue
		if f.status != "" && r.status != f.status do continue
		append(&out, r)
	}
	return out[:], {}
}

@(private = "file")
perm_store_close :: proc(ctx: rawptr, id, status, decided_by, message, decided_at: string) -> (bool, domain.Domain_Error) {
	s := (^Perm_Store)(ctx)
	for &r in s.rows {
		if r.id != id do continue
		if r.status != "pending" do return false, {}
		r.status = status
		r.decided_by = decided_by
		r.message = message
		r.decided_at = decided_at
		return true, {}
	}
	return false, {}
}

@(private = "file")
perm_store_close_pending :: proc(ctx: rawptr, instance_id, expired_by, status, decided_at: string) -> ([]domain.Permission_Request, domain.Domain_Error) {
	s := (^Perm_Store)(ctx)
	out := make([dynamic]domain.Permission_Request, context.temp_allocator)
	for &r in s.rows {
		if r.status != "pending" do continue
		if instance_id != "" && r.instance_id != instance_id do continue
		if instance_id == "" && (r.expires_at == "" || r.expires_at > expired_by) do continue
		r.status = status
		r.decided_at = decided_at
		append(&out, r)
	}
	return out[:], {}
}

@(private = "file")
perm_store_now :: proc(ctx: rawptr) -> string {
	return (^Perm_Store)(ctx).now
}

@(private = "file")
perm_store_send :: proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	s := (^Perm_Store)(ctx)
	append(&s.commands, cmd)
	return true, {}
}

@(private = "file")
perm_service :: proc(store: ^Perm_Store, repo: ^iface.Agent_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Agent_Service {
	store.inst = domain.Agent_Instance{agent_instance_id = "inst_me", owner_user_id = "owner", bridge_id = "brg_1", chain_id = "chain_1"}
	store.now = "2026-10-22T10:00:00Z"
	repo^ = iface.Agent_Repository{ctx = store, get_instance = perm_store_get_instance, perm_insert = perm_store_insert, perm_get = perm_store_get, perm_list = perm_store_list, perm_close = perm_store_close, perm_close_pending = perm_store_close_pending}
	clock^ = platform.Clock{ctx = store, now = perm_store_now}
	ids^ = platform.real_id_generator()
	svc := new_agent_service(repo, nil, clock, ids)
	svc.bridge_command_sink = project_service.Bridge_Command_Sink{ctx = store, send_runtime_command = perm_store_send}
	return svc
}

@(private = "file")
perm_instance_auth :: proc() -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .Instance_Token, user_id = "owner", agent_instance_id = "inst_me"}
}

@(private = "file")
perm_user_auth :: proc(user := "owner") -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .User_Token, user_id = user}
}

@(private = "file")
PERM_PARAMS :: `{"request_id":"perm_1","timeout_ms":300000,"provider":"claude","agent_id":"sub-1","tool_name":"Bash","tool_use_id":"tu_1","input":{"command":"ls"},"permission_suggestions":[{"type":"addRules"}]}`

@(test)
test_permission_ingest_requires_instance_token_and_stores_pending :: proc(t: ^testing.T) {
	store: Perm_Store; repo: iface.Agent_Repository; clock: platform.Clock; ids: platform.ID_Generator
	svc := perm_service(&store, &repo, &clock, &ids)

	_, ok, err := ingest_permission_request(&svc, perm_user_auth(), PERM_PARAMS)
	testing.expect(t, !ok, "a user token cannot create agent permission requests")
	testing.expect_value(t, err.code, domain.Error_Code.Forbidden)

	req, ok2, err2 := ingest_permission_request(&svc, perm_instance_auth(), PERM_PARAMS)
	testing.expect(t, ok2, err2.message)
	testing.expect_value(t, req.status, "pending")
	testing.expect_value(t, req.instance_id, "inst_me")
	testing.expect_value(t, req.chain_id, "chain_1")
	testing.expect_value(t, req.agent_id, "sub-1")
	testing.expect_value(t, req.expires_at, "2026-10-22T10:05:00Z")
	testing.expect(t, strings.contains(req.input, `"command"`), req.input)
	testing.expect(t, strings.contains(req.suggestions, `"addRules"`), req.suggestions)

	// A relay retry of the same id is idempotent; another instance reusing the id is a conflict.
	again, dup_ok, _ := ingest_permission_request(&svc, perm_instance_auth(), PERM_PARAMS)
	testing.expect(t, dup_ok)
	testing.expect_value(t, again.id, "perm_1")
	testing.expect_value(t, len(store.rows), 1)
	store.inst.agent_instance_id = "inst_twin"
	_, twin_ok, twin_err := ingest_permission_request(&svc, contracts.Auth_Context{kind = .Instance_Token, user_id = "owner", agent_instance_id = "inst_twin"}, PERM_PARAMS)
	testing.expect(t, !twin_ok)
	testing.expect_value(t, twin_err.code, domain.Error_Code.Conflict)
	store.inst.agent_instance_id = "inst_me"
	_, bad_ok, bad_err := ingest_permission_request(&svc, perm_instance_auth(), `{"request_id":"../x","tool_name":"Bash"}`)
	testing.expect(t, !bad_ok)
	testing.expect_value(t, bad_err.code, domain.Error_Code.Validation_Failed)
}

@(test)
test_permission_decision_authz :: proc(t: ^testing.T) {
	store: Perm_Store; repo: iface.Agent_Repository; clock: platform.Clock; ids: platform.ID_Generator
	svc := perm_service(&store, &repo, &clock, &ids)
	_, _, _ = ingest_permission_request(&svc, perm_instance_auth(), PERM_PARAMS)

	// The agent itself can never approve its own prompt.
	_, ok, err := decide_permission_request(&svc, perm_instance_auth(), "perm_1", "allow", "")
	testing.expect(t, !ok)
	testing.expect_value(t, err.code, domain.Error_Code.Forbidden)
	// Nor can a bridge token.
	_, ok_b, err_b := decide_permission_request(&svc, contracts.Auth_Context{kind = .Bridge_Token, user_id = "owner"}, "perm_1", "allow", "")
	testing.expect(t, !ok_b)
	testing.expect_value(t, err_b.code, domain.Error_Code.Forbidden)
	// Another user does not even learn it exists.
	_, ok2, err2 := decide_permission_request(&svc, perm_user_auth("mallory"), "perm_1", "allow", "")
	testing.expect(t, !ok2)
	testing.expect_value(t, err2.code, domain.Error_Code.Not_Found)
	// Only allow|deny are decisions.
	_, ok3, err3 := decide_permission_request(&svc, perm_user_auth(), "perm_1", "none", "")
	testing.expect(t, !ok3)
	testing.expect_value(t, err3.code, domain.Error_Code.Validation_Failed)
	testing.expect_value(t, len(store.commands), 0)
	testing.expect_value(t, store.rows[0].status, "pending")
}

@(test)
test_permission_decision_allow_pushes_to_bridge_once :: proc(t: ^testing.T) {
	store: Perm_Store; repo: iface.Agent_Repository; clock: platform.Clock; ids: platform.ID_Generator
	svc := perm_service(&store, &repo, &clock, &ids)
	_, _, _ = ingest_permission_request(&svc, perm_instance_auth(), PERM_PARAMS)

	res, ok, err := decide_permission_request(&svc, perm_user_auth(), "perm_1", "allow", "go ahead")
	testing.expect(t, ok, err.message)
	testing.expect(t, res.delivered)
	testing.expect_value(t, res.request.status, "allowed")
	testing.expect_value(t, res.request.decided_by, "owner")
	testing.expect_value(t, len(store.commands), 1)
	if len(store.commands) == 1 {
		cmd := store.commands[0]
		testing.expect_value(t, cmd.bridge_id, "brg_1")
		testing.expect(t, strings.contains(cmd.body_json, `"type":"permission_decision"`), cmd.body_json)
		testing.expect(t, strings.contains(cmd.body_json, `"request_id":"perm_1"`), cmd.body_json)
		testing.expect(t, strings.contains(cmd.body_json, `"agent_instance_id":"inst_me"`), cmd.body_json)
		testing.expect(t, strings.contains(cmd.body_json, `"decision":"allow"`), cmd.body_json)
	}
	// A second decision loses: the row is closed.
	_, ok2, err2 := decide_permission_request(&svc, perm_user_auth(), "perm_1", "deny", "")
	testing.expect(t, !ok2)
	testing.expect_value(t, err2.code, domain.Error_Code.Conflict)
	testing.expect_value(t, len(store.commands), 1)
}

@(test)
test_permission_expiry_and_instance_cancel :: proc(t: ^testing.T) {
	store: Perm_Store; repo: iface.Agent_Repository; clock: platform.Clock; ids: platform.ID_Generator
	svc := perm_service(&store, &repo, &clock, &ids)
	_, _, _ = ingest_permission_request(&svc, perm_instance_auth(), PERM_PARAMS)
	_, _, _ = ingest_permission_request(&svc, perm_instance_auth(), `{"request_id":"perm_2","timeout_ms":600000,"tool_name":"Edit"}`)

	// Past perm_1's deadline: deciding it is a conflict and it reads as expired.
	store.now = "2026-10-22T10:06:00Z"
	_, ok, err := decide_permission_request(&svc, perm_user_auth(), "perm_1", "deny", "")
	testing.expect(t, !ok)
	testing.expect_value(t, err.code, domain.Error_Code.Conflict)
	pending, lok, _ := list_permission_requests(&svc, perm_user_auth(), domain.Permission_Request_Filter{instance_id = "inst_me", status = "pending"})
	testing.expect(t, lok)
	testing.expect_value(t, len(pending), 1)
	if len(pending) == 1 do testing.expect_value(t, pending[0].id, "perm_2")
	got1, _, _ := perm_store_get(&store, "perm_1")
	testing.expect_value(t, got1.status, "expired")

	// The bridge closing its own timed-out relay marks it expired; a foreign
	// instance cannot close it.
	_, _, got_foreign, ferr := close_permission_request_from_agent(&svc, contracts.Auth_Context{kind = .Instance_Token, user_id = "owner", agent_instance_id = "inst_other"}, "perm_2", "timeout")
	testing.expect(t, !got_foreign)
	testing.expect_value(t, ferr.code, domain.Error_Code.Not_Found)

	// Instance death cancels whatever is still pending (no bridge push).
	notify_instance_terminal(&svc, "inst_me")
	got2, _, _ := perm_store_get(&store, "perm_2")
	testing.expect_value(t, got2.status, "cancelled")
	testing.expect_value(t, len(store.commands), 0)

	// Listing another user's instance is refused.
	_, lok2, lerr2 := list_permission_requests(&svc, perm_user_auth("mallory"), domain.Permission_Request_Filter{instance_id = "inst_me"})
	testing.expect(t, !lok2)
	testing.expect_value(t, lerr2.code, domain.Error_Code.Not_Found)
}

@(test)
test_permission_agent_close_timeout_marks_expired :: proc(t: ^testing.T) {
	store: Perm_Store; repo: iface.Agent_Repository; clock: platform.Clock; ids: platform.ID_Generator
	svc := perm_service(&store, &repo, &clock, &ids)
	_, _, _ = ingest_permission_request(&svc, perm_instance_auth(), PERM_PARAMS)
	req, changed, got, err := close_permission_request_from_agent(&svc, perm_instance_auth(), "perm_1", "timeout")
	testing.expect(t, got, err.message)
	testing.expect(t, changed)
	testing.expect_value(t, req.status, "expired")
	// Idempotent: a second close changes nothing.
	req2, changed2, got2, _ := close_permission_request_from_agent(&svc, perm_instance_auth(), "perm_1", "cancelled")
	testing.expect(t, got2)
	testing.expect(t, !changed2)
	testing.expect_value(t, req2.status, "expired")
}
