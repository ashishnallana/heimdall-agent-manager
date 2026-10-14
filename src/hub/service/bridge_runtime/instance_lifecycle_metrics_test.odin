package bridge_runtime

import "core:testing"
import project "odin_test:hub/service/project"
import metrics "odin_test:lib/metrics"

// Plan 3.3: agent_instance_starts_total / exits_total are derived from runtime
// state transitions in the registry, labelled by status enum only.
@(test)
test_instance_lifecycle_counters :: proc(t: ^testing.T) {
	project.fleet_metrics_init(metrics.init_global())
	m := &project.fleet_metrics
	// Sibling tests in this package drive running/stopped/unreachable
	// concurrently against the shared registry, so use statuses they don't.
	starts := metrics.with(m.agent_instance_starts, "blocked")
	exits_stopped := metrics.with(m.agent_instance_exits, "failed")
	exits_unreach := metrics.with(m.agent_instance_exits, "crashed")
	starts_before := metrics.counter_value(starts)
	stopped_before := metrics.counter_value(exits_stopped)
	unreach_before := metrics.counter_value(exits_unreach)

	r := new(project.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(r); free(r) }
	hello, ok, _ := runtime_accept_hello(r, "bridge-lc", 1, "", "customer")
	testing.expect(t, ok)
	g := hello.generation
	// new -> running: start
	_, admitted, _ := project.bridge_runtime_instance_apply(r, "bridge-lc", g, "inst_a", "customer", "blocked", "idle", 1)
	testing.expect(t, admitted)
	// running -> running (seq bump): neither
	_, _, _ = project.bridge_runtime_instance_apply(r, "bridge-lc", g, "inst_a", "customer", "blocked", "busy", 2)
	// running -> stopped: exit
	_, _, _ = project.bridge_runtime_instance_apply(r, "bridge-lc", g, "inst_a", "customer", "failed", "idle", 3)
	// stopped -> stopped: nothing
	_, _, _ = project.bridge_runtime_instance_apply(r, "bridge-lc", g, "inst_a", "customer", "failed", "idle", 4)
	// stopped -> running again: second start
	_, _, _ = project.bridge_runtime_instance_apply(r, "bridge-lc", g, "inst_a", "customer", "blocked", "idle", 5)
	// running -> unreachable: exit (different status label)
	_, _, _ = project.bridge_runtime_instance_apply(r, "bridge-lc", g, "inst_a", "customer", "crashed", "idle", 6)
	// A reservation is not a start.
	_, _, _ = project.bridge_runtime_instance_apply(r, "bridge-lc", g, "inst_b", "customer", "launching", "idle", 1, reserve = true)

	testing.expect_value(t, metrics.counter_value(starts) - starts_before, u64(2))
	testing.expect_value(t, metrics.counter_value(exits_stopped) - stopped_before, u64(1))
	testing.expect_value(t, metrics.counter_value(exits_unreach) - unreach_before, u64(1))
	testing.expect_value(t, metrics.counter_value(metrics.with(m.agent_instance_starts, "launching")), u64(0))
	// Only enum statuses become labels.
	for s in m.agent_instance_starts.series do testing.expect(t, project.runtime_status_enum(s.label_values[0]) == s.label_values[0], "status label is enum-mapped")
}
