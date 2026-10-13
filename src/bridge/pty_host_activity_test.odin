package main

import "core:testing"

// BR-3 classifier tests: parity with the wrapper's pane_activity detector, ported
// into the bridge. These reuse the SAME recorded real-agent frames so the bridge's
// spinner-masking + burst classification behave identically to the wrapper.

bridge_activity_burst :: proc(a, b, c: string) -> Bridge_Activity_Sample {
	frames := []string{a, b, c}
	return bridge_activity_burst_status(frames)
}

@(test)
bridge_activity_masks_timers_and_spinners :: proc(t: ^testing.T) {
	a, spin_a := bridge_activity_normalize("\u2801 Thinking\u2026 (12s \u00b7 3450 tokens)")
	b, spin_b := bridge_activity_normalize("\u2839 Thinking\u2026 (13s \u00b7 5120 tokens)")
	defer delete(a); defer delete(b)
	testing.expect(t, spin_a && spin_b, "braille spinner detected in both frames")
	testing.expect(t, a == b, "timer/token churn under a spinner must normalize equal")
}

@(test)
bridge_activity_preserves_real_content_change :: proc(t: ^testing.T) {
	a, _ := bridge_activity_normalize("Reading file foo.odin")
	b, _ := bridge_activity_normalize("Writing file bar.odin")
	defer delete(a); defer delete(b)
	testing.expect(t, a != b, "genuine content change must survive normalization")
}

@(test)
bridge_activity_spinner_is_active :: proc(t: ^testing.T) {
	s := bridge_activity_burst("\u2801 Working", "\u2839 Working", "\u2802 Working")
	testing.expect(t, s.spinner_present, "spinner present")
	testing.expect(t, s.status == .Active, "spinner => active")
}

@(test)
bridge_activity_static_goes_idle :: proc(t: ^testing.T) {
	s := bridge_activity_burst("$ ", "$ ", "$ ")
	testing.expect(t, !s.spinner_present, "no spinner")
	testing.expect(t, !s.changed, "static content did not change")
	testing.expect(t, s.status == .Idle, "static => idle")
}

@(test)
bridge_activity_streaming_is_active :: proc(t: ^testing.T) {
	s := bridge_activity_burst(
		"Generating response:\nHello",
		"Generating response:\nHello world",
		"Generating response:\nHello world, this is",
	)
	testing.expect(t, s.changed, "growing stream changed across burst")
	testing.expect(t, s.status == .Active, "growing token stream => active")
}

@(test)
bridge_activity_detects_waiting_user :: proc(t: ^testing.T) {
	frame := "Do you want to proceed? (y/n)"
	s := bridge_activity_burst(frame, frame, frame)
	testing.expect(t, s.waiting_user, "waiting-user prompt detected")
	testing.expect(t, s.status == .Waiting_User, "y/n prompt => waiting_user")
}

@(test)
bridge_activity_classify_precedence :: proc(t: ^testing.T) {
	same := []string{"x", "x", "x"}
	diff := []string{"x", "y", "x"}
	// spinner beats waiting
	st, _ := bridge_activity_classify_burst(same, true, true)
	testing.expect(t, st == .Active, "spinner precedence over waiting")
	// waiting beats idle
	st2, _ := bridge_activity_classify_burst(same, false, true)
	testing.expect(t, st2 == .Waiting_User, "waiting over idle")
	// changed => active
	st3, ch3 := bridge_activity_classify_burst(diff, false, false)
	testing.expect(t, st3 == .Active && ch3, "differing frames => active")
	// all same, nothing => idle
	st4, ch4 := bridge_activity_classify_burst(same, false, false)
	testing.expect(t, st4 == .Idle && !ch4, "quiet => idle")
}

// ---- recorded real-agent parity (same frames as the wrapper test) --------

CLAUDE_FOOTER_A :: "The coordinator asked the user to clarify the request.\n" +
	"\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n" +
	"/private/tmp/heimdall/instances/inst_18d1235fc148693a\n" +
	"\u219156 \u21939.1k R698k W73k $0.973 (sub) 5.9%/1.0M (auto)   (anthropic) claude-opus-4-8 \u2022 high\n" +
	"watchdog: idle 300s (0/\u221e) Heimdall: working \u00b7 settling"
CLAUDE_FOOTER_B :: "The coordinator asked the user to clarify the request.\n" +
	"\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n" +
	"/private/tmp/heimdall/instances/inst_18d1235fc148693a\n" +
	"\u219156 \u219311k R700k W73k $1.004 (sub) 6.0%/1.0M (auto)   (anthropic) claude-opus-4-8 \u2022 high\n" +
	"watchdog: idle 315s (0/\u221e) Heimdall: working \u00b7 settling"
CLAUDE_FOOTER_C :: "The coordinator asked the user to clarify the request.\n" +
	"\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n" +
	"/private/tmp/heimdall/instances/inst_18d1235fc148693a\n" +
	"\u219156 \u219312k R701k W73k $1.021 (sub) 6.1%/1.0M (auto)   (anthropic) claude-opus-4-8 \u2022 high\n" +
	"watchdog: idle 330s (0/\u221e) Heimdall: working \u00b7 settling"

@(test)
bridge_activity_real_claude_idle_footer_goes_idle :: proc(t: ^testing.T) {
	a, _ := bridge_activity_normalize(CLAUDE_FOOTER_A)
	b, _ := bridge_activity_normalize(CLAUDE_FOOTER_B)
	c, _ := bridge_activity_normalize(CLAUDE_FOOTER_C)
	defer delete(a); defer delete(b); defer delete(c)
	testing.expect(t, a == b && b == c, "idle Claude footer differing only by counters must normalize equal")

	s := bridge_activity_burst(CLAUDE_FOOTER_A, CLAUDE_FOOTER_B, CLAUDE_FOOTER_C)
	testing.expect(t, !s.spinner_present, "no spinner in idle Claude footer")
	testing.expect(t, !s.changed, "counter-only churn must not read as content change")
	testing.expect(t, s.status == .Idle, "real idle Claude footer burst must classify idle")
}

@(test)
bridge_activity_collapses_decimal_and_grouped_numbers :: proc(t: ^testing.T) {
	n1, _ := bridge_activity_normalize("tokens 9.1k cost $0.973 ratio 5.9%")
	n2, _ := bridge_activity_normalize("tokens 12k cost $1.02 ratio 6%")
	defer delete(n1); defer delete(n2)
	testing.expect(t, n1 == n2, "decimal/grouped counters must collapse to same masked form")
}

@(test)
bridge_activity_screen_to_text_joins_lines :: proc(t: ^testing.T) {
	txt := bridge_activity_screen_to_text([]string{"line1", "", "line3"})
	defer delete(txt)
	testing.expect_value(t, txt, "line1\n\nline3")
}

// ---- bridge_runtime_normalize_activity_status (REQ-4) ----

@(test)
activity_normalize_waiting_user_is_idle :: proc(t: ^testing.T) {
	testing.expect(t, bridge_runtime_normalize_activity_status("waiting_user") == "idle",
		"waiting_user must project to idle, not active (blocked-on-user agent is not working)")
	testing.expect(t, bridge_runtime_normalize_activity_status("waiting") == "idle",
		"waiting must project to idle")
	testing.expect(t, bridge_runtime_normalize_activity_status("waiting_approval") == "idle",
		"waiting_approval must project to idle")
	testing.expect(t, bridge_runtime_normalize_activity_status("  Waiting_User  ") == "idle",
		"normalization must be case- and whitespace-insensitive")
}

@(test)
activity_normalize_active_signals_unchanged :: proc(t: ^testing.T) {
	testing.expect(t, bridge_runtime_normalize_activity_status("active") == "active", "active stays active")
	testing.expect(t, bridge_runtime_normalize_activity_status("working") == "active", "working maps to active")
	testing.expect(t, bridge_runtime_normalize_activity_status("busy") == "active", "busy maps to active")
}

@(test)
activity_normalize_idle_and_unknown :: proc(t: ^testing.T) {
	testing.expect(t, bridge_runtime_normalize_activity_status("idle") == "idle", "idle stays idle")
	testing.expect(t, bridge_runtime_normalize_activity_status("inactive") == "idle", "inactive maps to idle")
	testing.expect(t, bridge_runtime_normalize_activity_status("unknown") == "unknown", "unknown stays unknown")
	testing.expect(t, bridge_runtime_normalize_activity_status("") == "unknown", "empty maps to unknown")
}
