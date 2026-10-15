package bridge_runtime

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import domain "odin_test:hub/domain"
import project "odin_test:hub/service/project"

@(test)
runtime_dynamic_instances_and_terminal_cleanup :: proc(t: ^testing.T) {
	r := new(project.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(r); free(r) }
	hello, ok, _ := runtime_accept_hello(r, "bridge", PROTOCOL_VERSION, "", "customer")
	testing.expect(t, ok)
	for i in 0..<700 {
		id := fmt.aprintf("agent-{}", i)
		_, admitted, err := project.bridge_runtime_instance_apply(r, "bridge", hello.generation, id, "customer", "running", "idle", 1)
		delete(id)
		testing.expect(t, admitted && err.code == .None)
	}
	testing.expect_value(t, r.active_instances, 700)
	c := project.bridge_runtime_connection_acquire(r, "bridge", hello.generation)
	testing.expect_value(t, len(c.instances), 700)
	for i in 0..<700 {
		id := fmt.aprintf("agent-{}", i)
		_, admitted, _ := project.bridge_runtime_instance_apply(r, "bridge", hello.generation, id, "customer", "stopped", "idle", 2)
		delete(id)
		testing.expect(t, admitted)
	}
	testing.expect_value(t, r.active_instances, 0)
	testing.expect(t, len(c.instances) <= project.runtime_registry_limits(r).terminal_instances_per_bridge)
	testing.expect_value(t, len(r.active_by_owner), 0)
	_ = project.bridge_runtime_registry_sweep(r, time.now()._nsec + i64(6 * time.Minute))
	testing.expect_value(t, len(c.instances), 0)
	project.bridge_runtime_connection_release(r, c)
}

@(test)
runtime_connection_churn_reclaims_writers_and_never_reuses_epoch :: proc(t: ^testing.T) {
	r := new(project.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(r); free(r) }
	previous := 0
	for i in 0..<1500 {
		id := fmt.aprintf("bridge-{}", i)
		hello, ok, _ := runtime_accept_hello(r, id, PROTOCOL_VERSION, "", "customer")
		testing.expect(t, ok && hello.generation > previous)
		previous = hello.generation
		project.bridge_runtime_registry_mark_offline(r, id, hello.generation)
		testing.expect_value(t, r.live_bridge_count, 0)
		testing.expect_value(t, r.connection_count, 0)
		delete(id)
	}
	first, _, _ := runtime_accept_hello(r, "same", PROTOCOL_VERSION, "", "customer")
	project.bridge_runtime_registry_mark_offline(r, "same", first.generation)
	second, _, _ := runtime_accept_hello(r, "same", PROTOCOL_VERSION, "", "customer")
	testing.expect(t, second.generation > first.generation)
	project.bridge_runtime_registry_mark_offline(r, "same", first.generation)
	testing.expect_value(t, project.bridge_runtime_registry_generation(r, "same"), second.generation)
}

@(test)
runtime_retired_connection_survives_outstanding_lease :: proc(t: ^testing.T) {
	r := new(project.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(r); free(r) }
	old, _, _ := runtime_accept_hello(r, "bridge", PROTOCOL_VERSION, "", "customer")
	lease := project.bridge_runtime_connection_acquire(r, "bridge", old.generation)
	_, _, _ = project.bridge_runtime_instance_apply(r, "bridge", old.generation, "agent", "customer", "running", "idle", 900)
	fresh, ok, _ := runtime_accept_hello(r, "bridge", PROTOCOL_VERSION, "", "customer")
	testing.expect(t, ok && fresh.replaced_existing)
	testing.expect(t, sync.atomic_load(&lease.retired))
	testing.expect_value(t, lease.generation, old.generation)
	testing.expect_value(t, len(lease.instances), 0)
	testing.expect_value(t, r.active_instances, 0)
	testing.expect_value(t, r.connection_count, 2)
	_, accepted, err := project.bridge_runtime_instance_apply(r, "bridge", old.generation, "agent", "customer", "running", "idle", 901)
	testing.expect(t, !accepted && err.code == .Bridge_Offline)
	_, accepted, _ = project.bridge_runtime_instance_apply(r, "bridge", fresh.generation, "agent", "customer", "running", "idle", 1)
	testing.expect(t, accepted, "new generation accepts its own sequence starting at one")
	project.bridge_runtime_connection_release(r, lease)
	testing.expect_value(t, r.connection_count, 1)
}

@(test)
runtime_digest_isolated_to_reporting_bridge :: proc(t: ^testing.T) {
	r := new(project.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(r); free(r) }
	a, _, _ := runtime_accept_hello(r, "a", PROTOCOL_VERSION, "", "customer")
	b, _, _ := runtime_accept_hello(r, "b", PROTOCOL_VERSION, "", "customer")
	_ = runtime_apply_state_report(r, "a", a.generation, "same-id", 7, "running", "idle", "customer")
	_ = runtime_apply_state_report(r, "b", b.generation, "same-id", 9, "running", "busy", "customer")
	testing.expect_value(t, runtime_reconcile_digest(r, "a", a.generation, nil), 1)
	state, found := project.bridge_runtime_instance_get(r, "b", b.generation, "same-id")
	defer { delete(state.owner_id); delete(state.runtime_status); delete(state.activity_status) }
	testing.expect(t, found && state.runtime_status == "running" && state.state_seq == 9)
	testing.expect_value(t, r.active_instances, 1)
}

@(test)
runtime_tombstone_rejects_stale_report_without_extending_retention :: proc(t: ^testing.T) {
	r := new(project.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(r); free(r) }
	r.limits.terminal_retention = time.Second
	hello, _, _ := runtime_accept_hello(r, "bridge", PROTOCOL_VERSION, "", "customer")
	now := time.now()._nsec
	_, _, _ = project.bridge_runtime_instance_apply(r, "bridge", hello.generation, "agent", "customer", "running", "idle", 5, now_ns = now)
	_, _, _ = project.bridge_runtime_instance_apply(r, "bridge", hello.generation, "agent", "customer", "stopped", "idle", 6, now_ns = now)
	_, accepted, _ := project.bridge_runtime_instance_apply(r, "bridge", hello.generation, "agent", "customer", "running", "idle", 5, now_ns = now + i64(500 * time.Millisecond))
	testing.expect(t, !accepted)
	testing.expect_value(t, project.bridge_runtime_registry_sweep(r, now + i64(2 * time.Second)), 1)
}

@(test)
runtime_active_quotas_are_per_owner_and_global_and_reusable :: proc(t: ^testing.T) {
	r := new(project.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(r); free(r) }
	r.limits.active_instances = 2
	r.limits.active_instances_per_owner = 1
	a, _, _ := runtime_accept_hello(r, "a", PROTOCOL_VERSION, "", "alice")
	b, _, _ := runtime_accept_hello(r, "b", PROTOCOL_VERSION, "", "bob")
	c, _, _ := runtime_accept_hello(r, "c", PROTOCOL_VERSION, "", "carol")
	_, ok, _ := project.bridge_runtime_instance_apply(r, "a", a.generation, "one", "alice", "running", "idle", 1)
	testing.expect(t, ok)
	err: domain.Domain_Error
	_, ok, err = project.bridge_runtime_instance_apply(r, "a", a.generation, "two", "alice", "running", "idle", 1)
	testing.expect(t, !ok && err.code == .Bridge_Busy)
	_, ok, _ = project.bridge_runtime_instance_apply(r, "b", b.generation, "one", "bob", "running", "idle", 1)
	testing.expect(t, ok)
	_, ok, err = project.bridge_runtime_instance_apply(r, "c", c.generation, "one", "carol", "running", "idle", 1)
	testing.expect(t, !ok && err.code == .Bridge_Busy)
	_, _, _ = project.bridge_runtime_instance_apply(r, "a", a.generation, "one", "alice", "stopped", "idle", 2)
	_, ok, _ = project.bridge_runtime_instance_apply(r, "c", c.generation, "one", "carol", "running", "idle", 1)
	testing.expect(t, ok)
	_, ok, err = project.bridge_runtime_instance_apply(r, "c", c.generation, "intruder", "alice", "running", "idle", 1)
	testing.expect(t, !ok && err.code == .Forbidden)
	testing.expect_value(t, r.active_instances, 2)
}

@(test)
runtime_reservations_cancel_expire_and_confirm_without_double_count :: proc(t: ^testing.T) {
	r := new(project.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(r); free(r) }
	hello, _, _ := runtime_accept_hello(r, "bridge", PROTOCOL_VERSION, "", "customer")
	_, admitted, _ := project.bridge_runtime_instance_apply(r, "bridge", hello.generation, "cancel", "customer", "launching", "unknown", 0, reserve = true)
	testing.expect(t, admitted)
	project.bridge_runtime_instance_cancel_reservation(r, "bridge", hello.generation, "cancel")
	testing.expect_value(t, r.active_instances, 0)
	now := time.now()._nsec
	_, _, _ = project.bridge_runtime_instance_apply(r, "bridge", hello.generation, "expire", "customer", "launching", "unknown", 0, reserve = true, now_ns = now)
	_, _, _ = project.bridge_runtime_instance_apply(r, "bridge", hello.generation, "confirm", "customer", "launching", "unknown", 0, reserve = true, now_ns = now)
	_, _, _ = project.bridge_runtime_instance_apply(r, "bridge", hello.generation, "confirm", "customer", "running", "idle", 1, now_ns = now)
	_ = project.bridge_runtime_registry_sweep(r, now + i64(2 * time.Minute))
	testing.expect_value(t, r.active_instances, 1)
	project.bridge_runtime_instance_cancel_reservation(r, "bridge", hello.generation, "confirm")
	testing.expect(t, r.active_instances == 1, "cancel cannot remove a confirmed running instance")
}

@(test)
runtime_metadata_copy_survives_disconnect :: proc(t: ^testing.T) {
	r := new(project.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(r); free(r) }
	hello, _, _ := runtime_accept_hello(r, "bridge", PROTOCOL_VERSION, "ws://example", "customer")
	project.bridge_runtime_registry_set_public_key(r, "bridge", "public-key", hello.generation)
	key := project.bridge_runtime_registry_public_key(r, "bridge")
	url := project.bridge_runtime_registry_path_validation_url(r, "bridge")
	defer delete(key)
	defer delete(url)
	project.bridge_runtime_registry_mark_offline(r, "bridge", hello.generation)
	testing.expect_value(t, key, "public-key")
	testing.expect_value(t, url, "ws://example")
}

Quota_Job :: struct { registry: ^project.Bridge_Runtime_Registry, bridge_id: string, generation: int }
quota_entry :: proc(data: rawptr) {
	job := (^Quota_Job)(data)
	for i in 0..<100 {
		id := fmt.aprintf("agent-{}", i)
		_, _, _ = project.bridge_runtime_instance_apply(job.registry, job.bridge_id, job.generation, id, "customer", "running", "idle", 1)
		delete(id)
	}
}
@(test)
runtime_concurrent_bridges_cannot_overcommit_global_quota :: proc(t: ^testing.T) {
	r := new(project.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(r); free(r) }
	r.limits.active_instances = 64
	jobs: [4]Quota_Job
	threads: [4]^thread.Thread
	for i in 0..<4 {
		id := fmt.aprintf("bridge-{}", i)
		hello, _, _ := runtime_accept_hello(r, id, PROTOCOL_VERSION, "", "customer")
		jobs[i] = Quota_Job{registry = r, bridge_id = id, generation = hello.generation}
		threads[i] = thread.create_and_start_with_data(rawptr(&jobs[i]), quota_entry)
	}
	for i in 0..<4 { thread.join(threads[i]); thread.destroy(threads[i]); delete(jobs[i].bridge_id) }
	testing.expect_value(t, r.active_instances, 64)
}

@(test)
runtime_live_registry_scales_beyond_old_array_and_admission_is_explicit :: proc(t: ^testing.T) {
	r := new(project.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(r); free(r) }
	r.limits.live_bridges_per_owner = 512
	for i in 0..<400 {
		id := fmt.aprintf("bridge-{}", i)
		_, ok, _ := runtime_accept_hello(r, id, PROTOCOL_VERSION, "", "customer")
		delete(id)
		testing.expect(t, ok)
	}
	testing.expect_value(t, r.live_bridge_count, 400)
	r.limits.live_bridges = 400
	_, ok, err := runtime_accept_hello(r, "denied", PROTOCOL_VERSION, "", "another-customer")
	testing.expect(t, !ok && err.code == .Bridge_Busy)
	testing.expect_value(t, r.connection_count, 400)
	testing.expect(t, !project.bridge_runtime_registry_has_live(r, "denied"))
}

@(test)
runtime_disconnect_purges_observations_and_rejects_late_results :: proc(t: ^testing.T) {
	r := new(project.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(r); free(r) }
	hello, _, _ := runtime_accept_hello(r, "bridge", PROTOCOL_VERSION, "", "customer")
	inserted := runtime_command_result_for_connection(r, "bridge", hello.generation, "command", `{"type":"command_result","status":"succeeded"}`)
	testing.expect(t, inserted)
	testing.expect_value(t, r.command_slots_used, 1)
	project.bridge_runtime_registry_mark_offline(r, "bridge", hello.generation)
	testing.expect_value(t, r.command_slots_used, 0)
	inserted = runtime_command_result_for_connection(r, "bridge", hello.generation, "late", `{"type":"command_result","status":"succeeded"}`)
	testing.expect(t, !inserted)
	testing.expect_value(t, r.command_slots_used, 0)
}

Retirement_Job :: struct { registry: ^project.Bridge_Runtime_Registry, generation: int, done: bool }
retirement_entry :: proc(data: rawptr) {
	job := (^Retirement_Job)(data)
	project.bridge_runtime_registry_mark_offline(job.registry, "bridge", job.generation)
	sync.atomic_store(&job.done, true)
}
@(test)
runtime_retirement_drains_writer_before_final_release :: proc(t: ^testing.T) {
	r := new(project.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(r); free(r) }
	hello, _, _ := runtime_accept_hello(r, "bridge", PROTOCOL_VERSION, "", "customer")
	lease := project.bridge_runtime_connection_acquire(r, "bridge", hello.generation)
	sync.lock(&lease.writer_mutex)
	job := Retirement_Job{registry = r, generation = hello.generation}
	worker := thread.create_and_start_with_data(rawptr(&job), retirement_entry)
	deadline := time.time_add(time.now(), time.Second)
	for !sync.atomic_load(&lease.retired) && time.diff(time.now(), deadline) > 0 { time.sleep(time.Millisecond) }
	testing.expect(t, sync.atomic_load(&lease.retired))
	testing.expect(t, !sync.atomic_load(&job.done), "retirement must wait for the outstanding writer")
	sync.unlock(&lease.writer_mutex)
	thread.join(worker)
	thread.destroy(worker)
	testing.expect_value(t, r.connection_count, 1)
	project.bridge_runtime_connection_quiesce(r, lease)
	project.bridge_runtime_connection_release(r, lease)
	testing.expect_value(t, r.connection_count, 0)
}

Registry_Destroy_Job :: struct { registry: ^project.Bridge_Runtime_Registry, done: bool }
registry_destroy_entry :: proc(data: rawptr) {
	job := (^Registry_Destroy_Job)(data)
	project.bridge_runtime_registry_destroy(job.registry)
	sync.atomic_store(&job.done, true)
}
@(test)
runtime_registry_shutdown_waits_for_reader_lease :: proc(t: ^testing.T) {
	r := new(project.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(r); free(r) }
	hello, _, _ := runtime_accept_hello(r, "bridge", PROTOCOL_VERSION, "", "customer")
	lease := project.bridge_runtime_connection_acquire(r, "bridge", hello.generation)
	job := Registry_Destroy_Job{registry = r}
	worker := thread.create_and_start_with_data(rawptr(&job), registry_destroy_entry)
	deadline := time.time_add(time.now(), time.Second)
	for !sync.atomic_load(&lease.retired) && time.diff(time.now(), deadline) > 0 { time.sleep(time.Millisecond) }
	testing.expect(t, sync.atomic_load(&lease.retired))
	testing.expect(t, !sync.atomic_load(&job.done), "registry storage must outlive the reader")
	project.bridge_runtime_connection_release(r, lease)
	thread.join(worker)
	thread.destroy(worker)
	testing.expect_value(t, r.connection_count, 0)
}
