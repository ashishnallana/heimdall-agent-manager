package main

import "base:runtime"
import "core:strings"
import "core:testing"
import ws "odin_test:lib/ws"

@(test)
test_mcp_dispatch_never_caches_plaintext_worker_results :: proc(t:^testing.T) {
	old_worker:=bridge_dispatch_workers[0]
	old_outputs,old_claims:=bridge_dispatch_outputs,bridge_dispatch_claims
	old_bytes,old_cost,old_owned:=bridge_dispatch_outbox_bytes,bridge_dispatch_queued_cost,bridge_dispatch_owned_bytes
	old_metrics:=bridge_dispatch_metrics
	defer {
		for output in bridge_dispatch_outputs do delete(output.text,runtime.default_allocator())
		delete(bridge_dispatch_outputs)
		for claim in bridge_dispatch_claims {delete(claim.command_id,runtime.default_allocator());delete(claim.result_json,runtime.default_allocator())}
		delete(bridge_dispatch_claims)
		bridge_dispatch_workers[0]=old_worker;bridge_dispatch_outputs=old_outputs;bridge_dispatch_claims=old_claims
		bridge_dispatch_outbox_bytes=old_bytes;bridge_dispatch_queued_cost=old_cost;bridge_dispatch_owned_bytes=old_owned;bridge_dispatch_metrics=old_metrics
	}
	bridge_dispatch_outputs=make([dynamic]Bridge_Dispatch_Output,runtime.default_allocator())
	bridge_dispatch_claims=make([dynamic]Bridge_Dispatch_Claim,runtime.default_allocator())
	bridge_dispatch_outbox_bytes=0;bridge_dispatch_queued_cost=0;bridge_dispatch_owned_bytes=0
	worker:=&bridge_dispatch_workers[0]
	worker^={current_command_id=strings.clone("mcp_fixture",runtime.default_allocator()),current_generation=3}
	append(&bridge_dispatch_claims,Bridge_Dispatch_Claim{command_id=strings.clone("mcp_fixture",runtime.default_allocator()),state=.Running})
	testing.expect(t,bridge_command_worker_capture_send(&worker.sink_conn,`{"type":"mcp_transform_result","reply":{"result":"private reply"}}`))
	testing.expect(t,worker.last_result=="" && len(bridge_dispatch_outputs)==1 && bridge_dispatch_outputs[0].sensitive)
	job:=Bridge_Dispatch_Job{text=strings.clone("private request",runtime.default_allocator()),command_id=strings.clone("mcp_fixture",runtime.default_allocator()),command_type=strings.clone("mcp_transform",runtime.default_allocator())}
	bridge_command_dispatch_finish(worker,&job)
	testing.expect(t,bridge_dispatch_claims[0].state==.Completed && bridge_dispatch_claims[0].result_json=="")
	closed:ws.Connection
	bridge_command_dispatch_drain(&closed,3)
	testing.expect_value(t,len(bridge_dispatch_outputs),0)
	testing.expect_value(t,bridge_dispatch_outbox_bytes,0)
}
