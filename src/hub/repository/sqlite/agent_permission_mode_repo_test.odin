package sqlite

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// REQ-EXT-PERM-2: migration 106 adds agents.permission_mode (default 'yolo',
// CHECK yolo|ask) and the agent repo round-trips it.

@(test)
test_agent_permission_mode_round_trips_and_defaults :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	conn, ok := tmpl_clone_migrated(t)
	if !testing.expect(t, ok, "migrated template db") do return
	defer close(&conn)
	impl: Agent_Repo_SQLite
	repo := new_agent_repository(&impl, &conn)

	// A row written without the column (pre-106 writers, seed migrations) reads as yolo.
	testing.expect(t, exec(&conn, "INSERT INTO agents (agent_id, owner_user_id, name, slug, template_id, instructions, state, created_at, updated_at) VALUES ('agt_legacy','owner','legacy','legacy','empty','','active','2026-10-22T00:00:00Z','2026-10-22T00:00:00Z');"))
	legacy, lok, _ := iface.agent_get(&repo, "agt_legacy")
	testing.expect(t, lok)
	testing.expect_value(t, legacy.permission_mode, domain.AGENT_PERMISSION_MODE_YOLO)

	// An unset domain value is stored as yolo; ask round-trips.
	agent := domain.Agent{agent_id = "agt_ask", owner_user_id = "owner", name = "asker", slug = "asker", template_id = "empty", state = .Active, created_at = "2026-10-22T00:00:00Z", updated_at = "2026-10-22T00:00:00Z"}
	_, saved, save_err := iface.agent_save(&repo, agent)
	testing.expect(t, saved, save_err.message)
	got, _, _ := iface.agent_get(&repo, "agt_ask")
	testing.expect_value(t, got.permission_mode, domain.AGENT_PERMISSION_MODE_YOLO)

	agent.permission_mode = domain.AGENT_PERMISSION_MODE_ASK
	_, saved, save_err = iface.agent_save(&repo, agent)
	testing.expect(t, saved, save_err.message)
	got, _, _ = iface.agent_get(&repo, "agt_ask")
	testing.expect_value(t, got.permission_mode, domain.AGENT_PERMISSION_MODE_ASK)

	// The CHECK constraint rejects anything else written directly.
	testing.expect(t, !exec(&conn, "UPDATE agents SET permission_mode = 'never' WHERE agent_id = 'agt_ask';"), "CHECK must reject unknown modes")
}
