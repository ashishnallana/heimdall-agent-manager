package http

import "core:testing"
import "core:encoding/json"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import content_service "odin_test:hub/service/content"

@(test)
test_agent_artifact_attribution_uses_authenticated_current_task :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	f:=wire_setup(t,"artifact-task");defer wire_teardown(f)
	impl:sqlite.Content_Repo_SQLite;repo:=sqlite.new_content_repository(&impl,&f.conn)
	svc:=content_service.new_content_service(&repo,&f.ag_repo,&f.br_repo,nil,&f.tc_repo,&f.clock,&f.ids);f.ah.content=&svc
	_,saved,_:=iface.agent_save(&f.ag_repo,domain.Agent{agent_id="agt_wire_tb2",owner_user_id=f.owner,name="Worker",slug="artifact-worker"});testing.expect(t,saved)
	_,saved,_=iface.taskchain_save_task(&f.tc_repo,{task_id="task_artifact_current",chain_id=f.chain_id,owner_user_id=f.owner,title="Current task",state=.In_Progress});testing.expect(t,saved)
	testing.expect(t,sqlite.exec(&f.conn,"UPDATE agent_instances SET current_task_id='task_artifact_current' WHERE agent_instance_id='inst_wire_tb2';"))
	body:=strings.clone(`{"agent_instance_id":"inst_wire_tb2","params":{"name":"Synthetic result","kind":"markdown","content":"Synthetic result","task_id":"task_foreign","chain_id":"chain_foreign","agent_id":"agt_foreign"}}`,context.temp_allocator)
	response:=agent_action_artifact_create_handler(&f.ah,wire_agent_request(f,"artifact/create",body))
	if !testing.expect_value(t,response.status,201) do return
	wire:struct {data:struct {artifact_id,task_id,chain_id,agent_id,agent_instance_id:string}}
	testing.expect(t,json.unmarshal_string(response.body,&wire,.JSON,context.temp_allocator)==nil)
	testing.expect_value(t,wire.data.task_id,"task_artifact_current")
	testing.expect_value(t,wire.data.chain_id,string(f.chain_id))
	testing.expect_value(t,wire.data.agent_id,"agt_wire_tb2")
	testing.expect_value(t,wire.data.agent_instance_id,f.instance_id)
	row,found,_:=iface.content_get_artifact(&repo,wire.data.artifact_id);testing.expect(t,found && row.task_id=="task_artifact_current")
}
