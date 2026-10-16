// Atomic enrollment: a bridge is enrolled only once its vault key is delivered
// (REQ-EA, plan task_18df06006e581bed).
//
// Approval of a bridge grant whose owner has a vault does not enroll the bridge. It
// mints a PENDING credential — a token family in BRIDGE_ENROLL_TOKEN_SCOPE, which
// authenticates only the enroll-only WebSocket the vault key travels over — and, for
// a new bridge, a row marked enrollment_pending_until. Exactly two things can happen
// to that state:
//
//   COMMIT   (commit_pending_enrollment). The hub relays the browser's unseal to the
//            enroll-only socket and the bridge answers ok:true, which it does only
//            after the key is stored, read back and the credential persisted. The
//            hub observes that answer itself; it is not a self-report (contrast
//            domain.Bridge.vault_status). The family is promoted to
//            BRIDGE_TOKEN_SCOPE and the bridge becomes enrolled.
//   ROLLBACK (rollback_pending_enrollment). The deadline passes, or the operator
//            cancels. The family is revoked and a new bridge's row is HARD-deleted,
//            so a failed enrollment leaves no bridge behind. An attach leaves its
//            target untouched, because nothing about it was changed at approval.
//
// The sweep (sweep_expired_enrollments) is what makes ROLLBACK unconditional: it runs
// on the reaper's timer and once at startup, so a hub or bridge that dies mid-flow
// still converges to "never enrolled".

package bridge

import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// Pending_Commit_Input carries what the hub observed on the enroll-only connection.
// Only an ATTACH uses it: the swap rewrites the target row's machine fields and its
// recorded key from the new device, which a new bridge already got at approval.
Pending_Commit_Input :: struct {
	bridge_id:              string,
	family_id:              string,
	machine_hostname:       string,
	machine_os:             string,
	bridge_version:         string,
	bridge_public_key:      string,
	bridge_key_fingerprint: string,
}

// commit_pending_enrollment makes a pending enrollment real (REQ-EA-2).
//
// THE COMMIT IS ONE TRANSACTION (iface.bridge_commit_enrollment): the family is
// promoted as a compare-and-set on its scope, and in the same transaction an
// attach revokes the old device's families, or a new bridge's pending deadline is
// cleared. So a rolled-back enrollment is never resurrected by a late answer, and no
// failure leaves two live credentials or a live credential on a row the sweep would
// delete. A duplicate answer for an already-committed family is an idempotent
// success. Only then is the row's descriptive state refreshed and, for an attach,
// the old device's socket kicked: by then nothing can authenticate as it.
commit_pending_enrollment :: proc(service: ^Bridge_Service, input: Pending_Commit_Input) -> (domain.Bridge, bool, domain.Domain_Error) {
	if service == nil || service.repo == nil do return domain.Bridge{}, false, domain.domain_error(.Internal_Error, "bridge service is not configured")
	if input.bridge_id == "" || input.family_id == "" do return domain.Bridge{}, false, domain.domain_error(.Validation_Failed, "bridge_id and family_id are required")
	bridge, ok, err := iface.bridge_get_bridge(service.repo, input.bridge_id)
	if !ok do return domain.Bridge{}, false, err
	if bridge.status == .Revoked {
		domain.bridge_destroy(&bridge)
		return domain.Bridge{}, false, domain.domain_error(.Bridge_Revoked, "bridge is revoked")
	}
	now := platform.clock_now(service.clock)
	attach := !domain.bridge_is_pending(bridge)
	outcome, commit_ok, commit_err := iface.bridge_commit_enrollment(service.repo, bridge.bridge_id, input.family_id, BRIDGE_ENROLL_TOKEN_SCOPE, BRIDGE_TOKEN_SCOPE, attach, now)
	if !commit_ok {
		domain.bridge_destroy(&bridge)
		return domain.Bridge{}, false, commit_err
	}
	switch outcome {
	case .Not_Pending:
		domain.bridge_destroy(&bridge)
		return domain.Bridge{}, false, domain.domain_error(.Conflict, "the enrollment is no longer pending; it was rolled back")
	case .Already_Committed:
		// A duplicate ok:true (a retried relay) for an enrollment that is already
		// committed. Idempotent success: answering a failure here would tell the
		// bridge to undo a committed enrollment.
		return bridge, true, domain.Domain_Error{}
	case .Committed:
	}
	// The credential swap above is the commit. What follows only refreshes the row's
	// descriptive fields; it cannot un-commit, and its failure is reported, not undone.
	if attach {
		if h := strings.trim_space(input.machine_hostname); h != "" {
			delete(bridge.machine_hostname)
			bridge.machine_hostname = strings.clone(h)
		}
		if input.machine_os != "" {
			delete(bridge.machine_os)
			bridge.machine_os = strings.clone(input.machine_os)
		}
		if input.bridge_version != "" {
			delete(bridge.version)
			bridge.version = strings.clone(input.bridge_version)
		}
		if input.bridge_public_key != "" {
			delete(bridge.capabilities_json)
			bridge.capabilities_json = device_enroll_capabilities_json(Device_Enroll_Input{
				bridge_public_key = input.bridge_public_key,
				bridge_key_fingerprint = input.bridge_key_fingerprint,
			})
		}
		bridge.status = .Offline
	} else {
		delete(bridge.enrollment_pending_until)
		bridge.enrollment_pending_until = ""
	}
	delete(bridge.updated_at)
	bridge.updated_at = strings.clone(now)
	saved, save_ok, save_err := iface.bridge_save_bridge(service.repo, bridge)
	if !save_ok {
		domain.bridge_destroy(&bridge)
		return domain.Bridge{}, false, save_err
	}
	if attach do _ = close_bridge_connection(service, saved.bridge_id)
	return saved, true, domain.Domain_Error{}
}

// rollback_pending_enrollment undoes a pending enrollment (REQ-EA-3): the family is
// revoked, then a new bridge's row is hard-deleted. delete_pending only matches a
// row that is still pending, so an attach target — or a bridge committed a moment
// ago — is never removed by this path. Idempotent: rolling back twice is harmless.
// Returns whether a row was deleted.
rollback_pending_enrollment :: proc(service: ^Bridge_Service, bridge_id, family_id: string) -> (bool, domain.Domain_Error) {
	if service == nil || service.repo == nil do return false, domain.domain_error(.Internal_Error, "bridge service is not configured")
	if bridge_id == "" do return false, domain.domain_error(.Validation_Failed, "bridge_id is required")
	now := platform.clock_now(service.clock)
	if family_id != "" {
		// Only a family still in the enroll scope is ours to revoke. A committed one
		// was promoted and is the bridge's real credential now.
		family, _ := iface.bridge_list_tokens_by_family(service.repo, family_id)
		still_pending := false
		for t in family {
			if t.scope == BRIDGE_ENROLL_TOKEN_SCOPE && t.revoked_at == "" do still_pending = true
		}
		free_bridge_tokens(family)
		if still_pending do _, _, _ = revoke_token_family(service, family_id, now)
	}
	removed, err := iface.bridge_delete_pending(service.repo, bridge_id)
	return removed, err
}

// Rolled_Back_Enrollment names one enrollment the sweep undid, so the caller can
// close any enroll-only socket still open for it and tell the UI.
Rolled_Back_Enrollment :: struct {
	bridge_id:     string,
	owner_user_id: string,
	row_deleted:   bool,
}

// pending_owner_clone reads a bridge's owner and frees the row. The sweep runs on the
// reaper thread, which has no per-request arena, so bridge_owner_user_id — which
// leaks the rest of the row — is not usable there.
@(private = "file")
pending_owner_clone :: proc(service: ^Bridge_Service, bridge_id: string) -> string {
	bridge, ok, _ := iface.bridge_get_bridge(service.repo, bridge_id)
	if !ok do return strings.clone("")
	defer domain.bridge_destroy(&bridge)
	return strings.clone(string(bridge.owner_user_id))
}

// sweep_expired_enrollments rolls back every pending enrollment past its deadline
// (REQ-EA-3). Two sources, because either half of a pending enrollment can exist
// without the other after a crash:
//
//   - live BRIDGE_ENROLL_TOKEN_SCOPE families issued more than
//     BRIDGE_ENROLL_PENDING_SECONDS ago (covers attach, which has no pending row);
//   - pending rows whose enrollment_pending_until has passed (covers a row whose
//     credential was never minted).
//
// A timestamp that does not parse is treated as EXPIRED, not as never-expiring: the
// fail-safe direction for a pending credential is to revoke it.
//
// The returned slice and its strings are allocated with context.allocator; free with
// rolled_back_enrollments_destroy. Everything else it allocates is freed before it
// returns: it runs on the reaper thread, which has no per-request arena. `now` is
// clock_now's temp-arena string and is deliberately never freed.
sweep_expired_enrollments :: proc(service: ^Bridge_Service) -> []Rolled_Back_Enrollment {
	if service == nil || service.repo == nil do return nil
	now := platform.clock_now(service.clock)
	now_ms, now_ok := platform.rfc3339_to_unix_ms(now)
	if !now_ok do return nil
	out := make([dynamic]Rolled_Back_Enrollment)
	seen := make(map[string]bool)
	defer {
		for k in seen do delete(k)
		delete(seen)
	}

	tokens, _ := iface.bridge_list_live_tokens_by_scope(service.repo, BRIDGE_ENROLL_TOKEN_SCOPE)
	for t in tokens {
		if t.family_id in seen do continue
		issued_ms, issued_ok := platform.rfc3339_to_unix_ms(t.issued_at)
		if issued_ok && now_ms - issued_ms < i64(BRIDGE_ENROLL_PENDING_SECONDS) * 1000 do continue
		seen[strings.clone(t.family_id)] = true
		owner := pending_owner_clone(service, t.bridge_id)
		removed, _ := rollback_pending_enrollment(service, t.bridge_id, t.family_id)
		append(&out, Rolled_Back_Enrollment{bridge_id = strings.clone(t.bridge_id), owner_user_id = owner, row_deleted = removed})
	}
	free_bridge_tokens(tokens)

	rows, _ := iface.bridge_list_pending(service.repo)
	for b in rows {
		until_ms, until_ok := platform.rfc3339_to_unix_ms(b.enrollment_pending_until)
		if until_ok && now_ms < until_ms do continue
		removed, _ := rollback_pending_enrollment(service, b.bridge_id, "")
		if !removed do continue
		append(&out, Rolled_Back_Enrollment{bridge_id = strings.clone(b.bridge_id), owner_user_id = strings.clone(string(b.owner_user_id)), row_deleted = true})
	}
	for &b in rows do domain.bridge_destroy(&b)
	delete(rows)
	return out[:]
}

rolled_back_enrollments_destroy :: proc(items: []Rolled_Back_Enrollment) {
	for it in items {
		delete(it.bridge_id)
		delete(it.owner_user_id)
	}
	delete(items)
}

// pending_enrollment_family returns the live enroll-scoped family for a bridge, if
// any: the lineage an unseal commit would promote. An attach target and its new
// device share a bridge_id, so this is how the commit finds the NEW family without
// trusting anything the browser sent.
pending_enrollment_family :: proc(service: ^Bridge_Service, bridge_id: string) -> (string, bool) {
	if service == nil || service.repo == nil || bridge_id == "" do return "", false
	tokens, _ := iface.bridge_list_live_tokens_by_scope(service.repo, BRIDGE_ENROLL_TOKEN_SCOPE)
	defer free_bridge_tokens(tokens)
	newest := ""
	newest_family := ""
	for t in tokens {
		if t.bridge_id != bridge_id do continue
		if newest_family == "" || t.issued_at > newest {
			newest = t.issued_at
			newest_family = t.family_id
		}
	}
	if newest_family == "" do return "", false
	return strings.clone(newest_family), true
}
