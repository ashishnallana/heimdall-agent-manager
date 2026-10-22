#+build linux, darwin, freebsd, openbsd, netbsd
package dbtelemetry

import "core:sys/posix"

// now_ns is the telemetry hot-path clock (monotonic ns). On Linux, core:time's
// tick_now issues a raw clock_gettime(MONOTONIC_RAW) syscall; libc's
// clock_gettime(MONOTONIC) is served from the vDSO, and basic mode reads the
// clock 3x per wrapped call. Only differences are meaningful.
now_ns :: #force_inline proc "contextless" () -> i64 {
	ts: posix.timespec
	posix.clock_gettime(.MONOTONIC, &ts)
	return i64(ts.tv_sec) * 1_000_000_000 + i64(ts.tv_nsec)
}
