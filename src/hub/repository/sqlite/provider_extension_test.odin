#+private file
// REQ-EXT-DET-1: the catalog extension descriptor (migration 107) and the
// persisted per-Bridge extension probe result.
package sqlite

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import provider_service "odin_test:hub/service/provider"
import "core:strings"
import "core:testing"

@(test)
test_provider_catalog_extension_descriptors_preserve_claude_and_add_codex :: proc(t: ^testing.T) {
	conn, clone_ok := tmpl_clone_migrated(t)
	if !clone_ok do return
	defer close(&conn)
	impl := Provider_Repo_SQLite{conn = &conn}
	repo := new_provider_repository(&impl, &conn)

	catalog, err := iface.provider_catalog_list(&repo)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	defer domain.provider_catalog_destroy(catalog)
	saw_claude := false
	saw_antigravity := false
	for entry in catalog {
		if entry.provider == "claude" {
			saw_claude = true
			testing.expect(t, strings.contains(entry.extension_json, `"detect_argv":["plugin","list","--json"]`), "claude detects via plugin list")
			testing.expect(t, strings.contains(entry.extension_json, `"plugin_id":"heimdall@heimdall"`), "claude plugin id")
			testing.expect(t, strings.contains(entry.extension_json, `"load_args":["--plugin-dir"]`), "catalog declares the extension loader argv")
			testing.expect(t, strings.contains(entry.extension_json, `"load_path_suffix":"extensions/claude"`), "loader is restricted to this extension directory")
			testing.expect(t, strings.contains(entry.extension_json, `"min_version":"0.4.31"`), "claude min_version")
			testing.expect(t, strings.contains(entry.extension_json, `"capabilities":["activity","subagents","permissions","file_edits","session_id"]`), "claude capabilities")
		} else if entry.provider == "codex" {
			testing.expect(t, strings.contains(entry.extension_json, `"detect_argv":["plugin","list","--marketplace","heimdall-codex","--json"]`), "native inventory avoids unrelated remote marketplaces")
			testing.expect(t, strings.contains(entry.extension_json, `"detect_collection":"installed"`))
			testing.expect(t, strings.contains(entry.extension_json, `"detect_id_key":"pluginId"`))
			testing.expect(t, strings.contains(entry.extension_json, `"plugin_id":"heimdall@heimdall-codex"`))
			testing.expect(t, strings.contains(entry.extension_json, `"min_version":"0.4.31"`), "codex min_version")
		} else if entry.provider == "antigravity" {
			saw_antigravity = true
			testing.expect(t, strings.contains(entry.extension_json, `"detect_argv":["plugin","list","--json"]`), "antigravity detects via plugin list")
			testing.expect(t, strings.contains(entry.extension_json, `"detect_collection":"installed"`))
			testing.expect(t, strings.contains(entry.extension_json, `"detect_id_key":"name"`))
			testing.expect(t, strings.contains(entry.extension_json, `"detect_version_key":"version"`))
			testing.expect(t, strings.contains(entry.extension_json, `"detect_enabled_key":"enabled"`))
			testing.expect(t, strings.contains(entry.extension_json, `"plugin_id":"heimdall"`))
			testing.expect(t, strings.contains(entry.extension_json, `"min_version":"0.4.31"`), "antigravity min_version")
			testing.expect(t, strings.contains(entry.extension_json, `"install_hint":"agy plugin install <repo>/extensions/antigravity"`))
			testing.expect(t, strings.contains(entry.extension_json, `"capabilities":["activity","subagents","permissions","file_edits","session_id"]`))
			testing.expect(t, strings.contains(entry.extension_json, `"load_args":["--add-dir"]`))
			testing.expect(t, strings.contains(entry.extension_json, `"load_path_suffix":"extensions/antigravity"`))
		} else {
			testing.expectf(t, entry.extension_json == "", "%s has no extension", entry.provider)
		}
	}
	testing.expect(t, saw_claude, "claude catalog entry exists")
	testing.expect(t, saw_antigravity, "antigravity catalog entry exists")

	// The canonical body (replicated to Bridges and served by /api/v1/providers)
	// carries the descriptor object, or null for unsupported providers.
	body := provider_service.catalog_body_json(catalog)
	defer delete(body)
	testing.expect(t, strings.contains(body, `"extension":{"detect_argv":`), "claude descriptor is on the wire")
	testing.expect(t, strings.contains(body, `"extension":null`), "unsupported providers are null on the wire")
}

@(test)
test_provider_discovery_report_persists_extension_state :: proc(t: ^testing.T) {
	conn, clone_ok := tmpl_clone_migrated(t)
	if !clone_ok do return
	defer close(&conn)
	impl := Provider_Repo_SQLite{conn = &conn}
	repo := new_provider_repository(&impl, &conn)
	service := provider_service.Provider_Service{repo = &repo}

	report := []domain.Bridge_Provider_Status{
		{bridge_id = "brg_ext", provider = "claude", binary_path = "/bin/claude", version_text = "2.1.295", state = "present", checked_at = "2026-10-22T00:00:00Z", extension_state = "outdated", extension_version = "0.0.9", extension_checked_at = "2026-10-22T00:00:01Z"},
		// The catalog owns the Codex descriptor; native package probe state persists.
		{bridge_id = "brg_ext", provider = "codex", binary_path = "/bin/codex", state = "present", checked_at = "2026-10-22T00:00:00Z", extension_state = "present", extension_version = "1.0.0", extension_checked_at = "2026-10-22T00:00:01Z"},
		// A Bridge that predates extension detection reports nothing.
		{bridge_id = "brg_ext", provider = "copilot", state = "absent", checked_at = "2026-10-22T00:00:00Z"},
	}
	testing.expect_value(t, provider_service.apply_discovery_report(&service, "brg_ext", report).code, domain.Error_Code.None)

	views, err := provider_service.list_bridge_providers(&service, "brg_ext")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	defer provider_service.bridge_provider_views_destroy(views)
	seen := 0
	for view in views {
		switch view.catalog.provider {
		case "claude":
			seen += 1
			testing.expect_value(t, view.extension_state, "outdated")
			testing.expect_value(t, view.extension_version, "0.0.9")
			testing.expect_value(t, view.extension_checked_at, "2026-10-22T00:00:01Z")
		case "codex":
			seen += 1
			testing.expect_value(t, view.extension_state, "present")
			testing.expect_value(t, view.extension_version, "1.0.0")
		case "copilot":
			seen += 1
			testing.expect_value(t, view.extension_state, "")
		}
	}
	testing.expect_value(t, seen, 3)

	// A re-probe overwrites the previous result.
	update := []domain.Bridge_Provider_Status{
		{bridge_id = "brg_ext", provider = "claude", binary_path = "/bin/claude", state = "present", checked_at = "2026-10-22T01:00:00Z", extension_state = "present", extension_version = "0.2.0", extension_checked_at = "2026-10-22T01:00:01Z"},
	}
	testing.expect_value(t, provider_service.apply_discovery_report(&service, "brg_ext", update).code, domain.Error_Code.None)
	statuses, list_err := iface.bridge_provider_status_list(&repo, "brg_ext")
	testing.expect_value(t, list_err.code, domain.Error_Code.None)
	defer domain.bridge_provider_statuses_destroy(statuses)
	for status in statuses {
		if status.provider != "claude" do continue
		testing.expect_value(t, status.extension_state, "present")
		testing.expect_value(t, status.extension_version, "0.2.0")
		testing.expect_value(t, status.extension_checked_at, "2026-10-22T01:00:01Z")
	}
}

@(test)
test_provider_discovery_report_rejects_unknown_extension_state :: proc(t: ^testing.T) {
	conn, clone_ok := tmpl_clone_migrated(t)
	if !clone_ok do return
	defer close(&conn)
	impl := Provider_Repo_SQLite{conn = &conn}
	repo := new_provider_repository(&impl, &conn)
	service := provider_service.Provider_Service{repo = &repo}
	report := []domain.Bridge_Provider_Status{
		{bridge_id = "brg_ext", provider = "claude", state = "present", checked_at = "2026-10-22T00:00:00Z", extension_state = "installed"},
	}
	testing.expect_value(t, provider_service.apply_discovery_report(&service, "brg_ext", report).code, domain.Error_Code.Validation_Failed)
}

@(test)
test_provider_discovery_report_ignores_stale_catalog_unsupported :: proc(t: ^testing.T) {
	conn, clone_ok := tmpl_clone_migrated(t)
	if !clone_ok do return
	defer close(&conn)
	impl := Provider_Repo_SQLite{conn = &conn}
	repo := new_provider_repository(&impl, &conn)
	service := provider_service.Provider_Service{repo = &repo}
	// A Bridge whose catalog snapshot predates the claude descriptor reports
	// "unsupported"; the Hub records "not measured yet" until it resyncs.
	report := []domain.Bridge_Provider_Status{
		{bridge_id = "brg_ext", provider = "claude", binary_path = "/bin/claude", state = "present", checked_at = "2026-10-22T00:00:00Z", extension_state = "unsupported", extension_checked_at = "2026-10-22T00:00:01Z"},
	}
	testing.expect_value(t, provider_service.apply_discovery_report(&service, "brg_ext", report).code, domain.Error_Code.None)
	statuses, list_err := iface.bridge_provider_status_list(&repo, "brg_ext")
	testing.expect_value(t, list_err.code, domain.Error_Code.None)
	defer domain.bridge_provider_statuses_destroy(statuses)
	seen := false
	for status in statuses {
		if status.provider != "claude" do continue
		seen = true
		testing.expect_value(t, status.extension_state, "")
		testing.expect_value(t, status.extension_version, "")
	}
	testing.expect(t, seen, "claude status stored")
}
