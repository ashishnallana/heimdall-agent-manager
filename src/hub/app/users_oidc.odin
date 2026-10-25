package app

import "core:fmt"
import "core:strings"
import sqlite "odin_test:hub/repository/sqlite"

// users_oidc_link_command implements `ham-hub users link-oidc`, `unlink-oidc`
// (also ends the user's sessions), `logout` (ends every session) and
// `disable`/`enable`. --issuer defaults to the configured oidc_issuer.
// Prints a one-line result and returns (ok, error message).
users_oidc_link_command :: proc(conn: ^sqlite.Conn, configured_issuer, now, action, user_id, issuer_arg, subject: string) -> (bool, string) {
	issuer := issuer_arg if issuer_arg != "" else configured_issuer
	switch action {
	case "link-oidc":
		if user_id == "" || issuer == "" || subject == "" do return false, "usage: ham-hub users link-oidc --user <user_id> --issuer <iss> --subject <sub> (--issuer defaults to the configured oidc_issuer)"
		if strings.trim_space(issuer) != issuer || strings.trim_space(subject) != subject do return false, "--issuer and --subject must not have surrounding whitespace"
		ok, err := sqlite.user_link_external_sqlite(conn, user_id, issuer, subject, now)
		if !ok do return false, err.message
		fmt.printfln("linked user_id=%s issuer=%s subject=%s", user_id, issuer, subject)
		return true, ""
	case "unlink-oidc":
		if user_id == "" do return false, "usage: ham-hub users unlink-oidc --user <user_id> [--issuer <iss>]"
		removed, err := sqlite.user_unlink_external_sqlite(conn, user_id, issuer_arg)
		if err.code != .None do return false, err.message
		// The identity no longer maps to this user: end its browser sessions too.
		ended, session_err := sqlite.delete_user_sessions_sqlite(conn, user_id)
		if session_err.code != .None do return false, session_err.message
		fmt.printfln("unlinked user_id=%s links_removed=%d sessions_ended=%d", user_id, removed, ended)
		return true, ""
	case "logout":
		if user_id == "" do return false, "usage: ham-hub users logout --user <user_id>"
		ended, err := sqlite.delete_user_sessions_sqlite(conn, user_id)
		if err.code != .None do return false, err.message
		fmt.printfln("logged out user_id=%s sessions_ended=%d", user_id, ended)
		return true, ""
	case "disable", "enable":
		if user_id == "" do return false, strings.concatenate({"usage: ham-hub users ", action, " --user <user_id>"}, context.temp_allocator)
		changed, err := sqlite.user_set_status_sqlite(conn, user_id, action == "enable", now)
		if err.code != .None do return false, err.message
		if !changed do return false, "user not found"
		ended := 0
		if action == "disable" {
			// A disabled user is refused on every request anyway; ending the sessions
			// also stops long-lived streams at their next re-check.
			ended, err = sqlite.delete_user_sessions_sqlite(conn, user_id)
			if err.code != .None do return false, err.message
		}
		fmt.printfln("%sd user_id=%s sessions_ended=%d", action, user_id, ended)
		return true, ""
	}
	return false, "unknown users action"
}
