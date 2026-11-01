package sqlite

import "core:testing"

@(test)
test_mcp_mutation_receipts_upgrade_isolation_and_rollback :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	conn,opened,_:=open(":memory:")
	if !testing.expect(t,opened) do return
	defer close(&conn)
	baseline,err:=run_migrations(&conn,"/missing-mcp-mutation-test","179_mcp_mutation_receipts.sql")
	if !testing.expect(t,baseline && err.code==.None) do return
	testing.expect(t,!sqlite_object_exists(&conn,"mcp_mutation_receipts"))
	for _ in 0..<2 {
		ok,merr:=run_migrations(&conn,"/missing-mcp-mutation-test")
		testing.expect(t,ok && merr.code==.None)
	}
	testing.expect(t,exec(&conn,"BEGIN IMMEDIATE;"))
	testing.expect(t,mcp_receipt_put(&conn,"alice","grant_a","tasks.comment","retry_a","digest_a","cmt_a").code==.None)
	digest,result,found,rerr:=mcp_receipt_get(&conn,"alice","grant_a","tasks.comment","retry_a")
	testing.expect(t,rerr.code==.None && found && digest=="digest_a" && result=="cmt_a")
	_,_,other,_:=mcp_receipt_get(&conn,"bob","grant_a","tasks.comment","retry_a")
	testing.expect(t,!other)
	testing.expect(t,mcp_receipt_put(&conn,"alice","grant_a","tasks.comment","retry_a","different","cmt_b").code!=.None)
	testing.expect(t,exec(&conn,"ROLLBACK;"))
	_,_,rolled_back,_:=mcp_receipt_get(&conn,"alice","grant_a","tasks.comment","retry_a")
	testing.expect(t,!rolled_back)
	testing.expect(t,mcp_receipt_put(&conn,"alice","grant_a","tasks.comment","retry_a","digest_a","cmt_a").code==.None)
	_,_,other_grant,_:=mcp_receipt_get(&conn,"alice","grant_b","tasks.comment","retry_a")
	testing.expect(t,!other_grant)
}
