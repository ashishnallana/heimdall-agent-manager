package vault

import "core:encoding/json"
import "core:strings"
import "core:testing"

@(test)
test_control_worker_cross_runtime_consent_digest_keys_and_projection :: proc(t:^testing.T) {
    control_worker_cross_runtime_flow(t,#load("../../../tests/fixtures/mcp_worker_v1.json",string))
    control_worker_cross_runtime_flow(t,#load("../../../tests/fixtures/mcp_worker_v2.json",string))
}
control_worker_cross_runtime_flow :: proc(t:^testing.T,vector_json:string) {
	context.allocator=context.temp_allocator
	v:struct {now_ms:i64,keyring_hex,device_id,bridge_device_id,result:string,job:Control_Job,reply,bridge_reply:Control_Reply}
	testing.expect(t,json.unmarshal_string(vector_json,&v,.JSON,context.temp_allocator)==nil)
	raw:=make([]byte,len(v.keyring_hex)/2,context.temp_allocator)
	testing.expect(t,hex_decode_into(raw,v.keyring_hex))
	kr,parsed:=keyring_parse(raw,v.job.owner)
	defer keyring_wipe(&kr)
	testing.expect(t,parsed)
	testing.expect_value(t,control_job_digest(v.job),v.job.digest)
	testing.expect(t,control_job_verify(v.job,v.job.owner,v.job.resource,v.device_id,&kr,v.now_ms))
	testing.expect(t,control_job_verify(v.job,v.job.owner,v.job.resource,v.bridge_device_id,&kr,v.now_ms),"approved bridge uses its unsealed keyring, without directory wrap privilege")
	dir,pinned:=directory_verify(v.job.directory);testing.expect(t,pinned)
	root:=dir.ever_approved[dir.root_device_id]
	pin,pin_ok:=root_pin_from_hex(dir.root_device_id,root.sign_alg,dir.root_public_key);testing.expect(t,pin_ok)
	testing.expect(t,control_job_verify(v.job,v.job.owner,v.job.resource,v.bridge_device_id,&kr,v.now_ms,&pin))
	pin.sign_pub[1]~=1
	testing.expect(t,!control_job_verify(v.job,v.job.owner,v.job.resource,v.bridge_device_id,&kr,v.now_ms,&pin))
	for reply in ([]Control_Reply{v.reply,v.bridge_reply}) {
		dir,ok:=directory_verify(v.job.directory)
		testing.expect(t,ok)
		d:=dir.trusted[reply.device_id]
		statement:=control_reply_statement(v.job,reply.device_id,reply.result)
		testing.expect(t,verify(d.sign_alg,d.sign_public_key,transmute([]byte)statement,reply.signature))
		testing.expect(t,!verify(d.sign_alg,d.sign_public_key,transmute([]byte)control_reply_statement(v.job,reply.device_id,strings.concatenate({reply.result,"tamper"},context.temp_allocator)),reply.signature))
	}
	result,opened:=control_job_transform(v.job,&kr)
	testing.expect(t,opened && strings.contains(result,"worker secret title") && strings.contains(result,"embedded worker secret body") && !strings.contains(result,"private internal brief") && !strings.contains(result,"vault:v2:"))
	bad:=v.job;bad.generation="other"
	testing.expect(t,!control_job_verify(bad,bad.owner,bad.resource,v.device_id,&kr,v.now_ms))
	bad=v.job;bad.payload="{}";bad.digest=control_job_digest(bad);bad.consent=strings.concatenate({bad.consent," "},context.temp_allocator)
	testing.expect(t,!control_job_verify(bad,bad.owner,bad.resource,v.device_id,&kr,v.now_ms))
	testing.expect(t,!control_job_verify(v.job,"another",v.job.resource,v.device_id,&kr,v.now_ms))
	testing.expect(t,!control_job_verify(v.job,v.job.owner,"https://other.example/api/v1/mcp",v.device_id,&kr,v.now_ms))
	testing.expect(t,!control_job_verify(v.job,v.job.owner,v.job.resource,v.device_id,&kr,v.job.deadline_ms))
	kr.entries[0].key[0]~=1
	testing.expect(t,!control_job_verify(v.job,v.job.owner,v.job.resource,v.device_id,&kr,v.now_ms))
}
