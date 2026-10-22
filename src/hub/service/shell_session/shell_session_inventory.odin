package shell_session

// REQ-SHELL-10 — the HUB HALF of the convergence protocol: apply one bridge's full
// session inventory and converge this hub's rows onto it.
//
// The chain's core invariant says no shell may be (a) running on a bridge but
// untracked by the hub, (b) marked live on the hub but not running on the bridge, or
// (c) un-killable. Everything else in the chain pursues those leak by leak — the exit
// outbox (REQ-SHELL-4) covers disconnect, the kill replay (REQ-SHELL-3) covers
// intent, the bridge's reconcile pass covers orphans. Each is sound, but a set of
// patches is only ever as complete as our list of failure modes. THIS is the part
// that needs no such list: the bridge states its whole truth, and every divergence,
// listed or not, falls out of one diff.
//
// THE FOUR BRANCHES, and what decides each:
//   hub row live, NOT in the inventory -> it died while we were away  -> TERMINAL
//   in the inventory, NO hub row       -> running untracked           -> ADOPT
//   status disagrees                   -> THE BRIDGE WINS             -> CORRECT
//   live row carrying a kill intent    -> deliver it now              -> REPLAY
//
// THE BRIDGE WINS, AND WHY THAT IS NOT MERELY A TIE-BREAK. The bridge owns the
// processes. Its inventory is built from the pty-host roster plus a ps check on each
// direct child (bridge_shell_session_reconcile), i.e. from OBSERVATION of the
// operating system; the hub's row is a memory of what it was last told. An
// observation beats a memory, which is the same rule
// domain.shell_session_terminal_is_observed already encodes for exits, applied to
// liveness instead of to death.
//
// WHAT THIS DOES NOT OWN. It is triggered by an inventory, i.e. BY A RECONNECT. A
// bridge that never comes back never sends one, so this never fires for it and the
// rows would report live forever — that is REQ-SHELL-14's half, and neither task may
// assume the other covers its case. The two compose in one specific place, handled in
// _apply_entry below: REQ-SHELL-14 lands a SYNTHESIZED terminal status on a bridge
// judged gone, and if that bridge returns with the process still alive, this diff is
// the only thing that can correct it.
//
// SCOPE. A single inventory mutates MANY rows, so "a bridge may only touch its own
// sessions" carries more weight here than anywhere else in this service. It is
// enforced twice and structurally, not by inspection: the row set comes from
// list_live_by_bridge (bridge-scoped SQL) and every entry is resolved with
// get_by_id(bridge_id, session_id) (bridge-scoped SQL), so an inventory from bridge A
// naming bridge B's session resolves to nothing and changes nothing on B.

import agent_service "odin_test:hub/service/agent"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import domain "odin_test:hub/domain"
import events "odin_test:hub/service/events"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"
import iface "odin_test:hub/repository/iface"

// SHELL_SESSION_INVENTORY_MAX_ROWS bounds the hub side of one diff, mirroring the
// bridge's BRIDGE_SHELL_INVENTORY_MAX_ENTRIES and, like it, a runaway backstop rather
// than pagination. Set ABOVE the bridge's cap on purpose: if a bound is going to bite
// it should be the one that can report that it bit (the bridge's `truncated` flag),
// not this one, which would silently shorten the row set and make live rows look
// absent.
SHELL_SESSION_INVENTORY_MAX_ROWS :: 1024

// SHELL_SESSION_INVENTORY_UNOBSERVED_TERMINAL is the status this diff lands on a
// session the bridge no longer lists.
//
// `failed` rather than `exited`, and the distinction is about what the hub is
// entitled to claim. `exited` reads as "ran to completion", which we did not see and
// have no exit code for; `failed` reads as "ended, and not verifiably well", which is
// exactly the truth: the bridge was away, the process ended at some point we did not
// observe. `killed` is excluded outright — nobody killed it.
//
// EXIT_CODE_SET IS DELIBERATELY LEFT FALSE here, and it is not an omission. It is the
// discriminator domain.shell_session_terminal_is_observed reads to tell a guess from
// an observation, and that predicate's own documentation makes this a CONDITION on
// the whole mechanism: the moment a hub-side path stamps a fabricated exit code, a
// guess starts outranking ground truth and the supersession in
// shell_session_handle_exited silently stops working. So this path records no code,
// and a late real exit from the bridge's durable outbox can still correct it.
//
// REQ-SHELL-14 lands a terminal status on the sessions of a bridge that never
// returns, which is the same KIND of claim made for a different reason. It should use
// this same spelling, for the same reasoning, rather than a second one.
SHELL_SESSION_INVENTORY_UNOBSERVED_TERMINAL :: domain.Shell_Session_Status_Failed

// Shell_Session_Inventory_Entry is one live session as the bridge reported it.
// Field-for-field the bridge's frame (bridge_shell_inventory_write_entry), which is
// itself field-for-field the bridge's on-disk session spec, so the three spellings
// cannot drift apart into a translation table nobody maintains.
Shell_Session_Inventory_Entry :: struct {
	session_id:        string `json:"session_id"`,
	kind:              string `json:"kind"`,
	status:            string `json:"status"`,
	shell_id:          string `json:"shell_id"`,
	started_at:        string `json:"started_at"`,
	label:             string `json:"label"`,
	cmd:               string `json:"cmd"`,
	cwd:               string `json:"cwd"`,
	owner_user_id:     string `json:"owner_user_id"`,
	project_id:        string `json:"project_id"`,
	chain_id:          string `json:"chain_id"`,
	agent_instance_id: string `json:"agent_instance_id"`,
	background:        bool   `json:"background"`,
	pid:               int    `json:"pid"`,
	server_port:       int    `json:"server_port"`,
	run_seq:           int    `json:"run_seq"`,
}

Shell_Session_Inventory_Frame :: struct {
	type:      string                         `json:"type"`,
	bridge_id: string                         `json:"bridge_id"`,
	truncated: bool                           `json:"truncated"`,
	sessions:  []Shell_Session_Inventory_Entry `json:"sessions"`,
}

// Shell_Session_Inventory_Result reports what one diff did. Counters rather than a
// bare bool because the branches mean very different things operationally — adopting
// a session says the hub lost a create, terminating one says it lost an exit — and
// because a test asserting "the second apply changed nothing" needs to see zeros
// rather than infer them.
Shell_Session_Inventory_Result :: struct {
	adopted:     int, // running untracked -> row created
	terminated:  int, // live here, absent there -> unobserved terminal
	corrected:   int, // status disagreed -> the bridge's status written
	revived:     int, // hub said terminal, bridge says running -> back to live
	conflicted:  int, // bridge says running but the hub OBSERVED this run end
	ignored:     int, // unusable entry (no id, unknown kind/status, bad scope)
	kills_replayed: int,
	reattached:  int, // live here, still viewed, stream re-armed on the bridge (REQ-SHELL-40)
}

// shell_session_inventory_changed answers whether a diff wrote anything, and it is the
// honest form of "did this matter" — `ignored` is deliberately excluded, since refusing
// an entry changes no row.
//
// IT NO LONGER GATES THE KILL REPLAY, and must not be wired back to it (REQ-SHELL-23).
// Whether an inventory found discrepancies and whether a durable kill is outstanding
// are unrelated facts; joining them disabled the replay in exactly the case it exists
// for, since a clean inventory is the case where the outstanding kill is the ONLY thing
// wrong. Its remaining use is what it is actually for: asserting the idempotency of
// apply_inventory in tests.
// `reattached` is excluded for the same reason as `ignored` and `kills_replayed`: it
// writes no row. A healthy reconnect with a pane open re-attaches and changes nothing,
// and the idempotency assertions built on this predicate must keep reading zero there.
shell_session_inventory_changed :: proc(r: Shell_Session_Inventory_Result) -> bool {
	return r.adopted > 0 || r.terminated > 0 || r.corrected > 0 || r.revived > 0
}

// shell_session_apply_inventory applies one `shell_inventory` frame from `bridge_id`.
//
// IDEMPOTENT, and by construction rather than by a delivery counter: every branch
// below is conditioned on an ACTUAL divergence, so applying the same inventory twice
// writes nothing and publishes nothing the second time. That is what makes reconnect
// flapping harmless — a bridge that connects five times in a minute produces one
// convergence and four no-ops (work item 5).
shell_session_apply_inventory :: proc(svc: ^Shell_Session_Service, bridge_id, frame_json: string) -> Shell_Session_Inventory_Result {
	result: Shell_Session_Inventory_Result
	if svc == nil || svc.repo == nil || bridge_id == "" do return result

	frame, ok := shell_session_inventory_parse_frame(frame_json)
	if !ok do return result
	entries := frame.sessions
	defer delete(entries)
	truncated := frame.truncated

	// BORROWED, NEVER DELETED. platform.clock_now bottoms out in fmt.tprintf, so what
	// it returns lives in the temp allocator's arena and was never a heap block —
	// handing it to delete()/free() is an invalid free that segfaults the process.
	// This was the only one of the hub's ~135 clock_now call sites to free its result;
	// every other one treats the value as borrowed, which is the contract. Because an
	// inventory frame is what a bridge sends on RECONNECT, the bad free made bridge
	// reconnection a reliable way to crash the hub.
	//
	// Nothing below needs `now` to outlive this call: the upserts bind it as SQLite
	// text (copied at bind time) and the events publish it into their own buffers.
	now := platform.clock_now(svc.clock)

	// Pass 1 — every entry the bridge reported: adopt, correct, revive.
	for entry in entries {
		_apply_inventory_entry(svc, bridge_id, entry, now, &result)
	}

	// Pass 2 — rows the hub still believes are live that the inventory does not name.
	//
	// SKIPPED ENTIRELY FOR A TRUNCATED INVENTORY. This branch reasons from ABSENCE,
	// and a truncated list cannot establish absence — it establishes only that the
	// bridge ran out of room. Concluding death from a full buffer would kill off rows
	// for processes that are alive and were simply not mentioned, which is a worse
	// failure than the stale row it was trying to fix. Pass 1 still applies: adopting
	// and correcting reason from PRESENCE, which truncation does not weaken.
	if !truncated {
		_reap_inventory_absent(svc, bridge_id, entries, now, &result)
	}

	// INVARIANT (c), and the reason it needs restating here. The reconnect kill replay
	// (shell_session_replay_kill_intents) runs on the bridge-WS accept path, which is
	// STRICTLY EARLIER than this frame — the inventory cannot arrive before the
	// connection it travels on is up. So a session this diff has just ADOPTED or
	// REVIVED was not in the row set that replay read, and a durable kill standing
	// against it would wait for an entire further reconnect that may never come.
	// Re-running the replay closes that window.
	//
	// Re-running in full is safe and is not a special case: the replay is documented
	// as idempotent because the bridge no-ops a kill against a session it has already
	// marked terminal, which is exactly why it can be re-issued without tracking what
	// was delivered before.
	//
	// UNCONDITIONAL, AND THE GATE THAT USED TO BE HERE WAS THE SECOND HALF OF
	// REQ-SHELL-23. This read `if shell_session_inventory_changed(result)`, so the one
	// path that could deliver a kill AFTER the bridge had rebuilt its session map ran
	// only when the diff had also found something else wrong. In the reproduction that
	// exposed this, the row already agreed with the roster in every field — status
	// running, correct pid — so the diff was a clean no-op, the gate was false, and the
	// outstanding kill was skipped precisely BECAUSE nothing else was broken. The
	// healthier the rest of the state, the more reliably the kill was dropped.
	//
	// The "a no-op inventory is a no-op end to end" promise in this procedure's header
	// is unchanged in the sense that matters and narrowed in the sense that does not:
	// it was always a promise about WRITES and PUBLISHES, and those are still gated by
	// the per-branch divergence checks above. What is no longer gated is one
	// bridge-scoped indexed SELECT (migration 050's partial index) that returns the
	// empty set on every reconnect where no kill is pending — which is every reconnect
	// in normal operation. Paying for one empty read per inventory to stop silently
	// discarding a durable kill is not a close trade.
	//
	// No intent handling of our own lives here, deliberately: REQ-SHELL-3 owns the
	// intent, and its structural auto-clear retires one the moment any terminal status
	// lands — including the ones written above.
	result.kills_replayed, _ = shell_session_replay_kill_intents(svc, bridge_id)

	// Pass 3 — REQ-SHELL-40. Re-arm the OUTPUT STREAM of every session that is still
	// being watched. This is the third leak of core invariant (b), and the only one
	// that is not about a row.
	//
	// THE INVARIANT, then the mechanism, then what breaks without it.
	//
	// REQUIREMENT: a session the hub reports as live AND has at least one viewer for
	// must have a running stream worker on its bridge. Both halves of that are needed;
	// a row that says "running" while nothing carries its bytes is a lie the UI renders
	// as a frozen pane.
	//
	// MECHANISM: the hub only ever asked the bridge to attach on the 0->1 VIEWER
	// transition (shell_session_attach). That is edge-triggered on the BROWSER side,
	// and a bridge reconnect is not an edge on the browser side — from the hub's point
	// of view no viewer ever left, so no viewer ever arrives, so nothing re-attaches.
	// The bridge meanwhile comes back with zero stream workers (it tears them down with
	// the connection they belong to; see bridge_pty_stream_stop_all_for_reconnect).
	// This pass supplies the missing edge: the reconnect itself.
	//
	// CONSEQUENCE IF YOU REMOVE IT: every pane open at the moment of any reconnect — a
	// WS blip, a deploy, a bridge restart — goes permanently silent, and recovers only
	// if the user happens to switch tabs, because unmount/remount is the only other
	// thing in the system that produces a 0->1 transition. Not time, not a heartbeat,
	// not the next inventory. That is what this pass exists to make impossible, so if
	// you replace the mechanism, preserve the property: SOMETHING must re-issue attach
	// for a still-viewed session after the bridge's worker set is emptied.
	//
	// WHY IT BELONGS HERE AND NOT ON THE ACCEPT PATH. It must run AFTER both passes
	// above, because "still live" is a fact those passes may have just changed — Pass 2
	// can have terminated this very session. Running it on the bridge-WS accept path
	// (where the kill replay runs) would read rows the inventory had not corrected yet
	// and could re-attach a session the bridge is about to tell us is dead.
	//
	// LIVENESS COMES FROM THE INVENTORY, NOT FROM A ROW READ. `entries` is the bridge's
	// own observation, which is the rule T10 already applies everywhere else, and it
	// costs no query. The terminal filter matches _apply_inventory_entry exactly: an
	// entry with no status, or a terminal one, is not evidence of a live process.
	_reattach_viewed_sessions(svc, bridge_id, entries[:], &result)
	return result
}

// _reattach_viewed_sessions re-issues shell_stream_attach for every session in `entries`
// that this bridge owns, that the bridge reports live, and that still has a viewer.
//
// IDEMPOTENT AT EVERY LAYER, which matters because this fires on every reconnect and a
// flapping bridge can fire it repeatedly in seconds:
//   - here: sends are derived from the viewer map, so a session with no viewer is never
//     touched, and the count of sends per reconnect is bounded by the inventory size;
//   - on the bridge: bridge_pty_stream_worker_start returns early when a live worker
//     already exists for that session id, so a duplicate attach CANNOT create a second
//     worker or a second pty-host socket — a storm costs N no-ops, not N workers;
//   - against a racing viewer: the decision is made under svc.mu from one consistent
//     snapshot, so a genuine attach/detach landing concurrently either is already
//     visible here (and we skip, because the bridge dedupes) or lands after (and does
//     its own 0->1 attach). Neither ordering yields a session with viewers and no
//     worker, which is the only outcome that would matter.
//
// WHY THE SENDS HAPPEN OUTSIDE THE LOCK. Same discipline as shell_session_attach and
// shell_session_detach: the command sink writes to a socket, and holding svc.mu across a
// write would put a viewer-registry lock behind network IO for every attached pane at
// once. The snapshot is taken under the lock and the IO is done after it.
@(private = "file")
_reattach_viewed_sessions :: proc(
	svc: ^Shell_Session_Service,
	bridge_id: string,
	entries: []Shell_Session_Inventory_Entry,
	result: ^Shell_Session_Inventory_Result,
) {
	if svc == nil || bridge_id == "" || len(entries) == 0 do return
	heap := runtime.heap_allocator()

	// HEAP, NOT TEMP, and this is the same trap bridge_runtime.send_runtime_command_wait
	// documents. The loop below calls platform.generate_id, which is fmt.tprintf memory
	// from the per-thread temp allocator ring; ids held in that same ring could be
	// rewritten IN PLACE underneath us once it wraps, and the symptom would not be a
	// crash but an attach sent for the wrong session id, intermittently and only under
	// load. Heap copies make that impossible rather than merely unlikely.
	targets := make([dynamic]string, 0, len(entries), heap)
	defer {
		for t in targets do delete(t, heap)
		delete(targets)
	}

	sync.mutex_lock(&svc.mu)
	for entry in entries {
		if entry.session_id == "" do continue
		// Same liveness test as _apply_inventory_entry: the bridge may only assert life
		// here, and a terminal or empty status asserts nothing.
		if entry.status == "" || domain.shell_session_status_is_terminal(entry.status) do continue
		viewers, has_viewers := svc.viewers[entry.session_id]
		if !has_viewers || len(viewers) == 0 do continue
		// Bridge-scoped, so an inventory from bridge A can never make the hub send an
		// attach to bridge B for a session A merely named. The same reasoning as the
		// row-scoping checks in _apply_inventory_entry, applied to a command instead of
		// a write.
		owner_bridge, known := svc.session_bridges[entry.session_id]
		if !known || owner_bridge != bridge_id do continue
		append(&targets, strings.clone(entry.session_id, heap))
	}
	sync.mutex_unlock(&svc.mu)

	for session_id in targets {
		cmd_id := ""
		if svc.ids != nil {
			cmd_id = platform.generate_id(svc.ids, "cmd_sh_attach_")
		}
		cmd_json := _shell_stream_attach_command_json(cmd_id, session_id)
		defer delete(cmd_json)
		sent, _ := project_service.bridge_command_send_runtime(
			svc.bridge_command_sink,
			project_service.Runtime_Command{
				bridge_id  = bridge_id,
				command_id = cmd_id,
				body_json  = cmd_json,
			},
		)
		// COUNTED ONLY WHEN THE SEND SUCCEEDED. Every defect on this chain survived by
		// being silent, and a counter that logged an intent rather than a delivery is
		// how REQ-SHELL-23's dropped kill went unnoticed for a day. A send can fail here
		// even mid-reconnect: the command socket is registered before the inventory
		// arrives, but it can drop again between the two.
		// AC5. LOGGED PER SESSION, WITH THE ID AND THE REASON, and logged HERE rather
		// than at the transport call site even though the kill replay sets the opposite
		// precedent (bridge_handlers.odin logs what the service returns). The precedent
		// works there because a count is the whole story: "N kills outstanding, M
		// delivered" is actionable on its own. Here it is not — the first question about
		// a pane that went quiet is WHICH pane, and only this loop holds the session id.
		// Returning the ids to the transport purely to log them would mean allocating and
		// handing back a string list on every reconnect to say something this line can
		// say for free.
		//
		// Both outcomes are logged, not just the happy one. A re-attach that failed to
		// send is precisely the case where a pane stays dead, so it is the line an
		// operator needs most; logging only successes would recreate the silence this
		// whole task exists to remove.
		if sent {
			result.reattached += 1
			fmt.println("shell stream re-attach", "session=", session_id, "bridge=", bridge_id, "reason=", "bridge_reconnect")
		} else {
			fmt.println("shell stream re-attach FAILED: viewer is attached but the bridge has no stream worker", "session=", session_id, "bridge=", bridge_id, "reason=", "bridge_reconnect")
		}
	}
}

// _apply_inventory_entry converges one session the bridge says is LIVE.
@(private = "file")
_apply_inventory_entry :: proc(
	svc: ^Shell_Session_Service,
	bridge_id: string,
	entry: Shell_Session_Inventory_Entry,
	now: string,
	result: ^Shell_Session_Inventory_Result,
) {
	if entry.session_id == "" {
		result.ignored += 1
		return
	}
	// The bridge may only report LIVE sessions here. A terminal status arriving in an
	// inventory is refused rather than applied: ending a session is the exit path's
	// job, that path carries the exit code this frame does not, and accepting a
	// terminal status here would be a second way to kill a row with weaker evidence.
	if _, known := domain.shell_session_kind_from_string(entry.kind); !known {
		result.ignored += 1
		return
	}
	if entry.status == "" || domain.shell_session_status_is_terminal(entry.status) {
		result.ignored += 1
		return
	}

	// Bridge-scoped lookup: an entry naming another bridge's session finds nothing
	// here and falls through to the adopt path, where the row it builds carries THIS
	// bridge's id — so bridge A can never write a row belonging to bridge B.
	row, found, err := iface.shell_session_get_by_id(svc.repo, bridge_id, entry.session_id)
	if err.code != .None {
		result.ignored += 1
		return
	}
	if !found {
		_adopt_inventory_entry(svc, bridge_id, entry, now, result)
		return
	}
	defer domain.shell_session_destroy(row)

	// Belt and braces over the bridge-scoped SQL above. The query cannot return
	// another bridge's row, but this is the one path in the service that writes many
	// rows from one untrusted frame, and shell_session_handle_exited makes the same
	// check for the same reason.
	if row.bridge_id != bridge_id do return

	// `next` shares every string with `row`, which still owns them and frees them on
	// the defer above. Assigning a field of `next` only repoints that copy, so the
	// upsert reads a coherent record and nothing is double-freed or leaked.
	next := row
	changed := false

	if domain.shell_session_is_terminal(row) {
		// "HUB SAYS TERMINAL, BRIDGE SAYS RUNNING" — the direction REQ-SHELL-14 depends
		// on this diff to handle, so it is a DECISION rather than an unhandled case.
		//
		// ADOPT THE BRIDGE'S REALITY. Reasoning:
		//  - A terminal status the hub holds in this situation is necessarily a GUESS. A
		//    bridge-OBSERVED terminal means that bridge waited on the child and saw it
		//    end, and it would not then list the session as live. So the conflict is
		//    guess-versus-observation, and the guess loses — the same ordering
		//    domain.shell_session_terminal_is_observed already imposes on exits.
		//  - The alternative, killing the process because the hub already reported it
		//    dead, destroys live work on the strength of a record the bridge has just
		//    contradicted. That is the failure the convert-not-kill call sites in
		//    bridge_ws_disconnect exist to prevent, and it would make REQ-SHELL-14's
		//    guess LETHAL rather than merely provisional.
		//
		// THE ONE EXCEPTION: a terminal the hub OBSERVED, for the run the bridge is
		// reporting. That is a genuine contradiction rather than a stale guess, and the
		// safe move is to leave the observation standing and count it, not to resurrect
		// a row on the strength of a claim we can prove conflicts with something we
		// watched happen. A NEWER run (run_seq ahead of the row's) is not that case: the
		// bridge has since restarted the session and is describing a different run, so
		// it wins as usual.
		if domain.shell_session_terminal_is_observed(row) && entry.run_seq <= row.run_seq {
			result.conflicted += 1
			return
		}
		next.status      = entry.status
		next.finished_at = ""
		result.revived += 1
		changed = true
	} else if row.status != entry.status {
		next.status = entry.status
		result.corrected += 1
		changed = true
	}

	// The pid is the bridge's to report — it is the process identity it observed — so
	// a drifted pid is corrected alongside the status rather than left pointing at a
	// pid that may since have been recycled.
	//
	// run_seq is NOT taken from the entry, and that asymmetry is deliberate: it is
	// HUB-ASSIGNED and bridge-echoed (REQ-SHELL-4), incremented only by
	// shell_session_restart. Accepting the bridge's copy would let a bridge running an
	// old spec rewind the row's run counter and make a genuinely stale exit look
	// current. It is read here only for the comparison above.
	if entry.pid > 0 && entry.pid != row.pid {
		next.pid = entry.pid
		changed = true
	}

	if !changed do return
	next.last_activity_at = now
	// REQ-2: publish a correction only once it is durable.
	if _, up_err := iface.shell_session_upsert(svc.repo, next); up_err.code == .None do _publish_inventory_change(svc, row.owner_user_id, next.session_id, next.status)
}

// _adopt_inventory_entry creates a row for a session running untracked — invariant
// (a). This is the branch that turns "the hub lost the create" from a permanent leak
// into a session that shows up, can be listed, and can be killed.
@(private = "file")
_adopt_inventory_entry :: proc(
	svc: ^Shell_Session_Service,
	bridge_id: string,
	entry: Shell_Session_Inventory_Entry,
	now: string,
	result: ^Shell_Session_Inventory_Result,
) {
	adopted := domain.Shell_Session{
		session_id        = entry.session_id,
		owner_user_id     = entry.owner_user_id,
		// THIS bridge's id, never one the frame could name: adoption is the one branch
		// that creates a row, so it is the one place a forged entry could otherwise
		// manufacture a session attributed to somebody else's bridge.
		bridge_id         = bridge_id,
		project_id        = entry.project_id,
		chain_id          = entry.chain_id,
		agent_instance_id = entry.agent_instance_id,
		kind              = entry.kind,
		label             = entry.label,
		cmd               = entry.cmd,
		cwd               = entry.cwd,
		status            = entry.status,
		pid               = entry.pid,
		server_port       = entry.server_port,
		background        = entry.background,
		// HUB-ASSIGNED everywhere else, but there is no hub row to assign from here —
		// the bridge's echo is the only record of which run this is, and taking it is
		// what keeps a later exit for this run from being discarded as stale.
		run_seq           = entry.run_seq,
		started_at        = entry.started_at,
		created_at        = now,
		last_activity_at  = now,
	}

	// An owner is not optional: every read path in this service is owner-scoped, so a
	// row without one is invisible to its user and unkillable through the API — a
	// worse outcome than the untracked process it was meant to fix.
	// TRIMMED, not merely non-empty: this value arrives over the wire, and an owner of
	// " " passes an emptiness check while being just as unusable as "" — every
	// owner-scoped read would miss it, leaving exactly the invisible, unkillable row
	// this guard exists to prevent.
	if strings.trim_space(adopted.owner_user_id) == "" {
		result.ignored += 1
		return
	}
	// The kind's scope contract, enforced by the domain's own validator rather than
	// re-expressed here. An entry that cannot name its scope is REFUSED rather than
	// stored: a row that violates the scope rules would be returned by the wrong
	// listings for the rest of its life, and REQ-SHELL-1 §5 requires that enforcement
	// in the service layer, not only at create.
	if _, _, ok := domain.shell_session_validate_scope(adopted); !ok {
		result.ignored += 1
		return
	}

	if _, upsert_err := iface.shell_session_upsert(svc.repo, adopted); upsert_err.code != .None {
		result.ignored += 1
		return
	}
	result.adopted += 1
	_publish_inventory_change(svc, adopted.owner_user_id, adopted.session_id, adopted.status)
}

// _reap_inventory_absent lands an unobserved terminal status on every live row of
// this bridge the inventory did not name — invariant (b) for the reconnect case.
@(private = "file")
_reap_inventory_absent :: proc(
	svc: ^Shell_Session_Service,
	bridge_id: string,
	entries: []Shell_Session_Inventory_Entry,
	now: string,
	result: ^Shell_Session_Inventory_Result,
) {
	rows, err := iface.shell_session_list_live_by_bridge(svc.repo, bridge_id, SHELL_SESSION_INVENTORY_MAX_ROWS)
	if err.code != .None do return
	defer domain.shell_sessions_destroy(rows)

	for row in rows {
		if row.bridge_id != bridge_id do continue // see the same check in _apply_inventory_entry
		named := false
		for entry in entries {
			if entry.session_id == row.session_id { named = true; break }
		}
		if named do continue

		next := row // shares strings with `row`, which still owns them — see _apply_inventory_entry
		next.status           = SHELL_SESSION_INVENTORY_UNOBSERVED_TERMINAL
		next.finished_at      = now
		next.last_activity_at = now
		// exit_code / exit_code_set are left exactly as the row had them: this path
		// observed nothing and must fabricate nothing. See
		// SHELL_SESSION_INVENTORY_UNOBSERVED_TERMINAL.
		_, term_up_err := iface.shell_session_upsert(svc.repo, next)
		result.terminated += 1

		// The SAME shape the bridge-reported terminal path uses
		// (shell_session_handle_exited), not a new one: the owner event, then the
		// viewer broadcast. A client must not have to learn a second way to hear that a
		// session ended depending on which mechanism noticed. REQ-2: only when the
		// terminal row was actually written.
		if term_up_err.code == .None {
			agent_service.tool_live_shell(svc.live_agents, next, false)
			if svc.events != nil {
				evt := _shell_exited_event_json(next.session_id, next.status, 0, false)
				events.publish_owned(svc.events, next.owner_user_id, evt)
			}
			shell_session_broadcast_status(svc, next.session_id, next.status, 0, false)
		}
		if svc.on_unobserved_terminal != nil {
			svc.on_unobserved_terminal(svc.on_unobserved_terminal_ctx, next)
		}
	}
}

// shell_session_reap_gone_bridge lands an unobserved terminal status on EVERY live row
// of one bridge — invariant (b) for the NEVER-CAME-BACK case (REQ-SHELL-14).
//
// IT IS DELIBERATELY A THIN CALL INTO _reap_inventory_absent WITH NO ENTRIES, and lives
// in this file rather than in the reaper or the service, for three reasons:
//
//  1. THE ROW WORK IS IDENTICAL AND MUST STAY IDENTICAL. "Sessions this bridge is not
//     reporting" is the same claim whether the silence is one inventory that omitted
//     them or an absence long enough to call the bridge gone. An inventory naming
//     nothing and no inventory at all are the same evidence about the rows. Passing no
//     entries means nothing is "named", so every live row of the bridge is reaped — and
//     it reuses the `failed` spelling, the untouched exit_code, and the existing event
//     pair rather than restating any of them.
//  2. THE REASONING IS HERE. SHELL_SESSION_INVENTORY_UNOBSERVED_TERMINAL's comment
//     instructs this task to reuse its spelling, and the header's compose note explains
//     how a synthesized terminal is corrected if the bridge returns. A copy in another
//     package would drift from both.
//  3. exit_code_set STAYS FALSE, which is a condition on the whole mechanism rather
//     than a preference: it is what domain.shell_session_terminal_is_observed reads to
//     tell a guess from an observation. Fabricating a code here would make this guess
//     outrank ground truth, breaking REQ-SHELL-4's supersession AND the revive below.
//
// THE CALLER OWNS THE "IS IT GONE" JUDGEMENT. This proc does not look at a clock or a
// threshold; it is told to reap and it reaps. Age lives in the sweep (app/reaper.odin)
// next to the constant that justifies it, so this stays testable by calling it directly.
//
// WHY BEING EARLY IS SURVIVABLE: if the bridge returns with the process still alive, its
// inventory revives the row (`revived`, and _apply_inventory_entry's terminal-vs-running
// branch). That is not a nicety — it is what makes a time-based judgement about a remote
// machine acceptable at all, so it is asserted by test, not assumed.
//
// Returns how many rows were moved, for the sweep's logging and for tests.
shell_session_reap_gone_bridge :: proc(svc: ^Shell_Session_Service, bridge_id: string, now: string) -> int {
	if svc == nil || svc.repo == nil || bridge_id == "" do return 0
	result: Shell_Session_Inventory_Result
	_reap_inventory_absent(svc, bridge_id, nil, now, &result)
	return result.terminated
}

// _publish_inventory_change announces an adopt/correct/revive.
//
// resource_changed, the bus's existing generic shape, rather than a new event type:
// these are not exits, so _shell_exited_event_json would be a lie, and REQ-SHELL-6
// renders a session's state from the row it fetches. Adding a bespoke frame would
// give the UI a second thing to learn for a change it already knows how to refetch.
@(private = "file")
_publish_inventory_change :: proc(svc: ^Shell_Session_Service, owner_user_id, session_id, status: string) {
	if svc == nil || svc.events == nil || owner_user_id == "" do return
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "{\"status\":\"")
	strings.write_string(&b, status)
	strings.write_string(&b, "\"}")
	events.publish_resource_changed(svc.events, owner_user_id, "shell_session", session_id, "status_changed", strings.to_string(b))
	shell_session_broadcast_status(svc, session_id, status, 0, false)
}

// --- frame parsing -----------------------------------------------------------

// shell_session_inventory_parse_frame unmarshals a full shell_inventory frame into
// a typed Shell_Session_Inventory_Frame.
//
// Strings and intermediate values are decoded on context.temp_allocator, while the
// sessions slice itself is allocated with `allocator` (defaults to context.allocator)
// according to caller ownership.
shell_session_inventory_parse_frame :: proc(frame_json: string, allocator := context.allocator) -> (frame: Shell_Session_Inventory_Frame, ok: bool) {
	temp_frame: Shell_Session_Inventory_Frame
	if err := json.unmarshal_string(frame_json, &temp_frame, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
		return {}, false
	}
	frame.type = temp_frame.type
	frame.bridge_id = temp_frame.bridge_id
	frame.truncated = temp_frame.truncated
	if len(temp_frame.sessions) > 0 {
		frame.sessions = make([]Shell_Session_Inventory_Entry, len(temp_frame.sessions), allocator)
		copy(frame.sessions, temp_frame.sessions)
	} else {
		frame.sessions = make([]Shell_Session_Inventory_Entry, 0, allocator)
	}
	return frame, true
}

// shell_session_inventory_parse extracts the entries of a shell_inventory frame.
//
// The returned slice is the caller's to `delete`. Strings in entries are allocated in
// the temp allocator (via json.unmarshal_string on context.temp_allocator).
//
// Exported for tests: the parse is the one part of this path with no database in it,
// so it is worth asserting directly rather than only through its effects.
shell_session_inventory_parse :: proc(frame_json: string, allocator := context.allocator) -> []Shell_Session_Inventory_Entry {
	frame, ok := shell_session_inventory_parse_frame(frame_json, allocator)
	if !ok do return nil
	return frame.sessions
}
