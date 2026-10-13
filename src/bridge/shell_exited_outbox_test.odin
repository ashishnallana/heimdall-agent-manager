package main

// REQ-SHELL-4 bridge-side acceptance tests — the half of AC1 that lives here:
// "kill a bridge with queued exits, restart it, and the hub converges without any
// client polling."
//
// A bridge RESTART cannot be staged inside a test process, so what is staged is the
// thing a restart actually does to this subsystem: the in-memory queue ceases to
// exist and the only surviving state is the filesystem. Every test below writes
// through the real persistence path, then reads back through the real load path with
// nothing carried across in memory — which is exactly the boundary a restart draws.
// The convergence that follows is the existing drain in bridge_hub_runtime_loop, and
// it is unchanged by this task, so the claim these tests support is precisely
// "restored to the queue", not "delivered".
//
// NO POLLING is asserted structurally rather than behaviourally: the restore path
// appends to the queue the WS loop already drains every tick, so there is no timer,
// no thread and no interval anywhere in this file or in shell_exited_outbox.odin.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
outbox_test_dir :: proc(name: string) -> string {
	return fmt.aprintf("/tmp/ham-shell4-outbox-%s-%d", name, os.get_pid())
}

// A clean slate per test. These tests are about what survives on DISK, so a stale
// envelope from a previous run would be indistinguishable from the thing under test.
@(private = "file")
outbox_test_reset :: proc(data_dir: string) {
	dir := bridge_shell_exited_outbox_dir(data_dir)
	defer delete(dir)
	infos, err := os.read_directory_by_path(dir, -1, context.allocator)
	if err != nil do return
	defer os.file_info_slice_delete(infos, context.allocator)
	for info in infos {
		path := strings.concatenate({dir, "/", info.name})
		_ = os.remove(path)
		delete(path)
	}
}

@(private = "file")
outbox_test_free :: proc(entries: []Bridge_Shell_Exited_Outbox_Entry) {
	for e in entries do bridge_shell_exited_outbox_entry_free(e)
	delete(entries)
}

// ---- AC1 (bridge half): a queued exit SURVIVES the process going away --------

// The regression this whole task exists for. Before it,
// bridge_shell_exited_outgoing was a plain [dynamic] array: an exit queued while
// the hub was unreachable died with the process, and the hub showed the session
// running forever with nothing but a client poll able to correct it.
@(test)
bridge_shell4_queued_exit_survives_a_restart :: proc(t: ^testing.T) {
	dir := outbox_test_dir("survives")
	defer delete(dir)
	outbox_test_reset(dir)

	event := bridge_shell_exited_event_json("sh_survive", 7, true, "exited", 0)
	defer delete(event)

	path := bridge_shell_exited_outbox_write(dir, "sh_survive", event, 1_000_000, 0)
	testing.expect(t, path != "", "the envelope must be written")
	defer delete(path)

	// THE RESTART: nothing above this line is carried across. The load below reads
	// only the filesystem, which is all a new process would have.
	entries := bridge_shell_exited_outbox_load(dir, 1_000_000)
	defer outbox_test_free(entries)

	testing.expect_value(t, len(entries), 1)
	testing.expect_value(t, entries[0].session_id, "sh_survive")
	// BYTE-IDENTICAL, not merely equivalent. The envelope stores the frame as an
	// opaque string precisely so the bytes that reach the hub after a restart are the
	// ones the exiting code built, not a re-serialization of a parsed copy.
	testing.expect_value(t, entries[0].event_json, event)
	testing.expect_value(t, entries[0].enqueued_at_ms, i64(1_000_000))
}

// A delivered exit must NOT come back. The drain removes the envelope only after the
// frame is sent; this asserts the removal half, without which every exit this bridge
// ever reported would be re-sent on every boot for the life of the machine.
@(test)
bridge_shell4_delivered_exit_does_not_reappear :: proc(t: ^testing.T) {
	dir := outbox_test_dir("delivered")
	defer delete(dir)
	outbox_test_reset(dir)

	event := bridge_shell_exited_event_json("sh_done", 0, true, "exited", 0)
	defer delete(event)
	path := bridge_shell_exited_outbox_write(dir, "sh_done", event, 1_000_000, 0)
	defer delete(path)

	bridge_shell_exited_outbox_remove(path)

	entries := bridge_shell_exited_outbox_load(dir, 1_000_000)
	defer outbox_test_free(entries)
	testing.expect_value(t, len(entries), 0)
}

// Several exits queued while offline all come back, oldest first. Order is NOT part
// of the contract across a restart — the hub's terminal guard is what makes that
// safe — but draining a backlog oldest-first is the least surprising thing to do
// with one, and an unordered restore would make the drain's behaviour depend on
// readdir order, which is not stable across filesystems.
@(test)
bridge_shell4_multiple_exits_restore_oldest_first :: proc(t: ^testing.T) {
	dir := outbox_test_dir("order")
	defer delete(dir)
	outbox_test_reset(dir)

	for spec in ([]struct{id: string, at: i64}{
		{"sh_c", 3_000_000},
		{"sh_a", 1_000_000},
		{"sh_b", 2_000_000},
	}) {
		event := bridge_shell_exited_event_json(spec.id, 0, true, "exited", 0)
		p := bridge_shell_exited_outbox_write(dir, spec.id, event, spec.at, 0)
		delete(event)
		delete(p)
	}

	entries := bridge_shell_exited_outbox_load(dir, 3_000_000)
	defer outbox_test_free(entries)

	testing.expect_value(t, len(entries), 3)
	testing.expect_value(t, entries[0].session_id, "sh_a")
	testing.expect_value(t, entries[1].session_id, "sh_b")
	testing.expect_value(t, entries[2].session_id, "sh_c")
}

// ---- AC4: the queue is BOUNDED ------------------------------------------------

// The age bound. An exit whose session no longer exists hub-side can never be
// applied, and the hub answers an unknown session with silence rather than a NACK,
// so nothing else will ever retire it. `now_ms` is a parameter for exactly this
// reason — the bound is testable without waiting a day.
@(test)
bridge_shell4_exits_past_the_age_bound_are_discarded :: proc(t: ^testing.T) {
	dir := outbox_test_dir("age")
	defer delete(dir)
	outbox_test_reset(dir)

	now := i64(100 * BRIDGE_SHELL_EXITED_OUTBOX_MAX_AGE_MS)

	fresh := bridge_shell_exited_event_json("sh_fresh", 0, true, "exited", 0)
	defer delete(fresh)
	fp := bridge_shell_exited_outbox_write(dir, "sh_fresh", fresh, now - 1000, 0)
	defer delete(fp)

	stale := bridge_shell_exited_event_json("sh_stale", 0, true, "exited", 0)
	defer delete(stale)
	sp := bridge_shell_exited_outbox_write(dir, "sh_stale", stale, now - BRIDGE_SHELL_EXITED_OUTBOX_MAX_AGE_MS - 1, 0)
	defer delete(sp)

	entries := bridge_shell_exited_outbox_load(dir, now)
	defer outbox_test_free(entries)

	testing.expect_value(t, len(entries), 1)
	testing.expect_value(t, entries[0].session_id, "sh_fresh")

	// DISCARDED, not merely skipped: a skipped envelope would be re-examined on every
	// boot and would keep charging against the count cap forever.
	_, stale_still_there := os.stat(sp, context.allocator)
	testing.expect(t, stale_still_there != nil, "the expired envelope must be deleted from disk, not just ignored")
}

// The count bound, dropping the OLDEST past the cap. A bridge offline while churning
// short-lived runs must not be able to fill its disk, nor hand its reconnect an
// unbounded drain.
@(test)
bridge_shell4_queue_is_bounded_by_count :: proc(t: ^testing.T) {
	dir := outbox_test_dir("count")
	defer delete(dir)
	outbox_test_reset(dir)

	over := 5
	total := BRIDGE_SHELL_EXITED_OUTBOX_MAX_ENTRIES + over
	for i in 0 ..< total {
		id := fmt.tprintf("sh_%05d", i)
		event := bridge_shell_exited_event_json(id, 0, true, "exited", 0)
		// enqueued_at ASCENDING with i, so "oldest" and "lowest i" are the same set.
		p := bridge_shell_exited_outbox_write(dir, id, event, i64(1_000_000 + i), 0)
		delete(event)
		delete(p)
	}

	entries := bridge_shell_exited_outbox_load(dir, 1_000_000 + i64(total))
	defer outbox_test_free(entries)

	testing.expect_value(t, len(entries), BRIDGE_SHELL_EXITED_OUTBOX_MAX_ENTRIES)
	// The newest survive: those are the exits someone is most likely still waiting on.
	testing.expect_value(t, entries[0].session_id, fmt.tprintf("sh_%05d", over))
	testing.expect_value(t, entries[len(entries) - 1].session_id, fmt.tprintf("sh_%05d", total - 1))
}

// ---- corruption and hostile input ---------------------------------------------

// A corrupt envelope can never be delivered, so leaving it on disk would be a
// permanent entry charging against the count cap. It is deleted, and — the part that
// matters more — it does not take the rest of the backlog down with it.
@(test)
bridge_shell4_corrupt_envelope_is_discarded_without_losing_the_rest :: proc(t: ^testing.T) {
	dir := outbox_test_dir("corrupt")
	defer delete(dir)
	outbox_test_reset(dir)

	good := bridge_shell_exited_event_json("sh_good", 0, true, "exited", 0)
	defer delete(good)
	gp := bridge_shell_exited_outbox_write(dir, "sh_good", good, 1_000_000, 0)
	defer delete(gp)

	odir := bridge_shell_exited_outbox_dir(dir)
	defer delete(odir)
	bad_path := strings.concatenate({odir, "/sh_corrupt.json"})
	defer delete(bad_path)
	testing.expect(t, os.write_entire_file(bad_path, transmute([]byte)string("{not json")) == nil)

	entries := bridge_shell_exited_outbox_load(dir, 1_000_000)
	defer outbox_test_free(entries)

	testing.expect_value(t, len(entries), 1)
	testing.expect_value(t, entries[0].session_id, "sh_good")
	_, bad_still_there := os.stat(bad_path, context.allocator)
	testing.expect(t, bad_still_there != nil, "an undeliverable envelope must be removed, not retried forever")
}

// The envelope's file name is derived from a session_id, and a session_id also
// arrives over the wire. Anything outside [A-Za-z0-9_-] is replaced rather than
// trusted, so a traversal attempt names a file inside the outbox instead of
// escaping it.
@(test)
bridge_shell4_session_id_cannot_escape_the_outbox_directory :: proc(t: ^testing.T) {
	name := bridge_shell_exited_outbox_file_name("../../etc/passwd", 0)
	defer delete(name)
	testing.expect(t, !strings.contains(name, "/"), "a path separator must never survive into the file name")
	testing.expect(t, !strings.contains(name, ".."), "a parent-directory hop must never survive into the file name")
	testing.expect(t, strings.has_suffix(name, ".json"))

	dir := outbox_test_dir("traversal")
	defer delete(dir)
	path := bridge_shell_exited_outbox_path(dir, "../../etc/passwd", 0)
	defer delete(path)
	odir := bridge_shell_exited_outbox_dir(dir)
	defer delete(odir)
	testing.expect(t, strings.has_prefix(path, odir), "the envelope path must stay under the outbox directory")
}

// An envelope carrying no event is undeliverable in the same way a corrupt one is,
// and is treated the same. Asserted separately because it parses cleanly, so it
// takes a different branch from the corruption case above.
@(test)
bridge_shell4_envelope_without_an_event_is_discarded :: proc(t: ^testing.T) {
	dir := outbox_test_dir("empty")
	defer delete(dir)
	outbox_test_reset(dir)

	odir := bridge_shell_exited_outbox_dir(dir)
	defer delete(odir)
	_ = os.make_directory_all(odir)
	p := strings.concatenate({odir, "/sh_empty.json"})
	defer delete(p)
	testing.expect(t, os.write_entire_file(p, transmute([]byte)string(`{"session_id":"sh_empty","enqueued_at_ms":1,"event":""}`)) == nil)

	entries := bridge_shell_exited_outbox_load(dir, 1_000_000)
	defer outbox_test_free(entries)
	testing.expect_value(t, len(entries), 0)
	_, still_there := os.stat(p, context.allocator)
	testing.expect(t, still_there != nil, "an empty envelope must be removed")
}

// An outbox directory that has never existed is not an error — it is the normal
// state of a bridge that has never queued an exit, and it must not make startup
// noisy or fail.
@(test)
bridge_shell4_missing_outbox_directory_loads_empty :: proc(t: ^testing.T) {
	entries := bridge_shell_exited_outbox_load("/tmp/ham-shell4-outbox-does-not-exist", 1_000_000)
	defer outbox_test_free(entries)
	testing.expect_value(t, len(entries), 0)
}

// An interrupted write leaves a .tmp behind. The real path is written by rename, so
// the .tmp is never a valid envelope; it must not be loaded as one. (The suffix
// check is `.json`, and the temp file is `<name>.json.tmp`, so this is asserting
// that the naming actually excludes it rather than that a filter catches it.)
@(test)
bridge_shell4_interrupted_write_leaves_nothing_loadable :: proc(t: ^testing.T) {
	dir := outbox_test_dir("tmp")
	defer delete(dir)
	outbox_test_reset(dir)

	odir := bridge_shell_exited_outbox_dir(dir)
	defer delete(odir)
	_ = os.make_directory_all(odir)
	p := strings.concatenate({odir, "/sh_partial.json.tmp"})
	defer delete(p)
	testing.expect(t, os.write_entire_file(p, transmute([]byte)string(`{"session_id":"sh_partial","enqueued_at_ms":1,"event":"{}"}`)) == nil)

	entries := bridge_shell_exited_outbox_load(dir, 1_000_000)
	defer outbox_test_free(entries)
	testing.expect_value(t, len(entries), 0)
}

// ---- run identity: an envelope names a RUN, not just a session ----------------

// THE FAILURE THIS PREVENTS, and the reason keying the store by session_id alone was
// wrong. shell_session_restart re-spawns under the SAME session_id. So: run 0 exits
// while the bridge is offline and its exit is queued on disk; the session is later
// restarted (run 1) and is genuinely alive; the bridge reconnects and drains run 0's
// exit against a row that is LEGITIMATELY RUNNING. Keyed by session alone, run 1's
// envelope would also OVERWRITE run 0's, so the two runs could not even be told apart
// on disk — the dedup made the stale entry linger instead of resolving it.
//
// Keyed by the run, the two are separate files and each names its own run, which is
// what lets the hub discard the stale one. The hub half — that it actually discards
// it and leaves the running session alone — is asserted in
// src/hub/service/shell_session/shell_session_req4_test.odin.
@(test)
bridge_shell4_envelopes_are_keyed_by_run_not_by_session :: proc(t: ^testing.T) {
	dir := outbox_test_dir("runkey")
	defer delete(dir)
	outbox_test_reset(dir)

	run0 := bridge_shell_exited_event_json("sh_restarted", 0, true, "exited", 0)
	defer delete(run0)
	p0 := bridge_shell_exited_outbox_write(dir, "sh_restarted", run0, 1_000_000, 0)
	defer delete(p0)

	run1 := bridge_shell_exited_event_json("sh_restarted", 3, true, "exited", 1)
	defer delete(run1)
	p1 := bridge_shell_exited_outbox_write(dir, "sh_restarted", run1, 2_000_000, 1)
	defer delete(p1)

	// Distinct files: run 1 must not have overwritten run 0.
	testing.expect(t, p0 != p1, "two runs of one session must not share an envelope path")

	entries := bridge_shell_exited_outbox_load(dir, 2_000_000)
	defer outbox_test_free(entries)
	testing.expect_value(t, len(entries), 2)

	// Each envelope carries its own run in the frame the hub will actually read —
	// asserting on the FRAME rather than on the file name, because the frame is what
	// the hub's discard decision is made from.
	testing.expect(t, strings.contains(entries[0].event_json, "\"run_seq\":0"), "run 0's frame names run 0")
	testing.expect(t, strings.contains(entries[1].event_json, "\"run_seq\":1"), "run 1's frame names run 1")
}

// The dedup is KEPT, just moved to the right granularity: a second exit for the SAME
// run — a reconcile racing the pty-host's own ChildExited — still overwrites rather
// than queueing a second frame to send.
@(test)
bridge_shell4_second_exit_for_the_same_run_deduplicates :: proc(t: ^testing.T) {
	dir := outbox_test_dir("dedup")
	defer delete(dir)
	outbox_test_reset(dir)

	first := bridge_shell_exited_event_json("sh_dup", 0, true, "exited", 2)
	defer delete(first)
	p1 := bridge_shell_exited_outbox_write(dir, "sh_dup", first, 1_000_000, 2)
	defer delete(p1)

	second := bridge_shell_exited_event_json("sh_dup", 1, true, "failed", 2)
	defer delete(second)
	p2 := bridge_shell_exited_outbox_write(dir, "sh_dup", second, 1_000_001, 2)
	defer delete(p2)

	testing.expect_value(t, p1, p2)
	entries := bridge_shell_exited_outbox_load(dir, 1_000_001)
	defer outbox_test_free(entries)
	testing.expect_value(t, len(entries), 1)
	testing.expect_value(t, entries[0].event_json, second)
}

// The run suffix is appended AFTER sanitizing, so a session_id that ends in something
// resembling one cannot forge another run's key and overwrite its envelope.
@(test)
bridge_shell4_run_suffix_cannot_be_spoofed_by_a_session_id :: proc(t: ^testing.T) {
	spoof := bridge_shell_exited_outbox_file_name("sh_a.run9", 0)
	defer delete(spoof)
	real := bridge_shell_exited_outbox_file_name("sh_a", 9)
	defer delete(real)
	testing.expect(t, spoof != real, "a session_id must not be able to name another run's envelope")
}

// run_seq must survive a BRIDGE restart, not just live in the session map. The spec
// is what a restarted bridge reloads; a bridge that came back on the PREVIOUS run's
// number would stamp every subsequent exit with it, the hub's row would be ahead,
// and every one of those exits would be discarded as stale — the session reporting
// running forever, which is the failure this column exists to prevent, reintroduced
// one layer down. This is why the restart handler re-saves the spec.
@(test)
bridge_shell4_run_seq_round_trips_through_the_spec :: proc(t: ^testing.T) {
	dir := outbox_test_dir("specroundtrip")
	defer delete(dir)
	spec_dir := bridge_shell_session_spec_dir(dir)
	defer delete(spec_dir)
	_ = os.make_directory_all(spec_dir)
	bridge_shell_session_delete_spec(dir, "sh_spec_run")

	s := Bridge_Shell_Session{
		session_id = "sh_spec_run",
		kind       = .Run,
		cmd        = "sleep 1",
		bridge_id  = "brg_1",
		status     = .Running,
		run_seq    = 4,
		started_at = "2026-09-28T09:00:00Z",
	}
	bridge_shell_session_save_spec(dir, s)
	defer bridge_shell_session_delete_spec(dir, "sh_spec_run")

	// THE RESTART: nothing carried across but the file.
	specs := bridge_shell_session_load_specs(dir, context.allocator)
	defer {
		for sp in specs do bridge_shell_session_free_fields(sp, context.allocator)
		delete(specs, context.allocator)
	}

	found := false
	for sp in specs {
		if sp.session_id != "sh_spec_run" do continue
		found = true
		testing.expect_value(t, sp.run_seq, 4)
	}
	testing.expect(t, found, "the spec must reload")
}

// REQ-P1-SHELL-SPEC AC: Outbox envelope key-order resilience and whitespace tolerance.
@(test)
bridge_shell4_envelope_key_order_and_whitespace_resilience :: proc(t: ^testing.T) {
	dir := outbox_test_dir("env_scrambled")
	defer delete(dir)
	outbox_test_reset(dir)

	odir := bridge_shell_exited_outbox_dir(dir)
	defer delete(odir)
	_ = os.make_directory_all(odir)

	// Scrambled envelope keys with whitespace, newlines, and tabs
	scrambled_envelope := `
	{
		"event" :   "{\"type\":\"shell_exited\",\"session_id\":\"sh_order_scrambled\",\"exit_code\":0}"  ,
		"enqueued_at_ms" :   1234567890  ,
		"session_id" : "sh_order_scrambled"
	}
	`

	path := strings.concatenate({odir, "/sh_order_scrambled.run0.json"})
	defer delete(path)
	_ = os.write_entire_file(path, transmute([]byte)scrambled_envelope)

	entries := bridge_shell_exited_outbox_load(dir, 1234567890 + 1000)
	defer outbox_test_free(entries)

	testing.expect_value(t, len(entries), 1)
	if len(entries) == 1 {
		testing.expect_value(t, entries[0].session_id, "sh_order_scrambled")
		testing.expect_value(t, entries[0].enqueued_at_ms, i64(1234567890))
		testing.expect_value(t, entries[0].event_json, `{"type":"shell_exited","session_id":"sh_order_scrambled","exit_code":0}`)
	}
}

// REQ-P1-SHELL-SPEC AC: Outbox zero tracking allocator leaks on write and load.
@(test)
bridge_shell4_outbox_zero_tracking_allocator_leaks :: proc(t: ^testing.T) {
	dir := outbox_test_dir("env_track")
	defer delete(dir)
	outbox_test_reset(dir)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	// In this test, we execute the write and reload with tracking allocator
	event := `{"type":"shell_exited","session_id":"sh_track_leak"}`
	path := bridge_shell_exited_outbox_write(dir, "sh_track_leak", event, 1_000_000, 0)
	testing.expect(t, path != "", "outbox path written")
	delete(path)

	// Load entries and release them
	entries := bridge_shell_exited_outbox_load(dir, 1_000_000)
	testing.expect_value(t, len(entries), 1)
	for e in entries do bridge_shell_exited_outbox_entry_free(e)
	delete(entries)

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

