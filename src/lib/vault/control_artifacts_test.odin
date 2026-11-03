#+feature dynamic-literals
package vault

import "core:testing"
import "core:encoding/json"
import "core:strings"

@(test)
test_artifact_browser_native_signed_content_jobs :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	v:struct {now_ms:i64,keyring_hex,device_id,bridge_device_id:string,entries:[]struct {job:Control_Job,result:string}}
	if !testing.expect(t,json.unmarshal_string(#load("../../../tests/fixtures/mcp_artifacts_worker_v2.json",string),&v,.JSON,context.temp_allocator)==nil) do return
	bytes:=make([]byte,len(v.keyring_hex)/2,context.temp_allocator);if !testing.expect(t,hex_decode_into(bytes,v.keyring_hex)) do return
	kr,parsed:=keyring_parse(bytes,v.entries[0].job.owner);if !testing.expect(t,parsed) do return
	defer keyring_wipe(&kr)
	for entry in v.entries {
		if !strings.has_prefix(entry.job.tool,"artifacts.") do continue
		for device in ([]string{v.device_id,v.bridge_device_id}) do testing.expect(t,control_job_verify(entry.job,entry.job.owner,entry.job.resource,device,&kr,v.now_ms))
		out,ok:=control_job_transform(entry.job,&kr);if !testing.expect(t,ok) do continue
		if entry.job.operation=="seal_resource" {
			value,_:=json.parse_string(out,parse_integers=true,allocator=context.temp_allocator);obj,_:=value.(json.Object)
			input,_:=json.parse_string(entry.job.payload,parse_integers=true,allocator=context.temp_allocator);original,_:=input.(json.Object)
			for key,text in obj {token,typed:=text.(json.String);plain,status:=open(string(token),&kr,context.temp_allocator);testing.expect(t,typed && status==.Ok && plain==string(original[key].(json.String)))}
		} else {testing.expect(t,!strings.contains(out,"vault:v2:") && !strings.contains(out,"never expose") && strings.contains(out,"artifact://art_a") && strings.contains(out,"worker secret title"))}
	}
	for scope in ([]string{"mcp:chains","mcp:chains mcp:artifacts:read","mcp:chains mcp:tasks:write"}) do testing.expect(t,!control_job_scope_ok(scope,"artifacts.create","seal_resource"))
	testing.expect(t,!control_job_scope_ok("mcp:chains mcp:artifacts:write","artifacts.get","read"))
	for fields in ([]json.Object{json.Object{"path"=json.String("/etc/passwd")},json.Object{"content"=json.String(strings.repeat("x",65537,context.temp_allocator))}}) {_,ok:=control_seal_resource_fields(&kr,"artifacts.create",fields);testing.expect(t,!ok)}
	_,ok:=control_seal_resource_fields(&kr,"artifacts.update",json.Object{"content"=json.String("No content replacement")});testing.expect(t,!ok)
	_,ok=control_record_json(&kr,.Artifact,json.Object{"owner_user_id"=json.String("system"),"read_only"=json.Boolean(true),"content"=json.String("No system exception")});testing.expect(t,!ok)
	_,ok=control_record_json(&kr,.Artifact,json.Object{"owner_user_id"=json.String(keyring_user_id(&kr)),"content_type"=json.String("text/plain"),"content"=json.String(strings.repeat("x",65537,context.temp_allocator))});testing.expect(t,!ok)
}
// Artifact jobs (html-bundle capable) may carry a deadline up to 20 s out; every
// other job keeps the 5 s window.
@(test)
test_control_job_deadline_window_is_per_job_kind :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	testing.expect_value(t,control_job_deadline_max_ms("seal_resource","artifacts.create"),i64(CONTROL_JOB_ARTIFACT_DEADLINE_MAX_MS))
	testing.expect_value(t,control_job_deadline_max_ms("read","artifacts.get"),i64(CONTROL_JOB_ARTIFACT_DEADLINE_MAX_MS))
	testing.expect_value(t,control_job_deadline_max_ms("read","artifacts.list"),i64(CONTROL_JOB_DEADLINE_MAX_MS))
	testing.expect_value(t,control_job_deadline_max_ms("seal_resource","memories.create"),i64(CONTROL_JOB_DEADLINE_MAX_MS))
	testing.expect_value(t,control_job_deadline_max_ms("read","chains.get"),i64(CONTROL_JOB_DEADLINE_MAX_MS))
	v:struct {now_ms:i64,keyring_hex,device_id,bridge_device_id:string,entries:[]struct {job:Control_Job,result:string}}
	if !testing.expect(t,json.unmarshal_string(#load("../../../tests/fixtures/mcp_artifacts_worker_v2.json",string),&v,.JSON,context.temp_allocator)==nil) do return
	bytes:=make([]byte,len(v.keyring_hex)/2,context.temp_allocator);if !testing.expect(t,hex_decode_into(bytes,v.keyring_hex)) do return
	kr,parsed:=keyring_parse(bytes,v.entries[0].job.owner);if !testing.expect(t,parsed) do return
	defer keyring_wipe(&kr)
	checked:=0
	for entry in v.entries {
		job:=entry.job
		long:=control_job_deadline_max_ms(job.operation,job.tool)==CONTROL_JOB_ARTIFACT_DEADLINE_MAX_MS
		// Deadline 6 s out: allowed only for artifact bundle-capable jobs.
		testing.expectf(t,control_job_verify(job,job.owner,job.resource,v.device_id,&kr,job.deadline_ms-6000)==long,"%s %s at -6s",job.operation,job.tool)
		if long {
			testing.expect(t,control_job_verify(job,job.owner,job.resource,v.device_id,&kr,job.deadline_ms-CONTROL_JOB_ARTIFACT_DEADLINE_MAX_MS))
			testing.expect(t,!control_job_verify(job,job.owner,job.resource,v.device_id,&kr,job.deadline_ms-CONTROL_JOB_ARTIFACT_DEADLINE_MAX_MS-1))
			checked+=1
		}
	}
	testing.expect(t,checked>0)
}
