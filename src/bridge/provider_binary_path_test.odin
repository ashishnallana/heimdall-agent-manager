package main

import "core:strings"
import "core:sync"
import "core:testing"

// Installs a one-provider catalog snapshot for the duration of a test.
provider_binary_path_with_catalog :: proc(snap: ^Bridge_Provider_Catalog_Snapshot) -> (old: ^Bridge_Provider_Catalog_Snapshot, old_loaded: bool) {
	sync.rw_mutex_lock(&bridge_provider_catalog_mutex)
	old, old_loaded = bridge_provider_catalog_snapshot, bridge_provider_catalog_loaded
	bridge_provider_catalog_snapshot = snap
	bridge_provider_catalog_loaded = true
	sync.rw_mutex_unlock(&bridge_provider_catalog_mutex)
	return
}

provider_binary_path_restore_catalog :: proc(old: ^Bridge_Provider_Catalog_Snapshot, old_loaded: bool) {
	sync.rw_mutex_lock(&bridge_provider_catalog_mutex)
	bridge_provider_catalog_snapshot = old
	bridge_provider_catalog_loaded = old_loaded
	sync.rw_mutex_unlock(&bridge_provider_catalog_mutex)
}

@(test)
test_discovery_report_carries_absolute_path_for_path_resolved_provider :: proc(t: ^testing.T) {
	result := bridge_provider_probe_one("claude", "sh")
	defer bridge_provider_path_destroy(&result)
	if !testing.expect_value(t, result.state, "present") do return
	testing.expect(t, strings.has_prefix(result.resolved_path, "/"), "resolved path is absolute")
	report := bridge_provider_discovery_report_json("req", []Bridge_Provider_Path{result})
	defer delete(report)
	// The default profile is reported under its effective id, which is the provider.
	testing.expect(t, strings.contains(report, `"profile_id":"claude"`), report)
	want := strings.concatenate({`"binary_path":"`, result.resolved_path, `"`})
	defer delete(want)
	testing.expect(t, strings.contains(report, want), report)
}

@(test)
test_extension_install_resolves_catalog_binary_on_path :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	snap := Bridge_Provider_Catalog_Snapshot{providers = []Bridge_Catalog_Provider{{provider = "binpathprov", state = "active", binary = "sh"}}}
	old, old_loaded := provider_binary_path_with_catalog(&snap)
	defer provider_binary_path_restore_catalog(old, old_loaded)

	// Default profile (the hub sends profile_id == provider): no override, so the
	// catalog binary is resolved on PATH, exactly as discovery does.
	pp := Provider_Profile{profile_id = "binpathprov", provider = "binpathprov", enabled = true}
	path, ok := bridge_extension_resolve_profile_binary("binpathprov", &pp)
	defer if ok do delete(path)
	testing.expect(t, ok, "PATH binary must resolve for a default profile")
	testing.expect(t, strings.has_prefix(path, "/"), "resolved path is absolute")

	// An override wins over PATH.
	pp.config.binary_path = "/definitely/not/here"
	_, ok2 := bridge_extension_resolve_profile_binary("binpathprov", &pp)
	testing.expect(t, !ok2, "a missing override must not silently fall back")

	// Unknown provider: not found, not a crash.
	other := Provider_Profile{profile_id = "nope", provider = "nope", enabled = true}
	_, ok3 := bridge_extension_resolve_profile_binary("nope", &other)
	testing.expect(t, !ok3)
}

provider_binary_path_reprobes: int

@(test)
test_first_catalog_sync_reprobes_providers_once :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	old, old_loaded := provider_binary_path_with_catalog(nil)
	defer provider_binary_path_restore_catalog(old, old_loaded)
	saved_hook := bridge_provider_reprobe_hook
	defer bridge_provider_reprobe_hook = saved_hook
	provider_binary_path_reprobes = 0
	bridge_provider_reprobe_hook = proc() {provider_binary_path_reprobes += 1}

	first := Bridge_Provider_Catalog_Snapshot{providers = []Bridge_Catalog_Provider{{provider = "claude", state = "active", binary = "claude"}}}
	bridge_provider_catalog_publish_and_probe(&first)
	testing.expect_value(t, provider_binary_path_reprobes, 1)
	// A later catalog edit (providers already known) does not re-probe.
	second := Bridge_Provider_Catalog_Snapshot{providers = []Bridge_Catalog_Provider{{provider = "claude", state = "active", binary = "claude"}, {provider = "codex", state = "active", binary = "codex"}}}
	bridge_provider_catalog_publish_and_probe(&second)
	testing.expect_value(t, provider_binary_path_reprobes, 1)
	// An empty first catalog has nothing to probe.
	provider_binary_path_with_catalog(nil)
	empty := Bridge_Provider_Catalog_Snapshot{}
	bridge_provider_catalog_publish_and_probe(&empty)
	testing.expect_value(t, provider_binary_path_reprobes, 1)
}
