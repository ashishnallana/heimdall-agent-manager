package taskv2

import "core:sync"
import domain "odin_test:hub/domain"
import metrics "odin_test:lib/metrics"

// Task System v2 metric families (plan §2.3). Labels are closed vocabularies —
// never an id — so a chain or an agent can never mint a series.
Task_Metrics :: struct {
	lease_active:   ^metrics.Family, // gauge {kind}
	lease_expired:  ^metrics.Family, // counter {reason}
	matcher_runs:   ^metrics.Family, // counter {trigger}
	timers_armed:   ^metrics.Series, // gauge
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
