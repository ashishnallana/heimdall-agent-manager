package taskv2

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import dbt "odin_test:hub/platform/dbtelemetry"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import project "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"
import contracts "odin_test:contracts"

// Per-task worktree merge-back. A task placed in a git directory works on
// branch `heimdall/<task_id>` in `<dir>/.heimdall/worktrees/<task_id>`
// (task_worktree, lease.odin). When the task reaches Done the hub asks the
// directory's bridge to merge that branch into the directory's checked-out
// branch and drop the worktree (`taskv2_merge_worktree`). The outcome lands on
// the task timeline:
//   merged          — audit only; the branch is in.
//   merge_conflict  — fold: Done → blocked on a human (the bridge aborted the
//                     merge and kept the worktree for the next attempt).
//   merge_failed    — audit only; the merge never ran (bridge offline, …).

MERGE_COMMAND_TYPE :: "taskv2_merge_worktree"
MERGE_TIMEOUT_MS :: 60_000

Merge_Effect :: struct {
	owner:     string,
	task_id:   string,
	bridge_id: string,
	repo:      string,
	workdir:   string,
	branch:    string,
}

// effect_merge_worktree queues the merge-back for a task that just became done.
// No-op unless its work ran on a bridge whose chain directory gets worktrees.
effect_merge_worktree :: proc(svc: ^Service, u: ^Uow, task: domain.Task, evs: []domain.Task_Event, only_bridge := "") {
	if u == nil || !PER_LEASE_WORKTREES_ENABLED do return
	if merge_queued(u, task.task_id) do return
	if !workflow_merge_allowed(svc, task) do return
	bridge_id := ""
	for i := len(evs) - 1; i >= 0; i -= 1 {
		ev := evs[i]
		if ev.kind != EV_LEASE_GRANTED do continue
		if jsonx.extract_string(ev.payload_json, "kind", domain.LEASE_KIND_WORK, true, context.temp_allocator) != domain.LEASE_KIND_WORK do continue
		bridge_id = jsonx.extract_string(ev.payload_json, "bridge_id", "", true, context.temp_allocator)
		break
	}
	if bridge_id == "" || (only_bridge != "" && bridge_id != only_bridge) do return
	dirs, derr := iface.taskchain_list_directories_by_chain(svc.repo, task.chain_id, task.owner_user_id)
	if derr.code != .None do return
	for d in dirs {
		if d.bridge_id != bridge_id do continue
		workdir, branch := task_worktree(d, task.task_id)
		if workdir == "" do return
		append(&u.effects.merges, Merge_Effect{
			owner     = strings.clone(string(task.owner_user_id)),
			task_id   = strings.clone(string(task.task_id)),
			bridge_id = strings.clone(bridge_id),
			repo      = strings.clone(strings.trim_right(strings.trim_space(d.path), "/")),
			workdir   = strings.clone(workdir),
			branch    = strings.clone(branch),
		})
		return
	}
}

destroy_merge_effect :: proc(m: Merge_Effect) {
	delete(m.owner)
	delete(m.task_id)
	delete(m.bridge_id)
	delete(m.repo)
	delete(m.workdir)
	delete(m.branch)
}

Merge_Job :: struct {
	svc:   ^Service,
	merge: Merge_Effect,
}

// flush_merges runs each merge on its own thread: the bridge round trip can
// take seconds and flush_effects may run on a bridge frame handler, which must
// not wait on its own bridge.
flush_merges :: proc(svc: ^Service, e: ^Effects) {
	if len(e.merges) == 0 do return
	// The job, its strings and the Thread itself outlive the caller, which on
	// the request path allocates from a per-request arena: build them on the
	// persistent heap (same trap as push.send_to_user_async).
	context.allocator = runtime.heap_allocator()
	for m in e.merges {
		if svc.bridge_command_sink.send_runtime_command_wait == nil do continue
		// One job per task at a time: a duplicate (bridge hello, directory add
		// or re-check while the first is still waiting) would resend the same
		// command_id and could record a stale failure after the merge.
		if !merge_inflight_begin(svc, m.task_id) do continue
		job := new(Merge_Job)
		job.svc = svc
		job.merge = Merge_Effect{
			owner     = strings.clone(m.owner),
			task_id   = strings.clone(m.task_id),
			bridge_id = strings.clone(m.bridge_id),
			repo      = strings.clone(m.repo),
			workdir   = strings.clone(m.workdir),
			branch    = strings.clone(m.branch),
		}
		_ = thread.create_and_start_with_data(rawptr(job), merge_job_run, self_cleanup = true)
	}
}

@(private = "file")
merge_job_run :: proc(data: rawptr) {
	job := (^Merge_Job)(data)
	dbt.scope_begin(.Merge)
	defer dbt.scope_end_background()
	defer {
		merge_inflight_end(job.svc, job.merge.task_id)
		destroy_merge_effect(job.merge)
		free(job)
		free_all(context.temp_allocator)
	}
	run_merge_scoped(job.svc, job.merge)
}

// merge_inflight_begin marks `task_id`'s merge-back as running; false when a
// job for it already is. In-memory on purpose: a restart drops the jobs too.
merge_inflight_begin :: proc(svc: ^Service, task_id: string) -> bool {
	sync.mutex_lock(&svc.state_mutex)
	defer sync.mutex_unlock(&svc.state_mutex)
	if svc.merges_inflight == nil do svc.merges_inflight = make(map[string]struct{}, runtime.heap_allocator())
	if task_id in svc.merges_inflight do return false
	svc.merges_inflight[strings.clone(task_id, runtime.heap_allocator())] = {}
	return true
}

merge_inflight_end :: proc(svc: ^Service, task_id: string) {
	sync.mutex_lock(&svc.state_mutex)
	defer sync.mutex_unlock(&svc.state_mutex)
	if task_id not_in svc.merges_inflight do return
	key, _ := delete_key(&svc.merges_inflight, task_id)
	delete(key, runtime.heap_allocator())
}

merge_inflight :: proc(svc: ^Service, task_id: string) -> bool {
	sync.mutex_lock(&svc.state_mutex)
	defer sync.mutex_unlock(&svc.state_mutex)
	return task_id in svc.merges_inflight
}

// merge_queued: this unit of work already holds a merge-back for the task.
merge_queued :: proc(u: ^Uow, task_id: domain.Task_ID) -> bool {
	for m in u.effects.merges do if m.task_id == string(task_id) do return true
	return false
}

// run_merge_scoped runs the merge on a scratch arena: this thread is on the
// persistent heap and run_merge, like the rest of taskv2, never frees. The job
// itself is heap-owned and freed by merge_job_run, outside this scope.
@(private = "file")
run_merge_scoped :: proc(svc: ^Service, m: Merge_Effect) {
	scratch: Scratch
	context.allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	run_merge(svc, m)
}

// merge_command_json renders the bridge command. Pure; temp-allocated.
merge_command_json :: proc(command_id: string, m: Merge_Effect) -> string {
	o := json_begin()
	json_str(&o, "type", MERGE_COMMAND_TYPE)
	json_str(&o, "command_id", command_id)
	json_str(&o, "task_id", m.task_id)
	json_str(&o, "repo", m.repo)
	json_str(&o, "workdir", m.workdir)
	json_str(&o, "branch", m.branch)
	return json_end(&o)
}

Merge_Outcome :: enum {
	Merged,
	Conflict,
	Failed,
}

// parse_merge_reply classifies the bridge's `taskv2_merge_worktree_result`.
// Pure. Anything that is not an explicit success or conflict is a failure.
parse_merge_reply :: proc(reply: string) -> (outcome: Merge_Outcome, detail: string) {
	detail = jsonx.extract_string(reply, "detail", "", true, context.temp_allocator)
	if c, ok := jsonx.extract_bool_literal(reply, "conflict", true); ok && c do return .Conflict, detail
	if ok_v, ok := jsonx.extract_bool_literal(reply, "ok", true); ok && ok_v do return .Merged, detail
	if detail == "" do detail = "bridge reported a merge failure"
	return .Failed, detail
}

@(private = "file")
run_merge :: proc(svc: ^Service, m: Merge_Effect) {
    initial, found, _ := iface.taskchain_get_task(svc.repo, domain.Task_ID(m.task_id))
    if !found || !workflow_merge_allowed(svc, initial) do return
	command_id := fmt.tprintf("cmd_merge_%s_%d", initial.task_id, initial.attempt_no)
	reply, ok, err := project.bridge_command_send_runtime_wait(svc.bridge_command_sink, project.Runtime_Command{
		bridge_id  = m.bridge_id,
		command_id = command_id,
		body_json  = merge_command_json(command_id, m),
	}, MERGE_TIMEOUT_MS)
	defer if ok do delete(reply)

	outcome := Merge_Outcome.Failed
	detail := err.message
	if ok do outcome, detail = parse_merge_reply(reply)

	task, tok, _ := iface.taskchain_get_task(svc.repo, domain.Task_ID(m.task_id))
	if !tok do return
    if !workflow_merge_allowed(svc, task) do return
	p := json_begin()
	json_str(&p, "branch", m.branch)
	json_str(&p, "workdir", m.workdir)
	if detail != "" do json_str(&p, "detail", detail)
	kind := EV_MERGE_FAILED
	switch outcome {
	case .Merged:
		kind = EV_MERGED
		json_str(&p, "into", m.repo)
		json_str(&p, "head", jsonx.extract_string(reply, "head", "", true, context.temp_allocator))
		json_str(&p, "mode", jsonx.extract_string(reply, "mode", "", true, context.temp_allocator))
	case .Conflict:
		kind = EV_MERGE_CONFLICT
		files := jsonx.extract_string_array(reply, "files", true, context.temp_allocator)
		if len(files) > 0 do json_str(&p, "files", strings.join(files[:], ", ", context.temp_allocator))
	case .Failed:
	}

	u, uok, _ := begin_uow(svc)
	if !uok do return
	saved, _, rok, _ := record_event(svc, &u, task, hub_actor(), kind, json_end(&p))
	if rok && outcome != .Merged {
		line := fmt.tprintf("[taskv2] merge %s: task %s (%s) branch %s did not merge into %s: %s",
			"conflict" if outcome == .Conflict else "failed", saved.task_id, saved.title, m.branch, m.repo, first_line_trimmed(detail))
		effect_notify_coordinator(svc, &u, saved.chain_id, saved.owner_user_id, "merge_conflict" if outcome == .Conflict else "merge_failed", line)
	}
	if rok {
		rok, _ = after_chain_change(svc, &u, saved.chain_id, saved.owner_user_id, .Task_Updated)
	}
	_, _ = end_uow(svc, &u, rok)
}

// merge_pending: the task's latest completion has no merge outcome yet (the
// hub stopped between Done and the bridge's reply, or the bridge was away).
merge_pending :: proc(evs: []domain.Task_Event) -> bool {
	for i := len(evs) - 1; i >= 0; i -= 1 {
		switch evs[i].kind {
		case EV_MERGED, EV_MERGE_CONFLICT: return false
		case EV_APPROVED, EV_SUBMITTED: return true
		}
	}
	return false
}

// requeue_pending_merges re-sends the merge-back of every done task whose work
// ran on `bridge_id` and never got a merge outcome. Called on bridge hello;
// the bridge side is idempotent (an already-merged branch is gone → no-op).
// Scans done tasks of every chain: the chain of a task that just finished is
// usually already `completed`, so active chains alone would miss it.
requeue_pending_merges :: proc(svc: ^Service, u: ^Uow, bridge_id: string) {
	if !PER_LEASE_WORKTREES_ENABLED do return
	tasks, terr := iface.taskchain_list_tasks_by_state(svc.repo, .Done)
	if terr.code != .None do return
	for t in tasks {
		evs, eerr := iface.taskchain_list_events_by_task(svc.repo, t.task_id, t.owner_user_id)
		if eerr.code != .None || !merge_pending(evs) do continue
		// Done before any git directory existed → merge none for good.
		if task_merge_status(svc, t).state == "none" do continue
		effect_merge_worktree(svc, u, t, evs, bridge_id)
	}
}

// directory_added (REQ-TV2-3b): a chain directory was attached. Requeue the
// chain's pending merges on that directory's bridge (as on bridge hello) and
// refold the chain, so readiness that depends on merge state is recomputed.
// Tasks that reached Done before the directory existed stay merge none.
directory_added :: proc(svc: ^Service, dir: domain.Task_Chain_Directory) -> (bool, domain.Domain_Error) {
	if svc == nil || svc.uow_factory == nil do return true, domain.Domain_Error{}
	u, uok, uerr := begin_uow(svc)
	if !uok do return false, uerr
	ok, err := directory_added_in_uow(svc, &u, dir)
	_, cerr := end_uow(svc, &u, ok)
	if !ok do return false, err
	if cerr.code != .None do return false, cerr
	return true, domain.Domain_Error{}
}

directory_added_in_uow :: proc(svc: ^Service, u: ^Uow, dir: domain.Task_Chain_Directory) -> (bool, domain.Domain_Error) {
	chain, cok, cerr := iface.taskchain_get_chain(svc.repo, dir.chain_id)
	if !cok do return false, cerr
	if PER_LEASE_WORKTREES_ENABLED && dir.bridge_id != "" {
		tasks, terr := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
		if terr.code != .None do return false, terr
		for t in tasks {
			if t.state != .Done do continue
			evs, eerr := iface.taskchain_list_events_by_task(svc.repo, t.task_id, t.owner_user_id)
			if eerr.code != .None || !merge_pending(evs) do continue
			if task_merge_status(svc, t).state == "none" do continue
			effect_merge_worktree(svc, u, t, evs, dir.bridge_id)
		}
	}
	if chain.status != .Active || chain.publish_state != .Published do return true, domain.Domain_Error{}
	return after_chain_change(svc, u, chain.chain_id, chain.owner_user_id, .Task_Updated)
}

// ---- F5: merge status for the task projection --------------------------------------

Merge_Status :: struct {
	state:  string, // none | pending | merged | conflict | failed
	detail: string,
	head:   string,
}

// task_merge_status derives where a task's branch is: only done tasks (and a
// task blocked on a merge conflict) in a chain with a git directory carry one.
task_merge_status :: proc(svc: ^Service, task: domain.Task) -> Merge_Status {
	st := Merge_Status{state = "none"}
	if svc == nil || svc.repo == nil || !PER_LEASE_WORKTREES_ENABLED do return st
	if task.state != .Done && !strings.contains(task.blocked_on_json, `"merge_conflict"`) do return st
	evs, eerr := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
	if eerr.code != .None do return st
	// The newest merge_snapshot after the Done-making event is the
	// immutable record of whether a git directory applied at Done.
	snapshot_seen, snapshot_applicable := false, false
	for i := len(evs) - 1; i >= 0; i -= 1 {
		ev := evs[i]
		switch ev.kind {
		case EV_MERGE_SNAPSHOT:
			if !snapshot_seen {
				snapshot_seen = true
				snapshot_applicable = jsonx.extract_bool(ev.payload_json, "applicable", false, true)
			}
		case EV_MERGED:
			st.state = "merged"
			st.head = jsonx.extract_string(ev.payload_json, "head", "", true, context.temp_allocator)
			st.detail = jsonx.extract_string(ev.payload_json, "mode", "", true, context.temp_allocator)
			return st
		case EV_MERGE_CONFLICT:
			st.state = "conflict"
			st.detail = jsonx.extract_string(ev.payload_json, "files", "", true, context.temp_allocator)
			return st
		case EV_MERGE_FAILED:
			st.state = "failed"
			st.detail = jsonx.extract_string(ev.payload_json, "detail", "", true, context.temp_allocator)
			return st
		case EV_APPROVED, EV_SUBMITTED:
			// Done with no outcome yet: pending only where a worktree applies —
			// work ran (a gate never has a work lease) in a git directory.
			if !task_ran_work(evs) do return st
			applicable := snapshot_applicable
			if !snapshot_seen {
				// Legacy Done (before snapshots existed, not yet backfilled at
				// boot): derive from the current directory rows. An unreadable
				// directory list fails closed (pending), never open (none).
				dirs, derr := git_directories_at(svc, task, ev.ts_ms)
				applicable = derr.code != .None || len(dirs) > 0
			}
			if applicable do st.state = "pending"
			return st
		}
	}
	return st
}

task_ran_work :: proc(evs: []domain.Task_Event) -> bool {
	for e in evs do if e.kind == EV_LEASE_GRANTED && jsonx.extract_string(e.payload_json, "kind", domain.LEASE_KIND_WORK, true, context.temp_allocator) == domain.LEASE_KIND_WORK do return true
	return false
}

// git_directories_at lists the chain's git directories; with before_ms > 0
// only those created at or before it (the legacy derivation). A failed read is
// returned, never reported as "no git directory".
git_directories_at :: proc(svc: ^Service, task: domain.Task, before_ms: i64 = 0) -> ([dynamic]string, domain.Domain_Error) {
	out := make([dynamic]string, context.temp_allocator)
	dirs, derr := iface.taskchain_list_directories_by_chain(svc.repo, task.chain_id, task.owner_user_id)
	if derr.code != .None do return out, derr
	for d in dirs {
		if d.vcs_kind != "git" do continue
		if before_ms > 0 {
			if created_ms, cok := platform.rfc3339_to_unix_ms(d.created_at); cok && created_ms > before_ms do continue
		}
		append(&out, string(d.directory_id))
	}
	return out, domain.Domain_Error{}
}

// record_merge_snapshot (REQ-TV2-3b) appends the immutable Done-time record of
// the chain's git directories. Later directory updates, removals or re-adds
// never change it: a task Done with no git directory stays merge none, and a
// task Done with one stays pending until a merge outcome even if the directory
// goes away. Recorded on every transition into Done (so a reopen re-snapshots).
// Fails closed: a directory-read or event-write error is returned so the
// caller's UoW rolls back and Done never commits without its snapshot.
record_merge_snapshot :: proc(svc: ^Service, task: domain.Task) -> domain.Domain_Error {
	if svc == nil || svc.repo == nil || !PER_LEASE_WORKTREES_ENABLED do return domain.Domain_Error{}
	dirs, derr := git_directories_at(svc, task)
	if derr.code != .None do return derr
	return append_merge_snapshot(svc, task, dirs[:], false)
}

append_merge_snapshot :: proc(svc: ^Service, task: domain.Task, dirs: []string, backfilled: bool) -> domain.Domain_Error {
	ids := strings.builder_make(context.temp_allocator)
	strings.write_byte(&ids, '[')
	for id, i in dirs {
		if i > 0 do strings.write_byte(&ids, ',')
		strings.write_byte(&ids, '"')
		contracts.write_json_string(&ids, id)
		strings.write_byte(&ids, '"')
	}
	strings.write_byte(&ids, ']')
	p := json_begin()
	json_bool(&p, "applicable", len(dirs) > 0)
	json_raw(&p, "git_directories", strings.to_string(ids))
	if backfilled do json_bool(&p, "backfilled", true)
	_, ok, err := append_event(svc.repo, svc.clock, task, hub_actor(), EV_MERGE_SNAPSHOT, json_end(&p))
	if !ok {
		if err.code == .None do err = domain.domain_error(.Internal_Error, "merge snapshot was not recorded")
		return err
	}
	return domain.Domain_Error{}
}

// backfill_merge_snapshot (boot): a legacy Done task with a pending merge and
// no snapshot gets one from the legacy derivation, so from then on its merge
// applicability no longer follows mutable directory rows. On a failed read or
// write nothing is recorded and the error is returned; the task keeps the
// fail-closed legacy derivation and the next boot retries.
backfill_merge_snapshot :: proc(svc: ^Service, task: domain.Task, evs: []domain.Task_Event) -> domain.Domain_Error {
	if !PER_LEASE_WORKTREES_ENABLED do return domain.Domain_Error{}
	for i := len(evs) - 1; i >= 0; i -= 1 {
		switch evs[i].kind {
		case EV_MERGE_SNAPSHOT, EV_MERGED, EV_MERGE_CONFLICT, EV_MERGE_FAILED: return domain.Domain_Error{}
		case EV_APPROVED, EV_SUBMITTED:
			if !task_ran_work(evs) do return domain.Domain_Error{}
			dirs, derr := git_directories_at(svc, task, evs[i].ts_ms)
			if derr.code != .None do return derr
			return append_merge_snapshot(svc, task, dirs[:], true)
		}
	}
	return domain.Domain_Error{}
}

// Generation changes are refused while merges are pending, so a job authorized
// here cannot cross a cancel/retry while the bridge is touching the repository.
// Failed executions may settle existing Done tasks before explicit retry.
workflow_merge_allowed :: proc(svc: ^Service, task: domain.Task) -> bool {
 if task.workflow_run_id == "" do return true
 wf, ok, _ := workflow_context(svc, task.workflow_run_id, task.owner_user_id)
 return ok && wf.run.current_execution_no == task.workflow_execution_no && wf.execution.state != "cancelled"
}
