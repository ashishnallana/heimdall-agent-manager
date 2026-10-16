package taskv2

import "core:sync"
import domain "odin_test:hub/domain"
import metrics "odin_test:lib/metrics"

// Task System v2 metric families (plan §2.3 / §8 M3). Labels are closed vocabularies —
// never an id — so a chain or an agent can never mint a series.
Task_Metrics :: struct {
	lease_active:          ^metrics.Family, // gauge {kind}
	lease_expired:         ^metrics.Family, // counter {reason}
	matcher_runs:          ^metrics.Family, // counter {trigger}
	timers_armed:          ^metrics.Series, // gauge
	verify_total:          ^metrics.Family, // counter {result}
	transitions_total:     ^metrics.Family, // counter {from,to}
	gate_evaluations_total: ^metrics.Family, // counter {result}
}

task_metrics: Task_Metrics
@(private = "file")
task_metrics_once: sync.Once

init_task_metrics :: proc() {
	sync.once_do(&task_metrics_once, proc() {
		reg := metrics.global()
		task_metrics.lease_active = metrics.new_gauge(reg, "heimdall_task_lease_active", "Live task leases by kind.", {"kind"})
		task_metrics.lease_expired = metrics.new_counter(reg, "heimdall_task_lease_expired_total", "Task leases expired by the engine, by reason.", {"reason"})
		task_metrics.matcher_runs = metrics.new_counter(reg, "heimdall_task_matcher_runs_total", "match_chain runs by trigger.", {"trigger"})
		task_metrics.timers_armed = metrics.with(metrics.new_gauge(reg, "heimdall_task_timers_armed", "Engine timers currently armed (heap size)."))
		task_metrics.verify_total = metrics.new_counter(reg, "heimdall_task_verify_total", "Task verify runs by result.", {"result"})
		task_metrics.transitions_total = metrics.new_counter(reg, "heimdall_task_transitions_total", "Task state transitions.", {"from", "to"})
		task_metrics.gate_evaluations_total = metrics.new_counter(reg, "heimdall_task_gate_evaluations_total", "Review gate evaluations by result.", {"result"})
	})
}

timrics_set_armed :: proc(n: int) {
	if task_metrics.timers_armed == nil do return
	metrics.gauge_set(task_metrics.timers_armed, i64(n))
}

metric_lease_granted :: proc(kind: string) {
	if task_metrics.lease_active == nil do return
	metrics.gauge_inc(metrics.with(task_metrics.lease_active, lease_kind_label(kind)))
}

metric_lease_released :: proc(kind: string) {
	if task_metrics.lease_active == nil do return
	metrics.gauge_dec(metrics.with(task_metrics.lease_active, lease_kind_label(kind)))
}

metric_lease_expired :: proc(reason: string) {
	if task_metrics.lease_expired == nil do return
	metrics.counter_inc(metrics.with(task_metrics.lease_expired, expire_reason_label(reason)))
}

metric_matcher_run :: proc(trigger: Trigger) {
	if task_metrics.matcher_runs == nil do return
	metrics.counter_inc(metrics.with(task_metrics.matcher_runs, trigger_label(trigger)))
}

metric_verify_run :: proc(exit_code: int, exit_code_set: bool, status: string) {
	if task_metrics.verify_total == nil do return
	result := "fail"
	if !exit_code_set || status == "failed" || status == "killed" || exit_code < 0 {
		result = "error"
	} else if exit_code == 0 {
		result = "pass"
	}
	metrics.counter_inc(metrics.with(task_metrics.verify_total, result))
}

metric_task_transition :: proc(from_state, to_state: domain.Task_State) {
	if task_metrics.transitions_total == nil || from_state == to_state do return
	metrics.counter_inc(metrics.with(task_metrics.transitions_total, domain.task_state_string(from_state), domain.task_state_string(to_state)))
}

metric_gate_evaluated :: proc(res: Gate_Result) {
	if task_metrics.gate_evaluations_total == nil do return
	label := "waiting"
	switch res {
	case .Waiting:           label = "waiting"
	case .Approved:          label = "approved"
	case .Changes_Requested: label = "changes_requested"
	}
	metrics.counter_inc(metrics.with(task_metrics.gate_evaluations_total, label))
}

@(private = "file")
lease_kind_label :: proc(kind: string) -> string {
	if kind == domain.LEASE_KIND_REVIEW do return "review"
	return "work"
}

@(private = "file")
expire_reason_label :: proc(reason: string) -> string {
	switch reason {
	case EXPIRE_TTL, EXPIRE_HARD_CAP, EXPIRE_IDLE, EXPIRE_INSTANCE_LOST, EXPIRE_UNCONFIRMED, EXPIRE_REPLACED, EXPIRE_DEP_ADDED, EXPIRE_CHAIN_CLOSED, EXPIRE_CANCELLED, EXPIRE_CHANGES_REQUESTED, EXPIRE_HUB_RESTART:
		return reason
	}
	return "other"
}
