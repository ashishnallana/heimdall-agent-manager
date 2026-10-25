// Tests for the expiring bridge credential: expiry enforcement, single-use
// rotation, reuse-as-theft family revocation, the crash-recovery grace window, the
// absolute family cap, kind confusion, and per-bridge isolation (REQ-IMPL-3).
//
// WHY A REAL SQLITE REPOSITORY AND NOT AN IN-MEMORY FAKE. Two of the properties
// under test are enforced IN SQL, not in this package: single-use rotation is the
// `AND rotated_at = ''` in bridge_mark_token_rotated_sqlite (so two concurrent
// refreshes of one token produce exactly one winner), and family revocation is one
// UPDATE across a lineage. A hand-written fake would satisfy the service's calls and
// quietly re-implement neither, which is how a test ends up asserting the mock.
//
// WHY A FAKE CLOCK. "An expired access token is rejected" is only provable
// deterministically if the test can stand on both sides of the boundary. The clock
// is a seam (platform.Clock) and every expiry on this path is derived from
// clock_now via platform.expires_at_after_seconds_from, so moving the fake forward
// an hour genuinely ages a credential — no sleeping, and no wall-clock flake.
package bridge

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

@(private = "file")
token_test_counter: int = 0

// Fake_Clock advances only when a test tells it to. The value is a unix-seconds
// offset applied to a fixed base, formatted exactly as platform.format_rfc3339_utc
// does, so the strings this hands out are indistinguishable from production ones —
// including being lexically ordered, which every expiry comparison relies on.
@(private = "file")
Fake_Clock :: struct {
	unix_seconds: i64,
}

@(private = "file")
fake_clock_now :: proc(ctx: rawptr) -> string {
	c := (^Fake_Clock)(ctx)
	return platform.format_rfc3339_utc(time.Time{_nsec = c.unix_seconds * 1_000_000_000})
}

@(private = "file")
Token_Fixture :: struct {
	db_path: string,
	conn:    sqlite.Conn,
	impl:    sqlite.Bridge_Repo_SQLite,
	repo:    iface.Bridge_Repository,
	clock:   platform.Clock,
	fake:    Fake_Clock,
	ids:     platform.ID_Generator,
	svc:     Bridge_Service,
	// closed_bridge_ids records what the connection-closer seam was asked to tear
	// down, so a service-level test can assert revocation reaches it. The REAL
	// socket teardown is proven on a real socket in
	// src/hub/transport/http/bridge_revocation_ws_test.odin — this records intent,
	// and that test is what proves effect. Both exist on purpose: F6 is the bug
	// where the intent was right and the effect was missing.
	closed_bridge_ids: [dynamic]string,
}

@(private = "file")
fixture_closer :: proc(ctx: rawptr, bridge_id: string) -> bool {
	f := (^Token_Fixture)(ctx)
	append(&f.closed_bridge_ids, strings.clone(bridge_id))
	return true
}

@(private = "file")
setup_token_fixture :: proc(t: ^testing.T, tag: string) -> ^Token_Fixture {
	f := new(Token_Fixture)
	seq := sync.atomic_add(&token_test_counter, 1)
	f.db_path = fmt.tprintf("/tmp/test_bridge_tokens_%s_%d_%d_%d.db", tag, os.get_pid(), time.now()._nsec, seq)
	os.remove(f.db_path)
	conn, open_ok, _ := sqlite.open(f.db_path)
	testing.expect(t, open_ok, "sqlite open ok")
	f.conn = conn
	mig_ok, mig_err := sqlite.run_migrations(&f.conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)
	f.repo = sqlite.new_bridge_repository(&f.impl, &f.conn)
	// 2026-01-01T00:00:00Z, chosen only for being a round readable number.
	f.fake = Fake_Clock{unix_seconds = 1767225600}
	f.clock = platform.Clock{ctx = rawptr(&f.fake), now = fake_clock_now}
	f.ids = platform.real_id_generator()
	f.svc = new_bridge_service(&f.repo, &f.clock, &f.ids)
	f.closed_bridge_ids = make([dynamic]string)
	with_connection_closer(&f.svc, Bridge_Connection_Closer{ctx = rawptr(f), close_bridge_connection = fixture_closer})
	return f
}

@(private = "file")
teardown_token_fixture :: proc(f: ^Token_Fixture) {
	if f == nil do return
	sqlite.close(&f.conn)
	os.remove(f.db_path)
	for s in f.closed_bridge_ids do delete(s)
	delete(f.closed_bridge_ids)
	free(f)
}

@(private = "file")
advance :: proc(f: ^Token_Fixture, seconds: i64) {
	f.fake.unix_seconds += seconds
}

// enrol_one enrols a bridge through the device-grant path and returns its pair.
@(private = "file")
enrol_one :: proc(t: ^testing.T, f: ^Token_Fixture, hostname: string) -> Enroll_Bridge_Result {
	result, ok, err := enroll_bridge_from_device_grant(&f.svc, Device_Enroll_Input{
		owner_user_id = "approving-human",
		bridge_public_key = "04aabbccdd",
		bridge_key_fingerprint = "aaaa bbbb cccc dddd",
		os_user = "tanmay",
		machine_hostname = hostname,
		machine_os = "linux",
	})
	testing.expect(t, ok, err.message)
	return result
}

// AC: "An expired access token is rejected; a valid one is accepted." This is the
// direct answer to audit finding F3 — the credential it replaces never expired at
// all, so this test is the whole requirement in one assertion pair.
@(test)
test_access_token_expires :: proc(t: ^testing.T) {
	f := setup_token_fixture(t, "expiry")
	defer teardown_token_fixture(f)
	enrolled := enrol_one(t, f, "expiring-host")

	ctx, ok, err := verify_bridge_token(&f.svc, enrolled.bridge_token)
	testing.expect(t, ok, err.message)
	testing.expect_value(t, ctx.bridge_id, enrolled.bridge.bridge_id)
	testing.expect_value(t, enrolled.expires_in, BRIDGE_ACCESS_TOKEN_TTL_SECONDS)

	// Just inside the TTL: still good. Asserted so the rejection below cannot be
	// explained by the token having been broken from the start.
	advance(f, BRIDGE_ACCESS_TOKEN_TTL_SECONDS - 10)
	_, still_ok, still_err := verify_bridge_token(&f.svc, enrolled.bridge_token)
	testing.expect(t, still_ok, still_err.message)

	// Past the TTL but inside the skew grace: deliberately STILL ACCEPTED. The grace
	// exists so a request crossing the expiry second does not hard-fail; asserting
	// it here keeps that a decision rather than an accident someone later "fixes".
	advance(f, 10 + BRIDGE_TOKEN_CLOCK_SKEW_SECONDS - 5)
	_, grace_ok, _ := verify_bridge_token(&f.svc, enrolled.bridge_token)
	testing.expect(t, grace_ok, "a token inside the clock-skew grace is still accepted")

	// Past TTL + grace: rejected, with the error that tells the bridge to refresh
	// rather than to wipe its credentials and demand re-enrollment.
	advance(f, 10)
	_, expired_ok, expired_err := verify_bridge_token(&f.svc, enrolled.bridge_token)
	testing.expect(t, !expired_ok, "an expired access token authenticates nothing")
	testing.expect(t, strings.contains(expired_err.message, "expired"), "the error says the token expired, so the bridge refreshes instead of re-enrolling")
	testing.expect_value(t, expired_err.code, domain.Error_Code.Unauthenticated)
}

// AC: "Refresh returns a new access + new refresh token; the old refresh token is
// dead." Also asserts the expired access token is renewed — i.e. that refresh is
// actually a recovery path and not just a token factory.
@(test)
test_refresh_rotates_and_kills_the_old_token :: proc(t: ^testing.T) {
	f := setup_token_fixture(t, "rotate")
	defer teardown_token_fixture(f)
	enrolled := enrol_one(t, f, "rotating-host")

	// Age the access token out, the way a bridge returning from a long sleep would.
	advance(f, BRIDGE_ACCESS_TOKEN_TTL_SECONDS + BRIDGE_TOKEN_CLOCK_SKEW_SECONDS + 1)
	_, pre_ok, _ := verify_bridge_token(&f.svc, enrolled.bridge_token)
	testing.expect(t, !pre_ok, "the access token is expired before the refresh")

	pair, ok, err := refresh_bridge_token(&f.svc, enrolled.refresh_token)
	testing.expect(t, ok, err.message)
	testing.expect(t, pair.access_token != enrolled.bridge_token, "refresh issues a NEW access token")
	testing.expect(t, pair.refresh_token != enrolled.refresh_token, "refresh issues a NEW refresh token")
	testing.expect_value(t, pair.generation, 1)
	testing.expect_value(t, pair.bridge_id, enrolled.bridge.bridge_id)
	testing.expect_value(t, pair.expires_in, BRIDGE_ACCESS_TOKEN_TTL_SECONDS)

	// The new access token works.
	ctx, new_ok, new_err := verify_bridge_token(&f.svc, pair.access_token)
	testing.expect(t, new_ok, new_err.message)
	testing.expect_value(t, ctx.bridge_id, enrolled.bridge.bridge_id)

	// The new refresh token works, which proves the lineage continues rather than
	// terminating at generation 1.
	advance(f, BRIDGE_REFRESH_REUSE_GRACE_SECONDS + 1)
	second, second_ok, second_err := refresh_bridge_token(&f.svc, pair.refresh_token)
	testing.expect(t, second_ok, second_err.message)
	testing.expect_value(t, second.generation, 2)
	testing.expect_value(t, second.family_id, pair.family_id)
}

// AC, and the one the reviewer asked to see proven rather than claimed: "REUSING A
// CONSUMED REFRESH TOKEN REVOKES THE FAMILY."
//
// This is the control that turns refresh-token theft from silent persistent access
// into a loud, self-limiting event (design §7.4.3), so the assertions deliberately
// cover BOTH halves: the replay is refused, AND everything else in the lineage —
// including the access token the legitimate bridge is holding right now — is dead
// afterwards. A revocation that only refused the replay would leave the thief with a
// working access token and the victim none the wiser.
@(test)
test_refresh_token_reuse_revokes_the_whole_family :: proc(t: ^testing.T) {
	f := setup_token_fixture(t, "reuse")
	defer teardown_token_fixture(f)
	enrolled := enrol_one(t, f, "stolen-host")

	// Generation 1, legitimately.
	pair, ok, err := refresh_bridge_token(&f.svc, enrolled.refresh_token)
	testing.expect(t, ok, err.message)
	_, live_ok, _ := verify_bridge_token(&f.svc, pair.access_token)
	testing.expect(t, live_ok, "the current generation's access token works before the replay")

	// Move past the crash-recovery grace, so this is unambiguously a replay and not
	// the tolerated case.
	advance(f, BRIDGE_REFRESH_REUSE_GRACE_SECONDS + 1)

	// THE REPLAY: the generation-0 refresh token, already spent above.
	_, replay_ok, replay_err := refresh_bridge_token(&f.svc, enrolled.refresh_token)
	testing.expect(t, !replay_ok, "a consumed refresh token cannot be redeemed again")
	testing.expect(t, strings.contains(replay_err.message, "invalid_grant"), "the replay is reported as invalid_grant")

	// THE FAMILY IS DEAD. The access token minted one step earlier, which the
	// legitimate bridge is actively using, must now fail.
	_, after_ok, after_err := verify_bridge_token(&f.svc, pair.access_token)
	testing.expect(t, !after_ok, "reuse detection revoked the CURRENT access token too")
	testing.expect_value(t, after_err.code, domain.Error_Code.Forbidden)
	// And the current refresh token cannot be used to recover: re-enrollment is the
	// only way back, which is what makes the event loud.
	_, recover_ok, _ := refresh_bridge_token(&f.svc, pair.refresh_token)
	testing.expect(t, !recover_ok, "the family's newest refresh token is revoked as well")

	// Belt and braces at the storage layer: every row of the lineage carries a
	// revoked_at, not merely the two tokens the assertions above happened to touch.
	family, _ := iface.bridge_list_tokens_by_family(&f.repo, pair.family_id)
	defer free_bridge_tokens(family)
	testing.expect(t, len(family) >= 4, "the lineage has at least two generations x two kinds")
	for row in family {
		testing.expect(t, row.revoked_at != "", "every row in the family is revoked")
	}
}

// §7.4.4: the crash-recovery grace window, tested as the deliberate hole it is.
//
// A bridge that dies between "Hub rotated" and "bridge persisted" comes back holding
// a token the Hub considers spent. Without the grace, its next refresh revokes the
// family and the machine needs a human at a browser — a power cut would brick it.
// With it, that one token works once more, AND the generation it had already minted
// (which the bridge demonstrably never received) is revoked so two live generations
// cannot coexist.
@(test)
test_refresh_grace_window_recovers_a_crashed_bridge :: proc(t: ^testing.T) {
	f := setup_token_fixture(t, "grace")
	defer teardown_token_fixture(f)
	enrolled := enrol_one(t, f, "crashing-host")

	// The Hub rotates; pretend the response never reached the bridge.
	orphaned, ok, err := refresh_bridge_token(&f.svc, enrolled.refresh_token)
	testing.expect(t, ok, err.message)

	// The bridge restarts a few seconds later still holding generation 0.
	advance(f, 5)
	recovered, recover_ok, recover_err := refresh_bridge_token(&f.svc, enrolled.refresh_token)
	testing.expect(t, recover_ok, recover_err.message)
	testing.expect(t, recovered.generation > orphaned.generation, "recovery mints a NEW generation rather than re-sending the lost one")
	testing.expect_value(t, recovered.family_id, orphaned.family_id)

	// The recovered pair works...
	_, live_ok, live_err := verify_bridge_token(&f.svc, recovered.access_token)
	testing.expect(t, live_ok, live_err.message)
	// ...and the orphaned generation does NOT. This is what keeps single-use
	// meaningful inside the grace window: whoever else holds that lost pair gets
	// nothing.
	_, orphan_ok, _ := verify_bridge_token(&f.svc, orphaned.access_token)
	testing.expect(t, !orphan_ok, "the orphaned generation's access token is revoked")
	_, orphan_refresh_ok, _ := refresh_bridge_token(&f.svc, orphaned.refresh_token)
	testing.expect(t, !orphan_refresh_ok, "the orphaned generation's refresh token is revoked")

	// Outside the window the SAME replay is theft, not recovery. The grace is
	// 30 seconds, not "the last rotation forever".
	stale, stale_ok, _ := refresh_bridge_token(&f.svc, enrolled.refresh_token)
	testing.expect(t, !stale_ok, "a replay of an already-graced token is refused")
	testing.expect_value(t, stale.generation, 0)
}

// §7.4.5: the absolute family cap. Sliding expiry alone means a credential used
// often never expires, which is how a decommissioned-but-running machine keeps
// access indefinitely.
@(test)
test_family_absolute_cap_forces_reenrollment :: proc(t: ^testing.T) {
	f := setup_token_fixture(t, "cap")
	defer teardown_token_fixture(f)
	enrolled := enrol_one(t, f, "ancient-host")

	// The refresh lifetime is reported as the sliding window, not the cap.
	testing.expect_value(t, enrolled.refresh_expires_in, BRIDGE_REFRESH_TOKEN_TTL_SECONDS)

	advance(f, BRIDGE_TOKEN_FAMILY_MAX_SECONDS + BRIDGE_TOKEN_CLOCK_SKEW_SECONDS + 1)
	_, ok, _ := refresh_bridge_token(&f.svc, enrolled.refresh_token)
	testing.expect(t, !ok, "a family past its absolute cap cannot rotate")

	// A fresh enrollment at the same (far future) instant works, so the cap forces
	// RE-ENROLLMENT rather than bricking the machine permanently.
	again := enrol_one(t, f, "ancient-host")
	_, again_ok, again_err := verify_bridge_token(&f.svc, again.bridge_token)
	testing.expect(t, again_ok, again_err.message)
}

// Privilege confusion: the two halves of the pair have different authority, so each
// must be refused where the other belongs. A prefix alone is attacker-supplied, so
// the service checks the STORED kind; these assertions are what would fail if that
// check were dropped for the "obvious" prefix test.
@(test)
test_token_kinds_are_not_interchangeable :: proc(t: ^testing.T) {
	f := setup_token_fixture(t, "kinds")
	defer teardown_token_fixture(f)
	enrolled := enrol_one(t, f, "kinds-host")

	// A refresh token must not authenticate a connection: it is the long-lived half.
	_, auth_ok, _ := verify_bridge_token(&f.svc, enrolled.refresh_token)
	testing.expect(t, !auth_ok, "a refresh token does not authenticate a bridge connection")

	// An access token must not be exchangeable for a 30-day credential.
	_, refresh_ok, _ := refresh_bridge_token(&f.svc, enrolled.bridge_token)
	testing.expect(t, !refresh_ok, "an access token cannot be redeemed at the refresh path")

	// A refresh token wearing the access prefix: the row exists, the secret is even
	// correct, and it must STILL fail — this is the stored-kind check, and a
	// prefix-only implementation would accept it.
	token_id, secret, split_ok := split_credential(REFRESH_TOKEN_PREFIX, enrolled.refresh_token)
	testing.expect(t, split_ok, "the refresh token splits")
	relabelled := strings.concatenate({ACCESS_TOKEN_PREFIX, token_id, ".", secret}, context.temp_allocator)
	_, relabelled_ok, _ := verify_bridge_token(&f.svc, relabelled)
	testing.expect(t, !relabelled_ok, "a refresh row reached through the access prefix authenticates nothing")

	// Garbage and an unknown-but-well-formed id are both refused, and the second is
	// the existence-oracle case: it must look exactly like a wrong secret.
	_, junk_ok, junk_err := verify_bridge_token(&f.svc, "hba_btk_nosuchrow.deadbeef")
	testing.expect(t, !junk_ok, "an unknown token id authenticates nothing")
	testing.expect_value(t, junk_err.code, domain.Error_Code.Unauthenticated)
	testing.expect_value(t, junk_err.message, "bridge token is invalid")
	// Same message as a WRONG SECRET against a real row. Settled 6: row-not-found
	// and secret-mismatch must be indistinguishable.
	real_id, _, _ := split_credential(ACCESS_TOKEN_PREFIX, enrolled.bridge_token)
	wrong := strings.concatenate({ACCESS_TOKEN_PREFIX, real_id, ".", "00000000000000000000000000000000"}, context.temp_allocator)
	_, wrong_ok, wrong_err := verify_bridge_token(&f.svc, wrong)
	testing.expect(t, !wrong_ok, "a wrong secret authenticates nothing")
	testing.expect_value(t, wrong_err.message, junk_err.message)
	testing.expect_value(t, wrong_err.code, junk_err.code)
}

// INVERTED (REQ-ENROLL-9). This test was `test_legacy_hbr_credential_still_
// authenticates` and it asserted the opposite: that a legacy non-expiring
// credential authenticated, did NOT expire after 48 token lifetimes, and kept
// working until its bridge was revoked. That coexistence was deliberate while the
// one-time-token flow still minted such credentials — deleting the branch earlier
// would have locked out every bridge enrolled the old way.
//
// REQ-IMPL-6 deleted the flow, so the credential must now be refused. It is inverted
// rather than deleted because the REFUSAL is the security property, and because the
// old test is precisely the thing that would still pass if the branch were left in
// by accident.
//
// IT ALSO PINS THE OPERATOR STORY. Every bridge enrolled the old way breaks at this
// change, so the rejection is required to NAME THE REMEDY rather than return a bare
// "invalid". That message is an acceptance criterion, so it is asserted here and not
// left to a code comment: a reworded error that drops the command would be a
// regression a status-code assertion could not catch.
@(test)
test_legacy_credential_is_refused_with_a_message_naming_the_fix :: proc(t: ^testing.T) {
	f := setup_token_fixture(t, "legacy")
	defer teardown_token_fixture(f)

	// A real, currently-enrolled bridge, so the legacy token below names a bridge id
	// that genuinely exists. That is the case most likely to slip through: a
	// surviving lookup would FIND this row, and only the deleted verification step
	// would have rejected it.
	modern := enrol_one(t, f, "modern-box")
	legacy_token := strings.concatenate({BRIDGE_TOKEN_PREFIX, modern.bridge.bridge_id, ".", LEGACY_SHAPED_SECRET}, context.temp_allocator)

	_, ok, err := verify_bridge_token(&f.svc, legacy_token)
	testing.expect(t, !ok, "a legacy hbr_ credential authenticates nothing")
	testing.expect_value(t, err.code, domain.Error_Code.Unauthenticated)
	// The message must carry the command an operator runs to recover, not merely
	// the word "invalid". Asserted by substring so the surrounding prose can change.
	testing.expect(t, strings.contains(err.message, "ham-bridge enroll --hub"), fmt.tprintf("the rejection must name the re-enrollment command; got: %s", err.message))
	testing.expect(t, strings.contains(err.message, "re-enroll"), fmt.tprintf("the rejection must say the bridge has to re-enroll; got: %s", err.message))
	// And it must NOT be the generic message: that is the whole distinction being
	// made, so assert the two are actually different strings.
	_, _, junk := verify_bridge_token(&f.svc, "hbz_nonsense.secret")
	testing.expect(t, err.message != junk.message, "the legacy rejection must differ from the generic one")

	// The modern credential for the SAME bridge still authenticates. Without this,
	// the test above would pass just as well if verification were broken outright.
	ctx, modern_ok, modern_err := verify_bridge_token(&f.svc, modern.bridge_token)
	testing.expect(t, modern_ok, modern_err.message)
	testing.expect_value(t, ctx.bridge_id, modern.bridge.bridge_id)

	// A legacy credential cannot be refreshed into a live one either — the refusal
	// must not be a door into the token family.
	_, refresh_ok, _ := refresh_bridge_token(&f.svc, legacy_token)
	testing.expect(t, !refresh_ok, "a legacy credential cannot be refreshed")
}

// LEGACY_SHAPED_SECRET is a well-formed 64-hex-char secret that was never issued.
// The shape matters: a malformed secret could be rejected by the credential split
// before the prefix is ever considered, which would make the test above pass for
// the wrong reason.
LEGACY_SHAPED_SECRET :: "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

// Revocation's three effects, at the service layer: credentials dead, row flipped,
// and the connection-closer ASKED to tear the socket down. The real teardown is
// proven on a real socket in src/hub/transport/http/bridge_revocation_ws_test.odin;
// this asserts revoke_bridge actually reaches the seam, with the right bridge_id,
// which is the part a socket test cannot isolate.
@(test)
test_revoke_bridge_revokes_credentials_and_asks_to_close_the_socket :: proc(t: ^testing.T) {
	f := setup_token_fixture(t, "revoke")
	defer teardown_token_fixture(f)
	a := enrol_one(t, f, "host-a")
	b := enrol_one(t, f, "host-b")

	owner_auth := contracts.Auth_Context{kind = .Session, user_id = "approving-human"}
	_, ok, err := revoke_bridge(&f.svc, owner_auth, a.bridge.bridge_id)
	testing.expect(t, ok, err.message)

	testing.expect_value(t, len(f.closed_bridge_ids), 1)
	testing.expect_value(t, f.closed_bridge_ids[0], a.bridge.bridge_id)

	_, a_ok, _ := verify_bridge_token(&f.svc, a.bridge_token)
	testing.expect(t, !a_ok, "revoked bridge's access token is dead")
	_, a_refresh_ok, _ := refresh_bridge_token(&f.svc, a.refresh_token)
	testing.expect(t, !a_refresh_ok, "revoked bridge cannot refresh")

	// AC: revoking bridge A leaves bridge B of the SAME user working, and B's
	// socket was never asked to close.
	b_ctx, b_ok, b_err := verify_bridge_token(&f.svc, b.bridge_token)
	testing.expect(t, b_ok, b_err.message)
	testing.expect_value(t, b_ctx.bridge_id, b.bridge.bridge_id)
	b_pair, b_refresh_ok, b_refresh_err := refresh_bridge_token(&f.svc, b.refresh_token)
	testing.expect(t, b_refresh_ok, b_refresh_err.message)
	testing.expect_value(t, b_pair.bridge_id, b.bridge.bridge_id)
	testing.expect_value(t, len(f.closed_bridge_ids), 1)
}

// An entropy failure must deny the operation with 503 + a retry hint, never issue a
// weaker credential (settled 8). The seam is issue_credential's entropy_source, so
// this covers the decision rather than the plumbing: a mint that cannot draw CSPRNG
// bytes returns Provider_Unavailable and writes nothing.
@(test)
test_mint_fails_closed_without_entropy :: proc(t: ^testing.T) {
	_, _, ok := issue_credential(ACCESS_TOKEN_PREFIX, "btk_no_entropy", NO_ENTROPY_SOURCE)
	testing.expect(t, !ok, "no credential is issued without a secure random source")
	_, _, refresh_ok := issue_credential(REFRESH_TOKEN_PREFIX, "btk_no_entropy", NO_ENTROPY_SOURCE)
	testing.expect(t, !refresh_ok, "the refresh half fails closed the same way")
}

// token_is_expired's fail-closed edges, which no higher-level test reaches: an empty
// expires_at must read as EXPIRED (it is what a row gets if a future writer forgets
// the column, and the opposite reading would silently resurrect a never-expiring
// credential), while an unreadable `now` must NOT expire the whole fleet over a
// formatting bug.
@(test)
test_token_expiry_edge_cases :: proc(t: ^testing.T) {
	testing.expect(t, token_is_expired("", "2026-01-01T00:00:00Z"), "an empty expiry is expired, not eternal")
	testing.expect(t, token_is_expired("not-a-timestamp", "2026-01-01T00:00:00Z"), "an unparseable expiry is expired")
	testing.expect(t, !token_is_expired("2026-01-01T00:00:00Z", "garbage"), "an unreadable `now` does not expire a valid token")
	testing.expect(t, !token_is_expired("2026-01-01T00:00:00Z", "2026-01-01T00:00:30Z"), "inside the skew grace is not expired")
	testing.expect(t, token_is_expired("2026-01-01T00:00:00Z", "2026-01-01T00:02:00Z"), "beyond the skew grace is expired")
}
