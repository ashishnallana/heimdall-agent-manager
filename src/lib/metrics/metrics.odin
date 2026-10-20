// Package metrics is a small, allocation-disciplined Prometheus client for the
// hub (and, later, the bridge).
//
// Design rules (see the hub telemetry plan, section 4.1):
//
//   - Every value is a u64/i64 atomic. Histogram sums are kept in integer
//     units (e.g. nanoseconds) and scaled at exposition time; there are no f64
//     CAS loops anywhere.
//   - A Registry captures an explicit heap `mem.Allocator` at init and uses it
//     for EVERY allocation it ever makes, including cloning label values out of
//     caller strings. Hub HTTP handlers run on a per-request arena that is
//     destroyed after the response, so touching context.allocator (or
//     context.temp_allocator) from inside this package would hand out dangling
//     series memory. Never do it.
//   - Series memory is never freed while the process runs. Removing a series
//     tombstones it (`dead = 1`); exposition skips it and `with()` revives it
//     with zeroed values. This is what makes cached `^Series` pointers in hot
//     paths safe without reference counting. `registry_destroy` exists only so
//     tests can release memory at the very end.
//   - Collectors are called by the exposition writer without ANY family lock
//     held. Hot paths may create series while holding runtime-registry locks;
//     a collector that then takes the same runtime lock would otherwise invert
//     the lock order.
package metrics

import "base:runtime"
import "core:math"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"

Kind :: enum u8 {
	Counter,
	Gauge,
	Histogram,
}

// Series is one labelled time series. Pointers to a Series are stable for the
// lifetime of the Registry and may be cached by hot paths.
Series :: struct {
	family:       ^Family,
	label_values: []string, // owned by the registry allocator, never freed
	dead:         u32, // tombstone flag; 1 = skipped by exposition
	value:        u64, // counter count
	gauge:        i64, // gauge value (integer units, scaled at exposition)
	sum:          u64, // histogram: sum of observations in integer units
	buckets:      []u64, // histogram: per-bucket (non-cumulative) counts; last = +Inf
}

Family :: struct {
	registry:    ^Registry,
	name:        string,
	help:        string,
	kind:        Kind,
	label_names: []string,
	// Exposed value = stored integer / 10^decimals. 0 prints plain integers.
	decimals:    int,
	// Histogram upper bounds in integer units, strictly ascending, without +Inf.
	bounds:      []u64,
	mu:          sync.RW_Mutex,
	index:       map[string]^Series,
	series:      [dynamic]^Series,
}

Collector_Proc :: proc(ctx: rawptr, e: ^Exposition)

Collector :: struct {
	ctx:     rawptr,
	collect: Collector_Proc,
}

Registry :: struct {
	allocator:   mem.Allocator,
	initialised: bool,
	mu:          sync.Mutex, // guards families / by_name / collectors
	families:    [dynamic]^Family,
	by_name:     map[string]^Family,
	collectors:  [dynamic]Collector,
}

// Hub-wide default registry. Instrumented packages reference families created
// against this registry; the app wires the listener to it.
@(private)
global_registry: Registry
@(private)
global_init_mu: sync.Mutex

global :: proc() -> ^Registry {
	return &global_registry
}

// init_global initialises the process-wide registry exactly once. The default
// allocator is the runtime heap, deliberately NOT context.allocator: under
// `odin test` the context allocator is a per-test tracking allocator that does
// not outlive the test, and the global registry must.
init_global :: proc(allocator: mem.Allocator = {}) -> ^Registry {
	a := allocator
	if a.procedure == nil do a = runtime.heap_allocator()
	sync.lock(&global_init_mu)
	defer sync.unlock(&global_init_mu)
	if !global_registry.initialised do registry_init(&global_registry, a)
	return &global_registry
}

registry_init :: proc(reg: ^Registry, allocator: mem.Allocator) {
	reg.allocator = allocator
	reg.families = make([dynamic]^Family, allocator)
	reg.by_name = make(map[string]^Family, allocator)
	reg.collectors = make([dynamic]Collector, allocator)
	reg.initialised = true
}

// registry_destroy frees everything. ONLY for tests, after every thread that
// could touch a series has finished; the production registry lives forever.
registry_destroy :: proc(reg: ^Registry) {
	if reg == nil || !reg.initialised do return
	a := reg.allocator
	for f in reg.families {
		for s in f.series {
			for v in s.label_values do delete(v, a)
			delete(s.label_values, a)
			delete(s.buckets, a)
			free(s, a)
		}
		for key, _ in f.index do delete(key, a)
		delete(f.index)
		delete(f.series)
		for n in f.label_names do delete(n, a)
		delete(f.label_names, a)
		delete(f.bounds, a)
		delete(f.name, a)
		delete(f.help, a)
		free(f, a)
	}
	delete(reg.families)
	delete(reg.by_name)
	delete(reg.collectors)
	reg^ = {}
}

registry_add_collector :: proc(reg: ^Registry, ctx: rawptr, collect: Collector_Proc) {
	if reg == nil || collect == nil do return
	sync.lock(&reg.mu)
	defer sync.unlock(&reg.mu)
	append(&reg.collectors, Collector{ctx = ctx, collect = collect})
}

// ---------------------------------------------------------------------------
// Family creation. Re-registering an existing name returns the existing family
// (so tests and repeated graph builds are idempotent); the kind must match.

new_counter :: proc(reg: ^Registry, name, help: string, label_names: []string = {}, decimals := 0) -> ^Family {
	return new_family(reg, name, help, .Counter, label_names, nil, decimals)
}

new_gauge :: proc(reg: ^Registry, name, help: string, label_names: []string = {}, decimals := 0) -> ^Family {
	return new_family(reg, name, help, .Gauge, label_names, nil, decimals)
}

// new_histogram creates a histogram whose observations are integers scaled by
// 10^decimals. `bounds` are given in exposed units (e.g. seconds) and converted.
new_histogram :: proc(reg: ^Registry, name, help: string, label_names: []string, bounds: []f64, decimals: int) -> ^Family {
	return new_family(reg, name, help, .Histogram, label_names, bounds, decimals)
}

// new_histogram_seconds observes time.Duration (nanoseconds) and exposes seconds.
new_histogram_seconds :: proc(reg: ^Registry, name, help: string, label_names: []string, bounds: []f64) -> ^Family {
	return new_family(reg, name, help, .Histogram, label_names, bounds, 9)
}

@(private)
new_family :: proc(reg: ^Registry, name, help: string, kind: Kind, label_names: []string, bounds: []f64, decimals: int) -> ^Family {
	if reg == nil || !reg.initialised do return nil
	a := reg.allocator
	sync.lock(&reg.mu)
	defer sync.unlock(&reg.mu)
	if existing, ok := reg.by_name[name]; ok {
		assert(existing.kind == kind, "metrics: family re-registered with a different kind")
		return existing
	}
	f := new(Family, a)
	f.registry = reg
	f.name = strings.clone(name, a)
	f.help = strings.clone(help, a)
	f.kind = kind
	f.decimals = decimals
	f.label_names = make([]string, len(label_names), a)
	for n, i in label_names do f.label_names[i] = strings.clone(n, a)
	if kind == .Histogram {
		assert(len(bounds) > 0 && len(bounds) <= 10, "metrics: histograms need 1..10 buckets")
		f.bounds = make([]u64, len(bounds), a)
		scale := math.pow(10.0, f64(decimals))
		for b, i in bounds {
			f.bounds[i] = u64(math.round(b * scale))
			if i > 0 do assert(f.bounds[i] > f.bounds[i-1], "metrics: histogram bounds must ascend")
		}
	}
	f.index = make(map[string]^Series, a)
	f.series = make([dynamic]^Series, a)
	append(&reg.families, f)
	reg.by_name[f.name] = f
	return f
}

// ---------------------------------------------------------------------------
// Series lookup / creation / tombstoning.

// with returns the series for the given label values, creating it on first use
// or reviving a tombstoned one (with zeroed values). Lookups take a shared lock;
// only creation takes the exclusive lock. Label values are cloned with the
// registry allocator, so callers may pass request-arena strings.
with :: proc(f: ^Family, values: ..string) -> ^Series {
	if f == nil do return nil
	assert(len(values) == len(f.label_names), "metrics: label value count mismatch")
	key_buf: [512]byte
	key, key_heap := build_key(key_buf[:], values, f.registry.allocator)
	defer if key_heap do delete(key, f.registry.allocator)

	sync.shared_lock(&f.mu)
	s, found := f.index[key]
	alive := found && sync.atomic_load(&s.dead) == 0
	sync.shared_unlock(&f.mu)
	if alive do return s

	sync.lock(&f.mu)
	defer sync.unlock(&f.mu)
	if s, found = f.index[key]; found {
		if sync.atomic_load(&s.dead) != 0 do revive_locked(s)
		return s
	}
	a := f.registry.allocator
	s = new(Series, a)
	s.family = f
	s.label_values = make([]string, len(values), a)
	for v, i in values do s.label_values[i] = strings.clone(v, a)
	if f.kind == .Histogram do s.buckets = make([]u64, len(f.bounds) + 1, a)
	f.index[strings.clone(key, a)] = s
	append(&f.series, s)
	return s
}

@(private)
revive_locked :: proc(s: ^Series) {
	sync.atomic_store(&s.value, 0)
	sync.atomic_store(&s.gauge, 0)
	sync.atomic_store(&s.sum, 0)
	for &b in s.buckets do sync.atomic_store(&b, 0)
	sync.atomic_store(&s.dead, 0)
}

// remove tombstones one series. The memory stays; cached pointers stay valid.
remove :: proc(f: ^Family, values: ..string) -> bool {
	if f == nil do return false
	key_buf: [512]byte
	key, key_heap := build_key(key_buf[:], values, f.registry.allocator)
	defer if key_heap do delete(key, f.registry.allocator)
	sync.lock(&f.mu)
	defer sync.unlock(&f.mu)
	s, found := f.index[key]
	if !found do return false
	sync.atomic_store(&s.dead, 1)
	return true
}

// remove_where tombstones every series whose label `label_index` equals
// `value` (e.g. everything carrying a given bridge_id). Returns the count.
remove_where :: proc(f: ^Family, label_index: int, value: string) -> int {
	if f == nil || label_index < 0 || label_index >= len(f.label_names) do return 0
	n := 0
	sync.lock(&f.mu)
	defer sync.unlock(&f.mu)
	for s in f.series {
		if s.label_values[label_index] == value && sync.atomic_load(&s.dead) == 0 {
			sync.atomic_store(&s.dead, 1)
			n += 1
		}
	}
	return n
}

series_is_dead :: proc(s: ^Series) -> bool {
	return s == nil || sync.atomic_load(&s.dead) != 0
}

// live_series_count counts non-tombstoned series in the family.
live_series_count :: proc(f: ^Family) -> int {
	if f == nil do return 0
	sync.shared_lock(&f.mu)
	defer sync.shared_unlock(&f.mu)
	n := 0
	for s in f.series do if sync.atomic_load(&s.dead) == 0 do n += 1
	return n
}

// build_key joins label values with NUL. Uses the caller's stack buffer when it
// fits, otherwise the registry allocator (never context.*).
@(private)
build_key :: proc(buf: []byte, values: []string, allocator: mem.Allocator) -> (key: string, heap: bool) {
	total := 0
	for v in values do total += len(v) + 1
	out := buf
	if total > len(buf) {
		out = make([]byte, total, allocator)
		heap = true
	}
	n := 0
	for v in values {
		copy(out[n:], v)
		n += len(v)
		out[n] = 0
		n += 1
	}
	return string(out[:n]), heap
}

// ---------------------------------------------------------------------------
// Hot-path operations. All are nil-safe so instrumentation compiles and runs
// (as a no-op) even when a family was never created.

counter_add :: proc(s: ^Series, n: u64) {
	if s == nil || n == 0 do return
	sync.atomic_add(&s.value, n)
}

counter_inc :: proc(s: ^Series) {
	if s == nil do return
	sync.atomic_add(&s.value, 1)
}

// counter_set overwrites a counter with a cumulative value pushed by a remote
// process (e.g. a bridge's own cpu seconds). The remote restarting makes the
// value drop, which rate()/increase() treat as a counter reset.
counter_set :: proc(s: ^Series, v: u64) {
	if s == nil do return
	sync.atomic_store(&s.value, v)
}

counter_value :: proc(s: ^Series) -> u64 {
	if s == nil do return 0
	return sync.atomic_load(&s.value)
}

gauge_set :: proc(s: ^Series, v: i64) {
	if s == nil do return
	sync.atomic_store(&s.gauge, v)
}

gauge_add :: proc(s: ^Series, n: i64) {
	if s == nil do return
	sync.atomic_add(&s.gauge, n)
}

gauge_sub :: proc(s: ^Series, n: i64) {
	if s == nil do return
	sync.atomic_sub(&s.gauge, n)
}

gauge_inc :: proc(s: ^Series) { gauge_add(s, 1) }
gauge_dec :: proc(s: ^Series) { gauge_sub(s, 1) }

gauge_value :: proc(s: ^Series) -> i64 {
	if s == nil do return 0
	return sync.atomic_load(&s.gauge)
}

// observe records one histogram observation in the family's integer units.
observe :: proc(s: ^Series, v: u64) {
	if s == nil || s.buckets == nil do return
	bounds := s.family.bounds
	i := 0
	for ; i < len(bounds); i += 1 do if v <= bounds[i] do break
	sync.atomic_add(&s.buckets[i], 1)
	sync.atomic_add(&s.sum, v)
}

// observe_duration records a time.Duration on a `new_histogram_seconds` family.
observe_duration :: proc(s: ^Series, d: time.Duration) {
	if s == nil do return
	v := i64(d)
	if v < 0 do v = 0
	if s.family.decimals != 9 do v = rescale(v, 9, s.family.decimals)
	observe(s, u64(v))
}

// histogram_count returns the total observation count (the +Inf cumulative bucket).
histogram_count :: proc(s: ^Series) -> u64 {
	if s == nil do return 0
	n: u64
	for &b in s.buckets do n += sync.atomic_load(&b)
	return n
}

@(private)
rescale :: proc(v: i64, from_decimals, to_decimals: int) -> i64 {
	out := v
	if from_decimals > to_decimals {
		for _ in 0 ..< from_decimals - to_decimals do out /= 10
	} else {
		for _ in 0 ..< to_decimals - from_decimals do out *= 10
	}
	return out
}
