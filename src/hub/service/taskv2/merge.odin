package taskv2

import "core:fmt"
import "core:strings"
import "core:thread"
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
effect_merge_worktree :: proc(svc: ^Service, u: ^Uow, task: domain.Task, evs: []domain.Task_Event) {
	if u == nil || !PER_LEASE_WORKTREES_ENABLED do return
	bridge_id := ""
	for i := len(evs) - 1; i >= 0; i -= 1 {
		ev := evs[i]
		if ev.kind != EV_LEASE_GRANTED do continue
		if jsonx.extract_string(ev.payload_json, "kind", domain.LEASE_KIND_WORK, true, context.temp_allocator) != domain.LEASE_KIND_WORK do continue
		bridge_id = jsonx.extract_string(ev.payload_json, "bridge_id", "", true, context.temp_allocator)
		break
	}
	if bridge_id == "" do return
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
	defer {
		destroy_merge_effect(job.merge)
		free(job)
		free_all(context.temp_allocator)
	}
	run_merge(job.svc, job.merge)
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
	command_id := platform.generate_id(svc.ids, "cmd_merge_")
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
	if rok && outcome == .Conflict {
		rok, _ = after_chain_change(svc, &u, saved.chain_id, saved.owner_user_id, .Task_Updated)
	}
	_, _ = end_uow(svc, &u, rok)
}
