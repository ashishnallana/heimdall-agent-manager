package billing

import "core:crypto/hmac"
import "core:fmt"
import "core:encoding/hex"
import "core:encoding/json"
import "core:strconv"
import "core:strings"
import "core:time"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"

// Paddle signs the original bytes as ts:rawBody. Multiple h1 values support
// rotation; verification is constant time and timestamps have a five-minute bound.
verify_signature :: proc(secret, signature, body: string, now_seconds: i64) -> bool {
	if secret == "" || signature == "" || len(body) > 1024*1024 do return false
	parts := strings.split(signature, ";")
	timestamp := ""
	for part in parts {
		value := strings.trim_space(part)
		if strings.has_prefix(value, "ts=") {
			if timestamp != "" do return false
			timestamp = value[3:]
		}
	}
	ts, ok := strconv.parse_i64(timestamp)
	if !ok || ts < now_seconds - 300 || ts > now_seconds + 30 do return false
	message := strings.concatenate({timestamp, ":", body})
	for part in parts {
		value := strings.trim_space(part)
		if !strings.has_prefix(value, "h1=") || len(value) != 67 do continue
		tag, decode_err := hex.decode(transmute([]byte)value[3:], context.temp_allocator)
		if !decode_err || len(tag) != 32 do continue
		if hmac.verify(.SHA256, tag, transmute([]byte)message, transmute([]byte)secret) do return true
	}
	return false
}

receive_webhook :: proc(service: ^Service, signature, body: string) -> domain.Domain_Error {
	event_type, result, err := receive_webhook_classified(service, signature, body)
	m := service.metrics
	if m == nil do m = &billing_metrics
	if err.code == .None && result == "ok" {
		invalidate_entitlements(service)
		// The event is durable; a per-owner reconciliation failure must not fail
		// the webhook. Cache fills and the reaper retry failed owners.
		if service.on_plan_change != nil {
			if plan_err := service.on_plan_change(service.plan_change_ctx); plan_err.code != .None {
				fmt.eprintfln("hub: webhook bridge plan reconciliation incomplete: %s", plan_err.message)
			}
		}
	}
	billing_metrics_record_webhook(m, event_type, result)
	return err
}

// receive_webhook_classified is receive_webhook plus the two facts the metric
// needs: the Paddle event type (raw; enum-mapped by the metrics layer) and the
// outcome class. Split so every return path reports exactly one outcome.
@(private)
receive_webhook_classified :: proc(service: ^Service, signature, body: string) -> (event_type: string, result: string, err: domain.Domain_Error) {
	now := platform.clock_now(service.clock)
	parsed_now, _ := platform.parse_rfc3339_utc(now)
	if !verify_signature(service.config.webhook_secret, signature, body, time.to_unix_seconds(parsed_now)) do return "", "invalid_signature", domain.domain_error(.Unauthenticated, "invalid Paddle webhook signature")
	payload: struct {
		event_id: string,
		event_type: string,
		occurred_at: string,
		data: struct {
			id: string,
			status: string,
			customer_id: string,
			next_billed_at: string,
			scheduled_change: struct {action: string, effective_at: string},
			custom_data: struct {heimdall_checkout_reference: string},
			items: []struct {price: struct {id: string}},
		},
	}
	if json.unmarshal_string(body, &payload, .JSON, context.temp_allocator) != nil do return "", "error", domain.domain_error(.Validation_Failed, "invalid Paddle event JSON")
	event_type = payload.event_type
	if !strings.has_prefix(payload.event_id, "evt_") do return event_type, "error", domain.domain_error(.Validation_Failed, "Paddle event ID is required")
	if !strings.has_prefix(payload.event_type, "subscription.") do return event_type, "ignored", {} // Non-subscription notifications do not grant access.
	occurred, valid_time := parse_paddle_time(payload.occurred_at)
	if !valid_time || !strings.has_prefix(payload.data.id, "sub_") || !strings.has_prefix(payload.data.customer_id, "ctm_") || len(payload.data.items) != 1 do return event_type, "error", domain.domain_error(.Validation_Failed, "invalid subscription event")
	switch payload.data.status {
	case "active", "trialing", "past_due", "paused", "canceled":
	case: return event_type, "error", domain.domain_error(.Validation_Failed, "unsupported subscription status")
	}
	cancels_at := ""
	if payload.data.scheduled_change.action == "cancel" do cancels_at = payload.data.scheduled_change.effective_at
	grace_until := ""
	if payload.data.status == "past_due" && service.config.past_due_grace_seconds > 0 do grace_until = platform.format_rfc3339_utc(time.time_add(occurred, time.Duration(service.config.past_due_grace_seconds)*time.Second))
	err = service.repo.apply_event(service.repo.ctx, domain.Billing_Event{event_id = payload.event_id, event_type = payload.event_type, occurred_ns = time.to_unix_nanoseconds(occurred), checkout_reference = payload.data.custom_data.heimdall_checkout_reference, subscription_id = payload.data.id, customer_id = payload.data.customer_id, price_id = payload.data.items[0].price.id, status = payload.data.status, renews_at = payload.data.next_billed_at, cancels_at = cancels_at, grace_until = grace_until}, now)
	return event_type, "ok" if err.code == .None else "error", err
}

// core:time in the pinned Odin release only parses two fractional digits.
// Paddle timestamps use microseconds; retain all digits for event ordering.
parse_paddle_time :: proc(value: string) -> (time.Time, bool) {
	if len(value) < 20 do return {}, false
	base := value
	nanos: i64
	if value[19] == '.' {
		end := 20
		for end < len(value) && value[end] >= '0' && value[end] <= '9' do end += 1
		digits := end - 20
		if digits < 1 || digits > 9 || end >= len(value) do return {}, false
		parsed, ok := strconv.parse_i64(value[20:end])
		if !ok do return {}, false
		nanos = parsed
		for _ in digits..<9 do nanos *= 10
		base = strings.concatenate({value[:19], value[end:]})
	}
	parsed, consumed := time.rfc3339_to_time_utc(base)
	if consumed != len(base) || consumed == 0 do return {}, false
	return time.time_add(parsed, time.Duration(nanos)), true
}
