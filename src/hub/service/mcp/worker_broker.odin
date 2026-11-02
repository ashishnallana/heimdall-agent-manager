package mcp

import "base:runtime"
import "core:crypto"
import "core:encoding/json"
import "core:strings"
import "core:sync"
import vault "odin_test:lib/vault"

Worker_Slot :: struct {active,claimed,done:bool,owner,id,generation,device,registration,job,result:string,deadline_ms:i64,connection_generation:int}
Worker_Broker :: struct {mutex:sync.Mutex,slots:[64]Worker_Slot}
worker_assign :: proc(b:^Worker_Broker,id,generation,device:string,connection_generation:=0)->bool {
	sync.mutex_lock(&b.mutex);defer sync.mutex_unlock(&b.mutex)
	for &slot in b.slots do if slot.active && !slot.claimed && slot.id==id && slot.generation==generation {
		slot.claimed=true;slot.device=strings.clone(device,runtime.heap_allocator());slot.connection_generation=connection_generation;return true
	}
	return false
}
worker_unclaim :: proc(b:^Worker_Broker,id,generation,device:string) {
	sync.mutex_lock(&b.mutex);defer sync.mutex_unlock(&b.mutex)
	for &slot in b.slots do if slot.active && slot.id==id && slot.generation==generation && slot.device==device {
		delete(slot.device,runtime.heap_allocator());slot.device="";slot.claimed=false;slot.done=false
		delete(slot.registration,runtime.heap_allocator());slot.registration=""
		slot.connection_generation=0
		if slot.result!="" {crypto.zero_explicit(raw_data(slot.result),len(slot.result));delete(slot.result,runtime.heap_allocator());slot.result=""}
		return
	}
}
worker_begin :: proc(b:^Worker_Broker,job:vault.Control_Job)->bool {
	encoded,err:=json.marshal(job,allocator=context.temp_allocator)
	if err!=nil || len(encoded)>5*1024*1024 do return false
	defer if len(encoded)>0 do crypto.zero_explicit(raw_data(encoded),len(encoded))
	sync.mutex_lock(&b.mutex);defer sync.mutex_unlock(&b.mutex)
	count:=0
	for slot in b.slots do if slot.active && slot.owner==job.owner do count+=1
	if count>=4 do return false
	for &slot in b.slots do if !slot.active {
		a:=runtime.heap_allocator()
		slot={active=true,owner=strings.clone(job.owner,a),id=strings.clone(job.request_id,a),generation=strings.clone(job.generation,a),job=strings.clone(string(encoded),a),deadline_ms=job.deadline_ms}
		return true
	}
	return false
}
worker_take :: proc(b:^Worker_Broker,owner,device:string,now:i64,registration:="")->(string,bool) {
	sync.mutex_lock(&b.mutex);defer sync.mutex_unlock(&b.mutex)
	for &slot in b.slots do if slot.active && !slot.claimed && slot.owner==owner && slot.deadline_ms>now {
		slot.claimed=true;slot.device=strings.clone(device,runtime.heap_allocator())
		slot.registration=strings.clone(registration,runtime.heap_allocator())
		return strings.clone(slot.job,context.temp_allocator),true
	}
	return "",false
}
worker_job :: proc(b:^Worker_Broker,owner,device,id,generation:string,now:i64,registration:="",connection_generation:=0)->(vault.Control_Job,bool) {
	text:=""
	sync.mutex_lock(&b.mutex)
	for slot in b.slots do if slot.active && slot.claimed && !slot.done && slot.owner==owner && slot.device==device && slot.registration==registration && slot.connection_generation==connection_generation && slot.id==id && slot.generation==generation && slot.deadline_ms>now {text=strings.clone(slot.job,context.temp_allocator);break}
	sync.mutex_unlock(&b.mutex)
	if text=="" do return {},false
	defer crypto.zero_explicit(raw_data(text),len(text))
	job:vault.Control_Job
	err:=json.unmarshal_string(text,&job,.JSON,context.temp_allocator)
	return job,err==nil
}
worker_complete :: proc(b:^Worker_Broker,owner,device:string,reply:vault.Control_Reply,now:i64,registration:="",connection_generation:=0)->bool {
	if len(reply.result)>4*1024*1024 do return false
	sync.mutex_lock(&b.mutex);defer sync.mutex_unlock(&b.mutex)
	for &slot in b.slots do if slot.active && slot.claimed && !slot.done && slot.owner==owner && slot.device==device && slot.registration==registration && slot.connection_generation==connection_generation && slot.id==reply.request_id && slot.generation==reply.generation && slot.deadline_ms==reply.deadline_ms && slot.deadline_ms>now {
		slot.result=strings.clone(reply.result,runtime.heap_allocator());slot.done=true
		return true
	}
	return false
}
worker_receiver :: proc(b:^Worker_Broker,id,generation:string)->(device,registration:string) {
	sync.mutex_lock(&b.mutex);defer sync.mutex_unlock(&b.mutex)
	for slot in b.slots do if slot.active && slot.id==id && slot.generation==generation do return strings.clone(slot.device,context.temp_allocator),strings.clone(slot.registration,context.temp_allocator)
	return "",""
}
worker_result :: proc(b:^Worker_Broker,id,generation:string)->(string,bool) {
	sync.mutex_lock(&b.mutex);defer sync.mutex_unlock(&b.mutex)
	for slot in b.slots do if slot.active && slot.id==id && slot.generation==generation && slot.done do return strings.clone(slot.result,context.temp_allocator),true
	return "",false
}
worker_end :: proc(b:^Worker_Broker,id,generation:string) {
	sync.mutex_lock(&b.mutex);defer sync.mutex_unlock(&b.mutex)
	for &slot in b.slots do if slot.active && slot.id==id && slot.generation==generation {
		for text in ([]string{slot.owner,slot.id,slot.generation,slot.device,slot.registration,slot.job,slot.result}) do if text!="" {crypto.zero_explicit(raw_data(text),len(text));delete(text,runtime.heap_allocator())}
		slot={};return
	}
}
