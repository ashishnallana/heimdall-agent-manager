package metrics

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
test_registry :: proc() -> ^Registry {
	reg := new(Registry, runtime.heap_allocator())
	registry_init(reg, runtime.heap_allocator())
	return reg
}

@(private = "file")
test_registry_free :: proc(reg: ^Registry) {
	registry_destroy(reg)
	free(reg, runtime.heap_allocator())
}

@(private = "file")
scrape :: proc(reg: ^Registry) -> string {
	b := strings.builder_make(context.allocator)
	gather(reg, &b)
	return strings.to_string(b)
}

// Golden exposition: counter, gauge (scaled), histogram, escaping, ordering.
@(test)
test_exposition_golden :: proc(t: ^testing.T) {
	reg := test_registry()
	defer test_registry_free(reg)

	c := new_counter(reg, "t_requests_total", "Requests \"seen\"\nso far.", {"route", "method"})
	counter_add(with(c, "/api/v1/x/*", "GET"), 3)
	counter_inc(with(c, "quo\"te\\back\nline", "POST"))
	g := new_gauge(reg, "t_cpu_seconds", "CPU.", nil, 2)
	gauge_set(with(g), 1234)
	h := new_histogram_seconds(reg, "t_latency_seconds", "Latency.", {"route"}, {0.01, 0.25, 1})
	s := with(h, "r")
	observe_duration(s, 5 * time.Millisecond)
	observe_duration(s, 10 * time.Millisecond) // on the bound: inclusive
	observe_duration(s, 500 * time.Millisecond)
	observe_duration(s, 7 * time.Second)

	out := scrape(reg)
	defer delete(out)
	expected := strings.concatenate({
		"# HELP t_requests_total Requests \"seen\"\\nso far.\n",
		"# TYPE t_requests_total counter\n",
		"t_requests_total{route=\"/api/v1/x/*\",method=\"GET\"} 3\n",
		"t_requests_total{route=\"quo\\\"te\\\\back\\nline\",method=\"POST\"} 1\n",
		"# HELP t_cpu_seconds CPU.\n",
		"# TYPE t_cpu_seconds gauge\n",
		"t_cpu_seconds 12.34\n",
		"# HELP t_latency_seconds Latency.\n",
		"# TYPE t_latency_seconds histogram\n",
		"t_latency_seconds_bucket{route=\"r\",le=\"0.01\"} 2\n",
		"t_latency_seconds_bucket{route=\"r\",le=\"0.25\"} 2\n",
		"t_latency_seconds_bucket{route=\"r\",le=\"1\"} 3\n",
		"t_latency_seconds_bucket{route=\"r\",le=\"+Inf\"} 4\n",
		"t_latency_seconds_sum{route=\"r\"} 7.515\n",
		"t_latency_seconds_count{route=\"r\"} 4\n",
		"# HELP heimdall_metrics_series Number of live series in the last scrape.\n",
		"# TYPE heimdall_metrics_series gauge\n",
		"heimdall_metrics_series 6\n",
		"# HELP heimdall_metrics_scrape_duration_seconds Wall time spent producing the last scrape.\n",
		"# TYPE heimdall_metrics_scrape_duration_seconds gauge\n",
		"heimdall_metrics_scrape_duration_seconds ",
	})
	defer delete(expected)
	testing.expectf(t, strings.has_prefix(out, expected), "golden mismatch.\n--- got ---\n%s\n--- want prefix ---\n%s", out, expected)
	testing.expect(t, strings.has_suffix(out, "\n"), "exposition ends with newline")
}

// Histogram buckets are cumulative and +Inf equals count.
@(test)
test_histogram_cumulative_buckets :: proc(t: ^testing.T) {
	reg := test_registry()
	defer test_registry_free(reg)
	h := new_histogram(reg, "t_bytes", "Bytes.", {}, {10, 100, 1000}, 0)
	s := with(h)
	for v in ([]u64{1, 10, 11, 100, 101, 1000, 1001, 5000}) do observe(s, v)
	testing.expect_value(t, histogram_count(s), u64(8))
	out := scrape(reg)
	defer delete(out)
	testing.expect(t, strings.contains(out, "t_bytes_bucket{le=\"10\"} 2\n"), "le=10")
	testing.expect(t, strings.contains(out, "t_bytes_bucket{le=\"100\"} 4\n"), "le=100")
	testing.expect(t, strings.contains(out, "t_bytes_bucket{le=\"1000\"} 6\n"), "le=1000")
	testing.expect(t, strings.contains(out, "t_bytes_bucket{le=\"+Inf\"} 8\n"), "le=+Inf")
	testing.expect(t, strings.contains(out, "t_bytes_sum 7224\n"), "sum")
	testing.expect(t, strings.contains(out, "t_bytes_count 8\n"), "count")
}

// Removing a series tombstones it (hidden from scrapes, pointer still valid),
// and re-creating it revives the SAME pointer with zeroed values.
@(test)
test_tombstone_and_revive :: proc(t: ^testing.T) {
	reg := test_registry()
	defer test_registry_free(reg)
	g := new_gauge(reg, "t_bridge_info", "Info.", {"bridge_id", "owner"})
	s := with(g, "brg_1", "alice@example.com")
	gauge_set(s, 1)
	testing.expect_value(t, live_series_count(g), 1)

	testing.expect(t, remove(g, "brg_1", "alice@example.com"), "remove returns true")
	testing.expect(t, series_is_dead(s), "dead after remove")
	out := scrape(reg)
	testing.expect(t, !strings.contains(out, "t_bridge_info{"), "tombstoned series not exposed")
	delete(out)
	testing.expect_value(t, live_series_count(g), 0)
	gauge_set(s, 99) // writes through a cached pointer must not crash
	testing.expect(t, !remove(g, "brg_missing", "x"), "remove of unknown is false")

	s2 := with(g, "brg_1", "alice@example.com")
	testing.expect(t, s2 == s, "revive returns the same series pointer")
	testing.expect(t, !series_is_dead(s2), "alive again")
	testing.expect_value(t, gauge_value(s2), i64(0))
	gauge_set(s2, 1)
	out2 := scrape(reg)
	defer delete(out2)
	testing.expect(t, strings.contains(out2, "t_bridge_info{bridge_id=\"brg_1\",owner=\"alice@example.com\"} 1\n"), "revived series exposed")

	// remove_where: everything for one bridge, nothing else.
	with(g, "brg_2", "bob")
	with(g, "brg_2", "carol")
	testing.expect_value(t, remove_where(g, 0, "brg_2"), 2)
	testing.expect_value(t, live_series_count(g), 1)
}

// Series created while context.allocator is an arena that is destroyed right
// after must survive: the registry must clone with its own allocator.
@(test)
test_series_survive_request_arena :: proc(t: ^testing.T) {
	reg := test_registry()
	defer test_registry_free(reg)
	c := new_counter(reg, "t_arena_total", "Arena.", {"route", "method"})
	heap := context.allocator
	{
		arena: virtual.Arena
		testing.expect(t, virtual.arena_init_growing(&arena, 64 * 1024) == nil, "arena init")
		context.allocator = virtual.arena_allocator(&arena)
		context.temp_allocator = virtual.arena_allocator(&arena)
		// Build the label from arena memory so a non-cloned reference would dangle.
		route := strings.concatenate({"/api/v1/", "arena/", "*"})
		method := strings.clone("GET")
		counter_add(with(c, route, method), 7)
		// Overwrite then destroy the arena to make a dangling reference visible.
		for i in 0 ..< len(route) do (transmute([]byte)route)[i] = 'X'
		virtual.arena_destroy(&arena)
	}
	context.allocator = heap
	out := scrape(reg)
	defer delete(out)
	testing.expect(t, strings.contains(out, "t_arena_total{route=\"/api/v1/arena/*\",method=\"GET\"} 7\n"), "series intact after arena destroy")
	// A second lookup from a fresh arena must hit the existing series.
	s := with(c, "/api/v1/arena/*", "GET")
	testing.expect_value(t, counter_value(s), u64(7))
}

Hammer_Job :: struct {
	family: ^Family,
	hist:   ^Family,
	iters:  int,
	ready:  ^sync.Barrier,
}

@(private = "file")
hammer_worker :: proc(th: ^thread.Thread) {
	job := (^Hammer_Job)(th.data)
	sync.barrier_wait(job.ready)
	cached := with(job.family, "cached")
	for i in 0 ..< job.iters {
		counter_inc(cached)
		// Interleave fresh lookups so creation and lookup race with increments.
		counter_inc(with(job.family, "shared"))
		if i % 7 == 0 do counter_inc(with(job.family, i % 2 == 0 ? "even" : "odd"))
		observe(with(job.hist), u64(i % 50))
	}
}

// Concurrency hammer: many threads incrementing through cached and fresh
// lookups; totals must be exact.
@(test)
test_concurrency_hammer :: proc(t: ^testing.T) {
	reg := test_registry()
	defer test_registry_free(reg)
	c := new_counter(reg, "t_hammer_total", "Hammer.", {"kind"})
	h := new_histogram(reg, "t_hammer_hist", "Hist.", {}, {10, 20, 30, 40}, 0)
	N_THREADS :: 16
	ITERS :: 20_000
	barrier: sync.Barrier
	sync.barrier_init(&barrier, N_THREADS)
	jobs: [N_THREADS]Hammer_Job
	threads: [N_THREADS]^thread.Thread
	for i in 0 ..< N_THREADS {
		jobs[i] = Hammer_Job{family = c, hist = h, iters = ITERS, ready = &barrier}
		threads[i] = thread.create(hammer_worker)
		threads[i].data = &jobs[i]
		thread.start(threads[i])
	}
	// Scrape concurrently with the writers to exercise the shared lock path.
	for _ in 0 ..< 20 {
		out := scrape(reg)
		delete(out)
		time.sleep(time.Millisecond)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	testing.expect_value(t, counter_value(with(c, "cached")), u64(N_THREADS * ITERS))
	testing.expect_value(t, counter_value(with(c, "shared")), u64(N_THREADS * ITERS))
	even_odd := counter_value(with(c, "even")) + counter_value(with(c, "odd"))
	testing.expect_value(t, even_odd, u64(N_THREADS * ((ITERS + 6) / 7)))
	testing.expect_value(t, histogram_count(with(h)), u64(N_THREADS * ITERS))
	testing.expect_value(t, live_series_count(c), 4)
}

// Collectors run with no family lock held and can themselves create series.
@(private = "file")
locking_collector :: proc(ctx: rawptr, e: ^Exposition) {
	f := (^Family)(ctx)
	gauge_set(with(f, "from_collector"), 42)
	expo_header(e, "t_direct", "Direct.", .Gauge)
	expo_sample_i64(e, "t_direct", {"k"}, {"v"}, -5, 1)
}

@(test)
test_collector_can_touch_families :: proc(t: ^testing.T) {
	reg := test_registry()
	defer test_registry_free(reg)
	g := new_gauge(reg, "t_col", "Col.", {"src"})
	registry_add_collector(reg, rawptr(g), locking_collector)
	out := scrape(reg)
	defer delete(out)
	testing.expect(t, strings.contains(out, "t_direct{k=\"v\"} -0.5\n"), "direct sample with negative scaled value")
	testing.expect(t, strings.contains(out, "t_col{src=\"from_collector\"} 42\n"), "collector-set gauge exposed in the same scrape")
}

// Process collector (Linux): sanity-check the /proc readers.
@(test)
test_process_collector_linux :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		reg := test_registry()
		defer test_registry_free(reg)
		st := read_process_stats_linux(reg)
		testing.expect(t, st.ok, "stats read")
		testing.expect(t, st.resident_bytes > 1024 * 1024, "rss > 1 MiB")
		testing.expect(t, st.virtual_bytes >= st.resident_bytes, "vsize >= rss")
		testing.expect(t, st.threads >= 1, "threads")
		testing.expect(t, st.open_fds >= 3, "open fds")
		testing.expect(t, st.max_fds >= st.open_fds, "max fds")
		testing.expect(t, st.start_time_seconds > 1_600_000_000, "start time is epoch seconds")
		register_process_collector(reg)
		out := scrape(reg)
		defer delete(out)
		testing.expect(t, strings.contains(out, "# TYPE process_cpu_seconds_total counter\n"), "cpu header")
		testing.expect(t, strings.contains(out, "process_open_fds "), "fds sample")
	}
}

// Nil families/series are no-ops so instrumentation is safe before wiring.
@(test)
test_nil_safety :: proc(t: ^testing.T) {
	f: ^Family
	s := with(f, "a")
	testing.expect(t, s == nil, "nil family yields nil series")
	counter_inc(s)
	gauge_set(s, 1)
	observe(s, 1)
	observe_duration(s, time.Second)
	testing.expect(t, !remove(f, "a"), "remove on nil")
	testing.expect_value(t, remove_where(f, 0, "a"), 0)
}

// Scaled formatting edge cases.
@(test)
test_scaled_formatting :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_scaled_u64(&b, 0, 9)
	strings.write_byte(&b, '|')
	write_scaled_u64(&b, 1, 9)
	strings.write_byte(&b, '|')
	write_scaled_u64(&b, 1_500_000_000, 9)
	strings.write_byte(&b, '|')
	write_scaled_u64(&b, 100, 2)
	strings.write_byte(&b, '|')
	write_scaled_u64(&b, 7, 0)
	testing.expect_value(t, strings.to_string(b), "0|0.000000001|1.5|1|7")
}
