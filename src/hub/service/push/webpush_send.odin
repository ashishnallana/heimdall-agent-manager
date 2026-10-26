package push

// WP-SEND-1: deliver an encrypted Web Push message to every subscription a user
// owns. For each subscription we RFC 8291-encrypt the payload, sign a VAPID JWT
// for the endpoint's origin, and POST the aes128gcm body via the Hub's
// src/lib/httpc. Endpoints that report 404/410 Gone are pruned.
//
// send_to_user is BLOCKING; callers on the request path must run it on a
// background thread (see send_to_user_async) so it never stalls the response.

import "base:runtime"
import "core:crypto/ecdsa"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:thread"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import httpc "odin_test:lib/httpc"

// WEBPUSH_TTL_SECONDS is the `TTL` header: how long the push service should try
// to deliver if the device is offline. One day matches the design doc.
WEBPUSH_TTL_SECONDS :: 86400
WEBPUSH_TTL_HEADER_VALUE :: "86400" // keep equal to WEBPUSH_TTL_SECONDS

// Async_Send_Job carries an OWNED copy of the send arguments to a background
// thread. Both the job struct and its strings live on the PERSISTENT heap
// (runtime.heap_allocator), never the ambient allocator: send_to_user_async is
// called from an HTTP handler whose context.allocator is the per-request
// virtual.Arena (MEM-4), which is destroyed the instant the handler returns —
// long before the spawned worker reads these fields. The worker releases them
// with async_send_job_destroy on exit.
@(private)
Async_Send_Job :: struct {
	service:       ^Push_Service,
	owner_user_id: domain.User_ID,
	payload_json:  string,
}

// async_send_job_make allocates an Async_Send_Job and deep-copies the caller's
// owner id + payload onto the persistent heap so they outlive the caller's
// per-request arena. Returns nil if allocation fails.
@(private)
async_send_job_make :: proc(service: ^Push_Service, owner_user_id: domain.User_ID, payload_json: string) -> ^Async_Send_Job {
	job := new(Async_Send_Job, runtime.heap_allocator())
	if job == nil {
		return nil
	}
	job.service = service
	job.owner_user_id = domain.User_ID(strings.clone(string(owner_user_id), runtime.heap_allocator()))
	job.payload_json = strings.clone(payload_json, runtime.heap_allocator())
	return job
}

// async_send_job_destroy frees everything async_send_job_make allocated, using
// the same persistent heap allocator so alloc/free stay paired no matter which
// thread runs (the worker's context.allocator is the default heap, not the
// caller's request arena).
@(private)
async_send_job_destroy :: proc(job: ^Async_Send_Job) {
	if job == nil {
		return
	}
	delete(job.payload_json, runtime.heap_allocator())
	delete(string(job.owner_user_id), runtime.heap_allocator())
	free(job, runtime.heap_allocator())
}

// send_to_user_async runs send_to_user on a background thread so the request
// path is never blocked by network I/O to push endpoints. It deep-copies the
// owner id + payload onto the persistent heap (the caller keeps ownership of the
// originals, which on the request path live on the per-request arena). Best-
// effort: delivery failures are swallowed. No-op when push is disabled.
send_to_user_async :: proc(service: ^Push_Service, owner_user_id: domain.User_ID, payload_json: string) {
	if !push_send_enabled(service) {
		return
	}
	job := async_send_job_make(service, owner_user_id, payload_json)
	if job == nil {
		return
	}
	// The spawned Thread struct + thread.create's internal allocations must ALSO
	// live on the persistent heap, not the caller's per-request arena (MEM-4). This
	// worker outlives the handler by seconds (11 sequential push sends), but the
	// handler's arena is destroyed the instant it returns. thread.create allocates
	// the Thread with the ambient context.allocator and stores it as
	// t.creation_allocator; an arena-backed Thread is therefore freed while the OS
	// thread is still running, so the trampoline's post-proc `t.flags` store (and
	// self-cleanup's free(t, creation_allocator)) touch freed memory -> SIGSEGV
	// (P0 part 2). Creating under the heap allocator makes t.creation_allocator the
	// heap, so self-cleanup frees the Thread correctly when the worker exits.
	context.allocator = runtime.heap_allocator()
	thread.run_with_data(rawptr(job), async_send_entry)
}

@(private = "file")
async_send_entry :: proc(data: rawptr) {
	job := (^Async_Send_Job)(data)
	if job == nil do return
	defer async_send_job_destroy(job)
	send_to_user_scoped(job)
}

// send_to_user_scoped runs one fan-out on a scratch arena. The worker is a fresh
// thread on the persistent heap, and send_to_user's subscription rows, VAPID
// claims and HTTP responses (one set per subscription) are never freed by it.
// The job is heap-owned and destroyed by async_send_entry, outside this scope.
@(private = "file")
send_to_user_scoped :: proc(job: ^Async_Send_Job) {
	scratch: virtual.Arena
	scratch_ok := virtual.arena_init_growing(&scratch) == nil
	defer if scratch_ok do virtual.arena_destroy(&scratch)
	allocator, temp_allocator := context.allocator, context.temp_allocator
	if scratch_ok do allocator, temp_allocator = virtual.arena_allocator(&scratch), virtual.arena_allocator(&scratch)
	context.allocator, context.temp_allocator = allocator, temp_allocator
	_ = send_to_user(job.service, job.owner_user_id, job.payload_json)
}

// Push_Send_Class classifies a single delivery attempt for pruning purposes.
Push_Send_Class :: enum {
	Success,     // 2xx — delivered.
	Gone,        // 404/410 — subscription permanently gone (RFC 8030); always prune.
	Auth_Failed, // 401/403 — VAPID/auth rejection; prune ONLY if isolated (see breaker).
	Transient,   // 429/5xx/other, transport failure, or pre-send error — never prune.
}

// classify_push_status maps a push-service HTTP status (or a transport/pre-send
// failure, transport_ok=false) to a prune class. Only 404/410 (Gone) and 401/403
// (Auth_Failed) are ever prune-eligible; everything else — 429, 5xx, other 4xx
// (e.g. 400/413), and dial/tls/timeout/encode failures — is Transient and MUST
// NOT be pruned, since it may recover or reflect a server-side (not sub) problem.
@(private)
classify_push_status :: proc(status: int, transport_ok: bool) -> Push_Send_Class {
	if !transport_ok {
		return .Transient
	}
	switch {
	case status >= 200 && status < 300:
		return .Success
	case status == 404 || status == 410:
		return .Gone
	case status == 401 || status == 403:
		return .Auth_Failed
	case:
		return .Transient
	}
}

// push_auth_breaker_tripped reports whether 401/403 failures across a fan-out look
// server-wide (a likely VAPID/misconfig problem, e.g. an accidental key rotation
// that 403s every subscription at once) rather than specific to one dead sub.
// When it trips, auth-failed subs are NOT pruned — a naive "prune on 403" would
// otherwise wipe every affected subscription system-wide on a single bad batch.
// Migration-free: it trips when there were no successes at all, or when auth
// failures are at least half of the whole batch. An auth failure is only treated
// as sub-specific (prune-worthy) when it is a minority AND other sends succeeded.
@(private)
push_auth_breaker_tripped :: proc(successes, auth_failures, total: int) -> bool {
	if auth_failures == 0 {
		return false
	}
	return successes == 0 || auth_failures * 2 >= total
}

// push_should_prune decides whether one attempt's subscription should be removed,
// given whether the batch-level auth breaker tripped. Gone is always pruned;
// Auth_Failed is pruned only when the breaker did NOT trip (an isolated failure).
@(private)
push_should_prune :: proc(class: Push_Send_Class, auth_breaker_tripped: bool) -> bool {
	#partial switch class {
	case .Gone:
		return true
	case .Auth_Failed:
		return !auth_breaker_tripped
	}
	return false
}

// Push_Send_Outcome records one subscription's fan-out result so pruning can be
// decided AFTER the whole batch is known (the auth breaker needs batch stats).
// sub_id/endpoint are borrowed from the caller's `subs` slice, which outlives it.
@(private)
Push_Send_Outcome :: struct {
	sub_id:   domain.Push_Subscription_ID,
	endpoint: string,
	status:   int,
	class:    Push_Send_Class,
}

// apply_push_prune removes dead subscriptions from a completed fan-out and logs
// the outcome. It derives the auth circuit breaker from the batch, prunes Gone
// (404/410) unconditionally and isolated Auth_Failed (401/403) subs, and skips all
// pruning (WARN only) when the breaker trips. Returns how many rows it pruned and
// whether the breaker tripped. Runs on the async push worker thread; the repo
// delete is the same call the fan-out already performs, so it adds no new
// cross-thread DB access.
@(private)
apply_push_prune :: proc(service: ^Push_Service, owner_user_id: domain.User_ID, outcomes: []Push_Send_Outcome) -> (pruned: int, breaker_tripped: bool) {
	successes := 0
	auth_failures := 0
	for o in outcomes {
		#partial switch o.class {
		case .Success:
			successes += 1
		case .Auth_Failed:
			auth_failures += 1
		}
	}

	breaker_tripped = push_auth_breaker_tripped(successes, auth_failures, len(outcomes))
	for o in outcomes {
		if !push_should_prune(o.class, breaker_tripped) {
			continue
		}
		reason := "gone(404/410)" if o.class == .Gone else "isolated-auth(401/403)"
		_, del_err := iface.push_subscription_delete_by_id(service.subscriptions, o.sub_id)
		if del_err.code == .None {
			pruned += 1
			fmt.eprintfln("ham-push INFO prune: removed stale subscription sub=%s status=%d endpoint=%s reason=%s", string(o.sub_id), o.status, o.endpoint, reason)
		} else {
			fmt.eprintfln("ham-push WARN prune: delete FAILED sub=%s status=%d err=%v", string(o.sub_id), o.status, del_err.code)
		}
	}
	if breaker_tripped && auth_failures > 0 {
		// A batch-wide auth failure is almost always a server/VAPID problem (e.g. an
		// accidental key rotation), not many subs going bad at once — so keep them all
		// and shout, rather than deleting everyone's subscriptions.
		fmt.eprintfln(
			"ham-push WARN send_to_user: auth circuit breaker TRIPPED — %d/%d sends failed with 401/403; NOT pruning (likely VAPID/server misconfig, e.g. key rotation). owner=%s",
			auth_failures,
			len(outcomes),
			string(owner_user_id),
		)
	}
	return
}

// send_to_user encrypts payload_json and pushes it to every subscription owned by
// owner_user_id. Returns the number of successful deliveries. Dead subscriptions
// are pruned so delivery self-heals: 404/410 (Gone) unconditionally, and isolated
// 401/403 (Auth_Failed) — but a batch-wide auth failure (likely a VAPID/server
// misconfig) trips a circuit breaker that logs a WARNING and prunes nothing. When
// push is disabled (no VAPID keypair) it is a no-op returning 0.
send_to_user :: proc(service: ^Push_Service, owner_user_id: domain.User_ID, payload_json: string) -> int {
	if !push_send_enabled(service) {
		push_metrics_record("skipped")
		return 0
	}

	subs, err := iface.push_subscription_list_by_owner(service.subscriptions, owner_user_id)
	if err.code != .None {
		fmt.eprintfln("ham-push DEBUG send_to_user: list subs FAILED owner=%s err=%v", string(owner_user_id), err.code)
		push_metrics_record("skipped")
		return 0
	}
	defer delete(subs)
	fmt.eprintfln("ham-push DEBUG send_to_user: owner=%s subscriptions=%d", string(owner_user_id), len(subs))
	if len(subs) == 0 {
		return 0
	}

	// Decode the VAPID private scalar + public key once for the whole batch.
	// A failure here is a delivery failure for every subscription in the batch.
	priv_bytes, priv_ok := base64url_decode(service.vapid.private_key)
	if !priv_ok {
		fmt.eprintln("ham-push DEBUG send_to_user: VAPID private-key base64url decode FAILED")
		for _ in subs do push_metrics_record("failed")
		return 0
	}
	defer delete(priv_bytes)
	vapid_priv: ecdsa.Private_Key
	defer ecdsa.private_key_clear(&vapid_priv)
	if !ecdsa.private_key_set_bytes(&vapid_priv, .SECP256R1, priv_bytes) {
		fmt.eprintln("ham-push DEBUG send_to_user: ecdsa private_key_set_bytes FAILED")
		for _ in subs do push_metrics_record("failed")
		return 0
	}

	// DEBUG: derive the public key from the loaded private scalar and compare to
	// the configured VAPID public key. A keypair mismatch is a prime cause of
	// Apple's 403 BadJwtToken (Apple verifies the JWT signature against `k=`).
	{
		dbg_pub: ecdsa.Public_Key
		ecdsa.public_key_set_priv(&dbg_pub, &vapid_priv)
		dbg_bytes: [65]byte
		ecdsa.public_key_bytes(&dbg_pub, dbg_bytes[:])
		dbg_pub_b64 := base64url_encode(dbg_bytes[:])
		defer delete(dbg_pub_b64)
		fmt.eprintfln(
			"ham-push DEBUG send_to_user: derived_pub=%s configured_pub=%s keypair_match=%v",
			dbg_pub_b64,
			service.vapid.public_key,
			dbg_pub_b64 == service.vapid.public_key,
		)
	}

	now_unix := time.time_to_unix(time.now())

	// Pass 1: deliver to every subscription and record the classified outcome. We
	// do NOT prune here — the auth circuit breaker needs the whole batch's stats.
	outcomes := make([]Push_Send_Outcome, len(subs))
	defer delete(outcomes)
	successes := 0
	for sub, i in subs {
		class, status := send_to_subscription(service, &vapid_priv, sub, payload_json, now_unix)
		outcomes[i] = Push_Send_Outcome{sub_id = sub.id, endpoint = sub.endpoint, status = status, class = class}
		push_metrics_record(push_metrics_result(class))
		if class == .Success {
			successes += 1
		}
	}

	// Pass 2: prune dead subscriptions so delivery self-heals (Gone always; isolated
	// auth failures only — a batch-wide auth failure trips the breaker and prunes
	// nothing, logging a WARNING instead).
	_, _ = apply_push_prune(service, owner_user_id, outcomes)
	return successes
}

// send_to_subscription encrypts + delivers one message and returns its prune
// classification plus the push-service HTTP status (0 when the request never got
// a response). It does NOT prune — the caller (send_to_user) decides that once the
// whole fan-out is classified, so the auth circuit breaker can see the batch.
// Pre-send failures (bad keys, encrypt/sign errors) and transport failures are
// Transient (never pruned): they may be our-side/transient, not a dead sub.
@(private = "file")
send_to_subscription :: proc(
	service: ^Push_Service,
	vapid_priv: ^ecdsa.Private_Key,
	sub: domain.Push_Subscription,
	payload_json: string,
	now_unix: i64,
) -> (Push_Send_Class, int) {
	// VAPID JWT audience is the endpoint origin — log it first so we can see the
	// push service (e.g. web.push.apple.com vs fcm.googleapis.com) even if a later
	// step fails.
	audience, aud_ok := vapid_endpoint_audience(sub.endpoint)
	if !aud_ok {
		fmt.eprintfln("ham-push DEBUG send: endpoint audience parse FAILED sub=%s", string(sub.id))
		return .Transient, 0
	}
	defer delete(audience)
	fmt.eprintfln("ham-push DEBUG send: sub=%s aud=%s", string(sub.id), audience)

	ua_public, ua_ok := base64url_decode(sub.p256dh)
	if !ua_ok {
		fmt.eprintfln("ham-push DEBUG send: p256dh decode FAILED aud=%s", audience)
		return .Transient, 0
	}
	defer delete(ua_public)
	auth_secret, auth_ok := base64url_decode(sub.auth)
	if !auth_ok {
		fmt.eprintfln("ham-push DEBUG send: auth decode FAILED aud=%s", audience)
		return .Transient, 0
	}
	defer delete(auth_secret)

	enc, enc_ok := webpush_encrypt(transmute([]byte)payload_json, ua_public, auth_secret)
	if !enc_ok {
		fmt.eprintfln("ham-push DEBUG send: webpush_encrypt FAILED aud=%s", audience)
		return .Transient, 0
	}
	defer delete(enc.body)

	claims := vapid_claims_for(audience, service.vapid.subject, now_unix)
	// DEBUG: the exact signed VAPID claims. This is public JWT content (no key, no
	// signature — not a secret) and lets ops confirm the real prod subject/aud/exp,
	// which is otherwise invisible in the logs. A malformed/unexpected `sub` (or an
	// out-of-range `exp`) is a prime Apple `BadJwtToken` cause that FCM tolerates.
	fmt.eprintfln("ham-push DEBUG vapid-claims: aud=%q sub=%q exp=%d", claims.audience, claims.subject, claims.expiry)
	jwt, jwt_ok := vapid_sign_jwt(vapid_priv, claims)
	if !jwt_ok {
		fmt.eprintfln("ham-push DEBUG send: vapid_sign_jwt FAILED aud=%s", audience)
		return .Transient, 0
	}
	defer delete(jwt)
	authorization := vapid_authorization_header(jwt, service.vapid.public_key)
	defer delete(authorization)

	// The endpoint is the whole target URL (path and query included); curl sends
	// an RFC 9110 Host header without the default port, which strict push
	// services (web.push.apple.com) require.
	endpoint, url_err := httpc.parse_url(sub.endpoint)
	if url_err != .None {
		return .Transient, 0
	}
	headers := [?]httpc.Header{
		{name = "Authorization", value = authorization},
		{name = "Content-Encoding", value = "aes128gcm"},
		{name = "TTL", value = WEBPUSH_TTL_HEADER_VALUE},
	}
	resp, err := httpc.send({
		method = .POST, url = endpoint, headers = headers[:],
		body = httpc.raw_body(httpc.CONTENT_TYPE_OCTET_STREAM, enc.body),
		max_response_bytes = 64 * 1024,
	}, context.temp_allocator)
	if err != .None {
		fmt.eprintfln("ham-push DEBUG send: transport FAILED (%s) aud=%s", httpc.error_string(err), audience)
		return .Transient, 0
	}

	// Log the push-service response so a silent Apple/APNs rejection (4xx with a
	// reason body) is visible to ops. Body is truncated; it carries no secret.
	body_preview := httpc.text(resp)
	if len(body_preview) > 300 {
		body_preview = body_preview[:300]
	}
	fmt.eprintfln("ham-push DEBUG send: aud=%s status=%d body=%q", audience, resp.status, body_preview)

	// Classify only; send_to_user prunes once the whole batch is known.
	return classify_push_status(resp.status, true), resp.status
}

