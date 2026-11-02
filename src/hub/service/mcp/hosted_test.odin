package mcp

import "core:encoding/json"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import vd "odin_test:hub/service/vault_directory"
import vault "odin_test:lib/vault"

Hosted_Vector :: struct {
	initial:Consent_Vector,
	content,rotated_content:json.Object,
	rotated_directory,complex_directory:Consent_Test_Directory,
	rotated_wrap,wrong_key_wrap:Epoch_Delivery_Input,
}
Hosted_Vectors :: struct {alice,bob:Hosted_Vector}
hosted_vectors :: proc(t:^testing.T)->Hosted_Vectors {
	v:Hosted_Vectors
	testing.expect(t,json.unmarshal_string(#load("../../../../tests/fixtures/mcp_hosted_v1.json",string),&v,.JSON,context.temp_allocator)==nil)
	return v
}
hosted_test_now :: proc(ctx:rawptr)->string {return "2026-10-31T07:00:02Z"}
hosted_test_directory :: proc(v:^Consent_Vector,repo:^iface.Vault_Directory_Repository,clock:^platform.Clock)->vd.Service {
	repo^={ctx=v,get_directory=consent_test_directory,list_devices=consent_test_devices,list_log=consent_test_log}
	return vd.Service{repo=repo,clock=clock}
}
hosted_test_authorize :: proc(t:^testing.T,f:^Delegation_Fixture,v:^Consent_Vector,directory:^vd.Service)->string {
	f.service.issuer="https://hub.example";f.service.resource=v.request.resource
	seed:=Consent_Seed{v}
	testing.expect(t,iface.mcp_transaction(&f.repo,seed_consent_request,&seed).code==.None)
	code,_,_,err:=delegation_consent(&f.service,directory,v.request.owner,v.directory.root_device_id,v.hosted,v.now_ms)
	testing.expectf(t,err.code==.None,"hosted consent: %s",err.message)
	tokens:=delegation_test_tokens(t,delegation_redeem(&f.service,code,"code",v.request.client,v.request.redirect,"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",v.now_ms))
	return tokens.access_token
}
Hosted_Test_Transform :: struct {
	record:json.Object,
	calls:int,
	revoke:^Delegation_Service,
	owner,grant:string,
	vector:^Consent_Vector,
	new_directory:Consent_Test_Directory,
	seal:bool,
	sealed_title:string,
}
hosted_test_transform :: proc(ctx:rawptr,kr:^vault.Vault_Keyring)->(string,bool) {
	op:=(^Hosted_Test_Transform)(ctx)
	op.calls+=1
	if op.revoke!=nil do _=delegation_revoke(op.revoke,op.owner,op.grant)
	if op.vector!=nil do op.vector.directory=op.new_directory
	if op.seal {
		title,_,ok:=hosted_seal_chain(kr,"new chain","new description")
		op.sealed_title=title
		return strings.clone(`{"created":true}`,context.temp_allocator),ok
	}
	return hosted_record_json(kr,.Task,op.record)
}

@(test)
test_hosted_two_users_bindings_and_fail_closed_transforms :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	f:Delegation_Fixture
	if !delegation_fixture(t,&f) do return
	defer sqlite.close(&f.impl.conn)
	v:=hosted_vectors(t)
	clock:=platform.Clock{now=hosted_test_now};f.service.clock=&clock
	ar,br:iface.Vault_Directory_Repository
	ad:=hosted_test_directory(&v.alice.initial,&ar,&clock)
	bd:=hosted_test_directory(&v.bob.initial,&br,&clock)
	a:=hosted_test_authorize(t,&f,&v.alice.initial,&ad)
	b:=hosted_test_authorize(t,&f,&v.bob.initial,&bd)
	for i in 0..<4 {
		aop:=Hosted_Test_Transform{record=v.alice.content}
		bop:=Hosted_Test_Transform{record=v.bob.content}
		ra:=hosted_with_access(&f.service,&ad,a,"client-fixture",hosted_test_transform,&aop)
		rb:=hosted_with_access(&f.service,&bd,b,"client-fixture",hosted_test_transform,&bop)
		testing.expectf(t,ra.error=="" && strings.contains(ra.response,"usr_alice_fixture secret") && !strings.contains(ra.response,"vault:v2:") && !strings.contains(ra.response,"usr_bob_fixture") && !strings.contains(ra.response,"comment_summary"),"alice transform: %s",ra.error)
		testing.expectf(t,rb.error=="" && strings.contains(rb.response,"usr_bob_fixture secret") && !strings.contains(rb.response,"usr_alice_fixture"),"bob transform: %s",rb.error)
		delegation_response_wipe(&ra);delegation_response_wipe(&rb)
	}
	op:=Hosted_Test_Transform{record=v.alice.content}
	testing.expect(t,hosted_with_access(&f.service,&ad,a,"wrong-client",hosted_test_transform,&op).error!="" && op.calls==0)
	testing.expect(t,hosted_with_access(&f.service,&bd,a,"client-fixture",hosted_test_transform,&op).error!="" && op.calls==0)
	// Even a valid other-user ciphertext is never transformed under Alice's key.
	op.record=v.bob.content
	rejected:=hosted_with_access(&f.service,&ad,a,"client-fixture",hosted_test_transform,&op)
	testing.expect(t,rejected.error!="" && rejected.response=="")
	// No plaintext fallback for a truncated claimed envelope.
	op.record=make(json.Object,context.temp_allocator);op.record["title"]=json.String("vault:v2:broken")
	testing.expect(t,hosted_with_access(&f.service,&ad,a,"client-fixture",hosted_test_transform,&op).error!="")
}

@(test)
test_hosted_rotation_missing_wrap_delivery_without_reconnect_and_revocation :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	f:Delegation_Fixture
	if !delegation_fixture(t,&f) do return
	defer sqlite.close(&f.impl.conn)
	v:=hosted_vectors(t).alice
	clock:=platform.Clock{now=hosted_test_now};f.service.clock=&clock
	repo:iface.Vault_Directory_Repository
	directory:=hosted_test_directory(&v.initial,&repo,&clock)
	access:=hosted_test_authorize(t,&f,&v.initial,&directory)
	v.initial.directory=v.rotated_directory
	op:=Hosted_Test_Transform{record=v.rotated_content}
	missing:=hosted_with_access(&f.service,&directory,access,"client-fixture",hosted_test_transform,&op)
	testing.expect(t,missing.error=="decryption_unavailable" && op.calls==0)
	bad:=v.rotated_wrap;bad.wrap_json=v.initial.hosted.wrap_json
	testing.expect(t,deliver_connector_epoch(&f.service,&directory,v.initial.request.owner,v.initial.directory.root_device_id,bad).code!=.None,"stale epoch delivery refused")
	testing.expect(t,deliver_connector_epoch(&f.service,&directory,v.initial.request.owner,v.initial.directory.root_device_id,v.wrong_key_wrap).code==.None,"a signed ciphertext cannot be inspected without the client-held capability")
	wrong_keys:=hosted_with_access(&f.service,&directory,access,"client-fixture",hosted_test_transform,&op)
	testing.expect(t,wrong_keys.error=="decryption_unavailable" && op.calls==0,"signed wrap with wrong epoch keys fails the signed commit check")
	err:=deliver_connector_epoch(&f.service,&directory,v.initial.request.owner,v.initial.directory.root_device_id,v.rotated_wrap)
	testing.expectf(t,err.code==.None,"signed current-epoch delivery: %s",err.message)
	result:=hosted_with_access(&f.service,&directory,access,"client-fixture",hosted_test_transform,&op)
	testing.expectf(t,result.error=="" && strings.contains(result.response,"epoch two") && strings.contains(result.response,"usr_alice_fixture secret"),"same credential opens current and historical signed epochs: %s",result.error)
	delegation_response_wipe(&result)
	op.seal=true
	created:=hosted_with_access(&f.service,&directory,access,"client-fixture",hosted_test_transform,&op)
	_,sealed_epoch,_,sealed_result:=vault.envelope_header(op.sealed_title)
	testing.expect(t,created.error=="" && sealed_result==.Ok && sealed_epoch==2 && !strings.contains(op.sealed_title,"new chain"),"creation always seals under the verified current epoch")
	delegation_response_wipe(&created)
	testing.expect(t,delegation_revoke(&f.service,v.initial.request.owner,v.initial.request.grant).code==.None)
	testing.expect(t,hosted_with_access(&f.service,&directory,access,"client-fixture",hosted_test_transform,&op).error!="")
	testing.expect(t,deliver_connector_epoch(&f.service,&directory,v.initial.request.owner,v.initial.directory.root_device_id,v.rotated_wrap).code!=.None,"revocation stops future delivery")
	rows,rerr:=connector_recipients(&f.service,&directory,v.initial.request.owner)
	testing.expect(t,rerr.code==.None && len(rows)==0)
}

@(test)
test_hosted_rechecks_revocation_and_directory_after_transform :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	for change_directory in ([]bool{false,true}) {
		f:Delegation_Fixture
		if !delegation_fixture(t,&f) do return
		defer sqlite.close(&f.impl.conn)
		v:=hosted_vectors(t).alice
		clock:=platform.Clock{now=hosted_test_now};f.service.clock=&clock
		repo:iface.Vault_Directory_Repository
		directory:=hosted_test_directory(&v.initial,&repo,&clock)
		access:=hosted_test_authorize(t,&f,&v.initial,&directory)
		op:=Hosted_Test_Transform{record=v.content,owner=v.initial.request.owner,grant=v.initial.request.grant}
		if change_directory {op.vector=&v.initial;op.new_directory=v.rotated_directory} else {op.revoke=&f.service}
		result:=hosted_with_access(&f.service,&directory,access,"client-fixture",hosted_test_transform,&op)
		testing.expect(t,op.calls==1 && result.error!="" && result.response=="","no result escapes after concurrent revocation or rotation")
	}
}

@(test)
test_hosted_full_directory_chain_approvals_revocation_and_tampering :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	f:Delegation_Fixture
	if !delegation_fixture(t,&f) do return
	defer sqlite.close(&f.impl.conn)
	v:=hosted_vectors(t).alice
	clock:=platform.Clock{now=hosted_test_now};f.service.clock=&clock
	repo:iface.Vault_Directory_Repository
	directory:=hosted_test_directory(&v.initial,&repo,&clock)
	_ = hosted_test_authorize(t,&f,&v.initial,&directory)
	g,_,_:=delegation_read(&f.service,"grant",v.initial.request.grant)
	v.initial.directory=v.complex_directory
	verified,ok,err:=verified_grant_directory(&directory,g)
	testing.expect(t,ok && err.code==.None && len(verified.trusted)==2 && len(verified.ever_approved)==3 && verified.current_epoch==3,"full signed approval/revoke sequence verifies")
	for n in 0..<5 {
		v=hosted_vectors(t).alice
		v.initial.directory=v.complex_directory
		switch n {
		case 0: v.initial.directory.head_hash="tampered"
		case 1: v.initial.directory.log[1].seq=99
		case 2: v.initial.directory.log[1].signature.sig="00"
		case 3: v.initial.directory.current_epoch+=1
		case 4: v.initial.directory.devices[0].sign_public_key=v.initial.directory.devices[1].sign_public_key
		}
		_,accepted,_:=verified_grant_directory(&directory,g)
		testing.expect(t,!accepted,"bad links/signatures/metadata never yield partial trust")
	}
}
