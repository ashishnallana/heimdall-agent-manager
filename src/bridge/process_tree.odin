package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

// REQ-PTREE-1, REQ-PTREE-2, REQ-PTREE-3: Cross-platform process tree discovery
// and metrics attribution for dynamic telemetry.

Process_Raw :: struct {
	pid:         i32,
	ppid:        i32,
	rss_kb:      i64,
	cpu_percent: f64,
	command:     string,
}

Process_Node :: struct {
	pid:         i32,
	ppid:        i32,
	rss_bytes:   i64,
	cpu_percent: f64,
	num_threads: int,
	command:     string,
	instance_id: string,
	role:        string,
	chain_id:    string,
	is_root:     bool,
}

process_tree_cache_mu: sync.Mutex
process_tree_cached_prometheus: string
process_tree_cache_tick: time.Tick
process_tree_has_cache: bool

process_tree_parse_ps_line :: proc(line: string, allocator := context.allocator) -> (Process_Raw, bool) {
	trimmed := strings.trim_right(line, "\r\n")
	s := strings.trim_left_space(trimmed)
	if len(s) == 0 do return {}, false

	// 1. pid
	pid_end := strings.index_any(s, " \t")
	if pid_end < 0 do return {}, false
	pid_str := s[:pid_end]
	pid, pid_ok := strconv.parse_int(pid_str, 10)
	if !pid_ok do return {}, false
	s = strings.trim_left_space(s[pid_end:])

	// 2. ppid
	ppid_end := strings.index_any(s, " \t")
	if ppid_end < 0 do return {}, false
	ppid_str := s[:ppid_end]
	ppid, ppid_ok := strconv.parse_int(ppid_str, 10)
	if !ppid_ok do return {}, false
	s = strings.trim_left_space(s[ppid_end:])

	// 3. rss (KB)
	rss_end := strings.index_any(s, " \t")
	if rss_end < 0 do return {}, false
	rss_str := s[:rss_end]
	rss_kb, rss_ok := strconv.parse_i64(rss_str, 10)
	if !rss_ok do return {}, false
	s = strings.trim_left_space(s[rss_end:])

	// 4. %cpu
	cpu_end := strings.index_any(s, " \t")
	cpu_str: string
	cmd_str: string
	if cpu_end < 0 {
		cpu_str = s
		cmd_str = ""
	} else {
		cpu_str = s[:cpu_end]
		cmd_str = strings.trim_left_space(s[cpu_end:])
	}
	cpu_val: f64 = 0.0
	c_buf, _ := strings.replace_all(cpu_str, ",", ".", context.temp_allocator)
	if parsed_cpu, cpu_ok := strconv.parse_f64(c_buf); cpu_ok {
		cpu_val = parsed_cpu
	}

	return Process_Raw{
		pid = i32(pid),
		ppid = i32(ppid),
		rss_kb = rss_kb,
		cpu_percent = cpu_val,
		command = strings.clone(cmd_str, allocator),
	}, true
}

process_tree_parse_ps_output :: proc(output: string, allocator := context.allocator) -> [dynamic]Process_Raw {
	res := make([dynamic]Process_Raw, allocator)
	lines := strings.split_lines(output, context.temp_allocator)
	for line in lines {
		raw, ok := process_tree_parse_ps_line(line, allocator)
		if ok {
			append(&res, raw)
		}
	}
	return res
}

process_tree_free_raw :: proc(procs: []Process_Raw, allocator := context.allocator) {
	for p in procs {
		if len(p.command) > 0 do delete(p.command, allocator)
	}
}

process_tree_destroy_raw :: proc(procs: ^[dynamic]Process_Raw, allocator := context.allocator) {
	if procs == nil do return
	process_tree_free_raw(procs[:], allocator)
	delete(procs^)
}

process_tree_free_nodes :: proc(nodes: []Process_Node, allocator := context.allocator) {
	for n in nodes {
		if len(n.command) > 0 do delete(n.command, allocator)
		if len(n.instance_id) > 0 do delete(n.instance_id, allocator)
		if len(n.role) > 0 do delete(n.role, allocator)
		if len(n.chain_id) > 0 do delete(n.chain_id, allocator)
	}
}

process_tree_destroy_nodes :: proc(nodes: ^[dynamic]Process_Node, allocator := context.allocator) {
	if nodes == nil do return
	process_tree_free_nodes(nodes[:], allocator)
	delete(nodes^)
}

process_tree_get_threads :: proc(pid: i32) -> int {
	when ODIN_OS == .Linux {
		status_path := fmt.tprintf("/proc/%d/status", pid)
		if data, err := os.read_entire_file(status_path, context.temp_allocator); err == nil {
			s := string(data)
			idx := strings.index(s, "Threads:")
			if idx >= 0 {
				rest := strings.trim_left_space(s[idx + 8:])
				end := strings.index_any(rest, "\r\n \t")
				num_str := end >= 0 ? rest[:end] : rest
				if th, ok := strconv.parse_int(num_str, 10); ok && th > 0 {
					return th
				}
			}
		}
	}
	return 1
}

process_tree_extract_metadata_from_agents_md :: proc(content: string, allocator := context.allocator) -> (role: string, chain_id: string) {
	lines := strings.split_lines(content, context.temp_allocator)
	role_val := ""
	chain_val := ""

	for line in lines {
		l := strings.trim_space(line)
		if strings.has_prefix(l, "Agent:") {
			agent_str := strings.trim_space(l[6:])
			if strings.contains(agent_str, "coordinator") {
				role_val = "coordinator"
			} else if strings.contains(agent_str, "reviewer") {
				role_val = "reviewer"
			} else if strings.contains(agent_str, "worker") {
				role_val = "worker"
			} else if role_val == "" {
				role_val = agent_str
			}
		} else if strings.has_prefix(l, "Role:") {
			role_str := strings.trim_space(l[5:])
			if role_val == "" do role_val = role_str
		} else if strings.has_prefix(l, "Task chain:") {
			if open_paren := strings.last_index_byte(l, '('); open_paren >= 0 {
				if close_paren := strings.last_index_byte(l, ')'); close_paren > open_paren {
					chain_val = strings.trim_space(l[open_paren + 1:close_paren])
				}
			}
		}
	}

	if role_val == "" do role_val = "worker"
	return strings.clone(role_val, allocator), strings.clone(chain_val, allocator)
}

process_tree_resolve_instance_metadata :: proc(instance_id: string, allocator := context.allocator) -> (role: string, chain_id: string) {
	if strings.has_prefix(instance_id, "sh_") {
		chain_id_val := ""
		if sess, found := bridge_shell_session_snapshot(&bridge_shell_session_map, instance_id); found {
			chain_id_val = strings.clone(sess.chain_id, context.temp_allocator)
			bridge_shell_session_snapshot_destroy(&bridge_shell_session_map, sess)
		}
		return strings.clone("worker", allocator), strings.clone(chain_id_val, allocator)
	}

	if strings.has_prefix(instance_id, "inst_") {
		role_val := ""
		chain_val := ""

		if launch, ok := bridge_runtime_get_launch(instance_id); ok {
			role_val = launch.role
		}

		run_dir := bridge_runtime_default_run_dir(instance_id)
		defer delete(run_dir)
		agents_path := strings.concatenate({run_dir, "/AGENTS.md"}, context.temp_allocator)
		if os.exists(agents_path) {
			if data, err := os.read_entire_file(agents_path, context.temp_allocator); err == nil {
				md_role, md_chain := process_tree_extract_metadata_from_agents_md(string(data), context.temp_allocator)
				if role_val == "" do role_val = md_role
				if chain_val == "" do chain_val = md_chain
			}
		}

		if role_val == "" do role_val = "worker"
		return strings.clone(role_val, allocator), strings.clone(chain_val, allocator)
	}

	return strings.clone("daemon", allocator), strings.clone("", allocator)
}

Process_Meta_Resolver :: #type proc(instance_id: string, allocator: runtime.Allocator) -> (string, string)

process_tree_build_nodes :: proc(
	raw_procs: []Process_Raw,
	agents: []Pty_Host_Agent_Info,
	meta_resolver: Process_Meta_Resolver = nil,
	allocator := context.allocator,
) -> [dynamic]Process_Node {
	resolver := meta_resolver
	if resolver == nil {
		resolver = proc(instance_id: string, alloc: runtime.Allocator) -> (string, string) {
			return process_tree_resolve_instance_metadata(instance_id, alloc)
		}
	}

	children := make(map[i32][dynamic]i32, len(raw_procs), context.temp_allocator)
	procs_by_pid := make(map[i32]Process_Raw, len(raw_procs), context.temp_allocator)

	for p in raw_procs {
		procs_by_pid[p.pid] = p
		if !(p.ppid in children) {
			children[p.ppid] = make([dynamic]i32, context.temp_allocator)
		}
		append(&children[p.ppid], p.pid)
	}

	visited := make(map[i32]bool, len(raw_procs), context.temp_allocator)
	nodes := make([dynamic]Process_Node, allocator)

	// 1. Traverse trees under active instance root PIDs
	for a in agents {
		if !a.alive || a.pid <= 0 do continue
		if a.pid in visited do continue

		role, chain_id := resolver(a.instance_id, context.temp_allocator)

		queue := make([dynamic]i32, context.temp_allocator)
		append(&queue, a.pid)

		for len(queue) > 0 {
			cur_pid := pop_front(&queue)
			if cur_pid in visited do continue
			visited[cur_pid] = true

			if raw, ok := procs_by_pid[cur_pid]; ok {
				append(&nodes, Process_Node{
					pid = raw.pid,
					ppid = raw.ppid,
					rss_bytes = raw.rss_kb * 1024,
					cpu_percent = raw.cpu_percent,
					num_threads = process_tree_get_threads(raw.pid),
					command = strings.clone(raw.command, allocator),
					instance_id = strings.clone(a.instance_id, allocator),
					role = strings.clone(role, allocator),
					chain_id = strings.clone(chain_id, allocator),
					is_root = (raw.pid == a.pid),
				})
			}

			if child_list, has_children := children[cur_pid]; has_children {
				for ch in child_list {
					if !(ch in visited) {
						append(&queue, ch)
					}
				}
			}
		}
	}

	// 2. Discover ham-pty-host daemon and unvisited daemon descendants
	for p in raw_procs {
		if p.pid in visited do continue
		is_pty_host := strings.contains(p.command, "ham-pty-host") && strings.contains(p.command, "daemon")
		if is_pty_host {
			visited[p.pid] = true
			append(&nodes, Process_Node{
				pid = p.pid,
				ppid = p.ppid,
				rss_bytes = p.rss_kb * 1024,
				cpu_percent = p.cpu_percent,
				num_threads = process_tree_get_threads(p.pid),
				command = strings.clone(p.command, allocator),
				instance_id = strings.clone("ham-pty-host", allocator),
				role = strings.clone("daemon", allocator),
				chain_id = strings.clone("", allocator),
				is_root = true,
			})

			queue := make([dynamic]i32, context.temp_allocator)
			if child_list, has_children := children[p.pid]; has_children {
				for ch in child_list {
					if !(ch in visited) {
						append(&queue, ch)
					}
				}
			}
			for len(queue) > 0 {
				cur_pid := pop_front(&queue)
				if cur_pid in visited do continue
				visited[cur_pid] = true

				if raw, ok := procs_by_pid[cur_pid]; ok {
					append(&nodes, Process_Node{
						pid = raw.pid,
						ppid = raw.ppid,
						rss_bytes = raw.rss_kb * 1024,
						cpu_percent = raw.cpu_percent,
						num_threads = process_tree_get_threads(raw.pid),
						command = strings.clone(raw.command, allocator),
						instance_id = strings.clone("ham-pty-host", allocator),
						role = strings.clone("daemon", allocator),
						chain_id = strings.clone("", allocator),
						is_root = false,
					})
				}

				if child_list, has_children := children[cur_pid]; has_children {
					for ch in child_list {
						if !(ch in visited) {
							append(&queue, ch)
						}
					}
				}
			}
		}
	}

	slice.sort_by(nodes[:], proc(i, j: Process_Node) -> bool {
		return i.pid < j.pid
	})

	return nodes
}

// Bridge_Ps_Cpu_Column picks the cpu column of bridge_os_ps rows.
Bridge_Ps_Cpu_Column :: enum {
	Cputime, // [[dd-]hh:]mm:ss of cpu time
	Percent, // %cpu
}

process_tree_run_ps :: proc(allocator := context.allocator) -> (output: string, ok: bool) {
	return bridge_os_ps(.Percent, allocator)
}

process_tree_collect_live :: proc(allocator := context.allocator) -> ([dynamic]Process_Node, bool) {
	ps_output, ps_ok := process_tree_run_ps(context.temp_allocator)
	if !ps_ok do return nil, false

	raw_procs := process_tree_parse_ps_output(ps_output, context.temp_allocator)
	defer process_tree_free_raw(raw_procs[:], context.temp_allocator)
	defer delete(raw_procs)

	socket, sock_ok := bridge_pty_host_ensure_daemon()
	agents: []Pty_Host_Agent_Info
	reply: Pty_Host_Reply
	have_reply := false
	if sock_ok {
		r, ok := bridge_pty_host_list(socket)
		if ok {
			reply = r
			agents = reply.agents
			have_reply = true
		}
	}

	if (!have_reply || len(agents) == 0) {
		for p in raw_procs {
			if strings.contains(p.command, "ham-pty-host") && strings.contains(p.command, "--socket") {
				if idx := strings.index(p.command, "--socket"); idx >= 0 {
					rest := strings.trim_left_space(p.command[idx + 8:])
					end := strings.index_any(rest, " \t\r\n")
					sock_path := end >= 0 ? rest[:end] : rest
					if sock_path != "" && sock_path != socket {
						r, ok := bridge_pty_host_list(sock_path)
						if ok {
							if have_reply do pty_host_reply_delete(reply)
							reply = r
							agents = reply.agents
							have_reply = true
							break
						}
					}
				}
			}
		}
	}
	defer if have_reply do pty_host_reply_delete(reply)

	nodes := process_tree_build_nodes(raw_procs[:], agents, nil, allocator)
	return nodes, true
}

bridge_process_tree_format_prometheus :: proc(nodes: []Process_Node, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)

	// 1. heimdall_process_cpu_percent
	strings.write_string(&b, "# HELP heimdall_process_cpu_percent CPU percentage used by process\n")
	strings.write_string(&b, "# TYPE heimdall_process_cpu_percent gauge\n")
	for n in nodes {
		fmt.sbprintf(&b, "heimdall_process_cpu_percent{{instance_id=\"%s\",role=\"%s\",chain_id=\"%s\",pid=\"%d\"}} %.1f\n",
			n.instance_id, n.role, n.chain_id, n.pid, n.cpu_percent)
	}

	// 2. heimdall_process_memory_rss_bytes
	strings.write_string(&b, "# HELP heimdall_process_memory_rss_bytes Resident memory size in bytes\n")
	strings.write_string(&b, "# TYPE heimdall_process_memory_rss_bytes gauge\n")
	for n in nodes {
		fmt.sbprintf(&b, "heimdall_process_memory_rss_bytes{{instance_id=\"%s\",role=\"%s\",chain_id=\"%s\",pid=\"%d\"}} %d\n",
			n.instance_id, n.role, n.chain_id, n.pid, n.rss_bytes)
	}

	// 3. heimdall_process_num_threads
	strings.write_string(&b, "# HELP heimdall_process_num_threads Number of threads in process\n")
	strings.write_string(&b, "# TYPE heimdall_process_num_threads gauge\n")
	for n in nodes {
		fmt.sbprintf(&b, "heimdall_process_num_threads{{instance_id=\"%s\",role=\"%s\",chain_id=\"%s\",pid=\"%d\"}} %d\n",
			n.instance_id, n.role, n.chain_id, n.pid, n.num_threads)
	}

	return strings.to_string(b)
}

process_tree_get_cached_prometheus :: proc(allocator := context.allocator) -> string {
	sync.mutex_lock(&process_tree_cache_mu)
	defer sync.mutex_unlock(&process_tree_cache_mu)

	now := time.tick_now()
	if process_tree_has_cache && time.tick_diff(process_tree_cache_tick, now) < 2 * time.Second {
		return strings.clone(process_tree_cached_prometheus, allocator)
	}

	nodes, ok := process_tree_collect_live(context.temp_allocator)
	if !ok {
		if process_tree_has_cache {
			return strings.clone(process_tree_cached_prometheus, allocator)
		}
		return bridge_process_tree_format_prometheus(nil, allocator)
	}
	defer process_tree_free_nodes(nodes[:], context.temp_allocator)
	defer delete(nodes)

	prom := bridge_process_tree_format_prometheus(nodes[:], context.allocator)
	if process_tree_cached_prometheus != "" {
		delete(process_tree_cached_prometheus)
	}
	process_tree_cached_prometheus = prom
	process_tree_cache_tick = now
	process_tree_has_cache = true

	return strings.clone(prom, allocator)
}

process_tree_reset_cache :: proc() {
	sync.mutex_lock(&process_tree_cache_mu)
	defer sync.mutex_unlock(&process_tree_cache_mu)
	if process_tree_cached_prometheus != "" {
		delete(process_tree_cached_prometheus)
		process_tree_cached_prometheus = ""
	}
	process_tree_has_cache = false
}
