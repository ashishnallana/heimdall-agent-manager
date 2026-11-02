package taskv2

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

@(test)
test_runtime_intent_prevents_matching_and_direct_lease_grant :: proc(t:^testing.T) {
	fx,log,ok:=lease_fixture(t,"runtime_intent_lease")
	defer lease_fixture_close(fx,log);if !ok do return
	chain:=seed_live_chain(t,fx,"chain_runtime_guard")
	seed_fleet(fx,chain,"agt_w",capacity=1)
	inst:=seed_instance(fx,chain,"inst_runtime_worker","agt_w","br_1","idle")
	testing.expect(t,sqlite.mcp_receipt_put(&fx.conn,"u1","runtime_grant","instances.stop","stop_once","digest",inst.agent_instance_id,`{"result":{"phase":"prepared"}}`).code==.None)
	task:=publish_task(t,fx,chain,"task_runtime_guard")
	_,held:=lease_of(fx,inst.agent_instance_id)
	testing.expect(t,!held && !wake_log_has_run(log,inst.agent_instance_id),"pending intent excludes matching and unsolicited wake")
	rows,_:=iface.agent_list_instances_by_chain(&fx.agents,"u1",string(chain.chain_id))
	testing.expect(t,len(rows)==2,"pending instance counts toward capacity; no duplicate JIT session")
	u,begun,_:=begin_uow(&fx.svc);if !testing.expect(t,begun) do return
	_,granted,err:=grant_in_uow(&fx.svc,&u,{chain=chain,task=task,instance=inst,kind=domain.LEASE_KIND_WORK,placement={bridge_id="br_1"},actor=hub_actor()})
	end_uow(&fx.svc,&u,false)
	testing.expect(t,!granted && err.code==.Conflict,"final grant guard protects explicit pulls too")
	testing.expect(t,sqlite.mcp_runtime_receipt_update(&fx.conn,"u1","runtime_grant","instances.stop","stop_once",`{"result":{"phase":"awaiting_runtime"}}`).code==.None)
	u,begun,_=begin_uow(&fx.svc);if !testing.expect(t,begun) do return
	_,granted,err=grant_in_uow(&fx.svc,&u,{chain=chain,task=task,instance=inst,kind=domain.LEASE_KIND_WORK,placement={bridge_id="br_1"},actor=hub_actor()})
	end_uow(&fx.svc,&u,granted)
	testing.expect(t,granted && err.code==.None,"native acceptance releases the temporary intent guard")
}
