#+build !windows
// Tests for the browser-approval enrollment flow (REQ-IMPL-4).
//
// These are @(test) in `package main` because the flow is package-main code and a
// separate test binary cannot import package main.
//
// WHAT IS ASSERTED HERE VERSUS WHAT NEEDS THE LIVE STACK. Everything in this file
// is a property of the bridge's own output: the URL it emits, the shape of what it
// writes to disk, and when it
// schedules a refresh. The end-to-end ceremony against a real Hub is the local
// stack's job, and the handoff carries that transcript separately. The split
// matters because the stable, request-free approval URL is decided entirely by
// the emitted string, so a unit test pins it more precisely than a stack run can.
package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:sys/posix"
import "core:strings"
import "core:sync"
import "core:encoding/json"
import "core:testing"
import vault "odin_test:lib/vault"

// A fixed, well-formed uncompressed P-256 point: 0x04 then bytes 1..64. Its
// fingerprint and base64url encoding below were computed INDEPENDENTLY in python
// (sha256 of the decoded point, first 8 bytes as hex quads), not read back out of
// this implementation — a test that derives its expectation from the code under
// test proves only self-consistency.
TEST_PUBKEY_HEX :: "040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40"
TEST_PUBKEY_FINGERPRINT :: "0ed3 a6ab 957f f6f5"


// bridge_enroll_test_mode reads a path's permission bits as an octal integer via
// stat(2). os.File_Info.mode is a Permissions bit_set in this toolchain, which
// cannot be masked with an octal literal, and the repo already reads modes this
// way (see the vault-key permission checks in main.odin).
bridge_enroll_test_mode :: proc(path: string) -> (int, bool) {
	c_path := strings.clone_to_cstring(path, context.temp_allocator)
	st: posix.stat_t
	if posix.stat(c_path, &st) != .OK do return 0, false
	mode := 0
	bits := [?]struct{flag: posix.mode_t, value: int}{
		{{.IRUSR}, 0o400}, {{.IWUSR}, 0o200}, {{.IXUSR}, 0o100},
		{{.IRGRP}, 0o040}, {{.IWGRP}, 0o020}, {{.IXGRP}, 0o010},
		{{.IROTH}, 0o004}, {{.IWOTH}, 0o002}, {{.IXOTH}, 0o001},
	}
	for b in bits {
		if (st.st_mode & b.flag) == b.flag do mode |= b.value
	}
	return mode, true
}

bridge_enroll_test_rmdir :: proc(path: string) {
	posix.rmdir(strings.clone_to_cstring(path, context.temp_allocator))
}

// ===== Property 1: the approval URL is stable and carries no request data =====

@(test)
enroll_approval_url_is_stable_and_code_free :: proc(t: ^testing.T) {
	url := bridge_enroll_approval_url("https://heimdall.example.com")
	defer delete(url)
	testing.expect_value(t, url, "https://heimdall.example.com/api/v1/device/add")
	testing.expect(t, !strings.contains(url, "?"), "the stable URL must carry no query")
	testing.expect(t, !strings.contains(url, "#"), "the stable URL must be a path: a forward-auth login drops the fragment")
	for forbidden in ([?]string{"user_code", "device_code", "bpk", "state", "callback", "access_token"}) {
		testing.expectf(t, !strings.contains(url, forbidden), "approval URL leaked %s", forbidden)
	}
}

@(test)
enroll_authorize_body_carries_pairing_values_never_the_code :: proc(t: ^testing.T) {
	// Hub-blind pairing: the body carries the lookup and key_mac derived from the
	// pairing code; the code itself never leaves the bridge.
	code, ok := vault.pair_code_generate(context.temp_allocator)
	testing.expect(t, ok, "pairing code generated")
	salt, _ := vault.pair_salt_generate(context.temp_allocator)
	keys, _ := vault.pair_keys_derive(code, vault.Pair_Context{kind = "bridge", hub_origin = "https://hub.example.test:443", pair_salt = salt})
	defer vault.pair_keys_wipe(&keys)
	lookup := vault.pair_lookup_hex(&keys, context.temp_allocator)
	d := Bridge_Machine_Descriptor{hostname = "dawnstar", os = "Linux", os_user = "tanmay", bridge_version = "1.2.3"}
	body := bridge_enroll_authorize_body(d, TEST_PUBKEY_HEX, "challenge-value", pair_lookup = lookup, pair_key_mac = lookup, pair_salt = salt, pair_hub_origin = "https://hub.example.test:443", allocator = context.temp_allocator)
	decoded: Bridge_Authorize_Request
	testing.expect(t, json.unmarshal_string(body, &decoded, json.Specification.JSON, context.temp_allocator) == nil, "the body is valid JSON")
	testing.expect_value(t, decoded.pair_lookup, lookup)
	testing.expect_value(t, decoded.pair_salt, salt)
	testing.expect_value(t, decoded.pair_hub_origin, "https://hub.example.test:443")
	testing.expect_value(t, decoded.device_label, "dawnstar")
	symbols, _ := vault.pair_code_symbols(code)
	testing.expect(t, !strings.contains(body, string(symbols[:])) && !strings.contains(body, code), "the pairing code is never sent")
}
@(test)
enroll_pkce_challenge_matches_rfc7636_vector :: proc(t: ^testing.T) {
	// RFC 7636 Appendix B's verifier and its expected S256 challenge, verbatim.
	// Using the RFC's own vector rather than a locally-generated pair is what makes
	// this test evidence that the Hub (which recomputes the same way) will agree.
	verifier := "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
	challenge := bridge_pkce_challenge(verifier, context.temp_allocator)
	testing.expectf(t, challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "S256 challenge mismatch: %q", challenge)
	// Unpadded, URL-safe: the Hub's validator requires exactly 43 chars from the
	// base64url alphabet and rejects '=' padding.
	testing.expect(t, len(challenge) == 43, "an S256 challenge is 43 unpadded base64url chars")
	testing.expect(t, !strings.contains(challenge, "="), "the challenge must not be padded")
	testing.expect(t, !strings.contains(challenge, "+") && !strings.contains(challenge, "/"), "the challenge must use the URL-safe alphabet")
}

@(test)
enroll_generated_verifier_satisfies_rfc7636 :: proc(t: ^testing.T) {
	verifier, ok := bridge_enroll_random_token(context.temp_allocator)
	testing.expect(t, ok, "entropy must be available in the test environment")
	testing.expectf(t, len(verifier) >= 43 && len(verifier) <= 128, "verifier length %d is outside RFC 7636 §4.1", len(verifier))
	for i in 0 ..< len(verifier) {
		c := verifier[i]
		allowed :=
			(c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
			c == '-' || c == '.' || c == '_' || c == '~'
		testing.expectf(t, allowed, "verifier byte %q is outside the unreserved set", rune(c))
	}
	second, _ := bridge_enroll_random_token(context.temp_allocator)
	testing.expect(t, verifier != second, "two draws must differ — a constant verifier would make PKCE decorative")
}

// ===== The fingerprint the human compares =====

@(test)
enroll_fingerprint_matches_the_hub_derivation :: proc(t: ^testing.T) {
	fp, ok := bridge_enroll_fingerprint(TEST_PUBKEY_HEX, context.temp_allocator)
	testing.expect(t, ok, "a well-formed point must produce a fingerprint")
	// Independently computed in python over the DECODED point. If the bridge hashed
	// the hex TEXT instead, this value would differ and the human comparison against
	// the Hub's display would fail for every bridge.
	testing.expectf(t, fp == TEST_PUBKEY_FINGERPRINT, "fingerprint mismatch: %q", fp)
}

@(test)
enroll_fingerprint_refuses_a_malformed_point :: proc(t: ^testing.T) {
	// Each rejection matters because an empty fingerprint would render on the
	// approval page as "nothing to compare", which looks like a match.
	_, short := bridge_enroll_fingerprint("0401020304", context.temp_allocator)
	testing.expect(t, !short, "a short key must be refused")
	compressed := strings.concatenate({"02", TEST_PUBKEY_HEX[2:]}, context.temp_allocator)
	_, not_uncompressed := bridge_enroll_fingerprint(compressed, context.temp_allocator)
	testing.expect(t, !not_uncompressed, "a non-0x04 prefix must be refused")
	_, empty := bridge_enroll_fingerprint("", context.temp_allocator)
	testing.expect(t, !empty, "an empty key must be refused")
}

// ===== The machine descriptor — the defect this task exists to fix =====

@(test)
enroll_descriptor_refuses_the_old_placeholder :: proc(t: ^testing.T) {
	// The literal that used to ship for every machine. If it ever comes back, the
	// approval screen shows the same constant for an entire fleet and there is
	// nothing for the human to recognise — REQ-IMPL-5 is then meaningless.
	testing.expect(t, !bridge_enroll_descriptor_usable(Bridge_Machine_Descriptor{hostname = "ham-bridge"}), "the hardcoded placeholder must be refused")
	testing.expect(t, !bridge_enroll_descriptor_usable(Bridge_Machine_Descriptor{hostname = ""}), "an empty hostname must be refused")
	testing.expect(t, !bridge_enroll_descriptor_usable(Bridge_Machine_Descriptor{hostname = "   "}), "a blank hostname must be refused")
	testing.expect(t, bridge_enroll_descriptor_usable(Bridge_Machine_Descriptor{hostname = "dawnstar"}), "a real hostname must be accepted")
}

@(test)
enroll_descriptor_reads_real_values_from_the_host :: proc(t: ^testing.T) {
	d := bridge_enroll_machine_descriptor(context.temp_allocator)
	testing.expect(t, strings.trim_space(d.hostname) != "", "a real hostname must be resolvable on the test host")
	testing.expect(t, d.hostname != "ham-bridge", "the hostname must not be the placeholder")
	testing.expect(t, strings.trim_space(d.os) != "", "os must be populated")
	testing.expect(t, strings.trim_space(d.arch) != "", "arch must be populated")
	testing.expect(t, strings.trim_space(d.bridge_version) != "", "bridge_version must be populated")
}

@(test)
enroll_authorize_body_sends_the_descriptor_and_no_fingerprint :: proc(t: ^testing.T) {
	d := Bridge_Machine_Descriptor{
		hostname = "dawnstar", os = "Linux", os_version = "6.18.49", arch = "amd64",
		os_user = "tanmay", bridge_version = "1.2.3",
	}
	body := bridge_enroll_authorize_body(d, TEST_PUBKEY_HEX, "challenge-value", allocator = context.temp_allocator)
	// device_label is the field the Hub maps into the bridge row's machine_hostname,
	// so the real hostname has to land THERE specifically.
	testing.expect(t, strings.contains(body, "\"device_label\":\"dawnstar\""), "device_label must carry the real hostname")
	testing.expect(t, strings.contains(body, "\"os_user\":\"tanmay\""), "os_user must be sent")
	testing.expect(t, strings.contains(body, "\"os\":\"Linux 6.18.49 amd64\""), "os must carry the real os/version/arch")
	testing.expect(t, strings.contains(body, "\"app_version\":\"1.2.3\""), "the bridge version must be sent")
	testing.expect(t, strings.contains(body, "\"code_challenge_method\":\"S256\""), "S256 only")
	testing.expect(t, !strings.contains(body, "\"hostname\":\"ham-bridge\""), "the placeholder must be gone")
	// The Hub COMPUTES the fingerprint and rejects a disagreeing body value, so
	// sending one can only cause a 400.
	testing.expect(t, !strings.contains(body, "bridge_key_fingerprint"), "the bridge must not assert a fingerprint; the Hub derives it")
	testing.expect(t, !strings.contains(body, "code_verifier"), "the verifier is revealed only at redemption, never at authorize")
}

// ===== F4: the bridge cannot finish enrollment holding nothing =====

@(test)
enroll_credential_rejects_every_empty_shape :: proc(t: ^testing.T) {
	// Each of these is a shape that, if accepted and written, would leave the bridge
	// with a blank or unusable token — and a blank token is what makes the loopback
	// authorizer authorise every caller (audit F4).
	testing.expect(t, !bridge_enroll_credential_usable(""), "empty")
	testing.expect(t, !bridge_enroll_credential_usable("   "), "blank")
	testing.expect(t, !bridge_enroll_credential_usable("hba_"), "prefix only")
	testing.expect(t, !bridge_enroll_credential_usable("hba_btk_1"), "no separator")
	testing.expect(t, !bridge_enroll_credential_usable("hba_btk_1."), "empty secret half")
	testing.expect(t, !bridge_enroll_credential_usable("hba_.secret"), "empty id half")
	testing.expect(t, !bridge_enroll_credential_usable(".secret"), "no prefix at all")
	testing.expect(t, !bridge_enroll_credential_usable("hlat_agent.secret"), "an agent token is not a bridge credential")
	testing.expect(t, bridge_enroll_credential_usable("hba_btk_19fa3d.deadbeefdeadbeef"), "a well-formed access token is accepted")
	testing.expect(t, bridge_enroll_credential_usable("hbf_btk_19fa3d.deadbeefdeadbeef"), "a well-formed refresh token is accepted")
	testing.expect(t, bridge_enroll_credential_usable("hbr_brg_19fa3d.deadbeefdeadbeef"), "a legacy hbr_ credential is still accepted")
}

@(test)
enroll_persist_refuses_to_write_a_blank_credential :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/ham-enroll-test-%d", bridge_now_unix_ms())
	path := fmt.tprintf("%s/credential", dir)
	defer bridge_enroll_test_rmdir(dir)
	testing.expect(t, !bridge_write_secret_file(path, ""), "an empty credential must not be written")
	testing.expect(t, !bridge_write_secret_file(path, "   "), "a blank credential must not be written")
	_, exists := bridge_enroll_test_mode(path)
	testing.expect(t, !exists, "no file may exist after a refused write")
	ok := bridge_enroll_persist(Bridge_Enroll_Credential{access_token = ""}, path, "", "https://example.com")
	testing.expect(t, !ok, "persisting an empty access token must fail")
}

// ===== At-rest storage: 0600, and never in config.toml =====

@(test)
enroll_credential_file_is_0600_in_a_0700_directory :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/ham-enroll-mode-%d", bridge_now_unix_ms())
	path := fmt.tprintf("%s/credential", dir)
	defer os.remove(path)
	defer bridge_enroll_test_rmdir(dir)
	testing.expect(t, bridge_write_secret_file(path, "hba_btk_1.secretsecret"), "the write must succeed")
	mode, mode_ok := bridge_enroll_test_mode(path)
	testing.expect(t, mode_ok, "the file must exist")
	// 0600 exactly: group and other must have nothing. This is what keeps a
	// DIFFERENT local user out; it does not and cannot stop the same user (§3.2).
	testing.expectf(t, mode == 0o600, "credential mode was %o, expected 600", mode)
	dir_mode, dir_ok := bridge_enroll_test_mode(dir)
	testing.expect(t, dir_ok, "the parent directory must exist")
	testing.expectf(t, dir_mode == 0o700, "parent directory mode was %o, expected 700", dir_mode)
	// The content round-trips exactly — a credential mangled on the way to disk is
	// indistinguishable from a revoked one at the next start.
	read_back, read_ok := bridge_read_token_file(path)
	defer delete(read_back)
	testing.expect(t, read_ok && read_back == "hba_btk_1.secretsecret", "the credential must round-trip unchanged")
}

@(test)
enroll_rewrite_is_atomic_and_leaves_no_temp_file :: proc(t: ^testing.T) {
	// A refresh rewrites this file under a running bridge, so a reader must see the
	// old content or the new one and never a truncated line.
	dir := fmt.tprintf("/tmp/ham-enroll-atomic-%d", bridge_now_unix_ms())
	path := fmt.tprintf("%s/credential", dir)
	defer os.remove(path)
	defer bridge_enroll_test_rmdir(dir)
	testing.expect(t, bridge_write_secret_file(path, "hba_btk_1.first"), "first write")
	testing.expect(t, bridge_write_secret_file(path, "hba_btk_2.second"), "rotation")
	read_back, _ := bridge_read_token_file(path)
	defer delete(read_back)
	testing.expect(t, read_back == "hba_btk_2.second", "the rotated credential must be the one on disk")
	_, tmp_exists := bridge_enroll_test_mode(fmt.tprintf("%s.tmp", path))
	testing.expect(t, !tmp_exists, "no .tmp file may survive a completed write")
}

@(test)
enroll_never_writes_a_credential_into_config_toml :: proc(t: ^testing.T) {
	// Audit F2, closed by removing the path: the merge is called with an EMPTY token
	// on this flow, and an empty token writes no bridge_token line at all.
	merged := bridge_config_merge("", "https://heimdall.example.com", "", "brg_123")
	defer delete(merged)
	testing.expect(t, !strings.contains(merged, "bridge_token"), "config.toml must never receive a bridge_token on the device flow")
	testing.expect(t, strings.contains(merged, "brg_123"), "the non-secret bridge id is fine to persist")
	testing.expect(t, strings.contains(merged, "heimdall.example.com"), "the hub url is fine to persist")
	// And the secret must not reach it even when one exists on the flow.
	with_existing := bridge_config_merge("[daemon]\nbridge_token = \"hbr_old.secret\"\n", "https://heimdall.example.com", "", "brg_123")
	defer delete(with_existing)
	testing.expect(t, !strings.contains(with_existing, "hba_"), "no new credential may be written into config.toml")
}

// ===== Proactive refresh scheduling =====

@(test)
refresh_delay_lands_in_the_jittered_band :: proc(t: ^testing.T) {
	// 1 hour: 80% is 2880s, the +/-5% jitter span is 180s, so every delay must land
	// in [2700, 3060] — comfortably before expiry, which is the point.
	lo := 3600 * (BRIDGE_REFRESH_AT_PERCENT - BRIDGE_REFRESH_JITTER_PERCENT) / 100
	hi := 3600 * (BRIDGE_REFRESH_AT_PERCENT + BRIDGE_REFRESH_JITTER_PERCENT) / 100
	for b in 0 ..= 255 {
		d := bridge_refresh_delay_seconds(3600, u8(b))
		testing.expectf(t, d >= lo && d <= hi, "jitter byte %d produced %ds, outside [%d, %d]", b, d, lo, hi)
		testing.expectf(t, d < 3600, "a refresh at %ds would be at or after expiry", d)
	}
	// The jitter must actually spread: identical delays for every byte would be a
	// synchronised fleet, which is the failure the jitter exists to prevent.
	testing.expect(t, bridge_refresh_delay_seconds(3600, 0) != bridge_refresh_delay_seconds(3600, 255), "the jitter must vary with its input")
	testing.expect(t, bridge_refresh_delay_seconds(3600, 0) == lo, "the low end of the band must be reachable")
	testing.expect(t, bridge_refresh_delay_seconds(3600, 255) == hi, "the high end of the band must be reachable")
}

@(test)
refresh_delay_is_zero_for_a_non_expiring_credential :: proc(t: ^testing.T) {
	// A legacy `hbr_` bridge reports no expiry. Zero means "schedule nothing", and
	// must not be confused with "refresh immediately" — that would be a hot loop
	// against the Hub for every pre-REQ-IMPL-3 bridge in the fleet.
	testing.expect(t, bridge_refresh_delay_seconds(0, 128) == 0, "no expiry means no schedule")
	testing.expect(t, bridge_refresh_delay_seconds(-1, 128) == 0, "a negative expiry means no schedule")
}

@(test)
refresh_delay_never_schedules_past_expiry_on_short_lifetimes :: proc(t: ^testing.T) {
	// The 30s floor could otherwise overshoot a very short lifetime, scheduling a
	// renewal for after the token is already dead.
	for lifetime in ([?]int{1, 5, 10, 29, 30, 31, 60, 120}) {
		d := bridge_refresh_delay_seconds(lifetime, 128)
		testing.expectf(t, d <= lifetime, "lifetime %ds scheduled a refresh at %ds, after expiry", lifetime, d)
		testing.expectf(t, d > 0, "lifetime %ds must still schedule something", lifetime)
	}
}

// ===== The Hub origin is the only input =====

@(test)
enroll_hub_url_accepts_an_origin_and_rejects_everything_else :: proc(t: ^testing.T) {
	origin, ok := bridge_enroll_hub_url("https://hub.example.com/", context.temp_allocator)
	testing.expect(t, ok && origin == "https://hub.example.com", "a trailing slash must be normalised away")
	plain, plain_ok := bridge_enroll_hub_url("http://127.0.0.1:8190", context.temp_allocator)
	testing.expect(t, plain_ok && plain == "http://127.0.0.1:8190", "a local http origin must be accepted for the dev stack")
	// A path is refused rather than trimmed: it most likely means the operator
	// pasted the approval page, and silently deriving the origin from it would make
	// a wrong host look like it worked.
	_, with_path := bridge_enroll_hub_url("https://hub.example.com/enroll", context.temp_allocator)
	testing.expect(t, !with_path, "a URL with a path must be refused")
	_, no_scheme := bridge_enroll_hub_url("hub.example.com", context.temp_allocator)
	testing.expect(t, !no_scheme, "a bare hostname must be refused")
	_, empty := bridge_enroll_hub_url("", context.temp_allocator)
	testing.expect(t, !empty, "an empty value must be refused")
	_, fragment := bridge_enroll_hub_url("https://hub.example.com/#x", context.temp_allocator)
	testing.expect(t, !fragment, "a URL with a fragment must be refused")
}

// ===== Polling is the sole completion channel =====

@(test)
enroll_approval_url_advertises_no_callback :: proc(t: ^testing.T) {
	url := bridge_enroll_approval_url("https://heimdall.example.com")
	defer delete(url)
	testing.expect(t, !strings.contains(url, "cb="), "no callback port may be advertised")
	testing.expect(t, !strings.contains(url, "state="), "no callback nonce may be advertised")
	testing.expect(t, !strings.contains(url, "127.0.0.1"), "enrollment must not expose a loopback listener")
}


@(test)
hello_reports_the_real_hostname_not_the_bridge_id :: proc(t: ^testing.T) {
	// The hub assigns the hello's `hostname` to machine_hostname (and to the label
	// when it is not user-customized), so this field previously renamed every bridge
	// after its own `brg_` id moments after it started — overwriting the real value
	// this task captures at enrollment. Observed live on the local stack before the
	// fix: machine_hostname = brg_18dc53cf6bbdb13a.
	host := bridge_hello_hostname()
	testing.expect(t, !strings.has_prefix(host, "brg_"), "the hello must never report a bridge id as the hostname")
	testing.expect(t, host != "ham-bridge", "the hello must not report the old placeholder either")
	// It must agree with the descriptor the approval screen was shown, or the
	// displayed hostname would depend on which message the hub saw last.
	d := bridge_enroll_machine_descriptor(context.temp_allocator)
	testing.expectf(t, host == d.hostname, "hello hostname %q disagrees with the enrollment descriptor %q", host, d.hostname)
	// Cached: a second call must not re-resolve into a different answer.
	testing.expect(t, bridge_hello_hostname() == host, "the resolved hostname must be stable for the process")
}

@(test)
hello_json_carries_the_real_hostname :: proc(t: ^testing.T) {
	// Asserted on the emitted frame, not just the helper, because the defect was in
	// which value the frame passed — the helper is new and the frame is what the hub
	// reads.
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	saved_cfg := bridge_config
	defer bridge_config = saved_cfg
	bridge_config.daemon_id = "brg_1234567890abcdef"
	hello := bridge_hub_hello_json()
	defer delete(hello)
	testing.expect(t, strings.contains(hello, "\"hostname\":\""), "the hello must carry a hostname field")
	testing.expect(t, !strings.contains(hello, "\"hostname\":\"brg_1234567890abcdef\""), "the hello must not pass daemon_id as the hostname")
	host := bridge_hello_hostname()
	if host != "" {
		testing.expectf(t, strings.contains(hello, fmt.tprintf("\"hostname\":\"%s\"", host)), "the hello must carry the resolved hostname %q", host)
	}
}

@(test)
enroll_and_startup_agree_on_the_default_credential_path :: proc(t: ^testing.T) {
    // `enroll` writes the credential here and startup reads it from here. If the two
    // ever disagreed, an enrolled bridge would come up unable to find its own
    // credential — and because the device flow no longer writes the token into
    // config.toml (F2), there would be no second source to fall back on.
    bridge_id, _ := keystore_test_bridge_ids()
    written := bridge_enroll_token_file_from_args([]string{"ham-bridge", "enroll", "--hub", "https://hub.example.com"}, "https://hub.example.com", bridge_id, context.temp_allocator)
    read := bridge_enroll_default_credential_path("https://hub.example.com", bridge_id, context.temp_allocator)
    testing.expectf(t, written == read, "enroll writes %q but startup reads %q", written, read)
    if read != "" {
        testing.expect(t, !strings.has_prefix(read, "~"), "the path must be expanded, not a literal tilde")
        testing.expect(t, strings.has_prefix(read, "/"), "the path must be absolute")
        // Not a system path: enrollment is run by a person, and a root-only default
        // would fail after the human had already approved in the browser.
        testing.expect(t, !strings.has_prefix(read, "/var/lib/"), "the default must not require root")
    }
    // An explicit flag always wins over the default.
    explicit := bridge_enroll_token_file_from_args([]string{"ham-bridge", "enroll", "--bridge-token-file", "/tmp/explicit-cred"}, "https://hub.example.com", bridge_id, context.temp_allocator)
    testing.expect(t, explicit == "/tmp/explicit-cred", "an explicit --bridge-token-file must win")
}

@(test)
enrolled_but_tokenless_startup_is_refused :: proc(t: ^testing.T) {
    // Audit F4 at startup: with a blank token `bridge_loopback_authorized` returns
    // true for every caller, so an enrolled-but-tokenless bridge would serve its
    // loopback API unauthenticated while being unable to reach the hub at all.
    testing.expect(t, bridge_enrolled_but_tokenless("brg_18dc53eec25c54cd", ""), "enrolled with no token must be refused")
    testing.expect(t, bridge_enrolled_but_tokenless("brg_1", "   "), "a blank token counts as none")
    // Narrow by design (Q4 ruling): a dev bridge that was never enrolled still
    // starts, so this cannot break the dev-stack harnesses other workers rely on.
    testing.expect(t, !bridge_enrolled_but_tokenless("local-daemon", ""), "a never-enrolled dev bridge must still start")
    testing.expect(t, !bridge_enrolled_but_tokenless("", ""), "an unconfigured bridge must still start")
    // And a credential of any shape clears it — validity is the enroll path's job,
    // not startup's, so a legacy hbr_ bridge is unaffected.
    testing.expect(t, !bridge_enrolled_but_tokenless("brg_1", "hba_btk_1.secret"), "an enrolled bridge with a token starts")
    testing.expect(t, !bridge_enrolled_but_tokenless("brg_1", "hbr_brg_1.secret"), "a legacy credential still starts")
}

@(test)
default_credential_adoption_never_overrides_an_explicit_token :: proc(t: ^testing.T) {
    // The fallback exists only to rescue the case that is otherwise broken (no token
    // anywhere). It must never shadow what the operator asked for, because adopting
    // an ambient file over an explicit flag would silently point a bridge at a
    // DIFFERENT hub's credential.
    //
    // THE CANDIDATE FILE IS CREATED HERE, and that is the point. The first version of
    // this test let the proc resolve the real default path, so on a machine with no
    // credential there it did nothing whatever the config said — the reviewer deleted
    // BOTH early returns and the test still passed. An assertion that holds because
    // the code under test had nothing to do is not a test.
    dir := fmt.tprintf("/tmp/ham-default-cred-%d", bridge_now_unix_ms())
    candidate := fmt.tprintf("%s/credential", dir)
    defer os.remove(candidate)
    defer bridge_enroll_test_rmdir(dir)
    testing.expect(t, bridge_write_secret_file(candidate, "hba_btk_ambient.ambientsecret"), "the candidate must exist for this test to mean anything")

    // 1. An explicit token wins over a candidate that really is there.
    explicit := Bridge_Config{bridge_token = "hba_btk_explicit.secret"}
    bridge_adopt_default_credential_if_needed(&explicit, candidate)
    testing.expect(t, explicit.bridge_token == "hba_btk_explicit.secret", "an explicit token must survive an existing candidate")
    testing.expect(t, explicit.credential_file == "", "and no credential file is adopted")

    // 2. An explicit credential file wins too.
    named := Bridge_Config{credential_file = "/tmp/some-explicit-path"}
    bridge_adopt_default_credential_if_needed(&named, candidate)
    testing.expect(t, named.credential_file == "/tmp/some-explicit-path", "an explicit credential file must survive")
    testing.expect(t, named.bridge_token == "", "and the candidate is not read")

    // 3. With nothing configured, the candidate IS adopted — the positive half, which
    //    the previous version never exercised at all.
    empty := Bridge_Config{}
    bridge_adopt_default_credential_if_needed(&empty, candidate)
    testing.expect(t, empty.bridge_token == "hba_btk_ambient.ambientsecret", "an unconfigured bridge adopts the candidate")
    testing.expect(t, empty.credential_file == candidate, "and records where it came from, so refresh can rewrite it")

    // 4. A candidate that does not exist adopts nothing and must not invent a path.
    missing := Bridge_Config{}
    bridge_adopt_default_credential_if_needed(&missing, fmt.tprintf("%s/absent", dir))
    testing.expect(t, missing.bridge_token == "", "a missing candidate adopts nothing")
    testing.expect(t, missing.credential_file == "", "and sets no credential file")
}

@(test)
hello_hostname_cache_survives_an_allocator_reset :: proc(t: ^testing.T) {
    // REGRESSION TEST for the reviewer's blocking find. The cache used to hold a
    // clone made from whatever context.allocator was current at the first call, while
    // the global outlives every such scope — so under the test runner, whose per-test
    // rollback allocator is free_all'd after each test, it came back as another
    // test's bytes ("dawnstar" read back as "CDEFGHIJ": the same 8 bytes, rewritten
    // in place). It is now a fixed global buffer owning its own bytes.
    //
    // This reproduces the hazard directly rather than relying on test ordering: call
    // it inside an arena, destroy the arena, and read again.
    arena_backing := make([]byte, 4096)
    defer delete(arena_backing)
    arena: mem.Arena
    mem.arena_init(&arena, arena_backing)
    first: string
    {
        context.allocator = mem.arena_allocator(&arena)
        first = bridge_hello_hostname()
    }
    // SNAPSHOT THE BYTES OUT before wiping, and this is the whole reason the first
    // version of this test could not fail. Pre-fix, both calls return the SAME global
    // string, so `first` and `second` alias one buffer: wiping the arena changes what
    // `first` itself points at, and `second == first` then compares a value with
    // itself and holds no matter how corrupt the memory is. The reviewer reinstated
    // the broken cache and this test still passed. Copying into a local array makes
    // the comparison be against the ORIGINAL bytes.
    first_snapshot: [256]byte
    first_n := copy(first_snapshot[:], first)
    first_bytes := string(first_snapshot[:first_n])
    // Wipe the arena the way a freed scope would, then re-read.
    mem.zero_slice(arena_backing)
    free_all(mem.arena_allocator(&arena))
    second := bridge_hello_hostname()
    testing.expectf(t, second == first_bytes, "the cached hostname changed after its first allocator was reset: %q -> %q", first_bytes, second)
    if second != "" {
        testing.expect(t, !strings.has_prefix(second, "brg_"), "and it must still not be a bridge id")
        testing.expect(t, second != "ham-bridge", "nor the old placeholder")
    }
}

@(test)
enroll_credential_reads_approver_username :: proc(t: ^testing.T) {
	credential := bridge_enroll_credential_from_json(`{"bridge_id":"brg_test","approver_username":"alice","access_token":"hba_test.secret"}`)
	defer delete(credential.approver_username)
	defer delete(credential.bridge_id)
	defer delete(credential.access_token)
	defer delete(credential.refresh_token)
	testing.expect_value(t, credential.approver_username, "alice")
	legacy := bridge_enroll_credential_from_json(`{"bridge_id":"brg_old","access_token":"hba_old.secret"}`)
	defer delete(legacy.approver_username)
	defer delete(legacy.bridge_id)
	defer delete(legacy.access_token)
	defer delete(legacy.refresh_token)
	testing.expect_value(t, legacy.approver_username, "")
}

// ===== Enrolled config TOML merging & writing =====

@(test)
test_bridge_config_merge_empty :: proc(t: ^testing.T) {
	merged := bridge_config_merge("", "http://hub.example.test:8080", "tok_123", "brg_abc")
	testing.expect(t, strings.contains(merged, "[wrapper]"), "empty config gains [wrapper]")
	testing.expect(t, strings.contains(merged, "daemon_url = \"http://hub.example.test:8080\""), "empty config gains daemon_url")
	testing.expect(t, strings.contains(merged, "[daemon]"), "empty config gains [daemon]")
	testing.expect(t, strings.contains(merged, "daemon_id = \"brg_abc\""), "empty config gains daemon_id")
	testing.expect(t, strings.contains(merged, "bridge_token = \"tok_123\""), "empty config gains bridge_token")
}

@(test)
test_bridge_config_merge_existing_updates_daemon_url :: proc(t: ^testing.T) {
	existing := strings.concatenate({
		"# existing comment\n",
		"[wrapper]\n",
		"daemon_url = \"http://127.0.0.1:49322\"\n",
		"keep_me = true\n",
		"\n",
		"[daemon]\n",
		"daemon_id = \"old_id\"\n",
	})
	merged := bridge_config_merge(existing, "http://central-hub:9000", "", "new_id")
	testing.expect(t, !strings.contains(merged, "http://127.0.0.1:49322"), "old daemon_url was replaced")
	testing.expect(t, strings.contains(merged, "daemon_url = \"http://central-hub:9000\""), "new daemon_url present under [wrapper]")
	testing.expect(t, !strings.contains(merged, "old_id"), "old daemon_id was replaced")
	testing.expect(t, strings.contains(merged, "daemon_id = \"new_id\""), "new daemon_id present under [daemon]")
	testing.expect(t, strings.contains(merged, "keep_me = true"), "other keys preserved")
	testing.expect(t, strings.contains(merged, "# existing comment"), "comments preserved")
}

@(test)
test_bridge_config_merge_missing_wrapper_section :: proc(t: ^testing.T) {
	existing := strings.concatenate({
		"[daemon]\n",
		"daemon_id = \"old_id\"\n",
	})
	merged := bridge_config_merge(existing, "https://remote-hub.domain", "tok_999", "new_id")
	testing.expect(t, strings.contains(merged, "[wrapper]"), "missing [wrapper] appended")
	testing.expect(t, strings.contains(merged, "daemon_url = \"https://remote-hub.domain\""), "daemon_url present in appended [wrapper]")
	testing.expect(t, strings.contains(merged, "daemon_id = \"new_id\""), "daemon_id updated")
	testing.expect(t, strings.contains(merged, "bridge_token = \"tok_999\""), "bridge_token added")
}

@(test)
test_bridge_write_enrolled_config_file :: proc(t: ^testing.T) {
	tmp_path := fmt.tprintf("/tmp/ham-bridge-config-test-%d.toml", os.get_pid())
	defer os.remove(tmp_path)

	initial := "[wrapper]\ndaemon_url = \"http://old-hub:1111\"\n\n[daemon]\ndaemon_id = \"old_brg\"\n"
	_ = os.write_entire_file(tmp_path, transmute([]byte)initial)

	ok := bridge_write_enrolled_config(tmp_path, "http://new-hub:2222", "tok_new", "new_brg")
	testing.expect(t, ok, "bridge_write_enrolled_config succeeded")

	bytes, err := os.read_entire_file(tmp_path, context.allocator)
	testing.expect(t, err == nil, "read back config file")
	defer delete(bytes)

	content := string(bytes)
	testing.expect(t, strings.contains(content, "daemon_url = \"http://new-hub:2222\""), "file updated with new daemon_url")
	testing.expect(t, !strings.contains(content, "http://old-hub:1111"), "old url replaced in file")
	testing.expect(t, strings.contains(content, "daemon_id = \"new_brg\""), "file updated with new daemon_id")
}

// ===== bridge_config_from_args data_dir ~ expansion =====

@(test)
bridge_config_expands_default_data_dir_tilde :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	home := os.get_env_alloc("HOME", context.allocator)
	if strings.trim_space(home) == "" do return

	cfg := bridge_config_from_args([]string{"ham-bridge"})
	testing.expect(t, !strings.has_prefix(cfg.data_dir, "~"), "default data_dir must not keep a literal ~")
	testing.expect(t, strings.has_prefix(cfg.data_dir, home), "default data_dir should resolve under $HOME")
	testing.expect(t, strings.has_suffix(cfg.data_dir, "/.local/share/heimdall"), "default data_dir keeps the heimdall suffix")
}

@(test)
bridge_config_expands_data_dir_override_tilde :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	home := os.get_env_alloc("HOME", context.allocator)
	if strings.trim_space(home) == "" do return

	cfg := bridge_config_from_args([]string{"ham-bridge", "--data-dir", "~/custom-heimdall-dir"})
	testing.expect(t, !strings.has_prefix(cfg.data_dir, "~"), "override data_dir must not keep a literal ~")
	testing.expect_value(t, cfg.data_dir, strings.concatenate({home, "/custom-heimdall-dir"}))
}

@(test)
bridge_config_leaves_absolute_data_dir_untouched :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	cfg := bridge_config_from_args([]string{"ham-bridge", "--data-dir", "/var/lib/heimdall"})
	testing.expect_value(t, cfg.data_dir, "/var/lib/heimdall")
}
