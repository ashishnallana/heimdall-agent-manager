package main

import "core:strings"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"

// REQ-EXT-CORE-1/2, REQ-EXT-ACT-1: ham.ext.v1 parse/validate, activity mapping,
// identity stamping and transient local reduction on the bridge.

@(private = "file")
ext_test_event :: proc(event, extra: string) -> string {
	return strings.concatenate({`{"schema":"ham.ext.v1","provider":"claude","ext_version":"0.1.0","event":"`, event, `","ts":"2026-10-22T06:00:00Z","session_id":"sess-1"`, extra, `}`}, context.temp_allocator)
}

@(private = "file")
ext_test_rec :: proc(id: string) -> Bridge_Local_Agent_Token_Record {
	return Bridge_Local_Agent_Token_Record{agent_instance_id = id, instance_token = "tok_test", role = .Agent}
}

@(test)
test_ext_parse_valid_event_extracts_fields :: proc(t: ^testing.T) {
	raw := ext_test_event("file.edit", `,"agent":{"id":"sub-1","type":"Explore"},"tool":{"name":"Edit","use_id":"tu_1","input":{"file_path":"/x/y.odin"}},"payload":{}`)
	ev, err := contracts.ext_parse_event(raw)
	defer contracts.ext_event_destroy(&ev)
	testing.expect_value(t, err, contracts.Ext_Error.None)
	testing.expect_value(t, ev.kind, contracts.Ext_Event_Kind.File_Edit)
	testing.expect_value(t, ev.provider, "claude")
	testing.expect_value(t, ev.session_id, "sess-1")
	testing.expect_value(t, ev.agent_id, "sub-1")
	testing.expect_value(t, ev.agent_type, "Explore")
	testing.expect_value(t, ev.tool_name, "Edit")
	testing.expect_value(t, ev.tool_use_id, "tu_1")
	testing.expect_value(t, ev.file_path, "/x/y.odin")
}

@(test)
test_ext_parse_rejects_invalid_events :: proc(t: ^testing.T) {
	_, e1 := contracts.ext_parse_event(`{"schema":"ham.ext.v0","provider":"claude","event":"hello"}`)
	testing.expect_value(t, e1, contracts.Ext_Error.Bad_Schema)
	_, e2 := contracts.ext_parse_event(`{"schema":"ham.ext.v1","provider":"claude","event":"tool.explode"}`)
	testing.expect_value(t, e2, contracts.Ext_Error.Unknown_Event)
	_, e3 := contracts.ext_parse_event(`{"schema":"ham.ext.v1","event":"hello"}`)
	testing.expect_value(t, e3, contracts.Ext_Error.Missing_Provider)
	_, e4 := contracts.ext_parse_event(`[1,2]`)
	testing.expect_value(t, e4, contracts.Ext_Error.Malformed_Json)
	big := strings.repeat("a", contracts.EXT_EVENT_MAX_BYTES, context.temp_allocator)
	_, e5 := contracts.ext_parse_event(ext_test_event("activity", strings.concatenate({`,"payload":{"note":"`, big, `"}`}, context.temp_allocator)))
	testing.expect_value(t, e5, contracts.Ext_Error.Too_Large)
}

@(test)
test_ext_parse_hello_capabilities :: proc(t: ^testing.T) {
	ev, err := contracts.ext_parse_event(ext_test_event("hello", `,"payload":{"capabilities":["activity","subagents"]}`))
	defer contracts.ext_event_destroy(&ev)
	testing.expect_value(t, err, contracts.Ext_Error.None)
	testing.expect_value(t, len(ev.capabilities), 2)
	if len(ev.capabilities) == 2 do testing.expect_value(t, ev.capabilities[1], "subagents")
}

@(test)
test_ext_split_single_and_batch :: proc(t: ^testing.T) {
	one, e1 := contracts.ext_split_events(ext_test_event("session", ""))
	defer contracts.ext_split_events_destroy(one)
	testing.expect_value(t, e1, contracts.Ext_Error.None)
	testing.expect_value(t, len(one), 1)

	batch := strings.concatenate({`{"events":[`, ext_test_event("tool.start", ""), `,`, ext_test_event("tool.end", ""), `,7]}`}, context.temp_allocator)
	many, e2 := contracts.ext_split_events(batch)
	defer contracts.ext_split_events_destroy(many)
	testing.expect_value(t, e2, contracts.Ext_Error.None)
	testing.expect_value(t, len(many), 3)

	_, e3 := contracts.ext_split_events(`not json`)
	testing.expect_value(t, e3, contracts.Ext_Error.Malformed_Json)
}

@(test)
test_ext_split_truncates_large_diff :: proc(t: ^testing.T) {
	diff := strings.repeat("d", contracts.EXT_DIFF_MAX_BYTES + 100, context.temp_allocator)
	raw := ext_test_event("file.edit", strings.concatenate({`,"payload":{"file_path":"/a","diff":"`, diff, `"}`}, context.temp_allocator))
	out, err := contracts.ext_split_events(raw)
	defer contracts.ext_split_events_destroy(out)
	testing.expect_value(t, err, contracts.Ext_Error.None)
	testing.expect_value(t, len(out), 1)
	if len(out) == 1 {
		testing.expect(t, strings.contains(out[0], "truncated by heimdall"), "diff must carry the truncation marker")
		testing.expect(t, strings.contains(out[0], `"diff_truncated":true`), "diff_truncated flag must be set")
		testing.expect(t, len(out[0]) < contracts.EXT_DIFF_MAX_BYTES + 1024, "normalised event must be bounded")
		ev, perr := contracts.ext_parse_event(out[0])
		defer contracts.ext_event_destroy(&ev)
		testing.expect_value(t, perr, contracts.Ext_Error.None)
		testing.expect_value(t, ev.file_path, "/a")
	}
}

@(test)
test_ext_activity_mapping :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, raw: string, want: string, want_ok: bool) {
		ev, err := contracts.ext_parse_event(raw)
		defer contracts.ext_event_destroy(&ev)
		testing.expect_value(t, err, contracts.Ext_Error.None)
		got, ok := contracts.ext_activity_for_event(ev)
		testing.expect_value(t, ok, want_ok)
		testing.expect_value(t, got, want)
	}
	check(t, ext_test_event("tool.start", ""), "active", true)
	check(t, ext_test_event("subagent.start", ""), "active", true)
	check(t, ext_test_event("activity", `,"payload":{"state":"active"}`), "active", true)
	check(t, ext_test_event("activity", `,"payload":{"state":"idle"}`), "idle", true)
	check(t, ext_test_event("notification", `,"payload":{"type":"permission_prompt"}`), "waiting_user", true)
	check(t, ext_test_event("notification", `,"payload":{"notification_type":"permission_prompt"}`), "waiting_user", true)
	check(t, ext_test_event("notification", `,"payload":{"type":"idle_prompt"}`), "", false)
	check(t, ext_test_event("tool.end", ""), "", false)
	check(t, ext_test_event("hello", ""), "", false)
	testing.expect_value(t, bridge_runtime_activity_source_rank(bridge_ext_activity_source("Claude")), 80)
}

@(test)
test_ext_ingest_stamps_token_instance_and_overrides_pane_diff :: proc(t: ^testing.T) {
	id := "inst_test_ext_identity"
	other := "inst_test_ext_spoofed"
	bridge_runtime_mark_start_success(id)
	bridge_runtime_mark_start_success(other)
	bridge_runtime_note_agent_activity(id, "idle", "pane_diff")
	bridge_runtime_note_agent_activity(other, "idle", "pane_diff")

	params := ext_test_event("tool.start", strings.concatenate({`,"agent_instance_id":"`, other, `","instance_id":"`, other, `"`}, context.temp_allocator))
	res := bridge_ext_ingest(ext_test_rec(id), params, bridge_runtime_now_ms())
	defer bridge_ext_ingest_result_destroy(&res)
	testing.expect_value(t, res.accepted, 1)
	testing.expect_value(t, res.fatal, contracts.Ext_Error.None)

	mine, ok1 := bridge_runtime_instance_snapshot(id)
	testing.expect(t, ok1, "token instance must exist")
	testing.expect_value(t, mine.activity_status, "active")
	testing.expect_value(t, mine.activity_source, "claude_extension")
	spoof, ok2 := bridge_runtime_instance_snapshot(other)
	testing.expect(t, ok2, "other instance must exist")
	testing.expect_value(t, spoof.activity_status, "idle")

	// A lower-ranked pane_diff idle within the TTL must not override the extension.
	bridge_runtime_note_agent_activity(id, "idle", "pane_diff")
	again, _ := bridge_runtime_instance_snapshot(id)
	testing.expect_value(t, again.activity_status, "active")
}

@(test)
test_ext_ingest_partial_batch_and_status :: proc(t: ^testing.T) {
	id := "inst_test_ext_batch"
	bridge_runtime_mark_start_success(id)
	params := strings.concatenate({`{"events":[`, ext_test_event("hello", `,"payload":{"capabilities":["activity","session_id"]}`), `,{"schema":"bogus"},`, ext_test_event("activity", `,"payload":{"state":"idle"}`), `]}`}, context.temp_allocator)
	res := bridge_ext_ingest(ext_test_rec(id), params, bridge_runtime_now_ms())
	defer bridge_ext_ingest_result_destroy(&res)
	testing.expect_value(t, res.accepted, 2)
	testing.expect_value(t, res.rejected, 1)
	testing.expect_value(t, res.fatal, contracts.Ext_Error.None)
	body := bridge_ext_ingest_result_json(res)
	defer delete(body)
	testing.expect(t, strings.contains(body, `"index":1`), "rejected event must be reported by index")

	status := bridge_ext_status_json(id)
	defer delete(status)
	testing.expect(t, strings.contains(status, `"provider":"claude"`), status)
	testing.expect(t, strings.contains(status, `"capabilities":["activity","session_id"]`), status)
	testing.expect(t, strings.contains(status, `"queued":0`), status)

	single := bridge_ext_ingest(ext_test_rec(id), `{"schema":"ham.ext.v1","event":"hello"}`, bridge_runtime_now_ms())
	defer bridge_ext_ingest_result_destroy(&single)
	testing.expect_value(t, single.fatal, contracts.Ext_Error.Missing_Provider)
}

@(test)
test_ext_ingest_volume_keeps_only_current_local_metadata :: proc(t: ^testing.T) {
    id := "inst_ext_no_outbox"
    bridge_runtime_mark_start_success(id)
    for _ in 0..<10_000 {
        result := bridge_ext_ingest(ext_test_rec(id), ext_test_event("tool.end", ""), bridge_runtime_now_ms())
        testing.expect_value(t, result.accepted, 1)
        bridge_ext_ingest_result_destroy(&result)
    }
    status := bridge_ext_status_json(id)
    defer delete(status)
    testing.expect(t, strings.contains(status, `"queued":0`), status)
    testing.expect(t, strings.contains(status, `"events_accepted":10000`), status)
}

@(test)
test_ext_methods_allowlisted :: proc(t: ^testing.T) {
	testing.expect(t, bridge_agent_method_allowed("agent.extension.event"), "agent.extension.event must be allowlisted")
	testing.expect(t, bridge_agent_method_allowed("agent.extension.status"), "agent.extension.status must be allowlisted")
}
