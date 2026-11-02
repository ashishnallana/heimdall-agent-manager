package mcp

// ── E2EE artifact transfers: Hub-side state machine (docs/plans/mcp-large-artifact-transfers.md) ──
//
// STRICT E2EE invariant (§13.1): nothing in this file seals, opens, holds a keyring,
// enters hosted_with_access or enqueues a device control job. The Hub stages and
// serves CIPHERTEXT only and checks it BLIND (§5.4): canonical token grammar, vault
// id and current epoch from the verified directory, exact plaintext length from the
// token length, SHA-256 of the ciphertext, and a device-signed receipt. A static
// test (transfers_test.odin) scans this file for forbidden references.

import "core:crypto/sha2"
import "core:encoding/base64"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import vault "odin_test:lib/vault"
import os_random "odin_test:lib/os_random"

TRANSFER_TOKEN_PREFIX :: "hxt_"

// Transfer_Directory_Proc returns the owner's verified device directory (vault id,
// current epoch, trusted devices) as seen through the transfer's grant; production
// wiring uses verified_grant_directory (hosted.odin) and must also fail for a
// revoked grant. It carries public keys only.
Transfer_Directory_Proc :: proc(user: rawptr, owner, grant_id: string) -> (^vault.Verified_Directory, bool)

Transfer_Service :: struct {
	repo:          ^iface.Transfer_Repository,
	directory:     Transfer_Directory_Proc,
	directory_ctx: rawptr,
	now_ms:        proc() -> i64, // nil = wall clock
	data_path_in_flight: i64,  // global data-path semaphore (§7)
	commits_in_flight:   i64,  // global commit semaphore (§7)
	data_path_max:       i64,  // 0 = contracts default
	commit_max:          i64,
	staged_global_max:   i64,
	// In-memory per-owner / per-grant limits (§7); lost on restart, which only resets
	// the windows.
	limits_mu:     sync.Mutex,
	owner_gets:    map[string]int,
	grant_windows: map[string]Transfer_Rate_Window,
}

Transfer_Rate_Window :: struct {
	begin_hour_start, data_minute_start: i64,
	begins, data_requests: int,
}

TRANSFER_BEGINS_PER_HOUR      :: 10
TRANSFER_DATA_PER_MINUTE      :: 60
TRANSFER_MAX_GETS_PER_OWNER   :: 2

// transfer_rate_allow counts one *_begin (begin=true) or one data-path request for a
// grant and reports whether it is within the per-grant window.
transfer_rate_allow :: proc(s: ^Transfer_Service, grant_id: string, begin: bool) -> bool {
	now := now_ms(s)
	sync.mutex_lock(&s.limits_mu); defer sync.mutex_unlock(&s.limits_mu)
	if s.grant_windows == nil do s.grant_windows = make(map[string]Transfer_Rate_Window)
	w, found := s.grant_windows[grant_id]
	if begin {
		if now - w.begin_hour_start >= 3_600_000 { w.begin_hour_start = now; w.begins = 0 }
		if w.begins >= TRANSFER_BEGINS_PER_HOUR do return false
		w.begins += 1
	} else {
		if now - w.data_minute_start >= 60_000 { w.data_minute_start = now; w.data_requests = 0 }
		if w.data_requests >= TRANSFER_DATA_PER_MINUTE do return false
		w.data_requests += 1
	}
	if found do s.grant_windows[grant_id] = w
	else do s.grant_windows[strings.clone(grant_id)] = w
	return true
}

// transfer_owner_get_acquire admits at most 2 concurrent ciphertext GETs per owner.
transfer_owner_get_acquire :: proc(s: ^Transfer_Service, owner: string) -> bool {
	sync.mutex_lock(&s.limits_mu); defer sync.mutex_unlock(&s.limits_mu)
	if s.owner_gets == nil do s.owner_gets = make(map[string]int)
	n, found := s.owner_gets[owner]
	if n >= TRANSFER_MAX_GETS_PER_OWNER do return false
	if found do s.owner_gets[owner] = n + 1
	else do s.owner_gets[strings.clone(owner)] = 1
	return true
}
transfer_owner_get_release :: proc(s: ^Transfer_Service, owner: string) {
	sync.mutex_lock(&s.limits_mu); defer sync.mutex_unlock(&s.limits_mu)
	if n, found := s.owner_gets[owner]; found && n > 0 do s.owner_gets[owner] = n - 1
}

rate_limited :: proc() -> Transfer_Fail {
	return {code = .Rate_Limited, reason = "rate_limited", retryable = true, retry_after_ms = contracts.ARTIFACT_TRANSFER_RETRY_AFTER_MS}
}

// Transfer_Fail is a stable, machine-readable failure. reason is the MCP/HTTP error
// code from the design (§5.1/§5.2); retryable failures never change durable state.
Transfer_Fail :: struct {
	code:      contracts.Error_Code,
	reason:    string,
	retryable: bool,
	retry_after_ms: int,
	offset:    i64, // current Upload-Offset for offset conflicts
}

@(private = "file")
fail :: proc(code: contracts.Error_Code, reason: string, retryable := false) -> Transfer_Fail {
	return {code = code, reason = reason, retryable = retryable}
}

transfer_ok :: proc(f: Transfer_Fail) -> bool { return f.code == .None }

@(private = "file")
now_ms :: proc(s: ^Transfer_Service) -> i64 {
	if s.now_ms != nil do return s.now_ms()
	return time.time_to_unix_nano(time.now()) / 1_000_000
}

// transfer_time renders ms since epoch as fixed-width RFC 3339 UTC, so stored
// timestamps order lexically.
transfer_time :: proc(ms: i64) -> string {
	t := time.unix(ms / 1000, (ms % 1000) * 1_000_000)
	y, mon, d := time.date(t)
	h, mi, sec := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", y, int(mon), d, h, mi, sec, ms % 1000)
}

@(private = "file")
sha_hex :: proc(data: []byte) -> string {
	digest: [32]byte
	ctx: sha2.Context_256
	sha2.init_256(&ctx); sha2.update(&ctx, data); sha2.final(&ctx, digest[:])
	return vault.hex_encode_lower(digest[:], context.temp_allocator)
}

// transfer_token_sha256 is the only form in which a transfer token is stored.
transfer_token_sha256 :: proc(token: string) -> string {
	if !strings.has_prefix(token, TRANSFER_TOKEN_PREFIX) || len(token) != len(TRANSFER_TOKEN_PREFIX) + 43 do return ""
	return sha_hex(transmute([]byte)token)
}

@(private = "file")
mint_token :: proc() -> (token: string, digest: string, ok: bool) {
	raw: [32]byte
	if !os_random.fill(raw[:]) do return "", "", false
	enc, err := base64.encode(raw[:], base64.ENC_URL_TABLE, context.temp_allocator)
	if err != nil do return "", "", false
	enc = strings.trim_right(enc, "=")
	token = strings.concatenate({TRANSFER_TOKEN_PREFIX, enc}, context.temp_allocator)
	return token, transfer_token_sha256(token), len(enc) == 43
}

@(private = "file")
mint_id :: proc(prefix: string) -> string {
	raw: [12]byte
	os_random.fill(raw[:])
	return strings.concatenate({prefix, vault.hex_encode_lower(raw[:], context.temp_allocator)}, context.temp_allocator)
}

// ── Semaphores (§7): acquired BEFORE any body is read or SQLite is touched ──

transfer_data_path_acquire :: proc(s: ^Transfer_Service) -> bool {
	limit := s.data_path_max > 0 ? s.data_path_max : contracts.ARTIFACT_TRANSFER_DATA_PATH_MAX_CONCURRENT
	if sync.atomic_add(&s.data_path_in_flight, 1) >= limit {
		sync.atomic_sub(&s.data_path_in_flight, 1)
		return false
	}
	return true
}
transfer_data_path_release :: proc(s: ^Transfer_Service) { sync.atomic_sub(&s.data_path_in_flight, 1) }

@(private = "file")
commit_acquire :: proc(s: ^Transfer_Service) -> bool {
	limit := s.commit_max > 0 ? s.commit_max : contracts.ARTIFACT_TRANSFER_COMMIT_MAX_CONCURRENT
	if sync.atomic_add(&s.commits_in_flight, 1) >= limit {
		sync.atomic_sub(&s.commits_in_flight, 1)
		return false
	}
	return true
}

busy :: proc() -> Transfer_Fail {
	return {code = .Rate_Limited, reason = "busy", retryable = true, retry_after_ms = contracts.ARTIFACT_TRANSFER_RETRY_AFTER_MS}
}

// ── Begin ──

Transfer_Caller :: struct {
	owner, client_id, grant_id, family_id: string,
}

Upload_Begin_Input :: struct {
	request_id, request_digest: string,
	kind, content_type, ext, associations: string,
}

@(private = "file")
kind_ok :: proc(kind: string) -> bool {
	switch kind {
	case "file", "text", "markdown", "json", "html-bundle":
		return true
	}
	return false
}

@(private = "file")
current_vault :: proc(s: ^Transfer_Service, owner, grant_id: string) -> (vault_id: string, epoch: u32, dir: ^vault.Verified_Directory, ok: bool) {
	if s.directory == nil do return "", 0, nil, false
	d, found := s.directory(s.directory_ctx, owner, grant_id)
	if !found || d == nil || d.current_epoch == 0 do return "", 0, nil, false
	buf: [vault.VAULT_ID_HEX_CHARS]byte
	return strings.clone(vault.vault_id_hex(d.vault_id, buf[:]), context.temp_allocator), d.current_epoch, d, true
}

// transfer_upload_begin creates (or replays) an upload transfer with a reserved
// artifact id and returns a freshly minted bearer token. Replay with the same
// request_id and digest rotates the token; a changed digest is a conflict; replay of
// a terminal transfer returns its state and no token.
transfer_upload_begin :: proc(s: ^Transfer_Service, who: Transfer_Caller, in_: Upload_Begin_Input) -> (domain.Mcp_Transfer, string, Transfer_Fail) {
	if len(in_.request_id) == 0 || len(in_.request_id) > 128 do return {}, "", fail(.Validation_Failed, "invalid_request_id")
	if !kind_ok(in_.kind) do return {}, "", fail(.Validation_Failed, "invalid_kind")
	if len(in_.content_type) == 0 || len(in_.content_type) > 255 || !vault.transfer_field_ok(in_.content_type) do return {}, "", fail(.Validation_Failed, "invalid_content_type")
	if in_.kind == "html-bundle" && in_.content_type != "application/zip" do return {}, "", fail(.Validation_Failed, "invalid_content_type")
	if len(in_.ext) > 32 do return {}, "", fail(.Validation_Failed, "invalid_ext")
	if prior, found, err := s.repo.get_by_request(s.repo.ctx, who.owner, who.client_id, in_.request_id); err.code != .None {
		return {}, "", fail(.Internal_Error, "internal")
	} else if found {
		return replay_begin(s, prior, in_.request_digest)
	}
	vid, epoch, _, vok := current_vault(s, who.owner, who.grant_id)
	if !vok do return {}, "", fail(.Validation_Failed, "vault_required")
	if !transfer_rate_allow(s, who.grant_id, true) do return {}, "", rate_limited()
	active, staged, uerr := s.repo.owner_usage(s.repo.ctx, who.owner, domain.MCP_TRANSFER_UPLOAD)
	if uerr.code != .None do return {}, "", fail(.Internal_Error, "internal")
	if active >= contracts.ARTIFACT_TRANSFER_MAX_UPLOADS_PER_OWNER || staged >= contracts.ARTIFACT_TRANSFER_STAGED_MAX_PER_OWNER {
		f := fail(.Rate_Limited, "quota_exceeded", true); f.retry_after_ms = contracts.ARTIFACT_TRANSFER_RETRY_AFTER_MS
		return {}, "", f
	}
	token, digest, tok_ok := mint_token()
	if !tok_ok do return {}, "", fail(.Internal_Error, "internal")
	now := now_ms(s)
	x := domain.Mcp_Transfer{
		transfer_id = mint_id("xfr_"), owner_user_id = who.owner, client_id = who.client_id, grant_id = who.grant_id, family_id = who.family_id,
		direction = domain.MCP_TRANSFER_UPLOAD, state = domain.MCP_TRANSFER_RECEIVING, token_sha256 = digest,
		artifact_id = mint_id("art_"), request_id = in_.request_id, request_digest = in_.request_digest,
		kind = in_.kind, content_type = in_.content_type, ext = in_.ext, associations = in_.associations == "" ? "{}" : in_.associations,
		vault_id = vid, epoch = i64(epoch),
		created_at = transfer_time(now), touched_at = transfer_time(now), expires_at = transfer_time(now + contracts.ARTIFACT_TRANSFER_ABSOLUTE_TTL_MS),
	}
	if err := s.repo.insert(s.repo.ctx, x); err.code != .None do return {}, "", fail(.Conflict, "conflict")
	return x, token, {}
}

@(private = "file")
replay_begin :: proc(s: ^Transfer_Service, prior: domain.Mcp_Transfer, digest: string) -> (domain.Mcp_Transfer, string, Transfer_Fail) {
	if prior.request_digest != digest do return {}, "", fail(.Conflict, "conflict")
	if domain.mcp_transfer_state_terminal(prior.state) do return prior, "", {}
	token, tdigest, ok := mint_token()
	if !ok do return {}, "", fail(.Internal_Error, "internal")
	if err := s.repo.rotate_token(s.repo.ctx, prior.transfer_id, tdigest, transfer_time(now_ms(s))); err.code != .None do return {}, "", fail(.Internal_Error, "internal")
	p := prior; p.token_sha256 = tdigest
	return p, token, {}
}

// transfer_download_begin binds a download transfer to an owned, sealed artifact's
// stored ciphertext and its SHA-256, computed in bounded windows.
transfer_download_begin :: proc(s: ^Transfer_Service, who: Transfer_Caller, request_id, request_digest, artifact_id: string) -> (domain.Mcp_Transfer, string, Transfer_Fail) {
	if len(request_id) == 0 || len(request_id) > 128 do return {}, "", fail(.Validation_Failed, "invalid_request_id")
	if prior, found, err := s.repo.get_by_request(s.repo.ctx, who.owner, who.client_id, request_id); err.code != .None {
		return {}, "", fail(.Internal_Error, "internal")
	} else if found {
		return replay_begin(s, prior, request_digest)
	}
	if _, _, _, vok := current_vault(s, who.owner, who.grant_id); !vok do return {}, "", fail(.Validation_Failed, "vault_required")
	if !transfer_rate_allow(s, who.grant_id, true) do return {}, "", rate_limited()
	active, _, uerr := s.repo.owner_usage(s.repo.ctx, who.owner, domain.MCP_TRANSFER_DOWNLOAD)
	if uerr.code != .None do return {}, "", fail(.Internal_Error, "internal")
	if active >= contracts.ARTIFACT_TRANSFER_MAX_DOWNLOADS_PER_OWNER {
		f := fail(.Rate_Limited, "quota_exceeded", true); f.retry_after_ms = contracts.ARTIFACT_TRANSFER_RETRY_AFTER_MS
		return {}, "", f
	}
	// Hash + blind-check the stored value window by window: never a full copy.
	h: sha2.Context_256
	sha2.init_256(&h)
	check: vault.Blind_Token_Check
	window := make([]byte, contracts.ARTIFACT_TRANSFER_STORE_CHUNK_BYTES, context.temp_allocator)
	off: i64 = 0
	total: i64 = -1
	for {
		n, tot, found, err := s.repo.read_artifact_window(s.repo.ctx, artifact_id, who.owner, off, window)
		if err.code != .None do return {}, "", fail(.Internal_Error, "internal")
		if !found do return {}, "", fail(.Not_Found, "not_found")
		total = tot
		if n == 0 do break
		sha2.update(&h, window[:n])
		vault.blind_token_check_update(&check, window[:n])
		off += i64(n)
		if off >= total do break
	}
	info, canonical := vault.blind_token_check_finish(&check)
	if total <= 0 || !canonical do return {}, "", fail(.Validation_Failed, "not_encrypted")
	digest: [32]byte
	sha2.final(&h, digest[:])
	token, tdigest, ok := mint_token()
	if !ok do return {}, "", fail(.Internal_Error, "internal")
	now := now_ms(s)
	vbuf: [vault.VAULT_ID_HEX_CHARS]byte
	x := domain.Mcp_Transfer{
		transfer_id = mint_id("xfr_"), owner_user_id = who.owner, client_id = who.client_id, grant_id = who.grant_id, family_id = who.family_id,
		direction = domain.MCP_TRANSFER_DOWNLOAD, state = domain.MCP_TRANSFER_READY, token_sha256 = tdigest, artifact_id = artifact_id,
		request_id = request_id, request_digest = request_digest, kind = "", content_type = "", associations = "{}",
		vault_id = strings.clone(vault.vault_id_hex(info.vault_id, vbuf[:]), context.temp_allocator), epoch = i64(info.epoch),
		received_bytes = total, ciphertext_bytes = total, ciphertext_sha256 = vault.hex_encode_lower(digest[:], context.temp_allocator),
		created_at = transfer_time(now), touched_at = transfer_time(now), expires_at = transfer_time(now + contracts.ARTIFACT_TRANSFER_ABSOLUTE_TTL_MS),
	}
	if err := s.repo.insert(s.repo.ctx, x); err.code != .None do return {}, "", fail(.Conflict, "conflict")
	return x, token, {}
}

// ── Data path authentication ──

// transfer_authenticate resolves a bearer token to its live transfer. Expired rows
// fail closed even before the janitor runs. A grant-liveness check is the caller's.
transfer_authenticate :: proc(s: ^Transfer_Service, token: string, transfer_id: string) -> (domain.Mcp_Transfer, Transfer_Fail) {
	digest := transfer_token_sha256(token)
	if digest == "" do return {}, fail(.Unauthenticated, "unauthenticated")
	x, found, err := s.repo.get_by_token(s.repo.ctx, digest)
	if err.code != .None do return {}, fail(.Internal_Error, "internal")
	// A token for another transfer is indistinguishable from no transfer (404 policy).
	if !found || x.transfer_id != transfer_id do return {}, fail(.Not_Found, "not_found")
	return transfer_live(s, x)
}

// transfer_get_owned resolves a transfer for an authenticated owner session (browser
// executor). Another owner's transfer is Not_Found.
transfer_get_owned :: proc(s: ^Transfer_Service, owner, transfer_id: string) -> (domain.Mcp_Transfer, Transfer_Fail) {
	x, found, err := s.repo.get(s.repo.ctx, transfer_id)
	if err.code != .None do return {}, fail(.Internal_Error, "internal")
	if !found || x.owner_user_id != owner do return {}, fail(.Not_Found, "not_found")
	return transfer_live(s, x)
}

@(private = "file")
transfer_live :: proc(s: ^Transfer_Service, x: domain.Mcp_Transfer) -> (domain.Mcp_Transfer, Transfer_Fail) {
	now := now_ms(s)
	if !domain.mcp_transfer_state_terminal(x.state) {
		idle := transfer_time(now - contracts.ARTIFACT_TRANSFER_IDLE_TTL_MS)
		if x.expires_at <= transfer_time(now) || x.touched_at <= idle {
			s.repo.set_state(s.repo.ctx, x.transfer_id, x.state, domain.MCP_TRANSFER_EXPIRED, "transfer_expired", transfer_time(now))
			return {}, fail(.Gone, "transfer_expired")
		}
	}
	return x, {}
}

// ── Upload data ──

// transfer_append stores one ciphertext piece at offset. The offset must equal
// received_bytes (else conflict with the current offset); the running total may
// never exceed the ciphertext bound or the staging quotas. Pieces larger than the
// store chunk size are split into <= 1 MiB rows.
transfer_append :: proc(s: ^Transfer_Service, x: domain.Mcp_Transfer, offset: i64, bytes: []byte) -> (i64, Transfer_Fail) {
	if x.direction != domain.MCP_TRANSFER_UPLOAD do return 0, fail(.Validation_Failed, "wrong_direction")
	if x.state != domain.MCP_TRANSFER_RECEIVING do return 0, fail(.Conflict, x.state == domain.MCP_TRANSFER_SEALED ? "already_sealed" : x.state)
	if len(bytes) == 0 do return x.received_bytes, fail(.Validation_Failed, "empty_body")
	if offset != x.received_bytes {
		f := fail(.Conflict, "offset_mismatch"); f.offset = x.received_bytes
		return x.received_bytes, f
	}
	end := offset + i64(len(bytes))
	if end > contracts.ARTIFACT_TRANSFER_CIPHERTEXT_MAX_BYTES do return x.received_bytes, reject(s, x, "ciphertext_too_large")
	// Quotas: owner and global staged bytes, checked before writing.
	_, staged, uerr := s.repo.owner_usage(s.repo.ctx, x.owner_user_id, domain.MCP_TRANSFER_UPLOAD)
	if uerr.code != .None do return x.received_bytes, fail(.Internal_Error, "internal")
	global, gerr := s.repo.global_staged_bytes(s.repo.ctx)
	if gerr.code != .None do return x.received_bytes, fail(.Internal_Error, "internal")
	gmax := s.staged_global_max > 0 ? s.staged_global_max : contracts.ARTIFACT_TRANSFER_STAGED_MAX_GLOBAL
	if staged + i64(len(bytes)) > contracts.ARTIFACT_TRANSFER_STAGED_MAX_PER_OWNER || global + i64(len(bytes)) > gmax {
		f := fail(.Rate_Limited, "quota_exceeded", true); f.retry_after_ms = contracts.ARTIFACT_TRANSFER_RETRY_AFTER_MS
		return x.received_bytes, f
	}
	now := now_ms(s)
	pos := offset
	rest := bytes
	for len(rest) > 0 {
		k := min(len(rest), contracts.ARTIFACT_TRANSFER_STORE_CHUNK_BYTES)
		ok, err := s.repo.append_chunk(s.repo.ctx, x.transfer_id, pos, rest[:k], transfer_time(now), x.expires_at)
		if err.code != .None do return pos, fail(.Internal_Error, "internal")
		if !ok {
			cur, _, _ := s.repo.get(s.repo.ctx, x.transfer_id)
			f := fail(.Conflict, "offset_mismatch"); f.offset = cur.received_bytes
			return cur.received_bytes, f
		}
		pos += i64(k)
		rest = rest[k:]
	}
	return pos, {}
}

@(private = "file")
reject :: proc(s: ^Transfer_Service, x: domain.Mcp_Transfer, reason: string) -> Transfer_Fail {
	s.repo.set_state(s.repo.ctx, x.transfer_id, x.state, domain.MCP_TRANSFER_FAILED, reason, transfer_time(now_ms(s)))
	return fail(.Validation_Failed, reason)
}

// ── Seal (§5.4 checks 1-6) ──

Seal_Input :: struct {
	receipt, signature, device_id: string,
	name_token, description_token, attestation_token: string,
}

NAME_TOKEN_PLAINTEXT_MAX :: 16 * 1024
DESCRIPTION_TOKEN_PLAINTEXT_MAX :: 16 * 1024
ATTESTATION_TOKEN_PLAINTEXT_MAX :: 4 * 1024

@(private = "file")
Hash_Check :: struct {
	h: sha2.Context_256,
	check: vault.Blind_Token_Check,
	bytes: i64,
}

@(private = "file")
hash_visit :: proc(user: rawptr, b: []byte) -> bool {
	hc := (^Hash_Check)(user)
	sha2.update(&hc.h, b)
	vault.blind_token_check_update(&hc.check, b)
	hc.bytes += i64(len(b))
	return true
}

@(private = "file")
small_token_ok :: proc(tok: string, vault_id: string, epoch: u32, max_plain: int) -> bool {
	info, ok := vault.blind_token_check_string(tok)
	if !ok || info.epoch != epoch || info.plaintext_bytes > max_plain do return false
	buf: [vault.VAULT_ID_HEX_CHARS]byte
	return vault.vault_id_hex(info.vault_id, buf[:]) == vault_id
}

// staged_check verifies the staged ciphertext (checks 1-4) and the receipt (5-6)
// against the transfer row and the CURRENT verified directory.
@(private = "file")
staged_check :: proc(s: ^Transfer_Service, x: domain.Mcp_Transfer, in_: Seal_Input) -> (ciphertext_sha256: string, f: Transfer_Fail) {
	vid, epoch, dir, vok := current_vault(s, x.owner_user_id, x.grant_id)
	if !vok do return "", fail(.Validation_Failed, "vault_required", true) // transient: lookup/tx failure
	hc: Hash_Check
	sha2.init_256(&hc.h)
	if err := s.repo.visit_chunks(s.repo.ctx, x.transfer_id, &hc, hash_visit); err.code != .None do return "", fail(.Internal_Error, "internal", true)
	info, canonical := vault.blind_token_check_finish(&hc.check)
	if !canonical || hc.bytes != x.received_bytes do return "", fail(.Validation_Failed, "ciphertext_invalid")
	vbuf: [vault.VAULT_ID_HEX_CHARS]byte
	if vault.vault_id_hex(info.vault_id, vbuf[:]) != vid do return "", fail(.Validation_Failed, "ciphertext_invalid")
	if info.epoch != epoch || i64(epoch) != x.epoch do return "", fail(.Validation_Failed, "stale_epoch")
	if info.plaintext_bytes < 1 || info.plaintext_bytes > contracts.ARTIFACT_MAX_CONTENT_BYTES do return "", fail(.Validation_Failed, "ciphertext_invalid")
	digest: [32]byte
	sha2.final(&hc.h, digest[:])
	sum := vault.hex_encode_lower(digest[:], context.temp_allocator)

	r, rok := vault.transfer_seal_receipt_parse(in_.receipt)
	if !rok do return "", fail(.Validation_Failed, "receipt_invalid")
	if r.owner_user_id != x.owner_user_id || r.vault_id != vid || i64(r.epoch) != x.epoch || r.transfer_id != x.transfer_id ||
	   r.artifact_id != x.artifact_id || r.kind != x.kind || r.content_type != x.content_type || r.device_id != in_.device_id {
		return "", fail(.Validation_Failed, "receipt_invalid")
	}
	if r.ciphertext_bytes != x.received_bytes || r.ciphertext_sha256 != sum do return "", fail(.Validation_Failed, "receipt_invalid")
	// issued_ms within the transfer lifetime.
	now := now_ms(s)
	if r.issued_ms > now + 60_000 || r.issued_ms < now - contracts.ARTIFACT_TRANSFER_ABSOLUTE_TTL_MS - 60_000 do return "", fail(.Validation_Failed, "receipt_invalid")
	if !small_token_ok(in_.name_token, vid, epoch, NAME_TOKEN_PLAINTEXT_MAX) || !small_token_ok(in_.attestation_token, vid, epoch, ATTESTATION_TOKEN_PLAINTEXT_MAX) {
		return "", fail(.Validation_Failed, "receipt_invalid")
	}
	if in_.description_token != "" && !small_token_ok(in_.description_token, vid, epoch, DESCRIPTION_TOKEN_PLAINTEXT_MAX) do return "", fail(.Validation_Failed, "receipt_invalid")
	if r.name_token_sha256 != sha_hex(transmute([]byte)in_.name_token) || r.description_token_sha256 != sha_hex(transmute([]byte)in_.description_token) ||
	   r.attestation_token_sha256 != sha_hex(transmute([]byte)in_.attestation_token) {
		return "", fail(.Validation_Failed, "receipt_invalid")
	}
	if vault.transfer_receipt_verify(dir, in_.device_id, in_.receipt, in_.signature) != .None do return "", fail(.Validation_Failed, "receipt_invalid")
	return sum, {}
}

// transfer_seal runs the blind checks and moves receiving -> sealed. A duplicate seal
// with the identical receipt is idempotent; a different receipt after sealed is a
// conflict. A definitive check failure fails the transfer and wipes staging; a
// retryable one (transient lookup/read error) leaves it receiving.
transfer_seal :: proc(s: ^Transfer_Service, x: domain.Mcp_Transfer, in_: Seal_Input) -> (domain.Mcp_Transfer, Transfer_Fail) {
	if x.direction != domain.MCP_TRANSFER_UPLOAD do return {}, fail(.Validation_Failed, "wrong_direction")
	if x.state == domain.MCP_TRANSFER_SEALED {
		if x.seal_statement == in_.receipt && x.seal_signature == in_.signature do return x, {}
		return {}, fail(.Conflict, "conflict")
	}
	if x.state != domain.MCP_TRANSFER_RECEIVING do return {}, fail(.Conflict, x.state)
	if x.received_bytes == 0 do return {}, fail(.Validation_Failed, "not_received", true)
	sum, f := staged_check(s, x, in_)
	if !transfer_ok(f) {
		// Retryable failures (directory lookup, chunk read) never change durable
		// state (§5.1/§9); only a definitive blind-check failure fails the transfer.
		if f.retryable do return {}, f
		reason := f.reason
		s.repo.set_state(s.repo.ctx, x.transfer_id, domain.MCP_TRANSFER_RECEIVING, domain.MCP_TRANSFER_FAILED, reason, transfer_time(now_ms(s)))
		return {}, f
	}
	y := x
	y.state = domain.MCP_TRANSFER_SEALED; y.ciphertext_sha256 = sum; y.ciphertext_bytes = x.received_bytes
	y.seal_statement = in_.receipt; y.seal_signature = in_.signature; y.seal_device_id = in_.device_id
	y.name_token = in_.name_token; y.description_token = in_.description_token; y.attestation_token = in_.attestation_token
	y.touched_at = transfer_time(now_ms(s))
	ok, err := s.repo.mark_sealed(s.repo.ctx, y)
	if err.code != .None do return {}, fail(.Internal_Error, "internal")
	if !ok do return {}, fail(.Conflict, "conflict")
	return y, {}
}

// ── Commit (§5.4 check 7) ──

// transfer_commit re-runs the blind checks against the CURRENT directory (an epoch
// rotation or a device revocation since seal fails it), then atomically creates the
// artifact with the reserved id and the staged ciphertext as content. The caller
// performs grant/family liveness and association re-checks first.
transfer_commit :: proc(s: ^Transfer_Service, who: Transfer_Caller, transfer_id: string, associations: domain.Artifact) -> (domain.Mcp_Transfer, Transfer_Fail) {
	x, found, err := s.repo.get(s.repo.ctx, transfer_id)
	if err.code != .None do return {}, fail(.Internal_Error, "internal")
	if !found || x.owner_user_id != who.owner || x.client_id != who.client_id || x.direction != domain.MCP_TRANSFER_UPLOAD do return {}, fail(.Not_Found, "not_found")
	switch x.state {
	case domain.MCP_TRANSFER_COMMITTED:
		return x, {}
	case domain.MCP_TRANSFER_RECEIVING:
		f := fail(.Conflict, "not_sealed", true); f.offset = x.received_bytes
		return x, f
	case domain.MCP_TRANSFER_CANCELLED:
		return x, fail(.Gone, "cancelled")
	case domain.MCP_TRANSFER_EXPIRED:
		return x, fail(.Gone, "transfer_expired")
	case domain.MCP_TRANSFER_FAILED:
		return x, fail(.Validation_Failed, x.error == "" ? "failed" : x.error)
	}
	if live, lf := transfer_live(s, x); !transfer_ok(lf) do return live, lf
	if !commit_acquire(s) do return x, busy()
	defer sync.atomic_sub(&s.commits_in_flight, 1)
	if _, f := staged_check(s, x, Seal_Input{receipt = x.seal_statement, signature = x.seal_signature, device_id = x.seal_device_id,
		name_token = x.name_token, description_token = x.description_token, attestation_token = x.attestation_token}); !transfer_ok(f) {
		if f.retryable do return x, f
		s.repo.set_state(s.repo.ctx, x.transfer_id, domain.MCP_TRANSFER_SEALED, domain.MCP_TRANSFER_FAILED, f.reason, transfer_time(now_ms(s)))
		return x, f
	}
	now := transfer_time(now_ms(s))
	a := associations
	a.artifact_id = x.artifact_id; a.owner_user_id = domain.User_ID(x.owner_user_id); a.kind = x.kind
	a.name = x.name_token; a.description = x.description_token; a.content_type = x.content_type; a.mime = x.content_type
	a.ext = x.ext; a.size_bytes = int(x.ciphertext_bytes); a.content = ""; a.blob_ref = ""
	a.sha256 = "" // never a plaintext digest in clear (§5.4.7)
	a.origin_kind = "mcp_transfer"; a.origin_ref = x.transfer_id; a.created_at = now; a.updated_at = now
	ok, cerr := s.repo.commit(s.repo.ctx, x.transfer_id, domain.Mcp_Transfer_Commit{artifact = a, receipt_created_at = now})
	if cerr.code == .Conflict do return x, fail(.Conflict, "conflict")
	if cerr.code != .None do return x, fail(.Internal_Error, "internal")
	y, _, _ := s.repo.get(s.repo.ctx, x.transfer_id)
	if !ok && y.state != domain.MCP_TRANSFER_COMMITTED do return y, fail(.Conflict, "conflict")
	return y, {}
}

// ── Download data ──

// transfer_fetch_begin counts one GET against max_fetches and confirms the artifact
// still holds exactly the bound ciphertext (deleted -> Gone).
transfer_fetch_begin :: proc(s: ^Transfer_Service, x: domain.Mcp_Transfer) -> Transfer_Fail {
	if x.direction != domain.MCP_TRANSFER_DOWNLOAD do return fail(.Validation_Failed, "wrong_direction")
	if x.state != domain.MCP_TRANSFER_READY && x.state != domain.MCP_TRANSFER_DELIVERED do return fail(.Gone, x.state)
	one: [1]byte
	_, total, found, err := s.repo.read_artifact_window(s.repo.ctx, x.artifact_id, x.owner_user_id, 0, one[:])
	if err.code != .None do return fail(.Internal_Error, "internal")
	if !found || total != x.ciphertext_bytes {
		s.repo.set_state(s.repo.ctx, x.transfer_id, x.state, domain.MCP_TRANSFER_FAILED, "artifact_gone", transfer_time(now_ms(s)))
		return fail(.Gone, "artifact_gone")
	}
	ok, cerr := s.repo.count_fetch(s.repo.ctx, x.transfer_id, contracts.ARTIFACT_TRANSFER_MAX_FETCHES, transfer_time(now_ms(s)))
	if cerr.code != .None do return fail(.Internal_Error, "internal")
	if !ok do return fail(.Rate_Limited, "max_fetches")
	return {}
}

// transfer_read_window copies one <= 1 MiB window of the bound stored ciphertext.
transfer_read_window :: proc(s: ^Transfer_Service, x: domain.Mcp_Transfer, offset: i64, dst: []byte) -> (int, Transfer_Fail) {
	n, total, found, err := s.repo.read_artifact_window(s.repo.ctx, x.artifact_id, x.owner_user_id, offset, dst[:min(len(dst), contracts.ARTIFACT_TRANSFER_STORE_CHUNK_BYTES)])
	if err.code != .None do return 0, fail(.Internal_Error, "internal")
	if !found || total != x.ciphertext_bytes do return 0, fail(.Gone, "artifact_gone")
	return n, {}
}

// transfer_opened records a signed open receipt (§6.3). verified is taken ONLY from
// the signed statement.
transfer_opened :: proc(s: ^Transfer_Service, x: domain.Mcp_Transfer, statement, signature, device_id: string) -> (domain.Mcp_Transfer, Transfer_Fail) {
	if x.direction != domain.MCP_TRANSFER_DOWNLOAD do return {}, fail(.Validation_Failed, "wrong_direction")
	if x.state == domain.MCP_TRANSFER_DELIVERED && x.open_statement == statement && x.open_signature == signature do return x, {}
	if x.state != domain.MCP_TRANSFER_READY do return {}, fail(.Conflict, x.state)
	r, ok := vault.transfer_open_receipt_parse(statement)
	if !ok do return {}, fail(.Validation_Failed, "receipt_invalid")
	vid, _, dir, vok := current_vault(s, x.owner_user_id, x.grant_id)
	if !vok do return {}, fail(.Validation_Failed, "vault_required")
	if r.owner_user_id != x.owner_user_id || r.vault_id != vid || r.vault_id != x.vault_id || i64(r.epoch) != x.epoch ||
	   r.transfer_id != x.transfer_id || r.artifact_id != x.artifact_id || r.device_id != device_id ||
	   r.ciphertext_bytes != x.ciphertext_bytes || r.ciphertext_sha256 != x.ciphertext_sha256 {
		return {}, fail(.Validation_Failed, "receipt_invalid")
	}
	if vault.transfer_receipt_verify(dir, device_id, statement, signature) != .None do return {}, fail(.Validation_Failed, "receipt_invalid")
	y := x
	y.state = domain.MCP_TRANSFER_DELIVERED; y.open_statement = statement; y.open_signature = signature; y.open_device_id = device_id
	y.open_verified = r.verified; y.touched_at = transfer_time(now_ms(s))
	done, err := s.repo.mark_opened(s.repo.ctx, y)
	if err.code != .None do return {}, fail(.Internal_Error, "internal")
	if !done do return {}, fail(.Conflict, "conflict")
	return y, {}
}

// transfer_cancel is idempotent and wipes staging in the same transaction.
transfer_cancel :: proc(s: ^Transfer_Service, x: domain.Mcp_Transfer) -> (domain.Mcp_Transfer, Transfer_Fail) {
	if x.state == domain.MCP_TRANSFER_CANCELLED do return x, {}
	if x.state == domain.MCP_TRANSFER_COMMITTED do return x, fail(.Conflict, "committed")
	if domain.mcp_transfer_state_terminal(x.state) do return x, {}
	ok, err := s.repo.set_state(s.repo.ctx, x.transfer_id, x.state, domain.MCP_TRANSFER_CANCELLED, "", transfer_time(now_ms(s)))
	if err.code != .None do return x, fail(.Internal_Error, "internal")
	y, _, _ := s.repo.get(s.repo.ctx, x.transfer_id)
	if !ok && y.state != domain.MCP_TRANSFER_CANCELLED do return y, fail(.Conflict, y.state)
	return y, {}
}

// transfer_janitor expires idle/absolute-TTL rows (wiping their chunks) and purges
// terminal rows after 24 h. Run at startup and at least every 60 s.
transfer_janitor :: proc(s: ^Transfer_Service) -> (expired, purged: int) {
	now := now_ms(s)
	expired, _ = s.repo.expire(s.repo.ctx, transfer_time(now), transfer_time(now - contracts.ARTIFACT_TRANSFER_IDLE_TTL_MS))
	purged, _ = s.repo.purge(s.repo.ctx, transfer_time(now - contracts.ARTIFACT_TRANSFER_TERMINAL_KEEP_MS))
	return
}

// transfer_revoke_grant fails every non-terminal transfer of a revoked grant and
// wipes its staging (§9 Revocation).
transfer_fail_for_revocation :: proc(s: ^Transfer_Service, x: domain.Mcp_Transfer) {
	if domain.mcp_transfer_state_terminal(x.state) do return
	s.repo.set_state(s.repo.ctx, x.transfer_id, x.state, domain.MCP_TRANSFER_FAILED, "revoked", transfer_time(now_ms(s)))
}
