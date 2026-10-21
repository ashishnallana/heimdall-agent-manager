package dbtelemetry

import "core:sync"
import "core:time"

// Sampled slow-request / slow-scope records (plan §3). The decision is made
// here; the transport layer formats the sanitized log line (route pattern,
// method, status class, components, top-3 calls as file:line - never SQL text,
// parameters, query strings, bodies or identifiers).

Slow_Reason :: enum u8 {
	Slow,
	Sample,
}

SLOW_REASON_LABELS := [Slow_Reason]string {
	.Slow   = "slow",
	.Sample = "sample",
}

DEFAULT_SLOW_MS :: 250
DEFAULT_SAMPLE_N :: 1000
DEFAULT_SCOPE_SLOW_MS :: 1000
SLOW_LOG_MAX_PER_SECOND :: 10

Slow_Config :: struct {
	slow_ms:       i64, // 0 disables threshold-triggered records
	sample_n:      i64, // 0 disables 1-in-N sampling
	scope_slow_ms: i64,
}

slow_config := Slow_Config{slow_ms = DEFAULT_SLOW_MS, sample_n = DEFAULT_SAMPLE_N, scope_slow_ms = DEFAULT_SCOPE_SLOW_MS}

@(private)
slow_mu: sync.Mutex
@(private)
slow_tokens: f64 = SLOW_LOG_MAX_PER_SECOND
@(private)
slow_refill_at: time.Tick
@(private)
slow_dropped_since_last: i64
@(private)
sample_counter: u64

Slow_Decision :: struct {
	emit:               bool,
	reason:             Slow_Reason,
	dropped_since_last: i64,
}

// slow_decide returns whether a record should be written for a unit of work
// that took `elapsed_ns`. A request both over the threshold and sampled is
// `slow`. Records over the token bucket (<= 10 lines/s) are dropped and
// counted in heimdall_db_slow_log_dropped_total{reason}.
slow_decide :: proc(elapsed_ns: i64, threshold_ms: i64) -> Slow_Decision {
	if !enabled() do return {}
	reason: Slow_Reason
	switch {
	case threshold_ms > 0 && elapsed_ns >= threshold_ms * 1_000_000:
		reason = .Slow
	case slow_config.sample_n > 0 && sync.atomic_add(&sample_counter, 1) % u64(slow_config.sample_n) == 0:
		reason = .Sample
	case:
		return {}
	}
	sync.lock(&slow_mu)
	defer sync.unlock(&slow_mu)
	now := time.tick_now()
	if slow_refill_at != {} {
		slow_tokens += time.duration_seconds(time.tick_diff(slow_refill_at, now)) * SLOW_LOG_MAX_PER_SECOND
		if slow_tokens > SLOW_LOG_MAX_PER_SECOND do slow_tokens = SLOW_LOG_MAX_PER_SECOND
	}
	slow_refill_at = now
	if slow_tokens < 1 {
		slow_dropped_since_last += 1
		counter_add(tm.slow_dropped[reason], 1)
		return {}
	}
	slow_tokens -= 1
	d := Slow_Decision{emit = true, reason = reason, dropped_since_last = slow_dropped_since_last}
	slow_dropped_since_last = 0
	return d
}

// slow_reset_for_test restores the token bucket and sample counter.
slow_reset_for_test :: proc() {
	sync.lock(&slow_mu)
	defer sync.unlock(&slow_mu)
	slow_tokens = SLOW_LOG_MAX_PER_SECOND
	slow_refill_at = {}
	slow_dropped_since_last = 0
	sync.atomic_store(&sample_counter, 0)
}
