package shell_session

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"

PANE_POLL_CAPTURES_PER_SECOND :: 2
Pane_Poll_Budget :: struct {
	at: [PANE_POLL_CAPTURES_PER_SECOND]time.Tick,
	used: int,
}

// One sliding window across agent and shell pane captures. Stream reservations and
// this check share mu so a capture cannot bypass a stream allowance already at cap.
shell_session_admit_pane_poll :: proc(svc: ^Shell_Session_Service, auth: contracts.Auth_Context) -> domain.Domain_Error {
	if auth.kind != .User_Token && auth.kind != .Trusted_Proxy do return {}
	if svc == nil do return domain.domain_error(.Internal_Error, "PTY viewer service is unavailable")
	parameters, err := domain.lookup_entitlements(svc.entitlements, auth.user_id)
	if err.code != .None do return err
	if parameters.max_concurrent_streams < 0 do return {}

	sync.mutex_lock(&svc.mu)
	defer sync.mutex_unlock(&svc.mu)
	current := svc.user_viewer_counts[auth.user_id]
	if current >= parameters.max_concurrent_streams {
		return domain.entitlement_limit_error(svc.entitlements, auth.user_id, "max_concurrent_streams", parameters.max_concurrent_streams, current)
	}
	now := time.tick_now()
	if svc.pane_poll_now != nil do now = svc.pane_poll_now(svc.pane_poll_clock_ctx)
	heap := runtime.heap_allocator()
	if svc.pane_poll_budgets == nil do svc.pane_poll_budgets = make(map[string]Pane_Poll_Budget, heap)
	// Retain only active windows, so visiting users do not accumulate forever.
	for key, budget in svc.pane_poll_budgets {
		if budget.used == 0 || time.tick_diff(budget.at[budget.used - 1], now) >= time.Second {
			delete_key(&svc.pane_poll_budgets, key)
			delete(key, heap)
		}
	}
	budget := svc.pane_poll_budgets[auth.user_id]
	for budget.used > 0 && time.tick_diff(budget.at[0], now) >= time.Second {
		for i in 1..<budget.used do budget.at[i-1] = budget.at[i]
		budget.used -= 1
	}
	if budget.used >= PANE_POLL_CAPTURES_PER_SECOND {
		retry_ms := max((i64(time.Second - time.tick_diff(budget.at[0], now)) + i64(time.Millisecond) - 1) / i64(time.Millisecond), 1)
		details, _ := json.marshal(struct {retry_after_ms: i64}{retry_ms}, allocator = context.temp_allocator)
		return domain.domain_error(.Rate_Limited, "Pane capture rate limit reached", string(details))
	}
	budget.at[budget.used] = now
	budget.used += 1
	if _, exists := svc.pane_poll_budgets[auth.user_id]; !exists {
		svc.pane_poll_budgets[strings.clone(auth.user_id, heap)] = budget
	} else {
		svc.pane_poll_budgets[auth.user_id] = budget
	}
	return {}
}
