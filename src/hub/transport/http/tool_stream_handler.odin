package http

import "base:runtime"
import "core:encoding/json"
import "core:mem/virtual"
import "core:net"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import agent_service "odin_test:hub/service/agent"
import live "odin_test:lib/tool_live"

tool_stream_pong :: proc(ctx: rawptr, socket: net.TCP_Socket, payload: string) -> bool {
    return agent_service.tool_stream_write((^agent_service.Agent_Service)(ctx), socket, payload, 0xA)
}
tool_stream_error :: proc(h: ^Agent_Handlers, client: net.TCP_Socket, code, message: string) {
    data, _ := json.marshal(struct {type, code, message: string}{"error", code, message}, allocator = context.temp_allocator)
    _ = agent_service.tool_stream_write(h.agents, client, string(data))
}
// Dedicated JSON stream; uses the existing single-use user WS ticket mechanism.
tool_stream_handler :: proc(ctx: rawptr, req: Request, client: net.TCP_Socket) {
    h := (^Agent_Handlers)(ctx)
    auth: contracts.Auth_Context
    if ticket := query_value(req.query, "ticket"); ticket != "" {
        c, ok := user_ws_ticket_store_consume(h.ws_tickets, ticket)
        if !ok {
            write_stream_error(client, respond_error(domain.domain_error(.Unauthenticated, "invalid websocket ticket"), req.request_id))
            return
        }
        auth = c
    } else {
        c, ok, resp := require_auth(h.auth, req)
        if !ok { write_stream_error(client, resp); return }
        auth = c
    }
    if auth.user_id == "" || (auth.kind != .Trusted_Proxy && auth.kind != .User_Token) {
        write_stream_error(client, respond_error(domain.domain_error(.Forbidden, "user authentication required"), req.request_id))
        return
    }
    key := header_value(req.headers, "Sec-WebSocket-Key")
    if key == "" {
        write_stream_error(client, respond_error(domain.domain_error(.Validation_Failed, "missing websocket key"), req.request_id))
        return
    }
    if !write_user_ws_upgrade_response(client, user_ws_accept_key(key)) do return
    // The request arena lives for this whole upgraded socket. Reader buffers
    // use the heap; JSON/repository scratch is reclaimed after every frame.
    context.allocator = runtime.heap_allocator()
    viewer := agent_service.tool_stream_open(h.agents, auth.user_id, client)
    if viewer == nil do return
    // The HTTP request reader is the socket owner. Stop/join the sole writer
    // before returning to the router, which closes the descriptor.
    defer agent_service.tool_stream_close(h.agents, viewer)
    reader := bridge_ws_reader_make(client)
    reader.control_context = h.agents; reader.control_writer = tool_stream_pong
    reader.max_buffer_bytes = 32 * 1024
    defer bridge_ws_reader_destroy(&reader)
    for {
        scratch: virtual.Arena
        if virtual.arena_init_growing(&scratch) != nil do return
        defer virtual.arena_destroy(&scratch)
        context.temp_allocator = virtual.arena_allocator(&scratch)
        text, got, why := bridge_ws_read_frame(&reader, 120 * time.Second)
        if !got {
            // An idle display is live even when no tools run. Timeouts are wakes,
            // not EOF; ping/pong remains available for browser liveness checks.
            if why == .Read_Deadline do continue
            return
        }
        if reader.last_opcode != 0x1 || len(text) > 32 * 1024 || !live.wire_shape_ok(text) {
            delete(text)
            tool_stream_error(h, client, "invalid_frame", "expected bounded JSON text")
            continue
        }
        value, err := json.parse_string(text, .JSON, true, context.temp_allocator)
        delete(text)
        root, is_obj := value.(json.Object)
        if err != .None || !is_obj { tool_stream_error(h, client, "invalid_frame", "expected JSON object"); continue }
        switch agent_service.tool_live_text(root, "type") {
        case "ping":
            _ = agent_service.tool_stream_write(h.agents, client, `{"type":"pong"}`)
        case "subscribe":
            array, is_array := root["instance_ids"].(json.Array)
            if !is_array || len(array) > live.TOOL_LIVE_MAX_INSTANCES { tool_stream_error(h, client, "invalid_subscription", "instance_ids must contain at most 256 strings"); continue }
            ids := make([]string, len(array), context.temp_allocator)
            valid := true
            for item, i in array {
                id, is_string := item.(json.String)
                if !is_string { valid = false; break }
                ids[i] = string(id)
            }
            if !valid { tool_stream_error(h, client, "invalid_subscription", "instance IDs must be strings"); continue }
            if code := agent_service.tool_stream_subscribe(h.agents, viewer, ids); code != "" do tool_stream_error(h, client, code, "subscription replacement rejected")
        case:
            tool_stream_error(h, client, "unknown_type", "expected subscribe or ping")
        }
    }
}
