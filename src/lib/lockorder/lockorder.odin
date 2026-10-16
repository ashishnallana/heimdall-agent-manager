package lockorder

import "core:fmt"
import "core:sync"

// Lock order between the two hot locks of the hub (Task System v2 review B1):
//
//   sqlite.tx_mutex  →  Bridge_Runtime_Connection.state_mutex
//
// is the ONLY allowed order. A unit of work (tx_mutex) may reserve runtime
// capacity (state_mutex) — the matcher's JIT path does — but code holding a
// connection's state_mutex must NEVER open a unit of work: it must return the
// facts it learned and let the caller act after the unlock. Every state_mutex
// acquisition goes through state_mutex_enter/leave so the tx side can check.
//
// In debug builds a violation panics at the offending begin; release builds
// count it (violations) and log once so a slipped path is visible without
// turning a would-be deadlock into a crash.

@(thread_local) state_mutex_depth: int
violations: int
@(private = "file") logged: bool

state_mutex_enter :: proc() { state_mutex_depth += 1 }
state_mutex_leave :: proc() { state_mutex_depth -= 1 }
state_mutex_held :: proc() -> bool { return state_mutex_depth > 0 }

// assert_tx_mutex_allowed is called by sqlite.begin before taking tx_mutex.
assert_tx_mutex_allowed :: proc(loc := #caller_location) {
	if state_mutex_depth <= 0 do return
	when ODIN_DEBUG {
		panic("lock-order violation: unit of work begun while a bridge connection state_mutex is held (allowed order is tx_mutex → state_mutex)", loc)
	} else {
		sync.atomic_add(&violations, 1)
		if !logged {
			logged = true
			fmt.eprintfln("ham-hub LOCK-ORDER VIOLATION at %v: unit of work begun under a connection state_mutex (allowed order tx_mutex → state_mutex)", loc)
		}
	}
}
