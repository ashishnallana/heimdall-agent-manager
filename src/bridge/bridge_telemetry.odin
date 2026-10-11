package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

// REQ-TEL-2, REQ-TEL-5: Dynamic Telegraf process supervisor and metrics feed.
// Controls the lifecycle of the local Telegraf collector child process and
// provides telemetry endpoints.

TELEGRAF_CONF_EMBEDDED :: #load("../../tools/telemetry/telegraf.conf.template", string)

bridge_telemetry_mu: sync.Mutex
bridge_telemetry_running: bool
bridge_telemetry_process: os.Process
bridge_telemetry_active_conf_path: string

bridge_telemetry_get_hostname :: proc(allocator := context.allocator) -> string {
	if h := os.get_env("HOSTNAME", allocator); h != "" do return h
	when ODIN_OS != .Windows {
		buf: [256]byte
		if posix.gethostname(raw_data(buf[:]), len(buf)) == .OK {
			name := strings.truncate_to_byte(string(buf[:]), 0)
			if len(name) > 0 do return strings.clone(name, allocator)
		}
	}
	return strings.clone("localhost", allocator)
}

bridge_telemetry_get_port :: proc(allocator := context.allocator) -> string {
	if p := os.get_env("TELEMETRY_PORT", allocator); p != "" do return p
	return strings.clone("9273", allocator)
}

bridge_telemetry_get_template :: proc(allocator := context.allocator) -> string {
	if path := os.get_env("TELEGRAF_CONF_TEMPLATE", context.temp_allocator); path != "" {
		if data, err := os.read_entire_file(path, allocator); err == nil {
			return string(data)
		}
	}
	paths := [?]string{
		"tools/telemetry/telegraf.conf.template",
		"../tools/telemetry/telegraf.conf.template",
		"../../tools/telemetry/telegraf.conf.template",
	}
	for p in paths {
		if data, err := os.read_entire_file(p, allocator); err == nil {
			return string(data)
		}
	}
	return strings.clone(TELEGRAF_CONF_EMBEDDED, allocator)
}

bridge_telemetry_hydrate_template :: proc(template_text, bridge_id, hostname, port: string, allocator := context.allocator) -> string {
	s := strings.clone(template_text, allocator)

	s1, _ := strings.replace_all(s, "${HEIMDALL_BRIDGE_ID}", bridge_id, allocator)
	delete(s, allocator)

	s2, _ := strings.replace_all(s1, "${HOSTNAME}", hostname, allocator)
	delete(s1, allocator)

	s3, _ := strings.replace_all(s2, "${TELEMETRY_PORT:-9273}", port, allocator)
	delete(s2, allocator)

	s4, _ := strings.replace_all(s3, "${TELEMETRY_PORT}", port, allocator)
	delete(s3, allocator)

	return s4
}

bridge_telemetry_conf_path :: proc(bridge_id: string, allocator := context.allocator) -> string {
	safe_id := bridge_runtime_safe_part(bridge_id)
	defer delete(safe_id)
	root := bridge_scratch_root(context.temp_allocator)
	return fmt.aprintf("%s/heimdall-telegraf-%s.conf", root, safe_id, allocator = allocator)
}

bridge_telemetry_status :: proc() -> bool {
	sync.mutex_lock(&bridge_telemetry_mu)
	defer sync.mutex_unlock(&bridge_telemetry_mu)

	if !bridge_telemetry_running do return false

	if state, err := os.process_wait(bridge_telemetry_process, 0); err == nil && state.exited {
		bridge_telemetry_running = false
		return false
	}

	return true
}

bridge_telemetry_start :: proc() -> bool {
	sync.mutex_lock(&bridge_telemetry_mu)
	defer sync.mutex_unlock(&bridge_telemetry_mu)

	if bridge_telemetry_running {
		if state, err := os.process_wait(bridge_telemetry_process, 0); err == nil && state.exited {
			bridge_telemetry_running = false
		} else {
			return true
		}
	}

	bridge_id := bridge_config.daemon_id
	if strings.trim_space(bridge_id) == "" do bridge_id = "local-daemon"

	hostname := bridge_telemetry_get_hostname(context.temp_allocator)
	port := bridge_telemetry_get_port(context.temp_allocator)
	tpl := bridge_telemetry_get_template(context.temp_allocator)

	hydrated := bridge_telemetry_hydrate_template(tpl, bridge_id, hostname, port, context.temp_allocator)
	conf_file := bridge_telemetry_conf_path(bridge_id, context.temp_allocator)

	write_err := os.write_entire_file(conf_file, transmute([]byte)hydrated)
	if write_err != nil {
		fmt.eprintln("bridge telemetry: failed to write config file:", conf_file, write_err)
		return false
	}

	// Locate telegraf executable
	cmd: [dynamic]string
	defer delete(cmd)

	if bin := os.get_env("TELEGRAF_BIN", context.temp_allocator); strings.trim_space(bin) != "" {
		append(&cmd, bin, "--config", conf_file)
	} else if path := bridge_runtime_find_on_path("telegraf"); path != "" {
		append(&cmd, path, "--config", conf_file)
	} else if nix_shell := bridge_runtime_find_on_path("nix-shell"); nix_shell != "" {
		append(&cmd, nix_shell, "-p", "telegraf", "--run", fmt.tprintf("exec telegraf --config %s", conf_file))
	} else {
		append(&cmd, "telegraf", "--config", conf_file)
	}

	proc_handle, start_err := os.process_start(os.Process_Desc{
		command = cmd[:],
	})
	if start_err != nil {
		fmt.eprintln("bridge telemetry: failed to spawn telegraf:", start_err)
		return false
	}

	bridge_telemetry_process = proc_handle
	bridge_telemetry_running = true
	if bridge_telemetry_active_conf_path != "" {
		delete(bridge_telemetry_active_conf_path)
	}
	bridge_telemetry_active_conf_path = strings.clone(conf_file)

	fmt.println("bridge telemetry: supervisor started telegraf pid=", proc_handle.pid, "conf=", conf_file)
	return true
}

bridge_telemetry_stop :: proc() -> bool {
	sync.mutex_lock(&bridge_telemetry_mu)
	defer sync.mutex_unlock(&bridge_telemetry_mu)

	if !bridge_telemetry_running do return true

	// Check if already dead
	if state, err := os.process_wait(bridge_telemetry_process, 0); err == nil && state.exited {
		bridge_telemetry_running = false
		if bridge_telemetry_active_conf_path != "" {
			_ = os.remove(bridge_telemetry_active_conf_path)
			delete(bridge_telemetry_active_conf_path)
			bridge_telemetry_active_conf_path = ""
		}
		return true
	}

	// Graceful SIGTERM
	if bridge_telemetry_process.pid > 0 {
		_ = os.process_terminate(bridge_telemetry_process)
		when ODIN_OS != .Windows {
			_ = posix.kill(posix.pid_t(bridge_telemetry_process.pid), .SIGTERM)
		}
	}

	deadline := time.to_unix_nanoseconds(time.now()) + i64(2 * time.Second)
	exited := false
	for time.to_unix_nanoseconds(time.now()) < deadline {
		if state, err := os.process_wait(bridge_telemetry_process, 50 * time.Millisecond); err == nil && state.exited {
			exited = true
			break
		}
	}

	if !exited && bridge_telemetry_process.pid > 0 {
		_ = os.process_kill(bridge_telemetry_process)
		when ODIN_OS != .Windows {
			_ = posix.kill(posix.pid_t(bridge_telemetry_process.pid), .SIGKILL)
		}
		_, _ = os.process_wait(bridge_telemetry_process, 500 * time.Millisecond)
	}

	if bridge_telemetry_active_conf_path != "" {
		_ = os.remove(bridge_telemetry_active_conf_path)
		delete(bridge_telemetry_active_conf_path)
		bridge_telemetry_active_conf_path = ""
	}

	bridge_telemetry_running = false
	bridge_telemetry_process = {}
	fmt.println("bridge telemetry: supervisor stopped telegraf")
	return true
}

bridge_telemetry_looks_like_agents_count :: proc(line: string) -> bool {
	if !strings.has_prefix(line, "GET ") do return false
	rest := line[4:]
	return strings.has_prefix(rest, "/api/v1/telemetry/agents-count")
}

bridge_telemetry_agents_count_json :: proc(allocator := context.allocator) -> string {
	count := bridge_runtime_active_agent_count()
	return fmt.aprintf("{{\"active_count\":%d}}", count, allocator = allocator)
}

bridge_telemetry_agents_count_http_response :: proc(allocator := context.allocator) -> string {
	body := bridge_telemetry_agents_count_json(context.temp_allocator)
	b := strings.builder_make(allocator)
	strings.write_string(&b, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ")
	strings.write_int(&b, len(body))
	strings.write_string(&b, "\r\n\r\n")
	strings.write_string(&b, body)
	return strings.to_string(b)
}

bridge_telemetry_looks_like_processes :: proc(line: string) -> bool {
	if !strings.has_prefix(line, "GET ") do return false
	rest := line[4:]
	return strings.has_prefix(rest, "/api/v1/telemetry/processes")
}

bridge_telemetry_processes_http_response :: proc(allocator := context.allocator) -> string {
	body := process_tree_get_cached_prometheus(context.temp_allocator)
	b := strings.builder_make(allocator)
	strings.write_string(&b, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4; charset=utf-8\r\nConnection: close\r\nContent-Length: ")
	strings.write_int(&b, len(body))
	strings.write_string(&b, "\r\n\r\n")
	strings.write_string(&b, body)
	return strings.to_string(b)
}
