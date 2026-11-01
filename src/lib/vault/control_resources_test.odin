#+feature dynamic-literals
package vault

import "core:testing"
import "core:encoding/json"
import "core:strings"

@(test)
test_resource_browser_native_jobs_encryption_owner_and_nested_projection :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	v:struct {now_ms:i64,keyring_hex,device_id,bridge_device_id:string,entries:[]struct {job:Control_Job,result:string}}
	if !testing.expect(t,json.unmarshal_string(#load("../../../tests/fixtures/mcp_resources_worker_v2.json",string),&v,.JSON,context.temp_allocator)==nil) do return
	bytes:=make([]byte,len(v.keyring_hex)/2,context.temp_allocator);if !testing.expect(t,hex_decode_into(bytes,v.keyring_hex)) do return
	kr,parsed:=keyring_parse(bytes,v.entries[0].job.owner);if !testing.expect(t,parsed) do return
	defer keyring_wipe(&kr)
	for entry in v.entries {
		job:=entry.job
		for device in ([]string{v.device_id,v.bridge_device_id}) do testing.expect(t,control_job_verify(job,job.owner,job.resource,device,&kr,v.now_ms))
		out,ok:=control_job_transform(job,&kr);if !testing.expect(t,ok) do continue
		if job.operation=="seal_resource" {
			value,_:=json.parse_string(out,parse_integers=true,allocator=context.temp_allocator);obj,_:=value.(json.Object)
			input,_:=json.parse_string(job.payload,parse_integers=true,allocator=context.temp_allocator);original,_:=input.(json.Object)
			for key,text in obj {token,typed:=text.(json.String);plain,status:=open(string(token),&kr,context.temp_allocator);testing.expect(t,typed && status==.Ok && plain==string(original[key].(json.String)))}
		} else {
			testing.expect(t,!strings.contains(out,"vault:v2:") && !strings.contains(out,"never expose"))
			if job.tool=="issues.get" do testing.expect(t,strings.contains(out,"bound_comments") && strings.contains(out,"worker secret title"))
			if job.tool=="projects.get" do testing.expect(t,strings.contains(out,"/native/path") && strings.contains(out,"worker secret title"))
			if job.tool=="issues.list" {data:Control_Data;json.unmarshal_string(out,&data,.JSON,context.temp_allocator);text,_:=data.records[0]["description"].(json.String);testing.expect_value(t,len(text),512)}
		}
	}
	for scope in ([]string{"mcp:chains","mcp:chains mcp:memories:read","mcp:chains mcp:projects:write"}) do testing.expect(t,!control_job_scope_ok(scope,"memories.create","seal_resource"))
	testing.expect(t,!control_job_scope_ok("mcp:chains mcp:memories:write","memories.approve","seal_resource"))
	_,sealed:=control_seal_resource_fields(&kr,"projects.create",json.Object{"default_path"=json.String("/not prose")});testing.expect(t,!sealed)
	_,sealed=control_seal_resource_fields(&kr,"memories.create",json.Object{"body"=json.String(strings.repeat("x",65537,context.temp_allocator))});testing.expect(t,!sealed)
}
