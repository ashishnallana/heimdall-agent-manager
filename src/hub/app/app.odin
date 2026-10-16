package app

import "core:fmt"
import "core:thread"
import metrics "odin_test:lib/metrics"
import http "odin_test:hub/transport/http"
import taskv2 "odin_test:hub/service/taskv2"

run :: proc(config: Hub_Config) -> (bool, string) {
	graph: App_Graph
	ok, message := build_graph(&graph, config)
	if !ok do return false, message
	// The Hub is a long-running HTTP process; shutdown_graph is intentionally only
	// used by tests that construct App_Graph directly.
	// Background stale-instance reaper: flips agents to 'unreachable' when their
	// bridge stops heartbeating, independent of inbound bridge traffic. Launched
	// before the blocking serve. We pass &graph directly: run() blocks on serve()
	// for the process lifetime, so this stack frame (and every service pointer the
	// graph holds) stays valid — exactly like &graph.router handed to serve below.
	// A heap COPY would be unsafe: the graph's services store pointers back into
	// this graph's own fields, so a copy would alias the original anyway.
	thread.run_with_data(rawptr(&graph), reaper_thread_entry)
	// Task System v2: rebuild timers from the columns, heal lease-less
	// in_progress rows, match every Active chain once, then run the thin timer
	// thread (1 s probe of the in-memory heap; the columns stay the truth).
	taskv2.boot(&graph.task_engine)
	_ = taskv2.start_timer_thread(&graph.task_engine)
	// Private Prometheus endpoint, off unless --metrics-addr is set.
	start_metrics_listener(metrics.global(), config.metrics_addr)
	if config.ui_origin == "" do fmt.eprintln("ham-hub WARNING: --ui-origin is empty; CSRF protection is disabled")
	served := http.serve(&graph.router, http.Server_Config{
		bind_host = config.bind_host,
		port = config.port,
		preview_origin = config.preview_origin,
		ui_origin = config.ui_origin,
		preview_ctx = rawptr(&graph.shell_session_stream_handlers),
		preview_handler = http.preview_origin_handler,
	})
	if !served do return false, "hub server failed"
	return true, "hub server stopped"
}

// reaper_thread_entry adapts reaper_loop to the thread.run_with_data ABI.
reaper_thread_entry :: proc(data: rawptr) {
	if data == nil do return
	reaper_loop((^App_Graph)(data))
}
