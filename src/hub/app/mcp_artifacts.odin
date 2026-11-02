package app

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import mcp "odin_test:hub/service/mcp"
import content "odin_test:hub/service/content"

mcp_resource_artifact :: proc(g:^App_Graph,view:mcp.Access_View,c:mcp.Resource_Command)->(string,string,string) {
	context.allocator=context.temp_allocator
	a:=c.args;auth:=mcp.control_auth(view.owner)
	row:domain.Artifact;ok:bool;err:domain.Domain_Error
	switch c.tool {
	case "artifacts.create":
		if a.task_id!="" && a.chain_id=="" {task,found,e:=iface.taskchain_get_task(&g.repos.taskchains,domain.Task_ID(a.task_id));if !found || e.code!=.None || string(task.owner_user_id)!=view.owner do return "","","not_found";a.chain_id=string(task.chain_id)}
		ext:="txt";if a.content_type=="text/markdown" do ext="md";if a.content_type=="application/json" do ext="json"
		row,ok,err=content.create_artifact(&g.content,auth,{kind="file",name=mcp.resource_text(c.sealed,"name"),description=mcp.resource_text(c.sealed,"description"),content=mcp.resource_text(c.sealed,"content"),content_type=a.content_type,mime=a.content_type,ext=ext,project_id=domain.Project_ID(a.project_id),chain_id=a.chain_id,task_id=a.task_id,agent_id=a.agent_id,agent_instance_id=a.agent_instance_id})
	case "artifacts.update":row,ok,err=content.update_artifact_bounded(&g.content,auth,a.id,mcp.resource_text(c.sealed,"name"),mcp.resource_text(c.sealed,"description"))
	case "artifacts.delete":ok,err=content.delete_artifact_bounded(&g.content,auth,a.id);if ok && err.code==.None do return a.id,"deleted",""
	}
	if !ok || err.code!=.None do return "","",mcp_resource_error(err)
	return row.artifact_id,"available",""
}
