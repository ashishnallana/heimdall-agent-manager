package http

// REQ-XM-4 — hub side of the bridge→hub proxy path.
//
// The preview route (shell_session_handlers.odin) has the hub originate a stream toward
// a bridge: a browser hits /api/v1/preview/{session}/**, the hub opens a tunnel, the
// target bridge dials 127.0.0.1:{server_port}, bytes come back. This file is that path
// pointed the other way. A bridge originates the stream over the runtime WebSocket it
// already holds, and the hub splices it to the target bridge using the SAME tunnel
// machinery — so only the near end is new.
//
//   process on host A
//     → bridge A local endpoint (local_proxy.odin)   proxy_open/proxy_data/proxy_close
//       → hub (this file)                            tunnel_open/tunnel_data/tunnel_close
//         → bridge B → 127.0.0.1:{server_port}
//
// Nothing here opens an inbound port and no user bearer token or browser session appears
// anywhere in the chain — the point of the task, since the hub sits behind Authentik
// forward auth which rejects machine-originated requests before they reach it.
//
// The far end (tunnel_open → loopback dial → tunnel_data) is committed, verified, and
// deliberately untouched. The loopback-only fence on the target bridge stays exactly as
// it is.

import base64 "core:encoding/base64"
import "base:runtime"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import bridge_service "odin_test:hub/service/bridge"
import project_service "odin_test:hub/service/project"
import shell_session_svc "odin_test:hub/service/shell_session"
import iface "odin_test:hub/repository/iface"

// Hub_Proxy_Stream ties an originating bridge's proxy_id to the hub-side tunnel stream
// driving the target leg. Two id spaces meet here and must not be confused:
//   proxy_id  — allocated by the ORIGINATING bridge, unique only within that bridge
//   stream_id — allocated by the HUB, the id the target bridge and the tunnel registry see
// Keying on origin_bridge_id + proxy_id is what keeps two bridges' proxy_ids from
// colliding in this map.
Hub_Proxy_Stream :: struct {
	key:              string,
	proxy_id:         string,
	stream_id:        string,
	origin_bridge_id: string,
	target_bridge_id: string,
}

hub_proxy_streams: map[string]^Hub_Proxy_Stream
hub_proxy_mu:      sync.Mutex
hub_proxy_init_once: bool

hub_proxy_ensure_init :: proc() {
	if hub_proxy_init_once do return
	hub_proxy_streams = make(map[string]^Hub_Proxy_Stream, runtime.heap_allocator())
	hub_proxy_init_once = true
}

hub_proxy_key :: proc(origin_bridge_id, proxy_id: string, allocator := context.allocator) -> string {
	return strings.concatenate({origin_bridge_id, "|", proxy_id}, allocator)
}

// ---------------------------------------------------------------------------
// THE authorisation decision for REQ-XM-4.
// ---------------------------------------------------------------------------
//
// INTENTIONALLY PERMISSIVE, PENDING REQ-XM-5. This is a deliberate, user-accepted
// decision recorded on the task, not an oversight, and it is deliberately the ONLY
// place the relay makes an access decision — harden HERE rather than spreading policy
// across the splice.
//
// The model: any process that can reach an enabled bridge's local endpoint acts with
// that bridge's OWNER's authority. Reaching the local endpoint is therefore equivalent
// to holding the owner's credentials, and the feature ships enabled by default. That is
// the accepted trade for getting an end-to-end model working first.
//
// The one boundary that IS enforced, and must stay enforced: same-owner. A bridge may
// only reach sessions owned by the user who owns that bridge. Cross-owner targets are
// refused even under the permissive model.
//
// When REQ-XM-5 lands, the per-process identity check belongs in this function.
//
// Note for whoever hardens this: the hub's resolve_auth deliberately refuses hbr_ bridge
// tokens on user APIs ("bridge token cannot call user APIs", auth_service.odin:229).
// This path does not violate that rule — the bridge never presents hbr_ to a user
// endpoint, it relays over the runtime WS it already holds — but it reaches a comparable
// outcome by another route, and that is exactly what REQ-XM-5 needs to revisit.
bridge_proxy_authorise_target :: proc(h: ^Bridge_Handlers, origin_bridge_id, target_session_id: string) -> (domain.Shell_Session, string, bool) {
	empty := domain.Shell_Session{}
	if h == nil || h.shell_sessions == nil || h.bridges == nil do return empty, "unavailable", false

	// Attribute the request to the originating bridge's owner. This is the whole of the
	// identity model for now: the bridge's own hub credential stands in for the caller.
	owner := bridge_service.bridge_owner_user_id(h.bridges, origin_bridge_id)
	if owner == "" do return empty, "unknown_bridge", false

	// Owner-scoped lookup: a session belonging to a different user is not found at all.
	//
	// REQ-SHELL-12: an AMBIGUOUS id gets its own refusal rather than being folded into
	// "session_not_found". This relay cannot propagate the Domain_Error the way the REST
	// handlers do — it answers in reason STRINGS, not domain errors — so the refusal is
	// expressed in the vocabulary this function already speaks.
	//
	// THIS LINE AND ITS CASE IN bridge_proxy_send_refusal ARE ONE CHANGE. That switch
	// defaults to 403, so a reason added without its case does not fail loudly: it tells
	// the caller they are FORBIDDEN from a session that is in fact their own, which is a
	// worse answer than the 404 this replaces. Never add a member here without adding it
	// there in the same edit.
	session, found, repo_err := iface.shell_session_get(h.shell_sessions.repo, owner, target_session_id)
	if repo_err.code == .Conflict do return empty, "session_ambiguous", false
	if !found do return empty, "session_not_found", false

	// Explicit same-owner assertion. The repo query above is already owner-scoped, so
	// this is defence in depth — but it is stated here so the boundary is visible in the
	// authorisation function rather than being an emergent property of a query elsewhere.
	if session.owner_user_id != owner do return empty, "cross_owner", false

	// Same target preconditions the preview path enforces.
	// XM-8: kind is NOT one of them.  Reachability is "declared a port and is running",
	// whatever the session kind; the port is read from the session record, never from the
	// request, so relaxing this does not let a caller choose what gets dialled.
	if session.status != "running" do return empty, "session_not_running", false
	if session.server_port <= 0 do return empty, "no_server_port", false

	return session, "", true
}

// ---------------------------------------------------------------------------
// frame handlers — called from bridge_ws_process_frame
// ---------------------------------------------------------------------------

// bridge_proxy_handle_open resolves and authorises the target, opens the tunnel toward
// the target bridge, sends the request, and starts the response relay.
bridge_proxy_handle_open :: proc(h: ^Bridge_Handlers, origin_bridge_id, text: string) {
	heap := runtime.heap_allocator()
	proxy_id := json_string(text, "proxy_id")
	target_session_id := json_string(text, "target_session_id")
	method := json_string(text, "method")
	path := json_string(text, "path")
	query := json_string(text, "query")
	headers_b64 := json_string(text, "headers_b64")
	defer {
		delete(proxy_id); delete(target_session_id); delete(method)
		delete(path); delete(query); delete(headers_b64)
	}
	if proxy_id == "" || target_session_id == "" do return

	session, deny_reason, allowed := bridge_proxy_authorise_target(h, origin_bridge_id, target_session_id)
	if !allowed {
		// Refusal travels back as an HTTP response so the local caller sees a real
		// status rather than a silent hang, then the stream is closed.
		bridge_proxy_send_refusal(h, origin_bridge_id, proxy_id, deny_reason)
		return
	}

	hub_proxy_ensure_init()

	stream_id := strings.concatenate({"px", proxy_id, "_", hub_proxy_now_hex()}, heap)
	defer delete(stream_id, heap)

	// Register the tunnel stream BEFORE tunnel_open, so a fast bridge cannot deliver
	// response bytes into an unregistered stream. Same ordering as the preview path.
	stream := shell_session_svc.shell_session_tunnel_register(h.shell_sessions, stream_id)

	key := hub_proxy_key(origin_bridge_id, proxy_id, heap)
	rec := new(Hub_Proxy_Stream, heap)
	rec.key = key
	rec.proxy_id = strings.clone(proxy_id, heap)
	rec.stream_id = strings.clone(stream_id, heap)
	rec.origin_bridge_id = strings.clone(origin_bridge_id, heap)
	rec.target_bridge_id = strings.clone(session.bridge_id, heap)
	sync.mutex_lock(&hub_proxy_mu)
	hub_proxy_streams[strings.clone(key, heap)] = rec
	sync.mutex_unlock(&hub_proxy_mu)

	// Open the tunnel toward the target bridge.
	// client_ip on the wire is informational; label it with the originating bridge so
	// the target side can tell proxy-originated traffic from a browser preview.
	origin_label := strings.concatenate({"bridge:", origin_bridge_id}, heap)
	defer delete(origin_label, heap)
	open_json := _preview_tunnel_open_json(stream_id, target_session_id, origin_label)
	defer delete(open_json)
	project_service.bridge_command_send_runtime(
		h.shell_sessions.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = session.bridge_id, body_json = open_json},
	)

	// Rebuild the request with the SAME builder the preview path uses, so the bytes that
	// reach the target server — header allowlist included — come from exactly one piece
	// of code for both paths. Called in place; nothing is moved out of that file.
	headers := bridge_proxy_decode_headers(headers_b64, heap)
	defer {
		for hdr in headers { delete(hdr.name, heap); delete(hdr.value, heap) }
		delete(headers)
	}
	fwd_path := path == "" ? "/" : path
	prefix := strings.concatenate({"/proxy/", target_session_id})
	defer delete(prefix)
	forward_context := Preview_Forward_Context{
		prefix      = prefix,
		// This hub-side relay does not know the originating bridge's local endpoint port.
		host        = "",
		proto       = "http",
		client_addr = "127.0.0.1",
	}
	raw_req := _preview_build_http_request(method, fwd_path, query, headers[:], "", session.server_port, forward_context, false)
	defer delete(raw_req)

	bridge_proxy_send_tunnel_bytes(h, session.bridge_id, stream_id, transmute([]byte)raw_req)

	// Relay the response back to the originating bridge on its own thread: this handler
	// runs on the WS reader, which must not block.
	relay := new(Hub_Proxy_Relay_Data, heap)
	relay^ = Hub_Proxy_Relay_Data{
		h                = h,
		stream           = stream,
		stream_id        = strings.clone(stream_id, heap),
		proxy_id         = strings.clone(proxy_id, heap),
		key              = strings.clone(key, heap),
		origin_bridge_id = strings.clone(origin_bridge_id, heap),
		target_bridge_id = strings.clone(session.bridge_id, heap),
	}
	thread.run_with_data(rawptr(relay), bridge_proxy_relay_worker)
}

// bridge_proxy_handle_data forwards request-body bytes toward the target bridge.
bridge_proxy_handle_data :: proc(h: ^Bridge_Handlers, origin_bridge_id, text: string) {
	heap := runtime.heap_allocator()
	proxy_id := json_string(text, "proxy_id")
	data_b64 := json_string(text, "data_b64")
	defer { delete(proxy_id); delete(data_b64) }
	if proxy_id == "" || data_b64 == "" do return

	key := hub_proxy_key(origin_bridge_id, proxy_id, heap)
	defer delete(key, heap)

	target_bridge_id, stream_id, found := bridge_proxy_lookup(key)
	defer { delete(target_bridge_id, heap); delete(stream_id, heap) }
	if !found do return

	decoded, err := base64.decode(data_b64)
	defer delete(decoded)
	if err != nil || len(decoded) == 0 do return
	bridge_proxy_send_tunnel_bytes(h, target_bridge_id, stream_id, decoded)
}

// bridge_proxy_handle_close tears the target leg down when the originating side ends.
// This is what makes a client disconnect at A close the TCP connection on B rather than
// leaking it.
bridge_proxy_handle_close :: proc(h: ^Bridge_Handlers, origin_bridge_id, text: string) {
	heap := runtime.heap_allocator()
	proxy_id := json_string(text, "proxy_id")
	defer delete(proxy_id)
	if proxy_id == "" do return

	key := hub_proxy_key(origin_bridge_id, proxy_id, heap)
	defer delete(key, heap)

	rec, removed := bridge_proxy_take(key)
	if !removed do return

	close_json := _preview_tunnel_close_json(rec.stream_id, "origin_closed")
	project_service.bridge_command_send_runtime(
		h.shell_sessions.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = rec.target_bridge_id, body_json = close_json},
	)
	delete(close_json)

	// Waking the relay is what actually ends it: it is parked on the stream cond.
	shell_session_svc.shell_session_tunnel_close_stream(h.shell_sessions, rec.stream_id)
	bridge_proxy_free_record(rec)
}

// ---------------------------------------------------------------------------
// response relay
// ---------------------------------------------------------------------------

Hub_Proxy_Relay_Data :: struct {
	h:                ^Bridge_Handlers,
	stream:           ^shell_session_svc.Preview_Tunnel_Stream,
	stream_id:        string,
	proxy_id:         string,
	key:              string,
	origin_bridge_id: string,
	target_bridge_id: string,
}

// HUB_PROXY_IDLE_TIMEOUT matches the preview path's idle policy: an arbitrarily long or
// slow response is fine, only a total absence of bytes tears the stream down.
HUB_PROXY_IDLE_TIMEOUT :: 120 * time.Second

// bridge_proxy_relay_worker drains the tunnel stream and forwards each chunk to the
// originating bridge as a proxy_data frame.
//
// Chunks are forwarded AS THEY ARRIVE, never accumulated. XM-1 removed a full-response
// buffer from the preview relay because it broke streaming and capped responses; this is
// the equivalent near end for the proxy path and must not reintroduce it. cond_wait
// blocks until bytes land, so there is no sleep-poll either.
bridge_proxy_relay_worker :: proc(data: rawptr) {
	d := (^Hub_Proxy_Relay_Data)(data)
	heap := runtime.heap_allocator()
	defer {
		delete(d.stream_id, heap); delete(d.proxy_id, heap); delete(d.key, heap)
		delete(d.origin_bridge_id, heap); delete(d.target_bridge_id, heap)
		free(d, heap)
	}

	stream := d.stream
	for {
		sync.mutex_lock(&stream.mu)
		for len(stream.chunks) == 0 && !stream.closed {
			signaled := sync.cond_wait_with_timeout(&stream.cond, &stream.mu, HUB_PROXY_IDLE_TIMEOUT)
			if !signaled && len(stream.chunks) == 0 && !stream.closed {
				sync.mutex_unlock(&stream.mu)
				bridge_proxy_finish(d, "idle_timeout")
				return
			}
		}
		to_write := make([][]byte, len(stream.chunks), heap)
		copy(to_write, stream.chunks[:])
		clear(&stream.chunks)
		done := stream.closed
		sync.mutex_unlock(&stream.mu)

		for chunk in to_write {
			frame := bridge_proxy_data_json(d.proxy_id, chunk)
			project_service.bridge_command_send_runtime(
				d.h.shell_sessions.bridge_command_sink,
				project_service.Runtime_Command{bridge_id = d.origin_bridge_id, body_json = frame},
			)
			delete(frame)
			delete(chunk)
		}
		delete(to_write, heap)

		if done do break
	}
	bridge_proxy_finish(d, "done")
}

// bridge_proxy_finish closes both legs exactly once.
//
// The relay worker and an inbound proxy_close can both decide a stream is over, so the
// map removal decides who announces it: whoever takes the key owns the teardown and the
// other finds it gone. Same independent-key discipline the tunnel path uses on the
// bridge side.
bridge_proxy_finish :: proc(d: ^Hub_Proxy_Relay_Data, reason: string) {
	rec, removed := bridge_proxy_take(d.key)
	if removed {
		close_json := _preview_tunnel_close_json(d.stream_id, reason)
		project_service.bridge_command_send_runtime(
			d.h.shell_sessions.bridge_command_sink,
			project_service.Runtime_Command{bridge_id = d.target_bridge_id, body_json = close_json},
		)
		delete(close_json)
		bridge_proxy_free_record(rec)
	}
	// Tell the originating bridge the response is over so it can close the local socket.
	frame := bridge_proxy_close_json(d.proxy_id, reason)
	project_service.bridge_command_send_runtime(
		d.h.shell_sessions.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = d.origin_bridge_id, body_json = frame},
	)
	delete(frame)
	shell_session_svc.shell_session_tunnel_unregister(d.h.shell_sessions, d.stream_id)
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

bridge_proxy_lookup :: proc(key: string) -> (string, string, bool) {
	heap := runtime.heap_allocator()
	sync.mutex_lock(&hub_proxy_mu)
	defer sync.mutex_unlock(&hub_proxy_mu)
	rec, ok := hub_proxy_streams[key]
	if !ok do return "", "", false
	return strings.clone(rec.target_bridge_id, heap), strings.clone(rec.stream_id, heap), true
}

bridge_proxy_take :: proc(key: string) -> (^Hub_Proxy_Stream, bool) {
	heap := runtime.heap_allocator()
	sync.mutex_lock(&hub_proxy_mu)
	defer sync.mutex_unlock(&hub_proxy_mu)
	rec, ok := hub_proxy_streams[key]
	if !ok do return nil, false
	for k in hub_proxy_streams {
		if k == key {
			delete_key(&hub_proxy_streams, k)
			delete(k, heap)
			break
		}
	}
	return rec, true
}

bridge_proxy_free_record :: proc(rec: ^Hub_Proxy_Stream) {
	heap := runtime.heap_allocator()
	delete(rec.key, heap); delete(rec.proxy_id, heap); delete(rec.stream_id, heap)
	delete(rec.origin_bridge_id, heap); delete(rec.target_bridge_id, heap)
	free(rec, heap)
}

// bridge_proxy_send_tunnel_bytes chunks bytes into tunnel_data frames toward a bridge,
// mirroring the preview path's 48KB base64 chunking.
//
// CHUNK_SIZE does NOT fit one WS frame, and that is deliberate rather than an oversight.
// See the long note at the identical constant in shell_session_handlers.odin (the preview
// request path) for the full reasoning: 49152 raw base64s to exactly 65536 chars against a
// 65535 cap, which was FATAL before REQ-SHELL-36 and is harmless after it, because
// write_ws_command now owns framing and re-splits any oversized command at
// BRIDGE_WS_HUB_TO_BRIDGE_CHUNK_PAYLOAD_BYTES. Do not "fix" the arithmetic here without
// reading that note; pinned by preview_chunk_size_req54_test.odin (REQ-SHELL-54).
bridge_proxy_send_tunnel_bytes :: proc(h: ^Bridge_Handlers, bridge_id, stream_id: string, payload: []byte) {
	CHUNK_SIZE :: 48 * 1024
	seq := 0
	off := 0
	for {
		end := off + CHUNK_SIZE
		if end > len(payload) do end = len(payload)
		chunk := payload[off:end]
		is_last := end >= len(payload)
		encoded := base64.encode(chunk)
		frame := _preview_tunnel_data_json(stream_id, string(encoded), seq, is_last)
		delete(encoded)
		project_service.bridge_command_send_runtime(
			h.shell_sessions.bridge_command_sink,
			project_service.Runtime_Command{bridge_id = bridge_id, body_json = frame},
		)
		delete(frame)
		seq += 1
		off = end
		if is_last do break
	}
}

// bridge_proxy_decode_headers turns the base64 header block from proxy_open back into
// headers. The originating bridge sends the raw block rather than a JSON array because
// both ends hand-roll their JSON and neither has an array-of-objects parser.
bridge_proxy_decode_headers :: proc(headers_b64: string, allocator := context.allocator) -> [dynamic]contracts.HTTP_Header {
	out := make([dynamic]contracts.HTTP_Header, allocator)
	if headers_b64 == "" do return out
	decoded, err := base64.decode(headers_b64)
	defer delete(decoded)
	if err != nil || len(decoded) == 0 do return out
	block := string(decoded)
	for line in strings.split_lines_iterator(&block) {
		trimmed := strings.trim_space(line)
		if trimmed == "" do continue
		colon := strings.index_byte(trimmed, ':')
		if colon <= 0 do continue
		name := strings.trim_space(trimmed[:colon])
		value := strings.trim_space(trimmed[colon + 1:])
		if name == "" do continue
		append(&out, contracts.HTTP_Header{
			name  = strings.clone(name, allocator),
			value = strings.clone(value, allocator),
		})
	}
	return out
}

// bridge_proxy_send_refusal answers a refused proxy_open with a real HTTP response, then
// closes the stream. A refusal the caller can see beats a hang they have to diagnose.
bridge_proxy_send_refusal :: proc(h: ^Bridge_Handlers, origin_bridge_id, proxy_id, reason: string) {
	status := 403
	switch reason {
	case "session_not_found":     status = 404
	// session_ambiguous is a CONFLICT, not a 403: the session exists and belongs to this
	// caller, but the database holds two rows for the id and the hub will not guess.
	// Added in the same edit as its producer in bridge_proxy_authorise_target — see the
	// note there about this switch's 403 default.
	case "session_not_running", "no_server_port", "session_ambiguous": status = 409
	case "unavailable":           status = 503
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	body := strings.concatenate({"{\"error\":\"", reason, "\"}"})
	defer delete(body)
	strings.write_string(&b, "HTTP/1.1 ")
	strings.write_int(&b, status)
	strings.write_string(&b, " ")
	strings.write_string(&b, status == 404 ? "Not Found" : status == 409 ? "Conflict" : status == 503 ? "Service Unavailable" : "Forbidden")
	strings.write_string(&b, "\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ")
	strings.write_int(&b, len(body))
	strings.write_string(&b, "\r\n\r\n")
	strings.write_string(&b, body)
	raw := strings.to_string(b)

	frame := bridge_proxy_data_json(proxy_id, transmute([]byte)raw)
	project_service.bridge_command_send_runtime(
		h.shell_sessions.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = origin_bridge_id, body_json = frame},
	)
	delete(frame)

	close_frame := bridge_proxy_close_json(proxy_id, reason)
	project_service.bridge_command_send_runtime(
		h.shell_sessions.bridge_command_sink,
		project_service.Runtime_Command{bridge_id = origin_bridge_id, body_json = close_frame},
	)
	delete(close_frame)
}

bridge_proxy_data_json :: proc(proxy_id: string, payload: []byte) -> string {
	encoded := base64.encode(payload)
	defer delete(encoded)
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"proxy_data\",\"proxy_id\":\"")
	write_handler_json_string(&b, proxy_id)
	strings.write_string(&b, "\",\"data_b64\":\"")
	write_handler_json_string(&b, string(encoded))
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

bridge_proxy_close_json :: proc(proxy_id, reason: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"proxy_close\",\"proxy_id\":\"")
	write_handler_json_string(&b, proxy_id)
	strings.write_string(&b, "\",\"reason\":\"")
	write_handler_json_string(&b, reason)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

hub_proxy_now_hex :: proc() -> string {
	b := strings.builder_make()
	strings.write_int(&b, int(time.to_unix_nanoseconds(time.now())), 16)
	return strings.to_string(b)
}
