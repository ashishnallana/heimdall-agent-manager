package auth

import "base:runtime"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import user_service "odin_test:hub/service/user"

// Memory_Session_Store is an in-process Session_Repository (tests and tools that
// run without SQLite). It holds only session/login-state hashes, like the SQLite
// store. It is not an authentication bypass: a session still has to be created
// through web_login_complete or mint_session, which needs in-process access.
Memory_Session_Store :: struct {
	mutex:    sync.Mutex,
	sessions: map[string]iface.User_Session,
	repo:     iface.Session_Repository,
}

@(private = "file")
memory_store_clone_session :: proc(s: iface.User_Session, a: runtime.Allocator) -> iface.User_Session {
	out := s
	out.session_id_hash = strings.clone(s.session_id_hash, a)
	out.user_id = strings.clone(s.user_id, a)
	out.id_token = strings.clone(s.id_token, a)
	out.user_agent = strings.clone(s.user_agent, a)
	return out
}

@(private = "file")
memory_store_free_session :: proc(s: iface.User_Session) {
	a := runtime.heap_allocator()
	delete(s.session_id_hash, a); delete(s.user_id, a); delete(s.id_token, a); delete(s.user_agent, a)
}


new_memory_session_store :: proc() -> ^Memory_Session_Store {
	a := runtime.heap_allocator()
	store := new(Memory_Session_Store, a)
	store.sessions = make(map[string]iface.User_Session, a)
	store.repo = iface.Session_Repository{
		ctx = store,
		create_session = memory_session_create,
		get_session = memory_session_get,
		touch_session = memory_session_touch,
		delete_session = memory_session_delete,
		purge_expired = memory_session_purge,
	}
	return store
}

free_memory_session_store :: proc(store: ^Memory_Session_Store) {
	if store == nil do return
	a := runtime.heap_allocator()
	for k, v in store.sessions {delete(k, a); memory_store_free_session(v)}
	delete(store.sessions)
	free(store, a)
}

@(private = "file")
memory_session_create :: proc(ctx: rawptr, session: iface.User_Session) -> domain.Domain_Error {
	store := (^Memory_Session_Store)(ctx)
	sync.mutex_lock(&store.mutex); defer sync.mutex_unlock(&store.mutex)
	if _, exists := store.sessions[session.session_id_hash]; exists do return domain.domain_error(.Conflict, "session exists")
	a := runtime.heap_allocator()
	store.sessions[strings.clone(session.session_id_hash, a)] = memory_store_clone_session(session, a)
	return {}
}

@(private = "file")
memory_session_get :: proc(ctx: rawptr, hash: string) -> (iface.User_Session, bool, domain.Domain_Error) {
	store := (^Memory_Session_Store)(ctx)
	sync.mutex_lock(&store.mutex); defer sync.mutex_unlock(&store.mutex)
	row, found := store.sessions[hash]
	if !found do return {}, false, {}
	return memory_store_clone_session(row, context.temp_allocator), true, {}
}

@(private = "file")
memory_session_touch :: proc(ctx: rawptr, hash: string, now_ms, idle_expires_at_ms: i64) -> domain.Domain_Error {
	store := (^Memory_Session_Store)(ctx)
	sync.mutex_lock(&store.mutex); defer sync.mutex_unlock(&store.mutex)
	if row, found := &store.sessions[hash]; found {
		row.last_seen_at_ms = now_ms
		row.idle_expires_at_ms = min(idle_expires_at_ms, row.expires_at_ms)
	}
	return {}
}

@(private = "file")
memory_session_delete :: proc(ctx: rawptr, hash: string) -> (iface.User_Session, bool, domain.Domain_Error) {
	store := (^Memory_Session_Store)(ctx)
	sync.mutex_lock(&store.mutex); defer sync.mutex_unlock(&store.mutex)
	if _, found := store.sessions[hash]; !found do return {}, false, {}
	key, row := delete_key(&store.sessions, hash)
	out := memory_store_clone_session(row, context.temp_allocator)
	delete(key, runtime.heap_allocator())
	memory_store_free_session(row)
	return out, true, {}
}



@(private = "file")
memory_session_purge :: proc(ctx: rawptr, now_ms: i64) -> (int, domain.Domain_Error) {
	store := (^Memory_Session_Store)(ctx)
	sync.mutex_lock(&store.mutex); defer sync.mutex_unlock(&store.mutex)
	expired := make([dynamic]string, context.temp_allocator)
	for k, v in store.sessions do if v.expires_at_ms <= now_ms || v.idle_expires_at_ms <= now_ms do append(&expired, k)
	removed := 0
	for k in expired {
		key, row := delete_key(&store.sessions, k)
		delete(key, runtime.heap_allocator()); memory_store_free_session(row); removed += 1
	}
	return removed, {}
}

// use_memory_sessions wires an in-memory session store and enables cookie
// sessions on `service` (tests, in-process tools). Pair with
// release_memory_sessions.
use_memory_sessions :: proc(service: ^Auth_Service) -> ^Memory_Session_Store {
	store := new_memory_session_store()
	service.sessions = &store.repo
	service.web.enabled = true
	return store
}

release_memory_sessions :: proc(service: ^Auth_Service, store: ^Memory_Session_Store) {
	if service != nil && service.sessions == &store.repo do service.sessions = nil
	free_memory_session_store(store)
}

// mint_session creates a browser session for an existing (or, when
// `ensure_user`, provisioned) user and returns the raw session id. It is the
// in-process equivalent of a completed OIDC login, used by tests and tools.
mint_session :: proc(service: ^Auth_Service, user_id: string, ensure_user := true) -> (string, bool) {
	if !web_login_enabled(service) do return "", false
	owner := user_id
	if ensure_user {
		user, ok, _ := user_service.ensure_user_from_auth(service.users, user_id, "", "", true)
		if !ok do return "", false
		owner = string(user.user_id)
	}
	now, now_ok := now_unix_ms(service)
	if !now_ok do return "", false
	raw, raw_ok := random_token(32)
	if !raw_ok do return "", false
	ttl := service.web.session_ttl_ms if service.web.session_ttl_ms > 0 else DEFAULT_SESSION_TTL_HOURS * 3_600_000
	idle := service.web.session_idle_ms if service.web.session_idle_ms > 0 else DEFAULT_SESSION_IDLE_HOURS * 3_600_000
	repo := service.sessions
	err := repo.create_session(repo.ctx, iface.User_Session{
		session_id_hash = sha256_hex(raw),
		user_id = owner,
		created_at_ms = now,
		last_seen_at_ms = now,
		expires_at_ms = now + ttl,
		idle_expires_at_ms = now + min(idle, ttl),
	})
	if err.code != .None do return "", false
	return strings.clone(raw), true
}

// session_cookie_request_header is the request `Cookie` header for a raw session id.
session_cookie_request_header :: proc(raw_session: string) -> contracts.HTTP_Header {
	return contracts.HTTP_Header{"Cookie", strings.concatenate({SESSION_COOKIE, "=", raw_session})}
}
