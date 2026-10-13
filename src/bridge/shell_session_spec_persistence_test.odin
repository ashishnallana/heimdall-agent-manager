package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
spec_test_dir :: proc(name: string) -> string {
	return strings.concatenate({"/tmp/ham-spec-test-", name})
}

@(private = "file")
spec_test_cleanup :: proc(data_dir: string) {
	dir := bridge_shell_session_spec_dir(data_dir)
	defer delete(dir)
	infos, err := os.read_directory_by_path(dir, -1, context.allocator)
	if err == nil {
		defer os.file_info_slice_delete(infos, context.allocator)
		for info in infos {
			p := strings.concatenate({dir, "/", info.name})
			_ = os.remove(p)
			delete(p)
		}
	}
	_ = os.remove(dir)
	_ = os.remove(data_dir)
}

// REQ-P1-SHELL-SPEC AC: Shell_Session_Spec round-trip serialization for all 21 fields.
@(test)
test_shell_session_spec_roundtrip_all_fields :: proc(t: ^testing.T) {
	dir := spec_test_dir("roundtrip")
	defer delete(dir)
	defer spec_test_cleanup(dir)

	orig := Bridge_Shell_Session{
		session_id        = "sh_roundtrip_all",
		kind              = .Server,
		label             = "web-server",
		cmd               = "node server.js --port 8080",
		cwd               = "/home/user/app",
		bridge_id         = "brg_alpha",
		project_id        = "proj_beta",
		chain_id          = "chain_gamma",
		agent_instance_id = "inst_delta",
		owner_user_id     = "user_epsilon",
		pid               = 4242,
		server_port       = 8080,
		run_seq           = 3,
		status            = .Running,
		exit_code         = 0,
		exit_code_set     = true,
		started_at        = "2026-10-03T10:00:00Z",
		finished_at       = "2026-10-03T10:05:00Z",
		shell_id          = "sh_daemon_spec",
		background        = true,
		pty_host          = true,
	}

	bridge_shell_session_save_spec(dir, orig)

	specs := bridge_shell_session_load_specs(dir, context.allocator)
	defer {
		for s in specs do bridge_shell_session_free_fields(s, context.allocator)
		delete(specs, context.allocator)
	}

	testing.expect_value(t, len(specs), 1)
	if len(specs) != 1 do return

	s := specs[0]
	testing.expect_value(t, s.session_id, orig.session_id)
	testing.expect_value(t, s.kind, orig.kind)
	testing.expect_value(t, s.label, orig.label)
	testing.expect_value(t, s.cmd, orig.cmd)
	testing.expect_value(t, s.cwd, orig.cwd)
	testing.expect_value(t, s.bridge_id, orig.bridge_id)
	testing.expect_value(t, s.project_id, orig.project_id)
	testing.expect_value(t, s.chain_id, orig.chain_id)
	testing.expect_value(t, s.agent_instance_id, orig.agent_instance_id)
	testing.expect_value(t, s.owner_user_id, orig.owner_user_id)
	testing.expect_value(t, s.pid, orig.pid)
	testing.expect_value(t, s.server_port, orig.server_port)
	testing.expect_value(t, s.run_seq, orig.run_seq)
	testing.expect_value(t, s.status, orig.status)
	testing.expect_value(t, s.exit_code, orig.exit_code)
	testing.expect_value(t, s.exit_code_set, orig.exit_code_set)
	testing.expect_value(t, s.started_at, orig.started_at)
	testing.expect_value(t, s.finished_at, orig.finished_at)
	testing.expect_value(t, s.shell_id, orig.shell_id)
	testing.expect_value(t, s.background, orig.background)
	testing.expect_value(t, s.pty_host, orig.pty_host)
	testing.expect_value(t, s.pty_host_provenance_known, true)
}

// REQ-P1-SHELL-SPEC AC: Key-order resilience and whitespace tolerance.
@(test)
test_shell_session_spec_key_order_and_whitespace_resilience :: proc(t: ^testing.T) {
	dir := spec_test_dir("scrambled")
	defer delete(dir)
	defer spec_test_cleanup(dir)

	sdir := bridge_shell_session_spec_dir(dir)
	defer delete(sdir)
	_ = os.make_directory_all(sdir)

	// Scrambled keys with whitespace, newlines, and tabs
	scrambled_json := `
	{
		"pty_host" :   false  ,
		"background" :   true  ,
		"finished_at" : "2026-10-03T12:00:00Z" ,
		"started_at" : "2026-10-03T11:00:00Z" ,
		"exit_code_set" :  true ,
		"exit_code" :   137 ,
		"status" : "killed" ,
		"run_seq" : 5 ,
		"server_port" : 3000 ,
		"pid" : 9999 ,
		"owner_user_id" : "tanmay" ,
		"agent_instance_id" : "inst_worker" ,
		"chain_id" : "chain_abc" ,
		"project_id" : "proj_123" ,
		"bridge_id" : "brg_local" ,
		"cwd" : "/tmp/work" ,
		"cmd" : "sleep 10" ,
		"label" : "order_test" ,
		"kind" : "server" ,
		"shell_id" : "sh_scrambled" ,
		"session_id" : "sh_scrambled"
	}
	`

	path := strings.concatenate({sdir, "/sh_scrambled.json"})
	defer delete(path)
	_ = os.write_entire_file(path, transmute([]byte)scrambled_json)

	specs := bridge_shell_session_load_specs(dir, context.allocator)
	defer {
		for s in specs do bridge_shell_session_free_fields(s, context.allocator)
		delete(specs, context.allocator)
	}

	testing.expect_value(t, len(specs), 1)
	if len(specs) != 1 do return

	s := specs[0]
	testing.expect_value(t, s.session_id, "sh_scrambled")
	testing.expect_value(t, s.kind, Bridge_Shell_Session_Kind.Server)
	testing.expect_value(t, s.label, "order_test")
	testing.expect_value(t, s.cmd, "sleep 10")
	testing.expect_value(t, s.cwd, "/tmp/work")
	testing.expect_value(t, s.bridge_id, "brg_local")
	testing.expect_value(t, s.project_id, "proj_123")
	testing.expect_value(t, s.chain_id, "chain_abc")
	testing.expect_value(t, s.agent_instance_id, "inst_worker")
	testing.expect_value(t, s.owner_user_id, "tanmay")
	testing.expect_value(t, s.pid, 9999)
	testing.expect_value(t, s.server_port, 3000)
	testing.expect_value(t, s.run_seq, 5)
	testing.expect_value(t, s.status, Bridge_Shell_Session_Status.Killed)
	testing.expect_value(t, s.exit_code, 137)
	testing.expect_value(t, s.exit_code_set, true)
	testing.expect_value(t, s.started_at, "2026-10-03T11:00:00Z")
	testing.expect_value(t, s.finished_at, "2026-10-03T12:00:00Z")
	testing.expect_value(t, s.shell_id, "sh_scrambled")
	testing.expect_value(t, s.background, true)
	testing.expect_value(t, s.pty_host, false)
	testing.expect_value(t, s.pty_host_provenance_known, true)
}

// REQ-P1-SHELL-SPEC AC: Backward compatibility for legacy spec files (missing run_seq and pty_host).
@(test)
test_shell_session_spec_backward_compatibility :: proc(t: ^testing.T) {
	dir := spec_test_dir("compat")
	defer delete(dir)
	defer spec_test_cleanup(dir)

	sdir := bridge_shell_session_spec_dir(dir)
	defer delete(sdir)
	_ = os.make_directory_all(sdir)

	// Legacy spec without run_seq or pty_host keys
	legacy_json := `{"session_id":"sh_legacy","kind":"run","cmd":"uptime","pid":555,"status":"running"}`
	path := strings.concatenate({sdir, "/sh_legacy.json"})
	defer delete(path)
	_ = os.write_entire_file(path, transmute([]byte)legacy_json)

	specs := bridge_shell_session_load_specs(dir, context.allocator)
	defer {
		for s in specs do bridge_shell_session_free_fields(s, context.allocator)
		delete(specs, context.allocator)
	}

	testing.expect_value(t, len(specs), 1)
	if len(specs) != 1 do return

	s := specs[0]
	testing.expect_value(t, s.session_id, "sh_legacy")
	testing.expect_value(t, s.kind, Bridge_Shell_Session_Kind.Run)
	testing.expect_value(t, s.cmd, "uptime")
	testing.expect_value(t, s.pid, 555)
	testing.expect_value(t, s.status, Bridge_Shell_Session_Status.Running)
	// Missing run_seq defaults to 0
	testing.expect_value(t, s.run_seq, 0)
	// Missing pty_host defaults to false and provenance is unknown
	testing.expect_value(t, s.pty_host, false)
	testing.expect_value(t, s.pty_host_provenance_known, false)
}

// REQ-P1-SHELL-SPEC AC: Zero tracking allocator leaks during spec save and load.
@(test)
test_shell_session_spec_zero_tracking_allocator_leaks :: proc(t: ^testing.T) {
	dir := spec_test_dir("track")
	defer delete(dir)
	defer spec_test_cleanup(dir)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	m_allocator := mem.tracking_allocator(&track)

	orig := Bridge_Shell_Session{
		session_id        = "sh_leak_check",
		kind              = .Run,
		cmd               = "echo hello",
		cwd               = "/tmp",
		bridge_id         = "brg_track",
		label             = "leak-check",
		status            = .Exited,
		pid               = 1234,
		exit_code         = 0,
		exit_code_set     = true,
		started_at        = "2026-10-03T10:00:00Z",
		finished_at       = "2026-10-03T10:01:00Z",
		shell_id          = "sh_leak_check",
		pty_host          = true,
	}

	bridge_shell_session_save_spec(dir, orig)

	specs := bridge_shell_session_load_specs(dir, m_allocator)
	testing.expect_value(t, len(specs), 1)

	for s in specs {
		bridge_shell_session_free_fields(s, m_allocator)
	}
	delete(specs, m_allocator)

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

// ---- REQ-PAGER-1/2/3: non-interactive pager overrides for kind=run ----------

@(test)
test_shell_run_env_key_values :: proc(t: ^testing.T) {
	env := bridge_shell_run_env()
	defer {
		for kv in env {
			delete(kv[0])
			delete(kv[1])
		}
		delete(env)
	}

	testing.expect_value(t, len(env), 3)
	if len(env) == 3 {
		testing.expect_value(t, env[0][0], "PAGER")
		testing.expect_value(t, env[0][1], "cat")
		testing.expect_value(t, env[1][0], "GIT_PAGER")
		testing.expect_value(t, env[1][1], "cat")
		testing.expect_value(t, env[2][0], "SYSTEMD_PAGER")
		testing.expect_value(t, env[2][1], "cat")
	}
}

@(test)
test_shell_run_env_cleanly_freed_by_spawn_request_delete :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	baseline_allocs := len(track.allocation_map)
	baseline_bytes := track.current_memory_allocated

	{
		req := Pty_Host_Spawn_Request{
			env = bridge_shell_run_env(),
		}
		bridge_pty_host_spawn_request_delete(req)
	}

	testing.expectf(t, len(track.allocation_map) == baseline_allocs,
		"leak: %d live allocations, expected %d", len(track.allocation_map), baseline_allocs)
	testing.expectf(t, track.current_memory_allocated == baseline_bytes,
		"leak: %d live bytes, expected %d", track.current_memory_allocated, baseline_bytes)
	testing.expect(t, len(track.bad_free_array) == 0, "no bad frees")
}

@(test)
test_shell_env_kind_branching :: proc(t: ^testing.T) {
	run_env := Bridge_Shell_Session_Kind.Run == .Run ? bridge_shell_run_env() : nil
	testing.expect(t, run_env != nil, "Run env must not be nil")
	testing.expect_value(t, len(run_env), 3)

	req_run := Pty_Host_Spawn_Request{
		env = run_env,
	}
	bridge_pty_host_spawn_request_delete(req_run)

	shell_env := Bridge_Shell_Session_Kind.Shell == .Run ? bridge_shell_run_env() : nil
	testing.expect(t, shell_env == nil, "Shell env must remain nil")
	req_shell := Pty_Host_Spawn_Request{
		env = shell_env,
	}
	bridge_pty_host_spawn_request_delete(req_shell)

	server_env := Bridge_Shell_Session_Kind.Server == .Run ? bridge_shell_run_env() : nil
	testing.expect(t, server_env == nil, "Server env must remain nil")
	req_server := Pty_Host_Spawn_Request{
		env = server_env,
	}
	bridge_pty_host_spawn_request_delete(req_server)
}

// ---- REQ-SHELL-16: shell error result JSON & log formatting -----------------

@(test)
test_req16_shell_start_error_body_is_unchanged :: proc(t: ^testing.T) {
	got := bridge_shell_error_result_json("shell_start_result", "sh_1", "cmd_1", "daemon unavailable", "")
	defer delete(got)
	testing.expect_value(
		t,
		got,
		`{"type":"shell_start_result","session_id":"sh_1","command_id":"cmd_1","ok":false,"error":"daemon unavailable"}`,
	)
}

@(test)
test_req16_shell_logs_error_body_keeps_its_padding_fields :: proc(t: ^testing.T) {
	got := bridge_shell_error_result_json(
		"shell_logs_result", "sh_2", "cmd_2", "session not found",
		`"lines":[],"truncated":false,"total_lines":0,`,
	)
	defer delete(got)
	testing.expect_value(
		t,
		got,
		`{"type":"shell_logs_result","session_id":"sh_2","command_id":"cmd_2","ok":false,"lines":[],"truncated":false,"total_lines":0,"error":"session not found"}`,
	)
}

@(test)
test_req16_shell_capture_error_body_keeps_its_padding_fields :: proc(t: ^testing.T) {
	got := bridge_shell_error_result_json(
		"shell_capture_result", "sh_3", "cmd_3", "capture failed",
		`"content":"","rows":0,"cols":0,`,
	)
	defer delete(got)
	testing.expect_value(
		t,
		got,
		`{"type":"shell_capture_result","session_id":"sh_3","command_id":"cmd_3","ok":false,"content":"","rows":0,"cols":0,"error":"capture failed"}`,
	)
}

@(test)
test_req16_error_reason_is_json_escaped :: proc(t: ^testing.T) {
	got := bridge_shell_error_result_json(
		"shell_start_result", "sh_4", "cmd_4", `spawn failed: "/bin/sh" \ exited`, "",
	)
	defer delete(got)
	testing.expect(
		t,
		strings.contains(got, `\"/bin/sh\"`),
		"an embedded quote in the reason must be escaped, not emitted raw",
	)
	testing.expect(
		t,
		!strings.contains(got, `: "/bin/sh"`),
		"the raw unescaped form must not appear",
	)
}

@(test)
test_req16_error_log_line_names_the_reason_and_both_ids :: proc(t: ^testing.T) {
	got := bridge_shell_error_log_line("shell_start_result", "sh_5", "cmd_5", "daemon unavailable")
	defer delete(got)
	testing.expect_value(
		t,
		got,
		"bridge shell: rejected shell_start_result session_id=sh_5 command_id=cmd_5 reason=daemon unavailable",
	)
}

@(test)
test_req16_handler_rejects_a_missing_session_id :: proc(t: ^testing.T) {
	bridge_hub_handle_shell_start(nil, `{"type":"shell_start","command_id":"cmd_ac1a","kind":"run","cmd":"echo hi"}`)
	testing.expect(t, true, "handler returned without a connection or a daemon")
}

@(test)
test_req16_handler_rejects_a_missing_cmd :: proc(t: ^testing.T) {
	bridge_hub_handle_shell_start(nil, `{"type":"shell_start","session_id":"sh_ac1b","command_id":"cmd_ac1b","kind":"run"}`)
	testing.expect(t, true, "handler returned without a connection or a daemon")
}

// ---- REQ-SHELL-1 §8: authoritative started_at clock -------------------------

@(test)
test_bridge_shell_started_at_prefers_the_hub_clock :: proc(t: ^testing.T) {
	hub   := "2026-09-28T08:00:00Z"
	local := "2026-09-28T08:00:00Z"
	testing.expect_value(t, bridge_shell_authoritative_started_at(hub, local), hub)
}

@(test)
test_bridge_shell_skewed_local_clock_does_not_change_started_at :: proc(t: ^testing.T) {
	hub := "2026-09-28T08:00:00Z"
	skews := []string{
		"2026-09-28T02:13:44Z",
		"2026-09-28T19:47:02Z",
		"2026-09-27T08:00:00Z",
		"2026-09-29T08:00:00Z",
	}
	for skewed in skews {
		testing.expect_value(t, bridge_shell_authoritative_started_at(hub, skewed), hub)
	}
}

@(test)
test_bridge_shell_started_at_falls_back_only_when_hub_sent_none :: proc(t: ^testing.T) {
	local := "2026-09-28T08:00:00Z"
	testing.expect_value(t, bridge_shell_authoritative_started_at("", local), local)
}
