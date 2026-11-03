package taskv2

import "core:log"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// ---- per-call chain fold cache (F1) ----------------------------------------------
//
// after_chain_change refolds the whole chain several times inside its write
// transaction (requirements reconcile, the settle loop's refold passes, the
// final pass). Reading each task's events per refold made that 4N+ statements
// per write. While a Chain_Fold_Cache is active on this thread:
//
//   - the chain's fold events (every kind but `comment`) are read in ONE
//     batched query and served from memory; append_event keeps them current,
//     so a refold always sees exactly what list_events_by_task would;
//   - refold_chain loads the active work-dependency edges once per pass;
//   - refold_chain skips a task whose fold inputs (its events, Fold_Input and
//     stored projection) are unchanged since it was last folded in this call:
//     folding the same inputs gives the same view, and the projection already
//     matches it, so the refold would be a no-op. Only the dirty set (tasks
//     with new events, or whose deps_done / row changed) is refolded.
//
// The cache is thread-local and bound to one chain: any other chain, any other
// thread and any call outside after_chain_change read the repository as before.

Chain_Fold_Cache :: struct {
	chain_id:     domain.Task_Chain_ID,
	owner:        domain.User_ID,
	loaded:       bool,
	events:       map[domain.Task_ID][dynamic]domain.Task_Event,
	// settled: the inputs each task was last folded with in this call, when
	// the resulting projection was persisted (or already stored).
	settled:      map[domain.Task_ID]Fold_Key,
	// Loaded once per refold_chain pass: refolds change neither. A chain
	// without depends_on edges has a nil `deps`, hence the flag.
	deps:         []domain.Task_Dependency,
	edges:        []domain.Work_Dependency,
	edges_loaded: bool,
}

// Fold_Key is everything refold_task's outcome depends on, besides the clock
// (apply_view_to_task is idempotent on an already-applied projection).
Fold_Key :: struct {
	event_count:     int,
	last_event_id:   i64,
	input:           Fold_Input,
	state:           domain.Task_State,
	attempt_no:      int,
	blocked_on_json: string,
	ready_since:     string,
	started_at:      string,
	completed_at:    string,
}

@(thread_local)
tl_fold_cache: ^Chain_Fold_Cache

// fold_cache_begin activates `c` for `chain_id` on this thread. A nested call
// for the same chain reuses the outer cache (returns nil: nothing to end).
fold_cache_begin :: proc(c: ^Chain_Fold_Cache, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> (active: ^Chain_Fold_Cache, prev: ^Chain_Fold_Cache) {
	if tl_fold_cache != nil && tl_fold_cache.chain_id == chain_id && tl_fold_cache.owner == owner do return nil, nil
	c^ = Chain_Fold_Cache{chain_id = chain_id, owner = owner}
	prev = tl_fold_cache
	tl_fold_cache = c
	return c, prev
}

fold_cache_end :: proc(c: ^Chain_Fold_Cache, prev: ^Chain_Fold_Cache) {
	if c == nil do return
	tl_fold_cache = prev
	fold_cache_drop_events(c)
	delete(c.settled)
	c.settled = nil
}

@(private = "file")
fold_cache_drop_events :: proc(c: ^Chain_Fold_Cache) {
	for _, &list in c.events do delete(list)
	delete(c.events)
	c.events = nil
	c.loaded = false
}

// fold_cache_invalidate drops the cached events (a nested unit of work rolled
// back: events it appended are gone). Events are re-read and every task is
// refolded on next use.
fold_cache_invalidate :: proc() {
	if c := tl_fold_cache; c != nil {
		fold_cache_drop_events(c)
		delete(c.settled)
		c.settled = nil
	}
}

@(private = "file")
fold_cache_for :: proc(task: domain.Task) -> ^Chain_Fold_Cache {
	c := tl_fold_cache
	if c == nil || c.chain_id != task.chain_id || c.owner != task.owner_user_id do return nil
	return c
}

@(private = "file")
fold_cache_load :: proc(svc: ^Service, c: ^Chain_Fold_Cache) -> domain.Domain_Error {
	if c.loaded do return {}
	evs, err := iface.taskchain_list_fold_events_by_chain(svc.repo, c.chain_id, c.owner)
	if err.code != .None do return err
	c.events = make(map[domain.Task_ID][dynamic]domain.Task_Event)
	for ev in evs {
		list, found := &c.events[ev.task_id]
		if !found {
			c.events[ev.task_id] = make([dynamic]domain.Task_Event)
			list = &c.events[ev.task_id]
		}
		append(list, ev)
	}
	delete(evs)
	c.loaded = true
	return {}
}

// fold_cache_note_appended records an event append_event just stored, so the
// cache stays identical to the table. Comments are not fold events.
fold_cache_note_appended :: proc(ev: domain.Task_Event) {
	if ev.kind == EV_COMMENT do return
	c := tl_fold_cache
	if c == nil || !c.loaded || c.chain_id != ev.chain_id || c.owner != ev.owner_user_id do return
	saved := ev
	saved.payload_json = strings.clone(ev.payload_json)
	list, found := &c.events[ev.task_id]
	if !found {
		c.events[ev.task_id] = make([dynamic]domain.Task_Event)
		list = &c.events[ev.task_id]
	}
	append(list, saved)
}

// task_fold_events returns `task`'s fold events (ascending, no comments):
// from the active chain cache when there is one, else from the repository.
task_fold_events :: proc(svc: ^Service, task: domain.Task) -> ([]domain.Task_Event, domain.Domain_Error) {
	if c := fold_cache_for(task); c != nil {
		if err := fold_cache_load(svc, c); err.code != .None do return nil, err
		return c.events[task.task_id][:], {}
	}
	evs, err := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	if err.code != .None do return nil, err
	return without_comments(evs), {}
}

// without_comments filters comment events out in place (they are audit only).
without_comments :: proc(evs: []domain.Task_Event) -> []domain.Task_Event {
	n := 0
	for ev in evs {
		if ev.kind == EV_COMMENT do continue
		evs[n] = ev
		n += 1
	}
	return evs[:n]
}

fold_key_for :: proc(task: domain.Task, evs: []domain.Task_Event, input: Fold_Input) -> Fold_Key {
	return Fold_Key{
		event_count = len(evs),
		last_event_id = evs[len(evs) - 1].event_id if len(evs) > 0 else 0,
		input = input,
		state = task.state,
		attempt_no = task.attempt_no,
		blocked_on_json = task.blocked_on_json,
		ready_since = task.ready_since,
		started_at = task.started_at,
		completed_at = task.completed_at,
	}
}

// fold_cache_settled: whether `task` was already folded with exactly `key` in
// this call (so refolding it would change nothing).
fold_cache_settled :: proc(task: domain.Task, key: Fold_Key) -> bool {
	c := fold_cache_for(task)
	if c == nil do return false
	prev, ok := c.settled[task.task_id]
	return ok && prev == key
}

fold_cache_settle :: proc(task: domain.Task, key: Fold_Key) {
	c := fold_cache_for(task)
	if c == nil do return
	if c.settled == nil do c.settled = make(map[domain.Task_ID]Fold_Key)
	c.settled[task.task_id] = key
}

// fold_cache_deps returns the chain's depends_on edges loaded for the current
// refold pass (ok=false: none loaded, read the repo).
fold_cache_deps :: proc(chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Dependency, bool) {
	c := tl_fold_cache
	if c == nil || !c.edges_loaded || c.chain_id != chain_id || c.owner != owner do return nil, false
	return c.deps, true
}

// fold_cache_work_edges returns the chain's work-dependency edges loaded for
// the current refold pass, or ok=false when none are loaded (read the repo).
fold_cache_work_edges :: proc(chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Work_Dependency, bool) {
	c := tl_fold_cache
	if c == nil || !c.edges_loaded || c.chain_id != chain_id || c.owner != owner do return nil, false
	return c.edges, true
}

// TASKV2_FOLD_VERIFY (tests only): at the end of every after_chain_change,
// check that a FULL refold — every task, events read per task from the
// repository, no cache — would change nothing. Running the taskv2 suite with
// it on proves the dirty-set refold leaves the same projection as the full one.
FOLD_VERIFY :: #config(TASKV2_FOLD_VERIFY, false)

fold_verify_full_refold_is_noop :: proc(svc: ^Service, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) {
	saved := tl_fold_cache
	tl_fold_cache = nil
	defer tl_fold_cache = saved
	tasks, err := iface.taskchain_list_tasks_by_chain(svc.repo, chain_id, owner)
	if err.code != .None do return
	deps, derr := iface.taskchain_list_dependencies_by_chain(svc.repo, chain_id, owner)
	if derr.code != .None do return
	for task in tasks {
		evs, eerr := task_fold_events(svc, task)
		if eerr.code != .None do continue
		ready, rerr := task_dependencies_ready(svc, task, tasks, deps)
		if rerr.code != .None do continue
		view := fold_task(evs, fold_input_for_task(task, ready))
		next := apply_view_to_task(task, view, task.updated_at)
		if next.state != task.state || next.attempt_no != task.attempt_no || next.blocked_on_json != task.blocked_on_json || (next.ready_since == "") != (task.ready_since == "") || (next.completed_at == "") != (task.completed_at == "") {
			// Error-level logs fail the running test (core:testing's logger).
			log.errorf("fold verify: dirty-set refold diverged from a full refold for task %s: stored %v/%d/%q, full %v/%d/%q", task.task_id, task.state, task.attempt_no, task.blocked_on_json, next.state, next.attempt_no, next.blocked_on_json)
		}
	}
}
