package events

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

Attention_Recorder :: struct {
	mutex:  sync.Mutex,
	owners: [dynamic]string,
	events: [dynamic]string,
}

attention_record :: proc(ctx: rawptr, owner, event_json: string) {
	r := (^Attention_Recorder)(ctx)
	sync.mutex_lock(&r.mutex)
	defer sync.mutex_unlock(&r.mutex)
	// Runs on the flush thread (default heap context): keep allocations on the
	// heap allocator explicitly so the test frees them with the same one.
	append(&r.owners, strings.clone(owner, runtime.heap_allocator()))
	append(&r.events, strings.clone(event_json, runtime.heap_allocator()))
}

@(test)
test_attention_debouncer_coalesces_per_owner :: proc(t: ^testing.T) {
	rec: Attention_Recorder
	defer {
		for s in rec.owners do delete(s, runtime.heap_allocator())
		for s in rec.events do delete(s, runtime.heap_allocator())
		delete(rec.owners); delete(rec.events)
	}
	d: Attention_Debouncer
	init_attention_debouncer(&d, nil, 80 * time.Millisecond)
	defer delete(d.pending)
	d.publish = attention_record
	d.publish_ctx = &rec

	// A burst for alice (three writes, two kinds) and one write for bob.
	attention_debouncer_note(&d, "alice", "task")
	attention_debouncer_note(&d, "alice", "task")
	attention_debouncer_note(&d, "alice", "message")
	attention_debouncer_note(&d, "bob", "message")
	// Unknown kinds and empty owners are ignored.
	attention_debouncer_note(&d, "alice", "nonsense")
	attention_debouncer_note(&d, "", "task")

	time.sleep(400 * time.Millisecond)
	sync.mutex_lock(&rec.mutex)
	defer sync.mutex_unlock(&rec.mutex)
	testing.expect_value(t, len(rec.events), 2) // exactly one event per owner
	for owner, i in rec.owners {
		switch owner {
		case "alice": testing.expect_value(t, rec.events[i], `{"type":"attention_changed","kinds":["message","task"]}`)
		case "bob":   testing.expect_value(t, rec.events[i], `{"type":"attention_changed","kinds":["message"]}`)
		case:         testing.fail_now(t, "event for an owner that never wrote")
		}
	}
	testing.expect_value(t, len(d.pending), 0)
}

@(test)
test_attention_debouncer_rearms_after_flush :: proc(t: ^testing.T) {
	rec: Attention_Recorder
	defer {
		for s in rec.owners do delete(s, runtime.heap_allocator())
		for s in rec.events do delete(s, runtime.heap_allocator())
		delete(rec.owners); delete(rec.events)
	}
	d: Attention_Debouncer
	init_attention_debouncer(&d, nil, 50 * time.Millisecond)
	defer delete(d.pending)
	d.publish = attention_record
	d.publish_ctx = &rec

	attention_debouncer_note(&d, "carol", "task")
	time.sleep(250 * time.Millisecond)
	attention_debouncer_note(&d, "carol", "task")
	time.sleep(250 * time.Millisecond)
	sync.mutex_lock(&rec.mutex)
	defer sync.mutex_unlock(&rec.mutex)
	testing.expect_value(t, len(rec.events), 2) // separate windows, separate hints
}

// Regression (crashed a live hub): a note made from a request thread whose
// allocator is a per-request arena that is wiped before the flush fires. The
// debouncer must not keep anything in that arena -- neither the owner key nor
// the flush thread's own record.
@(test)
test_attention_debouncer_survives_reclaimed_request_arena :: proc(t: ^testing.T) {
	rec: Attention_Recorder
	defer {
		for s in rec.owners do delete(s, runtime.heap_allocator())
		for s in rec.events do delete(s, runtime.heap_allocator())
		delete(rec.owners); delete(rec.events)
	}
	d: Attention_Debouncer
	init_attention_debouncer(&d, nil, 100 * time.Millisecond)
	defer delete(d.pending)
	d.publish = attention_record
	d.publish_ctx = &rec

	request :: proc(d: ^Attention_Debouncer) {
		buf := make([]byte, 64 * 1024, runtime.heap_allocator())
		defer delete(buf, runtime.heap_allocator())
		arena: mem.Arena
		mem.arena_init(&arena, buf)
		context.allocator = mem.arena_allocator(&arena)
		attention_debouncer_note(d, strings.clone("dave"), "task")
		// The request ends: its arena is scribbled over and released.
		for i in 0 ..< len(buf) do buf[i] = 0xAA
	}
	worker := thread.create_and_start_with_poly_data(&d, request)
	thread.join(worker)
	thread.destroy(worker)

	time.sleep(400 * time.Millisecond)
	sync.mutex_lock(&rec.mutex)
	defer sync.mutex_unlock(&rec.mutex)
	testing.expect_value(t, len(rec.events), 1)
	if len(rec.owners) == 1 do testing.expect_value(t, rec.owners[0], "dave")
}
