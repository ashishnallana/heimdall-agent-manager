package shell_session

import "base:runtime"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import project_service "odin_test:hub/service/project"

Pane_Plan_Test :: struct {
	max_streams: int,
	fail_lookup: bool,
	now: time.Tick,
}
pane_plan_lookup :: proc(ctx: rawptr, user_id: string) -> (domain.User_Entitlements, domain.Domain_Error) {
	f := (^Pane_Plan_Test)(ctx)
	if f.fail_lookup do return {}, domain.domain_error(.Internal_Error, "lookup failed")
	p := domain.unlimited_entitlements()
	p.max_concurrent_streams = f.max_streams
	return p, {}
}
pane_plan_now :: proc(ctx: rawptr) -> time.Tick { return ((^Pane_Plan_Test)(ctx)).now }
pane_plan_configure :: proc(svc: ^Shell_Session_Service, f: ^Pane_Plan_Test) {
	svc.entitlements = {ctx = f, lookup = pane_plan_lookup}
	svc.pane_poll_now = pane_plan_now
	svc.pane_poll_clock_ctx = f
}

@(test)
test_pane_plan_shared_user_cap_deduplicates_and_reclaims_slot :: proc(t: ^testing.T) {
	pairs: [4]Pane_Test_Pair
	for i in 0..<len(pairs) do pairs[i] = pane_test_pair(t)
	defer for pair in pairs { net.close(pair.hub); net.close(pair.peer) }
	svc := new_shell_session_service()
	defer shell_session_service_free(&svc)
	f := Pane_Plan_Test{max_streams = 2}
	pane_plan_configure(&svc, &f)

	first := shell_session_attach(&svc, "agent", pairs[0].hub, "bridgeA", project_service.WS_KIND_AGENT_STREAM, "alice")
	second := shell_session_attach(&svc, "shell", pairs[1].hub, "bridgeB", project_service.WS_KIND_SHELL, "alice")
	duplicate := shell_session_attach(&svc, "agent", pairs[0].hub, "bridgeA", user_id = "alice")
	third := shell_session_attach(&svc, "third", pairs[2].hub, "bridgeC", user_id = "alice")
	other := shell_session_attach(&svc, "third", pairs[3].hub, "bridgeC", user_id = "bob")
	testing.expect_value(t, first.status, Attach_Status.Attached)
	testing.expect_value(t, second.status, Attach_Status.Attached)
	testing.expect_value(t, duplicate.status, Attach_Status.Late_Join)
	testing.expect_value(t, third.status, Attach_Status.Rejected_Limit)
	testing.expect_value(t, third.err.code, domain.Error_Code.Plan_Limit_Reached)
	testing.expect(t, strings.contains(third.err.details_json, "\"allowed\":2"))
	testing.expect(t, strings.contains(third.err.details_json, "\"current\":2"))
	testing.expect_value(t, other.status, Attach_Status.Attached)
	testing.expect_value(t, svc.user_viewer_counts["alice"], 2)
	testing.expect_value(t, svc.user_viewer_counts["bob"], 1)
	testing.expect_value(t, len(svc.viewers["third"]), 1)

	// A repeated detach cannot return another viewer's slot.
	shell_session_detach(&svc, "agent", pairs[0].hub, "bridgeA")
	shell_session_detach(&svc, "agent", pairs[0].hub, "bridgeA")
	testing.expect_value(t, svc.user_viewer_counts["alice"], 1)
	retry := shell_session_attach(&svc, "third", pairs[2].hub, "bridgeC", user_id = "alice")
	testing.expect_value(t, retry.status, Attach_Status.Late_Join)
	shell_session_detach(&svc, "shell", pairs[1].hub, "bridgeB")
	shell_session_detach(&svc, "third", pairs[2].hub, "bridgeC")
	shell_session_detach(&svc, "third", pairs[3].hub, "bridgeC")
	testing.expect_value(t, len(svc.user_viewer_counts), 0)
}

@(test)
test_pane_plan_zero_unlimited_bypass_and_lookup_failure :: proc(t: ^testing.T) {
	pairs: [3]Pane_Test_Pair
	for i in 0..<len(pairs) do pairs[i] = pane_test_pair(t)
	defer for pair in pairs { net.close(pair.hub); net.close(pair.peer) }
	svc := new_shell_session_service()
	defer shell_session_service_free(&svc)
	f := Pane_Plan_Test{max_streams = 0}
	pane_plan_configure(&svc, &f)
	testing.expect_value(t, shell_session_attach(&svc, "zero", pairs[0].hub, user_id = "alice").status, Attach_Status.Rejected_Limit)
	testing.expect_value(t, len(svc.viewer_writers), 0)
	f.max_streams = -1
	for pair, i in pairs {
		testing.expect_value(t, shell_session_attach(&svc, "paid", pair.hub, user_id = "alice").status, Attach_Status.Attached if i == 0 else Attach_Status.Late_Join)
	}
	for pair in pairs do shell_session_detach(&svc, "paid", pair.hub)
	f.fail_lookup = true
	result := shell_session_attach(&svc, "fail", pairs[0].hub, user_id = "alice")
	testing.expect_value(t, result.status, Attach_Status.Rejected)
	testing.expect_value(t, result.err.code, domain.Error_Code.Internal_Error)
	testing.expect_value(t, len(svc.user_viewer_counts), 0)
	// Empty user identity is the explicit automation bypass, even if billing fails.
	testing.expect_value(t, shell_session_attach(&svc, "automation", pairs[0].hub).status, Attach_Status.Attached)
	testing.expect_value(t, len(svc.user_viewer_counts), 0)
}

Pane_Plan_Attach_Thread :: struct {
	svc: ^Shell_Session_Service,
	socket: net.TCP_Socket,
	gate: ^sync.Mutex,
	result: Attach_Result,
}
pane_plan_attach_thread :: proc(raw: rawptr) {
	context = runtime.default_context()
	f := (^Pane_Plan_Attach_Thread)(raw)
	sync.mutex_lock(f.gate)
	sync.mutex_unlock(f.gate)
	f.result = shell_session_attach(f.svc, "racing", f.socket, user_id = "alice")
}
@(test)
test_pane_plan_concurrent_attach_cannot_overbook :: proc(t: ^testing.T) {
	pairs: [8]Pane_Test_Pair
	for i in 0..<len(pairs) do pairs[i] = pane_test_pair(t)
	defer for pair in pairs { net.close(pair.hub); net.close(pair.peer) }
	svc := new_shell_session_service()
	defer shell_session_service_free(&svc)
	f := Pane_Plan_Test{max_streams = 2}
	pane_plan_configure(&svc, &f)
	gate: sync.Mutex
	sync.mutex_lock(&gate)
	runners: [8]Pane_Plan_Attach_Thread
	threads: [8]^thread.Thread
	for i in 0..<len(pairs) {
		runners[i] = {svc = &svc, socket = pairs[i].hub, gate = &gate}
		threads[i] = thread.create_and_start_with_data(&runners[i], pane_plan_attach_thread)
	}
	sync.mutex_unlock(&gate)
	for th in threads { thread.join(th); thread.destroy(th) }
	accepted, rejected := 0, 0
	for runner in runners {
		if runner.result.status == .Rejected_Limit { rejected += 1 } else { accepted += 1 }
	}
	testing.expect_value(t, accepted, 2)
	testing.expect_value(t, rejected, 6)
	testing.expect_value(t, svc.user_viewer_counts["alice"], 2)
}

@(test)
test_pane_plan_poll_sliding_window_cap_and_exemptions :: proc(t: ^testing.T) {
	svc := new_shell_session_service()
	defer shell_session_service_free(&svc)
	f := Pane_Plan_Test{max_streams = 2}
	pane_plan_configure(&svc, &f)
	alice := contracts.Auth_Context{kind = .User_Token, user_id = "alice"}
	bob := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "bob"}
	testing.expect_value(t, shell_session_admit_pane_poll(&svc, alice).code, domain.Error_Code.None)
	f.now._nsec += i64(500 * time.Millisecond)
	testing.expect_value(t, shell_session_admit_pane_poll(&svc, alice).code, domain.Error_Code.None)
	rate := shell_session_admit_pane_poll(&svc, alice)
	testing.expect_value(t, rate.code, domain.Error_Code.Rate_Limited)
	testing.expect_value(t, rate.details_json, "{\"retry_after_ms\":500}")
	testing.expect_value(t, shell_session_admit_pane_poll(&svc, bob).code, domain.Error_Code.None)
	f.now._nsec += i64(500 * time.Millisecond)
	testing.expect_value(t, shell_session_admit_pane_poll(&svc, alice).code, domain.Error_Code.None)
	testing.expect_value(t, shell_session_admit_pane_poll(&svc, alice).code, domain.Error_Code.Rate_Limited)
	// Stream limit wins over a full polling budget.
	svc.user_viewer_counts[strings.clone("alice", runtime.heap_allocator())] = 2
	testing.expect_value(t, shell_session_admit_pane_poll(&svc, alice).code, domain.Error_Code.Plan_Limit_Reached)
	f.max_streams = 0
	testing.expect_value(t, shell_session_admit_pane_poll(&svc, bob).code, domain.Error_Code.Plan_Limit_Reached)
	f.fail_lookup = true
	testing.expect_value(t, shell_session_admit_pane_poll(&svc, alice).code, domain.Error_Code.Internal_Error)
	testing.expect_value(t, shell_session_admit_pane_poll(&svc, {kind = .Instance_Token, user_id = "alice"}).code, domain.Error_Code.None)
	f.fail_lookup = false
	f.max_streams = -1
	for _ in 0..<10 do testing.expect_value(t, shell_session_admit_pane_poll(&svc, alice).code, domain.Error_Code.None)
	// Expired users are reclaimed when another bounded user polls.
	f.max_streams = 2
	f.now._nsec += i64(2 * time.Second)
	testing.expect_value(t, shell_session_admit_pane_poll(&svc, bob).code, domain.Error_Code.None)
	testing.expect_value(t, len(svc.pane_poll_budgets), 1)
}
