package events

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// Attention_Debouncer coalesces card writes into one attention_changed event
// per owner per window (attention deck v1). The event is an INVALIDATION HINT
// only -- {"type":"attention_changed","kinds":[...]} with no counts: the client
// refetches /attention/summary for its own selected range (and /attention while
// the deck is open). A burst of writes (a reconciliation sweep, a chain
// completing) therefore costs the client one refetch, not one per card.
//
// The first write for an owner arms a one-shot flush after `delay`; writes that
// land before it fires only add their kind to the pending set. Owners never
// share an entry, so one user's burst never delays or leaks to another's.

ATTENTION_EVENT_DELAY :: 500 * time.Millisecond

// Attention kinds the event can name, as a small bit set per owner.
ATTENTION_KIND_BITS :: [?]string{"message", "task", "approval", "memory"}

Attention_Publish_Proc :: proc(ctx: rawptr, owner_user_id: string, event_json: string)

Attention_Debouncer :: struct {
	bus:         ^User_Event_Bus,
	delay:       time.Duration,
	mutex:       sync.Mutex,
	pending:     map[string]u8, // owner -> kind bits; present = a flush is armed
	// publish defaults to publishing on bus; tests substitute a recorder.
	publish:     Attention_Publish_Proc,
	publish_ctx: rawptr,
}

init_attention_debouncer :: proc(d: ^Attention_Debouncer, bus: ^User_Event_Bus, delay := ATTENTION_EVENT_DELAY) {
	d.bus = bus
	d.delay = delay
	d.pending = make(map[string]u8, runtime.heap_allocator())
}

attention_kind_bit :: proc(kind: string) -> u8 {
	for k, i in ATTENTION_KIND_BITS do if k == kind do return u8(1) << u8(i)
	return 0
}

// attention_debouncer_note records that an owner's card of kind changed. Cheap
// and non-blocking: at most it starts the owner's one-shot flush thread.
attention_debouncer_note :: proc(d: ^Attention_Debouncer, owner_user_id: string, kind: string) {
	if d == nil || owner_user_id == "" do return
	bit := attention_kind_bit(kind)
	if bit == 0 do return
	sync.mutex_lock(&d.mutex)
	bits, armed := d.pending[owner_user_id]
	if armed {
		d.pending[owner_user_id] = bits | bit
		sync.mutex_unlock(&d.mutex)
		return
	}
	// Request threads run on a per-request arena that is reclaimed when the
	// request ends, so everything that outlives this call (the map key, the
	// flush thread's work) lives on the heap with a fresh default context.
	owner := strings.clone(owner_user_id, runtime.heap_allocator())
	d.pending[owner] = bit
	sync.mutex_unlock(&d.mutex)
	thread.run_with_poly_data2(d, owner, attention_debouncer_flush_after, init_context = runtime.default_context())
}

// attention_debouncer_flush_after runs on the owner's one-shot thread. owner is
// the clone made when the flush was armed (also the map key); it is freed here.
attention_debouncer_flush_after :: proc(d: ^Attention_Debouncer, owner: string) {
	time.sleep(d.delay)
	attention_debouncer_flush(d, owner)
	delete(owner, runtime.heap_allocator())
}

// attention_debouncer_flush publishes and clears one owner's pending kinds. It
// never frees owner, so tests may call it directly.
attention_debouncer_flush :: proc(d: ^Attention_Debouncer, owner: string) {
	sync.mutex_lock(&d.mutex)
	bits, armed := d.pending[owner]
	if armed do delete_key(&d.pending, owner)
	sync.mutex_unlock(&d.mutex)
	if !armed do return

	event := attention_changed_json(bits)
	if d.publish != nil {
		d.publish(d.publish_ctx, owner, event)
		delete(event)
	} else {
		publish_owned(d.bus, owner, event)
	}
}

attention_changed_json :: proc(bits: u8) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"type":"attention_changed","kinds":[`)
	n := 0
	for k, i in ATTENTION_KIND_BITS {
		if bits & (u8(1) << u8(i)) == 0 do continue
		if n > 0 do strings.write_byte(&b, ',')
		strings.write_byte(&b, '"')
		strings.write_string(&b, k)
		strings.write_byte(&b, '"')
		n += 1
	}
	strings.write_string(&b, `]}`)
	return strings.to_string(b)
}
