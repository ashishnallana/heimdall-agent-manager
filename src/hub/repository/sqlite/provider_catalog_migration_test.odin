#+private file
// Behavioral tests for the provider catalog state produced by the migrations.
package sqlite

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import provider_service "odin_test:hub/service/provider"
import "core:strings"
import "core:testing"

// Migration 086: Heimdall launches claude with --dangerously-skip-permissions,
// so the "Bypass Permissions mode" warning must be auto-accepted (Down selects
// "Yes, I accept"; the default is "No, exit").
@(test)
test_claude_catalog_auto_accepts_bypass_permissions_warning :: proc(t: ^testing.T) {
	conn, clone_ok := tmpl_clone_migrated(t)
	if !clone_ok do return
	defer close(&conn)

	impl := Provider_Repo_SQLite{conn = &conn}
	repo := new_provider_repository(&impl, &conn)
	entry, found, err := iface.provider_catalog_get(&repo, "claude")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect(t, found, "claude catalog entry exists")
	defer domain.provider_catalog_entry_destroy(entry)
	testing.expect(
		t,
		strings.contains(entry.startup_detection_json, `"Yes, I trust this folder","Bypass Permissions mode"]`),
		"bypass warning is an auto-enter pattern after folder trust",
	)
	testing.expect(
		t,
		strings.contains(entry.startup_detection_json, `"auto_enter_pre_keys":["Up","Up","Down"]`),
		"bypass warning pre-key is Down, parallel to its pattern",
	)
}

// provider_catalog_meta is audit metadata, but it should match the etag the
// Hub derives from the canonical body so operators inspecting the DB see truth.
@(test)
test_provider_catalog_meta_etag_matches_canonical_body :: proc(t: ^testing.T) {
	conn, clone_ok := tmpl_clone_migrated(t)
	if !clone_ok do return
	defer close(&conn)

	impl := Provider_Repo_SQLite{conn = &conn}
	repo := new_provider_repository(&impl, &conn)
	stored, err := iface.provider_catalog_etag(&repo)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	defer delete(stored)
	service := provider_service.Provider_Service{repo = &repo}
	derived, derive_err := provider_service.catalog_etag(&service)
	testing.expect_value(t, derive_err.code, domain.Error_Code.None)
	defer delete(derived)
	testing.expect_value(t, stored, derived)
}

// Migration 109: permission_mode 'ask' launches with ask_args instead of
// yolo_args. Claude needs an explicit --permission-mode default, otherwise it
// inherits the user's default mode ("auto" auto-approves and never prompts).
@(test)
test_provider_catalog_ask_args_claude_only :: proc(t: ^testing.T) {
	conn, clone_ok := tmpl_clone_migrated(t)
	if !clone_ok do return
	defer close(&conn)

	impl := Provider_Repo_SQLite{conn = &conn}
	repo := new_provider_repository(&impl, &conn)
	catalog, err := iface.provider_catalog_list(&repo)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	defer domain.provider_catalog_destroy(catalog)
	saw_claude := false
	for entry in catalog {
		if entry.provider == "claude" {
			saw_claude = true
			testing.expect_value(t, entry.ask_args_json, `["--permission-mode","default"]`)
		} else {
			testing.expectf(t, entry.ask_args_json == "[]", "%s has no ask_args, got %s", entry.provider, entry.ask_args_json)
		}
	}
	testing.expect(t, saw_claude, "claude catalog entry exists")

	body := provider_service.catalog_body_json(catalog)
	defer delete(body)
	testing.expect(t, strings.contains(body, `"ask_args":["--permission-mode","default"]`), "claude ask_args on the wire")
	testing.expect(t, strings.contains(body, `"ask_args":[]`), "other providers carry an empty ask_args")
}

// Migration 101: Codex 0.162 ships the GPT-6 family. gpt-6.1-sol is the
// default (lowest rank) for codex, Pi exposes the same ids under
// openai-codex/, and the GPT-5.6 rows stay for history but are retired.
@(test)
test_codex_and_pi_catalog_select_gpt6_models :: proc(t: ^testing.T) {
	conn, clone_ok := tmpl_clone_migrated(t)
	if !clone_ok do return
	defer close(&conn)

	impl := Provider_Repo_SQLite{conn = &conn}
	expect_models :: proc(t: ^testing.T, impl: ^Provider_Repo_SQLite, provider: string, active: []string, deprecated: []string) {
		models, err := provider_models_for_sqlite(impl, provider)
		testing.expect_value(t, err.code, domain.Error_Code.None)
		defer {
			for model in models do domain.provider_model_destroy(model)
			delete(models)
		}
		active_ids := make([dynamic]string, context.temp_allocator)
		for model in models {
			if model.state == "active" && strings.contains(model.model_id, "gpt-") do append(&active_ids, model.model_id)
		}
		testing.expect_value(t, len(active_ids), len(active))
		for want, i in active {
			if i < len(active_ids) do testing.expect_value(t, active_ids[i], want)
		}
		for want in deprecated {
			found := false
			for model in models {
				if model.model_id != want do continue
				found = true
				testing.expect_value(t, model.state, "deprecated")
			}
			testing.expectf(t, found, "%s row kept", want)
		}
	}
	expect_models(t, &impl, "codex",
		{"gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna"},
		{"gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"})
	expect_models(t, &impl, "pi",
		{"openai-codex/gpt-6.1-sol", "openai-codex/gpt-6-astra", "openai-codex/gpt-6-sol", "openai-codex/gpt-6-luna"},
		{"openai-codex/gpt-5.6-sol", "openai-codex/gpt-5.6-luna"})
}
