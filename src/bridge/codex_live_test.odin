package main

// Opt-in native fixture runner. No Hub connection or production configuration:
// the real extension reducers run behind an isolated loopback JSONL listener.
// Normal verification replays the captured native callbacks below.

import "base:runtime"
import json "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import ext "odin_test:ctl/extension"
import contracts "odin_test:contracts"

@(test)
test_codex_native_fixture_replay_isolated_by_issued_instance :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	id := "inst_codex_replay_one"
	other := "inst_codex_replay_two"
	bridge_runtime_mark_start_success(id)
	bridge_runtime_mark_start_success(other)
	v, err := json.parse_string(#load("../ctl/extension/testdata/codex/callbacks.json", string), json.DEFAULT_SPECIFICATION, true)
	testing.expect_value(t, err, json.Error.None)
	rows, _ := v.(json.Array)
	total := 0
	for row in rows {
		root, _ := row.(json.Object)
		// Spoofed native fields are not instance authority.
		root["agent_instance_id"] = json.String(other)
		raw, _ := json.marshal(root)
		mapped, map_err := ext.codex_map_hook(string(raw), "2026-10-22T10:00:00Z", 1000)
		testing.expect_value(t, map_err, ext.Codex_Error.None)
		if mapped.is_permission || len(mapped.events) == 0 do continue
		res := bridge_ext_ingest(Bridge_Local_Agent_Token_Record{agent_instance_id=id, instance_token="fixture-one",role=.Agent}, ext.event_params(mapped.events[:]), bridge_runtime_now_ms())
		testing.expect_value(t, res.accepted, len(mapped.events))
		testing.expect_value(t, res.fatal, contracts.Ext_Error.None)
		total += res.accepted
		bridge_ext_ingest_result_destroy(&res)
	}
	testing.expect(t, total > 70)
	testing.expect(t, strings.contains(bridge_ext_status_json(id), `"provider":"codex"`))
	testing.expect(t, strings.contains(bridge_ext_status_json(other), `"events_accepted":0`))
	mine, exists := bridge_runtime_instance_snapshot(id)
	testing.expect(t, exists)
	testing.expect_value(t, mine.activity_source, "codex_extension")
	testing.expect_value(t, bridge_runtime_activity_source_rank(mine.activity_source), 80)
}

@(private="file")
codex_live_stop: bool
@(private="file")
codex_live_stop_mutex: sync.Mutex

@(private="file")
codex_live_text :: proc(o: json.Object, k: string) -> string {
	v, _ := o[k].(json.String)
	return string(v)
}

@(private="file")
codex_live_connection :: proc(data: rawptr) {
	context.allocator = runtime.heap_allocator()
	socket := (cast(^net.TCP_Socket)data)^
	free(data, runtime.heap_allocator())
	defer net.close(socket)
	_ = net.set_option(socket, .Receive_Timeout, 5 * time.Second)
	raw := make([dynamic]u8)
	defer delete(raw)
	buf: [8192]u8
	for len(raw) <= contracts.EXT_BATCH_MAX_BYTES+4096 {
		n, err := net.recv_tcp(socket, buf[:])
		if err != nil || n <= 0 { fmt.println("CODEX_LIVE_RECV", n, err); return }
		append(&raw, ..buf[:n])
		if strings.contains(string(raw[:]), "\n") do break
	}
	value, err := json.parse_string(strings.trim_space(string(raw[:])), json.DEFAULT_SPECIFICATION, true)
	if err != .None { fmt.println("CODEX_LIVE_JSON", err); return }
	defer json.destroy_value(value)
	root, ok := value.(json.Object)
	if !ok do return
	token := codex_live_text(root, "token")
	id := "inst_codex_live_one" if token == "fixture-one" else "inst_codex_live_two"
	if token != "fixture-one" && token != "fixture-two" {
		_, _ = net.send_tcp(socket, transmute([]u8)string(`{"ok":false,"error":{"code":"forbidden"}}`+"\n"))
		return
	}
	rec := Bridge_Local_Agent_Token_Record{agent_instance_id=id,instance_token=token,role=.Agent}
	method := codex_live_text(root, "method")
	fmt.println("CODEX_LIVE_REQUEST", method)
	request_id := codex_live_text(root, "id")
	params, _ := json.marshal(root["params"])
	defer delete(params)
	response := ""
	switch method {
	case "agent.extension.event":
		res := bridge_ext_ingest(rec, string(params), bridge_runtime_now_ms())
		response = bridge_local_response_data(request_id, bridge_ext_ingest_result_json(res))
		bridge_ext_ingest_result_destroy(&res)
	case "agent.extension.permission":
		response = bridge_ext_permission_handle_rpc(request_id, string(params), rec)
	case "fixture.finish":
		sync.mutex_lock(&codex_live_stop_mutex)
		codex_live_stop = true
		sync.mutex_unlock(&codex_live_stop_mutex)
		response = `{"ok":true}`
	case "fixture.inspect":
		blockers, _ := json.marshal(bridge_blockers_list(id))
		events := strings.builder_make()
		strings.write_byte(&events, '[')
		sync.mutex_lock(&bridge_ext_mutex)
		for s in bridge_ext_states {
			if s.agent_instance_id != id do continue
			for ev, i in s.queue {
				if i > 0 do strings.write_byte(&events, ',')
				strings.write_string(&events, ev)
			}
		}
		sync.mutex_unlock(&bridge_ext_mutex)
		strings.write_byte(&events, ']')
		response = fmt.aprintf(`{{"ok":true,"data":{{"extension":%s,"blockers":%s,"events":%s}}}}`,bridge_ext_status_json(id),string(blockers),strings.to_string(events))
	case "fixture.decide":
		p, _ := root["params"].(json.Object)
		frame := fmt.aprintf(`{{"type":"permission_decision","command_id":"fixture","agent_instance_id":"%s","request_id":"%s","decision":"%s","message":"synthetic fixture decision"}}`,id,codex_live_text(p,"blocker_id"),codex_live_text(p,"decision"))
		decided := bridge_ext_permission_handle_decision_frame(frame)
		response = fmt.aprintf(`{{"ok":%t}}`,decided)
	case:
		response = `{"ok":false,"error":{"code":"bad_request"}}`
	}
	fmt.println("CODEX_LIVE_SEND", len(response))
	sent, send_err := net.send_tcp(socket, transmute([]u8)strings.concatenate({response,"\n"}))
	fmt.println("CODEX_LIVE_SENT", sent, send_err)
}

@(test)
test_codex_live_bridge_listener_when_explicitly_configured :: proc(t: ^testing.T) {
	port_raw := os.get_env("HEIMDALL_CODEX_LIVE_PORT", context.temp_allocator)
	if port_raw == "" do return
	port, ok := strconv.parse_int(port_raw)
	testing.expect(t, ok && port > 1024 && port < 65536)
	if !ok do return
	context.allocator = runtime.heap_allocator()
	for id in ([]string{"inst_codex_live_one","inst_codex_live_two"}) do bridge_runtime_mark_start_success(id)
	listener, err := net.listen_tcp({address=net.IP4_Loopback,port=port})
	testing.expect(t, err == nil)
	if err != nil do return
	defer net.close(listener)
	fmt.println("CODEX_LIVE_READY", port)
	workers := make([dynamic]^thread.Thread)
	for {
		socket, _, err := net.accept_tcp(listener)
		if err != nil do break
		sync.mutex_lock(&codex_live_stop_mutex)
		stop := codex_live_stop
		sync.mutex_unlock(&codex_live_stop_mutex)
		if stop { net.close(socket); break }
		p := new(net.TCP_Socket)
		p^ = socket
		th := thread.create_and_start_with_data(p, codex_live_connection)
		append(&workers, th)
	}
	for th in workers { thread.join(th); thread.destroy(th) }
	delete(workers)
	for id in ([]string{"inst_codex_live_one","inst_codex_live_two"}) {
		testing.expect(t, strings.contains(bridge_ext_status_json(id), `"provider":"codex"`))
	}
}
