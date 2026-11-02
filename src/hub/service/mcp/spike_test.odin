package mcp

import "core:testing"
import auth "odin_test:hub/service/auth"

VERIFIER :: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
REDIRECT :: "https://client.example/callback?source=mcp"

@(test)
test_probe_pkce_binding_and_single_use :: proc(t: ^testing.T) {
	s: Store; init(&s); defer free(&s)
	client, registered := register(&s, REDIRECT)
	testing.expect(t, registered)
	code, ok := authorize(&s, "alice", client, REDIRECT, auth.pkce_challenge_s256(VERIFIER), 1000)
	testing.expect(t, ok)
	testing.expect_value(t, len(code), 1024)
	_, wrong := exchange(&s, code, client, REDIRECT, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 1001)
	testing.expect(t, !wrong)
	_, wrong = exchange(&s, code, "other-client", REDIRECT, VERIFIER, 1001)
	testing.expect(t, !wrong)
	_, wrong = exchange(&s, code, client, "https://attacker.example/", VERIFIER, 1001)
	testing.expect(t, !wrong)
	tokens, good := exchange(&s, code, client, REDIRECT, VERIFIER, 1002)
	testing.expect(t, good)
	testing.expect(t, validate(&s, tokens.access_token, 1003))
	_, replay := exchange(&s, code, client, REDIRECT, VERIFIER, 1003)
	testing.expect(t, !replay)
	testing.expect_value(t, len(s.codes), 0)
	testing.expect_value(t, len(tokens.access_token), 1024)
	_, stores_raw := s.access[tokens.access_token]
	testing.expect(t, !stores_raw)
}
@(test)
test_probe_expiry_refresh_and_token_types :: proc(t: ^testing.T) {
	s: Store; init(&s); defer free(&s)
	client, _ := register(&s, REDIRECT)
	code, _ := authorize(&s, "alice", client, REDIRECT, auth.pkce_challenge_s256(VERIFIER), 0)
	_, ok := exchange(&s, code, client, REDIRECT, VERIFIER, CODE_TTL)
	testing.expect(t, !ok)
	code, _ = authorize(&s, "alice", client, REDIRECT, auth.pkce_challenge_s256(VERIFIER), 0)
	tokens, made := exchange(&s, code, client, REDIRECT, VERIFIER, 1)
	testing.expect(t, made)
	testing.expect(t, !validate(&s, tokens.refresh_token, 2))
	testing.expect(t, !validate(&s, tokens.access_token, 1 + ACCESS_TTL))
	_, wrong := refresh(&s, tokens.refresh_token, "other-client", 2)
	testing.expect(t, !wrong)
	next, renewed := refresh(&s, tokens.refresh_token, client, 2)
	testing.expect(t, renewed)
	testing.expect(t, next.refresh_token != tokens.refresh_token)
	testing.expect(t, validate(&s, next.access_token, 3))
	_, replay := refresh(&s, tokens.refresh_token, client, 3)
	testing.expect(t, !replay)
	_, expired := refresh(&s, next.refresh_token, client, 2 + REFRESH_TTL)
	testing.expect(t, !expired)
}
@(test)
test_probe_registration_and_authorization_validation :: proc(t: ^testing.T) {
	s: Store; init(&s); defer free(&s)
	for uri in ([]string{"http://client.example/cb", "https://client.example/cb#fragment", "https://user@client.example/cb", "https:///cb", "https://client.example/\r\nX:bad", "https://client.example\\evil/cb"}) {
		_, ok := register(&s, uri)
		testing.expect(t, !ok)
	}
	client, _ := register(&s, REDIRECT)
	_, ok := authorize(&s, "", client, REDIRECT, auth.pkce_challenge_s256(VERIFIER), 0)
	testing.expect(t, !ok)
	_, ok = authorize(&s, "alice", client, REDIRECT, "plain", 0)
	testing.expect(t, !ok)
	_, ok = authorize(&s, "alice", client, "https://attacker.example/", auth.pkce_challenge_s256(VERIFIER), 0)
	testing.expect(t, !ok)
}

@(test)
test_probe_pending_resume_is_bounded_expiring_and_one_use :: proc(t: ^testing.T) {
	s: Store; init(&s); defer free(&s)
	ticket, ok := pending_begin(&s, "client_id=one&state=two", 1000)
	testing.expect(t, ok)
	form, found := pending_read(&s, ticket, 1001)
	testing.expect(t, found)
	testing.expect_value(t, form, "client_id=one&state=two")
	_, found = pending_read(&s, ticket, 1002, true)
	testing.expect(t, found)
	_, found = pending_read(&s, ticket, 1003, true)
	testing.expect(t, !found)
	ticket, _ = pending_begin(&s, "client_id=one", 1000)
	_, found = pending_read(&s, ticket, 301_000)
	testing.expect(t, !found)
}
