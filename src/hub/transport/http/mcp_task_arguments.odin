package http

import "core:encoding/json"
import "core:strings"
import "core:crypto"
import mcp "odin_test:hub/service/mcp"
import vault "odin_test:lib/vault"

mcp_task_write_arguments :: proc(tool:string,value:json.Value)->(mcp.Control_Arguments,bool) {
	obj,typed:=value.(json.Object)
	if !typed do return {},false
	allowed:[]string
	switch tool {
	case "tasks.create":allowed=[]string{"chain_id","request_id","title","description","goal","acceptance","assignee_agent_id","bridge_id","reviewers","depends_on","requires_user_approval","priority"}
	case "tasks.update":allowed=[]string{"chain_id","task_id","request_id","expected_revision","title","description","goal","acceptance","assignee_agent_id","bridge_id","reviewers","depends_on","requires_user_approval","priority"}
	case "tasks.control":allowed=[]string{"chain_id","task_id","request_id","expected_revision","action","reason"}
	case "chains.configure":allowed=[]string{"chain_id","request_id","expected_revision","action","agent_id","bridge_id","provider","model","provider_profile","roles","capacity"}
	case:return {},false
	}
	mask:u64
	for key,v in obj {
		known:=false
		for k in allowed do if key==k do known=true
		if !known do return {},false
		for k,i in mcp.TASK_TOOL_KEYS do if key==k do mask|=u64(1)<<u64(i)
		switch key {
		case "capacity":n,ok:=v.(json.Integer);if !ok || n<1 || n>8 do return {},false
		case "requires_user_approval":if _,ok:=v.(json.Boolean);!ok do return {},false
		case "acceptance","reviewers","depends_on","roles":
			items,ok:=v.(json.Array)
			if !ok || len(items)>100 || key=="acceptance" && (len(items)<1 || len(items)>20) do return {},false
			for item in items {
				s,is_text:=item.(json.String);if !is_text || len(s)<1 do return {},false
				if key=="acceptance" {if len(s)>200 || strings.trim_space(string(s))=="" do return {},false} else if len(s)>256 || !vault.valid_id_value(string(s)) do return {},false
			}
		case:
			s,ok:=v.(json.String);if !ok do return {},false
			limit:=256
			switch key {case "title":limit=500;case "goal":limit=2000;case "description","reason":limit=20000}
			if len(s)>limit do return {},false
			if key=="title" || key=="goal" || key=="reason" {if strings.trim_space(string(s))=="" do return {},false}
		}
	}
	encoded,err:=json.marshal(obj,allocator=context.temp_allocator)
	defer if len(encoded)>0 do crypto.zero_explicit(raw_data(encoded),len(encoded))
	if err!=nil do return {},false
	args:mcp.Task_Tool_Arguments
	if json.unmarshal(encoded,&args,.JSON,context.temp_allocator)!=nil do return {},false
	accepted:=false
	defer if !accepted {
		for text in ([]string{args.title,args.description,args.goal,args.reason}) do if text!="" do crypto.zero_explicit(raw_data(text),len(text))
		for text in args.acceptance do if text!="" do crypto.zero_explicit(raw_data(text),len(text))
	}
	args.present=mask
	if mcp.task_argument_present(args,"priority") && args.priority!="p0" && args.priority!="p1" && args.priority!="p2" do return {},false
	if args.request_id=="" || !vault.valid_id_value(args.request_id) do return {},false
	if !mcp.control_id_ok(args.chain_id) do return {},false
	if tool=="tasks.update" || tool=="tasks.control" {if len(args.task_id)<=5 || !strings.has_prefix(args.task_id,"task_") || !vault.valid_id_value(args.task_id) do return {},false}
	if tool!="tasks.create" && (len(args.expected_revision)!=64 || !vault.is_lower_hex(args.expected_revision)) do return {},false
	if tool=="tasks.create" && (args.title=="" || args.goal=="" || len(args.acceptance)<1) do return {},false
	if tool=="tasks.update" && len(obj)<5 do return {},false
	if tool=="tasks.control" {
		valid:=false
		for action in ([]string{"publish","cancel","reopen","answer","hold","release","recheck"}) do if action==args.action do valid=true
		if !valid || (args.action=="hold" || args.action=="cancel" || args.action=="answer") && args.reason=="" do return {},false
	}
	if tool=="chains.configure" {
		if args.action!="publish" && args.action!="fleet" do return {},false
		if args.action=="fleet" && (args.agent_id=="" || args.bridge_id=="" || args.provider=="" || args.model=="") do return {},false
		if args.action=="publish" && len(obj)!=4 do return {},false
		if mcp.task_argument_present(args,"roles") && len(args.roles)==0 do return {},false
	}
	accepted=true
	return {task_write=args},true
}
