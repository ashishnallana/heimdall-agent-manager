package app

import "core:testing"
import "core:time"
import metrics "odin_test:lib/metrics"

// heimdall_reaper_runs_total{result} + heimdall_reaper_last_success_timestamp_seconds.
@(test)
test_reaper_metrics_record_outcomes :: proc(t: ^testing.T) {
	reaper_metrics_init(metrics.init_global())
	ok_series := metrics.with(reaper_metrics.runs_total, "ok")
	err_series := metrics.with(reaper_metrics.runs_total, "error")
	ok_before := metrics.counter_value(ok_series)
	err_before := metrics.counter_value(err_series)

	start := time.time_to_unix(time.now())
	reaper_metrics_record(true)
	testing.expect_value(t, metrics.counter_value(ok_series) - ok_before, u64(1))
	testing.expect_value(t, metrics.counter_value(err_series) - err_before, u64(0))
	stamp := metrics.gauge_value(reaper_metrics.last_success)
	testing.expect(t, stamp >= start && stamp <= start + 5, "last_success set to now (unix seconds)")

	reaper_metrics_record(false)
	testing.expect_value(t, metrics.counter_value(ok_series) - ok_before, u64(1))
	testing.expect_value(t, metrics.counter_value(err_series) - err_before, u64(1))
	testing.expect(t, metrics.gauge_value(reaper_metrics.last_success) >= stamp, "a failed sweep never moves last_success backwards")
}
