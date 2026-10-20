package push

// Push_Service owns the persistence-facing operations for browser Web Push
// subscriptions: creating/updating (upsert-by-endpoint), listing, and deleting
// them. HTTP handlers (WP-API) call this so id/timestamp generation and
// validation live in one place rather than in the transport layer.
//
// Message sending (WP-SEND) will extend this service; for now it covers the
// subscription lifecycle behind the /me/push-subscriptions endpoints.

import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// Vapid_Config carries the keypair + contact subject used to sign VAPID JWTs
// for outbound push. When public_key/private_key are empty, sending is disabled.
Vapid_Config :: struct {
	public_key:  string,
	private_key: string,
	subject:     string,
}

Push_Service :: struct {
	subscriptions: ^iface.Push_Repository,
	clock:         ^platform.Clock,
	ids:           ^platform.ID_Generator,
	vapid:         Vapid_Config,
}

new_push_service :: proc(
	subscriptions: ^iface.Push_Repository,
	clock: ^platform.Clock,
	ids: ^platform.ID_Generator,
	vapid: Vapid_Config = {},
) -> Push_Service {
	return Push_Service{subscriptions = subscriptions, clock = clock, ids = ids, vapid = vapid}
}

// push_send_enabled reports whether outbound push is possible (a VAPID keypair
// is present). Subscription CRUD works regardless.
push_send_enabled :: proc(service: ^Push_Service) -> bool {
	return service != nil && service.vapid.public_key != "" && service.vapid.private_key != ""
}

// Save_Subscription_Input is the browser PushSubscription reduced to the fields
// we persist. endpoint/p256dh/auth come straight from PushSubscription.toJSON().
Save_Subscription_Input :: struct {
	owner_user_id: domain.User_ID,
	endpoint:      string,
	p256dh:        string,
	auth:          string,
}

// save_subscription upserts a subscription by endpoint and returns the stored
// row (with its persisted id). Re-subscribing with the same endpoint replaces
// the keys instead of creating a duplicate.
save_subscription :: proc(service: ^Push_Service, input: Save_Subscription_Input) -> (domain.Push_Subscription, bool, domain.Domain_Error) {
	if service == nil || service.subscriptions == nil {
		return domain.Push_Subscription{}, false, domain.domain_error(.Internal_Error, "push service is not configured")
	}
	if domain.id_is_empty(string(input.owner_user_id)) {
		return domain.Push_Subscription{}, false, domain.domain_error(.Unauthenticated, "owner is required")
	}
	endpoint := strings.trim_space(input.endpoint)
	p256dh := strings.trim_space(input.p256dh)
	auth := strings.trim_space(input.auth)
	if endpoint == "" || p256dh == "" || auth == "" {
		return domain.Push_Subscription{}, false, domain.domain_error(.Validation_Failed, "endpoint, keys.p256dh and keys.auth are required")
	}

	now := platform.clock_now(service.clock)
	sub := domain.Push_Subscription{
		id            = domain.Push_Subscription_ID(platform.generate_id(service.ids, "psub_")),
		owner_user_id = input.owner_user_id,
		endpoint      = endpoint,
		p256dh        = p256dh,
		auth          = auth,
		created_at    = now,
		updated_at    = now,
	}
	return iface.push_subscription_upsert(service.subscriptions, sub)
}

// delete_subscription removes a subscription owned by the caller, identified by
// endpoint. It returns true when a row was removed.
delete_subscription :: proc(service: ^Push_Service, owner_user_id: domain.User_ID, endpoint: string) -> (bool, domain.Domain_Error) {
	if service == nil || service.subscriptions == nil {
		return false, domain.domain_error(.Internal_Error, "push service is not configured")
	}
	trimmed := strings.trim_space(endpoint)
	if trimmed == "" {
		return false, domain.domain_error(.Validation_Failed, "endpoint is required")
	}
	return iface.push_subscription_delete_by_endpoint(service.subscriptions, owner_user_id, trimmed)
}
