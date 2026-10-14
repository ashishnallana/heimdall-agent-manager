package billing

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import metrics "odin_test:lib/metrics"

// heimdall_billing_webhooks_total{event,result}: one increment per delivery,
// both labels from fixed enums.

@(private = "file")
webhook_count :: proc(event, result: string) -> u64 {
	return metrics.counter_value(metrics.with(billing_metrics.webhooks_total, event, result))
}

@(test)
test_billing_webhook_event_enum :: proc(t: ^testing.T) {
	testing.expect_value(t, billing_webhook_event_enum("subscription.created"), "subscription_created")
	testing.expect_value(t, billing_webhook_event_enum("subscription.canceled"), "subscription_canceled")
	testing.expect_value(t, billing_webhook_event_enum("subscription.something_new"), "subscription_other")
	testing.expect_value(t, billing_webhook_event_enum("transaction.completed"), "transaction")
	testing.expect_value(t, billing_webhook_event_enum("customer.updated"), "customer")
	testing.expect_value(t, billing_webhook_event_enum("adjustment.created"), "other")
	testing.expect_value(t, billing_webhook_event_enum(""), "unknown")
	testing.expect_value(t, billing_webhook_result_enum("ok"), "ok")
	testing.expect_value(t, billing_webhook_result_enum("whatever"), "other")
}

@(test)
test_billing_webhook_metrics_outcomes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	billing_metrics_init(metrics.init_global())
	fixture: Fixture; repo: iface.Billing_Repository; clock: platform.Clock
	service := fixture_setup(&fixture, &repo, &clock)

	ok_body := `{"event_id":"evt_created","event_type":"subscription.created","occurred_at":"2026-10-10T10:00:00.123456Z","data":{"id":"sub_alice","status":"active","customer_id":"ctm_alice","next_billed_at":"2026-11-10T10:00:00Z","scheduled_change":null,"custom_data":{"heimdall_checkout_reference":"ref"},"items":[{"price":{"id":"pri_approved"}}]}}`
	ok_before := webhook_count("subscription_created", "ok")
	testing.expect_value(t, receive_webhook(&service, signature_for(ok_body), ok_body).code, domain.Error_Code.None)
	testing.expect_value(t, webhook_count("subscription_created", "ok") - ok_before, u64(1))

	sig_before := webhook_count("unknown", "invalid_signature")
	testing.expect_value(t, receive_webhook(&service, "ts=0;h1=bad", ok_body).code, domain.Error_Code.Unauthenticated)
	testing.expect_value(t, webhook_count("unknown", "invalid_signature") - sig_before, u64(1))

	ignored_body := `{"event_id":"evt_txn","event_type":"transaction.completed","occurred_at":"2026-10-10T10:00:00Z","data":{}}`
	ignored_before := webhook_count("transaction", "ignored")
	testing.expect_value(t, receive_webhook(&service, signature_for(ignored_body), ignored_body).code, domain.Error_Code.None)
	testing.expect_value(t, webhook_count("transaction", "ignored") - ignored_before, u64(1))

	bad_status := `{"event_id":"evt_bad","event_type":"subscription.updated","occurred_at":"2026-10-10T10:00:00Z","data":{"id":"sub_alice","status":"bogus","customer_id":"ctm_alice","items":[{"price":{"id":"pri_approved"}}]}}`
	err_before := webhook_count("subscription_updated", "error")
	testing.expect_value(t, receive_webhook(&service, signature_for(bad_status), bad_status).code, domain.Error_Code.Validation_Failed)
	testing.expect_value(t, webhook_count("subscription_updated", "error") - err_before, u64(1))

	not_json := `{nope`
	json_before := webhook_count("unknown", "error")
	testing.expect_value(t, receive_webhook(&service, signature_for(not_json), not_json).code, domain.Error_Code.Validation_Failed)
	testing.expect_value(t, webhook_count("unknown", "error") - json_before, u64(1))
}
