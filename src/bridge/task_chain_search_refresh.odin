package main

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import http "odin_test:lib/http_client"

TASK_CHAIN_SEARCH_REFRESH_SECONDS :: 30

Task_Chain_Document_Source_Fetch :: #type proc(after_revision: i64) -> (body: string, ok: bool)
Task_Chain_Document_Source :: struct {
	fetch: Task_Chain_Document_Source_Fetch,
}

@(private = "file")
bridge_task_chain_search_refresh_mutex: sync.Mutex
@(private = "file")
bridge_task_chain_search_refresh_running: bool
@(private = "file")
bridge_task_chain_search_refresh_started: bool

bridge_task_chain_search_document_destroy :: proc(document: ^Task_Chain_Search_Document) {
	if document == nil do return
	delete(document.chain_id)
	delete(document.project_id)
	delete(document.status)
	delete(document.updated_at)
	delete(document.title)
	delete(document.description)
	document^ = Task_Chain_Search_Document{}
}

bridge_task_chain_search_documents_destroy :: proc(documents: []Task_Chain_Search_Document) {
	for &document in documents do bridge_task_chain_search_document_destroy(&document)
	delete(documents)
}

bridge_task_chain_search_strings_destroy :: proc(values: []string) {
	for value in values do delete(value)
	delete(values)
}

bridge_task_chain_search_changes_destroy :: proc(changes: []Task_Chain_Search_Change) {
	for &change in changes {
		if change.operation == "upsert" do bridge_task_chain_search_document_destroy(&change.document)
		delete(change.operation)
		delete(change.chain_id)
	}
	delete(changes)
}

bridge_task_chain_search_parse_failure :: proc(
	documents: ^[dynamic]Task_Chain_Search_Document,
	deleted_chain_ids: ^[dynamic]string,
) -> ([]Task_Chain_Search_Document, []string, i64, bool, bool) {
	if documents != nil do bridge_task_chain_search_documents_destroy(documents^[:])
	if deleted_chain_ids != nil do bridge_task_chain_search_strings_destroy(deleted_chain_ids^[:])
	return nil, nil, 0, false, false
}

bridge_task_chain_search_change_parse_failure :: proc(changes: ^[dynamic]Task_Chain_Search_Change) -> ([]Task_Chain_Search_Change, i64, bool, bool) {
	if changes != nil do bridge_task_chain_search_changes_destroy(changes^[:])
	return nil, 0, false, false
}

bridge_hub_task_chain_document_fetch :: proc(after_revision: i64) -> (body: string, ok: bool) {
	if strings.trim_space(bridge_config.daemon_url) == "" || strings.trim_space(bridge_config.bridge_token) == "" do return "", false
	path := fmt.tprintf("/api/v1/bridge/task-chain-search/documents?after_revision=%d&limit=500", after_revision)
	defer delete(path)
	auth := strings.concatenate({"Bearer ", bridge_config.bridge_token})
	defer delete(auth)
	headers := [?]http.Header{{name = "Authorization", value = auth}}
	resp, sent := bridge_http_request_retry("GET", bridge_config.daemon_url, path, "", headers[:], http.DEFAULT_TIMEOUT_MS)
	if !sent || resp.status != 200 {
		delete(resp.body)
		return "", false
	}
	return resp.body, true
}

// The sole storage seam. A future Bridge-primary store can replace this source
// without introducing a repository/replication abstraction into today's design.
bridge_task_chain_document_source :: proc() -> Task_Chain_Document_Source {
	return Task_Chain_Document_Source{fetch = bridge_hub_task_chain_document_fetch}
}


bridge_task_chain_search_parse_changes :: proc(body, key_hex: string) -> (changes: []Task_Chain_Search_Change, next_revision: i64, has_more: bool, ok: bool) {
	out := make([dynamic]Task_Chain_Search_Change)
	data_obj, data_ok := bridge_provider_json_extract_object(body, "data")
	if !data_ok do return bridge_task_chain_search_change_parse_failure(&out)
	defer delete(data_obj)
	documents_json, docs_ok := bridge_provider_json_extract_array(data_obj, "documents")
	if !docs_ok do return bridge_task_chain_search_change_parse_failure(&out)
	defer delete(documents_json)
	objects := bridge_provider_json_top_level_objects(documents_json)
	defer { for object in objects do delete(object); delete(objects) }
	next_int, next_ok := bridge_provider_json_extract_int(data_obj, "next_revision")
	if !next_ok do return bridge_task_chain_search_change_parse_failure(&out)
	has_more = strings.contains(data_obj, `"has_more":true`)
	for object in objects {
		operation := bridge_provider_json_extract_string(object, "operation", "")
		chain_id := bridge_provider_json_extract_string(object, "chain_id", "")
		revision, revision_ok := bridge_provider_json_extract_int(object, "revision")
		if chain_id == "" || !revision_ok || (operation != "upsert" && operation != "delete") {
			delete(operation); delete(chain_id)
			return bridge_task_chain_search_change_parse_failure(&out)
		}
		change := Task_Chain_Search_Change{operation = operation, chain_id = chain_id, revision = i64(revision)}
		if operation == "upsert" {
			title_ciphertext := bridge_provider_json_extract_string(object, "title", "")
			description_ciphertext := bridge_provider_json_extract_string(object, "description", "")
			title, title_ok := bridge_decrypt_vault_ciphertext_hex(title_ciphertext, key_hex)
			description, description_ok := bridge_decrypt_vault_ciphertext_hex(description_ciphertext, key_hex)
			delete(title_ciphertext); delete(description_ciphertext)
			if !title_ok || !description_ok {
				delete(title); delete(description); delete(operation); delete(chain_id)
				return bridge_task_chain_search_change_parse_failure(&out)
			}
			change.document = Task_Chain_Search_Document{
				chain_id = strings.clone(chain_id), project_id = bridge_provider_json_extract_string(object, "project_id", ""),
				status = bridge_provider_json_extract_string(object, "status", ""), source_revision = i64(revision),
				updated_at = bridge_provider_json_extract_string(object, "updated_at", ""), title = title, description = description,
			}
		}
		append(&out, change)
	}
	return out[:], i64(next_int), has_more, true
}

bridge_task_chain_search_parse_feed :: proc(body, key_hex: string) -> (
	documents: []Task_Chain_Search_Document,
	deleted_chain_ids: []string,
	next_revision: i64,
	has_more: bool,
	ok: bool,
) {
	documents_out := make([dynamic]Task_Chain_Search_Document)
	deleted_out := make([dynamic]string)

	data_obj, data_ok := bridge_provider_json_extract_object(body, "data")
	if !data_ok do return bridge_task_chain_search_parse_failure(&documents_out, &deleted_out)
	defer delete(data_obj)
	documents_json, docs_ok := bridge_provider_json_extract_array(data_obj, "documents")
	if !docs_ok do return bridge_task_chain_search_parse_failure(&documents_out, &deleted_out)
	defer delete(documents_json)
	objects := bridge_provider_json_top_level_objects(documents_json)
	defer {
		for object in objects do delete(object)
		delete(objects)
	}

	next_int, next_ok := bridge_provider_json_extract_int(data_obj, "next_revision")
	if !next_ok do return bridge_task_chain_search_parse_failure(&documents_out, &deleted_out)
	has_more = strings.contains(data_obj, `"has_more":true`)
	for object in objects {
		operation := bridge_provider_json_extract_string(object, "operation", "")
		defer delete(operation)
		chain_id := bridge_provider_json_extract_string(object, "chain_id", "")
		defer delete(chain_id)
		revision, revision_ok := bridge_provider_json_extract_int(object, "revision")
		if chain_id == "" || !revision_ok do return bridge_task_chain_search_parse_failure(&documents_out, &deleted_out)
		if operation == "delete" {
			append(&deleted_out, strings.clone(chain_id))
			continue
		}
		if operation != "upsert" do return bridge_task_chain_search_parse_failure(&documents_out, &deleted_out)
		title_ciphertext := bridge_provider_json_extract_string(object, "title", "")
		defer delete(title_ciphertext)
		description_ciphertext := bridge_provider_json_extract_string(object, "description", "")
		defer delete(description_ciphertext)
		title, title_ok := bridge_decrypt_vault_ciphertext_hex(title_ciphertext, key_hex)
		if !title_ok do return bridge_task_chain_search_parse_failure(&documents_out, &deleted_out)
		description, description_ok := bridge_decrypt_vault_ciphertext_hex(description_ciphertext, key_hex)
		if !description_ok {
			delete(title)
			return bridge_task_chain_search_parse_failure(&documents_out, &deleted_out)
		}
		append(&documents_out, Task_Chain_Search_Document{
			chain_id = strings.clone(chain_id),
			project_id = bridge_provider_json_extract_string(object, "project_id", ""),
			status = bridge_provider_json_extract_string(object, "status", ""),
			source_revision = i64(revision),
			updated_at = bridge_provider_json_extract_string(object, "updated_at", ""),
			title = title,
			description = description,
		})
	}
	return documents_out[:], deleted_out[:], i64(next_int), has_more, true
}

bridge_task_chain_search_refresh_once :: proc() {
	sync.mutex_lock(&bridge_task_chain_search_refresh_mutex)
	if bridge_task_chain_search_refresh_running {
		sync.mutex_unlock(&bridge_task_chain_search_refresh_mutex)
		return
	}
	bridge_task_chain_search_refresh_running = true
	sync.mutex_unlock(&bridge_task_chain_search_refresh_mutex)
	defer {
		sync.mutex_lock(&bridge_task_chain_search_refresh_mutex)
		bridge_task_chain_search_refresh_running = false
		sync.mutex_unlock(&bridge_task_chain_search_refresh_mutex)
	}

	key_hex, key_ok := bridge_read_vault_key()
	if !key_ok do return
	vault_generation := bridge_task_chain_search_generation()
	defer {
		mem.zero_explicit(raw_data(key_hex), len(key_hex))
		delete(key_hex)
	}

	ready, _, indexed_revision := bridge_task_chain_search_status()
	after_revision := indexed_revision if ready else 0
	source := bridge_task_chain_document_source()
	for {
		body, fetched := source.fetch(after_revision)
		if !fetched {
			if ready do bridge_task_chain_search_mark_stale()
			return
		}
		documents: []Task_Chain_Search_Document
		deleted: []string
		changes: []Task_Chain_Search_Change
		next_revision: i64
		has_more, parsed := false, false
		if !ready {
			documents, deleted, next_revision, has_more, parsed = bridge_task_chain_search_parse_feed(body, key_hex)
		} else {
			changes, next_revision, has_more, parsed = bridge_task_chain_search_parse_changes(body, key_hex)
		}
		delete(body)
		if !parsed {
			if ready do bridge_task_chain_search_mark_stale()
			return
		}
		applied := false
		if !ready {
			applied = bridge_task_chain_search_rebuild(documents, next_revision, vault_generation)
			ready = applied
		} else {
			applied = bridge_task_chain_search_apply_ordered_changes(changes, next_revision, vault_generation)
		}
		bridge_task_chain_search_documents_destroy(documents)
		bridge_task_chain_search_strings_destroy(deleted)
		bridge_task_chain_search_changes_destroy(changes)
		if !applied do return
		after_revision = next_revision
		if !has_more do return
	}
}

bridge_task_chain_search_refresh_async :: proc() {
	thread.run(bridge_task_chain_search_refresh_once)
}

bridge_task_chain_search_refresh_worker :: proc() {
	for {
		bridge_task_chain_search_refresh_once()
		time.sleep(TASK_CHAIN_SEARCH_REFRESH_SECONDS * time.Second)
	}
}

bridge_task_chain_search_start :: proc() {
	sync.mutex_lock(&bridge_task_chain_search_refresh_mutex)
	if bridge_task_chain_search_refresh_started {
		sync.mutex_unlock(&bridge_task_chain_search_refresh_mutex)
		return
	}
	bridge_task_chain_search_refresh_started = true
	sync.mutex_unlock(&bridge_task_chain_search_refresh_mutex)
	thread.run(bridge_task_chain_search_refresh_worker)
}
