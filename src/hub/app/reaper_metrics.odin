package app

import "core:time"
import metrics "odin_test:lib/metrics"

// Reaper metrics (hub telemetry plan 3.8). The sweep deliberately swallows
// per-pass failures so one failing tidy-up cannot abort the stale-instance
// reap; `result="error"` therefore means "at least one pass reported an error
// but the sweep still completed". `last_success_timestamp_seconds` only moves
// on a fully clean sweep, which is what an alert should watch.
Reaper_Metrics :: struct {
	runs_total:   ^metrics.Family, // {result}
	last_success: ^metrics.Series,
}

reaper_metrics: Reaper_Metrics

reaper_metrics_init :: proc(reg: ^metrics.Registry) {
	if reg == nil do return
	reaper_metrics.runs_total = metrics.new_counter(reg, "heimdall_reaper_runs_total",
		"Background reaper sweeps by outcome.", {"result"})
	reaper_metrics.last_success = metrics.with(metrics.new_gauge(reg, "heimdall_reaper_last_success_timestamp_seconds",
		"Unix time of the last reaper sweep that completed without any pass reporting an error."))
	// Pre-create both outcomes so rate() has a zero baseline from the first scrape.
	metrics.with(reaper_metrics.runs_total, "ok")
	metrics.with(reaper_metrics.runs_total, "error")
}

// reaper_metrics_record is called once per completed sweep.
reaper_metrics_record :: proc(ok: bool) {
	m := &reaper_metrics
	if m.runs_total == nil do return
	metrics.counter_inc(metrics.with(m.runs_total, "ok" if ok else "error"))
	if ok do metrics.gauge_set(m.last_success, time.time_to_unix(time.now()))
}
