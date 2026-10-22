#+build !linux
#+build !darwin
#+build !freebsd
#+build !openbsd
#+build !netbsd
package dbtelemetry

import "core:time"

now_ns :: #force_inline proc "contextless" () -> i64 {
	return time.tick_now()._nsec
}
