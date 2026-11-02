package http

import "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import auth "odin_test:hub/service/auth"
import mcp "odin_test:hub/service/mcp"
import vd "odin_test:hub/service/vault_directory"
import vault "odin_test:lib/vault"

MCP_HTTP_Vector :: struct {
	now_ms:i64,
	request:struct {owner,client,redirect,resource,scope,grant,family:string,revision,expires_ms:i64},
	directory:struct {version,current_epoch:i64,root_device_id,head_hash:string,devices:[]struct {device_id,kind,sign_alg,wrap_alg,sign_public_key,ecdh_public_key:string},log:[]struct {seq:i64,statement:string,signature:struct {alg,sig:string}}},
	hosted:mcp.Consent_Input,
	consent_body,disconnect_body,delivery_body:string,
	consent_headers,disconnect_headers,delivery_headers,recipients_headers:map[string]string,
}
MCP_HTTP_State :: struct {vector:MCP_HTTP_Vector}
mcp_http_directory :: proc(ctx:rawptr,owner:string)->(domain.Vault_Directory,bool,domain.Domain_Error) {
	v:=&(^MCP_HTTP_State)(ctx).vector
	sig,_:=vault.signature_text_from_parts(v.directory.log[0].signature.alg,v.directory.log[0].signature.sig,context.temp_allocator)
	return {user_id=owner,version=v.directory.version,current_epoch=v.directory.current_epoch,root_device_id=v.directory.root_device_id,head_hash=v.directory.head_hash,genesis_statement=v.directory.log[0].statement,genesis_signature=sig},owner==v.request.owner,domain.Domain_Error{}
}
mcp_http_devices :: proc(ctx:rawptr,owner:string)->([]domain.Vault_Device,domain.Domain_Error) {
	v:=&(^MCP_HTTP_State)(ctx).vector
	out:=make([]domain.Vault_Device,len(v.directory.devices),context.temp_allocator)
	for d,i in v.directory.devices do out[i]={user_id=owner,device_id=d.device_id,kind=d.kind,sign_alg=d.sign_alg,wrap_alg=d.wrap_alg,sign_public_key=d.sign_public_key,ecdh_public_key=d.ecdh_public_key,status=.Approved}
	return out,{}
}
mcp_http_log :: proc(ctx:rawptr,owner:string)->([]domain.Vault_Log_Entry,domain.Domain_Error) {
	v:=&(^MCP_HTTP_State)(ctx).vector
	out:=make([]domain.Vault_Log_Entry,len(v.directory.log),context.temp_allocator)
	for entry,i in v.directory.log {
		sig,_:=vault.signature_text_from_parts(entry.signature.alg,entry.signature.sig,context.temp_allocator)
		out[i]={user_id=owner,seq=entry.seq,statement=entry.statement,signature=sig}
	}
	return out,{}
}
mcp_http_seed :: proc(tx:iface.MCP_Transaction,ctx:rawptr)->domain.Domain_Error {
	v:=&(^MCP_HTTP_State)(ctx).vector
	if err:=tx.put(tx.ctx,domain.MCP_Record{kind="client",id=v.request.client,redirect=v.request.redirect});err.code!=.None do return err
	return tx.put(tx.ctx,domain.MCP_Record{kind="pending",id=auth.sha256_hex(v.hosted.request),owner=v.request.owner,client=v.request.client,redirect=v.request.redirect,resource=v.request.resource,scope=v.request.scope,grant=v.request.grant,family=v.request.family,revision=1,created_ms=v.now_ms,expires_ms=v.request.expires_ms,challenge=auth.pkce_challenge_s256("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),oauth_state="fixture-state"})
}
mcp_http_headers :: proc(cookie:contracts.HTTP_Header,signed:map[string]string,origin:string)->[]contracts.HTTP_Header {
	out:=make([dynamic]contracts.HTTP_Header,context.temp_allocator)
	append(&out,cookie,contracts.HTTP_Header{"Origin",origin},contracts.HTTP_Header{"Content-Type","application/json"})
	for name,value in signed do append(&out,contracts.HTTP_Header{name,value})
	return out[:]
}

@(test)
test_mcp_delegation_signed_consent_token_retry_and_disconnect :: proc(t:^testing.T) {
    mcp_http_consent_flow(t,#load("../../../../tests/fixtures/mcp_consent_v1.json",string))
    mcp_http_consent_flow(t,#load("../../../../tests/fixtures/mcp_consent_v2.json",string))
}
mcp_http_consent_flow :: proc(t:^testing.T,vector_json:string) {
	context.allocator=context.temp_allocator
	f:=mcp_test_fixture(t)
	defer sqlite.close(&f.conn)
	state:MCP_HTTP_State
	testing.expect(t,json.unmarshal(transmute([]byte)vector_json,&state.vector,.JSON,context.temp_allocator)==nil)
	v:=&state.vector
	_,saved,_:=iface.user_save(&f.user_repo,domain.User{user_id=domain.User_ID(v.request.owner),name=v.request.owner,status=.Active,created_at=mcp_test_now(nil),updated_at=mcp_test_now(nil)})
	testing.expect(t,saved)
	impl:sqlite.MCP_Repo_SQLite
	repo,rerr:=sqlite.open_mcp_repository(&impl,":memory:")
	testing.expect(t,rerr.code==.None)
	defer sqlite.close(&impl.conn)
	testing.expect(t,sqlite.exec(&impl.conn,#load("../../repository/sqlite/migrations/175_mcp_delegated_credentials.sql",string)))
	testing.expect(t,sqlite.exec(&impl.conn,#load("../../repository/sqlite/migrations/176_mcp_epoch_wraps.sql",string)))
	testing.expect(t,iface.mcp_transaction(&repo,mcp_http_seed,&state).code==.None)
	keys:[1]mcp.Envelope_Key
	keys[0].id="http-test";keys[0].bytes[0]=9
	s:=mcp.Delegation_Service{repo=&repo,keys=keys[:],issuer="https://hub.example",resource=v.request.resource,authority=proc(ctx:rawptr,g:domain.MCP_Record)->(bool,domain.Domain_Error){return true,{}}}
	vrepo:=iface.Vault_Directory_Repository{ctx=&state,get_directory=mcp_http_directory,list_devices=mcp_http_devices,list_log=mcp_http_log}
	directory:=vd.new_service(&vrepo,&f.clock)
	defer vd.service_free(&directory)
	login:mcp.Store;mcp.init(&login);defer mcp.free(&login)
	h:=MCP_Delegation_Handlers{auth=&f.auth,directory=&directory,grant_directory=&directory,service=&s,login_requests=&login,origin="https://hub.example"}
	cookie:=http_test_login_cookie(t,&f.auth,v.request.owner)
	// Session-only and cross-origin requests cannot complete consent. Neither
	// rejected request consumes the signed request's nonce.
	unsigned_headers:=mcp_http_headers(cookie,nil,h.origin)
	testing.expect(t,mcp_delegation_consent_handler(&h,{method="POST",path=MCP_OAUTH+"/consent",body=strings.clone(v.consent_body,context.temp_allocator),headers=unsigned_headers}).status!=200)
	foreign_headers:=mcp_http_headers(cookie,v.consent_headers,"https://other.example")
	testing.expect(t,mcp_delegation_consent_handler(&h,{method="POST",path=MCP_OAUTH+"/consent",body=strings.clone(v.consent_body,context.temp_allocator),headers=foreign_headers}).status==403)
	headers:=mcp_http_headers(cookie,v.consent_headers,h.origin)
	accepted:=mcp_delegation_consent_handler(&h,{method="POST",path=MCP_OAUTH+"/consent",body=strings.clone(v.consent_body,context.temp_allocator),headers=headers})
	testing.expect(t,accepted.sensitive,"credential redirect is wiped by HTTP writer")
	testing.expectf(t,accepted.status==200,"signed browser consent status %d",accepted.status)
	if accepted.status!=200 do return
	callback:struct {redirect:string}
	testing.expect(t,json.unmarshal_string(accepted.body,&callback,.JSON,context.temp_allocator)==nil)
	q:=callback.redirect[strings.index_byte(callback.redirect,'?')+1:]
	code:=query_value(q,"code")
	testing.expect(t,code!="" && len(code)<4096 && query_value(q,"state")=="fixture-state")
	// Native endpoints continue rejecting delegated credentials as user auth.
	form:=mcp_join("grant_type=authorization_code&client_id=",v.request.client,"&resource=",auth.form_encode(v.request.resource),"&redirect_uri=",auth.form_encode(v.request.redirect),"&code=",auth.form_encode(code),"&code_verifier=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	form_headers:=make([]contracts.HTTP_Header,1,context.temp_allocator)
	form_headers[0]={"Content-Type","application/x-www-form-urlencoded"}
	// Requesting unsigned or unselected rights must not consume the code.
    elevated:=mcp_join(form,"&scope=",auth.form_encode("mcp:chains mcp:instances:control"))
    denied:=mcp_delegation_token_handler(&h,{method="POST",body=strings.clone(elevated,context.temp_allocator),headers=form_headers})
    testing.expect(t,strings.contains(denied.body,"invalid_scope"))
    token_resp:=mcp_delegation_token_handler(&h,{method="POST",body=strings.clone(form,context.temp_allocator),headers=form_headers})
	testing.expect(t,token_resp.sensitive,"token response copies use sensitive cleanup")
	testing.expect(t,token_resp.status==200 && header_value(token_resp.headers,"Cache-Control")=="no-store")
	tokens:mcp.Tokens
	testing.expect(t,json.unmarshal_string(token_resp.body,&tokens,.JSON,context.temp_allocator)==nil)
    consent:mcp.Consent
    testing.expect(t,json.unmarshal_string(v.hosted.consent,&consent,.JSON,context.temp_allocator)==nil)
    testing.expect_value(t,tokens.scope,consent.scope)
    testing.expect(t,!mcp.scope_allows_tool(tokens.scope,"tasks.comment"))
    if consent.v==2 do testing.expect(t,mcp.scope_allows_tool(tokens.scope,"artifacts.get"))
	native_headers:=make([]contracts.HTTP_Header,1,context.temp_allocator)
	native_headers[0]={"Authorization",mcp_join("Bearer ",tokens.access_token)}
	_,native_ok,_:=require_auth(&f.auth,{method="GET",path="/api/v1/me",headers=native_headers})
	testing.expect(t,!native_ok)
	refresh_form:=mcp_join("grant_type=refresh_token&client_id=",v.request.client,"&resource=",auth.form_encode(v.request.resource),"&refresh_token=",auth.form_encode(tokens.refresh_token))
	broader:=mcp_join(refresh_form,"&scope=",auth.form_encode("mcp:chains mcp:tasks:read mcp:tasks:write mcp:artifacts:read"))
    if consent.v==2 do testing.expect(t,strings.contains(mcp_delegation_token_handler(&h,{method="POST",body=strings.clone(broader,context.temp_allocator),headers=form_headers}).body,"invalid_scope"))
    rotated:=mcp_delegation_token_handler(&h,{method="POST",body=strings.clone(refresh_form,context.temp_allocator),headers=form_headers})
	retry:=mcp_delegation_token_handler(&h,{method="POST",body=strings.clone(refresh_form,context.temp_allocator),headers=form_headers})
	testing.expect(t,rotated.status==200 && retry.status==200 && rotated.body==retry.body)
	recipients:=mcp_connector_epoch_handler(&h,{method="GET",path=MCP_OAUTH+"/recipients",headers=mcp_http_headers(cookie,v.recipients_headers,h.origin)})
	testing.expect(t,recipients.status==200 && strings.contains(recipients.body,v.request.grant) && !strings.contains(recipients.body,v.hosted.private_capability))
	delivered:=mcp_connector_epoch_handler(&h,{method="POST",path=MCP_OAUTH+"/wraps",body=strings.clone(v.delivery_body,context.temp_allocator),headers=mcp_http_headers(cookie,v.delivery_headers,h.origin)})
	testing.expect(t,delivered.status==200)
	disconnect:=mcp_delegation_connections_handler(&h,{method="POST",path=MCP_OAUTH+"/disconnect",body=strings.clone(v.disconnect_body,context.temp_allocator),headers=mcp_http_headers(cookie,v.disconnect_headers,h.origin)})
	testing.expect(t,disconnect.status==200)
	after:=mcp_delegation_token_handler(&h,{method="POST",body=strings.clone(refresh_form,context.temp_allocator),headers=form_headers})
	testing.expect(t,after.status==400 && strings.contains(after.body,"invalid_grant"))
}
