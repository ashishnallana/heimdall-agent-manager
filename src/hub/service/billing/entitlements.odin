package billing

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:time"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"

ENTITLEMENTS_TTL_SECONDS :: 30
ENTITLEMENTS_CACHE_CAPACITY :: 256

Entitlement_Cache_Entry :: struct {
	entitlements: domain.User_Entitlements,
	loaded_at: i64,
	expires_at: i64,
}

// Enforcement is independent of checkout readiness. Partial Paddle setup still
// enables limits; an explicit operator override always wins. The default sandbox
// environment and grace duration alone do not count as a Paddle integration.
plan_limits_enabled :: proc(config: Config) -> bool {
	if enforce, explicit := config.enforce_plan_limits.?; explicit do return enforce
	return config.api_key != "" || config.client_token != "" ||
		config.webhook_secret != "" || config.hobbyist_price_id != ""
}

// Serialize fills and invalidations so an in-flight read cannot repopulate an
// obsolete entry after a webhook or an application override invalidates it.
// No repository transaction runs on a hit. Keys use the heap, never request arenas.
effective_entitlements :: proc(service: ^Service, user_id: string) -> (domain.User_Entitlements, domain.Domain_Error) {
	if service == nil || !plan_limits_enabled(service.config) do return domain.unlimited_entitlements(), {}
	sync.mutex_lock(&service.entitlements_mutex)
	defer sync.mutex_unlock(&service.entitlements_mutex)
	now := platform.clock_now(service.clock)
	if now == "" do now = platform.real_clock_now(nil)
	parsed, valid_time := platform.parse_rfc3339_utc(now)
	seconds := time.to_unix_seconds(parsed)
	if entry, found := service.entitlements_cache[user_id]; valid_time && found && seconds >= entry.loaded_at && seconds < entry.expires_at {
		return entry.entitlements, {}
	}
	if service.repo == nil || service.repo.get_account == nil do return {}, domain.domain_error(.Internal_Error, "billing repository is not configured")
	account, err := service.repo.get_account(service.repo.ctx, user_id, now)
	if err.code != .None do return {}, err // Do not cache failures or grant access on storage failure.
	if valid_time {
		expires := seconds + ENTITLEMENTS_TTL_SECONDS
		// A cached paid grant must not outlive its past_due grace boundary.
		if account.status == "past_due" {
			if grace, ok := platform.parse_rfc3339_utc(account.grace_until); ok {
				grace_seconds := time.to_unix_seconds(grace)
				if grace_seconds > seconds && grace_seconds < expires do expires = grace_seconds
			}
		}
		if len(service.entitlements_cache) >= ENTITLEMENTS_CACHE_CAPACITY do clear_entitlements_locked(service)
		if service.entitlements_cache == nil do service.entitlements_cache = make(map[string]Entitlement_Cache_Entry, runtime.heap_allocator())
		cache_key := ""
		for key in service.entitlements_cache {
			if key == user_id { cache_key = key; break }
		}
		if cache_key == "" do cache_key = strings.clone(user_id, runtime.heap_allocator())
		service.entitlements_cache[cache_key] = {account.entitlements, seconds, expires}
	}
	return account.entitlements, {}
}

// user_id="" clears all users, useful when a webhook has only a subscription ID.
// Call after application override writes; manual SQL changes are observed by TTL.
invalidate_entitlements :: proc(service: ^Service, user_id := "") {
	if service == nil do return
	sync.mutex_lock(&service.entitlements_mutex)
	defer sync.mutex_unlock(&service.entitlements_mutex)
	if user_id == "" {
		clear_entitlements_locked(service)
		return
	}
	// Delete the owned key, not the caller's temporary user_id.
	for key in service.entitlements_cache {
		if key == user_id {
			delete_key(&service.entitlements_cache, key)
			delete(key, runtime.heap_allocator())
			break
		}
	}
}

@(private)
clear_entitlements_locked :: proc(service: ^Service) {
	for key in service.entitlements_cache do delete(key, runtime.heap_allocator())
	delete(service.entitlements_cache)
	service.entitlements_cache = nil
}

// Call once consumers have stopped during graph shutdown.
service_free :: proc(service: ^Service) {
	invalidate_entitlements(service)
}

entitlement_lookup :: proc(service: ^Service) -> domain.Entitlement_Lookup {
	return {ctx = service, lookup = entitlement_lookup_callback}
}

@(private)
entitlement_lookup_callback :: proc(ctx: rawptr, user_id: string) -> (domain.User_Entitlements, domain.Domain_Error) {
	return effective_entitlements((^Service)(ctx), user_id)
}
