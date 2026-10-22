package domain

// Feature code consumes these account-scoped parameters, never a plan ID.
User_Entitlements :: struct {
	max_bridges: int, // -1 = unlimited; 0 permits none
	terminal_streaming_enabled: bool,
	terminal_input_enabled: bool,
	max_concurrent_streams: int, // -1 = unlimited; 0 permits none
	shells_enabled: bool,
}

Billing_Plan :: struct {
	plan_id: string,
	plan_label: string,
	price_id: string,
	entitlements: User_Entitlements,
}

Account_Billing :: struct {
	user_id: string,
	plan_id: string,
	plan_label: string,
	status: string,
	customer_id: string,
	subscription_id: string,
	price_id: string,
	renews_at: string,
	cancels_at: string,
	grace_until: string,
	last_event_ns: i64,
	entitlements: User_Entitlements,
	checkout_pending: bool,
	created_at: string,
	updated_at: string,
}

Billing_Checkout :: struct {
	reference: string,
	user_id: string,
	plan_id: string,
	price_id: string,
	transaction_id: string,
	expires_at: string,
}

Billing_Event :: struct {
	event_id: string,
	event_type: string,
	occurred_ns: i64,
	checkout_reference: string,
	subscription_id: string,
	customer_id: string,
	price_id: string,
	status: string,
	renews_at: string,
	cancels_at: string,
	grace_until: string,
}

// A zero-valued lookup is permissive for self-hosted hubs and isolated tests.
// Feature code can depend on this seam without importing the billing service.
Entitlement_Lookup :: struct {
	ctx: rawptr,
	lookup: proc(ctx: rawptr, user_id: string) -> (User_Entitlements, Domain_Error),
}

unlimited_entitlements :: proc() -> User_Entitlements {
	return {max_bridges = -1, terminal_streaming_enabled = true,
		terminal_input_enabled = true, max_concurrent_streams = -1, shells_enabled = true}
}

lookup_entitlements :: proc(source: Entitlement_Lookup, user_id: string) -> (User_Entitlements, Domain_Error) {
	if source.lookup == nil do return unlimited_entitlements(), {}
	return source.lookup(source.ctx, user_id)
}
