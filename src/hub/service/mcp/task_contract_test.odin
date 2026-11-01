#+feature dynamic-literals
package mcp

import "core:encoding/json"
import "core:strings"
import "core:testing"

@(test)
test_task_detail_result_binds_paging_provenance_and_native_metadata :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	task:=json.Object{"task_id"=json.String("task_a"),"chain_id"=json.String("chain_a"),"title"=json.String("encrypted title"),"hold_reason"=json.String("encrypted hold"),"blocked_since_ms"=json.Integer(123),"hold_since_ms"=json.Integer(456),"checkpoint_requested"=json.Boolean(true),"latest_attempt_no"=json.Integer(2),"latest_attempt_summary"=json.String("encrypted summary"),"allowed_actions"=json.Array{json.String("release")}}
	comment:=json.Object{"comment_id"=json.String("cmt_a"),"chain_id"=json.String("chain_a"),"task_id"=json.String("task_a"),"body"=json.String("encrypted body"),"author_kind"=json.String("delegated_user"),"delegated_client_id"=json.String("client_a"),"delegated_grant_id"=json.String("grant_a")}
	data:=Control_Data{tasks=[]json.Object{task},comments=[]json.Object{comment},comments_next_cursor="bound_position"}
	encoded,_:=json.marshal(data,allocator=context.temp_allocator)
	value,_:=json.parse_string(string(encoded),parse_integers=true,allocator=context.temp_allocator)
	root,_:=value.(json.Object);tasks,_:=root["tasks"].(json.Array);row,_:=tasks[0].(json.Object)
	row["title"]=json.String("readable title");row["hold_reason"]=json.String("readable hold");row["latest_attempt_summary"]=json.String("readable summary")
	comments,_:=root["comments"].(json.Array);c,_:=comments[0].(json.Object);c["body"]=json.String("readable body")
	valid,_:=json.marshal(root,allocator=context.temp_allocator)
	testing.expect(t,control_result_ok(data,string(valid)))
	for key in ([]string{"blocked_since_ms","hold_since_ms","checkpoint_requested","latest_attempt_no","allowed_actions"}) {
		original:=row[key];row[key]=json.String("forged metadata")
		bad,_:=json.marshal(root,allocator=context.temp_allocator)
		testing.expectf(t,!control_result_ok(data,string(bad)),"bind %s",key)
		row[key]=original
	}
	c["delegated_grant_id"]=json.String("grant_foreign")
	bad,_:=json.marshal(root,allocator=context.temp_allocator)
	testing.expect(t,!control_result_ok(data,string(bad)))
	c["delegated_grant_id"]=json.String("grant_a")
	root["comments_next_cursor"]=json.String("foreign_position")
	bad,_=json.marshal(root,allocator=context.temp_allocator)
	testing.expect(t,!control_result_ok(data,string(bad)))
}

@(test)
test_task_operation_codes_do_not_persist_native_private_prose :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	reasons:=control_outcome_codes([]string{"task is held (private reason); release it with task release","work lease lease_secret is live (holder inst_private)","private unknown blocker"},false)
	actions:=control_outcome_codes([]string{"state: ready → in_progress","dispatched: work lease secret to private instance","blocked: private reason"},true)
	encoded,_:=json.marshal(struct {reasons,actions:[]string}{reasons,actions},allocator=context.temp_allocator)
	testing.expect(t,len(reasons)==3 && reasons[0]=="held" && reasons[1]=="lease_active" && reasons[2]=="native_blocker")
	testing.expect(t,len(actions)==3 && actions[0]=="state_changed" && actions[1]=="lease_dispatched" && actions[2]=="block_changed")
	testing.expect(t,!strings.contains(string(encoded),"private") && !strings.contains(string(encoded),"secret"))
}
