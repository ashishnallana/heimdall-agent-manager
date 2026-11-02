package mcp

import "core:encoding/json"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:os"
import "core:fmt"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import auth "odin_test:hub/service/auth"

Delegation_Fixture :: struct {
	impl: sqlite.MCP_Repo_SQLite,
	repo: iface.MCP_Repository,
	service: Delegation_Service,
	key: [1]Envelope_Key,
}
delegation_fixture :: proc(t: ^testing.T, f: ^Delegation_Fixture, path := ":memory:") -> bool {
	repo, err := sqlite.open_mcp_repository(&f.impl, path)
	testing.expect(t, err.code == .None)
	if err.code != .None do return false
	if !sqlite.exec(&f.impl.conn, #load("../../repository/sqlite/migrations/175_mcp_delegated_credentials.sql", string)) do return false
	if !sqlite.exec(&f.impl.conn, #load("../../repository/sqlite/migrations/176_mcp_epoch_wraps.sql", string)) do return false
	f.repo = repo
	f.key[0].id = "test"; f.key[0].bytes[0] = 9
	f.service = {repo = &f.repo, keys = f.key[:], issuer = "https://hub", resource = "https://hub/api/v1/mcp", authority = proc(ctx: rawptr, g: domain.MCP_Record) -> (bool, domain.Domain_Error) {return true, {}}}
	return true
}

Refresh_Job :: struct {
	service: ^Delegation_Service,
	raw: string,
	response_hash: [64]byte,
	succeeded, busy: bool,
}
refresh_job :: proc(job: ^Refresh_Job) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	result := delegation_redeem(job.service,job.raw,"refresh","claude","","",2000)
	job.succeeded=result.error==""
	job.busy=result.error=="temporarily_unavailable"
	if job.succeeded do copy(job.response_hash[:],auth.sha256_hex(result.response))
	delegation_response_wipe(&result)
}

@(test)
test_delegation_concurrent_refresh_has_one_successor :: proc(t: ^testing.T) {
	context.allocator=context.temp_allocator
	f:Delegation_Fixture
	if !delegation_fixture(t,&f) do return
	defer sqlite.close(&f.impl.conn)
	code:=delegation_test_seed(t,&f,"race-family")
	first:=delegation_test_tokens(t,delegation_redeem(&f.service,code,"code","claude","https://client/callback","aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",1001))
	jobs:[8]Refresh_Job
	threads:[8]^thread.Thread
	for i in 0..<len(jobs) {
		jobs[i]={service=&f.service,raw=first.refresh_token}
		threads[i]=thread.create_and_start_with_poly_data(&jobs[i],refresh_job)
	}
	for th in threads {thread.join(th);thread.destroy(th)}
	successes,busy:=0,0
	expected:[64]byte
	for job in jobs {
		if job.succeeded {
			if successes==0 do expected=job.response_hash
			testing.expect(t,job.response_hash==expected,"every successful concurrent redemption returns identical bytes")
			successes+=1
		}
		if job.busy do busy+=1
	}
	testing.expect(t,successes==4 && busy==4)
}

Dump_Operation :: struct {text:string}
dump_mcp_rows :: proc(tx:iface.MCP_Transaction,ctx:rawptr)->domain.Domain_Error {
	op:=(^Dump_Operation)(ctx)
	for kind in ([]string{"grant","family","code","access","refresh"}) {
		rows,err:=tx.list(tx.ctx,kind,"alice")
		if err.code!=.None do return err
		bytes,_:=json.marshal(rows,allocator=context.temp_allocator)
		op.text=strings.concatenate({op.text,string(bytes)},context.temp_allocator)
	}
	return {}
}

@(test)
test_delegation_restart_retry_and_database_non_persistence :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	id,_:=auth.random_token()
	path:=fmt.tprintf("%s/mcp-%s.db",os.temp_dir(context.temp_allocator),id)
	defer _=os.remove(path)
	f:Delegation_Fixture
	if !delegation_fixture(t,&f,path) do return
	defer sqlite.close(&f.impl.conn)
	code:=delegation_test_seed(t,&f,"restart-family")
	first:=delegation_test_tokens(t,delegation_redeem(&f.service,code,"code","claude","https://client/callback","aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",1001))
	rotated:=delegation_redeem(&f.service,first.refresh_token,"refresh","claude","","",2000)
	next:=delegation_test_tokens(t,rotated)
	dump:Dump_Operation
	err:=iface.mcp_transaction(&f.repo,dump_mcp_rows,&dump)
	testing.expect(t,err.code==.None)
	for secret in ([]string{code,first.access_token,first.refresh_token,next.access_token,next.refresh_token,"test-private-capability",rotated.response}) do testing.expect(t,!strings.contains(dump.text,secret),"no server-recoverable credential/capability in metadata")
	sqlite.close(&f.impl.conn)
	// Inspect actual on-disk SQLite bytes too, not merely decoded model rows.
	bytes,read_err:=os.read_entire_file(path,context.temp_allocator)
	testing.expect(t,read_err==nil)
	for secret in ([]string{code,first.access_token,first.refresh_token,next.access_token,next.refresh_token,"test-private-capability"}) do testing.expect(t,!strings.contains(string(bytes),secret),"no raw credential/capability in DB pages")
	reopened,reopen_err:=sqlite.open_mcp_repository(&f.impl,path)
	testing.expect(t,reopen_err.code==.None)
	f.repo=reopened
	retry:=delegation_redeem(&f.service,first.refresh_token,"refresh","claude","","",2001)
	testing.expect(t,retry.error=="" && retry.response==rotated.response,"restart preserves identical successor retry")
	f.key[0].bytes[0]+=1
	testing.expect(t,delegation_redeem(&f.service,first.refresh_token,"refresh","claude","","",2002).error=="invalid_grant")
	f.key[0].bytes[0]-=1
	testing.expect(t,delegation_redeem(&f.service,next.access_token,"access","claude","","",2002).error=="","wrong key cannot revoke a family")
	testing.expect(t,sqlite.mcp_cleanup(&f.impl,32000).code==.None)
	row,found,rerr:=delegation_read(&f.service,"refresh",auth.sha256_hex(first.refresh_token))
	testing.expect(t,rerr.code==.None && found && row.retry_capsule=="" && row.consumed,"cleanup removes capsule, retains authenticated replay tombstone")
	testing.expect(t,delegation_redeem(&f.service,first.refresh_token,"refresh","claude","","",32000).error=="invalid_grant")
}
Seed_Op :: struct {claims: Credential_Claims, raw: string}
seed_delegation :: proc(tx: iface.MCP_Transaction, ctx: rawptr) -> domain.Domain_Error {
	op := (^Seed_Op)(ctx)
	row := credential_metadata(op.claims, op.raw)
	if err := tx.put(tx.ctx, domain.MCP_Record{kind="client",id=row.client}); err.code != .None do return err
	if err := tx.put(tx.ctx, row); err.code != .None do return err
	g := row; g.kind = "grant"; g.id = row.grant
	if err := tx.put(tx.ctx, g); err.code != .None do return err
	f := row; f.kind = "family"; f.id = row.family
	return tx.put(tx.ctx, f)
}
delegation_test_seed :: proc(t: ^testing.T, f: ^Delegation_Fixture, family: string) -> string {
	c := Credential_Claims{kind = "code", issuer = f.service.issuer, resource = f.service.resource, owner = "alice", client = "claude", scope = DELEGATION_SCOPE, grant = family, family = family, revision = 1, issued_ms = 1000, expires_ms = 121000, vault_id = "vault", jti = family, redirect = "https://client/callback", challenge = auth.pkce_challenge_s256("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), private_capability = "test-private-capability"}
	raw, ok := credential_seal(&f.key[0], c)
	testing.expect(t, ok)
	op := Seed_Op{c, raw}
	err := iface.mcp_transaction(&f.repo, seed_delegation, &op)
	testing.expect(t, err.code == .None)
	return raw
}
delegation_test_tokens :: proc(t: ^testing.T, r: Delegation_Result) -> Tokens {
	testing.expect(t, r.error == "" && r.response != "")
	tokens: Tokens
	err := json.unmarshal(transmute([]byte)r.response, &tokens, .JSON, context.temp_allocator)
	testing.expect(t, err == nil)
	return tokens
}

@(test)
test_delegation_pkce_refresh_retry_expiry_replay_and_family_isolation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f: Delegation_Fixture
	if !delegation_fixture(t, &f) do return
	defer sqlite.close(&f.impl.conn)
	code := delegation_test_seed(t, &f, "f1")
	other_code := delegation_test_seed(t, &f, "f2")
	testing.expect(t, delegation_redeem(&f.service, code, "code", "other-client", "https://client/callback", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 1001).error == "invalid_grant")
	testing.expect(t, delegation_redeem(&f.service, code, "code", "claude", "https://client/callback", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", 1001).error == "invalid_grant")
	first := delegation_test_tokens(t, delegation_redeem(&f.service, code, "code", "claude", "https://client/callback", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 1001))
	other := delegation_test_tokens(t, delegation_redeem(&f.service, other_code, "code", "claude", "https://client/callback", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 1001))
	testing.expect(t, delegation_redeem(&f.service, code, "code", "claude", "https://client/callback", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 1002).error == "invalid_grant")
	access := delegation_redeem(&f.service, first.access_token, "access", "claude", "", "", 601000)
	testing.expect(t, access.error == "" && access.claims.private_capability == "test-private-capability")
	delegation_response_wipe(&access)
	testing.expect(t, delegation_redeem(&f.service, first.access_token, "access", "claude", "", "", 601001).error == "invalid_grant")
	rotated := delegation_redeem(&f.service, first.refresh_token, "refresh", "claude", "", "", 601001)
	successor := delegation_test_tokens(t, rotated)
	for n in 0..<3 {
		retried := delegation_redeem(&f.service, first.refresh_token, "refresh", "claude", "", "", 601002+i64(n))
		testing.expect(t, retried.error == "" && retried.response == rotated.response)
	}
	testing.expect(t, delegation_redeem(&f.service, first.refresh_token, "refresh", "claude", "", "", 601010).error == "temporarily_unavailable")
	// Duplicate exhaustion must not revoke the working successor.
	testing.expect(t, delegation_redeem(&f.service, successor.access_token, "access", "claude", "", "", 601011).error == "")
	// Forged and wrong-client refresh requests cannot revoke the family.
	forged := strings.clone(first.refresh_token, context.temp_allocator)
	(transmute([]byte)forged)[len(forged)-10] = '!'
	testing.expect(t, delegation_redeem(&f.service, forged, "refresh", "claude", "", "", 640000).error == "invalid_grant")
	testing.expect(t, delegation_redeem(&f.service, first.refresh_token, "refresh", "wrong-client", "", "", 640000).error == "invalid_grant")
	testing.expect(t, delegation_redeem(&f.service, successor.access_token, "access", "claude", "", "", 640000).error == "")
	testing.expect(t, delegation_redeem(&f.service, first.refresh_token, "refresh", "claude", "", "", 631001).error == "invalid_grant")
	testing.expect(t, delegation_redeem(&f.service, successor.access_token, "access", "claude", "", "", 640001).error == "invalid_grant")
	testing.expect(t, delegation_redeem(&f.service, other.refresh_token, "refresh", "claude", "", "", 640001).error == "")
	// Owner-bound disconnect cannot be used by another user.
	testing.expect(t, delegation_revoke(&f.service, "bob", "f2").code == .Not_Found)
	testing.expect(t, delegation_revoke(&f.service, "alice", "f2").code == .None)
	testing.expect(t, delegation_redeem(&f.service, other.refresh_token, "refresh", "claude", "", "", 640002).error == "invalid_grant")
}
