package mcp

import "core:testing"
import vault "odin_test:lib/vault"

@(test)
test_worker_broker_isolation_claim_generation_deadline_and_cleanup :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	b:Worker_Broker
	job:=vault.Control_Job{owner="alice",request_id="req_a",generation="gen_a",payload="private request",deadline_ms=1000}
	testing.expect(t,worker_begin(&b,job))
	_,wrong:=worker_take(&b,"bob","dev_b",1);testing.expect(t,!wrong)
	_,claimed:=worker_take(&b,"alice","dev_a",1);testing.expect(t,claimed)
	_,twice:=worker_take(&b,"alice","dev_a2",1);testing.expect(t,!twice)
	r:=vault.Control_Reply{request_id=job.request_id,generation=job.generation,device_id="dev_a",deadline_ms=1000,result="private result"}
	testing.expect(t,!worker_complete(&b,"bob","dev_a",r,1))
	testing.expect(t,!worker_complete(&b,"alice","dev_b",r,1))
	bad:=r;bad.generation="wrong";testing.expect(t,!worker_complete(&b,"alice","dev_a",bad,1))
	testing.expect(t,!worker_complete(&b,"alice","dev_a",r,1000))
	testing.expect(t,worker_complete(&b,"alice","dev_a",r,999))
	text,done:=worker_result(&b,job.request_id,job.generation);testing.expect(t,done && text=="private result")
	worker_end(&b,job.request_id,job.generation)
	testing.expect(t,!worker_complete(&b,"alice","dev_a",r,999))
	for slot in b.slots do testing.expect(t,!slot.active && slot.result=="" && slot.job=="")
	testing.expect(t,worker_begin(&b,job))
	testing.expect(t,worker_assign(&b,job.request_id,job.generation,"dev_a",7))
	_,stale:=worker_job(&b,"alice","dev_a",job.request_id,job.generation,1,connection_generation=6)
	_,current:=worker_job(&b,"alice","dev_a",job.request_id,job.generation,1,connection_generation=7)
	testing.expect(t,!stale && current)
	testing.expect(t,!worker_complete(&b,"alice","dev_a",r,1,connection_generation=6))
	testing.expect(t,worker_complete(&b,"alice","dev_a",r,1,connection_generation=7))
	worker_end(&b,job.request_id,job.generation)
}
@(test)
test_mcp_request_cancellation_scoped_and_reused_slot_is_safe :: proc(t:^testing.T) {
	r:Request_Registry
	a,ok:=request_begin(&r,"token_a","1");testing.expect(t,ok)
	_,duplicate:=request_begin(&r,"token_a","1");testing.expect(t,!duplicate)
	b,bok:=request_begin(&r,"token_b","1");testing.expect(t,bok)
	request_cancel(&r,"token_a","1")
	testing.expect(t,request_cancelled(&r,a) && !request_cancelled(&r,b))
	request_end(&r,a)
	c,cok:=request_begin(&r,"token_c","1");testing.expect(t,cok && c.slot==a.slot && c.generation!=a.generation)
	request_end(&r,a);testing.expect(t,!request_cancelled(&r,c))
	request_end(&r,b);request_end(&r,c)
}

@(test)
test_mcp_worker_registration_is_owner_device_generation_bound_and_expires :: proc(t:^testing.T) {
	r:Worker_Registrations
	defer worker_registrations_free(&r)
	testing.expect(t,worker_register(&r,"alice","dev_a","tab_1",true,50000,1))
	testing.expect(t,worker_registered(&r,"alice","dev_a","tab_1",49999))
	testing.expect(t,!worker_registered(&r,"bob","dev_a","tab_1",1))
	testing.expect(t,!worker_registered(&r,"alice","dev_b","tab_1",1))
	testing.expect(t,!worker_registered(&r,"alice","dev_a","tab_2",1))
	testing.expect(t,!worker_registered(&r,"alice","dev_a","tab_1",50000))
	testing.expect(t,!worker_register(&r,"alice","dev_a","tab_2",true,60002,1))
	testing.expect(t,worker_register(&r,"alice","dev_a","tab_1",false,50000,2))
	testing.expect(t,!worker_registered(&r,"alice","dev_a","tab_1",2))
	for slot in r.slots do testing.expect(t,!slot.active)
}
