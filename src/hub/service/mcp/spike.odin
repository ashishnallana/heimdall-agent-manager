package mcp

// U0 interoperability probe only. These credentials authorize synthetic results,
// never Hub business services or vault operations. U1 supplies durable grants and
// reviewed sealed capability envelopes; this store is intentionally process-local.
import "base:runtime"
import "core:strings"
import "core:sync"
import auth "odin_test:hub/service/auth"
import httpc "odin_test:lib/httpc"

SCOPE :: "mcp:probe"
LIMIT :: 256
CODE_TTL :: 120_000
ACCESS_TTL :: 600_000
REFRESH_TTL :: 3_600_000

Client :: struct { redirect: string }
Pending :: struct {form: string, expires: i64}
Credential :: struct {
	user, client, redirect, challenge: string,
	expires: i64,
}
Tokens :: struct {
	access_token, refresh_token: string,
	token_type: string,
	expires_in: int,
	scope: string,
}
Store :: struct {
	mutex: sync.Mutex,
	clients: map[string]Client,
	pending: map[string]Pending,
	codes, access, refresh: map[string]Credential,
}

init :: proc(s: ^Store) {
	a := runtime.heap_allocator()
	s.clients = make(map[string]Client, a)
	s.pending = make(map[string]Pending, a)
	s.codes = make(map[string]Credential, a)
	s.access = make(map[string]Credential, a)
	s.refresh = make(map[string]Credential, a)
}
free_credential :: proc(c: Credential) {
	a := runtime.heap_allocator()
	delete(c.user, a); delete(c.client, a); delete(c.redirect, a); delete(c.challenge, a)
}
free :: proc(s: ^Store) {
	a := runtime.heap_allocator()
	for k, c in s.clients {delete(k, a); delete(c.redirect, a)}
	for k, p in s.pending {delete(k, a); delete(p.form, a)}
	delete(s.pending)
	for table in ([]^map[string]Credential{&s.codes, &s.access, &s.refresh}) {
		for k, c in table^ {delete(k, a); free_credential(c)}
		delete(table^)
	}
	delete(s.clients)
}
clone_credential :: proc(c: Credential) -> Credential {
	a := runtime.heap_allocator()
	return {strings.clone(c.user, a), strings.clone(c.client, a), strings.clone(c.redirect, a), strings.clone(c.challenge, a), c.expires}
}
remove :: proc(table: ^map[string]Credential, key: string) {
	c, exists := table^[key]
	if !exists do return
	k, _ := delete_key(table, key)
	delete(k, runtime.heap_allocator()); free_credential(c)
}
sweep :: proc(s: ^Store, now: i64) {
	dead_pending := make([dynamic]string, context.temp_allocator)
	for k, p in s.pending do if p.expires <= now do append(&dead_pending, k)
	for k in dead_pending {
		key, p := delete_key(&s.pending, k)
		delete(key, runtime.heap_allocator()); delete(p.form, runtime.heap_allocator())
	}
	for table in ([]^map[string]Credential{&s.codes, &s.access, &s.refresh}) {
		dead := make([dynamic]string, context.temp_allocator)
		for k, c in table^ do if c.expires <= now do append(&dead, k)
		for k in dead do remove(table, k)
	}
}
// Keep OAuth query data out of the existing login return_to: that validator
// correctly refuses embedded absolute URLs, including redirect_uri/resource.
pending_begin :: proc(s: ^Store, form: string, now: i64) -> (string, bool) {
	sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
	sweep(s, now)
	if len(s.pending) >= LIMIT || len(form) > 8192 do return "", false
	raw, ok := auth.random_token()
	if !ok do return "", false
	a := runtime.heap_allocator()
	s.pending[strings.clone(auth.sha256_hex(raw), a)] = {strings.clone(form, a), now + 300_000}
	return raw, true
}
pending_read :: proc(s: ^Store, raw: string, now: i64, consume := false) -> (string, bool) {
	if len(raw) != 43 do return "", false
	sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
	hash := auth.sha256_hex(raw)
	p, ok := s.pending[hash]
	if !ok || p.expires <= now do return "", false
	form := strings.clone(p.form, context.temp_allocator)
	if consume {
		key, entry := delete_key(&s.pending, hash)
		delete(key, runtime.heap_allocator()); delete(entry.form, runtime.heap_allocator())
	}
	return form, true
}

// No metadata URL fetches: registration cannot initiate SSRF. Restrict this probe
// to HTTPS redirects with no fragment, userinfo, controls or backslash ambiguity.
redirect_ok :: proc(uri: string) -> bool {
	if len(uri) > 2048 || !strings.has_prefix(uri, "https://") do return false
	rest := uri[len("https://"):]
	if rest == "" || rest[0] == '/' || rest[0] == '?' do return false
	for ch in uri do if ch <= ' ' || ch == '#' || ch == '@' || ch == '\\' do return false
	_, err := httpc.parse_url(uri)
	return err == .None
}
register :: proc(s: ^Store, redirect: string) -> (string, bool) {
	if !redirect_ok(redirect) do return "", false
	sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
	if len(s.clients) >= LIMIT do return "", false
	id, ok := auth.random_token()
	if !ok do return "", false
	a := runtime.heap_allocator()
	s.clients[strings.clone(id, a)] = {strings.clone(redirect, a)}
	return id, true
}
binding_ok :: proc(s: ^Store, client, redirect: string) -> bool {
	sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
	c, ok := s.clients[client]
	return ok && c.redirect == redirect
}
challenge_ok :: proc(challenge: string) -> bool {
	if len(challenge) != 43 do return false
	for c in challenge do if !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_') do return false
	return true
}
authorize :: proc(s: ^Store, user, client, redirect, challenge: string, now: i64) -> (string, bool) {
	if user == "" || !challenge_ok(challenge) do return "", false
	sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
	c, ok := s.clients[client]
	if !ok || c.redirect != redirect do return "", false
	sweep(s, now)
	if len(s.codes) >= LIMIT do return "", false
	code, made := auth.random_token(768)
	if !made do return "", false
	s.codes[strings.clone(auth.sha256_hex(code), runtime.heap_allocator())] = clone_credential({user, client, redirect, challenge, now + CODE_TTL})
	return code, true
}
// Caller holds mutex. Large opaque credentials exercise the transport's size
// handling; random padding is NOT a vault capability or a sealed-key protocol.
issue :: proc(s: ^Store, c: Credential, now: i64) -> (Tokens, bool) {
	if len(s.access) >= LIMIT || len(s.refresh) >= LIMIT do return {}, false
	at, aok := auth.random_token(768)
	rt, rok := auth.random_token(768)
	if !aok || !rok do return {}, false
	a := runtime.heap_allocator()
	entry := c; entry.expires = now + ACCESS_TTL
	s.access[strings.clone(auth.sha256_hex(at), a)] = clone_credential(entry)
	entry.expires = now + REFRESH_TTL
	s.refresh[strings.clone(auth.sha256_hex(rt), a)] = clone_credential(entry)
	return {at, rt, "Bearer", int(ACCESS_TTL / 1000), SCOPE}, true
}
exchange :: proc(s: ^Store, code, client, redirect, verifier: string, now: i64) -> (Tokens, bool) {
	if len(code) > 2048 || len(verifier) < 43 || len(verifier) > 128 do return {}, false
	sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
	sweep(s, now)
	hash := auth.sha256_hex(code)
	c, ok := s.codes[hash]
	if !ok || c.client != client || c.redirect != redirect || c.challenge != auth.pkce_challenge_s256(verifier) do return {}, false
	tokens, made := issue(s, c, now)
	if made do remove(&s.codes, hash)
	return tokens, made
}
refresh :: proc(s: ^Store, raw, client: string, now: i64) -> (Tokens, bool) {
	if len(raw) > 2048 do return {}, false
	sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
	sweep(s, now)
	hash := auth.sha256_hex(raw)
	c, ok := s.refresh[hash]
	if !ok || c.client != client do return {}, false
	tokens, made := issue(s, c, now)
	if made do remove(&s.refresh, hash)
	return tokens, made
}
validate :: proc(s: ^Store, raw: string, now: i64) -> bool {
	if raw == "" || len(raw) > 2048 do return false
	sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
	c, ok := s.access[auth.sha256_hex(raw)]
	return ok && c.expires > now
}
