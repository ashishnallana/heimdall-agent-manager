// In-memory device-authorization grant store (ELDA-1).
//
// Holds pending/approved/denied device grants keyed by device_code, plus the
// per-source-IP authorize rate limiter. All mutations are serialized under a
// single mutex so concurrent device/authorize and token-poll threads see a
// consistent snapshot.
//
// Lifecycle:
//   pending  -> approved | denied   (set by the browser verify handler, task 2)
//   approved -> token minted        (token poll hands out minted_token, task 3)
//
// A background GC sweeper evicts grants whose requested_at + expires_in has
// passed, so the map cannot grow unbounded from abandoned flows. The store is
// purely in-memory (no DB) by design: device grants are short-lived ephemeral
// state, and task 3 persists the resulting user/bridge tokens elsewhere.

package device_auth

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:time"

// The grant store outlives the requests that populate it, so it owns every string
// it retains on the persistent heap — never on a caller's per-request arena.
// Ownership rule: the `grants` map owns each Grant's string fields; the
// `by_user_code` index only aliases them (its key/value point into the owning
// grant), so it is never freed independently.
grant_clone_strings :: proc(g: Grant, heap: runtime.Allocator) -> Grant {
	c := g
	c.device_code = strings.clone(g.device_code, heap)
	c.user_code = strings.clone(g.user_code, heap)
	c.verification_uri = strings.clone(g.verification_uri, heap)
	c.owner_user_id = strings.clone(g.owner_user_id, heap)
	c.approver_username = strings.clone(g.approver_username, heap)
	c.device_label = strings.clone(g.device_label, heap)
	c.os = strings.clone(g.os, heap)
	c.app_version = strings.clone(g.app_version, heap)
	c.client = strings.clone(g.client, heap)
	c.request_ip = strings.clone(g.request_ip, heap)
	c.minted_token = strings.clone(g.minted_token, heap)
	c.minted_token_id = strings.clone(g.minted_token_id, heap)
	c.approver_ip = strings.clone(g.approver_ip, heap)
	c.approver_ua = strings.clone(g.approver_ua, heap)
	// REQ-IMPL-2 bridge-enrollment fields. These arrive on the per-request arena
	// like every other request-derived field, so they are cloned here too; a
	// field added to Grant and missed in this proc is a use-after-arena that only
	// shows up once the request that created the grant has returned.
	c.bridge_public_key = strings.clone(g.bridge_public_key, heap)
	c.bridge_key_fingerprint = strings.clone(g.bridge_key_fingerprint, heap)
	c.os_user = strings.clone(g.os_user, heap)
	c.code_challenge = strings.clone(g.code_challenge, heap)
	c.code_challenge_method = strings.clone(g.code_challenge_method, heap)
	c.minted_bridge_id = strings.clone(g.minted_bridge_id, heap)
	c.minted_refresh_token = strings.clone(g.minted_refresh_token, heap)
	c.bridge_identity_public_key = strings.clone(g.bridge_identity_public_key, heap)
	c.bridge_identity_fingerprint = strings.clone(g.bridge_identity_fingerprint, heap)
	c.pair_key_mac = strings.clone(g.pair_key_mac, heap)
	c.pair_salt = strings.clone(g.pair_salt, heap)
	c.pair_hub_origin = strings.clone(g.pair_hub_origin, heap)
	c.previous_bridge_id = strings.clone(g.previous_bridge_id, heap)
	return c
}

grant_free_strings :: proc(g: Grant, heap: runtime.Allocator) {
	delete(g.device_code, heap)
	delete(g.user_code, heap)
	delete(g.verification_uri, heap)
	delete(g.owner_user_id, heap)
	delete(g.approver_username, heap)
	delete(g.device_label, heap)
	delete(g.os, heap)
	delete(g.app_version, heap)
	delete(g.client, heap)
	delete(g.request_ip, heap)
	delete(g.minted_token, heap)
	delete(g.minted_token_id, heap)
	delete(g.approver_ip, heap)
	delete(g.approver_ua, heap)
	delete(g.bridge_public_key, heap)
	delete(g.bridge_key_fingerprint, heap)
	delete(g.os_user, heap)
	delete(g.code_challenge, heap)
	delete(g.code_challenge_method, heap)
	delete(g.minted_bridge_id, heap)
	delete(g.minted_refresh_token, heap)
	delete(g.bridge_identity_public_key, heap)
	delete(g.bridge_identity_fingerprint, heap)
	delete(g.pair_key_mac, heap)
	delete(g.pair_salt, heap)
	delete(g.pair_hub_origin, heap)
	delete(g.previous_bridge_id, heap)
}

// Grant_Kind is WHAT a grant will mint when it is approved, decided ONCE at
// /device/authorize and then persisted (REQ-IMPL-2).
//
// It exists instead of re-testing `bridge_public_key != ""` at each decision
// point. The two kinds mint different identities — a user API token versus a
// per-machine bridge credential — so an emptiness test that went wrong in one
// branch would silently mint the WRONG KIND of credential, which is a privilege
// confusion rather than a cosmetic bug. The same bug class is already on this
// chain's register as F4 ("empty token => loopback authorizes all",
// the loopback callback guard in src/bridge/main.odin). An enum makes the illegal state unrepresentable
// and every dispatch exhaustive.
//
// `Unsupported` is the zero value deliberately: a grant that somehow skipped
// derivation can never be approved into anything. (It replaced the user-token
// grant: Hub user tokens were removed, users sign in with OIDC.)
Grant_Kind :: enum {
	Unsupported,       // never created: authorize refuses requests without a bridge key
	Bridge_Enrollment, // REQ-IMPL-2: mints a bridge-scoped credential (brg_)
}

// Grant_Status models the device-authorization grant lifecycle.
Grant_Status :: enum {
	Pending,
	Approved,
	Denied,
	Expired,
	Used, // token handed out on first successful poll (single-use, ELDA-3)
}

// Grant is one device-authorization flow. Fields populated over time:
//   - requested_at (creation), approver_* / decided_at (task 2 verify),
//     minted_token (task 3 token mint). owner_user_id is empty until the user
//     approves in the browser (task 2).
Grant :: struct {
	device_code:    string,
	user_code:      string,
	verification_uri: string,
	owner_user_id:  string,
	approver_username: string,
	device_label:   string,
	os:             string,
	app_version:    string,
	client:         string,
	request_ip:     string,
	requested_at:   i64,   // unix seconds
	expires_at:     i64,   // unix seconds
	status:         Grant_Status,
	minted_token:   string,
	minted_token_id: string,
	approver_ip:    string,
	approver_ua:    string,
	decided_at:     i64,
	last_poll_at:   i64, // unix seconds of the last /device/token poll (slow_down gating)
	// --- REQ-IMPL-2: bridge-enrollment fields -------------------------------
	// grant_kind is derived once at authorize and is the ONLY thing later
	// branches dispatch on (see Grant_Kind).
	grant_kind:             Grant_Kind,
	// Populated only for a bridge grant (see is_bridge_grant, bridge_grant.odin).
	// bridge_public_key is HOST-ASSERTED (the bridge submits it at authorize) and
	// is what the minted credential is bound to; bridge_key_fingerprint is
	// HUB-COMPUTED from that key and is never taken from the request body. The
	// separation matters because the approval page displays the two differently
	// (design §5.4.4, REQ-ENROLL-14).
	bridge_public_key:      string,
	bridge_key_fingerprint: string,
	os_user:                string, // host-asserted OS user the bridge runs as
	code_challenge:         string, // PKCE S256 challenge (RFC 7636 §4.2)
	code_challenge_method:  string, // always "S256" when a challenge is present
	minted_bridge_id:       string, // brg_ minted on approval of a bridge grant
	// --- REQ-IMPL-3: the refresh half of the credential pair -----------------
	// Held from approval until the single-use poll hands it over, exactly like
	// minted_token, and cleared at the same moment. The two lifetimes are carried
	// alongside because they come from the CREDENTIAL (1h / 30d), not from the
	// grant's own 900-second window, and a bridge that scheduled its refresh off
	// the grant's expires_in would renew 96 times a day.
	minted_refresh_token:       string,
	minted_expires_in:          int,
	minted_refresh_expires_in:  int,
	vault_delivery_expected:    bool,
	// Passwordless vault (plan §1 "Bridge identity", §2 P2): the bridge's persistent
	// ECDSA identity key (host-asserted, REQUIRED for a bridge grant) and its
	// hub-computed fingerprint. The approving device signs a vault `approve`
	// statement naming exactly this key.
	bridge_identity_public_key:  string,
	bridge_identity_fingerprint: string,
	// Hub-blind pairing (plan §1 "Pairing"): for a bridge grant `user_code` holds the
	// pair_lookup the bridge derived from its secret code (the hub never sees the
	// code), and pair_key_mac is the bridge's MAC over its keys that the approver checks.
	// pair_salt is the bridge's public per-request salt of the pairing stretch; the
	// approver fetches it (pending_bridge_pair_salts) before it can derive the lookup,
	// with pair_hub_origin: the canonical hub origin the bridge declares it bound into
	// the stretch (the approver derives with it, not with its own page origin).
	pair_key_mac:                string,
	pair_salt:                   string,
	pair_hub_origin:             string,
	// REQ-BE-2: the bridge id the machine says it was enrolled as before. An
	// UNTRUSTED, host-asserted hint: it authorizes nothing. It is shown to the
	// approver only after verify_handler re-checks that the approver owns that bridge
	// and that it is live, and an attach still goes through the approver's explicit
	// target_bridge_id choice (re-checked again by the bridge service).
	previous_bridge_id:          string,
}

// Authorize_Input is the public /device/authorize request body (ELDA-1).
Authorize_Input :: struct {
	client:     string,
	device_label: string,
	os:         string,
	app_version: string,
	// REQ-IMPL-2. A request carrying bridge_public_key is a bridge enrollment and
	// must also carry PKCE; see authorize() for the validation and
	// bridge_grant.odin for why the fingerprint is NOT read from the body here.
	bridge_public_key:      string,
	bridge_key_fingerprint: string, // client's own copy; cross-checked, never trusted
	os_user:                string,
	code_challenge:         string,
	code_challenge_method:  string,
	bridge_identity_public_key: string,
	// Signature object (canonical JSON text) by the identity key over
	// vault.bridge_enroll_proof_canonical(bridge_public_key, code_challenge).
	bridge_identity_proof:      string,
	// Bridge grants: the hub-blind pairing values (REQUIRED). pair_lookup indexes the
	// grant instead of a hub-generated user code.
	pair_lookup:                string,
	pair_key_mac:               string,
	pair_salt:                  string,
	pair_hub_origin:            string,
	// Bridge grants only, optional: an untrusted hint (see Grant.previous_bridge_id).
	previous_bridge_id:         string,
}

// Authorize_Result is what /device/authorize hands back to the device (ELDA-1).
Authorize_Result :: struct {
	device_code:    string,
	user_code:      string,
	verification_uri: string,
	interval:       int,
	expires_in:     int,
	// bridge_key_fingerprint is the Hub's computed fingerprint, echoed back so
	// the bridge can print it (design §2.2 step 5). It is ADVISORY on the wire —
	// the bridge computes its own copy from its own key and the human compares
	// the two displays; the Hub's echo is never the bridge's source of truth.
	bridge_key_fingerprint: string,
}

// Monotonic_Clock provides unix-second timestamps so expiry/rate-limit math is
// deterministic in tests. The real implementation reads wall-clock time.
Monotonic_Clock :: struct {
	now:    proc() -> i64,
}

real_monotonic_clock :: proc() -> Monotonic_Clock {
	return Monotonic_Clock{now = real_unix_seconds}
}

real_unix_seconds :: proc() -> i64 {
	return time.to_unix_seconds(time.now())
}

// Rate_Limit_Entry tracks per-IP authorize counts inside the rolling window.
Rate_Limit_Entry :: struct {
	window_start: i64,
	count:        int,
}

// Grant_Store is the thread-safe in-memory grant store + rate limiter.
// `config` is treated as read-only after construction.
Grant_Store :: struct {
	config:   Grant_Store_Config,
	mutex:    sync.Mutex,
	grants:   map[string]Grant,        // keyed by device_code
	by_user_code: map[string]string,   // user_code -> device_code (for browser verify lookup, task 2)
	rate:     map[string]Rate_Limit_Entry, // keyed by source IP
	// epoch identifies this store's lifetime (the hub process): grants live only in
	// memory, so a device that sees the epoch change while polling knows its
	// device_code is gone and asks for a new one (audit F7/REQ-ENR-12). Not secret and
	// the same for every grant, so it reveals nothing about any device_code.
	epoch:    i64,
}

// Grant_Store_Config tunes TTL, polling interval, rate limit, and the
// verification_uri base the device should open in a browser.
Grant_Store_Config :: struct {
	verification_uri: string,   // browser/outpost device URL (NOT the API URL)
	expires_in:       int,      // grant lifetime in seconds (<=600, ELDA-1)
	interval:         int,      // polling interval the device should use (seconds)
	rate_limit:       int,      // max authorize calls per IP per window
	rate_window:      int,      // rate-limit window in seconds
}

default_grant_store_config :: proc() -> Grant_Store_Config {
	return Grant_Store_Config{
		verification_uri = "https://auth.example.com/application/o/heimdall/device/",
		expires_in = 300,
		interval = 5,
		rate_limit = 10,
		rate_window = 60,
	}
}

new_grant_store :: proc(config: Grant_Store_Config) -> Grant_Store {
	return Grant_Store{
		config = config,
		grants = make(map[string]Grant),
		by_user_code = make(map[string]string),
		rate = make(map[string]Rate_Limit_Entry),
		epoch = time.to_unix_nanoseconds(time.now()),
	}
}

grant_store_free :: proc(store: ^Grant_Store) {
	heap := runtime.heap_allocator()
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)
	// Free each grant's owned strings (by_user_code only aliases them) and each
	// heap-owned rate-limit key, then drop the maps themselves. Iterating without
	// delete_key is safe; the maps are deleted wholesale afterwards.
	for _, grant in store.grants do grant_free_strings(grant, heap)
	for ip in store.rate do delete(ip, heap)
	delete(store.grants)
	delete(store.by_user_code)
	delete(store.rate)
}

// allow_authorize enforces the per-source-IP authorize rate limit BEFORE any
// grant is created (store-filling DoS protection, ELDA-1). Returns true if the
// caller is under the limit (and increments the counter); false otherwise.
// MUST be called under the store mutex.
allow_authorize :: proc(store: ^Grant_Store, ip: string, now: i64) -> bool {
	if ip == "" do return true // cannot attribute; allow (handler still validates input)
	if store.config.rate_limit <= 0 do return true // limit disabled
	entry, has := store.rate[ip]
	window := i64(store.config.rate_window)
	if window <= 0 do window = 60
	if !has || now - entry.window_start >= window {
		// Map string keys keep the string header/data; clone request-derived IPs so
		// rate-limit entries never point at temporary request buffers.
		store.rate[strings.clone(ip, runtime.heap_allocator())] = Rate_Limit_Entry{window_start = now, count = 1}
		return true
	}
	if entry.count >= store.config.rate_limit do return false
	entry.count += 1
	store.rate[ip] = entry
	return true
}

// create_grant mints a new device grant. Caller MUST have already passed the
// rate-limit check (allow_authorize) and validated input. Generates fresh,
// unlinkable device_code + user_code (AC2). Returns ("", false) only if the OS
// CSPRNG is unavailable (caller fails closed with 503).
// create_grant mints the grant. `bridge_key_fingerprint` is the HUB-COMPUTED
// fingerprint (authorize() derives it from input.bridge_public_key before
// calling); it is passed in rather than recomputed here so there is exactly one
// place in the codebase that decides what a fingerprint is.
create_grant :: proc(store: ^Grant_Store, input: Authorize_Input, request_ip: string, clock: Monotonic_Clock, bridge_key_fingerprint: string = "", grant_kind: Grant_Kind = .Unsupported) -> (Authorize_Result, bool) {
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)
	device_code := ""
	user_code := ""
	// The short code is a lookup key, so even its extremely unlikely collision
	// must be retried rather than replacing another live enrollment's mapping.
	for _ in 0..<8 {
		candidate_device, device_ok := generate_device_code()
		if !device_ok do return Authorize_Result{}, false
		// A bridge grant is indexed by the pair_lookup the bridge derived from its own
		// code; the hub never generates (or sees) that code. A taken lookup refuses.
		candidate_user: string
		if input.pair_lookup != "" {
			if _, taken := store.by_user_code[input.pair_lookup]; taken {
				delete(candidate_device)
				return Authorize_Result{}, false
			}
			candidate_user = strings.clone(input.pair_lookup)
		} else {
			user, user_ok := generate_user_code()
			if !user_ok do return Authorize_Result{}, false
			candidate_user = user
		}
		_, device_exists := store.grants[candidate_device]
		_, user_exists := store.by_user_code[candidate_user]
		if !device_exists && !user_exists {
			device_code = candidate_device
			user_code = candidate_user
			break
		}
		delete(candidate_device)
		delete(candidate_user)
	}
	if device_code == "" || user_code == "" do return Authorize_Result{}, false
	now := clock.now()
	expires_in := store.config.expires_in
	if expires_in <= 0 || expires_in > 600 do expires_in = 600 // ELDA-1 hard cap
	grant := Grant{
		device_code = device_code,
		user_code = user_code,
		verification_uri = store.config.verification_uri,
		device_label = input.device_label,
		os = input.os,
		app_version = input.app_version,
		client = input.client,
		request_ip = request_ip,
		requested_at = now,
		expires_at = now + i64(expires_in),
		status = .Pending,
		grant_kind = grant_kind,
		bridge_public_key = input.bridge_public_key,
		bridge_key_fingerprint = bridge_key_fingerprint,
		os_user = input.os_user,
		code_challenge = input.code_challenge,
		code_challenge_method = input.code_challenge_method,
		bridge_identity_public_key = input.bridge_identity_public_key,
		pair_key_mac = input.pair_key_mac,
		pair_salt = input.pair_salt,
		pair_hub_origin = input.pair_hub_origin,
		previous_bridge_id = input.previous_bridge_id,
	}
	if input.bridge_identity_public_key != "" {
		// Validated by validate_bridge_authorize_input before we get here.
		grant.bridge_identity_fingerprint, _ = bridge_key_fingerprint_for(input.bridge_identity_public_key, context.temp_allocator)
	}
	heap := runtime.heap_allocator()
	// Persist heap-owned copies: `grant`'s request-derived fields (device_label,
	// os, app_version, client, request_ip) live on the per-request arena.
	stored := grant_clone_strings(grant, heap)
	store.grants[stored.device_code] = stored
	store.by_user_code[stored.user_code] = stored.device_code
	return Authorize_Result{
		device_code = device_code,
		// A pair_lookup is never echoed back as if it were a code to show.
		user_code = user_code if input.pair_lookup == "" else "",
		verification_uri = store.config.verification_uri,
		interval = store.config.interval,
		expires_in = expires_in,
		bridge_key_fingerprint = bridge_key_fingerprint,
	}, true
}

// get_grant returns the live grant for a device_code (or false if absent). The
// returned grant is a snapshot copy; mutations go through the mutator procs.
get_grant :: proc(store: ^Grant_Store, device_code: string) -> (Grant, bool) {
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)
	grant, ok := store.grants[device_code]
	return grant, ok
}

// set_grant replaces the grant for a device_code under the mutex (used by
// approve to write the terminal decision + audit fields atomically).
set_grant :: proc(store: ^Grant_Store, device_code: string, grant: Grant) {
	heap := runtime.heap_allocator()
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)
	// Clone onto the heap so the entry never points at the caller's per-request
	// arena. The previous entry's strings are intentionally NOT freed here: the
	// store hands out borrowed snapshots (get_grant / grant_by_user_code return a
	// value copy whose string fields alias the stored heap strings), and a caller
	// may still be using one — e.g. approve passes grant.client to the token minter
	// in the same call that then set_grants. So grant strings are treated as
	// immortal (exactly as the original store did) and reclaimed only at
	// grant_store_free; the residual is bounded by the grant's short TTL. Overwrite
	// reuses the existing map keys (Odin keeps the key on assignment to an existing
	// entry), so no key churn.
	//
	// REVISITED DELIBERATELY FOR REQ-IMPL-3 (refresh-token rotation), and the
	// immortal-string design is KEPT. Writing the reasoning down because the question
	// was raised on the premise that rotation would make this a hot path:
	//
	//   IT DOES NOT. The rotation lineage lives in SQLITE (the `bridge_tokens`
	//   table), not in this in-memory store, and `refresh_bridge_token` never calls
	//   set_grant. The grant store is touched only during the 900-second enrollment
	//   window, exactly as before.
	//
	//   THE NEW BOUND, STATED EXACTLY. Per grant, set_grant runs at most once per
	//   accepted poll plus once at the approval decision; polls are gated by the
	//   per-grant interval and the per-IP `poll:` bucket, and the grant is reaped at
	//   its TTL. So the residual per grant is
	//       (polls admitted inside 900s) x sizeof(cloned grant strings) + 1 approval,
	//   which REQ-IMPL-3 increases by exactly ONE additional cloned string per
	//   approved enrollment (`minted_refresh_token`, cleared on the handover poll).
	//   Everything is reclaimed at grant_store_free.
	//
	//   WHY NOT RECLAIM ANYWAY. The ownership story that makes reclamation unsafe is
	//   unchanged: get_grant returns a value copy whose strings ALIAS the stored
	//   heap strings, and approve is a live example of a caller holding such a
	//   snapshot across a set_grant. Freeing the overwritten strings would turn
	//   every borrowed snapshot into a use-after-free, so reclamation needs an
	//   ownership change (returned grants owning their strings, or refcounting) —
	//   a bigger change than it looks, on the enrollment path, for a residual that
	//   is bounded by a 900-second TTL. That is a poor trade; if the grant TTL ever
	//   becomes long, or set_grant is ever called off the poll path, revisit it
	//   with that change rather than by adding a free here.
	// BUG FIX (REQ-IMPL-2, found end-to-end on the live stack): index the
	// user_code to the HEAP-OWNED clone's device_code, never to the caller's
	// `device_code` parameter.
	//
	// The old line was `store.by_user_code[grant.user_code] = device_code`, and
	// `device_code` reaches set_grant straight from the handler — in the poll path
	// it is `json_string(req.body, "device_code")`, which lives on the PER-REQUEST
	// ARENA. Storing it in a process-lifetime index left that index pointing at
	// memory the next request reuses, so `grant_by_user_code` then looked up
	// garbage and `/device/verify` answered "invalid or expired code" for a grant
	// that was alive and well.
	//
	// The user-visible failure was deterministic, not a rare race: ONE
	// `/device/token` poll on a pending grant permanently broke
	// `/device/verify` for that user_code, while the device_code kept working.
	// That is the normal shape of this flow — RFC 8628 has the device polling
	// while the human is still reading the approval page — so it bit the
	// pre-existing Electron flow too, not just bridge enrollment.
	//
	// The ownership rule at the top of this file already said the index only
	// ALIASES strings the `grants` map owns; this line was the one place that
	// broke it. Keying by `stored.device_code` likewise avoids leaving an arena
	// string as a map key if set_grant is ever called for an absent code (Odin
	// keeps the existing key when assigning to an existing entry, so for the
	// normal overwrite path this changes nothing).
	stored := grant_clone_strings(grant, heap)
	store.grants[stored.device_code] = stored
	store.by_user_code[stored.user_code] = stored.device_code
}

// grant_by_user_code looks up a grant by its short user_code (for the browser
// verify flow, task 2). Returns the device_code + grant snapshot.
grant_by_user_code :: proc(store: ^Grant_Store, user_code: string) -> (string, Grant, bool) {
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)
	device_code, ok := store.by_user_code[user_code]
	if !ok do return "", Grant{}, false
	grant, gok := store.grants[device_code]
	if !gok do return "", Grant{}, false
	return device_code, grant, true
}

// is_expired reports whether a grant's TTL has elapsed at `now`.
is_expired :: proc(grant: Grant, now: i64) -> bool {
	return now >= grant.expires_at
}

// sweep evicts expired grants (status -> .Expired, then removed). Called by the
// GC loop and safe to call from tests with a controlled clock.
sweep :: proc(store: ^Grant_Store, now: i64) -> int {
	heap := runtime.heap_allocator()
	sync.mutex_lock(&store.mutex)
	defer sync.mutex_unlock(&store.mutex)
	removed := 0
	// Collect expired codes first — deleting during a map range is unsafe.
	expired: [dynamic]string
	expired.allocator = context.temp_allocator
	defer delete(expired)
	for code, grant in store.grants {
		if now >= grant.expires_at do append(&expired, code)
	}
	for code in expired {
		if grant, ok := store.grants[code]; ok {
			delete_key(&store.grants, code)
			delete_key(&store.by_user_code, grant.user_code)
			// Grant strings are NOT freed here: they may be aliased by a borrowed
			// snapshot a concurrent request is still using (get_grant releases the
			// mutex before the caller reads the snapshot). They are heap-owned and
			// reclaimed at grant_store_free; the residual is TTL-bounded.
			removed += 1
		}
	}
	// Evict stale rate-limit entries; the per-IP rate map previously grew
	// monotonically with unique source IPs. An entry whose window has fully elapsed
	// is safe to drop (the next request re-seeds it via allow_authorize/verify/poll).
	window := i64(store.config.rate_window)
	if window <= 0 do window = 60
	stale: [dynamic]string
	stale.allocator = context.temp_allocator
	defer delete(stale)
	for ip, entry in store.rate {
		if now - entry.window_start >= window do append(&stale, ip)
	}
	for ip in stale {
		delete_key(&store.rate, ip)
		delete(ip, heap)
	}
	return removed
}

// gc_loop runs sweep on a fixed cadence forever; intended to be launched in
// its own thread by the app wiring (process-scoped, like server.serve). The
// cadence is min(expires_in, 120s)/2 so grants are reaped within ~half a TTL.
gc_loop :: proc(store: ^Grant_Store) {
	cadence := store.config.expires_in
	if cadence <= 0 || cadence > 120 do cadence = 60
	cadence = max(cadence / 2, 5)
	for {
		time.sleep(time.Duration(cadence) * time.Second)
		sweep(store, real_unix_seconds())
	}
}
