package mcp

import "base:runtime"
import "core:strings"
import "core:sync"

Worker_Registration :: struct {owner,device,generation:string,expires_ms:i64,active:bool}
Worker_Registrations :: struct {mutex:sync.Mutex,slots:[64]Worker_Registration}
worker_registrations_free :: proc(r:^Worker_Registrations) {
	sync.mutex_lock(&r.mutex);defer sync.mutex_unlock(&r.mutex)
	for &slot in r.slots do if slot.active {
		delete(slot.owner,runtime.heap_allocator());delete(slot.device,runtime.heap_allocator());delete(slot.generation,runtime.heap_allocator());slot={}
	}
}
worker_register :: proc(r:^Worker_Registrations,owner,device,generation:string,enabled:bool,expires_ms,now:i64)->bool {
	if owner=="" || device=="" || generation=="" || len(generation)>128 || enabled && (expires_ms<=now || expires_ms>now+60000) do return false
	sync.mutex_lock(&r.mutex);defer sync.mutex_unlock(&r.mutex)
	for &slot in r.slots {
		if slot.active && (slot.expires_ms<=now || slot.owner==owner && slot.device==device && slot.generation==generation) {
			delete(slot.owner,runtime.heap_allocator());delete(slot.device,runtime.heap_allocator());delete(slot.generation,runtime.heap_allocator());slot={}
		}
	}
	if !enabled do return true
	for &slot in r.slots do if !slot.active {
		a:=runtime.heap_allocator()
		slot={owner=strings.clone(owner,a),device=strings.clone(device,a),generation=strings.clone(generation,a),expires_ms=expires_ms,active=true}
		return true
	}
	return false
}
worker_registered :: proc(r:^Worker_Registrations,owner,device,generation:string,now:i64)->bool {
	sync.mutex_lock(&r.mutex);defer sync.mutex_unlock(&r.mutex)
	for slot in r.slots do if slot.active && slot.owner==owner && slot.device==device && slot.generation==generation && slot.expires_ms>now do return true
	return false
}
