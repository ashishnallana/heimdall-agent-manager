package http

import "core:encoding/json"
import "core:sync"
import agent_service "odin_test:hub/service/agent"
import project_service "odin_test:hub/service/project"
import live "odin_test:lib/tool_live"

bridge_ws_tool_live_frame :: proc(h: ^Bridge_Handlers, bridge_id: string, generation: int, conn: ^project_service.Bridge_Runtime_Connection, raw: string) {
    if h.agents == nil || conn == nil || !live.wire_shape_ok(raw) || sync.atomic_load(&conn.retired) do return
    value, err := json.parse_string(raw, .JSON, true, context.temp_allocator)
    if err != .None do return
    root, ok := value.(json.Object)
    if !ok do return
    kind := agent_service.tool_live_text(root, "type")
    epoch := agent_service.tool_live_text(root, "epoch")
    if kind == "tool_stream_reset" {
        if len(epoch) == 0 || len(epoch) > 32 do return
        for c in transmute([]u8)epoch do if c < 48 || c > 57 do return
        if conn.tool_live_epoch_len != 0 do return
        conn.tool_live_epoch_len = len(epoch)
        copy(conn.tool_live_epoch[:], transmute([]u8)epoch)
        agent_service.tool_stream_bridge_ready(h.agents, bridge_id, generation)
        return
    }
    if (kind != "tool_stream_state" && kind != "tool_stream_unavailable") || conn.tool_live_epoch_len == 0 || epoch != string(conn.tool_live_epoch[:conn.tool_live_epoch_len]) do return
    seq, good := root["seq"].(json.Integer)
    if !good || seq < 1 || u64(seq) <= conn.tool_live_seq do return
    conn.tool_live_seq = u64(seq)
    _ = agent_service.tool_live_apply_bridge(h.agents, bridge_id, generation, epoch, raw)
}
