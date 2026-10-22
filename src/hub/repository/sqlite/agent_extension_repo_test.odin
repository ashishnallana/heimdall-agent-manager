package sqlite

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(private = "file")
ext_setup :: proc(t: ^testing.T, conn: ^Conn, impl: ^Agent_Repo_SQLite) -> (iface.Agent_Repository, bool) {
	opened, ok := tmpl_clone_migrated(t)
	conn^ = opened
	if !ok do return {}, false
	repo := new_agent_repository(impl, conn)
	_, saved, save_err := iface.agent_save_instance(&repo, domain.Agent_Instance{agent_instance_id = "inst_ext", owner_user_id = "owner", agent_id = "agent", bridge_id = "brg", provider = "claude", model = "m", runtime_status = "running", created_at = "2026-10-22T10:00:00Z", updated_at = "2026-10-22T10:00:00Z"})
	testing.expect(t, saved, save_err.message)
	return repo, saved
}

@(private = "file")
ext_ev :: proc(event: string, agent_id := "", agent_type := "", tool := "", file := "", payload := "{}", ts := "") -> domain.Agent_Extension_Event {
	return domain.Agent_Extension_Event{event = event, agent_id = agent_id, agent_type = agent_type, tool_name = tool, file_path = file, payload = payload, ts = ts, created_at = "2026-10-22T10:00:01Z"}
}

@(test)
test_agent_extension_repo_seq_filter_and_retention :: proc(t: ^testing.T) {
	conn: Conn
	impl: Agent_Repo_SQLite
	repo, ok := ext_setup(t, &conn, &impl)
	defer close(&conn)
	if !ok do return
	testing.expect(t, table_column_exists(&conn, "agent_instances", "provider_session_id"), "104 applied")

	// Incoming seq values are ignored: the repo assigns 1..n per instance.
	first := []domain.Agent_Extension_Event{ext_ev("hello"), ext_ev("tool.start", tool = "Bash"), ext_ev("subagent.start", agent_id = "sub_1", agent_type = "Explore")}
	first[0].seq = 99
	stored, err := iface.agent_ext_insert_events(&repo, "inst_ext", first, 0)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, len(stored), 3)
	if len(stored) == 3 {
		testing.expect_value(t, stored[0].seq, 1)
		testing.expect_value(t, stored[2].seq, 3)
		testing.expect_value(t, stored[2].instance_id, "inst_ext")
	}
	// A second batch continues the sequence.
	second := []domain.Agent_Extension_Event{ext_ev("tool.end", agent_id = "sub_1", tool = "Read")}
	stored2, _ := iface.agent_ext_insert_events(&repo, "inst_ext", second, 0)
	if len(stored2) == 1 do testing.expect_value(t, stored2[0].seq, 4)

	all, _ := iface.agent_ext_list_events(&repo, "inst_ext", "", 0, 100)
	testing.expect_value(t, len(all), 4)
	sub, _ := iface.agent_ext_list_events(&repo, "inst_ext", "sub_1", 0, 100)
	testing.expect_value(t, len(sub), 2)
	main_only, _ := iface.agent_ext_list_events(&repo, "inst_ext", "main", 0, 100)
	testing.expect_value(t, len(main_only), 2)
	paged, _ := iface.agent_ext_list_events(&repo, "inst_ext", "", 2, 1)
	testing.expect_value(t, len(paged), 1)
	if len(paged) == 1 do testing.expect_value(t, paged[0].seq, 3)

	// Retention keeps the newest `keep` rows and seq keeps climbing.
	many := make([dynamic]domain.Agent_Extension_Event)
	defer delete(many)
	for _ in 0 ..< 100 do append(&many, ext_ev("activity"))
	stored3, _ := iface.agent_ext_insert_events(&repo, "inst_ext", many[:], 10)
	if len(stored3) == 100 do testing.expect_value(t, stored3[99].seq, 104)
	kept, _ := iface.agent_ext_list_events(&repo, "inst_ext", "", 0, 500)
	testing.expect_value(t, len(kept), 10)
	if len(kept) == 10 do testing.expect_value(t, kept[0].seq, 95)
}

@(test)
test_agent_extension_repo_subagent_and_file_summaries :: proc(t: ^testing.T) {
	conn: Conn
	impl: Agent_Repo_SQLite
	repo, ok := ext_setup(t, &conn, &impl)
	defer close(&conn)
	if !ok do return
	evs := []domain.Agent_Extension_Event{
		ext_ev("subagent.start", agent_id = "sub_a", agent_type = "Explore", payload = `{"description":"find callers"}`, ts = "2026-10-22T10:00:02Z"),
		ext_ev("subagent.start", agent_id = "sub_b", agent_type = "Plan", ts = "2026-10-22T10:00:03Z"),
		ext_ev("file.edit", file = "/w/a.odin", tool = "Edit"),
		ext_ev("file.edit", agent_id = "sub_a", file = "/w/a.odin", tool = "Edit"),
		ext_ev("file.edit", agent_id = "sub_b", file = "/w/b.odin", tool = "Write"),
		ext_ev("subagent.stop", agent_id = "sub_a", ts = "2026-10-22T10:00:09Z"),
	}
	_, err := iface.agent_ext_insert_events(&repo, "inst_ext", evs, 0)
	testing.expect_value(t, err.code, domain.Error_Code.None)

	subs, serr := iface.agent_ext_list_subagents(&repo, "inst_ext")
	testing.expect_value(t, serr.code, domain.Error_Code.None)
	testing.expect_value(t, len(subs), 2)
	if len(subs) == 2 {
		testing.expect_value(t, subs[0].agent_id, "sub_a")
		testing.expect_value(t, subs[0].agent_type, "Explore")
		testing.expect_value(t, subs[0].description, "find callers")
		testing.expect_value(t, subs[0].status, "stopped")
		testing.expect_value(t, subs[0].started_at, "2026-10-22T10:00:02Z")
		testing.expect_value(t, subs[0].stopped_at, "2026-10-22T10:00:09Z")
		testing.expect_value(t, subs[0].event_count, 3)
		testing.expect_value(t, subs[1].agent_id, "sub_b")
		testing.expect_value(t, subs[1].status, "running")
		testing.expect_value(t, subs[1].stopped_at, "")
	}

	files, ferr := iface.agent_ext_list_files(&repo, "inst_ext")
	testing.expect_value(t, ferr.code, domain.Error_Code.None)
	testing.expect_value(t, len(files), 2)
	if len(files) == 2 {
		// Most recently edited first.
		testing.expect_value(t, files[0].file_path, "/w/b.odin")
		testing.expect_value(t, files[0].edit_count, 1)
		testing.expect_value(t, files[1].file_path, "/w/a.odin")
		testing.expect_value(t, files[1].edit_count, 2)
	}
}

@(test)
test_agent_extension_instance_fields_survive_upsert :: proc(t: ^testing.T) {
	conn: Conn
	impl: Agent_Repo_SQLite
	repo, ok := ext_setup(t, &conn, &impl)
	defer close(&conn)
	if !ok do return
	_, uerr := iface.agent_ext_update_instance(&repo, "inst_ext", domain.Agent_Extension_Instance_Update{provider_session_id = "sess_1", provider_transcript_path = "/t/1.jsonl", extension_provider = "claude", extension_version = "0.1.0", extension_capabilities = `["activity","subagents"]`, extension_last_seen_at = "2026-10-22T10:00:05Z"})
	testing.expect_value(t, uerr.code, domain.Error_Code.None)
	inst, got, _ := iface.agent_get_instance(&repo, "inst_ext")
	testing.expect(t, got, "instance readable")
	testing.expect_value(t, inst.provider_session_id, "sess_1")
	testing.expect_value(t, inst.extension_capabilities, `["activity","subagents"]`)

	// A partial update (session change only) overwrites the session and keeps the rest.
	_, _ = iface.agent_ext_update_instance(&repo, "inst_ext", domain.Agent_Extension_Instance_Update{provider_session_id = "sess_2"})
	// The general status upsert never touches extension columns.
	inst.activity_status = "active"
	_, _, _ = iface.agent_save_instance(&repo, inst)
	after, _, _ := iface.agent_get_instance(&repo, "inst_ext")
	testing.expect_value(t, after.provider_session_id, "sess_2")
	testing.expect_value(t, after.provider_transcript_path, "/t/1.jsonl")
	testing.expect_value(t, after.extension_provider, "claude")
	testing.expect_value(t, after.extension_version, "0.1.0")
	testing.expect_value(t, after.activity_status, "active")
}
