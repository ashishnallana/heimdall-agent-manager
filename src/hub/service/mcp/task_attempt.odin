package mcp

import "core:encoding/json"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

control_task_attempt :: proc(s:^Control_Service,task:domain.Task,row:^json.Object)->string {
	attempts,err:=iface.taskchain_list_attempts_by_task(s.chains.repo,task.task_id,task.owner_user_id)
	if err.code!=.None do return "request_failed"
	latest:=domain.Task_Attempt{attempt_no=-1}
	for attempt in attempts do if attempt.attempt_no>latest.attempt_no do latest=attempt
	if latest.attempt_no<0 do return ""
	row["latest_attempt_no"]=json.Integer(latest.attempt_no)
	row["latest_attempt_holder_instance_id"]=json.String(latest.holder_instance_id)
	row["latest_attempt_outcome"]=json.String(latest.outcome)
	row["latest_attempt_started_at"]=json.String(latest.started_at)
	row["latest_attempt_ended_at"]=json.String(latest.ended_at)
	facets,ferr:=iface.taskchain_list_facets_by_task(s.chains.repo,task.task_id,task.owner_user_id)
	if ferr.code!=.None do return "request_failed"
	for facet in facets do if facet.attempt_no==latest.attempt_no && facet.kind=="handoff" {
		value,perr:=json.parse_string(facet.body_json,parse_integers=true,allocator=context.temp_allocator)
		obj,typed:=value.(json.Object)
		if perr!=nil || !typed do return "request_failed"
		if summary,typed:=obj["summary"].(json.String);typed {
			if len(summary)>256*1024 {row["latest_attempt_summary_error"]=json.String("summary_too_large")} else {row["latest_attempt_summary"]=summary}
		}
	}
	return ""
}
