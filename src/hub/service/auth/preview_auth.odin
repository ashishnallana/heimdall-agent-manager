package auth

import "base:runtime"
import "core:crypto/hmac"
import "core:fmt"
import "core:strconv"
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
// Browser binding for the handoff: set on the preview host when it starts a
// sign-in bounce; the ticket carries sha256(bind value) and is only redeemable
// by the browser holding that bind cookie (stops a planted ticket — login CSRF).
// Each flow has its own cookie, `__Host-heimdall_preview_bind_<id>`, so
// concurrent previews never clobber each other, and the value carries an HMAC
// tag under a per-process key, so only hub-minted bind cookies count (a
// previewed app's script could plant a non-HttpOnly cookie of the same name).
PREVIEW_BIND_COOKIE :: "__Host-heimdall_preview_bind"
PREVIEW_BIND_ID_BYTES :: 6 // 8 base64url characters
// A browser that does not keep the preview cookie would bounce forever; give up
// after this many consecutive bounces.
PREVIEW_MAX_HOPS :: 3
// At most this many bind cookies live at once on the preview host; a bounce that
// finds more expires them before minting its own (cookie-bomb cap).
PREVIEW_MAX_BIND_COOKIES :: 4
// After a successful handoff the bounce count is remembered for a short while in
// this host-only cookie (the URL carries it only from the second hop on).
PREVIEW_HOP_COOKIE :: "__Host-heimdall_preview_hop"
PREVIEW_HOP_TTL_S :: 30
PREVIEW_BIND_TTL_S :: 300
// At most this many preview sessions per parent session (oldest replaced).
PREVIEW_MAX_PER_PARENT :: 32
PREVIEW_TICKET_TTL_MS :: 60_000
PREVIEW_PARENT_RECHECK_MS :: 15_000
PREVIEW_MAX_TICKETS :: 4096
PREVIEW_MAX_SESSIONS :: 16384

Preview_Ticket :: struct {
	user_id, parent_session_hash, shell_session_id, return_to, bind_hash, bind_id: string,
	hop: int,
	expires_ms: i64,
}

Preview_Session :: struct {
	user_id, parent_session_hash: string,
	expires_ms: i64,
	created_ms: i64,
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
	delete(key, a); delete(t.user_id, a); delete(t.parent_session_hash, a); delete(t.shell_session_id, a); delete(t.return_to, a); delete(t.bind_hash, a); delete(t.bind_id, a)
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
preview_bind_hash_ok :: proc(bind_hash: string) -> bool {
	if len(bind_hash) != 64 do return false
	for c in transmute([]byte)bind_hash do if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) do return false
	return true
}

preview_bind_id_ok :: proc(bind_id: string) -> bool {
	if len(bind_id) != 8 do return false
	for c in transmute([]byte)bind_id do if !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_') do return false
	return true
}

preview_bind_cookie_name :: proc(bind_id: string) -> string {
	return strings.concatenate({PREVIEW_BIND_COOKIE, "_", bind_id}, context.temp_allocator)
}

// The tag covers the flow id, the random part and the mint time (Unix ms), under
// a key derived only for this purpose.
@(private = "file")
preview_bind_tag :: proc(service: ^Auth_Service, bind_id, raw, ts: string) -> (string, bool) {
	key, ok := hub_subkey(service, HUB_SUBKEY_PREVIEW_BIND)
	if !ok do return "", false
	msg := strings.concatenate({bind_id, "|", raw, "|", ts}, context.temp_allocator)
	tag: [32]byte
	hmac.sum(.SHA256, tag[:], transmute([]byte)msg, key[:])
	return base64url_encode(tag[:16]), true
}

// preview_bind_new mints a flow id and a hub-tagged, timestamped bind value
// (`<random>.<unix ms>.<tag>`, the cookie value).
preview_bind_new :: proc(service: ^Auth_Service) -> (bind_id, value: string, ok: bool) {
	id, id_ok := random_token(PREVIEW_BIND_ID_BYTES)
	raw, raw_ok := random_token(32)
	now, now_ok := now_unix_ms(service)
	if !id_ok || !raw_ok || !now_ok do return "", "", false
	ts := fmt.tprintf("%d", now)
	tag, tag_ok := preview_bind_tag(service, id, raw, ts)
	if !tag_ok do return "", "", false
	return id, strings.concatenate({raw, ".", ts, ".", tag}, context.temp_allocator), true
}

// preview_bind_value_ok verifies the hub's HMAC tag on a bind cookie value and
// that it was minted within the bind window (a harvested value goes stale even
// if a browser keeps the cookie past its Max-Age).
preview_bind_value_ok :: proc(service: ^Auth_Service, bind_id, value: string) -> bool {
	if len(value) > 160 do return false
	parts := strings.split(value, ".", context.temp_allocator)
	if len(parts) != 3 || parts[0] == "" || parts[1] == "" do return false
	want, ok := preview_bind_tag(service, bind_id, parts[0], parts[1])
	if !ok || !oidc_constant_time_equal(want, parts[2]) do return false
	minted, ts_ok := strconv.parse_i64(parts[1])
	now, now_ok := now_unix_ms(service)
	if !ts_ok || !now_ok do return false
	return minted <= now + 60_000 && now - minted <= PREVIEW_BIND_TTL_S * 1000
}

preview_ticket_mint :: proc(service: ^Auth_Service, principal: contracts.Auth_Context, shell_session_id, return_to, bind_hash, bind_id: string, hop := 1) -> (string, domain.Domain_Error) {
	if principal.kind != .Session || principal.session_id == "" do return "", domain.domain_error(.Forbidden, "a browser session is required to open a preview")
	if !preview_bind_hash_ok(bind_hash) || !preview_bind_id_ok(bind_id) do return "", domain.domain_error(.Validation_Failed, "invalid preview bind")
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
		bind_hash = strings.clone(bind_hash, a),
		bind_id = strings.clone(bind_id, a),
		hop = clamp(hop, 1, PREVIEW_MAX_HOPS),
		expires_ms = now + PREVIEW_TICKET_TTL_MS,
	}
	return raw, {}
}

// preview_ticket_redeem consumes a ticket (single use, even on failure) and
// creates a preview session bound to the ticket's parent session. Only the
// browser holding this flow's hub-minted bind cookie may redeem it. Returns the
// raw preview session id (cookie value), its max age, the return_to path, the
// flow's bind cookie name (to clear) and the bounce hop count.
preview_ticket_redeem :: proc(service: ^Auth_Service, raw_ticket: string, headers: []contracts.HTTP_Header) -> (preview_id: string, max_age_s: i64, return_to: string, bind_cookie: string, hop: int, stage: string, ok: bool) {
	if raw_ticket == "" || len(raw_ticket) > 128 do return "", 0, "", "", 0, "ticket_missing", false
	now, now_ok := now_unix_ms(service)
	if !now_ok do return "", 0, "", "", 0, "clock", false
	store := &service.preview
	sync.mutex_lock(&store.mutex)
	if store.tickets == nil {
		sync.mutex_unlock(&store.mutex)
		return "", 0, "", "", 0, "ticket_unknown", false
	}
	hash := sha256_hex(raw_ticket)
	if _, found := store.tickets[hash]; !found {
		sync.mutex_unlock(&store.mutex)
		return "", 0, "", "", 0, "ticket_unknown", false
	}
	key, ticket := delete_key(&store.tickets, hash)
	sync.mutex_unlock(&store.mutex)
	t := context.temp_allocator
	user_id, parent, target := strings.clone(ticket.user_id, t), strings.clone(ticket.parent_session_hash, t), strings.clone(ticket.return_to, t)
	cookie_name := preview_bind_cookie_name(ticket.bind_id)
	bind_value, has_bind := cookie_value(headers, cookie_name)
	expired := ticket.expires_ms <= now
	bound := has_bind && preview_bind_value_ok(service, ticket.bind_id, bind_value) && oidc_constant_time_equal(sha256_hex(bind_value), ticket.bind_hash)
	hops := ticket.hop
	preview_free_ticket(key, ticket)
	if expired do return "", 0, "", cookie_name, hops, "ticket_expired", false
	// Only the browser that started this sign-in may redeem the ticket.
	if !bound do return "", 0, "", cookie_name, hops, "bind_mismatch", false
	bind_cookie = cookie_name
	hop = hops
	row, live := session_lookup_live(service, parent, now)
	if !live || row.user_id != user_id do return "", 0, "", bind_cookie, hop, "parent_session", false
	raw, raw_ok := random_token(32)
	if !raw_ok do return "", 0, "", bind_cookie, hop, "random", false
	a := runtime.heap_allocator()
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)
	if store.sessions == nil do store.sessions = make(map[string]Preview_Session, a)
	preview_prune(store, now)
	if len(store.sessions) >= PREVIEW_MAX_SESSIONS do return "", 0, "", bind_cookie, hop, "capacity", false
	// Bound per parent session: replace the oldest beyond the cap.
	for {
		count := 0
		oldest_key := ""
		oldest := max(i64)
		for k, ps in store.sessions {
			if ps.parent_session_hash != parent do continue
			count += 1
			if ps.created_ms < oldest {oldest = ps.created_ms; oldest_key = k}
		}
		if count < PREVIEW_MAX_PER_PARENT do break
		k2, ps2 := delete_key(&store.sessions, oldest_key)
		preview_free_session(k2, ps2)
	}
	store.sessions[strings.clone(sha256_hex(raw), a)] = Preview_Session{
		user_id = strings.clone(user_id, a),
		parent_session_hash = strings.clone(parent, a),
		expires_ms = row.expires_at_ms,
		created_ms = now,
		parent_checked_until_ms = now + PREVIEW_PARENT_RECHECK_MS,
	}
	return raw, max((row.expires_at_ms - now) / 1000, 1), target, bind_cookie, hop, "", true
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

preview_bind_cookie_header :: proc(bind_id, value: string) -> string {
	return fmt.tprintf("%s=%s; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=%d", preview_bind_cookie_name(bind_id), value, PREVIEW_BIND_TTL_S)
}

// preview_bind_cookie_names lists the per-flow bind cookies a request carries.
preview_bind_cookie_names :: proc(headers: []contracts.HTTP_Header) -> []string {
	prefix := strings.concatenate({PREVIEW_BIND_COOKIE, "_"}, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	for h in headers {
		if !ascii_equal_fold(h.name, "Cookie") do continue
		rest := h.value
		for part in strings.split_iterator(&rest, ";") {
			pair := strings.trim_space(part)
			eq := strings.index_byte(pair, '=')
			if eq <= 0 do continue
			if strings.has_prefix(pair[:eq], prefix) do append(&names, pair[:eq])
		}
	}
	return names[:]
}

preview_hop_cookie_header :: proc(hop: int) -> string {
	return fmt.tprintf("%s=%d; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=%d", PREVIEW_HOP_COOKIE, hop, PREVIEW_HOP_TTL_S)
}
