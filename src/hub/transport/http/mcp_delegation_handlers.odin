package http

import "core:crypto"
import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import auth "odin_test:hub/service/auth"
import mcp "odin_test:hub/service/mcp"
import vd "odin_test:hub/service/vault_directory"

MCP_PATH :: "/api/v1/mcp"
MCP_OAUTH :: "/api/v1/mcp/oauth"
mcp_join :: proc(parts: ..string) -> string {return strings.concatenate(parts, context.temp_allocator)}
MCP_Delegation_Handlers :: struct {
	auth: ^auth.Auth_Service,
	directory: ^vd.Service,
	grant_directory: ^vd.Service, // read view on the MCP transaction connection
	service: ^mcp.Delegation_Service,
	login_requests: ^mcp.Store,
	origin: string,
}
mcp_delegation_register_routes :: proc(r: ^Router, h: ^MCP_Delegation_Handlers) {
	for p in ([]string{"/.well-known/oauth-protected-resource/api/v1/mcp", "/.well-known/oauth-protected-resource", "/.well-known/oauth-authorization-server"}) do router_add(r, "GET", p, h, mcp_delegation_metadata_handler)
	router_add(r, "GET", MCP_OAUTH+"/authorize", h, mcp_delegation_authorize_handler)
	router_add(r, "POST", MCP_OAUTH+"/register", h, mcp_delegation_register_handler)
	router_add(r, "POST", MCP_OAUTH+"/token", h, mcp_delegation_token_handler)
	router_add(r, "GET", MCP_OAUTH+"/consent", h, mcp_delegation_consent_handler)
	router_add(r, "POST", MCP_OAUTH+"/consent", h, mcp_delegation_consent_handler)
	router_add(r, "GET", MCP_OAUTH+"/connections", h, mcp_delegation_connections_handler)
	router_add(r, "POST", MCP_OAUTH+"/disconnect", h, mcp_delegation_connections_handler)
	router_add(r, "GET", MCP_OAUTH+"/recipients", h, mcp_connector_epoch_handler)
	router_add(r, "POST", MCP_OAUTH+"/wraps", h, mcp_connector_epoch_handler)
}

mcp_connector_epoch_handler :: proc(ctx:rawptr,req:Request)->Response {
	h:=(^MCP_Delegation_Handlers)(ctx)
	principal,signer,ok,resp:=mcp_delegation_user(h,req,true)
	if !ok do return resp
	if req.method=="GET" {
		recipients,err:=mcp.connector_recipients(h.service,h.grant_directory,principal.user_id)
		if err.code!=.None do return respond_error(err,req.request_id)
		Row::struct {grant:string,revision:i64,consent,signature:string}
		out:=make([]Row,len(recipients),context.temp_allocator)
		for g,i in recipients do out[i]={g.id,g.revision,g.consent,g.signature}
		return mcp_json(out)
	}
	if len(req.body)>16384 do return mcp_oauth_error("invalid_request")
	input:mcp.Epoch_Delivery_Input
	if json.unmarshal_string(req.body,&input,.JSON,context.temp_allocator)!=nil do return mcp_oauth_error("invalid_request")
	if err:=mcp.deliver_connector_epoch(h.service,h.grant_directory,principal.user_id,signer.device_id,input);err.code!=.None do return respond_error(err,req.request_id)
	return mcp_json(struct {delivered:bool}{true})
}
mcp_delegation_metadata_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^MCP_Delegation_Handlers)(ctx)
	if req.path == "/.well-known/oauth-authorization-server" {
		return mcp_json(struct {issuer, authorization_endpoint, token_endpoint, registration_endpoint: string, response_types_supported, grant_types_supported, code_challenge_methods_supported, token_endpoint_auth_methods_supported, scopes_supported: []string}{h.origin, mcp_join(h.origin,MCP_OAUTH,"/authorize"), mcp_join(h.origin,MCP_OAUTH,"/token"), mcp_join(h.origin,MCP_OAUTH,"/register"), []string{"code"}, []string{"authorization_code","refresh_token"}, []string{"S256"}, []string{"none"}, mcp.supported_scopes()})
	}
	return mcp_json(struct {resource: string, authorization_servers, scopes_supported, bearer_methods_supported: []string}{h.service.resource, []string{h.origin}, mcp.supported_scopes(), []string{"header"}})
}
mcp_delegation_register_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^MCP_Delegation_Handlers)(ctx)
	if len(req.body) > 8192 || !strings.has_prefix(header_value(req.headers,"Content-Type"), "application/json") do return mcp_oauth_error("invalid_client_metadata")
	input: struct {redirect_uris: []string, token_endpoint_auth_method: string, grant_types, response_types: []string}
	if json.unmarshal(transmute([]byte)req.body, &input, .JSON, context.temp_allocator) != nil || len(input.redirect_uris) != 1 || (input.token_endpoint_auth_method != "" && input.token_endpoint_auth_method != "none") do return mcp_oauth_error("invalid_client_metadata")
	for g in input.grant_types do if g != "authorization_code" && g != "refresh_token" do return mcp_oauth_error("invalid_client_metadata")
	for r in input.response_types do if r != "code" do return mcp_oauth_error("invalid_client_metadata")
	id, err := mcp.delegation_register(h.service, input.redirect_uris[0])
	if err.code != .None do return mcp_oauth_error("invalid_client_metadata")
	return mcp_json(struct {client_id: string, redirect_uris: []string, token_endpoint_auth_method: string, grant_types, response_types: []string}{id, input.redirect_uris, "none", []string{"authorization_code","refresh_token"}, []string{"code"}},201)
}
mcp_delegation_authorize_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^MCP_Delegation_Handlers)(ctx)
	if !mcp_form_unique(req.query) do return mcp_oauth_error("invalid_request")
	now, clock_ok := auth.now_unix_ms(h.auth)
	if !clock_ok do return mcp_oauth_error("temporarily_unavailable",503)
	query := req.query
	resume := query_value(query,"request")
	if resume != "" {
		form, found := mcp.pending_read(h.login_requests,resume,now)
		if !found do return mcp_oauth_error("invalid_request")
		query = form
	}
	requested_scope,scope_ok:=mcp.canonical_scopes(query_value(query,"scope"))
	if !scope_ok do return mcp_oauth_error("invalid_scope")
	client, redirect := query_value(query,"client_id"),query_value(query,"redirect_uri")
	c, found, err := mcp.delegation_read(h.service,"client",client)
	if err.code != .None do return mcp_oauth_error("temporarily_unavailable",503)
	if !found || c.revoked || c.redirect != redirect || !mcp.challenge_ok(query_value(query,"code_challenge")) || query_value(query,"code_challenge_method") != "S256" || query_value(query,"response_type") != "code" || query_value(query,"resource") != h.service.resource do return mcp_oauth_error("invalid_request")
	principal, ok, _ := require_auth(h.auth,req)
	if !ok {
		if resume == "" {
			ticket, made := mcp.pending_begin(h.login_requests,query,now)
			if !made do return mcp_oauth_error("temporarily_unavailable",503)
			resume = ticket
		}
		return redirect_response(mcp_join("/api/v1/auth/login?return_to=",auth.form_encode(mcp_join(MCP_OAUTH,"/authorize?request=",resume))))
	}
	if principal.kind != .Session do return mcp_oauth_error("access_denied",403)
	if resume != "" {_, _ = mcp.pending_read(h.login_requests,resume,now,true)}
	ticket, berr := mcp.delegation_begin(h.service,principal.user_id,client,redirect,query_value(query,"code_challenge"),query_value(query,"state"),now,requested_scope)
	if berr.code != .None do return respond_error(berr,req.request_id)
	return redirect_response(mcp_join(h.origin,"/#/mcp/consent?request=",ticket))
}
mcp_delegation_user :: proc(h: ^MCP_Delegation_Handlers, req: Request, allow_native:=false) -> (contracts.Auth_Context, domain.Vault_Device, bool, Response) {
	principal, ok, resp := require_auth(h.auth,req)
	if !ok do return {},{},false,resp
	if principal.kind != .Session && !(allow_native && principal.kind==.OIDC) do return {},{},false,mcp_oauth_error("access_denied",403)
	if principal.kind==.Session && req.method == "POST" && header_value(req.headers,"Origin") != h.origin do return {},{},false,mcp_oauth_error("access_denied",403)
	vh := Vault_Directory_Handlers{auth=h.auth,vault=h.directory}
	signer, err := vault_request_signer(&vh,principal,req,.Approver)
	if err.code != .None do return {},{},false,respond_error(err,req.request_id)
	return principal,signer,true,{}
}
mcp_delegation_consent_handler :: proc(ctx: rawptr, req: Request) -> Response {
	defer if req.body!="" do crypto.zero_explicit(raw_data(req.body),len(req.body))
	h := (^MCP_Delegation_Handlers)(ctx)
	principal, signer, ok, resp := mcp_delegation_user(h,req)
	if !ok do return resp
	now, clock_ok := auth.now_unix_ms(h.auth)
	if !clock_ok do return mcp_oauth_error("temporarily_unavailable",503)
	if req.method == "GET" {
		ticket := query_value(req.query,"request")
		row, found, err := mcp.delegation_read(h.service,"pending",auth.sha256_hex(ticket))
		if err.code != .None do return respond_error(err,req.request_id)
		if !found || row.owner != principal.user_id || row.consumed || row.expires_ms <= now do return mcp_oauth_error("invalid_request")
		return mcp_json(struct {owner,client,redirect,resource,scope,grant,family: string, revision,expires_ms: i64}{row.owner,row.client,row.redirect,row.resource,row.scope,row.grant,row.family,row.revision,row.expires_ms})
	}
	if len(req.body)>65536 do return mcp_oauth_error("invalid_request")
	input: mcp.Consent_Input
	if json.unmarshal(transmute([]byte)req.body,&input,.JSON,context.temp_allocator)!=nil do return mcp_oauth_error("invalid_request")
	defer if input.private_capability!="" do crypto.zero_explicit(raw_data(input.private_capability),len(input.private_capability))
	code,redirect,state,err:=mcp.delegation_consent(h.service,h.grant_directory,principal.user_id,signer.device_id,input,now)
	if err.code!=.None do return respond_error(err,req.request_id)
	separator:="&" if strings.contains(redirect,"?") else "?"
	response:=mcp_json(struct {redirect: string}{mcp_join(redirect,separator,"code=",auth.form_encode(code),"&state=",auth.form_encode(state))})
	response.sensitive=true
	return response
}
mcp_delegation_connections_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^MCP_Delegation_Handlers)(ctx)
	principal,_,ok,resp:=mcp_delegation_user(h,req,true)
	if !ok do return resp
	if req.method=="POST" {
		input:struct {grant:string}
		if len(req.body)>1024 || json.unmarshal(transmute([]byte)req.body,&input,.JSON,context.temp_allocator)!=nil do return mcp_oauth_error("invalid_request")
		if err:=mcp.delegation_revoke(h.service,principal.user_id,input.grant);err.code!=.None do return respond_error(err,req.request_id)
		return mcp_json(struct {disconnected:bool}{true})
	}
	rows,err:=mcp.delegation_grants(h.service,principal.user_id)
	if err.code!=.None do return respond_error(err,req.request_id)
	Row :: struct {grant,client,resource,mode:string,created_ms:i64,revoked:bool}
	out:=make([]Row,len(rows),context.temp_allocator)
	for row,i in rows do out[i]={row.id,row.client,row.resource,row.mode,row.created_ms,row.revoked}
	return mcp_json(out)
}
mcp_delegation_token_handler :: proc(ctx: rawptr, req: Request) -> Response {
	defer if req.body!="" do crypto.zero_explicit(raw_data(req.body),len(req.body))
	h := (^MCP_Delegation_Handlers)(ctx)
	// Account for form escaping and the exact registered redirect as well as
	// the bounded envelope. U0 retains its smaller default form cap.
	if !strings.has_prefix(header_value(req.headers,"Content-Type"),"application/x-www-form-urlencoded") || !mcp_form_unique(req.body,65536) do return mcp_oauth_error("invalid_request")
	if header_value(req.headers,"Authorization")!="" do return mcp_oauth_error("invalid_client",401)
	if query_value(req.body,"resource")!=h.service.resource do return mcp_oauth_error("invalid_target")

	now,clock_ok:=auth.now_unix_ms(h.auth)
	if !clock_ok do return mcp_oauth_error("temporarily_unavailable",503)
	kind,raw:="",""
	switch query_value(req.body,"grant_type") {
	case "authorization_code": kind="code";raw=query_value(req.body,"code")
	case "refresh_token": kind="refresh";raw=query_value(req.body,"refresh_token")
	case: return mcp_oauth_error("unsupported_grant_type")
	}
	if requested:=query_value(req.body,"scope");requested!="" {
		canonical,ok:=mcp.canonical_scopes(requested)
		claims,opened:=mcp.credential_open(h.service.keys,raw,kind)
		defer mcp.credential_claims_wipe(&claims)
		if !ok || !opened || canonical!=claims.scope do return mcp_oauth_error("invalid_scope")
	}
	result:=mcp.delegation_redeem(h.service,raw,kind,query_value(req.body,"client_id"),query_value(req.body,"redirect_uri"),query_value(req.body,"code_verifier"),now)
	if result.error!="" do return mcp_oauth_error(result.error)
	// Exact bytes, including a recovered retry response. Neither body nor raw
	// credentials are included in telemetry, audit records or error messages.
	headers:=make([]contracts.HTTP_Header,2,context.temp_allocator)
	headers[0]={"Cache-Control","no-store"};headers[1]={"Pragma","no-cache"}
	return Response{status=200,content_type="application/json",body=result.response,headers=headers,sensitive=true}
}
