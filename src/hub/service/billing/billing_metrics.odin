package billing

import "core:strings"
import metrics "odin_test:lib/metrics"

// heimdall_billing_webhooks_total{event,result} (hub telemetry plan 3.8).
//   event:  Paddle event type enum-mapped below (unknown -> other). Both
//           labels are fixed sets, so a webhook sender cannot mint series.
//   result: ok | invalid_signature | ignored (non-subscription event) | error
//           (malformed payload, unsupported status, or repository failure)
Billing_Metrics :: struct {
	webhooks_total: ^metrics.Family, // {event, result}
}

billing_metrics: Billing_Metrics

billing_metrics_init :: proc(reg: ^metrics.Registry) {
	if reg == nil do return
	billing_metrics.webhooks_total = metrics.new_counter(reg, "heimdall_billing_webhooks_total",
		"Paddle webhook deliveries by event family and outcome.", {"event", "result"})
}

billing_metrics_record_webhook :: proc(event_type, result: string) {
	metrics.counter_inc(metrics.with(billing_metrics.webhooks_total, billing_webhook_event_enum(event_type), billing_webhook_result_enum(result)))
}

// billing_webhook_event_enum maps "subscription.<x>" onto a fixed set; an
// unsigned/unparseable delivery has no event type and maps to "unknown".
billing_webhook_event_enum :: proc(event_type: string) -> string {
	if event_type == "" do return "unknown"
	if !strings.has_prefix(event_type, "subscription.") {
		switch {
		case strings.has_prefix(event_type, "transaction."): return "transaction"
		case strings.has_prefix(event_type, "customer."):    return "customer"
		}
		return "other"
	}
	switch event_type[len("subscription."):] {
	case "created":   return "subscription_created"
	case "activated": return "subscription_activated"
	case "updated":   return "subscription_updated"
	case "trialing":  return "subscription_trialing"
	case "past_due":  return "subscription_past_due"
	case "paused":    return "subscription_paused"
	case "resumed":   return "subscription_resumed"
	case "canceled":  return "subscription_canceled"
	case "imported":  return "subscription_imported"
	}
	return "subscription_other"
}

billing_webhook_result_enum :: proc(result: string) -> string {
	switch result {
	case "ok", "invalid_signature", "ignored", "error":
		return result
	}
	return "other"
}
