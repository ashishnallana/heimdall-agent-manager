#+build !windows
package main

import "core:c"
import "core:mem"
import "core:sys/posix"

MADV_DONTDUMP      :: 16

foreign import libc "system:c"
foreign libc {
	madvise :: proc(addr: rawptr, len: c.size_t, advice: c.int) -> c.int ---
}

// Allocates active key material via posix.mmap, locks it with posix.mlock() so it cannot be
// paged to swap, and flags it with posix.madvise(MADV_DONTDUMP) to prevent key material
// from being written to crash/core dumps.
secure_key_alloc :: proc(size: int) -> (key: Secure_Key, ok: bool) {
	if size <= 0 do return {}, false

	page_size := 4096
	alloc_size := ((size + page_size - 1) / page_size) * page_size

	addr := posix.mmap(
		nil,
		c.size_t(alloc_size),
		posix.Prot_Flags{.READ, .WRITE},
		posix.Map_Flags{.PRIVATE, .ANONYMOUS},
	)
	if addr == posix.MAP_FAILED || addr == nil {
		return {}, false
	}

	key.ptr = cast([^]u8)addr
	key.len = size
	key.capacity = alloc_size

	// Protect with posix.mlock() so it cannot be paged to swap
	lock_res := posix.mlock(addr, c.size_t(alloc_size))
	key.locked = (lock_res == .OK)

	// Apply posix.madvise(ptr, len, MADV_DONTDUMP) to prevent key material from being written to crash/core dumps
	adv_res := madvise(addr, c.size_t(alloc_size), MADV_DONTDUMP)
	key.dontdump = (adv_res == 0)

	return key, true
}

// On lock, shutdown, or scope exit, securely wipe key memory using mem.zero_explicit(),
// then unlock and unmap.
secure_key_wipe_and_free :: proc(key: ^Secure_Key) {
	if key == nil || key.ptr == nil do return

	mem.zero_explicit(rawptr(key.ptr), key.capacity)

	if key.locked {
		_ = posix.munlock(rawptr(key.ptr), c.size_t(key.capacity))
		key.locked = false
	}

	_ = posix.munmap(rawptr(key.ptr), c.size_t(key.capacity))
	key.ptr = nil
	key.len = 0
	key.capacity = 0
	key.dontdump = false
}
