package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

Bridge_Dependency_Breaker :: struct {
	key: string,
	consecutive_failures: int,
	open_until_ns: i64,
	half_open_probe: bool,
	open_count: u64,
	rejected_count: u64,
}

BRIDGE_DEPENDENCY_BREAKER_FAILURE_THRESHOLD :: 3
BRIDGE_DEPENDENCY_BREAKER_COOLDOWN :: 30 * time.Second
BRIDGE_DEPENDENCY_BREAKER_LIMIT :: 64

bridge_dependency_breaker_mutex: sync.Mutex
bridge_dependency_breakers: [dynamic]Bridge_Dependency_Breaker

bridge_dependency_breaker_index_locked :: proc(key: string) -> int {
	for breaker, i in bridge_dependency_breakers do if breaker.key == key do return i
	return -1
}

bridge_dependency_breaker_allow_at :: proc(key: string, now_ns: i64) -> bool {
	if key == "" do return true
	sync.mutex_lock(&bridge_dependency_breaker_mutex)
	defer sync.mutex_unlock(&bridge_dependency_breaker_mutex)
	i := bridge_dependency_breaker_index_locked(key)
	if i < 0 do return true
	breaker := &bridge_dependency_breakers[i]
	if breaker.open_until_ns == 0 do return true
	if now_ns < breaker.open_until_ns {
		breaker.rejected_count += 1
		return false
	}
	if breaker.half_open_probe {
		breaker.rejected_count += 1
		return false
	}
	breaker.half_open_probe = true
	return true
}

bridge_dependency_breaker_allow :: proc(key: string) -> bool {
	return bridge_dependency_breaker_allow_at(key, time.to_unix_nanoseconds(time.now()))
}

bridge_dependency_breaker_record_at :: proc(key: string, success: bool, now_ns: i64) {
	if key == "" do return
	sync.mutex_lock(&bridge_dependency_breaker_mutex)
	defer sync.mutex_unlock(&bridge_dependency_breaker_mutex)
	i := bridge_dependency_breaker_index_locked(key)
	if i < 0 {
		if success || len(bridge_dependency_breakers) >= BRIDGE_DEPENDENCY_BREAKER_LIMIT do return
		if bridge_dependency_breakers.allocator.procedure == nil do bridge_dependency_breakers = make([dynamic]Bridge_Dependency_Breaker, runtime.default_allocator())
		append(&bridge_dependency_breakers, Bridge_Dependency_Breaker{key = strings.clone(key, runtime.default_allocator())})
		i = len(bridge_dependency_breakers) - 1
	}
	breaker := &bridge_dependency_breakers[i]
	if success {
		breaker.consecutive_failures = 0
		breaker.open_until_ns = 0
		breaker.half_open_probe = false
		return
	}
	breaker.consecutive_failures += 1
	breaker.half_open_probe = false
	if breaker.consecutive_failures >= BRIDGE_DEPENDENCY_BREAKER_FAILURE_THRESHOLD {
		breaker.open_until_ns = now_ns + i64(BRIDGE_DEPENDENCY_BREAKER_COOLDOWN)
		breaker.open_count += 1
	}
}

bridge_dependency_breaker_record :: proc(key: string, success: bool) {
	bridge_dependency_breaker_record_at(key, success, time.to_unix_nanoseconds(time.now()))
}

bridge_dependency_breaker_snapshot :: proc(key: string) -> (Bridge_Dependency_Breaker, bool) {
	sync.mutex_lock(&bridge_dependency_breaker_mutex)
	defer sync.mutex_unlock(&bridge_dependency_breaker_mutex)
	i := bridge_dependency_breaker_index_locked(key)
	if i < 0 do return {}, false
	value := bridge_dependency_breakers[i]
	value.key = strings.clone(value.key)
	return value, true
}

// bridge_dependency_breaker_diagnostics_write appends the bridge_diagnostics
// dependency_breakers family: the open gauge and cumulative opened counter the hub
// consumes. tracked/rejected stay in the legacy heartbeat object only.
bridge_dependency_breaker_diagnostics_write :: proc(b: ^strings.Builder) {
	now_ns := time.to_unix_nanoseconds(time.now())
	sync.mutex_lock(&bridge_dependency_breaker_mutex)
	open := 0
	opened: u64
	for breaker in bridge_dependency_breakers {
		if breaker.open_until_ns > now_ns do open += 1
		opened += breaker.open_count
	}
	sync.mutex_unlock(&bridge_dependency_breaker_mutex)
	fmt.sbprintf(b, `{{"open":%d,"opened":%d}}`, open, opened)
}

bridge_dependency_breaker_metrics_json :: proc() -> string {
	now_ns := time.to_unix_nanoseconds(time.now())
	sync.mutex_lock(&bridge_dependency_breaker_mutex)
	defer sync.mutex_unlock(&bridge_dependency_breaker_mutex)
	open := 0
	opened: u64
	rejected: u64
	for breaker in bridge_dependency_breakers {
		if breaker.open_until_ns > now_ns do open += 1
		opened += breaker.open_count
		rejected += breaker.rejected_count
	}
	b := strings.builder_make()
	strings.write_string(&b, "{\"tracked\":")
	strings.write_string(&b, fmt.tprintf("%d", len(bridge_dependency_breakers)))
	strings.write_string(&b, ",\"open\":")
	strings.write_string(&b, fmt.tprintf("%d", open))
	strings.write_string(&b, ",\"opened\":")
	strings.write_string(&b, fmt.tprintf("%d", opened))
	strings.write_string(&b, ",\"rejected\":")
	strings.write_string(&b, fmt.tprintf("%d", rejected))
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}
