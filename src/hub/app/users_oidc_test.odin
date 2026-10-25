package app

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

@(test)
test_users_link_and_unlink_oidc_command :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, opened, _ := sqlite.open(":memory:")
	if !testing.expect(t, opened) do return
	defer sqlite.close(&conn)
	migrated, _ := sqlite.run_migrations(&conn)
	testing.expect(t, migrated)
	impl: sqlite.User_Repo_SQLite
	repo := sqlite.new_user_repository(&impl, &conn)
	issuer :: "https://auth.example.test/application/o/heimdall-native/"
	_, saved, _ := iface.user_save(&repo, domain.User{user_id = "alice", name = "alice", status = .Active, created_at = "now", updated_at = "now"})
	testing.expect(t, saved)
	ok: bool
	message: string

	ok, message = users_oidc_link_command(&conn, issuer, "now", "link-oidc", "alice", "", "")
	testing.expect(t, !ok, "subject is required")
	ok, message = users_oidc_link_command(&conn, issuer, "now", "link-oidc", "nobody", "", "sub-1")
	testing.expect(t, !ok, "unknown user refused")
	// --issuer defaults to the configured issuer.
	ok, message = users_oidc_link_command(&conn, issuer, "now", "link-oidc", "alice", "", "sub-1")
	testing.expect(t, ok, message)
	user, linked, _ := repo.resolve_external(repo.ctx, issuer, "sub-1", "", "", "", "now", false, false)
	testing.expect(t, linked)
	testing.expect_value(t, user.user_id, domain.User_ID("alice"))

	ok, message = users_oidc_link_command(&conn, issuer, "now", "unlink-oidc", "alice", "https://other.example/", "")
	testing.expect(t, ok, message)
	_, still, _ := repo.resolve_external(repo.ctx, issuer, "sub-1", "", "", "", "now", false, false)
	testing.expect(t, still, "other issuer's unlink leaves the link")
	ok, message = users_oidc_link_command(&conn, issuer, "now", "unlink-oidc", "alice", "", "")
	testing.expect(t, ok, message)
	_, gone, _ := repo.resolve_external(repo.ctx, issuer, "sub-1", "", "", "", "now", false, false)
	testing.expect(t, !gone, "unlinked")
	ok, _ = users_oidc_link_command(&conn, issuer, "now", "unlink-oidc", "", "", "")
	testing.expect(t, !ok, "--user is required")
}

@(test)
test_legacy_auth_mode_refused_and_auto_provision_default :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	ok, msg := check_legacy_auth_mode("", false)
	testing.expect(t, ok)
	for value in ([]string{"oidc", "trusted_proxy", ""}) {
		ok, msg = check_legacy_auth_mode(value, true)
		testing.expect(t, !ok, value)
		testing.expect(t, len(msg) > 0 && contains_all(msg, "HAM_AUTH_MODE", "HAM_OIDC_ISSUER", "HAM_OIDC_API_SCOPE"), msg)
	}
	config := default_config()
	testing.expect(t, effective_auto_provision_users(config), "without OIDC: provisioning stays on")
	config.oidc_issuer = "https://auth.example.test/"
	testing.expect(t, !effective_auto_provision_users(config), "with OIDC: off by default")
	config.auto_provision_users_setting = true
	testing.expect(t, effective_auto_provision_users(config), "explicit true honoured")
	config.oidc_issuer = ""
	config.auto_provision_users_setting = false
	testing.expect(t, !effective_auto_provision_users(config), "explicit false honoured")
	v, parsed := parse_bool_setting(" TRUE ")
	testing.expect(t, v && parsed)
	_, parsed = parse_bool_setting("yes")
	testing.expect(t, !parsed)
}

@(private = "file")
contains_all :: proc(s: string, parts: ..string) -> bool {
	for p in parts {
		found := false
		for i := 0; i + len(p) <= len(s); i += 1 {if s[i:i + len(p)] == p {found = true; break}}
		if !found do return false
	}
	return true
}
