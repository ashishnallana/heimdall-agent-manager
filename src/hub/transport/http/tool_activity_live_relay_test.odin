package http

import "core:strings"
import "core:testing"
import agent_service "odin_test:hub/service/agent"
import project_service "odin_test:hub/service/project"
import live "odin_test:lib/tool_live"

@(test)
test_live_relay_connection_epoch_sequence_and_rate_budget :: proc(t:^testing.T) {
    agents := agent_service.Agent_Service{}
    h := Bridge_Handlers{agents=&agents}
    conn := project_service.Bridge_Runtime_Connection{owner_id="owner"}
    bridge_ws_tool_live_frame(&h,"brg",1,&conn,`{"type":"tool_activity_live_reset","epoch":"1000"}`)
    testing.expect_value(t,string(conn.tool_live_epoch[:conn.tool_live_epoch_len]),"1000")
    bridge_ws_tool_live_frame(&h,"brg",1,&conn,`{"type":"tool_activity_live_reset","epoch":"2000"}`)
    testing.expect_value(t,string(conn.tool_live_epoch[:conn.tool_live_epoch_len]),"1000")
    bridge_ws_tool_live_frame(&h,"brg",1,&conn,`{"type":"tool_activity_live_snapshot","epoch":"2000","seq":10}`)
    testing.expect_value(t,conn.tool_live_seq,u64(0))
    bridge_ws_tool_live_frame(&h,"brg",1,&conn,`{"type":"tool_activity_live_snapshot","epoch":"1000","seq":10}`)
    testing.expect_value(t,conn.tool_live_seq,u64(10))
    bridge_ws_tool_live_frame(&h,"brg",1,&conn,`{"type":"tool_activity_live_snapshot","epoch":"1000","seq":9}`)
    testing.expect_value(t,conn.tool_live_seq,u64(10))
    conn.tool_live_tokens=0
    bridge_ws_tool_live_frame(&h,"brg",1,&conn,`{"type":"tool_activity_live_snapshot","epoch":"1000","seq":11}`)
    testing.expect_value(t,conn.tool_live_seq,u64(10))
    testing.expect(t,conn.tool_live_rate_notified)
    testing.expect(t,!live.wire_shape_ok(strings.repeat("a",live.MAX_FRAME_BYTES+1,context.temp_allocator)))
}
