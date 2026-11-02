package events

import "core:testing"

@(test)
test_poll_hints_owner_isolation_capacity_and_late_detach :: proc(t:^testing.T) {
	bus:User_Event_Bus
	a,aok:=poll_attach(&bus,"alice");b,bok:=poll_attach(&bus,"bob")
	testing.expect(t,aok && bok)
	publish_resource_changed(&bus,"bob","task","task_bob","updated","")
	testing.expect_value(t,poll_revision(&bus,a),u64(0))
	testing.expect_value(t,poll_revision(&bus,b),u64(1))
	poll_detach(&bus,a)
	c,cok:=poll_attach(&bus,"carol");testing.expect(t,cok && c.slot==a.slot && c.generation!=a.generation)
	poll_detach(&bus,a)
	publish_resource_changed(&bus,"carol","task_chain","chain_carol","updated","")
	testing.expect_value(t,poll_revision(&bus,c),u64(1))
	handles:[62]Poll_Hint
	for &h in handles {var_ok:bool;h,var_ok=poll_attach(&bus,"alice");testing.expect(t,var_ok)}
	_,overflow:=poll_attach(&bus,"alice");testing.expect(t,!overflow)
	for h in handles do poll_detach(&bus,h)
	poll_detach(&bus,b);poll_detach(&bus,c)
	for slot in bus.poll_slots do testing.expect(t,!slot.active && slot.owner=="")
}

@(test)
test_poll_hints_filter_requested_chain :: proc(t:^testing.T) {
	bus:User_Event_Bus
	h,ok:=poll_attach(&bus,"alice","chain_a");testing.expect(t,ok);defer poll_detach(&bus,h)
	publish_resource_changed(&bus,"alice","task_chain","chain_b","updated","")
	publish_resource_changed(&bus,"bob","task_chain","chain_a","updated","")
	testing.expect_value(t,poll_revision(&bus,h),u64(0))
	publish_resource_changed(&bus,"alice","task","task_a","updated",`{"chain_id":"chain_a"}`)
	testing.expect_value(t,poll_revision(&bus,h),u64(1))
}
