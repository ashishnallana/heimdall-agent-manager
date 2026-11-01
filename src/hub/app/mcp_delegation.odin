package app

import "base:runtime"
import "core:crypto"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:fmt"
import sqlite "odin_test:hub/repository/sqlite"
import iface "odin_test:hub/repository/iface"
import domain "odin_test:hub/domain"
import mcp "odin_test:hub/service/mcp"
import auth_service "odin_test:hub/service/auth"
import vd "odin_test:hub/service/vault_directory"
import vault "odin_test:lib/vault"
import tc "odin_test:hub/service/taskchain"

configure_mcp_delegation :: proc(graph: ^App_Graph) -> (bool, string) {
	data, err := os.read_entire_file(graph.config.mcp_oauth_key_file, context.temp_allocator)
	if err != nil do return false, "cannot read MCP OAuth key file"
	defer crypto.zero_explicit(raw_data(data), len(data))
	if len(data)>8192 do return false, "MCP OAuth key file exceeds size limit"
	file: struct {keys: []struct {id,key_hex:string}}
	defer {
		for &entry in file.keys do if entry.key_hex!="" do crypto.zero_explicit(raw_data(entry.key_hex),len(entry.key_hex))
	}
	if json.unmarshal(data,&file,.JSON,context.temp_allocator)!=nil || len(file.keys)<1 || len(file.keys)>4 do return false,"MCP OAuth key file requires one to four keys"
	keys:=make([]mcp.Envelope_Key,len(file.keys),runtime.heap_allocator())
	valid:=false
	defer if !valid {
		for &key in keys {delete(key.id,runtime.heap_allocator());crypto.zero_explicit(&key.bytes,size_of(key.bytes))}
		delete(keys,runtime.heap_allocator())
	}
	for entry,i in file.keys {
		if !mcp.envelope_key_id_ok(entry.id) || !vault.is_lower_hex(entry.key_hex) || !vault.hex_decode_into(keys[i].bytes[:],entry.key_hex) do return false,"invalid MCP OAuth envelope key"
		nonzero:=false
		for b in keys[i].bytes do if b!=0 do nonzero=true
		if !nonzero do return false,"invalid MCP OAuth envelope key"
		for j in 0..<i do if keys[j].id==entry.id do return false,"duplicate MCP OAuth envelope key id"
		keys[i].id=strings.clone(entry.id,runtime.heap_allocator())
	}
	repo,rerr:=sqlite.open_mcp_repository(&graph.mcp_repository_impl,graph.config.database_path)
	if rerr.code!=.None do return false,"cannot open MCP OAuth persistence"
	graph.mcp_repository=repo
	// Authority reads inside the MCP write transaction MUST use that same
	// connection, not the shared Hub connection (which may be waiting to write).
	graph.mcp_vault_repo=sqlite.new_vault_directory_repository(&graph.mcp_vault_repo_impl,&graph.mcp_repository_impl.conn)
	graph.mcp_vault_view=vd.Service{repo=&graph.mcp_vault_repo,clock=&graph.clock}
	origin:=strings.trim_right(graph.config.ui_origin,"/")
	graph.mcp_delegation={repo=&graph.mcp_repository,keys=keys,issuer=origin,resource=strings.concatenate({origin,"/api/v1/mcp"},runtime.heap_allocator()),clock=&graph.clock,authority_ctx=graph,authority=mcp_account_authority}
	mcp.init(&graph.mcp_spike) // bounded transient pre-login request handles only
	graph.mcp_delegation_handlers={auth=&graph.auth,directory=&graph.vault_directory,grant_directory=&graph.mcp_vault_view,service=&graph.mcp_delegation,login_requests=&graph.mcp_spike,origin=origin}
	graph.mcp_control_handlers={delegation=&graph.mcp_delegation_handlers,control={chains=&graph.taskchains,agents=&graph.agents,providers=&graph.providers,bridges=&graph.repos.bridges},bus=&graph.event_bus,bridge_ctx=graph,bridge_transform=mcp_bridge_transform,create_ctx=graph,create=mcp_create_chain}
	graph.mcp_control_handlers.comment=mcp_comment_task
	graph.mcp_control_handlers.mutate_task=mcp_mutate_task
	graph.mcp_control_handlers.mutate_catalog=mcp_mutate_catalog
	valid=true
	return true,""
}

mcp_create_chain :: proc(ctx:rawptr,owner,title,description:string)->(string,bool) {
	graph:=(^App_Graph)(ctx)
	impl:sqlite.Taskchain_Repo_SQLite
	repo:=sqlite.new_taskchain_repository(&impl,&graph.mcp_repository_impl.conn)
	service:=graph.taskchains
	service.repo=&repo
	chain,ok,err:=tc.create_chain(&service,mcp.control_auth(owner),{title=title,description=description})
	return string(chain.chain_id),ok && err.code==.None
}

mcp_account_authority :: proc(ctx: rawptr, grant: domain.MCP_Record) -> (bool, domain.Domain_Error) {
	graph := (^App_Graph)(ctx)
	user_impl:sqlite.User_Repo_SQLite
	user_repo:=sqlite.new_user_repository(&user_impl,&graph.mcp_repository_impl.conn)
	user, found, err := iface.user_get_by_id(&user_repo, domain.User_ID(grant.owner))
	if err.code != .None do return false, err
	if !found || user.status != .Active do return false, domain.Domain_Error{}
	return mcp.delegation_vault_authority(&graph.mcp_vault_view, grant)
}

mcp_cleanup_once :: proc(graph: ^App_Graph) {
	if graph.config.mcp_oauth_key_file == "" || graph.mcp_repository_impl.conn.db == nil do return
	now, ok := auth_service.now_unix_ms(&graph.auth)
	if !ok do return
	// Fixed operation only: no database/body/credential values enter logs.
	if err:=sqlite.mcp_cleanup(&graph.mcp_repository_impl, now);err.code!=.None do fmt.eprintln("hub: MCP metadata cleanup failed")
}
free_mcp_delegation :: proc(graph: ^App_Graph) {
	mcp.worker_registrations_free(&graph.mcp_control_handlers.registrations)
	for &key in graph.mcp_delegation.keys {delete(key.id,runtime.heap_allocator());crypto.zero_explicit(&key.bytes,size_of(key.bytes))}
	delete(graph.mcp_delegation.keys,runtime.heap_allocator());graph.mcp_delegation.keys=nil
	if graph.mcp_delegation.resource!="" do delete(graph.mcp_delegation.resource,runtime.heap_allocator())
	graph.mcp_delegation.resource=""
	sqlite.close(&graph.mcp_repository_impl.conn)
}
