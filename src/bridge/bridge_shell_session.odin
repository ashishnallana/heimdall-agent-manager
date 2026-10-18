package main

// REQ-SH-CONTRACT §3: bridge-side session management.
//
// Bridge_Shell_Session_Map owns the live session registry, mints session IDs,
// persists spawn specs to disk for crash-recovery, and reconciles with the
// daemon on reconnect. It is the backing store for EVERY kind — run, shell and
// server — all of which are spawned through the pty-host path in
// hub_runtime_client.odin. The shared constants and output helpers live alongside it
// in shell_common.odin.

import json "core:encoding/json"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// ---- session kind / status enums ----------------------------------------

// The bridge's mirror of domain.Shell_Session_Kind (src/hub/domain/shell_session.odin)
// — the same three kinds, one lifecycle, and the same wire spellings. REQ-SHELL-1
// renamed Command->Run and Interactive->Shell and DELETED Agent outright; both
// sides were changed together and neither accepts the old spellings, since there
// is no back-compat requirement and a dual-accept parser would just keep the dead
// vocabulary alive.
Bridge_Shell_Session_Kind :: enum {
	Run,
	Shell,
	Server,
}

Bridge_Shell_Session_Status :: enum {
	Starting,
	Running,
	Exited,
	Killed,
	Failed,
}

// ---- session struct ------------------------------------------------------

// Bridge_Shell_Session is the durable record for one bridge-managed shell
// session. All string fields are owned (cloned) so they outlive the request
// that created them.
//
// started_unix_ms / finished_unix_ms are implementation-only timing fields behind
// the response's execution_time_ms. They are NOT persisted in the spec JSON; they
// default to 0 after a crash-recovery load.
Bridge_Shell_Session :: struct {
	session_id:        string, // hub-minted "sh_<...>"; the hub is the only minter
	kind:              Bridge_Shell_Session_Kind,
	label:             string,
	cmd:               string,
	cwd:               string,
	bridge_id:         string,
	project_id:        string,
	chain_id:          string,
	agent_instance_id: string,
	owner_user_id:     string,
	pid:               int,
	server_port:       int, // 0 unless a port was declared at start (any kind — XM-8)
	status:            Bridge_Shell_Session_Status,
	exit_code:         int,
	exit_code_set:     bool,
	// run_seq — REQ-SHELL-4. The HUB-assigned run number this session is currently
	// on; the bridge echoes it back on every exit it reports so the hub can tell an
	// exit for the CURRENT run from one left over in the durable outbox from a
	// previous run of the same session_id. 0 is the first run, which is also what a
	// spec written before this field parses as.
	run_seq:           int,
	started_at:        string, // RFC3339 UTC
	finished_at:       string, // RFC3339 UTC; "" while running
	shell_id:          string, // daemon shell_id (== session_id for every kind since REQ-SHELL-1)
	// background — kind=run only, ONE-WAY, mirrors domain.Shell_Session.background.
	// REQ-SHELL-2 deleted the implicit 15s auto-background rule, so this is set by
	// an explicit --bg start or by a runtime conversion, never inferred from how
	// long the run has taken. Only a background run notifies on completion.
	background:        bool,
	// pty_host — HOW this session was spawned, which is what reconcile must branch
	// on. A session started through the hub path is spawned by the pty-host daemon
	// and therefore APPEARS IN ITS ROSTER. The retired bridge-local exec path spawned
	// a direct os.process_start child instead, which NEVER appears there however alive
	// it is.
	//
	// REQ-SHELL-7 DELETED THAT PRODUCER, so every session this code now creates is
	// pty_host=true. THE FLAG STAYS, and so does the branch that reads it: a bridge
	// upgraded past that commit still finds direct-child specs on disk from before it,
	// and reconcile asking the roster about a process that can never be in it is
	// exactly the bug that killed healthy runs. It is deliberately not derived from
	// `kind` — kind=run once arrived by both mechanisms, so kind never could answer
	// "should the daemon roster know about this?"
	pty_host:          bool,
	// pty_host_provenance_known distinguishes "pty_host is false" from "nobody said".
	// A spec written BEFORE REQ-SHELL-2 has no pty_host key at all, and it may
	// describe a genuinely pty-host-spawned session; loading that as a plain false
	// would send it down the direct-child path and NEVER consult the roster that
	// actually tracks it. Not persisted — a spec this code writes always states the
	// flag, so anything loaded without one is legacy by definition.
	pty_host_provenance_known: bool,
	// implementation-only (not in spec JSON):
	started_unix_ms:   i64,
	finished_unix_ms:  i64,
	// exit_reported — this run's exit has been handed to the hub (shell_exited
	// enqueued) by bridge_shell_session_finalize_exit. It is the claim that makes the
	// ChildExited event, the periodic sweep and the refused-kill path safe to race: the
	// first one to claim reports, the others no-op, so the hub never sees two exits for
	// one run. Cleared whenever the session goes back to a live status (a restart), so
	// the next run's exit is reported too.
	exit_reported:     bool,
}

// ---- session map ---------------------------------------------------------

// Bridge_Shell_Session_Map owns every string of every entry it holds; see the
// OWNERSHIP RULE on the CRUD section below for what that means for readers.
//
// allocator is the ONE allocator every entry's strings are allocated from and
// freed through, and it is carried on the map rather than taken from
// context.allocator for the reason lsp_session.odin's lsp_heap already states:
// this state crosses threads. A session is registered on the WS command thread,
// re-registered by reconcile on a background thread, and freed by whichever
// thread supersedes or removes the key — while context.allocator differs per
// thread (it is a per-test tracking allocator under `odin test`), so letting it
// decide means freeing through a different allocator than allocated from.
//
// A zero value means "not set yet" and resolves to runtime.default_allocator(),
// so the process-wide bridge_shell_session_map needs no initialisation. A test
// may set it to a mem.Tracking_Allocator before first use to assert the
// ownership rule holds (shell_session_ownership_test.odin does exactly that).
Bridge_Shell_Session_Map :: struct {
	mu:        sync.Mutex,
	sessions:  map[string]Bridge_Shell_Session, // keyed by session_id
	allocator: runtime.Allocator,
}

// bridge_shell_session_map_allocator resolves the map's allocator, defaulting to
// the process heap. Call it with the lock held (or before publishing the map) —
// it reads m.allocator.
bridge_shell_session_map_allocator :: proc(m: ^Bridge_Shell_Session_Map) -> runtime.Allocator {
	if m.allocator.procedure == nil do return runtime.default_allocator()
	return m.allocator
}

// ---- ID generator --------------------------------------------------------
//
// THERE ISN'T ONE ANY MORE. The bridge used to mint "shl_<unixnano>_<seq>" ids for
// sessions it created itself, which was only ever the bridge-local exec path
// REQ-SHELL-7 deleted. Every session now arrives with a hub-minted session_id in its
// spawn request, and the hub is the single minter — the same "hub assigns, bridge
// stores THAT" rule that already governs started_at and run_seq (REQ-SHELL-1 §8).

// ---- CRUD ----------------------------------------------------------------
//
// OWNERSHIP RULE (REQ-SHELL-11). THE MAP OWNS every string of every entry it
// holds, and nothing outside the map may point into that allocation once the map
// mutex is released. There is therefore NO by-value getter: reading a session
// gives you memory whose ownership is unambiguous, in one of three shapes.
//
//   bridge_shell_session_scalars   — the string-free fields, copied under the
//                                    lock. No allocation, nothing to free.
//                                    PREFER THIS: a snapshot where scalars would
//                                    do is a needless clone.
//   bridge_shell_session_shell_id  — the daemon key, CLONED under the lock.
//                                    Release with bridge_shell_session_str_delete.
//   bridge_shell_session_snapshot  — the whole record, DEEP-CLONED under the
//                                    lock. Release with
//                                    bridge_shell_session_snapshot_destroy.
//
// That mirrors the hub side, where domain.shell_session_destroy /
// domain.shell_sessions_destroy already state the same rule for the same record.
//
// WHY, i.e. what this replaced. The old API returned Bridge_Shell_Session BY
// VALUE, so every caller walked away with borrowed pointers into the stored
// allocation while the mutex was already released. That forced register to LEAK
// the strings it superseded: freeing them would have raced any holder — the
// kill/signal handlers in hub_runtime_client.odin read sess.shell_id across a
// bridge_pty_host_ensure_daemon call that can block for up to 5s, while reconcile
// re-registers the same session from a background thread — a use-after-free with a
// seconds-wide window. With no borrowed pointers left, that free is correct, and
// bridge_shell_session_register performs it.
//
// The teardown discipline is AGENTS.md's "Socket lifetime across threads" applied
// to this map: whoever removes the key owns the free, it happens under the same
// lock that removed it, and a thread that loses that race never dereferences the
// pointer because it never held one.

// Bridge_Shell_Session_Scalars is every field of Bridge_Shell_Session that is NOT
// a string. Copying it out of the map is a plain value copy, so a caller that only
// needs status/pid/kind/port/exit/background allocates nothing and frees nothing.
Bridge_Shell_Session_Scalars :: struct {
	kind:             Bridge_Shell_Session_Kind,
	status:           Bridge_Shell_Session_Status,
	pid:              int,
	server_port:      int,
	exit_code:        int,
	exit_code_set:    bool,
	background:       bool,
	pty_host:         bool,
	pty_host_provenance_known: bool,
	exit_reported:    bool,
	started_unix_ms:  i64,
	finished_unix_ms: i64,
}

// bridge_shell_session_clone deep-clones every owned string of a session through
// `allocator`, so the result shares no allocation with `s`. Unset ("") fields stay
// unset rather than becoming an empty allocation, which is what lets
// bridge_shell_session_free_fields skip them.
bridge_shell_session_clone :: proc(s: Bridge_Shell_Session, allocator: runtime.Allocator) -> Bridge_Shell_Session {
	clone_owned :: proc(str: string, allocator: runtime.Allocator) -> string {
		if str == "" do return ""
		return strings.clone(str, allocator)
	}
	out                   := s
	out.session_id        = clone_owned(s.session_id, allocator)
	out.label             = clone_owned(s.label, allocator)
	out.cmd               = clone_owned(s.cmd, allocator)
	out.cwd               = clone_owned(s.cwd, allocator)
	out.bridge_id         = clone_owned(s.bridge_id, allocator)
	out.project_id        = clone_owned(s.project_id, allocator)
	out.chain_id          = clone_owned(s.chain_id, allocator)
	out.agent_instance_id = clone_owned(s.agent_instance_id, allocator)
	out.owner_user_id     = clone_owned(s.owner_user_id, allocator)
	out.started_at        = clone_owned(s.started_at, allocator)
	out.finished_at       = clone_owned(s.finished_at, allocator)
	out.shell_id          = clone_owned(s.shell_id, allocator)
	return out
}

// bridge_shell_session_register inserts (or replaces) a session, CONSUMING it: it
// takes ownership of every string field, and ZEROES `s` on the way out so the
// caller's copy cannot be read afterwards. Those strings MUST come from the map's
// allocator (bridge_shell_session_map_allocator) — this is the proc that will
// eventually free them.
//
// WHY IT TAKES A POINTER AND ZEROES (REQ-SHELL-11 review). Handing a struct to the
// map and then reading it again is the WRITE-SIDE version of the borrow this task
// removed from the read side, and it is the more dangerous half: the hazard is not
// this register freeing your strings, it is the NEXT register of the same session_id
// making your just-handed-over set the superseded one and freeing it while you are
// still reading. Five call sites did exactly that.
//   Odin has no move semantics, so "the caller's copy stops compiling" is not
// available. Taking `^Bridge_Shell_Session` is the closest thing: the call reads as a
// transfer at every site, and a post-register read now yields the ZERO VALUE — an
// empty id or a .Starting status that fails immediately and visibly — instead of a
// silent read of memory another thread may have freed.
//   THE ZEROING IS NOT SUFFICIENT ON ITS OWN, and callers must not treat it as a
// licence: a copy made BEFORE the call (`updated := s`, the reconcile shape) still
// aliases the same string data, and zeroing `updated` does nothing for `s`. Those
// sites clone what they need before registering. See the writer-side table in the
// task handoff.
//
// Replacing an entry FREES the strings the previous entry owned, which is only
// correct because no getter hands out a pointer into them (see the OWNERSHIP RULE
// above). Two non-obvious guards make it safe:
//
//  1. THE KEY ALIASES THE OLD ENTRY'S session_id. Odin keeps the EXISTING key when
//     you assign to a slot that is already occupied, so `m.sessions[s.session_id] = s`
//     would leave the map keyed by the old allocation and freeing it would dangle
//     the key. delete_key first, then insert, so the new key is the new allocation.
//  2. A RE-REGISTER MAY ALIAS. If a caller ever hands back a struct sharing a string
//     with the stored entry, freeing the old copy would free memory the new entry
//     still holds. Each field is therefore freed only when its data pointer DIFFERS
//     from the new entry's, which makes an aliasing re-register a no-op rather than a
//     double free.
bridge_shell_session_register :: proc(m: ^Bridge_Shell_Session_Map, s: ^Bridge_Shell_Session) {
	if s == nil do return
	// Zeroed on EVERY exit path, so a caller cannot read its copy back even when the
	// insert took the replace branch and returned early.
	defer s^ = {}
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	allocator := bridge_shell_session_map_allocator(m)
	if m.sessions == nil do m.sessions = make(map[string]Bridge_Shell_Session, allocator = allocator)
	if _, existed := m.sessions[s.session_id]; existed {
		// Guard 1: remove the key so the insert below stores the NEW session_id
		// allocation as the key, rather than keeping the old one we are about to free.
		_, superseded := delete_key(&m.sessions, s.session_id)
		m.sessions[s.session_id] = s^
		bridge_shell_session_free_superseded(superseded, s^, allocator)
		return
	}
	m.sessions[s.session_id] = s^
}

// bridge_shell_session_free_superseded frees the strings of an entry that has just
// been replaced, skipping any field the replacement shares (guard 2 on
// bridge_shell_session_register). Called with the map lock held.
@(private = "file")
bridge_shell_session_free_superseded :: proc(old, new: Bridge_Shell_Session, allocator: runtime.Allocator) {
	free_superseded :: proc(old_str, new_str: string, allocator: runtime.Allocator) {
		if old_str == "" do return
		if raw_data(old_str) == raw_data(new_str) do return // aliased: the new entry owns it
		delete(old_str, allocator)
	}
	free_superseded(old.session_id, new.session_id, allocator)
	free_superseded(old.label, new.label, allocator)
	free_superseded(old.cmd, new.cmd, allocator)
	free_superseded(old.cwd, new.cwd, allocator)
	free_superseded(old.bridge_id, new.bridge_id, allocator)
	free_superseded(old.project_id, new.project_id, allocator)
	free_superseded(old.chain_id, new.chain_id, allocator)
	free_superseded(old.agent_instance_id, new.agent_instance_id, allocator)
	free_superseded(old.owner_user_id, new.owner_user_id, allocator)
	free_superseded(old.started_at, new.started_at, allocator)
	free_superseded(old.finished_at, new.finished_at, allocator)
	free_superseded(old.shell_id, new.shell_id, allocator)
}

// bridge_shell_session_free_fields frees every owned string of a session,
// through the allocator those strings were cloned from.
//
// Two callers, and both own the memory outright: a spec loaded by
// bridge_shell_session_load_specs that reconcile then SKIPPED (never handed to the
// map), and bridge_shell_session_snapshot_destroy freeing a caller's deep clone.
// Never call it on a session the map currently holds — that entry's strings are
// freed by the map, when the key is replaced or removed.
bridge_shell_session_free_fields :: proc(s: Bridge_Shell_Session, allocator: runtime.Allocator) {
	free_owned :: proc(str: string, allocator: runtime.Allocator) {
		if str != "" do delete(str, allocator)
	}
	free_owned(s.session_id, allocator)
	free_owned(s.label, allocator)
	free_owned(s.cmd, allocator)
	free_owned(s.cwd, allocator)
	free_owned(s.bridge_id, allocator)
	free_owned(s.project_id, allocator)
	free_owned(s.chain_id, allocator)
	free_owned(s.agent_instance_id, allocator)
	free_owned(s.owner_user_id, allocator)
	free_owned(s.started_at, allocator)
	free_owned(s.finished_at, allocator)
	free_owned(s.shell_id, allocator)
}

// bridge_shell_session_exists reports whether the map holds a session, without
// copying or cloning anything.
bridge_shell_session_exists :: proc(m: ^Bridge_Shell_Session_Map, session_id: string) -> bool {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	_, ok := m.sessions[session_id]
	return ok
}

// bridge_shell_session_scalars copies the string-free fields of a session out
// from under the lock. This is the narrowest read and the one to reach for first:
// status, pid, kind, server_port, exit_code and background answer most questions
// asked of this map, and none of them needs an allocation.
bridge_shell_session_scalars :: proc(m: ^Bridge_Shell_Session_Map, session_id: string) -> (Bridge_Shell_Session_Scalars, bool) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	s, ok := m.sessions[session_id]
	if !ok do return {}, false
	return Bridge_Shell_Session_Scalars{
		kind             = s.kind,
		status           = s.status,
		pid              = s.pid,
		server_port      = s.server_port,
		exit_code        = s.exit_code,
		exit_code_set    = s.exit_code_set,
		background       = s.background,
		pty_host         = s.pty_host,
		pty_host_provenance_known = s.pty_host_provenance_known,
		exit_reported    = s.exit_reported,
		started_unix_ms  = s.started_unix_ms,
		finished_unix_ms = s.finished_unix_ms,
	}, true
}

// bridge_shell_session_shell_id returns the DAEMON KEY for a session as an OWNED
// clone: shell_id when set, else session_id. Release it with
// bridge_shell_session_str_delete.
//
// This is the dominant read — the pty-host signal, kill, respawn, capture and pane
// paths all want exactly this one string, and each of them used to spell the
// `if shell_id == "" do shell_id = session_id` fallback itself. The fallback now
// lives here, once, next to the clone that makes holding the result safe across a
// blocking bridge_pty_host_ensure_daemon call.
bridge_shell_session_shell_id :: proc(m: ^Bridge_Shell_Session_Map, session_id: string) -> (string, bool) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	s, ok := m.sessions[session_id]
	if !ok do return "", false
	key := s.shell_id if s.shell_id != "" else s.session_id
	return strings.clone(key, bridge_shell_session_map_allocator(m)), true
}

// bridge_shell_session_str_delete releases a string handed out by
// bridge_shell_session_shell_id, through the allocator it was cloned from.
bridge_shell_session_str_delete :: proc(m: ^Bridge_Shell_Session_Map, str: string) {
	if str == "" do return
	delete(str, bridge_shell_session_map_allocator(m))
}

// bridge_shell_session_snapshot returns a FULLY OWNED deep clone of a session, for
// the few callers that genuinely serialize or re-save the whole record. Release it
// with bridge_shell_session_snapshot_destroy. Prefer _scalars or _shell_id when
// they suffice; a snapshot clones twelve strings to answer a question about one.
bridge_shell_session_snapshot :: proc(m: ^Bridge_Shell_Session_Map, session_id: string) -> (Bridge_Shell_Session, bool) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	s, ok := m.sessions[session_id]
	if !ok do return {}, false
	return bridge_shell_session_clone(s, bridge_shell_session_map_allocator(m)), true
}

// bridge_shell_session_snapshot_destroy releases a snapshot. Mirrors
// domain.shell_session_destroy hub-side.
bridge_shell_session_snapshot_destroy :: proc(m: ^Bridge_Shell_Session_Map, s: Bridge_Shell_Session) {
	bridge_shell_session_free_fields(s, bridge_shell_session_map_allocator(m))
}

// bridge_shell_session_snapshot_by_shell_id returns a fully owned deep clone of the
// session whose shell_id matches, falling back to session_id equality for a session
// that never recorded one. Returns the first match. Release it with
// bridge_shell_session_snapshot_destroy.
bridge_shell_session_snapshot_by_shell_id :: proc(m: ^Bridge_Shell_Session_Map, shell_id: string) -> (Bridge_Shell_Session, bool) {
	if shell_id == "" do return {}, false
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	for _, s in m.sessions {
		if s.shell_id == shell_id || (s.shell_id == "" && s.session_id == shell_id) {
			return bridge_shell_session_clone(s, bridge_shell_session_map_allocator(m)), true
		}
	}
	return {}, false
}

// bridge_shell_session_update_status updates the status, exit_code, and
// exit_code_set of an existing session under the map lock. Use
// bridge_shell_session_finish for the async-worker path (also sets timing).
bridge_shell_session_update_status :: proc(m: ^Bridge_Shell_Session_Map, session_id: string, status: Bridge_Shell_Session_Status, exit_code: int, exit_code_set: bool) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	if s, ok := &m.sessions[session_id]; ok {
		s.status = status
		s.exit_code = exit_code
		s.exit_code_set = exit_code_set
		// A session put back into a live status is a NEW run (shell_restart), whose
		// exit has not been reported yet.
		if !bridge_shell_session_status_is_terminal(status) do s.exit_reported = false
	}
}

// bridge_shell_session_set_run_seq adopts a new hub-assigned run number for a live
// session (REQ-SHELL-4) and returns an OWNED SNAPSHOT of the updated record so the
// caller can re-save its spec — the same shape as bridge_shell_session_set_server_port
// and bridge_shell_session_mark_background, and for the same reason.
//
// THE SPEC RE-SAVE IS NOT OPTIONAL HERE. run_seq lives on the session AND in the
// on-disk spec, and the spec is what a restarted BRIDGE reloads. Set it only in
// memory and a bridge restart would reload the PREVIOUS run's number and stamp every
// subsequent exit with it — the hub's row would be ahead, those exits would be
// discarded as stale, and the session would report running forever. That is the exact
// failure this column was added to prevent, reintroduced one layer down.
//
// Called by the restart handler AFTER a successful respawn, so a restart that failed
// leaves the bridge on the run the hub's row still names.
bridge_shell_session_set_run_seq :: proc(m: ^Bridge_Shell_Session_Map, session_id: string, run_seq: int) -> (Bridge_Shell_Session, bool) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	if s, ok := &m.sessions[session_id]; ok {
		s.run_seq = run_seq
		return bridge_shell_session_clone(s^, bridge_shell_session_map_allocator(m)), true
	}
	return {}, false
}

// bridge_shell_session_set_server_port sets server_port on an existing session
// under the map lock (XM-9) and returns an OWNED SNAPSHOT of the updated record so
// the caller can re-save its spec — destroy it with
// bridge_shell_session_snapshot_destroy. This is the bridge's OWN copy of the port
// — the one bridge_hub_handle_tunnel_open re-validates against — so a port declared
// after start has no effect until it lands here, however up to date the hub's row is.
bridge_shell_session_set_server_port :: proc(m: ^Bridge_Shell_Session_Map, session_id: string, port: int) -> (Bridge_Shell_Session, bool) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	if s, ok := &m.sessions[session_id]; ok {
		s.server_port = port
		return bridge_shell_session_clone(s^, bridge_shell_session_map_allocator(m)), true
	}
	return {}, false
}

// bridge_shell_session_mark_background sets background=true on a live session
// under the map lock and returns an OWNED SNAPSHOT of the updated record so the
// caller can re-save its spec. Same shape as bridge_shell_session_set_server_port,
// and for the same reason: the bridge's own copy is what the local waiter and the
// reaper read, so a flag set only on the hub row would have no effect here.
//
// The one-way rule (domain.shell_session_run_may_background) is checked by the
// caller; this proc is the write.
bridge_shell_session_mark_background :: proc(m: ^Bridge_Shell_Session_Map, session_id: string) -> (Bridge_Shell_Session, bool) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	if s, ok := &m.sessions[session_id]; ok {
		s.background = true
		return bridge_shell_session_clone(s^, bridge_shell_session_map_allocator(m)), true
	}
	return {}, false
}

// bridge_shell_session_finish is the async-worker variant: updates status,
// exit_code, and the millisecond-precision finish timestamp.
bridge_shell_session_finish :: proc(m: ^Bridge_Shell_Session_Map, session_id: string, status: Bridge_Shell_Session_Status, exit_code: int, finished_unix_ms: i64) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	if s, ok := &m.sessions[session_id]; ok {
		s.status = status
		s.exit_code = exit_code
		s.exit_code_set = true
		s.finished_unix_ms = finished_unix_ms
	}
}

// bridge_shell_session_list_snapshot returns a DEEP-CLONED snapshot of every
// session. The old bridge_shell_session_list copied the structs into a slice and
// therefore handed out twelve borrowed pointers per entry, which its one caller
// (bridge_hub_handle_shell_list) then read every one of while serializing.
// Release the result with bridge_shell_session_list_destroy.
bridge_shell_session_list_snapshot :: proc(m: ^Bridge_Shell_Session_Map) -> []Bridge_Shell_Session {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	allocator := bridge_shell_session_map_allocator(m)
	result := make([]Bridge_Shell_Session, len(m.sessions), allocator)
	i := 0
	for _, s in m.sessions {
		result[i] = bridge_shell_session_clone(s, allocator)
		i += 1
	}
	return result
}

// bridge_shell_session_list_destroy frees a slice from
// bridge_shell_session_list_snapshot, entries included.
bridge_shell_session_list_destroy :: proc(m: ^Bridge_Shell_Session_Map, sessions: []Bridge_Shell_Session) {
	allocator := bridge_shell_session_map_allocator(m)
	for s in sessions do bridge_shell_session_free_fields(s, allocator)
	delete(sessions, allocator)
}

// bridge_shell_session_map_reset removes every session (for tests), FREEING each
// entry's strings — it used to `clear()` and leak all of them. Under the ownership
// rule the map owns those strings, so reset is a removal and removal frees; it is
// also what makes a churn test measure real growth instead of watching the reset
// hide it.
bridge_shell_session_map_reset :: proc(m: ^Bridge_Shell_Session_Map) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	allocator := bridge_shell_session_map_allocator(m)
	for _, s in m.sessions do bridge_shell_session_free_fields(s, allocator)
	clear(&m.sessions)
}

// bridge_shell_session_map_destroy releases the map itself as well as its entries.
// Tests that stand up a local map on a tracking allocator need this to reach zero
// live allocations; the process-wide map lives for the life of the bridge.
bridge_shell_session_map_destroy :: proc(m: ^Bridge_Shell_Session_Map) {
	bridge_shell_session_map_reset(m)
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	delete(m.sessions)
	m.sessions = nil
}

// ---- pending kill intents (REQ-SHELL-3) ----------------------------------
//
// A kill can arrive for a session this bridge does not know yet. The hub creates the
// row and then sends shell_start, so a kill accepted in between is dispatched
// against a session_id that is not in the map: before this, that kill was dropped on
// the floor and the process leaked the moment it spawned (the task's edge case C).
// The intent is recorded here instead and applied by one of its two consumers — the
// spawn path, the moment a spawn produces a pid, or reconcile's resolver, for a session
// adopted rather than spawned. A session that starts while carrying a kill intent is
// killed immediately, never left running.
//
// IN MEMORY, NOT ON DISK, and that is deliberate. The DURABLE store for a kill
// intent is the hub's shell_sessions.kill_requested_at column, and the hub re-issues
// every outstanding intent when this bridge's WS reconnects — which is exactly what
// happens after a bridge restart. Persisting the set here as well would be a second
// source of truth for the same fact, with its own staleness and its own clearing
// rule, to cover a window the hub already covers.
//
// AN ENTRY IS A CANDIDATE, NOT A DECISION (REQ-SHELL-23). The recording site cannot
// tell the two reasons a session is missing from the map apart:
//
//   NOT STARTED YET  — the hub wrote its row and the spawn has not landed. The intent
//                      is meaningful and shell_start consumes it.
//   ALREADY GONE, or ADOPTED-BUT-NOT-YET-KNOWN — a stale id, a session from a previous
//                      bridge life, or (the REQ-SHELL-23 case) a session that is alive
//                      in the surviving pty-host daemon while this freshly restarted
//                      bridge has not yet rebuilt its map from the roster.
//
// Distinguishing them needs the pty-host roster, and the recording site runs on the
// hub-WS loop thread, where a daemon round-trip (up to 5s on a cold daemon) would stall
// heartbeats and every other command. So this site does not try: it records a candidate
// and RECONCILE resolves it, because reconcile is the one place that already holds the
// authoritative roster. See bridge_shell_kill_intent_resolve.
//
// THAT ALSO GIVES EVERY ENTRY AN OWNER THAT FREES IT. Before REQ-SHELL-23 the only
// consumer was the spawn path, so an intent for a session that never spawns — a stale
// id, or the reconnect case above — leaked one key for the life of the process, for any
// session id the hub ever named. The resolver retires those.
//
// recorded_at is a MONOTONIC instant and it is load-bearing, not diagnostics: the
// resolver must not judge an intent that was recorded AFTER it captured its roster,
// because such an intent may be about a spawn that has not happened yet, and discarding
// it would reintroduce exactly the leak the kill-before-start path exists to prevent.
@(private = "file")
_bridge_shell_pending_kills: map[string]time.Tick
@(private = "file")
_bridge_shell_pending_kills_mu: sync.Mutex

// bridge_shell_kill_intent_record notes that a kill arrived for a session that is
// not in the map yet. Idempotent: the set holds an intent, not a count — and a repeat
// keeps the ORIGINAL instant, so a kill the hub redelivers every reconnect can never
// keep outrunning the resolver's roster and postpone its own retirement forever.
bridge_shell_kill_intent_record :: proc(session_id: string) {
	bridge_shell_kill_intent_record_at(session_id, time.tick_now())
}

// bridge_shell_kill_intent_record_at is bridge_shell_kill_intent_record with the instant
// supplied. It exists so the resolver's age gate can be tested at all: the gate's whole
// point is that an intent younger than a start round-trip is left alone, and a test that
// had to wait BRIDGE_SHELL_KILL_INTENT_GARBAGE_AGE in real time to check the other side of
// it would be a test nobody runs.
bridge_shell_kill_intent_record_at :: proc(session_id: string, at: time.Tick) {
	if session_id == "" do return
	sync.mutex_lock(&_bridge_shell_pending_kills_mu)
	defer sync.mutex_unlock(&_bridge_shell_pending_kills_mu)
	if _bridge_shell_pending_kills == nil {
		_bridge_shell_pending_kills = make(map[string]time.Tick, allocator = runtime.default_allocator())
	}
	if session_id in _bridge_shell_pending_kills do return
	_bridge_shell_pending_kills[strings.clone(session_id, runtime.default_allocator())] = at
}

// Bridge_Shell_Kill_Intent is one parked intent as the resolver sees it: which session,
// and when it was recorded. The instant travels with the id because the resolver needs it
// for the age gate below, and re-reading it later would mean retaking the intent lock.
Bridge_Shell_Kill_Intent :: struct {
	session_id:  string,
	recorded_at: time.Tick,
}

// bridge_shell_kill_intent_ids_before returns every intent recorded STRICTLY BEFORE
// `cutoff`, with owned session_id clones the caller frees. It exists so the resolver can
// iterate without holding the intent lock across the kill work it then does — which takes
// the session-map lock and starts a worker that dials the daemon.
bridge_shell_kill_intent_ids_before :: proc(cutoff: time.Tick, allocator := context.allocator) -> []Bridge_Shell_Kill_Intent {
	sync.mutex_lock(&_bridge_shell_pending_kills_mu)
	defer sync.mutex_unlock(&_bridge_shell_pending_kills_mu)
	if _bridge_shell_pending_kills == nil do return nil
	out := make([dynamic]Bridge_Shell_Kill_Intent, allocator)
	for id, recorded_at in _bridge_shell_pending_kills {
		// Strictly before: an intent recorded at or after the roster snapshot describes a
		// world the roster cannot speak for.
		if time.tick_diff(recorded_at, cutoff) > 0 {
			append(&out, Bridge_Shell_Kill_Intent{session_id = strings.clone(id, allocator), recorded_at = recorded_at})
		}
	}
	return out[:]
}

// BRIDGE_SHELL_KILL_INTENT_GARBAGE_AGE is how old an intent naming a session the roster
// does not know must be before the resolver will discard it.
//
// IT IS A SAFETY MARGIN AGAINST A SPAWN STILL IN FLIGHT, not a tidiness interval, and the
// number is chosen against the longest window in which a start could still land and
// consume the intent legitimately (REQ-SHELL-3 work item 5b: the hub writes its row and
// may send a kill BEFORE the shell_start it raced):
//   - the hub's own bridge-command wait is 30s, so it will not still be expecting a start
//     to complete beyond that;
//   - a spawn onto a COLD daemon absorbs up to 5s inside bridge_pty_host_ensure_daemon
//     before it even begins.
// Five minutes is an order of magnitude above both. Being LATE to discard costs one map
// key; being EARLY costs a live process surviving a kill the hub already promised the
// user, which is the core invariant this task exists to restore. The asymmetry is the
// whole reason this is minutes and not seconds.
BRIDGE_SHELL_KILL_INTENT_GARBAGE_AGE :: 5 * time.Minute

// bridge_shell_kill_intent_take consumes a pending intent, reporting whether one was
// there. CONSUMING rather than peeking is what makes applying it a one-shot: the
// spawn path acts on it exactly once, and a later redelivery from the hub goes
// through the normal kill path against a session that is now in the map.
bridge_shell_kill_intent_take :: proc(session_id: string) -> bool {
	if session_id == "" do return false
	sync.mutex_lock(&_bridge_shell_pending_kills_mu)
	defer sync.mutex_unlock(&_bridge_shell_pending_kills_mu)
	if _bridge_shell_pending_kills == nil do return false
	for k in _bridge_shell_pending_kills {
		if k == session_id {
			delete_key(&_bridge_shell_pending_kills, k)
			delete(k, runtime.default_allocator())
			return true
		}
	}
	return false
}

// bridge_shell_kill_intent_pending reports whether an intent is recorded WITHOUT
// consuming it. For assertions and diagnostics only — the spawn path must use
// bridge_shell_kill_intent_take so the intent is applied once.
bridge_shell_kill_intent_pending :: proc(session_id: string) -> bool {
	sync.mutex_lock(&_bridge_shell_pending_kills_mu)
	defer sync.mutex_unlock(&_bridge_shell_pending_kills_mu)
	if _bridge_shell_pending_kills == nil do return false
	for k in _bridge_shell_pending_kills {
		if k == session_id do return true
	}
	return false
}

// bridge_shell_kill_intent_resolve settles every kill intent the roster can speak for,
// and it is the second consumer the intent set never had (REQ-SHELL-23).
//
// THE DEFECT IT FIXES. A kill accepted while the bridge was offline is redelivered by the
// hub on reconnect, and it arrives BEFORE reconcile has rebuilt the session map from the
// pty-host roster — the hub replays inline on its WS accept path, while the bridge
// repopulates on a background thread whose first act can block for up to 5s spawning the
// daemon. The kill therefore always found an empty map, was parked as an intent, and was
// never consumed, because the only consumer was the spawn path and an adopted session is
// never re-spawned. The process survived a kill the hub had already promised the user,
// and nothing anywhere said so.
//
// CALLED FROM RECONCILE, with the roster already applied to the map, because that is the
// only place in the bridge that knows which sessions actually exist. `cutoff` is the
// instant the roster was captured: intents recorded at or after it are LEFT ALONE, since
// they may name a spawn that has not happened yet and discarding one would reintroduce
// the kill-before-start leak (REQ-SHELL-3 work item 5b). Taking that snapshot BEFORE the
// roster read, not after, is what makes the guard conservative in the safe direction.
//
// Each resolved intent ends in exactly one of three states, and all three FREE the entry:
//   in the map, still live     -> take + arm the kill. The REQ-SHELL-23 case.
//   in the map, terminal       -> take + drop. Already dead; re-signalling a terminal
//                                 session is the PID-reuse hazard the kill path refuses.
//   not in the map, and OLD    -> take + drop as garbage. See the age gate's reasoning.
//   not in the map, and young  -> LEFT PARKED, untouched, for the spawn path.
//
// WHY THE UNKNOWN CASE NEEDS AN AGE GATE AND NOT JUST `cutoff`. The cutoff orders an
// intent against the ROSTER, but the hazard is an intent racing a FUTURE SPAWN, which the
// roster cannot see:
//     intent recorded at T-1 (kill-before-start: the hub sent the kill before the start)
//     roster captured at T; the intent is older, so it is judged
//     not in the map -> discarded as garbage
//     shell_start lands at T+1 -> spawns -> nothing left to consume -> the process runs on
// That is exactly the leak work item 5b exists to prevent, reintroduced by a cleanup. So
// "not in the roster" is NOT sufficient grounds to discard; only "not in the roster AND too
// old for any start to still be in flight" is.
//
// Returns (armed, discarded) for the caller to log; a resolver that silently found work and
// did nothing with it is the shape of bug this task exists to remove.
//
// `arm` is a parameter so this is testable without starting a real kill worker, which
// would dial (and possibly spawn) the pty-host daemon. Production callers take the
// default; tests pass a recorder. It is the ONLY seam — the decision logic under test is
// the same code either way.
bridge_shell_kill_intent_resolve :: proc(
	m: ^Bridge_Shell_Session_Map,
	cutoff: time.Tick,
	arm: proc(session_id: string, shell_id: string) = bridge_shell_kill_arm,
) -> (armed: int, discarded: int) {
	// Snapshot the intents and release the intent lock before doing any work: arming takes
	// the session-map lock and starts a worker that dials the daemon, and holding both
	// locks across that is how a deadlock gets written.
	intents := bridge_shell_kill_intent_ids_before(cutoff)
	defer {
		for it in intents do delete(it.session_id)
		delete(intents)
	}

	now := time.tick_now()
	for it in intents {
		id := it.session_id
		sc, known := bridge_shell_session_scalars(m, id)
		if !known {
			// The roster does not know it. Only discard once no start could still be in
			// flight; until then it stays parked for bridge_hub_handle_shell_start.
			if time.tick_diff(it.recorded_at, now) < BRIDGE_SHELL_KILL_INTENT_GARBAGE_AGE do continue
			if bridge_shell_kill_intent_take(id) {
				discarded += 1
				// LOGGED: discarding a kill intent is a decision to stop trying to kill
				// something, and an unlogged one is how this class of bug hides.
				fmt.println("bridge shell kill intent discarded: no such session on this host", id)
			}
			continue
		}
		if bridge_shell_session_status_is_terminal(sc.status) {
			if bridge_shell_kill_intent_take(id) do discarded += 1
			continue
		}
		// TAKE FIRST, then arm. The take is what makes this one-shot, and doing it before
		// the arm means a concurrent second resolver (or a redelivery racing in) cannot
		// arm the same session twice.
		if !bridge_shell_kill_intent_take(id) do continue
		shell_id, have_key := bridge_shell_session_shell_id(m, id)
		if !have_key {
			// Removed between the two reads; the intent is spent either way.
			discarded += 1
			continue
		}
		defer bridge_shell_session_str_delete(m, shell_id)
		arm(id, shell_id)
		armed += 1
	}
	return armed, discarded
}

// bridge_shell_kill_intent_reset clears the set (for tests), freeing its keys.
bridge_shell_kill_intent_reset :: proc() {
	sync.mutex_lock(&_bridge_shell_pending_kills_mu)
	defer sync.mutex_unlock(&_bridge_shell_pending_kills_mu)
	if _bridge_shell_pending_kills == nil do return
	for k in _bridge_shell_pending_kills do delete(k, runtime.default_allocator())
	clear(&_bridge_shell_pending_kills)
}

// bridge_shell_session_status_is_terminal is the bridge's mirror of
// domain.shell_session_status_is_terminal: the session is over and must not be
// signalled again. It is what makes a REDELIVERED kill a no-op — the kill path marks
// a session .Killed before its worker even starts, so a second delivery of the same
// kill sees a terminal session and does nothing, rather than arming a second
// SIGTERM/SIGKILL pair against a pid that may by then have been recycled.
bridge_shell_session_status_is_terminal :: proc(status: Bridge_Shell_Session_Status) -> bool {
	switch status {
	case .Exited, .Killed, .Failed: return true
	case .Starting, .Running:       return false
	}
	return false
}

// ---- durable JSON spec store --------------------------------------------

// The returned string is ALWAYS a fresh allocation (concatenate, never an alias of
// data_dir), so every caller owns it and must delete it. All three used to drop it:
// save_spec leaked one path per spec write — i.e. per start, per port change, per
// background conversion and per exit — and load_specs one per reconnect.
bridge_shell_session_spec_dir :: proc(data_dir: string) -> string {
	return strings.concatenate({strings.trim_right(data_dir, "/"), "/shell_sessions"})
}

// Shell_Session_Spec is the typed disk representation of a shell session.
// Persisted atomically to $data_dir/shell_sessions/<session_id>.json.
Shell_Session_Spec :: struct {
	session_id:        string      `json:"session_id"`,
	kind:              string      `json:"kind"`,
	label:             string      `json:"label"`,
	cmd:               string      `json:"cmd"`,
	cwd:               string      `json:"cwd"`,
	bridge_id:         string      `json:"bridge_id"`,
	project_id:        string      `json:"project_id"`,
	chain_id:          string      `json:"chain_id"`,
	agent_instance_id: string      `json:"agent_instance_id"`,
	owner_user_id:     string      `json:"owner_user_id"`,
	pid:               int         `json:"pid"`,
	server_port:       int         `json:"server_port"`,
	run_seq:           int         `json:"run_seq"`,
	status:            string      `json:"status"`,
	exit_code:         int         `json:"exit_code"`,
	exit_code_set:     bool        `json:"exit_code_set"`,
	started_at:        string      `json:"started_at"`,
	finished_at:       string      `json:"finished_at"`,
	shell_id:          string      `json:"shell_id"`,
	background:        bool        `json:"background"`,
	pty_host:          Maybe(bool) `json:"pty_host"`,
}

// bridge_shell_session_save_spec writes the session spec to disk atomically
// (write to a .tmp file then rename). Callers pass the expanded data_dir.
bridge_shell_session_save_spec :: proc(data_dir: string, s: Bridge_Shell_Session) {
	dir := bridge_shell_session_spec_dir(data_dir)
	defer delete(dir)
	_ = bridge_make_directory_all(dir)

	path := strings.concatenate({dir, "/", s.session_id, ".json"})
	defer delete(path)
	tmp := strings.concatenate({path, ".tmp"})
	defer delete(tmp)

	spec := Shell_Session_Spec{
		session_id        = s.session_id,
		kind              = bridge_shell_session_kind_str(s.kind),
		label             = s.label,
		cmd               = s.cmd,
		cwd               = s.cwd,
		bridge_id         = s.bridge_id,
		project_id        = s.project_id,
		chain_id          = s.chain_id,
		agent_instance_id = s.agent_instance_id,
		owner_user_id     = s.owner_user_id,
		pid               = s.pid,
		server_port       = s.server_port,
		run_seq           = s.run_seq,
		status            = bridge_shell_session_status_str(s.status),
		exit_code         = s.exit_code,
		exit_code_set     = s.exit_code_set,
		started_at        = s.started_at,
		finished_at       = s.finished_at,
		shell_id          = s.shell_id,
		background        = s.background,
		pty_host          = s.pty_host,
	}

	payload, merr := json.marshal(spec, allocator = context.temp_allocator)
	if merr != nil {
		fmt.eprintln("bridge shell session: failed to marshal spec:", merr)
		return
	}

	if os.write_entire_file(tmp, payload) == nil {
		_ = os.rename(tmp, path)
	}
}

// bridge_shell_session_load_specs reads all *.json spec files from the
// shell_sessions directory. Corrupt or unreadable files are logged and skipped.
//
// The caller owns the returned slice and each element's string fields, and they are
// cloned from `allocator` — which must be the SESSION MAP'S allocator whenever a
// spec may be registered, because register then takes ownership and the map's free
// must match this clone. Release a spec the caller keeps with
// bridge_shell_session_free_fields(s, allocator), and the slice with
// delete(specs, allocator).
bridge_shell_session_load_specs :: proc(data_dir: string, allocator: runtime.Allocator) -> []Bridge_Shell_Session {
	dir := bridge_shell_session_spec_dir(data_dir)
	defer delete(dir)
	infos, rerr := os.read_directory_by_path(dir, -1, context.allocator)
	if rerr != nil do return nil
	defer os.file_info_slice_delete(infos, context.allocator)

	result := make([dynamic]Bridge_Shell_Session, allocator = allocator)
	for info in infos {
		if !strings.has_suffix(info.name, ".json") || strings.has_suffix(info.name, ".tmp.json") do continue
		// skip .tmp files (from an interrupted write)
		if strings.has_suffix(info.name, ".tmp") do continue

		path := strings.concatenate({dir, "/", info.name})
		raw, ferr := os.read_entire_file(path, context.allocator)
		delete(path)
		if ferr != nil do continue
		defer delete(raw)

		spec: Shell_Session_Spec
		jerr := json.unmarshal(raw, &spec, allocator = context.temp_allocator)
		if jerr != nil {
			fmt.eprintln("bridge shell session: corrupt spec, skipping:", info.name)
			continue
		}

		s: Bridge_Shell_Session
		s.session_id = strings.clone(spec.session_id, allocator)
		s.kind = bridge_shell_session_kind_from_str(spec.kind)
		s.label = strings.clone(spec.label, allocator)
		s.cmd = strings.clone(spec.cmd, allocator)
		s.cwd = strings.clone(spec.cwd, allocator)
		s.bridge_id = strings.clone(spec.bridge_id, allocator)
		s.project_id = strings.clone(spec.project_id, allocator)
		s.chain_id = strings.clone(spec.chain_id, allocator)
		s.agent_instance_id = strings.clone(spec.agent_instance_id, allocator)
		s.owner_user_id = strings.clone(spec.owner_user_id, allocator)
		s.pid = spec.pid
		s.server_port = spec.server_port
		// A spec written before REQ-SHELL-4 has no run_seq key and loads as 0, the
		// first run — the same value the hub's row carries for a session that has
		// never been restarted, so the two sides agree with no backfill.
		s.run_seq = spec.run_seq
		s.status = bridge_shell_session_status_from_str(spec.status)
		s.exit_code = spec.exit_code
		s.exit_code_set = spec.exit_code_set
		s.started_at = strings.clone(spec.started_at, allocator)
		s.finished_at = strings.clone(spec.finished_at, allocator)
		s.shell_id = strings.clone(spec.shell_id, allocator)
		s.background = spec.background
		// A spec written before REQ-SHELL-2 has no pty_host key and loads as false,
		// i.e. "direct child". That is the SAFE default: the false branch proves
		// liveness with ps before acting, while defaulting to true would ask the
		// roster about a process that may never have been in it and reap it as dead.
		if pty, ok := spec.pty_host.?; ok {
			s.pty_host = pty
			s.pty_host_provenance_known = true
		}

		if s.session_id != "" {
			append(&result, s)
		} else {
			bridge_shell_session_free_fields(s, allocator)
		}
	}
	return result[:]
}

bridge_shell_session_delete_spec :: proc(data_dir: string, session_id: string) {
	dir := bridge_shell_session_spec_dir(data_dir)
	defer delete(dir)
	path := strings.concatenate({dir, "/", session_id, ".json"})
	defer delete(path)
	_ = os.remove(path)
}

// ---- reconcile on reconnect ----------------------------------------------

@(private = "file")
_bridge_shell_reconcile_running: bool
@(private = "file")
_bridge_shell_reconcile_mu: sync.Mutex

// bridge_shell_reconcile_try_begin / _end are the single-flight gate shared by the
// reconnect reconcile and the periodic exit sweep (shell_exit_sweep.odin). They act on
// the same sessions, and the reconcile's dead-spec path registers a fresh terminal
// record without the exit claim, so letting the two overlap could report one exit
// twice. A pass that finds the gate taken is a no-op; the next tick or reconnect picks
// up whatever the running pass did not.
bridge_shell_reconcile_try_begin :: proc() -> bool {
	sync.mutex_lock(&_bridge_shell_reconcile_mu)
	defer sync.mutex_unlock(&_bridge_shell_reconcile_mu)
	if _bridge_shell_reconcile_running do return false
	_bridge_shell_reconcile_running = true
	return true
}

bridge_shell_reconcile_end :: proc() {
	sync.mutex_lock(&_bridge_shell_reconcile_mu)
	defer sync.mutex_unlock(&_bridge_shell_reconcile_mu)
	_bridge_shell_reconcile_running = false
}

// bridge_shell_session_reconcile_now resolves the data dir and the live pty-host
// agent list, then runs a reconcile pass. Intended to be launched on a background
// thread from the hub-runtime-ready path (REQ-RECON-1).
//
// Single-flight: hub WS reconnects can arrive back-to-back, and two overlapping
// reconcile passes could each act on the same orphaned session (double kill,
// duplicate shell_exited). A running pass therefore makes any concurrent call a
// no-op; the next reconnect picks up whatever this pass did not.
//
// If the pty-host is unreachable we return without touching anything: without a
// daemon list we cannot distinguish a live session from a dead one, and guessing
// would mark healthy sessions dead.
bridge_shell_session_reconcile_now :: proc() {
	if !bridge_shell_reconcile_try_begin() do return
	defer bridge_shell_reconcile_end()

	// bridge_expand_home allocates only when the path starts with "~/", so free
	// it only when it actually handed back a different allocation. This runs on
	// every reconnect, outside any arena.
	raw_dir := strings.trim_space(bridge_config.data_dir)
	if raw_dir == "" do raw_dir = "~/.local/share/heimdall"
	data_dir := bridge_expand_home(raw_dir)
	defer if raw_data(data_dir) != raw_data(raw_dir) do delete(data_dir)

	// REQ-SHELL-8: second of the three retention triggers. Deliberately placed
	// BEFORE the pty-host check below, which returns early when the daemon is
	// unreachable — output retention does not depend on the roster and has no reason
	// to be skipped just because reconcile cannot run.
	bridge_shell_output_sweep_if_due()

	socket, sock_ok := bridge_pty_host_ensure_daemon()
	if !sock_ok do return

	// SUBSCRIBE TO THE DAEMON'S EVENT STREAM ON EVERY RECONNECT, not only after a spawn
	// (REQ-SHELL-23).
	//
	// EVERY MECHANISM THAT CONVERGES AN ADOPTED SESSION WAS KEYED TO A SPAWN THAT, AFTER A
	// RESTART, NEVER HAPPENS. That one sentence describes all three faces of this defect:
	// the kill intent whose only consumer was the spawn path, the inventory replay gated on
	// a diff that a healthy adopted session does not produce, and this subscription. A
	// bridge that restarts does not spawn the sessions it inherits — it adopts them — so
	// anything hung off spawn is simply absent on the path that matters most.
	//
	// bridge_pty_host_events_ensure had exactly two callers, both spawn
	// paths, so a bridge that restarted and ADOPTED the surviving sessions below was not
	// watching the daemon at all: their ChildExited was broadcast to nobody, no
	// shell_exited was enqueued, and the hub row stayed `running` — with its kill intent
	// still stamped — until some later reconnect's inventory reaped it by ABSENCE. That is
	// how a kill this bridge had successfully executed still left the hub lying about the
	// session. Idempotent by contract ("Safe to call repeatedly"), and placed after
	// ensure_daemon so there is something to attach to, which is the precondition its own
	// comment names.
	bridge_pty_host_events_ensure()

	// CAPTURED BEFORE THE ROSTER READ, deliberately. This is the cutoff handed to
	// bridge_shell_kill_intent_resolve, which may only judge intents older than the world
	// the roster describes. Taking it early makes the guard err toward leaving a young
	// intent for the spawn path — the safe direction; taking it after the read would let
	// an intent recorded DURING the read be judged against a roster that predates it.
	roster_at := time.tick_now()
	reply, list_ok := bridge_pty_host_list(socket)
	if !list_ok do return
	defer pty_host_reply_delete(reply)

	// REQ-BR-1: finalize the IN-MEMORY sessions whose process is gone first, through
	// the ChildExited path, so a run the daemon reports exited is reported with its
	// real exit code. Done before the spec pass below, which would otherwise find the
	// same session's spec, see it dead in the roster and report it "failed" with a
	// made-up code 1. The sweep deletes the spec of every session it finalizes, so the
	// spec pass never sees them.
	bridge_shell_session_sweep(&bridge_shell_session_map, reply.agents, data_dir)

	bridge_shell_session_reconcile(&bridge_shell_session_map, reply.agents, data_dir)

	// REQ-SHELL-10: hand the hub this bridge's WHOLE live truth, so it can diff its
	// rows against it instead of waiting for an event per divergence.
	//
	// AFTER the reconcile pass, never before, and that ordering is the first half of
	// the guarantee that the inventory and the REQ-SHELL-4 exit outbox cannot
	// disagree: the pass has by now moved every session it found dead to a terminal
	// status in the map and enqueued its exit, so those sessions are absent from the
	// snapshot rather than being reported live and dead at once. See the header of
	// shell_inventory.odin for the rest of it.
	//
	// It also inherits this proc's EARLY RETURNS, and that is deliberate rather than a
	// gap: if the pty-host daemon or its list is unreachable we return above without
	// sending anything. An inventory asserts "these and ONLY these are alive", and
	// asserting that on the strength of a roster we could not read would have the hub
	// mark healthy sessions terminal. No diff is better than a wrong diff; the next
	// reconnect sends one built on a roster we could read.
	frame := bridge_shell_inventory_build(&bridge_shell_session_map)
	defer delete(frame)
	bridge_shell_inventory_enqueue(frame)

	// NOW the map reflects the roster, so a parked kill intent can finally be judged
	// (REQ-SHELL-23). AFTER the inventory is enqueued, and the ordering is not arbitrary —
	// I had it the other way first and it was wrong in a way worth recording.
	//
	// Arming a kill marks the session .Killed, and bridge_shell_inventory_build EXCLUDES
	// terminal sessions. Resolving first therefore produced an inventory that omitted a
	// session which was still very much alive, the hub reasoned from that absence
	// (_reap_inventory_absent), and every durable kill published a synthesized
	// shell_session_exited{status:"failed"} ~16ms before the real {status:"killed"} — a
	// visible wrong status on the user bus, fixed only because an observed exit outranks a
	// synthesized one. Measured on the isolated stack, both rounds.
	//
	// An inventory must describe the world the ROSTER showed, not anticipate a kill this
	// pass is about to perform. Resolving after it means the session is reported live,
	// which is true at that instant, and the single terminal status the hub ever sees for
	// it is the observed exit.
	if armed, discarded := bridge_shell_kill_intent_resolve(&bridge_shell_session_map, roster_at); armed > 0 || discarded > 0 {
		fmt.println("bridge shell kill intents resolved: armed", armed, "discarded", discarded)
	}
}

// Bridge_Shell_Orphan_Kill_Ctx carries state for the orphan-kill background
// thread. It holds the session identity (not just the pid) because the escalation
// step has to re-verify the pid before SIGKILL — see the worker below. cmd and
// started_at are owned clones, freed by the worker.
Bridge_Shell_Orphan_Kill_Ctx :: struct {
	pid:        i32,
	cmd:        string,
	started_at: string,
}

// bridge_shell_session_orphan_kill_worker sends SIGTERM to a directly-tracked
// PID, waits 5s, then SIGKILLs if the pid is STILL OUR PROCESS. Used only for
// processes the pty-host no longer tracks (bridge_shell_kill_worker cannot kill
// them because it routes through the pty-host daemon, which has no handle on
// the session).
//
// The identity check is re-run before the SIGKILL rather than a bare liveness
// probe: the 5s grace period is exactly the window in which our SIGTERMed
// process exits and the OS is free to hand its pid to something else. A plain
// kill(pid, 0) would then report "alive" for an unrelated process and we would
// SIGKILL it — reintroducing, one step later, the PID-reuse hazard the guard
// before the SIGTERM exists to prevent. If the re-check fails for any reason we
// skip the SIGKILL: an orphan that outlives us is acceptable, a wrong kill is not.
bridge_shell_session_orphan_kill_worker :: proc(data: rawptr) {
	ctx := (^Bridge_Shell_Orphan_Kill_Ctx)(data)
	defer {
		delete(ctx.cmd)
		delete(ctx.started_at)
		free(ctx)
		free_all(context.temp_allocator)
	}

	_ = bridge_os_terminate(int(ctx.pid))
	time.sleep(5 * time.Second)
	// Re-verify identity, not just liveness, before escalating.
	if bridge_shell_session_pid_is_plausible(int(ctx.pid), ctx.cmd, ctx.started_at) {
		_ = bridge_os_kill(int(ctx.pid))
	}
}

// bridge_shell_session_parse_lstart parses the C-locale lstart string produced
// by `LC_ALL=C ps -o lstart=`.  Format: "Www Mmm DD HH:MM:SS YYYY" (24 chars).
// Returns (unix_sec, true) on success, (0, false) on any parse failure.
bridge_shell_session_parse_lstart :: proc(s: string) -> (i64, bool) {
	if len(s) < 24 do return 0, false
	month_names := [12]string{"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"}
	month_str := strings.trim_space(s[4:7])
	month := 0
	for m, i in month_names {
		if m == month_str { month = i + 1; break }
	}
	if month == 0 do return 0, false
	day, day_ok   := strconv.parse_int(strings.trim_space(s[8:10]))
	hour, hr_ok   := strconv.parse_int(s[11:13])
	min_, mn_ok   := strconv.parse_int(s[14:16])
	sec, sc_ok    := strconv.parse_int(s[17:19])
	year, yr_ok   := strconv.parse_int(s[20:24])
	if !day_ok || !hr_ok || !mn_ok || !sc_ok || !yr_ok do return 0, false
	t, ok := time.datetime_to_time(year, time.Month(month), day, hour, min_, sec, 0)
	if !ok do return 0, false
	return time.to_unix_seconds(t), true
}

// bridge_shell_session_pid_is_plausible checks whether pid is still alive and
// is plausibly the same process that produced the given session.
//
// Portably uses `LC_ALL=C ps -p <pid> -o lstart=,command=` — both keywords
// exist on procps (Linux) and BSD ps (macOS), giving one code path with no
// /proc dependency.  BOTH conditions must hold; there is no fallback:
//   (a) The base executable name (after last '/', before first space) extracted
//       from ps `command=` matches the same extraction from the spec cmd.
//       Exact match, not prefix — we have full names from `command=` so there
//       is no reason to accept a prefix match.
//   (b) The ps `lstart=` wall-clock start time matches the spec started_at
//       (RFC3339) within 5 s.  5 s absorbs the gap between process launch and
//       spec-write; it is far too small to be fooled by PID reuse (a recycled
//       PID from a dead process has a different start time by definition).
//
// If ps fails, the output is unparseable, started_at is absent, or either
// check does not match → returns false (skip the kill, still mark the session
// dead and emit shell_exited).  Killing the wrong process is worse than leaving
// a stale spec.
bridge_shell_session_pid_is_plausible :: proc(pid: int, cmd: string, started_at: string) -> bool {
	if pid <= 0 || cmd == "" || started_at == "" do return false

	// The OS reports the process's start time and command (`ps` on Unix).
	lstart_sec, ps_command, ps_ok := bridge_os_process_lstart_and_command(pid)
	if !ps_ok do return false

	// (a) Base executable name match.
	if bridge_os_exe_base(ps_command) != bridge_os_exe_base(cmd) do return false

	// (b) Start-time check: lstart vs started_at within 5 s.
	started_time, consumed := time.rfc3339_to_time_utc(started_at)
	if consumed == 0 do return false
	started_sec := time.to_unix_seconds(started_time)
	diff := lstart_sec - started_sec
	if diff < 0 do diff = -diff
	return diff <= 5
}

// bridge_shell_session_reconcile loads persisted specs from disk, then for
// each spec checks whether the daemon still tracks it in daemon_agents:
//
//   - found AND alive   → re-register as Running (REQ-RECON-1)
//   - not found (or found-dead): idempotency guard skips if already terminal;
//       if the OS process is still alive and plausibly ours, kill it
//       asynchronously and report status "killed" (REQ-RECON-3);
//       otherwise report status "failed" (REQ-RECON-2).
//     In both cases emit a shell_exited event so the hub DB clears.
//
// REQ-RECON-4 claimed all kinds are handled identically via the daemon roster.
// That is TRUE ONLY FOR PTY-HOST-SPAWNED SESSIONS, and REQ-SHELL-2 made the
// difference load-bearing by persisting specs for direct-child runs as well.
//
// THE BUG THIS BRANCH FIXES (C5). The retired bridge-local exec path spawned a run as
// a direct os.process_start child. It is never in the pty-host roster, so
// `found_alive` can never be set for it, and it fell straight through to the
// "not found -> pid is plausible -> kill it" branch below — on every hub WS
// reconnect, against a run that was perfectly alive and still tracked in this
// bridge's own memory. Persisting run specs is what exposed it; before that,
// reconcile simply never saw these sessions.
//
// REQ-SHELL-7 deleted that producer, so nothing running this code creates a
// direct-child session any more. THE BRANCH IS STILL LIVE AND STILL TESTED: a bridge
// upgraded past that commit reads specs written before it, and those describe direct
// children. Deleting the producer does not delete the reader.
//
// So the roster question is asked ONLY of sessions that can answer it
// (s.pty_host), and a direct child is resolved by the three-way rule in
// bridge_shell_session_reconcile_direct_child below.
//
// Idempotency: sessions already in a terminal state (Failed/Exited/Killed) in
// the in-memory map are skipped so re-connections don't double-process them.
bridge_shell_session_reconcile :: proc(m: ^Bridge_Shell_Session_Map, daemon_agents: []Pty_Host_Agent_Info, data_dir: string) {
	// THE MAP'S allocator, not context.allocator: a spec loaded here may be handed
	// straight to bridge_shell_session_register, which makes the map responsible for
	// freeing it later. Loading through a different allocator than the map frees
	// through is the mismatch this runs on a background thread to discover.
	allocator := bridge_shell_session_map_allocator(m)
	specs := bridge_shell_session_load_specs(data_dir, allocator)
	if specs == nil do return
	defer delete(specs, allocator)

	for s in specs {
		// Each spec's strings are freshly cloned by load_specs. Registering a
		// session hands them to the map; any spec we skip owns strings nothing
		// else will ever free, and reconcile re-reads the same on-disk specs on
		// every reconnect — so a skipped spec would otherwise leak its full
		// string set, forever, on a non-arena background thread.
		transferred := false
		defer if !transferred do bridge_shell_session_free_fields(s, allocator)

		// A KNOWN direct child is never in the roster; resolving it there would reap
		// a live process. It gets its own liveness rule instead.
		//
		// A spec of UNKNOWN provenance (pre-REQ-SHELL-2, no pty_host key) is NOT
		// treated as a direct child: it may be a genuinely pty-host-spawned session,
		// and a roster hit is strictly more information than ps can produce, so it
		// falls through to the roster below and only reaches the direct-child rule if
		// the roster does not know it. Trying the roster first costs one comparison
		// against a list already in hand.
		if !s.pty_host && s.pty_host_provenance_known {
			handled, took := bridge_shell_session_reconcile_direct_child(m, s, data_dir)
			if took do transferred = true
			if handled do continue
			// Not handled = not in the map = an orphan from a previous bridge life.
			// Fall through to the kill-and-report path below, which is unchanged.
		} else {
			// daemon key: shell_id when set, else session_id (kind=Command parity)
			match_id := s.shell_id if s.shell_id != "" else s.session_id

			found_alive := false
			for d in daemon_agents {
				if d.instance_id == match_id {
					if d.alive {
						found_alive = true
						updated      := s
						updated.status = .Running
						updated.pid    = int(d.pid)
						// Re-saved with provenance now recorded, so a legacy spec becomes a
						// known-pty_host spec the first time reconcile reclaims it and never
						// takes the unknown path again.
						updated.pty_host = true
						updated.pty_host_provenance_known = true
						// SPEC FIRST, THEN REGISTER: save_spec reads every string of
						// `updated`, which the map owns the moment register takes it, and
						// this runs on the reconnect thread with the hub reissuing starts.
						bridge_shell_session_save_spec(data_dir, updated)
						bridge_shell_session_register(m, &updated) // CONSUMES updated
						transferred = true
					}
					// found-dead: treat same as not-found (session exited in daemon)
					break
				}
			}
			if found_alive do continue

			// Unknown provenance and the roster does not know it either: it may still
			// be a direct child from a legacy spec, so give it the ps-based rule before
			// falling through to the kill path. Without this, a legacy direct-child run
			// that is alive and owned by this process would be reaped.
			if !s.pty_host_provenance_known {
				handled, took := bridge_shell_session_reconcile_direct_child(m, s, data_dir)
				if took do transferred = true
				if handled do continue
			}
		}

		// Idempotency: skip sessions already in a terminal state. Only the status is
		// read, so this takes the scalar copy and allocates nothing.
		if existing, has := bridge_shell_session_scalars(m, s.session_id); has {
			switch existing.status {
			case .Failed, .Exited, .Killed:
				continue
			case .Running, .Starting:
				// fall through to reconcile
			}
		}

		// REQ-RECON-3: kill the OS process if still alive and verifiably ours.
		status_str := "failed"
		final_status := Bridge_Shell_Session_Status.Failed
		if s.pid > 0 && bridge_shell_session_pid_is_plausible(s.pid, s.cmd, s.started_at) {
			status_str   = "killed"
			final_status = .Killed
			kctx            := new(Bridge_Shell_Orphan_Kill_Ctx)
			kctx.pid         = i32(s.pid)
			kctx.cmd         = strings.clone(s.cmd)
			kctx.started_at  = strings.clone(s.started_at)
			thread.run_with_data(rawptr(kctx), bridge_shell_session_orphan_kill_worker)
		}

		// REQ-RECON-2: mark dead in the local map, remove spec, notify hub.
		//
		// THE ID IS CLONED FIRST (REQ-SHELL-11 review). `updated := s` SHARES every
		// string with the spec, so once register has it, s.session_id is map-owned too —
		// and the three reads below (delete_spec, wait_signal_exit, the event json) would
		// be reads of memory a concurrent re-register can free. Zeroing register's
		// argument does not help here: it zeroes `updated`, while `s` still aliases the
		// same data.
		//   Cloning rather than reordering, because the ORDER IS LOAD-BEARING: the map
		// must say terminal BEFORE wait_signal_exit releases a waiter, or the released
		// waiter re-reads the session, still sees Running, and reports a live run it was
		// just told had ended. One small allocation on a path that already pays a `ps`
		// popen per session.
		sid := strings.clone(s.session_id, allocator)
		defer delete(sid, allocator)

		updated              := s
		updated.status        = final_status
		updated.exit_code_set = true
		updated.exit_code     = 1
		bridge_shell_session_register(m, &updated) // CONSUMES updated; s now aliases map memory
		transferred = true
		bridge_shell_session_delete_spec(data_dir, sid)
		// Release any foreground caller parked on this session. Reachable for a
		// pty-host session found dead within THIS bridge's life; a true cross-restart
		// orphan has no waiter and the signal is a harmless no-op. Additive to the
		// hub event below, never a replacement for it (W3).
		bridge_shell_wait_signal_exit(sid, final_status, 1, true)
		// s.run_seq, read before register consumed `updated` — the run this orphaned
		// session belonged to, not whatever it may have been restarted into since.
		event := bridge_shell_exited_event_json(sid, 1, true, status_str, s.run_seq)
		bridge_shell_exited_enqueue(event)
		delete(event)
	}
}

// bridge_shell_session_reconcile_direct_child resolves ONE spec whose process is
// a direct os.process_start child of the bridge rather than a pty-host session.
//
// Returns (handled, transferred): `handled` is false only for the not-in-map case,
// which the CALLER must then resolve through its orphan kill-and-report path —
// returning false there rather than swallowing it is what keeps a cross-restart
// orphan from being silently dropped. `transferred` says the session was handed to
// the map, so the caller must not free its strings.
//
// Three outcomes, and the middle one is why map presence alone is not enough:
//
//   in map, non-terminal, AND pid plausible -> genuinely alive and THIS bridge
//       process owns it. SKIP: leave it running, leave its spec in place.
//
//   in map, non-terminal, NOT pid plausible -> it died and we missed the exit.
//       Report it terminal and clear the spec, but do NOT kill: there is nothing
//       left to kill. Trusting map presence alone here would be the real hazard —
//       if an exit event is ever missed the entry stays non-terminal FOREVER,
//       reconcile skips it on every pass, and the hub reports a dead run as
//       running with the very mechanism that would have corrected it now the one
//       suppressing it. That is a live-on-hub/dead-on-bridge divergence made
//       permanent and self-reinforcing.
//
//   not in map -> an orphan from a PREVIOUS bridge life (the map is empty after a
//       restart; the process survived because it was reparented to init). Fall
//       through to the caller's existing kill-and-report path, unchanged.
//
// COST, deliberately paid: one `ps -p` popen per non-terminal direct-child run per
// reconcile pass. Reconcile runs on hub WS reconnect, not in any hot path, and the
// kill branch below has always paid exactly this. DO NOT "optimise" it away — the
// popen IS the liveness proof, and replacing it with in-memory bookkeeping
// reintroduces the permanent-divergence case above.
bridge_shell_session_reconcile_direct_child :: proc(m: ^Bridge_Shell_Session_Map, s: Bridge_Shell_Session, data_dir: string) -> (handled: bool, transferred: bool) {
	// A SNAPSHOT, not a borrow: the pid-plausibility check below shells out to `ps`,
	// which is exactly the kind of blocking gap in which another thread can re-register
	// this session and free the strings a borrowed struct would still be pointing at.
	existing, in_map := bridge_shell_session_snapshot(m, s.session_id)
	if !in_map do return false, false // orphan from a previous life: caller's kill path
	defer bridge_shell_session_snapshot_destroy(m, existing)

	switch existing.status {
	case .Failed, .Exited, .Killed:
		// Already terminal: the exit path owns the spec deletion. Idempotent, as
		// before — repeated reconnects must not re-report a finished run.
		return true, false
	case .Running, .Starting:
		// fall through
	}

	if bridge_shell_session_pid_is_plausible(existing.pid, existing.cmd, existing.started_at) {
		return true, false // alive and ours: leave it entirely alone
	}

	// Died with the exit unobserved. Mark terminal, clear the spec, and tell the
	// hub — the same reporting the exit path would have done, just late.
	//
	// THE ID IS CLONED FIRST, for the same reason as the orphan path in
	// bridge_shell_session_reconcile: `updated := s` shares its strings with the spec,
	// so after register every s.session_id read would be a read of map-owned memory,
	// and the map must say terminal before wait_signal_exit releases anyone.
	allocator := bridge_shell_session_map_allocator(m)
	sid := strings.clone(s.session_id, allocator)
	defer delete(sid, allocator)

	updated              := s
	updated.status        = .Failed
	updated.exit_code_set = true
	updated.exit_code     = 1
	bridge_shell_session_register(m, &updated) // CONSUMES updated; s now aliases map memory
	bridge_shell_session_delete_spec(data_dir, sid)
	// Release any foreground caller still parked on it, or it would block until its
	// own ceiling on a run that ended long ago (W3: additive, alongside the hub event).
	bridge_shell_wait_signal_exit(sid, .Failed, 1, true)
	event := bridge_shell_exited_event_json(sid, 1, true, "failed", s.run_seq)
	bridge_shell_exited_enqueue(event)
	delete(event)
	return true, true
}

// ---- string helpers ------------------------------------------------------

bridge_shell_session_kind_str :: proc(k: Bridge_Shell_Session_Kind) -> string {
	switch k {
	case .Run:    return "run"
	case .Shell:  return "shell"
	case .Server: return "server"
	}
	return "run"
}

// Every unrecognised spelling is COERCED to .Run, the kind with no scope prerequisites
// of its own. Be precise about what that means: this is silent coercion, not rejection.
// The retired vocabulary — "agent", "command", "interactive" — takes the same default as
// genuine garbage would, so nothing here distinguishes a stale client from a malformed
// frame, and nothing here reports either.
//
// That is acceptable only because the real gate is upstream: the hub validates kind
// before it ever reaches the wire (domain.shell_session_validate_scope), so a retired
// spelling cannot arrive on this path in the first place. This default exists so a
// malformed frame does not crash the bridge, and for no other reason. It is not a
// parsing policy, and it must not be read as one — in particular it is NOT a
// bridge-side check on the kind vocabulary.
bridge_shell_session_kind_from_str :: proc(s: string) -> Bridge_Shell_Session_Kind {
	switch s {
	case "shell":  return .Shell
	case "server": return .Server
	}
	return .Run
}

bridge_shell_session_status_str :: proc(s: Bridge_Shell_Session_Status) -> string {
	switch s {
	case .Starting: return "starting"
	case .Running:  return "running"
	case .Exited:   return "exited"
	case .Killed:   return "killed"
	case .Failed:   return "failed"
	}
	return "failed"
}

bridge_shell_session_status_from_str :: proc(s: string) -> Bridge_Shell_Session_Status {
	switch s {
	case "starting": return .Starting
	case "running":  return .Running
	case "exited":   return .Exited
	case "killed":   return .Killed
	}
	return .Failed
}

// bridge_shell_session_exec_status_str maps the internal session status to the
// "running" | "completed" | "failed" vocabulary the run RESPONSE exposes — the shape
// bridge_shell_write_session_json renders for a finished run. It is a narrower
// vocabulary than the internal status on purpose: a caller holding a result cares
// whether the command worked, not which flavour of not-running it reached.
bridge_shell_session_exec_status_str :: proc(s: ^Bridge_Shell_Session) -> string {
	switch s.status {
	case .Starting, .Running: return "running"
	case .Exited:             return "completed"
	case .Killed, .Failed:    return "failed"
	}
	return "failed"
}
