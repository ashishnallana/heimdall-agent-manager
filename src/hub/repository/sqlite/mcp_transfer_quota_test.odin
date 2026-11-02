package sqlite

import "core:fmt"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Quotas are enforced inside the INSERT/UPDATE statements, not by a prior read:
// calling the repository directly (no service pre-check) still cannot exceed them.

@(private = "file")
quota_row :: proc(id, owner: string) -> domain.Mcp_Transfer {
	return {transfer_id = id, owner_user_id = owner, client_id = "c", grant_id = "g", family_id = "f",
		direction = domain.MCP_TRANSFER_UPLOAD, state = domain.MCP_TRANSFER_RECEIVING, token_sha256 = fmt.tprintf("tok_%s", id),
		artifact_id = fmt.tprintf("art_%s", id), request_id = fmt.tprintf("req_%s", id), request_digest = "d", kind = "file",
		content_type = "application/octet-stream", associations = "{}", vault_id = "v", epoch = 1,
		created_at = "2026-01-01T00:00:00Z", touched_at = "2026-01-01T00:00:00Z", expires_at = "2026-01-01T01:00:00Z"}
}

@(test)
test_transfer_quota_enforced_inside_statements :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	ok, err := run_migrations(&conn)
	if !testing.expect(t, ok && err.code == .None) do return
	impl: Transfer_Repo_SQLite
	repo := new_transfer_repository(&impl, &conn)

	q := iface.Transfer_Quota{max_active = 2, max_owner_staged = 100, max_global_staged = 150}
	in1, e1 := repo.insert(repo.ctx, quota_row("x1", "user_a"), q)
	in2, _ := repo.insert(repo.ctx, quota_row("x2", "user_a"), q)
	in3, e3 := repo.insert(repo.ctx, quota_row("x3", "user_a"), q)
	testing.expect(t, e1.code == .None && e3.code == .None)
	testing.expect(t, in1 && in2 && !in3, "third active upload for the owner is refused by the INSERT")
	inb, _ := repo.insert(repo.ctx, quota_row("y1", "user_b"), q)
	testing.expect(t, inb, "another owner is unaffected")

	buf: [80]byte
	a1, _ := repo.append_chunk(repo.ctx, "x1", 0, buf[:], "2026-01-01T00:00:01Z", "2026-01-01T01:00:00Z", q)
	testing.expect(t, a1)
	a2, ae := repo.append_chunk(repo.ctx, "x2", 0, buf[:30], "2026-01-01T00:00:01Z", "2026-01-01T01:00:00Z", q)
	testing.expect(t, !a2 && ae.code == .None, "owner staged 80+30 > 100 is refused by the UPDATE")
	x2, _, _ := repo.get(repo.ctx, "x2")
	testing.expect_value(t, x2.received_bytes, i64(0))
	testing.expect_value(t, debug_query_text(&conn, "SELECT COUNT(*) FROM mcp_transfer_chunks WHERE transfer_id='x2';"), "0")
	a3, _ := repo.append_chunk(repo.ctx, "x2", 0, buf[:20], "2026-01-01T00:00:01Z", "2026-01-01T01:00:00Z", q)
	testing.expect(t, a3, "exactly at the owner cap is allowed")
	// Global: 100 staged; user_b may add 50 but not 51.
	b1, _ := repo.append_chunk(repo.ctx, "y1", 0, buf[:51], "2026-01-01T00:00:01Z", "2026-01-01T01:00:00Z", q)
	testing.expect(t, !b1, "global staged cap is refused by the UPDATE")
	b2, _ := repo.append_chunk(repo.ctx, "y1", 0, buf[:50], "2026-01-01T00:00:01Z", "2026-01-01T01:00:00Z", q)
	testing.expect(t, b2)
	// Staged bytes also gate new begins.
	full := iface.Transfer_Quota{max_active = 10, max_owner_staged = 100}
	in4, _ := repo.insert(repo.ctx, quota_row("x4", "user_a"), full)
	testing.expect(t, !in4, "an owner at the staged cap cannot begin another upload")
}
