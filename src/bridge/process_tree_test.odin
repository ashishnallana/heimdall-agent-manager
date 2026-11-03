package main

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// Serializes tests that read or seed the process-global process-tree cache, so
// a seeded fixture is never observed by another test's endpoint response.
process_tree_cache_fixture_mu: sync.Mutex

// REQ-PTREE-1: Portable POSIX ps parser handles Linux and macOS Darwin output cleanly.
@(test)
test_process_tree_parse_ps_linux :: proc(t: ^testing.T) {
	sample_linux := `      1       0 17988  1.8 /sbin/init splash
      2       0     0  0.0 [kthreadd]
    123       1  1024  0.5 /usr/bin/ham-pty-host daemon --socket /tmp/pty.sock
   1001     123 20480  2.1 /usr/bin/node /home/user/agent/worker.js --role worker
   1002    1001  5120  0.0 /bin/bash -c "echo hello world && odin build"
`
	procs := process_tree_parse_ps_output(sample_linux, context.allocator)
	defer process_tree_destroy_raw(&procs)

	testing.expect_value(t, len(procs), 5)

	testing.expect_value(t, procs[0].pid, 1)
	testing.expect_value(t, procs[0].ppid, 0)
	testing.expect_value(t, procs[0].rss_kb, 17988)
	testing.expect(t, procs[0].cpu_percent > 1.7 && procs[0].cpu_percent < 1.9, "cpu around 1.8")
	testing.expect_value(t, procs[0].command, "/sbin/init splash")

	testing.expect_value(t, procs[1].pid, 2)
	testing.expect_value(t, procs[1].ppid, 0)
	testing.expect_value(t, procs[1].rss_kb, 0)
	testing.expect_value(t, procs[1].cpu_percent, 0.0)
	testing.expect_value(t, procs[1].command, "[kthreadd]")

	testing.expect_value(t, procs[2].pid, 123)
	testing.expect_value(t, procs[2].ppid, 1)
	testing.expect_value(t, procs[2].command, "/usr/bin/ham-pty-host daemon --socket /tmp/pty.sock")

	testing.expect_value(t, procs[3].pid, 1001)
	testing.expect_value(t, procs[3].ppid, 123)
	testing.expect_value(t, procs[3].rss_kb, 20480)
	testing.expect(t, procs[3].cpu_percent > 2.0 && procs[3].cpu_percent < 2.2, "cpu around 2.1")

	testing.expect_value(t, procs[4].pid, 1002)
	testing.expect_value(t, procs[4].ppid, 1001)
	testing.expect_value(t, procs[4].command, `/bin/bash -c "echo hello world && odin build"`)
}

@(test)
test_process_tree_parse_ps_macos :: proc(t: ^testing.T) {
	sample_macos := `    1     0 12480   0.1 /sbin/launchd
  501     1 45820   2.3 /Applications/Heimdall.app/Contents/MacOS/ham-pty-host daemon --socket /tmp/bridge.sock
 1234   501  4096   0.0 /bin/zsh -l
 1235  1234 16384  12.5 /opt/homebrew/bin/python3 -m unittest
`
	procs := process_tree_parse_ps_output(sample_macos, context.allocator)
	defer process_tree_destroy_raw(&procs)

	testing.expect_value(t, len(procs), 4)

	testing.expect_value(t, procs[0].pid, 1)
	testing.expect_value(t, procs[0].ppid, 0)
	testing.expect_value(t, procs[0].rss_kb, 12480)
	testing.expect(t, procs[0].cpu_percent > 0.05 && procs[0].cpu_percent < 0.15, "cpu 0.1")
	testing.expect_value(t, procs[0].command, "/sbin/launchd")

	testing.expect_value(t, procs[1].pid, 501)
	testing.expect_value(t, procs[1].ppid, 1)
	testing.expect_value(t, procs[1].rss_kb, 45820)
	testing.expect(t, procs[1].cpu_percent > 2.2 && procs[1].cpu_percent < 2.4, "cpu 2.3")
	testing.expect_value(t, procs[1].command, "/Applications/Heimdall.app/Contents/MacOS/ham-pty-host daemon --socket /tmp/bridge.sock")

	testing.expect_value(t, procs[2].pid, 1234)
	testing.expect_value(t, procs[2].ppid, 501)
	testing.expect_value(t, procs[2].rss_kb, 4096)

	testing.expect_value(t, procs[3].pid, 1235)
	testing.expect_value(t, procs[3].ppid, 1234)
	testing.expect_value(t, procs[3].rss_kb, 16384)
	testing.expect(t, procs[3].cpu_percent > 12.4 && procs[3].cpu_percent < 12.6, "cpu 12.5")
	testing.expect_value(t, procs[3].command, "/opt/homebrew/bin/python3 -m unittest")
}

// REQ-PTREE-2: Descendant process tree accurately walks PPID links and attributes metadata.
@(test)
test_process_tree_build_and_attribute :: proc(t: ^testing.T) {
	raw_procs := []Process_Raw{
		{pid = 100, ppid = 1, rss_kb = 1024, cpu_percent = 0.5, command = "/bin/ham-pty-host daemon --socket /tmp/s.sock"},
		{pid = 200, ppid = 100, rss_kb = 20480, cpu_percent = 1.5, command = "node worker.js"},
		{pid = 201, ppid = 200, rss_kb = 4096, cpu_percent = 0.2, command = "bash -c odin build"},
		{pid = 202, ppid = 201, rss_kb = 8192, cpu_percent = 3.0, command = "odin build"},
		{pid = 300, ppid = 100, rss_kb = 16384, cpu_percent = 0.8, command = "python3 coord.py"},
		{pid = 301, ppid = 300, rss_kb = 2048, cpu_percent = 0.1, command = "git status"},
		{pid = 999, ppid = 1, rss_kb = 51200, cpu_percent = 0.0, command = "sshd: ambient_user"},
	}

	agents := []Pty_Host_Agent_Info{
		{instance_id = "inst_worker_1", pid = 200, alive = true},
		{instance_id = "inst_coord_1", pid = 300, alive = true},
	}

	test_resolver := proc(instance_id: string, alloc: runtime.Allocator) -> (string, string) {
		if instance_id == "inst_worker_1" do return "worker", "chain_w99"
		if instance_id == "inst_coord_1" do return "coordinator", "chain_c77"
		return "worker", ""
	}

	nodes := process_tree_build_nodes(raw_procs, agents, test_resolver, context.allocator)
	defer process_tree_destroy_nodes(&nodes)

	// Should contain: 100 (pty-host), 200, 201, 202 (worker_1), 300, 301 (coord_1).
	// Unrelated 999 must NOT be included!
	testing.expect_value(t, len(nodes), 6)

	node_map := make(map[i32]Process_Node, context.temp_allocator)
	for n in nodes {
		node_map[n.pid] = n
	}

	// 999 not present
	testing.expect(t, !(999 in node_map), "ambient system process 999 must not be included")

	// 100 is ham-pty-host daemon
	n100 := node_map[100]
	testing.expect_value(t, n100.instance_id, "ham-pty-host")
	testing.expect_value(t, n100.role, "daemon")
	testing.expect_value(t, n100.chain_id, "")
	testing.expect_value(t, n100.is_root, true)
	testing.expect_value(t, n100.rss_bytes, 1024 * 1024)

	// 200 is worker root
	n200 := node_map[200]
	testing.expect_value(t, n200.instance_id, "inst_worker_1")
	testing.expect_value(t, n200.role, "worker")
	testing.expect_value(t, n200.chain_id, "chain_w99")
	testing.expect_value(t, n200.is_root, true)
	testing.expect_value(t, n200.rss_bytes, 20480 * 1024)

	// 201 is worker child
	n201 := node_map[201]
	testing.expect_value(t, n201.instance_id, "inst_worker_1")
	testing.expect_value(t, n201.role, "worker")
	testing.expect_value(t, n201.chain_id, "chain_w99")
	testing.expect_value(t, n201.is_root, false)

	// 202 is worker grandchild
	n202 := node_map[202]
	testing.expect_value(t, n202.instance_id, "inst_worker_1")
	testing.expect_value(t, n202.role, "worker")
	testing.expect_value(t, n202.chain_id, "chain_w99")
	testing.expect_value(t, n202.is_root, false)

	// 300 is coordinator root
	n300 := node_map[300]
	testing.expect_value(t, n300.instance_id, "inst_coord_1")
	testing.expect_value(t, n300.role, "coordinator")
	testing.expect_value(t, n300.chain_id, "chain_c77")
	testing.expect_value(t, n300.is_root, true)

	// 301 is coordinator child
	n301 := node_map[301]
	testing.expect_value(t, n301.instance_id, "inst_coord_1")
	testing.expect_value(t, n301.role, "coordinator")
	testing.expect_value(t, n301.chain_id, "chain_c77")
	testing.expect_value(t, n301.is_root, false)
}

// REQ-PTREE-3: Endpoint Prometheus formatting.
@(test)
test_process_tree_prometheus_formatting :: proc(t: ^testing.T) {
	nodes := []Process_Node{
		{
			pid = 200,
			ppid = 100,
			rss_bytes = 20971520,
			cpu_percent = 2.1,
			num_threads = 4,
			command = "node worker.js",
			instance_id = "inst_worker_1",
			role = "worker",
			chain_id = "chain_w99",
			is_root = true,
		},
	}

	prom := bridge_process_tree_format_prometheus(nodes, context.allocator)
	defer delete(prom)

	// Check HELP and TYPE
	testing.expect(t, strings.contains(prom, "# HELP heimdall_process_cpu_percent CPU percentage used by process\n"), "has cpu HELP")
	testing.expect(t, strings.contains(prom, "# TYPE heimdall_process_cpu_percent gauge\n"), "has cpu TYPE")
	testing.expect(t, strings.contains(prom, "# HELP heimdall_process_memory_rss_bytes Resident memory size in bytes\n"), "has rss HELP")
	testing.expect(t, strings.contains(prom, "# TYPE heimdall_process_memory_rss_bytes gauge\n"), "has rss TYPE")
	testing.expect(t, strings.contains(prom, "# HELP heimdall_process_num_threads Number of threads in process\n"), "has threads HELP")
	testing.expect(t, strings.contains(prom, "# TYPE heimdall_process_num_threads gauge\n"), "has threads TYPE")

	// Check exact metric samples
	expected_cpu := `heimdall_process_cpu_percent{instance_id="inst_worker_1",role="worker",chain_id="chain_w99",pid="200"} 2.1`
	testing.expect(t, strings.contains(prom, expected_cpu), "matches expected cpu sample")

	expected_rss := `heimdall_process_memory_rss_bytes{instance_id="inst_worker_1",role="worker",chain_id="chain_w99",pid="200"} 20971520`
	testing.expect(t, strings.contains(prom, expected_rss), "matches expected rss sample")

	expected_threads := `heimdall_process_num_threads{instance_id="inst_worker_1",role="worker",chain_id="chain_w99",pid="200"} 4`
	testing.expect(t, strings.contains(prom, expected_threads), "matches expected threads sample")
}

@(test)
test_process_tree_endpoint_matchers :: proc(t: ^testing.T) {
	sync.mutex_lock(&process_tree_cache_fixture_mu)
	defer sync.mutex_unlock(&process_tree_cache_fixture_mu)
	testing.expect(t, bridge_telemetry_looks_like_processes("GET /api/v1/telemetry/processes HTTP/1.1"), "valid GET matches")
	testing.expect(t, bridge_telemetry_looks_like_processes("GET /api/v1/telemetry/processes"), "prefix matches")
	testing.expect(t, bridge_telemetry_looks_like_processes("GET /api/v1/telemetry/processes?format=prom"), "query param matches")
	testing.expect(t, !bridge_telemetry_looks_like_processes("POST /api/v1/telemetry/processes HTTP/1.1"), "POST rejected")
	testing.expect(t, !bridge_telemetry_looks_like_processes("GET /api/v1/telemetry/agents-count"), "agents-count not matched")
	testing.expect(t, !bridge_telemetry_looks_like_processes("GET /api/v1/projects"), "projects not matched")

	resp := bridge_telemetry_processes_http_response()
	defer delete(resp)
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 200 OK\r\n"), "HTTP 200 status line")
	testing.expect(t, strings.contains(resp, "Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n"), "Content-Type text/plain")
	testing.expect(t, strings.contains(resp, "heimdall_process_"), "Contains process metrics in body")
}

@(test)
test_process_tree_cache_ttl :: proc(t: ^testing.T) {
	sync.mutex_lock(&process_tree_cache_fixture_mu)
	defer sync.mutex_unlock(&process_tree_cache_fixture_mu)
	process_tree_reset_cache()
	defer process_tree_reset_cache()

	// Seed a fresh cache entry instead of collecting live data: a live collection
	// queries the process-global pty-host daemon socket (other tests point it at
	// mocks) and can outlast the 2s TTL under load, making p1 != p2.
	sync.mutex_lock(&process_tree_cache_mu)
	process_tree_cached_prometheus = strings.clone("seeded_metric 1\n", runtime.heap_allocator())
	process_tree_cache_tick = time.tick_now()
	process_tree_has_cache = true
	sync.mutex_unlock(&process_tree_cache_mu)

	p1 := process_tree_get_cached_prometheus(context.allocator)
	defer delete(p1)

	p2 := process_tree_get_cached_prometheus(context.allocator)
	defer delete(p2)

	testing.expect_value(t, p1, "seeded_metric 1\n")
	testing.expect_value(t, p1, p2)
}

@(test)
test_process_tree_agents_md_metadata :: proc(t: ^testing.T) {
	sample_md := `# Agent bootstrap

Agent: worker #71
Instance: inst_18dab22ecb6a56ee
Task chain: Dynamic Telegraf Telemetry (chain_18dab0fc15f5d204)
Coordinator: inst_18dab0fc16af4da3
## Agent Identity & Instructions
`
	role, chain_id := process_tree_extract_metadata_from_agents_md(sample_md, context.allocator)
	defer delete(role)
	defer delete(chain_id)

	testing.expect_value(t, role, "worker")
	testing.expect_value(t, chain_id, "chain_18dab0fc15f5d204")
}
