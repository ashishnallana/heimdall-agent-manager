package app

import "core:fmt"
import "core:strings"
import sqlite "odin_test:hub/repository/sqlite"

// users_oidc_link_command implements `ham-hub users link-oidc` and
// `ham-hub users unlink-oidc`. --issuer defaults to the configured oidc_issuer.
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
		fmt.printfln("unlinked user_id=%s links_removed=%d", user_id, removed)
		return true, ""
	}
	return false, "unknown users action"
}
