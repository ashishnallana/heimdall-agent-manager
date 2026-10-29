package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"

// The catalog descriptor shipped for Claude Code by Hub migration 105.
@(rodata) provider_extension_test_argv := [?]string{"plugin", "list", "--json"}
@(rodata) provider_extension_test_capabilities := [?]string{"activity", "subagents"}

provider_extension_test_descriptor :: proc() -> Bridge_Catalog_Extension {
	return Bridge_Catalog_Extension{
		detect_argv = provider_extension_test_argv[:],
		plugin_id = "heimdall@heimdall",
		min_version = "0.1.0",
		install_hint = "claude plugin install heimdall@heimdall",
		capabilities = provider_extension_test_capabilities[:],
	}
}

provider_extension_test_expect :: proc(t: ^testing.T, output, want_state, want_version: string, ran := true, loc := #caller_location) {
	state, version := bridge_provider_extension_evaluate(provider_extension_test_descriptor(), output, ran)
	defer delete(version)
	testing.expect_value(t, state, want_state, loc = loc)
	testing.expect_value(t, version, want_version, loc = loc)
}

@(test)
test_provider_extension_enabled_plugin_is_present :: proc(t: ^testing.T) {
	output := `[
  {"id":"other@market","version":"9.0.0","scope":"user","enabled":true},
  {"id":"heimdall@heimdall","version":"0.2.1","scope":"user","enabled":true,"installPath":"/home/u/.claude/plugins/cache/heimdall","errors":[]}
]`
	provider_extension_test_expect(t, output, "present", "0.2.1")
}

@(test)
test_provider_extension_disabled_plugin_is_disabled :: proc(t: ^testing.T) {
	provider_extension_test_expect(t, `[{"id":"heimdall@heimdall","version":"0.2.1","enabled":false}]`, "disabled", "0.2.1")
}

@(test)
test_provider_extension_missing_plugin_is_absent :: proc(t: ^testing.T) {
	provider_extension_test_expect(t, `[]`, "absent", "")
	provider_extension_test_expect(t, `[{"id":"heimdall@elsewhere","version":"1.0.0","enabled":true}]`, "absent", "")
}

@(test)
test_provider_extension_malformed_output_is_error :: proc(t: ^testing.T) {
	provider_extension_test_expect(t, `Unknown command: plugin`, "error", "")
	provider_extension_test_expect(t, `{"id":"heimdall@heimdall"}`, "error", "")
	provider_extension_test_expect(t, `[{"id":"heimdall@heimdall"`, "error", "")
	// A failed, timed-out or breaker-skipped detector is an error, not "absent".
	provider_extension_test_expect(t, `[]`, "error", "", ran = false)
}

@(test)
test_provider_extension_older_version_is_outdated :: proc(t: ^testing.T) {
	provider_extension_test_expect(t, `[{"id":"heimdall@heimdall","version":"0.0.9","enabled":true}]`, "outdated", "0.0.9")
	// Numeric, not lexical, comparison; suffixes and a "v" prefix are tolerated.
	testing.expect_value(t, bridge_provider_extension_version_compare("0.10.0", "0.9.0"), 1)
	testing.expect_value(t, bridge_provider_extension_version_compare("v0.1.0-beta", "0.1.0"), 0)
	testing.expect_value(t, bridge_provider_extension_version_compare("0.1", "0.1.0"), 0)
	testing.expect_value(t, bridge_provider_extension_version_compare("1.0.0", "1.0.1"), -1)
}

@(test)
test_provider_extension_load_errors_are_error :: proc(t: ^testing.T) {
	provider_extension_test_expect(t, `[{"id":"heimdall@heimdall","version":"0.2.1","enabled":true,"errors":["hooks.json: invalid"]}]`, "error", "0.2.1")
}

@(test)
test_provider_extension_best_scope_wins :: proc(t: ^testing.T) {
	// One install per scope: a disabled project copy must not hide an enabled user copy.
	output := `[{"id":"heimdall@heimdall","version":"0.2.0","scope":"project","enabled":false},{"id":"heimdall@heimdall","version":"0.3.0","scope":"user","enabled":true}]`
	provider_extension_test_expect(t, output, "present", "0.3.0")
}

@(test)
test_provider_extension_catalog_null_is_unsupported :: proc(t: ^testing.T) {
	provider: Bridge_Catalog_Provider
	err := json.unmarshal_string(`{"provider":"codex","binary":"codex","extension":null}`, &provider, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, !bridge_provider_extension_supported(provider.extension))
	state, version := bridge_provider_extension_probe("/usr/bin/codex", provider.extension, time.Second)
	defer delete(version)
	testing.expect_value(t, state, "unsupported")

	claude: Bridge_Catalog_Provider
	err = json.unmarshal_string(`{"provider":"claude","binary":"claude","extension":{"detect_argv":["plugin","list","--json"],"plugin_id":"heimdall@heimdall","min_version":"0.1.0","install_hint":"x","capabilities":["activity"]}}`, &claude, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, bridge_provider_extension_supported(claude.extension))
	testing.expect_value(t, len(claude.extension.detect_argv), 3)
	testing.expect_value(t, claude.extension.plugin_id, "heimdall@heimdall")
}

probe_fixture_counter: u64

provider_extension_test_fixture :: proc(t: ^testing.T, body: string) -> string {
	dir, _ := os.temp_directory(context.allocator)
	defer delete(dir)
	seq := sync.atomic_add(&probe_fixture_counter, 1)
	path := fmt.aprintf("%s/heimdall-ext-probe-%p-%d-%d", dir, t, time.to_unix_nanoseconds(time.now()), seq)
	testing.expect(t, os.write_entire_file(path, body) == nil, "fixture must be writable")
	testing.expect(t, os.chmod(path, os.Permissions{.Read_User, .Write_User, .Execute_User}) == nil, "fixture must be executable")
	return path
}

@(test)
test_provider_extension_probe_runs_detect_argv :: proc(t: ^testing.T) {
	// The fixture only answers the catalog's exact argv, proving it is passed through.
	path := provider_extension_test_fixture(t, "#!/bin/sh\n[ \"$1 $2 $3\" = \"plugin list --json\" ] || exit 3\necho 'noise' >&2\necho '[{\"id\":\"heimdall@heimdall\",\"version\":\"0.1.0\",\"enabled\":true}]'\n")
	defer { _ = os.remove(path); delete(path) }
	state, version := bridge_provider_extension_probe(path, provider_extension_test_descriptor(), 5 * time.Second)
	defer delete(version)
	testing.expect_value(t, state, "present")
	testing.expect_value(t, version, "0.1.0")
}

@(test)
test_provider_extension_probe_times_out_as_error :: proc(t: ^testing.T) {
	path := provider_extension_test_fixture(t, "#!/bin/sh\nwhile :; do :; done\n")
	defer { _ = os.remove(path); delete(path) }
	started := time.now()
	state, version := bridge_provider_extension_probe(path, provider_extension_test_descriptor(), 50 * time.Millisecond)
	defer delete(version)
	testing.expect_value(t, state, "error")
	testing.expect(t, time.diff(started, time.now()) < 2 * time.Second, "hung detector must be killed promptly")
}

@(test)
test_provider_discovery_report_includes_extension_state :: proc(t: ^testing.T) {
	results := make([dynamic]Bridge_Provider_Path)
	defer delete(results)
	append(&results, Bridge_Provider_Path{provider = "claude", resolved_path = "/bin/claude", version_text = "2.1", probed_at = "2026-10-22T00:00:00Z", state = "present", extension_state = "outdated", extension_version = "0.0.9"})
	report := bridge_provider_discovery_report_json("pdr_1", results[:])
	defer delete(report)
	wire: struct {
		providers: []struct {
			extension_state:      string `json:"extension_state"`,
			extension_version:    string `json:"extension_version"`,
			extension_checked_at: string `json:"extension_checked_at"`,
		} `json:"providers"`,
	}
	err := json.unmarshal_string(report, &wire, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	if !testing.expect(t, err == nil && len(wire.providers) == 1, "report must be valid JSON") do return
	testing.expect_value(t, wire.providers[0].extension_state, "outdated")
	testing.expect_value(t, wire.providers[0].extension_version, "0.0.9")
	testing.expect_value(t, wire.providers[0].extension_checked_at, "2026-10-22T00:00:00Z")
}

@(test)
test_provider_extension_declarative_installed_collection_and_keys :: proc(t: ^testing.T) {
	ext := provider_extension_test_descriptor()
	ext.plugin_id = "heimdall@heimdall-codex"
	ext.detect_collection = "installed"
	ext.detect_id_key = "pluginId"
	ext.detect_version_key = "version"
	ext.detect_enabled_key = "enabled"
	cases := [?]struct {raw, state: string}{
		{`{"installed":[{"pluginId":"heimdall@heimdall-codex","version":"0.1.0","enabled":true}],"available":[]}`, "present"},
		{`{"installed":[],"available":[{"pluginId":"heimdall@heimdall-codex","version":"0.1.0","enabled":true}]}`, "absent"},
		{`{"installed":[{"pluginId":"heimdall@elsewhere","version":"1.0.0","enabled":true}]}`, "absent"},
		{`{"installed":[{"pluginId":"heimdall@heimdall-codex","version":"0.1.0","enabled":false}]}`, "disabled"},
		{`{"installed":[{"pluginId":"heimdall@heimdall-codex","version":"0.0.9","enabled":true}]}`, "outdated"},
		{`{"installed":[{"pluginId":"heimdall@heimdall-codex","enabled":true}]}`, "error"},
		{`{"installed":[{"pluginId":"heimdall@heimdall-codex","version":"unknown","enabled":true}]}`, "error"},
		{`{"installed":[{"pluginId":"heimdall@heimdall-codex","version":"1garbage","enabled":true}]}`, "error"},
		{`{"installed":[{"pluginId":"heimdall@heimdall-codex","version":"0.1.0","enabled":"true"}]}`, "error"},
		{`{"installed":{},"available":[]}`, "error"},
		{`[]`, "error"},
	}
	for c in cases {
		state, version := bridge_provider_extension_evaluate(ext, c.raw, true)
		testing.expect_value(t, state, c.state)
		delete(version)
	}
}

@(test)
test_provider_extension_antigravity_detection :: proc(t: ^testing.T) {
	ext := Bridge_Catalog_Extension{
		detect_argv = []string{"plugin", "list", "--json"},
		detect_collection = "installed",
		detect_id_key = "name",
		detect_version_key = "version",
		detect_enabled_key = "enabled",
		plugin_id = "heimdall",
		min_version = "0.1.0",
		install_hint = "agy plugin install <repo>/extensions/antigravity",
		capabilities = []string{"activity", "subagents", "permissions", "file_edits", "session_id"},
		load_args = []string{"--add-dir"},
		load_path_suffix = "extensions/antigravity",
	}
	cases := [?]struct {raw, state: string}{
		{`{"installed":[{"name":"heimdall","version":"0.1.0","enabled":true}],"available":[]}`, "present"},
		{`{"installed":[{"name":"other","version":"1.0.0","enabled":true}],"available":[]}`, "absent"},
		{`{"installed":[],"available":[{"name":"heimdall","version":"0.1.0","enabled":true}]}`, "absent"},
		{`{"installed":[{"name":"heimdall","version":"0.1.0","enabled":false}]}`, "disabled"},
		{`{"installed":[{"name":"heimdall","version":"0.0.9","enabled":true}]}`, "outdated"},
		{`{"installed":[{"name":"heimdall","version":"0.2.0","enabled":true}]}`, "present"},
		{`{"imports":[{"name":"heimdall","version":"0.2.0","enabled":true,"importedAt":"2026-10-24"}]}`, "present"},
		{`{"installed":[{"name":"heimdall","enabled":true}]}`, "error"},
		{`{"installed":[{"name":"heimdall","version":"unknown","enabled":true}]}`, "error"},
		{`{"installed":[{"name":"heimdall","version":"0.1.0","enabled":"true"}]}`, "error"},
		{`{"installed":{},"available":[]}`, "error"},
		{`[]`, "error"},
	}
	for c in cases {
		state, version := bridge_provider_extension_evaluate(ext, c.raw, true)
		testing.expect_value(t, state, c.state)
		delete(version)
	}
}

@(test)
test_provider_extension_probe_runs_antigravity_argv :: proc(t: ^testing.T) {
	ext := Bridge_Catalog_Extension{
		detect_argv = []string{"plugin", "list", "--json"},
		detect_collection = "installed",
		detect_id_key = "name",
		detect_version_key = "version",
		detect_enabled_key = "enabled",
		plugin_id = "heimdall",
		min_version = "0.1.0",
		install_hint = "agy plugin install <repo>/extensions/antigravity",
		capabilities = []string{"activity", "subagents", "permissions", "file_edits", "session_id"},
		load_args = []string{"--add-dir"},
		load_path_suffix = "extensions/antigravity",
	}
	path := provider_extension_test_fixture(t, "#!/bin/sh\n[ \"$1 $2 $3\" = \"plugin list --json\" ] || exit 3\necho '{\"installed\":[{\"name\":\"heimdall\",\"version\":\"0.1.0\",\"enabled\":true}]}'\n")
	defer { _ = os.remove(path); delete(path) }
	state, version := bridge_provider_extension_probe(path, ext, time.Second)
	defer delete(version)
	testing.expect_value(t, state, "present")
	testing.expect_value(t, version, "0.1.0")
}


@(test)
test_antigravity_imported_manifest_and_disabled_config :: proc(t: ^testing.T) {
	path := provider_extension_test_fixture(t, `{"version":"0.4.31"}`)
	defer { _ = os.remove(path); delete(path) }
	version := bridge_provider_extension_installed_manifest_version("heimdall", context.temp_allocator, {path})
	testing.expect_value(t, version, "0.4.31")
	testing.expect(t, os.write_entire_file_from_string(path, `{"plugins":{"heimdall":{"enabled":false}}}`) == nil)
	enabled, found := bridge_antigravity_plugin_enabled_state("heimdall", {path})
	testing.expect(t, found && !enabled, "authoritative config detects disable even though imports still lists the plugin")
	testing.expect(t, os.write_entire_file_from_string(path, `{"plugins":{"heimdall":{"enabled":true}}}`) == nil)
	enabled, found = bridge_antigravity_plugin_enabled_state("heimdall", {path})
	testing.expect(t, found && enabled)
	testing.expect(t, os.write_entire_file_from_string(path, "{}") == nil)
	enabled, found = bridge_antigravity_plugin_enabled_state("heimdall", {path})
	testing.expect(t, enabled && !found)
	version = bridge_provider_extension_installed_manifest_version("heimdall", context.temp_allocator, {path})
	testing.expect_value(t, version, "")
}

@(test)
test_provider_extension_imports_schema_is_antigravity_only :: proc(t: ^testing.T) {
	ext := provider_extension_test_descriptor()
	ext.plugin_id = "heimdall"
	ext.detect_collection = "installed"
	ext.detect_id_key = "name"
	ext.detect_version_key = "version"
	ext.detect_enabled_key = "enabled"
	ext.min_version = "0.4.31"
	// Explicit fields make this independent of the host's installed files.
	raw := `{"imports":[{"name":"heimdall","version":"0.4.31","enabled":false,"importedAt":"2026-10-24"}]}`
	state, version := bridge_provider_extension_evaluate(ext, raw, true)
	defer delete(version)
	testing.expect_value(t, state, "disabled")
	testing.expect_value(t, version, "0.4.31")

	ext.plugin_id = "heimdall@heimdall-codex"
	state2, version2 := bridge_provider_extension_evaluate(ext, raw, true)
	defer delete(version2)
	testing.expect(t, state2 == "error", "Codex requires its configured installed collection")

	raw_codex := `{"installed":[{"name":"heimdall@heimdall-codex","version":"0.4.31","importedAt":"2026-10-24"}]}`
	state3, version3 := bridge_provider_extension_evaluate(ext, raw_codex, true)
	defer delete(version3)
	testing.expect(t, state3 == "error", "imports timestamps cannot substitute for Codex enabled evidence")
}

@(test)
test_provider_extension_antigravity_empty_inventory :: proc(t: ^testing.T) {
	ext := provider_extension_test_descriptor()
	ext.plugin_id = "heimdall"
	ext.detect_id_key = "name"
	ext.detect_version_key = "version"
	ext.detect_enabled_key = "enabled"
	for collection in ([]string{"installed", "imports"}) {
		ext.detect_collection = collection
		for output in ([]string{"No imported plugins.", "No imported plugins.\n", " \tNo imported plugins.\r\n"}) {
			state, version := bridge_provider_extension_evaluate(ext, output, true)
			testing.expect_value(t, state, "absent")
			testing.expect_value(t, version, "")
			delete(version)
		}
	}
	for output in ([]string{"", "No imported plugins", "no imported plugins.", "Warning: No imported plugins.", "No imported plugins.\nerror", "{broken"}) {
		state, version := bridge_provider_extension_evaluate(ext, output, true)
		testing.expect_value(t, state, "error")
		delete(version)
	}
	state, version := bridge_provider_extension_evaluate(ext, "No imported plugins.", false)
	defer delete(version)
	testing.expect_value(t, state, "error")

	// Claude and Codex must continue to reject this non-JSON response.
	provider_extension_test_expect(t, "No imported plugins.", "error", "")
	ext.plugin_id = "heimdall@heimdall-codex"
	state2, version2 := bridge_provider_extension_evaluate(ext, "No imported plugins.", true)
	defer delete(version2)
	testing.expect_value(t, state2, "error")
}

@(test)
test_provider_extension_antigravity_empty_probe_exit_status :: proc(t: ^testing.T) {
	ext := provider_extension_test_descriptor()
	ext.plugin_id = "heimdall"
	ext.detect_collection = "installed"
	ext.detect_id_key = "name"
	for exit_code in ([]int{0, 1}) {
		body := fmt.aprintf("#!/bin/sh\n[ \"$1 $2 $3\" = \"plugin list --json\" ] || exit 3\nprintf 'No imported plugins.\\n'\nexit %d\n", exit_code)
		path := provider_extension_test_fixture(t, body)
		delete(body)
		state, version := bridge_provider_extension_probe(path, ext, time.Second)
		testing.expect_value(t, state, "absent" if exit_code == 0 else "error")
		testing.expect_value(t, version, "")
		delete(version)
		_ = os.remove(path)
		delete(path)
	}
}
