package push

import metrics "odin_test:lib/metrics"

// heimdall_push_sent_total{result} (hub telemetry plan 3.8). One increment per
// subscription per fan-out:
//   sent    - 2xx from the push service
//   gone    - 404/410, subscription pruned
//   failed  - 401/403 (auth), 429/5xx/other, transport or pre-send failure
//   skipped - fan-out requested while push is disabled (no VAPID keypair), or
//             the subscription list could not be read; counted once per call
Push_Metrics :: struct {
	sent_total: ^metrics.Family, // {result}
}

push_metrics: Push_Metrics

push_metrics_init :: proc(reg: ^metrics.Registry) {
	if reg == nil do return
	push_metrics.sent_total = metrics.new_counter(reg, "heimdall_push_sent_total",
		"Web Push delivery attempts by outcome.", {"result"})
	for r in ([]string{"sent", "gone", "failed", "skipped"}) do metrics.with(push_metrics.sent_total, r)
}

push_metrics_record :: proc(result: string) {
	metrics.counter_inc(metrics.with(push_metrics.sent_total, result))
}

push_metrics_result :: proc(class: Push_Send_Class) -> string {
	switch class {
	case .Success: return "sent"
	case .Gone:    return "gone"
	case .Auth_Failed, .Transient: return "failed"
	}
	return "failed"
}
