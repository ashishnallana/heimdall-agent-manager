package taskv2

import "core:testing"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import project "odin_test:hub/service/project"
import agent "odin_test:hub/service/agent"

@(test)
test_nested_task_effects_rollback_releases_reservation :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	conn,opened,_:=sqlite.open(":memory:")
	if !testing.expect(t,opened) do return
	defer sqlite.close(&conn)
	impl:sqlite.SQLite_Unit_Of_Work_Factory
	repos:iface.Repositories
	factory:=sqlite.new_unit_of_work_factory(&impl,&conn,&repos)
	registry:project.Bridge_Runtime_Registry
	defer project.bridge_runtime_registry_destroy(&registry)
	project.bridge_runtime_registry_mark_live(&registry,"brg_rollback",false,"")
	generation:=project.bridge_runtime_registry_generation(&registry,"brg_rollback")
	agent_service:=agent.Agent_Service{bridge_runtime_registry=&registry}
	service:=Service{uow_factory=&factory,agent_service=&agent_service}
	outer,ok,_:=iface.unit_of_work_begin(&factory)
	if !testing.expect(t,ok) do return
	inner,inner_ok,_:=begin_uow(&service)
	if !testing.expect(t,inner_ok) {iface.unit_of_work_rollback(&outer);return}
	_,accepted,err:=project.bridge_runtime_instance_apply(&registry,"brg_rollback",generation,"inst_rollback","synthetic_owner","launching","idle",0,reserve=true)
	testing.expect(t,accepted && err.code==.None)
	append(&inner.effects.reservations,Jit_Reservation{"brg_rollback",generation,"inst_rollback"})
	committed,cerr:=end_uow(&service,&inner,true)
	testing.expect(t,committed && cerr.code==.None)
	_,reserved:=project.bridge_runtime_instance_get(&registry,"brg_rollback",generation,"inst_rollback")
	testing.expect(t,reserved)
	iface.unit_of_work_rollback(&outer)
	_,leaked:=project.bridge_runtime_instance_get(&registry,"brg_rollback",generation,"inst_rollback")
	testing.expect(t,!leaked,"outer rollback must release the nested engine launch reservation")
}
