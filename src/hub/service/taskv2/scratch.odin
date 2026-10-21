package taskv2

import "base:runtime"
import "core:mem/virtual"

// Scratch is the allocation scope for a taskv2 entry point that can be called
// off the request path. Everything taskv2 allocates (lease/task/chain rows, a
// match context, effects, snapshot JSON) is scratch by design: it runs inside a
// per-request arena or the timer thread's per-tick temp arena and never frees.
// The hooks below are also called from threads that live on the persistent heap
// (the bridge WS reader, the reaper), where that design leaks every row it
// touches — a workflow chain's spec, inputs and every task brief per call.
// Heap-lived state (timers, recent_expiries, pending_touches, merge jobs)
// already clones onto runtime.heap_allocator explicitly.
//
// Only context.allocator is scoped, exactly as a request arena does: the temp
// allocator belongs to the caller, which may hand temp data to (or expect it
// back from) the hook, and every heap-thread caller resets its own temp (per
// frame on the WS reader, per pass in the reaper, per tick in the timer).
//
// Usage — assign at proc-body scope; Odin restores `context` at every block
// boundary, so an assignment inside a nested `if`/`do` silently reverts:
//
//	scratch: Scratch
//	context.allocator = scratch_begin(&scratch)
//	defer scratch_end(&scratch)
Scratch :: struct {
	arena: virtual.Arena,
	ok:    bool,
}

// scratch_begin returns the allocator to install. If the arena cannot be created
// it falls back to the caller's allocator: correct, just not reclaimed.
scratch_begin :: proc(s: ^Scratch) -> runtime.Allocator {
	s.ok = virtual.arena_init_growing(&s.arena) == nil
	if !s.ok do return context.allocator
	return virtual.arena_allocator(&s.arena)
}

scratch_end :: proc(s: ^Scratch) {
	if s.ok do virtual.arena_destroy(&s.arena)
	s.ok = false
}
