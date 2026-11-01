package mcp

import "core:encoding/json"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import auth "odin_test:hub/service/auth"
import vd "odin_test:hub/service/vault_directory"
import vault "odin_test:lib/vault"
import sqlite "odin_test:hub/repository/sqlite"

// Generated using production browser crypto and a synthetic vault. This pins
// fixed-order consent JSON, signature domain, P-256 scalar/public binding and
// signed wrap interoperability across TypeScript/WebCrypto and Odin.
Consent_Test_Directory :: struct {
		version,current_epoch:i64,
		root_device_id,head_hash:string,
		devices:[]struct {device_id,kind,sign_alg,wrap_alg,sign_public_key,ecdh_public_key:string},
		log:[]struct {seq:i64,statement:string,signature:struct {alg,sig:string}},
	}
Consent_Vector :: struct {
	now_ms:i64,
	request:struct {owner,client,redirect,resource,scope,grant,family:string,revision,expires_ms:i64},
	directory:Consent_Test_Directory,
	hosted,device:Consent_Input,
	revoked:bool,
}
consent_vector :: proc(t:^testing.T,raw:string=#load("../../../../tests/fixtures/mcp_consent_v1.json",string))->Consent_Vector {
	v:Consent_Vector
	err:=json.unmarshal(transmute([]byte)raw,&v,.JSON,context.temp_allocator)
	testing.expect(t,err==nil)
	return v
}
consent_test_directory :: proc(ctx:rawptr,owner:string)->(domain.Vault_Directory,bool,domain.Domain_Error) {
	v:=(^Consent_Vector)(ctx)
	if owner!=v.request.owner do return {},false,domain.Domain_Error{}
	sig,_:=vault.signature_text_from_parts(v.directory.log[0].signature.alg,v.directory.log[0].signature.sig,context.temp_allocator)
	return {user_id=owner,version=v.directory.version,current_epoch=v.directory.current_epoch,root_device_id=v.directory.root_device_id,head_hash=v.directory.head_hash,genesis_statement=v.directory.log[0].statement,genesis_signature=sig},true,domain.Domain_Error{}
}
consent_test_devices :: proc(ctx:rawptr,owner:string)->([]domain.Vault_Device,domain.Domain_Error) {
	v:=(^Consent_Vector)(ctx)
	rows:=make([]domain.Vault_Device,len(v.directory.devices),context.temp_allocator)
	for d,i in v.directory.devices do rows[i]={user_id=owner,device_id=d.device_id,kind=d.kind,sign_alg=d.sign_alg,wrap_alg=d.wrap_alg,sign_public_key=d.sign_public_key,ecdh_public_key=d.ecdh_public_key,status=.Revoked if v.revoked else .Approved}
	return rows,{}
}
consent_test_log :: proc(ctx:rawptr,owner:string)->([]domain.Vault_Log_Entry,domain.Domain_Error) {
	v:=(^Consent_Vector)(ctx)
	rows:=make([]domain.Vault_Log_Entry,len(v.directory.log),context.temp_allocator)
	for entry,i in v.directory.log {
		sig,_:=vault.signature_text_from_parts(entry.signature.alg,entry.signature.sig,context.temp_allocator)
		rows[i]={user_id=owner,seq=entry.seq,statement=entry.statement,signature=sig}
	}
	return rows,{}
}
consent_test_now :: proc(ctx:rawptr)->string {return "2026-10-31T07:00:00Z"}

Consent_Seed :: struct {vector:^Consent_Vector}
seed_consent_request :: proc(tx:iface.MCP_Transaction,ctx:rawptr)->domain.Domain_Error {
	v:=(^Consent_Seed)(ctx).vector
	if err:=tx.put(tx.ctx,domain.MCP_Record{kind="client",id=v.request.client,redirect=v.request.redirect});err.code!=.None do return err
	p:=domain.MCP_Record{kind="pending",id=auth.sha256_hex(v.hosted.request),owner=v.request.owner,client=v.request.client,redirect=v.request.redirect,resource=v.request.resource,scope=v.request.scope,grant=v.request.grant,family=v.request.family,revision=1,created_ms=v.now_ms,expires_ms=v.request.expires_ms,challenge=auth.pkce_challenge_s256("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")}
	return tx.put(tx.ctx,p)
}

@(test)
test_consent_browser_vector_bindings_and_one_use :: proc(t:^testing.T) {
    consent_cross_runtime_flow(t,#load("../../../../tests/fixtures/mcp_consent_v1.json",string))
    consent_cross_runtime_flow(t,#load("../../../../tests/fixtures/mcp_consent_v2.json",string))
}
consent_cross_runtime_flow :: proc(t:^testing.T,raw:string) {
	context.allocator=context.temp_allocator
	f:Delegation_Fixture
	if !delegation_fixture(t,&f) do return
	defer sqlite.close(&f.impl.conn)
	v:=consent_vector(t,raw)
	value,parse_err:=json.parse_string(v.hosted.wrap_json,parse_integers=true,allocator=context.temp_allocator)
	testing.expect(t,parse_err==nil)
	_,_,native_ok:=vault.wrap_from_value(value,context.temp_allocator)
	testing.expect(t,!native_ok,"delegated recipients remain invalid at native device-directory endpoints")
	f.service.issuer="https://hub.example";f.service.resource=v.request.resource
	repo:=iface.Vault_Directory_Repository{ctx=&v,get_directory=consent_test_directory,list_devices=consent_test_devices,list_log=consent_test_log}
	clock:=platform.Clock{now=consent_test_now}
	directory:=vd.Service{repo=&repo,clock=&clock}
	seed:=Consent_Seed{&v}
	testing.expect(t,iface.mcp_transaction(&f.repo,seed_consent_request,&seed).code==.None)
	signer:=v.directory.root_device_id
	// Every rejected attempt leaves the pending consent usable.
	for n in 0..<10 {
		input:=v.hosted
		owner,approver:=v.request.owner,signer
		switch n {
		case 0: owner="bob"
		case 1: approver="unknown"
		case 2: input.consent=strings.concatenate({input.consent," "},context.temp_allocator)
		case 3: input.signature=`{"alg":"ecdsa-p256-sha256","sig":"00"}`
		case 4: input.private_capability="0000000000000000000000000000000000000000000000000000000000000000"
		case 5: input.wrap_json="{}"
		case 6: v.directory.version+=1
        case 7,8,9:
            bad:Consent
            _=json.unmarshal_string(input.consent,&bad,.JSON,context.temp_allocator)
            if n==7 do bad.scope="mcp:chains mcp:instances:control"
            if n==8 do bad.v=1 if bad.v==2 else 2
            if n==9 do bad.scope="mcp:chains mcp:messages:write"
            encoded,_:=json.marshal(bad,allocator=context.temp_allocator)
            input.consent=string(encoded)
		}
		_,_,_,err:=delegation_consent(&f.service,&directory,owner,approver,input,v.now_ms)
		testing.expect(t,err.code!=.None)
		if n==6 do v.directory.version-=1
	}
	code,redirect,_,err:=delegation_consent(&f.service,&directory,v.request.owner,signer,v.hosted,v.now_ms)
	testing.expectf(t,err.code==.None && redirect==v.request.redirect && code!="","production WebCrypto consent verifies in Odin: %s",err.message)
	if err.code!=.None do return
	opened,ok:=credential_open(f.key[:],code,"code")
	testing.expect(t,ok && opened.private_capability==v.hosted.private_capability && opened.client==v.request.client)
	credential_claims_wipe(&opened)
	_,_,_,again:=delegation_consent(&f.service,&directory,v.request.owner,signer,v.hosted,v.now_ms)
	testing.expect(t,again.code!=.None,"pending consent is one use")
	grant,found,gerr:=delegation_read(&f.service,"grant",v.request.grant)
	testing.expect(t,found && gerr.code==.None && !strings.contains(grant.consent,v.hosted.private_capability) && !strings.contains(grant.wrap_json,v.hosted.private_capability))
	live,lerr:=delegation_vault_authority(&directory,grant)
	testing.expect(t,live && lerr.code==.None)
	// Scoped WebCrypto consent must survive native token issuance, hosted
	// directory verification/decryption and refresh without gaining rights.
	if consent_version(grant.scope)==2 {
		tokens:=delegation_test_tokens(t,delegation_redeem(&f.service,code,"code",v.request.client,v.request.redirect,"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",v.now_ms))
		testing.expect_value(t,tokens.scope,grant.scope)
		testing.expect(t,scope_allows_tool(tokens.scope,"artifacts.get") && !scope_allows_tool(tokens.scope,"tasks.comment"))
		clock.now=hosted_test_now;f.service.clock=&clock
		op:=Hosted_Test_Transform{seal=true}
		result:=hosted_with_access(&f.service,&directory,tokens.access_token,v.request.client,hosted_test_transform,&op)
		testing.expectf(t,result.error=="" && op.calls==1,"v2 hosted transform: %s",result.error)
		delegation_response_wipe(&result)
		refreshed:=delegation_test_tokens(t,delegation_redeem(&f.service,tokens.refresh_token,"refresh",v.request.client,"","",v.now_ms+2000))
		testing.expect_value(t,refreshed.scope,grant.scope)
	}
	v.revoked=true
	live,_=delegation_vault_authority(&directory,grant)
	testing.expect(t,!live,"revoked approving device stops delegation")
}

@(test)
test_consent_device_mode_has_no_private_capability :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	f:Delegation_Fixture
	if !delegation_fixture(t,&f) do return
	defer sqlite.close(&f.impl.conn)
	v:=consent_vector(t)
	f.service.issuer="https://hub.example";f.service.resource=v.request.resource
	repo:=iface.Vault_Directory_Repository{ctx=&v,get_directory=consent_test_directory,list_devices=consent_test_devices,list_log=consent_test_log}
	clock:=platform.Clock{now=consent_test_now}
	directory:=vd.Service{repo=&repo,clock=&clock}
	seed:=Consent_Seed{&v}
	testing.expect(t,iface.mcp_transaction(&f.repo,seed_consent_request,&seed).code==.None)
	code,_,_,err:=delegation_consent(&f.service,&directory,v.request.owner,v.directory.root_device_id,v.device,v.now_ms)
	testing.expectf(t,err.code==.None,"device consent verifies: %s",err.message)
	claims,ok:=credential_open(f.key[:],code,"code")
	testing.expect(t,ok && claims.private_capability=="" && claims.recipient=="")
}
