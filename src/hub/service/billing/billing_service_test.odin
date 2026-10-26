package billing

import "core:crypto/hmac"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import httpc "odin_test:lib/httpc"

Fixture :: struct {
	account: domain.Account_Billing,
	checkout: domain.Billing_Checkout,
	applied: domain.Billing_Event,
	existing: domain.Billing_Checkout,
	apply_error: domain.Domain_Error,
	get_error: domain.Domain_Error,
	get_calls: int,
}
FIXTURE_REFERENCE :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
fixture_reference :: proc() -> (string, bool) { return FIXTURE_REFERENCE, true }
// fixture_api has no context pointer; tests run on separate threads.
@(thread_local) fixture_transaction_response: string
@(thread_local) fixture_paddle_calls: [dynamic]string
@(thread_local) fixture_portal_response: string
@(thread_local) fixture_post_reference: string
fixture_clock :: proc(ctx: rawptr) -> string { return "2026-10-10T10:00:00Z" }
fixture_get :: proc(ctx: rawptr, user_id, now: string) -> (domain.Account_Billing, domain.Domain_Error) {
	fixture := (^Fixture)(ctx)
	fixture.get_calls += 1
	if fixture.get_error.code != .None do return {}, fixture.get_error
	if user_id != fixture.account.user_id do return {}, domain.domain_error(.Not_Found, "wrong owner")
	return fixture.account, {}
}
fixture_plans :: proc(ctx: rawptr) -> ([]domain.Billing_Plan, domain.Domain_Error) {
	plans := new([3]domain.Billing_Plan, context.temp_allocator)
	plans^ = {{plan_id = "free", plan_label = "Free", entitlements = {max_bridges = 1, terminal_streaming_enabled = true, max_concurrent_streams = 2}}, {plan_id = "hobbyist", plan_label = "Hobbyist", price_id = "pri_approved", entitlements = {max_bridges = 2, terminal_streaming_enabled = true, terminal_input_enabled = true, max_concurrent_streams = -1, shells_enabled = true}}, {plan_id = "third", plan_label = "Third plan", price_id = "pri_third", entitlements = {max_bridges = 8, terminal_streaming_enabled = true, terminal_input_enabled = true, max_concurrent_streams = -1, shells_enabled = true}}}
	return plans[:], {}
}
fixture_reserve :: proc(ctx: rawptr, checkout: domain.Billing_Checkout, now: string) -> (domain.Billing_Checkout, bool, domain.Domain_Error) {
	fixture := (^Fixture)(ctx)
	if fixture.existing.reference != "" do return fixture.existing, false, {}
	fixture.checkout = checkout
	return checkout, true, {}
}
fixture_finish :: proc(ctx: rawptr, checkout: domain.Billing_Checkout) -> domain.Domain_Error {
	fixture := (^Fixture)(ctx); fixture.checkout = checkout
	return {}
}
fixture_apply :: proc(ctx: rawptr, event: domain.Billing_Event, now: string) -> domain.Domain_Error {
	fixture := (^Fixture)(ctx)
	if fixture.apply_error.code != .None do return fixture.apply_error
	fixture.applied = event
	return {}
}
fixture_api :: proc(config: Config, m: httpc.Method, segments: []string, request_body: httpc.Body) -> (string, domain.Domain_Error) {
	method := httpc.method_name(m)
	path, _ := httpc.build_target(segments, allocator = context.temp_allocator)
	body := ""
	if j, is_json := request_body.(httpc.Json_Body); is_json do body = string(j.encoded)
	append(&fixture_paddle_calls, fmt.tprintf("%s %s", method, path))
	if method == "GET" && path == "/transactions/txn_reserved" do return fixture_transaction_response, {}
	if method == "POST" && path == "/transactions" {
		payload: struct {items: []struct {price_id: string, quantity: int}, custom_data: struct {heimdall_checkout_reference: string}}
		if json.unmarshal_string(body, &payload, .JSON, context.temp_allocator) != nil || len(payload.items) != 1 || payload.items[0].quantity != 1 || payload.custom_data.heimdall_checkout_reference == "" do return "", domain.domain_error(.Validation_Failed, "invalid transaction payload")
		if payload.items[0].price_id != "pri_approved" && payload.items[0].price_id != "pri_third" do return "", domain.domain_error(.Validation_Failed, "unapproved transaction price")
		fixture_post_reference = strings.clone(payload.custom_data.heimdall_checkout_reference, context.temp_allocator)
		return fixture_transaction_response, {}
	}
	if method == "POST" && path == "/customers/ctm_alice/portal-sessions" do return fixture_portal_response, {}
	return "", domain.domain_error(.Validation_Failed, "wrong account or endpoint")
}
fixture_setup :: proc(fixture: ^Fixture, repo: ^iface.Billing_Repository, clock: ^platform.Clock) -> Service {
	fixture_paddle_calls = make([dynamic]string, context.temp_allocator)
	fixture_post_reference = ""
	fixture_portal_response = `{"data":{"urls":{"general":{"overview":"https://customer-portal.paddle.com/cpl_test?token=temporary"}}}}`
	fixture_transaction_response = `{"data":{"id":"txn_prepared","checkout":{"url":"https://pay.example.test/checkout?_ptxn=txn_prepared"}}}`
	fixture.account = domain.Account_Billing{user_id = "alice", plan_id = "free", plan_label = "Free", status = "free", entitlements = {max_bridges = 1, terminal_streaming_enabled = true, max_concurrent_streams = 2}}
	repo^ = iface.Billing_Repository{ctx = fixture, get_account = fixture_get, list_plans = fixture_plans, reserve_checkout = fixture_reserve, finish_checkout = fixture_finish, apply_event = fixture_apply}
	clock^ = platform.Clock{now = fixture_clock}
	return Service{repo = repo, clock = clock, config = Config{environment = "sandbox", api_key = "test_key", client_token = "test_token", webhook_secret = "test_secret", past_due_grace_seconds = 86400}, request = fixture_api, new_reference = fixture_reference}
}

@(test)
test_checkout_uses_approved_offer_and_persists_without_granting_access :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture: Fixture; repo: iface.Billing_Repository; clock: platform.Clock
	service := fixture_setup(&fixture, &repo, &clock)
	view, err := account_view(&service, "alice")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, len(view.offers), 2)
	result, checkout_err := start_checkout(&service, "alice", "third")
	testing.expect_value(t, checkout_err.code, domain.Error_Code.None)
	testing.expect_value(t, result.transaction_id, "txn_prepared")
	testing.expect_value(t, result.checkout_url, "https://pay.example.test/checkout?_ptxn=txn_prepared")
	testing.expect_value(t, fixture.checkout.user_id, "alice")
	testing.expect_value(t, fixture.checkout.price_id, "pri_third")
	testing.expect_value(t, fixture.checkout.reference, FIXTURE_REFERENCE)
	testing.expect_value(t, fixture.checkout.expires_at, "2026-10-10T10:20:00Z")
	testing.expect_value(t, fixture_post_reference, fixture.checkout.reference)
	testing.expect_value(t, fixture.applied.event_id, "")
	testing.expect_value(t, len(fixture_paddle_calls), 1)
	_, unapproved := start_checkout(&service, "alice", "pri_forged")
	testing.expect_value(t, unapproved.code, domain.Error_Code.Validation_Failed)
	fixture.account.subscription_id = "sub_active"; fixture.account.status = "active"
	_, duplicate := start_checkout(&service, "alice", "hobbyist")
	testing.expect_value(t, duplicate.code, domain.Error_Code.Conflict)
	testing.expect_value(t, len(fixture_paddle_calls), 1) // rejected paths make no Paddle call
	fixture.account.status = "custom"; fixture.account.subscription_id = ""
	custom_view, _ := account_view(&service, "alice")
	testing.expect_value(t, len(custom_view.offers), 0)
}

@(test)
test_portal_is_bound_to_authenticated_account :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture: Fixture; repo: iface.Billing_Repository; clock: platform.Clock
	service := fixture_setup(&fixture, &repo, &clock)
	fixture.account.customer_id = "ctm_alice"
	portal, err := create_portal(&service, "alice")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect(t, strings.has_prefix(portal.url, "https://customer-portal.paddle.com/"))
	_, wrong_owner := create_portal(&service, "bob")
	testing.expect_value(t, wrong_owner.code, domain.Error_Code.Not_Found)
	testing.expect_value(t, len(fixture_paddle_calls), 1)
	if len(fixture_paddle_calls) == 1 do testing.expect_value(t, fixture_paddle_calls[0], "POST /customers/ctm_alice/portal-sessions")

	fixture.account.customer_id = ""
	_, no_customer := create_portal(&service, "alice")
	testing.expect_value(t, no_customer.code, domain.Error_Code.Not_Found)
	testing.expect_value(t, len(fixture_paddle_calls), 1) // no Paddle call without a customer
	fixture.account.customer_id = "ctm_alice"

	fixture_portal_response = `{"data":{"urls":{"general":{"overview":"https://sandbox-customer-portal.paddle.com/cpl_test"}}}}`
	sandbox, sandbox_err := create_portal(&service, "alice")
	testing.expect_value(t, sandbox_err.code, domain.Error_Code.None)
	testing.expect_value(t, sandbox.url, "https://sandbox-customer-portal.paddle.com/cpl_test")
	fixture_portal_response = `{"data":{"urls":{"general":{"overview":"https://evil.example.test/portal"}}}}`
	_, untrusted := create_portal(&service, "alice")
	testing.expect_value(t, untrusted.code, domain.Error_Code.Internal_Error)

	calls_before := len(fixture_paddle_calls)
	service.config.api_key = ""
	_, portal_unconfigured := create_portal(&service, "alice")
	testing.expect_value(t, portal_unconfigured.code, domain.Error_Code.Not_Implemented)
	_, unconfigured := start_checkout(&service, "alice", "hobbyist")
	testing.expect_value(t, unconfigured.code, domain.Error_Code.Not_Implemented)
	testing.expect_value(t, len(fixture_paddle_calls), calls_before)
}

@(test)
test_reused_checkout_returns_validated_url_without_duplicate_transaction :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture: Fixture; repo: iface.Billing_Repository; clock: platform.Clock
	service := fixture_setup(&fixture, &repo, &clock)
	fixture.existing = domain.Billing_Checkout{reference = "reserved_reference", user_id = "alice", plan_id = "hobbyist", price_id = "pri_approved", transaction_id = "txn_reserved"}
	fixture_transaction_response = `{"data":{"id":"txn_reserved","checkout":{"url":"https://www.brolabs.ai/heimdall/checkout?_ptxn=txn_reserved"}}}`
	result, err := start_checkout(&service, "alice", "hobbyist")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, result.transaction_id, "txn_reserved")
	testing.expect_value(t, result.checkout_url, "https://www.brolabs.ai/heimdall/checkout?_ptxn=txn_reserved")
	testing.expect_value(t, len(fixture_paddle_calls), 1)
	if len(fixture_paddle_calls) == 1 do testing.expect_value(t, fixture_paddle_calls[0], "GET /transactions/txn_reserved")
	fixture_transaction_response = `{"data":{"id":"txn_other","checkout":{"url":"https://www.brolabs.ai/heimdall/checkout?_ptxn=txn_other"}}}`
	_, mismatched := start_checkout(&service, "alice", "hobbyist")
	testing.expect_value(t, mismatched.code, domain.Error_Code.Internal_Error)
	fixture_transaction_response = `{"data":{"id":"txn_reserved","checkout":{"url":null}}}`
	_, missing := start_checkout(&service, "alice", "hobbyist")
	testing.expect_value(t, missing.code, domain.Error_Code.Internal_Error)
	fixture.existing.transaction_id = "txn_../customers"
	_, forged := start_checkout(&service, "alice", "hobbyist")
	testing.expect_value(t, forged.code, domain.Error_Code.Conflict)
	for call in fixture_paddle_calls do testing.expect(t, !strings.has_prefix(call, "POST"), "reused reservations never create another transaction")
}

@(test)
test_new_checkout_with_invalid_url_keeps_transaction_reserved :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture: Fixture; repo: iface.Billing_Repository; clock: platform.Clock
	service := fixture_setup(&fixture, &repo, &clock)
	fixture_transaction_response = `{"data":{"id":"txn_prepared","checkout":null}}`
	_, err := start_checkout(&service, "alice", "hobbyist")
	testing.expect_value(t, err.code, domain.Error_Code.Internal_Error)
	testing.expect_value(t, fixture.checkout.transaction_id, "txn_prepared")
}

@(test)
test_checkout_url_validation_rejects_untrusted_redirects :: proc(t: ^testing.T) {
	testing.expect(t, valid_checkout_url("https://www.brolabs.ai/heimdall/checkout?_ptxn=txn_01m4qhm8k14vqm92dwdbh8a8xh", "txn_01m4qhm8k14vqm92dwdbh8a8xh"))
	testing.expect(t, valid_checkout_url("https://pay.example.test:443/?a=1&_ptxn=txn_abc#top", "txn_abc"))
	rejected := []string{
		"",
		"not a url",
		"http://pay.example.test/?_ptxn=txn_abc",
		"javascript:alert(1)//?_ptxn=txn_abc",
		"https://user:pass@pay.example.test/?_ptxn=txn_abc",
		"https://pay.example.test@evil.test/?_ptxn=txn_abc",
		"https:///?_ptxn=txn_abc",
		"https://pay.example.test",
		"https://pay.example.test/checkout",
		"https://pay.example.test/?ptxn=txn_abc",
		"https://pay.example.test/?_ptxn=txn_other",
		"https://pay.example.test/?_ptxn=txn_abcd",
		"https://pay.example.test/?_ptxn=",
		"https://pay.example.test/?_ptxn=txn_abc&_ptxn=txn_abc",
		"https://pay.example.test/?_ptxn=txn_abc&_ptxn=txn_evil",
		"https://pay.example.test/#?_ptxn=txn_abc",
		"https://pay.example.test:/?_ptxn=txn_abc",
		"https://pay.example.test:44x/?_ptxn=txn_abc",
		"https://pay.example.test\\@evil.test/?_ptxn=txn_abc",
		"https://pay.example.test/ ?_ptxn=txn_abc",
		"https://pay.exa_mple.test/?_ptxn=txn_abc",
	}
	for url in rejected do testing.expectf(t, !valid_checkout_url(url, "txn_abc"), "accepted %q", url)
	testing.expect(t, !valid_checkout_url("https://pay.example.test/?_ptxn=pri_abc", "pri_abc"), "transaction id must be a Paddle transaction")
}

signature_for :: proc(body: string, timestamp: string = "1791626400") -> string {
	digest: [32]byte
	message := strings.concatenate({timestamp, ":", body})
	hmac.sum(.SHA256, digest[:], transmute([]byte)message, transmute([]byte)string("test_secret"))
	return fmt.tprintf("ts=%s;h1=%s", timestamp, string(hex.encode(digest[:], context.temp_allocator)))
}

@(test)
test_paddle_signature_checks_raw_bytes_timestamp_and_rotation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	body := `{"event_id":"evt_test"}`
	signature := signature_for(body)
	testing.expect(t, verify_signature("test_secret", signature, body, 1791626400))
	testing.expect(t, !verify_signature("other_secret", signature, body, 1791626400))
	testing.expect(t, !verify_signature("test_secret", signature, strings.concatenate({body, " "}), 1791626400))
	testing.expect(t, !verify_signature("test_secret", signature, body, 1791626701))
	testing.expect(t, !verify_signature("test_secret", signature, body, 1791626369))
	testing.expect(t, !verify_signature("test_secret", strings.concatenate({signature, ";ts=1791626400"}), body, 1791626400))
	testing.expect(t, verify_signature("test_secret", strings.concatenate({signature, ";h1=bad"}), body, 1791626400))

	// Inclusive window boundaries: ts = now-300 and ts = now+30.
	testing.expect(t, verify_signature("test_secret", signature, body, 1791626700))
	testing.expect(t, verify_signature("test_secret", signature, body, 1791626370))

	// Rotation: a well-formed but wrong h1 before the valid one is skipped.
	wrong_tag := strings.repeat("0", 64)
	h1_at := strings.index(signature, ";h1=")
	rotated := strings.concatenate({signature[:h1_at], ";h1=", wrong_tag, signature[h1_at:]})
	testing.expect(t, verify_signature("test_secret", rotated, body, 1791626400))
	testing.expect(t, !verify_signature("test_secret", strings.concatenate({signature[:h1_at], ";h1=", wrong_tag}), body, 1791626400))
	// A 64-char non-hex h1 is skipped, not fatal.
	non_hex := strings.concatenate({signature[:h1_at], ";h1=", strings.repeat("z", 64), signature[h1_at:]})
	testing.expect(t, verify_signature("test_secret", non_hex, body, 1791626400))

	testing.expect(t, !verify_signature("", signature, body, 1791626400))
	testing.expect(t, !verify_signature("test_secret", "", body, 1791626400))
	big := strings.repeat("a", 1024*1024 + 1)
	testing.expect(t, !verify_signature("test_secret", signature_for(big), big, 1791626400))
}

@(test)
test_verified_subscription_event_is_parsed_and_persisted :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture: Fixture; repo: iface.Billing_Repository; clock: platform.Clock
	service := fixture_setup(&fixture, &repo, &clock)
	body := `{"event_id":"evt_created","event_type":"subscription.created","occurred_at":"2026-10-10T10:00:00.123456Z","data":{"id":"sub_alice","status":"active","customer_id":"ctm_alice","next_billed_at":"2026-11-10T10:00:00Z","scheduled_change":null,"custom_data":{"heimdall_checkout_reference":"server_only_reference"},"items":[{"price":{"id":"pri_approved"}}]}}`
	err := receive_webhook(&service, signature_for(body), body)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, fixture.applied.event_id, "evt_created")
	testing.expect_value(t, fixture.applied.event_type, "subscription.created")
	testing.expect_value(t, fixture.applied.subscription_id, "sub_alice")
	testing.expect_value(t, fixture.applied.customer_id, "ctm_alice")
	testing.expect_value(t, fixture.applied.price_id, "pri_approved")
	testing.expect_value(t, fixture.applied.status, "active")
	testing.expect_value(t, fixture.applied.renews_at, "2026-11-10T10:00:00Z")
	testing.expect_value(t, fixture.applied.cancels_at, "")
	testing.expect_value(t, fixture.applied.grace_until, "")
	testing.expect_value(t, fixture.applied.checkout_reference, "server_only_reference")
	testing.expect_value(t, fixture.applied.occurred_ns, i64(1791626400123456000))

	// Bad signature must not reach the repository.
	fixture.applied = {}
	invalid := receive_webhook(&service, "ts=0;h1=bad", body)
	testing.expect_value(t, invalid.code, domain.Error_Code.Unauthenticated)
	testing.expect_value(t, fixture.applied.event_id, "")

	// past_due derives the grace deadline; a scheduled cancel sets cancels_at.
	past_due := `{"event_id":"evt_past_due","event_type":"subscription.past_due","occurred_at":"2026-10-10T10:00:00Z","data":{"id":"sub_alice","status":"past_due","customer_id":"ctm_alice","next_billed_at":"2026-11-10T10:00:00Z","scheduled_change":{"action":"cancel","effective_at":"2026-11-01T00:00:00Z"},"custom_data":{"heimdall_checkout_reference":""},"items":[{"price":{"id":"pri_approved"}}]}}`
	testing.expect_value(t, receive_webhook(&service, signature_for(past_due), past_due).code, domain.Error_Code.None)
	testing.expect_value(t, fixture.applied.status, "past_due")
	testing.expect_value(t, fixture.applied.grace_until, "2026-10-11T10:00:00Z")
	testing.expect_value(t, fixture.applied.cancels_at, "2026-11-01T00:00:00Z")

	// Fraction bounds: 9 digits accepted (nanosecond precision), 10 rejected.
	nine, _ := strings.replace(body, ".123456Z", ".123456789Z", 1)
	testing.expect_value(t, receive_webhook(&service, signature_for(nine), nine).code, domain.Error_Code.None)
	testing.expect_value(t, fixture.applied.occurred_ns, i64(1791626400123456789))
	ten, _ := strings.replace(body, ".123456Z", ".1234567890Z", 1)
	testing.expect_value(t, receive_webhook(&service, signature_for(ten), ten).code, domain.Error_Code.Validation_Failed)
}
