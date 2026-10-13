package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

Provider_Discovery_Test_Job :: struct {
	filter: []string,
	results: [dynamic]Bridge_Provider_Path,
}

provider_discovery_test_worker :: proc(th: ^thread.Thread) {
	job := (^Provider_Discovery_Test_Job)(th.data)
	job.results = bridge_provider_discover(job.filter)
}

@(test)
test_provider_json_helpers :: proc(t: ^testing.T) {
	body := `{"provider":"codex","models":["gpt-5","gpt-5-pro"]}`
	provider := bridge_provider_json_extract_string(body, "provider", "")
	defer delete(provider)
	testing.expect_value(t, provider, "codex")
	models, ok := bridge_provider_json_extract_string_array(body, "models")
	defer if models != nil {
		for model in models do delete(model)
		delete(models)
	}
	testing.expect(t, ok)
	testing.expect_value(t, len(models), 2)
	if len(models) == 2 do testing.expect_value(t, models[1], "gpt-5-pro")
}

@(test)
test_provider_shell_join_quotes_arguments :: proc(t: ^testing.T) {
	joined := bridge_shell_join([]string{"/usr/bin/codex", "-m", "gpt-5 pro", "it's ready"})
	defer delete(joined)
	testing.expect(t, strings.contains(joined, "'gpt-5 pro'"))
	testing.expect(t, strings.contains(joined, "'it'\\''s ready'"))
}

@(test)
test_runtime_find_on_path_returns_owned_path :: proc(t: ^testing.T) {
	path := bridge_runtime_find_on_path("sh")
	if !testing.expect(t, path != "", "test shell is discoverable on PATH") do return
	// The resolver contract gives ownership to the caller. In particular, an
	// already-absolute PATH entry must not be freed inside the resolver and then
	// returned as a dangling string.
	delete(path)
}

@(test)
test_provider_removed_from_path_degrades_to_absent :: proc(t: ^testing.T) {
	result := bridge_provider_probe_one(
		"codex",
		"heimdall-provider-binary-that-does-not-exist-18dcd",
	)
	defer bridge_provider_path_destroy(&result)
	testing.expect_value(t, result.provider, "codex")
	testing.expect_value(t, result.state, "absent")
	testing.expect_value(t, result.resolved_path, "")
	// Destruction is part of the regression: an unavailable formerly-cached
	// provider must produce a fully owned absent record, not a dangling PATH
	// string that crashes the Bridge during launch cleanup.
}

@(test)
test_provider_version_probe_kills_and_reaps_at_deadline :: proc(t: ^testing.T) {
	path := fmt.aprintf("/tmp/heimdall-provider-probe-timeout-%d", time.to_unix_nanoseconds(time.now()))
	defer { _ = os.remove(path); delete(path) }
	fixture := "#!/bin/sh\nwhile :; do :; done\n"
	write_err := os.write_entire_file(path, fixture)
	if !testing.expect(t, write_err == nil, "timeout fixture must be writable") do return
	chmod_err := os.chmod(path, os.Permissions{.Read_User, .Write_User, .Execute_User})
	if !testing.expect(t, chmod_err == nil, "timeout fixture must be executable") do return
	started := time.to_unix_nanoseconds(time.now())
	version, ok := bridge_provider_probe_version_with_timeout(path, 50 * time.Millisecond)
	elapsed := time.to_unix_nanoseconds(time.now()) - started
	defer delete(version)
	testing.expect(t, !ok && version == "", "timed out provider probe must not report a version")
	testing.expect(t, elapsed < i64(2 * time.Second), "timed out provider probe must be killed and reaped promptly")
}

@(test)
test_provider_discovery_coalesces_identical_concurrent_scans :: proc(t: ^testing.T) {
	filter := []string{"provider-that-is-not-in-the-catalog"}
	sync.mutex_lock(&bridge_provider_discovery_mutex)
	before := bridge_provider_discovery_scan_count
	sync.mutex_unlock(&bridge_provider_discovery_mutex)
	bridge_provider_discovery_test_delay = 100 * time.Millisecond
	defer { bridge_provider_discovery_test_delay = 0 }

	jobs := [2]Provider_Discovery_Test_Job{{filter = filter}, {filter = filter}}
	workers: [2]^thread.Thread
	for i in 0..<2 {
		workers[i] = thread.create(provider_discovery_test_worker)
		workers[i].data = rawptr(&jobs[i])
		thread.start(workers[i])
	}
	for i in 0..<2 {
		thread.join(workers[i])
		thread.destroy(workers[i])
	}
	defer for &job in jobs {
		for &result in job.results do bridge_provider_path_destroy(&result)
		delete(job.results)
	}

	sync.mutex_lock(&bridge_provider_discovery_mutex)
	after := bridge_provider_discovery_scan_count
	sync.mutex_unlock(&bridge_provider_discovery_mutex)
	testing.expect_value(t, after - before, u64(1))
	testing.expect_value(t, len(jobs[0].results), len(jobs[1].results))
}

@(test)
bridge_provider_catalog_name_supported_accepts_slugs_only :: proc(t: ^testing.T) {
	for name in ([]string{"claude", "codex", "copilot", "antigravity", "pi", "open-code", "gpt5"}) {
		testing.expectf(t, bridge_provider_catalog_name_supported(name), "%q should be a supported provider slug", name)
	}
	for name in ([]string{"", "Claude", "pi agent", "-pi", "pi-", "pi/x", "a-very-long-provider-name-over-32b"}) {
		testing.expectf(t, !bridge_provider_catalog_name_supported(name), "%q should be rejected", name)
	}
}

@(test)
bridge_provider_catalog_valid_accepts_any_provider_count :: proc(t: ^testing.T) {
	models := []Bridge_Catalog_Model{{model_id = "m1", label = "M1", state = "active"}}
	providers := []Bridge_Catalog_Provider{
		{provider = "claude", display_name = "Claude Code", binary = "claude", state = "active", models = models},
		{provider = "codex", display_name = "Codex", binary = "codex", state = "active", models = models},
		{provider = "copilot", display_name = "GitHub Copilot", binary = "copilot", state = "active", models = models},
		{provider = "antigravity", display_name = "Antigravity", binary = "agy", state = "active", models = models},
		{provider = "pi", display_name = "Pi", binary = "pi", state = "active", models = models},
	}
	testing.expect(t, bridge_provider_catalog_valid({providers = providers}), "five-provider catalog (with pi) is valid")
	testing.expect(t, bridge_provider_catalog_valid({providers = providers[:1]}), "single-provider catalog is valid")
	testing.expect(t, !bridge_provider_catalog_valid({}), "empty catalog is rejected")

	duplicate := []Bridge_Catalog_Provider{providers[0], providers[0]}
	testing.expect(t, !bridge_provider_catalog_valid({providers = duplicate}), "duplicate provider is rejected")

	bad_name := []Bridge_Catalog_Provider{{provider = "Pi Agent", display_name = "Pi", binary = "pi", state = "active", models = models}}
	testing.expect(t, !bridge_provider_catalog_valid({providers = bad_name}), "malformed provider name is rejected")

	no_models := []Bridge_Catalog_Provider{{provider = "pi", display_name = "Pi", binary = "pi", state = "active"}}
	testing.expect(t, !bridge_provider_catalog_valid({providers = no_models}), "provider without models is rejected")
}
