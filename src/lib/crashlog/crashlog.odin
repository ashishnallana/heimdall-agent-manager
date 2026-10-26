#+build !windows
// Package crashlog writes a one-line reason plus a raw backtrace to stderr when
// the process dies on a fatal signal (SIGSEGV/SIGBUS/SIGABRT/SIGFPE/SIGILL), then
// re-raises it so the default action (core dump) still happens.
//
// Best effort by design: the handler runs on an alternate signal stack so a
// stack-overflow SEGV can still log, and it uses only write(2) plus glibc's
// backtrace()/backtrace_symbols_fd() (no allocation). Frames print as
// `binary(+0xOFFSET)`; resolve them with `addr2line -f -e <binary> 0xOFFSET`.
//
// musl (the static release binaries, -define:HAM_LIBC_MUSL=true) has no
// execinfo; there the frames come from the unwinder in libgcc_eh
// (_Unwind_Backtrace, linked by the static cc driver) and print as raw
// addresses: the binaries are -no-pie, so `addr2line -f -e <binary> 0xADDR`.
package crashlog

import "core:sys/posix"

LIBC_MUSL :: #config(HAM_LIBC_MUSL, false)

when ODIN_OS == .Linux {
	foreign import libc "system:c"

	when LIBC_MUSL {
		@(private) Unwind_Trace_Fn :: #type proc "c" (ctx: rawptr, arg: rawptr) -> i32

		@(default_calling_convention = "c")
		foreign libc {
			raise :: proc(sig: i32) -> i32 ---
			_Unwind_Backtrace :: proc(trace: Unwind_Trace_Fn, arg: rawptr) -> i32 ---
			_Unwind_GetIP :: proc(ctx: rawptr) -> uintptr ---
		}
	} else {
		@(default_calling_convention = "c")
		foreign libc {
			backtrace :: proc(buffer: [^]rawptr, size: i32) -> i32 ---
			backtrace_symbols_fd :: proc(buffer: [^]rawptr, size: i32, fd: i32) ---
			raise :: proc(sig: i32) -> i32 ---
		}
	}
}

ALT_STACK_SIZE :: 64 * 1024
MAX_FRAMES :: 64

@(private)
g_name: [64]u8
@(private)
g_name_len: int
@(private)
g_alt_stack: [ALT_STACK_SIZE]u8

// install registers the fatal-signal handlers. `name` prefixes the log line
// (e.g. "ham-hub"). Call once, early in main.
install :: proc(name: string) {
	when ODIN_OS == .Linux {
		g_name_len = copy(g_name[:], name)
		ss := posix.stack_t{ss_sp = &g_alt_stack[0], ss_size = ALT_STACK_SIZE}
		posix.sigaltstack(&ss, nil)
		for sig in ([]posix.Signal{.SIGSEGV, .SIGBUS, .SIGABRT, .SIGFPE, .SIGILL}) {
			act := posix.sigaction_t{}
			act.sa_handler = on_fatal
			// RESETHAND: the re-raise below then takes the default action.
			act.sa_flags = {.ONSTACK, .RESETHAND}
			posix.sigemptyset(&act.sa_mask)
			posix.sigaction(sig, &act, nil)
		}
	}
}

@(private)
on_fatal :: proc "c" (sig: posix.Signal) {
	when ODIN_OS == .Linux {
		write_str("\n")
		posix.write(2, &g_name[0], uint(g_name_len))
		write_str(" fatal signal ")
		write_int(int(sig))
		write_str(" — backtrace (resolve with addr2line -f -e <binary> 0xOFFSET):\n")
		when LIBC_MUSL {
			frames := 0
			_Unwind_Backtrace(unwind_frame, &frames)
		} else {
			frames: [MAX_FRAMES]rawptr
			n := backtrace(&frames[0], MAX_FRAMES)
			backtrace_symbols_fd(&frames[0], n, 2)
		}
		raise(i32(sig))
	}
}

when ODIN_OS == .Linux && LIBC_MUSL {
	// One line per frame: "  0x<ip>". Stops after MAX_FRAMES (non-zero return).
	@(private)
	unwind_frame :: proc "c" (ctx: rawptr, arg: rawptr) -> i32 {
		count := (^int)(arg)
		if count^ >= MAX_FRAMES do return 1
		count^ += 1
		write_str("  0x")
		write_hex(u64(_Unwind_GetIP(ctx)))
		write_str("\n")
		return 0
	}
}

@(private)
write_hex :: proc "contextless" (v: u64) {
	digits := "0123456789abcdef"
	buf: [16]u8
	i := len(buf)
	n := v
	for {
		i -= 1
		buf[i] = digits[n & 0xf]
		n >>= 4
		if n == 0 || i == 0 do break
	}
	posix.write(2, &buf[i], uint(len(buf) - i))
}

@(private)
write_str :: proc "contextless" (s: string) {
	if len(s) > 0 do posix.write(2, raw_data(s), uint(len(s)))
}

@(private)
write_int :: proc "contextless" (v: int) {
	buf: [20]u8
	i := len(buf)
	n := v if v >= 0 else -v
	for {
		i -= 1
		buf[i] = u8('0' + n % 10)
		n /= 10
		if n == 0 || i == 0 do break
	}
	posix.write(2, &buf[i], uint(len(buf) - i))
}
