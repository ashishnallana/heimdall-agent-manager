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

Fixture :: struct {
	account: domain.Account_Billing,
	checkout: domain.Billing_Checkout,
	applied: domain.Billing_Event,
	existing: domain.Billing_Checkout,
}
// fixture_api has no context pointer; tests run on separate threads.
@(thread_local) fixture_transaction_response: string
@(thread_local) fixture_paddle_calls: [dynamic]string
fixture_clock :: proc(ctx: rawptr) -> string { return "2026-10-10T10:00:00Z" }
fixture_get :: proc(ctx: rawptr, user_id, now: string) -> (domain.Account_Billing, domain.Domain_Error) {
	fixture := (^Fixture)(ctx)
	if user_id != fixture.account.user_id do return {}, domain.domain_error(.Not_Found, "wrong owner")
	return fixture.account, {}
}
fixture_plans :: proc(ctx: rawptr) -> ([]domain.Billing_Plan, domain.Domain_Error) {
	plans := new([3]domain.Billing_Plan, context.temp_allocator)
	plans^ = {{plan_id = "free", plan_label = "Free", entitlements = {1, false}}, {plan_id = "hobbyist", plan_label = "Hobbyist", price_id = "pri_approved", entitlements = {2, true}}, {plan_id = "third", plan_label = "Third plan", price_id = "pri_third", entitlements = {8, true}}}
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
	fixture := (^Fixture)(ctx); fixture.applied = event
	return {}
}
fixture_api :: proc(config: Config, method, path, body: string) -> (string, domain.Domain_Error) {
	append(&fixture_paddle_calls, fmt.tprintf("%s %s", method, path))
	if method == "GET" && path == "/transactions/txn_reserved" do return fixture_transaction_response, {}
	if method == "POST" && path == "/transactions" {
		payload: struct {items: []struct {price_id: string, quantity: int}, custom_data: struct {heimdall_checkout_reference: string}}
		if json.unmarshal_string(body, &payload, .JSON, context.temp_allocator) != nil || len(payload.items) != 1 || payload.items[0].quantity != 1 || payload.custom_data.heimdall_checkout_reference == "" do return "", domain.domain_error(.Validation_Failed, "invalid transaction payload")
		if payload.items[0].price_id != "pri_approved" && payload.items[0].price_id != "pri_third" do return "", domain.domain_error(.Validation_Failed, "unapproved transaction price")
		return fixture_transaction_response, {}
	}
	if path == "/customers/ctm_alice/portal-sessions" do return `{"data":{"urls":{"general":{"overview":"https://customer-portal.paddle.com/cpl_test?token=temporary"}}}}`, {}
	return "", domain.domain_error(.Validation_Failed, "wrong account or endpoint")
}
fixture_setup :: proc(fixture: ^Fixture, repo: ^iface.Billing_Repository, clock: ^platform.Clock) -> Service {
	fixture_paddle_calls = make([dynamic]string, context.temp_allocator)
	fixture_transaction_response = `{"data":{"id":"txn_prepared","checkout":{"url":"https://pay.example.test/checkout?_ptxn=txn_prepared"}}}`
	fixture.account = domain.Account_Billing{user_id = "alice", plan_id = "free", plan_label = "Free", status = "free", entitlements = {1, false}}
	repo^ = iface.Billing_Repository{ctx = fixture, get_account = fixture_get, list_plans = fixture_plans, reserve_checkout = fixture_reserve, finish_checkout = fixture_finish, apply_event = fixture_apply}
	clock^ = platform.Clock{now = fixture_clock}
	return Service{repo = repo, clock = clock, config = Config{environment = "sandbox", api_key = "test_key", client_token = "test_token", webhook_secret = "test_secret", past_due_grace_seconds = 86400}, request = fixture_api}
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
	testing.expect(t, len(fixture.checkout.reference) >= 32)
	testing.expect(t, !fixture.account.entitlements.terminal_streaming_enabled, "checkout does not grant paid access")
	_, unapproved := start_checkout(&service, "alice", "pri_forged")
	testing.expect_value(t, unapproved.code, domain.Error_Code.Validation_Failed)
	fixture.account.subscription_id = "sub_active"; fixture.account.status = "active"
	_, duplicate := start_checkout(&service, "alice", "hobbyist")
	testing.expect_value(t, duplicate.code, domain.Error_Code.Conflict)
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
	service.config.api_key = ""
	_, unconfigured := start_checkout(&service, "alice", "hobbyist")
	testing.expect_value(t, unconfigured.code, domain.Error_Code.Not_Implemented)
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
}

@(test)
test_verified_subscription_event_is_parsed_and_persisted :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture: Fixture; repo: iface.Billing_Repository; clock: platform.Clock
	service := fixture_setup(&fixture, &repo, &clock)
	body := `{"event_id":"evt_created","event_type":"subscription.created","occurred_at":"2026-10-10T10:00:00.123456Z","data":{"id":"sub_alice","status":"active","customer_id":"ctm_alice","next_billed_at":"2026-11-10T10:00:00Z","scheduled_change":null,"custom_data":{"heimdall_checkout_reference":"server_only_reference"},"items":[{"price":{"id":"pri_approved"}}]}}`
	err := receive_webhook(&service, signature_for(body), body)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, fixture.applied.subscription_id, "sub_alice")
	testing.expect_value(t, fixture.applied.checkout_reference, "server_only_reference")
	testing.expect_value(t, fixture.applied.occurred_ns, i64(1791626400123456000))
	invalid := receive_webhook(&service, "ts=0;h1=bad", body)
	testing.expect_value(t, invalid.code, domain.Error_Code.Unauthenticated)
}
