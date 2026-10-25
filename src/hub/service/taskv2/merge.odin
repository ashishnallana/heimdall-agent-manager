package taskv2

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:thread"
import dbt "odin_test:hub/platform/dbtelemetry"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import project "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"

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
		destroy_merge_effect(job.merge)
		free(job)
		free_all(context.temp_allocator)
	}
	run_merge_scoped(job.svc, job.merge)
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
		effect_merge_worktree(svc, u, t, evs, bridge_id)
	}
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
	for i := len(evs) - 1; i >= 0; i -= 1 {
		ev := evs[i]
		switch ev.kind {
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
			ran := false
			for e in evs do if e.kind == EV_LEASE_GRANTED && jsonx.extract_string(e.payload_json, "kind", domain.LEASE_KIND_WORK, true, context.temp_allocator) == domain.LEASE_KIND_WORK { ran = true; break }
			if !ran do return st
			dirs, derr := iface.taskchain_list_directories_by_chain(svc.repo, task.chain_id, task.owner_user_id)
			if derr.code != .None do return st
			// Snapshot at Done (REQ-TV2-3b): only a git directory that already
			// existed when the task reached Done makes it pending. A directory
			// added later never retro-actively owes a merge, so such a task is
			// `none` permanently.
			for d in dirs {
				if d.vcs_kind != "git" do continue
				if created_ms, cok := platform.rfc3339_to_unix_ms(d.created_at); cok && created_ms > ev.ts_ms do continue
				st.state = "pending"
				break
			}
			return st
		}
	}
	return st
}

// Generation changes are refused while merges are pending, so a job authorized
// here cannot cross a cancel/retry while the bridge is touching the repository.
// Failed executions may settle existing Done tasks before explicit retry.
workflow_merge_allowed :: proc(svc: ^Service, task: domain.Task) -> bool {
 if task.workflow_run_id == "" do return true
 wf, ok, _ := workflow_context(svc, task.workflow_run_id, task.owner_user_id)
 return ok && wf.run.current_execution_no == task.workflow_execution_no && wf.execution.state != "cancelled"
}
