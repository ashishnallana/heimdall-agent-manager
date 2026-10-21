package shell_session

// REQ-SHELL-8 item 6: retention for terminal shell_sessions ROWS.
//
// Output got a 5-day window; the rows it belongs to had none. Every run and every
// server a bridge ever executed left a row behind forever, so the owner-wide list,
// the per-bridge list and the chain summary all degraded permanently and could
// never recover. This is the missing half.

import "core:fmt"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import events "odin_test:hub/service/events"
import "odin_test:hub/platform"

// HUB_SHELL_SESSION_ROW_RETENTION is how long a TERMINAL row survives after it
// ended. It is the middle link of the one ordered chain REQ-SHELL-8 maintains:
//
//     output 5 days  <  ROWS 7 days  <  tombstones 30 days
//
// GREATER THAN THE OUTPUT WINDOW, and that inequality is the requirement, not a
// preference: if rows expired first, a user would be shown a session whose output
// had already been reclaimed and get an error for every log they opened — the row
// would outlive the only thing it is good for. Keeping rows strictly longer instead
// means the opposite, benign case: for two days a row survives its output and says
// so explicitly, which is precisely what the .Gone answer exists to express.
//
// The other two windows live on the bridge, in src/bridge/shell_output_retention.odin
// (BRIDGE_SHELL_OUTPUT_RETENTION and BRIDGE_SHELL_TOMBSTONE_RETENTION), because that
// is where the files are. They are one chain across two processes: changing this
// number without checking those breaks a property that neither file can check alone.
HUB_SHELL_SESSION_ROW_RETENTION :: 7 * 24 * time.Hour

// shell_session_sweep_terminal_rows deletes terminal rows that ended more than
// HUB_SHELL_SESSION_ROW_RETENTION ago, and returns how many went.
//
// LIVE ROWS ARE NEVER TOUCHED, at any age. That is enforced by status in the SQL
// (built from domain.SHELL_SESSION_TERMINAL_STATUSES), not by a filter here, so no
// caller can pass an argument that makes a running server eligible. A server up for
// a month has a month-old row and keeps it.
//
// `now_rfc3339` is a parameter rather than a read of svc.clock so a test can place
// "now" days ahead and exercise the boundary without sleeping through it. Production
// passes platform.clock_now(svc.clock); an empty string falls back to that too, so a
// caller cannot accidentally sweep with no clock at all.
//
// REQ-SHELL-9 NOTE: this is the ONE terminal-row pass, called once from
// reaper_sweep_once. Server reaping should extend this proc or ride the same sweep
// call rather than adding a second walk of shell_sessions on the same cadence.
shell_session_sweep_terminal_rows :: proc(svc: ^Shell_Session_Service, now_rfc3339: string = "") -> (int, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return 0, domain.domain_error(.Internal_Error, "shell session service is not configured")

	now := now_rfc3339
	if now == "" do now = platform.clock_now(svc.clock)
	if now == "" do return 0, domain.domain_error(.Internal_Error, "shell session row retention has no clock")

	cutoff := shell_session_row_retention_cutoff(now)
	if cutoff == "" do return 0, domain.domain_error(.Internal_Error, "shell session row retention could not compute a cutoff")

	// REQ-2: one shell_session/pruned hint per owner that lost rows, so open
	// session lists and chain summaries refetch. Ids are not enumerated: the
	// rows are terminal, at least 7 days old and gone; the count is enough.
	owners, supported, del_err := iface.shell_session_delete_terminal_before_owners(svc.repo, cutoff)
	if !supported do return iface.shell_session_delete_terminal_before(svc.repo, cutoff)
	defer { for k in owners do delete(k); delete(owners) }
	total := 0
	for owner, n in owners {
		total += n
		if svc.events == nil do continue
		summary := fmt.tprintf("{{\"deleted\":%d}}", n)
		events.publish_resource_changed(svc.events, owner, "shell_session", "", "pruned", summary)
	}
	return total, del_err
}

// shell_session_row_retention_cutoff turns an RFC3339 UTC instant into the instant
// HUB_SHELL_SESSION_ROW_RETENTION before it, in the same spelling. Split out from
// the sweep so the arithmetic is testable on its own — an off-by-one here silently
// shifts the whole window, and a wrong window is not visible in a delete count.
//
// Returns "" if `now` is not the fixed-width UTC form every timestamp column holds,
// rather than guessing at a cutoff: a malformed cutoff compared against real rows
// could delete far more than intended, so refusing is the only safe failure.
shell_session_row_retention_cutoff :: proc(now_rfc3339: string) -> string {
	t, ok := platform.parse_rfc3339_utc(now_rfc3339)
	if !ok do return ""
	return platform.format_rfc3339_utc(time.time_add(t, -HUB_SHELL_SESSION_ROW_RETENTION))
}
