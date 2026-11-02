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

import "core:fmt"
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
	// The old device's socket is retired whatever happens to the row below: its
	// credential died inside the commit transaction.
	if attach do _ = close_bridge_connection(service, bridge.bridge_id)
	saved, save_ok, save_err := iface.bridge_save_bridge(service.repo, bridge)
	if !save_ok {
		// COMMITTED regardless. The credential swap is durable; only the row's
		// descriptive fields (machine facts, updated_at) are stale. Reporting a
		// failure here would tell the bridge to discard a credential the hub has
		// made live — the enrolled-without-credential state REQ-EA exists to
		// prevent. So the verdict stays committed, and the error is logged.
		fmt.eprintfln("hub: bridge %s enrollment committed, but its row's descriptive fields could not be saved: %s", bridge.bridge_id, save_err.message)
		return bridge, true, domain.Domain_Error{}
	}
	return saved, true, domain.Domain_Error{} // save returns the same value it was given
}

// rollback_pending_enrollment undoes a pending enrollment (REQ-EA-3): the family is
// revoked, then a new bridge's row is hard-deleted. delete_pending only matches a
// row that is still pending, so an attach target — or a bridge committed a moment
// ago — is never removed by this path. Idempotent: rolling back twice is harmless.
//
// `rolled_back` is the VERDICT, and callers must gate on it: only when it is true may
// they tell the enrolling process committed:false, close its socket, or report a
// rollback. It is false exactly when a commit won the write lock first and promoted
// the family — the bridge is enrolled, and a committed:false sent now could reach the
// process before the commit's committed:true and make it discard a credential the
// hub already treats as live.
//
// A new bridge that sunset another (REQ-3, "register new and sunset one") carries a
// durable receipt; the row delete here is delete_pending_restoring_sunset, which gives
// that bridge back in the SAME transaction. Every rollback path (the approval's own
// vault-commit failure, cancel / the bridge's committed:false, both sweep sources)
// comes through here, so none of them can leave the owner with neither bridge.
// A caller whose INTENT is to kill credentials (vault reset's revoke-all, a vault
// device's bridge revocation) passes .Keep_Revoked: reviving a bridge there would
// undo the very revocation it was asked for.
Sunset_On_Rollback :: enum {
	Restore,
	Keep_Revoked,
}

rollback_pending_enrollment :: proc(service: ^Bridge_Service, bridge_id, family_id: string, sunset := Sunset_On_Rollback.Restore) -> (rolled_back: bool, row_deleted: bool, err: domain.Domain_Error) {
	if service == nil || service.repo == nil do return false, false, domain.domain_error(.Internal_Error, "bridge service is not configured")
	if bridge_id == "" do return false, false, domain.domain_error(.Validation_Failed, "bridge_id is required")
	now := platform.clock_now(service.clock)
	committed := false
	if family_id != "" {
		// Only a family still in the enroll scope is ours to revoke; a committed one
		// was promoted and is the bridge's real credential now. The scope test is
		// inside the revoke statement itself: a read-then-revoke would race a commit
		// landing in between and revoke the credential it had just made live.
		changed, revoke_ok, revoke_err := iface.bridge_revoke_token_family_in_scope(service.repo, family_id, BRIDGE_ENROLL_TOKEN_SCOPE, now)
		if !revoke_ok do return false, false, revoke_err
		// Nothing left to revoke: either an earlier rollback did it (still rolled
		// back), or a commit promoted the family. Only the latter has live
		// runtime-scope rows, and the promote is final, so this read cannot race.
		// A failed read is NOT "not committed": guessing rolled back here would
		// recreate the committed-without-credential race, so the caller gets the error
		// and must send nothing.
		if changed == 0 {
			has_runtime, read_err := family_has_live_scope(service, family_id, BRIDGE_TOKEN_SCOPE)
			if read_err.code != .None do return false, false, read_err
			committed = has_runtime
		}
	}
	if committed do return false, false, domain.Domain_Error{}
	removed, del_err := delete_pending_restoring_sunset(service, bridge_id, sunset)
	if del_err.code != .None do return false, removed, del_err
	// With no family to judge by, the deleted row is the only evidence of a rollback.
	return family_id != "" || removed, removed, domain.Domain_Error{}
}

// delete_pending_restoring_sunset hard-deletes a still-pending new bridge and, if its
// approval sunset another bridge, restores that bridge in the same transaction
// (iface.Bridge_Delete_Pending_Restoring_Sunset_Proc). The plan cap for the restore
// comes from the replacement's owner (the sunset bridge has the same owner: admission
// checked it). FAIL CLOSED: when the owner or their plan cannot be read, the row is
// still deleted but the sunset bridge stays revoked -- reviving it unchecked could
// put the owner over their plan. A declined restore is not an error to the caller (the
// enrollment is rolled back either way), but it is logged: the owner lost a bridge
// they did not finally give up.
delete_pending_restoring_sunset :: proc(service: ^Bridge_Service, bridge_id: string, sunset := Sunset_On_Rollback.Restore) -> (removed: bool, err: domain.Domain_Error) {
	max_bridges := -1
	restore_allowed := false
	replacement, found, _ := iface.bridge_get_bridge(service.repo, bridge_id)
	if found {
		if sunset == .Restore {
			entitlements, ent_err := domain.lookup_entitlements(service.entitlements, string(replacement.owner_user_id))
			if ent_err.code == .None {
				max_bridges = entitlements.max_bridges
				restore_allowed = true
			}
		}
		domain.bridge_destroy(&replacement)
	}
	outcome, del_err := iface.bridge_delete_pending_restoring_sunset(service.repo, bridge_id, max_bridges, restore_allowed, platform.clock_now(service.clock))
	if del_err.code != .None do return false, del_err
	if outcome.had_sunset && !outcome.restored && sunset == .Restore {
		fmt.eprintfln("hub: pending bridge %s rolled back; the bridge it sunset stays revoked (replacement committed, sunset row changed since, plan full, or plan unreadable)", bridge_id)
	}
	return outcome.replacement_deleted, domain.Domain_Error{}
}

@(private = "file")
family_has_live_scope :: proc(service: ^Bridge_Service, family_id, scope: string) -> (bool, domain.Domain_Error) {
	tokens, err := iface.bridge_list_tokens_by_family(service.repo, family_id)
	defer free_bridge_tokens(tokens)
	if err.code != .None do return false, err
	for t in tokens do if t.scope == scope && t.revoked_at == "" do return true, domain.Domain_Error{}
	return false, domain.Domain_Error{}
}

// cancel_pending_enrollment is the operator's cancel (REQ-EA-3): find the bridge's
// live enroll-scoped family, then roll back. A failed family lookup returns the error
// with NOTHING done — rolling back with no family would delete a new bridge's row
// while its enroll token stays live, or call a still-pending attach committed.
//
// `sunset`: see rollback_pending_enrollment. The operator's own cancel restores a
// bridge this enrollment sunset; revoke-everything callers pass .Keep_Revoked.
cancel_pending_enrollment :: proc(service: ^Bridge_Service, bridge_id: string, sunset := Sunset_On_Rollback.Restore) -> (rolled_back: bool, row_deleted: bool, err: domain.Domain_Error) {
	family, _, lookup_err := pending_enrollment_family(service, bridge_id)
	defer delete(family)
	if lookup_err.code != .None do return false, false, lookup_err
	return rollback_pending_enrollment(service, bridge_id, family, sunset)
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
		rolled_back, removed, _ := rollback_pending_enrollment(service, t.bridge_id, t.family_id)
		// A commit that landed after the listing above wins: no rollback to report.
		if !rolled_back {
			delete(owner)
			continue
		}
		append(&out, Rolled_Back_Enrollment{bridge_id = strings.clone(t.bridge_id), owner_user_id = owner, row_deleted = removed})
	}
	free_bridge_tokens(tokens)

	rows, _ := iface.bridge_list_pending(service.repo)
	for b in rows {
		until_ms, until_ok := platform.rfc3339_to_unix_ms(b.enrollment_pending_until)
		if until_ok && now_ms < until_ms do continue
		_, removed, _ := rollback_pending_enrollment(service, b.bridge_id, "")
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
pending_enrollment_family :: proc(service: ^Bridge_Service, bridge_id: string) -> (string, bool, domain.Domain_Error) {
	if service == nil || service.repo == nil do return "", false, domain.domain_error(.Internal_Error, "bridge service is not configured")
	if bridge_id == "" do return "", false, domain.Domain_Error{}
	tokens, err := iface.bridge_list_live_tokens_by_scope(service.repo, BRIDGE_ENROLL_TOKEN_SCOPE)
	defer free_bridge_tokens(tokens)
	if err.code != .None do return "", false, err
	newest := ""
	newest_family := ""
	for t in tokens {
		if t.bridge_id != bridge_id do continue
		if newest_family == "" || t.issued_at > newest {
			newest = t.issued_at
			newest_family = t.family_id
		}
	}
	if newest_family == "" do return "", false, domain.Domain_Error{}
	return strings.clone(newest_family), true, domain.Domain_Error{}
}
