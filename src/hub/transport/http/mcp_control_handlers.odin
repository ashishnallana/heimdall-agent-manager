#+feature dynamic-literals
package http

import "core:crypto"
import "core:encoding/json"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import auth "odin_test:hub/service/auth"
import events "odin_test:hub/service/events"
import mcp "odin_test:hub/service/mcp"
import tc "odin_test:hub/service/taskchain"
import vault "odin_test:lib/vault"

MCP_Control_Handlers :: struct {
	delegation:^MCP_Delegation_Handlers,
	control:mcp.Control_Service,
	bus:^events.User_Event_Bus,
	workers:mcp.Worker_Broker,
	registrations:mcp.Worker_Registrations,
	requests:mcp.Request_Registry,
	create_ctx:rawptr,
	create:mcp.Control_Create_Proc,
	// Optional approved enrolled-bridge transport. It receives no client token.
	bridge_ctx:rawptr,
	bridge_transform:proc(ctx:rawptr,job:vault.Control_Job)->(string,bool),
}
mcp_control_register_routes :: proc(r:^Router,h:^MCP_Control_Handlers) {
	router_add(r,"ANY",MCP_PATH,h,mcp_control_handler)
	router_add(r,"GET",MCP_OAUTH+"/jobs",h,mcp_worker_handler)
	router_add(r,"POST",MCP_OAUTH+"/jobs",h,mcp_worker_handler)
	router_add(r,"POST",MCP_OAUTH+"/worker",h,mcp_worker_registration_handler)
}
mcp_parse_object :: proc(text:string)->(json.Object,bool) {
	if !utf8.valid_string(text) do return nil,false
	parser:=json.make_parser_from_string(text,.JSON,true,context.temp_allocator)
	value,err:=json.parse_value(&parser)
	obj,ok:=value.(json.Object)
	return obj,err==nil && ok && parser.curr_token.kind==.EOF
}
mcp_rpc_error :: proc(id:json.Value,code:int,message:string)->Response {
	return mcp_json(struct {jsonrpc:string,id:json.Value,error:struct {code:int,message:string}}{"2.0",id,{code,message}})
}
mcp_rpc_result :: proc(id,result:json.Value)->Response {
	return mcp_json(struct {jsonrpc:string,id:json.Value,result:json.Value}{"2.0",id,result})
}
mcp_id_ok :: proc(id:json.Value)->bool {
	#partial switch v in id {
	case json.String:return len(v)>0 && len(v)<=128
	case json.Integer:return v>=-9007199254740991 && v<=9007199254740991
	}
	return false
}
mcp_arguments :: proc(name:string,value:json.Value)->(mcp.Control_Arguments,bool) {
	args:mcp.Control_Arguments
	obj,ok:=value.(json.Object)
	if value==nil {obj=make(json.Object,context.temp_allocator);ok=true}
	if !ok do return {},false
	for key,v in obj {
		switch key {
		case "chain_id":
			s,typed:=v.(json.String);if !typed || (name!="chains.get" && name!="events.wait") || !mcp.control_id_ok(string(s)) do return {},false
			args.chain_id=string(s)
		case "title":
			s,typed:=v.(json.String);if !typed || name!="chains.create" || len(s)<1 || len(s)>500 || strings.trim_space(string(s))=="" do return {},false
			args.title=string(s)
		case "description":
			s,typed:=v.(json.String);if !typed || name!="chains.create" || len(s)>20000 do return {},false
			args.description=string(s)
		case "cursor":
			s,typed:=v.(json.String);if !typed || name!="chains.list" || len(s)>20 do return {},false
			args.cursor=string(s)
		case "limit":
			n,typed:=v.(json.Integer);if !typed || name!="chains.list" || n<1 || n>100 do return {},false
			args.limit=int(n)
		case "timeout_ms":
			n,typed:=v.(json.Integer);if !typed || name!="events.wait" || n<1 || n>25000 do return {},false
			args.timeout_ms=int(n)
		case:return {},false
		}
	}
	switch name {
	case "chains.get","events.wait":return args,args.chain_id!=""
	case "chains.create":return args,args.title!=""
	case "chains.list":return args,true
	}
	return {},false
}
mcp_tool_result :: proc(id:json.Value,text:string,is_error:bool)->Response {
	resp:=mcp_json(struct {jsonrpc:string,id:json.Value,result:struct {content:[]struct {type,text:string},isError:bool}}{"2.0",id,{[]struct {type,text:string}{{"text",text}},is_error}})
	resp.sensitive=true
	return resp
}
mcp_unauthorized :: proc(h:^MCP_Control_Handlers)->Response {
	resp:=mcp_oauth_error("invalid_token",401)
	headers:=make([]contracts.HTTP_Header,len(resp.headers)+1,context.temp_allocator);copy(headers,resp.headers)
	headers[len(resp.headers)]={"WWW-Authenticate",mcp_join("Bearer resource_metadata=\"",h.delegation.origin,"/.well-known/oauth-protected-resource/api/v1/mcp\", scope=\"",mcp.DELEGATION_SCOPE,"\"")}
	resp.headers=headers;return resp
}
mcp_control_handler :: proc(ctx:rawptr,req:Request)->(response:Response) {
	h:=(^MCP_Control_Handlers)(ctx)
	started:=time.tick_now()
	defer response.write_timeout_ms=max(1,min(5000,int((30*time.Second-time.tick_since(started))/time.Millisecond)))
	if origin:=header_value(req.headers,"Origin");origin!="" && origin!=h.delegation.origin do return mcp_oauth_error("access_denied",403)
	bearer:=header_value(req.headers,"Authorization")
	if !strings.has_prefix(bearer,"Bearer ") || len(bearer)>16384 do return mcp_unauthorized(h)
	raw:=strings.trim_prefix(bearer,"Bearer ")
	view,valid:=mcp.access_view(h.delegation.service,h.delegation.grant_directory,raw)
	if !valid do return mcp_unauthorized(h)
	if req.method!="POST" do return plain_response(405,"method not allowed",{"Allow","POST"})
	if len(req.body)>32768 || !strings.has_prefix(header_value(req.headers,"Content-Type"),"application/json") do return mcp_oauth_error("invalid_request")
	defer if req.body!="" do crypto.zero_explicit(raw_data(req.body),len(req.body))
	rpc,parsed:=mcp_parse_object(req.body)
	defer vault.control_wipe_value(rpc)
	version,vok:=rpc["jsonrpc"].(json.String)
	method,mok:=rpc["method"].(json.String)
	if !parsed || !vok || string(version)!="2.0" || !mok do return mcp_rpc_error(nil,-32600,"Invalid Request")
	id,has_id:=rpc["id"]
	if has_id && !mcp_id_ok(id) do return mcp_rpc_error(nil,-32600,"Invalid request id")
	params,_:=rpc["params"].(json.Object)
	key:=auth.sha256_hex(raw)
	if !has_id {
		if string(method)=="notifications/cancelled" {
			cancel_id:=params["requestId"]
			if mcp_id_ok(cancel_id) {encoded,_:=json.marshal(cancel_id,allocator=context.temp_allocator);mcp.request_cancel(&h.requests,key,string(encoded))}
		}
		return mcp_json(struct {}{},202)
	}
	switch string(method) {
	case "initialize":
		requested,ok:=params["protocolVersion"].(json.String)
		if !ok do return mcp_rpc_error(id,-32602,"Invalid initialization")
		protocol:="2025-11-25"
		if requested=="2025-03-26" || requested=="2025-06-18" || requested=="2024-11-05" do protocol=string(requested)
		return mcp_rpc_result(id,json.Object{"protocolVersion"=json.String(protocol),"capabilities"=json.Object{"tools"=json.Object{}},"serverInfo"=json.Object{"name"=json.String("heimdall-control"),"version"=json.String("0.1.0")},"instructions"=json.String("Act as the connected user. Only four chain tools are available; no agent/lease/review authority. Poll events.wait while actively monitoring with a stopping condition and budget. No background wake or durable replay. Never automatically retry an ambiguous chains.create result. Default decryption requires an approved unlocked device; hosted decryption requires explicit connection consent.")})
	case "ping":return mcp_rpc_result(id,json.Object{})
	case "tools/list":
		tools,err:=json.parse_string(#load("mcp_tools.json",string),parse_integers=true,allocator=context.temp_allocator)
		if err!=nil do return mcp_rpc_error(id,-32603,"Tool metadata unavailable")
		return mcp_rpc_result(id,json.Object{"tools"=tools})
	case "tools/call":
	case:return mcp_rpc_error(id,-32601,"Method not found")
	}
	name,nok:=params["name"].(json.String)
	args,args_ok:=mcp_arguments(string(name),params["arguments"])
	if !nok || !args_ok do return mcp_rpc_error(id,-32602,"Unknown tool or invalid arguments")
	if !mcp.scope_allows_tool(view.scope,string(name)) do return mcp_tool_result(id,"scope_missing",true)
	encoded_id,_:=json.marshal(id,allocator=context.temp_allocator)
	handle,admitted:=mcp.request_begin(&h.requests,key,string(encoded_id))
	if !admitted do return mcp_tool_result(id,"busy: request is already active or capacity is exhausted",true)
	defer mcp.request_end(&h.requests,handle)
	data:mcp.Control_Data
	wait_changed:=false
	if string(name)=="events.wait" {
		// Validate ownership before attaching, attach before the baseline read.
		_,owned,err:=tc.get_chain_for_read(h.control.chains,mcp.control_auth(view.owner),domain.Task_Chain_ID(args.chain_id))
		if !owned || err.code!=.None do return mcp_tool_result(id,"not_found",true)
		hint,attached:=events.poll_attach(h.bus,view.owner,args.chain_id)
		if !attached do return mcp_tool_result(id,"temporarily_unavailable",true)
		defer events.poll_detach(h.bus,hint)
		wait:=args.timeout_ms;if wait==0 do wait=20000
		wait_started:=time.tick_now()
		for events.poll_revision(h.bus,hint)==0 && time.tick_since(wait_started)<time.Duration(wait)*time.Millisecond && time.tick_since(started)<25*time.Second {
			if mcp.request_cancelled(&h.requests,handle) do return mcp_tool_result(id,"cancelled",true)
			time.sleep(25*time.Millisecond)
		}
		wait_changed=events.poll_revision(h.bus,hint)>0
	}
	if mcp.request_cancelled(&h.requests,handle) do return mcp_tool_result(id,"cancelled",true)
	// A fresh read and credential check after waiting, never a pre-wait cache.
	fresh,fresh_ok:=mcp.access_view(h.delegation.service,h.delegation.grant_directory,raw)
	if !fresh_ok do return mcp_unauthorized(h)
	view=fresh
	op:=mcp.Control_Transform{seal=string(name)=="chains.create",title=args.title,description=args.description}
	if !op.seal {
		code:string
		data,code=mcp.control_read(&h.control,view.owner,string(name),args)
		if code!="" do return mcp_tool_result(id,code,true)
		op.data=data
		if !mcp.control_payload_ok(data) do return mcp_tool_result(id,"result_too_large",true)
	}
	result:mcp.Delegation_Result
	if view.mode=="hosted" {
		result=mcp.hosted_with_access(h.delegation.service,h.delegation.grant_directory,raw,view.client,mcp.control_hosted_transform,&op)
	} else {
		result=mcp_device_transform(h,view,&op,handle,started)
	}
	defer if result.response!="" do crypto.zero_explicit(raw_data(result.response),len(result.response))
	if result.error=="invalid_token" do return mcp_unauthorized(h)
	if result.error!="" {
		if _,still_valid:=mcp.access_view(h.delegation.service,h.delegation.grant_directory,raw);!still_valid do return mcp_unauthorized(h)
		return mcp_tool_result(id,result.error,true)
	}
	if time.tick_since(started)>=30*time.Second || mcp.request_cancelled(&h.requests,handle) do return mcp_tool_result(id,"cancelled",true)
	final,final_ok:=mcp.access_view(h.delegation.service,h.delegation.grant_directory,raw)
	if !final_ok do return mcp_unauthorized(h)
	if !mcp.access_same(view,final) do return mcp_tool_result(id,"decryption_unavailable",true)
	if op.seal {
		title,description,sealed_ok:=mcp.control_sealed_ok(view,result.response)
		if !sealed_ok do return mcp_tool_result(id,"decryption_unavailable",true)
		// No remote retry: this single owner-authorized write may have committed
		// even if the client disconnects before receiving its result.
		chain_id,code:=mcp.control_create(h.delegation.service,h.delegation.grant_directory,raw,view,title,description,h.create,h.create_ctx)
		if code=="invalid_token" do return mcp_unauthorized(h)
		if code!="" do return mcp_tool_result(id,code,true)
		encoded,_:=json.marshal(struct {chain_id:string,title,description:string,status:string}{chain_id,args.title,args.description,"active"},allocator=context.temp_allocator)
		defer if len(encoded)>0 do crypto.zero_explicit(raw_data(encoded),len(encoded))
		return mcp_tool_result(id,string(encoded),false)
	}
	if !mcp.control_result_ok(data,result.response) do return mcp_tool_result(id,"decryption_unavailable",true)
	if string(name)=="events.wait" {
		state,err:=json.parse_string(result.response,parse_integers=true,allocator=context.temp_allocator)
		defer vault.control_wipe_value(state)
		if err!=nil do return mcp_tool_result(id,"decryption_unavailable",true)
		status:="timeout"
		hint:json.Value
		if wait_changed {status="changed";hint=json.Object{"resource"=json.String("task_chain"),"resource_id"=json.String(args.chain_id),"change"=json.String("refetch")}}
		encoded,eerr:=json.marshal(struct {status:string,event:json.Value,refresh_required:bool,state:json.Value}{status,hint,true,state},allocator=context.temp_allocator)
		defer if len(encoded)>0 do crypto.zero_explicit(raw_data(encoded),len(encoded))
		if eerr!=nil do return mcp_tool_result(id,"request_failed",true)
		return mcp_tool_result(id,string(encoded),false)
	}
	return mcp_tool_result(id,result.response,false)
}
