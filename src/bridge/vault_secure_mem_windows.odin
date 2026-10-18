package main

import "core:mem"
import win "core:sys/windows"

// Allocates active key material with VirtualAlloc and pins it with VirtualLock so
// it cannot be paged out (the Windows counterpart of mmap + mlock). Windows has no
// per-range MADV_DONTDUMP; dontdump stays false.
secure_key_alloc :: proc(size: int) -> (key: Secure_Key, ok: bool) {
	if size <= 0 do return {}, false

	page_size := 4096
	alloc_size := ((size + page_size - 1) / page_size) * page_size

	addr := win.VirtualAlloc(nil, uint(alloc_size), win.MEM_COMMIT | win.MEM_RESERVE, win.PAGE_READWRITE)
	if addr == nil do return {}, false

	key.ptr = cast([^]u8)addr
	key.len = size
	key.capacity = alloc_size
	key.locked = bool(win.VirtualLock(addr, uint(alloc_size)))
	return key, true
}

// On lock, shutdown, or scope exit, securely wipe key memory using mem.zero_explicit(),
// then unlock and release.
secure_key_wipe_and_free :: proc(key: ^Secure_Key) {
	if key == nil || key.ptr == nil do return

	mem.zero_explicit(rawptr(key.ptr), key.capacity)

	if key.locked {
		_ = win.VirtualUnlock(rawptr(key.ptr), uint(key.capacity))
		key.locked = false
	}

	_ = win.VirtualFree(rawptr(key.ptr), 0, win.MEM_RELEASE)
	key.ptr = nil
	key.len = 0
	key.capacity = 0
	key.dontdump = false
}
