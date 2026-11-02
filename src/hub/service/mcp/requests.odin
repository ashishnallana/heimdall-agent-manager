package mcp

import "base:runtime"
import "core:strings"
import "core:sync"

Request_Slot :: struct {active,cancelled:bool,key,id:string,generation:u64}
Request_Handle :: struct {slot:int,generation:u64}
Request_Registry :: struct {mutex:sync.Mutex,slots:[64]Request_Slot}
request_begin :: proc(r:^Request_Registry,key,id:string)->(Request_Handle,bool) {
	sync.mutex_lock(&r.mutex);defer sync.mutex_unlock(&r.mutex)
	count:=0
	for slot in r.slots do if slot.active && slot.key==key {
		if slot.id==id do return {},false
		count+=1
	}
	if count>=4 do return {},false
	for &slot,i in r.slots do if !slot.active {
		slot.generation+=1;slot.active=true;slot.cancelled=false
		slot.key=strings.clone(key,runtime.heap_allocator());slot.id=strings.clone(id,runtime.heap_allocator())
		return {i,slot.generation},true
	}
	return {},false
}
request_cancel :: proc(r:^Request_Registry,key,id:string) {
	sync.mutex_lock(&r.mutex);defer sync.mutex_unlock(&r.mutex)
	for &slot in r.slots do if slot.active && slot.key==key && slot.id==id do slot.cancelled=true
}
request_cancelled :: proc(r:^Request_Registry,h:Request_Handle)->bool {
	sync.mutex_lock(&r.mutex);defer sync.mutex_unlock(&r.mutex)
	if h.slot<0 || h.slot>=len(r.slots) do return true
	s:=&r.slots[h.slot]
	return !s.active || s.generation!=h.generation || s.cancelled
}
request_end :: proc(r:^Request_Registry,h:Request_Handle) {
	sync.mutex_lock(&r.mutex);defer sync.mutex_unlock(&r.mutex)
	if h.slot<0 || h.slot>=len(r.slots) do return
	s:=&r.slots[h.slot]
	if !s.active || s.generation!=h.generation do return
	delete(s.key,runtime.heap_allocator());delete(s.id,runtime.heap_allocator());s.key="";s.id="";s.active=false
}
