package http

import "core:strings"
import "core:testing"
import agent_service "odin_test:hub/service/agent"
import project_service "odin_test:hub/service/project"
import live "odin_test:lib/tool_live"

@(test)
test_tool_stream_relay_connection_epoch_and_sequence :: proc(t:^testing.T) {
    agents := agent_service.Agent_Service{}
    h := Bridge_Handlers{agents=&agents}
    conn := project_service.Bridge_Runtime_Connection{owner_id="owner"}
    bridge_ws_tool_live_frame(&h,"brg",1,&conn,`{"type":"tool_stream_reset","epoch":"1000"}`)
    testing.expect_value(t,string(conn.tool_live_epoch[:conn.tool_live_epoch_len]),"1000")
    bridge_ws_tool_live_frame(&h,"brg",1,&conn,`{"type":"tool_stream_reset","epoch":"2000"}`)
    testing.expect_value(t,string(conn.tool_live_epoch[:conn.tool_live_epoch_len]),"1000")
    bridge_ws_tool_live_frame(&h,"brg",1,&conn,`{"type":"tool_stream_state","epoch":"2000","seq":10}`)
    testing.expect_value(t,conn.tool_live_seq,u64(0))
    bridge_ws_tool_live_frame(&h,"brg",1,&conn,`{"type":"tool_stream_state","epoch":"1000","seq":10}`)
    testing.expect_value(t,conn.tool_live_seq,u64(10))
    bridge_ws_tool_live_frame(&h,"brg",1,&conn,`{"type":"tool_stream_state","epoch":"1000","seq":9}`)
    testing.expect_value(t,conn.tool_live_seq,u64(10))
}
