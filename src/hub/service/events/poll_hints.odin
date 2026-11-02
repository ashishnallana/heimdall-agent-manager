package events

import "core:strings"
import "core:sync"

// Bounded, transient owner hints only. No events/results/replay are retained.
Poll_Hint :: struct {slot:int,generation:u64}
Poll_Slot :: struct {owner,chain_id:string,generation,revision:u64,active:bool}
poll_attach :: proc(bus:^User_Event_Bus,owner:string,chain_id:="")->(Poll_Hint,bool) {
	if bus==nil || owner=="" do return {},false
	sync.mutex_lock(&bus.poll_mutex);defer sync.mutex_unlock(&bus.poll_mutex)
	for &slot,i in bus.poll_slots do if !slot.active {
		slot.owner=strings.clone(owner);slot.chain_id=strings.clone(chain_id);slot.generation+=1;slot.revision=0;slot.active=true
		return {i,slot.generation},true
	}
	return {},false
}
poll_detach :: proc(bus:^User_Event_Bus,h:Poll_Hint) {
	if bus==nil || h.slot<0 || h.slot>=len(bus.poll_slots) do return
	sync.mutex_lock(&bus.poll_mutex);defer sync.mutex_unlock(&bus.poll_mutex)
	s:=&bus.poll_slots[h.slot]
	if !s.active || s.generation!=h.generation do return
	delete(s.owner);delete(s.chain_id);s.owner="";s.chain_id="";s.active=false
}
poll_revision :: proc(bus:^User_Event_Bus,h:Poll_Hint)->u64 {
	if bus==nil || h.slot<0 || h.slot>=len(bus.poll_slots) do return 0
	sync.mutex_lock(&bus.poll_mutex);defer sync.mutex_unlock(&bus.poll_mutex)
	s:=&bus.poll_slots[h.slot]
	if !s.active || s.generation!=h.generation do return 0
	return s.revision
}
poll_hint :: proc(bus:^User_Event_Bus,owner,chain_id:string) {
	sync.mutex_lock(&bus.poll_mutex);defer sync.mutex_unlock(&bus.poll_mutex)
	for &slot in bus.poll_slots do if slot.active && slot.owner==owner && (slot.chain_id=="" || slot.chain_id==chain_id) do slot.revision+=1
}
