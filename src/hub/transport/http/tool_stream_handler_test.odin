package http

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import agent_service "odin_test:hub/service/agent"
import project_service "odin_test:hub/service/project"
import ws "odin_test:lib/ws"

@(private = "file")
Tool_HTTP_Test :: struct { h: Agent_Handlers, sock: net.TCP_Socket, mu: sync.Mutex, cond: sync.Cond, attached, detached: int, token: string }
@(private = "file")
tool_http_test_run :: proc(raw: rawptr) {
    context=runtime.default_context()
    f:=(^Tool_HTTP_Test)(raw)
    // Model the router's socket ownership: handler joins writer before this close.
    defer net.close(f.sock)
    tool_stream_handler(&f.h,Request{query="ticket=tool_ticket",headers=[]contracts.HTTP_Header{{name="Sec-WebSocket-Key",value="dGhlIHNhbXBsZSBub25jZQ=="}}},f.sock)
}
@(private = "file")
tool_http_test_read :: proc(t: ^testing.T, socket: net.TCP_Socket, reader: ^ws.Frame_Reader) -> json.Object {
    _,body,got:=ws.read_frame(socket,reader,time.Second)
    testing.expect(t,got)
    if !got do return nil
    defer delete(body)
    value,_:=json.parse_string(body,.JSON,true,context.temp_allocator)
    obj,_:=value.(json.Object)
    return obj
}
@(test)
test_tool_stream_http_ticket_json_lifecycle_and_empty_baseline :: proc(t: ^testing.T) {
    pair,ok:=tool_http_pair(t)
    if !ok do return
    // The test owns the client; the handler thread owns and closes the Hub fd.
    defer net.close(pair.client)
    defer net.close(pair.listener)
    tickets:=new_user_ws_ticket_store();defer user_ws_ticket_store_free(&tickets)
    user_ws_ticket_store_put(&tickets,"tool_ticket",{kind=.User_Token,user_id="owner"},60)
    f: Tool_HTTP_Test
    repo:=iface.Agent_Repository{get_tool_instance=proc(ctx:rawptr,id:string)->(domain.Agent_Instance,bool,domain.Domain_Error){
        return domain.Agent_Instance{agent_instance_id=id,owner_user_id="owner" if id=="inst_a" else "foreign",bridge_id="brg_a",runtime_status="running"},true,{}
    }}
    content := iface.Content_Repository{get_conversation = proc(ctx: rawptr, id: string) -> (domain.Chat_Conversation, bool, domain.Domain_Error) {
        return domain.Chat_Conversation{conversation_id = id, owner_user_id = "owner", agent_instance_id = "inst_a"}, id == "chat_a", {}
    }}
    svc:=agent_service.Agent_Service{agents=&repo, content=&content}
    defer agent_service.tool_live_destroy(&svc.tool_live)
    svc.bridge_command_sink={ctx=&f,send_runtime_command=proc(raw:rawptr,c:project_service.Runtime_Command)->(bool,domain.Domain_Error){
        f:=(^Tool_HTTP_Test)(raw)
        value,_:=json.parse_string(c.body_json,.JSON,true,context.temp_allocator)
        root:=value.(json.Object)
        controls, _ := root["controls"].(json.Array)
        sync.mutex_lock(&f.mu);defer sync.mutex_unlock(&f.mu)
        for item in controls {
        obj := item.(json.Object)
        if agent_service.tool_live_text(obj,"type")=="tool_stream_attach" {
            f.attached+=1
            delete(f.token,runtime.heap_allocator())
            f.token=strings.clone(agent_service.tool_live_text(obj,"subscription_id"),runtime.heap_allocator())
        } else { f.detached+=1 }
        }
        sync.cond_signal(&f.cond)
        return true,{}
    }}
    f.h={agents=&svc,ws_tickets=&tickets};f.sock=pair.hub
    worker:=thread.create_and_start_with_data(&f,tool_http_test_run,self_cleanup=false)
    if worker==nil { net.close(pair.hub); return }
    defer {
        _=net.shutdown(pair.client,.Both)
        thread.join(worker);thread.destroy(worker)
        // Control worker can still use the fixture until service destruction.
    }
    response,got:=tool_http_response(pair.client,time.Second)
    testing.expect(t,got&&strings.contains(response,"101 Switching Protocols"));delete(response)
    conn:=ws.Connection{socket=pair.client,connected=true}
    reader:=ws.reader_make();defer ws.reader_destroy(&reader)
    testing.expect(t,ws.send_text(&conn,`{"type":"subscribe","instance_ids":["inst_a"]}`))
    legacy:=tool_http_test_read(t,pair.client,&reader)
    testing.expect_value(t,agent_service.tool_live_text(legacy,"code"),"upgrade_required")
    sync.mutex_lock(&f.mu)
    testing.expect_value(t,f.attached,0)
    sync.mutex_unlock(&f.mu)
    testing.expect(t,ws.send_text(&conn,`{"type":"subscribe","version":2,"views":[{"conversation_id":"chat_a","instance_ids":["inst_a"]}]}`))
    ack:=tool_http_test_read(t,pair.client,&reader)
    testing.expect_value(t,agent_service.tool_live_text(ack,"type"),"subscribed")
    sync.mutex_lock(&f.mu)
    for f.attached==0 { if !sync.cond_wait_with_timeout(&f.cond,&f.mu,time.Second) do break }
    token:=strings.clone(f.token);count:=f.attached
    sync.mutex_unlock(&f.mu)
    defer delete(token)
    testing.expect_value(t,count,1)
    frame:=fmt.tprintf(`{{"type":"tool_stream_state","epoch":"1000","subscription_id":"%s","run_count":0,"baseline":true,"snapshot":{{"instance_id":"inst_a","epoch":"1000","generation":1,"revision":0,"run_count":0,"active":[],"completed_since_last":[]}}}}`,token)
    testing.expect(t,agent_service.tool_live_apply_bridge(&svc,"brg_a",0,"1000",frame))
    baseline:=tool_http_test_read(t,pair.client,&reader)
    testing.expect_value(t,agent_service.tool_live_text(baseline,"type"),"state")
    snap:=baseline["snapshot"].(json.Object)
    testing.expect_value(t,len(snap["active"].(json.Array)),0)
    testing.expect_value(t,len(snap["completed_since_last"].(json.Array)),0)
    testing.expect(t,ws.send_text(&conn,`{"type":"subscribe","version":2,"views":[{"conversation_id":"chat_a","instance_ids":["inst_foreign"]}]}`))
    denied:=tool_http_test_read(t,pair.client,&reader)
    testing.expect_value(t,agent_service.tool_live_text(denied,"code"),"forbidden")
    testing.expect(t,ws.send_text(&conn,`{"type":"ping"}`))
    pong:=tool_http_test_read(t,pair.client,&reader)
    testing.expect_value(t,agent_service.tool_live_text(pong,"type"),"pong")
    testing.expect(t,ws.send_text(&conn,`{"type":"subscribe","version":2,"views":[]}`))
    ack=tool_http_test_read(t,pair.client,&reader)
    testing.expect_value(t,len(ack["instance_ids"].(json.Array)),0)
    sync.mutex_lock(&f.mu)
    for f.detached==0 { if !sync.cond_wait_with_timeout(&f.cond,&f.mu,time.Second) do break }
    count=f.detached
    sync.mutex_unlock(&f.mu)
    testing.expect_value(t,count,1)
    // Token is deliberately one-shot.
    _,reused:=user_ws_ticket_store_consume(&tickets,"tool_ticket")
    testing.expect(t,!reused)
    // Keep fixture-owned strings until the control worker has stopped.
    sync.mutex_lock(&svc.tool_live.mutex)
    svc.tool_live.stopped=true;sync.cond_signal(&svc.tool_live.control_cond)
    sync.mutex_unlock(&svc.tool_live.mutex)
    thread.join(svc.tool_live.control_worker)
    thread.destroy(svc.tool_live.control_worker);svc.tool_live.control_worker=nil
    delete(f.token,runtime.heap_allocator());f.token=""
}
@(test)
test_tool_stream_http_rejects_invalid_ticket_before_upgrade :: proc(t: ^testing.T) {
    pair,ok:=tool_http_pair(t);if !ok do return
    defer tool_http_pair_close(&pair)
    h:=Agent_Handlers{}
    tool_stream_handler(&h,Request{query="ticket=invalid"},pair.hub)
    response,got:=tool_http_response(pair.client,time.Second);defer delete(response)
    testing.expect(t,got&&strings.contains(response,"401 Unauthorized"))
}

@(private = "file")
Tool_HTTP_Pair :: struct {
	listener: net.TCP_Socket,
	client:   net.TCP_Socket,
	hub:      net.TCP_Socket,
}

@(private = "file")
tool_http_pair :: proc(t: ^testing.T) -> (Tool_HTTP_Pair, bool) {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil {
		testing.fail_now(t, "could not listen on loopback")
	}
	bound, bound_err := net.bound_endpoint(listener)
	if bound_err != nil {
		net.close(listener)
		testing.fail_now(t, "could not read bound endpoint")
	}
	client, dial_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if dial_err != nil {
		net.close(listener)
		testing.fail_now(t, "could not dial loopback")
	}
	hub, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil {
		net.close(listener)
		net.close(client)
		testing.fail_now(t, "could not accept on loopback")
	}
	return Tool_HTTP_Pair{listener = listener, client = client, hub = hub}, true
}

@(private = "file")
tool_http_pair_close :: proc(p: ^Tool_HTTP_Pair) {
	if int(p.hub) > 0 { net.close(p.hub); p.hub = net.TCP_Socket(0) }
	if int(p.client) > 0 { net.close(p.client); p.client = net.TCP_Socket(0) }
	if int(p.listener) > 0 { net.close(p.listener); p.listener = net.TCP_Socket(0) }
}

// Read raw response string until timeout
@(private = "file")
tool_http_response :: proc(sock: net.TCP_Socket, timeout: time.Duration) -> (string, bool) {
	_ = net.set_option(sock, .Receive_Timeout, timeout)
	buf: [4096]byte
	acc := make([dynamic]byte)
	defer delete(acc)
	for {
		n, err := net.recv_tcp(sock, buf[:])
		if err != nil || n <= 0 do break
		append(&acc, ..buf[:n])
		s := string(acc[:])
		if strings.contains(s, "\r\n\r\n") {
			return strings.clone(s), true
		}
	}
	if len(acc) > 0 {
		return strings.clone(string(acc[:])), true
	}
	return "", false
}


@(test)
test_tool_stream_http_failed_upstream_route_is_unavailable :: proc(t: ^testing.T) {
    pair,ok:=tool_http_pair(t); if !ok do return
    defer net.close(pair.client)
    defer net.close(pair.listener)
    tickets:=new_user_ws_ticket_store(); defer user_ws_ticket_store_free(&tickets)
    user_ws_ticket_store_put(&tickets,"tool_ticket",{kind=.User_Token,user_id="owner"},60)
    repo:=iface.Agent_Repository{get_tool_instance=proc(ctx:rawptr,id:string)->(domain.Agent_Instance,bool,domain.Domain_Error) {
        return domain.Agent_Instance{agent_instance_id=id,owner_user_id="owner",bridge_id="brg_offline",runtime_status="running"},true,{}
    }}
    content := iface.Content_Repository{get_conversation = proc(ctx: rawptr, id: string) -> (domain.Chat_Conversation, bool, domain.Domain_Error) {
        return domain.Chat_Conversation{conversation_id = id, owner_user_id = "owner", agent_instance_id = "inst_a"}, id == "chat_a", {}
    }}
    svc:=agent_service.Agent_Service{agents=&repo, content=&content}
    defer agent_service.tool_live_destroy(&svc.tool_live)
    svc.bridge_command_sink={send_runtime_command=proc(ctx:rawptr,c:project_service.Runtime_Command)->(bool,domain.Domain_Error) { return false,{} }}
    f:=Tool_HTTP_Test{h={agents=&svc,ws_tickets=&tickets},sock=pair.hub}
    worker:=thread.create_and_start_with_data(&f,tool_http_test_run,self_cleanup=false)
    testing.expect(t,worker!=nil)
    if worker==nil {net.close(pair.hub); return}
    defer {
        _=net.shutdown(pair.client,.Both)
        thread.join(worker); thread.destroy(worker)
    }
    response,got:=tool_http_response(pair.client,time.Second)
    testing.expect(t,got&&strings.contains(response,"101 Switching Protocols")); delete(response)
    conn:=ws.Connection{socket=pair.client,connected=true}
    reader:=ws.reader_make(); defer ws.reader_destroy(&reader)
    testing.expect(t,ws.send_text(&conn,`{"type":"subscribe","version":2,"views":[{"conversation_id":"chat_a","instance_ids":["inst_a"]}]}`))
    ack:=tool_http_test_read(t,pair.client,&reader)
    testing.expect_value(t,agent_service.tool_live_text(ack,"type"),"subscribed")
    unavailable:=tool_http_test_read(t,pair.client,&reader)
    testing.expect_value(t,agent_service.tool_live_text(unavailable,"type"),"unavailable")
    testing.expect_value(t,agent_service.tool_live_text(unavailable,"instance_id"),"inst_a")
    testing.expect_value(t,agent_service.tool_live_text(unavailable,"reason"),"bridge_offline")
    testing.expect(t,ws.send_text(&conn,`{"type":"ping"}`))
    pong:=tool_http_test_read(t,pair.client,&reader)
    testing.expect_value(t,agent_service.tool_live_text(pong,"type"),"pong")
}

@(test)
test_tool_stream_ticket_preserves_opaque_credential_and_proxy_kind :: proc(t: ^testing.T) {
    store := new_user_ws_ticket_store()
    defer user_ws_ticket_store_free(&store)
    user_ws_ticket_store_put(&store, "opaque_ticket", {kind = .User_Token, user_id = "owner", user_token_id = "utok_public"}, 60)
    auth, ok := user_ws_ticket_store_consume(&store, "opaque_ticket")
    testing.expect(t, ok)
    testing.expect_value(t, auth.user_token_id, "utok_public")
    user_ws_ticket_store_put(&store, "proxy_ticket", {kind = .Trusted_Proxy, user_id = "owner"}, 60)
    proxy, proxy_ok := user_ws_ticket_store_consume(&store, "proxy_ticket")
    testing.expect(t, proxy_ok)
    testing.expect_value(t, proxy.kind, contracts.Auth_Kind.Trusted_Proxy)
}
