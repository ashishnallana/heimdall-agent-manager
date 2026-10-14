package main

// REQ-SHELL-4: a shell_exited outbox that survives a BRIDGE RESTART.
//
// The in-memory queue in hub_runtime_client.odin already survives a DISCONNECT —
// bridge_shell_exited_drain_outgoing re-queues the item at the head on send failure
// and marks the connection dead, so the exit drains on reconnect. What it did not
// survive was the bridge process going away: the queue was a plain [dynamic] array,
// so a restart with queued exits left the hub showing those sessions as running
// forever, with nothing but a client poll to ever correct it.
//
// This file gives that queue a disk backing, modelled on the spec store in
// bridge_shell_session.odin (atomic .tmp + rename, one JSON file per entry) because
// that is the persistence idiom this package already uses.
//
// DELIVERY CONTRACT — at-least-once, never at-most-once.
// The file is removed only AFTER the frame is handed to the WS successfully. A crash
// in the window between the send and the remove replays that exit on the next boot.
// That is deliberate: losing an exit strands a session as "running" forever, while
// repeating one is harmless because the hub's apply is idempotent
// (shell_session_handle_exited returns early on an already-terminal row). We take
// the duplicate over the loss.
//
// ORDER is explicitly NOT guaranteed across a restart: entries reload sorted by the
// moment they were enqueued, but a replayed exit can still arrive after a newer,
// more accurate terminal status reached the hub by another route. The hub's terminal
// guard is what makes that safe — the bridge does not try to order its way out of it.

import json "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// BRIDGE_SHELL_EXITED_OUTBOX_MAX_AGE_MS bounds how long an undeliverable exit is
// kept before it is dropped (REQ-SHELL-4 §4). An exit whose session no longer
// exists hub-side — the row was deleted, or the hub's DB was reset — can never be
// applied, and without a bound it would be re-sent on every reconnect for the life
// of the machine.
//
// 24h is chosen to be comfortably longer than any plausible hub outage that is
// still worth converging after: past a day the session's status is of no
// operational interest to anyone, and the honest answer is that it is gone rather
// than a resurrected row appearing in a list days later.
BRIDGE_SHELL_EXITED_OUTBOX_MAX_AGE_MS :: i64(24 * 60 * 60 * 1000)

// BRIDGE_SHELL_EXITED_OUTBOX_MAX_ENTRIES bounds the queue by COUNT as well, so a
// bridge that is offline while churning through short-lived runs cannot fill its
// disk (or its reconnect drain) with exits. When the cap is exceeded the OLDEST
// entries are dropped: the newest exits are the ones a user is most likely still
// watching for.
BRIDGE_SHELL_EXITED_OUTBOX_MAX_ENTRIES :: 512

// bridge_shell_exited_outbox_dir returns the outbox directory. The result is ALWAYS
// a fresh allocation (concatenate, never an alias of data_dir), so every caller owns
// it and must delete it — the same contract as bridge_shell_session_spec_dir.
bridge_shell_exited_outbox_dir :: proc(data_dir: string) -> string {
	return strings.concatenate({strings.trim_right(data_dir, "/"), "/shell_exited_outbox"})
}

// bridge_shell_exited_outbox_file_name maps a RUN to its envelope's file name.
//
// KEYED BY (session_id, run_seq), NOT BY session_id ALONE. The key is what makes the
// store deduplicating — one envelope per run, so a reconcile racing the pty-host's
// own ChildExited overwrites rather than queueing a second frame — and getting its
// GRANULARITY wrong is worse than having no dedup at all:
//
// A session_id is NOT a run. shell_session_restart re-spawns under the same
// session_id. Key by session alone and run #1's exit, queued while the bridge was
// offline, sits on disk under the same name the restarted session would use, is
// still there when the bridge reconnects, and is delivered against a row that is
// LEGITIMATELY RUNNING — the hub marks a live session terminal on the strength of a
// previous run's exit. Deduplication makes that entry LINGER, so keying too coarsely
// raises the odds of the divergence rather than lowering them.
//
// Keying by the run keeps the dedup and removes the confusion: the stale entry is a
// separate file, and the hub discards it on arrival because its run_seq is older
// than the row's.
//
// Session ids are minted by the bridge and are already [A-Za-z0-9_], but this is a
// path built from a value that also arrives over the wire, so anything outside that
// set is replaced rather than trusted — a session_id of "../x" must not be able to
// name a file outside the outbox.
bridge_shell_exited_outbox_file_name :: proc(session_id: string, run_seq: int) -> string {
	b := strings.builder_make()
	for ch in session_id {
		switch {
		case ch >= 'a' && ch <= 'z', ch >= 'A' && ch <= 'Z', ch >= '0' && ch <= '9', ch == '_', ch == '-':
			strings.write_rune(&b, ch)
		case:
			strings.write_byte(&b, '_')
		}
	}
	// The run suffix is appended AFTER sanitizing, so it cannot be spoofed by a
	// session_id that ends in something resembling one.
	strings.write_string(&b, ".run")
	{
		buf: [24]byte
		strings.write_string(&b, strconv.write_int(buf[:], i64(run_seq), 10))
	}
	strings.write_string(&b, ".json")
	return strings.to_string(b)
}

// bridge_shell_exited_outbox_path is the full path of a session's envelope.
// Caller owns the result.
bridge_shell_exited_outbox_path :: proc(data_dir, session_id: string, run_seq: int) -> string {
	dir := bridge_shell_exited_outbox_dir(data_dir)
	defer delete(dir)
	name := bridge_shell_exited_outbox_file_name(session_id, run_seq)
	defer delete(name)
	return strings.concatenate({dir, "/", name})
}

// Shell_Exited_Outbox_Envelope is the typed disk representation of a queued exit.
Shell_Exited_Outbox_Envelope :: struct {
	session_id:     string `json:"session_id"`,
	enqueued_at_ms: i64    `json:"enqueued_at_ms"`,
	event:          string `json:"event"`,
}

// bridge_shell_exited_outbox_write persists one queued exit, atomically. Returns the
// path it wrote, or "" when it could not write — a failure here is not fatal: the
// in-memory queue still carries the event, so the only thing lost is restart
// survival for that one exit, and saying so on stderr beats dropping the exit.
// Caller owns a non-empty result.
bridge_shell_exited_outbox_write :: proc(data_dir, session_id, event_json: string, enqueued_at_ms: i64, run_seq: int) -> string {
	if strings.trim_space(session_id) == "" || strings.trim_space(event_json) == "" do return ""

	dir := bridge_shell_exited_outbox_dir(data_dir)
	defer delete(dir)
	_ = bridge_make_directory_all(dir)

	path := bridge_shell_exited_outbox_path(data_dir, session_id, run_seq)
	tmp := strings.concatenate({path, ".tmp"})
	defer delete(tmp)

	envelope := Shell_Exited_Outbox_Envelope{
		session_id     = session_id,
		enqueued_at_ms = enqueued_at_ms,
		event          = event_json,
	}

	payload, merr := json.marshal(envelope, allocator = context.temp_allocator)
	if merr != nil {
		fmt.eprintln("bridge shell_exited outbox: failed to marshal envelope:", merr)
		delete(path)
		return ""
	}

	if os.write_entire_file(tmp, payload) != nil {
		fmt.eprintln("bridge shell_exited outbox: could not write", tmp, "— this exit will not survive a restart")
		blog_warn(.outbox_persist_failed, blog_sym(.stage, .write))
		delete(path)
		return ""
	}
	if os.rename(tmp, path) != nil {
		fmt.eprintln("bridge shell_exited outbox: could not rename", tmp, "->", path)
		blog_warn(.outbox_persist_failed, blog_sym(.stage, .rename))
		_ = os.remove(tmp)
		delete(path)
		return ""
	}
	return path
}

// bridge_shell_exited_outbox_remove drops a delivered entry. Safe to call with "".
bridge_shell_exited_outbox_remove :: proc(path: string) {
	if path == "" do return
	_ = os.remove(path)
}

// Bridge_Shell_Exited_Outbox_Entry is one reloaded envelope. The caller owns
// event_json and path.
Bridge_Shell_Exited_Outbox_Entry :: struct {
	session_id:     string,
	event_json:     string,
	path:           string,
	enqueued_at_ms: i64,
}

// bridge_shell_exited_outbox_entry_free releases one reloaded entry.
bridge_shell_exited_outbox_entry_free :: proc(e: Bridge_Shell_Exited_Outbox_Entry) {
	if e.session_id != "" do delete(e.session_id)
	if e.event_json != "" do delete(e.event_json)
	if e.path != "" do delete(e.path)
}

// bridge_shell_exited_outbox_load reads every envelope back, OLDEST FIRST, applying
// both bounds (§4) as it goes: entries older than the age bound and entries beyond
// the count cap are deleted from disk and not returned. `now_ms` is passed in rather
// than read here so the bound is testable without waiting a day.
//
// Corrupt or unreadable envelopes are reported and DELETED rather than skipped: a
// file that cannot be parsed can never be delivered, so leaving it would be a
// permanent entry that the count cap then charges against live exits.
//
// The caller owns the returned slice and each entry's strings; release them with
// bridge_shell_exited_outbox_entry_free and delete(entries).
bridge_shell_exited_outbox_load :: proc(data_dir: string, now_ms: i64) -> []Bridge_Shell_Exited_Outbox_Entry {
	dir := bridge_shell_exited_outbox_dir(data_dir)
	defer delete(dir)

	infos, rerr := os.read_directory_by_path(dir, -1, context.allocator)
	if rerr != nil do return nil
	defer os.file_info_slice_delete(infos, context.allocator)

	entries := make([dynamic]Bridge_Shell_Exited_Outbox_Entry)
	for info in infos {
		if !strings.has_suffix(info.name, ".json") do continue

		path := strings.concatenate({dir, "/", info.name})
		raw, ferr := os.read_entire_file(path, context.allocator)
		if ferr != nil {
			delete(path)
			continue
		}
		defer delete(raw)

		envelope: Shell_Exited_Outbox_Envelope
		jerr := json.unmarshal(raw, &envelope, allocator = context.temp_allocator)
		if jerr != nil {
			fmt.eprintln("bridge shell_exited outbox: corrupt envelope, discarding:", info.name)
			_ = os.remove(path)
			delete(path)
			continue
		}

		e: Bridge_Shell_Exited_Outbox_Entry
		e.path = path
		e.session_id = strings.clone(envelope.session_id)
		e.event_json = strings.clone(envelope.event)
		e.enqueued_at_ms = envelope.enqueued_at_ms

		if strings.trim_space(e.event_json) == "" {
			fmt.eprintln("bridge shell_exited outbox: envelope carries no event, discarding:", info.name)
			_ = os.remove(path)
			bridge_shell_exited_outbox_entry_free(e)
			continue
		}

		// §4 age bound.
		if now_ms > 0 && e.enqueued_at_ms > 0 && now_ms - e.enqueued_at_ms > BRIDGE_SHELL_EXITED_OUTBOX_MAX_AGE_MS {
			fmt.eprintln("bridge shell_exited outbox: dropping exit older than the retention bound:", e.session_id)
			_ = os.remove(path)
			bridge_shell_exited_outbox_entry_free(e)
			continue
		}

		append(&entries, e)
	}

	// Oldest first. read_directory_by_path gives no ordering guarantee, and while
	// order is not part of the contract across a restart, draining the oldest first
	// is still the least surprising thing to do with a backlog.
	for i in 1 ..< len(entries) {
		e := entries[i]
		j := i
		for j > 0 && entries[j - 1].enqueued_at_ms > e.enqueued_at_ms {
			entries[j] = entries[j - 1]
			j -= 1
		}
		entries[j] = e
	}

	// §4 count bound — drop the OLDEST beyond the cap, which are now at the front.
	if len(entries) > BRIDGE_SHELL_EXITED_OUTBOX_MAX_ENTRIES {
		excess := len(entries) - BRIDGE_SHELL_EXITED_OUTBOX_MAX_ENTRIES
		fmt.eprintln("bridge shell_exited outbox: over the", BRIDGE_SHELL_EXITED_OUTBOX_MAX_ENTRIES, "entry cap, dropping", excess, "oldest")
		for i in 0 ..< excess {
			bridge_shell_exited_outbox_remove(entries[i].path)
			bridge_shell_exited_outbox_entry_free(entries[i])
		}
		remove_range(&entries, 0, excess)
	}

	return entries[:]
}
