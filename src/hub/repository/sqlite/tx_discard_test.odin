package sqlite

import "core:testing"
import iface "odin_test:hub/repository/iface"

Tx_Discard_Probe :: struct {runs,discards:int}
tx_discard_probe_run :: proc(ctx:rawptr) {p:=(^Tx_Discard_Probe)(ctx);p.runs+=1}
tx_discard_probe_discard :: proc(ctx:rawptr) {p:=(^Tx_Discard_Probe)(ctx);p.discards+=1}

@(test)
test_uow_hooks_cleanup_on_outer_nested_and_failed_commit :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	conn,opened,_:=open(":memory:")
	if !testing.expect(t,opened) do return
	defer close(&conn)
	impl:SQLite_Unit_Of_Work_Factory
	repos:iface.Repositories
	factory:=new_unit_of_work_factory(&impl,&conn,&repos)
	probe:Tx_Discard_Probe
	hook:=iface.After_Commit_Hook{ctx=&probe,run=tx_discard_probe_run,discard=tx_discard_probe_discard}
	for mode in 0..<3 {
		outer,outer_ok,_:=iface.unit_of_work_begin(&factory)
		if !testing.expect(t,outer_ok) do return
		inner,inner_ok,_:=iface.unit_of_work_begin(&factory)
		if !testing.expect(t,inner_ok) {iface.unit_of_work_rollback(&outer);return}
		testing.expect(t,iface.unit_of_work_after_commit(&inner,hook))
		if mode==1 {iface.unit_of_work_rollback(&inner)} else {ok,_:=iface.unit_of_work_commit(&inner);testing.expect(t,ok)}
		if mode==0 {iface.unit_of_work_rollback(&outer)} else {ok,_:=iface.unit_of_work_commit(&outer);testing.expect(t,ok)}
	}
	testing.expect(t,probe.discards==2 && probe.runs==1)
	testing.expect(t,exec(&conn,"PRAGMA foreign_keys=ON; CREATE TABLE hook_parent(id INTEGER PRIMARY KEY); CREATE TABLE hook_child(id INTEGER REFERENCES hook_parent(id) DEFERRABLE INITIALLY DEFERRED);"))
	outer,ok,_:=iface.unit_of_work_begin(&factory)
	if !testing.expect(t,ok) do return
	testing.expect(t,iface.unit_of_work_after_commit(&outer,hook))
	testing.expect(t,exec(&conn,"INSERT INTO hook_child(id) VALUES(999);"))
	committed,err:=iface.unit_of_work_commit(&outer)
	testing.expect(t,!committed && err.code!=.None)
	testing.expect(t,probe.discards==3 && probe.runs==1)
}
