#+feature dynamic-literals
package mcp

import "core:testing"
import "core:encoding/json"
import domain "odin_test:hub/domain"

@(test)
test_runtime_revisions_bind_lifecycle_and_permissions_but_not_heartbeats :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	i:=domain.Agent_Instance{agent_instance_id="inst_a",agent_id="agt_a",bridge_id="brg_a",provider="codex",provider_profile="codex",model="model_a",runtime_status="stopped",run_count=1,agent_permission_mode="ask"}
	revision:=runtime_revision(i)
	for field in 0..<7 {
		changed:=i
		switch field {case 0:changed.configuration_revision+=1;case 1:changed.run_count+=1;case 2:changed.runtime_status="running";case 3:changed.permission_mode="yolo";case 4:changed.launch_epoch="new_epoch";case 5:changed.current_task_id="task_a";case 6:changed.agent_permission_mode="yolo"}
		testing.expect(t,runtime_revision(changed)!=revision)
	}
	i.updated_at="heartbeat";i.last_seen_at="heartbeat";i.last_applied_seq+=1
	testing.expect_value(t,runtime_revision(i),revision)
	a:=Runtime_Arguments{request_id="retry",agent_instance_id="inst_a",expected_revision=revision}
	digest:=runtime_write_digest(a);a.operation_tool="polling argument"
	testing.expect_value(t,runtime_write_digest(a),digest)
	a.expected_revision="different";testing.expect(t,runtime_write_digest(a)!=digest)
	for tool in ([]string{"instances.create","instances.start","instances.stop","instances.reconfigure"}) {
		testing.expect(t,scope_allows_tool("mcp:chains mcp:instances:control",tool))
		testing.expect(t,!scope_allows_tool("mcp:chains mcp:instances:read",tool))
	}
	testing.expect(t,scope_allows_tool("mcp:chains mcp:instances:read","instances.operations"))
	testing.expect(t,!scope_allows_tool("mcp:chains mcp:instances:control","instances.operations"))
}

@(test)
test_runtime_device_read_cannot_forge_lifecycle_revision :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	row:=json.Object{"agent_instance_id"=json.String("inst_a"),"display_name"=json.String("sealed label"),"revision"=json.String("original_revision"),"configuration_revision"=json.Integer(1)}
	data:=Control_Data{records_kind="instance",records=[]json.Object{row}}
	encoded,_:=json.marshal(data,allocator=context.temp_allocator)
	value,_:=json.parse_string(string(encoded),parse_integers=true,allocator=context.temp_allocator)
	root,_:=value.(json.Object);rows,_:=root["records"].(json.Array);actual,_:=rows[0].(json.Object)
	actual["display_name"]=json.String("Readable label")
	valid,_:=json.marshal(root,allocator=context.temp_allocator);testing.expect(t,control_result_ok(data,string(valid)))
	actual["revision"]=json.String("forged_revision")
	bad,_:=json.marshal(root,allocator=context.temp_allocator);testing.expect(t,!control_result_ok(data,string(bad)))
}
