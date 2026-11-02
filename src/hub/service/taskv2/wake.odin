package taskv2

import "core:fmt"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import agent "odin_test:hub/service/agent"
import project "odin_test:hub/service/project"

// Wake delivery (plan §2.5 / §4). A UoW never talks to a bridge: it queues
// run[]/stop[] entries on the Effects list and flush_wakes sends ONE wake_agent
// command per (bridge × chain) after COMMIT. The bridge's wake path kills and
// re-bootstraps an instance it already has a launch record for, and does a full
// launch for one it has never seen (JIT) — one launch path for every restart
// reason (§4c).

// effect_wake_lease queues the run[] entry that delivers `lease` to its holder:
// the enriched descriptor the bridge needs for the agent-keyed bootstrap plus
// lease_id and the context pack.
effect_wake_lease :: proc(svc: ^Service, u: ^Uow, lease: domain.Task_Lease, task: domain.Task) {
	if u == nil do return
	inst, iok, _ := iface.agent_get_instance(svc.agents, lease.holder_instance_id)
	if !iok do return
	bridge_id := lease.bridge_id
	if bridge_id == "" do bridge_id = inst.bridge_id
	if bridge_id == "" {
		fmt.eprintfln("[taskv2] wake: lease %s holder %s has no bridge; cannot deliver", lease.lease_id, lease.holder_instance_id)
		return
	}
	chain, cok, _ := iface.taskchain_get_chain(svc.repo, task.chain_id)
	if !cok do return
	agent_name := ""
	permission_mode := domain.agent_instance_effective_permission_mode(inst)
	if ag, aok, _ := iface.agent_get(svc.agents, inst.agent_id); aok {
		agent_name = ag.name
		permission_mode = domain.effective_permission_mode(inst.permission_mode, ag.permission_mode)
	}
	role := "worker"
	if lease.kind == domain.LEASE_KIND_REVIEW do role = "reviewer"
	provider, model := lease_launch_model(svc, Placement{bridge_id = bridge_id, provider = lease.provider, provider_profile=lease.provider_profile, model = lease.model}, inst)
	append(&u.effects.owned_strings, provider, model)
	entry := agent.Wake_Agent_Run_Entry{
		run_count = inst.run_count,
		agent_instance_id = inst.agent_instance_id,
		task_id           = string(task.task_id),
		role              = role,
		provider          = provider,
		provider_profile=domain.profile_effective_id(provider,lease.provider_profile),
		model             = model,
		agent_id          = inst.agent_id,
		agent_name        = agent_name,
		chain_id          = string(chain.chain_id),
		chain_title       = chain.title,
		coordinator_id    = chain.coordinator_agent_instance_id,
		project_id        = string(inst.project_id),
		project_path      = inst.project_path,
		lease_id          = lease.lease_id,
		pack_json         = build_pack_json(svc, chain, task, lease, inst),
		permission_mode   = permission_mode,
	}
	key := effects_key(&u.effects, bridge_id, string(chain.chain_id))
	entries := u.effects.runs[key]
	// A later entry for the same instance in one UoW replaces the earlier one.
	replaced := false
	for &e in entries {
		if e.agent_instance_id == entry.agent_instance_id { e = entry; replaced = true }
	}
	if !replaced do append(&entries, entry)
	u.effects.runs[key] = entries
	// An instance we are about to (re)start must not also be in stop[].
	remove_stop(u, key, entry.agent_instance_id)
}

// effect_stop queues `instance_id` on the stop[] list of its bridge × chain.
// The coordinator is never stopped by the lease system (callers check; the
// bridge checks again).
effect_stop :: proc(u: ^Uow, bridge_id, chain_id, instance_id: string) {
	if u == nil || bridge_id == "" || instance_id == "" do return
	key := effects_key(&u.effects, bridge_id, chain_id)
	if entries, has := u.effects.runs[key]; has {
		for e in entries do if e.agent_instance_id == instance_id do return // being restarted in this UoW
	}
	stops := u.effects.stops[key]
	for s in stops do if s == instance_id do return
	append(&stops, instance_id)
	u.effects.stops[key] = stops
}

effect_has_stop :: proc(u: ^Uow, bridge_id, chain_id, instance_id: string) -> bool {
	if u == nil || bridge_id == "" || instance_id == "" do return false
	key := effects_key(&u.effects, bridge_id, chain_id)
	if stops, has := u.effects.stops[key]; has {
		for s in stops do if s == instance_id do return true
	}
	return false
}

@(private = "file")
remove_stop :: proc(u: ^Uow, key, instance_id: string) {
	stops, has := u.effects.stops[key]
	if !has do return
	for i := 0; i < len(stops); i += 1 {
		if stops[i] == instance_id {
			ordered_remove(&stops, i)
			i -= 1
		}
	}
	u.effects.stops[key] = stops
}

@(private = "file")
split_wake_key :: proc(key: string) -> (bridge_id, chain_id: string) {
	for i in 0..<len(key) {
		if key[i] == 0 do return key[:i], key[i+1:]
	}
	return key, ""
}

// Wake_Command is one wake_agent push as sent (test seam: svc.wake_observer).
Wake_Command :: struct {
	bridge_id: string,
	chain_id:  string,
	body_json: string,
}

// flush_wakes sends one wake_agent command per (bridge × chain) for the
// runs/stops a committed UoW decided on. Called after COMMIT, never under the
// tx mutex.
flush_wakes :: proc(svc: ^Service, e: ^Effects) {
	keys := make(map[string]bool, context.temp_allocator)
	for k in e.runs do keys[k] = true
	for k in e.stops do keys[k] = true
	for key in keys {
		bridge_id, chain_id := split_wake_key(key)
		if bridge_id == "" do continue
		runs := e.runs[key]
		stops := e.stops[key]
		if len(runs) == 0 && len(stops) == 0 do continue
		cmd_id := platform.generate_id(svc.ids, "cmd_")
		body := agent.wake_agent_command_json(cmd_id, chain_id, runs[:], stops[:])
		if svc.wake_observer != nil {
			svc.wake_observer(svc.wake_observer_ctx, Wake_Command{bridge_id = bridge_id, chain_id = chain_id, body_json = body})
		}
		if sent, err := project.bridge_command_send_runtime(svc.bridge_command_sink, project.Runtime_Command{bridge_id = bridge_id, command_id = cmd_id, body_json = body}); !sent && svc.bridge_command_sink.send_runtime_command != nil {
			fmt.eprintfln("[taskv2] wake_agent to bridge %s failed: %s", bridge_id, err.message)
			for run in runs do on_dispatch_failed(svc, run.lease_id, err.message)
		}
	}
}
