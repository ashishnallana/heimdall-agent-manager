// Vault device directory service (docs/plans/passwordless-vault.md §2 P2).
//
// The hub is hostile for confidentiality, but it still enforces authorization and
// compare-and-set as defense in depth:
//   - every statement and wrap signature is re-verified here with lib/vault;
//   - every mutation except register/genesis carries a device request signature
//     from an approved approver-capable device of the session user (kind_policy);
//   - every mutation is a versioned CAS (409 with the current version on a stale one).
// Clients verify everything again; nothing here is trusted by them.
package vault_directory

import "base:runtime"
import "core:crypto"
import "core:crypto/sha2"
import "core:strconv"
import "core:strings"
import "core:sync"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import vault "odin_test:lib/vault"
import os_random "odin_test:lib/os_random"

REQUEST_HEADER       :: "heimdall-device-request/v1"
REQUEST_SKEW_MS      :: 60_000
// A nonce stays recorded until its timestamp can no longer pass the skew check:
// ts may be up to 60 s ahead of the hub clock, and stays acceptable for 60 s after.
NONCE_TTL_MS         :: 2 * REQUEST_SKEW_MS + 5_000
// Per-device budget of live nonces. Nonces are recorded only for MUTATIONS, which
// only approved approver-capable devices may sign, so the budget is per signing
// device and one device (or one account) can never exhaust anyone else's.
NONCE_DEVICE_QUOTA   :: 64

Service :: struct {
	repo:  ^iface.Vault_Directory_Repository,
	clock: ^platform.Clock,
	nonces: Nonce_Cache,
	// random_source is the CSPRNG path for pending codes (tests point it at a missing
	// path to prove the fail-closed contract).
	random_source: string,
	// reset_delay_seconds is how long an owner reset waits before it executes
	// (RESET_DELAY_SECONDS). Tests drive the delay with the injected clock.
	reset_delay_seconds: int,
}

new_service :: proc(repo: ^iface.Vault_Directory_Repository, clock: ^platform.Clock) -> Service {
	return Service{repo = repo, clock = clock, nonces = nonce_cache_make(NONCE_DEVICE_QUOTA), random_source = os_random.DEFAULT_SOURCE, reset_delay_seconds = RESET_DELAY_SECONDS}
}

service_free :: proc(svc: ^Service) {
	nonce_cache_free(&svc.nonces)
}

// ── Nonce replay cache ──────────────────────────────────────────────────────
// Expiry-based and PARTITIONED: one bucket per (user, device), each with its own
// quota. A nonce is recorded only after its request authenticated, so garbage cannot
// fill a bucket; when a device's bucket holds `quota` live nonces that device's next
// mutation is REFUSED rather than evicting one (an evicted nonce could be replayed
// inside its window). Other devices and other accounts are unaffected.
//
// Reads (GET /vault/devices/self, GET /vault/directory) are NOT recorded: they need a
// fresh, valid signature but change nothing, so a replayed read only re-reads.
//
// RESTART: the cache is in memory only. A hub restart forgets the nonces of the last
// ~2 minutes, so a captured mutation could be replayed once inside its remaining
// ±60 s window after a restart. That replay still has to pass the directory CAS:
// every mutation's statements are bound to `directory_version`, which the original
// request already advanced, so it fails with 409. Deny/reset-cancel carry no
// version; replaying them re-applies the same idempotent outcome.

Nonce_Cache :: struct {
	mutex:   sync.Mutex,
	buckets: map[string]map[string]i64, // "user|device" -> nonce -> expires_ms
	quota:   int,
}

Nonce_Result :: enum {
	Inserted,
	Replay,
	Full,
}

nonce_cache_make :: proc(quota: int) -> Nonce_Cache {
	return Nonce_Cache{buckets = make(map[string]map[string]i64, 16, runtime.heap_allocator()), quota = quota}
}

@(private)
nonce_bucket_free :: proc(b: ^map[string]i64) {
	for k in b^ do delete(k, runtime.heap_allocator())
	delete(b^)
}

nonce_cache_free :: proc(c: ^Nonce_Cache) {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	for k, &b in c.buckets {
		nonce_bucket_free(&b)
		delete(k, runtime.heap_allocator())
	}
	delete(c.buckets)
}

// nonce_cache_insert records `nonce` in the bucket `bucket_key`. Expired nonces of
// that bucket are purged first; an emptied bucket is dropped, so memory follows the
// number of devices that signed a mutation in the last NONCE_TTL_MS.
nonce_cache_insert :: proc(c: ^Nonce_Cache, bucket_key, nonce: string, now_ms, ttl_ms: i64) -> Nonce_Result {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	heap := runtime.heap_allocator()
	b, has_bucket := &c.buckets[bucket_key]
	if !has_bucket {
		c.buckets[strings.clone(bucket_key, heap)] = make(map[string]i64, 8, heap)
		b = &c.buckets[bucket_key]
	}
	if exp, has := b[nonce]; has && now_ms <= exp do return .Replay
	expired := make([dynamic]string, context.temp_allocator)
	for k, exp in b do if now_ms > exp do append(&expired, k)
	for k in expired {
		key_ptr, _ := delete_key(b, k)
		delete(key_ptr, heap)
	}
	if len(b) >= c.quota do return .Full
	b[strings.clone(nonce, heap)] = now_ms + ttl_ms
	return .Inserted
}

// nonce_cache_sweep drops every expired nonce and every emptied bucket.
nonce_cache_sweep :: proc(c: ^Nonce_Cache, now_ms: i64) {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	heap := runtime.heap_allocator()
	empty := make([dynamic]string, context.temp_allocator)
	for bk, &b in c.buckets {
		expired := make([dynamic]string, context.temp_allocator)
		for k, exp in b do if now_ms > exp do append(&expired, k)
		for k in expired {
			key_ptr, _ := delete_key(&b, k)
			delete(key_ptr, heap)
		}
		if len(b) == 0 do append(&empty, bk)
	}
	for bk in empty {
		key_ptr, b := delete_key(&c.buckets, bk)
		bb := b
		nonce_bucket_free(&bb)
		delete(key_ptr, heap)
	}
}

// ── Helpers ─────────────────────────────────────────────────────────────────

@(private)
now_ms :: proc(svc: ^Service) -> (i64, bool) {
	return platform.rfc3339_to_unix_ms(platform.clock_now(svc.clock))
}

@(private)
unauth :: proc(msg: string) -> domain.Domain_Error {
	return domain.domain_error(.Unauthenticated, msg)
}

@(private)
forbidden :: proc(msg: string) -> domain.Domain_Error {
	return domain.domain_error(.Forbidden, msg)
}

@(private)
invalid :: proc(msg: string) -> domain.Domain_Error {
	return domain.domain_error(.Validation_Failed, msg)
}

not_configured_error :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Not_Found, "vault directory is not configured", `{"configured":false}`)
}

GENERIC_CODE_ERROR :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Not_Found, "invalid or expired code")
}

@(private)
i64_str :: proc(v: i64) -> string {
	buf: [24]byte
	return strings.clone(strconv.write_int(buf[:], v, 10), context.temp_allocator)
}

@(private)
find_device :: proc(devices: []domain.Vault_Device, device_id: string) -> (domain.Vault_Device, bool) {
	for d in devices do if d.device_id == device_id do return d, true
	return {}, false
}

@(private)
is_hex64_or_empty :: proc(s: string) -> bool {
	return s == "" || (len(s) == vault.EPOCH_COMMIT_HEX_CHARS && vault.is_lower_hex(s))
}

// subject_matches checks a statement's subject_* fields against a stored device.
@(private)
subject_matches :: proc(st: ^vault.Statement, d: domain.Vault_Device) -> bool {
	return st.subject_device_id == d.device_id && st.subject_kind == d.kind &&
		st.subject_sign_pub == d.sign_public_key && st.subject_ecdh_pub == d.ecdh_public_key &&
		st.subject_sign_alg == d.sign_alg && st.subject_wrap_alg == d.wrap_alg
}

@(private)
subject_empty :: proc(st: ^vault.Statement) -> bool {
	return st.subject_device_id == "" && st.subject_kind == "" && st.subject_sign_pub == "" &&
		st.subject_ecdh_pub == "" && st.subject_sign_alg == "" && st.subject_wrap_alg == "" && st.subject_label_b64 == ""
}

// Log_Slot is where the next signed log op goes: seq = version + 1, linked to the
// current head (plan §1 "Directory log").
Log_Slot :: struct {
	seq:       string,
	prev_hash: string,
}

@(private)
next_slot :: proc(dir: domain.Vault_Directory) -> Log_Slot {
	return Log_Slot{seq = i64_str(dir.version + 1), prev_hash = dir.head_hash}
}

// parse_signed_statement parses the canonical text, checks type/user/log slot/issuer
// and verifies the signature under the issuer's key.
@(private)
parse_signed_statement :: proc(text, signature, type, user_id: string, slot: Log_Slot, issuer: domain.Vault_Device) -> (vault.Statement, domain.Domain_Error) {
	st, ok := vault.statement_parse(text)
	if !ok do return {}, invalid("statement is not canonical")
	if st.type != type do return {}, invalid(strings.concatenate({"statement type must be ", type}, context.temp_allocator))
	if st.user_id != user_id do return {}, forbidden("statement is for another account")
	if st.seq != slot.seq || st.prev_hash != slot.prev_hash do return {}, domain.vault_reason_error(.Conflict, "statement_version", "statement is not linked to the current directory log head")
	if st.issuer_device_id != issuer.device_id do return {}, forbidden("statement issuer is not the signing device")
	if !vault.valid_decimal(st.issued_at_ms) do return {}, invalid("issued_at_ms is required")
	if !vault.verify(issuer.sign_alg, issuer.sign_public_key, transmute([]byte)text, signature) do return {}, unauth("statement signature does not verify")
	return st, domain.Domain_Error{}
}

// current_epoch_commit is the epoch_commit of the directory's current epoch, taken
// from its stored (signed) epoch statement. An approval must name exactly this.
@(private)
current_epoch_commit :: proc(svc: ^Service, user_id: string, current_epoch: i64) -> (string, domain.Domain_Error) {
	epochs, err := iface.vault_list_epochs(svc.repo, user_id)
	if err.code != .None do return "", err
	for e in epochs {
		if e.epoch != current_epoch do continue
		st, ok := vault.statement_parse(e.statement)
		if !ok || len(st.epoch_commit) != vault.EPOCH_COMMIT_HEX_CHARS do break
		return st.epoch_commit, domain.Domain_Error{}
	}
	return "", domain.domain_error(.Internal_Error, "the current epoch statement is missing or malformed")
}

Wrap_Input :: struct {
	wrap:      vault.Keyring_Wrap,
	signature: string,
}

// check_wrap verifies one wrap: addressing, version/epoch binding, wrapper identity,
// algorithm agreement with the recipient, and the wrapper's signature over the wrap
// statement. Returns the stored row.
@(private)
check_wrap :: proc(svc: ^Service, in_wrap: Wrap_Input, user_id: string, recipient: domain.Vault_Device, version, epoch: i64, signer: domain.Vault_Device, now: string) -> (domain.Vault_Wrap_Row, domain.Domain_Error) {
	w := in_wrap.wrap
	if w.recipient_device_id != recipient.device_id do return {}, invalid("wrap is addressed to another device")
	if i64(w.directory_version) != version do return {}, invalid("wrap is bound to a different directory version")
	if i64(w.current_epoch) != epoch do return {}, invalid("wrap is for a different epoch")
	if w.wrapped_by_device_id != signer.device_id do return {}, forbidden("wrap was not made by the signing device")
	if w.alg != recipient.wrap_alg || vault.wrap_alg_from_id(w.alg) == .Unknown do return {}, invalid("wrap algorithm does not match the recipient")
	stmt, ok := vault.wrap_statement(&w, user_id, context.temp_allocator)
	if !ok do return {}, invalid("wrap is malformed")
	if !vault.verify(signer.sign_alg, signer.sign_public_key, transmute([]byte)stmt, in_wrap.signature) do return {}, unauth("wrap signature does not verify")
	json_text, j_ok := vault.wrap_signed_json(&w, in_wrap.signature)
	if !j_ok do return {}, invalid("wrap is malformed")
	return domain.Vault_Wrap_Row{user_id = user_id, device_id = recipient.device_id, directory_version = version, current_epoch = epoch, wrap_json = json_text, updated_at = now}, domain.Domain_Error{}
}

// ── Request signing ─────────────────────────────────────────────────────────

Signed_Request :: struct {
	method, path, body: string,
	device_id, ts, nonce, signature: string,
}

Signer_Requirement :: enum {
	// An approved device whose kind may approve (never a bridge). Every mutation.
	Approver,
	// The device itself in any status (pending, approved or revoked). READ-ONLY
	// endpoints only (GET self, GET directory): no nonce is recorded. Bridges are
	// never accepted.
	Self,
}

request_canonical :: proc(method, path, user_id, ts, nonce, body: string, allocator := context.allocator) -> string {
	digest: [32]byte
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]byte)body)
	sha2.final(&ctx, digest[:])
	return strings.concatenate({REQUEST_HEADER, "\n", method, "\n", path, "\n", user_id, "\n", ts, "\n", nonce, "\n", vault.hex_encode_lower(digest[:], context.temp_allocator)}, allocator)
}

has_signature_headers :: proc(r: Signed_Request) -> bool {
	return r.device_id != "" || r.ts != "" || r.nonce != "" || r.signature != ""
}

@(private)
valid_nonce :: proc(s: string) -> bool {
	if len(s) < 16 || len(s) > 64 do return false
	for i in 0 ..< len(s) {
		switch s[i] {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '_', '-':
		case: return false
		}
	}
	return true
}

// verify_request authenticates a device-signed request for `user_id` and returns
// the signing device. Order: shape, freshness, signer lookup + policy, signature,
// THEN — for a mutation (.Approver) only — the nonce is recorded in the signer's own
// bucket (an unauthenticated request never consumes a slot).
verify_request :: proc(svc: ^Service, user_id: string, r: Signed_Request, need: Signer_Requirement) -> (domain.Vault_Device, domain.Domain_Error) {
	if r.device_id == "" || r.ts == "" || r.nonce == "" || r.signature == "" do return {}, unauth("device request signature required")
	if !vault.valid_device_id(r.device_id) || !valid_nonce(r.nonce) do return {}, unauth("malformed device signature headers")
	ts, ts_ok := vault.decimal_u64(r.ts)
	now, now_ok := now_ms(svc)
	if !ts_ok || !now_ok do return {}, unauth("malformed device request timestamp")
	skew := i64(ts) - now
	if skew > REQUEST_SKEW_MS || skew < -REQUEST_SKEW_MS do return {}, unauth("device request timestamp outside the allowed window")
	devices, err := iface.vault_list_devices(svc.repo, user_id)
	if err.code != .None do return {}, err
	dev, found := find_device(devices, r.device_id)
	// Not this user's device (unknown, or another account's): same answer.
	if !found do return {}, forbidden("signing device is not in this account's directory")
	policy := domain.vault_kind_policy(dev.kind)
	switch need {
	case .Approver:
		if dev.status != .Approved do return {}, forbidden("signing device is not approved")
		if !policy.can_approve do return {}, forbidden("signing device kind may not approve")
	case .Self:
		if dev.kind == "bridge" || !domain.vault_kind_valid(dev.kind) do return {}, forbidden("signing device kind may not use this endpoint")
	}
	msg := request_canonical(r.method, r.path, user_id, r.ts, r.nonce, r.body, context.temp_allocator)
	if !vault.verify(dev.sign_alg, dev.sign_public_key, transmute([]byte)msg, r.signature) do return {}, unauth("device request signature does not verify")
	// Only mutations consume a nonce (see the cache comment): .Self is read-only.
	if need == .Self do return dev, domain.Domain_Error{}
	bucket := strings.concatenate({user_id, "|", dev.device_id}, context.temp_allocator)
	switch nonce_cache_insert(&svc.nonces, bucket, r.nonce, now, NONCE_TTL_MS) {
	case .Inserted:
	case .Replay:
		return {}, unauth("device request nonce was already used")
	case .Full:
		return {}, domain.domain_error(.Rate_Limited, "too many signed requests from this device; retry shortly")
	}
	return dev, domain.Domain_Error{}
}

// ── Reads ───────────────────────────────────────────────────────────────────

Directory_View :: struct {
	directory:       domain.Vault_Directory,
	devices:         []domain.Vault_Device,
	// The signed directory log, seq 1..version: what clients verify.
	log:             []domain.Vault_Log_Entry,
	root_sign_public_key: string,
	root_sign_alg:   string,
	// retired_hints: approved identities the hub retired without a signed revocation
	// (a bridge revoked from bridge settings, the old identity an attach replaced, a
	// rolled-back enrollment). A hint only: an approved browser that verifies the id is
	// a trusted bridge in the log signs a real revoke for it (new epoch + wraps). The
	// hub never changes the log or the version itself.
	retired_hints: []string,
}

@(private)
collect_retired_hints :: proc(view: ^Directory_View) {
	ids := make([dynamic]string, 0, 2, context.temp_allocator)
	for d in view.devices do if d.status == .Approved && d.retired_at != "" do append(&ids, d.device_id)
	view.retired_hints = ids[:]
}

get_directory :: proc(svc: ^Service, user_id: string) -> (Directory_View, domain.Domain_Error) {
	dir, found, err := iface.vault_get_directory(svc.repo, user_id)
	if err.code != .None do return {}, err
	if !found do return {}, not_configured_error()
	devices, derr := iface.vault_list_devices(svc.repo, user_id)
	if derr.code != .None do return {}, derr
	log, lerr := iface.vault_list_log(svc.repo, user_id)
	if lerr.code != .None do return {}, lerr
	// Expired pending devices are not listed (they can no longer be approved).
	now := platform.clock_now(svc.clock)
	listed := make([dynamic]domain.Vault_Device, 0, len(devices), context.temp_allocator)
	for d in devices {
		if d.status == .Pending && d.code_expires_at <= now do continue
		append(&listed, d)
	}
	view := Directory_View{directory = dir, devices = listed[:], log = log}
	// The root's key comes from the self-signed genesis statement (what a client
	// pins), not from the device row.
	if st, ok := vault.statement_parse(dir.genesis_statement); ok {
		view.root_sign_public_key = st.subject_sign_pub
		view.root_sign_alg = st.subject_sign_alg
	}
	collect_retired_hints(&view)
	return view, domain.Domain_Error{}
}

directory_exists :: proc(svc: ^Service, user_id: string) -> (bool, domain.Domain_Error) {
	_, found, err := iface.vault_get_directory(svc.repo, user_id)
	return found, err
}

touch_last_seen :: proc(svc: ^Service, user_id, device_id: string) {
	_ = iface.vault_touch_last_seen(svc.repo, user_id, device_id, platform.clock_now(svc.clock))
}

Self_View :: struct {
	device:            domain.Vault_Device,
	directory_version: i64,
	wrap:              domain.Vault_Wrap_Row,
	has_wrap:          bool,
}

get_self :: proc(svc: ^Service, user_id: string, signer: domain.Vault_Device) -> (Self_View, domain.Domain_Error) {
	view := Self_View{device = signer}
	dir, found, err := iface.vault_get_directory(svc.repo, user_id)
	if err.code != .None do return {}, err
	if found do view.directory_version = dir.version
	if signer.status == .Approved && domain.vault_kind_policy(signer.kind).receives_wrap {
		w, has, werr := iface.vault_get_wrap(svc.repo, user_id, signer.device_id)
		if werr.code != .None do return {}, werr
		view.wrap, view.has_wrap = w, has
	}
	touch_last_seen(svc, user_id, signer.device_id)
	return view, domain.Domain_Error{}
}

// resolve_pending_lookup finds a pending device of the SESSION USER by its pairing
// lookup (derived from the code on the new device; the hub never sees the code).
// Unknown, malformed, another account's and expired lookups all get the same answer.
resolve_pending_lookup :: proc(svc: ^Service, user_id, pair_lookup: string) -> (domain.Vault_Device, domain.Domain_Error) {
	if !vault.valid_pair_hex(pair_lookup) do return {}, GENERIC_CODE_ERROR()
	dev, found, err := iface.vault_find_pending_by_lookup(svc.repo, user_id, pair_lookup)
	if err.code != .None do return {}, err
	if !found || dev.code_expires_at <= platform.clock_now(svc.clock) do return {}, GENERIC_CODE_ERROR()
	return dev, domain.Domain_Error{}
}

// ── Genesis ─────────────────────────────────────────────────────────────────

Genesis_Input :: struct {
	user_id:           string,
	genesis_statement: string,
	genesis_signature: string,
	wrap:              Wrap_Input,
}

// subject_device_from_statement builds the self-described device a genesis or register
// statement introduces, validating keys, algorithms, kind and label.
@(private)
subject_device_from_statement :: proc(st: ^vault.Statement, user_id: string) -> (domain.Vault_Device, domain.Domain_Error) {
	if !domain.vault_kind_valid(st.subject_kind) do return {}, invalid("unknown device kind")
	if vault.sign_alg_from_id(st.subject_sign_alg) == .Unknown do return {}, invalid("unknown sign algorithm")
	if !vault.valid_p256_public_key(st.subject_sign_pub) do return {}, invalid("subject_sign_pub is not a valid P-256 key")
	policy := domain.vault_kind_policy(st.subject_kind)
	if policy.receives_wrap {
		if vault.wrap_alg_from_id(st.subject_wrap_alg) == .Unknown do return {}, invalid("unknown wrap algorithm")
		if !vault.valid_p256_public_key(st.subject_ecdh_pub) do return {}, invalid("subject_ecdh_pub is not a valid P-256 key")
	} else if st.subject_wrap_alg != "" || st.subject_ecdh_pub != "" {
		return {}, invalid("this device kind receives no wrap")
	}
	id, id_ok := vault.device_id_from_sign_pub(st.subject_sign_pub, context.temp_allocator)
	if !id_ok || st.subject_device_id != id do return {}, invalid("subject_device_id does not match subject_sign_pub")
	label, l_ok := vault.label_from_b64(st.subject_label_b64, context.temp_allocator)
	if !l_ok do return {}, invalid("subject_label_b64 is not a valid label")
	fp, fp_ok := vault.device_fingerprint(st.subject_sign_pub, st.subject_ecdh_pub, context.temp_allocator)
	if !fp_ok do return {}, invalid("could not fingerprint the device")
	return domain.Vault_Device{
		device_id = id, user_id = user_id, kind = st.subject_kind, label = label,
		sign_alg = st.subject_sign_alg, wrap_alg = st.subject_wrap_alg,
		sign_public_key = st.subject_sign_pub, ecdh_public_key = st.subject_ecdh_pub,
		fingerprint = fp,
	}, domain.Domain_Error{}
}

genesis :: proc(svc: ^Service, in_: Genesis_Input) -> (domain.Vault_Device, domain.Domain_Error) {
	if in_.user_id == "" do return {}, unauth("user is required")
	if !vault.valid_id_value(in_.user_id) do return {}, invalid("user id cannot be used in vault statements")
	if exists, err := directory_exists(svc, in_.user_id); err.code != .None {
		return {}, err
	} else if exists {
		return {}, domain.vault_reason_error(.Conflict, "directory_exists", "a vault directory already exists for this account")
	}
	st, ok := vault.statement_parse(in_.genesis_statement)
	if !ok || st.type != "genesis" do return {}, invalid("genesis_statement is not a canonical genesis statement")
	if st.user_id != in_.user_id do return {}, forbidden("statement is for another account")
	if st.seq != "1" || st.prev_hash != "" || st.epoch != "1" do return {}, invalid("genesis is log seq 1 with no prev_hash, epoch 1")
	if !vault.valid_decimal(st.issued_at_ms) do return {}, invalid("issued_at_ms is required")
	root, derr := subject_device_from_statement(&st, in_.user_id)
	if derr.code != .None do return {}, derr
	policy := domain.vault_kind_policy(root.kind)
	// The root must be an interactive approver (a browser now): a recovery key is
	// offline by design and must never become the pinned root.
	if !policy.can_be_root || !policy.can_approve || !policy.receives_wrap do return {}, invalid("the root device must be an interactive approver-capable device")
	if st.issuer_device_id != root.device_id do return {}, invalid("genesis is self-signed by the root")
	if len(st.epoch_commit) != vault.EPOCH_COMMIT_HEX_CHARS || !vault.is_lower_hex(st.epoch_commit) || !is_hex64_or_empty(st.wrap_sha256) do return {}, invalid("malformed genesis commitment")
	if !vault.verify(root.sign_alg, root.sign_public_key, transmute([]byte)in_.genesis_statement, in_.genesis_signature) do return {}, unauth("genesis signature does not verify")

	now := platform.clock_now(svc.clock)
	wrap_row, werr := check_wrap(svc, in_.wrap, in_.user_id, root, 1, 1, root, now)
	if werr.code != .None do return {}, werr
	head := vault.log_entry_hash(in_.genesis_statement, context.temp_allocator)

	root.status = .Approved
	root.approval_statement = in_.genesis_statement
	root.approval_signature = in_.genesis_signature
	root.approved_by_device_id = root.device_id
	root.created_at = now
	root.approved_at = now
	root.last_seen_at = now
	gerr := iface.vault_create_genesis(svc.repo, domain.Vault_Genesis{
		directory = {user_id = in_.user_id, version = 1, current_epoch = 1, root_device_id = root.device_id, head_hash = head, genesis_statement = in_.genesis_statement, genesis_signature = in_.genesis_signature, created_at = now, updated_at = now},
		device = root,
		epoch = {user_id = in_.user_id, epoch = 1, statement = in_.genesis_statement, signature = in_.genesis_signature, created_at = now},
		wrap = wrap_row,
		log = {user_id = in_.user_id, seq = 1, statement = in_.genesis_statement, signature = in_.genesis_signature, entry_hash = head, created_at = now},
	})
	if gerr.code != .None do return {}, gerr
	return root, domain.Domain_Error{}
}

// ── Register ────────────────────────────────────────────────────────────────

Register_Result :: struct {
	device:   domain.Vault_Device,
	// newly_pending: THIS call's pairing lookup is now the live one (insert or
	// re-pairing with a newer register statement); the caller notifies the user's
	// other devices only then.
	newly_pending: bool,
}

// register records a pending device under the pairing lookup and key_mac the device
// derived from its own code (plan §1 "Pairing"). The hub cannot check key_mac (it
// lacks the code); the approver does.
register :: proc(svc: ^Service, user_id, statement, signature, pair_lookup, pair_key_mac: string) -> (Register_Result, domain.Domain_Error) {
	if user_id == "" do return {}, unauth("user is required")
	if !vault.valid_id_value(user_id) do return {}, invalid("user id cannot be used in vault statements")
	st, ok := vault.statement_parse(statement)
	if !ok || st.type != "register" do return {}, invalid("statement is not a canonical register statement")
	if st.user_id != user_id do return {}, forbidden("statement is for another account")
	if st.seq != "" || st.prev_hash != "" || st.epoch != "" || st.epoch_commit != "" || st.wrap_sha256 != "" do return {}, invalid("register statements carry no directory binding")
	if !vault.valid_decimal(st.issued_at_ms) do return {}, invalid("issued_at_ms is required")
	dev, derr := subject_device_from_statement(&st, user_id)
	if derr.code != .None do return {}, derr
	// Bridges enroll through the device grant; a browser-style pending row for one would
	// be an approval path that skips the grant's PKCE binding.
	if dev.kind == "bridge" do return {}, invalid("bridges enroll with ham-bridge enroll")
	if st.issuer_device_id != dev.device_id do return {}, invalid("register statements are self-signed")
	if !vault.verify(dev.sign_alg, dev.sign_public_key, transmute([]byte)statement, signature) do return {}, unauth("proof_signature does not verify")
	if !vault.valid_pair_hex(pair_lookup) || !vault.valid_pair_hex(pair_key_mac) do return {}, invalid("pair_lookup and pair_key_mac must be 64 lowercase hex")

	now := platform.clock_now(svc.clock)
	expires, exp_ok := platform.expires_at_after_seconds_from(now, domain.VAULT_CODE_TTL_SECONDS)
	if !exp_ok do return {}, domain.domain_error(.Internal_Error, "clock unavailable")
	dev.status = .Pending
	dev.created_at = now
	dev.code_expires_at = expires
	dev.pair_lookup = pair_lookup
	dev.pair_key_mac = pair_key_mac
	dev.register_statement = statement
	stored, err := iface.vault_register_pending(svc.repo, dev, now)
	if err.code != .None do return {}, err
	if stored.status == .Revoked do return {}, forbidden("this device key was revoked; generate a new device identity")
	if stored.status == .Pending && stored.pair_lookup != pair_lookup {
		// A live request with a NEWER register statement exists (this one is stale or replayed).
		return {}, domain.vault_reason_error(.Conflict, "stale_register", "a newer pairing request exists for this device")
	}
	return Register_Result{device = stored, newly_pending = stored.status == .Pending}, domain.Domain_Error{}
}

// ── Approve (browser) ───────────────────────────────────────────────────────

Approve_Input :: struct {
	user_id:          string,
	device_id:        string,
	// The lookup the approver derived from the code it was given (must be the pending
	// request's), and its pair_mac over the approval for the new device to verify.
	pair_lookup:      string,
	pair_mac:         string,
	expected_version: i64,
	statement:        string,
	signature:        string,
	wrap:             Wrap_Input,
	signer:           domain.Vault_Device,
}

approve :: proc(svc: ^Service, in_: Approve_Input) -> (i64, domain.Domain_Error) {
	dir, found, err := iface.vault_get_directory(svc.repo, in_.user_id)
	if err.code != .None do return 0, err
	if !found do return 0, not_configured_error()
	if in_.expected_version != dir.version do return 0, domain.vault_conflict_error(dir.version)
	devices, derr := iface.vault_list_devices(svc.repo, in_.user_id)
	if derr.code != .None do return 0, derr
	target, has := find_device(devices, in_.device_id)
	if !has || target.status != .Pending do return 0, GENERIC_CODE_ERROR()
	// The approver resolved this request from the code on the new device: its lookup
	// must be the pending request's. The pair_mac is for the new device to verify
	// (the hub cannot), so only its shape is checked here.
	if !vault.valid_pair_hex(in_.pair_lookup) || !vault.pair_mac_equal(in_.pair_lookup, target.pair_lookup) do return 0, GENERIC_CODE_ERROR()
	if !vault.valid_pair_hex(in_.pair_mac) do return 0, invalid("pair_mac must be 64 lowercase hex")
	now := platform.clock_now(svc.clock)
	if target.code_expires_at <= now do return 0, GENERIC_CODE_ERROR()
	if target.kind == "bridge" || !domain.vault_kind_valid(target.kind) do return 0, invalid("this device kind is not approved here")

	slot := next_slot(dir)
	st, serr := parse_signed_statement(in_.statement, in_.signature, "approve", in_.user_id, slot, in_.signer)
	if serr.code != .None do return 0, serr
	if !subject_matches(&st, target) do return 0, invalid("approval statement does not describe the pending device")
	label, l_ok := vault.label_from_b64(st.subject_label_b64, context.temp_allocator)
	if !l_ok do return 0, invalid("subject_label_b64 is not a valid label")
	commit, cerr := current_epoch_commit(svc, in_.user_id, dir.current_epoch)
	if cerr.code != .None do return 0, cerr
	if st.epoch != i64_str(dir.current_epoch) || st.epoch_commit != commit do return 0, invalid("approval must name the current epoch and its epoch_commit")

	cm :=domain.Vault_Directory_Commit{
		user_id = in_.user_id, expected_version = in_.expected_version, now = now,
		expected_head_hash = dir.head_hash,
		log_statement = in_.statement, log_signature = in_.signature, log_entry_hash = vault.log_entry_hash(in_.statement, context.temp_allocator),
		approve_device_id = target.device_id, approval_statement = in_.statement,
		approval_signature = in_.signature, approved_by_device_id = in_.signer.device_id,
		approve_pair_mac = in_.pair_mac,
		label_device_id = target.device_id, label = label,
	}
	if domain.vault_kind_policy(target.kind).receives_wrap {
		row, werr := check_wrap(svc, in_.wrap, in_.user_id, target, dir.version + 1, dir.current_epoch, in_.signer, now)
		if werr.code != .None do return 0, werr
		// The signed approval must commit to exactly this wrap.
		digest: [32]byte
		w := in_.wrap.wrap
		if !vault.wrap_sha256(&w, digest[:]) do return 0, invalid("wrap is malformed")
		if st.wrap_sha256 == "" || st.wrap_sha256 != vault.hex_encode_lower(digest[:], context.temp_allocator) do return 0, invalid("approval statement must name this wrap in wrap_sha256")
		cm.wraps = []domain.Vault_Wrap_Row{row}
	} else if st.wrap_sha256 != "" {
		return 0, invalid("this device kind receives no wrap")
	}
	return iface.vault_commit(svc.repo, cm)
}

// ── Deny ────────────────────────────────────────────────────────────────────

// deny removes a pending device. Called after verify_request(.Approver), so only an
// approved approver device of the account can deny. Not a directory mutation (pending
// rows are not part of the signed chain), so there is no version. Unknown or
// non-pending devices are 404.
deny :: proc(svc: ^Service, user_id, device_id: string) -> domain.Domain_Error {
	if !vault.valid_device_id(device_id) do return domain.domain_error(.Not_Found, "no pending device with that id")
	removed, err := iface.vault_delete_pending(svc.repo, user_id, device_id)
	if err.code != .None do return err
	if !removed do return domain.domain_error(.Not_Found, "no pending device with that id")
	return domain.Domain_Error{}
}

// ── Bridge approval (via /device/approve) ───────────────────────────────────

Bridge_Approval_Input :: struct {
	user_id:                    string,
	expected_version:           i64,
	statement:                  string,
	signature:                  string,
	bridge_identity_public_key: string,
}

// check_bridge_approval validates a bridge's vault approval WITHOUT writing: the
// caller mints the bridge credential only after this passes, then commits with
// commit_bridge_approval. Returns the device row to insert (bridge_id filled later).
check_bridge_approval :: proc(svc: ^Service, in_: Bridge_Approval_Input) -> (domain.Vault_Device, domain.Domain_Error) {
	dir, found, err := iface.vault_get_directory(svc.repo, in_.user_id)
	if err.code != .None do return {}, err
	if !found do return {}, domain.domain_error(.Validation_Failed, "set up your vault on a browser before enrolling a bridge")
	if in_.expected_version != dir.version do return {}, domain.vault_conflict_error(dir.version)
	if in_.bridge_identity_public_key == "" do return {}, invalid("the bridge did not present an identity key; update ham-bridge and re-run enroll")
	st0, ok := vault.statement_parse(in_.statement)
	if !ok do return {}, invalid("vault_approval statement is not canonical")
	devices, derr := iface.vault_list_devices(svc.repo, in_.user_id)
	if derr.code != .None do return {}, derr
	issuer, has := find_device(devices, st0.issuer_device_id)
	if !has || issuer.status != .Approved || !domain.vault_kind_policy(issuer.kind).can_approve do return {}, forbidden("vault_approval issuer is not an approved approver device")
	st, serr := parse_signed_statement(in_.statement, in_.signature, "approve", in_.user_id, next_slot(dir), issuer)
	if serr.code != .None do return {}, serr
	if st.subject_kind != "bridge" || st.subject_sign_pub != in_.bridge_identity_public_key do return {}, invalid("vault_approval does not describe this bridge's identity key")
	dev, sderr := subject_device_from_statement(&st, in_.user_id)
	if sderr.code != .None do return {}, sderr
	commit, cerr := current_epoch_commit(svc, in_.user_id, dir.current_epoch)
	if cerr.code != .None do return {}, cerr
	if st.epoch != i64_str(dir.current_epoch) || st.epoch_commit != commit || st.wrap_sha256 != "" do return {}, invalid("vault_approval must name the current epoch, its epoch_commit, and no wrap")
	if _, exists := find_device(devices, dev.device_id); exists do return {}, domain.vault_reason_error(.Conflict, "device_exists", "this bridge identity is already in the directory")
	now := platform.clock_now(svc.clock)
	dev.status = .Approved
	dev.approval_statement = in_.statement
	dev.approval_signature = in_.signature
	dev.approved_by_device_id = issuer.device_id
	dev.created_at = now
	dev.approved_at = now
	return dev, domain.Domain_Error{}
}

// commit_bridge_approval appends the bridge's signed approval to the log and inserts
// the approved identity. If another live (approved, not retired) identity already
// maps to bridge_id (an attach), it is marked retired — a HINT — in the same
// transaction, so at most one live identity maps to a bridge_id; an approved browser
// then signs the old identity's real revoke.
commit_bridge_approval :: proc(svc: ^Service, in_: Bridge_Approval_Input, dev: domain.Vault_Device, bridge_id: string) -> (i64, domain.Domain_Error) {
	if bridge_id == "" do return 0, invalid("bridge_id is required")
	st, ok := vault.statement_parse(in_.statement)
	if !ok do return 0, invalid("vault_approval statement is not canonical")
	d := dev
	d.bridge_id = bridge_id
	cm := domain.Vault_Directory_Commit{
		user_id = in_.user_id, expected_version = in_.expected_version, now = platform.clock_now(svc.clock),
		// The statement was checked against (version, head) by check_bridge_approval; the
		// CAS on both refuses if the log moved since.
		expected_head_hash = st.prev_hash,
		log_statement = in_.statement, log_signature = in_.signature, log_entry_hash = vault.log_entry_hash(in_.statement, context.temp_allocator),
		insert_device = d,
	}
	devices, err := iface.vault_list_devices(svc.repo, in_.user_id)
	if err.code != .None do return 0, err
	for other in devices {
		if other.status != .Approved || other.bridge_id != bridge_id || other.retired_at != "" do continue
		if cm.hint_retire_device_id != "" do return 0, domain.domain_error(.Internal_Error, "more than one live identity maps to this bridge")
		cm.hint_retire_device_id, cm.hint_retire_bridge_id = other.device_id, bridge_id
	}
	return iface.vault_commit(svc.repo, cm)
}

// retire_bridge_entry marks the live directory identity of bridge_id retired (a
// HINT: retired_at only) after the bridge was revoked from bridge settings or its
// enrollment was rolled back. It consumes no directory version and appends nothing
// to the log: the identity stays approved in the signed log until an approved
// browser verifies it and signs a real revoke. Returns the hinted device id, or ""
// when there was nothing to hint.
retire_bridge_entry :: proc(svc: ^Service, user_id, bridge_id: string) -> (string, domain.Domain_Error) {
	if user_id == "" || bridge_id == "" do return "", domain.Domain_Error{}
	devices, derr := iface.vault_list_devices(svc.repo, user_id)
	if derr.code != .None do return "", derr
	target := ""
	for d in devices do if d.status == .Approved && d.bridge_id == bridge_id && d.retired_at == "" do target = d.device_id
	if target == "" do return "", domain.Domain_Error{}
	changed, err := iface.vault_mark_retired(svc.repo, user_id, target, bridge_id, platform.clock_now(svc.clock))
	if err.code != .None do return "", err
	return target if changed else "", domain.Domain_Error{}
}

// other_approved_for_bridge reports whether a live (approved, not retired) identity
// other than device_id maps to bridge_id (then the bridge's credentials must stay).
other_approved_for_bridge :: proc(svc: ^Service, user_id, bridge_id, device_id: string) -> (bool, domain.Domain_Error) {
	devices, err := iface.vault_list_devices(svc.repo, user_id)
	if err.code != .None do return false, err
	for d in devices do if d.device_id != device_id && d.status == .Approved && d.retired_at == "" && d.bridge_id == bridge_id do return true, domain.Domain_Error{}
	return false, domain.Domain_Error{}
}

// ── Revoke ──────────────────────────────────────────────────────────────────

Revoke_Input :: struct {
	user_id:          string,
	device_id:        string,
	expected_version: i64,
	// The revoke log op: names the revoked subject AND introduces epoch current+1
	// (epoch, epoch_commit), so a revocation and its rotation are one signed op.
	revoke_statement: string,
	signature:        string,
	wraps:            []Wrap_Input,
	signer:           domain.Vault_Device,
}

Revoke_Result :: struct {
	version: i64,
	target:  domain.Vault_Device,
}

// Revoke_Plan is a fully validated revocation that has not been written yet. The
// HTTP handler revokes a bridge target's credentials BETWEEN revoke_prepare and
// revoke_commit, so a failure there leaves the safe state (credentials dead or the
// request failed) rather than "revoked in the directory, credential still live".
Revoke_Plan :: struct {
	commit: domain.Vault_Directory_Commit,
	target: domain.Vault_Device,
}

revoke :: proc(svc: ^Service, in_: Revoke_Input) -> (Revoke_Result, domain.Domain_Error) {
	plan, err := revoke_prepare(svc, in_)
	if err.code != .None do return {}, err
	return revoke_commit(svc, plan)
}

revoke_commit :: proc(svc: ^Service, plan: Revoke_Plan) -> (Revoke_Result, domain.Domain_Error) {
	v, err := iface.vault_commit(svc.repo, plan.commit)
	if err.code != .None do return {}, err
	return Revoke_Result{version = v, target = plan.target}, domain.Domain_Error{}
}

revoke_prepare :: proc(svc: ^Service, in_: Revoke_Input) -> (Revoke_Plan, domain.Domain_Error) {
	// Enforced before anything else, whatever the rest of the request says.
	if in_.device_id == in_.signer.device_id do return {}, domain.vault_reason_error(.Conflict, "self_revoke", "a device cannot revoke itself")
	dir, found, err := iface.vault_get_directory(svc.repo, in_.user_id)
	if err.code != .None do return {}, err
	if !found do return {}, not_configured_error()
	if in_.expected_version != dir.version do return {}, domain.vault_conflict_error(dir.version)
	devices, derr := iface.vault_list_devices(svc.repo, in_.user_id)
	if derr.code != .None do return {}, derr
	target, has := find_device(devices, in_.device_id)
	if !has || target.status != .Approved do return {}, domain.domain_error(.Not_Found, "no approved device with that id")

	// The last-approver guard: at least one approver-capable device (a browser or a
	// recovery device) must remain approved.
	remaining_approvers := 0
	for d in devices {
		if d.device_id == target.device_id || d.status != .Approved do continue
		if domain.vault_kind_policy(d.kind).counts_as_approver do remaining_approvers += 1
	}
	if remaining_approvers == 0 do return {}, domain.vault_reason_error(.Conflict, "last_approver", "revoking this device would leave no device able to approve; add a recovery key first")

	new_epoch := dir.current_epoch + 1
	new_epoch_s := i64_str(new_epoch)
	rst, rerr := parse_signed_statement(in_.revoke_statement, in_.signature, "revoke", in_.user_id, next_slot(dir), in_.signer)
	if rerr.code != .None do return {}, rerr
	if !subject_matches(&rst, target) do return {}, invalid("revoke statement does not describe the target device")
	if rst.epoch != new_epoch_s do return {}, invalid("revoke must advance to epoch current+1")
	if len(rst.epoch_commit) != vault.EPOCH_COMMIT_HEX_CHARS || !vault.is_lower_hex(rst.epoch_commit) || rst.wrap_sha256 != "" do return {}, invalid("malformed revoke epoch commitment")

	// The wraps must cover EXACTLY the remaining approved wrap-receiving devices.
	now := platform.clock_now(svc.clock)
	expected := 0
	for d in devices {
		if d.device_id != target.device_id && d.status == .Approved && domain.vault_kind_policy(d.kind).receives_wrap do expected += 1
	}
	if len(in_.wraps) != expected do return {}, invalid("wraps must cover exactly the remaining approved devices")
	rows := make([]domain.Vault_Wrap_Row, len(in_.wraps), context.temp_allocator)
	for w, i in in_.wraps {
		recipient, r_has := find_device(devices, w.wrap.recipient_device_id)
		if !r_has || recipient.device_id == target.device_id || recipient.status != .Approved || !domain.vault_kind_policy(recipient.kind).receives_wrap {
			return {}, invalid("a wrap is addressed to a device that must not receive one")
		}
		for j in 0 ..< i do if rows[j].device_id == recipient.device_id do return {}, invalid("duplicate wrap recipient")
		row, werr := check_wrap(svc, w, in_.user_id, recipient, dir.version + 1, new_epoch, in_.signer, now)
		if werr.code != .None do return {}, werr
		rows[i] = row
	}
	return Revoke_Plan{
		target = target,
		commit = domain.Vault_Directory_Commit{
			user_id = in_.user_id, expected_version = in_.expected_version, now = now,
			expected_head_hash = dir.head_hash,
			log_statement = in_.revoke_statement, log_signature = in_.signature, log_entry_hash = vault.log_entry_hash(in_.revoke_statement, context.temp_allocator),
			revoke_device_id = target.device_id, revocation_statement = in_.revoke_statement,
			revocation_signature = in_.signature, revoked_by_device_id = in_.signer.device_id,
			new_epoch = new_epoch,
			wraps = rows, replace_all_wraps = true,
		},
	}, domain.Domain_Error{}
}

// ── Rotate (re-key without a revocation) ────────────────────────────────────
// An approver advances the account to epoch current+1 and wraps the new keyring to
// EXACTLY the approved wrap-receiving devices. Used after the hub retired an identity
// (rotation_recommended): a bridge revoked from bridge settings may still hold the
// current keyring. Same checks as the rotation half of revoke; CAS on the version.

Rotate_Input :: struct {
	user_id:          string,
	expected_version: i64,
	// A `rotate` log op: no subject, introduces epoch current+1.
	statement:        string,
	signature:        string,
	wraps:            []Wrap_Input,
	signer:           domain.Vault_Device,
}

rotate :: proc(svc: ^Service, in_: Rotate_Input) -> (i64, domain.Domain_Error) {
	dir, found, err := iface.vault_get_directory(svc.repo, in_.user_id)
	if err.code != .None do return 0, err
	if !found do return 0, not_configured_error()
	if in_.expected_version != dir.version do return 0, domain.vault_conflict_error(dir.version)
	devices, derr := iface.vault_list_devices(svc.repo, in_.user_id)
	if derr.code != .None do return 0, derr

	new_epoch := dir.current_epoch + 1
	est, eerr := parse_signed_statement(in_.statement, in_.signature, "rotate", in_.user_id, next_slot(dir), in_.signer)
	if eerr.code != .None do return 0, eerr
	if est.epoch != i64_str(new_epoch) do return 0, invalid("epoch must be current+1")
	if len(est.epoch_commit) != vault.EPOCH_COMMIT_HEX_CHARS || !vault.is_lower_hex(est.epoch_commit) || !subject_empty(&est) || est.wrap_sha256 != "" do return 0, invalid("malformed rotate statement")

	now := platform.clock_now(svc.clock)
	expected := 0
	for d in devices {
		if d.status == .Approved && domain.vault_kind_policy(d.kind).receives_wrap do expected += 1
	}
	if len(in_.wraps) != expected do return 0, invalid("wraps must cover exactly the approved devices")
	rows := make([]domain.Vault_Wrap_Row, len(in_.wraps), context.temp_allocator)
	for w, i in in_.wraps {
		recipient, r_has := find_device(devices, w.wrap.recipient_device_id)
		if !r_has || recipient.status != .Approved || !domain.vault_kind_policy(recipient.kind).receives_wrap {
			return 0, invalid("a wrap is addressed to a device that must not receive one")
		}
		for j in 0 ..< i do if rows[j].device_id == recipient.device_id do return 0, invalid("duplicate wrap recipient")
		row, werr := check_wrap(svc, w, in_.user_id, recipient, dir.version + 1, new_epoch, in_.signer, now)
		if werr.code != .None do return 0, werr
		rows[i] = row
	}
	return iface.vault_commit(svc.repo, domain.Vault_Directory_Commit{
		user_id = in_.user_id, expected_version = in_.expected_version, now = now,
		expected_head_hash = dir.head_hash,
		log_statement = in_.statement, log_signature = in_.signature, log_entry_hash = vault.log_entry_hash(in_.statement, context.temp_allocator),
		new_epoch = new_epoch,
		wraps = rows, replace_all_wraps = true,
	})
}

// ── Owner reset ─────────────────────────────────────────────────────────────
// The only way to replace a directory's root. It is requested from an interactive
// browser session (Trusted_Proxy; the handler enforces it), and it is DELAYED: the
// directory is destroyed RESET_DELAY_SECONDS (72 h) later, never at once. The request
// is announced to every session and device of the account (WS + push), and any
// approved device may cancel it with a signed request during the delay. So a stolen
// session cannot quietly swap the root: the owner's devices see the notice and cancel.
// An owner who really lost every approver waits out the delay, then runs genesis
// again. The delay is always 72 h (no "no device seen recently" shortcut).
//
// Execution (app reaper, reaper_sweep_vault_resets) first revokes the credentials of
// every bridge the account owns — and fails closed, keeping the directory and
// retrying on the next sweep, if any revoke fails — then deletes the directory, its
// devices, epochs and wraps in one transaction.

RESET_DELAY_SECONDS :: 72 * 60 * 60

schedule_reset :: proc(svc: ^Service, user_id: string) -> (reset: domain.Vault_Reset, newly: bool, err: domain.Domain_Error) {
	if user_id == "" do return {}, false, unauth("user is required")
	now := platform.clock_now(svc.clock)
	due, ok := platform.expires_at_after_seconds_from(now, svc.reset_delay_seconds)
	if !ok do return {}, false, domain.domain_error(.Internal_Error, "clock unavailable")
	return iface.vault_schedule_reset(svc.repo, domain.Vault_Reset{user_id = user_id, requested_at = now, due_at = due})
}

get_reset :: proc(svc: ^Service, user_id: string) -> (domain.Vault_Reset, bool, domain.Domain_Error) {
	return iface.vault_get_reset(svc.repo, user_id)
}

// cancel_reset is called only after verify_request(.Approver) authenticated the
// cancelling device. Idempotent: false when nothing was scheduled.
cancel_reset :: proc(svc: ^Service, user_id: string) -> (bool, domain.Domain_Error) {
	return iface.vault_cancel_reset(svc.repo, user_id)
}

due_resets :: proc(svc: ^Service) -> ([]string, domain.Domain_Error) {
	return iface.vault_list_due_resets(svc.repo, platform.clock_now(svc.clock))
}

// execute_reset destroys the directory if its reset is (still) due. The caller must
// already have revoked the account's bridge credentials.
execute_reset :: proc(svc: ^Service, user_id: string) -> (bool, domain.Domain_Error) {
	return iface.vault_execute_reset(svc.repo, user_id, platform.clock_now(svc.clock))
}
