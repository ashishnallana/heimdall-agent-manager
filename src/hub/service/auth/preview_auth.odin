package auth

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import user_service "odin_test:hub/service/user"

// Preview-origin authentication (docs/plans/oidc-only-auth.md, phase 3).
//
// The dedicated preview origin is a different site-local host, so the Hub
// session cookie (__Host-, host-only) never reaches it. Instead the preview host
// gets its own host-only cookie, minted ON the preview origin from a one-time
// handoff ticket:
//
//   1. <ui_origin>/api/v1/preview-auth/start?session=<sid>&return_to=/p/<sid>/...
//      (Hub session required) mints a ticket: 32 random bytes, stored hashed,
//      single use, 60 s, bound to the user, the parent session and <sid>.
//   2. 302 to <preview_origin>/__heimdall/preview-auth?ticket=...; the Hub (not the
//      previewed app) redeems it, sets __Host-heimdall_preview and 302s to return_to.
//   3. Preview requests authenticate only with that cookie. Every use re-checks
//      (throttled) that the parent session is still live, so logout/expiry of the
//      main session ends the preview session too.
//
// Both tables are process memory: tickets live 60 s, and after a Hub restart a
// preview navigation simply bounces through step 1 again.

PREVIEW_COOKIE :: "__Host-heimdall_preview"
PREVIEW_TICKET_TTL_MS :: 60_000
PREVIEW_PARENT_RECHECK_MS :: 15_000
PREVIEW_MAX_TICKETS :: 4096
PREVIEW_MAX_SESSIONS :: 16384

Preview_Ticket :: struct {
	user_id, parent_session_hash, shell_session_id, return_to: string,
	expires_ms: i64,
}

Preview_Session :: struct {
	user_id, parent_session_hash: string,
	expires_ms: i64,
	parent_checked_until_ms: i64,
}

Preview_Auth_Store :: struct {
	mutex:    sync.Mutex,
	tickets:  map[string]Preview_Ticket,
	sessions: map[string]Preview_Session,
}

@(private = "file")
preview_free_ticket :: proc(key: string, t: Preview_Ticket) {
	a := runtime.heap_allocator()
	delete(key, a); delete(t.user_id, a); delete(t.parent_session_hash, a); delete(t.shell_session_id, a); delete(t.return_to, a)
}

@(private = "file")
preview_free_session :: proc(key: string, s: Preview_Session) {
	a := runtime.heap_allocator()
	delete(key, a); delete(s.user_id, a); delete(s.parent_session_hash, a)
}

// preview_prune drops expired entries (caller holds the mutex).
@(private = "file")
preview_prune :: proc(store: ^Preview_Auth_Store, now: i64) {
	dead := make([dynamic]string, context.temp_allocator)
	for k, t in store.tickets do if t.expires_ms <= now do append(&dead, k)
	for k in dead {key, t := delete_key(&store.tickets, k); preview_free_ticket(key, t)}
	clear(&dead)
	for k, s in store.sessions do if s.expires_ms <= now do append(&dead, k)
	for k in dead {key, s := delete_key(&store.sessions, k); preview_free_session(key, s)}
}

preview_auth_free :: proc(store: ^Preview_Auth_Store) {
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)
	for k, t in store.tickets do preview_free_ticket(k, t)
	for k, s in store.sessions do preview_free_session(k, s)
	delete(store.tickets)
	delete(store.sessions)
	store.tickets, store.sessions = nil, nil
}

// preview_return_to_ok: a same-origin relative path inside this preview session.
preview_return_to_ok :: proc(return_to, shell_session_id: string) -> bool {
	if _, ok := safe_return_to(return_to); !ok do return false
	prefix := strings.concatenate({"/p/", shell_session_id, "/"}, context.temp_allocator)
	return strings.has_prefix(return_to, prefix)
}

// preview_ticket_mint issues a handoff ticket for a browser Session principal.
// The caller has already checked that `shell_session_id` belongs to the user.
preview_ticket_mint :: proc(service: ^Auth_Service, principal: contracts.Auth_Context, shell_session_id, return_to: string) -> (string, domain.Domain_Error) {
	if principal.kind != .Session || principal.session_id == "" do return "", domain.domain_error(.Forbidden, "a browser session is required to open a preview")
	if shell_session_id == "" || strings.contains_any(shell_session_id, "/?#%\\") do return "", domain.domain_error(.Validation_Failed, "invalid preview session")
	if !preview_return_to_ok(return_to, shell_session_id) do return "", domain.domain_error(.Validation_Failed, "return_to must be a path inside the preview")
	now, now_ok := now_unix_ms(service)
	if !now_ok do return "", domain.domain_error(.Internal_Error, "clock unavailable")
	raw, raw_ok := random_token(32)
	if !raw_ok do return "", domain.domain_error(.Internal_Error, "random source unavailable")
	store := &service.preview
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)
	a := runtime.heap_allocator()
	if store.tickets == nil do store.tickets = make(map[string]Preview_Ticket, a)
	preview_prune(store, now)
	if len(store.tickets) >= PREVIEW_MAX_TICKETS do return "", domain.domain_error(.Rate_Limited, "too many pending preview sign-ins; retry shortly")
	store.tickets[strings.clone(sha256_hex(raw), a)] = Preview_Ticket{
		user_id = strings.clone(principal.user_id, a),
		parent_session_hash = strings.clone(principal.session_id, a),
		shell_session_id = strings.clone(shell_session_id, a),
		return_to = strings.clone(return_to, a),
		expires_ms = now + PREVIEW_TICKET_TTL_MS,
	}
	return raw, {}
}

// preview_ticket_redeem consumes a ticket (single use, even on failure) and
// creates a preview session bound to the ticket's parent session. Returns the
// raw preview session id (cookie value), its max age and the return_to path.
preview_ticket_redeem :: proc(service: ^Auth_Service, raw_ticket: string) -> (preview_id: string, max_age_s: i64, return_to: string, stage: string, ok: bool) {
	if raw_ticket == "" || len(raw_ticket) > 128 do return "", 0, "", "ticket_missing", false
	now, now_ok := now_unix_ms(service)
	if !now_ok do return "", 0, "", "clock", false
	store := &service.preview
	sync.mutex_lock(&store.mutex)
	if store.tickets == nil {
		sync.mutex_unlock(&store.mutex)
		return "", 0, "", "ticket_unknown", false
	}
	hash := sha256_hex(raw_ticket)
	if _, found := store.tickets[hash]; !found {
		sync.mutex_unlock(&store.mutex)
		return "", 0, "", "ticket_unknown", false
	}
	key, ticket := delete_key(&store.tickets, hash)
	sync.mutex_unlock(&store.mutex)
	t := context.temp_allocator
	user_id, parent, target := strings.clone(ticket.user_id, t), strings.clone(ticket.parent_session_hash, t), strings.clone(ticket.return_to, t)
	expired := ticket.expires_ms <= now
	preview_free_ticket(key, ticket)
	if expired do return "", 0, "", "ticket_expired", false
	row, live := session_lookup_live(service, parent, now)
	if !live || row.user_id != user_id do return "", 0, "", "parent_session", false
	raw, raw_ok := random_token(32)
	if !raw_ok do return "", 0, "", "random", false
	a := runtime.heap_allocator()
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)
	if store.sessions == nil do store.sessions = make(map[string]Preview_Session, a)
	preview_prune(store, now)
	if len(store.sessions) >= PREVIEW_MAX_SESSIONS do return "", 0, "", "capacity", false
	store.sessions[strings.clone(sha256_hex(raw), a)] = Preview_Session{
		user_id = strings.clone(user_id, a),
		parent_session_hash = strings.clone(parent, a),
		expires_ms = row.expires_at_ms,
		parent_checked_until_ms = now + PREVIEW_PARENT_RECHECK_MS,
	}
	return raw, max((row.expires_at_ms - now) / 1000, 1), target, "", true
}

// resolve_preview_auth authenticates a request on the preview origin. It looks
// only at __Host-heimdall_preview — never Authorization (owned by the previewed
// app) and never the Hub session cookie.
resolve_preview_auth :: proc(service: ^Auth_Service, headers: []contracts.HTTP_Header) -> (contracts.Auth_Context, bool, domain.Domain_Error) {
	fail := domain.domain_error(.Unauthenticated, "preview sign-in required")
	if service == nil || service.users == nil do return {}, false, fail
	raw, present := cookie_value(headers, PREVIEW_COOKIE)
	if !present || len(raw) < 32 || len(raw) > 128 do return {}, false, fail
	now, now_ok := now_unix_ms(service)
	if !now_ok do return {}, false, fail
	hash := sha256_hex(raw)
	store := &service.preview
	sync.mutex_lock(&store.mutex)
	entry: Preview_Session
	found := false
	if store.sessions != nil do entry, found = store.sessions[hash]
	if !found || entry.expires_ms <= now {
		sync.mutex_unlock(&store.mutex)
		return {}, false, fail
	}
	user_id, parent := strings.clone(entry.user_id, context.temp_allocator), strings.clone(entry.parent_session_hash, context.temp_allocator)
	recheck := now >= entry.parent_checked_until_ms
	sync.mutex_unlock(&store.mutex)
	if recheck {
		_, live := session_lookup_live(service, parent, now)
		sync.mutex_lock(&store.mutex)
		if live {
			if e, ok := &store.sessions[hash]; ok do e.parent_checked_until_ms = now + PREVIEW_PARENT_RECHECK_MS
		} else if hash in store.sessions {
			key, s := delete_key(&store.sessions, hash)
			preview_free_session(key, s)
		}
		sync.mutex_unlock(&store.mutex)
		if !live do return {}, false, fail
	}
	user, user_found, user_err := user_service.get_user(service.users, domain.User_ID(user_id))
	if !user_found || user_err.code != .None || user.status != .Active do return {}, false, fail
	return contracts.Auth_Context{
		kind = .Session,
		user_id = string(user.user_id),
		name = user.name,
		display_name = user.display_name,
		email = user.email,
		session_id = parent,
		expires_ms = entry.expires_ms,
	}, true, {}
}

// preview_end_for_parent drops every preview session derived from a parent
// session (called on logout).
preview_end_for_parent :: proc(service: ^Auth_Service, parent_session_hash: string) {
	if service == nil || parent_session_hash == "" do return
	store := &service.preview
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)
	if store.sessions == nil do return
	dead := make([dynamic]string, context.temp_allocator)
	for k, s in store.sessions do if s.parent_session_hash == parent_session_hash do append(&dead, k)
	for k in dead {key, s := delete_key(&store.sessions, k); preview_free_session(key, s)}
}

preview_cookie_header :: proc(raw: string, max_age_s: i64) -> string {
	return fmt.tprintf("%s=%s; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=%d", PREVIEW_COOKIE, raw, max_age_s)
}
