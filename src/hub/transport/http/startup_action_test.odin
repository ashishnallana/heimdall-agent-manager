package http

import "core:strings"
import "core:encoding/json"
import "core:testing"
import "core:thread"
import jsonx "odin_test:lib/jsonx"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import agent_service "odin_test:hub/service/agent"
import content_service "odin_test:hub/service/content"
import project_service "odin_test:hub/service/project"

@(test)
startup_launch_and_wake_payloads_carry_generation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	launch := agent_service.launch_command_json("command", domain.Agent_Instance{agent_instance_id = "inst", run_count = 4})
	count, present := jsonx.extract_int_found(launch, "run_count")
	testing.expect(t, present && count == 4)
	run := []agent_service.Wake_Agent_Run_Entry{{agent_instance_id = "inst", run_count = 4}}
	wake := agent_service.wake_agent_command_json("bridge", "chain", run, nil)
	wire: struct { payload: struct { run: []struct { run_count: int } } }
	err := json.unmarshal_string(wake, &wire)
	testing.expect(t, err == nil && len(wire.payload.run) == 1 && wire.payload.run[0].run_count == 4)
}

// Exercise the actual bridge-authenticated action handler, including durable
// note insertion, lifecycle hook, inbox wake, retries, and a replacement epoch.
@(test)
startup_action_concurrent_retries_have_one_note_hook_and_wake :: proc(t: ^testing.T) {
	f := wire_setup(t, "startup")
	defer wire_teardown(f)
	content_impl: sqlite.Content_Repo_SQLite
	content_repo := sqlite.new_content_repository(&content_impl, &f.conn)
	content := content_service.new_content_service(&content_repo, &f.ag_repo, &f.br_repo, nil, nil, &f.clock, &f.ids)
	f.ah.content = &content
	Counts :: struct { hooks, wakes: int }
	counts: Counts
	f.ag_svc.hooks = agent_service.Lifecycle_Hooks{ctx = &counts, on_start_success = proc(ctx: rawptr, inst: domain.Agent_Instance) { (^Counts)(ctx).hooks += 1 }}
	content.bridge_command_sink = project_service.Bridge_Command_Sink{ctx = &counts, send_runtime_command = proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
		if strings.contains(command.body_json, "notify_agent_message") do (^Counts)(ctx).wakes += 1
		return true, {}
	}}
	_, conv_ok, _ := iface.content_save_conversation(&content_repo, domain.Chat_Conversation{conversation_id = "chat_startup", owner_user_id = f.owner, agent_id = "agt_wire_tb2", agent_instance_id = f.instance_id, title = "startup", created_at = "2026-10-22T10:00:00Z", updated_at = "2026-10-22T10:00:00Z"})
	if !testing.expect(t, conv_ok, "conversation fixture") do return
	_, msg_ok, _ := iface.content_save_message(&content_repo, domain.Chat_Message{message_id = "msg_unread", conversation_id = "chat_startup", owner_user_id = f.owner, direction = "user_to_agent", body = "Pending work", artifact_ids_json = "[]", message_type = "text", created_at = "2026-10-22T10:00:00Z"})
	if !testing.expect(t, msg_ok, "unread inbound fixture") do return
	body := strings.concatenate({`{"agent_instance_id":"`, f.instance_id, `","params":{}}`})
	defer delete(body)
	req := wire_agent_request(f, "start-success", body)
	Work :: struct { handler: ^Agent_Action_Handlers, req: Request, status: int }
	work: [3]Work
	workers: [3]^thread.Thread
	for &w, i in work {
		w.handler = &f.ah
		w.req = req
		workers[i] = thread.create_and_start_with_data(rawptr(&w), proc(data: rawptr) {
			job := (^Work)(data)
			resp := agent_action_start_success_handler(job.handler, job.req)
			job.status = resp.status
		})
	}
	for w in workers { thread.join(w); thread.destroy(w) }
	for w in work do testing.expect_value(t, w.status, 200)
	testing.expect_value(t, counts.hooks, 1)
	testing.expect_value(t, counts.wakes, 1)
	rows, _ := iface.content_list_messages(&content_repo, "chat_startup", f.owner, 20, "")
	testing.expect_value(t, len(rows), 2)
	conv, _, _ := iface.content_get_conversation(&content_repo, "chat_startup")
	testing.expect_value(t, conv.unread_count, 1)
	// Recreate services to simulate lost in-memory dedup state after a restart.
	restarted := content_service.new_content_service(&content_repo, &f.ag_repo, &f.br_repo, nil, nil, &f.clock, &f.ids)
	f.ah.content = &restarted
	resp := agent_action_start_success_handler(&f.ah, req)
	testing.expect_value(t, resp.status, 200)
	testing.expect_value(t, counts.hooks, 1)
	conv, _, _ = iface.content_get_conversation(&content_repo, "chat_startup")
	testing.expect_value(t, conv.unread_count, 1)

	// A normal relaunch keeps launch_epoch unchanged. Its old assertion still
	// authenticates, so the explicit generation fence must reject delayed work.
	testing.expect(t, sqlite.exec(&f.conn, "UPDATE agent_instances SET run_count=2, runtime_status='starting', startup_status='starting' WHERE agent_instance_id='inst_wire_tb2';"))
	old_body := strings.concatenate({`{"agent_instance_id":"`, f.instance_id, `","params":{"run_count":1}}`})
	defer delete(old_body)
	req.body = old_body
	testing.expect(t, agent_action_start_success_handler(&f.ah, req).status != 200, "same-epoch old generation rejected")
	req.body = body
	testing.expect(t, agent_action_start_success_handler(&f.ah, req).status != 200, "missing generation cannot bypass a relaunch fence")
	testing.expect_value(t, counts.hooks, 1)
	current_body := strings.concatenate({`{"agent_instance_id":"`, f.instance_id, `","params":{"run_count":2}}`})
	defer delete(current_body)
	req.body = current_body
	testing.expect_value(t, agent_action_start_success_handler(&f.ah, req).status, 200)
	testing.expect_value(t, counts.hooks, 2)

	inst, _, _ := iface.agent_get_instance(&f.ag_repo, f.instance_id)
	// Epoch changes use their own fenced SQL operation in production. save_instance
	// intentionally refuses to mutate launch_epoch, so seed that boundary directly.
	testing.expect(t, sqlite.exec(&f.conn, "UPDATE agent_instances SET launch_epoch='startup_epoch_2', run_count=run_count+1, runtime_status='starting', startup_status='starting' WHERE agent_instance_id='inst_wire_tb2';"))
	inst, _, _ = iface.agent_get_instance(&f.ag_repo, f.instance_id)
	stale := agent_action_start_success_handler(&f.ah, req)
	testing.expect(t, stale.status != 200, "old launch assertion is rejected")
	new_assertion := agent_service.instance_assertion_token(inst)
	defer delete(new_assertion)
	f.agent_headers[1].value = new_assertion
	req.headers = f.agent_headers[:]
	next_body := strings.concatenate({`{"agent_instance_id":"`, f.instance_id, `","params":{"run_count":3}}`})
	defer delete(next_body)
	req.body = next_body
	resp = agent_action_start_success_handler(&f.ah, req)
	testing.expect_value(t, resp.status, 200)
	testing.expect_value(t, counts.hooks, 3)
	rows, _ = iface.content_list_messages(&content_repo, "chat_startup", f.owner, 20, "")
	testing.expect_value(t, len(rows), 4)
	// A new stopped epoch has no receipt: a valid credential still cannot revive it.
	testing.expect(t, sqlite.exec(&f.conn, "UPDATE agent_instances SET launch_epoch='startup_epoch_3', runtime_status='stopped', startup_status='stopped' WHERE agent_instance_id='inst_wire_tb2';"))
	inst, _, _ = iface.agent_get_instance(&f.ag_repo, f.instance_id)
	stopped_assertion := agent_service.instance_assertion_token(inst)
	defer delete(stopped_assertion)
	f.agent_headers[1].value = stopped_assertion
	resp = agent_action_start_success_handler(&f.ah, req)
	testing.expect(t, resp.status != 200, "stopped launch cannot be resurrected")
	after, _, _ := iface.agent_get_instance(&f.ag_repo, f.instance_id)
	testing.expect_value(t, after.runtime_status, "stopped")
	testing.expect_value(t, counts.hooks, 3)
}
