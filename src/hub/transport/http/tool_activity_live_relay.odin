package http

import "core:encoding/json"
import "core:time"
import "core:sync"
import agent_service "odin_test:hub/service/agent"
import events "odin_test:hub/service/events"
import project_service "odin_test:hub/service/project"
import live "odin_test:lib/tool_live"

bridge_ws_tool_live_frame :: proc(h: ^Bridge_Handlers, bridge_id: string, generation: int, conn: ^project_service.Bridge_Runtime_Connection, raw: string) {
    if h.agents == nil || conn == nil || !live.wire_shape_ok(raw) || sync.atomic_load(&conn.retired) do return
    // No content queue: bounded per-connection token budget then synchronous
    // owner-scoped delivery. Slow sockets are removed by the existing writer's
    // 5-second deadline; the user stream gap/resync protocol recovers fresh state.
    now := time.to_unix_nanoseconds(time.now())
    if conn.tool_live_refill_ns == 0 || now - conn.tool_live_refill_ns >= i64(time.Second) {
        conn.tool_live_tokens = 128; conn.tool_live_bytes = 4 * 1024 * 1024
        conn.tool_live_refill_ns = now; conn.tool_live_rate_notified = false
    }
    if conn.tool_live_tokens <= 0 || conn.tool_live_bytes < len(raw) {
        if !conn.tool_live_rate_notified {
            conn.tool_live_rate_notified = true
            frame := struct {type, bridge_id: string}{"tool_activity_live_resync", bridge_id}
            data, _ := json.marshal(frame, allocator = context.temp_allocator)
            events.publish_raw_to_user(h.agents.event_bus, conn.owner_id, string(data))
        }
        return
    }
    conn.tool_live_tokens -= 1; conn.tool_live_bytes -= len(raw)
    value, err := json.parse_string(raw, .JSON, true, context.temp_allocator)
    if err != .None do return
    root, ok := value.(json.Object)
    if !ok do return
    kind := agent_service.tool_live_text(root, "type")
    epoch := agent_service.tool_live_text(root, "epoch")
    if kind == "tool_activity_live_reset" {
        if len(epoch) == 0 || len(epoch) > 32 do return
        for c in transmute([]u8)epoch do if c < 48 || c > 57 do return
        if conn.tool_live_epoch_len != 0 && epoch != string(conn.tool_live_epoch[:conn.tool_live_epoch_len]) do return
        conn.tool_live_epoch_len = len(epoch)
        copy(conn.tool_live_epoch[:], transmute([]u8)epoch)
        return
    }
    if kind == "tool_activity_live_resync" {
        if conn.tool_live_epoch_len == 0 do return
        frame := struct {type, bridge_id: string}{"tool_activity_live_resync", bridge_id}
        data, _ := json.marshal(frame, allocator = context.temp_allocator)
        events.publish_raw_to_user(h.agents.event_bus, conn.owner_id, string(data))
        return
    }
    if conn.tool_live_epoch_len == 0 || epoch != string(conn.tool_live_epoch[:conn.tool_live_epoch_len]) do return
    if kind == "tool_activity_live_snapshot" {
        seq, good := root["seq"].(json.Integer)
        if !good || seq < 1 || u64(seq) <= conn.tool_live_seq do return
        conn.tool_live_seq = u64(seq)
    }
    _ = agent_service.tool_live_apply_bridge(h.agents, bridge_id, generation, epoch, raw)
}
