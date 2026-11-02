package vault

import "core:testing"
import "core:encoding/json"
import "core:strings"

@(test)
test_catalog_browser_native_signed_jobs_and_typed_projection :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	v:struct {now_ms:i64,keyring_hex,device_id,bridge_device_id:string,entries:[]struct {job:Control_Job,result:string}}
	if !testing.expect(t,json.unmarshal_string(#load("../../../tests/fixtures/mcp_catalog_worker_v2.json",string),&v,.JSON,context.temp_allocator)==nil) do return
	bytes:=make([]byte,len(v.keyring_hex)/2,context.temp_allocator)
	if !testing.expect(t,hex_decode_into(bytes,v.keyring_hex)) do return
	kr,parsed:=keyring_parse(bytes,v.entries[0].job.owner);if !testing.expect(t,parsed) do return
	defer keyring_wipe(&kr)
	for entry in v.entries {
		job:=entry.job
		testing.expect(t,control_job_digest(job)==job.digest)
		for device in ([]string{v.device_id,v.bridge_device_id}) do testing.expect(t,control_job_verify(job,job.owner,job.resource,device,&kr,v.now_ms))
		out,ok:=control_job_transform(job,&kr);if !testing.expect(t,ok) do continue
		if job.operation=="seal_agent" {
			obj:struct {name,slug,instructions:string}
			testing.expect(t,json.unmarshal_string(out,&obj,.JSON,context.temp_allocator)==nil && !strings.contains(out,"agent secret"))
			plain,status:=open(obj.instructions,&kr,context.temp_allocator)
			testing.expect(t,status==.Ok && plain=="agent secret instructions")
		} else {
			testing.expect(t,strings.contains(out,"worker secret title") && !strings.contains(out,"vault:v2:") && !strings.contains(out,"never expose"))
			if job.tool=="providers.list" do testing.expect(t,strings.contains(out,"owner_bound_position") && strings.contains(out,"model_a"))
			data:Control_Data
			testing.expect(t,json.unmarshal_string(job.payload,&data,.JSON,context.temp_allocator)==nil)
			data.records_kind="wrong_kind"
			bad,_:=json.marshal(data,allocator=context.temp_allocator);job.payload=string(bad)
			_,opened:=control_job_transform(job,&kr);testing.expect(t,!opened)
		}
	}
	testing.expect(t,!control_job_scope_ok("mcp:chains mcp:agents:read","agents.create","seal_agent"))
	testing.expect(t,!control_job_scope_ok("mcp:chains mcp:agents:write","providers.list","read"))
}
