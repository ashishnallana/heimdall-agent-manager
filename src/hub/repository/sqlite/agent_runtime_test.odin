package sqlite

import "core:testing"
import iface "odin_test:hub/repository/iface"

@(test)
test_runtime_intent_upgrade_busy_guard_and_receipt_isolation :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	conn,opened,_:=open(":memory:");if !testing.expect(t,opened) do return
	defer close(&conn)
	ok,err:=run_migrations(&conn,"/missing-runtime-migration","181_mcp_runtime_intents.sql");if !testing.expect(t,ok && err.code==.None) do return
	testing.expect(t,!sqlite_object_exists(&conn,"idx_mcp_runtime_intents"))
	for _ in 0..<2 {ok,err=run_migrations(&conn,"/missing-runtime-migration");testing.expect(t,ok && err.code==.None)}
	testing.expect(t,sqlite_object_exists(&conn,"idx_mcp_runtime_intents"))
	impl:Agent_Repo_SQLite;repo:=new_agent_repository(&impl,&conn)
	busy,read_err:=iface.agent_runtime_busy(&repo,"inst_runtime");testing.expect(t,!busy && read_err.code==.None)
	// Other mutation receipts and old empty result_json rows are harmless.
	testing.expect(t,mcp_receipt_put(&conn,"owner","grant","tasks.comment","old","digest","inst_runtime").code==.None)
	testing.expect(t,mcp_receipt_put(&conn,"owner","grant","instances.start","start","digest","inst_runtime",`{"result":{"phase":"prepared"}}`).code==.None)
	busy,read_err=iface.agent_runtime_busy(&repo,"inst_runtime");testing.expect(t,busy && read_err.code==.None)
	busy,_=iface.agent_runtime_busy(&repo,"inst_other");testing.expect(t,!busy)
	testing.expect(t,mcp_runtime_receipt_update(&conn,"foreign","grant","instances.start","start",`{"result":{"phase":"awaiting_runtime"}}`).code==.None)
	busy,_=iface.agent_runtime_busy(&repo,"inst_runtime");testing.expect(t,busy,"foreign update must leave original intent blocked")
	testing.expect(t,mcp_runtime_receipt_update(&conn,"owner","grant","tasks.comment","old","{}").code!=.None,"task receipts stay immutable")
	testing.expect(t,mcp_runtime_receipt_update(&conn,"owner","grant","instances.start","start",`{"result":{"phase":"awaiting_runtime"}}`).code==.None)
	busy,_=iface.agent_runtime_busy(&repo,"inst_runtime");testing.expect(t,!busy)
	testing.expect(t,mcp_runtime_receipt_update(&conn,"owner","grant","instances.start","start",`{"result":{"phase":"launch_unconfirmed","status":"repair_required"}}`).code==.None)
	busy,_=iface.agent_runtime_busy(&repo,"inst_runtime");testing.expect(t,busy,"ambiguous send also excludes new task grants")
}
