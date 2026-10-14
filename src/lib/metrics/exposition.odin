package metrics

import "core:strings"
import "core:sync"
import "core:time"

// Prometheus text exposition format 0.0.4.
CONTENT_TYPE :: "text/plain; version=0.0.4; charset=utf-8"

// Exposition is handed to collectors so they can emit samples straight into
// the scrape output without owning any series.
Exposition :: struct {
	b:       ^strings.Builder,
	samples: int, // live series/samples written so far (feeds metrics_series)
}

// gather writes the full exposition into `b`. The builder belongs to the caller
// (the metrics listener uses a heap builder). Family locks are held in shared
// mode only while that family is formatted; collectors run with no lock held.
gather :: proc(reg: ^Registry, b: ^strings.Builder) {
	if reg == nil || !reg.initialised do return
	start := time.tick_now()
	e := Exposition{b = b}

	// Snapshot the family/collector lists under the registry lock, then drop
	// it so collectors and other threads can register concurrently.
	sync.lock(&reg.mu)
	nfam := len(reg.families)
	ncol := len(reg.collectors)
	sync.unlock(&reg.mu)

	for i in 0 ..< ncol {
		sync.lock(&reg.mu)
		c := reg.collectors[i]
		sync.unlock(&reg.mu)
		c.collect(c.ctx, &e)
	}
	for i in 0 ..< nfam {
		sync.lock(&reg.mu)
		f := reg.families[i]
		sync.unlock(&reg.mu)
		write_family(&e, f)
	}

	elapsed := time.tick_since(start)
	// Self-metrics last: +2 for the two lines below.
	expo_header(&e, "heimdall_metrics_series", "Number of live series in the last scrape.", .Gauge)
	expo_sample_i64(&e, "heimdall_metrics_series", nil, nil, i64(e.samples + 2))
	expo_header(&e, "heimdall_metrics_scrape_duration_seconds", "Wall time spent producing the last scrape.", .Gauge)
	expo_sample_i64(&e, "heimdall_metrics_scrape_duration_seconds", nil, nil, i64(elapsed), 9)
}

@(private)
write_family :: proc(e: ^Exposition, f: ^Family) {
	sync.shared_lock(&f.mu)
	defer sync.shared_unlock(&f.mu)
	wrote_header := false
	for s in f.series {
		if sync.atomic_load(&s.dead) != 0 do continue
		if !wrote_header {
			expo_header(e, f.name, f.help, f.kind)
			wrote_header = true
		}
		switch f.kind {
		case .Counter:
			expo_sample_u64(e, f.name, f.label_names, s.label_values, sync.atomic_load(&s.value), f.decimals)
		case .Gauge:
			expo_sample_i64(e, f.name, f.label_names, s.label_values, sync.atomic_load(&s.gauge), f.decimals)
		case .Histogram:
			write_histogram(e, f, s)
		}
	}
}

@(private)
write_histogram :: proc(e: ^Exposition, f: ^Family, s: ^Series) {
	b := e.b
	cumulative: u64
	for i in 0 ..< len(s.buckets) {
		cumulative += sync.atomic_load(&s.buckets[i])
		strings.write_string(b, f.name)
		strings.write_string(b, "_bucket{")
		write_label_pairs(b, f.label_names, s.label_values)
		if len(f.label_names) > 0 do strings.write_byte(b, ',')
		strings.write_string(b, "le=\"")
		if i < len(f.bounds) {
			write_scaled_u64(b, f.bounds[i], f.decimals)
		} else {
			strings.write_string(b, "+Inf")
		}
		strings.write_string(b, "\"} ")
		strings.write_u64(b, cumulative)
		strings.write_byte(b, '\n')
	}
	strings.write_string(b, f.name)
	strings.write_string(b, "_sum")
	write_label_block(b, f.label_names, s.label_values)
	strings.write_byte(b, ' ')
	write_scaled_u64(b, sync.atomic_load(&s.sum), f.decimals)
	strings.write_byte(b, '\n')
	strings.write_string(b, f.name)
	strings.write_string(b, "_count")
	write_label_block(b, f.label_names, s.label_values)
	strings.write_byte(b, ' ')
	strings.write_u64(b, cumulative)
	strings.write_byte(b, '\n')
	e.samples += 1
}

// ---------------------------------------------------------------------------
// Collector-facing helpers.

expo_header :: proc(e: ^Exposition, name, help: string, kind: Kind) {
	b := e.b
	strings.write_string(b, "# HELP ")
	strings.write_string(b, name)
	strings.write_byte(b, ' ')
	write_escaped(b, help, false)
	strings.write_string(b, "\n# TYPE ")
	strings.write_string(b, name)
	strings.write_byte(b, ' ')
	switch kind {
	case .Counter:   strings.write_string(b, "counter")
	case .Gauge:     strings.write_string(b, "gauge")
	case .Histogram: strings.write_string(b, "histogram")
	}
	strings.write_byte(b, '\n')
}

expo_sample_u64 :: proc(e: ^Exposition, name: string, label_names, label_values: []string, v: u64, decimals := 0) {
	b := e.b
	strings.write_string(b, name)
	write_label_block(b, label_names, label_values)
	strings.write_byte(b, ' ')
	write_scaled_u64(b, v, decimals)
	strings.write_byte(b, '\n')
	e.samples += 1
}

expo_sample_i64 :: proc(e: ^Exposition, name: string, label_names, label_values: []string, v: i64, decimals := 0) {
	b := e.b
	strings.write_string(b, name)
	write_label_block(b, label_names, label_values)
	strings.write_byte(b, ' ')
	if v < 0 {
		strings.write_byte(b, '-')
		write_scaled_u64(b, u64(-v), decimals)
	} else {
		write_scaled_u64(b, u64(v), decimals)
	}
	strings.write_byte(b, '\n')
	e.samples += 1
}

// ---------------------------------------------------------------------------
// Formatting primitives.

@(private)
write_label_block :: proc(b: ^strings.Builder, names, values: []string) {
	if len(names) == 0 do return
	strings.write_byte(b, '{')
	write_label_pairs(b, names, values)
	strings.write_byte(b, '}')
}

@(private)
write_label_pairs :: proc(b: ^strings.Builder, names, values: []string) {
	for n, i in names {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_string(b, n)
		strings.write_string(b, "=\"")
		if i < len(values) do write_escaped(b, values[i], true)
		strings.write_byte(b, '"')
	}
}

// write_escaped escapes `\` and newline; label values additionally escape `"`.
@(private)
write_escaped :: proc(b: ^strings.Builder, s: string, label: bool) {
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '\\': strings.write_string(b, "\\\\")
		case '\n': strings.write_string(b, "\\n")
		case '"':
			if label { strings.write_string(b, "\\\"") } else { strings.write_byte(b, c) }
		case: strings.write_byte(b, c)
		}
	}
}

// write_scaled_u64 prints v / 10^decimals as an exact decimal ("0.01", "12",
// "1.5"), trimming trailing zeros. Exact integer arithmetic keeps golden tests
// deterministic and avoids float formatting entirely.
@(private)
write_scaled_u64 :: proc(b: ^strings.Builder, v: u64, decimals: int) {
	if decimals <= 0 {
		strings.write_u64(b, v)
		return
	}
	div: u64 = 1
	for _ in 0 ..< decimals do div *= 10
	strings.write_u64(b, v / div)
	frac := v % div
	if frac == 0 do return
	digits: [20]byte
	n := decimals
	for i := decimals - 1; i >= 0; i -= 1 {
		digits[i] = byte('0' + frac % 10)
		frac /= 10
	}
	for n > 0 && digits[n-1] == '0' do n -= 1
	strings.write_byte(b, '.')
	strings.write_string(b, string(digits[:n]))
}
