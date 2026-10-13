package http

// Unit tests for the ephemeral "agent_action" activity-bubble frame.
// agent_action_event_json is the pure builder behind publish_agent_action, so
// these lock the wire payload shape (type/instance_id/action/summary/ts) and the
// id-free + rune-safe-clip contract WITHOUT a live event bus. The owner-scoped
// fanout in publish_agent_action reuses events.publish_raw_to_user (covered by the
// event-bus + existing publish helpers).

import "core:strings"
import "core:testing"

@(test)
test_agent_action_event_json_shape :: proc(t: ^testing.T) {
	out := agent_action_event_json("inst_abc", "task_comment", "commented: looks good")
	defer delete(out)
	testing.expect(t, strings.contains(out, "\"type\":\"agent_action\""), "type present")
	testing.expect(t, strings.contains(out, "\"instance_id\":\"inst_abc\""), "instance_id present")
	testing.expect(t, strings.contains(out, "\"action\":\"task_comment\""), "action present")
	testing.expect(t, strings.contains(out, "\"summary\":\"commented: looks good\""), "summary present")
	// ts is a numeric unix-ms field (not quoted) — the client uses it for the replay window.
	testing.expect(t, strings.contains(out, "\"ts\":"), "ts key present")
	testing.expect(t, !strings.contains(out, "\"ts\":\""), "ts is numeric, not a quoted string")
}

@(test)
test_agent_action_event_json_clips_long_summary :: proc(t: ^testing.T) {
	// A summary longer than AGENT_ACTION_SUMMARY_MAX runes must be truncated with an
	// ellipsis so a long comment preview can't bloat the frame.
	long := strings.repeat("x", 200)
	defer delete(long)
	out := agent_action_event_json("inst_1", "task_comment", long)
	defer delete(out)
	testing.expect(t, strings.contains(out, "\u2026"), "long summary is clipped with an ellipsis")
	// The clipped summary keeps at most AGENT_ACTION_SUMMARY_MAX 'x' runes.
	over_cap := strings.repeat("x", AGENT_ACTION_SUMMARY_MAX + 1)
	defer delete(over_cap)
	testing.expect(t, !strings.contains(out, over_cap), "no run longer than the cap")
}

@(test)
test_agent_action_event_json_escapes_and_is_id_free :: proc(t: ^testing.T) {
	// Quotes/backslashes in a composed summary must be JSON-escaped so the frame
	// stays well-formed. (Callers are responsible for passing id-free text; this
	// asserts the framing does not re-introduce structural breakage.)
	out := agent_action_event_json("inst_2", "task_create", "created task \"Fix \\ bug\"")
	defer delete(out)
	testing.expect(t, strings.contains(out, "\\\"Fix"), "double-quote escaped in summary")
	testing.expect(t, strings.contains(out, "\\\\"), "backslash escaped in summary")
	// The frame opens and closes as a single JSON object.
	testing.expect(t, strings.has_prefix(out, "{\"type\":\"agent_action\""), "opens as agent_action object")
	testing.expect(t, strings.has_suffix(out, "}"), "closes the object")
}
