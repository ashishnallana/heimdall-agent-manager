package main

import "core:strings"
import "core:sync"
import "core:testing"
import vault "odin_test:lib/vault"

// The bridge search index is process-global, and the test runner is
// multi-threaded. Tests that rebuild or lock the global index hold this mutex so
// they don't swap or wipe one another's index mid-assertion (package-visible: the
// connect-heartbeat test rebuilds it too).
task_chain_search_global_test_mutex: sync.Mutex

@(test)
task_chain_search_index_upsert_query_filter_and_delete :: proc(t: ^testing.T) {
	index, ok := task_chain_search_index_open()
	testing.expect(t, ok, "in-memory FTS index should open")
	defer task_chain_search_index_close(&index)

	testing.expect(t, task_chain_search_index_upsert(&index, Task_Chain_Search_Document{
		chain_id = "chain_alpha", project_id = "proj_one", status = "active",
		source_revision = 1, updated_at = "2026-10-14T00:00:00Z",
		title = "Reliable encrypted search", description = "Bridge-local task chain lookup",
	}), "first document should index")
	testing.expect(t, task_chain_search_index_upsert(&index, Task_Chain_Search_Document{
		chain_id = "chain_beta", project_id = "proj_two", status = "completed",
		source_revision = 2, updated_at = "2026-10-14T01:00:00Z",
		title = "Release checklist", description = "Reliable packaging and rollout",
	}), "second document should index")

	hits, searched := task_chain_search_index_query(&index, "reliab", "proj_one", "active", 20)
	testing.expect(t, searched, "prefix query should execute")
	defer task_chain_search_hits_destroy(hits)
	testing.expect_value(t, len(hits), 1)
	if len(hits) == 1 {
		testing.expect_value(t, hits[0].chain_id, "chain_alpha")
		testing.expect(t, strings.contains(hits[0].description_snippet, "task chain"), "description snippet should be returned")
	}

	testing.expect(t, task_chain_search_index_delete(&index, "chain_alpha", 3), "tombstone should apply")
	after_delete, searched_after_delete := task_chain_search_index_query(&index, "reliab", "proj_one", "", 20)
	testing.expect(t, searched_after_delete, "query after tombstone should execute")
	defer task_chain_search_hits_destroy(after_delete)
	testing.expect_value(t, len(after_delete), 0)
}

@(test)
task_chain_search_rebuild_is_atomic_and_lock_drops_plaintext :: proc(t: ^testing.T) {
	sync.mutex_lock(&task_chain_search_global_test_mutex)
	defer sync.mutex_unlock(&task_chain_search_global_test_mutex)
	bridge_task_chain_search_lock()
	defer bridge_task_chain_search_lock()
	documents := [?]Task_Chain_Search_Document{{
		chain_id = "chain_atomic", project_id = "proj", status = "active",
		source_revision = 7, updated_at = "2026-10-14T02:00:00Z",
		title = "Atomic bridge index", description = "stays available until replacement",
	}}
	testing.expect(t, bridge_task_chain_search_rebuild(documents[:], 7), "rebuild should succeed")
	hits, ok, stale, revision := bridge_task_chain_search_query("atomic", "", "", 20)
	testing.expect(t, ok, "rebuilt index should be ready")
	testing.expect(t, !stale, "fresh rebuild should not be stale")
	testing.expect_value(t, revision, i64(7))
	testing.expect_value(t, len(hits), 1)
	task_chain_search_hits_destroy(hits)

	bridge_task_chain_search_mark_stale()
	stale_hits, stale_ok, is_stale, _ := bridge_task_chain_search_query("atomic", "", "", 20)
	testing.expect(t, stale_ok && is_stale, "last valid index should remain queryable while stale")
	task_chain_search_hits_destroy(stale_hits)

	bridge_task_chain_search_lock()
	locked_hits, locked_ok, _, locked_revision := bridge_task_chain_search_query("atomic", "", "", 20)
	testing.expect(t, !locked_ok, "locked vault must not expose an index")
	testing.expect_value(t, len(locked_hits), 0)
	testing.expect_value(t, locked_revision, i64(0))
}

@(test)
task_chain_search_query_treats_fts_syntax_as_text :: proc(t: ^testing.T) {
	query := task_chain_search_match_query(`release OR "private"`)
	defer delete(query)
	testing.expect_value(t, query, `"release"* AND "OR"* AND """private"""*`)
}

@(test)
task_chain_search_feed_decrypts_documents_and_preserves_tombstones :: proc(t: ^testing.T) {
	key_hex := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	// Content fields may be sealed under any epoch the keyring holds.
	kr := test_keyring_two_epochs(key_hex, TEST_ENC_VAULT_KEY)
	defer vault.keyring_wipe(&kr)
	title := test_vault_seal("Encrypted title", key_hex, 1)
	defer delete(title)
	description := test_vault_seal("Secret description", TEST_ENC_VAULT_KEY, 2)
	defer delete(description)
	body := strings.concatenate({
		`{"data":{"next_revision":9,"has_more":false,"documents":[{"revision":8,"operation":"upsert","chain_id":"chain_secure","project_id":"proj_secure","status":"active","updated_at":"2026-10-14T00:00:00Z","title":"`,
		title,
		`","description":"`,
		description,
		`"},{"revision":9,"operation":"delete","chain_id":"chain_old","project_id":"","status":"","updated_at":"","title":"","description":""}]}}`,
	})
	defer delete(body)
	documents, deleted, revision, has_more, parsed := bridge_task_chain_search_parse_feed(body, &kr)
	testing.expect(t, parsed, "feed should parse")
	defer bridge_task_chain_search_documents_destroy(documents)
	defer bridge_task_chain_search_strings_destroy(deleted)
	testing.expect_value(t, revision, i64(9))
	testing.expect(t, !has_more, "fixture is the last page")
	testing.expect_value(t, len(documents), 1)
	testing.expect_value(t, len(deleted), 1)
	if len(documents) == 1 {
		testing.expect_value(t, documents[0].title, "Encrypted title")
		testing.expect_value(t, documents[0].description, "Secret description")
		testing.expect_value(t, documents[0].project_id, "proj_secure")
	}
	if len(deleted) == 1 do testing.expect_value(t, deleted[0], "chain_old")
}

@(test)
task_chain_search_delta_preserves_delete_recreate_order :: proc(t: ^testing.T) {
	sync.mutex_lock(&task_chain_search_global_test_mutex)
	defer sync.mutex_unlock(&task_chain_search_global_test_mutex)
	bridge_task_chain_search_lock()
	defer bridge_task_chain_search_lock()
	seed := [?]Task_Chain_Search_Document{{chain_id = "chain_recreated", project_id = "proj", status = "active", source_revision = 1, title = "Old title"}}
	testing.expect(t, bridge_task_chain_search_rebuild(seed[:], 1), "seed index should build")
	changes := [?]Task_Chain_Search_Change{
		{operation = "delete", chain_id = "chain_recreated", revision = 2},
		{operation = "upsert", chain_id = "chain_recreated", revision = 3, document = {
			chain_id = "chain_recreated", project_id = "proj", status = "active", source_revision = 3, title = "New searchable title",
		}},
	}
	testing.expect(t, bridge_task_chain_search_apply_ordered_changes(changes[:], 3), "ordered page should apply")
	hits, ok, _, revision := bridge_task_chain_search_query("searchable", "", "", 20)
	defer task_chain_search_hits_destroy(hits)
	testing.expect(t, ok, "index remains queryable")
	testing.expect_value(t, revision, i64(3))
	testing.expect_value(t, len(hits), 1)
}

@(test)
task_chain_search_lock_generation_prevents_late_refresh_swap :: proc(t: ^testing.T) {
	sync.mutex_lock(&task_chain_search_global_test_mutex)
	defer sync.mutex_unlock(&task_chain_search_global_test_mutex)
	bridge_task_chain_search_lock()
	defer bridge_task_chain_search_lock()
	generation := bridge_task_chain_search_generation()
	bridge_task_chain_search_lock()
	documents := [?]Task_Chain_Search_Document{{chain_id = "chain_late", source_revision = 1, title = "Must stay locked"}}
	testing.expect(t, !bridge_task_chain_search_rebuild(documents[:], 1, generation), "refresh captured before lock must not swap plaintext back in")
	_, ready, _, _ := bridge_task_chain_search_query("locked", "", "", 20)
	testing.expect(t, !ready, "index remains unavailable after rejected late refresh")
}
